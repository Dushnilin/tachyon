//! Built-in Telegram Bot long-polling daemon, interactive dispatcher, and
//! diagnostic engine for `tachyon`.
//!
//! Public and `pub(crate)` API coordinates `menus`, `ops`, `transport`, `api`,
//! `ubus_bridge`, and `updater`.

pub(crate) mod fleet;
mod menus;
mod ops;
#[cfg(test)]
mod tests;
pub(crate) mod transport;

use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio::sync::Notify;

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::store::{AppState, PortableAtomicU64, RouterStoreData, unix_now_secs};
use crate::updater;

static TG_POLL_ACTIVE: AtomicBool = AtomicBool::new(false);
// 0 = follow store `d.telegram.enabled`, 1 = force stopped, 2 = force running
static TG_RUNTIME_OVERRIDE: AtomicU8 = AtomicU8::new(0);
static TG_WAKEUP_NOTIFY: Notify = Notify::const_new();
static OUTBOX_SEQ: PortableAtomicU64 = PortableAtomicU64::new(0);
static CB_TOKEN_SEQ: PortableAtomicU64 = PortableAtomicU64::new(1);
static PROMPT_SEQ: PortableAtomicU64 = PortableAtomicU64::new(1);

fn tg_outbox_dir() -> std::path::PathBuf {
    crate::store::runtime_state_dir().join("telegram-outbox")
}

pub(crate) fn tg_heartbeat_file() -> std::path::PathBuf {
    crate::store::runtime_state_dir().join("telegram.heartbeat")
}

pub(crate) fn tg_route_alert_stamp_file() -> std::path::PathBuf {
    crate::store::runtime_state_dir().join("telegram-route-alert.stamp")
}
pub(crate) const TG_OUTBOX_MAX_FILES: usize = 50;
pub(crate) const TG_POLL_TIMEOUT_SECS: u64 = 25;
pub(crate) const TG_ROUTE_ALERT_COOLDOWN_SECS: i64 = 21_600;
#[allow(dead_code)]
pub(crate) const MAX_CB_TOKENS: usize = 512;
pub(crate) const MAX_CHAT_STATES: usize = 32;
pub(crate) const CHAT_PROMPT_TTL_SECS: u64 = 600;
const MAX_SEEN_FINISHED_JOBS: usize = 64;

#[derive(Clone, Debug)]
pub(crate) struct BotDocument {
    pub filename: String,
    pub bytes: Vec<u8>,
    pub caption: String,
}

#[derive(Clone, Debug)]
pub(crate) struct BotReply {
    pub text: String,
    pub keyboard: Option<serde_json::Value>,
    pub document: Option<BotDocument>,
    pub prefer_new_message: bool,
}

impl BotReply {
    pub(crate) fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            keyboard: None,
            document: None,
            prefer_new_message: false,
        }
    }

    pub(crate) fn with_kb(text: impl Into<String>, kb: serde_json::Value) -> Self {
        Self {
            text: text.into(),
            keyboard: Some(kb),
            document: None,
            prefer_new_message: false,
        }
    }

    pub(crate) fn with_doc(
        text: impl Into<String>,
        kb: Option<serde_json::Value>,
        filename: impl Into<String>,
        bytes: Vec<u8>,
        caption: impl Into<String>,
    ) -> Self {
        Self {
            text: text.into(),
            keyboard: kb,
            document: Some(BotDocument {
                filename: filename.into(),
                bytes,
                caption: caption.into(),
            }),
            prefer_new_message: false,
        }
    }

    #[allow(dead_code)]
    pub(crate) fn new_msg(mut self) -> Self {
        self.prefer_new_message = true;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PendingPromptKind {
    AddDomainToSection { sec_id: String },
    RemoveDomainFromSection { sec_id: String },
    AddIpToSection { sec_id: String },
    UpdateFptnToken { sec_id: String },
    UpdateSourceFptnToken { src_id: String },
    AddSubscriptionOrUri,
    RouteTraceInput,
    DnsCheckInput,
    AiDoctorQuestion,
    FuzzerCustomTarget,
    CreateSnapshotName,
    ImportSnapshotPayload,
    SetRouterName,
    SetQuietHours,
    AddAdminId,
    FleetAddName,
    FleetAddUrl { name: String },
    FleetAddToken { name: String, url: String },
}

#[derive(Default)]
struct CallbackTokenStore {
    map: HashMap<String, String>,
    rev: HashMap<String, String>,
    order: VecDeque<String>,
}

fn callback_token_store() -> &'static Mutex<CallbackTokenStore> {
    static STORE: OnceLock<Mutex<CallbackTokenStore>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(CallbackTokenStore::default()))
}

struct PromptEntry {
    kind: PendingPromptKind,
    expires_at: Instant,
    seq: u64,
}

fn chat_prompt_store() -> &'static Mutex<HashMap<i64, PromptEntry>> {
    static STORE: OnceLock<Mutex<HashMap<i64, PromptEntry>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn purge_expired_prompts(map: &mut HashMap<i64, PromptEntry>, now: Instant) {
    map.retain(|_, v| v.expires_at > now);
}

pub(crate) fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
    out
}

pub(crate) fn is_ru(d: &RouterStoreData) -> bool {
    !d.telegram.language.trim().eq_ignore_ascii_case("en")
}

pub(crate) fn tr<'a>(ru: bool, ru_s: &'a str, en_s: &'a str) -> &'a str {
    if ru { ru_s } else { en_s }
}

pub(crate) fn cb_btn(label: &str, cmd: &str) -> serde_json::Value {
    if cmd.len() <= 60 {
        return json!({
            "text": label,
            "callback_data": cmd,
        });
    }

    let mut guard = callback_token_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner());

    if let Some(existing) = guard.rev.get(cmd) {
        return json!({
            "text": label,
            "callback_data": existing.clone(),
        });
    }

    while guard.map.len() >= MAX_CB_TOKENS {
        if let Some(oldest_key) = guard.order.pop_front() {
            if let Some(old_cmd) = guard.map.remove(&oldest_key) {
                guard.rev.remove(&old_cmd);
            }
        } else {
            break;
        }
    }

    let id = CB_TOKEN_SEQ.fetch_add(1, Ordering::Relaxed);
    let key = format!("@t:{id:x}");
    guard.map.insert(key.clone(), cmd.to_string());
    guard.rev.insert(cmd.to_string(), key.clone());
    guard.order.push_back(key.clone());

    json!({
        "text": label,
        "callback_data": key,
    })
}

pub(crate) fn resolve_callback_data(raw: &str) -> String {
    if raw.starts_with("@t:") {
        let guard = callback_token_store()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some(full) = guard.map.get(raw) {
            return full.clone();
        }
    }
    raw.to_string()
}

#[allow(dead_code)]
pub(crate) fn url_btn(label: &str, url: &str) -> serde_json::Value {
    json!({
        "text": label,
        "url": url,
    })
}

pub(crate) fn inline_kb(rows: Vec<Vec<serde_json::Value>>) -> serde_json::Value {
    let filtered: Vec<Vec<serde_json::Value>> =
        rows.into_iter().filter(|r| !r.is_empty()).collect();
    json!({
        "inline_keyboard": filtered,
    })
}

pub(crate) fn set_chat_prompt(chat_id: i64, kind: PendingPromptKind) {
    let now = Instant::now();
    let mut guard = chat_prompt_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    purge_expired_prompts(&mut guard, now);

    if !guard.contains_key(&chat_id)
        && guard.len() >= MAX_CHAT_STATES
        && let Some(oldest_chat) = guard
            .iter()
            .min_by_key(|(_, entry)| (entry.expires_at, entry.seq))
            .map(|(k, _)| *k)
    {
        guard.remove(&oldest_chat);
    }

    let seq = PROMPT_SEQ.fetch_add(1, Ordering::Relaxed);
    guard.insert(
        chat_id,
        PromptEntry {
            kind,
            expires_at: now + Duration::from_secs(CHAT_PROMPT_TTL_SECS),
            seq,
        },
    );
}

pub(crate) fn clear_chat_prompt(chat_id: i64) {
    let mut guard = chat_prompt_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    guard.remove(&chat_id);
}

pub(crate) fn take_chat_prompt(chat_id: i64) -> Option<PendingPromptKind> {
    let now = Instant::now();
    let mut guard = chat_prompt_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    purge_expired_prompts(&mut guard, now);
    guard.remove(&chat_id).map(|e| e.kind)
}

#[allow(dead_code)]
pub(crate) fn peek_chat_prompt(chat_id: i64) -> Option<PendingPromptKind> {
    let now = Instant::now();
    let mut guard = chat_prompt_store()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    purge_expired_prompts(&mut guard, now);
    guard.get(&chat_id).map(|e| e.kind.clone())
}

pub(crate) fn resolve_tg_proxy_url(d: &RouterStoreData, core_running: bool) -> Option<String> {
    let sec_id = d.telegram.bot_proxy_section.trim();
    if sec_id.eq_ignore_ascii_case("direct") {
        return None;
    }
    if !sec_id.is_empty()
        && let Some(sec) = d
            .sections
            .iter()
            .find(|s| s.enabled && (s.id == sec_id || s.label.eq_ignore_ascii_case(sec_id)))
    {
        if sec.mixed_proxy_enabled && sec.mixed_proxy_port > 0 && !sec.mixed_proxy_auth_enabled {
            return Some(format!("http://127.0.0.1:{}", sec.mixed_proxy_port));
        }
        if core_running {
            return Some("http://127.0.0.1:4535".to_string());
        }
        return None;
    }
    if core_running {
        Some("http://127.0.0.1:4534".to_string())
    } else {
        None
    }
}

pub(crate) fn parse_hhmm(raw: &str) -> Option<u16> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if !trimmed.contains(':') {
        if trimmed.len() <= 2 && trimmed.bytes().all(|b| b.is_ascii_digit()) {
            let h = trimmed.parse::<u16>().ok()?;
            if h < 24 {
                return Some(h * 60);
            }
        }
        return None;
    }
    let (h_s, m_s) = trimmed.split_once(':')?;
    let h_trim = h_s.trim();
    let m_trim = m_s.trim();
    if h_trim.is_empty()
        || m_trim.is_empty()
        || !h_trim.bytes().all(|b| b.is_ascii_digit())
        || !m_trim.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let h = h_trim.parse::<u16>().ok()?;
    let m = m_trim.parse::<u16>().ok()?;
    if h >= 24 || m >= 60 {
        return None;
    }
    Some(h * 60 + m)
}

