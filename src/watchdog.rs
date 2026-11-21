//! Autonomous Watchdog, real WAN/DNS probing, binary/config integrity verification,
//! L0-L5 self-healing escalation ladder, and zero-flash-wear tmpfs Blackbox capture.

use std::collections::HashMap;
use std::io::Read as _;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::net::{TcpStream, UdpSocket};
use tokio::task::JoinSet;

use crate::config_gen;
use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::net_stack;
use crate::snapshots;
use crate::store::{AppState, BlackboxSummary, OutboundHealthEntry, unix_now_secs};

pub const MAX_BLACKBOX_FILES: usize = 5;
const MIN_CORE_BINARY_BYTES: u64 = 64 * 1024;
const CIRCUIT_BREAKER_WINDOW_SECS: i64 = 600;
const CIRCUIT_BREAKER_MAX_RESTARTS: usize = 4;

/// Hysteresis filter preventing transient packet drops from triggering state flips.
#[derive(Debug, Clone)]
pub struct CheckHysteresis {
    pub fail_streak: u32,
    pub ok_streak: u32,
    pub healthy: bool,
    fail_threshold: u32,
    recover_threshold: u32,
}

impl CheckHysteresis {
    pub fn new(fail_threshold: u32, recover_threshold: u32) -> Self {
        Self {
            fail_streak: 0,
            ok_streak: 0,
            healthy: true,
            fail_threshold: fail_threshold.max(1),
            recover_threshold: recover_threshold.max(1),
        }
    }

    /// Record one probe result and return the updated `healthy` state.
    pub fn record(&mut self, ok: bool) -> bool {
        if ok {
            self.fail_streak = 0;
            self.ok_streak = self.ok_streak.saturating_add(1);
            if !self.healthy && self.ok_streak >= self.recover_threshold {
                self.healthy = true;
            }
        } else {
            self.ok_streak = 0;
            self.fail_streak = self.fail_streak.saturating_add(1);
            if self.healthy && self.fail_streak >= self.fail_threshold {
                self.healthy = false;
            }
        }
        self.healthy
    }
}

/// Persistent in-memory Watchdog state (held inside `CoreManager`, never locked across `.await`).
#[derive(Debug)]
pub struct WatchdogState {
    pub wan: CheckHysteresis,
    pub dns: CheckHysteresis,
    pub core: CheckHysteresis,
    pub restart_timestamps: Vec<i64>,
    pub action_cooldowns: HashMap<String, i64>,
    pub last_escalation: String,
    pub last_escalation_ts: i64,
    pub last_dns_flush_ts: i64,
    pub last_blackbox_by_reason: HashMap<String, i64>,
}

impl Default for WatchdogState {
    fn default() -> Self {
        Self {
            wan: CheckHysteresis::new(3, 2),
            dns: CheckHysteresis::new(3, 2),
            core: CheckHysteresis::new(2, 1),
            restart_timestamps: Vec::new(),
            action_cooldowns: HashMap::new(),
            last_escalation: "idle".to_string(),
            last_escalation_ts: 0,
            last_dns_flush_ts: 0,
            last_blackbox_by_reason: HashMap::new(),
        }
    }
}

impl WatchdogState {
    pub fn prune_restarts(&mut self, now: i64) {
        self.restart_timestamps
            .retain(|&ts| now.saturating_sub(ts) <= CIRCUIT_BREAKER_WINDOW_SECS);
    }

    pub fn record_restart(&mut self, now: i64) -> bool {
        self.prune_restarts(now);
        self.restart_timestamps.push(now);
        self.restart_timestamps.len() > CIRCUIT_BREAKER_MAX_RESTARTS
    }

    pub fn restarts_in_window(&mut self, now: i64) -> u32 {
        self.prune_restarts(now);
        self.restart_timestamps.len() as u32
    }

    pub fn cooldown_ready(&mut self, action: &str, now: i64, cooldown_secs: i64) -> bool {
        if let Some(&last) = self.action_cooldowns.get(action)
            && now.saturating_sub(last) < cooldown_secs
        {
            return false;
        }
        self.action_cooldowns.insert(action.to_string(), now);
        true
    }
}

pub fn default_wan_targets() -> [SocketAddr; 3] {
    [
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), 443),
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)), 53),
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(77, 88, 8, 8)), 53),
    ]
}

/// Non-blocking concurrent TCP connect check against WAN targets without shell subprocesses.
pub async fn probe_wan_health(targets: &[SocketAddr]) -> (bool, u64) {
    if targets.is_empty() {
        return (false, 0);
    }
    let started = Instant::now();
    let mut set = JoinSet::new();
    for &addr in targets {
        set.spawn(async move {
            let t0 = Instant::now();
            let ok = tokio::time::timeout(Duration::from_millis(1200), TcpStream::connect(addr))
                .await
                .is_ok_and(|res| res.is_ok());
            (ok, u64::try_from(t0.elapsed().as_millis()).unwrap_or(1200))
        });
    }
    while let Some(res) = set.join_next().await {
        if let Ok((true, ms)) = res {
            set.abort_all();
            return (true, ms);
        }
    }
    (
        false,
        u64::try_from(started.elapsed().as_millis()).unwrap_or(1200),
    )
}

