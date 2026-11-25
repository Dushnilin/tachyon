//! Zero-dependency host telemetry, PID-recycling-safe process identity (`pid + starttime + boot_id`),
//! and LAN neighbor / DHCP lease discovery for OpenWrt routers.

use std::collections::HashMap;
use std::net::UdpSocket;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::platform;
use crate::platform_keenetic::{self, KeeneticHostEntry, KeeneticVersionInfo};

type KeeneticVersionCacheEntry = (Instant, Option<KeeneticVersionInfo>);

static DAEMON_START_INSTANT: OnceLock<Instant> = OnceLock::new();
static KEENETIC_VERSION_CACHE: OnceLock<Mutex<Option<KeeneticVersionCacheEntry>>> = OnceLock::new();
static KEENETIC_VERSION_INFLIGHT: AtomicBool = AtomicBool::new(false);
static KEENETIC_HOTSPOT_CACHE: OnceLock<Mutex<(Option<Instant>, Vec<KeeneticHostEntry>)>> =
    OnceLock::new();
static KEENETIC_HOTSPOT_INFLIGHT: AtomicBool = AtomicBool::new(false);

const KEENETIC_VERSION_CACHE_TTL: Duration = Duration::from_secs(300);
const KEENETIC_HOTSPOT_CACHE_TTL: Duration = Duration::from_secs(15);

pub fn init_daemon_start_time() {
    let _ = DAEMON_START_INSTANT.get_or_init(Instant::now);
}

pub fn daemon_uptime_secs() -> u64 {
    DAEMON_START_INSTANT
        .get_or_init(Instant::now)
        .elapsed()
        .as_secs()
        .max(1)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DnsmasqStatus {
    pub running: bool,
    pub pid: u32,
    pub memory_rss_mb: u64,
    pub uptime_secs: u64,
    pub cache_size: u32,
    pub local_cache_enabled: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HostSysInfo {
    pub os: String,
    pub arch: String,
    pub hostname: String,
    pub mem_total_bytes: u64,
    pub mem_used_bytes: u64,
    pub memory_total_mb: u64,
    pub memory_used_mb: u64,
    pub zram_total_bytes: u64,
    pub zram_used_bytes: u64,
    pub cpu_temp_c: f32,
    pub panel_rss_bytes: u64,
    pub host_uptime_secs: u64,
    pub load_avg: String,
    pub router_model: String,
    pub openwrt_release: String,
    #[serde(default)]
    pub platform: String,
    #[serde(default)]
    pub firewall_backend: String,
    #[serde(default)]
    pub storage_kind: String,
    #[serde(default)]
    pub storage_fs: String,
    #[serde(default)]
    pub storage_mount: String,
    #[serde(default)]
    pub runtime_tmpfs_ok: bool,
}

/// Triple process identity (`pid` + `/proc/<pid>/stat` `starttime` + `/proc/sys/kernel/random/boot_id`)
/// matching `core/process.uc` to prevent PID recycling false positives.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub starttime_ticks: u64,
    pub boot_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LanDevice {
    pub ip: String,
    pub mac: String,
    pub hostname: String,
    #[serde(default)]
    pub custom_name: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub vendor: String,
    pub interface: String,
    pub reachable: bool,
    pub lease_expires: i64,
    #[serde(default)]
    pub static_lease: bool,
    #[serde(default)]
    pub routed_section: String,
    #[serde(default)]
    pub upload_bytes: u64,
    #[serde(default)]
    pub download_bytes: u64,
    #[serde(default)]
    pub proxied_upload: u64,
    #[serde(default)]
    pub proxied_download: u64,
    #[serde(default)]
    pub direct_upload: u64,
    #[serde(default)]
    pub direct_download: u64,
    #[serde(default)]
    pub upload_bps: u64,
    #[serde(default)]
    pub download_bps: u64,
    #[serde(default)]
    pub limit_up_bps: u64,
    #[serde(default)]
    pub limit_down_bps: u64,
    #[serde(default)]
    pub active_sessions: usize,
}

pub fn read_boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "host-boot-0".to_string())
}

/// Read `/proc/<pid>/stat` field 22 (`starttime` after the last `)`) on Linux.
pub fn read_pid_starttime(pid: u32) -> Option<u64> {
    if pid == 0 {
        return None;
    }
    #[cfg(target_os = "linux")]
    {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let close_paren = stat.rfind(')')?;
        let after_comm = stat.get(close_paren + 1..)?.trim();
        // Field 3 is state (index 0 in `after_comm`), field 22 is starttime (index 19 in `after_comm`).
        after_comm
            .split_whitespace()
            .nth(19)
            .and_then(|v| v.parse::<u64>().ok())
    }
    #[cfg(not(target_os = "linux"))]
    {
        Some(pid as u64)
    }
}

pub fn capture_process_identity(pid: u32) -> Option<ProcessIdentity> {
    let starttime_ticks = read_pid_starttime(pid)?;
    Some(ProcessIdentity {
        pid,
        starttime_ticks,
        boot_id: read_boot_id(),
    })
}

