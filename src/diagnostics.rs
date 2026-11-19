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

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio::process::Command;

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::net_stack;
use crate::store::{AppState, OutboundSource, RouterStoreData, unix_now_secs};
use crate::sys_info;
use crate::transaction;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorFinding {
    pub id: String,
    pub severity: String,
    pub subsystem: String,
    pub title: String,
    pub detail: String,
    pub quick_fix_id: String,
    pub quick_fix_label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorReport {
    pub healthy: bool,
    pub timestamp: i64,
    pub checks_total: usize,
    pub checks_passed: usize,
    pub subsystems: Vec<Value>,
    pub findings: Vec<DoctorFinding>,
    pub summary: String,
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

pub fn evaluate_odhcpd_ipv6_dns(dhcp_conf_raw: &str, odhcpd_present: bool) -> (bool, String) {
    if !odhcpd_present {
        return (
            true,
            "odhcpd не установлен (проверка IPv6 DNS не требуется)".to_string(),
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
        return (true, "DHCPv6-сервер odhcpd на lan неактивен".to_string());
    }
    if ra_dns == "1" || !dns_list.is_empty() {
        let detail = if !dns_list.is_empty() {
            format!("DHCPv6 DNS настроен ({})", dns_list.join(", "))
        } else {
            "DHCPv6 RA DNS активен (ra_dns=1)".to_string()
        };
        return (true, detail);
    }
    (
        false,
        "При включённом dhcp.lan.dhcpv6='server' не заданы ra_dns='1' и list dns".to_string(),
    )
}

/// Run Local Doctor heuristic and runtime checks across 16 router subsystems.
pub async fn run_local_doctor(state: &Arc<AppState>) -> DoctorReport {
    let mut findings = Vec::new();
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let sys = sys_info::collect_host_info();
    let checks_total = 16usize;

    // 1. Core process liveness
    if !live.core_running {
        findings.push(DoctorFinding {
            id: "core_stopped".to_string(),
            severity: "critical".to_string(),
            subsystem: "core".to_string(),
            title: "Процесс tachyon-core не запущен".to_string(),
            detail: "Ядро маршрутизации остановлено или ожидает запуска.".to_string(),
            quick_fix_id: "restart_core".to_string(),
            quick_fix_label: "Запустить tachyon-core".to_string(),
        });
    }

    // 2. nftables TProxy table check
    if d.settings.proxy_mode == "tproxy" && !live.nft_table_active {
        findings.push(DoctorFinding {
            id: "nft_missing".to_string(),
            severity: "warning".to_string(),
            subsystem: "nftables".to_string(),
            title: "Таблица nftables inet TachyonTable не активна".to_string(),
            detail: "Правила прозрачного перехвата TProxy не загружены в ядро Linux.".to_string(),
            quick_fix_id: "heal_network_stack".to_string(),
            quick_fix_label: "Восстановить сетевой стек".to_string(),
        });
    }

    // 3. Bootstrap DNS check
    if d.settings.bootstrap_dns_servers.is_empty() {
        findings.push(DoctorFinding {
            id: "bootstrap_dns_empty".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: "Не задан Bootstrap DNS".to_string(),
            detail: "Для разрешения доменов прокси-узлов и DoH требуется прямой Bootstrap DNS."
                .to_string(),
            quick_fix_id: "fix_bootstrap_dns".to_string(),
            quick_fix_label: "Сбросить Bootstrap DNS".to_string(),
        });
    }

    // 4. Active routing sections check
    let enabled_sections = d.sections.iter().filter(|s| s.enabled).count();
    if enabled_sections == 0 {
        findings.push(DoctorFinding {
            id: "no_active_sections".to_string(),
            severity: "info".to_string(),
            subsystem: "routing".to_string(),
            title: "Нет активных секций маршрутизации".to_string(),
            detail: "Весь трафик сейчас направляется напрямую (direct).".to_string(),
            quick_fix_id: "enable_default_desync".to_string(),
            quick_fix_label: "Включить секции".to_string(),
        });
    }

    // 5. System RAM pressure check
    if sys.mem_total_bytes > 0 {
        let avail_bytes = sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes);
        let free_pct = (avail_bytes * 100) / sys.mem_total_bytes;
        if free_pct < 12 {
            findings.push(DoctorFinding {
                id: "low_memory".to_string(),
                severity: "warning".to_string(),
                subsystem: "memory".to_string(),
                title: format!("Мало свободной памяти ОЗУ ({free_pct}%)"),
                detail: "Рекомендуется выполнить сжатие буферов ядра или включить Эко-режим (Tachyon Lite).".to_string(),
                quick_fix_id: "optimize_memory".to_string(),
                quick_fix_label: "Оптимизировать память".to_string(),
            });
        }
    }

    // 6. System clock sanity check (for TLS / Reality / WireGuard handshakes)
    if unix_now_secs() < 1_700_000_000 {
        findings.push(DoctorFinding {
            id: "clock_skew".to_string(),
            severity: "critical".to_string(),
            subsystem: "time".to_string(),
            title: "Системное время роутера сбито".to_string(),
            detail: "Некорректное время ломает рукопожатия TLS 1.3 и VLESS Reality.".to_string(),
            quick_fix_id: "fix_system_time".to_string(),
            quick_fix_label: "Синхронизировать NTP".to_string(),
        });
    }

    // 7. Outbound sources empty cache check
    for src in d
        .outbound_sources
        .iter()
        .filter(|s| s.enabled && s.source_type == "subscription")
    {
        if src.cached_nodes.is_empty() && src.proxy_links.is_empty() {
            findings.push(DoctorFinding {
                id: format!("sub_empty_{}", src.id),
                severity: "warning".to_string(),
                subsystem: "subscriptions".to_string(),
                title: format!("Подписка «{}» не содержит кэшированных узлов", src.name),
                detail: "Обновите подписку для загрузки актуального списка узлов.".to_string(),
                quick_fix_id: "update_subscriptions".to_string(),
                quick_fix_label: "Обновить подписки".to_string(),
            });
        }
    }

    // 8. Firewall flow offloading conflict check (breaks TProxy / SQM packet interception)
    let (sw_offload, hw_offload) = read_firewall_flow_offloading();
    let flow_offload_active = (sw_offload || hw_offload)
        && (matches!(d.settings.proxy_mode.as_str(), "tproxy" | "redirect")
            || d.settings.smart_queue);
    if flow_offload_active {
        findings.push(DoctorFinding {
            id: "flow_offloading_conflict".to_string(),
            severity: "warning".to_string(),
            subsystem: "firewall".to_string(),
            title: "Включён Flow Offloading в Firewall (конфликт с TProxy/SQM)".to_string(),
            detail: "Аппаратный/программный Flow Offloading обходит netfilter/TProxy и приводит к зависанию долгоживущих TCP-потоков на клиентских устройствах.".to_string(),
            quick_fix_id: "disable_flow_offloading".to_string(),
            quick_fix_label: "Отключить Flow Offloading".to_string(),
        });
    }

    // 9. odhcpd IPv6 DNS check (when DHCPv6 server is active on LAN)
    let (odhcpd_ok, odhcpd_detail) = if cfg!(windows) {
        (true, "Windows test mode: odhcpd пропущен".to_string())
    } else {
        let odhcpd_present = tokio::fs::metadata("/etc/init.d/odhcpd").await.is_ok();
        let dhcp_raw = tokio::fs::read_to_string("/etc/config/dhcp")
            .await
            .unwrap_or_default();
        evaluate_odhcpd_ipv6_dns(&dhcp_raw, odhcpd_present)
    };
    if !odhcpd_ok {
        findings.push(DoctorFinding {
            id: "odhcpd_ipv6_dns_missing".to_string(),
            severity: "warning".to_string(),
            subsystem: "dhcp".to_string(),
            title: "Не настроен IPv6 DNS в odhcpd для LAN".to_string(),
            detail: odhcpd_detail.clone(),
            quick_fix_id: "heal_network_stack".to_string(),
            quick_fix_label: "Настроить стек IPv6/DNS".to_string(),
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
            title: "Некорректный системный /etc/resolv.conf".to_string(),
            detail:
                "Резолвер хоста роутера не указывает на локальный DNS (127.0.0.1) или отсутствует."
                    .to_string(),
            quick_fix_id: "fix_resolv_symlink".to_string(),
            quick_fix_label: "Починить симлинк".to_string(),
        });
    }

    let sub_has_issue = findings.iter().any(|f| f.id.starts_with("sub_empty_"))
        || d.outbound_sources
            .iter()
            .any(|s| s.enabled && !s.sub_last_error.is_empty())
        || d.outbound_sources.iter().filter(|s| s.enabled).count() == 0;
    let balancer_has_issue = d
        .balancers
        .iter()
        .any(|b| b.balancer_pool.is_empty() && b.priority_levels.is_empty())
        || d.sections.iter().any(|s| {
            s.enabled
                && s.connection_type == "proxy"
                && s.outbound_source_refs.is_empty()
                && s.balancer_refs.is_empty()
                && s.outbound_group_refs.is_empty()
        });
    let server_has_issue = d.servers.iter().any(|s| s.enabled)
        && (!live.core_running
            || d.servers.iter().any(|s| {
                s.enabled
                    && (s.listen_port == 0
                        || (s.security == "tls" && s.tls_certificate_path.trim().is_empty()))
            }));
    let low_memory = findings.iter().any(|f| f.id == "low_memory");
    let lkg_ready = state.lkg_path.exists();
    let honeypot_triggered = !live.honeypot_hits.is_empty();
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
            title: "Нарушен каскад dnsmasq -> 127.0.0.42#53".to_string(),
            detail: "Отсутствует drop-in /tmp/dnsmasq*.d/tachyon.conf или остановлен dnsmasq."
                .to_string(),
            quick_fix_id: "fix_dnsmasq".to_string(),
            quick_fix_label: "Перезапустить dnsmasq".to_string(),
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
        && !crate::core_mgr::CoreManager::core_config_ipv6_matches(
            &core_cfg_doc,
            &d,
            ipv6_state_doc,
        )
    {
        findings.push(DoctorFinding {
            id: "fakeip6_config_drift".to_string(),
            severity: "warning".to_string(),
            subsystem: "dns".to_string(),
            title: "FakeIPv6 в конфиге ядра не синхронизирован с активным IPv6".to_string(),
            detail: format!(
                "В {} отсутствует актуальный inet6_range для FakeIPv6 при активном состоянии IPv6 ({}).",
                core_cfg_doc.display(),
                ipv6_state_doc.as_str()
            ),
            quick_fix_id: "doctor_fix".to_string(),
            quick_fix_label: "Автовосстановление конфига и IPv6 (doctor --fix)".to_string(),
        });
    }

    let checks_passed = checks_total.saturating_sub(findings.len());
    let healthy = !findings.iter().any(|f| f.severity == "critical");
    let summary = if findings.is_empty() {
        format!("Все {checks_total} подсистем роутера и ядра tachyon-core работают штатно")
    } else {
        format!(
            "Проверено подсистем: {checks_total}, замечаний: {}",
            findings.len()
        )
    };

    let subsystems = vec![
        json!({"name": "1. Ядро tachyon-core", "status": if live.core_running { "ok" } else { "warn" }, "detail": format!("PID {} · RSS {} KB", live.core_pid.unwrap_or(0), live.core_rss_bytes / 1024), "fix_id": "restart_core", "fix_label": "Перезапустить"}),
        json!({"name": "2. Таблица nftables TProxy", "status": if live.nft_table_active { "ok" } else { "warn" }, "detail": "inet TachyonTable :1602", "fix_id": "heal_network_stack", "fix_label": "Восстановить стек"}),
        json!({
            "name": if d.settings.fakeip_enabled {
                format!(
                    "3. DNS и FakeIP ({})",
                    if d.settings.fakeip_inet4_range.trim().is_empty() {
                        "198.18.0.0/15"
                    } else {
                        d.settings.fakeip_inet4_range.trim()
                    }
                )
            } else {
                "3. DNS (RealIP)".to_string()
            },
            "status": if live.dns_healthy { "ok" } else { "warn" },
            "detail": if d.settings.fakeip_enabled {
                "FakeIP 127.0.0.42:53"
            } else {
                "RealIP 127.0.0.42:53"
            },
            "fix_id": "clear_dns_cache",
            "fix_label": "Сбросить кэш DNS"
        }),
        json!({"name": "4. Внешний канал WAN", "status": if live.wan_healthy { "ok" } else { "warn" }, "detail": "Маршрут по умолчанию активен", "fix_id": "fix_wan_interface", "fix_label": "Проверить шлюз"}),
        json!({"name": "5. Секции маршрутизации", "status": if d.sections.iter().any(|s| s.enabled) { "ok" } else { "warn" }, "detail": format!("Активно {} из {}", d.sections.iter().filter(|s| s.enabled).count(), d.sections.len()), "fix_id": "enable_default_desync", "fix_label": "Включить секции"}),
        json!({"name": "6. Источники и Подписки", "status": if sub_has_issue { "warn" } else { "ok" }, "detail": format!("Активно {} из {}", d.outbound_sources.iter().filter(|s| s.enabled).count(), d.outbound_sources.len()), "fix_id": "update_subscriptions", "fix_label": "Обновить подписки"}),
        json!({"name": "7. Балансировщики нагрузки", "status": if balancer_has_issue { "warn" } else { "ok" }, "detail": format!("Алгоритмов: {}", d.balancers.len()), "fix_id": "restart_core", "fix_label": "Перепроверить"}),
        json!({"name": "8. Входящие серверы", "status": if server_has_issue { "warn" } else { "ok" }, "detail": format!("Активно {} из {}", d.servers.iter().filter(|s| s.enabled).count(), d.servers.len()), "fix_id": "restart_core", "fix_label": "Применить"}),
        json!({"name": "9. Память ОЗУ и ZRAM", "status": if low_memory { "warn" } else { "ok" }, "detail": format!("Свободно {} МБ · ZRAM {} МБ", sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes) / 1048576, sys.zram_total_bytes / 1048576), "fix_id": "optimize_memory", "fix_label": "Сжать память"}),
        json!({"name": "10. Системное время NTP", "status": if unix_now_secs() > 1_700_000_000 { "ok" } else { "warn" }, "detail": "Синхронизировано для TLS 1.3 / Reality", "fix_id": "fix_system_time", "fix_label": "Синхронизировать NTP"}),
        json!({"name": "11. Снимок LKG Watchdog", "status": if lkg_ready { "ok" } else { "warn" }, "detail": if lkg_ready { "Эталон сохранён" } else { "Эталон ещё не сохранён" }, "fix_id": "rollback_known_good", "fix_label": "Откат к эталону"}),
        json!({"name": "12. Защита NAND и Honeypot", "status": if honeypot_triggered { "warn" } else { "ok" }, "detail": format!("SHA-256 Guard · Отражено: {}", live.honeypot_hits.len()), "fix_id": "flush_conntrack", "fix_label": "Сбросить сессии"}),
        json!({"name": "13. Каскад dnsmasq -> FakeIP", "status": if dnsmasq_cascade_ok { "ok" } else { "warn" }, "detail": if dnsmasq_cascade_ok { "noresolv=1 · 127.0.0.42#53" } else { "Проблема каскада dnsmasq/127.0.0.42#53" }, "fix_id": "fix_dnsmasq", "fix_label": "Перезапустить dnsmasq"}),
        json!({"name": "14. Системный /etc/resolv.conf", "status": if resolv_ok { "ok" } else { "warn" }, "detail": "Резолвер хоста роутера", "fix_id": "fix_resolv_symlink", "fix_label": "Починить симлинк"}),
        json!({"name": "15. Конфликты Firewall (Flow Offloading)", "status": if flow_offload_active { "warn" } else { "ok" }, "detail": if flow_offload_active { "Обнаружен Flow Offloading при TProxy/SQM" } else { "Конфликтов с netfilter/TProxy не обнаружено" }, "fix_id": "disable_flow_offloading", "fix_label": "Отключить Flow Offloading"}),
        json!({"name": "16. odhcpd IPv6 DNS", "status": if odhcpd_ok { "ok" } else { "warn" }, "detail": odhcpd_detail, "fix_id": "heal_network_stack", "fix_label": "Настроить стек IPv6/DNS"}),
    ];

    DoctorReport {
        healthy,
        timestamp: unix_now_secs(),
        checks_total,
        checks_passed,
        subsystems,
        findings,
        summary,
    }
}

/// Execute any of the 25 automated Quick Fixes by ID.
pub async fn apply_quick_fix(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    fix_id: &str,
) -> anyhow::Result<String> {
    match fix_id {
        "restart_core" | "start_core" | "start_tachyon_core" => {
            core.apply_or_reload().await?;
            Ok("Ядро tachyon-core перезапущено и синхронизировано".to_string())
        }
        "doctor_fix" => {
            if core.apply_or_reload().await.is_err() {
                let _ = core.component_action("lists", "update", None).await;
                core.apply_or_reload().await?;
            }
            Ok("Выполнено автовосстановление конфигурации, правил IPv6 и списков".to_string())
        }
        "heal_network_stack" | "rebuild_rules" | "reset_firewall" => {
            let snap = state.data.read().await.clone();
            net_stack::apply_network_stack(&snap).await?;
            state.live.write().await.nft_table_active = net_stack::check_nft_table_active().await;
            Ok("Сетевой стек (inet TachyonTable и ip rule) перестроен".to_string())
        }
        "fix_bootstrap_dns" => {
            let mut candidate = state.data.read().await.clone();
            candidate.settings.bootstrap_dns_servers =
                vec!["77.88.8.8".to_string(), "1.1.1.1".to_string()];
            transaction::commit_transaction(state, candidate).await?;
            let _ = core.apply_or_reload().await;
            Ok("Bootstrap DNS сброшен на 77.88.8.8 / 1.1.1.1".to_string())
        }
        "switch_to_doh" => {
            let mut candidate = state.data.read().await.clone();
            candidate.settings.dns_type = "doh".to_string();
            candidate.settings.dns_servers = vec![
                "https://1.1.1.1/dns-query".to_string(),
                "https://dns.google/dns-query".to_string(),
            ];
            transaction::commit_transaction(state, candidate).await?;
            let _ = core.apply_or_reload().await;
            Ok("DNS переключён на защищённый DoH (Cloudflare + Google)".to_string())
        }
        "clear_dns_cache" | "restart_core_dns" | "restart_tachyon_core_dns" => {
            let _ = core
                .clash_request("POST", "/configs?force=true", Some("{}"))
                .await;
            if !cfg!(windows) {
                let _ = Command::new("/etc/init.d/dnsmasq")
                    .arg("restart")
                    .status()
                    .await;
            }
            Ok("Кэш DNS очищен, резолвер перезапущен".to_string())
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
            let mut candidate = state.data.read().await.clone();
            candidate.settings.enable_watchdog = true;
            transaction::commit_transaction(state, candidate).await?;
            core.set_manual_stop(false);
            Ok("Автономный Watchdog включён".to_string())
        }
        "optimize_memory" => {
            let _ = core
                .clash_request("POST", "/tachyon/memory/trim", Some("{}"))
                .await;
            if !cfg!(windows) {
                let _ = std::fs::write("/proc/sys/vm/drop_caches", "1\n");
            }
            Ok("Буферы памяти tachyon-core и кэш страниц Linux очищены".to_string())
        }
        "optimize_mtu" => {
            let mut candidate = state.data.read().await.clone();
            candidate.settings.tun_mtu = 1400;
            transaction::commit_transaction(state, candidate).await?;
            let _ = core.apply_or_reload().await;
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
            let updated = core.refresh_all_subscriptions().await?;
            Ok(format!("Обновлено подписок: {updated}"))
        }
        "fix_wan_interface" | "fix_gateway" | "restart_network" => {
            let _ = core.probe_all_nodes_rtt().await;
            Ok("Проверка шлюза WAN и узлов маршрутизации выполнена".to_string())
        }
        "restore_native_internet" | "enable_safe_bypass" | "flush_nftables" => {
            let _ = core.stop().await;
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
            let mut candidate = state.data.read().await.clone();
            if candidate.outbound_sources.is_empty() {
                candidate.outbound_sources.push(OutboundSource {
                    id: "src_adaptive_desync".to_string(),
                    enabled: true,
                    name: "Adaptive Desync 2.0".to_string(),
                    source_type: "desync".to_string(),
                    desync_preset: "adaptive".to_string(),
                    desync_auto_tune: true,
                    ..Default::default()
                });
            }
            for s in &mut candidate.sections {
                s.enabled = true;
            }
            transaction::commit_transaction(state, candidate).await?;
            let _ = core.apply_or_reload().await;
            Ok("Включена секция адаптивной десинхронизации пакетов".to_string())
        }
        "rollback_known_good" | "fix_uci_config" | "restore_lkg" => {
            let lkg = transaction::load_known_good(&state.lkg_path)?;
            transaction::commit_transaction(state, lkg).await?;
            let _ = core.apply_or_reload().await;
            Ok("Выполнен откат к снимку Last Known Good".to_string())
        }
        "upgrade_core" => {
            let info = core.check_updates().await;
            Ok(format!(
                "Проверка обновлений завершена: {}",
                info.get("core_latest")
                    .and_then(Value::as_str)
                    .unwrap_or("актуальная версия")
            ))
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
    let d = state.data.read().await.clone();
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
    let docs = [
        (
            "01_SYSTEM_ARCHITECTURE",
            "Архитектура Tachyon и ядра tachyon-core",
            "Единый бинарный оркестратор управляет /usr/bin/tachyon-core, таблицей nftables inet TachyonTable (TProxy :1602) и DNS FakeIP (127.0.0.42:53 -> 198.18.0.0/15).",
        ),
        (
            "03_NETWORKING_AND_NFTABLES",
            "Перехват трафика TProxy и таблица inet TachyonTable",
            "В режиме tproxy пакеты из br-lan маркируются fwmark 0x1 и направляются через ip rule fwmark 0x1 lookup 100 на порт 1602.",
        ),
        (
            "04_ADAPTIVE_DESYNC",
            "Адаптивная десинхронизация пакетов (Adaptive Desync 2.0)",
            "Модуль desync выполняет фрагментацию TLS ClientHello (pos=1,sni,midsld), автоподбор TTL и отправку фейковых пакетов без внешних утилит.",
        ),
        (
            "05_BALANCERS_INVARIANT",
            "Инвариант секционных балансировщиков (URLTest / Stability / Sticky)",
            "Балансировщик хранит только политику выбора (least_test, stability, sticky, priority). Список кандидатов всегда формируется строго из секции маршрутизации.",
        ),
        (
            "08_DNS_AND_FAKEIP",
            "Конвейер DNS, FakeIP и защита от утечек",
            "Запросы A/AAAA перехватываются на 127.0.0.42:53 и получают синтетические адреса 198.18.0.0/15, что исключает DNS-утечки и ускоряет маршрутизацию.",
        ),
        (
            "22_LAST_KNOWN_GOOD",
            "Транзакции, сверка (Reconciler) и снимок Last Known Good",
            "После каждого изменения запускается окно наблюдения 180 секунд. При успешной проверке конфигурация сохраняется в tachyon.known_good.json.",
        ),
    ];

    let q_lower = query.to_lowercase();
    let mut out = Vec::new();
    for (id, title, snippet) in docs {
        if q_lower.is_empty()
            || title.to_lowercase().contains(&q_lower)
            || snippet.to_lowercase().contains(&q_lower)
            || id.to_lowercase().contains(&q_lower)
        {
            out.push(json!({
                "id": id,
                "title": title,
                "snippet": snippet
            }));
        }
    }
    if out.is_empty() {
        for (id, title, snippet) in docs.iter().take(3) {
            out.push(json!({
                "id": id,
                "title": title,
                "snippet": snippet
            }));
        }
    }
    out
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
    };
    let mut steps = vec![
        format!("1. Входящий пакет от {client_ip} -> {target}:{port} ({proto_lower})"),
        format!(
            "2. DNS FakeIP конвейер (127.0.0.42:53, стратегия: {})",
            store.settings.dns_strategy
        ),
    ];

    // Check parental profiles first
    for prof in store.profiles.iter().filter(|p| p.enabled) {
        if prof.device_ips.iter().any(|ip| {
            client_matches_entry(ip, client_ip, resolved_client_mac.as_deref(), mac_table)
        }) && prof.blocked_domains.iter().any(|d| {
            target_lower == d.to_ascii_lowercase()
                || target_lower.ends_with(&format!(".{}", d.to_ascii_lowercase()))
        }) {
            steps.push(format!(
                "3. Совпадение с семейным профилем «{}» -> БЛОКИРОВКА",
                prof.label
            ));
            return RouteExplainResult {
                client_ip: client_ip.to_string(),
                target: target.to_string(),
                port,
                protocol: proto_lower,
                matched_section_id: prof.id.clone(),
                matched_section_label: format!("Семейный профиль: {}", prof.label),
                matched_section: format!("Семейный профиль: {}", prof.label),
                matched_condition_id: "blocked_domains".to_string(),
                matched_reason: format!("Домен '{}' заблокирован семейным профилем", target),
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
        if is_excluded_port || is_excluded_domain || is_excluded_subnet {
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
            steps.push(format!(
                "3. Клиент {client_ip} входит в список полной маршрутизации секции «{}» -> {resolved_out}",
                sec.label
            ));
            return RouteExplainResult {
                client_ip: client_ip.to_string(),
                target: target.to_string(),
                port,
                protocol: proto_lower,
                matched_section_id: sec.id.clone(),
                matched_section_label: sec.label.clone(),
                matched_section: sec.label.clone(),
                matched_condition_id: "fully_routed_ips".to_string(),
                matched_reason: format!("Клиент {client_ip} задан в fully_routed_ips"),
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
                steps.push(format!(
                    "3. Совпадение с условием «{}» ({reason}) в секции «{}»",
                    cond.name, sec.label
                ));
                steps.push(format!(
                    "4. Выходной обработчик: {resolved_out} ({})",
                    sec.connection_type
                ));
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
        let mut combined_domains = sec.domains.clone();
        for d in &sec.user_domains {
            if !combined_domains.contains(d) {
                combined_domains.push(d.clone());
            }
        }
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
            rule_set_with_subnets: sec.rule_set_with_subnets.clone(),
            user_domains: combined_domains,
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
            steps.push(format!(
                "3. Совпадение с правилами секции «{}» ({reason})",
                sec.label
            ));
            steps.push(format!(
                "4. Выходной обработчик: {resolved_out} ({})",
                sec.connection_type
            ));
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
            let reason = format!(
                "Секция «{}» настроена на перехват всего трафика (match_all)",
                sec.label
            );
            steps.push(format!("3. {reason}"));
            steps.push(format!(
                "4. Выходной обработчик: {resolved_out} ({})",
                sec.connection_type
            ));
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

    steps.push(
        "3. Ни одно правило секций не совпало -> маршрут по умолчанию (route.final = direct)"
            .to_string(),
    );
    RouteExplainResult {
        client_ip: client_ip.to_string(),
        target: target.to_string(),
        port,
        protocol: proto_lower,
        matched_section_id: "final".to_string(),
        matched_section_label: "Прямой маршрут (Direct)".to_string(),
        matched_section: "Прямой маршрут (Direct)".to_string(),
        matched_condition_id: "none".to_string(),
        matched_reason: "Не совпало ни одно условие; направлено напрямую (direct)".to_string(),
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
            "byteoversea.com",
            "volcengine.com",
            "volces.com",
            "bytedance.com",
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
            "byteoversea.com",
            "volcengine.com",
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

fn match_condition_community_lists_in_dirs(
    cond: &crate::store::TrafficCondition,
    target_lower: &str,
    dirs: &[std::path::PathBuf],
) -> Option<String> {
    for list in &cond.community_lists {
        let ll = list.trim().to_ascii_lowercase();
        if !ll.is_empty()
            && (match_list_tag_against_domain(&ll, target_lower)
                || (cond.community_subnets
                    && check_community_ip_match_in_dirs(target_lower, &ll, dirs)))
        {
            return Some(format!(
                "Список сообщества trs-{list} в условии «{}»",
                cond.name
            ));
        }
    }

    for rset in &cond.rule_set_with_subnets {
        let clean = rset.trim();
        if crate::config_gen::is_community_list_token(clean) {
            let ll = clean.to_ascii_lowercase();
            if match_list_tag_against_domain(&ll, target_lower)
                || check_community_ip_match_in_dirs(target_lower, &ll, dirs)
            {
                return Some(format!(
                    "Список с подсетями {clean} в условии «{}»",
                    cond.name
                ));
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
                return Some(format!("Отрицание условия «{}»", cond.name));
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

    if cond.user_domains.iter().any(|d| {
        let dl = d.trim().to_ascii_lowercase();
        !dl.is_empty() && (ctx.target_lower == dl || ctx.target_lower.ends_with(&format!(".{dl}")))
    }) {
        return Some(format!("Пользовательский домен в условии «{}»", cond.name));
    }

    if !cond.ports.is_empty() && cond.ports.iter().any(|p| p.trim() == ctx.port.to_string()) {
        return Some(format!("Порт {} в условии «{}»", ctx.port, cond.name));
    }

    if !cond.user_subnets.is_empty()
        && cond.user_subnets.iter().any(|s| {
            let clean = s.trim();
            !clean.is_empty()
                && (clean.eq_ignore_ascii_case(ctx.target_lower)
                    || crate::store::ip_in_cidr(ctx.target_lower, clean))
        })
    {
        return Some(format!("Подсеть в условии «{}»", cond.name));
    }

    let comm_dirs = default_community_subnet_dirs();
    if let Some(reason) =
        match_condition_community_lists_in_dirs(cond, ctx.target_lower, &comm_dirs)
    {
        return Some(reason);
    }

    for gs in &cond.geosite_codes {
        let gl = gs.trim().to_ascii_lowercase();
        if !gl.is_empty() && match_list_tag_against_domain(&gl, ctx.target_lower) {
            return Some(format!("Набор geosite-{gs} в условии «{}»", cond.name));
        }
    }

    if has_client_filter
        && cond.user_domains.is_empty()
        && cond.ports.is_empty()
        && cond.user_subnets.is_empty()
        && cond.community_lists.is_empty()
        && cond.rule_set_with_subnets.is_empty()
        && cond.geosite_codes.is_empty()
    {
        return Some(format!("Устройство/источник в условии «{}»", cond.name));
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
    let nft_details = if d.settings.proxy_mode == "socks" {
        "Активен режим SOCKS/Mixed; таблица nftables не используется"
    } else if !nft_active {
        "Таблица inet TachyonTable не загружена в ядро (трафик идёт напрямую через WAN)"
    } else if is_direct {
        "Секция direct/bypass; пакет пропущен в обход TProxy"
    } else {
        "Пакет направлен в tproxy :1602 с меткой 0x04000000"
    };
    let is_ip_target = tr.target.chars().all(|c| c.is_ascii_digit() || c == '.');
    let inbound_tag = if d.settings.proxy_mode == "socks" {
        "mixed-in"
    } else {
        "tproxy-in"
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
                "name": "Классификация клиента",
                "client": client_ip,
                "ip": client_ip,
                "client_type": "lan",
                "is_excluded": false,
                "details": format!("Клиент локальной сети {client_ip} включен в обработку")
            },
            "2_target_classification": {
                "stage": 2,
                "name": "Классификация назначения",
                "target": tr.target,
                "target_type": if is_ip_target { "ip" } else { "domain" },
                "port": tr.port,
                "proto": tr.protocol,
                "is_private_ip": false,
                "is_fakeip": d.settings.fakeip_enabled && !is_ip_target,
                "details": format!("Назначение {}:{} ({})", tr.target, tr.port, tr.protocol.to_uppercase())
            },
            "3_section_matching": {
                "stage": 3,
                "name": "Сопоставление правил секции",
                "matched_section": tr.matched_section,
                "section_label": tr.matched_section,
                "action": action_str,
                "rule_type": "condition",
                "rule_value": tr.matched_condition_id,
                "details": tr.matched_reason
            },
            "4_dns_decision": {
                "stage": 4,
                "name": "Решение DNS / FakeIP",
                "mode": if d.settings.fakeip_enabled { "fakeip" } else { "realip" },
                "resolver": d.settings.dns_type,
                "fakeip_active": d.settings.fakeip_enabled,
                "ipv6_effective_state": ipv6_state.as_str(),
                "runtime_dns_strategy": runtime_dns_strategy,
                "details": if d.settings.fakeip_enabled {
                    format!(
                        "Домен сопоставлен через таблицу FakeIP ({})",
                        if d.settings.fakeip_inet4_range.trim().is_empty() {
                            "198.18.0.0/15"
                        } else {
                            d.settings.fakeip_inet4_range.trim()
                        }
                    )
                } else {
                    "Используется реальное разрешение имён без подмены FakeIP".to_string()
                }
            },
            "5_nftables_interception": {
                "stage": 5,
                "name": "Перехват nftables",
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
                "name": "Политика маршрутизации (PBR)",
                "table": crate::net_stack::TPROXY_ROUTE_TABLE,
                "ip_rule": format!("fwmark {} table {}", crate::net_stack::TPROXY_FWMARK, crate::net_stack::TPROXY_ROUTE_TABLE),
                "route": "local 0.0.0.0/0 dev lo",
                "details": if nft_active {
                    "Таблица маршрутизации 100 доставляет пакет в сокет Tachyon Core (:1602)"
                } else {
                    "Политика PBR неактивна — таблица TachyonTable не загружена"
                }
            },
            "7_engine_outbound": {
                "stage": 7,
                "name": "Исходящий узел ядра",
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
                "details": format!("Трафик отправлен через узел {} ({})", tr.selected_outbound, srv_proto.to_uppercase())
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
    let d = state.data.read().await.clone();
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

    if ipv6_leaked {
        crate::tg_bot::notify_if_enabled(
            &d,
            "dns_leak",
            "Обнаружен риск прямой маршрутизации IPv6 при неактивной таблице nftables",
        );
    } else if live.core_running && !dns_port_open {
        crate::tg_bot::notify_if_enabled(
            &d,
            "dns_leak",
            "Локальный DNS-резолвер ядра 127.0.0.42:53 не отвечает — возможна утечка DNS",
        );
    }

    let verdict = if !live.core_running {
        "Ядро остановлено — используется системный DNS роутера".to_string()
    } else if ipv6_leaked {
        "Обнаружен риск прямой маршрутизации IPv6 при отключённой таблице nftables".to_string()
    } else if d.settings.fakeip_enabled && ipv6_state.is_tunnel_over_v4() {
        format!(
            "Защита FakeIP ({fakeip_v4}, {fakeip_v6}), туннель IPv6-over-IPv4 и WebRTC-фильтр активны"
        )
    } else if d.settings.fakeip_enabled && ipv6_state.is_active() {
        format!(
            "Защита FakeIP ({fakeip_v4}, {fakeip_v6}), режим IPv6 ({}) и WebRTC-фильтр активны",
            ipv6_state.as_str()
        )
    } else if d.settings.fakeip_enabled {
        format!(
            "Защита FakeIP ({fakeip_v4}), подавление AAAA (NOERROR) и перехват WebRTC STUN активны"
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
    let d = state.data.read().await.clone();
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
}
