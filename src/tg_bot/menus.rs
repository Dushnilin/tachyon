//! Interactive Telegram Bot menus and CRUD handlers for Tachyon Router.

use std::collections::HashSet;
use std::future::Future;
use std::net::IpAddr;
use std::pin::Pin;
use std::sync::Arc;

use serde_json::Value;

use crate::config_gen::{
    build_router_subscription_payload, build_server_share_uri, build_server_wg_conf,
    compile_core_config, count_fptn_token_servers, decode_fptn_token_json_with_core_bin,
    expand_fptn_token_outbounds, normalize_fptn_token_input, parse_proxy_uri,
};
use crate::core_mgr::CoreManager;
use crate::crypto_gen::auto_configure_server;
use crate::store::{
    AppState, InboundServer, LiveTelemetry, OutboundSource, ParsedProxyNode, RouterStoreData,
    RoutingSection, unix_now_secs,
};
use crate::sys_info::{
    LanDevice, collect_dnsmasq_status, collect_host_info, count_open_fds, daemon_uptime_secs,
    detect_router_ips, discover_lan_devices, process_rss_bytes, sample_cpu_load_percent,
};
use crate::transaction::commit_transaction;

use super::{
    BotReply, PendingPromptKind, cb_btn, clear_chat_prompt, escape_html, inline_kb, is_ru,
    set_chat_prompt, tr,
};

const PER_PAGE: usize = 6;
const LISTS_PER_PAGE: usize = 8;

const COMMUNITY_LIST_CATALOG: &[&str] = &[
    "youtube",
    "discord",
    "telegram",
    "openai",
    "anthropic",
    "google_ai",
    "github",
    "instagram",
    "facebook",
    "twitter",
    "twitch",
    "spotify",
    "netflix",
    "tiktok",
    "steam",
    "russia_outside",
    "ru_blocked_all",
    "geoblock",
    "ads_hagezi_pro",
];

const SECTION_MODES: &[&str] = &[
    "proxy",
    "desync",
    "wdtt",
    "fptn",
    "tailscale",
    "direct",
    "block",
];

const DESYNC_PRESETS: &[(&str, &str, &str)] = &[
    ("adaptive", "Adaptive Auto", "Adaptive Auto"),
    ("russia_youtube_tlsrec", "YouTube TLSRec", "YouTube TLSRec"),
    ("russia_discord", "Discord Preset", "Discord Preset"),
    ("aggressive", "Aggressive", "Aggressive"),
    ("soft", "Soft", "Soft"),
];

const SERVER_PROTOCOLS: &[&str] = &[
    "vless",
    "hysteria2",
    "tuic",
    "shadowsocks",
    "awg",
    "wireguard",
    "trojan",
    "mtproto",
    "anytls",
    "tewfai",
];

type BoxBotFuture<'a> = Pin<Box<dyn Future<Output = BotReply> + Send + 'a>>;

pub(crate) async fn try_handle_menu(
    cmd: &str,
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut = dispatch_menu_system(cmd, chat_id, state, core)
        .or_else(|| dispatch_menu_fleet(cmd, arg, chat_id, state))
        .or_else(|| dispatch_menu_sections(cmd, arg, chat_id, state, core))
        .or_else(|| dispatch_menu_sources(cmd, arg, chat_id, state, core))
        .or_else(|| dispatch_menu_servers(cmd, arg, state, core))
        .or_else(|| dispatch_menu_lan(cmd, arg, state, core))?;
    Some(fut.await)
}

fn dispatch_menu_fleet<'a>(
    cmd: &'a str,
    arg: &'a str,
    chat_id: i64,
    state: &'a Arc<AppState>,
) -> Option<BoxBotFuture<'a>> {
    match cmd {
        "/routers" => Some(Box::pin(super::fleet::handle_routers_command(
            arg, chat_id, state,
        ))),
        "flt_list" => {
            clear_chat_prompt(chat_id);
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(super::fleet::render_fleet_overview(
                state, page, None,
            )))
        }
        "flt_view" => {
            clear_chat_prompt(chat_id);
            Some(Box::pin(super::fleet::render_router_detail(
                state,
                arg.trim(),
                None,
            )))
        }
        "flt_add" => Some(Box::pin(super::fleet::start_add_router_prompt(
            chat_id, state,
        ))),
        "flt_tog" => {
            clear_chat_prompt(chat_id);
            Some(Box::pin(super::fleet::toggle_router_enabled(
                state,
                arg.trim(),
            )))
        }
        "flt_del_ask" => {
            clear_chat_prompt(chat_id);
            Some(Box::pin(super::fleet::render_router_action_confirm(
                state,
                arg.trim(),
                super::fleet::FleetConfirmAction::RemoveRouter,
            )))
        }
        "flt_del_ok" => {
            clear_chat_prompt(chat_id);
            Some(Box::pin(super::fleet::execute_router_action_confirmed(
                state,
                arg.trim(),
                super::fleet::FleetConfirmAction::RemoveRouter,
            )))
        }
        _ => None,
    }
}

fn dispatch_menu_system<'a>(
    cmd: &'a str,
    chat_id: i64,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Option<BoxBotFuture<'a>> {
    match cmd {
        "/start" | "/menu" | "/help" | "menu" => {
            clear_chat_prompt(chat_id);
            Some(Box::pin(render_main_menu(state)))
        }
        "/status" | "/sysinfo" | "/core" => Some(Box::pin(render_system_status(state, None))),
        "/start_core" | "sys_start" => Some(Box::pin(handle_sys_action("start", state, core))),
        "/stop_core" | "sys_stop" => Some(Box::pin(handle_sys_action("stop", state, core))),
        "/restart" | "/reload" | "sys_reload" => {
            Some(Box::pin(handle_sys_action("reload", state, core)))
        }
        "/trim_ram" | "sys_trim" => Some(Box::pin(handle_sys_action("trim", state, core))),
        "/close_conns" | "sys_close_conns" => {
            Some(Box::pin(handle_sys_action("close_conns", state, core)))
        }
        "/watchdog" | "sys_toggle_wd" => Some(Box::pin(handle_sys_toggle("wd", state, core))),
        "sys_toggle_sqm" => Some(Box::pin(handle_sys_toggle("sqm", state, core))),
        "sys_toggle_fakeip" => Some(Box::pin(handle_sys_toggle("fakeip", state, core))),
        _ => None,
    }
}

fn dispatch_menu_sections<'a>(
    cmd: &'a str,
    arg: &'a str,
    chat_id: i64,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Option<BoxBotFuture<'a>> {
    if let Some(rest) = cmd.strip_prefix("srv:select:") {
        let full = if arg.is_empty() {
            rest.to_string()
        } else {
            format!("{rest} {arg}")
        };
        if let Some((sec_id, tag)) = full.split_once(':') {
            let sec_owned = sec_id.trim().to_string();
            let tag_owned = tag.trim().to_string();
            return Some(Box::pin(async move {
                handle_sec_pick(&sec_owned, &tag_owned, state, core).await
            }));
        }
        return None;
    }

    if let Some(sec_id) = cmd.strip_prefix("rule:toggle:") {
        return Some(Box::pin(handle_sec_toggle(sec_id.trim(), state, core)));
    }

    match cmd {
        "/sections" | "/sec" | "/rules" => Some(Box::pin(render_sections_list(state, 0, None))),
        "/fptn" => Some(Box::pin(handle_fptn_shortcut(state))),
        "sec_list" => {
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(render_sections_list(state, page, None)))
        }
        "sec_view" => Some(Box::pin(render_section_view(state, core, arg.trim(), None))),
        "sec_tog" => Some(Box::pin(handle_sec_toggle(arg.trim(), state, core))),
        "sec_up" => Some(Box::pin(handle_sec_move(arg.trim(), -1, state, core))),
        "sec_dn" => Some(Box::pin(handle_sec_move(arg.trim(), 1, state, core))),
        "sec_modes" => Some(Box::pin(render_section_modes(state, arg.trim()))),
        "sec_mode" => {
            let (sec_id, mode) = split_pair(arg);
            Some(Box::pin(handle_sec_mode(sec_id, mode, state, core)))
        }
        "sec_nodes" => {
            let (sec_id, page) = split_id_page(arg);
            Some(Box::pin(render_section_nodes(
                state, core, sec_id, page, None,
            )))
        }
        "sec_pick" => {
            let (sec_id, tag) = split_pair(arg);
            Some(Box::pin(handle_sec_pick(sec_id, tag, state, core)))
        }
        "sec_desyncs" => Some(Box::pin(render_section_desyncs(state, arg.trim()))),
        "sec_desync" => {
            let (sec_id, preset) = split_pair(arg);
            Some(Box::pin(handle_sec_desync(sec_id, preset, state, core)))
        }
        "sec_conds" => {
            let (sec_id, page) = split_id_page(arg);
            Some(Box::pin(render_section_conditions(
                state, sec_id, page, None,
            )))
        }
        "sec_cond_tog" => {
            let (sec_id, cond_id) = split_pair(arg);
            Some(Box::pin(handle_sec_cond_toggle(
                sec_id, cond_id, state, core,
            )))
        }
        "sec_lists" => {
            let (sec_id, page) = split_id_page(arg);
            Some(Box::pin(render_section_lists(state, sec_id, page, None)))
        }
        "sec_list_tog" => {
            let (sec_id, list_id) = split_pair(arg);
            Some(Box::pin(handle_sec_list_toggle(
                sec_id, list_id, state, core,
            )))
        }
        "sec_add_dom" => Some(Box::pin(prompt_section_input(
            chat_id,
            state,
            arg.trim(),
            SectionPromptMode::AddDomain,
        ))),
        "sec_rm_dom" => Some(Box::pin(prompt_section_input(
            chat_id,
            state,
            arg.trim(),
            SectionPromptMode::RemoveDomain,
        ))),
        "sec_add_ip" => Some(Box::pin(prompt_section_input(
            chat_id,
            state,
            arg.trim(),
            SectionPromptMode::AddIp,
        ))),
        "sec_fptn" => Some(Box::pin(prompt_section_input(
            chat_id,
            state,
            arg.trim(),
            SectionPromptMode::UpdateFptn,
        ))),
        _ => None,
    }
}

fn dispatch_menu_sources<'a>(
    cmd: &'a str,
    arg: &'a str,
    chat_id: i64,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Option<BoxBotFuture<'a>> {
    match cmd {
        "/sources" | "/subs" | "/outbounds" => Some(Box::pin(render_sources_list(state, 0, None))),
        "/ping" | "src_ping" => Some(Box::pin(handle_ping_all(state, core))),
        "src_list" => {
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(render_sources_list(state, page, None)))
        }
        "src_view" => {
            let (src_id, page) = split_id_page(arg);
            Some(Box::pin(render_source_view(state, src_id, page, None)))
        }
        "src_refresh" => Some(Box::pin(handle_src_refresh(arg.trim(), state, core))),
        "src_refresh_all" => Some(Box::pin(handle_src_refresh("", state, core))),
        "src_tog" => Some(Box::pin(handle_src_toggle(arg.trim(), state, core))),
        "src_del" => Some(Box::pin(render_source_delete_confirm(state, arg.trim()))),
        "src_del_ok" => Some(Box::pin(handle_src_delete(arg.trim(), state, core))),
        "src_add" => Some(Box::pin(prompt_add_source(chat_id, state))),
        "src_fptn" => Some(Box::pin(prompt_source_fptn_input(
            chat_id,
            state,
            arg.trim(),
        ))),
        "src_warp" => Some(Box::pin(handle_src_warp(state, core))),
        "src_exit" => Some(Box::pin(handle_src_exit(arg.trim(), state, core))),
        "quick_add_uri" => Some(Box::pin(handle_import_subscription_or_uri(
            arg, chat_id, state, core,
        ))),
        _ => None,
    }
}

fn dispatch_menu_servers<'a>(
    cmd: &'a str,
    arg: &'a str,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Option<BoxBotFuture<'a>> {
    match cmd {
        "/servers" | "/srv" => Some(Box::pin(render_servers_list(state, 0, None))),
        "srv_list" => {
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(render_servers_list(state, page, None)))
        }
        "srv_view" => Some(Box::pin(render_server_view(state, arg.trim(), None))),
        "srv_tog" => Some(Box::pin(handle_srv_toggle(arg.trim(), state, core))),
        "srv_uri" => Some(Box::pin(handle_srv_uri(arg.trim(), state))),
        "srv_wg" => Some(Box::pin(handle_srv_wg(arg.trim(), state))),
        "srv_sub" => Some(Box::pin(handle_srv_sub(state))),
        "srv_new_menu" => Some(Box::pin(render_server_new_menu(state))),
        "srv_create" => Some(Box::pin(handle_srv_create(arg.trim(), state, core))),
        "srv_clients" => {
            let (srv_id, page) = split_id_page(arg);
            Some(Box::pin(render_server_clients(state, srv_id, page, None)))
        }
        "srv_client_tog" => {
            let (srv_id, idx_str) = split_id_last(arg);
            let idx = parse_usize_or(idx_str, usize::MAX);
            Some(Box::pin(handle_srv_client_toggle(srv_id, idx, state, core)))
        }
        _ => None,
    }
}

fn dispatch_menu_lan<'a>(
    cmd: &'a str,
    arg: &'a str,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Option<BoxBotFuture<'a>> {
    match cmd {
        "/devices" => Some(Box::pin(render_devices_list(state, 0, None))),
        "/wol" => Some(Box::pin(handle_wol_command(arg.trim(), state, core))),
        "dev_list" => {
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(render_devices_list(state, page, None)))
        }
        "dev_view" => {
            let idx = parse_usize_or(arg, usize::MAX);
            Some(Box::pin(render_device_view(state, idx, None)))
        }
        "dev_sec" => {
            let (idx_s, sec_arg) = split_pair(arg);
            let idx = parse_usize_or(idx_s, usize::MAX);
            Some(Box::pin(handle_dev_section(idx, sec_arg, state, core)))
        }
        "dev_block" => {
            let idx = parse_usize_or(arg, usize::MAX);
            Some(Box::pin(handle_dev_block(idx, state, core)))
        }
        "dev_wol" => {
            let idx = parse_usize_or(arg, usize::MAX);
            Some(Box::pin(handle_dev_wol(idx, state, core)))
        }
        "/parental" | "par_list" => {
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(render_parental_list(state, page, None)))
        }
        "par_tog" => Some(Box::pin(handle_parental_toggle(arg.trim(), state, core))),
        "/guest" | "guest_view" => Some(Box::pin(render_guest_view(state, None))),
        "guest_tog" => Some(Box::pin(handle_guest_toggle(false, state, core))),
        "guest_iso" => Some(Box::pin(handle_guest_toggle(true, state, core))),
        "/schedules" | "sched_list" => {
            let page = parse_usize_or(arg, 0);
            Some(Box::pin(render_schedules_list(state, page, None)))
        }
        "sched_tog" => Some(Box::pin(handle_schedule_toggle(arg.trim(), state, core))),
        _ => None,
    }
}

pub(crate) async fn handle_menu_prompt(
    kind: PendingPromptKind,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let fut: BoxBotFuture<'_> =
        match kind {
            PendingPromptKind::AddDomainToSection { sec_id } => Box::pin(async move {
                handle_add_domain_prompt(&sec_id, input, chat_id, state, core).await
            }),
            PendingPromptKind::RemoveDomainFromSection { sec_id } => Box::pin(async move {
                handle_remove_domain_prompt(&sec_id, input, chat_id, state, core).await
            }),
            PendingPromptKind::AddIpToSection { sec_id } => {
                Box::pin(
                    async move { handle_add_ip_prompt(&sec_id, input, chat_id, state, core).await },
                )
            }
            PendingPromptKind::UpdateFptnToken { sec_id } => Box::pin(async move {
                handle_update_fptn_prompt(&sec_id, input, chat_id, state, core).await
            }),
            PendingPromptKind::UpdateSourceFptnToken { src_id } => Box::pin(async move {
                handle_update_source_fptn_prompt(&src_id, input, chat_id, state, core).await
            }),
            PendingPromptKind::AddSubscriptionOrUri => Box::pin(handle_import_subscription_or_uri(
                input, chat_id, state, core,
            )),
            kind @ (PendingPromptKind::FleetAddName
            | PendingPromptKind::FleetAddUrl { .. }
            | PendingPromptKind::FleetAddToken { .. }) => {
                return Box::pin(super::fleet::handle_fleet_prompt(
                    kind, input, chat_id, state,
                ))
                .await;
            }
            _ => return None,
        };
    Some(fut.await)
}

async fn handle_sys_action(
    action: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let ru = current_is_ru(state).await;
    let note = match action {
        "start" => match Box::pin(core.start()).await {
            Ok(()) => tr(ru, "[OK] Ядро запущено", "[OK] Core started").to_string(),
            Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
        },
        "stop" => match Box::pin(core.stop()).await {
            Ok(()) => tr(ru, "[OK] Ядро остановлено", "[OK] Core stopped").to_string(),
            Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
        },
        "reload" => match Box::pin(core.apply_or_reload()).await {
            Ok(()) => tr(ru, "[OK] Конфигурация применена", "[OK] Core reloaded").to_string(),
            Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
        },
        "trim" => {
            match Box::pin(core.clash_request("POST", "/tachyon/memory/trim", Some("{}"))).await {
                Ok(_) => tr(
                    ru,
                    "[OK] Запрос очистки памяти отправлен",
                    "[OK] Memory trim requested",
                )
                .to_string(),
                Err(e) => format!("[!] {}", escape_html(&e.to_string())),
            }
        }
        "close_conns" => match Box::pin(core.clash_request("DELETE", "/connections", None)).await {
            Ok(_) => tr(
                ru,
                "[OK] Активные соединения закрыты",
                "[OK] Active connections closed",
            )
            .to_string(),
            Err(e) => format!("[!] {}", escape_html(&e.to_string())),
        },
        _ => String::new(),
    };
    Box::pin(render_system_status(state, Some(note))).await
}

