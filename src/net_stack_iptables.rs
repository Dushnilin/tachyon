//! Universal `iptables` + `ipset` network stack driver for Entware targets
//! (Keenetic NDMS, Asuswrt-Merlin, Padavan, and generic Linux/Entware routers).
//!
//! - Uses atomic `ipset restore -!` staging (`<set>_tmp` -> `swap` -> `destroy`) to prevent
//!   traffic gaps and memory spikes on 128-256 MiB routers.
//! - Uses `iptables-restore --noflush` / `ip6tables-restore --noflush` with dedicated
//!   `TACHYON_*` chains so firmware-owned chains (NDM / Merlin / Padavan) remain untouched.
//! - Manages jump hooks idempotently (`-C ... || -I ... 1`) and cleans all chains, sets,
//!   and policy routing rules cleanly on teardown.

use std::fmt::Write as _;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::net_stack::{
    BYPASS_FWMARK, DIRECT_PROBE_SKGID, FPTN_TUNNEL_BYPASS_MARK, ROUTER_TPROXY_FWMARK,
    ROUTER_TPROXY_FWMARK_MASKED, TAILSCALE_DAEMON_BYPASS_MARK, TPROXY_FWMARK, TPROXY_FWMARK_MASKED,
    TPROXY_PORT, TPROXY_ROUTE_TABLE, TPROXY6_LISTEN_ADDR, cleanup_policy_rules,
    cleanup_policy_rules_for, collect_bypass_macs, collect_managed_lan_ifaces,
    collect_parental_blocked_macs, collect_proxy_udp_ports, collect_router_admin_ports,
    collect_tailscale_bypass_ifaces, direct_fallback_veto, embedded_tailscale_enabled,
    ensure_bridge_netfilter_disabled, format_guest_allowed_ports, guest_mode_has_active_rules,
    has_source_aware_dns, is_guest_mode_zero_trust, kill_switch_source_interfaces,
    native_tailscale_enabled, parse_guest_device_buckets, run_checked_ip, run_status_with_timeout,
    sanitize_iface_name, try_modprobe_quiet,
};
use crate::store::RouterStoreData;

pub const IPSET_LOCAL_V4: &str = "tachyon_local_v4";
pub const IPSET_EXCL_SRC_V4: &str = "tachyon_excl_src_v4";
pub const IPSET_EXCL_MAC: &str = "tachyon_excl_mac";
pub const IPSET_LOCAL_V6: &str = "tachyon_local_v6";
pub const IPSET_EXCL_SRC_V6: &str = "tachyon_excl_src_v6";

const IPTABLES_BIN_CANDIDATES: &[&str] = &[
    "/usr/sbin/iptables",
    "/sbin/iptables",
    "/opt/sbin/iptables-legacy",
    "/opt/sbin/iptables",
    "/opt/bin/iptables",
];
const IP6TABLES_BIN_CANDIDATES: &[&str] = &[
    "/usr/sbin/ip6tables",
    "/sbin/ip6tables",
    "/opt/sbin/ip6tables-legacy",
    "/opt/sbin/ip6tables",
    "/opt/bin/ip6tables",
];
const IPTABLES_RESTORE_CANDIDATES: &[&str] = &[
    "/usr/sbin/iptables-restore",
    "/sbin/iptables-restore",
    "/opt/sbin/iptables-legacy-restore",
    "/opt/sbin/iptables-restore",
    "/opt/bin/iptables-restore",
];
const IP6TABLES_RESTORE_CANDIDATES: &[&str] = &[
    "/usr/sbin/ip6tables-restore",
    "/sbin/ip6tables-restore",
    "/opt/sbin/ip6tables-legacy-restore",
    "/opt/sbin/ip6tables-restore",
    "/opt/bin/ip6tables-restore",
];
const IPSET_BIN_CANDIDATES: &[&str] = &[
    "/usr/sbin/ipset",
    "/sbin/ipset",
    "/opt/sbin/ipset",
    "/opt/bin/ipset",
];

const LOCAL_CIDRS_V4: &[&str] = &[
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
];
const LOCAL_CIDRS_V6: &[&str] = &[
    "::1/128",
    "64:ff9b::/96",
    "100::/64",
    "2001:db8::/32",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
];

const DOH_IPS_V4: &[&str] = &["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9"];
const DOH_IPS_V6: &[&str] = &[
    "2606:4700:4700::1111",
    "2606:4700:4700::1001",
    "2001:4860:4860::8888",
    "2001:4860:4860::8844",
    "2620:fe::fe",
    "2620:fe::9",
];

const CMD_TIMEOUT: Duration = Duration::from_secs(8);

/// Detected kernel and userspace networking capabilities on Entware routers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntwareNetCaps {
    pub has_iptables: bool,
    pub has_ip6tables: bool,
    pub has_iptables_restore: bool,
    pub has_ipset: bool,
    pub has_tproxy: bool,
    pub has_socket_match: bool,
    pub has_tun: bool,
    pub has_owner: bool,
    pub has_addrtype: bool,
    pub has_conntrack: bool,
    pub has_multiport: bool,
    pub has_mac: bool,
    pub has_set: bool,
    pub has_limit: bool,
    pub has_reject: bool,
    pub has_redirect: bool,
    pub has_masquerade: bool,
    pub iptables_bin: Option<String>,
    pub ip6tables_bin: Option<String>,
    pub iptables_restore_bin: Option<String>,
    pub ip6tables_restore_bin: Option<String>,
}

impl EntwareNetCaps {
    /// Full capability set used for deterministic preview rendering and legacy helpers.
    pub fn full_for_preview() -> Self {
        Self {
            has_iptables: true,
            has_ip6tables: true,
            has_iptables_restore: true,
            has_ipset: true,
            has_tproxy: true,
            has_socket_match: true,
            has_tun: true,
            has_owner: true,
            has_addrtype: true,
            has_conntrack: true,
            has_multiport: true,
            has_mac: true,
            has_set: true,
            has_limit: true,
            has_reject: true,
            has_redirect: true,
            has_masquerade: true,
            iptables_bin: None,
            ip6tables_bin: None,
            iptables_restore_bin: None,
            ip6tables_restore_bin: None,
        }
    }
}

/// Select the first existing binary from `candidates` in strict preference order.
pub fn select_preferred_bin(candidates: &[&str], exists: impl Fn(&str) -> bool) -> Option<String> {
    candidates
        .iter()
        .find(|&&p| exists(p))
        .map(|&p| p.to_string())
}

/// Select a matched `(iptables, iptables-restore)` binary pair from the same backend/directory
/// so system firmware `iptables` is never mixed with Entware `iptables-restore`.
pub fn select_preferred_bin_pair(
    pairs: &[(&str, &str)],
    exists: impl Fn(&str) -> bool,
) -> Option<(String, String)> {
    pairs
        .iter()
        .find(|(bin, restore)| exists(bin) && exists(restore))
        .map(|(bin, restore)| ((*bin).to_string(), (*restore).to_string()))
}

const IPTABLES_PAIR_CANDIDATES: &[(&str, &str)] = &[
    (
        "/opt/sbin/iptables-legacy",
        "/opt/sbin/iptables-legacy-restore",
    ),
    (
        "/usr/sbin/iptables-legacy",
        "/usr/sbin/iptables-legacy-restore",
    ),
    ("/sbin/iptables-legacy", "/sbin/iptables-legacy-restore"),
    ("/usr/sbin/iptables", "/usr/sbin/iptables-restore"),
    ("/sbin/iptables", "/sbin/iptables-restore"),
    ("/opt/sbin/iptables", "/opt/sbin/iptables-restore"),
    ("/opt/bin/iptables", "/opt/bin/iptables-restore"),
];
const IP6TABLES_PAIR_CANDIDATES: &[(&str, &str)] = &[
    (
        "/opt/sbin/ip6tables-legacy",
        "/opt/sbin/ip6tables-legacy-restore",
    ),
    (
        "/usr/sbin/ip6tables-legacy",
        "/usr/sbin/ip6tables-legacy-restore",
    ),
    ("/sbin/ip6tables-legacy", "/sbin/ip6tables-legacy-restore"),
    ("/usr/sbin/ip6tables", "/usr/sbin/ip6tables-restore"),
    ("/sbin/ip6tables", "/sbin/ip6tables-restore"),
    ("/opt/sbin/ip6tables", "/opt/sbin/ip6tables-restore"),
    ("/opt/bin/ip6tables", "/opt/bin/ip6tables-restore"),
];

fn find_bin_with_path_fallback(candidates: &[&str], fallback_name: &str) -> Option<String> {
    if let Some(found) = select_preferred_bin(candidates, |p| Path::new(p).is_file()) {
        return Some(found);
    }
    if let Ok(path_env) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_env) {
            let full = dir.join(fallback_name);
            if full.is_file() {
                return Some(full.to_string_lossy().into_owned());
            }
        }
    }
    None
}

fn select_iptables_pair(is_v6: bool) -> (Option<String>, Option<String>) {
    let pairs = if is_v6 {
        IP6TABLES_PAIR_CANDIDATES
    } else {
        IPTABLES_PAIR_CANDIDATES
    };
    if let Some((b, r)) = select_preferred_bin_pair(pairs, |p| Path::new(p).is_file()) {
        return (Some(b), Some(r));
    }
    let (bin_cands, res_cands, bin_fb, res_fb) = if is_v6 {
        (
            IP6TABLES_BIN_CANDIDATES,
            IP6TABLES_RESTORE_CANDIDATES,
            "ip6tables",
            "ip6tables-restore",
        )
    } else {
        (
            IPTABLES_BIN_CANDIDATES,
            IPTABLES_RESTORE_CANDIDATES,
            "iptables",
            "iptables-restore",
        )
    };
    (
        find_bin_with_path_fallback(bin_cands, bin_fb),
        find_bin_with_path_fallback(res_cands, res_fb),
    )
}

fn proc_table_contains_token(raw: &str, token: &str) -> bool {
    raw.lines().any(|line| line.trim() == token)
}

/// Pure capability parser over explicit filesystem/proc probe inputs.
#[allow(clippy::too_many_arguments)]
pub fn parse_entware_net_caps_from_signals(
    iptables_bin: Option<String>,
    ip6tables_bin: Option<String>,
    has_iptables_restore: bool,
    has_ipset: bool,
    targets_raw: &str,
    matches_raw: &str,
    has_tun: bool,
) -> EntwareNetCaps {
    let has_matches_data = !matches_raw.trim().is_empty();
    let has_targets_data = !targets_raw.trim().is_empty();
    let match_or = |tok: &str, default_if_empty: bool| -> bool {
        if has_matches_data {
            proc_table_contains_token(matches_raw, tok)
        } else {
            default_if_empty
        }
    };
    let target_or = |tok: &str, default_if_empty: bool| -> bool {
        if has_targets_data {
            proc_table_contains_token(targets_raw, tok)
        } else {
            default_if_empty
        }
    };
    EntwareNetCaps {
        has_iptables: iptables_bin.is_some(),
        has_ip6tables: ip6tables_bin.is_some(),
        has_iptables_restore,
        has_ipset,
        has_tproxy: proc_table_contains_token(targets_raw, "TPROXY"),
        has_socket_match: proc_table_contains_token(matches_raw, "socket"),
        has_tun,
        has_owner: match_or("owner", false),
        has_addrtype: match_or("addrtype", false),
        has_conntrack: match_or("conntrack", false),
        has_multiport: match_or("multiport", false),
        has_mac: match_or("mac", false),
        has_set: match_or("set", has_ipset),
        has_limit: match_or("limit", false),
        has_reject: target_or("REJECT", false),
        has_redirect: target_or("REDIRECT", false),
        has_masquerade: target_or("MASQUERADE", false),
        iptables_bin,
        ip6tables_bin,
        iptables_restore_bin: None,
        ip6tables_restore_bin: None,
    }
}