pub(crate) fn is_in_quiet_hours_at(now_secs: i64, start: &str, end: &str) -> bool {
    let (Some(start_m), Some(end_m)) = (parse_hhmm(start), parse_hhmm(end)) else {
        return false;
    };
    if start_m == end_m {
        return false;
    }
    let now_m = (now_secs.rem_euclid(86400) / 60) as u16;
    if start_m < end_m {
        now_m >= start_m && now_m < end_m
    } else {
        now_m >= start_m || now_m < end_m
    }
}

fn local_secs_for_quiet_check() -> i64 {
    if let Ok(out) = std::process::Command::new("date").arg("+%H:%M").output()
        && out.status.success()
    {
        let s = String::from_utf8_lossy(&out.stdout);
        if let Some(mins) = parse_hhmm(&s) {
            return i64::from(mins) * 60;
        }
    }
    unix_now_secs()
}

pub(crate) fn is_quiet_hours_now(tg: &crate::store::TgBotConfig) -> bool {
    tg.quiet_hours_enabled
        && is_in_quiet_hours_at(
            local_secs_for_quiet_check(),
            &tg.quiet_hours_start,
            &tg.quiet_hours_end,
        )
}

pub(crate) fn is_critical_notification(kind: &str, text: &str) -> bool {
    match kind {
        "crash" | "dns_leak" | "honeypot" => true,
        "wan" => text.contains("потеря связи") || text.contains("uplink unreachable"),
        _ => false,
    }
}

pub(crate) fn should_suppress_for_quiet_hours_at(
    now_local_secs: i64,
    tg: &crate::store::TgBotConfig,
    is_critical: bool,
) -> bool {
    !is_critical
        && tg.quiet_hours_enabled
        && is_in_quiet_hours_at(now_local_secs, &tg.quiet_hours_start, &tg.quiet_hours_end)
}

pub(crate) fn is_critical_outbox_message(raw: &str, dedup_key: Option<&str>) -> bool {
    if let Some(key) = dedup_key
        && (key == "route_alert" || key.starts_with("upd_"))
    {
        return false;
    }
    raw.contains("<b>Сбой ядра:")
        || raw.contains("<b>Core Crash:")
        || raw.contains("tachyon-core</code> остановлен")
        || raw.contains("process stopped")
        || raw.contains("утечки DNS")
        || raw.contains("DNS leak")
        || raw.contains("возможна утечка DNS")
        || raw.contains("прямой маршрутизации IPv6")
        || raw.contains("<b>Honeypot:")
        || raw.contains("<b>WAN:</b> потеря связи")
        || raw.contains("<b>WAN:</b> uplink unreachable")
}

pub(crate) fn build_message_header(d: &RouterStoreData) -> String {
    let name = d.telegram.router_name.trim();
    if name.is_empty() {
        String::new()
    } else {
        format!("<b>[{}]</b>\n", escape_html(name))
    }
}

pub fn set_runtime_override(active: Option<bool>) {
    let val = match active {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    };
    TG_RUNTIME_OVERRIDE.store(val, Ordering::Release);
}

pub fn notify_bot_wakeup() {
    TG_WAKEUP_NOTIFY.notify_one();
}

pub fn is_bot_effectively_running(d: &RouterStoreData) -> bool {
    let enabled = match TG_RUNTIME_OVERRIDE.load(Ordering::Acquire) {
        1 => false,
        2 => true,
        _ => d.telegram.enabled,
    };
    enabled && !d.telegram.bot_token.trim().is_empty() && !d.telegram.admin_ids.is_empty()
}

pub async fn probe_bot_status(token: &str) -> (bool, String, String) {
    transport::probe_bot_status_via(token, None).await
}

pub async fn diagnose_bot_connection(state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let (
        enabled,
        eff_running,
        token,
        admins,
        bot_proxy_section,
        proxy_url_live,
        proxy_url_when_core_up,
        direct_fallback,
        core_running,
        ru,
        header,
    ) = {
        let d = state.data.read().await;
        let live_core = state.live.read().await.core_running
            || core.has_spawned_child().await
            || crate::sys_info::find_running_process_by_name("tachyon-core").is_some();
        (
            d.telegram.enabled,
            is_bot_effectively_running(&d),
            d.telegram.bot_token.trim().to_string(),
            d.telegram.admin_ids.clone(),
            d.telegram.bot_proxy_section.trim().to_string(),
            resolve_tg_proxy_url(&d, live_core),
            resolve_tg_proxy_url(&d, true),
            d.telegram.bot_direct_fallback,
            live_core,
            is_ru(&d),
            build_message_header(&d),
        )
    };

    let token_ok = !token.is_empty();
    let admins_ok = !admins.is_empty();
    let configured = token_ok && admins_ok;
    let is_direct_mode = bot_proxy_section.eq_ignore_ascii_case("direct");

    let target_port = proxy_url_when_core_up
        .as_deref()
        .and_then(|u| u.rsplit(':').next())
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(4534);

    let proxy_desc = proxy_url_live.clone().unwrap_or_else(|| {
        if is_direct_mode {
            "direct".to_string()
        } else {
            "none".to_string()
        }
    });

    let port_fut = async {
        if is_direct_mode {
            (
                true,
                "Direct WAN route configured (no local proxy port needed)".to_string(),
            )
        } else {
            match tokio::time::timeout(
                Duration::from_millis(500),
                TcpStream::connect(("127.0.0.1", target_port)),
            )
            .await
            {
                Ok(Ok(_)) => {
                    let msg = match target_port {
                        4534 => "Proxy port 4534 is listening".to_string(),
                        4535 => "Proxy port 4535 is listening".to_string(),
                        p => format!("Proxy port {p} is listening"),
                    };
                    (true, msg)
                }
                _ => (false, "Local proxy port is not listening".to_string()),
            }
        }
    };

    let dns_fut = async {
        if let Ok(Ok(mut addrs)) = tokio::time::timeout(
            Duration::from_secs(3),
            tokio::net::lookup_host("api.telegram.org:443"),
        )
        .await
        {
            addrs.next().is_some()
        } else {
            false
        }
    };

    let direct_fut = async {
        if token_ok {
            probe_bot_status(&token).await
        } else {
            (false, String::new(), "Bot token is missing".to_string())
        }
    };

    let proxy_fut = async {
        if !token_ok || is_direct_mode || proxy_url_live.is_none() {
            (false, String::new(), String::new())
        } else {
            transport::probe_bot_status_via(&token, proxy_url_live.as_deref()).await
        }
    };

    let ((port_ok, port_msg), dns_ok, (direct_ok, direct_uname, _), (proxy_ok, proxy_uname, _)) =
        tokio::join!(port_fut, dns_fut, direct_fut, proxy_fut);

    let bot_username = if !proxy_uname.is_empty() {
        proxy_uname
    } else {
        direct_uname
    };

    let (test_msg_ok, test_msg_text) = if !admins_ok {
        (
            false,
            "No admin_ids set — cannot send test message".to_string(),
        )
    } else if !token_ok || !(proxy_ok || (direct_fallback && direct_ok)) {
        (
            false,
            "Failed to send test message — check admin_ids and bot permissions".to_string(),
        )
    } else {
        let send_proxy = if proxy_ok || !direct_fallback {
            proxy_url_live.as_deref()
        } else {
            None
        };
        let ping_body = tr(
            ru,
            "[OK] Диагностика Telegram-бота: связь подтверждена.",
            "[OK] Telegram bot diagnostic check passed.",
        );
        let ping_msg = format!("{header}{ping_body}");
        let mut sent = 0usize;
        for &cid in &admins {
            if transport::send_tg_message(
                &token,
                cid,
                &ping_msg,
                None,
                false,
                send_proxy,
                direct_fallback,
            )
            .await
            .is_ok()
            {
                sent += 1;
            }
        }
        if sent > 0 {
            (true, "Test message sent to chat".to_string())
        } else {
            (
                false,
                "Failed to send test message — check admin_ids and bot permissions".to_string(),
            )
        }
    };

    let proxy_check = if is_direct_mode {
        json!({
            "name": "proxy_api",
            "ok": true,
            "message": "Direct WAN route configured (no local proxy port needed)",
        })
    } else {
        json!({
            "name": "proxy_api",
            "ok": proxy_ok,
            "message": if proxy_ok {
                "Proxy route to Telegram API works"
            } else {
                "Proxy route to Telegram API failed — check proxy outbound config"
            },
        })
    };

    let checks = vec![
        json!({
            "name": "token",
            "ok": token_ok,
            "message": if token_ok { "Bot token is configured" } else { "Bot token is missing" },
        }),
        json!({
            "name": "admin_ids",
            "ok": admins_ok,
            "count": admins.len(),
            "message": if admins_ok { "Admin Chat IDs configured" } else { "No admin_ids configured" },
        }),
        json!({
            "name": "core",
            "ok": core_running,
            "message": if core_running {
                "Tachyon Core is running"
            } else {
                "Tachyon Core is NOT running — bot cannot route through proxy"
            },
        }),
        json!({
            "name": "proxy_port",
            "ok": port_ok,
            "message": port_msg,
        }),
        json!({
            "name": "dns",
            "ok": dns_ok,
            "message": if dns_ok {
                "DNS resolves api.telegram.org"
            } else {
                "DNS cannot resolve api.telegram.org — check DNS settings"
            },
        }),
        json!({
            "name": "direct_api",
            "ok": direct_ok,
            "message": if direct_ok {
                "Direct IPv4 to Telegram API works"
            } else if token_ok {
                "Cannot reach Telegram API directly (IPv4 blocked by ISP?)"
            } else {
                "Direct API connection failed"
            },
        }),
        proxy_check,
        json!({
            "name": "test_message",
            "ok": test_msg_ok,
            "message": test_msg_text,
        }),
    ];

    let overall_ok = token_ok && admins_ok && (proxy_ok || direct_ok) && test_msg_ok;

    json!({
        "ok": overall_ok,
        "success": overall_ok,
        "enabled": enabled,
        "running": eff_running,
        "configured": configured,
        "bot_username": bot_username,
        "proxy_url": proxy_desc,
        "status": if eff_running { "running" } else { "stopped" },
        "checks": checks,
    })
}

