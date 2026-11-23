//! Telegram Bot operational handlers: diagnostics, AI Doctor, route tracing,
//! DNS checks, leak audit, failover, logs, support bundle, desync strategy fuzzer,
//! component/list updates, configuration snapshots, LKG rollback, and bot self-settings.

use std::collections::HashSet;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use serde_json::Value;

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::diagnostics;
use crate::fuzzer;
use crate::snapshots;
use crate::store::{AppState, RouterStoreData, RoutingSection, TgBotConfig};
use crate::transaction;
use crate::ubus_bridge;
use crate::updater;

use super::{
    BotReply, PendingPromptKind, cb_btn, clear_chat_prompt, escape_html, inline_kb,
    is_quiet_hours_now, is_ru, notify_bot_wakeup, parse_hhmm, resolve_tg_proxy_url,
    set_chat_prompt, tr,
};

const TG_TEXT_BUDGET: usize = 3500;

fn truncate_for_tg(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(8)).collect();
    out.push_str("\n...");
    out
}

fn normalize_fix_id(raw: &str) -> &str {
    match raw.trim() {
        "rebuild_nft" => "heal_network_stack",
        "flush_dns" => "clear_dns_cache",
        other => other,
    }
}

fn sanitize_trace_target(raw: &str) -> String {
    let trimmed = raw.trim();
    let no_scheme = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))
        .unwrap_or(trimmed);
    let host_port = no_scheme.split('/').next().unwrap_or("").trim();
    if let Some((host, port_part)) = host_port.rsplit_once(':')
        && !host.contains(':')
        && port_part.chars().all(|c| c.is_ascii_digit())
    {
        return host.to_string();
    }
    host_port.to_string()
}

fn is_desync_section(s: &RoutingSection) -> bool {
    s.connection_type.eq_ignore_ascii_case("desync") || s.action.eq_ignore_ascii_case("desync")
}

/// Apply parsed `desync` strategy tokens (`mode=... split_pos=... fooling=...`)
/// directly onto a `RoutingSection` in `RouterStoreData`.
pub(crate) fn apply_desync_strategy_to_section(sec: &mut RoutingSection, args_str: &str) {
    sec.desync_preset.clear();
    sec.desync_mode.clear();
    sec.desync_fooling.clear();
    sec.desync_split_pos.clear();
    sec.desync_fake_ttl = 0;
    sec.desync_fake_sni.clear();
    sec.desync_repeats = 0;
    sec.desync_split_delay_ms = 0;
    sec.desync_tlsrec_first = false;
    sec.desync_seqovl = 0;
    sec.desync_syndata = false;
    sec.desync_wsize = 0;
    sec.desync_ipfrag = false;
    sec.desync_udp_fake = false;
    sec.desync_udp_repeats = 0;
    sec.desync_udp_fake_ttl = 0;
    sec.desync_udplen = 0;
    sec.desync_host_fake = false;
    sec.desync_wscale = None;
    sec.desync_sni_pool.clear();
    sec.desync_fake_payload.clear();
    sec.desync_fake_tls.clear();
    sec.desync_opts = args_str.trim().to_string();

    let mut explicit_preset = false;
    let mut is_hostfakesplit = false;
    let mut explicit_host_fake = false;

    for tok in args_str.split_whitespace() {
        let Some((k, v)) = tok.split_once('=') else {
            continue;
        };
        let key = k.trim();
        let val = v.trim();
        if key.is_empty() || val.is_empty() {
            continue;
        }
        match key {
            "preset" => {
                sec.desync_preset = val.to_string();
                explicit_preset = true;
            }
            "mode" => {
                if val == "hostfakesplit" {
                    is_hostfakesplit = true;
                }
                sec.desync_mode = val.to_string();
            }
            "split_pos" => {
                sec.desync_split_pos = val.to_string();
            }
            "fooling" => {
                sec.desync_fooling = val.to_string();
            }
            "fake_ttl" | "ttl" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec.desync_fake_ttl = n.clamp(1, 128);
                }
            }
            "fake_sni" => {
                sec.desync_fake_sni = val.to_string();
            }
            "repeats" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec.desync_repeats = n.clamp(1, 16);
                }
            }
            "split_delay_ms" => {
                if let Ok(n) = val.parse::<u32>() {
                    sec.desync_split_delay_ms = n.min(500);
                }
            }
            "tlsrec_first" => {
                sec.desync_tlsrec_first = val == "true" || val == "1";
            }
            "seqovl" => {
                if let Ok(n) = val.parse::<u16>() {
                    sec.desync_seqovl = n;
                }
            }
            "syndata" => {
                sec.desync_syndata = val == "true" || val == "1";
            }
            "wsize" => {
                if let Ok(n) = val.parse::<u32>() {
                    sec.desync_wsize = n;
                }
            }
            "wscale" | "scale" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec.desync_wscale = Some(n.clamp(0, 14));
                }
            }
            "ipfrag" => {
                sec.desync_ipfrag = val == "true" || val == "1";
            }
            "udp_fake" | "quic_fake" => {
                sec.desync_udp_fake = val == "true" || val == "1";
            }
            "udp_repeats" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec.desync_udp_repeats = n.clamp(1, 16);
                }
            }
            "udp_fake_ttl" => {
                if let Ok(n) = val.parse::<u8>() {
                    sec.desync_udp_fake_ttl = n.clamp(1, 128);
                }
            }
            "udplen" => {
                if let Ok(n) = val.parse::<u16>() {
                    sec.desync_udplen = n;
                }
            }
            "auto_tune" => {
                sec.desync_auto_tune = val == "true" || val == "1";
            }
            "host_fake" => {
                explicit_host_fake = true;
                sec.desync_host_fake = val == "true" || val == "1";
            }
            "sni_pool" => {
                sec.desync_sni_pool = val
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect();
            }
            "fake_payload" => {
                sec.desync_fake_payload = val.to_string();
            }
            "fake_tls" => {
                sec.desync_fake_tls = val.to_string();
            }
            _ => {}
        }
    }

    if is_hostfakesplit && !explicit_host_fake {
        sec.desync_host_fake = true;
    }
    if !explicit_preset {
        sec.desync_preset = "custom".to_string();
    }
}

type BoxOpsFuture<'a> = Pin<Box<dyn Future<Output = BotReply> + Send + 'a>>;

fn sync_tg_store_json_and_cache(store: &RouterStoreData) {
    if std::env::var_os("TACHYON_DATA_DIR").is_some() || cfg!(not(test)) {
        crate::ubus_bridge::sync_from_store_to_json_and_cache(store);
    }
}

async fn commit_tx_boxed(state: &Arc<AppState>, candidate: RouterStoreData) -> anyhow::Result<()> {
    let state = Arc::clone(state);
    tokio::spawn(async move {
        Box::pin(transaction::commit_transaction(&state, candidate))
            .await
            .map(|_| ())?;
        let saved = state.data.read().await.clone();
        sync_tg_store_json_and_cache(&saved);
        Ok(())
    })
    .await
    .map_err(|e| anyhow::anyhow!("commit task panicked: {e}"))?
}

async fn reload_core_boxed(core: &Arc<CoreManager>) {
    let core = Arc::clone(core);
    let _ = tokio::spawn(async move { Box::pin(core.apply_or_reload()).await }).await;
}

async fn update_telegram_cfg<F>(
    state: &Arc<AppState>,
    mutator: F,
) -> anyhow::Result<RouterStoreData>
where
    F: FnOnce(&mut TgBotConfig) -> anyhow::Result<()>,
{
    let mut candidate = state.data.read().await.clone();
    mutator(&mut candidate.telegram)?;
    let tg_copy = candidate.telegram.clone();
    commit_tx_boxed(state, candidate.clone()).await?;
    ubus_bridge::sync_telegram_section_to_json(&tg_copy);
    notify_bot_wakeup();
    Ok(candidate)
}

fn format_bytes_human(bytes: u64) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.2} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

// ---------------------------------------------------------------------------
// 1. Diagnostics, AI Doctor, Trace, DNS, Leaks, Failover, Logs, Support
// ---------------------------------------------------------------------------

