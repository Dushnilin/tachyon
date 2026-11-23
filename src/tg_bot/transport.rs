//! Secret-safe Telegram Bot API transport via `curl -K -` (stdin config).
//!
//! Bot tokens are NEVER placed in process command-line arguments, environment
//! variables, error strings, or logs: `url = "..."` is written exclusively to
//! `curl`'s stdin pipe.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

static UPLOAD_SEQ: crate::store::PortableAtomicU64 = crate::store::PortableAtomicU64::new(0);

const TELEGRAM_MAX_MESSAGE_CHARS: usize = 3800;
const TELEGRAM_MAX_CAPTION_CHARS: usize = 1000;

struct RemoveFileOnDrop(PathBuf);

impl Drop for RemoveFileOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn escape_curl_config_value(raw: &str) -> String {
    raw.replace('\\', "\\\\").replace('"', "\\\"")
}

fn sanitize_upload_filename(raw: &str) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = cleaned.trim_start_matches('.');
    if trimmed.is_empty() {
        "attachment.bin".to_string()
    } else {
        trimmed.chars().take(64).collect()
    }
}

fn truncate_chars_with_ellipsis(raw: &str, max_chars: usize) -> String {
    if raw.chars().count() <= max_chars {
        return raw.to_string();
    }
    let keep = max_chars.saturating_sub(3);
    let mut out: String = raw.chars().take(keep).collect();
    out.push_str("...");
    out
}

fn is_supported_html_tag(tag_name: &str) -> bool {
    matches!(
        tag_name,
        "b" | "strong"
            | "i"
            | "em"
            | "u"
            | "ins"
            | "s"
            | "strike"
            | "del"
            | "code"
            | "pre"
            | "a"
            | "blockquote"
            | "tg-spoiler"
    )
}

fn update_tag_stack(segment: &str, stack: &mut Vec<(String, String)>) {
    let mut idx = 0usize;
    let bytes = segment.as_bytes();
    while idx < bytes.len() {
        if bytes[idx] == b'<'
            && let Some(rel_end) = segment[idx..].find('>')
        {
            let full_tag = &segment[idx..=idx + rel_end];
            let inner = full_tag[1..full_tag.len() - 1].trim();
            if let Some(close_rest) = inner.strip_prefix('/') {
                let name = close_rest
                    .split(|c: char| c.is_ascii_whitespace() || c == '/')
                    .next()
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if let Some(pos) = stack.iter().rposition(|(t, _)| t == &name) {
                    stack.truncate(pos);
                }
            } else if !inner.is_empty() && !inner.ends_with('/') {
                let name = inner
                    .split(|c: char| c.is_ascii_whitespace() || c == '/')
                    .next()
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if is_supported_html_tag(&name) {
                    stack.push((name, full_tag.to_string()));
                }
            }
            idx += rel_end + 1;
            continue;
        }
        let ch_len = segment[idx..]
            .chars()
            .next()
            .map(char::len_utf8)
            .unwrap_or(1);
        idx += ch_len;
    }
}

