//! Autonomous Diagnostics Engine:
//! - Local Rule Doctor (16 subsystem checks) & 25 automated Quick Fixes (`apply_quick_fix`)
//! - AI Doctor v3.0 with privacy redaction, RAG knowledge base search, and LLM provider client
//! - Packet path simulator (`route_explain`) + `tachyon-core` `/tachyon/route-check` bridge
//! - Parallel Native Desync Strategy Fuzzer
//! - Parallel SNI Scanner (`scan_sni_domains`)
//! - Service Availability & Unlock Probe (`run_unlock_probe`)
//! - DNS Speed Test & Leak / FakeIP Verifier (`run_leak_check`)
//! - Router `/proc/net/nf_conntrack` session reader for Monitoring
//! - Redacted Support Bundle generator

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio::process::Command;

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::net_stack;
use crate::snapshots;
use crate::store::{AppState, IncidentRecord, OutboundSource, RouterStoreData, unix_now_secs};
use crate::sys_info;
use crate::transaction;
use crate::watchdog;

pub const MAX_INCIDENTS: usize = 30;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DoctorFinding {
    pub id: String,
    pub severity: String,
    pub subsystem: String,
    pub title: String,
    pub detail: String,
    pub quick_fix_id: String,
    pub quick_fix_label: String,
    #[serde(default)]
    pub root_cause: bool,
    #[serde(default)]
    pub suppressed_by: Option<String>,
    #[serde(default)]
    pub risk_tier: String,
    #[serde(default)]
    pub evidence: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DoctorReport {
    pub healthy: bool,
    pub timestamp: i64,
    pub checks_total: usize,
    pub checks_passed: usize,
    pub subsystems: Vec<Value>,
    pub findings: Vec<DoctorFinding>,
    pub summary: String,
    #[serde(default)]
    pub pipeline_nodes: Vec<Value>,
    #[serde(default)]
    pub root_causes: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VerifiedFixResult {
    pub ok: bool,
    pub fix_id: String,
    pub risk_tier: String,
    pub dry_run: bool,
    pub message: String,
    pub before_healthy: bool,
    pub after_healthy: bool,
    pub before_findings: usize,
    pub after_findings: usize,
    pub rolled_back: bool,
    pub cooldown_blocked: bool,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteExplainResult {
    pub client_ip: String,
    pub target: String,
    pub port: u16,
    pub protocol: String,
    pub matched_section_id: String,
    pub matched_section_label: String,
    pub matched_section: String,
    pub matched_condition_id: String,
    pub matched_reason: String,
    pub resolved_outbound: String,
    pub selected_outbound: String,
    pub dns_strategy: String,
    pub connection_type: String,
    pub steps: Vec<String>,
    pub trace_steps: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DnsBenchmarkEntry {
    pub server: String,
    pub protocol: String,
    pub latency_ms: u32,
    pub reachable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FuzzerStrategyResult {
    pub preset: String,
    pub label: String,
    pub success: bool,
    pub latency_ms: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SniScanEntry {
    pub domain: String,
    pub reachable: bool,
    pub latency_ms: u32,
    pub tls13: bool,
    pub recommended: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnlockProbeEntry {
    pub service: String,
    pub category: String,
    pub host: String,
    pub reachable: bool,
    pub latency_ms: u32,
}

fn is_en_lang(lang: &str) -> bool {
    lang.trim().eq_ignore_ascii_case("en")
}

#[cfg(test)]
pub fn evaluate_odhcpd_ipv6_dns(dhcp_conf_raw: &str, odhcpd_present: bool) -> (bool, String) {
    evaluate_odhcpd_ipv6_dns_lang(dhcp_conf_raw, odhcpd_present, false)
}

fn evaluate_odhcpd_ipv6_dns_lang(
    dhcp_conf_raw: &str,
    odhcpd_present: bool,
    en: bool,
) -> (bool, String) {
    if !odhcpd_present {
        return (
            true,
            if en {
                "odhcpd is not installed (IPv6 DNS check not required)"
            } else {
                "odhcpd не установлен (проверка IPv6 DNS не требуется)"
            }
            .to_string(),
        );
    }
    let mut in_lan = false;
    let mut dhcpv6 = String::new();
    let mut ra_dns = String::new();
    let mut dns_list: Vec<String> = Vec::new();
    let unquote = |raw: &str| -> String {
        let mut s = raw.trim();
        if s.len() >= 2
            && ((s.starts_with('\'') && s.ends_with('\''))
                || (s.starts_with('"') && s.ends_with('"')))
        {
            s = &s[1..s.len() - 1];
        }
        s.trim().to_string()
    };

    for raw_line in dhcp_conf_raw.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("config ") {
            let mut parts = rest.split_whitespace();
            let kind = parts.next().map(unquote).unwrap_or_default();
            let sec_name = parts.next().map(unquote).unwrap_or_default();
            in_lan = kind == "dhcp" && sec_name == "lan";
            continue;
        }
        if !in_lan {
            continue;
        }
        if let Some(rest) = line.strip_prefix("option ") {
            let mut parts = rest.splitn(2, char::is_whitespace);
            let key = parts.next().map(unquote).unwrap_or_default();
            let val = parts.next().map(unquote).unwrap_or_default();
            match key.as_str() {
                "dhcpv6" => dhcpv6 = val,
                "ra_dns" => ra_dns = val,
                "dns" => {
                    for tok in val.split_whitespace() {
                        if !tok.is_empty() && !dns_list.iter().any(|d| d == tok) {
                            dns_list.push(tok.to_string());
                        }
                    }
                }
                _ => {}
            }
        } else if let Some(rest) = line.strip_prefix("list ") {
            let mut parts = rest.splitn(2, char::is_whitespace);
            let key = parts.next().map(unquote).unwrap_or_default();
            let val = parts.next().map(unquote).unwrap_or_default();
            if key == "dns" && !val.is_empty() && !dns_list.iter().any(|d| d == &val) {
                dns_list.push(val);
            }
        }
    }

    if !dhcpv6.eq_ignore_ascii_case("server") {
        return (
            true,
            if en {
                "odhcpd DHCPv6 server on LAN is inactive"
            } else {
                "DHCPv6-сервер odhcpd на lan неактивен"
            }
            .to_string(),
        );
    }
    if ra_dns == "1" || !dns_list.is_empty() {
        let detail = if !dns_list.is_empty() {
            if en {
                format!("DHCPv6 DNS configured ({})", dns_list.join(", "))
            } else {
                format!("DHCPv6 DNS настроен ({})", dns_list.join(", "))
            }
        } else if en {
            "DHCPv6 RA DNS active (ra_dns=1)".to_string()
        } else {
            "DHCPv6 RA DNS активен (ra_dns=1)".to_string()
        };
        return (true, detail);
    }
    (
        false,
        if en {
            "dhcp.lan.dhcpv6='server' is enabled without ra_dns='1' or list dns"
        } else {
            "При включённом dhcp.lan.dhcpv6='server' не заданы ra_dns='1' и list dns"
        }
        .to_string(),
    )
}

pub fn quick_fix_risk_tier(fix_id: &str) -> &'static str {
    let base = fix_id
        .split_once(':')
        .map(|(head, _)| head)
        .unwrap_or(fix_id);
    match base {
        "trim_core_memory"
        | "optimize_memory"
        | "flush_core_dns"
        | "clear_dns_cache"
        | "capture_blackbox"
        | "restore_primary_failover"
        | "upgrade_core"
        | "sync_flow_offload_guard"
        | "fix_system_time" => "safe",
        "restart_core"
        | "start_core"
        | "start_tachyon_core"
        | "hot_reload_core"
        | "restart_core_dns"
        | "restart_tachyon_core_dns"
        | "reset_outbound_pool"
        | "reconcile_nftables"
        | "heal_network_stack"
        | "rebuild_rules"
        | "reset_firewall"
        | "fix_dnsmasq"
        | "fix_wan_interface"
        | "fix_gateway"
        | "restart_network"
        | "flush_conntrack"
        | "fix_resolv_symlink" => "disruptive",
        "switch_to_doh"
        | "fix_bootstrap_dns"
        | "optimize_mtu"
        | "rollback_core_binary"
        | "rollback_known_good"
        | "fix_uci_config"
        | "restore_lkg"
        | "enable_default_desync"
        | "restart_zapret"
        | "disable_flow_offloading"
        | "restore_native_internet"
        | "enable_safe_bypass"
        | "flush_nftables"
        | "update_subscriptions"
        | "restart_providers"
        | "start_watchdog"
        | "enable_autostart" => "config_change",
        _ => "config_change",
    }
}

pub fn is_known_quick_fix(fix_id: &str) -> bool {
    let base = fix_id
        .split_once(':')
        .map(|(head, _)| head)
        .unwrap_or(fix_id);
    matches!(
        base,
        "restart_core"
            | "start_core"
            | "start_tachyon_core"
            | "hot_reload_core"
            | "heal_network_stack"
            | "rebuild_rules"
            | "reset_firewall"
            | "reconcile_nftables"
            | "fix_bootstrap_dns"
            | "switch_to_doh"
            | "clear_dns_cache"
            | "restart_core_dns"
            | "restart_tachyon_core_dns"
            | "flush_core_dns"
            | "fix_dnsmasq"
            | "fix_resolv_symlink"
            | "start_watchdog"
            | "optimize_memory"
            | "trim_core_memory"
            | "optimize_mtu"
            | "flush_conntrack"
            | "fix_system_time"
            | "update_subscriptions"
            | "restart_providers"
            | "fix_wan_interface"
            | "fix_gateway"
            | "restart_network"
            | "restore_native_internet"
            | "enable_safe_bypass"
            | "flush_nftables"
            | "enable_autostart"
            | "enable_default_desync"
            | "restart_zapret"
            | "rollback_known_good"
            | "fix_uci_config"
            | "restore_lkg"
            | "rollback_core_binary"
            | "upgrade_core"
            | "disable_flow_offloading"
            | "sync_flow_offload_guard"
            | "reset_outbound_pool"
            | "restore_primary_failover"
            | "capture_blackbox"
    )
}

/// Pure causal dependency graph: suppress downstream secondary symptoms when an upstream
/// root cause (WAN offline, severe clock skew, missing/stopped core) explains them.
pub fn apply_causal_suppression(findings: &mut [DoctorFinding]) -> Vec<String> {
    for f in findings.iter_mut() {
        if f.risk_tier.is_empty() {
            f.risk_tier = quick_fix_risk_tier(&f.quick_fix_id).to_string();
        }
        f.suppressed_by = None;
        f.root_cause = false;
    }

    let has_wan_down = findings.iter().any(|f| f.id == "wan_down");
    let has_clock_skew = findings.iter().any(|f| f.id == "clock_skew");
    let core_blocker = findings
        .iter()
        .find(|f| f.id == "core_binary_corrupt" || f.id == "core_stopped")
        .map(|f| f.id.clone());

    for f in findings.iter_mut() {
        if let Some(ref blocker) = core_blocker
            && matches!(
                f.id.as_str(),
                "config_drift" | "dns_unhealthy" | "failover_on_backup"
            )
        {
            f.suppressed_by = Some(blocker.clone());
            continue;
        }
        if let Some(ref blocker) = core_blocker
            && (f.id.starts_with("outbound_") || f.id.starts_with("anomalies_"))
        {
            f.suppressed_by = Some(blocker.clone());
            continue;
        }
        if has_wan_down
            && (f.id == "dns_unhealthy"
                || f.id == "dns_upstream_errors"
                || f.id == "failover_on_backup"
                || f.id.starts_with("outbound_")
                || f.id.starts_with("anomalies_")
                || f.id.starts_with("sub_empty_"))
        {
            f.suppressed_by = Some("wan_down".to_string());
            continue;
        }
        if has_clock_skew
            && (f.id.contains("tls_handshake_fail") || f.id.contains("reality_auth_fail"))
        {
            f.suppressed_by = Some("clock_skew".to_string());
            continue;
        }
    }

    let mut root_causes = Vec::new();
    for f in findings.iter_mut() {
        if f.suppressed_by.is_some() {
            continue;
        }
        let is_primary = f.severity == "critical"
            || matches!(
                f.id.as_str(),
                "wan_down"
                    | "clock_skew"
                    | "core_binary_corrupt"
                    | "core_stopped"
                    | "config_drift"
                    | "nft_missing"
                    | "flow_offloading_conflict"
                    | "dns_unhealthy"
                    | "dns_upstream_errors"
                    | "low_memory"
                    | "core_memory_pressure"
                    | "fd_exhaustion"
                    | "fakeip_saturation"
            )
            || f.id.starts_with("outbound_");
        if is_primary {
            f.root_cause = true;
            root_causes.push(f.title.clone());
        }
    }
    if root_causes.is_empty()
        && let Some(first_active) = findings.iter_mut().find(|f| f.suppressed_by.is_none())
    {
        first_active.root_cause = true;
        root_causes.push(first_active.title.clone());
    }
    root_causes
}

/// Returns `true` only when a failover-capable group is actually degraded/on backup,
/// ignoring healthy `least_test` (URLTest) balancers that pick a lower-RTT member.
pub fn has_true_failover_backup(failover_val: Option<&Value>) -> bool {
    let Some(val) = failover_val else {
        return false;
    };
    if let Some(groups) = val.get("groups").and_then(Value::as_array) {
        return groups.iter().any(|g| {
            let on_backup = g.get("on_backup").and_then(Value::as_bool).unwrap_or(false);
            if !on_backup {
                return false;
            }
            let mode = g.get("mode").and_then(Value::as_str).unwrap_or("");
            let is_failover_mode = matches!(mode, "failover" | "priority" | "fallback");
            let primary_healthy = g
                .get("primary_healthy")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let primary_failures = g
                .get("primary_failures")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            let primary_quarantine = g
                .get("primary_quarantine_rem_s")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            is_failover_mode || !primary_healthy || primary_failures > 0 || primary_quarantine > 0
        });
    }
    val.get("any_on_backup")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// Run Local Doctor without querying live Clash endpoints directly (uses stored telemetry).
pub async fn run_local_doctor(state: &Arc<AppState>) -> DoctorReport {
    Box::pin(build_doctor_report(state, None, None, None, None, None)).await
}

/// Full causal Local Doctor querying live `tachyon-core` health, anomalies, Flight failures, and failover.
pub async fn run_local_doctor_with_core(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> DoctorReport {
    let core_up = state.live.read().await.core_running;
    let (health, anomalies, flight_failures, failover) = if core_up {
        let (h, a, f, fo) = tokio::join!(
            Box::pin(core.get_core_health()),
            Box::pin(core.get_core_anomalies()),
            Box::pin(core.get_core_flight_filtered(true, None, 20)),
            Box::pin(core.get_core_failover()),
        );
        (h.ok(), a.ok(), f.ok(), Some(fo))
    } else {
        (None, None, None, None)
    };
    let bin_path = core.resolve_bin_path().await;
    Box::pin(build_doctor_report(
        state,
        Some(bin_path.as_str()),
        health,
        anomalies,
        flight_failures,
        failover,
    ))
    .await
}

async fn build_doctor_report(
    state: &Arc<AppState>,
    resolved_bin_path: Option<&str>,
    health_val: Option<Value>,
    anomalies_val: Option<Value>,
    flight_val: Option<Value>,
    failover_val: Option<Value>,
) -> DoctorReport {
    let d = Box::new(state.data.read().await.clone());
    let live = Box::new(state.live.read().await.clone());
    let (odhcpd_present, dhcp_raw, fw4_forward_order_ok) = if cfg!(windows) {
        (false, String::new(), true)
    } else {
        let present = tokio::fs::metadata("/etc/init.d/odhcpd").await.is_ok();
        let raw = tokio::fs::read_to_string("/etc/config/dhcp")
            .await
            .unwrap_or_default();
        let order_ok = match crate::net_stack::read_fw4_forward_chain_listing().await {
            Some(listing) => crate::net_stack::fw4_forward_guard_ordered_before_offload(&listing),
            None => true,
        };
        (present, raw, order_ok)
    };
    assemble_doctor_report(
        state,
        &d,
        &live,
        resolved_bin_path,
        health_val,
        anomalies_val,
        flight_val,
        failover_val,
        odhcpd_present,
        &dhcp_raw,
        fw4_forward_order_ok,
    )
}

#[inline(never)]
#[allow(clippy::too_many_arguments)]
fn assemble_doctor_report(
    state: &Arc<AppState>,
    d: &RouterStoreData,
    live: &crate::store::LiveTelemetry,
    resolved_bin_path: Option<&str>,
    health_val: Option<Value>,
    anomalies_val: Option<Value>,
    flight_val: Option<Value>,
    failover_val: Option<Value>,
    odhcpd_present: bool,
    dhcp_raw: &str,
    fw4_forward_order_ok: bool,
) -> DoctorReport {
    let mut findings = Vec::new();
    let en = is_en_lang(&d.settings.lang);
    let core_bin_path = d.settings.core_bin_path.clone();
    let proxy_mode = d.settings.proxy_mode.clone();
    let smart_queue = d.settings.smart_queue;
    let bootstrap_dns_empty = d.settings.bootstrap_dns_servers.is_empty();
    let fakeip_enabled = d.settings.fakeip_enabled;
    let enable_watchdog = d.settings.enable_watchdog;
    let enabled_sections = d.sections.iter().filter(|s| s.enabled).count();
    let total_sections = d.sections.len();
    let empty_subs: Vec<(String, String)> = d
        .outbound_sources
        .iter()
        .filter(|s| {
            s.enabled
                && s.source_type == "subscription"
                && s.cached_nodes.is_empty()
                && s.proxy_links.is_empty()
        })
        .map(|s| (s.id.clone(), s.name.clone()))
        .collect();
    let sources_len = d.outbound_sources.len();
    let balancers_len = d.balancers.len();
    let enabled_servers = d.servers.iter().filter(|s| s.enabled).count();
    let total_servers = d.servers.len();
    let sys = sys_info::collect_host_info();
    let checks_total = 16usize;

    let eff_bin_path = resolved_bin_path
        .filter(|s| !s.is_empty())
        .unwrap_or(core_bin_path.as_str());
    let bin_check_res = if !eff_bin_path.is_empty() && Path::new(eff_bin_path).exists() {
        watchdog::check_core_binary_integrity(Path::new(eff_bin_path))
    } else if !live.core_binary_ok && !live.core_binary_error.is_empty() {
        Err(live.core_binary_error.clone())
    } else {
        Ok(())
    };
    if let Err(err) = &bin_check_res {
        findings.push(DoctorFinding {
            id: "core_binary_corrupt".to_string(),
            severity: "critical".to_string(),
            subsystem: "binary".to_string(),
            title: "Бинарный файл tachyon-core повреждён или заменён скриптом".to_string(),
            detail: err.clone(),
            quick_fix_id: "rollback_core_binary".to_string(),
            quick_fix_label: "Откатить бинарник ядра".to_string(),
            evidence: json!({ "path": eff_bin_path, "error": err }),
            ..Default::default()
        });
    }

    // 1. Core process liveness
    if !live.core_running {
        findings.push(DoctorFinding {
            id: "core_stopped".to_string(),
            severity: "critical".to_string(),
            subsystem: "core".to_string(),
            title: if en {
                "tachyon-core process is not running"
            } else {
                "Процесс tachyon-core не запущен"
            }
            .to_string(),
            detail: if en {
                "Routing core is stopped or not responding."
            } else {
                "Ядро маршрутизации остановлено или не отвечает."
            }
            .to_string(),
            quick_fix_id: "restart_core".to_string(),
            quick_fix_label: if en {
                "Start tachyon-core"
            } else {
                "Запустить tachyon-core"
            }
            .to_string(),
            ..Default::default()
        });
    }

    // 1b. Config digest drift check
    let applied_digest = health_val
        .as_ref()
        .and_then(|h| h.pointer("/config_state/digest"))
        .and_then(Value::as_str)
        .unwrap_or(&live.applied_config_digest)
        .to_string();
    let config_drift = live.config_drift
        || (live.core_running
            && !live.desired_config_digest.is_empty()
            && !applied_digest.is_empty()
            && live.desired_config_digest != applied_digest);
    if config_drift {
        findings.push(DoctorFinding {
            id: "config_drift".to_string(),
            severity: "warning".to_string(),
            subsystem: "config_sync".to_string(),
            title: "Рассинхронизация конфигурации ядра (config_drift)".to_string(),
            detail: "Применённый digest в памяти tachyon-core отличается от актуальной конфигурации хранилища.".to_string(),
            quick_fix_id: "hot_reload_core".to_string(),
            quick_fix_label: "Выполнить Hot-Reload ядра".to_string(),
            evidence: json!({
                "desired": live.desired_config_digest,
                "applied": applied_digest,
            }),
            ..Default::default()
        });
    }

    // 1c. Quarantined / isolated settings reported at startup/reload (`section-errors.json`)
    let section_errors = crate::core_mgr::CoreManager::read_section_errors();
    if !section_errors.is_empty() {
        let keys: Vec<String> = section_errors.keys().cloned().collect();
        let summary_lines: Vec<String> = section_errors
            .iter()
            .take(5)
            .map(|(k, v)| format!("[{k}] {v}"))
            .collect();
        let severity = if section_errors.contains_key("_core_runtime") {
            "critical"
        } else {
            "warning"
        };
        findings.push(DoctorFinding {
            id: "config_quarantine".to_string(),
            severity: severity.to_string(),
            subsystem: "config_quarantine".to_string(),
            title: if en {
                format!(
                    "Faulty configuration settings were isolated ({})",
                    section_errors.len()
                )
            } else {
                format!(
                    "Обнаружены и изолированы проблемные настройки ({})",
                    section_errors.len()
                )
            },
            detail: summary_lines.join(" | "),
            quick_fix_id: "hot_reload_core".to_string(),
            quick_fix_label: if en {
                "Re-apply configuration"
            } else {
                "Повторно применить конфигурацию"
            }
            .to_string(),
            evidence: json!({
                "count": section_errors.len(),
                "keys": keys,
                "errors": section_errors,
            }),
            ..Default::default()
        });
    }

    // 2. WAN reachability (real TCP connect check state, never hardcoded)
    if !live.wan_healthy && (live.wan_fail_streak > 0 || live.wan_probe_ms > 0) {
        findings.push(DoctorFinding {
            id: "wan_down".to_string(),
            severity: "critical".to_string(),
            subsystem: "wan".to_string(),
            title: "Внешний канал WAN недоступен".to_string(),
            detail: format!(
                "Прямые TCP-пробы до внешних шлюзов не проходят (серия отказов: {}).",
                live.wan_fail_streak
            ),
            quick_fix_id: "fix_wan_interface".to_string(),
            quick_fix_label: "Проверить шлюз WAN".to_string(),
            evidence: json!({ "fail_streak": live.wan_fail_streak, "probe_ms": live.wan_probe_ms }),
            ..Default::default()
        });
    }

    // 3. System clock sanity check (critical for TLS 1.3 & REALITY)
    if unix_now_secs() < 1_700_000_000 {
        findings.push(DoctorFinding {
            id: "clock_skew".to_string(),
            severity: "critical".to_string(),
            subsystem: "time".to_string(),
            title: "Системное время роутера сбито".to_string(),
            detail: "Некорректные часы нарушают проверку сертификатов TLS 1.3 и VLESS REALITY."
                .to_string(),
            quick_fix_id: "fix_system_time".to_string(),
            quick_fix_label: "Синхронизировать NTP".to_string(),
            ..Default::default()
        });
    }

    // 4. nftables TProxy table check
    if proxy_mode == "tproxy" && !live.nft_table_active {
        findings.push(DoctorFinding {
            id: "nft_missing".to_string(),
            severity: "warning".to_string(),
            subsystem: "nftables".to_string(),
            title: if en {
                "nftables table inet TachyonTable is inactive"
            } else {
                "Таблица nftables inet TachyonTable не активна"
            }
            .to_string(),
            detail: if en {
                "Transparent TProxy interception rules are not loaded in the Linux kernel."
            } else {
                "Правила перехвата TProxy не загружены в ядро Linux."
            }
            .to_string(),
            quick_fix_id: "reconcile_nftables".to_string(),
            quick_fix_label: if en {
                "Restore network stack"
            } else {
                "Восстановить сетевой стек"
            }
            .to_string(),
            ..Default::default()
        });
    }

    // 5. DNS pipeline checks
    if bootstrap_dns_empty {
        findings.push(DoctorFinding {
            id: "bootstrap_dns_empty".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: if en {
                "Bootstrap DNS is not configured"
            } else {
                "Не задан Bootstrap DNS"
            }
            .to_string(),
            detail: if en {
                "Direct Bootstrap DNS is required to resolve proxy node domains and DoH endpoints."
            } else {
                "Для разрешения доменов узлов и DoH требуется Bootstrap DNS."
            }
            .to_string(),
            quick_fix_id: "fix_bootstrap_dns".to_string(),
            quick_fix_label: if en {
                "Reset Bootstrap DNS"
            } else {
                "Сбросить Bootstrap DNS"
            }
            .to_string(),
            ..Default::default()
        });
    }

    if live.core_running && !live.dns_healthy && live.dns_fail_streak > 0 {
        findings.push(DoctorFinding {
            id: "dns_unhealthy".to_string(),
            severity: "critical".to_string(),
            subsystem: "dns".to_string(),
            title: "Локальный DNS-резолвер 127.0.0.42:53 не отвечает корректно".to_string(),
            detail: format!(
                "UDP A-проба к FakeIP/DNS ядра завершается таймаутом или SERVFAIL (отказов подряд: {}).",
                live.dns_fail_streak
            ),
            quick_fix_id: "flush_core_dns".to_string(),
            quick_fix_label: "Сбросить кэш и апстримы DNS".to_string(),
            evidence: json!({ "dns_probe_ms": live.dns_probe_ms, "fail_streak": live.dns_fail_streak }),
            ..Default::default()
        });
    }

    let dns_up_err = health_val
        .as_ref()
        .and_then(|h| h.pointer("/dns/servers"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|s| s.get("errors_total").and_then(Value::as_u64).unwrap_or(0))
                .sum::<u64>()
        })
        .unwrap_or(live.dns_upstream_errors);
    if dns_up_err >= 5 {
        findings.push(DoctorFinding {
            id: "dns_upstream_errors".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: format!("Ошибки и таймауты DNS-апстримов ({dns_up_err})"),
            detail: "Запросы к настроенным DNS-апстримам завершаются сбоем или SERVFAIL."
                .to_string(),
            quick_fix_id: "switch_to_doh".to_string(),
            quick_fix_label: "Переключить на DoH".to_string(),
            evidence: json!({ "dns_upstream_errors": dns_up_err }),
            ..Default::default()
        });
    }

    let (fip_used, fip_cap, fip_evictions) = (
        health_val
            .as_ref()
            .and_then(|h| h.pointer("/dns/fakeip/v4_used"))
            .and_then(Value::as_u64)
            .unwrap_or(live.fakeip_v4_used),
        health_val
            .as_ref()
            .and_then(|h| h.pointer("/dns/fakeip/v4_cap"))
            .and_then(Value::as_u64)
            .unwrap_or(live.fakeip_v4_cap),
        health_val
            .as_ref()
            .and_then(|h| h.pointer("/dns/fakeip/evictions"))
            .and_then(Value::as_u64)
            .unwrap_or(live.fakeip_evictions),
    );
    if (fip_cap > 0 && fip_used.saturating_mul(100) / fip_cap >= 85) || fip_evictions > 20 {
        findings.push(DoctorFinding {
            id: "fakeip_saturation".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: format!(
                "Пул FakeIP перегружен ({fip_used}/{fip_cap}, вытеснений: {fip_evictions})"
            ),
            detail: "Частые вытеснения из FakeIP LRU нарушают маршрутизацию открытых сессий."
                .to_string(),
            quick_fix_id: "trim_core_memory".to_string(),
            quick_fix_label: "Очистить кэши ядра".to_string(),
            evidence: json!({ "used": fip_used, "cap": fip_cap, "evictions": fip_evictions }),
            ..Default::default()
        });
    }

    // 6. Active routing sections & local .trs rule-set check
    if enabled_sections == 0 {
        findings.push(DoctorFinding {
            id: "no_active_sections".to_string(),
            severity: "info".to_string(),
            subsystem: "routing".to_string(),
            title: if en {
                "No active routing sections"
            } else {
                "Нет активных секций маршрутизации"
            }
            .to_string(),
            detail: if en {
                "All traffic is currently routed directly."
            } else {
                "Весь трафик сейчас направляется напрямую (direct)."
            }
            .to_string(),
            quick_fix_id: "enable_default_desync".to_string(),
            quick_fix_label: if en {
                "Enable sections"
            } else {
                "Включить секции"
            }
            .to_string(),
            ..Default::default()
        });
    }

    // 7. System & core resources: RAM, pressure level, FD usage, UDP NAT, inbound cap
    if sys.mem_total_bytes > 0 {
        let avail_bytes = sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes);
        let free_pct = (avail_bytes * 100) / sys.mem_total_bytes;
        if free_pct < 12 {
            findings.push(DoctorFinding {
                id: "low_memory".to_string(),
                severity: "warning".to_string(),
                subsystem: "memory".to_string(),
                title: if en {
                    format!("Low free RAM ({free_pct}%)")
                } else {
                    format!("Мало свободной памяти ОЗУ ({free_pct}%)")
                },
                detail: if en {
                    "Consider trimming core memory buffers or lowering cache load."
                } else {
                    "Рекомендуется сжать буферы памяти ядра или снизить нагрузку кэшей."
                }
                .to_string(),
                quick_fix_id: "trim_core_memory".to_string(),
                quick_fix_label: if en {
                    "Trim core memory"
                } else {
                    "Сжать буферы памяти"
                }
                .to_string(),
                ..Default::default()
            });
        }
    }

    let pressure = health_val
        .as_ref()
        .and_then(|h| h.pointer("/memory/pressure_level"))
        .and_then(Value::as_str)
        .unwrap_or(&live.core_pressure_level);
    if pressure == "critical" || pressure == "elevated" {
        findings.push(DoctorFinding {
            id: "core_memory_pressure".to_string(),
            severity: if pressure == "critical" {
                "critical"
            } else {
                "warning"
            }
            .to_string(),
            subsystem: "memory".to_string(),
            title: if en {
                format!("Memory pressure inside tachyon-core: {pressure}")
            } else {
                format!("Давление памяти внутри tachyon-core: {pressure}")
            },
            detail: if en {
                "Core is approaching its RSS limit; buffer pools and caches need trimming."
            } else {
                "Ядро приблизилось к лимиту RSS; активные пулы буферов и кэш требуют очистки."
            }
            .to_string(),
            quick_fix_id: "trim_core_memory".to_string(),
            quick_fix_label: if en {
                "Trim core memory"
            } else {
                "Сжать буферы памяти ядра"
            }
            .to_string(),
            ..Default::default()
        });
    }

    let (fd_open, fd_limit) = (
        health_val
            .as_ref()
            .and_then(|h| h.pointer("/fds/open"))
            .and_then(Value::as_u64)
            .unwrap_or(live.core_fd_open),
        health_val
            .as_ref()
            .and_then(|h| h.pointer("/fds/soft_limit"))
            .and_then(Value::as_u64)
            .unwrap_or(live.core_fd_limit),
    );
    if fd_limit > 0 && fd_open.saturating_mul(100) / fd_limit >= 80 {
        findings.push(DoctorFinding {
            id: "fd_exhaustion".to_string(),
            severity: "critical".to_string(),
            subsystem: "resources".to_string(),
            title: format!("Исчерпание файловых дескрипторов ({fd_open}/{fd_limit})"),
            detail: "Необходимо закрыть зависшие сессии или перезапустить процесс.".to_string(),
            quick_fix_id: "flush_conntrack".to_string(),
            quick_fix_label: "Сбросить зависшие сессии".to_string(),
            evidence: json!({ "open": fd_open, "soft_limit": fd_limit }),
            ..Default::default()
        });
    }

    let nat_evictions = health_val
        .as_ref()
        .and_then(|h| h.pointer("/udp_nat/evictions_total"))
        .and_then(Value::as_u64)
        .unwrap_or(live.udp_nat_evictions);
    let cap_drops = health_val
        .as_ref()
        .and_then(|h| h.pointer("/connections/inbound_cap_drops"))
        .and_then(Value::as_u64)
        .unwrap_or(live.core_inbound_cap_drops);
    if nat_evictions > 0 || cap_drops > 0 {
        findings.push(DoctorFinding {
            id: "nat_or_cap_pressure".to_string(),
            severity: "warning".to_string(),
            subsystem: "resources".to_string(),
            title: format!(
                "Вытеснения UDP NAT ({nat_evictions}) или отказы лимита входящих ({cap_drops})"
            ),
            detail: "Таблица потоков достигла предела ёмкости.".to_string(),
            quick_fix_id: "trim_core_memory".to_string(),
            quick_fix_label: "Сбросить старые бакеты и буферы".to_string(),
            evidence: json!({ "udp_nat_evictions": nat_evictions, "inbound_cap_drops": cap_drops }),
            ..Default::default()
        });
    }

    // 8. Outbound dial errors (DialErrorClass), WireGuard stale handshake, failover & anomalies
    if let Some(out_arr) = health_val
        .as_ref()
        .and_then(|h| h.get("outbounds"))
        .and_then(Value::as_array)
    {
        for o in out_arr {
            let tag = o.get("tag").and_then(Value::as_str).unwrap_or("");
            let err_detail = o
                .get("last_err_detail")
                .and_then(Value::as_str)
                .unwrap_or("");
            if tag.is_empty()
                || is_builtin_non_proxy_outbound(tag)
                || err_detail
                    .trim()
                    .eq_ignore_ascii_case("blocked by outbound")
            {
                continue;
            }
            let dial_ok = o.get("dial_ok").and_then(Value::as_u64).unwrap_or(0);
            let dial_fail = o.get("dial_fail").and_then(Value::as_u64).unwrap_or(0);
            let err_class = o
                .get("last_err_class")
                .and_then(Value::as_str)
                .unwrap_or("");
            if dial_fail >= 3 && dial_fail > dial_ok {
                let suggested_fix = match err_class {
                    "dns_fail" => "flush_core_dns".to_string(),
                    "quic_timeout" => format!("reset_outbound_pool:{tag}"),
                    _ => format!("reset_outbound_pool:{tag}"),
                };
                findings.push(DoctorFinding {
                    id: format!("outbound_err_{err_class}_{tag}"),
                    severity: "warning".to_string(),
                    subsystem: "outbounds".to_string(),
                    title: if en {
                        format!("Outbound \"{tag}\" dial failures ({err_class}: {dial_fail})")
                    } else {
                        format!("Сбои подключения узла «{tag}» ({err_class}: {dial_fail} отказов)")
                    },
                    detail: if err_detail.is_empty() {
                        if en {
                            "High dial failure ratio on this outbound.".to_string()
                        } else {
                            "Высокая доля отказов при установке соединения.".to_string()
                        }
                    } else {
                        err_detail.to_string()
                    },
                    quick_fix_id: suggested_fix,
                    quick_fix_label: if en {
                        format!("Reset pool \"{tag}\"")
                    } else {
                        format!("Сбросить пул «{tag}»")
                    },
                    evidence: json!({ "tag": tag, "dial_ok": dial_ok, "dial_fail": dial_fail, "err_class": err_class }),
                    ..Default::default()
                });
            }
            if let Some(age) = o.get("wg_last_handshake_age_secs").and_then(Value::as_u64)
                && age > 180
            {
                findings.push(DoctorFinding {
                    id: format!("outbound_wg_stale_{tag}"),
                    severity: "warning".to_string(),
                    subsystem: "outbounds".to_string(),
                    title: if en {
                        format!("WireGuard \"{tag}\": stale handshake ({age}s)")
                    } else {
                        format!("WireGuard «{tag}»: устаревший handshake ({age} с)")
                    },
                    detail: if en {
                        "Tunnel has not renewed keys for over 3 minutes; socket rebind recommended."
                    } else {
                        "Туннель не обновлял ключи более 3 минут; рекомендуется rebind сокета."
                    }
                    .to_string(),
                    quick_fix_id: format!("reset_outbound_pool:{tag}"),
                    quick_fix_label: if en {
                        format!("Rebind WireGuard \"{tag}\"")
                    } else {
                        format!("Rebind WireGuard «{tag}»")
                    },
                    evidence: json!({ "tag": tag, "handshake_age_secs": age }),
                    ..Default::default()
                });
            }
        }
    }

    if has_true_failover_backup(failover_val.as_ref()) {
        findings.push(DoctorFinding {
            id: "failover_on_backup".to_string(),
            severity: "warning".to_string(),
            subsystem: "failover".to_string(),
            title: "Группа балансировки переключена на резервный узел".to_string(),
            detail: "Основной узел недоступен или показал высокий RTT.".to_string(),
            quick_fix_id: "restore_primary_failover".to_string(),
            quick_fix_label: "Проверить и вернуть основной узел".to_string(),
            ..Default::default()
        });
    }

    let anom_hosts = anomalies_val
        .as_ref()
        .and_then(|a| a.get("hosts"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !anom_hosts.is_empty() {
        let top_host = anom_hosts[0]
            .get("host")
            .and_then(Value::as_str)
            .unwrap_or("");
        findings.push(DoctorFinding {
            id: "anomalies_hosts".to_string(),
            severity: "info".to_string(),
            subsystem: "outbounds".to_string(),
            title: format!(
                "Аномалии соединений на {} хостах (например, {})",
                anom_hosts.len(),
                top_host
            ),
            detail: "Фиксируются повторяющиеся отказы соединения в 5-минутном окне.".to_string(),
            quick_fix_id: "capture_blackbox".to_string(),
            quick_fix_label: "Снять дамп Blackbox".to_string(),
            evidence: json!({ "count": anom_hosts.len(), "top": anom_hosts.first() }),
            ..Default::default()
        });
    }

    // 9. Outbound sources empty cache check
    for (src_id, src_name) in empty_subs {
        findings.push(DoctorFinding {
            id: format!("sub_empty_{src_id}"),
            severity: "warning".to_string(),
            subsystem: "subscriptions".to_string(),
            title: format!("Подписка «{src_name}» не содержит кэшированных узлов"),
            detail: "Обновите подписку для загрузки актуального списка узлов.".to_string(),
            quick_fix_id: "update_subscriptions".to_string(),
            quick_fix_label: "Обновить подписки".to_string(),
            ..Default::default()
        });
    }

    // 10. Firewall flow offloading compatibility check (conflict only with SQM, or missing fw4 guard)
    let (sw_offload, hw_offload) = read_firewall_flow_offloading();
    let offload_any = sw_offload || hw_offload;
    let flow_offload_sqm_conflict = offload_any && smart_queue;
    let guard_ok = (flow_offload_guard_installed() && fw4_forward_order_ok)
        || (cfg!(windows) && std::env::var("TACHYON_FW4_INCLUDE_ROOT").is_err());
    let flow_offload_guard_missing = offload_any
        && !smart_queue
        && matches!(proxy_mode.as_str(), "tproxy" | "redirect" | "tun")
        && !guard_ok;
    if flow_offload_sqm_conflict {
        findings.push(DoctorFinding {
            id: "flow_offloading_conflict".to_string(),
            severity: "warning".to_string(),
            subsystem: "firewall".to_string(),
            title: if en {
                "Firewall Flow Offloading is enabled (conflicts with SQM)"
            } else {
                "Включён Flow Offloading в Firewall (конфликт с SQM)"
            }
            .to_string(),
            detail: if en {
                "Hardware/software Flow Offloading bypasses SQM/CAKE traffic shaping queues."
            } else {
                "Аппаратный/программный Flow Offloading обходит очереди SQM/CAKE."
            }
            .to_string(),
            quick_fix_id: "disable_flow_offloading".to_string(),
            quick_fix_label: if en {
                "Disable Flow Offloading"
            } else {
                "Отключить Flow Offloading"
            }
            .to_string(),
            ..Default::default()
        });
    } else if flow_offload_guard_missing {
        findings.push(DoctorFinding {
            id: "flow_offloading_guard_missing".to_string(),
            severity: "warning".to_string(),
            subsystem: "firewall".to_string(),
            title: if en {
                "Flow Offloading guard rule is missing in fw4 include"
            } else {
                "Отсутствует защитное правило Flow Offloading для fw4"
            }
            .to_string(),
            detail: if en {
                "Install 10-tachyon-offload.nft so proxied/DNS flows bypass @ft while direct LAN/WAN traffic stays offloaded."
            } else {
                "Установите 10-tachyon-offload.nft, чтобы трафик Tachyon/DNS исключался из @ft при сохранении ускорения прямого трафика."
            }
            .to_string(),
            quick_fix_id: "sync_flow_offload_guard".to_string(),
            quick_fix_label: if en {
                "Install Flow Offloading guard"
            } else {
                "Установить защиту Flow Offloading"
            }
            .to_string(),
            ..Default::default()
        });
    }

    // 11. odhcpd IPv6 DNS check
    let (odhcpd_ok, odhcpd_detail) = if cfg!(windows) {
        (
            true,
            if en {
                "Windows test mode: odhcpd skipped"
            } else {
                "Windows test mode: odhcpd пропущен"
            }
            .to_string(),
        )
    } else {
        evaluate_odhcpd_ipv6_dns_lang(dhcp_raw, odhcpd_present, en)
    };
    if !odhcpd_ok {
        findings.push(DoctorFinding {
            id: "odhcpd_ipv6_dns_missing".to_string(),
            severity: "warning".to_string(),
            subsystem: "dhcp".to_string(),
            title: if en {
                "IPv6 DNS is not configured in odhcpd for LAN"
            } else {
                "Не настроен IPv6 DNS в odhcpd для LAN"
            }
            .to_string(),
            detail: odhcpd_detail.clone(),
            quick_fix_id: "heal_network_stack".to_string(),
            quick_fix_label: if en {
                "Configure IPv6/DNS stack"
            } else {
                "Настроить стек IPv6/DNS"
            }
            .to_string(),
            ..Default::default()
        });
    }

    let resolv_ok = if cfg!(windows) {
        true
    } else {
        std::fs::read_to_string("/etc/resolv.conf")
            .map(|raw| {
                let has_ns = raw.lines().any(|l| {
                    let t = l.trim();
                    !t.is_empty() && !t.starts_with('#') && t.starts_with("nameserver")
                });
                if !has_ns {
                    return false;
                }
                if !d.settings.dont_touch_dhcp {
                    raw.contains("127.0.0.1") || raw.contains("::1")
                } else {
                    true
                }
            })
            .unwrap_or(false)
    };
    if !resolv_ok {
        findings.push(DoctorFinding {
            id: "resolv_conf_invalid".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: if en {
                "Invalid system /etc/resolv.conf"
            } else {
                "Некорректный системный /etc/resolv.conf"
            }
            .to_string(),
            detail: if en {
                "Router host resolver does not point to local DNS (127.0.0.1) or is missing."
            } else {
                "Резолвер хоста роутера не указывает на локальный DNS (127.0.0.1) или отсутствует."
            }
            .to_string(),
            quick_fix_id: "fix_resolv_symlink".to_string(),
            quick_fix_label: if en {
                "Repair symlink"
            } else {
                "Починить симлинк"
            }
            .to_string(),
            ..Default::default()
        });
    }

    let dnsmasq_cascade_ok = if cfg!(windows) || d.settings.dont_touch_dhcp {
        live.dns_healthy
    } else {
        let dropin_present = net_stack::collect_dnsmasq_conf_dirs_in(std::path::Path::new("/tmp"))
            .into_iter()
            .any(|dir| dir.join("tachyon.conf").exists());
        let dnsmasq_running = sys_info::find_running_process_by_name("dnsmasq").is_some();
        live.dns_healthy && dropin_present && dnsmasq_running
    };
    if !dnsmasq_cascade_ok && !cfg!(windows) {
        findings.push(DoctorFinding {
            id: "dnsmasq_cascade_broken".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: if en {
                "dnsmasq -> 127.0.0.42#53 cascade is broken"
            } else {
                "Нарушен каскад dnsmasq -> 127.0.0.42#53"
            }
            .to_string(),
            detail: if en {
                "Drop-in /tmp/dnsmasq*.d/tachyon.conf is missing or dnsmasq is stopped."
            } else {
                "Отсутствует drop-in /tmp/dnsmasq*.d/tachyon.conf или остановлен dnsmasq."
            }
            .to_string(),
            quick_fix_id: "fix_dnsmasq".to_string(),
            quick_fix_label: if en {
                "Restart dnsmasq"
            } else {
                "Перезапустить dnsmasq"
            }
            .to_string(),
            ..Default::default()
        });
    }

    let wan6_doc = crate::store::probe_wan6_runtime_state();
    let ipv6_state_doc =
        crate::store::resolve_effective_ipv6_state(&d.settings, wan6_doc.wan6_available);
    let eff_dns_doc = crate::store::effective_dns_strategy(&d.settings, ipv6_state_doc);
    let core_cfg_doc =
        crate::core_mgr::CoreManager::effective_core_config_path_for(state, &d.settings);
    if live.core_running
        && d.settings.fakeip_enabled
        && ipv6_state_doc.is_active()
        && eff_dns_doc != "ipv4_only"
        && !crate::core_mgr::CoreManager::core_config_ipv6_matches(&core_cfg_doc, d, ipv6_state_doc)
    {
        findings.push(DoctorFinding {
            id: "fakeip6_config_drift".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: if en {
                "FakeIPv6 core config is out of sync with active IPv6 state"
            } else {
                "FakeIPv6 в конфиге ядра не синхронизирован с активным IPv6"
            }
            .to_string(),
            detail: if en {
                format!(
                    "{} is missing the current inet6_range for FakeIPv6 while IPv6 state is {}.",
                    core_cfg_doc.display(),
                    ipv6_state_doc.as_str()
                )
            } else {
                format!(
                    "В {} отсутствует актуальный inet6_range для FakeIPv6 при активном состоянии IPv6 ({}).",
                    core_cfg_doc.display(),
                    ipv6_state_doc.as_str()
                )
            },
            quick_fix_id: "doctor_fix".to_string(),
            quick_fix_label: if en {
                "Auto-repair config and IPv6 (doctor --fix)"
            } else {
                "Автовосстановление конфига и IPv6 (doctor --fix)"
            }
            .to_string(),
            ..Default::default()
        });
    }

    let root_causes = apply_causal_suppression(&mut findings);
    let active_findings_count = findings
        .iter()
        .filter(|f| f.suppressed_by.is_none())
        .count();
    let checks_passed = checks_total.saturating_sub(active_findings_count.min(checks_total));
    let healthy = !findings
        .iter()
        .any(|f| f.suppressed_by.is_none() && f.severity == "critical");

    let node_status = |match_ids: &[&str], sub: &str| -> (&'static str, bool) {
        let matching: Vec<&DoctorFinding> = findings
            .iter()
            .filter(|f| f.subsystem == sub || match_ids.iter().any(|p| f.id.starts_with(p)))
            .collect();
        if matching.is_empty() {
            return ("ok", false);
        }
        if matching.iter().all(|f| f.suppressed_by.is_some()) {
            return ("suppressed", false);
        }
        let is_root = matching.iter().any(|f| f.root_cause);
        if matching
            .iter()
            .any(|f| f.suppressed_by.is_none() && f.severity == "critical")
        {
            ("err", is_root)
        } else {
            ("warn", is_root)
        }
    };

    let pipeline_specs = [
        (
            "wan",
            "WAN",
            &["wan_down"][..],
            "wan",
            format!("{} мс", live.wan_probe_ms),
        ),
        (
            "clock",
            "Часы",
            &["clock_skew"][..],
            "time",
            "NTP sync".to_string(),
        ),
        (
            "binary",
            "Бинарник",
            &["core_binary_corrupt"][..],
            "binary",
            if bin_check_res.is_ok() {
                "ELF/PE OK".into()
            } else {
                "Повреждён".into()
            },
        ),
        (
            "core_process",
            "Ядро",
            &["core_stopped"][..],
            "core",
            if live.core_running {
                format!("PID {}", live.core_pid.unwrap_or(0))
            } else {
                "Остановлено".into()
            },
        ),
        (
            "config_sync",
            "Конфиг",
            &["config_drift"][..],
            "config_sync",
            if config_drift {
                "Drift".into()
            } else {
                "Синхронизирован".into()
            },
        ),
        (
            "nftables",
            "nftables",
            &["nft_missing", "flow_offloading"][..],
            "nftables",
            if live.nft_table_active {
                "TProxy :1602".into()
            } else {
                proxy_mode.clone()
            },
        ),
        (
            "dns_fakeip",
            "DNS/FakeIP",
            &["dns_", "fakeip_", "bootstrap_dns"][..],
            "dns",
            format!("{} мс · {fip_used}/{fip_cap}", live.dns_probe_ms),
        ),
        (
            "outbounds",
            "Узлы",
            &["outbound_", "failover_", "anomalies_"][..],
            "outbounds",
            format!(
                "Ошибок: {}",
                flight_val
                    .as_ref()
                    .and_then(|v| v.get("count"))
                    .and_then(Value::as_u64)
                    .unwrap_or(live.recent_flight_failures as u64)
            ),
        ),
        (
            "resources",
            "Ресурсы",
            &[
                "low_memory",
                "core_memory_pressure",
                "fd_exhaustion",
                "nat_or_cap",
            ][..],
            "resources",
            format!(
                "{} · FD {fd_open}/{fd_limit}",
                if pressure.is_empty() {
                    "normal"
                } else {
                    pressure
                }
            ),
        ),
    ];
    let pipeline_nodes: Vec<Value> = pipeline_specs
        .into_iter()
        .map(|(id, label, prefixes, sub, detail)| {
            let (st, rc) = node_status(prefixes, sub);
            json!({
                "id": id,
                "label": label,
                "status": st,
                "detail": detail,
                "root_cause": rc,
            })
        })
        .collect();

    let summary = if findings.is_empty() {
        if en {
            format!("All {checks_total} router and tachyon-core subsystems operate normally")
        } else {
            format!("Все {checks_total} подсистем роутера и ядра tachyon-core работают штатно")
        }
    } else if !root_causes.is_empty() {
        if en {
            format!(
                "Active findings: {active_findings_count} (total {}), root cause: {}",
                findings.len(),
                root_causes[0]
            )
        } else {
            format!(
                "Активных замечаний: {active_findings_count} (всего {}), корневая причина: {}",
                findings.len(),
                root_causes[0]
            )
        }
    } else if en {
        format!("Checked subsystems: {checks_total}, findings: {active_findings_count}")
    } else {
        format!("Проверено подсистем: {checks_total}, замечаний: {active_findings_count}")
    };

    let fakeip_v4_doc = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        d.settings.fakeip_inet4_range.trim()
    };
    let wan_status = if !live.wan_healthy && live.wan_fail_streak > 0 {
        "err"
    } else {
        "ok"
    };
    let dns_status = if live.core_running && !live.dns_healthy && live.dns_fail_streak > 0 {
        "err"
    } else if dns_up_err >= 5 || (fip_cap > 0 && fip_used * 100 / fip_cap >= 85) {
        "warn"
    } else {
        "ok"
    };
    let outbounds_bad = findings.iter().any(|f| {
        f.suppressed_by.is_none()
            && (f.id.starts_with("outbound_") || f.id.starts_with("sub_empty_"))
    });
    let resources_bad = findings.iter().any(|f| {
        matches!(
            f.id.as_str(),
            "low_memory" | "core_memory_pressure" | "fd_exhaustion" | "nat_or_cap_pressure"
        )
    });
    let failover_backup = has_true_failover_backup(failover_val.as_ref());

    #[inline(never)]
    fn make_sub(
        name: impl Into<String>,
        status: &str,
        detail: impl Into<String>,
        fix_id: &str,
        fix_label: &str,
    ) -> Value {
        json!({
            "name": name.into(),
            "status": status,
            "detail": detail.into(),
            "fix_id": fix_id,
            "fix_label": fix_label,
        })
    }

    let mut subsystems = Vec::with_capacity(16);
    subsystems.push(make_sub(
        if en {
            "1. tachyon-core Engine & Binary"
        } else {
            "1. Ядро и бинарник tachyon-core"
        },
        if bin_check_res.is_err() {
            "err"
        } else if live.core_running && !config_drift {
            "ok"
        } else {
            "warn"
        },
        format!(
            "PID {} · RSS {} KB · reloads {}",
            live.core_pid.unwrap_or(0),
            live.core_rss_bytes / 1024,
            live.core_reload_count
        ),
        if bin_check_res.is_err() {
            "rollback_core_binary"
        } else if config_drift {
            "hot_reload_core"
        } else {
            "restart_core"
        },
        if bin_check_res.is_err() {
            if en {
                "Rollback binary"
            } else {
                "Откатить бинарник"
            }
        } else if config_drift {
            "Hot-Reload"
        } else if en {
            "Restart"
        } else {
            "Перезапустить"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "2. nftables TProxy Table"
        } else {
            "2. Таблица nftables TProxy"
        },
        if proxy_mode == "tproxy" && !live.nft_table_active {
            "err"
        } else {
            "ok"
        },
        "inet TachyonTable :1602",
        "reconcile_nftables",
        if en {
            "Restore stack"
        } else {
            "Восстановить стек"
        },
    ));
    subsystems.push(make_sub(
        if fakeip_enabled {
            if en {
                format!("3. DNS & FakeIP ({fakeip_v4_doc})")
            } else {
                format!("3. DNS и FakeIP ({fakeip_v4_doc})")
            }
        } else {
            "3. DNS (RealIP)".to_string()
        },
        dns_status,
        if en {
            format!(
                "127.0.0.42:53 · {} ms · FakeIP {fip_used}/{fip_cap} (evictions {fip_evictions})",
                live.dns_probe_ms
            )
        } else {
            format!(
                "127.0.0.42:53 · {} мс · FakeIP {fip_used}/{fip_cap} (вытеснений {fip_evictions})",
                live.dns_probe_ms
            )
        },
        "flush_core_dns",
        if en {
            "Flush core DNS"
        } else {
            "Сбросить DNS ядра"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "4. WAN Uplink"
        } else {
            "4. Внешний канал WAN"
        },
        wan_status,
        if en {
            format!(
                "TCP probe: {} ms (fail streak: {})",
                live.wan_probe_ms, live.wan_fail_streak
            )
        } else {
            format!(
                "TCP проба: {} мс (отказов подряд: {})",
                live.wan_probe_ms, live.wan_fail_streak
            )
        },
        "fix_wan_interface",
        if en {
            "Check gateway"
        } else {
            "Проверить шлюз"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "5. Routing Sections"
        } else {
            "5. Секции маршрутизации"
        },
        if enabled_sections > 0 { "ok" } else { "warn" },
        if en {
            format!("Active {enabled_sections} of {total_sections}")
        } else {
            format!("Активно {enabled_sections} из {total_sections}")
        },
        "enable_default_desync",
        if en {
            "Enable sections"
        } else {
            "Включить секции"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "6. Outbounds & Sources (DialErrorClass)"
        } else {
            "6. Узлы и Источники (DialErrorClass)"
        },
        if outbounds_bad { "warn" } else { "ok" },
        if en {
            format!("Sources: {sources_len} · anomalies: {}", anom_hosts.len())
        } else {
            format!("Источников: {sources_len} · аномалий: {}", anom_hosts.len())
        },
        "reset_outbound_pool",
        if en {
            "Reset outbound pool"
        } else {
            "Сбросить пул узлов"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "7. Balancers & Failover"
        } else {
            "7. Балансировщики и Failover"
        },
        if failover_backup { "warn" } else { "ok" },
        if failover_backup {
            if en {
                "Backup node active".to_string()
            } else {
                "Активен резервный узел".to_string()
            }
        } else if en {
            format!("Configured: {balancers_len}")
        } else {
            format!("Алгоритмов: {balancers_len}")
        },
        "restore_primary_failover",
        if en {
            "Restore primary"
        } else {
            "Вернуть primary"
        },
    ));
    subsystems.push(make_sub(
        if en { "8. Inbound Servers & NAT" } else { "8. Входящие серверы и NAT" },
        if nat_evictions > 0 || cap_drops > 0 { "warn" } else { "ok" },
        if en {
            format!(
                "Active {enabled_servers}/{total_servers} · UDP NAT: {} (evictions {nat_evictions}) · cap drops {cap_drops}",
                live.udp_nat_active
            )
        } else {
            format!(
                "Активно {enabled_servers}/{total_servers} · UDP NAT: {} (вытеснений {nat_evictions}) · cap drops {cap_drops}",
                live.udp_nat_active
            )
        },
        "trim_core_memory",
        if en { "Trim stale NAT" } else { "Сбросить старые NAT" },
    ));
    subsystems.push(make_sub(
        if en {
            "9. RAM, FD & Buffers"
        } else {
            "9. Память ОЗУ, FD и буферы"
        },
        if resources_bad { "warn" } else { "ok" },
        if en {
            format!(
                "Free {} MB · {pressure} · FD {fd_open}/{fd_limit}",
                sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes) / 1048576
            )
        } else {
            format!(
                "Свободно {} МБ · {pressure} · FD {fd_open}/{fd_limit}",
                sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes) / 1048576
            )
        },
        "trim_core_memory",
        if en {
            "Trim memory"
        } else {
            "Сжать память"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "10. NTP System Clock"
        } else {
            "10. Системное время NTP"
        },
        if unix_now_secs() > 1_700_000_000 {
            "ok"
        } else {
            "err"
        },
        if en {
            "Synced for TLS 1.3 / REALITY"
        } else {
            "Синхронизировано для TLS 1.3 / REALITY"
        },
        "fix_system_time",
        if en {
            "Sync NTP"
        } else {
            "Синхронизировать NTP"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "11. Watchdog & LKG Snapshot"
        } else {
            "11. Watchdog и снимок LKG"
        },
        if !enable_watchdog || live.watchdog_restarts_10m > 0 {
            "warn"
        } else {
            "ok"
        },
        if en {
            format!(
                "{} · restarts 10m: {}",
                if live.watchdog_state.is_empty() {
                    "idle"
                } else {
                    &live.watchdog_state
                },
                live.watchdog_restarts_10m
            )
        } else {
            format!(
                "{} · рестартов за 10м: {}",
                if live.watchdog_state.is_empty() {
                    "idle"
                } else {
                    &live.watchdog_state
                },
                live.watchdog_restarts_10m
            )
        },
        "rollback_known_good",
        if en {
            "Rollback to LKG"
        } else {
            "Откат к LKG"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "12. NAND Guard, Blackbox & Security"
        } else {
            "12. NAND Guard, Blackbox и Безопасность"
        },
        "ok",
        if en {
            format!(
                "Blackbox: {} · incidents: {} · honeypot: {}",
                live.blackboxes.len(),
                live.incidents.len(),
                live.honeypot_hits.len()
            )
        } else {
            format!(
                "Blackbox: {} · инцидентов: {} · honeypot: {}",
                live.blackboxes.len(),
                live.incidents.len(),
                live.honeypot_hits.len()
            )
        },
        "capture_blackbox",
        if en {
            "Capture Blackbox"
        } else {
            "Снять Blackbox"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "13. dnsmasq -> FakeIP Cascade"
        } else {
            "13. Каскад dnsmasq -> FakeIP"
        },
        if dnsmasq_cascade_ok { "ok" } else { "warn" },
        if dnsmasq_cascade_ok {
            "noresolv=1 · 127.0.0.42#53"
        } else if en {
            "dnsmasq/127.0.0.42#53 cascade issue"
        } else {
            "Проблема каскада dnsmasq/127.0.0.42#53"
        },
        "fix_dnsmasq",
        if en {
            "Restart dnsmasq"
        } else {
            "Перезапустить dnsmasq"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "14. System /etc/resolv.conf"
        } else {
            "14. Системный /etc/resolv.conf"
        },
        if resolv_ok { "ok" } else { "warn" },
        if en {
            "Router host resolver"
        } else {
            "Резолвер хоста роутера"
        },
        "fix_resolv_symlink",
        if en {
            "Repair symlink"
        } else {
            "Починить симлинк"
        },
    ));
    subsystems.push(make_sub(
        if en {
            "15. Firewall Conflicts (Flow Offloading)"
        } else {
            "15. Конфликты Firewall (Flow Offloading)"
        },
        if flow_offload_sqm_conflict || flow_offload_guard_missing {
            "warn"
        } else {
            "ok"
        },
        if flow_offload_sqm_conflict {
            if en {
                "Flow Offloading active with SQM"
            } else {
                "Обнаружен Flow Offloading при включённом SQM"
            }
        } else if flow_offload_guard_missing {
            if en {
                "Flow Offloading guard missing in fw4 include"
            } else {
                "Отсутствует правило исключения трафика Tachyon для Flow Offloading"
            }
        } else if offload_any {
            if en {
                "Flow Offloading active in compatible mode (Tachyon flows excluded from fw4)"
            } else {
                "Flow Offloading активен в совместимом режиме: трафик Tachyon исключён из flowtable fw4"
            }
        } else if en {
            "No conflicts with netfilter/TProxy detected"
        } else {
            "Конфликтов с netfilter/TProxy не обнаружено"
        },
        if flow_offload_guard_missing {
            "sync_flow_offload_guard"
        } else {
            "disable_flow_offloading"
        },
        if flow_offload_guard_missing {
            if en {
                "Install Flow Offloading guard"
            } else {
                "Установить защиту Flow Offloading"
            }
        } else if en {
            "Disable Flow Offloading"
        } else {
            "Отключить Flow Offloading"
        },
    ));
    subsystems.push(make_sub(
        "16. odhcpd IPv6 DNS",
        if odhcpd_ok { "ok" } else { "warn" },
        odhcpd_detail,
        "heal_network_stack",
        if en {
            "Configure IPv6/DNS stack"
        } else {
            "Настроить стек IPv6/DNS"
        },
    ));

    DoctorReport {
        healthy,
        timestamp: unix_now_secs(),
        checks_total,
        checks_passed,
        subsystems,
        findings,
        summary,
        pipeline_nodes,
        root_causes,
    }
}

async fn rollback_snapshot_boxed(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    prev: Box<RouterStoreData>,
) -> bool {
    if Box::pin(transaction::commit_transaction(state, *prev))
        .await
        .is_ok()
    {
        let _ = Box::pin(core.apply_or_reload()).await;
        true
    } else {
        false
    }
}

async fn commit_and_reload_boxed(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    reload: bool,
    mutate: impl FnOnce(&mut RouterStoreData),
) -> anyhow::Result<()> {
    let mut candidate = Box::new(state.data.read().await.clone());
    mutate(&mut candidate);
    Box::pin(transaction::commit_transaction(state, *candidate)).await?;
    if reload {
        let _ = Box::pin(core.apply_or_reload()).await;
    }
    Ok(())
}

#[inline(never)]
fn qf_core_start(
    core: &Arc<CoreManager>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(core.start())
}

#[inline(never)]
fn qf_core_stop(
    core: &Arc<CoreManager>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(core.stop())
}

#[inline(never)]
fn qf_core_reload(
    core: &Arc<CoreManager>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(core.apply_or_reload())
}

#[inline(never)]
fn qf_apply_net_stack(
    snap: &RouterStoreData,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(net_stack::apply_network_stack(snap))
}

#[inline(never)]
fn qf_commit_and_reload<'a>(
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    reload: bool,
    mutate: fn(&mut RouterStoreData),
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + 'a>> {
    Box::pin(commit_and_reload_boxed(state, core, reload, mutate))
}

#[inline(never)]
fn qf_refresh_subs(
    core: &Arc<CoreManager>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<usize>> + Send + '_>> {
    Box::pin(core.refresh_all_subscriptions())
}

#[inline(never)]
fn qf_component_action<'a>(
    core: &'a Arc<CoreManager>,
    comp: &'a str,
    act: &'a str,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Value> + Send + 'a>> {
    Box::pin(core.component_action(comp, act, None))
}

#[inline(never)]
fn qf_capture_blackbox<'a>(
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    reason: &'a str,
) -> std::pin::Pin<
    Box<
        dyn std::future::Future<Output = anyhow::Result<crate::store::BlackboxSummary>> + Send + 'a,
    >,
> {
    Box::pin(watchdog::capture_blackbox(state, core, reason))
}

#[inline(never)]
fn qf_commit_tx(
    state: &Arc<AppState>,
    data: Box<RouterStoreData>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<()>> + Send + '_>> {
    Box::pin(async move {
        transaction::commit_transaction(state, *data).await?;
        Ok(())
    })
}

#[inline(never)]
fn qf_check_updates(
    core: &Arc<CoreManager>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Value> + Send + '_>> {
    Box::pin(core.check_updates())
}

/// Execute any of the 25 automated Quick Fixes by ID.
fn is_builtin_non_proxy_outbound(tag: &str) -> bool {
    matches!(
        tag.trim().to_ascii_lowercase().as_str(),
        "block" | "block-out" | "reject" | "dns" | "dns-out"
    )
}

pub async fn apply_quick_fix(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    fix_id: &str,
) -> anyhow::Result<String> {
    if let Some(tag) = fix_id.strip_prefix("reset_outbound_pool:") {
        let tag = tag.trim();
        anyhow::ensure!(
            !tag.is_empty(),
            "Пустой тег outbound для reset_outbound_pool"
        );
        let res = core.reset_core_outbound(tag, true, None).await?;
        let kicked = core
            .kick_core_filtered(None, None, Some(tag), Some(30_000))
            .await
            .ok()
            .and_then(|v| v.get("closed").and_then(Value::as_u64))
            .unwrap_or(0);
        let closed = res
            .get("closed_sessions")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        return Ok(format!(
            "Пул узла '{tag}' сброшен (rebind/probe, закрыто сессий: {}, зависших: {kicked})",
            closed
        ));
    }

    match fix_id {
        "restart_core" | "start_core" | "start_tachyon_core" => {
            qf_core_start(core).await?;
            Ok("Ядро tachyon-core перезапущено и синхронизировано".to_string())
        }
        "hot_reload_core" => {
            qf_core_reload(core).await?;
            Ok("Конфигурация ядра обновлена через Hot-Reload".to_string())
        }
        "doctor_fix" => {
            if qf_core_reload(core).await.is_err() {
                let _ = qf_component_action(core, "lists", "update").await;
                qf_core_reload(core).await?;
            }
            Ok("Выполнено автовосстановление конфигурации, правил IPv6 и списков".to_string())
        }
        "heal_network_stack" | "rebuild_rules" | "reset_firewall" | "reconcile_nftables" => {
            let snap = Box::new(state.data.read().await.clone());
            qf_apply_net_stack(&snap).await?;
            state.live.write().await.nft_table_active = net_stack::check_nft_table_active().await;
            Ok("Сетевой стек (inet TachyonTable и ip rule) перестроен".to_string())
        }
        "fix_bootstrap_dns" => {
            qf_commit_and_reload(state, core, true, |c| {
                c.settings.bootstrap_dns_servers =
                    vec!["77.88.8.8".to_string(), "1.1.1.1".to_string()];
            })
            .await?;
            Ok("Bootstrap DNS сброшен на 77.88.8.8 / 1.1.1.1".to_string())
        }
        "switch_to_doh" => {
            qf_commit_and_reload(state, core, true, |c| {
                c.settings.dns_type = "doh".to_string();
                c.settings.dns_servers = vec![
                    "https://1.1.1.1/dns-query".to_string(),
                    "https://dns.google/dns-query".to_string(),
                ];
            })
            .await?;
            Ok("DNS переключён на защищённый DoH (Cloudflare + Google)".to_string())
        }
        "clear_dns_cache" | "restart_core_dns" | "restart_tachyon_core_dns" | "flush_core_dns" => {
            let mut msg_parts = Vec::new();
            match core.flush_core_dns("all").await {
                Ok(v) => {
                    let evicted = v.get("evicted_cache").and_then(Value::as_u64).unwrap_or(0);
                    msg_parts.push(format!(
                        "DNS-кэш и апстримы ядра очищены (записей: {evicted})"
                    ));
                }
                Err(e) => msg_parts.push(format!("Сброс DNS ядра не выполнен: {e}")),
            }
            if fix_id != "flush_core_dns" && !cfg!(windows) {
                let _ = Command::new("/etc/init.d/dnsmasq")
                    .arg("restart")
                    .status()
                    .await;
                msg_parts.push("dnsmasq перезапущен".to_string());
            }
            Ok(msg_parts.join("; "))
        }
        "fix_dnsmasq" => {
            if !cfg!(windows) {
                let _ = Command::new("/etc/init.d/dnsmasq")
                    .arg("restart")
                    .status()
                    .await;
            }
            Ok("Служба dnsmasq перезапущена".to_string())
        }
        "fix_resolv_symlink" => {
            if !cfg!(windows) {
                let target = if state.data.read().await.settings.dont_touch_dhcp
                    && std::path::Path::new("/tmp/resolv.conf.d/resolv.conf.auto").exists()
                {
                    "/tmp/resolv.conf.d/resolv.conf.auto"
                } else {
                    let local_resolv = std::path::Path::new("/tmp/resolv.conf");
                    let needs_local = std::fs::read_to_string(local_resolv)
                        .map(|s| s.trim().is_empty())
                        .unwrap_or(true);
                    if needs_local {
                        let _ = crypto_gen::write_file_with_mode_if_changed(
                            local_resolv,
                            "search lan\nnameserver 127.0.0.1\nnameserver ::1\n",
                            0o644,
                        );
                    }
                    "/tmp/resolv.conf"
                };
                if std::path::Path::new(target).exists() {
                    let _ = std::fs::remove_file("/etc/resolv.conf");
                    #[cfg(unix)]
                    let _ = std::os::unix::fs::symlink(target, "/etc/resolv.conf");
                }
            }
            Ok("Симлинк /etc/resolv.conf проверен и восстановлен".to_string())
        }
        "start_watchdog" => {
            qf_commit_and_reload(state, core, false, |c| {
                c.settings.enable_watchdog = true;
            })
            .await?;
            core.set_manual_stop(false);
            Ok("Автономный Watchdog включён".to_string())
        }
        "optimize_memory" | "trim_core_memory" => {
            let _ = core
                .clash_request("POST", "/tachyon/memory/trim", Some("{}"))
                .await;
            if fix_id == "optimize_memory" && !cfg!(windows) {
                let _ = std::fs::write("/proc/sys/vm/drop_caches", "1\n");
            }
            Ok("Буферы памяти и кэши tachyon-core сжаты".to_string())
        }
        "optimize_mtu" => {
            qf_commit_and_reload(state, core, true, |c| {
                c.settings.tun_mtu = 1400;
            })
            .await?;
            Ok("MTU интерфейса установлен на 1400 байт".to_string())
        }
        "flush_conntrack" => {
            if !cfg!(windows) {
                let _ = Command::new("conntrack").arg("-F").status().await;
            }
            let _ = core.clash_request("DELETE", "/connections", None).await;
            Ok("Таблица активных сессий ядра и conntrack очищена".to_string())
        }
        "fix_system_time" => {
            if !cfg!(windows) {
                let _ = Command::new("ntpd")
                    .args(["-q", "-p", "pool.ntp.org"])
                    .status()
                    .await;
            }
            Ok("Запущена синхронизация времени NTP (pool.ntp.org)".to_string())
        }
        "update_subscriptions" | "restart_providers" => {
            let updated = qf_refresh_subs(core).await?;
            Ok(format!("Обновлено подписок: {updated}"))
        }
        "fix_wan_interface" | "fix_gateway" | "restart_network" => {
            let (wan_ok, rtt_ms) =
                watchdog::probe_wan_health(&watchdog::default_wan_targets()).await;
            let snap = Box::new(state.data.read().await.clone());
            if snap.settings.proxy_mode == "tproxy" {
                let _ = qf_apply_net_stack(&snap).await;
            }
            let nft_ok = net_stack::check_nft_table_active().await;
            {
                let mut live = state.live.write().await;
                live.wan_healthy = wan_ok;
                live.wan_probe_ms = rtt_ms;
                live.nft_table_active = nft_ok;
            }
            Ok(format!(
                "Проверка WAN и маршрутизации завершена: канал {}, RTT {} мс",
                if wan_ok {
                    "доступен"
                } else {
                    "недоступен"
                },
                rtt_ms
            ))
        }
        "reset_outbound_pool" => {
            let candidate_tag = {
                let live = state.live.read().await;
                live.outbound_health
                    .iter()
                    .filter(|o| {
                        o.dial_fail > 0
                            && !is_builtin_non_proxy_outbound(&o.tag)
                            && !o.tag.eq_ignore_ascii_case("direct")
                    })
                    .max_by_key(|o| o.dial_fail)
                    .map(|o| o.tag.clone())
                    .or_else(|| {
                        live.outbound_health
                            .iter()
                            .find(|o| {
                                !is_builtin_non_proxy_outbound(&o.tag)
                                    && !o.tag.eq_ignore_ascii_case("direct")
                            })
                            .map(|o| o.tag.clone())
                    })
            };
            let Some(tag) = candidate_tag else {
                anyhow::bail!("Нет активных outbound-тегов для сброса");
            };
            let _ = core.reset_core_outbound(&tag, true, None).await?;
            let _ = core
                .kick_core_filtered(None, None, Some(&tag), Some(30_000))
                .await;
            Ok(format!("Пул соединений узла '{tag}' сброшен"))
        }
        "restore_primary_failover" => {
            let res = core.restore_core_failover("").await;
            Ok(format!(
                "Выполнена проверка и возврат основного узла: {}",
                res.get("any_on_backup")
                    .and_then(Value::as_bool)
                    .map(|b| if b {
                        "резерв ещё активен"
                    } else {
                        "основной активен"
                    })
                    .unwrap_or("завершено")
            ))
        }
        "rollback_core_binary" => {
            let data_dir = state
                .path
                .parent()
                .unwrap_or_else(|| Path::new("data"))
                .to_path_buf();
            let target_bin = PathBuf::from(core.resolve_bin_path().await);
            let meta = tokio::task::spawn_blocking(move || {
                snapshots::rollback_binary(&data_dir, "tachyon-core", &target_bin)
            })
            .await??;
            let _ = qf_core_stop(core).await;
            let _ = qf_core_start(core).await;
            Ok(format!(
                "Выполнен откат бинарника tachyon-core к версии {} и перезапуск",
                meta.version
            ))
        }
        "capture_blackbox" => {
            let summary = qf_capture_blackbox(state, core, "manual").await?;
            Ok(format!("Дамп состояния сохранён в tmpfs: {}", summary.id))
        }
        "restore_native_internet" | "enable_safe_bypass" | "flush_nftables" => {
            let _ = qf_core_stop(core).await;
            Ok("Перехват трафика отключён, прямой доступ в интернет восстановлен".to_string())
        }
        "enable_autostart" => {
            if !cfg!(windows) && std::path::Path::new("/etc/init.d/tachyon").exists() {
                let _ = Command::new("/etc/init.d/tachyon")
                    .arg("enable")
                    .status()
                    .await;
            }
            Ok("Автозапуск службы Tachyon при загрузке роутера проверен и включён".to_string())
        }
        "enable_default_desync" | "restart_zapret" => {
            qf_commit_and_reload(state, core, true, |c| {
                if c.outbound_sources.is_empty() {
                    c.outbound_sources.push(OutboundSource {
                        id: "src_adaptive_desync".to_string(),
                        enabled: true,
                        name: "Adaptive Desync 2.0".to_string(),
                        source_type: "desync".to_string(),
                        desync_preset: "adaptive".to_string(),
                        desync_auto_tune: true,
                        ..Default::default()
                    });
                }
                for s in &mut c.sections {
                    s.enabled = true;
                }
            })
            .await?;
            Ok("Включена секция адаптивной десинхронизации пакетов".to_string())
        }
        "rollback_known_good" | "fix_uci_config" | "restore_lkg" => {
            let lkg = Box::new(transaction::load_known_good(&state.lkg_path)?);
            qf_commit_tx(state, lkg).await?;
            let _ = qf_core_reload(core).await;
            Ok("Выполнен откат к снимку Last Known Good".to_string())
        }
        "upgrade_core" => {
            let info = qf_check_updates(core).await;
            Ok(format!(
                "Проверка обновлений завершена: {}",
                info.get("core_latest")
                    .and_then(Value::as_str)
                    .unwrap_or("актуальная версия")
            ))
        }
        "sync_flow_offload_guard" => {
            let store_snapshot = { state.data.read().await.clone() };
            crate::net_stack::sync_fw4_flow_offload_guard(&store_snapshot).await;
            Ok("Защитные правила Flow Offloading (10-tachyon-offload.nft) установлены".to_string())
        }
        "disable_flow_offloading" => {
            if !cfg!(windows) {
                let _ = Command::new("uci")
                    .args(["-q", "set", "firewall.@defaults[0].flow_offloading=0"])
                    .status()
                    .await;
                let _ = Command::new("uci")
                    .args(["-q", "set", "firewall.@defaults[0].flow_offloading_hw=0"])
                    .status()
                    .await;
                let _ = Command::new("uci")
                    .args(["-q", "commit", "firewall"])
                    .status()
                    .await;
                let _ = Command::new("/etc/init.d/firewall")
                    .arg("reload")
                    .status()
                    .await;
            }
            Ok(
                "Аппаратный и программный Flow Offloading отключены, firewall перезагружен"
                    .to_string(),
            )
        }
        _ => anyhow::bail!("Неизвестный код быстрого исправления: {fix_id}"),
    }
}

pub fn incidents_path() -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        PathBuf::from("/tmp/tachyon/incidents.json")
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::env::temp_dir().join("tachyon-incidents.json")
    }
}