async fn prompt_add_source(chat_id: i64, state: &Arc<AppState>) -> BotReply {
    let ru = current_is_ru(state).await;
    set_chat_prompt(chat_id, PendingPromptKind::AddSubscriptionOrUri);
    let kb = inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "src_list 0")]]);
    BotReply::with_kb(
        tr(
            ru,
            "<b>Добавить подписку или URI</b>\n\nОтправьте HTTPS-ссылку подписки, URI (<code>vless://</code>, <code>vmess://</code>, <code>trojan://</code>, <code>ss://</code>, <code>hy2://</code>, <code>awg://</code>, <code>wg://</code>), токен FPTN (<code>fptn://</code>, <code>fptnb://</code>, JSON) или <code>.fptn</code>-файл.\nДля отмены: /cancel",
            "<b>Add Subscription or URI</b>\n\nSend an HTTPS subscription URL, URI lines (<code>vless://</code>, <code>vmess://</code>, <code>trojan://</code>, <code>ss://</code>, <code>hy2://</code>, <code>awg://</code>, <code>wg://</code>), an FPTN token (<code>fptn://</code>, <code>fptnb://</code>, JSON), or a <code>.fptn</code> file.\nSend /cancel to abort.",
        ),
        kb,
    )
}

async fn current_is_ru(state: &Arc<AppState>) -> bool {
    let d = state.data.read().await;
    is_ru(&d)
}

fn format_reload_warn(warn: Option<String>) -> String {
    warn.map(|w| format!("\n[WARN] {}", escape_html(&w)))
        .unwrap_or_default()
}

fn sync_tg_store_json_and_cache(store: &RouterStoreData) {
    if std::env::var_os("TACHYON_DATA_DIR").is_some() || cfg!(not(test)) {
        crate::ubus_bridge::sync_from_store_to_json_and_cache(store);
    }
}

async fn commit_and_sync_tg_tx(
    state: &Arc<AppState>,
    candidate: RouterStoreData,
) -> anyhow::Result<()> {
    Box::pin(commit_transaction(state, candidate)).await?;
    let saved = state.data.read().await.clone();
    sync_tg_store_json_and_cache(&saved);
    Ok(())
}

async fn commit_and_reload_with_warning(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    candidate: RouterStoreData,
) -> anyhow::Result<Option<String>> {
    commit_and_sync_tg_tx(state, candidate).await?;
    match Box::pin(core.apply_or_reload()).await {
        Ok(()) => Ok(None),
        Err(e) => Ok(Some(e.to_string())),
    }
}

async fn commit_and_reload(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    candidate: RouterStoreData,
) -> anyhow::Result<()> {
    commit_and_sync_tg_tx(state, candidate).await?;
    let _ = Box::pin(core.apply_or_reload()).await;
    Ok(())
}

fn parse_usize_or(raw: &str, default_val: usize) -> usize {
    raw.trim().parse::<usize>().unwrap_or(default_val)
}

fn split_pair(arg: &str) -> (&str, &str) {
    match arg.trim().split_once(char::is_whitespace) {
        Some((a, b)) => (a.trim(), b.trim()),
        None => (arg.trim(), ""),
    }
}

fn split_id_last(arg: &str) -> (&str, &str) {
    match arg.trim().rsplit_once(char::is_whitespace) {
        Some((a, b)) => (a.trim(), b.trim()),
        None => (arg.trim(), ""),
    }
}

fn split_id_page(arg: &str) -> (&str, usize) {
    let trimmed = arg.trim();
    if let Some((head, tail)) = trimmed.rsplit_once(char::is_whitespace)
        && let Ok(page) = tail.trim().parse::<usize>()
    {
        return (head.trim(), page);
    }
    (trimmed, 0)
}

fn paginate(total: usize, page: usize, per_page: usize) -> (usize, usize, usize, usize) {
    let per = per_page.max(1);
    let total_pages = total.div_ceil(per).max(1);
    let safe_page = page.min(total_pages - 1);
    let start = safe_page * per;
    let end = (start + per).min(total);
    (safe_page, total_pages, start, end)
}

fn add_pagination_row(
    rows: &mut Vec<Vec<Value>>,
    cmd_prefix: &str,
    page: usize,
    total_pages: usize,
) {
    if total_pages <= 1 {
        return;
    }
    let mut nav = Vec::new();
    if page > 0 {
        nav.push(cb_btn("<<", &format!("{cmd_prefix} {}", page - 1)));
    }
    nav.push(cb_btn(
        &format!("{}/{}", page + 1, total_pages),
        &format!("{cmd_prefix} {page}"),
    ));
    if page + 1 < total_pages {
        nav.push(cb_btn(">>", &format!("{cmd_prefix} {}", page + 1)));
    }
    rows.push(nav);
}

fn fmt_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    const GB: f64 = 1024.0 * 1024.0 * 1024.0;
    let b = bytes as f64;
    if b >= GB {
        format!("{:.2} GB", b / GB)
    } else if b >= MB {
        format!("{:.1} MB", b / MB)
    } else if b >= KB {
        format!("{:.1} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}

fn fmt_bps(bps: u64) -> String {
    format!("{}/s", fmt_bytes(bps))
}

fn fmt_duration(secs: u64) -> String {
    let days = secs / 86400;
    let hrs = (secs % 86400) / 3600;
    let mins = (secs % 3600) / 60;
    let rem = secs % 60;
    if days > 0 {
        format!("{days}d {hrs}h {mins}m")
    } else if hrs > 0 {
        format!("{hrs}h {mins}m")
    } else if mins > 0 {
        format!("{mins}m {rem}s")
    } else {
        format!("{rem}s")
    }
}

fn status_badge(on: bool) -> &'static str {
    if on { "[ON]" } else { "[OFF]" }
}

fn unique_id(prefix: &str, existing: &[String]) -> String {
    let ts = unix_now_secs();
    let base = format!("{prefix}_{ts}");
    if !existing.iter().any(|x| x == &base) {
        return base;
    }
    for i in 1..1000usize {
        let cand = format!("{base}_{i}");
        if !existing.iter().any(|x| x == &cand) {
            return cand;
        }
    }
    format!("{base}_x")
}

fn sanitize_url_host(url: &str) -> String {
    let trimmed = url.trim();
    let no_scheme = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))
        .unwrap_or(trimmed);
    let host = no_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("subscription");
    if host.is_empty() {
        "subscription".to_string()
    } else {
        host.to_string()
    }
}

fn count_conntrack_entries() -> usize {
    for p in ["/proc/net/nf_conntrack", "/proc/net/ip_conntrack"] {
        if let Ok(raw) = std::fs::read_to_string(p) {
            return raw.lines().filter(|l| !l.trim().is_empty()).count();
        }
    }
    0
}

// =========================================================================
// 1. Main Menu
// =========================================================================

async fn render_main_menu(state: &Arc<AppState>) -> BotReply {
    state.touch_telemetry_access();
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);
    let sys = collect_host_info();
    let cpu = sample_cpu_load_percent();

    let sec_on = d.sections.iter().filter(|s| s.enabled).count();
    let src_on = d.outbound_sources.iter().filter(|s| s.enabled).count();
    let srv_on = d.servers.iter().filter(|s| s.enabled).count();
    let core_ver = if live.core_version.is_empty() {
        "-"
    } else {
        live.core_version.as_str()
    };

    let text = format!(
        "<b>{}</b>\n\
         <pre>{}: {} ({})\n\
         {}: {} | CPU: {}%\n\
         RAM: {}/{} MB | {}: {}\n\
         {}: {}/{} | {}: {}/{} | {}: {}/{}</pre>",
        tr(
            ru,
            "Tachyon Router — Панель управления",
            "Tachyon Router — Control Panel"
        ),
        tr(ru, "Ядро", "Core"),
        status_badge(live.core_running),
        escape_html(core_ver),
        tr(ru, "Аптайм", "Uptime"),
        fmt_duration(if live.core_running {
            live.core_uptime_secs
        } else {
            sys.host_uptime_secs
        }),
        cpu,
        sys.memory_used_mb,
        sys.memory_total_mb,
        tr(ru, "Сессии", "Sessions"),
        live.active_connections,
        tr(ru, "Секции", "Sections"),
        sec_on,
        d.sections.len(),
        tr(ru, "Источники", "Sources"),
        src_on,
        d.outbound_sources.len(),
        tr(ru, "Серверы", "Servers"),
        srv_on,
        d.servers.len(),
    );

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Система и ядро", "System & Core"), "/core"),
            cb_btn(tr(ru, "Секции маршрутов", "Routing Sections"), "/sections"),
        ],
        vec![
            cb_btn(tr(ru, "Источники и узлы", "Sources & Nodes"), "/sources"),
            cb_btn(tr(ru, "VPN-серверы", "VPN Servers"), "/servers"),
        ],
        vec![
            cb_btn(tr(ru, "Устройства LAN", "LAN Devices"), "/devices"),
            cb_btn(tr(ru, "Родители", "Parental"), "/parental"),
        ],
        vec![
            cb_btn(tr(ru, "Гостевой Wi-Fi", "Guest Wi-Fi"), "/guest"),
            cb_btn(tr(ru, "Расписание", "Schedules"), "/schedules"),
        ],
        vec![
            cb_btn(tr(ru, "Диагностика", "Doctor"), "/doctor"),
            cb_btn(tr(ru, "Трассировка", "Trace Route"), "/trace"),
        ],
        vec![
            cb_btn(tr(ru, "Подбор Desync", "Desync Fuzzer"), "/fuzzer"),
            cb_btn(tr(ru, "Обновления", "Updates"), "/updates"),
        ],
        vec![
            cb_btn(tr(ru, "Роутеры", "Routers"), "/routers"),
            cb_btn(tr(ru, "Переключатели", "Quick Toggles"), "bot_toggles_menu"),
        ],
        vec![
            cb_btn(tr(ru, "Настройки бота", "Bot Settings"), "/bot_settings"),
            cb_btn(tr(ru, "Ping узлов", "Ping Nodes"), "/ping"),
        ],
        vec![cb_btn(
            tr(ru, "Перезапуск ядра", "Reload Core"),
            "sys_reload",
        )],
    ]);

    BotReply::with_kb(text, kb)
}

// =========================================================================
// 2. System & Core
// =========================================================================

async fn handle_sys_toggle(
    field: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let mut need_reload = false;
    let label = match field {
        "wd" => {
            candidate.settings.enable_watchdog = !candidate.settings.enable_watchdog;
            format!(
                "Watchdog -> {}",
                status_badge(candidate.settings.enable_watchdog)
            )
        }
        "sqm" => {
            candidate.settings.smart_queue = !candidate.settings.smart_queue;
            need_reload = true;
            format!("SQM -> {}", status_badge(candidate.settings.smart_queue))
        }
        "fakeip" => {
            candidate.settings.fakeip_enabled = !candidate.settings.fakeip_enabled;
            need_reload = true;
            format!(
                "FakeIP -> {}",
                status_badge(candidate.settings.fakeip_enabled)
            )
        }
        _ => String::new(),
    };
    let res = if need_reload {
        Box::pin(commit_and_reload(state, core, candidate)).await
    } else {
        commit_and_sync_tg_tx(state, candidate).await
    };
    let note = match res {
        Ok(()) => format!("[OK] {label}"),
        Err(e) => format!(
            "[ERR] {}: {}",
            tr(ru, "Ошибка сохранения", "Save failed"),
            escape_html(&e.to_string())
        ),
    };
    render_system_status(state, Some(note)).await
}

async fn render_system_status(state: &Arc<AppState>, notice: Option<String>) -> BotReply {
    state.touch_telemetry_access();
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);

    let sys = collect_host_info();
    let dnsmasq = collect_dnsmasq_status();
    let cpu = sample_cpu_load_percent();
    let (lan_ip, wan_ip) = detect_router_ips();
    let conntrack_cnt = count_conntrack_entries();

    let self_pid = std::process::id();
    let self_rss = if sys.panel_rss_bytes > 0 {
        sys.panel_rss_bytes
    } else {
        process_rss_bytes(self_pid)
    };
    let self_fds = count_open_fds(None);
    let self_up = daemon_uptime_secs();

    let core_pid = live.core_pid.unwrap_or(0);
    let core_rss = if core_pid > 0 {
        let r = process_rss_bytes(core_pid);
        if r > 0 { r } else { live.core_rss_bytes }
    } else {
        live.core_rss_bytes
    };
    let core_fds = if core_pid > 0 {
        count_open_fds(Some(core_pid))
    } else {
        0
    };
    let core_ver = if live.core_version.is_empty() {
        "-"
    } else {
        live.core_version.as_str()
    };

    let zram_used_mb = sys.zram_used_bytes / (1024 * 1024);
    let zram_total_mb = sys.zram_total_bytes / (1024 * 1024);
    let temp_str = if sys.cpu_temp_c > 0.5 {
        format!("{:.1} C", sys.cpu_temp_c)
    } else {
        "-".to_string()
    };

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b>",
        tr(ru, "Система и процессы", "System & Core Status")
    ));
    lines.push(format!(
        "<pre>tachyon      : [ON] PID {} | RSS {} | FD {} | {}\n\
         tachyon-core : {} PID {} | v{} | RSS {} | FD {} | {}\n\
         dnsmasq      : {} PID {} | RSS {} MB</pre>",
        self_pid,
        fmt_bytes(self_rss),
        self_fds,
        fmt_duration(self_up),
        status_badge(live.core_running),
        core_pid,
        escape_html(core_ver),
        fmt_bytes(core_rss),
        core_fds,
        fmt_duration(live.core_uptime_secs),
        status_badge(dnsmasq.running),
        dnsmasq.pid,
        dnsmasq.memory_rss_mb,
    ));
    lines.push(format!(
        "<pre>CPU: {}% | Temp: {} | Load: {}\n\
         RAM: {}/{} MB | ZRAM/Swap: {}/{} MB\n\
         LAN: {} | WAN: {}\n\
         {}: {} | Conntrack: {}\n\
         TX: {} ({}) | RX: {} ({})</pre>",
        cpu,
        temp_str,
        escape_html(&sys.load_avg),
        sys.memory_used_mb,
        sys.memory_total_mb,
        zram_used_mb,
        zram_total_mb,
        escape_html(&lan_ip),
        escape_html(&wan_ip),
        tr(ru, "Сессии", "Sessions"),
        live.active_connections,
        conntrack_cnt,
        fmt_bytes(live.total_up_bytes),
        fmt_bps(live.total_up_bps),
        fmt_bytes(live.total_down_bytes),
        fmt_bps(live.total_down_bps),
    ));

    let kb = inline_kb(vec![
        vec![
            cb_btn(tr(ru, "Запустить", "Start"), "sys_start"),
            cb_btn(tr(ru, "Остановить", "Stop"), "sys_stop"),
            cb_btn(tr(ru, "Перезапуск", "Reload"), "sys_reload"),
        ],
        vec![
            cb_btn(tr(ru, "Сжать RAM", "Trim RAM"), "sys_trim"),
            cb_btn(tr(ru, "Закрыть сессии", "Close Conns"), "sys_close_conns"),
        ],
        vec![
            cb_btn(
                &format!("Watchdog {}", status_badge(d.settings.enable_watchdog)),
                "sys_toggle_wd",
            ),
            cb_btn(
                &format!("SQM {}", status_badge(d.settings.smart_queue)),
                "sys_toggle_sqm",
            ),
        ],
        vec![
            cb_btn(
                &format!("FakeIP {}", status_badge(d.settings.fakeip_enabled)),
                "sys_toggle_fakeip",
            ),
            cb_btn(tr(ru, "Обновить", "Refresh"), "/core"),
        ],
        vec![cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu")],
    ]);

    BotReply::with_kb(lines.join("\n"), kb)
}

// =========================================================================
// 3. Routing Sections & Rules
// =========================================================================

fn section_display_name(sec: &RoutingSection) -> &str {
    if sec.label.trim().is_empty() {
        sec.id.as_str()
    } else {
        sec.label.trim()
    }
}

fn collect_section_lists(d: &RouterStoreData, sec: &RoutingSection) -> Vec<String> {
    let mut lists = Vec::new();
    for item in &sec.community_lists {
        let clean = item.trim().to_string();
        if !clean.is_empty() && !lists.contains(&clean) {
            lists.push(clean);
        }
    }
    for cref in &sec.condition_refs {
        if let Some(cond) = d.conditions.iter().find(|c| &c.id == cref) {
            for item in &cond.community_lists {
                let clean = item.trim().to_string();
                if !clean.is_empty() && !lists.contains(&clean) {
                    lists.push(clean);
                }
            }
        }
    }
    lists
}

fn collect_section_domains(d: &RouterStoreData, sec: &RoutingSection) -> Vec<String> {
    let mut doms = Vec::new();
    for item in sec.domains.iter().chain(sec.user_domains.iter()) {
        let clean = item.trim().to_string();
        if !clean.is_empty() && !doms.contains(&clean) {
            doms.push(clean);
        }
    }
    for cref in &sec.condition_refs {
        if let Some(cond) = d.conditions.iter().find(|c| &c.id == cref) {
            for item in cond.domains.iter().chain(cond.user_domains.iter()) {
                let clean = item.trim().to_string();
                if !clean.is_empty() && !doms.contains(&clean) {
                    doms.push(clean);
                }
            }
        }
    }
    doms
}