/// Split an HTML-formatted message into Telegram-safe chunks (`<= max_len` chars),
/// closing and re-opening active HTML tags cleanly across chunk boundaries.
pub(crate) fn split_long_html_message(text: &str, max_len: usize) -> Vec<String> {
    let cap = max_len.max(128);
    if text.chars().count() <= cap {
        return vec![text.to_string()];
    }

    let soft_limit = cap.saturating_sub(80).max(96);
    let mut chunks = Vec::new();
    let mut open_tags: Vec<(String, String)> = Vec::new();
    let mut pos = 0usize;

    while pos < text.len() {
        let reopen_prefix: String = open_tags.iter().map(|(_, full)| full.as_str()).collect();
        let prefix_chars = reopen_prefix.chars().count();
        let target_body_chars = soft_limit.saturating_sub(prefix_chars).max(64);

        let rest = &text[pos..];
        let worst_close_chars: usize = open_tags.iter().map(|(name, _)| name.len() + 3).sum();
        if rest.chars().count() + prefix_chars + worst_close_chars <= cap {
            update_tag_stack(rest, &mut open_tags);
            let close_suffix: String = open_tags
                .iter()
                .rev()
                .map(|(name, _)| format!("</{name}>"))
                .collect();
            chunks.push(format!("{reopen_prefix}{rest}{close_suffix}"));
            break;
        }

        let mut body_chars = 0usize;
        let mut in_tag = false;
        let mut last_newline: Option<usize> = None;
        let mut last_space: Option<usize> = None;
        let mut last_safe: usize = pos;
        let mut scan_end = text.len();

        for (rel_idx, ch) in rest.char_indices() {
            let abs_idx = pos + rel_idx;
            if ch == '<' {
                in_tag = true;
            }
            if !in_tag {
                last_safe = abs_idx;
                if ch == '\n' {
                    last_newline = Some(abs_idx);
                } else if ch.is_ascii_whitespace() {
                    last_space = Some(abs_idx);
                }
            }
            if ch == '>' && in_tag {
                in_tag = false;
                last_safe = abs_idx + ch.len_utf8();
            }

            body_chars += 1;
            if body_chars >= target_body_chars && !in_tag {
                scan_end = abs_idx + ch.len_utf8();
                last_safe = scan_end;
                break;
            }
        }

        let span = scan_end.saturating_sub(pos);
        let min_preferred = pos + span / 3;
        let mut split_at = if let Some(nl) = last_newline
            && nl >= min_preferred
        {
            nl
        } else if let Some(sp) = last_space
            && sp >= min_preferred
        {
            sp
        } else {
            last_safe
        };

        if split_at <= pos {
            // Ensure forward progress even on pathological single unbreakable tags.
            let next_len = rest.chars().next().map(char::len_utf8).unwrap_or(1);
            split_at = (pos + next_len).min(text.len());
        }

        let slice = &text[pos..split_at];
        update_tag_stack(slice, &mut open_tags);
        let close_suffix: String = open_tags
            .iter()
            .rev()
            .map(|(name, _)| format!("</{name}>"))
            .collect();
        chunks.push(format!("{reopen_prefix}{slice}{close_suffix}"));

        pos = split_at;
        while pos < text.len() && matches!(text.as_bytes()[pos], b'\n' | b'\r') {
            pos += 1;
        }
    }

    if chunks.is_empty() {
        chunks.push(String::new());
    }
    chunks
}

#[derive(Debug, Clone)]
pub(crate) struct PollTransportRequest {
    pub token: String,
    pub offset: i64,
    pub timeout_secs: u64,
    pub proxy_url: Option<String>,
    pub direct_fallback: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TransportCallSpec {
    pub url: String,
    pub json_body: Option<String>,
    pub max_time_secs: u64,
    pub connect_timeout_secs: u64,
    pub proxy_url: Option<String>,
}

pub(crate) async fn curl_telegram_api_with_timeouts(
    url: &str,
    json_body: Option<&str>,
    max_time_secs: u64,
    connect_timeout_secs: u64,
    proxy_url: Option<&str>,
) -> anyhow::Result<Vec<u8>> {
    let max_t = max_time_secs.max(1);
    let conn_t = connect_timeout_secs.max(1).min(max_t);
    let mut cmd = Command::new("curl");
    cmd.kill_on_drop(true);
    cmd.args([
        "-sSL",
        "--connect-timeout",
        &conn_t.to_string(),
        "--max-time",
        &max_t.to_string(),
        "-K",
        "-",
    ]);
    if let Some(px) = proxy_url.map(str::trim).filter(|s| !s.is_empty()) {
        cmd.args(["-x", px]);
    }
    if let Some(body) = json_body {
        cmd.args(["-H", "Content-Type: application/json", "-d", body]);
    }
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    let mut child = cmd.spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        let cfg_line = format!("url = \"{}\"\n", escape_curl_config_value(url));
        let _ = stdin.write_all(cfg_line.as_bytes()).await;
        let _ = stdin.shutdown().await;
    }

    let out =
        tokio::time::timeout(Duration::from_secs(max_t + 2), child.wait_with_output()).await??;