/// Probe kernel netfilter modules, `/dev/net/tun`, and `iptables`/`ipset` binaries.
pub fn probe_entware_net_caps() -> EntwareNetCaps {
    #[cfg(target_os = "linux")]
    {
        let (iptables_bin, iptables_restore_bin) = select_iptables_pair(false);
        let (ip6tables_bin, ip6tables_restore_bin) = select_iptables_pair(true);
        let has_iptables_restore = iptables_restore_bin.is_some();
        let has_ipset = find_bin_with_path_fallback(IPSET_BIN_CANDIDATES, "ipset").is_some();
        let targets_raw =
            std::fs::read_to_string("/proc/net/ip_tables_targets").unwrap_or_default();
        let matches_raw =
            std::fs::read_to_string("/proc/net/ip_tables_matches").unwrap_or_default();
        let has_tun = Path::new("/dev/net/tun").exists();
        let mut caps = parse_entware_net_caps_from_signals(
            iptables_bin,
            ip6tables_bin,
            has_iptables_restore,
            has_ipset,
            &targets_raw,
            &matches_raw,
            has_tun,
        );
        caps.iptables_restore_bin = iptables_restore_bin;
        caps.ip6tables_restore_bin = ip6tables_restore_bin;
        caps
    }
    #[cfg(not(target_os = "linux"))]
    {
        parse_entware_net_caps_from_signals(None, None, false, false, "", "", false)
    }
}

fn to_iptables_iface_pattern(raw: &str) -> String {
    if let Some(prefix) = raw.strip_suffix('*') {
        format!("{prefix}+")
    } else {
        raw.to_string()
    }
}

fn effective_entware_dns_port(store: &RouterStoreData) -> u16 {
    if store
        .settings
        .entware_dns_mode
        .trim()
        .eq_ignore_ascii_case("override")
    {
        53
    } else if store.settings.entware_dns_port > 0 {
        store.settings.entware_dns_port
    } else {
        1053
    }
}

fn split_excluded_client_entries(items: &[String]) -> (Vec<String>, Vec<String>, Vec<String>) {
    let mut v4 = Vec::new();
    let mut v6 = Vec::new();
    let mut macs = Vec::new();
    for raw in items {
        let tok = raw.trim();
        if tok.is_empty() {
            continue;
        }
        if crate::store::is_mac_address(tok) {
            let mac = tok.to_ascii_lowercase();
            if !macs.contains(&mac) {
                macs.push(mac);
            }
        } else if let Some((ip_part, prefix_part)) = tok.split_once('/') {
            if let (Ok(_), Ok(p)) = (
                ip_part.trim().parse::<std::net::Ipv4Addr>(),
                prefix_part.trim().parse::<u8>(),
            ) && p <= 32
            {
                let item = tok.to_string();
                if !v4.contains(&item) {
                    v4.push(item);
                }
            } else if let (Ok(_), Ok(p)) = (
                ip_part.trim().parse::<std::net::Ipv6Addr>(),
                prefix_part.trim().parse::<u8>(),
            ) && p <= 128
            {
                let item = tok.to_string();
                if !v6.contains(&item) {
                    v6.push(item);
                }
            }
        } else if tok.parse::<std::net::Ipv4Addr>().is_ok() {
            let item = tok.to_string();
            if !v4.contains(&item) {
                v4.push(item);
            }
        } else if tok.parse::<std::net::Ipv6Addr>().is_ok() {
            let item = tok.to_string();
            if !v6.contains(&item) {
                v6.push(item);
            }
        }
    }
    (v4, v6, macs)
}

fn append_atomic_ipset(out: &mut String, name: &str, set_type_spec: &str, entries: &[String]) {
    let tmp = format!("{name}_tmp");
    let _ = writeln!(out, "create {tmp} {set_type_spec} -exist");
    let _ = writeln!(out, "flush {tmp}");
    for entry in entries {
        let _ = writeln!(out, "add {tmp} {entry} -exist");
    }
    let _ = writeln!(out, "create {name} {set_type_spec} -exist");
    let _ = writeln!(out, "swap {tmp} {name}");
    let _ = writeln!(out, "destroy {tmp}");
}

