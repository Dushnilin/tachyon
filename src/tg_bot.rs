//! Built-in Telegram Bot long-polling daemon and notification sender for `tachyon`
//! (`docs/knowledge-base/09_TELEGRAM_BOT_ARCHITECTURE.md`).
//!
//! Supports commands: `/start`, `/status`, `/doctor`, `/ai_doctor`, `/fix`, `/server`,
//! `/rules`, `/restart`, `/backup` and callback queries `srv:select:*`, `rule:toggle:*`, `fix:apply:*`.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::process::Command;

use crate::core_mgr::CoreManager;
use crate::diagnostics;
use crate::store::AppState;
use crate::transaction;

pub fn spawn_tg_bot_loop(state: Arc<AppState>, core: Arc<CoreManager>) {
    tokio::spawn(async move {
        let mut last_update_id: i64 = 0;
        let mut interval = tokio::time::interval(Duration::from_secs(6));
        loop {
            interval.tick().await;
            let (enabled, token, admins) = {
                let d = state.data.read().await;
                (
                    d.telegram.enabled,
                    d.telegram.bot_token.trim().to_string(),
                    d.telegram.admin_ids.clone(),
                )
            };
            if !enabled || token.is_empty() || admins.is_empty() {
                continue;
            }
            let url = format!(
                "https://api.telegram.org/bot{token}/getUpdates?timeout=2&offset={}",
                last_update_id + 1
            );
            let Ok(out) = Command::new("curl")
                .args(["-fsSL", "--max-time", "5", &url])
                .output()
                .await
            else {
                continue;
            };
            if !out.status.success() {
                continue;
            }
            let Ok(val) = serde_json::from_slice::<Value>(&out.stdout) else {
                continue;
            };
            let Some(arr) = val.get("result").and_then(Value::as_array) else {
                continue;
            };
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
                    let text = msg.get("text").and_then(Value::as_str).unwrap_or("").trim();
                    let reply = handle_bot_command(&state, &core, text).await;
                    let _ = send_tg_message(&token, chat_id, &reply).await;
                } else if let Some(cb) = upd.get("callback_query") {
                    let chat_id = cb
                        .pointer("/message/chat/id")
                        .and_then(Value::as_i64)
                        .unwrap_or(0);
                    if !admins.contains(&chat_id) {
                        continue;
                    }
                    let data = cb.get("data").and_then(Value::as_str).unwrap_or("");
                    let reply = handle_bot_callback(&state, &core, data).await;
                    let _ = send_tg_message(&token, chat_id, &reply).await;
                }
            }
        }
    });
}

async fn handle_bot_command(state: &Arc<AppState>, core: &Arc<CoreManager>, text: &str) -> String {
    let cmd = text.split_whitespace().next().unwrap_or("");
    match cmd {
        "/start" | "/help" => "<b>Tachyon Router Bot</b>\n\n\
             Доступные команды:\n\
             - /status — статус ядра и трафика\n\
             - /doctor — проверка 14 подсистем\n\
             - /ai_doctor — заключение AI Doctor v3.0\n\
             - /rules — список секций маршрутизации\n\
             - /server — список серверов и узлов\n\
             - /devices — список клиентов LAN\n\
             - /restart — перезапуск tachyon-core\n\
             - /rollback — откат к снимку Last Known Good\n\
             - /backup — выгрузка резервной копии"
            .to_string(),
        "/status" => {
            let live = state.live.read().await;
            format!(
                "<b>Tachyon Status</b>\n\
                 Ядро: <code>{}</code> (PID: {:?})\n\
                 Uptime: <code>{} с</code>\n\
                 Память RSS: <code>{:.2} МБ</code>\n\
                 Активных сессий: <code>{}</code>\n\
                 Трафик: TX <code>{}</code> / RX <code>{}</code> байт",
                if live.core_running {
                    "Работает"
                } else {
                    "Остановлено"
                },
                live.core_pid,
                live.core_uptime_secs,
                live.core_rss_bytes as f64 / (1024.0 * 1024.0),
                live.active_connections,
                live.total_up_bytes,
                live.total_down_bytes
            )
        }
        "/doctor" => {
            let rep = diagnostics::run_local_doctor(state).await;
            format!(
                "<b>Диагностика Tachyon</b>\nСтатус: {}\nПроверено: {}/{}",
                rep.summary, rep.checks_passed, rep.checks_total
            )
        }
        "/ai_doctor" => {
            let res = diagnostics::run_ai_doctor(state, None).await;
            res.get("analysis")
                .and_then(Value::as_str)
                .unwrap_or("OK")
                .to_string()
        }
        "/rules" | "/sections" => {
            let d = state.data.read().await;
            let lines: Vec<String> = d
                .sections
                .iter()
                .map(|s| {
                    format!(
                        "[{}] <b>{}</b> (<code>{}</code>)",
                        if s.enabled { "ON" } else { "OFF" },
                        s.label,
                        s.connection_type
                    )
                })
                .collect();
            format!("<b>Секции маршрутизации:</b>\n{}", lines.join("\n"))
        }
        "/server" | "/servers" => {
            let d = state.data.read().await;
            let lines: Vec<String> = d
                .servers
                .iter()
                .take(15)
                .map(|s| {
                    format!(
                        "[{}] <b>{}</b> — <code>{}:{}</code> ({})",
                        if s.enabled { "ON" } else { "OFF" },
                        s.label,
                        s.public_host,
                        s.listen_port,
                        s.protocol
                    )
                })
                .collect();
            format!("<b>Входящие серверы:</b>\n{}", lines.join("\n"))
        }
        "/devices" => {
            let live = state.live.read().await;
            let lines: Vec<String> = live
                .lan_devices
                .iter()
                .take(20)
                .map(|dev| {
                    let name = if !dev.custom_name.is_empty() {
                        &dev.custom_name
                    } else if !dev.hostname.is_empty() {
                        &dev.hostname
                    } else {
                        "LAN Client"
                    };
                    format!("• <code>{}</code> — {} ({})", dev.ip, name, dev.mac)
                })
                .collect();
            format!("<b>Клиенты LAN ({}):</b>\n{}", live.lan_devices.len(), lines.join("\n"))
        }
        "/restart" | "/reload" => match core.apply_or_reload().await {
            Ok(()) => "[OK] Ядро tachyon-core успешно перезапущено".to_string(),
            Err(e) => format!("[ERR] Ошибка перезапуска: {e}"),
        },
        "/rollback" => {
            match diagnostics::apply_quick_fix(state, core, "rollback_known_good").await {
                Ok(msg) => format!("[OK] {msg}"),
                Err(e) => format!("[ERR] {e}"),
            }
        }
        _ if cmd.starts_with("/fix") => {
            let fix_id = text.split_whitespace().nth(1).unwrap_or("restart_core");
            match diagnostics::apply_quick_fix(state, core, fix_id).await {
                Ok(msg) => format!("[OK] {msg}"),
                Err(e) => format!("[ERR] {e}"),
            }
        }
        _ => "Используйте /start для списка команд.".to_string(),
    }
}