    if !out.status.success() {
        anyhow::bail!("Telegram API transport error");
    }
    if out.stdout.is_empty() {
        anyhow::bail!("Empty response from Telegram API");
    }
    Ok(out.stdout)
}

pub(crate) async fn curl_telegram_api_once(
    url: &str,
    json_body: Option<&str>,
    timeout_secs: u64,
    proxy_url: Option<&str>,
) -> anyhow::Result<Vec<u8>> {
    curl_telegram_api_with_timeouts(
        url,
        json_body,
        timeout_secs,
        timeout_secs.clamp(1, 8),
        proxy_url,
    )
    .await
}

pub(crate) async fn poll_updates_with<F, Fut>(
    req: &PollTransportRequest,
    mut call_fn: F,
) -> anyhow::Result<serde_json::Value>
where
    F: FnMut(TransportCallSpec) -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<Vec<u8>>>,
{
    let poll_url = format!(
        "https://api.telegram.org/bot{}/getUpdates?timeout={}&offset={}",
        req.token, req.timeout_secs, req.offset
    );
    let max_time = req.timeout_secs.saturating_add(10).max(15);
    let active_proxy = req
        .proxy_url
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);

    if let Some(px) = active_proxy {
        let primary_spec = TransportCallSpec {
            url: poll_url,
            json_body: None,
            max_time_secs: max_time,
            connect_timeout_secs: 8,
            proxy_url: Some(px.clone()),
        };
        if let Ok(bytes) = call_fn(primary_spec).await
            && let Ok(val) = serde_json::from_slice::<serde_json::Value>(&bytes)
        {
            return Ok(val);
        }

        // Long-poll through proxy dropped or timed out; verify proxy liveness with short getMe
        // before deciding between idle recovery and direct fallback.
        let probe_spec = TransportCallSpec {
            url: format!("https://api.telegram.org/bot{}/getMe", req.token),
            json_body: None,
            max_time_secs: 12,
            connect_timeout_secs: 5,
            proxy_url: Some(px),
        };
        if let Ok(probe_bytes) = call_fn(probe_spec).await
            && let Ok(probe_val) = serde_json::from_slice::<serde_json::Value>(&probe_bytes)
            && probe_val.get("ok").and_then(serde_json::Value::as_bool) == Some(true)
        {
            return Ok(serde_json::json!({ "ok": true, "result": [] }));
        }

        if !req.direct_fallback {
            anyhow::bail!("Telegram proxy transport error (direct fallback disabled)");
        }

        let fallback_timeout = req.timeout_secs.min(5);
        let fallback_spec = TransportCallSpec {
            url: format!(
                "https://api.telegram.org/bot{}/getUpdates?timeout={}&offset={}",
                req.token, fallback_timeout, req.offset
            ),
            json_body: None,
            max_time_secs: fallback_timeout.saturating_add(10).max(15),
            connect_timeout_secs: 8,
            proxy_url: None,
        };
        let bytes = call_fn(fallback_spec).await?;
        let val = serde_json::from_slice::<serde_json::Value>(&bytes)?;
        return Ok(val);
    }

    let direct_spec = TransportCallSpec {
        url: poll_url,
        json_body: None,
        max_time_secs: max_time,
        connect_timeout_secs: 8,
        proxy_url: None,
    };
    let bytes = call_fn(direct_spec).await?;
    let val = serde_json::from_slice::<serde_json::Value>(&bytes)?;
    Ok(val)
}

pub(crate) async fn poll_telegram_updates(
    req: &PollTransportRequest,
) -> anyhow::Result<serde_json::Value> {
    poll_updates_with(req, |spec| async move {
        curl_telegram_api_with_timeouts(
            &spec.url,
            spec.json_body.as_deref(),
            spec.max_time_secs,
            spec.connect_timeout_secs,
            spec.proxy_url.as_deref(),
        )
        .await
    })
    .await
}

