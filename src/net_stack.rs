//! OpenWrt networking stack orchestrator:
//! - Compiles and atomically applies `nftables` (`table inet TachyonTable`) via `nft -f -`
//! - Manages Policy Routing (`ip rule` / `ip route` table 100 for TProxy `:1602`)
//! - Coordinates `dnsmasq` upstream forwarding to `127.0.0.42#53` without NAND flash wear.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::crypto_gen;
use crate::store::RouterStoreData;

pub const TPROXY_PORT: u16 = 1602;
pub const TPROXY_FWMARK: &str = "0x04000000";
pub const ROUTER_TPROXY_FWMARK: &str = "0x10000000";
pub const BYPASS_FWMARK: &str = "0x40000000";
pub const TPROXY_ROUTE_TABLE: &str = "100";
pub const TAILSCALE_TUNNEL_BYPASS_MARK_MASK: &str = "0x00340000";
pub const TAILSCALE_DAEMON_BYPASS_MARK: &str = "0x00080000";
pub const TPROXY_FWMARK_MASKED: &str = "0x04000000/0x04000000";
pub const ROUTER_TPROXY_FWMARK_MASKED: &str = "0x10000000/0x10000000";
const TAILSCALE_MAGICDNS_SERVERS_FILE: &str = "/etc/tachyon/dnsmasq-tailscale.servers";
const TAILSCALE_LEGACY_DNSMASQ_CONF: &str = "/tmp/dnsmasq.d/tachyon-tailscale.conf";
const TAILSCALE_MAGICDNS_IP: &str = "100.100.100.100";
pub const FPTN_TUNNEL_BYPASS_MARK: &str = "0x00300000";

