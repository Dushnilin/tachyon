//! Pure-Rust multi-router fleet client, background health monitor, and
//! interactive Telegram Bot UI handlers for managing remote Tachyon nodes.
//!
//! Security & flash-wear invariants:
//! - Remote router `api_token` values are transmitted solely via the
//!   `Authorization: Bearer <token>` HTTP header (written over TCP for `http://`
//!   or passed via `curl -K -` stdin pipe for `https://`, never on CLI argv,
//!   in env vars, logs, errors, or Telegram replies).
//! - Fleet health tracking lives in memory and mirrors sanitized status snapshots
//!   to tmpfs (`runtime_state_dir()`) via `write_json_if_changed`.

use std::collections::{HashMap, HashSet};
use std::net::Ipv6Addr;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::process::Command;

use crate::crypto_gen;
use crate::store::{AppState, ManagedRouter, runtime_state_dir, unix_now_secs};
use crate::transaction::commit_transaction;
use crate::updater;

use super::{
    BotReply, PendingPromptKind, cb_btn, clear_chat_prompt, escape_html, inline_kb, is_ru,
    notify_bot_wakeup, set_chat_prompt, tr,
};

pub(crate) const FLEET_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
pub(crate) const FLEET_REQUEST_TIMEOUT: Duration = Duration::from_secs(6);
pub(crate) const FLEET_ACTION_TIMEOUT: Duration = Duration::from_secs(15);
pub(crate) const MAX_FLEET_RESP_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_MANAGED_ROUTERS: usize = 64;
pub(crate) const FLEET_PER_PAGE: usize = 6;
pub(crate) const FLEET_MONITOR_INTERVAL_SECS: i64 = 60;
pub(crate) const FLEET_FAILURE_THRESHOLD: u32 = 2;
pub(crate) const FLEET_RECOVERY_THRESHOLD: u32 = 2;
pub(crate) const FLEET_ALERT_COOLDOWN_SECS: i64 = 300;
const FLEET_HEALTH_CACHE_FILE: &str = "fleet-health.json";
const FLEET_PROBE_CONCURRENCY: usize = 8;
const POST_VERIFY_ATTEMPTS: usize = 3;
const POST_VERIFY_RETRY_DELAY: Duration = Duration::from_millis(500);

struct AbortHandlesOnDrop(Vec<tokio::task::AbortHandle>);

impl Drop for AbortHandlesOnDrop {
    fn drop(&mut self) {
        for h in &self.0 {
            h.abort();
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ParsedRouterUrl {
    pub scheme: String,
    pub connect_host: String,
    pub host_header: String,
    pub port: u16,
    pub base_path: String,
    pub normalized_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FleetHttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FleetError {
    InvalidConfig(String),
    AuthRejected { status: u16 },
    HttpStatus { status: u16, message: String },
    Unreachable(String),
}

impl FleetError {
    pub(crate) fn auth_status(&self) -> Option<u16> {
        match self {
            Self::AuthRejected { status } => Some(*status),
            _ => None,
        }
    }

    pub(crate) fn display_sanitized(&self, ru: bool) -> String {
        match self {
            Self::InvalidConfig(msg) => msg.clone(),
            Self::AuthRejected { status } => {
                if ru {
                    format!("HTTP {status}: доступ отклонён (проверьте API token)")
                } else {
                    format!("HTTP {status}: authorization rejected (check API token)")
                }
            }
            Self::HttpStatus { status, message } => {
                if message.is_empty() {
                    format!("HTTP {status}")
                } else {
                    format!("HTTP {status}: {message}")
                }
            }
            Self::Unreachable(msg) => msg.clone(),
        }
    }
}

pub(crate) fn sanitize_fleet_error(raw: &str, secret_token: &str) -> String {
    let mut cleaned = raw.trim().to_string();
    for tok in [secret_token, secret_token.trim()] {
        if !tok.is_empty() && cleaned.contains(tok) {
            cleaned = cleaned.replace(tok, "[REDACTED]");
        }
    }
    let scrubbed = crypto_gen::redact_string(&cleaned);
    let compact: String = scrubbed
        .chars()
        .map(|c| {
            if matches!(c, '\r' | '\n' | '\0') {
                ' '
            } else {
                c
            }
        })
        .take(240)
        .collect();
    compact.trim().to_string()
}

pub(crate) fn sanitize_display_url(raw: &str) -> String {
    match normalize_and_validate_router_url(raw) {
        Ok(p) => p.normalized_url,
        Err(_) => {
            let trimmed = raw.trim();
            let without_query = trimmed.split(['?', '#']).next().unwrap_or(trimmed);
            if let Some(scheme_pos) = without_query.find("://") {
                let after = &without_query[scheme_pos + 3..];
                if let Some(at_rel) = after.find('@') {
                    let slash_rel = after.find('/').unwrap_or(after.len());
                    if at_rel < slash_rel {
                        return format!(
                            "{}://[REDACTED]@{}",
                            &without_query[..scheme_pos],
                            &after[at_rel + 1..]
                        );
                    }
                }
            }
            crypto_gen::redact_string(without_query)
        }
    }
}

pub(crate) fn normalize_and_validate_router_url(raw: &str) -> Result<ParsedRouterUrl, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 512 {
        return Err("URL must be 1..512 characters".to_string());
    }
    if trimmed.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("URL must not contain spaces or control characters".to_string());
    }
    if trimmed.contains('?') || trimmed.contains('#') || trimmed.contains('@') {
        return Err(
            "URL must be a plain base http(s)://host[:port] without credentials or query"
                .to_string(),
        );
    }

    let (scheme, rest) = if let Some(idx) = trimmed.find("://") {
        let raw_scheme = &trimmed[..idx];
        let after = &trimmed[idx + 3..];
        if raw_scheme.eq_ignore_ascii_case("http") {
            ("http".to_string(), after)
        } else if raw_scheme.eq_ignore_ascii_case("https") {
            ("https".to_string(), after)
        } else {
            return Err(format!(
                "Unsupported URL scheme '{raw_scheme}' (use http:// or https://)"
            ));
        }
    } else {
        ("http".to_string(), trimmed)
    };

    let (authority, raw_path) = match rest.find('/') {
        Some(pos) => (&rest[..pos], &rest[pos..]),
        None => (rest, ""),
    };
    if authority.is_empty() {
        return Err("URL host is empty".to_string());
    }

    let default_port = if scheme == "https" { 443u16 } else { 80u16 };
    let (connect_host, port, host_header) = if let Some(after_open) = authority.strip_prefix('[') {
        let Some(close_idx) = after_open.find(']') else {
            return Err("Unclosed IPv6 host bracket".to_string());
        };
        let ipv6_str = &after_open[..close_idx];
        if ipv6_str.is_empty() || ipv6_str.parse::<Ipv6Addr>().is_err() {
            return Err("Invalid IPv6 host literal".to_string());
        }
        let tail = &after_open[close_idx + 1..];
        let port = if tail.is_empty() {
            default_port
        } else if let Some(port_s) = tail.strip_prefix(':') {
            let p = port_s
                .parse::<u16>()
                .map_err(|_| "Invalid port number".to_string())?;
            if p == 0 {
                return Err("Port cannot be 0".to_string());
            }
            p
        } else {
            return Err("Invalid authority after IPv6 address".to_string());
        };
        let hdr = if port == default_port {
            format!("[{ipv6_str}]")
        } else {
            format!("[{ipv6_str}]:{port}")
        };
        (ipv6_str.to_string(), port, hdr)
    } else {
        let (host_str, port) = match authority.split_once(':') {
            Some((h, p_s)) => {
                if p_s.contains(':') {
                    return Err("IPv6 addresses must be enclosed in brackets [...]".to_string());
                }
                let p = p_s
                    .parse::<u16>()
                    .map_err(|_| "Invalid port number".to_string())?;
                if p == 0 {
                    return Err("Port cannot be 0".to_string());
                }
                (h, p)
            }
            None => (authority, default_port),
        };
        if host_str.is_empty()
            || !host_str
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        {
            return Err("Invalid router host".to_string());
        }
        let hdr = if port == default_port {
            host_str.to_string()
        } else {
            format!("{host_str}:{port}")
        };
        (host_str.to_string(), port, hdr)
    };

    let clean_path = raw_path.trim_end_matches('/');
    let base_path = if clean_path == "/" {
        String::new()
    } else {
        clean_path.to_string()
    };
    let normalized_url = format!("{scheme}://{host_header}{base_path}");

    Ok(ParsedRouterUrl {
        scheme,
        connect_host,
        host_header,
        port,
        base_path,
        normalized_url,
    })
}

pub(crate) fn validate_router_name(raw: &str) -> Result<String, String> {
    let clean: String = raw
        .trim()
        .chars()
        .filter(|&c| !matches!(c, '<' | '>' | '\r' | '\n' | '\0'))
        .take(48)
        .collect();
    let trimmed = clean.trim().to_string();
    if trimmed.is_empty() {
        return Err("Router name must not be empty (1..48 chars)".to_string());
    }
    Ok(trimmed)
}

pub(crate) fn validate_api_token(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 512 {
        return Err("API token must be 1..512 characters".to_string());
    }
    if trimmed.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("API token must not contain whitespace or control characters".to_string());
    }
    Ok(trimmed.to_string())
}

pub(crate) fn generate_unique_router_id(name: &str, existing: &[ManagedRouter]) -> String {
    let mut slug = String::with_capacity(16);
    let mut last_dash = false;
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            last_dash = false;
        } else if !slug.is_empty() && !last_dash {
            slug.push('-');
            last_dash = true;
        }
        if slug.len() >= 14 {
            break;
        }
    }
    let slug = slug.trim_matches('-');
    let base = if slug.is_empty() {
        format!("r-{}", unix_now_secs() % 100_000)
    } else {
        format!("r-{slug}")
    };
    let taken = |cand: &str| existing.iter().any(|r| r.id == cand);
    if !taken(&base) {
        return base;
    }
    for i in 2..1000usize {
        let cand = format!("{base}-{i}");
        if !taken(&cand) {
            return cand;
        }
    }
    format!("r-{}", unix_now_secs())
}

fn escape_curl_cfg_val(raw: &str) -> String {
    raw.replace('\\', "\\\\").replace('"', "\\\"")
}

pub(crate) fn build_curl_stdin_config(url: &str, token: &str) -> Result<String, FleetError> {
    if url.chars().any(|c| matches!(c, '\r' | '\n' | '\0')) {
        return Err(FleetError::InvalidConfig(
            "Invalid control character in URL".to_string(),
        ));
    }
    if token.chars().any(|c| matches!(c, '\r' | '\n' | '\0')) {
        return Err(FleetError::InvalidConfig(
            "Invalid control character in API token".to_string(),
        ));
    }
    let mut out = String::new();
    out.push_str(&format!("url = \"{}\"\n", escape_curl_cfg_val(url)));
    if !token.trim().is_empty() {
        out.push_str(&format!(
            "header = \"Authorization: Bearer {}\"\n",
            escape_curl_cfg_val(token.trim())
        ));
    }
    out.push_str("header = \"Accept: application/json\"\n");
    out.push_str("user-agent = \"tachyon-fleet/2.0\"\n");
    Ok(out)
}

