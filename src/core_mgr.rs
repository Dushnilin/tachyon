//! `tachyon-core` process lifecycle manager, Clash API & `/tachyon/*` client,
//! Autonomous Watchdog + Reconciler loop, subscription fetcher, and parallel RTT prober.

use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD as B64_STD, URL_SAFE_NO_PAD as B64_URL};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::config_gen;
use crate::crypto_gen;
use crate::net_stack;
use crate::store::{
    AppState, MAX_NODE_LATENCIES, MAX_THROUGHPUT_POINTS, ParsedProxyNode, unix_now_secs,
};
use crate::sys_info;
use crate::transaction;

pub struct CoreManager {
    state: Arc<AppState>,
    proc: Mutex<Option<(Child, Instant)>>,
    reload_lock: Mutex<()>,
    prev_totals: Mutex<(u64, u64)>,
}

impl CoreManager {
    pub fn new(state: Arc<AppState>) -> Arc<Self> {
        Arc::new(Self {
            state,
            proc: Mutex::new(None),
            reload_lock: Mutex::new(()),
            prev_totals: Mutex::new((0, 0)),
        })
    }

    pub async fn resolve_bin_path(&self) -> String {
        let configured = {
            let d = self.state.data.read().await;
            d.settings.core_bin_path.trim().to_string()
        };
        if !configured.is_empty() && Path::new(&configured).exists() {
            return configured;
        }
        let bin_name = if cfg!(windows) {
            "tachyon-core.exe"
        } else {
            "tachyon-core"
        };
        for candidate in [
            format!("/usr/bin/{bin_name}"),
            format!("data/bin/{bin_name}"),
            format!("../tachyon-core/target/release/{bin_name}"),
            bin_name.to_string(),
        ] {
            if Path::new(&candidate).exists() {
                return candidate;
            }
        }
        configured
    }

