//! `tachyon-core` process lifecycle manager, Clash API & `/tachyon/*` client,
//! Autonomous Watchdog + Reconciler loop, subscription fetcher, and parallel RTT prober.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64_STD;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
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
use crate::switch_history::{
    Groups as SwitchGroups, Recorder as SwitchRecorder, Source as SwitchSource,
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
    pub(crate) reload_lock: Mutex<()>,
    sub_refresh_lock: Mutex<()>,
    sub_last_attempt: Mutex<HashMap<String, i64>>,
    prev_totals: Mutex<Option<TrafficSampleBaseline>>,
    last_net_stack_fingerprint: Mutex<Option<String>>,
    intentional_stop: AtomicBool,
    auto_rollback_in_flight: AtomicBool,
    last_ipv6_resync_ts: PortableAtomicU64,
    boot_recovery_attempts: AtomicU32,
    last_boot_recovery_ts: PortableAtomicU64,
    pub watchdog: Mutex<crate::watchdog::WatchdogState>,
    switch_history: std::sync::OnceLock<Arc<SwitchRecorder>>,
}

static CLASH_CRED_EPOCH: crate::store::PortableAtomicU64 = crate::store::PortableAtomicU64::new(0);

impl CoreManager {
    pub fn invalidate_clash_cred_cache() {
        CLASH_CRED_EPOCH.fetch_add(1, Ordering::AcqRel);
    }

    pub fn clash_cred_epoch() -> u64 {
        CLASH_CRED_EPOCH.load(Ordering::Acquire)
    }

    pub fn is_telemetry_active(&self) -> bool {
        self.state
            .is_telemetry_active(crate::store::unix_now_u64(), TELEMETRY_ACTIVE_WINDOW_SECS)
    }

    pub async fn is_data_plane_busy(&self) -> bool {
        let lite_mode = { self.state.data.read().await.settings.lite_mode };
        sys_info::is_lite_data_plane_busy(lite_mode)
    }