fn find_http_header_end(buf: &[u8]) -> Option<(usize, usize)> {
    let mut i = 0usize;
    while i + 1 < buf.len() {
        if i + 3 < buf.len() && &buf[i..i + 4] == b"\r\n\r\n" {
            return Some((i, i + 4));
        }
        if &buf[i..i + 2] == b"\n\n" {
            return Some((i, i + 2));
        }
        i += 1;
    }
    None
}

fn decode_chunked_body(raw: &[u8], max_bytes: usize) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    loop {
        let rest = &raw[pos..];
        let Some(nl_rel) = rest.iter().position(|&b| b == b'\n') else {
            return Err("Incomplete chunked HTTP response".to_string());
        };
        let line_bytes = &rest[..nl_rel];
        let line_str = String::from_utf8_lossy(line_bytes);
        let size_hex = line_str
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .trim_end_matches('\r');
        let chunk_len = usize::from_str_radix(size_hex, 16)
            .map_err(|_| "Invalid HTTP chunk size".to_string())?;
        pos += nl_rel + 1;
        if chunk_len == 0 {
            break;
        }
        let next_total = out
            .len()
            .checked_add(chunk_len)
            .ok_or_else(|| "Chunked HTTP body size overflow".to_string())?;
        if next_total > max_bytes {
            return Err("HTTP response body exceeded size limit".to_string());
        }
        let chunk_end = pos
            .checked_add(chunk_len)
            .ok_or_else(|| "Chunked HTTP offset overflow".to_string())?;
        if chunk_end > raw.len() {
            return Err("Truncated chunked HTTP body".to_string());
        }
        out.extend_from_slice(&raw[pos..chunk_end]);
        pos = chunk_end;
        if pos < raw.len() && raw[pos] == b'\r' {
            pos += 1;
        }
        if pos < raw.len() && raw[pos] == b'\n' {
            pos += 1;
        }
    }
    Ok(out)
}

pub(crate) fn parse_http_response(
    raw: &[u8],
    decode_chunked: bool,
) -> Result<FleetHttpResponse, String> {
    let mut offset = 0usize;
    loop {
        let slice = &raw[offset..];
        let Some((hdr_end, body_rel_start)) = find_http_header_end(slice) else {
            return Err("Malformed HTTP response (missing header terminator)".to_string());
        };
        let head_str = String::from_utf8_lossy(&slice[..hdr_end]);
        let mut lines = head_str.lines();
        let status_line = lines.next().unwrap_or("").trim();
        let mut status_parts = status_line.split_whitespace();
        let proto = status_parts.next().unwrap_or("");
        let status_code = status_parts
            .next()
            .and_then(|s| s.parse::<u16>().ok())
            .filter(|&code| (100..=599).contains(&code))
            .ok_or_else(|| "Malformed HTTP status line".to_string())?;
        if !proto.starts_with("HTTP/") {
            return Err("Malformed HTTP protocol prefix".to_string());
        }

        if status_code / 100 == 1 {
            offset += body_rel_start;
            continue;
        }

        let mut content_length: Option<usize> = None;
        let mut is_chunked = false;
        for line in lines {
            if let Some((k, v)) = line.split_once(':') {
                let key = k.trim();
                let val = v.trim();
                if key.eq_ignore_ascii_case("content-length") {
                    if let Ok(len) = val.parse::<usize>() {
                        if len > MAX_FLEET_RESP_BYTES {
                            return Err("HTTP Content-Length exceeds 1 MiB limit".to_string());
                        }
                        content_length = Some(len);
                    }
                } else if key.eq_ignore_ascii_case("transfer-encoding")
                    && val.to_ascii_lowercase().contains("chunked")
                {
                    is_chunked = true;
                }
            }
        }

        let body_slice = &slice[body_rel_start..];
        let body = if decode_chunked && is_chunked {
            decode_chunked_body(body_slice, MAX_FLEET_RESP_BYTES)?
        } else if let Some(expected_len) = content_length {
            if body_slice.len() < expected_len {
                return Err("Truncated HTTP response body".to_string());
            }
            body_slice[..expected_len].to_vec()
        } else {
            if body_slice.len() > MAX_FLEET_RESP_BYTES {
                return Err("HTTP response body exceeded 1 MiB limit".to_string());
            }
            body_slice.to_vec()
        };

        return Ok(FleetHttpResponse {
            status: status_code,
            body,
        });
    }
}

async fn http_plain_request(
    parsed: &ParsedRouterUrl,
    method: &str,
    full_path: &str,
    json_body: Option<&str>,
    token: &str,
    timeout: Duration,
) -> Result<FleetHttpResponse, FleetError> {
    let mut stream = tokio::time::timeout(
        FLEET_CONNECT_TIMEOUT,
        TcpStream::connect((parsed.connect_host.as_str(), parsed.port)),
    )
    .await
    .map_err(|_| FleetError::Unreachable("Connection timed out".to_string()))?
    .map_err(|e| FleetError::Unreachable(sanitize_fleet_error(&e.to_string(), token)))?;
    let _ = stream.set_nodelay(true);

    let body_bytes = json_body.unwrap_or("").as_bytes();
    let mut req = format!(
        "{method} {full_path} HTTP/1.1\r\n\
         Host: {}\r\n\
         Accept: application/json\r\n\
         User-Agent: tachyon-fleet/2.0\r\n\
         Connection: close\r\n",
        parsed.host_header
    );
    let clean_tok = token.trim();
    if !clean_tok.is_empty() {
        req.push_str(&format!("Authorization: Bearer {clean_tok}\r\n"));
    }
    if json_body.is_some() {
        req.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body_bytes.len()
        ));
    }
    req.push_str("\r\n");

    let io_res = tokio::time::timeout(timeout, async {
        stream.write_all(req.as_bytes()).await?;
        if !body_bytes.is_empty() {
            stream.write_all(body_bytes).await?;
        }
        stream.flush().await?;

        let max_wire_bytes = MAX_FLEET_RESP_BYTES + 16_384;
        let mut buf = Vec::with_capacity(4096);
        let mut chunk = [0u8; 8192];
        loop {
            let n = stream.read(&mut chunk).await?;
            if n == 0 {
                break;
            }
            if buf.len().saturating_add(n) > max_wire_bytes {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Response exceeded maximum allowed size",
                ));
            }
            buf.extend_from_slice(&chunk[..n]);
        }
        Ok::<Vec<u8>, std::io::Error>(buf)
    })
    .await
    .map_err(|_| FleetError::Unreachable("Request timed out".to_string()))?
    .map_err(|e| FleetError::Unreachable(sanitize_fleet_error(&e.to_string(), token)))?;

    parse_http_response(&io_res, true)
        .map_err(|e| FleetError::Unreachable(sanitize_fleet_error(&e, token)))
}

async fn https_curl_request(
    parsed: &ParsedRouterUrl,
    method: &str,
    full_path: &str,
    json_body: Option<&str>,
    token: &str,
    timeout: Duration,
) -> Result<FleetHttpResponse, FleetError> {
    let full_url = format!("{}://{}{}", parsed.scheme, parsed.host_header, full_path);
    let stdin_cfg = build_curl_stdin_config(&full_url, token)?;

    let conn_secs = FLEET_CONNECT_TIMEOUT.as_secs().max(1);
    let max_secs = timeout.as_secs().max(conn_secs + 1);

    let mut cmd = Command::new("curl");
    cmd.kill_on_drop(true);
    cmd.args([
        "-sS",
        "-i",
        "--connect-timeout",
        &conn_secs.to_string(),
        "--max-time",
        &max_secs.to_string(),
        "-X",
        method,
        "-K",
        "-",
    ]);
    if let Some(body) = json_body {
        cmd.args(["-H", "Content-Type: application/json", "-d", body]);
    }
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| FleetError::Unreachable(sanitize_fleet_error(&e.to_string(), token)))?;

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(stdin_cfg.as_bytes()).await;
        let _ = stdin.shutdown().await;
    }

    let out = tokio::time::timeout(
        Duration::from_secs(max_secs.saturating_add(2)),
        child.wait_with_output(),
    )
    .await
    .map_err(|_| FleetError::Unreachable("HTTPS request timed out".to_string()))?
    .map_err(|e| FleetError::Unreachable(sanitize_fleet_error(&e.to_string(), token)))?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let msg = sanitize_fleet_error(&stderr, token);
        return Err(FleetError::Unreachable(if msg.is_empty() {
            "HTTPS transport error".to_string()
        } else {
            msg
        }));
    }

    if out.stdout.len() > MAX_FLEET_RESP_BYTES + 16_384 {
        return Err(FleetError::Unreachable(
            "HTTPS response exceeded maximum allowed size".to_string(),
        ));
    }

    parse_http_response(&out.stdout, false)
        .map_err(|e| FleetError::Unreachable(sanitize_fleet_error(&e, token)))
}

async fn router_request_raw(
    router: &ManagedRouter,
    method: &str,
    api_path: &str,
    json_body: Option<&str>,
    timeout: Duration,
) -> Result<FleetHttpResponse, FleetError> {
    let parsed =
        normalize_and_validate_router_url(&router.url).map_err(FleetError::InvalidConfig)?;
    if router
        .api_token
        .chars()
        .any(|c| matches!(c, '\r' | '\n' | '\0'))
    {
        return Err(FleetError::InvalidConfig(
            "Invalid control character in API token".to_string(),
        ));
    }
    let clean_path = if api_path.starts_with('/') {
        api_path.to_string()
    } else {
        format!("/{api_path}")
    };
    let full_path = format!("{}{}", parsed.base_path, clean_path);
    if parsed.scheme == "https" {
        https_curl_request(
            &parsed,
            method,
            &full_path,
            json_body,
            &router.api_token,
            timeout,
        )
        .await
    } else {
        http_plain_request(
            &parsed,
            method,
            &full_path,
            json_body,
            &router.api_token,
            timeout,
        )
        .await
    }
}