pub(crate) async fn curl_telegram_api(
    url: &str,
    json_body: Option<&str>,
    timeout_secs: u64,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<Vec<u8>> {
    if let Some(px) = proxy_url.map(str::trim).filter(|s| !s.is_empty()) {
        match curl_telegram_api_once(url, json_body, timeout_secs, Some(px)).await {
            Ok(res) if !res.is_empty() => return Ok(res),
            Ok(_) if !direct_fallback => anyhow::bail!("Empty Telegram API response via proxy"),
            Err(e) if !direct_fallback => return Err(e),
            Ok(_) | Err(_) => {}
        }
    }
    curl_telegram_api_once(url, json_body, timeout_secs, None).await
}

pub(crate) async fn probe_bot_status_via(
    token: &str,
    proxy_url: Option<&str>,
) -> (bool, String, String) {
    let clean = token.trim();
    if clean.is_empty() {
        return (false, String::new(), "Bot token is missing".to_string());
    }
    let url = format!("https://api.telegram.org/bot{clean}/getMe");
    match curl_telegram_api_once(&url, None, 6, proxy_url).await {
        Ok(bytes) => {
            if let Ok(val) = serde_json::from_slice::<Value>(&bytes) {
                if val.get("ok").and_then(Value::as_bool) == Some(true) {
                    let uname = val
                        .pointer("/result/username")
                        .and_then(Value::as_str)
                        .unwrap_or("tachyon_bot")
                        .to_string();
                    (true, uname, String::new())
                } else {
                    let desc = val
                        .get("description")
                        .and_then(Value::as_str)
                        .unwrap_or("Telegram API error")
                        .to_string();
                    (false, String::new(), desc)
                }
            } else {
                (
                    false,
                    String::new(),
                    "Invalid JSON response from Telegram API".to_string(),
                )
            }
        }
        Err(e) => (false, String::new(), format!("{e}")),
    }
}

async fn send_single_chunk(
    url: &str,
    chat_id: i64,
    chunk: &str,
    keyboard: Option<&Value>,
    disable_notification: bool,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<()> {
    let mut body = json!({
        "chat_id": chat_id,
        "text": chunk,
        "parse_mode": "HTML",
        "disable_web_page_preview": true,
    });
    if disable_notification {
        body["disable_notification"] = json!(true);
    }
    if let Some(kb) = keyboard {
        body["reply_markup"] = kb.clone();
    }
    let raw =
        curl_telegram_api(url, Some(&body.to_string()), 10, proxy_url, direct_fallback).await?;
    let val: Value = serde_json::from_slice(&raw)?;
    if val.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    let desc = val
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("Telegram sendMessage failed");
    if desc.to_ascii_lowercase().contains("can't parse entities") {
        let mut plain_body = json!({
            "chat_id": chat_id,
            "text": chunk,
            "disable_web_page_preview": true,
        });
        if disable_notification {
            plain_body["disable_notification"] = json!(true);
        }
        if let Some(kb) = keyboard {
            plain_body["reply_markup"] = kb.clone();
        }
        let raw_plain = curl_telegram_api(
            url,
            Some(&plain_body.to_string()),
            10,
            proxy_url,
            direct_fallback,
        )
        .await?;
        let val_plain: Value = serde_json::from_slice(&raw_plain)?;
        if val_plain.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(());
        }
    }
    anyhow::bail!("Telegram API error: {desc}")
}

pub(crate) async fn send_tg_message(
    token: &str,
    chat_id: i64,
    text: &str,
    keyboard: Option<&Value>,
    disable_notification: bool,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<()> {
    let clean = token.trim();
    if clean.is_empty() {
        anyhow::bail!("Bot token is missing");
    }
    let url = format!("https://api.telegram.org/bot{clean}/sendMessage");
    let chunks = split_long_html_message(text, TELEGRAM_MAX_MESSAGE_CHARS);
    let last_idx = chunks.len().saturating_sub(1);
    for (idx, chunk) in chunks.iter().enumerate() {
        let kb = if idx == last_idx { keyboard } else { None };
        send_single_chunk(
            &url,
            chat_id,
            chunk,
            kb,
            disable_notification,
            proxy_url,
            direct_fallback,
        )
        .await?;
    }
    Ok(())
}

pub(crate) async fn edit_tg_message(
    token: &str,
    chat_id: i64,
    message_id: i64,
    text: &str,
    keyboard: Option<&Value>,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<()> {
    let clean = token.trim();
    if clean.is_empty() {
        anyhow::bail!("Bot token is missing");
    }
    let chunks = split_long_html_message(text, TELEGRAM_MAX_MESSAGE_CHARS);
    if chunks.len() != 1 {
        return send_tg_message(
            clean,
            chat_id,
            text,
            keyboard,
            false,
            proxy_url,
            direct_fallback,
        )
        .await;
    }

    let url = format!("https://api.telegram.org/bot{clean}/editMessageText");
    let mut body = json!({
        "chat_id": chat_id,
        "message_id": message_id,
        "text": chunks[0],
        "parse_mode": "HTML",
        "disable_web_page_preview": true,
    });
    if let Some(kb) = keyboard {
        body["reply_markup"] = kb.clone();
    }

    if let Ok(raw) =
        curl_telegram_api(&url, Some(&body.to_string()), 8, proxy_url, direct_fallback).await
        && let Ok(val) = serde_json::from_slice::<Value>(&raw)
    {
        if val.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(());
        }
        let desc = val.get("description").and_then(Value::as_str).unwrap_or("");
        if desc
            .to_ascii_lowercase()
            .contains("message is not modified")
        {
            return Ok(());
        }
    }

    send_tg_message(
        clean,
        chat_id,
        text,
        keyboard,
        false,
        proxy_url,
        direct_fallback,
    )
    .await
}

pub(crate) async fn answer_callback_query(
    token: &str,
    callback_query_id: &str,
    text: Option<&str>,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) {
    let clean = token.trim();
    if clean.is_empty() || callback_query_id.trim().is_empty() {
        return;
    }
    let url = format!("https://api.telegram.org/bot{clean}/answerCallbackQuery");
    let mut body = json!({
        "callback_query_id": callback_query_id,
    });
    if let Some(msg) = text.filter(|s| !s.trim().is_empty()) {
        body["text"] = json!(truncate_chars_with_ellipsis(msg, 180));
    }
    let _ = curl_telegram_api(&url, Some(&body.to_string()), 5, proxy_url, direct_fallback).await;
}

pub(crate) struct TgDocument<'a> {
    pub filename: &'a str,
    pub bytes: &'a [u8],
    pub caption: &'a str,
    pub keyboard: Option<&'a Value>,
    pub disable_notification: bool,
}

#[derive(Clone, Copy)]
struct TgDocumentAttempt<'a> {
    url: &'a str,
    chat_id: i64,
    tmp_path: &'a Path,
    safe_name: &'a str,
    caption: &'a str,
    keyboard_json: Option<&'a str>,
    disable_notification: bool,
    proxy_url: Option<&'a str>,
}

