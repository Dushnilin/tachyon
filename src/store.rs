//! Persistent state and data models for `tachyon` (Pure-Rust OpenWrt Router Orchestrator).
//!
//! Designed for minimal memory footprint (<1.5 MB in-memory state) and zero NAND flash wear:
//! configuration writes pass through `write_json_if_changed`, and all runtime telemetry rings/maps
//! have strict capacity caps and automatic TTL eviction.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

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

pub fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn default_true() -> bool {
    true
}

fn default_ui_mode() -> String {
    "advanced".to_string()
}

fn default_sidebar_pos() -> String {
    "left".to_string()
}

fn default_accent_theme() -> String {
    "purple".to_string()
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
    #[serde(default = "default_accent_theme")]
    pub accent_theme: String,
    #[serde(default = "default_lang")]
    pub lang: String,
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

    pub core_bin_path: String,
    pub core_config_path: String,
    pub cache_path: String,
    pub rulesets_dir: String,
    pub clash_api_addr: String,
    pub clash_api_secret: String,
    #[serde(default)]
    pub agent_api_token: String,

    #[serde(default = "default_proxy_mode")]
    pub proxy_mode: String,
    #[serde(default = "default_tun_iface")]
    pub tun_interface: String,
    #[serde(default = "default_tun_stack")]
    pub tun_stack: String,
    #[serde(default = "default_tun_mtu")]
    pub tun_mtu: u16,
    pub source_network_interfaces: Vec<String>,
    #[serde(default)]
    pub output_network_interface: String,
    #[serde(default)]
    pub enable_ipv6: bool,
    #[serde(default)]
    pub disable_quic: bool,
    #[serde(default)]
    pub block_doh: bool,
    #[serde(default)]
    pub webrtc_leak_protect: bool,
    #[serde(default)]
    pub route_router_traffic: bool,
    #[serde(default)]
    pub wifi_calling_direct: bool,
    #[serde(default)]
    pub isolate_p2p: bool,
    #[serde(default)]
    pub p2p_ports: String,
    #[serde(default)]
    pub direct_bypass_enabled: bool,
    #[serde(default)]
    pub direct_bypass_port: u16,
    #[serde(default)]
    pub game_console_optimizer: bool,
    #[serde(default)]
    pub game_console_ips: Vec<String>,
    #[serde(default)]
    pub exclude_ntp: bool,
    #[serde(default)]
    pub dont_touch_dhcp: bool,
    #[serde(default)]
    pub torrserver_direct_enabled: bool,
    #[serde(default)]
    pub torrserver_ports: Vec<u16>,

    #[serde(default = "default_dns_type")]
    pub dns_type: String,
    pub dns_servers: Vec<String>,
    pub bootstrap_dns_servers: Vec<String>,
    #[serde(default)]
    pub fallback_dns_server: String,
    #[serde(default)]
    pub dns_fallback_servers: Vec<String>,
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

    #[serde(default)]
    pub hosts_enabled: bool,
    #[serde(default)]
    pub hosts_list_urls: Vec<String>,
    #[serde(default)]
    pub static_hosts: Vec<String>,
    #[serde(default)]
    pub github_mirror: String,

    #[serde(default = "default_true")]
    pub enable_watchdog: bool,
    #[serde(default)]
    pub wan_failover_enabled: bool,
    #[serde(default)]
    pub wan_failover_primary: String,
    #[serde(default)]
    pub wan_failover_backup: String,
    #[serde(default)]
    pub wan_failover_probe_hosts: Vec<String>,
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

    #[serde(default = "default_true")]
    pub list_update_enabled: bool,
    #[serde(default)]
    pub update_interval: String,
    #[serde(default)]
    pub download_lists_via_proxy: bool,
    #[serde(default)]
    pub download_lists_via_proxy_section: String,
    #[serde(default = "default_true")]
    pub component_update_check_enabled: bool,
    #[serde(default)]
    pub component_auto_update_enabled: bool,
    #[serde(default = "default_latency_url")]
    pub latency_test_url: String,

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
            ui_mode: "advanced".to_string(),
            lite_mode: false,
            sidebar_pos: "left".to_string(),
            sidebar_collapsed: false,
            accent_theme: "purple".to_string(),
            lang: "ru".to_string(),
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
            core_bin_path: "/usr/bin/tachyon-core".to_string(),
            core_config_path: "/etc/tachyon-core/config.json".to_string(),
            cache_path: "/usr/share/tachyon-core/cache.db".to_string(),
            rulesets_dir: "/etc/tachyon/rulesets".to_string(),
            clash_api_addr: "127.0.0.1:9090".to_string(),
            clash_api_secret: crypto_gen::generate_alnum(24),
            agent_api_token: crypto_gen::generate_alnum(32),
            proxy_mode: "tproxy".to_string(),
            tun_interface: "tun0".to_string(),
            tun_stack: "mixed".to_string(),
            tun_mtu: 9000,
            source_network_interfaces: vec!["br-lan".to_string()],
            output_network_interface: String::new(),
            enable_ipv6: false,
            disable_quic: false,
            block_doh: false,
            webrtc_leak_protect: false,
            route_router_traffic: false,
            wifi_calling_direct: false,
            isolate_p2p: false,
            p2p_ports: "tcp:6881,udp:6881-6889".to_string(),
            direct_bypass_enabled: false,
            direct_bypass_port: 2080,
            game_console_optimizer: false,
            game_console_ips: Vec::new(),
            exclude_ntp: false,
            dont_touch_dhcp: false,
            torrserver_direct_enabled: false,
            torrserver_ports: vec![8090],
            dns_type: "udp".to_string(),
            dns_servers: vec!["77.88.8.8".to_string(), "77.88.8.1".to_string(), "9.9.9.9".to_string()],
            bootstrap_dns_servers: vec!["77.88.8.8".to_string(), "1.1.1.1".to_string()],
            fallback_dns_server: "1.0.0.1".to_string(),
            dns_fallback_servers: vec!["1.0.0.1".to_string(), "77.88.8.1".to_string()],
            dns_upstream_mode: "parallel".to_string(),
            dns_rewrite_ttl: 60,
            dns_strategy: "prefer_ipv4".to_string(),
            dns_detour_enabled: false,
            dns_detour_section: String::new(),
            dns_local_cache: true,
            dns_turbo_cache: true,
            dns_cache_size: 10000,
            hosts_enabled: false,
            hosts_list_urls: Vec::new(),
            static_hosts: Vec::new(),
            github_mirror: String::new(),
            enable_watchdog: true,
            wan_failover_enabled: false,
            wan_failover_primary: "wan".to_string(),
            wan_failover_backup: "wan2".to_string(),
            wan_failover_probe_hosts: vec!["77.88.8.8".to_string(), "1.1.1.1".to_string()],
            recovery_bypass: false,
            memory_limit_mb: 0,
            log_level: "warn".to_string(),
            smart_detect: true,
            smart_detect_mode: "default".to_string(),
            smart_detect_expand_to_root: true,
            smart_detect_sections: vec!["Main".to_string()],
            list_update_enabled: true,
            update_interval: "3h".to_string(),
            download_lists_via_proxy: true,
            download_lists_via_proxy_section: "Main".to_string(),
            component_update_check_enabled: true,
            component_auto_update_enabled: false,
            latency_test_url: "https://www.gstatic.com/generate_204".to_string(),
            server_subscription_enabled: true,
            server_subscription_token: crypto_gen::generate_hex(24),
            server_subscription_host: "192.168.1.205".to_string(),
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
    /// `proxy`, `desync`, `wdtt`, `fptn`, `tailscale`, `direct`, `block`, `hosts`, `dns`
    #[serde(default, alias = "action_mode")]
    pub connection_type: String,
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub condition_refs: Vec<String>,
    #[serde(default, alias = "source_refs")]
    pub outbound_source_refs: Vec<String>,
    #[serde(default)]
    pub balancer_refs: Vec<String>,
    #[serde(default)]
    pub outbound_group_ref: String,
    #[serde(default)]
    pub community_lists: Vec<String>,
    #[serde(default)]
    pub user_domains: Vec<String>,
    #[serde(default)]
    pub user_subnets: Vec<String>,
    #[serde(default)]
    pub geoip_codes: Vec<String>,
    #[serde(default)]
    pub geoip_mode: String,
    #[serde(default, alias = "client_ips")]
    pub fully_routed_ips: Vec<String>,
    #[serde(default)]
    pub outbound_detour_enabled: bool,
    #[serde(default)]
    pub outbound_detour_section: String,
    #[serde(default)]
    pub sort_by_latency: bool,
    #[serde(default)]
    pub fail_policy: String,
    #[serde(default)]
    pub routed_dns_enabled: bool,
    #[serde(default)]
    pub dns_servers: Vec<String>,
    #[serde(default, alias = "selected_node_tag")]
    pub active_selected_tag: String,
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
    #[serde(default, alias = "domains")]
    pub user_domains: Vec<String>,
    #[serde(default, alias = "ip_cidrs")]
    pub user_subnets: Vec<String>,
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
    pub l4_proto: String,
    /// Optional `time_window` schedule (e.g. `22:00-08:00` or `mon,tue,wed,thu,fri 09:00-18:00`).
    #[serde(default)]
    pub time_window: String,
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
    /// `subscription`, `proxy_links`, `custom_json`, `interface`, `desync`, `wdtt`, `fptn`, `tailscale`, `warp`, `mtproto`, `wireguard`, `awg`
    pub source_type: String,
    #[serde(default)]
    pub subscription_urls: Vec<String>,
    #[serde(default)]
    pub subscription_update_interval: String,
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
    pub awg_h1: u32,
    #[serde(default)]
    pub awg_h2: u32,
    #[serde(default)]
    pub awg_h3: u32,
    #[serde(default)]
    pub awg_h4: u32,
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

    /// MTProto `telegram-ws` / `kws` mode.
    #[serde(default)]
    pub mtproto_telegram_ws: bool,

    /// Tailscale native outbound config.
    #[serde(default)]
    pub tailscale_auth_key: String,
    #[serde(default)]
    pub tailscale_control_url: String,
    #[serde(default)]
    pub tailscale_hostname: String,

    #[serde(default)]
    pub filter_allow_regex: String,
    #[serde(default)]
    pub filter_deny_regex: String,
    #[serde(default)]
    pub include_countries: Vec<String>,
    #[serde(default)]
    pub exclude_countries: Vec<String>,
    #[serde(default)]
    pub cached_nodes: Vec<ParsedProxyNode>,
    #[serde(default)]
    pub last_updated_unix: i64,
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
    /// `least_test`, `stability`, `sticky`, `round_robin`, `least_load`, `weighted`, `passive`, `priority`, `hedged`, `throughput`, `quota`
    #[serde(default)]
    pub mode: String,
    #[serde(default = "default_latency_url", alias = "probe_url")]
    pub testing_url: String,
    /// Probe interval in seconds (default 180).
    #[serde(default, alias = "interval_secs")]
    pub check_interval: u32,
    /// Latency tolerance in ms (default 50).
    #[serde(default, alias = "tolerance_ms")]
    pub tolerance: u32,
    #[serde(default, alias = "sticky_hash_field")]
    pub sticky_hash: String,
    #[serde(default)]
    pub passive_check: bool,
    #[serde(default)]
    pub interrupt_exist_connections: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutboundGroup {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub name: String,
    #[serde(default)]
    pub primary_refs: Vec<String>,
    #[serde(default)]
    pub backup_refs: Vec<String>,
    /// `block`, `direct`, or `last_alive`
    pub fail_policy: String,
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
    #[serde(default)]
    pub country: String,
    /// `vless`, `vmess`, `shadowsocks`, `trojan`, `hysteria2`, `tuic`, `anytls`, `shadowtls`,
    /// `naive`, `mieru`, `snell`, `tewfai`, `masque`, `trusttunnel`, `mtproto`, `openconnect`,
    /// `fptn`, `wdtt`, `wireguard`, `awg`, `tailscale`, `mixed`, `socks`, `http`, `json_inbound`
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
    #[serde(default)]
    pub password: String,
    #[serde(default, alias = "ss_method")]
    pub method: String,
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
    pub transport: String,
    #[serde(default)]
    pub transport_path: String,

    // Protocol-specific fields (TewFai, Hysteria2, TUIC, ShadowTLS, Mieru, TrustTunnel, MASQUE, OpenConnect, MTProto, AmneziaWG, Tailscale)
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
    pub masque_mtu: u16,
    #[serde(default)]
    pub openconnect_cookie: String,
    #[serde(default)]
    pub openconnect_flavor: String,
    #[serde(default)]
    pub openconnect_address: String,
    #[serde(default)]
    pub openconnect_mtu: u16,
    #[serde(default)]
    pub mtproto_secret: String,
    #[serde(default)]
    pub mtproto_faketls: String,
    #[serde(default)]
    pub mtproto_telegram_ws: bool,
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
    pub awg_h1: u32,
    #[serde(default)]
    pub awg_h2: u32,
    #[serde(default)]
    pub awg_h3: u32,
    #[serde(default)]
    pub awg_h4: u32,
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
    pub tailscale_hostname: String,
    #[serde(default)]
    pub tailscale_advertise_exit_node: bool,
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
    #[serde(default, alias = "device_macs")]
    pub device_ips: Vec<String>,
    #[serde(default)]
    pub safe_search: bool,
    #[serde(default)]
    pub block_doh: bool,
    #[serde(default)]
    pub daily_quota_minutes: u32,
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
pub struct ScheduleRule {
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, alias = "name")]
    pub label: String,
    #[serde(default)]
    pub profile_refs: Vec<String>,
    #[serde(default, alias = "target_id")]
    pub target: String,
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub start_time: String,
    #[serde(default)]
    pub end_time: String,
    #[serde(default)]
    pub days: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
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
    #[serde(default)]
    pub daily_time_limit: u32,
    #[serde(default)]
    pub daily_traffic_limit: u64,
    #[serde(default)]
    pub bandwidth_limit_mbps: u32,
    #[serde(default)]
    pub allowed_ports: Vec<u16>,
    #[serde(default)]
    pub start_time: String,
    #[serde(default)]
    pub end_time: String,
    #[serde(default)]
    pub days: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TgBotConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub bot_token: String,
    #[serde(default)]
    pub admin_ids: Vec<i64>,
    #[serde(default)]
    pub poll_interval: u32,
    #[serde(default = "default_true", alias = "notify_on_core_restart")]
    pub notify_crash: bool,
    #[serde(default = "default_true")]
    pub notify_restart: bool,
    #[serde(default = "default_true", alias = "notify_on_wan_drop")]
    pub notify_server_switch: bool,
    #[serde(default = "default_true")]
    pub notify_subscription: bool,
    #[serde(default = "default_true")]
    pub notify_dns_leak: bool,
    #[serde(default)]
    pub bot_proxy_section: String,
    #[serde(default)]
    pub language: String,
}