pub(crate) async fn router_request_json(
    router: &ManagedRouter,
    method: &str,
    api_path: &str,
    body: Option<&Value>,
    timeout: Duration,
) -> Result<Value, FleetError> {
    let body_str = body.map(Value::to_string);
    let resp = router_request_raw(router, method, api_path, body_str.as_deref(), timeout).await?;

    if matches!(resp.status, 401 | 403) {
        return Err(FleetError::AuthRejected {
            status: resp.status,
        });
    }
    if !(200..300).contains(&resp.status) {
        let parsed_err = serde_json::from_slice::<Value>(&resp.body)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .or_else(|| v.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_default();
        let safe_msg = sanitize_fleet_error(&parsed_err, &router.api_token);
        return Err(FleetError::HttpStatus {
            status: resp.status,
            message: safe_msg,
        });
    }

    serde_json::from_slice::<Value>(&resp.body).map_err(|e| {
        FleetError::Unreachable(sanitize_fleet_error(
            &format!("Invalid JSON response: {e}"),
            &router.api_token,
        ))
    })
}

async fn call_remote_ubus_tachyon_cli(
    router: &ManagedRouter,
    params: &[&str],
    timeout: Duration,
) -> Result<Value, FleetError> {
    let rpc = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "call",
        "params": [
            "00000000000000000000000000000000",
            "file",
            "exec",
            {
                "command": "/usr/bin/tachyon",
                "params": params,
            }
        ]
    });
    let resp = router_request_json(router, "POST", "/ubus", Some(&rpc), timeout).await?;
    let stdout = resp
        .pointer("/result/1/stdout")
        .and_then(Value::as_str)
        .unwrap_or("");
    if stdout.trim().is_empty() {
        return Err(FleetError::Unreachable(
            "Empty stdout from remote ubus command".to_string(),
        ));
    }
    serde_json::from_str::<Value>(stdout).map_err(|e| {
        FleetError::Unreachable(sanitize_fleet_error(
            &format!("Invalid JSON from remote ubus command: {e}"),
            &router.api_token,
        ))
    })
}

#[derive(Debug, Clone, Default)]
pub(crate) struct RouterOverviewSnapshot {
    pub router_id: String,
    pub router_name: String,
    pub url: String,
    pub enabled: bool,
    pub reachable: bool,
    pub auth_error: Option<u16>,
    pub error: Option<String>,
    pub tachyon_version: String,
    pub core_version: String,
    pub core_running: Option<bool>,
    pub wan_healthy: Option<bool>,
    pub dns_healthy: Option<bool>,
    pub active_connections: Option<u64>,
    pub uptime_secs: Option<u64>,
    pub mem_used_mb: Option<u64>,
    pub mem_total_mb: Option<u64>,
    pub hostname: String,
    pub model: String,
    pub doctor_healthy: Option<bool>,
    pub doctor_passed: Option<u64>,
    pub doctor_total: Option<u64>,
    pub doctor_summary: String,
    pub doctor_findings: Vec<String>,
}

fn apply_telemetry_json(snap: &mut RouterOverviewSnapshot, val: &Value) {
    if let Some(sys) = val.get("system") {
        if let Some(h) = sys.get("hostname").and_then(Value::as_str) {
            snap.hostname = h.trim().to_string();
        }
        if let Some(m) = sys.get("router_model").and_then(Value::as_str) {
            snap.model = m.trim().to_string();
        }
        snap.mem_used_mb = sys.get("memory_used_mb").and_then(Value::as_u64);
        snap.mem_total_mb = sys.get("memory_total_mb").and_then(Value::as_u64);
        if snap.uptime_secs.is_none() {
            snap.uptime_secs = sys.get("host_uptime_secs").and_then(Value::as_u64);
        }
    }
    if let Some(live) = val.get("live") {
        snap.core_running = live.get("core_running").and_then(Value::as_bool);
        if let Some(cv) = live
            .get("core_version")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            snap.core_version = cv.to_string();
        }
        snap.wan_healthy = live.get("wan_healthy").and_then(Value::as_bool);
        snap.dns_healthy = live.get("dns_healthy").and_then(Value::as_bool);
        snap.active_connections = live.get("active_connections").and_then(Value::as_u64);
        if let Some(up) = live.get("core_uptime_secs").and_then(Value::as_u64) {
            snap.uptime_secs = Some(up);
        }
    }
}

fn apply_updates_json(snap: &mut RouterOverviewSnapshot, val: &Value) {
    if let Some(tv) = val
        .get("orchestrator_version")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        snap.tachyon_version = tv.to_string();
    }
    if snap.core_version.is_empty()
        && let Some(cv) = val
            .get("core_installed")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
    {
        snap.core_version = cv.to_string();
    }
}

fn apply_doctor_json(snap: &mut RouterOverviewSnapshot, val: &Value) {
    snap.doctor_healthy = val.get("healthy").and_then(Value::as_bool);
    snap.doctor_passed = val.get("checks_passed").and_then(Value::as_u64);
    snap.doctor_total = val.get("checks_total").and_then(Value::as_u64);
    if let Some(s) = val.get("summary").and_then(Value::as_str) {
        snap.doctor_summary = s.trim().to_string();
    }
    if let Some(arr) = val.get("findings").and_then(Value::as_array) {
        snap.doctor_findings = arr
            .iter()
            .filter(|f| f.get("suppressed_by").is_none_or(Value::is_null))
            .take(4)
            .filter_map(|f| {
                let title = f.get("title").and_then(Value::as_str).unwrap_or("").trim();
                let detail = f.get("detail").and_then(Value::as_str).unwrap_or("").trim();
                if title.is_empty() && detail.is_empty() {
                    None
                } else if detail.is_empty() {
                    Some(title.to_string())
                } else {
                    Some(format!("{title}: {detail}"))
                }
            })
            .collect();
    }
}

pub(crate) async fn probe_router_overview(
    router: &ManagedRouter,
    include_doctor: bool,
) -> RouterOverviewSnapshot {
    let mut snap = RouterOverviewSnapshot {
        router_id: router.id.clone(),
        router_name: router.name.clone(),
        url: sanitize_display_url(&router.url),
        enabled: router.enabled,
        ..Default::default()
    };
    if !router.enabled {
        return snap;
    }

    let telemetry_fut =
        router_request_json(router, "GET", "/api/telemetry", None, FLEET_REQUEST_TIMEOUT);
    let updates_fut = router_request_json(
        router,
        "GET",
        "/api/updates/check",
        None,
        FLEET_REQUEST_TIMEOUT,
    );
    let doctor_fut = async {
        if include_doctor {
            Some(
                router_request_json(
                    router,
                    "GET",
                    "/api/diagnostics/doctor",
                    None,
                    FLEET_REQUEST_TIMEOUT,
                )
                .await,
            )
        } else {
            None
        }
    };

    let (tele_res, upd_res, doc_opt) = tokio::join!(telemetry_fut, updates_fut, doctor_fut);

    for res in [&tele_res, &upd_res] {
        if let Err(err) = res
            && let Some(status) = err.auth_status()
        {
            snap.auth_error = Some(status);
            snap.error = Some(format!("HTTP {status}"));
            return snap;
        }
    }
    if let Some(Err(err)) = &doc_opt
        && let Some(status) = err.auth_status()
    {
        snap.auth_error = Some(status);
        snap.error = Some(format!("HTTP {status}"));
        return snap;
    }

    match &tele_res {
        Ok(val) => {
            snap.reachable = true;
            apply_telemetry_json(&mut snap, val);
        }
        Err(FleetError::HttpStatus { status: 404, .. }) => {
            match router_request_json(
                router,
                "GET",
                "/api/agent/v1/health",
                None,
                FLEET_REQUEST_TIMEOUT,
            )
            .await
            {
                Ok(h) => {
                    snap.reachable = true;
                    snap.core_running = h
                        .get("core_running")
                        .or_else(|| h.get("ok"))
                        .and_then(Value::as_bool);
                    snap.uptime_secs = h.get("uptime_secs").and_then(Value::as_u64);
                }
                Err(e) => {
                    snap.auth_error = e.auth_status();
                    snap.error = Some(sanitize_fleet_error(
                        &e.display_sanitized(false),
                        &router.api_token,
                    ));
                }
            }
        }
        Err(e) => {
            snap.error = Some(sanitize_fleet_error(
                &e.display_sanitized(false),
                &router.api_token,
            ));
        }
    }

    if let Ok(upd_val) = &upd_res {
        snap.reachable = true;
        apply_updates_json(&mut snap, upd_val);
    } else if snap.error.is_none()
        && !snap.reachable
        && let Err(e) = &upd_res
    {
        snap.error = Some(sanitize_fleet_error(
            &e.display_sanitized(false),
            &router.api_token,
        ));
    }

    if let Some(Ok(doc_val)) = &doc_opt {
        snap.reachable = true;
        apply_doctor_json(&mut snap, doc_val);
    }

    snap
}

pub(crate) async fn probe_fleet_overview(routers: &[ManagedRouter]) -> Vec<RouterOverviewSnapshot> {
    let mut results = Vec::with_capacity(routers.len());
    for chunk in routers.chunks(FLEET_PROBE_CONCURRENCY) {
        let mut handles = Vec::with_capacity(chunk.len());
        let mut guard = AbortHandlesOnDrop(Vec::with_capacity(chunk.len()));
        for r in chunk {
            let rc = r.clone();
            let h = tokio::spawn(async move { Box::pin(probe_router_overview(&rc, false)).await });
            guard.0.push(h.abort_handle());
            handles.push(h);
        }
        for (idx, h) in handles.into_iter().enumerate() {
            match h.await {
                Ok(snap) => results.push(snap),
                Err(_) => {
                    let r = &chunk[idx];
                    results.push(RouterOverviewSnapshot {
                        router_id: r.id.clone(),
                        router_name: r.name.clone(),
                        url: sanitize_display_url(&r.url),
                        enabled: r.enabled,
                        reachable: false,
                        error: Some("Probe cancelled".to_string()),
                        ..Default::default()
                    });
                }
            }
        }
        guard.0.clear();
    }
    results
}

#[derive(Debug, Clone, Default)]
pub(crate) struct RemoteUpdatesInfo {
    pub tachyon_current: String,
    pub tachyon_latest: String,
    pub core_current: String,
    pub core_latest: String,
    pub lists_count: u64,
    pub subscriptions_count: u64,
}

fn first_release_version(val: &Value) -> Option<String> {
    val.as_array()
        .and_then(|arr| arr.first())
        .and_then(|item| {
            item.get("version")
                .or_else(|| item.get("tag"))
                .and_then(Value::as_str)
        })
        .map(|s| s.trim().trim_start_matches(['v', 'V']).to_string())
        .filter(|s| !s.is_empty())
}