/// Compile a streaming `ipset restore -!` script with atomic `<set>_tmp` swap/destroy.
pub fn compile_ipset_restore_script(store: &RouterStoreData, ipv6_active: bool) -> String {
    let (excl_v4, excl_v6, excl_mac) = split_excluded_client_entries(&store.settings.excluded_ips);
    let mut out = String::with_capacity(1024);

    let local_v4: Vec<String> = [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    append_atomic_ipset(&mut out, IPSET_LOCAL_V4, "hash:net family inet", &local_v4);
    append_atomic_ipset(
        &mut out,
        IPSET_EXCL_SRC_V4,
        "hash:net family inet",
        &excl_v4,
    );
    if !excl_mac.is_empty() {
        append_atomic_ipset(&mut out, IPSET_EXCL_MAC, "hash:mac", &excl_mac);
    }

    if ipv6_active {
        let local_v6: Vec<String> = [
            "::1/128",
            "64:ff9b::/96",
            "100::/64",
            "2001:db8::/32",
            "fc00::/7",
            "fe80::/10",
            "ff00::/8",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        append_atomic_ipset(&mut out, IPSET_LOCAL_V6, "hash:net family inet6", &local_v6);
        append_atomic_ipset(
            &mut out,
            IPSET_EXCL_SRC_V6,
            "hash:net family inet6",
            &excl_v6,
        );
    }

    out
}

fn format_multiport_chunks(ports: &[u16]) -> Vec<String> {
    let mut chunks = Vec::new();
    for chunk in ports.chunks(15) {
        let joined = chunk
            .iter()
            .map(u16::to_string)
            .collect::<Vec<_>>()
            .join(",");
        if !joined.is_empty() {
            chunks.push(joined);
        }
    }
    chunks
}

fn parse_port_csv_to_vec(csv: &str) -> Vec<u16> {
    let mut ports = Vec::new();
    for tok in csv.split(',') {
        if let Ok(p) = tok.trim().parse::<u16>()
            && p > 0
            && !ports.contains(&p)
        {
            ports.push(p);
        }
    }
    ports
}

fn append_tailscale_tunnel_mark_returns(out: &mut String, chain: &str, cond: &str) {
    let prefix = if cond.is_empty() {
        String::new()
    } else {
        format!(" {cond}")
    };
    let _ = writeln!(
        out,
        "-A {chain}{prefix} -m mark --mark 0x00200000/0x00200000 -j RETURN"
    );
    let _ = writeln!(
        out,
        "-A {chain}{prefix} -m mark --mark 0x00040000/0x00040000 -j RETURN"
    );
}

fn append_local_dst_returns(out: &mut String, chain: &str, ipv6: bool, caps: &EntwareNetCaps) {
    if caps.has_set {
        let local_set = if ipv6 { IPSET_LOCAL_V6 } else { IPSET_LOCAL_V4 };
        let _ = writeln!(
            out,
            "-A {chain} -m set --match-set {local_set} dst -j RETURN"
        );
    } else {
        let cidrs = if ipv6 { LOCAL_CIDRS_V6 } else { LOCAL_CIDRS_V4 };
        for cidr in cidrs {
            let _ = writeln!(out, "-A {chain} -d {cidr} -j RETURN");
        }
    }
}

fn append_excl_src_returns(
    out: &mut String,
    chain: &str,
    ipv6: bool,
    has_excl_mac: bool,
    store: &RouterStoreData,
    caps: &EntwareNetCaps,
) {
    if caps.has_set {
        let excl_set = if ipv6 {
            IPSET_EXCL_SRC_V6
        } else {
            IPSET_EXCL_SRC_V4
        };
        let _ = writeln!(
            out,
            "-A {chain} -m set --match-set {excl_set} src -j RETURN"
        );
        if has_excl_mac {
            let _ = writeln!(
                out,
                "-A {chain} -m set --match-set {IPSET_EXCL_MAC} src -j RETURN"
            );
        }
    } else {
        let (excl_v4, excl_v6, excl_mac) =
            split_excluded_client_entries(&store.settings.excluded_ips);
        let ips = if ipv6 { &excl_v6 } else { &excl_v4 };
        for ip in ips {
            let _ = writeln!(out, "-A {chain} -s {ip} -j RETURN");
        }
        if caps.has_mac {
            for mac in &excl_mac {
                let _ = writeln!(out, "-A {chain} -m mac --mac-source {mac} -j RETURN");
            }
        }
    }
}

fn append_proto_ports_rule(
    out: &mut String,
    chain: &str,
    extra: &str,
    proto: &str,
    ports: &[u16],
    target: &str,
    caps: &EntwareNetCaps,
) {
    if ports.is_empty() {
        return;
    }
    let extra_s = if extra.is_empty() {
        String::new()
    } else {
        format!(" {extra}")
    };
    if ports.len() == 1 {
        let _ = writeln!(
            out,
            "-A {chain}{extra_s} -p {proto} --dport {} -j {target}",
            ports[0]
        );
        return;
    }
    if caps.has_multiport {
        for chunk in format_multiport_chunks(ports) {
            let _ = writeln!(
                out,
                "-A {chain}{extra_s} -p {proto} -m multiport --dports {chunk} -j {target}"
            );
        }
    } else {
        for p in ports {
            let _ = writeln!(
                out,
                "-A {chain}{extra_s} -p {proto} --dport {p} -j {target}"
            );
        }
    }
}

fn append_sport_ports_rule(
    out: &mut String,
    chain: &str,
    extra: &str,
    proto: &str,
    ports: &[u16],
    target: &str,
    caps: &EntwareNetCaps,
) {
    if ports.is_empty() {
        return;
    }
    let extra_s = if extra.is_empty() {
        String::new()
    } else {
        format!(" {extra}")
    };
    if ports.len() == 1 {
        let _ = writeln!(
            out,
            "-A {chain}{extra_s} -p {proto} --sport {} -j {target}",
            ports[0]
        );
        return;
    }
    if caps.has_multiport {
        for chunk in format_multiport_chunks(ports) {
            let _ = writeln!(
                out,
                "-A {chain}{extra_s} -p {proto} -m multiport --sports {chunk} -j {target}"
            );
        }
    } else {
        for p in ports {
            let _ = writeln!(
                out,
                "-A {chain}{extra_s} -p {proto} --sport {p} -j {target}"
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn append_dns_nat_chain(
    out: &mut String,
    store: &RouterStoreData,
    lan_ifaces: &[String],
    bypass_ifaces: &[String],
    ipv6: bool,
    ipv6_active: bool,
    dns_port: u16,
    has_excl_mac: bool,
    caps: &EntwareNetCaps,
) {
    let override_mode = store
        .settings
        .entware_dns_mode
        .trim()
        .eq_ignore_ascii_case("override");
    if store.settings.dont_touch_dhcp || override_mode || dns_port == 0 || !caps.has_redirect {
        return;
    }

    let _ = writeln!(out, "-A TACHYON_DNS_NAT -i lo -j RETURN");
    for bif in bypass_ifaces {
        let pat = to_iptables_iface_pattern(bif);
        let _ = writeln!(out, "-A TACHYON_DNS_NAT -i {pat} -j RETURN");
    }

    append_excl_src_returns(out, "TACHYON_DNS_NAT", ipv6, has_excl_mac, store, caps);

    let (src_v4, src_v6) = crate::config_gen::collect_source_aware_dns_cidrs(store, ipv6_active);
    let src_cidrs = if ipv6 { &src_v6 } else { &src_v4 };
    let src_port = crate::config_gen::SOURCE_DNS_INBOUND_PORT;
    for cidr in src_cidrs {
        let _ = writeln!(
            out,
            "-A TACHYON_DNS_NAT -s {cidr} -p udp --dport 53 -j REDIRECT --to-ports {src_port}"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_DNS_NAT -s {cidr} -p tcp --dport 53 -j REDIRECT --to-ports {src_port}"
        );
    }

    for lan in lan_ifaces {
        let _ = writeln!(
            out,
            "-A TACHYON_DNS_NAT -i {lan} -p udp --dport 53 -j REDIRECT --to-ports {dns_port}"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_DNS_NAT -i {lan} -p tcp --dport 53 -j REDIRECT --to-ports {dns_port}"
        );
    }
}

fn append_filter_input_chain(
    out: &mut String,
    store: &RouterStoreData,
    lan_ifaces: &[String],
    ipv6_active: bool,
    dns_port: u16,
) {
    let _ = writeln!(out, "-A TACHYON_INPUT -i lo -j RETURN");
    for lan in lan_ifaces {
        let _ = writeln!(out, "-A TACHYON_INPUT -i {lan} -j RETURN");
    }

    let mut protected_ports: Vec<u16> = Vec::new();
    if dns_port > 0 {
        protected_ports.push(dns_port);
    }
    if store.settings.proxy_mode == "tproxy" {
        protected_ports.push(TPROXY_PORT);
    } else if store.settings.proxy_mode == "socks" {
        protected_ports.push(1080);
    }
    if has_source_aware_dns(store, ipv6_active) {
        protected_ports.push(crate::config_gen::SOURCE_DNS_INBOUND_PORT);
    }
    protected_ports.sort_unstable();
    protected_ports.dedup();

    for port in protected_ports {
        let _ = writeln!(out, "-A TACHYON_INPUT -p tcp --dport {port} -j DROP");
        let _ = writeln!(out, "-A TACHYON_INPUT -p udp --dport {port} -j DROP");
    }
}

#[allow(clippy::too_many_arguments)]
fn append_guest_forward_rules(
    out: &mut String,
    store: &RouterStoreData,
    ipv6: bool,
    ipv6_active: bool,
    local_set: &str,
    caps: &EntwareNetCaps,
) {
    if !guest_mode_has_active_rules(&store.guest_mode) {
        return;
    }
    let gm = &store.guest_mode;
    let admin_ports = parse_port_csv_to_vec(&collect_router_admin_ports(store));
    let source_dns_active = has_source_aware_dns(store, ipv6_active);
    let allowed_ports =
        format_guest_allowed_ports(gm, source_dns_active).map(|s| parse_port_csv_to_vec(&s));
    let rate_pps = if gm.bandwidth_limit_mbps > 0 && caps.has_limit {
        Some((u64::from(gm.bandwidth_limit_mbps) * 85).max(1))
    } else {
        None
    };

    if is_guest_mode_zero_trust(gm) {
        let (tv4, tv6, tmac) = parse_guest_device_buckets(&gm.trusted_devices);
        let trusted_ips = if ipv6 { &tv6 } else { &tv4 };
        for ip in trusted_ips {
            let _ = writeln!(out, "-A TACHYON_GUEST -s {ip} -j RETURN");
        }
        if caps.has_mac {
            for mac in &tmac {
                let _ = writeln!(out, "-A TACHYON_GUEST -m mac --mac-source {mac} -j RETURN");
            }
        }
        if caps.has_multiport {
            let _ = writeln!(
                out,
                "-A TACHYON_GUEST -p udp -m multiport --dports 67,68,547 -j RETURN"
            );
        } else {
            for p in [67u16, 68, 547] {
                let _ = writeln!(out, "-A TACHYON_GUEST -p udp --dport {p} -j RETURN");
            }
        }
        if gm.block_router_admin && caps.has_set {
            for proto in ["tcp", "udp"] {
                append_proto_ports_rule(
                    out,
                    "TACHYON_GUEST",
                    &format!("-m set --match-set {local_set} dst"),
                    proto,
                    &admin_ports,
                    "DROP",
                    caps,
                );
            }
        }
        if gm.isolate_lan && caps.has_set {
            if source_dns_active && caps.has_multiport {
                let dns_ports = format!("53,{}", crate::config_gen::SOURCE_DNS_INBOUND_PORT);
                let _ = writeln!(
                    out,
                    "-A TACHYON_GUEST -m set --match-set {local_set} dst -p tcp -m multiport ! --dports {dns_ports} -j DROP"
                );
                let _ = writeln!(
                    out,
                    "-A TACHYON_GUEST -m set --match-set {local_set} dst -p udp -m multiport ! --dports {dns_ports} -j DROP"
                );
            } else {
                let _ = writeln!(
                    out,
                    "-A TACHYON_GUEST -m set --match-set {local_set} dst -p tcp ! --dport 53 -j DROP"
                );
                let _ = writeln!(
                    out,
                    "-A TACHYON_GUEST -m set --match-set {local_set} dst -p udp ! --dport 53 -j DROP"
                );
            }
        }
        if let Some(ref ports) = allowed_ports
            && !ports.is_empty()
            && caps.has_set
            && caps.has_multiport
        {
            for chunk in format_multiport_chunks(ports) {
                let _ = writeln!(
                    out,
                    "-A TACHYON_GUEST -m set ! --match-set {local_set} dst -p tcp -m multiport ! --dports {chunk} -j DROP"
                );
                let _ = writeln!(
                    out,
                    "-A TACHYON_GUEST -m set ! --match-set {local_set} dst -p udp -m multiport ! --dports {chunk} -j DROP"
                );
            }
        }
        if let Some(pps) = rate_pps {
            let _ = writeln!(
                out,
                "-A TACHYON_GUEST -m limit --limit {pps}/sec --limit-burst {} -j RETURN",
                (pps / 2).max(10)
            );
            let _ = writeln!(out, "-A TACHYON_GUEST -j DROP");
        }
        let _ = writeln!(out, "-A TACHYON_FORWARD -j TACHYON_GUEST");
        return;
    }

    let (gv4, gv6, gmac) = parse_guest_device_buckets(&gm.guest_devices);
    let guest_ips = if ipv6 { &gv6 } else { &gv4 };
    let mut selectors: Vec<String> = Vec::new();
    for ip in guest_ips {
        selectors.push(format!("-s {ip}"));
    }
    if caps.has_mac {
        for mac in &gmac {
            selectors.push(format!("-m mac --mac-source {mac}"));
        }
    }
    for sel in &selectors {
        if gm.block_router_admin && caps.has_set {
            for proto in ["tcp", "udp"] {
                append_proto_ports_rule(
                    out,
                    "TACHYON_FORWARD",
                    &format!("{sel} -m set --match-set {local_set} dst"),
                    proto,
                    &admin_ports,
                    "DROP",
                    caps,
                );
            }
        }
        if gm.isolate_lan && caps.has_set {
            if source_dns_active && caps.has_multiport {
                let dns_ports = format!("53,{}", crate::config_gen::SOURCE_DNS_INBOUND_PORT);
                let _ = writeln!(
                    out,
                    "-A TACHYON_FORWARD {sel} -m set --match-set {local_set} dst -p tcp -m multiport ! --dports {dns_ports} -j DROP"
                );
                let _ = writeln!(
                    out,
                    "-A TACHYON_FORWARD {sel} -m set --match-set {local_set} dst -p udp -m multiport ! --dports {dns_ports} -j DROP"
                );
            } else {
                let _ = writeln!(
                    out,
                    "-A TACHYON_FORWARD {sel} -m set --match-set {local_set} dst -p tcp ! --dport 53 -j DROP"
                );
                let _ = writeln!(
                    out,
                    "-A TACHYON_FORWARD {sel} -m set --match-set {local_set} dst -p udp ! --dport 53 -j DROP"
                );
            }
        }
        if let Some(ref ports) = allowed_ports
            && !ports.is_empty()
            && caps.has_set
            && caps.has_multiport
        {
            for chunk in format_multiport_chunks(ports) {
                let _ = writeln!(
                    out,
                    "-A TACHYON_FORWARD {sel} -m set ! --match-set {local_set} dst -p tcp -m multiport ! --dports {chunk} -j DROP"
                );
                let _ = writeln!(
                    out,
                    "-A TACHYON_FORWARD {sel} -m set ! --match-set {local_set} dst -p udp -m multiport ! --dports {chunk} -j DROP"
                );
            }
        }
        if let Some(pps) = rate_pps {
            let _ = writeln!(
                out,
                "-A TACHYON_FORWARD {sel} -m limit --limit {pps}/sec --limit-burst {} -j RETURN",
                (pps / 2).max(10)
            );
            let _ = writeln!(out, "-A TACHYON_FORWARD {sel} -j DROP");
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn append_filter_forward_policy_rules(
    out: &mut String,
    store: &RouterStoreData,
    bypass_ifaces: &[String],
    ipv6: bool,
    ipv6_active: bool,
    local_set: &str,
    caps: &EntwareNetCaps,
) {
    let reject_target = if caps.has_reject { "REJECT" } else { "DROP" };
    for bif in bypass_ifaces {
        let pat = to_iptables_iface_pattern(bif);
        let _ = writeln!(out, "-A TACHYON_FORWARD -i {pat} -j RETURN");
        let _ = writeln!(out, "-A TACHYON_FORWARD -o {pat} -j RETURN");
    }

    if caps.has_mac {
        for mac in collect_parental_blocked_macs(store) {
            let _ = writeln!(out, "-A TACHYON_FORWARD -m mac --mac-source {mac} -j DROP");
        }
    }

    append_guest_forward_rules(out, store, ipv6, ipv6_active, local_set, caps);

    let eff_dns_intercept = crate::store::effective_dns_intercept_all(store);
    if crate::net_stack::effective_disable_quic_global(store) {
        let _ = writeln!(
            out,
            "-A TACHYON_FORWARD -p udp --dport 443 -j {reject_target}"
        );
    }
    if eff_dns_intercept {
        let _ = writeln!(
            out,
            "-A TACHYON_FORWARD -p tcp --dport 853 -j {reject_target}"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_FORWARD -p udp --dport 853 -j {reject_target}"
        );
    }
    if store.settings.block_doh || eff_dns_intercept {
        let doh_ips = if ipv6 { DOH_IPS_V6 } else { DOH_IPS_V4 };
        for ip in doh_ips {
            append_proto_ports_rule(
                out,
                "TACHYON_FORWARD",
                &format!("-d {ip}"),
                "tcp",
                &[443, 853],
                reject_target,
                caps,
            );
        }
    }

    if crate::store::effective_webrtc_leak_protect(store) {
        let proxy_udp_ports = collect_proxy_udp_ports(store);
        let _ = writeln!(
            out,
            "-A TACHYON_WEBRTC -m mark --mark {ROUTER_TPROXY_FWMARK}/{ROUTER_TPROXY_FWMARK} -j RETURN"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_WEBRTC -m mark --mark {BYPASS_FWMARK}/{BYPASS_FWMARK} -j RETURN"
        );
        append_tailscale_tunnel_mark_returns(out, "TACHYON_WEBRTC", "");
        let _ = writeln!(
            out,
            "-A TACHYON_WEBRTC -m mark --mark {TAILSCALE_DAEMON_BYPASS_MARK}/{TAILSCALE_DAEMON_BYPASS_MARK} -j RETURN"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_WEBRTC -m mark --mark {FPTN_TUNNEL_BYPASS_MARK}/0x00ff0000 -j RETURN"
        );
        append_proto_ports_rule(
            out,
            "TACHYON_WEBRTC",
            "",
            "udp",
            &proxy_udp_ports,
            "RETURN",
            caps,
        );
        append_sport_ports_rule(
            out,
            "TACHYON_WEBRTC",
            "",
            "udp",
            &proxy_udp_ports,
            "RETURN",
            caps,
        );
        append_proto_ports_rule(
            out,
            "TACHYON_WEBRTC",
            "",
            "udp",
            &[3478, 5349, 19302],
            reject_target,
            caps,
        );
        let _ = writeln!(out, "-A TACHYON_FORWARD -j TACHYON_WEBRTC");
    }
}

fn compile_tproxy_family_ruleset(
    store: &RouterStoreData,
    ipv6: bool,
    ipv6_active: bool,
    dns_port: u16,
    caps: &EntwareNetCaps,
) -> String {
    let (_, _, excl_mac) = split_excluded_client_entries(&store.settings.excluded_ips);
    let has_excl_mac = !excl_mac.is_empty();
    let lan_ifaces = collect_managed_lan_ifaces(store);
    let tailscale_bypass_ifaces = collect_tailscale_bypass_ifaces(store);
    let is_tailscale_source = store
        .settings
        .source_network_interfaces
        .iter()
        .any(|i| i.trim() == "tailscale0");
    let allow_tailscale_fakeip = !is_tailscale_source && store.settings.fakeip_enabled;
    let intercept_embedded_ts =
        embedded_tailscale_enabled(store) && !native_tailscale_enabled(store);

    let fakeip_cidr = if ipv6 {
        if store.settings.fakeip_inet6_range.trim().is_empty() {
            "fc00::/18"
        } else {
            store.settings.fakeip_inet6_range.trim()
        }
    } else if store.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        store.settings.fakeip_inet4_range.trim()
    };

    let local_set = if ipv6 { IPSET_LOCAL_V6 } else { IPSET_LOCAL_V4 };
    let tproxy_on_ip = if ipv6 {
        TPROXY6_LISTEN_ADDR
    } else {
        "127.0.0.1"
    };

    let source_ifaces: Vec<String> = store
        .settings
        .source_network_interfaces
        .iter()
        .filter_map(|i| sanitize_iface_name(i))
        .filter(|i| i != "lo")
        .collect();
    let mut allowed_src_ifaces = source_ifaces.clone();
    if allow_tailscale_fakeip && !allowed_src_ifaces.iter().any(|i| i == "tailscale0") {
        allowed_src_ifaces.push("tailscale0".to_string());
    }

    let blocked_macs = collect_parental_blocked_macs(store);
    let bypass_macs = collect_bypass_macs(store, &blocked_macs);
    let fptn_ips: Vec<String> = crate::config_gen::extract_fptn_server_ips(store)
        .into_iter()
        .filter(|ip| {
            if ipv6 {
                ip.parse::<std::net::Ipv6Addr>().is_ok()
            } else {
                ip.parse::<std::net::Ipv4Addr>().is_ok()
            }
        })
        .collect();

    let mut out = String::with_capacity(4096);

    // 1. *mangle
    let _ = writeln!(out, "*mangle");
    let _ = writeln!(out, ":TACHYON_DIVERT - [0:0]");
    let _ = writeln!(out, ":TACHYON_PREROUTING - [0:0]");
    let _ = writeln!(out, ":TACHYON_OUTPUT - [0:0]");
    let use_multi_src_chain = !source_ifaces.is_empty() && allowed_src_ifaces.len() > 1;
    if use_multi_src_chain {
        let _ = writeln!(out, ":TACHYON_TPROXY - [0:0]");
    }
    let _ = writeln!(out, "-F TACHYON_DIVERT");
    let _ = writeln!(out, "-F TACHYON_PREROUTING");
    let _ = writeln!(out, "-F TACHYON_OUTPUT");
    if use_multi_src_chain {
        let _ = writeln!(out, "-F TACHYON_TPROXY");
    }

    // TACHYON_DIVERT for already-established local transparent sockets (`-m socket`)
    let _ = writeln!(out, "-A TACHYON_DIVERT -j MARK --set-mark {TPROXY_FWMARK}");
    let _ = writeln!(out, "-A TACHYON_DIVERT -j ACCEPT");

    let target_pre_chain = if use_multi_src_chain {
        for iface in &allowed_src_ifaces {
            let _ = writeln!(out, "-A TACHYON_PREROUTING -i {iface} -j TACHYON_TPROXY");
        }
        let _ = writeln!(
            out,
            "-A TACHYON_PREROUTING -i lo -m mark --mark {ROUTER_TPROXY_FWMARK_MASKED} -j TACHYON_TPROXY"
        );
        let _ = writeln!(out, "-A TACHYON_PREROUTING -j RETURN");
        "TACHYON_TPROXY"
    } else {
        "TACHYON_PREROUTING"
    };

    // Bypass virtual tunnel interfaces
    for bif in &tailscale_bypass_ifaces {
        if (is_tailscale_source || allow_tailscale_fakeip) && bif == "tailscale0" {
            continue;
        }
        let pat = to_iptables_iface_pattern(bif);
        let _ = writeln!(out, "-A {target_pre_chain} -i {pat} -j RETURN");
    }
    if allow_tailscale_fakeip {
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -i tailscale0 ! -d {fakeip_cidr} -j RETURN"
        );
    }

    // Loopback re-entry only for router-marked traffic
    let _ = writeln!(
        out,
        "-A {target_pre_chain} -i lo -m mark ! --mark {ROUTER_TPROXY_FWMARK_MASKED} -j RETURN"
    );

    // Single configured source interface guard (non-source LAN interfaces return)
    if !use_multi_src_chain && allowed_src_ifaces.len() == 1 {
        let only = &allowed_src_ifaces[0];
        let _ = writeln!(
            out,
            "-A {target_pre_chain} ! -i {only} -m mark ! --mark {ROUTER_TPROXY_FWMARK_MASKED} -j RETURN"
        );
    }

    // Bypass marks (tachyon-core default_mark, Tailscale, FPTN)
    let _ = writeln!(
        out,
        "-A {target_pre_chain} -m mark --mark {BYPASS_FWMARK}/{BYPASS_FWMARK} -j RETURN"
    );
    let _ = writeln!(
        out,
        "-A {target_pre_chain} -m mark --mark {TAILSCALE_DAEMON_BYPASS_MARK}/{TAILSCALE_DAEMON_BYPASS_MARK} -j RETURN"
    );
    let _ = writeln!(
        out,
        "-A {target_pre_chain} -m mark --mark {FPTN_TUNNEL_BYPASS_MARK}/0x00ff0000 -j RETURN"
    );
    if store.settings.fakeip_enabled {
        append_tailscale_tunnel_mark_returns(
            &mut out,
            target_pre_chain,
            &format!("! -d {fakeip_cidr}"),
        );
    } else {
        append_tailscale_tunnel_mark_returns(&mut out, target_pre_chain, "");
    }

    // Client exclusions (IP/CIDR + MAC)
    append_excl_src_returns(&mut out, target_pre_chain, ipv6, has_excl_mac, store, caps);
    if caps.has_mac {
        for mac in &bypass_macs {
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -m mac --mac-source {mac} -j RETURN"
            );
        }
    }

    // Guest devices with allow_proxy=false bypass TPROXY
    if guest_mode_has_active_rules(&store.guest_mode)
        && !store.guest_mode.allow_proxy
        && !is_guest_mode_zero_trust(&store.guest_mode)
    {
        let (gv4, gv6, gmac) = parse_guest_device_buckets(&store.guest_mode.guest_devices);
        let gips = if ipv6 { &gv6 } else { &gv4 };
        for ip in gips {
            let _ = writeln!(out, "-A {target_pre_chain} -s {ip} -j RETURN");
        }
        if caps.has_mac {
            for mac in &gmac {
                let _ = writeln!(
                    out,
                    "-A {target_pre_chain} -m mac --mac-source {mac} -j RETURN"
                );
            }
        }
    }

    // Preserve local router addresses and DNAT reflection (only when kernel modules exist)
    if caps.has_conntrack {
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -m conntrack --ctstate DNAT -j RETURN"
        );
    }
    if caps.has_addrtype {
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -m addrtype --dst-type LOCAL -j RETURN"
        );
    }

    // FPTN server endpoints, NTP, TorrServer ports
    for fip in &fptn_ips {
        let _ = writeln!(out, "-A {target_pre_chain} -d {fip} -j RETURN");
    }
    if store.settings.exclude_ntp {
        let _ = writeln!(out, "-A {target_pre_chain} -p udp --dport 123 -j RETURN");
    }
    if store.settings.torrserver_direct_enabled && !store.settings.torrserver_ports.is_empty() {
        for proto in ["tcp", "udp"] {
            append_proto_ports_rule(
                &mut out,
                target_pre_chain,
                "",
                proto,
                &store.settings.torrserver_ports,
                "RETURN",
                caps,
            );
        }
    }

    // FakeIP & embedded Tailscale CGNAT/ULA MUST enter TPROXY BEFORE tachyon_local_v4/v6 return!
    if store.settings.fakeip_enabled {
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -p tcp -d {fakeip_cidr} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
        );
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -p udp -d {fakeip_cidr} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
        );
    }
    if intercept_embedded_ts {
        let ts_cidr = if ipv6 {
            "fd7a:115c:a1e0::/48"
        } else {
            "100.64.0.0/10"
        };
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -p tcp -d {ts_cidr} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
        );
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -p udp -d {ts_cidr} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
        );
    }

    // Return for local / RFC1918 / loopback / multicast / CGNAT destinations
    if ipv6 {
        let _ = writeln!(out, "-A {target_pre_chain} -p ipv6-icmp -j RETURN");
    }
    append_local_dst_returns(&mut out, target_pre_chain, ipv6, caps);

    // TPROXY interception: selective (FakeIP + explicit subnets/sources) or catch-all
    if !ipv6 && crate::net_stack::selective_tproxy_active(store) {
        let targets = crate::net_stack::collect_selective_tproxy_targets(store);
        for dst in &targets.dst_v4 {
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p tcp -d {dst} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p udp -d {dst} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
        }
        for src in &targets.src_v4 {
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p tcp -s {src} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p udp -s {src} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
        }
        if caps.has_mac {
            for mac in &targets.src_macs {
                let _ = writeln!(
                    out,
                    "-A {target_pre_chain} -m mac --mac-source {mac} -p tcp -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
                );
                let _ = writeln!(
                    out,
                    "-A {target_pre_chain} -m mac --mac-source {mac} -p udp -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
                );
            }
        }
    } else if ipv6 && crate::net_stack::selective_tproxy_active(store) {
        let targets = crate::net_stack::collect_selective_tproxy_targets(store);
        for dst in &targets.dst_v6 {
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p tcp -d {dst} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p udp -d {dst} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
        }
        for src in &targets.src_v6 {
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p tcp -s {src} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
            let _ = writeln!(
                out,
                "-A {target_pre_chain} -p udp -s {src} -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
            );
        }
    } else {
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -p tcp -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
        );
        let _ = writeln!(
            out,
            "-A {target_pre_chain} -p udp -j TPROXY --on-port {TPROXY_PORT} --on-ip {tproxy_on_ip} --tproxy-mark {TPROXY_FWMARK_MASKED}"
        );
    }

    // TACHYON_OUTPUT (router-originated traffic)
    for bif in &tailscale_bypass_ifaces {
        let pat = to_iptables_iface_pattern(bif);
        let _ = writeln!(out, "-A TACHYON_OUTPUT -o {pat} -j RETURN");
    }
    if caps.has_owner {
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -m owner --gid-owner {DIRECT_PROBE_SKGID} -j RETURN"
        );
    }
    let _ = writeln!(
        out,
        "-A TACHYON_OUTPUT -m mark --mark {BYPASS_FWMARK}/{BYPASS_FWMARK} -j RETURN"
    );
    let _ = writeln!(
        out,
        "-A TACHYON_OUTPUT -m mark --mark {ROUTER_TPROXY_FWMARK_MASKED} -j RETURN"
    );
    let _ = writeln!(
        out,
        "-A TACHYON_OUTPUT -m mark --mark {TPROXY_FWMARK_MASKED} -j RETURN"
    );
    append_tailscale_tunnel_mark_returns(&mut out, "TACHYON_OUTPUT", "");
    let _ = writeln!(
        out,
        "-A TACHYON_OUTPUT -m mark --mark {TAILSCALE_DAEMON_BYPASS_MARK}/{TAILSCALE_DAEMON_BYPASS_MARK} -j RETURN"
    );
    let _ = writeln!(
        out,
        "-A TACHYON_OUTPUT -m mark --mark {FPTN_TUNNEL_BYPASS_MARK}/0x00ff0000 -j RETURN"
    );
    for fip in &fptn_ips {
        let _ = writeln!(out, "-A TACHYON_OUTPUT -d {fip} -j RETURN");
    }
    if store.settings.exclude_ntp {
        let _ = writeln!(out, "-A TACHYON_OUTPUT -p udp --dport 123 -j RETURN");
    }
    if store.settings.torrserver_direct_enabled && !store.settings.torrserver_ports.is_empty() {
        for proto in ["tcp", "udp"] {
            append_proto_ports_rule(
                &mut out,
                "TACHYON_OUTPUT",
                "",
                proto,
                &store.settings.torrserver_ports,
                "RETURN",
                caps,
            );
        }
    }
    if caps.has_conntrack {
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -m conntrack --ctstate DNAT -j RETURN"
        );
    }
    if caps.has_addrtype {
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -m addrtype --dst-type LOCAL -j RETURN"
        );
    }

    // Router FakeIP and embedded Tailscale before tachyon_local return
    if store.settings.fakeip_enabled {
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -p tcp -d {fakeip_cidr} -j MARK --set-mark {ROUTER_TPROXY_FWMARK}"
        );
        let _ = writeln!(out, "-A TACHYON_OUTPUT -p tcp -d {fakeip_cidr} -j RETURN");
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -p udp -d {fakeip_cidr} -j MARK --set-mark {ROUTER_TPROXY_FWMARK}"
        );
        let _ = writeln!(out, "-A TACHYON_OUTPUT -p udp -d {fakeip_cidr} -j RETURN");
    }
    if intercept_embedded_ts {
        let ts_cidr = if ipv6 {
            "fd7a:115c:a1e0::/48"
        } else {
            "100.64.0.0/10"
        };
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -p tcp -d {ts_cidr} -j MARK --set-mark {ROUTER_TPROXY_FWMARK}"
        );
        let _ = writeln!(out, "-A TACHYON_OUTPUT -p tcp -d {ts_cidr} -j RETURN");
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -p udp -d {ts_cidr} -j MARK --set-mark {ROUTER_TPROXY_FWMARK}"
        );
        let _ = writeln!(out, "-A TACHYON_OUTPUT -p udp -d {ts_cidr} -j RETURN");
    }
    append_local_dst_returns(&mut out, "TACHYON_OUTPUT", ipv6, caps);
    if store.settings.route_router_traffic {
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -p tcp -j MARK --set-mark {ROUTER_TPROXY_FWMARK}"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_OUTPUT -p udp -j MARK --set-mark {ROUTER_TPROXY_FWMARK}"
        );
    }
    let _ = writeln!(out, "COMMIT");

    // 2. *nat (DNS redirect on LAN)
    let _ = writeln!(out, "*nat");
    let _ = writeln!(out, ":TACHYON_DNS_NAT - [0:0]");
    let _ = writeln!(out, "-F TACHYON_DNS_NAT");
    append_dns_nat_chain(
        &mut out,
        store,
        &lan_ifaces,
        &tailscale_bypass_ifaces,
        ipv6,
        ipv6_active,
        dns_port,
        has_excl_mac,
        caps,
    );
    let _ = writeln!(out, "COMMIT");

    // 3. *filter (open-resolver guard + DoH/QUIC/WebRTC/parental/guest)
    // Declare and flush ALL custom chains at the top of *filter BEFORE any -A rules.
    let zero_trust_guest = guest_mode_has_active_rules(&store.guest_mode)
        && is_guest_mode_zero_trust(&store.guest_mode);
    let webrtc_enabled = crate::store::effective_webrtc_leak_protect(store);
    let _ = writeln!(out, "*filter");
    let _ = writeln!(out, ":TACHYON_INPUT - [0:0]");
    let _ = writeln!(out, ":TACHYON_FORWARD - [0:0]");
    if zero_trust_guest {
        let _ = writeln!(out, ":TACHYON_GUEST - [0:0]");
    }
    if webrtc_enabled {
        let _ = writeln!(out, ":TACHYON_WEBRTC - [0:0]");
    }
    let _ = writeln!(out, "-F TACHYON_INPUT");
    let _ = writeln!(out, "-F TACHYON_FORWARD");
    if zero_trust_guest {
        let _ = writeln!(out, "-F TACHYON_GUEST");
    }
    if webrtc_enabled {
        let _ = writeln!(out, "-F TACHYON_WEBRTC");
    }
    append_filter_input_chain(&mut out, store, &lan_ifaces, ipv6_active, dns_port);
    append_filter_forward_policy_rules(
        &mut out,
        store,
        &tailscale_bypass_ifaces,
        ipv6,
        ipv6_active,
        local_set,
        caps,
    );
    let _ = writeln!(out, "COMMIT");

    out
}

