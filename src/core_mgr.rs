//! `tachyon-core` process lifecycle manager, Clash API & `/tachyon/*` client,
//! Autonomous Watchdog + Reconciler loop, subscription fetcher, and parallel RTT prober.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::{
    STANDARD as B64_STD, STANDARD_NO_PAD as B64_STD_NO_PAD, URL_SAFE as B64_URL_PAD,
    URL_SAFE_NO_PAD as B64_URL,
};
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
    sub_last_attempt: Mutex<HashMap<String, i64>>,
    prev_totals: Mutex<Option<TrafficSampleBaseline>>,
    intentional_stop: AtomicBool,
    auto_rollback_in_flight: AtomicBool,
    last_ipv6_resync_ts: PortableAtomicU64,
    pub watchdog: Mutex<crate::watchdog::WatchdogState>,
}

impl CoreManager {
    pub fn new(state: Arc<AppState>) -> Arc<Self> {
        Arc::new(Self {
            state,
            proc: Mutex::new(None),
            reload_lock: Mutex::new(()),
            sub_refresh_lock: Mutex::new(()),
            sub_last_attempt: Mutex::new(HashMap::new()),
            prev_totals: Mutex::new(None),
            intentional_stop: AtomicBool::new(false),
            auto_rollback_in_flight: AtomicBool::new(false),
            last_ipv6_resync_ts: PortableAtomicU64::new(0),
            watchdog: Mutex::new(crate::watchdog::WatchdogState::default()),
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
            let tag = obj
                .get("tag")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if !tag.starts_with("trs-") && !tag.starts_with("builtin-") {
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
        if !matches!(format, "source" | "binary" | "trs" | "tsr") {
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
                    "timeout": "4s",
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
                route_map.insert("default_domain_resolver".into(), json!("dns-bootstrap"));
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
            && let Some(tag) = cfg
                .pointer(&format!("/outbounds/{idx}/tag"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
            && Self::strip_outbound_tag_and_repair_refs(cfg, &tag)
        {
            return true;
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "endpoints")
            && let Some(tag) = cfg
                .pointer(&format!("/endpoints/{idx}/tag"))
                .and_then(Value::as_str)
                .map(ToString::to_string)
            && Self::strip_outbound_tag_and_repair_refs(cfg, &tag)
        {
            return true;
        }

        if let Some(idx) = Self::extract_bracket_index(&norm, "inbounds")
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

        let found_tag = ["/outbounds", "/endpoints"].iter().find_map(|ptr| {
            cfg.pointer(ptr)
                .and_then(Value::as_array)
                .and_then(|items| {
                    items.iter().find_map(|item| {
                        let tag = item.get("tag").and_then(Value::as_str)?;
                        (!matches!(tag, "direct" | "block") && norm.contains(tag))
                            .then(|| tag.to_string())
                    })
                })
        });
        if let Some(tag) = found_tag
            && Self::strip_outbound_tag_and_repair_refs(cfg, &tag)
        {
            return true;
        }
        false
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
        config_gen::compile_safe_minimal_core_config(store_snapshot)
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

    async fn run_core_check_on_value(bin_path: &str, candidate_cfg: &Value) -> Result<(), String> {
        let tmp_check_path = std::env::temp_dir().join("tachyon-core-candidate.json");
        crypto_gen::write_json_if_changed(&tmp_check_path, candidate_cfg)
            .map_err(|e| format!("failed to write check candidate: {e}"))?;
        let mut cmd = Command::new(bin_path);
        cmd.args(["check", "-c", &tmp_check_path.to_string_lossy()]);
        match Self::run_command_output_with_timeout(&mut cmd, Duration::from_secs(15)).await {
            Ok(out) if out.status.success() => Ok(()),
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let stdout = String::from_utf8_lossy(&out.stdout);
                Err(format!("{}{}", stderr.trim(), stdout.trim()))
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                Err("tachyon-core check timed out after 15s".to_string())
            }
            Err(e) => Err(format!("failed to invoke tachyon-core check: {e}")),
        }
    }

    async fn compile_or_safe_minimal(
        &self,
        store_snapshot: &crate::store::RouterStoreData,
    ) -> (Value, BTreeMap<String, String>) {
        let mut seed_errors = BTreeMap::new();
        match config_gen::compile_core_config(store_snapshot) {
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
                    config_gen::compile_safe_minimal_core_config(store_snapshot),
                    seed_errors,
                )
            }
        }
    }

    async fn spawn_and_verify_core(bin_path: &str, cfg_path: &Path) -> Result<Child, String> {
        let mut cmd = Command::new(bin_path);
        cmd.args(["run", "-c", &cfg_path.to_string_lossy()])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("tachyon-core spawn failed: {e:#}"))?;

        for _ in 0..4 {
            tokio::time::sleep(Duration::from_millis(75)).await;
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
        let is_tmp_staging = state_dir.to_string_lossy().starts_with("/tmp/tachyon-rs")
            && Path::new("/etc/init.d/tachyon").exists();

        let bin_path = self.resolve_bin_path().await;
        let run_binary_check = cfg!(target_os = "linux") && Path::new(&bin_path).exists();

        let (prepared_cfg, quarantined) = if run_binary_check {
            let mut cfg = initial_cfg;
            let mut quarantined = seed_errors;
            Self::sanitize_candidate_local_rulesets(&mut cfg);
            Self::sanitize_broken_custom_local_rulesets(&mut cfg, &mut quarantined);

            let mut last_err: Option<String> = None;
            let mut passed = false;
            for _ in 0..16 {
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
        self.ensure_server_tls_certs(&store_snapshot).await;
        let (cfg_val, seed_errors) = self.compile_or_safe_minimal(&store_snapshot).await;
        let (cfg_path, prepared_cfg, mut quarantined) = match self
            .prepare_and_write_validated_core_config(&store_snapshot, cfg_val, seed_errors)
            .await
        {
            Ok(v) => v,
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

        let mut child = match Self::spawn_and_verify_core(&bin_path, &cfg_path).await {
            Ok(c) => c,
            Err(first_err) if !quarantined.contains_key("_core_runtime") => {
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
                self.state.live.write().await.push_event(
                    "warn",
                    "core_mgr",
                    &format!(
                        "Ранний сбой запуска tachyon-core ({pretty}); повторный запуск в безопасном минимальном режиме"
                    ),
                );
                let safe_cfg = config_gen::compile_safe_minimal_core_config(&store_snapshot);
                if let Err(e) = crypto_gen::write_json_if_changed(&cfg_path, &safe_cfg) {
                    cleanup_failed_start(
                        veto.is_some(),
                        format!("failed to write safe fallback config: {e:#}"),
                    )
                    .await;
                    return Err(e);
                }
                match Self::spawn_and_verify_core(&bin_path, &cfg_path).await {
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
            let (re_cfg_val, re_seed_errors) = self.compile_or_safe_minimal(&store_snapshot).await;
            if let Ok((re_cfg_path, _, _)) = self
                .prepare_and_write_validated_core_config(
                    &store_snapshot,
                    re_cfg_val,
                    re_seed_errors,
                )
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
            return Box::pin(self.start()).await;
        }
        let store_snapshot = { self.state.data.read().await.clone() };
        self.ensure_server_tls_certs(&store_snapshot).await;
        let (cfg_val, seed_errors) = self.compile_or_safe_minimal(&store_snapshot).await;
        let (cfg_path_buf, _, _) = self
            .prepare_and_write_validated_core_config(&store_snapshot, cfg_val, seed_errors)
            .await?;
        let cfg_path = cfg_path_buf.to_string_lossy().to_string();
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
            return Box::pin(self.start()).await;
        }
        self.restore_saved_selectors(&store_snapshot).await;
        drop(reload_guard);
        Ok(())
    }

    /// Hot-reload `tachyon-core` via `PUT /configs` on Clash API, or restart if not running.
    /// Automatically rolls back to the last working config if validation/startup fails during an observation window.
    pub async fn apply_or_reload(&self) -> anyhow::Result<()> {
        let was_running = { self.state.live.read().await.core_running };
        let res = Box::pin(self.apply_or_reload_inner()).await;
        if let Err(ref err) = res {
            let err_text = err.to_string();
            let missing_binary = err_text.contains("tachyon-core binary not found");
            let config_rejected = err_text.contains("tachyon-core check failed")
                || err_text.contains("tachyon-core check timed out")
                || err_text.contains("config compile failed");
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
                    let wanted_canon = config_gen::strip_dynamic_server_telemetry(&chosen);
                    let telemetry_match = (!wanted_canon.is_empty()).then(|| {
                        all_arr.iter().filter_map(Value::as_str).find(|cand| {
                            config_gen::strip_dynamic_server_telemetry(cand)
                                .eq_ignore_ascii_case(&wanted_canon)
                        })
                    });
                    if let Some(Some(matched)) = telemetry_match {
                        chosen = matched.to_string();
                        pruned_dirty = true;
                    } else {
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

    pub(crate) const SUBSCRIPTION_AUTO_USER_AGENTS: &[&str] = &[
        "tachyon-core/2.0",
        "Happ/4.6.2",
        "v2rayNG/2.3.15",
        "v2rayN/7.12",
        "Mihomo/1.19.16",
        "FlClash/v0.8.72",
        "HiddifyNext/2.5.7",
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
        let mut headers = Vec::with_capacity(7);
        let accept_lang = if src.accept_language.trim().is_empty() {
            "ru-RU,ru;q=0.9,en-US;q=0.8"
        } else {
            src.accept_language.trim()
        };
        headers.push(("Accept-Language".to_string(), accept_lang.to_string()));

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
        let max_t = timeout_secs.max(4).to_string();
        let ua = user_agent
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("tachyon-core/2.0");
        let build_base_args = |inc_hdr: bool| -> Vec<String> {
            let mut a = Vec::with_capacity(14 + extra_headers.len() * 2);
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
            for (k, v) in extra_headers {
                a.push("-H".to_string());
                a.push(format!("{k}: {v}"));
            }
            a
        };

        let mut saw_http_error = false;
        let cmd_timeout = Duration::from_secs(timeout_secs.max(4).saturating_add(3));
        if let Some(px) = proxy_url.filter(|s| !s.trim().is_empty()) {
            let mut args = build_base_args(include_headers);
            args.push("-x".to_string());
            args.push(px.trim().to_string());
            args.push(url.to_string());
            if let Ok(out) = Self::run_curl_args(&args, cmd_timeout).await {
                if out.status.success() && !out.stdout.is_empty() {
                    return Ok(out.stdout);
                }
                if out.status.code() == Some(22) {
                    saw_http_error = true;
                }
            }
        }

        let mut direct_args = build_base_args(include_headers);
        if let Some(resolve_spec) = self.resolve_url_host_via_bootstrap_dns(url).await {
            direct_args.push("--resolve".to_string());
            direct_args.push(resolve_spec);
        }
        direct_args.push(url.to_string());
        if let Ok(out) = Self::run_curl_args(&direct_args, cmd_timeout).await {
            if out.status.success() && !out.stdout.is_empty() {
                return Ok(out.stdout);
            }
            if out.status.code() == Some(22) {
                saw_http_error = true;
            }
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
                    saw_http_error = true;
                    break;
                }
            }
        }

        if saw_http_error {
            anyhow::bail!("curl HTTP error (status 22) for {url}");
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
        Self::parse_subscription_payload_with_stats(raw).0
    }

    /// Parse raw subscription content into usable nodes and return the count of dropped `.invalid` stubs.
    pub(crate) fn parse_subscription_payload_with_stats(
        raw: &str,
    ) -> (Vec<ParsedProxyNode>, usize) {
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

        // Drop informational/banner pseudo-nodes pointing to loopback/unspecified addresses
        // (e.g. `127.0.0.1:443#Remaining: 15GB`) that cause immediate ECONNREFUSED after reload.
        // Track `.invalid` stub hosts separately so auto-UA discovery promotes past degraded feeds.
        let mut dropped_invalid_stubs = 0usize;
        out.retain(|node| {
            let srv = node.server.trim();
            let keep = srv.is_empty() || config_gen::is_usable_external_sub_host(srv);
            if !keep {
                let bare = srv
                    .trim_start_matches('[')
                    .trim_end_matches(']')
                    .trim_end_matches('.')
                    .to_ascii_lowercase();
                if bare == "invalid" || bare.ends_with(".invalid") {
                    dropped_invalid_stubs += 1;
                }
            }
            keep
        });

        let mut taken_tags: HashSet<String> = HashSet::new();
        for node in &mut out {
            config_gen::assign_unique_node_tag(node, &mut taken_tags);
        }
        (out, dropped_invalid_stubs)
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

            let extra_headers = Self::build_subscription_request_headers(&src);
            let urls = src.subscription_urls.clone();

            let probe_with_ua = |base_src: &crate::store::OutboundSource, ua: &str| {
                let mut trial_src = base_src.clone();
                let headers_ref = &extra_headers;
                let urls_ref = &urls;
                let proxy_ref = proxy_opt.as_deref();
                let ua_owned = ua.to_string();
                async move {
                    let mut out_nodes: Vec<ParsedProxyNode> = Vec::new();
                    let mut dropped_invalid_stubs = 0usize;
                    let mut err_msg: Option<String> = None;
                    let mut got_http_reply = false;
                    for url in urls_ref {
                        match self
                            .curl_fetch_with_headers(
                                url,
                                true,
                                12,
                                proxy_ref,
                                Some(&ua_owned),
                                headers_ref,
                            )
                            .await
                        {
                            Ok(stdout) => {
                                got_http_reply = true;
                                let raw_resp = String::from_utf8_lossy(&stdout);
                                let (headers_part, body_part) = split_http_response(&raw_resp);
                                parse_subscription_headers(headers_part, &mut trial_src);
                                let (parsed_for_url, stubs_for_url) =
                                    Self::parse_subscription_payload_with_stats(body_part);
                                dropped_invalid_stubs += stubs_for_url;
                                if parsed_for_url.is_empty() && err_msg.is_none() {
                                    err_msg = Some(
                                        if headers_indicate_hwid_not_supported(headers_part) {
                                            format!(
                                                "Провайдер подписки ({url}) отклонил параметры устройства (X-Hwid-Not-Supported)"
                                            )
                                        } else {
                                            format!(
                                                "Ответ подписки ({url}) не содержит поддерживаемых узлов"
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
                                let es = e.to_string();
                                if es.contains("status 22") {
                                    got_http_reply = true;
                                }
                                if err_msg.is_none() {
                                    err_msg = Some(format!("{url}: {es}"));
                                }
                            }
                        }
                    }
                    (
                        out_nodes,
                        dropped_invalid_stubs,
                        err_msg,
                        got_http_reply,
                        trial_src,
                    )
                }
            };

            let (nodes, last_fetch_err, final_src) = if !src.auto_user_agent {
                let explicit_ua = Self::normalize_subscription_user_agent(&src.user_agent);
                let effective_ua = if explicit_ua.is_empty() {
                    "tachyon-core/2.0".to_string()
                } else {
                    explicit_ua
                };
                let (n, _stubs, e, _, mut next_src) = probe_with_ua(&src, &effective_ua).await;
                if !n.is_empty() {
                    next_src.sub_preferred_user_agent = effective_ua;
                }
                (n, e, next_src)
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
                if !preferred.is_empty() {
                    already_tried_preferred = true;
                    let (n, dropped_stubs, e, _, mut next_src) =
                        probe_with_ua(&src, &preferred).await;
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
                    (n, e, next_src)
                } else {
                    let mut first_err: Option<String> = None;
                    for (idx, ua) in Self::SUBSCRIPTION_AUTO_USER_AGENTS.iter().enumerate() {
                        if already_tried_preferred && *ua == preferred {
                            continue;
                        }
                        if idx > 0 {
                            tokio::time::sleep(Duration::from_millis(120)).await;
                        }
                        let (n, dropped_stubs, e, got_http, next_src) =
                            probe_with_ua(&src, ua).await;
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
                        if !got_http && count == 0 && idx == 0 {
                            // Network/DNS transport unreachable on first probe — skip redundant UA retries.
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
                        (best.nodes, best.err, best_src)
                    } else {
                        let mut fallback_src =
                            candidates.into_iter().next().map(|c| c.src).unwrap_or(src);
                        if !fallback_src.sub_preferred_user_agent.is_empty() {
                            fallback_src.sub_preferred_user_agent.clear();
                        }
                        (Vec::new(), first_err, fallback_src)
                    }
                }
            };
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
                if !nodes_materially_equal(&src.cached_nodes, &res.nodes) {
                    core_reload_needed = true;
                }
                src.cached_nodes = res.nodes;
                src.last_updated_unix = finish_ts;
                src.sub_last_error.clear();
                updated_sources += 1;
                metadata_changed = true;
            } else {
                src.sub_last_error = res.last_fetch_err.unwrap_or_else(|| {
                    "Не удалось загрузить или разобрать узлы подписки".to_string()
                });
                src.last_updated_unix = finish_ts;
                if !src.cached_nodes.is_empty() {
                    updated_sources += 1;
                }
                metadata_changed = true;
            }
        }

        if metadata_changed || updated_sources > 0 {
            if let Err(e) =
                transaction::commit_transaction_with_source(&self.state, candidate, "subscription")
                    .await
            {
                self.state.live.write().await.push_event(
                    "warn",
                    "subscription",
                    &format!("Subscription state commit skipped (in-memory timestamp kept): {e:#}"),
                );
                return Err(e);
            }
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

            if live.lkg_observing {
                let healthy_tick = core_alive
                    && !self.is_manually_stopped()
                    && live.core_fail_streak == 0
                    && live.dns_fail_streak == 0;
                if healthy_tick {
                    live.lkg_remaining_secs = live.lkg_remaining_secs.saturating_sub(3);
                    if live.lkg_remaining_secs == 0 {
                        live.lkg_observing = false;
                        promote_lkg = true;
                        promoted_rev_id = live.active_revision_id.clone();
                    }
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
            json!("dns-bootstrap")
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
            json!("dns-bootstrap")
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
}