async fn render_doctor(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let rep = Box::pin(diagnostics::run_local_doctor_with_core(state, core)).await;

    let mut lines = Vec::new();
    let badge = if rep.healthy { "[OK]" } else { "[!]" };
    lines.push(format!(
        "<b>{}</b> {} ({}/{})",
        tr(ru, "Диагностика Tachyon", "Tachyon Diagnostics"),
        badge,
        rep.checks_passed,
        rep.checks_total
    ));
    lines.push(escape_html(&rep.summary));

    if !rep.findings.is_empty() {
        lines.push(String::new());
        lines.push(format!(
            "<b>{}:</b>",
            tr(ru, "Обнаруженные замечания", "Findings")
        ));
        for f in rep.findings.iter().take(8) {
            lines.push(format!(
                "[!] <b>{}</b> — {}",
                escape_html(&f.title),
                escape_html(&f.detail)
            ));
        }
    }

    if !rep.subsystems.is_empty() {
        lines.push(String::new());
        lines.push(format!("<b>{}:</b>", tr(ru, "Подсистемы", "Subsystems")));
        for sub in rep.subsystems.iter().take(15) {
            let name = sub.get("name").and_then(Value::as_str).unwrap_or("");
            let status = sub.get("status").and_then(Value::as_str).unwrap_or("ok");
            let detail = sub.get("detail").and_then(Value::as_str).unwrap_or("");
            let st = if status == "ok" { "[OK]" } else { "[!]" };
            lines.push(format!(
                "{st} {} — <code>{}</code>",
                escape_html(name),
                escape_html(detail)
            ));
        }
    }

    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut seen_fixes: HashSet<String> = HashSet::new();
    let mut finding_btns: Vec<Value> = Vec::new();
    for f in &rep.findings {
        let fid = f.quick_fix_id.trim();
        if fid.is_empty() || !seen_fixes.insert(fid.to_string()) {
            continue;
        }
        let lbl = if f.quick_fix_label.trim().is_empty() {
            fid.to_string()
        } else {
            f.quick_fix_label.clone()
        };
        finding_btns.push(cb_btn(&format!("[Fix] {lbl}"), &format!("fix_apply {fid}")));
    }
    for chunk in finding_btns.chunks(2) {
        rows.push(chunk.to_vec());
    }

    // Standard quick-fix actions
    rows.push(vec![
        cb_btn(
            tr(ru, "Перезапуск ядра", "Restart Core"),
            "fix_apply restart_core",
        ),
        cb_btn(
            tr(ru, "Перестроить nftables", "Rebuild nftables"),
            "fix_apply heal_network_stack",
        ),
    ]);
    rows.push(vec![
        cb_btn(
            tr(ru, "Откл. Flow Offload", "Disable Flow Offload"),
            "fix_apply disable_flow_offloading",
        ),
        cb_btn(
            tr(ru, "Сброс кэша DNS", "Flush DNS"),
            "fix_apply clear_dns_cache",
        ),
    ]);
    rows.push(vec![
        cb_btn(
            tr(ru, "Откат к LKG", "Rollback LKG"),
            "fix_apply rollback_known_good",
        ),
        cb_btn(tr(ru, "AI Doctor", "AI Doctor"), "ai_doc_run"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Утечки", "Leak Check"), "leak_run"),
        cb_btn(tr(ru, "Трассировка", "Route Trace"), "trace_menu"),
        cb_btn(tr(ru, "Отчёт JSON", "Support Bundle"), "support_bundle"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Обновить", "Refresh"), "doc_run"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]);

    BotReply::with_kb(
        truncate_for_tg(&lines.join("\n"), TG_TEXT_BUDGET),
        inline_kb(rows),
    )
}

fn render_fix_menu(ru: bool) -> BotReply {
    let text = format!(
        "<b>{}</b>\n{}",
        tr(ru, "Быстрые исправления", "Quick Fixes"),
        tr(
            ru,
            "Выберите действие или используйте <code>/fix &lt;fix_id&gt;</code>.",
            "Choose an action or run <code>/fix &lt;fix_id&gt;</code>."
        )
    );
    let rows = vec![
        vec![
            cb_btn(
                tr(ru, "Перезапуск ядра", "Restart Core"),
                "fix_apply restart_core",
            ),
            cb_btn(
                tr(ru, "Перестроить nftables", "Rebuild nftables"),
                "fix_apply heal_network_stack",
            ),
        ],
        vec![
            cb_btn(
                tr(ru, "Откл. Flow Offload", "Disable Flow Offload"),
                "fix_apply disable_flow_offloading",
            ),
            cb_btn(
                tr(ru, "Сброс кэша DNS", "Flush DNS"),
                "fix_apply clear_dns_cache",
            ),
        ],
        vec![
            cb_btn(
                tr(ru, "Сжать память", "Optimize RAM"),
                "fix_apply optimize_memory",
            ),
            cb_btn(
                tr(ru, "Откат к LKG", "Rollback LKG"),
                "fix_apply rollback_known_good",
            ),
        ],
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ];
    BotReply::with_kb(text, inline_kb(rows))
}

async fn run_quick_fix_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    raw_fix_id: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let fix_id = normalize_fix_id(raw_fix_id);
    if fix_id.is_empty() {
        return render_fix_menu(ru);
    }

    let res = Box::pin(diagnostics::apply_quick_fix(state, core, fix_id)).await;
    if res.is_ok() {
        let d = state.data.read().await.clone();
        ubus_bridge::sync_telegram_section_to_json(&d.telegram);
        notify_bot_wakeup();
    }
    let text = match res {
        Ok(msg) => format!(
            "[OK] <b>{}</b> (<code>{}</code>)\n{}",
            tr(ru, "Исправление выполнено", "Quick fix applied"),
            escape_html(fix_id),
            escape_html(&msg)
        ),
        Err(e) => format!(
            "[ERR] <b>{}</b> (<code>{}</code>)\n{}",
            tr(ru, "Ошибка исправления", "Quick fix failed"),
            escape_html(fix_id),
            escape_html(&e.to_string())
        ),
    };

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
            cb_btn(tr(ru, "Все фиксы", "All Fixes"), "/fix"),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn render_ai_doctor(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    query: Option<&str>,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let clean_query = query.map(str::trim).filter(|s| !s.is_empty());
    let res = Box::pin(diagnostics::run_ai_doctor_with_core(
        state,
        Some(core),
        clean_query,
    ))
    .await;
    let analysis = res.get("analysis").and_then(Value::as_str).unwrap_or("OK");

    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut rec_btns: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    if let Some(recs) = res.get("recommendations").and_then(Value::as_array) {
        for r in recs.iter().take(6) {
            let fid = r.get("fix_id").and_then(Value::as_str).unwrap_or("").trim();
            if fid.is_empty() || !seen.insert(fid.to_string()) {
                continue;
            }
            let lbl = r
                .get("label")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(fid);
            rec_btns.push(cb_btn(&format!("[Fix] {lbl}"), &format!("fix_apply {fid}")));
        }
    }
    for chunk in rec_btns.chunks(2) {
        rows.push(chunk.to_vec());
    }
    rows.push(vec![
        cb_btn(tr(ru, "Задать вопрос", "Ask Question"), "ai_doc_ask"),
        cb_btn(tr(ru, "Обновить анализ", "Re-run"), "ai_doc_run"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]);

    let body = format!(
        "<b>{}</b>\n<pre>{}</pre>",
        tr(ru, "Заключение AI Doctor", "AI Doctor Report"),
        escape_html(&truncate_for_tg(analysis, 3200))
    );
    BotReply::with_kb(body, inline_kb(rows))
}

fn render_trace_menu(ru: bool) -> BotReply {
    let text = format!(
        "<b>{}</b>\n{}",
        tr(ru, "Трассировка маршрута пакета", "Packet Route Trace"),
        tr(
            ru,
            "Выберите быстрый пресет или введите <code>/trace &lt;домен&gt; [IP_клиента]</code>.",
            "Pick a quick preset or send <code>/trace &lt;domain&gt; [client_ip]</code>."
        )
    );
    let kb = inline_kb(vec![
        vec![
            cb_btn("youtube.com", "/trace youtube.com"),
            cb_btn("discord.com", "/trace discord.com"),
        ],
        vec![
            cb_btn("1.1.1.1", "/trace 1.1.1.1"),
            cb_btn(
                tr(ru, "Свой домен / IP", "Custom Domain / IP"),
                "trace_prompt",
            ),
        ],
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(text, kb)
}

async fn run_trace_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    raw_input: &str,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let nft_active = state.live.read().await.nft_table_active;

    let mut parts = raw_input.split_whitespace();
    let raw_target = parts.next().unwrap_or("").trim();
    if raw_target.is_empty() {
        return render_trace_menu(ru);
    }
    let target = sanitize_trace_target(raw_target);
    let effective_target = if target.is_empty() {
        "example.com".to_string()
    } else {
        target
    };
    let client_ip = parts
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("192.168.1.100");

    let mut trace = Box::pin(diagnostics::explain_route_with_engine(
        core,
        &d,
        client_ip,
        &effective_target,
        443,
        "tcp",
    ))
    .await;

    if trace.get("verdict").is_none() {
        trace = diagnostics::build_route_trace_json(
            &d,
            client_ip,
            &effective_target,
            &effective_target,
            443,
            "tcp",
            nft_active,
        );
    }

    let verdict = trace.get("verdict").and_then(Value::as_str).unwrap_or("-");
    let section = trace
        .get("matched_section")
        .and_then(Value::as_str)
        .unwrap_or("-");
    let outbound = trace
        .get("selected_outbound")
        .and_then(Value::as_str)
        .unwrap_or("-");
    let conn_type = trace
        .get("connection_type")
        .and_then(Value::as_str)
        .unwrap_or("-");
    let reason = trace
        .get("matched_reason")
        .and_then(Value::as_str)
        .unwrap_or("-");

    let mut lines = vec![
        format!("<b>{}</b>", tr(ru, "Трассировка маршрута", "Route Trace")),
        format!(
            "{}: <code>{}</code> -> <code>{}:443</code>",
            tr(ru, "Клиент", "Client"),
            escape_html(client_ip),
            escape_html(&effective_target)
        ),
        format!(
            "{}: <b>{}</b> | {}: <code>{}</code>",
            tr(ru, "Вердикт", "Verdict"),
            escape_html(verdict),
            tr(ru, "Тип", "Mode"),
            escape_html(conn_type)
        ),
        format!(
            "{}: <b>{}</b> -> <code>{}</code>",
            tr(ru, "Секция / Outbound", "Section / Outbound"),
            escape_html(section),
            escape_html(outbound)
        ),
        format!("{}: {}", tr(ru, "Причина", "Reason"), escape_html(reason)),
    ];

    if let Some(steps) = trace.get("trace_steps").and_then(Value::as_array)
        && !steps.is_empty()
    {
        lines.push(String::new());
        lines.push(format!("<b>{}:</b>", tr(ru, "Этапы", "Steps")));
        for s in steps.iter().take(8) {
            if let Some(txt) = s.as_str() {
                lines.push(format!("- {}", escape_html(txt)));
            }
        }
    }

    if let Some(eng) = trace.get("engine_route_check") {
        let out_ok = eng
            .pointer("/outbound_probe/ok")
            .and_then(Value::as_bool)
            .map(|b| if b { "[OK]" } else { "[ERR]" })
            .unwrap_or("-");
        let dir_ok = eng
            .pointer("/direct_probe/ok")
            .and_then(Value::as_bool)
            .map(|b| if b { "[OK]" } else { "[ERR]" })
            .unwrap_or("-");
        lines.push(String::new());
        lines.push(format!(
            "<b>{}:</b> outbound={out_ok}, direct={dir_ok}",
            tr(ru, "Живая проверка ядра", "Live Engine Probe")
        ));
    }

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Другой домен", "Trace Another"), "trace_prompt"),
            cb_btn(tr(ru, "Меню трассировки", "Trace Menu"), "trace_menu"),
        ],
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(truncate_for_tg(&lines.join("\n"), TG_TEXT_BUDGET), kb)
}

async fn render_dns_menu(state: &Arc<AppState>) -> BotReply {
    let (d, dns_healthy) = {
        let data = state.data.read().await.clone();
        let live = state.live.read().await;
        (data, live.dns_healthy)
    };
    let ru = is_ru(&d);
    let servers = if d.settings.dns_servers.is_empty() {
        "-".to_string()
    } else {
        d.settings.dns_servers.join(", ")
    };
    let boot = if d.settings.bootstrap_dns_servers.is_empty() {
        "-".to_string()
    } else {
        d.settings.bootstrap_dns_servers.join(", ")
    };

    let text = format!(
        "<b>{}</b>\n\
         {}: {}\n\
         {}: <code>{}</code>\n\
         {}: <code>{}</code>\n\
         Bootstrap: <code>{}</code>\n\
         FakeIP: <code>{}</code> | Block DoH: <code>{}</code> | WebRTC: <code>{}</code>",
        tr(ru, "Настройки и проверка DNS", "DNS Diagnostics & Presets"),
        tr(ru, "Состояние", "Health"),
        if dns_healthy { "[OK]" } else { "[!]" },
        tr(ru, "Тип DNS", "DNS Type"),
        escape_html(&d.settings.dns_type),
        tr(ru, "Серверы", "Servers"),
        escape_html(&servers),
        escape_html(&boot),
        if d.settings.fakeip_enabled {
            "ON"
        } else {
            "OFF"
        },
        if d.settings.block_doh { "ON" } else { "OFF" },
        if d.settings.webrtc_leak_protect {
            "ON"
        } else {
            "OFF"
        }
    );

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Проверить домен", "Check Domain"), "dns_check"),
            cb_btn(tr(ru, "Тест скорости DNS", "DNS Benchmark"), "dns_bench"),
        ],
        vec![
            cb_btn("Cloudflare DoH", "dns_preset cloudflare"),
            cb_btn("Google DoH", "dns_preset google"),
        ],
        vec![
            cb_btn("Quad9 DoH", "dns_preset quad9"),
            cb_btn("AdGuard DoH", "dns_preset adguard"),
        ],
        vec![
            cb_btn(tr(ru, "Проверка утечек", "Leak Check"), "leak_run"),
            cb_btn(
                tr(ru, "Сброс кэша DNS", "Flush Cache"),
                "fix_apply clear_dns_cache",
            ),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn run_dns_check_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    raw_domain: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let clean = sanitize_trace_target(raw_domain);
    let domain = if clean.is_empty() {
        "www.youtube.com".to_string()
    } else {
        clean
    };
    let res = Box::pin(diagnostics::run_dns_check_with_engine(core, &domain)).await;
    let ok = res.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let err = res.get("error").and_then(Value::as_str).unwrap_or("");
    let pretty = serde_json::to_string_pretty(&res).unwrap_or_else(|_| "{}".to_string());

    let text = if !err.is_empty() && !ok {
        format!(
            "[!] <b>{}</b> (<code>{}</code>)\n{}",
            tr(ru, "Проверка DNS", "DNS Check"),
            escape_html(&domain),
            escape_html(err)
        )
    } else {
        format!(
            "{} <b>{}</b> (<code>{}</code>)\n<pre>{}</pre>",
            if ok { "[OK]" } else { "[!]" },
            tr(ru, "Результат проверки DNS", "DNS Check Result"),
            escape_html(&domain),
            escape_html(&truncate_for_tg(&pretty, 2800))
        )
    };

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Другой домен", "Check Another"), "dns_check"),
            cb_btn(tr(ru, "Меню DNS", "DNS Menu"), "dns_menu"),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn run_dns_bench_reply(state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let entries = Box::pin(diagnostics::run_dns_speed_test()).await;
    let mut lines = vec![format!(
        "<b>{}</b>",
        tr(ru, "Тест скорости DNS-серверов", "DNS Speed Benchmark")
    )];
    for e in &entries {
        let st = if e.reachable { "[OK]" } else { "[ERR]" };
        let rtt = if e.reachable {
            format!("{} ms", e.latency_ms)
        } else {
            "timeout".to_string()
        };
        lines.push(format!(
            "{st} <code>{}</code> — {} (<b>{}</b>)",
            escape_html(&e.server),
            escape_html(&e.protocol),
            escape_html(&rtt)
        ));
    }
    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Повторить", "Re-run"), "dns_bench"),
            cb_btn(tr(ru, "Меню DNS", "DNS Menu"), "dns_menu"),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(lines.join("\n"), kb)
}

async fn apply_dns_preset_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    preset: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let (label, servers) = match preset.trim().to_ascii_lowercase().as_str() {
        "cloudflare" => (
            "Cloudflare DoH",
            vec![
                "https://1.1.1.1/dns-query".to_string(),
                "https://1.0.0.1/dns-query".to_string(),
            ],
        ),
        "google" => (
            "Google DoH",
            vec![
                "https://dns.google/dns-query".to_string(),
                "https://8.8.8.8/dns-query".to_string(),
            ],
        ),
        "quad9" => (
            "Quad9 DoH",
            vec![
                "https://dns.quad9.net/dns-query".to_string(),
                "https://9.9.9.9/dns-query".to_string(),
            ],
        ),
        "adguard" => (
            "AdGuard DoH",
            vec![
                "https://dns.adguard-dns.com/dns-query".to_string(),
                "https://94.140.14.14/dns-query".to_string(),
            ],
        ),
        other => {
            return BotReply::with_kb(
                format!(
                    "[ERR] {}: <code>{}</code>",
                    tr(ru, "Неизвестный пресет DNS", "Unknown DNS preset"),
                    escape_html(other)
                ),
                inline_kb(vec![vec![cb_btn(
                    tr(ru, "Меню DNS", "DNS Menu"),
                    "dns_menu",
                )]]),
            );
        }
    };

    let mut candidate = state.data.read().await.clone();
    candidate.settings.dns_type = "doh".to_string();
    candidate.settings.dns_servers = servers.clone();
    let res = commit_tx_boxed(state, candidate).await;
    if res.is_ok() {
        reload_core_boxed(core).await;
    }

    let text = match res {
        Ok(_) => format!(
            "[OK] <b>{}</b>: {}\n<code>{}</code>",
            tr(ru, "DNS обновлён", "DNS Updated"),
            escape_html(label),
            escape_html(&servers.join(", "))
        ),
        Err(e) => format!(
            "[ERR] {}: {}",
            tr(ru, "Не удалось сохранить DNS", "Failed to save DNS"),
            escape_html(&e.to_string())
        ),
    };
    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Меню DNS", "DNS Menu"), "dns_menu"),
            cb_btn(tr(ru, "Тест скорости", "Benchmark"), "dns_bench"),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn run_leak_reply(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let res = Box::pin(diagnostics::run_leak_check(state, Some(core))).await;
    let core_on = res
        .get("core_running")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let nft_on = res
        .get("nft_table_active")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let dns_reach = res
        .get("dns_listener_reachable")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let fakeip_range = res
        .get("fakeip_range")
        .and_then(Value::as_str)
        .unwrap_or("198.18.0.0/15");
    let fakeip_v6_range = res
        .get("fakeip_inet6_range")
        .and_then(Value::as_str)
        .unwrap_or("fc00::/18");
    let ipv6_state_str = res
        .get("ipv6_effective_state")
        .and_then(Value::as_str)
        .unwrap_or("disabled");
    let ipv6_leaked = res
        .get("ipv6_leaked")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let dns_type = res.get("dns_type").and_then(Value::as_str).unwrap_or("-");
    let webrtc = res
        .get("webrtc_leak_protect")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let block_doh = res
        .get("block_doh")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let verdict = res.get("verdict").and_then(Value::as_str).unwrap_or("-");

    let mut lines = vec![
        format!(
            "<b>{}</b>",
            tr(
                ru,
                "Аудит утечек DNS / WebRTC / IPv6",
                "DNS / WebRTC / IPv6 Leak Check"
            )
        ),
        format!(
            "IPv6: {} | {}: {} | FakeIP: {}, {}",
            ipv6_state_str,
            tr(ru, "Утечка IPv6", "IPv6 leak"),
            if ipv6_leaked {
                tr(ru, "ДА", "YES")
            } else {
                tr(ru, "нет", "no")
            },
            fakeip_range,
            fakeip_v6_range
        ),
        format!(
            "{}: {} | nftables: {} | DNS listener: {}",
            tr(ru, "Ядро", "Core"),
            if core_on { "[OK]" } else { "[OFF]" },
            if nft_on { "[OK]" } else { "[OFF]" },
            if dns_reach { "[OK]" } else { "[!]" }
        ),
        format!(
            "FakeIP: <code>{}</code> | DNS: <code>{}</code>",
            escape_html(fakeip_range),
            escape_html(dns_type)
        ),
        format!(
            "WebRTC protect: <code>{}</code> | Block DoH: <code>{}</code>",
            if webrtc { "ON" } else { "OFF" },
            if block_doh { "ON" } else { "OFF" }
        ),
        format!(
            "<b>{}:</b> {}",
            tr(ru, "Итог", "Verdict"),
            escape_html(verdict)
        ),
    ];

    if let Some(eng) = res.get("engine_leak_audit")
        && !eng.is_null()
    {
        let pretty = serde_json::to_string_pretty(eng).unwrap_or_default();
        if !pretty.is_empty() {
            lines.push(format!(
                "<pre>{}</pre>",
                escape_html(&truncate_for_tg(&pretty, 1400))
            ));
        }
    }

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Повторить", "Re-run"), "leak_run"),
            cb_btn(tr(ru, "Меню DNS", "DNS Menu"), "dns_menu"),
        ],
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(lines.join("\n"), kb)
}

async fn render_failover_view(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let info = core.get_core_failover().await;
    let groups = info
        .get("groups")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut lines = vec![format!(
        "<b>{}</b>",
        tr(ru, "Состояние Failover маршрутов", "Route Failover Status")
    )];
    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut restore_btns: Vec<Value> = Vec::new();

    if groups.is_empty() {
        lines.push(
            tr(
                ru,
                "Активных групп переключения не обнаружено (или ядро не отвечает).",
                "No active failover groups reported (or core is offline).",
            )
            .to_string(),
        );
    } else {
        for g in groups.iter().take(12) {
            let tag = g
                .get("tag")
                .or_else(|| g.get("group"))
                .or_else(|| g.get("name"))
                .and_then(Value::as_str)
                .unwrap_or("group");
            let active = g
                .get("active")
                .or_else(|| g.get("now"))
                .or_else(|| g.get("current"))
                .and_then(Value::as_str)
                .unwrap_or("-");
            let primary = g.get("primary").and_then(Value::as_str).unwrap_or("");
            let degraded = g
                .get("degraded")
                .or_else(|| g.get("failed"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let badge = if degraded { "[!]" } else { "[OK]" };
            if primary.is_empty() {
                lines.push(format!(
                    "{badge} <b>{}</b> -> <code>{}</code>",
                    escape_html(tag),
                    escape_html(active)
                ));
            } else {
                lines.push(format!(
                    "{badge} <b>{}</b> -> <code>{}</code> (primary: <code>{}</code>)",
                    escape_html(tag),
                    escape_html(active),
                    escape_html(primary)
                ));
            }
            if restore_btns.len() < 6 {
                restore_btns.push(cb_btn(
                    &format!("{} {tag}", tr(ru, "Сброс", "Restore")),
                    &format!("failover_restore {tag}"),
                ));
            }
        }
    }

    for chunk in restore_btns.chunks(2) {
        rows.push(chunk.to_vec());
    }
    rows.push(vec![
        cb_btn(
            tr(ru, "Перепроверить маршруты", "Recheck Routes"),
            "failover_recheck",
        ),
        cb_btn(tr(ru, "Обновить", "Refresh"), "failover_view"),
    ]);
    rows.push(vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")]);

    BotReply::with_kb(
        truncate_for_tg(&lines.join("\n"), TG_TEXT_BUDGET),
        inline_kb(rows),
    )
}

async fn run_failover_restore_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    tag: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let clean_tag = tag.trim();
    if clean_tag.is_empty() {
        return render_failover_view(state, core).await;
    }
    let res = core.restore_core_failover(clean_tag).await;
    let ok = res.get("ok").and_then(Value::as_bool).unwrap_or(true);
    let text = format!(
        "{} <b>{}</b>: <code>{}</code>",
        if ok { "[OK]" } else { "[!]" },
        tr(ru, "Восстановление failover", "Failover Restore"),
        escape_html(clean_tag)
    );
    let kb = inline_kb(vec![
        vec![cb_btn(
            tr(ru, "К failover", "Failover View"),
            "failover_view",
        )],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn run_failover_recheck_reply(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let res = core.recheck_core_routes().await;
    let ok = res.get("ok").and_then(Value::as_bool).unwrap_or(true);
    let text = format!(
        "{} {}",
        if ok { "[OK]" } else { "[!]" },
        tr(
            ru,
            "Запущена перепроверка маршрутов в ядре tachyon-core.",
            "Triggered route health recheck in tachyon-core."
        )
    );
    let kb = inline_kb(vec![
        vec![cb_btn(
            tr(ru, "К failover", "Failover View"),
            "failover_view",
        )],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn render_logs_view(state: &Arc<AppState>, arg: &str) -> BotReply {
    let count = arg
        .split_whitespace()
        .next()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(25)
        .clamp(1, 50);

    let (ru, entries) = {
        let d = state.data.read().await;
        let live = state.live.read().await;
        let mut combined: Vec<String> = Vec::new();
        for ev in live.events.iter().rev().take(count).rev() {
            let msg = crypto_gen::redact_string(&ev.message);
            combined.push(format!(
                "[{}][{}/{}] {}",
                ev.timestamp, ev.level, ev.subsystem, msg
            ));
        }
        if combined.len() < count {
            let rem = count - combined.len();
            for line in live.recent_logs.iter().rev().take(rem).rev() {
                combined.push(crypto_gen::redact_string(line));
            }
        }
        (is_ru(&d), combined)
    };

    let mut body = String::new();
    if entries.is_empty() {
        body.push_str(tr(ru, "Журнал событий пуст.", "Event log is empty."));
    } else {
        // Keep newest lines within Telegram HTML limits
        let mut kept: Vec<String> = Vec::new();
        let mut total_chars = 0usize;
        for line in entries.iter().rev() {
            let esc = escape_html(line);
            if total_chars + esc.chars().count() + 1 > 3100 {
                break;
            }
            total_chars += esc.chars().count() + 1;
            kept.push(esc);
        }
        kept.reverse();
        body = format!("<pre>{}</pre>", kept.join("\n"));
    }

    let text = format!(
        "<b>{} ({})</b>\n{}",
        tr(ru, "Журнал и события", "Logs & Events"),
        entries.len(),
        body
    );
    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Обновить", "Refresh"), "logs_view"),
            cb_btn(tr(ru, "Отчёт JSON", "Support Bundle"), "support_bundle"),
        ],
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(text, kb)
}

async fn build_support_bundle_reply(state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let raw_bundle = Box::pin(diagnostics::build_support_bundle(state)).await;
    let redacted = crypto_gen::redact_json_value(&raw_bundle);
    let bytes = serde_json::to_vec_pretty(&redacted).unwrap_or_else(|_| b"{}".to_vec());

    let healthy = redacted
        .pointer("/doctor/healthy")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let size_label = format_bytes_human(bytes.len() as u64);
    let caption = format!(
        "{}: {} ({})",
        tr(ru, "Пакет диагностики", "Support bundle"),
        if healthy { "healthy" } else { "warnings" },
        size_label
    );
    let text = format!(
        "[OK] <b>{}</b>\n{}: <code>tachyon-support-bundle.json</code> (<code>{}</code>)\n{}",
        tr(ru, "Пакет поддержки сформирован", "Support Bundle Ready"),
        tr(ru, "Файл", "File"),
        escape_html(&size_label),
        tr(
            ru,
            "Токены, пароли и приватные ключи автоматически скрыты.",
            "Tokens, passwords, and private keys are redacted."
        )
    );
    let kb = inline_kb(vec![vec![
        cb_btn(tr(ru, "Диагностика", "Doctor"), "doc_run"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]]);
    BotReply::with_doc(
        text,
        Some(kb),
        "tachyon-support-bundle.json",
        bytes,
        caption,
    )
}

// ---------------------------------------------------------------------------
// 2. Desync Strategy Fuzzer
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
struct FuzzerWinner {
    name: String,
    args: String,
    score: i64,
    ttfb_ms: u64,
}

fn collect_fuzzer_winners(status: &Value) -> Vec<FuzzerWinner> {
    let mut out = Vec::new();
    if let Some(arr) = status.get("results").and_then(Value::as_array) {
        for r in arr {
            if r.get("success").and_then(Value::as_bool) != Some(true) {
                continue;
            }
            let args = r.get("args").and_then(Value::as_str).unwrap_or("").trim();
            if args.is_empty() {
                continue;
            }
            let name = r
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("Desync Strategy")
                .to_string();
            let score = r.get("score").and_then(Value::as_i64).unwrap_or(0);
            let ttfb_ms = r
                .get("ttfb_ms")
                .or_else(|| r.get("time_ms"))
                .and_then(Value::as_u64)
                .unwrap_or(0);
            out.push(FuzzerWinner {
                name,
                args: args.to_string(),
                score,
                ttfb_ms,
            });
            if out.len() >= 5 {
                break;
            }
        }
    }
    if out.is_empty()
        && let Some(best) = status.get("best_strategy").filter(|v| v.is_object())
    {
        let args = best
            .get("args")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if !args.is_empty() {
            out.push(FuzzerWinner {
                name: best
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("Best Strategy")
                    .to_string(),
                args: args.to_string(),
                score: best.get("score").and_then(Value::as_i64).unwrap_or(0),
                ttfb_ms: best
                    .get("ttfb_ms")
                    .or_else(|| best.get("time_ms"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
            });
        }
    }
    out
}

async fn render_fuzzer_view(state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let st = fuzzer::get_status();
    let running = st.get("running").and_then(Value::as_bool).unwrap_or(false);
    let target = st.get("target").and_then(Value::as_str).unwrap_or("-");
    let mode = st.get("mode").and_then(Value::as_str).unwrap_or("-");
    let phase = st.get("phase").and_then(Value::as_str).unwrap_or("idle");
    let pct = st.get("progress_pct").and_then(Value::as_u64).unwrap_or(0);
    let cur_idx = st.get("current_index").and_then(Value::as_u64).unwrap_or(0);
    let total = st
        .get("total_strategies")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let winners = collect_fuzzer_winners(&st);

    let mut lines = vec![
        format!(
            "<b>{}</b>",
            tr(
                ru,
                "Подбор стратегий десинхронизации",
                "Desync Strategy Fuzzer"
            )
        ),
        format!(
            "{}: {} | {}: <code>{}</code> ({})",
            tr(ru, "Статус", "State"),
            if running { "[RUNNING]" } else { "[IDLE]" },
            tr(ru, "Цель", "Target"),
            escape_html(target),
            escape_html(mode)
        ),
        format!(
            "{}: <code>{}</code> ({pct}% · {cur_idx}/{total})",
            tr(ru, "Этап", "Phase"),
            escape_html(phase)
        ),
    ];

    if let Some(err) = st
        .get("error")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        lines.push(format!("[!] {}", escape_html(err)));
    }

    if !winners.is_empty() {
        lines.push(String::new());
        lines.push(format!(
            "<b>{}:</b>",
            tr(ru, "Рабочие стратегии", "Passing Strategies")
        ));
        for (i, w) in winners.iter().enumerate() {
            lines.push(format!(
                "#{}: <b>{}</b> (score {}, {} ms)\n<code>{}</code>",
                i + 1,
                escape_html(&w.name),
                w.score,
                w.ttfb_ms,
                escape_html(&w.args)
            ));
        }
    }

    let mut rows: Vec<Vec<Value>> = Vec::new();
    if !winners.is_empty() {
        let apply_btns: Vec<Value> = winners
            .iter()
            .enumerate()
            .take(3)
            .map(|(i, _)| {
                cb_btn(
                    &format!("{} #{}", tr(ru, "Применить", "Apply"), i + 1),
                    &format!("fuz_apply_menu {i}"),
                )
            })
            .collect();
        rows.push(apply_btns);
    }

    rows.push(vec![
        cb_btn("YouTube (Fast)", "fuz_start youtube presets"),
        cb_btn("YouTube (Deep)", "fuz_start youtube deep"),
    ]);
    rows.push(vec![
        cb_btn("Discord", "fuz_start discord presets"),
        cb_btn("Telegram", "fuz_start telegram presets"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Свой домен", "Custom Target"), "fuz_custom"),
        if running {
            cb_btn(tr(ru, "Остановить", "Stop"), "fuz_stop")
        } else {
            cb_btn(tr(ru, "Обновить", "Refresh"), "fuz_view")
        },
    ]);
    if running {
        rows.push(vec![
            cb_btn(tr(ru, "Обновить прогресс", "Refresh"), "fuz_view"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ]);
    } else {
        rows.push(vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")]);
    }

    BotReply::with_kb(
        truncate_for_tg(&lines.join("\n"), TG_TEXT_BUDGET),
        inline_kb(rows),
    )
}

async fn start_fuzzer_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    target: &str,
    custom_url: &str,
    mode: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let bin_path = core.resolve_bin_path().await;
    let timeout_secs = if mode.eq_ignore_ascii_case("deep") {
        240
    } else {
        90
    };
    let res = fuzzer::start_benchmark(
        bin_path,
        "desync",
        target,
        custom_url,
        "",
        "",
        mode,
        timeout_secs,
    )
    .await;
    let ok = res.get("success").and_then(Value::as_bool).unwrap_or(false);
    if !ok {
        let err = res
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Failed to start benchmark");
        return BotReply::with_kb(
            format!(
                "[ERR] <b>{}</b>\n{}",
                tr(ru, "Не удалось запустить подбор", "Failed to start fuzzer"),
                escape_html(err)
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "К фаззеру", "Fuzzer"), "fuz_view"),
                cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
            ]]),
        );
    }
    let total = res
        .get("total_strategies")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let text = format!(
        "[OK] <b>{}</b>\n{}: <code>{}</code> ({})\n{}: <code>{}</code>",
        tr(ru, "Подбор стратегий запущен", "Strategy Fuzzer Started"),
        tr(ru, "Цель", "Target"),
        escape_html(if custom_url.is_empty() {
            target
        } else {
            custom_url
        }),
        escape_html(mode),
        tr(ru, "Стратегий в очереди", "Queued strategies"),
        total
    );
    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Прогресс", "Refresh Status"), "fuz_view"),
            cb_btn(tr(ru, "Остановить", "Stop"), "fuz_stop"),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn stop_fuzzer_reply(state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let _ = fuzzer::stop().await;
    let kb = inline_kb(vec![vec![
        cb_btn(tr(ru, "Результаты", "Results"), "fuz_view"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]]);
    BotReply::with_kb(
        format!(
            "[OK] {}",
            tr(
                ru,
                "Подбор стратегий остановлен.",
                "Strategy fuzzer stopped."
            )
        ),
        kb,
    )
}

async fn render_fuzzer_apply_menu(state: &Arc<AppState>, rank: usize) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let st = fuzzer::get_status();
    let winners = collect_fuzzer_winners(&st);
    let Some(winner) = winners.get(rank) else {
        return BotReply::with_kb(
            format!(
                "[!] {}",
                tr(
                    ru,
                    "Рабочая стратегия с таким номером не найдена. Запустите подбор.",
                    "Selected passing strategy not found. Run the fuzzer first."
                )
            ),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "fuz_view")]]),
        );
    };

    let desync_secs: Vec<&RoutingSection> = d
        .sections
        .iter()
        .filter(|s| s.enabled && is_desync_section(s))
        .collect();

    let mut rows: Vec<Vec<Value>> = Vec::new();
    for sec in &desync_secs {
        let lbl = if sec.label.trim().is_empty() {
            sec.id.as_str()
        } else {
            sec.label.as_str()
        };
        rows.push(vec![cb_btn(
            &format!("-> {lbl} ({})", sec.id),
            &format!("fuz_apply {rank} {}", sec.id),
        )]);
    }
    rows.push(vec![
        cb_btn(tr(ru, "Назад", "Back"), "fuz_view"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]);

    let hint = if desync_secs.is_empty() {
        tr(
            ru,
            "Нет включённых секций с типом desync.",
            "No enabled sections with type desync.",
        )
    } else {
        tr(
            ru,
            "Выберите секцию desync для применения стратегии:",
            "Choose a desync section to apply this strategy:",
        )
    };
    let text = format!(
        "<b>{} #{}</b>\n{}\n<code>{}</code>\n\n{}",
        tr(ru, "Применение стратегии", "Apply Strategy"),
        rank + 1,
        escape_html(&winner.name),
        escape_html(&winner.args),
        hint
    );
    BotReply::with_kb(text, inline_kb(rows))
}

async fn apply_fuzzer_strategy_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    rank: usize,
    sec_id: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let st = fuzzer::get_status();
    let winners = collect_fuzzer_winners(&st);
    let Some(winner) = winners.get(rank) else {
        return BotReply::with_kb(
            format!(
                "[ERR] {}",
                tr(ru, "Стратегия не найдена.", "Strategy not found.")
            ),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "fuz_view")]]),
        );
    };

    let mut candidate = state.data.read().await.clone();
    let Some(sec) = candidate
        .sections
        .iter_mut()
        .find(|s| s.id == sec_id && s.enabled && is_desync_section(s))
    else {
        return BotReply::with_kb(
            format!(
                "[ERR] {}: <code>{}</code>",
                tr(
                    ru,
                    "Активная desync-секция не найдена",
                    "Enabled desync section not found"
                ),
                escape_html(sec_id)
            ),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "fuz_view")]]),
        );
    };

    apply_desync_strategy_to_section(sec, &winner.args);
    let sec_label = if sec.label.is_empty() {
        sec.id.clone()
    } else {
        sec.label.clone()
    };

    match commit_tx_boxed(state, candidate).await {
        Ok(_) => {
            reload_core_boxed(core).await;
            BotReply::with_kb(
                format!(
                    "[OK] <b>{}</b>\n{}: <b>{}</b> (<code>{}</code>)\n{}: <code>{}</code>",
                    tr(ru, "Стратегия применена", "Strategy Applied"),
                    tr(ru, "Секция", "Section"),
                    escape_html(&sec_label),
                    escape_html(sec_id),
                    tr(ru, "Параметры", "Parameters"),
                    escape_html(&winner.args)
                ),
                inline_kb(vec![vec![
                    cb_btn(tr(ru, "К фаззеру", "Fuzzer"), "fuz_view"),
                    cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
                ]]),
            )
        }
        Err(e) => BotReply::with_kb(
            format!(
                "[ERR] {}: {}",
                tr(
                    ru,
                    "Ошибка сохранения конфигурации",
                    "Failed to save config"
                ),
                escape_html(&e.to_string())
            ),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "fuz_view")]]),
        ),
    }
}