pub(crate) fn parse_outbox_sort_key(name: &str) -> (u64, u64, &str) {
    let stem = name
        .strip_suffix(".txt")
        .or_else(|| name.strip_suffix(".json"))
        .unwrap_or(name);
    if let Some((ts_str, seq_str)) = stem.split_once('_')
        && let (Ok(ts), Ok(seq)) = (ts_str.parse::<u64>(), seq_str.parse::<u64>())
    {
        return (ts, seq, name);
    }
    (0, 0, name)
}

pub(crate) fn bot_id_from_token(token: &str) -> String {
    token
        .trim()
        .split(':')
        .next()
        .unwrap_or("")
        .trim()
        .to_string()
}

fn default_outbox_parse_mode() -> String {
    "HTML".to_string()
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub(crate) struct OutboxJsonNotice {
    pub bot_id: String,
    pub chat_id: i64,
    pub text: String,
    #[serde(default = "default_outbox_parse_mode")]
    pub parse_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dedup_key: Option<String>,
    pub created_at: i64,
}

fn set_private_dir_mode(dir: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    #[cfg(not(unix))]
    let _ = dir;
}

fn list_outbox_entries(dir: &std::path::Path) -> Vec<(String, std::path::PathBuf)> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut entries: Vec<(String, std::path::PathBuf)> = rd
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            let name = path.file_name()?.to_str()?.to_string();
            if (name.ends_with(".txt") || name.ends_with(".json")) && path.is_file() {
                Some((name, path))
            } else {
                None
            }
        })
        .collect();
    entries.sort_by(|a, b| parse_outbox_sort_key(&a.0).cmp(&parse_outbox_sort_key(&b.0)));
    entries
}

pub fn enforce_outbox_limit(dir: &std::path::Path, max_files: usize) {
    let entries = list_outbox_entries(dir);
    if entries.len() <= max_files {
        return;
    }
    let excess = entries.len() - max_files;
    for (_, old_path) in entries.into_iter().take(excess) {
        let _ = std::fs::remove_file(old_path);
    }
}

pub(crate) fn submit_outbox_notice_in(
    dir: &std::path::Path,
    token: &str,
    chat_id: i64,
    text: &str,
    dedup_key: Option<&str>,
) -> anyhow::Result<std::path::PathBuf> {
    if text.trim().is_empty() {
        anyhow::bail!("Empty outbox notice");
    }
    let bot_id = bot_id_from_token(token);
    if bot_id.is_empty() || chat_id == 0 {
        anyhow::bail!("Invalid Telegram bot ID or chat ID for outbox");
    }
    std::fs::create_dir_all(dir)?;
    set_private_dir_mode(dir);

    let dedup = dedup_key
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);
    let now = unix_now_secs();
    let payload = OutboxJsonNotice {
        bot_id: bot_id.clone(),
        chat_id,
        text: text.to_string(),
        parse_mode: "HTML".to_string(),
        dedup_key: dedup.clone(),
        created_at: now,
    };
    let serialized = serde_json::to_vec(&payload)?;

    let entries = list_outbox_entries(dir);
    if let Some(ref dk) = dedup {
        for (name, existing_path) in &entries {
            if !name.ends_with(".json") {
                continue;
            }
            if let Ok(raw) = std::fs::read(existing_path)
                && let Ok(existing) = serde_json::from_slice::<OutboxJsonNotice>(&raw)
                && existing.bot_id == bot_id
                && existing.chat_id == chat_id
                && existing.dedup_key.as_deref() == Some(dk.as_str())
            {
                std::fs::write(existing_path, serialized)?;
                return Ok(existing_path.clone());
            }
        }
    }

    if entries.len() >= TG_OUTBOX_MAX_FILES {
        anyhow::bail!("Telegram outbox full ({} items)", entries.len());
    }

    let seq = OUTBOX_SEQ.fetch_add(1, Ordering::Relaxed);
    let path = dir.join(format!("{now}_{seq}.json"));
    std::fs::write(&path, serialized)?;
    Ok(path)
}

pub(crate) fn write_heartbeat_to(path: &std::path::Path, now_secs: i64) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
        set_private_dir_mode(parent);
    }
    let body = serde_json::json!({
        "ts": now_secs,
        "version": crate::store::TACHYON_VERSION,
    })
    .to_string();
    let _ = std::fs::write(path, body);
}

pub(crate) async fn sleep_with_heartbeat_to(mut remaining_secs: u64, hb_path: &std::path::Path) {
    if remaining_secs == 0 {
        return;
    }
    while remaining_secs > 0 {
        write_heartbeat_to(hb_path, unix_now_secs());
        let chunk = remaining_secs.min(15);
        tokio::select! {
            _ = TG_WAKEUP_NOTIFY.notified() => {
                return;
            }
            _ = tokio::time::sleep(Duration::from_secs(chunk)) => {}
        }
        remaining_secs -= chunk;
    }
    write_heartbeat_to(hb_path, unix_now_secs());
}

async fn sleep_with_heartbeat(secs: u64) {
    let hb = tg_heartbeat_file();
    sleep_with_heartbeat_to(secs, &hb).await;
}

pub(crate) fn route_alert_recent(
    stamp_path: &std::path::Path,
    now_secs: i64,
    cooldown_secs: i64,
) -> bool {
    let Ok(raw) = std::fs::read_to_string(stamp_path) else {
        return false;
    };
    let Ok(last_ts) = raw.trim().parse::<i64>() else {
        return false;
    };
    now_secs >= last_ts && (now_secs - last_ts) < cooldown_secs.max(0)
}

pub(crate) struct RouteAlertParams<'a> {
    pub token: &'a str,
    pub admins: &'a [i64],
    pub header: &'a str,
    pub ru: bool,
    pub failures: u32,
    pub direct_fallback: bool,
    pub quiet_enabled: bool,
    pub quiet_start: &'a str,
    pub quiet_end: &'a str,
    pub now_utc_secs: i64,
    pub local_now_secs: i64,
    pub outbox_dir: &'a std::path::Path,
    pub stamp_path: &'a std::path::Path,
    pub cooldown_secs: i64,
}

pub(crate) fn maybe_alert_route_failure_at(params: &RouteAlertParams<'_>) -> bool {
    if params.token.trim().is_empty() || params.admins.is_empty() {
        return false;
    }
    if params.quiet_enabled
        && is_in_quiet_hours_at(params.local_now_secs, params.quiet_start, params.quiet_end)
    {
        return false;
    }
    if route_alert_recent(params.stamp_path, params.now_utc_secs, params.cooldown_secs) {
        return true;
    }

    let body = if params.ru {
        format!(
            "{}<b>Предупреждение маршрута Telegram-бота</b>\n\
             Не удалось подключиться к Telegram API за {} попыток подряд ({}).\n\
             Проверьте секцию прокси для бота или доступность сети.",
            params.header,
            params.failures,
            if params.direct_fallback {
                "резервный прямой маршрут активен"
            } else {
                "прямой резервный маршрут отключён"
            }
        )
    } else {
        format!(
            "{}<b>Telegram bot route warning</b>\n\
             Failed to reach Telegram API after {} consecutive poll attempts ({}).\n\
             Check the bot proxy section or upstream network reachability.",
            params.header,
            params.failures,
            if params.direct_fallback {
                "direct fallback enabled"
            } else {
                "direct fallback disabled"
            }
        )
    };

    let mut any_queued = false;
    for &admin_id in params.admins {
        if submit_outbox_notice_in(
            params.outbox_dir,
            params.token,
            admin_id,
            &body,
            Some("route_alert"),
        )
        .is_ok()
        {
            any_queued = true;
        }
    }
    if any_queued {
        if let Some(parent) = params.stamp_path.parent() {
            let _ = std::fs::create_dir_all(parent);
            set_private_dir_mode(parent);
        }
        let _ = std::fs::write(params.stamp_path, params.now_utc_secs.to_string());
    }
    any_queued
}

pub(crate) fn submit_update_available_notice(
    d: &crate::store::RouterStoreData,
    comp: &str,
    current: &str,
    latest: &str,
) {
    let token = d.telegram.bot_token.trim();
    if !d.telegram.enabled
        || !d.telegram.notify_update_available
        || token.is_empty()
        || d.telegram.admin_ids.is_empty()
        || latest.trim().is_empty()
        || is_quiet_hours_now(&d.telegram)
    {
        return;
    }
    let ru = is_ru(d);
    let text = if ru {
        format!(
            "Доступно обновление <b>{}</b>: <code>{}</code> -> <code>{}</code>",
            escape_html(comp),
            escape_html(current),
            escape_html(latest)
        )
    } else {
        format!(
            "Update available for <b>{}</b>: <code>{}</code> -> <code>{}</code>",
            escape_html(comp),
            escape_html(current),
            escape_html(latest)
        )
    };
    let outbox_dir = tg_outbox_dir();
    let dedup = format!("upd_{comp}_{latest}");
    let mut queued = false;
    for &cid in &d.telegram.admin_ids {
        if submit_outbox_notice_in(&outbox_dir, token, cid, &text, Some(&dedup)).is_ok() {
            queued = true;
        }
    }
    if queued {
        notify_bot_wakeup();
    }
}

pub(crate) fn should_emit_notification_at(
    d: &crate::store::RouterStoreData,
    kind: &str,
    text: &str,
    local_now_secs: i64,
) -> bool {
    if !d.telegram.enabled || text.trim().is_empty() {
        return false;
    }
    let enabled = match kind {
        "crash" => d.telegram.notify_crash,
        "restart" => d.telegram.notify_restart,
        "server_switch" => d.telegram.notify_server_switch,
        "failover" => d.telegram.notify_failover,
        "wan" => d.telegram.notify_wan,
        "dns_leak" => d.telegram.notify_dns_leak,
        "subscription" => d.telegram.notify_subscription,
        "parental" => d.telegram.notify_parental,
        "cert" => d.telegram.notify_cert,
        "honeypot" => d.telegram.notify_honeypot,
        "smart_detect" => d.telegram.notify_smart_detect,
        "auto_update" => d.telegram.notify_auto_update,
        _ => false,
    };
    if !enabled {
        return false;
    }
    !should_suppress_for_quiet_hours_at(
        local_now_secs,
        &d.telegram,
        is_critical_notification(kind, text),
    )
}

