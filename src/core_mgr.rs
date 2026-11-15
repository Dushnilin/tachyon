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
    pub state: Arc<AppState>,
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

        let tmp_check_path = std::env::temp_dir().join("tachyon-core-candidate.json");
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

    fn ensure_runtime_cache_dir(cache_path: &str) {
        let trimmed = cache_path.trim();
        if trimmed.is_empty() {
            return;
        }
        let dst = Path::new(trimmed);
        if let Some(parent) = dst.parent()
            && !parent.as_os_str().is_empty()
        {
            let _ = std::fs::create_dir_all(parent);
        }
        if !dst.exists() {
            for seed in [
                "/etc/tachyon-core/cache.db",
                "/usr/share/tachyon-core/cache.db",
            ] {
                let src = Path::new(seed);
                if src.exists() {
                    let _ = std::fs::copy(src, dst);
                    break;
                }
            }
        }
    }

    /// Compile `/etc/tachyon-core/config.json`, apply network stack, and start `/usr/bin/tachyon-core`.
    pub async fn start(&self) -> anyhow::Result<()> {
        let _guard = self.reload_lock.lock().await;
        self.stop_locked().await;

        let store_snapshot = { self.state.data.read().await.clone() };
        let _ = crate::store::probe_wan6_runtime_state();
        Self::ensure_runtime_cache_dir(&store_snapshot.settings.cache_path);
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
        let net_res = net_stack::apply_network_stack(&store_snapshot).await;
        let _ = self.refresh_core_version().await;
        let nft_ok = net_stack::check_nft_table_active().await;

        {
            let mut live = self.state.live.write().await;
            live.core_running = true;
            live.core_pid = Some(pid);
            live.core_identity = identity;
            live.nft_table_active = nft_ok;
            live.push_event(
                "info",
                "core_mgr",
                &format!("Started tachyon-core (PID {pid})"),
            );
            if let Err(ref e) = net_res {
                eprintln!("[tachyon] apply_network_stack failed: {e:#}");
                live.push_event(
                    "error",
                    "net_stack",
                    &format!("apply_network_stack failed: {e:#}"),
                );
            }
        }
        self.restore_saved_selectors(&store_snapshot).await;
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
        #[cfg(target_os = "linux")]
        {
            // Also terminate any externally started or orphaned `tachyon-core` process
            // (e.g., adopted on daemon startup or stale pre-upgrade `(deleted)` binary)
            // so the new binary/config can bind `:1602`, `:53`, and `:9090` cleanly.
            let mut killed_pids = std::collections::HashSet::new();
            for _ in 0..8 {
                let target_pid = {
                    let live_pid = self.state.live.read().await.core_pid;
                    live_pid
                        .filter(|p| {
                            Path::new(&format!("/proc/{p}")).exists() && !killed_pids.contains(p)
                        })
                        .or_else(|| {
                            sys_info::find_running_process_by_name("tachyon-core")
                                .map(|(p, _)| p)
                                .filter(|p| !killed_pids.contains(p))
                        })
                };
                let Some(ext_pid) = target_pid else {
                    break;
                };
                killed_pids.insert(ext_pid);
                let _ = Command::new("kill")
                    .args(["-TERM", &ext_pid.to_string()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .await;
                let mut exited = false;
                for _ in 0..15 {
                    if !Path::new(&format!("/proc/{ext_pid}")).exists() {
                        exited = true;
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                if !exited {
                    let _ = Command::new("kill")
                        .args(["-KILL", &ext_pid.to_string()])
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .status()
                        .await;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
        let mut live = self.state.live.write().await;
        live.core_running = false;
        live.core_pid = None;
        live.core_identity = None;
    }

    /// Hot-reload `tachyon-core` via `PUT /configs` on Clash API, or restart if not running.
    pub async fn apply_or_reload(&self) -> anyhow::Result<()> {
        let (is_running, core_pid) = {
            let live = self.state.live.read().await;
            (live.core_running, live.core_pid)
        };
        let exe_deleted = core_pid.is_some_and(|p| {
            std::fs::read_link(format!("/proc/{p}/exe"))
                .ok()
                .is_some_and(|dest| dest.to_string_lossy().ends_with(" (deleted)"))
        });
        if !is_running || exe_deleted {
            return self.start().await;
        }
        let store_snapshot = { self.state.data.read().await.clone() };
        let cfg_val = config_gen::compile_core_config(&store_snapshot)?;
        let cfg_path = self
            .write_validated_core_config(&store_snapshot, &cfg_val)
            .await?
            .to_string_lossy()
            .to_string();
        if let Err(e) = net_stack::apply_network_stack(&store_snapshot).await {
            eprintln!("[tachyon] apply_network_stack failed during reload: {e:#}");
            self.state.live.write().await.push_event(
                "error",
                "net_stack",
                &format!("apply_network_stack failed: {e:#}"),
            );
        } else {
            self.state.live.write().await.nft_table_active =
                net_stack::check_nft_table_active().await;
        }
        let body = json!({ "path": cfg_path }).to_string();
        if self
            .clash_request("PUT", "/configs?force=true", Some(&body))
            .await
            .is_err()
        {
            return self.start().await;
        }
        self.restore_saved_selectors(&store_snapshot).await;
        Ok(())
    }

    pub async fn refresh_core_version(&self) -> String {
        let bin = self.resolve_bin_path().await;
        if let Ok(out) = Command::new(&bin).arg("version").output().await
            && out.status.success()
        {
            let text = String::from_utf8_lossy(&out.stdout);
            if let Some(ver) = extract_semver_token(&text) {
                let ver_path = crate::store::runtime_state_dir().join("tachyon-core-version");
                let _ = crypto_gen::write_file_if_changed(ver_path, format!("{ver}\n").as_bytes());
                self.state.live.write().await.core_version = ver.clone();
                return ver;
            }
        }
        self.state.live.read().await.core_version.clone()
    }

    async fn restore_saved_selectors(&self, store_snapshot: &crate::store::RouterStoreData) {
        let sel_path = crate::store::runtime_state_dir().join("selector_state.json");
        let mut sel_map: HashMap<String, String> = std::fs::read_to_string(&sel_path)
            .or_else(|_| std::fs::read_to_string("/etc/tachyon/selector_state.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        for sec in &store_snapshot.sections {
            if sec.enabled && !sec.active_selected_tag.trim().is_empty() {
                sel_map.insert(format!("sel-{}", sec.id), sec.active_selected_tag.clone());
                sel_map.insert(sec.id.clone(), sec.active_selected_tag.clone());
            }
        }
        if sel_map.is_empty() {
            return;
        }
        let proxies_resp = self.clash_request("GET", "/proxies", None).await.ok();
        let mut pruned_dirty = false;
        let mut validated = Vec::with_capacity(sel_map.len());
        for (group, tag) in &sel_map {
            let mut chosen = tag.clone();
            if let Some(ref body) = proxies_resp
                && let Some(all_arr) = body
                    .pointer(&format!("/proxies/{group}/all"))
                    .and_then(Value::as_array)
            {
                let in_pool = all_arr
                    .iter()
                    .filter_map(Value::as_str)
                    .any(|cand| cand == chosen);
                if !in_pool {
                    let default_cand = body
                        .pointer(&format!("/proxies/{group}/default"))
                        .and_then(Value::as_str)
                        .filter(|def_tag| {
                            all_arr
                                .iter()
                                .filter_map(Value::as_str)
                                .any(|cand| cand == *def_tag)
                        });
                    if let Some(fallback) =
                        default_cand.or_else(|| all_arr.iter().filter_map(Value::as_str).next())
                    {
                        chosen = fallback.to_string();
                        pruned_dirty = true;
                    } else {
                        continue;
                    }
                }
            }
            validated.push((group.clone(), chosen));
        }
        for (group, tag) in &validated {
            let encoded = group.replace(' ', "%20");
            let payload = json!({ "name": tag }).to_string();
            let _ = self
                .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&payload))
                .await;
            sel_map.insert(group.clone(), tag.clone());
        }
        if pruned_dirty && let Ok(raw) = serde_json::to_string_pretty(&sel_map) {
            let sel_path = crate::store::runtime_state_dir().join("selector_state.json");
            let _ = crypto_gen::write_file_if_changed(sel_path, raw.as_bytes());
        }
    }

    pub fn save_selector_choice(group_or_sec: &str, chosen_tag: &str) {
        let path = crate::store::runtime_state_dir().join("selector_state.json");
        let mut map: HashMap<String, String> = std::fs::read_to_string(&path)
            .or_else(|_| std::fs::read_to_string("/etc/tachyon/selector_state.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        map.insert(group_or_sec.to_string(), chosen_tag.to_string());
        let _ = crypto_gen::write_json_if_changed(path, &map);
    }

    /// Fetch an HTTP(S) URL via `curl` with optional local proxy and automatic DoH fallback
    /// (`dns.google`, `common.dot.dns.yandex.net`, `1.1.1.1`) when router UDP DNS is degraded.
    pub async fn curl_fetch_with_doh_fallback(
        &self,
        url: &str,
        include_headers: bool,
        timeout_secs: u64,
        proxy_url: Option<&str>,
    ) -> anyhow::Result<Vec<u8>> {
        let max_t = timeout_secs.max(4).to_string();
        let build_base_args = |inc_hdr: bool| -> Vec<String> {
            let mut a = Vec::with_capacity(12);
            if inc_hdr {
                a.push("-i".to_string());
            }
            a.extend([
                "-fsSL".to_string(),
                "--connect-timeout".to_string(),
                "3".to_string(),
                "--max-time".to_string(),
                max_t.clone(),
                "-A".to_string(),
                "tachyon-core/2.0".to_string(),
            ]);
            a
        };

        if let Some(px) = proxy_url.filter(|s| !s.trim().is_empty()) {
            let mut args = build_base_args(include_headers);
            args.push("-x".to_string());
            args.push(px.trim().to_string());
            args.push(url.to_string());
            if let Ok(out) = Command::new("curl").args(&args).output().await
                && out.status.success()
                && !out.stdout.is_empty()
            {
                return Ok(out.stdout);
            }
        }

        let mut direct_args = build_base_args(include_headers);
        direct_args.push(url.to_string());
        if let Ok(out) = Command::new("curl").args(&direct_args).output().await
            && out.status.success()
            && !out.stdout.is_empty()
        {
            return Ok(out.stdout);
        }

        for doh in [
            "https://1.1.1.1/dns-query",
            "https://dns.google/dns-query",
            "https://common.dot.dns.yandex.net/dns-query",
        ] {
            let mut doh_args = build_base_args(include_headers);
            doh_args.push("--doh-url".to_string());
            doh_args.push(doh.to_string());
            doh_args.push(url.to_string());
            if let Ok(out) = Command::new("curl").args(&doh_args).output().await {
                if out.status.success() && !out.stdout.is_empty() {
                    return Ok(out.stdout);
                }
                if out.status.code() == Some(22) {
                    // Remote returned HTTP 4xx/5xx — DNS/TLS already succeeded, skip remaining DoH retries.
                    break;
                }
            }
        }

        anyhow::bail!("curl fetch failed for {url}")
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
        static CACHED_CLASH_CRED: std::sync::Mutex<Option<(u64, String, String)>> =
            std::sync::Mutex::new(None);

        let (mut addr, mut secret, cfg_path) = {
            let d = self.state.data.read().await;
            (
                d.settings.clash_api_addr.clone(),
                d.settings.clash_api_secret.clone(),
                d.settings.core_config_path.clone(),
            )
        };
        for candidate_cfg in [cfg_path.as_str(), "/etc/tachyon-core/config.json"] {
            if let Ok(meta) = std::fs::metadata(candidate_cfg) {
                let mtime = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                if let Ok(guard) = CACHED_CLASH_CRED.lock()
                    && let Some((cached_mtime, ref c_addr, ref c_sec)) = *guard
                    && cached_mtime == mtime
                    && !c_addr.is_empty()
                {
                    addr = c_addr.clone();
                    secret = c_sec.clone();
                    break;
                }
                if let Ok(raw_cfg) = std::fs::read_to_string(candidate_cfg)
                    && let Ok(val) = serde_json::from_str::<Value>(&raw_cfg)
                    && let Some(clash_obj) = val.pointer("/experimental/clash_api")
                {
                    let raw_ext = clash_obj
                        .get("external_controller")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .trim();
                    let found_addr = if let Some(port) = raw_ext.strip_prefix("0.0.0.0:") {
                        format!("127.0.0.1:{port}")
                    } else if let Some(port) = raw_ext.strip_prefix("[::]:") {
                        format!("127.0.0.1:{port}")
                    } else if let Some(port) = raw_ext.strip_prefix(':') {
                        format!("127.0.0.1:{port}")
                    } else if !raw_ext.is_empty() {
                        raw_ext.to_string()
                    } else {
                        addr.clone()
                    };
                    let found_sec = clash_obj
                        .get("secret")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    addr = found_addr.clone();
                    secret = found_sec.clone();
                    if let Ok(mut guard) = CACHED_CLASH_CRED.lock() {
                        *guard = Some((mtime, found_addr, found_sec));
                    }
                    break;
                }
            }
        }
        let mut stream =
            tokio::time::timeout(Duration::from_secs(2), TcpStream::connect(&addr)).await??;
        let _ = stream.set_nodelay(true);
        let body_bytes = body.unwrap_or("").as_bytes();
        let auth_hdr = if secret.is_empty() {
            String::new()
        } else {
            format!("Authorization: Bearer {secret}\r\n")
        };
        let req = format!(
            "{method} {path} HTTP/1.0\r\nHost: {addr}\r\n{auth_hdr}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body_bytes.len()
        );
        stream.write_all(req.as_bytes()).await?;
        if !body_bytes.is_empty() {
            stream.write_all(body_bytes).await?;
        }
        let mut buf = Vec::with_capacity(65536);
        let mut chunk = [0u8; 16384];
        let mut expected_total: Option<usize> = None;
        let read_fut = async {
            loop {
                let n = stream.read(&mut chunk).await?;
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&chunk[..n]);
                if expected_total.is_none()
                    && let Some(hdr_end) = buf.windows(4).position(|w| w == b"\r\n\r\n")
                {
                    let body_start = hdr_end + 4;
                    let hdr_str = String::from_utf8_lossy(&buf[..hdr_end]);
                    for line in hdr_str.lines() {
                        if let Some((k, v)) = line.split_once(':')
                            && k.trim().eq_ignore_ascii_case("content-length")
                            && let Ok(cl) = v.trim().parse::<usize>()
                        {
                            expected_total = Some(body_start + cl);
                            break;
                        }
                    }
                }
                if let Some(exp) = expected_total
                    && buf.len() >= exp
                {
                    break;
                }
            }
            Ok::<(), std::io::Error>(())
        };
        tokio::time::timeout(Duration::from_secs(2), read_fut).await??;
        let raw = String::from_utf8_lossy(&buf);
        let (head_part, json_part) = raw.split_once("\r\n\r\n").unwrap_or(("", "{}"));
        let status_code = head_part
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|code| code.parse::<u16>().ok())
            .unwrap_or(200);
        if status_code >= 400 {
            anyhow::bail!(
                "clash api {method} {path} returned HTTP {status_code}: {}",
                json_part.trim()
            );
        }
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

        // Apply 50ms hysteresis switching on URLTest / balancer groups in Clash API
        if let Ok(proxies_resp) = self.clash_request("GET", "/proxies", None).await
            && let Some(proxies_obj) = proxies_resp.get("proxies").and_then(Value::as_object)
        {
            for (group_name, group_val) in proxies_obj {
                let gtype = group_val
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if gtype != "urltest" && gtype != "fallback" {
                    continue;
                }
                let Some(all_members) = group_val.get("all").and_then(Value::as_array) else {
                    continue;
                };
                let cur_now = group_val.get("now").and_then(Value::as_str).unwrap_or("");
                let cur_delay = results.get(cur_now).copied().unwrap_or(0);
                let mut best_tag = String::new();
                let mut best_delay = u32::MAX;
                for m in all_members.iter().filter_map(Value::as_str) {
                    if let Some(&d) = results.get(m)
                        && d > 0
                        && d < best_delay
                    {
                        best_delay = d;
                        best_tag = m.to_string();
                    }
                }
                if !best_tag.is_empty()
                    && best_tag != cur_now
                    && (cur_delay == 0 || best_delay.saturating_add(50) < cur_delay)
                {
                    let encoded = group_name.replace(' ', "%20");
                    let body = json!({ "name": best_tag }).to_string();
                    let _ = self
                        .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&body))
                        .await;
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

        if let Some(json_nodes) = config_gen::parse_json_subscription_payload(&decoded) {
            return json_nodes;
        }

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
        let mut core_reload_needed = false;
        let now = unix_now_secs();

        // Trigger native `tachyon-core` provider refresh if running
        let providers_map = self
            .clash_request("GET", "/providers/proxies", None)
            .await
            .ok();

        // Map section ID -> mixed_proxy_port for optional proxy-routed subscription fetches
        let sec_proxy_ports: HashMap<String, u16> = candidate
            .sections
            .iter()
            .filter(|s| s.enabled && s.mixed_proxy_enabled && s.mixed_proxy_port > 0)
            .map(|s| (s.id.clone(), s.mixed_proxy_port))
            .collect();
        let global_sub_proxy = if candidate.settings.download_lists_via_proxy {
            sec_proxy_ports
                .get(&candidate.settings.download_lists_via_proxy_section)
                .copied()
        } else {
            None
        };

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

            let proxy_opt = if src.download_via_proxy_enabled {
                sec_proxy_ports
                    .get(&src.download_via_proxy_section)
                    .copied()
                    .or(global_sub_proxy)
            } else {
                global_sub_proxy
            }
            .map(|p| format!("http://127.0.0.1:{p}"));

            let mut nodes = Vec::new();
            let urls = src.subscription_urls.clone();
            for url in &urls {
                if let Ok(stdout) = self
                    .curl_fetch_with_doh_fallback(url, true, 12, proxy_opt.as_deref())
                    .await
                {
                    let raw_resp = String::from_utf8_lossy(&stdout);
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
                if !nodes_materially_equal(&src.cached_nodes, &nodes) {
                    core_reload_needed = true;
                }
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
            if core_reload_needed {
                let _ = self.apply_or_reload().await;
            }
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
        Self::save_selector_choice(&format!("sel-{section_id}"), node_tag);

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
        let (rulesets_dir, torr_enabled, sub_count) = {
            let d = self.state.data.read().await;
            (
                d.settings.rulesets_dir.clone(),
                d.settings.torrserver_direct_enabled,
                d.outbound_sources.len(),
            )
        };
        let engine_variant = "tachyon-core".to_string();
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

        let data_dir = crate::snapshots::data_dir_for_state(&self.state);
        let tachyon_bak = crate::snapshots::read_backup_meta(&data_dir, "tachyon");
        let core_bak = crate::snapshots::read_backup_meta(&data_dir, "tachyon-core");

        let components = vec![
            json!({
                "id": "tachyon",
                "name": "Tachyon",
                "category": "core",
                "desc": "Основной сервис оркестрации, веб-интерфейс, REST/MCP агент и автономный Watchdog",
                "installed": true,
                "running": true,
                "pid": std::process::id(),
                "version": crate::store::TACHYON_VERSION,
                "latest": crate::store::TACHYON_VERSION,
                "repo": "Dushnilin/tachyon",
                "backup_version": tachyon_bak.as_ref().map(|m| m.version.as_str()).unwrap_or(""),
                "backup_time": tachyon_bak.as_ref().map(|m| m.backed_up_at).unwrap_or(0),
                "can_rollback": tachyon_bak.is_some() || self.state.lkg_path.exists()
            }),
            json!({
                "id": "tachyon-core",
                "name": "Tachyon Core",
                "category": "core",
                "desc": "Основной движок маршрутизации (включает встроенный Desync 2.0, FPTN и Tailscale endpoint)",
                "installed": true,
                "running": core_running,
                "pid": core_pid,
                "version": core_ver_str,
                "latest": core_ver_str,
                "variant": &engine_variant,
                "variants": ["tachyon-core"],
                "repo": "Dushnilin/tachyon-core",
                "backup_version": core_bak.as_ref().map(|m| m.version.as_str()).unwrap_or(""),
                "backup_time": core_bak.as_ref().map(|m| m.backed_up_at).unwrap_or(0),
                "can_rollback": core_bak.is_some()
                    || Path::new("/usr/bin/tachyon-core.prev").exists()
                    || Path::new("/usr/bin/tachyon-core.bak").exists()
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
                "id": "direct_bypass",
                "name": "Direct Bypass (cgroup / nftables)",
                "category": "service",
                "desc": "Прямой маршрут в обход туннелей для выбранных процессов и локальных служб роутера",
                "installed": true,
                "running": core_running,
                "pid": core_pid,
                "version": "встроен",
                "latest": "встроен",
                "repo": "Dushnilin/tachyon",
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
            "orchestrator_version": crate::store::TACHYON_VERSION,
            "orchestrator_latest": crate::store::TACHYON_VERSION,
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

    /// Ensure initial binary backups exist for `tachyon` and `tachyon-core` when `component_backup_enabled` is true.
    pub async fn ensure_initial_binary_backups(&self) {
        let (enabled, core_bin_cfg) = {
            let d = self.state.data.read().await;
            (
                d.settings.component_backup_enabled,
                d.settings.core_bin_path.clone(),
            )
        };
        if !enabled {
            return;
        }
        let core_ver = {
            let live = self.state.live.read().await;
            if live.core_version.is_empty() {
                "0.4.8".to_string()
            } else {
                live.core_version.clone()
            }
        };
        let data_dir = crate::snapshots::data_dir_for_state(&self.state);
        let _ = tokio::task::spawn_blocking(move || {
            if crate::snapshots::read_backup_meta(&data_dir, "tachyon").is_none() {
                let daemon_bin = crate::snapshots::resolve_tachyon_daemon_bin_path();
                if daemon_bin.is_file() {
                    let _ = crate::snapshots::backup_binary(
                        &data_dir,
                        "tachyon",
                        &daemon_bin,
                        crate::store::TACHYON_VERSION,
                    );
                }
            }
            if crate::snapshots::read_backup_meta(&data_dir, "tachyon-core").is_none() {
                let core_path = if !core_bin_cfg.trim().is_empty()
                    && Path::new(core_bin_cfg.trim()).is_file()
                {
                    Path::new(core_bin_cfg.trim()).to_path_buf()
                } else {
                    Path::new("/usr/bin/tachyon-core").to_path_buf()
                };
                if core_path.is_file() {
                    let _ = crate::snapshots::backup_binary(
                        &data_dir,
                        "tachyon-core",
                        &core_path,
                        &core_ver,
                    );
                }
            }
        })
        .await;
    }

    /// Run a background component/lists update or lifecycle action and record progress in `LiveTelemetry.jobs`.
    pub async fn run_update_job(&self, target: &str) -> Value {
        self.component_action(target, "update", None).await
    }

    /// Unified component lifecycle & update manager (`check`, `update`, `backup`, `restart`, `stop`, `rollback`, `set_variant`).
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

        let data_dir = crate::snapshots::data_dir_for_state(&self.state);
        let (backup_enabled, core_bin_cfg) = {
            let d = self.state.data.read().await;
            (
                d.settings.component_backup_enabled,
                d.settings.core_bin_path.clone(),
            )
        };
        let core_bin_path =
            if !core_bin_cfg.trim().is_empty() && Path::new(core_bin_cfg.trim()).is_file() {
                Path::new(core_bin_cfg.trim()).to_path_buf()
            } else {
                Path::new("/usr/bin/tachyon-core").to_path_buf()
            };
        let core_ver = {
            let live = self.state.live.read().await;
            if live.core_version.is_empty() {
                "0.4.8".to_string()
            } else {
                live.core_version.clone()
            }
        };

        if matches!(action, "update" | "install" | "reinstall") && backup_enabled {
            if component == "tachyon" {
                let src = crate::snapshots::resolve_tachyon_daemon_bin_path();
                let dd = data_dir.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    crate::snapshots::backup_binary(
                        &dd,
                        "tachyon",
                        &src,
                        crate::store::TACHYON_VERSION,
                    )
                })
                .await;
            } else if crate::snapshots::normalize_backup_component(component)
                == Some("tachyon-core")
            {
                let src = core_bin_path.clone();
                let dd = data_dir.clone();
                let cv = core_ver.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    crate::snapshots::backup_binary(&dd, "tachyon-core", &src, &cv)
                })
                .await;
            }
        }

        let res = match (component, action) {
            ("subscriptions", _) => {
                let cnt = self.refresh_all_subscriptions().await.unwrap_or(0);
                json!({ "ok": true, "component": component, "action": action, "updated_subscriptions": cnt, "message": format!("Обновлено подписок: {cnt}") })
            }
            ("lists" | "rulesets", _) => {
                let (rulesets_dir, github_mirror, list_names, proxy_opt) = {
                    let d = self.state.data.read().await;
                    let mut names = Vec::new();
                    for c in &d.conditions {
                        for l in &c.community_lists {
                            let cl = l.trim().to_string();
                            if !cl.is_empty() && !names.contains(&cl) {
                                names.push(cl);
                            }
                        }
                    }
                    for s in &d.sections {
                        for l in &s.community_lists {
                            let cl = l.trim().to_string();
                            if !cl.is_empty() && !names.contains(&cl) {
                                names.push(cl);
                            }
                        }
                    }
                    let px = if d.settings.download_lists_via_proxy {
                        d.sections
                            .iter()
                            .find(|s| {
                                s.enabled
                                    && s.id == d.settings.download_lists_via_proxy_section
                                    && s.mixed_proxy_enabled
                                    && s.mixed_proxy_port > 0
                            })
                            .map(|s| format!("http://127.0.0.1:{}", s.mixed_proxy_port))
                    } else {
                        None
                    };
                    (
                        d.settings.rulesets_dir.clone(),
                        d.settings.github_mirror.clone(),
                        names,
                        px,
                    )
                };
                let mut any_changed = false;
                if !rulesets_dir.trim().is_empty() {
                    let _ = std::fs::create_dir_all(&rulesets_dir);
                    for clean in &list_names {
                        let base_url = format!(
                            "https://github.com/Dushnilin/tachyon-lists/releases/latest/download/{clean}.trs"
                        );
                        let remote_url = if github_mirror.trim().is_empty() {
                            base_url
                        } else {
                            format!("{}/{}", github_mirror.trim_end_matches('/'), base_url)
                        };
                        if let Ok(bytes) = self
                            .curl_fetch_with_doh_fallback(
                                &remote_url,
                                false,
                                15,
                                proxy_opt.as_deref(),
                            )
                            .await
                            && !bytes.is_empty()
                        {
                            let dst = Path::new(&rulesets_dir).join(format!("{clean}.trs"));
                            if matches!(crypto_gen::write_file_if_changed(dst, &bytes), Ok(true)) {
                                any_changed = true;
                            }
                        }
                    }
                }
                if any_changed {
                    let _ = self.apply_or_reload().await;
                }
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
                let mut candidate = self.state.data.read().await.clone();
                candidate.settings.core_bin_path = "/usr/bin/tachyon-core".to_string();
                let _ = transaction::commit_transaction(&self.state, candidate).await;
                let _ = self.apply_or_reload().await;
                json!({ "ok": true, "component": component, "variant": variant.unwrap_or("tachyon-core"), "message": "Ядро tachyon-core активировано" })
            }
            (comp @ ("tachyon" | "tachyon-core" | "sing_box" | "sing-box"), "backup") => {
                let (src_bin, ver) = if comp == "tachyon" {
                    (
                        crate::snapshots::resolve_tachyon_daemon_bin_path(),
                        crate::store::TACHYON_VERSION.to_string(),
                    )
                } else {
                    (core_bin_path.clone(), core_ver.clone())
                };
                let dd = data_dir.clone();
                let comp_str = comp.to_string();
                match tokio::task::spawn_blocking(move || {
                    crate::snapshots::backup_binary(&dd, &comp_str, &src_bin, &ver)
                })
                .await
                {
                    Ok(Ok(meta)) => json!({
                        "ok": true,
                        "component": component,
                        "action": "backup",
                        "backup_version": meta.version,
                        "sha256": meta.sha256,
                        "size": meta.size,
                        "backed_up_at": meta.backed_up_at,
                        "message": format!("Создана резервная копия '{}' v{}", meta.component, meta.version)
                    }),
                    Ok(Err(e)) => json!({
                        "ok": false,
                        "component": component,
                        "action": "backup",
                        "error": format!("{e}")
                    }),
                    Err(e) => json!({
                        "ok": false,
                        "component": component,
                        "action": "backup",
                        "error": format!("{e}")
                    }),
                }
            }
            (_, "rollback") => {
                if let Some(norm) = crate::snapshots::normalize_backup_component(component)
                    && crate::snapshots::read_backup_meta(&data_dir, norm).is_some()
                {
                    let target_bin = if norm == "tachyon" {
                        crate::snapshots::resolve_tachyon_daemon_bin_path()
                    } else {
                        core_bin_path.clone()
                    };
                    let dd = data_dir.clone();
                    let norm_str = norm.to_string();
                    match tokio::task::spawn_blocking(move || {
                        crate::snapshots::rollback_binary(&dd, &norm_str, &target_bin)
                    })
                    .await
                    {
                        Ok(Ok(meta)) => {
                            if norm == "tachyon-core" {
                                let _ = self.stop().await;
                                let _ = self.start().await;
                            }
                            json!({
                                "ok": true,
                                "component": component,
                                "action": "rollback",
                                "changed": true,
                                "current_version": meta.version,
                                "sha256": meta.sha256,
                                "message": format!("Выполнен откат бинарной версии '{}' к {}", norm, meta.version)
                            })
                        }
                        Ok(Err(e)) => json!({
                            "ok": false,
                            "component": component,
                            "action": "rollback",
                            "error": format!("{e}")
                        }),
                        Err(e) => json!({
                            "ok": false,
                            "component": component,
                            "action": "rollback",
                            "error": format!("{e}")
                        }),
                    }
                } else if let Ok(restored) = transaction::load_known_good(&self.state.lkg_path) {
                    let _ = transaction::commit_transaction(&self.state, restored).await;
                    let _ = self.apply_or_reload().await;
                    json!({ "ok": true, "component": component, "action": "rollback", "changed": true, "message": "Выполнен откат к проверенной конфигурации (Last Known Good)" })
                } else {
                    json!({ "ok": false, "component": component, "error": "Резервная копия или снимок Last Known Good не найдены" })
                }
            }
            (_, "check") => {
                let info = self.check_updates().await;
                let disp = crate::updater::component_display_name(component);
                json!({ "ok": true, "component": component, "action": "check", "updates": info, "message": format!("Проверка состояния '{disp}' завершена") })
            }
            (_, "reload" | "restart") => {
                let disp = crate::updater::component_display_name(component);
                let _ = self.apply_or_reload().await;
                json!({ "ok": true, "component": component, "action": action, "message": format!("{disp} перезапущен") })
            }
            _ => {
                let disp = crate::updater::component_display_name(component);
                json!({ "ok": false, "component": component, "action": action, "message": format!("Действие '{action}' для {disp} требует запуска через updater") })
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
                && let Ok(stdout) = self.curl_fetch_with_doh_fallback(l, true, 10, None).await
            {
                let raw_resp = String::from_utf8_lossy(&stdout);
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
                if tick_count == 10 || tick_count.is_multiple_of(200) {
                    let upd_mgr = Arc::clone(&mgr);
                    tokio::spawn(async move {
                        crate::updater::maybe_run_auto_update_tick(&upd_mgr).await;
                    });
                }
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
            let (watchdog_on, proxy_mode, lite_mode) = {
                let d = self.state.data.read().await;
                (
                    d.settings.enable_watchdog,
                    d.settings.proxy_mode.clone(),
                    d.settings.lite_mode,
                )
            };
            let nft_ok = net_stack::check_nft_table_active().await;
            let data_plane_busy = sys_info::is_lite_data_plane_busy(lite_mode);

            let devices_opt = if !data_plane_busy {
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
                                reachable: cd
                                    .get("reachable")
                                    .and_then(Value::as_bool)
                                    .unwrap_or(true),
                                ..Default::default()
                            });
                            devices.last_mut().unwrap()
                        };
                        existing.upload_bytes =
                            cd.get("upload").and_then(Value::as_u64).unwrap_or(0);
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
                        existing.upload_bps =
                            cd.get("upload_bps").and_then(Value::as_u64).unwrap_or(0);
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
                Some(devices)
            } else {
                None
            };

            {
                let mut live = self.state.live.write().await;
                live.nft_table_active = nft_ok;
                if let Some(devices) = devices_opt {
                    live.lan_devices = devices;
                }
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

fn extract_semver_token(raw: &str) -> Option<String> {
    for tok in raw.split(|c: char| !c.is_ascii_alphanumeric() && c != '.' && c != '-') {
        let trimmed = tok.trim_start_matches(['v', 'V']);
        let parts: Vec<&str> = trimmed.split('.').collect();
        if parts.len() >= 2
            && parts
                .iter()
                .take(2)
                .all(|p| !p.is_empty() && p.chars().all(|ch| ch.is_ascii_digit()))
        {
            return Some(trimmed.to_string());
        }
    }
    None
}

/// Strip volatile `tls.reality.short_id` rotation before comparing fetched subscription nodes
/// against cached nodes (`aeab04d18`), avoiding pointless core reloads on CDN short_id rotation.
fn canonical_node_fingerprint(node: &crate::store::ParsedProxyNode) -> Value {
    let mut obj = node.outbound_json.clone();
    if let Some(reality) = obj
        .get_mut("tls")
        .and_then(|v| v.get_mut("reality"))
        .and_then(Value::as_object_mut)
    {
        reality.remove("short_id");
    }
    json!({
        "tag": node.tag,
        "protocol": node.protocol,
        "server": node.server,
        "server_port": node.server_port,
        "outbound": obj,
    })
}

fn nodes_materially_equal(
    old_nodes: &[crate::store::ParsedProxyNode],
    new_nodes: &[crate::store::ParsedProxyNode],
) -> bool {
    if old_nodes.len() != new_nodes.len() {
        return false;
    }
    old_nodes
        .iter()
        .zip(new_nodes.iter())
        .all(|(a, b)| canonical_node_fingerprint(a) == canonical_node_fingerprint(b))
}

#[cfg(test)]
mod core_mgr_tests {
    use super::*;
    use crate::store::ParsedProxyNode;

    #[test]
    fn test_extract_semver_token_and_short_id_ignore() {
        assert_eq!(
            extract_semver_token("tachyon-core version v0.5.1\n").as_deref(),
            Some("0.5.1")
        );
        let mk = |sid: &str| ParsedProxyNode {
            tag: "de-1".to_string(),
            protocol: "vless".to_string(),
            server: "1.2.3.4".to_string(),
            server_port: 443,
            country: "DE".to_string(),
            raw_uri: String::new(),
            outbound_json: json!({
                "type": "vless",
                "server": "1.2.3.4",
                "server_port": 443,
                "tls": { "enabled": true, "reality": { "enabled": true, "short_id": sid } }
            }),
        };
        assert!(nodes_materially_equal(&[mk("abcd")], &[mk("ef01")]));
        let mut changed = mk("ef01");
        changed.server_port = 8443;
        assert!(!nodes_materially_equal(&[mk("abcd")], &[changed]));
    }

    #[test]
    fn test_parse_subscription_payload_json_and_base64_json() {
        let singbox_json = json!({
            "outbounds": [
                {
                    "type": "vless",
                    "tag": "🇳🇱 Amsterdam",
                    "server": "198.51.100.10",
                    "server_port": 443,
                    "uuid": "22222222-2222-4222-8222-222222222222"
                }
            ]
        })
        .to_string();
        let plain_nodes = CoreManager::parse_subscription_payload(&singbox_json);
        assert_eq!(plain_nodes.len(), 1);
        assert_eq!(plain_nodes[0].tag, "🇳🇱 Amsterdam");
        assert_eq!(plain_nodes[0].country, "NL");

        let b64_payload = B64_STD.encode(singbox_json.as_bytes());
        let b64_nodes = CoreManager::parse_subscription_payload(&b64_payload);
        assert_eq!(b64_nodes.len(), 1);
        assert_eq!(b64_nodes[0].tag, "🇳🇱 Amsterdam");
    }
}
