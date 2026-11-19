//! Persistent state and data models for `tachyon` (Pure-Rust OpenWrt Router Orchestrator).
//!
//! Designed for minimal memory footprint (<1.5 MB in-memory state) and zero NAND flash wear:
//! configuration writes pass through `write_json_if_changed`, and all runtime telemetry rings/maps
//! have strict capacity caps and automatic TTL eviction.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::RwLock;

use crate::config_gen;
use crate::crypto_gen;
use crate::sys_info::{LanDevice, ProcessIdentity};

pub const MAX_THROUGHPUT_POINTS: usize = 60;
pub const MAX_RECENT_LOGS: usize = 150;
pub const MAX_EVENTS_RING: usize = 200;
pub const MAX_HONEYPOT_HITS: usize = 100;
pub const MAX_HONEYPOT_STRIKES: usize = 2048;
pub const MAX_SESSIONS: usize = 64;
pub const MAX_NODE_LATENCIES: usize = 2048;
pub const MAX_JOBS: usize = 16;
pub const LEGACY_UCI_BACKUP_PATH: &str = "/etc/tachyon/backup-pre-2.0/tachyon.uci";
pub const LEGACY_UCI_IMPORTED_MIGRATION: &str = "legacy_uci_imported_v1";

#[cfg(any(not(target_has_atomic = "64"), test))]
struct FallbackAtomicU64(std::sync::Mutex<u64>);

#[cfg(any(not(target_has_atomic = "64"), test))]
impl FallbackAtomicU64 {
    const fn new(val: u64) -> Self {
        Self(std::sync::Mutex::new(val))
    }

    fn load(&self, _order: Ordering) -> u64 {
        *self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn store(&self, val: u64, _order: Ordering) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = val;
    }

    fn fetch_add(&self, val: u64, _order: Ordering) -> u64 {
        let mut guard = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let prev = *guard;
        *guard = prev.wrapping_add(val);
        prev
    }
}

/// Drop-in `AtomicU64` wrapper that uses native `std::sync::atomic::AtomicU64`
/// when `target_has_atomic = "64"` and falls back to `Mutex<u64>` on MIPS32.
pub struct PortableAtomicU64(
    #[cfg(target_has_atomic = "64")] std::sync::atomic::AtomicU64,
    #[cfg(not(target_has_atomic = "64"))] FallbackAtomicU64,
);

impl Default for PortableAtomicU64 {
    fn default() -> Self {
        Self::new(0)
    }
}

impl PortableAtomicU64 {
    pub const fn new(val: u64) -> Self {
        #[cfg(target_has_atomic = "64")]
        {
            Self(std::sync::atomic::AtomicU64::new(val))
        }
        #[cfg(not(target_has_atomic = "64"))]
        {
            Self(FallbackAtomicU64::new(val))
        }
    }

    pub fn load(&self, order: Ordering) -> u64 {
        self.0.load(order)
    }

    pub fn store(&self, val: u64, order: Ordering) {
        self.0.store(val, order);
    }

    pub fn fetch_add(&self, val: u64, order: Ordering) -> u64 {
        self.0.fetch_add(val, order)
    }
}

/// Effective Tachyon daemon version (supports prerelease SemVer via `TACHYON_BUILD_VERSION`).
pub const TACHYON_VERSION: &str = match option_env!("TACHYON_BUILD_VERSION") {
    Some(v) if !v.is_empty() => v,
    _ => env!("CARGO_PKG_VERSION"),
};

pub fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Decodes subscription header metadata (`profile-title`, `announce`) that carries a
/// `base64:` prefix (standard or URL-safe base64, padded or unpadded) into UTF-8 text.
/// Returns the original string untouched if it has no `base64:` prefix or fails to decode.
pub fn decode_sub_header_value(raw: &str) -> String {
    let trimmed = raw.trim();
    let Some(prefix) = trimmed.get(..7) else {
        return raw.to_string();
    };
    if !prefix.eq_ignore_ascii_case("base64:") {
        return raw.to_string();
    }
    let payload = trimmed[7..].trim();
    if payload.is_empty() {
        return raw.to_string();
    }
    let try_decode = |s: &str| {
        base64::engine::general_purpose::STANDARD
            .decode(s)
            .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(s))
            .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(s))
            .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s))
    };
    let decoded = try_decode(payload).or_else(|_| {
        let compact: String = payload
            .chars()
            .filter(|c| !c.is_ascii_whitespace())
            .collect();
        try_decode(&compact)
    });
    match decoded {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(text) => text,
            Err(_) => raw.to_string(),
        },
        Err(_) => raw.to_string(),
    }
}

fn default_true() -> bool {
    true
}

fn default_ui_mode() -> String {
    "simple".to_string()
}

fn default_ipv6_mode() -> String {
    "auto".to_string()
}

fn default_tun_inet4() -> String {
    "172.19.0.1/30".to_string()
}

pub fn normalize_ui_mode(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "advanced" => "advanced".to_string(),
        "simple" | "basic" | "" => "simple".to_string(),
        _ => "simple".to_string(),
    }
}

pub fn normalize_ipv6_mode(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "off" | "disabled" | "disable" | "0" | "false" | "no" | "leak_guard" | "ipv4_only"
        | "ipv4" => "off".to_string(),
        "dual_stack" | "full" | "1" | "true" | "yes" | "on" | "ipv4_ipv6" => {
            "dual_stack".to_string()
        }
        "tunnel_over_v4" | "v6_over_v4" => "tunnel_over_v4".to_string(),
        "auto" | "" => "auto".to_string(),
        _ => "auto".to_string(),
    }
}

pub fn normalize_dns_strategy(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "ipv4_only" => "ipv4_only".to_string(),
        "prefer_ipv4" | "" => "prefer_ipv4".to_string(),
        "prefer_ipv6" => "prefer_ipv6".to_string(),
        "ipv6_only" => "ipv6_only".to_string(),
        _ => "prefer_ipv4".to_string(),
    }
}

pub fn normalize_tcp_profile(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "auto" | "windows" | "macos" | "ios" | "android" | "linux" | "default" => {
            raw.trim().to_ascii_lowercase()
        }
        _ => String::new(),
    }
}

pub fn sanitize_cache_path(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.starts_with("/tmp/") || trimmed.starts_with("/var/run/") {
        trimmed.to_string()
    } else {
        "/tmp/tachyon-core/cache.db".to_string()
    }
}

fn default_sidebar_pos() -> String {
    "left".to_string()
}

fn default_accent_theme() -> String {
    "blue".to_string()
}

fn default_lang() -> String {
    "ru".to_string()
}

fn default_dashboard_preset() -> String {
    "standard".to_string()
}

fn default_proxy_mode() -> String {
    "tproxy".to_string()
}

fn default_tun_iface() -> String {
    "tun0".to_string()
}

fn default_tun_stack() -> String {
    "mixed".to_string()
}

fn default_tun_mtu() -> u16 {
    9000
}

fn default_dns_type() -> String {
    "doh".to_string()
}

fn default_dns_strategy() -> String {
    "prefer_ipv4".to_string()
}

fn default_dns_ttl() -> u32 {
    60
}

fn default_latency_url() -> String {
    "https://www.gstatic.com/generate_204".to_string()
}

fn default_log_level() -> String {
    "warn".to_string()
}

fn default_sub_format() -> String {
    "base64".to_string()
}

fn default_sub_title() -> String {
    "Tachyon Router".to_string()
}

fn default_tab_name() -> String {
    "dashboard".to_string()
}

fn default_routing_strategy() -> String {
    "split".to_string()
}

fn default_quiet_start() -> String {
    "23:00".to_string()
}

fn default_quiet_end() -> String {
    "07:00".to_string()
}

fn default_tunnel_section_name() -> String {
    "Main".to_string()
}

fn default_tun_udp_timeout() -> String {
    "5m".to_string()
}

fn default_tcp_profile() -> String {
    "default".to_string()
}

fn default_threshold_3() -> u32 {
    3
}

fn default_threshold_2() -> u32 {
    2
}

fn default_threshold_5() -> u32 {
    5
}

fn default_interval_60() -> u32 {
    60
}

fn default_interval_180() -> u32 {
    180
}

fn deserialize_string_or_number<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = serde_json::Value::deserialize(deserializer)?;
    match v {
        serde_json::Value::Null => Ok(String::new()),
        serde_json::Value::String(s) => Ok(s),
        serde_json::Value::Number(n) => Ok(n.to_string()),
        serde_json::Value::Bool(b) => Ok(if b { "1" } else { "0" }.to_string()),
        _ => Ok(String::new()),
    }
}

fn default_retention_24() -> u32 {
    24
}

fn default_dns_check_interval() -> String {
    "30s".to_string()
}

fn default_dns_rec_interval() -> String {
    "60s".to_string()
}

fn default_dns_check_timeout() -> String {
    "5s".to_string()
}

fn default_fakeip_v4() -> String {
    "198.18.0.0/15".to_string()
}

fn default_fakeip_v6() -> String {
    "fc00::/18".to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffectiveIpv6State {
    Disabled,
    LeakGuard,
    TunnelOverV4,
    Full,
}

impl EffectiveIpv6State {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::LeakGuard => "leak_guard",
            Self::TunnelOverV4 => "tunnel_over_v4",
            Self::Full => "full",
        }
    }

    pub fn is_active(self) -> bool {
        matches!(self, Self::TunnelOverV4 | Self::Full)
    }

    pub fn is_leak_guard(self) -> bool {
        matches!(self, Self::LeakGuard)
    }

    pub fn is_tunnel_over_v4(self) -> bool {
        matches!(self, Self::TunnelOverV4)
    }
}

pub fn parse_ipv6_cidr(raw: &str) -> Option<(u128, u8)> {
    let s = raw.trim();
    let (ip_str, prefix_len) = match s.split_once('/') {
        Some((ip, plen)) => (ip.trim(), plen.trim().parse::<u8>().ok()?),
        None => (s, 128u8),
    };
    if prefix_len > 128 {
        return None;
    }
    let ip: std::net::Ipv6Addr = ip_str.parse().ok()?;
    let mask = if prefix_len == 0 {
        0u128
    } else {
        !0u128 << (128 - prefix_len as u32)
    };
    Some((u128::from(ip) & mask, prefix_len))
}

pub fn cidr_v6_overlaps(a: &str, b: &str) -> bool {
    let Some((net_a, len_a)) = parse_ipv6_cidr(a) else {
        return false;
    };
    let Some((net_b, len_b)) = parse_ipv6_cidr(b) else {
        return false;
    };
    let min_len = len_a.min(len_b);
    if min_len == 0 {
        return true;
    }
    let mask = !0u128 << (128 - min_len as u32);
    (net_a & mask) == (net_b & mask)
}

/// Parse an IPv4 CIDR string (`a.b.c.d/prefix` or bare `a.b.c.d` -> `/32`)
/// into `(masked_network_u32, prefix_len)`.
pub fn parse_ipv4_cidr(raw: &str) -> Option<(u32, u8)> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    let (ip_str, prefix_len) = match s.split_once('/') {
        Some((ip, plen)) => {
            let plen_trim = plen.trim();
            if plen_trim.is_empty() || !plen_trim.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            (ip.trim(), plen_trim.parse::<u8>().ok()?)
        }
        None => (s, 32u8),
    };
    if prefix_len > 32 {
        return None;
    }
    let ip: std::net::Ipv4Addr = ip_str.parse().ok()?;
    let mask = if prefix_len == 0 {
        0u32
    } else {
        !0u32 << (32 - prefix_len as u32)
    };
    Some((u32::from(ip) & mask, prefix_len))
}

/// Return true if two valid IPv4 CIDRs overlap.
pub fn cidr_v4_overlaps(a: &str, b: &str) -> bool {
    let Some((net_a, len_a)) = parse_ipv4_cidr(a) else {
        return false;
    };
    let Some((net_b, len_b)) = parse_ipv4_cidr(b) else {
        return false;
    };
    let min_len = len_a.min(len_b);
    if min_len == 0 {
        return true;
    }
    let mask = !0u32 << (32 - min_len as u32);
    (net_a & mask) == (net_b & mask)
}

/// Return true if two CIDRs of the same address family overlap.
pub fn cidrs_overlap(a: &str, b: &str) -> bool {
    cidr_v4_overlaps(a, b) || cidr_v6_overlaps(a, b)
}

/// Canonicalize an IPv4 or IPv6 CIDR by zeroing host bits.
pub fn mask_cidr(raw: &str) -> Option<String> {
    if let Some((net, len)) = parse_ipv4_cidr(raw) {
        return Some(format!("{}/{}", std::net::Ipv4Addr::from(net), len));
    }
    if let Some((net, len)) = parse_ipv6_cidr(raw) {
        return Some(format!("{}/{}", std::net::Ipv6Addr::from(net), len));
    }
    None
}

/// Return true if `raw` is a valid IPv4 address, IPv6 address, or IPv6 link-local
/// address with a `%zone` interface suffix.
pub fn valid_ip_with_zone(raw: &str) -> bool {
    let s = raw.trim();
    if s.is_empty() || s.contains('/') {
        return false;
    }
    if let Some((addr, zone)) = s.split_once('%') {
        if addr.is_empty() || zone.is_empty() || zone.len() > 32 || zone.contains('%') {
            return false;
        }
        if !zone
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
        {
            return false;
        }
        return addr.parse::<std::net::Ipv6Addr>().is_ok();
    }
    s.parse::<std::net::IpAddr>().is_ok()
}

/// Return true if `ip_str` belongs to `cidr_str` (same family).
pub fn ip_in_cidr(ip_str: &str, cidr_str: &str) -> bool {
    let ip_clean = ip_str.trim();
    if ip_clean.is_empty() || ip_clean.contains('/') {
        return false;
    }
    if ip_clean.contains('%') && !valid_ip_with_zone(ip_clean) {
        return false;
    }
    let ip_no_zone = ip_clean.split_once('%').map_or(ip_clean, |(a, _)| a);
    let Ok(ip) = ip_no_zone.parse::<std::net::IpAddr>() else {
        return false;
    };
    match ip {
        std::net::IpAddr::V4(v4) => {
            let Some((net, len)) = parse_ipv4_cidr(cidr_str) else {
                return false;
            };
            let mask = if len == 0 {
                0u32
            } else {
                !0u32 << (32 - len as u32)
            };
            (u32::from(v4) & mask) == net
        }
        std::net::IpAddr::V6(v6) => {
            let Some((net, len)) = parse_ipv6_cidr(cidr_str) else {
                return false;
            };
            let mask = if len == 0 {
                0u128
            } else {
                !0u128 << (128 - len as u32)
            };
            (u128::from(v6) & mask) == net
        }
    }
}

pub fn runtime_state_dir() -> std::path::PathBuf {
    #[cfg(not(test))]
    {
        let var_run = std::path::Path::new("/var/run/tachyon");
        if var_run.is_dir() || std::fs::create_dir_all(var_run).is_ok() {
            return var_run.to_path_buf();
        }
        let tmp_dir = std::path::Path::new("/tmp/tachyon-rs");
        if tmp_dir.is_dir() || std::fs::create_dir_all(tmp_dir).is_ok() {
            return tmp_dir.to_path_buf();
        }
    }
    let fallback = std::env::temp_dir().join("tachyon-rs");
    let _ = std::fs::create_dir_all(&fallback);
    fallback
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RuntimeIpv6Cache {
    pub wan6_available: bool,
    pub wan_ipv6: Vec<String>,
    pub lan_ipv6: Vec<String>,
    pub wan6_prefixes: Vec<String>,
    pub updated_at: i64,
}

#[cfg(all(target_os = "linux", not(test)))]
fn is_non_tunnel_ifname(ifname: &str) -> bool {
    let lower = ifname.to_ascii_lowercase();
    lower != "lo"
        && !lower.starts_with("tun")
        && !lower.starts_with("tap")
        && !lower.starts_with("tailscale")
        && !lower.starts_with("fptn")
        && !lower.starts_with("wg")
        && !lower.starts_with("awg")
        && !lower.starts_with("utun")
}

#[cfg(all(target_os = "linux", not(test)))]
fn parse_proc_if_inet6_line(line: &str) -> Option<(std::net::Ipv6Addr, u8, u8, String)> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 6 || parts[0].len() != 32 {
        return None;
    }
    let raw = u128::from_str_radix(parts[0], 16).ok()?;
    let plen = u8::from_str_radix(parts[2], 16).ok()?;
    let scope = u8::from_str_radix(parts[3], 16).ok()?;
    let ifname = parts[5].to_string();
    Some((std::net::Ipv6Addr::from(raw), plen.min(128), scope, ifname))
}

#[cfg(all(target_os = "linux", not(test)))]
fn is_global_routable_v6(ip: &std::net::Ipv6Addr) -> bool {
    let segs = ip.segments();
    // 2000::/3 global unicast, excluding 2001:db8::/32 docs and 2001:20::/28 ORCHIDv2
    let is_global_unicast = (segs[0] & 0xe000) == 0x2000;
    let is_doc = segs[0] == 0x2001 && segs[1] == 0x0db8;
    let is_orchid = segs[0] == 0x2001 && (segs[1] & 0xfff0) == 0x0020;
    is_global_unicast && !is_doc && !is_orchid
}

pub fn probe_wan6_runtime_state() -> RuntimeIpv6Cache {
    #[cfg_attr(not(all(target_os = "linux", not(test))), allow(unused_mut))]
    let mut cache = RuntimeIpv6Cache {
        updated_at: unix_now_secs(),
        ..Default::default()
    };
    #[cfg(all(target_os = "linux", not(test)))]
    {
        let mut wan_addrs = Vec::new();
        let mut lan_addrs = Vec::new();
        let mut prefixes = Vec::new();
        if let Ok(raw_if6) = std::fs::read_to_string("/proc/net/if_inet6") {
            for line in raw_if6.lines() {
                let Some((ip, plen, scope, ifname)) = parse_proc_if_inet6_line(line) else {
                    continue;
                };
                if scope != 0 || !is_non_tunnel_ifname(&ifname) || !is_global_routable_v6(&ip) {
                    continue;
                }
                let lower_if = ifname.to_ascii_lowercase();
                let is_lan = lower_if == "br-lan"
                    || lower_if.starts_with("br-")
                    || lower_if.starts_with("lan");
                if is_lan {
                    if !lan_addrs.contains(&ip.to_string()) {
                        lan_addrs.push(ip.to_string());
                    }
                    if plen <= 64 {
                        let mask = if plen == 0 {
                            0u128
                        } else {
                            !0u128 << (128 - plen as u32)
                        };
                        let net = std::net::Ipv6Addr::from(u128::from(ip) & mask);
                        let pfx = format!("{net}/{plen}");
                        if !prefixes.contains(&pfx) {
                            prefixes.push(pfx);
                        }
                    }
                } else {
                    let s = ip.to_string();
                    if !wan_addrs.contains(&s) {
                        wan_addrs.push(s);
                    }
                }
            }
        }
        let mut has_default_v6_route = false;
        if let Ok(raw_rt6) = std::fs::read_to_string("/proc/net/ipv6_route") {
            for line in raw_rt6.lines() {
                let cols: Vec<&str> = line.split_whitespace().collect();
                if cols.len() >= 10
                    && cols[0] == "00000000000000000000000000000000"
                    && cols[1] == "00"
                    && is_non_tunnel_ifname(cols[9])
                {
                    has_default_v6_route = true;
                    break;
                }
            }
        }
        cache.wan6_available =
            !wan_addrs.is_empty() || !lan_addrs.is_empty() || has_default_v6_route;
        cache.wan_ipv6 = wan_addrs;
        cache.lan_ipv6 = lan_addrs;
        cache.wan6_prefixes = prefixes;
        let path = runtime_state_dir().join("ipv6-state.json");
        let _ = crate::crypto_gen::write_json_if_changed(path, &cache);
    }
    cache
}

pub fn load_cached_wan6_runtime_state() -> RuntimeIpv6Cache {
    let path = runtime_state_dir().join("ipv6-state.json");
    if let Ok(raw) = std::fs::read_to_string(&path)
        && let Ok(parsed) = serde_json::from_str::<RuntimeIpv6Cache>(&raw)
    {
        return parsed;
    }
    RuntimeIpv6Cache::default()
}

pub fn detect_wan6_runtime_available() -> bool {
    #[cfg(test)]
    {
        false
    }
    #[cfg(not(test))]
    {
        probe_wan6_runtime_state().wan6_available
    }
}

pub fn resolve_effective_ipv6_state(
    settings: &GlobalSettings,
    wan6_available: bool,
) -> EffectiveIpv6State {
    match normalize_ipv6_mode(&settings.ipv6_mode).as_str() {
        "off" => {
            if settings.ipv6_leak_guard {
                EffectiveIpv6State::LeakGuard
            } else {
                EffectiveIpv6State::Disabled
            }
        }
        "dual_stack" => EffectiveIpv6State::Full,
        "tunnel_over_v4" => EffectiveIpv6State::TunnelOverV4,
        _ => {
            // In "auto" mode: active when upstream WAN6 exists, or when legacy callers/tests
            // explicitly set `settings.enable_ipv6 = true`.
            if wan6_available || settings.enable_ipv6 {
                EffectiveIpv6State::Full
            } else if settings.ipv6_leak_guard {
                EffectiveIpv6State::LeakGuard
            } else {
                EffectiveIpv6State::Disabled
            }
        }
    }
}

pub fn effective_dns_strategy(settings: &GlobalSettings, ipv6_state: EffectiveIpv6State) -> String {
    if !ipv6_state.is_active() {
        "ipv4_only".to_string()
    } else {
        normalize_dns_strategy(&settings.dns_strategy)
    }
}

pub fn effective_tun_inet4(settings: &GlobalSettings) -> String {
    let t = settings.tun_inet4.trim();
    if t.is_empty() {
        "172.19.0.1/30".to_string()
    } else {
        t.to_string()
    }
}

pub fn effective_tun_inet6(
    settings: &GlobalSettings,
    ipv6_state: EffectiveIpv6State,
) -> Option<String> {
    if !ipv6_state.is_active() {
        return None;
    }
    let fakeip_v6 = if settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        settings.fakeip_inet6_range.trim()
    };
    let configured = settings.tun_inet6.trim();
    if !configured.is_empty() && !cidr_v6_overlaps(configured, fakeip_v6) {
        return Some(configured.to_string());
    }
    let fallback = "fdfe:dcba:9876::1/126";
    if !cidr_v6_overlaps(fallback, fakeip_v6) {
        Some(fallback.to_string())
    } else {
        Some("fd99:7ac4:9001::1/126".to_string())
    }
}

fn default_sub_engine() -> String {
    "core".to_string()
}

fn default_comp_check_int() -> String {
    "12h".to_string()
}

fn default_auto_upd_mode() -> String {
    "immediate".to_string()
}

fn default_auto_upd_time() -> String {
    "04:00".to_string()
}

fn default_latency_mode() -> String {
    "standard".to_string()
}

fn default_engine_variant() -> String {
    "tachyon-core".to_string()
}

fn default_qos_engine() -> String {
    "auto".to_string()
}

fn default_off_str() -> String {
    "off".to_string()
}

fn default_auto_str() -> String {
    "auto".to_string()
}

pub fn normalize_auto_mode(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => "1".to_string(),
        "0" | "false" | "no" | "off" => "0".to_string(),
        _ => "auto".to_string(),
    }
}

/// Enabled sections whose traffic is captured/proxied and set `fail_policy = "block"`.
/// Actions that never proxy (`bypass`, `block`, `dns`, `hosts`) never trigger router-wide Fail-Closed.
pub fn is_fail_closed_section(sec: &RoutingSection) -> bool {
    if !sec.enabled {
        return false;
    }
    let act = sec.action.trim().to_ascii_lowercase();
    if matches!(act.as_str(), "bypass" | "block" | "dns" | "hosts") {
        return false;
    }
    sec.fail_policy.trim().eq_ignore_ascii_case("block")
}

pub fn has_fail_closed_section(store: &RouterStoreData) -> bool {
    store.sections.iter().any(is_fail_closed_section)
}

fn effective_auto_flag(flag: bool, mode: &str, fail_closed: bool) -> bool {
    if flag {
        return true;
    }
    match mode.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => true,
        "0" | "false" | "no" | "off" => false,
        _ => fail_closed,
    }
}

pub fn effective_dns_intercept_all(store: &RouterStoreData) -> bool {
    effective_auto_flag(
        store.settings.dns_intercept_all,
        &store.settings.dns_intercept_all_mode,
        has_fail_closed_section(store),
    )
}

pub fn effective_webrtc_leak_protect(store: &RouterStoreData) -> bool {
    effective_auto_flag(
        store.settings.webrtc_leak_protect,
        &store.settings.webrtc_leak_protect_mode,
        has_fail_closed_section(store),
    )
}

fn default_snapshot_max() -> u32 {
    10
}

fn default_session_ttl() -> u32 {
    86_400
}

fn default_ai_temp() -> f32 {
    0.3
}