/// Compile the complete `inet TachyonTable` nftables ruleset from `RouterStoreData`.
/// With native `tachyon-core` handling all protocols (`desync`, `wdtt`, `fptn`, `tailscale`, `proxy`),
/// there are zero `NFQUEUE` chains and zero local `ciadpi` redirects — a single clean TProxy contour.
pub fn compile_nftables_ruleset(store: &RouterStoreData) -> String {
    let mut out = String::with_capacity(4096);
    let _ = writeln!(out, "table inet TachyonTable");
    let _ = writeln!(out, "delete table inet TachyonTable");
    let _ = writeln!(out, "table inet TachyonTable {{");

    // Local / RFC1918 / Loopback / Multicast bypass sets
    let _ = writeln!(
        out,
        "    set localv4 {{
        type ipv4_addr
        flags interval
        elements = {{
            0.0.0.0/8,
            10.0.0.0/8,
            100.64.0.0/10,
            127.0.0.0/8,
            169.254.0.0/16,
            172.16.0.0/12,
            192.168.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        }}
    }}"
    );

    if store.settings.enable_ipv6 {
        let _ = writeln!(
            out,
            "    set localv6 {{
        type ipv6_addr
        flags interval
        elements = {{
            ::1/128,
            fc00::/7,
            fe80::/10,
            ff00::/8
        }}
    }}"
        );
    }

    let fakeip_v4 = if store.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        store.settings.fakeip_inet4_range.trim()
    };
    let fakeip_v6 = if store.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        store.settings.fakeip_inet6_range.trim()
    };

    let bypass_ifaces_literal = collect_tailscale_bypass_ifaces(store)
        .into_iter()
        .map(|i| format!("\"{i}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let _ = writeln!(
        out,
        "    chain prerouting {{
        type filter hook prerouting priority mangle; policy accept;"
    );

    // Exclude virtual tunnel interfaces (Tailscale & FPTN) from self-interception
    let _ = writeln!(out, "        iifname {{ {bypass_ifaces_literal} }} return");

    // Loopback re-entry is only allowed for packets routed back via `mangle_output` (`ROUTER_TPROXY_FWMARK`)
    let _ = writeln!(
        out,
        "        iifname \"lo\" meta mark != {ROUTER_TPROXY_FWMARK} return"
    );

    // Restrict interception to configured LAN interfaces (`br-lan` by default) plus rerouted `lo`
    if !store.settings.source_network_interfaces.is_empty() {
        let mut quoted: Vec<String> = store
            .settings
            .source_network_interfaces
            .iter()
            .map(|i| i.trim())
            .filter(|i| !i.is_empty() && *i != "lo")
            .map(|i| format!("\"{i}\""))
            .collect();
        quoted.push("\"lo\"".to_string());
        let _ = writeln!(out, "        iifname != {{ {} }} return", quoted.join(", "));
    }

    // Bypass packets already marked with `BYPASS_FWMARK`, Tailscale marks, or FPTN tunnel mark
    let _ = writeln!(out, "        meta mark {BYPASS_FWMARK} return");
    let _ = writeln!(
        out,
        "        meta mark & 0x00ff0000 == {TAILSCALE_TUNNEL_BYPASS_MARK_MASK} return"
    );
    let _ = writeln!(
        out,
        "        meta mark & 0x00ff0000 == {TAILSCALE_DAEMON_BYPASS_MARK} return"
    );
    let _ = writeln!(
        out,
        "        meta mark & 0x00ff0000 == {FPTN_TUNNEL_BYPASS_MARK} return"
    );

    // Globally excluded LAN hosts / subnets / MACs (bypass TProxy & interception entirely)
    for raw_excl in &store.settings.excluded_ips {
        let tok = raw_excl.trim();
        if let Some((ip_part, prefix_part)) = tok.split_once('/') {
            if let (Ok(_v4), Ok(p)) = (
                ip_part.parse::<std::net::Ipv4Addr>(),
                prefix_part.parse::<u8>(),
            ) && p <= 32
            {
                let _ = writeln!(out, "        ip saddr {tok} return");
            } else if let (Ok(_v6), Ok(p)) = (
                ip_part.parse::<std::net::Ipv6Addr>(),
                prefix_part.parse::<u8>(),
            ) && p <= 128
            {
                let _ = writeln!(out, "        ip6 saddr {tok} return");
            }
        } else if tok.parse::<std::net::Ipv4Addr>().is_ok() {
            let _ = writeln!(out, "        ip saddr {tok} return");
        } else if tok.parse::<std::net::Ipv6Addr>().is_ok() {
            let _ = writeln!(out, "        ip6 saddr {tok} return");
        } else if crate::store::is_mac_address(tok) {
            let _ = writeln!(
                out,
                "        ether saddr {} return",
                tok.to_ascii_lowercase()
            );
        }
    }

    // Guest mode LAN isolation, router admin protection, port allowlist & rate shaping
    if store.guest_mode.enabled {
        let guests: Vec<String> = store
            .guest_mode
            .guest_devices
            .iter()
            .map(|g| g.trim().to_string())
            .filter(|g| g.contains('.'))
            .collect();
        if !guests.is_empty() {
            let guest_set = guests.join(", ");
            if store.guest_mode.block_router_admin {
                let _ = writeln!(
                    out,
                    "        ip saddr {{ {guest_set} }} ip daddr @localv4 meta l4proto {{ tcp, udp }} th dport {{ 22, 80, 443, 1680, 9090 }} drop"
                );
            }
            if store.guest_mode.isolate_lan {
                let _ = writeln!(
                    out,
                    "        ip saddr {{ {guest_set} }} ip daddr @localv4 meta l4proto {{ tcp, udp }} th dport != 53 drop"
                );
            }
            if !store.guest_mode.allowed_ports.is_empty() {
                let mut ports: Vec<u16> = store.guest_mode.allowed_ports.clone();
                if !ports.contains(&53) {
                    ports.push(53);
                }
                ports.sort_unstable();
                ports.dedup();
                let port_list = ports
                    .iter()
                    .map(u16::to_string)
                    .collect::<Vec<_>>()
                    .join(", ");
                let _ = writeln!(
                    out,
                    "        ip saddr {{ {guest_set} }} ip daddr != @localv4 meta l4proto {{ tcp, udp }} th dport != {{ {port_list} }} drop"
                );
            }
            if store.guest_mode.bandwidth_limit_mbps > 0 {
                let rate_kbytes = (u64::from(store.guest_mode.bandwidth_limit_mbps) * 125).max(1);
                let _ = writeln!(
                    out,
                    "        ip saddr {{ {guest_set} }} limit rate over {rate_kbytes} kbytes/second drop"
                );
                let _ = writeln!(
                    out,
                    "        ip daddr {{ {guest_set} }} limit rate over {rate_kbytes} kbytes/second drop"
                );
            }
        }
    }

    let intercept_embedded_ts =
        embedded_tailscale_enabled(store) && !native_tailscale_enabled(store);
    if intercept_embedded_ts {
        let _ = writeln!(
            out,
            "        ip daddr 100.64.0.0/10 meta l4proto {{ tcp, udp }} tproxy ip to 127.0.0.1:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
        );
        if store.settings.enable_ipv6 {
            let _ = writeln!(
                out,
                "        ip6 daddr fd7a:115c:a1e0::/48 meta l4proto {{ tcp, udp }} tproxy ip6 to [::1]:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
            );
        }
    }

    // Intercept DNS queries (`:53`) to `tachyon-core` FakeIP/DNS listener (`127.0.0.42:53`)
    let _ = writeln!(out, "        ip daddr @localv4 return");
    if store.settings.enable_ipv6 {
        let _ = writeln!(
            out,
            "        ip6 daddr @localv6 ip6 daddr != {fakeip_v6} return"
        );
    }

    // Paused / quota-exhausted parental control devices matched by L2 MAC address
    let now_unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut blocked_macs: Vec<String> = Vec::new();
    for prof in store.profiles.iter().filter(|p| p.enabled) {
        let paused = prof.paused_until_unix > now_unix;
        let quota_exhausted =
            prof.daily_quota_minutes > 0 && prof.used_minutes_today >= prof.daily_quota_minutes;
        if paused || quota_exhausted {
            for dev in &prof.device_ips {
                if crate::store::is_mac_address(dev) {
                    let mac = dev.trim().to_ascii_lowercase();
                    if !blocked_macs.contains(&mac) {
                        blocked_macs.push(mac);
                    }
                }
            }
        }
    }
    for mac in &blocked_macs {
        let _ = writeln!(out, "        ether saddr {mac} drop");
    }

    // Direct/bypass section `fully_routed_ips` devices specified by MAC bypass TProxy directly
    let mut bypass_macs: Vec<String> = Vec::new();
    for sec in store.sections.iter().filter(|s| {
        s.enabled
            && (matches!(s.action.as_str(), "direct" | "bypass") || s.connection_type == "direct")
    }) {
        for dev in &sec.fully_routed_ips {
            if crate::store::is_mac_address(dev) {
                let mac = dev.trim().to_ascii_lowercase();
                if !blocked_macs.contains(&mac) && !bypass_macs.contains(&mac) {
                    bypass_macs.push(mac);
                }
            }
        }
    }
    for mac in &bypass_macs {
        let _ = writeln!(out, "        ether saddr {mac} return");
    }

    // Exclude FPTN upstream server IPs so FPTN tunnel packets never self-intercept
    let fptn_ips = crate::config_gen::extract_fptn_server_ips(store);
    if !fptn_ips.is_empty() {
        let _ = writeln!(out, "        ip daddr {{ {} }} return", fptn_ips.join(", "));
    }

    if store.settings.exclude_ntp {
        let _ = writeln!(out, "        udp dport 123 return");
    }

    if store.settings.torrserver_direct_enabled && !store.settings.torrserver_ports.is_empty() {
        let ports: Vec<String> = store
            .settings
            .torrserver_ports
            .iter()
            .map(u16::to_string)
            .collect();
        let _ = writeln!(
            out,
            "        meta l4proto {{ tcp, udp }} th dport {{ {} }} return",
            ports.join(", ")
        );
    }

    if store.settings.disable_quic {
        let _ = writeln!(out, "        udp dport 443 reject");
    }

    if store.settings.block_doh {
        let _ = writeln!(
            out,
            "        ip daddr {{ 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9 }} tcp dport {{ 443, 853 }} reject"
        );
    }

    let _ = writeln!(
        out,
        "        meta l4proto {{ tcp, udp }} tproxy ip to 127.0.0.1:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
    );
    if store.settings.enable_ipv6 {
        let _ = writeln!(
            out,
            "        meta l4proto {{ tcp, udp }} tproxy ip6 to [::1]:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
        );
    }

    let _ = writeln!(out, "    }}");

    // Router-originated traffic (`OUTPUT` hook): prevent loops via `BYPASS_FWMARK`,
    // always intercept router FakeIP connections so local checks/tools work, and optionally
    // intercept all non-local router traffic when `route_router_traffic` is enabled.
    let bypass_ifaces_literal = collect_tailscale_bypass_ifaces(store)
        .into_iter()
        .map(|i| format!("\"{i}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let _ = writeln!(
        out,
        "    chain mangle_output {{
        type route hook output priority mangle; policy accept;
        oifname {{ {bypass_ifaces_literal} }} return
        meta mark & {BYPASS_FWMARK} == {BYPASS_FWMARK} return
        meta mark & 0x14000000 != 0 return
        meta mark & 0x00ff0000 == {TAILSCALE_TUNNEL_BYPASS_MARK_MASK} return
        meta mark & 0x00ff0000 == {TAILSCALE_DAEMON_BYPASS_MARK} return
        meta mark & 0x00ff0000 == {FPTN_TUNNEL_BYPASS_MARK} return"
    );
    if intercept_embedded_ts {
        let _ = writeln!(
            out,
            "        ip daddr 100.64.0.0/10 meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
        );
    }
    let _ = writeln!(out, "        ip daddr @localv4 return");
    if !fptn_ips.is_empty() {
        let _ = writeln!(out, "        ip daddr {{ {} }} return", fptn_ips.join(", "));
    }
    if store.settings.exclude_ntp {
        let _ = writeln!(out, "        udp dport 123 return");
    }
    if store.settings.torrserver_direct_enabled && !store.settings.torrserver_ports.is_empty() {
        let ports: Vec<String> = store
            .settings
            .torrserver_ports
            .iter()
            .map(u16::to_string)
            .collect();
        let _ = writeln!(
            out,
            "        meta l4proto {{ tcp, udp }} th dport {{ {} }} return",
            ports.join(", ")
        );
    }
    let _ = writeln!(
        out,
        "        ip daddr {fakeip_v4} meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
    );
    if store.settings.enable_ipv6 {
        let _ = writeln!(
            out,
            "        ip6 daddr {fakeip_v6} meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
        );
        if intercept_embedded_ts {
            let _ = writeln!(
                out,
                "        ip6 daddr fd7a:115c:a1e0::/48 meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
            );
        }
        let _ = writeln!(out, "        ip6 daddr @localv6 return");
    }
    if store.settings.route_router_traffic {
        if store.settings.disable_quic {
            let _ = writeln!(out, "        udp dport 443 reject");
        }
        if store.settings.block_doh {
            let _ = writeln!(
                out,
                "        ip daddr {{ 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9 }} tcp dport {{ 443, 853 }} reject"
            );
        }
        let _ = writeln!(
            out,
            "        meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
        );
    }
    let _ = writeln!(out, "    }}");

    let _ = writeln!(out, "}}");
    out
}

async fn run_checked_ip(args: &[&str]) -> anyhow::Result<()> {
    let out = Command::new("ip").args(args).output().await?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("ip {} failed: {}", args.join(" "), err.trim());
    }
    Ok(())
}