pub fn notify_if_enabled(d: &crate::store::RouterStoreData, kind: &str, text: &str) {
    if !d.telegram.enabled || text.trim().is_empty() {
        return;
    }
    let local_secs = if d.telegram.quiet_hours_enabled && !is_critical_notification(kind, text) {
        local_secs_for_quiet_check()
    } else {
        0
    };
    if should_emit_notification_at(d, kind, text, local_secs) {
        queue_or_send_notification(text);
    }
}

pub(crate) fn queue_plain_outbox_notice_in(outbox_dir: &std::path::Path, text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    let _ = std::fs::create_dir_all(outbox_dir);
    if let Ok(entries) = std::fs::read_dir(outbox_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("txt") {
                continue;
            }
            if let Ok(existing) = std::fs::read_to_string(&path)
                && existing.trim() == trimmed
            {
                return false;
            }
        }
    }
    let now = unix_now_secs();
    let seq = OUTBOX_SEQ.fetch_add(1, Ordering::Relaxed);
    let path = outbox_dir.join(format!("{now}_{seq}.txt"));
    if std::fs::write(path, text).is_err() {
        return false;
    }
    enforce_outbox_limit(outbox_dir, TG_OUTBOX_MAX_FILES);
    true
}

pub fn queue_or_send_notification(text: impl Into<String>) {
    let msg = text.into();
    let outbox = tg_outbox_dir();
    if queue_plain_outbox_notice_in(&outbox, &msg) {
        notify_bot_wakeup();
    }
}

fn format_outbox_html(raw: &str, header: &str) -> String {
    let trimmed = raw.trim();
    let looks_html = trimmed.contains("<b>")
        || trimmed.contains("<code>")
        || trimmed.contains("<pre>")
        || trimmed.contains("<i>");
    let body = if looks_html {
        trimmed.to_string()
    } else {
        escape_html(trimmed)
    };
    if header.is_empty() || body.starts_with(header) || body.starts_with("<b>[") {
        body
    } else {
        format!("{header}{body}")
    }
}

async fn drain_telegram_outbox(
    token: &str,
    admins: &[i64],
    header: &str,
    quiet_now: bool,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) {
    let current_bot_id = bot_id_from_token(token);
    let outbox = tg_outbox_dir();
    let entries = list_outbox_entries(&outbox);

    for (name, path) in entries {
        let Ok(raw_text) = std::fs::read_to_string(&path) else {
            let _ = std::fs::remove_file(&path);
            continue;
        };
        if raw_text.trim().is_empty() {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        if name.ends_with(".json") {
            let Ok(notice) = serde_json::from_str::<OutboxJsonNotice>(&raw_text) else {
                let _ = std::fs::remove_file(&path);
                continue;
            };
            if current_bot_id.is_empty() || notice.bot_id != current_bot_id || notice.chat_id == 0 {
                continue;
            }
            let critical = is_critical_outbox_message(&notice.text, notice.dedup_key.as_deref());
            if quiet_now && !critical {
                let _ = std::fs::remove_file(&path);
                continue;
            }
            if transport::send_tg_message(
                token,
                notice.chat_id,
                &notice.text,
                None,
                false,
                proxy_url,
                direct_fallback,
            )
            .await
            .is_ok()
            {
                let _ = std::fs::remove_file(&path);
            } else {
                break;
            }
            continue;
        }
        if quiet_now && !is_critical_outbox_message(&raw_text, None) {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        let html = format_outbox_html(&raw_text, header);
        let mut any_ok = false;
        for &chat_id in admins {
            if transport::send_tg_message(
                token,
                chat_id,
                &html,
                None,
                false,
                proxy_url,
                direct_fallback,
            )
            .await
            .is_ok()
            {
                any_ok = true;
            }
        }
        if any_ok {
            let _ = std::fs::remove_file(&path);
        } else {
            break;
        }
    }
}

pub async fn send_test_notification(state: &Arc<AppState>) -> anyhow::Result<usize> {
    let (token, admins, proxy_opt, direct_fallback, header, ru) = {
        let d = state.data.read().await;
        let core_running = state.live.read().await.core_running;
        (
            d.telegram.bot_token.trim().to_string(),
            d.telegram.admin_ids.clone(),
            resolve_tg_proxy_url(&d, core_running),
            d.telegram.bot_direct_fallback,
            build_message_header(&d),
            is_ru(&d),
        )
    };
    if token.is_empty() || admins.is_empty() {
        anyhow::bail!(
            "{}",
            tr(
                ru,
                "Укажите Bot Token и хотя бы один Admin ID в настройках Telegram",
                "Set Bot Token and at least one Admin ID in Telegram settings",
            )
        );
    }

    let body = tr(
        ru,
        "<b>Tachyon Router: Тестовое уведомление</b>\nСвязь с роутером установлена.",
        "<b>Tachyon Router: Test Notification</b>\nConnection to router is working.",
    );
    let text = format!("{header}{body}");
    let mut sent = 0usize;
    let mut last_err: Option<anyhow::Error> = None;
    for chat_id in admins {
        match transport::send_tg_message(
            &token,
            chat_id,
            &text,
            None,
            false,
            proxy_opt.as_deref(),
            direct_fallback,
        )
        .await
        {
            Ok(()) => sent += 1,
            Err(e) => last_err = Some(e),
        }
    }
    if sent == 0
        && let Some(err) = last_err
    {
        return Err(err);
    }
    Ok(sent)
}

fn split_cmd_arg(raw: &str) -> (&str, &str) {
    let trimmed = raw.trim();
    if let Some(pos) = trimmed.find(char::is_whitespace) {
        (&trimmed[..pos], trimmed[pos..].trim())
    } else {
        (trimmed, "")
    }
}

fn strip_bot_mention(cmd: &str) -> &str {
    if cmd.starts_with('/') {
        cmd.split('@').next().unwrap_or(cmd)
    } else {
        cmd
    }
}

fn looks_like_transfer_payload(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.len() >= 12
        && (trimmed
            .get(..14)
            .is_some_and(|p| p.eq_ignore_ascii_case("tachyon://rs2/"))
            || trimmed
                .get(..8)
                .is_some_and(|p| p.eq_ignore_ascii_case("TACHYON-")))
}

fn looks_like_proxy_uri(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.starts_with('{') && crate::config_gen::decode_fptn_token_json(trimmed).is_some() {
        return true;
    }
    let Some(first_line) = trimmed.lines().map(str::trim).find(|l| !l.is_empty()) else {
        return false;
    };
    let lower = first_line.to_ascii_lowercase();
    const PREFIXES: [&str; 16] = [
        "vless://",
        "vmess://",
        "trojan://",
        "ss://",
        "hy2://",
        "hysteria2://",
        "tuic://",
        "mierus://",
        "mieru://",
        "wg://",
        "awg://",
        "fptn:",
        "fptn//",
        "fptnb:",
        "fptnb//",
        "https://",
    ];
    PREFIXES.iter().any(|p| lower.starts_with(p))
}

fn dispatch_command_or_callback<'a>(
    cmd: &'a str,
    arg: &'a str,
    chat_id: i64,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Pin<Box<dyn Future<Output = BotReply> + Send + 'a>> {
    Box::pin(async move {
        if let Some(reply) = Box::pin(menus::try_handle_menu(cmd, arg, chat_id, state, core)).await
        {
            return reply;
        }
        if let Some(reply) = Box::pin(ops::try_handle_ops(cmd, arg, chat_id, state, core)).await {
            return reply;
        }
        let ru = {
            let d = state.data.read().await;
            is_ru(&d)
        };
        let msg = tr(
            ru,
            "Неизвестная команда. Нажмите /start для открытия главного меню.",
            "Unknown command. Send /start to open the main menu.",
        );
        let kb = inline_kb(vec![vec![cb_btn(
            tr(ru, "Главное меню", "Main Menu"),
            "/start",
        )]]);
        BotReply::with_kb(msg, kb)
    })
}

fn dispatch_text_message<'a>(
    chat_id: i64,
    raw_text: &'a str,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Pin<Box<dyn Future<Output = BotReply> + Send + 'a>> {
    Box::pin(async move {
        let text = raw_text.trim();
        if text.is_empty() {
            return dispatch_command_or_callback("/start", "", chat_id, state, core).await;
        }

        let (first_tok, rest_arg) = split_cmd_arg(text);
        let cmd_clean = strip_bot_mention(first_tok);
        let cmd_lower = if cmd_clean.starts_with('/') {
            cmd_clean.to_ascii_lowercase()
        } else {
            cmd_clean.to_string()
        };

        if cmd_lower == "/cancel" {
            clear_chat_prompt(chat_id);
            return dispatch_command_or_callback("/start", "", chat_id, state, core).await;
        }
        if matches!(cmd_lower.as_str(), "/start" | "/menu" | "/help") {
            clear_chat_prompt(chat_id);
            return dispatch_command_or_callback(&cmd_lower, rest_arg, chat_id, state, core).await;
        }
        if first_tok.starts_with('/') && first_tok.len() > 1 && !first_tok[1..].contains('/') {
            clear_chat_prompt(chat_id);
            return dispatch_command_or_callback(&cmd_lower, rest_arg, chat_id, state, core).await;
        }

        if let Some(prompt_kind) = take_chat_prompt(chat_id) {
            if let Some(reply) = Box::pin(menus::handle_menu_prompt(
                prompt_kind.clone(),
                text,
                chat_id,
                state,
                core,
            ))
            .await
            {
                return reply;
            }
            if let Some(reply) = Box::pin(ops::handle_ops_prompt(
                prompt_kind,
                text,
                chat_id,
                state,
                core,
            ))
            .await
            {
                return reply;
            }
        }

        if !text.starts_with('/') {
            if looks_like_transfer_payload(text)
                && let Some(reply) = Box::pin(ops::try_handle_ops(
                    "quick_import",
                    text,
                    chat_id,
                    state,
                    core,
                ))
                .await
            {
                return reply;
            }
            if looks_like_proxy_uri(text)
                && let Some(reply) = Box::pin(menus::try_handle_menu(
                    "quick_add_uri",
                    text,
                    chat_id,
                    state,
                    core,
                ))
                .await
            {
                return reply;
            }
        }

        dispatch_command_or_callback(&cmd_lower, rest_arg, chat_id, state, core).await
    })
}

fn dispatch_callback_query<'a>(
    chat_id: i64,
    raw_data: &'a str,
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> Pin<Box<dyn Future<Output = BotReply> + Send + 'a>> {
    Box::pin(async move {
        let resolved = resolve_callback_data(raw_data);
        let trimmed = resolved.trim();
        if trimmed.is_empty() {
            return dispatch_command_or_callback("/start", "", chat_id, state, core).await;
        }

        if trimmed.starts_with("srv:select:")
            || trimmed.starts_with("rule:toggle:")
            || trimmed.starts_with("fix:apply:")
        {
            return dispatch_command_or_callback(trimmed, "", chat_id, state, core).await;
        }

        let (first_tok, rest_arg) = split_cmd_arg(trimmed);
        let cmd_clean = strip_bot_mention(first_tok);
        let cmd_norm = if cmd_clean.starts_with('/') {
            cmd_clean.to_ascii_lowercase()
        } else {
            cmd_clean.to_string()
        };

        if matches!(cmd_norm.as_str(), "/start" | "/menu" | "menu") {
            clear_chat_prompt(chat_id);
        }

        dispatch_command_or_callback(&cmd_norm, rest_arg, chat_id, state, core).await
    })
}