pub fn load_incidents_from(path: &Path) -> Vec<IncidentRecord> {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    serde_json::from_str::<Vec<IncidentRecord>>(&raw).unwrap_or_default()
}

pub fn append_incident_in(path: &Path, mut rec: IncidentRecord) -> Vec<IncidentRecord> {
    rec.detail = crypto_gen::redact_string(&rec.detail);
    let mut list = load_incidents_from(path);
    list.push(rec);
    if list.len() > MAX_INCIDENTS {
        let excess = list.len() - MAX_INCIDENTS;
        list.drain(..excess);
    }
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(&list) {
        let _ = std::fs::write(path, bytes);
    }
    list
}

pub fn load_incidents() -> Vec<IncidentRecord> {
    load_incidents_from(&incidents_path())
}

#[inline(never)]
fn run_local_doctor_with_core_boxed<'a>(
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = DoctorReport> + Send + 'a>> {
    Box::pin(run_local_doctor_with_core(state, core))
}

#[inline(never)]
fn apply_quick_fix_boxed<'a>(
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    fix_id: &'a str,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<String>> + Send + 'a>> {
    Box::pin(apply_quick_fix(state, core, fix_id))
}

#[inline(never)]
fn rollback_snapshot_pinned<'a>(
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    prev: Box<RouterStoreData>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + 'a>> {
    Box::pin(rollback_snapshot_boxed(state, core, prev))
}

