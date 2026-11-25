//! Platform detection, filesystem path layout, firewall backend selection,
//! storage inspection, and crash-durable file persistence for OpenWrt and Entware targets.

#![allow(dead_code)]

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::Ordering;

use serde::{Deserialize, Serialize};

/// Supported router operating environments.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlatformKind {
    #[serde(rename = "openwrt")]
    OpenWrt,
    KeeneticEntware,
    MerlinEntware,
    PadavanEntware,
    GenericEntware,
}

impl PlatformKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::OpenWrt => "openwrt",
            Self::KeeneticEntware => "keenetic_entware",
            Self::MerlinEntware => "merlin_entware",
            Self::PadavanEntware => "padavan_entware",
            Self::GenericEntware => "generic_entware",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            Self::OpenWrt => "OpenWrt",
            Self::KeeneticEntware => "Keenetic (Entware)",
            Self::MerlinEntware => "Asuswrt-Merlin (Entware)",
            Self::PadavanEntware => "Padavan (Entware)",
            Self::GenericEntware => "Entware (Linux)",
        }
    }

    pub fn is_entware(&self) -> bool {
        !matches!(self, Self::OpenWrt)
    }

    pub fn is_openwrt(&self) -> bool {
        matches!(self, Self::OpenWrt)
    }

    pub fn is_keenetic(&self) -> bool {
        matches!(self, Self::KeeneticEntware)
    }
}

/// Active kernel packet filter backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FirewallKind {
    Nftables,
    Iptables,
}

impl FirewallKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Nftables => "nftables",
            Self::Iptables => "iptables",
        }
    }
}

/// Underlying storage medium classification for wear and durability decisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StorageKind {
    InternalFlash,
    UsbExternal,
    TmpfsOnly,
    Unknown,
}

impl StorageKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::InternalFlash => "internal_flash",
            Self::UsbExternal => "usb_external",
            Self::TmpfsOnly => "tmpfs_only",
            Self::Unknown => "unknown",
        }
    }
}

/// Resolved mount metadata for a given path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorageInfo {
    pub kind: StorageKind,
    pub fs_type: String,
    pub mount_point: String,
    pub device: String,
    pub is_posix: bool,
}

/// Platform-specific installation and runtime directory layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlatformPaths {
    pub root: PathBuf,
    pub bin_dir: PathBuf,
    pub data_dir: PathBuf,
    pub core_config_dir: PathBuf,
    pub www_dir: PathBuf,
    pub share_dir: PathBuf,
    pub init_script: PathBuf,
    pub runtime_tmpfs_dir: PathBuf,
    pub rulesets_dir: PathBuf,
    pub ndm_dir: PathBuf,
    pub jffs_scripts_dir: PathBuf,
}

/// Pure platform detector operating on explicit probe signals.
#[allow(clippy::too_many_arguments)]
pub fn detect_platform_from_signals(
    force_platform: Option<&str>,
    has_openwrt_release: bool,
    has_proc_ndm: bool,
    has_ndmc: bool,
    entware_release_raw: Option<&str>,
    device_model_raw: Option<&str>,
    has_jffs_scripts: bool,
    has_etc_storage: bool,
    has_entware_files: bool,
) -> PlatformKind {
    if let Some(forced) = force_platform.map(str::trim).filter(|s| !s.is_empty()) {
        match forced.to_ascii_lowercase().as_str() {
            "openwrt" | "open_wrt" => return PlatformKind::OpenWrt,
            "keenetic" | "keenetic_entware" | "ndms" => return PlatformKind::KeeneticEntware,
            "merlin" | "merlin_entware" | "asuswrt" | "asuswrt_merlin" => {
                return PlatformKind::MerlinEntware;
            }
            "padavan" | "padavan_entware" => return PlatformKind::PadavanEntware,
            "entware" | "generic_entware" | "generic" => return PlatformKind::GenericEntware,
            _ => {}
        }
    }

    if has_openwrt_release {
        return PlatformKind::OpenWrt;
    }

    let entware_lower = entware_release_raw
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    let model_lower = device_model_raw
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    if has_proc_ndm
        || has_ndmc
        || entware_lower.contains("keenetic")
        || entware_lower.contains("ndms")
        || model_lower.contains("keenetic")
        || model_lower.contains("kn-")
    {
        return PlatformKind::KeeneticEntware;
    }

    if has_jffs_scripts
        || entware_lower.contains("merlin")
        || entware_lower.contains("asuswrt")
        || (has_entware_files && model_lower.contains("asus"))
    {
        return PlatformKind::MerlinEntware;
    }

    if has_etc_storage || entware_lower.contains("padavan") {
        return PlatformKind::PadavanEntware;
    }

    if has_entware_files || entware_release_raw.is_some() {
        return PlatformKind::GenericEntware;
    }

    PlatformKind::OpenWrt
}

