//! `tachyon-core` process lifecycle manager, Clash API & `/tachyon/*` client,
//! Autonomous Watchdog + Reconciler loop, subscription fetcher, and parallel RTT prober.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::{
    STANDARD as B64_STD, STANDARD_NO_PAD as B64_STD_NO_PAD, URL_SAFE as B64_URL_PAD,
    URL_SAFE_NO_PAD as B64_URL,
};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use tokio::time::Instant as TokioInstant;

use crate::config_gen;
use crate::crypto_gen;
use crate::net_stack;
use crate::store::{
    AppState, MAX_NODE_LATENCIES, MAX_THROUGHPUT_POINTS, ParsedProxyNode, PortableAtomicU64,
    ThroughputSample, unix_now_secs,
};
use crate::sys_info;
use crate::transaction;

const TELEMETRY_ACTIVE_WINDOW_SECS: u64 = 15;

#[derive(Debug, Clone, Copy)]
struct TrafficSampleBaseline {
    pid: Option<u32>,
    total_up: u64,
    total_down: u64,
    sampled_at: TokioInstant,
}

fn compute_rate_bps(prev_bytes: u64, curr_bytes: u64, elapsed: Duration) -> u64 {
    if curr_bytes < prev_bytes {
        return 0;
    }
    let nanos = elapsed.as_nanos();
    if nanos < Duration::from_millis(50).as_nanos() {
        return 0;
    }
    let delta_bytes = u128::from(curr_bytes - prev_bytes);
    let bps = delta_bytes.saturating_mul(1_000_000_000) / nanos;
    u64::try_from(bps).unwrap_or(u64::MAX)
}

fn telemetry_poll_interval() -> tokio::time::Interval {
    telemetry_poll_interval_with(Duration::from_secs(3))
}

fn telemetry_poll_interval_with(period: Duration) -> tokio::time::Interval {
    let mut interval = tokio::time::interval(period);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    interval
}

pub struct CoreManager {
    pub state: Arc<AppState>,
    proc: Mutex<Option<(Child, Instant)>>,
    reload_lock: Mutex<()>,
    sub_refresh_lock: Mutex<()>,
    prev_totals: Mutex<Option<TrafficSampleBaseline>>,
    intentional_stop: AtomicBool,
    last_ipv6_resync_ts: PortableAtomicU64,
}

impl CoreManager {
    pub fn new(state: Arc<AppState>) -> Arc<Self> {
        Arc::new(Self {
            state,
            proc: Mutex::new(None),
            reload_lock: Mutex::new(()),
            sub_refresh_lock: Mutex::new(()),
            prev_totals: Mutex::new(None),
            intentional_stop: AtomicBool::new(false),
            last_ipv6_resync_ts: PortableAtomicU64::new(0),
        })
    }

    pub fn manual_stop_marker_path(&self) -> PathBuf {
        Self::manual_stop_marker_path_for(&self.state)
    }

    pub fn manual_stop_marker_path_for(state: &AppState) -> PathBuf {
        #[cfg(test)]
        {
            state.path.with_file_name(".manual_stop")
        }
        #[cfg(not(test))]
        {
            let _ = state;
            crate::store::runtime_state_dir().join("manual_stop")
        }
    }

    pub fn is_manual_stop_active(state: &AppState) -> bool {
        Self::manual_stop_marker_path_for(state).exists()
    }

    pub fn set_manual_stop(&self, stopped: bool) {
        self.intentional_stop.store(stopped, Ordering::SeqCst);
        let marker = self.manual_stop_marker_path();
        if stopped {
            if let Some(parent) = marker.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(&marker, b"1\n");
        } else {
            let _ = std::fs::remove_file(&marker);
        }
    }

    pub fn is_manually_stopped(&self) -> bool {
        let marker_exists = self.manual_stop_marker_path().exists();
        if marker_exists {
            self.intentional_stop.store(true, Ordering::SeqCst);
            return true;
        }
        false
    }

    pub async fn is_watchdog_effectively_running(&self) -> bool {
        let enabled = { self.state.data.read().await.settings.enable_watchdog };
        enabled && !self.is_manually_stopped()
    }