fn default_ai_max_tokens() -> u32 {
    2048
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalSettings {
    pub config_version: String,
    pub listen_addr: String,
    pub listen_port: u16,
    pub web_base_path: String,
    pub admin_user: String,
    pub admin_pass_hash: String,
    pub admin_pass_salt: String,
    pub session_secret: String,
    #[serde(default = "default_ui_mode")]
    pub ui_mode: String,
    #[serde(default)]
    pub lite_mode: bool,
    #[serde(default = "default_sidebar_pos")]
    pub sidebar_pos: String,
    #[serde(default)]
    pub sidebar_collapsed: bool,
    #[serde(default = "default_accent_theme", alias = "theme_accent")]
    pub accent_theme: String,
    #[serde(default = "default_lang")]
    pub lang: String,
    #[serde(default = "default_tab_name")]
    pub default_tab: String,
    #[serde(default = "default_dashboard_preset")]
    pub dashboard_preset: String,
    #[serde(default)]
    pub dashboard_widgets_json: String,
    #[serde(default)]
    pub studio_views_json: String,
    #[serde(default)]
    pub tab_order: Vec<String>,
    #[serde(default)]
    pub hidden_tabs: Vec<String>,
    #[serde(default = "default_true")]
    pub show_tab_dashboard: bool,
    #[serde(default = "default_true")]
    pub show_tab_section: bool,
    #[serde(default = "default_true")]
    pub show_tab_server: bool,
    #[serde(default = "default_true")]
    pub show_tab_profile: bool,
    #[serde(default = "default_true")]
    pub show_tab_schedule: bool,
    #[serde(default = "default_true")]
    pub show_tab_guest_mode: bool,
    #[serde(default = "default_true")]
    pub show_tab_local_devices: bool,
    #[serde(default = "default_true")]
    pub show_tab_monitoring: bool,
    #[serde(default = "default_true")]
    pub show_tab_diagnostic: bool,
    #[serde(default = "default_true")]
    pub show_tab_updates: bool,
    #[serde(default = "default_true")]
    pub show_tab_telegram: bool,

    pub core_bin_path: String,
    pub core_config_path: String,
    pub cache_path: String,
    pub rulesets_dir: String,
    pub clash_api_addr: String,
    pub clash_api_secret: String,
    #[serde(default)]
    pub agent_api_token: String,

    #[serde(default = "default_routing_strategy")]
    pub routing_strategy: String,
    #[serde(default = "default_tunnel_section_name")]
    pub default_tunnel_section: String,
    #[serde(default = "default_proxy_mode")]
    pub proxy_mode: String,
    #[serde(default = "default_tun_iface")]
    pub tun_interface: String,
    #[serde(default = "default_tun_stack")]
    pub tun_stack: String,
    #[serde(default = "default_true")]
    pub tun_auto_route: bool,
    #[serde(default = "default_tun_mtu")]
    pub tun_mtu: u16,
    #[serde(default = "default_tun_inet4")]
    pub tun_inet4: String,
    #[serde(default)]
    pub tun_inet6: String,
    #[serde(default)]
    pub tun_gso: bool,
    #[serde(default = "default_true")]
    pub tun_endpoint_independent_nat: bool,
    #[serde(default = "default_tun_udp_timeout")]
    pub tun_udp_timeout: String,
    #[serde(default = "default_true")]
    pub tun_kill_switch: bool,
    #[serde(default, alias = "sqm_enabled")]
    pub smart_queue: bool,
    #[serde(default)]
    pub sqm_download_kbps: u32,
    #[serde(default)]
    pub sqm_upload_kbps: u32,
    #[serde(default)]
    pub sqm_interface: String,
    #[serde(default = "default_tcp_profile")]
    pub tcp_profile: String,
    #[serde(default = "default_true")]
    pub tcp_bbr: bool,
    #[serde(default = "default_true")]
    pub selector_auto_failover: bool,
    pub source_network_interfaces: Vec<String>,
    #[serde(default)]
    pub enable_output_network_interface: bool,
    #[serde(default)]
    pub excluded_ips: Vec<String>,
    #[serde(default)]
    pub output_network_interface: String,
    #[serde(default)]
    pub enable_badwan_interface_monitoring: bool,
    #[serde(default)]
    pub badwan_monitored_interfaces: Vec<String>,
    #[serde(default = "default_threshold_5")]
    pub badwan_reload_delay: u32,
    #[serde(default = "default_ipv6_mode")]
    pub ipv6_mode: String,
    #[serde(default = "default_true")]
    pub ipv6_leak_guard: bool,
    #[serde(default)]
    pub enable_ipv6: bool,
    #[serde(default = "default_true")]
    pub enable_yacd: bool,
    #[serde(default)]
    pub enable_yacd_wan_access: bool,
    #[serde(default)]
    pub yacd_secret_key: String,
    #[serde(default)]
    pub disable_quic: bool,
    #[serde(default = "default_off_str")]
    pub disable_quic_mode: String,
    #[serde(default)]
    pub block_doh: bool,
    #[serde(default)]
    pub dns_intercept_all: bool,
    #[serde(default = "default_auto_str")]
    pub dns_intercept_all_mode: String,
    #[serde(default)]
    pub webrtc_leak_protect: bool,
    #[serde(default = "default_auto_str")]
    pub webrtc_leak_protect_mode: String,
    #[serde(default)]
    pub route_router_traffic: bool,
    #[serde(default)]
    pub route_router_traffic_section: String,
    #[serde(default)]
    pub wifi_calling_direct: bool,
    #[serde(default, alias = "torrent_isolation")]
    pub isolate_p2p: bool,
    #[serde(default = "default_off_str")]
    pub bittorrent_policy: String,
    #[serde(default)]
    pub p2p_ports: String,
    #[serde(default)]
    pub direct_bypass_enabled: bool,
    #[serde(default)]
    pub direct_bypass_port: u16,
    #[serde(default, alias = "console_gaming_mode")]
    pub game_console_optimizer: bool,
    #[serde(default)]
    pub game_console_ips: Vec<String>,
    #[serde(default)]
    pub exclude_ntp: bool,
    #[serde(default)]
    pub dont_touch_dhcp: bool,
    #[serde(default, alias = "torrserver_direct")]
    pub torrserver_direct_enabled: bool,
    #[serde(default)]
    pub torrserver_ports: Vec<u16>,
    #[serde(default)]
    pub tailscale_enabled: bool,
    #[serde(default = "default_auto_str")]
    pub tailscale_web_access: String,

    #[serde(default = "default_dns_type")]
    pub dns_type: String,
    pub dns_servers: Vec<String>,
    pub bootstrap_dns_servers: Vec<String>,
    #[serde(default)]
    pub fallback_dns_server: String,
    #[serde(default)]
    pub dns_fallback_servers: Vec<String>,
    #[serde(default)]
    pub fallback_wan_main: bool,
    #[serde(default)]
    pub fallback_wan_bootstrap: bool,
    #[serde(default = "default_dns_check_interval")]
    pub dns_check_interval: String,
    #[serde(default = "default_dns_rec_interval")]
    pub dns_recovery_check_interval: String,
    #[serde(default = "default_dns_check_timeout")]
    pub dns_check_timeout: String,
    #[serde(default = "default_threshold_3")]
    pub dns_failure_threshold: u32,
    #[serde(default = "default_threshold_2")]
    pub dns_recovery_threshold: u32,
    #[serde(default)]
    pub dns_upstream_mode: String,
    #[serde(default = "default_dns_ttl")]
    pub dns_rewrite_ttl: u32,
    #[serde(default = "default_dns_strategy")]
    pub dns_strategy: String,
    #[serde(default)]
    pub dns_detour_enabled: bool,
    #[serde(default)]
    pub dns_detour_section: String,
    #[serde(default = "default_true")]
    pub dns_local_cache: bool,
    #[serde(default = "default_true")]
    pub dns_turbo_cache: bool,
    #[serde(default)]
    pub dns_cache_size: u32,
    #[serde(default = "default_true")]
    pub fakeip_enabled: bool,
    #[serde(default = "default_fakeip_v4")]
    pub fakeip_inet4_range: String,
    #[serde(default = "default_fakeip_v6")]
    pub fakeip_inet6_range: String,
    #[serde(default)]
    pub fakeip_exclude: Vec<String>,

    #[serde(default)]
    pub hosts_enabled: bool,
    #[serde(default)]
    pub hosts_list_urls: Vec<String>,
    #[serde(default)]
    pub static_hosts: Vec<String>,
    #[serde(default)]
    pub github_mirror: String,
    #[serde(default)]
    pub github_token: String,

    #[serde(default = "default_true")]
    pub enable_watchdog: bool,
    #[serde(default = "default_true")]
    pub emergency_direct_bypass: bool,
    #[serde(default)]
    pub wan_failover_enabled: bool,
    #[serde(default)]
    pub wan_failover_primary: String,
    #[serde(default)]
    pub wan_failover_backup: String,
    #[serde(default)]
    pub wan_failover_probe_hosts: Vec<String>,
    #[serde(default = "default_threshold_3")]
    pub wan_failover_failure_threshold: u32,
    #[serde(default = "default_threshold_3")]
    pub wan_failover_recovery_threshold: u32,
    #[serde(default)]
    pub recovery_bypass: bool,
    #[serde(default)]
    pub memory_limit_mb: u32,
    #[serde(default = "default_log_level")]
    pub log_level: String,

    #[serde(default)]
    pub smart_detect: bool,
    #[serde(default)]
    pub smart_detect_mode: String,
    #[serde(default = "default_true")]
    pub smart_detect_expand_to_root: bool,
    #[serde(default)]
    pub smart_detect_sections: Vec<String>,
    #[serde(default)]
    pub smart_detect_section: String,
    #[serde(default)]
    pub smart_detect_exclude: Vec<String>,
    #[serde(default)]
    pub smart_detect_exclude_lists: Vec<String>,

    #[serde(default = "default_sub_engine")]
    pub subscription_engine: String,
    #[serde(default = "default_true")]
    pub list_update_enabled: bool,
    #[serde(default)]
    pub update_interval: String,
    #[serde(default)]
    pub download_all_presets: bool,
    #[serde(default)]
    pub download_lists_via_proxy: bool,
    #[serde(default)]
    pub download_lists_via_proxy_section: String,
    #[serde(default)]
    pub download_components_via_proxy: bool,
    #[serde(default)]
    pub download_components_via_proxy_section: String,
    #[serde(default = "default_true")]
    pub component_update_check_enabled: bool,
    #[serde(default = "default_comp_check_int")]
    pub component_update_check_interval: String,
    #[serde(default)]
    pub component_auto_update_enabled: bool,
    #[serde(default = "default_auto_upd_mode")]
    pub component_auto_update_mode: String,
    #[serde(default = "default_auto_upd_time")]
    pub component_auto_update_time: String,
    #[serde(default)]
    pub component_auto_update_window_start: String,
    #[serde(default)]
    pub component_auto_update_window_end: String,
    #[serde(default)]
    pub component_auto_update_max_connections: u32,
    #[serde(default)]
    pub component_auto_update_max_clients: u32,
    #[serde(default)]
    pub component_auto_update_targets: Vec<String>,
    #[serde(default = "default_true")]
    pub component_backup_enabled: bool,
    #[serde(default = "default_latency_url")]
    pub latency_test_url: String,
    #[serde(default = "default_latency_mode")]
    pub latency_test_mode: String,
    #[serde(default = "default_engine_variant")]
    pub engine_variant: String,

    #[serde(default = "default_true")]
    pub server_subscription_enabled: bool,
    #[serde(default)]
    pub server_subscription_token: String,
    #[serde(default)]
    pub server_subscription_host: String,
    #[serde(default = "default_sub_format")]
    pub server_subscription_format: String,
    #[serde(default = "default_sub_title")]
    pub server_subscription_title: String,

    #[serde(default = "default_true")]
    pub honeypot_enabled: bool,
    #[serde(default)]
    pub decoy_mode: String,
    #[serde(default)]
    pub auto_heal_enabled: bool,
    #[serde(default)]
    pub auto_heal_interval_mins: u32,

    #[serde(default)]
    pub enable_ai_doctor: bool,
    #[serde(default = "default_true")]
    pub enable_rag: bool,
    #[serde(default)]
    pub ai_doctor_provider: String,
    #[serde(default)]
    pub ai_doctor_model: String,
    #[serde(default)]
    pub ai_doctor_api_key: String,
    #[serde(default)]
    pub ai_doctor_custom_url: String,
    #[serde(default)]
    pub ai_doctor_lang: String,
    #[serde(default = "default_true")]
    pub ai_proxy_health_enabled: bool,
    #[serde(default = "default_interval_60")]
    pub ai_proxy_health_interval: u32,
    #[serde(default = "default_threshold_3")]
    pub ai_proxy_health_fail_threshold: u32,
    #[serde(default = "default_latency_url")]
    pub ai_proxy_health_url: String,
    #[serde(default = "default_true")]
    pub ai_dns_continuous_enabled: bool,
    #[serde(default = "default_interval_180")]
    pub ai_dns_interval: u32,
    #[serde(default = "default_true")]
    pub ai_reload_dedup_enabled: bool,
    #[serde(default = "default_true")]
    pub ai_metrics_enabled: bool,
    #[serde(default = "default_retention_24")]
    pub ai_metrics_retention_hours: u32,
    #[serde(default = "default_true")]
    pub ai_smart_cooldowns_enabled: bool,
    #[serde(default = "default_true")]
    pub ai_config_validation_enabled: bool,
    #[serde(default = "default_true")]
    pub ai_graceful_degradation_enabled: bool,
    #[serde(default = "default_true")]
    pub ai_persistent_smart_detect: bool,
    #[serde(default)]
    pub ai_adaptive_intervals_enabled: bool,
    #[serde(default)]
    pub ai_anomaly_detection_enabled: bool,
    #[serde(default = "default_threshold_5")]
    pub ai_anomaly_reconnect_threshold: u32,

    #[serde(default = "default_true")]
    pub section_failover_enabled: bool,
    #[serde(default = "default_threshold_3")]
    pub section_failover_threshold: u32,
    #[serde(default)]
    pub dns_doq_ech: bool,
    #[serde(default = "default_qos_engine")]
    pub qos_priority_engine: String,
    #[serde(default)]
    pub warp_proxy_section: String,
    #[serde(default = "default_true", alias = "snapshot_enable")]
    pub snapshot_enabled: bool,
    #[serde(default = "default_snapshot_max", alias = "snapshot_max")]
    pub snapshot_max_count: u32,
    #[serde(default)]
    pub cors_origins: Vec<String>,
    #[serde(default = "default_session_ttl")]
    pub session_ttl_secs: u32,
    #[serde(default = "default_ai_temp")]
    pub ai_temperature: f32,
    #[serde(default = "default_ai_max_tokens")]
    pub ai_max_tokens: u32,
}

impl Default for GlobalSettings {
    fn default() -> Self {
        let salt = crypto_gen::generate_hex(8);
        let pass_hash = crypto_gen::hash_password("admin", &salt);
        Self {
            config_version: "2.0.0".to_string(),
            listen_addr: "0.0.0.0".to_string(),
            listen_port: 1680,
            web_base_path: "/".to_string(),
            admin_user: "admin".to_string(),
            admin_pass_hash: pass_hash,
            admin_pass_salt: salt,
            session_secret: crypto_gen::generate_hex(32),
            ui_mode: "simple".to_string(),
            lite_mode: false,
            sidebar_pos: "left".to_string(),
            sidebar_collapsed: false,
            accent_theme: "blue".to_string(),
            lang: "ru".to_string(),
            default_tab: "dashboard".to_string(),
            dashboard_preset: "standard".to_string(),
            dashboard_widgets_json: String::new(),
            studio_views_json: r#"{"sections":"cards","outbounds":"cards","conditions":"pipeline","balancers":"cards"}"#.to_string(),
            tab_order: vec![
                "dashboard".to_string(),
                "section".to_string(),
                "server".to_string(),
                "profile".to_string(),
                "schedule".to_string(),
                "guest_mode".to_string(),
                "local_devices".to_string(),
                "monitoring".to_string(),
                "diagnostic".to_string(),
                "updates".to_string(),
                "telegram".to_string(),
                "settings".to_string(),
            ],
            hidden_tabs: Vec::new(),
            show_tab_dashboard: true,
            show_tab_section: true,
            show_tab_server: true,
            show_tab_profile: true,
            show_tab_schedule: true,
            show_tab_guest_mode: true,
            show_tab_local_devices: true,
            show_tab_monitoring: true,
            show_tab_diagnostic: true,
            show_tab_updates: true,
            show_tab_telegram: true,
            core_bin_path: "/usr/bin/tachyon-core".to_string(),
            core_config_path: "/etc/tachyon-core/config.json".to_string(),
            cache_path: "/tmp/tachyon-core/cache.db".to_string(),
            rulesets_dir: "/etc/tachyon/rulesets".to_string(),
            clash_api_addr: "127.0.0.1:9090".to_string(),
            clash_api_secret: crypto_gen::generate_alnum(24),
            agent_api_token: crypto_gen::generate_alnum(32),
            routing_strategy: "split".to_string(),
            default_tunnel_section: "Main".to_string(),
            proxy_mode: "tproxy".to_string(),
            tun_interface: "tun0".to_string(),
            tun_stack: "mixed".to_string(),
            tun_auto_route: true,
            tun_mtu: 9000,
            tun_inet4: "172.19.0.1/30".to_string(),
            tun_inet6: String::new(),
            tun_gso: false,
            tun_endpoint_independent_nat: true,
            tun_udp_timeout: "5m".to_string(),
            tun_kill_switch: true,
            smart_queue: false,
            sqm_download_kbps: 0,
            sqm_upload_kbps: 0,
            sqm_interface: "wan".to_string(),
            tcp_profile: "default".to_string(),
            tcp_bbr: true,
            selector_auto_failover: true,
            source_network_interfaces: vec!["br-lan".to_string()],
            enable_output_network_interface: false,
            excluded_ips: Vec::new(),
            output_network_interface: String::new(),
            enable_badwan_interface_monitoring: false,
            badwan_monitored_interfaces: Vec::new(),
            badwan_reload_delay: 5,
            ipv6_mode: "auto".to_string(),
            ipv6_leak_guard: true,
            enable_ipv6: false,
            enable_yacd: true,
            enable_yacd_wan_access: false,
            yacd_secret_key: String::new(),
            disable_quic: false,
            disable_quic_mode: "off".to_string(),
            block_doh: false,
            dns_intercept_all: false,
            dns_intercept_all_mode: "auto".to_string(),
            webrtc_leak_protect: false,
            webrtc_leak_protect_mode: "auto".to_string(),
            route_router_traffic: false,
            route_router_traffic_section: String::new(),
            wifi_calling_direct: false,
            isolate_p2p: false,
            bittorrent_policy: "off".to_string(),
            p2p_ports: "tcp:6881,udp:6881-6889".to_string(),
            direct_bypass_enabled: false,
            direct_bypass_port: 2080,
            game_console_optimizer: false,
            game_console_ips: Vec::new(),
            exclude_ntp: false,
            dont_touch_dhcp: false,
            torrserver_direct_enabled: false,
            torrserver_ports: vec![8090],
            tailscale_enabled: false,
            tailscale_web_access: "auto".to_string(),
            dns_type: "udp".to_string(),
            dns_servers: vec!["77.88.8.8".to_string(), "77.88.8.1".to_string(), "9.9.9.9".to_string()],
            bootstrap_dns_servers: vec!["77.88.8.8".to_string(), "1.1.1.1".to_string()],
            fallback_dns_server: "1.0.0.1".to_string(),
            dns_fallback_servers: vec!["1.0.0.1".to_string(), "77.88.8.1".to_string()],
            fallback_wan_main: false,
            fallback_wan_bootstrap: false,
            dns_check_interval: "30s".to_string(),
            dns_recovery_check_interval: "60s".to_string(),
            dns_check_timeout: "5s".to_string(),
            dns_failure_threshold: 3,
            dns_recovery_threshold: 2,
            dns_upstream_mode: "parallel".to_string(),
            dns_rewrite_ttl: 60,
            dns_strategy: "prefer_ipv4".to_string(),
            dns_detour_enabled: false,
            dns_detour_section: String::new(),
            dns_local_cache: true,
            dns_turbo_cache: true,
            dns_cache_size: 10000,
            fakeip_enabled: true,
            fakeip_inet4_range: "198.18.0.0/15".to_string(),
            fakeip_inet6_range: "fc00::/18".to_string(),
            fakeip_exclude: Vec::new(),
            hosts_enabled: false,
            hosts_list_urls: Vec::new(),
            static_hosts: Vec::new(),
            github_mirror: String::new(),
            github_token: String::new(),
            enable_watchdog: true,
            emergency_direct_bypass: true,
            wan_failover_enabled: false,
            wan_failover_primary: "wan".to_string(),
            wan_failover_backup: "wan2".to_string(),
            wan_failover_probe_hosts: vec!["77.88.8.8".to_string(), "1.1.1.1".to_string()],
            wan_failover_failure_threshold: 3,
            wan_failover_recovery_threshold: 3,
            recovery_bypass: false,
            memory_limit_mb: 0,
            log_level: "warn".to_string(),
            smart_detect: true,
            smart_detect_mode: "default".to_string(),
            smart_detect_expand_to_root: true,
            smart_detect_sections: vec!["Main".to_string()],
            smart_detect_section: "Main".to_string(),
            smart_detect_exclude: Vec::new(),
            smart_detect_exclude_lists: Vec::new(),
            subscription_engine: "core".to_string(),
            list_update_enabled: true,
            update_interval: "3h".to_string(),
            download_all_presets: false,
            download_lists_via_proxy: true,
            download_lists_via_proxy_section: "Main".to_string(),
            download_components_via_proxy: false,
            download_components_via_proxy_section: "Main".to_string(),
            component_update_check_enabled: true,
            component_update_check_interval: "12h".to_string(),
            component_auto_update_enabled: false,
            component_auto_update_mode: "immediate".to_string(),
            component_auto_update_time: "04:00".to_string(),
            component_auto_update_window_start: "02:00".to_string(),
            component_auto_update_window_end: "06:00".to_string(),
            component_auto_update_max_connections: 0,
            component_auto_update_max_clients: 0,
            component_auto_update_targets: Vec::new(),
            component_backup_enabled: true,
            latency_test_url: "https://www.gstatic.com/generate_204".to_string(),
            latency_test_mode: "standard".to_string(),
            engine_variant: "tachyon-core".to_string(),
            server_subscription_enabled: true,
            server_subscription_token: crypto_gen::generate_hex(24),
            server_subscription_host: String::new(),
            server_subscription_format: "base64".to_string(),
            server_subscription_title: "Tachyon Router".to_string(),
            honeypot_enabled: true,
            decoy_mode: "none".to_string(),
            auto_heal_enabled: false,
            auto_heal_interval_mins: 30,
            enable_ai_doctor: true,
            enable_rag: true,
            ai_doctor_provider: "deepseek".to_string(),
            ai_doctor_model: "deepseek-chat".to_string(),
            ai_doctor_api_key: String::new(),
            ai_doctor_custom_url: String::new(),
            ai_doctor_lang: "ru".to_string(),
            ai_proxy_health_enabled: true,
            ai_proxy_health_interval: 60,
            ai_proxy_health_fail_threshold: 3,
            ai_proxy_health_url: "https://www.gstatic.com/generate_204".to_string(),
            ai_dns_continuous_enabled: true,
            ai_dns_interval: 180,
            ai_reload_dedup_enabled: true,
            ai_metrics_enabled: true,
            ai_metrics_retention_hours: 24,
            ai_smart_cooldowns_enabled: true,
            ai_config_validation_enabled: true,
            ai_graceful_degradation_enabled: true,
            ai_persistent_smart_detect: true,
            ai_adaptive_intervals_enabled: false,
            ai_anomaly_detection_enabled: false,
            ai_anomaly_reconnect_threshold: 5,
            section_failover_enabled: true,
            section_failover_threshold: 3,
            dns_doq_ech: false,
            qos_priority_engine: "auto".to_string(),
            warp_proxy_section: String::new(),
            snapshot_enabled: true,
            snapshot_max_count: 10,
            cors_origins: Vec::new(),
            session_ttl_secs: 86_400,
            ai_temperature: 0.3,
            ai_max_tokens: 2048,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RoutingSection {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "name")]
    pub label: String,
    #[serde(default)]
    pub icon: String,
    #[serde(default)]
    pub icon_domain: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub prefix_text: String,
    #[serde(default)]
    pub prefix_bg: String,
    #[serde(default)]
    pub prefix_color: String,
    #[serde(default)]
    pub dashboard_filter_mode: String,
    /// `proxy`, `desync`, `zapret2`, `zapret`, `byedpi`, `wdtt`, `olcrtc`, `fptn`, `awg`, `warp`, `tailscale`, `openvpn`, `openconnect`, `tewfai`, `direct`, `block`, `hosts`, `dns`
    #[serde(default, alias = "action_mode")]
    pub connection_type: String,
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub condition_refs: Vec<String>,
    #[serde(default)]
    pub condition_operator: String,
    #[serde(default)]
    pub condition_expression: String,
    #[serde(default)]
    pub match_all: bool,
    #[serde(default, alias = "source_refs")]
    pub outbound_source_refs: Vec<String>,
    #[serde(default)]
    pub section_refs: Vec<String>,
    #[serde(default)]
    pub balancer_refs: Vec<String>,
    #[serde(default)]
    pub outbound_group_ref: String,
    #[serde(default)]
    pub outbound_group_refs: Vec<String>,
    #[serde(default)]
    pub outbound_group_levels: Vec<String>,
    #[serde(default)]
    pub section_selection_mode: String,
    #[serde(default)]
    pub selector_auto_failover: bool,
    #[serde(default)]
    pub section_health_url: String,
    #[serde(default)]
    pub interfaces: Vec<String>,
    #[serde(default)]
    pub output_interface: String,
    #[serde(default)]
    pub server_domain_rules: Vec<String>,

    // Section-level server pool narrowing & dashboard filter
    #[serde(default)]
    pub section_filter_mode: String,
    #[serde(default)]
    pub include_countries: Vec<String>,
    #[serde(default)]
    pub exclude_countries: Vec<String>,
    #[serde(default)]
    pub include_prefixes: Vec<String>,
    #[serde(default)]
    pub exclude_prefixes: Vec<String>,
    #[serde(default)]
    pub node_filter_allow: String,
    #[serde(default)]
    pub node_filter_deny: String,
    #[serde(default)]
    pub include_protocols: Vec<String>,
    #[serde(default)]
    pub exclude_protocols: Vec<String>,
    #[serde(default)]
    pub include_transports: Vec<String>,
    #[serde(default)]
    pub exclude_transports: Vec<String>,
    #[serde(default)]
    pub include_securities: Vec<String>,
    #[serde(default)]
    pub exclude_securities: Vec<String>,
    #[serde(default)]
    pub dashboard_hide_na_servers: bool,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub subscription_url_settings: Vec<String>,

    // Traffic filters (Domains, Lists, Subnets, GeoIP, LAN devices, Ports, Protocols, DSCP)
    #[serde(default)]
    pub community_lists: Vec<String>,
    #[serde(default = "default_true")]
    pub community_subnets: bool,
    #[serde(default)]
    pub rule_set_urls: Vec<String>,
    #[serde(default)]
    pub rule_set_with_subnets: Vec<String>,
    #[serde(default)]
    pub domain_ip_lists: Vec<String>,
    #[serde(default)]
    pub domains: Vec<String>,
    #[serde(default)]
    pub user_domains: Vec<String>,
    #[serde(default, alias = "excluded_domains")]
    pub exclude_domains: Vec<String>,
    #[serde(default)]
    pub user_subnets: Vec<String>,
    #[serde(default)]
    pub exclude_subnets: Vec<String>,
    #[serde(default)]
    pub asn_list: Vec<String>,
    #[serde(default)]
    pub geoip_codes: Vec<String>,
    #[serde(default)]
    pub geoip_mode: String,
    #[serde(default)]
    pub geosite_codes: Vec<String>,
    #[serde(default)]
    pub global_rules: Vec<String>,
    #[serde(default)]
    pub source_ip_cidr: Vec<String>,
    #[serde(default, alias = "client_ips")]
    pub fully_routed_ips: Vec<String>,
    #[serde(default)]
    pub excluded_ips: Vec<String>,
    #[serde(default)]
    pub source_inbounds: Vec<String>,
    #[serde(default)]
    pub default_interface_address: Vec<String>,
    #[serde(default)]
    pub interface_address: Vec<String>,
    #[serde(default)]
    pub ports: Vec<String>,
    #[serde(default)]
    pub source_ports: Vec<String>,
    #[serde(default)]
    pub exclude_ports: Vec<String>,
    #[serde(default)]
    pub protocol: Vec<String>,
    #[serde(default)]
    pub excluded_protocol: Vec<String>,
    #[serde(default)]
    pub dscp: Vec<String>,

    // Cascade Detour, Fail Policy, Packet Encoding, Local Mixed Proxy & Routed DNS
    #[serde(default)]
    pub outbound_detour_enabled: bool,
    #[serde(default)]
    pub outbound_detour_section: String,
    #[serde(default)]
    pub sort_by_latency: bool,
    #[serde(default)]
    pub packet_encoding: String,
    #[serde(default)]
    pub resolve_real_ip_for_routing: bool,
    #[serde(default)]
    pub fail_policy: String,
    #[serde(default)]
    pub fail_policy_urls: Vec<String>,
    #[serde(default)]
    pub fail_policy_timeout: u32,
    #[serde(default)]
    pub fail_policy_threshold: u32,
    #[serde(default)]
    pub fail_policy_recover_threshold: u32,
    #[serde(default)]
    pub fail_policy_cooldown: u32,
    #[serde(default = "default_true")]
    pub fail_policy_check_direct: bool,
    #[serde(default)]
    pub fail_policy_check_interval: u32,
    #[serde(default)]
    pub fail_policy_recover_interval: u32,
    #[serde(default)]
    pub fail_policy_expected_status: String,
    #[serde(default)]
    pub mixed_proxy_enabled: bool,
    #[serde(default)]
    pub mixed_proxy_port: u16,
    #[serde(default)]
    pub mixed_proxy_auth_enabled: bool,
    #[serde(default)]
    pub mixed_proxy_username: String,
    #[serde(default)]
    pub mixed_proxy_password: String,
    #[serde(default)]
    pub routed_dns_enabled: bool,
    #[serde(default)]
    pub routed_dns_type: String,
    #[serde(default)]
    pub dns_servers: Vec<String>,
    #[serde(default)]
    pub dns_use_wan: bool,
    #[serde(default)]
    pub disable_fakeip: bool,
    #[serde(default)]
    pub dns_detour_enabled: bool,
    #[serde(default)]
    pub dns_detour_section: String,
    #[serde(default, alias = "selected_node_tag")]
    pub active_selected_tag: String,

    #[serde(default)]
    pub bind_interface: String,
    #[serde(default)]
    pub tailscale_mode: String,
    #[serde(default)]
    pub tailscale_auth_key: String,
    #[serde(default)]
    pub tailscale_control_url: String,
    #[serde(default)]
    pub tailscale_hostname: String,
    #[serde(default, alias = "tailscale_exit_node")]
    pub tailscale_use_exit_node: String,
    #[serde(default)]
    pub tailscale_ephemeral: bool,
    #[serde(default)]
    pub tailscale_exit_node_allow_lan_access: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_routes: bool,
    #[serde(default)]
    pub tailscale_advertise_routes: Vec<String>,
    #[serde(default)]
    pub tailscale_advertise_exit_node: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_dns: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_default_resolvers: bool,
    #[serde(default, deserialize_with = "deserialize_string_or_number")]
    pub tailscale_relay_server_port: String,
    #[serde(default)]
    pub tailscale_relay_server_static_endpoints: Vec<String>,
    #[serde(default)]
    pub tailscale_system_interface: bool,
    #[serde(default)]
    pub tailscale_system_interface_name: String,
    #[serde(default, deserialize_with = "deserialize_string_or_number")]
    pub tailscale_system_interface_mtu: String,
    #[serde(default)]
    pub tailscale_udp_timeout: String,

    // Provider-specific inline configuration (Desync 2.0, Zapret2, Zapret, ByeDPI, WDTT, OlcRTC, FPTN, AWG, Hosts)
    #[serde(default)]
    pub desync_preset: String,
    #[serde(default)]
    pub desync_mode: String,
    #[serde(default)]
    pub desync_fooling: String,
    #[serde(default = "default_true")]
    pub desync_auto_tune: bool,
    #[serde(default)]
    pub desync_split_pos: String,
    #[serde(default)]
    pub desync_fake_ttl: u8,
    #[serde(default)]
    pub desync_fake_sni: String,
    #[serde(default)]
    pub desync_repeats: u8,
    #[serde(default)]
    pub desync_split_delay_ms: u32,
    #[serde(default)]
    pub desync_tlsrec_first: bool,
    #[serde(default)]
    pub desync_seqovl: u16,
    #[serde(default)]
    pub desync_syndata: bool,
    #[serde(default)]
    pub desync_wsize: u32,
    #[serde(default)]
    pub desync_ipfrag: bool,
    #[serde(default = "default_true")]
    pub desync_udp_fake: bool,
    #[serde(default)]
    pub desync_udp_repeats: u8,
    #[serde(default)]
    pub desync_udp_fake_ttl: u8,
    #[serde(default)]
    pub desync_udp_fake_payload: String,
    #[serde(default)]
    pub desync_udp_out_range: String,
    #[serde(default)]
    pub desync_udp_keep_socket: String,
    #[serde(default)]
    pub desync_udplen: u16,
    #[serde(default)]
    pub desync_host_fake: bool,
    #[serde(default)]
    pub desync_wscale: Option<u8>,
    #[serde(default)]
    pub desync_sni_pool: Vec<String>,
    #[serde(default)]
    pub desync_fake_payload: String,
    #[serde(default)]
    pub desync_fake_tls: String,
    #[serde(default)]
    pub desync_opts: String,
    #[serde(default)]
    pub nfqws2_opt: String,
    #[serde(default)]
    pub nfqws_opt: String,
    #[serde(default)]
    pub byedpi_cmd_opts: String,
    #[serde(default)]
    pub warp_flow_uri: String,
    #[serde(default)]
    pub warp_flow_mode: String,
    #[serde(default)]
    pub warp_flow_workers: String,
    #[serde(default)]
    pub warp_flow_mtu: String,
    #[serde(default)]
    pub warp_flow_subscription_links: Vec<String>,
    #[serde(default)]
    pub olcrtc_provider: String,
    #[serde(default)]
    pub olcrtc_transport: String,
    #[serde(default)]
    pub olcrtc_room_id: String,
    #[serde(default)]
    pub olcrtc_crypto_key: String,
    #[serde(default)]
    pub olcrtc_socks_port: String,
    #[serde(default)]
    pub olcrtc_subscription_links: Vec<String>,
    #[serde(default)]
    pub fptn_access_token: String,
    #[serde(default)]
    pub fptn_sni: String,
    #[serde(default)]
    pub fptn_bypass_method: String,
    #[serde(default)]
    pub fptn_preferred_server: String,
    #[serde(default)]
    pub dns_hosts: String,
    #[serde(default)]
    pub hosts_list_urls: Vec<String>,
    /// CSQTT / WDTT v3
    #[serde(default)]
    pub warp_flow_device_id: String,
    #[serde(default)]
    pub wdtt_native: bool,
    #[serde(default)]
    pub wdtt_workers: u16,
    #[serde(default)]
    pub wdtt_mtu: u16,
    #[serde(default)]
    pub csqtt_server: String,
    #[serde(default)]
    pub csqtt_server_port: u16,
    #[serde(default)]
    pub csqtt_password: String,
    #[serde(default)]
    pub csqtt_mode: String,
    #[serde(default)]
    pub csqtt_obfs: String,
    #[serde(default)]
    pub csqtt_raw_port: u16,
    #[serde(default)]
    pub csqtt_wg_port: u16,
    #[serde(default)]
    pub csqtt_local_port: u16,
    #[serde(default)]
    pub csqtt_hashes: Vec<String>,
    #[serde(default)]
    pub csqtt_workers: u16,
    #[serde(default)]
    pub csqtt_turn_transport: String,
    #[serde(default)]
    pub csqtt_turn_server: String,
    #[serde(default)]
    pub csqtt_turn_urls: Vec<String>,
    #[serde(default)]
    pub csqtt_turn_username: String,
    #[serde(default)]
    pub csqtt_turn_password: String,
    #[serde(default)]
    pub csqtt_vk_auth_mode: String,
    #[serde(default)]
    pub csqtt_vk_cookie: String,
    #[serde(default)]
    pub csqtt_vk_client_ids: Vec<String>,
    #[serde(default)]
    pub csqtt_mtu: u16,
    #[serde(default)]
    pub csqtt_device_id: String,
    #[serde(default)]
    pub csqtt_uri: String,
    #[serde(default)]
    pub csqtt_chunk1: bool,
    #[serde(default)]
    pub csqtt_wg_private_key: String,
    #[serde(default)]
    pub csqtt_wg_peer_public_key: String,
    #[serde(default)]
    pub csqtt_wg_address: String,
    #[serde(default)]
    pub hosts_list_auto_update: bool,
    #[serde(default)]
    pub hosts_list_update_interval: String,
    /// Section IPv6 handling: `""` / `"auto"` / `"true"` / `"false"` (or `"1"` / `"0"`).
    #[serde(default)]
    pub ipv6_support: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrafficCondition {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "label")]
    pub name: String,
    /// `atomic`, `all`, `any`, or `not`
    #[serde(default, alias = "operator")]
    pub condition_type: String,
    #[serde(default)]
    pub children: Vec<String>,
    #[serde(default)]
    pub community_lists: Vec<String>,
    #[serde(default = "default_true")]
    pub community_subnets: bool,
    #[serde(default, alias = "domains")]
    pub user_domains: Vec<String>,
    #[serde(default, alias = "excluded_domains")]
    pub exclude_domains: Vec<String>,
    #[serde(default, alias = "ip_cidrs")]
    pub user_subnets: Vec<String>,
    #[serde(default)]
    pub exclude_subnets: Vec<String>,
    #[serde(default)]
    pub asn_list: Vec<String>,
    #[serde(default)]
    pub remote_domain_lists: Vec<String>,
    #[serde(default)]
    pub remote_subnet_lists: Vec<String>,
    #[serde(default)]
    pub geoip_codes: Vec<String>,
    #[serde(default)]
    pub geoip_mode: String,
    #[serde(default)]
    pub geosite_codes: Vec<String>,
    #[serde(default)]
    pub client_ips: Vec<String>,
    #[serde(default)]
    pub exclude_client_ips: Vec<String>,
    #[serde(default)]
    pub ports: Vec<String>,
    #[serde(default)]
    pub source_ports: Vec<String>,
    #[serde(default)]
    pub exclude_ports: Vec<String>,
    #[serde(default)]
    pub l4_proto: String,
    #[serde(default)]
    pub protocol: Vec<String>,
    #[serde(default)]
    pub excluded_protocol: Vec<String>,
    #[serde(default)]
    pub dscp: Vec<String>,
    /// Optional `time_window` schedule (e.g. `22:00-08:00` or `mon,tue,wed,thu,fri 09:00-18:00`).
    #[serde(default)]
    pub time_window: String,
    #[serde(default)]
    pub expression: String,
    #[serde(default)]
    pub invert: bool,
    #[serde(default)]
    pub rule_set: Vec<String>,
    #[serde(default)]
    pub rule_set_with_subnets: Vec<String>,
    #[serde(default)]
    pub domain_ip_lists: Vec<String>,
    #[serde(default)]
    pub fully_routed_ips: Vec<String>,
    #[serde(default)]
    pub source_macs: Vec<String>,
    #[serde(default)]
    pub source_inbounds: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ParsedProxyNode {
    pub tag: String,
    pub protocol: String,
    pub server: String,
    pub server_port: u16,
    #[serde(default)]
    pub country: String,
    #[serde(default)]
    pub raw_uri: String,
    pub outbound_json: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutboundSource {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub name: String,
    /// `subscription`, `proxy_links`, `amnezia_config`, `awg`, `wireguard`, `warp`, `fptn`,
    /// `openvpn`, `anytls`, `naive`, `mieru`, `snell`, `sudoku`, `masque`, `openconnect`,
    /// `shadowtls`, `trusttunnel`, `tewfai`, `desync`, `zapret2`, `zapret`, `byedpi`,
    /// `tor`, `tailscale`, `interface`, `custom_json`, `mtproto`
    pub source_type: String,
    #[serde(default)]
    pub subscription_urls: Vec<String>,
    #[serde(default)]
    pub subscription_update_interval: String,
    #[serde(default)]
    pub subscription_update_jitter: String,
    #[serde(default)]
    pub subscription_engine: String,
    #[serde(default)]
    pub subscription_insecure: bool,
    #[serde(default)]
    pub sub_title: String,
    #[serde(default)]
    pub sub_support_url: String,
    #[serde(default)]
    pub sub_web_page_url: String,
    #[serde(default)]
    pub sub_announce: String,
    #[serde(default)]
    pub proxy_links: Vec<String>,
    #[serde(default)]
    pub custom_json: String,
    #[serde(default)]
    pub interface_name: String,

    /// Shared direct protocol endpoint fields
    #[serde(default)]
    pub server: String,
    #[serde(default)]
    pub server_port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub psk: String,
    #[serde(default)]
    pub uuid: String,
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub flow: String,
    #[serde(default)]
    pub transport: String,
    #[serde(default)]
    pub transport_path: String,
    #[serde(default)]
    pub transport_host: String,
    #[serde(default)]
    pub reality_public_key: String,
    #[serde(default)]
    pub reality_short_id: String,
    #[serde(default)]
    pub tcp_fast_open: bool,
    #[serde(default)]
    pub multiplex_enabled: bool,
    #[serde(default)]
    pub multiplex_protocol: String,
    #[serde(default)]
    pub multiplex_max_connections: u16,
    #[serde(default)]
    pub multiplex_padding: bool,
    #[serde(default)]
    pub sni: String,
    #[serde(default)]
    pub tls_sni: String,
    #[serde(default)]
    pub insecure: bool,
    #[serde(default)]
    pub tls_insecure: bool,

    /// Amnezia .conf
    #[serde(default)]
    pub amnezia_configs: Vec<String>,
    #[serde(default)]
    pub amnezia_conf_text: String,

    /// Native `tachyon-core` Desync settings (`adaptive`, `auto`, `tls_split`, `multisplit`, `disorder`, `fake_split`, `custom`).
    #[serde(default)]
    pub desync_preset: String,
    /// `auto_tune` is enabled only when `desync_preset` is `adaptive`/`auto` or explicitly requested.
    #[serde(default)]
    pub desync_auto_tune: bool,
    #[serde(default)]
    pub desync_fake_sni: String,
    #[serde(default)]
    pub desync_sni_pool: Vec<String>,
    #[serde(default)]
    pub desync_split_pos: String,
    #[serde(default)]
    pub desync_ttl: u8,
    #[serde(default)]
    pub desync_fooling: String,
    #[serde(default)]
    pub desync_quic_fake: bool,
    #[serde(default)]
    pub desync_mode: String,
    #[serde(default)]
    pub desync_repeats: u8,
    #[serde(default)]
    pub desync_split_delay_ms: u16,
    #[serde(default)]
    pub desync_tlsrec_first: bool,
    #[serde(default)]
    pub desync_seqovl: u16,
    #[serde(default)]
    pub desync_syndata: bool,
    #[serde(default)]
    pub desync_wsize: u16,
    #[serde(default)]
    pub desync_ipfrag: bool,
    #[serde(default)]
    pub desync_udplen: u16,
    #[serde(default)]
    pub desync_udp_repeats: u8,
    #[serde(default)]
    pub desync_udp_fake_ttl: u8,
    #[serde(default)]
    pub desync_udp_fake_payload: String,
    #[serde(default)]
    pub desync_udp_out_range: String,
    #[serde(default)]
    pub desync_udp_keep_socket: String,
    #[serde(default)]
    pub desync_host_fake: bool,
    #[serde(default)]
    pub desync_wscale: Option<u8>,
    #[serde(default)]
    pub desync_fake_payload: String,
    #[serde(default)]
    pub desync_fake_tls: String,
    #[serde(default)]
    pub desync_opts: String,

    /// WireGuard / AmneziaWG client & UDP port hopping parameters.
    #[serde(default)]
    pub wg_endpoint: String,
    #[serde(default)]
    pub wg_private_key: String,
    #[serde(default)]
    pub wg_peer_public_key: String,
    #[serde(default)]
    pub wg_preshared_key: String,
    #[serde(default)]
    pub wg_local_address: String,
    #[serde(default)]
    pub wg_mtu: u16,
    #[serde(default)]
    pub awg_version: String,
    #[serde(default)]
    pub awg_keepalive: u16,
    #[serde(default)]
    pub awg_jc: u16,
    #[serde(default)]
    pub awg_jmin: u16,
    #[serde(default)]
    pub awg_jmax: u16,
    #[serde(default)]
    pub awg_s1: u16,
    #[serde(default)]
    pub awg_s2: u16,
    #[serde(default)]
    pub awg_s3: u16,
    #[serde(default)]
    pub awg_s4: u16,
    #[serde(default)]
    pub awg_h1: u32,
    #[serde(default)]
    pub awg_h2: u32,
    #[serde(default)]
    pub awg_h3: u32,
    #[serde(default)]
    pub awg_h4: u32,
    #[serde(default)]
    pub awg_i1: String,
    #[serde(default)]
    pub awg_i2: String,
    #[serde(default)]
    pub awg_i3: String,
    #[serde(default)]
    pub awg_i4: String,
    #[serde(default)]
    pub awg_i5: String,
    #[serde(default)]
    pub awg_j1: String,
    #[serde(default)]
    pub awg_j2: String,
    #[serde(default)]
    pub awg_j3: String,
    #[serde(default)]
    pub awg_itime: u32,
    #[serde(default)]
    pub server_ports: Vec<String>,
    #[serde(default)]
    pub hop_interval: String,
    #[serde(default)]
    pub hop_interval_max: String,

    /// Cloudflare WARP / MASQUE parameters.
    #[serde(default)]
    pub warp_device_id: String,
    #[serde(default)]
    pub warp_access_token: String,
    #[serde(default)]
    pub warp_ipv4: String,
    #[serde(default)]
    pub warp_ipv6: String,
    #[serde(default)]
    pub warp_private_key: String,
    #[serde(default)]
    pub warp_peer_public_key: String,
    #[serde(default)]
    pub warp_server: String,
    #[serde(default)]
    pub warp_server_port: u16,
    #[serde(default)]
    pub warp_reserved: String,
    #[serde(default)]
    pub warp_mtu: u16,
    #[serde(default)]
    pub warp_fake_packets: String,
    #[serde(default)]
    pub warp_fake_packets_size: String,
    #[serde(default)]
    pub warp_fake_packets_delay: String,
    #[serde(default)]
    pub warp_fake_packets_mode: String,

    /// FPTN
    #[serde(default)]
    pub fptn_access_token: String,
    #[serde(default)]
    pub fptn_sni: String,
    #[serde(default)]
    pub fptn_bypass_method: String,
    #[serde(default)]
    pub fptn_preferred_server: String,

    /// OpenVPN (15 fields)
    #[serde(default)]
    pub openvpn_proto: String,
    #[serde(default)]
    pub openvpn_cipher: String,
    #[serde(default)]
    pub openvpn_auth: String,
    #[serde(default)]
    pub openvpn_mtu: u16,
    #[serde(default)]
    pub openvpn_ca: String,
    #[serde(default)]
    pub openvpn_cert: String,
    #[serde(default)]
    pub openvpn_key: String,
    #[serde(default)]
    pub openvpn_tls_auth: String,
    #[serde(default)]
    pub openvpn_tls_crypt: String,
    #[serde(default)]
    pub openvpn_key_direction: String,
    #[serde(default)]
    pub openvpn_config: String,

    /// AnyTLS
    #[serde(default)]
    pub anytls_alpn: Vec<String>,
    #[serde(default)]
    pub anytls_idle_session_check_interval: String,
    #[serde(default)]
    pub anytls_idle_session_timeout: String,
    #[serde(default)]
    pub anytls_min_idle_session: u32,

    /// Snell
    #[serde(default)]
    pub snell_version: u8,
    #[serde(default)]
    pub snell_obfs: String,
    #[serde(default)]
    pub snell_obfs_host: String,
    #[serde(default)]
    pub snell_uot: bool,

    /// Mieru
    #[serde(default)]
    pub mieru_transport: String,
    #[serde(default)]
    pub mieru_multiplexing: String,
    #[serde(default)]
    pub mieru_handshake_mode: String,
    #[serde(default)]
    pub mieru_traffic_pattern: String,

    /// NaiveProxy
    #[serde(default)]
    pub naive_quic: bool,
    #[serde(default)]
    pub naive_quic_congestion_control: String,
    #[serde(default)]
    pub naive_insecure_concurrency: u32,
    #[serde(default)]
    pub naive_udp_over_tcp: bool,
    #[serde(default)]
    pub naive_extra_headers: String,

    /// Sudoku
    #[serde(default)]
    pub sudoku_aead: String,
    #[serde(default)]
    pub sudoku_ascii: bool,
    #[serde(default)]
    pub sudoku_http_mask: bool,
    #[serde(default)]
    pub sudoku_http_mask_host: String,

    /// MASQUE
    #[serde(default)]
    pub masque_vhttp: bool,
    #[serde(default)]
    pub masque_public_key: String,
    #[serde(default)]
    pub masque_local_address: String,
    #[serde(default)]
    pub masque_ipv6: String,
    #[serde(default)]
    pub masque_uri: String,
    #[serde(default)]
    pub masque_mtu: u16,

    /// OpenConnect
    #[serde(default)]
    pub openconnect_protocol: String,
    #[serde(default)]
    pub openconnect_authgroup: String,
    #[serde(default)]
    pub openconnect_servercert: String,
    #[serde(default)]
    pub openconnect_no_dtls: bool,

    /// ShadowTLS
    #[serde(default)]
    pub shadowtls_version: u8,

    /// TrustTunnel
    #[serde(default)]
    pub trusttunnel_quic: bool,
    #[serde(default)]
    pub trusttunnel_health_check: bool,

    /// TewFai
    #[serde(default)]
    pub tewfai_transport: String,
    #[serde(default)]
    pub tewfai_inner_cipher: String,
    #[serde(default)]
    pub tewfai_morph_profile: String,
    #[serde(default)]
    pub tewfai_desync_enabled: bool,

    /// CSQTT / WDTT v3
    #[serde(default)]
    pub csqtt_server: String,
    #[serde(default)]
    pub csqtt_server_port: u16,
    #[serde(default)]
    pub csqtt_password: String,
    #[serde(default)]
    pub csqtt_mode: String,
    #[serde(default)]
    pub csqtt_obfs: String,
    #[serde(default)]
    pub csqtt_raw_port: u16,
    #[serde(default)]
    pub csqtt_wg_port: u16,
    #[serde(default)]
    pub csqtt_local_port: u16,
    #[serde(default)]
    pub csqtt_hashes: Vec<String>,
    #[serde(default)]
    pub csqtt_workers: u16,
    #[serde(default)]
    pub csqtt_turn_transport: String,
    #[serde(default)]
    pub csqtt_turn_server: String,
    #[serde(default)]
    pub csqtt_turn_urls: Vec<String>,
    #[serde(default)]
    pub csqtt_turn_username: String,
    #[serde(default)]
    pub csqtt_turn_password: String,
    #[serde(default)]
    pub csqtt_vk_auth_mode: String,
    #[serde(default)]
    pub csqtt_vk_cookie: String,
    #[serde(default)]
    pub csqtt_vk_client_ids: Vec<String>,
    #[serde(default)]
    pub csqtt_mtu: u16,
    #[serde(default)]
    pub csqtt_device_id: String,
    #[serde(default)]
    pub csqtt_uri: String,
    #[serde(default)]
    pub csqtt_chunk1: bool,
    #[serde(default)]
    pub csqtt_wg_private_key: String,
    #[serde(default)]
    pub csqtt_wg_peer_public_key: String,
    #[serde(default)]
    pub csqtt_wg_address: String,

    /// Tor
    #[serde(default)]
    pub tor_socks_port: u16,
    #[serde(default)]
    pub tor_bridges: Vec<String>,

    /// MTProto `telegram-ws` / `kws` mode.
    #[serde(default)]
    pub mtproto_telegram_ws: bool,

    /// Tailscale native or embedded outbound config.
    #[serde(default)]
    pub tailscale_mode: String,
    #[serde(default)]
    pub tailscale_auth_key: String,
    #[serde(default)]
    pub tailscale_control_url: String,
    #[serde(default)]
    pub tailscale_hostname: String,
    #[serde(default, alias = "tailscale_exit_node")]
    pub tailscale_use_exit_node: String,
    #[serde(default)]
    pub tailscale_ephemeral: bool,
    #[serde(default)]
    pub tailscale_exit_node_allow_lan_access: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_routes: bool,
    #[serde(default)]
    pub tailscale_advertise_routes: Vec<String>,
    #[serde(default)]
    pub tailscale_advertise_exit_node: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_dns: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_default_resolvers: bool,
    #[serde(default, deserialize_with = "deserialize_string_or_number")]
    pub tailscale_relay_server_port: String,
    #[serde(default)]
    pub tailscale_relay_server_static_endpoints: Vec<String>,
    #[serde(default)]
    pub tailscale_system_interface: bool,
    #[serde(default)]
    pub tailscale_system_interface_name: String,
    #[serde(default, deserialize_with = "deserialize_string_or_number")]
    pub tailscale_system_interface_mtu: String,
    #[serde(default)]
    pub tailscale_udp_timeout: String,
    #[serde(default)]
    pub fail_policy: String,

    #[serde(default)]
    pub filter_allow_regex: String,
    #[serde(default)]
    pub filter_deny_regex: String,
    #[serde(default)]
    pub include_countries: Vec<String>,
    #[serde(default)]
    pub exclude_countries: Vec<String>,
    #[serde(default = "default_true")]
    pub subscription_update_enabled: bool,
    #[serde(default)]
    pub download_via_proxy_enabled: bool,
    #[serde(default)]
    pub download_via_proxy_section: String,
    #[serde(default = "default_true")]
    pub auto_user_agent: bool,
    #[serde(default)]
    pub user_agent: String,
    #[serde(default = "default_true")]
    pub auto_hwid: bool,
    #[serde(default)]
    pub hwid: String,
    #[serde(default)]
    pub custom_device_headers: bool,
    #[serde(default)]
    pub device_os: String,
    #[serde(default)]
    pub ver_os: String,
    #[serde(default)]
    pub device_model: String,
    #[serde(default)]
    pub device_locale: String,
    #[serde(default)]
    pub app_version: String,
    #[serde(default)]
    pub accept_language: String,
    #[serde(default)]
    pub show_dashboard_metadata: bool,
    #[serde(default)]
    pub include_urltest_groups: bool,
    #[serde(default)]
    pub hide_urltest_group_outbounds: bool,
    #[serde(default)]
    pub urltest_idle_timeout: String,
    #[serde(default)]
    pub hide_detour_outbounds: bool,
    #[serde(default)]
    pub tls_fingerprint: String,
    #[serde(default)]
    pub tls_fragment_mode: String,
    #[serde(default)]
    pub tcp_fragment_length: String,
    #[serde(default)]
    pub tcp_fragment_delay: String,
    #[serde(default)]
    pub outbound_detour_enabled: bool,
    #[serde(default)]
    pub outbound_detour_section: String,
    #[serde(default)]
    pub bind_interface: String,
    #[serde(default)]
    pub server_interfaces: Vec<String>,
    #[serde(default)]
    pub domain_resolver_enabled: bool,
    #[serde(default)]
    pub domain_resolver_dns_type: String,
    #[serde(default)]
    pub domain_resolver_dns_server: String,
    #[serde(default)]
    pub prefix_nodes: bool,
    #[serde(default)]
    pub node_prefix: String,
    #[serde(default)]
    pub node_prefix_bg: String,
    #[serde(default)]
    pub node_prefix_color: String,
    #[serde(default)]
    pub nfqws2_opt: String,
    #[serde(default)]
    pub nfqws_opt: String,
    #[serde(default)]
    pub byedpi_cmd_opts: String,
    #[serde(default)]
    pub sub_upload_bytes: u64,
    #[serde(default)]
    pub sub_download_bytes: u64,
    #[serde(default)]
    pub sub_total_bytes: u64,
    #[serde(default)]
    pub sub_expire_unix: i64,
    #[serde(default)]
    pub sub_last_error: String,
    #[serde(default)]
    pub cached_nodes: Vec<ParsedProxyNode>,
    #[serde(default)]
    pub last_updated_unix: i64,
    #[serde(default)]
    pub hidden: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PriorityLevelConfig {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub direct: bool,
    /// `include`, `exclude`, `mixed`, or `all_remaining`
    #[serde(default)]
    pub filter_mode: String,
    #[serde(default)]
    pub include_countries: Vec<String>,
    #[serde(default)]
    pub exclude_countries: Vec<String>,
    #[serde(default)]
    pub include_servers: Vec<String>,
    #[serde(default)]
    pub exclude_servers: Vec<String>,
    #[serde(default)]
    pub include_regex: String,
    #[serde(default)]
    pub exclude_regex: String,
}

/// Policy-only balancer configuration.
/// Per architectural invariant, candidate outbounds/subscriptions/groups are NEVER stored in the
/// balancer itself — they are always resolved from the `RoutingSection` referencing this balancer.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BalancerConfig {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "label")]
    pub name: String,
    /// `urltest` or `priority`
    #[serde(default)]
    pub balancer_type: String,
    /// `least_test`, `stability`, `sticky`, `round_robin`, `least_load`, `weighted`, `passive`, `priority`, `hedged`, `throughput`, `quota`, `failover`
    #[serde(default)]
    pub mode: String,
    #[serde(default = "default_latency_url", alias = "probe_url")]
    pub testing_url: String,
    #[serde(default)]
    pub testing_urls: Vec<String>,
    #[serde(default)]
    pub multi_url_strategy: String,
    /// Probe interval in seconds (default 180).
    #[serde(default, alias = "interval_secs")]
    pub check_interval: u32,
    #[serde(default)]
    pub check_interval_jitter: u32,
    #[serde(default)]
    pub urltest_active_check_interval: String,
    #[serde(default)]
    pub idle_timeout: String,
    /// Latency tolerance in ms (default 50).
    #[serde(default, alias = "tolerance_ms")]
    pub tolerance: u32,
    #[serde(default, alias = "sticky_hash_field")]
    pub sticky_hash: String,
    #[serde(default)]
    pub quota_mib: u64,
    #[serde(default)]
    pub fallback_section: String,
    #[serde(default)]
    pub balancer_pool: Vec<String>,
    #[serde(default)]
    pub passive_check: bool,
    #[serde(default)]
    pub interrupt_exist_connections: bool,
    #[serde(default)]
    pub health_urls: Vec<String>,
    #[serde(default)]
    pub active_check_interval: String,
    #[serde(default)]
    pub check_timeout: String,
    #[serde(default)]
    pub recovery_check_interval: String,
    #[serde(default)]
    pub pick_fastest: bool,
    #[serde(default)]
    pub switch_to_faster_same_priority: bool,
    #[serde(default)]
    pub fastest_check_interval: String,
    #[serde(default)]
    pub priority_levels: Vec<PriorityLevelConfig>,
    #[serde(default)]
    pub filter_mode: String,
    #[serde(default = "default_true")]
    pub detect_server_country: bool,
    #[serde(default)]
    pub pin_dashboard: bool,
    #[serde(default)]
    pub exclude_proxy_parameters: bool,
    #[serde(default)]
    pub include_prefixes: Vec<String>,
    #[serde(default)]
    pub include_country_flags: Vec<String>,
    #[serde(default)]
    pub include_servers: Vec<String>,
    #[serde(default)]
    pub include_name_regex: String,
    #[serde(default)]
    pub include_protocols: Vec<String>,
    #[serde(default)]
    pub include_transports: Vec<String>,
    #[serde(default)]
    pub include_security_types: Vec<String>,
    #[serde(default)]
    pub include_ports: Vec<String>,
    #[serde(default)]
    pub exclude_prefixes: Vec<String>,
    #[serde(default)]
    pub exclude_country_flags: Vec<String>,
    #[serde(default)]
    pub exclude_servers: Vec<String>,
    #[serde(default)]
    pub exclude_name_regex: String,
    #[serde(default)]
    pub exclude_protocols: Vec<String>,
    #[serde(default)]
    pub exclude_transports: Vec<String>,
    #[serde(default)]
    pub exclude_security_types: Vec<String>,
    #[serde(default)]
    pub exclude_ports: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutboundGroup {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "display_name")]
    pub name: String,
    #[serde(default)]
    pub primary_refs: Vec<String>,
    #[serde(default)]
    pub backup_refs: Vec<String>,
    /// `block`, `direct`, or `last_alive`
    #[serde(default)]
    pub fail_policy: String,
    /// Outbound group filter modal fields (22 fields)
    #[serde(default)]
    pub source_refs: Vec<String>,
    #[serde(default)]
    pub filter_mode: String,
    #[serde(default = "default_true")]
    pub detect_server_country: bool,
    #[serde(default)]
    pub include_prefixes: Vec<String>,
    #[serde(default)]
    pub include_country_flags: Vec<String>,
    #[serde(default)]
    pub include_servers: Vec<String>,
    #[serde(default)]
    pub include_name_regex: String,
    #[serde(default)]
    pub include_protocols: Vec<String>,
    #[serde(default)]
    pub include_transports: Vec<String>,
    #[serde(default)]
    pub include_security_types: Vec<String>,
    #[serde(default)]
    pub include_ports: Vec<String>,
    #[serde(default)]
    pub exclude_prefixes: Vec<String>,
    #[serde(default)]
    pub exclude_country_flags: Vec<String>,
    #[serde(default)]
    pub exclude_servers: Vec<String>,
    #[serde(default)]
    pub exclude_name_regex: String,
    #[serde(default)]
    pub exclude_protocols: Vec<String>,
    #[serde(default)]
    pub exclude_transports: Vec<String>,
    #[serde(default)]
    pub exclude_security_types: Vec<String>,
    #[serde(default)]
    pub exclude_ports: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InboundClient {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub uuid: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub flow: String,
    #[serde(default)]
    pub sub_id: String,
    #[serde(default)]
    pub up: u64,
    #[serde(default)]
    pub down: u64,
    #[serde(default)]
    pub total_limit_bytes: u64,
    #[serde(default)]
    pub expiry_time: i64,
    #[serde(default)]
    pub ip_limit: u32,
    #[serde(default)]
    pub wg_public_key: String,
    #[serde(default)]
    pub wg_private_key: String,
    #[serde(default)]
    pub wg_client_ip: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InboundServer {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "name")]
    pub label: String,
    #[serde(default, alias = "server_country")]
    pub country: String,
    /// `vless`, `vmess`, `shadowsocks`, `trojan`, `hysteria2`, `tuic`, `anytls`, `shadowtls`,
    /// `naive`, `mieru`, `snell`, `tewfai`, `masque`, `trusttunnel`, `mtproto`, `openconnect`,
    /// `fptn`, `wireguard`, `awg`, `tailscale`, `mixed`, `socks`, `http`, `json_inbound`
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub listen: String,
    #[serde(default)]
    pub listen_port: u16,
    #[serde(default)]
    pub listen_port_range: String,
    #[serde(default)]
    pub public_host: String,
    #[serde(default = "default_true")]
    pub open_firewall_port: bool,
    /// `rules`, `direct`, or `section`
    #[serde(default)]
    pub routing_mode: String,
    #[serde(default)]
    pub routing_section: String,
    #[serde(default)]
    pub security: String,
    #[serde(default, alias = "client_uuid")]
    pub server_uuid: String,
    #[serde(default)]
    pub server_username: String,
    #[serde(default, alias = "server_password")]
    pub password: String,
    #[serde(default, alias = "ss_method", alias = "shadowsocks_method")]
    pub method: String,
    #[serde(default)]
    pub vmess_alter_id: u16,
    #[serde(default)]
    pub socks_auth_enabled: bool,
    #[serde(default)]
    pub vless_flow: String,
    #[serde(default, alias = "tls_domain")]
    pub tls_server_name: String,
    #[serde(default)]
    pub tls_certificate_path: String,
    #[serde(default)]
    pub tls_key_path: String,
    #[serde(default)]
    pub tls_alpn: Vec<String>,
    #[serde(default)]
    pub client_fingerprint: String,
    #[serde(default, alias = "reality_sni")]
    pub reality_handshake_server: String,
    #[serde(default)]
    pub reality_handshake_server_port: u16,
    #[serde(default)]
    pub reality_private_key: String,
    #[serde(default)]
    pub reality_public_key: String,
    #[serde(default)]
    pub reality_short_id: String,
    #[serde(default)]
    pub reality_max_time_difference: String,
    #[serde(default)]
    pub transport: String,
    #[serde(default)]
    pub transport_path: String,
    #[serde(default)]
    pub transport_host: String,
    #[serde(default)]
    pub transport_xhttp_mode: String,
    #[serde(default)]
    pub transport_hosts: Vec<String>,
    #[serde(default)]
    pub transport_service_name: String,

    // Protocol-specific fields (TewFai, Hysteria2, TUIC, AnyTLS, ShadowTLS, Mieru, TrustTunnel, MASQUE, OpenConnect, MTProto, AmneziaWG, Tailscale)
    #[serde(default)]
    pub anytls_padding_scheme: String,
    #[serde(default)]
    pub tewfai_uuid: String,
    #[serde(default)]
    pub tewfai_password: String,
    #[serde(default)]
    pub tewfai_inbound_transport: String,
    #[serde(default)]
    pub tewfai_inner_cipher: String,
    #[serde(default)]
    pub tewfai_shaper_profile: String,
    #[serde(default)]
    pub tewfai_morph_profile: String,
    #[serde(default)]
    pub tewfai_pqc_enabled: bool,
    #[serde(default)]
    pub tewfai_handover_enabled: bool,
    #[serde(default)]
    pub tewfai_fec_enabled: bool,
    #[serde(default)]
    pub tewfai_shaper_enabled: bool,
    #[serde(default)]
    pub tewfai_mtu: u16,
    #[serde(default)]
    pub wdtt_mode: String,
    #[serde(default)]
    pub wdtt_obfs: String,
    #[serde(default)]
    pub wdtt_raw_port: u16,
    #[serde(default)]
    pub wdtt_network: String,
    #[serde(default)]
    pub wdtt_ipv4_pool: String,
    #[serde(default)]
    pub wdtt_raw_ipv4_pool: String,
    #[serde(default)]
    pub wdtt_client_dns: String,
    #[serde(default)]
    pub wdtt_mtu: u16,
    #[serde(default)]
    pub hysteria2_obfs_type: String,
    #[serde(default)]
    pub hysteria2_obfs_password: String,
    #[serde(default)]
    pub hysteria2_up_mbps: u64,
    #[serde(default)]
    pub hysteria2_down_mbps: u64,
    #[serde(default)]
    pub tuic_congestion_control: String,
    #[serde(default)]
    pub shadowtls_handshake_server: String,
    #[serde(default)]
    pub shadowtls_handshake_server_port: u16,
    #[serde(default)]
    pub shadowtls_version: u8,
    #[serde(default)]
    pub mieru_transport: String,
    #[serde(default)]
    pub trusttunnel_quic: bool,
    #[serde(default)]
    pub masque_ipv4_pool: String,
    #[serde(default)]
    pub masque_ipv6_pool: String,
    #[serde(default)]
    pub masque_mtu: u16,
    #[serde(default)]
    pub openconnect_cookie: String,
    #[serde(default)]
    pub openconnect_flavor: String,
    #[serde(default)]
    pub openconnect_user_agent: String,
    #[serde(default)]
    pub openconnect_local_hostname: String,
    #[serde(default)]
    pub openconnect_urlpath: String,
    #[serde(default)]
    pub openconnect_address: String,
    #[serde(default)]
    pub openconnect_mtu: u16,
    #[serde(default)]
    pub openconnect_ip: bool,
    #[serde(default)]
    pub openconnect_esp: bool,
    #[serde(default)]
    pub openconnect_dtls: bool,
    #[serde(default)]
    pub mtproto_secret: String,
    #[serde(default, alias = "adtag")]
    pub mtproto_adtag: String,
    #[serde(default)]
    pub mtproto_faketls: String,
    #[serde(default)]
    pub mtproto_telegram_ws: bool,
    #[serde(default)]
    pub mtproto_padding: bool,
    #[serde(default)]
    pub mtproto_concurrency: u32,
    #[serde(default)]
    pub mtproto_domain_fronting_port: u16,
    #[serde(default)]
    pub mtproto_domain_fronting_ip: String,
    #[serde(default)]
    pub mtproto_domain_fronting_proxy_protocol: bool,
    #[serde(default)]
    pub mtproto_prefer_ip: String,
    #[serde(default)]
    pub mtproto_auto_update: bool,
    #[serde(default)]
    pub mtproto_allow_fallback_on_unknown_dc: bool,
    #[serde(default)]
    pub mtproto_tolerate_time_skewness: bool,
    #[serde(default)]
    pub mtproto_idle_timeout: String,
    #[serde(default)]
    pub mtproto_handshake_timeout: String,
    #[serde(default)]
    pub awg_version: String,
    #[serde(default)]
    pub awg_mtu: u16,
    #[serde(default)]
    pub awg_local_address: String,
    #[serde(default)]
    pub awg_client_address: String,
    #[serde(default)]
    pub awg_dns: String,
    #[serde(default)]
    pub awg_jc: u16,
    #[serde(default)]
    pub awg_jmin: u16,
    #[serde(default)]
    pub awg_jmax: u16,
    #[serde(default)]
    pub awg_s1: u16,
    #[serde(default)]
    pub awg_s2: u16,
    #[serde(default)]
    pub awg_s3: u16,
    #[serde(default)]
    pub awg_s4: u16,
    #[serde(default)]
    pub awg_h1: u32,
    #[serde(default)]
    pub awg_h2: u32,
    #[serde(default)]
    pub awg_h3: u32,
    #[serde(default)]
    pub awg_h4: u32,
    #[serde(default)]
    pub awg_i1: String,
    #[serde(default)]
    pub awg_i2: String,
    #[serde(default)]
    pub awg_i3: String,
    #[serde(default)]
    pub awg_i4: String,
    #[serde(default)]
    pub awg_i5: String,
    #[serde(default)]
    pub awg_j1: String,
    #[serde(default)]
    pub awg_j2: String,
    #[serde(default)]
    pub awg_j3: String,
    #[serde(default)]
    pub awg_itime: u32,
    #[serde(default)]
    pub awg_keepalive: u16,
    #[serde(default)]
    pub awg_private_key: String,
    #[serde(default)]
    pub awg_server_public_key: String,
    #[serde(default)]
    pub awg_client_private_key: String,
    #[serde(default)]
    pub awg_peer_public_key: String,
    #[serde(default)]
    pub awg_preshared_key: String,
    #[serde(default)]
    pub tailscale_auth_key: String,
    #[serde(default)]
    pub tailscale_control_url: String,
    #[serde(default)]
    pub tailscale_hostname: String,
    #[serde(default)]
    pub tailscale_advertise_exit_node: bool,
    #[serde(default)]
    pub tailscale_advertise_routes: Vec<String>,
    #[serde(default)]
    pub tailscale_accept_routes: bool,
    #[serde(default)]
    pub tailscale_mode: String,
    #[serde(default)]
    pub tailscale_auto_firewall: bool,
    #[serde(default)]
    pub tailscale_masquerade: bool,
    #[serde(default, alias = "tailscale_exit_node")]
    pub tailscale_use_exit_node: String,
    #[serde(default)]
    pub tailscale_ephemeral: bool,
    #[serde(default)]
    pub tailscale_exit_node_allow_lan_access: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_dns: bool,
    #[serde(default = "default_true")]
    pub tailscale_accept_default_resolvers: bool,
    #[serde(default, deserialize_with = "deserialize_string_or_number")]
    pub tailscale_relay_server_port: String,
    #[serde(default)]
    pub tailscale_relay_server_static_endpoints: Vec<String>,
    #[serde(default)]
    pub tailscale_system_interface: bool,
    #[serde(default)]
    pub tailscale_system_interface_name: String,
    #[serde(default, deserialize_with = "deserialize_string_or_number")]
    pub tailscale_system_interface_mtu: String,
    #[serde(default)]
    pub tailscale_udp_timeout: String,
    #[serde(default)]
    pub isolate_lan_for_users: bool,
    #[serde(default)]
    pub isolated_users: Vec<String>,
    #[serde(default)]
    pub isolated_subnets: Vec<String>,
    #[serde(default)]
    pub clients: Vec<InboundClient>,
    #[serde(default)]
    pub inbound_json: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ParentalProfile {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "name")]
    pub label: String,
    #[serde(default)]
    pub avatar: String,
    #[serde(default, alias = "device_macs", alias = "device_ip")]
    pub device_ips: Vec<String>,
    #[serde(default)]
    pub safe_search: bool,
    #[serde(default)]
    pub block_doh: bool,
    #[serde(default)]
    pub daily_quota_minutes: u32,
    #[serde(default)]
    pub used_minutes_today: u32,
    #[serde(default)]
    pub paused_until_unix: i64,
    #[serde(default)]
    pub blocked_categories: Vec<String>,
    #[serde(default, alias = "custom_blocked_domains")]
    pub blocked_domains: Vec<String>,
    #[serde(default, alias = "schedule_window")]
    pub schedule_ref: String,
    #[serde(default)]
    pub notify: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DeviceMeta {
    #[serde(default)]
    pub ip: String,
    #[serde(default)]
    pub mac: String,
    #[serde(default)]
    pub custom_name: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub static_lease: bool,
    #[serde(default)]
    pub limit_up_bps: u64,
    #[serde(default)]
    pub limit_down_bps: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ScheduleRule {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "name")]
    pub label: String,
    #[serde(default, alias = "profile")]
    pub profile_refs: Vec<String>,
    #[serde(default, alias = "device_ip")]
    pub device_ips: Vec<String>,
    #[serde(default, alias = "target_id")]
    pub target: String,
    #[serde(default)]
    pub sections: Vec<String>,
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub time_mode: String,
    #[serde(default)]
    pub start_time: String,
    #[serde(default)]
    pub end_time: String,
    #[serde(default)]
    pub days: Vec<String>,
    #[serde(default)]
    pub daily_quota_minutes: u32,
    #[serde(default)]
    pub blocked_domains: Vec<String>,
    #[serde(default)]
    pub blocked_categories: Vec<String>,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub dns_level: String,
    #[serde(default)]
    pub notify: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GuestModeConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub guest_devices: Vec<String>,
    #[serde(default)]
    pub trusted_devices: Vec<String>,
    #[serde(default = "default_true")]
    pub isolate_lan: bool,
    #[serde(default = "default_true")]
    pub block_router_admin: bool,
    #[serde(default = "default_true")]
    pub allow_proxy: bool,
    #[serde(default)]
    pub daily_time_limit: u32,
    #[serde(default)]
    pub daily_traffic_limit: u64,
    #[serde(default)]
    pub bandwidth_limit_mbps: u32,
    #[serde(default)]
    pub allowed_ports: Vec<u16>,
    #[serde(default)]
    pub allowed_domains: Vec<String>,
    #[serde(default)]
    pub landing_url: String,
    #[serde(default)]
    pub start_time: String,
    #[serde(default)]
    pub end_time: String,
    #[serde(default)]
    pub days: Vec<String>,
    #[serde(default)]
    pub notify: bool,
}

impl Default for GuestModeConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: "selected".to_string(),
            guest_devices: Vec::new(),
            trusted_devices: Vec::new(),
            isolate_lan: true,
            block_router_admin: true,
            allow_proxy: true,
            daily_time_limit: 0,
            daily_traffic_limit: 0,
            bandwidth_limit_mbps: 0,
            allowed_ports: Vec::new(),
            allowed_domains: Vec::new(),
            landing_url: String::new(),
            start_time: String::new(),
            end_time: String::new(),
            days: Vec::new(),
            notify: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TgBotConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub bot_token: String,
    #[serde(default, alias = "allowed_chat_ids", alias = "admin_id")]
    pub admin_ids: Vec<i64>,
    #[serde(default)]
    pub router_name: String,
    #[serde(default, alias = "polling_interval")]
    pub poll_interval: u32,
    #[serde(
        default = "default_true",
        alias = "notify_on_core_restart",
        alias = "notify_core_crash"
    )]
    pub notify_crash: bool,
    #[serde(default = "default_true")]
    pub notify_restart: bool,
    #[serde(
        default = "default_true",
        alias = "notify_on_wan_drop",
        alias = "notify_wan_failover"
    )]
    pub notify_server_switch: bool,
    #[serde(default = "default_true")]
    pub notify_subscription: bool,
    #[serde(default = "default_true")]
    pub notify_dns_leak: bool,
    #[serde(default)]
    pub notify_cert: bool,
    #[serde(default)]
    pub notify_auto_update: bool,
    #[serde(default = "default_true")]
    pub notify_honeypot: bool,
    #[serde(default = "default_true")]
    pub notify_parental: bool,
    #[serde(default = "default_true")]
    pub notify_smart_detect: bool,
    #[serde(default = "default_true")]
    pub notify_failover: bool,
    #[serde(default = "default_true")]
    pub notify_wan: bool,
    #[serde(default = "default_true")]
    pub notify_update_available: bool,
    #[serde(default = "default_true")]
    pub notify_route_alert: bool,
    #[serde(default)]
    pub bot_proxy_section: String,
    #[serde(default = "default_true")]
    pub bot_direct_fallback: bool,
    #[serde(default)]
    pub language: String,
    #[serde(default)]
    pub quiet_hours_enabled: bool,
    #[serde(default = "default_quiet_start")]
    pub quiet_hours_start: String,
    #[serde(default = "default_quiet_end")]
    pub quiet_hours_end: String,
    #[serde(default)]
    pub webhook_secret: String,
}