pub fn verify_process_identity(id: &ProcessIdentity) -> bool {
    if id.pid == 0 {
        return false;
    }
    if id.boot_id != read_boot_id() {
        return false;
    }
    match read_pid_starttime(id.pid) {
        Some(actual) => actual == id.starttime_ticks,
        None => false,
    }
}

/// Find a running process by `/proc/<pid>/comm` name on Linux, returning `(pid, uptime_secs)`.
pub fn find_running_process_by_name(comm_name: &str) -> Option<(u32, u64)> {
    #[cfg(target_os = "linux")]
    {
        let host_uptime = std::fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
            .unwrap_or(0.0) as u64;
        let entries = std::fs::read_dir("/proc").ok()?;
        let self_pid = std::process::id();
        for entry in entries.flatten() {
            let fname = entry.file_name();
            let Some(pid_str) = fname.to_str() else {
                continue;
            };
            let Ok(pid) = pid_str.parse::<u32>() else {
                continue;
            };
            if pid == self_pid {
                continue;
            }
            if let Ok(comm) = std::fs::read_to_string(format!("/proc/{pid}/comm"))
                && comm.trim() == comm_name
            {
                let start_ticks = read_pid_starttime(pid).unwrap_or(0);
                let proc_uptime = host_uptime.saturating_sub(start_ticks / 100);
                return Some((pid, proc_uptime));
            }
        }
        None
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = comm_name;
        None
    }
}

/// Check whether `dir` is backed by RAM `tmpfs` (never `/opt` USB external storage).
pub fn is_runtime_dir_on_tmpfs(dir: &Path) -> bool {
    #[cfg(target_os = "linux")]
    {
        let s = dir.to_string_lossy();
        if s == "/opt" || s.starts_with("/opt/") {
            return false;
        }
        platform::detect_storage_info(dir).kind == platform::StorageKind::TmpfsOnly
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = dir;
        true
    }
}

/// Refresh cached Keenetic RCI version info asynchronously without blocking the Tokio runtime.
pub async fn refresh_keenetic_version_cache() -> Option<KeeneticVersionInfo> {
    if !platform::is_keenetic() {
        return None;
    }
    let fetched = platform_keenetic::fetch_rci_version().await;
    let lock = KEENETIC_VERSION_CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = lock.lock() {
        *guard = Some((Instant::now(), fetched.clone()));
    }
    fetched
}

fn read_cached_keenetic_version() -> Option<KeeneticVersionInfo> {
    if !platform::is_keenetic() {
        return None;
    }
    let lock = KEENETIC_VERSION_CACHE.get_or_init(|| Mutex::new(None));
    let (cached, needs_refresh) = match lock.lock() {
        Ok(guard) => match guard.as_ref() {
            Some((at, info)) => (
                info.clone(),
                at.elapsed() >= KEENETIC_VERSION_CACHE_TTL && info.is_none(),
            ),
            None => (None, true),
        },
        Err(_) => (None, false),
    };
    if needs_refresh
        && let Ok(handle) = tokio::runtime::Handle::try_current()
        && KEENETIC_VERSION_INFLIGHT
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
    {
        handle.spawn(async {
            let _ = refresh_keenetic_version_cache().await;
            KEENETIC_VERSION_INFLIGHT.store(false, Ordering::Release);
        });
    }
    cached
}

/// Async system info collection that refreshes Keenetic RCI version metadata before reading host telemetry.
#[allow(dead_code)]
pub async fn collect_system_info() -> HostSysInfo {
    if platform::is_keenetic() {
        let needs_fetch = {
            let lock = KEENETIC_VERSION_CACHE.get_or_init(|| Mutex::new(None));
            lock.lock().ok().is_none_or(|g| {
                g.as_ref().is_none_or(|(at, info)| {
                    info.is_none() && at.elapsed() >= KEENETIC_VERSION_CACHE_TTL
                })
            })
        };
        if needs_fetch {
            let _ = refresh_keenetic_version_cache().await;
        }
    }
    collect_host_info()
}