async fn del_ip_rule_all(ip6: bool, args: &[&str]) {
    for _ in 0..8 {
        let mut full_args: Vec<&str> = Vec::with_capacity(args.len() + 3);
        if ip6 {
            full_args.push("-6");
        }
        full_args.push("rule");
        full_args.push("del");
        full_args.extend_from_slice(args);
        let ok = Command::new("ip")
            .args(&full_args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success());
        if !ok {
            break;
        }
    }
}

pub fn collect_dnsmasq_conf_dirs_in(tmp_root: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(entries) = std::fs::read_dir(tmp_root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            let is_instance_dir = name == "dnsmasq.d"
                || (name.starts_with("dnsmasq.")
                    && name.ends_with(".d")
                    && name.len() > "dnsmasq..d".len());
            if is_instance_dir {
                dirs.push(path);
            }
        }
    }
    dirs.sort();
    if dirs.is_empty() {
        dirs.push(tmp_root.join("dnsmasq.d"));
    }
    dirs
}

fn json_contains_tailscale_type(raw: &str) -> bool {
    let trimmed = raw.trim();
    if trimmed.is_empty() || !trimmed.to_ascii_lowercase().contains("tailscale") {
        return false;
    }
    let Ok(parsed) = serde_json::from_str::<serde_json::Value>(trimmed) else {
        return false;
    };
    fn value_has_tailscale_type(v: &serde_json::Value) -> bool {
        match v {
            serde_json::Value::Object(map) => {
                if map
                    .get("type")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|t| t.trim().eq_ignore_ascii_case("tailscale"))
                {
                    return true;
                }
                for key in ["endpoints", "outbounds"] {
                    if let Some(arr) = map.get(key).and_then(serde_json::Value::as_array)
                        && arr.iter().any(value_has_tailscale_type)
                    {
                        return true;
                    }
                }
                false
            }
            serde_json::Value::Array(arr) => arr.iter().any(value_has_tailscale_type),
            _ => false,
        }
    }
    value_has_tailscale_type(&parsed)
}

pub fn embedded_tailscale_enabled(store: &RouterStoreData) -> bool {
    if store.servers.iter().any(|s| {
        s.enabled && (s.is_embedded_tailscale() || json_contains_tailscale_type(&s.inbound_json))
    }) {
        return true;
    }
    if store
        .sections
        .iter()
        .any(|s| s.enabled && s.is_embedded_tailscale())
    {
        return true;
    }
    store.outbound_sources.iter().any(|src| {
        src.enabled
            && (src.is_embedded_tailscale()
                || src
                    .proxy_links
                    .iter()
                    .any(|u| u.trim().to_ascii_lowercase().starts_with("tailscale://"))
                || json_contains_tailscale_type(&src.custom_json))
    })
}

pub fn native_tailscale_enabled(store: &RouterStoreData) -> bool {
    if store
        .servers
        .iter()
        .any(|s| s.enabled && s.is_native_tailscale())
        || store
            .sections
            .iter()
            .any(|s| s.enabled && s.is_native_tailscale())
        || store
            .outbound_sources
            .iter()
            .any(|s| s.enabled && s.is_native_tailscale())
    {
        return true;
    }
    store.settings.tailscale_enabled && !embedded_tailscale_enabled(store)
}