impl Default for TgBotConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            bot_token: String::new(),
            admin_ids: Vec::new(),
            router_name: "OpenWrt Tachyon".to_string(),
            poll_interval: 5,
            notify_crash: true,
            notify_restart: true,
            notify_server_switch: true,
            notify_subscription: true,
            notify_dns_leak: true,
            notify_cert: false,
            notify_auto_update: true,
            notify_honeypot: true,
            notify_parental: true,
            notify_smart_detect: true,
            notify_failover: true,
            notify_wan: true,
            notify_update_available: true,
            notify_route_alert: true,
            bot_proxy_section: String::new(),
            bot_direct_fallback: true,
            language: "ru".to_string(),
            quiet_hours_enabled: false,
            quiet_hours_start: default_quiet_start(),
            quiet_hours_end: default_quiet_end(),
            webhook_secret: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouterStoreData {
    pub settings: GlobalSettings,
    #[serde(default)]
    pub sections: Vec<RoutingSection>,
    #[serde(default)]
    pub conditions: Vec<TrafficCondition>,
    #[serde(default)]
    pub outbound_sources: Vec<OutboundSource>,
    #[serde(default)]
    pub balancers: Vec<BalancerConfig>,
    #[serde(default)]
    pub outbound_groups: Vec<OutboundGroup>,
    #[serde(default)]
    pub servers: Vec<InboundServer>,
    #[serde(default)]
    pub profiles: Vec<ParentalProfile>,
    #[serde(default)]
    pub schedules: Vec<ScheduleRule>,
    #[serde(default)]
    pub guest_mode: GuestModeConfig,
    #[serde(default)]
    pub telegram: TgBotConfig,
    #[serde(default)]
    pub device_registry: HashMap<String, DeviceMeta>,
    #[serde(default)]
    pub applied_migrations: Vec<String>,
}

impl Default for RouterStoreData {
    fn default() -> Self {
        let mut s = Self {
            settings: GlobalSettings::default(),
            sections: Vec::new(),
            conditions: Vec::new(),
            outbound_sources: Vec::new(),
            balancers: Vec::new(),
            outbound_groups: Vec::new(),
            servers: Vec::new(),
            profiles: Vec::new(),
            schedules: Vec::new(),
            guest_mode: GuestModeConfig::default(),
            telegram: TgBotConfig::default(),
            device_registry: HashMap::new(),
            applied_migrations: Vec::new(),
        };
        if s.import_legacy_router_files() == 0 {
            s.seed_defaults();
        }
        s.apply_relax_probe_intervals_v1();
        s.apply_fail_closed_auto_defaults();
        s.apply_ai_lists_1_8();
        s
    }
}

fn strip_one_condition_clone_suffix(s: &str) -> Option<&str> {
    if !s.starts_with("cond_") {
        return None;
    }
    if let Some(pos) = s.rfind("_copy") {
        let tail = &s[pos + 5..];
        let digits_tail = tail.strip_prefix('_').unwrap_or(tail);
        if pos > "cond_".len()
            && (tail.is_empty()
                || (!digits_tail.is_empty() && digits_tail.bytes().all(|b| b.is_ascii_digit())))
        {
            return Some(&s[..pos]);
        }
    }
    if let Some(pos) = s.rfind('_') {
        let tail = &s[pos + 1..];
        let bytes = tail.as_bytes();
        let is_clone_index = match bytes.len() {
            0 => false,
            1 => (b'2'..=b'9').contains(&bytes[0]),
            _ => (b'1'..=b'9').contains(&bytes[0]) && bytes[1..].iter().all(|b| b.is_ascii_digit()),
        };
        if pos > "cond_".len() && is_clone_index {
            return Some(&s[..pos]);
        }
    }
    None
}

fn condition_clone_base_id(cid: &str) -> String {
    let mut base = cid;
    while let Some(next) = strip_one_condition_clone_suffix(base) {
        base = next;
    }
    base.to_string()
}