/// Compile IPv4 (and optional IPv6) `iptables-restore --noflush` rulesets for TProxy mode
/// using explicit probed kernel capabilities.
pub fn compile_iptables_tproxy_ruleset_with_caps(
    store: &RouterStoreData,
    ipv6_active: bool,
    dns_port: u16,
    caps: &EntwareNetCaps,
) -> (String, Option<String>) {
    let v4 = compile_tproxy_family_ruleset(store, false, ipv6_active, dns_port, caps);
    let v6 = ipv6_active
        .then(|| compile_tproxy_family_ruleset(store, true, ipv6_active, dns_port, caps));
    (v4, v6)
}

/// Compile IPv4 (and optional IPv6) `iptables-restore --noflush` rulesets for TProxy mode.
pub fn compile_iptables_tproxy_ruleset(
    store: &RouterStoreData,
    ipv6_active: bool,
    dns_port: u16,
) -> (String, Option<String>) {
    compile_iptables_tproxy_ruleset_with_caps(
        store,
        ipv6_active,
        dns_port,
        &EntwareNetCaps::full_for_preview(),
    )
}

fn compile_tun_family_ruleset(
    store: &RouterStoreData,
    ipv6: bool,
    ipv6_active: bool,
    dns_port: u16,
    caps: &EntwareNetCaps,
) -> String {
    let (_, _, excl_mac) = split_excluded_client_entries(&store.settings.excluded_ips);
    let has_excl_mac = !excl_mac.is_empty();
    let lan_ifaces = collect_managed_lan_ifaces(store);
    let mut bypass_ifaces = collect_tailscale_bypass_ifaces(store);
    let tun_if =
        sanitize_iface_name(&store.settings.tun_interface).unwrap_or_else(|| "tun0".to_string());
    if !bypass_ifaces.iter().any(|i| i == &tun_if) {
        bypass_ifaces.push(tun_if.clone());
    }
    let local_set = if ipv6 { IPSET_LOCAL_V6 } else { IPSET_LOCAL_V4 };
    let zero_trust_guest = guest_mode_has_active_rules(&store.guest_mode)
        && is_guest_mode_zero_trust(&store.guest_mode);
    let webrtc_enabled = crate::store::effective_webrtc_leak_protect(store);

    let mut out = String::with_capacity(2048);

    // 1. *filter (all chain declarations + flushes BEFORE any -A rules)
    let _ = writeln!(out, "*filter");
    let _ = writeln!(out, ":TACHYON_INPUT - [0:0]");
    let _ = writeln!(out, ":TACHYON_FORWARD - [0:0]");
    if zero_trust_guest {
        let _ = writeln!(out, ":TACHYON_GUEST - [0:0]");
    }
    if webrtc_enabled {
        let _ = writeln!(out, ":TACHYON_WEBRTC - [0:0]");
    }
    let _ = writeln!(out, "-F TACHYON_INPUT");
    let _ = writeln!(out, "-F TACHYON_FORWARD");
    if zero_trust_guest {
        let _ = writeln!(out, "-F TACHYON_GUEST");
    }
    if webrtc_enabled {
        let _ = writeln!(out, "-F TACHYON_WEBRTC");
    }
    append_filter_input_chain(&mut out, store, &lan_ifaces, ipv6_active, dns_port);
    let policy_bypass: Vec<String> = bypass_ifaces
        .iter()
        .filter(|i| i.as_str() != tun_if.as_str())
        .cloned()
        .collect();
    append_filter_forward_policy_rules(
        &mut out,
        store,
        &policy_bypass,
        ipv6,
        ipv6_active,
        local_set,
        caps,
    );
    let _ = writeln!(out, "-A TACHYON_FORWARD -i {tun_if} -j ACCEPT");
    let _ = writeln!(out, "-A TACHYON_FORWARD -o {tun_if} -j ACCEPT");
    let _ = writeln!(out, "COMMIT");

    // 2. *nat (all chain declarations + flushes BEFORE any -A rules)
    let _ = writeln!(out, "*nat");
    let _ = writeln!(out, ":TACHYON_POSTROUTING - [0:0]");
    let _ = writeln!(out, ":TACHYON_DNS_NAT - [0:0]");
    let _ = writeln!(out, "-F TACHYON_POSTROUTING");
    let _ = writeln!(out, "-F TACHYON_DNS_NAT");
    if caps.has_masquerade {
        let _ = writeln!(out, "-A TACHYON_POSTROUTING -o {tun_if} -j MASQUERADE");
    }
    append_dns_nat_chain(
        &mut out,
        store,
        &lan_ifaces,
        &bypass_ifaces,
        ipv6,
        ipv6_active,
        dns_port,
        has_excl_mac,
        caps,
    );
    let _ = writeln!(out, "COMMIT");

    out
}

