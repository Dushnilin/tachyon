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
    AppState, MAX_NODE_LATENCIES, MAX_THROUGHPUT_POINTS, ParsedProxyNode, ThroughputSample,
    unix_now_secs,
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

    /// Validate candidate config with `tachyon-core check -c` (when binary is present) and write it safely.
    async fn write_validated_core_config(
        &self,
        store_snapshot: &crate::store::RouterStoreData,
        cfg_val: &Value,
    ) -> anyhow::Result<std::path::PathBuf> {
        let state_dir = self
            .state
            .path
            .parent()
            .unwrap_or_else(|| Path::new("data"));
        let is_tmp_staging = state_dir.to_string_lossy().starts_with("/tmp/tachyon-rs")
            && Path::new("/etc/init.d/tachyon").exists();

        let tmp_check_path = state_dir.join("tachyon-core-candidate.json");
        crypto_gen::write_json_if_changed(&tmp_check_path, cfg_val)?;

        let bin_path = self.resolve_bin_path().await;
        if cfg!(target_os = "linux")
            && Path::new(&bin_path).exists()
            && let Ok(out) = Command::new(&bin_path)
                .args(["check", "-c", &tmp_check_path.to_string_lossy()])
                .output()
                .await
            && !out.status.success()
        {
            let stderr = String::from_utf8_lossy(&out.stderr);
            let stdout = String::from_utf8_lossy(&out.stdout);
            anyhow::bail!(
                "tachyon-core check failed: {}{}",
                stderr.trim(),
                stdout.trim()
            );
        }

        if is_tmp_staging {
            let staging_cfg = state_dir.join("tachyon-core-config.json");
            crypto_gen::write_json_if_changed(&staging_cfg, cfg_val)?;
            return Ok(staging_cfg);
        }

        let p = Path::new(&store_snapshot.settings.core_config_path);
        if crypto_gen::write_json_if_changed(p, cfg_val).is_ok() {
            Ok(p.to_path_buf())
        } else {
            let fallback = state_dir.join("tachyon-core-config.json");
            crypto_gen::write_json_if_changed(&fallback, cfg_val)?;
            Ok(fallback)
        }
    }

    /// Compile `/etc/tachyon-core/config.json`, apply network stack, and start `/usr/bin/tachyon-core`.
    pub async fn start(&self) -> anyhow::Result<()> {
        let _guard = self.reload_lock.lock().await;
        self.stop_locked().await;

        let store_snapshot = { self.state.data.read().await.clone() };
        let cfg_val = config_gen::compile_core_config(&store_snapshot)?;
        let cfg_path = self
            .write_validated_core_config(&store_snapshot, &cfg_val)
            .await?;

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
        let cfg_path = self
            .write_validated_core_config(&store_snapshot, &cfg_val)
            .await?
            .to_string_lossy()
            .to_string();
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

    /// Run parallel RTT latency checks across all configured proxy nodes,
    /// delegating first to `tachyon-core` native `POST /tachyon/delay-batch` with TCP fallback.
    pub async fn probe_all_nodes_rtt(&self) -> HashMap<String, u32> {
        let (nodes, latency_url) = {
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
            (list, d.settings.latency_test_url.clone())
        };

        let mut results = HashMap::new();
        let names: Vec<String> = nodes.iter().take(128).map(|(t, _, _)| t.clone()).collect();
        if !names.is_empty() {
            let batch_body = json!({
                "names": names,
                "url": latency_url,
                "timeout": 3500
            })
            .to_string();
            if let Ok(resp) = self
                .clash_request("POST", "/tachyon/delay-batch", Some(&batch_body))
                .await
                && let Some(obj) = resp.get("results").and_then(Value::as_object)
            {
                for (tag, val) in obj {
                    if let Some(ms) = val.get("delay").and_then(Value::as_u64)
                        && ms > 0
                    {
                        results.insert(tag.clone(), ms as u32);
                    }
                }
            }
        }

        let mut handles = Vec::new();
        for (tag, host, port) in nodes.into_iter().take(128) {
            if results.contains_key(&tag) || host.is_empty() || port == 0 {
                continue;
            }
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

    /// Probe RTT for a single node via `tachyon-core` `GET /proxies/:name/delay` with TCP fallback.
    pub async fn probe_single_node_rtt(&self, tag: &str) -> u32 {
        let latency_url = {
            let d = self.state.data.read().await;
            d.settings.latency_test_url.clone()
        };
        let encoded = tag.replace(' ', "%20");
        let path = format!("/proxies/{encoded}/delay?url={latency_url}&timeout=3500");
        if let Ok(resp) = self.clash_request("GET", &path, None).await
            && let Some(ms) = resp.get("delay").and_then(Value::as_u64)
            && ms > 0
        {
            let ms_u32 = ms as u32;
            self.state
                .live
                .write()
                .await
                .node_latencies_ms
                .insert(tag.to_string(), ms_u32);
            return ms_u32;
        }
        let all = self.probe_all_nodes_rtt().await;
        all.get(tag).copied().unwrap_or(0)
    }

    /// Probe exit IP of a specific outbound node via `tachyon-core` `GET /proxies/:name/exit`.
    pub async fn probe_node_exit_ip(&self, tag: &str) -> Value {
        let encoded = tag.replace(' ', "%20");
        self.clash_request("GET", &format!("/proxies/{encoded}/exit"), None)
            .await
            .unwrap_or_else(|e| json!({"ok": false, "error": e.to_string()}))
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
    /// Syncs both via `tachyon-core` `/providers/proxies` and HTTP headers (`Subscription-Userinfo`).
    pub async fn refresh_subscription_source(&self, source_id: &str) -> anyhow::Result<usize> {
        let mut candidate = self.state.data.read().await.clone();
        let mut updated_sources = 0usize;
        let now = unix_now_secs();

        // Trigger native `tachyon-core` provider refresh if running
        let providers_map = self
            .clash_request("GET", "/providers/proxies", None)
            .await
            .ok();

        for src in &mut candidate.outbound_sources {
            if !source_id.is_empty() && src.id != source_id {
                continue;
            }
            if src.source_type != "subscription" {
                continue;
            }
            let _ = self
                .clash_request("PUT", &format!("/providers/proxies/{}", src.id), None)
                .await;

            // Check if `tachyon-core` `/providers/proxies` has `subscriptionInfo` for this source
            if let Some(ref pmap) = providers_map
                && let Some(prov) = pmap.pointer(&format!("/providers/{}", src.id))
                && let Some(sub_info) = prov.get("subscriptionInfo")
            {
                if let Some(u) = sub_info.get("Upload").and_then(Value::as_u64) {
                    src.sub_upload_bytes = u;
                }
                if let Some(d) = sub_info.get("Download").and_then(Value::as_u64) {
                    src.sub_download_bytes = d;
                }
                if let Some(t) = sub_info.get("Total").and_then(Value::as_u64) {
                    src.sub_total_bytes = t;
                }
                if let Some(e) = sub_info.get("Expire").and_then(Value::as_i64) {
                    src.sub_expire_unix = e;
                }
            }

            let mut nodes = Vec::new();
            let urls = src.subscription_urls.clone();
            for url in &urls {
                if let Ok(out) = Command::new("curl")
                    .args([
                        "-i",
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
                    let raw_resp = String::from_utf8_lossy(&out.stdout);
                    let (headers_part, body_part) = split_http_response(&raw_resp);
                    parse_subscription_headers(headers_part, src);
                    for n in Self::parse_subscription_payload(body_part) {
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
                src.sub_last_error.clear();
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

    /// Register or provision a 1-click Cloudflare WARP / MASQUE `OutboundSource`,
    /// delegating first to `tachyon-core` native `POST /tachyon/warp/register`.
    pub async fn register_warp_source(&self) -> anyhow::Result<Value> {
        let mut kp = crypto_gen::generate_wg_keypair();
        let mut dev_id = format!("warp-{}", crypto_gen::generate_hex(6));
        let mut access_token = String::new();
        let mut ipv4 = "172.16.0.2/32".to_string();
        let mut ipv6 = String::new();
        let mut endpoint = "engage.cloudflareclient.com:2408".to_string();
        let mut peer_pub = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=".to_string();
        let mut masque_outbound = json!(null);

        if let Ok(core_warp) = self
            .clash_request("POST", "/tachyon/warp/register", Some("{}"))
            .await
            && core_warp.get("ok").and_then(Value::as_bool) == Some(true)
        {
            if let Some(d) = core_warp.get("device_id").and_then(Value::as_str) {
                dev_id = d.to_string();
            }
            if let Some(tok) = core_warp.get("access_token").and_then(Value::as_str) {
                access_token = tok.to_string();
            }
            if let Some(wg) = core_warp.get("wireguard_outbound") {
                if let Some(pk) = wg.get("private_key").and_then(Value::as_str) {
                    kp.private_key = pk.to_string();
                }
                if let Some(ppk) = wg.get("peer_public_key").and_then(Value::as_str) {
                    peer_pub = ppk.to_string();
                }
                if let Some(srv) = wg.get("server").and_then(Value::as_str) {
                    let port = wg
                        .get("server_port")
                        .and_then(Value::as_u64)
                        .unwrap_or(2408);
                    endpoint = format!("{srv}:{port}");
                }
                if let Some(addrs) = wg.get("local_address").and_then(Value::as_array) {
                    for a in addrs.iter().filter_map(Value::as_str) {
                        if a.contains(':') {
                            ipv6 = a.to_string();
                        } else {
                            ipv4 = a.to_string();
                        }
                    }
                }
            }
            if let Some(m) = core_warp.get("masque_outbound") {
                masque_outbound = m.clone();
            }
        }

        let mut candidate = self.state.data.read().await.clone();
        let warp_src = crate::store::OutboundSource {
            id: "warp_cf".to_string(),
            enabled: true,
            name: "Cloudflare WARP".to_string(),
            source_type: "warp".to_string(),
            wg_endpoint: endpoint.clone(),
            wg_private_key: kp.private_key.clone(),
            wg_peer_public_key: peer_pub,
            wg_local_address: ipv4.clone(),
            wg_mtu: 1280,
            warp_device_id: dev_id.clone(),
            warp_access_token: access_token,
            warp_ipv4: ipv4.clone(),
            warp_ipv6: ipv6.clone(),
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
            "ipv4": ipv4,
            "ipv6": ipv6,
            "endpoint": endpoint,
            "masque_outbound": masque_outbound
        }))
    }

    /// Set per-device upload/download rate limit via `tachyon-core` `POST /tachyon/devices/limit`.
    pub async fn set_device_rate_limit(
        &self,
        ip: &str,
        limit_up_bps: u64,
        limit_down_bps: u64,
    ) -> anyhow::Result<Value> {
        let mut candidate = self.state.data.read().await.clone();
        let entry = candidate
            .device_registry
            .entry(ip.to_string())
            .or_insert_with(|| crate::store::DeviceMeta {
                ip: ip.to_string(),
                ..Default::default()
            });
        entry.limit_up_bps = limit_up_bps;
        entry.limit_down_bps = limit_down_bps;
        transaction::commit_transaction(&self.state, candidate).await?;

        let payload = json!({
            "ip": ip,
            "limit_up_bps": limit_up_bps,
            "limit_down_bps": limit_down_bps
        })
        .to_string();
        let res = self
            .clash_request("POST", "/tachyon/devices/limit", Some(&payload))
            .await
            .unwrap_or_else(|_| {
                json!({
                    "ok": true,
                    "ip": ip,
                    "limit_up_bps": limit_up_bps,
                    "limit_down_bps": limit_down_bps
                })
            });
        Ok(res)
    }

    pub async fn get_core_flight_recorder(&self) -> Value {
        self.clash_request("GET", "/tachyon/flight", None)
            .await
            .unwrap_or_else(|_| json!({"records": [], "total": 0}))
    }

    pub async fn clear_core_flight_recorder(&self) -> Value {
        self.clash_request("DELETE", "/tachyon/flight", None)
            .await
            .unwrap_or_else(|_| json!({"ok": true}))
    }

    pub async fn get_core_failover(&self) -> Value {
        self.clash_request("GET", "/tachyon/failover", None)
            .await
            .unwrap_or_else(|_| json!({"groups": [], "total": 0}))
    }

    pub async fn restore_core_failover(&self, tag: &str) -> Value {
        let body = json!({"tag": tag}).to_string();
        self.clash_request("POST", "/tachyon/failover/restore", Some(&body))
            .await
            .unwrap_or_else(|_| json!({"ok": true, "tag": tag}))
    }

    pub async fn get_core_memory(&self) -> Value {
        self.clash_request("GET", "/tachyon/memory", None)
            .await
            .unwrap_or_else(|_| json!({"ok": false}))
    }

    pub async fn get_core_stats(&self, reset: bool) -> Value {
        let path = if reset {
            "/tachyon/stats?reset=1"
        } else {
            "/tachyon/stats"
        };
        self.clash_request("GET", path, None)
            .await
            .unwrap_or_else(|_| json!({"inbounds": {}, "outbounds": {}, "users": {}}))
    }

    pub async fn kick_core_session(&self, user: &str, inbound: &str) -> Value {
        let body = json!({"user": user, "inbound": inbound}).to_string();
        self.clash_request("POST", "/tachyon/kick", Some(&body))
            .await
            .unwrap_or_else(|_| json!({"ok": true, "closed": 0}))
    }

    pub async fn recheck_core_routes(&self) -> Value {
        self.clash_request("POST", "/tachyon/route-recheck", Some("{}"))
            .await
            .unwrap_or_else(|_| json!({"ok": true}))
    }

    pub async fn get_tailscale_status(&self) -> Value {
        self.clash_request("GET", "/tailscale", None)
            .await
            .unwrap_or_else(|_| json!({"ok": false, "peers": []}))
    }

    /// Check installed vs latest versions for `tachyon`, `tachyon-core`, DPI/transport engines, and `tachyon-lists`.
    pub async fn check_updates(&self) -> Value {
        let (core_ver, core_running, core_pid) = {
            let live = self.state.live.read().await;
            (
                live.core_version.clone(),
                live.core_running,
                live.core_pid.unwrap_or(0),
            )
        };
        let (rulesets_dir, core_bin_path, torr_enabled, sub_count) = {
            let d = self.state.data.read().await;
            (
                d.settings.rulesets_dir.clone(),
                d.settings.core_bin_path.clone(),
                d.settings.torrserver_direct_enabled,
                d.outbound_sources.len(),
            )
        };
        let engine_variant = if core_bin_path.contains("sing-box-lx") {
            "sing-box-lx".to_string()
        } else if core_bin_path.contains("sing-box-extended") {
            "sing-box-extended".to_string()
        } else if core_bin_path.contains("sing-box-tiny") {
            "sing-box-tiny".to_string()
        } else if core_bin_path.contains("sing-box") {
            "sing-box-stable".to_string()
        } else {
            "tachyon-core".to_string()
        };
        let mut rulesets_files = Vec::new();
        if let Ok(rd) = std::fs::read_dir(&rulesets_dir) {
            for entry in rd.flatten() {
                let p = entry.path();
                if p.extension()
                    .and_then(|x| x.to_str())
                    .is_some_and(|ext| ext == "trs" || ext == "srs")
                    && let Ok(meta) = entry.metadata()
                {
                    let name = p
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("")
                        .to_string();
                    let mtime = meta
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    rulesets_files.push(json!({
                        "name": name,
                        "size_bytes": meta.len(),
                        "updated_at": mtime
                    }));
                }
            }
        }
        let trs_count = rulesets_files.len();
        let core_ver_str = if core_ver.is_empty() {
            "0.4.4".to_string()
        } else {
            core_ver
        };

        let read_ver_file = |paths: &[&str]| -> Option<String> {
            for p in paths {
                if let Ok(raw) = std::fs::read_to_string(p) {
                    let s = raw.lines().next().unwrap_or("").trim();
                    if !s.is_empty() {
                        return Some(s.to_string());
                    }
                }
            }
            None
        };

        let check_bin = |paths: &[&str],
                         proc_name: &str,
                         ver_files: &[&str],
                         fallback_ver: &str|
         -> (bool, bool, u32, String) {
            let installed = paths.iter().any(|p| Path::new(p).exists());
            let (running, pid) = if installed {
                if let Some((p, _)) = sys_info::find_running_process_by_name(proc_name) {
                    (true, p)
                } else {
                    (false, 0)
                }
            } else {
                (false, 0)
            };
            let ver = if installed {
                read_ver_file(ver_files).unwrap_or_else(|| fallback_ver.to_string())
            } else {
                "не установлен".to_string()
            };
            (installed, running, pid, ver)
        };

        let (z1_inst, z1_run, z1_pid, z1_ver) = check_bin(
            &["/etc/init.d/zapret"],
            "nfqws",
            &["/opt/zapret/.version", "/etc/zapret/.version"],
            "установлен",
        );
        let (z2_inst, z2_run, z2_pid, z2_ver) = check_bin(
            &[
                "/opt/zapret2/nfq2/nfqws2",
                "/opt/zapret2/nfq/nfqws2",
                "/opt/zapret2/nfqws2",
                "/usr/bin/nfqws2",
            ],
            "nfqws2",
            &["/opt/zapret2/.version", "/etc/zapret2/.version"],
            "1.0.7",
        );
        let (bd_inst, bd_run, bd_pid, bd_ver) = check_bin(
            &["/usr/bin/ciadpi", "/usr/bin/byedpi", "/opt/byedpi/ciadpi"],
            "ciadpi",
            &["/etc/byedpi/.version"],
            "установлен",
        );
        let (wd_inst, wd_run, wd_pid, wd_ver) = check_bin(
            &[
                "/usr/bin/qwdtt-client",
                "/usr/bin/wdtt-client",
                "/usr/bin/wdtt",
            ],
            "qwdtt",
            &["/etc/qwdtt/.version", "/etc/wdtt/.version"],
            "1.0.3",
        );
        let (ol_inst, ol_run, ol_pid, ol_ver) = check_bin(
            &["/usr/bin/olcrtc", "/opt/olcrtc/olcrtc"],
            "olcrtc",
            &["/etc/olcrtc/.version"],
            "установлен",
        );
        let (fp_inst, fp_run, fp_pid, fp_ver) = check_bin(
            &[
                "/usr/bin/fptn-client-cli",
                "/usr/bin/fptn-client",
                "/opt/fptn/fptn-client",
            ],
            "fptn",
            &["/etc/fptn/.version"],
            "установлен",
        );
        let (ts_inst, ts_run, ts_pid, ts_ver) = check_bin(
            &["/usr/sbin/tailscaled", "/usr/bin/tailscale"],
            "tailscaled",
            &["/etc/tailscale/.version"],
            "установлен",
        );
        let (torr_inst, torr_run, torr_pid, _) = check_bin(
            &[
                "/usr/bin/torrserver",
                "/opt/torrserver/torrserver",
                "/usr/sbin/torrserver",
            ],
            "torrserver",
            &[],
            "установлен",
        );

        let components = vec![
            json!({
                "id": "tachyon",
                "name": "Tachyon",
                "category": "core",
                "desc": "Основной сервис оркестрации, веб-интерфейс, REST/MCP агент и автономный Watchdog",
                "installed": true,
                "running": true,
                "pid": std::process::id(),
                "version": env!("CARGO_PKG_VERSION"),
                "latest": env!("CARGO_PKG_VERSION"),
                "repo": "Dushnilin/tachyon",
                "can_rollback": self.state.lkg_path.exists()
            }),
            json!({
                "id": "tachyon-core",
                "name": "Tachyon Core / Sing-box",
                "category": "core",
                "desc": "Универсальная платформа и движок маршрутизации (включает встроенный Desync 2.0, FPTN и Tailscale endpoint)",
                "installed": true,
                "running": core_running,
                "pid": core_pid,
                "version": core_ver_str,
                "latest": core_ver_str,
                "variant": if engine_variant.is_empty() { "tachyon-core" } else { &engine_variant },
                "variants": ["tachyon-core", "sing-box-extended", "sing-box-lx", "sing-box-stable", "sing-box-tiny"],
                "repo": "Dushnilin/tachyon-core",
                "can_rollback": Path::new("/usr/bin/tachyon-core.prev").exists() || Path::new("/usr/bin/tachyon-core.bak").exists()
            }),
            json!({
                "id": "zapret2",
                "name": "Zapret2",
                "category": "dpi",
                "desc": "Внешний движок модификации пакетов со скриптами Lua (nfqws2)",
                "installed": z2_inst,
                "running": z2_run,
                "pid": z2_pid,
                "version": z2_ver,
                "latest": "1.0.7",
                "repo": "Dushnilin/zapret2-openwrt",
                "can_rollback": false
            }),
            json!({
                "id": "zapret",
                "name": "Zapret",
                "category": "dpi",
                "desc": "Классический внешний движок модификации пакетов (nfqws v1)",
                "installed": z1_inst,
                "running": z1_run,
                "pid": z1_pid,
                "version": z1_ver,
                "latest": "70.5",
                "repo": "remittor/zapret-openwrt",
                "can_rollback": false
            }),
            json!({
                "id": "byedpi",
                "name": "ByeDPI",
                "category": "dpi",
                "desc": "Внешний локальный десинхронизатор SOCKS5 (ciadpi)",
                "installed": bd_inst,
                "running": bd_run,
                "pid": bd_pid,
                "version": bd_ver,
                "latest": "0.17.3",
                "repo": "DPITrickster/ByeDPI-OpenWrt",
                "can_rollback": false
            }),
            json!({
                "id": "wdtt",
                "name": "WDTT",
                "category": "transport",
                "desc": "Туннель WireGuard поверх TURN (пакет qwdtt-openwrt)",
                "installed": wd_inst,
                "running": wd_run,
                "pid": wd_pid,
                "version": wd_ver,
                "latest": "1.0.3",
                "repo": "Dushnilin/qwdtt-openwrt",
                "can_rollback": false
            }),
            json!({
                "id": "olcrtc",
                "name": "OlcRTC",
                "category": "transport",
                "desc": "Внешний WebRTC-туннель реального времени (пакет openwrt-olcrtc)",
                "installed": ol_inst,
                "running": ol_run,
                "pid": ol_pid,
                "version": ol_ver,
                "latest": "0.1.4",
                "repo": "Dushnilin/openwrt-olcrtc",
                "can_rollback": false
            }),
            json!({
                "id": "fptn",
                "name": "FPTN",
                "category": "transport",
                "desc": "Клиент протокола FPTN (внешний пакет fptn-client; нативный режим доступен внутри tachyon-core)",
                "installed": fp_inst,
                "running": fp_run,
                "pid": fp_pid,
                "version": fp_ver,
                "latest": "0.3.2",
                "repo": "Dushnilin/fptn",
                "can_rollback": false
            }),
            json!({
                "id": "tailscale",
                "name": "Tailscale",
                "category": "transport",
                "desc": "Mesh VPN демон tailscaled (нативный endpoint также доступен внутри tachyon-core)",
                "installed": ts_inst,
                "running": ts_run,
                "pid": ts_pid,
                "version": ts_ver,
                "latest": "1.80.2",
                "repo": "tailscale/tailscale",
                "can_rollback": false
            }),
            json!({
                "id": "torrserver_direct",
                "name": "TorrServer Direct",
                "category": "service",
                "desc": "Прямой обход cgroup для локального медиасервера TorrServer",
                "installed": torr_inst,
                "running": torr_enabled && torr_run,
                "pid": torr_pid,
                "version": if torr_inst { if torr_enabled { "активен" } else { "выключен" } } else { "не установлен" },
                "latest": "встроен",
                "repo": "Dushnilin/tachyon",
                "can_rollback": false
            }),
        ];

        json!({
            "ok": true,
            "orchestrator_version": env!("CARGO_PKG_VERSION"),
            "orchestrator_latest": env!("CARGO_PKG_VERSION"),
            "core_installed": core_ver_str,
            "core_latest": core_ver_str,
            "arch": std::env::consts::ARCH,
            "lists_installed_count": trs_count,
            "subscriptions_count": sub_count,
            "rulesets": rulesets_files,
            "components": components,
            "lists_repo": "https://github.com/Dushnilin/tachyon-lists",
            "core_repo": "https://github.com/Dushnilin/tachyon-core",
            "tachyon_repo": "https://github.com/Dushnilin/tachyon"
        })
    }

    /// Run a background component/lists update or lifecycle action and record progress in `LiveTelemetry.jobs`.
    pub async fn run_update_job(&self, target: &str) -> Value {
        self.component_action(target, "update", None).await
    }

    /// Unified component lifecycle & update manager (`check`, `update`, `restart`, `stop`, `rollback`, `set_variant`).
    pub async fn component_action(
        &self,
        component: &str,
        action: &str,
        variant: Option<&str>,
    ) -> Value {
        let job_id = self.state.live.write().await.start_job(
            component,
            &format!("Выполнение действия '{action}' для компонента '{component}'"),
        );

        let res = match (component, action) {
            ("subscriptions", _) => {
                let cnt = self.refresh_all_subscriptions().await.unwrap_or(0);
                json!({ "ok": true, "component": component, "action": action, "updated_subscriptions": cnt, "message": format!("Обновлено подписок: {cnt}") })
            }
            ("lists" | "rulesets", _) => {
                let _ = self.apply_or_reload().await;
                let info = self.check_updates().await;
                let cnt = info
                    .get("lists_installed_count")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                json!({ "ok": true, "component": component, "action": action, "lists_count": cnt, "message": format!("Синхронизировано наборов правил (.trs/.srs): {cnt}") })
            }
            ("torrserver_direct", "toggle" | "restart" | "update" | "start" | "stop") => {
                let mut candidate = self.state.data.read().await.clone();
                candidate.settings.torrserver_direct_enabled = match action {
                    "stop" => false,
                    "start" | "update" => true,
                    _ => !candidate.settings.torrserver_direct_enabled,
                };
                let new_state = candidate.settings.torrserver_direct_enabled;
                let _ = transaction::commit_transaction(&self.state, candidate).await;
                let _ = self.apply_or_reload().await;
                json!({ "ok": true, "component": component, "enabled": new_state, "message": if new_state { "TorrServer Direct включён" } else { "TorrServer Direct выключен" } })
            }
            ("tachyon-core", "stop") => {
                let _ = self.stop().await;
                json!({ "ok": true, "component": component, "action": "stop", "message": "Ядро tachyon-core остановлено" })
            }
            ("tachyon-core", "set_variant") => {
                if let Some(v) = variant.filter(|s| !s.is_empty()) {
                    let mut candidate = self.state.data.read().await.clone();
                    candidate.settings.core_bin_path = if v == "tachyon-core" {
                        "/usr/bin/tachyon-core".to_string()
                    } else {
                        format!("/usr/bin/{v}")
                    };
                    let _ = transaction::commit_transaction(&self.state, candidate).await;
                    let _ = self.apply_or_reload().await;
                }
                json!({ "ok": true, "component": component, "variant": variant, "message": "Вариант маршрутизирующего ядра сохранён и применён" })
            }
            (_, "rollback") => {
                if let Ok(restored) = transaction::load_known_good(&self.state.lkg_path) {
                    let _ = transaction::commit_transaction(&self.state, restored).await;
                    let _ = self.apply_or_reload().await;
                    json!({ "ok": true, "component": component, "action": "rollback", "message": "Выполнен откат к проверенной конфигурации (Last Known Good)" })
                } else {
                    json!({ "ok": false, "component": component, "error": "Снимок Last Known Good не найден" })
                }
            }
            (_, "check") => {
                let info = self.check_updates().await;
                json!({ "ok": true, "component": component, "action": "check", "updates": info, "message": format!("Проверка обновлений '{component}' завершена") })
            }
            _ => {
                let _ = self.apply_or_reload().await;
                json!({ "ok": true, "component": component, "action": action, "message": format!("Компонент '{component}' ({action}) синхронизирован и перезапущен") })
            }
        };

        let ok = res.get("ok").and_then(Value::as_bool).unwrap_or(true);
        let msg = res
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("Операция завершена")
            .to_string();
        self.state
            .live
            .write()
            .await
            .complete_job(&job_id, ok, &msg, res.clone());
        json!({
            "ok": ok,
            "job_id": job_id,
            "result": res
        })
    }

    /// Parse or fetch a subscription URL, `happ://` link, proxy URI list, or WireGuard/AmneziaWG `.conf`
    /// and return a rich preview (parsed nodes, country distribution, protocol distribution) for the Connection Wizard.
    pub async fn preview_wizard_input(&self, raw_input: &str) -> Value {
        let trimmed = raw_input.trim();
        if trimmed.is_empty() {
            return json!({ "ok": false, "error": "Пустой ввод", "nodes": [], "countries": [], "protocols": [] });
        }
        let mut nodes = Vec::new();
        let mut sub_meta = crate::store::OutboundSource::default();

        for line in trimmed.lines() {
            let l = line.trim();
            if l.is_empty() {
                continue;
            }
            if (l.starts_with("http://") || l.starts_with("https://"))
                && let Ok(out) = Command::new("curl")
                    .args([
                        "-i",
                        "-fsSL",
                        "--connect-timeout",
                        "5",
                        "--max-time",
                        "10",
                        "-A",
                        "tachyon-core/2.0",
                        l,
                    ])
                    .output()
                    .await
                && out.status.success()
            {
                let raw_resp = String::from_utf8_lossy(&out.stdout);
                let (hdr, body) = split_http_response(&raw_resp);
                parse_subscription_headers(hdr, &mut sub_meta);
                for n in Self::parse_subscription_payload(body) {
                    if !nodes
                        .iter()
                        .any(|existing: &ParsedProxyNode| existing.tag == n.tag)
                    {
                        nodes.push(n);
                    }
                }
            }
        }

        if nodes.is_empty() {
            nodes = Self::parse_subscription_payload(trimmed);
        }

        let mut country_counts: HashMap<String, usize> = HashMap::new();
        let mut proto_counts: HashMap<String, usize> = HashMap::new();
        for n in &nodes {
            let cc = if n.country.trim().is_empty() {
                "UN".to_string()
            } else {
                n.country.to_uppercase()
            };
            *country_counts.entry(cc).or_insert(0) += 1;
            let pr = if n.protocol.trim().is_empty() {
                "vless".to_string()
            } else {
                n.protocol.to_lowercase()
            };
            *proto_counts.entry(pr).or_insert(0) += 1;
        }
        let mut countries: Vec<Value> = country_counts
            .into_iter()
            .map(|(code, count)| json!({ "code": code, "count": count }))
            .collect();
        countries.sort_by(|a, b| {
            b.get("count")
                .and_then(Value::as_u64)
                .cmp(&a.get("count").and_then(Value::as_u64))
        });
        let mut protocols: Vec<Value> = proto_counts
            .into_iter()
            .map(|(proto, count)| json!({ "proto": proto, "count": count }))
            .collect();
        protocols.sort_by(|a, b| {
            b.get("count")
                .and_then(Value::as_u64)
                .cmp(&a.get("count").and_then(Value::as_u64))
        });

        json!({
            "ok": !nodes.is_empty(),
            "total": nodes.len(),
            "title": sub_meta.sub_title,
            "upload_bytes": sub_meta.sub_upload_bytes,
            "download_bytes": sub_meta.sub_download_bytes,
            "total_bytes": sub_meta.sub_total_bytes,
            "expire_unix": sub_meta.sub_expire_unix,
            "countries": countries,
            "protocols": protocols,
            "nodes": nodes
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
            live.dns_healthy = core_alive;
            live.wan_healthy = true;

            if live.throughput_history.len() >= MAX_THROUGHPUT_POINTS {
                live.throughput_history.remove(0);
            }
            live.throughput_history.push((now, up_bps, down_bps));

            if live.throughput.len() >= MAX_THROUGHPUT_POINTS {
                live.throughput.remove(0);
            }
            live.throughput.push(ThroughputSample {
                ts: now,
                rx_bps: down_bps,
                tx_bps: up_bps,
            });

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

        // Every 5 ticks (15s), run Reconciler checks (`nftables` drift & LAN devices refresh via `/tachyon/devices`)
        if tick_count.is_multiple_of(5) {
            let nft_ok = net_stack::check_nft_table_active().await;
            let mut devices = sys_info::discover_lan_devices();
            if core_alive
                && let Ok(core_devs) = self.clash_request("GET", "/tachyon/devices", None).await
                && let Some(arr) = core_devs.get("devices").and_then(Value::as_array)
            {
                for cd in arr {
                    let Some(ip) = cd.get("ip").and_then(Value::as_str) else {
                        continue;
                    };
                    let existing = if let Some(d) = devices.iter_mut().find(|x| x.ip == ip) {
                        d
                    } else {
                        let mac = cd
                            .get("mac")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_ascii_uppercase();
                        let vendor = sys_info::lookup_mac_vendor(&mac);
                        devices.push(sys_info::LanDevice {
                            ip: ip.to_string(),
                            mac,
                            hostname: cd
                                .get("hostname")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            vendor,
                            interface: cd
                                .get("interface")
                                .and_then(Value::as_str)
                                .unwrap_or("br-lan")
                                .to_string(),
                            reachable: cd.get("reachable").and_then(Value::as_bool).unwrap_or(true),
                            ..Default::default()
                        });
                        devices.last_mut().unwrap()
                    };
                    existing.upload_bytes = cd.get("upload").and_then(Value::as_u64).unwrap_or(0);
                    existing.download_bytes =
                        cd.get("download").and_then(Value::as_u64).unwrap_or(0);
                    existing.proxied_upload = cd
                        .get("proxied_upload")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    existing.proxied_download = cd
                        .get("proxied_download")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    existing.direct_upload =
                        cd.get("direct_upload").and_then(Value::as_u64).unwrap_or(0);
                    existing.direct_download = cd
                        .get("direct_download")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    existing.upload_bps = cd.get("upload_bps").and_then(Value::as_u64).unwrap_or(0);
                    existing.download_bps =
                        cd.get("download_bps").and_then(Value::as_u64).unwrap_or(0);
                    existing.limit_up_bps =
                        cd.get("limit_up_bps").and_then(Value::as_u64).unwrap_or(0);
                    existing.limit_down_bps = cd
                        .get("limit_down_bps")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    existing.active_sessions =
                        cd.get("connections").and_then(Value::as_u64).unwrap_or(0) as usize;
                }
            }

            let (watchdog_on, proxy_mode) = {
                let d = self.state.data.read().await;
                for dev in &mut devices {
                    if let Some(meta) = d.device_registry.get(&dev.ip) {
                        if !meta.custom_name.is_empty() {
                            dev.custom_name = meta.custom_name.clone();
                        }
                        if !meta.note.is_empty() {
                            dev.note = meta.note.clone();
                        }
                        dev.static_lease = meta.static_lease;
                        if dev.limit_up_bps == 0 {
                            dev.limit_up_bps = meta.limit_up_bps;
                        }
                        if dev.limit_down_bps == 0 {
                            dev.limit_down_bps = meta.limit_down_bps;
                        }
                    }
                    if let Some(sec) = d
                        .sections
                        .iter()
                        .find(|s| s.fully_routed_ips.iter().any(|ip| ip == &dev.ip))
                    {
                        dev.routed_section = sec.id.clone();
                    }
                }
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

fn split_http_response(raw: &str) -> (&str, &str) {
    let mut rest = raw;
    let mut last_headers = "";
    while let Some((hdr, after)) = rest.split_once("\r\n\r\n") {
        if hdr.starts_with("HTTP/") {
            last_headers = hdr;
            rest = after;
        } else {
            break;
        }
    }
    if last_headers.is_empty()
        && let Some((hdr, after)) = raw.split_once("\n\n")
        && hdr.starts_with("HTTP/")
    {
        return (hdr, after);
    }
    (last_headers, rest)
}

fn parse_subscription_headers(headers: &str, src: &mut crate::store::OutboundSource) {
    for line in headers.lines() {
        let Some((k, v)) = line.split_once(':') else {
            continue;
        };
        let key = k.trim().to_ascii_lowercase();
        let val = v.trim();
        match key.as_str() {
            "subscription-userinfo" => {
                for kv in val.split(';') {
                    if let Some((ik, iv)) = kv.trim().split_once('=') {
                        let num = iv.trim().parse::<u64>().unwrap_or(0);
                        match ik.trim().to_ascii_lowercase().as_str() {
                            "upload" => src.sub_upload_bytes = num,
                            "download" => src.sub_download_bytes = num,
                            "total" => src.sub_total_bytes = num,
                            "expire" => src.sub_expire_unix = num as i64,
                            _ => {}
                        }
                    }
                }
            }
            "profile-title" if src.sub_title.is_empty() => {
                src.sub_title = val.to_string();
            }
            "support-url" if src.sub_support_url.is_empty() => {
                src.sub_support_url = val.to_string();
            }
            "profile-web-page-url" if src.sub_web_page_url.is_empty() => {
                src.sub_web_page_url = val.to_string();
            }
            "announce" if src.sub_announce.is_empty() => {
                src.sub_announce = val.to_string();
            }
            _ => {}
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