    pub fn new(state: Arc<AppState>) -> Arc<Self> {
        Arc::new(Self {
            state,
            proc: Mutex::new(None),
            reload_lock: Mutex::new(()),
            sub_refresh_lock: Mutex::new(()),
            sub_last_attempt: Mutex::new(HashMap::new()),
            prev_totals: Mutex::new(None),
            last_net_stack_fingerprint: Mutex::new(None),
            intentional_stop: AtomicBool::new(false),
            auto_rollback_in_flight: AtomicBool::new(false),
            last_ipv6_resync_ts: PortableAtomicU64::new(0),
            boot_recovery_attempts: AtomicU32::new(0),
            last_boot_recovery_ts: PortableAtomicU64::new(0),
            watchdog: Mutex::new(crate::watchdog::WatchdogState::default()),
            switch_history: std::sync::OnceLock::new(),
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

    pub(crate) fn rotate_core_log_on_start(log_dir: &Path) -> PathBuf {
        let _ = std::fs::create_dir_all(log_dir);
        let log_path = log_dir.join("tachyon-core.log");
        let prev_path = log_dir.join("tachyon-core.log.prev");
        if std::fs::metadata(&log_path).is_ok_and(|m| m.len() > 0) {
            let _ = std::fs::rename(&log_path, &prev_path);
        }
        let header = format!(
            "--- tachyon-core started (unix={}) ---\n",
            crate::store::unix_now_u64()
        );
        let _ = std::fs::write(&log_path, header.as_bytes());
        log_path
    }

    fn append_core_log_line(path: &Path, line: &str) {
        use std::io::Write as _;
        const MAX_CORE_LOG_BYTES: u64 = 512 * 1024;
        if std::fs::metadata(path).is_ok_and(|m| m.len() >= MAX_CORE_LOG_BYTES) {
            let prev_path = path.with_file_name("tachyon-core.log.prev");
            let _ = std::fs::rename(path, &prev_path);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(file, "{line}");
        }
    }

    async fn drain_core_log_stream_to_file<R>(
        stream: R,
        st: Arc<AppState>,
        log_file_path: Option<PathBuf>,
    ) where
        R: tokio::io::AsyncRead + Unpin,
    {
        const MAX_LINE_BYTES: usize = 16 * 1024;
        let mut reader = BufReader::with_capacity(8192, stream);
        let mut line_buf: Vec<u8> = Vec::with_capacity(512);
        let mut discarding = false;
        loop {
            let avail = match reader.fill_buf().await {
                Ok([]) => break,
                Ok(b) => b,
                Err(_) => break,
            };
            let (consume_len, saw_nl) = if let Some(nl_pos) = avail.iter().position(|&b| b == b'\n')
            {
                (nl_pos + 1, true)
            } else {
                (avail.len(), false)
            };
            if !discarding {
                let raw_slice = &avail[..consume_len.saturating_sub(usize::from(saw_nl))];
                let take_bytes = raw_slice.strip_suffix(b"\r").unwrap_or(raw_slice);
                let room = MAX_LINE_BYTES.saturating_sub(line_buf.len());
                if take_bytes.len() <= room {
                    line_buf.extend_from_slice(take_bytes);
                } else {
                    line_buf.extend_from_slice(&take_bytes[..room]);
                    discarding = true;
                }
            }
            reader.consume(consume_len);
            if saw_nl {
                if !line_buf.is_empty() {
                    let msg = String::from_utf8_lossy(&line_buf);
                    let clean = if discarding {
                        format!("{msg} [truncated]")
                    } else {
                        msg.into_owned()
                    };
                    if let Some(ref p) = log_file_path {
                        Self::append_core_log_line(p, &clean);
                    }
                    st.live.write().await.push_log(&clean);
                    line_buf.clear();
                }
                discarding = false;
            }
        }
        if !line_buf.is_empty() {
            let msg = String::from_utf8_lossy(&line_buf);
            if let Some(ref p) = log_file_path {
                Self::append_core_log_line(p, &msg);
            }
            st.live.write().await.push_log(&msg);
        }
    }

    async fn read_pipe_bounded<R: tokio::io::AsyncRead + Unpin>(
        mut r: R,
        limit: usize,
    ) -> std::io::Result<Vec<u8>> {
        let mut out = Vec::new();
        let mut buf = [0u8; 8192];
        loop {
            let n = r.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            if out.len().saturating_add(n) > limit {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("process output exceeds {limit} byte limit"),
                ));
            }
            out.extend_from_slice(&buf[..n]);
        }
        Ok(out)
    }

    async fn run_command_stdin_output_with_timeout(
        cmd: &mut Command,
        stdin_bytes: Option<&[u8]>,
        timeout: Duration,
    ) -> std::io::Result<std::process::Output> {
        const MAX_STDOUT_BYTES: usize = 16 * 1024 * 1024;
        const MAX_STDERR_BYTES: usize = 1024 * 1024;
        cmd.stdin(if stdin_bytes.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
        let mut child = cmd.spawn()?;
        if let Some(input) = stdin_bytes
            && let Some(mut stdin_pipe) = child.stdin.take()
        {
            let data = input.to_vec();
            tokio::spawn(async move {
                let _ = stdin_pipe.write_all(&data).await;
                let _ = stdin_pipe.shutdown().await;
            });
        }
        let stdout_pipe = child.stdout.take();
        let stderr_pipe = child.stderr.take();
        let fut = async {
            let out_fut = async {
                match stdout_pipe {
                    Some(r) => Self::read_pipe_bounded(r, MAX_STDOUT_BYTES).await,
                    None => Ok(Vec::new()),
                }
            };
            let err_fut = async {
                match stderr_pipe {
                    Some(r) => Self::read_pipe_bounded(r, MAX_STDERR_BYTES).await,
                    None => Ok(Vec::new()),
                }
            };
            let (out_bytes, err_bytes) = tokio::try_join!(out_fut, err_fut)?;
            let status = child.wait().await?;
            Ok::<std::process::Output, std::io::Error>(std::process::Output {
                status,
                stdout: out_bytes,
                stderr: err_bytes,
            })
        };
        match tokio::time::timeout(timeout, fut).await {
            Ok(Ok(out)) => Ok(out),
            Ok(Err(e)) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                Err(e)
            }
            Err(_) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    format!("command timed out after {}ms", timeout.as_millis()),
                ))
            }
        }
    }

    async fn run_command_output_with_timeout(
        cmd: &mut Command,
        timeout: Duration,
    ) -> std::io::Result<std::process::Output> {
        Self::run_command_stdin_output_with_timeout(cmd, None, timeout).await
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
        let platform_bin = crate::platform::paths()
            .bin_dir
            .join(bin_name)
            .to_string_lossy()
            .into_owned();
        for candidate in [
            platform_bin,
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

    fn write_empty_ruleset_stub(tag: &str, path_hint: Option<&str>) -> PathBuf {
        let tmp_rs_dir = std::env::temp_dir().join("tachyon-rulesets");
        let _ = std::fs::create_dir_all(&tmp_rs_dir);
        let raw_name = path_hint
            .and_then(|p| Path::new(p).file_name().and_then(|n| n.to_str()))
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(tag);
        let clean_name: String = raw_name
            .trim_end_matches(".trs")
            .trim_end_matches(".srs")
            .trim_end_matches(".json")
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        let fallback_json = tmp_rs_dir.join(format!("{clean_name}.empty.json"));
        let _ = std::fs::write(&fallback_json, br#"{"version":3,"rules":[]}"#);
        fallback_json
    }

    pub fn sanitize_candidate_local_rulesets(candidate_cfg: &mut Value) {
        let persistent_dir = std::env::var("TACHYON_PERSISTENT_RULESETS_DIR")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| crate::platform::paths().rulesets_dir.clone());

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
            let tag = obj
                .get("tag")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let is_adguard = tag.starts_with("adguard-");
            if !tag.starts_with("trs-") && !tag.starts_with("builtin-") && !is_adguard {
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
            if is_adguard {
                let _ = std::fs::remove_file(rs_path);
                let json_path = rs_path.with_extension("json");
                if crate::adguard_hosts::ruleset_file_has_entries(&json_path) {
                    obj.insert("format".into(), json!("source"));
                    obj.insert("path".into(), json!(json_path.to_string_lossy()));
                } else {
                    let fallback_json = Self::write_empty_ruleset_stub(&tag, Some(&rs_path_str));
                    obj.insert("format".into(), json!("source"));
                    obj.insert("path".into(), json!(fallback_json.to_string_lossy()));
                }
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
            let fallback_json = Self::write_empty_ruleset_stub(&tag, Some(&rs_path_str));
            obj.insert("format".into(), json!("source"));
            obj.insert("path".into(), json!(fallback_json.to_string_lossy()));
        }
    }

    fn check_custom_local_ruleset(obj: &serde_json::Map<String, Value>) -> Result<(), String> {
        let tag = obj.get("tag").and_then(Value::as_str).unwrap_or("");
        let path_str = obj.get("path").and_then(Value::as_str).unwrap_or("").trim();
        if path_str.is_empty() {
            return Err(format!("custom local rule_set '{tag}' has an empty path"));
        }
        let format = obj
            .get("format")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if !matches!(
            format,
            "source" | "binary" | "trs" | "tsr" | "adblock" | "hosts"
        ) {
            return Err(format!(
                "custom local rule_set '{tag}' ({path_str}) has unsupported format '{format}'"
            ));
        }
        let path = Path::new(path_str);
        let meta = std::fs::metadata(path).map_err(|e| {
            format!("custom local rule_set '{tag}' file not readable at '{path_str}': {e}")
        })?;
        if !meta.is_file() {
            return Err(format!(
                "custom local rule_set '{tag}' path '{path_str}' is not a regular file"
            ));
        }
        if matches!(format, "adblock" | "hosts") {
            let _ = std::fs::read_to_string(path).map_err(|e| {
                format!("custom local rule_set '{tag}' at '{path_str}' is not valid UTF-8: {e}")
            })?;
        }
        if format == "source" {
            let raw = std::fs::read_to_string(path).map_err(|e| {
                format!("failed to read custom local rule_set '{tag}' at '{path_str}': {e}")
            })?;
            let parsed: Value = serde_json::from_str(&raw).map_err(|e| {
                format!("custom local rule_set '{tag}' at '{path_str}' is invalid JSON: {e}")
            })?;
            let Some(root) = parsed.as_object() else {
                return Err(format!(
                    "custom local rule_set '{tag}' at '{path_str}' must be a JSON object"
                ));
            };
            if !root.get("rules").is_some_and(Value::is_array) {
                return Err(format!(
                    "custom local rule_set '{tag}' at '{path_str}' is missing a 'rules' array"
                ));
            }
        }
        Ok(())
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn validate_custom_local_rulesets(candidate_cfg: &Value) -> anyhow::Result<()> {
        let Some(rule_sets) = candidate_cfg
            .pointer("/route/rule_set")
            .and_then(Value::as_array)
        else {
            return Ok(());
        };
        for rs in rule_sets {
            let Some(obj) = rs.as_object() else {
                continue;
            };
            if obj.get("type").and_then(Value::as_str) != Some("local") {
                continue;
            }
            let tag = obj.get("tag").and_then(Value::as_str).unwrap_or("");
            if !tag.starts_with("custom-local-") {
                continue;
            }
            Self::check_custom_local_ruleset(obj).map_err(anyhow::Error::msg)?;
        }
        Ok(())
    }

    /// Replace unreadable or malformed `custom-local-*` rule-sets with empty stubs and record errors
    /// instead of aborting `tachyon-core` startup.
    pub fn sanitize_broken_custom_local_rulesets(
        candidate_cfg: &mut Value,
        quarantined: &mut BTreeMap<String, String>,
    ) -> usize {
        let mut broken: Vec<(String, Option<String>, String)> = Vec::new();
        if let Some(rule_sets) = candidate_cfg
            .pointer("/route/rule_set")
            .and_then(Value::as_array)
        {
            for rs in rule_sets {
                let Some(obj) = rs.as_object() else {
                    continue;
                };
                if obj.get("type").and_then(Value::as_str) != Some("local") {
                    continue;
                }
                let tag = obj
                    .get("tag")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if !tag.starts_with("custom-local-") {
                    continue;
                }
                if let Err(err) = Self::check_custom_local_ruleset(obj) {
                    let path_hint = obj
                        .get("path")
                        .and_then(Value::as_str)
                        .map(ToString::to_string);
                    broken.push((tag, path_hint, err));
                }
            }
        }
        if broken.is_empty() {
            return 0;
        }
        let mut tag_to_section: HashMap<String, String> = HashMap::new();
        if let Some(rules) = candidate_cfg
            .pointer("/route/rules")
            .and_then(Value::as_array)
        {
            for rule in rules {
                let Some(out_tag) = rule.get("outbound").and_then(Value::as_str) else {
                    continue;
                };
                let Some(sec_id) = Self::extract_section_id_from_tag(out_tag) else {
                    continue;
                };
                if let Some(rs_arr) = rule.get("rule_set").and_then(Value::as_array) {
                    for rs_tag in rs_arr.iter().filter_map(Value::as_str) {
                        tag_to_section
                            .entry(rs_tag.to_string())
                            .or_insert_with(|| sec_id.clone());
                    }
                }
            }
        }
        let broken_tags: HashMap<String, (Option<String>, String)> = broken
            .iter()
            .map(|(tag, path_hint, err)| (tag.clone(), (path_hint.clone(), err.clone())))
            .collect();
        if let Some(rule_sets) = candidate_cfg
            .pointer_mut("/route/rule_set")
            .and_then(Value::as_array_mut)
        {
            for rs in rule_sets {
                let Some(obj) = rs.as_object_mut() else {
                    continue;
                };
                let tag = obj
                    .get("tag")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if let Some((path_hint, _)) = broken_tags.get(&tag) {
                    let fallback_json = Self::write_empty_ruleset_stub(&tag, path_hint.as_deref());
                    obj.insert("format".into(), json!("source"));
                    obj.insert("path".into(), json!(fallback_json.to_string_lossy()));
                }
            }
        }
        for (tag, _, err) in &broken {
            let key = tag_to_section
                .get(tag)
                .cloned()
                .unwrap_or_else(|| "_rules".to_string());
            let msg = format!(
                "Локальный список правил '{tag}' повреждён или недоступен (подменена пустая заглушка): {err}"
            );
            quarantined
                .entry(key)
                .and_modify(|prev| {
                    if !prev.contains(tag.as_str()) {
                        prev.push_str("; ");
                        prev.push_str(&msg);
                    }
                })
                .or_insert(msg);
        }
        broken.len()
    }

    pub fn effective_core_config_path_for(
        state: &AppState,
        settings: &crate::store::GlobalSettings,
    ) -> PathBuf {
        let p = crate::platform::paths();
        let state_dir = state.path.parent().unwrap_or_else(|| Path::new("data"));
        let is_tmp_staging = state_dir.to_string_lossy().starts_with("/tmp/tachyon-rs")
            && (p.init_script.exists() || Path::new("/etc/init.d/tachyon").exists());
        if is_tmp_staging {
            return state_dir.join("tachyon-core-config.json");
        }
        let configured = settings.core_config_path.trim();
        if configured.is_empty() {
            p.core_config_dir.join("config.json")
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

    pub fn section_errors_path() -> PathBuf {
        crate::store::runtime_state_dir().join("section-errors.json")
    }

    pub fn write_section_errors_to(path: &Path, errors: &BTreeMap<String, String>) {
        if errors.is_empty() {
            let _ = std::fs::remove_file(path);
            return;
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut map = serde_json::Map::new();
        for (k, v) in errors {
            map.insert(k.clone(), json!(v));
        }
        let _ = crypto_gen::write_json_if_changed(path, &Value::Object(map));
    }

    pub fn read_section_errors_from(path: &Path) -> BTreeMap<String, String> {
        let Ok(raw) = std::fs::read_to_string(path) else {
            return BTreeMap::new();
        };
        let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&raw) else {
            return BTreeMap::new();
        };
        map.into_iter()
            .filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string())))
            .collect()
    }

    pub fn write_section_errors(errors: &BTreeMap<String, String>) {
        Self::write_section_errors_to(&Self::section_errors_path(), errors);
    }

    pub fn read_section_errors() -> BTreeMap<String, String> {
        Self::read_section_errors_from(&Self::section_errors_path())
    }

    pub fn format_fault_reason(raw: &str) -> String {
        let trimmed = raw.trim();
        let single: String = trimmed.split_whitespace().collect::<Vec<_>>().join(" ");
        let short: String = single.chars().take(240).collect();
        let lower = single.to_ascii_lowercase();
        if lower.contains("unknown field") {
            format!("неподдерживаемое поле настройки ({short})")
        } else if lower.contains("address already in use")
            || lower.contains("listen tcp")
            || lower.contains("listen udp")
            || lower.contains("bind:")
        {
            format!("порт занят или недоступен ({short})")
        } else if lower.contains("certificate") || lower.contains("private key") {
            format!("ошибка TLS-сертификата или ключа ({short})")
        } else if lower.contains("outbound not found")
            || lower.contains("endpoint not found")
            || lower.contains("detour")
        {
            format!("ссылка на несуществующий узел или outbound ({short})")
        } else if lower.contains("rule_set") || lower.contains("rule-set") {
            format!("ошибка списка правил маршрутизации ({short})")
        } else {
            short
        }
    }

    fn extract_section_id_from_tag(tag: &str) -> Option<String> {
        let t = tag.trim();
        if let Some(rest) = t.strip_prefix("sec-") {
            if let Some(id) = rest
                .strip_suffix("-out")
                .or_else(|| rest.strip_suffix("-mix"))
                && !id.is_empty()
            {
                return Some(id.to_string());
            }
            if !rest.is_empty() {
                return Some(rest.to_string());
            }
        }
        for prefix in ["bal-", "urltest-", "pri-", "sel-", "desync-"] {
            if let Some(rest) = t.strip_prefix(prefix) {
                let id = rest.strip_suffix("-out").unwrap_or(rest);
                if !id.is_empty() {
                    return Some(id.to_string());
                }
            }
        }
        None
    }

    fn extract_bracket_index(reason: &str, key: &str) -> Option<usize> {
        let pattern = format!("{key}[");
        let idx = reason.find(&pattern)?;
        let rest = &reason[idx + pattern.len()..];
        let end = rest.find(']')?;
        rest[..end].trim().parse::<usize>().ok()
    }

    fn extract_unknown_field_name(norm: &str) -> Option<String> {
        for needle in ["unknown field \"", "unknown field `"] {
            if let Some(pos) = norm.find(needle) {
                let rest = &norm[pos + needle.len()..];
                let delim = needle.chars().last().unwrap_or('"');
                if let Some(end) = rest.find(delim) {
                    let field = rest[..end].trim();
                    if !field.is_empty() {
                        return Some(field.to_string());
                    }
                }
            }
        }
        None
    }

    fn strip_optional_unknown_fields(cfg_val: &mut Value, reason: &str) -> bool {
        let norm = Self::normalize_unknown_field_reason(reason);
        let mut changed = false;
        for field in ["tcp_profile", "tcp_fragment"] {
            if norm.contains(&format!("json: unknown field \"{field}\""))
                || norm.contains(&format!("unknown field `{field}`"))
            {
                for array_key in ["outbounds", "endpoints"] {
                    if let Some(arr) = cfg_val.get_mut(array_key).and_then(Value::as_array_mut) {
                        for item in arr {
                            if let Some(map) = item.as_object_mut()
                                && map.remove(field).is_some()
                            {
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
        if !changed
            && let Some(field) = Self::extract_unknown_field_name(&norm)
            && !matches!(
                field.as_str(),
                "type" | "tag" | "outbounds" | "servers" | "rules" | "inbounds" | "route" | "dns"
            )
        {
            for array_key in ["outbounds", "endpoints", "inbounds"] {
                if let Some(idx) = Self::extract_bracket_index(&norm, array_key)
                    && let Some(map) = cfg_val
                        .pointer_mut(&format!("/{array_key}/{idx}"))
                        .and_then(Value::as_object_mut)
                    && map.remove(&field).is_some()
                {
                    return true;
                }
            }
            if norm.contains("dns.servers")
                && let Some(idx) = Self::extract_bracket_index(&norm, "servers")
                && let Some(map) = cfg_val
                    .pointer_mut(&format!("/dns/servers/{idx}"))
                    .and_then(Value::as_object_mut)
                && map.remove(&field).is_some()
            {
                return true;
            }
        }
        changed
    }

    fn resolve_section_id_for_tag(
        tag: &str,
        cfg: &Value,
        store: &crate::store::RouterStoreData,
    ) -> Option<String> {
        if let Some(sec_id) = Self::extract_section_id_from_tag(tag)
            && (store.sections.iter().any(|s| s.id == sec_id) || tag.starts_with("sec-"))
        {
            return Some(sec_id);
        }
        if let Some(obs) = cfg.get("outbounds").and_then(Value::as_array) {
            for ob in obs {
                let Some(group_tag) = ob.get("tag").and_then(Value::as_str) else {
                    continue;
                };
                if ob
                    .get("outbounds")
                    .and_then(Value::as_array)
                    .is_some_and(|arr| arr.iter().any(|v| v.as_str() == Some(tag)))
                    && let Some(sec_id) = Self::extract_section_id_from_tag(group_tag)
                {
                    return Some(sec_id);
                }
            }
        }
        if let Some(rules) = cfg.pointer("/route/rules").and_then(Value::as_array) {
            for rule in rules {
                if (rule.get("outbound").and_then(Value::as_str) == Some(tag)
                    || rule
                        .get("inbound")
                        .and_then(Value::as_array)
                        .is_some_and(|arr| arr.iter().any(|v| v.as_str() == Some(tag))))
                    && let Some(out_tag) = rule.get("outbound").and_then(Value::as_str)
                    && let Some(sec_id) = Self::extract_section_id_from_tag(out_tag)
                {
                    return Some(sec_id);
                }
            }
        }
        for src in &store.outbound_sources {
            let prefix = format!("src-{}-", src.id);
            if (tag == format!("src-{}", src.id) || tag.starts_with(&prefix))
                && let Some(sec) = store
                    .sections
                    .iter()
                    .find(|s| s.outbound_source_refs.iter().any(|id| id == &src.id))
            {
                return Some(sec.id.clone());
            }
        }
        Self::extract_section_id_from_tag(tag)
    }

    fn section_label(store: &crate::store::RouterStoreData, sec_id: &str) -> String {
        store
            .sections
            .iter()
            .find(|s| s.id == sec_id)
            .map(|s| {
                let n = s.label.trim();
                if n.is_empty() {
                    format!("Секция '{}'", s.id)
                } else {
                    format!("Секция '{n}' ({})", s.id)
                }
            })
            .unwrap_or_else(|| format!("Секция '{sec_id}'"))
    }

    /// Map a `tachyon-core` validation or runtime error back to an entity key for UI diagnostics.
    pub fn attribute_error_to_store_entity(
        reason: &str,
        cfg: &Value,
        store: &crate::store::RouterStoreData,
    ) -> (String, String) {
        let norm = Self::normalize_unknown_field_reason(reason);
        let lower = norm.to_ascii_lowercase();

        if lower.contains("config: dns")
            || lower.contains("dns.servers")
            || lower.contains("dns.rules")
        {
            return ("_dns".to_string(), "Настройки DNS".to_string());
        }
        if let Some(idx) = Self::extract_bracket_index(&norm, "outbounds")
            .or_else(|| Self::extract_bracket_index(&norm, "outbound"))
            && let Some(tag) = cfg
                .pointer(&format!("/outbounds/{idx}/tag"))
                .and_then(Value::as_str)
        {
            if let Some(sec_id) = Self::resolve_section_id_for_tag(tag, cfg, store) {
                return (sec_id.clone(), Self::section_label(store, &sec_id));
            }
            return (format!("outbound:{tag}"), format!("Исходящий узел '{tag}'"));
        }
        if let Some(idx) = Self::extract_bracket_index(&norm, "endpoints")
            .or_else(|| Self::extract_bracket_index(&norm, "endpoint"))
            && let Some(tag) = cfg
                .pointer(&format!("/endpoints/{idx}/tag"))
                .and_then(Value::as_str)
        {
            if let Some(sec_id) = Self::resolve_section_id_for_tag(tag, cfg, store) {
                return (sec_id.clone(), Self::section_label(store, &sec_id));
            }
            return (format!("server:{tag}"), format!("Endpoint '{tag}'"));
        }
        if let Some(idx) = Self::extract_bracket_index(&norm, "inbounds")
            .or_else(|| Self::extract_bracket_index(&norm, "inbound"))
            && let Some(tag) = cfg
                .pointer(&format!("/inbounds/{idx}/tag"))
                .and_then(Value::as_str)
        {
            if matches!(tag, "tproxy-in" | "tun-in" | "mixed-in" | "dns-in") {
                return (
                    "_settings".to_string(),
                    format!("Базовые сетевые настройки ({tag})"),
                );
            }
            if let Some(sec_id) = Self::resolve_section_id_for_tag(tag, cfg, store) {
                return (sec_id.clone(), Self::section_label(store, &sec_id));
            }
            return ("_servers".to_string(), format!("Входящий сервер '{tag}'"));
        }
        if Self::extract_bracket_index(&norm, "rule_set").is_some()
            || lower.contains("rule_set")
            || lower.contains("rule-set")
        {
            return (
                "_rules".to_string(),
                "Списки правил маршрутизации".to_string(),
            );
        }
        if let Some(idx) = Self::extract_bracket_index(&norm, "route.rules")
            .or_else(|| Self::extract_bracket_index(&norm, "rules"))
        {
            if let Some(out_tag) = cfg
                .pointer(&format!("/route/rules/{idx}/outbound"))
                .and_then(Value::as_str)
                && let Some(sec_id) = Self::resolve_section_id_for_tag(out_tag, cfg, store)
            {
                return (sec_id.clone(), Self::section_label(store, &sec_id));
            }
            return ("_rules".to_string(), "Правила маршрутизации".to_string());
        }
        for ptr in ["/outbounds", "/endpoints", "/inbounds"] {
            if let Some(items) = cfg.pointer(ptr).and_then(Value::as_array) {
                for item in items {
                    let Some(tag) = item.get("tag").and_then(Value::as_str) else {
                        continue;
                    };
                    if matches!(tag, "direct" | "block" | "tproxy-in" | "tun-in" | "dns-in") {
                        continue;
                    }
                    if norm.contains(tag) {
                        if let Some(sec_id) = Self::resolve_section_id_for_tag(tag, cfg, store) {
                            return (sec_id.clone(), Self::section_label(store, &sec_id));
                        }
                        return ("_settings".to_string(), format!("Элемент '{tag}'"));
                    }
                }
            }
        }
        if lower.contains("experimental") || lower.contains("clash_api") || lower.contains("cache")
        {
            return (
                "_settings".to_string(),
                "Системные настройки ядра".to_string(),
            );
        }
        if lower.contains("route") {
            return ("_rules".to_string(), "Правила маршрутизации".to_string());
        }
        (
            "_core_runtime".to_string(),
            "Запуск ядра tachyon-core".to_string(),
        )
    }

    fn strip_outbound_tag_and_repair_refs(cfg: &mut Value, target_tag: &str) -> bool {
        if target_tag.is_empty() || matches!(target_tag, "direct" | "block") {
            return false;
        }
        let mut changed = false;
        let mut removed_tags: HashSet<String> = HashSet::new();
        let mut pending: Vec<String> = vec![target_tag.to_string()];

        while let Some(cur_tag) = pending.pop() {
            if matches!(cur_tag.as_str(), "direct" | "block")
                || !removed_tags.insert(cur_tag.clone())
            {
                continue;
            }
            if let Some(obs) = cfg.get_mut("outbounds").and_then(Value::as_array_mut) {
                let before = obs.len();
                obs.retain(|o| o.get("tag").and_then(Value::as_str) != Some(cur_tag.as_str()));
                if obs.len() != before {
                    changed = true;
                }
            }
            if let Some(eps) = cfg.get_mut("endpoints").and_then(Value::as_array_mut) {
                let before = eps.len();
                eps.retain(|e| e.get("tag").and_then(Value::as_str) != Some(cur_tag.as_str()));
                if eps.len() != before {
                    changed = true;
                }
            }
            let mut emptied_groups: Vec<String> = Vec::new();
            if let Some(obs) = cfg.get_mut("outbounds").and_then(Value::as_array_mut) {
                for ob in obs.iter_mut() {
                    let Some(map) = ob.as_object_mut() else {
                        continue;
                    };
                    let (first_remaining, became_empty, arr_changed) = {
                        let Some(arr) = map.get_mut("outbounds").and_then(Value::as_array_mut)
                        else {
                            continue;
                        };
                        let before = arr.len();
                        arr.retain(|v| v.as_str() != Some(cur_tag.as_str()));
                        let first = arr.first().and_then(Value::as_str).map(str::to_string);
                        (first, arr.is_empty(), arr.len() != before)
                    };
                    if arr_changed {
                        changed = true;
                    }
                    if map.get("default").and_then(Value::as_str) == Some(cur_tag.as_str()) {
                        if let Some(first) = first_remaining {
                            map.insert("default".into(), json!(first));
                        } else {
                            map.remove("default");
                        }
                    }
                    if became_empty && let Some(gtag) = map.get("tag").and_then(Value::as_str) {
                        emptied_groups.push(gtag.to_string());
                    }
                }
                if !emptied_groups.is_empty() {
                    obs.retain(|o| {
                        o.get("tag")
                            .and_then(Value::as_str)
                            .is_none_or(|t| !emptied_groups.iter().any(|g| g == t))
                    });
                    changed = true;
                }
            }
            pending.extend(emptied_groups);
        }

        if let Some(dns_servers) = cfg
            .pointer_mut("/dns/servers")
            .and_then(Value::as_array_mut)
        {
            for srv in dns_servers.iter_mut() {
                if let Some(map) = srv.as_object_mut()
                    && map
                        .get("detour")
                        .and_then(Value::as_str)
                        .is_some_and(|d| removed_tags.contains(d))
                {
                    map.insert("detour".into(), json!("direct"));
                    changed = true;
                }
            }
        }
        if let Some(rules) = cfg
            .pointer_mut("/route/rules")
            .and_then(Value::as_array_mut)
        {
            let before = rules.len();
            rules.retain(|r| {
                r.get("outbound")
                    .and_then(Value::as_str)
                    .is_none_or(|o| !removed_tags.contains(o))
            });
            if rules.len() != before {
                changed = true;
            }
        }
        changed
    }

    fn apply_safe_udp_dns_block(cfg: &mut Value) -> bool {
        let desired = json!({
            "servers": [
                {
                    "type": "udp",
                    "tag": "dns-bootstrap",
                    "server": "77.88.8.8",
                    "server_port": 53,
                    "detour": "direct"
                },
                {
                    "type": "udp",
                    "tag": "dns-remote-1",
                    "server": "1.1.1.1",
                    "server_port": 53,
                    "detour": "direct"
                },
                {
                    "type": "group",
                    "tag": "dns-remote",
                    "mode": "stable",
                    "error_ttl": "30s",
                    "timeout": "8s",
                    "servers": ["dns-remote-1", "dns-bootstrap"]
                }
            ],
            "rules": [],
            "final": "dns-remote",
            "strategy": "prefer_ipv4",
            "reverse_mapping": true
        });
        let changed = cfg.get("dns") != Some(&desired);
        if let Some(map) = cfg.as_object_mut() {
            map.insert("dns".into(), desired);
            if let Some(route_map) = map.get_mut("route").and_then(Value::as_object_mut) {
                route_map.insert("default_domain_resolver".into(), json!("dns-remote"));
            }
        }
        changed
    }

    fn strip_broken_entity_from_cfg(cfg: &mut Value, reason: &str) -> bool {
        let norm = Self::normalize_unknown_field_reason(reason);
        let lower = norm.to_ascii_lowercase();

        if lower.contains("config: dns")
            || lower.contains("dns.servers")
            || lower.contains("dns.rules")
        {
            if lower.contains("dns.rules")
                && let Some(idx) = Self::extract_bracket_index(&norm, "rules")
                && let Some(rules) = cfg.pointer_mut("/dns/rules").and_then(Value::as_array_mut)
                && idx < rules.len()
            {
                rules.remove(idx);
                return true;
            }
            return Self::apply_safe_udp_dns_block(cfg);
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "outbounds")
            .or_else(|| Self::extract_bracket_index(&norm, "outbound"))
            && let Some(tag) = cfg
                .pointer(&format!("/outbounds/{idx}/tag"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
            && Self::strip_outbound_tag_and_repair_refs(cfg, &tag)
        {
            return true;
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "endpoints")
            .or_else(|| Self::extract_bracket_index(&norm, "endpoint"))
            && let Some(tag) = cfg
                .pointer(&format!("/endpoints/{idx}/tag"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
            && Self::strip_outbound_tag_and_repair_refs(cfg, &tag)
        {
            return true;
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "inbounds")
            .or_else(|| Self::extract_bracket_index(&norm, "inbound"))
            && let Some(tag) = cfg
                .pointer(&format!("/inbounds/{idx}/tag"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
            && !matches!(tag.as_str(), "tproxy-in" | "tun-in" | "mixed-in" | "dns-in")
            && let Some(inbs) = cfg.get_mut("inbounds").and_then(Value::as_array_mut)
        {
            inbs.remove(idx);
            if let Some(rules) = cfg
                .pointer_mut("/route/rules")
                .and_then(Value::as_array_mut)
            {
                rules.retain(|r| {
                    !r.get("inbound")
                        .and_then(Value::as_array)
                        .is_some_and(|arr| arr.iter().all(|v| v.as_str() == Some(tag.as_str())))
                });
            }
            return true;
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "rule_set")
            && let Some(rs_tag) = cfg
                .pointer(&format!("/route/rule_set/{idx}/tag"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
            && let Some(rs_obj) = cfg
                .pointer_mut(&format!("/route/rule_set/{idx}"))
                .and_then(Value::as_object_mut)
        {
            let fallback_json = Self::write_empty_ruleset_stub(&rs_tag, None);
            rs_obj.remove("url");
            rs_obj.remove("download_detour");
            rs_obj.remove("http_client");
            rs_obj.remove("update_interval");
            rs_obj.insert("type".into(), json!("local"));
            rs_obj.insert("format".into(), json!("source"));
            rs_obj.insert("path".into(), json!(fallback_json.to_string_lossy()));
            return true;
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "route.rules")
            .or_else(|| Self::extract_bracket_index(&norm, "rules"))
            && let Some(rules) = cfg
                .pointer_mut("/route/rules")
                .and_then(Value::as_array_mut)
            && idx < rules.len()
        {
            rules.remove(idx);
            return true;
        }

        let found_tag = ["/outbounds", "/endpoints"]
            .iter()
            .filter_map(|ptr| cfg.pointer(ptr).and_then(Value::as_array))
            .flatten()
            .filter_map(|item| item.get("tag").and_then(Value::as_str))
            .filter(|tag| !matches!(*tag, "direct" | "block") && norm.contains(*tag))
            .max_by_key(|tag| tag.len())
            .map(ToString::to_string);
        if let Some(tag) = found_tag
            && Self::strip_outbound_tag_and_repair_refs(cfg, &tag)
        {
            return true;
        }
        false
    }

    fn section_still_has_active_route(cfg: &Value, sec_id: &str) -> bool {
        let candidate_tags = [
            format!("sec-{sec_id}-out"),
            format!("sel-{sec_id}"),
            format!("sec-{sec_id}"),
        ];
        let exact_bal = format!("bal-{sec_id}");
        let bal_prefix = format!("bal-{sec_id}-");
        let matches_section_tag = |tag: &str| {
            candidate_tags.iter().any(|c| c == tag)
                || tag == exact_bal
                || tag.starts_with(&bal_prefix)
        };
        let has_group = cfg
            .get("outbounds")
            .and_then(Value::as_array)
            .is_some_and(|obs| {
                obs.iter().any(|ob| {
                    let tag = ob.get("tag").and_then(Value::as_str).unwrap_or("");
                    matches_section_tag(tag)
                        && ob
                            .get("outbounds")
                            .and_then(Value::as_array)
                            .is_some_and(|m| !m.is_empty())
                })
            });
        let has_rule = cfg
            .pointer("/route/rules")
            .and_then(Value::as_array)
            .is_some_and(|rules| {
                rules.iter().any(|r| {
                    r.get("outbound")
                        .and_then(Value::as_str)
                        .is_some_and(matches_section_tag)
                })
            })
            || cfg
                .pointer("/route/final")
                .and_then(Value::as_str)
                .is_some_and(matches_section_tag);
        has_group && has_rule
    }

    fn apply_quarantine_failure_step(
        store_snapshot: &crate::store::RouterStoreData,
        cfg: &mut Value,
        quarantined: &mut BTreeMap<String, String>,
        reason: &str,
    ) -> bool {
        if Self::strip_optional_unknown_fields(cfg, reason) {
            return true;
        }
        let (key, label) = Self::attribute_error_to_store_entity(reason, cfg, store_snapshot);
        let pretty = Self::format_fault_reason(reason);
        let entry_msg = format!("{label} не загружена: {pretty}");
        let stripped = Self::strip_broken_entity_from_cfg(cfg, reason);
        let sec_survived = stripped
            && !key.starts_with('_')
            && !key.starts_with("outbound:")
            && !key.starts_with("server:")
            && Self::section_still_has_active_route(cfg, &key);
        if sec_survived {
            eprintln!(
                "[tachyon] {label}: пропущен проблемный узел ({pretty}); секция остаётся активной"
            );
            return true;
        }
        quarantined
            .entry(key)
            .and_modify(|prev| {
                if !prev.contains(pretty.as_str()) {
                    prev.push_str("; ");
                    prev.push_str(&entry_msg);
                }
            })
            .or_insert(entry_msg);
        stripped
    }

    fn finalize_safe_minimal_fallback(
        store_snapshot: &crate::store::RouterStoreData,
        failed_cfg: &Value,
        quarantined: &mut BTreeMap<String, String>,
        last_err: Option<String>,
    ) -> Value {
        let reason = last_err.unwrap_or_else(|| "конфигурация не прошла проверку".to_string());
        let (attr_key, attr_label) =
            Self::attribute_error_to_store_entity(&reason, failed_cfg, store_snapshot);
        let pretty = Self::format_fault_reason(&reason);
        quarantined.entry(attr_key).or_insert_with(|| {
            format!("{attr_label}: {pretty}. Активирован безопасный минимальный режим.")
        });
        quarantined.entry("_core_runtime".to_string()).or_insert_with(|| {
            format!(
                "Основная конфигурация не прошла проверку ядра ({pretty}). Запущен минимальный режим (DNS + direct), чтобы сохранить сеть."
            )
        });
        config_gen::compile_safe_minimal_core_config_with_wan6(
            store_snapshot,
            crate::store::detect_wan6_runtime_available(),
        )
    }

    pub fn quarantine_with_checker<F>(
        store_snapshot: &crate::store::RouterStoreData,
        initial_cfg: Value,
        mut quarantined: BTreeMap<String, String>,
        mut checker: F,
    ) -> (Value, BTreeMap<String, String>)
    where
        F: FnMut(&Value) -> Result<(), String>,
    {
        let mut cfg = initial_cfg;
        Self::sanitize_candidate_local_rulesets(&mut cfg);
        Self::sanitize_broken_custom_local_rulesets(&mut cfg, &mut quarantined);

        let mut last_err: Option<String> = None;
        for _ in 0..16 {
            match checker(&cfg) {
                Ok(()) => return (cfg, quarantined),
                Err(reason) => {
                    let can_continue = Self::apply_quarantine_failure_step(
                        store_snapshot,
                        &mut cfg,
                        &mut quarantined,
                        &reason,
                    );
                    last_err = Some(reason);
                    if !can_continue {
                        break;
                    }
                }
            }
        }

        if checker(&cfg).is_ok() {
            return (cfg, quarantined);
        }

        let safe_cfg =
            Self::finalize_safe_minimal_fallback(store_snapshot, &cfg, &mut quarantined, last_err);
        (safe_cfg, quarantined)
    }

    pub(crate) async fn run_core_check_on_value(
        bin_path: &str,
        candidate_cfg: &Value,
    ) -> Result<(), String> {
        static CHECK_CANDIDATE_SEQ: PortableAtomicU64 = PortableAtomicU64::new(0);
        struct CandidateFileGuard(PathBuf);
        impl Drop for CandidateFileGuard {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }

        let seq = CHECK_CANDIDATE_SEQ.fetch_add(1, Ordering::Relaxed);
        let guard = CandidateFileGuard(std::env::temp_dir().join(format!(
            "tachyon-core-candidate-{}-{seq}.json",
            std::process::id()
        )));
        crypto_gen::write_json_if_changed(&guard.0, candidate_cfg)
            .map_err(|e| format!("failed to write check candidate: {e}"))?;
        let mut cmd = Command::new(bin_path);
        cmd.args(["check", "-c", &guard.0.to_string_lossy()]);
        match Self::run_command_output_with_timeout(&mut cmd, Duration::from_secs(8)).await {
            Ok(out) if out.status.success() => Ok(()),
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let stdout = String::from_utf8_lossy(&out.stdout);
                Err(format!("{}{}", stderr.trim(), stdout.trim()))
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                Err("tachyon-core check timed out after 8s".to_string())
            }
            Err(e) => Err(format!("failed to invoke tachyon-core check: {e}")),
        }
    }

    #[inline(never)]
    async fn compile_or_safe_minimal_with_wan6(
        &self,
        store_snapshot: &crate::store::RouterStoreData,
        wan6_available: Option<bool>,
    ) -> (Value, BTreeMap<String, String>) {
        crate::adguard_hosts::ensure_adguard_trs_compiled_in(
            &crate::store::runtime_state_dir(),
            self,
        )
        .await;
        let effective_wan6 =
            wan6_available.unwrap_or_else(crate::store::detect_wan6_runtime_available);
        let mut seed_errors = BTreeMap::new();
        match config_gen::compile_core_config_with_wan6(store_snapshot, effective_wan6) {
            Ok(v) => (v, seed_errors),
            Err(e) => {
                let pretty = Self::format_fault_reason(&format!("{e:#}"));
                let msg = format!(
                    "Ошибка компиляции конфигурации ({pretty}). Активирован минимальный режим (DNS + direct)."
                );
                self.state
                    .live
                    .write()
                    .await
                    .push_event("warn", "core_mgr", &msg);
                seed_errors.insert("_core_runtime".to_string(), msg);
                (
                    config_gen::compile_safe_minimal_core_config_with_wan6(
                        store_snapshot,
                        effective_wan6,
                    ),
                    seed_errors,
                )
            }
        }
    }

    fn read_total_ram_kb() -> Option<u64> {
        let content = std::fs::read_to_string("/proc/meminfo").ok()?;
        for line in content.lines() {
            if let Some(rest) = line.strip_prefix("MemTotal:") {
                let kb = rest.split_whitespace().next()?.parse::<u64>().ok()?;
                if kb > 0 {
                    return Some(kb);
                }
            }
        }
        None
    }

    /// Resolve effective `TACHYON_MEMLIMIT_MB` (MiB): explicit setting wins; otherwise auto-cap routers (< 640 MiB).
    pub(crate) fn effective_core_memory_limit_mb(
        configured_mb: u32,
        total_ram_kb: Option<u64>,
    ) -> u32 {
        if configured_mb > 0 {
            return configured_mb;
        }
        match total_ram_kb {
            Some(kb) if kb > 0 && kb < 320 * 1024 => ((kb / 1024) / 2).clamp(64, 160) as u32,
            Some(kb) if kb < 640 * 1024 => ((kb / 1024) * 28 / 100).clamp(112, 144) as u32,
            _ => 0,
        }
    }

    fn configure_core_spawn_command(cmd: &mut Command, daemon_mode: bool, memory_limit_mb: u32) {
        cmd.stdin(Stdio::null());
        let effective_limit_mb =
            Self::effective_core_memory_limit_mb(memory_limit_mb, Self::read_total_ram_kb());
        if effective_limit_mb > 0 {
            cmd.env("TACHYON_MEMLIMIT_MB", effective_limit_mb.to_string());
        }
        if daemon_mode {
            cmd.stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
        } else {
            // Standalone CLI `start`/`reload` must never kill or SIGPIPE tachyon-core on exit.
            cmd.stdout(Stdio::null())
                .stderr(Stdio::null())
                .kill_on_drop(false);
            #[cfg(unix)]
            cmd.process_group(0);
        }
    }

    async fn spawn_and_verify_core(
        bin_path: &str,
        cfg_path: &Path,
        memory_limit_mb: u32,
    ) -> Result<Child, String> {
        let mut cmd = Command::new(bin_path);
        cmd.args(["run", "-c", &cfg_path.to_string_lossy()]);
        Self::configure_core_spawn_command(
            &mut cmd,
            crate::ubus_bridge::is_daemon_mode(),
            memory_limit_mb,
        );

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("tachyon-core spawn failed: {e:#}"))?;

        for _ in 0..4 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            if let Ok(Some(status)) = child.try_wait() {
                let mut early_err = String::new();
                if let Some(stderr) = child.stderr.take() {
                    let mut buf = Vec::with_capacity(1024);
                    let _ = tokio::time::timeout(
                        Duration::from_millis(200),
                        stderr.take(1024).read_to_end(&mut buf),
                    )
                    .await;
                    let s = String::from_utf8_lossy(&buf).trim().to_string();
                    if !s.is_empty() {
                        early_err = format!(": {s}");
                    }
                }
                return Err(format!(
                    "tachyon-core exited immediately with {status}{early_err}"
                ));
            }
        }
        Ok(child)
    }

    /// Prepare a runnable `tachyon-core` config, isolating invalid entities instead of failing startup.
    #[inline(never)]
    async fn prepare_and_write_validated_core_config(
        &self,
        store_snapshot: &crate::store::RouterStoreData,
        initial_cfg: Value,
        seed_errors: BTreeMap<String, String>,
    ) -> anyhow::Result<(PathBuf, Value, BTreeMap<String, String>)> {
        let state_dir = self
            .state
            .path
            .parent()
            .unwrap_or_else(|| Path::new("data"));
        let p_layout = crate::platform::paths();
        let is_tmp_staging = state_dir.to_string_lossy().starts_with("/tmp/tachyon-rs")
            && (p_layout.init_script.exists() || Path::new("/etc/init.d/tachyon").exists());

        let bin_path = self.resolve_bin_path().await;
        let run_binary_check = cfg!(target_os = "linux") && Path::new(&bin_path).exists();

        let (prepared_cfg, quarantined) = if run_binary_check {
            let mut cfg = initial_cfg;
            let mut quarantined = seed_errors;
            Self::sanitize_candidate_local_rulesets(&mut cfg);
            Self::sanitize_broken_custom_local_rulesets(&mut cfg, &mut quarantined);

            let mut last_err: Option<String> = None;
            let mut passed = false;
            let check_started = Instant::now();
            const QUARANTINE_CHECK_BUDGET: Duration = Duration::from_secs(12);
            for attempt in 0..16 {
                if attempt > 0 && check_started.elapsed() >= QUARANTINE_CHECK_BUDGET {
                    break;
                }
                match Self::run_core_check_on_value(&bin_path, &cfg).await {
                    Ok(()) => {
                        passed = true;
                        break;
                    }
                    Err(reason) => {
                        let can_continue = Self::apply_quarantine_failure_step(
                            store_snapshot,
                            &mut cfg,
                            &mut quarantined,
                            &reason,
                        );
                        last_err = Some(reason);
                        if !can_continue {
                            break;
                        }
                    }
                }
            }
            if !passed {
                cfg = Self::finalize_safe_minimal_fallback(
                    store_snapshot,
                    &cfg,
                    &mut quarantined,
                    last_err,
                );
            }
            (cfg, quarantined)
        } else {
            Self::quarantine_with_checker(store_snapshot, initial_cfg, seed_errors, |_| Ok(()))
        };

        Self::write_section_errors(&quarantined);
        if !quarantined.is_empty() {
            let mut live = self.state.live.write().await;
            for (k, msg) in &quarantined {
                live.push_event(
                    "warn",
                    "core_mgr",
                    &format!("Изолирована проблемная настройка [{k}]: {msg}"),
                );
            }
        }

        if is_tmp_staging {
            let staging_cfg = state_dir.join("tachyon-core-config.json");
            crypto_gen::write_json_if_changed(&staging_cfg, &prepared_cfg)?;
            return Ok((staging_cfg, prepared_cfg, quarantined));
        }

        let p = Path::new(&store_snapshot.settings.core_config_path);
        let written_path = if crypto_gen::write_json_if_changed(p, &prepared_cfg).is_ok() {
            p.to_path_buf()
        } else {
            let fallback = state_dir.join("tachyon-core-config.json");
            crypto_gen::write_json_if_changed(&fallback, &prepared_cfg)?;
            fallback
        };
        Ok((written_path, prepared_cfg, quarantined))
    }

    fn is_allowed_cache_path(path: &Path) -> bool {
        if path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return false;
        }
        let p_layout = crate::platform::paths();
        let allowed_roots = [
            "/tmp",
            "/var",
            "/etc/tachyon",
            "/etc/tachyon-core",
            "/usr/share/tachyon",
            "/usr/share/tachyon-core",
            "/opt",
            "/mnt",
            "/overlay",
        ];
        let has_posix_root = path.to_str().is_some_and(|s| s.starts_with('/'));
        let in_allowed_root = (path.is_absolute() || has_posix_root)
            && (allowed_roots.iter().any(|r| path.starts_with(r))
                || path.starts_with(&p_layout.data_dir)
                || path.starts_with(&p_layout.core_config_dir)
                || path.starts_with(&p_layout.share_dir)
                || path.starts_with(&p_layout.runtime_tmpfs_dir));
        #[cfg(test)]
        {
            in_allowed_root || path.starts_with(std::env::temp_dir())
        }
        #[cfg(not(test))]
        {
            in_allowed_root
        }
    }

    fn ensure_runtime_cache_dir(cache_path: &str) {
        let trimmed = cache_path.trim();
        if trimmed.is_empty() {
            return;
        }
        let dst = Path::new(trimmed);
        if !Self::is_allowed_cache_path(dst) {
            eprintln!("[tachyon] ignoring disallowed cache_path: {trimmed}");
            return;
        }
        if let Some(parent) = dst.parent()
            && !parent.as_os_str().is_empty()
        {
            let _ = std::fs::create_dir_all(parent);
        }
        if !dst.exists() {
            let p_layout = crate::platform::paths();
            let seed_candidates = [
                p_layout.core_config_dir.join("cache.db"),
                p_layout.share_dir.join("cache.db"),
                PathBuf::from("/etc/tachyon-core/cache.db"),
                PathBuf::from("/usr/share/tachyon-core/cache.db"),
            ];
            for src in &seed_candidates {
                if src.exists() {
                    let _ = std::fs::copy(src, dst);
                    break;
                }
            }
        }
    }

    async fn ensure_server_tls_certs(&self, store_snapshot: &crate::store::RouterStoreData) {
        let bin_path = self.resolve_bin_path().await;
        for srv in &store_snapshot.servers {
            if !srv.enabled || !config_gen::server_requires_tls(srv) {
                continue;
            }
            let (cert_path, key_path) = config_gen::server_tls_cert_key_paths(srv);
            let cert_ok = std::fs::metadata(&cert_path)
                .map(|m| m.is_file() && m.len() > 0)
                .unwrap_or(false);
            let key_ok = std::fs::metadata(&key_path)
                .map(|m| m.is_file() && m.len() > 0)
                .unwrap_or(false);
            if cert_ok && key_ok {
                continue;
            }
            let sni = if !srv.tls_server_name.trim().is_empty() {
                srv.tls_server_name.trim()
            } else if !srv.public_host.trim().is_empty() {
                srv.public_host.trim()
            } else {
                "tachyon.internal"
            };
            match crypto_gen::generate_tls_keypair_files(
                Some(bin_path.as_str()),
                sni,
                Path::new(&cert_path),
                Path::new(&key_path),
            )
            .await
            {
                Ok(()) => {
                    self.state.live.write().await.push_event(
                        "info",
                        "core_mgr",
                        &format!(
                            "Generated TLS certificate pair for server '{}' ({})",
                            srv.id, cert_path
                        ),
                    );
                }
                Err(e) => {
                    eprintln!(
                        "[tachyon] ensure_server_tls_certs failed for '{}': {e:#}",
                        srv.id
                    );
                    self.state.live.write().await.push_event(
                        "warn",
                        "core_mgr",
                        &format!(
                            "Failed to generate TLS certificate pair for server '{}' ({cert_path}): {e:#}",
                            srv.id
                        ),
                    );
                }
            }
        }
    }

    /// Compile `/etc/tachyon-core/config.json`, apply network stack, and start `/usr/bin/tachyon-core`.
    pub async fn start(&self) -> anyhow::Result<()> {
        self.start_boxed().await
    }

    #[inline(never)]
    fn start_boxed(
        &self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
        Box::pin(self.start_inner())
    }

    async fn start_inner(&self) -> anyhow::Result<()> {
        self.set_manual_stop(false);
        let guard = self.reload_lock.lock().await;
        let store_snapshot = Box::new(self.state.data.read().await.clone());
        let veto = Box::pin(net_stack::hold_kill_switch(&store_snapshot)).await;
        Box::pin(self.stop_locked()).await;

        let cleanup_failed_start = |veto_active: bool, msg: String| {
            let state = Arc::clone(&self.state);
            Box::pin(async move {
                net_stack::teardown_network_stack_with_mode(veto_active).await;
                let mut live = state.live.write().await;
                live.core_running = false;
                live.core_pid = None;
                live.core_identity = None;
                live.nft_table_active = false;
                live.push_event("error", "core_mgr", &msg);
            })
        };

        let startup_wan6 = crate::store::probe_wan6_runtime_state();
        let startup_ipv6_state = crate::store::resolve_effective_ipv6_state(
            &store_snapshot.settings,
            startup_wan6.wan6_available,
        );
        Self::ensure_runtime_cache_dir(&store_snapshot.settings.cache_path);
        Box::pin(self.ensure_server_tls_certs(&store_snapshot)).await;
        let (cfg_val, seed_errors) =
            Box::pin(self.compile_or_safe_minimal_with_wan6(
                &store_snapshot,
                Some(startup_wan6.wan6_available),
            ))
            .await;
        let (cfg_path, prepared_cfg, mut quarantined) = match Box::pin(
            self.prepare_and_write_validated_core_config(&store_snapshot, cfg_val, seed_errors),
        )
        .await
        {
            Ok(v) => v,
            Err(e) => {
                cleanup_failed_start(veto.is_some(), format!("config validation failed: {e:#}"))
                    .await;
                return Err(e);
            }
        };
        let mut reload_guard_opt = Some(guard);
        let mut safe_minimal_active = quarantined.contains_key("_core_runtime");
        if safe_minimal_active
            && self.state.live.read().await.lkg_observing
            && !self.auto_rollback_in_flight.load(Ordering::Acquire)
        {
            drop(reload_guard_opt.take());
            match Box::pin(self.auto_rollback_to_working_config(
                "Конфиг приведён к минимальному режиму при старте; выполнен автооткат на рабочий конфиг",
                None,
            ))
            .await
            {
                Ok(true) => return Ok(()),
                Ok(false) => {
                    self.state.live.write().await.push_event(
                        "warn",
                        "core_mgr",
                        "Конфиг приведён к минимальному режиму при старте, автооткат не применился; продолжается запуск в безопасном режиме",
                    );
                }
                Err(rb_err) => {
                    self.state.live.write().await.push_event(
                        "warn",
                        "core_mgr",
                        &format!(
                            "Ошибка автоотката из безопасного режима ({rb_err:#}); продолжается запуск в безопасном режиме"
                        ),
                    );
                }
            }
            reload_guard_opt = Some(self.reload_lock.lock().await);
        }
        Self::invalidate_clash_cred_cache();

        let bin_path = self.resolve_bin_path().await;
        if !Path::new(&bin_path).exists() {
            let err = anyhow::anyhow!("tachyon-core binary not found at '{bin_path}'");
            cleanup_failed_start(veto.is_some(), err.to_string()).await;
            return Err(err);
        }

        let core_log_dir = if cfg!(target_os = "linux") {
            PathBuf::from("/tmp/tachyon-core")
        } else {
            self.state
                .path
                .parent()
                .unwrap_or_else(|| Path::new("data"))
                .join("logs")
        };
        let core_log_path = Self::rotate_core_log_on_start(&core_log_dir);
        let mem_limit = store_snapshot.settings.memory_limit_mb;
        let mut child = match Box::pin(Self::spawn_and_verify_core(&bin_path, &cfg_path, mem_limit))
            .await
        {
            Ok(c) => c,
            Err(first_err) if !quarantined.contains_key("_core_runtime") => {
                safe_minimal_active = true;
                let (key, label) = Self::attribute_error_to_store_entity(
                    &first_err,
                    &prepared_cfg,
                    &store_snapshot,
                );
                let pretty = Self::format_fault_reason(&first_err);
                quarantined.entry(key).or_insert_with(|| {
                    format!("{label}: сбой запуска ({pretty}). Включён безопасный режим.")
                });
                quarantined
                    .entry("_core_runtime".to_string())
                    .or_insert_with(|| {
                        format!(
                            "Ядро завершилось при запуске ({pretty}). Выполнен перезапуск в безопасном минимальном режиме (DNS + direct)."
                        )
                    });
                Self::write_section_errors(&quarantined);
                if self.state.live.read().await.lkg_observing
                    && !self.auto_rollback_in_flight.load(Ordering::Acquire)
                {
                    drop(reload_guard_opt.take());
                    match Box::pin(self.auto_rollback_to_working_config(
                        &format!("Ранний сбой запуска tachyon-core ({pretty}); выполнен автооткат"),
                        None,
                    ))
                    .await
                    {
                        Ok(true) => return Ok(()),
                        Ok(false) => {
                            self.state.live.write().await.push_event(
                                "warn",
                                "core_mgr",
                                &format!(
                                    "Ранний сбой запуска tachyon-core ({pretty}); автооткат не применился, запуск в безопасном минимальном режиме"
                                ),
                            );
                        }
                        Err(rb_err) => {
                            self.state.live.write().await.push_event(
                                "warn",
                                "core_mgr",
                                &format!(
                                    "Ранний сбой запуска tachyon-core ({pretty}); ошибка автоотката ({rb_err:#}), запуск в безопасном минимальном режиме"
                                ),
                            );
                        }
                    }
                    reload_guard_opt = Some(self.reload_lock.lock().await);
                }
                self.state.live.write().await.push_event(
                    "warn",
                    "core_mgr",
                    &format!(
                        "Ранний сбой запуска tachyon-core ({pretty}); повторный запуск в безопасном минимальном режиме"
                    ),
                );
                let safe_cfg = config_gen::compile_safe_minimal_core_config_with_wan6(
                    &store_snapshot,
                    startup_wan6.wan6_available,
                );
                if let Err(e) = crypto_gen::write_json_if_changed(&cfg_path, &safe_cfg) {
                    cleanup_failed_start(
                        veto.is_some(),
                        format!("failed to write safe fallback config: {e:#}"),
                    )
                    .await;
                    return Err(e);
                }
                match Box::pin(Self::spawn_and_verify_core(&bin_path, &cfg_path, mem_limit)).await {
                    Ok(c) => c,
                    Err(second_err) => {
                        cleanup_failed_start(veto.is_some(), second_err.clone()).await;
                        anyhow::bail!("{second_err}");
                    }
                }
            }
            Err(msg) => {
                cleanup_failed_start(veto.is_some(), msg.clone()).await;
                anyhow::bail!("{msg}");
            }
        };
        let _keep_reload_guard = reload_guard_opt;
        let pid = child.id().unwrap_or(0);
        let identity = sys_info::capture_process_identity(pid);

        if let Some(stdout) = child.stdout.take() {
            let st = Arc::clone(&self.state);
            tokio::spawn(Self::drain_core_log_stream_to_file(
                stdout,
                st,
                Some(core_log_path.clone()),
            ));
        }
        if let Some(stderr) = child.stderr.take() {
            let st = Arc::clone(&self.state);
            tokio::spawn(Self::drain_core_log_stream_to_file(
                stderr,
                st,
                Some(core_log_path),
            ));
        }

        *self.proc.lock().await = Some((child, Instant::now()));
        let net_res = if safe_minimal_active {
            Box::pin(net_stack::apply_network_stack_safe_minimal(&store_snapshot)).await
        } else {
            Box::pin(net_stack::apply_network_stack(&store_snapshot)).await
        };
        let post_net_wan6 = crate::store::probe_wan6_runtime_state();
        let applied_net_fp = if net_res.is_ok() {
            let fp = Self::compute_net_stack_fingerprint(
                &store_snapshot,
                safe_minimal_active,
                post_net_wan6.wan6_available,
            );
            *self.last_net_stack_fingerprint.lock().await = Some(fp.clone());
            Some(fp)
        } else {
            *self.last_net_stack_fingerprint.lock().await = None;
            None
        };
        let _ = Box::pin(self.refresh_core_version()).await;
        let nft_ok = net_stack::check_nft_table_active().await;

        {
            let mut live = self.state.live.write().await;
            live.core_running = true;
            live.core_pid = Some(pid);
            live.core_identity = identity;
            live.nft_table_active = nft_ok;
            live.safe_minimal_active = safe_minimal_active;
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
        Box::pin(self.restore_saved_selectors(&store_snapshot)).await;
        self.record_watchdog_applied_config(
            &store_snapshot,
            &prepared_cfg,
            &quarantined,
            startup_wan6.wan6_available,
        )
        .await;
        let post_ipv6_state = crate::store::resolve_effective_ipv6_state(
            &store_snapshot.settings,
            post_net_wan6.wan6_available,
        );
        let cfg_ipv6_matches =
            Self::core_config_ipv6_matches(&cfg_path, &store_snapshot, post_ipv6_state);
        if Self::should_resync_startup_ipv6(startup_ipv6_state, post_ipv6_state, cfg_ipv6_matches)
            && !self.is_manually_stopped()
        {
            self.state.live.write().await.push_event(
                "info",
                "core_mgr",
                &format!(
                    "IPv6 effective state changed during startup ({} -> {}); resynchronizing runtime",
                    startup_ipv6_state.as_str(),
                    post_ipv6_state.as_str(),
                ),
            );
            let (re_cfg_val, re_seed_errors) = Box::pin(self.compile_or_safe_minimal_with_wan6(
                &store_snapshot,
                Some(post_net_wan6.wan6_available),
            ))
            .await;
            if let Ok((re_cfg_path, re_prepared_cfg, re_quarantined)) =
                Box::pin(self.prepare_and_write_validated_core_config(
                    &store_snapshot,
                    re_cfg_val,
                    re_seed_errors,
                ))
                .await
            {
                let re_safe_minimal = re_quarantined.contains_key("_core_runtime");
                self.state.live.write().await.safe_minimal_active = re_safe_minimal;
                let desired_fp = Self::compute_net_stack_fingerprint(
                    &store_snapshot,
                    re_safe_minimal,
                    post_net_wan6.wan6_available,
                );
                if applied_net_fp.as_deref() != Some(desired_fp.as_str()) {
                    let re_net_res = if re_safe_minimal {
                        Box::pin(net_stack::apply_network_stack_safe_minimal(&store_snapshot)).await
                    } else {
                        Box::pin(net_stack::apply_network_stack(&store_snapshot)).await
                    };
                    if re_net_res.is_ok() {
                        *self.last_net_stack_fingerprint.lock().await = Some(desired_fp);
                    }
                }
                let payload = json!({ "path": re_cfg_path, "payload": "" }).to_string();
                if Box::pin(self.clash_request("PUT", "/configs?force=true", Some(&payload)))
                    .await
                    .is_ok()
                {
                    Box::pin(self.restore_saved_selectors(&store_snapshot)).await;
                    self.record_watchdog_applied_config(
                        &store_snapshot,
                        &re_prepared_cfg,
                        &re_quarantined,
                        post_net_wan6.wan6_available,
                    )
                    .await;
                }
            }
        }
        Ok(())
    }

    pub(crate) fn should_resync_startup_ipv6(
        startup_ipv6_state: crate::store::EffectiveIpv6State,
        post_ipv6_state: crate::store::EffectiveIpv6State,
        cfg_matches: bool,
    ) -> bool {
        post_ipv6_state != startup_ipv6_state && !cfg_matches
    }

    fn compute_net_stack_fingerprint(
        store: &crate::store::RouterStoreData,
        safe_minimal_active: bool,
        wan6_available: bool,
    ) -> String {
        let mut hasher = Sha256::new();
        hasher.update(store.settings.proxy_mode.as_bytes());
        hasher.update([u8::from(safe_minimal_active), u8::from(wan6_available)]);
        hasher.update([
            u8::from(store.settings.tcp_bbr),
            u8::from(store.settings.smart_queue),
            u8::from(store.settings.dont_touch_dhcp),
            u8::from(store.settings.enable_yacd),
        ]);
        hasher.update(store.settings.tcp_profile.as_bytes());
        hasher.update(store.settings.sqm_interface.as_bytes());
        hasher.update(store.settings.sqm_upload_kbps.to_le_bytes());
        hasher.update(store.settings.sqm_download_kbps.to_le_bytes());
        let ruleset = net_stack::compile_nftables_ruleset_with_wan6(store, wan6_available, &[]);
        hasher.update(ruleset.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    async fn record_watchdog_applied_config(
        &self,
        store_snapshot: &crate::store::RouterStoreData,
        prepared_cfg: &Value,
        quarantined: &BTreeMap<String, String>,
        wan6_available: bool,
    ) {
        if quarantined.contains_key("_core_runtime") {
            return;
        }
        let mut digest = if quarantined.is_empty() {
            crate::watchdog::compute_config_digest(prepared_cfg)
        } else {
            crate::watchdog::compute_desired_digest(store_snapshot)
        };
        if digest.is_empty() {
            digest = crate::watchdog::compute_config_digest(prepared_cfg);
        }
        if !digest.is_empty() {
            let store_gen = self.state.store_generation();
            {
                let mut wd = self.watchdog.lock().await;
                wd.record_applied_config(digest.clone());
                wd.cached_store_generation = store_gen;
                wd.cached_wan6_available = wan6_available;
                wd.cached_desired_digest = digest.clone();
            }
            let mut live = self.state.live.write().await;
            live.desired_config_digest = digest;
            live.config_drift = false;
        }
    }

    fn service_autostart_enabled_for(
        platform: crate::platform::PlatformKind,
        init_script: &Path,
        rc_d_dir: &Path,
    ) -> bool {
        if platform.is_entware() {
            let Ok(meta) = std::fs::metadata(init_script) else {
                return false;
            };
            if !meta.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                meta.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                true
            }
        } else {
            std::fs::read_dir(rc_d_dir).ok().is_some_and(|rd| {
                rd.flatten().any(|e| {
                    let name = e.file_name();
                    let s = name.to_string_lossy();
                    s.starts_with('S') && s.ends_with("tachyon") && !s.ends_with("tachyon-core")
                })
            })
        }
    }

    fn service_autostart_enabled() -> bool {
        if cfg!(not(target_os = "linux")) {
            return false;
        }
        Self::service_autostart_enabled_for(
            crate::platform::detect_platform(),
            &crate::platform::paths().init_script,
            Path::new("/etc/rc.d"),
        )
    }

    #[cfg(target_os = "linux")]
    fn is_pid_running_non_zombie(pid: u32) -> bool {
        let status_path = format!("/proc/{pid}/status");
        let Ok(status) = std::fs::read_to_string(&status_path) else {
            return false;
        };
        !status.lines().any(|line| {
            line.strip_prefix("State:")
                .map(str::trim_start)
                .is_some_and(|st| st.starts_with('Z') || st.starts_with('X'))
        })
    }

    #[cfg(target_os = "linux")]
    fn verify_external_tachyon_core_pid(
        pid: u32,
        expected_identity: Option<&sys_info::ProcessIdentity>,
    ) -> bool {
        if !Self::is_pid_running_non_zombie(pid) {
            return false;
        }
        if let Some(id) = expected_identity
            && id.pid == pid
        {
            return sys_info::verify_process_identity(id);
        }
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .ok()
            .is_some_and(|comm| comm.trim() == "tachyon-core")
    }

    pub async fn stop(&self) -> anyhow::Result<()> {
        self.stop_inner(true).await
    }

    pub async fn stop_for_shutdown(&self) -> anyhow::Result<()> {
        self.stop_inner(false).await
    }

    async fn stop_inner(&self, mark_manual_stop: bool) -> anyhow::Result<()> {
        if mark_manual_stop {
            self.set_manual_stop(true);
        }
        let _guard = self.reload_lock.lock().await;
        let store_snapshot = { self.state.data.read().await.clone() };
        let keep_fail_closed = if !Self::service_autostart_enabled() {
            net_stack::remove_kill_switch().await;
            false
        } else if mark_manual_stop || net_stack::direct_fallback_veto(&store_snapshot).is_some() {
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
        live.safe_minimal_active = false;
        Ok(())
    }

    pub async fn force_kill_spawned_child_fast(&self) {
        if let Ok(mut guard) =
            tokio::time::timeout(Duration::from_millis(120), self.proc.lock()).await
            && let Some((mut child, _)) = guard.take()
        {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(Duration::from_millis(200), child.wait()).await;
        }
    }

    async fn stop_locked(&self) {
        if let Some((mut child, _)) = self.proc.lock().await.take() {
            #[cfg(unix)]
            if let Some(child_pid) = child.id() {
                let _ = tokio::time::timeout(
                    Duration::from_secs(1),
                    Command::new("kill")
                        .args(["-TERM", &child_pid.to_string()])
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .kill_on_drop(true)
                        .status(),
                )
                .await;
                if !matches!(
                    tokio::time::timeout(Duration::from_millis(700), child.wait()).await,
                    Ok(Ok(_))
                ) {
                    let _ = child.kill().await;
                    let _ = tokio::time::timeout(Duration::from_millis(600), child.wait()).await;
                }
            } else {
                let _ = child.kill().await;
                let _ = tokio::time::timeout(Duration::from_millis(600), child.wait()).await;
            }
            #[cfg(not(unix))]
            {
                let _ = child.kill().await;
                let _ = tokio::time::timeout(Duration::from_millis(600), child.wait()).await;
            }
        }
        #[cfg(target_os = "linux")]
        {
            // Also terminate any externally started or orphaned `tachyon-core` process
            // (e.g., adopted on daemon startup or stale pre-upgrade `(deleted)` binary)
            // so the new binary/config can bind `:1602`, `:53`, and `:9090` cleanly.
            let mut killed_pids = std::collections::HashSet::new();
            for _ in 0..4 {
                let target_pid = {
                    let live = self.state.live.read().await;
                    live.core_pid
                        .filter(|p| {
                            !killed_pids.contains(p)
                                && Self::verify_external_tachyon_core_pid(
                                    *p,
                                    live.core_identity.as_ref(),
                                )
                        })
                        .or_else(|| {
                            sys_info::find_running_process_by_name("tachyon-core")
                                .map(|(p, _)| p)
                                .filter(|p| {
                                    !killed_pids.contains(p) && Self::is_pid_running_non_zombie(*p)
                                })
                        })
                };
                let Some(ext_pid) = target_pid else {
                    break;
                };
                killed_pids.insert(ext_pid);
                let _ = tokio::time::timeout(
                    Duration::from_secs(1),
                    Command::new("kill")
                        .args(["-TERM", &ext_pid.to_string()])
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .kill_on_drop(true)
                        .status(),
                )
                .await;
                let mut exited = false;
                for _ in 0..7 {
                    if !Self::is_pid_running_non_zombie(ext_pid) {
                        exited = true;
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                if !exited {
                    let _ = tokio::time::timeout(
                        Duration::from_secs(1),
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
        *self.last_net_stack_fingerprint.lock().await = None;
        Self::invalidate_clash_cred_cache();
        let mut live = self.state.live.write().await;
        live.core_running = false;
        live.core_pid = None;
        live.core_identity = None;
        live.safe_minimal_active = false;
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

    #[inline(never)]
    fn apply_or_reload_inner_boxed(
        &self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
        Box::pin(self.apply_or_reload_inner())
    }

    async fn apply_or_reload_inner(&self) -> anyhow::Result<()> {
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
            return self.start_boxed().await;
        }
        let store_snapshot = Box::new(self.state.data.read().await.clone());
        let reload_wan6 = crate::store::probe_wan6_runtime_state();
        Box::pin(self.ensure_server_tls_certs(&store_snapshot)).await;
        let (cfg_val, seed_errors) =
            Box::pin(self.compile_or_safe_minimal_with_wan6(
                &store_snapshot,
                Some(reload_wan6.wan6_available),
            ))
            .await;
        let (cfg_path_buf, prepared_cfg, quarantined) = Box::pin(
            self.prepare_and_write_validated_core_config(&store_snapshot, cfg_val, seed_errors),
        )
        .await?;
        let safe_minimal_active = quarantined.contains_key("_core_runtime");
        if safe_minimal_active
            && self.state.live.read().await.lkg_observing
            && !self.auto_rollback_in_flight.load(Ordering::Acquire)
        {
            anyhow::bail!("config downgraded to safe_minimal during reload");
        }
        Self::invalidate_clash_cred_cache();
        self.state.live.write().await.safe_minimal_active = safe_minimal_active;
        let cfg_path = cfg_path_buf.to_string_lossy().to_string();
        let desired_net_fp = Self::compute_net_stack_fingerprint(
            &store_snapshot,
            safe_minimal_active,
            reload_wan6.wan6_available,
        );
        let prev_net_fp = { self.last_net_stack_fingerprint.lock().await.clone() };
        let nft_already_ok = if prev_net_fp.as_deref() == Some(desired_net_fp.as_str()) {
            store_snapshot.settings.proxy_mode == "socks"
                || net_stack::check_nft_table_active().await
        } else {
            false
        };
        if !nft_already_ok {
            let net_res = if safe_minimal_active {
                Box::pin(net_stack::apply_network_stack_safe_minimal(&store_snapshot)).await
            } else {
                Box::pin(net_stack::apply_network_stack(&store_snapshot)).await
            };
            if let Err(e) = net_res {
                *self.last_net_stack_fingerprint.lock().await = None;
                eprintln!("[tachyon] apply_network_stack failed during reload: {e:#}");
                self.state.live.write().await.push_event(
                    "error",
                    "net_stack",
                    &format!("apply_network_stack failed: {e:#}"),
                );
            } else {
                *self.last_net_stack_fingerprint.lock().await = Some(desired_net_fp);
                self.state.live.write().await.nft_table_active =
                    net_stack::check_nft_table_active().await;
            }
        } else {
            self.state.live.write().await.nft_table_active = true;
        }
        let body = json!({ "path": cfg_path }).to_string();
        if Box::pin(self.clash_request("PUT", "/configs?force=true", Some(&body)))
            .await
            .is_err()
        {
            // Release reload_lock before falling back to start() to avoid self-deadlock.
            drop(reload_guard);
            return self.start_boxed().await;
        }
        Box::pin(self.restore_saved_selectors(&store_snapshot)).await;
        self.record_watchdog_applied_config(
            &store_snapshot,
            &prepared_cfg,
            &quarantined,
            reload_wan6.wan6_available,
        )
        .await;
        drop(reload_guard);
        Ok(())
    }

    /// Hot-reload `tachyon-core` via `PUT /configs` on Clash API, or restart if not running.
    /// Automatically rolls back to the last working config if validation/startup fails during an observation window.
    pub async fn apply_or_reload(&self) -> anyhow::Result<()> {
        let was_running = { self.state.live.read().await.core_running };
        let res = self.apply_or_reload_inner_boxed().await;
        if let Err(ref err) = res {
            let err_text = err.to_string();
            let missing_binary = err_text.contains("tachyon-core binary not found");
            let config_rejected = err_text.contains("tachyon-core check failed")
                || err_text.contains("tachyon-core check timed out")
                || err_text.contains("config compile failed")
                || err_text.contains("safe_minimal");
            let observing = { self.state.live.read().await.lkg_observing };
            if observing
                && !self.is_manually_stopped()
                && !missing_binary
                && (config_rejected || was_running)
            {
                let reason = format!("Ошибка применения конфига: {err}");
                if let Ok(true) =
                    Box::pin(self.auto_rollback_to_working_config(&reason, None)).await
                {
                    return Err(anyhow::anyhow!(
                        "Конфиг отклонён ядром ({err}); выполнен автоматический откат на последний рабочий конфиг"
                    ));
                }
            }
        }
        res
    }

    /// Automatically revert to the newest working revision (or LKG / previous revision snapshot)
    /// and mark the failing revision as `"failed"`.
    #[inline(never)]
    pub async fn auto_rollback_to_working_config(
        &self,
        reason: &str,
        hist_dir: Option<PathBuf>,
    ) -> anyhow::Result<bool> {
        struct AutoRollbackGuard<'a>(&'a AtomicBool);
        impl Drop for AutoRollbackGuard<'_> {
            fn drop(&mut self) {
                self.0.store(false, Ordering::SeqCst);
            }
        }

        if self.auto_rollback_in_flight.swap(true, Ordering::SeqCst) {
            anyhow::bail!("Автооткат уже выполняется");
        }
        let _guard = AutoRollbackGuard(&self.auto_rollback_in_flight);

        let failed_rev_id = { self.state.live.read().await.active_revision_id.clone() };
        let failed_opt = if failed_rev_id.trim().is_empty() {
            None
        } else {
            Some(failed_rev_id.as_str())
        };
        let dir_buf = hist_dir
            .clone()
            .unwrap_or_else(crate::config_history::history_dir);

        let _ =
            crate::config_history::mark_revision_status_in(&dir_buf, failed_opt, "failed", reason);

        let candidate_opt: Option<Box<crate::store::RouterStoreData>> = {
            let cur_guard = self.state.data.read().await;
            if let Some((_, store)) =
                crate::config_history::load_last_working_store_in(&dir_buf, Some(&cur_guard))
            {
                Some(store)
            } else if let Ok(mut lkg) = transaction::load_known_good_boxed(&self.state.lkg_path) {
                crate::config_history::preserve_live_cached_nodes(&mut lkg, Some(&cur_guard));
                Some(lkg)
            } else if !failed_rev_id.trim().is_empty() {
                crate::config_history::load_revision_store_in(
                    &dir_buf,
                    &failed_rev_id,
                    "before",
                    Some(&cur_guard),
                )
                .ok()
            } else {
                None
            }
        };

        let Some(working_store) = candidate_opt else {
            anyhow::bail!("Рабочий конфиг для автоматического отката не найден");
        };

        transaction::commit_transaction_boxed_in_history_dir(
            &self.state,
            working_store,
            "auto_rollback",
            hist_dir,
        )
        .await?;

        {
            let committed = self.state.data.read().await;
            crate::ubus_bridge::sync_from_store_to_json_and_cache(&committed);
        }

        let rb_rev_id = {
            let mut live = self.state.live.write().await;
            live.lkg_observing = false;
            live.lkg_remaining_secs = 0;
            live.last_auto_rollback_reason = reason.to_string();
            live.last_auto_rollback_ts = unix_now_secs();
            live.push_event(
                "warn",
                "auto_rollback",
                &format!("Выполнен автооткат на последний рабочий конфиг: {reason}"),
            );
            live.active_revision_id.clone()
        };

        if !self.is_manually_stopped() {
            Box::pin(self.apply_or_reload_inner()).await?;
        }

        if !rb_rev_id.trim().is_empty() && rb_rev_id != failed_rev_id {
            let _ = crate::config_history::mark_revision_status_in(
                &dir_buf,
                Some(rb_rev_id.as_str()),
                "working",
                "Восстановлен последний рабочий конфиг",
            );
        }

        Ok(true)
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
        let legacy_sel = crate::platform::paths()
            .data_dir
            .join("selector_state.json");
        let mut sel_map: HashMap<String, String> = std::fs::read_to_string(&sel_path)
            .or_else(|_| std::fs::read_to_string(&legacy_sel))
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
        let mut proxies_resp = None;
        let retry_started = Instant::now();
        for attempt in 0..4u8 {
            if let Ok(v) = self.clash_request("GET", "/proxies", None).await {
                proxies_resp = Some(v);
                break;
            }
            if attempt >= 3 || retry_started.elapsed() >= Duration::from_millis(500) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(120)).await;
        }
        let Some(ref body) = proxies_resp else {
            return;
        };
        let mut pruned_dirty = false;
        let mut validated = Vec::with_capacity(sel_map.len());
        let mut synced_updates = Vec::new();
        for (group, tag) in &sel_map {
            let mut chosen = tag.clone();
            let Some(group_obj) = body
                .get("proxies")
                .and_then(Value::as_object)
                .and_then(|m| m.get(group))
            else {
                continue;
            };
            if !group_obj
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|t| t.eq_ignore_ascii_case("selector"))
            {
                continue;
            }
            if let Some(all_arr) = group_obj.get("all").and_then(Value::as_array) {
                let in_pool = all_arr
                    .iter()
                    .filter_map(Value::as_str)
                    .any(|cand| cand == chosen);
                if !in_pool {
                    let wanted_canon = config_gen::strip_dynamic_server_telemetry(&chosen);
                    let telemetry_match = (!wanted_canon.is_empty())
                        .then(|| {
                            all_arr.iter().filter_map(Value::as_str).find(|cand| {
                                config_gen::strip_dynamic_server_telemetry(cand)
                                    .eq_ignore_ascii_case(&wanted_canon)
                            })
                        })
                        .flatten()
                        .or_else(|| {
                            all_arr.iter().filter_map(Value::as_str).find(|cand| {
                                config_gen::server_filter_name_matches(cand, &chosen, &[])
                            })
                        });
                    if let Some(matched) = telemetry_match {
                        chosen = matched.to_string();
                        pruned_dirty = true;
                    } else {
                        let default_cand =
                            group_obj
                                .get("default")
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
            }
            if group_obj.get("now").and_then(Value::as_str) == Some(chosen.as_str()) {
                if chosen != *tag {
                    synced_updates.push((group.clone(), chosen));
                }
                continue;
            }
            validated.push((group.clone(), chosen));
        }
        for (group, tag) in synced_updates {
            sel_map.insert(group, tag);
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
        let legacy_sel = crate::platform::paths()
            .data_dir
            .join("selector_state.json");
        let mut map: HashMap<String, String> = std::fs::read_to_string(&path)
            .or_else(|_| std::fs::read_to_string(&legacy_sel))
            .or_else(|_| std::fs::read_to_string("/etc/tachyon/selector_state.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        map.insert(group_or_sec.to_string(), chosen_tag.to_string());
        if let Some(base) = group_or_sec.strip_prefix("sel-") {
            map.remove(base);
            map.remove(&format!("{base}-out"));
        }
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
                    let formatted_ip = if ip.contains(':') && !ip.starts_with('[') {
                        format!("[{ip}]")
                    } else {
                        ip
                    };
                    return Some(format!("{host}:{port}:{formatted_ip}"));
                }
            }
        }
        None
    }

    /// Fetch URL via `curl` with optional HTTP/SOCKS proxy, bootstrap non-FakeIP `--resolve`,
    /// and multi-resolver DoH fallback (`1.1.1.1`, `8.8.8.8`, `dns.google`, `common.dot.dns.yandex.net`).
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

    pub(crate) const SUBSCRIPTION_AUTO_USER_AGENTS: &[&str] = &[
        "tachyon-core/2.0 (compatible; sing-box 1.14.3)",
        "Happ/4.6.2",
        "Happ",
        "v2rayNG/1.8.29",
        "v2rayNG/2.3.15",
        "v2rayN/7.12",
        "Clash.Meta/v1.19.10",
        "Mihomo/1.19.16",
        "FlClash/v0.8.72",
        "HiddifyNext/2.5.7",
        "sing-box 1.14.3",
        "tachyon-core/2.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    ];

    pub(crate) fn is_happ_versioned_user_agent(ua: &str) -> bool {
        ua.trim().to_ascii_lowercase().starts_with("happ/")
    }

    pub(crate) fn normalize_subscription_user_agent(raw: &str) -> String {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("auto") {
            return String::new();
        }
        match trimmed.to_ascii_lowercase().as_str() {
            "tachyon-core" | "tachyon" | "sing-box" | "singbox" => "tachyon-core/2.0".to_string(),
            "happ" => "Happ/4.6.2".to_string(),
            "v2rayng" => "v2rayNG/2.3.15".to_string(),
            "v2rayn" => "v2rayN/7.12".to_string(),
            "mihomo" | "clash" | "clash-meta" | "clash.meta" => "Mihomo/1.19.16".to_string(),
            "flclash" => "FlClash/v0.8.72".to_string(),
            "hiddify" | "hiddifynext" => "HiddifyNext/2.5.7".to_string(),
            _ => trimmed.to_string(),
        }
    }

    pub(crate) fn compute_deterministic_router_hwid() -> String {
        static HWID_CACHE: OnceLock<String> = OnceLock::new();
        HWID_CACHE
            .get_or_init(|| {
                let seed = [
                    "/etc/machine-id",
                    "/sys/class/net/br-lan/address",
                    "/sys/class/net/eth0/address",
                    "/proc/sys/kernel/hostname",
                ]
                .iter()
                .find_map(|p| {
                    std::fs::read_to_string(p)
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                })
                .unwrap_or_else(|| "tachyon-router-default".to_string());
                let mut hasher = Sha256::new();
                hasher.update(b"tachyon-hwid-v1:");
                hasher.update(seed.as_bytes());
                let digest = hasher.finalize();
                let mut hex = String::with_capacity(24);
                for b in &digest[..12] {
                    hex.push_str(&format!("{b:02x}"));
                }
                hex
            })
            .clone()
    }

    pub(crate) fn build_subscription_request_headers(
        src: &crate::store::OutboundSource,
    ) -> Vec<(String, String)> {
        Self::build_subscription_request_headers_inner(src, true)
    }

    pub(crate) fn build_subscription_request_headers_inner(
        src: &crate::store::OutboundSource,
        include_hwid: bool,
    ) -> Vec<(String, String)> {
        let mut headers = Vec::with_capacity(7);
        let accept_lang = if src.accept_language.trim().is_empty() {
            "ru-RU,ru;q=0.9,en-US;q=0.8"
        } else {
            src.accept_language.trim()
        };
        headers.push(("Accept-Language".to_string(), accept_lang.to_string()));

        if !include_hwid {
            return headers;
        }

        let explicit_hwid = src.hwid.trim();
        let hwid = if !explicit_hwid.is_empty() {
            Some(explicit_hwid.to_string())
        } else if src.auto_hwid {
            Some(Self::compute_deterministic_router_hwid())
        } else {
            None
        };
        if let Some(id) = hwid {
            headers.push(("x-hwid".to_string(), id));
        }

        if src.custom_device_headers || src.auto_hwid {
            let sys = crate::sys_info::collect_host_info();
            let dev_os = if src.custom_device_headers && !src.device_os.trim().is_empty() {
                src.device_os.trim().to_string()
            } else {
                "OpenWrt".to_string()
            };
            let ver_os = if src.custom_device_headers && !src.ver_os.trim().is_empty() {
                src.ver_os.trim().to_string()
            } else if !sys.openwrt_release.trim().is_empty() {
                sys.openwrt_release.trim().to_string()
            } else {
                "24.10".to_string()
            };
            let model = if src.custom_device_headers && !src.device_model.trim().is_empty() {
                src.device_model.trim().to_string()
            } else if !sys.router_model.trim().is_empty() {
                sys.router_model.trim().to_string()
            } else {
                "Router".to_string()
            };
            headers.push(("x-device-os".to_string(), dev_os));
            headers.push(("x-ver-os".to_string(), ver_os));
            headers.push(("x-device-model".to_string(), model));
            if src.custom_device_headers && !src.device_locale.trim().is_empty() {
                headers.push((
                    "x-device-locale".to_string(),
                    src.device_locale.trim().to_string(),
                ));
            }
            if src.custom_device_headers && !src.app_version.trim().is_empty() {
                headers.push((
                    "x-app-version".to_string(),
                    src.app_version.trim().to_string(),
                ));
            }
        }
        headers
    }

    pub async fn curl_fetch_with_options(
        &self,
        url: &str,
        include_headers: bool,
        timeout_secs: u64,
        proxy_url: Option<&str>,
        user_agent: Option<&str>,
    ) -> anyhow::Result<Vec<u8>> {
        self.curl_fetch_with_headers(
            url,
            include_headers,
            timeout_secs,
            proxy_url,
            user_agent,
            &[],
        )
        .await
    }

    pub async fn curl_fetch_with_headers(
        &self,
        url: &str,
        include_headers: bool,
        timeout_secs: u64,
        proxy_url: Option<&str>,
        user_agent: Option<&str>,
        extra_headers: &[(String, String)],
    ) -> anyhow::Result<Vec<u8>> {
        let detailed = self
            .curl_fetch_detailed(
                url,
                include_headers,
                timeout_secs,
                proxy_url,
                None,
                user_agent,
                extra_headers,
                false,
            )
            .await
            .map_err(|e| anyhow::anyhow!("{}", e.message))?;
        if detailed.status_code >= 400 {
            anyhow::bail!(
                "curl HTTP error (status 22, HTTP {}) for {url}",
                detailed.status_code
            );
        }
        Ok(detailed.raw)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn curl_fetch_detailed(
        &self,
        url: &str,
        include_headers: bool,
        timeout_secs: u64,
        proxy_url: Option<&str>,
        fallback_proxy_url: Option<&str>,
        user_agent: Option<&str>,
        extra_headers: &[(String, String)],
        insecure: bool,
    ) -> Result<CurlFetchResult, CurlFetchError> {
        let max_t = timeout_secs.max(4).to_string();
        let ua = user_agent
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("tachyon-core/2.0");
        let build_base_args = |inc_hdr: bool, use_compressed: bool| -> Vec<String> {
            let mut a = Vec::with_capacity(18 + extra_headers.len() * 2);
            if inc_hdr {
                a.push("-i".to_string());
            }
            a.extend([
                "-sSL".to_string(),
                "--max-filesize".to_string(),
                "16777216".to_string(),
                "--connect-timeout".to_string(),
                "8".to_string(),
                "--max-time".to_string(),
                max_t.clone(),
                "-A".to_string(),
                ua.to_string(),
            ]);
            if use_compressed {
                a.push("--compressed".to_string());
            }
            if insecure {
                a.push("-k".to_string());
            }
            for (k, v) in extra_headers {
                a.push("-H".to_string());
                a.push(format!("{k}: {v}"));
            }
            a
        };

        let mut last_http_err: Option<(u16, Vec<u8>)> = None;
        let mut last_exit_code: Option<i32> = None;
        let cmd_timeout = Duration::from_secs(timeout_secs.max(4).saturating_add(4));

        let run_curl_with_compressed_fallback =
            |args_comp: Vec<String>, args_plain: Vec<String>| async move {
                let out = Self::run_curl_args(&args_comp, cmd_timeout).await;
                if let Ok(ref res) = out
                    && res.status.code() == Some(2)
                {
                    return Self::run_curl_args(&args_plain, cmd_timeout).await;
                }
                out
            };

        let evaluate_curl_out = |stdout: Vec<u8>,
                                 status: std::process::ExitStatus,
                                 last_http_err: &mut Option<(u16, Vec<u8>)>,
                                 last_exit_code: &mut Option<i32>|
         -> Option<CurlFetchResult> {
            if let Some(code) = status.code()
                && code != 0
            {
                *last_exit_code = Some(code);
            }
            if status.success() && !stdout.is_empty() {
                if include_headers {
                    let (_, _, http_code) = split_http_response_bytes(&stdout);
                    if http_code >= 400 {
                        *last_http_err = Some((http_code, stdout));
                        return None;
                    }
                    return Some(CurlFetchResult {
                        status_code: if http_code == 0 { 200 } else { http_code },
                        raw: stdout,
                    });
                }
                return Some(CurlFetchResult {
                    status_code: 200,
                    raw: stdout,
                });
            }
            None
        };

        if let Some(px) = proxy_url.filter(|s| !s.trim().is_empty()) {
            let mut args_c = build_base_args(include_headers, true);
            let mut args_p = build_base_args(include_headers, false);
            for a in [&mut args_c, &mut args_p] {
                a.push("-x".to_string());
                a.push(px.trim().to_string());
                a.push(url.to_string());
            }
            if let Ok(out) = run_curl_with_compressed_fallback(args_c, args_p).await
                && let Some(res) = evaluate_curl_out(
                    out.stdout,
                    out.status,
                    &mut last_http_err,
                    &mut last_exit_code,
                )
            {
                return Ok(res);
            }
        }

        let resolve_spec_opt = self.resolve_url_host_via_bootstrap_dns(url).await;
        let mut direct_c = build_base_args(include_headers, true);
        let mut direct_p = build_base_args(include_headers, false);
        for a in [&mut direct_c, &mut direct_p] {
            if let Some(ref spec) = resolve_spec_opt {
                a.push("--resolve".to_string());
                a.push(spec.clone());
            }
            a.push(url.to_string());
        }
        if let Ok(out) = run_curl_with_compressed_fallback(direct_c, direct_p).await
            && let Some(res) = evaluate_curl_out(
                out.stdout,
                out.status,
                &mut last_http_err,
                &mut last_exit_code,
            )
        {
            return Ok(res);
        }

        if last_http_err.is_none() {
            for (doh, pin) in [
                ("https://1.1.1.1/dns-query", None),
                ("https://8.8.8.8/dns-query", None),
                (
                    "https://dns.google/dns-query",
                    Some("dns.google:443:8.8.8.8"),
                ),
                (
                    "https://common.dot.dns.yandex.net/dns-query",
                    Some("common.dot.dns.yandex.net:443:77.88.8.8"),
                ),
            ] {
                let mut doh_c = build_base_args(include_headers, true);
                let mut doh_p = build_base_args(include_headers, false);
                for a in [&mut doh_c, &mut doh_p] {
                    if let Some(p) = pin {
                        a.push("--resolve".to_string());
                        a.push(p.to_string());
                    }
                    a.push("--doh-url".to_string());
                    a.push(doh.to_string());
                    a.push(url.to_string());
                }
                if let Ok(out) = run_curl_with_compressed_fallback(doh_c, doh_p).await
                    && let Some(res) = evaluate_curl_out(
                        out.stdout,
                        out.status,
                        &mut last_http_err,
                        &mut last_exit_code,
                    )
                {
                    return Ok(res);
                }
                if last_http_err.is_some() {
                    break;
                }
            }
        }

        if last_http_err.is_none()
            && proxy_url.is_none()
            && let Some(fb_px) = fallback_proxy_url.filter(|s| !s.trim().is_empty())
        {
            let mut px_c = build_base_args(include_headers, true);
            let mut px_p = build_base_args(include_headers, false);
            for a in [&mut px_c, &mut px_p] {
                a.push("-x".to_string());
                a.push(fb_px.trim().to_string());
                a.push(url.to_string());
            }
            if let Ok(out) = run_curl_with_compressed_fallback(px_c, px_p).await
                && let Some(res) = evaluate_curl_out(
                    out.stdout,
                    out.status,
                    &mut last_http_err,
                    &mut last_exit_code,
                )
            {
                return Ok(res);
            }
        }

        if let Some((http_code, raw)) = last_http_err {
            return Ok(CurlFetchResult {
                status_code: http_code,
                raw,
            });
        }
        let ua_retryable = matches!(last_exit_code, Some(52 | 56 | 35 | 18 | 22));
        let exit_desc = last_exit_code
            .map(|c| format!(" (curl exit {c})"))
            .unwrap_or_default();
        Err(CurlFetchError {
            exit_code: last_exit_code,
            ua_retryable,
            message: format!("curl fetch failed{exit_desc} for {url}"),
        })
    }

    pub async fn has_spawned_child(&self) -> bool {
        self.proc.lock().await.is_some()
    }

    pub(crate) fn enable_switch_history(&self) {
        self.switch_history
            .get_or_init(|| Arc::new(SwitchRecorder::spawn(crate::switch_history::path())));
    }

    pub(crate) fn switch_history_stats(&self) -> Option<crate::switch_history::RecorderStats> {
        self.switch_history.get().map(|r| r.stats())
    }

    fn switch_history_core(&self) -> Option<(u32, u64)> {
        let live = self.state.live.try_read().ok()?;
        let identity = live.core_identity.as_ref()?;
        Some((identity.pid, identity.starttime_ticks))
    }

    async fn clash_request_raw_internal(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> anyhow::Result<(
        String,
        Option<(Arc<SwitchRecorder>, SwitchSource, (u32, u64))>,
        Option<Arc<SwitchGroups>>,
        Option<Instant>,
    )> {
        struct ClashConfig {
            path: String,
            mtime: u128,
            epoch: u64,
            addr: String,
            secret: String,
            groups: Arc<SwitchGroups>,
        }
        static CACHED_CLASH_CRED: std::sync::Mutex<Option<ClashConfig>> =
            std::sync::Mutex::new(None);
        let cur_epoch = CLASH_CRED_EPOCH.load(Ordering::Acquire);

        let observer = self.switch_history.get().map(Arc::clone);
        let source = match (method, path) {
            ("GET", "/proxies") => Some(SwitchSource::ClashProxies),
            ("GET", "/tachyon/failover") => Some(SwitchSource::CoreFailover),
            _ => None,
        };
        let observation = observer
            .as_ref()
            .zip(source)
            .and_then(|(observer, source)| {
                Some((Arc::clone(observer), source, self.switch_history_core()?))
            });
        let mut switch_groups = None;

        let (mut addr, mut secret, cfg_path) = {
            let d = self.state.data.read().await;
            (
                d.settings.clash_api_addr.clone(),
                d.settings.clash_api_secret.clone(),
                d.settings.core_config_path.clone(),
            )
        };
        let default_core_cfg = crate::platform::paths()
            .core_config_dir
            .join("config.json")
            .to_string_lossy()
            .into_owned();
        for candidate_cfg in [
            cfg_path.as_str(),
            default_core_cfg.as_str(),
            "/etc/tachyon-core/config.json",
        ] {
            if let Ok(meta) = std::fs::metadata(candidate_cfg) {
                let mtime = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                if let Ok(guard) = CACHED_CLASH_CRED.lock()
                    && let Some(cached) = guard.as_ref()
                    && cached.epoch == cur_epoch
                    && cached.path == candidate_cfg
                    && cached.mtime == mtime
                    && !cached.addr.is_empty()
                {
                    addr = cached.addr.clone();
                    secret = cached.secret.clone();
                    if observation.is_some() {
                        switch_groups = Some(Arc::clone(&cached.groups));
                    }
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
                        let groups = Arc::new(if observer.is_some() {
                            SwitchGroups::from_config(&val)
                        } else {
                            SwitchGroups::default()
                        });
                        if observation.is_some() {
                            switch_groups = Some(Arc::clone(&groups));
                        }
                        *guard = Some(ClashConfig {
                            path: candidate_cfg.to_owned(),
                            mtime,
                            epoch: cur_epoch,
                            addr: found_addr,
                            secret: found_sec,
                            groups,
                        });
                    }
                    break;
                }
            }
        }
        let started = observation.as_ref().map(|_| Instant::now());
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
        const MAX_CLASH_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
        let mut buf = Vec::with_capacity(65536);
        let mut chunk = [0u8; 16384];
        let mut expected_total: Option<usize> = None;
        let read_fut = async {
            loop {
                let n = stream.read(&mut chunk).await?;
                if n == 0 {
                    break;
                }
                if buf.len().saturating_add(n) > MAX_CLASH_RESPONSE_BYTES {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "clash response exceeds 16 MiB limit",
                    ));
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
                                let total = body_start.saturating_add(cl);
                                if total > MAX_CLASH_RESPONSE_BYTES {
                                    return Err(std::io::Error::new(
                                        std::io::ErrorKind::InvalidData,
                                        "clash response Content-Length exceeds 16 MiB limit",
                                    ));
                                }
                                expected_total = Some(total);
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
                    8000
                });
            if path.contains("/group/") || path.contains("delay-batch") {
                Duration::from_millis(
                    query_ms
                        .saturating_mul(4)
                        .max(query_ms.saturating_add(12_000))
                        .clamp(15_000, 45_000),
                )
            } else {
                Duration::from_millis(query_ms.saturating_add(6000).clamp(5000, 35_000))
            }
        } else if method == "PUT" && path.starts_with("/configs") {
            Duration::from_secs(20)
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
        let trimmed = json_part.trim();
        let raw_body = if trimmed.is_empty() {
            "{}".to_string()
        } else {
            trimmed.to_string()
        };
        Ok((raw_body, observation, switch_groups, started))
    }

    /// Perform an HTTP/1.1 request against the local `tachyon-core` Clash API and return the raw JSON string.
    pub async fn clash_request_raw(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> anyhow::Result<String> {
        let (raw_body, observation, switch_groups, started) =
            self.clash_request_raw_internal(method, path, body).await?;
        if let (Some((recorder, source, identity)), Some(groups), Some(started)) =
            (observation, switch_groups, started)
            && self.switch_history_core() == Some(identity)
        {
            let raw_clone = raw_body.clone();
            let state_clone = Arc::clone(&self.state);
            tokio::task::spawn_blocking(move || {
                if let Ok(result) = serde_json::from_str::<Value>(&raw_clone) {
                    let still_same = state_clone.live.try_read().ok().and_then(|live| {
                        live.core_identity
                            .as_ref()
                            .map(|id| (id.pid, id.starttime_ticks))
                    }) == Some(identity);
                    if still_same {
                        recorder.observe(groups, identity, started, source, &result);
                    }
                }
            });
        }
        Ok(raw_body)
    }

    /// Perform an HTTP/1.1 request against the local `tachyon-core` Clash API.
    pub async fn clash_request(
        &self,
        method: &str,
        path: &str,
        body: Option<&str>,
    ) -> anyhow::Result<Value> {
        let (raw_body, observation, switch_groups, started) =
            self.clash_request_raw_internal(method, path, body).await?;
        let result = serde_json::from_str::<Value>(&raw_body).unwrap_or_else(|_| json!({}));
        if let (Some((recorder, source, identity)), Some(groups), Some(started)) =
            (observation, switch_groups, started)
            && self.switch_history_core() == Some(identity)
        {
            recorder.observe(groups, identity, started, source, &result);
        }
        Ok(result)
    }

    pub async fn get_core_health(&self) -> anyhow::Result<Value> {
        self.clash_request("GET", "/tachyon/health", None).await
    }

    pub async fn get_core_anomalies(&self) -> anyhow::Result<Value> {
        self.clash_request("GET", "/tachyon/anomalies", None).await
    }

    pub async fn get_core_recent_logs(&self, level: &str, limit: usize) -> anyhow::Result<Value> {
        let lvl = encode_query_component(level);
        let path = format!("/tachyon/logs/recent?level={lvl}&limit={limit}");
        self.clash_request("GET", &path, None).await
    }

    pub async fn get_core_config_state(&self) -> anyhow::Result<Value> {
        self.clash_request("GET", "/tachyon/config-state", None)
            .await
    }

    pub async fn get_core_flight_filtered(
        &self,
        only_failed: bool,
        outbound: Option<&str>,
        limit: usize,
    ) -> anyhow::Result<Value> {
        let mut path = format!("/tachyon/flight?only_failed={only_failed}&limit={limit}");
        if let Some(tag) = outbound.map(str::trim).filter(|s| !s.is_empty()) {
            path.push_str("&outbound=");
            path.push_str(&encode_query_component(tag));
        }
        self.clash_request("GET", &path, None).await
    }

    pub async fn flush_core_dns(&self, scope: &str) -> anyhow::Result<Value> {
        let body = json!({ "scope": scope }).to_string();
        self.clash_request("POST", "/tachyon/dns/flush", Some(&body))
            .await
    }

    pub async fn reset_core_outbound(
        &self,
        tag: &str,
        close_sessions: bool,
        stalled_only_ms: Option<u64>,
    ) -> anyhow::Result<Value> {
        let mut obj = json!({
            "tag": tag,
            "close_sessions": close_sessions,
        });
        if let Some(ms) = stalled_only_ms
            && let Some(map) = obj.as_object_mut()
        {
            map.insert("stalled_only_ms".to_string(), json!(ms));
        }
        self.clash_request("POST", "/tachyon/outbound/reset", Some(&obj.to_string()))
            .await
    }

    pub async fn kick_core_filtered(
        &self,
        inbound: Option<&str>,
        user: Option<&str>,
        outbound: Option<&str>,
        only_stalled_ms: Option<u64>,
    ) -> anyhow::Result<Value> {
        let mut obj = serde_json::Map::new();
        if let Some(v) = inbound.filter(|s| !s.is_empty()) {
            obj.insert("inbound".to_string(), json!(v));
        }
        if let Some(v) = user.filter(|s| !s.is_empty()) {
            obj.insert("user".to_string(), json!(v));
        }
        if let Some(v) = outbound.filter(|s| !s.is_empty()) {
            obj.insert("outbound".to_string(), json!(v));
        }
        if let Some(ms) = only_stalled_ms {
            obj.insert("only_stalled_ms".to_string(), json!(ms));
        }
        self.clash_request(
            "POST",
            "/tachyon/kick",
            Some(&Value::Object(obj).to_string()),
        )
        .await
    }

    pub async fn set_core_log_level(
        &self,
        level: &str,
        ttl_sec: Option<u64>,
    ) -> anyhow::Result<Value> {
        let mut obj = json!({ "log-level": crate::store::normalize_core_log_level(level) });
        if let Some(ttl) = ttl_sec
            && let Some(map) = obj.as_object_mut()
        {
            map.insert("ttl_sec".to_string(), json!(ttl));
        }
        self.clash_request("PATCH", "/configs", Some(&obj.to_string()))
            .await
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

        // URLTest / Fallback groups in tachyon-core manage outbound selection internally and reject PUT /proxies/{name}.
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
        self.clash_request(
            "GET",
            &format!("/proxies/{encoded}/exit?timeout=6000"),
            None,
        )
        .await
        .unwrap_or_else(|e| json!({"ok": false, "error": e.to_string()}))
    }

    /// Parse raw subscription content (base64 or newline-separated proxy URIs) into `ParsedProxyNode`s.
    pub fn parse_subscription_payload(raw: &str) -> Vec<ParsedProxyNode> {
        Self::parse_subscription_payload_with_stats(raw).0
    }

    /// Unwrap deep-link subscription wrappers (`happ://add/`, `v2raytun://import/`, `incy://add/`,
    /// `hiddify://import/`, `clash://install-config?url=`, `sing-box://import-remote-profile?url=`,
    /// `ssconf://`, `sub://`, and trailing `" | label"` suffixes).
    pub(crate) fn unwrap_subscription_entry(raw: &str) -> String {
        let mut cur = raw.trim_start_matches('\u{feff}').trim().to_string();
        if let Some((left, _)) = cur.split_once(" | ") {
            let l = left.trim();
            if l.contains("://") || l.starts_with("fptn:") || l.starts_with("fptnb:") {
                cur = l.to_string();
            }
        }
        for _ in 0..4 {
            let trimmed = cur.trim();
            let lc = trimmed.to_ascii_lowercase();
            let mut next: Option<String> = None;
            for prefix in [
                "happ://add/",
                "happ://import/",
                "v2raytun://import/",
                "v2raytun://add/",
                "incy://add/",
                "incy://import/",
                "hiddify://import/",
                "hiddify://add/",
            ] {
                if lc.starts_with(prefix) {
                    let rest = trimmed[prefix.len()..].trim();
                    let decoded = if rest.contains('%') && !rest.contains("://") {
                        config_gen::url_decode_percent(rest)
                    } else {
                        rest.to_string()
                    };
                    if !decoded.is_empty() {
                        next = Some(decoded);
                    }
                    break;
                }
            }
            if next.is_none()
                && (lc.starts_with("clash://install-config")
                    || lc.starts_with("clashmeta://install-config")
                    || lc.starts_with("sing-box://import-remote-profile"))
                && let Some((_, q)) = trimmed.split_once('?')
            {
                for pair in q.split('&') {
                    if let Some((k, v)) = pair.split_once('=')
                        && k.trim().eq_ignore_ascii_case("url")
                    {
                        let decoded = config_gen::url_decode_percent(v.trim());
                        if !decoded.is_empty() {
                            next = Some(decoded);
                        }
                        break;
                    }
                }
            }
            if next.is_none() && lc.starts_with("ssconf://") {
                let rest = trimmed["ssconf://".len()..].trim();
                if rest.starts_with("http://") || rest.starts_with("https://") {
                    next = Some(rest.to_string());
                } else if !rest.is_empty() {
                    next = Some(format!("https://{rest}"));
                }
            }
            if next.is_none() && lc.starts_with("sub://") {
                let rest = trimmed["sub://".len()..].trim();
                let (b64_part, _) = rest.split_once('#').unwrap_or((rest, ""));
                if let Some(decoded) = decode_base64_flex_bytes(b64_part)
                    && let Ok(url_str) = String::from_utf8(decoded)
                    && !url_str.trim().is_empty()
                {
                    next = Some(url_str.trim().to_string());
                }
            }
            match next {
                Some(n) if n != cur => cur = n,
                _ => break,
            }
        }
        cur
    }

    /// Parse raw subscription content into usable nodes and return the count of dropped `.invalid` / unsupported-client stubs.
    pub(crate) fn parse_subscription_payload_with_stats(
        raw: &str,
    ) -> (Vec<ParsedProxyNode>, usize) {
        Self::parse_subscription_payload_depth(raw, 0)
    }

    fn parse_subscription_payload_depth(raw: &str, depth: usize) -> (Vec<ParsedProxyNode>, usize) {
        if depth > 4 {
            return (Vec::new(), 0);
        }
        let cleaned_bom = raw.trim_start_matches('\u{feff}').trim();
        if cleaned_bom.is_empty() {
            return (Vec::new(), 0);
        }

        let unwrapped = Self::unwrap_subscription_entry(cleaned_bom);
        if unwrapped != cleaned_bom {
            return Self::parse_subscription_payload_depth(&unwrapped, depth + 1);
        }

        let stripped_body = strip_subscription_comment_wrapper(cleaned_bom);
        let candidate_str = if !stripped_body.is_empty() {
            stripped_body
        } else {
            cleaned_bom
        };

        let mut out: Vec<ParsedProxyNode> = Vec::new();
        let candidate_lc = candidate_str.to_ascii_lowercase();
        if candidate_lc.starts_with("fptn:")
            || candidate_lc.starts_with("fptnb:")
            || candidate_lc.starts_with("fptn://")
            || candidate_lc.starts_with("fptnb://")
        {
            out = config_gen::parse_fptn_token_nodes(candidate_str);
        }

        if out.is_empty() && looks_like_wireguard_ini_payload(candidate_str) {
            let wg_pairs =
                config_gen::parse_amnezia_conf_outbounds_with_prefix("wg", candidate_str);
            for (tag, val) in wg_pairs {
                let server = val
                    .get("server")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let server_port = val
                    .get("server_port")
                    .and_then(Value::as_u64)
                    .unwrap_or(51820) as u16;
                out.push(ParsedProxyNode {
                    country: config_gen::detect_country_code(&tag),
                    tag,
                    protocol: "wireguard".to_string(),
                    server,
                    server_port,
                    raw_uri: "wgconf:inline".to_string(),
                    outbound_json: val,
                });
            }
        }

        if out.is_empty()
            && let Some(json_nodes) = config_gen::parse_json_subscription_payload(candidate_str)
        {
            out = json_nodes;
        }

        if out.is_empty()
            && let Some(clash_nodes) =
                config_gen::parse_clash_yaml_subscription_payload(candidate_str)
        {
            out = clash_nodes;
        }

        if out.is_empty() {
            let mut line_nodes = Vec::new();
            for (idx, line) in candidate_str.lines().enumerate() {
                let t = line.trim();
                if t.is_empty() || t.starts_with('#') || t.starts_with("//") {
                    continue;
                }
                let fptn_nodes = config_gen::parse_fptn_token_nodes(t);
                if !fptn_nodes.is_empty() {
                    line_nodes.extend(fptn_nodes);
                    continue;
                }
                if let Some(node) = config_gen::parse_proxy_uri(t, idx) {
                    line_nodes.push(node);
                }
            }
            if !line_nodes.is_empty() {
                out = line_nodes;
            }
        }

        if out.is_empty() && depth < 4 {
            let mut b64_candidates: Vec<String> = vec![candidate_str.to_string()];
            if candidate_str.contains('%') {
                b64_candidates.push(config_gen::url_decode_percent(candidate_str));
            }
            for cand in b64_candidates {
                if let Some(decoded_bytes) = decode_base64_flex_bytes(&cand) {
                    let decoded_str = decode_text_lossy_with_bom(&decoded_bytes);
                    let decoded_trim = decoded_str.trim_start_matches('\u{feff}').trim();
                    if !decoded_trim.is_empty() && decoded_trim != candidate_str {
                        let (sub_nodes, sub_stubs) =
                            Self::parse_subscription_payload_depth(decoded_trim, depth + 1);
                        if !sub_nodes.is_empty() || sub_stubs > 0 {
                            return (sub_nodes, sub_stubs);
                        }
                    }
                }
            }
        }

        // Drop informational/banner pseudo-nodes pointing to loopback/unspecified addresses
        // (e.g. `127.0.0.1:443#Remaining: 15GB`, `0.0.0.0:1#Лимит устройств исчерпан`) that cause
        // immediate failures after reload. Track `.invalid`, unspecified hosts, port-1 stub
        // banners, and explicit client-warning tags separately so auto-UA discovery promotes past
        // degraded feeds (while keeping `127.0.0.1:443` traffic banners distinct for legacy behavior/tests).
        let mut dropped_invalid_stubs = 0usize;
        out.retain(|node| {
            let srv = node.server.trim();
            let bare = srv
                .trim_start_matches('[')
                .trim_end_matches(']')
                .trim_end_matches('.')
                .to_ascii_lowercase();
            let tag_lc = node.tag.to_lowercase();
            let is_client_stub_tag = [
                "клиент не поддерживается",
                "не поддерживается",
                "unsupported client",
                "client not supported",
                "client is not supported",
                "update client",
                "update your client",
                "обновите клиент",
                "обновите приложение",
                "скачать happ",
                "скачайте happ",
                "используйте happ",
                "только в happ",
                "app not supported",
                "app is not supported",
                "unsupported app",
                "подписка истекла",
                "subscription expired",
            ]
            .iter()
            .any(|p| tag_lc.contains(p));
            let is_bad_reality_or_flow = node.outbound_json.get("type").and_then(Value::as_str)
                == Some("vless")
                && (node
                    .outbound_json
                    .get("flow")
                    .and_then(Value::as_str)
                    .is_some_and(|f| !f.trim().is_empty() && f.trim() != "xtls-rprx-vision")
                    || node
                        .outbound_json
                        .pointer("/tls/reality")
                        .and_then(Value::as_object)
                        .is_some_and(|r| {
                            r.get("enabled").and_then(Value::as_bool) != Some(false)
                                && r.get("public_key").and_then(Value::as_str).is_none_or(|p| {
                                    decode_base64_flex_bytes(p.trim()).is_none_or(|b| b.len() != 32)
                                })
                        }));
            let keep = !is_client_stub_tag
                && !is_bad_reality_or_flow
                && (srv.is_empty() || config_gen::is_usable_external_sub_host(srv));
            if !keep
                && (is_client_stub_tag
                    || is_bad_reality_or_flow
                    || bare == "invalid"
                    || bare.ends_with(".invalid")
                    || matches!(bare.as_str(), "0.0.0.0" | "::" | "0:0:0:0:0:0:0:0")
                    || node.server_port == 1)
            {
                dropped_invalid_stubs += 1;
            }
            keep
        });

        let mut taken_tags: HashSet<String> = HashSet::new();
        for node in &mut out {
            config_gen::assign_unique_node_tag(node, &mut taken_tags);
        }
        (out, dropped_invalid_stubs)
    }

    async fn try_core_subscription_cli(
        &self,
        args: &[String],
        stdin_bytes: Option<&[u8]>,
        timeout: Duration,
    ) -> Option<(
        Vec<ParsedProxyNode>,
        usize,
        crate::store::OutboundSource,
        String,
    )> {
        let core_bin = self.resolve_bin_path().await;
        if core_bin.trim().is_empty() || !Path::new(core_bin.trim()).is_file() {
            return None;
        }
        let mut cmd = Command::new(core_bin.trim());
        cmd.args(args);
        let out = Self::run_command_stdin_output_with_timeout(&mut cmd, stdin_bytes, timeout)
            .await
            .ok()?;
        if !out.status.success() || out.stdout.is_empty() {
            return None;
        }
        let parsed_json: Value = serde_json::from_slice(&out.stdout).ok()?;
        let outbounds = parsed_json.get("outbounds").and_then(Value::as_array)?;
        let raw_nodes = config_gen::normalize_singbox_json_outbounds(outbounds);
        let mut meta_src = crate::store::OutboundSource::default();
        if let Some(ui) = parsed_json.get("user_info").and_then(Value::as_object) {
            if let Some(u) = ui.get("Upload").and_then(Value::as_u64) {
                meta_src.sub_upload_bytes = u;
            }
            if let Some(d) = ui.get("Download").and_then(Value::as_u64) {
                meta_src.sub_download_bytes = d;
            }
            if let Some(t) = ui.get("Total").and_then(Value::as_u64) {
                meta_src.sub_total_bytes = t;
            }
            if let Some(e) = ui.get("Expire").and_then(Value::as_i64) {
                meta_src.sub_expire_unix = e;
            }
        }
        if let Some(md) = parsed_json.get("metadata").and_then(Value::as_object) {
            if let Some(t) = md.get("profile_title").and_then(Value::as_str)
                && !t.trim().is_empty()
            {
                meta_src.sub_title = crate::store::decode_sub_header_value(t.trim());
            }
            if let Some(s) = md.get("support_url").and_then(Value::as_str)
                && !s.trim().is_empty()
            {
                meta_src.sub_support_url = s.trim().to_string();
            }
            if let Some(w) = md.get("web_page_url").and_then(Value::as_str)
                && !w.trim().is_empty()
            {
                meta_src.sub_web_page_url = w.trim().to_string();
            }
            if let Some(a) = md.get("announce").and_then(Value::as_str)
                && !a.trim().is_empty()
            {
                meta_src.sub_announce = crate::store::decode_sub_header_value(a.trim());
            }
            if let Some(h) = md.get("update_interval_hours").and_then(Value::as_u64)
                && h >= 1
            {
                meta_src.subscription_update_interval = format!("{}h", h.min(24 * 30));
            }
        }
        let ua_used = parsed_json
            .get("user_agent")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();

        let mut kept = Vec::new();
        let mut stubs = 0usize;
        let mut taken_tags = HashSet::new();
        for mut node in raw_nodes {
            let srv = node.server.trim().to_string();
            let bare = srv
                .trim_start_matches('[')
                .trim_end_matches(']')
                .trim_end_matches('.')
                .to_ascii_lowercase();
            let keep = srv.is_empty() || config_gen::is_usable_external_sub_host(&srv);
            if !keep {
                if bare == "invalid"
                    || bare.ends_with(".invalid")
                    || matches!(bare.as_str(), "0.0.0.0" | "::" | "0:0:0:0:0:0:0:0")
                    || node.server_port == 1
                {
                    stubs += 1;
                }
                continue;
            }
            config_gen::assign_unique_node_tag(&mut node, &mut taken_tags);
            kept.push(node);
        }
        (!kept.is_empty()).then_some((kept, stubs, meta_src, ua_used))
    }

    async fn try_core_subscription_parse(
        &self,
        raw_bytes: &[u8],
        headers_part: &str,
        hwid: Option<&str>,
        source_url: Option<&str>,
    ) -> Option<(Vec<ParsedProxyNode>, usize, crate::store::OutboundSource)> {
        let core_bin = self.resolve_bin_path().await;
        if core_bin.trim().is_empty() || !Path::new(core_bin.trim()).is_file() {
            return None;
        }
        let encrypt_tag = extract_http_header_value(headers_part, "encrypt-tag");
        let payload_bytes: Vec<u8> = if encrypt_tag.is_some() {
            let mut dec_args = vec![
                "subscription".to_string(),
                "decrypt".to_string(),
                "-".to_string(),
            ];
            if let Some(u) = source_url.map(str::trim).filter(|s| !s.is_empty()) {
                dec_args.push(format!("--url={u}"));
            }
            if let Some(et) = encrypt_tag.as_deref() {
                dec_args.push(format!("--encrypt-tag={et}"));
            }
            if let Some(hw) = hwid.map(str::trim).filter(|s| !s.is_empty()) {
                dec_args.push(format!("--hwid={hw}"));
            }
            let mut dec_cmd = Command::new(core_bin.trim());
            dec_cmd.args(&dec_args);
            match Self::run_command_stdin_output_with_timeout(
                &mut dec_cmd,
                Some(raw_bytes),
                Duration::from_secs(12),
            )
            .await
            {
                Ok(out) if out.status.success() && !out.stdout.is_empty() => out.stdout,
                _ => raw_bytes.to_vec(),
            }
        } else {
            raw_bytes.to_vec()
        };

        let normalized_utf8 = decode_text_lossy_with_bom(&payload_bytes);
        let mut parse_args = vec![
            "subscription".to_string(),
            "parse".to_string(),
            "-".to_string(),
            "--format=full".to_string(),
        ];
        if let Some(hw) = hwid.map(str::trim).filter(|s| !s.is_empty()) {
            parse_args.push(format!("--hwid={hw}"));
        }
        for line in headers_part.lines() {
            if let Some((k, v)) = line.split_once(':') {
                let kt = k.trim();
                let vt = v.trim();
                if kt.to_ascii_lowercase().starts_with("x-") && !vt.is_empty() {
                    parse_args.push("-H".to_string());
                    parse_args.push(format!("{kt}: {vt}"));
                }
            }
        }
        let (nodes, stubs, meta, _) = self
            .try_core_subscription_cli(
                &parse_args,
                Some(normalized_utf8.as_bytes()),
                Duration::from_secs(15),
            )
            .await?;
        Some((nodes, stubs, meta))
    }

    #[allow(clippy::too_many_arguments)]
    async fn try_core_subscription_fetch(
        &self,
        url: &str,
        ua_opt: Option<&str>,
        send_hwid: bool,
        custom_hwid: Option<&str>,
        insecure: bool,
        proxy_url: Option<&str>,
        extra_headers: &[(String, String)],
    ) -> Option<(
        Vec<ParsedProxyNode>,
        usize,
        crate::store::OutboundSource,
        String,
    )> {
        let mut args = vec![
            "subscription".to_string(),
            "fetch".to_string(),
            url.to_string(),
            "--format=full".to_string(),
        ];
        if let Some(ua) = ua_opt.map(str::trim).filter(|s| !s.is_empty()) {
            args.push(format!("--ua={ua}"));
        }
        if !send_hwid {
            args.push("--no-hwid".to_string());
        } else if let Some(hw) = custom_hwid.map(str::trim).filter(|s| !s.is_empty()) {
            args.push(format!("--hwid={hw}"));
        }
        if insecure {
            args.push("-k".to_string());
        }
        if let Some(px) = proxy_url.map(str::trim).filter(|s| !s.is_empty()) {
            args.push(format!("--proxy={px}"));
        }
        for (k, v) in extra_headers {
            args.push("-H".to_string());
            args.push(format!("{k}: {v}"));
        }
        self.try_core_subscription_cli(&args, None, Duration::from_secs(30))
            .await
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
        let eff_core_cfg = Self::effective_core_config_path_for(&self.state, &snapshot.settings);
        let service_mixed_port =
            read_service_mixed_port_from_config(&eff_core_cfg.to_string_lossy());
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
            let put_ok = self
                .clash_request("PUT", &format!("/providers/proxies/{enc_src_id}"), None)
                .await
                .is_ok();
            let fresh_providers = if put_ok {
                self.clash_request("GET", "/providers/proxies", None)
                    .await
                    .ok()
            } else {
                None
            };

            // Check if `tachyon-core` `/providers/proxies` has `subscriptionInfo` for this source
            if let Some(pmap) = fresh_providers.as_ref().or(providers_map.as_ref())
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

            let explicit_proxy_opt = if src.download_via_proxy_enabled {
                sec_proxy_ports
                    .get(&src.download_via_proxy_section)
                    .copied()
                    .or(global_sub_proxy)
                    .or(service_mixed_port)
            } else {
                global_sub_proxy
            }
            .map(|p| format!("http://127.0.0.1:{p}"));
            let auto_fallback_proxy_opt = if explicit_proxy_opt.is_none() {
                service_mixed_port
                    .or_else(|| sec_proxy_ports.values().copied().min())
                    .map(|p| format!("http://127.0.0.1:{p}"))
            } else {
                None
            };

            let extra_headers = Self::build_subscription_request_headers(&src);
            let hwid_free_headers = Self::build_subscription_request_headers_inner(&src, false);
            let urls: Vec<String> = src
                .subscription_urls
                .iter()
                .map(|raw_u| Self::unwrap_subscription_entry(raw_u))
                .filter(|u| !u.is_empty())
                .collect();
            let src_hwid_val = {
                let explicit = src.hwid.trim();
                if !explicit.is_empty() {
                    Some(explicit.to_string())
                } else if src.auto_hwid {
                    Some(Self::compute_deterministic_router_hwid())
                } else {
                    None
                }
            };
            let allow_insecure_tls = src.subscription_insecure;

            let probe_with_ua_headers =
                |base_src: &crate::store::OutboundSource,
                 ua: &str,
                 hdrs: &[(String, String)],
                 use_hwid_cli: bool| {
                    let mut trial_src = base_src.clone();
                    let hdrs_owned = hdrs.to_vec();
                    let urls_ref = &urls;
                    let proxy_ref = explicit_proxy_opt.as_deref();
                    let fb_proxy_ref = auto_fallback_proxy_opt.as_deref();
                    let ua_owned = ua.to_string();
                    let hwid_cli_opt = use_hwid_cli.then(|| src_hwid_val.clone()).flatten();
                    async move {
                        let mut out_nodes: Vec<ParsedProxyNode> = Vec::new();
                        let mut dropped_invalid_stubs = 0usize;
                        let mut err_msg: Option<String> = None;
                        let mut got_http_reply = false;
                        let mut retryable_transport_err = false;
                        for entry in urls_ref {
                            let lc_entry = entry.to_ascii_lowercase();
                            let is_http =
                                lc_entry.starts_with("http://") || lc_entry.starts_with("https://");
                            if !is_http {
                                let (mut parsed_inline, stubs_inline) =
                                    Self::parse_subscription_payload_with_stats(entry);
                                dropped_invalid_stubs += stubs_inline;
                                if parsed_inline.is_empty()
                                    && let Some((core_nodes, core_stubs, core_meta)) = self
                                        .try_core_subscription_parse(
                                            entry.as_bytes(),
                                            "",
                                            hwid_cli_opt.as_deref(),
                                            None,
                                        )
                                        .await
                                {
                                    parsed_inline = core_nodes;
                                    dropped_invalid_stubs += core_stubs;
                                    merge_sub_source_metadata(&mut trial_src, &core_meta);
                                }
                                got_http_reply = true;
                                for n in parsed_inline {
                                    if !out_nodes
                                        .iter()
                                        .any(|existing: &ParsedProxyNode| existing.tag == n.tag)
                                    {
                                        out_nodes.push(n);
                                    }
                                }
                                continue;
                            }
                            match self
                                .curl_fetch_detailed(
                                    entry,
                                    true,
                                    15,
                                    proxy_ref,
                                    fb_proxy_ref,
                                    Some(&ua_owned),
                                    &hdrs_owned,
                                    allow_insecure_tls,
                                )
                                .await
                            {
                                Ok(fetch_res) => {
                                    got_http_reply = true;
                                    let (headers_part, body_bytes, http_status) =
                                        split_http_response_bytes(&fetch_res.raw);
                                    if http_status >= 400 {
                                        retryable_transport_err = true;
                                        if err_msg.is_none() {
                                            err_msg = Some(
                                                if headers_indicate_hwid_not_supported(
                                                    &headers_part,
                                                ) {
                                                    format!(
                                                        "Провайдер подписки ({entry}) отклонил параметры устройства (X-Hwid-Not-Supported)"
                                                    )
                                                } else {
                                                    format!("{entry}: HTTP {http_status}")
                                                },
                                            );
                                        }
                                        continue;
                                    }
                                    parse_subscription_headers(&headers_part, &mut trial_src);
                                    let body_text = decode_text_lossy_with_bom(body_bytes);
                                    parse_subscription_body_metadata(&body_text, &mut trial_src);
                                    let body_trim_lc = body_text
                                        .trim_start_matches('\u{feff}')
                                        .trim()
                                        .to_ascii_lowercase();
                                    let needs_core_decrypt =
                                        extract_http_header_value(&headers_part, "encrypt-tag")
                                            .is_some()
                                            || body_trim_lc.starts_with("happ://crypt")
                                            || body_trim_lc.starts_with("v2raytun://crypt");

                                    let (mut parsed_for_url, mut stubs_for_url) =
                                        if needs_core_decrypt {
                                            (Vec::new(), 0)
                                        } else {
                                            Self::parse_subscription_payload_with_stats(&body_text)
                                        };
                                    if parsed_for_url.is_empty()
                                        && let Some((core_nodes, core_stubs, core_meta)) = self
                                            .try_core_subscription_parse(
                                                body_bytes,
                                                &headers_part,
                                                hwid_cli_opt.as_deref(),
                                                Some(entry),
                                            )
                                            .await
                                    {
                                        parsed_for_url = core_nodes;
                                        stubs_for_url = core_stubs.max(stubs_for_url);
                                        merge_sub_source_metadata(&mut trial_src, &core_meta);
                                    }
                                    dropped_invalid_stubs += stubs_for_url;
                                    if parsed_for_url.is_empty() && err_msg.is_none() {
                                        err_msg = Some(
                                            if headers_indicate_hwid_not_supported(&headers_part) {
                                                format!(
                                                    "Провайдер подписки ({entry}) отклонил параметры устройства (X-Hwid-Not-Supported)"
                                                )
                                            } else {
                                                format!(
                                                    "Ответ подписки ({entry}) не содержит поддерживаемых узлов"
                                                )
                                            },
                                        );
                                    }
                                    for n in parsed_for_url {
                                        if !out_nodes
                                            .iter()
                                            .any(|existing: &ParsedProxyNode| existing.tag == n.tag)
                                        {
                                            out_nodes.push(n);
                                        }
                                    }
                                }
                                Err(e) => {
                                    if e.ua_retryable {
                                        got_http_reply = true;
                                        retryable_transport_err = true;
                                    }
                                    if err_msg.is_none() {
                                        err_msg = Some(format!("{entry}: {}", e.message));
                                    }
                                }
                            }
                        }
                        (
                            out_nodes,
                            dropped_invalid_stubs,
                            err_msg,
                            got_http_reply,
                            retryable_transport_err,
                            trial_src,
                        )
                    }
                };

            let (mut nodes, mut last_fetch_err, mut final_src, any_http_reply) = if !src
                .auto_user_agent
            {
                let explicit_ua = Self::normalize_subscription_user_agent(&src.user_agent);
                let effective_ua = if explicit_ua.is_empty() {
                    "tachyon-core/2.0 (compatible; sing-box 1.14.3)".to_string()
                } else {
                    explicit_ua
                };
                let (n, _stubs, e, got_http, _retried, mut next_src) = probe_with_ua_headers(
                    &src,
                    &effective_ua,
                    &extra_headers,
                    src_hwid_val.is_some(),
                )
                .await;
                if !n.is_empty() {
                    next_src.sub_preferred_user_agent = effective_ua;
                }
                (n, e, next_src, got_http)
            } else {
                let preferred =
                    Self::normalize_subscription_user_agent(&src.sub_preferred_user_agent);
                struct UaProbeCandidate {
                    ua: String,
                    count: usize,
                    dropped_stubs: usize,
                    nodes: Vec<ParsedProxyNode>,
                    err: Option<String>,
                    src: crate::store::OutboundSource,
                }
                let mut candidates: Vec<UaProbeCandidate> = Vec::new();
                let mut fast_winner: Option<(
                    Vec<ParsedProxyNode>,
                    Option<String>,
                    crate::store::OutboundSource,
                )> = None;
                let mut already_tried_preferred = false;
                let mut saw_http = false;
                if !preferred.is_empty() {
                    already_tried_preferred = true;
                    let (n, dropped_stubs, e, got_http, _retried, mut next_src) =
                        probe_with_ua_headers(
                            &src,
                            &preferred,
                            &extra_headers,
                            src_hwid_val.is_some(),
                        )
                        .await;
                    saw_http |= got_http;
                    if !n.is_empty()
                        && (dropped_stubs == 0 || Self::is_happ_versioned_user_agent(&preferred))
                    {
                        next_src.sub_preferred_user_agent = preferred.clone();
                        fast_winner = Some((n, e, next_src));
                    } else if !n.is_empty() {
                        candidates.push(UaProbeCandidate {
                            ua: preferred.clone(),
                            count: n.len(),
                            dropped_stubs,
                            nodes: n,
                            err: e,
                            src: next_src,
                        });
                    }
                }
                if let Some((n, e, next_src)) = fast_winner {
                    (n, e, next_src, true)
                } else {
                    let mut first_err: Option<String> = None;
                    for (idx, ua) in Self::SUBSCRIPTION_AUTO_USER_AGENTS.iter().enumerate() {
                        if already_tried_preferred && *ua == preferred {
                            continue;
                        }
                        if idx > 0 {
                            tokio::time::sleep(Duration::from_millis(100)).await;
                        }
                        let (n, dropped_stubs, e, got_http, ua_retryable, next_src) =
                            probe_with_ua_headers(&src, ua, &extra_headers, src_hwid_val.is_some())
                                .await;
                        saw_http |= got_http;
                        if first_err.is_none() && e.is_some() {
                            first_err = e.clone();
                        }
                        let count = n.len();
                        candidates.push(UaProbeCandidate {
                            ua: (*ua).to_string(),
                            count,
                            dropped_stubs,
                            nodes: n,
                            err: e,
                            src: next_src,
                        });
                        if !got_http && !ua_retryable && count == 0 && idx >= 1 {
                            // Network/DNS transport unreachable across distinct client UAs — skip remaining retries.
                            break;
                        }
                    }
                    let summary: Vec<(usize, usize)> = candidates
                        .iter()
                        .map(|c| (c.count, c.dropped_stubs))
                        .collect();
                    if let Some(best_idx) = pick_best_subscription_ua_candidate_index(&summary) {
                        let best = candidates.swap_remove(best_idx);
                        let mut best_src = best.src;
                        best_src.sub_preferred_user_agent = best.ua;
                        (best.nodes, best.err, best_src, saw_http)
                    } else {
                        let mut fallback_src = candidates
                            .into_iter()
                            .next()
                            .map(|c| c.src)
                            .unwrap_or_else(|| src.clone());
                        fallback_src.sub_preferred_user_agent.clear();
                        (Vec::new(), first_err, fallback_src, saw_http)
                    }
                }
            };
            if nodes.is_empty()
                && any_http_reply
                && final_src.auto_hwid
                && final_src.hwid.trim().is_empty()
            {
                let retry_uas: Vec<String> = if final_src.auto_user_agent {
                    vec![
                        "Happ/4.6.2".to_string(),
                        "v2rayNG/1.8.29".to_string(),
                        "Mihomo/1.19.16".to_string(),
                        "HiddifyNext/2.5.7".to_string(),
                        "tachyon-core/2.0 (compatible; sing-box 1.14.3)".to_string(),
                    ]
                } else {
                    let explicit_ua =
                        Self::normalize_subscription_user_agent(&final_src.user_agent);
                    if explicit_ua.is_empty() {
                        vec![
                            "Happ/4.6.2".to_string(),
                            "v2rayNG/1.8.29".to_string(),
                            "tachyon-core/2.0 (compatible; sing-box 1.14.3)".to_string(),
                        ]
                    } else {
                        vec![
                            explicit_ua,
                            "Happ/4.6.2".to_string(),
                            "v2rayNG/1.8.29".to_string(),
                        ]
                    }
                };
                for retry_ua in retry_uas {
                    let (n, _stubs, e, _, _, mut next_src) =
                        probe_with_ua_headers(&src, &retry_ua, &hwid_free_headers, false).await;
                    if !n.is_empty() {
                        next_src.sub_preferred_user_agent = retry_ua;
                        nodes = n;
                        last_fetch_err = e;
                        final_src = next_src;
                        break;
                    }
                }
            } else if nodes.is_empty()
                && any_http_reply
                && !final_src.auto_hwid
                && final_src.hwid.trim().is_empty()
            {
                let mut with_router_hwid = final_src.clone();
                with_router_hwid.auto_hwid = true;
                let router_hwid_headers =
                    Self::build_subscription_request_headers(&with_router_hwid);
                for retry_ua in [
                    "tachyon-core/2.0 (compatible; sing-box 1.14.3)",
                    "Happ/4.6.2",
                    "Clash.Meta/v1.19.10",
                    "v2rayNG/1.8.29",
                ] {
                    let (n, _stubs, e, _, _, mut next_src) =
                        probe_with_ua_headers(&src, retry_ua, &router_hwid_headers, true).await;
                    if !n.is_empty() {
                        next_src.sub_preferred_user_agent = retry_ua.to_string();
                        nodes = n;
                        last_fetch_err = e;
                        final_src = next_src;
                        break;
                    }
                }
            }
            if nodes.is_empty() {
                let core_ua = if !final_src.auto_user_agent {
                    let u = Self::normalize_subscription_user_agent(&final_src.user_agent);
                    (!u.is_empty()).then_some(u)
                } else {
                    None
                };
                let effective_proxy = explicit_proxy_opt
                    .as_deref()
                    .or(auto_fallback_proxy_opt.as_deref());
                for entry in &urls {
                    let lc = entry.to_ascii_lowercase();
                    if !(lc.starts_with("http://") || lc.starts_with("https://")) {
                        continue;
                    }
                    if let Some((core_nodes, _core_stubs, core_meta, ua_used)) = self
                        .try_core_subscription_fetch(
                            entry,
                            core_ua.as_deref(),
                            final_src.auto_hwid || !final_src.hwid.trim().is_empty(),
                            (!final_src.hwid.trim().is_empty()).then_some(final_src.hwid.trim()),
                            allow_insecure_tls,
                            effective_proxy,
                            &extra_headers,
                        )
                        .await
                    {
                        merge_sub_source_metadata(&mut final_src, &core_meta);
                        if !ua_used.is_empty() {
                            final_src.sub_preferred_user_agent = ua_used;
                        }
                        for n in core_nodes {
                            if !nodes.iter().any(|ex: &ParsedProxyNode| ex.tag == n.tag) {
                                nodes.push(n);
                            }
                        }
                    }
                }
                if !nodes.is_empty() {
                    last_fetch_err = None;
                }
            }
            src = final_src;
            fetched_results.push(SubFetchResult {
                id: src.id.clone(),
                nodes,
                last_fetch_err,
                updated_src: src,
            });
        }

        // Re-read fresh state right before committing so concurrent config edits are preserved.
        let finish_ts = unix_now_secs().max(now);
        {
            let mut attempts = self.sub_last_attempt.lock().await;
            for res in &fetched_results {
                attempts.insert(res.id.clone(), finish_ts);
            }
        }
        let mut candidate = self.state.data.read().await.clone();
        let mut updated_sources = 0usize;
        let mut persist_needed = false;
        let mut core_reload_needed = false;
        let mut mem_updates: Vec<(String, i64, String, u64, u64, String)> = Vec::new();

        for res in fetched_results {
            let Some(src) = candidate
                .outbound_sources
                .iter_mut()
                .find(|s| s.id == res.id && s.source_type == "subscription")
            else {
                continue;
            };
            let static_meta_changed = src.sub_title != res.updated_src.sub_title
                || src.sub_support_url != res.updated_src.sub_support_url
                || src.sub_web_page_url != res.updated_src.sub_web_page_url
                || src.sub_announce != res.updated_src.sub_announce
                || src.sub_total_bytes != res.updated_src.sub_total_bytes
                || src.sub_expire_unix != res.updated_src.sub_expire_unix
                || src.sub_preferred_user_agent != res.updated_src.sub_preferred_user_agent
                || (src.subscription_update_interval.trim().is_empty()
                    && !res
                        .updated_src
                        .subscription_update_interval
                        .trim()
                        .is_empty());

            src.sub_title = res.updated_src.sub_title;
            src.sub_support_url = res.updated_src.sub_support_url;
            src.sub_web_page_url = res.updated_src.sub_web_page_url;
            src.sub_announce = res.updated_src.sub_announce;
            src.sub_upload_bytes = res.updated_src.sub_upload_bytes;
            src.sub_download_bytes = res.updated_src.sub_download_bytes;
            src.sub_total_bytes = res.updated_src.sub_total_bytes;
            src.sub_expire_unix = res.updated_src.sub_expire_unix;
            if src.sub_preferred_user_agent != res.updated_src.sub_preferred_user_agent {
                src.sub_preferred_user_agent = res.updated_src.sub_preferred_user_agent;
            }
            if src.subscription_update_interval.trim().is_empty()
                && !res
                    .updated_src
                    .subscription_update_interval
                    .trim()
                    .is_empty()
            {
                src.subscription_update_interval = res.updated_src.subscription_update_interval;
            }

            if !res.nodes.is_empty() {
                let nodes_changed = !nodes_materially_equal(&src.cached_nodes, &res.nodes);
                if nodes_changed {
                    core_reload_needed = true;
                }
                if nodes_changed || static_meta_changed {
                    persist_needed = true;
                }
                src.cached_nodes = res.nodes;
                src.last_updated_unix = finish_ts;
                src.sub_last_error.clear();
                updated_sources += 1;
            } else {
                if static_meta_changed {
                    persist_needed = true;
                }
                src.sub_last_error = res.last_fetch_err.unwrap_or_else(|| {
                    "Не удалось загрузить или разобрать узлы подписки".to_string()
                });
            }
            mem_updates.push((
                src.id.clone(),
                src.last_updated_unix,
                src.sub_last_error.clone(),
                src.sub_upload_bytes,
                src.sub_download_bytes,
                src.sub_preferred_user_agent.clone(),
            ));
        }

        if persist_needed {
            if let Err(e) = transaction::commit_transaction_with_source(
                &self.state,
                candidate.clone(),
                "subscription",
            )
            .await
            {
                self.state.live.write().await.push_event(
                    "warn",
                    "subscription",
                    &format!("Subscription state commit skipped (in-memory timestamp kept): {e:#}"),
                );
                return Err(e);
            }
            crate::ubus_bridge::sync_from_store_to_json_and_cache(&candidate);
            if core_reload_needed && !self.is_manually_stopped() {
                let _ = self.apply_or_reload().await;
            }
        } else if !mem_updates.is_empty() {
            let mut d = self.state.data.write().await;
            for (id, ts, err, up, down, pref_ua) in mem_updates {
                if let Some(src) = d
                    .outbound_sources
                    .iter_mut()
                    .find(|s| s.id == id && s.source_type == "subscription")
                {
                    src.last_updated_unix = ts;
                    src.sub_last_error = err;
                    src.sub_upload_bytes = up;
                    src.sub_download_bytes = down;
                    src.sub_preferred_user_agent = pref_ua;
                }
            }
            crate::ubus_bridge::sync_from_store_to_json_and_cache(&d);
            drop(d);
            self.state.bump_generation();
        }
        Ok(updated_sources)
    }

    pub async fn refresh_all_subscriptions(&self) -> anyhow::Result<usize> {
        self.refresh_subscription_source("").await
    }

    pub async fn refresh_due_subscriptions(&self, target: Option<&str>) -> anyhow::Result<usize> {
        let candidate = self.state.data.read().await.clone();
        let last_attempts = self.sub_last_attempt.lock().await.clone();
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
            let last_attempt = last_attempts.get(&src.id).copied().unwrap_or(0);
            let effective_last = src.last_updated_unix.max(last_attempt);
            let is_due = if src.cached_nodes.is_empty() {
                effective_last <= 0 || now.saturating_sub(effective_last) >= interval_secs.min(900)
            } else {
                effective_last <= 0 || now.saturating_sub(effective_last) >= interval_secs
            };
            if is_due {
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

    pub(crate) fn clash_selector_candidates(
        section_id: &str,
        balancer_refs: &[String],
        proxies_resp: Option<&Value>,
    ) -> Vec<String> {
        let mut raw_candidates = vec![format!("sel-{section_id}")];
        for bal_ref in balancer_refs {
            let b = bal_ref.trim();
            if !b.is_empty() {
                raw_candidates.push(format!("bal-{section_id}-{b}"));
            }
        }
        raw_candidates.push(section_id.to_string());
        raw_candidates.push(format!("{section_id}-out"));

        if let Some(proxies_obj) = proxies_resp
            .and_then(|v| v.get("proxies"))
            .and_then(Value::as_object)
        {
            raw_candidates
                .into_iter()
                .filter(|name| {
                    proxies_obj
                        .get(name)
                        .and_then(|entry| entry.get("type"))
                        .and_then(Value::as_str)
                        .is_some_and(|t| t.eq_ignore_ascii_case("selector"))
                })
                .collect()
        } else {
            // When /proxies could not be queried, avoid sending PUT to bal-* (URLTest/Fallback).
            raw_candidates
                .into_iter()
                .filter(|name| !name.starts_with("bal-"))
                .collect()
        }
    }

    /// Switch the active node on a `RoutingSection` selector (`PUT /proxies/sel-{id}`).
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

        let proxies_resp = self.clash_request("GET", "/proxies", None).await.ok();
        let selector_names =
            Self::clash_selector_candidates(section_id, &balancer_refs, proxies_resp.as_ref());

        let payload = json!({ "name": node_tag }).to_string();
        let proxies_map = proxies_resp
            .as_ref()
            .and_then(|v| v.get("proxies"))
            .and_then(Value::as_object);
        let mut updated_any = false;
        for selector_name in &selector_names {
            if let Some(map) = proxies_map
                && let Some(all_arr) = map
                    .get(selector_name)
                    .and_then(|entry| entry.get("all"))
                    .and_then(Value::as_array)
                && !all_arr
                    .iter()
                    .filter_map(Value::as_str)
                    .any(|cand| cand == node_tag)
            {
                continue;
            }
            let encoded = crate::store::url_encode_component(selector_name);
            if self
                .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&payload))
                .await
                .is_ok()
            {
                Self::save_selector_choice(selector_name, node_tag);
                updated_any = true;
            }
        }
        if !updated_any {
            Self::save_selector_choice(&format!("sel-{section_id}"), node_tag);
        }
        Ok(())
    }
}

struct WarpProvisioned {
    payload: Value,
    access_token: String,
    endpoint: String,
    server: String,
    server_port: u16,
    private_key: String,
    peer_public_key: String,
    dev_id: String,
    ipv4: String,
    ipv6: String,
    reserved_csv: String,
}

fn split_host_port_with_default(raw: &str, default_port: u16) -> (String, u16) {
    let trimmed = raw.trim();
    if let Some(rest) = trimmed.strip_prefix('[')
        && let Some((host, port_part)) = rest.split_once("]:")
        && let Ok(port) = port_part.parse::<u16>()
    {
        return (host.to_string(), port);
    }
    if trimmed.matches(':').count() == 1
        && let Some((host, port_part)) = trimmed.split_once(':')
        && let Ok(port) = port_part.parse::<u16>()
    {
        return (host.to_string(), port);
    }
    (trimmed.trim_matches(['[', ']']).to_string(), default_port)
}

impl CoreManager {
    async fn provision_warp_internal(&self) -> anyhow::Result<WarpProvisioned> {
        let mut kp = crypto_gen::generate_wg_keypair();
        kp.private_key.clear();
        let mut dev_id = String::new();
        let mut access_token = String::new();
        let mut ipv4 = "172.16.0.2/32".to_string();
        let mut ipv6 = String::new();
        let mut server = "engage.cloudflareclient.com".to_string();
        let mut server_port: u16 = 2408;
        let mut peer_pub = String::new();
        let mut reserved_vec: Vec<u8> = Vec::new();
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
                    kp.private_key = pk.trim().to_string();
                }
                if let Some(ppk) = wg.get("peer_public_key").and_then(Value::as_str) {
                    peer_pub = ppk.trim().to_string();
                }
                if let Some(srv) = wg.get("server").and_then(Value::as_str)
                    && !srv.trim().is_empty()
                {
                    server = srv.trim().to_string();
                }
                if let Some(port) = wg.get("server_port").and_then(Value::as_u64)
                    && let Ok(p16) = u16::try_from(port)
                {
                    server_port = p16;
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
                if let Some(res) = wg.get("reserved").and_then(Value::as_array) {
                    reserved_vec = res
                        .iter()
                        .filter_map(Value::as_u64)
                        .filter_map(|v| u8::try_from(v).ok())
                        .collect();
                }
            }
            if reserved_vec.is_empty()
                && let Some(res) = core_warp.get("reserved").and_then(Value::as_array)
            {
                reserved_vec = res
                    .iter()
                    .filter_map(Value::as_u64)
                    .filter_map(|v| u8::try_from(v).ok())
                    .collect();
            }
            if let Some(m) = core_warp.get("masque_outbound") {
                masque_outbound = m.clone();
            }
        }

        if kp.private_key.is_empty() || peer_pub.is_empty() {
            let fallback_kp = crypto_gen::generate_wg_keypair();
            let reg_body = json!({
                "key": fallback_kp.public_key,
                "install_id": "",
                "fcm_token": "",
                "tos": "2026-01-01T00:00:00.000Z",
                "model": "tachyon-router",
                "serial_number": crypto_gen::generate_hex(8),
                "locale": "en_US",
            });
            let reg_json = serde_json::to_string(&reg_body)?;
            let out = tokio::time::timeout(
                Duration::from_secs(12),
                Command::new("curl")
                    .args([
                        "--silent",
                        "--show-error",
                        "--fail",
                        "--connect-timeout",
                        "4",
                        "--max-time",
                        "10",
                        "-X",
                        "POST",
                        "-H",
                        "Content-Type: application/json",
                        "-H",
                        "User-Agent: okhttp/3.12.1",
                        "--data",
                        &reg_json,
                        "https://api.cloudflareclient.com/v0a2158/reg",
                    ])
                    .output(),
            )
            .await
            .map_err(|_| anyhow::anyhow!("Таймаут регистрации Cloudflare WARP"))??;

            if !out.status.success() {
                let err_txt = String::from_utf8_lossy(&out.stderr);
                anyhow::bail!(
                    "Не удалось зарегистрировать устройство Cloudflare WARP: {}",
                    err_txt.trim()
                );
            }
            let cf: Value = serde_json::from_slice(&out.stdout)
                .map_err(|e| anyhow::anyhow!("Некорректный ответ Cloudflare WARP API: {e}"))?;
            if let Some(id) = cf.get("id").and_then(Value::as_str) {
                dev_id = id.to_string();
            }
            if let Some(tok) = cf.get("token").and_then(Value::as_str) {
                access_token = tok.to_string();
            }
            if let Some(peer) = cf.pointer("/config/peers/0") {
                if let Some(ppk) = peer.get("public_key").and_then(Value::as_str) {
                    peer_pub = ppk.trim().to_string();
                }
                let ep_raw = peer
                    .pointer("/endpoint/host")
                    .or_else(|| peer.pointer("/endpoint/v4"))
                    .and_then(Value::as_str)
                    .unwrap_or("engage.cloudflareclient.com:2408");
                let (h, p) = split_host_port_with_default(ep_raw, 2408);
                if !h.is_empty() {
                    server = h;
                }
                if p > 0 {
                    server_port = p;
                }
            }
            if let Some(v4) = cf
                .pointer("/config/interface/addresses/v4")
                .and_then(Value::as_str)
                && !v4.trim().is_empty()
            {
                let v4t = v4.trim();
                ipv4 = if v4t.contains('/') {
                    v4t.to_string()
                } else {
                    format!("{v4t}/32")
                };
            }
            if let Some(v6) = cf
                .pointer("/config/interface/addresses/v6")
                .and_then(Value::as_str)
                && !v6.trim().is_empty()
            {
                let v6t = v6.trim();
                ipv6 = if v6t.contains('/') {
                    v6t.to_string()
                } else {
                    format!("{v6t}/128")
                };
            }
            if let Some(client_id) = cf.pointer("/config/client_id").and_then(Value::as_str)
                && let Ok(raw_bytes) = B64_STD.decode(client_id.trim())
                && raw_bytes.len() >= 3
            {
                reserved_vec = raw_bytes[..3].to_vec();
            }
            kp = fallback_kp;
        }

        if kp.private_key.is_empty() || peer_pub.is_empty() {
            anyhow::bail!(
                "Регистрация WARP не вернула обязательные ключи WireGuard (private_key / peer_public_key)"
            );
        }
        if dev_id.is_empty() {
            dev_id = format!("warp-{}", crypto_gen::generate_hex(6));
        }

        let endpoint = if server.contains(':') {
            format!("[{server}]:{server_port}")
        } else {
            format!("{server}:{server_port}")
        };
        let reserved_csv = reserved_vec
            .iter()
            .map(u8::to_string)
            .collect::<Vec<_>>()
            .join(",");

        let payload = json!({
            "ok": true,
            "success": true,
            "source_id": "warp_cf",
            "device_id": dev_id,
            "private_key": kp.private_key,
            "peer_public_key": peer_pub,
            "public_key": peer_pub,
            "client_public_key": kp.public_key,
            "server_address": server,
            "server": server,
            "server_port": server_port,
            "endpoint": endpoint,
            "local_address": ipv4,
            "ipv4": ipv4,
            "ipv6_address": ipv6,
            "ipv6": ipv6,
            "reserved": reserved_vec,
            "mtu": 1280,
            "jc": 4,
            "jmin": 40,
            "jmax": 70,
            "s1": 0,
            "s2": 0,
            "h1": 1,
            "h2": 2,
            "h3": 3,
            "h4": 4,
            "masque_outbound": masque_outbound,
        });

        Ok(WarpProvisioned {
            payload,
            access_token,
            endpoint,
            server,
            server_port,
            private_key: kp.private_key,
            peer_public_key: peer_pub,
            dev_id,
            ipv4,
            ipv6,
            reserved_csv,
        })
    }

    /// Provision Cloudflare WARP account credentials without mutating persistent router config.
    pub async fn provision_warp_credentials(&self) -> anyhow::Result<Value> {
        Ok(self.provision_warp_internal().await?.payload)
    }

    /// Register or provision a 1-click Cloudflare WARP / MASQUE `OutboundSource`,
    /// persisting `warp_cf` into the router store and triggering hot reload.
    pub async fn register_warp_source(&self) -> anyhow::Result<Value> {
        let prov = self.provision_warp_internal().await?;

        let mut candidate = self.state.data.read().await.clone();
        let warp_src = crate::store::OutboundSource {
            id: "warp_cf".to_string(),
            enabled: true,
            name: "Cloudflare WARP".to_string(),
            source_type: "warp".to_string(),
            wg_endpoint: prov.endpoint,
            wg_private_key: prov.private_key.clone(),
            wg_peer_public_key: prov.peer_public_key.clone(),
            wg_local_address: prov.ipv4.clone(),
            wg_mtu: 1280,
            warp_device_id: prov.dev_id,
            warp_access_token: prov.access_token,
            warp_ipv4: prov.ipv4,
            warp_ipv6: prov.ipv6,
            warp_private_key: prov.private_key,
            warp_peer_public_key: prov.peer_public_key,
            warp_server: prov.server,
            warp_server_port: prov.server_port,
            warp_reserved: prov.reserved_csv,
            warp_mtu: 1280,
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

        Ok(prov.payload)
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
        self.clash_request("GET", "/tachyon/flight?limit=250", None)
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
        let data_dir = crate::snapshots::data_dir_for_state(&self.state);
        let rulesets_dir_clone = rulesets_dir.clone();
        let data_dir_clone = data_dir.clone();
        let (
            rulesets_files,
            (fp_inst, fp_run, fp_pid, fp_ver),
            (torr_inst, torr_run, torr_pid, _),
            tachyon_bak,
            core_bak,
        ) = tokio::task::spawn_blocking(move || {
            let mut rulesets_files = Vec::new();
            if let Ok(rd) = std::fs::read_dir(&rulesets_dir_clone) {
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
            let fp = check_bin(
                &[
                    "/usr/bin/fptn-client-cli",
                    "/usr/bin/fptn-client",
                    "/opt/fptn/fptn-client",
                ],
                "fptn",
                &["/etc/fptn/.version"],
                "установлен",
            );
            let torr = check_bin(
                &[
                    "/usr/bin/torrserver",
                    "/opt/torrserver/torrserver",
                    "/usr/sbin/torrserver",
                ],
                "torrserver",
                &[],
                "установлен",
            );
            let tachyon_bak = crate::snapshots::read_backup_meta(&data_dir_clone, "tachyon");
            let core_bak = crate::snapshots::read_backup_meta(&data_dir_clone, "tachyon-core");
            (rulesets_files, fp, torr, tachyon_bak, core_bak)
        })
        .await
        .unwrap_or_default();
        let trs_count = rulesets_files.len();
        let core_ver_str = if core_ver.is_empty() {
            "0.4.4".to_string()
        } else {
            core_ver
        };

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
                    || crate::platform::paths()
                        .bin_dir
                        .join("tachyon-core.prev")
                        .exists()
                    || crate::platform::paths()
                        .bin_dir
                        .join("tachyon-core.bak")
                        .exists()
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
                let platform_bin = crate::platform::paths().bin_dir.join("tachyon-core");
                let core_path = if !core_bin_cfg.trim().is_empty()
                    && Path::new(core_bin_cfg.trim()).is_file()
                {
                    Path::new(core_bin_cfg.trim()).to_path_buf()
                } else if platform_bin.is_file() {
                    platform_bin
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
        let Some(_canon) = crate::updater::resolve_known_component(component) else {
            return json!({
                "ok": false,
                "job_id": "",
                "result": {
                    "ok": false,
                    "component": component,
                    "action": action,
                    "error": format!("Unsupported component: {component}")
                }
            });
        };
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
        let platform_core_bin = crate::platform::paths().bin_dir.join("tachyon-core");
        let core_bin_path =
            if !core_bin_cfg.trim().is_empty() && Path::new(core_bin_cfg.trim()).is_file() {
                Path::new(core_bin_cfg.trim()).to_path_buf()
            } else if platform_core_bin.is_file() {
                platform_core_bin
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
                candidate.settings.core_bin_path = crate::platform::paths()
                    .bin_dir
                    .join("tachyon-core")
                    .to_string_lossy()
                    .into_owned();
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
                    let _ = transaction::commit_transaction_with_source(
                        &self.state,
                        restored,
                        "rollback",
                    )
                    .await;
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
        let trimmed = raw_input.trim_start_matches('\u{feff}').trim();
        if trimmed.is_empty() {
            return json!({ "ok": false, "error": "Пустой ввод", "nodes": [], "countries": [], "protocols": [] });
        }
        let mut nodes = Vec::new();
        let mut sub_meta = crate::store::OutboundSource::default();
        let (fallback_proxy_opt, router_hwid) = {
            let d = self.state.data.read().await;
            let px = read_service_mixed_port_from_config(&d.settings.core_config_path)
                .or_else(|| {
                    d.sections
                        .iter()
                        .filter(|s| s.enabled && s.mixed_proxy_enabled && s.mixed_proxy_port > 0)
                        .map(|s| s.mixed_proxy_port)
                        .min()
                })
                .map(|p| format!("http://127.0.0.1:{p}"));
            (px, Self::compute_deterministic_router_hwid())
        };

        let unwrapped_whole = Self::unwrap_subscription_entry(trimmed);
        let is_single_http_entry = {
            let lc = unwrapped_whole.to_ascii_lowercase();
            (lc.starts_with("http://") || lc.starts_with("https://"))
                && !unwrapped_whole.contains('\n')
        };

        if !trimmed.contains('\n') && !is_single_http_entry {
            let (parsed, _) = Self::parse_subscription_payload_with_stats(&unwrapped_whole);
            nodes = parsed;
            if nodes.is_empty()
                && let Some((core_nodes, _, core_meta)) = self
                    .try_core_subscription_parse(
                        unwrapped_whole.as_bytes(),
                        "",
                        Some(&router_hwid),
                        None,
                    )
                    .await
            {
                nodes = core_nodes;
                merge_sub_source_metadata(&mut sub_meta, &core_meta);
            }
        }

        if nodes.is_empty() {
            for line in trimmed.lines() {
                let entry = Self::unwrap_subscription_entry(line);
                if entry.is_empty() {
                    continue;
                }
                let lc = entry.to_ascii_lowercase();
                if lc.starts_with("http://") || lc.starts_with("https://") {
                    let mut fetched_nodes = Vec::new();
                    let hwid_headers =
                        Self::build_subscription_request_headers(&crate::store::OutboundSource {
                            auto_hwid: true,
                            ..Default::default()
                        });
                    for ua in [
                        "tachyon-core/2.0 (compatible; sing-box 1.14.3)",
                        "Happ/4.6.2",
                        "Clash.Meta/v1.19.10",
                        "v2rayNG/1.8.29",
                        "Mihomo/1.19.16",
                    ] {
                        if let Ok(res) = self
                            .curl_fetch_detailed(
                                &entry,
                                true,
                                12,
                                None,
                                fallback_proxy_opt.as_deref(),
                                Some(ua),
                                &hwid_headers,
                                false,
                            )
                            .await
                            && res.status_code < 400
                        {
                            let (hdr, body_bytes, _) = split_http_response_bytes(&res.raw);
                            parse_subscription_headers(&hdr, &mut sub_meta);
                            let body_text = decode_text_lossy_with_bom(body_bytes);
                            parse_subscription_body_metadata(&body_text, &mut sub_meta);
                            let (mut parsed, _) =
                                Self::parse_subscription_payload_with_stats(&body_text);
                            if parsed.is_empty()
                                && let Some((core_nodes, _, core_meta)) = self
                                    .try_core_subscription_parse(
                                        body_bytes,
                                        &hdr,
                                        Some(&router_hwid),
                                        Some(&entry),
                                    )
                                    .await
                            {
                                parsed = core_nodes;
                                merge_sub_source_metadata(&mut sub_meta, &core_meta);
                            }
                            if !parsed.is_empty() {
                                fetched_nodes = parsed;
                                break;
                            }
                        }
                    }
                    if fetched_nodes.is_empty()
                        && let Some((core_nodes, _, core_meta, _)) = self
                            .try_core_subscription_fetch(
                                &entry,
                                None,
                                true,
                                Some(&router_hwid),
                                false,
                                fallback_proxy_opt.as_deref(),
                                &[],
                            )
                            .await
                    {
                        fetched_nodes = core_nodes;
                        merge_sub_source_metadata(&mut sub_meta, &core_meta);
                    }
                    for n in fetched_nodes {
                        if !nodes
                            .iter()
                            .any(|existing: &ParsedProxyNode| existing.tag == n.tag)
                        {
                            nodes.push(n);
                        }
                    }
                }
            }
        }

        if nodes.is_empty() {
            nodes = Self::parse_subscription_payload(trimmed);
            if nodes.is_empty()
                && let Some((core_nodes, _, core_meta)) = self
                    .try_core_subscription_parse(trimmed.as_bytes(), "", Some(&router_hwid), None)
                    .await
            {
                nodes = core_nodes;
                merge_sub_source_metadata(&mut sub_meta, &core_meta);
            }
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
            // Consume the immediate first tick so `tick_count = 1` runs after one full period
            // rather than duplicating the startup `poll_telemetry_and_reconcile(0)` call.
            interval.tick().await;
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
        let mut promoted_rev_id = String::new();
        {
            let mut live = self.state.live.write().await;
            live.core_running = core_alive;
            live.core_pid = pid_opt;
            live.core_uptime_secs = uptime_secs;
            live.core_rss_bytes = rss_bytes;

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

            if should_tick_lkg_promotion(&live, core_alive, self.is_manually_stopped()) {
                live.lkg_remaining_secs = live.lkg_remaining_secs.saturating_sub(3);
                if live.lkg_remaining_secs == 0 {
                    live.lkg_observing = false;
                    promote_lkg = true;
                    promoted_rev_id = live.active_revision_id.clone();
                }
            }
        }

        if promote_lkg {
            let promoted_ok = {
                let d = self.state.data.read().await;
                transaction::promote_to_known_good(&self.state.lkg_path, &d).is_ok()
            };
            if promoted_ok {
                let target_opt = if promoted_rev_id.trim().is_empty() {
                    None
                } else {
                    Some(promoted_rev_id.as_str())
                };
                let _ = crate::config_history::mark_revision_status(
                    target_opt,
                    "working",
                    "Проверен и подтверждён (LKG)",
                );
                let mut live = self.state.live.write().await;
                live.last_auto_rollback_reason.clear();
                live.last_auto_rollback_ts = 0;
                live.push_event(
                    "info",
                    "known_good",
                    "Promoted stable configuration to Last Known Good snapshot",
                );
            }
        }

        // Every 5 ticks (15s), run Reconciler checks (`nftables` drift & adaptive LAN devices refresh via `/tachyon/devices`)
        if tick_count.is_multiple_of(5) {
            let nft_ok = net_stack::check_nft_table_active().await;

            let devices_opt = if telemetry_active && !data_plane_busy {
                let mut devices = sys_info::discover_lan_devices_async().await;
                let default_lan_iface = crate::platform::detect_default_lan_iface();
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
                                    .unwrap_or(default_lan_iface.as_str())
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
            if !core_alive && prev_core_pid.is_some() && !self.is_manually_stopped() {
                let d_snap = self.state.data.read().await.clone();
                let _ = net_stack::hold_kill_switch(&d_snap).await;
            }
            crate::watchdog::check_and_repair_nft_drift_boxed(
                &self.state,
                watchdog_on && !self.is_manually_stopped(),
                core_alive,
                &proxy_mode,
                nft_ok,
            )
            .await;
            crate::watchdog::run_watchdog_tick_boxed(self, core_alive, tick_count).await;
            if core_alive && uptime_secs >= 60 {
                self.boot_recovery_attempts.store(0, Ordering::Release);
            } else if crate::ubus_bridge::is_daemon_mode()
                && !watchdog_on
                && !core_alive
                && !self.is_manually_stopped()
            {
                let bin_path = self.resolve_bin_path().await;
                if Path::new(&bin_path).exists() {
                    let attempts = self.boot_recovery_attempts.load(Ordering::Acquire);
                    let now_u64 = crate::store::unix_now_u64();
                    let last_try = self.last_boot_recovery_ts.load(Ordering::Acquire);
                    if attempts < 5 && now_u64.saturating_sub(last_try) >= 30 {
                        self.last_boot_recovery_ts.store(now_u64, Ordering::Release);
                        self.boot_recovery_attempts
                            .store(attempts.saturating_add(1), Ordering::Release);
                        self.state.live.write().await.push_event(
                            "warn",
                            "core_mgr",
                            &format!(
                                "tachyon-core не запущен; попытка автовосстановления {}/5",
                                attempts + 1
                            ),
                        );
                        let _ = Box::pin(self.start()).await;
                    }
                }
            }
            if watchdog_on
                && !self.is_manually_stopped()
                && core_alive
                && tick_count.is_multiple_of(20)
            {
                let wan6 = crate::store::probe_wan6_runtime_state();
                let drifted_state = {
                    let store_guard = self.state.data.read().await;
                    let ipv6_state = crate::store::resolve_effective_ipv6_state(
                        &store_guard.settings,
                        wan6.wan6_available,
                    );
                    let cfg_path =
                        Self::effective_core_config_path_for(&self.state, &store_guard.settings);
                    if !Self::core_config_ipv6_matches(&cfg_path, &store_guard, ipv6_state) {
                        Some(ipv6_state)
                    } else {
                        None
                    }
                };
                if let Some(ipv6_state) = drifted_state {
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
                        let _ = self.apply_or_reload_boxed().await;
                    }
                }
            }
        }
    }

    #[inline(never)]
    fn apply_or_reload_boxed(
        &self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
        Box::pin(self.apply_or_reload())
    }
}

fn encode_query_component(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn merge_sub_source_metadata(
    dst: &mut crate::store::OutboundSource,
    meta: &crate::store::OutboundSource,
) {
    if dst.sub_title.trim().is_empty() && !meta.sub_title.trim().is_empty() {
        dst.sub_title = meta.sub_title.clone();
    }
    if dst.sub_support_url.trim().is_empty() && !meta.sub_support_url.trim().is_empty() {
        dst.sub_support_url = meta.sub_support_url.clone();
    }
    if dst.sub_web_page_url.trim().is_empty() && !meta.sub_web_page_url.trim().is_empty() {
        dst.sub_web_page_url = meta.sub_web_page_url.clone();
    }
    if dst.sub_announce.trim().is_empty() && !meta.sub_announce.trim().is_empty() {
        dst.sub_announce = meta.sub_announce.clone();
    }
    if dst.sub_upload_bytes == 0 && meta.sub_upload_bytes > 0 {
        dst.sub_upload_bytes = meta.sub_upload_bytes;
    }
    if dst.sub_download_bytes == 0 && meta.sub_download_bytes > 0 {
        dst.sub_download_bytes = meta.sub_download_bytes;
    }
    if dst.sub_total_bytes == 0 && meta.sub_total_bytes > 0 {
        dst.sub_total_bytes = meta.sub_total_bytes;
    }
    if dst.sub_expire_unix == 0 && meta.sub_expire_unix > 0 {
        dst.sub_expire_unix = meta.sub_expire_unix;
    }
    if dst.subscription_update_interval.trim().is_empty()
        && !meta.subscription_update_interval.trim().is_empty()
    {
        dst.subscription_update_interval = meta.subscription_update_interval.clone();
    }
}

pub(crate) struct CurlFetchResult {
    pub status_code: u16,
    pub raw: Vec<u8>,
}

pub(crate) struct CurlFetchError {
    #[allow(dead_code)]
    pub exit_code: Option<i32>,
    pub ua_retryable: bool,
    pub message: String,
}

fn decode_base64_flex_bytes(input: &str) -> Option<Vec<u8>> {
    let mut normalized = String::with_capacity(input.len());
    for ch in input.chars() {
        if ch.is_ascii_whitespace() || ch == '=' {
            continue;
        }
        match ch {
            '-' => normalized.push('+'),
            '_' => normalized.push('/'),
            c if c.is_ascii_alphanumeric() || c == '+' || c == '/' => normalized.push(c),
            _ => return None,
        }
    }
    if normalized.is_empty() || normalized.len() % 4 == 1 {
        return None;
    }
    while !normalized.len().is_multiple_of(4) {
        normalized.push('=');
    }
    B64_STD.decode(&normalized).ok()
}

fn decode_text_lossy_with_bom(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xFF, 0xFE]) {
        let u16s: Vec<u16> = bytes[2..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes(*c))
            .collect();
        return String::from_utf16_lossy(&u16s);
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        let u16s: Vec<u16> = bytes[2..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_be_bytes(*c))
            .collect();
        return String::from_utf16_lossy(&u16s);
    }
    let body = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    String::from_utf8_lossy(body).into_owned()
}

fn strip_subscription_comment_wrapper(raw: &str) -> &str {
    let mut s = raw.trim_start_matches('\u{feff}').trim();
    for _ in 0..64 {
        if let Some(nl) = s.find('\n') {
            let line = s[..nl].trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
                s = s[nl + 1..].trim_start();
                continue;
            }
        }
        break;
    }
    for _ in 0..32 {
        if let Some(nl) = s.rfind('\n') {
            let line = s[nl + 1..].trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
                s = s[..nl].trim_end();
                continue;
            }
        }
        break;
    }
    s.trim()
}

fn looks_like_wireguard_ini_payload(raw: &str) -> bool {
    let mut has_iface = false;
    let mut has_peer = false;
    for line in raw.lines().take(200) {
        let t = line.trim();
        if t.eq_ignore_ascii_case("[interface]") {
            has_iface = true;
        } else if t.eq_ignore_ascii_case("[peer]") {
            has_peer = true;
        }
        if has_iface && has_peer {
            return true;
        }
    }
    false
}

fn extract_http_header_value(headers: &str, name: &str) -> Option<String> {
    for line in headers.lines() {
        if let Some((k, v)) = line.split_once(':')
            && k.trim().eq_ignore_ascii_case(name)
        {
            let val = v.trim();
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

fn parse_subscription_body_metadata(raw: &str, src: &mut crate::store::OutboundSource) {
    let mut header_lines = Vec::new();
    for line in raw.trim_start_matches('\u{feff}').lines().take(32) {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if let Some(rest) = t.strip_prefix('#').or_else(|| t.strip_prefix("//")) {
            let r = rest.trim();
            if r.contains(':') {
                header_lines.push(r.to_string());
            }
        } else {
            break;
        }
    }
    if !header_lines.is_empty() {
        parse_subscription_headers(&header_lines.join("\n"), src);
    }
}

fn split_http_response_bytes(raw: &[u8]) -> (String, &[u8], u16) {
    let mut rest = raw;
    let mut last_headers: &[u8] = &[];
    let find_subslice = |hay: &[u8], needle: &[u8]| -> Option<usize> {
        hay.windows(needle.len()).position(|w| w == needle)
    };
    while let Some(pos) = find_subslice(rest, b"\r\n\r\n") {
        let hdr = &rest[..pos];
        if hdr.starts_with(b"HTTP/") {
            last_headers = hdr;
            rest = &rest[pos + 4..];
        } else {
            break;
        }
    }
    if last_headers.is_empty() {
        while let Some(pos) = find_subslice(rest, b"\n\n") {
            let hdr = &rest[..pos];
            if hdr.starts_with(b"HTTP/") {
                last_headers = hdr;
                rest = &rest[pos + 2..];
            } else {
                break;
            }
        }
    }
    let hdr_str = String::from_utf8_lossy(last_headers).into_owned();
    let status_code = hdr_str
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .unwrap_or(0);
    (hdr_str, rest, status_code)
}

#[cfg(test)]
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
    if last_headers.is_empty() {
        while let Some((hdr, after)) = rest.split_once("\n\n") {
            if hdr.starts_with("HTTP/") {
                last_headers = hdr;
                rest = after;
            } else {
                break;
            }
        }
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
            "profile-update-interval" if src.subscription_update_interval.trim().is_empty() => {
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

fn headers_indicate_hwid_not_supported(headers: &str) -> bool {
    for line in headers.lines() {
        if let Some((name, val)) = line.split_once(':')
            && name.trim().eq_ignore_ascii_case("x-hwid-not-supported")
            && matches!(
                val.trim().to_ascii_lowercase().as_str(),
                "true" | "1" | "yes"
            )
        {
            return true;
        }
    }
    false
}

fn pick_best_subscription_ua_candidate_index(candidates: &[(usize, usize)]) -> Option<usize> {
    let mut best_clean: Option<(usize, usize)> = None;
    let mut best_any: Option<(usize, usize)> = None;
    for (idx, &(count, dropped_stubs)) in candidates.iter().enumerate() {
        if count == 0 {
            continue;
        }
        if dropped_stubs == 0 && best_clean.is_none_or(|(_, b)| count > b) {
            best_clean = Some((idx, count));
        }
        if best_any.is_none_or(|(_, b)| count > b) {
            best_any = Some((idx, count));
        }
    }
    best_clean.or(best_any).map(|(idx, _)| idx)
}

#[cfg(test)]
fn pick_best_subscription_ua_index(counts: &[usize]) -> Option<usize> {
    let pairs: Vec<(usize, usize)> = counts.iter().map(|&count| (count, 0)).collect();
    pick_best_subscription_ua_candidate_index(&pairs)
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

/// Strip volatile `tls.reality.short_id` rotation and dynamic traffic/expiry telemetry
/// from node tags before comparing fetched subscription nodes against cached nodes,
/// avoiding pointless core hot-reloads that drop active client connections.
fn canonical_node_fingerprint(node: &crate::store::ParsedProxyNode) -> Value {
    let clean_tag = config_gen::strip_dynamic_server_telemetry(&node.tag);
    let mut obj = node.outbound_json.clone();
    if let Some(map) = obj.as_object_mut() {
        if let Some(raw_t) = map.get("tag").and_then(Value::as_str) {
            let cleaned = config_gen::strip_dynamic_server_telemetry(raw_t);
            map.insert("tag".to_string(), json!(cleaned));
        }
        if let Some(reality) = map
            .get_mut("tls")
            .and_then(|v| v.get_mut("reality"))
            .and_then(Value::as_object_mut)
        {
            reality.remove("short_id");
        }
    }
    json!({
        "tag": clean_tag,
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
    let mut old_fps: Vec<String> = old_nodes
        .iter()
        .map(|n| canonical_node_fingerprint(n).to_string())
        .collect();
    let mut new_fps: Vec<String> = new_nodes
        .iter()
        .map(|n| canonical_node_fingerprint(n).to_string())
        .collect();
    old_fps.sort_unstable();
    new_fps.sort_unstable();
    old_fps == new_fps
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

fn should_tick_lkg_promotion(
    live: &crate::store::LiveTelemetry,
    core_alive: bool,
    manually_stopped: bool,
) -> bool {
    live.lkg_observing
        && core_alive
        && !manually_stopped
        && live.core_fail_streak == 0
        && live.dns_fail_streak == 0
        && !live.safe_minimal_active
        && !live.config_drift
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
    if trimmed.is_empty()
        || matches!(
            trimmed.as_str(),
            "0" | "0s" | "0m" | "0h" | "0d" | "off" | "disabled" | "none" | "never"
        )
    {
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
        if bare == 0 {
            return 6 * 3600;
        }
        let secs = if bare < 200 {
            bare.saturating_mul(3600)
        } else {
            bare
        };
        return secs.max(300);
    };
    let n = num_str.trim().parse::<u64>().unwrap_or(6);
    if n == 0 {
        return 6 * 3600;
    }
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
        Box::pin(mgr.poll_telemetry_and_reconcile(5)).await;
        assert_eq!(mock.conn_hits.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert_eq!(mock.dev_hits.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(state.live.read().await.core_running);

        // 2. UI active: tick 5 establishes baseline without division by hardcoded 3.
        state.touch_telemetry_access();
        Box::pin(mgr.poll_telemetry_and_reconcile(5)).await;
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
        Box::pin(mgr.poll_telemetry_and_reconcile(6)).await;
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
        Box::pin(mgr.poll_telemetry_and_reconcile(10)).await;
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
        Box::pin(mgr.poll_telemetry_and_reconcile(11)).await;
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
        Box::pin(mgr.poll_telemetry_and_reconcile(12)).await;
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
                Box::pin(mgr.apply_or_reload()),
                Box::pin(mgr.apply_or_reload()),
                Box::pin(mgr.apply_or_reload()),
                Box::pin(mgr.apply_or_reload()),
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
        let res_stopped =
            tokio::time::timeout(Duration::from_secs(3), Box::pin(mgr.apply_or_reload()))
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
            tokio::join!(
                Box::pin(mgr.apply_or_reload()),
                Box::pin(mgr.apply_or_reload()),
            )
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
        use base64::engine::general_purpose::STANDARD_NO_PAD as B64_STD_NO_PAD;
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

    #[test]
    fn test_subscription_zero_interval_loopback_filter_and_telemetry_diff() {
        // Zero / disabled intervals must fall back to 6h instead of clamping to 5m (300s).
        assert_eq!(parse_subscription_interval_secs("0"), 6 * 3600);
        assert_eq!(parse_subscription_interval_secs("0h"), 6 * 3600);
        assert_eq!(parse_subscription_interval_secs("0m"), 6 * 3600);
        assert_eq!(parse_subscription_interval_secs("off"), 6 * 3600);

        // User-defined interval must not be overwritten by provider Profile-Update-Interval header.
        let mut src = crate::store::OutboundSource {
            subscription_update_interval: "6h".to_string(),
            ..Default::default()
        };
        parse_subscription_headers("Profile-Update-Interval: 1\r\n", &mut src);
        assert_eq!(src.subscription_update_interval, "6h");
        src.subscription_update_interval.clear();
        parse_subscription_headers("Profile-Update-Interval: 4\r\n", &mut src);
        assert_eq!(src.subscription_update_interval, "4h");

        // Loopback/unspecified banner pseudo-nodes must be dropped from remote subscriptions.
        let payload = concat!(
            "vless://11111111-1111-4111-8111-111111111111@127.0.0.1:443#Remaining%2015GB\n",
            "vless://11111111-1111-4111-8111-111111111111@0.0.0.0:80#Expire%2020d\n",
            "vless://11111111-1111-4111-8111-111111111111@198.51.100.10:443#DE%20Frankfurt%20%5B15d%20%7C%2010GB%5D\n",
            "vless://11111111-1111-4111-8111-111111111111@198.51.100.11:443#FI%20Helsinki\n",
        );
        let parsed = CoreManager::parse_subscription_payload(payload);
        assert_eq!(parsed.len(), 2);
        assert!(
            parsed
                .iter()
                .all(|n| n.server != "127.0.0.1" && n.server != "0.0.0.0")
        );

        // Dynamic telemetry suffix changes or shuffled order must not trigger core hot-reload.
        let payload_reordered = concat!(
            "vless://11111111-1111-4111-8111-111111111111@198.51.100.11:443#FI%20Helsinki\n",
            "vless://11111111-1111-4111-8111-111111111111@198.51.100.10:443#DE%20Frankfurt%20%5B14d%20%7C%209.5GB%5D\n",
        );
        let parsed_reordered = CoreManager::parse_subscription_payload(payload_reordered);
        assert!(nodes_materially_equal(&parsed, &parsed_reordered));
    }

    #[tokio::test]
    async fn test_auto_rollback_marks_failed_revision_and_restores_working_config() {
        #[inline(never)]
        fn clone_store_boxed(
            src: &crate::store::RouterStoreData,
        ) -> Box<crate::store::RouterStoreData> {
            Box::new(src.clone())
        }

        Box::pin(async move {
            let dir = std::env::temp_dir().join(format!("tachyon_auto_rb_{}", std::process::id()));
            let hist_dir = dir.join("history");
            let _ = std::fs::remove_dir_all(&dir);
            let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
            let mgr = CoreManager::new(Arc::clone(&state));
            mgr.set_manual_stop(true);

            // Commit a working configuration (tun_mtu = 1420) and mark it working.
            let mut s1 = {
                let guard = state.data.read().await;
                clone_store_boxed(&guard)
            };
            s1.settings.tun_mtu = 1420;
            transaction::commit_transaction_boxed_in_history_dir(
                &state,
                s1,
                "save",
                Some(hist_dir.clone()),
            )
            .await
            .expect("commit s1");
            let rev1_id = state.live.read().await.active_revision_id.clone();
            assert!(!rev1_id.is_empty());
            crate::config_history::mark_revision_status_in(
                &hist_dir,
                Some(&rev1_id),
                "working",
                "Проверен",
            )
            .expect("mark rev1 working");

            // Commit a faulty configuration (tun_mtu = 1360) with distinct source to avoid 3s coalescing.
            let mut s2 = {
                let guard = state.data.read().await;
                clone_store_boxed(&guard)
            };
            s2.settings.tun_mtu = 1360;
            transaction::commit_transaction_boxed_in_history_dir(
                &state,
                s2,
                "rollback",
                Some(hist_dir.clone()),
            )
            .await
            .expect("commit s2");
            let rev2_id = state.live.read().await.active_revision_id.clone();
            assert_ne!(rev2_id, rev1_id);
            assert_eq!(state.data.read().await.settings.tun_mtu, 1360);

            let ok = mgr
                .auto_rollback_to_working_config("Сбой проверки конфига", Some(hist_dir.clone()))
                .await
                .expect("auto rollback succeeds");
            assert!(ok);
            assert_eq!(state.data.read().await.settings.tun_mtu, 1420);
            {
                let live = state.live.read().await;
                assert!(!live.lkg_observing);
                assert_eq!(live.last_auto_rollback_reason, "Сбой проверки конфига");
            }

            let list = crate::config_history::list_revisions_in(&hist_dir);
            let failed_rev = list.iter().find(|r| r.id == rev2_id).unwrap();
            assert_eq!(failed_rev.status, "failed");
            assert_eq!(failed_rev.status_reason, "Сбой проверки конфига");

            let rb_rev = list
                .iter()
                .find(|r| r.source == "auto_rollback")
                .expect("auto_rollback revision recorded");
            assert_eq!(rb_rev.status, "working");

            let _ = std::fs::remove_dir_all(&dir);
        })
        .await;
    }

    #[test]
    fn test_subscription_hwid_headers_and_auto_ua_max_node_selection() {
        let mut src = crate::store::OutboundSource {
            id: "sub_test".to_string(),
            source_type: "subscription".to_string(),
            auto_hwid: true,
            ..Default::default()
        };
        let headers = CoreManager::build_subscription_request_headers(&src);
        assert!(headers.iter().any(|(k, v)| k == "x-hwid" && !v.is_empty()));
        assert!(headers.iter().any(|(k, _)| k == "x-device-os"));
        assert!(headers.iter().any(|(k, _)| k == "x-ver-os"));
        assert!(headers.iter().any(|(k, _)| k == "x-device-model"));

        src.hwid = "custom-router-hwid-42".to_string();
        let headers2 = CoreManager::build_subscription_request_headers(&src);
        assert!(
            headers2
                .iter()
                .any(|(k, v)| k == "x-hwid" && v == "custom-router-hwid-42")
        );

        assert_eq!(CoreManager::normalize_subscription_user_agent("auto"), "");
        assert_eq!(
            CoreManager::normalize_subscription_user_agent("happ"),
            "Happ/4.6.2"
        );
        assert_eq!(
            CoreManager::normalize_subscription_user_agent("v2rayng"),
            "v2rayNG/2.3.15"
        );
        assert!(headers_indicate_hwid_not_supported(
            "HTTP/1.1 200 OK\r\nX-Hwid-Not-Supported: true\r\n"
        ));
        assert!(!headers_indicate_hwid_not_supported("HTTP/1.1 200 OK\r\n"));

        // Picks the User-Agent returning the largest node count (ties broken by earliest index)
        assert_eq!(
            pick_best_subscription_ua_index(&[0, 12, 39, 39, 5]),
            Some(2)
        );
        assert_eq!(pick_best_subscription_ua_index(&[0, 0, 0]), None);
        assert_eq!(
            pick_best_subscription_ua_candidate_index(&[(43, 12), (20, 0)]),
            Some(1)
        );
        assert_eq!(
            pick_best_subscription_ua_candidate_index(&[(5, 2), (10, 1)]),
            Some(1)
        );

        let mixed_sub = concat!(
            "vless://11111111-1111-4111-8111-111111111111@super-auto.invalid:4659?security=tls#Stub\n",
            "vless://11111111-1111-4111-8111-111111111111@127.0.0.1:443?security=tls#TrafficBanner\n",
            "vless://11111111-1111-4111-8111-111111111111@real.example.org:443?security=tls#RealNode\n",
        );
        let (parsed_nodes, invalid_stubs) =
            CoreManager::parse_subscription_payload_with_stats(mixed_sub);
        assert_eq!(parsed_nodes.len(), 1);
        assert_eq!(parsed_nodes[0].server, "real.example.org");
        assert_eq!(invalid_stubs, 1);

        assert!(CoreManager::is_happ_versioned_user_agent("Happ/4.6.2"));
        assert!(!CoreManager::is_happ_versioned_user_agent("Happ"));
        assert!(!CoreManager::is_happ_versioned_user_agent(
            "tachyon-core/2.0"
        ));
    }

    #[test]
    fn test_custom_local_rulesets_validation_and_sanitize_preservation() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_custom_rs_test_{}",
            crypto_gen::generate_hex(4)
        ));
        std::fs::create_dir_all(&dir).unwrap();

        let valid_json_path = dir.join("media.json");
        std::fs::write(
            &valid_json_path,
            r#"{"version":3,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}"#,
        )
        .unwrap();

        let custom_trs_path = dir.join("user-custom.trs");
        std::fs::write(&custom_trs_path, b"not-a-valid-trs-header").unwrap();

        let bad_json_path = dir.join("broken.json");
        std::fs::write(&bad_json_path, b"{not valid json").unwrap();

        let missing_path = dir.join("does-not-exist.json");

        let mut preserve_cfg = json!({
            "route": {
                "rule_set": [
                    {
                        "tag": "custom-local-user-custom-1234567890ab",
                        "type": "local",
                        "format": "binary",
                        "path": custom_trs_path.to_string_lossy()
                    },
                    {
                        "tag": "custom-local-media-1234567890ab",
                        "type": "local",
                        "format": "source",
                        "path": valid_json_path.to_string_lossy()
                    }
                ]
            }
        });
        CoreManager::sanitize_candidate_local_rulesets(&mut preserve_cfg);
        assert!(
            custom_trs_path.exists(),
            "custom .trs must never be removed"
        );
        assert_eq!(
            preserve_cfg["route"]["rule_set"][0]["path"],
            json!(custom_trs_path.to_string_lossy())
        );

        let ok_cfg = json!({
            "route": {
                "rule_set": [{
                    "tag": "custom-local-media-1234567890ab",
                    "type": "local",
                    "format": "source",
                    "path": valid_json_path.to_string_lossy()
                }]
            }
        });
        assert!(CoreManager::validate_custom_local_rulesets(&ok_cfg).is_ok());

        let missing_cfg = json!({
            "route": {
                "rule_set": [{
                    "tag": "custom-local-missing-1234567890ab",
                    "type": "local",
                    "format": "source",
                    "path": missing_path.to_string_lossy()
                }]
            }
        });
        assert!(CoreManager::validate_custom_local_rulesets(&missing_cfg).is_err());

        let broken_cfg = json!({
            "route": {
                "rule_set": [{
                    "tag": "custom-local-broken-1234567890ab",
                    "type": "local",
                    "format": "source",
                    "path": bad_json_path.to_string_lossy()
                }]
            }
        });
        assert!(CoreManager::validate_custom_local_rulesets(&broken_cfg).is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_quarantine_isolates_bad_outbound_and_keeps_siblings() {
        let mut store = crate::store::RouterStoreData::default();
        store.sections.push(crate::store::RoutingSection {
            id: "broken_sec".to_string(),
            label: "Broken".to_string(),
            enabled: true,
            ..Default::default()
        });
        store.sections.push(crate::store::RoutingSection {
            id: "good_sec".to_string(),
            label: "Healthy".to_string(),
            enabled: true,
            ..Default::default()
        });

        let initial_cfg = json!({
            "dns": {
                "servers": [
                    { "type": "udp", "tag": "dns-bootstrap", "server": "77.88.8.8", "server_port": 53 },
                    { "type": "udp", "tag": "dns-remote", "server": "1.1.1.1", "server_port": 53 }
                ],
                "final": "dns-remote"
            },
            "outbounds": [
                { "type": "direct", "tag": "direct" },
                { "type": "vless", "tag": "bad-leaf-1", "server": "bad.example", "server_port": 443 },
                { "type": "vless", "tag": "good-leaf-1", "server": "good.example", "server_port": 443 },
                { "type": "selector", "tag": "sec-broken_sec-out", "outbounds": ["bad-leaf-1"] },
                { "type": "selector", "tag": "sec-good_sec-out", "outbounds": ["good-leaf-1"] }
            ],
            "route": {
                "rules": [
                    { "domain_suffix": ["broken.example"], "outbound": "sec-broken_sec-out" },
                    { "domain_suffix": ["good.example"], "outbound": "sec-good_sec-out" }
                ],
                "final": "direct"
            }
        });

        let (prepared, errs) =
            CoreManager::quarantine_with_checker(&store, initial_cfg, BTreeMap::new(), |cfg| {
                let obs = cfg["outbounds"].as_array().unwrap();
                for (i, ob) in obs.iter().enumerate() {
                    if ob["tag"].as_str() == Some("bad-leaf-1") {
                        return Err(format!("outbounds[{i}]: invalid vless uuid"));
                    }
                }
                Ok(())
            });

        assert!(errs.contains_key("broken_sec"), "errs={errs:?}");
        assert!(!errs.contains_key("good_sec"), "errs={errs:?}");
        assert!(!errs.contains_key("_core_runtime"), "errs={errs:?}");
        let obs = prepared["outbounds"].as_array().unwrap();
        assert!(!obs.iter().any(|o| o["tag"] == "bad-leaf-1"));
        assert!(!obs.iter().any(|o| o["tag"] == "sec-broken_sec-out"));
        assert!(obs.iter().any(|o| o["tag"] == "sec-good_sec-out"));
        let rules = prepared["route"]["rules"].as_array().unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0]["outbound"], json!("sec-good_sec-out"));
    }

    #[test]
    fn test_quarantine_falls_back_to_safe_dns_on_bad_dns() {
        let store = crate::store::RouterStoreData::default();
        let initial_cfg = json!({
            "dns": {
                "servers": [
                    { "type": "https", "tag": "dns-remote", "server": "invalid host", "detour": "broken-sec" }
                ],
                "final": "dns-remote"
            },
            "outbounds": [
                { "type": "direct", "tag": "direct" },
                { "type": "block", "tag": "block" }
            ],
            "route": {
                "rules": [{ "inbound": ["dns-in"], "action": "hijack-dns" }],
                "final": "direct",
                "default_domain_resolver": "dns-remote"
            }
        });

        let (prepared, errs) =
            CoreManager::quarantine_with_checker(&store, initial_cfg, BTreeMap::new(), |cfg| {
                let first_tag = cfg["dns"]["servers"][0]["tag"].as_str().unwrap_or("");
                if first_tag == "dns-remote" {
                    return Err("config: dns.servers[0]: missing host".to_string());
                }
                Ok(())
            });

        assert!(errs.contains_key("_dns"), "errs={errs:?}");
        assert!(!errs.contains_key("_core_runtime"), "errs={errs:?}");
        let servers = prepared["dns"]["servers"].as_array().unwrap();
        assert!(
            servers
                .iter()
                .any(|s| s["tag"] == "dns-bootstrap" && s["server"] == "77.88.8.8")
        );
        assert_eq!(
            prepared["route"]["default_domain_resolver"],
            json!("dns-remote")
        );
    }

    #[test]
    fn test_quarantine_strips_unknown_fields_and_broken_custom_ruleset() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_quarantine_rs_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let bad_rs_path = dir.join("broken_custom.json");
        std::fs::write(&bad_rs_path, "{ not json").unwrap();

        let mut store = crate::store::RouterStoreData::default();
        store.sections.push(crate::store::RoutingSection {
            id: "media".to_string(),
            label: "Media".to_string(),
            enabled: true,
            ..Default::default()
        });

        let initial_cfg = json!({
            "outbounds": [
                { "type": "direct", "tag": "direct" },
                { "type": "vless", "tag": "node-1", "tcp_profile": "legacy_bad" },
                { "type": "selector", "tag": "sec-media-out", "outbounds": ["node-1"] }
            ],
            "route": {
                "rule_set": [{
                    "tag": "custom-local-media-1",
                    "type": "local",
                    "format": "source",
                    "path": bad_rs_path.to_string_lossy()
                }],
                "rules": [{
                    "rule_set": ["custom-local-media-1"],
                    "outbound": "sec-media-out"
                }]
            }
        });

        let (prepared, errs) =
            CoreManager::quarantine_with_checker(&store, initial_cfg, BTreeMap::new(), |cfg| {
                if cfg["outbounds"][1].get("tcp_profile").is_some() {
                    return Err("outbounds[1]: json: unknown field \"tcp_profile\"".to_string());
                }
                Ok(())
            });

        assert!(
            prepared["outbounds"][1].get("tcp_profile").is_none(),
            "tcp_profile must be silently stripped"
        );
        assert!(
            errs.contains_key("media"),
            "broken custom local rule_set must be reported against referencing section: {errs:?}"
        );
        assert_eq!(prepared["route"]["rule_set"][0]["format"], json!("source"));
        let stub_path = prepared["route"]["rule_set"][0]["path"].as_str().unwrap();
        let stub_body = std::fs::read_to_string(stub_path).unwrap();
        assert!(stub_body.contains("\"rules\":[]"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_quarantine_falls_back_to_safe_minimal_on_irrecoverable_error() {
        let store = crate::store::RouterStoreData::default();
        let bad_cfg = json!({
            "dns": { "servers": [] },
            "inbounds": [{ "type": "tproxy", "tag": "tproxy-in", "listen": "::", "listen_port": 1602 }],
            "outbounds": [{ "type": "direct", "tag": "direct" }],
            "route": { "rules": [] }
        });

        let (prepared, errs) =
            CoreManager::quarantine_with_checker(&store, bad_cfg, BTreeMap::new(), |cfg| {
                if cfg["dns"]["servers"].as_array().unwrap().len() >= 2 {
                    Ok(())
                } else {
                    Err("fatal experimental error: corrupted store invariant".to_string())
                }
            });

        assert!(errs.contains_key("_core_runtime"), "errs={errs:?}");
        assert_eq!(prepared["route"]["final"], json!("direct"));
        assert_eq!(
            prepared["route"]["default_domain_resolver"],
            json!("dns-remote")
        );
        assert!(prepared["dns"]["servers"].as_array().unwrap().len() >= 3);
        assert!(prepared["experimental"]["clash_api"].is_object());
    }

    #[test]
    fn test_section_errors_persistence_write_read_and_clear() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_sec_err_persist_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let err_path = dir.join("section-errors.json");

        let mut map = BTreeMap::new();
        map.insert("_dns".to_string(), "DNS fallback active".to_string());
        map.insert("youtube".to_string(), "Bad key".to_string());
        CoreManager::write_section_errors_to(&err_path, &map);

        let loaded = CoreManager::read_section_errors_from(&err_path);
        assert_eq!(
            loaded.get("_dns").map(String::as_str),
            Some("DNS fallback active")
        );
        assert_eq!(loaded.get("youtube").map(String::as_str), Some("Bad key"));

        CoreManager::write_section_errors_to(&err_path, &BTreeMap::new());
        assert!(CoreManager::read_section_errors_from(&err_path).is_empty());
        assert!(!err_path.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_resolve_subscription_target_ids_isolates_single_source_and_missing_sentinel() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources = ["src_a", "src_b", "src_c"]
            .into_iter()
            .map(|id| crate::store::OutboundSource {
                id: id.to_string(),
                source_type: "subscription".to_string(),
                ..Default::default()
            })
            .collect();
        store.sections.push(crate::store::RoutingSection {
            id: "Main".to_string(),
            outbound_source_refs: vec![
                "src_a".to_string(),
                "src_b".to_string(),
                "src_c".to_string(),
            ],
            ..Default::default()
        });

        let single = resolve_subscription_target_ids(&store, "src_b").expect("single target set");
        assert_eq!(single.len(), 1);
        assert!(single.contains("src_b"));
        assert!(!single.contains("src_a"));
        assert!(!single.contains("src_c"));

        let missing = resolve_subscription_target_ids(&store, "__missing_subscription_index__:99")
            .expect("missing sentinel must stay non-all");
        assert_eq!(missing.len(), 1);
        assert!(missing.contains("__missing_subscription_index__:99"));
        assert!(
            store
                .outbound_sources
                .iter()
                .all(|s| !missing.contains(&s.id))
        );
    }

    #[test]
    fn test_should_tick_lkg_promotion_suppressed_by_safe_minimal_or_drift() {
        let mut live = crate::store::LiveTelemetry {
            lkg_observing: true,
            ..Default::default()
        };
        assert!(should_tick_lkg_promotion(&live, true, false));

        live.safe_minimal_active = true;
        assert!(!should_tick_lkg_promotion(&live, true, false));

        live.safe_minimal_active = false;
        live.config_drift = true;
        assert!(!should_tick_lkg_promotion(&live, true, false));
    }

    #[tokio::test]
    async fn test_stop_for_shutdown_does_not_write_manual_stop_marker() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_shutdown_stop_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let state = crate::store::AppState::load_or_create(dir.join("tachyon-state.json")).unwrap();
        let core = CoreManager::new(Arc::clone(&state));
        let _ = std::fs::remove_file(core.manual_stop_marker_path());

        core.stop_for_shutdown().await.unwrap();
        assert!(!core.manual_stop_marker_path().exists());
        assert!(!core.is_manually_stopped());

        core.stop().await.unwrap();
        assert!(core.manual_stop_marker_path().exists());
        assert!(core.is_manually_stopped());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_drain_core_log_stream_handles_invalid_utf8_and_long_lines() {
        use tokio::io::AsyncWriteExt as _;
        let dir = std::env::temp_dir().join(format!(
            "tachyon_log_drain_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let state = crate::store::AppState::load_or_create(dir.join("store.json")).unwrap();
        let (mut writer, reader) = tokio::io::duplex(64 * 1024);
        let st_clone = Arc::clone(&state);
        let task = tokio::spawn(CoreManager::drain_core_log_stream_to_file(
            reader, st_clone, None,
        ));

        writer.write_all(b"bad-utf8:\xff\xfe:ok\n").await.unwrap();
        let huge = vec![b'x'; 24 * 1024];
        writer.write_all(&huge).await.unwrap();
        writer.write_all(b"\nafter-huge\n").await.unwrap();
        drop(writer);
        task.await.unwrap();

        let logs = state.live.read().await.recent_logs.clone();
        assert!(
            logs.iter()
                .any(|l| l.contains("bad-utf8:") && l.contains(":ok"))
        );
        assert!(logs.iter().any(|l| l.ends_with("[truncated]")));
        assert!(logs.iter().any(|l| l.contains("after-huge")));
        assert!(!CoreManager::is_allowed_cache_path(Path::new(
            "/tmp/../etc/shadow"
        )));
        assert!(!CoreManager::is_allowed_cache_path(Path::new(
            "relative/cache.db"
        )));
        assert!(CoreManager::is_allowed_cache_path(Path::new(
            "/var/run/tachyon/cache.db"
        )));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_device_limit_zero_ip_stub_counted_as_degraded_and_hwid_strip_headers() {
        let zero_ip_sub = "vless://11111111-1111-4111-8111-111111111111@0.0.0.0:1?security=none#%D0%9B%D0%B8%D0%BC%D0%B8%D1%82\n";
        let (nodes, stubs) = CoreManager::parse_subscription_payload_with_stats(zero_ip_sub);
        assert!(nodes.is_empty());
        assert_eq!(stubs, 1);

        let src = crate::store::OutboundSource {
            id: "sub_hwid".to_string(),
            source_type: "subscription".to_string(),
            auto_hwid: true,
            ..Default::default()
        };
        let stripped = CoreManager::build_subscription_request_headers_inner(&src, false);
        assert!(stripped.iter().any(|(k, _)| k == "Accept-Language"));
        assert!(!stripped.iter().any(|(k, _)| {
            matches!(
                k.as_str(),
                "x-hwid" | "x-device-os" | "x-ver-os" | "x-device-model"
            )
        }));
    }

    #[test]
    fn test_quarantine_skips_single_broken_node_and_preserves_multi_node_section() {
        let mut store = crate::store::RouterStoreData::default();
        store.sections.clear();
        store.sections.push(crate::store::RoutingSection {
            id: "Gneral".to_string(),
            label: "General".to_string(),
            enabled: true,
            ..Default::default()
        });

        let initial_cfg = json!({
            "dns": {
                "servers": [
                    { "type": "udp", "tag": "dns-bootstrap", "server": "77.88.8.8", "server_port": 53 },
                    { "type": "udp", "tag": "dns-remote", "server": "1.1.1.1", "server_port": 53 }
                ],
                "final": "dns-remote"
            },
            "outbounds": [
                { "type": "direct", "tag": "direct" },
                { "type": "vless", "tag": "PROM Good", "server": "198.51.100.1", "server_port": 443 },
                { "type": "vless", "tag": "PROM Bad", "server": "198.51.100.2", "server_port": 443 },
                {
                    "type": "selector",
                    "tag": "sel-Gneral",
                    "default": "PROM Bad",
                    "outbounds": ["PROM Bad", "PROM Good"]
                }
            ],
            "route": {
                "rules": [
                    { "rule_set": ["trs-geoblock"], "outbound": "sel-Gneral" }
                ],
                "final": "direct"
            }
        });

        let (prepared, errs) =
            CoreManager::quarantine_with_checker(&store, initial_cfg, BTreeMap::new(), |cfg| {
                let obs = cfg["outbounds"].as_array().unwrap();
                for (i, ob) in obs.iter().enumerate() {
                    if ob["tag"].as_str() == Some("PROM Bad") {
                        return Err(format!(
                            "check: initialize outbound[{i}] vless[PROM Bad]: invalid public_key"
                        ));
                    }
                }
                Ok(())
            });

        assert!(
            !errs.contains_key("Gneral"),
            "working section must not be marked broken when only 1 leaf is skipped: {errs:?}"
        );
        let obs = prepared["outbounds"].as_array().unwrap();
        assert!(!obs.iter().any(|o| o["tag"] == "PROM Bad"));
        assert!(obs.iter().any(|o| o["tag"] == "PROM Good"));
        let sel = obs
            .iter()
            .find(|o| o["tag"] == "sel-Gneral")
            .expect("sel-Gneral must stay active");
        assert_eq!(sel["outbounds"], json!(["PROM Good"]));
        assert_eq!(sel["default"], json!("PROM Good"));
        assert_eq!(
            prepared["route"]["rules"][0]["outbound"],
            json!("sel-Gneral")
        );
    }

    #[test]
    fn test_rotate_core_log_on_start_moves_previous_log_and_writes_header() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_core_log_rot_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let log_path = dir.join("tachyon-core.log");
        let prev_path = dir.join("tachyon-core.log.prev");
        std::fs::write(&log_path, "2026-11-22 stale entry\n").unwrap();

        let created = CoreManager::rotate_core_log_on_start(&dir);
        assert_eq!(created, log_path);
        assert!(prev_path.exists());
        assert_eq!(
            std::fs::read_to_string(&prev_path).unwrap(),
            "2026-11-22 stale entry\n"
        );
        let cur = std::fs::read_to_string(&log_path).unwrap();
        assert!(cur.contains("tachyon-core started"));
        assert!(!cur.contains("stale entry"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_service_autostart_enabled_for_openwrt_and_entware() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_autostart_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let rc_d = dir.join("rc.d");
        std::fs::create_dir_all(&rc_d).unwrap();
        let init_script = dir.join("S99tachyon");

        // OpenWrt: requires S*tachyon in rc.d
        assert!(!CoreManager::service_autostart_enabled_for(
            crate::platform::PlatformKind::OpenWrt,
            &init_script,
            &rc_d
        ));
        std::fs::write(rc_d.join("S99tachyon"), "#!/bin/sh\n").unwrap();
        assert!(CoreManager::service_autostart_enabled_for(
            crate::platform::PlatformKind::OpenWrt,
            &init_script,
            &rc_d
        ));

        // Entware: requires init_script file (and executable on Unix)
        assert!(!CoreManager::service_autostart_enabled_for(
            crate::platform::PlatformKind::KeeneticEntware,
            &init_script,
            &rc_d
        ));
        std::fs::write(&init_script, "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&init_script, std::fs::Permissions::from_mode(0o644)).unwrap();
            assert!(!CoreManager::service_autostart_enabled_for(
                crate::platform::PlatformKind::KeeneticEntware,
                &init_script,
                &rc_d
            ));
            std::fs::set_permissions(&init_script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert!(CoreManager::service_autostart_enabled_for(
            crate::platform::PlatformKind::KeeneticEntware,
            &init_script,
            &rc_d
        ));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_subscription_bom_comments_double_b64_utf16_wg_and_unwrap() {
        use base64::engine::general_purpose::{
            STANDARD_NO_PAD as B64_STD_NO_PAD, URL_SAFE_NO_PAD as B64_URL,
        };
        // 1. UTF-8 BOM + metadata comments with `://` before Base64 payload
        let inner_uris = "vless://11111111-1111-4111-8111-111111111111@de.example.org:443?security=REALITY&pbk=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU=&flow=xtls-rprx-vision-udp443#DE%2BNode\n\
                          ss://YWVzLTI1Ni1nY206dGVzdCt4eXo=@198.51.100.7:8388#SS+2022";
        let b64_inner = B64_STD.encode(inner_uris.as_bytes());
        let with_bom_and_comments = format!(
            "\u{feff}#profile-title: base64:{}\n#support-url: https://t.me/test\n#subscription-userinfo: upload=10; download=20; total=100; expire=1900000000\n\n{}\n# footer comment",
            B64_STD.encode("TestSub".as_bytes()),
            b64_inner
        );
        let parsed = CoreManager::parse_subscription_payload(&with_bom_and_comments);
        assert_eq!(
            parsed.len(),
            2,
            "BOM + comment headers must not break Base64"
        );
        assert_eq!(parsed[0].tag, "DE+Node");
        assert_eq!(parsed[0].outbound_json["flow"], "xtls-rprx-vision");
        assert_eq!(parsed[0].outbound_json["tls"]["reality"]["enabled"], true);
        assert_eq!(parsed[1].outbound_json["password"], "test+xyz");

        let mut meta_src = crate::store::OutboundSource::default();
        parse_subscription_body_metadata(&with_bom_and_comments, &mut meta_src);
        assert_eq!(meta_src.sub_title, "TestSub");
        assert_eq!(meta_src.sub_support_url, "https://t.me/test");
        assert_eq!(meta_src.sub_total_bytes, 100);

        // 2. URL-safe Base64 without padding, double Base64, percent-encoded Base64
        let urlsafe_nopad = B64_URL.encode(inner_uris.as_bytes());
        assert_eq!(
            CoreManager::parse_subscription_payload(&urlsafe_nopad).len(),
            2
        );
        let double_b64 = B64_STD_NO_PAD.encode(urlsafe_nopad.as_bytes());
        assert_eq!(
            CoreManager::parse_subscription_payload(&double_b64).len(),
            2
        );
        let pct_b64 = b64_inner
            .replace('+', "%2B")
            .replace('/', "%2F")
            .replace('=', "%3D");
        assert_eq!(CoreManager::parse_subscription_payload(&pct_b64).len(), 2);

        // 3. UTF-16 LE BOM
        let mut utf16_bytes = vec![0xFFu8, 0xFEu8];
        for unit in inner_uris.encode_utf16() {
            utf16_bytes.extend_from_slice(&unit.to_le_bytes());
        }
        let utf16_text = decode_text_lossy_with_bom(&utf16_bytes);
        assert_eq!(
            CoreManager::parse_subscription_payload(&utf16_text).len(),
            2
        );

        // 4. WireGuard / AmneziaWG .conf INI
        let wg_conf = "[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAddress = 10.8.0.2/32\nJc = 4\n[Peer]\nPublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\nEndpoint = wg.example.org:51820\n";
        let wg_nodes = CoreManager::parse_subscription_payload(wg_conf);
        assert_eq!(wg_nodes.len(), 1);
        assert_eq!(wg_nodes[0].protocol, "wireguard");
        assert_eq!(wg_nodes[0].outbound_json["jc"], 4);

        // 5. Deep-link unwrap formats
        assert_eq!(
            CoreManager::unwrap_subscription_entry("happ://add/https%3A%2F%2Fsub.example.com%2Fx"),
            "https://sub.example.com/x"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry("v2raytun://import/https://sub.example.com/v"),
            "https://sub.example.com/v"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry("incy://add/https://sub.example.com/i"),
            "https://sub.example.com/i"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry("hiddify://import/https://sub.example.com/h"),
            "https://sub.example.com/h"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry(
                "clash://install-config?url=https%3A%2F%2Fsub.example.com%2Fc"
            ),
            "https://sub.example.com/c"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry(
                "sing-box://import-remote-profile?url=https%3A%2F%2Fsub.example.com%2Fsb"
            ),
            "https://sub.example.com/sb"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry("ssconf://outline.example.com/key"),
            "https://outline.example.com/key"
        );
        let sub_b64 = format!("sub://{}", B64_URL.encode(b"https://sub.example.com/s"));
        assert_eq!(
            CoreManager::unwrap_subscription_entry(&sub_b64),
            "https://sub.example.com/s"
        );
        assert_eq!(
            CoreManager::unwrap_subscription_entry("https://sub.example.com/m | My Sub"),
            "https://sub.example.com/m"
        );

        // 6. Chained LF HTTP response headers + 403 X-Hwid-Not-Supported
        let chained = b"HTTP/1.1 200 Connection established\n\nHTTP/1.1 302 Found\nLocation: https://b\n\nHTTP/1.1 403 Forbidden\nX-Hwid-Not-Supported: true\n\nblocked";
        let (hdrs, body, code) = split_http_response_bytes(chained);
        assert_eq!(code, 403);
        assert_eq!(body, b"blocked");
        assert!(headers_indicate_hwid_not_supported(&hdrs));
        let (hdr_s, body_s) = split_http_response(std::str::from_utf8(chained).unwrap());
        assert!(headers_indicate_hwid_not_supported(hdr_s));
        assert_eq!(body_s, "blocked");

        // 7. Unsupported client banner stubs counted
        let stub_sub = "vless://11111111-1111-4111-8111-111111111111@stub.example.org:443#%D0%9A%D0%BB%D0%B8%D0%B5%D0%BD%D1%82%20%D0%BD%D0%B5%20%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B8%D0%B2%D0%B0%D0%B5%D1%82%D1%81%D1%8F\nvless://11111111-1111-4111-8111-111111111111@127.0.0.1:443#%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D0%B9%D1%82%D0%B5%20Happ";
        let (kept, dropped) = CoreManager::parse_subscription_payload_with_stats(stub_sub);
        assert!(kept.is_empty());
        assert_eq!(dropped, 2);

        // 8. Selectel/Remnawave `#App not supported` stub on both 0.0.0.0:1 and dummy host
        let app_stub_b64 = "dmxlc3M6Ly8wMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDBAMC4wLjAuMDoxP2VuY3J5cHRpb249bm9uZSZ0eXBlPXRjcCZzZWN1cml0eT1ub25lI0FwcCUyMG5vdCUyMHN1cHBvcnRlZA==";
        let (kept_app_stub, dropped_app_stub) =
            CoreManager::parse_subscription_payload_with_stats(app_stub_b64);
        assert!(kept_app_stub.is_empty());
        assert_eq!(dropped_app_stub, 1);

        let dummy_host_app_stub = "vless://00000000-0000-0000-0000-000000000000@stub.example.org:443?encryption=none&type=tcp&security=none#App%20not%20supported";
        let (kept_dummy_stub, dropped_dummy_stub) =
            CoreManager::parse_subscription_payload_with_stats(dummy_host_app_stub);
        assert!(kept_dummy_stub.is_empty());
        assert_eq!(dropped_dummy_stub, 1);
    }

    #[test]
    fn test_effective_core_memory_limit_mb_issue_487() {
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(200, Some(128 * 1024)),
            200
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(64 * 1024)),
            64
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(128 * 1024)),
            64
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(256 * 1024)),
            128
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(319 * 1024)),
            159
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(485 * 1024)),
            135
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(512 * 1024)),
            143
        );
        assert_eq!(
            CoreManager::effective_core_memory_limit_mb(0, Some(1024 * 1024)),
            0
        );
        assert_eq!(CoreManager::effective_core_memory_limit_mb(0, None), 0);

        let mut cmd = tokio::process::Command::new("tachyon-core");
        CoreManager::configure_core_spawn_command(&mut cmd, true, 128);
        let envs: Vec<(String, Option<String>)> = cmd
            .as_std()
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().into_owned(),
                    v.map(|val| val.to_string_lossy().into_owned()),
                )
            })
            .collect();
        assert!(envs.contains(&("TACHYON_MEMLIMIT_MB".to_string(), Some("128".to_string()))));
        assert!(!envs.iter().any(|(k, _)| k == "GOMEMLIMIT"));
    }

    #[test]
    fn test_clash_selector_candidates_skips_urltest_and_fallback_pr_510() {
        let proxies = json!({
            "proxies": {
                "sel-Main": { "type": "Selector", "all": ["bal-Main-auto", "NodeA"] },
                "bal-Main-auto": { "type": "URLTest", "all": ["NodeA", "NodeB"] },
                "Main": { "type": "Fallback", "all": ["NodeA", "NodeB"] }
            }
        });
        assert_eq!(
            CoreManager::clash_selector_candidates("Main", &["auto".to_string()], Some(&proxies)),
            vec!["sel-Main".to_string()]
        );
        assert_eq!(
            CoreManager::clash_selector_candidates("Main", &["auto".to_string()], None),
            vec![
                "sel-Main".to_string(),
                "Main".to_string(),
                "Main-out".to_string(),
            ]
        );

        let proxies_with_sel_bal = json!({
            "proxies": {
                "sel-Main": { "type": "Selector", "all": ["bal-Main-sel", "NodeA", "NodeB"] },
                "bal-Main-sel": { "type": "Selector", "all": ["NodeA", "NodeB"] }
            }
        });
        assert_eq!(
            CoreManager::clash_selector_candidates(
                "Main",
                &["sel".to_string()],
                Some(&proxies_with_sel_bal)
            ),
            vec!["sel-Main".to_string(), "bal-Main-sel".to_string()]
        );
    }

    #[tokio::test]
    async fn test_clash_request_raw_and_restore_saved_selectors_skip_unready_or_unchanged() {
        let mock = Arc::new(MockClashState::default());
        let (port, srv_handle) = spawn_test_mock_clash_server(Arc::clone(&mock)).await;

        let dir = std::env::temp_dir().join(format!(
            "tachyon_raw_sel_test_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let cfg_file = dir.join("core-cfg.json");
        std::fs::write(
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
        )
        .expect("write cfg");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        {
            let mut d = state.data.write().await;
            d.settings.clash_api_addr = format!("127.0.0.1:{port}");
            d.settings.clash_api_secret.clear();
            d.settings.core_config_path = cfg_file.to_string_lossy().to_string();
            d.sections[0].enabled = true;
            d.sections[0].active_selected_tag = "NodeA".to_string();
        }
        let mgr = CoreManager::new(Arc::clone(&state));
        let raw = mgr
            .clash_request_raw("GET", "/connections", None)
            .await
            .expect("clash_request_raw GET /connections");
        let parsed: Value = serde_json::from_str(&raw).expect("valid raw json");
        assert!(parsed.get("connections").is_some());

        // When Clash API is unreachable, restore_saved_selectors must abort instead of blasting PUTs.
        let closed_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind closed port");
        let closed_port = closed_listener.local_addr().unwrap().port();
        drop(closed_listener);
        let closed_cfg = dir.join("closed-cfg.json");
        std::fs::write(
            &closed_cfg,
            json!({
                "experimental": {
                    "clash_api": {
                        "external_controller": format!("127.0.0.1:{closed_port}"),
                        "secret": ""
                    }
                }
            })
            .to_string(),
        )
        .expect("write closed cfg");
        {
            let mut d = state.data.write().await;
            d.settings.clash_api_addr = format!("127.0.0.1:{closed_port}");
            d.settings.core_config_path = closed_cfg.to_string_lossy().to_string();
        }
        CoreManager::invalidate_clash_cred_cache();
        let snap = state.data.read().await.clone();
        let started = Instant::now();
        mgr.restore_saved_selectors(&snap).await;
        assert!(started.elapsed() < Duration::from_secs(3));

        // Startup IPv6 resync helper triggers only when effective state changed AND config does not match.
        assert!(!CoreManager::should_resync_startup_ipv6(
            crate::store::EffectiveIpv6State::TunnelOverV4,
            crate::store::EffectiveIpv6State::TunnelOverV4,
            false
        ));
        assert!(!CoreManager::should_resync_startup_ipv6(
            crate::store::EffectiveIpv6State::Disabled,
            crate::store::EffectiveIpv6State::Full,
            true
        ));
        assert!(CoreManager::should_resync_startup_ipv6(
            crate::store::EffectiveIpv6State::Disabled,
            crate::store::EffectiveIpv6State::Full,
            false
        ));

        srv_handle.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_net_stack_fingerprint_stable_across_non_net_changes_and_fast_kill() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_fp_kill_test_{}_{:08x}",
            std::process::id(),
            rand::random::<u32>()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        let mgr = CoreManager::new(Arc::clone(&state));
        let d1 = state.data.read().await.clone();
        let mut d2 = d1.clone();
        d2.sections[0].active_selected_tag = "NodeX".to_string();
        assert_eq!(
            CoreManager::compute_net_stack_fingerprint(&d1, false, false),
            CoreManager::compute_net_stack_fingerprint(&d2, false, false),
        );
        d2.settings.tcp_bbr = !d1.settings.tcp_bbr;
        assert_ne!(
            CoreManager::compute_net_stack_fingerprint(&d1, false, false),
            CoreManager::compute_net_stack_fingerprint(&d2, false, false),
        );

        let child = spawn_dummy_long_process();
        *mgr.proc.lock().await = Some((child, Instant::now()));
        assert!(mgr.has_spawned_child().await);
        mgr.force_kill_spawned_child_fast().await;
        assert!(!mgr.has_spawned_child().await);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