#[allow(dead_code)]
pub(crate) async fn handle_incoming_text(
    chat_id: i64,
    text: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let authorized = {
        let d = state.data.read().await;
        d.telegram.admin_ids.contains(&chat_id)
    };
    if !authorized {
        return None;
    }
    Some(dispatch_text_message(chat_id, text, state, core).await)
}

#[allow(dead_code)]
pub(crate) async fn handle_incoming_callback(
    chat_id: i64,
    raw_data: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<BotReply> {
    let authorized = {
        let d = state.data.read().await;
        d.telegram.admin_ids.contains(&chat_id)
    };
    if !authorized {
        return None;
    }
    Some(dispatch_callback_query(chat_id, raw_data, state, core).await)
}

fn prepend_header_if_missing(text: &str, header: &str) -> String {
    if header.is_empty() || text.is_empty() || text.starts_with(header) || text.starts_with("<b>[")
    {
        text.to_string()
    } else {
        format!("{header}{text}")
    }
}

async fn deliver_bot_reply(
    token: &str,
    chat_id: i64,
    edit_message_id: Option<i64>,
    reply: BotReply,
    header: &str,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) {
    let final_text = prepend_header_if_missing(&reply.text, header);
    let kb_ref = reply.keyboard.as_ref();

    if let Some(doc) = reply.document {
        let caption_src = if doc.caption.trim().is_empty() {
            &final_text
        } else {
            &doc.caption
        };
        let caption = prepend_header_if_missing(caption_src, header);
        let text_differs = !final_text.trim().is_empty()
            && !doc.caption.trim().is_empty()
            && final_text.trim() != caption.trim();

        if text_differs {
            if let Some(mid) = edit_message_id.filter(|_| !reply.prefer_new_message) {
                let _ = transport::edit_tg_message(
                    token,
                    chat_id,
                    mid,
                    &final_text,
                    None,
                    proxy_url,
                    direct_fallback,
                )
                .await;
            } else {
                let _ = transport::send_tg_message(
                    token,
                    chat_id,
                    &final_text,
                    None,
                    false,
                    proxy_url,
                    direct_fallback,
                )
                .await;
            }
        }

        let tg_doc = transport::TgDocument {
            filename: &doc.filename,
            bytes: &doc.bytes,
            caption: &caption,
            keyboard: kb_ref,
            disable_notification: false,
        };
        if let Err(err) =
            transport::send_tg_document(token, chat_id, &tg_doc, proxy_url, direct_fallback).await
        {
            let fallback = format!(
                "{final_text}\n\n[!] Upload error: {}",
                escape_html(&err.to_string())
            );
            let _ = transport::send_tg_message(
                token,
                chat_id,
                &fallback,
                kb_ref,
                false,
                proxy_url,
                direct_fallback,
            )
            .await;
        }
        return;
    }

    if let Some(mid) = edit_message_id.filter(|_| !reply.prefer_new_message) {
        let _ = transport::edit_tg_message(
            token,
            chat_id,
            mid,
            &final_text,
            kb_ref,
            proxy_url,
            direct_fallback,
        )
        .await;
    } else {
        let _ = transport::send_tg_message(
            token,
            chat_id,
            &final_text,
            kb_ref,
            false,
            proxy_url,
            direct_fallback,
        )
        .await;
    }
}

async fn sleep_or_wakeup(secs: u64) {
    if secs == 0 {
        return;
    }
    tokio::select! {
        _ = TG_WAKEUP_NOTIFY.notified() => {}
        _ = tokio::time::sleep(Duration::from_secs(secs)) => {}
    }
}

struct JobNotifyCtx<'a> {
    token: &'a str,
    admins: &'a [i64],
    header: &'a str,
    ru: bool,
    quiet_now: bool,
    notify_auto_update: bool,
    proxy_url: Option<&'a str>,
    direct_fallback: bool,
}

async fn check_and_notify_finished_jobs(
    prev_active_jobs: &mut HashSet<String>,
    seen_finished_jobs: &mut VecDeque<String>,
    ctx: &JobNotifyCtx<'_>,
) {
    let current_active: HashSet<String> = updater::active_component_job_ids().into_iter().collect();
    for finished_id in prev_active_jobs.difference(&current_active) {
        if seen_finished_jobs.iter().any(|s| s == finished_id) {
            continue;
        }
        let st = updater::read_job_status(finished_id);
        if st.get("running").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        if seen_finished_jobs.len() >= MAX_SEEN_FINISHED_JOBS {
            seen_finished_jobs.pop_front();
        }
        seen_finished_jobs.push_back(finished_id.clone());

        let action = st.get("action").and_then(Value::as_str).unwrap_or("");
        if action == "check" || action == "check_update" {
            continue;
        }
        if !ctx.notify_auto_update || ctx.quiet_now {
            continue;
        }

        let comp = st
            .get("component")
            .and_then(Value::as_str)
            .unwrap_or("component");
        let disp = updater::component_display_name(comp);
        let ok = st.get("success").and_then(Value::as_bool).unwrap_or(false);
        let raw_msg = st.get("message").and_then(Value::as_str).unwrap_or(if ok {
            "Completed"
        } else {
            "Failed"
        });
        let safe_msg = escape_html(&crypto_gen::redact_string(raw_msg));
        let tag = if ok { "[OK]" } else { "[!]" };
        let title = if ctx.ru {
            format!(
                "{tag} Задача обновления <b>{}</b> ({})",
                escape_html(disp),
                escape_html(action)
            )
        } else {
            format!(
                "{tag} Update job <b>{}</b> ({})",
                escape_html(disp),
                escape_html(action)
            )
        };
        let text = format!("{}{title}\n{safe_msg}", ctx.header);
        for &cid in ctx.admins {
            let _ = transport::send_tg_message(
                ctx.token,
                cid,
                &text,
                None,
                ctx.quiet_now,
                ctx.proxy_url,
                ctx.direct_fallback,
            )
            .await;
        }
    }
    *prev_active_jobs = current_active;
}

const SEEN_EVENT_KEY_CAP: usize = crate::store::MAX_EVENTS_RING * 4;
const SEEN_HONEYPOT_KEY_CAP: usize = 512;

#[derive(Default)]
pub(crate) struct BotEventObserver {
    initialized: bool,
    seen_event_keys: VecDeque<String>,
    seen_honeypot_keys: VecDeque<String>,
    last_seen_event_seq: u64,
    last_core_pid: Option<u32>,
    last_core_running: bool,
    last_wan_healthy: bool,
    last_dns_healthy: bool,
    section_active_nodes: HashMap<String, String>,
    clash_active_nodes: HashMap<String, String>,
    sub_state: HashMap<String, (i64, String)>,
    parental_blocked: HashMap<String, bool>,
    smart_detect_domain_count: usize,
    last_clash_poll_unix: i64,
    last_cert_check_unix: i64,
    warned_cert_paths: HashSet<String>,
    pub(crate) last_crash_alerts: HashMap<String, i64>,
    pub(crate) last_restart_alerts: HashMap<String, i64>,
    pub(crate) last_switch_alerts: HashMap<String, (i64, u32)>,
}

impl BotEventObserver {
    fn should_emit_rate_limited(
        map: &mut HashMap<String, i64>,
        key: &str,
        now: i64,
        cooldown_secs: i64,
    ) -> bool {
        map.retain(|_, ts| now.saturating_sub(*ts) < cooldown_secs);
        if let Some(&last_ts) = map.get(key)
            && now.saturating_sub(last_ts) < cooldown_secs
        {
            return false;
        }
        if map.len() >= 64 {
            map.clear();
        }
        map.insert(key.to_string(), now);
        true
    }

    pub(crate) fn should_emit_crash_alert(&mut self, key: &str, now: i64) -> bool {
        Self::should_emit_rate_limited(&mut self.last_crash_alerts, key, now, 300)
    }

    pub(crate) fn should_emit_restart_alert(&mut self, key: &str, now: i64) -> bool {
        Self::should_emit_rate_limited(&mut self.last_restart_alerts, key, now, 300)
    }
}

