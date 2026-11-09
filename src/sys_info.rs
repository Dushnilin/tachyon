//! Zero-dependency host telemetry, PID-recycling-safe process identity (`pid + starttime + boot_id`),
//! and LAN neighbor / DHCP lease discovery for OpenWrt routers.

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

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

pub fn collect_host_info() -> HostSysInfo {
    let model = read_router_model();
    let hostname = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| model.clone());

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
        openwrt_release: read_openwrt_release(),
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
        if let Ok(statm) = std::fs::read_to_string("/proc/self/statm")
            && let Some(res_pages) = statm.split_whitespace().nth(1)
            && let Ok(pages) = res_pages.parse::<u64>()
        {
            info.panel_rss_bytes = pages * 4096;
        }
    }

    #[cfg(target_os = "windows")]
    {
        win_sys::fill_host_info(&mut info);
        info.memory_total_mb = info.mem_total_bytes / 1_048_576;
        info.memory_used_mb = info.mem_used_bytes / 1_048_576;
    }

    info
}

fn read_router_model() -> String {
    for p in ["/tmp/sysinfo/model", "/proc/device-tree/model"] {
        if let Ok(s) = std::fs::read_to_string(p) {
            let trimmed = s.trim_matches(|c: char| c.is_whitespace() || c == '\0');
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
    }
    "Generic Router / Host".to_string()
}

fn read_openwrt_release() -> String {
    if let Ok(raw) = std::fs::read_to_string("/etc/openwrt_release") {
        for line in raw.lines() {
            if let Some(rest) = line.strip_prefix("DISTRIB_DESCRIPTION=") {
                return rest.trim_matches(|c| c == '\'' || c == '"').to_string();
            }
        }
    }
    format!("{} ({})", std::env::consts::OS, std::env::consts::ARCH)
}

/// Discover LAN devices from `/tmp/dhcp.leases` and `/proc/net/arp`.
pub fn discover_lan_devices() -> Vec<LanDevice> {
    let mut by_ip: HashMap<String, LanDevice> = HashMap::new();

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
                        interface: "br-lan".to_string(),
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
        if let Ok(statm) = std::fs::read_to_string(format!("/proc/{pid}/statm"))
            && let Some(res_pages) = statm.split_whitespace().nth(1)
            && let Ok(pages) = res_pages.parse::<u64>()
        {
            return pages * 4096;
        }
        0
    }
    #[cfg(target_os = "windows")]
    {
        win_sys::pid_working_set_bytes(pid)
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        let _ = pid;
        0
    }
}

#[cfg(target_os = "linux")]
fn parse_kb(s: &str) -> u64 {
    s.split_whitespace()
        .next()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0)
}

#[cfg(target_os = "windows")]
mod win_sys {
    use super::HostSysInfo;
    use std::sync::{Mutex, OnceLock};

    #[repr(C)]
    struct MemoryStatusEx {
        dw_length: u32,
        dw_memory_load: u32,
        ull_total_phys: u64,
        ull_avail_phys: u64,
        ull_total_page_file: u64,
        ull_avail_page_file: u64,
        ull_total_virtual: u64,
        ull_avail_virtual: u64,
        ull_avail_extended_virtual: u64,
    }

    #[repr(C)]
    struct ProcessMemoryCounters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    struct FileTime {
        dw_low_date_time: u32,
        dw_high_date_time: u32,
    }

    impl FileTime {
        fn to_u64(self) -> u64 {
            ((self.dw_high_date_time as u64) << 32) | (self.dw_low_date_time as u64)
        }
    }

    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const PROCESS_VM_READ: u32 = 0x0010;

    unsafe extern "system" {
        fn GlobalMemoryStatusEx(lp_buffer: *mut MemoryStatusEx) -> i32;
        fn GetTickCount64() -> u64;
        fn GetCurrentProcess() -> *mut core::ffi::c_void;
        fn OpenProcess(
            dw_desired_access: u32,
            b_inherit_handle: i32,
            dw_process_id: u32,
        ) -> *mut core::ffi::c_void;
        fn CloseHandle(h_object: *mut core::ffi::c_void) -> i32;
        fn K32GetProcessMemoryInfo(
            process: *mut core::ffi::c_void,
            ppsmem_counters: *mut ProcessMemoryCounters,
            cb: u32,
        ) -> i32;
        fn GetSystemTimes(
            lp_idle_time: *mut FileTime,
            lp_kernel_time: *mut FileTime,
            lp_user_time: *mut FileTime,
        ) -> i32;
    }

    pub fn fill_host_info(info: &mut HostSysInfo) {
        unsafe {
            let mut mem: MemoryStatusEx = core::mem::zeroed();
            mem.dw_length = core::mem::size_of::<MemoryStatusEx>() as u32;
            if GlobalMemoryStatusEx(&mut mem) != 0 {
                info.mem_total_bytes = mem.ull_total_phys;
                info.mem_used_bytes = mem.ull_total_phys.saturating_sub(mem.ull_avail_phys);
            }
            info.host_uptime_secs = GetTickCount64() / 1000;

            let mut pmc: ProcessMemoryCounters = core::mem::zeroed();
            pmc.cb = core::mem::size_of::<ProcessMemoryCounters>() as u32;
            if K32GetProcessMemoryInfo(GetCurrentProcess(), &mut pmc, pmc.cb) != 0 {
                info.panel_rss_bytes = pmc.working_set_size as u64;
            }
        }
        let cpu_load = sample_cpu_load();
        info.load_avg = format!("{cpu_load:.2} / {cpu_load:.2} / {cpu_load:.2}");
    }

    pub fn pid_working_set_bytes(pid: u32) -> u64 {
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, 0, pid);
            if handle.is_null() {
                return 0;
            }
            let mut pmc: ProcessMemoryCounters = core::mem::zeroed();
            pmc.cb = core::mem::size_of::<ProcessMemoryCounters>() as u32;
            let ok = K32GetProcessMemoryInfo(handle, &mut pmc, pmc.cb);
            let _ = CloseHandle(handle);
            if ok != 0 {
                pmc.working_set_size as u64
            } else {
                0
            }
        }
    }

    fn sample_cpu_load() -> f64 {
        static PREV: OnceLock<Mutex<(u64, u64, f64)>> = OnceLock::new();
        let lock = PREV.get_or_init(|| Mutex::new((0, 0, 0.0)));
        let (idle, total) = unsafe {
            let mut idle_ft = FileTime::default();
            let mut kern_ft = FileTime::default();
            let mut user_ft = FileTime::default();
            if GetSystemTimes(&mut idle_ft, &mut kern_ft, &mut user_ft) == 0 {
                return 0.0;
            }
            let i = idle_ft.to_u64();
            let t = kern_ft.to_u64().saturating_add(user_ft.to_u64());
            (i, t)
        };
        let Ok(mut guard) = lock.lock() else {
            return 0.0;
        };
        let (prev_idle, prev_total, prev_val) = *guard;
        let d_total = total.saturating_sub(prev_total);
        let d_idle = idle.saturating_sub(prev_idle);
        let val = if prev_total > 0 && d_total > 0 {
            let busy = d_total.saturating_sub(d_idle) as f64;
            ((busy / (d_total as f64)) * 100.0).clamp(0.0, 100.0) / 100.0
        } else {
            prev_val
        };
        if d_total > 0 || prev_total == 0 {
            *guard = (idle, total, val);
        }
        val
    }
}