#[cfg(target_os = "linux")]
fn command_exists_in_path(cmd: &str) -> bool {
    if let Ok(path_env) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_env) {
            let candidate = dir.join(cmd);
            if candidate.is_file() {
                return true;
            }
        }
    }
    for fallback in [
        "/bin",
        "/usr/bin",
        "/sbin",
        "/usr/sbin",
        "/opt/bin",
        "/opt/sbin",
    ] {
        if Path::new(fallback).join(cmd).is_file() {
            return true;
        }
    }
    false
}

/// Detect the active host platform once and cache the result for the process lifetime.
pub fn detect_platform() -> PlatformKind {
    static DETECTED: OnceLock<PlatformKind> = OnceLock::new();
    *DETECTED.get_or_init(|| {
        let force = std::env::var("TACHYON_PLATFORM").ok();
        #[cfg(target_os = "linux")]
        {
            let has_openwrt_release = Path::new("/etc/openwrt_release").exists();
            let has_proc_ndm = Path::new("/proc/ndm").exists();
            let has_ndmc = command_exists_in_path("ndmc");
            let entware_release_raw = std::fs::read_to_string("/opt/etc/entware_release").ok();
            let device_model_raw = std::fs::read_to_string("/proc/device-tree/model").ok();
            let has_jffs_scripts = Path::new("/jffs/scripts").is_dir();
            let has_etc_storage = Path::new("/etc/storage").is_dir();
            let has_entware_files =
                Path::new("/opt/bin/opkg").exists() || Path::new("/opt/etc/init.d").is_dir();
            detect_platform_from_signals(
                force.as_deref(),
                has_openwrt_release,
                has_proc_ndm,
                has_ndmc,
                entware_release_raw.as_deref(),
                device_model_raw.as_deref(),
                has_jffs_scripts,
                has_etc_storage,
                has_entware_files,
            )
        }
        #[cfg(not(target_os = "linux"))]
        {
            detect_platform_from_signals(
                force.as_deref(),
                false,
                false,
                false,
                None,
                None,
                false,
                false,
                false,
            )
        }
    })
}

pub fn is_entware() -> bool {
    detect_platform().is_entware()
}

pub fn is_openwrt() -> bool {
    detect_platform().is_openwrt()
}

pub fn is_keenetic() -> bool {
    detect_platform().is_keenetic()
}

/// Pure firewall backend selection from platform and explicit override.
pub fn detect_firewall_kind_from_signals(
    platform: PlatformKind,
    force_firewall: Option<&str>,
) -> FirewallKind {
    if let Some(forced) = force_firewall.map(str::trim).filter(|s| !s.is_empty()) {
        match forced.to_ascii_lowercase().as_str() {
            "nftables" | "nft" => return FirewallKind::Nftables,
            "iptables" | "ipt" => return FirewallKind::Iptables,
            _ => {}
        }
    }

    if platform.is_openwrt() {
        FirewallKind::Nftables
    } else {
        // Entware environments (Keenetic NDMS, Asuswrt-Merlin, Padavan, generic Entware)
        // default to iptables unless TACHYON_FIREWALL=nftables is explicitly requested.
        FirewallKind::Iptables
    }
}

/// Resolve the active firewall backend once and cache the result.
pub fn firewall_kind() -> FirewallKind {
    static FW_KIND: OnceLock<FirewallKind> = OnceLock::new();
    *FW_KIND.get_or_init(|| {
        let force = std::env::var("TACHYON_FIREWALL").ok();
        detect_firewall_kind_from_signals(detect_platform(), force.as_deref())
    })
}