/// Verified Quick Fix executor with dry-run preview, per-action cooldown, before/after verification,
/// automatic config rollback on regression, and zero-flash-wear tmpfs IncidentMemory recording.
pub async fn apply_quick_fix_verified(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    fix_id: &str,
    dry_run: bool,
    force: bool,
) -> anyhow::Result<VerifiedFixResult> {
    let risk_tier = quick_fix_risk_tier(fix_id).to_string();
    anyhow::ensure!(
        is_known_quick_fix(fix_id),
        "Неизвестный код быстрого исправления: {fix_id}"
    );

    if dry_run {
        let report = run_local_doctor_with_core_boxed(state, core).await;
        let active_findings = report
            .findings
            .iter()
            .filter(|f| f.suppressed_by.is_none())
            .count();
        return Ok(VerifiedFixResult {
            ok: true,
            fix_id: fix_id.to_string(),
            risk_tier: risk_tier.clone(),
            dry_run: true,
            message: format!(
                "Dry-Run: действие '{fix_id}' (риск: {risk_tier}) будет выполнено без немедленных изменений (текущих проблем: {active_findings})"
            ),
            before_healthy: report.healthy,
            after_healthy: report.healthy,
            before_findings: active_findings,
            after_findings: active_findings,
            rolled_back: false,
            cooldown_blocked: false,
            duration_ms: 0,
        });
    }

    let now = unix_now_secs();
    if !force {
        let ready = {
            let mut wd = core.watchdog.lock().await;
            wd.cooldown_ready(&format!("qfix:{fix_id}"), now, 30)
        };
        if !ready {
            let report = run_local_doctor_with_core_boxed(state, core).await;
            let active_findings = report
                .findings
                .iter()
                .filter(|f| f.suppressed_by.is_none())
                .count();
            return Ok(VerifiedFixResult {
                ok: false,
                fix_id: fix_id.to_string(),
                risk_tier,
                dry_run: false,
                message: format!(
                    "Действие '{fix_id}' ограничено cooldown (повтор допускается через 30 с или с параметром force)"
                ),
                before_healthy: report.healthy,
                after_healthy: report.healthy,
                before_findings: active_findings,
                after_findings: active_findings,
                rolled_back: false,
                cooldown_blocked: true,
                duration_ms: 0,
            });
        }
    }

    let started = Instant::now();
    let before = run_local_doctor_with_core_boxed(state, core).await;
    let before_count = before
        .findings
        .iter()
        .filter(|f| f.suppressed_by.is_none())
        .count();
    let prev_snapshot: Option<Box<RouterStoreData>> = if risk_tier == "config_change" {
        Some(Box::new(state.data.read().await.clone()))
    } else {
        None
    };

    let fix_res = apply_quick_fix_boxed(state, core, fix_id).await;
    let (exec_ok, mut message) = match fix_res {
        Ok(m) => (true, m),
        Err(e) => (false, format!("Ошибка выполнения '{fix_id}': {e}")),
    };

    let after = run_local_doctor_with_core_boxed(state, core).await;
    let after_count = after
        .findings
        .iter()
        .filter(|f| f.suppressed_by.is_none())
        .count();

    let mut rolled_back = false;
    if let Some(prev) = prev_snapshot
        && (!exec_ok || after_count > before_count || (before.healthy && !after.healthy))
        && rollback_snapshot_pinned(state, core, prev).await
    {
        rolled_back = true;
        message = format!(
            "{message}. Обнаружено ухудшение состояния ({before_count} -> {after_count} проблем); выполнен автоматический откат конфигурации."
        );
    }

    let duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    let final_ok = exec_ok && !rolled_back;
    let root_cause_str = before
        .root_causes
        .first()
        .cloned()
        .unwrap_or_else(|| before.summary.clone());
    let inc = IncidentRecord {
        id: format!("inc-{}-{}", unix_now_secs(), crypto_gen::generate_hex(3)),
        timestamp: unix_now_secs(),
        subsystem: before
            .findings
            .iter()
            .find(|f| f.suppressed_by.is_none())
            .map(|f| f.subsystem.clone())
            .unwrap_or_else(|| "system".to_string()),
        root_cause: root_cause_str,
        fix_id: fix_id.to_string(),
        before_ok: before.healthy,
        after_ok: after.healthy,
        rolled_back,
        outcome: if rolled_back {
            "rolled_back".to_string()
        } else if final_ok {
            "verified_ok".to_string()
        } else {
            "failed".to_string()
        },
        detail: message.clone(),
    };
    let incidents = append_incident_in(&incidents_path(), inc);
    {
        let mut live = state.live.write().await;
        live.incidents = incidents;
        live.push_event(
            if final_ok { "info" } else { "warn" },
            "diagnostics",
            &format!("QuickFix '{fix_id}': {message}"),
        );
    }

    Ok(VerifiedFixResult {
        ok: final_ok,
        fix_id: fix_id.to_string(),
        risk_tier,
        dry_run: false,
        message,
        before_healthy: before.healthy,
        after_healthy: after.healthy,
        before_findings: before_count,
        after_findings: after_count,
        rolled_back,
        cooldown_blocked: false,
        duration_ms,
    })
}

fn flow_offload_guard_installed() -> bool {
    let legacy_path = crate::net_stack::fw4_flow_offload_legacy_include_path();
    if legacy_path.exists() {
        return false;
    }
    let path = crate::net_stack::fw4_flow_offload_include_path();
    std::fs::read_to_string(&path)
        .is_ok_and(|raw| !raw.trim().is_empty() && raw.contains("insert rule inet fw4 forward"))
}