/// Compile IPv4 (and optional IPv6) `iptables-restore --noflush` rulesets for TUN mode
/// using explicit probed kernel capabilities.
pub fn compile_iptables_tun_ruleset_with_caps(
    store: &RouterStoreData,
    ipv6_active: bool,
    dns_port: u16,
    caps: &EntwareNetCaps,
) -> (String, Option<String>) {
    let v4 = compile_tun_family_ruleset(store, false, ipv6_active, dns_port, caps);
    let v6 =
        ipv6_active.then(|| compile_tun_family_ruleset(store, true, ipv6_active, dns_port, caps));
    (v4, v6)
}

/// Compile IPv4 (and optional IPv6) `iptables-restore --noflush` rulesets for TUN mode.
pub fn compile_iptables_tun_ruleset(
    store: &RouterStoreData,
    ipv6_active: bool,
    dns_port: u16,
) -> (String, Option<String>) {
    compile_iptables_tun_ruleset_with_caps(
        store,
        ipv6_active,
        dns_port,
        &EntwareNetCaps::full_for_preview(),
    )
}

/// Compile IPv6 leak-guard rules for `ip6tables-restore --noflush` when IPv6 is disabled or guarded.
pub fn compile_iptables_v6_leak_guard_ruleset(
    store: &RouterStoreData,
    caps: &EntwareNetCaps,
) -> String {
    let reject_target = if caps.has_reject { "REJECT" } else { "DROP" };
    let lan_ifaces = collect_managed_lan_ifaces(store);
    let mut out = String::with_capacity(512);
    let _ = writeln!(out, "*filter");
    let _ = writeln!(out, ":TACHYON_INPUT - [0:0]");
    let _ = writeln!(out, ":TACHYON_FORWARD - [0:0]");
    let _ = writeln!(out, "-F TACHYON_INPUT");
    let _ = writeln!(out, "-F TACHYON_FORWARD");
    let _ = writeln!(out, "-A TACHYON_INPUT -i lo -j RETURN");
    for lan in &lan_ifaces {
        let _ = writeln!(out, "-A TACHYON_INPUT -i {lan} -j RETURN");
    }
    let _ = writeln!(out, "-A TACHYON_FORWARD -p ipv6-icmp -j RETURN");
    for cidr in LOCAL_CIDRS_V6 {
        let _ = writeln!(out, "-A TACHYON_FORWARD -d {cidr} -j RETURN");
    }
    let _ = writeln!(out, "-A TACHYON_FORWARD -j {reject_target}");
    let _ = writeln!(out, "COMMIT");
    out
}