fn join_platform_path(base: &str, rel: &str) -> PathBuf {
    if base.contains('\\') {
        return PathBuf::from(base).join(rel);
    }
    let clean_base = base.trim_end_matches('/');
    let clean_rel = rel.trim_start_matches('/');
    if clean_base.is_empty() {
        PathBuf::from(format!("/{clean_rel}"))
    } else if clean_rel.is_empty() {
        PathBuf::from(clean_base)
    } else {
        PathBuf::from(format!("{clean_base}/{clean_rel}"))
    }
}

/// Resolve all platform directories for a given platform and optional overrides.
pub fn resolve_paths_for(
    platform: PlatformKind,
    root_override: Option<&str>,
    data_dir_override: Option<&str>,
    runtime_tmpfs: PathBuf,
) -> PlatformPaths {
    let root_str = root_override
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| if platform.is_openwrt() { "/" } else { "/opt" });
    let data_override = data_dir_override.map(str::trim).filter(|s| !s.is_empty());

    if platform.is_openwrt() {
        let data_dir = data_override
            .map(PathBuf::from)
            .unwrap_or_else(|| join_platform_path(root_str, "etc/tachyon"));
        let data_str = data_dir.to_string_lossy();
        let rulesets_dir = join_platform_path(&data_str, "rulesets");
        PlatformPaths {
            root: PathBuf::from(root_str),
            bin_dir: join_platform_path(root_str, "usr/bin"),
            core_config_dir: join_platform_path(root_str, "etc/tachyon-core"),
            www_dir: join_platform_path(root_str, "www/luci-static"),
            share_dir: join_platform_path(root_str, "usr/share/tachyon"),
            init_script: join_platform_path(root_str, "etc/init.d/tachyon"),
            runtime_tmpfs_dir: runtime_tmpfs,
            rulesets_dir,
            data_dir,
            ndm_dir: PathBuf::from("/opt/etc/ndm"),
            jffs_scripts_dir: PathBuf::from("/jffs/scripts"),
        }
    } else {
        let data_dir = data_override
            .map(PathBuf::from)
            .unwrap_or_else(|| join_platform_path(root_str, "etc/tachyon"));
        let data_str = data_dir.to_string_lossy();
        let rulesets_dir = join_platform_path(&data_str, "rulesets");
        PlatformPaths {
            root: PathBuf::from(root_str),
            bin_dir: join_platform_path(root_str, "bin"),
            core_config_dir: join_platform_path(root_str, "etc/tachyon-core"),
            www_dir: join_platform_path(root_str, "share/tachyon/www/luci-static"),
            share_dir: join_platform_path(root_str, "share/tachyon"),
            init_script: join_platform_path(root_str, "etc/init.d/S99tachyon"),
            runtime_tmpfs_dir: runtime_tmpfs,
            rulesets_dir,
            data_dir,
            ndm_dir: join_platform_path(root_str, "etc/ndm"),
            jffs_scripts_dir: PathBuf::from("/jffs/scripts"),
        }
    }
}

/// Cached process-wide platform path layout.
pub fn paths() -> &'static PlatformPaths {
    static PATHS: OnceLock<PlatformPaths> = OnceLock::new();
    PATHS.get_or_init(|| {
        let platform = detect_platform();
        let root_override = std::env::var("TACHYON_ROOT").ok();
        let data_dir_override = std::env::var("TACHYON_DATA_DIR")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| {
                #[cfg(not(target_os = "linux"))]
                {
                    Some("data".to_string())
                }
                #[cfg(target_os = "linux")]
                {
                    None
                }
            });
        let runtime_tmpfs = resolve_ram_tmpfs_dir();
        resolve_paths_for(
            platform,
            root_override.as_deref(),
            data_dir_override.as_deref(),
            runtime_tmpfs,
        )
    })
}