async fn send_tg_document_once(req: &TgDocumentAttempt<'_>) -> anyhow::Result<Vec<u8>> {
    let mut cmd = Command::new("curl");
    cmd.kill_on_drop(true);
    cmd.args(["-sSL", "--max-time", "25", "-K", "-"]);
    if let Some(px) = req.proxy_url.map(str::trim).filter(|s| !s.is_empty()) {
        cmd.args(["-x", px]);
    }
    let chat_arg = format!("chat_id={}", req.chat_id);
    let doc_arg = format!(
        "document=@{};filename={}",
        req.tmp_path.display(),
        req.safe_name
    );
    cmd.args(["--form-string", &chat_arg, "-F", &doc_arg]);

    if !req.caption.trim().is_empty() {
        let cap_trunc = truncate_chars_with_ellipsis(req.caption, TELEGRAM_MAX_CAPTION_CHARS);
        let cap_arg = format!("caption={cap_trunc}");
        cmd.args([
            "--form-string",
            &cap_arg,
            "--form-string",
            "parse_mode=HTML",
        ]);
    }
    if req.disable_notification {
        cmd.args(["--form-string", "disable_notification=true"]);
    }
    if let Some(kb_str) = req.keyboard_json {
        let kb_arg = format!("reply_markup={kb_str}");
        cmd.args(["--form-string", &kb_arg]);
    }

    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    let mut child = cmd.spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        let cfg_line = format!("url = \"{}\"\n", escape_curl_config_value(req.url));
        let _ = stdin.write_all(cfg_line.as_bytes()).await;
        let _ = stdin.shutdown().await;
    }

    let out = tokio::time::timeout(Duration::from_secs(28), child.wait_with_output()).await??;
    if !out.status.success() {
        anyhow::bail!("Telegram sendDocument transport error");
    }
    if out.stdout.is_empty() {
        anyhow::bail!("Empty response from Telegram sendDocument");
    }
    Ok(out.stdout)
}