pub fn collect_host_info() -> HostSysInfo {
    let model = read_router_model();
    let hostname = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| model.clone());
    let plat = platform::detect_platform();
    let fw_kind = platform::firewall_kind();
    let storage = platform::detect_storage_info(&platform::paths().data_dir);
    let runtime_tmpfs_ok = is_runtime_dir_on_tmpfs(&crate::store::runtime_state_dir());

    #[allow(unused_mut)]
    let mut info = HostSysInfo {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        hostname,
        mem_total_bytes: 0,
        mem_used_bytes: 0,
        memory_total_mb: 0,
        memory_used_mb: 0,
        zram_total_bytes: 0,
        zram_used_bytes: 0,
        cpu_temp_c: 0.0,
        panel_rss_bytes: 0,
        host_uptime_secs: 0,
        load_avg: "0.00 / 0.00 / 0.00".to_string(),
        router_model: model,
        openwrt_release: read_os_release(),
        platform: plat.as_str().to_string(),
        firewall_backend: fw_kind.as_str().to_string(),
        storage_kind: storage.kind.as_str().to_string(),
        storage_fs: storage.fs_type,
        storage_mount: storage.mount_point,
        runtime_tmpfs_ok,
    };

    #[cfg(target_os = "linux")]
    {
        if let Ok(meminfo) = std::fs::read_to_string("/proc/meminfo") {
            let mut total_kb = 0u64;
            let mut avail_kb = 0u64;
            let mut swap_total_kb = 0u64;
            let mut swap_free_kb = 0u64;
            for line in meminfo.lines() {
                if let Some(rest) = line.strip_prefix("MemTotal:") {
                    total_kb = parse_kb(rest);
                } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
                    avail_kb = parse_kb(rest);
                } else if let Some(rest) = line.strip_prefix("SwapTotal:") {
                    swap_total_kb = parse_kb(rest);
                } else if let Some(rest) = line.strip_prefix("SwapFree:") {
                    swap_free_kb = parse_kb(rest);
                }
            }
            info.mem_total_bytes = total_kb * 1024;
            info.mem_used_bytes = total_kb.saturating_sub(avail_kb) * 1024;
            info.memory_total_mb = info.mem_total_bytes / 1_048_576;
            info.memory_used_mb = info.mem_used_bytes / 1_048_576;
            info.zram_total_bytes = swap_total_kb * 1024;
            info.zram_used_bytes = swap_total_kb.saturating_sub(swap_free_kb) * 1024;
        }
        for tz in [
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/hwmon/hwmon0/temp1_input",
        ] {
            if let Ok(raw_t) = std::fs::read_to_string(tz)
                && let Ok(v) = raw_t.trim().parse::<f32>()
            {
                info.cpu_temp_c = if v > 200.0 { v / 1000.0 } else { v };
                break;
            }
        }
        if let Ok(uptime_str) = std::fs::read_to_string("/proc/uptime")
            && let Some(first) = uptime_str.split_whitespace().next()
            && let Ok(secs) = first.parse::<f64>()
        {
            info.host_uptime_secs = secs as u64;
        }
        if let Ok(loadavg) = std::fs::read_to_string("/proc/loadavg") {
            let parts: Vec<&str> = loadavg.split_whitespace().take(3).collect();
            if parts.len() == 3 {
                info.load_avg = format!("{} / {} / {}", parts[0], parts[1], parts[2]);
            }
        }
        if let Some(rss) = read_proc_status_rss_bytes("/proc/self/status") {
            info.panel_rss_bytes = rss;
        } else if let Ok(statm) = std::fs::read_to_string("/proc/self/statm")
            && let Some(res_pages) = statm.split_whitespace().nth(1)
            && let Ok(pages) = res_pages.parse::<u64>()
        {
            info.panel_rss_bytes = pages * 4096;
        }
    }

    #[cfg(not(target_os = "linux"))]
    {
        info.mem_total_bytes = 512 * 1_048_576;
        info.mem_used_bytes = 64 * 1_048_576;
        info.memory_total_mb = 512;
        info.memory_used_mb = 64;
        info.host_uptime_secs = daemon_uptime_secs();
    }

    info
}

fn format_keenetic_model(ver: &KeeneticVersionInfo) -> Option<String> {
    let raw = ver.model.trim();
    if raw.is_empty() {
        return None;
    }
    if raw.to_ascii_lowercase().contains("keenetic") {
        Some(raw.to_string())
    } else {
        Some(format!("Keenetic {raw}"))
    }
}

fn format_keenetic_release(ver: &KeeneticVersionInfo) -> Option<String> {
    let rel = if !ver.release.trim().is_empty() {
        ver.release.trim()
    } else {
        ver.ndms.trim()
    };
    if rel.is_empty() {
        return None;
    }
    let lower = rel.to_ascii_lowercase();
    if lower.contains("keenetic") || lower.contains("ndms") {
        Some(rel.to_string())
    } else {
        Some(format!("KeeneticOS {rel}"))
    }
}

fn parse_entware_release(raw: &str) -> Option<String> {
    for prefix in ["DISTRIB_DESCRIPTION=", "PRETTY_NAME="] {
        for line in raw.lines() {
            if let Some(rest) = line.trim().strip_prefix(prefix) {
                let cleaned = rest.trim().trim_matches(|c| c == '\'' || c == '"').trim();
                if !cleaned.is_empty() {
                    return Some(cleaned.to_string());
                }
            }
        }
    }
    for line in raw.lines() {
        let trimmed = line.trim();
        if !trimmed.is_empty() && !trimmed.starts_with('#') {
            return Some(trimmed.to_string());
        }
    }
    None
}