/// Compile fail-closed `*filter` `TACHYON_KILLSWITCH` chain for `iptables-restore --noflush`.
pub fn compile_iptables_kill_switch(interfaces: &[String]) -> String {
    let owned;
    let effective = if interfaces.is_empty() {
        owned = vec![crate::platform::detect_default_lan_iface()];
        owned.as_slice()
    } else {
        interfaces
    };

    let mut out = String::with_capacity(512);
    let _ = writeln!(out, "*filter");
    let _ = writeln!(out, ":TACHYON_KILLSWITCH - [0:0]");
    let _ = writeln!(out, ":TACHYON_KILLSWITCH_IN - [0:0]");
    let _ = writeln!(out, "-F TACHYON_KILLSWITCH");
    let _ = writeln!(out, "-F TACHYON_KILLSWITCH_IN");
    for src in effective {
        for dst in effective {
            let _ = writeln!(out, "-A TACHYON_KILLSWITCH -i {src} -o {dst} -j RETURN");
        }
        let _ = writeln!(out, "-A TACHYON_KILLSWITCH -i {src} -j DROP");
        let _ = writeln!(
            out,
            "-A TACHYON_KILLSWITCH_IN -i {src} -p udp --dport 53 -j DROP"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_KILLSWITCH_IN -i {src} -p tcp --dport 53 -j DROP"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_KILLSWITCH_IN -i {src} -p udp --dport 853 -j DROP"
        );
        let _ = writeln!(
            out,
            "-A TACHYON_KILLSWITCH_IN -i {src} -p tcp --dport 853 -j DROP"
        );
    }
    let _ = writeln!(out, "COMMIT");
    out
}

/// Render a human-readable preview of the compiled `ipset` + `iptables` rules for CLI `compile_iptables`.
pub fn compile_iptables_preview(store: &RouterStoreData) -> String {
    let wan6 = crate::store::detect_wan6_runtime_available();
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&store.settings, wan6);
    let ipv6_active = ipv6_state.is_active();
    let dns_port = effective_entware_dns_port(store);

    let mut out = String::with_capacity(4096);
    let _ = writeln!(
        out,
        "# tachyon iptables preview (platform={}, firewall={}, mode={}, ipv6_active={}, entware_dns_mode={}, entware_dns_port={})",
        crate::platform::detect_platform().as_str(),
        crate::platform::firewall_kind().as_str(),
        store.settings.proxy_mode,
        ipv6_active,
        store.settings.entware_dns_mode,
        dns_port,
    );
    if store.settings.proxy_mode == "socks" {
        let _ = writeln!(out, "# proxy_mode=socks: no iptables interception rules");
        return out;
    }

    let _ = writeln!(out, "\n# === ipset restore -! ===");
    out.push_str(&compile_ipset_restore_script(store, ipv6_active));

    let (v4, v6) = if store.settings.proxy_mode == "tun" {
        compile_iptables_tun_ruleset(store, ipv6_active, dns_port)
    } else {
        compile_iptables_tproxy_ruleset(store, ipv6_active, dns_port)
    };
    let _ = writeln!(out, "\n# === iptables-restore --noflush (IPv4) ===");
    out.push_str(&v4);
    if let Some(v6_rules) = v6 {
        let _ = writeln!(out, "\n# === ip6tables-restore --noflush (IPv6) ===");
        out.push_str(&v6_rules);
    }
    out
}

async fn run_stdin_command(bin: &str, args: &[&str], stdin_data: &str) -> anyhow::Result<()> {
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd.spawn()?;
    if let Some(mut stdin) = child.stdin.take()
        && let Err(write_err) = stdin.write_all(stdin_data.as_bytes()).await
    {
        drop(stdin);
        let _ = child.kill().await;
        let _ = child.wait().await;
        return Err(write_err.into());
    }
    let out = match tokio::time::timeout(CMD_TIMEOUT, child.wait_with_output()).await {
        Ok(res) => res?,
        Err(_) => anyhow::bail!(
            "{bin} {} timed out after {}ms",
            args.join(" "),
            CMD_TIMEOUT.as_millis()
        ),
    };
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("{bin} {} failed: {}", args.join(" "), err.trim());
    }
    Ok(())
}

async fn run_iptables_status(bin: &str, args: &[&str]) -> bool {
    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    run_status_with_timeout(&mut cmd, CMD_TIMEOUT)
        .await
        .is_ok_and(|s| s.success())
}

async fn ensure_iptables_jump(bin: &str, table: &str, chain: &str, rule_args: &[&str]) -> bool {
    let mut check_args = Vec::with_capacity(rule_args.len() + 4);
    check_args.extend(["-t", table, "-C", chain]);
    check_args.extend_from_slice(rule_args);
    if run_iptables_status(bin, &check_args).await {
        return true;
    }
    let mut insert_args = Vec::with_capacity(rule_args.len() + 5);
    insert_args.extend(["-t", table, "-I", chain, "1"]);
    insert_args.extend_from_slice(rule_args);
    run_iptables_status(bin, &insert_args).await
}

async fn remove_iptables_jump_all(bin: &str, table: &str, chain: &str, rule_args: &[&str]) {
    let mut del_args = Vec::with_capacity(rule_args.len() + 4);
    del_args.extend(["-t", table, "-D", chain]);
    del_args.extend_from_slice(rule_args);
    for _ in 0..8 {
        if !run_iptables_status(bin, &del_args).await {
            break;
        }
    }
}

async fn flush_and_delete_chain(bin: &str, table: &str, chain: &str) {
    let _ = run_iptables_status(bin, &["-t", table, "-F", chain]).await;
    let _ = run_iptables_status(bin, &["-t", table, "-X", chain]).await;
}