// ---------------------------------------------------------------------------
// 3. Updates & Rule Lists
// ---------------------------------------------------------------------------

async fn render_updates_view(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    fetch_remote: bool,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let info = Box::pin(core.check_updates()).await;
    let tachyon_ver = info
        .get("orchestrator_version")
        .and_then(Value::as_str)
        .unwrap_or(crate::store::TACHYON_VERSION);
    let core_ver = info
        .get("core_installed")
        .and_then(Value::as_str)
        .unwrap_or("-");
    let lists_cnt = info
        .get("lists_installed_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let subs_cnt = info
        .get("subscriptions_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);

    let (remote_tachyon, remote_core) = if fetch_remote {
        let (r1, r2) = tokio::join!(
            Box::pin(updater::list_releases(core, "tachyon", 1, 1)),
            Box::pin(updater::list_releases(core, "tachyon-core", 1, 1))
        );
        let latest1 = r1
            .as_array()
            .and_then(|a| a.first())
            .and_then(|v| v.get("version"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let latest2 = r2
            .as_array()
            .and_then(|a| a.first())
            .and_then(|v| v.get("version"))
            .and_then(Value::as_str)
            .map(str::to_string);
        (latest1, latest2)
    } else {
        (None, None)
    };

    let list_status = updater::read_list_update_status();
    let list_msg = list_status
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("-");
    let active_jobs = updater::active_component_job_ids();

    let mut lines = vec![
        format!(
            "<b>{}</b>",
            tr(ru, "Обновления и списки правил", "Updates & Rule Lists")
        ),
        format!(
            "tachyon: <code>{}</code>{}",
            escape_html(tachyon_ver),
            remote_tachyon
                .as_deref()
                .map(|l| format!(
                    " -> latest <code>{}</code> ({})",
                    escape_html(l),
                    updater::classify_version_status(tachyon_ver, l)
                ))
                .unwrap_or_default()
        ),
        format!(
            "tachyon-core: <code>{}</code>{}",
            escape_html(core_ver),
            remote_core
                .as_deref()
                .map(|l| format!(
                    " -> latest <code>{}</code> ({})",
                    escape_html(l),
                    updater::classify_version_status(core_ver, l)
                ))
                .unwrap_or_default()
        ),
        format!(
            "{}: <code>{}</code> | {}: <code>{}</code>",
            tr(ru, "Наборы правил", "Rule lists"),
            lists_cnt,
            tr(ru, "Подписки", "Subscriptions"),
            subs_cnt
        ),
        format!(
            "{}: {}",
            tr(ru, "Статус списков", "Lists status"),
            escape_html(list_msg)
        ),
    ];

    if !active_jobs.is_empty() {
        lines.push(format!(
            "{}: <code>{}</code>",
            tr(ru, "Активные задачи", "Active jobs"),
            escape_html(&active_jobs.join(", "))
        ));
    }

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Проверить релизы", "Check Releases"), "upd_check"),
            cb_btn(tr(ru, "Обновить списки", "Update Lists"), "upd_lists"),
        ],
        vec![
            cb_btn("Update tachyon", "upd_install tachyon"),
            cb_btn("Update tachyon-core", "upd_install tachyon-core"),
        ],
        vec![
            cb_btn("Rollback tachyon", "upd_rollback tachyon"),
            cb_btn("Rollback tachyon-core", "upd_rollback tachyon-core"),
        ],
        vec![
            cb_btn(tr(ru, "Обновить экран", "Refresh"), "upd_view"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(lines.join("\n"), kb)
}

async fn run_update_install_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    comp: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let target = match comp.trim() {
        "tachyon" => "tachyon",
        "tachyon-core" | "sing_box" | "sing-box" => "tachyon-core",
        other => {
            return BotReply::with_kb(
                format!(
                    "[ERR] {}: <code>{}</code>",
                    tr(ru, "Неизвестный компонент", "Unknown component"),
                    escape_html(other)
                ),
                inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "upd_view")]]),
            );
        }
    };

    let res = Box::pin(updater::start_component_action(
        core,
        target,
        "install",
        Some("latest"),
    ))
    .await;
    let job_id = res.get("job_id").and_then(Value::as_str).unwrap_or("-");
    let msg = res
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Started");

    BotReply::with_kb(
        format!(
            "[OK] <b>{}</b> (<code>{}</code>)\nJob: <code>{}</code>\n{}",
            tr(ru, "Обновление запущено", "Update Started"),
            escape_html(target),
            escape_html(job_id),
            escape_html(msg)
        ),
        inline_kb(vec![
            vec![
                cb_btn(tr(ru, "Статус обновлений", "Updates Status"), "upd_view"),
                cb_btn(tr(ru, "Журнал", "Logs"), "logs_view"),
            ],
            vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
        ]),
    )
}