fn encode_dns_a_query(txid: u16, domain: &str) -> Vec<u8> {
    let mut pkt = Vec::with_capacity(64);
    pkt.extend_from_slice(&txid.to_be_bytes());
    pkt.extend_from_slice(&0x0100u16.to_be_bytes()); // standard query, RD=1
    pkt.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT=1
    pkt.extend_from_slice(&0u16.to_be_bytes()); // ANCOUNT
    pkt.extend_from_slice(&0u16.to_be_bytes()); // NSCOUNT
    pkt.extend_from_slice(&0u16.to_be_bytes()); // ARCOUNT
    for label in domain.trim_end_matches('.').split('.') {
        if label.is_empty() || label.len() > 63 {
            continue;
        }
        pkt.push(label.len() as u8);
        pkt.extend_from_slice(label.as_bytes());
    }
    pkt.push(0); // root label
    pkt.extend_from_slice(&1u16.to_be_bytes()); // QTYPE = A
    pkt.extend_from_slice(&1u16.to_be_bytes()); // QCLASS = IN
    pkt
}

/// Pure-Rust UDP DNS A-query probe (1000ms timeout), validating txid, QR flag, and rcode != SERVFAIL.
pub async fn probe_local_dns_health(addr: SocketAddr, domain: &str) -> (bool, u64) {
    let bind_addr: SocketAddr = if addr.is_ipv6() {
        SocketAddr::new(IpAddr::V6(std::net::Ipv6Addr::UNSPECIFIED), 0)
    } else {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
    };
    let t0 = Instant::now();
    let Ok(sock) = UdpSocket::bind(bind_addr).await else {
        return (false, 0);
    };
    if sock.connect(addr).await.is_err() {
        return (
            false,
            u64::try_from(t0.elapsed().as_millis()).unwrap_or(1000),
        );
    }
    let txid: u16 = rand::random();
    let pkt = encode_dns_a_query(txid, domain);
    if sock.send(&pkt).await.is_err() {
        return (
            false,
            u64::try_from(t0.elapsed().as_millis()).unwrap_or(1000),
        );
    }
    let mut buf = [0u8; 512];
    match tokio::time::timeout(Duration::from_millis(1000), sock.recv(&mut buf)).await {
        Ok(Ok(n)) if n >= 12 => {
            let ms = u64::try_from(t0.elapsed().as_millis()).unwrap_or(1000);
            let resp_txid = u16::from_be_bytes([buf[0], buf[1]]);
            let is_response = (buf[2] & 0x80) != 0;
            let rcode = buf[3] & 0x0f;
            // Reject SERVFAIL (2) or REFUSED (5); NOERROR (0) / NXDOMAIN (3) indicate healthy engine response
            let healthy = resp_txid == txid && is_response && rcode != 2 && rcode != 5;
            (healthy, ms)
        }
        _ => (
            false,
            u64::try_from(t0.elapsed().as_millis()).unwrap_or(1000),
        ),
    }
}

/// Validate `tachyon-core` binary existence, non-trivial size (>64 KiB), and executable header.
pub fn check_core_binary_integrity(path: &Path) -> Result<(), String> {
    check_core_binary_integrity_with_min_size(path, MIN_CORE_BINARY_BYTES)
}

pub fn check_core_binary_integrity_with_min_size(
    path: &Path,
    min_bytes: u64,
) -> Result<(), String> {
    if path.as_os_str().is_empty() {
        return Err("core binary path is empty".to_string());
    }
    let meta = std::fs::metadata(path).map_err(|e| format!("cannot stat binary: {e}"))?;
    if !meta.is_file() {
        return Err("core binary path is not a regular file".to_string());
    }
    if meta.len() < min_bytes {
        return Err(format!(
            "core binary size ({} B) below minimum {} B (truncated download or wrapper)",
            meta.len(),
            min_bytes
        ));
    }
    let mut file =
        std::fs::File::open(path).map_err(|e| format!("cannot open core binary: {e}"))?;
    let mut hdr = [0u8; 4];
    file.read_exact(&mut hdr)
        .map_err(|e| format!("cannot read binary header: {e}"))?;
    if hdr.starts_with(b"#!") {
        return Err(
            "core binary is a shell script wrapper (#!) instead of native executable".into(),
        );
    }
    #[cfg(target_os = "linux")]
    if &hdr != b"\x7fELF" {
        return Err(format!("unexpected ELF magic {:02x?}", hdr));
    }
    #[cfg(windows)]
    if &hdr[..2] != b"MZ" && &hdr != b"\x7fELF" {
        return Err(format!("unexpected executable header {:02x?}", hdr));
    }
    Ok(())
}