fn unescape_mount_field(raw: &str) -> String {
    if !raw.contains('\\') {
        return raw.to_string();
    }
    let bytes = raw.as_bytes();
    let mut out = String::with_capacity(raw.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 3 < bytes.len() {
            let oct = &raw[i + 1..i + 4];
            if oct.bytes().all(|b| (b'0'..=b'7').contains(&b))
                && let Ok(val) = u8::from_str_radix(oct, 8)
            {
                out.push(val as char);
                i += 4;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

struct MountEntry {
    device: String,
    mount_point: String,
    fs_type: String,
}

fn parse_proc_mounts(mounts_raw: &str) -> Vec<MountEntry> {
    let mut entries = Vec::new();
    for line in mounts_raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let mut parts = trimmed.split_whitespace();
        let (Some(dev), Some(mp), Some(fs)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        let mut mount_point = unescape_mount_field(mp);
        if mount_point.len() > 1 {
            mount_point = mount_point.trim_end_matches('/').to_string();
            if mount_point.is_empty() {
                mount_point.push('/');
            }
        }
        entries.push(MountEntry {
            device: unescape_mount_field(dev),
            mount_point,
            fs_type: fs.to_string(),
        });
    }
    entries
}

fn find_longest_mount<'a>(target: &str, entries: &'a [MountEntry]) -> Option<&'a MountEntry> {
    let normalized_owned = target.replace('\\', "/");
    let normalized = if normalized_owned.len() > 1 {
        normalized_owned.trim_end_matches('/')
    } else {
        normalized_owned.as_str()
    };

    let mut best: Option<&MountEntry> = None;
    let mut best_len: usize = 0;

    for entry in entries {
        let mp = entry.mount_point.as_str();
        let matched = if mp == "/" {
            normalized.starts_with('/')
        } else if normalized == mp {
            true
        } else if let Some(rest) = normalized.strip_prefix(mp) {
            rest.starts_with('/')
        } else {
            false
        };
        if matched && mp.len() >= best_len {
            best_len = mp.len();
            best = Some(entry);
        }
    }
    best
}

fn mount_is_tmpfs(target: &str, entries: &[MountEntry]) -> bool {
    find_longest_mount(target, entries)
        .map(|m| m.fs_type.eq_ignore_ascii_case("tmpfs"))
        .unwrap_or(false)
}

/// Select a RAM-backed temporary runtime directory from `/proc/mounts` contents.
/// Never returns any path under `/opt` (USB external storage).
pub fn resolve_ram_tmpfs_dir_from_mounts(mounts_raw: &str) -> PathBuf {
    let entries = parse_proc_mounts(mounts_raw);
    if mount_is_tmpfs("/var/run", &entries) || mount_is_tmpfs("/run", &entries) {
        return PathBuf::from("/var/run/tachyon");
    }
    if mount_is_tmpfs("/tmp", &entries) {
        return PathBuf::from("/tmp/tachyon-rs");
    }
    PathBuf::from("/tmp/tachyon-rs")
}

/// Resolve the RAM tmpfs directory for runtime state files.
pub fn resolve_ram_tmpfs_dir() -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        if let Ok(mounts_raw) = std::fs::read_to_string("/proc/mounts") {
            return resolve_ram_tmpfs_dir_from_mounts(&mounts_raw);
        }
        PathBuf::from("/tmp/tachyon-rs")
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::env::temp_dir().join("tachyon-rs")
    }
}

/// Inspect storage medium and POSIX semantics for `path` using `/proc/mounts` text.
pub fn detect_storage_info_from_mounts(path: &Path, mounts_raw: &str) -> StorageInfo {
    let entries = parse_proc_mounts(mounts_raw);
    let target = path.to_string_lossy();
    let Some(entry) = find_longest_mount(&target, &entries) else {
        return StorageInfo {
            kind: StorageKind::Unknown,
            fs_type: String::new(),
            mount_point: String::new(),
            device: String::new(),
            is_posix: false,
        };
    };

    let fs_lower = entry.fs_type.to_ascii_lowercase();
    let is_posix = matches!(
        fs_lower.as_str(),
        "ext2"
            | "ext3"
            | "ext4"
            | "f2fs"
            | "btrfs"
            | "xfs"
            | "ubifs"
            | "overlay"
            | "jffs2"
            | "tmpfs"
    );

    let mp = entry.mount_point.as_str();
    let dev = entry.device.as_str();

    let is_usb_mountpoint = mp == "/opt"
        || mp.starts_with("/opt/")
        || mp == "/tmp/mnt"
        || mp.starts_with("/tmp/mnt/")
        || mp == "/mnt"
        || mp.starts_with("/mnt/")
        || mp == "/media"
        || mp.starts_with("/media/");

    let kind = if fs_lower == "tmpfs" || fs_lower == "ramfs" {
        StorageKind::TmpfsOnly
    } else if dev.starts_with("/dev/sd") || (is_usb_mountpoint && fs_lower != "rootfs") {
        StorageKind::UsbExternal
    } else if dev.starts_with("/dev/mtd")
        || dev.starts_with("/dev/ubi")
        || dev.starts_with("/dev/mmcblk")
        || dev.starts_with("/dev/root")
        || matches!(
            fs_lower.as_str(),
            "overlay" | "jffs2" | "ubifs" | "squashfs" | "ext2" | "ext3" | "ext4" | "f2fs"
        )
    {
        StorageKind::InternalFlash
    } else {
        StorageKind::Unknown
    };

    StorageInfo {
        kind,
        fs_type: entry.fs_type.clone(),
        mount_point: entry.mount_point.clone(),
        device: entry.device.clone(),
        is_posix,
    }
}