async fn render_sections_list(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let (safe_page, total_pages, start, end) = paginate(d.sections.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({}/{})",
        tr(ru, "Секции маршрутизации", "Routing Sections"),
        d.sections.iter().filter(|s| s.enabled).count(),
        d.sections.len()
    ));

    let mut rows = Vec::new();
    if d.sections.is_empty() {
        lines.push(tr(ru, "Секций пока нет.", "No routing sections configured.").to_string());
    } else {
        for (offset, sec) in d.sections[start..end].iter().enumerate() {
            let idx = start + offset + 1;
            let dom_cnt = collect_section_domains(&d, sec).len();
            let list_cnt = collect_section_lists(&d, sec).len();
            let active = if !sec.active_selected_tag.is_empty() {
                sec.active_selected_tag.as_str()
            } else if sec.connection_type == "desync" && !sec.desync_preset.is_empty() {
                sec.desync_preset.as_str()
            } else {
                "-"
            };
            lines.push(format!(
                "#{idx} {} <b>{}</b> | <code>{}</code> | {} | L:{} D:{}",
                status_badge(sec.enabled),
                escape_html(section_display_name(sec)),
                escape_html(&sec.connection_type),
                escape_html(active),
                list_cnt,
                dom_cnt
            ));
            let btn_lbl = format!(
                "#{} {} {}",
                idx,
                status_badge(sec.enabled),
                truncate_label(section_display_name(sec), 20)
            );
            rows.push(vec![
                cb_btn(&btn_lbl, &format!("sec_view {}", sec.id)),
                cb_btn(
                    if sec.enabled { "OFF" } else { "ON" },
                    &format!("sec_tog {}", sec.id),
                ),
            ]);
        }
    }

    add_pagination_row(&mut rows, "sec_list", safe_page, total_pages);
    rows.push(vec![
        cb_btn(
            tr(ru, "Обновить", "Refresh"),
            &format!("sec_list {safe_page}"),
        ),
        cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_fptn_shortcut(state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    if let Some(sec) = d.sections.iter().find(|s| s.connection_type == "fptn") {
        let sec_id = sec.id.clone();
        drop(d);
        return render_section_view_no_core(state, &sec_id, None).await;
    }
    if let Some(src) = d.outbound_sources.iter().find(|s| s.source_type == "fptn") {
        let src_id = src.id.clone();
        drop(d);
        return render_source_view(state, &src_id, 0, None).await;
    }
    let ru = is_ru(&d);
    let note = tr(
        ru,
        "[!] Секция с режимом fptn не найдена. Откройте нужную секцию и переключите режим на fptn.",
        "[!] No section in fptn mode found. Open a section and switch mode to fptn.",
    )
    .to_string();
    render_sections_list(state, 0, Some(note)).await
}

async fn render_section_view_no_core(
    state: &Arc<AppState>,
    sec_id: &str,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    render_section_view_inner(&d, &live, None, sec_id, notice)
}

async fn render_section_view(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    sec_id: &str,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let clash_proxies = if live.core_running {
        Box::pin(core.clash_request("GET", "/proxies", None))
            .await
            .ok()
    } else {
        None
    };
    render_section_view_inner(&d, &live, clash_proxies.as_ref(), sec_id, notice)
}

fn render_section_view_inner(
    d: &RouterStoreData,
    live: &LiveTelemetry,
    clash_proxies: Option<&Value>,
    sec_id: &str,
    notice: Option<String>,
) -> BotReply {
    let ru = is_ru(d);
    let Some(pos) = d.sections.iter().position(|s| s.id == sec_id) else {
        let kb = inline_kb(vec![vec![cb_btn(
            tr(ru, "<- Секции", "<- Sections"),
            "sec_list 0",
        )]]);
        return BotReply::with_kb(
            tr(ru, "[ERR] Секция не найдена", "[ERR] Section not found"),
            kb,
        );
    };
    let sec = &d.sections[pos];
    let lists = collect_section_lists(d, sec);
    let doms = collect_section_domains(d, sec);
    let outbounds = resolve_section_outbounds(d, sec, clash_proxies);

    let mut active_tag = sec.active_selected_tag.clone();
    if active_tag.is_empty()
        && let Some(px) = clash_proxies
        && let Some(now_tag) = px
            .pointer(&format!("/proxies/sel-{}/now", sec.id))
            .and_then(Value::as_str)
    {
        active_tag = now_tag.to_string();
    }
    if active_tag.is_empty() && outbounds.len() == 1 {
        active_tag = outbounds[0].clone();
    }

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{} #{} — {}</b>",
        tr(ru, "Секция", "Section"),
        pos + 1,
        escape_html(section_display_name(sec))
    ));
    lines.push(format!(
        "ID: <code>{}</code> | {} | {}: <code>{}</code>",
        escape_html(&sec.id),
        status_badge(sec.enabled),
        tr(ru, "Режим", "Mode"),
        escape_html(&sec.connection_type)
    ));
    if !active_tag.is_empty() {
        let rtt = live
            .node_latencies_ms
            .get(&active_tag)
            .map(|ms| format!(" ({ms} ms)"))
            .unwrap_or_default();
        lines.push(format!(
            "{}: <code>{}</code>{}",
            tr(ru, "Активный узел", "Active node"),
            escape_html(&active_tag),
            rtt
        ));
    }
    if sec.connection_type == "desync" {
        lines.push(format!(
            "Desync: <code>{}</code> | auto_tune: {} | SNI: <code>{}</code>",
            escape_html(if sec.desync_preset.is_empty() {
                "adaptive"
            } else {
                &sec.desync_preset
            }),
            status_badge(sec.desync_auto_tune),
            escape_html(if sec.desync_fake_sni.is_empty() {
                "default"
            } else {
                &sec.desync_fake_sni
            })
        ));
    }
    if sec.connection_type == "fptn" {
        let token_state = if sec.fptn_access_token.trim().is_empty() {
            tr(ru, "[не задан]", "[not set]").to_string()
        } else if let Some(dec) = decode_fptn_token_json_with_core_bin(
            &sec.fptn_access_token,
            Some(&d.settings.core_bin_path),
        ) {
            let srv_cnt = count_fptn_token_servers(&dec);
            format!("[OK] ({srv_cnt} {})", tr(ru, "серв.", "servers"))
        } else {
            "[configured]".to_string()
        };
        lines.push(format!("FPTN Token: {token_state}"));
    }

    lines.push(format!(
        "{} ({}): {}",
        tr(ru, "Списки", "Lists"),
        lists.len(),
        if lists.is_empty() {
            "-".to_string()
        } else {
            escape_html(&preview_list(&lists, 6))
        }
    ));
    lines.push(format!(
        "{} ({}): {}",
        tr(ru, "Домены", "Domains"),
        doms.len(),
        if doms.is_empty() {
            "-".to_string()
        } else {
            escape_html(&preview_list(&doms, 5))
        }
    ));
    lines.push(format!(
        "{}: LAN={} | CIDR={}",
        tr(ru, "IP/Подсети", "IP/CIDR"),
        sec.fully_routed_ips.len(),
        sec.user_subnets.len()
    ));

    let mut rows = vec![
        vec![
            cb_btn(
                if sec.enabled {
                    tr(ru, "Выключить", "Disable")
                } else {
                    tr(ru, "Включить", "Enable")
                },
                &format!("sec_tog {}", sec.id),
            ),
            cb_btn(tr(ru, "Вверх", "Up"), &format!("sec_up {}", sec.id)),
            cb_btn(tr(ru, "Вниз", "Down"), &format!("sec_dn {}", sec.id)),
        ],
        vec![
            cb_btn(
                &format!("{}: {}", tr(ru, "Режим", "Mode"), sec.connection_type),
                &format!("sec_modes {}", sec.id),
            ),
            cb_btn(
                &format!("{} ({})", tr(ru, "Узлы", "Nodes"), outbounds.len()),
                &format!("sec_nodes {} 0", sec.id),
            ),
        ],
    ];

    if sec.connection_type == "desync" {
        rows.push(vec![cb_btn(
            &format!(
                "Desync: {}",
                if sec.desync_preset.is_empty() {
                    "adaptive"
                } else {
                    &sec.desync_preset
                }
            ),
            &format!("sec_desyncs {}", sec.id),
        )]);
    }
    if sec.connection_type == "fptn" {
        rows.push(vec![cb_btn(
            tr(ru, "Обновить FPTN токен", "Update FPTN Token"),
            &format!("sec_fptn {}", sec.id),
        )]);
    }

    rows.push(vec![
        cb_btn(
            &format!(
                "{} ({})",
                tr(ru, "Списки сервисов", "Service Lists"),
                lists.len()
            ),
            &format!("sec_lists {} 0", sec.id),
        ),
        cb_btn(
            &format!(
                "{} ({})",
                tr(ru, "Условия", "Conditions"),
                sec.condition_refs.len()
            ),
            &format!("sec_conds {} 0", sec.id),
        ),
    ]);
    rows.push(vec![
        cb_btn(
            tr(ru, "+ Домен", "+ Domain"),
            &format!("sec_add_dom {}", sec.id),
        ),
        cb_btn(
            tr(ru, "- Домен", "- Domain"),
            &format!("sec_rm_dom {}", sec.id),
        ),
        cb_btn(
            tr(ru, "+ IP/CIDR", "+ IP/CIDR"),
            &format!("sec_add_ip {}", sec.id),
        ),
    ]);
    rows.push(vec![
        cb_btn(tr(ru, "<- Секции", "<- Sections"), "sec_list 0"),
        cb_btn(tr(ru, "Меню", "Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_sec_toggle(
    sec_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == sec_id) else {
        return render_sections_list(
            state,
            0,
            Some(tr(ru, "[ERR] Секция не найдена", "[ERR] Section not found").to_string()),
        )
        .await;
    };
    sec.enabled = !sec.enabled;
    let enabled_now = sec.enabled;
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} -> {}",
            escape_html(sec_id),
            status_badge(enabled_now)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

async fn handle_sec_move(
    sec_id: &str,
    delta: isize,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    if let Some(idx) = candidate.sections.iter().position(|s| s.id == sec_id) {
        let max_idx = candidate.sections.len().saturating_sub(1) as isize;
        let target = (idx as isize + delta).clamp(0, max_idx) as usize;
        if target != idx {
            let item = candidate.sections.remove(idx);
            candidate.sections.insert(target, item);
            let note = match commit_and_reload(state, core, candidate).await {
                Ok(()) => format!(
                    "[OK] {}: #{} -> #{}",
                    tr(ru, "Приоритет", "Priority"),
                    idx + 1,
                    target + 1
                ),
                Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
            };
            return render_section_view(state, core, sec_id, Some(note)).await;
        }
        return render_section_view(
            state,
            core,
            sec_id,
            Some(tr(ru, "Уже на краю списка", "Already at boundary").to_string()),
        )
        .await;
    }
    render_sections_list(
        state,
        0,
        Some(tr(ru, "[ERR] Секция не найдена", "[ERR] Section not found").to_string()),
    )
    .await
}

async fn render_section_modes(state: &Arc<AppState>, sec_id: &str) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(sec) = d.sections.iter().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };

    let mut rows = Vec::new();
    for chunk in SECTION_MODES.chunks(2) {
        let row = chunk
            .iter()
            .map(|&mode| {
                let mark = if sec.connection_type == mode {
                    "* "
                } else {
                    ""
                };
                cb_btn(
                    &format!("{mark}{mode}"),
                    &format!("sec_mode {} {mode}", sec.id),
                )
            })
            .collect();
        rows.push(row);
    }
    rows.push(vec![cb_btn(
        tr(ru, "<- Назад", "<- Back"),
        &format!("sec_view {}", sec.id),
    )]);

    BotReply::with_kb(
        format!(
            "<b>{}</b>: {}",
            tr(ru, "Режим секции", "Section Mode"),
            escape_html(section_display_name(sec))
        ),
        inline_kb(rows),
    )
}

async fn handle_sec_mode(
    sec_id: &str,
    mode: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let ru_init = current_is_ru(state).await;
    if !SECTION_MODES.contains(&mode) {
        return render_section_view(
            state,
            core,
            sec_id,
            Some(tr(ru_init, "[ERR] Неизвестный режим", "[ERR] Unknown mode").to_string()),
        )
        .await;
    }
    let mut candidate = state.data.read().await.clone();
    let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };
    sec.connection_type = mode.to_string();
    sec.action = mode.to_string();
    if mode == "desync" && sec.desync_preset.trim().is_empty() {
        sec.desync_preset = "adaptive".to_string();
        sec.desync_auto_tune = true;
    }
    let note = match commit_and_reload_with_warning(state, core, candidate).await {
        Ok(warn) => format!(
            "[OK] {} -> <code>{mode}</code>{}",
            tr(ru_init, "Режим", "Mode"),
            format_reload_warn(warn)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

fn url_encode_proxy_tag(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for b in raw.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char);
            }
            _ => {
                use std::fmt::Write as _;
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
    out
}

fn candidate_section_group_tags(
    sec: &RoutingSection,
    clash_proxies: Option<&Value>,
) -> Vec<String> {
    let mut candidates = Vec::new();
    for bal_id in &sec.balancer_refs {
        let tag = format!("bal-{}-{bal_id}", sec.id);
        if !candidates.contains(&tag) {
            candidates.push(tag);
        }
    }
    if let Some(map) = clash_proxies
        .and_then(|v| v.get("proxies"))
        .and_then(Value::as_object)
    {
        let prefix = format!("bal-{}-", sec.id);
        let mut matched: Vec<String> = map
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        matched.sort();
        for tag in matched {
            if !candidates.contains(&tag) {
                candidates.push(tag);
            }
        }
    }
    for tag in [
        format!("sel-{}", sec.id),
        format!("{}-out", sec.id),
        sec.id.clone(),
    ] {
        if !candidates.contains(&tag) {
            candidates.push(tag);
        }
    }
    candidates
}

fn resolve_section_outbounds(
    d: &RouterStoreData,
    sec: &RoutingSection,
    clash_proxies: Option<&Value>,
) -> Vec<String> {
    let mut tags = Vec::new();
    let sel_name = format!("sel-{}", sec.id);
    let group_candidates = candidate_section_group_tags(sec, clash_proxies);

    if let Some(px_map) = clash_proxies
        .and_then(|v| v.get("proxies"))
        .and_then(Value::as_object)
    {
        for group_tag in &group_candidates {
            if let Some(arr) = px_map
                .get(group_tag)
                .and_then(|g| g.get("all"))
                .and_then(Value::as_array)
            {
                for item in arr.iter().filter_map(Value::as_str) {
                    if !tags.iter().any(|t| t == item) {
                        tags.push(item.to_string());
                    }
                }
            }
        }
    }

    if let Ok(cfg) = compile_core_config(d)
        && let Some(outbounds) = cfg.get("outbounds").and_then(Value::as_array)
    {
        for ob in outbounds {
            let tag = ob.get("tag").and_then(Value::as_str).unwrap_or("");
            if (tag == sel_name
                || tag == format!("{}-out", sec.id)
                || tag == sec.id
                || tag.starts_with(&format!("bal-{}-", sec.id)))
                && let Some(arr) = ob.get("outbounds").and_then(Value::as_array)
            {
                if tag.starts_with(&format!("bal-{}-", sec.id)) && !tags.iter().any(|t| t == tag) {
                    tags.push(tag.to_string());
                }
                for m in arr.iter().filter_map(Value::as_str) {
                    if !tags.iter().any(|t| t == m) {
                        tags.push(m.to_string());
                    }
                }
            }
        }
    }

    for sref in &sec.outbound_source_refs {
        if let Some(src) = d
            .outbound_sources
            .iter()
            .find(|s| &s.id == sref && s.enabled)
        {
            for n in &src.cached_nodes {
                if !tags.contains(&n.tag) {
                    tags.push(n.tag.clone());
                }
            }
            for (idx, link) in src.proxy_links.iter().enumerate() {
                if let Some(n) = parse_proxy_uri(link, idx)
                    && !tags.contains(&n.tag)
                {
                    tags.push(n.tag);
                }
            }
        }
    }

    for bal_id in &sec.balancer_refs {
        let bal_tag = format!("bal-{}-{bal_id}", sec.id);
        if !tags.contains(&bal_tag) {
            tags.push(bal_tag);
        }
    }

    tags
}

async fn render_section_nodes(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    sec_id: &str,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);
    let Some(sec) = d.sections.iter().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };
    let clash_proxies = if live.core_running {
        Box::pin(core.clash_request("GET", "/proxies", None))
            .await
            .ok()
    } else {
        None
    };
    let nodes = resolve_section_outbounds(&d, sec, clash_proxies.as_ref());
    let mut active = sec.active_selected_tag.clone();
    if let Some(px_map) = clash_proxies
        .as_ref()
        .and_then(|v| v.get("proxies"))
        .and_then(Value::as_object)
    {
        for group_tag in candidate_section_group_tags(sec, clash_proxies.as_ref()) {
            if let Some(now_tag) = px_map
                .get(&group_tag)
                .and_then(|g| g.get("now"))
                .and_then(Value::as_str)
                && !now_tag.is_empty()
            {
                active = now_tag.to_string();
                break;
            }
        }
    }

    let (safe_page, total_pages, start, end) = paginate(nodes.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> — {}",
        tr(ru, "Узлы секции", "Section Nodes"),
        escape_html(section_display_name(sec))
    ));
    if !active.is_empty() {
        lines.push(format!(
            "{}: <code>{}</code>",
            tr(ru, "Выбран", "Selected"),
            escape_html(&active)
        ));
    }

    let mut rows = Vec::new();
    if nodes.is_empty() {
        lines.push(
            tr(
                ru,
                "Для секции не назначены узлы или источники.",
                "No outbound nodes or balancers assigned to this section.",
            )
            .to_string(),
        );
    } else {
        for tag in &nodes[start..end] {
            let is_cur = active == *tag;
            let lat = live
                .node_latencies_ms
                .get(tag)
                .map(|ms| format!(" ({ms} ms)"))
                .unwrap_or_default();
            let prefix = if is_cur { "[*] " } else { "" };
            lines.push(format!("{prefix}<code>{}</code>{lat}", escape_html(tag)));
            rows.push(vec![cb_btn(
                &format!("{prefix}{}{lat}", truncate_label(tag, 26)),
                &format!("sec_pick {} {tag}", sec.id),
            )]);
        }
    }

    add_pagination_row(
        &mut rows,
        &format!("sec_nodes {}", sec.id),
        safe_page,
        total_pages,
    );
    rows.push(vec![
        cb_btn(tr(ru, "Ping узлов", "Ping All"), "src_ping"),
        cb_btn(
            tr(ru, "<- Секция", "<- Section"),
            &format!("sec_view {}", sec.id),
        ),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_sec_pick(
    sec_id: &str,
    tag: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let ru = current_is_ru(state).await;
    let sec_opt = state
        .data
        .read()
        .await
        .sections
        .iter()
        .find(|s| s.id == sec_id)
        .cloned();
    let note = match Box::pin(core.select_section_node(sec_id, tag)).await {
        Ok(()) => {
            if let Some(sec) = sec_opt {
                let clash_proxies = Box::pin(core.clash_request("GET", "/proxies", None))
                    .await
                    .ok();
                let payload = serde_json::json!({ "name": tag }).to_string();
                let candidates = candidate_section_group_tags(&sec, clash_proxies.as_ref());
                let mut switched_via_group = false;
                for group_tag in candidates {
                    if let Some(px_map) = clash_proxies
                        .as_ref()
                        .and_then(|v| v.get("proxies"))
                        .and_then(Value::as_object)
                        && !px_map.contains_key(&group_tag)
                    {
                        continue;
                    }
                    let encoded = url_encode_proxy_tag(&group_tag);
                    if Box::pin(core.clash_request(
                        "PUT",
                        &format!("/proxies/{encoded}"),
                        Some(&payload),
                    ))
                    .await
                    .is_ok()
                    {
                        switched_via_group = true;
                        break;
                    }
                }
                let _ = switched_via_group;
            }
            format!(
                "[OK] {} -> <code>{}</code>",
                tr(ru, "Узел выбран", "Selected node"),
                escape_html(tag)
            )
        }
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_nodes(state, core, sec_id, 0, Some(note)).await
}

async fn render_section_desyncs(state: &Arc<AppState>, sec_id: &str) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(sec) = d.sections.iter().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };

    let mut rows = Vec::new();
    for &(key, label_ru, label_en) in DESYNC_PRESETS {
        let cur = sec.desync_preset == key
            || (key == "adaptive" && (sec.desync_preset.is_empty() || sec.desync_preset == "auto"));
        let mark = if cur { "[*] " } else { "" };
        rows.push(vec![cb_btn(
            &format!("{mark}{} ({key})", tr(ru, label_ru, label_en)),
            &format!("sec_desync {} {key}", sec.id),
        )]);
    }
    rows.push(vec![cb_btn(
        tr(ru, "<- Назад", "<- Back"),
        &format!("sec_view {}", sec.id),
    )]);

    BotReply::with_kb(
        format!(
            "<b>{}</b> — {}",
            tr(ru, "Пресет Desync", "Desync Preset"),
            escape_html(section_display_name(sec))
        ),
        inline_kb(rows),
    )
}

async fn handle_sec_desync(
    sec_id: &str,
    preset: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };
    sec.connection_type = "desync".to_string();
    sec.action = "desync".to_string();
    sec.desync_preset = preset.to_string();
    sec.desync_auto_tune = preset == "adaptive" || preset == "auto";
    sec.desync_opts.clear();
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} -> <code>{}</code>",
            tr(ru, "Пресет Desync", "Desync preset"),
            escape_html(preset)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