fn read_router_model() -> String {
    if let Some(ver) = read_cached_keenetic_version()
        && let Some(model) = format_keenetic_model(&ver)
    {
        return model;
    }
    for p in ["/tmp/sysinfo/model", "/proc/device-tree/model"] {
        if let Ok(s) = std::fs::read_to_string(p) {
            let trimmed = s.trim_matches(|c: char| c.is_whitespace() || c == '\0');
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
    }
    if platform::is_entware() {
        return platform::detect_platform().display_name().to_string();
    }
    "Generic Router / Host".to_string()
}

pub fn read_os_release() -> String {
    if let Some(ver) = read_cached_keenetic_version()
        && let Some(rel) = format_keenetic_release(&ver)
    {
        return rel;
    }
    if let Ok(raw) = std::fs::read_to_string("/etc/openwrt_release") {
        for line in raw.lines() {
            if let Some(rest) = line.strip_prefix("DISTRIB_DESCRIPTION=") {
                let cleaned = rest.trim_matches(|c| c == '\'' || c == '"').trim();
                if !cleaned.is_empty() {
                    return cleaned.to_string();
                }
            }
        }
    }
    if let Ok(raw) = std::fs::read_to_string("/opt/etc/entware_release")
        && let Some(desc) = parse_entware_release(&raw)
    {
        return desc;
    }
    if let Ok(raw) = std::fs::read_to_string("/etc/os-release") {
        for line in raw.lines() {
            if let Some(rest) = line.trim().strip_prefix("PRETTY_NAME=") {
                let cleaned = rest.trim_matches(|c| c == '\'' || c == '"').trim();
                if !cleaned.is_empty() {
                    return cleaned.to_string();
                }
            }
        }
    }
    format!("{} ({})", std::env::consts::OS, std::env::consts::ARCH)
}

/// Merge Keenetic RCI `/rci/show/ip/hotspot` entries into a base LAN device map/list.
pub fn merge_keenetic_hotspot_devices(
    base: Vec<LanDevice>,
    rci_hosts: &[KeeneticHostEntry],
) -> Vec<LanDevice> {
    if rci_hosts.is_empty() {
        return base;
    }
    let default_iface = platform::detect_default_lan_iface();
    let mut by_ip: HashMap<String, LanDevice> =
        base.into_iter().map(|d| (d.ip.clone(), d)).collect();
    for h in rci_hosts {
        let ip = h.ip.trim();
        if ip.is_empty() {
            continue;
        }
        let mac = h.mac.trim().to_ascii_uppercase();
        let vendor = if mac.is_empty() {
            String::new()
        } else {
            lookup_mac_vendor(&mac)
        };
        let iface = if h.interface.trim().is_empty() {
            default_iface.clone()
        } else {
            h.interface.trim().to_string()
        };
        let name = h.name.trim().to_string();
        by_ip
            .entry(ip.to_string())
            .and_modify(|d| {
                if d.mac.is_empty() && !mac.is_empty() {
                    d.mac = mac.clone();
                }
                if d.vendor.is_empty() && !vendor.is_empty() {
                    d.vendor = vendor.clone();
                }
                if d.hostname.is_empty() && !name.is_empty() {
                    d.hostname = name.clone();
                }
                if d.interface.is_empty() && !iface.is_empty() {
                    d.interface = iface.clone();
                }
                if h.active {
                    d.reachable = true;
                }
            })
            .or_insert_with(|| LanDevice {
                ip: ip.to_string(),
                mac,
                hostname: name,
                vendor,
                interface: iface,
                reachable: h.active,
                lease_expires: 0,
                ..Default::default()
            });
    }
    let mut list: Vec<LanDevice> = by_ip.into_values().collect();
    list.sort_by(|a, b| a.ip.cmp(&b.ip));
    list
}

fn read_cached_keenetic_hotspot_devices() -> Vec<KeeneticHostEntry> {
    if !platform::is_keenetic() {
        return Vec::new();
    }
    let lock = KEENETIC_HOTSPOT_CACHE.get_or_init(|| Mutex::new((None, Vec::new())));
    let (cached, needs_refresh) = match lock.lock() {
        Ok(guard) => match guard.0 {
            Some(at) => (guard.1.clone(), at.elapsed() >= KEENETIC_HOTSPOT_CACHE_TTL),
            None => (Vec::new(), true),
        },
        Err(_) => (Vec::new(), false),
    };
    if needs_refresh
        && let Ok(handle) = tokio::runtime::Handle::try_current()
        && KEENETIC_HOTSPOT_INFLIGHT
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
    {
        handle.spawn(async {
            let hosts = platform_keenetic::fetch_rci_hotspot_devices().await;
            let lock = KEENETIC_HOTSPOT_CACHE.get_or_init(|| Mutex::new((None, Vec::new())));
            if let Ok(mut guard) = lock.lock() {
                guard.0 = Some(Instant::now());
                guard.1 = hosts;
            }
            KEENETIC_HOTSPOT_INFLIGHT.store(false, Ordering::Release);
        });
    }
    cached
}

/// Async LAN device discovery: on Keenetic fetches `/rci/show/ip/hotspot` and merges with
/// `/tmp/dhcp.leases` and `/proc/net/arp`; on other platforms uses local leases/ARP.
pub async fn discover_lan_devices_async() -> Vec<LanDevice> {
    let base = discover_lan_devices_local();
    if platform::is_keenetic() {
        // Also populate RCI version cache opportunistically if still empty.
        let version_empty = KEENETIC_VERSION_CACHE
            .get_or_init(|| Mutex::new(None))
            .lock()
            .ok()
            .is_none_or(|g| g.is_none());
        if version_empty {
            let _ = refresh_keenetic_version_cache().await;
        }
        let hosts = platform_keenetic::fetch_rci_hotspot_devices().await;
        let lock = KEENETIC_HOTSPOT_CACHE.get_or_init(|| Mutex::new((None, Vec::new())));
        if let Ok(mut guard) = lock.lock() {
            guard.0 = Some(Instant::now());
            guard.1 = hosts.clone();
        }
        return merge_keenetic_hotspot_devices(base, &hosts);
    }
    base
}

fn discover_lan_devices_local() -> Vec<LanDevice> {
    let mut by_ip: HashMap<String, LanDevice> = HashMap::new();
    let default_iface = platform::detect_default_lan_iface();

    if Path::new("/tmp/dhcp.leases").exists()
        && let Ok(leases) = std::fs::read_to_string("/tmp/dhcp.leases")
    {
        for line in leases.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 4 {
                let expires = parts[0].parse::<i64>().unwrap_or(0);
                let mac = parts[1].to_ascii_uppercase();
                let ip = parts[2].to_string();
                let host = if parts[3] == "*" {
                    String::new()
                } else {
                    parts[3].to_string()
                };
                let vendor = lookup_mac_vendor(&mac);
                by_ip.insert(
                    ip.clone(),
                    LanDevice {
                        ip,
                        mac,
                        hostname: host,
                        vendor,
                        interface: default_iface.clone(),
                        reachable: true,
                        lease_expires: expires,
                        ..Default::default()
                    },
                );
            }
        }
    }

    if Path::new("/proc/net/arp").exists()
        && let Ok(arp) = std::fs::read_to_string("/proc/net/arp")
    {
        for line in arp.lines().skip(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 6 {
                let ip = parts[0].to_string();
                let flags = parts[2];
                let mac = parts[3].to_ascii_uppercase();
                let dev = parts[5].to_string();
                if mac == "00:00:00:00:00:00" {
                    continue;
                }
                let reachable = flags != "0x0";
                let vendor = lookup_mac_vendor(&mac);
                by_ip
                    .entry(ip.clone())
                    .and_modify(|d| {
                        if d.mac.is_empty() {
                            d.mac = mac.clone();
                        }
                        if d.vendor.is_empty() {
                            d.vendor = vendor.clone();
                        }
                        d.interface = dev.clone();
                        d.reachable = reachable;
                    })
                    .or_insert(LanDevice {
                        ip,
                        mac,
                        hostname: String::new(),
                        vendor,
                        interface: dev,
                        reachable,
                        lease_expires: 0,
                        ..Default::default()
                    });
            }
        }
    }

    let mut list: Vec<LanDevice> = by_ip.into_values().collect();
    list.sort_by(|a, b| a.ip.cmp(&b.ip));
    list
}