async fn run_update_rollback_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    comp: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let target = match comp.trim() {
        "tachyon" => "tachyon",
        "tachyon-core" | "sing_box" | "sing-box" => "tachyon-core",
        other => {
            return BotReply::with_kb(
                format!(
                    "[ERR] {}: <code>{}</code>",
                    tr(ru, "Неизвестный компонент", "Unknown component"),
                    escape_html(other)
                ),
                inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "upd_view")]]),
            );
        }
    };

    let res = Box::pin(core.component_action(target, "rollback", None)).await;
    let ok = res.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let msg = res
        .get("message")
        .or_else(|| res.get("error"))
        .or_else(|| res.pointer("/result/message"))
        .or_else(|| res.pointer("/result/error"))
        .and_then(Value::as_str)
        .unwrap_or("Done");

    BotReply::with_kb(
        format!(
            "{} <b>{}</b> (<code>{}</code>)\n{}",
            if ok { "[OK]" } else { "[ERR]" },
            tr(ru, "Откат компонента", "Component Rollback"),
            escape_html(target),
            escape_html(msg)
        ),
        inline_kb(vec![vec![
            cb_btn(tr(ru, "К обновлениям", "Updates"), "upd_view"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ]]),
    )
}

async fn run_lists_update_reply(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let res = Box::pin(updater::start_list_update_async(core)).await;
    let msg = res
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Started");
    let job_id = res.get("job_id").and_then(Value::as_str).unwrap_or("-");

    BotReply::with_kb(
        format!(
            "[OK] <b>{}</b>\nJob: <code>{}</code>\n{}",
            tr(
                ru,
                "Обновление списков запущено",
                "Rule Lists Update Started"
            ),
            escape_html(job_id),
            escape_html(msg)
        ),
        inline_kb(vec![vec![
            cb_btn(tr(ru, "Статус", "Refresh Status"), "upd_view"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ]]),
    )
}

// ---------------------------------------------------------------------------
// 4. Snapshots, Transfer Codes & LKG
// ---------------------------------------------------------------------------

fn safe_snapshot_file_path(state: &AppState, file_arg: &str) -> Option<(String, PathBuf)> {
    let trimmed = file_arg.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
    {
        return None;
    }
    let dir = snapshots::snapshots_dir(state);
    for cand in [
        trimmed.to_string(),
        format!("{trimmed}.tachyon-profile.json"),
        format!("{trimmed}.json"),
    ] {
        let p = dir.join(&cand);
        if p.is_file() {
            return Some((cand, p));
        }
    }
    None
}

async fn render_snapshots_list(state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let list = snapshots::snapshot_list(state);
    let arr = list
        .get("snapshots")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut lines = vec![format!(
        "<b>{} ({})</b>",
        tr(ru, "Снапшоты конфигурации", "Configuration Snapshots"),
        arr.len()
    )];
    let mut rows: Vec<Vec<Value>> = Vec::new();

    if arr.is_empty() {
        lines.push(
            tr(
                ru,
                "Сохранённых снапшотов пока нет.",
                "No saved snapshots yet.",
            )
            .to_string(),
        );
    } else {
        for item in arr.iter().take(6) {
            let file = item.get("file").and_then(Value::as_str).unwrap_or("");
            let name = item.get("name").and_then(Value::as_str).unwrap_or(file);
            let stamp = item.get("stamp").and_then(Value::as_str).unwrap_or("-");
            let size = item.get("size").and_then(Value::as_u64).unwrap_or(0);
            let secs = item
                .pointer("/counts/sections")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            lines.push(format!(
                "- <b>{}</b> (<code>{}</code>, {}, {} sec)",
                escape_html(name),
                escape_html(stamp),
                format_bytes_human(size),
                secs
            ));
            rows.push(vec![
                cb_btn(&format!("{name} ({stamp})"), &format!("snap_view {file}")),
                cb_btn(tr(ru, "Файл", "File"), &format!("snap_doc {file}")),
            ]);
        }
    }

    rows.push(vec![
        cb_btn(tr(ru, "Быстрый бэкап", "Quick Backup"), "snap_save"),
        cb_btn(tr(ru, "Бэкап с именем", "Named Backup"), "snap_save_ask"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Код переноса", "Transfer Code"), "snap_code"),
        cb_btn(tr(ru, "Импорт кода", "Import Code"), "snap_import_ask"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Эталон LKG", "LKG Status"), "lkg_view"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn save_snapshot_reply(state: &Arc<AppState>, raw_name: &str, send_doc: bool) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let name = if raw_name.trim().is_empty() {
        "telegram"
    } else {
        raw_name.trim()
    };
    let secs = ubus_bridge::get_json_sections_snapshot();
    let saved = Box::pin(snapshots::snapshot_save(state, &secs, name)).await;
    if saved.get("success").and_then(Value::as_bool) != Some(true) {
        let err = saved
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("Failed to save snapshot");
        return BotReply::with_kb(
            format!("[ERR] {}", escape_html(err)),
            inline_kb(vec![vec![cb_btn(
                tr(ru, "Снапшоты", "Snapshots"),
                "snap_list",
            )]]),
        );
    }

    let file = saved
        .get("file")
        .and_then(Value::as_str)
        .unwrap_or("snapshot.tachyon-profile.json");
    let size = saved.get("size").and_then(Value::as_u64).unwrap_or(0);
    let snap_name = saved.get("name").and_then(Value::as_str).unwrap_or(name);

    let text = format!(
        "[OK] <b>{}</b>\n{}: <b>{}</b>\n{}: <code>{}</code> (<code>{}</code>)",
        tr(ru, "Снапшот сохранён", "Snapshot Saved"),
        tr(ru, "Имя", "Name"),
        escape_html(snap_name),
        tr(ru, "Файл", "File"),
        escape_html(file),
        format_bytes_human(size)
    );
    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Код переноса", "Transfer Code"), "snap_code"),
            cb_btn(tr(ru, "Все снапшоты", "All Snapshots"), "snap_list"),
        ],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);

    if send_doc
        && let Some((fname, path)) = safe_snapshot_file_path(state, file)
        && let Ok(bytes) = std::fs::read(&path)
    {
        return BotReply::with_doc(
            text,
            Some(kb),
            fname,
            bytes,
            format!("{}: {}", tr(ru, "Снапшот", "Snapshot"), snap_name),
        );
    }
    BotReply::with_kb(text, kb)
}

async fn render_snapshot_view(state: &Arc<AppState>, file_arg: &str) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let clean = file_arg.trim();
    if clean.is_empty() {
        return render_snapshots_list(state).await;
    }
    let secs = ubus_bridge::get_json_sections_snapshot();
    let diff = Box::pin(snapshots::snapshot_diff(state, &secs, clean)).await;
    if diff.get("success").and_then(Value::as_bool) != Some(true) {
        let msg = diff
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("Snapshot not found");
        return BotReply::with_kb(
            format!("[ERR] {}", escape_html(msg)),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "snap_list")]]),
        );
    }
    let name = diff.get("name").and_then(Value::as_str).unwrap_or(clean);
    let added = diff.get("added_count").and_then(Value::as_u64).unwrap_or(0);
    let removed = diff
        .get("removed_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let diff_txt = diff.get("diff").and_then(Value::as_str).unwrap_or("");
    let diff_preview = if diff_txt.is_empty() {
        tr(ru, "Изменений нет.", "No differences from active config.").to_string()
    } else {
        format!(
            "<pre>{}</pre>",
            escape_html(&truncate_for_tg(diff_txt, 1800))
        )
    };

    let text = format!(
        "<b>{}: {}</b>\n<code>{}</code>\n+{added} / -{removed}\n{}",
        tr(ru, "Снапшот", "Snapshot"),
        escape_html(name),
        escape_html(clean),
        diff_preview
    );
    let kb = inline_kb(vec![
        vec![
            cb_btn(
                tr(ru, "Восстановить", "Restore"),
                &format!("snap_restore {clean}"),
            ),
            cb_btn(
                tr(ru, "Скачать .json", "Download"),
                &format!("snap_doc {clean}"),
            ),
        ],
        vec![
            cb_btn(tr(ru, "Удалить", "Delete"), &format!("snap_del {clean}")),
            cb_btn(tr(ru, "К списку", "Back"), "snap_list"),
        ],
    ]);
    BotReply::with_kb(text, kb)
}