/// Canonical SHA-256 hex digest matching `tachyon-core`'s `/tachyon/config-state` `digest`.
pub fn compute_config_digest(cfg: &Value) -> String {
    struct HashWriter(Sha256);
    impl std::io::Write for HashWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.update(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut writer = HashWriter(Sha256::new());
    if serde_json::to_writer(&mut writer, cfg).is_err() {
        return String::new();
    }
    writer
        .0
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn blackbox_dir() -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        PathBuf::from("/tmp/tachyon/blackbox")
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::env::temp_dir().join("tachyon-blackbox")
    }
}

fn is_valid_blackbox_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 80
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn sanitize_reason_slug(reason: &str) -> String {
    let slug: String = reason
        .chars()
        .take(24)
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = slug.trim_matches('_');
    if trimmed.is_empty() {
        "snapshot".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Store a redacted Blackbox incident bundle in tmpfs, rotating oldest files past `MAX_BLACKBOX_FILES`.
pub fn write_blackbox_file_in(
    dir: &Path,
    reason: &str,
    payload: Value,
) -> anyhow::Result<BlackboxSummary> {
    std::fs::create_dir_all(dir)?;
    let ts = unix_now_secs();
    let suffix = crypto_gen::generate_hex(3);
    let slug = sanitize_reason_slug(reason);
    let id = format!("bb-{ts}-{slug}-{suffix}");
    let redacted = crypto_gen::redact_json_value(&payload);
    let doc = json!({
        "id": id,
        "timestamp": ts,
        "reason": reason,
        "payload": redacted,
    });
    let file_path = dir.join(format!("{id}.json"));
    let serialized = serde_json::to_vec_pretty(&doc)?;
    std::fs::write(&file_path, &serialized)?;

    // Enforce strict tmpfs capacity rotation (`MAX_BLACKBOX_FILES`).
    if let Ok(entries) = std::fs::read_dir(dir) {
        let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
            .flatten()
            .filter_map(|e| {
                let p = e.path();
                if p.extension().and_then(|s| s.to_str()) != Some("json") {
                    return None;
                }
                let mtime = e
                    .metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
                Some((mtime, p))
            })
            .collect();
        if files.len() > MAX_BLACKBOX_FILES {
            files.sort_by_key(|(t, _)| *t);
            let excess = files.len() - MAX_BLACKBOX_FILES;
            for (_, old_path) in files.into_iter().take(excess) {
                let _ = std::fs::remove_file(old_path);
            }
        }
    }

    Ok(BlackboxSummary {
        id,
        timestamp: ts,
        reason: reason.to_string(),
        file_size_bytes: serialized.len() as u64,
    })
}

pub fn list_blackboxes_in(dir: &Path) -> Vec<BlackboxSummary> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
        let fallback_id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        if !is_valid_blackbox_id(&fallback_id) {
            continue;
        }
        if let Ok(raw) = std::fs::read_to_string(&path)
            && let Ok(val) = serde_json::from_str::<Value>(&raw)
        {
            items.push(BlackboxSummary {
                id: val
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or(&fallback_id)
                    .to_string(),
                timestamp: val.get("timestamp").and_then(Value::as_i64).unwrap_or(0),
                reason: val
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_string(),
                file_size_bytes: size,
            });
        }
    }
    items.sort_by(|a, b| b.timestamp.cmp(&a.timestamp).then_with(|| b.id.cmp(&a.id)));
    items
}

pub fn list_blackboxes() -> Vec<BlackboxSummary> {
    list_blackboxes_in(&blackbox_dir())
}

pub fn read_blackbox_in(dir: &Path, id: &str) -> anyhow::Result<Value> {
    if !is_valid_blackbox_id(id) {
        anyhow::bail!("Недопустимый идентификатор blackbox");
    }
    let path = dir.join(format!("{id}.json"));
    if !path.is_file() {
        anyhow::bail!("Blackbox '{id}' не найден");
    }
    let raw = std::fs::read_to_string(&path)?;
    Ok(serde_json::from_str::<Value>(&raw)?)
}

pub fn read_blackbox(id: &str) -> anyhow::Result<Value> {
    read_blackbox_in(&blackbox_dir(), id)
}