/// Discover LAN devices from `/tmp/dhcp.leases`, `/proc/net/arp`, and cached Keenetic RCI hotspot entries.
pub fn discover_lan_devices() -> Vec<LanDevice> {
    let base = discover_lan_devices_local();
    if platform::is_keenetic() {
        let cached = read_cached_keenetic_hotspot_devices();
        return merge_keenetic_hotspot_devices(base, &cached);
    }
    base
}

/// Fast offline OUI vendor lookup for common LAN devices.
pub fn lookup_mac_vendor(mac: &str) -> String {
    let up = mac.trim().to_ascii_uppercase();
    if up.len() < 8 {
        return String::new();
    }
    let prefix = &up[..8];
    // Locally administered / randomized MAC check (second hex digit is 2, 6, A, E)
    if let Some(second) = up.chars().nth(1)
        && matches!(second, '2' | '6' | 'A' | 'E')
    {
        return "Private MAC".to_string();
    }
    match prefix {
        "00:1A:11" | "3C:5A:B4" | "F4:F5:D8" | "54:60:09" => "Google",
        "00:17:F2" | "28:CF:E9" | "3C:06:30" | "A4:83:E7" | "F0:18:98" | "BC:D0:74" => "Apple",
        "00:16:32" | "24:4B:03" | "50:01:BB" | "78:47:1D" | "BC:14:85" => "Samsung",
        "28:6C:07" | "64:09:80" | "78:11:DC" | "F8:A4:5F" | "AC:F7:F3" => "Xiaomi",
        "00:E0:4C" | "52:54:00" | "70:85:C2" | "18:C0:4D" => "Realtek / PC",
        "00:1B:21" | "3C:97:0E" | "8C:8D:28" | "A4:34:D9" | "F8:63:3F" => "Intel",
        "14:CC:20" | "50:C7:BF" | "C0:25:E9" | "E8:DE:27" | "B0:BE:76" => "TP-Link",
        "50:FF:20" | "E4:18:6B" => "Keenetic",
        "4C:5E:0C" | "64:D1:54" | "B8:69:F4" | "DC:2C:6E" => "MikroTik",
        "04:D9:F5" | "10:7B:44" | "2C:56:DC" | "F0:2F:74" => "ASUS",
        "00:13:A9" | "00:1D:0D" | "70:9E:29" | "F8:46:1C" => "Sony PlayStation",
        "00:50:F2" | "28:18:78" | "7C:ED:8D" | "98:5F:D3" => "Microsoft / Xbox",
        "B8:27:EB" | "DC:A6:32" | "E4:5F:01" | "2C:CF:67" => "Raspberry Pi",
        "00:18:82" | "28:31:52" | "48:46:FB" | "88:28:B3" => "Huawei",
        _ => "LAN Client",
    }
    .to_string()
}