fn strip_nat_section_from_restore(script: &str) -> String {
    let mut out = String::with_capacity(script.len());
    let mut skip_nat = false;
    for line in script.lines() {
        let trimmed = line.trim();
        if trimmed == "*nat" {
            skip_nat = true;
            continue;
        }
        if skip_nat {
            if trimmed == "COMMIT" {
                skip_nat = false;
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

async fn apply_tproxy_policy_routes(
    store: &RouterStoreData,
    ipv6_active: bool,
) -> anyhow::Result<()> {
    let fakeip_v6 = if store.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        store.settings.fakeip_inet6_range.trim()
    };
    cleanup_policy_rules_for(Some(fakeip_v6)).await;

    run_checked_ip(&[
        "rule",
        "add",
        "iif",
        "lo",
        "fwmark",
        TPROXY_FWMARK_MASKED,
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
        TPROXY_FWMARK_MASKED,
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
        ROUTER_TPROXY_FWMARK_MASKED,
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

    if ipv6_active {
        let _ = run_checked_ip(&[
            "-6",
            "rule",
            "add",
            "fwmark",
            TPROXY_FWMARK_MASKED,
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
            ROUTER_TPROXY_FWMARK_MASKED,
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
        if store.settings.fakeip_enabled {
            let _ = run_checked_ip(&["-6", "route", "replace", fakeip_v6, "dev", "lo"]).await;
        }
    }
    Ok(())
}

/// Apply `ipset`, `iptables-restore --noflush`, idempotent jump hooks, and policy routing.
pub async fn apply_iptables_network_stack(store: &RouterStoreData) -> anyhow::Result<()> {
    if cfg!(not(target_os = "linux")) {
        return Ok(());
    }
    if store.settings.proxy_mode == "socks" {
        teardown_iptables_network_stack().await;
        return Ok(());
    }

    ensure_bridge_netfilter_disabled().await;

    for module in [
        "ip_set",
        "ip_set_hash_net",
        "ip_set_hash_mac",
        "xt_set",
        "xt_TPROXY",
        "xt_socket",
        "xt_mark",
        "xt_owner",
        "xt_addrtype",
        "xt_conntrack",
        "xt_multiport",
        "xt_mac",
        "xt_limit",
        "ipt_REJECT",
        "ipt_REDIRECT",
        "ipt_MASQUERADE",
    ] {
        try_modprobe_quiet(module).await;
    }

    let caps = tokio::task::spawn_blocking(probe_entware_net_caps).await?;
    let Some(ipt_bin) = caps.iptables_bin.as_deref() else {
        anyhow::bail!("iptables binary not found (checked /usr/sbin, /sbin, /opt/sbin, /opt/bin)");
    };
    let Some(ipt_restore_bin) = caps.iptables_restore_bin.as_deref() else {
        anyhow::bail!("iptables-restore binary not found (install via: opkg install iptables)");
    };

    if store.settings.proxy_mode == "tproxy" && !caps.has_tproxy {
        let hint = if caps.has_tun {
            "Kernel module xt_TPROXY is unavailable (/proc/net/ip_tables_targets has no TPROXY). Switch proxy_mode to 'tun' (available via /dev/net/tun) or install the router's xt_TPROXY kernel package."
        } else {
            "Kernel module xt_TPROXY is unavailable (/proc/net/ip_tables_targets has no TPROXY) and /dev/net/tun is missing. Install kernel netfilter TPROXY/TUN modules or switch proxy_mode to 'socks'."
        };
        anyhow::bail!("{hint}");
    }
    if store.settings.proxy_mode == "tun" && !caps.has_tun {
        anyhow::bail!(
            "/dev/net/tun is unavailable for TUN mode. Load the tun kernel module or switch proxy_mode."
        );
    }

    let wan6_cache = tokio::task::spawn_blocking(crate::store::probe_wan6_runtime_state).await?;
    let ipv6_state =
        crate::store::resolve_effective_ipv6_state(&store.settings, wan6_cache.wan6_available);
    let ipv6_active = ipv6_state.is_active() && caps.has_ip6tables;
    let ipv6_mode_off = crate::store::normalize_ipv6_mode(&store.settings.ipv6_mode) == "off";
    let forward_guard = (ipv6_state.is_leak_guard() || ipv6_mode_off) && caps.has_ip6tables;
    let dns_port = effective_entware_dns_port(store);

    // 1. Atomic ipset restore (if kernel xt_set + ipset binary are present)
    if caps.has_set
        && let Some(ipset_bin) = find_bin_with_path_fallback(IPSET_BIN_CANDIDATES, "ipset")
    {
        let ipset_script = compile_ipset_restore_script(store, ipv6_active);
        run_stdin_command(&ipset_bin, &["restore", "-!"], &ipset_script).await?;
    }

    // 2. Compile & atomically restore TACHYON_* chains without flushing firmware rules
    let is_tun = store.settings.proxy_mode == "tun";
    let (v4_rules, v6_rules_opt) = if is_tun {
        compile_iptables_tun_ruleset_with_caps(store, ipv6_active, dns_port, &caps)
    } else {
        compile_iptables_tproxy_ruleset_with_caps(store, ipv6_active, dns_port, &caps)
    };
    run_stdin_command(ipt_restore_bin, &["--noflush"], &v4_rules).await?;

    // 3. Idempotent jump rules in built-in chains
    if is_tun {
        remove_iptables_jump_all(
            ipt_bin,
            "mangle",
            "PREROUTING",
            &["-j", "TACHYON_PREROUTING"],
        )
        .await;
        remove_iptables_jump_all(
            ipt_bin,
            "mangle",
            "PREROUTING",
            &["-p", "tcp", "-m", "socket", "-j", "TACHYON_DIVERT"],
        )
        .await;
        remove_iptables_jump_all(ipt_bin, "mangle", "OUTPUT", &["-j", "TACHYON_OUTPUT"]).await;
        ensure_iptables_jump(ipt_bin, "filter", "INPUT", &["-j", "TACHYON_INPUT"]).await;
        ensure_iptables_jump(ipt_bin, "filter", "FORWARD", &["-j", "TACHYON_FORWARD"]).await;
        ensure_iptables_jump(
            ipt_bin,
            "nat",
            "POSTROUTING",
            &["-j", "TACHYON_POSTROUTING"],
        )
        .await;
        if caps.has_redirect {
            ensure_iptables_jump(ipt_bin, "nat", "PREROUTING", &["-j", "TACHYON_DNS_NAT"]).await;
        }
        cleanup_policy_rules().await;
        crate::net_stack::tun_guard_sync(store).await;
    } else {
        remove_iptables_jump_all(
            ipt_bin,
            "nat",
            "POSTROUTING",
            &["-j", "TACHYON_POSTROUTING"],
        )
        .await;
        ensure_iptables_jump(
            ipt_bin,
            "mangle",
            "PREROUTING",
            &["-j", "TACHYON_PREROUTING"],
        )
        .await;
        if caps.has_socket_match {
            ensure_iptables_jump(
                ipt_bin,
                "mangle",
                "PREROUTING",
                &["-p", "tcp", "-m", "socket", "-j", "TACHYON_DIVERT"],
            )
            .await;
        }
        ensure_iptables_jump(ipt_bin, "mangle", "OUTPUT", &["-j", "TACHYON_OUTPUT"]).await;
        if caps.has_redirect {
            ensure_iptables_jump(ipt_bin, "nat", "PREROUTING", &["-j", "TACHYON_DNS_NAT"]).await;
        }
        ensure_iptables_jump(ipt_bin, "filter", "INPUT", &["-j", "TACHYON_INPUT"]).await;
        ensure_iptables_jump(ipt_bin, "filter", "FORWARD", &["-j", "TACHYON_FORWARD"]).await;
        apply_tproxy_policy_routes(store, ipv6_active).await?;
    }

    // 4. Optional IPv6 restore (or IPv6 leak guard when IPv6 is disabled/guarded)
    if let (Some(v6_rules), Some(ip6_bin), Some(ip6_restore_bin)) = (
        v6_rules_opt,
        caps.ip6tables_bin.as_deref(),
        caps.ip6tables_restore_bin.as_deref(),
    ) {
        let mut ip6_nat_ok = true;
        if let Err(err) = run_stdin_command(ip6_restore_bin, &["--noflush"], &v6_rules).await {
            let without_nat = strip_nat_section_from_restore(&v6_rules);
            if run_stdin_command(ip6_restore_bin, &["--noflush"], &without_nat)
                .await
                .is_ok()
            {
                ip6_nat_ok = false;
                eprintln!(
                    "[tachyon] ip6tables *nat unsupported on this kernel ({err:#}); applied IPv6 mangle+filter only"
                );
            } else {
                eprintln!("[tachyon] ip6tables-restore skipped: {err:#}");
                ip6_nat_ok = false;
            }
        }
        if is_tun {
            ensure_iptables_jump(ip6_bin, "filter", "INPUT", &["-j", "TACHYON_INPUT"]).await;
            ensure_iptables_jump(ip6_bin, "filter", "FORWARD", &["-j", "TACHYON_FORWARD"]).await;
            if ip6_nat_ok && caps.has_redirect {
                ensure_iptables_jump(
                    ip6_bin,
                    "nat",
                    "POSTROUTING",
                    &["-j", "TACHYON_POSTROUTING"],
                )
                .await;
                ensure_iptables_jump(ip6_bin, "nat", "PREROUTING", &["-j", "TACHYON_DNS_NAT"])
                    .await;
            }
        } else {
            ensure_iptables_jump(
                ip6_bin,
                "mangle",
                "PREROUTING",
                &["-j", "TACHYON_PREROUTING"],
            )
            .await;
            if caps.has_socket_match {
                ensure_iptables_jump(
                    ip6_bin,
                    "mangle",
                    "PREROUTING",
                    &["-p", "tcp", "-m", "socket", "-j", "TACHYON_DIVERT"],
                )
                .await;
            }
            ensure_iptables_jump(ip6_bin, "mangle", "OUTPUT", &["-j", "TACHYON_OUTPUT"]).await;
            if ip6_nat_ok && caps.has_redirect {
                ensure_iptables_jump(ip6_bin, "nat", "PREROUTING", &["-j", "TACHYON_DNS_NAT"])
                    .await;
            }
            ensure_iptables_jump(ip6_bin, "filter", "INPUT", &["-j", "TACHYON_INPUT"]).await;
            ensure_iptables_jump(ip6_bin, "filter", "FORWARD", &["-j", "TACHYON_FORWARD"]).await;
        }
    } else if forward_guard
        && let (Some(ip6_bin), Some(ip6_restore_bin)) = (
            caps.ip6tables_bin.as_deref(),
            caps.ip6tables_restore_bin.as_deref(),
        )
    {
        let guard_rules = compile_iptables_v6_leak_guard_ruleset(store, &caps);
        if run_stdin_command(ip6_restore_bin, &["--noflush"], &guard_rules)
            .await
            .is_ok()
        {
            ensure_iptables_jump(ip6_bin, "filter", "INPUT", &["-j", "TACHYON_INPUT"]).await;
            ensure_iptables_jump(ip6_bin, "filter", "FORWARD", &["-j", "TACHYON_FORWARD"]).await;
        }
    }

    Ok(())
}

/// Idempotently reconcile iptables/ipset/policy-routing state (invoked by NDM/Merlin hooks).
pub async fn reconcile_iptables_network_stack(store: &RouterStoreData) -> anyhow::Result<()> {
    apply_iptables_network_stack(store).await
}

async fn teardown_family_iptables(bin: &str) {
    remove_iptables_jump_all(
        bin,
        "mangle",
        "PREROUTING",
        &["-p", "tcp", "-m", "socket", "-j", "TACHYON_DIVERT"],
    )
    .await;
    remove_iptables_jump_all(bin, "mangle", "PREROUTING", &["-j", "TACHYON_PREROUTING"]).await;
    remove_iptables_jump_all(bin, "mangle", "OUTPUT", &["-j", "TACHYON_OUTPUT"]).await;
    remove_iptables_jump_all(bin, "nat", "PREROUTING", &["-j", "TACHYON_DNS_NAT"]).await;
    remove_iptables_jump_all(bin, "nat", "POSTROUTING", &["-j", "TACHYON_POSTROUTING"]).await;
    remove_iptables_jump_all(bin, "filter", "INPUT", &["-j", "TACHYON_INPUT"]).await;
    remove_iptables_jump_all(bin, "filter", "FORWARD", &["-j", "TACHYON_FORWARD"]).await;

    for (table, chain) in [
        ("mangle", "TACHYON_DIVERT"),
        ("mangle", "TACHYON_PREROUTING"),
        ("mangle", "TACHYON_TPROXY"),
        ("mangle", "TACHYON_OUTPUT"),
        ("nat", "TACHYON_DNS_NAT"),
        ("nat", "TACHYON_POSTROUTING"),
        ("filter", "TACHYON_INPUT"),
        ("filter", "TACHYON_FORWARD"),
        ("filter", "TACHYON_GUEST"),
        ("filter", "TACHYON_WEBRTC"),
    ] {
        flush_and_delete_chain(bin, table, chain).await;
    }
}

/// Remove all `TACHYON_*` jumps, chains, ipsets, and TProxy policy routing rules.
pub async fn teardown_iptables_network_stack() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    if let (Some(ipt_bin), _) = select_iptables_pair(false) {
        teardown_family_iptables(&ipt_bin).await;
    }
    if let (Some(ip6_bin), _) = select_iptables_pair(true) {
        teardown_family_iptables(&ip6_bin).await;
    }
    if let Some(ipset_bin) = find_bin_with_path_fallback(IPSET_BIN_CANDIDATES, "ipset") {
        for set_name in [
            IPSET_LOCAL_V4,
            IPSET_EXCL_SRC_V4,
            IPSET_EXCL_MAC,
            IPSET_LOCAL_V6,
            IPSET_EXCL_SRC_V6,
        ] {
            let mut cmd = Command::new(&ipset_bin);
            cmd.args(["destroy", set_name])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            let _ = run_status_with_timeout(&mut cmd, CMD_TIMEOUT).await;
        }
    }
    cleanup_policy_rules().await;
}

/// Activate fail-closed `TACHYON_KILLSWITCH` chain when direct fallback is vetoed.
pub async fn hold_iptables_kill_switch(store: &RouterStoreData) -> Option<String> {
    let Some(veto) = direct_fallback_veto(store) else {
        remove_iptables_kill_switch().await;
        return None;
    };
    if cfg!(target_os = "linux") {
        let ifaces = kill_switch_source_interfaces(&store.settings);
        let rules = compile_iptables_kill_switch(&ifaces);
        if let (Some(ipt_bin), Some(ipt_restore)) = select_iptables_pair(false)
            && run_stdin_command(&ipt_restore, &["--noflush"], &rules)
                .await
                .is_ok()
        {
            ensure_iptables_jump(&ipt_bin, "filter", "FORWARD", &["-j", "TACHYON_KILLSWITCH"])
                .await;
            ensure_iptables_jump(
                &ipt_bin,
                "filter",
                "INPUT",
                &["-j", "TACHYON_KILLSWITCH_IN"],
            )
            .await;
        }
        if let (Some(ip6_bin), Some(ip6_restore)) = select_iptables_pair(true)
            && run_stdin_command(&ip6_restore, &["--noflush"], &rules)
                .await
                .is_ok()
        {
            ensure_iptables_jump(&ip6_bin, "filter", "FORWARD", &["-j", "TACHYON_KILLSWITCH"])
                .await;
            ensure_iptables_jump(
                &ip6_bin,
                "filter",
                "INPUT",
                &["-j", "TACHYON_KILLSWITCH_IN"],
            )
            .await;
        }
    }
    Some(veto)
}

/// Open the kill-switch gate after the network stack and core are healthy.
pub async fn release_iptables_kill_switch(_store: &RouterStoreData) {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    for bin in [select_iptables_pair(false).0, select_iptables_pair(true).0]
        .into_iter()
        .flatten()
    {
        remove_iptables_jump_all(&bin, "filter", "FORWARD", &["-j", "TACHYON_KILLSWITCH"]).await;
        remove_iptables_jump_all(&bin, "filter", "INPUT", &["-j", "TACHYON_KILLSWITCH_IN"]).await;
    }
}

/// Completely remove `TACHYON_KILLSWITCH` jump and chain.
pub async fn remove_iptables_kill_switch() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    for bin in [select_iptables_pair(false).0, select_iptables_pair(true).0]
        .into_iter()
        .flatten()
    {
        remove_iptables_jump_all(&bin, "filter", "FORWARD", &["-j", "TACHYON_KILLSWITCH"]).await;
        remove_iptables_jump_all(&bin, "filter", "INPUT", &["-j", "TACHYON_KILLSWITCH_IN"]).await;
        flush_and_delete_chain(&bin, "filter", "TACHYON_KILLSWITCH").await;
        flush_and_delete_chain(&bin, "filter", "TACHYON_KILLSWITCH_IN").await;
    }
}

/// Check whether Tachyon's iptables jump rules are currently active in the kernel.
pub async fn check_iptables_active(proxy_mode: &str) -> bool {
    if cfg!(not(target_os = "linux")) {
        return true;
    }
    let Some(ipt_bin) = find_bin_with_path_fallback(IPTABLES_BIN_CANDIDATES, "iptables") else {
        return false;
    };
    match proxy_mode.trim().to_ascii_lowercase().as_str() {
        "tproxy" => {
            run_iptables_status(
                &ipt_bin,
                &[
                    "-t",
                    "mangle",
                    "-C",
                    "PREROUTING",
                    "-j",
                    "TACHYON_PREROUTING",
                ],
            )
            .await
        }
        "tun" => {
            run_iptables_status(
                &ipt_bin,
                &["-t", "filter", "-C", "FORWARD", "-j", "TACHYON_FORWARD"],
            )
            .await
                || run_iptables_status(
                    &ipt_bin,
                    &["-t", "nat", "-C", "PREROUTING", "-j", "TACHYON_DNS_NAT"],
                )
                .await
        }
        _ => {
            run_iptables_status(
                &ipt_bin,
                &[
                    "-t",
                    "mangle",
                    "-C",
                    "PREROUTING",
                    "-j",
                    "TACHYON_PREROUTING",
                ],
            )
            .await
                || run_iptables_status(
                    &ipt_bin,
                    &["-t", "filter", "-C", "FORWARD", "-j", "TACHYON_FORWARD"],
                )
                .await
                || run_iptables_status(
                    &ipt_bin,
                    &["-t", "nat", "-C", "PREROUTING", "-j", "TACHYON_DNS_NAT"],
                )
                .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_select_preferred_bin_prefers_system_over_opt() {
        let found = select_preferred_bin(IPTABLES_BIN_CANDIDATES, |p| {
            matches!(p, "/sbin/iptables" | "/opt/sbin/iptables")
        });
        assert_eq!(found.as_deref(), Some("/sbin/iptables"));

        let opt_only = select_preferred_bin(IPTABLES_BIN_CANDIDATES, |p| p == "/opt/sbin/iptables");
        assert_eq!(opt_only.as_deref(), Some("/opt/sbin/iptables"));
    }

    #[test]
    fn test_parse_entware_net_caps_from_signals() {
        let caps = parse_entware_net_caps_from_signals(
            Some("/usr/sbin/iptables".to_string()),
            Some("/usr/sbin/ip6tables".to_string()),
            true,
            true,
            "MARK\nTPROXY\nREDIRECT\n",
            "comment\nsocket\nset\n",
            true,
        );
        assert!(caps.has_iptables);
        assert!(caps.has_ip6tables);
        assert!(caps.has_iptables_restore);
        assert!(caps.has_ipset);
        assert!(caps.has_tproxy);
        assert!(caps.has_socket_match);
        assert!(caps.has_tun);

        let no_tproxy = parse_entware_net_caps_from_signals(
            Some("/sbin/iptables".to_string()),
            None,
            true,
            true,
            "MARK\nREDIRECT\n",
            "comment\n",
            true,
        );
        assert!(!no_tproxy.has_tproxy);
        assert!(!no_tproxy.has_socket_match);
        assert!(no_tproxy.has_tun);
    }

    #[test]
    fn test_compile_ipset_restore_script_atomic_swap_and_macs() {
        let mut store = RouterStoreData::default();
        store.settings.excluded_ips = vec![
            "192.168.1.50".to_string(),
            "10.10.0.0/24".to_string(),
            "AA:BB:CC:DD:EE:FF".to_string(),
            "fd00::10/128".to_string(),
        ];

        let script = compile_ipset_restore_script(&store, true);
        assert!(script.contains("create tachyon_local_v4_tmp hash:net family inet -exist"));
        assert!(script.contains("flush tachyon_local_v4_tmp"));
        assert!(script.contains("add tachyon_local_v4_tmp 192.168.0.0/16 -exist"));
        assert!(script.contains("swap tachyon_local_v4_tmp tachyon_local_v4"));
        assert!(script.contains("destroy tachyon_local_v4_tmp"));

        assert!(script.contains("add tachyon_excl_src_v4_tmp 192.168.1.50 -exist"));
        assert!(script.contains("add tachyon_excl_src_v4_tmp 10.10.0.0/24 -exist"));
        assert!(script.contains("swap tachyon_excl_src_v4_tmp tachyon_excl_src_v4"));

        assert!(script.contains("create tachyon_excl_mac_tmp hash:mac -exist"));
        assert!(script.contains("add tachyon_excl_mac_tmp aa:bb:cc:dd:ee:ff -exist"));
        assert!(script.contains("swap tachyon_excl_mac_tmp tachyon_excl_mac"));

        assert!(script.contains("create tachyon_local_v6_tmp hash:net family inet6 -exist"));
        assert!(script.contains("add tachyon_excl_src_v6_tmp fd00::10/128 -exist"));

        // Without MAC exclusions, tachyon_excl_mac must not be emitted
        store.settings.excluded_ips = vec!["192.168.1.50".to_string()];
        let no_mac_script = compile_ipset_restore_script(&store, false);
        assert!(!no_mac_script.contains("tachyon_excl_mac"));
        assert!(!no_mac_script.contains("tachyon_local_v6"));
    }

    #[test]
    fn test_compile_iptables_tproxy_ruleset_ordering_and_guards() {
        let mut store = RouterStoreData::default();
        store.settings.source_network_interfaces = vec!["br0".to_string()];
        store.settings.fakeip_enabled = true;
        store.settings.route_router_traffic = true;
        store.settings.block_doh = true;
        store.settings.webrtc_leak_protect = true;
        store.settings.entware_dns_mode = "redirect".to_string();
        store.settings.entware_dns_port = 1053;
        store.settings.excluded_ips =
            vec!["192.168.1.77".to_string(), "aa:bb:cc:dd:ee:11".to_string()];
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "ts_emb".to_string(),
            enabled: true,
            source_type: "tailscale".to_string(),
            tailscale_mode: "singbox".to_string(),
            ..Default::default()
        });

        let (v4, v6_opt) = compile_iptables_tproxy_ruleset(&store, true, 1053);
        let v6 = v6_opt.expect("IPv6 ruleset must be emitted when ipv6_active=true");

        // *mangle TACHYON_DIVERT, TACHYON_PREROUTING, TACHYON_OUTPUT
        assert!(v4.contains("*mangle"));
        assert!(v4.contains("-A TACHYON_DIVERT -j MARK --set-mark 0x04000000"));
        assert!(v4.contains("-A TACHYON_DIVERT -j ACCEPT"));
        assert!(v4.contains("-m mark --mark 0x40000000/0x40000000 -j RETURN"));
        assert!(v4.contains("-m set --match-set tachyon_excl_src_v4 src -j RETURN"));
        assert!(v4.contains("-m set --match-set tachyon_excl_mac src -j RETURN"));
        assert!(v4.contains("-m owner --gid-owner 65533 -j RETURN"));
        assert!(v4.contains("-A TACHYON_OUTPUT -p tcp -j MARK --set-mark 0x10000000"));

        // FakeIP 198.18.0.0/15 and Tailscale CGNAT 100.64.0.0/10 MUST precede tachyon_local_v4 return
        let idx_fakeip = v4
            .find("-p tcp -d 198.18.0.0/15 -j TPROXY --on-port 1602 --on-ip 127.0.0.1 --tproxy-mark 0x04000000/0x04000000")
            .expect("FakeIP TPROXY rule");
        let idx_ts = v4
            .find("-p tcp -d 100.64.0.0/10 -j TPROXY --on-port 1602 --on-ip 127.0.0.1 --tproxy-mark 0x04000000/0x04000000")
            .expect("Tailscale CGNAT TPROXY rule");
        let idx_local = v4
            .find("-m set --match-set tachyon_local_v4 dst -j RETURN")
            .expect("local v4 return");
        assert!(idx_fakeip < idx_local);
        assert!(idx_ts < idx_local);

        // *nat TACHYON_DNS_NAT redirects LAN :53 to :1053
        assert!(
            v4.contains("-A TACHYON_DNS_NAT -i br0 -p udp --dport 53 -j REDIRECT --to-ports 1053")
        );
        assert!(
            v4.contains("-A TACHYON_DNS_NAT -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 1053")
        );

        // *filter TACHYON_INPUT protects dns_port & TPROXY port from non-LAN
        assert!(v4.contains("-A TACHYON_INPUT -i br0 -j RETURN"));
        assert!(v4.contains("-A TACHYON_INPUT -p udp --dport 1053 -j DROP"));
        assert!(v4.contains("-A TACHYON_INPUT -p tcp --dport 1602 -j DROP"));

        // *filter TACHYON_FORWARD enforces DoH & WebRTC
        assert!(v4.contains(
            "-A TACHYON_FORWARD -d 1.1.1.1 -p tcp -m multiport --dports 443,853 -j REJECT"
        ));
        assert!(
            v4.contains("-A TACHYON_WEBRTC -p udp -m multiport --dports 3478,5349,19302 -j REJECT")
        );

        // IPv6 uses ::1 and tachyon_local_v6
        assert!(v6.contains("--on-ip ::1 --tproxy-mark 0x04000000/0x04000000"));
        assert!(v6.contains("tachyon_local_v6"));

        // Override mode disables DNS NAT redirect rules
        store.settings.entware_dns_mode = "override".to_string();
        let (v4_ovr, _) = compile_iptables_tproxy_ruleset(&store, false, 53);
        assert!(!v4_ovr.contains("-j REDIRECT --to-ports"));
    }

    #[test]
    fn test_compile_iptables_tun_and_kill_switch() {
        let mut store = RouterStoreData::default();
        store.settings.proxy_mode = "tun".to_string();
        store.settings.tun_interface = "tun0".to_string();
        store.settings.source_network_interfaces = vec!["br0".to_string()];

        let (v4, v6) = compile_iptables_tun_ruleset(&store, false, 1053);
        assert!(v6.is_none());
        assert!(v4.contains("-A TACHYON_FORWARD -i tun0 -j ACCEPT"));
        assert!(v4.contains("-A TACHYON_FORWARD -o tun0 -j ACCEPT"));
        assert!(v4.contains("-A TACHYON_POSTROUTING -o tun0 -j MASQUERADE"));
        assert!(
            v4.contains("-A TACHYON_DNS_NAT -i br0 -p udp --dport 53 -j REDIRECT --to-ports 1053")
        );

        let ks = compile_iptables_kill_switch(&["br0".to_string(), "br1".to_string()]);
        assert!(ks.contains(":TACHYON_KILLSWITCH - [0:0]"));
        assert!(ks.contains("-A TACHYON_KILLSWITCH -i br0 -o br0 -j RETURN"));
        assert!(ks.contains("-A TACHYON_KILLSWITCH -i br0 -o br1 -j RETURN"));
        assert!(ks.contains("-A TACHYON_KILLSWITCH -i br0 -j DROP"));
        assert!(ks.contains("-A TACHYON_KILLSWITCH -i br1 -j DROP"));
    }

    #[test]
    fn test_compile_iptables_preview_outputs_ipset_and_rules() {
        let mut store = RouterStoreData::default();
        store.settings.source_network_interfaces = vec!["br0".to_string()];
        store.settings.entware_dns_mode = "redirect".to_string();
        store.settings.entware_dns_port = 1053;
        let preview = compile_iptables_preview(&store);
        assert!(preview.contains("# === ipset restore -! ==="));
        assert!(preview.contains("# === iptables-restore --noflush (IPv4) ==="));
        assert!(preview.contains("TACHYON_PREROUTING"));
        assert!(preview.contains("TACHYON_DNS_NAT"));
    }

    #[test]
    fn test_iptables_restore_chain_declarations_precede_rules_and_keenetic_caps() {
        let mut store = RouterStoreData::default();
        store.settings.source_network_interfaces = vec!["br0".to_string()];
        store.settings.fakeip_enabled = true;
        store.settings.block_doh = true;
        store.settings.webrtc_leak_protect = true;
        store.settings.disable_quic = true;
        store.settings.entware_dns_mode = "redirect".to_string();
        store.settings.entware_dns_port = 1053;
        store.guest_mode.enabled = true;
        store.guest_mode.mode = "zero_trust".to_string();
        store.guest_mode.isolate_lan = true;

        let keenetic_caps = parse_entware_net_caps_from_signals(
            Some("/opt/sbin/iptables".to_string()),
            None,
            true,
            true,
            "MARK\nTPROXY\nREDIRECT\n",
            "comment\nsocket\nset\nmark\n",
            true,
        );
        assert!(!keenetic_caps.has_owner);
        assert!(!keenetic_caps.has_addrtype);
        assert!(!keenetic_caps.has_conntrack);
        assert!(!keenetic_caps.has_multiport);
        assert!(!keenetic_caps.has_reject);

        let (v4, _) =
            compile_iptables_tproxy_ruleset_with_caps(&store, false, 1053, &keenetic_caps);
        assert!(!v4.contains("-m owner"));
        assert!(!v4.contains("-m addrtype"));
        assert!(!v4.contains("-m conntrack"));
        assert!(!v4.contains("-m multiport"));
        assert!(!v4.contains("-j REJECT"));
        assert!(v4.contains("-j DROP"));
        assert!(v4.contains("-m mark --mark 0x00200000/0x00200000 -j RETURN"));
        assert!(v4.contains("-m mark --mark 0x00040000/0x00040000 -j RETURN"));
        assert!(!v4.contains("0x00340000/0x00340000"));

        // Verify EVERY table in both TProxy and TUN modes declares/flushes all :CHAIN before any -A rule.
        let (tun_v4, _) = compile_iptables_tun_ruleset(&store, false, 1053);
        for ruleset in [v4, tun_v4] {
            let mut seen_append_in_table = false;
            for line in ruleset.lines() {
                let t = line.trim();
                if t.starts_with('*') || t == "COMMIT" {
                    seen_append_in_table = false;
                } else if t.starts_with(':') || t.starts_with("-F ") {
                    assert!(
                        !seen_append_in_table,
                        "chain declaration/flush `{t}` must appear before any -A rule in:\n{ruleset}"
                    );
                } else if t.starts_with("-A ") {
                    seen_append_in_table = true;
                }
            }
        }
    }
}