/// Capture a live core/router Blackbox snapshot into tmpfs (never writes to NAND flash).
pub async fn capture_blackbox(
    state: &Arc<AppState>,
    core: &CoreManager,
    reason: &str,
) -> anyhow::Result<BlackboxSummary> {
    let manual = reason.eq_ignore_ascii_case("manual");
    let now = unix_now_secs();
    {
        let mut wd = core.watchdog.lock().await;
        if !manual
            && let Some(&last_ts) = wd.last_blackbox_by_reason.get(reason)
            && now.saturating_sub(last_ts) < 60
        {
            anyhow::bail!("Blackbox rate-limited for reason '{reason}'");
        }
        wd.last_blackbox_by_reason.insert(reason.to_string(), now);
    }

    let core_up = state.live.read().await.core_running;
    if core_up {
        // Request a temporary 20s debug burst so logs capture immediate context without flash wear
        let _ = core.set_core_log_level("debug", Some(20)).await;
    }

    let (health, anomalies, flight_failures, recent_logs, config_state) = if core_up {
        tokio::join!(
            Box::pin(core.get_core_health()),
            Box::pin(core.get_core_anomalies()),
            Box::pin(core.get_core_flight_filtered(true, None, 30)),
            Box::pin(core.get_core_recent_logs("warn", 60)),
            Box::pin(core.get_core_config_state()),
        )
    } else {
        (
            Err(anyhow::anyhow!("core stopped")),
            Err(anyhow::anyhow!("core stopped")),
            Err(anyhow::anyhow!("core stopped")),
            Err(anyhow::anyhow!("core stopped")),
            Err(anyhow::anyhow!("core stopped")),
        )
    };

    let live_json = {
        let live = state.live.read().await;
        serde_json::to_value(&*live).unwrap_or_else(|_| json!({}))
    };
    let payload = json!({
        "live": live_json,
        "core_health": health.ok(),
        "anomalies": anomalies.ok(),
        "flight_failures": flight_failures.ok(),
        "recent_logs": recent_logs.ok(),
        "config_state": config_state.ok(),
    });

    let dir = blackbox_dir();
    let summary = write_blackbox_file_in(&dir, reason, payload)?;
    let updated_list = list_blackboxes_in(&dir);
    {
        let mut live = state.live.write().await;
        live.blackboxes = updated_list;
        live.push_event(
            if manual { "info" } else { "warn" },
            "blackbox",
            &format!("Captured tmpfs blackbox {} (reason: {reason})", summary.id),
        );
    }
    Ok(summary)
}

async fn rollback_lkg_and_apply(core: &CoreManager, reason: &str) -> anyhow::Result<bool> {
    core.auto_rollback_to_working_config(reason, None).await
}

#[inline(never)]
fn boxed_core_start(
    core: &CoreManager,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(core.start())
}

#[inline(never)]
fn boxed_core_reload(
    core: &CoreManager,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(core.apply_or_reload())
}

#[inline(never)]
fn boxed_capture_blackbox<'a>(
    core: &'a CoreManager,
    reason: &'a str,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<BlackboxSummary>> + Send + 'a>>
{
    Box::pin(capture_blackbox(&core.state, core, reason))
}

#[inline(never)]
fn boxed_rollback_lkg<'a>(
    core: &'a CoreManager,
    reason: &'a str,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<bool>> + Send + 'a>> {
    Box::pin(rollback_lkg_and_apply(core, reason))
}

#[inline(never)]
pub fn run_watchdog_tick_boxed(
    core: &CoreManager,
    core_alive: bool,
    tick_count: u64,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + '_>> {
    Box::pin(run_watchdog_tick(core, core_alive, tick_count))
}

#[inline(never)]
fn compute_desired_digest(store: &crate::store::RouterStoreData) -> String {
    config_gen::compile_core_config(store)
        .map(|mut v| {
            CoreManager::sanitize_candidate_local_rulesets(&mut v);
            compute_config_digest(&v)
        })
        .unwrap_or_default()
}