async fn render_section_conditions(
    state: &Arc<AppState>,
    sec_id: &str,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(sec) = d.sections.iter().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };
    let linked: Vec<_> = sec
        .condition_refs
        .iter()
        .filter_map(|cid| d.conditions.iter().find(|c| &c.id == cid))
        .collect();

    let (safe_page, total_pages, start, end) = paginate(linked.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> — {}",
        tr(ru, "Условия секции", "Section Conditions"),
        escape_html(section_display_name(sec))
    ));

    let mut rows = Vec::new();
    if linked.is_empty() {
        lines.push(
            tr(
                ru,
                "Привязанных условий нет (используются прямые списки и домены секции).",
                "No linked conditions (section uses inline lists and domains).",
            )
            .to_string(),
        );
    } else {
        for cond in &linked[start..end] {
            let cname = if cond.name.trim().is_empty() {
                cond.id.as_str()
            } else {
                cond.name.trim()
            };
            lines.push(format!(
                "{} <b>{}</b> (<code>{}</code>) | L:{} D:{} IP:{}",
                status_badge(cond.enabled),
                escape_html(cname),
                escape_html(&cond.condition_type),
                cond.community_lists.len(),
                cond.domains.len() + cond.user_domains.len(),
                cond.user_subnets.len()
            ));
            rows.push(vec![cb_btn(
                &format!(
                    "{} {}",
                    status_badge(cond.enabled),
                    truncate_label(cname, 24)
                ),
                &format!("sec_cond_tog {} {}", sec.id, cond.id),
            )]);
        }
    }

    add_pagination_row(
        &mut rows,
        &format!("sec_conds {}", sec.id),
        safe_page,
        total_pages,
    );
    rows.push(vec![
        cb_btn(
            tr(ru, "Списки сервисов", "Service Lists"),
            &format!("sec_lists {} 0", sec.id),
        ),
        cb_btn(
            tr(ru, "<- Секция", "<- Section"),
            &format!("sec_view {}", sec.id),
        ),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_sec_cond_toggle(
    sec_id: &str,
    cond_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(cond) = candidate.conditions.iter_mut().find(|c| c.id == cond_id) else {
        return render_section_conditions(
            state,
            sec_id,
            0,
            Some(tr(ru, "[ERR] Условие не найдено", "[ERR] Condition not found").to_string()),
        )
        .await;
    };
    cond.enabled = !cond.enabled;
    let enabled_now = cond.enabled;
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} -> {}",
            escape_html(cond_id),
            status_badge(enabled_now)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_conditions(state, sec_id, 0, Some(note)).await
}

async fn render_section_lists(
    state: &Arc<AppState>,
    sec_id: &str,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(sec) = d.sections.iter().find(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };

    let active_lists = collect_section_lists(&d, sec);
    let mut catalog: Vec<String> = COMMUNITY_LIST_CATALOG
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    for existing in &active_lists {
        if !catalog.contains(existing) {
            catalog.push(existing.clone());
        }
    }

    let (safe_page, total_pages, start, end) = paginate(catalog.len(), page, LISTS_PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> — {}",
        tr(ru, "Списки сервисов", "Service Lists"),
        escape_html(section_display_name(sec))
    ));
    lines.push(format!(
        "{}: {}",
        tr(ru, "Активны", "Active"),
        if active_lists.is_empty() {
            "-".to_string()
        } else {
            escape_html(&active_lists.join(", "))
        }
    ));

    let mut rows = Vec::new();
    for chunk in catalog[start..end].chunks(2) {
        let row = chunk
            .iter()
            .map(|item| {
                let on = active_lists.contains(item);
                cb_btn(
                    &format!("{} {item}", status_badge(on)),
                    &format!("sec_list_tog {} {item}", sec.id),
                )
            })
            .collect();
        rows.push(row);
    }

    add_pagination_row(
        &mut rows,
        &format!("sec_lists {}", sec.id),
        safe_page,
        total_pages,
    );
    rows.push(vec![cb_btn(
        tr(ru, "<- Секция", "<- Section"),
        &format!("sec_view {}", sec.id),
    )]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_sec_list_toggle(
    sec_id: &str,
    list_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let clean = list_id.trim().to_string();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(sec_idx) = candidate.sections.iter().position(|s| s.id == sec_id) else {
        return render_sections_list(state, 0, None).await;
    };

    let cond_refs = candidate.sections[sec_idx].condition_refs.clone();
    let in_sec = candidate.sections[sec_idx].community_lists.contains(&clean);
    let in_cond = cond_refs.iter().any(|cid| {
        candidate
            .conditions
            .iter()
            .find(|c| &c.id == cid)
            .is_some_and(|c| c.community_lists.contains(&clean))
    });

    let added = !(in_sec || in_cond);
    if !added {
        candidate.sections[sec_idx]
            .community_lists
            .retain(|x| x != &clean);
        for cid in &cond_refs {
            if let Some(c) = candidate.conditions.iter_mut().find(|c| &c.id == cid) {
                c.community_lists.retain(|x| x != &clean);
            }
        }
    } else {
        if !candidate.sections[sec_idx].community_lists.contains(&clean) {
            candidate.sections[sec_idx]
                .community_lists
                .push(clean.clone());
        }
        if let Some(first_cid) = cond_refs.first()
            && let Some(c) = candidate.conditions.iter_mut().find(|c| &c.id == first_cid)
            && !c.community_lists.contains(&clean)
        {
            c.community_lists.push(clean.clone());
        }
    }

    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} <code>{}</code> -> {}",
            tr(ru, "Список", "List"),
            escape_html(&clean),
            status_badge(added)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    let page = COMMUNITY_LIST_CATALOG
        .iter()
        .position(|&x| x == clean)
        .map(|i| i / LISTS_PER_PAGE)
        .unwrap_or(0);
    render_section_lists(state, sec_id, page, Some(note)).await
}

enum SectionPromptMode {
    AddDomain,
    RemoveDomain,
    AddIp,
    UpdateFptn,
}

async fn prompt_section_input(
    chat_id: i64,
    state: &Arc<AppState>,
    sec_id: &str,
    mode: SectionPromptMode,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let sec_label = d
        .sections
        .iter()
        .find(|s| s.id == sec_id)
        .map(|s| escape_html(section_display_name(s)))
        .unwrap_or_else(|| escape_html(sec_id));

    let (kind, msg) = match mode {
        SectionPromptMode::AddDomain => (
            PendingPromptKind::AddDomainToSection {
                sec_id: sec_id.to_string(),
            },
            tr(
                ru,
                "Отправьте домен(ы) для добавления (через запятую или с новой строки, например: <code>example.com</code>).\nОтмена: /cancel",
                "Send domain(s) to add (comma or newline separated, e.g. <code>example.com</code>).\nCancel: /cancel",
            ),
        ),
        SectionPromptMode::RemoveDomain => (
            PendingPromptKind::RemoveDomainFromSection {
                sec_id: sec_id.to_string(),
            },
            tr(
                ru,
                "Отправьте домен(ы) для удаления из секции.\nОтмена: /cancel",
                "Send domain(s) to remove from this section.\nCancel: /cancel",
            ),
        ),
        SectionPromptMode::AddIp => (
            PendingPromptKind::AddIpToSection {
                sec_id: sec_id.to_string(),
            },
            tr(
                ru,
                "Отправьте IP/CIDR: частный IP (<code>192.168.1.50</code> или <code>lan:192.168.1.50</code>) для маршрутизации клиента, либо внешний IP/CIDR (<code>1.2.3.0/24</code> или <code>dst:8.8.8.8</code>) для адреса назначения.\nОтмена: /cancel",
                "Send IP/CIDR: private IP (<code>192.168.1.50</code> or <code>lan:192.168.1.50</code>) for client routing, or destination IP/CIDR (<code>1.2.3.0/24</code> or <code>dst:8.8.8.8</code>).\nCancel: /cancel",
            ),
        ),
        SectionPromptMode::UpdateFptn => (
            PendingPromptKind::UpdateFptnToken {
                sec_id: sec_id.to_string(),
            },
            tr(
                ru,
                "Отправьте новый токен доступа FPTN (<code>fptn://...</code>, <code>fptnb://...</code>, <code>fptn:...</code>, JSON или <code>.fptn</code>-файл).\nОтмена: /cancel",
                "Send the new FPTN access token (<code>fptn://...</code>, <code>fptnb://...</code>, <code>fptn:...</code>, JSON, or a <code>.fptn</code> file).\nCancel: /cancel",
            ),
        ),
    };

    set_chat_prompt(chat_id, kind);
    let kb = inline_kb(vec![vec![cb_btn(
        tr(ru, "Отмена", "Cancel"),
        &format!("sec_view {sec_id}"),
    )]]);
    BotReply::with_kb(format!("<b>{sec_label}</b>\n\n{msg}"), kb)
}

fn normalize_domain_token(raw: &str) -> Option<String> {
    let mut s = raw.trim().to_ascii_lowercase();
    if s.is_empty() {
        return None;
    }
    if let Some(rest) = s.strip_prefix("https://") {
        s = rest.to_string();
    } else if let Some(rest) = s.strip_prefix("http://") {
        s = rest.to_string();
    }
    if let Some((host, _)) = s.split_once('/') {
        s = host.to_string();
    }
    if let Some((host, _)) = s.split_once(':') {
        s = host.to_string();
    }
    let clean = s.trim_matches('.').trim().to_string();
    if clean.is_empty()
        || !clean.contains('.')
        || !clean
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
    {
        return None;
    }
    Some(clean)
}

async fn handle_add_domain_prompt(
    sec_id: &str,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let domains: Vec<String> = input
        .split([',', ';', '\n', '\r', ' '])
        .filter_map(normalize_domain_token)
        .collect();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    if domains.is_empty() {
        set_chat_prompt(
            chat_id,
            PendingPromptKind::AddDomainToSection {
                sec_id: sec_id.to_string(),
            },
        );
        return BotReply::text(tr(
            ru,
            "[!] Не найдено корректных доменов (пример: example.com). Повторите или отправьте /cancel.",
            "[!] No valid domain names found (e.g. example.com). Retry or send /cancel.",
        ));
    }

    let Some(sec_idx) = candidate.sections.iter().position(|s| s.id == sec_id) else {
        clear_chat_prompt(chat_id);
        return render_sections_list(state, 0, None).await;
    };

    let first_cond = candidate.sections[sec_idx].condition_refs.first().cloned();
    let mut added = 0usize;
    for dom in &domains {
        if !candidate.sections[sec_idx]
            .domains
            .iter()
            .chain(candidate.sections[sec_idx].user_domains.iter())
            .any(|d| d.eq_ignore_ascii_case(dom))
        {
            candidate.sections[sec_idx].user_domains.push(dom.clone());
            added += 1;
        }
        if let Some(ref cid) = first_cond
            && let Some(cond) = candidate.conditions.iter_mut().find(|c| &c.id == cid)
            && !cond.is_composite()
            && !cond
                .domains
                .iter()
                .chain(cond.user_domains.iter())
                .any(|d| d.eq_ignore_ascii_case(dom))
        {
            cond.user_domains.push(dom.clone());
        }
    }

    clear_chat_prompt(chat_id);
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {}: {added} ({})",
            tr(ru, "Добавлено доменов", "Added domains"),
            escape_html(&domains.join(", "))
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

async fn handle_remove_domain_prompt(
    sec_id: &str,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let domains: Vec<String> = input
        .split([',', ';', '\n', '\r', ' '])
        .filter_map(normalize_domain_token)
        .collect();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    if domains.is_empty() {
        set_chat_prompt(
            chat_id,
            PendingPromptKind::RemoveDomainFromSection {
                sec_id: sec_id.to_string(),
            },
        );
        return BotReply::text(tr(
            ru,
            "[!] Укажите домен (пример: example.com) или /cancel.",
            "[!] Specify a domain (e.g. example.com) or /cancel.",
        ));
    }

    let Some(sec_idx) = candidate.sections.iter().position(|s| s.id == sec_id) else {
        clear_chat_prompt(chat_id);
        return render_sections_list(state, 0, None).await;
    };

    let cond_refs = candidate.sections[sec_idx].condition_refs.clone();
    let mut removed = 0usize;
    let before =
        candidate.sections[sec_idx].domains.len() + candidate.sections[sec_idx].user_domains.len();
    candidate.sections[sec_idx]
        .domains
        .retain(|d| !domains.contains(&d.to_ascii_lowercase()));
    candidate.sections[sec_idx]
        .user_domains
        .retain(|d| !domains.contains(&d.to_ascii_lowercase()));
    let after =
        candidate.sections[sec_idx].domains.len() + candidate.sections[sec_idx].user_domains.len();
    removed += before.saturating_sub(after);

    for cid in &cond_refs {
        if let Some(cond) = candidate.conditions.iter_mut().find(|c| &c.id == cid) {
            let cb = cond.domains.len() + cond.user_domains.len();
            cond.domains
                .retain(|d| !domains.contains(&d.to_ascii_lowercase()));
            cond.user_domains
                .retain(|d| !domains.contains(&d.to_ascii_lowercase()));
            removed += cb.saturating_sub(cond.domains.len() + cond.user_domains.len());
        }
    }

    clear_chat_prompt(chat_id);
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {}: {removed}",
            tr(ru, "Удалено записей", "Removed entries")
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

fn parse_ip_or_cidr_token(raw: &str) -> Option<(bool, String)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let (explicit_lan, clean) = if let Some(rest) = trimmed.strip_prefix("lan:") {
        (Some(true), rest.trim())
    } else if let Some(rest) = trimmed.strip_prefix("src:") {
        (Some(true), rest.trim())
    } else if let Some(rest) = trimmed.strip_prefix("dst:") {
        (Some(false), rest.trim())
    } else {
        (None, trimmed)
    };

    let (ip_part, prefix_opt) = match clean.split_once('/') {
        Some((ip_s, p_s)) => (ip_s.trim(), Some(p_s.trim().parse::<u8>().ok()?)),
        None => (clean, None),
    };
    let addr: IpAddr = ip_part.parse().ok()?;
    let max_prefix = match addr {
        IpAddr::V4(_) => 32,
        IpAddr::V6(_) => 128,
    };
    if let Some(pfx) = prefix_opt
        && pfx > max_prefix
    {
        return None;
    }

    let is_lan = explicit_lan.unwrap_or_else(|| {
        prefix_opt.is_none()
            && match addr {
                IpAddr::V4(v4) => v4.is_private() || v4.is_link_local(),
                IpAddr::V6(v6) => v6.is_unique_local() || v6.is_unicast_link_local(),
            }
    });

    let normalized = match prefix_opt {
        Some(pfx) => format!("{addr}/{pfx}"),
        None if is_lan => addr.to_string(),
        None => format!("{addr}/{max_prefix}"),
    };
    Some((is_lan, normalized))
}

async fn handle_add_ip_prompt(
    sec_id: &str,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let tokens: Vec<(bool, String)> = input
        .split([',', ';', '\n', '\r', ' '])
        .filter_map(parse_ip_or_cidr_token)
        .collect();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    if tokens.is_empty() {
        set_chat_prompt(
            chat_id,
            PendingPromptKind::AddIpToSection {
                sec_id: sec_id.to_string(),
            },
        );
        return BotReply::text(tr(
            ru,
            "[!] Неверный IP/CIDR (пример: 192.168.1.50 или 1.2.3.0/24). Повторите или /cancel.",
            "[!] Invalid IP/CIDR (e.g. 192.168.1.50 or 1.2.3.0/24). Retry or /cancel.",
        ));
    }

    let Some(sec_idx) = candidate.sections.iter().position(|s| s.id == sec_id) else {
        clear_chat_prompt(chat_id);
        return render_sections_list(state, 0, None).await;
    };
    let first_cond = candidate.sections[sec_idx].condition_refs.first().cloned();
    let mut added_labels = Vec::new();
    for (is_lan, val) in tokens {
        if is_lan {
            if !candidate.sections[sec_idx].fully_routed_ips.contains(&val) {
                candidate.sections[sec_idx]
                    .fully_routed_ips
                    .push(val.clone());
            }
            added_labels.push(format!("LAN:{val}"));
        } else {
            if !candidate.sections[sec_idx].user_subnets.contains(&val) {
                candidate.sections[sec_idx].user_subnets.push(val.clone());
            }
            if let Some(ref cid) = first_cond
                && let Some(cond) = candidate.conditions.iter_mut().find(|c| &c.id == cid)
                && !cond.user_subnets.contains(&val)
            {
                cond.user_subnets.push(val.clone());
            }
            added_labels.push(format!("DST:{val}"));
        }
    }

    clear_chat_prompt(chat_id);
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!("[OK] {}", escape_html(&added_labels.join(", "))),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

async fn handle_update_fptn_prompt(
    sec_id: &str,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let trimmed = input.trim();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);

    let Some(decoded) =
        decode_fptn_token_json_with_core_bin(trimmed, Some(&candidate.settings.core_bin_path))
    else {
        set_chat_prompt(
            chat_id,
            PendingPromptKind::UpdateFptnToken {
                sec_id: sec_id.to_string(),
            },
        );
        return BotReply::text(tr(
            ru,
            "[!] Не удалось декодировать токен FPTN. Проверьте формат (fptn://, fptnb://, JSON) или отправьте /cancel.",
            "[!] Failed to decode FPTN token. Verify format (fptn://, fptnb://, JSON) or send /cancel.",
        ));
    };

    let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == sec_id) else {
        clear_chat_prompt(chat_id);
        return render_sections_list(state, 0, None).await;
    };
    sec.fptn_access_token =
        normalize_fptn_token_input(trimmed).unwrap_or_else(|| trimmed.to_string());
    sec.connection_type = "fptn".to_string();
    sec.action = "fptn".to_string();
    sec.outbound_source_refs.clear();

    let srv_cnt = count_fptn_token_servers(&decoded);

    clear_chat_prompt(chat_id);
    let note = match commit_and_reload_with_warning(state, core, candidate).await {
        Ok(warn) => format!(
            "[OK] {}: {srv_cnt}{}",
            tr(
                ru,
                "Токен FPTN обновлён, серверов",
                "FPTN token updated, servers"
            ),
            format_reload_warn(warn)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_section_view(state, core, sec_id, Some(note)).await
}

async fn prompt_source_fptn_input(chat_id: i64, state: &Arc<AppState>, src_id: &str) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let label = d
        .outbound_sources
        .iter()
        .find(|s| s.id == src_id)
        .map(|s| {
            let n = s.name.trim();
            if n.is_empty() { s.id.as_str() } else { n }
        })
        .unwrap_or(src_id);

    set_chat_prompt(
        chat_id,
        PendingPromptKind::UpdateSourceFptnToken {
            src_id: src_id.to_string(),
        },
    );
    let kb = inline_kb(vec![vec![cb_btn(
        tr(ru, "Отмена", "Cancel"),
        &format!("src_view {src_id}"),
    )]]);
    BotReply::with_kb(
        format!(
            "<b>{}</b>\n\n{}",
            escape_html(label),
            tr(
                ru,
                "Отправьте новый токен доступа FPTN (<code>fptn://...</code>, <code>fptnb://...</code>, <code>fptn:...</code>, JSON или <code>.fptn</code>-файл).\nОтмена: /cancel",
                "Send the new FPTN access token (<code>fptn://...</code>, <code>fptnb://...</code>, <code>fptn:...</code>, JSON, or a <code>.fptn</code> file).\nCancel: /cancel",
            )
        ),
        kb,
    )
}

async fn handle_update_source_fptn_prompt(
    src_id: &str,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let trimmed = input.trim();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);

    let Some(decoded) =
        decode_fptn_token_json_with_core_bin(trimmed, Some(&candidate.settings.core_bin_path))
    else {
        set_chat_prompt(
            chat_id,
            PendingPromptKind::UpdateSourceFptnToken {
                src_id: src_id.to_string(),
            },
        );
        return BotReply::text(tr(
            ru,
            "[!] Не удалось декодировать токен FPTN. Проверьте формат (fptn://, fptnb://, JSON) или отправьте /cancel.",
            "[!] Failed to decode FPTN token. Verify format (fptn://, fptnb://, JSON) or send /cancel.",
        ));
    };

    let Some(src) = candidate
        .outbound_sources
        .iter_mut()
        .find(|s| s.id == src_id)
    else {
        clear_chat_prompt(chat_id);
        return render_sources_list(state, 0, None).await;
    };
    src.fptn_access_token =
        normalize_fptn_token_input(trimmed).unwrap_or_else(|| trimmed.to_string());
    src.source_type = "fptn".to_string();
    src.last_updated_unix = unix_now_secs();

    let srv_cnt = count_fptn_token_servers(&decoded);

    clear_chat_prompt(chat_id);
    let note = match commit_and_reload_with_warning(state, core, candidate).await {
        Ok(warn) => format!(
            "[OK] {}: {srv_cnt}{}",
            tr(
                ru,
                "Токен FPTN обновлён, серверов",
                "FPTN token updated, servers"
            ),
            format_reload_warn(warn)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_source_view(state, src_id, 0, Some(note)).await
}

// =========================================================================
// 4. Outbound Sources & Nodes
// =========================================================================

async fn render_sources_list(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let (safe_page, total_pages, start, end) = paginate(d.outbound_sources.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({}/{})",
        tr(ru, "Источники и подписки", "Outbound Sources"),
        d.outbound_sources.iter().filter(|s| s.enabled).count(),
        d.outbound_sources.len()
    ));

    let mut rows = Vec::new();
    if d.outbound_sources.is_empty() {
        lines.push(
            tr(
                ru,
                "Источники не настроены.",
                "No outbound sources configured.",
            )
            .to_string(),
        );
    } else {
        for src in &d.outbound_sources[start..end] {
            let sname = if src.name.trim().is_empty() {
                src.id.as_str()
            } else {
                src.name.trim()
            };
            let nodes_cnt = if !src.cached_nodes.is_empty() {
                src.cached_nodes.len()
            } else {
                src.proxy_links.len()
            };
            let quota_str = if src.sub_total_bytes > 0 {
                let used = src.sub_upload_bytes.saturating_add(src.sub_download_bytes);
                format!(" | {}/{}", fmt_bytes(used), fmt_bytes(src.sub_total_bytes))
            } else {
                String::new()
            };
            lines.push(format!(
                "{} <b>{}</b> (<code>{}</code>) | {}: {}{}",
                status_badge(src.enabled),
                escape_html(sname),
                escape_html(&src.source_type),
                tr(ru, "узлов", "nodes"),
                nodes_cnt,
                quota_str
            ));
            rows.push(vec![
                cb_btn(
                    &format!(
                        "{} {}",
                        status_badge(src.enabled),
                        truncate_label(sname, 22)
                    ),
                    &format!("src_view {}", src.id),
                ),
                cb_btn(
                    if src.enabled { "OFF" } else { "ON" },
                    &format!("src_tog {}", src.id),
                ),
            ]);
        }
    }

    add_pagination_row(&mut rows, "src_list", safe_page, total_pages);
    rows.push(vec![
        cb_btn(tr(ru, "+ Добавить URI/Sub", "+ Add URI/Sub"), "src_add"),
        cb_btn(
            tr(ru, "Обновить подписки", "Refresh Subs"),
            "src_refresh_all",
        ),
    ]);
    rows.push(vec![
        cb_btn("WARP", "src_warp"),
        cb_btn(tr(ru, "Ping всех узлов", "Ping All"), "src_ping"),
        cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

fn collect_all_source_node_tags(d: &RouterStoreData) -> Vec<String> {
    let mut tags = Vec::new();
    for src in &d.outbound_sources {
        for n in &src.cached_nodes {
            if !tags.contains(&n.tag) {
                tags.push(n.tag.clone());
            }
        }
        for (idx, link) in src.proxy_links.iter().enumerate() {
            if let Some(n) = parse_proxy_uri(link, idx)
                && !tags.contains(&n.tag)
            {
                tags.push(n.tag);
            }
        }
        if src.source_type == "fptn" && !src.fptn_access_token.trim().is_empty() {
            let sni_val = if !src.fptn_sni.trim().is_empty() {
                src.fptn_sni.trim()
            } else {
                src.sni.trim()
            };
            for (tag, _) in expand_fptn_token_outbounds(
                &format!("fptn-{}", src.id),
                &src.fptn_access_token,
                sni_val,
                src.fptn_bypass_method.trim(),
                src.fptn_preferred_server.trim(),
            ) {
                if !tags.contains(&tag) {
                    tags.push(tag);
                }
            }
        }
    }
    tags
}

async fn render_source_view(
    state: &Arc<AppState>,
    src_id: &str,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);

    let Some(src) = d.outbound_sources.iter().find(|s| s.id == src_id) else {
        return render_sources_list(
            state,
            0,
            Some(tr(ru, "[ERR] Источник не найден", "[ERR] Source not found").to_string()),
        )
        .await;
    };

    let sname = if src.name.trim().is_empty() {
        src.id.as_str()
    } else {
        src.name.trim()
    };

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!("<b>{}</b>", escape_html(sname)));
    lines.push(format!(
        "ID: <code>{}</code> | {} | {}: <code>{}</code>",
        escape_html(&src.id),
        status_badge(src.enabled),
        tr(ru, "Тип", "Type"),
        escape_html(&src.source_type)
    ));
    if !src.subscription_urls.is_empty() {
        let hosts: Vec<String> = src
            .subscription_urls
            .iter()
            .map(|u| sanitize_url_host(u))
            .collect();
        lines.push(format!(
            "URL ({}): <code>{}</code>",
            hosts.len(),
            escape_html(&hosts.join(", "))
        ));
    }
    if src.sub_total_bytes > 0 {
        let used = src.sub_upload_bytes.saturating_add(src.sub_download_bytes);
        lines.push(format!(
            "{}: {} / {}",
            tr(ru, "Трафик", "Traffic"),
            fmt_bytes(used),
            fmt_bytes(src.sub_total_bytes)
        ));
    }
    if !src.sub_last_error.is_empty() {
        lines.push(format!(
            "[!] {}: {}",
            tr(ru, "Ошибка", "Error"),
            escape_html(&src.sub_last_error)
        ));
    }
    if src.source_type == "warp" && !src.warp_ipv4.is_empty() {
        lines.push(format!(
            "WARP IP: <code>{}</code> | Endpoint: <code>{}</code>",
            escape_html(&src.warp_ipv4),
            escape_html(&src.wg_endpoint)
        ));
    }
    if src.source_type == "fptn" {
        let token_state = if src.fptn_access_token.trim().is_empty() {
            tr(ru, "[не задан]", "[not set]").to_string()
        } else if let Some(dec) = decode_fptn_token_json_with_core_bin(
            &src.fptn_access_token,
            Some(&d.settings.core_bin_path),
        ) {
            let srv_cnt = count_fptn_token_servers(&dec);
            format!("[OK] ({srv_cnt} {})", tr(ru, "серв.", "servers"))
        } else {
            "[configured]".to_string()
        };
        lines.push(format!("FPTN Token: {token_state}"));
    }

    let mut src_nodes: Vec<String> = src.cached_nodes.iter().map(|n| n.tag.clone()).collect();
    for (idx, link) in src.proxy_links.iter().enumerate() {
        if let Some(n) = parse_proxy_uri(link, idx)
            && !src_nodes.contains(&n.tag)
        {
            src_nodes.push(n.tag);
        }
    }
    if src.source_type == "fptn" && !src.fptn_access_token.trim().is_empty() {
        let sni_val = if !src.fptn_sni.trim().is_empty() {
            src.fptn_sni.trim()
        } else {
            src.sni.trim()
        };
        for (tag, _) in expand_fptn_token_outbounds(
            &format!("fptn-{}", src.id),
            &src.fptn_access_token,
            sni_val,
            src.fptn_bypass_method.trim(),
            src.fptn_preferred_server.trim(),
        ) {
            if !src_nodes.contains(&tag) {
                src_nodes.push(tag);
            }
        }
    }

    let all_tags = collect_all_source_node_tags(&d);
    let mut rows = Vec::new();
    let mut action_row = vec![cb_btn(
        if src.enabled {
            tr(ru, "Выключить", "Disable")
        } else {
            tr(ru, "Включить", "Enable")
        },
        &format!("src_tog {}", src.id),
    )];
    if src.source_type == "subscription" {
        action_row.push(cb_btn(
            tr(ru, "Обновить", "Refresh"),
            &format!("src_refresh {}", src.id),
        ));
    }
    if src.source_type == "fptn" {
        action_row.push(cb_btn(
            tr(ru, "Обновить FPTN токен", "Update FPTN Token"),
            &format!("src_fptn {}", src.id),
        ));
    }
    rows.push(action_row);

    if !src_nodes.is_empty() {
        let (safe_page, total_pages, start, end) = paginate(src_nodes.len(), page, PER_PAGE);
        lines.push(format!(
            "\n<b>{} ({}):</b>",
            tr(ru, "Узлы", "Nodes"),
            src_nodes.len()
        ));
        for tag in &src_nodes[start..end] {
            let lat = live
                .node_latencies_ms
                .get(tag)
                .map(|ms| format!(" ({ms} ms)"))
                .unwrap_or_default();
            lines.push(format!("- <code>{}</code>{lat}", escape_html(tag)));
            if let Some(global_idx) = all_tags.iter().position(|t| t == tag) {
                rows.push(vec![cb_btn(
                    &format!("Exit IP: {}{lat}", truncate_label(tag, 20)),
                    &format!("src_exit {global_idx}"),
                )]);
            }
        }
        add_pagination_row(
            &mut rows,
            &format!("src_view {}", src.id),
            safe_page,
            total_pages,
        );
    }

    rows.push(vec![
        cb_btn(tr(ru, "Удалить", "Delete"), &format!("src_del {}", src.id)),
        cb_btn(tr(ru, "<- Источники", "<- Sources"), "src_list 0"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_src_toggle(
    src_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(src) = candidate
        .outbound_sources
        .iter_mut()
        .find(|s| s.id == src_id)
    else {
        return render_sources_list(
            state,
            0,
            Some(tr(ru, "[ERR] Источник не найден", "[ERR] Source not found").to_string()),
        )
        .await;
    };
    src.enabled = !src.enabled;
    let enabled_now = src.enabled;
    let note = match commit_and_reload_with_warning(state, core, candidate).await {
        Ok(warn) => format!(
            "[OK] {} -> {}{}",
            escape_html(src_id),
            status_badge(enabled_now),
            format_reload_warn(warn)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_source_view(state, src_id, 0, Some(note)).await
}

async fn render_source_delete_confirm(state: &Arc<AppState>, src_id: &str) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let label = d
        .outbound_sources
        .iter()
        .find(|s| s.id == src_id)
        .map(|s| {
            if s.name.is_empty() {
                s.id.as_str()
            } else {
                s.name.as_str()
            }
        })
        .unwrap_or(src_id);

    let kb = inline_kb(vec![vec![
        cb_btn(
            tr(ru, "Подтвердить удаление", "Confirm Delete"),
            &format!("src_del_ok {src_id}"),
        ),
        cb_btn(tr(ru, "Отмена", "Cancel"), &format!("src_view {src_id}")),
    ]]);

    BotReply::with_kb(
        format!(
            "<b>{}</b>\n\n{} <code>{}</code>?",
            tr(ru, "Удаление источника", "Delete Source"),
            tr(ru, "Удалить источник", "Delete source"),
            escape_html(label)
        ),
        kb,
    )
}

async fn handle_src_delete(
    src_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let before = candidate.outbound_sources.len();
    candidate.outbound_sources.retain(|s| s.id != src_id);
    if candidate.outbound_sources.len() == before {
        return render_sources_list(
            state,
            0,
            Some(tr(ru, "[ERR] Источник не найден", "[ERR] Source not found").to_string()),
        )
        .await;
    }
    for sec in &mut candidate.sections {
        sec.outbound_source_refs.retain(|r| r != src_id);
    }
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} <code>{}</code>",
            tr(ru, "Удалён источник", "Deleted source"),
            escape_html(src_id)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_sources_list(state, 0, Some(note)).await
}

async fn handle_src_refresh(
    src_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let ru = current_is_ru(state).await;
    let res = if src_id.is_empty() {
        Box::pin(core.refresh_all_subscriptions()).await
    } else {
        Box::pin(core.refresh_subscription_source(src_id)).await
    };
    let note = match res {
        Ok(cnt) => format!(
            "[OK] {}: {cnt}",
            tr(ru, "Обновлено подписок", "Refreshed subscriptions")
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    if src_id.is_empty() {
        render_sources_list(state, 0, Some(note)).await
    } else {
        render_source_view(state, src_id, 0, Some(note)).await
    }
}

async fn handle_src_warp(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let ru = current_is_ru(state).await;
    match Box::pin(core.register_warp_source()).await {
        Ok(val) => {
            let ipv4 = val.get("ipv4").and_then(Value::as_str).unwrap_or("-");
            let ep = val.get("endpoint").and_then(Value::as_str).unwrap_or("-");
            let note = format!(
                "[OK] WARP {}: <code>{}</code> ({})",
                tr(ru, "подключён", "registered"),
                escape_html(ipv4),
                escape_html(ep)
            );
            render_source_view(state, "warp_cf", 0, Some(note)).await
        }
        Err(e) => {
            let note = format!("[ERR] WARP: {}", escape_html(&e.to_string()));
            render_sources_list(state, 0, Some(note)).await
        }
    }
}

async fn handle_ping_all(state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let results = Box::pin(core.probe_all_nodes_rtt()).await;
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let mut entries: Vec<(String, u32)> = results.into_iter().collect();
    entries.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));

    let mut lines = vec![format!(
        "<b>{}</b> ({})",
        tr(ru, "Задержка узлов (RTT)", "Node Latency (RTT)"),
        entries.len()
    )];
    if entries.is_empty() {
        lines.push(
            tr(
                ru,
                "Нет доступных узлов или ядро не отвечает.",
                "No reachable nodes or core did not respond.",
            )
            .to_string(),
        );
    } else {
        let mut table = String::from("<pre>");
        for (tag, ms) in entries.iter().take(20) {
            table.push_str(&format!("{:>4} ms  {}\n", ms, escape_html(tag)));
        }
        table.push_str("</pre>");
        lines.push(table);
        if entries.len() > 20 {
            lines.push(format!("... +{}", entries.len() - 20));
        }
    }

    let kb = inline_kb(vec![vec![
        cb_btn(tr(ru, "Повторить Ping", "Ping Again"), "src_ping"),
        cb_btn(tr(ru, "<- Источники", "<- Sources"), "src_list 0"),
        cb_btn(tr(ru, "Меню", "Menu"), "menu"),
    ]]);
    BotReply::with_kb(lines.join("\n"), kb)
}

async fn handle_src_exit(
    idx_or_tag: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let all_tags = collect_all_source_node_tags(&d);
    let tag = if let Ok(idx) = idx_or_tag.parse::<usize>() {
        match all_tags.get(idx) {
            Some(t) => t.clone(),
            None => {
                return render_sources_list(
                    state,
                    0,
                    Some(tr(ru, "[ERR] Узел не найден", "[ERR] Node not found").to_string()),
                )
                .await;
            }
        }
    } else {
        idx_or_tag.to_string()
    };

    let (exit_val, rtt_ms) = tokio::join!(
        Box::pin(core.probe_node_exit_ip(&tag)),
        Box::pin(core.probe_single_node_rtt(&tag))
    );
    let ip = exit_val
        .get("ip")
        .or_else(|| exit_val.get("exit_ip"))
        .and_then(Value::as_str)
        .unwrap_or("-");
    let country = exit_val
        .get("country")
        .or_else(|| exit_val.get("country_code"))
        .and_then(Value::as_str)
        .unwrap_or("-");
    let err = exit_val.get("error").and_then(Value::as_str).unwrap_or("");

    let mut msg = format!(
        "<b>{}</b>\n{}: <code>{}</code>\nRTT: <code>{} ms</code>\nExit IP: <code>{}</code> ({})",
        tr(ru, "Проверка узла", "Node Exit Probe"),
        tr(ru, "Узел", "Node"),
        escape_html(&tag),
        rtt_ms,
        escape_html(ip),
        escape_html(country)
    );
    if !err.is_empty() {
        msg.push_str(&format!("\n[!] {}", escape_html(err)));
    }

    let kb = inline_kb(vec![vec![
        cb_btn(tr(ru, "<- Источники", "<- Sources"), "src_list 0"),
        cb_btn(tr(ru, "Меню", "Menu"), "menu"),
    ]]);
    BotReply::with_kb(msg, kb)
}

async fn handle_import_subscription_or_uri(
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let trimmed = input.trim();
    let ru = current_is_ru(state).await;
    if trimmed.is_empty() {
        set_chat_prompt(chat_id, PendingPromptKind::AddSubscriptionOrUri);
        return BotReply::text(tr(
            ru,
            "[!] Пустой ввод. Отправьте HTTPS-подписку или URI узла, либо /cancel.",
            "[!] Empty input. Send an HTTPS subscription URL or proxy URI, or /cancel.",
        ));
    }

    let core_bin = {
        let d = state.data.read().await;
        d.settings.core_bin_path.clone()
    };

    let mut sub_urls: Vec<String> = Vec::new();
    let mut uri_lines: Vec<String> = Vec::new();
    let mut parsed_nodes: Vec<ParsedProxyNode> = Vec::new();
    let mut fptn_tokens: Vec<(String, Value)> = Vec::new();

    let has_multiple_uri_lines = trimmed.lines().skip(1).any(|l| {
        let s = l.trim().to_ascii_lowercase();
        !s.is_empty()
            && (s.starts_with("http://")
                || s.starts_with("https://")
                || s.contains("://")
                || s.starts_with("fptn:")
                || s.starts_with("fptnb:"))
    });
    let allow_whole_payload = trimmed.starts_with('{') || !has_multiple_uri_lines;
    if allow_whole_payload
        && let Some(decoded) = decode_fptn_token_json_with_core_bin(trimmed, Some(&core_bin))
    {
        let norm = normalize_fptn_token_input(trimmed).unwrap_or_else(|| trimmed.to_string());
        fptn_tokens.push((norm, decoded));
    } else {
        for (idx, raw_line) in trimmed.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with("https://") || line.starts_with("http://") {
                if !sub_urls.contains(&line.to_string()) {
                    sub_urls.push(line.to_string());
                }
                continue;
            }
            let lower_line = line.to_ascii_lowercase();
            if (lower_line.starts_with("fptn:")
                || lower_line.starts_with("fptn//")
                || lower_line.starts_with("fptnb:")
                || lower_line.starts_with("fptnb//"))
                && let Some(decoded) = decode_fptn_token_json_with_core_bin(line, Some(&core_bin))
            {
                let norm = normalize_fptn_token_input(line).unwrap_or_else(|| line.to_string());
                fptn_tokens.push((norm, decoded));
                continue;
            }
            if let Some(node) = parse_proxy_uri(line, idx) {
                uri_lines.push(line.to_string());
                if !parsed_nodes.iter().any(|n| n.tag == node.tag) {
                    parsed_nodes.push(node);
                }
            }
        }
    }

    // Fallback: raw base64 subscription payload pasted directly
    if sub_urls.is_empty() && parsed_nodes.is_empty() && fptn_tokens.is_empty() {
        let b64_nodes = CoreManager::parse_subscription_payload(trimmed);
        for n in b64_nodes {
            if !n.raw_uri.is_empty() {
                uri_lines.push(n.raw_uri.clone());
            }
            if !parsed_nodes.iter().any(|x| x.tag == n.tag) {
                parsed_nodes.push(n);
            }
        }
    }

    if sub_urls.is_empty() && parsed_nodes.is_empty() && fptn_tokens.is_empty() {
        set_chat_prompt(chat_id, PendingPromptKind::AddSubscriptionOrUri);
        return BotReply::text(tr(
            ru,
            "[!] Не удалось распознать URL подписки или прокси-URI. Повторите или отправьте /cancel.",
            "[!] Could not parse subscription URL or proxy URI. Retry or send /cancel.",
        ));
    }

    let mut candidate = state.data.read().await.clone();
    let existing_ids: Vec<String> = candidate
        .outbound_sources
        .iter()
        .map(|s| s.id.clone())
        .collect();
    let mut created_ids: Vec<String> = Vec::new();
    let mut created_sub_ids: Vec<String> = Vec::new();
    let now = unix_now_secs();

    if !sub_urls.is_empty() {
        let new_id = unique_id("src_sub", &existing_ids);
        let host_label = sanitize_url_host(&sub_urls[0]);
        candidate.outbound_sources.push(OutboundSource {
            id: new_id.clone(),
            enabled: true,
            name: format!("Sub ({host_label})"),
            source_type: "subscription".to_string(),
            subscription_urls: sub_urls,
            subscription_update_enabled: true,
            last_updated_unix: now,
            ..Default::default()
        });
        created_ids.push(new_id.clone());
        created_sub_ids.push(new_id);
    }

    if !parsed_nodes.is_empty() {
        let mut all_ids = existing_ids.clone();
        all_ids.extend(created_ids.clone());
        let new_id = unique_id("src_uri", &all_ids);
        let label = if parsed_nodes.len() == 1 {
            parsed_nodes[0].tag.clone()
        } else {
            format!("Links ({})", parsed_nodes.len())
        };
        candidate.outbound_sources.push(OutboundSource {
            id: new_id.clone(),
            enabled: true,
            name: label,
            source_type: "proxy_links".to_string(),
            proxy_links: uri_lines,
            cached_nodes: parsed_nodes.clone(),
            last_updated_unix: now,
            ..Default::default()
        });
        created_ids.push(new_id);
    }

    for (tok, decoded) in fptn_tokens {
        let mut all_ids = existing_ids.clone();
        all_ids.extend(created_ids.clone());
        let new_id = unique_id("src_fptn", &all_ids);
        let svc_name = decoded
            .get("service_name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let name = match svc_name {
            Some(svc) => format!("FPTN ({svc})"),
            None => "FPTN Source".to_string(),
        };
        candidate.outbound_sources.push(OutboundSource {
            id: new_id.clone(),
            enabled: true,
            name,
            source_type: "fptn".to_string(),
            fptn_access_token: tok,
            last_updated_unix: now,
            ..Default::default()
        });
        created_ids.push(new_id);
    }

    clear_chat_prompt(chat_id);
    if let Err(e) = commit_and_sync_tg_tx(state, candidate).await {
        return render_sources_list(
            state,
            0,
            Some(format!("[ERR] {}", escape_html(&e.to_string()))),
        )
        .await;
    }

    for sid in &created_sub_ids {
        let _ = Box::pin(core.refresh_subscription_source(sid)).await;
    }
    let reload_warn = format_reload_warn(
        Box::pin(core.apply_or_reload())
            .await
            .err()
            .map(|e| e.to_string()),
    );

    if let Some(first_id) = created_ids.first() {
        let note = format!(
            "[OK] {}: {}{}",
            tr(ru, "Источник добавлен", "Source added"),
            escape_html(&created_ids.join(", ")),
            reload_warn
        );
        return render_source_view(state, first_id, 0, Some(note)).await;
    }
    render_sources_list(state, 0, None).await
}

// =========================================================================
// 5. Inbound VPN Servers
// =========================================================================

fn resolve_public_host_override<'a>(
    d: &'a RouterStoreData,
    srv: &'a InboundServer,
    wan_ip: &'a str,
) -> Option<&'a str> {
    if !srv.public_host.trim().is_empty() {
        None
    } else if !d.settings.server_subscription_host.trim().is_empty() {
        Some(d.settings.server_subscription_host.trim())
    } else if !wan_ip.trim().is_empty() {
        Some(wan_ip.trim())
    } else {
        None
    }
}

async fn render_servers_list(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let (safe_page, total_pages, start, end) = paginate(d.servers.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({}/{})",
        tr(ru, "Входящие VPN-серверы", "Inbound VPN Servers"),
        d.servers.iter().filter(|s| s.enabled).count(),
        d.servers.len()
    ));

    let mut rows = Vec::new();
    if d.servers.is_empty() {
        lines.push(tr(ru, "Серверов пока нет.", "No inbound servers configured.").to_string());
    } else {
        for srv in &d.servers[start..end] {
            let label = if srv.label.trim().is_empty() {
                srv.id.as_str()
            } else {
                srv.label.trim()
            };
            lines.push(format!(
                "{} <b>{}</b> | <code>{}</code> :{} | {}: {}",
                status_badge(srv.enabled),
                escape_html(label),
                escape_html(&srv.protocol),
                srv.listen_port,
                tr(ru, "клиенты", "clients"),
                srv.clients.len()
            ));
            rows.push(vec![
                cb_btn(
                    &format!(
                        "{} {} :{}",
                        status_badge(srv.enabled),
                        truncate_label(label, 18),
                        srv.listen_port
                    ),
                    &format!("srv_view {}", srv.id),
                ),
                cb_btn(
                    if srv.enabled { "OFF" } else { "ON" },
                    &format!("srv_tog {}", srv.id),
                ),
            ]);
        }
    }

    add_pagination_row(&mut rows, "srv_list", safe_page, total_pages);
    rows.push(vec![
        cb_btn(tr(ru, "+ Новый сервер", "+ New Server"), "srv_new_menu"),
        cb_btn(tr(ru, "Экспорт подписки", "Export Sub"), "srv_sub"),
    ]);
    rows.push(vec![cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu")]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn render_server_view(
    state: &Arc<AppState>,
    srv_id: &str,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let Some(srv) = d.servers.iter().find(|s| s.id == srv_id) else {
        return render_servers_list(
            state,
            0,
            Some(tr(ru, "[ERR] Сервер не найден", "[ERR] Server not found").to_string()),
        )
        .await;
    };

    let label = if srv.label.trim().is_empty() {
        srv.id.as_str()
    } else {
        srv.label.trim()
    };
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!("<b>{}</b>", escape_html(label)));
    lines.push(format!(
        "ID: <code>{}</code> | {}",
        escape_html(&srv.id),
        status_badge(srv.enabled)
    ));
    lines.push(format!(
        "{}: <code>{}</code> | {}: <code>{}</code> | {}: <code>{}</code>",
        tr(ru, "Протокол", "Protocol"),
        escape_html(&srv.protocol),
        tr(ru, "Порт", "Port"),
        srv.listen_port,
        tr(ru, "Защита", "Security"),
        escape_html(if srv.security.is_empty() {
            "none"
        } else {
            &srv.security
        })
    ));
    if !srv.public_host.is_empty() {
        lines.push(format!(
            "Host: <code>{}</code>",
            escape_html(&srv.public_host)
        ));
    }
    lines.push(format!(
        "{}: <code>{}</code> | {}: {}",
        tr(ru, "Маршрутизация", "Routing"),
        escape_html(if srv.routing_mode.is_empty() {
            "rules"
        } else {
            &srv.routing_mode
        }),
        tr(ru, "Клиенты", "Clients"),
        srv.clients.len()
    ));

    let mut rows = vec![vec![
        cb_btn(
            if srv.enabled {
                tr(ru, "Выключить", "Disable")
            } else {
                tr(ru, "Включить", "Enable")
            },
            &format!("srv_tog {}", srv.id),
        ),
        cb_btn(
            tr(ru, "Share URI", "Share URI"),
            &format!("srv_uri {}", srv.id),
        ),
    ]];
    if srv.protocol == "awg" || srv.protocol == "wireguard" {
        rows.push(vec![cb_btn(
            tr(ru, "Скачать .conf", "Download .conf"),
            &format!("srv_wg {}", srv.id),
        )]);
    }
    rows.push(vec![
        cb_btn(
            &format!("{} ({})", tr(ru, "Клиенты", "Clients"), srv.clients.len()),
            &format!("srv_clients {} 0", srv.id),
        ),
        cb_btn(tr(ru, "<- Серверы", "<- Servers"), "srv_list 0"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_srv_toggle(
    srv_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(srv) = candidate.servers.iter_mut().find(|s| s.id == srv_id) else {
        return render_servers_list(
            state,
            0,
            Some(tr(ru, "[ERR] Сервер не найден", "[ERR] Server not found").to_string()),
        )
        .await;
    };
    srv.enabled = !srv.enabled;
    let enabled_now = srv.enabled;
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} -> {}",
            escape_html(srv_id),
            status_badge(enabled_now)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_server_view(state, srv_id, Some(note)).await
}

async fn handle_srv_uri(srv_id: &str, state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(srv) = d.servers.iter().find(|s| s.id == srv_id) else {
        return render_servers_list(state, 0, None).await;
    };
    let (_lan, wan_ip) = detect_router_ips();
    let host_ov = resolve_public_host_override(&d, srv, &wan_ip);
    let uri = build_server_share_uri(srv, host_ov);

    let kb = inline_kb(vec![vec![
        cb_btn(
            tr(ru, "<- Сервер", "<- Server"),
            &format!("srv_view {}", srv.id),
        ),
        cb_btn(tr(ru, "<- Серверы", "<- Servers"), "srv_list 0"),
    ]]);
    BotReply::with_kb(
        format!(
            "<b>{} — {}</b>\n\n<pre><code>{}</code></pre>",
            tr(ru, "Клиентская ссылка", "Client Share URI"),
            escape_html(&srv.label),
            escape_html(&uri)
        ),
        kb,
    )
}

async fn handle_srv_wg(srv_id: &str, state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(srv) = d.servers.iter().find(|s| s.id == srv_id) else {
        return render_servers_list(state, 0, None).await;
    };
    let (_lan, wan_ip) = detect_router_ips();
    let host_ov = resolve_public_host_override(&d, srv, &wan_ip);
    let conf = build_server_wg_conf(srv, host_ov);
    let safe_name: String = srv
        .id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let filename = format!("{safe_name}.conf");
    let kb = inline_kb(vec![vec![cb_btn(
        tr(ru, "<- Сервер", "<- Server"),
        &format!("srv_view {}", srv.id),
    )]]);
    let caption = format!("{} ({})", srv.label, srv.protocol);
    BotReply::with_doc(
        format!(
            "<b>{}</b>: <code>{}</code>",
            tr(ru, "Конфигурация WireGuard / AWG", "WireGuard / AWG Config"),
            escape_html(&filename)
        ),
        Some(kb),
        filename,
        conf.into_bytes(),
        caption,
    )
}

async fn handle_srv_sub(state: &Arc<AppState>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let enabled_cnt = d.servers.iter().filter(|s| s.enabled).count();
    if enabled_cnt == 0 {
        return render_servers_list(
            state,
            0,
            Some(
                tr(
                    ru,
                    "[!] Нет включённых входящих серверов для экспорта.",
                    "[!] No enabled inbound servers to export.",
                )
                .to_string(),
            ),
        )
        .await;
    }

    let (_lan, wan_ip) = detect_router_ips();
    let host_ov = (!d.settings.server_subscription_host.trim().is_empty())
        .then_some(d.settings.server_subscription_host.trim())
        .or((!wan_ip.trim().is_empty()).then_some(wan_ip.as_str()));
    let fmt = if d.settings.server_subscription_format.trim().is_empty() {
        "plain"
    } else {
        d.settings.server_subscription_format.trim()
    };
    let payload = build_router_subscription_payload(&d, host_ov, fmt);
    let kb = inline_kb(vec![vec![cb_btn(
        tr(ru, "<- Серверы", "<- Servers"),
        "srv_list 0",
    )]]);
    BotReply::with_doc(
        format!(
            "<b>{}</b>\n{}: {enabled_cnt} | {}: <code>{}</code>",
            tr(
                ru,
                "Подписка серверов роутера",
                "Router Server Subscription"
            ),
            tr(ru, "Активных серверов", "Enabled servers"),
            tr(ru, "Формат", "Format"),
            escape_html(fmt)
        ),
        Some(kb),
        "tachyon-subscription.txt",
        payload.into_bytes(),
        format!("Tachyon Servers ({enabled_cnt})"),
    )
}

async fn render_server_new_menu(state: &Arc<AppState>) -> BotReply {
    let ru = current_is_ru(state).await;
    let mut rows = Vec::new();
    for chunk in SERVER_PROTOCOLS.chunks(2) {
        let row = chunk
            .iter()
            .map(|&p| cb_btn(&p.to_uppercase(), &format!("srv_create {p}")))
            .collect();
        rows.push(row);
    }
    rows.push(vec![cb_btn(
        tr(ru, "<- Серверы", "<- Servers"),
        "srv_list 0",
    )]);
    BotReply::with_kb(
        tr(
            ru,
            "<b>Новый входящий VPN-сервер</b>\n\nВыберите протокол для авто-настройки:",
            "<b>New Inbound VPN Server</b>\n\nSelect protocol to auto-configure:",
        ),
        inline_kb(rows),
    )
}

fn pick_free_server_port(d: &RouterStoreData, preferred: u16) -> u16 {
    let mut used: HashSet<u16> = HashSet::new();
    used.insert(d.settings.listen_port);
    used.insert(1602);
    used.insert(1080);
    used.insert(53);
    used.insert(4534);
    used.insert(4535);
    if d.settings.direct_bypass_port > 0 {
        used.insert(d.settings.direct_bypass_port);
    }
    for s in &d.servers {
        used.insert(s.listen_port);
    }
    if preferred > 0 && !used.contains(&preferred) {
        return preferred;
    }
    for port in 20000..=55000 {
        if !used.contains(&port) {
            return port;
        }
    }
    44300
}

fn json_str(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

fn json_u16(v: &Value, key: &str) -> u16 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0) as u16
}

fn json_u32(v: &Value, key: &str) -> u32 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0) as u32
}

fn json_u64(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn json_bool(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

async fn handle_srv_create(
    proto_raw: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let proto = proto_raw.trim().to_ascii_lowercase();
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);

    if proto.is_empty() || !SERVER_PROTOCOLS.contains(&proto.as_str()) {
        return render_server_new_menu(state).await;
    }

    let cfg = auto_configure_server(&proto);
    let preferred_port = json_u16(&cfg, "listen_port");
    let listen_port = pick_free_server_port(&candidate, preferred_port);
    let existing_ids: Vec<String> = candidate.servers.iter().map(|s| s.id.clone()).collect();
    let srv_id = unique_id(&format!("srv_{proto}"), &existing_ids);
    let (_lan, wan_ip) = detect_router_ips();
    let public_host = if !candidate
        .settings
        .server_subscription_host
        .trim()
        .is_empty()
    {
        candidate
            .settings
            .server_subscription_host
            .trim()
            .to_string()
    } else {
        wan_ip
    };

    let mut security = json_str(&cfg, "security");
    if security.is_empty() && matches!(proto.as_str(), "trojan" | "anytls") {
        security = "tls".to_string();
    }

    let srv = InboundServer {
        id: srv_id.clone(),
        enabled: true,
        label: format!("{} :{}", proto.to_uppercase(), listen_port),
        protocol: json_str(&cfg, "protocol").if_empty_then(&proto),
        listen: "0.0.0.0".to_string(),
        listen_port,
        public_host,
        open_firewall_port: true,
        routing_mode: "rules".to_string(),
        security,
        server_uuid: json_str(&cfg, "server_uuid"),
        server_username: json_str(&cfg, "server_username"),
        password: json_str(&cfg, "password"),
        method: json_str(&cfg, "method"),
        vless_flow: json_str(&cfg, "vless_flow"),
        client_fingerprint: json_str(&cfg, "client_fingerprint"),
        reality_handshake_server: json_str(&cfg, "reality_handshake_server"),
        reality_handshake_server_port: json_u16(&cfg, "reality_handshake_server_port"),
        reality_private_key: json_str(&cfg, "reality_private_key"),
        reality_public_key: json_str(&cfg, "reality_public_key"),
        reality_short_id: json_str(&cfg, "reality_short_id"),
        transport: json_str(&cfg, "transport"),
        tewfai_uuid: json_str(&cfg, "tewfai_uuid"),
        tewfai_password: json_str(&cfg, "tewfai_password"),
        tewfai_inbound_transport: json_str(&cfg, "tewfai_inbound_transport"),
        tewfai_inner_cipher: json_str(&cfg, "tewfai_inner_cipher"),
        tewfai_shaper_profile: json_str(&cfg, "tewfai_shaper_profile"),
        tewfai_morph_profile: json_str(&cfg, "tewfai_morph_profile"),
        tewfai_pqc_enabled: json_bool(&cfg, "tewfai_pqc_enabled"),
        wdtt_mode: json_str(&cfg, "wdtt_mode"),
        wdtt_obfs: json_str(&cfg, "wdtt_obfs"),
        wdtt_network: json_str(&cfg, "wdtt_network"),
        wdtt_mtu: json_u16(&cfg, "wdtt_mtu"),
        hysteria2_obfs_type: json_str(&cfg, "hysteria2_obfs_type"),
        hysteria2_obfs_password: json_str(&cfg, "hysteria2_obfs_password"),
        hysteria2_up_mbps: json_u64(&cfg, "hysteria2_up_mbps"),
        hysteria2_down_mbps: json_u64(&cfg, "hysteria2_down_mbps"),
        tuic_congestion_control: json_str(&cfg, "tuic_congestion_control"),
        shadowtls_handshake_server: json_str(&cfg, "shadowtls_handshake_server"),
        shadowtls_handshake_server_port: json_u16(&cfg, "shadowtls_handshake_server_port"),
        shadowtls_version: json_u16(&cfg, "shadowtls_version") as u8,
        mtproto_secret: json_str(&cfg, "mtproto_secret"),
        mtproto_faketls: json_str(&cfg, "mtproto_faketls"),
        mtproto_padding: json_bool(&cfg, "mtproto_padding"),
        mtproto_tolerate_time_skewness: json_bool(&cfg, "mtproto_tolerate_time_skewness"),
        awg_version: json_str(&cfg, "awg_version"),
        awg_mtu: json_u16(&cfg, "awg_mtu"),
        awg_local_address: json_str(&cfg, "awg_local_address"),
        awg_client_address: json_str(&cfg, "awg_client_address"),
        awg_dns: json_str(&cfg, "awg_dns"),
        awg_jc: json_u16(&cfg, "awg_jc"),
        awg_jmin: json_u16(&cfg, "awg_jmin"),
        awg_jmax: json_u16(&cfg, "awg_jmax"),
        awg_s1: json_u16(&cfg, "awg_s1"),
        awg_s2: json_u16(&cfg, "awg_s2"),
        awg_h1: json_u32(&cfg, "awg_h1"),
        awg_h2: json_u32(&cfg, "awg_h2"),
        awg_h3: json_u32(&cfg, "awg_h3"),
        awg_h4: json_u32(&cfg, "awg_h4"),
        awg_keepalive: json_u16(&cfg, "awg_keepalive"),
        awg_private_key: json_str(&cfg, "awg_private_key"),
        awg_server_public_key: json_str(&cfg, "awg_server_public_key"),
        awg_client_private_key: json_str(&cfg, "awg_client_private_key"),
        awg_peer_public_key: json_str(&cfg, "awg_peer_public_key"),
        awg_preshared_key: json_str(&cfg, "awg_preshared_key"),
        ..Default::default()
    };

    candidate.servers.push(srv);
    match commit_and_reload(state, core, candidate).await {
        Ok(()) => {
            let note = format!(
                "[OK] {} <code>{}:{}</code>",
                tr(ru, "Создан сервер", "Created server"),
                escape_html(&proto),
                listen_port
            );
            render_server_view(state, &srv_id, Some(note)).await
        }
        Err(e) => {
            render_servers_list(
                state,
                0,
                Some(format!("[ERR] {}", escape_html(&e.to_string()))),
            )
            .await
        }
    }
}

async fn render_server_clients(
    state: &Arc<AppState>,
    srv_id: &str,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let Some(srv) = d.servers.iter().find(|s| s.id == srv_id) else {
        return render_servers_list(state, 0, None).await;
    };

    let (safe_page, total_pages, start, end) = paginate(srv.clients.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> — {} ({})",
        tr(ru, "Клиенты сервера", "Server Clients"),
        escape_html(&srv.label),
        srv.clients.len()
    ));

    let mut rows = Vec::new();
    if srv.clients.is_empty() {
        lines.push(
            tr(
                ru,
                "Отдельных клиентских записей нет (используются общие ключи сервера).",
                "No individual client entries (shared server credentials in use).",
            )
            .to_string(),
        );
    } else {
        for (offset, cli) in srv.clients[start..end].iter().enumerate() {
            let idx = start + offset;
            let cname = if cli.name.trim().is_empty() {
                if cli.id.trim().is_empty() {
                    "client"
                } else {
                    cli.id.trim()
                }
            } else {
                cli.name.trim()
            };
            lines.push(format!(
                "#{} {} <b>{}</b> | TX {} / RX {}",
                idx + 1,
                status_badge(cli.enabled),
                escape_html(cname),
                fmt_bytes(cli.up),
                fmt_bytes(cli.down)
            ));
            rows.push(vec![cb_btn(
                &format!(
                    "{} {}",
                    status_badge(cli.enabled),
                    truncate_label(cname, 24)
                ),
                &format!("srv_client_tog {} {idx}", srv.id),
            )]);
        }
    }

    add_pagination_row(
        &mut rows,
        &format!("srv_clients {}", srv.id),
        safe_page,
        total_pages,
    );
    rows.push(vec![cb_btn(
        tr(ru, "<- Сервер", "<- Server"),
        &format!("srv_view {}", srv.id),
    )]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_srv_client_toggle(
    srv_id: &str,
    idx: usize,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(srv) = candidate.servers.iter_mut().find(|s| s.id == srv_id) else {
        return render_servers_list(state, 0, None).await;
    };
    let Some(cli) = srv.clients.get_mut(idx) else {
        return render_server_clients(
            state,
            srv_id,
            0,
            Some(tr(ru, "[ERR] Клиент не найден", "[ERR] Client not found").to_string()),
        )
        .await;
    };
    cli.enabled = !cli.enabled;
    let enabled_now = cli.enabled;
    let kick_user = if !cli.name.trim().is_empty() {
        cli.name.clone()
    } else {
        cli.id.clone()
    };

    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => {
            if !enabled_now && !kick_user.is_empty() {
                let _ =
                    Box::pin(core.kick_core_session(&kick_user, &format!("srv-{srv_id}"))).await;
            }
            format!(
                "[OK] {} -> {}",
                escape_html(&kick_user),
                status_badge(enabled_now)
            )
        }
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_server_clients(state, srv_id, idx / PER_PAGE, Some(note)).await
}

// =========================================================================
// 6. LAN Devices, WoL, Parental, Guest Wi-Fi & Schedules
// =========================================================================

fn collect_devices(d: &RouterStoreData, live: &LiveTelemetry) -> Vec<LanDevice> {
    let mut devices = if !live.lan_devices.is_empty() {
        live.lan_devices.clone()
    } else {
        discover_lan_devices()
    };

    for (ip, meta) in &d.device_registry {
        if !devices.iter().any(|dev| dev.ip == *ip) {
            devices.push(LanDevice {
                ip: ip.clone(),
                mac: meta.mac.clone(),
                custom_name: meta.custom_name.clone(),
                note: meta.note.clone(),
                static_lease: meta.static_lease,
                interface: "br-lan".to_string(),
                ..Default::default()
            });
        }
    }

    for dev in &mut devices {
        if let Some(meta) = d.device_registry.get(&dev.ip) {
            if !meta.custom_name.is_empty() {
                dev.custom_name = meta.custom_name.clone();
            }
            if dev.mac.is_empty() && !meta.mac.is_empty() {
                dev.mac = meta.mac.clone();
            }
            dev.static_lease = meta.static_lease;
        }
        dev.routed_section = d
            .sections
            .iter()
            .find(|s| s.fully_routed_ips.contains(&dev.ip))
            .map(|s| s.id.clone())
            .unwrap_or_default();
    }

    devices.sort_by(|a, b| a.ip.cmp(&b.ip));
    devices
}

fn device_display_name(dev: &LanDevice) -> &str {
    if !dev.custom_name.trim().is_empty() {
        dev.custom_name.trim()
    } else if !dev.hostname.trim().is_empty() {
        dev.hostname.trim()
    } else if !dev.vendor.trim().is_empty() {
        dev.vendor.trim()
    } else {
        "LAN Client"
    }
}

async fn render_devices_list(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    state.touch_telemetry_access();
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);
    let devices = collect_devices(&d, &live);

    let (safe_page, total_pages, start, end) = paginate(devices.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({})",
        tr(ru, "Устройства LAN", "LAN Devices"),
        devices.len()
    ));

    let mut rows = Vec::new();
    if devices.is_empty() {
        lines.push(
            tr(
                ru,
                "Активные клиенты LAN не обнаружены.",
                "No active LAN devices found.",
            )
            .to_string(),
        );
    } else {
        for (offset, dev) in devices[start..end].iter().enumerate() {
            let idx = start + offset;
            let name = device_display_name(dev);
            let route = if dev.routed_section.is_empty() {
                tr(ru, "правила", "rules")
            } else {
                dev.routed_section.as_str()
            };
            lines.push(format!(
                "{} <b>{}</b> — <code>{}</code> | <code>{}</code>",
                status_badge(dev.reachable),
                escape_html(name),
                escape_html(&dev.ip),
                escape_html(route)
            ));
            rows.push(vec![cb_btn(
                &format!("{} ({})", truncate_label(name, 16), dev.ip),
                &format!("dev_view {idx}"),
            )]);
        }
    }

    add_pagination_row(&mut rows, "dev_list", safe_page, total_pages);
    rows.push(vec![
        cb_btn(
            tr(ru, "Обновить", "Refresh"),
            &format!("dev_list {safe_page}"),
        ),
        cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn render_device_view(state: &Arc<AppState>, idx: usize, notice: Option<String>) -> BotReply {
    state.touch_telemetry_access();
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);
    let devices = collect_devices(&d, &live);

    let Some(dev) = devices.get(idx) else {
        return render_devices_list(
            state,
            0,
            Some(tr(ru, "[ERR] Устройство не найдено", "[ERR] Device not found").to_string()),
        )
        .await;
    };

    let name = device_display_name(dev);
    let is_excluded = d.sections.iter().any(|s| s.excluded_ips.contains(&dev.ip));
    let route_desc = if !dev.routed_section.is_empty() {
        d.sections
            .iter()
            .find(|s| s.id == dev.routed_section)
            .map(section_display_name)
            .unwrap_or(dev.routed_section.as_str())
            .to_string()
    } else if is_excluded {
        tr(ru, "Исключено (Direct)", "Excluded (Direct)").to_string()
    } else {
        tr(ru, "По правилам секций", "Default section rules").to_string()
    };

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!("<b>{}</b>", escape_html(name)));
    lines.push(format!(
        "IP: <code>{}</code> | MAC: <code>{}</code>",
        escape_html(&dev.ip),
        escape_html(if dev.mac.is_empty() { "-" } else { &dev.mac })
    ));
    lines.push(format!(
        "{}: {} | {}: <code>{}</code> | {}: {}",
        tr(ru, "Статус", "Reachable"),
        status_badge(dev.reachable),
        tr(ru, "Интерфейс", "Interface"),
        escape_html(if dev.interface.is_empty() {
            "br-lan"
        } else {
            &dev.interface
        }),
        tr(ru, "Сессии", "Sessions"),
        dev.active_sessions
    ));
    lines.push(format!(
        "{}: TX {} / RX {}",
        tr(ru, "Трафик", "Traffic"),
        fmt_bytes(dev.upload_bytes),
        fmt_bytes(dev.download_bytes)
    ));
    lines.push(format!(
        "{}: <code>{}</code>",
        tr(ru, "Маршрут", "Route"),
        escape_html(&route_desc)
    ));

    let mut rows = Vec::new();
    let sec_buttons: Vec<Value> = d
        .sections
        .iter()
        .take(6)
        .map(|s| {
            let mark = if dev.routed_section == s.id { "* " } else { "" };
            cb_btn(
                &format!("{mark}{}", truncate_label(section_display_name(s), 16)),
                &format!("dev_sec {idx} {}", s.id),
            )
        })
        .collect();
    for chunk in sec_buttons.chunks(2) {
        rows.push(chunk.to_vec());
    }

    rows.push(vec![
        cb_btn(
            tr(ru, "Сброс (правила)", "Default (Clear)"),
            &format!("dev_sec {idx} clear"),
        ),
        cb_btn(
            tr(ru, "Исключить (Direct)", "Exclude IP"),
            &format!("dev_sec {idx} exclude"),
        ),
    ]);

    let mut action_row = vec![cb_btn(
        tr(ru, "Заблокировать", "Block Device"),
        &format!("dev_block {idx}"),
    )];
    if !dev.mac.is_empty() {
        action_row.push(cb_btn("Wake-on-LAN", &format!("dev_wol {idx}")));
    }
    rows.push(action_row);
    rows.push(vec![
        cb_btn(
            tr(ru, "<- Устройства", "<- Devices"),
            &format!("dev_list {}", idx / PER_PAGE),
        ),
        cb_btn(tr(ru, "Меню", "Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_dev_section(
    idx: usize,
    sec_arg: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let d_snap = state.data.read().await.clone();
    let live_snap = state.live.read().await.clone();
    let ru = is_ru(&d_snap);
    let devices = collect_devices(&d_snap, &live_snap);

    let Some(dev) = devices.get(idx) else {
        return render_devices_list(
            state,
            0,
            Some(tr(ru, "[ERR] Устройство не найдено", "[ERR] Device not found").to_string()),
        )
        .await;
    };
    let ip = dev.ip.clone();
    let mut candidate = d_snap;

    for s in &mut candidate.sections {
        s.fully_routed_ips.retain(|x| x != &ip);
        s.excluded_ips.retain(|x| x != &ip);
    }

    let action_desc = if sec_arg.is_empty() || sec_arg == "clear" || sec_arg == "default" {
        tr(ru, "Маршрут сброшен к правилам", "Reset to section rules").to_string()
    } else if sec_arg == "exclude" {
        for s in &mut candidate.sections {
            if s.connection_type != "direct" && s.connection_type != "block" {
                s.excluded_ips.push(ip.clone());
            }
        }
        tr(
            ru,
            "Устройство исключено (Direct)",
            "Device excluded (Direct)",
        )
        .to_string()
    } else if let Some(target_sec) = candidate.sections.iter_mut().find(|s| s.id == sec_arg) {
        target_sec.fully_routed_ips.push(ip.clone());
        format!(
            "{} -> {}",
            tr(ru, "Направлено в", "Routed to"),
            escape_html(section_display_name(target_sec))
        )
    } else {
        return render_device_view(
            state,
            idx,
            Some(tr(ru, "[ERR] Секция не найдена", "[ERR] Section not found").to_string()),
        )
        .await;
    };

    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!("[OK] {action_desc}"),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_device_view(state, idx, Some(note)).await
}

async fn handle_dev_block(idx: usize, state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let d_snap = state.data.read().await.clone();
    let live_snap = state.live.read().await.clone();
    let ru = is_ru(&d_snap);
    let devices = collect_devices(&d_snap, &live_snap);

    let Some(dev) = devices.get(idx) else {
        return render_devices_list(
            state,
            0,
            Some(tr(ru, "[ERR] Устройство не найдено", "[ERR] Device not found").to_string()),
        )
        .await;
    };
    let ip = dev.ip.clone();
    let mut candidate = d_snap;

    for s in &mut candidate.sections {
        s.fully_routed_ips.retain(|x| x != &ip);
        s.excluded_ips.retain(|x| x != &ip);
    }

    if let Some(block_sec) = candidate
        .sections
        .iter_mut()
        .find(|s| s.connection_type == "block" || s.id == "block" || s.id == "sec_block")
    {
        block_sec.enabled = true;
        if !block_sec.fully_routed_ips.contains(&ip) {
            block_sec.fully_routed_ips.push(ip.clone());
        }
    } else {
        candidate.sections.insert(
            0,
            RoutingSection {
                id: "sec_block".to_string(),
                enabled: true,
                label: "Blocked Devices".to_string(),
                connection_type: "block".to_string(),
                action: "block".to_string(),
                fully_routed_ips: vec![ip.clone()],
                ..Default::default()
            },
        );
    }

    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} <code>{}</code>",
            tr(ru, "Устройство заблокировано", "Blocked device"),
            escape_html(&ip)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_device_view(state, idx, Some(note)).await
}

async fn handle_dev_wol(idx: usize, state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);
    let devices = collect_devices(&d, &live);

    let Some(dev) = devices.get(idx) else {
        return render_devices_list(
            state,
            0,
            Some(tr(ru, "[ERR] Устройство не найдено", "[ERR] Device not found").to_string()),
        )
        .await;
    };
    if dev.mac.trim().is_empty() {
        return render_device_view(
            state,
            idx,
            Some(
                tr(
                    ru,
                    "[!] MAC-адрес устройства неизвестен",
                    "[!] Device MAC is empty",
                )
                .to_string(),
            ),
        )
        .await;
    }
    let iface = if dev.interface.trim().is_empty() {
        "br-lan"
    } else {
        dev.interface.trim()
    };
    let note = match Box::pin(core.send_wake_on_lan(&dev.mac, iface)).await {
        Ok(()) => format!(
            "[OK] WoL -> <code>{}</code> ({})",
            escape_html(&dev.mac),
            escape_html(iface)
        ),
        Err(e) => format!("[ERR] WoL: {}", escape_html(&e.to_string())),
    };
    render_device_view(state, idx, Some(note)).await
}

async fn handle_wol_command(arg: &str, state: &Arc<AppState>, core: &Arc<CoreManager>) -> BotReply {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let ru = is_ru(&d);
    let devices = collect_devices(&d, &live);

    if !arg.is_empty() {
        if let Some((idx, _)) = devices.iter().enumerate().find(|(_, dev)| {
            dev.mac.eq_ignore_ascii_case(arg)
                || dev.ip == arg
                || dev.hostname.eq_ignore_ascii_case(arg)
                || dev.custom_name.eq_ignore_ascii_case(arg)
        }) {
            return handle_dev_wol(idx, state, core).await;
        }
        let msg = match Box::pin(core.send_wake_on_lan(arg, "br-lan")).await {
            Ok(()) => format!("[OK] WoL -> <code>{}</code>", escape_html(arg)),
            Err(e) => format!("[ERR] WoL: {}", escape_html(&e.to_string())),
        };
        return BotReply::with_kb(
            msg,
            inline_kb(vec![vec![
                cb_btn(tr(ru, "Устройства", "Devices"), "dev_list 0"),
                cb_btn(tr(ru, "Меню", "Menu"), "menu"),
            ]]),
        );
    }

    let mut lines = vec![format!(
        "<b>Wake-on-LAN</b>\n{}",
        tr(
            ru,
            "Выберите устройство или введите <code>/wol AA:BB:CC:DD:EE:FF</code>:",
            "Select a device or send <code>/wol AA:BB:CC:DD:EE:FF</code>:"
        )
    )];
    let mut rows = Vec::new();
    for (idx, dev) in devices.iter().enumerate() {
        if dev.mac.is_empty() || rows.len() >= PER_PAGE {
            continue;
        }
        let name = device_display_name(dev);
        lines.push(format!(
            "- <b>{}</b>: <code>{}</code> (<code>{}</code>)",
            escape_html(name),
            escape_html(&dev.mac),
            escape_html(&dev.ip)
        ));
        rows.push(vec![cb_btn(
            &format!("WoL: {} ({})", truncate_label(name, 16), dev.mac),
            &format!("dev_wol {idx}"),
        )]);
    }
    if rows.is_empty() {
        lines.push(
            tr(
                ru,
                "Устройств с известным MAC пока нет.",
                "No devices with known MAC addresses yet.",
            )
            .to_string(),
        );
    }
    rows.push(vec![
        cb_btn(tr(ru, "Все устройства", "All Devices"), "dev_list 0"),
        cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu"),
    ]);
    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn render_parental_list(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let (safe_page, total_pages, start, end) = paginate(d.profiles.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({}/{})",
        tr(ru, "Родительский контроль", "Parental Control"),
        d.profiles.iter().filter(|p| p.enabled).count(),
        d.profiles.len()
    ));

    let mut rows = Vec::new();
    if d.profiles.is_empty() {
        lines.push(
            tr(
                ru,
                "Профили не настроены.",
                "No parental profiles configured.",
            )
            .to_string(),
        );
    } else {
        for prof in &d.profiles[start..end] {
            let pname = if prof.label.trim().is_empty() {
                prof.id.as_str()
            } else {
                prof.label.trim()
            };
            let quota = if prof.daily_quota_minutes > 0 {
                format!("{}/{}m", prof.used_minutes_today, prof.daily_quota_minutes)
            } else {
                "-".to_string()
            };
            lines.push(format!(
                "{} <b>{}</b> | IP:{} | {}: {} | SafeSearch:{} DoH:{}",
                status_badge(prof.enabled),
                escape_html(pname),
                prof.device_ips.len(),
                tr(ru, "Квота", "Quota"),
                quota,
                status_badge(prof.safe_search),
                status_badge(prof.block_doh)
            ));
            rows.push(vec![cb_btn(
                &format!(
                    "{} {}",
                    status_badge(prof.enabled),
                    truncate_label(pname, 24)
                ),
                &format!("par_tog {}", prof.id),
            )]);
        }
    }

    add_pagination_row(&mut rows, "par_list", safe_page, total_pages);
    rows.push(vec![
        cb_btn(tr(ru, "Гостевой Wi-Fi", "Guest Wi-Fi"), "guest_view"),
        cb_btn(tr(ru, "Расписание", "Schedules"), "sched_list"),
    ]);
    rows.push(vec![cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu")]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_parental_toggle(
    prof_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(prof) = candidate.profiles.iter_mut().find(|p| p.id == prof_id) else {
        return render_parental_list(
            state,
            0,
            Some(tr(ru, "[ERR] Профиль не найден", "[ERR] Profile not found").to_string()),
        )
        .await;
    };
    prof.enabled = !prof.enabled;
    let enabled_now = prof.enabled;
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} -> {}",
            escape_html(prof_id),
            status_badge(enabled_now)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_parental_list(state, 0, Some(note)).await
}

async fn render_guest_view(state: &Arc<AppState>, notice: Option<String>) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);
    let g = &d.guest_mode;

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b>",
        tr(ru, "Гостевой режим Wi-Fi", "Guest Wi-Fi Mode")
    ));
    lines.push(format!(
        "{}: {} | {}: <code>{}</code>\n\
         {}: {} | Block Admin: {}\n\
         {}: {} | {}: {}\n\
         {}: {} Mbps | {}: {} min",
        tr(ru, "Статус", "Enabled"),
        status_badge(g.enabled),
        tr(ru, "Режим", "Mode"),
        escape_html(if g.mode.is_empty() {
            "selected"
        } else {
            &g.mode
        }),
        tr(ru, "Изоляция LAN", "Isolate LAN"),
        status_badge(g.isolate_lan),
        status_badge(g.block_router_admin),
        tr(ru, "Гостевых устр.", "Guest devices"),
        g.guest_devices.len(),
        tr(ru, "Доверенных", "Trusted"),
        g.trusted_devices.len(),
        tr(ru, "Лимит скорости", "Speed limit"),
        g.bandwidth_limit_mbps,
        tr(ru, "Лимит времени", "Time limit"),
        g.daily_time_limit
    ));

    let kb = inline_kb(vec![
        vec![
            cb_btn(
                &format!(
                    "{} {}",
                    tr(ru, "Гостевой режим", "Guest Mode"),
                    status_badge(g.enabled)
                ),
                "guest_tog",
            ),
            cb_btn(
                &format!(
                    "{} {}",
                    tr(ru, "Изоляция LAN", "Isolate LAN"),
                    status_badge(g.isolate_lan)
                ),
                "guest_iso",
            ),
        ],
        vec![
            cb_btn(tr(ru, "Родители", "Parental"), "par_list"),
            cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu"),
        ],
    ]);
    BotReply::with_kb(lines.join("\n"), kb)
}

async fn handle_guest_toggle(
    toggle_iso: bool,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let label = if toggle_iso {
        candidate.guest_mode.isolate_lan = !candidate.guest_mode.isolate_lan;
        format!(
            "isolate_lan -> {}",
            status_badge(candidate.guest_mode.isolate_lan)
        )
    } else {
        candidate.guest_mode.enabled = !candidate.guest_mode.enabled;
        format!(
            "guest_mode -> {}",
            status_badge(candidate.guest_mode.enabled)
        )
    };
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!("[OK] {label}"),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_guest_view(state, Some(note)).await
}

async fn render_schedules_list(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let d = state.data.read().await.clone();
    let ru = is_ru(&d);

    let (safe_page, total_pages, start, end) = paginate(d.schedules.len(), page, PER_PAGE);
    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({}/{})",
        tr(ru, "Правила расписания", "Schedule Rules"),
        d.schedules.iter().filter(|s| s.enabled).count(),
        d.schedules.len()
    ));

    let mut rows = Vec::new();
    if d.schedules.is_empty() {
        lines.push(
            tr(
                ru,
                "Правил расписания нет.",
                "No schedule rules configured.",
            )
            .to_string(),
        );
    } else {
        for sched in &d.schedules[start..end] {
            let sname = if sched.label.trim().is_empty() {
                sched.id.as_str()
            } else {
                sched.label.trim()
            };
            let window = format!(
                "{}-{}",
                if sched.start_time.is_empty() {
                    "00:00"
                } else {
                    &sched.start_time
                },
                if sched.end_time.is_empty() {
                    "23:59"
                } else {
                    &sched.end_time
                }
            );
            let act = if sched.action.is_empty() {
                "block"
            } else {
                sched.action.as_str()
            };
            lines.push(format!(
                "{} <b>{}</b> | <code>{}</code> | {} | {}",
                status_badge(sched.enabled),
                escape_html(sname),
                escape_html(act),
                escape_html(&window),
                escape_html(&sched.days.join(","))
            ));
            rows.push(vec![cb_btn(
                &format!(
                    "{} {}",
                    status_badge(sched.enabled),
                    truncate_label(sname, 24)
                ),
                &format!("sched_tog {}", sched.id),
            )]);
        }
    }

    add_pagination_row(&mut rows, "sched_list", safe_page, total_pages);
    rows.push(vec![
        cb_btn(tr(ru, "Родители", "Parental"), "par_list"),
        cb_btn(tr(ru, "<- Меню", "<- Menu"), "menu"),
    ]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

async fn handle_schedule_toggle(
    sched_id: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(sched) = candidate.schedules.iter_mut().find(|s| s.id == sched_id) else {
        return render_schedules_list(
            state,
            0,
            Some(
                tr(
                    ru,
                    "[ERR] Правило не найдено",
                    "[ERR] Schedule rule not found",
                )
                .to_string(),
            ),
        )
        .await;
    };
    sched.enabled = !sched.enabled;
    let enabled_now = sched.enabled;
    let note = match commit_and_reload(state, core, candidate).await {
        Ok(()) => format!(
            "[OK] {} -> {}",
            escape_html(sched_id),
            status_badge(enabled_now)
        ),
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    render_schedules_list(state, 0, Some(note)).await
}

fn preview_list(items: &[String], max: usize) -> String {
    if items.len() <= max {
        items.join(", ")
    } else {
        format!("{} (+{})", items[..max].join(", "), items.len() - max)
    }
}

fn truncate_label(s: &str, max_chars: usize) -> String {
    let mut out = String::new();
    for (idx, ch) in s.chars().enumerate() {
        if idx >= max_chars {
            out.push_str("..");
            break;
        }
        out.push(ch);
    }
    out
}

trait StrFallback {
    fn if_empty_then(self, fallback: &str) -> String;
}

impl StrFallback for String {
    fn if_empty_then(self, fallback: &str) -> String {
        if self.trim().is_empty() {
            fallback.to_string()
        } else {
            self
        }
    }
}