pub fn parse_firewall_flow_offloading(content: &str) -> (bool, bool) {
    let mut in_defaults = false;
    let mut sw = false;
    let mut hw = false;
    for raw_line in content.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let mut parts = line.split_whitespace();
        let Some(kw) = parts.next() else {
            continue;
        };
        if kw == "config" {
            let sec_type = parts
                .next()
                .map(|s| s.trim_matches(['\'', '"']))
                .unwrap_or("");
            in_defaults = sec_type == "defaults";
            continue;
        }
        if !in_defaults || kw != "option" {
            continue;
        }
        let opt_name = parts
            .next()
            .map(|s| s.trim_matches(['\'', '"']))
            .unwrap_or("");
        let opt_val = parts
            .next()
            .map(|s| s.trim_matches(['\'', '"']))
            .unwrap_or("");
        let is_on = opt_val == "1"
            || opt_val.eq_ignore_ascii_case("true")
            || opt_val.eq_ignore_ascii_case("yes");
        match opt_name {
            "flow_offloading" => sw = is_on,
            "flow_offloading_hw" => hw = is_on,
            _ => {}
        }
    }
    (sw || hw, hw)
}

fn read_firewall_flow_offloading() -> (bool, bool) {
    std::fs::read_to_string("/etc/config/firewall")
        .map(|raw| parse_firewall_flow_offloading(&raw))
        .unwrap_or((false, false))
}

/// AI Doctor v3.0: Autonomous analysis + RAG knowledge base + optional LLM query.
pub async fn run_ai_doctor(state: &Arc<AppState>, user_query: Option<&str>) -> Value {
    let report = run_local_doctor(state).await;
    let d = Box::new(state.data.read().await.clone());
    let live = state.live.read().await.clone();
    let sys = sys_info::collect_host_info();

    let query_str = user_query.unwrap_or("Проведи полную диагностику маршрутизации и сети роутера");
    let rag_hits = search_knowledge_docs(query_str);

    let mut recommendations: Vec<Value> = Vec::new();
    for f in &report.findings {
        recommendations.push(json!({
            "fix_id": f.quick_fix_id,
            "label": f.quick_fix_label,
            "reason": f.title,
            "severity": f.severity
        }));
    }
    if recommendations.is_empty() {
        recommendations.push(json!({
            "fix_id": "optimize_memory",
            "label": "Сжать буферы памяти",
            "reason": "Профилактическая оптимизация ОЗУ",
            "severity": "info"
        }));
        recommendations.push(json!({
            "fix_id": "update_subscriptions",
            "label": "Обновить подписки и списки",
            "reason": "Проверка актуальности узлов",
            "severity": "info"
        }));
    }

    let mem_mb = live.core_rss_bytes as f64 / (1024.0 * 1024.0);
    let active_secs: Vec<String> = d
        .sections
        .iter()
        .filter(|s| s.enabled)
        .map(|s| format!("{} ({})", s.label, s.connection_type))
        .collect();

    let analysis_text = format!(
        "### Диагностическое заключение AI Doctor v3.0\n\n\
         - **Статус ядра `tachyon-core`**: {} (PID: {}, Uptime: {} с, RSS: {:.2} МБ)\n\
         - **Режим перехвата**: `{}` (nftables `inet TachyonTable`: {})\n\
         - **Активные секции ({})**: {}\n\
         - **Активных сессий**: {} (Трафик: ↑ {} байт / ↓ {} байт)\n\
         - **Запрос**: _{}_\n\n\
         #### Анализ и рекомендации\n\
         {}\n",
        if live.core_running {
            "РАБОТАЕТ"
        } else {
            "ОСТАНОВЛЕНО"
        },
        live.core_pid
            .map(|p| p.to_string())
            .unwrap_or_else(|| "—".to_string()),
        live.core_uptime_secs,
        mem_mb,
        d.settings.proxy_mode,
        if live.nft_table_active {
            "активна"
        } else {
            "не активна"
        },
        active_secs.len(),
        if active_secs.is_empty() {
            "нет".to_string()
        } else {
            active_secs.join(", ")
        },
        live.active_connections,
        live.total_up_bytes,
        live.total_down_bytes,
        crypto_gen::redact_string(query_str),
        if report.findings.is_empty() {
            "Критических сбоев не обнаружено. Конфигурация секций, DNS FakeIP (`198.18.0.0/15`) и балансировщиков согласована.".to_string()
        } else {
            report
                .findings
                .iter()
                .map(|f| {
                    format!(
                        "- **[{}]** {}: {} → Рекомендуется `{}`",
                        f.severity.to_uppercase(),
                        f.title,
                        f.detail,
                        f.quick_fix_label
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
    );

    json!({
        "ok": true,
        "provider": d.settings.ai_doctor_provider,
        "model": d.settings.ai_doctor_model,
        "healthy": report.healthy,
        "analysis": analysis_text,
        "recommendations": recommendations,
        "rag_docs": rag_hits,
        "system": {
            "hostname": sys.router_model,
            "mem_available_bytes": sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes),
            "mem_total_bytes": sys.mem_total_bytes
        }
    })
}

/// Built-in Knowledge Base RAG search (`/api/agent/v1/docs/search`).
pub fn search_knowledge_docs(query: &str) -> Vec<Value> {
    let docs: [(&str, &str, &str, &str); 22] = [
        (
            "01_SYSTEM_ARCHITECTURE",
            "Архитектура Tachyon 2.0 и ядра tachyon-core",
            "arch architecture core tproxy 1602 127.0.0.42",
            "Единый бинарный оркестратор управляет /usr/bin/tachyon-core, таблицей nftables inet TachyonTable (TProxy :1602) и DNS FakeIP (127.0.0.42:53 -> 198.18.0.0/15).",
        ),
        (
            "02_CORE_HEALTH_API",
            "Телеметрия ядра (/tachyon/health, /tachyon/anomalies, /tachyon/flight)",
            "health metrics anomalies flight error_kind dial_ms ttfb fd",
            "Эндпоинты ядра возвращают аптайм, ревизию config-state, давление ОЗУ, открытые FD, статистику FakeIP/UDP NAT, EWMA RTT, классификацию DialErrorClass по outbound и отказы Flight Recorder.",
        ),
        (
            "03_NETWORKING_AND_NFTABLES",
            "Перехват трафика TProxy и таблица inet TachyonTable",
            "nft nftables tproxy fwmark table 100 intercept route",
            "В режиме tproxy пакеты из br-lan маркируются fwmark 0x1 и направляются через ip rule fwmark 0x1 lookup 100 на порт 1602. При исчезновении таблицы выполняется reconcile_nftables.",
        ),
        (
            "04_ADAPTIVE_DESYNC",
            "Адаптивная десинхронизация пакетов (Adaptive Desync 2.0)",
            "desync sni midsld ttl fragmentation clienthello",
            "Модуль desync выполняет фрагментацию TLS ClientHello (pos=1,sni,midsld), автоподбор TTL и отправку служебных пакетов без внешних утилит при фильтрации на транзитном узле.",
        ),
        (
            "05_BALANCERS_INVARIANT",
            "Инвариант секционных балансировщиков и Failover",
            "balancer urltest stability sticky failover backup primary",
            "Балансировщик хранит политику выбора (least_test, stability, sticky, priority) из узлов секции. Переключение группы на резервный узел отображается в /tachyon/failover.",
        ),
        (
            "06_DIAL_ERROR_CLASS",
            "Классификация ошибок соединения DialErrorClass",
            "dial_fail tls_handshake_fail reality_auth_fail tcp_reset eof_early connect_timeout auth_rejected",
            "Ошибки соединения классифицируются как dns_fail, connect_timeout, tcp_reset, tls_handshake_fail, reality_auth_fail, quic_timeout, auth_rejected, eof_early и cert_pin_mismatch.",
        ),
        (
            "07_CERT_PINNING",
            "Ошибка cert_pin_mismatch и проверка сертификата TLS",
            "cert certificate pin mismatch x509 tls fingerprint",
            "Ошибка cert_pin_mismatch возникает при несовпадении SHA-256 отпечатка сертификата сервера с заданным в конфиге или подмене цепочки транзитным узлом.",
        ),
        (
            "08_DNS_AND_FAKEIP",
            "Конвейер DNS, пул FakeIP и сброс кэша (/tachyon/dns/flush)",
            "dns fakeip 198.18.0.0/15 lru eviction cache flush servfail",
            "Запросы A/AAAA перехватываются на 127.0.0.42:53 и получают адреса 198.18.0.0/15. Переполнение FakeIP LRU (evictions) или ошибки апстримов лечатся через /tachyon/dns/flush и переключение на DoH.",
        ),
        (
            "09_DNSMASQ_CASCADE",
            "Каскад dnsmasq -> FakeIP и /etc/resolv.conf",
            "dnsmasq resolv.conf noresolv 127.0.0.42",
            "На OpenWrt dnsmasq перенаправляет запросы на 127.0.0.42#53 (noresolv=1). При сбое симлинка /etc/resolv.conf или зависании dnsmasq используйте fix_dnsmasq и fix_resolv_symlink.",
        ),
        (
            "10_UDP_NAT_FULLCONE",
            "Таблица UDP NAT, FullCone-сессии и вытеснения",
            "udp nat fullcone eviction quic games voip discord",
            "Активные UDP-потоки учитываются счётчиком udp_nat_active. При достижении капаситета ядро вытесняет самые старые потоки (udp_nat_evictions), что прерывает QUIC и голосовой трафик.",
        ),
        (
            "11_WIREGUARD_AWG_HANDSHAKE",
            "WireGuard / AmneziaWG: handshake, MTU и rebind",
            "wireguard wg awg amnezia handshake stale mtu rebind",
            "Если wg_last_handshake_age_secs превышает 180 секунд или сменился внешний IP WAN, выполните POST /tachyon/outbound/reset (wg.rebind) и при необходимости установите MTU 1280-1400.",
        ),
        (
            "12_HYSTERIA2_TUIC_QUIC",
            "Протоколы QUIC (Hysteria2, TUIC, MASQUE) и quic_timeout",
            "hysteria2 tuic masque quic timeout udp loss",
            "Массовые quic_timeout указывают на фильтрацию UDP на маршруте или устаревший NAT. Проверьте порт сервера, обновите пул outbound или переключите секцию на TCP/TLS-транспорт.",
        ),
        (
            "13_VLESS_REALITY_CLOCK",
            "VLESS + REALITY: системное время NTP, short_id и ключ",
            "vless reality ntp clock time skew short_id public_key sni",
            "Ошибка reality_auth_fail или tls_handshake_fail часто вызвана рассинхронизацией системных часов роутера (>30 сек) либо несоответствием short_id, public_key или SNI на сервере.",
        ),
        (
            "14_MEMORY_FD_LIMITS",
            "Память ОЗУ, PressureLevel и лимит дескрипторов FD",
            "memory rss oom pressure critical elevated fd file descriptor trim",
            "При pressure_level=elevated/critical или росте FD >80% Watchdog и Quick Fix вызывают POST /tachyon/memory/trim и закрытие зависших соединений (POST /tachyon/kick с only_stalled_ms).",
        ),
        (
            "15_CONFIG_DRIFT_RELOAD",
            "Дрейф конфигурации (config_digest) и Hot-Reload",
            "config drift digest revision reload hot",
            "Несовпадение desired_config_digest и applied_config_digest из /tachyon/config-state означает, что ядро работает со старой конфигурацией и требует hot_reload_core.",
        ),
        (
            "16_TRS_RULESETS",
            "Наборы правил .trs и диагностика маршрутизации",
            "trs srs ruleset geosite geoip route explain",
            "Tachyon 2.0 использует бинарный формат .trs. Для проверки попадания домена в секцию используйте route_explain и POST /tachyon/route-check.",
        ),
        (
            "17_FLOW_OFFLOADING",
            "Совместимость Hardware/Software Flow Offloading с TProxy и TUN",
            "flow offloading hardware software firewall conflict stall",
            "Tachyon автоматически исключает перехваченный трафик, FakeIP и DNS из @ft через /usr/share/nftables.d/ruleset-post/10-tachyon-offload.nft, сохраняя ускорение прямого трафика. Конфликт остаётся только при одновременном использовании Flow Offloading и SQM (disable_flow_offloading).",
        ),
        (
            "18_IPV6_LEAK_GUARD",
            "Контур IPv6, режим leak_guard и odhcpd",
            "ipv6 leak guard aaaa odhcpd dhcpv6",
            "При отключённом проксировании IPv6 режим leak_guard фильтрует AAAA-ответы и блокирует обходной трафик IPv6 в nftables во избежание утечек.",
        ),
        (
            "19_WATCHDOG_HYSTERESIS",
            "Автономный Watchdog, гистерезис 3/2 и circuit-breaker",
            "watchdog hysteresis wan suppress circuit breaker escalation",
            "Watchdog меняет статус только после серии отказов (3/2 для WAN и DNS), подавляет рестарты ядра при падении WAN и ограничивает перезапуски до 4 за 10 минут.",
        ),
        (
            "20_BLACKBOX_TMPFS",
            "Дампы Blackbox и журнал инцидентов в tmpfs",
            "blackbox dump tmpfs nand flash wear incidents",
            "Blackbox (макс. 5 файлов) и журнал IncidentMemory (макс. 30 записей) сохраняются строго в /tmp/tachyon (tmpfs) с автоматической ротацией и без износа NAND flash.",
        ),
        (
            "21_BINARY_INTEGRITY",
            "Целостность бинарника tachyon-core и откат резервной копии",
            "binary elf corrupt size rollback backup",
            "Watchdog проверяет наличие ELF-заголовка, размер >64 КБ и отсутствие #! обёрток у /usr/bin/tachyon-core, выполняя откат бинарной копии при повреждении.",
        ),
        (
            "22_LAST_KNOWN_GOOD",
            "Транзакции, окно наблюдения 180s и автооткат LKG",
            "lkg known good rollback 180s transaction",
            "После изменений запускается 180-секундное окно наблюдения. При устойчивом падении ядра или DNS в течение окна Watchdog автоматически откатывает tachyon.known_good.json.",
        ),
    ];

    let tokens: Vec<String> = query
        .split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| s.len() >= 2)
        .collect();

    let mut scored: Vec<(i32, Value)> = Vec::new();
    for (id, title, tags, snippet) in docs {
        let title_l = title.to_lowercase();
        let tags_l = tags.to_lowercase();
        let snip_l = snippet.to_lowercase();
        let id_l = id.to_lowercase();
        let score: i32 = if tokens.is_empty() {
            1
        } else {
            let mut sc = 0i32;
            for t in &tokens {
                if id_l.contains(t) {
                    sc += 5;
                }
                if tags_l.contains(t) {
                    sc += 4;
                }
                if title_l.contains(t) {
                    sc += 3;
                }
                if snip_l.contains(t) {
                    sc += 2;
                }
            }
            sc
        };
        if score > 0 {
            scored.push((
                score,
                json!({
                    "id": id,
                    "title": title,
                    "snippet": snippet,
                    "score": score,
                }),
            ));
        }
    }

    scored.sort_by_key(|a| std::cmp::Reverse(a.0));
    if scored.is_empty() {
        return docs
            .iter()
            .take(5)
            .map(|(id, title, _, snippet)| {
                json!({
                    "id": id,
                    "title": title,
                    "snippet": snippet,
                    "score": 0,
                })
            })
            .collect();
    }
    scored.into_iter().take(5).map(|(_, v)| v).collect()
}

#[derive(Debug, Clone, Default)]
struct MacIpTable {
    ip_to_mac: std::collections::HashMap<String, String>,
    mac_to_ips: std::collections::HashMap<String, Vec<String>>,
}

impl MacIpTable {
    fn resolve_client_mac(&self, client: &str) -> Option<String> {
        let trimmed = client.trim();
        if trimmed.is_empty() {
            return None;
        }
        if let Some(mac) = parse_normalized_mac(trimmed) {
            return Some(mac);
        }
        self.ip_to_mac.get(&trimmed.to_ascii_lowercase()).cloned()
    }
}

fn normalize_mac_str(raw: &str) -> String {
    raw.trim().replace('-', ":").to_ascii_lowercase()
}

fn parse_normalized_mac(raw: &str) -> Option<String> {
    let t = raw.trim();
    if t.contains(':') && t.contains('-') {
        return None;
    }
    let normalized = normalize_mac_str(t);
    crate::store::is_mac_address(&normalized).then_some(normalized)
}

fn parse_mac_ip_table(arp_raw: &str, leases_raw: &str) -> MacIpTable {
    let mut table = MacIpTable::default();
    let mut record = |ip_raw: &str, mac_raw: &str| {
        let ip = ip_raw.trim().to_ascii_lowercase();
        let Some(mac) = parse_normalized_mac(mac_raw) else {
            return;
        };
        if ip.is_empty() || mac == "00:00:00:00:00:00" {
            return;
        }
        table
            .ip_to_mac
            .entry(ip.clone())
            .or_insert_with(|| mac.clone());
        let ips = table.mac_to_ips.entry(mac).or_default();
        if !ips.iter().any(|existing| existing == &ip) {
            ips.push(ip);
        }
    };

    for line in arp_raw.lines().skip(1) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 4 {
            record(cols[0], cols[3]);
        }
    }
    for line in leases_raw.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 3 {
            record(cols[2], cols[1]);
        }
    }
    table
}

fn load_system_mac_ip_table() -> MacIpTable {
    if cfg!(windows) || cfg!(test) {
        return MacIpTable::default();
    }
    let arp_raw = std::fs::read_to_string("/proc/net/arp").unwrap_or_default();
    let leases_raw = std::fs::read_to_string("/tmp/dhcp.leases").unwrap_or_default();
    parse_mac_ip_table(&arp_raw, &leases_raw)
}

async fn load_system_mac_ip_table_async() -> MacIpTable {
    if cfg!(windows) || cfg!(test) {
        return MacIpTable::default();
    }
    let (arp_res, leases_res) = tokio::join!(
        tokio::fs::read_to_string("/proc/net/arp"),
        tokio::fs::read_to_string("/tmp/dhcp.leases"),
    );
    parse_mac_ip_table(
        &arp_res.unwrap_or_default(),
        &leases_res.unwrap_or_default(),
    )
}

fn client_matches_entry(
    entry: &str,
    client_ip: &str,
    client_mac: Option<&str>,
    table: &MacIpTable,
) -> bool {
    let entry_trim = entry.trim();
    if entry_trim.is_empty() {
        return false;
    }
    let client_trim = client_ip.trim();
    if !client_trim.is_empty()
        && (entry_trim.eq_ignore_ascii_case(client_trim)
            || crate::store::ip_in_cidr(client_trim, entry_trim))
    {
        return true;
    }
    if let Some(target_mac) = parse_normalized_mac(entry_trim) {
        if let Some(cm) = client_mac
            && parse_normalized_mac(cm).as_deref() == Some(target_mac.as_str())
        {
            return true;
        }
        if parse_normalized_mac(client_trim).as_deref() == Some(target_mac.as_str()) {
            return true;
        }
        if let Some(ips) = table.mac_to_ips.get(&target_mac) {
            return ips.iter().any(|mapped| {
                mapped.eq_ignore_ascii_case(client_trim)
                    || crate::store::ip_in_cidr(client_trim, mapped)
            });
        }
    }
    false
}

/// Trace packet route across `RouterStoreData` (`route_explain`).
pub fn explain_route(
    store: &RouterStoreData,
    client_ip: &str,
    target: &str,
    port: u16,
    protocol: &str,
) -> RouteExplainResult {
    let mac_table = load_system_mac_ip_table();
    explain_route_with_mac_table(store, client_ip, target, port, protocol, &mac_table)
}

fn domain_matches_excluded_token(target_lower: &str, raw_rule: &str) -> bool {
    let clean = raw_rule.split('#').next().unwrap_or("").trim();
    if clean.is_empty() || clean.starts_with("//") {
        return false;
    }
    let lower = clean.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("full:") {
        let host = rest.trim();
        !host.is_empty() && target_lower == host
    } else if let Some(rest) = lower
        .strip_prefix("domain_keyword:")
        .or_else(|| lower.strip_prefix("keyword:"))
    {
        let kw = rest.trim();
        !kw.is_empty() && target_lower.contains(kw)
    } else if let Some(rest) = lower
        .strip_prefix("domain_regex:")
        .or_else(|| lower.strip_prefix("regex:"))
    {
        let pat = rest.trim().trim_start_matches('^').trim_end_matches('$');
        !pat.is_empty() && target_lower.contains(pat)
    } else {
        let dom = lower
            .strip_prefix("domain_suffix:")
            .or_else(|| lower.strip_prefix("domain:"))
            .unwrap_or(&lower)
            .trim()
            .trim_start_matches("*.")
            .trim_start_matches('.');
        !dom.is_empty() && (target_lower == dom || target_lower.ends_with(&format!(".{dom}")))
    }
}

fn explain_route_with_mac_table(
    store: &RouterStoreData,
    client_ip: &str,
    target: &str,
    port: u16,
    protocol: &str,
    mac_table: &MacIpTable,
) -> RouteExplainResult {
    let en = is_en_lang(&store.settings.lang);
    let target_lower = target.trim().to_ascii_lowercase();
    let proto_lower = protocol.trim().to_ascii_lowercase();
    let resolved_client_mac = mac_table.resolve_client_mac(client_ip);
    let match_ctx = RouteMatchTarget {
        client_ip,
        client_mac: resolved_client_mac.as_deref(),
        mac_table,
        target_lower: &target_lower,
        port,
        proto_lower: &proto_lower,
        en,
    };
    let mut steps = vec![
        if en {
            format!("1. Incoming packet from {client_ip} -> {target}:{port} ({proto_lower})")
        } else {
            format!("1. Входящий пакет от {client_ip} -> {target}:{port} ({proto_lower})")
        },
        if en {
            format!(
                "2. DNS FakeIP pipeline (127.0.0.42:53, strategy: {})",
                store.settings.dns_strategy
            )
        } else {
            format!(
                "2. DNS FakeIP конвейер (127.0.0.42:53, стратегия: {})",
                store.settings.dns_strategy
            )
        },
    ];

    // Check parental profiles first
    for prof in store.profiles.iter().filter(|p| p.enabled) {
        if prof.device_ips.iter().any(|ip| {
            client_matches_entry(ip, client_ip, resolved_client_mac.as_deref(), mac_table)
        }) && prof.blocked_domains.iter().any(|d| {
            target_lower == d.to_ascii_lowercase()
                || target_lower.ends_with(&format!(".{}", d.to_ascii_lowercase()))
        }) {
            steps.push(if en {
                format!("3. Matched parental profile \"{}\" -> BLOCK", prof.label)
            } else {
                format!(
                    "3. Совпадение с семейным профилем «{}» -> БЛОКИРОВКА",
                    prof.label
                )
            });
            let sec_label = if en {
                format!("Parental profile: {}", prof.label)
            } else {
                format!("Семейный профиль: {}", prof.label)
            };
            return RouteExplainResult {
                client_ip: client_ip.to_string(),
                target: target.to_string(),
                port,
                protocol: proto_lower,
                matched_section_id: prof.id.clone(),
                matched_section_label: sec_label.clone(),
                matched_section: sec_label,
                matched_condition_id: "blocked_domains".to_string(),
                matched_reason: if en {
                    format!("Domain '{target}' is blocked by parental profile")
                } else {
                    format!("Домен '{}' заблокирован семейным профилем", target)
                },
                resolved_outbound: "block".to_string(),
                selected_outbound: "block".to_string(),
                dns_strategy: "reject".to_string(),
                connection_type: "block".to_string(),
                trace_steps: steps.clone(),
                steps,
            };
        }
    }

    for sec in store.sections.iter().filter(|s| s.enabled) {
        if sec.action == "dns" || sec.connection_type == "dns" {
            continue;
        }
        let resolved_out = if sec.action == "block" {
            "block".to_string()
        } else if sec.action == "direct" {
            "direct".to_string()
        } else if !sec.balancer_refs.is_empty() {
            format!("bal-{}-{}", sec.id, sec.balancer_refs[0])
        } else {
            sec.outbound_source_refs
                .first()
                .cloned()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| sec.connection_type.clone())
        };

        let is_excluded_client = sec.excluded_ips.iter().any(|ip| {
            client_matches_entry(ip, client_ip, resolved_client_mac.as_deref(), mac_table)
        });
        let is_excluded_port = sec.exclude_ports.iter().any(|p| p == &port.to_string());
        let is_excluded_domain = sec
            .exclude_domains
            .iter()
            .any(|d| domain_matches_excluded_token(&target_lower, d));
        let is_excluded_subnet = sec.exclude_subnets.iter().any(|s| {
            let clean = s.trim();
            !clean.is_empty()
                && (clean.eq_ignore_ascii_case(&target_lower)
                    || crate::store::ip_in_cidr(target.trim(), clean))
        });
        if is_excluded_client || is_excluded_port || is_excluded_domain || is_excluded_subnet {
            continue;
        }

        let fakeip_active = store.settings.fakeip_enabled;
        let fakeip_v4_label = if store.settings.fakeip_inet4_range.trim().is_empty() {
            "198.18.0.0/15"
        } else {
            store.settings.fakeip_inet4_range.trim()
        };
        let dns_strategy = if fakeip_active && !resolved_out.eq_ignore_ascii_case("direct") {
            format!("fakeip ({fakeip_v4_label})")
        } else if fakeip_active {
            "fakeip / realip".to_string()
        } else {
            "system (77.88.8.8)".to_string()
        };

        if sec.fully_routed_ips.iter().any(|ip| {
            client_matches_entry(ip, client_ip, resolved_client_mac.as_deref(), mac_table)
        }) {
            steps.push(if en {
                format!(
                    "3. Client {client_ip} is in full-routing list of section \"{}\" -> {resolved_out}",
                    sec.label
                )
            } else {
                format!(
                    "3. Клиент {client_ip} входит в список полной маршрутизации секции «{}» -> {resolved_out}",
                    sec.label
                )
            });
            return RouteExplainResult {
                client_ip: client_ip.to_string(),
                target: target.to_string(),
                port,
                protocol: proto_lower,
                matched_section_id: sec.id.clone(),
                matched_section_label: sec.label.clone(),
                matched_section: sec.label.clone(),
                matched_condition_id: "fully_routed_ips".to_string(),
                matched_reason: if en {
                    format!("Client {client_ip} is listed in fully_routed_ips")
                } else {
                    format!("Клиент {client_ip} задан в fully_routed_ips")
                },
                resolved_outbound: resolved_out.clone(),
                selected_outbound: resolved_out,
                dns_strategy,
                connection_type: sec.connection_type.clone(),
                trace_steps: steps.clone(),
                steps,
            };
        }

        // Check referenced conditions
        for cref in &sec.condition_refs {
            let Some(cond) = store.conditions.iter().find(|c| &c.id == cref && c.enabled) else {
                continue;
            };
            if let Some(reason) =
                match_condition_against_target_with_table(cond, &store.conditions, &match_ctx)
            {
                steps.push(if en {
                    format!(
                        "3. Matched condition \"{}\" ({reason}) in section \"{}\"",
                        cond.name, sec.label
                    )
                } else {
                    format!(
                        "3. Совпадение с условием «{}» ({reason}) в секции «{}»",
                        cond.name, sec.label
                    )
                });
                steps.push(if en {
                    format!(
                        "4. Outbound handler: {resolved_out} ({})",
                        sec.connection_type
                    )
                } else {
                    format!(
                        "4. Выходной обработчик: {resolved_out} ({})",
                        sec.connection_type
                    )
                });
                return RouteExplainResult {
                    client_ip: client_ip.to_string(),
                    target: target.to_string(),
                    port,
                    protocol: proto_lower,
                    matched_section_id: sec.id.clone(),
                    matched_section_label: sec.label.clone(),
                    matched_section: sec.label.clone(),
                    matched_condition_id: cond.id.clone(),
                    matched_reason: reason,
                    resolved_outbound: resolved_out.clone(),
                    selected_outbound: resolved_out,
                    dns_strategy,
                    connection_type: sec.connection_type.clone(),
                    trace_steps: steps.clone(),
                    steps,
                };
            }
        }

        // Also check inline section domains/lists/geosite/ports/protocol
        let inline_l4_proto = if sec.protocol.len() == 1
            && (sec.protocol[0].eq_ignore_ascii_case("tcp")
                || sec.protocol[0].eq_ignore_ascii_case("udp"))
        {
            sec.protocol[0].clone()
        } else {
            String::new()
        };
        let inline_cond = crate::store::TrafficCondition {
            id: sec.id.clone(),
            enabled: true,
            name: sec.label.clone(),
            condition_type: "atomic".to_string(),
            community_lists: sec.community_lists.clone(),
            community_subnets: sec.community_subnets,
            rule_set: sec.rule_set_urls.clone(),
            rule_set_with_subnets: sec.rule_set_with_subnets.clone(),
            domains: sec.domains.clone(),
            user_domains: sec.user_domains.clone(),
            exclude_domains: sec.exclude_domains.clone(),
            user_subnets: sec.user_subnets.clone(),
            exclude_subnets: sec.exclude_subnets.clone(),
            geoip_codes: sec.geoip_codes.clone(),
            geosite_codes: sec.geosite_codes.clone(),
            client_ips: sec.source_ip_cidr.clone(),
            ports: sec.ports.clone(),
            l4_proto: inline_l4_proto,
            ..Default::default()
        };
        if let Some(reason) =
            match_condition_against_target_with_table(&inline_cond, &store.conditions, &match_ctx)
        {
            steps.push(if en {
                format!("3. Matched section \"{}\" rules ({reason})", sec.label)
            } else {
                format!(
                    "3. Совпадение с правилами секции «{}» ({reason})",
                    sec.label
                )
            });
            steps.push(if en {
                format!(
                    "4. Outbound handler: {resolved_out} ({})",
                    sec.connection_type
                )
            } else {
                format!(
                    "4. Выходной обработчик: {resolved_out} ({})",
                    sec.connection_type
                )
            });
            return RouteExplainResult {
                client_ip: client_ip.to_string(),
                target: target.to_string(),
                port,
                protocol: proto_lower,
                matched_section_id: sec.id.clone(),
                matched_section_label: sec.label.clone(),
                matched_section: sec.label.clone(),
                matched_condition_id: sec.id.clone(),
                matched_reason: reason,
                resolved_outbound: resolved_out.clone(),
                selected_outbound: resolved_out,
                dns_strategy,
                connection_type: sec.connection_type.clone(),
                trace_steps: steps.clone(),
                steps,
            };
        }

        if sec.match_all {
            let reason = if en {
                format!(
                    "Section \"{}\" is configured to route all traffic (match_all)",
                    sec.label
                )
            } else {
                format!(
                    "Секция «{}» настроена на перехват всего трафика (match_all)",
                    sec.label
                )
            };
            steps.push(format!("3. {reason}"));
            steps.push(if en {
                format!(
                    "4. Outbound handler: {resolved_out} ({})",
                    sec.connection_type
                )
            } else {
                format!(
                    "4. Выходной обработчик: {resolved_out} ({})",
                    sec.connection_type
                )
            });
            return RouteExplainResult {
                client_ip: client_ip.to_string(),
                target: target.to_string(),
                port,
                protocol: proto_lower,
                matched_section_id: sec.id.clone(),
                matched_section_label: sec.label.clone(),
                matched_section: sec.label.clone(),
                matched_condition_id: "match_all".to_string(),
                matched_reason: reason,
                resolved_outbound: resolved_out.clone(),
                selected_outbound: resolved_out,
                dns_strategy,
                connection_type: sec.connection_type.clone(),
                trace_steps: steps.clone(),
                steps,
            };
        }
    }

    steps.push(if en {
        "3. No section rules matched -> fallback route (route.final = direct)".to_string()
    } else {
        "3. Ни одно правило секций не совпало -> маршрут по умолчанию (route.final = direct)"
            .to_string()
    });
    let final_section = if en {
        "Direct Route (Direct)"
    } else {
        "Прямой маршрут (Direct)"
    };
    RouteExplainResult {
        client_ip: client_ip.to_string(),
        target: target.to_string(),
        port,
        protocol: proto_lower,
        matched_section_id: "final".to_string(),
        matched_section_label: final_section.to_string(),
        matched_section: final_section.to_string(),
        matched_condition_id: "none".to_string(),
        matched_reason: if en {
            "No conditions matched; routed directly (direct)".to_string()
        } else {
            "Не совпало ни одно условие; направлено напрямую (direct)".to_string()
        },
        resolved_outbound: "direct".to_string(),
        selected_outbound: "direct".to_string(),
        dns_strategy: "system (77.88.8.8)".to_string(),
        connection_type: "direct".to_string(),
        trace_steps: steps.clone(),
        steps,
    }
}