/// Read the Resident Set Size (RSS / Working Set) in bytes for a given process PID.
pub fn process_rss_bytes(pid: u32) -> u64 {
    if pid == 0 {
        return 0;
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(rss) = read_proc_status_rss_bytes(&format!("/proc/{pid}/status")) {
            return rss;
        }
        if let Ok(statm) = std::fs::read_to_string(format!("/proc/{pid}/statm"))
            && let Some(res_pages) = statm.split_whitespace().nth(1)
            && let Ok(pages) = res_pages.parse::<u64>()
        {
            return pages * 4096;
        }
        0
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        0
    }
}

#[cfg(target_os = "linux")]
fn read_proc_status_rss_bytes(status_path: &str) -> Option<u64> {
    let raw = std::fs::read_to_string(status_path).ok()?;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            let kb = parse_kb(rest);
            return Some(kb * 1024);
        }
    }
    None
}

#[cfg(target_os = "linux")]
#[derive(Default)]
struct LiteBusySampleState {
    prev_total: u64,
    prev_idle: u64,
    cache_at: Option<Instant>,
    cache_val: bool,
}

#[allow(dead_code)]
fn count_proc_stat_cpus_and_totals(stat_raw: &str) -> (usize, Option<(u64, u64)>) {
    let mut ncpu = 0usize;
    let mut agg: Option<(u64, u64)> = None;
    for (idx, line) in stat_raw.lines().enumerate() {
        let trimmed = line.trim();
        if idx == 0 && trimmed.starts_with("cpu ") {
            let vals: Vec<u64> = trimmed
                .split_whitespace()
                .skip(1)
                .filter_map(|v| v.parse::<u64>().ok())
                .collect();
            if vals.len() >= 4 {
                let idle = vals[3].saturating_add(vals.get(4).copied().unwrap_or(0));
                let total: u64 = vals.iter().copied().sum();
                agg = Some((total, idle));
            }
        } else if let Some(rest) = trimmed.strip_prefix("cpu") {
            let digits_end = rest
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(rest.len());
            if digits_end > 0 {
                ncpu += 1;
            }
        }
    }
    (ncpu.max(1), agg)
}

#[allow(dead_code)]
fn evaluate_smp_load_busy(loadavg_raw: &str, ncpu: usize) -> bool {
    let Some(first) = loadavg_raw.split_whitespace().next() else {
        return false;
    };
    let Ok(load1) = first.parse::<f64>() else {
        return false;
    };
    load1 >= 0.85 * (ncpu.max(1) as f64)
}