async fn restore_snapshot_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    file_arg: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    match Box::pin(snapshots::snapshot_restore(state, file_arg.trim())).await {
        Ok((prof, restored_secs)) => {
            if !restored_secs.is_empty() {
                ubus_bridge::set_json_sections_snapshot(restored_secs);
            }
            let tg = state.data.read().await.telegram.clone();
            ubus_bridge::sync_telegram_section_to_json(&tg);
            notify_bot_wakeup();
            reload_core_boxed(core).await;
            BotReply::with_kb(
                format!(
                    "[OK] <b>{}</b>\n{}: <b>{}</b> (<code>{}</code>)",
                    tr(ru, "Снапшот восстановлен", "Snapshot Restored"),
                    tr(ru, "Профиль", "Profile"),
                    escape_html(&prof.name),
                    escape_html(&prof.stamp)
                ),
                inline_kb(vec![vec![
                    cb_btn(tr(ru, "Снапшоты", "Snapshots"), "snap_list"),
                    cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
                ]]),
            )
        }
        Err(e) => BotReply::with_kb(
            format!("[ERR] {}", escape_html(&e.to_string())),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "snap_list")]]),
        ),
    }
}

async fn delete_snapshot_reply(state: &Arc<AppState>, file_arg: &str) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let res = snapshots::snapshot_delete(state, file_arg.trim());
    let ok = res.get("success").and_then(Value::as_bool).unwrap_or(false);
    let msg = if ok {
        format!(
            "[OK] {}: <code>{}</code>",
            tr(ru, "Снапшот удалён", "Snapshot deleted"),
            escape_html(file_arg.trim())
        )
    } else {
        format!(
            "[ERR] {}",
            escape_html(
                res.get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Error")
            )
        )
    };
    BotReply::with_kb(
        msg,
        inline_kb(vec![vec![
            cb_btn(tr(ru, "К списку", "Back"), "snap_list"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ]]),
    )
}

async fn download_snapshot_doc(state: &Arc<AppState>, file_arg: &str) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let Some((fname, path)) = safe_snapshot_file_path(state, file_arg) else {
        return BotReply::with_kb(
            format!(
                "[ERR] {}",
                tr(ru, "Файл снапшота не найден.", "Snapshot file not found.")
            ),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "snap_list")]]),
        );
    };
    match std::fs::read(&path) {
        Ok(bytes) => {
            let sz = format_bytes_human(bytes.len() as u64);
            let kb = inline_kb(vec![vec![
                cb_btn(tr(ru, "К списку", "Snapshots"), "snap_list"),
                cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
            ]]);
            BotReply::with_doc(
                format!(
                    "[OK] <code>{}</code> (<code>{}</code>)",
                    escape_html(&fname),
                    escape_html(&sz)
                ),
                Some(kb),
                fname.clone(),
                bytes,
                fname,
            )
        }
        Err(e) => BotReply::with_kb(
            format!("[ERR] {}", escape_html(&e.to_string())),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "snap_list")]]),
        ),
    }
}

async fn export_transfer_code_reply(state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let secs = ubus_bridge::get_json_sections_snapshot();
    let prof = Box::pin(snapshots::build_active_profile(
        state, &secs, "transfer", "routes",
    ))
    .await;
    match snapshots::encode_transfer_code(&prof) {
        Ok(code) => {
            let kb = inline_kb(vec![
                vec![
                    cb_btn(tr(ru, "Импорт кода", "Import Code"), "snap_import_ask"),
                    cb_btn(tr(ru, "Снапшоты", "Snapshots"), "snap_list"),
                ],
                vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
            ]);
            if code.len() <= 3200 {
                BotReply::with_kb(
                    format!(
                        "<b>{}</b> ({} sections)\n<code>{}</code>",
                        tr(ru, "Код переноса маршрутов", "Routes Transfer Code"),
                        prof.counts.sections,
                        escape_html(&code)
                    ),
                    kb,
                )
            } else {
                BotReply::with_doc(
                    format!(
                        "[OK] <b>{}</b> ({} bytes)",
                        tr(
                            ru,
                            "Код переноса сформирован в файле",
                            "Transfer Code Generated as File"
                        ),
                        code.len()
                    ),
                    Some(kb),
                    "tachyon-transfer-code.txt",
                    code.into_bytes(),
                    tr(ru, "Код переноса маршрутов", "Routes transfer code"),
                )
            }
        }
        Err(e) => BotReply::with_kb(
            format!("[ERR] {}", escape_html(&e.to_string())),
            inline_kb(vec![vec![cb_btn(tr(ru, "Назад", "Back"), "snap_list")]]),
        ),
    }
}

async fn import_snapshot_payload_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    raw: &str,
) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return BotReply::with_kb(
            format!(
                "[!] {}",
                tr(
                    ru,
                    "Отправьте код tachyon://rs2/... или JSON профиля.",
                    "Send a tachyon://rs2/... transfer code or profile JSON."
                )
            ),
            inline_kb(vec![vec![cb_btn(
                tr(ru, "Снапшоты", "Snapshots"),
                "snap_list",
            )]]),
        );
    }

    let secs = ubus_bridge::get_json_sections_snapshot();
    let is_code = trimmed
        .get(..10)
        .is_some_and(|p| p.eq_ignore_ascii_case("tachyon://"))
        || trimmed
            .get(..8)
            .is_some_and(|p| p.eq_ignore_ascii_case("TACHYON-"));
    let arg_str = if is_code {
        format!("code-apply:replace:{trimmed}")
    } else {
        trimmed.to_string()
    };

    match Box::pin(snapshots::snapshot_import(state, &secs, Some(&arg_str))).await {
        snapshots::ImportOutcome::AppliedState {
            response,
            new_sections,
        } => {
            if !new_sections.is_empty() {
                ubus_bridge::set_json_sections_snapshot(new_sections);
            }
            let tg = state.data.read().await.telegram.clone();
            ubus_bridge::sync_telegram_section_to_json(&tg);
            notify_bot_wakeup();
            reload_core_boxed(core).await;
            let scope = response
                .get("scope")
                .and_then(Value::as_str)
                .unwrap_or("routes");
            let sec_cnt = response
                .pointer("/counts/sections")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            BotReply::with_kb(
                format!(
                    "[OK] <b>{}</b>\nScope: <code>{}</code> | Sections: <code>{}</code>",
                    tr(ru, "Профиль переноса применён", "Transfer Profile Applied"),
                    escape_html(scope),
                    sec_cnt
                ),
                inline_kb(vec![vec![
                    cb_btn(tr(ru, "Снапшоты", "Snapshots"), "snap_list"),
                    cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
                ]]),
            )
        }
        snapshots::ImportOutcome::ResponseOnly(resp) => {
            let ok = resp
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if ok {
                let file = resp.get("file").and_then(Value::as_str).unwrap_or("");
                let name = resp.get("name").and_then(Value::as_str).unwrap_or(file);
                BotReply::with_kb(
                    format!(
                        "[OK] <b>{}</b>: <b>{}</b> (<code>{}</code>)",
                        tr(
                            ru,
                            "Профиль импортирован в снапшоты",
                            "Profile Imported to Snapshots"
                        ),
                        escape_html(name),
                        escape_html(file)
                    ),
                    inline_kb(vec![
                        vec![
                            cb_btn(
                                tr(ru, "Восстановить сейчас", "Restore Now"),
                                &format!("snap_restore {file}"),
                            ),
                            cb_btn(tr(ru, "Снапшоты", "Snapshots"), "snap_list"),
                        ],
                        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
                    ]),
                )
            } else {
                let msg = resp
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Import failed");
                BotReply::with_kb(
                    format!("[ERR] {}", escape_html(msg)),
                    inline_kb(vec![
                        vec![cb_btn(tr(ru, "Повторить", "Retry"), "snap_import_ask")],
                        vec![cb_btn(tr(ru, "Снапшоты", "Snapshots"), "snap_list")],
                    ]),
                )
            }
        }
    }
}