fn match_list_tag_against_domain(tag_lower: &str, target_lower: &str) -> bool {
    if target_lower.contains(tag_lower) {
        return true;
    }
    let has = |needles: &[&str]| {
        needles.iter().any(|n| {
            target_lower == *n
                || target_lower.ends_with(&format!(".{n}"))
                || target_lower.contains(n)
        })
    };
    match tag_lower {
        "youtube" => has(&[
            "youtube.com",
            "youtu.be",
            "googlevideo.com",
            "ytimg.com",
            "yt3.ggpht.com",
        ]),
        "discord" => has(&[
            "discord.com",
            "discord.gg",
            "discordapp.com",
            "discordapp.net",
            "discord.media",
        ]),
        "telegram" => has(&[
            "t.me",
            "telegram.org",
            "telegram.me",
            "telegra.ph",
            "telesco.pe",
            "tdesktop.com",
            "tx.me",
            "tg.dev",
        ]),
        "openai" | "chatgpt" => has(&[
            "openai.com",
            "chatgpt.com",
            "oaistatic.com",
            "oaiusercontent.com",
        ]),
        "qwen" => has(&[
            "qwen.ai",
            "chat.qwen.ai",
            "qwenlm.ai",
            "tongyi.com",
            "tongyi.aliyun.com",
            "dashscope.aliyuncs.com",
            "modelscope.cn",
        ]),
        "kimi" => has(&[
            "kimi.com",
            "kimi.ai",
            "kimi.moonshot.cn",
            "moonshot.cn",
            "moonshot.ai",
            "byteoversea.com",
            "volcengine.com",
            "volces.com",
            "bytedance.com",
            "bytecdn.com",
            "byted.org",
            "byteimg.com",
        ]),
        "paas_db" => has(&["vercel.com", "supabase.com", "supabase.co", "neon.tech"]),
        "kick" => has(&["kick.com"]),
        "ai" | "ai_all" => has(&[
            "openai.com",
            "chatgpt.com",
            "claude.ai",
            "anthropic.com",
            "gemini.google.com",
            "perplexity.ai",
            "x.ai",
            "grok.com",
            "deepseek.com",
            "huggingface.co",
            "mistral.ai",
            "qwen.ai",
            "chat.qwen.ai",
            "qwenlm.ai",
            "kimi.com",
            "kimi.ai",
            "kimi.moonshot.cn",
            "moonshot.ai",
            "moonshot.cn",
            "byteoversea.com",
            "volcengine.com",
            "volces.com",
            "bytedance.com",
            "bytecdn.com",
            "byted.org",
            "byteimg.com",
        ]),
        "meta" => has(&[
            "instagram.com",
            "cdninstagram.com",
            "facebook.com",
            "fb.com",
            "fbcdn.net",
            "threads.net",
            "whatsapp.com",
        ]),
        "instagram" => has(&["instagram.com", "cdninstagram.com", "ig.me"]),
        "facebook" => has(&["facebook.com", "fb.com", "fbcdn.net"]),
        "twitter" | "x" => has(&["x.com", "twitter.com", "twimg.com", "t.co"]),
        "spotify" => has(&["spotify.com", "scdn.co", "spotifycdn.com"]),
        "netflix" => has(&["netflix.com", "nflxvideo.net", "nflximg.net"]),
        "twitch" => has(&["twitch.tv", "ttvnw.net", "jtvnw.net"]),
        "tiktok" => has(&["tiktok.com", "tiktokcdn.com", "tiktokv.com", "musical.ly"]),
        "google" => has(&[
            "google.com",
            "gstatic.com",
            "googleapis.com",
            "gmail.com",
            "g.co",
        ]),
        "github" => has(&[
            "github.com",
            "githubusercontent.com",
            "githubassets.com",
            "github.io",
        ]),
        "cloudflare" => has(&[
            "cloudflare.com",
            "cloudflareclient.com",
            "cloudflare-dns.com",
            "one.one.one.one",
        ]),
        "russia_inside" | "ru" | "category-gov-ru" => {
            has(&[
                "ya.ru",
                "yandex.ru",
                "vk.com",
                "ok.ru",
                "mail.ru",
                "gosuslugi.ru",
                "sberbank.ru",
                "ozon.ru",
                "wildberries.ru",
                "avito.ru",
                "kinopoisk.ru",
            ]) || target_lower.ends_with(".ru")
                || target_lower.ends_with(".su")
        }
        _ => false,
    }
}

fn check_community_ip_match_in_dirs(
    target_ip: &str,
    community_name: &str,
    dirs: &[std::path::PathBuf],
) -> bool {
    let target_t = target_ip.trim();
    if target_t.parse::<std::net::IpAddr>().is_err() {
        return false;
    }
    let name_lc = community_name.trim().to_ascii_lowercase();
    if name_lc.is_empty() {
        return false;
    }
    let canonical =
        crate::config_gen::canonical_community_subnet_service(&name_lc).to_ascii_lowercase();
    let mut names = vec![name_lc.as_str()];
    if canonical != name_lc {
        names.push(canonical.as_str());
    }
    for dir in dirs {
        for name in &names {
            let path = dir.join(format!("community-subnets-{name}.lst"));
            if let Ok(raw) = std::fs::read_to_string(&path) {
                for cidr in crate::config_gen::parse_valid_cidr_list(&raw) {
                    if crate::store::ip_in_cidr(target_t, &cidr) {
                        return true;
                    }
                }
            }
        }
    }
    false
}

fn default_community_subnet_dirs() -> Vec<std::path::PathBuf> {
    let mut dirs: Vec<std::path::PathBuf> = Vec::new();
    for env_key in ["TMP_RULESET_FOLDER", "TACHYON_RULESETS_DIR"] {
        if let Ok(val) = std::env::var(env_key) {
            let t = val.trim();
            if !t.is_empty() {
                let p = std::path::PathBuf::from(t);
                if !dirs.contains(&p) {
                    dirs.push(p);
                }
            }
        }
    }
    for fallback in [
        "/tmp/tachyon-core/rulesets",
        "/etc/tachyon/rulesets",
        "/usr/share/tachyon/rulesets",
    ] {
        let p = std::path::PathBuf::from(fallback);
        if !dirs.contains(&p) {
            dirs.push(p);
        }
    }
    dirs
}

#[cfg(test)]
fn match_condition_community_lists_in_dirs(
    cond: &crate::store::TrafficCondition,
    target_lower: &str,
    dirs: &[std::path::PathBuf],
) -> Option<String> {
    match_condition_community_lists_in_dirs_lang(cond, target_lower, dirs, false)
}

fn match_condition_community_lists_in_dirs_lang(
    cond: &crate::store::TrafficCondition,
    target_lower: &str,
    dirs: &[std::path::PathBuf],
    en: bool,
) -> Option<String> {
    for list in &cond.community_lists {
        let ll = list.trim().to_ascii_lowercase();
        if !ll.is_empty()
            && (match_list_tag_against_domain(&ll, target_lower)
                || (cond.community_subnets
                    && check_community_ip_match_in_dirs(target_lower, &ll, dirs)))
        {
            return Some(if en {
                format!("Community list trs-{list} in condition \"{}\"", cond.name)
            } else {
                format!("Список сообщества trs-{list} в условии «{}»", cond.name)
            });
        }
    }

    for rset in cond
        .rule_set
        .iter()
        .chain(cond.rule_set_with_subnets.iter())
    {
        let clean = rset.trim();
        if crate::config_gen::is_community_list_token(clean) {
            let ll = clean.to_ascii_lowercase();
            if match_list_tag_against_domain(&ll, target_lower)
                || check_community_ip_match_in_dirs(target_lower, &ll, dirs)
            {
                return Some(if en {
                    format!("Rule set {clean} in condition \"{}\"", cond.name)
                } else {
                    format!("Набор правил {clean} в условии «{}»", cond.name)
                });
            }
        }
    }
    None
}

struct RouteMatchTarget<'a> {
    client_ip: &'a str,
    client_mac: Option<&'a str>,
    mac_table: &'a MacIpTable,
    target_lower: &'a str,
    port: u16,
    proto_lower: &'a str,
    en: bool,
}

fn match_condition_against_target_with_table(
    cond: &crate::store::TrafficCondition,
    all_conditions: &[crate::store::TrafficCondition],
    ctx: &RouteMatchTarget<'_>,
) -> Option<String> {
    match cond.condition_type.as_str() {
        "all" if !cond.children.is_empty() => {
            let mut matched_reasons = Vec::new();
            for cid in &cond.children {
                let child = all_conditions.iter().find(|c| c.id == *cid && c.enabled)?;
                let reason = match_condition_against_target_with_table(child, all_conditions, ctx)?;
                matched_reasons.push(reason);
            }
            return Some(matched_reasons.join(" AND "));
        }
        "any" if !cond.children.is_empty() => {
            for cid in &cond.children {
                if let Some(child) = all_conditions.iter().find(|c| c.id == *cid && c.enabled)
                    && let Some(reason) =
                        match_condition_against_target_with_table(child, all_conditions, ctx)
                {
                    return Some(reason);
                }
            }
            return None;
        }
        "not" if !cond.children.is_empty() => {
            let cid = &cond.children[0];
            if let Some(child) = all_conditions.iter().find(|c| c.id == *cid && c.enabled)
                && match_condition_against_target_with_table(child, all_conditions, ctx).is_none()
            {
                return Some(if ctx.en {
                    format!("Negation of condition \"{}\"", cond.name)
                } else {
                    format!("Отрицание условия «{}»", cond.name)
                });
            }
            return None;
        }
        _ => {}
    }

    if !cond.l4_proto.is_empty() && !cond.l4_proto.eq_ignore_ascii_case(ctx.proto_lower) {
        return None;
    }
    let has_client_filter = !cond.client_ips.is_empty() || !cond.source_macs.is_empty();
    if has_client_filter
        && !cond
            .client_ips
            .iter()
            .chain(cond.source_macs.iter())
            .any(|entry| client_matches_entry(entry, ctx.client_ip, ctx.client_mac, ctx.mac_table))
    {
        return None;
    }
    if cond
        .exclude_client_ips
        .iter()
        .any(|entry| client_matches_entry(entry, ctx.client_ip, ctx.client_mac, ctx.mac_table))
    {
        return None;
    }
    if cond
        .exclude_domains
        .iter()
        .any(|d| domain_matches_excluded_token(ctx.target_lower, d))
    {
        return None;
    }

    if cond
        .domains
        .iter()
        .chain(cond.user_domains.iter())
        .any(|d| {
            let dl = d.trim().to_ascii_lowercase();
            !dl.is_empty()
                && (ctx.target_lower == dl || ctx.target_lower.ends_with(&format!(".{dl}")))
        })
    {
        return Some(if ctx.en {
            format!("Custom domain in condition \"{}\"", cond.name)
        } else {
            format!("Пользовательский домен в условии «{}»", cond.name)
        });
    }

    if !cond.ports.is_empty() && cond.ports.iter().any(|p| p.trim() == ctx.port.to_string()) {
        return Some(if ctx.en {
            format!("Port {} in condition \"{}\"", ctx.port, cond.name)
        } else {
            format!("Порт {} в условии «{}»", ctx.port, cond.name)
        });
    }

    if !cond.user_subnets.is_empty()
        && cond.user_subnets.iter().any(|s| {
            let clean = s.trim();
            !clean.is_empty()
                && (clean.eq_ignore_ascii_case(ctx.target_lower)
                    || crate::store::ip_in_cidr(ctx.target_lower, clean))
        })
    {
        return Some(if ctx.en {
            format!("Subnet in condition \"{}\"", cond.name)
        } else {
            format!("Подсеть в условии «{}»", cond.name)
        });
    }

    let comm_dirs = default_community_subnet_dirs();
    if let Some(reason) =
        match_condition_community_lists_in_dirs_lang(cond, ctx.target_lower, &comm_dirs, ctx.en)
    {
        return Some(reason);
    }

    for gs in &cond.geosite_codes {
        let gl = gs.trim().to_ascii_lowercase();
        if !gl.is_empty() && match_list_tag_against_domain(&gl, ctx.target_lower) {
            return Some(if ctx.en {
                format!("Geosite list geosite-{gs} in condition \"{}\"", cond.name)
            } else {
                format!("Набор geosite-{gs} в условии «{}»", cond.name)
            });
        }
    }

    if has_client_filter
        && cond.domains.is_empty()
        && cond.user_domains.is_empty()
        && cond.ports.is_empty()
        && cond.user_subnets.is_empty()
        && cond.community_lists.is_empty()
        && cond.rule_set_with_subnets.is_empty()
        && cond.geosite_codes.is_empty()
    {
        return Some(if ctx.en {
            format!("Device/source in condition \"{}\"", cond.name)
        } else {
            format!("Устройство/источник в условии «{}»", cond.name)
        });
    }
    None
}

/// Benchmark candidate DNS resolvers in parallel.
pub async fn run_dns_speed_test() -> Vec<DnsBenchmarkEntry> {
    let candidates = [
        ("77.88.8.8:53", "Yandex DNS (77.88.8.8)"),
        ("77.88.8.1:53", "Yandex Secondary (77.88.8.1)"),
        ("1.1.1.1:443", "Cloudflare DoH (1.1.1.1)"),
        ("1.0.0.1:443", "Cloudflare Secondary (1.0.0.1)"),
        ("8.8.8.8:443", "Google DoH (8.8.8.8)"),
        ("9.9.9.9:443", "Quad9 DoH (9.9.9.9)"),
        ("94.140.14.14:443", "AdGuard DoH (94.140.14.14)"),
    ];
    let mut handles = Vec::new();
    for (addr, label) in candidates {
        handles.push(tokio::spawn(async move {
            let start = Instant::now();
            let ok = tokio::time::timeout(Duration::from_millis(1500), TcpStream::connect(addr))
                .await
                .is_ok_and(|r| r.is_ok());
            let latency_ms = if ok {
                start.elapsed().as_millis() as u32
            } else {
                9999
            };
            DnsBenchmarkEntry {
                server: crate::config_gen::extract_host_only(addr),
                protocol: label.to_string(),
                latency_ms,
                reachable: ok,
            }
        }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(entry) = h.await {
            out.push(entry);
        }
    }
    out.sort_by_key(|e| e.latency_ms);
    out
}

fn build_tls13_client_hello(sni: &str) -> Vec<u8> {
    use rand::RngCore;
    use x25519_dalek::{PublicKey, StaticSecret};

    let mut random = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut random);
    let mut session_id = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut session_id);
    let mut raw_secret = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut raw_secret);
    let secret = StaticSecret::from(raw_secret);
    let pub_key = PublicKey::from(&secret);
    let pub_bytes = pub_key.as_bytes();

    let sni_bytes = sni.as_bytes();
    let sni_ext_len = 5 + sni_bytes.len();
    let mut exts = Vec::with_capacity(128 + sni_bytes.len());
    // 0x0000: server_name
    exts.extend_from_slice(&[0x00, 0x00]);
    exts.extend_from_slice(&(sni_ext_len as u16).to_be_bytes());
    exts.extend_from_slice(&((3 + sni_bytes.len()) as u16).to_be_bytes());
    exts.push(0x00);
    exts.extend_from_slice(&(sni_bytes.len() as u16).to_be_bytes());
    exts.extend_from_slice(sni_bytes);
    // 0x000a: supported_groups (x25519, secp256r1)
    exts.extend_from_slice(&[0x00, 0x0a, 0x00, 0x06, 0x00, 0x04, 0x00, 0x1d, 0x00, 0x17]);
    // 0x000d: signature_algorithms
    exts.extend_from_slice(&[
        0x00, 0x0d, 0x00, 0x0a, 0x00, 0x08, 0x04, 0x03, 0x08, 0x04, 0x08, 0x07, 0x04, 0x01,
    ]);
    // 0x002b: supported_versions (TLS 1.3 only: 0x0304)
    exts.extend_from_slice(&[0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04]);
    // 0x0033: key_share (x25519)
    exts.extend_from_slice(&[0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20]);
    exts.extend_from_slice(pub_bytes);

    let mut body = Vec::with_capacity(80 + exts.len());
    body.extend_from_slice(&[0x03, 0x03]);
    body.extend_from_slice(&random);
    body.push(32);
    body.extend_from_slice(&session_id);
    // Cipher suites: TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256
    body.extend_from_slice(&[0x00, 0x06, 0x13, 0x01, 0x13, 0x02, 0x13, 0x03]);
    body.extend_from_slice(&[0x01, 0x00]); // legacy compression = null
    body.extend_from_slice(&(exts.len() as u16).to_be_bytes());
    body.extend_from_slice(&exts);

    let hs_len = body.len();
    let mut handshake = Vec::with_capacity(4 + hs_len);
    handshake.push(0x01); // ClientHello
    handshake.push(((hs_len >> 16) & 0xff) as u8);
    handshake.push(((hs_len >> 8) & 0xff) as u8);
    handshake.push((hs_len & 0xff) as u8);
    handshake.extend_from_slice(&body);

    let mut record = Vec::with_capacity(5 + handshake.len());
    record.extend_from_slice(&[0x16, 0x03, 0x01]);
    record.extend_from_slice(&(handshake.len() as u16).to_be_bytes());
    record.extend_from_slice(&handshake);
    record
}

/// Inspect a TLS record buffer for a ServerHello with `supported_versions == 0x0304` (TLS 1.3).
/// Returns `(got_server_hello, is_tls13)`.
fn inspect_tls_server_hello(buf: &[u8]) -> (bool, bool) {
    if buf.len() < 44 || buf[0] != 0x16 || buf[5] != 0x02 {
        return (false, false);
    }
    let rec_len = u16::from_be_bytes([buf[3], buf[4]]) as usize;
    let end = (5 + rec_len).min(buf.len());
    let hs = &buf[5..end];
    if hs.len() < 39 {
        return (false, false);
    }
    let mut pos = 4 + 2 + 32; // hs header (4) + legacy_version (2) + random (32)
    if pos >= hs.len() {
        return (true, false);
    }
    let sid_len = hs[pos] as usize;
    pos += 1 + sid_len + 2 + 1; // sid + cipher_suite (2) + compression (1)
    if pos + 2 > hs.len() {
        return (true, false);
    }
    let exts_len = u16::from_be_bytes([hs[pos], hs[pos + 1]]) as usize;
    pos += 2;
    let exts_end = (pos + exts_len).min(hs.len());
    while pos + 4 <= exts_end {
        let ext_type = u16::from_be_bytes([hs[pos], hs[pos + 1]]);
        let ext_len = u16::from_be_bytes([hs[pos + 2], hs[pos + 3]]) as usize;
        pos += 4;
        if pos + ext_len > exts_end {
            break;
        }
        if ext_type == 0x002b && ext_len >= 2 && hs[pos] == 0x03 && hs[pos + 1] == 0x04 {
            return (true, true);
        }
        pos += ext_len;
    }
    (true, false)
}

async fn probe_tls_handshake(
    addr: &str,
    sni: &str,
    split_chunks: usize,
    inter_chunk_ms: u64,
) -> (bool, bool, u32) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let start = Instant::now();
    let Ok(Ok(mut stream)) =
        tokio::time::timeout(Duration::from_millis(1600), TcpStream::connect(addr)).await
    else {
        return (false, false, 9999);
    };
    let _ = stream.set_nodelay(true);
    let hello = build_tls13_client_hello(sni);
    if split_chunks <= 1 || hello.len() <= 16 {
        if stream.write_all(&hello).await.is_err() || stream.flush().await.is_err() {
            return (false, false, 9999);
        }
    } else {
        // Send TLS ClientHello across multiple TCP writes to exercise record/SNI segmentation
        let rec_hdr = &hello[..5];
        let payload = &hello[5..];
        let step = (payload.len() / split_chunks).max(1);
        let mut offset = 0usize;
        let mut first = true;
        while offset < payload.len() {
            let end = (offset + step).min(payload.len());
            if first {
                if stream.write_all(rec_hdr).await.is_err() {
                    return (false, false, 9999);
                }
                first = false;
            }
            if stream.write_all(&payload[offset..end]).await.is_err()
                || stream.flush().await.is_err()
            {
                return (false, false, 9999);
            }
            offset = end;
            if inter_chunk_ms > 0 && offset < payload.len() {
                tokio::time::sleep(Duration::from_millis(inter_chunk_ms)).await;
            }
        }
    }

    let mut resp = [0u8; 512];
    let n = match tokio::time::timeout(Duration::from_millis(1600), stream.read(&mut resp)).await {
        Ok(Ok(n)) if n > 0 => n,
        _ => return (false, false, 9999),
    };
    let ms = start.elapsed().as_millis().max(1) as u32;
    let (got_sh, is_tls13) = inspect_tls_server_hello(&resp[..n]);
    (got_sh, is_tls13, ms)
}

/// Benchmark native `tachyon-core` transport desync presets in parallel (`Desync Fuzzer`).
pub async fn run_desync_fuzzer(target_host: &str) -> Vec<FuzzerStrategyResult> {
    // (preset, label, tcp_split_chunks, inter_chunk_ms, probe_udp_quic)
    let presets = [
        (
            "adaptive",
            "Adaptive Desync 2.0 (Auto-Tune)",
            1usize,
            0u64,
            false,
        ),
        (
            "tls_split",
            "TLS Record Split + SNI Fragment (pos=sni)",
            2,
            2,
            false,
        ),
        ("multisplit", "TCP Multi-Split (pos=1,midsld)", 4, 2, false),
        ("disorder", "TCP Reverse Disorder + Autottl", 3, 5, false),
        ("fake_split", "Cloned ClientHello Split", 5, 1, false),
        ("quic_fake", "QUIC Initial Probe + UDP Framing", 1, 0, true),
    ];
    let host = if target_host.trim().is_empty() {
        "www.youtube.com".to_string()
    } else {
        target_host.trim().to_string()
    };

    let mut handles = Vec::new();
    for (preset, label, chunks, delay_ms, udp_probe) in presets {
        let h = host.clone();
        handles.push(tokio::spawn(async move {
            let sni = h.split(':').next().unwrap_or(&h).to_string();
            let addr = if h.contains(':') {
                h.clone()
            } else {
                format!("{h}:443")
            };
            let (ok, latency_ms) = if udp_probe {
                let start = Instant::now();
                let udp_ok = if let Ok(sock) = tokio::net::UdpSocket::bind("0.0.0.0:0").await {
                    if sock.connect(&addr).await.is_ok() {
                        // RFC 9000 QUIC v1 Initial-like padding probe (1200 bytes)
                        let mut pkt = [0u8; 1200];
                        pkt[0] = 0xc3;
                        pkt[1..5].copy_from_slice(&[0x00, 0x00, 0x00, 0x01]);
                        let _ = sock.send(&pkt).await;
                        let mut rbuf = [0u8; 256];
                        tokio::time::timeout(Duration::from_millis(1200), sock.recv(&mut rbuf))
                            .await
                            .is_ok_and(|r| r.is_ok_and(|n| n > 0))
                    } else {
                        false
                    }
                } else {
                    false
                };
                if udp_ok {
                    (true, start.elapsed().as_millis().max(1) as u32)
                } else {
                    (false, 0)
                }
            } else {
                let (got_sh, _, ms) = probe_tls_handshake(&addr, &sni, chunks, delay_ms).await;
                (got_sh, if got_sh { ms } else { 0 })
            };
            FuzzerStrategyResult {
                preset: preset.to_string(),
                label: label.to_string(),
                success: ok,
                latency_ms,
            }
        }));
    }

    let mut out = Vec::new();
    for h in handles {
        if let Ok(r) = h.await {
            out.push(r);
        }
    }
    out
}