    async fn run_command_output_with_timeout(
        cmd: &mut Command,
        timeout: Duration,
    ) -> std::io::Result<std::process::Output> {
        cmd.kill_on_drop(true);
        match tokio::time::timeout(timeout, cmd.output()).await {
            Ok(res) => res,
            Err(_) => Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("command timed out after {}ms", timeout.as_millis()),
            )),
        }
    }

    async fn run_curl_args(
        args: &[String],
        timeout: Duration,
    ) -> std::io::Result<std::process::Output> {
        let mut cmd = Command::new("curl");
        cmd.args(args);
        Self::run_command_output_with_timeout(&mut cmd, timeout).await
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

    pub fn normalize_unknown_field_reason(reason: &str) -> String {
        let mut out = reason.replace(": unknown field ", ": json: unknown field ");
        while out.contains(": json: json: unknown field ") {
            out = out.replace(": json: json: unknown field ", ": json: unknown field ");
        }
        for section in ["log", "ntp", "route", "dns"] {
            let needle = format!("{section}: ");
            let mut rebuilt = String::with_capacity(out.len());
            let mut rest = out.as_str();
            while let Some(pos) = rest.find(&needle) {
                let is_boundary = pos == 0 || rest[..pos].ends_with(": ");
                rebuilt.push_str(&rest[..pos]);
                let after = &rest[pos + needle.len()..];
                if is_boundary && let Some(uk_pos) = after.find(": json: unknown field ") {
                    let field_part = &after[..uk_pos];
                    if !field_part.is_empty()
                        && field_part
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.')
                    {
                        rebuilt.push_str(section);
                        rebuilt.push('.');
                        rebuilt.push_str(field_part);
                        rebuilt.push_str(": json: unknown field ");
                        rest = &after[uk_pos + ": json: unknown field ".len()..];
                        continue;
                    }
                }
                rebuilt.push_str(&needle);
                rest = after;
            }
            rebuilt.push_str(rest);
            out = rebuilt;
        }
        out
    }

    pub fn bytes_have_valid_trs_magic(bytes: &[u8]) -> bool {
        bytes.len() >= 16
            && (bytes.starts_with(b"TRS")
                || bytes.starts_with(b"TSRS")
                || bytes.starts_with(b"TCRS"))
    }

    pub fn file_has_valid_trs_magic(path: &Path) -> bool {
        let Ok(mut f) = std::fs::File::open(path) else {
            return false;
        };
        let Ok(meta) = f.metadata() else {
            return false;
        };
        if meta.len() < 16 {
            return false;
        }
        use std::io::Read as _;
        let mut hdr = [0u8; 4];
        if f.read_exact(&mut hdr).is_err() {
            return false;
        }
        hdr.starts_with(b"TRS") || hdr == *b"TSRS" || hdr == *b"TCRS"
    }

    pub fn sanitize_candidate_local_rulesets(candidate_cfg: &mut Value) {
        let tmp_rs_dir = std::env::temp_dir().join("tachyon-rulesets");
        let persistent_dir = std::env::var("TACHYON_PERSISTENT_RULESETS_DIR")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/etc/tachyon/rulesets"));

        let Some(rule_sets) = candidate_cfg
            .pointer_mut("/route/rule_set")
            .and_then(Value::as_array_mut)
        else {
            return;
        };
        for rs in rule_sets {
            let Some(obj) = rs.as_object_mut() else {
                continue;
            };
            if obj.get("type").and_then(Value::as_str) != Some("local") {
                continue;
            }
            let Some(rs_path_str) = obj.get("path").and_then(Value::as_str).map(str::to_string)
            else {
                continue;
            };
            if !rs_path_str.ends_with(".trs") {
                continue;
            }
            let rs_path = Path::new(&rs_path_str);
            if Self::file_has_valid_trs_magic(rs_path) {
                continue;
            }
            let fname = rs_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("ruleset.trs");
            let etc_file = persistent_dir.join(fname);
            if Self::file_has_valid_trs_magic(&etc_file)
                && let Ok(bytes) = std::fs::read(&etc_file)
            {
                if let Some(parent) = rs_path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if std::fs::write(rs_path, &bytes).is_ok() {
                    continue;
                }
            }
            // Never write an SRS stub to a .trs path: remove corrupt file and switch
            // the candidate check entry to an empty JSON source rule-set.
            let _ = std::fs::remove_file(rs_path);
            let _ = std::fs::create_dir_all(&tmp_rs_dir);
            let empty_name = fname.strip_suffix(".trs").unwrap_or(fname);
            let fallback_json = tmp_rs_dir.join(format!("{empty_name}.empty.json"));
            let _ = std::fs::write(&fallback_json, br#"{"version":3,"rules":[]}"#);
            obj.insert("format".into(), json!("source"));
            obj.insert("path".into(), json!(fallback_json.to_string_lossy()));
        }
    }

    pub fn effective_core_config_path_for(
        state: &AppState,
        settings: &crate::store::GlobalSettings,
    ) -> PathBuf {
        let state_dir = state.path.parent().unwrap_or_else(|| Path::new("data"));
        let is_tmp_staging = state_dir.to_string_lossy().starts_with("/tmp/tachyon-rs")
            && Path::new("/etc/init.d/tachyon").exists();
        if is_tmp_staging {
            return state_dir.join("tachyon-core-config.json");
        }
        let configured = settings.core_config_path.trim();
        if configured.is_empty() {
            PathBuf::from("/etc/tachyon-core/config.json")
        } else {
            PathBuf::from(configured)
        }
    }

    pub fn core_config_ipv6_matches(
        cfg_path: &Path,
        store_snapshot: &crate::store::RouterStoreData,
        ipv6_state: crate::store::EffectiveIpv6State,
    ) -> bool {
        let Ok(raw) = std::fs::read_to_string(cfg_path) else {
            return true;
        };
        let Ok(runtime) = serde_json::from_str::<Value>(&raw) else {
            return true;
        };
        let Some(dns_servers) = runtime.pointer("/dns/servers").and_then(Value::as_array) else {
            return true;
        };
        let want_fakeip6 = ipv6_state.is_active() && store_snapshot.settings.fakeip_enabled;
        for srv in dns_servers {
            if srv.get("type").and_then(Value::as_str) == Some("fakeip") {
                let has_fakeip6 = srv
                    .get("inet6_range")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.trim().is_empty());
                if has_fakeip6 != want_fakeip6 {
                    return false;
                }
            }
        }
        true
    }

    fn strip_optional_unknown_fields(cfg_val: &mut Value, reason: &str) -> bool {
        let norm = Self::normalize_unknown_field_reason(reason);
        let mut changed = false;
        for field in ["tcp_profile", "tcp_fragment"] {
            if norm.contains(&format!("json: unknown field \"{field}\""))
                || norm.contains(&format!("unknown field `{field}`"))
            {
                if let Some(obs) = cfg_val.get_mut("outbounds").and_then(Value::as_array_mut) {
                    for ob in obs {
                        if let Some(map) = ob.as_object_mut()
                            && map.remove(field).is_some()
                        {
                            changed = true;
                        }
                    }
                }
                if let Some(eps) = cfg_val.get_mut("endpoints").and_then(Value::as_array_mut) {
                    for ep in eps {
                        if let Some(map) = ep.as_object_mut()
                            && map.remove(field).is_some()
                        {
                            changed = true;
                        }
                    }
                }
            }
        }
        changed
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

        let mut candidate_cfg = cfg_val.clone();
        Self::sanitize_candidate_local_rulesets(&mut candidate_cfg);
        let tmp_check_path = std::env::temp_dir().join("tachyon-core-candidate.json");
        crypto_gen::write_json_if_changed(&tmp_check_path, &candidate_cfg)?;

        let bin_path = self.resolve_bin_path().await;
        if cfg!(target_os = "linux") && Path::new(&bin_path).exists() {
            for attempt in 0..=2 {
                let mut cmd = Command::new(&bin_path);
                cmd.args(["check", "-c", &tmp_check_path.to_string_lossy()]);
                match Self::run_command_output_with_timeout(&mut cmd, Duration::from_secs(15)).await
                {
                    Ok(out) if !out.status.success() => {
                        let stderr = String::from_utf8_lossy(&out.stderr);
                        let stdout = String::from_utf8_lossy(&out.stdout);
                        let combined = format!("{}{}", stderr.trim(), stdout.trim());
                        if attempt < 2
                            && Self::strip_optional_unknown_fields(&mut candidate_cfg, &combined)
                        {
                            crypto_gen::write_json_if_changed(&tmp_check_path, &candidate_cfg)?;
                            continue;
                        }
                        anyhow::bail!("tachyon-core check failed: {combined}");
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                        anyhow::bail!("tachyon-core check timed out after 15s");
                    }
                    _ => break,
                }
            }
        }

        if is_tmp_staging {
            let staging_cfg = state_dir.join("tachyon-core-config.json");
            crypto_gen::write_json_if_changed(&staging_cfg, &candidate_cfg)?;
            return Ok(staging_cfg);
        }

        let p = Path::new(&store_snapshot.settings.core_config_path);
        if crypto_gen::write_json_if_changed(p, &candidate_cfg).is_ok() {
            Ok(p.to_path_buf())
        } else {
            let fallback = state_dir.join("tachyon-core-config.json");
            crypto_gen::write_json_if_changed(&fallback, &candidate_cfg)?;
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
        self.set_manual_stop(false);
        let _guard = self.reload_lock.lock().await;
        let store_snapshot = { self.state.data.read().await.clone() };
        let veto = net_stack::hold_kill_switch(&store_snapshot).await;
        self.stop_locked().await;

        let cleanup_failed_start = |veto_active: bool, msg: String| {
            let state = Arc::clone(&self.state);
            async move {
                net_stack::teardown_network_stack_with_mode(veto_active).await;
                let mut live = state.live.write().await;
                live.core_running = false;
                live.core_pid = None;
                live.core_identity = None;
                live.nft_table_active = false;
                live.push_event("error", "core_mgr", &msg);
            }
        };

        let startup_wan6 = crate::store::probe_wan6_runtime_state();
        let startup_ipv6_state = crate::store::resolve_effective_ipv6_state(
            &store_snapshot.settings,
            startup_wan6.wan6_available,
        );
        Self::ensure_runtime_cache_dir(&store_snapshot.settings.cache_path);
        let cfg_val = match config_gen::compile_core_config(&store_snapshot) {
            Ok(v) => v,
            Err(e) => {
                cleanup_failed_start(veto.is_some(), format!("config compile failed: {e:#}")).await;
                return Err(e);
            }
        };
        let cfg_path = match self
            .write_validated_core_config(&store_snapshot, &cfg_val)
            .await
        {
            Ok(p) => p,
            Err(e) => {
                cleanup_failed_start(veto.is_some(), format!("config validation failed: {e:#}"))
                    .await;
                return Err(e);
            }
        };

        let bin_path = self.resolve_bin_path().await;
        if !Path::new(&bin_path).exists() {
            let err = anyhow::anyhow!("tachyon-core binary not found at '{bin_path}'");
            cleanup_failed_start(veto.is_some(), err.to_string()).await;
            return Err(err);
        }

        let mut cmd = Command::new(&bin_path);
        cmd.args(["run", "-c", &cfg_path.to_string_lossy()])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                cleanup_failed_start(veto.is_some(), format!("tachyon-core spawn failed: {e:#}"))
                    .await;
                return Err(e.into());
            }
        };
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
        let post_wan6 = crate::store::probe_wan6_runtime_state();
        let post_ipv6_state = crate::store::resolve_effective_ipv6_state(
            &store_snapshot.settings,
            post_wan6.wan6_available,
        );
        if post_ipv6_state != startup_ipv6_state && !self.is_manually_stopped() {
            self.state.live.write().await.push_event(
                "info",
                "core_mgr",
                &format!(
                    "IPv6 effective state changed during startup ({} -> {}); resynchronizing runtime",
                    startup_ipv6_state.as_str(),
                    post_ipv6_state.as_str(),
                ),
            );
            if let Ok(re_cfg_val) = config_gen::compile_core_config(&store_snapshot)
                && let Ok(re_cfg_path) = self
                    .write_validated_core_config(&store_snapshot, &re_cfg_val)
                    .await
            {
                let _ = net_stack::apply_network_stack(&store_snapshot).await;
                let payload = json!({ "path": re_cfg_path, "payload": "" }).to_string();
                if self
                    .clash_request("PUT", "/configs?force=true", Some(&payload))
                    .await
                    .is_ok()
                {
                    self.restore_saved_selectors(&store_snapshot).await;
                }
            }
        }
        Ok(())
    }

    fn service_autostart_enabled() -> bool {
        if cfg!(not(target_os = "linux")) {
            return false;
        }
        std::fs::read_dir("/etc/rc.d").ok().is_some_and(|rd| {
            rd.flatten().any(|e| {
                let name = e.file_name();
                let s = name.to_string_lossy();
                s.starts_with('S') && s.ends_with("tachyon") && !s.ends_with("tachyon-core")
            })
        })
    }

    pub async fn stop(&self) -> anyhow::Result<()> {
        self.set_manual_stop(true);
        let _guard = self.reload_lock.lock().await;
        let store_snapshot = { self.state.data.read().await.clone() };
        let keep_fail_closed = if Self::service_autostart_enabled() {
            net_stack::hold_kill_switch(&store_snapshot).await.is_some()
        } else {
            net_stack::remove_kill_switch().await;
            false
        };
        self.stop_locked().await;
        net_stack::teardown_network_stack_with_mode(keep_fail_closed).await;
        let mut live = self.state.live.write().await;
        live.core_running = false;
        live.core_pid = None;
        live.core_identity = None;
        live.nft_table_active = false;
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
                let _ = tokio::time::timeout(
                    Duration::from_secs(2),
                    Command::new("kill")
                        .args(["-TERM", &ext_pid.to_string()])
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .kill_on_drop(true)
                        .status(),
                )
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
                    let _ = tokio::time::timeout(
                        Duration::from_secs(2),
                        Command::new("kill")
                            .args(["-KILL", &ext_pid.to_string()])
                            .stdout(Stdio::null())
                            .stderr(Stdio::null())
                            .kill_on_drop(true)
                            .status(),
                    )
                    .await;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
        *self.prev_totals.lock().await = None;
        let mut live = self.state.live.write().await;
        live.core_running = false;
        live.core_pid = None;
        live.core_identity = None;
        live.core_uptime_secs = 0;
        live.core_rss_bytes = 0;
        live.total_up_bps = 0;
        live.total_down_bps = 0;
        live.total_up_bytes = 0;
        live.total_down_bytes = 0;
        live.active_connections = 0;
        live.dns_healthy = false;
        for dev in &mut live.lan_devices {
            dev.upload_bps = 0;
            dev.download_bps = 0;
            dev.active_sessions = 0;
        }
    }

    /// Hot-reload `tachyon-core` via `PUT /configs` on Clash API, or restart if not running.
    pub async fn apply_or_reload(&self) -> anyhow::Result<()> {
        let reload_guard = self.reload_lock.lock().await;
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
            // Release reload_lock before calling start(), which acquires reload_lock itself.
            drop(reload_guard);
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
            // Release reload_lock before falling back to start() to avoid self-deadlock.
            drop(reload_guard);
            return self.start().await;
        }
        self.restore_saved_selectors(&store_snapshot).await;
        drop(reload_guard);
        Ok(())
    }

    pub async fn refresh_core_version(&self) -> String {
        self.refresh_core_version_with_timeout(Duration::from_secs(5))
            .await
    }

    async fn refresh_core_version_with_timeout(&self, timeout: Duration) -> String {
        let bin = self.resolve_bin_path().await;
        let mut cmd = Command::new(&bin);
        cmd.arg("version");
        if let Ok(out) = Self::run_command_output_with_timeout(&mut cmd, timeout).await
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
            let encoded = crate::store::url_encode_component(group);
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
    async fn resolve_url_host_via_bootstrap_dns(&self, url: &str) -> Option<String> {
        let (host, port) = parse_http_url_host_port(url)?;
        if host.parse::<std::net::IpAddr>().is_ok() {
            return None;
        }
        let (boot_servers, fakeip_v4, fakeip_v6) = {
            let d = self.state.data.read().await;
            let v4 = if d.settings.fakeip_inet4_range.trim().is_empty() {
                "198.18.0.0/15".to_string()
            } else {
                d.settings.fakeip_inet4_range.trim().to_string()
            };
            let v6 = if d.settings.fakeip_inet6_range.trim().is_empty() {
                "fc00::/18".to_string()
            } else {
                d.settings.fakeip_inet6_range.trim().to_string()
            };
            (d.settings.bootstrap_dns_servers.clone(), v4, v6)
        };
        let mut servers: Vec<std::net::SocketAddr> = Vec::new();
        for raw in
            boot_servers
                .iter()
                .map(String::as_str)
                .chain(["77.88.8.8", "1.1.1.1", "8.8.8.8"])
        {
            if let Some(addr) = normalize_bootstrap_dns_addr(raw)
                && !servers.contains(&addr)
            {
                servers.push(addr);
            }
        }

        for qtype in [1u16, 28u16] {
            let query = crate::diagnostics::build_dns_query_packet(&host, qtype)?;
            for srv in &servers {
                let bind_addr = if srv.is_ipv6() { "[::]:0" } else { "0.0.0.0:0" };
                let Ok(sock) = tokio::net::UdpSocket::bind(bind_addr).await else {
                    continue;
                };
                if tokio::time::timeout(Duration::from_millis(800), sock.send_to(&query, *srv))
                    .await
                    .is_err()
                {
                    continue;
                }
                let mut buf = [0u8; 512];
                let Ok(Ok((n, _))) =
                    tokio::time::timeout(Duration::from_millis(900), sock.recv_from(&mut buf))
                        .await
                else {
                    continue;
                };
                let (is_fakeip, ip, rcode) = crate::diagnostics::parse_dns_fakeip_response(
                    &buf[..n],
                    &fakeip_v4,
                    &fakeip_v6,
                );
                if rcode == 0
                    && !is_fakeip
                    && !ip.is_empty()
                    && ip.parse::<std::net::IpAddr>().is_ok()
                {
                    return Some(format!("{host}:{port}:{ip}"));
                }
            }
        }
        None
    }

    /// Fetch URL via `curl` with optional HTTP/SOCKS proxy, bootstrap non-FakeIP `--resolve`,
    /// and multi-resolver DoH fallback (`1.1.1.1`, `dns.google`, `common.dot.dns.yandex.net`).
    pub async fn curl_fetch_with_doh_fallback(
        &self,
        url: &str,
        include_headers: bool,
        timeout_secs: u64,
        proxy_url: Option<&str>,
    ) -> anyhow::Result<Vec<u8>> {
        self.curl_fetch_with_options(url, include_headers, timeout_secs, proxy_url, None)
            .await
    }

    pub async fn curl_fetch_with_options(
        &self,
        url: &str,
        include_headers: bool,
        timeout_secs: u64,
        proxy_url: Option<&str>,
        user_agent: Option<&str>,
    ) -> anyhow::Result<Vec<u8>> {
        let max_t = timeout_secs.max(4).to_string();
        let ua = user_agent
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("tachyon-core/2.0");
        let build_base_args = |inc_hdr: bool| -> Vec<String> {
            let mut a = Vec::with_capacity(14);
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
                ua.to_string(),
            ]);
            a
        };

        let cmd_timeout = Duration::from_secs(timeout_secs.max(4).saturating_add(3));
        if let Some(px) = proxy_url.filter(|s| !s.trim().is_empty()) {
            let mut args = build_base_args(include_headers);
            args.push("-x".to_string());
            args.push(px.trim().to_string());
            args.push(url.to_string());
            if let Ok(out) = Self::run_curl_args(&args, cmd_timeout).await
                && out.status.success()
                && !out.stdout.is_empty()
            {
                return Ok(out.stdout);
            }
        }

        let mut direct_args = build_base_args(include_headers);
        if let Some(resolve_spec) = self.resolve_url_host_via_bootstrap_dns(url).await {
            direct_args.push("--resolve".to_string());
            direct_args.push(resolve_spec);
        }
        direct_args.push(url.to_string());
        if let Ok(out) = Self::run_curl_args(&direct_args, cmd_timeout).await
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
            if let Ok(out) = Self::run_curl_args(&doh_args, cmd_timeout).await {
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
        static CACHED_CLASH_CRED: std::sync::Mutex<Option<(String, u128, String, String)>> =
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
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                if let Ok(guard) = CACHED_CLASH_CRED.lock()
                    && let Some((ref cached_path, cached_mtime, ref c_addr, ref c_sec)) = *guard
                    && cached_path == candidate_cfg
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
                        *guard = Some((candidate_cfg.to_string(), mtime, found_addr, found_sec));
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
                    let status_code = hdr_str
                        .lines()
                        .next()
                        .and_then(|line| line.split_whitespace().nth(1))
                        .and_then(|code| code.parse::<u16>().ok())
                        .unwrap_or(200);
                    if status_code == 204 || status_code == 304 || (100..200).contains(&status_code)
                    {
                        expected_total = Some(body_start);
                    } else {
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
                }
                if let Some(exp) = expected_total
                    && buf.len() >= exp
                {
                    break;
                }
            }
            Ok::<(), std::io::Error>(())
        };
        let read_timeout = if path.contains("/delay") {
            let query_ms = path
                .split_once('?')
                .and_then(|(_, q)| {
                    q.split('&').find_map(|kv| {
                        let (k, v) = kv.split_once('=')?;
                        if k == "timeout" {
                            v.parse::<u64>().ok()
                        } else {
                            None
                        }
                    })
                })
                .or_else(|| {
                    body.and_then(|b| serde_json::from_str::<Value>(b).ok())
                        .and_then(|v| v.get("timeout").and_then(Value::as_u64))
                })
                .unwrap_or(if path.contains("delay-batch") {
                    5000
                } else {
                    3500
                });
            if path.contains("/group/") || path.contains("delay-batch") {
                Duration::from_millis(
                    query_ms
                        .saturating_mul(4)
                        .max(query_ms.saturating_add(12_000))
                        .clamp(15_000, 45_000),
                )
            } else {
                Duration::from_millis(query_ms.saturating_add(2000).clamp(3000, 30_000))
            }
        } else {
            Duration::from_secs(2)
        };
        tokio::time::timeout(read_timeout, read_fut).await??;
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
        let mut seen_tags = HashSet::new();
        let mut unique_nodes = Vec::with_capacity(nodes.len());
        for item in nodes {
            if seen_tags.insert(item.0.clone()) {
                unique_nodes.push(item);
            }
        }
        let names: Vec<String> = unique_nodes.iter().map(|(t, _, _)| t.clone()).collect();
        for chunk in names.chunks(64) {
            let batch_body = json!({
                "names": chunk,
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

        let sem = Arc::new(tokio::sync::Semaphore::new(24));
        let mut handles = Vec::new();
        for (tag, host, port) in unique_nodes {
            if results.contains_key(&tag) || host.is_empty() || port == 0 {
                continue;
            }
            let sem = Arc::clone(&sem);
            handles.push(tokio::spawn(async move {
                let _permit = sem.acquire_owned().await.ok();
                let start = Instant::now();
                let addr = format!("{host}:{port}");
                let ok =
                    tokio::time::timeout(Duration::from_millis(1800), TcpStream::connect(&addr))
                        .await
                        .is_ok_and(|r| r.is_ok());
                let ms = if ok {
                    (start.elapsed().as_millis() as u32).max(1)
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
                    let encoded = crate::store::url_encode_component(group_name);
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
        let (latency_url, host_port) = {
            let d = self.state.data.read().await;
            let mut found = None;
            'outer: for src in &d.outbound_sources {
                for n in &src.cached_nodes {
                    if n.tag == tag {
                        found = Some((n.server.clone(), n.server_port));
                        break 'outer;
                    }
                }
                for (i, link) in src.proxy_links.iter().enumerate() {
                    if let Some(n) = config_gen::parse_proxy_uri(link, i)
                        && n.tag == tag
                    {
                        found = Some((n.server, n.server_port));
                        break 'outer;
                    }
                }
            }
            (d.settings.latency_test_url.clone(), found)
        };
        let encoded = crate::store::url_encode_component(tag);
        let encoded_url = crate::store::url_encode_component(&latency_url);
        let path = format!("/proxies/{encoded}/delay?url={encoded_url}&timeout=3500");
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
        if let Some((host, port)) = host_port
            && !host.is_empty()
            && port > 0
        {
            let start = Instant::now();
            let addr = format!("{host}:{port}");
            if tokio::time::timeout(Duration::from_millis(1800), TcpStream::connect(&addr))
                .await
                .is_ok_and(|r| r.is_ok())
            {
                let ms_u32 = (start.elapsed().as_millis() as u32).max(1);
                self.state
                    .live
                    .write()
                    .await
                    .node_latencies_ms
                    .insert(tag.to_string(), ms_u32);
                return ms_u32;
            }
        }
        0
    }

    /// Probe exit IP of a specific outbound node via `tachyon-core` `GET /proxies/:name/exit`.
    pub async fn probe_node_exit_ip(&self, tag: &str) -> Value {
        let encoded = crate::store::url_encode_component(tag);
        self.clash_request("GET", &format!("/proxies/{encoded}/exit"), None)
            .await
            .unwrap_or_else(|e| json!({"ok": false, "error": e.to_string()}))
    }

    /// Parse raw subscription content (base64 or newline-separated proxy URIs) into `ParsedProxyNode`s.
    pub fn parse_subscription_payload(raw: &str) -> Vec<ParsedProxyNode> {
        let trimmed = raw.trim();
        let looks_plain = trimmed.contains("://")
            || trimmed.starts_with('{')
            || trimmed.starts_with('[')
            || trimmed.lines().any(|l| l.trim() == "proxies:");
        let decoded = if looks_plain {
            raw.to_string()
        } else {
            let compact: String = trimmed
                .chars()
                .filter(|c| !c.is_ascii_whitespace())
                .collect();
            B64_STD
                .decode(&compact)
                .or_else(|_| B64_STD_NO_PAD.decode(&compact))
                .or_else(|_| B64_URL_PAD.decode(&compact))
                .or_else(|_| B64_URL.decode(&compact))
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
                .unwrap_or_else(|| raw.to_string())
        };

        let mut out =
            if let Some(json_nodes) = config_gen::parse_json_subscription_payload(&decoded) {
                json_nodes
            } else if let Some(clash_nodes) =
                config_gen::parse_clash_yaml_subscription_payload(&decoded)
            {
                clash_nodes
            } else {
                let mut line_nodes = Vec::new();
                for (idx, line) in decoded.lines().enumerate() {
                    if let Some(node) = config_gen::parse_proxy_uri(line, idx) {
                        line_nodes.push(node);
                    }
                }
                line_nodes
            };

        let mut taken_tags: HashSet<String> = HashSet::new();
        for node in &mut out {
            config_gen::assign_unique_node_tag(node, &mut taken_tags);
        }
        out
    }

    /// Refresh a single subscription `OutboundSource` (or all sources in a `RoutingSection`, or all if `source_id` is empty).
    /// Syncs both via `tachyon-core` `/providers/proxies` and HTTP headers (`Subscription-Userinfo`).
    pub async fn refresh_subscription_source(&self, source_id: &str) -> anyhow::Result<usize> {
        let _sub_guard = self.sub_refresh_lock.lock().await;
        let snapshot = self.state.data.read().await.clone();
        let target_ids = resolve_subscription_target_ids(&snapshot, source_id);
        let now = unix_now_secs();

        // Trigger native `tachyon-core` provider refresh if running
        let providers_map = self
            .clash_request("GET", "/providers/proxies", None)
            .await
            .ok();

        // Map section ID -> mixed_proxy_port for optional proxy-routed subscription fetches
        let sec_proxy_ports: HashMap<String, u16> = snapshot
            .sections
            .iter()
            .filter(|s| s.enabled && s.mixed_proxy_enabled && s.mixed_proxy_port > 0)
            .map(|s| (s.id.clone(), s.mixed_proxy_port))
            .collect();
        let service_mixed_port =
            read_service_mixed_port_from_config(&snapshot.settings.core_config_path);
        let global_sub_proxy = if snapshot.settings.download_lists_via_proxy {
            sec_proxy_ports
                .get(&snapshot.settings.download_lists_via_proxy_section)
                .copied()
                .or(service_mixed_port)
        } else {
            None
        };

        struct SubFetchResult {
            id: String,
            nodes: Vec<ParsedProxyNode>,
            last_fetch_err: Option<String>,
            updated_src: crate::store::OutboundSource,
        }

        let mut fetched_results: Vec<SubFetchResult> = Vec::new();
        for orig_src in &snapshot.outbound_sources {
            if let Some(ref ids) = target_ids
                && !ids.contains(&orig_src.id)
            {
                continue;
            }
            if orig_src.source_type != "subscription" {
                continue;
            }
            let mut src = orig_src.clone();
            let enc_src_id = crate::store::url_encode_component(&src.id);
            let _ = self
                .clash_request("PUT", &format!("/providers/proxies/{enc_src_id}"), None)
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
                    .or(service_mixed_port)
            } else {
                global_sub_proxy
            }
            .map(|p| format!("http://127.0.0.1:{p}"));

            let mut nodes = Vec::new();
            let mut last_fetch_err: Option<String> = None;
            let urls = src.subscription_urls.clone();
            for url in &urls {
                let mut fetched = self
                    .curl_fetch_with_options(url, true, 12, proxy_opt.as_deref(), None)
                    .await;
                let mut parsed_for_url = Vec::new();
                if let Ok(ref stdout) = fetched {
                    let raw_resp = String::from_utf8_lossy(stdout);
                    let (headers_part, body_part) = split_http_response(&raw_resp);
                    parse_subscription_headers(headers_part, &mut src);
                    parsed_for_url = Self::parse_subscription_payload(body_part);
                }
                if fetched.is_err() || parsed_for_url.is_empty() {
                    let retry = self
                        .curl_fetch_with_options(
                            url,
                            true,
                            12,
                            proxy_opt.as_deref(),
                            Some("v2rayNG/1.8.19"),
                        )
                        .await;
                    match retry {
                        Ok(stdout2) => {
                            let raw_resp2 = String::from_utf8_lossy(&stdout2);
                            let (headers_part2, body_part2) = split_http_response(&raw_resp2);
                            parse_subscription_headers(headers_part2, &mut src);
                            let parsed2 = Self::parse_subscription_payload(body_part2);
                            if !parsed2.is_empty() {
                                parsed_for_url = parsed2;
                                fetched = Ok(stdout2);
                            } else if fetched.is_ok() {
                                last_fetch_err = Some(format!(
                                    "Ответ подписки ({url}) не содержит поддерживаемых узлов"
                                ));
                            }
                        }
                        Err(e2) => {
                            if let Err(ref e1) = fetched {
                                last_fetch_err = Some(format!("{url}: {e1}"));
                            } else {
                                last_fetch_err = Some(format!("{url}: {e2}"));
                            }
                        }
                    }
                }
                if let Err(ref e) = fetched
                    && parsed_for_url.is_empty()
                    && last_fetch_err.is_none()
                {
                    last_fetch_err = Some(format!("{url}: {e}"));
                }
                for n in parsed_for_url {
                    if !nodes
                        .iter()
                        .any(|existing: &ParsedProxyNode| existing.tag == n.tag)
                    {
                        nodes.push(n);
                    }
                }
            }
            fetched_results.push(SubFetchResult {
                id: src.id.clone(),
                nodes,
                last_fetch_err,
                updated_src: src,
            });
        }

        // Re-read fresh state right before committing so concurrent config edits are preserved.
        let mut candidate = self.state.data.read().await.clone();
        let mut updated_sources = 0usize;
        let mut metadata_changed = false;
        let mut core_reload_needed = false;

        for res in fetched_results {
            let Some(src) = candidate
                .outbound_sources
                .iter_mut()
                .find(|s| s.id == res.id && s.source_type == "subscription")
            else {
                continue;
            };
            src.sub_title = res.updated_src.sub_title;
            src.sub_support_url = res.updated_src.sub_support_url;
            src.sub_web_page_url = res.updated_src.sub_web_page_url;
            src.sub_announce = res.updated_src.sub_announce;
            src.sub_upload_bytes = res.updated_src.sub_upload_bytes;
            src.sub_download_bytes = res.updated_src.sub_download_bytes;
            src.sub_total_bytes = res.updated_src.sub_total_bytes;
            src.sub_expire_unix = res.updated_src.sub_expire_unix;
            src.subscription_update_interval = res.updated_src.subscription_update_interval;

            if !res.nodes.is_empty() {
                if !nodes_materially_equal(&src.cached_nodes, &res.nodes) {
                    core_reload_needed = true;
                }
                src.cached_nodes = res.nodes;
                src.last_updated_unix = now;
                src.sub_last_error.clear();
                updated_sources += 1;
                metadata_changed = true;
            } else {
                src.sub_last_error = res.last_fetch_err.unwrap_or_else(|| {
                    "Не удалось загрузить или разобрать узлы подписки".to_string()
                });
                if !src.cached_nodes.is_empty() {
                    src.last_updated_unix = now;
                    updated_sources += 1;
                }
                metadata_changed = true;
            }
        }

        if metadata_changed || updated_sources > 0 {
            transaction::commit_transaction(&self.state, candidate).await?;
            if core_reload_needed && !self.is_manually_stopped() {
                let _ = self.apply_or_reload().await;
            }
        }
        Ok(updated_sources)
    }

    pub async fn refresh_all_subscriptions(&self) -> anyhow::Result<usize> {
        self.refresh_subscription_source("").await
    }

    pub async fn refresh_due_subscriptions(&self, target: Option<&str>) -> anyhow::Result<usize> {
        let candidate = self.state.data.read().await.clone();
        let target_ids = target
            .map(|t| t.trim())
            .filter(|t| !t.is_empty())
            .and_then(|t| resolve_subscription_target_ids(&candidate, t));
        let now = unix_now_secs();
        let mut due_ids: Vec<String> = Vec::new();
        for src in &candidate.outbound_sources {
            if !src.enabled
                || src.source_type != "subscription"
                || src.subscription_urls.is_empty()
                || !src.subscription_update_enabled
            {
                continue;
            }
            if let Some(ref ids) = target_ids
                && !ids.contains(&src.id)
            {
                continue;
            }
            let base_interval = parse_subscription_interval_secs(&src.subscription_update_interval);
            let jitter_offset = compute_subscription_jitter_offset(
                base_interval,
                &src.subscription_update_jitter,
                &src.id,
            );
            let interval_secs = (base_interval as i64 + jitter_offset).max(300);
            if src.cached_nodes.is_empty()
                || src.last_updated_unix <= 0
                || now.saturating_sub(src.last_updated_unix) >= interval_secs
            {
                due_ids.push(src.id.clone());
            }
        }
        drop(candidate);

        let mut total_updated = 0usize;
        for id in due_ids {
            if let Ok(cnt) = self.refresh_subscription_source(&id).await {
                total_updated += cnt;
            }
        }
        Ok(total_updated)
    }

    /// Switch the active node on a `RoutingSection` selector (`PUT /proxies/sel-{id}` or `bal-{id}-{bal}`).
    pub async fn select_section_node(
        &self,
        section_id: &str,
        node_tag: &str,
    ) -> anyhow::Result<()> {
        let mut candidate = self.state.data.read().await.clone();
        let balancer_refs = {
            let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == section_id) else {
                anyhow::bail!("Section '{section_id}' not found");
            };
            sec.active_selected_tag = node_tag.to_string();
            sec.balancer_refs.clone()
        };
        transaction::commit_transaction(&self.state, candidate).await?;

        let mut selector_names = vec![format!("sel-{section_id}")];
        for bal_ref in balancer_refs {
            let b = bal_ref.trim();
            if !b.is_empty() {
                selector_names.push(format!("bal-{section_id}-{b}"));
            }
        }
        selector_names.push(section_id.to_string());
        selector_names.push(format!("{section_id}-out"));

        let payload = json!({ "name": node_tag }).to_string();
        let mut saved_key = None;
        for selector_name in &selector_names {
            let encoded = crate::store::url_encode_component(selector_name);
            if self
                .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&payload))
                .await
                .is_ok()
            {
                saved_key = Some(selector_name.clone());
                break;
            }
        }
        Self::save_selector_choice(
            saved_key.as_deref().unwrap_or(&format!("sel-{section_id}")),
            node_tag,
        );
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
                let (rulesets_dir, github_mirror, list_names, subnet_services, proxy_opt) = {
                    let d = self.state.data.read().await;
                    let (names, subnets) = crate::updater::collect_community_sync_targets(&d);
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
                        subnets,
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
                            && Self::bytes_have_valid_trs_magic(&bytes)
                        {
                            let dst = Path::new(&rulesets_dir).join(format!("{clean}.trs"));
                            let stale_srs = Path::new(&rulesets_dir).join(format!("{clean}.srs"));
                            let _ = std::fs::remove_file(&stale_srs);
                            if matches!(crypto_gen::write_file_if_changed(dst, &bytes), Ok(true)) {
                                any_changed = true;
                            }
                        } else {
                            let dst = Path::new(&rulesets_dir).join(format!("{clean}.trs"));
                            let stale_srs = Path::new(&rulesets_dir).join(format!("{clean}.srs"));
                            let _ = std::fs::remove_file(&stale_srs);
                            if !Self::file_has_valid_trs_magic(&dst) {
                                let _ = std::fs::remove_file(&dst);
                            }
                        }
                    }
                    let mut dead_hosts = std::collections::HashSet::new();
                    let (sub_changed, _) = crate::updater::sync_community_subnet_lists(
                        self,
                        Path::new(&rulesets_dir),
                        &github_mirror,
                        proxy_opt.as_deref(),
                        &subnet_services,
                        &mut dead_hosts,
                    )
                    .await;
                    if sub_changed {
                        any_changed = true;
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
                                self.refresh_core_version().await;
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
            let mut interval = telemetry_poll_interval();
            loop {
                interval.tick().await;
                tick_count = tick_count.wrapping_add(1);
                mgr.poll_telemetry_and_reconcile(tick_count).await;
                if tick_count == 5 || tick_count.is_multiple_of(100) {
                    let sub_mgr = Arc::clone(&mgr);
                    tokio::spawn(async move {
                        let _ = sub_mgr.refresh_due_subscriptions(None).await;
                    });
                }
                if tick_count == 8 || tick_count.is_multiple_of(100) {
                    let list_mgr = Arc::clone(&mgr);
                    tokio::spawn(async move {
                        let _ = crate::diagnostics::tick_list_updates_if_due(&list_mgr).await;
                    });
                }
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
        enum ConnectionsSample {
            Stopped,
            PollOk {
                total_up: u64,
                total_down: u64,
                active_conns: usize,
                up_bps: u64,
                down_bps: u64,
            },
            PollErr,
            IdleSkipped,
            BusySkipped {
                preserve_recent_bps: bool,
            },
        }

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
            pid_opt = None;
            uptime_secs = 0;
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

        let (watchdog_on, proxy_mode, lite_mode) = {
            let d = self.state.data.read().await;
            (
                d.settings.enable_watchdog,
                d.settings.proxy_mode.clone(),
                d.settings.lite_mode,
            )
        };
        let prev_core_pid = self.state.live.read().await.core_pid;
        let pid_changed = prev_core_pid.is_some() && prev_core_pid != pid_opt;
        let data_plane_busy = sys_info::is_lite_data_plane_busy(lite_mode);
        let telemetry_active = self
            .state
            .is_telemetry_active(crate::store::unix_now_u64(), TELEMETRY_ACTIVE_WINDOW_SECS);

        // Adaptive polling of Clash API `/connections`: skip `:9090` requests when no UI/TG
        // subscriber queried telemetry recently or while a lite-mode data plane is busy.
        let sample = if !core_alive {
            *self.prev_totals.lock().await = None;
            ConnectionsSample::Stopped
        } else if !telemetry_active {
            *self.prev_totals.lock().await = None;
            ConnectionsSample::IdleSkipped
        } else if data_plane_busy {
            let now_mono = TokioInstant::now();
            let mut prev = self.prev_totals.lock().await;
            let preserve_recent_bps = !pid_changed
                && prev.as_ref().is_some_and(|base| {
                    base.pid == pid_opt
                        && now_mono.saturating_duration_since(base.sampled_at)
                            <= Duration::from_secs(TELEMETRY_ACTIVE_WINDOW_SECS)
                });
            if !preserve_recent_bps {
                *prev = None;
            }
            ConnectionsSample::BusySkipped {
                preserve_recent_bps,
            }
        } else {
            if pid_changed {
                *self.prev_totals.lock().await = None;
            }
            match self.clash_request("GET", "/connections", None).await {
                Ok(conns_val) => {
                    let sampled_at = TokioInstant::now();
                    let total_up = conns_val
                        .get("uploadTotal")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    let total_down = conns_val
                        .get("downloadTotal")
                        .and_then(Value::as_u64)
                        .unwrap_or(0);
                    let active_conns = conns_val
                        .get("connections")
                        .and_then(Value::as_array)
                        .map(Vec::len)
                        .unwrap_or(0);

                    let mut prev = self.prev_totals.lock().await;
                    let (up_bps, down_bps) = if let Some(base) = prev.as_ref()
                        && base.pid == pid_opt
                    {
                        let elapsed = sampled_at.saturating_duration_since(base.sampled_at);
                        (
                            compute_rate_bps(base.total_up, total_up, elapsed),
                            compute_rate_bps(base.total_down, total_down, elapsed),
                        )
                    } else {
                        (0, 0)
                    };
                    *prev = Some(TrafficSampleBaseline {
                        pid: pid_opt,
                        total_up,
                        total_down,
                        sampled_at,
                    });
                    ConnectionsSample::PollOk {
                        total_up,
                        total_down,
                        active_conns,
                        up_bps,
                        down_bps,
                    }
                }
                Err(_) => ConnectionsSample::PollErr,
            }
        };

        let rss_bytes = pid_opt.map(sys_info::process_rss_bytes).unwrap_or(0);

        // Update LiveTelemetry and LKG 180s observation window
        let mut promote_lkg = false;
        {
            let mut live = self.state.live.write().await;
            live.core_running = core_alive;
            live.core_pid = pid_opt;
            live.core_uptime_secs = uptime_secs;
            live.core_rss_bytes = rss_bytes;
            live.dns_healthy = core_alive;
            live.wan_healthy = true;

            let (pt_up_bps, pt_down_bps) = match sample {
                ConnectionsSample::Stopped => {
                    live.core_identity = None;
                    live.total_up_bps = 0;
                    live.total_down_bps = 0;
                    live.total_up_bytes = 0;
                    live.total_down_bytes = 0;
                    live.active_connections = 0;
                    for dev in &mut live.lan_devices {
                        dev.upload_bps = 0;
                        dev.download_bps = 0;
                        dev.active_sessions = 0;
                    }
                    (0, 0)
                }
                ConnectionsSample::PollOk {
                    total_up,
                    total_down,
                    active_conns,
                    up_bps,
                    down_bps,
                } => {
                    live.total_up_bps = up_bps;
                    live.total_down_bps = down_bps;
                    live.total_up_bytes = total_up;
                    live.total_down_bytes = total_down;
                    live.active_connections = active_conns;
                    (up_bps, down_bps)
                }
                ConnectionsSample::PollErr => {
                    if pid_changed {
                        live.total_up_bytes = 0;
                        live.total_down_bytes = 0;
                    }
                    live.total_up_bps = 0;
                    live.total_down_bps = 0;
                    live.active_connections = 0;
                    for dev in &mut live.lan_devices {
                        dev.upload_bps = 0;
                        dev.download_bps = 0;
                        if pid_changed {
                            dev.active_sessions = 0;
                        }
                    }
                    (0, 0)
                }
                ConnectionsSample::IdleSkipped => {
                    if pid_changed {
                        live.total_up_bytes = 0;
                        live.total_down_bytes = 0;
                        live.active_connections = 0;
                    }
                    live.total_up_bps = 0;
                    live.total_down_bps = 0;
                    for dev in &mut live.lan_devices {
                        dev.upload_bps = 0;
                        dev.download_bps = 0;
                        if pid_changed {
                            dev.active_sessions = 0;
                        }
                    }
                    (0, 0)
                }
                ConnectionsSample::BusySkipped {
                    preserve_recent_bps,
                } => {
                    if pid_changed {
                        live.total_up_bytes = 0;
                        live.total_down_bytes = 0;
                        live.active_connections = 0;
                    }
                    if !preserve_recent_bps {
                        live.total_up_bps = 0;
                        live.total_down_bps = 0;
                        for dev in &mut live.lan_devices {
                            dev.upload_bps = 0;
                            dev.download_bps = 0;
                            if pid_changed {
                                dev.active_sessions = 0;
                            }
                        }
                    }
                    (live.total_up_bps, live.total_down_bps)
                }
            };

            if live.throughput_history.len() >= MAX_THROUGHPUT_POINTS {
                live.throughput_history.remove(0);
            }
            live.throughput_history.push((now, pt_up_bps, pt_down_bps));

            if live.throughput.len() >= MAX_THROUGHPUT_POINTS {
                live.throughput.remove(0);
            }
            live.throughput.push(ThroughputSample {
                ts: now,
                rx_bps: pt_down_bps,
                tx_bps: pt_up_bps,
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

        // Every 5 ticks (15s), run Reconciler checks (`nftables` drift & adaptive LAN devices refresh via `/tachyon/devices`)
        if tick_count.is_multiple_of(5) {
            let nft_ok = net_stack::check_nft_table_active().await;

            let devices_opt = if telemetry_active && !data_plane_busy {
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
            if watchdog_on && !self.is_manually_stopped() {
                let store_snapshot = { self.state.data.read().await.clone() };
                if !core_alive && !self.is_manually_stopped() {
                    let _ = net_stack::hold_kill_switch(&store_snapshot).await;
                    self.state.live.write().await.push_event(
                        "warn",
                        "watchdog",
                        "tachyon-core process stopped unexpectedly; restarting",
                    );
                    let _ = self.start().await;
                    return;
                }
                let needs_nft_table = proxy_mode == "tproxy"
                    || (proxy_mode == "tun"
                        && net_stack::compile_tun_guard_ruleset_with_wan6(
                            &store_snapshot,
                            true,
                            &[],
                        )
                        .is_some());
                if needs_nft_table && !nft_ok {
                    let _ = net_stack::apply_network_stack(&store_snapshot).await;
                    self.state.live.write().await.push_event(
                        "warn",
                        "reconciler",
                        "Repaired inet TachyonTable drift",
                    );
                }
                if core_alive && tick_count.is_multiple_of(20) {
                    let wan6 = crate::store::probe_wan6_runtime_state();
                    let ipv6_state = crate::store::resolve_effective_ipv6_state(
                        &store_snapshot.settings,
                        wan6.wan6_available,
                    );
                    let cfg_path =
                        Self::effective_core_config_path_for(&self.state, &store_snapshot.settings);
                    if !Self::core_config_ipv6_matches(&cfg_path, &store_snapshot, ipv6_state) {
                        let now_u64 = crate::store::unix_now_u64();
                        let last_sync = self.last_ipv6_resync_ts.load(Ordering::Acquire);
                        if now_u64.saturating_sub(last_sync) >= 120 {
                            self.last_ipv6_resync_ts.store(now_u64, Ordering::Release);
                            self.state.live.write().await.push_event(
                                "warn",
                                "watchdog",
                                &format!(
                                    "FakeIPv6 runtime config drifted from {} state; reloading",
                                    ipv6_state.as_str()
                                ),
                            );
                            let _ = self.apply_or_reload().await;
                        }
                    }
                }
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
            "profile-title" if !val.is_empty() => {
                src.sub_title = crate::store::decode_sub_header_value(val);
            }
            "support-url" if !val.is_empty() => {
                src.sub_support_url = val.to_string();
            }
            "profile-web-page-url" if !val.is_empty() => {
                src.sub_web_page_url = val.to_string();
            }
            "announce" if !val.is_empty() => {
                src.sub_announce = crate::store::decode_sub_header_value(val);
            }
            "profile-update-interval" => {
                if let Ok(hours) = val.trim().parse::<u64>()
                    && hours >= 1
                {
                    src.subscription_update_interval = format!("{}h", hours.min(24 * 30));
                }
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

fn parse_http_url_host_port(url: &str) -> Option<(String, u16)> {
    let trimmed = url.trim();
    let (default_port, after_scheme) = if let Some(rest) = trimmed.strip_prefix("https://") {
        (443u16, rest)
    } else {
        let rest = trimmed.strip_prefix("http://")?;
        (80u16, rest)
    };
    let authority = after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(after_scheme);
    let host_port = authority
        .rsplit_once('@')
        .map_or(authority, |(_, hp)| hp)
        .trim();
    if host_port.is_empty() {
        return None;
    }
    if let Some(rest) = host_port.strip_prefix('[') {
        let (ip_part, after_bracket) = rest.split_once(']')?;
        let port = after_bracket
            .strip_prefix(':')
            .and_then(|p| p.parse::<u16>().ok())
            .filter(|p| *p > 0)
            .unwrap_or(default_port);
        return Some((ip_part.trim().to_string(), port));
    }
    if let Some((h, p_str)) = host_port.rsplit_once(':')
        && let Ok(port) = p_str.parse::<u16>()
        && port > 0
    {
        return Some((h.trim().to_string(), port));
    }
    Some((host_port.to_string(), default_port))
}

fn normalize_bootstrap_dns_addr(raw: &str) -> Option<std::net::SocketAddr> {
    let mut t = raw.trim();
    for pfx in ["udp://", "tcp://"] {
        if let Some(rest) = t.strip_prefix(pfx) {
            t = rest;
        }
    }
    if t.contains("://") || t.is_empty() {
        return None;
    }
    if let Ok(sock) = t.parse::<std::net::SocketAddr>() {
        return Some(sock);
    }
    let ip_str = t.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = ip_str.parse::<std::net::IpAddr>() {
        return Some(std::net::SocketAddr::new(ip, 53));
    }
    None
}

fn collect_section_source_ids(
    candidate: &crate::store::RouterStoreData,
    section_id: &str,
    visited_sections: &mut HashSet<String>,
    out_sources: &mut HashSet<String>,
) {
    if !visited_sections.insert(section_id.to_string()) {
        return;
    }
    let Some(sec) = candidate.sections.iter().find(|s| s.id == section_id) else {
        return;
    };
    for r in &sec.outbound_source_refs {
        let t = r.trim();
        if !t.is_empty() {
            out_sources.insert(t.to_string());
        }
    }
    let mut group_ids: Vec<&str> = Vec::new();
    if !sec.outbound_group_ref.trim().is_empty() {
        group_ids.push(sec.outbound_group_ref.trim());
    }
    for gref in &sec.outbound_group_refs {
        let g = gref.trim();
        if !g.is_empty() {
            group_ids.push(g);
        }
    }
    for gid in group_ids {
        if let Some(grp) = candidate.outbound_groups.iter().find(|g| g.id == gid) {
            for r in grp
                .primary_refs
                .iter()
                .chain(grp.backup_refs.iter())
                .chain(grp.source_refs.iter())
            {
                let t = r.trim();
                if !t.is_empty() {
                    out_sources.insert(t.to_string());
                }
            }
        } else {
            out_sources.insert(gid.to_string());
        }
    }
    for bref in &sec.balancer_refs {
        let bid = bref.trim();
        if let Some(bal) = candidate.balancers.iter().find(|b| b.id == bid) {
            for r in &bal.balancer_pool {
                let t = r.trim();
                if !t.is_empty() {
                    out_sources.insert(t.to_string());
                }
            }
        }
    }
    for sub_sec in &sec.section_refs {
        let sid = sub_sec.trim();
        if !sid.is_empty() {
            collect_section_source_ids(candidate, sid, visited_sections, out_sources);
        }
    }
}

fn resolve_subscription_target_ids(
    candidate: &crate::store::RouterStoreData,
    target: &str,
) -> Option<HashSet<String>> {
    let t = target.trim();
    if t.is_empty() || t.eq_ignore_ascii_case("all") || t == "*" {
        return None;
    }
    if candidate.outbound_sources.iter().any(|s| s.id == t) {
        return Some(HashSet::from([t.to_string()]));
    }
    if let Some(src_ci) = candidate
        .outbound_sources
        .iter()
        .find(|s| s.id.eq_ignore_ascii_case(t))
    {
        return Some(HashSet::from([src_ci.id.clone()]));
    }
    if let Some(sec) = candidate
        .sections
        .iter()
        .find(|s| s.id == t || s.id.eq_ignore_ascii_case(t))
    {
        let mut visited = HashSet::new();
        let mut out = HashSet::new();
        collect_section_source_ids(candidate, &sec.id, &mut visited, &mut out);
        return Some(out);
    }
    Some(HashSet::from([t.to_string()]))
}

fn compute_subscription_jitter_offset(interval_secs: u64, raw_jitter: &str, seed: &str) -> i64 {
    let trimmed = raw_jitter.trim().to_ascii_lowercase();
    if trimmed.is_empty() || trimmed == "0" || trimmed == "0%" {
        return 0;
    }
    let max_jitter = if let Some(pct_str) = trimmed.strip_suffix('%') {
        let pct = pct_str.trim().parse::<u64>().unwrap_or(0).min(50);
        interval_secs.saturating_mul(pct) / 100
    } else if let Some(m) = trimmed.strip_suffix('m') {
        m.trim().parse::<u64>().unwrap_or(0).saturating_mul(60)
    } else if let Some(h) = trimmed.strip_suffix('h') {
        h.trim().parse::<u64>().unwrap_or(0).saturating_mul(3600)
    } else if let Some(s) = trimmed.strip_suffix('s') {
        s.trim().parse::<u64>().unwrap_or(0)
    } else if let Ok(bare) = trimmed.parse::<u64>() {
        if bare <= 50 {
            interval_secs.saturating_mul(bare) / 100
        } else {
            bare
        }
    } else {
        0
    }
    .min(interval_secs / 2);
    if max_jitter == 0 {
        return 0;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in seed.as_bytes() {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    let span = max_jitter.saturating_mul(2).saturating_add(1);
    (hash % span) as i64 - max_jitter as i64
}

fn read_service_mixed_port_from_config(config_path: &str) -> Option<u16> {
    let raw = std::fs::read_to_string(config_path).ok()?;
    let val: Value = serde_json::from_str(&raw).ok()?;
    let inbounds = val.get("inbounds")?.as_array()?;
    inbounds.iter().find_map(|inb| {
        if inb.get("tag").and_then(Value::as_str) == Some("service-mixed-in") {
            inb.get("listen_port")
                .and_then(Value::as_u64)
                .and_then(|p| u16::try_from(p).ok())
                .filter(|p| *p > 0)
        } else {
            None
        }
    })
}

fn parse_subscription_interval_secs(raw: &str) -> u64 {
    let trimmed = raw.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        return 6 * 3600;
    }
    let (num_str, mult) = if let Some(n) = trimmed.strip_suffix('d') {
        (n, 86_400u64)
    } else if let Some(n) = trimmed.strip_suffix('h') {
        (n, 3_600u64)
    } else if let Some(n) = trimmed.strip_suffix('m') {
        (n, 60u64)
    } else if let Some(n) = trimmed.strip_suffix('s') {
        (n, 1u64)
    } else {
        let bare = trimmed.parse::<u64>().unwrap_or(6);
        let secs = if bare < 200 {
            bare.saturating_mul(3600)
        } else {
            bare
        };
        return secs.max(300);
    };
    let n = num_str.trim().parse::<u64>().unwrap_or(6);
    n.saturating_mul(mult).max(300)
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

    #[derive(Default)]
    struct MockClashState {
        up_total: PortableAtomicU64,
        down_total: PortableAtomicU64,
        conns_count: std::sync::atomic::AtomicUsize,
        conn_hits: std::sync::atomic::AtomicUsize,
        dev_hits: std::sync::atomic::AtomicUsize,
        put_hits: std::sync::atomic::AtomicUsize,
        put_in_flight: std::sync::atomic::AtomicUsize,
        put_max_in_flight: std::sync::atomic::AtomicUsize,
        put_delay: Duration,
    }

    async fn spawn_test_mock_clash_server(
        mock: Arc<MockClashState>,
    ) -> (u16, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind mock clash port");
        let port = listener.local_addr().unwrap().port();
        let handle = tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mock = Arc::clone(&mock);
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let n = match sock.read(&mut buf).await {
                        Ok(n) if n > 0 => n,
                        _ => return,
                    };
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let first_line = req.lines().next().unwrap_or("");
                    let mut parts = first_line.split_whitespace();
                    let method = parts.next().unwrap_or("");
                    let path = parts.next().unwrap_or("");

                    if method == "PUT" && path.starts_with("/configs") {
                        let cur = mock
                            .put_in_flight
                            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                            + 1;
                        mock.put_max_in_flight
                            .fetch_max(cur, std::sync::atomic::Ordering::SeqCst);
                        mock.put_hits
                            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        if !mock.put_delay.is_zero() {
                            tokio::time::sleep(mock.put_delay).await;
                        }
                        mock.put_in_flight
                            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                        let _ = sock
                            .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .await;
                        return;
                    }

                    let body = if method == "GET" && path == "/connections" {
                        mock.conn_hits
                            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        let cnt = mock.conns_count.load(std::sync::atomic::Ordering::SeqCst);
                        let connections = vec![json!({"id": "c"}); cnt];
                        json!({
                            "uploadTotal": mock.up_total.load(std::sync::atomic::Ordering::SeqCst),
                            "downloadTotal": mock.down_total.load(std::sync::atomic::Ordering::SeqCst),
                            "connections": connections
                        })
                        .to_string()
                    } else if method == "GET" && path == "/tachyon/devices" {
                        mock.dev_hits
                            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        json!({
                            "devices": [{
                                "ip": "192.168.1.50",
                                "mac": "AA:BB:CC:DD:EE:01",
                                "hostname": "workstation",
                                "upload": 5000,
                                "download": 9000,
                                "upload_bps": 800,
                                "download_bps": 1600,
                                "connections": 2
                            }]
                        })
                        .to_string()
                    } else {
                        "{}".to_string()
                    };

                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                });
            }
        });
        (port, handle)
    }

    fn spawn_dummy_long_process() -> Child {
        #[cfg(windows)]
        let mut cmd = {
            let mut c = Command::new("ping");
            c.args(["-n", "30", "127.0.0.1"]);
            c
        };
        #[cfg(not(windows))]
        let mut cmd = {
            let mut c = Command::new("sleep");
            c.arg("30");
            c
        };
        cmd.stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("spawn dummy long-lived child")
    }

    #[tokio::test]
    async fn test_telemetry_interval_uses_missed_tick_behavior_skip_and_rate_math() {
        let prod_iv = telemetry_poll_interval();
        assert_eq!(
            prod_iv.missed_tick_behavior(),
            tokio::time::MissedTickBehavior::Skip
        );

        let mut iv = telemetry_poll_interval_with(Duration::from_millis(80));
        iv.tick().await;
        // Miss >3 periods while busy: Skip must drop missed ticks instead of bursting.
        tokio::time::sleep(Duration::from_millis(260)).await;
        iv.tick().await;
        let burst = tokio::time::timeout(Duration::from_millis(25), iv.tick()).await;
        assert!(burst.is_err(), "expected Skip behavior to suppress burst");
        let next = tokio::time::timeout(Duration::from_millis(160), iv.tick()).await;
        assert!(next.is_ok(), "expected next tick after one period");

        assert_eq!(compute_rate_bps(1000, 7000, Duration::from_secs(6)), 1000);
        assert_eq!(compute_rate_bps(1000, 500, Duration::from_secs(3)), 0);
        assert_eq!(compute_rate_bps(0, 3000, Duration::from_millis(10)), 0);
    }

    #[tokio::test]
    async fn test_adaptive_telemetry_throttling_real_delta_and_state_cleanup() {
        let mock = Arc::new(MockClashState {
            up_total: PortableAtomicU64::new(10_000),
            down_total: PortableAtomicU64::new(20_000),
            conns_count: std::sync::atomic::AtomicUsize::new(3),
            ..Default::default()
        });
        let (port, srv_handle) = spawn_test_mock_clash_server(Arc::clone(&mock)).await;

        let dir = std::env::temp_dir().join(format!("tachyon_tele_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let cfg_file = dir.join("tele-core-cfg.json");
        let _ = std::fs::write(
            &cfg_file,
            json!({
                "experimental": {
                    "clash_api": {
                        "external_controller": format!("127.0.0.1:{port}"),
                        "secret": ""
                    }
                }
            })
            .to_string(),
        );
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        {
            let mut d = state.data.write().await;
            d.settings.clash_api_addr = format!("127.0.0.1:{port}");
            d.settings.clash_api_secret.clear();
            d.settings.core_config_path = cfg_file.to_string_lossy().to_string();
            d.settings.proxy_mode = "socks".to_string();
            d.settings.enable_watchdog = false;
            d.settings.lite_mode = false;
        }

        let mgr = CoreManager::new(Arc::clone(&state));
        let child = spawn_dummy_long_process();
        let pid1 = child.id().expect("child pid");
        *mgr.proc.lock().await = Some((child, Instant::now()));

        // 1. UI idle (last_telemetry_access_ts == 0): must NOT poll `:9090`.
        mgr.poll_telemetry_and_reconcile(5).await;
        assert_eq!(mock.conn_hits.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert_eq!(mock.dev_hits.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(state.live.read().await.core_running);

        // 2. UI active: tick 5 establishes baseline without division by hardcoded 3.
        state.touch_telemetry_access();
        mgr.poll_telemetry_and_reconcile(5).await;
        assert_eq!(mock.conn_hits.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(mock.dev_hits.load(std::sync::atomic::Ordering::SeqCst), 1);
        {
            let live = state.live.read().await;
            assert_eq!(live.total_up_bytes, 10_000);
            assert_eq!(live.total_down_bytes, 20_000);
            assert_eq!(live.total_up_bps, 0);
            assert_eq!(live.total_down_bps, 0);
            let dev = live
                .lan_devices
                .iter()
                .find(|d| d.ip == "192.168.1.50")
                .expect("mock lan device present");
            assert_eq!(dev.upload_bps, 800);
        }

        // Wait ~200ms real Instant delta -> bps (~10_000 / ~30_000 B/s) must reflect real elapsed time, NOT /3s (666 / 2000).
        tokio::time::sleep(Duration::from_millis(200)).await;
        mock.up_total
            .store(12_000, std::sync::atomic::Ordering::SeqCst);
        mock.down_total
            .store(26_000, std::sync::atomic::Ordering::SeqCst);
        mgr.poll_telemetry_and_reconcile(6).await;
        assert_eq!(mock.conn_hits.load(std::sync::atomic::Ordering::SeqCst), 2);
        {
            let live = state.live.read().await;
            assert_eq!(live.total_up_bytes, 12_000);
            assert_eq!(live.total_down_bytes, 26_000);
            assert!(
                live.total_up_bps >= 1_500 && live.total_up_bps <= 15_000,
                "expected real-delta up_bps (>=1500, !=666), got {}",
                live.total_up_bps
            );
            assert!(
                live.total_down_bps >= 4_500 && live.total_down_bps <= 45_000,
                "expected real-delta down_bps (>=4500, !=2000), got {}",
                live.total_down_bps
            );
        }

        // 3. UI transitions back to idle (>15s ago): zero fake instantaneous bps, preserve cumulative totals.
        state.last_telemetry_access_ts.store(
            crate::store::unix_now_u64().saturating_sub(30),
            std::sync::atomic::Ordering::Release,
        );
        mgr.poll_telemetry_and_reconcile(10).await;
        assert_eq!(mock.conn_hits.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert_eq!(mock.dev_hits.load(std::sync::atomic::Ordering::SeqCst), 1);
        {
            let live = state.live.read().await;
            assert!(live.core_running);
            assert_eq!(live.total_up_bytes, 12_000);
            assert_eq!(live.total_down_bytes, 26_000);
            assert_eq!(live.total_up_bps, 0);
            assert_eq!(live.total_down_bps, 0);
            let dev = live
                .lan_devices
                .iter()
                .find(|d| d.ip == "192.168.1.50")
                .expect("mock lan device preserved on idle");
            assert_eq!(dev.upload_bytes, 5_000);
            assert_eq!(dev.upload_bps, 0);
            assert_eq!(dev.download_bps, 0);
            let last_pt = live.throughput.last().expect("throughput point");
            assert_eq!((last_pt.tx_bps, last_pt.rx_bps), (0, 0));
        }

        // 4. Process PID change resets stale baseline instead of computing bogus diff.
        if let Some((mut old_child, _)) = mgr.proc.lock().await.take() {
            let _ = old_child.kill().await;
            let _ = old_child.wait().await;
        }
        let child2 = spawn_dummy_long_process();
        let pid2 = child2.id().expect("child2 pid");
        assert_ne!(pid1, pid2);
        *mgr.proc.lock().await = Some((child2, Instant::now()));
        state.touch_telemetry_access();
        mock.up_total
            .store(2_000, std::sync::atomic::Ordering::SeqCst);
        mock.down_total
            .store(4_000, std::sync::atomic::Ordering::SeqCst);
        mgr.poll_telemetry_and_reconcile(11).await;
        {
            let live = state.live.read().await;
            assert_eq!(live.core_pid, Some(pid2));
            assert_eq!(live.total_up_bytes, 2_000);
            assert_eq!(live.total_up_bps, 0);
        }

        // 5. Core stops/crashes -> all runtime counters & speeds cleared cleanly.
        if let Some((mut old_child, _)) = mgr.proc.lock().await.take() {
            let _ = old_child.kill().await;
            let _ = old_child.wait().await;
        }
        mgr.poll_telemetry_and_reconcile(12).await;
        {
            let live = state.live.read().await;
            assert!(!live.core_running);
            assert_eq!(live.core_pid, None);
            assert_eq!(live.total_up_bytes, 0);
            assert_eq!(live.total_down_bytes, 0);
            assert_eq!(live.total_up_bps, 0);
            assert_eq!(live.total_down_bps, 0);
            assert_eq!(live.active_connections, 0);
        }

        srv_handle.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_apply_or_reload_serialization_and_start_fallbacks_no_deadlock() {
        let mock = Arc::new(MockClashState {
            put_delay: Duration::from_millis(60),
            ..Default::default()
        });
        let (port, srv_handle) = spawn_test_mock_clash_server(Arc::clone(&mock)).await;

        let dir = std::env::temp_dir().join(format!("tachyon_reload_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        {
            let mut d = state.data.write().await;
            d.settings.clash_api_addr = format!("127.0.0.1:{port}");
            d.settings.clash_api_secret.clear();
            d.settings.core_config_path = dir.join("core-cfg.json").to_string_lossy().to_string();
            d.settings.core_bin_path = dir
                .join("missing-tachyon-core")
                .to_string_lossy()
                .to_string();
            d.settings.proxy_mode = "socks".to_string();
            d.settings.enable_watchdog = false;
        }
        let mut dummy = spawn_dummy_long_process();
        let dummy_pid = dummy.id().expect("dummy pid");
        {
            let mut live = state.live.write().await;
            live.core_running = true;
            live.core_pid = Some(dummy_pid);
        }

        let mgr = CoreManager::new(Arc::clone(&state));

        // 1. Four concurrent apply_or_reload calls serialize strictly on reload_lock.
        let batch = tokio::time::timeout(Duration::from_secs(5), async {
            tokio::join!(
                mgr.apply_or_reload(),
                mgr.apply_or_reload(),
                mgr.apply_or_reload(),
                mgr.apply_or_reload(),
            )
        })
        .await
        .expect("concurrent apply_or_reload timed out");
        assert!(batch.0.is_ok() && batch.1.is_ok() && batch.2.is_ok() && batch.3.is_ok());
        assert_eq!(mock.put_hits.load(std::sync::atomic::Ordering::SeqCst), 4);
        assert_eq!(
            mock.put_max_in_flight
                .load(std::sync::atomic::Ordering::SeqCst),
            1
        );

        // 2. Fallback into start() when !core_running must drop reload_guard and avoid deadlock.
        {
            let mut live = state.live.write().await;
            live.core_running = false;
            live.core_pid = None;
        }
        let res_stopped = tokio::time::timeout(Duration::from_secs(3), mgr.apply_or_reload())
            .await
            .expect("fallback !core_running deadlocked/timed out");
        assert!(res_stopped.is_err());

        // 3. Fallback into start() when PUT /configs fails must also drop reload_guard cleanly.
        srv_handle.abort();
        let closed_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind closed port");
        let closed_port = closed_listener.local_addr().unwrap().port();
        drop(closed_listener);
        state.data.write().await.settings.clash_api_addr = format!("127.0.0.1:{closed_port}");
        {
            let mut live = state.live.write().await;
            live.core_running = true;
            live.core_pid = Some(dummy_pid);
        }
        let res_put_fail = tokio::time::timeout(Duration::from_secs(5), async {
            tokio::join!(mgr.apply_or_reload(), mgr.apply_or_reload())
        })
        .await
        .expect("fallback on PUT error deadlocked/timed out");
        assert!(res_put_fail.0.is_err() && res_put_fail.1.is_err());

        let _ = dummy.kill().await;
        let _ = dummy.wait().await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_external_command_timeout_and_kill_on_drop() {
        #[cfg(target_os = "linux")]
        {
            let pid_file =
                std::env::temp_dir().join(format!("tachyon_kill_drop_{}.pid", std::process::id()));
            let _ = std::fs::remove_file(&pid_file);
            let script = format!("echo $$ > '{}'; exec sleep 30", pid_file.display());
            let mut cmd = Command::new("sh");
            cmd.args(["-c", &script]);
            let started = Instant::now();
            let err =
                CoreManager::run_command_output_with_timeout(&mut cmd, Duration::from_millis(250))
                    .await
                    .expect_err("expected slow child to time out");
            assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
            assert!(started.elapsed() < Duration::from_secs(3));

            if let Ok(raw_pid) = std::fs::read_to_string(&pid_file)
                && let Ok(pid) = raw_pid.trim().parse::<u32>()
            {
                let mut exited = false;
                for _ in 0..20 {
                    if !Path::new(&format!("/proc/{pid}")).exists() {
                        exited = true;
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(25)).await;
                }
                assert!(exited, "child pid {pid} leaked after timeout/kill_on_drop");
            }
            let _ = std::fs::remove_file(&pid_file);
        }

        #[cfg(not(target_os = "linux"))]
        {
            let mut cmd = Command::new("ping");
            cmd.args(["-n", "30", "127.0.0.1"]);
            let started = Instant::now();
            let err =
                CoreManager::run_command_output_with_timeout(&mut cmd, Duration::from_millis(250))
                    .await
                    .expect_err("expected slow child to time out");
            assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
            assert!(started.elapsed() < Duration::from_secs(3));
        }
    }

    #[test]
    fn test_parse_subscription_payload_mieru_base64_and_clash_yaml() {
        let raw_links = concat!(
            "mierus://default:dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ%3D@198.51.100.47?profile=default&port=2012-2022&protocol=TCP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=GgQIARAK#Mieru\n",
            "mierus://default:dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ%3D@198.51.100.48?port=2030-2040&protocol=UDP#Mieru\n"
        );
        let encoded_raw = B64_STD_NO_PAD.encode(raw_links);
        let wrapped = format!("{}\r\n{}", &encoded_raw[..40], &encoded_raw[40..]);
        let b64_nodes = CoreManager::parse_subscription_payload(&wrapped);
        assert_eq!(b64_nodes.len(), 2);
        assert_eq!(b64_nodes[0].tag, "Mieru");
        assert_eq!(b64_nodes[1].tag, "Mieru-1");
        assert_eq!(b64_nodes[1].outbound_json["tag"], "Mieru-1");
        assert_eq!(
            b64_nodes[0].outbound_json["server_ports"],
            json!(["2012-2022"])
        );
        assert!(b64_nodes[0].outbound_json.get("server_port").is_none());
        assert_eq!(
            b64_nodes[0].outbound_json["password"],
            "dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ="
        );
        assert_eq!(b64_nodes[0].outbound_json["traffic_pattern"], "GgQIARAK");

        let clash_yaml = r#"proxies:
  - name: Mieru
    type: mieru
    server: 198.51.100.47
    port: 0
    port-range: "2012-2022"
    username: default
    password: dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ=
    protocol: TCP
    multiplexing: MULTIPLEXING_HIGH
    traffic-pattern: GgQIARAK
    handshake-mode: HANDSHAKE_STANDARD
  - name: Mieru
    type: mieru
    server: 198.51.100.48
    ports:
      - 2030-2040
      - 2050
    username: default
    password: dGVzdFBhc3NNaWVydTEyMzQ1Njc4OQ=
    protocol: UDP
"#;
        let yaml_nodes = CoreManager::parse_subscription_payload(clash_yaml);
        assert_eq!(yaml_nodes.len(), 2);
        assert_eq!(yaml_nodes[0].tag, "Mieru");
        assert_eq!(yaml_nodes[0].server_port, 2012);
        assert!(yaml_nodes[0].outbound_json.get("server_port").is_none());
        assert_eq!(
            yaml_nodes[0].outbound_json["server_ports"],
            json!(["2012-2022"])
        );
        assert_eq!(yaml_nodes[0].outbound_json["traffic_pattern"], "GgQIARAK");
        assert_eq!(
            yaml_nodes[0].outbound_json["handshake_mode"],
            "HANDSHAKE_STANDARD"
        );
        assert_eq!(yaml_nodes[1].tag, "Mieru-1");
        assert_eq!(
            yaml_nodes[1].outbound_json["server_ports"],
            json!(["2030-2040", "2050"])
        );
    }

    #[test]
    fn test_subscription_target_resolution_dns_packet_and_interval_helpers() {
        assert_eq!(
            parse_http_url_host_port("https://sub.skytunnel.pw/bb6a9d37678a415a"),
            Some(("sub.skytunnel.pw".to_string(), 443))
        );
        assert_eq!(
            parse_http_url_host_port("http://[::1]:8080/sub"),
            Some(("::1".to_string(), 8080))
        );
        assert_eq!(
            normalize_bootstrap_dns_addr("udp://77.88.8.8"),
            Some("77.88.8.8:53".parse().unwrap())
        );

        let pkt = crate::diagnostics::build_dns_query_packet("sub.skytunnel.pw", 1)
            .expect("dns query packet");
        assert!(pkt.len() > 20);
        // Simulate FakeIP vs Real IP response rejection
        let mut fake_resp = pkt.clone();
        fake_resp[2] = 0x81;
        fake_resp[3] = 0x80;
        fake_resp[7] = 1; // 1 answer
        fake_resp.extend_from_slice(&[
            0xc0, 0x0c, // name ptr
            0x00, 0x01, // A
            0x00, 0x01, // IN
            0x00, 0x00, 0x00, 0x05, // TTL
            0x00, 0x04, // len 4
            198, 18, 0, 7, // FakeIP
        ]);
        let (is_fake, ip, rcode) =
            crate::diagnostics::parse_dns_fakeip_response(&fake_resp, "198.18.0.0/15", "fc00::/18");
        assert_eq!(rcode, 0);
        assert!(is_fake);
        assert_eq!(ip, "198.18.0.7");

        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "sub_sky".to_string(),
            source_type: "subscription".to_string(),
            ..Default::default()
        });
        store.sections.clear();
        store.sections.push(crate::store::RoutingSection {
            id: "Main".to_string(),
            outbound_source_refs: vec!["sub_sky".to_string(), "src_two".to_string()],
            ..Default::default()
        });
        assert_eq!(
            resolve_subscription_target_ids(&store, "sub_sky"),
            Some(HashSet::from(["sub_sky".to_string()]))
        );
        assert_eq!(
            resolve_subscription_target_ids(&store, "Main"),
            Some(HashSet::from([
                "sub_sky".to_string(),
                "src_two".to_string()
            ]))
        );
        assert_eq!(resolve_subscription_target_ids(&store, ""), None);

        assert_eq!(parse_subscription_interval_secs("24h"), 86_400);
        assert_eq!(parse_subscription_interval_secs("30m"), 1_800);
        assert_eq!(parse_subscription_interval_secs("12"), 43_200);
    }

    #[tokio::test]
    async fn test_manual_stop_persists_across_managers_and_blocks_watchdog_restart() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_manual_stop_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let store_path = dir.join("store.json");

        let cli_state = AppState::load_or_create(store_path.clone()).expect("load cli state");
        {
            let mut d = cli_state.data.write().await;
            d.settings.enable_watchdog = true;
            d.settings.proxy_mode = "socks".to_string();
        }
        let cli_mgr = CoreManager::new(Arc::clone(&cli_state));

        // 1. CLI stop sets cross-process manual stop marker and pauses Watchdog.
        cli_mgr.stop().await.expect("cli stop succeeds");
        assert!(cli_mgr.is_manually_stopped());
        assert!(!cli_mgr.is_watchdog_effectively_running().await);

        // 2. Separate daemon CoreManager observes manual stop and MUST NOT auto-restart core on reconcile.
        let daemon_state = AppState::load_or_create(store_path.clone()).expect("load daemon state");
        {
            let mut d = daemon_state.data.write().await;
            d.settings.enable_watchdog = true;
            d.settings.proxy_mode = "socks".to_string();
            d.settings.core_bin_path = dir
                .join("missing-tachyon-core")
                .to_string_lossy()
                .to_string();
        }
        let daemon_mgr = CoreManager::new(Arc::clone(&daemon_state));
        assert!(daemon_mgr.is_manually_stopped());
        assert!(!daemon_mgr.is_watchdog_effectively_running().await);

        daemon_mgr.poll_telemetry_and_reconcile(1).await;
        {
            let live = daemon_state.live.read().await;
            assert!(!live.core_running);
            assert!(
                !live
                    .events
                    .iter()
                    .any(|e| e.subsystem == "watchdog" && e.message.contains("restarting")),
                "watchdog must not attempt core restart after manual stop"
            );
        }

        // 3. Explicit start clears manual stop marker across processes and re-activates Watchdog.
        cli_mgr.set_manual_stop(false);
        assert!(!daemon_mgr.is_manually_stopped());
        assert!(daemon_mgr.is_watchdog_effectively_running().await);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_trs_magic_validation_reason_normalization_and_fakeip6_drift() {
        let reason = "config: route: max_idle_timeout: json: unknown field \"bad_key\"";
        assert_eq!(
            CoreManager::normalize_unknown_field_reason(reason),
            "config: route.max_idle_timeout: json: unknown field \"bad_key\""
        );

        let mut valid_trs = b"TSRS".to_vec();
        valid_trs.resize(32, 0x01);
        assert!(CoreManager::bytes_have_valid_trs_magic(&valid_trs));
        assert!(!CoreManager::bytes_have_valid_trs_magic(b"SRS\x02tiny"));
        assert!(!CoreManager::bytes_have_valid_trs_magic(b"TSRS"));

        let dir =
            std::env::temp_dir().join(format!("tachyon_fakeip6_drift_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let cfg_path = dir.join("config.json");

        let mut store = crate::store::RouterStoreData::default();
        store.settings.fakeip_enabled = true;
        let v6_on = crate::store::EffectiveIpv6State::Full;
        let v6_off = crate::store::EffectiveIpv6State::Disabled;

        std::fs::write(
            &cfg_path,
            r#"{"dns":{"servers":[{"type":"fakeip","tag":"dns-fakeip","inet4_range":"198.18.0.0/15"}]}}"#,
        )
        .unwrap();
        assert!(!CoreManager::core_config_ipv6_matches(
            &cfg_path, &store, v6_on
        ));
        assert!(CoreManager::core_config_ipv6_matches(
            &cfg_path, &store, v6_off
        ));

        std::fs::write(
            &cfg_path,
            r#"{"dns":{"servers":[{"type":"fakeip","tag":"dns-fakeip","inet4_range":"198.18.0.0/15","inet6_range":"fc00::/18"}]}}"#,
        )
        .unwrap();
        assert!(CoreManager::core_config_ipv6_matches(
            &cfg_path, &store, v6_on
        ));
        assert!(!CoreManager::core_config_ipv6_matches(
            &cfg_path, &store, v6_off
        ));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
