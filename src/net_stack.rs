//! OpenWrt networking stack orchestrator:
//! - Compiles and atomically applies `nftables` (`table inet TachyonTable`) via `nft -f -`
//! - Manages Policy Routing (`ip rule` / `ip route` table 100 for TProxy `:1602`)
//! - Coordinates `dnsmasq` upstream forwarding to `127.0.0.42#53` without NAND flash wear.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::crypto_gen;
use crate::store::{EffectiveIpv6State, RouterStoreData};

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
pub const TPROXY6_LISTEN_ADDR: &str = "::1";

fn parse_port_spec_tokens(spec: &str, out: &mut Vec<u16>) {
    for tok in spec.split([',', ' ', '\t']) {
        let t = tok.trim();
        if t.is_empty() {
            continue;
        }
        let norm = t.replace(':', "-");
        if let Some((a_s, b_s)) = norm.split_once('-') {
            if let (Ok(lo), Ok(hi)) = (a_s.trim().parse::<u16>(), b_s.trim().parse::<u16>())
                && lo > 0
                && hi >= lo
            {
                let capped_hi = hi.min(lo.saturating_add(64));
                for p in lo..=capped_hi {
                    out.push(p);
                }
            }
        } else if let Ok(p) = norm.parse::<u16>()
            && p > 0
        {
            out.push(p);
        }
    }
}

fn push_nz_port(ports: &mut Vec<u16>, p: u16) {
    if p > 0 {
        ports.push(p);
    }
}

fn collect_proxy_udp_ports(store: &RouterStoreData) -> Vec<u16> {
    let mut ports: Vec<u16> = Vec::new();

    for src in store.outbound_sources.iter().filter(|s| s.enabled) {
        push_nz_port(&mut ports, src.server_port);
        push_nz_port(&mut ports, src.warp_server_port);
        push_nz_port(&mut ports, src.csqtt_server_port);
        push_nz_port(&mut ports, src.csqtt_raw_port);
        push_nz_port(&mut ports, src.csqtt_wg_port);
        for node in &src.cached_nodes {
            push_nz_port(&mut ports, node.server_port);
            if let Some(p) = node
                .outbound_json
                .get("server_port")
                .and_then(|v| v.as_u64())
                .and_then(|v| u16::try_from(v).ok())
            {
                push_nz_port(&mut ports, p);
            }
            if let Some(p) = node
                .outbound_json
                .get("port")
                .and_then(|v| v.as_u64())
                .and_then(|v| u16::try_from(v).ok())
            {
                push_nz_port(&mut ports, p);
            }
            if let Some(peers) = node.outbound_json.get("peers").and_then(|v| v.as_array()) {
                for peer in peers {
                    if let Some(p) = peer
                        .get("server_port")
                        .and_then(|v| v.as_u64())
                        .and_then(|v| u16::try_from(v).ok())
                    {
                        push_nz_port(&mut ports, p);
                    }
                }
            }
            if let Some(sp) = node
                .outbound_json
                .get("server_ports")
                .and_then(|v| v.as_array())
            {
                for item in sp {
                    if let Some(s) = item.as_str() {
                        parse_port_spec_tokens(s, &mut ports);
                    }
                }
            }
        }
    }

    for srv in store.servers.iter().filter(|s| s.enabled) {
        push_nz_port(&mut ports, srv.listen_port);
        push_nz_port(&mut ports, srv.wdtt_raw_port);
        if !srv.listen_port_range.trim().is_empty() {
            parse_port_spec_tokens(&srv.listen_port_range, &mut ports);
        }
    }

    for sec in store.sections.iter().filter(|s| s.enabled) {
        push_nz_port(&mut ports, sec.csqtt_server_port);
        push_nz_port(&mut ports, sec.csqtt_raw_port);
        push_nz_port(&mut ports, sec.csqtt_wg_port);
    }

    ports.sort_unstable();
    ports.dedup();
    ports
}

fn format_localv6_elements(fakeip_v6: &str, extra_local_v6: &[String]) -> String {
    let mut elems = vec![
        "::1/128".to_string(),
        "64:ff9b::/96".to_string(),
        "100::/64".to_string(),
        "2001:db8::/32".to_string(),
        "fc00::/7".to_string(),
        "fe80::/10".to_string(),
        "ff00::/8".to_string(),
    ];
    for raw in extra_local_v6 {
        let p = raw.trim();
        if p.is_empty() || !p.contains(':') {
            continue;
        }
        let Some(masked) = crate::store::mask_cidr(p) else {
            continue;
        };
        if !masked.contains(':') {
            continue;
        }
        let overlaps_builtin = elems
            .iter()
            .any(|b| crate::store::cidr_v6_overlaps(&masked, b))
            || crate::store::cidr_v6_overlaps(&masked, fakeip_v6);
        if !overlaps_builtin && !elems.iter().any(|e| e == &masked) {
            elems.push(masked);
        }
    }
    elems.join(",\n            ")
}

fn collect_managed_lan_ifaces(store: &RouterStoreData) -> Vec<String> {
    let mut excluded: Vec<String> = collect_tailscale_bypass_ifaces(store)
        .into_iter()
        .map(|s| s.to_ascii_lowercase())
        .collect();
    for static_excl in ["lo", "wan", "wan6"] {
        excluded.push(static_excl.to_string());
    }
    for opt in [
        &store.settings.output_network_interface,
        &store.settings.wan_failover_primary,
        &store.settings.wan_failover_backup,
        &store.settings.tun_interface,
    ] {
        if let Some(clean) = sanitize_iface_name(opt) {
            excluded.push(clean.to_ascii_lowercase());
        }
    }
    for opt in &store.settings.badwan_monitored_interfaces {
        if let Some(clean) = sanitize_iface_name(opt) {
            excluded.push(clean.to_ascii_lowercase());
        }
    }

    let mut lan_ifaces = Vec::new();
    for raw in &store.settings.source_network_interfaces {
        let Some(clean) = sanitize_iface_name(raw) else {
            continue;
        };
        let lower = clean.to_ascii_lowercase();
        if excluded.iter().any(|e| e == &lower)
            || lower.starts_with("tun")
            || lower.starts_with("tap")
            || lower.starts_with("tailscale")
            || lower.starts_with("fptn")
            || lower.starts_with("wg")
            || lower.starts_with("awg")
            || lower.starts_with("utun")
            || lower.starts_with("wan")
        {
            continue;
        }
        if !lan_ifaces.iter().any(|x| x == &clean) {
            lan_ifaces.push(clean);
        }
    }
    if lan_ifaces.is_empty() {
        lan_ifaces.push("br-lan".to_string());
    } else if !lan_ifaces.iter().any(|x| x == "br-lan") && !excluded.iter().any(|e| e == "br-lan") {
        lan_ifaces.insert(0, "br-lan".to_string());
    }
    lan_ifaces
}

fn append_webrtc_filter_chain(
    out: &mut String,
    bypass_ifaces_literal: &str,
    proxy_udp_ports_literal: &str,
) {
    let _ = writeln!(out, "    chain webrtc_filter {{");
    let _ = writeln!(out, "        iifname {{ {bypass_ifaces_literal} }} return");
    let _ = writeln!(out, "        meta mark {ROUTER_TPROXY_FWMARK} return");
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
    if !proxy_udp_ports_literal.is_empty() {
        let _ = writeln!(
            out,
            "        udp dport {{ {proxy_udp_ports_literal} }} return"
        );
        let _ = writeln!(
            out,
            "        udp sport {{ {proxy_udp_ports_literal} }} return"
        );
    }
    let _ = writeln!(out, "        udp dport {{ 3478, 5349, 19302 }} reject");
    let _ = writeln!(out, "    }}");
}