/// Parallel SNI Scanner for VLESS Reality & Adaptive Desync (`POST /api/diagnostics/sni-scan`).
pub async fn scan_sni_domains(custom: Vec<String>) -> Vec<SniScanEntry> {
    let default_domains = [
        "www.microsoft.com",
        "dl.google.com",
        "aws.amazon.com",
        "www.apple.com",
        "cdn.jsdelivr.net",
        "st.ozone.ru",
        "ya.ru",
        "habr.com",
        "www.cloudflare.com",
        "addons.mozilla.org",
    ];
    let targets: Vec<String> = if custom.is_empty() {
        default_domains.iter().map(|s| s.to_string()).collect()
    } else {
        custom
    };

    let mut handles = Vec::new();
    for dom in targets.into_iter().take(24) {
        handles.push(tokio::spawn(async move {
            let clean = dom
                .trim()
                .trim_start_matches("https://")
                .trim_start_matches("http://")
                .split('/')
                .next()
                .unwrap_or(&dom)
                .to_string();
            let addr = format!("{clean}:443");
            let (got_sh, tls13, ms) = probe_tls_handshake(&addr, &clean, 1, 0).await;
            SniScanEntry {
                domain: clean,
                reachable: got_sh,
                latency_ms: if got_sh { ms } else { 9999 },
                tls13,
                recommended: got_sh && tls13 && ms < 180,
            }
        }));
    }

    let mut out = Vec::new();
    for h in handles {
        if let Ok(entry) = h.await {
            out.push(entry);
        }
    }
    out.sort_by_key(|e| e.latency_ms);
    out
}

/// Parallel Service Availability & Unlock Probe (`POST /api/diagnostics/unlock-probe`),
/// testing connectivity through local `service-mixed-in` when active (falling back to TLS probe if stopped).
pub async fn run_unlock_probe() -> Vec<UnlockProbeEntry> {
    let services = [
        ("YouTube", "Media", "www.youtube.com:443"),
        (
            "Google Video CDN",
            "Media",
            "rr1---sn-gvnuxaxjvh-n8me.googlevideo.com:443",
        ),
        ("Discord", "VoIP & Chat", "discord.com:443"),
        ("Telegram Web", "VoIP & Chat", "web.telegram.org:443"),
        ("OpenAI / ChatGPT", "AI", "chatgpt.com:443"),
        ("Claude / Anthropic", "AI", "claude.ai:443"),
        ("Qwen", "AI", "chat.qwen.ai:443"),
        ("Kimi", "AI", "kimi.com:443"),
        ("Kick", "Media", "kick.com:443"),
        ("GitHub", "Dev", "github.com:443"),
        ("Docker Hub", "Dev", "hub.docker.com:443"),
        ("Vercel", "Dev", "vercel.com:443"),
        ("Cloudflare", "CDN", "www.cloudflare.com:443"),
        ("Steam", "Gaming", "store.steampowered.com:443"),
    ];
    let mixed_port = read_service_mixed_in_port();
    let proxy_listening = tokio::time::timeout(
        Duration::from_millis(300),
        TcpStream::connect(("127.0.0.1", mixed_port)),
    )
    .await
    .is_ok_and(|r| r.is_ok());
    let proxy_url = format!("http://127.0.0.1:{mixed_port}");

    let mut handles = Vec::new();
    for (service, category, addr) in services {
        let px = proxy_url.clone();
        handles.push(tokio::spawn(async move {
            let host = crate::config_gen::extract_host_only(addr);
            let (ok, latency_ms) = if proxy_listening {
                let start = Instant::now();
                let mut cmd = Command::new("curl");
                cmd.kill_on_drop(true).args([
                    "-sS",
                    "-o",
                    "/dev/null",
                    "-w",
                    "%{http_code}",
                    "--connect-timeout",
                    "3",
                    "--max-time",
                    "5",
                    "-x",
                    &px,
                    &format!("https://{host}/"),
                ]);
                let curl_ok = tokio::time::timeout(Duration::from_secs(6), cmd.output())
                    .await
                    .ok()
                    .and_then(|r| r.ok())
                    .is_some_and(|out| {
                        out.status.success()
                            && String::from_utf8_lossy(&out.stdout)
                                .trim()
                                .parse::<u16>()
                                .is_ok_and(|code| (200..500).contains(&code))
                    });
                if curl_ok {
                    (true, start.elapsed().as_millis().max(1) as u32)
                } else {
                    (false, 0)
                }
            } else {
                let (got_sh, _, ms) = probe_tls_handshake(addr, &host, 1, 0).await;
                (got_sh, if got_sh { ms } else { 0 })
            };
            UnlockProbeEntry {
                service: service.to_string(),
                category: category.to_string(),
                host,
                reachable: ok,
                latency_ms,
            }
        }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(e) = h.await {
            out.push(e);
        }
    }
    out
}

struct RouteTraceInput<'a> {
    d: &'a RouterStoreData,
    client_ip: &'a str,
    domain: &'a str,
    target_or_ip: &'a str,
    port: u16,
    protocol: &'a str,
    nft_active: bool,
    wan6_available: bool,
    mac_table: &'a MacIpTable,
}

/// Build the unified 7-stage routing explanation JSON used by CLI, RPC (`trace_rules`/`route_explain`), and HTTP API.
pub fn build_route_trace_json(
    d: &RouterStoreData,
    client_ip: &str,
    domain: &str,
    target_or_ip: &str,
    port: u16,
    protocol: &str,
    nft_active: bool,
) -> Value {
    let mac_table = load_system_mac_ip_table();
    let (_lan_v6, wan_v6, _) = crate::sys_info::detect_router_ipv6_ips();
    build_route_trace_json_with_mac_table(&RouteTraceInput {
        d,
        client_ip,
        domain,
        target_or_ip,
        port,
        protocol,
        nft_active,
        wan6_available: !wan_v6.is_empty(),
        mac_table: &mac_table,
    })
}

/// Async variant of [`build_route_trace_json`] using non-blocking Tokio file reads.
pub async fn build_route_trace_json_async(
    d: &RouterStoreData,
    client_ip: &str,
    domain: &str,
    target_or_ip: &str,
    port: u16,
    protocol: &str,
    nft_active: bool,
) -> Value {
    let (mac_table, v6_res) = tokio::join!(
        load_system_mac_ip_table_async(),
        tokio::task::spawn_blocking(crate::sys_info::detect_router_ipv6_ips),
    );
    let (_lan_v6, wan_v6, _) = v6_res.unwrap_or_default();
    build_route_trace_json_with_mac_table(&RouteTraceInput {
        d,
        client_ip,
        domain,
        target_or_ip,
        port,
        protocol,
        nft_active,
        wan6_available: !wan_v6.is_empty(),
        mac_table: &mac_table,
    })
}

fn build_route_trace_json_with_mac_table(input: &RouteTraceInput<'_>) -> Value {
    let RouteTraceInput {
        d,
        client_ip,
        domain,
        target_or_ip,
        port,
        protocol,
        nft_active,
        wan6_available,
        mac_table,
    } = *input;
    let effective_target = if !domain.trim().is_empty() {
        domain.trim()
    } else if !target_or_ip.trim().is_empty() {
        target_or_ip.trim()
    } else {
        "example.com"
    };
    let client_mac = mac_table.resolve_client_mac(client_ip);
    let tr =
        explain_route_with_mac_table(d, client_ip, effective_target, port, protocol, mac_table);
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&d.settings, wan6_available);
    let runtime_dns_strategy = crate::store::effective_dns_strategy(&d.settings, ipv6_state);
    let is_direct = tr.selected_outbound.eq_ignore_ascii_case("direct");
    let is_block = tr.selected_outbound.eq_ignore_ascii_case("block")
        || tr.connection_type.eq_ignore_ascii_case("block");
    let verdict = if is_block {
        "block"
    } else if is_direct {
        "direct"
    } else {
        "proxied"
    };
    let action_str = if is_block {
        "block"
    } else if is_direct {
        "direct"
    } else {
        "proxy"
    };

    let matched_sec = d.sections.iter().find(|s| s.id == tr.matched_section_id);
    let sec_src = matched_sec
        .and_then(|s| s.outbound_source_refs.first())
        .and_then(|ref_id| d.outbound_sources.iter().find(|o| &o.id == ref_id));
    let fallback_src = sec_src.or_else(|| d.outbound_sources.first());
    let is_desync = tr.connection_type.eq_ignore_ascii_case("desync");
    let srv_addr = if is_desync {
        effective_target
    } else {
        fallback_src
            .map(|s| s.server.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("127.0.0.1")
    };
    let srv_port = if is_desync {
        tr.port
    } else {
        fallback_src.map(|s| s.server_port).unwrap_or(443)
    };
    let srv_proto = if is_desync {
        "desync"
    } else if is_direct {
        "direct"
    } else if is_block {
        "block"
    } else {
        fallback_src
            .map(|s| s.source_type.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(&tr.connection_type)
    };

    let is_tproxy = d.settings.proxy_mode == "tproxy";
    let intercepted = is_tproxy && nft_active && !is_direct;
    let nft_action = if d.settings.proxy_mode == "socks" {
        "socks"
    } else if !nft_active {
        "nft_inactive"
    } else if is_direct {
        "accept"
    } else if is_block {
        "reject"
    } else {
        "tproxy"
    };
    let en = is_en_lang(&d.settings.lang);
    let nft_details = if d.settings.proxy_mode == "socks" {
        if en {
            "SOCKS/Mixed mode active; nftables table is not used"
        } else {
            "Активен режим SOCKS/Mixed; таблица nftables не используется"
        }
    } else if !nft_active {
        if en {
            "Table inet TachyonTable is not loaded in kernel (traffic goes directly via WAN)"
        } else {
            "Таблица inet TachyonTable не загружена в ядро (трафик идёт напрямую через WAN)"
        }
    } else if is_direct {
        if en {
            "Direct/bypass section; packet bypassed TProxy"
        } else {
            "Секция direct/bypass; пакет пропущен в обход TProxy"
        }
    } else if en {
        "Packet redirected to tproxy :1602 with fwmark 0x04000000"
    } else {
        "Пакет направлен в tproxy :1602 с меткой 0x04000000"
    };
    let is_ip_target = tr.target.chars().all(|c| c.is_ascii_digit() || c == '.');
    let inbound_tag = if d.settings.proxy_mode == "socks" {
        "mixed-in"
    } else {
        "tproxy-in"
    };
    let fakeip_range_trace = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        d.settings.fakeip_inet4_range.trim()
    };

    json!({
        "success": true,
        "verdict": verdict,
        "action": action_str,
        "engine": "tachyon-core",
        "target": tr.target,
        "client": client_ip,
        "client_ip": tr.client_ip,
        "domain": domain,
        "dest_ip": if target_or_ip != domain { target_or_ip } else { "" },
        "source_ip": client_ip,
        "protocol": tr.protocol,
        "proto": tr.protocol,
        "port": tr.port,
        "rule_matched": tr.matched_condition_id,
        "matched_rule": {
            "type": "condition",
            "value": tr.matched_condition_id,
            "section": tr.matched_section,
            "action": action_str
        },
        "section": tr.matched_section,
        "matched_section_id": tr.matched_section_id,
        "matched_section_label": tr.matched_section_label,
        "matched_section": tr.matched_section,
        "matched_condition_id": tr.matched_condition_id,
        "matched_reason": tr.matched_reason,
        "outbound": tr.selected_outbound,
        "outbound_label": tr.selected_outbound,
        "resolved_outbound": tr.resolved_outbound,
        "selected_outbound": tr.selected_outbound,
        "dns_strategy": tr.dns_strategy,
        "runtime_dns_strategy": runtime_dns_strategy,
        "ipv6_effective_state": ipv6_state.as_str(),
        "connection_type": tr.connection_type,
        "reason": tr.matched_reason,
        "query": {
            "client": client_ip,
            "client_mac": client_mac,
            "target": tr.target,
            "target_type": if is_ip_target { "ip" } else { "domain" },
            "port": tr.port,
            "proto": tr.protocol
        },
        "stages": {
            "1_client_classification": {
                "stage": 1,
                "name": if en { "Client Classification" } else { "Классификация клиента" },
                "client": client_ip,
                "ip": client_ip,
                "client_type": "lan",
                "is_excluded": false,
                "details": if en {
                    format!("LAN client {client_ip} is included in routing")
                } else {
                    format!("Клиент локальной сети {client_ip} включен в обработку")
                }
            },
            "2_target_classification": {
                "stage": 2,
                "name": if en { "Target Classification" } else { "Классификация назначения" },
                "target": tr.target,
                "target_type": if is_ip_target { "ip" } else { "domain" },
                "port": tr.port,
                "proto": tr.protocol,
                "is_private_ip": false,
                "is_fakeip": d.settings.fakeip_enabled && !is_ip_target,
                "details": if en {
                    format!("Target {}:{} ({})", tr.target, tr.port, tr.protocol.to_uppercase())
                } else {
                    format!("Назначение {}:{} ({})", tr.target, tr.port, tr.protocol.to_uppercase())
                }
            },
            "3_section_matching": {
                "stage": 3,
                "name": if en { "Section Rules Matching" } else { "Сопоставление правил секции" },
                "matched_section": tr.matched_section,
                "section_label": tr.matched_section,
                "action": action_str,
                "rule_type": "condition",
                "rule_value": tr.matched_condition_id,
                "details": tr.matched_reason
            },
            "4_dns_decision": {
                "stage": 4,
                "name": if en { "DNS / FakeIP Decision" } else { "Решение DNS / FakeIP" },
                "mode": if d.settings.fakeip_enabled { "fakeip" } else { "realip" },
                "resolver": d.settings.dns_type,
                "fakeip_active": d.settings.fakeip_enabled,
                "ipv6_effective_state": ipv6_state.as_str(),
                "runtime_dns_strategy": runtime_dns_strategy,
                "details": if d.settings.fakeip_enabled {
                    if en {
                        format!("Domain matched through FakeIP table ({fakeip_range_trace})")
                    } else {
                        format!("Домен сопоставлен через таблицу FakeIP ({fakeip_range_trace})")
                    }
                } else if en {
                    "Real IP name resolution without FakeIP substitution".to_string()
                } else {
                    "Используется реальное разрешение имён без подмены FakeIP".to_string()
                }
            },
            "5_nftables_interception": {
                "stage": 5,
                "name": if en { "nftables Interception" } else { "Перехват nftables" },
                "table": "inet TachyonTable",
                "chain": "prerouting",
                "hook": "prerouting",
                "intercepted": intercepted,
                "fwmark": crate::net_stack::TPROXY_FWMARK,
                "action": nft_action,
                "details": nft_details
            },
            "6_policy_routing": {
                "stage": 6,
                "name": if en { "Policy Routing (PBR)" } else { "Политика маршрутизации (PBR)" },
                "table": crate::net_stack::TPROXY_ROUTE_TABLE,
                "ip_rule": format!("fwmark {} table {}", crate::net_stack::TPROXY_FWMARK, crate::net_stack::TPROXY_ROUTE_TABLE),
                "route": "local 0.0.0.0/0 dev lo",
                "details": if nft_active {
                    if en {
                        "Routing table 100 delivers the packet to Tachyon Core socket (:1602)"
                    } else {
                        "Таблица маршрутизации 100 доставляет пакет в сокет Tachyon Core (:1602)"
                    }
                } else if en {
                    "PBR policy inactive — TachyonTable is not loaded"
                } else {
                    "Политика PBR неактивна — таблица TachyonTable не загружена"
                }
            },
            "7_engine_outbound": {
                "stage": 7,
                "name": if en { "Core Outbound Node" } else { "Исходящий узел ядра" },
                "engine": "tachyon-core",
                "engaged": nft_active || !is_tproxy,
                "inbound_tag": inbound_tag,
                "group_tag": tr.matched_section,
                "group_type": "selector",
                "outbound_tag": tr.selected_outbound,
                "selected_node": tr.selected_outbound,
                "node_type": srv_proto,
                "server_address": srv_addr,
                "server_port": srv_port,
                "transport": tr.protocol,
                "details": if en {
                    format!("Traffic routed via {} ({})", tr.selected_outbound, srv_proto.to_uppercase())
                } else {
                    format!("Трафик отправлен через узел {} ({})", tr.selected_outbound, srv_proto.to_uppercase())
                }
            }
        },
        "explanation": {
            "ru": format!(
                "Трафик от {client_ip} к {}:{} ({}) попал в секцию '{}' ({}) и направлен через '{}'.",
                tr.target, tr.port, tr.protocol.to_uppercase(), tr.matched_section, tr.matched_reason, tr.selected_outbound
            ),
            "en": format!(
                "Traffic from {client_ip} to {}:{} ({}) matched section '{}' ({}) and routed via '{}'.",
                tr.target, tr.port, tr.protocol.to_uppercase(), tr.matched_section, tr.matched_reason, tr.selected_outbound
            )
        },
        "trace_steps": tr.trace_steps,
        "steps": [
            { "stage": "ingress", "detail": format!("{} {}:{}", tr.protocol.to_uppercase(), tr.target, tr.port), "matched": true },
            { "stage": "rule", "detail": tr.matched_condition_id, "matched": true },
            { "stage": "outbound", "detail": tr.selected_outbound, "matched": true }
        ]
    })
}

/// Explain packet route + live `tachyon-core` `/tachyon/route-check` dual probe (`outbound_probe` vs `direct_probe`).
pub async fn explain_route_with_engine(
    core: &Arc<CoreManager>,
    store: &RouterStoreData,
    client_ip: &str,
    target: &str,
    port: u16,
    protocol: &str,
) -> Value {
    let nft_active = crate::net_stack::check_nft_table_active().await;
    let mut out =
        build_route_trace_json_async(store, client_ip, target, target, port, protocol, nft_active)
            .await;
    let req_body = json!({
        "target": target,
        "port": port,
        "network": protocol,
        "source_ip": client_ip,
        "probe": true,
        "timeout": 3500
    })
    .to_string();
    if let Ok(engine_res) = core
        .clash_request("POST", "/tachyon/route-check", Some(&req_body))
        .await
        && engine_res.get("ok").is_some()
    {
        out["engine_route_check"] = engine_res;
    }
    out
}

/// DNS spoofing/bogon check via `tachyon-core` `POST /tachyon/dns-check`.
pub async fn run_dns_check_with_engine(core: &Arc<CoreManager>, domain: &str) -> Value {
    let target = if domain.trim().is_empty() {
        "www.youtube.com"
    } else {
        domain.trim()
    };
    let body = json!({ "domain": target, "timeout": 3500 }).to_string();
    core.clash_request("POST", "/tachyon/dns-check", Some(&body))
        .await
        .unwrap_or_else(|e| json!({"ok": false, "domain": target, "error": e.to_string()}))
}

/// Run safe router network tools (`ping`, `traceroute`, `nslookup`, `pcap`) for Diagnostics (`Этап 7.7`).
pub async fn run_network_tool(tool: &str, target: &str) -> Value {
    let clean_target: String = target
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'))
        .take(64)
        .collect();
    let host = if clean_target.is_empty() {
        "1.1.1.1".to_string()
    } else {
        clean_target
    };

    let (bin, args): (&str, Vec<&str>) = match tool {
        "traceroute" => {
            if cfg!(windows) {
                ("tracert", vec!["-d", "-h", "12", "-w", "800", &host])
            } else {
                ("traceroute", vec!["-n", "-m", "12", "-w", "1", &host])
            }
        }
        "nslookup" => ("nslookup", vec![&host, "127.0.0.42"]),
        "pcap" | "tcpdump" => {
            if cfg!(windows) {
                ("netstat", vec!["-an"])
            } else {
                ("tcpdump", vec!["-ni", "br-lan", "-c", "20", "port", "443"])
            }
        }
        _ => {
            if cfg!(windows) {
                ("ping", vec!["-n", "4", "-w", "1000", &host])
            } else {
                ("ping", vec!["-c", "4", "-W", "1", &host])
            }
        }
    };

    match tokio::time::timeout(
        Duration::from_secs(8),
        Command::new(bin).args(&args).output(),
    )
    .await
    {
        Ok(Ok(out)) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            let combined = if stderr.trim().is_empty() {
                stdout.to_string()
            } else {
                format!("{stdout}\n{stderr}")
            };
            json!({
                "ok": out.status.success(),
                "tool": tool,
                "target": host,
                "output": combined.trim()
            })
        }
        _ => json!({
            "ok": false,
            "tool": tool,
            "target": host,
            "output": format!("Утилита '{bin}' недоступна или превышено время ожидания")
        }),
    }
}

pub(crate) fn build_ipv6_leak_summary(
    d: &RouterStoreData,
    ipv6_state: crate::store::EffectiveIpv6State,
    wan_v6: &str,
    proxy_ipv6: &str,
    nft_table_active: bool,
) -> Value {
    let wan6_available = !wan_v6.is_empty();
    let nft_leak_guard_present = nft_table_active && ipv6_state.is_leak_guard();
    let ipv6_leaked = d.settings.ipv6_leak_guard
        && ipv6_state.is_leak_guard()
        && wan6_available
        && !nft_table_active;
    json!({
        "direct_ipv6": wan_v6,
        "proxy_ipv6": proxy_ipv6,
        "ipv6_leak_guard": d.settings.ipv6_leak_guard,
        "ipv6_leaked": ipv6_leaked,
        "ipv6_effective_state": ipv6_state.as_str(),
        "ipv6_mode": d.settings.ipv6_mode,
        "wan6_available": wan6_available,
        "nft_leak_guard_present": nft_leak_guard_present,
    })
}

/// DNS Leak, IPv4/IPv6, WebRTC STUN & FakeIP pipeline verification (`POST /api/diagnostics/leak-check`),
/// delegating directly to `tachyon-core` `POST /tachyon/leak`.
pub async fn run_leak_check(state: &Arc<AppState>, core: Option<&Arc<CoreManager>>) -> Value {
    let d = Box::new(state.data.read().await.clone());
    let live = state.live.read().await.clone();
    let (_lan_v6, wan_v6, _prefixes_v6) =
        tokio::task::spawn_blocking(crate::sys_info::detect_router_ipv6_ips)
            .await
            .unwrap_or_default();
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&d.settings, !wan_v6.is_empty());
    let eff_dns = crate::store::effective_dns_strategy(&d.settings, ipv6_state);
    let fakeip_v4 = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15".to_string()
    } else {
        d.settings.fakeip_inet4_range.trim().to_string()
    };
    let fakeip_v6 = if d.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18".to_string()
    } else {
        d.settings.fakeip_inet6_range.trim().to_string()
    };
    let dns_port_open = tokio::time::timeout(
        Duration::from_millis(600),
        TcpStream::connect("127.0.0.42:53"),
    )
    .await
    .is_ok();

    let engine_leak = if let Some(c) = core {
        c.clash_request("POST", "/tachyon/leak", Some("{}"))
            .await
            .ok()
    } else {
        None
    };

    let direct_ipv6 = wan_v6.clone();
    let proxy_ipv6 = if ipv6_state.is_active() && live.core_running {
        d.outbound_sources
            .iter()
            .filter(|s| s.enabled)
            .find_map(|s| {
                let host = if !s.server.trim().is_empty() {
                    crate::config_gen::extract_host_only(&s.server)
                } else {
                    s.cached_nodes
                        .first()
                        .map(|n| crate::config_gen::extract_host_only(&n.server))
                        .unwrap_or_default()
                };
                host.parse::<std::net::Ipv6Addr>()
                    .ok()
                    .map(|ip| ip.to_string())
            })
            .unwrap_or_default()
    } else {
        String::new()
    };
    let ipv6_leak = build_ipv6_leak_summary(
        &d,
        ipv6_state,
        &direct_ipv6,
        &proxy_ipv6,
        live.nft_table_active,
    );
    let ipv6_leaked = ipv6_leak
        .get("ipv6_leaked")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let en = is_en_lang(&d.settings.lang);
    let tg_en = is_en_lang(&d.telegram.language);
    if ipv6_leaked {
        crate::tg_bot::notify_if_enabled(
            &d,
            "dns_leak",
            if tg_en {
                "IPv6 direct routing leak risk detected while nftables table is inactive"
            } else {
                "Обнаружен риск прямой маршрутизации IPv6 при неактивной таблице nftables"
            },
        );
    } else if live.core_running && !dns_port_open {
        crate::tg_bot::notify_if_enabled(
            &d,
            "dns_leak",
            if tg_en {
                "Core local DNS resolver 127.0.0.42:53 is unreachable — DNS leak risk"
            } else {
                "Локальный DNS-резолвер ядра 127.0.0.42:53 не отвечает — возможна утечка DNS"
            },
        );
    }

    let verdict = if !live.core_running {
        if en {
            "Core is stopped — router system DNS is active".to_string()
        } else {
            "Ядро остановлено — используется системный DNS роутера".to_string()
        }
    } else if ipv6_leaked {
        if en {
            "IPv6 direct routing leak risk detected while nftables table is disabled".to_string()
        } else {
            "Обнаружен риск прямой маршрутизации IPv6 при отключённой таблице nftables".to_string()
        }
    } else if d.settings.fakeip_enabled && ipv6_state.is_tunnel_over_v4() {
        if en {
            format!(
                "FakeIP protection ({fakeip_v4}, {fakeip_v6}), IPv6-over-IPv4 tunnel and WebRTC filter are active"
            )
        } else {
            format!(
                "Защита FakeIP ({fakeip_v4}, {fakeip_v6}), туннель IPv6-over-IPv4 и WebRTC-фильтр активны"
            )
        }
    } else if d.settings.fakeip_enabled && ipv6_state.is_active() {
        if en {
            format!(
                "FakeIP protection ({fakeip_v4}, {fakeip_v6}), IPv6 mode ({}) and WebRTC filter are active",
                ipv6_state.as_str()
            )
        } else {
            format!(
                "Защита FakeIP ({fakeip_v4}, {fakeip_v6}), режим IPv6 ({}) и WebRTC-фильтр активны",
                ipv6_state.as_str()
            )
        }
    } else if d.settings.fakeip_enabled {
        if en {
            format!(
                "FakeIP protection ({fakeip_v4}), AAAA suppression (NOERROR) and WebRTC STUN interception are active"
            )
        } else {
            format!(
                "Защита FakeIP ({fakeip_v4}), подавление AAAA (NOERROR) и перехват WebRTC STUN активны"
            )
        }
    } else if en {
        format!(
            "RealIP DNS ({eff_dns}), IPv6 mode ({}) and WebRTC STUN interception are active",
            ipv6_state.as_str()
        )
    } else {
        format!(
            "DNS RealIP ({eff_dns}), режим IPv6 ({}) и перехват WebRTC STUN активны",
            ipv6_state.as_str()
        )
    };

    json!({
        "ok": true,
        "core_running": live.core_running,
        "nft_table_active": live.nft_table_active,
        "fakeip_enabled": d.settings.fakeip_enabled,
        "fakeip_range": fakeip_v4,
        "fakeip_inet4_range": fakeip_v4,
        "fakeip_inet6_range": fakeip_v6,
        "dns_listener": "127.0.0.42:53",
        "dns_listener_reachable": dns_port_open || live.core_running,
        "dns_type": d.settings.dns_type,
        "dns_strategy": eff_dns,
        "dns_servers": d.settings.dns_servers,
        "bootstrap_dns": d.settings.bootstrap_dns_servers,
        "webrtc_leak_protect": d.settings.webrtc_leak_protect,
        "block_doh": d.settings.block_doh,
        "ipv6_mode": d.settings.ipv6_mode,
        "ipv6_effective_state": ipv6_state.as_str(),
        "ipv6_leak_guard": d.settings.ipv6_leak_guard,
        "direct_ipv6": direct_ipv6,
        "proxy_ipv6": proxy_ipv6,
        "ipv6_leaked": ipv6_leaked,
        "ipv6_leak": ipv6_leak,
        "engine_leak_audit": engine_leak,
        "verdict": verdict
    })
}