async fn render_lkg_view(state: &Arc<AppState>) -> BotReply {
    let (ru, observing, rem_secs, lkg_exists, lkg_info) = {
        let d = state.data.read().await;
        let live = state.live.read().await;
        let exists = state.lkg_path.exists();
        let loaded = if exists {
            transaction::load_known_good(&state.lkg_path).ok()
        } else {
            None
        };
        (
            is_ru(&d),
            live.lkg_observing,
            live.lkg_remaining_secs,
            exists,
            loaded.map(|l| (l.sections.len(), l.outbound_sources.len(), l.servers.len())),
        )
    };

    let lkg_summary = match lkg_info {
        Some((secs, srcs, srvs)) => format!(
            "[OK] {} (sections: {secs}, sources: {srcs}, servers: {srvs})",
            tr(ru, "Эталон сохранён", "Snapshot present")
        ),
        None if lkg_exists => format!(
            "[!] {}",
            tr(ru, "Файл LKG повреждён", "LKG file unreadable")
        ),
        None => format!(
            "[!] {}",
            tr(ru, "Эталон LKG ещё не создан", "No LKG snapshot yet")
        ),
    };

    let text = format!(
        "<b>{}</b>\n\
         {}: {}\n\
         {}: {}",
        tr(ru, "Last Known Good (LKG)", "Last Known Good (LKG)"),
        tr(ru, "Состояние", "Status"),
        lkg_summary,
        tr(ru, "Окно наблюдения", "Observation window"),
        if observing {
            format!("{rem_secs}s")
        } else {
            "idle".to_string()
        }
    );

    let kb = inline_kb(vec![
        vec![
            cb_btn(
                tr(ru, "Сохранить как эталон", "Promote Current"),
                "lkg_promote",
            ),
            cb_btn(
                tr(ru, "Откатить к LKG", "Rollback to LKG"),
                "fix_apply rollback_known_good",
            ),
        ],
        vec![
            cb_btn(tr(ru, "Снапшоты", "Snapshots"), "snap_list"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(text, kb)
}

async fn promote_lkg_reply(state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let text = match transaction::promote_to_known_good(&state.lkg_path, &d) {
        Ok(true) => format!(
            "[OK] {}",
            tr(
                ru,
                "Текущая конфигурация закреплена как Last Known Good.",
                "Current configuration promoted to Last Known Good."
            )
        ),
        Ok(false) => format!(
            "[OK] {}",
            tr(
                ru,
                "Эталон Last Known Good уже актуален.",
                "Last Known Good is already up to date."
            )
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    let kb = inline_kb(vec![vec![
        cb_btn(tr(ru, "Эталон LKG", "LKG View"), "lkg_view"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]]);
    BotReply::with_kb(text, kb)
}

// ---------------------------------------------------------------------------
// 5. Bot Self-Settings
// ---------------------------------------------------------------------------

fn describe_bot_proxy(d: &RouterStoreData, core_running: bool, ru: bool) -> String {
    let sec_ref = d.telegram.bot_proxy_section.trim();
    let resolved = resolve_tg_proxy_url(d, core_running);
    if sec_ref.eq_ignore_ascii_case("direct") {
        tr(ru, "Direct (без прокси)", "Direct (no proxy)").to_string()
    } else if sec_ref.is_empty() {
        match resolved {
            Some(url) => format!("Auto ({url})"),
            None => tr(ru, "Auto (ядро остановлено)", "Auto (core stopped)").to_string(),
        }
    } else {
        match resolved {
            Some(url) => format!("{sec_ref} ({url})"),
            None => sec_ref.to_string(),
        }
    }
}

async fn render_bot_settings(state: &Arc<AppState>) -> BotReply {
    let (d, core_running) = {
        let data = state.data.read().await.clone();
        let live = state.live.read().await;
        (data, live.core_running)
    };
    let ru = is_ru(&d);
    let tg = &d.telegram;
    let in_quiet = is_quiet_hours_now(tg);
    let admins_str = if tg.admin_ids.is_empty() {
        "-".to_string()
    } else {
        tg.admin_ids
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    };

    let text = format!(
        "<b>{}</b>\n\
         {}: <b>{}</b>\n\
         {}: <code>{}</code>\n\
         {}: <code>{}</code>\n\
         {}: {} (<code>{} - {}</code>{})\n\
         {}: <code>{}</code> | {}: <code>{}s</code>\n\
         Admin IDs ({}): <code>{}</code>",
        tr(ru, "Настройки Telegram-бота", "Telegram Bot Settings"),
        tr(ru, "Имя роутера", "Router Name"),
        escape_html(&tg.router_name),
        tr(ru, "Язык", "Language"),
        if ru { "ru" } else { "en" },
        tr(ru, "Прокси бота", "Bot Proxy"),
        escape_html(&describe_bot_proxy(&d, core_running, ru)),
        tr(ru, "Тихие часы", "Quiet Hours"),
        if tg.quiet_hours_enabled {
            "[ON]"
        } else {
            "[OFF]"
        },
        escape_html(&tg.quiet_hours_start),
        escape_html(&tg.quiet_hours_end),
        if in_quiet { " · active" } else { "" },
        tr(ru, "Токен", "Token"),
        if tg.bot_token.trim().is_empty() {
            "missing"
        } else {
            "configured"
        },
        tr(ru, "Интервал", "Poll"),
        tg.poll_interval,
        tg.admin_ids.len(),
        escape_html(&admins_str)
    );

    let kb = inline_kb(vec![
        vec![
            cb_btn("Language: RU", "bot_lang ru"),
            cb_btn("Language: EN", "bot_lang en"),
        ],
        vec![
            cb_btn(tr(ru, "Имя роутера", "Router Name"), "bot_name_ask"),
            cb_btn(tr(ru, "Прокси бота", "Bot Proxy"), "bot_proxy_menu"),
        ],
        vec![
            cb_btn(
                if tg.quiet_hours_enabled {
                    tr(ru, "Тихие часы: ON", "Quiet Hours: ON")
                } else {
                    tr(ru, "Тихие часы: OFF", "Quiet Hours: OFF")
                },
                "bot_quiet_tog",
            ),
            cb_btn(tr(ru, "Задать интервал", "Quiet Window"), "bot_quiet_ask"),
        ],
        vec![
            cb_btn(tr(ru, "Уведомления", "Notifications"), "bot_notify_menu"),
            cb_btn(tr(ru, "Переключатели", "Quick Toggles"), "bot_toggles_menu"),
        ],
        vec![cb_btn(
            tr(ru, "Добавить Admin ID", "Add Admin ID"),
            "bot_admin_ask",
        )],
        vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
    ]);
    BotReply::with_kb(text, kb)
}

async fn set_bot_language_reply(state: &Arc<AppState>, arg: &str) -> BotReply {
    let lang = arg.trim().to_ascii_lowercase();
    if lang.is_empty() {
        let ru = {
            let d = state.data.read().await;
            is_ru(&d)
        };
        return BotReply::with_kb(
            format!(
                "<b>{}</b>: <code>{}</code>",
                tr(ru, "Текущий язык бота", "Current bot language"),
                if ru { "ru" } else { "en" }
            ),
            inline_kb(vec![
                vec![
                    cb_btn("Русский (ru)", "bot_lang ru"),
                    cb_btn("English (en)", "bot_lang en"),
                ],
                vec![cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg")],
            ]),
        );
    }
    if lang != "ru" && lang != "en" {
        return BotReply::with_kb(
            format!(
                "[ERR] Unsupported language <code>{}</code>. Use <code>ru</code> or <code>en</code>.",
                escape_html(&lang)
            ),
            inline_kb(vec![vec![
                cb_btn("Русский (ru)", "bot_lang ru"),
                cb_btn("English (en)", "bot_lang en"),
            ]]),
        );
    }

    match update_telegram_cfg(state, |tg| {
        tg.language = lang.clone();
        Ok(())
    })
    .await
    {
        Ok(_) => {
            let ru = lang == "ru";
            BotReply::with_kb(
                format!(
                    "[OK] {}",
                    tr(
                        ru,
                        "Язык бота переключён на русский (ru).",
                        "Bot language switched to English (en)."
                    )
                ),
                inline_kb(vec![vec![
                    cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
                    cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
                ]]),
            )
        }
        Err(e) => BotReply::text(format!("[ERR] {}", escape_html(&e.to_string()))),
    }
}

async fn set_router_name_reply(state: &Arc<AppState>, raw_name: &str) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let clean: String = raw_name
        .trim()
        .chars()
        .filter(|&c| !matches!(c, '<' | '>' | '\r' | '\n'))
        .take(48)
        .collect();
    let clean = clean.trim().to_string();
    if clean.is_empty() {
        return BotReply::with_kb(
            format!(
                "[ERR] {}",
                tr(
                    ru,
                    "Имя роутера не должно быть пустым (1..48 символов).",
                    "Router name must not be empty (1..48 chars)."
                )
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Повторить", "Retry"), "bot_name_ask"),
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
            ]]),
        );
    }

    match update_telegram_cfg(state, |tg| {
        tg.router_name = clean.clone();
        Ok(())
    })
    .await
    {
        Ok(_) => BotReply::with_kb(
            format!(
                "[OK] {}: <b>{}</b>",
                tr(ru, "Имя роутера обновлено", "Router name updated"),
                escape_html(&clean)
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
                cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
            ]]),
        ),
        Err(e) => BotReply::text(format!("[ERR] {}", escape_html(&e.to_string()))),
    }
}

fn parse_quiet_window(raw: &str) -> Option<(String, String)> {
    let norm = raw.trim().replace(',', " ");
    let mut tokens: Vec<&str> = if let Some((a, b)) = norm.split_once('-') {
        vec![a.trim(), b.trim()]
    } else {
        norm.split_whitespace().collect()
    };
    if tokens.len() != 2 {
        return None;
    }
    let start = parse_hhmm(tokens.remove(0))?;
    let end = parse_hhmm(tokens.remove(0))?;
    Some((
        format!("{:02}:{:02}", start / 60, start % 60),
        format!("{:02}:{:02}", end / 60, end % 60),
    ))
}

async fn render_quiet_hours_view(state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let tg = &d.telegram;
    let text = format!(
        "<b>{}</b>\n{}: {} (<code>{} - {}</code>)",
        tr(ru, "Тихие часы уведомлений", "Quiet Hours"),
        tr(ru, "Статус", "Status"),
        if tg.quiet_hours_enabled {
            "[ON]"
        } else {
            "[OFF]"
        },
        escape_html(&tg.quiet_hours_start),
        escape_html(&tg.quiet_hours_end)
    );
    let kb = inline_kb(vec![
        vec![
            cb_btn(
                if tg.quiet_hours_enabled {
                    tr(ru, "Выключить", "Disable")
                } else {
                    tr(ru, "Включить", "Enable")
                },
                "bot_quiet_tog",
            ),
            cb_btn(tr(ru, "Изменить время", "Set Window"), "bot_quiet_ask"),
        ],
        vec![
            cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(text, kb)
}

async fn toggle_quiet_hours_reply(state: &Arc<AppState>) -> BotReply {
    let res = update_telegram_cfg(state, |tg| {
        tg.quiet_hours_enabled = !tg.quiet_hours_enabled;
        Ok(())
    })
    .await;
    if let Err(e) = res {
        return BotReply::text(format!("[ERR] {}", escape_html(&e.to_string())));
    }
    render_quiet_hours_view(state).await
}

async fn set_quiet_hours_window_reply(state: &Arc<AppState>, raw: &str) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let trimmed = raw.trim();
    if trimmed.eq_ignore_ascii_case("on") || trimmed.eq_ignore_ascii_case("off") {
        let target = trimmed.eq_ignore_ascii_case("on");
        let _ = update_telegram_cfg(state, |tg| {
            tg.quiet_hours_enabled = target;
            Ok(())
        })
        .await;
        return render_quiet_hours_view(state).await;
    }

    let Some((start, end)) = parse_quiet_window(trimmed) else {
        return BotReply::with_kb(
            format!(
                "[ERR] {}",
                tr(
                    ru,
                    "Неверный формат. Укажите диапазон в виде <code>23:00-07:00</code>.",
                    "Invalid format. Enter a range like <code>23:00-07:00</code>."
                )
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Повторить", "Retry"), "bot_quiet_ask"),
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
            ]]),
        );
    };

    match update_telegram_cfg(state, |tg| {
        tg.quiet_hours_enabled = true;
        tg.quiet_hours_start = start.clone();
        tg.quiet_hours_end = end.clone();
        Ok(())
    })
    .await
    {
        Ok(_) => BotReply::with_kb(
            format!(
                "[OK] {}: <code>{} - {}</code> ([ON])",
                tr(ru, "Тихие часы заданы", "Quiet hours saved"),
                escape_html(&start),
                escape_html(&end)
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
                cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
            ]]),
        ),
        Err(e) => BotReply::text(format!("[ERR] {}", escape_html(&e.to_string()))),
    }
}

async fn render_notify_menu(state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let tg = &d.telegram;

    let items: [(&str, &str, &str, bool); 14] = [
        (
            "smart_detect",
            "Smart Detect",
            "Smart Detect",
            tg.notify_smart_detect,
        ),
        ("crash", "Сбои ядра", "Core Crash", tg.notify_crash),
        ("restart", "Перезапуски", "Restarts", tg.notify_restart),
        (
            "server_switch",
            "Смена сервера",
            "Server Switch",
            tg.notify_server_switch,
        ),
        ("failover", "Failover", "Failover", tg.notify_failover),
        ("wan", "Статус WAN", "WAN Status", tg.notify_wan),
        ("dns_leak", "DNS / Утечки", "DNS Leak", tg.notify_dns_leak),
        (
            "subscription",
            "Подписки",
            "Subscriptions",
            tg.notify_subscription,
        ),
        (
            "update_available",
            "Новые версии",
            "Updates Available",
            tg.notify_update_available,
        ),
        (
            "auto_update",
            "Автообновление",
            "Auto Update",
            tg.notify_auto_update,
        ),
        ("parental", "Семейный режим", "Parental", tg.notify_parental),
        ("cert", "Сертификаты", "Certificates", tg.notify_cert),
        (
            "route_alert",
            "Проблемы маршрута",
            "Route Alerts",
            tg.notify_route_alert,
        ),
        ("honeypot", "Honeypot", "Honeypot", tg.notify_honeypot),
    ];

    let mut lines = vec![format!(
        "<b>{}</b>",
        tr(ru, "Уведомления Telegram-бота", "Bot Notification Filters")
    )];
    let mut btns: Vec<Value> = Vec::new();
    for (key, lbl_ru, lbl_en, val) in items {
        let lbl = tr(ru, lbl_ru, lbl_en);
        let st = if val { "[ON]" } else { "[OFF]" };
        lines.push(format!("{st} {lbl}"));
        btns.push(cb_btn(
            &format!("{st} {lbl}"),
            &format!("bot_notify_tog {key}"),
        ));
    }

    let mut rows: Vec<Vec<Value>> = btns.chunks(2).map(<[Value]>::to_vec).collect();
    rows.push(vec![
        cb_btn(tr(ru, "Включить все", "Enable All"), "bot_notify_all 1"),
        cb_btn(tr(ru, "Выключить все", "Disable All"), "bot_notify_all 0"),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "Переключатели", "Quick Toggles"), "bot_toggles_menu"),
        cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
    ]);
    rows.push(vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")]);
    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn toggle_notify_field_reply(state: &Arc<AppState>, field: &str) -> BotReply {
    let key = field.trim().to_ascii_lowercase();
    let res = update_telegram_cfg(state, |tg| {
        match key.as_str() {
            "smart_detect" | "notify_smart_detect" => {
                tg.notify_smart_detect = !tg.notify_smart_detect
            }
            "crash" | "notify_crash" => tg.notify_crash = !tg.notify_crash,
            "restart" | "notify_restart" => tg.notify_restart = !tg.notify_restart,
            "server_switch" | "notify_server_switch" => {
                tg.notify_server_switch = !tg.notify_server_switch
            }
            "failover" | "notify_failover" => tg.notify_failover = !tg.notify_failover,
            "wan" | "notify_wan" => tg.notify_wan = !tg.notify_wan,
            "subscription" | "notify_subscription" => {
                tg.notify_subscription = !tg.notify_subscription
            }
            "dns_leak" | "notify_dns_leak" => tg.notify_dns_leak = !tg.notify_dns_leak,
            "cert" | "notify_cert" => tg.notify_cert = !tg.notify_cert,
            "update_available" | "notify_update_available" => {
                tg.notify_update_available = !tg.notify_update_available
            }
            "auto_update" | "notify_auto_update" => tg.notify_auto_update = !tg.notify_auto_update,
            "honeypot" | "notify_honeypot" => tg.notify_honeypot = !tg.notify_honeypot,
            "parental" | "notify_parental" => tg.notify_parental = !tg.notify_parental,
            "route_alert" | "notify_route_alert" => tg.notify_route_alert = !tg.notify_route_alert,
            _ => anyhow::bail!("Unknown notification flag: {key}"),
        }
        Ok(())
    })
    .await;
    if let Err(e) = res {
        return BotReply::with_kb(
            format!("[ERR] {}", escape_html(&e.to_string())),
            inline_kb(vec![vec![cb_btn("Notifications", "bot_notify_menu")]]),
        );
    }
    render_notify_menu(state).await
}

async fn set_all_notify_reply(state: &Arc<AppState>, arg: &str) -> BotReply {
    let target = arg.trim() != "0";
    let _ = update_telegram_cfg(state, |tg| {
        tg.notify_smart_detect = target;
        tg.notify_crash = target;
        tg.notify_restart = target;
        tg.notify_server_switch = target;
        tg.notify_failover = target;
        tg.notify_wan = target;
        tg.notify_subscription = target;
        tg.notify_dns_leak = target;
        tg.notify_cert = target;
        tg.notify_update_available = target;
        tg.notify_auto_update = target;
        tg.notify_honeypot = target;
        tg.notify_parental = target;
        tg.notify_route_alert = target;
        Ok(())
    })
    .await;
    render_notify_menu(state).await
}

#[derive(Clone, Copy)]
enum ToggleApplyKind {
    None,
    Firewall,
    Reload,
}

#[derive(Clone, Copy)]
struct QuickToggleSpec {
    key: &'static str,
    group: &'static str,
    ru: &'static str,
    en: &'static str,
    apply: ToggleApplyKind,
}

const QUICK_TOGGLE_SPECS: &[QuickToggleSpec] = &[
    QuickToggleSpec {
        key: "tcp_bbr",
        group: "core",
        ru: "TCP BBR",
        en: "TCP BBR",
        apply: ToggleApplyKind::Firewall,
    },
    QuickToggleSpec {
        key: "enable_watchdog",
        group: "core",
        ru: "Watchdog",
        en: "Watchdog",
        apply: ToggleApplyKind::None,
    },
    QuickToggleSpec {
        key: "emergency_direct_bypass",
        group: "core",
        ru: "Аварийный прямой обход",
        en: "Emergency Direct Bypass",
        apply: ToggleApplyKind::Firewall,
    },
    QuickToggleSpec {
        key: "list_update_enabled",
        group: "core",
        ru: "Автообновление списков",
        en: "Rule Lists Auto-Update",
        apply: ToggleApplyKind::None,
    },
    QuickToggleSpec {
        key: "component_update_check_enabled",
        group: "core",
        ru: "Проверка обновлений",
        en: "Check Updates",
        apply: ToggleApplyKind::None,
    },
    QuickToggleSpec {
        key: "component_auto_update_enabled",
        group: "core",
        ru: "Автообновление компонентов",
        en: "Auto-Update Components",
        apply: ToggleApplyKind::None,
    },
    QuickToggleSpec {
        key: "fakeip_enabled",
        group: "net",
        ru: "FakeIP",
        en: "FakeIP",
        apply: ToggleApplyKind::Reload,
    },
    QuickToggleSpec {
        key: "ipv6_leak_guard",
        group: "net",
        ru: "Защита утечек IPv6",
        en: "IPv6 Leak Guard",
        apply: ToggleApplyKind::Reload,
    },
    QuickToggleSpec {
        key: "dns_intercept_all",
        group: "net",
        ru: "Перехват всего DNS",
        en: "Intercept All LAN DNS",
        apply: ToggleApplyKind::Firewall,
    },
    QuickToggleSpec {
        key: "block_doh",
        group: "net",
        ru: "Блок стороннего DoH",
        en: "Block 3rd-Party DoH",
        apply: ToggleApplyKind::Reload,
    },
    QuickToggleSpec {
        key: "disable_quic",
        group: "net",
        ru: "Блок QUIC (UDP 443)",
        en: "Block QUIC (UDP 443)",
        apply: ToggleApplyKind::Reload,
    },
    QuickToggleSpec {
        key: "webrtc_leak_protect",
        group: "net",
        ru: "Защита WebRTC",
        en: "WebRTC Protection",
        apply: ToggleApplyKind::Firewall,
    },
    QuickToggleSpec {
        key: "isolate_p2p",
        group: "net",
        ru: "Изоляция P2P/Torrent",
        en: "Isolate P2P/Torrent",
        apply: ToggleApplyKind::Reload,
    },
    QuickToggleSpec {
        key: "route_router_traffic",
        group: "net",
        ru: "Трафик самого роутера",
        en: "Route Router Traffic",
        apply: ToggleApplyKind::Firewall,
    },
    QuickToggleSpec {
        key: "smart_queue",
        group: "net",
        ru: "SQM / Антибуферизация",
        en: "Smart Queue (SQM)",
        apply: ToggleApplyKind::Firewall,
    },
    QuickToggleSpec {
        key: "direct_bypass_enabled",
        group: "net",
        ru: "Порт прямого обхода",
        en: "Direct Bypass Port",
        apply: ToggleApplyKind::Reload,
    },
];

fn read_quick_toggle_val(s: &crate::store::GlobalSettings, key: &str) -> bool {
    match key {
        "tcp_bbr" => s.tcp_bbr,
        "enable_watchdog" => s.enable_watchdog,
        "emergency_direct_bypass" => s.emergency_direct_bypass,
        "list_update_enabled" => s.list_update_enabled,
        "component_update_check_enabled" => s.component_update_check_enabled,
        "component_auto_update_enabled" => s.component_auto_update_enabled,
        "fakeip_enabled" => s.fakeip_enabled,
        "ipv6_leak_guard" => s.ipv6_leak_guard,
        "dns_intercept_all" => s.dns_intercept_all,
        "block_doh" => s.block_doh,
        "disable_quic" => s.disable_quic,
        "webrtc_leak_protect" => s.webrtc_leak_protect,
        "isolate_p2p" => s.isolate_p2p,
        "route_router_traffic" => s.route_router_traffic,
        "smart_queue" => s.smart_queue,
        "direct_bypass_enabled" => s.direct_bypass_enabled,
        _ => false,
    }
}

fn flip_quick_toggle_val(s: &mut crate::store::GlobalSettings, key: &str) -> bool {
    match key {
        "tcp_bbr" => {
            s.tcp_bbr = !s.tcp_bbr;
            true
        }
        "enable_watchdog" => {
            s.enable_watchdog = !s.enable_watchdog;
            true
        }
        "emergency_direct_bypass" => {
            s.emergency_direct_bypass = !s.emergency_direct_bypass;
            true
        }
        "list_update_enabled" => {
            s.list_update_enabled = !s.list_update_enabled;
            true
        }
        "component_update_check_enabled" => {
            s.component_update_check_enabled = !s.component_update_check_enabled;
            true
        }
        "component_auto_update_enabled" => {
            s.component_auto_update_enabled = !s.component_auto_update_enabled;
            true
        }
        "fakeip_enabled" => {
            s.fakeip_enabled = !s.fakeip_enabled;
            true
        }
        "ipv6_leak_guard" => {
            s.ipv6_leak_guard = !s.ipv6_leak_guard;
            true
        }
        "dns_intercept_all" => {
            s.dns_intercept_all = !s.dns_intercept_all;
            s.dns_intercept_all_mode = if s.dns_intercept_all { "1" } else { "0" }.to_string();
            true
        }
        "block_doh" => {
            s.block_doh = !s.block_doh;
            true
        }
        "disable_quic" => {
            s.disable_quic = !s.disable_quic;
            true
        }
        "webrtc_leak_protect" => {
            s.webrtc_leak_protect = !s.webrtc_leak_protect;
            s.webrtc_leak_protect_mode = if s.webrtc_leak_protect { "1" } else { "0" }.to_string();
            true
        }
        "isolate_p2p" => {
            s.isolate_p2p = !s.isolate_p2p;
            true
        }
        "route_router_traffic" => {
            s.route_router_traffic = !s.route_router_traffic;
            true
        }
        "smart_queue" => {
            s.smart_queue = !s.smart_queue;
            true
        }
        "direct_bypass_enabled" => {
            s.direct_bypass_enabled = !s.direct_bypass_enabled;
            true
        }
        _ => false,
    }
}

async fn render_toggles_menu(
    state: &Arc<AppState>,
    group_arg: &str,
    notice: Option<String>,
) -> BotReply {
    let group = if group_arg.trim().eq_ignore_ascii_case("net") {
        "net"
    } else {
        "core"
    };
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let mut lines = vec![format!(
        "<b>{}</b> ({})",
        tr(ru, "Быстрые переключатели", "Quick Toggles"),
        if group == "net" {
            tr(ru, "Сеть и DNS", "Network & DNS")
        } else {
            tr(ru, "Ядро и система", "Core & System")
        }
    )];
    if let Some(n) = notice {
        lines.push(n);
    }

    let mut btns: Vec<Value> = Vec::new();
    for spec in QUICK_TOGGLE_SPECS.iter().filter(|sp| sp.group == group) {
        let val = read_quick_toggle_val(&d.settings, spec.key);
        let lbl = if ru { spec.ru } else { spec.en };
        let st = if val { "[ON]" } else { "[OFF]" };
        lines.push(format!("{st} {lbl}"));
        btns.push(cb_btn(
            &format!("{st} {lbl}"),
            &format!("bot_feat_tog {group} {}", spec.key),
        ));
    }

    let mut rows: Vec<Vec<Value>> = vec![vec![
        cb_btn(
            if group == "core" {
                "• Ядро / Система"
            } else {
                "Ядро / Система"
            },
            "bot_toggles_menu core",
        ),
        cb_btn(
            if group == "net" {
                "• Сеть / DNS"
            } else {
                "Сеть / DNS"
            },
            "bot_toggles_menu net",
        ),
    ]];
    rows.extend(btns.chunks(2).map(<[Value]>::to_vec));
    rows.push(vec![
        cb_btn(tr(ru, "Уведомления", "Notifications"), "bot_notify_menu"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]);
    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn toggle_feature_setting_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    arg: &str,
) -> BotReply {
    let mut parts = arg.split_whitespace();
    let (group, key) = match (parts.next(), parts.next()) {
        (Some(g), Some(k)) => (g, k),
        (Some(k), None) => ("core", k),
        _ => return render_toggles_menu(state, "core", None).await,
    };

    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    if !flip_quick_toggle_val(&mut candidate.settings, key) {
        return render_toggles_menu(
            state,
            group,
            Some(format!("[ERR] Unknown toggle: {}", escape_html(key))),
        )
        .await;
    }

    let apply_kind = QUICK_TOGGLE_SPECS
        .iter()
        .find(|sp| sp.key == key)
        .map_or(ToggleApplyKind::None, |sp| sp.apply);

    let save_res = crate::transaction::commit_transaction(state, candidate).await;
    let notice = match save_res {
        Ok(_report) => {
            let saved = state.data.read().await.clone();
            sync_tg_store_json_and_cache(&saved);
            let apply_warn = match apply_kind {
                ToggleApplyKind::Reload => core
                    .apply_or_reload()
                    .await
                    .err()
                    .map(|e| format!("\n[WARN] {}", escape_html(&e.to_string())))
                    .unwrap_or_default(),
                ToggleApplyKind::Firewall => crate::net_stack::apply_network_stack(&saved)
                    .await
                    .err()
                    .map(|e| format!("\n[WARN] {}", escape_html(&e.to_string())))
                    .unwrap_or_default(),
                ToggleApplyKind::None => String::new(),
            };
            let new_val = read_quick_toggle_val(&saved.settings, key);
            let badge = if new_val { "[ON]" } else { "[OFF]" };
            format!(
                "[OK] <code>{}</code> -> {badge}{apply_warn}",
                escape_html(key)
            )
        }
        Err(e) => format!(
            "[ERR] {}: {}",
            tr(ru, "Ошибка сохранения", "Save failed"),
            escape_html(&e.to_string())
        ),
    };
    render_toggles_menu(state, group, Some(notice)).await
}

async fn render_bot_proxy_menu(state: &Arc<AppState>) -> BotReply {
    let (d, core_running) = {
        let data = state.data.read().await.clone();
        let live = state.live.read().await;
        (data, live.core_running)
    };
    let ru = is_ru(&d);
    let current = describe_bot_proxy(&d, core_running, ru);

    let mut rows: Vec<Vec<Value>> = vec![vec![
        cb_btn(
            tr(
                ru,
                "Auto (service-mixed-in :4534)",
                "Auto (service-mixed-in :4534)",
            ),
            "bot_proxy_set auto",
        ),
        cb_btn("Direct (WAN)", "bot_proxy_set direct"),
    ]];

    let mut sec_btns: Vec<Value> = Vec::new();
    for s in d
        .sections
        .iter()
        .filter(|s| s.enabled && !matches!(s.connection_type.as_str(), "dns" | "block"))
    {
        let lbl = if s.label.trim().is_empty() {
            s.id.as_str()
        } else {
            s.label.as_str()
        };
        sec_btns.push(cb_btn(lbl, &format!("bot_proxy_set {}", s.id)));
    }
    for chunk in sec_btns.chunks(2) {
        rows.push(chunk.to_vec());
    }
    rows.push(vec![
        cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
        cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
    ]);

    let text = format!(
        "<b>{}</b>\n{}: <code>{}</code>",
        tr(ru, "Прокси-маршрут Telegram-бота", "Bot Proxy Section"),
        tr(ru, "Текущий режим", "Current mode"),
        escape_html(&current)
    );
    BotReply::with_kb(text, inline_kb(rows))
}

async fn set_bot_proxy_reply(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    raw_ref: &str,
) -> BotReply {
    let trimmed = raw_ref.trim();
    let new_val = if trimmed.eq_ignore_ascii_case("auto") || trimmed.eq_ignore_ascii_case("default")
    {
        String::new()
    } else {
        trimmed.to_string()
    };

    let (ru, prev_val, valid_match) = {
        let d = state.data.read().await;
        let matched = new_val.is_empty()
            || new_val.eq_ignore_ascii_case("direct")
            || d.sections
                .iter()
                .any(|s| s.enabled && (s.id == new_val || s.label.eq_ignore_ascii_case(&new_val)));
        (is_ru(&d), d.telegram.bot_proxy_section.clone(), matched)
    };

    if !valid_match {
        return BotReply::with_kb(
            format!(
                "[ERR] {}: <code>{}</code>",
                tr(
                    ru,
                    "Секция не найдена или выключена",
                    "Section not found or disabled"
                ),
                escape_html(&new_val)
            ),
            inline_kb(vec![vec![cb_btn(
                tr(ru, "Назад", "Back"),
                "bot_proxy_menu",
            )]]),
        );
    }

    let normalized = if new_val.eq_ignore_ascii_case("direct") {
        "direct".to_string()
    } else {
        new_val
    };

    let changed = prev_val != normalized;
    if changed {
        if let Err(e) = update_telegram_cfg(state, |tg| {
            tg.bot_proxy_section = normalized.clone();
            Ok(())
        })
        .await
        {
            return BotReply::text(format!("[ERR] {}", escape_html(&e.to_string())));
        }
        reload_core_boxed(core).await;
    }

    render_bot_proxy_menu(state).await
}

async fn add_admin_id_reply(state: &Arc<AppState>, raw: &str) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    let Ok(new_id) = raw.trim().parse::<i64>() else {
        return BotReply::with_kb(
            format!(
                "[ERR] {}",
                tr(
                    ru,
                    "Некорректный ID. Введите числовой Telegram Chat ID.",
                    "Invalid ID. Enter a numeric Telegram Chat ID."
                )
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Повторить", "Retry"), "bot_admin_ask"),
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
            ]]),
        );
    };
    if new_id == 0 {
        return BotReply::with_kb(
            format!(
                "[ERR] {}",
                tr(ru, "Chat ID не может быть равен 0.", "Chat ID cannot be 0.")
            ),
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Повторить", "Retry"), "bot_admin_ask"),
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
            ]]),
        );
    }

    let mut already = false;
    match update_telegram_cfg(state, |tg| {
        if tg.admin_ids.contains(&new_id) {
            already = true;
        } else {
            tg.admin_ids.push(new_id);
        }
        Ok(())
    })
    .await
    {
        Ok(_) => BotReply::with_kb(
            if already {
                format!(
                    "[OK] Admin ID <code>{new_id}</code> {}",
                    tr(ru, "уже добавлен.", "is already configured.")
                )
            } else {
                format!(
                    "[OK] Admin ID <code>{new_id}</code> {}",
                    tr(ru, "добавлен.", "added.")
                )
            },
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "bot_cfg"),
                cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
            ]]),
        ),
        Err(e) => BotReply::text(format!("[ERR] {}", escape_html(&e.to_string()))),
    }
}