/// Inspect storage medium and filesystem type backing `path`.
pub fn detect_storage_info(path: &Path) -> StorageInfo {
    #[cfg(target_os = "linux")]
    {
        let raw = std::fs::read_to_string("/proc/mounts").unwrap_or_default();
        detect_storage_info_from_mounts(path, &raw)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = path;
        StorageInfo {
            kind: StorageKind::Unknown,
            fs_type: String::new(),
            mount_point: String::new(),
            device: String::new(),
            is_posix: false,
        }
    }
}

/// Pure default LAN bridge selector based on platform and interface presence.
pub fn detect_default_lan_iface_from(
    platform: PlatformKind,
    has_br_lan: bool,
    has_br0: bool,
) -> String {
    if platform.is_openwrt() {
        let _ = has_br_lan;
        "br-lan".to_string()
    } else if has_br0 {
        "br0".to_string()
    } else if has_br_lan {
        "br-lan".to_string()
    } else {
        "br0".to_string()
    }
}

/// Detect the default LAN bridge interface (`br-lan` on OpenWrt, `br0` on Entware/Keenetic).
pub fn detect_default_lan_iface() -> String {
    let platform = detect_platform();
    #[cfg(target_os = "linux")]
    {
        let has_br_lan = Path::new("/sys/class/net/br-lan").exists();
        let has_br0 = Path::new("/sys/class/net/br0").exists();
        detect_default_lan_iface_from(platform, has_br_lan, has_br0)
    }
    #[cfg(not(target_os = "linux"))]
    {
        detect_default_lan_iface_from(platform, false, false)
    }
}

/// Pure check whether Tachyon manages a local dnsmasq instance directly.
pub fn has_managed_dnsmasq_for(platform: PlatformKind, dont_touch_dhcp: bool) -> bool {
    if dont_touch_dhcp {
        return false;
    }
    platform.is_openwrt()
}

/// Return `true` when Tachyon is allowed to manage dnsmasq configuration on this host.
pub fn has_managed_dnsmasq(dont_touch_dhcp: bool) -> bool {
    has_managed_dnsmasq_for(detect_platform(), dont_touch_dhcp)
}

fn file_bytes_equal(path: &Path, expected: &[u8]) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() || meta.len() != expected.len() as u64 {
        return false;
    }
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    let mut buf = [0u8; 4096];
    let mut offset = 0usize;
    loop {
        match file.read(&mut buf) {
            Ok(0) => return offset == expected.len(),
            Ok(n) => {
                let Some(end) = offset.checked_add(n) else {
                    return false;
                };
                if end > expected.len() || expected[offset..end] != buf[..n] {
                    return false;
                }
                offset = end;
            }
            Err(_) => return false,
        }
    }
}