/// SMP-aware data-plane saturation detector (`Lite` mode) with a 5-second cache.
/// Never sleeps on the caller thread: evaluates `/proc/stat` delta (>= 75% CPU) or
/// `/proc/loadavg` 1m load (`>= 0.85 * ncpu`).
pub fn is_lite_data_plane_busy(lite_mode: bool) -> bool {
    if !lite_mode {
        return false;
    }
    #[cfg(target_os = "linux")]
    {
        static BUSY_STATE: OnceLock<Mutex<LiteBusySampleState>> = OnceLock::new();
        let lock = BUSY_STATE.get_or_init(|| Mutex::new(LiteBusySampleState::default()));
        let Ok(mut guard) = lock.lock() else {
            return false;
        };
        if let Some(at) = guard.cache_at
            && at.elapsed().as_secs() < 5
        {
            return guard.cache_val;
        }

        let mut busy = false;
        let mut ncpu = 1usize;
        if let Ok(stat_raw) = std::fs::read_to_string("/proc/stat") {
            let (cpus, agg) = count_proc_stat_cpus_and_totals(&stat_raw);
            ncpu = cpus;
            if let Some((total, idle)) = agg {
                let prev_total = guard.prev_total;
                let prev_idle = guard.prev_idle;
                let d_total = total.saturating_sub(prev_total);
                if prev_total == 0 || d_total >= 25 {
                    guard.prev_total = total;
                    guard.prev_idle = idle;
                }
                if prev_total > 0 && d_total >= 25 {
                    let d_idle = idle.saturating_sub(prev_idle);
                    let busy_pct = ((d_total.saturating_sub(d_idle)) * 100) / d_total;
                    if busy_pct >= 75 {
                        busy = true;
                    }
                }
            }
        }
        if !busy && let Ok(load_raw) = std::fs::read_to_string("/proc/loadavg") {
            busy = evaluate_smp_load_busy(&load_raw, ncpu);
        }
        guard.cache_at = Some(Instant::now());
        guard.cache_val = busy;
        busy
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}

/// Sample real system-wide CPU busy percentage (`0..=100`) from `/proc/stat` jiffies delta.
pub fn sample_cpu_load_percent() -> u8 {
    #[cfg(target_os = "linux")]
    {
        static PREV_CPU: OnceLock<Mutex<(u64, u64, u8)>> = OnceLock::new();
        let lock = PREV_CPU.get_or_init(|| Mutex::new((0, 0, 1)));
        let Ok(stat) = std::fs::read_to_string("/proc/stat") else {
            return 0;
        };
        let Some(cpu_line) = stat.lines().find(|l| l.starts_with("cpu ")) else {
            return 0;
        };
        let vals: Vec<u64> = cpu_line
            .split_whitespace()
            .skip(1)
            .filter_map(|v| v.parse::<u64>().ok())
            .collect();
        if vals.len() < 4 {
            return 0;
        }
        let idle = vals[3].saturating_add(vals.get(4).copied().unwrap_or(0));
        let total: u64 = vals.iter().copied().sum();
        let Ok(mut guard) = lock.lock() else {
            return 0;
        };
        let (prev_idle, prev_total, prev_pct) = *guard;
        if prev_total == 0 {
            *guard = (idle, total, prev_pct);
            return prev_pct;
        }
        let d_total = total.saturating_sub(prev_total);
        if d_total < 20 {
            return prev_pct;
        }
        let d_idle = idle.saturating_sub(prev_idle);
        let busy = d_total.saturating_sub(d_idle);
        let pct = ((busy * 100 + (d_total / 2)) / d_total).min(100) as u8;
        *guard = (idle, total, pct);
        pct
    }
    #[cfg(not(target_os = "linux"))]
    {
        0
    }
}

/// Collect real `dnsmasq` worker PID, RSS, uptime, and configured cache size on OpenWrt.
pub fn collect_dnsmasq_status() -> DnsmasqStatus {
    let mut cache_size = 1000u32;
    for dir in ["/var/etc", "/tmp/dnsmasq.d"] {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                let fname = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if (fname.starts_with("dnsmasq.conf") || fname.ends_with(".conf"))
                    && let Ok(raw) = std::fs::read_to_string(&path)
                {
                    for line in raw.lines() {
                        let t = line.trim();
                        if let Some(val) = t.strip_prefix("cache-size=")
                            && let Ok(parsed) = val.trim().parse::<u32>()
                        {
                            cache_size = parsed;
                        }
                    }
                }
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        let host_uptime = std::fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok())
            .unwrap_or(0.0) as u64;
        let mut best_pid = 0u32;
        let mut best_rss = 0u64;
        let mut best_uptime = 0u64;

        if let Ok(entries) = std::fs::read_dir("/proc") {
            for entry in entries.flatten() {
                let Some(pid_str) = entry.file_name().to_str().map(String::from) else {
                    continue;
                };
                let Ok(pid) = pid_str.parse::<u32>() else {
                    continue;
                };
                let Ok(comm) = std::fs::read_to_string(format!("/proc/{pid}/comm")) else {
                    continue;
                };
                if comm.trim() != "dnsmasq" {
                    continue;
                }
                // Skip ujail wrapper if its cmdline starts with `/sbin/ujail`
                if let Ok(cmdline) = std::fs::read(format!("/proc/{pid}/cmdline"))
                    && let Some(arg0) = cmdline.split(|b| *b == 0).next()
                {
                    let arg0_s = String::from_utf8_lossy(arg0);
                    if arg0_s.contains("ujail") {
                        continue;
                    }
                }
                let rss = process_rss_bytes(pid);
                let start_ticks = read_pid_starttime(pid).unwrap_or(0);
                let up = host_uptime.saturating_sub(start_ticks / 100).max(1);
                if best_pid == 0 || rss > best_rss {
                    best_pid = pid;
                    best_rss = rss;
                    best_uptime = up;
                }
            }
        }

        if best_pid > 0 {
            return DnsmasqStatus {
                running: true,
                pid: best_pid,
                memory_rss_mb: ((best_rss + 512 * 1024) / (1024 * 1024)).max(1),
                uptime_secs: best_uptime,
                cache_size,
                local_cache_enabled: cache_size > 0,
            };
        }
    }

    DnsmasqStatus {
        running: false,
        pid: 0,
        memory_rss_mb: 0,
        uptime_secs: 0,
        cache_size,
        local_cache_enabled: cache_size > 0,
    }
}

/// Count open file descriptors for `pid` (or current process when `None`).
pub fn count_open_fds(pid: Option<u32>) -> usize {
    #[cfg(target_os = "linux")]
    {
        let fd_dir = match pid {
            Some(0) => return 0,
            Some(p) => format!("/proc/{p}/fd"),
            None => "/proc/self/fd".to_string(),
        };
        std::fs::read_dir(fd_dir).map(|it| it.count()).unwrap_or(0)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        16
    }
}