impl Default for TgBotConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            bot_token: String::new(),
            admin_ids: Vec::new(),
            poll_interval: 5,
            notify_crash: true,
            notify_restart: true,
            notify_server_switch: true,
            notify_subscription: true,
            notify_dns_leak: true,
            bot_proxy_section: String::new(),
            language: "ru".to_string(),
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
            guest_mode: GuestModeConfig {
                enabled: false,
                mode: "selected".to_string(),
                guest_devices: Vec::new(),
                trusted_devices: Vec::new(),
                isolate_lan: true,
                block_router_admin: true,
                daily_time_limit: 0,
                daily_traffic_limit: 0,
                bandwidth_limit_mbps: 0,
                allowed_ports: Vec::new(),
                start_time: String::new(),
                end_time: String::new(),
                days: Vec::new(),
            },
            telegram: TgBotConfig::default(),
        };
        if s.import_legacy_router_files() == 0 {
            s.seed_defaults();
        }
        s
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

    /// Import existing router configuration from `/etc/config/tachyon` and `/etc/tachyon/subscription-cache/*.json`
    /// into native `RouterStoreData` (`tachyon.json`) with zero runtime UCI dependency.
    pub fn import_legacy_router_files(&mut self) -> usize {
        let legacy_path = Path::new("/etc/config/tachyon");
        let Ok(raw) = std::fs::read_to_string(legacy_path) else {
            return 0;
        };
        let blocks = parse_legacy_uci_blocks(&raw);
        if blocks.is_empty() {
            return 0;
        }

        let selector_state: HashMap<String, String> =
            std::fs::read_to_string("/etc/tachyon/selector_state.json")
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();

        self.sections.clear();
        self.conditions.clear();
        self.outbound_sources.clear();
        self.balancers.clear();
        self.servers.clear();

        let mut imported = 0usize;

        for b in &blocks {
            match b.kind.as_str() {
                "settings" => {
                    if let Some(v) = b.opt("proxy_mode") {
                        self.settings.proxy_mode = v.to_string();
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
                    if let Some(v) = b.opt("lite_mode") {
                        self.settings.lite_mode = v == "1" || v == "true";
                    }
                    if let Some(v) = b.opt("disable_quic") {
                        self.settings.disable_quic = v == "1" || v == "true";
                    }
                    if let Some(v) = b.opt("isolate_p2p") {
                        self.settings.isolate_p2p = v == "1" || v == "true";
                    }
                    if let Some(v) = b.opt("direct_bypass_enabled") {
                        self.settings.direct_bypass_enabled = v == "1" || v == "true";
                    }
                    if let Some(v) = b.opt("direct_bypass_port").and_then(|s| s.parse().ok()) {
                        self.settings.direct_bypass_port = v;
                    }
                    if let Some(v) = b.opt("smart_detect") {
                        self.settings.smart_detect = v == "1" || v == "true";
                    }
                    let sd_secs = b.list("smart_detect_sections");
                    if !sd_secs.is_empty() {
                        self.settings.smart_detect_sections = sd_secs;
                    }
                    if let Some(v) = b.opt("enable_ai_doctor") {
                        self.settings.enable_ai_doctor = v == "1" || v == "true";
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
                    if let Some(v) = b.opt("server_subscription_token") {
                        self.settings.server_subscription_token = v.to_string();
                    }
                    if let Some(v) = b.opt("server_subscription_host") {
                        self.settings.server_subscription_host = v.to_string();
                    }
                }
                "telegram" => {
                    self.telegram.enabled =
                        b.opt("enabled").is_some_and(|v| v == "1" || v == "true");
                    if let Some(v) = b.opt("bot_token") {
                        self.telegram.bot_token = v.to_string();
                    }
                    if let Some(v) = b.opt("admin_ids") {
                        self.telegram.admin_ids = v
                            .split([',', ' '])
                            .filter_map(|s| s.trim().parse::<i64>().ok())
                            .collect();
                    }
                    if let Some(v) = b.opt("bot_proxy_section") {
                        self.telegram.bot_proxy_section = v.to_string();
                    }
                }
                "condition" => {
                    let mut user_domains = b.list("user_domains");
                    if let Some(dom_multiline) = b.opt("domain") {
                        for line in dom_multiline.lines() {
                            let t = line.trim();
                            if !t.is_empty()
                                && !t.starts_with("//")
                                && !t.starts_with('#')
                                && !user_domains.contains(&t.to_string())
                            {
                                user_domains.push(t.to_string());
                            }
                        }
                    }
                    let mut user_subnets = b.list("ip_cidr");
                    if let Some(cidr_multiline) = b.opt("ip_cidr") {
                        for line in cidr_multiline.lines() {
                            let t = line.trim();
                            if !t.is_empty()
                                && !t.starts_with("//")
                                && !user_subnets.contains(&t.to_string())
                            {
                                user_subnets.push(t.to_string());
                            }
                        }
                    }
                    self.conditions.push(TrafficCondition {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(|v| v == "1" || v == "true"),
                        name: b.opt("name").unwrap_or(&b.name).to_string(),
                        condition_type: b.opt("condition_type").unwrap_or("atomic").to_string(),
                        community_lists: b.list("community_lists"),
                        user_domains,
                        user_subnets,
                        geoip_codes: b.list("geoip_country"),
                        geoip_mode: b.opt("geoip_mode").unwrap_or("include").to_string(),
                        client_ips: b.list("fully_routed_ips"),
                        ..Default::default()
                    });
                    imported += 1;
                }
                "balancer" => {
                    let check_interval = b
                        .opt("check_interval")
                        .map(parse_duration_secs)
                        .unwrap_or(180);
                    self.balancers.push(BalancerConfig {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(|v| v == "1" || v == "true"),
                        name: b.opt("name").unwrap_or(&b.name).to_string(),
                        balancer_type: b.opt("balancer_type").unwrap_or("urltest").to_string(),
                        mode: b.opt("mode").unwrap_or("least_test").to_string(),
                        testing_url: b
                            .opt("testing_url")
                            .unwrap_or("https://www.gstatic.com/generate_204")
                            .to_string(),
                        check_interval,
                        tolerance: b
                            .opt("tolerance")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(50),
                        sticky_hash: String::new(),
                        passive_check: true,
                        interrupt_exist_connections: b
                            .opt("interrupt_exist_connections")
                            .is_some_and(|v| v == "1" || v == "true"),
                    });
                    imported += 1;
                }
                "outbound_source" => {
                    let stype = b.opt("source_type").unwrap_or("subscription").to_string();
                    let mut urls = b.list("subscription_urls");
                    if let Some(u) = b.opt("url")
                        && !u.is_empty()
                        && !urls.contains(&u.to_string())
                    {
                        urls.push(u.to_string());
                    }
                    let preset = b.opt("desync_preset").unwrap_or("adaptive").to_string();
                    let auto_tune = preset == "adaptive" || preset == "auto";
                    let fake_sni = b.opt("desync_fake_sni").unwrap_or("").to_string();
                    let mut sni_pool = b.list("desync_sni_pool");
                    if !fake_sni.is_empty() && !sni_pool.contains(&fake_sni) {
                        sni_pool.push(fake_sni.clone());
                    }

                    let mut src = OutboundSource {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(|v| v == "1" || v == "true"),
                        name: b.opt("name").unwrap_or(&b.name).to_string(),
                        source_type: stype.clone(),
                        subscription_urls: urls,
                        subscription_update_interval: b
                            .opt("subscription_update_interval")
                            .unwrap_or("3h")
                            .to_string(),
                        desync_preset: preset,
                        desync_auto_tune: auto_tune,
                        desync_fake_sni: fake_sni,
                        desync_sni_pool: sni_pool,
                        desync_split_pos: b.opt("desync_split_pos").unwrap_or("sni").to_string(),
                        desync_fooling: b.opt("desync_fooling").unwrap_or("autottl").to_string(),
                        last_updated_unix: unix_now_secs(),
                        ..Default::default()
                    };

                    if stype == "subscription" {
                        load_cached_subscription_nodes(&mut src);
                    }
                    self.outbound_sources.push(src);
                    imported += 1;
                }
                "section" => {
                    let raw_action = b.opt("action").unwrap_or("connection");
                    let out_refs = b.list("outbound_source_refs");
                    let conn_type = match raw_action {
                        "block" => "block",
                        "bypass" | "direct" => "direct",
                        "dns" => "dns",
                        _ => {
                            if out_refs.iter().any(|r| r.contains("desync")) {
                                "desync"
                            } else if b.name.eq_ignore_ascii_case("fptn") {
                                "fptn"
                            } else {
                                "proxy"
                            }
                        }
                    };
                    let mut user_domains = b.list("user_domains");
                    if let Some(dom_multiline) = b.opt("domain") {
                        for line in dom_multiline.lines() {
                            let t = line.trim();
                            if !t.is_empty()
                                && !t.starts_with("//")
                                && !t.starts_with('#')
                                && !user_domains.contains(&t.to_string())
                            {
                                user_domains.push(t.to_string());
                            }
                        }
                    }
                    let mut user_subnets = b.list("ip_cidr");
                    if let Some(cidr_multiline) = b.opt("ip_cidr") {
                        for line in cidr_multiline.lines() {
                            let t = line.trim();
                            if !t.is_empty()
                                && !t.starts_with("//")
                                && !user_subnets.contains(&t.to_string())
                            {
                                user_subnets.push(t.to_string());
                            }
                        }
                    }
                    let active_sel = selector_state
                        .get(&b.name)
                        .or_else(|| selector_state.get(&format!("{}-out", b.name)))
                        .cloned()
                        .unwrap_or_default();

                    self.sections.push(RoutingSection {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(|v| v == "1" || v == "true"),
                        label: b.opt("label").unwrap_or(&b.name).to_string(),
                        icon: String::new(),
                        connection_type: conn_type.to_string(),
                        action: raw_action.to_string(),
                        condition_refs: b.list("condition_refs"),
                        outbound_source_refs: out_refs,
                        balancer_refs: b.list("balancer_refs"),
                        outbound_group_ref: String::new(),
                        community_lists: b.list("community_lists"),
                        user_domains,
                        user_subnets,
                        geoip_codes: b.list("geoip_country"),
                        geoip_mode: b.opt("geoip_mode").unwrap_or("exclude").to_string(),
                        fully_routed_ips: b.list("fully_routed_ips"),
                        outbound_detour_enabled: b
                            .opt("outbound_detour_enabled")
                            .is_some_and(|v| v == "1" || v == "true"),
                        outbound_detour_section: b
                            .opt("outbound_detour_section")
                            .unwrap_or("")
                            .to_string(),
                        sort_by_latency: b
                            .opt("sort_by_latency")
                            .is_some_and(|v| v == "1" || v == "true"),
                        fail_policy: b.opt("fail_policy").unwrap_or("keep").to_string(),
                        routed_dns_enabled: b
                            .opt("routed_dns_enabled")
                            .is_some_and(|v| v == "1" || v == "true"),
                        dns_servers: b.list("dns_server"),
                        active_selected_tag: active_sel,
                    });
                    imported += 1;
                }
                "server" => {
                    let raw_port = b.opt("listen_port").unwrap_or("443");
                    let listen_port = raw_port
                        .split('-')
                        .next()
                        .and_then(|s| s.parse::<u16>().ok())
                        .unwrap_or(443);
                    let listen_port_range = if raw_port.contains('-') {
                        raw_port.to_string()
                    } else {
                        String::new()
                    };
                    let proto = b.opt("protocol").unwrap_or("vless").to_string();
                    let label = b.opt("label").unwrap_or(&b.name).to_string();
                    let srv_uuid = b
                        .opt("server_uuid")
                        .or_else(|| b.opt("tewfai_uuid"))
                        .unwrap_or("")
                        .to_string();
                    let srv_pw = b
                        .opt("server_password")
                        .or_else(|| b.opt("tewfai_password"))
                        .unwrap_or("")
                        .to_string();
                    let flow = b.opt("vless_flow").unwrap_or("none").to_string();

                    let default_client = InboundClient {
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
                        total_limit_bytes: 0,
                        expiry_time: 0,
                        ip_limit: 0,
                        wg_public_key: b.opt("awg_peer_public_key").unwrap_or("").to_string(),
                        wg_private_key: b.opt("awg_client_private_key").unwrap_or("").to_string(),
                        wg_client_ip: b
                            .opt("awg_client_address")
                            .unwrap_or("10.8.0.2/32")
                            .to_string(),
                    };

                    self.servers.push(InboundServer {
                        id: b.name.clone(),
                        enabled: b.opt("enabled").is_none_or(|v| v == "1" || v == "true"),
                        label,
                        country: b.opt("server_country").unwrap_or("RU").to_string(),
                        protocol: proto,
                        listen: b.opt("listen").unwrap_or("0.0.0.0").to_string(),
                        listen_port,
                        listen_port_range,
                        public_host: b.opt("public_host").unwrap_or("192.168.1.205").to_string(),
                        open_firewall_port: b
                            .opt("open_firewall_port")
                            .is_none_or(|v| v == "1" || v == "true"),
                        routing_mode: b.opt("routing_mode").unwrap_or("rules").to_string(),
                        routing_section: b.opt("routing_section").unwrap_or("").to_string(),
                        security: b.opt("security").unwrap_or("none").to_string(),
                        server_uuid: srv_uuid,
                        server_username: b.opt("server_username").unwrap_or("").to_string(),
                        password: srv_pw,
                        method: b
                            .opt("shadowsocks_method")
                            .unwrap_or("aes-128-gcm")
                            .to_string(),
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
                        transport: b.opt("transport").unwrap_or("tcp").to_string(),
                        transport_path: b.opt("transport_path").unwrap_or("").to_string(),
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
                        hysteria2_obfs_password: b
                            .opt("hysteria2_obfs_password")
                            .unwrap_or("")
                            .to_string(),
                        hysteria2_up_mbps: 100,
                        hysteria2_down_mbps: 100,
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
                        trusttunnel_quic: b
                            .opt("trusttunnel_quic")
                            .is_some_and(|v| v == "1" || v == "true"),
                        masque_ipv4_pool: b
                            .opt("masque_ipv4_pool")
                            .unwrap_or("172.16.0.0/24")
                            .to_string(),
                        masque_mtu: b
                            .opt("masque_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1400),
                        openconnect_cookie: b.opt("openconnect_cookie").unwrap_or("").to_string(),
                        openconnect_flavor: b
                            .opt("openconnect_flavor")
                            .unwrap_or("anyconnect")
                            .to_string(),
                        openconnect_address: b
                            .opt("openconnect_address")
                            .unwrap_or("172.16.1.2/24")
                            .to_string(),
                        openconnect_mtu: b
                            .opt("openconnect_mtu")
                            .and_then(|s| s.parse().ok())
                            .unwrap_or(1400),
                        mtproto_secret: b.opt("mtproto_secret").unwrap_or("").to_string(),
                        mtproto_faketls: b
                            .opt("mtproto_faketls")
                            .unwrap_or("google.com")
                            .to_string(),
                        mtproto_telegram_ws: false,
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
                        awg_dns: b.opt("awg_dns").unwrap_or("192.168.1.205").to_string(),
                        awg_jc: b.opt("awg_jc").and_then(|s| s.parse().ok()).unwrap_or(5),
                        awg_jmin: b.opt("awg_jmin").and_then(|s| s.parse().ok()).unwrap_or(40),
                        awg_jmax: b.opt("awg_jmax").and_then(|s| s.parse().ok()).unwrap_or(70),
                        awg_s1: b.opt("awg_s1").and_then(|s| s.parse().ok()).unwrap_or(17),
                        awg_s2: b.opt("awg_s2").and_then(|s| s.parse().ok()).unwrap_or(26),
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
                        tailscale_auth_key: String::new(),
                        tailscale_hostname: b.opt("tailscale_hostname").unwrap_or("").to_string(),
                        tailscale_advertise_exit_node: false,
                        isolate_lan_for_users: false,
                        isolated_users: Vec::new(),
                        isolated_subnets: Vec::new(),
                        clients: vec![default_client],
                        inbound_json: String::new(),
                    });
                    imported += 1;
                }
                _ => {}
            }
        }
        imported
    }
}

struct LegacyUciBlock {
    kind: String,
    name: String,
    options: HashMap<String, String>,
    lists: HashMap<String, Vec<String>>,
}

impl LegacyUciBlock {
    fn opt(&self, key: &str) -> Option<&str> {
        self.options.get(key).map(String::as_str)
    }
    fn list(&self, key: &str) -> Vec<String> {
        self.lists.get(key).cloned().unwrap_or_default()
    }
}

fn parse_legacy_uci_blocks(raw: &str) -> Vec<LegacyUciBlock> {
    let mut blocks: Vec<LegacyUciBlock> = Vec::new();
    let mut current: Option<LegacyUciBlock> = None;
    let mut multiline_key: Option<(bool, String, String)> = None;

    for line in raw.lines() {
        if let Some((is_list, ref key, ref mut acc)) = multiline_key {
            if let Some(stripped) = line.strip_suffix('\'') {
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

fn load_cached_subscription_nodes(src: &mut OutboundSource) {
    let cache_dir = Path::new("/etc/tachyon/subscription-cache");
    let Ok(entries) = std::fs::read_dir(cache_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let fname = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if fname.ends_with(".metadata.json") {
            if let Ok(raw) = std::fs::read_to_string(&path)
                && let Ok(v) = serde_json::from_str::<Value>(&raw)
            {
                if let Some(t) = v.get("title").and_then(Value::as_str) {
                    src.sub_title = t.to_string();
                }
                if let Some(u) = v.get("supportUrl").and_then(Value::as_str) {
                    src.sub_support_url = u.to_string();
                }
                if let Some(u) = v.get("webPageUrl").and_then(Value::as_str) {
                    src.sub_web_page_url = u.to_string();
                }
                if let Some(a) = v.get("announce").and_then(Value::as_str) {
                    src.sub_announce = a.to_string();
                }
            }
            continue;
        }
        if !fname.ends_with(".json") {
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
            let server_port = item
                .get("server_port")
                .and_then(Value::as_u64)
                .unwrap_or(443) as u16;
            if tag.is_empty() || server.is_empty() {
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

pub struct AppState {
    pub path: PathBuf,
    pub lkg_path: PathBuf,
    pub data: RwLock<RouterStoreData>,
    pub live: RwLock<LiveTelemetry>,
    /// Session token -> expiry unix timestamp (bounded to `MAX_SESSIONS`).
    pub sessions: RwLock<HashMap<String, i64>>,
    pub dirty: AtomicBool,
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
            let mut parsed = serde_json::from_str::<RouterStoreData>(&raw)?;
            // If store only has the initial demo sections/servers and `/etc/config/tachyon` exists,
            // auto-import the router's full configuration so nothing is missing.
            if parsed.sections.len() <= 2
                && parsed.servers.len() <= 1
                && Path::new("/etc/config/tachyon").exists()
            {
                let count = parsed.import_legacy_router_files();
                if count > 0 {
                    let _ = crypto_gen::write_json_if_changed(&path, &parsed);
                }
            }
            parsed
        } else {
            let default_data = RouterStoreData::default();
            let _ = crypto_gen::write_json_if_changed(&path, &default_data);
            default_data
        };

        let core_ver = std::fs::read_to_string("/etc/tachyon/tachyon-core-version")
            .ok()
            .map(|s| s.trim().to_string())
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