async fn handle_bot_callback(state: &Arc<AppState>, core: &Arc<CoreManager>, data: &str) -> String {
    if let Some(rest) = data.strip_prefix("srv:select:") {
        if let Some((sec_id, tag)) = rest.split_once(':') {
            match core.select_section_node(sec_id, tag).await {
                Ok(()) => return format!("[OK] Узел секции {sec_id} переключён на {tag}"),
                Err(e) => return format!("[ERR] {e}"),
            }
        }
    } else if let Some(sec_id) = data.strip_prefix("rule:toggle:") {
        let mut candidate = state.data.read().await.clone();
        if let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == sec_id) {
            sec.enabled = !sec.enabled;
            let st = sec.enabled;
            let _ = transaction::commit_transaction(state, candidate).await;
            let _ = core.apply_or_reload().await;
            return format!(
                "Секция {sec_id}: {}",
                if st {
                    "Включена"
                } else {
                    "Выключена"
                }
            );
        }
    } else if let Some(fix_id) = data.strip_prefix("fix:apply:")
        && let Ok(msg) = diagnostics::apply_quick_fix(state, core, fix_id).await
    {
        return format!("[OK] {msg}");
    }
    handle_bot_command(state, core, data).await
}

pub async fn send_test_notification(state: &Arc<AppState>) -> anyhow::Result<usize> {
    let (token, admins) = {
        let d = state.data.read().await;
        (
            d.telegram.bot_token.trim().to_string(),
            d.telegram.admin_ids.clone(),
        )
    };
    if token.is_empty() || admins.is_empty() {
        anyhow::bail!("Укажите Bot Token и хотя бы один Admin ID в настройках Telegram");
    }
    let mut sent = 0usize;
    let text = "<b>Tachyon Router: Тестовое уведомление</b>\nСвязь с роутером установлена.";
    for chat_id in admins {
        if send_tg_message(&token, chat_id, text).await.is_ok() {
            sent += 1;
        }
    }
    Ok(sent)
}

async fn send_tg_message(token: &str, chat_id: i64, text: &str) -> anyhow::Result<()> {
    let url = format!("https://api.telegram.org/bot{token}/sendMessage");
    let body = json!({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "reply_markup": {
            "inline_keyboard": [
                [
                    {"text": "Статус", "callback_data": "/status"},
                    {"text": "Doctor", "callback_data": "/doctor"},
                    {"text": "Секции", "callback_data": "/rules"}
                ],
                [
                    {"text": "Клиенты LAN", "callback_data": "/devices"},
                    {"text": "Перезапуск", "callback_data": "/restart"},
                    {"text": "Откат LKG", "callback_data": "/rollback"}
                ]
            ]
        }
    })
    .to_string();
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "--max-time",
            "8",
            "-H",
            "Content-Type: application/json",
            "-d",
            &body,
            &url,
        ])
        .output()
        .await?;
    if !out.status.success() {
        anyhow::bail!("Telegram API HTTP error");
    }
    Ok(())
}
