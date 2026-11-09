//! OpenWrt networking stack orchestrator:
//! - Compiles and atomically applies `nftables` (`table inet TachyonTable`) via `nft -f -`
//! - Manages Policy Routing (`ip rule` / `ip route` table 100 for TProxy `:1602`)
//! - Coordinates `dnsmasq` upstream forwarding to `127.0.0.42#53` without NAND flash wear.

use std::fmt::Write as _;
use std::process::Stdio;

use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::crypto_gen;
use crate::store::RouterStoreData;

pub const TPROXY_PORT: u16 = 1602;
pub const TPROXY_FWMARK: &str = "0x04000000";
pub const BYPASS_FWMARK: &str = "0x40000000";
pub const TPROXY_ROUTE_TABLE: &str = "100";

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

    let _ = writeln!(
        out,
        "    chain divert {{
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto tcp socket transparent 1 meta mark set {TPROXY_FWMARK} accept
    }}"
    );

    let _ = writeln!(
        out,
        "    chain prerouting {{
        type filter hook prerouting priority mangle + 10; policy accept;"
    );

    // Restrict interception to configured LAN interfaces (`br-lan` by default)
    if !store.settings.source_network_interfaces.is_empty() {
        let quoted: Vec<String> = store
            .settings
            .source_network_interfaces
            .iter()
            .map(|i| format!("\"{}\"", i.trim()))
            .collect();
        let _ = writeln!(out, "        iifname != {{ {} }} return", quoted.join(", "));
    }

    // Bypass packets already marked with `BYPASS_FWMARK`
    let _ = writeln!(out, "        meta mark {BYPASS_FWMARK} return");

    // Guest mode LAN isolation
    if store.guest_mode.enabled && !store.guest_mode.guest_devices.is_empty() {
        let guests: Vec<String> = store
            .guest_mode
            .guest_devices
            .iter()
            .filter(|g| g.contains('.'))
            .cloned()
            .collect();
        if !guests.is_empty() && store.guest_mode.isolate_lan {
            let _ = writeln!(
                out,
                "        ip saddr {{ {} }} ip daddr @localv4 udp dport != 53 drop",
                guests.join(", ")
            );
        }
    }

    // Intercept DNS queries (`:53`) to `tachyon-core` FakeIP/DNS listener (`127.0.0.42:53`)
    let _ = writeln!(out, "        ip daddr @localv4 return");
    if store.settings.enable_ipv6 {
        let _ = writeln!(out, "        ip6 daddr @localv6 return");
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
    let _ = writeln!(out, "}}");
    out
}

/// Apply `inet TachyonTable` atomically via `nft -f -` and configure `ip rule` / `ip route`.
pub async fn apply_network_stack(store: &RouterStoreData) -> anyhow::Result<()> {
    if cfg!(not(target_os = "linux")) || store.settings.proxy_mode == "socks" {
        return Ok(());
    }

    if store.settings.proxy_mode == "tproxy" {
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

        // Ensure policy routing table 100 for TProxy fwmark
        let _ = Command::new("ip")
            .args([
                "rule",
                "del",
                "fwmark",
                TPROXY_FWMARK,
                "table",
                TPROXY_ROUTE_TABLE,
            ])
            .status()
            .await;
        let _ = Command::new("ip")
            .args([
                "rule",
                "add",
                "fwmark",
                TPROXY_FWMARK,
                "table",
                TPROXY_ROUTE_TABLE,
            ])
            .status()
            .await;
        let _ = Command::new("ip")
            .args([
                "route",
                "replace",
                "local",
                "0.0.0.0/0",
                "dev",
                "lo",
                "table",
                TPROXY_ROUTE_TABLE,
            ])
            .status()
            .await;
    }

    if !store.settings.dont_touch_dhcp {
        let dnsmasq_conf = "no-resolv\nserver=127.0.0.42#53\n";
        let _ = crypto_gen::write_file_if_changed(
            "/tmp/dnsmasq.d/tachyon.conf",
            dnsmasq_conf.as_bytes(),
        );
    }

    Ok(())
}

/// Teardown `inet TachyonTable` and policy routing rules cleanly on stop.
pub async fn teardown_network_stack() {
    if cfg!(not(target_os = "linux")) {
        return;
    }
    let _ = Command::new("nft")
        .args(["delete", "table", "inet", "TachyonTable"])
        .status()
        .await;
    let _ = Command::new("ip")
        .args([
            "rule",
            "del",
            "fwmark",
            TPROXY_FWMARK,
            "table",
            TPROXY_ROUTE_TABLE,
        ])
        .status()
        .await;
    let _ = std::fs::remove_file("/tmp/dnsmasq.d/tachyon.conf");
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
    fn test_compile_nftables_ruleset_clean_tproxy() {
        let mut store = RouterStoreData::default();
        store.settings.disable_quic = true;
        store.settings.torrserver_direct_enabled = true;
        let nft = compile_nftables_ruleset(&store);
        assert!(nft.contains("table inet TachyonTable"));
        assert!(nft.contains("tproxy ip to 127.0.0.1:1602"));
        assert!(nft.contains("udp dport 443 reject"));
        assert!(nft.contains("th dport { 8090 } return"));
        assert!(!nft.contains("queue num"));
    }
}