// ---------------------------------------------------------------------------
// Public Dispatcher Entrypoints
// ---------------------------------------------------------------------------

async fn set_prompt_reply(
    state: &Arc<AppState>,
    chat_id: i64,
    kind: PendingPromptKind,
    ru_msg: &'static str,
    en_msg: &'static str,
    cancel_cmd: &'static str,
) -> BotReply {
    let ru = is_ru(&*state.data.read().await);
    set_chat_prompt(chat_id, kind);
    BotReply::with_kb(
        tr(ru, ru_msg, en_msg),
        inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), cancel_cmd)]]),
    )
}

async fn dispatch_diag_ops(
    cmd_lc: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match cmd_lc {
        "/doctor" | "doc_run" => Box::pin(render_doctor(state, core)),
        "/fix" => {
            if arg.trim().is_empty() {
                Box::pin(async move {
                    let ru = is_ru(&*state.data.read().await);
                    render_fix_menu(ru)
                })
            } else {
                let fid = arg.split_whitespace().next().unwrap_or("");
                Box::pin(run_quick_fix_reply(state, core, fid))
            }
        }
        "fix_apply" => {
            let fid = arg.split_whitespace().next().unwrap_or("");
            Box::pin(run_quick_fix_reply(state, core, fid))
        }
        "/ai_doctor" | "ai_doc_run" => {
            let q = (!arg.trim().is_empty()).then_some(arg.trim());
            Box::pin(render_ai_doctor(state, core, q))
        }
        "ai_doc_ask" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::AiDoctorQuestion,
            "Опишите проблему сети или вопрос для AI Doctor (отмена: /cancel):",
            "Describe your network question for AI Doctor (/cancel to abort):",
            "ai_doc_run",
        )),
        "/logs" | "logs_view" => Box::pin(render_logs_view(state, arg)),
        "/support" | "support_bundle" => Box::pin(build_support_bundle_reply(state)),
        _ => return None,
    };
    Some(fut.await)
}