pub fn native_tailscale_magicdns_enabled(store: &RouterStoreData) -> bool {
    if !native_tailscale_enabled(store) {
        return false;
    }
    let any_native_accept = store
        .servers
        .iter()
        .any(|s| s.enabled && s.is_native_tailscale() && s.tailscale_accept_dns)
        || store
            .sections
            .iter()
            .any(|s| s.enabled && s.is_native_tailscale() && s.tailscale_accept_dns)
        || store
            .outbound_sources
            .iter()
            .any(|s| s.enabled && s.is_native_tailscale() && s.tailscale_accept_dns);
    if any_native_accept {
        return true;
    }
    let any_native_node = store
        .servers
        .iter()
        .any(|s| s.enabled && s.is_native_tailscale())
        || store
            .sections
            .iter()
            .any(|s| s.enabled && s.is_native_tailscale())
        || store
            .outbound_sources
            .iter()
            .any(|s| s.enabled && s.is_native_tailscale());
    !any_native_node && store.settings.tailscale_enabled
}

pub fn is_tailscale_enabled(store: &RouterStoreData) -> bool {
    native_tailscale_enabled(store) || embedded_tailscale_enabled(store)
}

fn collect_tailscale_bypass_ifaces(store: &RouterStoreData) -> Vec<String> {
    let mut ifaces = vec![
        "tailscale0".to_string(),
        "fptn0".to_string(),
        "tun-fptn*".to_string(),
    ];
    let mut push_iface = |enabled: bool, sys_iface: bool, raw_name: &str| {
        if !enabled || !sys_iface {
            return;
        }
        if let Some(clean) = sanitize_iface_name(raw_name)
            && !ifaces.iter().any(|existing| existing == &clean)
        {
            ifaces.push(clean);
        }
    };
    for srv in &store.servers {
        push_iface(
            srv.enabled && srv.is_embedded_tailscale(),
            srv.tailscale_system_interface,
            &srv.tailscale_system_interface_name,
        );
    }
    for sec in &store.sections {
        push_iface(
            sec.enabled && sec.is_embedded_tailscale(),
            sec.tailscale_system_interface,
            &sec.tailscale_system_interface_name,
        );
    }
    for src in &store.outbound_sources {
        push_iface(
            src.enabled && src.is_embedded_tailscale(),
            src.tailscale_system_interface,
            &src.tailscale_system_interface_name,
        );
    }
    ifaces
}

async fn neutralize_standalone_tailscale_service() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    let _ = std::fs::remove_file("/tmp/resolv.conf.d/resolv.conf.tailscale");
    let init_script = Path::new("/etc/init.d/tailscale");
    if init_script.exists() {
        if crate::sys_info::find_running_process_by_name("tailscaled").is_some() {
            let _ = Command::new(init_script)
                .arg("stop")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await;
        }
        let is_enabled = Command::new(init_script)
            .arg("enabled")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success());
        if is_enabled {
            let _ = Command::new(init_script)
                .arg("disable")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await;
        }
    }
}