pub(crate) async fn send_tg_document(
    token: &str,
    chat_id: i64,
    doc: &TgDocument<'_>,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<()> {
    let clean = token.trim();
    if clean.is_empty() {
        anyhow::bail!("Bot token is missing");
    }
    let safe_name = sanitize_upload_filename(doc.filename);
    let pid = std::process::id();
    let seq = UPLOAD_SEQ.fetch_add(1, Ordering::Relaxed);
    let tmp_dir = if Path::new("/tmp").is_dir() {
        PathBuf::from("/tmp")
    } else {
        std::env::temp_dir()
    };
    let tmp_path = tmp_dir.join(format!("tachyon-tg-upload-{pid}-{seq}-{safe_name}"));
    {
        use std::io::Write as _;
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut file = opts.open(&tmp_path)?;
        file.write_all(doc.bytes)?;
    }
    let _cleanup = RemoveFileOnDrop(tmp_path.clone());

    let url = format!("https://api.telegram.org/bot{clean}/sendDocument");
    let kb_str = doc.keyboard.map(Value::to_string);
    let base_attempt = TgDocumentAttempt {
        url: &url,
        chat_id,
        tmp_path: &tmp_path,
        safe_name: &safe_name,
        caption: doc.caption,
        keyboard_json: kb_str.as_deref(),
        disable_notification: doc.disable_notification,
        proxy_url: None,
    };

    let raw = if let Some(px) = proxy_url.map(str::trim).filter(|s| !s.is_empty()) {
        let via_proxy = TgDocumentAttempt {
            proxy_url: Some(px),
            ..base_attempt
        };
        match send_tg_document_once(&via_proxy).await {
            Ok(b) => b,
            Err(e) => {
                if !direct_fallback {
                    return Err(e);
                }
                send_tg_document_once(&base_attempt).await?
            }
        }
    } else {
        send_tg_document_once(&base_attempt).await?
    };

    let val: Value = serde_json::from_slice(&raw)?;
    if val.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    let desc = val
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("Telegram sendDocument failed");
    anyhow::bail!("Telegram API error: {desc}")
}