fn append_lan_ipv6_isolation_chains(
    out: &mut String,
    lan_ifaces: &[String],
    ipv6_active: bool,
    forward_guard: bool,
) {
    let lan_ifaces_literal = lan_ifaces
        .iter()
        .map(|i| format!("\"{i}\""))
        .collect::<Vec<_>>()
        .join(", ");
    if !ipv6_active && !lan_ifaces_literal.is_empty() {
        let _ = writeln!(
            out,
            "    chain lan_ipv6_guard_in {{
        type filter hook input priority filter; policy accept;
        iifname {{ {lan_ifaces_literal} }} icmpv6 type nd-router-solicit drop
        iifname {{ {lan_ifaces_literal} }} udp sport 546 udp dport 547 drop
    }}"
        );
        let _ = writeln!(
            out,
            "    chain lan_ipv6_guard_out {{
        type filter hook output priority filter; policy accept;
        oifname {{ {lan_ifaces_literal} }} icmpv6 type nd-router-advert drop
        oifname {{ {lan_ifaces_literal} }} udp sport 547 udp dport 546 drop
    }}"
        );
    }
    if forward_guard {
        let _ = writeln!(out, "    chain ipv6_forward_guard {{");
        let _ = writeln!(
            out,
            "        type filter hook forward priority filter; policy accept;"
        );
        if !ipv6_active && !lan_ifaces_literal.is_empty() {
            let _ = writeln!(
                out,
                "        iifname {{ {lan_ifaces_literal} }} icmpv6 type nd-router-solicit drop"
            );
            let _ = writeln!(
                out,
                "        oifname {{ {lan_ifaces_literal} }} icmpv6 type nd-router-advert drop"
            );
            let _ = writeln!(
                out,
                "        iifname {{ {lan_ifaces_literal} }} udp sport 546 udp dport 547 drop"
            );
            let _ = writeln!(
                out,
                "        oifname {{ {lan_ifaces_literal} }} udp sport 547 udp dport 546 drop"
            );
        }
        let _ = writeln!(
            out,
            "        icmpv6 type {{ destination-unreachable, packet-too-big, time-exceeded, parameter-problem }} return"
        );
        let _ = writeln!(out, "        ip6 daddr @localv6 return");
        let _ = writeln!(
            out,
            "        meta nfproto ipv6 reject with icmpx type admin-prohibited"
        );
        let _ = writeln!(out, "    }}");
    }
}

/// Compile the complete `inet TachyonTable` nftables ruleset from `RouterStoreData`.
/// With native `tachyon-core` handling all protocols (`desync`, `wdtt`, `fptn`, `tailscale`, `proxy`),
/// there are zero `NFQUEUE` chains and zero local `ciadpi` redirects — a single clean TProxy contour.
pub fn compile_nftables_ruleset(store: &RouterStoreData) -> String {
    let wan6 = crate::store::detect_wan6_runtime_available();
    let cache = crate::store::load_cached_wan6_runtime_state();
    compile_nftables_ruleset_with_wan6(store, wan6, &cache.wan6_prefixes)
}