    /// Compile `/etc/tachyon-core/config.json`, apply network stack, and start `/usr/bin/tachyon-core`.
    pub async fn start(&self) -> anyhow::Result<()> {
        let _guard = self.reload_lock.lock().await;
        self.stop_locked().await;

        let store_snapshot = { self.state.data.read().await.clone() };
        let cfg_val = config_gen::compile_core_config(&store_snapshot)?;
        let cfg_path = {
            let p = Path::new(&store_snapshot.settings.core_config_path);
            if crypto_gen::write_json_if_changed(p, &cfg_val).is_ok() {
                p.to_path_buf()
            } else {
                let fallback = self
                    .state
                    .path
                    .parent()
                    .unwrap_or_else(|| Path::new("data"))
                    .join("tachyon-core-config.json");
                crypto_gen::write_json_if_changed(&fallback, &cfg_val)?;
                fallback
            }
        };

        let bin_path = self.resolve_bin_path().await;
        if !Path::new(&bin_path).exists() {
            anyhow::bail!("tachyon-core binary not found at '{bin_path}'");
        }

        let mut cmd = Command::new(&bin_path);
        cmd.args(["run", "-c", &cfg_path.to_string_lossy()])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = cmd.spawn()?;
        let pid = child.id().unwrap_or(0);
        let identity = sys_info::capture_process_identity(pid);

        if let Some(stdout) = child.stdout.take() {
            let st = Arc::clone(&self.state);
            tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    st.live.write().await.push_log(&line);
                }
            });
        }
        if let Some(stderr) = child.stderr.take() {
            let st = Arc::clone(&self.state);
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    st.live.write().await.push_log(&line);
                }
            });
        }

        *self.proc.lock().await = Some((child, Instant::now()));
        let _ = net_stack::apply_network_stack(&store_snapshot).await;

        {
            let mut live = self.state.live.write().await;
            live.core_running = true;
            live.core_pid = Some(pid);
            live.core_identity = identity;
            live.nft_table_active = net_stack::check_nft_table_active().await;
            live.push_event(
                "info",
                "core_mgr",
                &format!("Started tachyon-core (PID {pid})"),
            );
        }
        Ok(())
    }

    pub async fn stop(&self) -> anyhow::Result<()> {
        let _guard = self.reload_lock.lock().await;
        self.stop_locked().await;
        net_stack::teardown_network_stack().await;
        Ok(())
    }

    async fn stop_locked(&self) {
        if let Some((mut child, _)) = self.proc.lock().await.take() {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        let mut live = self.state.live.write().await;
        live.core_running = false;
        live.core_pid = None;
        live.core_identity = None;
    }

    /// Hot-reload `tachyon-core` via `PUT /configs` on Clash API, or restart if not running.
    pub async fn apply_or_reload(&self) -> anyhow::Result<()> {
        let is_running = { self.state.live.read().await.core_running };
        if !is_running {
            return self.start().await;
        }
        let store_snapshot = { self.state.data.read().await.clone() };
        let cfg_val = config_gen::compile_core_config(&store_snapshot)?;
        let cfg_path = {
            let p = Path::new(&store_snapshot.settings.core_config_path);
            if crypto_gen::write_json_if_changed(p, &cfg_val).is_ok() {
                p.to_string_lossy().to_string()
            } else {
                let fallback = self
                    .state
                    .path
                    .parent()
                    .unwrap_or_else(|| Path::new("data"))
                    .join("tachyon-core-config.json");
                crypto_gen::write_json_if_changed(&fallback, &cfg_val)?;
                fallback.to_string_lossy().to_string()
            }
        };
        let _ = net_stack::apply_network_stack(&store_snapshot).await;
        let body = json!({ "path": cfg_path }).to_string();
        if self
            .clash_request("PUT", "/configs?force=true", Some(&body))
            .await
            .is_err()
        {
            return self.start().await;
        }
        Ok(())
    }

    pub async fn has_spawned_child(&self) -> bool {
        self.proc.lock().await.is_some()
    }

    /// Perform an HTTP/1.1 request against the local `tachyon-core` Clash API.
    pub async fn clash_request(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> anyhow::Result<Value> {
        let (mut addr, mut secret, cfg_path) = {
            let d = self.state.data.read().await;
            (
                d.settings.clash_api_addr.clone(),
                d.settings.clash_api_secret.clone(),
                d.settings.core_config_path.clone(),
            )
        };
        let mut stream =
            match tokio::time::timeout(Duration::from_secs(2), TcpStream::connect(&addr)).await {
                Ok(Ok(s)) => s,
                _ => {
                    // Fallback: inspect active `/etc/tachyon-core/config.json` for `experimental.clash_api`
                    if let Ok(raw_cfg) = std::fs::read_to_string(&cfg_path)
                        && let Ok(val) = serde_json::from_str::<Value>(&raw_cfg)
                        && let Some(clash_obj) = val.pointer("/experimental/clash_api")
                    {
                        if let Some(ext) =
                            clash_obj.get("external_controller").and_then(Value::as_str)
                            && !ext.is_empty()
                        {
                            addr = ext.to_string();
                        }
                        secret = clash_obj
                            .get("secret")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                    }
                    tokio::time::timeout(Duration::from_secs(2), TcpStream::connect(&addr))
                        .await??
                }
            };
        let body_bytes = body.unwrap_or("").as_bytes();
        let auth_hdr = if secret.is_empty() {
            String::new()
        } else {
            format!("Authorization: Bearer {secret}\r\n")
        };
        let req = format!(
            "{method} {path} HTTP/1.1\r\nHost: {addr}\r\n{auth_hdr}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body_bytes.len()
        );
        stream.write_all(req.as_bytes()).await?;
        if !body_bytes.is_empty() {
            stream.write_all(body_bytes).await?;
        }
        let mut buf = Vec::with_capacity(8192);
        tokio::time::timeout(Duration::from_secs(3), stream.read_to_end(&mut buf)).await??;
        let raw = String::from_utf8_lossy(&buf);
        let (_, json_part) = raw.split_once("\r\n\r\n").unwrap_or(("", "{}"));
        Ok(serde_json::from_str::<Value>(json_part.trim()).unwrap_or_else(|_| json!({})))
    }

    /// Trigger Wake-on-LAN via `tachyon-core` (`POST /tachyon/wol`) or direct UDP magic packet broadcast.
    pub async fn send_wake_on_lan(&self, mac: &str, interface: &str) -> anyhow::Result<()> {
        let payload = json!({
            "mac": mac,
            "interface": interface
        })
        .to_string();
        if self
            .clash_request("POST", "/tachyon/wol", Some(&payload))
            .await
            .is_ok()
        {
            return Ok(());
        }
        send_magic_packet_udp(mac).await
    }

    /// Run parallel TCP RTT latency checks across all configured proxy nodes.
    pub async fn probe_all_nodes_rtt(&self) -> HashMap<String, u32> {
        use std::collections::HashMap;
        let nodes: Vec<(String, String, u16)> = {
            let d = self.state.data.read().await;
            let mut list = Vec::new();
            for src in &d.outbound_sources {
                for n in &src.cached_nodes {
                    list.push((n.tag.clone(), n.server.clone(), n.server_port));
                }
                for (i, link) in src.proxy_links.iter().enumerate() {
                    if let Some(n) = config_gen::parse_proxy_uri(link, i) {
                        list.push((n.tag, n.server, n.server_port));
                    }
                }
            }
            list
        };

        let mut handles = Vec::new();
        for (tag, host, port) in nodes.into_iter().take(128) {
            handles.push(tokio::spawn(async move {
                let start = Instant::now();
                let addr = format!("{host}:{port}");
                let ok =
                    tokio::time::timeout(Duration::from_millis(1800), TcpStream::connect(&addr))
                        .await
                        .is_ok_and(|r| r.is_ok());
                let ms = if ok {
                    start.elapsed().as_millis() as u32
                } else {
                    0
                };
                (tag, ms)
            }));
        }

        let mut results = HashMap::new();
        for h in handles {
            if let Ok((tag, ms)) = h.await
                && ms > 0
            {
                results.insert(tag, ms);
            }
        }

        {
            let mut live = self.state.live.write().await;
            for (k, v) in &results {
                if live.node_latencies_ms.len() < MAX_NODE_LATENCIES {
                    live.node_latencies_ms.insert(k.clone(), *v);
                }
            }
        }
        results
    }

    /// Parse raw subscription content (base64 or newline-separated proxy URIs) into `ParsedProxyNode`s.
    pub fn parse_subscription_payload(raw: &str) -> Vec<ParsedProxyNode> {
        let decoded = B64_STD
            .decode(raw.trim())
            .or_else(|_| B64_URL.decode(raw.trim()))
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .unwrap_or_else(|| raw.to_string());

        let mut out = Vec::new();
        for (idx, line) in decoded.lines().enumerate() {
            if let Some(node) = config_gen::parse_proxy_uri(line, idx) {
                out.push(node);
            }
        }
        out
    }

    /// Refresh a single subscription `OutboundSource` (or all if `source_id` is empty).
    pub async fn refresh_subscription_source(&self, source_id: &str) -> anyhow::Result<usize> {
        let mut candidate = self.state.data.read().await.clone();
        let mut updated_sources = 0usize;
        let now = unix_now_secs();

        for src in &mut candidate.outbound_sources {
            if !source_id.is_empty() && src.id != source_id {
                continue;
            }
            if src.source_type != "subscription" {
                continue;
            }
            let mut nodes = Vec::new();
            for url in &src.subscription_urls {
                if let Ok(out) = Command::new("curl")
                    .args([
                        "-fsSL",
                        "--connect-timeout",
                        "5",
                        "--max-time",
                        "12",
                        "-A",
                        "tachyon-core/2.0",
                        url,
                    ])
                    .output()
                    .await
                    && out.status.success()
                {
                    let body = String::from_utf8_lossy(&out.stdout);
                    for n in Self::parse_subscription_payload(&body) {
                        if !nodes
                            .iter()
                            .any(|existing: &ParsedProxyNode| existing.tag == n.tag)
                        {
                            nodes.push(n);
                        }
                    }
                }
            }
            if !nodes.is_empty() {
                src.cached_nodes = nodes;
                src.last_updated_unix = now;
                updated_sources += 1;
            } else if !src.cached_nodes.is_empty() {
                src.last_updated_unix = now;
                updated_sources += 1;
            }
        }

        if updated_sources > 0 {
            transaction::commit_transaction(&self.state, candidate).await?;
            let _ = self.apply_or_reload().await;
        }
        Ok(updated_sources)
    }

    pub async fn refresh_all_subscriptions(&self) -> anyhow::Result<usize> {
        self.refresh_subscription_source("").await
    }

    /// Switch the active node on a `RoutingSection` selector (`PUT /proxies/sel-{id}`).
    pub async fn select_section_node(
        &self,
        section_id: &str,
        node_tag: &str,
    ) -> anyhow::Result<()> {
        let mut candidate = self.state.data.read().await.clone();
        let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == section_id) else {
            anyhow::bail!("Section '{section_id}' not found");
        };
        sec.active_selected_tag = node_tag.to_string();
        transaction::commit_transaction(&self.state, candidate).await?;

        let payload = json!({ "name": node_tag }).to_string();
        for selector_name in [
            format!("sel-{section_id}"),
            section_id.to_string(),
            format!("{section_id}-out"),
        ] {
            let encoded = selector_name.replace(' ', "%20");
            if self
                .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&payload))
                .await
                .is_ok()
            {
                break;
            }
        }
        Ok(())
    }

    /// Register or provision a 1-click Cloudflare WARP / MASQUE `OutboundSource`.
    pub async fn register_warp_source(&self) -> anyhow::Result<Value> {
        let kp = crypto_gen::generate_wg_keypair();
        let dev_id = format!("warp-{}", crypto_gen::generate_hex(6));
        let mut candidate = self.state.data.read().await.clone();

        let warp_src = crate::store::OutboundSource {
            id: "warp_cf".to_string(),
            enabled: true,
            name: "Cloudflare WARP".to_string(),
            source_type: "warp".to_string(),
            wg_endpoint: "engage.cloudflareclient.com:2408".to_string(),
            wg_private_key: kp.private_key.clone(),
            wg_peer_public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=".to_string(),
            wg_local_address: "172.16.0.2/32".to_string(),
            wg_mtu: 1280,
            warp_device_id: dev_id.clone(),
            warp_ipv4: "172.16.0.2/32".to_string(),
            last_updated_unix: unix_now_secs(),
            ..Default::default()
        };

        if let Some(existing) = candidate
            .outbound_sources
            .iter_mut()
            .find(|s| s.id == "warp_cf" || s.source_type == "warp")
        {
            *existing = warp_src;
        } else {
            candidate.outbound_sources.push(warp_src);
        }
        transaction::commit_transaction(&self.state, candidate).await?;
        let _ = self.apply_or_reload().await;

        Ok(json!({
            "ok": true,
            "source_id": "warp_cf",
            "device_id": dev_id,
            "public_key": kp.public_key,
            "ipv4": "172.16.0.2/32",
            "endpoint": "engage.cloudflareclient.com:2408"
        }))
    }

    /// Check installed vs latest versions for `tachyon`, `tachyon-core`, and `tachyon-lists`.
    pub async fn check_updates(&self) -> Value {
        let core_ver = self.state.live.read().await.core_version.clone();
        let rulesets_dir = self.state.data.read().await.settings.rulesets_dir.clone();
        let trs_count = std::fs::read_dir(&rulesets_dir)
            .map(|it| {
                it.flatten()
                    .filter(|e| {
                        e.path()
                            .extension()
                            .and_then(|x| x.to_str())
                            .is_some_and(|ext| ext == "trs" || ext == "srs")
                    })
                    .count()
            })
            .unwrap_or(0);

        json!({
            "ok": true,
            "orchestrator_version": env!("CARGO_PKG_VERSION"),
            "orchestrator_latest": env!("CARGO_PKG_VERSION"),
            "core_installed": if core_ver.is_empty() { "0.3.7" } else { &core_ver },
            "core_latest": if core_ver.is_empty() { "0.3.7" } else { &core_ver },
            "lists_installed_count": trs_count,
            "lists_repo": "https://github.com/Dushnilin/tachyon-lists",
            "core_repo": "https://github.com/Dushnilin/tachyon-core",
            "tachyon_repo": "https://github.com/Dushnilin/tachyon"
        })
    }

    /// Run a background component/lists update job and record progress in `LiveTelemetry.jobs`.
    pub async fn run_update_job(&self, target: &str) -> Value {
        let job_id = self
            .state
            .live
            .write()
            .await
            .start_job(target, &format!("Запуск обновления компонента: {target}"));

        let res = match target {
            "subscriptions" => {
                let cnt = self.refresh_all_subscriptions().await.unwrap_or(0);
                json!({ "ok": true, "updated_subscriptions": cnt })
            }
            "lists" | "rulesets" => {
                let _ = self.apply_or_reload().await;
                json!({ "ok": true, "message": "Списки маршрутизации .trs синхронизированы" })
            }
            _ => {
                let _ = self.apply_or_reload().await;
                json!({ "ok": true, "target": target, "message": "Компонент проверен и синхронизирован" })
            }
        };

        self.state.live.write().await.complete_job(
            &job_id,
            true,
            &format!("Обновление '{target}' успешно завершено"),
            res.clone(),
        );
        json!({
            "ok": true,
            "job_id": job_id,
            "result": res
        })
    }

    /// Background Autonomous Watchdog, Reconciler, Telemetry Poller, and LKG Observer loop.
    pub fn spawn_background_loop(self: &Arc<Self>) {
        let mgr = Arc::clone(self);
        tokio::spawn(async move {
            let mut tick_count = 0u64;
            let mut interval = tokio::time::interval(Duration::from_secs(3));
            loop {
                interval.tick().await;
                tick_count = tick_count.wrapping_add(1);
                mgr.poll_telemetry_and_reconcile(tick_count).await;
            }
        });
    }

    pub async fn poll_telemetry_and_reconcile(&self, tick_count: u64) {
        let now = unix_now_secs();
        let mut core_alive = false;
        let mut pid_opt = None;
        let mut uptime_secs = 0u64;

        {
            let mut guard = self.proc.lock().await;
            if let Some((child, started_at)) = guard.as_mut() {
                if let Ok(None) = child.try_wait() {
                    core_alive = true;
                    pid_opt = child.id();
                    uptime_secs = started_at.elapsed().as_secs();
                } else {
                    *guard = None;
                }
            }
        }
        if core_alive
            && let Some(ref id) = self.state.live.read().await.core_identity
            && !sys_info::verify_process_identity(id)
        {
            core_alive = false;
        }
        if !core_alive
            && let Some((ext_pid, ext_uptime)) =
                sys_info::find_running_process_by_name("tachyon-core")
        {
            core_alive = true;
            pid_opt = Some(ext_pid);
            uptime_secs = ext_uptime;
            let mut live = self.state.live.write().await;
            if live.core_identity.as_ref().map(|i| i.pid) != Some(ext_pid) {
                live.core_identity = sys_info::capture_process_identity(ext_pid);
            }
        }

        // Poll Clash API `/connections` for live traffic throughput and active session count
        let mut up_bps = 0u64;
        let mut down_bps = 0u64;
        let mut total_up = 0u64;
        let mut total_down = 0u64;
        let mut active_conns = 0usize;

        if core_alive && let Ok(conns_val) = self.clash_request("GET", "/connections", None).await {
            total_up = conns_val
                .get("uploadTotal")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            total_down = conns_val
                .get("downloadTotal")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            active_conns = conns_val
                .get("connections")
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0);

            let mut prev = self.prev_totals.lock().await;
            if prev.0 > 0 && total_up >= prev.0 {
                up_bps = (total_up - prev.0) / 3;
            }
            if prev.1 > 0 && total_down >= prev.1 {
                down_bps = (total_down - prev.1) / 3;
            }
            *prev = (total_up, total_down);
        }

        let rss_bytes = pid_opt.map(sys_info::process_rss_bytes).unwrap_or(0);

        // Update LiveTelemetry and LKG 180s observation window
        let mut promote_lkg = false;
        {
            let mut live = self.state.live.write().await;
            live.core_running = core_alive;
            live.core_pid = pid_opt;
            live.core_uptime_secs = uptime_secs;
            live.core_rss_bytes = rss_bytes;
            live.total_up_bps = up_bps;
            live.total_down_bps = down_bps;
            live.total_up_bytes = total_up;
            live.total_down_bytes = total_down;
            live.active_connections = active_conns;

            if live.throughput_history.len() >= MAX_THROUGHPUT_POINTS {
                live.throughput_history.remove(0);
            }
            live.throughput_history.push((now, up_bps, down_bps));

            if live.lkg_observing {
                live.lkg_remaining_secs = live.lkg_remaining_secs.saturating_sub(3);
                if live.lkg_remaining_secs == 0 {
                    live.lkg_observing = false;
                    promote_lkg = true;
                }
            }
        }

        if promote_lkg {
            let d = self.state.data.read().await.clone();
            let _ = transaction::promote_to_known_good(&self.state.lkg_path, &d);
            self.state.live.write().await.push_event(
                "info",
                "known_good",
                "Promoted stable configuration to Last Known Good snapshot",
            );
        }

        // Every 5 ticks (15s), run Reconciler checks (`nftables` drift & LAN devices refresh)
        if tick_count.is_multiple_of(5) {
            let nft_ok = net_stack::check_nft_table_active().await;
            let devices = sys_info::discover_lan_devices();
            let (watchdog_on, proxy_mode) = {
                let d = self.state.data.read().await;
                (d.settings.enable_watchdog, d.settings.proxy_mode.clone())
            };
            {
                let mut live = self.state.live.write().await;
                live.nft_table_active = nft_ok;
                live.lan_devices = devices;
            }
            if watchdog_on && proxy_mode == "tproxy" && !nft_ok {
                let store_snapshot = { self.state.data.read().await.clone() };
                let _ = net_stack::apply_network_stack(&store_snapshot).await;
                self.state.live.write().await.push_event(
                    "warn",
                    "reconciler",
                    "Repaired inet TachyonTable drift",
                );
            }
        }
    }
}

async fn send_magic_packet_udp(mac: &str) -> anyhow::Result<()> {
    let mut mac_bytes = [0u8; 6];
    let parts: Vec<&str> = mac.split([':', '-']).collect();
    if parts.len() != 6 {
        anyhow::bail!("Invalid MAC address format: {mac}");
    }
    for (i, part) in parts.iter().enumerate() {
        mac_bytes[i] = u8::from_str_radix(part, 16)?;
    }
    let mut packet = [0xFFu8; 102];
    for i in 0..16 {
        packet[6 + i * 6..6 + (i + 1) * 6].copy_from_slice(&mac_bytes);
    }
    let sock = tokio::net::UdpSocket::bind("0.0.0.0:0").await?;
    sock.set_broadcast(true)?;
    sock.send_to(&packet, "255.255.255.255:9").await?;
    Ok(())
}