pub fn render_tailscale_servers_file(enabled: bool) -> String {
    if enabled {
        format!("# Managed by Tachyon Tailscale runtime\nserver=/ts.net/{TAILSCALE_MAGICDNS_IP}\n")
    } else {
        String::new()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MagicDnsFileSync {
    pub file_changed: bool,
    pub legacy_removed: bool,
}

pub fn sync_tailscale_magicdns_files_at(
    servers_file: &Path,
    legacy_conf: &Path,
    enabled: bool,
    release: bool,
    servers_file_in_use: bool,
) -> anyhow::Result<MagicDnsFileSync> {
    let legacy_removed = std::fs::remove_file(legacy_conf).is_ok();
    let mut file_changed = false;

    if enabled {
        let content = render_tailscale_servers_file(true);
        file_changed = crypto_gen::write_file_if_changed(servers_file, content.as_bytes())?;
    } else if release {
        if !servers_file_in_use
            && servers_file.exists()
            && std::fs::remove_file(servers_file).is_ok()
        {
            file_changed = true;
        }
    } else if servers_file.exists() {
        let existing = std::fs::read_to_string(servers_file).unwrap_or_default();
        if !existing.trim().is_empty() {
            file_changed = crypto_gen::write_file_if_changed(servers_file, b"")?;
        }
    }

    Ok(MagicDnsFileSync {
        file_changed,
        legacy_removed,
    })
}

fn parse_dnsmasq_section_names(uci_show_dhcp: &str) -> Vec<String> {
    let mut names = Vec::new();
    for line in uci_show_dhcp.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("dhcp.")
            && let Some(name) = rest.strip_suffix("=dnsmasq")
            && !name.is_empty()
            && !names.iter().any(|existing| existing == name)
        {
            names.push(name.to_string());
        }
    }
    names
}

async fn uci_query(args: &[&str]) -> Option<String> {
    let out = Command::new("uci")
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .await
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

async fn uci_run(args: &[&str]) -> bool {
    Command::new("uci")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

async fn discover_dnsmasq_sections() -> Vec<String> {
    if let Some(show) = uci_query(&["-q", "show", "dhcp"]).await {
        let names = parse_dnsmasq_section_names(&show);
        if !names.is_empty() {
            return names;
        }
    }
    if uci_query(&["-q", "get", "dhcp.@dnsmasq[0]"])
        .await
        .is_some_and(|v| v.trim() == "dnsmasq")
    {
        return vec!["@dnsmasq[0]".to_string()];
    }
    Vec::new()
}

async fn dnsmasq_servers_file_in_use(names: &[String], servers_file: &str) -> bool {
    for name in names {
        let key = format!("dhcp.{name}.serversfile");
        if uci_query(&["-q", "get", &key])
            .await
            .is_some_and(|v| v.trim() == servers_file)
        {
            return true;
        }
    }
    false
}

async fn claim_dnsmasq_settings(names: &[String], servers_file: &str) -> Option<bool> {
    for name in names {
        let key = format!("dhcp.{name}.serversfile");
        if let Some(current) = uci_query(&["-q", "get", &key]).await {
            let trimmed = current.trim();
            if !trimmed.is_empty() && trimmed != servers_file {
                return None;
            }
        }
    }
    let mut changed = false;
    for name in names {
        let sf_key = format!("dhcp.{name}.serversfile");
        let sf_cur = uci_query(&["-q", "get", &sf_key]).await.unwrap_or_default();
        if sf_cur.trim() != servers_file {
            uci_run(&["set", &format!("{sf_key}={servers_file}")]).await;
            uci_run(&["set", &format!("dhcp.{name}.tachyon_serversfile=1")]).await;
            changed = true;
        }

        let ls_key = format!("dhcp.{name}.localservice");
        let ls_cur = uci_query(&["-q", "get", &ls_key])
            .await
            .map(|v| v.trim().to_string())
            .unwrap_or_default();
        if ls_cur != "0" {
            let marker_key = format!("dhcp.{name}.tachyon_localservice");
            let marker_cur = uci_query(&["-q", "get", &marker_key])
                .await
                .unwrap_or_default();
            if marker_cur.trim().is_empty() {
                let saved = if ls_cur.is_empty() {
                    "unset"
                } else {
                    ls_cur.as_str()
                };
                uci_run(&["set", &format!("{marker_key}={saved}")]).await;
            }
            uci_run(&["set", &format!("{ls_key}=0")]).await;
            changed = true;
        }
    }
    if changed {
        uci_run(&["commit", "dhcp"]).await;
    }
    Some(changed)
}

async fn release_dnsmasq_settings(names: &[String], servers_file: &str) -> bool {
    let mut changed = false;
    for name in names {
        let t_sf_key = format!("dhcp.{name}.tachyon_serversfile");
        let t_sf = uci_query(&["-q", "get", &t_sf_key])
            .await
            .unwrap_or_default();
        if !t_sf.trim().is_empty() {
            let sf_key = format!("dhcp.{name}.serversfile");
            if uci_query(&["-q", "get", &sf_key])
                .await
                .is_some_and(|v| v.trim() == servers_file)
            {
                uci_run(&["-q", "delete", &sf_key]).await;
            }
            uci_run(&["-q", "delete", &t_sf_key]).await;
            changed = true;
        }

        let marker_key = format!("dhcp.{name}.tachyon_localservice");
        let saved = uci_query(&["-q", "get", &marker_key])
            .await
            .map(|v| v.trim().to_string())
            .unwrap_or_default();
        if !saved.is_empty() {
            let ls_key = format!("dhcp.{name}.localservice");
            if uci_query(&["-q", "get", &ls_key])
                .await
                .is_some_and(|v| v.trim() == "0")
            {
                if saved == "unset" {
                    uci_run(&["-q", "delete", &ls_key]).await;
                } else {
                    uci_run(&["set", &format!("{ls_key}={saved}")]).await;
                }
            }
            uci_run(&["-q", "delete", &marker_key]).await;
            changed = true;
        }
    }
    if changed {
        uci_run(&["commit", "dhcp"]).await;
    }
    changed
}

async fn run_dnsmasq_init(action: &str) {
    let _ = Command::new("/etc/init.d/dnsmasq")
        .arg(action)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await;
}

async fn sync_tailscale_magicdns(enabled: bool, release: bool) {
    let servers_file = Path::new(TAILSCALE_MAGICDNS_SERVERS_FILE);
    let legacy_conf = Path::new(TAILSCALE_LEGACY_DNSMASQ_CONF);
    let sections = discover_dnsmasq_sections().await;

    if enabled {
        let file_sync =
            sync_tailscale_magicdns_files_at(servers_file, legacy_conf, true, false, false)
                .unwrap_or(MagicDnsFileSync {
                    file_changed: false,
                    legacy_removed: false,
                });
        match claim_dnsmasq_settings(&sections, TAILSCALE_MAGICDNS_SERVERS_FILE).await {
            Some(uci_changed) => {
                if file_sync.legacy_removed {
                    run_dnsmasq_init("restart").await;
                } else if file_sync.file_changed || uci_changed {
                    run_dnsmasq_init("reload").await;
                }
            }
            None => {
                eprintln!(
                    "MagicDNS for *.ts.net skipped: dnsmasq already uses a custom serversfile"
                );
                if !dnsmasq_servers_file_in_use(&sections, TAILSCALE_MAGICDNS_SERVERS_FILE).await {
                    let _ = std::fs::remove_file(servers_file);
                }
                if file_sync.legacy_removed {
                    run_dnsmasq_init("restart").await;
                }
            }
        }
        return;
    }

    let uci_changed = if release {
        release_dnsmasq_settings(&sections, TAILSCALE_MAGICDNS_SERVERS_FILE).await
    } else {
        false
    };
    let in_use = if release {
        dnsmasq_servers_file_in_use(&sections, TAILSCALE_MAGICDNS_SERVERS_FILE).await
    } else {
        true
    };
    let file_sync =
        sync_tailscale_magicdns_files_at(servers_file, legacy_conf, false, release, in_use)
            .unwrap_or(MagicDnsFileSync {
                file_changed: false,
                legacy_removed: false,
            });

    if file_sync.legacy_removed {
        run_dnsmasq_init("restart").await;
    } else if file_sync.file_changed || uci_changed {
        run_dnsmasq_init("reload").await;
    }
}

pub fn legacy_policy_cleanup_specs() -> &'static [(bool, &'static [&'static str])] {
    &[
        (
            false,
            &["iif", "lo", "fwmark", TPROXY_FWMARK, "table", "main"],
        ),
        (
            false,
            &["iif", "lo", "fwmark", TPROXY_FWMARK_MASKED, "table", "main"],
        ),
        (
            false,
            &["fwmark", TPROXY_FWMARK, "table", TPROXY_ROUTE_TABLE],
        ),
        (
            false,
            &["fwmark", TPROXY_FWMARK_MASKED, "table", TPROXY_ROUTE_TABLE],
        ),
        (
            false,
            &["fwmark", ROUTER_TPROXY_FWMARK, "table", TPROXY_ROUTE_TABLE],
        ),
        (
            false,
            &[
                "fwmark",
                ROUTER_TPROXY_FWMARK_MASKED,
                "table",
                TPROXY_ROUTE_TABLE,
            ],
        ),
        (false, &["fwmark", TPROXY_FWMARK, "table", "tachyon"]),
        (false, &["fwmark", TPROXY_FWMARK_MASKED, "table", "tachyon"]),
        (false, &["fwmark", ROUTER_TPROXY_FWMARK, "table", "tachyon"]),
        (
            false,
            &["fwmark", ROUTER_TPROXY_FWMARK_MASKED, "table", "tachyon"],
        ),
        (
            true,
            &["fwmark", TPROXY_FWMARK, "table", TPROXY_ROUTE_TABLE],
        ),
        (
            true,
            &["fwmark", TPROXY_FWMARK_MASKED, "table", TPROXY_ROUTE_TABLE],
        ),
        (
            true,
            &["fwmark", ROUTER_TPROXY_FWMARK, "table", TPROXY_ROUTE_TABLE],
        ),
        (
            true,
            &[
                "fwmark",
                ROUTER_TPROXY_FWMARK_MASKED,
                "table",
                TPROXY_ROUTE_TABLE,
            ],
        ),
        (true, &["fwmark", TPROXY_FWMARK, "table", "tachyon"]),
        (true, &["fwmark", TPROXY_FWMARK_MASKED, "table", "tachyon"]),
        (true, &["fwmark", ROUTER_TPROXY_FWMARK, "table", "tachyon"]),
        (
            true,
            &["fwmark", ROUTER_TPROXY_FWMARK_MASKED, "table", "tachyon"],
        ),
    ]
}

async fn cleanup_policy_rules() {
    for &(ipv6, args) in legacy_policy_cleanup_specs() {
        del_ip_rule_all(ipv6, args).await;
    }
}

/// Apply `inet TachyonTable` atomically via `nft -f -` and configure `ip rule` / `ip route`.
pub async fn apply_network_stack(store: &RouterStoreData) -> anyhow::Result<()> {
    if cfg!(not(target_os = "linux")) || store.settings.proxy_mode == "socks" {
        return Ok(());
    }

    let intercept_embedded_ts =
        embedded_tailscale_enabled(store) && !native_tailscale_enabled(store);

    if store.settings.proxy_mode == "tproxy" {
        if intercept_embedded_ts {
            neutralize_standalone_tailscale_service().await;
        }
        let ruleset = compile_nftables_ruleset(store);
        let mut child = Command::new("nft")
            .arg("-f")
            .arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(ruleset.as_bytes()).await?;
        }
        let out = child.wait_with_output().await?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            anyhow::bail!("nft apply failed: {}", err.trim());
        }

        // Clean stale or duplicate policy rules (including `table tachyon`) before adding ours.
        cleanup_policy_rules().await;

        // Rule pref 99 answers reverse-path `iif lo` checks for LAN packets (`0x04000000`)
        // from `main` when `net.ipv4.conf.all.src_valid_mark=1` (e.g. Tailscale netfilter mode).
        run_checked_ip(&[
            "rule",
            "add",
            "iif",
            "lo",
            "fwmark",
            TPROXY_FWMARK,
            "table",
            "main",
            "pref",
            "99",
        ])
        .await?;
        run_checked_ip(&[
            "rule",
            "add",
            "fwmark",
            TPROXY_FWMARK,
            "table",
            TPROXY_ROUTE_TABLE,
            "pref",
            "100",
        ])
        .await?;
        run_checked_ip(&[
            "rule",
            "add",
            "fwmark",
            ROUTER_TPROXY_FWMARK,
            "table",
            TPROXY_ROUTE_TABLE,
            "pref",
            "101",
        ])
        .await?;
        run_checked_ip(&[
            "route",
            "replace",
            "local",
            "0.0.0.0/0",
            "dev",
            "lo",
            "table",
            TPROXY_ROUTE_TABLE,
        ])
        .await?;
        if store.settings.enable_ipv6 {
            let _ = run_checked_ip(&[
                "-6",
                "rule",
                "add",
                "fwmark",
                TPROXY_FWMARK,
                "table",
                TPROXY_ROUTE_TABLE,
                "pref",
                "100",
            ])
            .await;
            let _ = run_checked_ip(&[
                "-6",
                "rule",
                "add",
                "fwmark",
                ROUTER_TPROXY_FWMARK,
                "table",
                TPROXY_ROUTE_TABLE,
                "pref",
                "101",
            ])
            .await;
            let _ = run_checked_ip(&[
                "-6",
                "route",
                "replace",
                "local",
                "::/0",
                "dev",
                "lo",
                "table",
                TPROXY_ROUTE_TABLE,
            ])
            .await;
        }
    }

    if !store.settings.dont_touch_dhcp {
        let dnsmasq_conf = "no-resolv\nserver=127.0.0.42#53\n";
        let mut dnsmasq_changed = false;
        for dir in collect_dnsmasq_conf_dirs_in(Path::new("/tmp")) {
            let conf_path = dir.join("tachyon.conf");
            if crypto_gen::write_file_if_changed(&conf_path, dnsmasq_conf.as_bytes())
                .unwrap_or(false)
            {
                dnsmasq_changed = true;
            }
        }
        if dnsmasq_changed {
            run_dnsmasq_init("reload").await;
        }
        if intercept_embedded_ts {
            let _ = std::fs::remove_file("/tmp/resolv.conf.d/resolv.conf.tailscale");
            sync_tailscale_magicdns(false, true).await;
        } else {
            let ts_dns = native_tailscale_magicdns_enabled(store);
            sync_tailscale_magicdns(ts_dns, !ts_dns).await;
        }
    }

    #[cfg(unix)]
    if store.settings.enable_yacd
        && std::path::Path::new("/etc/tachyon-core/ui").exists()
        && !std::path::Path::new("/www/yacd").exists()
    {
        let _ = std::os::unix::fs::symlink("/etc/tachyon-core/ui", "/www/yacd");
    }

    apply_tcp_profile(&store.settings.tcp_profile).await;
    apply_sqm_qdisc(store).await;

    Ok(())
}

async fn apply_tcp_profile(profile: &str) {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    let pairs: &[(&str, &str)] = match profile.trim().to_ascii_lowercase().as_str() {
        "bbr" => &[
            ("net.core.default_qdisc", "fq"),
            ("net.ipv4.tcp_congestion_control", "bbr"),
            ("net.ipv4.tcp_fastopen", "3"),
        ],
        "low_latency" => &[
            ("net.ipv4.tcp_fastopen", "3"),
            ("net.ipv4.tcp_slow_start_after_idle", "0"),
            ("net.ipv4.tcp_notsent_lowat", "16384"),
        ],
        "throughput" => &[
            ("net.core.rmem_max", "4194304"),
            ("net.core.wmem_max", "4194304"),
            ("net.ipv4.tcp_fastopen", "3"),
        ],
        _ => return,
    };
    for (k, v) in pairs {
        let _ = Command::new("sysctl")
            .args(["-w", &format!("{k}={v}")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    }
}

const SQM_MARKER_PATH: &str = "/tmp/tachyon-sqm-iface";

fn sanitize_iface_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 32 {
        return None;
    }
    if trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
    {
        Some(trimmed.to_string())
    } else {
        None
    }
}

async fn apply_sqm_qdisc(store: &RouterStoreData) {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    if !store.settings.smart_queue {
        teardown_sqm_qdisc().await;
        return;
    }
    let Some(iface) = sanitize_iface_name(&store.settings.sqm_interface) else {
        return;
    };

    let mut applied = false;
    if store.settings.sqm_upload_kbps > 0 {
        let bw = format!("{}kbit", store.settings.sqm_upload_kbps);
        applied = Command::new("tc")
            .args([
                "qdisc",
                "replace",
                "dev",
                &iface,
                "root",
                "cake",
                "bandwidth",
                &bw,
                "besteffort",
                "nat",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success());
    }
    if !applied {
        applied = Command::new("tc")
            .args(["qdisc", "replace", "dev", &iface, "root", "fq_codel"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|s| s.success());
    }
    if applied {
        let _ = crypto_gen::write_file_if_changed(SQM_MARKER_PATH, iface.as_bytes());
    }
}

async fn teardown_sqm_qdisc() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    if let Ok(prev) = std::fs::read_to_string(SQM_MARKER_PATH) {
        if let Some(iface) = sanitize_iface_name(&prev) {
            let _ = Command::new("tc")
                .args(["qdisc", "del", "dev", &iface, "root"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await;
        }
        let _ = std::fs::remove_file(SQM_MARKER_PATH);
    }
}

/// Remove `inet TachyonTable`, policy routing rules and dnsmasq drop-in cleanly.
pub async fn teardown_network_stack() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    let _ = Command::new("nft")
        .args(["delete", "table", "inet", "TachyonTable"])
        .status()
        .await;
    cleanup_policy_rules().await;
    let mut dnsmasq_changed = false;
    for dir in collect_dnsmasq_conf_dirs_in(Path::new("/tmp")) {
        if std::fs::remove_file(dir.join("tachyon.conf")).is_ok() {
            dnsmasq_changed = true;
        }
    }
    if dnsmasq_changed {
        run_dnsmasq_init("reload").await;
    }
    sync_tailscale_magicdns(false, false).await;
    teardown_sqm_qdisc().await;
}

/// Check if `table inet TachyonTable` is currently loaded in the kernel.
pub async fn check_nft_table_active() -> bool {
    if cfg!(not(target_os = "linux")) {
        return true;
    }
    Command::new("nft")
        .args(["list", "table", "inet", "TachyonTable"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_collect_dnsmasq_conf_dirs_includes_instance_dirs_and_fallback() {
        let base = std::env::temp_dir().join(format!(
            "tachyon_dnsmasq_dirs_{}",
            crate::store::unix_now_secs()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).expect("create base");

        let fallback = collect_dnsmasq_conf_dirs_in(&base);
        assert_eq!(fallback, vec![base.join("dnsmasq.d")]);

        std::fs::create_dir_all(base.join("dnsmasq.d")).expect("default dir");
        std::fs::create_dir_all(base.join("dnsmasq.cfg01411c.d")).expect("instance dir");
        std::fs::create_dir_all(base.join("dnsmasq..d")).expect("invalid empty dir");
        std::fs::create_dir_all(base.join("other.d")).expect("unrelated dir");

        let discovered = collect_dnsmasq_conf_dirs_in(&base);
        assert_eq!(
            discovered,
            vec![base.join("dnsmasq.cfg01411c.d"), base.join("dnsmasq.d")]
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn test_legacy_policy_cleanup_specs_cover_masked_and_tachyon_table() {
        let specs = legacy_policy_cleanup_specs();
        assert!(specs.iter().any(|(v6, args)| !v6
            && args.contains(&TPROXY_FWMARK_MASKED)
            && args.contains(&TPROXY_ROUTE_TABLE)));
        assert!(specs.iter().any(|(v6, args)| !v6
            && args.contains(&ROUTER_TPROXY_FWMARK_MASKED)
            && args.contains(&"tachyon")));
        assert!(specs.iter().any(|(v6, args)| *v6
            && args.contains(&TPROXY_FWMARK_MASKED)
            && args.contains(&"tachyon")));
        assert!(specs.iter().any(|(v6, args)| !v6
            && args.contains(&"iif")
            && args.contains(&"lo")
            && args.contains(&TPROXY_FWMARK_MASKED)
            && args.contains(&"main")));
    }

    #[test]
    fn test_tailscale_magicdns_servers_file_lifecycle() {
        let base =
            std::env::temp_dir().join(format!("tachyon_ts_dns_{}", crate::store::unix_now_secs()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).expect("create base");

        let servers_file = base.join("dnsmasq-tailscale.servers");
        let legacy_conf = base.join("tachyon-tailscale.conf");
        std::fs::write(&legacy_conf, "server=/ts.net/100.100.100.100\n").expect("legacy");

        let on = sync_tailscale_magicdns_files_at(&servers_file, &legacy_conf, true, false, false)
            .expect("enable");
        assert!(on.file_changed);
        assert!(on.legacy_removed);
        assert!(!legacy_conf.exists());
        let text = std::fs::read_to_string(&servers_file).expect("read servers file");
        assert!(text.contains("server=/ts.net/100.100.100.100"));

        // Stop (release=false) empties file without deleting it so SIGHUP suffices
        let stop =
            sync_tailscale_magicdns_files_at(&servers_file, &legacy_conf, false, false, true)
                .expect("stop");
        assert!(stop.file_changed);
        assert!(servers_file.exists());
        assert_eq!(std::fs::read_to_string(&servers_file).unwrap(), "");

        // Second stop is a no-op
        let stop_again =
            sync_tailscale_magicdns_files_at(&servers_file, &legacy_conf, false, false, true)
                .expect("stop again");
        assert!(!stop_again.file_changed);

        // Full release deletes the file when no longer referenced
        let rel = sync_tailscale_magicdns_files_at(&servers_file, &legacy_conf, false, true, false)
            .expect("release");
        assert!(rel.file_changed);
        assert!(!servers_file.exists());

        let sections = parse_dnsmasq_section_names(
            "dhcp.cfg01411c=dnsmasq\ndhcp.lan=dhcp\ndhcp.cfg02411c=dnsmasq\n",
        );
        assert_eq!(sections, vec!["cfg01411c", "cfg02411c"]);

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn test_compile_nftables_ruleset_clean_tproxy() {
        let mut store = RouterStoreData::default();
        store.settings.disable_quic = true;
        store.settings.torrserver_direct_enabled = true;
        let nft = compile_nftables_ruleset(&store);
        assert!(nft.contains("table inet TachyonTable"));
        assert!(nft.contains("tproxy ip to 127.0.0.1:1602 meta mark set 0x04000000 accept"));
        assert!(nft.contains("udp dport 443 reject"));
        assert!(nft.contains("th dport { 8090 } return"));
        assert!(nft.contains("chain mangle_output"));
        assert!(nft.contains("iifname \"lo\" meta mark != 0x10000000 return"));
        assert!(nft.contains("meta mark & 0x14000000 != 0 return"));
        assert!(nft.contains(
            "ip daddr 198.18.0.0/15 meta l4proto { tcp, udp } meta mark set 0x10000000 accept"
        ));
        assert!(!nft.contains("socket transparent"));
        assert!(!nft.contains("queue num"));
    }

    #[test]
    fn test_compile_nftables_router_traffic_and_ipv6_marks() {
        let mut store = RouterStoreData::default();
        store.settings.route_router_traffic = true;
        store.settings.enable_ipv6 = true;
        let nft = compile_nftables_ruleset(&store);
        assert!(nft.contains("iifname \"lo\" meta mark != 0x10000000 return"));
        assert!(nft.contains("meta mark & 0x14000000 != 0 return"));
        assert!(nft.contains("tproxy ip6 to [::1]:1602 meta mark set 0x04000000 accept"));
        assert!(nft.contains(
            "ip6 daddr fc00::/18 meta l4proto { tcp, udp } meta mark set 0x10000000 accept"
        ));
        assert!(
            nft.contains("\n        meta l4proto { tcp, udp } meta mark set 0x10000000 accept\n")
        );
    }

    #[test]
    fn test_compile_nftables_guest_isolation_and_shaping() {
        let mut store = RouterStoreData::default();
        store.guest_mode.enabled = true;
        store.guest_mode.guest_devices = vec!["192.168.4.10".to_string()];
        store.guest_mode.isolate_lan = true;
        store.guest_mode.block_router_admin = true;
        store.guest_mode.allowed_ports = vec![80, 443];
        store.guest_mode.bandwidth_limit_mbps = 8;
        let nft = compile_nftables_ruleset(&store);
        assert!(nft.contains("th dport { 22, 80, 443, 1680, 9090 } drop"));
        assert!(nft.contains("th dport != 53 drop"));
        assert!(nft.contains("th dport != { 53, 80, 443 } drop"));
        assert!(nft.contains("limit rate over 1000 kbytes/second drop"));
    }

    #[test]
    fn test_compile_nftables_fptn_and_tailscale_loop_protection() {
        let mut store = RouterStoreData::default();
        store.sections[0].fptn_preferred_server = "198.51.100.77".to_string();
        let nft = compile_nftables_ruleset(&store);
        assert!(nft.contains("iifname { \"tailscale0\", \"fptn0\", \"tun-fptn*\" } return"));
        assert!(nft.contains("meta mark & 0x00ff0000 == 0x00340000 return"));
        assert!(nft.contains("meta mark & 0x00ff0000 == 0x00080000 return"));
        assert!(nft.contains("meta mark & 0x00ff0000 == 0x00300000 return"));
        assert!(nft.contains("ip daddr { 198.51.100.77 } return"));
    }

    #[test]
    fn test_compile_nftables_tailscale_cgnat_ula_before_local_returns() {
        let mut store = RouterStoreData::default();
        store.settings.enable_ipv6 = true;
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "ts1".to_string(),
            enabled: true,
            source_type: "tailscale".to_string(),
            tailscale_mode: "singbox".to_string(),
            ..Default::default()
        });

        let nft = compile_nftables_ruleset(&store);
        let pre_start = nft
            .find("chain prerouting")
            .expect("chain prerouting must exist");
        let out_start = nft
            .find("chain mangle_output")
            .expect("chain mangle_output must exist");
        let prerouting = &nft[pre_start..out_start];
        let mangle_output = &nft[out_start..];

        let pre_cgnat = prerouting
            .find("ip daddr 100.64.0.0/10 meta l4proto")
            .expect("prerouting CGNAT intercept rule");
        let pre_localv4 = prerouting
            .find("ip daddr @localv4 return")
            .expect("prerouting @localv4 return");
        assert!(pre_cgnat < pre_localv4);

        let pre_ula = prerouting
            .find("ip6 daddr fd7a:115c:a1e0::/48 meta l4proto")
            .expect("prerouting ULA intercept rule");
        let pre_localv6 = prerouting
            .find("ip6 daddr @localv6")
            .expect("prerouting @localv6 return");
        assert!(pre_ula < pre_localv6);

        let out_cgnat = mangle_output
            .find("ip daddr 100.64.0.0/10 meta l4proto")
            .expect("mangle_output CGNAT intercept rule");
        let out_localv4 = mangle_output
            .find("ip daddr @localv4 return")
            .expect("mangle_output @localv4 return");
        assert!(out_cgnat < out_localv4);
        assert!(
            mangle_output.contains(&format!(
                "ip daddr 100.64.0.0/10 meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
            ))
        );

        let out_ula = mangle_output
            .find("ip6 daddr fd7a:115c:a1e0::/48 meta l4proto")
            .expect("mangle_output ULA intercept rule");
        let out_localv6 = mangle_output
            .find("ip6 daddr @localv6 return")
            .expect("mangle_output @localv6 return");
        assert!(out_ula < out_localv6);

        store
            .outbound_sources
            .last_mut()
            .expect("ts1 source")
            .tailscale_mode = "native".to_string();
        let native_nft = compile_nftables_ruleset(&store);
        assert!(!native_nft.contains("ip daddr 100.64.0.0/10 meta l4proto"));
        assert!(!native_nft.contains("ip6 daddr fd7a:115c:a1e0::/48 meta l4proto"));
        assert!(native_nft.contains("\"tailscale0\""));
    }
}