pub(crate) async fn check_router_updates(
    router: &ManagedRouter,
) -> Result<RemoteUpdatesInfo, FleetError> {
    let val = router_request_json(
        router,
        "GET",
        "/api/updates/check",
        None,
        FLEET_REQUEST_TIMEOUT,
    )
    .await?;

    let mut info = RemoteUpdatesInfo {
        tachyon_current: val
            .get("orchestrator_version")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string(),
        tachyon_latest: val
            .get("orchestrator_latest")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string(),
        core_current: val
            .get("core_installed")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string(),
        core_latest: val
            .get("core_latest")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string(),
        lists_count: val
            .get("lists_installed_count")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        subscriptions_count: val
            .get("subscriptions_count")
            .and_then(Value::as_u64)
            .unwrap_or(0),
    };

    let need_tachyon_release =
        info.tachyon_latest.is_empty() || info.tachyon_latest == info.tachyon_current;
    let need_core_release = info.core_latest.is_empty() || info.core_latest == info.core_current;

    if need_tachyon_release || need_core_release {
        let (rel_tachyon, rel_core) = tokio::join!(
            async {
                if need_tachyon_release {
                    Some(
                        call_remote_ubus_tachyon_cli(
                            router,
                            &["component_list_releases", "tachyon", "1", "1"],
                            FLEET_REQUEST_TIMEOUT,
                        )
                        .await,
                    )
                } else {
                    None
                }
            },
            async {
                if need_core_release {
                    Some(
                        call_remote_ubus_tachyon_cli(
                            router,
                            &["component_list_releases", "tachyon-core", "1", "1"],
                            FLEET_REQUEST_TIMEOUT,
                        )
                        .await,
                    )
                } else {
                    None
                }
            }
        );

        if let Some(Err(err)) = &rel_tachyon
            && let Some(status) = err.auth_status()
        {
            return Err(FleetError::AuthRejected { status });
        }
        if let Some(Err(err)) = &rel_core
            && let Some(status) = err.auth_status()
        {
            return Err(FleetError::AuthRejected { status });
        }

        if let Some(Ok(v)) = rel_tachyon
            && let Some(ver) = first_release_version(&v)
        {
            info.tachyon_latest = ver;
        }
        if let Some(Ok(v)) = rel_core
            && let Some(ver) = first_release_version(&v)
        {
            info.core_latest = ver;
        }
    }

    Ok(info)
}