/// Detect router LAN IPv4 and primary outbound WAN IPv4 without process forks.
pub fn detect_router_ips() -> (String, String) {
    let wan_ip = UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("1.1.1.1:80")?;
            s.local_addr()
        })
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|_| "192.168.1.1".to_string());

    let mut lan_ip = String::new();
    if let Ok(net_cfg) = std::fs::read_to_string("/etc/config/network") {
        let mut in_lan = false;
        for line in net_cfg.lines() {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("config interface") {
                let name = rest.trim().trim_matches(|c| c == '\'' || c == '"');
                in_lan = name == "lan";
            } else if in_lan && let Some(rest) = t.strip_prefix("option ipaddr") {
                let val = rest.trim().trim_matches(|c| c == '\'' || c == '"');
                if !val.is_empty() {
                    lan_ip = val.to_string();
                    break;
                }
            }
        }
    }
    if lan_ip.is_empty() {
        lan_ip = wan_ip.clone();
    }
    (lan_ip, wan_ip)
}

#[cfg(target_os = "linux")]
fn parse_kb(s: &str) -> u64 {
    s.split_whitespace()
        .next()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0)
}

/// Detect active non-loopback, non-tunnel LAN and WAN global IPv6 addresses plus
/// candidate routed IPv6 prefixes (`/64` derived from global WAN/LAN addresses).
pub fn detect_router_ipv6_ips() -> (String, String, Vec<String>) {
    let cache = crate::store::probe_wan6_runtime_state();
    let lan_v6 = cache.lan_ipv6.first().cloned().unwrap_or_default();
    let wan_v6 = cache.wan_ipv6.first().cloned().unwrap_or_default();
    (lan_v6, wan_v6, cache.wan6_prefixes)
}

/// Read the system hostname with fallback to detected `HostSysInfo`.
pub fn read_router_hostname() -> String {
    if let Ok(raw) = std::fs::read_to_string("/proc/sys/kernel/hostname") {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    collect_host_info().hostname
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_evaluate_smp_load_busy_single_and_quad_core() {
        assert!(!evaluate_smp_load_busy("0.80 0.50 0.30 1/120 123", 1));
        assert!(evaluate_smp_load_busy("0.85 0.50 0.30 1/120 123", 1));
        assert!(!evaluate_smp_load_busy("2.50 1.20 0.90 2/240 456", 4));
        assert!(evaluate_smp_load_busy("3.40 2.00 1.00 4/240 456", 4));

        let stat_sample = "\
cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0
";
        let (cpus, agg) = count_proc_stat_cpus_and_totals(stat_sample);
        assert_eq!(cpus, 2);
        assert_eq!(agg, Some((1000, 800)));
    }

    #[test]
    fn test_format_keenetic_model_release_and_entware_release_parsing() {
        let ver = KeeneticVersionInfo {
            model: "Ultra (KN-1811)".to_string(),
            release: "4.2.3".to_string(),
            ndms: "0-4.2.3".to_string(),
            hw_id: "KN-1811".to_string(),
        };
        assert_eq!(
            format_keenetic_model(&ver).as_deref(),
            Some("Keenetic Ultra (KN-1811)")
        );
        assert_eq!(
            format_keenetic_release(&ver).as_deref(),
            Some("KeeneticOS 4.2.3")
        );

        let ent_raw = "DISTRIB_DESCRIPTION='Entware mipsel-3.4'\n";
        assert_eq!(
            parse_entware_release(ent_raw).as_deref(),
            Some("Entware mipsel-3.4")
        );
    }

    #[test]
    fn test_merge_keenetic_hotspot_devices_enriches_and_adds() {
        let base = vec![LanDevice {
            ip: "192.168.1.42".to_string(),
            mac: "AA:BB:CC:DD:EE:01".to_string(),
            hostname: String::new(),
            interface: "br0".to_string(),
            reachable: false,
            ..Default::default()
        }];
        let rci = vec![
            KeeneticHostEntry {
                ip: "192.168.1.42".to_string(),
                mac: "aa:bb:cc:dd:ee:01".to_string(),
                name: "Workstation".to_string(),
                interface: "Home".to_string(),
                active: true,
            },
            KeeneticHostEntry {
                ip: "192.168.1.99".to_string(),
                mac: "50:ff:20:11:22:33".to_string(),
                name: "Keenetic Mesh".to_string(),
                interface: "Home".to_string(),
                active: true,
            },
        ];
        let merged = merge_keenetic_hotspot_devices(base, &rci);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].ip, "192.168.1.42");
        assert_eq!(merged[0].hostname, "Workstation");
        assert!(merged[0].reachable);
        assert_eq!(merged[1].ip, "192.168.1.99");
        assert_eq!(merged[1].vendor, "Keenetic");
    }

    #[test]
    fn test_collect_host_info_includes_platform_fields() {
        let info = collect_host_info();
        assert!(!info.platform.is_empty());
        assert!(!info.firewall_backend.is_empty());
        assert!(!info.storage_kind.is_empty());
    }
}