/// Evaluate live probes + `/tachyon/health` + `/tachyon/anomalies` + Flight Recorder failures
/// and execute deterministic L0-L5 self-healing actions under hysteresis & circuit-breaker protection.
pub async fn run_watchdog_tick(core: &CoreManager, core_alive: bool, _tick_count: u64) {
    let now = unix_now_secs();
    let (desired_digest, enable_watchdog) = {
        let store_guard = core.state.data.read().await;
        let enable = store_guard.settings.enable_watchdog;
        let digest = if core_alive && enable {
            compute_desired_digest(&store_guard)
        } else {
            String::new()
        };
        (digest, enable)
    };

    let bin_path_str = Box::pin(core.resolve_bin_path()).await;
    let binary_check = check_core_binary_integrity(Path::new(&bin_path_str));
    let (core_binary_ok, core_binary_error) = match &binary_check {
        Ok(()) => (true, String::new()),
        Err(e) => (false, e.clone()),
    };

    // Real WAN TCP connect + local DNS UDP A probes (parallel, short timeout, zero shell)
    let dns_target = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 42)), 53);
    let wan_targets = default_wan_targets();
    let ((wan_ok, wan_ms), (dns_probe_ok, dns_ms)) = tokio::join!(
        Box::pin(probe_wan_health(&wan_targets)),
        Box::pin(probe_local_dns_health(dns_target, "one.one.one.one"))
    );

    let (health_res, anomalies_res, flight_res) = if core_alive {
        tokio::join!(
            Box::pin(core.get_core_health()),
            Box::pin(core.get_core_anomalies()),
            Box::pin(core.get_core_flight_filtered(true, None, 20)),
        )
    } else {
        (
            Err(anyhow::anyhow!("core stopped")),
            Err(anyhow::anyhow!("core stopped")),
            Err(anyhow::anyhow!("core stopped")),
        )
    };

    let health_val = health_res.ok();
    let applied_digest = health_val
        .as_ref()
        .and_then(|h| h.pointer("/config_state/digest"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let config_ready = health_val
        .as_ref()
        .and_then(|h| h.pointer("/config_state/ready"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let config_drift = core_alive
        && config_ready
        && !desired_digest.is_empty()
        && !applied_digest.is_empty()
        && desired_digest != applied_digest;

    let pressure_level = health_val
        .as_ref()
        .and_then(|h| h.pointer("/memory/pressure_level"))
        .and_then(Value::as_str)
        .unwrap_or(if core_alive { "normal" } else { "stopped" })
        .to_string();
    let fd_open = health_val
        .as_ref()
        .and_then(|h| h.pointer("/fds/open"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let fd_limit = health_val
        .as_ref()
        .and_then(|h| h.pointer("/fds/soft_limit"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let reload_count = health_val
        .as_ref()
        .and_then(|h| h.get("reload_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let pool_purges = health_val
        .as_ref()
        .and_then(|h| h.pointer("/memory/pool_purges_total"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let inbound_cap_drops = health_val
        .as_ref()
        .and_then(|h| h.pointer("/connections/inbound_cap_drops"))
        .and_then(Value::as_u64)
        .unwrap_or(0);

    let fakeip_v4_used = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/fakeip/v4_used"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let fakeip_v4_cap = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/fakeip/v4_cap"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let fakeip_evictions = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/fakeip/evictions"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let udp_nat_active = health_val
        .as_ref()
        .and_then(|h| h.pointer("/udp_nat/active"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let udp_nat_evictions = health_val
        .as_ref()
        .and_then(|h| h.pointer("/udp_nat/evictions_total"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let dns_cache_entries = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/cache_entries"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let dns_cache_hits = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/cache_hits"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let dns_cache_misses = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/cache_misses"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let dns_upstream_errors: u64 = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/servers"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|s| s.get("errors_total").and_then(Value::as_u64).unwrap_or(0))
                .sum()
        })
        .unwrap_or(0);

    let outbound_health: Vec<OutboundHealthEntry> = health_val
        .as_ref()
        .and_then(|h| h.get("outbounds"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|o| OutboundHealthEntry {
                    tag: o
                        .get("tag")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    kind: o
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    dial_ok: o.get("dial_ok").and_then(Value::as_u64).unwrap_or(0),
                    dial_fail: o.get("dial_fail").and_then(Value::as_u64).unwrap_or(0),
                    ewma_handshake_ms: o
                        .get("ewma_handshake_ms")
                        .and_then(Value::as_u64)
                        .unwrap_or(0),
                    last_err_class: o
                        .get("last_err_class")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    last_err_detail: o
                        .get("last_err_detail")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    wg_up: o.get("wg_up").and_then(Value::as_bool),
                    wg_last_handshake_age_secs: o
                        .get("wg_last_handshake_age_secs")
                        .and_then(Value::as_u64),
                    selected: o
                        .get("selected")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default();

    let anomalies_count = anomalies_res
        .as_ref()
        .ok()
        .and_then(|a| a.get("count").and_then(Value::as_u64))
        .unwrap_or(0) as usize;
    let recent_flight_failures = flight_res
        .as_ref()
        .ok()
        .and_then(|f| f.get("count").and_then(Value::as_u64))
        .unwrap_or(0) as usize;

    let manual_stop = core.is_manually_stopped();
    let (
        wan_healthy,
        dns_healthy,
        core_hyst_healthy,
        wan_streak,
        dns_streak,
        core_streak,
        restarts_10m,
    ) = {
        let mut wd = core.watchdog.lock().await;
        let w = wd.wan.record(wan_ok);
        let d = wd.dns.record(core_alive && dns_probe_ok);
        let c = wd.core.record(core_alive || manual_stop);
        let r10 = wd.restarts_in_window(now);
        (
            w,
            d,
            c,
            wd.wan.fail_streak,
            wd.dns.fail_streak,
            wd.core.fail_streak,
            r10,
        )
    };

    let blackboxes = list_blackboxes();
    let mut wd_state_label = if manual_stop {
        "manual_stop"
    } else if !wan_healthy {
        "wan_down"
    } else if !core_hyst_healthy || !dns_healthy {
        "degraded"
    } else if config_drift {
        "config_drift"
    } else {
        "healthy"
    }
    .to_string();

    let lkg_observing = {
        let mut live = core.state.live.write().await;
        live.wan_healthy = wan_healthy;
        live.dns_healthy = dns_healthy;
        live.wan_probe_ms = wan_ms;
        live.dns_probe_ms = dns_ms;
        live.wan_fail_streak = wan_streak;
        live.dns_fail_streak = dns_streak;
        live.core_fail_streak = core_streak;
        live.core_pressure_level = pressure_level.clone();
        live.core_fd_open = fd_open;
        live.core_fd_limit = fd_limit;
        live.core_reload_count = reload_count;
        live.core_pool_purges = pool_purges;
        live.core_inbound_cap_drops = inbound_cap_drops;
        live.fakeip_v4_used = fakeip_v4_used;
        live.fakeip_v4_cap = fakeip_v4_cap;
        live.fakeip_evictions = fakeip_evictions;
        live.udp_nat_active = udp_nat_active;
        live.udp_nat_evictions = udp_nat_evictions;
        live.dns_cache_entries = dns_cache_entries;
        live.dns_cache_hits = dns_cache_hits;
        live.dns_cache_misses = dns_cache_misses;
        live.dns_upstream_errors = dns_upstream_errors;
        live.desired_config_digest = desired_digest;
        live.applied_config_digest = applied_digest;
        live.config_drift = config_drift;
        live.core_binary_ok = core_binary_ok;
        live.core_binary_error = core_binary_error.clone();
        live.watchdog_restarts_10m = restarts_10m;
        live.outbound_health = outbound_health;
        live.anomalies_count = anomalies_count;
        live.recent_flight_failures = recent_flight_failures;
        live.blackboxes = blackboxes;
        live.watchdog_state = wd_state_label.clone();
        live.lkg_observing
    };

    if !core_alive && !manual_stop {
        let store_snapshot = core.state.data.read().await.clone();
        let _ = net_stack::hold_kill_switch(&store_snapshot).await;
    }

    if !enable_watchdog || manual_stop {
        return;
    }

    // Escalation suppression: never restart core/DNS when WAN is down
    if !wan_healthy {
        let should_log = core
            .watchdog
            .lock()
            .await
            .cooldown_ready("wan_down_log", now, 60);
        if should_log {
            core.state.live.write().await.push_event(
                "warn",
                "watchdog",
                "WAN unreachable: suppressing core/DNS restart escalations",
            );
        }
        return;
    }

    let mut action_taken: Option<&'static str> = None;

    if !core_alive && !core_hyst_healthy {
        let data_dir = core
            .state
            .path
            .parent()
            .unwrap_or_else(|| Path::new("data"))
            .to_path_buf();
        let has_bin_backup = snapshots::read_backup_meta(&data_dir, "tachyon-core").is_some();

        if !core_binary_ok && has_bin_backup {
            let allow = core
                .watchdog
                .lock()
                .await
                .cooldown_ready("l5_bin_rollback", now, 60);
            if allow {
                let target_bin = PathBuf::from(&bin_path_str);
                let dd = data_dir.clone();
                let res = tokio::task::spawn_blocking(move || {
                    snapshots::rollback_binary(&dd, "tachyon-core", &target_bin)
                })
                .await;
                if matches!(res, Ok(Ok(_))) {
                    let _ = boxed_core_start(core).await;
                    action_taken = Some("L5_binary_rollback");
                    wd_state_label = "recovered_binary_rollback".to_string();
                }
            }
        } else if (lkg_observing
            || core.watchdog.lock().await.restarts_in_window(now)
                >= CIRCUIT_BREAKER_MAX_RESTARTS as u32)
            && core.state.lkg_path.exists()
        {
            let allow = core
                .watchdog
                .lock()
                .await
                .cooldown_ready("l4_lkg_rollback", now, 60);
            if allow {
                let _ = boxed_capture_blackbox(core, "core_crash_lkg_rollback").await;
                if boxed_rollback_lkg(
                    core,
                    "Автооткат watchdog: ядро остановилось после изменения конфига",
                )
                .await
                .is_ok()
                {
                    action_taken = Some("L4_lkg_rollback");
                    wd_state_label = "rolled_back_lkg".to_string();
                }
            }
        } else {
            let allow_restart =
                core.watchdog
                    .lock()
                    .await
                    .cooldown_ready("l3_core_restart", now, 20);
            if allow_restart {
                let _ = boxed_capture_blackbox(core, "core_down").await;
                let tripped = core.watchdog.lock().await.record_restart(now);
                if tripped && core.state.lkg_path.exists() {
                    if boxed_rollback_lkg(core, "Автооткат watchdog: частые перезапуски ядра")
                        .await
                        .is_ok()
                    {
                        action_taken = Some("L4_circuit_breaker_lkg_rollback");
                    }
                } else if boxed_core_start(core).await.is_ok() {
                    action_taken = Some("L3_core_restart");
                }
            }
        }
    } else if core_alive {
        if config_drift {
            let allow =
                core.watchdog
                    .lock()
                    .await
                    .cooldown_ready("l2_config_drift_reload", now, 45);
            if allow && boxed_core_reload(core).await.is_ok() {
                action_taken = Some("L2_config_drift_reload");
            }
        }

        if pressure_level == "critical"
            || (pressure_level == "elevated" && (dns_cache_entries > 4096 || fakeip_v4_used > 3000))
        {
            let allow = core
                .watchdog
                .lock()
                .await
                .cooldown_ready("l1_memory_trim", now, 60);
            if allow
                && Box::pin(core.clash_request("POST", "/tachyon/memory/trim", Some("{}")))
                    .await
                    .is_ok()
            {
                action_taken = Some("L1_memory_trim");
            }
        }

        if !dns_healthy {
            let last_flush = core.watchdog.lock().await.last_dns_flush_ts;
            if now.saturating_sub(last_flush) > 45 {
                let allow = core
                    .watchdog
                    .lock()
                    .await
                    .cooldown_ready("l1_dns_flush", now, 30);
                if allow {
                    core.watchdog.lock().await.last_dns_flush_ts = now;
                    let _ = boxed_capture_blackbox(core, "dns_unhealthy").await;
                    if Box::pin(core.flush_core_dns("all")).await.is_ok() {
                        action_taken = Some("L1_dns_flush");
                    }
                }
            } else if lkg_observing && core.state.lkg_path.exists() {
                let allow =
                    core.watchdog
                        .lock()
                        .await
                        .cooldown_ready("l4_dns_lkg_rollback", now, 60);
                if allow
                    && boxed_rollback_lkg(
                        core,
                        "Автооткат watchdog: сбой DNS после изменения конфига",
                    )
                    .await
                    .is_ok()
                {
                    action_taken = Some("L4_dns_lkg_rollback");
                }
            } else {
                let allow =
                    core.watchdog
                        .lock()
                        .await
                        .cooldown_ready("l3_dns_core_restart", now, 60);
                if allow {
                    let tripped = core.watchdog.lock().await.record_restart(now);
                    if !tripped && boxed_core_start(core).await.is_ok() {
                        action_taken = Some("L3_dns_core_restart");
                    }
                }
            }
        }
    }

    if let Some(action) = action_taken {
        {
            let mut wd = core.watchdog.lock().await;
            wd.last_escalation = action.to_string();
            wd.last_escalation_ts = now;
        }
        let mut live = core.state.live.write().await;
        live.watchdog_state = wd_state_label;
        live.watchdog_last_action = action.to_string();
        live.watchdog_last_action_ts = now;
        live.push_event(
            "warn",
            "watchdog",
            &format!("Watchdog action executed: {action}"),
        );
    }
}

#[inline(never)]
pub fn check_and_repair_nft_drift_boxed<'a>(
    state: &'a Arc<AppState>,
    watchdog_on: bool,
    core_alive: bool,
    proxy_mode: &'a str,
    nft_ok: bool,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
    Box::pin(check_and_repair_nft_drift(
        state,
        watchdog_on,
        core_alive,
        proxy_mode,
        nft_ok,
    ))
}

/// Apply nftables network stack safely if missing while `tachyon-core` is alive under `tproxy`,
/// or keep the fail-closed kill-switch shut when `tachyon-core` is absent.
pub async fn check_and_repair_nft_drift(
    state: &Arc<AppState>,
    watchdog_on: bool,
    core_alive: bool,
    proxy_mode: &str,
    nft_ok: bool,
) {
    if !watchdog_on {
        return;
    }
    if !core_alive {
        let store_snapshot = Box::new(state.data.read().await.clone());
        let _ = net_stack::hold_kill_switch(&store_snapshot).await;
        return;
    }
    if proxy_mode == "tproxy" && !nft_ok {
        let store_snapshot = Box::new(state.data.read().await.clone());
        let _ = Box::pin(net_stack::apply_network_stack(&store_snapshot)).await;
        state.live.write().await.push_event(
            "warn",
            "reconciler",
            "Repaired inet TachyonTable drift",
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[test]
    fn hysteresis_requires_sustained_failures_and_recovery() {
        let mut h = CheckHysteresis::new(3, 2);
        assert!(h.healthy);
        assert!(h.record(false));
        assert!(h.record(false));
        assert!(!h.record(false)); // 3rd consecutive failure flips state
        assert!(!h.record(true));
        assert!(h.record(true)); // 2nd consecutive ok restores state
        assert!(h.record(false));
        assert!(h.record(true)); // intermittent single fail keeps healthy
    }

    #[tokio::test]
    async fn probe_wan_health_succeeds_against_mock_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ok_addr = listener.local_addr().unwrap();
        let closed_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let closed_addr = closed_listener.local_addr().unwrap();
        drop(closed_listener);

        let accept_task =
            tokio::spawn(async move { while let Ok((_s, _)) = listener.accept().await {} });

        let (ok, ms) = probe_wan_health(&[closed_addr, ok_addr]).await;
        assert!(ok);
        assert!(ms < 1200);

        let (fail, _) = probe_wan_health(&[closed_addr]).await;
        assert!(!fail);
        accept_task.abort();
    }

    #[tokio::test]
    async fn probe_local_dns_health_validates_txid_and_rcode() {
        let sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let dns_addr = sock.local_addr().unwrap();
        let server_task = tokio::spawn(async move {
            let mut buf = [0u8; 512];
            for rcode in [0u8, 2u8] {
                if let Ok((n, peer)) = sock.recv_from(&mut buf).await
                    && n >= 12
                {
                    let mut resp = vec![0u8; 12];
                    resp[0] = buf[0];
                    resp[1] = buf[1];
                    resp[2] = 0x81; // QR=1, RD=1
                    resp[3] = 0x80 | rcode;
                    let _ = sock.send_to(&resp, peer).await;
                }
            }
        });

        let (ok, _) = probe_local_dns_health(dns_addr, "example.com").await;
        assert!(ok);
        let (servfail_ok, _) = probe_local_dns_health(dns_addr, "example.com").await;
        assert!(!servfail_ok);
        server_task.abort();
    }

    #[test]
    fn binary_integrity_rejects_scripts_and_small_files() {
        let dir = std::env::temp_dir().join(format!("tachyon-bin-chk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let script = dir.join("script-wrapper");
        std::fs::write(&script, vec![b'#'; 70_000]).unwrap();
        std::fs::write(&script, {
            let mut b = b"#!/bin/sh\necho hi\n".to_vec();
            b.resize(70_000, b' ');
            b
        })
        .unwrap();
        assert!(check_core_binary_integrity(&script).is_err());

        let tiny = dir.join("tiny-bin");
        let mut tiny_bytes = if cfg!(target_os = "linux") {
            b"\x7fELF".to_vec()
        } else {
            b"MZ\x90\x00".to_vec()
        };
        tiny_bytes.resize(1024, 0);
        std::fs::write(&tiny, tiny_bytes).unwrap();
        assert!(check_core_binary_integrity(&tiny).is_err());

        let valid = dir.join("valid-bin");
        let mut valid_bytes = if cfg!(target_os = "linux") {
            b"\x7fELF".to_vec()
        } else {
            b"MZ\x90\x00".to_vec()
        };
        valid_bytes.resize(70_000, 0);
        std::fs::write(&valid, valid_bytes).unwrap();
        assert!(check_core_binary_integrity(&valid).is_ok());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn blackbox_rotates_to_max_five_redacts_secrets_and_blocks_traversal() {
        let dir = std::env::temp_dir().join(format!("tachyon-bb-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut last_id = String::new();
        for i in 0..7 {
            let summary = write_blackbox_file_in(
                &dir,
                &format!("reason_{i}"),
                json!({
                    "api_key": "sk-secret-value-12345",
                    "note": "Authorization: Bearer supersecret999"
                }),
            )
            .unwrap();
            last_id = summary.id;
            std::thread::sleep(Duration::from_millis(12));
        }

        let listed = list_blackboxes_in(&dir);
        assert_eq!(listed.len(), MAX_BLACKBOX_FILES);

        let loaded = read_blackbox_in(&dir, &last_id).unwrap();
        let text = loaded.to_string();
        assert!(!text.contains("sk-secret-value-12345"));
        assert!(!text.contains("supersecret999"));

        assert!(read_blackbox_in(&dir, "../etc/passwd").is_err());
        assert!(read_blackbox_in(&dir, "bad/id").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn watchdog_circuit_breaker_trips_past_four_restarts() {
        let mut wd = WatchdogState::default();
        let base = 1_700_000_000;
        assert!(!wd.record_restart(base));
        assert!(!wd.record_restart(base + 10));
        assert!(!wd.record_restart(base + 20));
        assert!(!wd.record_restart(base + 30));
        assert!(wd.record_restart(base + 40)); // 5th within 600s trips circuit breaker
        assert!(!wd.record_restart(base + 1000)); // old entries pruned after >600s
    }
}