/// Read active Linux kernel conntrack entries (`/proc/net/nf_conntrack`) for Monitoring.
pub fn read_router_conntrack(limit: usize) -> Vec<Value> {
    let raw = std::fs::read_to_string("/proc/net/nf_conntrack")
        .or_else(|_| std::fs::read_to_string("/proc/net/ip_conntrack"))
        .unwrap_or_default();
    let mut out = Vec::new();
    for (idx, line) in raw.lines().enumerate() {
        if out.len() >= limit {
            break;
        }
        let mut proto = "tcp";
        let mut src = "";
        let mut dst = "";
        let mut sport = "";
        let mut dport = "";
        let mut bytes: u64 = 0;

        for tok in line.split_whitespace() {
            if matches!(tok, "tcp" | "udp" | "icmp") {
                proto = tok;
            } else if let Some(v) = tok.strip_prefix("src=")
                && src.is_empty()
            {
                src = v;
            } else if let Some(v) = tok.strip_prefix("dst=")
                && dst.is_empty()
            {
                dst = v;
            } else if let Some(v) = tok.strip_prefix("sport=")
                && sport.is_empty()
            {
                sport = v;
            } else if let Some(v) = tok.strip_prefix("dport=")
                && dport.is_empty()
            {
                dport = v;
            } else if let Some(v) = tok.strip_prefix("bytes=") {
                bytes = bytes.saturating_add(v.parse::<u64>().unwrap_or(0));
            }
        }
        if src.is_empty() || dst.is_empty() || src == "127.0.0.1" || dst == "127.0.0.1" {
            continue;
        }
        out.push(json!({
            "id": format!("ct-{idx}"),
            "source": "conntrack",
            "network": proto,
            "client_ip": src,
            "client_port": sport,
            "target_host": dst,
            "target_port": dport,
            "chain": "kernel-conntrack",
            "rule": "nf_conntrack",
            "upload": bytes / 2,
            "download": bytes / 2,
        }));
    }
    out
}

/// Assemble a fully redacted Support Bundle JSON snapshot for sharing or AI Doctor analysis.
pub async fn build_support_bundle(state: &Arc<AppState>) -> Value {
    let raw_store = {
        let d = state.data.read().await;
        serde_json::to_value(&*d).unwrap_or_else(|_| json!({}))
    };
    let redacted_store = crypto_gen::redact_json_value(&raw_store);
    let doctor = run_local_doctor(state).await;
    let sys = sys_info::collect_host_info();
    let live = state.live.read().await;

    json!({
        "bundle_version": "2.0.0",
        "generated_at": unix_now_secs(),
        "system": sys,
        "doctor": doctor,
        "telemetry": {
            "core_running": live.core_running,
            "core_pid": live.core_pid,
            "core_version": live.core_version,
            "core_uptime_secs": live.core_uptime_secs,
            "core_rss_bytes": live.core_rss_bytes,
            "active_connections": live.active_connections,
            "nft_table_active": live.nft_table_active,
            "events": live.events,
            "recent_logs": live.recent_logs,
        },
        "config_redacted": redacted_store,
    })
}

fn skip_dns_name(buf: &[u8], mut pos: usize) -> Option<usize> {
    for _ in 0..128 {
        let &len = buf.get(pos)?;
        if len == 0 {
            return Some(pos + 1);
        }
        if (len & 0xC0) == 0xC0 {
            buf.get(pos + 1)?;
            return Some(pos + 2);
        }
        if (len & 0xC0) != 0 {
            return None;
        }
        pos = pos.checked_add(1 + (len as usize))?;
        if pos > buf.len() {
            return None;
        }
    }
    None
}

fn ipv4_in_cidr(ip: std::net::Ipv4Addr, cidr: &str) -> bool {
    let trimmed = cidr.trim();
    if let Some((ip_part, prefix_part)) = trimmed.split_once('/')
        && let (Ok(net), Ok(prefix)) = (
            ip_part.trim().parse::<std::net::Ipv4Addr>(),
            prefix_part.trim().parse::<u32>(),
        )
        && prefix <= 32
    {
        let mask = if prefix == 0 {
            0u32
        } else {
            u32::MAX << (32 - prefix)
        };
        return (u32::from(ip) & mask) == (u32::from(net) & mask);
    }
    let o = ip.octets();
    o[0] == 198 && (o[1] == 18 || o[1] == 19)
}

fn ipv6_in_cidr(ip: std::net::Ipv6Addr, cidr: &str) -> bool {
    if let Some((net, prefix)) = crate::store::parse_ipv6_cidr(cidr) {
        let mask = if prefix == 0 {
            0u128
        } else {
            u128::MAX << (128 - u32::from(prefix))
        };
        return (u128::from(ip) & mask) == (net & mask);
    }
    false
}

pub(crate) fn parse_dns_fakeip_response(
    buf: &[u8],
    expected_v4_cidr: &str,
    expected_v6_cidr: &str,
) -> (bool, String, u8) {
    if buf.len() < 12 {
        return (false, String::new(), 255);
    }
    let rcode = buf[3] & 0x0f;
    let qdcount = u16::from_be_bytes([buf[4], buf[5]]) as usize;
    let ancount = u16::from_be_bytes([buf[6], buf[7]]) as usize;
    if ancount == 0 {
        return (false, String::new(), rcode);
    }

    let mut pos = 12usize;
    for _ in 0..qdcount.min(32) {
        let Some(next) = skip_dns_name(buf, pos) else {
            return (false, String::new(), rcode);
        };
        let Some(after_q) = next.checked_add(4) else {
            return (false, String::new(), rcode);
        };
        if after_q > buf.len() {
            return (false, String::new(), rcode);
        }
        pos = after_q;
    }

    for _ in 0..ancount.min(32) {
        let Some(after_name) = skip_dns_name(buf, pos) else {
            return (false, String::new(), rcode);
        };
        let Some(hdr_end) = after_name.checked_add(10) else {
            return (false, String::new(), rcode);
        };
        let Some(hdr) = buf.get(after_name..hdr_end) else {
            return (false, String::new(), rcode);
        };
        let rtype = u16::from_be_bytes([hdr[0], hdr[1]]);
        let rdlength = u16::from_be_bytes([hdr[8], hdr[9]]) as usize;
        let Some(rdata_end) = hdr_end.checked_add(rdlength) else {
            return (false, String::new(), rcode);
        };
        let Some(rdata) = buf.get(hdr_end..rdata_end) else {
            return (false, String::new(), rcode);
        };
        if rtype == 1 && rdata.len() == 4 {
            let ip = std::net::Ipv4Addr::new(rdata[0], rdata[1], rdata[2], rdata[3]);
            return (ipv4_in_cidr(ip, expected_v4_cidr), ip.to_string(), rcode);
        }
        if rtype == 28 && rdata.len() == 16 {
            let mut octets = [0u8; 16];
            octets.copy_from_slice(rdata);
            let ip = std::net::Ipv6Addr::from(octets);
            return (ipv6_in_cidr(ip, expected_v6_cidr), ip.to_string(), rcode);
        }
        pos = rdata_end;
    }

    (false, String::new(), rcode)
}

#[cfg(test)]
pub(crate) fn parse_dns_a_response(buf: &[u8]) -> (bool, String) {
    let (ok, ip, _) = parse_dns_fakeip_response(buf, "198.18.0.0/15", "fc00::/18");
    (ok, ip)
}

pub(crate) fn build_dns_query_packet(domain: &str, qtype: u16) -> Option<Vec<u8>> {
    let clean = domain.trim().trim_end_matches('.');
    if clean.is_empty() || clean.len() > 253 {
        return None;
    }
    let mut pkt = Vec::with_capacity(clean.len() + 18);
    pkt.extend_from_slice(&[
        0x54, 0x43, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);
    for label in clean.split('.') {
        let bytes = label.as_bytes();
        if bytes.is_empty() || bytes.len() > 63 {
            return None;
        }
        pkt.push(bytes.len() as u8);
        pkt.extend_from_slice(bytes);
    }
    pkt.push(0x00);
    pkt.extend_from_slice(&qtype.to_be_bytes());
    pkt.extend_from_slice(&[0x00, 0x01]);
    Some(pkt)
}

async fn send_dns_probe(qtype_low: u8) -> Option<Vec<u8>> {
    let sock = tokio::net::UdpSocket::bind("127.0.0.1:0").await.ok()?;
    let query = build_dns_query_packet("probe.example.com", u16::from(qtype_low))?;
    tokio::time::timeout(
        Duration::from_millis(800),
        sock.send_to(&query, "127.0.0.42:53"),
    )
    .await
    .ok()?
    .ok()?;
    let mut resp = [0u8; 512];
    let (n, _) = tokio::time::timeout(Duration::from_millis(800), sock.recv_from(&mut resp))
        .await
        .ok()?
        .ok()?;
    Some(resp[..n].to_vec())
}

/// Probe the local FakeIP DNS listener (`127.0.0.42:53`) with A and AAAA queries
/// against configured FakeIP ranges. Returns `(v4_ok, v4_ip, v6_ok, v6_ip, aaaa_suppressed_noerror)`.
pub async fn probe_local_fakeip_dns_with(
    expected_v4_cidr: &str,
    expected_v6_cidr: &str,
    ipv6_active: bool,
) -> (bool, String, bool, String, bool) {
    let v4_cidr = if expected_v4_cidr.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        expected_v4_cidr.trim()
    };
    let v6_cidr = if expected_v6_cidr.trim().is_empty() {
        "fc00::/18"
    } else {
        expected_v6_cidr.trim()
    };

    let (v4_ok, v4_ip) = if let Some(resp) = send_dns_probe(0x01).await {
        let (ok, ip, _) = parse_dns_fakeip_response(&resp, v4_cidr, v6_cidr);
        (ok, ip)
    } else {
        (false, String::new())
    };

    let (v6_ok, v6_ip, aaaa_suppressed) = if let Some(resp) = send_dns_probe(0x1c).await {
        let (ok, ip, rcode) = parse_dns_fakeip_response(&resp, v4_cidr, v6_cidr);
        let suppressed = !ipv6_active && rcode == 0 && ip.is_empty();
        (ipv6_active && ok, ip, suppressed)
    } else {
        (false, String::new(), false)
    };

    (v4_ok, v4_ip, v6_ok, v6_ip, aaaa_suppressed)
}

fn resolve_check_proxy_inbound_url(cfg_path: &str) -> Option<String> {
    let raw = std::fs::read_to_string(cfg_path).ok()?;
    let val: Value = serde_json::from_str(&raw).ok()?;
    let inbounds = val.get("inbounds")?.as_array()?;

    let format_ep = |inb: &Value, default_port: u16| -> Option<String> {
        let tag = inb.get("tag").and_then(Value::as_str).unwrap_or("");
        if tag == "direct-bypass-in" {
            return None;
        }
        let ib_type = inb
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase();
        if !matches!(ib_type.as_str(), "mixed" | "http" | "socks")
            && tag != "service-mixed-in"
            && tag != "mixed-in"
        {
            return None;
        }
        let port = inb
            .get("listen_port")
            .and_then(Value::as_u64)
            .and_then(|p| u16::try_from(p).ok())
            .filter(|&p| p > 0)
            .unwrap_or(default_port);
        if port == 0 {
            return None;
        }
        let mut host = inb
            .get("listen")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if host.starts_with('[') && host.ends_with(']') && host.len() >= 2 {
            host = &host[1..host.len() - 1];
        }
        let connect_host = if host.is_empty() || host == "0.0.0.0" || host == "::" {
            "127.0.0.1"
        } else {
            host
        };
        let scheme = if ib_type == "socks" {
            "socks5h"
        } else {
            "http"
        };
        let bracketed = if connect_host.contains(':') {
            format!("[{connect_host}]")
        } else {
            connect_host.to_string()
        };
        Some(format!("{scheme}://{bracketed}:{port}"))
    };

    for inb in inbounds {
        let tag = inb.get("tag").and_then(Value::as_str).unwrap_or("");
        if (tag == "service-mixed-in" || tag == "mixed-in")
            && let Some(url) = format_ep(inb, 4534)
        {
            return Some(url);
        }
    }
    for pass_local in [true, false] {
        for inb in inbounds {
            let tag = inb.get("tag").and_then(Value::as_str).unwrap_or("");
            let has_auth = inb
                .get("users")
                .and_then(Value::as_array)
                .is_some_and(|u| !u.is_empty());
            if has_auth || tag.starts_with("server-") {
                continue;
            }
            if pass_local {
                let listen = inb
                    .get("listen")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                if !matches!(
                    listen,
                    "" | "127.0.0.1" | "::1" | "[::1]" | "0.0.0.0" | "::" | "[::]"
                ) {
                    continue;
                }
            }
            if let Some(url) = format_ep(inb, 0) {
                return Some(url);
            }
        }
    }
    None
}

pub(crate) fn mask_proxy_probe_ip(raw_output: &str) -> Option<String> {
    let mut ipv4_lines = Vec::new();
    let mut ipv6_lines = Vec::new();
    for raw_line in raw_output.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(ip) = line.parse::<std::net::IpAddr>() {
            match ip {
                std::net::IpAddr::V4(v4) => {
                    ipv4_lines.push(format!("X.X.X.{}", v4.octets()[3]));
                }
                std::net::IpAddr::V6(v6) => {
                    let segs = v6.segments();
                    let masked = format!(
                        "{:x}:{:x}:{:x}:{:x}:xxxx:xxxx:xxxx:xxxx",
                        segs[0], segs[1], segs[2], segs[3]
                    );
                    ipv6_lines.push(masked);
                }
            }
        }
    }
    if !ipv4_lines.is_empty() {
        return Some(ipv4_lines.join("\n"));
    }
    if !ipv6_lines.is_empty() {
        return Some(ipv6_lines.join("\n"));
    }
    None
}

pub(crate) fn is_retryable_proxy_probe_error(raw_output: &str) -> bool {
    let lower = raw_output.to_ascii_lowercase();
    lower.contains("rate limit")
        || lower.contains("too many requests")
        || lower.contains("429")
        || lower.contains("timeout")
        || lower.contains("temporarily unavailable")
}

/// Probe outbound proxy connectivity via `curl` through the active local mixed inbound (`check_proxy`).
pub async fn run_proxy_check_cli(d: &RouterStoreData, core_running: bool) -> (i32, String) {
    let cfg_path = std::env::var("TACHYON_CORE_CONFIG_PATH")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            if d.settings.core_config_path.trim().is_empty() {
                "/etc/tachyon-core/config.json".to_string()
            } else {
                d.settings.core_config_path.clone()
            }
        });
    let mut out_lines = vec![format!("Checking {cfg_path} configuration...")];
    let Some(proxy_url) = resolve_check_proxy_inbound_url(&cfg_path) else {
        out_lines.push("Local mixed proxy inbound not found".to_string());
        out_lines.push(format!(
            "Error: No local mixed inbound (service-mixed-in / mixed-in) configured in {cfg_path}"
        ));
        return (1, format!("{}\n", out_lines.join("\n")));
    };
    out_lines.push("Checking proxy connection...".to_string());
    if !core_running {
        out_lines.push("tachyon-core is not running".to_string());
        out_lines.push(format!(
            "Error: tachyon-core is not running (expected local mixed proxy at {proxy_url})"
        ));
        return (1, format!("{}\n", out_lines.join("\n")));
    }

    let probe_urls = [
        "https://ifconfig.me/ip",
        "https://api.ipify.org",
        "https://icanhazip.com",
    ];
    let mut last_error = String::new();
    for probe_url in probe_urls {
        let mut cmd = Command::new("curl");
        cmd.kill_on_drop(true).args([
            "-fsSL",
            "--connect-timeout",
            "5",
            "--max-time",
            "10",
            "--proxy",
            &proxy_url,
            probe_url,
        ]);
        match tokio::time::timeout(Duration::from_secs(12), cmd.output()).await {
            Ok(Ok(res)) => {
                let stdout_str = String::from_utf8_lossy(&res.stdout);
                let stderr_str = String::from_utf8_lossy(&res.stderr);
                let combined = if stderr_str.trim().is_empty() {
                    stdout_str.to_string()
                } else if stdout_str.trim().is_empty() {
                    stderr_str.to_string()
                } else {
                    format!("{stdout_str} | {stderr_str}")
                };
                let trimmed = combined.trim();
                if !res.status.success() {
                    last_error = if trimmed.is_empty() {
                        format!(
                            "curl exited with status {:?} for {probe_url}",
                            res.status.code()
                        )
                    } else {
                        trimmed.replace(['\r', '\n'], " | ")
                    };
                    continue;
                }
                if is_retryable_proxy_probe_error(&combined) {
                    let snippet: String = trimmed.chars().take(120).collect();
                    last_error = format!("Retryable error response from {probe_url}: {snippet}");
                    continue;
                }
                if let Some(masked) = mask_proxy_probe_ip(&stdout_str) {
                    out_lines.push(format!("{masked} - should match proxy IP"));
                    return (0, format!("{}\n", out_lines.join("\n")));
                }
                let snippet: String = trimmed.chars().take(200).collect();
                last_error = if snippet.is_empty() {
                    format!("Empty response from {probe_url}")
                } else {
                    format!("Invalid IP response from {probe_url}: {snippet}")
                };
            }
            Ok(Err(e)) => {
                last_error = format!("Failed to execute curl for {probe_url}: {e}");
            }
            Err(_) => {
                last_error = format!("Timed out probing {probe_url}");
            }
        }
    }
    out_lines.push(format!(
        "Failed to get valid IP address after {} attempts",
        probe_urls.len()
    ));
    out_lines.push(format!(
        "Error: {}",
        if last_error.is_empty() {
            "Empty response"
        } else {
            &last_error
        }
    ));
    (1, format!("{}\n", out_lines.join("\n")))
}

fn read_service_mixed_in_port() -> u16 {
    std::fs::read_to_string("/etc/tachyon-core/config.json")
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.get("inbounds").and_then(Value::as_array).cloned())
        .and_then(|arr| {
            arr.into_iter().find_map(|ib| {
                if ib.get("tag").and_then(Value::as_str) == Some("service-mixed-in") {
                    ib.get("listen_port")
                        .and_then(Value::as_u64)
                        .and_then(|p| u16::try_from(p).ok())
                        .filter(|&p| p > 0)
                } else {
                    None
                }
            })
        })
        .unwrap_or(4534)
}

fn read_fakeip_probe_proxy_port_from_str(raw: &str) -> u16 {
    let Some(v) = serde_json::from_str::<Value>(raw).ok() else {
        return 4534;
    };
    let Some(arr) = v.get("inbounds").and_then(Value::as_array) else {
        return 4534;
    };
    let port_for_tag = |tag: &str| {
        arr.iter().find_map(|ib| {
            if ib.get("tag").and_then(Value::as_str) == Some(tag) {
                ib.get("listen_port")
                    .and_then(Value::as_u64)
                    .and_then(|p| u16::try_from(p).ok())
                    .filter(|&p| p > 0)
            } else {
                None
            }
        })
    };
    if let Some(p) = port_for_tag("diag-proxy-in") {
        return p;
    }
    if let Some(p) = port_for_tag("tg-bot-in") {
        let tg_routed_to_proxy = v
            .get("route")
            .and_then(|r| r.get("rules"))
            .and_then(Value::as_array)
            .is_some_and(|rules| {
                rules.iter().any(|rule| {
                    rule.get("inbound")
                        .and_then(Value::as_array)
                        .is_some_and(|ibs| ibs.iter().any(|x| x.as_str() == Some("tg-bot-in")))
                        && rule
                            .get("outbound")
                            .and_then(Value::as_str)
                            .is_some_and(|o| {
                                o != "direct" && o != "block" && !o.starts_with("desync-")
                            })
                })
            });
        if tg_routed_to_proxy {
            return p;
        }
    }
    port_for_tag("service-mixed-in").unwrap_or(4534)
}

fn read_fakeip_probe_proxy_port(cfg_path: &str) -> u16 {
    let path = if cfg_path.trim().is_empty() {
        "/etc/tachyon-core/config.json"
    } else {
        cfg_path.trim()
    };
    std::fs::read_to_string(path)
        .map(|raw| read_fakeip_probe_proxy_port_from_str(&raw))
        .unwrap_or(4534)
}

fn extract_trace_ip(text: &str) -> Option<String> {
    text.lines().find_map(|line| {
        line.trim()
            .strip_prefix("ip=")
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    })
}

async fn run_curl_trace_ip(mut cmd: Command) -> Option<String> {
    cmd.kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(9), cmd.output())
        .await
        .ok()?
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let body = String::from_utf8_lossy(&out.stdout);
    extract_trace_ip(&body)
}

pub(crate) struct FakeIpProbePayloadInput<'a> {
    pub d: &'a RouterStoreData,
    pub ipv6_state: crate::store::EffectiveIpv6State,
    pub via_proxy: bool,
    pub v4_ok: bool,
    pub v4_ip: &'a str,
    pub v6_ok: bool,
    pub v6_ip: &'a str,
    pub aaaa_suppressed: bool,
}

pub(crate) fn format_fakeip_probe_payload(input: FakeIpProbePayloadInput<'_>) -> Value {
    let FakeIpProbePayloadInput {
        d,
        ipv6_state,
        via_proxy,
        v4_ok,
        v4_ip,
        v6_ok,
        v6_ip,
        aaaa_suppressed,
    } = input;
    let fakeip4 = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        d.settings.fakeip_inet4_range.trim()
    };
    let fakeip6 = if d.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        d.settings.fakeip_inet6_range.trim()
    };
    let ipv4_only = if v4_ip.contains(':') { "" } else { v4_ip };
    if via_proxy {
        json!({
            "fakeip": d.settings.fakeip_enabled && v4_ok,
            "fakeip_enabled": d.settings.fakeip_enabled,
            "fakeip_inet4_range": fakeip4,
            "fakeip_inet6_range": fakeip6,
            "fakeip_v4": v4_ok,
            "fakeip_v6": v6_ok,
            "aaaa_suppressed": aaaa_suppressed,
            "ipv6_effective_state": ipv6_state.as_str(),
            "IP": v4_ip,
            "IPv4": ipv4_only,
            "IPv6": v6_ip
        })
    } else {
        json!({
            "fakeip": false,
            "fakeip_enabled": d.settings.fakeip_enabled,
            "fakeip_inet4_range": fakeip4,
            "fakeip_inet6_range": fakeip6,
            "ipv6_effective_state": ipv6_state.as_str(),
            "IP": v4_ip,
            "IPv4": ipv4_only,
            "IPv6": v6_ip
        })
    }
}

/// Resolve effective directory for `.trs`/`.srs` rule lists without wearing NAND flash in `lite_mode`.
pub fn effective_rulesets_dir(settings: &crate::store::GlobalSettings) -> std::path::PathBuf {
    let raw = settings.rulesets_dir.trim();
    if settings.lite_mode && (raw.is_empty() || raw.starts_with("/etc/tachyon")) {
        return crate::store::runtime_state_dir().join("rulesets");
    }
    if raw.is_empty() {
        std::path::PathBuf::from("/etc/tachyon/rulesets")
    } else {
        std::path::PathBuf::from(raw)
    }
}

/// Periodic background tick for scheduled `.trs`/`.srs` rule-list updates.
/// Checks `list_update_enabled` and `update_interval`, downloading into `effective_rulesets_dir`.
pub async fn tick_list_updates_if_due(core: &Arc<CoreManager>) -> bool {
    crate::updater::run_list_updates_if_due(core).await
}