pub(crate) fn collect_section_store_switch_notifications(
    obs: &mut BotEventObserver,
    d: &RouterStoreData,
    ru: bool,
) -> (HashSet<String>, Vec<(&'static str, String)>) {
    let mut switched_sections = HashSet::new();
    let mut notices = Vec::new();
    let tag_map = crate::ubus_bridge::build_telemetry_tag_display_map(d);
    for sec in &d.sections {
        if !sec.active_selected_tag.is_empty()
            && obs
                .section_active_nodes
                .get(&sec.id)
                .is_some_and(|prev| prev != &sec.active_selected_tag)
        {
            let sec_label = if !sec.label.trim().is_empty() {
                sec.label.trim()
            } else {
                sec.id.as_str()
            };
            let node_label = crate::ubus_bridge::resolve_telemetry_tag_display_name(
                &sec.active_selected_tag,
                &tag_map,
                d,
            );
            let txt = if ru {
                format!(
                    "<b>Смена узла:</b> секция <b>{}</b> -> <code>{}</code>",
                    escape_html(sec_label),
                    escape_html(&node_label)
                )
            } else {
                format!(
                    "<b>Server Switch:</b> section <b>{}</b> -> <code>{}</code>",
                    escape_html(sec_label),
                    escape_html(&node_label)
                )
            };
            switched_sections.insert(sec.id.clone());
            notices.push(("server_switch", txt));
        }
        if !sec.active_selected_tag.is_empty() {
            obs.section_active_nodes
                .insert(sec.id.clone(), sec.active_selected_tag.clone());
        }
    }
    (switched_sections, notices)
}

fn is_per_flow_balancer_group(d: &RouterStoreData, sec_id: &str, group_tag: &str) -> bool {
    let prefix = format!("bal-{sec_id}-");
    let Some(bal_id) = group_tag.strip_prefix(&prefix) else {
        return false;
    };
    let Some(bal) = d.balancers.iter().find(|b| b.id == bal_id) else {
        return false;
    };
    matches!(
        bal.mode.trim().to_ascii_lowercase().as_str(),
        "sticky"
            | "round_robin"
            | "random"
            | "least_load"
            | "least_connections"
            | "weighted"
            | "hedged"
            | "throughput"
            | "quota"
    )
}

#[cfg(test)]
pub(crate) fn collect_clash_node_switch_notifications(
    obs: &mut BotEventObserver,
    d: &RouterStoreData,
    px_map: &serde_json::Map<String, Value>,
    store_switched_sections: &HashSet<String>,
    ru: bool,
) -> Vec<(&'static str, String)> {
    collect_clash_node_switch_notifications_at(
        obs,
        d,
        px_map,
        store_switched_sections,
        ru,
        unix_now_secs(),
    )
}

pub(crate) fn collect_clash_node_switch_notifications_at(
    obs: &mut BotEventObserver,
    d: &RouterStoreData,
    px_map: &serde_json::Map<String, Value>,
    store_switched_sections: &HashSet<String>,
    ru: bool,
    now: i64,
) -> Vec<(&'static str, String)> {
    let mut notices = Vec::new();
    let tag_map = crate::ubus_bridge::build_telemetry_tag_display_map(d);
    for sec in &d.sections {
        let sel_tag = format!("sel-{}", sec.id);
        let active_pair: Option<(String, String)> = if let Some(sel_now) = px_map
            .get(&sel_tag)
            .and_then(|g| g.get("now"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            if let Some(bal_now) = px_map
                .get(sel_now)
                .and_then(|g| g.get("now"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                Some((sel_now.to_string(), bal_now.to_string()))
            } else {
                Some((sel_tag, sel_now.to_string()))
            }
        } else {
            let mut candidates: Vec<String> = sec
                .balancer_refs
                .iter()
                .map(|b| format!("bal-{}-{b}", sec.id))
                .collect();
            let prefix = format!("bal-{}-", sec.id);
            for k in px_map.keys() {
                if k.starts_with(&prefix) && !candidates.contains(k) {
                    candidates.push(k.clone());
                }
            }
            candidates.push(format!("{}-out", sec.id));
            candidates.into_iter().find_map(|gtag| {
                px_map
                    .get(&gtag)
                    .and_then(|g| g.get("now"))
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .map(|now_tag| (gtag, now_tag.to_string()))
            })
        };

        let Some((active_group, resolved_node)) = active_pair else {
            continue;
        };
        if is_per_flow_balancer_group(d, &sec.id, &active_group) {
            obs.clash_active_nodes
                .insert(format!("{}::{}", sec.id, active_group), resolved_node);
            continue;
        }
        let track_key = format!("{}::{}", sec.id, active_group);
        if let Some(prev) = obs.clash_active_nodes.get(&track_key)
            && prev != &resolved_node
            && !store_switched_sections.contains(&sec.id)
            && d.telegram.notify_server_switch
        {
            let suppress = if let Some((last_ts, suppressed)) =
                obs.last_switch_alerts.get_mut(&track_key)
                && now.saturating_sub(*last_ts) < 300
            {
                *suppressed = suppressed.saturating_add(1);
                true
            } else {
                false
            };
            if !suppress {
                let suppressed_count = obs
                    .last_switch_alerts
                    .get(&track_key)
                    .map(|(_, c)| *c)
                    .unwrap_or(0);
                obs.last_switch_alerts.insert(track_key.clone(), (now, 0));
                let sec_label = if !sec.label.trim().is_empty() {
                    sec.label.trim()
                } else {
                    sec.id.as_str()
                };
                let group_label = crate::ubus_bridge::resolve_telemetry_tag_display_name(
                    &active_group,
                    &tag_map,
                    d,
                );
                let node_label = crate::ubus_bridge::resolve_telemetry_tag_display_name(
                    &resolved_node,
                    &tag_map,
                    d,
                );
                let group_suffix =
                    if group_label.is_empty() || group_label.eq_ignore_ascii_case(sec_label) {
                        String::new()
                    } else {
                        format!(" ({})", escape_html(&group_label))
                    };
                let window_suffix = if suppressed_count > 0 {
                    if ru {
                        format!(" (ещё переключений за 5 мин: +{suppressed_count})")
                    } else {
                        format!(" (+{suppressed_count} switches in 5m)")
                    }
                } else {
                    String::new()
                };
                let txt = if ru {
                    format!(
                        "<b>Переключение узла:</b> <b>{}</b>{} -> <code>{}</code>{}",
                        escape_html(sec_label),
                        group_suffix,
                        escape_html(&node_label),
                        window_suffix
                    )
                } else {
                    format!(
                        "<b>Node Switch:</b> <b>{}</b>{} -> <code>{}</code>{}",
                        escape_html(sec_label),
                        group_suffix,
                        escape_html(&node_label),
                        window_suffix
                    )
                };
                notices.push(("server_switch", txt));
            }
        }
        obs.clash_active_nodes.insert(track_key, resolved_node);
    }
    notices
}

fn push_bounded_key(q: &mut VecDeque<String>, key: String, max: usize) -> bool {
    if q.iter().any(|k| k == &key) {
        return false;
    }
    if q.len() >= max {
        q.pop_front();
    }
    q.push_back(key);
    true
}

async fn check_cert_expiring_soon(path: &str) -> bool {
    if cfg!(windows) || path.trim().is_empty() || !std::path::Path::new(path).exists() {
        return false;
    }
    let out = tokio::process::Command::new("openssl")
        .args(["x509", "-noout", "-checkend", "1209600", "-in", path])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    matches!(out, Ok(st) if !st.success())
}

pub(crate) fn classify_event_notification(
    obs: &mut BotEventObserver,
    subsystem: &str,
    message: &str,
    now: i64,
    ru: bool,
) -> Option<(&'static str, String)> {
    let sub_low = subsystem.to_ascii_lowercase();
    let msg_low = message.to_ascii_lowercase();
    let watchdog_maintenance = sub_low == "watchdog"
        && (msg_low.contains("l2_config_drift_reload")
            || msg_low.contains("l1_memory_trim")
            || msg_low.contains("l1_dns_flush"));
    if sub_low == "watchdog" && msg_low.contains("l2_config_drift_reload") {
        if !obs.should_emit_restart_alert("watchdog:l2_config_drift_reload", now) {
            return None;
        }
        let txt = if ru {
            format!("<b>Перезапуск ядра:</b> {}", escape_html(message))
        } else {
            format!("<b>Core Restart:</b> {}", escape_html(message))
        };
        Some(("restart", txt))
    } else if watchdog_maintenance {
        None
    } else if sub_low != "blackbox"
        && (sub_low == "watchdog"
            || msg_low.contains("stopped unexpectedly")
            || msg_low.contains("crash"))
    {
        let dedup_key = msg_low.trim().to_string();
        if !obs.should_emit_crash_alert(&dedup_key, now) {
            return None;
        }
        let txt = if ru {
            format!("<b>Сбой ядра:</b> {}", escape_html(message))
        } else {
            format!("<b>Core Crash:</b> {}", escape_html(message))
        };
        Some(("crash", txt))
    } else if sub_low == "core_mgr"
        && (msg_low.contains("started")
            || msg_low.contains("reloaded")
            || msg_low.contains("restart"))
    {
        if !obs.should_emit_restart_alert("core_mgr:restart", now) {
            return None;
        }
        let txt = if ru {
            format!("<b>Перезапуск ядра:</b> {}", escape_html(message))
        } else {
            format!("<b>Core Restart:</b> {}", escape_html(message))
        };
        Some(("restart", txt))
    } else if sub_low.contains("failover") || msg_low.contains("failover") {
        let txt = if ru {
            format!(
                "<b>Переключение канала (Failover):</b> {}",
                escape_html(message)
            )
        } else {
            format!("<b>Failover:</b> {}", escape_html(message))
        };
        Some(("failover", txt))
    } else if sub_low.contains("smart_detect") || msg_low.contains("smart detect") {
        let txt = format!("<b>Smart Detect:</b> {}", escape_html(message));
        Some(("smart_detect", txt))
    } else if sub_low.contains("parental") {
        let txt = if ru {
            format!("<b>Семейный режим:</b> {}", escape_html(message))
        } else {
            format!("<b>Parental Control:</b> {}", escape_html(message))
        };
        Some(("parental", txt))
    } else {
        None
    }
}

pub(crate) fn collect_observed_event_notifications(
    obs: &mut BotEventObserver,
    live: &crate::store::LiveTelemetry,
    now: i64,
    ru: bool,
) -> (Vec<(&'static str, String)>, bool) {
    let mut emitted_restart = false;
    let mut out = Vec::new();
    for ev in &live.events {
        if ev.seq > 0 {
            if ev.seq <= obs.last_seen_event_seq {
                continue;
            }
            obs.last_seen_event_seq = ev.seq;
        } else {
            let key = format!("{}|{}|{}", ev.timestamp, ev.subsystem, ev.message);
            if !push_bounded_key(&mut obs.seen_event_keys, key, SEEN_EVENT_KEY_CAP) {
                continue;
            }
        }
        if let Some((kind, txt)) =
            classify_event_notification(obs, &ev.subsystem, &ev.message, now, ru)
        {
            if kind == "restart" {
                emitted_restart = true;
            }
            out.push((kind, txt));
        }
    }
    (out, emitted_restart)
}

async fn observe_and_notify_events(
    obs: &mut BotEventObserver,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();
    let now = unix_now_secs();
    let ru = is_ru(&d);

    let mut cur_sub_state = HashMap::new();
    for src in &d.outbound_sources {
        if src.source_type == "subscription" {
            cur_sub_state.insert(
                src.id.clone(),
                (src.last_updated_unix, src.sub_last_error.clone()),
            );
        }
    }

    let mut cur_parental = HashMap::new();
    for prof in &d.profiles {
        let blocked = prof.enabled
            && (prof.paused_until_unix > now
                || (prof.daily_quota_minutes > 0
                    && prof.used_minutes_today >= prof.daily_quota_minutes));
        cur_parental.insert(prof.id.clone(), blocked);
    }

    let cur_smart_count: usize = d
        .conditions
        .iter()
        .filter(|c| c.id.contains("smart") || c.name.to_ascii_lowercase().contains("smart"))
        .map(|c| c.user_domains.len())
        .sum();

    if !obs.initialized {
        obs.last_seen_event_seq = live.events.iter().map(|ev| ev.seq).max().unwrap_or(0);
        for ev in &live.events {
            if ev.seq == 0 {
                push_bounded_key(
                    &mut obs.seen_event_keys,
                    format!("{}|{}|{}", ev.timestamp, ev.subsystem, ev.message),
                    SEEN_EVENT_KEY_CAP,
                );
            }
        }
        for hit in &live.honeypot_hits {
            push_bounded_key(
                &mut obs.seen_honeypot_keys,
                format!("{}|{}|{}", hit.timestamp, hit.ip, hit.path),
                SEEN_HONEYPOT_KEY_CAP,
            );
        }
        obs.last_core_pid = live.core_pid;
        obs.last_core_running = live.core_running;
        obs.last_wan_healthy = live.wan_healthy;
        obs.last_dns_healthy = live.dns_healthy;
        for sec in &d.sections {
            if !sec.active_selected_tag.is_empty() {
                obs.section_active_nodes
                    .insert(sec.id.clone(), sec.active_selected_tag.clone());
            }
        }
        obs.sub_state = cur_sub_state;
        obs.parental_blocked = cur_parental;
        obs.smart_detect_domain_count = cur_smart_count;
        obs.last_clash_poll_unix = now;
        obs.initialized = true;
        return;
    }

    let (event_notices, emitted_restart) =
        collect_observed_event_notifications(obs, &live, now, ru);
    for (kind, txt) in event_notices {
        notify_if_enabled(&d, kind, &txt);
    }

    if !emitted_restart
        && live.core_running
        && live.core_pid.is_some()
        && obs.last_core_pid.is_some()
        && live.core_pid != obs.last_core_pid
    {
        let txt = if ru {
            format!(
                "<b>Перезапуск ядра:</b> новый PID <code>{}</code>",
                live.core_pid.unwrap_or(0)
            )
        } else {
            format!(
                "<b>Core Restarted:</b> new PID <code>{}</code>",
                live.core_pid.unwrap_or(0)
            )
        };
        notify_if_enabled(&d, "restart", &txt);
    }
    if obs.last_core_running && !live.core_running {
        let txt = if ru {
            "<b>Внимание:</b> процесс <code>tachyon-core</code> остановлен"
        } else {
            "<b>Warning:</b> <code>tachyon-core</code> process stopped"
        };
        notify_if_enabled(&d, "crash", txt);
    }
    obs.last_core_pid = live.core_pid;
    obs.last_core_running = live.core_running;

    for hit in &live.honeypot_hits {
        let key = format!("{}|{}|{}", hit.timestamp, hit.ip, hit.path);
        if push_bounded_key(&mut obs.seen_honeypot_keys, key, SEEN_HONEYPOT_KEY_CAP) {
            let txt = if ru {
                format!(
                    "<b>Honeypot:</b> заблокирована попытка с <code>{}</code> (<code>{}</code> — {})",
                    escape_html(&hit.ip),
                    escape_html(&hit.path),
                    escape_html(&hit.reason)
                )
            } else {
                format!(
                    "<b>Honeypot:</b> probe from <code>{}</code> (<code>{}</code> — {})",
                    escape_html(&hit.ip),
                    escape_html(&hit.path),
                    escape_html(&hit.reason)
                )
            };
            notify_if_enabled(&d, "honeypot", &txt);
        }
    }

    if live.wan_healthy != obs.last_wan_healthy {
        let txt = if live.wan_healthy {
            if ru {
                "<b>WAN:</b> внешний канал восстановлен"
            } else {
                "<b>WAN:</b> uplink restored"
            }
        } else if ru {
            "<b>WAN:</b> потеря связи на внешнем канале"
        } else {
            "<b>WAN:</b> uplink unreachable"
        };
        if d.telegram.notify_wan {
            notify_if_enabled(&d, "wan", txt);
        } else if d.settings.wan_failover_enabled {
            notify_if_enabled(&d, "failover", txt);
        }
        obs.last_wan_healthy = live.wan_healthy;
    }

    if obs.last_dns_healthy && !live.dns_healthy {
        let txt = if ru {
            "<b>DNS:</b> локальный резолвер <code>127.0.0.42:53</code> недоступен — риск утечки DNS"
        } else {
            "<b>DNS:</b> local resolver <code>127.0.0.42:53</code> unavailable — DNS leak risk"
        };
        notify_if_enabled(&d, "dns_leak", txt);
    }
    obs.last_dns_healthy = live.dns_healthy;

    let (store_switched_sections, store_notices) =
        collect_section_store_switch_notifications(obs, &d, ru);
    for (kind, txt) in store_notices {
        notify_if_enabled(&d, kind, &txt);
    }

    if live.core_running
        && d.telegram.notify_server_switch
        && now.saturating_sub(obs.last_clash_poll_unix) >= 30
    {
        obs.last_clash_poll_unix = now;
        if let Ok(px) = core.clash_request("GET", "/proxies", None).await
            && let Some(px_map) = px.get("proxies").and_then(Value::as_object)
        {
            for (kind, txt) in collect_clash_node_switch_notifications_at(
                obs,
                &d,
                px_map,
                &store_switched_sections,
                ru,
                now,
            ) {
                notify_if_enabled(&d, kind, &txt);
            }
        }
    }

    for (sid, (ts, err)) in &cur_sub_state {
        if let Some((prev_ts, prev_err)) = obs.sub_state.get(sid) {
            if err != prev_err && !err.is_empty() {
                let txt = if ru {
                    format!(
                        "<b>Подписка <code>{}</code>:</b> ошибка обновления — {}",
                        escape_html(sid),
                        escape_html(err)
                    )
                } else {
                    format!(
                        "<b>Subscription <code>{}</code>:</b> update error — {}",
                        escape_html(sid),
                        escape_html(err)
                    )
                };
                notify_if_enabled(&d, "subscription", &txt);
            } else if ts > prev_ts && err.is_empty() {
                let nodes_cnt = d
                    .outbound_sources
                    .iter()
                    .find(|s| &s.id == sid)
                    .map(|s| s.cached_nodes.len())
                    .unwrap_or(0);
                let txt = if ru {
                    format!(
                        "<b>Подписка <code>{}</code>:</b> обновлена (узлов: {nodes_cnt})",
                        escape_html(sid)
                    )
                } else {
                    format!(
                        "<b>Subscription <code>{}</code>:</b> updated ({nodes_cnt} nodes)",
                        escape_html(sid)
                    )
                };
                notify_if_enabled(&d, "subscription", &txt);
            }
        }
    }
    obs.sub_state = cur_sub_state;

    for (pid, &blocked) in &cur_parental {
        if obs.parental_blocked.get(pid).copied() == Some(false) && blocked {
            let txt = if ru {
                format!(
                    "<b>Семейный режим:</b> профиль <code>{}</code> ограничен (пауза или квота)",
                    escape_html(pid)
                )
            } else {
                format!(
                    "<b>Parental Control:</b> profile <code>{}</code> paused or quota reached",
                    escape_html(pid)
                )
            };
            notify_if_enabled(&d, "parental", &txt);
        }
    }
    obs.parental_blocked = cur_parental;

    if cur_smart_count > obs.smart_detect_domain_count {
        let added = cur_smart_count - obs.smart_detect_domain_count;
        let txt = if ru {
            format!("<b>Smart Detect:</b> добавлено доменов: {added} (всего {cur_smart_count})")
        } else {
            format!("<b>Smart Detect:</b> added {added} domain(s) (total {cur_smart_count})")
        };
        notify_if_enabled(&d, "smart_detect", &txt);
    }
    obs.smart_detect_domain_count = cur_smart_count;

    if d.telegram.notify_cert && now.saturating_sub(obs.last_cert_check_unix) >= 6 * 3600 {
        obs.last_cert_check_unix = now;
        for srv in d
            .servers
            .iter()
            .filter(|s| s.enabled && s.security == "tls")
        {
            let cp = srv.tls_certificate_path.trim();
            if !cp.is_empty()
                && !obs.warned_cert_paths.contains(cp)
                && check_cert_expiring_soon(cp).await
            {
                obs.warned_cert_paths.insert(cp.to_string());
                let txt = if ru {
                    format!(
                        "<b>Сертификаты:</b> срок TLS-сертификата <code>{}</code> истекает менее чем через 14 дней",
                        escape_html(cp)
                    )
                } else {
                    format!(
                        "<b>Certificates:</b> TLS certificate <code>{}</code> expires within 14 days",
                        escape_html(cp)
                    )
                };
                notify_if_enabled(&d, "cert", &txt);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn record_poll_failure_alert(
    consecutive_failures: &mut u32,
    route_alert_sent: &mut bool,
    notify_route_alert: bool,
    token: &str,
    admins: &[i64],
    header: &str,
    ru: bool,
    direct_fallback: bool,
    quiet_enabled: bool,
    quiet_start: &str,
    quiet_end: &str,
) {
    *consecutive_failures = consecutive_failures.saturating_add(1);
    if notify_route_alert && *consecutive_failures >= 5 && !*route_alert_sent {
        *route_alert_sent = maybe_alert_route_failure_at(&RouteAlertParams {
            token,
            admins,
            header,
            ru,
            failures: *consecutive_failures,
            direct_fallback,
            quiet_enabled,
            quiet_start,
            quiet_end,
            now_utc_secs: unix_now_secs(),
            local_now_secs: local_secs_for_quiet_check(),
            outbox_dir: &tg_outbox_dir(),
            stamp_path: &tg_route_alert_stamp_file(),
            cooldown_secs: TG_ROUTE_ALERT_COOLDOWN_SECS,
        });
    }
}

pub fn spawn_tg_bot_loop(state: Arc<AppState>, core: Arc<CoreManager>) {
    if TG_POLL_ACTIVE.swap(true, Ordering::AcqRel) {
        return;
    }
    tokio::spawn(async move {
        let mut last_update_id: i64 = 0;
        let mut last_commands_key: Option<(String, bool)> = None;
        let mut prev_active_jobs: HashSet<String> = HashSet::new();
        let mut seen_finished_jobs: VecDeque<String> =
            VecDeque::with_capacity(MAX_SEEN_FINISHED_JOBS);
        let mut consecutive_failures: u32 = 0;
        let mut route_alert_sent = false;
        let mut observer = BotEventObserver::default();
        let mut fleet_monitor = fleet::FleetMonitor::default();

        loop {
            let (
                eff_running,
                token,
                admins,
                poll_secs,
                ru,
                header,
                proxy_opt,
                direct_fallback,
                quiet_enabled,
                quiet_start,
                quiet_end,
                notify_auto_update,
                notify_route_alert,
                managed_routers,
            ) = {
                let d = state.data.read().await;
                let core_running = state.live.read().await.core_running;
                (
                    is_bot_effectively_running(&d),
                    d.telegram.bot_token.trim().to_string(),
                    d.telegram.admin_ids.clone(),
                    u64::from(d.telegram.poll_interval).clamp(1, 300),
                    is_ru(&d),
                    build_message_header(&d),
                    resolve_tg_proxy_url(&d, core_running),
                    d.telegram.bot_direct_fallback,
                    d.telegram.quiet_hours_enabled,
                    d.telegram.quiet_hours_start.clone(),
                    d.telegram.quiet_hours_end.clone(),
                    d.telegram.notify_auto_update,
                    d.telegram.notify_route_alert,
                    d.telegram.managed_routers.clone(),
                )
            };

            if !eff_running {
                consecutive_failures = 0;
                route_alert_sent = false;
                sleep_or_wakeup(30).await;
                continue;
            }

            write_heartbeat_to(&tg_heartbeat_file(), unix_now_secs());

            if last_commands_key.as_ref() != Some(&(token.clone(), ru))
                && transport::register_bot_commands(
                    &token,
                    ru,
                    proxy_opt.as_deref(),
                    direct_fallback,
                )
                .await
                .is_ok()
            {
                last_commands_key = Some((token.clone(), ru));
            }

            let quiet_now = quiet_enabled
                && is_in_quiet_hours_at(local_secs_for_quiet_check(), &quiet_start, &quiet_end);

            observe_and_notify_events(&mut observer, &state, &core).await;

            if managed_routers.is_empty() {
                fleet_monitor.clear_if_nonempty();
            } else {
                let fleet_alerts =
                    Box::pin(fleet_monitor.poll_tick_if_due(&managed_routers, unix_now_secs()))
                        .await;
                for alert in fleet_alerts {
                    let body = fleet::format_fleet_alert_html(&alert, ru);
                    let full_msg = prepend_header_if_missing(&body, &header);
                    let silent = quiet_now && !matches!(alert.kind, fleet::FleetAlertKind::Outage);
                    for &cid in &admins {
                        let _ = transport::send_tg_message(
                            &token,
                            cid,
                            &full_msg,
                            None,
                            silent,
                            proxy_opt.as_deref(),
                            direct_fallback,
                        )
                        .await;
                    }
                }
            }

            let job_ctx = JobNotifyCtx {
                token: &token,
                admins: &admins,
                header: &header,
                ru,
                quiet_now,
                notify_auto_update,
                proxy_url: proxy_opt.as_deref(),
                direct_fallback,
            };
            Box::pin(check_and_notify_finished_jobs(
                &mut prev_active_jobs,
                &mut seen_finished_jobs,
                &job_ctx,
            ))
            .await;

            Box::pin(drain_telegram_outbox(
                &token,
                &admins,
                &header,
                quiet_now,
                proxy_opt.as_deref(),
                direct_fallback,
            ))
            .await;

            let poll_req = transport::PollTransportRequest {
                token: token.clone(),
                offset: last_update_id + 1,
                timeout_secs: TG_POLL_TIMEOUT_SECS,
                proxy_url: proxy_opt.clone(),
                direct_fallback,
            };

            let poll_res = tokio::select! {
                _ = TG_WAKEUP_NOTIFY.notified() => {
                    continue;
                }
                res = transport::poll_telegram_updates(&poll_req) => res,
            };

            write_heartbeat_to(&tg_heartbeat_file(), unix_now_secs());

            let Ok(val) = poll_res else {
                record_poll_failure_alert(
                    &mut consecutive_failures,
                    &mut route_alert_sent,
                    notify_route_alert,
                    &token,
                    &admins,
                    &header,
                    ru,
                    direct_fallback,
                    quiet_enabled,
                    &quiet_start,
                    &quiet_end,
                );
                let backoff_secs =
                    (poll_secs.max(5) * u64::from(consecutive_failures.min(6))).min(60);
                sleep_with_heartbeat(backoff_secs).await;
                continue;
            };

            if val.get("error_code").and_then(Value::as_i64) == Some(409) {
                consecutive_failures = 0;
                route_alert_sent = false;
                sleep_with_heartbeat(15).await;
                continue;
            }
            if val.get("error_code").and_then(Value::as_i64) == Some(429) {
                consecutive_failures = 0;
                route_alert_sent = false;
                let retry_after = val
                    .pointer("/parameters/retry_after")
                    .and_then(Value::as_u64)
                    .unwrap_or(10)
                    .clamp(1, 300);
                sleep_with_heartbeat(retry_after).await;
                continue;
            }
            if val.get("ok").and_then(Value::as_bool) != Some(true) {
                let api_err = val.get("error_code").and_then(Value::as_i64);
                if !matches!(api_err, Some(400 | 401 | 403 | 404)) {
                    record_poll_failure_alert(
                        &mut consecutive_failures,
                        &mut route_alert_sent,
                        notify_route_alert,
                        &token,
                        &admins,
                        &header,
                        ru,
                        direct_fallback,
                        quiet_enabled,
                        &quiet_start,
                        &quiet_end,
                    );
                }
                sleep_with_heartbeat(poll_secs.max(5)).await;
                continue;
            }

            let Some(arr) = val.get("result").and_then(Value::as_array) else {
                sleep_with_heartbeat(poll_secs).await;
                continue;
            };

            consecutive_failures = 0;
            route_alert_sent = false;

            let mut processed_any = false;
            for upd in arr {
                if let Some(uid) = upd.get("update_id").and_then(Value::as_i64)
                    && uid > last_update_id
                {
                    last_update_id = uid;
                }
                if let Some(msg) = upd.get("message") {
                    let chat_id = msg.pointer("/chat/id").and_then(Value::as_i64).unwrap_or(0);
                    if !admins.contains(&chat_id) {
                        continue;
                    }
                    let text = msg
                        .get("text")
                        .or_else(|| msg.get("caption"))
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .trim();
                    let owned_doc_text = if text.is_empty()
                        && let Some(doc) = msg.get("document")
                        && let Some(file_id) = doc
                            .get("file_id")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                    {
                        const MAX_TG_DOC_BYTES: u64 = 262_144;
                        let too_big = doc
                            .get("file_size")
                            .and_then(Value::as_u64)
                            .is_some_and(|sz| sz > MAX_TG_DOC_BYTES);
                        if too_big {
                            if peek_chat_prompt(chat_id).is_some() {
                                let ru = {
                                    let d = state.data.read().await;
                                    is_ru(&d)
                                };
                                let err_reply = BotReply::text(tr(
                                    ru,
                                    "[ERR] Файл слишком большой (максимум 256 КБ).",
                                    "[ERR] File is too large (max 256 KB).",
                                ));
                                processed_any = true;
                                Box::pin(deliver_bot_reply(
                                    &token,
                                    chat_id,
                                    None,
                                    err_reply,
                                    &header,
                                    proxy_opt.as_deref(),
                                    direct_fallback,
                                ))
                                .await;
                            }
                            continue;
                        }
                        match transport::download_telegram_document_text(
                            &token,
                            file_id,
                            proxy_opt.as_deref(),
                            direct_fallback,
                        )
                        .await
                        {
                            Ok(content) => Some(content),
                            Err(e) => {
                                if peek_chat_prompt(chat_id).is_some() {
                                    let err_reply = BotReply::text(format!(
                                        "[ERR] {}",
                                        escape_html(&e.to_string())
                                    ));
                                    processed_any = true;
                                    Box::pin(deliver_bot_reply(
                                        &token,
                                        chat_id,
                                        None,
                                        err_reply,
                                        &header,
                                        proxy_opt.as_deref(),
                                        direct_fallback,
                                    ))
                                    .await;
                                }
                                continue;
                            }
                        }
                    } else {
                        None
                    };
                    let eff_text = owned_doc_text.as_deref().map(str::trim).unwrap_or(text);
                    if eff_text.is_empty() {
                        continue;
                    }
                    processed_any = true;
                    let reply = dispatch_text_message(chat_id, eff_text, &state, &core).await;
                    Box::pin(deliver_bot_reply(
                        &token,
                        chat_id,
                        None,
                        reply,
                        &header,
                        proxy_opt.as_deref(),
                        direct_fallback,
                    ))
                    .await;
                } else if let Some(cb) = upd.get("callback_query") {
                    let chat_id = cb
                        .pointer("/message/chat/id")
                        .and_then(Value::as_i64)
                        .unwrap_or(0);
                    if !admins.contains(&chat_id) {
                        continue;
                    }
                    processed_any = true;
                    let cb_id = cb
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let message_id = cb.pointer("/message/message_id").and_then(Value::as_i64);
                    let raw_data = cb.get("data").and_then(Value::as_str).unwrap_or("");

                    if !cb_id.is_empty() {
                        let tok_c = token.clone();
                        let px_c = proxy_opt.clone();
                        tokio::spawn(async move {
                            transport::answer_callback_query(
                                &tok_c,
                                &cb_id,
                                None,
                                px_c.as_deref(),
                                direct_fallback,
                            )
                            .await;
                        });
                    }

                    let reply = dispatch_callback_query(chat_id, raw_data, &state, &core).await;
                    Box::pin(deliver_bot_reply(
                        &token,
                        chat_id,
                        message_id,
                        reply,
                        &header,
                        proxy_opt.as_deref(),
                        direct_fallback,
                    ))
                    .await;
                }
            }

            if !processed_any && poll_secs > TG_POLL_TIMEOUT_SECS {
                sleep_with_heartbeat(poll_secs - TG_POLL_TIMEOUT_SECS).await;
            }
        }
    });
}