async fn dispatch_net_ops(
    cmd_lc: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match cmd_lc {
        "/trace" => {
            if arg.trim().is_empty() {
                Box::pin(async move {
                    let ru = is_ru(&*state.data.read().await);
                    render_trace_menu(ru)
                })
            } else {
                Box::pin(run_trace_reply(state, core, arg))
            }
        }
        "trace_menu" => Box::pin(async move {
            let ru = is_ru(&*state.data.read().await);
            render_trace_menu(ru)
        }),
        "trace_prompt" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::RouteTraceInput,
            "Введите домен и (опционально) IP клиента, например: <code>youtube.com 192.168.1.50</code>",
            "Enter domain and optional client IP, e.g. <code>youtube.com 192.168.1.50</code>",
            "trace_menu",
        )),
        "/dns" | "dns_menu" => Box::pin(render_dns_menu(state)),
        "dns_check" => {
            if arg.trim().is_empty() {
                Box::pin(set_prompt_reply(
                    state,
                    chat_id,
                    PendingPromptKind::DnsCheckInput,
                    "Введите домен для проверки DNS, например: <code>www.youtube.com</code>",
                    "Enter a domain to verify via DNS, e.g. <code>www.youtube.com</code>",
                    "dns_menu",
                ))
            } else {
                Box::pin(run_dns_check_reply(state, core, arg))
            }
        }
        "dns_bench" => Box::pin(run_dns_bench_reply(state)),
        "dns_preset" => Box::pin(apply_dns_preset_reply(state, core, arg)),
        "/leak" | "leak_run" => Box::pin(run_leak_reply(state, core)),
        "failover_view" | "/failover" => Box::pin(render_failover_view(state, core)),
        "failover_restore" => Box::pin(run_failover_restore_reply(state, core, arg)),
        "failover_recheck" => Box::pin(run_failover_recheck_reply(state, core)),
        _ => return None,
    };
    Some(fut.await)
}

async fn dispatch_fuzzer_ops(
    cmd_lc: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match cmd_lc {
        "/fuzzer" | "fuz_view" => Box::pin(render_fuzzer_view(state)),
        "fuz_start" => {
            let mut parts = arg.split_whitespace();
            let target = parts.next().unwrap_or("youtube");
            let mode = parts.next().unwrap_or("presets");
            Box::pin(start_fuzzer_reply(state, core, target, "", mode))
        }
        "fuz_custom" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::FuzzerCustomTarget,
            "Введите домен или URL для подбора стратегии десинхронизации (например: <code>example.com</code>):",
            "Enter domain or URL to benchmark desync strategies (e.g. <code>example.com</code>):",
            "fuz_view",
        )),
        "fuz_stop" => Box::pin(stop_fuzzer_reply(state)),
        "fuz_apply_menu" => {
            let rank = arg.trim().parse::<usize>().unwrap_or(0);
            Box::pin(render_fuzzer_apply_menu(state, rank))
        }
        "fuz_apply" => {
            let mut parts = arg.split_whitespace();
            let rank = parts
                .next()
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(0);
            let sec_id = parts.next().unwrap_or("");
            Box::pin(apply_fuzzer_strategy_reply(state, core, rank, sec_id))
        }
        _ => return None,
    };
    Some(fut.await)
}

async fn dispatch_updates_ops(
    cmd_lc: &str,
    arg: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match cmd_lc {
        "/updates" | "upd_view" => Box::pin(render_updates_view(state, core, false)),
        "upd_check" => Box::pin(render_updates_view(state, core, true)),
        "upd_install" => Box::pin(run_update_install_reply(state, core, arg)),
        "upd_rollback" => Box::pin(run_update_rollback_reply(state, core, arg)),
        "/update_lists" | "upd_lists" => Box::pin(run_lists_update_reply(state, core)),
        _ => return None,
    };
    Some(fut.await)
}

async fn dispatch_snapshots_ops(
    cmd_lc: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match cmd_lc {
        "/snapshots" | "snap_list" => Box::pin(render_snapshots_list(state)),
        "/backup" => Box::pin(save_snapshot_reply(state, "telegram", true)),
        "snap_save" => Box::pin(save_snapshot_reply(state, "telegram", false)),
        "snap_save_ask" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::CreateSnapshotName,
            "Введите название для нового снапшота:",
            "Enter a name for the new snapshot:",
            "snap_list",
        )),
        "snap_view" => Box::pin(render_snapshot_view(state, arg)),
        "snap_restore" => Box::pin(restore_snapshot_reply(state, core, arg)),
        "snap_del" => Box::pin(delete_snapshot_reply(state, arg)),
        "snap_doc" => Box::pin(download_snapshot_doc(state, arg)),
        "snap_code" => Box::pin(export_transfer_code_reply(state)),
        "snap_import_ask" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::ImportSnapshotPayload,
            "Отправьте код переноса <code>tachyon://rs2/...</code> или JSON профиля:",
            "Send a <code>tachyon://rs2/...</code> transfer code or profile JSON:",
            "snap_list",
        )),
        "quick_import" => Box::pin(import_snapshot_payload_reply(state, core, arg)),
        "/lkg" | "lkg_view" => Box::pin(render_lkg_view(state)),
        "lkg_promote" => Box::pin(promote_lkg_reply(state)),
        "/rollback" => Box::pin(run_quick_fix_reply(state, core, "rollback_known_good")),
        _ => return None,
    };
    Some(fut.await)
}

async fn dispatch_bot_cfg_ops(
    cmd_lc: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match cmd_lc {
        "/bot_settings" | "bot_cfg" => Box::pin(render_bot_settings(state)),
        "/lang" | "bot_lang" => Box::pin(set_bot_language_reply(state, arg)),
        "/name" => {
            if arg.trim().is_empty() {
                Box::pin(set_prompt_reply(
                    state,
                    chat_id,
                    PendingPromptKind::SetRouterName,
                    "Введите новое отображаемое имя роутера (1..48 символов):",
                    "Enter new router display name (1..48 chars):",
                    "bot_cfg",
                ))
            } else {
                Box::pin(set_router_name_reply(state, arg))
            }
        }
        "bot_name_ask" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::SetRouterName,
            "Введите новое отображаемое имя роутера (1..48 символов):",
            "Enter new router display name (1..48 chars):",
            "bot_cfg",
        )),
        "/quiet" => {
            if arg.trim().is_empty() {
                Box::pin(render_quiet_hours_view(state))
            } else {
                Box::pin(set_quiet_hours_window_reply(state, arg))
            }
        }
        "bot_quiet_tog" => Box::pin(toggle_quiet_hours_reply(state)),
        "bot_quiet_ask" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::SetQuietHours,
            "Введите интервал тихих часов в формате <code>HH:MM-HH:MM</code> (например <code>23:00-07:00</code>):",
            "Enter quiet hours range as <code>HH:MM-HH:MM</code> (e.g. <code>23:00-07:00</code>):",
            "bot_cfg",
        )),
        "/notify" | "/notifications" | "bot_notify_menu" => Box::pin(render_notify_menu(state)),
        "bot_notify_tog" => Box::pin(toggle_notify_field_reply(state, arg)),
        "bot_notify_all" => Box::pin(set_all_notify_reply(state, arg)),
        "/toggles" | "/features" | "bot_toggles_menu" => {
            Box::pin(render_toggles_menu(state, arg, None))
        }
        "bot_feat_tog" => Box::pin(toggle_feature_setting_reply(state, core, arg)),
        "bot_proxy_menu" => Box::pin(render_bot_proxy_menu(state)),
        "bot_proxy_set" => Box::pin(set_bot_proxy_reply(state, core, arg)),
        "bot_admin_ask" => Box::pin(set_prompt_reply(
            state,
            chat_id,
            PendingPromptKind::AddAdminId,
            "Введите числовой Telegram Chat ID администратора:",
            "Enter numeric Telegram admin Chat ID:",
            "bot_cfg",
        )),
        _ => return None,
    };
    Some(fut.await)
}

async fn dispatch_fleet_ops(
    cmd_lc: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
) -> Option<BotReply> {
    let rid = arg.trim();
    match cmd_lc {
        "flt_upd_chk" => {
            clear_chat_prompt(chat_id);
            Some(Box::pin(super::fleet::render_router_updates(state, rid)).await)
        }
        "flt_upd_ask" => {
            clear_chat_prompt(chat_id);
            Some(
                Box::pin(super::fleet::render_router_action_confirm(
                    state,
                    rid,
                    super::fleet::FleetConfirmAction::UpdateTachyon,
                ))
                .await,
            )
        }
        "flt_upd_ok" => {
            clear_chat_prompt(chat_id);
            Some(
                Box::pin(super::fleet::execute_router_action_confirmed(
                    state,
                    rid,
                    super::fleet::FleetConfirmAction::UpdateTachyon,
                ))
                .await,
            )
        }
        "flt_rst_ask" => {
            clear_chat_prompt(chat_id);
            Some(
                Box::pin(super::fleet::render_router_action_confirm(
                    state,
                    rid,
                    super::fleet::FleetConfirmAction::RestartTachyon,
                ))
                .await,
            )
        }
        "flt_rst_ok" => {
            clear_chat_prompt(chat_id);
            Some(
                Box::pin(super::fleet::execute_router_action_confirmed(
                    state,
                    rid,
                    super::fleet::FleetConfirmAction::RestartTachyon,
                ))
                .await,
            )
        }
        _ => None,
    }
}

async fn try_handle_ops_inner(
    cmd: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let trimmed_cmd = cmd.trim();
    if let Some(fid) = trimmed_cmd.strip_prefix("fix:apply:") {
        return Some(Box::pin(run_quick_fix_reply(state, core, fid)).await);
    }

    let cmd_lc = trimmed_cmd.to_ascii_lowercase();
    if let Some(reply) = Box::pin(dispatch_fleet_ops(&cmd_lc, arg, chat_id, state)).await {
        return Some(reply);
    }
    if let Some(reply) = Box::pin(dispatch_diag_ops(&cmd_lc, arg, chat_id, state, core)).await {
        return Some(reply);
    }
    if let Some(reply) = Box::pin(dispatch_net_ops(&cmd_lc, arg, chat_id, state, core)).await {
        return Some(reply);
    }
    if let Some(reply) = Box::pin(dispatch_fuzzer_ops(&cmd_lc, arg, chat_id, state, core)).await {
        return Some(reply);
    }
    if let Some(reply) = Box::pin(dispatch_updates_ops(&cmd_lc, arg, state, core)).await {
        return Some(reply);
    }
    if let Some(reply) = Box::pin(dispatch_snapshots_ops(&cmd_lc, arg, chat_id, state, core)).await
    {
        return Some(reply);
    }
    Box::pin(dispatch_bot_cfg_ops(&cmd_lc, arg, chat_id, state, core)).await
}

pub(crate) async fn try_handle_ops(
    cmd: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    Box::pin(try_handle_ops_inner(cmd, arg, chat_id, state, core)).await
}

async fn handle_ops_prompt_inner(
    kind: PendingPromptKind,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxOpsFuture<'_> = match kind {
        PendingPromptKind::RouteTraceInput => {
            clear_chat_prompt(chat_id);
            Box::pin(run_trace_reply(state, core, input))
        }
        PendingPromptKind::DnsCheckInput => {
            clear_chat_prompt(chat_id);
            Box::pin(run_dns_check_reply(state, core, input))
        }
        PendingPromptKind::AiDoctorQuestion => {
            clear_chat_prompt(chat_id);
            let q = (!input.trim().is_empty()).then_some(input.trim());
            Box::pin(render_ai_doctor(state, core, q))
        }
        PendingPromptKind::FuzzerCustomTarget => {
            clear_chat_prompt(chat_id);
            Box::pin(start_fuzzer_reply(
                state,
                core,
                "custom",
                input.trim(),
                "presets",
            ))
        }
        PendingPromptKind::CreateSnapshotName => {
            clear_chat_prompt(chat_id);
            Box::pin(save_snapshot_reply(state, input, true))
        }
        PendingPromptKind::ImportSnapshotPayload => {
            clear_chat_prompt(chat_id);
            Box::pin(import_snapshot_payload_reply(state, core, input))
        }
        PendingPromptKind::SetRouterName => {
            clear_chat_prompt(chat_id);
            Box::pin(set_router_name_reply(state, input))
        }
        PendingPromptKind::SetQuietHours => {
            clear_chat_prompt(chat_id);
            Box::pin(set_quiet_hours_window_reply(state, input))
        }
        PendingPromptKind::AddAdminId => {
            clear_chat_prompt(chat_id);
            Box::pin(add_admin_id_reply(state, input))
        }
        _ => return None,
    };
    Some(fut.await)
}

pub(crate) async fn handle_ops_prompt(
    kind: PendingPromptKind,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    Box::pin(handle_ops_prompt_inner(kind, input, chat_id, state, core)).await
}