pub(crate) async fn register_bot_commands(
    token: &str,
    ru: bool,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<()> {
    let clean = token.trim();
    if clean.is_empty() {
        anyhow::bail!("Bot token is missing");
    }
    let cmds = if ru {
        json!({
            "commands": [
                {"command": "start", "description": "Главная панель управления"},
                {"command": "status", "description": "Статус ядра, CPU, RAM и трафика"},
                {"command": "sections", "description": "Секции маршрутизации и правила"},
                {"command": "sources", "description": "Источники, подписки и узлы"},
                {"command": "servers", "description": "Входящие VPN-серверы"},
                {"command": "devices", "description": "Устройства LAN и Wake-on-LAN"},
                {"command": "doctor", "description": "Диагностика 16 подсистем"},
                {"command": "ai_doctor", "description": "Анализ AI Doctor"},
                {"command": "trace", "description": "Трассировка маршрута домена"},
                {"command": "dns", "description": "Проверка и настройка DNS"},
                {"command": "fuzzer", "description": "Подбор параметров desync"},
                {"command": "updates", "description": "Обновления компонентов и списков"},
                {"command": "snapshots", "description": "Снапшоты и перенос конфигурации"},
                {"command": "restart", "description": "Перезапуск tachyon-core"},
                {"command": "toggles", "description": "Быстрые переключатели опций"},
                {"command": "notify", "description": "Настройки уведомлений"},
                {"command": "bot_settings", "description": "Настройки Telegram-бота"},
                {"command": "cancel", "description": "Отменить текущий ввод"}
            ]
        })
    } else {
        json!({
            "commands": [
                {"command": "start", "description": "Main control menu"},
                {"command": "status", "description": "Core, CPU, RAM and traffic status"},
                {"command": "sections", "description": "Routing sections and rules"},
                {"command": "sources", "description": "Outbound sources and nodes"},
                {"command": "servers", "description": "Inbound VPN servers"},
                {"command": "devices", "description": "LAN devices and Wake-on-LAN"},
                {"command": "doctor", "description": "Run 16 subsystem checks"},
                {"command": "ai_doctor", "description": "AI Doctor analysis"},
                {"command": "trace", "description": "Trace domain routing path"},
                {"command": "dns", "description": "DNS check and presets"},
                {"command": "fuzzer", "description": "Desync parameter tuner"},
                {"command": "updates", "description": "Component and rule list updates"},
                {"command": "snapshots", "description": "Snapshots and transfer codes"},
                {"command": "restart", "description": "Reload tachyon-core"},
                {"command": "toggles", "description": "Quick feature toggles"},
                {"command": "notify", "description": "Notification filters"},
                {"command": "bot_settings", "description": "Telegram bot settings"},
                {"command": "cancel", "description": "Cancel active input"}
            ]
        })
    };
    let url = format!("https://api.telegram.org/bot{clean}/setMyCommands");
    let raw =
        curl_telegram_api(&url, Some(&cmds.to_string()), 8, proxy_url, direct_fallback).await?;
    let val: Value = serde_json::from_slice(&raw)?;
    if val.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        let desc = val
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("setMyCommands failed");
        anyhow::bail!("Telegram API error: {desc}")
    }
}

pub(crate) async fn download_telegram_document_text(
    token: &str,
    file_id: &str,
    proxy_url: Option<&str>,
    direct_fallback: bool,
) -> anyhow::Result<String> {
    const MAX_DOCUMENT_BYTES: usize = 262_144;
    let clean_token = token.trim();
    let clean_file_id = file_id.trim();
    if clean_token.is_empty() || clean_file_id.is_empty() {
        anyhow::bail!("Bot token or file_id is missing");
    }

    let get_file_url = format!("https://api.telegram.org/bot{clean_token}/getFile");
    let body = json!({ "file_id": clean_file_id }).to_string();
    let meta_raw =
        curl_telegram_api(&get_file_url, Some(&body), 10, proxy_url, direct_fallback).await?;
    let meta: Value = serde_json::from_slice(&meta_raw)?;
    if meta.get("ok").and_then(Value::as_bool) != Some(true) {
        let desc = meta
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("getFile failed");
        anyhow::bail!("Telegram getFile error: {desc}");
    }
    if let Some(sz) = meta.pointer("/result/file_size").and_then(Value::as_u64)
        && sz > MAX_DOCUMENT_BYTES as u64
    {
        anyhow::bail!("Document exceeds {MAX_DOCUMENT_BYTES} bytes limit");
    }
    let file_path = meta
        .pointer("/result/file_path")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| {
            !s.is_empty()
                && !s.contains("..")
                && !s.chars().any(|c| c.is_control() || c == '?' || c == '#')
        })
        .ok_or_else(|| anyhow::anyhow!("Invalid or missing Telegram file_path"))?;

    let download_url = format!("https://api.telegram.org/file/bot{clean_token}/{file_path}");
    let bytes = curl_telegram_api(&download_url, None, 15, proxy_url, direct_fallback).await?;
    if bytes.len() > MAX_DOCUMENT_BYTES {
        anyhow::bail!("Downloaded document exceeds {MAX_DOCUMENT_BYTES} bytes limit");
    }
    Ok(String::from_utf8(bytes)?)
}