/// Self-contained FakeIP & public exit IP probe for frontend diagnostics.
pub async fn run_fakeip_probe(state: &Arc<AppState>, via_proxy: bool) -> Value {
    let d = Box::new(state.data.read().await.clone());
    let (_lan_v6, wan_v6, _) = tokio::task::spawn_blocking(crate::sys_info::detect_router_ipv6_ips)
        .await
        .unwrap_or_default();
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&d.settings, !wan_v6.is_empty());
    if via_proxy {
        let (v4_ok, _dns_ip, v6_ok, v6_ip, aaaa_suppressed) = probe_local_fakeip_dns_with(
            &d.settings.fakeip_inet4_range,
            &d.settings.fakeip_inet6_range,
            ipv6_state.is_active(),
        )
        .await;
        let port = read_fakeip_probe_proxy_port(&d.settings.core_config_path);
        let proxy_url = format!("http://127.0.0.1:{port}");
        let mut exit_ip = String::new();
        for url in [
            "https://cloudflare.com/cdn-cgi/trace",
            "https://1.1.1.1/cdn-cgi/trace",
        ] {
            let mut cmd = Command::new("curl");
            cmd.args([
                "-fsSL",
                "--connect-timeout",
                "5",
                "--max-time",
                "8",
                "-x",
                &proxy_url,
                url,
            ]);
            if let Some(ip) = run_curl_trace_ip(cmd).await
                && !ip.is_empty()
            {
                exit_ip = ip;
                break;
            }
        }
        format_fakeip_probe_payload(FakeIpProbePayloadInput {
            d: &d,
            ipv6_state,
            via_proxy: true,
            v4_ok,
            v4_ip: &exit_ip,
            v6_ok,
            v6_ip: &v6_ip,
            aaaa_suppressed,
        })
    } else {
        let mut cmd = Command::new("curl");
        cmd.args([
            "-fsSL",
            "--noproxy",
            "*",
            "--connect-timeout",
            "4",
            "--max-time",
            "7",
            "https://1.1.1.1/cdn-cgi/trace",
        ]);
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt as _;
            cmd.as_std_mut().gid(net_stack::DIRECT_PROBE_SKGID);
        }
        let direct_ip = run_curl_trace_ip(cmd).await.unwrap_or_default();
        format_fakeip_probe_payload(FakeIpProbePayloadInput {
            d: &d,
            ipv6_state,
            via_proxy: false,
            v4_ok: false,
            v4_ip: &direct_ip,
            v6_ok: false,
            v6_ip: &wan_v6,
            aaaa_suppressed: false,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{RoutingSection, TrafficCondition};

    #[test]
    fn route_trace_json_matches_main_telegram_and_reflects_nft_state() {
        let mut store = RouterStoreData::default();
        store.settings.fakeip_enabled = true;
        store.sections = vec![
            RoutingSection {
                id: "ByPass".to_string(),
                label: "ByPass".to_string(),
                enabled: true,
                action: "bypass".to_string(),
                connection_type: "direct".to_string(),
                condition_refs: vec!["cond_ByPass".to_string()],
                community_lists: vec!["russia_outside".to_string()],
                ..Default::default()
            },
            RoutingSection {
                id: "Main".to_string(),
                label: "Main".to_string(),
                enabled: true,
                action: "proxy".to_string(),
                connection_type: "vless".to_string(),
                condition_refs: vec!["cond_Main".to_string()],
                outbound_source_refs: vec!["sub_1".to_string()],
                ..Default::default()
            },
        ];
        store.conditions = vec![
            TrafficCondition {
                id: "cond_ByPass".to_string(),
                enabled: true,
                name: "cond_ByPass".to_string(),
                condition_type: "atomic".to_string(),
                community_lists: vec!["russia_outside".to_string()],
                ..Default::default()
            },
            TrafficCondition {
                id: "cond_Main".to_string(),
                enabled: true,
                name: "cond_Main".to_string(),
                condition_type: "atomic".to_string(),
                community_lists: vec!["telegram".to_string()],
                ..Default::default()
            },
        ];

        let active = build_route_trace_json(&store, "192.168.1.100", "t.me", "", 443, "tcp", true);
        assert_eq!(active["verdict"], "proxied");
        assert_eq!(active["action"], "proxy");
        assert_eq!(active["matched_section"], "Main");
        assert_eq!(
            active["stages"]["5_nftables_interception"]["intercepted"],
            true
        );
        assert_eq!(
            active["stages"]["5_nftables_interception"]["action"],
            "tproxy"
        );

        let inactive =
            build_route_trace_json(&store, "192.168.1.100", "t.me", "", 443, "tcp", false);
        assert_eq!(inactive["verdict"], "proxied");
        assert_eq!(
            inactive["stages"]["5_nftables_interception"]["intercepted"],
            false
        );
        assert_eq!(
            inactive["stages"]["5_nftables_interception"]["action"],
            "nft_inactive"
        );
    }

    #[test]
    fn test_parse_firewall_flow_offloading() {
        let sw_only = r#"
config defaults
	option syn_flood '1'
	option flow_offloading '1'
	option flow_offloading_hw '0'

config zone
	option name 'wan'
"#;
        assert_eq!(parse_firewall_flow_offloading(sw_only), (true, false));

        let both_hw = r#"
config defaults
	option flow_offloading '1'
	option flow_offloading_hw '1'
"#;
        assert_eq!(parse_firewall_flow_offloading(both_hw), (true, true));

        let zone_decoy_only = r#"
config defaults
	option flow_offloading '0'

config zone
	option name 'lan'
	option flow_offloading '1'
	option flow_offloading_hw '1'
"#;
        assert_eq!(
            parse_firewall_flow_offloading(zone_decoy_only),
            (false, false)
        );
    }

    #[test]
    fn test_parse_dns_a_response_valid_normal_and_truncated() {
        // FakeIP 198.18.0.25 with compressed answer name (0xC0 0x0C) for `probe.example.com`
        let fakeip_pkt: &[u8] = &[
            0x54, 0x43, 0x81, 0x80, // Header: ID, QR=1, RD=1, RA=1
            0x00, 0x01, 0x00, 0x01, // QDCOUNT=1, ANCOUNT=1
            0x00, 0x00, 0x00, 0x00, // NSCOUNT=0, ARCOUNT=0
            5, b'p', b'r', b'o', b'b', b'e', 7, b'e', b'x', b'a', b'm', b'p', b'l', b'e', 3, b'c',
            b'o', b'm', 0, // QNAME
            0x00, 0x01, 0x00, 0x01, // QTYPE=A, QCLASS=IN
            0xC0, 0x0C, // Answer NAME pointer to offset 12
            0x00, 0x01, 0x00, 0x01, // TYPE=A, CLASS=IN
            0x00, 0x00, 0x00, 0x3C, // TTL=60
            0x00, 0x04, // RDLENGTH=4
            198, 18, 0, 25, // RDATA=198.18.0.25
        ];
        assert_eq!(
            parse_dns_a_response(fakeip_pkt),
            (true, "198.18.0.25".to_string())
        );

        // Normal public IP 93.184.216.34
        let mut normal_pkt = fakeip_pkt.to_vec();
        let n = normal_pkt.len();
        normal_pkt[n - 4..n].copy_from_slice(&[93, 184, 216, 34]);
        assert_eq!(
            parse_dns_a_response(&normal_pkt),
            (false, "93.184.216.34".to_string())
        );

        // Truncated packets must return safely without panics
        assert_eq!(
            parse_dns_a_response(&fakeip_pkt[..8]),
            (false, String::new())
        );
        assert_eq!(
            parse_dns_a_response(&fakeip_pkt[..fakeip_pkt.len() - 2]),
            (false, String::new())
        );
    }

    #[test]
    fn test_parse_dns_fakeip_response_aaaa_and_noerror_suppression() {
        // FakeIPv6 fc00::19 (AAAA rtype=28)
        let aaaa_fakeip: &[u8] = &[
            0x54, 0x43, 0x81, 0x80, // QR=1, RCODE=0
            0x00, 0x01, 0x00, 0x01, // QD=1, AN=1
            0x00, 0x00, 0x00, 0x00, //
            5, b'p', b'r', b'o', b'b', b'e', 7, b'e', b'x', b'a', b'm', b'p', b'l', b'e', 3, b'c',
            b'o', b'm', 0, //
            0x00, 0x1c, 0x00, 0x01, // QTYPE=AAAA
            0xC0, 0x0C, // ptr
            0x00, 0x1c, 0x00, 0x01, // TYPE=AAAA
            0x00, 0x00, 0x00, 0x3C, // TTL
            0x00, 0x10, // RDLENGTH=16
            0xfc, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x19, // fc00::19
        ];
        assert_eq!(
            parse_dns_fakeip_response(aaaa_fakeip, "198.18.0.0/15", "fc00::/18"),
            (true, "fc00::19".to_string(), 0)
        );

        // Public AAAA 2001:4860:4860::8888 is not FakeIP
        let mut aaaa_pub = aaaa_fakeip.to_vec();
        let n = aaaa_pub.len();
        aaaa_pub[n - 16..n].copy_from_slice(&[
            0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88,
        ]);
        assert_eq!(
            parse_dns_fakeip_response(&aaaa_pub, "198.18.0.0/15", "fc00::/18"),
            (false, "2001:4860:4860::8888".to_string(), 0)
        );

        // Suppressed AAAA: predefined NOERROR (rcode=0, ancount=0)
        let aaaa_noerror: &[u8] = &[
            0x54, 0x43, 0x81, 0x80, // QR=1, RCODE=0
            0x00, 0x01, 0x00, 0x00, // QD=1, AN=0
            0x00, 0x00, 0x00, 0x00, //
            5, b'p', b'r', b'o', b'b', b'e', 7, b'e', b'x', b'a', b'm', b'p', b'l', b'e', 3, b'c',
            b'o', b'm', 0, //
            0x00, 0x1c, 0x00, 0x01, //
        ];
        assert_eq!(
            parse_dns_fakeip_response(aaaa_noerror, "198.18.0.0/15", "fc00::/18"),
            (false, String::new(), 0)
        );
    }

    #[test]
    fn test_evaluate_odhcpd_ipv6_dns() {
        assert!(evaluate_odhcpd_ipv6_dns("", false).0);

        let no_dns = r#"
config dhcp 'lan'
	option interface 'lan'
	option dhcpv6 'server'
	option ra 'server'
	option ra_dns '0'
"#;
        assert!(!evaluate_odhcpd_ipv6_dns(no_dns, true).0);

        let with_ra_dns = r#"
config dhcp 'lan'
	option dhcpv6 'server'
	option ra_dns '1'
"#;
        assert!(evaluate_odhcpd_ipv6_dns(with_ra_dns, true).0);

        let with_dns_list = r#"
config dhcp 'lan'
	option dhcpv6 'server'
	list dns 'fd00::1'
"#;
        assert!(evaluate_odhcpd_ipv6_dns(with_dns_list, true).0);
    }

    #[test]
    fn test_source_macs_resolution_and_route_trace_fields() {
        let arp = "\
IP address       HW type     Flags       HW address            Mask     Device
192.168.1.50     0x1         0x2         AA:BB:CC:DD:EE:FF     *        br-lan
";
        let leases = "1700000000 11:22:33:44:55:66 192.168.1.77 laptop *";
        let table = parse_mac_ip_table(arp, leases);

        let mut store = RouterStoreData::default();
        store.settings.ipv6_mode = "auto".to_string();
        store.sections = vec![RoutingSection {
            id: "MacSec".to_string(),
            label: "MacSec".to_string(),
            enabled: true,
            action: "proxy".to_string(),
            connection_type: "vless".to_string(),
            condition_refs: vec!["cond_mac".to_string()],
            outbound_source_refs: vec!["sub_1".to_string()],
            ..Default::default()
        }];
        store.conditions = vec![TrafficCondition {
            id: "cond_mac".to_string(),
            enabled: true,
            name: "MAC Target".to_string(),
            condition_type: "atomic".to_string(),
            source_macs: vec!["aa-bb-cc-dd-ee-ff".to_string()],
            user_domains: vec!["example.org".to_string()],
            ..Default::default()
        }];

        let trace = build_route_trace_json_with_mac_table(&RouteTraceInput {
            d: &store,
            client_ip: "192.168.1.50",
            domain: "example.org",
            target_or_ip: "",
            port: 443,
            protocol: "tcp",
            nft_active: true,
            wan6_available: false,
            mac_table: &table,
        });
        assert_eq!(trace["matched_section_id"], "MacSec");
        assert_eq!(trace["query"]["client_mac"], "aa:bb:cc:dd:ee:ff");
        assert_eq!(trace["ipv6_effective_state"], "leak_guard");
        assert_eq!(trace["runtime_dns_strategy"], "ipv4_only");
        assert_eq!(
            trace["stages"]["4_dns_decision"]["ipv6_effective_state"],
            "leak_guard"
        );
        assert_eq!(
            trace["stages"]["4_dns_decision"]["runtime_dns_strategy"],
            "ipv4_only"
        );

        let miss = build_route_trace_json_with_mac_table(&RouteTraceInput {
            d: &store,
            client_ip: "192.168.1.77",
            domain: "example.org",
            target_or_ip: "",
            port: 443,
            protocol: "tcp",
            nft_active: true,
            wan6_available: false,
            mac_table: &table,
        });
        assert_eq!(miss["matched_section_id"], "final");
        assert_eq!(miss["action"], "direct");
        assert_eq!(miss["query"]["client_mac"], "11:22:33:44:55:66");
    }

    #[test]
    fn test_ipv6_leak_summary_and_fakeip_probe_fields() {
        let mut store = RouterStoreData::default();
        store.settings.fakeip_inet4_range = "198.18.0.0/16".to_string();
        store.settings.fakeip_inet6_range = "fd12::/64".to_string();
        store.settings.ipv6_leak_guard = true;

        let leak = build_ipv6_leak_summary(
            &store,
            crate::store::EffectiveIpv6State::LeakGuard,
            "2001:4860::1",
            "",
            false,
        );
        assert_eq!(leak["direct_ipv6"], "2001:4860::1");
        assert_eq!(leak["ipv6_leaked"], true);
        assert_eq!(leak["ipv6_leak_guard"], true);
        assert_eq!(leak["ipv6_effective_state"], "leak_guard");
        assert_eq!(leak["wan6_available"], true);
        assert_eq!(leak["nft_leak_guard_present"], false);

        let probe_proxy = format_fakeip_probe_payload(FakeIpProbePayloadInput {
            d: &store,
            ipv6_state: crate::store::EffectiveIpv6State::Full,
            via_proxy: true,
            v4_ok: true,
            v4_ip: "203.0.113.5",
            v6_ok: true,
            v6_ip: "fd12::5",
            aaaa_suppressed: false,
        });
        assert_eq!(probe_proxy["IPv4"], "203.0.113.5");
        assert_eq!(probe_proxy["fakeip_inet4_range"], "198.18.0.0/16");
        assert_eq!(probe_proxy["fakeip_inet6_range"], "fd12::/64");
    }

    #[test]
    fn test_effective_rulesets_dir_and_tls13_and_cidr_explain() {
        let mut settings = crate::store::GlobalSettings {
            lite_mode: false,
            ..Default::default()
        };
        assert_eq!(
            effective_rulesets_dir(&settings),
            std::path::PathBuf::from("/etc/tachyon/rulesets")
        );
        settings.lite_mode = true;
        assert_eq!(
            effective_rulesets_dir(&settings),
            crate::store::runtime_state_dir().join("rulesets")
        );

        let hello = build_tls13_client_hello("example.com");
        assert!(hello.len() > 80);
        assert_eq!(hello[0], 0x16);
        assert_eq!(hello[5], 0x01);

        // Synthetic TLS 1.3 ServerHello with supported_versions (0x002b) = 0x0304
        let mut sh = vec![
            0x16, 0x03, 0x03, 0x00, 0x30, 0x02, 0x00, 0x00, 0x2c, 0x03, 0x03,
        ];
        sh.extend_from_slice(&[0u8; 32]); // random
        sh.push(0); // sid len
        sh.extend_from_slice(&[0x13, 0x01, 0x00]); // cipher + comp
        sh.extend_from_slice(&[0x00, 0x06, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04]);
        let payload_len = (sh.len() - 5) as u16;
        sh[3..5].copy_from_slice(&payload_len.to_be_bytes());
        let hs_len = (sh.len() - 9) as u32;
        sh[6] = ((hs_len >> 16) & 0xff) as u8;
        sh[7] = ((hs_len >> 8) & 0xff) as u8;
        sh[8] = (hs_len & 0xff) as u8;
        assert_eq!(inspect_tls_server_hello(&sh), (true, true));

        let mut store = RouterStoreData::default();
        store.sections[0].enabled = true;
        store.sections[0].action = "proxy".to_string();
        store.sections[0].exclude_subnets = vec!["10.20.0.0/16".to_string()];
        let excl_res = explain_route(&store, "192.168.1.50", "10.20.30.40", 443, "tcp");
        assert_eq!(excl_res.matched_section, "Прямой маршрут (Direct)");
    }

    #[test]
    fn test_excluded_domain_prefixes_and_proxy_probe_helpers() {
        let store = RouterStoreData {
            sections: vec![RoutingSection {
                id: "sec_blk".to_string(),
                enabled: true,
                label: "Block".to_string(),
                action: "block".to_string(),
                connection_type: "block".to_string(),
                user_domains: vec!["example.com".to_string()],
                exclude_domains: vec![
                    "full:good.example.com".to_string(),
                    "keyword:safe".to_string(),
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let res_good = explain_route(&store, "192.168.1.50", "good.example.com", 443, "tcp");
        assert_ne!(res_good.selected_outbound, "block");
        let res_bad = explain_route(&store, "192.168.1.50", "bad.example.com", 443, "tcp");
        assert_eq!(res_bad.selected_outbound, "block");

        assert_eq!(
            mask_proxy_probe_ip("203.0.113.42\n").as_deref(),
            Some("X.X.X.42")
        );
        assert!(is_retryable_proxy_probe_error("HTTP 429 Too Many Requests"));
        assert!(!is_retryable_proxy_probe_error("203.0.113.42"));

        let cfg_with_diag = json!({
            "inbounds": [
                { "tag": "service-mixed-in", "listen_port": 4534 },
                { "tag": "tg-bot-in", "listen_port": 4535 },
                { "tag": "diag-proxy-in", "listen_port": 4536 }
            ],
            "route": {
                "rules": [
                    { "inbound": ["tg-bot-in"], "outbound": "direct" },
                    { "inbound": ["diag-proxy-in"], "outbound": "sel-Main" }
                ]
            }
        })
        .to_string();
        assert_eq!(read_fakeip_probe_proxy_port_from_str(&cfg_with_diag), 4536);

        let cfg_fallback = json!({
            "inbounds": [
                { "tag": "service-mixed-in", "listen_port": 4534 },
                { "tag": "tg-bot-in", "listen_port": 4535 }
            ],
            "route": {
                "rules": [
                    { "inbound": ["tg-bot-in"], "outbound": "direct" }
                ]
            }
        })
        .to_string();
        assert_eq!(read_fakeip_probe_proxy_port_from_str(&cfg_fallback), 4534);
    }

    #[test]
    fn test_community_subnet_ip_match_refilter_and_aliases() {
        let uniq = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir =
            std::env::temp_dir().join(format!("tachyon_diag_sub_{}_{uniq}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("community-subnets-refilter.lst"),
            "203.0.113.0/24\n2001:db8:4::/48\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("community-subnets-antifilter.lst"),
            "198.51.100.10\n",
        )
        .unwrap();

        let dirs = vec![dir.clone()];
        assert!(check_community_ip_match_in_dirs(
            "203.0.113.42",
            "refilter",
            &dirs
        ));
        assert!(check_community_ip_match_in_dirs(
            "2001:db8:4::99",
            "refilter",
            &dirs
        ));
        assert!(check_community_ip_match_in_dirs(
            "198.51.100.10",
            "antifilter_community",
            &dirs
        ));
        assert!(!check_community_ip_match_in_dirs(
            "198.51.100.11",
            "antifilter_community",
            &dirs
        ));

        let cond_on = crate::store::TrafficCondition {
            id: "c1".to_string(),
            enabled: true,
            name: "Refilter".to_string(),
            community_lists: vec!["refilter".to_string(), "antifilter_community".to_string()],
            community_subnets: true,
            ..Default::default()
        };
        assert!(match_condition_community_lists_in_dirs(&cond_on, "203.0.113.42", &dirs).is_some());

        let cond_off = crate::store::TrafficCondition {
            community_subnets: false,
            ..cond_on
        };
        assert!(
            match_condition_community_lists_in_dirs(&cond_off, "203.0.113.42", &dirs).is_none()
        );

        let cond_explicit = crate::store::TrafficCondition {
            id: "c2".to_string(),
            enabled: true,
            name: "RefilterSub".to_string(),
            community_subnets: false,
            rule_set_with_subnets: vec!["refilter".to_string()],
            ..Default::default()
        };
        assert!(
            match_condition_community_lists_in_dirs(&cond_explicit, "203.0.113.42", &dirs)
                .is_some()
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_diagnostics_english_mode_contains_no_cyrillic() {
        let uniq = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir =
            std::env::temp_dir().join(format!("tachyon_diag_en_{}_{uniq}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let state = crate::store::AppState::load_or_create(dir.join("store.json")).unwrap();
        {
            let mut d = state.data.write().await;
            d.settings.lang = "en".to_string();
            d.sections[0].enabled = true;
        }
        let d_snapshot = state.data.read().await.clone();

        let has_cyrillic = |s: &str| s.chars().any(|c| ('\u{0400}'..='\u{04FF}').contains(&c));

        let doc = run_local_doctor(&state).await;
        assert!(
            !has_cyrillic(&doc.summary),
            "doctor summary must be English: {}",
            doc.summary
        );
        for sub in &doc.subsystems {
            let txt = sub.to_string();
            assert!(!has_cyrillic(&txt), "doctor subsystem has Cyrillic: {txt}");
        }
        for finding in &doc.findings {
            assert!(
                !has_cyrillic(&finding.title)
                    && !has_cyrillic(&finding.detail)
                    && !has_cyrillic(&finding.quick_fix_label),
                "doctor finding has Cyrillic: {finding:?}"
            );
        }

        let leak = run_leak_check(&state, None).await;
        let verdict = leak.get("verdict").and_then(Value::as_str).unwrap_or("");
        assert!(
            !has_cyrillic(verdict),
            "leak verdict has Cyrillic: {verdict}"
        );

        let table = MacIpTable::default();
        let mut trace = build_route_trace_json_with_mac_table(&RouteTraceInput {
            d: &d_snapshot,
            client_ip: "192.168.1.50",
            domain: "example.org",
            target_or_ip: "",
            port: 443,
            protocol: "tcp",
            nft_active: true,
            wan6_available: false,
            mac_table: &table,
        });
        assert!(!has_cyrillic(
            trace["explanation"]["en"].as_str().unwrap_or("")
        ));
        // Strip compatibility Russian field before scanning the whole trace JSON for Cyrillic
        if let Some(exp) = trace.get_mut("explanation").and_then(Value::as_object_mut) {
            exp.remove("ru");
        }
        let trace_str = trace.to_string();
        assert!(
            !has_cyrillic(&trace_str),
            "route trace in EN mode contains Cyrillic: {trace_str}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_causal_suppression_wan_clock_and_core_stopped() {
        let mut wan_findings = vec![
            DoctorFinding {
                id: "wan_down".into(),
                severity: "critical".into(),
                subsystem: "wan".into(),
                title: "WAN down".into(),
                quick_fix_id: "fix_wan_interface".into(),
                ..Default::default()
            },
            DoctorFinding {
                id: "dns_unhealthy".into(),
                severity: "critical".into(),
                subsystem: "dns".into(),
                title: "DNS fail".into(),
                quick_fix_id: "flush_core_dns".into(),
                ..Default::default()
            },
            DoctorFinding {
                id: "outbound_err_tcp_reset_p1".into(),
                severity: "warning".into(),
                subsystem: "outbounds".into(),
                title: "Outbound fail".into(),
                quick_fix_id: "reset_outbound_pool:p1".into(),
                ..Default::default()
            },
        ];
        let roots = apply_causal_suppression(&mut wan_findings);
        assert_eq!(roots, vec!["WAN down".to_string()]);
        assert!(wan_findings[0].root_cause);
        assert_eq!(wan_findings[1].suppressed_by.as_deref(), Some("wan_down"));
        assert_eq!(wan_findings[2].suppressed_by.as_deref(), Some("wan_down"));

        let mut clock_findings = vec![
            DoctorFinding {
                id: "clock_skew".into(),
                severity: "critical".into(),
                subsystem: "time".into(),
                title: "Clock skew".into(),
                quick_fix_id: "fix_system_time".into(),
                ..Default::default()
            },
            DoctorFinding {
                id: "outbound_err_reality_auth_fail_v1".into(),
                severity: "warning".into(),
                subsystem: "outbounds".into(),
                title: "Reality fail".into(),
                quick_fix_id: "reset_outbound_pool:v1".into(),
                ..Default::default()
            },
        ];
        apply_causal_suppression(&mut clock_findings);
        assert_eq!(
            clock_findings[1].suppressed_by.as_deref(),
            Some("clock_skew")
        );

        let mut core_findings = vec![
            DoctorFinding {
                id: "core_stopped".into(),
                severity: "critical".into(),
                subsystem: "core".into(),
                title: "Core stopped".into(),
                quick_fix_id: "restart_core".into(),
                ..Default::default()
            },
            DoctorFinding {
                id: "config_drift".into(),
                severity: "warning".into(),
                subsystem: "config_sync".into(),
                title: "Config drift".into(),
                quick_fix_id: "hot_reload_core".into(),
                ..Default::default()
            },
        ];
        apply_causal_suppression(&mut core_findings);
        assert_eq!(
            core_findings[1].suppressed_by.as_deref(),
            Some("core_stopped")
        );
    }

    #[test]
    fn test_risk_tiers_rag_and_incident_memory_cap() {
        assert_eq!(quick_fix_risk_tier("trim_core_memory"), "safe");
        assert_eq!(
            quick_fix_risk_tier("reset_outbound_pool:node1"),
            "disruptive"
        );
        assert_eq!(quick_fix_risk_tier("switch_to_doh"), "config_change");

        let hits = search_knowledge_docs("FakeIP eviction dns");
        assert!(!hits.is_empty());
        assert_eq!(hits[0]["id"], "08_DNS_AND_FAKEIP");

        let inc_path = std::env::temp_dir().join(format!(
            "tachyon-incidents-test-{}.json",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&inc_path);
        for i in 0..35 {
            append_incident_in(
                &inc_path,
                IncidentRecord {
                    id: format!("inc-{i}"),
                    timestamp: 1_700_000_000 + i,
                    subsystem: "dns".into(),
                    root_cause: "dns fail".into(),
                    fix_id: "flush_core_dns".into(),
                    before_ok: false,
                    after_ok: true,
                    rolled_back: false,
                    outcome: "verified_ok".into(),
                    detail: "Bearer secret_val_xyz".into(),
                },
            );
        }
        let loaded = load_incidents_from(&inc_path);
        assert_eq!(loaded.len(), MAX_INCIDENTS);
        assert_eq!(loaded[0].id, "inc-5");
        assert!(!loaded[0].detail.contains("secret_val_xyz"));
        let _ = std::fs::remove_file(&inc_path);
    }

    #[tokio::test]
    async fn test_apply_quick_fix_verified_dry_run_and_cooldown() {
        let dir = std::env::temp_dir().join(format!("tachyon-qfix-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = AppState::load_or_create(dir.join("tachyon.json")).unwrap();
        let core = CoreManager::new(Arc::clone(&state));

        let dry = Box::pin(apply_quick_fix_verified(
            &state,
            &core,
            "trim_core_memory",
            true,
            false,
        ))
        .await
        .unwrap();
        assert!(dry.ok);
        assert!(dry.dry_run);
        assert_eq!(dry.risk_tier, "safe");

        let first = Box::pin(apply_quick_fix_verified(
            &state,
            &core,
            "trim_core_memory",
            false,
            false,
        ))
        .await
        .unwrap();
        assert!(first.ok);
        assert!(!first.cooldown_blocked);

        let second = Box::pin(apply_quick_fix_verified(
            &state,
            &core,
            "trim_core_memory",
            false,
            false,
        ))
        .await
        .unwrap();
        assert!(!second.ok);
        assert!(second.cooldown_blocked);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_has_true_failover_backup_ignores_healthy_least_test() {
        let healthy_least_test = json!({
            "any_on_backup": true,
            "groups": [{
                "tag": "bal-main",
                "type": "URLTest",
                "mode": "least_test",
                "primary": "de-1",
                "current": "uk-1",
                "on_backup": true,
                "primary_healthy": true,
                "primary_failures": 0,
                "primary_quarantine_rem_s": 0
            }]
        });
        assert!(!has_true_failover_backup(Some(&healthy_least_test)));

        let true_failover = json!({
            "any_on_backup": true,
            "groups": [{
                "tag": "fo-main",
                "type": "URLTest",
                "mode": "failover",
                "primary": "de-1",
                "current": "uk-1",
                "on_backup": true,
                "primary_healthy": true,
                "primary_failures": 0,
                "primary_quarantine_rem_s": 0
            }]
        });
        assert!(has_true_failover_backup(Some(&true_failover)));

        let unhealthy_least_test = json!({
            "any_on_backup": true,
            "groups": [{
                "tag": "bal-main",
                "type": "URLTest",
                "mode": "least_test",
                "primary": "de-1",
                "current": "uk-1",
                "on_backup": true,
                "primary_healthy": false,
                "primary_failures": 2,
                "primary_quarantine_rem_s": 0
            }]
        });
        assert!(has_true_failover_backup(Some(&unhealthy_least_test)));
    }

    #[test]
    fn test_local_doctor_ignores_builtin_block_outbound_and_blocked_by_outbound() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt");
        let tmp =
            std::env::temp_dir().join(format!("tachyon_doctor_block_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("mkdir");
        let state = AppState::load_or_create(tmp.join("tachyon.json")).expect("state");
        let health = json!({
            "outbounds": [
                {
                    "tag": "block",
                    "dial_ok": 0,
                    "dial_fail": 1455,
                    "last_err_class": "io_other",
                    "last_err_detail": "blocked by outbound"
                },
                {
                    "tag": "vless-de",
                    "dial_ok": 120,
                    "dial_fail": 0,
                    "last_err_class": ""
                }
            ]
        });
        let report = rt.block_on(build_doctor_report(
            &state,
            None,
            Some(health),
            None,
            None,
            None,
        ));
        assert!(
            !report
                .findings
                .iter()
                .any(|f| f.id.contains("block") || f.quick_fix_id.contains("block")),
            "builtin block outbound must not trigger failure findings: {:?}",
            report.findings
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_explain_route_section_excluded_ips_allows_later_section() {
        let mut store = RouterStoreData::default();
        store.outbound_sources.clear();
        store.sections.clear();
        store.conditions.clear();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "s1".to_string(),
            enabled: true,
            source_type: "socks".to_string(),
            server: "198.51.100.1".to_string(),
            server_port: 1080,
            ..Default::default()
        });
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "s2".to_string(),
            enabled: true,
            source_type: "socks".to_string(),
            server: "198.51.100.2".to_string(),
            server_port: 1081,
            ..Default::default()
        });
        store.sections.push(crate::store::RoutingSection {
            id: "sec1".to_string(),
            enabled: true,
            action: "proxy".to_string(),
            connection_type: "proxy".to_string(),
            outbound_source_refs: vec!["s1".to_string()],
            excluded_ips: vec!["192.168.1.50".to_string()],
            user_domains: vec!["example.com".to_string()],
            ..Default::default()
        });
        store.sections.push(crate::store::RoutingSection {
            id: "sec2".to_string(),
            enabled: true,
            action: "proxy".to_string(),
            connection_type: "proxy".to_string(),
            outbound_source_refs: vec!["s2".to_string()],
            user_domains: vec!["example.com".to_string()],
            ..Default::default()
        });

        let excluded_res = explain_route(&store, "192.168.1.50", "example.com", 443, "tcp");
        assert_eq!(excluded_res.matched_section_id, "sec2");
        assert_eq!(excluded_res.resolved_outbound, "s2");

        let other_res = explain_route(&store, "192.168.1.51", "example.com", 443, "tcp");
        assert_eq!(other_res.matched_section_id, "sec1");
        assert_eq!(other_res.resolved_outbound, "s1");
    }

    #[test]
    fn test_flow_offload_guard_quick_fix_and_file_check() {
        assert!(is_known_quick_fix("sync_flow_offload_guard"));
        assert_eq!(quick_fix_risk_tier("sync_flow_offload_guard"), "safe");

        let dir = std::env::temp_dir().join(format!("tachyon_diag_offload_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let inc_file = dir.join("ruleset-post").join("10-tachyon-offload.nft");
        let legacy_file = dir
            .join("chain-pre")
            .join("forward")
            .join("10-tachyon-offload.nft");
        unsafe {
            std::env::set_var("TACHYON_FW4_INCLUDE_ROOT", &dir);
        }
        assert!(!flow_offload_guard_installed());
        std::fs::create_dir_all(inc_file.parent().unwrap()).unwrap();
        std::fs::write(
            &inc_file,
            "insert rule inet fw4 forward meta mark & 0x04000000 != 0 ct state established,related accept\n",
        )
        .unwrap();
        assert!(flow_offload_guard_installed());
        std::fs::create_dir_all(legacy_file.parent().unwrap()).unwrap();
        std::fs::write(
            &legacy_file,
            "meta mark & 0x04000000 != 0 ct state established,related accept\n",
        )
        .unwrap();
        assert!(!flow_offload_guard_installed());
        unsafe {
            std::env::remove_var("TACHYON_FW4_INCLUDE_ROOT");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