/// Crash-durable, wear-safe atomic file writer:
/// - Skips writing and returns `Ok(false)` when existing file bytes already match `content`.
/// - Writes to a sibling temporary file, calls `file.sync_all()`, atomically renames it over
///   `path`, and fsyncs the parent directory on Unix for power-loss durability on USB/flash.
pub fn write_file_if_changed_durable(path: &Path, content: &[u8]) -> std::io::Result<bool> {
    if file_bytes_equal(path, content) {
        return Ok(false);
    }

    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }

    static DURABLE_TMP_SEQ: crate::store::PortableAtomicU64 =
        crate::store::PortableAtomicU64::new(0);
    let base_name = path
        .file_name()
        .map(|s| s.to_string_lossy())
        .unwrap_or_else(|| "file".into());
    let seq = DURABLE_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp_path = path.with_file_name(format!(".{base_name}.tmp.{}.{seq}", std::process::id()));

    let write_res = (|| -> std::io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp_path)?;
        file.write_all(content)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp_path, path)?;
        Ok(())
    })();

    if let Err(err) = write_res {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(err);
    }

    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        let dir_path = if parent.as_os_str().is_empty() {
            Path::new(".")
        } else {
            parent
        };
        if let Ok(dir) = File::open(dir_path) {
            let _ = dir.sync_all();
        }
    }

    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_platform_kind_helpers() {
        assert_eq!(PlatformKind::OpenWrt.as_str(), "openwrt");
        assert!(PlatformKind::OpenWrt.is_openwrt());
        assert!(!PlatformKind::OpenWrt.is_entware());
        assert!(!PlatformKind::OpenWrt.is_keenetic());

        assert_eq!(PlatformKind::KeeneticEntware.as_str(), "keenetic_entware");
        assert!(PlatformKind::KeeneticEntware.is_entware());
        assert!(PlatformKind::KeeneticEntware.is_keenetic());
        assert!(!PlatformKind::KeeneticEntware.is_openwrt());

        assert_eq!(PlatformKind::MerlinEntware.as_str(), "merlin_entware");
        assert!(PlatformKind::MerlinEntware.is_entware());
        assert_eq!(PlatformKind::PadavanEntware.as_str(), "padavan_entware");
        assert_eq!(PlatformKind::GenericEntware.as_str(), "generic_entware");
        assert_eq!(
            serde_json::to_string(&PlatformKind::OpenWrt).unwrap(),
            "\"openwrt\""
        );
        assert_eq!(
            serde_json::to_string(&PlatformKind::KeeneticEntware).unwrap(),
            "\"keenetic_entware\""
        );
    }

    #[test]
    fn test_detect_platform_from_signals() {
        // Explicit override wins over filesystem signals.
        assert_eq!(
            detect_platform_from_signals(
                Some("keenetic"),
                true,
                false,
                false,
                None,
                None,
                false,
                false,
                false
            ),
            PlatformKind::KeeneticEntware
        );
        assert_eq!(
            detect_platform_from_signals(
                Some("merlin"),
                false,
                true,
                true,
                None,
                None,
                false,
                false,
                false
            ),
            PlatformKind::MerlinEntware
        );

        // OpenWrt release takes precedence over Entware signals when unforced.
        assert_eq!(
            detect_platform_from_signals(
                None,
                true,
                false,
                false,
                Some("entware"),
                None,
                false,
                false,
                true
            ),
            PlatformKind::OpenWrt
        );

        // Keenetic detection via /proc/ndm, ndmc, or model.
        assert_eq!(
            detect_platform_from_signals(None, false, true, false, None, None, false, false, true),
            PlatformKind::KeeneticEntware
        );
        assert_eq!(
            detect_platform_from_signals(None, false, false, true, None, None, false, false, true),
            PlatformKind::KeeneticEntware
        );
        assert_eq!(
            detect_platform_from_signals(
                None,
                false,
                false,
                false,
                None,
                Some("Keenetic Ultra (KN-1811)"),
                false,
                false,
                true
            ),
            PlatformKind::KeeneticEntware
        );

        // Asuswrt-Merlin via /jffs/scripts.
        assert_eq!(
            detect_platform_from_signals(None, false, false, false, None, None, true, false, true),
            PlatformKind::MerlinEntware
        );

        // Padavan via /etc/storage.
        assert_eq!(
            detect_platform_from_signals(None, false, false, false, None, None, false, true, true),
            PlatformKind::PadavanEntware
        );

        // Generic Entware via /opt/bin/opkg.
        assert_eq!(
            detect_platform_from_signals(None, false, false, false, None, None, false, false, true),
            PlatformKind::GenericEntware
        );

        // Fallback on dev/CI machines without markers is OpenWrt.
        assert_eq!(
            detect_platform_from_signals(
                None, false, false, false, None, None, false, false, false
            ),
            PlatformKind::OpenWrt
        );
    }

    #[test]
    fn test_firewall_kind_selection() {
        assert_eq!(
            detect_firewall_kind_from_signals(PlatformKind::OpenWrt, None),
            FirewallKind::Nftables
        );
        assert_eq!(
            detect_firewall_kind_from_signals(PlatformKind::KeeneticEntware, None),
            FirewallKind::Iptables
        );
        assert_eq!(
            detect_firewall_kind_from_signals(PlatformKind::GenericEntware, None),
            FirewallKind::Iptables
        );
        assert_eq!(
            detect_firewall_kind_from_signals(PlatformKind::KeeneticEntware, Some("nftables")),
            FirewallKind::Nftables
        );
        assert_eq!(
            detect_firewall_kind_from_signals(PlatformKind::OpenWrt, Some("iptables")),
            FirewallKind::Iptables
        );
    }

    #[test]
    fn test_resolve_paths_for_openwrt_and_entware() {
        let ow = resolve_paths_for(
            PlatformKind::OpenWrt,
            None,
            None,
            PathBuf::from("/var/run/tachyon"),
        );
        assert_eq!(ow.root, PathBuf::from("/"));
        assert_eq!(ow.bin_dir, PathBuf::from("/usr/bin"));
        assert_eq!(ow.data_dir, PathBuf::from("/etc/tachyon"));
        assert_eq!(ow.core_config_dir, PathBuf::from("/etc/tachyon-core"));
        assert_eq!(ow.www_dir, PathBuf::from("/www/luci-static"));
        assert_eq!(ow.share_dir, PathBuf::from("/usr/share/tachyon"));
        assert_eq!(ow.init_script, PathBuf::from("/etc/init.d/tachyon"));
        assert_eq!(ow.rulesets_dir, PathBuf::from("/etc/tachyon/rulesets"));
        assert_eq!(ow.ndm_dir, PathBuf::from("/opt/etc/ndm"));
        assert_eq!(ow.jffs_scripts_dir, PathBuf::from("/jffs/scripts"));

        let ent = resolve_paths_for(
            PlatformKind::KeeneticEntware,
            None,
            None,
            PathBuf::from("/tmp/tachyon-rs"),
        );
        assert_eq!(ent.root, PathBuf::from("/opt"));
        assert_eq!(ent.bin_dir, PathBuf::from("/opt/bin"));
        assert_eq!(ent.data_dir, PathBuf::from("/opt/etc/tachyon"));
        assert_eq!(ent.core_config_dir, PathBuf::from("/opt/etc/tachyon-core"));
        assert_eq!(
            ent.www_dir,
            PathBuf::from("/opt/share/tachyon/www/luci-static")
        );
        assert_eq!(ent.share_dir, PathBuf::from("/opt/share/tachyon"));
        assert_eq!(ent.init_script, PathBuf::from("/opt/etc/init.d/S99tachyon"));
        assert_eq!(ent.rulesets_dir, PathBuf::from("/opt/etc/tachyon/rulesets"));
        assert_eq!(ent.ndm_dir, PathBuf::from("/opt/etc/ndm"));
        assert_eq!(ent.jffs_scripts_dir, PathBuf::from("/jffs/scripts"));

        let custom = resolve_paths_for(
            PlatformKind::GenericEntware,
            Some("/tmp/mnt/usb/entware"),
            Some("/tmp/custom-data"),
            PathBuf::from("/tmp/tachyon-rs"),
        );
        assert_eq!(custom.bin_dir, PathBuf::from("/tmp/mnt/usb/entware/bin"));
        assert_eq!(custom.data_dir, PathBuf::from("/tmp/custom-data"));
        assert_eq!(
            custom.rulesets_dir,
            PathBuf::from("/tmp/custom-data/rulesets")
        );
        assert_eq!(
            custom.ndm_dir,
            PathBuf::from("/tmp/mnt/usb/entware/etc/ndm")
        );
    }

    #[test]
    fn test_resolve_ram_tmpfs_dir_from_mounts() {
        let mounts_var_run = "\
/dev/root / squashfs ro 0 0
tmpfs /tmp tmpfs rw,nosuid 0 0
tmpfs /var/run tmpfs rw,nosuid 0 0
/dev/sda1 /opt ext4 rw,noatime 0 0
";
        assert_eq!(
            resolve_ram_tmpfs_dir_from_mounts(mounts_var_run),
            PathBuf::from("/var/run/tachyon")
        );

        let mounts_tmp_only = "\
/dev/root / squashfs ro 0 0
tmpfs /tmp tmpfs rw 0 0
/dev/sda1 /opt ext4 rw 0 0
";
        assert_eq!(
            resolve_ram_tmpfs_dir_from_mounts(mounts_tmp_only),
            PathBuf::from("/tmp/tachyon-rs")
        );

        let mounts_no_tmpfs = "\
/dev/sda1 /opt ext4 rw 0 0
";
        let resolved = resolve_ram_tmpfs_dir_from_mounts(mounts_no_tmpfs);
        assert_eq!(resolved, PathBuf::from("/tmp/tachyon-rs"));
        assert!(!resolved.starts_with("/opt"));
    }

    #[test]
    fn test_detect_storage_info_from_mounts() {
        let mounts = "\
rootfs / rootfs rw 0 0
/dev/root / squashfs ro 0 0
overlayfs:/overlay / overlay rw,noatime 0 0
tmpfs /tmp tmpfs rw 0 0
/dev/sda1 /tmp/mnt/My\\040USB vfat rw 0 0
/dev/sda2 /opt ext4 rw,noatime 0 0
";
        let opt_info = detect_storage_info_from_mounts(Path::new("/opt/etc/tachyon"), mounts);
        assert_eq!(opt_info.kind, StorageKind::UsbExternal);
        assert_eq!(opt_info.fs_type, "ext4");
        assert_eq!(opt_info.mount_point, "/opt");
        assert_eq!(opt_info.device, "/dev/sda2");
        assert!(opt_info.is_posix);

        let fat_info =
            detect_storage_info_from_mounts(Path::new("/tmp/mnt/My USB/tachyon"), mounts);
        assert_eq!(fat_info.kind, StorageKind::UsbExternal);
        assert_eq!(fat_info.fs_type, "vfat");
        assert!(!fat_info.is_posix);

        let flash_info = detect_storage_info_from_mounts(Path::new("/etc/tachyon"), mounts);
        assert_eq!(flash_info.kind, StorageKind::InternalFlash);
        assert_eq!(flash_info.fs_type, "overlay");
        assert!(flash_info.is_posix);

        let tmp_info = detect_storage_info_from_mounts(Path::new("/tmp/tachyon-rs"), mounts);
        assert_eq!(tmp_info.kind, StorageKind::TmpfsOnly);
        assert!(tmp_info.is_posix);
    }

    #[test]
    fn test_default_lan_iface_and_managed_dnsmasq() {
        assert_eq!(
            detect_default_lan_iface_from(PlatformKind::OpenWrt, true, true),
            "br-lan"
        );
        assert_eq!(
            detect_default_lan_iface_from(PlatformKind::KeeneticEntware, true, true),
            "br0"
        );
        assert_eq!(
            detect_default_lan_iface_from(PlatformKind::KeeneticEntware, true, false),
            "br-lan"
        );
        assert_eq!(
            detect_default_lan_iface_from(PlatformKind::GenericEntware, false, false),
            "br0"
        );

        assert!(has_managed_dnsmasq_for(PlatformKind::OpenWrt, false));
        assert!(!has_managed_dnsmasq_for(PlatformKind::OpenWrt, true));
        assert!(!has_managed_dnsmasq_for(
            PlatformKind::KeeneticEntware,
            false
        ));
    }

    #[test]
    fn test_write_file_if_changed_durable_skips_identical_rewrites() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "tachyon-platform-durable-{}-{nonce}",
            std::process::id()
        ));
        let target = dir.join("nested/config.json");

        assert!(write_file_if_changed_durable(&target, b"{\"v\":1}\n").unwrap());
        assert!(!write_file_if_changed_durable(&target, b"{\"v\":1}\n").unwrap());
        assert!(write_file_if_changed_durable(&target, b"{\"v\":2}\n").unwrap());
        assert_eq!(std::fs::read(&target).unwrap(), b"{\"v\":2}\n");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