pub fn compile_nftables_ruleset_with_wan6(
    store: &RouterStoreData,
    wan6_available: bool,
    extra_local_v6: &[String],
) -> String {
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&store.settings, wan6_available);
    let ipv6_active = ipv6_state.is_active();
    let ipv6_mode_off = crate::store::normalize_ipv6_mode(&store.settings.ipv6_mode) == "off";
    let forward_guard = ipv6_state.is_leak_guard() || ipv6_mode_off;
    let need_localv6 = ipv6_active || forward_guard;
    let lan_ifaces = collect_managed_lan_ifaces(store);

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

    if need_localv6 {
        let localv6_elems = format_localv6_elements(fakeip_v6, extra_local_v6);
        let _ = writeln!(
            out,
            "    set localv6 {{
        type ipv6_addr
        flags interval
        elements = {{
            {localv6_elems}
        }}
    }}"
        );
    }

    let bypass_ifaces_literal = collect_tailscale_bypass_ifaces(store)
        .into_iter()
        .map(|i| format!("\"{i}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let proxy_udp_ports = collect_proxy_udp_ports(store);
    let proxy_udp_ports_literal = proxy_udp_ports
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(", ");

    if store.settings.webrtc_leak_protect {
        append_webrtc_filter_chain(&mut out, &bypass_ifaces_literal, &proxy_udp_ports_literal);
    }

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

    // Guest mode LAN isolation, router admin protection, port allowlist & rate shaping (IPv4 + IPv6 + MAC)
    if store.guest_mode.enabled {
        let mut guests_v4: Vec<String> = Vec::new();
        let mut guests_v6: Vec<String> = Vec::new();
        let mut guests_mac: Vec<String> = Vec::new();
        for g_raw in &store.guest_mode.guest_devices {
            let g = g_raw.trim();
            if g.is_empty() {
                continue;
            }
            if crate::store::is_mac_address(g) {
                guests_mac.push(g.to_ascii_lowercase());
            } else if let Some((ip_part, prefix_part)) = g.split_once('/') {
                if let (Ok(_), Ok(p)) = (
                    ip_part.parse::<std::net::Ipv4Addr>(),
                    prefix_part.parse::<u8>(),
                ) && p <= 32
                {
                    guests_v4.push(g.to_string());
                } else if let (Ok(_), Ok(p)) = (
                    ip_part.parse::<std::net::Ipv6Addr>(),
                    prefix_part.parse::<u8>(),
                ) && p <= 128
                {
                    guests_v6.push(g.to_string());
                }
            } else if g.parse::<std::net::Ipv4Addr>().is_ok() {
                guests_v4.push(g.to_string());
            } else if g.parse::<std::net::Ipv6Addr>().is_ok() {
                guests_v6.push(g.to_string());
            }
        }
        let guest_allowed_ports = if !store.guest_mode.allowed_ports.is_empty() {
            let mut ports: Vec<u16> = store.guest_mode.allowed_ports.clone();
            if !ports.contains(&53) {
                ports.push(53);
            }
            ports.sort_unstable();
            ports.dedup();
            Some(
                ports
                    .iter()
                    .map(u16::to_string)
                    .collect::<Vec<_>>()
                    .join(", "),
            )
        } else {
            None
        };
        let fakeip_v6_exempt_clause =
            if store.guest_mode.allow_proxy && ipv6_active && store.settings.fakeip_enabled {
                format!(" ip6 daddr != {fakeip_v6}")
            } else {
                String::new()
            };
        if !guests_v4.is_empty() {
            let guest_set = guests_v4.join(", ");
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
            if let Some(ref port_list) = guest_allowed_ports {
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
            if !store.guest_mode.allow_proxy {
                let _ = writeln!(out, "        ip saddr {{ {guest_set} }} return");
            }
        }
        if !guests_v6.is_empty() {
            let guest6_set = guests_v6.join(", ");
            if need_localv6 {
                if store.guest_mode.block_router_admin {
                    let _ = writeln!(
                        out,
                        "        ip6 saddr {{ {guest6_set} }} ip6 daddr @localv6{fakeip_v6_exempt_clause} meta l4proto {{ tcp, udp }} th dport {{ 22, 80, 443, 1680, 9090 }} drop"
                    );
                }
                if store.guest_mode.isolate_lan {
                    let _ = writeln!(
                        out,
                        "        ip6 saddr {{ {guest6_set} }} ip6 daddr @localv6{fakeip_v6_exempt_clause} meta l4proto {{ tcp, udp }} th dport != 53 drop"
                    );
                }
                if let Some(ref port_list) = guest_allowed_ports {
                    let _ = writeln!(
                        out,
                        "        ip6 saddr {{ {guest6_set} }} ip6 daddr != @localv6 meta l4proto {{ tcp, udp }} th dport != {{ {port_list} }} drop"
                    );
                }
                if store.guest_mode.bandwidth_limit_mbps > 0 {
                    let rate_kbytes =
                        (u64::from(store.guest_mode.bandwidth_limit_mbps) * 125).max(1);
                    let _ = writeln!(
                        out,
                        "        ip6 saddr {{ {guest6_set} }} limit rate over {rate_kbytes} kbytes/second drop"
                    );
                    let _ = writeln!(
                        out,
                        "        ip6 daddr {{ {guest6_set} }} limit rate over {rate_kbytes} kbytes/second drop"
                    );
                }
            }
            if !store.guest_mode.allow_proxy {
                let _ = writeln!(out, "        ip6 saddr {{ {guest6_set} }} return");
            }
        }
        if !guests_mac.is_empty() {
            let mac_set = guests_mac.join(", ");
            if store.guest_mode.block_router_admin {
                let _ = writeln!(
                    out,
                    "        ether saddr {{ {mac_set} }} ip daddr @localv4 meta l4proto {{ tcp, udp }} th dport {{ 22, 80, 443, 1680, 9090 }} drop"
                );
                if need_localv6 {
                    let _ = writeln!(
                        out,
                        "        ether saddr {{ {mac_set} }} ip6 daddr @localv6{fakeip_v6_exempt_clause} meta l4proto {{ tcp, udp }} th dport {{ 22, 80, 443, 1680, 9090 }} drop"
                    );
                }
            }
            if store.guest_mode.isolate_lan {
                let _ = writeln!(
                    out,
                    "        ether saddr {{ {mac_set} }} ip daddr @localv4 meta l4proto {{ tcp, udp }} th dport != 53 drop"
                );
                if need_localv6 {
                    let _ = writeln!(
                        out,
                        "        ether saddr {{ {mac_set} }} ip6 daddr @localv6{fakeip_v6_exempt_clause} meta l4proto {{ tcp, udp }} th dport != 53 drop"
                    );
                }
            }
            if let Some(ref port_list) = guest_allowed_ports {
                let _ = writeln!(
                    out,
                    "        ether saddr {{ {mac_set} }} ip daddr != @localv4 meta l4proto {{ tcp, udp }} th dport != {{ {port_list} }} drop"
                );
            }
            if store.guest_mode.bandwidth_limit_mbps > 0 {
                let rate_kbytes = (u64::from(store.guest_mode.bandwidth_limit_mbps) * 125).max(1);
                let _ = writeln!(
                    out,
                    "        ether saddr {{ {mac_set} }} limit rate over {rate_kbytes} kbytes/second drop"
                );
            }
            if !store.guest_mode.allow_proxy {
                let _ = writeln!(out, "        ether saddr {{ {mac_set} }} return");
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
        if ipv6_active && !TPROXY6_LISTEN_ADDR.trim().is_empty() {
            let _ = writeln!(
                out,
                "        ip6 daddr fd7a:115c:a1e0::/48 meta l4proto {{ tcp, udp }} tproxy ip6 to [{TPROXY6_LISTEN_ADDR}]:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
            );
        }
    }

    // Intercept DNS queries (`:53`) to `tachyon-core` FakeIP/DNS listener (`127.0.0.42:53`)
    let _ = writeln!(out, "        ip daddr @localv4 return");
    if ipv6_active {
        if store.settings.fakeip_enabled && !TPROXY6_LISTEN_ADDR.trim().is_empty() {
            let _ = writeln!(
                out,
                "        ip6 daddr {fakeip_v6} meta l4proto {{ tcp, udp }} tproxy ip6 to [{TPROXY6_LISTEN_ADDR}]:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
            );
        }
        let _ = writeln!(out, "        meta l4proto icmpv6 return");
        let _ = writeln!(
            out,
            "        ip6 daddr @localv6 ip6 daddr != {fakeip_v6} return"
        );
    } else if forward_guard {
        let _ = writeln!(
            out,
            "        icmpv6 type {{ destination-unreachable, packet-too-big, time-exceeded, parameter-problem }} return"
        );
        let _ = writeln!(out, "        ip6 daddr @localv6 return");
        let _ = writeln!(
            out,
            "        meta nfproto ipv6 meta l4proto {{ tcp, udp }} th dport {{ 53, 853 }} reject with icmpx type admin-prohibited"
        );
        let _ = writeln!(
            out,
            "        ip6 daddr {{ 2606:4700:4700::1111, 2606:4700:4700::1001, 2001:4860:4860::8888, 2001:4860:4860::8844, 2620:fe::fe, 2620:fe::9 }} tcp dport {{ 443, 853 }} reject with icmpx type admin-prohibited"
        );
        let _ = writeln!(
            out,
            "        meta nfproto ipv6 reject with icmpx type admin-prohibited"
        );
    } else {
        let _ = writeln!(out, "        meta nfproto ipv6 return");
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
    let fptn_v4: Vec<String> = fptn_ips
        .iter()
        .filter(|s| s.parse::<std::net::Ipv4Addr>().is_ok())
        .cloned()
        .collect();
    let fptn_v6: Vec<String> = fptn_ips
        .iter()
        .filter(|s| s.parse::<std::net::Ipv6Addr>().is_ok())
        .cloned()
        .collect();
    if !fptn_v4.is_empty() {
        let _ = writeln!(out, "        ip daddr {{ {} }} return", fptn_v4.join(", "));
    }
    if !fptn_v6.is_empty() && ipv6_active {
        let _ = writeln!(out, "        ip6 daddr {{ {} }} return", fptn_v6.join(", "));
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

    if store.settings.webrtc_leak_protect {
        let _ = writeln!(out, "        jump webrtc_filter");
    }

    if store.settings.disable_quic {
        let _ = writeln!(out, "        udp dport 443 reject");
    }

    if store.settings.block_doh {
        let _ = writeln!(
            out,
            "        ip daddr {{ 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9 }} tcp dport {{ 443, 853 }} reject"
        );
        if ipv6_active {
            let _ = writeln!(
                out,
                "        ip6 daddr {{ 2606:4700:4700::1111, 2606:4700:4700::1001, 2001:4860:4860::8888, 2001:4860:4860::8844, 2620:fe::fe, 2620:fe::9 }} tcp dport {{ 443, 853 }} reject"
            );
        }
    }

    let _ = writeln!(
        out,
        "        meta l4proto {{ tcp, udp }} tproxy ip to 127.0.0.1:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
    );
    if ipv6_active && !TPROXY6_LISTEN_ADDR.trim().is_empty() {
        let _ = writeln!(
            out,
            "        meta l4proto {{ tcp, udp }} tproxy ip6 to [{TPROXY6_LISTEN_ADDR}]:{TPROXY_PORT} meta mark set {TPROXY_FWMARK} accept"
        );
    }

    let _ = writeln!(out, "    }}");

    // Router-originated traffic (`OUTPUT` hook): prevent loops via `BYPASS_FWMARK`,
    // always intercept router FakeIP connections so local checks/tools work, and optionally
    // intercept all non-local router traffic when `route_router_traffic` is enabled.
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
    if !fptn_v4.is_empty() {
        let _ = writeln!(out, "        ip daddr {{ {} }} return", fptn_v4.join(", "));
    }
    if !fptn_v6.is_empty() && ipv6_active {
        let _ = writeln!(out, "        ip6 daddr {{ {} }} return", fptn_v6.join(", "));
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
    if store.settings.fakeip_enabled {
        let _ = writeln!(
            out,
            "        ip daddr {fakeip_v4} meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
        );
    }
    if ipv6_active {
        if store.settings.fakeip_enabled {
            let _ = writeln!(
                out,
                "        ip6 daddr {fakeip_v6} meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
            );
        }
        if intercept_embedded_ts {
            let _ = writeln!(
                out,
                "        ip6 daddr fd7a:115c:a1e0::/48 meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
            );
        }
        let _ = writeln!(out, "        ip6 daddr @localv6 return");
    } else if forward_guard {
        let _ = writeln!(
            out,
            "        icmpv6 type {{ destination-unreachable, packet-too-big, time-exceeded, parameter-problem }} return"
        );
        let _ = writeln!(out, "        ip6 daddr @localv6 return");
        let _ = writeln!(
            out,
            "        meta nfproto ipv6 reject with icmpx type admin-prohibited"
        );
    }
    if store.settings.webrtc_leak_protect {
        if !proxy_udp_ports_literal.is_empty() {
            let _ = writeln!(
                out,
                "        udp dport {{ {proxy_udp_ports_literal} }} return"
            );
            let _ = writeln!(
                out,
                "        udp sport {{ {proxy_udp_ports_literal} }} return"
            );
        }
        let _ = writeln!(out, "        udp dport {{ 3478, 5349, 19302 }} reject");
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
            if ipv6_active {
                let _ = writeln!(
                    out,
                    "        ip6 daddr {{ 2606:4700:4700::1111, 2606:4700:4700::1001, 2001:4860:4860::8888, 2001:4860:4860::8844, 2620:fe::fe, 2620:fe::9 }} tcp dport {{ 443, 853 }} reject"
                );
            }
        }
        let _ = writeln!(
            out,
            "        meta l4proto {{ tcp, udp }} meta mark set {ROUTER_TPROXY_FWMARK} accept"
        );
    }
    let _ = writeln!(out, "    }}");

    if store.settings.webrtc_leak_protect {
        let _ = writeln!(
            out,
            "    chain webrtc_forward {{
        type filter hook forward priority filter; policy accept;
        oifname {{ {bypass_ifaces_literal} }} return
        jump webrtc_filter
    }}"
        );
    }
    append_lan_ipv6_isolation_chains(&mut out, &lan_ifaces, ipv6_active, forward_guard);

    let _ = writeln!(out, "}}");
    out
}

pub fn compile_tun_guard_ruleset_with_wan6(
    store: &RouterStoreData,
    wan6_available: bool,
    extra_local_v6: &[String],
) -> Option<String> {
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&store.settings, wan6_available);
    let ipv6_active = ipv6_state.is_active();
    let ipv6_mode_off = crate::store::normalize_ipv6_mode(&store.settings.ipv6_mode) == "off";
    let forward_guard = ipv6_state.is_leak_guard() || ipv6_mode_off;
    if !store.settings.webrtc_leak_protect && ipv6_active && !forward_guard {
        return None;
    }
    let lan_ifaces = collect_managed_lan_ifaces(store);
    let fakeip_v6 = if store.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        store.settings.fakeip_inet6_range.trim()
    };
    let mut bypass_ifaces = collect_tailscale_bypass_ifaces(store);
    if let Some(tun_if) = sanitize_iface_name(&store.settings.tun_interface)
        && !bypass_ifaces.iter().any(|i| i == &tun_if)
    {
        bypass_ifaces.push(tun_if);
    }
    let bypass_ifaces_literal = bypass_ifaces
        .into_iter()
        .map(|i| format!("\"{i}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let proxy_udp_ports = collect_proxy_udp_ports(store);
    let proxy_udp_ports_literal = proxy_udp_ports
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(", ");

    let mut out = String::with_capacity(2048);
    let _ = writeln!(out, "table inet TachyonTable");
    let _ = writeln!(out, "delete table inet TachyonTable");
    let _ = writeln!(out, "table inet TachyonTable {{");
    if forward_guard {
        let localv6_elems = format_localv6_elements(fakeip_v6, extra_local_v6);
        let _ = writeln!(
            out,
            "    set localv6 {{
        type ipv6_addr
        flags interval
        elements = {{
            {localv6_elems}
        }}
    }}"
        );
    }
    if store.settings.webrtc_leak_protect {
        append_webrtc_filter_chain(&mut out, &bypass_ifaces_literal, &proxy_udp_ports_literal);
        let _ = writeln!(
            out,
            "    chain webrtc_forward {{
        type filter hook forward priority filter; policy accept;
        oifname {{ {bypass_ifaces_literal} }} return
        jump webrtc_filter
    }}"
        );
    }
    append_lan_ipv6_isolation_chains(&mut out, &lan_ifaces, ipv6_active, forward_guard);
    let _ = writeln!(out, "}}");
    Some(out)
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

async fn run_odhcpd_reload() {
    let _ = Command::new("/etc/init.d/odhcpd")
        .arg("reload")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await;
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct OdhcpdLanBackup {
    pub ra: Option<String>,
    pub dhcpv6: Option<String>,
    pub ndp: Option<String>,
    pub ra_dns: Option<String>,
    pub ra_default: Option<String>,
    pub dns: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OdhcpdLanSnapshot {
    pub exists: bool,
    pub ra: Option<String>,
    pub dhcpv6: Option<String>,
    pub ndp: Option<String>,
    pub ra_dns: Option<String>,
    pub ra_default: Option<String>,
    pub dns: Vec<String>,
    pub backup: Option<OdhcpdLanBackup>,
    pub marker_keys_present: Vec<&'static str>,
}

impl OdhcpdLanSnapshot {
    pub fn to_backup(&self) -> OdhcpdLanBackup {
        OdhcpdLanBackup {
            ra: self.ra.clone(),
            dhcpv6: self.dhcpv6.clone(),
            ndp: self.ndp.clone(),
            ra_dns: self.ra_dns.clone(),
            ra_default: self.ra_default.clone(),
            dns: self.dns.clone(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OdhcpdSyncPlan {
    pub changed: bool,
    pub write_backup: Option<OdhcpdLanBackup>,
    pub set_opts: Vec<(&'static str, String)>,
    pub del_opts: Vec<&'static str>,
    pub replace_dns: bool,
    pub target_dns: Vec<String>,
    pub flush_lan_v6: bool,
    pub check_renew_lan: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OdhcpdRestorePlan {
    pub changed: bool,
    pub set_opts: Vec<(&'static str, String)>,
    pub del_opts: Vec<&'static str>,
    pub replace_dns: bool,
    pub target_dns: Vec<String>,
    pub del_markers: Vec<&'static str>,
    pub check_renew_lan: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct OdhcpdLanRuntimeState {
    pub inactive_applied: bool,
}

fn parse_uci_quoted_tokens(rhs: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let s = rhs.trim();
    if s.is_empty() {
        return tokens;
    }
    let bytes = s.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        if bytes[i] == b'\'' || bytes[i] == b'"' {
            let quote = bytes[i];
            i += 1;
            let mut buf = String::new();
            while i < bytes.len() {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    buf.push(bytes[i + 1] as char);
                    i += 2;
                    continue;
                }
                if bytes[i] == quote {
                    i += 1;
                    break;
                }
                buf.push(bytes[i] as char);
                i += 1;
            }
            if !buf.is_empty() {
                tokens.push(buf);
            }
        } else {
            let start = i;
            while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            let tok = &s[start..i];
            if !tok.is_empty() {
                tokens.push(tok.to_string());
            }
        }
    }
    tokens
}

fn decode_backup_scalar(raw: &str) -> Option<String> {
    let t = raw.trim();
    if t.is_empty() || t == "unset" {
        None
    } else {
        Some(t.to_string())
    }
}

pub fn parse_uci_dhcp_lan_snapshot(uci_show_out: &str) -> OdhcpdLanSnapshot {
    let mut snap = OdhcpdLanSnapshot::default();
    let mut backup = OdhcpdLanBackup::default();
    let mut has_backup = false;

    for raw_line in uci_show_out.lines() {
        let line = raw_line.trim();
        if line == "dhcp.lan=dhcp" {
            snap.exists = true;
            continue;
        }
        let Some(rest) = line.strip_prefix("dhcp.lan.") else {
            continue;
        };
        let Some((key, val)) = rest.split_once('=') else {
            continue;
        };
        snap.exists = true;
        let tokens = parse_uci_quoted_tokens(val);
        let first = tokens.first().cloned().filter(|v| !v.is_empty());
        match key {
            "ra" => snap.ra = first,
            "dhcpv6" => snap.dhcpv6 = first,
            "ndp" => snap.ndp = first,
            "ra_dns" => snap.ra_dns = first,
            "ra_default" => snap.ra_default = first,
            "dns" => snap.dns = tokens,
            "tachyon_lan_ra" => {
                has_backup = true;
                snap.marker_keys_present.push("tachyon_lan_ra");
                backup.ra = first.and_then(|v| decode_backup_scalar(&v));
            }
            "tachyon_lan_dhcpv6" => {
                has_backup = true;
                snap.marker_keys_present.push("tachyon_lan_dhcpv6");
                backup.dhcpv6 = first.and_then(|v| decode_backup_scalar(&v));
            }
            "tachyon_lan_ndp" => {
                has_backup = true;
                snap.marker_keys_present.push("tachyon_lan_ndp");
                backup.ndp = first.and_then(|v| decode_backup_scalar(&v));
            }
            "tachyon_lan_ra_dns" => {
                has_backup = true;
                snap.marker_keys_present.push("tachyon_lan_ra_dns");
                backup.ra_dns = first.and_then(|v| decode_backup_scalar(&v));
            }
            "tachyon_lan_ra_default" => {
                has_backup = true;
                snap.marker_keys_present.push("tachyon_lan_ra_default");
                backup.ra_default = first.and_then(|v| decode_backup_scalar(&v));
            }
            "tachyon_lan_dns" => {
                has_backup = true;
                snap.marker_keys_present.push("tachyon_lan_dns");
                if let Some(raw_dns) = first
                    && raw_dns != "unset"
                {
                    backup.dns = raw_dns
                        .split(',')
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(ToString::to_string)
                        .collect();
                } else {
                    backup.dns.clear();
                }
            }
            _ => {}
        }
    }

    if has_backup {
        snap.backup = Some(backup);
    }
    snap
}

fn diff_odhcpd_scalars(
    cur: &OdhcpdLanSnapshot,
    targets: [(&'static str, &Option<String>, &Option<String>); 5],
) -> (Vec<(&'static str, String)>, Vec<&'static str>) {
    let mut set_opts = Vec::new();
    let mut del_opts = Vec::new();
    for (key, cur_val, tgt_val) in targets {
        if cur_val != tgt_val {
            match tgt_val {
                Some(v) => set_opts.push((key, v.clone())),
                None => {
                    if cur_val.is_some() {
                        del_opts.push(key);
                    }
                }
            }
        }
    }
    let _ = cur;
    (set_opts, del_opts)
}

pub fn compute_odhcpd_sync_plan(
    cur: &OdhcpdLanSnapshot,
    ipv6_state: EffectiveIpv6State,
    ipv6_mode: &str,
    was_inactive: bool,
) -> OdhcpdSyncPlan {
    if !cur.exists {
        return OdhcpdSyncPlan::default();
    }
    let norm_mode = crate::store::normalize_ipv6_mode(ipv6_mode);
    let base = cur.backup.clone().unwrap_or_else(|| cur.to_backup());
    let (
        tgt_ra,
        tgt_dhcpv6,
        tgt_ndp,
        tgt_ra_dns,
        tgt_ra_default,
        tgt_dns,
        flush_lan_v6,
        check_renew_lan,
    ) = if !ipv6_state.is_active() {
        (
            Some("disabled".to_string()),
            Some("disabled".to_string()),
            Some("disabled".to_string()),
            Some("0".to_string()),
            Some("0".to_string()),
            Vec::new(),
            true,
            false,
        )
    } else if ipv6_state.is_tunnel_over_v4() {
        let ra = if matches!(base.ra.as_deref(), None | Some("") | Some("disabled")) {
            Some("server".to_string())
        } else {
            base.ra.clone()
        };
        (
            ra,
            base.dhcpv6.clone(),
            base.ndp.clone(),
            Some("1".to_string()),
            Some("2".to_string()),
            Vec::new(),
            false,
            was_inactive || cur.ra.as_deref() == Some("disabled"),
        )
    } else {
        let ra = if norm_mode == "dual_stack"
            && matches!(base.ra.as_deref(), None | Some("") | Some("disabled"))
        {
            Some("server".to_string())
        } else {
            base.ra.clone()
        };
        (
            ra,
            base.dhcpv6.clone(),
            base.ndp.clone(),
            Some("1".to_string()),
            base.ra_default.clone(),
            Vec::new(),
            false,
            was_inactive || cur.ra.as_deref() == Some("disabled"),
        )
    };

    let (set_opts, del_opts) = diff_odhcpd_scalars(
        cur,
        [
            ("ra", &cur.ra, &tgt_ra),
            ("dhcpv6", &cur.dhcpv6, &tgt_dhcpv6),
            ("ndp", &cur.ndp, &tgt_ndp),
            ("ra_dns", &cur.ra_dns, &tgt_ra_dns),
            ("ra_default", &cur.ra_default, &tgt_ra_default),
        ],
    );
    let replace_dns = cur.dns != tgt_dns;
    let changed = !set_opts.is_empty() || !del_opts.is_empty() || replace_dns;
    let write_backup = if cur.backup.is_none() && changed {
        Some(cur.to_backup())
    } else {
        None
    };

    OdhcpdSyncPlan {
        changed,
        write_backup,
        set_opts,
        del_opts,
        replace_dns,
        target_dns: tgt_dns,
        flush_lan_v6,
        check_renew_lan,
    }
}

pub fn compute_odhcpd_restore_plan(cur: &OdhcpdLanSnapshot) -> OdhcpdRestorePlan {
    if !cur.exists {
        return OdhcpdRestorePlan::default();
    }
    let Some(ref backup) = cur.backup else {
        return OdhcpdRestorePlan::default();
    };
    let (set_opts, del_opts) = diff_odhcpd_scalars(
        cur,
        [
            ("ra", &cur.ra, &backup.ra),
            ("dhcpv6", &cur.dhcpv6, &backup.dhcpv6),
            ("ndp", &cur.ndp, &backup.ndp),
            ("ra_dns", &cur.ra_dns, &backup.ra_dns),
            ("ra_default", &cur.ra_default, &backup.ra_default),
        ],
    );
    let replace_dns = cur.dns != backup.dns;
    let del_markers = cur.marker_keys_present.clone();
    let changed =
        !set_opts.is_empty() || !del_opts.is_empty() || replace_dns || !del_markers.is_empty();
    let check_renew_lan = cur.ra.as_deref() == Some("disabled");

    OdhcpdRestorePlan {
        changed,
        set_opts,
        del_opts,
        replace_dns,
        target_dns: backup.dns.clone(),
        del_markers,
        check_renew_lan,
    }
}

#[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
pub fn proc_if_inet6_has_global_v6(raw_if6: &str, ifname: &str) -> bool {
    for line in raw_if6.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 6 && parts[5] == ifname && u8::from_str_radix(parts[3], 16) == Ok(0) {
            return true;
        }
    }
    false
}

async fn detect_iface_has_global_v6(ifname: &str) -> bool {
    #[cfg(all(target_os = "linux", not(test)))]
    {
        if let Ok(raw) = tokio::fs::read_to_string("/proc/net/if_inet6").await {
            return proc_if_inet6_has_global_v6(&raw, ifname);
        }
    }
    let _ = ifname;
    false
}

async fn apply_uci_dhcp_lan_dns(dns: &[String]) {
    uci_run(&["-q", "delete", "dhcp.lan.dns"]).await;
    for item in dns {
        if !item.trim().is_empty() {
            uci_run(&["add_list", &format!("dhcp.lan.dns={}", item.trim())]).await;
        }
    }
}

async fn write_uci_odhcpd_backup(backup: &OdhcpdLanBackup) {
    let pairs = [
        ("tachyon_lan_ra", backup.ra.as_deref().unwrap_or("unset")),
        (
            "tachyon_lan_dhcpv6",
            backup.dhcpv6.as_deref().unwrap_or("unset"),
        ),
        ("tachyon_lan_ndp", backup.ndp.as_deref().unwrap_or("unset")),
        (
            "tachyon_lan_ra_dns",
            backup.ra_dns.as_deref().unwrap_or("unset"),
        ),
        (
            "tachyon_lan_ra_default",
            backup.ra_default.as_deref().unwrap_or("unset"),
        ),
    ];
    for (k, v) in pairs {
        uci_run(&["set", &format!("dhcp.lan.{k}={v}")]).await;
    }
    let dns_val = if backup.dns.is_empty() {
        "unset".to_string()
    } else {
        backup.dns.join(",")
    };
    uci_run(&["set", &format!("dhcp.lan.tachyon_lan_dns={dns_val}")]).await;
    let backup_path = crate::store::runtime_state_dir().join("odhcpd-lan-backup.json");
    let backup_owned = backup.clone();
    let _ = tokio::task::spawn_blocking(move || {
        crypto_gen::write_json_if_changed(backup_path, &backup_owned)
    })
    .await;
}

pub async fn sync_odhcpd_lan_ipv6(store: &RouterStoreData, ipv6_state: EffectiveIpv6State) {
    if cfg!(not(target_os = "linux")) || store.settings.dont_touch_dhcp {
        return;
    }
    let state_path = crate::store::runtime_state_dir().join("odhcpd-lan-state.json");
    let prev_state: OdhcpdLanRuntimeState = tokio::fs::read_to_string(&state_path)
        .await
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let Some(show_out) = uci_query(&["-q", "show", "dhcp.lan"]).await else {
        return;
    };
    let snap = parse_uci_dhcp_lan_snapshot(&show_out);
    let plan = compute_odhcpd_sync_plan(
        &snap,
        ipv6_state,
        &store.settings.ipv6_mode,
        prev_state.inactive_applied,
    );

    if plan.changed {
        if let Some(ref backup) = plan.write_backup {
            write_uci_odhcpd_backup(backup).await;
        }
        for (k, v) in &plan.set_opts {
            uci_run(&["set", &format!("dhcp.lan.{k}={v}")]).await;
        }
        for k in &plan.del_opts {
            uci_run(&["-q", "delete", &format!("dhcp.lan.{k}")]).await;
        }
        if plan.replace_dns {
            apply_uci_dhcp_lan_dns(&plan.target_dns).await;
        }
        uci_run(&["commit", "dhcp"]).await;
        run_odhcpd_reload().await;
    }

    if plan.flush_lan_v6 {
        for iface in collect_managed_lan_ifaces(store) {
            let _ = Command::new("ip")
                .args(["-6", "addr", "flush", "dev", &iface, "scope", "global"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await;
        }
    } else if plan.check_renew_lan && !detect_iface_has_global_v6("br-lan").await {
        let _ = Command::new("ubus")
            .args(["call", "network.interface.lan", "renew"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    }

    let next_state = OdhcpdLanRuntimeState {
        inactive_applied: !ipv6_state.is_active(),
    };
    let _ = tokio::task::spawn_blocking(move || {
        crypto_gen::write_json_if_changed(state_path, &next_state)
    })
    .await;
}

pub async fn restore_odhcpd_lan_ipv6() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    let Some(show_out) = uci_query(&["-q", "show", "dhcp.lan"]).await else {
        return;
    };
    let snap = parse_uci_dhcp_lan_snapshot(&show_out);
    let plan = compute_odhcpd_restore_plan(&snap);
    if plan.changed {
        for (k, v) in &plan.set_opts {
            uci_run(&["set", &format!("dhcp.lan.{k}={v}")]).await;
        }
        for k in &plan.del_opts {
            uci_run(&["-q", "delete", &format!("dhcp.lan.{k}")]).await;
        }
        if plan.replace_dns {
            apply_uci_dhcp_lan_dns(&plan.target_dns).await;
        }
        for marker in &plan.del_markers {
            uci_run(&["-q", "delete", &format!("dhcp.lan.{marker}")]).await;
        }
        uci_run(&["commit", "dhcp"]).await;
        run_odhcpd_reload().await;
    }
    if plan.check_renew_lan && !detect_iface_has_global_v6("br-lan").await {
        let _ = Command::new("ubus")
            .args(["call", "network.interface.lan", "renew"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    }
    let state_path = crate::store::runtime_state_dir().join("odhcpd-lan-state.json");
    let _ = tokio::fs::remove_file(state_path).await;
}

async fn sync_tailscale_magicdns(enabled: bool, release: bool) {
    let sections = discover_dnsmasq_sections().await;

    if enabled {
        let file_sync = tokio::task::spawn_blocking(|| {
            sync_tailscale_magicdns_files_at(
                Path::new(TAILSCALE_MAGICDNS_SERVERS_FILE),
                Path::new(TAILSCALE_LEGACY_DNSMASQ_CONF),
                true,
                false,
                false,
            )
        })
        .await
        .ok()
        .and_then(|res| res.ok())
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
                    let _ = tokio::fs::remove_file(TAILSCALE_MAGICDNS_SERVERS_FILE).await;
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
    let file_sync = tokio::task::spawn_blocking(move || {
        sync_tailscale_magicdns_files_at(
            Path::new(TAILSCALE_MAGICDNS_SERVERS_FILE),
            Path::new(TAILSCALE_LEGACY_DNSMASQ_CONF),
            false,
            release,
            in_use,
        )
    })
    .await
    .ok()
    .and_then(|res| res.ok())
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
    let _ = Command::new("ip")
        .args([
            "-6",
            "route",
            "del",
            "local",
            "::/0",
            "dev",
            "lo",
            "table",
            TPROXY_ROUTE_TABLE,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await;
}

async fn ensure_bridge_netfilter_disabled() {
    #[cfg(target_os = "linux")]
    {
        for sysctl_key in [
            "net.bridge.bridge-nf-call-iptables=0",
            "net.bridge.bridge-nf-call-ip6tables=0",
        ] {
            let _ = Command::new("sysctl")
                .args(["-w", sysctl_key])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await;
        }
    }
}

async fn apply_nft_stdin(ruleset: &str) -> anyhow::Result<()> {
    let mut child = Command::new("nft")
        .arg("-f")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take()
        && let Err(write_err) = stdin.write_all(ruleset.as_bytes()).await
    {
        drop(stdin);
        let _ = child.kill().await;
        let _ = child.wait().await;
        return Err(write_err.into());
    }
    let out = child.wait_with_output().await?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("nft apply failed: {}", err.trim());
    }
    Ok(())
}

/// Apply `inet TachyonTable` atomically via `nft -f -` and configure `ip rule` / `ip route`.
pub async fn apply_network_stack(store: &RouterStoreData) -> anyhow::Result<()> {
    if cfg!(not(target_os = "linux")) || store.settings.proxy_mode == "socks" {
        return Ok(());
    }

    ensure_bridge_netfilter_disabled().await;
    let wan6_cache = tokio::task::spawn_blocking(crate::store::probe_wan6_runtime_state).await?;
    let ipv6_state =
        crate::store::resolve_effective_ipv6_state(&store.settings, wan6_cache.wan6_available);
    let intercept_embedded_ts =
        embedded_tailscale_enabled(store) && !native_tailscale_enabled(store);

    if store.settings.proxy_mode == "tproxy" {
        if intercept_embedded_ts {
            neutralize_standalone_tailscale_service().await;
        }
        let ruleset = compile_nftables_ruleset_with_wan6(
            store,
            wan6_cache.wan6_available,
            &wan6_cache.wan6_prefixes,
        );
        apply_nft_stdin(&ruleset).await?;

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
        if ipv6_state.is_active() {
            run_checked_ip(&[
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
            .await?;
            run_checked_ip(&[
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
            .await?;
            run_checked_ip(&[
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
            .await?;
        }
    } else if store.settings.proxy_mode == "tun" {
        cleanup_policy_rules().await;
        if let Some(guard_nft) = compile_tun_guard_ruleset_with_wan6(
            store,
            wan6_cache.wan6_available,
            &wan6_cache.wan6_prefixes,
        ) {
            apply_nft_stdin(&guard_nft).await?;
        } else {
            let _ = Command::new("nft")
                .args(["delete", "table", "inet", "TachyonTable"])
                .status()
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
        sync_odhcpd_lan_ipv6(store, ipv6_state).await;
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
    restore_odhcpd_lan_ipv6().await;
    teardown_sqm_qdisc().await;
}

pub(crate) async fn run_status_with_timeout(
    cmd: &mut Command,
    timeout: std::time::Duration,
) -> std::io::Result<std::process::ExitStatus> {
    cmd.kill_on_drop(true);
    match tokio::time::timeout(timeout, cmd.status()).await {
        Ok(res) => res,
        Err(_) => Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            format!("command timed out after {}ms", timeout.as_millis()),
        )),
    }
}

/// Check if `table inet TachyonTable` is currently loaded in the kernel.
pub async fn check_nft_table_active() -> bool {
    if cfg!(not(target_os = "linux")) {
        return true;
    }
    let mut cmd = Command::new("nft");
    cmd.args(["list", "table", "inet", "TachyonTable"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    run_status_with_timeout(&mut cmd, std::time::Duration::from_secs(5))
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

    #[test]
    fn test_ipv6_stack_fakeip6_leak_guard_webrtc_exemptions_and_guest() {
        // 1) Auto IPv6 with wan6=false and ipv6_leak_guard=true enables LeakGuard
        let mut store = RouterStoreData::default();
        store.settings.ipv6_mode = "auto".to_string();
        store.settings.ipv6_leak_guard = true;
        store.settings.webrtc_leak_protect = true;
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "hy2".to_string(),
            enabled: true,
            source_type: "hysteria2".to_string(),
            server_port: 4433,
            ..Default::default()
        });
        let guard_nft = compile_nftables_ruleset_with_wan6(&store, false, &[]);
        assert!(
            guard_nft.contains("chain ipv6_forward_guard")
                && guard_nft.contains("admin-prohibited")
        );
        // WebRTC STUN filter with mandatory exemptions (fwmark 0x10000000 + proxy UDP port 4433)
        assert!(guard_nft.contains("chain webrtc_filter"));
        assert!(guard_nft.contains("meta mark 0x10000000 return"));
        assert!(guard_nft.contains("meta mark 0x40000000 return"));
        assert!(guard_nft.contains("udp dport {") && guard_nft.contains("4433"));
        assert!(guard_nft.contains("\"tailscale0\"") && guard_nft.contains("\"fptn0\""));

        // 2) Dual-stack with FakeIPv6 enabled: fc00::/18 precedes @localv6 return, extra WAN6 prefix in @localv6
        store.settings.ipv6_mode = "dual_stack".to_string();
        store.settings.fakeip_enabled = true;
        store.settings.fakeip_inet6_range = "fc00::/18".to_string();
        let extra = vec![
            "2606:4700:4700::/64".to_string(),
            "2001:db8:42::/64".to_string(),
        ];
        let dual_nft = compile_nftables_ruleset_with_wan6(&store, true, &extra);
        assert!(dual_nft.contains("2606:4700:4700::/64"));
        // 2001:db8:42::/64 overlaps builtin 2001:db8::/32 so it is deduplicated cleanly
        assert!(!dual_nft.contains("2001:db8:42::/64"));
        let pre_start = dual_nft.find("chain prerouting").expect("prerouting");
        let out_start = dual_nft.find("chain mangle_output").expect("mangle_output");
        let prerouting = &dual_nft[pre_start..out_start];
        let mangle_output = &dual_nft[out_start..];
        assert!(
            prerouting.find("ip6 daddr fc00::/18").expect("pre fakeip6")
                < prerouting.find("ip6 daddr @localv6").expect("pre localv6")
        );
        assert!(
            mangle_output
                .find("ip6 daddr fc00::/18")
                .expect("out fakeip6")
                < mangle_output
                    .find("ip6 daddr @localv6")
                    .expect("out localv6")
        );

        // 3) Guest isolation supports IPv4, IPv6, and MAC separately without syntax collision
        store.guest_mode.enabled = true;
        store.guest_mode.guest_devices = vec![
            "192.168.4.10".to_string(),
            "2001:db8:4::10".to_string(),
            "aa:bb:cc:dd:ee:ff".to_string(),
        ];
        store.guest_mode.isolate_lan = true;
        let guest_nft = compile_nftables_ruleset_with_wan6(&store, true, &[]);
        assert!(guest_nft.contains("ip saddr { 192.168.4.10 }"));
        assert!(guest_nft.contains("ip6 saddr { 2001:db8:4::10 }"));
        assert!(guest_nft.contains("ether saddr { aa:bb:cc:dd:ee:ff }"));
    }

    #[test]
    fn test_ipv6_off_and_auto_inactive_lan_isolation_rules() {
        let mut store = RouterStoreData::default();
        store.settings.ipv6_mode = "off".to_string();
        store.settings.ipv6_leak_guard = false;
        store.settings.source_network_interfaces = vec![
            "br-lan".to_string(),
            "br-guest".to_string(),
            "wan".to_string(),
            "wan6".to_string(),
            "lo".to_string(),
        ];

        let tproxy_nft = compile_nftables_ruleset_with_wan6(&store, true, &[]);
        let tun_nft = compile_tun_guard_ruleset_with_wan6(&store, true, &[])
            .expect("tun guard must emit IPv6 isolation rules when ipv6_mode=off");

        for nft in [&tproxy_nft, &tun_nft] {
            let guard_in_start = nft
                .find("chain lan_ipv6_guard_in")
                .expect("lan_ipv6_guard_in");
            let guard_out_start = nft
                .find("chain lan_ipv6_guard_out")
                .expect("lan_ipv6_guard_out");
            let fwd_start = nft
                .find("chain ipv6_forward_guard")
                .expect("ipv6_forward_guard");
            let guard_in = &nft[guard_in_start..guard_out_start];
            let guard_out = &nft[guard_out_start..fwd_start];
            let fwd = &nft[fwd_start..];

            assert!(guard_in.contains(
                "iifname { \"br-lan\", \"br-guest\" } icmpv6 type nd-router-solicit drop"
            ));
            assert!(
                guard_in.contains(
                    "iifname { \"br-lan\", \"br-guest\" } udp sport 546 udp dport 547 drop"
                )
            );
            assert!(guard_out.contains(
                "oifname { \"br-lan\", \"br-guest\" } icmpv6 type nd-router-advert drop"
            ));
            assert!(
                guard_out.contains(
                    "oifname { \"br-lan\", \"br-guest\" } udp sport 547 udp dport 546 drop"
                )
            );
            for ch in [guard_in, guard_out, fwd] {
                assert!(!ch.contains("\"wan\""));
                assert!(!ch.contains("\"wan6\""));
                assert!(!ch.contains("\"lo\""));
            }
            assert!(!nft.contains("meta l4proto icmpv6 return"));
            assert!(!nft.contains("udp sport 546 udp dport 547 return"));
            assert!(fwd.contains(
                "icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } return"
            ));
            assert!(fwd.contains("meta nfproto ipv6 reject with icmpx type admin-prohibited"));
        }

        // Verify alias ipv4_only produces identical off isolation
        store.settings.ipv6_mode = "ipv4_only".to_string();
        let alias_nft = compile_nftables_ruleset_with_wan6(&store, true, &[]);
        assert_eq!(alias_nft, tproxy_nft);

        // Auto without WAN6 and leak_guard=false drops LAN RA/DHCPv6 without forcing ipv6_forward_guard
        store.settings.ipv6_mode = "auto".to_string();
        store.settings.ipv6_leak_guard = false;
        let auto_tproxy = compile_nftables_ruleset_with_wan6(&store, false, &[]);
        let auto_tun = compile_tun_guard_ruleset_with_wan6(&store, false, &[])
            .expect("tun guard must drop LAN RA/DHCPv6 when auto lacks wan6");
        for nft in [&auto_tproxy, &auto_tun] {
            assert!(nft.contains("chain lan_ipv6_guard_in"));
            assert!(nft.contains("chain lan_ipv6_guard_out"));
            assert!(!nft.contains("chain ipv6_forward_guard"));
        }
    }

    #[test]
    fn test_odhcpd_lan_snapshot_sync_and_restore_plans() {
        let raw_initial = "\
dhcp.lan=dhcp
dhcp.lan.interface='lan'
dhcp.lan.start='100'
dhcp.lan.limit='150'
dhcp.lan.leasetime='12h'
dhcp.lan.dhcpv6='server'
dhcp.lan.ra='server'
dhcp.lan.ndp='relay'
dhcp.lan.ra_dns='1'
dhcp.lan.ra_default='1'
dhcp.lan.dns='fd00::1' '2001:4860:4860::8888'
";
        let initial = parse_uci_dhcp_lan_snapshot(raw_initial);
        assert!(initial.exists);
        assert_eq!(initial.ra.as_deref(), Some("server"));
        assert_eq!(initial.dhcpv6.as_deref(), Some("server"));
        assert_eq!(initial.ndp.as_deref(), Some("relay"));
        assert_eq!(initial.ra_dns.as_deref(), Some("1"));
        assert_eq!(initial.ra_default.as_deref(), Some("1"));
        assert_eq!(
            initial.dns,
            vec!["fd00::1".to_string(), "2001:4860:4860::8888".to_string()]
        );
        assert!(initial.backup.is_none());

        // Switching to off writes backup once and disables RA/DHCPv6/NDP/ra_dns/ra_default + clears dns
        let off_plan = compute_odhcpd_sync_plan(
            &initial,
            crate::store::EffectiveIpv6State::Disabled,
            "off",
            false,
        );
        assert!(off_plan.changed);
        assert!(off_plan.flush_lan_v6);
        assert!(!off_plan.check_renew_lan);
        assert!(off_plan.replace_dns && off_plan.target_dns.is_empty());
        let written_backup = off_plan
            .write_backup
            .clone()
            .expect("backup written on first change");
        assert_eq!(written_backup.ra.as_deref(), Some("server"));
        assert_eq!(written_backup.dns, vec!["fd00::1", "2001:4860:4860::8888"]);
        assert!(off_plan.set_opts.contains(&("ra", "disabled".to_string())));
        assert!(
            off_plan
                .set_opts
                .contains(&("dhcpv6", "disabled".to_string()))
        );
        assert!(off_plan.set_opts.contains(&("ndp", "disabled".to_string())));
        assert!(off_plan.set_opts.contains(&("ra_dns", "0".to_string())));
        assert!(off_plan.set_opts.contains(&("ra_default", "0".to_string())));

        // Re-applying off when already applied is idempotent (changed == false)
        let raw_after_off = "\
dhcp.lan=dhcp
dhcp.lan.interface='lan'
dhcp.lan.ra='disabled'
dhcp.lan.dhcpv6='disabled'
dhcp.lan.ndp='disabled'
dhcp.lan.ra_dns='0'
dhcp.lan.ra_default='0'
dhcp.lan.tachyon_lan_ra='server'
dhcp.lan.tachyon_lan_dhcpv6='server'
dhcp.lan.tachyon_lan_ndp='relay'
dhcp.lan.tachyon_lan_ra_dns='1'
dhcp.lan.tachyon_lan_ra_default='1'
dhcp.lan.tachyon_lan_dns='fd00::1,2001:4860:4860::8888'
";
        let after_off = parse_uci_dhcp_lan_snapshot(raw_after_off);
        assert!(after_off.backup.is_some());
        let off_idem = compute_odhcpd_sync_plan(
            &after_off,
            crate::store::EffectiveIpv6State::Disabled,
            "off",
            true,
        );
        assert!(!off_idem.changed);
        assert!(off_idem.write_backup.is_none());
        assert!(off_idem.flush_lan_v6);

        // Switching from off -> tunnel_over_v4 enables RA + ra_default=2 + ra_dns=1 and triggers LAN renew check
        let tun_v4_plan = compute_odhcpd_sync_plan(
            &after_off,
            crate::store::EffectiveIpv6State::TunnelOverV4,
            "tunnel_over_v4",
            true,
        );
        assert!(tun_v4_plan.changed);
        assert!(!tun_v4_plan.flush_lan_v6);
        assert!(tun_v4_plan.check_renew_lan);
        assert!(tun_v4_plan.set_opts.contains(&("ra", "server".to_string())));
        assert!(tun_v4_plan.set_opts.contains(&("ra_dns", "1".to_string())));
        assert!(
            tun_v4_plan
                .set_opts
                .contains(&("ra_default", "2".to_string()))
        );
        assert!(
            tun_v4_plan
                .set_opts
                .contains(&("dhcpv6", "server".to_string()))
        );
        assert!(tun_v4_plan.set_opts.contains(&("ndp", "relay".to_string())));

        // Switching from off -> dual_stack restores backup ra/dhcpv6/ndp/ra_default, sets ra_dns=1, triggers renew
        let dual_plan = compute_odhcpd_sync_plan(
            &after_off,
            crate::store::EffectiveIpv6State::Full,
            "dual_stack",
            true,
        );
        assert!(dual_plan.changed);
        assert!(dual_plan.check_renew_lan);
        assert!(dual_plan.set_opts.contains(&("ra", "server".to_string())));
        assert!(dual_plan.set_opts.contains(&("ra_dns", "1".to_string())));
        assert!(
            dual_plan
                .set_opts
                .contains(&("ra_default", "1".to_string()))
        );

        // Dual-stack forces ra='server' even when original router backup had ra='disabled'
        let mut disabled_orig_snap = after_off.clone();
        if let Some(ref mut b) = disabled_orig_snap.backup {
            b.ra = Some("disabled".to_string());
        }
        let dual_force_ra = compute_odhcpd_sync_plan(
            &disabled_orig_snap,
            crate::store::EffectiveIpv6State::Full,
            "dual_stack",
            true,
        );
        assert!(
            dual_force_ra
                .set_opts
                .contains(&("ra", "server".to_string()))
        );

        // Teardown restore restores exact original values & dns list and cleans markers
        let restore = compute_odhcpd_restore_plan(&after_off);
        assert!(restore.changed);
        assert!(restore.check_renew_lan);
        assert!(restore.set_opts.contains(&("ra", "server".to_string())));
        assert!(restore.set_opts.contains(&("ra_dns", "1".to_string())));
        assert!(restore.set_opts.contains(&("ra_default", "1".to_string())));
        assert!(restore.replace_dns);
        assert_eq!(restore.target_dns, vec!["fd00::1", "2001:4860:4860::8888"]);
        assert!(restore.del_markers.contains(&"tachyon_lan_ra"));
        assert!(restore.del_markers.contains(&"tachyon_lan_dns"));
    }

    #[test]
    fn test_proc_if_inet6_has_global_v6() {
        let only_ll = "\
fe80000000000000021122fffe334455 05 40 20 80   br-lan
00000000000000000000000000000001 01 80 10 80       lo
";
        assert!(!proc_if_inet6_has_global_v6(only_ll, "br-lan"));
        assert!(!proc_if_inet6_has_global_v6(only_ll, "lo"));

        let with_ula_and_gua = "\
fe80000000000000021122fffe334455 05 40 20 80   br-lan
fd001122334455660000000000000001 05 40 00 80   br-lan
20010db8000100000000000000000001 02 40 00 80     eth0
";
        assert!(proc_if_inet6_has_global_v6(with_ula_and_gua, "br-lan"));
        assert!(proc_if_inet6_has_global_v6(with_ula_and_gua, "eth0"));
        assert!(!proc_if_inet6_has_global_v6(with_ula_and_gua, "wan6"));
    }

    #[test]
    fn test_format_localv6_elements_masks_host_bits_via_mask_cidr() {
        let extra = vec![
            "2606:4700:4700::1234/64".to_string(),
            "2606:4700:4700::abcd/64".to_string(),
            "2001:4860:4860::8888".to_string(),
            "fc00::99/18".to_string(),
            "192.168.1.1/24".to_string(),
            "not-a-cidr".to_string(),
        ];
        let elems = format_localv6_elements("fc00::/18", &extra);
        assert!(elems.contains("2606:4700:4700::/64"));
        assert!(!elems.contains("2606:4700:4700::1234/64"));
        assert!(!elems.contains("2606:4700:4700::abcd/64"));
        assert_eq!(elems.matches("2606:4700:4700::/64").count(), 1);
        assert!(elems.contains("2001:4860:4860::8888/128"));
        assert!(!elems.contains("192.168.1.0/24"));
        assert!(!elems.contains("fc00::99/18"));
    }

    #[test]
    fn test_guest_mode_allow_proxy_emits_fakeip_v6_exemption_or_early_return() {
        let mut store = RouterStoreData::default();
        store.settings.ipv6_mode = "dual_stack".to_string();
        store.settings.fakeip_enabled = true;
        store.settings.fakeip_inet6_range = "fc00::/18".to_string();
        store.guest_mode.enabled = true;
        store.guest_mode.isolate_lan = true;
        store.guest_mode.block_router_admin = true;
        store.guest_mode.guest_devices = vec![
            "192.168.4.10".to_string(),
            "2001:4860::10".to_string(),
            "aa:bb:cc:dd:ee:ff".to_string(),
        ];

        // allow_proxy = true -> exempt FakeIPv6 on @localv6 drops, no early return before TProxy
        store.guest_mode.allow_proxy = true;
        let nft_allow = compile_nftables_ruleset_with_wan6(&store, true, &[]);
        assert!(nft_allow.contains(
            "ip6 saddr { 2001:4860::10 } ip6 daddr @localv6 ip6 daddr != fc00::/18 meta l4proto { tcp, udp } th dport != 53 drop"
        ));
        assert!(nft_allow.contains(
            "ether saddr { aa:bb:cc:dd:ee:ff } ip6 daddr @localv6 ip6 daddr != fc00::/18 meta l4proto { tcp, udp } th dport { 22, 80, 443, 1680, 9090 } drop"
        ));
        assert!(!nft_allow.contains("ip saddr { 192.168.4.10 } return"));
        assert!(!nft_allow.contains("ip6 saddr { 2001:4860::10 } return"));
        assert!(!nft_allow.contains("ether saddr { aa:bb:cc:dd:ee:ff } return"));

        // allow_proxy = false -> no FakeIPv6 exemption and early return skips TProxy
        store.guest_mode.allow_proxy = false;
        let nft_deny = compile_nftables_ruleset_with_wan6(&store, true, &[]);
        assert!(
            !nft_deny
                .contains("ip6 saddr { 2001:4860::10 } ip6 daddr @localv6 ip6 daddr != fc00::/18")
        );
        assert!(nft_deny.contains("ip saddr { 192.168.4.10 } return"));
        assert!(nft_deny.contains("ip6 saddr { 2001:4860::10 } return"));
        assert!(nft_deny.contains("ether saddr { aa:bb:cc:dd:ee:ff } return"));
        // Isolation drop still precedes early return in prerouting
        let pre_start = nft_deny.find("chain prerouting").expect("prerouting");
        let prerouting = &nft_deny[pre_start..];
        assert!(
            prerouting
                .find("ip saddr { 192.168.4.10 } ip daddr @localv4")
                .expect("guest isolate drop")
                < prerouting
                    .find("ip saddr { 192.168.4.10 } return")
                    .expect("guest early return")
        );
        assert!(
            prerouting
                .find("ip saddr { 192.168.4.10 } return")
                .expect("guest early return")
                < prerouting
                    .find("tproxy ip to 127.0.0.1:")
                    .expect("tproxy intercept")
        );
    }

    #[tokio::test]
    async fn test_run_status_with_timeout_terminates_hung_subprocess() {
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
        cmd.stdout(Stdio::null()).stderr(Stdio::null());
        let started = std::time::Instant::now();
        let err = run_status_with_timeout(&mut cmd, std::time::Duration::from_millis(150))
            .await
            .expect_err("expected command timeout");
        assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
        assert!(started.elapsed() < std::time::Duration::from_secs(3));
    }
}