#[derive(Debug, Clone, Default)]
pub(crate) struct PostActionVerification {
    pub reachable: bool,
    pub auth_error: Option<u16>,
    pub core_running: Option<bool>,
    pub tachyon_version: String,
    pub core_version: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct ActionExecutionOutcome {
    pub action_ok: bool,
    pub action_message: String,
    pub auth_error: Option<u16>,
    pub prev_tachyon_version: String,
    pub verification: PostActionVerification,
}

async fn probe_single_health_sample(router: &ManagedRouter) -> FleetProbeSample {
    let res = router_request_json(
        router,
        "GET",
        "/api/agent/v1/health",
        None,
        FLEET_REQUEST_TIMEOUT,
    )
    .await;

    match res {
        Ok(val) => {
            let core_running = val
                .get("core_running")
                .or_else(|| val.get("ok"))
                .and_then(Value::as_bool);
            FleetProbeSample {
                router_id: router.id.clone(),
                router_name: router.name.clone(),
                url: sanitize_display_url(&router.url),
                reachable: true,
                core_running,
                tachyon_version: String::new(),
                core_version: String::new(),
                auth_error: None,
                error: None,
            }
        }
        Err(FleetError::HttpStatus { status: 404, .. }) => {
            match router_request_json(router, "GET", "/api/telemetry", None, FLEET_REQUEST_TIMEOUT)
                .await
            {
                Ok(val) => {
                    let core_running = val.pointer("/live/core_running").and_then(Value::as_bool);
                    let core_version = val
                        .pointer("/live/core_version")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    FleetProbeSample {
                        router_id: router.id.clone(),
                        router_name: router.name.clone(),
                        url: sanitize_display_url(&router.url),
                        reachable: true,
                        core_running,
                        tachyon_version: String::new(),
                        core_version,
                        auth_error: None,
                        error: None,
                    }
                }
                Err(e) => FleetProbeSample {
                    router_id: router.id.clone(),
                    router_name: router.name.clone(),
                    url: sanitize_display_url(&router.url),
                    reachable: false,
                    core_running: None,
                    tachyon_version: String::new(),
                    core_version: String::new(),
                    auth_error: e.auth_status(),
                    error: Some(sanitize_fleet_error(
                        &e.display_sanitized(false),
                        &router.api_token,
                    )),
                },
            }
        }
        Err(e) => FleetProbeSample {
            router_id: router.id.clone(),
            router_name: router.name.clone(),
            url: sanitize_display_url(&router.url),
            reachable: false,
            core_running: None,
            tachyon_version: String::new(),
            core_version: String::new(),
            auth_error: e.auth_status(),
            error: Some(sanitize_fleet_error(
                &e.display_sanitized(false),
                &router.api_token,
            )),
        },
    }
}

pub(crate) async fn verify_router_post_action(router: &ManagedRouter) -> PostActionVerification {
    let mut last_ver = PostActionVerification::default();
    for attempt in 0..POST_VERIFY_ATTEMPTS {
        if attempt > 0 {
            tokio::time::sleep(POST_VERIFY_RETRY_DELAY).await;
        }
        let sample = probe_single_health_sample(router).await;
        if let Some(status) = sample.auth_error {
            return PostActionVerification {
                reachable: false,
                auth_error: Some(status),
                error: sample.error,
                ..Default::default()
            };
        }
        if sample.reachable {
            last_ver.reachable = true;
            last_ver.core_running = sample.core_running;
            last_ver.core_version = sample.core_version;
            if let Ok(upd) = router_request_json(
                router,
                "GET",
                "/api/updates/check",
                None,
                FLEET_REQUEST_TIMEOUT,
            )
            .await
            {
                if let Some(tv) = upd
                    .get("orchestrator_version")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                {
                    last_ver.tachyon_version = tv.to_string();
                }
                if last_ver.core_version.is_empty()
                    && let Some(cv) = upd
                        .get("core_installed")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                {
                    last_ver.core_version = cv.to_string();
                }
            }
            return last_ver;
        }
        last_ver.error = sample.error;
    }
    last_ver
}

async fn read_remote_tachyon_version(router: &ManagedRouter) -> Result<String, FleetError> {
    let val = router_request_json(
        router,
        "GET",
        "/api/updates/check",
        None,
        FLEET_REQUEST_TIMEOUT,
    )
    .await?;
    Ok(val
        .get("orchestrator_version")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string())
}

pub(crate) async fn execute_router_update_tachyon(
    router: &ManagedRouter,
) -> ActionExecutionOutcome {
    let prev_tachyon_version = match read_remote_tachyon_version(router).await {
        Ok(v) => v,
        Err(FleetError::AuthRejected { status }) => {
            return ActionExecutionOutcome {
                action_ok: false,
                action_message: FleetError::AuthRejected { status }.display_sanitized(false),
                auth_error: Some(status),
                prev_tachyon_version: String::new(),
                verification: PostActionVerification {
                    auth_error: Some(status),
                    ..Default::default()
                },
            };
        }
        Err(_) => String::new(),
    };

    let req_body = json!({
        "component": "tachyon",
        "action": "update",
    });
    let act_res = router_request_json(
        router,
        "POST",
        "/api/components/action",
        Some(&req_body),
        FLEET_ACTION_TIMEOUT,
    )
    .await;

    let (mut action_ok, mut action_message, needs_ubus_fallback) = match act_res {
        Ok(v) => {
            let ok = v.get("ok").and_then(Value::as_bool).unwrap_or(true);
            let msg = v
                .pointer("/result/message")
                .or_else(|| v.get("message"))
                .or_else(|| v.pointer("/result/error"))
                .or_else(|| v.get("error"))
                .and_then(Value::as_str)
                .unwrap_or(if ok {
                    "Update started"
                } else {
                    "Update failed"
                })
                .to_string();
            let ubus_needed = !ok && msg.contains("требует запуска через updater");
            (
                ok,
                sanitize_fleet_error(&msg, &router.api_token),
                ubus_needed,
            )
        }
        Err(FleetError::AuthRejected { status }) => {
            return ActionExecutionOutcome {
                action_ok: false,
                action_message: FleetError::AuthRejected { status }.display_sanitized(false),
                auth_error: Some(status),
                prev_tachyon_version,
                verification: PostActionVerification {
                    auth_error: Some(status),
                    ..Default::default()
                },
            };
        }
        Err(FleetError::HttpStatus { status: 404, .. }) => (false, String::new(), true),
        Err(e) => (
            false,
            sanitize_fleet_error(&e.display_sanitized(false), &router.api_token),
            false,
        ),
    };

    if needs_ubus_fallback {
        match call_remote_ubus_tachyon_cli(
            router,
            &["component_action_async", "tachyon", "install"],
            FLEET_ACTION_TIMEOUT,
        )
        .await
        {
            Ok(start_val) => {
                let job_id = start_val
                    .get("job_id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                let mut final_val = start_val;
                if !job_id.is_empty()
                    && final_val.get("running").and_then(Value::as_bool) == Some(true)
                {
                    for _ in 0..8 {
                        tokio::time::sleep(Duration::from_millis(500)).await;
                        if let Ok(st) = call_remote_ubus_tachyon_cli(
                            router,
                            &["component_action_status", &job_id],
                            FLEET_REQUEST_TIMEOUT,
                        )
                        .await
                        {
                            let still_running =
                                st.get("running").and_then(Value::as_bool).unwrap_or(false);
                            final_val = st;
                            if !still_running {
                                break;
                            }
                        } else {
                            // Daemon may be restarting after binary swap.
                            break;
                        }
                    }
                }
                let ok = final_val
                    .get("success")
                    .or_else(|| final_val.get("ok"))
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let msg = final_val
                    .get("message")
                    .or_else(|| final_val.get("error"))
                    .and_then(Value::as_str)
                    .unwrap_or("Update triggered");
                action_ok = ok;
                action_message = sanitize_fleet_error(msg, &router.api_token);
            }
            Err(FleetError::AuthRejected { status }) => {
                return ActionExecutionOutcome {
                    action_ok: false,
                    action_message: FleetError::AuthRejected { status }.display_sanitized(false),
                    auth_error: Some(status),
                    prev_tachyon_version,
                    verification: PostActionVerification {
                        auth_error: Some(status),
                        ..Default::default()
                    },
                };
            }
            Err(e) => {
                action_ok = false;
                action_message =
                    sanitize_fleet_error(&e.display_sanitized(false), &router.api_token);
            }
        }
    }

    let verification = verify_router_post_action(router).await;
    ActionExecutionOutcome {
        action_ok,
        action_message,
        auth_error: verification.auth_error,
        prev_tachyon_version,
        verification,
    }
}

pub(crate) async fn execute_router_restart_tachyon(
    router: &ManagedRouter,
) -> ActionExecutionOutcome {
    let prev_tachyon_version = match read_remote_tachyon_version(router).await {
        Ok(v) => v,
        Err(FleetError::AuthRejected { status }) => {
            return ActionExecutionOutcome {
                action_ok: false,
                action_message: FleetError::AuthRejected { status }.display_sanitized(false),
                auth_error: Some(status),
                prev_tachyon_version: String::new(),
                verification: PostActionVerification {
                    auth_error: Some(status),
                    ..Default::default()
                },
            };
        }
        Err(_) => String::new(),
    };

    let body = json!({});
    let primary = router_request_json(
        router,
        "POST",
        "/api/core/restart",
        Some(&body),
        FLEET_ACTION_TIMEOUT,
    )
    .await;

    let res = match primary {
        Err(FleetError::HttpStatus { status: 404, .. }) => {
            router_request_json(
                router,
                "POST",
                "/api/agent/v1/restart",
                Some(&body),
                FLEET_ACTION_TIMEOUT,
            )
            .await
        }
        other => other,
    };

    let (action_ok, action_message) = match res {
        Ok(val) => {
            let ok = val.get("ok").and_then(Value::as_bool).unwrap_or(true);
            let msg = val
                .get("message")
                .or_else(|| val.get("error"))
                .and_then(Value::as_str)
                .unwrap_or(if ok {
                    "Service restarted"
                } else {
                    "Restart failed"
                });
            (ok, sanitize_fleet_error(msg, &router.api_token))
        }
        Err(FleetError::AuthRejected { status }) => {
            return ActionExecutionOutcome {
                action_ok: false,
                action_message: FleetError::AuthRejected { status }.display_sanitized(false),
                auth_error: Some(status),
                prev_tachyon_version,
                verification: PostActionVerification {
                    auth_error: Some(status),
                    ..Default::default()
                },
            };
        }
        Err(e) => (
            false,
            sanitize_fleet_error(&e.display_sanitized(false), &router.api_token),
        ),
    };

    let verification = verify_router_post_action(router).await;
    ActionExecutionOutcome {
        action_ok,
        action_message,
        auth_error: verification.auth_error,
        prev_tachyon_version,
        verification,
    }
}

// =========================================================================
// Background Fleet Health Monitor (in-memory + zero-flash-wear tmpfs cache)
// =========================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FleetLinkState {
    Unknown,
    Online,
    Offline,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct RouterHealthTrack {
    pub id: String,
    pub name: String,
    pub url: String,
    pub state: FleetLinkState,
    pub consecutive_failures: u32,
    pub consecutive_successes: u32,
    pub outage_notified: bool,
    pub last_outage_alert_unix: i64,
    pub last_recovery_alert_unix: i64,
    pub last_checked_unix: i64,
    pub core_running: Option<bool>,
    pub tachyon_version: String,
    pub core_version: String,
    pub last_error: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum FleetAlertKind {
    Outage,
    Recovery,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FleetAlert {
    pub router_id: String,
    pub router_name: String,
    pub url: String,
    pub kind: FleetAlertKind,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub(crate) struct FleetProbeSample {
    pub router_id: String,
    pub router_name: String,
    pub url: String,
    pub reachable: bool,
    pub core_running: Option<bool>,
    pub tachyon_version: String,
    pub core_version: String,
    pub auth_error: Option<u16>,
    pub error: Option<String>,
}

pub(crate) struct FleetMonitor {
    tracks: HashMap<String, RouterHealthTrack>,
    last_poll_unix: i64,
    poll_interval_secs: i64,
    failure_threshold: u32,
    recovery_threshold: u32,
    cooldown_secs: i64,
    cache_path: PathBuf,
}

impl Default for FleetMonitor {
    fn default() -> Self {
        Self::new_with_config(
            FLEET_MONITOR_INTERVAL_SECS,
            FLEET_FAILURE_THRESHOLD,
            FLEET_RECOVERY_THRESHOLD,
            FLEET_ALERT_COOLDOWN_SECS,
            runtime_state_dir().join(FLEET_HEALTH_CACHE_FILE),
        )
    }
}

impl FleetMonitor {
    pub(crate) fn new_with_config(
        poll_interval_secs: i64,
        failure_threshold: u32,
        recovery_threshold: u32,
        cooldown_secs: i64,
        cache_path: PathBuf,
    ) -> Self {
        Self {
            tracks: HashMap::new(),
            last_poll_unix: 0,
            poll_interval_secs: poll_interval_secs.max(1),
            failure_threshold: failure_threshold.max(1),
            recovery_threshold: recovery_threshold.max(1),
            cooldown_secs: cooldown_secs.max(0),
            cache_path,
        }
    }

    pub(crate) fn is_due(&self, now_secs: i64) -> bool {
        self.last_poll_unix == 0
            || now_secs.saturating_sub(self.last_poll_unix) >= self.poll_interval_secs
    }

    pub(crate) fn clear_if_nonempty(&mut self) {
        if !self.tracks.is_empty() {
            self.tracks.clear();
            self.persist_cache_if_changed();
        }
        self.last_poll_unix = 0;
    }

    #[allow(dead_code)]
    pub(crate) fn track_for(&self, router_id: &str) -> Option<&RouterHealthTrack> {
        self.tracks.get(router_id)
    }

    fn persist_cache_if_changed(&self) {
        let mut items: Vec<&RouterHealthTrack> = self.tracks.values().collect();
        items.sort_by(|a, b| a.id.cmp(&b.id));
        let payload = json!({
            "routers": items,
        });
        let _ = crypto_gen::write_json_if_changed(&self.cache_path, &payload);
    }

    pub(crate) fn apply_probe_samples(
        &mut self,
        samples: &[FleetProbeSample],
        now_secs: i64,
    ) -> Vec<FleetAlert> {
        let active_ids: HashSet<&str> = samples.iter().map(|s| s.router_id.as_str()).collect();
        self.tracks.retain(|id, _| active_ids.contains(id.as_str()));

        let mut alerts = Vec::new();
        for s in samples {
            let entry =
                self.tracks
                    .entry(s.router_id.clone())
                    .or_insert_with(|| RouterHealthTrack {
                        id: s.router_id.clone(),
                        name: s.router_name.clone(),
                        url: s.url.clone(),
                        state: FleetLinkState::Unknown,
                        consecutive_failures: 0,
                        consecutive_successes: 0,
                        outage_notified: false,
                        last_outage_alert_unix: 0,
                        last_recovery_alert_unix: 0,
                        last_checked_unix: 0,
                        core_running: None,
                        tachyon_version: String::new(),
                        core_version: String::new(),
                        last_error: String::new(),
                    });

            entry.name = s.router_name.clone();
            entry.url = s.url.clone();
            entry.last_checked_unix = now_secs;

            if s.reachable {
                entry.consecutive_failures = 0;
                entry.consecutive_successes = entry.consecutive_successes.saturating_add(1);
                entry.core_running = s.core_running;
                if !s.tachyon_version.is_empty() {
                    entry.tachyon_version = s.tachyon_version.clone();
                }
                if !s.core_version.is_empty() {
                    entry.core_version = s.core_version.clone();
                }
                entry.last_error.clear();

                match entry.state {
                    FleetLinkState::Unknown | FleetLinkState::Online => {
                        entry.state = FleetLinkState::Online;
                    }
                    FleetLinkState::Offline => {
                        if entry.consecutive_successes >= self.recovery_threshold {
                            entry.state = FleetLinkState::Online;
                            let cooldown_ok = entry.last_recovery_alert_unix == 0
                                || now_secs.saturating_sub(entry.last_recovery_alert_unix)
                                    >= self.cooldown_secs;
                            if entry.outage_notified && cooldown_ok {
                                entry.outage_notified = false;
                                entry.last_recovery_alert_unix = now_secs;
                                alerts.push(FleetAlert {
                                    router_id: entry.id.clone(),
                                    router_name: entry.name.clone(),
                                    url: entry.url.clone(),
                                    kind: FleetAlertKind::Recovery,
                                    detail: match entry.core_running {
                                        Some(true) => "core running".to_string(),
                                        Some(false) => "core stopped".to_string(),
                                        None => "reachable".to_string(),
                                    },
                                });
                            }
                        }
                    }
                }
            } else {
                entry.consecutive_successes = 0;
                entry.consecutive_failures = entry.consecutive_failures.saturating_add(1);
                entry.core_running = None;
                let detail = if let Some(code) = s.auth_error {
                    format!("HTTP {code}")
                } else {
                    s.error
                        .clone()
                        .filter(|e| !e.is_empty())
                        .unwrap_or_else(|| "unreachable".to_string())
                };
                entry.last_error = detail.clone();

                if entry.state != FleetLinkState::Offline
                    && entry.consecutive_failures >= self.failure_threshold
                {
                    entry.state = FleetLinkState::Offline;
                    let cooldown_ok = entry.last_outage_alert_unix == 0
                        || now_secs.saturating_sub(entry.last_outage_alert_unix)
                            >= self.cooldown_secs;
                    if cooldown_ok {
                        entry.outage_notified = true;
                        entry.last_outage_alert_unix = now_secs;
                        alerts.push(FleetAlert {
                            router_id: entry.id.clone(),
                            router_name: entry.name.clone(),
                            url: entry.url.clone(),
                            kind: FleetAlertKind::Outage,
                            detail,
                        });
                    }
                }
            }
        }

        self.persist_cache_if_changed();
        alerts
    }

    pub(crate) async fn poll_tick_if_due(
        &mut self,
        routers: &[ManagedRouter],
        now_secs: i64,
    ) -> Vec<FleetAlert> {
        let enabled: Vec<ManagedRouter> = routers.iter().filter(|r| r.enabled).cloned().collect();
        if enabled.is_empty() {
            self.clear_if_nonempty();
            return Vec::new();
        }
        if !self.is_due(now_secs) {
            return Vec::new();
        }
        self.last_poll_unix = now_secs;

        let mut samples = Vec::with_capacity(enabled.len());
        for chunk in enabled.chunks(FLEET_PROBE_CONCURRENCY) {
            let mut handles = Vec::with_capacity(chunk.len());
            let mut guard = AbortHandlesOnDrop(Vec::with_capacity(chunk.len()));
            for r in chunk {
                let rc = r.clone();
                let h =
                    tokio::spawn(async move { Box::pin(probe_single_health_sample(&rc)).await });
                guard.0.push(h.abort_handle());
                handles.push(h);
            }
            for (idx, h) in handles.into_iter().enumerate() {
                match h.await {
                    Ok(sample) => samples.push(sample),
                    Err(_) => {
                        let r = &chunk[idx];
                        samples.push(FleetProbeSample {
                            router_id: r.id.clone(),
                            router_name: r.name.clone(),
                            url: sanitize_display_url(&r.url),
                            reachable: false,
                            core_running: None,
                            tachyon_version: String::new(),
                            core_version: String::new(),
                            auth_error: None,
                            error: Some("Probe cancelled".to_string()),
                        });
                    }
                }
            }
            guard.0.clear();
        }

        self.apply_probe_samples(&samples, now_secs)
    }
}

pub(crate) fn format_fleet_alert_html(alert: &FleetAlert, ru: bool) -> String {
    match alert.kind {
        FleetAlertKind::Outage => {
            if ru {
                format!(
                    "[!] <b>Роутер недоступен: {}</b>\nURL: <code>{}</code>\nПричина: <code>{}</code>",
                    escape_html(&alert.router_name),
                    escape_html(&alert.url),
                    escape_html(&alert.detail)
                )
            } else {
                format!(
                    "[!] <b>Router unreachable: {}</b>\nURL: <code>{}</code>\nDetail: <code>{}</code>",
                    escape_html(&alert.router_name),
                    escape_html(&alert.url),
                    escape_html(&alert.detail)
                )
            }
        }
        FleetAlertKind::Recovery => {
            if ru {
                format!(
                    "[OK] <b>Связь с роутером восстановлена: {}</b>\nURL: <code>{}</code>\nСостояние: <code>{}</code>",
                    escape_html(&alert.router_name),
                    escape_html(&alert.url),
                    escape_html(&alert.detail)
                )
            } else {
                format!(
                    "[OK] <b>Router recovered: {}</b>\nURL: <code>{}</code>\nState: <code>{}</code>",
                    escape_html(&alert.router_name),
                    escape_html(&alert.url),
                    escape_html(&alert.detail)
                )
            }
        }
    }
}

// =========================================================================
// Interactive Telegram Bot UI
// =========================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FleetConfirmAction {
    UpdateTachyon,
    RestartTachyon,
    RemoveRouter,
}

fn fmt_short_uptime(secs: u64) -> String {
    let d = secs / 86400;
    let h = (secs % 86400) / 3600;
    let m = (secs % 3600) / 60;
    if d > 0 {
        format!("{d}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

fn reachability_label(snap: &RouterOverviewSnapshot) -> &'static str {
    if !snap.enabled {
        "[DISABLED]"
    } else if snap.reachable {
        "[ONLINE]"
    } else if snap.auth_error.is_some() {
        "[AUTH ERR]"
    } else {
        "[OFFLINE]"
    }
}

fn reachability_word(snap: &RouterOverviewSnapshot) -> &'static str {
    if !snap.enabled {
        "disabled"
    } else if snap.reachable {
        "online"
    } else {
        "offline"
    }
}

pub(crate) async fn handle_routers_command(
    arg: &str,
    chat_id: i64,
    state: &Arc<AppState>,
) -> BotReply {
    clear_chat_prompt(chat_id);
    let trimmed = arg.trim();
    if trimmed.eq_ignore_ascii_case("add") {
        return start_add_router_prompt(chat_id, state).await;
    }
    if !trimmed.is_empty() {
        let matched_id = {
            let d = state.data.read().await;
            d.telegram
                .managed_routers
                .iter()
                .find(|r| r.id == trimmed || r.name.eq_ignore_ascii_case(trimmed))
                .map(|r| r.id.clone())
        };
        if let Some(id) = matched_id {
            return Box::pin(render_router_detail(state, &id, None)).await;
        }
    }
    Box::pin(render_fleet_overview(state, 0, None)).await
}

pub(crate) async fn render_fleet_overview(
    state: &Arc<AppState>,
    page: usize,
    notice: Option<String>,
) -> BotReply {
    let (routers, ru) = {
        let d = state.data.read().await;
        (d.telegram.managed_routers.clone(), is_ru(&d))
    };

    let snapshots = Box::pin(probe_fleet_overview(&routers)).await;
    let online_cnt = snapshots.iter().filter(|s| s.reachable).count();

    let total = snapshots.len();
    let per = FLEET_PER_PAGE;
    let total_pages = total.div_ceil(per).max(1);
    let safe_page = page.min(total_pages - 1);
    let start = safe_page * per;
    let end = (start + per).min(total);

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }
    lines.push(format!(
        "<b>{}</b> ({}/{} online)",
        tr(ru, "Управление роутерами", "Managed Routers"),
        online_cnt,
        total
    ));

    let mut rows: Vec<Vec<Value>> = Vec::new();
    if snapshots.is_empty() {
        lines.push(
            tr(
                ru,
                "Удалённые роутеры ещё не добавлены. Нажмите «Добавить роутер» и укажите имя, URL и API token.",
                "No managed routers configured yet. Tap Add Router and enter name, URL, and API token.",
            )
            .to_string(),
        );
    } else {
        for snap in &snapshots[start..end] {
            let badge = reachability_label(snap);
            let word = reachability_word(snap);
            let t_ver = if snap.tachyon_version.is_empty() {
                "-"
            } else {
                snap.tachyon_version.as_str()
            };
            let c_ver = if snap.core_version.is_empty() {
                "-"
            } else {
                snap.core_version.as_str()
            };
            let svc_state = match snap.core_running {
                Some(true) => "core: running",
                Some(false) => "core: stopped",
                None if !snap.enabled => "disabled",
                None => snap.error.as_deref().unwrap_or("unreachable"),
            };
            lines.push(format!(
                "{badge} <b>{}</b> (<code>{word}</code>)\n  <code>{}</code> | tachyon: <code>{}</code> | core: <code>{}</code> | <code>{}</code>",
                escape_html(&snap.router_name),
                escape_html(&snap.url),
                escape_html(t_ver),
                escape_html(c_ver),
                escape_html(svc_state),
            ));
            rows.push(vec![cb_btn(
                &format!("{badge} {}", snap.router_name),
                &format!("flt_view {}", snap.router_id),
            )]);
        }
    }

    if total_pages > 1 {
        let mut nav = Vec::new();
        if safe_page > 0 {
            nav.push(cb_btn("<<", &format!("flt_list {}", safe_page - 1)));
        }
        nav.push(cb_btn(
            &format!("{}/{}", safe_page + 1, total_pages),
            &format!("flt_list {safe_page}"),
        ));
        if safe_page + 1 < total_pages {
            nav.push(cb_btn(">>", &format!("flt_list {}", safe_page + 1)));
        }
        rows.push(nav);
    }

    rows.push(vec![
        cb_btn(tr(ru, "Добавить роутер", "Add Router"), "flt_add"),
        cb_btn(
            tr(ru, "Обновить", "Refresh"),
            &format!("flt_list {safe_page}"),
        ),
    ]);
    rows.push(vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")]);

    BotReply::with_kb(lines.join("\n"), inline_kb(rows))
}

pub(crate) async fn render_router_detail(
    state: &Arc<AppState>,
    router_id: &str,
    notice: Option<String>,
) -> BotReply {
    let (router_opt, ru) = {
        let d = state.data.read().await;
        (
            d.telegram
                .managed_routers
                .iter()
                .find(|r| r.id == router_id)
                .cloned(),
            is_ru(&d),
        )
    };

    let Some(router) = router_opt else {
        return Box::pin(render_fleet_overview(
            state,
            0,
            Some(tr(ru, "[ERR] Роутер не найден.", "[ERR] Router not found.").to_string()),
        ))
        .await;
    };

    let snap = Box::pin(probe_router_overview(&router, true)).await;
    let badge = reachability_label(&snap);
    let word = reachability_word(&snap);

    let mut lines = Vec::new();
    if let Some(n) = notice {
        lines.push(n);
        lines.push(String::new());
    }

    lines.push(format!(
        "<b>{}</b> {badge} (<code>{word}</code>)",
        escape_html(&snap.router_name)
    ));
    lines.push(format!(
        "ID: <code>{}</code> | URL: <code>{}</code>",
        escape_html(&snap.router_id),
        escape_html(&snap.url)
    ));

    let t_ver = if snap.tachyon_version.is_empty() {
        "-"
    } else {
        snap.tachyon_version.as_str()
    };
    let c_ver = if snap.core_version.is_empty() {
        "-"
    } else {
        snap.core_version.as_str()
    };
    lines.push(format!(
        "Tachyon: <code>{}</code> | Core: <code>{}</code>",
        escape_html(t_ver),
        escape_html(c_ver)
    ));

    if snap.reachable {
        let core_st = match snap.core_running {
            Some(true) => "running [ON]",
            Some(false) => "stopped [OFF]",
            None => "unknown",
        };
        let wan_st = match snap.wan_healthy {
            Some(true) => "[OK]",
            Some(false) => "[!]",
            None => "-",
        };
        let dns_st = match snap.dns_healthy {
            Some(true) => "[OK]",
            Some(false) => "[!]",
            None => "-",
        };
        let up_str = snap
            .uptime_secs
            .map(fmt_short_uptime)
            .unwrap_or_else(|| "-".to_string());
        let mem_str = match (snap.mem_used_mb, snap.mem_total_mb) {
            (Some(u), Some(t)) if t > 0 => format!("{u}/{t} MB"),
            _ => "-".to_string(),
        };
        let conns_str = snap
            .active_connections
            .map(|c| c.to_string())
            .unwrap_or_else(|| "-".to_string());

        lines.push(format!(
            "{}: <code>{}</code> | WAN: {wan_st} | DNS: {dns_st}",
            tr(ru, "Служба", "Service"),
            core_st
        ));
        lines.push(format!(
            "{}: <code>{}</code> | RAM: <code>{}</code> | {}: <code>{}</code>",
            tr(ru, "Аптайм", "Uptime"),
            escape_html(&up_str),
            escape_html(&mem_str),
            tr(ru, "Сессии", "Sessions"),
            escape_html(&conns_str)
        ));

        if let (Some(passed), Some(total)) = (snap.doctor_passed, snap.doctor_total) {
            let doc_badge = if snap.doctor_healthy == Some(true) {
                "[OK]"
            } else {
                "[!]"
            };
            let summary = if snap.doctor_summary.is_empty() {
                "-"
            } else {
                snap.doctor_summary.as_str()
            };
            lines.push(format!(
                "{}: {doc_badge} ({passed}/{total}) — {}",
                tr(ru, "Диагностика", "Diagnostics"),
                escape_html(summary)
            ));
            for f in &snap.doctor_findings {
                lines.push(format!("  [!] {}", escape_html(f)));
            }
        }
    } else if !snap.enabled {
        lines.push(
            tr(
                ru,
                "Мониторинг этого роутера отключён.",
                "Monitoring is disabled for this router.",
            )
            .to_string(),
        );
    } else if let Some(status) = snap.auth_error {
        lines.push(format!(
            "[ERR] {}",
            escape_html(&FleetError::AuthRejected { status }.display_sanitized(ru))
        ));
    } else {
        let err_msg = snap.error.as_deref().unwrap_or("unreachable");
        lines.push(format!("[ERR] {}", escape_html(err_msg)));
    }

    let kb = inline_kb(vec![
        vec![
            cb_btn(
                tr(ru, "Проверить обновления", "Check Updates"),
                &format!("flt_upd_chk {}", router.id),
            ),
            cb_btn(
                tr(ru, "Обновить", "Refresh"),
                &format!("flt_view {}", router.id),
            ),
        ],
        vec![
            cb_btn(
                tr(ru, "Обновить Tachyon", "Update Tachyon"),
                &format!("flt_upd_ask {}", router.id),
            ),
            cb_btn(
                tr(ru, "Перезапуск Tachyon", "Restart Tachyon"),
                &format!("flt_rst_ask {}", router.id),
            ),
        ],
        vec![
            cb_btn(
                if router.enabled {
                    tr(ru, "Откл. мониторинг", "Disable Monitor")
                } else {
                    tr(ru, "Вкл. мониторинг", "Enable Monitor")
                },
                &format!("flt_tog {}", router.id),
            ),
            cb_btn(
                tr(ru, "Удалить роутер", "Remove Router"),
                &format!("flt_del_ask {}", router.id),
            ),
        ],
        vec![
            cb_btn(tr(ru, "Все роутеры", "All Routers"), "flt_list 0"),
            cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu"),
        ],
    ]);

    BotReply::with_kb(lines.join("\n"), kb)
}

pub(crate) async fn toggle_router_enabled(state: &Arc<AppState>, router_id: &str) -> BotReply {
    let mut candidate = state.data.read().await.clone();
    let ru = is_ru(&candidate);
    let Some(r) = candidate
        .telegram
        .managed_routers
        .iter_mut()
        .find(|r| r.id == router_id)
    else {
        return Box::pin(render_fleet_overview(
            state,
            0,
            Some(tr(ru, "[ERR] Роутер не найден.", "[ERR] Router not found.").to_string()),
        ))
        .await;
    };
    r.enabled = !r.enabled;
    let enabled_now = r.enabled;
    let note = match Box::pin(commit_transaction(state, candidate)).await {
        Ok(_) => {
            notify_bot_wakeup();
            if enabled_now {
                tr(
                    ru,
                    "[OK] Мониторинг роутера включён.",
                    "[OK] Router monitoring enabled.",
                )
                .to_string()
            } else {
                tr(
                    ru,
                    "[OK] Мониторинг роутера выключен.",
                    "[OK] Router monitoring disabled.",
                )
                .to_string()
            }
        }
        Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
    };
    Box::pin(render_router_detail(state, router_id, Some(note))).await
}

pub(crate) async fn render_router_updates(state: &Arc<AppState>, router_id: &str) -> BotReply {
    let (router_opt, ru) = {
        let d = state.data.read().await;
        (
            d.telegram
                .managed_routers
                .iter()
                .find(|r| r.id == router_id)
                .cloned(),
            is_ru(&d),
        )
    };
    let Some(router) = router_opt else {
        return Box::pin(render_fleet_overview(
            state,
            0,
            Some(tr(ru, "[ERR] Роутер не найден.", "[ERR] Router not found.").to_string()),
        ))
        .await;
    };

    match Box::pin(check_router_updates(&router)).await {
        Ok(info) => {
            let t_cur = if info.tachyon_current.is_empty() {
                "-"
            } else {
                info.tachyon_current.as_str()
            };
            let t_lat = if info.tachyon_latest.is_empty() {
                t_cur
            } else {
                info.tachyon_latest.as_str()
            };
            let t_status = updater::classify_version_status(t_cur, t_lat);

            let c_cur = if info.core_current.is_empty() {
                "-"
            } else {
                info.core_current.as_str()
            };
            let c_lat = if info.core_latest.is_empty() {
                c_cur
            } else {
                info.core_latest.as_str()
            };
            let c_status = updater::classify_version_status(c_cur, c_lat);

            let text = format!(
                "<b>{}: {}</b>\n\
                 tachyon: <code>{}</code> -> <code>{}</code>{}\n\
                 tachyon-core: <code>{}</code> -> <code>{}</code>{}\n\
                 {}: <code>{}</code> | {}: <code>{}</code>",
                tr(ru, "Проверка обновлений", "Update Check"),
                escape_html(&router.name),
                escape_html(t_cur),
                escape_html(t_lat),
                if t_status.is_empty() {
                    String::new()
                } else {
                    format!(" ({})", escape_html(t_status))
                },
                escape_html(c_cur),
                escape_html(c_lat),
                if c_status.is_empty() {
                    String::new()
                } else {
                    format!(" ({})", escape_html(c_status))
                },
                tr(ru, "Наборы правил", "Rule lists"),
                info.lists_count,
                tr(ru, "Подписки", "Subscriptions"),
                info.subscriptions_count,
            );
            let kb = inline_kb(vec![
                vec![
                    cb_btn(
                        tr(ru, "Обновить Tachyon", "Update Tachyon"),
                        &format!("flt_upd_ask {}", router.id),
                    ),
                    cb_btn(
                        tr(ru, "Повторить", "Re-check"),
                        &format!("flt_upd_chk {}", router.id),
                    ),
                ],
                vec![
                    cb_btn(
                        tr(ru, "К роутеру", "Back to Router"),
                        &format!("flt_view {}", router.id),
                    ),
                    cb_btn(tr(ru, "Все роутеры", "All Routers"), "flt_list 0"),
                ],
            ]);
            BotReply::with_kb(text, kb)
        }
        Err(e) => {
            let msg = sanitize_fleet_error(&e.display_sanitized(ru), &router.api_token);
            let text = format!(
                "[ERR] <b>{}: {}</b>\n{}",
                tr(ru, "Проверка обновлений", "Update Check"),
                escape_html(&router.name),
                escape_html(&msg)
            );
            let kb = inline_kb(vec![vec![
                cb_btn(
                    tr(ru, "К роутеру", "Back to Router"),
                    &format!("flt_view {}", router.id),
                ),
                cb_btn(tr(ru, "Все роутеры", "All Routers"), "flt_list 0"),
            ]]);
            BotReply::with_kb(text, kb)
        }
    }
}

pub(crate) async fn render_router_action_confirm(
    state: &Arc<AppState>,
    router_id: &str,
    action: FleetConfirmAction,
) -> BotReply {
    let (router_opt, ru) = {
        let d = state.data.read().await;
        (
            d.telegram
                .managed_routers
                .iter()
                .find(|r| r.id == router_id)
                .cloned(),
            is_ru(&d),
        )
    };
    let Some(router) = router_opt else {
        return Box::pin(render_fleet_overview(
            state,
            0,
            Some(tr(ru, "[ERR] Роутер не найден.", "[ERR] Router not found.").to_string()),
        ))
        .await;
    };

    let (title, desc, confirm_cmd) = match action {
        FleetConfirmAction::UpdateTachyon => (
            tr(
                ru,
                "Подтверждение обновления Tachyon",
                "Confirm Tachyon Update",
            ),
            tr(
                ru,
                "На удалённом узле будет запущено обновление Tachyon и проверка состояния после выполнения.",
                "This will start a Tachyon update on the remote node and verify health/version afterwards.",
            ),
            format!("flt_upd_ok {}", router.id),
        ),
        FleetConfirmAction::RestartTachyon => (
            tr(
                ru,
                "Подтверждение перезапуска Tachyon",
                "Confirm Tachyon Restart",
            ),
            tr(
                ru,
                "Служба маршрутизации на удалённом узле будет перезапущена с последующей проверкой состояния.",
                "This will restart Tachyon service on the remote node and run post-restart verification.",
            ),
            format!("flt_rst_ok {}", router.id),
        ),
        FleetConfirmAction::RemoveRouter => (
            tr(
                ru,
                "Подтверждение удаления роутера",
                "Confirm Router Removal",
            ),
            tr(
                ru,
                "Удалить этот роутер из списка централизованного управления?",
                "Remove this router from centralized management?",
            ),
            format!("flt_del_ok {}", router.id),
        ),
    };

    let text = format!(
        "<b>{}</b>\n{}: <b>{}</b>\nURL: <code>{}</code>\n\n{}",
        title,
        tr(ru, "Роутер", "Router"),
        escape_html(&router.name),
        escape_html(&sanitize_display_url(&router.url)),
        desc
    );
    let kb = inline_kb(vec![vec![
        cb_btn(tr(ru, "Подтвердить", "Confirm"), &confirm_cmd),
        cb_btn(
            tr(ru, "Отмена", "Cancel"),
            &format!("flt_view {}", router.id),
        ),
    ]]);
    BotReply::with_kb(text, kb)
}

fn format_action_outcome_reply(
    router: &ManagedRouter,
    action_title_ru: &str,
    action_title_en: &str,
    out: &ActionExecutionOutcome,
    ru: bool,
) -> BotReply {
    let badge = if out.action_ok { "[OK]" } else { "[ERR]" };
    let v_badge = if out.verification.reachable {
        "[OK]"
    } else {
        "[!]"
    };
    let ver_before = if out.prev_tachyon_version.is_empty() {
        "-"
    } else {
        out.prev_tachyon_version.as_str()
    };
    let ver_after = if out.verification.tachyon_version.is_empty() {
        "-"
    } else {
        out.verification.tachyon_version.as_str()
    };
    let core_ver = if out.verification.core_version.is_empty() {
        "-"
    } else {
        out.verification.core_version.as_str()
    };
    let core_state = match out.verification.core_running {
        Some(true) => "running",
        Some(false) => "stopped",
        None => "unknown",
    };
    let verify_line = if out.verification.reachable {
        format!(
            "{v_badge} {}: <code>online</code> | Core: <code>{}</code>\n  Tachyon: <code>{}</code> -> <code>{}</code> | Core: <code>{}</code>",
            tr(ru, "Проверка после операции", "Post-action verification"),
            escape_html(core_state),
            escape_html(ver_before),
            escape_html(ver_after),
            escape_html(core_ver)
        )
    } else if let Some(status) = out.verification.auth_error {
        format!(
            "{v_badge} {}: {}",
            tr(ru, "Проверка после операции", "Post-action verification"),
            escape_html(&FleetError::AuthRejected { status }.display_sanitized(ru))
        )
    } else {
        format!(
            "{v_badge} {}: <code>offline</code> ({})",
            tr(ru, "Проверка после операции", "Post-action verification"),
            escape_html(out.verification.error.as_deref().unwrap_or("unreachable"))
        )
    };

    let msg_raw = if !out.action_ok {
        if let Some(status) = out.auth_error {
            FleetError::AuthRejected { status }.display_sanitized(ru)
        } else {
            out.action_message.clone()
        }
    } else {
        out.action_message.clone()
    };
    let msg_safe = sanitize_fleet_error(&msg_raw, &router.api_token);
    let text = format!(
        "{badge} <b>{}: {}</b>\n{}: {}\n{}",
        tr(ru, action_title_ru, action_title_en),
        escape_html(&router.name),
        tr(ru, "Результат", "Execution"),
        escape_html(&msg_safe),
        verify_line
    );
    let kb = inline_kb(vec![vec![
        cb_btn(
            tr(ru, "К роутеру", "Back to Router"),
            &format!("flt_view {}", router.id),
        ),
        cb_btn(tr(ru, "Все роутеры", "All Routers"), "flt_list 0"),
    ]]);
    BotReply::with_kb(text, kb)
}

pub(crate) async fn execute_router_action_confirmed(
    state: &Arc<AppState>,
    router_id: &str,
    action: FleetConfirmAction,
) -> BotReply {
    let (router_opt, ru) = {
        let d = state.data.read().await;
        (
            d.telegram
                .managed_routers
                .iter()
                .find(|r| r.id == router_id)
                .cloned(),
            is_ru(&d),
        )
    };
    let Some(router) = router_opt else {
        return Box::pin(render_fleet_overview(
            state,
            0,
            Some(tr(ru, "[ERR] Роутер не найден.", "[ERR] Router not found.").to_string()),
        ))
        .await;
    };

    match action {
        FleetConfirmAction::UpdateTachyon => {
            let out = Box::pin(execute_router_update_tachyon(&router)).await;
            format_action_outcome_reply(&router, "Обновление Tachyon", "Tachyon Update", &out, ru)
        }
        FleetConfirmAction::RestartTachyon => {
            let out = Box::pin(execute_router_restart_tachyon(&router)).await;
            format_action_outcome_reply(&router, "Перезапуск Tachyon", "Tachyon Restart", &out, ru)
        }
        FleetConfirmAction::RemoveRouter => {
            let mut candidate = state.data.read().await.clone();
            let before = candidate.telegram.managed_routers.len();
            candidate
                .telegram
                .managed_routers
                .retain(|r| r.id != router_id);
            let removed = candidate.telegram.managed_routers.len() < before;
            let note = if !removed {
                tr(ru, "[ERR] Роутер не найден.", "[ERR] Router not found.").to_string()
            } else {
                match Box::pin(commit_transaction(state, candidate)).await {
                    Ok(_) => {
                        notify_bot_wakeup();
                        format!(
                            "[OK] {}: <b>{}</b>",
                            tr(ru, "Роутер удалён", "Router removed"),
                            escape_html(&router.name)
                        )
                    }
                    Err(e) => format!("[ERR] {}", escape_html(&e.to_string())),
                }
            };
            Box::pin(render_fleet_overview(state, 0, Some(note))).await
        }
    }
}

pub(crate) async fn start_add_router_prompt(chat_id: i64, state: &Arc<AppState>) -> BotReply {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    set_chat_prompt(chat_id, PendingPromptKind::FleetAddName);
    BotReply::with_kb(
        tr(
            ru,
            "<b>Добавление роутера (шаг 1/3)</b>\n\nВведите имя площадки / роутера (1..48 символов, например: <code>Office</code> или <code>Дача</code>).\nДля отмены: /cancel",
            "<b>Add Router (Step 1/3)</b>\n\nEnter site/router name (1..48 chars, e.g. <code>Office</code> or <code>Branch-1</code>).\nSend /cancel to abort.",
        ),
        inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
    )
}

pub(crate) async fn handle_fleet_prompt(
    kind: PendingPromptKind,
    input: &str,
    chat_id: i64,
    state: &Arc<AppState>,
) -> Option<BotReply> {
    let ru = {
        let d = state.data.read().await;
        is_ru(&d)
    };
    match kind {
        PendingPromptKind::FleetAddName => {
            let name = match validate_router_name(input) {
                Ok(n) => n,
                Err(_) => {
                    set_chat_prompt(chat_id, PendingPromptKind::FleetAddName);
                    return Some(BotReply::with_kb(
                        format!(
                            "[ERR] {}",
                            tr(
                                ru,
                                "Имя роутера не должно быть пустым (1..48 символов).",
                                "Router name must not be empty (1..48 chars)."
                            )
                        ),
                        inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
                    ));
                }
            };
            set_chat_prompt(
                chat_id,
                PendingPromptKind::FleetAddUrl { name: name.clone() },
            );
            Some(BotReply::with_kb(
                format!(
                    "<b>{}</b>\n{}: <b>{}</b>\n\n{}",
                    tr(ru, "Добавление роутера (шаг 2/3)", "Add Router (Step 2/3)"),
                    tr(ru, "Имя", "Name"),
                    escape_html(&name),
                    tr(
                        ru,
                        "Введите базовый URL панели управления (например <code>http://192.168.2.1:1680</code> или <code>https://branch.example.com</code>):",
                        "Enter router control panel base URL (e.g. <code>http://192.168.2.1:1680</code> or <code>https://branch.example.com</code>):"
                    )
                ),
                inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
            ))
        }
        PendingPromptKind::FleetAddUrl { name } => {
            let parsed = match normalize_and_validate_router_url(input) {
                Ok(p) => p,
                Err(err) => {
                    set_chat_prompt(chat_id, PendingPromptKind::FleetAddUrl { name });
                    return Some(BotReply::with_kb(
                        format!(
                            "[ERR] {}\n<code>{}</code>",
                            tr(
                                ru,
                                "Некорректный URL. Укажите http:// или https:// без пробелов и учётных данных.",
                                "Invalid URL. Enter http:// or https:// without spaces or embedded credentials."
                            ),
                            escape_html(&err)
                        ),
                        inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
                    ));
                }
            };
            set_chat_prompt(
                chat_id,
                PendingPromptKind::FleetAddToken {
                    name: name.clone(),
                    url: parsed.normalized_url.clone(),
                },
            );
            Some(BotReply::with_kb(
                format!(
                    "<b>{}</b>\n{}: <b>{}</b>\nURL: <code>{}</code>\n\n{}",
                    tr(ru, "Добавление роутера (шаг 3/3)", "Add Router (Step 3/3)"),
                    tr(ru, "Имя", "Name"),
                    escape_html(&name),
                    escape_html(&parsed.normalized_url),
                    tr(
                        ru,
                        "Отправьте API token (<code>agent_api_token</code>) удалённого роутера. В ответах и журналах токен не отображается.",
                        "Send the remote router API token (<code>agent_api_token</code>). The token is never echoed in replies or logs."
                    )
                ),
                inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
            ))
        }
        PendingPromptKind::FleetAddToken { name, url } => {
            let token = match validate_api_token(input) {
                Ok(t) => t,
                Err(_) => {
                    set_chat_prompt(chat_id, PendingPromptKind::FleetAddToken { name, url });
                    return Some(BotReply::with_kb(
                        format!(
                            "[ERR] {}",
                            tr(
                                ru,
                                "Некорректный API token (пустой, слишком длинный или содержит пробелы).",
                                "Invalid API token (empty, too long, or contains whitespace)."
                            )
                        ),
                        inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
                    ));
                }
            };

            let mut candidate = state.data.read().await.clone();
            if candidate.telegram.managed_routers.len() >= MAX_MANAGED_ROUTERS {
                return Some(BotReply::with_kb(
                    format!(
                        "[ERR] {}",
                        tr(
                            ru,
                            "Достигнут лимит количества управляемых роутеров.",
                            "Maximum managed router limit reached."
                        )
                    ),
                    inline_kb(vec![vec![cb_btn(
                        tr(ru, "Все роутеры", "All Routers"),
                        "flt_list 0",
                    )]]),
                ));
            }

            let new_id = generate_unique_router_id(&name, &candidate.telegram.managed_routers);
            let new_router = ManagedRouter {
                id: new_id.clone(),
                name: name.clone(),
                url: url.clone(),
                api_token: token,
                enabled: true,
            };

            let probe = Box::pin(probe_router_overview(&new_router, false)).await;
            if let Some(status) = probe.auth_error {
                set_chat_prompt(
                    chat_id,
                    PendingPromptKind::FleetAddToken {
                        name: name.clone(),
                        url: url.clone(),
                    },
                );
                return Some(BotReply::with_kb(
                    format!(
                        "[ERR] <b>{}</b>\n{}\n{}",
                        escape_html(&name),
                        escape_html(&FleetError::AuthRejected { status }.display_sanitized(ru)),
                        tr(
                            ru,
                            "Отправьте корректный API token или нажмите Отмена.",
                            "Send a valid API token or press Cancel."
                        )
                    ),
                    inline_kb(vec![vec![cb_btn(tr(ru, "Отмена", "Cancel"), "flt_list 0")]]),
                ));
            }

            candidate.telegram.managed_routers.push(new_router);
            match Box::pin(commit_transaction(state, candidate)).await {
                Ok(_) => {
                    notify_bot_wakeup();
                    let status_line = if probe.reachable {
                        let t_ver = if probe.tachyon_version.is_empty() {
                            "-"
                        } else {
                            probe.tachyon_version.as_str()
                        };
                        let c_ver = if probe.core_version.is_empty() {
                            "-"
                        } else {
                            probe.core_version.as_str()
                        };
                        format!(
                            "[ONLINE] Tachyon: <code>{}</code> | Core: <code>{}</code>",
                            escape_html(t_ver),
                            escape_html(c_ver)
                        )
                    } else {
                        format!(
                            "[!] <code>offline</code> ({})",
                            escape_html(probe.error.as_deref().unwrap_or("unreachable"))
                        )
                    };
                    Some(BotReply::with_kb(
                        format!(
                            "[OK] <b>{}: {}</b>\nURL: <code>{}</code>\nToken: <code>configured</code>\n{}",
                            tr(ru, "Роутер добавлен", "Router Added"),
                            escape_html(&name),
                            escape_html(&url),
                            status_line
                        ),
                        inline_kb(vec![
                            vec![
                                cb_btn(
                                    tr(ru, "Открыть роутер", "Inspect Router"),
                                    &format!("flt_view {new_id}"),
                                ),
                                cb_btn(tr(ru, "Все роутеры", "All Routers"), "flt_list 0"),
                            ],
                            vec![cb_btn(tr(ru, "Главное меню", "Main Menu"), "menu")],
                        ]),
                    ))
                }
                Err(e) => Some(BotReply::with_kb(
                    format!(
                        "[ERR] {}",
                        escape_html(&sanitize_fleet_error(&e.to_string(), ""))
                    ),
                    inline_kb(vec![vec![cb_btn(
                        tr(ru, "Все роутеры", "All Routers"),
                        "flt_list 0",
                    )]]),
                )),
            }
        }
        _ => None,
    }
}