fn normalize_sig_tokens<'a, I>(items: I) -> Vec<String>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut out = Vec::new();
    for raw in items {
        for part in raw.split(['\n', '\r']) {
            let trimmed = part.trim();
            if !trimmed.is_empty() {
                out.push(trimmed.to_string());
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

fn condition_rule_signature(cond: &TrafficCondition) -> Option<String> {
    let raw_type = cond.condition_type.trim().to_ascii_lowercase();
    if !cond.children.is_empty()
        || !cond.expression.trim().is_empty()
        || matches!(raw_type.as_str(), "composite" | "all" | "any" | "not")
    {
        return None;
    }

    let norm_type = if raw_type.is_empty() {
        "atomic"
    } else {
        raw_type.as_str()
    };

    let mut has_rule_content = false;
    let mut parts: Vec<(&str, Vec<String>)> = vec![
        (
            "enabled",
            vec![if cond.enabled { "1" } else { "0" }.to_string()],
        ),
        ("condition_type", vec![norm_type.to_string()]),
    ];

    let list_fields: [(&str, &[String]); 24] = [
        ("community_lists", &cond.community_lists),
        ("user_domains", &cond.user_domains),
        ("exclude_domains", &cond.exclude_domains),
        ("user_subnets", &cond.user_subnets),
        ("exclude_subnets", &cond.exclude_subnets),
        ("asn_list", &cond.asn_list),
        ("remote_domain_lists", &cond.remote_domain_lists),
        ("remote_subnet_lists", &cond.remote_subnet_lists),
        ("geoip_codes", &cond.geoip_codes),
        ("geosite_codes", &cond.geosite_codes),
        ("client_ips", &cond.client_ips),
        ("exclude_client_ips", &cond.exclude_client_ips),
        ("ports", &cond.ports),
        ("source_ports", &cond.source_ports),
        ("exclude_ports", &cond.exclude_ports),
        ("protocol", &cond.protocol),
        ("excluded_protocol", &cond.excluded_protocol),
        ("dscp", &cond.dscp),
        ("rule_set", &cond.rule_set),
        ("rule_set_with_subnets", &cond.rule_set_with_subnets),
        ("domain_ip_lists", &cond.domain_ip_lists),
        ("fully_routed_ips", &cond.fully_routed_ips),
        ("source_macs", &cond.source_macs),
        ("source_inbounds", &cond.source_inbounds),
    ];

    for (name, slice) in list_fields {
        let tokens = normalize_sig_tokens(slice.iter().map(String::as_str));
        if !tokens.is_empty() {
            has_rule_content = true;
            parts.push((name, tokens));
        }
    }

    for (name, raw) in [
        ("l4_proto", cond.l4_proto.as_str()),
        ("time_window", cond.time_window.as_str()),
    ] {
        let tokens = normalize_sig_tokens([raw]);
        if !tokens.is_empty() {
            has_rule_content = true;
            parts.push((name, tokens));
        }
    }

    let gmode = cond.geoip_mode.trim().to_ascii_lowercase();
    if !cond.geoip_codes.is_empty() || (!gmode.is_empty() && gmode != "include") {
        let eff_gmode = if gmode.is_empty() {
            "include".to_string()
        } else {
            gmode
        };
        parts.push(("geoip_mode", vec![eff_gmode]));
    }

    parts.push((
        "community_subnets",
        vec![if cond.community_subnets { "1" } else { "0" }.to_string()],
    ));

    if cond.invert {
        has_rule_content = true;
        parts.push(("invert", vec!["1".to_string()]));
    }

    if !has_rule_content {
        return None;
    }

    serde_json::to_string(&parts).ok()
}

fn cond_uf_find(parent: &mut [usize], mut x: usize) -> usize {
    while parent[x] != x {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    x
}

fn cond_uf_union(parent: &mut [usize], a: usize, b: usize) {
    let ra = cond_uf_find(parent, a);
    let rb = cond_uf_find(parent, b);
    if ra == rb {
        return;
    }
    if ra < rb {
        parent[rb] = ra;
    } else {
        parent[ra] = rb;
    }
}

fn is_cond_expr_ident_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'
}

fn replace_condition_expression_ids(expr: &str, id_remap: &HashMap<String, String>) -> String {
    let mut out = String::with_capacity(expr.len());
    let mut ident_start: Option<usize> = None;

    for (idx, ch) in expr.char_indices() {
        if is_cond_expr_ident_char(ch) {
            if ident_start.is_none() {
                ident_start = Some(idx);
            }
        } else {
            if let Some(start) = ident_start.take() {
                let ident = &expr[start..idx];
                if let Some(mapped) = id_remap.get(ident) {
                    out.push_str(mapped);
                } else {
                    out.push_str(ident);
                }
            }
            out.push(ch);
        }
    }

    if let Some(start) = ident_start {
        let ident = &expr[start..];
        if let Some(mapped) = id_remap.get(ident) {
            out.push_str(mapped);
        } else {
            out.push_str(ident);
        }
    }

    out
}

fn remap_cond_ref_vec(items: Vec<String>, id_remap: &HashMap<String, String>) -> Vec<String> {
    let mut out = Vec::with_capacity(items.len());
    let mut seen = std::collections::HashSet::with_capacity(items.len());
    for item in items {
        let trimmed = item.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mapped = id_remap.get(trimmed).map(String::as_str).unwrap_or(trimmed);
        if seen.insert(mapped.to_string()) {
            out.push(mapped.to_string());
        }
    }
    out
}

pub fn validate_tailscale_network_options(
    relay_port_raw: &str,
    mtu_raw: &str,
    label: &str,
) -> Result<(), String> {
    let rp = relay_port_raw.trim();
    if !rp.is_empty() {
        match rp.parse::<u32>() {
            Ok(p) if (1..=65535).contains(&p) => {}
            _ => {
                return Err(format!(
                    "{label} has invalid tailscale_relay_server_port '{rp}' (expected integer 1..65535). Aborted."
                ));
            }
        }
    }
    let mtu = mtu_raw.trim();
    if !mtu.is_empty() {
        if !mtu.bytes().all(|b| b.is_ascii_digit()) {
            return Err(format!(
                "{label} has invalid tailscale_system_interface_mtu '{mtu}' (expected integer 576..65535). Aborted."
            ));
        }
        match mtu.parse::<u32>() {
            Ok(m) if (576..=65535).contains(&m) => {}
            _ => {
                return Err(format!(
                    "{label} has out-of-range tailscale_system_interface_mtu '{mtu}' (expected 576..65535). Aborted."
                ));
            }
        }
    }
    Ok(())
}

impl OutboundSource {
    pub fn is_tailscale(&self) -> bool {
        self.source_type.trim().eq_ignore_ascii_case("tailscale")
    }

    pub fn is_native_tailscale(&self) -> bool {
        self.is_tailscale() && !self.is_embedded_tailscale()
    }

    pub fn is_embedded_tailscale(&self) -> bool {
        if !self.source_type.trim().eq_ignore_ascii_case("tailscale") {
            return false;
        }
        let ts_mode = self.tailscale_mode.trim().to_ascii_lowercase();
        if ts_mode == "native" {
            return false;
        }
        if matches!(ts_mode.as_str(), "singbox" | "embedded" | "tachyon-core") {
            return true;
        }
        let has_ts_cfg = !self.tailscale_auth_key.trim().is_empty()
            || !self.tailscale_control_url.trim().is_empty()
            || !self.tailscale_hostname.trim().is_empty()
            || !self.tailscale_use_exit_node.trim().is_empty()
            || self.tailscale_ephemeral
            || self.tailscale_exit_node_allow_lan_access
            || !self.tailscale_advertise_routes.is_empty()
            || self.tailscale_advertise_exit_node
            || !self.tailscale_relay_server_port.trim().is_empty()
            || !self.tailscale_relay_server_static_endpoints.is_empty()
            || self.tailscale_system_interface
            || !self.tailscale_system_interface_name.trim().is_empty()
            || !self.tailscale_system_interface_mtu.trim().is_empty()
            || !self.tailscale_udp_timeout.trim().is_empty();
        if has_ts_cfg {
            return true;
        }
        self.interface_name.trim().is_empty()
    }
}

impl RoutingSection {
    pub fn is_tailscale(&self) -> bool {
        self.action.trim().eq_ignore_ascii_case("tailscale")
            || self
                .connection_type
                .trim()
                .eq_ignore_ascii_case("tailscale")
            || (self.action.trim().is_empty()
                && (!self.tailscale_auth_key.trim().is_empty()
                    || !self.tailscale_use_exit_node.trim().is_empty()
                    || !self.tailscale_control_url.trim().is_empty()))
    }

    pub fn is_native_tailscale(&self) -> bool {
        self.is_tailscale() && self.tailscale_mode.trim().eq_ignore_ascii_case("native")
    }

    pub fn is_embedded_tailscale(&self) -> bool {
        self.is_tailscale() && !self.is_native_tailscale()
    }
}

impl InboundServer {
    pub fn is_tailscale(&self) -> bool {
        self.protocol.trim().eq_ignore_ascii_case("tailscale")
    }

    pub fn is_native_tailscale(&self) -> bool {
        self.is_tailscale() && self.tailscale_mode.trim().eq_ignore_ascii_case("native")
    }

    pub fn is_embedded_tailscale(&self) -> bool {
        self.is_tailscale() && !self.is_native_tailscale()
    }
}

impl RouterStoreData {
    pub fn seed_defaults(&mut self) {
        if self.conditions.is_empty() {
            self.conditions.push(TrafficCondition {
                id: "cond_media".to_string(),
                enabled: true,
                name: "YouTube & Media".to_string(),
                condition_type: "atomic".to_string(),
                community_lists: vec!["youtube".to_string(), "discord".to_string()],
                user_domains: vec!["googlevideo.com".to_string(), "ytimg.com".to_string()],
                ..Default::default()
            });
            self.conditions.push(TrafficCondition {
                id: "cond_ai".to_string(),
                enabled: true,
                name: "AI & Cloud Services".to_string(),
                condition_type: "atomic".to_string(),
                community_lists: vec![
                    "openai".to_string(),
                    "anthropic".to_string(),
                    "google_ai".to_string(),
                ],
                ..Default::default()
            });
        }
        if self.outbound_sources.is_empty() {
            self.outbound_sources.push(OutboundSource {
                id: "src_adaptive_desync".to_string(),
                enabled: true,
                name: "Adaptive Desync 2.0".to_string(),
                source_type: "desync".to_string(),
                desync_preset: "adaptive".to_string(),
                desync_auto_tune: true,
                ..Default::default()
            });
        }
        if self.balancers.is_empty() {
            self.balancers.push(BalancerConfig {
                id: "bal_fastest".to_string(),
                enabled: true,
                name: "Fastest Node (URLTest)".to_string(),
                balancer_type: "urltest".to_string(),
                mode: "least_test".to_string(),
                testing_url: "https://www.gstatic.com/generate_204".to_string(),
                check_interval: 180,
                tolerance: 50,
                sticky_hash: String::new(),
                passive_check: true,
                interrupt_exist_connections: false,
                active_check_interval: "15s".to_string(),
                check_timeout: "2s".to_string(),
                recovery_check_interval: "30s".to_string(),
                fastest_check_interval: "10m".to_string(),
                ..Default::default()
            });
        }
        if self.sections.is_empty() {
            self.sections.push(RoutingSection {
                id: "sec_media_desync".to_string(),
                enabled: true,
                label: "Media Adaptive Desync".to_string(),
                connection_type: "desync".to_string(),
                action: "desync".to_string(),
                condition_refs: vec!["cond_media".to_string()],
                outbound_source_refs: vec!["src_adaptive_desync".to_string()],
                ..Default::default()
            });
        }
    }

    fn mark_legacy_uci_imported(&mut self) {
        if !self
            .applied_migrations
            .iter()
            .any(|m| m == LEGACY_UCI_IMPORTED_MIGRATION)
        {
            self.applied_migrations
                .push(LEGACY_UCI_IMPORTED_MIGRATION.to_string());
        }
    }

    fn is_seeded_default_store(&self) -> bool {
        self.sections.len() == 1
            && self.sections[0].id == "sec_media_desync"
            && self.servers.is_empty()
            && self.outbound_sources.len() == 1
            && self.outbound_sources[0].id == "src_adaptive_desync"
    }

    /// Apply one-shot probe interval relaxation (`relax_probe_intervals_v1`) idempotently.
    /// Returns `true` when `applied_migrations` was updated so callers can persist the marker.
    pub fn apply_relax_probe_intervals_v1(&mut self) -> bool {
        const MIGRATION_ID: &str = "relax_probe_intervals_v1";
        if self.applied_migrations.iter().any(|m| m == MIGRATION_ID) {
            return false;
        }
        if matches!(
            self.settings.dns_check_interval.trim(),
            "10s" | "10" | "15s" | "15"
        ) {
            self.settings.dns_check_interval = "30s".to_string();
        }
        if self.settings.ai_proxy_health_interval == 30 {
            self.settings.ai_proxy_health_interval = 60;
        }
        if self.settings.ai_dns_interval == 60 {
            self.settings.ai_dns_interval = 180;
        }
        for bal in &mut self.balancers {
            if matches!(bal.active_check_interval.trim(), "5s" | "5") {
                bal.active_check_interval = "15s".to_string();
            }
            if matches!(bal.recovery_check_interval.trim(), "15s" | "15") {
                bal.recovery_check_interval = "30s".to_string();
            }
            if matches!(
                bal.urltest_active_check_interval.trim(),
                "5s" | "5" | "10s" | "10"
            ) {
                bal.urltest_active_check_interval = "30s".to_string();
            }
            if matches!(bal.check_interval, 5 | 10) {
                bal.check_interval = 30;
            }
        }
        self.applied_migrations.push(MIGRATION_ID.to_string());
        true
    }

    /// Apply one-shot migration for `dns_intercept_all` and `webrtc_leak_protect`
    /// from legacy `'0'` default to `'auto'` (`fail_closed_auto_defaults`).
    pub fn apply_fail_closed_auto_defaults(&mut self) -> bool {
        const MIGRATION_ID: &str = "fail_closed_auto_defaults";
        if self.applied_migrations.iter().any(|m| m == MIGRATION_ID) {
            return false;
        }
        if !self.settings.dns_intercept_all {
            self.settings.dns_intercept_all_mode = "auto".to_string();
        }
        if !self.settings.webrtc_leak_protect {
            self.settings.webrtc_leak_protect_mode = "auto".to_string();
        }
        self.applied_migrations.push(MIGRATION_ID.to_string());
        true
    }

    /// Apply one-shot migration for AI rule-sets (`ai_lists_1_8`):
    /// - Add `qwen` and `kimi` when a proxy section or proxy-only condition has >=2
    ///   per-provider AI lists and no `ai_all`.
    /// - Add `google_services` when absent everywhere and `google_ai` + (`ai_all` or
    ///   >=2 AI lists) are present (including split across proxy-only conditions).
    pub fn apply_ai_lists_1_8(&mut self) -> bool {
        const MIGRATION_ID: &str = "ai_lists_1_8";
        if self.applied_migrations.iter().any(|m| m == MIGRATION_ID) {
            return false;
        }

        const NON_PROXY_ACTIONS: [&str; 5] = ["direct", "bypass", "block", "dns", "hosts"];
        const PER_PROVIDER_AI_LISTS: [&str; 14] = [
            "openai",
            "anthropic",
            "google_ai",
            "xai",
            "openrouter",
            "cursor",
            "perplexity",
            "copilot",
            "deepseek",
            "midjourney",
            "elevenlabs",
            "ai_video",
            "ai_cloud_gpu",
            "huggingface",
        ];

        fn collect_cond_refs_recursive(
            conds: &[TrafficCondition],
            cond_idx_by_id: &HashMap<&str, usize>,
            refs: &[String],
            visited: &mut HashSet<String>,
        ) {
            for cname in refs {
                let cname = cname.trim();
                if cname.is_empty() || !visited.insert(cname.to_string()) {
                    continue;
                }
                if let Some(&idx) = cond_idx_by_id.get(cname) {
                    collect_cond_refs_recursive(
                        conds,
                        cond_idx_by_id,
                        &conds[idx].children,
                        visited,
                    );
                }
            }
        }

        fn update_target_lists(lists: &mut Vec<String>, has_google_services_anywhere: &mut bool) {
            let has_ai_all = lists.iter().any(|x| x == "ai_all");
            let has_google_ai = lists.iter().any(|x| x == "google_ai");
            let provider_count = PER_PROVIDER_AI_LISTS
                .iter()
                .filter(|&&k| lists.iter().any(|x| x == k))
                .count();

            if !has_ai_all && provider_count >= 2 {
                if !lists.iter().any(|x| x == "qwen") {
                    lists.push("qwen".to_string());
                }
                if !lists.iter().any(|x| x == "kimi") {
                    lists.push("kimi".to_string());
                }
            }

            if !*has_google_services_anywhere
                && has_google_ai
                && (has_ai_all || provider_count >= 2)
                && !lists.iter().any(|x| x == "google_services")
            {
                lists.push("google_services".to_string());
                *has_google_services_anywhere = true;
            }
        }

        let mut has_google_services_anywhere = self
            .conditions
            .iter()
            .any(|c| c.community_lists.iter().any(|x| x == "google_services"))
            || self
                .sections
                .iter()
                .any(|s| s.community_lists.iter().any(|x| x == "google_services"));

        let cond_idx_by_id: HashMap<&str, usize> = self
            .conditions
            .iter()
            .enumerate()
            .filter_map(|(idx, c)| {
                let id = c.id.trim();
                (!id.is_empty()).then_some((id, idx))
            })
            .collect();

        let mut cond_in_proxy: HashSet<String> = HashSet::new();
        let mut cond_in_non_proxy: HashSet<String> = HashSet::new();
        let mut proxy_sec_indices: Vec<usize> = Vec::new();

        for (sec_idx, sec) in self.sections.iter().enumerate() {
            let act_raw = if !sec.action.trim().is_empty() {
                sec.action.trim().to_ascii_lowercase()
            } else {
                sec.connection_type.trim().to_ascii_lowercase()
            };
            let is_non_proxy = NON_PROXY_ACTIONS.contains(&act_raw.as_str());
            let mut refs_map = HashSet::new();
            collect_cond_refs_recursive(
                &self.conditions,
                &cond_idx_by_id,
                &sec.condition_refs,
                &mut refs_map,
            );
            for cname in refs_map {
                if is_non_proxy {
                    cond_in_non_proxy.insert(cname);
                } else {
                    cond_in_proxy.insert(cname);
                }
            }
            if !is_non_proxy {
                proxy_sec_indices.push(sec_idx);
            }
        }

        for &sec_idx in &proxy_sec_indices {
            if !self.sections[sec_idx].community_lists.is_empty() {
                update_target_lists(
                    &mut self.sections[sec_idx].community_lists,
                    &mut has_google_services_anywhere,
                );
            }
        }
        for cond in &mut self.conditions {
            let cname = cond.id.trim();
            if !cname.is_empty()
                && cond_in_proxy.contains(cname)
                && !cond_in_non_proxy.contains(cname)
                && !cond.community_lists.is_empty()
            {
                update_target_lists(&mut cond.community_lists, &mut has_google_services_anywhere);
            }
        }

        // Handle proxy sections whose `ai_all` and `google_ai` live in separate proxy-only conditions.
        if !has_google_services_anywhere {
            let cond_idx_by_id_owned: HashMap<String, usize> = self
                .conditions
                .iter()
                .enumerate()
                .filter_map(|(idx, c)| {
                    let id = c.id.trim().to_string();
                    (!id.is_empty()).then_some((id, idx))
                })
                .collect();
            for &sec_idx in &proxy_sec_indices {
                if has_google_services_anywhere {
                    break;
                }
                let mut refs_map = HashSet::new();
                collect_cond_refs_recursive(
                    &self.conditions,
                    &cond_idx_by_id_owned
                        .iter()
                        .map(|(k, &v)| (k.as_str(), v))
                        .collect(),
                    &self.sections[sec_idx].condition_refs,
                    &mut refs_map,
                );
                let mut combined: Vec<String> = self.sections[sec_idx].community_lists.clone();
                enum GoogleTarget {
                    Section(usize),
                    Condition(usize),
                }
                let mut google_target = self.sections[sec_idx]
                    .community_lists
                    .iter()
                    .any(|x| x == "google_ai")
                    .then_some(GoogleTarget::Section(sec_idx));

                let mut sorted_refs: Vec<String> = refs_map.into_iter().collect();
                sorted_refs.sort();
                for cname in sorted_refs {
                    if let Some(&c_idx) = cond_idx_by_id_owned.get(&cname) {
                        combined.extend(self.conditions[c_idx].community_lists.iter().cloned());
                        if google_target.is_none()
                            && cond_in_proxy.contains(&cname)
                            && !cond_in_non_proxy.contains(&cname)
                            && self.conditions[c_idx]
                                .community_lists
                                .iter()
                                .any(|x| x == "google_ai")
                        {
                            google_target = Some(GoogleTarget::Condition(c_idx));
                        }
                    }
                }
                if combined.iter().any(|x| x == "ai_all")
                    && combined.iter().any(|x| x == "google_ai")
                    && let Some(target) = google_target
                {
                    let lists = match target {
                        GoogleTarget::Section(idx) => &mut self.sections[idx].community_lists,
                        GoogleTarget::Condition(idx) => &mut self.conditions[idx].community_lists,
                    };
                    if !lists.iter().any(|x| x == "google_services") {
                        lists.push("google_services".to_string());
                        has_google_services_anywhere = true;
                    }
                }
            }
        }

        self.applied_migrations.push(MIGRATION_ID.to_string());
        true
    }

    /// Collapse duplicate cloned atomic `TrafficCondition` entries (`*_copy*`, `*_2*`, or
    /// matching `"<X> Rules"` labels with identical rule signatures) and rewrite condition
    /// references in sections and composite conditions using token-boundary matching.
    ///
    /// Returns the number of duplicate conditions removed.
    pub fn deduplicate_cloned_conditions(&mut self) -> usize {
        let n = self.conditions.len();
        if n < 2 {
            return 0;
        }

        let mut parent: Vec<usize> = (0..n).collect();
        let mut by_base_sig: HashMap<(String, String), Vec<usize>> = HashMap::new();
        let mut by_name_sig: HashMap<(String, String), Vec<usize>> = HashMap::new();

        for (idx, cond) in self.conditions.iter().enumerate() {
            let Some(sig) = condition_rule_signature(cond) else {
                continue;
            };
            let cid = cond.id.trim();
            if !cid.is_empty() {
                let base = condition_clone_base_id(cid);
                by_base_sig
                    .entry((base, sig.clone()))
                    .or_default()
                    .push(idx);
            }
            let cname = cond.name.trim();
            if cname.ends_with(" Rules") {
                by_name_sig
                    .entry((cname.to_string(), sig))
                    .or_default()
                    .push(idx);
            }
        }

        for indices in by_base_sig.values().chain(by_name_sig.values()) {
            if indices.len() > 1 {
                let first = indices[0];
                for &other in &indices[1..] {
                    cond_uf_union(&mut parent, first, other);
                }
            }
        }

        let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
        for idx in 0..n {
            let root = cond_uf_find(&mut parent, idx);
            groups.entry(root).or_default().push(idx);
        }

        let mut removed_mask = vec![false; n];
        let mut id_remap: HashMap<String, String> = HashMap::new();

        for mut members in groups.into_values() {
            if members.len() < 2 {
                continue;
            }
            members.sort_unstable();

            let canon_idx = members
                .iter()
                .copied()
                .find(|&idx| {
                    let cid = self.conditions[idx].id.trim();
                    !cid.is_empty() && cid == condition_clone_base_id(cid)
                })
                .unwrap_or(members[0]);

            let canon_id = self.conditions[canon_idx].id.trim().to_string();
            if canon_id.is_empty() {
                continue;
            }

            for &idx in &members {
                if idx == canon_idx {
                    continue;
                }
                let dup_id = self.conditions[idx].id.trim();
                if !dup_id.is_empty() && dup_id != canon_id {
                    id_remap.insert(dup_id.to_string(), canon_id.clone());
                }
                removed_mask[idx] = true;
            }
        }

        let before_len = self.conditions.len();
        if !removed_mask.iter().any(|&r| r) {
            return 0;
        }

        let mut idx = 0usize;
        self.conditions.retain(|_| {
            let keep = !removed_mask[idx];
            idx += 1;
            keep
        });
        let removed_count = before_len - self.conditions.len();

        if !id_remap.is_empty() {
            for sec in &mut self.sections {
                sec.condition_refs =
                    remap_cond_ref_vec(std::mem::take(&mut sec.condition_refs), &id_remap);
                if !sec.condition_expression.is_empty() {
                    sec.condition_expression =
                        replace_condition_expression_ids(&sec.condition_expression, &id_remap);
                }
            }
            for cond in &mut self.conditions {
                cond.children = remap_cond_ref_vec(std::mem::take(&mut cond.children), &id_remap);
                if !cond.expression.is_empty() {
                    cond.expression = replace_condition_expression_ids(&cond.expression, &id_remap);
                }
            }
        }

        removed_count
    }

    /// Import router configuration from explicit UCI paths (first readable non-empty wins)
    /// and load subscription node caches from `sub_cache_dir`.
    pub fn import_legacy_router_files_with_cache(
        &mut self,
        uci_paths: &[&Path],
        sub_cache_dir: &Path,
    ) -> usize {
        let raw = uci_paths.iter().find_map(|p| {
            std::fs::read_to_string(p)
                .ok()
                .filter(|s| !s.trim().is_empty())
        });
        let Some(raw) = raw else {
            return 0;
        };
        let blocks = parse_legacy_uci_blocks(&raw);
        let imported = self.import_from_blocks_with_cache(&blocks, sub_cache_dir);
        if imported > 0 {
            self.mark_legacy_uci_imported();
        }
        imported
    }

    /// Import router configuration from `primary` (`/etc/config/tachyon`), falling back to `backup`
    /// (`/etc/tachyon/backup-pre-2.0/tachyon.uci`) if the primary file is absent or empty.
    pub fn import_legacy_router_files_from(&mut self, primary: &Path, backup: &Path) -> usize {
        self.import_legacy_router_files_with_cache(
            &[primary, backup],
            Path::new("/etc/tachyon/subscription-cache"),
        )
    }

    /// Import existing router configuration from `/etc/config/tachyon` (with fallback to
    /// `/etc/tachyon/backup-pre-2.0/tachyon.uci`) and `/etc/tachyon/subscription-cache/*.json`
    /// into native `RouterStoreData` (`tachyon.json`) with zero runtime UCI dependency.
    pub fn import_legacy_router_files(&mut self) -> usize {
        self.import_legacy_router_files_from(
            Path::new("/etc/config/tachyon"),
            Path::new(LEGACY_UCI_BACKUP_PATH),
        )
    }

    /// Synchronize directly from the pure-Rust JSON sections map (`config_sections.json`)
    /// into `RouterStoreData` (`tachyon.json`) with zero UCI dependency.
    pub fn import_from_json_sections(
        &mut self,
        sections_map: &serde_json::Map<String, Value>,
    ) -> usize {
        let had_legacy_marker = self
            .applied_migrations
            .iter()
            .any(|m| m == LEGACY_UCI_IMPORTED_MIGRATION);
        let mut indexed: Vec<(usize, &String, &serde_json::Map<String, Value>)> = sections_map
            .iter()
            .filter_map(|(k, v)| {
                let obj = v.as_object()?;
                let idx = obj
                    .get(".index")
                    .and_then(Value::as_u64)
                    .map(|n| n as usize)
                    .unwrap_or(usize::MAX);
                Some((idx, k, obj))
            })
            .collect();
        indexed.sort_by_key(|(idx, _, _)| *idx);

        let mut blocks = Vec::with_capacity(indexed.len());
        for (_, sec_key, obj) in indexed {
            let kind = obj
                .get(".type")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            if kind.is_empty() {
                continue;
            }
            let name = obj
                .get(".name")
                .and_then(Value::as_str)
                .unwrap_or(sec_key.as_str())
                .trim()
                .to_string();
            let mut options = HashMap::new();
            let mut lists = HashMap::new();
            for (k, v) in obj {
                if k.starts_with('.') {
                    continue;
                }
                match v {
                    Value::String(s) => {
                        options.insert(k.clone(), s.clone());
                    }
                    Value::Bool(b) => {
                        options.insert(
                            k.clone(),
                            if *b { "1".to_string() } else { "0".to_string() },
                        );
                    }
                    Value::Number(n) => {
                        options.insert(k.clone(), n.to_string());
                    }
                    Value::Array(arr) => {
                        let vec_str: Vec<String> = arr
                            .iter()
                            .filter_map(|item| match item {
                                Value::String(s) => Some(s.clone()),
                                Value::Number(n) => Some(n.to_string()),
                                Value::Bool(b) => {
                                    Some(if *b { "1".to_string() } else { "0".to_string() })
                                }
                                _ => None,
                            })
                            .collect();
                        if let Some(first) = vec_str.first() {
                            options.insert(k.clone(), first.clone());
                        }
                        lists.insert(k.clone(), vec_str);
                    }
                    _ => {}
                }
            }
            blocks.push(LegacyUciBlock {
                kind,
                name,
                options,
                lists,
            });
        }
        let imported = self.import_from_blocks(&blocks);
        if had_legacy_marker || imported > 0 {
            self.mark_legacy_uci_imported();
        }
        imported
    }

    /// Reverse-convert `RouterStoreData` (`tachyon.json`) back into a UCI-compatible JSON
    /// sections map (`config_sections.json`), preserving frontend-only fields (e.g.
    /// `ui_prefs_json`) present in `existing`.
    #[allow(dead_code)]
    pub fn to_json_sections(&self, existing: Option<&Value>) -> Value {
        sync_store_to_json_sections(self, existing)
    }

    fn import_from_blocks(&mut self, blocks: &[LegacyUciBlock]) -> usize {
        self.import_from_blocks_with_cache(blocks, Path::new("/etc/tachyon/subscription-cache"))
    }

    fn import_from_blocks_with_cache(
        &mut self,
        blocks: &[LegacyUciBlock],
        sub_cache_dir: &Path,
    ) -> usize {
        if blocks.is_empty() {
            return 0;
        }

        let selector_state: HashMap<String, String> =
            std::fs::read_to_string(runtime_state_dir().join("selector_state.json"))
                .ok()
                .or_else(|| std::fs::read_to_string("/etc/tachyon/selector_state.json").ok())
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();

        let prev_sources: HashMap<String, OutboundSource> = self
            .outbound_sources
            .drain(..)
            .map(|s| (s.id.clone(), s))
            .collect();

        self.sections.clear();
        self.conditions.clear();
        self.outbound_groups.clear();
        self.balancers.clear();
        self.servers.clear();
        self.profiles.clear();
        self.schedules.clear();
        self.applied_migrations.clear();

        let parse_bool = |v: &str| v == "1" || v.eq_ignore_ascii_case("true") || v == "yes";
        let mut imported = 0usize;

        for b in blocks {
            match b.kind.as_str() {
                "settings" => {
                    if let Some(v) = b.opt("proxy_mode") {
                        self.settings.proxy_mode = v.to_string();
                    }
                    if let Some(v) = b.opt("routing_strategy") {
                        self.settings.routing_strategy = v.to_string();
                    }
                    if let Some(v) = b.opt("default_tunnel_section") {
                        self.settings.default_tunnel_section = v.to_string();
                    }
                    if let Some(v) = b.opt("tun_interface") {
                        self.settings.tun_interface = v.to_string();
                    }
                    if let Some(v) = b.opt("tun_stack") {
                        self.settings.tun_stack = v.to_string();
                    }
                    if let Some(v) = b.opt("tun_auto_route") {
                        self.settings.tun_auto_route = parse_bool(v);
                    }
                    if let Some(v) = b.opt("tun_kill_switch") {
                        self.settings.tun_kill_switch = parse_bool(v);
                    }
                    if let Some(v) = b.opt("tun_mtu").and_then(|s| s.parse().ok()) {
                        self.settings.tun_mtu = v;
                    }
                    if let Some(v) = b.opt("tun_inet4") {
                        let t = v.trim();
                        if !t.is_empty() {
                            self.settings.tun_inet4 = t.to_string();
                        }
                    }
                    if let Some(v) = b.opt("tun_inet6") {
                        self.settings.tun_inet6 = v.trim().to_string();
                    }
                    if let Some(v) = b.opt("tun_gso") {
                        self.settings.tun_gso = parse_bool(v);
                    }
                    if let Some(v) = b.opt("tun_endpoint_independent_nat") {
                        self.settings.tun_endpoint_independent_nat = parse_bool(v);
                    }
                    if let Some(v) = b.opt("tun_udp_timeout") {
                        self.settings.tun_udp_timeout = v.to_string();
                    }
                    if let Some(v) = b.opt("smart_queue").or_else(|| b.opt("sqm_enabled")) {
                        self.settings.smart_queue = parse_bool(v);
                    }
                    if let Some(v) = b.opt("sqm_download_kbps").and_then(|s| s.parse().ok()) {
                        self.settings.sqm_download_kbps = v;
                    }
                    if let Some(v) = b.opt("sqm_upload_kbps").and_then(|s| s.parse().ok()) {
                        self.settings.sqm_upload_kbps = v;
                    }
                    if let Some(v) = b.opt("sqm_interface") {
                        self.settings.sqm_interface = v.to_string();
                    }
                    if let Some(v) = b.opt("tcp_profile") {
                        self.settings.tcp_profile = normalize_tcp_profile(v);
                    }
                    if let Some(v) = b.opt("tcp_bbr") {
                        self.settings.tcp_bbr = parse_bool(v);
                    }
                    if let Some(v) = b.opt("selector_auto_failover") {
                        self.settings.selector_auto_failover = parse_bool(v);
                    }
                    let src_ifaces = b.clean_tokens(&["source_network_interfaces"]);
                    if !src_ifaces.is_empty() {
                        self.settings.source_network_interfaces = src_ifaces;
                    }
                    let excluded_ips = b.clean_tokens(&["excluded_ips"]);
                    if !excluded_ips.is_empty() {
                        self.settings.excluded_ips = excluded_ips;
                    }
                    if let Some(v) = b.opt("cache_path") {
                        let trimmed = v.trim();
                        if trimmed.starts_with("/tmp/") || trimmed.starts_with("/var/run/") {
                            self.settings.cache_path = trimmed.to_string();
                        } else {
                            self.settings.cache_path = "/tmp/tachyon-core/cache.db".to_string();
                        }
                    }
                    if let Some(v) = b.opt("enable_output_network_interface") {
                        self.settings.enable_output_network_interface = parse_bool(v);
                    }
                    if let Some(v) = b.opt("output_network_interface") {
                        self.settings.output_network_interface = v.to_string();
                    }
                    if let Some(v) = b.opt("ipv6_leak_guard") {
                        self.settings.ipv6_leak_guard = parse_bool(v);
                    }
                    if let Some(v) = b.opt("ipv6_mode") {
                        self.settings.ipv6_mode = normalize_ipv6_mode(v);
                        self.settings.enable_ipv6 = self.settings.ipv6_mode == "dual_stack";
                    } else if let Some(v) = b.opt("enable_ipv6") {
                        let en = parse_bool(v);
                        self.settings.enable_ipv6 = en;
                        self.settings.ipv6_mode = if en {
                            "dual_stack".to_string()
                        } else {
                            "off".to_string()
                        };
                    }
                    if let Some(v) = b.opt("enable_yacd") {
                        self.settings.enable_yacd = parse_bool(v);
                    }
                    if let Some(v) = b.opt("enable_yacd_wan_access") {
                        self.settings.enable_yacd_wan_access = parse_bool(v);
                    }
                    if let Some(v) = b.opt("yacd_secret_key") {
                        self.settings.yacd_secret_key = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_type") {
                        self.settings.dns_type = v.to_string();
                    }
                    let dns_srvs = b.list("dns_server");
                    if !dns_srvs.is_empty() {
                        self.settings.dns_servers = dns_srvs;
                    }
                    let boot_srvs = b.list("bootstrap_dns_server");
                    if !boot_srvs.is_empty() {
                        self.settings.bootstrap_dns_servers = boot_srvs;
                    }
                    let fb_srvs = b.list("dns_fallback_server");
                    if !fb_srvs.is_empty() {
                        self.settings.dns_fallback_servers = fb_srvs;
                    }
                    if let Some(v) = b.opt("fallback_dns_server") {
                        self.settings.fallback_dns_server = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_strategy") {
                        self.settings.dns_strategy = normalize_dns_strategy(v);
                    }
                    if let Some(v) = b.opt("dns_upstream_mode") {
                        self.settings.dns_upstream_mode = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_rewrite_ttl").and_then(|s| s.parse().ok()) {
                        self.settings.dns_rewrite_ttl = v;
                    }
                    if let Some(v) = b.opt("dns_check_interval") {
                        self.settings.dns_check_interval = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_recovery_check_interval") {
                        self.settings.dns_recovery_check_interval = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_check_timeout") {
                        self.settings.dns_check_timeout = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_failure_threshold").and_then(|s| s.parse().ok()) {
                        self.settings.dns_failure_threshold = v;
                    }
                    if let Some(v) = b.opt("dns_recovery_threshold").and_then(|s| s.parse().ok()) {
                        self.settings.dns_recovery_threshold = v;
                    }
                    if let Some(v) = b.opt("dns_detour_enabled") {
                        self.settings.dns_detour_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("dns_detour_section") {
                        self.settings.dns_detour_section = v.to_string();
                    }
                    if let Some(v) = b.opt("dns_local_cache") {
                        self.settings.dns_local_cache = parse_bool(v);
                    }
                    if let Some(v) = b.opt("dns_turbo_cache") {
                        self.settings.dns_turbo_cache = parse_bool(v);
                    }
                    if let Some(v) = b.opt("dns_cache_size").and_then(|s| s.parse().ok()) {
                        self.settings.dns_cache_size = v;
                    }
                    if let Some(v) = b.opt("dns_doq_ech") {
                        self.settings.dns_doq_ech = parse_bool(v);
                    }
                    if let Some(v) = b.opt("fakeip_enabled") {
                        self.settings.fakeip_enabled = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("fakeip_inet4_range")
                        .or_else(|| b.opt("fakeip_range"))
                    {
                        self.settings.fakeip_inet4_range = v.to_string();
                    }
                    if let Some(v) = b.opt("fakeip_inet6_range") {
                        self.settings.fakeip_inet6_range = v.to_string();
                    }
                    let fip_ex = b.list("fakeip_exclude");
                    if !fip_ex.is_empty() {
                        self.settings.fakeip_exclude = fip_ex;
                    }
                    if let Some(v) = b.opt("dont_touch_dhcp") {
                        self.settings.dont_touch_dhcp = parse_bool(v);
                    }
                    if let Some(v) = b.opt("hosts_enabled") {
                        self.settings.hosts_enabled = parse_bool(v);
                    }
                    let h_urls = b.list("hosts_list_urls");
                    if !h_urls.is_empty() {
                        self.settings.hosts_list_urls = h_urls;
                    }
                    let s_hosts = b.list("static_hosts");
                    if !s_hosts.is_empty() {
                        self.settings.static_hosts = s_hosts;
                    }
                    if let Some(v) = b.opt("lite_mode") {
                        self.settings.lite_mode = parse_bool(v);
                    }
                    if let Some(v) = b.opt("ui_mode") {
                        self.settings.ui_mode = normalize_ui_mode(v);
                    }
                    if let Some(v) = b.opt("sidebar_pos") {
                        self.settings.sidebar_pos = v.to_string();
                    }
                    if let Some(v) = b.opt("accent_theme").or_else(|| b.opt("theme_accent")) {
                        self.settings.accent_theme = v.to_string();
                    }
                    if let Some(v) = b.opt("lang").or_else(|| b.opt("language")) {
                        self.settings.lang = v.to_string();
                    }
                    if let Some(v) = b.opt("default_tab") {
                        self.settings.default_tab = v.to_string();
                    }
                    let t_order = b.list("tab_order");
                    if !t_order.is_empty() {
                        self.settings.tab_order = t_order;
                    }
                    if let Some(v) = b.opt("sidebar_collapsed") {
                        self.settings.sidebar_collapsed = parse_bool(v);
                    }
                    if let Some(v) = b.opt("dashboard_preset") {
                        self.settings.dashboard_preset = v.to_string();
                    }
                    if let Some(v) = b.opt("dashboard_widgets_json") {
                        self.settings.dashboard_widgets_json = v.to_string();
                    }
                    if let Some(v) = b.opt("studio_views_json") {
                        self.settings.studio_views_json = v.to_string();
                    }
                    if b.lists.contains_key("hidden_tabs") || b.options.contains_key("hidden_tabs")
                    {
                        self.settings.hidden_tabs = b.list("hidden_tabs");
                    }
                    if let Some(v) = b.opt("show_tab_dashboard") {
                        self.settings.show_tab_dashboard = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("show_tab_section")
                        .or_else(|| b.opt("show_tab_sections"))
                    {
                        self.settings.show_tab_section = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("show_tab_server")
                        .or_else(|| b.opt("show_tab_servers"))
                    {
                        self.settings.show_tab_server = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("show_tab_profile")
                        .or_else(|| b.opt("show_tab_profiles"))
                    {
                        self.settings.show_tab_profile = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_schedule") {
                        self.settings.show_tab_schedule = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_guest_mode") {
                        self.settings.show_tab_guest_mode = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_local_devices") {
                        self.settings.show_tab_local_devices = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_monitoring") {
                        self.settings.show_tab_monitoring = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_diagnostic") {
                        self.settings.show_tab_diagnostic = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_updates") {
                        self.settings.show_tab_updates = parse_bool(v);
                    }
                    if let Some(v) = b.opt("show_tab_telegram") {
                        self.settings.show_tab_telegram = parse_bool(v);
                    }
                    if let Some(v) = b.opt("disable_quic") {
                        self.settings.disable_quic = parse_bool(v);
                    }
                    if let Some(v) = b.opt("disable_quic_mode") {
                        self.settings.disable_quic_mode = v.to_string();
                    }
                    if let Some(v) = b.opt("block_doh") {
                        self.settings.block_doh = parse_bool(v);
                    }
                    if let Some(v) = b.opt("dns_intercept_all") {
                        let mode = normalize_auto_mode(v);
                        self.settings.dns_intercept_all_mode = mode.clone();
                        self.settings.dns_intercept_all = mode == "1";
                    }
                    if let Some(v) = b.opt("webrtc_leak_protect") {
                        let mode = normalize_auto_mode(v);
                        self.settings.webrtc_leak_protect_mode = mode.clone();
                        self.settings.webrtc_leak_protect = mode == "1";
                    }
                    if let Some(v) = b.opt("tailscale_web_access") {
                        self.settings.tailscale_web_access = normalize_auto_mode(v);
                    }
                    if let Some(v) = b.opt("route_router_traffic") {
                        self.settings.route_router_traffic = parse_bool(v);
                    }
                    if let Some(v) = b.opt("route_router_traffic_section") {
                        self.settings.route_router_traffic_section = v.to_string();
                    }
                    if let Some(v) = b.opt("wifi_calling_direct") {
                        self.settings.wifi_calling_direct = parse_bool(v);
                    }
                    if let Some(v) = b.opt("isolate_p2p").or_else(|| b.opt("torrent_isolation")) {
                        self.settings.isolate_p2p = parse_bool(v);
                    }
                    if let Some(v) = b.opt("bittorrent_policy") {
                        self.settings.bittorrent_policy = v.to_string();
                    }
                    if let Some(v) = b.opt("p2p_ports") {
                        self.settings.p2p_ports = v.to_string();
                    }
                    if let Some(v) = b.opt("direct_bypass_enabled") {
                        self.settings.direct_bypass_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("direct_bypass_port").and_then(|s| s.parse().ok()) {
                        self.settings.direct_bypass_port = v;
                    }
                    if let Some(v) = b
                        .opt("game_console_optimizer")
                        .or_else(|| b.opt("console_gaming_mode"))
                    {
                        self.settings.game_console_optimizer = parse_bool(v);
                    }
                    let gc_ips = b.list("game_console_ips");
                    if !gc_ips.is_empty() {
                        self.settings.game_console_ips = gc_ips;
                    }
                    if let Some(v) = b.opt("exclude_ntp") {
                        self.settings.exclude_ntp = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("torrserver_direct_enabled")
                        .or_else(|| b.opt("torrserver_direct"))
                    {
                        self.settings.torrserver_direct_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("enable_watchdog") {
                        self.settings.enable_watchdog = parse_bool(v);
                    }
                    if let Some(v) = b.opt("emergency_direct_bypass") {
                        self.settings.emergency_direct_bypass = parse_bool(v);
                    }
                    if let Some(v) = b.opt("wan_failover_enabled") {
                        self.settings.wan_failover_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("wan_failover_primary") {
                        self.settings.wan_failover_primary = v.to_string();
                    }
                    if let Some(v) = b.opt("wan_failover_backup") {
                        self.settings.wan_failover_backup = v.to_string();
                    }
                    let wf_hosts = b.list("wan_failover_probe_hosts");
                    if !wf_hosts.is_empty() {
                        self.settings.wan_failover_probe_hosts = wf_hosts;
                    }
                    if let Some(v) = b.opt("recovery_bypass") {
                        self.settings.recovery_bypass = parse_bool(v);
                    }
                    if let Some(v) = b.opt("memory_limit_mb").and_then(|s| s.parse().ok()) {
                        self.settings.memory_limit_mb = v;
                    }
                    if let Some(v) = b.opt("log_level") {
                        self.settings.log_level = v.to_string();
                    }
                    if let Some(v) = b.opt("smart_detect") {
                        self.settings.smart_detect = parse_bool(v);
                    }
                    if let Some(v) = b.opt("smart_detect_mode") {
                        self.settings.smart_detect_mode = v.to_string();
                    }
                    let sd_secs = b.list("smart_detect_sections");
                    if !sd_secs.is_empty() {
                        self.settings.smart_detect_sections = sd_secs;
                    }
                    if let Some(v) = b.opt("list_update_enabled") {
                        self.settings.list_update_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("update_interval") {
                        self.settings.update_interval = v.to_string();
                    }
                    if let Some(v) = b.opt("github_mirror") {
                        self.settings.github_mirror = v.to_string();
                    }
                    if let Some(v) = b.opt("github_token") {
                        self.settings.github_token = v.to_string();
                    }
                    if let Some(v) = b.opt("download_lists_via_proxy") {
                        self.settings.download_lists_via_proxy = parse_bool(v);
                    }
                    if let Some(v) = b.opt("download_lists_via_proxy_section") {
                        self.settings.download_lists_via_proxy_section = v.to_string();
                    }
                    if let Some(v) = b.opt("download_components_via_proxy") {
                        self.settings.download_components_via_proxy = parse_bool(v);
                    }
                    if let Some(v) = b.opt("download_components_via_proxy_section") {
                        self.settings.download_components_via_proxy_section = v.to_string();
                    }
                    if let Some(v) = b.opt("component_update_check_enabled") {
                        self.settings.component_update_check_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("component_update_check_interval") {
                        self.settings.component_update_check_interval = v.to_string();
                    }
                    if let Some(v) = b.opt("component_auto_update_enabled") {
                        self.settings.component_auto_update_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("component_auto_update_mode") {
                        self.settings.component_auto_update_mode = v.to_string();
                    }
                    if let Some(v) = b.opt("component_auto_update_time") {
                        self.settings.component_auto_update_time = v.to_string();
                    }
                    if let Some(v) = b.opt("component_auto_update_window_start") {
                        self.settings.component_auto_update_window_start = v.to_string();
                    }
                    if let Some(v) = b.opt("component_auto_update_window_end") {
                        self.settings.component_auto_update_window_end = v.to_string();
                    }
                    if let Some(v) = b.opt("component_auto_update_max_connections")
                        && let Ok(n) = v.trim().parse::<u32>()
                    {
                        self.settings.component_auto_update_max_connections = n;
                    }
                    if let Some(v) = b.opt("component_auto_update_max_clients")
                        && let Ok(n) = v.trim().parse::<u32>()
                    {
                        self.settings.component_auto_update_max_clients = n;
                    }
                    let auto_targets = b.list("component_auto_update_targets");
                    if !auto_targets.is_empty() {
                        self.settings.component_auto_update_targets = auto_targets;
                    }
                    if let Some(v) = b.opt("component_backup_enabled") {
                        self.settings.component_backup_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("latency_test_url") {
                        self.settings.latency_test_url = v.to_string();
                    }
                    if let Some(v) = b.opt("latency_test_mode") {
                        self.settings.latency_test_mode = v.to_string();
                    }
                    if let Some(v) = b.opt("auto_heal_enabled") {
                        self.settings.auto_heal_enabled = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("auto_heal_interval_mins")
                        .and_then(|s| s.parse().ok())
                    {
                        self.settings.auto_heal_interval_mins = v;
                    }
                    if let Some(v) = b.opt("enable_ai_doctor") {
                        self.settings.enable_ai_doctor = parse_bool(v);
                    }
                    if let Some(v) = b.opt("ai_doctor_provider") {
                        self.settings.ai_doctor_provider = v.to_string();
                    }
                    if let Some(v) = b.opt("ai_doctor_model") {
                        self.settings.ai_doctor_model = v.to_string();
                    }
                    if let Some(v) = b.opt("ai_doctor_api_key") {
                        self.settings.ai_doctor_api_key = v.to_string();
                    }
                    if let Some(v) = b
                        .opt("ai_doctor_custom_url")
                        .or_else(|| b.opt("ai_doctor_base_url"))
                    {
                        self.settings.ai_doctor_custom_url = v.to_string();
                    }
                    if let Some(v) = b.opt("ai_doctor_lang") {
                        self.settings.ai_doctor_lang = v.to_string();
                    }
                    if let Some(v) = b.opt("ai_temperature").and_then(|s| s.parse().ok()) {
                        self.settings.ai_temperature = v;
                    }
                    if let Some(v) = b.opt("ai_max_tokens").and_then(|s| s.parse().ok()) {
                        self.settings.ai_max_tokens = v;
                    }
                    if let Some(v) = b
                        .opt("ai_metrics_retention_hours")
                        .and_then(|s| s.parse().ok())
                    {
                        self.settings.ai_metrics_retention_hours = v;
                    }
                    if let Some(v) = b.opt("ai_proxy_health_enabled") {
                        self.settings.ai_proxy_health_enabled = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("ai_proxy_health_interval")
                        .and_then(|s| s.parse().ok())
                    {
                        self.settings.ai_proxy_health_interval = v;
                    }
                    if let Some(v) = b
                        .opt("ai_proxy_health_fail_threshold")
                        .and_then(|s| s.parse().ok())
                    {
                        self.settings.ai_proxy_health_fail_threshold = v;
                    }
                    if let Some(v) = b.opt("ai_proxy_health_url") {
                        self.settings.ai_proxy_health_url = v.to_string();
                    }
                    if let Some(v) = b.opt("ai_dns_continuous_enabled") {
                        self.settings.ai_dns_continuous_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("ai_dns_interval").and_then(|s| s.parse().ok()) {
                        self.settings.ai_dns_interval = v;
                    }
                    if let Some(v) = b.opt("server_subscription_enabled") {
                        self.settings.server_subscription_enabled = parse_bool(v);
                    }
                    if let Some(v) = b.opt("server_subscription_token") {
                        self.settings.server_subscription_token = v.to_string();
                    }
                    if let Some(v) = b.opt("server_subscription_host") {
                        self.settings.server_subscription_host = v.to_string();
                    }
                    if let Some(v) = b.opt("server_subscription_format") {
                        self.settings.server_subscription_format = v.to_string();
                    }
                    if let Some(v) = b.opt("server_subscription_title") {
                        self.settings.server_subscription_title = v.to_string();
                    }
                    if let Some(v) = b.opt("agent_api_token") {
                        self.settings.agent_api_token = v.to_string();
                    }
                    if let Some(v) = b
                        .opt("snapshot_enabled")
                        .or_else(|| b.opt("snapshot_enable"))
                    {
                        self.settings.snapshot_enabled = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("snapshot_max_count")
                        .or_else(|| b.opt("snapshot_max"))
                        .and_then(|s| s.parse().ok())
                    {
                        self.settings.snapshot_max_count = v;
                    }
                    let cors = b.list("cors_origins");
                    if !cors.is_empty() {
                        self.settings.cors_origins = cors;
                    }
                    if let Some(v) = b.opt("session_ttl_secs").and_then(|s| s.parse().ok()) {
                        self.settings.session_ttl_secs = v;
                    }
                    self.applied_migrations = b.list("applied_migrations");
                    self.settings.subscription_engine = "core".to_string();
                    imported += 1;
                }
                "telegram" => {
                    self.telegram.enabled = b.opt("enabled").is_some_and(parse_bool);
                    self.telegram.bot_token = b.opt("bot_token").unwrap_or("").to_string();
                    let mut id_tokens = b.list("admin_ids");
                    if id_tokens.is_empty() {
                        id_tokens = b.list("allowed_chat_ids");
                    }
                    if id_tokens.is_empty() {
                        id_tokens = b.list("admin_id");
                    }
                    self.telegram.admin_ids = id_tokens
                        .iter()
                        .flat_map(|s| s.split([',', ' ']))
                        .filter_map(|s| s.trim().parse::<i64>().ok())
                        .collect();
                    self.telegram.router_name = b.opt("router_name").unwrap_or("").to_string();
                    self.telegram.poll_interval = b
                        .opt("poll_interval")
                        .or_else(|| b.opt("polling_interval"))
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(5);
                    self.telegram.bot_proxy_section =
                        b.opt("bot_proxy_section").unwrap_or("").to_string();
                    if let Some(v) = b.opt("language") {
                        self.telegram.language = v.to_string();
                    }
                    if let Some(v) = b.opt("notify_crash") {
                        self.telegram.notify_crash = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_restart") {
                        self.telegram.notify_restart = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_server_switch") {
                        self.telegram.notify_server_switch = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_subscription") {
                        self.telegram.notify_subscription = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_dns_leak") {
                        self.telegram.notify_dns_leak = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_cert") {
                        self.telegram.notify_cert = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_auto_update") {
                        self.telegram.notify_auto_update = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_honeypot") {
                        self.telegram.notify_honeypot = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_parental") {
                        self.telegram.notify_parental = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_smart_detect") {
                        self.telegram.notify_smart_detect = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_failover") {
                        self.telegram.notify_failover = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_wan") {
                        self.telegram.notify_wan = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_update_available") {
                        self.telegram.notify_update_available = parse_bool(v);
                    }
                    if let Some(v) = b.opt("notify_route_alert") {
                        self.telegram.notify_route_alert = parse_bool(v);
                    }
                    if let Some(v) = b.opt("quiet_hours_enabled") {
                        self.telegram.quiet_hours_enabled = parse_bool(v);
                    }
                    if let Some(v) = b
                        .opt("quiet_hours_start")
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                    {
                        self.telegram.quiet_hours_start = v.to_string();
                    }
                    if let Some(v) = b
                        .opt("quiet_hours_end")
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                    {
                        self.telegram.quiet_hours_end = v.to_string();
                    }
                    if let Some(v) = b.opt("webhook_secret") {
                        self.telegram.webhook_secret = v.to_string();
                    }
                    if let Some(v) = b.opt("bot_direct_fallback") {
                        self.telegram.bot_direct_fallback = parse_bool(v);
                    }
                    imported += 1;
                }
                "condition" => {
                    let user_domains = b.clean_tokens(&["user_domains", "domain", "domains"]);
                    let user_subnets =
                        b.clean_tokens(&["user_subnets", "ip_cidr", "ip_cidrs", "subnets"]);
                    let mut children = b.list("children");
                    if children.is_empty() {
                        children = b.list("condition_refs");
                    }
                    let mut time_window = b.opt("time_window").unwrap_or("").trim().to_string();
                    if time_window.is_empty()
                        && let (Some(st), Some(et)) = (b.opt("start_time"), b.opt("end_time"))
                        && !st.trim().is_empty()
                        && !et.trim().is_empty()
                    {
                        let days = b.list("days");
                        time_window = if days.is_empty() {
                            format!("{}-{}", st.trim(), et.trim())
                        } else {
                            format!("{} {}-{}", days.join(","), st.trim(), et.trim())
                        };
                    }
                    let (comm_subnets, extra_comm_lists) = b.community_subnets_and_lists();
                    let mut comm_lists = b.list("community_lists");
                    for c in extra_comm_lists {
                        if !comm_lists.contains(&c) {
                            comm_lists.push(c);
                        }
                    }
                    self.conditions.push(TrafficCondition {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        name: b.opt("name").unwrap_or(&b.name).to_string(),
                        condition_type: b
                            .opt("condition_type")
                            .or_else(|| b.opt("operator"))
                            .unwrap_or("atomic")
                            .to_string(),
                        children,
                        community_lists: comm_lists,
                        community_subnets: comm_subnets,
                        user_domains,
                        exclude_domains: b.excluded_domain_tokens(),
                        user_subnets,
                        exclude_subnets: b.clean_tokens(&["exclude_subnets"]),
                        asn_list: b.clean_tokens(&["asn_list"]),
                        remote_domain_lists: b.clean_tokens(&[
                            "rule_set",
                            "remote_domain_lists",
                            "rule_set_urls",
                        ]),
                        rule_set_with_subnets: b.clean_tokens(&["rule_set_with_subnets"]),
                        remote_subnet_lists: b
                            .clean_tokens(&["domain_ip_lists", "remote_subnet_lists"]),
                        geoip_codes: b.clean_tokens(&["geoip_country"]),
                        geoip_mode: b.opt("geoip_mode").unwrap_or("include").to_string(),
                        geosite_codes: b.clean_tokens(&["geosite_codes"]),
                        client_ips: b
                            .clean_tokens(&["client_ips", "source_ip_cidr"])
                            .into_iter()
                            .filter(|t| !is_mac_address(t))
                            .collect(),
                        exclude_client_ips: b.clean_tokens(&["excluded_ips"]),
                        ports: b.list("ports"),
                        source_ports: b.list("source_ports"),
                        exclude_ports: b.list("exclude_ports"),
                        l4_proto: b.opt("l4_proto").unwrap_or("").to_string(),
                        protocol: b.list("protocol"),
                        excluded_protocol: b.list("excluded_protocol"),
                        dscp: b.list("dscp"),
                        time_window,
                        expression: b.opt("expression").unwrap_or("").to_string(),
                        invert: b.opt("invert").is_some_and(parse_bool),
                        fully_routed_ips: b.clean_tokens(&["fully_routed_ips"]),
                        source_macs: {
                            let mut macs: Vec<String> = b
                                .clean_tokens(&["source_macs"])
                                .into_iter()
                                .filter(|t| is_mac_address(t))
                                .map(|t| t.to_ascii_lowercase())
                                .collect();
                            for t in b.clean_tokens(&["client_ips", "source_ip_cidr"]) {
                                if is_mac_address(&t) {
                                    let m = t.to_ascii_lowercase();
                                    if !macs.contains(&m) {
                                        macs.push(m);
                                    }
                                }
                            }
                            macs
                        },
                        source_inbounds: b.list("source_inbounds"),
                        ..Default::default()
                    });
                    imported += 1;
                }
                "balancer" | "urltest" | "priority_group" => {
                    let check_interval = b
                        .opt("check_interval")
                        .or_else(|| b.opt("interval"))
                        .map(parse_duration_secs)
                        .unwrap_or(180);
                    let default_btype = if b.kind == "priority_group" {
                        "priority"
                    } else {
                        "urltest"
                    };
                    let balancer_type = b.opt("balancer_type").unwrap_or(default_btype).to_string();
                    let default_mode = if balancer_type == "priority" {
                        "priority"
                    } else {
                        "least_test"
                    };
                    let bal_name = b.opt("name").unwrap_or(&b.name).to_string();
                    let sec_ref = b.opt("section").unwrap_or("");
                    let bal_id = if b.kind == "urltest"
                        && (b.name.is_empty() || b.name.starts_with("cfg"))
                    {
                        let expected = format!("bal_{sec_ref}_{bal_name}");
                        let dup_in_blocks = blocks.iter().any(|other| {
                            other.kind == "balancer"
                                && (other.name == expected
                                    || (other.opt("name").unwrap_or(&other.name) == bal_name
                                        && other.opt("balancer_type").unwrap_or("urltest")
                                            == "urltest"))
                        });
                        if dup_in_blocks
                            || self.balancers.iter().any(|existing| {
                                existing.id == expected || existing.name == bal_name
                            })
                        {
                            continue;
                        }
                        if sec_ref.is_empty() {
                            format!("bal_{}", bal_name.to_ascii_lowercase().replace(' ', "_"))
                        } else {
                            expected
                        }
                    } else {
                        b.name.clone()
                    };
                    self.balancers.push(BalancerConfig {
                        id: bal_id,
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        name: bal_name,
                        balancer_type,
                        mode: b.opt("mode").unwrap_or(default_mode).to_string(),
                        testing_url: b
                            .opt("testing_url")
                            .or_else(|| b.opt("health_url"))
                            .unwrap_or("https://www.gstatic.com/generate_204")
                            .to_string(),
                        testing_urls: b.list("testing_urls"),
                        multi_url_strategy: b
                            .opt("multi_url_strategy")
                            .or_else(|| b.opt("url_aggregation"))
                            .unwrap_or("")
                            .to_string(),
                        check_interval,
                        check_interval_jitter: b
                            .opt("check_interval_jitter")
                            .and_then(|s| s.trim().trim_end_matches('%').trim().parse().ok())
                            .unwrap_or(0),
                        urltest_active_check_interval: b
                            .opt("urltest_active_check_interval")
                            .or_else(|| {
                                if b.kind == "urltest" {
                                    b.opt("interval")
                                } else {
                                    None
                                }
                            })
                            .unwrap_or("")
                            .to_string(),
                        idle_timeout: b.opt("idle_timeout").unwrap_or("").to_string(),
                        tolerance: b
                            .opt("tolerance")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(50),
                        sticky_hash: b
                            .opt("sticky_hash")
                            .or_else(|| b.opt("sticky_hash_field"))
                            .unwrap_or("")
                            .to_string(),
                        quota_mib: b.opt("quota_mib").and_then(|s| s.parse().ok()).unwrap_or(0),
                        fallback_section: b.opt("fallback_section").unwrap_or("").to_string(),
                        balancer_pool: b.list("balancer_pool"),
                        passive_check: b.opt("passive_check").is_none_or(parse_bool),
                        interrupt_exist_connections: b
                            .opt("interrupt_exist_connections")
                            .is_some_and(parse_bool),
                        health_urls: b.list("health_urls"),
                        active_check_interval: b
                            .opt("active_check_interval")
                            .unwrap_or("15s")
                            .to_string(),
                        check_timeout: b.opt("check_timeout").unwrap_or("2s").to_string(),
                        recovery_check_interval: b
                            .opt("recovery_check_interval")
                            .unwrap_or("30s")
                            .to_string(),
                        pick_fastest: b.opt("pick_fastest").is_some_and(parse_bool),
                        switch_to_faster_same_priority: b
                            .opt("switch_to_faster_same_priority")
                            .is_some_and(parse_bool),
                        fastest_check_interval: b
                            .opt("fastest_check_interval")
                            .unwrap_or("10m")
                            .to_string(),
                        filter_mode: b.opt("filter_mode").unwrap_or("").to_string(),
                        detect_server_country: b
                            .opt("detect_server_country")
                            .is_none_or(|v| v.trim().is_empty() || parse_bool(v)),
                        pin_dashboard: b.opt("pin_dashboard").is_some_and(parse_bool),
                        exclude_proxy_parameters: b
                            .opt("exclude_proxy_parameters")
                            .is_some_and(parse_bool),
                        include_prefixes: b.list("include_prefixes"),
                        include_country_flags: b.list("include_country_flags"),
                        include_servers: b.list("include_servers"),
                        include_name_regex: b.opt("include_name_regex").unwrap_or("").to_string(),
                        include_protocols: b.list("include_protocols"),
                        include_transports: b.list("include_transports"),
                        include_security_types: b.list("include_security_types"),
                        include_ports: b.list("include_ports"),
                        exclude_prefixes: b.list("exclude_prefixes"),
                        exclude_country_flags: b.list("exclude_country_flags"),
                        exclude_servers: b.list("exclude_servers"),
                        exclude_name_regex: b.opt("exclude_name_regex").unwrap_or("").to_string(),
                        exclude_protocols: b.list("exclude_protocols"),
                        exclude_transports: b.list("exclude_transports"),
                        exclude_security_types: b.list("exclude_security_types"),
                        exclude_ports: b.list("exclude_ports"),
                        ..Default::default()
                    });
                    imported += 1;
                }
                "outbound_source" => {
                    let stype = b.opt("source_type").unwrap_or("subscription").to_string();
                    let mut urls = b.list("subscription_urls");
                    if let Some(u) = b.opt("url").map(str::trim).filter(|s| !s.is_empty())
                        && urls.len() <= 1
                    {
                        urls = vec![u.to_string()];
                    }
                    let mut proxy_links = b.list("proxy_links");
                    for opt_key in ["links", "uri", "proxy_uri"] {
                        if let Some(raw_links) = b.opt(opt_key) {
                            for line in raw_links.lines() {
                                let t = line.trim();
                                if !t.is_empty()
                                    && !t.starts_with('#')
                                    && !proxy_links.contains(&t.to_string())
                                {
                                    proxy_links.push(t.to_string());
                                }
                            }
                        }
                    }
                    let preset = b.opt("desync_preset").unwrap_or("adaptive").to_string();
                    let auto_tune = b
                        .opt("desync_auto_tune")
                        .map(parse_bool)
                        .unwrap_or_else(|| preset == "adaptive" || preset == "auto");
                    let fake_sni = b.opt("desync_fake_sni").unwrap_or("").to_string();
                    let mut sni_pool = b.csv_list("desync_sni_pool");
                    if !fake_sni.is_empty() && !sni_pool.contains(&fake_sni) {
                        sni_pool.push(fake_sni.clone());
                    }

                    let mut src = OutboundSource {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        name: b.opt("name").unwrap_or(&b.name).to_string(),
                        source_type: stype.clone(),
                        subscription_urls: urls,
                        subscription_update_enabled: b
                            .opt("subscription_update_enabled")
                            .is_none_or(parse_bool),
                        subscription_update_interval: b
                            .opt("subscription_update_interval")
                            .unwrap_or("3h")
                            .to_string(),
                        subscription_update_jitter: b
                            .opt("subscription_update_jitter")
                            .unwrap_or("")
                            .to_string(),
                        subscription_insecure: b
                            .opt("subscription_insecure")
                            .is_some_and(parse_bool),
                        proxy_links,
                        custom_json: b.opt("custom_json").unwrap_or("").to_string(),
                        interface_name: b
                            .opt("interface_name")
                            .or_else(|| b.opt("interface"))
                            .unwrap_or("")
                            .to_string(),
                        server: b
                            .opt("server")
                            .or_else(|| b.opt("server_address"))
                            .unwrap_or("")
                            .to_string(),
                        server_port: b
                            .opt("server_port")
                            .or_else(|| b.opt("port"))
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        username: b.opt("username").unwrap_or("").to_string(),
                        password: b.opt("password").unwrap_or("").to_string(),
                        psk: b.opt("psk").unwrap_or("").to_string(),
                        uuid: b.opt("uuid").unwrap_or("").to_string(),
                        method: b
                            .opt("method")
                            .or_else(|| b.opt("cipher"))
                            .unwrap_or("")
                            .to_string(),
                        flow: b.opt("flow").unwrap_or("").to_string(),
                        transport: b.opt("transport").unwrap_or("").to_string(),
                        transport_path: b.opt("transport_path").unwrap_or("").to_string(),
                        transport_host: b.opt("transport_host").unwrap_or("").to_string(),
                        reality_public_key: b.opt("reality_public_key").unwrap_or("").to_string(),
                        reality_short_id: b.opt("reality_short_id").unwrap_or("").to_string(),
                        tcp_fast_open: b.opt("tcp_fast_open").is_some_and(parse_bool),
                        multiplex_enabled: b.opt("multiplex_enabled").is_some_and(parse_bool),
                        multiplex_protocol: b
                            .opt("multiplex_protocol")
                            .unwrap_or("h2mux")
                            .to_string(),
                        multiplex_max_connections: b
                            .opt("multiplex_max_connections")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        multiplex_padding: b.opt("multiplex_padding").is_some_and(parse_bool),
                        sni: b.opt("sni").unwrap_or("").to_string(),
                        tls_sni: b
                            .opt("tls_sni")
                            .or_else(|| b.opt("tls_server_name"))
                            .unwrap_or("")
                            .to_string(),
                        insecure: b.opt("insecure").is_some_and(parse_bool),
                        tls_insecure: b.opt("tls_insecure").is_some_and(parse_bool),
                        tls_fingerprint: b
                            .opt("tls_fingerprint")
                            .or_else(|| b.opt("client_fingerprint"))
                            .unwrap_or("")
                            .to_string(),
                        tls_fragment_mode: b
                            .opt("tls_fragment_mode")
                            .or_else(|| b.opt("subscription_tls_fragment_mode"))
                            .unwrap_or("")
                            .to_string(),
                        tcp_fragment_length: b
                            .opt("tcp_fragment_length")
                            .or_else(|| b.opt("subscription_tcp_fragment_length"))
                            .unwrap_or("")
                            .to_string(),
                        tcp_fragment_delay: b
                            .opt("tcp_fragment_delay")
                            .or_else(|| b.opt("subscription_tcp_fragment_delay"))
                            .unwrap_or("")
                            .to_string(),
                        outbound_detour_enabled: b
                            .opt("outbound_detour_enabled")
                            .is_some_and(parse_bool),
                        outbound_detour_section: b
                            .opt("outbound_detour_section")
                            .or_else(|| b.opt("detour"))
                            .unwrap_or("")
                            .to_string(),
                        bind_interface: b.opt("bind_interface").unwrap_or("").to_string(),
                        amnezia_configs: b.list("amnezia_configs"),
                        amnezia_conf_text: b.opt("amnezia_conf_text").unwrap_or("").to_string(),
                        wg_endpoint: b.opt("wg_endpoint").unwrap_or("").to_string(),
                        wg_private_key: b
                            .opt("wg_private_key")
                            .or_else(|| b.opt("private_key"))
                            .unwrap_or("")
                            .to_string(),
                        wg_peer_public_key: b
                            .opt("wg_peer_public_key")
                            .or_else(|| b.opt("peer_public_key"))
                            .unwrap_or("")
                            .to_string(),
                        wg_preshared_key: b
                            .opt("wg_preshared_key")
                            .or_else(|| b.opt("preshared_key"))
                            .unwrap_or("")
                            .to_string(),
                        wg_local_address: b
                            .opt("wg_local_address")
                            .or_else(|| b.opt("local_address"))
                            .unwrap_or("")
                            .to_string(),
                        wg_mtu: b
                            .opt("wg_mtu")
                            .or_else(|| b.opt("mtu"))
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        awg_version: b.opt("awg_version").unwrap_or("").to_string(),
                        awg_keepalive: b
                            .opt("awg_keepalive")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        awg_jc: b.opt("awg_jc").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_jmin: b.opt("awg_jmin").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_jmax: b.opt("awg_jmax").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_s1: b.opt("awg_s1").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_s2: b.opt("awg_s2").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_s3: b.opt("awg_s3").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_s4: b.opt("awg_s4").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_h1: b.opt("awg_h1").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_h2: b.opt("awg_h2").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_h3: b.opt("awg_h3").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_h4: b.opt("awg_h4").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_i1: b.opt("awg_i1").unwrap_or("").to_string(),
                        awg_i2: b.opt("awg_i2").unwrap_or("").to_string(),
                        awg_i3: b.opt("awg_i3").unwrap_or("").to_string(),
                        awg_i4: b.opt("awg_i4").unwrap_or("").to_string(),
                        awg_i5: b.opt("awg_i5").unwrap_or("").to_string(),
                        awg_j1: b.opt("awg_j1").unwrap_or("").to_string(),
                        awg_j2: b.opt("awg_j2").unwrap_or("").to_string(),
                        awg_j3: b.opt("awg_j3").unwrap_or("").to_string(),
                        awg_itime: b.opt("awg_itime").and_then(|s| s.parse().ok()).unwrap_or(0),
                        server_ports: b.list("server_ports"),
                        hop_interval: b.opt("hop_interval").unwrap_or("").to_string(),
                        hop_interval_max: b.opt("hop_interval_max").unwrap_or("").to_string(),
                        warp_device_id: b.opt("warp_device_id").unwrap_or("").to_string(),
                        warp_access_token: b.opt("warp_access_token").unwrap_or("").to_string(),
                        warp_ipv4: b.opt("warp_ipv4").unwrap_or("").to_string(),
                        warp_ipv6: b.opt("warp_ipv6").unwrap_or("").to_string(),
                        warp_private_key: b.opt("warp_private_key").unwrap_or("").to_string(),
                        warp_peer_public_key: b
                            .opt("warp_peer_public_key")
                            .unwrap_or("")
                            .to_string(),
                        warp_server: b.opt("warp_server").unwrap_or("").to_string(),
                        warp_server_port: b
                            .opt("warp_server_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        warp_reserved: b.opt("warp_reserved").unwrap_or("").to_string(),
                        warp_mtu: b.opt("warp_mtu").and_then(|s| s.parse().ok()).unwrap_or(0),
                        warp_fake_packets: b.opt("warp_fake_packets").unwrap_or("").to_string(),
                        warp_fake_packets_size: b
                            .opt("warp_fake_packets_size")
                            .unwrap_or("")
                            .to_string(),
                        warp_fake_packets_delay: b
                            .opt("warp_fake_packets_delay")
                            .unwrap_or("")
                            .to_string(),
                        warp_fake_packets_mode: b
                            .opt("warp_fake_packets_mode")
                            .unwrap_or("")
                            .to_string(),
                        fptn_access_token: b
                            .opt("fptn_access_token")
                            .or_else(|| b.opt("access_token"))
                            .or_else(|| b.opt("service_token"))
                            .unwrap_or("")
                            .to_string(),
                        fptn_sni: b
                            .opt("fptn_sni")
                            .or_else(|| b.opt("sni"))
                            .unwrap_or("")
                            .to_string(),
                        fptn_bypass_method: b
                            .opt("fptn_bypass_method")
                            .or_else(|| b.opt("bypass_method"))
                            .unwrap_or("")
                            .to_string(),
                        fptn_preferred_server: b
                            .opt("fptn_preferred_server")
                            .or_else(|| b.opt("preferred_server"))
                            .unwrap_or("")
                            .to_string(),
                        openvpn_proto: b.opt("openvpn_proto").unwrap_or("").to_string(),
                        openvpn_cipher: b.opt("openvpn_cipher").unwrap_or("").to_string(),
                        openvpn_auth: b.opt("openvpn_auth").unwrap_or("").to_string(),
                        openvpn_mtu: b
                            .opt("openvpn_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        openvpn_config: b.opt("openvpn_config").unwrap_or("").to_string(),
                        anytls_alpn: b.list("anytls_alpn"),
                        anytls_idle_session_check_interval: b
                            .opt("anytls_idle_session_check_interval")
                            .unwrap_or("")
                            .to_string(),
                        anytls_idle_session_timeout: b
                            .opt("anytls_idle_session_timeout")
                            .unwrap_or("")
                            .to_string(),
                        anytls_min_idle_session: b
                            .opt("anytls_min_idle_session")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        snell_version: b
                            .opt("snell_version")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        snell_obfs: b.opt("snell_obfs").unwrap_or("").to_string(),
                        snell_obfs_host: b.opt("snell_obfs_host").unwrap_or("").to_string(),
                        snell_uot: b.opt("snell_uot").is_some_and(parse_bool),
                        mieru_transport: b.opt("mieru_transport").unwrap_or("").to_string(),
                        mieru_multiplexing: b.opt("mieru_multiplexing").unwrap_or("").to_string(),
                        mieru_handshake_mode: b
                            .opt("mieru_handshake_mode")
                            .unwrap_or("")
                            .to_string(),
                        mieru_traffic_pattern: b
                            .opt("mieru_traffic_pattern")
                            .unwrap_or("")
                            .to_string(),
                        naive_quic: b.opt("naive_quic").is_some_and(parse_bool),
                        naive_quic_congestion_control: b
                            .opt("naive_quic_congestion_control")
                            .unwrap_or("")
                            .to_string(),
                        naive_insecure_concurrency: b
                            .opt("naive_insecure_concurrency")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        naive_udp_over_tcp: b.opt("naive_udp_over_tcp").is_some_and(parse_bool),
                        naive_extra_headers: b.opt("naive_extra_headers").unwrap_or("").to_string(),
                        sudoku_aead: b.opt("sudoku_aead").unwrap_or("").to_string(),
                        sudoku_ascii: b.opt("sudoku_ascii").is_some_and(parse_bool),
                        sudoku_http_mask: b.opt("sudoku_http_mask").is_some_and(parse_bool),
                        sudoku_http_mask_host: b
                            .opt("sudoku_http_mask_host")
                            .unwrap_or("")
                            .to_string(),
                        masque_vhttp: b.opt("masque_vhttp").is_some_and(parse_bool),
                        masque_public_key: b.opt("masque_public_key").unwrap_or("").to_string(),
                        masque_local_address: b
                            .opt("masque_local_address")
                            .unwrap_or("")
                            .to_string(),
                        masque_ipv6: b.opt("masque_ipv6").unwrap_or("").to_string(),
                        masque_uri: b.opt("masque_uri").unwrap_or("").to_string(),
                        masque_mtu: b
                            .opt("masque_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        openconnect_protocol: b
                            .opt("openconnect_protocol")
                            .unwrap_or("")
                            .to_string(),
                        openconnect_authgroup: b
                            .opt("openconnect_authgroup")
                            .unwrap_or("")
                            .to_string(),
                        openconnect_servercert: b
                            .opt("openconnect_servercert")
                            .unwrap_or("")
                            .to_string(),
                        openconnect_no_dtls: b.opt("openconnect_no_dtls").is_some_and(parse_bool),
                        shadowtls_version: b
                            .opt("shadowtls_version")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        trusttunnel_quic: b.opt("trusttunnel_quic").is_some_and(parse_bool),
                        trusttunnel_health_check: b
                            .opt("trusttunnel_health_check")
                            .is_some_and(parse_bool),
                        csqtt_server: b.opt_str("csqtt_server"),
                        csqtt_server_port: b.opt_u16(&["csqtt_server_port", "csqtt_port"]),
                        csqtt_password: b.opt_str("csqtt_password"),
                        csqtt_mode: b.opt_str("csqtt_mode"),
                        csqtt_obfs: b.opt_str("csqtt_obfs"),
                        csqtt_raw_port: b.opt_u16(&["csqtt_raw_port"]),
                        csqtt_wg_port: b.opt_u16(&["csqtt_wg_port"]),
                        csqtt_local_port: b.opt_u16(&["csqtt_local_port"]),
                        csqtt_hashes: {
                            let list = b.list("csqtt_hashes");
                            parse_csqtt_hashes_tokens(list.iter().map(String::as_str))
                        },
                        csqtt_workers: b.opt_u16(&["csqtt_workers"]),
                        csqtt_turn_transport: b.opt_str("csqtt_turn_transport"),
                        csqtt_turn_server: b.opt_str("csqtt_turn_server"),
                        csqtt_turn_urls: b.list("csqtt_turn_urls"),
                        csqtt_turn_username: b.opt_str("csqtt_turn_username"),
                        csqtt_turn_password: b.opt_str("csqtt_turn_password"),
                        csqtt_vk_auth_mode: b.opt_str("csqtt_vk_auth_mode"),
                        csqtt_vk_cookie: b.opt_str("csqtt_vk_cookie"),
                        csqtt_vk_client_ids: b.list("csqtt_vk_client_ids"),
                        csqtt_mtu: b.opt_u16(&["csqtt_mtu"]),
                        csqtt_device_id: b.opt_str("csqtt_device_id"),
                        csqtt_uri: b.opt_str("csqtt_uri"),
                        csqtt_chunk1: b.opt("csqtt_chunk1").is_some_and(parse_bool),
                        csqtt_wg_private_key: b.opt_str("csqtt_wg_private_key"),
                        csqtt_wg_peer_public_key: b.opt_str("csqtt_wg_peer_public_key"),
                        csqtt_wg_address: b.opt_str("csqtt_wg_address"),
                        tewfai_transport: b.opt("tewfai_transport").unwrap_or("").to_string(),
                        tewfai_inner_cipher: b.opt("tewfai_inner_cipher").unwrap_or("").to_string(),
                        tewfai_morph_profile: b
                            .opt("tewfai_morph_profile")
                            .unwrap_or("")
                            .to_string(),
                        tewfai_desync_enabled: b
                            .opt("tewfai_desync_enabled")
                            .is_some_and(parse_bool),
                        tor_socks_port: b
                            .opt("tor_socks_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        tor_bridges: b.list("tor_bridges"),
                        mtproto_telegram_ws: b.opt("mtproto_telegram_ws").is_some_and(parse_bool),
                        tailscale_mode: b.opt("tailscale_mode").unwrap_or("").to_string(),
                        tailscale_auth_key: b.opt("tailscale_auth_key").unwrap_or("").to_string(),
                        tailscale_control_url: b
                            .opt("tailscale_control_url")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_hostname: b.opt("tailscale_hostname").unwrap_or("").to_string(),
                        tailscale_use_exit_node: b
                            .opt("tailscale_exit_node")
                            .or_else(|| b.opt("tailscale_use_exit_node"))
                            .unwrap_or("")
                            .to_string(),
                        tailscale_ephemeral: b.opt("tailscale_ephemeral").is_some_and(parse_bool),
                        tailscale_exit_node_allow_lan_access: b
                            .opt("tailscale_exit_node_allow_lan_access")
                            .is_some_and(parse_bool),
                        tailscale_accept_routes: b
                            .opt("tailscale_accept_routes")
                            .is_none_or(parse_bool),
                        tailscale_advertise_routes: b.csv_list("tailscale_advertise_routes"),
                        tailscale_advertise_exit_node: b
                            .opt("tailscale_advertise_exit_node")
                            .is_some_and(parse_bool),
                        tailscale_accept_dns: b.opt("tailscale_accept_dns").is_none_or(parse_bool),
                        tailscale_accept_default_resolvers: b
                            .opt("tailscale_accept_default_resolvers")
                            .is_none_or(parse_bool),
                        tailscale_relay_server_port: b
                            .opt("tailscale_relay_server_port")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_relay_server_static_endpoints: b
                            .csv_list("tailscale_relay_server_static_endpoints"),
                        tailscale_system_interface: b
                            .opt("tailscale_system_interface")
                            .is_some_and(parse_bool),
                        tailscale_system_interface_name: b
                            .opt("tailscale_system_interface_name")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_system_interface_mtu: b
                            .opt("tailscale_system_interface_mtu")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_udp_timeout: b
                            .opt("tailscale_udp_timeout")
                            .unwrap_or("")
                            .to_string(),
                        fail_policy: b.opt("fail_policy").unwrap_or("").to_string(),
                        filter_allow_regex: b.opt("filter_allow_regex").unwrap_or("").to_string(),
                        filter_deny_regex: b.opt("filter_deny_regex").unwrap_or("").to_string(),
                        include_countries: b.list("include_countries"),
                        exclude_countries: b.list("exclude_countries"),
                        download_via_proxy_enabled: b
                            .opt("download_via_proxy_enabled")
                            .is_some_and(parse_bool),
                        download_via_proxy_section: b
                            .opt("download_via_proxy_section")
                            .unwrap_or("")
                            .to_string(),
                        auto_user_agent: b.opt("auto_user_agent").is_none_or(parse_bool),
                        user_agent: b.opt("user_agent").unwrap_or("").to_string(),
                        auto_hwid: b.opt("auto_hwid").is_none_or(parse_bool),
                        hwid: b.opt("hwid").unwrap_or("").to_string(),
                        custom_device_headers: b
                            .opt("custom_device_headers")
                            .is_some_and(parse_bool),
                        device_os: b.opt("device_os").unwrap_or("").to_string(),
                        ver_os: b.opt("ver_os").unwrap_or("").to_string(),
                        device_model: b.opt("device_model").unwrap_or("").to_string(),
                        device_locale: b.opt("device_locale").unwrap_or("").to_string(),
                        app_version: b.opt("app_version").unwrap_or("").to_string(),
                        accept_language: b.opt("accept_language").unwrap_or("").to_string(),
                        show_dashboard_metadata: b
                            .opt("show_dashboard_metadata")
                            .is_some_and(parse_bool),
                        server_interfaces: b.list("server_interfaces"),
                        domain_resolver_enabled: b
                            .opt("domain_resolver_enabled")
                            .is_some_and(parse_bool),
                        domain_resolver_dns_type: b
                            .opt("domain_resolver_dns_type")
                            .unwrap_or("")
                            .to_string(),
                        domain_resolver_dns_server: b
                            .opt("domain_resolver_dns_server")
                            .unwrap_or("")
                            .to_string(),
                        urltest_idle_timeout: b
                            .opt("urltest_idle_timeout")
                            .unwrap_or("")
                            .to_string(),
                        prefix_nodes: b.opt("prefix_nodes").is_some_and(parse_bool),
                        node_prefix: b.opt("node_prefix").unwrap_or("").to_string(),
                        node_prefix_bg: b.opt("node_prefix_bg").unwrap_or("").to_string(),
                        node_prefix_color: b.opt("node_prefix_color").unwrap_or("").to_string(),
                        include_urltest_groups: b
                            .opt("include_urltest_groups")
                            .is_some_and(parse_bool),
                        hide_urltest_group_outbounds: b
                            .opt("hide_urltest_group_outbounds")
                            .is_some_and(parse_bool),
                        hide_detour_outbounds: b
                            .opt("hide_detour_outbounds")
                            .is_some_and(parse_bool),
                        nfqws2_opt: b.opt("nfqws2_opt").unwrap_or("").to_string(),
                        nfqws_opt: b.opt("nfqws_opt").unwrap_or("").to_string(),
                        byedpi_cmd_opts: b.opt("byedpi_cmd_opts").unwrap_or("").to_string(),
                        desync_preset: preset,
                        desync_auto_tune: auto_tune,
                        desync_fake_sni: fake_sni,
                        desync_sni_pool: sni_pool,
                        desync_split_pos: b.opt("desync_split_pos").unwrap_or("sni").to_string(),
                        desync_ttl: b
                            .opt("desync_ttl")
                            .or_else(|| b.opt("desync_fake_ttl"))
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_fooling: b.opt("desync_fooling").unwrap_or("autottl").to_string(),
                        desync_quic_fake: b
                            .opt("desync_quic_fake")
                            .or_else(|| b.opt("desync_udp_fake"))
                            .is_some_and(parse_bool),
                        desync_mode: b.opt("desync_mode").unwrap_or("").to_string(),
                        desync_repeats: b
                            .opt("desync_repeats")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_split_delay_ms: b
                            .opt("desync_split_delay_ms")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_tlsrec_first: b.opt("desync_tlsrec_first").is_some_and(parse_bool),
                        desync_seqovl: b
                            .opt("desync_seqovl")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_syndata: b.opt("desync_syndata").is_some_and(parse_bool),
                        desync_wsize: b
                            .opt("desync_wsize")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_ipfrag: b.opt("desync_ipfrag").is_some_and(parse_bool),
                        desync_udplen: b
                            .opt("desync_udplen")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_udp_repeats: b
                            .opt("desync_udp_repeats")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_udp_fake_ttl: b
                            .opt("desync_udp_fake_ttl")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_udp_fake_payload: b.opt_str("desync_udp_fake_payload"),
                        desync_udp_out_range: b.opt_str("desync_udp_out_range"),
                        desync_udp_keep_socket: b.desync_keep_socket_str(),
                        desync_host_fake: b.opt("desync_host_fake").is_some_and(parse_bool),
                        desync_wscale: b
                            .opt("desync_wscale")
                            .or_else(|| b.opt("desync_scale"))
                            .and_then(|s| s.trim().parse::<u8>().ok())
                            .map(|v| v.min(14)),
                        desync_fake_payload: b.opt("desync_fake_payload").unwrap_or("").to_string(),
                        desync_fake_tls: b.opt("desync_fake_tls").unwrap_or("").to_string(),
                        desync_opts: b.opt("desync_opts").unwrap_or("").to_string(),
                        subscription_engine: "core".to_string(),
                        hidden: b.opt("hidden").is_some_and(parse_bool),
                        last_updated_unix: 0,
                        ..Default::default()
                    };

                    if stype == "subscription" {
                        if let Some(prev) = prev_sources.get(&src.id) {
                            let mut prev_urls: Vec<&str> = prev
                                .subscription_urls
                                .iter()
                                .map(|s| s.trim())
                                .filter(|s| !s.is_empty())
                                .collect();
                            let mut cur_urls: Vec<&str> = src
                                .subscription_urls
                                .iter()
                                .map(|s| s.trim())
                                .filter(|s| !s.is_empty())
                                .collect();
                            prev_urls.sort_unstable();
                            cur_urls.sort_unstable();
                            if prev_urls == cur_urls {
                                src.cached_nodes = prev.cached_nodes.clone();
                                src.sub_title = decode_sub_header_value(&prev.sub_title);
                                src.sub_support_url = prev.sub_support_url.clone();
                                src.sub_web_page_url = prev.sub_web_page_url.clone();
                                src.sub_announce = decode_sub_header_value(&prev.sub_announce);
                                src.sub_upload_bytes = prev.sub_upload_bytes;
                                src.sub_download_bytes = prev.sub_download_bytes;
                                src.sub_total_bytes = prev.sub_total_bytes;
                                src.sub_expire_unix = prev.sub_expire_unix;
                                src.sub_last_error = prev.sub_last_error.clone();
                                src.last_updated_unix = prev.last_updated_unix;
                            }
                        }
                        if src.cached_nodes.is_empty() {
                            load_cached_subscription_nodes_from(&mut src, sub_cache_dir);
                        }
                    }
                    self.outbound_sources.push(src);
                    imported += 1;
                }
                "outbound_group" => {
                    self.outbound_groups.push(OutboundGroup {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        name: b.opt("name").unwrap_or(&b.name).to_string(),
                        primary_refs: b.list("primary_refs"),
                        backup_refs: b.list("backup_refs"),
                        fail_policy: b.opt("fail_policy").unwrap_or("last_alive").to_string(),
                        source_refs: b.list("source_refs"),
                        filter_mode: b.opt("filter_mode").unwrap_or("include").to_string(),
                        detect_server_country: b.opt("detect_server_country").is_none_or(|v| {
                            !matches!(
                                v.trim().to_ascii_lowercase().as_str(),
                                "0" | "false" | "off" | "no" | "disabled"
                            )
                        }),
                        include_prefixes: b.list("include_prefixes"),
                        include_country_flags: b.list("include_country_flags"),
                        include_servers: {
                            let mut s = b.list("include_servers");
                            for item in b.list("include_outbounds") {
                                if !s.contains(&item) {
                                    s.push(item);
                                }
                            }
                            s
                        },
                        include_name_regex: b.opt("include_name_regex").unwrap_or("").to_string(),
                        include_protocols: b.list("include_protocols"),
                        include_transports: b.list("include_transports"),
                        include_security_types: b.list("include_security_types"),
                        include_ports: b.list("include_ports"),
                        exclude_prefixes: b.list("exclude_prefixes"),
                        exclude_country_flags: b.list("exclude_country_flags"),
                        exclude_servers: {
                            let mut s = b.list("exclude_servers");
                            for item in b.list("exclude_outbounds") {
                                if !s.contains(&item) {
                                    s.push(item);
                                }
                            }
                            s
                        },
                        exclude_name_regex: b.opt("exclude_name_regex").unwrap_or("").to_string(),
                        exclude_protocols: b.list("exclude_protocols"),
                        exclude_transports: b.list("exclude_transports"),
                        exclude_security_types: b.list("exclude_security_types"),
                        exclude_ports: b.list("exclude_ports"),
                    });
                    imported += 1;
                }
                "section" => {
                    let raw_action = b.opt("action").unwrap_or("connection");
                    let out_refs = b.list("outbound_source_refs");
                    let sec_refs = b.list("section_refs");
                    let conn_type = match raw_action {
                        "block" | "reject" => "block",
                        "bypass" | "direct" => "direct",
                        "group" => "group",
                        "dns" => "dns",
                        "hosts" => "hosts",
                        "desync" => "desync",
                        "zapret2" => "zapret2",
                        "zapret" => "zapret",
                        "byedpi" => "byedpi",
                        "wdtt" => "wdtt",
                        "csqtt" => "csqtt",
                        "olcrtc" => "olcrtc",
                        "fptn" => "fptn",
                        "awg" => "awg",
                        "warp" => "warp",
                        "tailscale" => "tailscale",
                        "openvpn" => "openvpn",
                        "openconnect" => "openconnect",
                        "tewfai" => "tewfai",
                        _ => {
                            if !sec_refs.is_empty() && out_refs.is_empty() {
                                "group"
                            } else if out_refs.iter().any(|r| {
                                r.to_ascii_lowercase().contains("desync")
                                    || blocks.iter().any(|blk| {
                                        blk.kind == "outbound_source"
                                            && blk.name == *r
                                            && blk.opt("source_type") == Some("desync")
                                    })
                            }) {
                                "desync"
                            } else if b.name.eq_ignore_ascii_case("fptn") {
                                "fptn"
                            } else {
                                "proxy"
                            }
                        }
                    };
                    let user_domains = b.clean_tokens(&["user_domains", "domain", "domains"]);
                    let exclude_domains = b.excluded_domain_tokens();
                    let (sec_comm_subnets, sec_extra_comm_lists) = b.community_subnets_and_lists();
                    let mut sec_comm_lists = b.clean_tokens(&["community_lists"]);
                    for c in sec_extra_comm_lists {
                        if !sec_comm_lists.contains(&c) {
                            sec_comm_lists.push(c);
                        }
                    }
                    let user_subnets =
                        b.clean_tokens(&["user_subnets", "ip_cidr", "ip_cidrs", "subnets"]);
                    let exclude_subnets = b.clean_tokens(&["exclude_subnets", "excluded_ip_cidr"]);
                    let active_sel = selector_state
                        .get(&b.name)
                        .or_else(|| selector_state.get(&format!("{}-out", b.name)))
                        .cloned()
                        .unwrap_or_default();

                    self.sections.push(RoutingSection {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        label: b.opt("label").unwrap_or(&b.name).to_string(),
                        icon: b.opt("icon").unwrap_or("").to_string(),
                        icon_domain: b.opt("icon_domain").unwrap_or("").to_string(),
                        description: b.opt("description").unwrap_or("").to_string(),
                        prefix_text: b.opt("prefix_text").unwrap_or("").to_string(),
                        prefix_bg: b.opt("prefix_bg").unwrap_or("").to_string(),
                        prefix_color: b.opt("prefix_color").unwrap_or("").to_string(),
                        dashboard_filter_mode: b
                            .opt("dashboard_filter_mode")
                            .unwrap_or("")
                            .to_string(),
                        connection_type: conn_type.to_string(),
                        action: raw_action.to_string(),
                        condition_refs: b.list("condition_refs"),
                        condition_operator: b
                            .opt("condition_operator")
                            .unwrap_or("and")
                            .to_string(),
                        condition_expression: b
                            .opt("condition_expression")
                            .unwrap_or("")
                            .to_string(),
                        match_all: b.opt("match_all").is_some_and(parse_bool),
                        outbound_source_refs: out_refs,
                        section_refs: sec_refs,
                        balancer_refs: b.list("balancer_refs"),
                        outbound_group_ref: b.opt("outbound_group_ref").unwrap_or("").to_string(),
                        outbound_group_refs: b.list("outbound_group_refs"),
                        outbound_group_levels: b.list("outbound_group_levels"),
                        section_selection_mode: b
                            .opt("section_selection_mode")
                            .unwrap_or("auto")
                            .to_string(),
                        selector_auto_failover: b
                            .opt("selector_auto_failover")
                            .is_some_and(parse_bool),
                        section_health_url: b.opt("section_health_url").unwrap_or("").to_string(),
                        interfaces: b.list("interfaces"),
                        output_interface: b.opt("output_interface").unwrap_or("").to_string(),
                        server_domain_rules: b.list("server_domain_rules"),
                        section_filter_mode: b
                            .opt("section_filter_mode")
                            .unwrap_or("disabled")
                            .to_string(),
                        include_countries: b.list("include_countries"),
                        exclude_countries: b.list("exclude_countries"),
                        include_prefixes: b.list("include_prefixes"),
                        exclude_prefixes: b.list("exclude_prefixes"),
                        node_filter_allow: b.opt("node_filter_allow").unwrap_or("").to_string(),
                        node_filter_deny: b.opt("node_filter_deny").unwrap_or("").to_string(),
                        include_protocols: b.list("include_protocols"),
                        exclude_protocols: b.list("exclude_protocols"),
                        include_transports: b.list("include_transports"),
                        exclude_transports: b.list("exclude_transports"),
                        include_securities: b.list("include_securities"),
                        exclude_securities: b.list("exclude_securities"),
                        dashboard_hide_na_servers: b
                            .opt("dashboard_hide_na_servers")
                            .is_some_and(parse_bool),
                        hidden: b.opt("hidden").is_some_and(parse_bool),
                        subscription_url_settings: b.list("subscription_url_settings"),
                        community_lists: sec_comm_lists,
                        community_subnets: sec_comm_subnets,
                        rule_set_urls: b.clean_tokens(&["rule_set"]),
                        rule_set_with_subnets: b.clean_tokens(&["rule_set_with_subnets"]),
                        domain_ip_lists: b.clean_tokens(&["domain_ip_lists"]),
                        user_domains,
                        exclude_domains,
                        user_subnets,
                        exclude_subnets,
                        asn_list: b.clean_tokens(&["asn_list"]),
                        geoip_codes: {
                            let l = b.clean_tokens(&["geoip_country"]);
                            if l.is_empty() {
                                b.clean_tokens(&["geoip_codes"])
                            } else {
                                l
                            }
                        },
                        geoip_mode: b.opt("geoip_mode").unwrap_or("exclude").to_string(),
                        geosite_codes: {
                            let l = b.clean_tokens(&["geosite_codes"]);
                            if l.is_empty() {
                                b.clean_tokens(&["geosite"])
                            } else {
                                l
                            }
                        },
                        global_rules: b.list("global_rules"),
                        source_ip_cidr: b
                            .clean_tokens(&["source_ip_cidr"])
                            .into_iter()
                            .filter(|t| !is_mac_address(t))
                            .collect(),
                        fully_routed_ips: {
                            let l = b.clean_tokens(&["fully_routed_ips"]);
                            if l.is_empty() {
                                b.clean_tokens(&["client_ips"])
                            } else {
                                l
                            }
                        },
                        excluded_ips: b.clean_tokens(&["excluded_ips"]),
                        source_inbounds: b.list("source_inbounds"),
                        default_interface_address: b.list("default_interface_address"),
                        interface_address: b.list("interface_address"),
                        ports: b.list("ports"),
                        source_ports: b.list("source_ports"),
                        exclude_ports: {
                            let l = b.list("exclude_ports");
                            if l.is_empty() {
                                b.list("excluded_ports")
                            } else {
                                l
                            }
                        },
                        protocol: b.list("protocol"),
                        excluded_protocol: b.list("excluded_protocol"),
                        dscp: b.list("dscp"),
                        outbound_detour_enabled: b
                            .opt("outbound_detour_enabled")
                            .is_some_and(parse_bool),
                        outbound_detour_section: b
                            .opt("outbound_detour_section")
                            .unwrap_or("")
                            .to_string(),
                        sort_by_latency: b.opt("sort_by_latency").is_some_and(parse_bool),
                        packet_encoding: b.opt("packet_encoding").unwrap_or("").to_string(),
                        resolve_real_ip_for_routing: b
                            .opt("resolve_real_ip_for_routing")
                            .is_some_and(parse_bool),
                        fail_policy: b.opt("fail_policy").unwrap_or("keep").to_string(),
                        fail_policy_urls: b.list("fail_policy_urls"),
                        fail_policy_timeout: b
                            .opt("fail_policy_timeout")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(3000),
                        fail_policy_threshold: b
                            .opt("fail_policy_threshold")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(3),
                        fail_policy_recover_threshold: b
                            .opt("fail_policy_recover_threshold")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(2),
                        fail_policy_cooldown: b
                            .opt("fail_policy_cooldown")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(60),
                        fail_policy_check_direct: b
                            .opt("fail_policy_check_direct")
                            .is_none_or(parse_bool),
                        fail_policy_check_interval: b
                            .opt("fail_policy_check_interval")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        fail_policy_recover_interval: b
                            .opt("fail_policy_recover_interval")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        fail_policy_expected_status: b
                            .opt("fail_policy_expected_status")
                            .unwrap_or("")
                            .to_string(),
                        mixed_proxy_enabled: b.opt("mixed_proxy_enabled").is_some_and(parse_bool),
                        mixed_proxy_port: b
                            .opt("mixed_proxy_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        mixed_proxy_auth_enabled: b
                            .opt("mixed_proxy_auth_enabled")
                            .is_some_and(parse_bool),
                        mixed_proxy_username: b
                            .opt("mixed_proxy_username")
                            .unwrap_or("")
                            .to_string(),
                        mixed_proxy_password: b
                            .opt("mixed_proxy_password")
                            .unwrap_or("")
                            .to_string(),
                        routed_dns_enabled: b.opt("routed_dns_enabled").is_some_and(parse_bool),
                        routed_dns_type: b.opt("routed_dns_type").unwrap_or("doh").to_string(),
                        dns_servers: {
                            let l = b.list("dns_server");
                            if l.is_empty() {
                                b.list("dns_servers")
                            } else {
                                l
                            }
                        },
                        dns_use_wan: b.opt("dns_use_wan").is_some_and(parse_bool),
                        disable_fakeip: b.opt("disable_fakeip").is_some_and(parse_bool),
                        dns_detour_enabled: b.opt("dns_detour_enabled").is_some_and(parse_bool),
                        dns_detour_section: b.opt("dns_detour_section").unwrap_or("").to_string(),
                        active_selected_tag: active_sel,
                        desync_preset: b.opt("desync_preset").unwrap_or("").to_string(),
                        desync_mode: b.opt("desync_mode").unwrap_or("").to_string(),
                        desync_fooling: b.opt("desync_fooling").unwrap_or("").to_string(),
                        desync_auto_tune: b.opt("desync_auto_tune").is_none_or(parse_bool),
                        desync_split_pos: b.opt("desync_split_pos").unwrap_or("").to_string(),
                        desync_fake_ttl: b
                            .opt("desync_fake_ttl")
                            .or_else(|| b.opt("desync_ttl"))
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_fake_sni: b.opt("desync_fake_sni").unwrap_or("").to_string(),
                        desync_repeats: b
                            .opt("desync_repeats")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_split_delay_ms: b
                            .opt("desync_split_delay_ms")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_tlsrec_first: b.opt("desync_tlsrec_first").is_some_and(parse_bool),
                        desync_seqovl: b
                            .opt("desync_seqovl")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_syndata: b.opt("desync_syndata").is_some_and(parse_bool),
                        desync_wsize: b
                            .opt("desync_wsize")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_ipfrag: b.opt("desync_ipfrag").is_some_and(parse_bool),
                        desync_udp_fake: b
                            .opt("desync_udp_fake")
                            .or_else(|| b.opt("desync_quic_fake"))
                            .is_none_or(parse_bool),
                        desync_udp_repeats: b
                            .opt("desync_udp_repeats")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_udp_fake_ttl: b
                            .opt("desync_udp_fake_ttl")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_udp_fake_payload: b.opt_str("desync_udp_fake_payload"),
                        desync_udp_out_range: b.opt_str("desync_udp_out_range"),
                        desync_udp_keep_socket: b.desync_keep_socket_str(),
                        desync_udplen: b
                            .opt("desync_udplen")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        desync_host_fake: b.opt("desync_host_fake").is_some_and(parse_bool),
                        desync_wscale: b
                            .opt("desync_wscale")
                            .or_else(|| b.opt("desync_scale"))
                            .and_then(|s| s.trim().parse::<u8>().ok())
                            .map(|v| v.min(14)),
                        desync_sni_pool: b.csv_list("desync_sni_pool"),
                        desync_fake_payload: b.opt("desync_fake_payload").unwrap_or("").to_string(),
                        desync_fake_tls: b.opt("desync_fake_tls").unwrap_or("").to_string(),
                        desync_opts: b.opt("desync_opts").unwrap_or("").to_string(),
                        nfqws2_opt: b.opt("nfqws2_opt").unwrap_or("").to_string(),
                        nfqws_opt: b.opt("nfqws_opt").unwrap_or("").to_string(),
                        byedpi_cmd_opts: b.opt("byedpi_cmd_opts").unwrap_or("").to_string(),
                        warp_flow_uri: b.opt("warp_flow_uri").unwrap_or("").to_string(),
                        warp_flow_mode: b.opt("warp_flow_mode").unwrap_or("").to_string(),
                        warp_flow_workers: b.opt("warp_flow_workers").unwrap_or("").to_string(),
                        warp_flow_mtu: b.opt("warp_flow_mtu").unwrap_or("").to_string(),
                        warp_flow_subscription_links: b.list("warp_flow_subscription_links"),
                        olcrtc_provider: b.opt("olcrtc_provider").unwrap_or("jitsi").to_string(),
                        olcrtc_transport: b.opt("olcrtc_transport").unwrap_or("whep").to_string(),
                        olcrtc_room_id: b.opt("olcrtc_room_id").unwrap_or("").to_string(),
                        olcrtc_crypto_key: b.opt("olcrtc_crypto_key").unwrap_or("").to_string(),
                        olcrtc_socks_port: b.opt("olcrtc_socks_port").unwrap_or("1082").to_string(),
                        olcrtc_subscription_links: b.list("olcrtc_subscription_links"),
                        fptn_access_token: b.opt("access_token").unwrap_or("").to_string(),
                        fptn_sni: b.opt("sni").unwrap_or("").to_string(),
                        fptn_bypass_method: b.opt("bypass_method").unwrap_or("").to_string(),
                        fptn_preferred_server: b.opt("preferred_server").unwrap_or("").to_string(),
                        warp_flow_device_id: b.opt_str("warp_flow_device_id"),
                        wdtt_native: b.opt("wdtt_native").is_some_and(parse_bool),
                        wdtt_workers: b.opt_u16(&["wdtt_workers"]),
                        wdtt_mtu: b.opt_u16(&["wdtt_mtu"]),
                        csqtt_server: b.opt_str("csqtt_server"),
                        csqtt_server_port: b.opt_u16(&["csqtt_server_port", "csqtt_port"]),
                        csqtt_password: b.opt_str("csqtt_password"),
                        csqtt_mode: b.opt_str("csqtt_mode"),
                        csqtt_obfs: b.opt_str("csqtt_obfs"),
                        csqtt_raw_port: b.opt_u16(&["csqtt_raw_port"]),
                        csqtt_wg_port: b.opt_u16(&["csqtt_wg_port"]),
                        csqtt_local_port: b.opt_u16(&["csqtt_local_port"]),
                        csqtt_hashes: {
                            let list = b.list("csqtt_hashes");
                            parse_csqtt_hashes_tokens(list.iter().map(String::as_str))
                        },
                        csqtt_workers: b.opt_u16(&["csqtt_workers"]),
                        csqtt_turn_transport: b.opt_str("csqtt_turn_transport"),
                        csqtt_turn_server: b.opt_str("csqtt_turn_server"),
                        csqtt_turn_urls: b.list("csqtt_turn_urls"),
                        csqtt_turn_username: b.opt_str("csqtt_turn_username"),
                        csqtt_turn_password: b.opt_str("csqtt_turn_password"),
                        csqtt_vk_auth_mode: b.opt_str("csqtt_vk_auth_mode"),
                        csqtt_vk_cookie: b.opt_str("csqtt_vk_cookie"),
                        csqtt_vk_client_ids: b.list("csqtt_vk_client_ids"),
                        csqtt_mtu: b.opt_u16(&["csqtt_mtu"]),
                        csqtt_device_id: b.opt_str("csqtt_device_id"),
                        csqtt_uri: b.opt_str("csqtt_uri"),
                        csqtt_chunk1: b.opt("csqtt_chunk1").is_some_and(parse_bool),
                        csqtt_wg_private_key: b.opt_str("csqtt_wg_private_key"),
                        csqtt_wg_peer_public_key: b.opt_str("csqtt_wg_peer_public_key"),
                        csqtt_wg_address: b.opt_str("csqtt_wg_address"),
                        dns_hosts: b.opt("dns_hosts").unwrap_or("").to_string(),
                        hosts_list_urls: b.list("hosts_list_urls"),
                        hosts_list_auto_update: b
                            .opt("hosts_list_auto_update")
                            .is_some_and(parse_bool),
                        hosts_list_update_interval: b
                            .opt("hosts_list_update_interval")
                            .unwrap_or("24h")
                            .to_string(),
                        bind_interface: b.opt("bind_interface").unwrap_or("").to_string(),
                        tailscale_mode: b.opt("tailscale_mode").unwrap_or("").to_string(),
                        tailscale_auth_key: b.opt("tailscale_auth_key").unwrap_or("").to_string(),
                        tailscale_control_url: b
                            .opt("tailscale_control_url")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_hostname: b.opt("tailscale_hostname").unwrap_or("").to_string(),
                        tailscale_use_exit_node: b
                            .opt("tailscale_exit_node")
                            .or_else(|| b.opt("tailscale_use_exit_node"))
                            .unwrap_or("")
                            .to_string(),
                        tailscale_ephemeral: b.opt("tailscale_ephemeral").is_some_and(parse_bool),
                        tailscale_exit_node_allow_lan_access: b
                            .opt("tailscale_exit_node_allow_lan_access")
                            .is_some_and(parse_bool),
                        tailscale_accept_routes: b
                            .opt("tailscale_accept_routes")
                            .is_none_or(parse_bool),
                        tailscale_advertise_routes: b.csv_list("tailscale_advertise_routes"),
                        tailscale_advertise_exit_node: b
                            .opt("tailscale_advertise_exit_node")
                            .is_some_and(parse_bool),
                        tailscale_accept_dns: b.opt("tailscale_accept_dns").is_none_or(parse_bool),
                        tailscale_accept_default_resolvers: b
                            .opt("tailscale_accept_default_resolvers")
                            .is_none_or(parse_bool),
                        tailscale_relay_server_port: b
                            .opt("tailscale_relay_server_port")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_relay_server_static_endpoints: b
                            .csv_list("tailscale_relay_server_static_endpoints"),
                        tailscale_system_interface: b
                            .opt("tailscale_system_interface")
                            .is_some_and(parse_bool),
                        tailscale_system_interface_name: b
                            .opt("tailscale_system_interface_name")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_system_interface_mtu: b
                            .opt("tailscale_system_interface_mtu")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_udp_timeout: b
                            .opt("tailscale_udp_timeout")
                            .unwrap_or("")
                            .to_string(),
                        ipv6_support: b.opt("ipv6_support").unwrap_or("").trim().to_string(),
                        ..Default::default()
                    });
                    imported += 1;
                }
                "server" => {
                    let proto = b.opt("protocol").unwrap_or("vless").to_string();
                    let default_port_str = if proto == "wdtt" {
                        "46000"
                    } else if proto == "tailscale" {
                        "0"
                    } else {
                        "443"
                    };
                    let default_port_num: u16 = if proto == "wdtt" {
                        46000
                    } else if proto == "tailscale" {
                        0
                    } else {
                        443
                    };
                    let raw_port = b.opt("listen_port").unwrap_or(default_port_str);
                    let listen_port = raw_port
                        .split('-')
                        .next()
                        .and_then(|s| s.parse::<u16>().ok())
                        .unwrap_or(default_port_num);
                    let listen_port_range = b
                        .opt("listen_port_range")
                        .map(String::from)
                        .unwrap_or_else(|| {
                            if raw_port.contains('-') {
                                raw_port.to_string()
                            } else {
                                String::new()
                            }
                        });
                    let label = b.opt("label").unwrap_or(&b.name).to_string();
                    let srv_uuid = b
                        .opt("server_uuid")
                        .or_else(|| b.opt("tewfai_uuid"))
                        .unwrap_or("")
                        .to_string();
                    let srv_pw = b
                        .opt("server_password")
                        .or_else(|| b.opt("password"))
                        .or_else(|| b.opt("tewfai_password"))
                        .unwrap_or("")
                        .to_string();
                    let flow = b.opt("vless_flow").unwrap_or("none").to_string();

                    let parsed_clients: Vec<InboundClient> = b
                        .opt("clients_json")
                        .and_then(|raw_c| serde_json::from_str::<Vec<InboundClient>>(raw_c).ok())
                        .filter(|v| !v.is_empty())
                        .unwrap_or_else(|| {
                            vec![InboundClient {
                                id: format!("cli-{}", b.name),
                                name: b.opt("server_username").unwrap_or(&label).to_string(),
                                enabled: true,
                                uuid: if srv_uuid.is_empty() {
                                    crypto_gen::generate_uuid_v4()
                                } else {
                                    srv_uuid.clone()
                                },
                                password: srv_pw.clone(),
                                flow: if flow == "none" {
                                    String::new()
                                } else {
                                    flow.clone()
                                },
                                sub_id: "default".to_string(),
                                up: 0,
                                down: 0,
                                total_limit_bytes: b
                                    .opt("client_limit_bytes")
                                    .and_then(|s| s.parse().ok())
                                    .unwrap_or(0),
                                expiry_time: b
                                    .opt("client_expiry_time")
                                    .and_then(|s| s.parse().ok())
                                    .unwrap_or(0),
                                ip_limit: b
                                    .opt("client_ip_limit")
                                    .and_then(|s| s.parse().ok())
                                    .unwrap_or(0),
                                wg_public_key: b
                                    .opt("awg_peer_public_key")
                                    .unwrap_or("")
                                    .to_string(),
                                wg_private_key: b
                                    .opt("awg_client_private_key")
                                    .unwrap_or("")
                                    .to_string(),
                                wg_client_ip: b
                                    .opt("awg_client_address")
                                    .unwrap_or("10.8.0.2/32")
                                    .to_string(),
                            }]
                        });

                    let is_tailscale_proto = proto.eq_ignore_ascii_case("tailscale");
                    self.servers.push(InboundServer {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        label,
                        country: b.opt("server_country").unwrap_or("RU").to_string(),
                        protocol: proto,
                        listen: b.opt("listen").unwrap_or("0.0.0.0").to_string(),
                        listen_port,
                        listen_port_range,
                        public_host: b.opt("public_host").unwrap_or("").to_string(),
                        open_firewall_port: if is_tailscale_proto {
                            b.opt("open_firewall_port").is_some_and(parse_bool)
                        } else {
                            b.opt("open_firewall_port").is_none_or(parse_bool)
                        },
                        routing_mode: b.opt("routing_mode").unwrap_or("rules").to_string(),
                        routing_section: b.opt("routing_section").unwrap_or("").to_string(),
                        security: b.opt("security").unwrap_or("none").to_string(),
                        server_uuid: srv_uuid,
                        server_username: b.opt("server_username").unwrap_or("").to_string(),
                        password: srv_pw,
                        method: b
                            .opt("shadowsocks_method")
                            .or_else(|| b.opt("method"))
                            .unwrap_or("aes-128-gcm")
                            .to_string(),
                        vmess_alter_id: b
                            .opt("vmess_alter_id")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        socks_auth_enabled: b.opt("socks_auth_enabled").is_some_and(parse_bool),
                        vless_flow: flow,
                        tls_server_name: b.opt("tls_server_name").unwrap_or("").to_string(),
                        tls_certificate_path: b
                            .opt("tls_certificate_path")
                            .unwrap_or("")
                            .to_string(),
                        tls_key_path: b.opt("tls_key_path").unwrap_or("").to_string(),
                        tls_alpn: b.list("tls_alpn"),
                        client_fingerprint: b
                            .opt("client_fingerprint")
                            .unwrap_or("chrome")
                            .to_string(),
                        reality_handshake_server: b
                            .opt("reality_handshake_server")
                            .unwrap_or("www.microsoft.com")
                            .to_string(),
                        reality_handshake_server_port: b
                            .opt("reality_handshake_server_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(443),
                        reality_private_key: b.opt("reality_private_key").unwrap_or("").to_string(),
                        reality_public_key: b.opt("reality_public_key").unwrap_or("").to_string(),
                        reality_short_id: b.opt("reality_short_id").unwrap_or("").to_string(),
                        reality_max_time_difference: b
                            .opt("reality_max_time_difference")
                            .unwrap_or("")
                            .to_string(),
                        transport: b.opt("transport").unwrap_or("tcp").to_string(),
                        transport_path: b.opt("transport_path").unwrap_or("").to_string(),
                        transport_host: b.opt("transport_host").unwrap_or("").to_string(),
                        transport_xhttp_mode: b
                            .opt("transport_xhttp_mode")
                            .unwrap_or("")
                            .to_string(),
                        transport_hosts: b.list("transport_hosts"),
                        transport_service_name: b
                            .opt("transport_service_name")
                            .unwrap_or("")
                            .to_string(),
                        anytls_padding_scheme: b
                            .opt("anytls_padding_scheme")
                            .unwrap_or("")
                            .to_string(),
                        tewfai_uuid: b.opt("tewfai_uuid").unwrap_or("").to_string(),
                        tewfai_password: b.opt("tewfai_password").unwrap_or("").to_string(),
                        tewfai_inbound_transport: b
                            .opt("tewfai_inbound_transport")
                            .unwrap_or("quic")
                            .to_string(),
                        tewfai_inner_cipher: b
                            .opt("tewfai_inner_cipher")
                            .unwrap_or("aes-256-gcm")
                            .to_string(),
                        tewfai_shaper_profile: b
                            .opt("tewfai_shaper_profile")
                            .unwrap_or("adaptive")
                            .to_string(),
                        tewfai_morph_profile: b
                            .opt("tewfai_morph_profile")
                            .unwrap_or("auto")
                            .to_string(),
                        tewfai_pqc_enabled: b.opt("tewfai_pqc_enabled").is_some_and(parse_bool),
                        tewfai_handover_enabled: b
                            .opt("tewfai_handover_enabled")
                            .is_some_and(parse_bool),
                        tewfai_fec_enabled: b.opt("tewfai_fec_enabled").is_some_and(parse_bool),
                        tewfai_shaper_enabled: b
                            .opt("tewfai_shaper_enabled")
                            .is_some_and(parse_bool),
                        tewfai_mtu: b
                            .opt("tewfai_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        hysteria2_obfs_type: b.opt("hysteria2_obfs_type").unwrap_or("").to_string(),
                        hysteria2_obfs_password: b
                            .opt("hysteria2_obfs_password")
                            .unwrap_or("")
                            .to_string(),
                        hysteria2_up_mbps: b
                            .opt("hysteria2_up_mbps")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(100),
                        hysteria2_down_mbps: b
                            .opt("hysteria2_down_mbps")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(100),
                        tuic_congestion_control: b
                            .opt("tuic_congestion_control")
                            .unwrap_or("bbr")
                            .to_string(),
                        shadowtls_handshake_server: b
                            .opt("shadowtls_handshake_server")
                            .unwrap_or("www.microsoft.com")
                            .to_string(),
                        shadowtls_handshake_server_port: b
                            .opt("shadowtls_handshake_server_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(443),
                        shadowtls_version: b
                            .opt("shadowtls_version")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(3),
                        mieru_transport: b.opt("mieru_transport").unwrap_or("TCP").to_string(),
                        trusttunnel_quic: b.opt("trusttunnel_quic").is_some_and(parse_bool),
                        masque_ipv4_pool: b
                            .opt("masque_ipv4_pool")
                            .unwrap_or("172.16.0.0/24")
                            .to_string(),
                        masque_ipv6_pool: b.opt("masque_ipv6_pool").unwrap_or("").to_string(),
                        masque_mtu: b
                            .opt("masque_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1400),
                        openconnect_cookie: b.opt("openconnect_cookie").unwrap_or("").to_string(),
                        openconnect_flavor: b
                            .opt("openconnect_flavor")
                            .unwrap_or("anyconnect")
                            .to_string(),
                        openconnect_user_agent: b
                            .opt("openconnect_user_agent")
                            .unwrap_or("")
                            .to_string(),
                        openconnect_local_hostname: b
                            .opt("openconnect_local_hostname")
                            .unwrap_or("")
                            .to_string(),
                        openconnect_urlpath: b.opt("openconnect_urlpath").unwrap_or("").to_string(),
                        openconnect_address: b
                            .opt("openconnect_address")
                            .unwrap_or("172.16.1.2/24")
                            .to_string(),
                        openconnect_mtu: b
                            .opt("openconnect_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1400),
                        openconnect_ip: b.opt("openconnect_ip").is_some_and(parse_bool),
                        openconnect_esp: b.opt("openconnect_esp").is_some_and(parse_bool),
                        openconnect_dtls: b.opt("openconnect_dtls").is_some_and(parse_bool),
                        mtproto_secret: b.opt("mtproto_secret").unwrap_or("").to_string(),
                        mtproto_adtag: b
                            .opt("mtproto_adtag")
                            .or_else(|| b.opt("adtag"))
                            .unwrap_or("")
                            .to_string(),
                        mtproto_faketls: b
                            .opt("mtproto_faketls")
                            .unwrap_or("google.com")
                            .to_string(),
                        mtproto_telegram_ws: b.opt("mtproto_telegram_ws").is_some_and(parse_bool),
                        mtproto_padding: b.opt("mtproto_padding").is_some_and(parse_bool),
                        mtproto_concurrency: b
                            .opt("mtproto_concurrency")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        mtproto_domain_fronting_port: b
                            .opt("mtproto_domain_fronting_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        mtproto_domain_fronting_ip: b
                            .opt("mtproto_domain_fronting_ip")
                            .unwrap_or("")
                            .to_string(),
                        mtproto_domain_fronting_proxy_protocol: b
                            .opt("mtproto_domain_fronting_proxy_protocol")
                            .is_some_and(parse_bool),
                        mtproto_prefer_ip: b.opt("mtproto_prefer_ip").unwrap_or("").to_string(),
                        mtproto_auto_update: b.opt("mtproto_auto_update").is_some_and(parse_bool),
                        mtproto_allow_fallback_on_unknown_dc: b
                            .opt("mtproto_allow_fallback_on_unknown_dc")
                            .is_some_and(parse_bool),
                        mtproto_tolerate_time_skewness: b
                            .opt("mtproto_tolerate_time_skewness")
                            .is_some_and(parse_bool),
                        mtproto_idle_timeout: b
                            .opt("mtproto_idle_timeout")
                            .unwrap_or("")
                            .to_string(),
                        mtproto_handshake_timeout: b
                            .opt("mtproto_handshake_timeout")
                            .unwrap_or("")
                            .to_string(),
                        awg_version: b.opt("awg_version").unwrap_or("1.5").to_string(),
                        awg_mtu: b
                            .opt("awg_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1280),
                        awg_local_address: b
                            .opt("awg_local_address")
                            .unwrap_or("10.8.0.1/24")
                            .to_string(),
                        awg_client_address: b
                            .opt("awg_client_address")
                            .unwrap_or("10.8.0.2/32")
                            .to_string(),
                        awg_dns: b.opt("awg_dns").unwrap_or("1.1.1.1").to_string(),
                        awg_jc: b.opt("awg_jc").and_then(|s| s.parse().ok()).unwrap_or(5),
                        awg_jmin: b.opt("awg_jmin").and_then(|s| s.parse().ok()).unwrap_or(40),
                        awg_jmax: b.opt("awg_jmax").and_then(|s| s.parse().ok()).unwrap_or(70),
                        awg_s1: b.opt("awg_s1").and_then(|s| s.parse().ok()).unwrap_or(17),
                        awg_s2: b.opt("awg_s2").and_then(|s| s.parse().ok()).unwrap_or(26),
                        awg_s3: b.opt("awg_s3").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_s4: b.opt("awg_s4").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_h1: b
                            .opt("awg_h1")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(448892597),
                        awg_h2: b
                            .opt("awg_h2")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(523644185),
                        awg_h3: b
                            .opt("awg_h3")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1107499361),
                        awg_h4: b
                            .opt("awg_h4")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1965444834),
                        awg_i1: b.opt("awg_i1").unwrap_or("").to_string(),
                        awg_i2: b.opt("awg_i2").unwrap_or("").to_string(),
                        awg_i3: b.opt("awg_i3").unwrap_or("").to_string(),
                        awg_i4: b.opt("awg_i4").unwrap_or("").to_string(),
                        awg_i5: b.opt("awg_i5").unwrap_or("").to_string(),
                        awg_j1: b.opt("awg_j1").unwrap_or("").to_string(),
                        awg_j2: b.opt("awg_j2").unwrap_or("").to_string(),
                        awg_j3: b.opt("awg_j3").unwrap_or("").to_string(),
                        awg_itime: b.opt("awg_itime").and_then(|s| s.parse().ok()).unwrap_or(0),
                        awg_keepalive: b
                            .opt("awg_keepalive")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(25),
                        awg_private_key: b.opt("awg_private_key").unwrap_or("").to_string(),
                        awg_server_public_key: b
                            .opt("awg_server_public_key")
                            .unwrap_or("")
                            .to_string(),
                        awg_client_private_key: b
                            .opt("awg_client_private_key")
                            .unwrap_or("")
                            .to_string(),
                        awg_peer_public_key: b.opt("awg_peer_public_key").unwrap_or("").to_string(),
                        awg_preshared_key: b.opt("awg_preshared_key").unwrap_or("").to_string(),
                        tailscale_auth_key: b.opt("tailscale_auth_key").unwrap_or("").to_string(),
                        tailscale_control_url: b
                            .opt("tailscale_control_url")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_hostname: b.opt("tailscale_hostname").unwrap_or("").to_string(),
                        tailscale_advertise_exit_node: b
                            .opt("tailscale_advertise_exit_node")
                            .is_some_and(parse_bool),
                        tailscale_advertise_routes: b.csv_list("tailscale_advertise_routes"),
                        tailscale_accept_routes: b
                            .opt("tailscale_accept_routes")
                            .is_some_and(parse_bool),
                        tailscale_mode: b.opt("tailscale_mode").unwrap_or("").to_string(),
                        tailscale_auto_firewall: b
                            .opt("tailscale_auto_firewall")
                            .is_some_and(parse_bool),
                        tailscale_masquerade: b.opt("tailscale_masquerade").is_some_and(parse_bool),
                        tailscale_use_exit_node: b
                            .opt("tailscale_use_exit_node")
                            .or_else(|| b.opt("tailscale_exit_node"))
                            .unwrap_or("")
                            .to_string(),
                        tailscale_ephemeral: b.opt("tailscale_ephemeral").is_some_and(parse_bool),
                        tailscale_exit_node_allow_lan_access: b
                            .opt("tailscale_exit_node_allow_lan_access")
                            .is_some_and(parse_bool),
                        tailscale_accept_dns: b.opt("tailscale_accept_dns").is_none_or(parse_bool),
                        tailscale_accept_default_resolvers: b
                            .opt("tailscale_accept_default_resolvers")
                            .is_none_or(parse_bool),
                        tailscale_relay_server_port: b
                            .opt("tailscale_relay_server_port")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_relay_server_static_endpoints: b
                            .csv_list("tailscale_relay_server_static_endpoints"),
                        tailscale_system_interface: b
                            .opt("tailscale_system_interface")
                            .is_some_and(parse_bool),
                        tailscale_system_interface_name: b
                            .opt("tailscale_system_interface_name")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_system_interface_mtu: b
                            .opt("tailscale_system_interface_mtu")
                            .unwrap_or("")
                            .to_string(),
                        tailscale_udp_timeout: b
                            .opt("tailscale_udp_timeout")
                            .unwrap_or("")
                            .to_string(),
                        isolate_lan_for_users: b
                            .opt("isolate_lan_for_users")
                            .is_some_and(parse_bool),
                        isolated_users: b.list("isolated_users"),
                        isolated_subnets: b.list("isolated_subnets"),
                        wdtt_mode: b.opt("wdtt_mode").unwrap_or("").to_string(),
                        wdtt_obfs: b.opt("wdtt_obfs").unwrap_or("").to_string(),
                        wdtt_raw_port: b
                            .opt("wdtt_raw_port")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        wdtt_network: b.opt("wdtt_network").unwrap_or("").to_string(),
                        wdtt_ipv4_pool: b.opt("wdtt_ipv4_pool").unwrap_or("").to_string(),
                        wdtt_raw_ipv4_pool: b.opt("wdtt_raw_ipv4_pool").unwrap_or("").to_string(),
                        wdtt_client_dns: b.opt("wdtt_client_dns").unwrap_or("").to_string(),
                        wdtt_mtu: b.opt("wdtt_mtu").and_then(|s| s.parse().ok()).unwrap_or(0),
                        clients: parsed_clients,
                        inbound_json: b.opt("inbound_json").unwrap_or("").to_string(),
                    });
                    imported += 1;
                }
                "profile" | "parental_profile" => {
                    let mut device_ips = b.list("device_ip");
                    for extra in b.list("device_ips") {
                        if !device_ips.contains(&extra) {
                            device_ips.push(extra);
                        }
                    }
                    for extra in b.list("devices") {
                        if !device_ips.contains(&extra) {
                            device_ips.push(extra);
                        }
                    }
                    self.profiles.push(ParentalProfile {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        label: b
                            .opt("label")
                            .or_else(|| b.opt("name"))
                            .unwrap_or(&b.name)
                            .to_string(),
                        avatar: b.opt("avatar").unwrap_or("").to_string(),
                        device_ips,
                        safe_search: b.opt("safe_search").is_some_and(parse_bool),
                        block_doh: b.opt("block_doh").is_some_and(parse_bool),
                        daily_quota_minutes: b
                            .opt("daily_quota_minutes")
                            .or_else(|| b.opt("daily_limit_minutes"))
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        used_minutes_today: b
                            .opt("used_minutes_today")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        paused_until_unix: b
                            .opt("paused_until_unix")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        blocked_categories: b.list("blocked_categories"),
                        blocked_domains: b.list("blocked_domains"),
                        schedule_ref: b
                            .opt("schedule_ref")
                            .or_else(|| b.opt("schedule"))
                            .unwrap_or("")
                            .to_string(),
                        notify: b.opt("notify").is_some_and(parse_bool),
                    });
                    imported += 1;
                }
                "schedule" | "parental_schedule" => {
                    let mut profile_refs = b.list("profile");
                    for extra in b.list("profile_refs") {
                        if !profile_refs.contains(&extra) {
                            profile_refs.push(extra);
                        }
                    }
                    let mut device_ips = b.list("device_ip");
                    for extra in b.list("device_ips") {
                        if !device_ips.contains(&extra) {
                            device_ips.push(extra);
                        }
                    }
                    self.schedules.push(ScheduleRule {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(parse_bool),
                        label: b
                            .opt("label")
                            .or_else(|| b.opt("name"))
                            .unwrap_or(&b.name)
                            .to_string(),
                        profile_refs,
                        device_ips,
                        target: b
                            .opt("target")
                            .or_else(|| b.opt("target_id"))
                            .unwrap_or("")
                            .to_string(),
                        sections: b.list("sections"),
                        action: b.opt("action").unwrap_or("block").to_string(),
                        time_mode: b.opt("time_mode").unwrap_or("range").to_string(),
                        start_time: b.opt("start_time").unwrap_or("").to_string(),
                        end_time: b.opt("end_time").unwrap_or("").to_string(),
                        days: b.list("days"),
                        daily_quota_minutes: b
                            .opt("daily_quota_minutes")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        blocked_domains: b.list("blocked_domains"),
                        blocked_categories: b.list("blocked_categories"),
                        mode: b.opt("mode").unwrap_or("").to_string(),
                        dns_level: b.opt("dns_level").unwrap_or("").to_string(),
                        notify: b.opt("notify").is_some_and(parse_bool),
                    });
                    imported += 1;
                }
                "guest_mode" => {
                    self.guest_mode = GuestModeConfig {
                        enabled: b.opt("enabled").is_some_and(parse_bool),
                        mode: b.opt("mode").unwrap_or("selected").to_string(),
                        guest_devices: b.list("guest_devices"),
                        trusted_devices: b.list("trusted_devices"),
                        isolate_lan: b.opt("isolate_lan").is_none_or(parse_bool),
                        block_router_admin: b.opt("block_router_admin").is_none_or(parse_bool),
                        allow_proxy: b.opt("allow_proxy").is_none_or(parse_bool),
                        daily_time_limit: b
                            .opt("daily_time_limit")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        daily_traffic_limit: b
                            .opt("daily_traffic_limit")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        bandwidth_limit_mbps: b
                            .opt("bandwidth_limit_mbps")
                            .or_else(|| b.opt("bandwidth_limit"))
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(0),
                        allowed_ports: b
                            .list("allowed_ports")
                            .into_iter()
                            .filter_map(|p| p.parse::<u16>().ok())
                            .collect(),
                        allowed_domains: b.list("allowed_domains"),
                        landing_url: b.opt("landing_url").unwrap_or("").to_string(),
                        start_time: b.opt("start_time").unwrap_or("").to_string(),
                        end_time: b.opt("end_time").unwrap_or("").to_string(),
                        days: b.list("days"),
                        notify: b.opt("notify").is_some_and(parse_bool),
                    };
                    imported += 1;
                }
                _ => {}
            }
        }
        self.apply_relax_probe_intervals_v1();
        self.apply_fail_closed_auto_defaults();
        self.apply_ai_lists_1_8();
        imported
    }
}

#[allow(clippy::too_many_arguments)]
fn struct_to_json_section<T: Serialize>(
    kind: &str,
    name: &str,
    idx: usize,
    item: &T,
    rename_keys: &[(&str, &str)],
    skip_keys: &[&str],
    extra_omit_existing: &[&str],
    existing_obj: Option<&serde_json::Map<String, Value>>,
    extra_fields: &[(&str, Value)],
) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert(".anonymous".to_string(), json!(false));
    obj.insert(".type".to_string(), json!(kind));
    obj.insert(".name".to_string(), json!(name));
    obj.insert(".index".to_string(), json!(idx));

    let mut owned_keys: std::collections::HashSet<String> = std::collections::HashSet::new();
    owned_keys.insert("id".to_string());
    for &k in skip_keys {
        owned_keys.insert(k.to_string());
    }
    for &k in extra_omit_existing {
        owned_keys.insert(k.to_string());
    }

    if let Ok(Value::Object(raw_map)) = serde_json::to_value(item) {
        for (k, v) in raw_map {
            owned_keys.insert(k.clone());
            if k == "id" || skip_keys.contains(&k.as_str()) {
                continue;
            }
            let out_key = rename_keys
                .iter()
                .find(|(from, _)| *from == k.as_str())
                .map(|(_, to)| *to)
                .unwrap_or(k.as_str());
            owned_keys.insert(out_key.to_string());

            match v {
                Value::Bool(b) => {
                    obj.insert(
                        out_key.to_string(),
                        Value::String(if b { "1" } else { "0" }.to_string()),
                    );
                }
                Value::Number(n) => {
                    obj.insert(out_key.to_string(), Value::String(n.to_string()));
                }
                Value::String(s) => {
                    if !s.is_empty() {
                        obj.insert(out_key.to_string(), Value::String(s));
                    }
                }
                Value::Array(arr) => {
                    if !arr.is_empty() {
                        let all_scalar = arr.iter().all(|el| {
                            matches!(el, Value::String(_) | Value::Bool(_) | Value::Number(_))
                        });
                        if all_scalar {
                            let converted: Vec<Value> = arr
                                .into_iter()
                                .filter_map(|el| match el {
                                    Value::String(s) => Some(Value::String(s)),
                                    Value::Number(n) => Some(Value::String(n.to_string())),
                                    Value::Bool(b) => {
                                        Some(Value::String(if b { "1" } else { "0" }.to_string()))
                                    }
                                    _ => None,
                                })
                                .collect();
                            if !converted.is_empty() {
                                obj.insert(out_key.to_string(), Value::Array(converted));
                            }
                        } else {
                            obj.insert(out_key.to_string(), Value::Array(arr));
                        }
                    }
                }
                Value::Object(m) => {
                    if !m.is_empty() {
                        obj.insert(out_key.to_string(), Value::Object(m));
                    }
                }
                Value::Null => {}
            }
        }
    }

    for (ek, ev) in extra_fields {
        owned_keys.insert((*ek).to_string());
        if !matches!(ev, Value::Null) {
            obj.insert((*ek).to_string(), ev.clone());
        }
    }

    // Preserve frontend-only keys (e.g. `ui_prefs_json`) present in `existing_obj`.
    if let Some(ex) = existing_obj {
        for (ek, ev) in ex {
            if ek.starts_with('.') || owned_keys.contains(ek) {
                continue;
            }
            obj.insert(ek.clone(), ev.clone());
        }
    }

    Value::Object(obj)
}

/// Reverse-converts `RouterStoreData` (`tachyon.json`) back into a UCI-compatible
/// `config_sections.json` map (`Value::Object`), preserving frontend-only fields
/// (such as `ui_prefs_json`) and non-managed custom section types from `existing`.
pub fn sync_store_to_json_sections(store: &RouterStoreData, existing: Option<&Value>) -> Value {
    let existing_map = existing.and_then(Value::as_object);
    let mut out = serde_json::Map::new();
    let mut idx = 0usize;

    let existing_obj = |key: &str| -> Option<&serde_json::Map<String, Value>> {
        existing_map
            .and_then(|m| m.get(key))
            .and_then(Value::as_object)
    };

    let mut settings_extra: Vec<(&str, Value)> = Vec::new();
    if !store.applied_migrations.is_empty() {
        settings_extra.push(("applied_migrations", json!(store.applied_migrations)));
    }
    let eff_mode = |mode: &str, flag: bool| -> &'static str {
        if flag {
            "1"
        } else if mode.trim().eq_ignore_ascii_case("0") {
            "0"
        } else {
            "auto"
        }
    };
    settings_extra.push((
        "dns_intercept_all",
        json!(eff_mode(
            &store.settings.dns_intercept_all_mode,
            store.settings.dns_intercept_all,
        )),
    ));
    settings_extra.push((
        "webrtc_leak_protect",
        json!(eff_mode(
            &store.settings.webrtc_leak_protect_mode,
            store.settings.webrtc_leak_protect,
        )),
    ));
    out.insert(
        "settings".to_string(),
        struct_to_json_section(
            "settings",
            "settings",
            idx,
            &store.settings,
            &[
                ("dns_servers", "dns_server"),
                ("bootstrap_dns_servers", "bootstrap_dns_server"),
                ("dns_fallback_servers", "dns_fallback_server"),
            ],
            &[
                "admin_pass_hash",
                "admin_pass_salt",
                "session_secret",
                "dns_intercept_all_mode",
                "webrtc_leak_protect_mode",
            ],
            &[],
            existing_obj("settings"),
            &settings_extra,
        ),
    );
    idx += 1;

    out.insert(
        "telegram".to_string(),
        struct_to_json_section(
            "telegram",
            "telegram",
            idx,
            &store.telegram,
            &[],
            &[],
            &[],
            existing_obj("telegram"),
            &[],
        ),
    );
    idx += 1;

    out.insert(
        "guest_mode".to_string(),
        struct_to_json_section(
            "guest_mode",
            "guest_mode",
            idx,
            &store.guest_mode,
            &[],
            &[],
            &[],
            existing_obj("guest_mode"),
            &[],
        ),
    );
    idx += 1;

    for sec in &store.sections {
        if sec.id.trim().is_empty() {
            continue;
        }
        out.insert(
            sec.id.clone(),
            struct_to_json_section(
                "section",
                &sec.id,
                idx,
                sec,
                &[
                    ("rule_set_urls", "rule_set"),
                    ("geoip_codes", "geoip_country"),
                    ("dns_servers", "dns_server"),
                    ("exclude_domains", "excluded_domains"),
                ],
                &[],
                &[],
                existing_obj(&sec.id),
                &[],
            ),
        );
        idx += 1;
    }

    for cond in &store.conditions {
        if cond.id.trim().is_empty() {
            continue;
        }
        out.insert(
            cond.id.clone(),
            struct_to_json_section(
                "condition",
                &cond.id,
                idx,
                cond,
                &[
                    ("remote_domain_lists", "rule_set"),
                    ("remote_subnet_lists", "domain_ip_lists"),
                    ("geoip_codes", "geoip_country"),
                    ("exclude_client_ips", "excluded_ips"),
                    ("exclude_domains", "excluded_domains"),
                ],
                &[],
                &[],
                existing_obj(&cond.id),
                &[],
            ),
        );
        idx += 1;
    }

    for src in &store.outbound_sources {
        if src.id.trim().is_empty() {
            continue;
        }
        out.insert(
            src.id.clone(),
            struct_to_json_section(
                "outbound_source",
                &src.id,
                idx,
                src,
                &[],
                &["cached_nodes"],
                &["url"],
                existing_obj(&src.id),
                &[],
            ),
        );
        idx += 1;
    }

    for bal in &store.balancers {
        if bal.id.trim().is_empty() {
            continue;
        }
        out.insert(
            bal.id.clone(),
            struct_to_json_section(
                "balancer",
                &bal.id,
                idx,
                bal,
                &[],
                &[],
                &[],
                existing_obj(&bal.id),
                &[],
            ),
        );
        idx += 1;
    }

    for grp in &store.outbound_groups {
        if grp.id.trim().is_empty() {
            continue;
        }
        out.insert(
            grp.id.clone(),
            struct_to_json_section(
                "outbound_group",
                &grp.id,
                idx,
                grp,
                &[],
                &[],
                &[],
                existing_obj(&grp.id),
                &[],
            ),
        );
        idx += 1;
    }

    for srv in &store.servers {
        if srv.id.trim().is_empty() {
            continue;
        }
        out.insert(
            srv.id.clone(),
            struct_to_json_section(
                "server",
                &srv.id,
                idx,
                srv,
                &[],
                &[],
                &[],
                existing_obj(&srv.id),
                &[],
            ),
        );
        idx += 1;
    }

    for prof in &store.profiles {
        if prof.id.trim().is_empty() {
            continue;
        }
        out.insert(
            prof.id.clone(),
            struct_to_json_section(
                "profile",
                &prof.id,
                idx,
                prof,
                &[],
                &[],
                &[],
                existing_obj(&prof.id),
                &[],
            ),
        );
        idx += 1;
    }

    for sched in &store.schedules {
        if sched.id.trim().is_empty() {
            continue;
        }
        out.insert(
            sched.id.clone(),
            struct_to_json_section(
                "schedule",
                &sched.id,
                idx,
                sched,
                &[],
                &[],
                &[],
                existing_obj(&sched.id),
                &[],
            ),
        );
        idx += 1;
    }

    if let Some(ex_map) = existing_map {
        for (k, v) in ex_map {
            if out.contains_key(k) {
                continue;
            }
            let Some(obj) = v.as_object() else {
                continue;
            };
            let stype = obj.get(".type").and_then(Value::as_str).unwrap_or("");
            let is_managed = matches!(
                stype,
                "settings"
                    | "telegram"
                    | "guest_mode"
                    | "section"
                    | "condition"
                    | "outbound_source"
                    | "balancer"
                    | "urltest"
                    | "priority_group"
                    | "outbound_group"
                    | "server"
                    | "profile"
                    | "schedule"
                    | "parental_schedule"
            );
            if !is_managed && !stype.is_empty() {
                let mut cloned = obj.clone();
                cloned.insert(".index".to_string(), json!(idx));
                out.insert(k.clone(), Value::Object(cloned));
                idx += 1;
            }
        }
    }

    Value::Object(out)
}

struct LegacyUciBlock {
    kind: String,
    name: String,
    options: HashMap<String, String>,
    lists: HashMap<String, Vec<String>>,
}

pub(crate) fn url_encode_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                out.push_str(&format!("%{b:02X}"));
            }
        }
    }
    out
}

pub fn parse_csqtt_hashes_tokens<'a, I>(items: I) -> Vec<String>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut out = Vec::new();
    for raw in items {
        for part in raw.split([',', '|', ';', '+', '\r', '\n', '\t', ' ']) {
            let mut item = part.trim();
            if item.is_empty() {
                continue;
            }
            if let Some(join_idx) = item.rfind("/call/join/") {
                let tail = &item[join_idx + "/call/join/".len()..];
                item = tail
                    .split(['?', '#', '/'])
                    .next()
                    .map(str::trim)
                    .unwrap_or("");
            }
            if !item.is_empty() && !out.iter().any(|existing: &String| existing == item) {
                out.push(item.to_string());
            }
        }
    }
    out
}

pub fn is_mac_address(s: &str) -> bool {
    let t = s.trim();
    let mut count = 0usize;
    for part in t.split(':') {
        if part.len() != 2 || !part.bytes().all(|b| b.is_ascii_hexdigit()) {
            return false;
        }
        count += 1;
    }
    count == 6
}

fn strip_uci_inline_comment(line: &str) -> &str {
    let mut s = line.trim();
    if let Some(idx) = s.find('#') {
        s = s[..idx].trim();
    }
    if s.starts_with("//") {
        return "";
    }
    if let Some(idx) = s.find("//")
        && s[..idx].ends_with(char::is_whitespace)
    {
        s = s[..idx].trim();
    }
    s
}

impl LegacyUciBlock {
    fn opt(&self, key: &str) -> Option<&str> {
        self.options.get(key).map(String::as_str).or_else(|| {
            self.lists
                .get(key)
                .and_then(|v| v.first())
                .map(String::as_str)
        })
    }
    fn opt_u16(&self, keys: &[&str]) -> u16 {
        keys.iter()
            .find_map(|k| self.opt(k).and_then(|v| v.trim().parse::<u16>().ok()))
            .unwrap_or(0)
    }
    fn opt_str(&self, key: &str) -> String {
        self.opt(key).unwrap_or("").to_string()
    }
    fn excluded_domain_tokens(&self) -> Vec<String> {
        let is_truthy = |s: &str| {
            matches!(
                s.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        };
        let text_mode = self
            .opt("excluded_domains_text_mode")
            .or_else(|| self.opt("conditions_text_mode"))
            .is_some_and(is_truthy);
        let text_vals = self.clean_tokens(&["excluded_domains_text", "exclude_domains_text"]);
        if text_mode && !text_vals.is_empty() {
            return text_vals;
        }
        let list_vals = self.clean_tokens(&["exclude_domains", "excluded_domains"]);
        if !list_vals.is_empty() {
            list_vals
        } else {
            text_vals
        }
    }
    fn community_subnets_and_lists(&self) -> (bool, Vec<String>) {
        let mut enabled = true;
        let mut extra_lists = Vec::new();
        for tok in self.clean_tokens(&["community_subnets"]) {
            let lc = tok.to_ascii_lowercase();
            if matches!(
                lc.as_str(),
                "0" | "1" | "true" | "false" | "yes" | "no" | "on" | "off"
            ) {
                enabled = matches!(lc.as_str(), "1" | "true" | "yes" | "on");
            } else if !extra_lists.iter().any(|x| x == &tok) {
                extra_lists.push(tok);
            }
        }
        (enabled, extra_lists)
    }
    fn desync_keep_socket_str(&self) -> String {
        let raw = self.opt_str("desync_udp_keep_socket");
        let trimmed = raw.trim();
        match trimmed.to_ascii_lowercase().as_str() {
            "" => String::new(),
            "1" | "true" | "yes" | "on" => "1".to_string(),
            "0" | "false" | "no" | "off" => "0".to_string(),
            _ => trimmed.to_string(),
        }
    }
    fn list(&self, key: &str) -> Vec<String> {
        if let Some(l) = self.lists.get(key) {
            return l.clone();
        }
        if let Some(s) = self.options.get(key) {
            return s
                .split_whitespace()
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(String::from)
                .collect();
        }
        Vec::new()
    }
    fn csv_list(&self, key: &str) -> Vec<String> {
        let mut out = Vec::new();
        let sources: Vec<String> = if let Some(l) = self.lists.get(key) {
            l.clone()
        } else if let Some(s) = self.options.get(key) {
            vec![s.clone()]
        } else {
            return out;
        };
        for raw in sources {
            for part in raw.split([',', ' ', '\t', '\r', '\n']) {
                let item = part.trim();
                if !item.is_empty() && !out.iter().any(|existing: &String| existing == item) {
                    out.push(item.to_string());
                }
            }
        }
        out
    }
    fn clean_tokens(&self, keys: &[&str]) -> Vec<String> {
        let mut out = Vec::new();
        for &key in keys {
            for raw in self
                .lists
                .get(key)
                .into_iter()
                .flatten()
                .chain(self.options.get(key))
            {
                for line in raw.lines() {
                    let cleaned = strip_uci_inline_comment(line);
                    if cleaned.is_empty() {
                        continue;
                    }
                    for part in cleaned.split([',', ' ', '\t']) {
                        let tok = part.trim();
                        if !tok.is_empty() && !out.iter().any(|existing: &String| existing == tok) {
                            out.push(tok.to_string());
                        }
                    }
                }
            }
        }
        out
    }
}

/// Parse legacy UCI configuration text into a JSON sections map (`Map<String, Value>`)
/// preserving multiline option values (`domain`, `ip_cidr`, `nfqws2_opt`, etc.).
pub fn parse_uci_text_to_json_sections(raw: &str) -> serde_json::Map<String, Value> {
    let blocks = parse_legacy_uci_blocks(raw);
    let mut out = serde_json::Map::new();
    for (idx, b) in blocks.into_iter().enumerate() {
        let anonymous = b.name == b.kind;
        let sname = if anonymous && out.contains_key(&b.name) {
            format!("cfg{:02x}{}", idx + 1, b.kind)
        } else {
            b.name.clone()
        };
        let mut sec_obj = serde_json::Map::new();
        sec_obj.insert(".anonymous".to_string(), json!(anonymous));
        sec_obj.insert(".type".to_string(), json!(b.kind));
        sec_obj.insert(".name".to_string(), json!(sname.clone()));
        sec_obj.insert(".index".to_string(), json!(idx));
        for (k, v) in b.options {
            sec_obj.insert(k, Value::String(v));
        }
        for (k, arr) in b.lists {
            sec_obj.insert(
                k,
                Value::Array(arr.into_iter().map(Value::String).collect()),
            );
        }
        out.insert(sname, Value::Object(sec_obj));
    }
    out
}

fn parse_legacy_uci_blocks(raw: &str) -> Vec<LegacyUciBlock> {
    let mut blocks: Vec<LegacyUciBlock> = Vec::new();
    let mut current: Option<LegacyUciBlock> = None;
    let mut multiline_key: Option<(bool, String, String)> = None;

    for raw_line in raw.lines() {
        let line = raw_line.trim_end_matches('\r');
        if let Some((is_list, ref key, ref mut acc)) = multiline_key {
            if let Some(stripped) = line.trim_end().strip_suffix('\'') {
                acc.push('\n');
                acc.push_str(stripped);
                let val = acc.clone();
                let k = key.clone();
                multiline_key = None;
                if let Some(ref mut cur) = current {
                    if is_list {
                        cur.lists.entry(k).or_default().push(val);
                    } else {
                        cur.options.insert(k, val);
                    }
                }
            } else {
                acc.push('\n');
                acc.push_str(line);
            }
            continue;
        }

        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("config ") {
            if let Some(prev) = current.take() {
                blocks.push(prev);
            }
            let mut parts = rest.split_whitespace();
            let kind = parts.next().unwrap_or("").trim().to_string();
            let name = parts
                .next()
                .unwrap_or(&kind)
                .trim_matches(['\'', '"'])
                .to_string();
            current = Some(LegacyUciBlock {
                kind,
                name,
                options: HashMap::new(),
                lists: HashMap::new(),
            });
            continue;
        }

        let (is_list, rest) = if let Some(r) = trimmed.strip_prefix("option ") {
            (false, r)
        } else if let Some(r) = trimmed.strip_prefix("list ") {
            (true, r)
        } else {
            continue;
        };

        let mut parts = rest.splitn(2, char::is_whitespace);
        let key = parts.next().unwrap_or("").trim().to_string();
        let raw_val = parts.next().unwrap_or("").trim();

        if let Some(after_open) = raw_val.strip_prefix('\'') {
            if let Some(val) = after_open.strip_suffix('\'') {
                if let Some(ref mut cur) = current {
                    if is_list {
                        cur.lists.entry(key).or_default().push(val.to_string());
                    } else {
                        cur.options.insert(key, val.to_string());
                    }
                }
            } else {
                multiline_key = Some((is_list, key, after_open.to_string()));
            }
        } else {
            let val = raw_val.trim_matches('"').to_string();
            if let Some(ref mut cur) = current {
                if is_list {
                    cur.lists.entry(key).or_default().push(val);
                } else {
                    cur.options.insert(key, val);
                }
            }
        }
    }
    if let Some(prev) = current.take() {
        blocks.push(prev);
    }
    blocks
}

fn parse_duration_secs(s: &str) -> u32 {
    let t = s.trim();
    if let Some(m) = t.strip_suffix('m').and_then(|v| v.parse::<u32>().ok()) {
        return m * 60;
    }
    if let Some(h) = t.strip_suffix('h').and_then(|v| v.parse::<u32>().ok()) {
        return h * 3600;
    }
    if let Some(sec) = t.strip_suffix('s').and_then(|v| v.parse::<u32>().ok()) {
        return sec;
    }
    t.parse::<u32>().unwrap_or(180)
}

fn normalize_sub_cache_url(raw: &str) -> &str {
    raw.trim().trim_end_matches('/')
}

fn cache_stem_matches_source(
    cache_dir: &Path,
    stem: &str,
    src: &OutboundSource,
    norm_urls: &[&str],
) -> bool {
    let url_path = cache_dir.join(format!("{stem}.url"));
    if let Ok(raw_url) = std::fs::read_to_string(&url_path) {
        let u = normalize_sub_cache_url(&raw_url);
        if !u.is_empty() {
            return norm_urls.contains(&u);
        }
    }
    stem == src.id
        || (!src.name.is_empty() && stem == src.name)
        || stem.starts_with(&format!("{}-", src.id))
        || (!src.name.is_empty() && stem.starts_with(&format!("{}-", src.name)))
}

pub fn load_cached_subscription_nodes_from(src: &mut OutboundSource, cache_dir: &Path) {
    if src.source_type != "subscription" {
        return;
    }
    let Ok(rd) = std::fs::read_dir(cache_dir) else {
        return;
    };
    let mut paths: Vec<std::path::PathBuf> = rd.flatten().map(|e| e.path()).collect();
    paths.sort();

    let norm_urls: Vec<&str> = src
        .subscription_urls
        .iter()
        .map(|u| normalize_sub_cache_url(u))
        .filter(|u| !u.is_empty())
        .collect();
    let mut seen_tags: std::collections::HashSet<String> =
        src.cached_nodes.iter().map(|n| n.tag.clone()).collect();

    for path in paths {
        let fname = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if let Some(stem) = fname.strip_suffix(".metadata.json") {
            if cache_stem_matches_source(cache_dir, stem, src, &norm_urls)
                && let Ok(raw) = std::fs::read_to_string(&path)
                && let Ok(v) = serde_json::from_str::<Value>(&raw)
            {
                if let Some(t) = v.get("title").and_then(Value::as_str) {
                    src.sub_title = decode_sub_header_value(t);
                }
                if let Some(u) = v.get("supportUrl").and_then(Value::as_str) {
                    src.sub_support_url = u.to_string();
                }
                if let Some(u) = v.get("webPageUrl").and_then(Value::as_str) {
                    src.sub_web_page_url = u.to_string();
                }
                if let Some(a) = v.get("announce").and_then(Value::as_str) {
                    src.sub_announce = decode_sub_header_value(a);
                }
            }
            continue;
        }
        if fname.ends_with(".meta.json") {
            continue;
        }
        let Some(stem) = fname.strip_suffix(".json") else {
            continue;
        };
        if !cache_stem_matches_source(cache_dir, stem, src, &norm_urls) {
            continue;
        }
        let Ok(raw) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let Some(arr) = v.get("outbounds").and_then(Value::as_array) else {
            continue;
        };
        for item in arr {
            let tag = item
                .get("tag")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let proto = item
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("vless")
                .to_string();
            let server = item
                .get("server")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let mut server_port =
                item.get("server_port").and_then(Value::as_u64).unwrap_or(0) as u16;
            if server_port == 0 {
                server_port = item
                    .get("server_ports")
                    .and_then(Value::as_array)
                    .and_then(|arr| arr.first())
                    .and_then(Value::as_str)
                    .and_then(|s| s.split(['-', ':']).next())
                    .and_then(|p| p.trim().parse::<u16>().ok())
                    .unwrap_or(443);
            }
            if tag.is_empty() || server.is_empty() || !seen_tags.insert(tag.clone()) {
                continue;
            }
            let raw_uri = item
                .get("share_link")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let mut outbound_json = item.clone();
            if let Some(obj) = outbound_json.as_object_mut() {
                obj.remove("share_link");
            }
            let country = config_gen::detect_country_code(&tag);
            src.cached_nodes.push(ParsedProxyNode {
                tag,
                protocol: proto,
                server,
                server_port,
                country,
                raw_uri,
                outbound_json,
            });
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventRecord {
    pub timestamp: i64,
    pub level: String,
    pub subsystem: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HoneypotHit {
    pub timestamp: i64,
    pub ip: String,
    pub path: String,
    pub reason: String,
    pub banned: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRecord {
    pub id: String,
    pub kind: String,
    pub status: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub progress_pct: u8,
    pub logs: Vec<String>,
    pub result: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ThroughputSample {
    pub ts: i64,
    pub rx_bps: u64,
    pub tx_bps: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct LiveTelemetry {
    pub core_running: bool,
    pub core_pid: Option<u32>,
    pub core_identity: Option<ProcessIdentity>,
    pub core_version: String,
    pub core_uptime_secs: u64,
    pub core_rss_bytes: u64,
    pub total_up_bps: u64,
    pub total_down_bps: u64,
    pub total_up_bytes: u64,
    pub total_down_bytes: u64,
    pub active_connections: usize,
    pub nft_table_active: bool,
    pub dns_healthy: bool,
    pub wan_healthy: bool,
    pub lkg_observing: bool,
    pub lkg_remaining_secs: u64,
    pub lan_devices: Vec<LanDevice>,
    /// Node tag -> latest RTT latency in ms (bounded to `MAX_NODE_LATENCIES`).
    pub node_latencies_ms: HashMap<String, u32>,
    /// Fixed ring of last 60 throughput points `(timestamp_sec, up_bps, down_bps)`.
    pub throughput_history: Vec<(i64, u64, u64)>,
    /// Fixed ring of last 60 throughput points `{ ts, rx_bps, tx_bps }` for UI chart.
    pub throughput: Vec<ThroughputSample>,
    /// Bounded recent core log lines (max `MAX_RECENT_LOGS`).
    pub recent_logs: Vec<String>,
    /// Bounded redacted event journal (max `MAX_EVENTS_RING`).
    pub events: Vec<EventRecord>,
    /// Bounded background jobs (max `MAX_JOBS`).
    pub jobs: Vec<JobRecord>,
    /// Bounded honeypot hits (max `MAX_HONEYPOT_HITS`).
    pub honeypot_hits: Vec<HoneypotHit>,
    /// Bounded IP -> `(strike_count, ban_until_unix_sec)` (max `MAX_HONEYPOT_STRIKES`).
    #[serde(skip)]
    pub honeypot_ip_strikes: HashMap<String, (u32, i64)>,
}

impl LiveTelemetry {
    pub fn push_event(&mut self, level: &str, subsystem: &str, message: &str) {
        if self.events.len() >= MAX_EVENTS_RING {
            self.events.remove(0);
        }
        self.events.push(EventRecord {
            timestamp: unix_now_secs(),
            level: level.to_string(),
            subsystem: subsystem.to_string(),
            message: crypto_gen::redact_string(message),
        });
    }

    pub fn push_log(&mut self, line: &str) {
        if self.recent_logs.len() >= MAX_RECENT_LOGS {
            self.recent_logs.remove(0);
        }
        self.recent_logs.push(crypto_gen::redact_string(line));
    }

    pub fn start_job(&mut self, kind: &str, initial_msg: &str) -> String {
        if self.jobs.len() >= MAX_JOBS {
            self.jobs.remove(0);
        }
        let now = unix_now_secs();
        let id = format!("job-{now}-{}", crypto_gen::generate_hex(3));
        self.jobs.push(JobRecord {
            id: id.clone(),
            kind: kind.to_string(),
            status: "running".to_string(),
            created_at: now,
            updated_at: now,
            progress_pct: 10,
            logs: vec![initial_msg.to_string()],
            result: json!({}),
        });
        id
    }

    pub fn complete_job(&mut self, id: &str, ok: bool, msg: &str, result: Value) {
        let now = unix_now_secs();
        if let Some(j) = self.jobs.iter_mut().find(|j| j.id == id) {
            j.status = if ok {
                "completed".to_string()
            } else {
                "failed".to_string()
            };
            j.updated_at = now;
            j.progress_pct = 100;
            j.logs.push(msg.to_string());
            j.result = result;
        }
    }

    pub fn record_honeypot_hit(&mut self, ip: &str, path: &str, reason: &str) {
        let now = unix_now_secs();
        let is_loopback = ip == "127.0.0.1" || ip == "::1" || ip == "localhost" || ip == "unknown";

        // Evict expired strikes first and enforce hard capacity cap (`MAX_HONEYPOT_STRIKES`).
        if self.honeypot_ip_strikes.len() >= MAX_HONEYPOT_STRIKES {
            self.honeypot_ip_strikes
                .retain(|_, (_, until)| *until > now);
            if self.honeypot_ip_strikes.len() >= MAX_HONEYPOT_STRIKES
                && let Some(oldest_ip) = self
                    .honeypot_ip_strikes
                    .iter()
                    .min_by_key(|(_, (_, until))| *until)
                    .map(|(k, _)| k.clone())
            {
                self.honeypot_ip_strikes.remove(&oldest_ip);
            }
        }

        let entry = self
            .honeypot_ip_strikes
            .entry(ip.to_string())
            .or_insert((0, 0));
        entry.0 = entry.0.saturating_add(1);
        let banned = if !is_loopback && entry.0 >= 5 {
            entry.1 = now + 900;
            true
        } else {
            entry.1 > now
        };

        if self.honeypot_hits.len() >= MAX_HONEYPOT_HITS {
            self.honeypot_hits.remove(0);
        }
        self.honeypot_hits.push(HoneypotHit {
            timestamp: now,
            ip: ip.to_string(),
            path: path.to_string(),
            reason: reason.to_string(),
            banned,
        });
    }
}

pub fn unix_now_u64() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub struct AppState {
    pub path: PathBuf,
    pub lkg_path: PathBuf,
    pub data: RwLock<RouterStoreData>,
    pub live: RwLock<LiveTelemetry>,
    /// Session token -> expiry unix timestamp (bounded to `MAX_SESSIONS`).
    pub sessions: RwLock<HashMap<String, i64>>,
    pub dirty: AtomicBool,
    pub last_telemetry_access_ts: PortableAtomicU64,
}

impl AppState {
    pub fn touch_telemetry_access(&self) {
        self.last_telemetry_access_ts
            .store(unix_now_u64(), Ordering::Release);
    }

    pub fn is_telemetry_active(&self, now_secs: u64, window_secs: u64) -> bool {
        let last = self.last_telemetry_access_ts.load(Ordering::Acquire);
        last != 0 && now_secs.saturating_sub(last) <= window_secs
    }
}

impl AppState {
    pub fn load_or_create(path: impl AsRef<Path>) -> anyhow::Result<Arc<Self>> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)?;
        }
        let lkg_path = path.with_file_name("tachyon.known_good.json");

        let data = if path.exists() {
            let raw = std::fs::read_to_string(&path)?;
            let raw_val = serde_json::from_str::<serde_json::Value>(&raw).ok();
            let raw_has_ipv6_mode = raw_val
                .as_ref()
                .and_then(|v| v.pointer("/settings/ipv6_mode"))
                .and_then(|v| v.as_str())
                .is_some();
            let raw_enable_ipv6 = raw_val
                .as_ref()
                .and_then(|v| v.pointer("/settings/enable_ipv6"))
                .and_then(|v| v.as_bool());
            let mut parsed = serde_json::from_str::<RouterStoreData>(&raw)?;
            let mut migrated = false;

            if !raw_has_ipv6_mode && let Some(en) = raw_enable_ipv6 {
                parsed.settings.ipv6_mode = if en {
                    "dual_stack".to_string()
                } else {
                    "off".to_string()
                };
                migrated = true;
            }
            let norm_ui = normalize_ui_mode(&parsed.settings.ui_mode);
            if norm_ui != parsed.settings.ui_mode {
                parsed.settings.ui_mode = norm_ui;
                migrated = true;
            }
            let norm_v6 = normalize_ipv6_mode(&parsed.settings.ipv6_mode);
            if norm_v6 != parsed.settings.ipv6_mode {
                parsed.settings.ipv6_mode = norm_v6;
                migrated = true;
            }
            if parsed.settings.ipv6_mode == "dual_stack" && !parsed.settings.enable_ipv6 {
                parsed.settings.enable_ipv6 = true;
                migrated = true;
            } else if parsed.settings.ipv6_mode == "off" && parsed.settings.enable_ipv6 {
                parsed.settings.enable_ipv6 = false;
                migrated = true;
            }
            let norm_dns = normalize_dns_strategy(&parsed.settings.dns_strategy);
            if norm_dns != parsed.settings.dns_strategy {
                parsed.settings.dns_strategy = norm_dns;
                migrated = true;
            }
            let norm_tcp = normalize_tcp_profile(&parsed.settings.tcp_profile);
            if norm_tcp != parsed.settings.tcp_profile {
                parsed.settings.tcp_profile = norm_tcp;
                migrated = true;
            }
            let safe_cache = sanitize_cache_path(&parsed.settings.cache_path);
            if safe_cache != parsed.settings.cache_path {
                parsed.settings.cache_path = safe_cache;
                migrated = true;
            }

            // If store still matches the unedited initial template (e.g. a package hook
            // initialized `tachyon.json` before legacy backup/config was restored) and has not
            // yet recorded `legacy_uci_imported_v1`, perform a one-shot UCI import.
            let already_imported = parsed
                .applied_migrations
                .iter()
                .any(|m| m == LEGACY_UCI_IMPORTED_MIGRATION);
            if !already_imported
                && parsed.is_seeded_default_store()
                && (Path::new("/etc/config/tachyon").exists()
                    || Path::new(LEGACY_UCI_BACKUP_PATH).exists())
            {
                let count = parsed.import_legacy_router_files();
                if count > 0 {
                    migrated = true;
                }
            }
            if parsed.apply_relax_probe_intervals_v1() {
                migrated = true;
            }
            if parsed.apply_fail_closed_auto_defaults() {
                migrated = true;
            }
            if parsed.apply_ai_lists_1_8() {
                migrated = true;
            }
            if parsed.settings.subscription_engine != "core" {
                parsed.settings.subscription_engine = "core".to_string();
                migrated = true;
            }
            for src in &mut parsed.outbound_sources {
                if src.subscription_engine != "core" {
                    src.subscription_engine = "core".to_string();
                    migrated = true;
                }
                let dec_title = decode_sub_header_value(&src.sub_title);
                if dec_title != src.sub_title {
                    src.sub_title = dec_title;
                    migrated = true;
                }
                let dec_announce = decode_sub_header_value(&src.sub_announce);
                if dec_announce != src.sub_announce {
                    src.sub_announce = dec_announce;
                    migrated = true;
                }
            }
            if migrated {
                let _ = crypto_gen::write_json_if_changed(&path, &parsed);
            }
            parsed
        } else {
            let default_data = RouterStoreData::default();
            let _ = crypto_gen::write_json_if_changed(&path, &default_data);
            default_data
        };

        let runtime_ver_path = runtime_state_dir().join("tachyon-core-version");
        let core_ver = std::fs::read_to_string(&runtime_ver_path)
            .or_else(|_| std::fs::read_to_string("/etc/tachyon/tachyon-core-version"))
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "0.3.7".to_string());

        let mut live = LiveTelemetry {
            core_version: core_ver,
            lan_devices: crate::sys_info::discover_lan_devices(),
            ..Default::default()
        };
        live.push_event("info", "store", "Configuration store initialized");

        Ok(Arc::new(Self {
            path,
            lkg_path,
            data: RwLock::new(data),
            live: RwLock::new(live),
            sessions: RwLock::new(HashMap::new()),
            dirty: AtomicBool::new(false),
            last_telemetry_access_ts: PortableAtomicU64::new(0),
        }))
    }

    /// Save current configuration to disk only if bytes changed (NAND flash wear protection).
    pub async fn save(&self) -> anyhow::Result<bool> {
        let d = self.data.read().await;
        let written = crypto_gen::write_json_if_changed(&self.path, &*d)?;
        self.dirty.store(false, Ordering::Release);
        Ok(written)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_import_legacy_falls_back_to_backup_uci_when_primary_missing() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let tmp_dir =
            std::env::temp_dir().join(format!("tachyon-store-test-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&tmp_dir).expect("create temp test dir");

        let missing_primary = tmp_dir.join("missing.uci");
        let backup_uci = tmp_dir.join("tachyon.uci");
        let uci_content = r#"
config settings 'settings'
	option proxy_mode 'tun'
	option dns_type 'dot'

config outbound_source 'sub_main'
	option name 'MainSub'
	option source_type 'subscription'
	list subscription_urls 'https://example.org/sub.txt'

config section 'Main'
	option label 'Main Section'
	option enabled '1'
	option action 'proxy'
	list outbound_source_refs 'sub_main'

config server 'srv_vless'
	option label 'Router VLESS'
	option protocol 'vless'
	option listen_port '8443'

config telegram 'telegram'
	option enabled '1'
	option bot_token '123456:TESTTOKEN'
	option admin_ids '1001,1002'
	option router_name 'BackupRouter'
	option poll_interval '7'
"#;
        std::fs::write(&backup_uci, uci_content).expect("write backup uci");

        let mut store = RouterStoreData {
            settings: GlobalSettings::default(),
            sections: Vec::new(),
            conditions: Vec::new(),
            outbound_sources: Vec::new(),
            balancers: Vec::new(),
            outbound_groups: Vec::new(),
            servers: Vec::new(),
            profiles: Vec::new(),
            schedules: Vec::new(),
            guest_mode: GuestModeConfig::default(),
            telegram: TgBotConfig::default(),
            device_registry: HashMap::new(),
            applied_migrations: Vec::new(),
        };

        let imported = store.import_legacy_router_files_from(&missing_primary, &backup_uci);
        let _ = std::fs::remove_dir_all(&tmp_dir);

        assert!(imported >= 5);
        assert_eq!(store.settings.proxy_mode, "tun");
        assert_eq!(store.settings.dns_type, "dot");
        assert_eq!(store.outbound_sources.len(), 1);
        assert_eq!(store.outbound_sources[0].id, "sub_main");
        assert_eq!(store.sections.len(), 1);
        assert_eq!(store.sections[0].id, "Main");
        assert_eq!(store.sections[0].label, "Main Section");
        assert_eq!(store.servers.len(), 1);
        assert_eq!(store.servers[0].id, "srv_vless");
        assert_eq!(store.servers[0].listen_port, 8443);
        assert!(store.telegram.enabled);
        assert_eq!(store.telegram.bot_token, "123456:TESTTOKEN");
        assert_eq!(store.telegram.admin_ids, vec![1001, 1002]);
        assert_eq!(store.telegram.router_name, "BackupRouter");
        assert_eq!(store.telegram.poll_interval, 7);
    }

    #[test]
    fn test_legacy_migration_comments_subscriptions_and_balancers() {
        let tmp_dir = std::env::temp_dir().join(format!(
            "tachyon-mig-full-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let sub_dir = tmp_dir.join("subscription-cache");
        let _ = std::fs::create_dir_all(&sub_dir);
        let uci_path = tmp_dir.join("tachyon");

        std::fs::write(
            sub_dir.join("aaa111.url"),
            "https://sub.example.test/clouds\n",
        )
        .expect("write url 1");
        std::fs::write(
            sub_dir.join("aaa111.json"),
            serde_json::json!({
                "outbounds": [
                    {
                        "tag": "DE One",
                        "type": "vless",
                        "server": "198.51.100.10",
                        "server_port": 443,
                        "uuid": "11111111-1111-1111-1111-111111111111"
                    },
                    {
                        "tag": "DE One",
                        "type": "vless",
                        "server": "198.51.100.11",
                        "server_port": 443,
                        "uuid": "11111111-1111-1111-1111-111111111112"
                    }
                ]
            })
            .to_string(),
        )
        .expect("write cache 1");
        std::fs::write(
            sub_dir.join("bbb222.url"),
            "https://sub.example.test/soft\n",
        )
        .expect("write url 2");
        std::fs::write(
            sub_dir.join("bbb222.json"),
            serde_json::json!({
                "outbounds": [
                    {
                        "tag": "DE DOUBLE HOPE #10",
                        "type": "vless",
                        "server": "198.51.100.20",
                        "server_port": 443,
                        "uuid": "22222222-2222-2222-2222-222222222222"
                    }
                ]
            })
            .to_string(),
        )
        .expect("write cache 2");

        let uci_content = r#"config settings 'settings'
	option proxy_mode 'tproxy'
	option cache_path '/etc/tachyon-core/cache.db'
	list excluded_ips '192.168.1.99 # livingroom TV'

config outbound_source 'Clouds'
	option type 'subscription'
	option enabled '1'
	option name 'Clouds'
	option url 'https://sub.example.test/clouds'

config outbound_source 'SoftPortal'
	option type 'subscription'
	option enabled '1'
	option name 'SoftPortal'
	option url 'https://sub.example.test/soft'

config urltest
	option tag 'anon_skip'
	option interval '3m'

config balancer 'Stability'
	option type 'urltest'
	option check_interval_jitter '15%'
	option tolerance '80'

config priority_group 'Priority'
	option label 'Priority'

config outbound_group 'Germany'
	option flag_emoji '0'
	list include_outbounds '[Clouds] DE One'
	list include_outbounds 'DE DOUBLE HOPE #10'

config condition 'cond_ByPass'
	option enabled '1'
	option type 'atomic'
	list community_lists 'russia_outside'
	list client_ips '192.168.1.0/24 # LAN net'
	list user_domains 'kimi.ai # AI portal'
	list user_domains 'multiline.example
	'
	list user_subnets '192.168.2.0/24 # secondary subnet'

config section 'ByPass'
	option enabled '1'
	option action 'direct'
	list condition_refs 'cond_ByPass'
	list fully_routed_ips '3e:83:67:22:fe:65'
	list excluded_ips '192.168.1.10 # phone'

config section 'Zapret2'
	option enabled '1'
	option action 'desync'
	option source_type 'desync'
	list dashboard_include_countries 'US'

config schedule 'Nahui'
	option enabled '1'
	option name 'Nahui'
	option action 'block'
	option daily_quota_minutes '60'
"#;
        std::fs::write(&uci_path, uci_content).expect("write uci");

        let mut store = RouterStoreData::default();
        let imported = store.import_legacy_router_files_with_cache(&[uci_path.as_path()], &sub_dir);
        let _ = std::fs::remove_dir_all(&tmp_dir);

        assert!(imported >= 8);
        assert_eq!(store.settings.cache_path, "/tmp/tachyon-core/cache.db");
        assert_eq!(store.settings.excluded_ips, vec!["192.168.1.99"]);

        let clouds = store
            .outbound_sources
            .iter()
            .find(|s| s.id == "Clouds")
            .expect("Clouds source");
        assert_eq!(clouds.cached_nodes.len(), 1, "tag dedup + url matching");
        assert_eq!(clouds.cached_nodes[0].server, "198.51.100.10");

        let soft = store
            .outbound_sources
            .iter()
            .find(|s| s.id == "SoftPortal")
            .expect("SoftPortal source");
        assert_eq!(soft.cached_nodes.len(), 1);
        assert_eq!(soft.cached_nodes[0].server, "198.51.100.20");

        assert!(
            !store.balancers.iter().any(|b| b.id == "anon_skip"),
            "anonymous urltest block must not create duplicate balancer"
        );
        let stability = store
            .balancers
            .iter()
            .find(|b| b.id == "Stability")
            .expect("Stability balancer");
        assert_eq!(stability.check_interval_jitter, 15);
        let priority = store
            .balancers
            .iter()
            .find(|b| b.id == "Priority")
            .expect("Priority balancer");
        assert_eq!(priority.mode, "priority");

        let germany = store
            .outbound_groups
            .iter()
            .find(|g| g.id == "Germany")
            .expect("Germany group");
        assert_eq!(
            germany.include_servers,
            vec!["[Clouds] DE One", "DE DOUBLE HOPE #10"]
        );

        let cond_bp = store
            .conditions
            .iter()
            .find(|c| c.id == "cond_ByPass")
            .expect("cond_ByPass");
        assert_eq!(cond_bp.client_ips, vec!["192.168.1.0/24"]);
        assert_eq!(cond_bp.user_domains, vec!["kimi.ai", "multiline.example"]);
        assert_eq!(cond_bp.user_subnets, vec!["192.168.2.0/24"]);

        let sec_bp = store
            .sections
            .iter()
            .find(|s| s.id == "ByPass")
            .expect("ByPass section");
        assert_eq!(sec_bp.fully_routed_ips, vec!["3e:83:67:22:fe:65"]);
        assert_eq!(sec_bp.excluded_ips, vec!["192.168.1.10"]);

        let zapret2 = store
            .sections
            .iter()
            .find(|s| s.id == "Zapret2")
            .expect("Zapret2 section");
        assert_eq!(zapret2.connection_type, "desync");
        assert!(zapret2.include_countries.is_empty());

        assert!(store.schedules.iter().any(|s| s.id == "Nahui"));
    }

    #[test]
    fn test_nftables_excluded_ips_mac_bypass_and_paused_profile() {
        let mut store = RouterStoreData::default();
        store.settings.excluded_ips =
            vec!["192.168.1.99".to_string(), "aa:bb:cc:dd:ee:01".to_string()];
        store.sections.clear();
        store.sections.push(RoutingSection {
            id: "ByPass".to_string(),
            enabled: true,
            label: "ByPass".to_string(),
            action: "direct".to_string(),
            fully_routed_ips: vec!["3e:83:67:22:fe:65".to_string()],
            ..Default::default()
        });
        store.profiles.push(ParentalProfile {
            id: "kid_paused".to_string(),
            enabled: true,
            label: "Paused Kid".to_string(),
            device_ips: vec!["aa:bb:cc:dd:ee:02".to_string()],
            paused_until_unix: i64::MAX,
            ..Default::default()
        });

        let nft = crate::net_stack::compile_nftables_ruleset(&store);
        assert!(nft.contains("ip saddr 192.168.1.99 return"));
        assert!(nft.contains("ether saddr aa:bb:cc:dd:ee:01 return"));
        assert!(nft.contains("ether saddr aa:bb:cc:dd:ee:02 drop"));

        let mac_drop_pos = nft
            .find("ether saddr aa:bb:cc:dd:ee:02 drop")
            .expect("paused MAC drop rule must exist");
        let localv4_pos = nft
            .find("ip daddr @localv4 return")
            .expect("@localv4 return must exist");
        let mac_bypass_pos = nft
            .find("ether saddr 3e:83:67:22:fe:65 return")
            .expect("MAC bypass rule must exist");
        assert!(
            mac_drop_pos < mac_bypass_pos && mac_bypass_pos < localv4_pos,
            "direct section MAC bypass must appear after blocked MAC drops and before @localv4 return"
        );
    }

    #[test]
    fn test_tailscale_validation_predicates_and_probe_relax_migration() {
        assert!(validate_tailscale_network_options("", "", "ts").is_ok());
        assert!(validate_tailscale_network_options("41641", "1280", "ts").is_ok());
        for bad_port in ["0", "70000", "abc"] {
            assert!(
                validate_tailscale_network_options(bad_port, "", "ts").is_err(),
                "port {bad_port} must be rejected"
            );
        }
        for bad_mtu in ["400", "70000", "abc"] {
            assert!(
                validate_tailscale_network_options("", bad_mtu, "ts").is_err(),
                "mtu {bad_mtu} must be rejected"
            );
        }

        let src_default = OutboundSource {
            source_type: "tailscale".to_string(),
            ..Default::default()
        };
        assert!(src_default.is_tailscale());
        assert!(src_default.is_embedded_tailscale());
        assert!(!src_default.is_native_tailscale());

        let src_singbox = OutboundSource {
            source_type: "tailscale".to_string(),
            tailscale_mode: "singbox".to_string(),
            ..Default::default()
        };
        assert!(src_singbox.is_tailscale());
        assert!(src_singbox.is_embedded_tailscale());
        assert!(!src_singbox.is_native_tailscale());

        let src_native = OutboundSource {
            source_type: "tailscale".to_string(),
            tailscale_mode: "native".to_string(),
            ..Default::default()
        };
        assert!(src_native.is_tailscale());
        assert!(!src_native.is_embedded_tailscale());
        assert!(src_native.is_native_tailscale());

        let srv_singbox = InboundServer {
            protocol: "tailscale".to_string(),
            tailscale_mode: "singbox".to_string(),
            ..Default::default()
        };
        assert!(srv_singbox.is_tailscale());
        assert!(srv_singbox.is_embedded_tailscale());
        assert!(!srv_singbox.is_native_tailscale());

        let srv_native = InboundServer {
            protocol: "tailscale".to_string(),
            tailscale_mode: "native".to_string(),
            ..Default::default()
        };
        assert!(srv_native.is_tailscale());
        assert!(!srv_native.is_embedded_tailscale());
        assert!(srv_native.is_native_tailscale());

        let sec_singbox = RoutingSection {
            action: "tailscale".to_string(),
            tailscale_mode: "singbox".to_string(),
            ..Default::default()
        };
        assert!(sec_singbox.is_tailscale());
        assert!(sec_singbox.is_embedded_tailscale());
        assert!(!sec_singbox.is_native_tailscale());

        let sec_native = RoutingSection {
            action: "tailscale".to_string(),
            tailscale_mode: "native".to_string(),
            ..Default::default()
        };
        assert!(sec_native.is_tailscale());
        assert!(!sec_native.is_embedded_tailscale());
        assert!(sec_native.is_native_tailscale());

        let mut store = RouterStoreData::default();
        store.applied_migrations.clear();
        store.balancers.clear();
        store.settings.dns_check_interval = "10s".to_string();
        store.settings.ai_proxy_health_interval = 30;
        store.settings.ai_dns_interval = 60;
        store.balancers.push(BalancerConfig {
            id: "bal_1".to_string(),
            name: "Bal 1".to_string(),
            active_check_interval: "5s".to_string(),
            recovery_check_interval: "15s".to_string(),
            urltest_active_check_interval: "10s".to_string(),
            check_interval: 10,
            ..Default::default()
        });

        assert!(store.apply_relax_probe_intervals_v1());
        assert_eq!(store.settings.dns_check_interval, "30s");
        assert_eq!(store.settings.ai_proxy_health_interval, 60);
        assert_eq!(store.settings.ai_dns_interval, 180);
        assert_eq!(store.balancers[0].active_check_interval, "15s");
        assert_eq!(store.balancers[0].recovery_check_interval, "30s");
        assert_eq!(store.balancers[0].urltest_active_check_interval, "30s");
        assert_eq!(store.balancers[0].check_interval, 30);

        // Repeat call must be idempotent and leave manual overrides untouched.
        store.settings.dns_check_interval = "15s".to_string();
        assert!(!store.apply_relax_probe_intervals_v1());
        assert_eq!(store.settings.dns_check_interval, "15s");
    }

    #[test]
    fn test_canonical_ipv6_ui_mode_cache_path_and_nand_guard() {
        assert_eq!(normalize_ui_mode("basic"), "simple");
        assert_eq!(normalize_ui_mode("SIMPLE"), "simple");
        assert_eq!(normalize_ui_mode("advanced"), "advanced");
        assert_eq!(normalize_ui_mode("anything_else"), "simple");

        assert_eq!(normalize_ipv6_mode("dual_stack"), "dual_stack");
        assert_eq!(normalize_ipv6_mode("ipv4_ipv6"), "dual_stack");
        assert_eq!(normalize_ipv6_mode("on"), "dual_stack");
        assert_eq!(normalize_ipv6_mode("full"), "dual_stack");
        assert_eq!(normalize_ipv6_mode("tunnel_over_v4"), "tunnel_over_v4");
        assert_eq!(normalize_ipv6_mode("v6_over_v4"), "tunnel_over_v4");
        assert_eq!(normalize_ipv6_mode("off"), "off");
        assert_eq!(normalize_ipv6_mode("ipv4_only"), "off");
        assert_eq!(normalize_ipv6_mode("ipv4"), "off");
        assert_eq!(normalize_ipv6_mode("unknown"), "auto");

        assert_eq!(normalize_dns_strategy("prefer_ipv6"), "prefer_ipv6");
        assert_eq!(normalize_dns_strategy("ipv6_only"), "ipv6_only");
        assert_eq!(normalize_dns_strategy("bogus"), "prefer_ipv4");

        // NAND protection: never allow flash paths for cache.db
        assert_eq!(
            sanitize_cache_path("/usr/share/tachyon-core/cache.db"),
            "/tmp/tachyon-core/cache.db"
        );
        assert_eq!(
            sanitize_cache_path("/etc/tachyon/cache.db"),
            "/tmp/tachyon-core/cache.db"
        );
        assert_eq!(
            sanitize_cache_path("/var/run/tachyon/cache.db"),
            "/var/run/tachyon/cache.db"
        );
        assert_eq!(
            sanitize_cache_path("/tmp/custom-cache.db"),
            "/tmp/custom-cache.db"
        );

        let mut s = GlobalSettings {
            ipv6_mode: "auto".to_string(),
            ipv6_leak_guard: true,
            enable_ipv6: false,
            dns_strategy: "prefer_ipv6".to_string(),
            ..Default::default()
        };

        let state_guard = resolve_effective_ipv6_state(&s, false);
        assert_eq!(state_guard, EffectiveIpv6State::LeakGuard);
        assert!(!state_guard.is_active());
        assert!(state_guard.is_leak_guard());
        assert_eq!(effective_dns_strategy(&s, state_guard), "ipv4_only");
        assert_eq!(effective_tun_inet6(&s, state_guard), None);

        s.ipv6_leak_guard = false;
        let state_off = resolve_effective_ipv6_state(&s, false);
        assert_eq!(state_off, EffectiveIpv6State::Disabled);
        assert_eq!(effective_dns_strategy(&s, state_off), "ipv4_only");

        let state_full = resolve_effective_ipv6_state(&s, true);
        assert_eq!(state_full, EffectiveIpv6State::Full);
        assert!(state_full.is_active());
        assert_eq!(effective_dns_strategy(&s, state_full), "prefer_ipv6");

        s.ipv6_mode = "tunnel_over_v4".to_string();
        let state_tov4 = resolve_effective_ipv6_state(&s, false);
        assert_eq!(state_tov4, EffectiveIpv6State::TunnelOverV4);
        assert!(state_tov4.is_active());
        assert!(state_tov4.is_tunnel_over_v4());

        // Overlapping tun_inet6 vs fakeip_inet6_range must fall back safely
        s.fakeip_inet6_range = "fc00::/18".to_string();
        s.tun_inet6 = "fc00:1::1/126".to_string();
        let non_overlapping = effective_tun_inet6(&s, state_full).expect("tun_inet6 fallback");
        assert!(!cidr_v6_overlaps(&non_overlapping, "fc00::/18"));

        // NAND write_json_if_changed skips identical rewrites
        let tmp_dir = std::env::temp_dir().join(format!("tachyon_nand_{}", unix_now_secs()));
        let _ = std::fs::create_dir_all(&tmp_dir);
        let test_file = tmp_dir.join("state.json");
        let payload = serde_json::json!({"ok": true, "mode": "simple"});
        assert!(crate::crypto_gen::write_json_if_changed(&test_file, &payload).unwrap());
        assert!(!crate::crypto_gen::write_json_if_changed(&test_file, &payload).unwrap());
        let payload2 = serde_json::json!({"ok": true, "mode": "advanced"});
        assert!(crate::crypto_gen::write_json_if_changed(&test_file, &payload2).unwrap());
        let _ = std::fs::remove_dir_all(&tmp_dir);

        // Migration test via temp store JSON lacking ipv6_mode with ui_mode="basic"
        let mig_dir = std::env::temp_dir().join(format!("tachyon_mig_{}", unix_now_secs()));
        let _ = std::fs::create_dir_all(&mig_dir);
        let store_path = mig_dir.join("store.json");
        let mut legacy_doc = serde_json::to_value(RouterStoreData::default()).unwrap();
        if let Some(st) = legacy_doc
            .get_mut("settings")
            .and_then(|v| v.as_object_mut())
        {
            st.remove("ipv6_mode");
            st.insert("ui_mode".to_string(), serde_json::json!("basic"));
            st.insert("enable_ipv6".to_string(), serde_json::json!(true));
            st.insert(
                "cache_path".to_string(),
                serde_json::json!("/usr/share/tachyon-core/cache.db"),
            );
        }
        std::fs::write(&store_path, legacy_doc.to_string()).unwrap();
        let state = AppState::load_or_create(&store_path).expect("load_or_create");
        let loaded = state.data.blocking_read();
        assert_eq!(loaded.settings.ui_mode, "simple");
        assert_eq!(loaded.settings.ipv6_mode, "dual_stack");
        assert_eq!(loaded.settings.cache_path, "/tmp/tachyon-core/cache.db");
        drop(loaded);
        let _ = std::fs::remove_dir_all(&mig_dir);
    }

    #[test]
    fn test_ip_cidr_and_zone_helpers() {
        assert_eq!(parse_ipv4_cidr("192.168.1.55/24"), Some((0xC0A8_0100, 24)));
        assert_eq!(parse_ipv4_cidr("10.0.0.1"), Some((0x0A00_0001, 32)));
        assert_eq!(parse_ipv4_cidr("0.0.0.0/0"), Some((0, 0)));
        assert_eq!(parse_ipv4_cidr("192.168.1.0/33"), None);
        assert_eq!(parse_ipv4_cidr("192.168.1.0/+24"), None);
        assert_eq!(parse_ipv4_cidr(""), None);

        assert!(cidr_v4_overlaps("172.19.0.1/30", "172.19.0.0/24"));
        assert!(cidrs_overlap("198.18.0.0/15", "198.19.0.1/30"));
        assert!(!cidrs_overlap("172.19.0.1/30", "198.18.0.0/15"));
        assert!(cidrs_overlap("fc00::/18", "fc00:100::1/126"));
        assert!(!cidrs_overlap("fc00::/18", "fdfe:dcba:9876::1/126"));
        assert!(!cidrs_overlap("198.18.0.0/15", "fc00::/18"));

        assert_eq!(
            mask_cidr("192.168.1.99/24").as_deref(),
            Some("192.168.1.0/24")
        );
        assert_eq!(mask_cidr("10.0.0.1").as_deref(), Some("10.0.0.1/32"));
        assert_eq!(
            mask_cidr("2001:0db8:0000::1/32").as_deref(),
            Some("2001:db8::/32")
        );
        assert_eq!(mask_cidr("::1/0").as_deref(), Some("::/0"));
        assert_eq!(mask_cidr("not-a-cidr"), None);

        assert!(valid_ip_with_zone("192.168.1.1"));
        assert!(valid_ip_with_zone("2001:db8::1"));
        assert!(valid_ip_with_zone("fe80::1%eth0"));
        assert!(valid_ip_with_zone("fe80::1%br-lan.10"));
        assert!(!valid_ip_with_zone("192.168.1.1%eth0"));
        assert!(!valid_ip_with_zone("fe80::1%"));
        assert!(!valid_ip_with_zone("fe80::1%bad zone"));
        assert!(!valid_ip_with_zone("fe80::1/64"));
        assert!(!valid_ip_with_zone(""));

        assert!(ip_in_cidr("192.168.1.42", "192.168.1.0/24"));
        assert!(!ip_in_cidr("192.168.2.42", "192.168.1.0/24"));
        assert!(ip_in_cidr("2001:db8:abcd::5", "2001:db8::/32"));
        assert!(ip_in_cidr("fe80::1%eth0", "fe80::/10"));
        assert!(!ip_in_cidr("fe80::1%bad zone", "fe80::/10"));
        assert!(!ip_in_cidr("192.168.1.1", "fe80::/10"));
    }

    #[test]
    fn test_guest_mode_defaults_and_uci_import() {
        let gm = GuestModeConfig::default();
        assert_eq!(gm.mode, "selected");
        assert!(gm.isolate_lan);
        assert!(gm.block_router_admin);
        assert!(gm.allow_proxy);

        let deser: GuestModeConfig =
            serde_json::from_str("{}").expect("empty GuestModeConfig JSON");
        assert!(deser.isolate_lan);
        assert!(deser.block_router_admin);
        assert!(deser.allow_proxy);

        let rt_empty: RuntimeIpv6Cache =
            serde_json::from_str("{}").expect("empty RuntimeIpv6Cache JSON");
        assert!(!rt_empty.wan6_available);
        assert!(rt_empty.wan_ipv6.is_empty());
        let rt_partial: RuntimeIpv6Cache = serde_json::from_str(r#"{"wan6_available":true}"#)
            .expect("partial RuntimeIpv6Cache JSON");
        assert!(rt_partial.wan6_available);
        assert_eq!(rt_partial.updated_at, 0);

        let uci_explicit = r#"
config guest_mode 'guest'
    option enabled '1'
    option mode 'all'
    option allow_proxy '0'

config section 'sec_v6'
    option label 'Dual Section'
    option connection_type 'direct'
    option ipv6_support 'auto'
"#;
        let blocks = parse_legacy_uci_blocks(uci_explicit);
        let mut store = RouterStoreData {
            settings: GlobalSettings::default(),
            sections: Vec::new(),
            conditions: Vec::new(),
            outbound_sources: Vec::new(),
            balancers: Vec::new(),
            outbound_groups: Vec::new(),
            servers: Vec::new(),
            profiles: Vec::new(),
            schedules: Vec::new(),
            guest_mode: GuestModeConfig::default(),
            telegram: TgBotConfig::default(),
            device_registry: HashMap::new(),
            applied_migrations: Vec::new(),
        };
        store.import_from_blocks_with_cache(&blocks, Path::new("/nonexistent"));
        assert!(!store.guest_mode.allow_proxy);
        assert_eq!(store.guest_mode.mode, "all");
        assert_eq!(store.sections.len(), 1);
        assert_eq!(store.sections[0].ipv6_support, "auto");

        let uci_omitted = r#"
config guest_mode 'guest'
    option enabled '1'
"#;
        store.import_from_blocks_with_cache(
            &parse_legacy_uci_blocks(uci_omitted),
            Path::new("/nonexistent"),
        );
        assert!(store.guest_mode.allow_proxy);
    }

    #[test]
    fn test_deduplicate_cloned_conditions_and_token_boundaries() {
        let base_cond = TrafficCondition {
            id: "cond_media".to_string(),
            enabled: true,
            name: "Media Rules".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["youtube.com".to_string(), "googlevideo.com".to_string()],
            community_subnets: true,
            ..Default::default()
        };

        let mut conditions = vec![base_cond];
        for i in 1..=50 {
            let id = if i == 1 {
                "cond_media_copy".to_string()
            } else if i <= 15 {
                format!("cond_media_copy_{i}")
            } else if i <= 30 {
                format!("cond_media_{i}")
            } else {
                format!("cond_media_copy{i}")
            };
            conditions.push(TrafficCondition {
                id,
                enabled: true,
                name: format!("Clone {i}"),
                condition_type: "atomic".to_string(),
                user_domains: vec!["googlevideo.com\nyoutube.com".to_string()],
                community_subnets: true,
                ..Default::default()
            });
        }

        // Different ID family but matching "<X> Rules" name and identical signature
        conditions.push(TrafficCondition {
            id: "cond_z_99".to_string(),
            enabled: true,
            name: "Media Rules".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["youtube.com".to_string(), "googlevideo.com".to_string()],
            community_subnets: true,
            ..Default::default()
        });

        // Distinct rule content under clone-like ID must survive
        conditions.push(TrafficCondition {
            id: "cond_media_diff".to_string(),
            enabled: true,
            name: "Media Diff".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["youtube.com".to_string(), "vimeo.com".to_string()],
            community_subnets: true,
            ..Default::default()
        });

        // Token-boundary trap: `cond_media_copy_extra` starts with `cond_media_copy`
        conditions.push(TrafficCondition {
            id: "cond_media_copy_extra".to_string(),
            enabled: true,
            name: "Extra Stream".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["twitch.tv".to_string()],
            community_subnets: true,
            ..Default::default()
        });

        // Disabled variant and differing `community_subnets` must not collapse
        conditions.push(TrafficCondition {
            id: "cond_media_copy_200".to_string(),
            enabled: false,
            name: "Disabled Copy".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["youtube.com".to_string(), "googlevideo.com".to_string()],
            community_subnets: true,
            ..Default::default()
        });
        conditions.push(TrafficCondition {
            id: "cond_media_copy_201".to_string(),
            enabled: true,
            name: "No Subnets".to_string(),
            condition_type: "atomic".to_string(),
            user_domains: vec!["youtube.com".to_string(), "googlevideo.com".to_string()],
            community_subnets: false,
            ..Default::default()
        });

        // Composite conditions must never be collapsed even with identical children
        for comp_id in ["cond_comp_1", "cond_comp_2"] {
            conditions.push(TrafficCondition {
                id: comp_id.to_string(),
                enabled: true,
                name: comp_id.to_string(),
                condition_type: "all".to_string(),
                children: vec![
                    "cond_media_copy_2".to_string(),
                    "cond_media_copy_extra".to_string(),
                    "cond_media_copy".to_string(),
                ],
                expression: "cond_media_copy && (cond_media_copy_extra || !cond_media_copy_2)"
                    .to_string(),
                ..Default::default()
            });
        }

        let mut store = RouterStoreData {
            settings: GlobalSettings::default(),
            sections: vec![RoutingSection {
                id: "sec_1".to_string(),
                enabled: true,
                label: "Main".to_string(),
                connection_type: "proxy".to_string(),
                condition_refs: vec![
                    "cond_media_copy".to_string(),
                    "cond_z_99".to_string(),
                    "cond_media_copy_extra".to_string(),
                ],
                condition_expression: "cond_media_copy || cond_media_copy_extra && !cond_z_99"
                    .to_string(),
                ..Default::default()
            }],
            conditions,
            outbound_sources: Vec::new(),
            balancers: Vec::new(),
            outbound_groups: Vec::new(),
            servers: Vec::new(),
            profiles: Vec::new(),
            schedules: Vec::new(),
            guest_mode: GuestModeConfig::default(),
            telegram: TgBotConfig::default(),
            device_registry: HashMap::new(),
            applied_migrations: Vec::new(),
        };

        let removed = store.deduplicate_cloned_conditions();
        assert_eq!(removed, 51);
        assert!(store.conditions.iter().any(|c| c.id == "cond_media"));
        assert!(store.conditions.iter().any(|c| c.id == "cond_media_diff"));
        assert!(
            store
                .conditions
                .iter()
                .any(|c| c.id == "cond_media_copy_extra")
        );
        assert!(
            store
                .conditions
                .iter()
                .any(|c| c.id == "cond_media_copy_200")
        );
        assert!(
            store
                .conditions
                .iter()
                .any(|c| c.id == "cond_media_copy_201")
        );
        assert!(store.conditions.iter().any(|c| c.id == "cond_comp_1"));
        assert!(store.conditions.iter().any(|c| c.id == "cond_comp_2"));

        assert_eq!(
            store.sections[0].condition_refs,
            vec!["cond_media", "cond_media_copy_extra"]
        );
        assert_eq!(
            store.sections[0].condition_expression,
            "cond_media || cond_media_copy_extra && !cond_media"
        );

        let comp1 = store
            .conditions
            .iter()
            .find(|c| c.id == "cond_comp_1")
            .unwrap();
        assert_eq!(comp1.children, vec!["cond_media", "cond_media_copy_extra"]);
        assert_eq!(
            comp1.expression,
            "cond_media && (cond_media_copy_extra || !cond_media)"
        );

        assert_eq!(store.deduplicate_cloned_conditions(), 0);
    }

    #[test]
    fn test_normalize_tcp_profile_and_ai_lists_1_8_migration() {
        assert_eq!(normalize_tcp_profile("low_latency"), "");
        assert_eq!(normalize_tcp_profile("throughput"), "");
        assert_eq!(normalize_tcp_profile("conservative"), "");
        assert_eq!(normalize_tcp_profile("Windows"), "windows");
        assert_eq!(normalize_tcp_profile("default"), "default");

        let mut store = RouterStoreData {
            sections: vec![
                RoutingSection {
                    id: "sec_proxy".to_string(),
                    enabled: true,
                    action: "proxy".to_string(),
                    condition_refs: vec!["cond_a".to_string(), "cond_b".to_string()],
                    ..Default::default()
                },
                RoutingSection {
                    id: "sec_direct".to_string(),
                    enabled: true,
                    action: "direct".to_string(),
                    condition_refs: vec!["cond_direct".to_string()],
                    ..Default::default()
                },
            ],
            conditions: vec![
                TrafficCondition {
                    id: "cond_a".to_string(),
                    enabled: true,
                    condition_type: "atomic".to_string(),
                    community_lists: vec!["openai".to_string(), "anthropic".to_string()],
                    ..Default::default()
                },
                TrafficCondition {
                    id: "cond_b".to_string(),
                    enabled: true,
                    condition_type: "atomic".to_string(),
                    community_lists: vec!["ai_all".to_string(), "google_ai".to_string()],
                    ..Default::default()
                },
                TrafficCondition {
                    id: "cond_direct".to_string(),
                    enabled: true,
                    condition_type: "atomic".to_string(),
                    community_lists: vec!["openai".to_string(), "google_ai".to_string()],
                    ..Default::default()
                },
            ],
            applied_migrations: Vec::new(),
            ..Default::default()
        };

        assert!(store.apply_ai_lists_1_8());
        let cond_a = store.conditions.iter().find(|c| c.id == "cond_a").unwrap();
        assert!(cond_a.community_lists.iter().any(|x| x == "qwen"));
        assert!(cond_a.community_lists.iter().any(|x| x == "kimi"));

        let cond_b = store.conditions.iter().find(|c| c.id == "cond_b").unwrap();
        assert!(
            cond_b
                .community_lists
                .iter()
                .any(|x| x == "google_services")
        );

        // Non-proxy condition must remain untouched
        let cond_direct = store
            .conditions
            .iter()
            .find(|c| c.id == "cond_direct")
            .unwrap();
        assert!(!cond_direct.community_lists.iter().any(|x| x == "qwen"));
        assert!(!cond_direct.community_lists.iter().any(|x| x == "kimi"));

        // Repeat call must be idempotent
        assert!(!store.apply_ai_lists_1_8());

        // Split case: ai_all and google_ai in separate proxy-only conditions
        let mut split_store = RouterStoreData {
            sections: vec![RoutingSection {
                id: "sec_proxy".to_string(),
                enabled: true,
                action: "proxy".to_string(),
                condition_refs: vec!["c_all".to_string(), "c_google".to_string()],
                ..Default::default()
            }],
            conditions: vec![
                TrafficCondition {
                    id: "c_all".to_string(),
                    enabled: true,
                    condition_type: "atomic".to_string(),
                    community_lists: vec!["ai_all".to_string()],
                    ..Default::default()
                },
                TrafficCondition {
                    id: "c_google".to_string(),
                    enabled: true,
                    condition_type: "atomic".to_string(),
                    community_lists: vec!["google_ai".to_string()],
                    ..Default::default()
                },
            ],
            applied_migrations: Vec::new(),
            ..Default::default()
        };
        assert!(split_store.apply_ai_lists_1_8());
        let c_google = split_store
            .conditions
            .iter()
            .find(|c| c.id == "c_google")
            .unwrap();
        assert!(
            c_google
                .community_lists
                .iter()
                .any(|x| x == "google_services")
        );
    }

    #[test]
    fn test_portable_and_fallback_atomic_u64() {
        let p = PortableAtomicU64::default();
        assert_eq!(p.load(Ordering::Acquire), 0);
        p.store(42, Ordering::Release);
        assert_eq!(p.load(Ordering::Acquire), 42);
        assert_eq!(p.fetch_add(8, Ordering::AcqRel), 42);
        assert_eq!(p.load(Ordering::Acquire), 50);

        let fb = FallbackAtomicU64::new(u64::MAX - 1);
        assert_eq!(fb.load(Ordering::Acquire), u64::MAX - 1);
        assert_eq!(fb.fetch_add(1, Ordering::AcqRel), u64::MAX - 1);
        assert_eq!(fb.load(Ordering::Acquire), u64::MAX);
        assert_eq!(fb.fetch_add(2, Ordering::AcqRel), u64::MAX);
        assert_eq!(fb.load(Ordering::Acquire), 1);
        fb.store(99, Ordering::Release);
        assert_eq!(fb.load(Ordering::Acquire), 99);
    }

    #[test]
    fn test_legacy_uci_import_marks_migration_and_does_not_overwrite_edits() {
        let mut seeded = RouterStoreData {
            settings: GlobalSettings::default(),
            ..Default::default()
        };
        seeded.sections.clear();
        seeded.outbound_sources.clear();
        seeded.conditions.clear();
        seeded.balancers.clear();
        seeded.seed_defaults();
        assert!(seeded.is_seeded_default_store());

        // Deleting default entries or editing user 1-section setup must not look like unedited seed
        let mut user_single_section = seeded.clone();
        user_single_section.sections[0].id = "custom_main".to_string();
        assert!(!user_single_section.is_seeded_default_store());

        let tmp = std::env::temp_dir().join(format!(
            "tachyon_legacy_import_marker_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let uci_path = tmp.join("tachyon.uci");
        let missing_primary = tmp.join("missing.uci");

        std::fs::write(
            &uci_path,
            r#"
config settings 'settings'
        option proxy_mode 'tproxy'
        option show_tab_sections '0'
        option show_tab_servers '0'
        option show_tab_profiles '0'

config condition 'cond_refilter'
        option name 'Refilter Subnets'
        list rule_set_with_subnets 'refilter'

config section 'sec_user'
        option label 'User Proxy'
        option action 'proxy'
        list rule_set_with_subnets 'telegram'
"#,
        )
        .unwrap();

        let mut store = RouterStoreData {
            settings: GlobalSettings::default(),
            ..Default::default()
        };
        let imported = store.import_legacy_router_files_from(&missing_primary, &uci_path);
        assert!(imported >= 3);
        assert!(
            store
                .applied_migrations
                .iter()
                .any(|m| m == LEGACY_UCI_IMPORTED_MIGRATION),
            "legacy import must set {LEGACY_UCI_IMPORTED_MIGRATION} marker"
        );
        assert!(!store.settings.show_tab_section);
        assert!(!store.settings.show_tab_server);
        assert!(!store.settings.show_tab_profile);
        let cond = store
            .conditions
            .iter()
            .find(|c| c.id == "cond_refilter")
            .unwrap();
        assert_eq!(cond.rule_set_with_subnets, vec!["refilter".to_string()]);
        let sec = store.sections.iter().find(|s| s.id == "sec_user").unwrap();
        assert_eq!(sec.rule_set_with_subnets, vec!["telegram".to_string()]);
        assert!(!store.is_seeded_default_store());

        // Subsequent Web UI JSON sections sync must preserve the legacy import marker
        let mut json_sec = serde_json::Map::new();
        json_sec.insert(
            "settings".to_string(),
            serde_json::json!({
                ".type": "settings",
                ".name": "settings",
                ".index": 0,
                "proxy_mode": "tun"
            }),
        );
        store.import_from_json_sections(&json_sec);
        assert!(
            store
                .applied_migrations
                .iter()
                .any(|m| m == LEGACY_UCI_IMPORTED_MIGRATION)
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
