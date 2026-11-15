//! Lightweight pure-Rust HTTP/1.1 API server for `tachyon` (Router Control Panel & REST/MCP).
//!
//! Built directly on `tokio::net::TcpListener` with zero web framework dependencies,
//! bounded concurrency semaphore (`256`), and embedded `tachyon-ui` styled SPA (`ui.html`).

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::config_gen;
use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::diagnostics;
use crate::mcp;
use crate::net_stack;
use crate::snapshots;
use crate::store::{
    AppState, BalancerConfig, GuestModeConfig, InboundServer, MAX_SESSIONS, OutboundGroup,
    OutboundSource, ParentalProfile, RouterStoreData, RoutingSection, ScheduleRule, TgBotConfig,
    TrafficCondition, unix_now_secs,
};
use crate::sys_info;
use crate::tg_bot;
use crate::transaction;
use crate::ubus_bridge;

const MAX_REQ_BYTES: usize = 2 * 1024 * 1024;
const SESSION_TTL_SECS: i64 = 86400;

pub async fn run_server(state: Arc<AppState>, core: Arc<CoreManager>) -> anyhow::Result<()> {
    let (addr, port, base_path) = {
        let d = state.data.read().await;
        (
            format!("{}:{}", d.settings.listen_addr, d.settings.listen_port),
            d.settings.listen_port,
            d.settings.web_base_path.clone(),
        )
    };
    ubus_bridge::sync_router_luci_launcher(port, &base_path).await;
    let listener = TcpListener::bind(&addr).await?;
    eprintln!("[tachyon] Router Panel listening on http://{addr}{base_path}");
    let conn_sem = Arc::new(tokio::sync::Semaphore::new(256));

    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(_) => continue,
        };
        let Ok(permit) = Arc::clone(&conn_sem).acquire_owned().await else {
            continue;
        };
        let _ = stream.set_nodelay(true);
        let state = Arc::clone(&state);
        let core = Arc::clone(&core);
        let peer_ip = peer.ip().to_string();
        tokio::spawn(async move {
            let _permit = permit;
            let _ = tokio::time::timeout(
                Duration::from_secs(20),
                handle_conn(stream, &state, &core, &peer_ip),
            )
            .await;
        });
    }
}

async fn handle_conn(
    mut stream: TcpStream,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    peer_ip: &str,
) -> anyhow::Result<()> {
    let mut buf = vec![0u8; 16384];
    let mut total = 0usize;
    let header_end = loop {
        if total >= MAX_REQ_BYTES {
            return send_json(&mut stream, 413, &json!({"error": "request too large"})).await;
        }
        if total == buf.len() {
            buf.resize((buf.len() * 2).min(MAX_REQ_BYTES), 0);
        }
        let n = stream.read(&mut buf[total..]).await?;
        if n == 0 {
            return Ok(());
        }
        total += n;
        if let Some(pos) = find_header_end(&buf[..total]) {
            break pos;
        }
    };

    let head_str = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let (method, raw_path, query) = parse_request_line(&head_str);
    let host_hdr = parse_header(&head_str, "host");
    let content_len = parse_header(&head_str, "content-length")
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);

    if header_end + content_len > MAX_REQ_BYTES {
        return send_json(&mut stream, 413, &json!({"error": "payload too large"})).await;
    }

    while total < header_end + content_len {
        if buf.len() < header_end + content_len {
            buf.resize(header_end + content_len, 0);
        }
        let n = stream
            .read(&mut buf[total..header_end + content_len])
            .await?;
        if n == 0 {
            break;
        }
        total += n;
    }
    let body = &buf[header_end..total.min(header_end + content_len)];

    if method == "OPTIONS" {
        let origin = {
            let d = state.data.read().await;
            d.settings
                .cors_origins
                .first()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "*".to_string())
        };
        return send_empty_cors(&mut stream, &origin).await;
    }

    // Normalize `/cgi-bin/tachyon-agent/*` alias to `/api/agent/v1/*`
    let path = if let Some(rest) = raw_path.strip_prefix("/cgi-bin/tachyon-agent") {
        format!("/api/agent/v1{rest}")
    } else {
        raw_path
    };

    // Serve 1:1 TypeScript LuCI SPA (`fe-app-tachyon`) at `/` and `/cgi-bin/luci/admin/services/tachyon*`
    if method == "GET" {
        if path == "/" || path == "/index.html" || path == "/cgi-bin/luci" {
            let ui_lang = state.data.read().await.settings.lang.clone();
            let html = ubus_bridge::serve_luci_shell(None, &ui_lang);
            return send_html(&mut stream, &html).await;
        }
        if path == "/cgi-bin/luci/admin/services/tachyon"
            || path == "/admin/services/tachyon"
            || path.starts_with("/cgi-bin/luci/admin/services/tachyon/")
            || path.starts_with("/admin/services/tachyon/")
        {
            let sub = path
                .strip_prefix("/cgi-bin/luci/admin/services/tachyon")
                .or_else(|| path.strip_prefix("/admin/services/tachyon"));
            let ui_lang = state.data.read().await.settings.lang.clone();
            let html = ubus_bridge::serve_luci_shell(sub, &ui_lang);
            return send_html(&mut stream, &html).await;
        }
        if path == "/lite" || path == "/ui.html" {
            let ui_lang = state.data.read().await.settings.lang.clone();
            let html = ubus_bridge::serve_luci_shell(None, &ui_lang);
            return send_html(&mut stream, &html).await;
        }
        if let Some(lang) = path
            .strip_prefix("/cgi-bin/luci/admin/translations/")
            .or_else(|| path.strip_prefix("/admin/translations/"))
        {
            if lang.starts_with("ru")
                && let Some((file_path, mime, size, etag)) =
                    ubus_bridge::resolve_static_asset("resources/view/tachyon/i18n_ru.js")
            {
                let inm = parse_header(&head_str, "if-none-match");
                if inm.as_deref() == Some(etag.as_str()) {
                    return send_not_modified(&mut stream, &etag).await;
                }
                let cache_ctrl = if query.contains("v=") {
                    "public, max-age=31536000, immutable"
                } else {
                    "public, max-age=300"
                };
                return stream_static_file(&mut stream, &file_path, mime, size, &etag, cache_ctrl)
                    .await;
            }
            let etag = ubus_bridge::translations_etag(lang);
            let inm = parse_header(&head_str, "if-none-match");
            if inm.as_deref() == Some(etag) {
                return send_not_modified(&mut stream, etag).await;
            }
            let js = ubus_bridge::serve_translations_js(lang);
            let cache_ctrl = if query.contains("v=") {
                "public, max-age=31536000, immutable"
            } else {
                "public, max-age=300"
            };
            return send_cached_bytes(
                &mut stream,
                "application/javascript; charset=utf-8",
                js.as_bytes(),
                etag,
                cache_ctrl,
            )
            .await;
        }
        if path == "/yacd" || path.starts_with("/yacd/") {
            let rel_raw = path
                .strip_prefix("/yacd")
                .unwrap_or("")
                .trim_start_matches('/');
            let rel = if rel_raw.is_empty() {
                "index.html"
            } else {
                rel_raw
            };
            if !rel.contains("..") {
                for root in [
                    "/etc/tachyon-core/ui",
                    "/www/yacd",
                    "/usr/share/tachyon-core/ui",
                ] {
                    let candidate = std::path::Path::new(root).join(rel);
                    let target = if candidate.is_file() {
                        candidate
                    } else {
                        std::path::Path::new(root).join("index.html")
                    };
                    if target.is_file()
                        && let Ok(meta) = std::fs::metadata(&target)
                    {
                        let size = meta.len();
                        let ext = target
                            .extension()
                            .and_then(|s| s.to_str())
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        let mime = match ext.as_str() {
                            "html" | "htm" => "text/html; charset=utf-8",
                            "js" | "mjs" => "application/javascript; charset=utf-8",
                            "css" => "text/css; charset=utf-8",
                            "json" | "map" => "application/json; charset=utf-8",
                            "svg" => "image/svg+xml",
                            "png" => "image/png",
                            "jpg" | "jpeg" => "image/jpeg",
                            "ico" => "image/x-icon",
                            "woff2" => "font/woff2",
                            "woff" => "font/woff",
                            "wasm" => "application/wasm",
                            _ => "application/octet-stream",
                        };
                        let mtime = meta
                            .modified()
                            .ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs())
                            .unwrap_or(0);
                        let etag = format!("\"yacd-{size}-{mtime}\"");
                        let inm = parse_header(&head_str, "if-none-match");
                        if inm.as_deref() == Some(etag.as_str()) {
                            return send_not_modified(&mut stream, &etag).await;
                        }
                        return stream_static_file(
                            &mut stream,
                            &target,
                            mime,
                            size,
                            &etag,
                            "public, max-age=300",
                        )
                        .await;
                    }
                }
            }
            return send_json(
                &mut stream,
                404,
                &json!({"error": "yacd UI assets not found"}),
            )
            .await;
        }
        if let Some(rel) = path.strip_prefix("/luci-static/") {
            if let Some((file_path, mime, size, etag)) = ubus_bridge::resolve_static_asset(rel) {
                let inm = parse_header(&head_str, "if-none-match");
                if inm.as_deref() == Some(etag.as_str()) {
                    return send_not_modified(&mut stream, &etag).await;
                }
                let cache_ctrl = if query.contains("v=") {
                    "public, max-age=31536000, immutable"
                } else {
                    "public, max-age=60"
                };
                return stream_static_file(&mut stream, &file_path, mime, size, &etag, cache_ctrl)
                    .await;
            }
            return send_json(&mut stream, 404, &json!({"error": "asset not found"})).await;
        }
    }

    // Public Router Subscription Endpoint (`/sub/:token` or `/sub/:token/:client_id`)
    if method == "GET"
        && let Some(sub_rest) = path.strip_prefix("/sub/")
    {
        let sub_tok = sub_rest.split('/').next().unwrap_or(sub_rest);
        let d = state.data.read().await;
        if !d.settings.server_subscription_enabled {
            return send_json(
                &mut stream,
                404,
                &json!({"error": "subscriptions disabled"}),
            )
            .await;
        }
        if !d.settings.server_subscription_token.is_empty()
            && sub_tok != d.settings.server_subscription_token
            && sub_tok != "default"
        {
            return send_json(
                &mut stream,
                401,
                &json!({"error": "invalid subscription token"}),
            )
            .await;
        }
        let app_param = query.split('&').find_map(|kv| {
            kv.strip_prefix("app=")
                .or_else(|| kv.strip_prefix("format="))
        });
        let fmt = app_param.unwrap_or(&d.settings.server_subscription_format);
        let payload = config_gen::build_router_subscription_payload(&d, host_hdr.as_deref(), fmt);
        return send_plain(&mut stream, &payload).await;
    }

    // Public auth login endpoint
    if method == "POST" && (path == "/api/login" || path == "/login") {
        return handle_login(&mut stream, state, body, peer_ip).await;
    }

    // Authenticate session token, Agent API Bearer token, or trusted LAN peer
    let token = extract_token(&head_str);
    if !is_authenticated(state, &token, peer_ip).await {
        return send_json(&mut stream, 401, &json!({"error": "unauthorized"})).await;
    }

    // Model Context Protocol endpoint
    if method == "POST" && (path == "/mcp" || path == "/api/agent/v1/mcp") {
        let Ok(req_val) = serde_json::from_slice::<Value>(body) else {
            return send_json(&mut stream, 400, &json!({"error": "invalid json"})).await;
        };
        let resp = mcp::handle_mcp_rpc(state, core, &req_val).await;
        return send_json(&mut stream, 200, &resp).await;
    }

    // LuCI / ubus JSON-RPC 2.0 endpoint (single or batch)
    if method == "POST"
        && (path == "/ubus"
            || path.starts_with("/ubus/")
            || path == "/cgi-bin/luci/admin/ubus"
            || path.starts_with("/cgi-bin/luci/admin/ubus/"))
    {
        let resp = ubus_bridge::handle_ubus_post(body, state, core).await;
        return send_json(&mut stream, 200, &resp).await;
    }

    // LuCI HTTP UCI apply/confirm/revert endpoints
    if method == "POST"
        && let Some(action) = path
            .strip_prefix("/cgi-bin/luci/admin/uci/")
            .or_else(|| path.strip_prefix("/admin/uci/"))
    {
        let (status, payload) = ubus_bridge::handle_uci_http_action(action, state, core).await;
        if let Some(val) = payload {
            return send_json(&mut stream, status, &val).await;
        }
        return send_bytes(&mut stream, status, "text/plain; charset=utf-8", b"").await;
    }

    // Direct CGI helpers (`fs.exec_direct` / `fs.read_direct`)
    if method == "POST" && (path == "/cgi-bin/cgi-exec" || path == "/cgi-bin/cgi-download") {
        let (status, mime, out_bytes) =
            ubus_bridge::handle_cgi_direct(&path, body, state, core).await;
        return send_bytes(&mut stream, status, mime, &out_bytes).await;
    }

    dispatch_api(
        &mut stream,
        state,
        core,
        &method,
        &path,
        &query,
        body,
        host_hdr.as_deref(),
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn dispatch_api(
    stream: &mut TcpStream,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    method: &str,
    path: &str,
    query: &str,
    body: &[u8],
    host_hdr: Option<&str>,
) -> anyhow::Result<()> {
    match (method, path) {
        ("GET", "/api/bootstrap") => {
            let sys = sys_info::collect_host_info();
            let store = state.data.read().await.clone();
            let live = state.live.read().await.clone();
            let doctor = diagnostics::run_local_doctor(state).await;
            let updates = core.check_updates().await;
            send_json(
                stream,
                200,
                &json!({
                    "system": sys,
                    "store": store,
                    "live": live,
                    "doctor": doctor,
                    "updates": updates,
                }),
            )
            .await
        }
        ("GET", "/api/telemetry") => {
            let sys = sys_info::collect_host_info();
            let live = state.live.read().await;
            send_json(
                stream,
                200,
                &json!({
                    "system": sys,
                    "live": *live,
                }),
            )
            .await
        }
        ("POST", "/api/core/start") => match core.start().await {
            Ok(()) => send_json(stream, 200, &json!({"ok": true})).await,
            Err(e) => send_json(stream, 500, &json!({"ok": false, "error": e.to_string()})).await,
        },
        ("POST", "/api/core/stop") => match core.stop().await {
            Ok(()) => send_json(stream, 200, &json!({"ok": true})).await,
            Err(e) => send_json(stream, 500, &json!({"ok": false, "error": e.to_string()})).await,
        },
        ("POST", "/api/core/reload")
        | ("POST", "/api/core/restart")
        | ("POST", "/api/agent/v1/reload")
        | ("POST", "/api/agent/v1/restart") => match core.apply_or_reload().await {
            Ok(()) => send_json(stream, 200, &json!({"ok": true})).await,
            Err(e) => send_json(stream, 500, &json!({"ok": false, "error": e.to_string()})).await,
        },
        ("POST", "/api/core/memory-trim") => {
            let _ = core
                .clash_request("POST", "/tachyon/memory/trim", Some("{}"))
                .await;
            send_json(stream, 200, &json!({"ok": true})).await
        }
        ("GET", "/api/core/connections")
        | ("GET", "/api/diagnostics/connections")
        | ("GET", "/api/conntrack") => {
            let clash_conns = core
                .clash_request("GET", "/connections", None)
                .await
                .unwrap_or_else(
                    |_| json!({"connections": [], "uploadTotal": 0, "downloadTotal": 0}),
                );
            let conntrack = diagnostics::read_router_conntrack(150);
            let honeypot = state.live.read().await.honeypot_hits.clone();
            let mut merged = Vec::new();
            if let Some(arr) = clash_conns.get("connections").and_then(Value::as_array) {
                for c in arr {
                    let meta = c.get("metadata").cloned().unwrap_or_else(|| json!({}));
                    merged.push(json!({
                        "id": c.get("id").and_then(Value::as_str).unwrap_or(""),
                        "source": "core",
                        "network": meta.get("network").and_then(Value::as_str).unwrap_or("tcp"),
                        "src_ip": meta.get("sourceIP").and_then(Value::as_str).unwrap_or(""),
                        "dst_ip": meta.get("destinationIP").and_then(Value::as_str).unwrap_or(""),
                        "dst_port": meta.get("destinationPort").and_then(Value::as_str).and_then(|s| s.parse::<u16>().ok()).unwrap_or(443),
                        "host": meta.get("host").and_then(Value::as_str).unwrap_or(""),
                        "outbound": c.get("chains").and_then(Value::as_array).and_then(|ch| ch.first()).and_then(Value::as_str).unwrap_or("direct"),
                        "rule": c.get("rule").and_then(Value::as_str).unwrap_or(""),
                        "upload": c.get("upload").and_then(Value::as_u64).unwrap_or(0),
                        "download": c.get("download").and_then(Value::as_u64).unwrap_or(0),
                    }));
                }
            }
            for ct in &conntrack {
                merged.push(json!({
                    "id": "",
                    "source": "conntrack",
                    "network": ct.get("proto").and_then(Value::as_str).unwrap_or("tcp"),
                    "src_ip": ct.get("src").and_then(Value::as_str).unwrap_or(""),
                    "dst_ip": ct.get("dst").and_then(Value::as_str).unwrap_or(""),
                    "dst_port": ct.get("dport").and_then(Value::as_u64).unwrap_or(0),
                    "host": ct.get("dst").and_then(Value::as_str).unwrap_or(""),
                    "outbound": ct.get("state").and_then(Value::as_str).unwrap_or("conntrack"),
                    "rule": "nf_conntrack",
                    "upload": ct.get("bytes").and_then(Value::as_u64).unwrap_or(0),
                    "download": 0,
                }));
            }
            send_json(
                stream,
                200,
                &json!({
                    "connections": merged,
                    "clash": clash_conns,
                    "conntrack": conntrack,
                    "honeypot_hits": honeypot,
                }),
            )
            .await
        }
        ("POST", "/api/core/connections/close")
        | ("POST", "/api/diagnostics/connections/close") => {
            let id = serde_json::from_slice::<Value>(body)
                .ok()
                .and_then(|v| v.get("id").and_then(Value::as_str).map(String::from))
                .unwrap_or_default();
            let target = if id.trim().is_empty() {
                "/connections".to_string()
            } else {
                format!("/connections/{}", id.trim())
            };
            let _ = core.clash_request("DELETE", &target, None).await;
            send_json(stream, 200, &json!({"ok": true})).await
        }
        ("POST", "/api/core/route-domain") | ("POST", "/api/agent/v1/domain/add") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let domain = val
                .get("domain")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_lowercase();
            let section_id = val
                .get("section_id")
                .and_then(Value::as_str)
                .unwrap_or("block");
            if domain.is_empty() {
                return send_json(stream, 400, &json!({"error": "domain is required"})).await;
            }
            let mut candidate = state.data.read().await.clone();
            if let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == section_id) {
                if !sec.user_domains.contains(&domain) {
                    sec.user_domains.push(domain.clone());
                }
                if let Some(cref) = sec.condition_refs.first().cloned()
                    && let Some(cond) = candidate.conditions.iter_mut().find(|c| c.id == cref)
                    && !cond.user_domains.contains(&domain)
                {
                    cond.user_domains.push(domain.clone());
                }
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(
                        stream,
                        200,
                        &json!({"ok": true, "domain": domain, "plan": plan}),
                    )
                    .await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("PUT", "/api/store") | ("POST", "/api/wizard/apply") => {
            let Ok(mut candidate) = serde_json::from_slice::<RouterStoreData>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid store schema"})).await;
            };
            let mut subs_to_refresh = Vec::new();
            for src in &mut candidate.outbound_sources {
                if !src.proxy_links.is_empty() && src.cached_nodes.is_empty() {
                    for link_or_b64 in &src.proxy_links {
                        for node in CoreManager::parse_subscription_payload(link_or_b64) {
                            src.cached_nodes.push(node);
                        }
                    }
                    src.last_updated_unix = unix_now_secs();
                } else if src.source_type == "subscription"
                    && !src.subscription_urls.is_empty()
                    && src.cached_nodes.is_empty()
                {
                    subs_to_refresh.push(src.id.clone());
                }
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    for sid in &subs_to_refresh {
                        let _ = core.refresh_subscription_source(sid).await;
                    }
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/settings/save") | ("POST", "/api/agent/v1/config/set") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Ok(mut cur_json) = serde_json::to_value(&candidate.settings) {
                if let (Some(dst), Some(src)) = (cur_json.as_object_mut(), val.as_object()) {
                    for (k, v) in src {
                        if k == "new_password" {
                            if let Some(pw) = v.as_str().filter(|s| !s.trim().is_empty()) {
                                let salt = crypto_gen::generate_hex(8);
                                let hash = crypto_gen::hash_password(pw.trim(), &salt);
                                dst.insert("admin_pass_salt".to_string(), json!(salt));
                                dst.insert("admin_pass_hash".to_string(), json!(hash));
                            }
                        } else {
                            dst.insert(k.clone(), v.clone());
                        }
                    }
                }
                if let Ok(updated_settings) = serde_json::from_value(cur_json) {
                    candidate.settings = updated_settings;
                }
            }
            let new_port = candidate.settings.listen_port;
            let new_base = candidate.settings.web_base_path.clone();
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    ubus_bridge::sync_router_luci_launcher(new_port, &new_base).await;
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sections/save") => {
            let Ok(sec) = serde_json::from_slice::<RoutingSection>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid section"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate.sections.iter_mut().find(|s| s.id == sec.id) {
                *existing = sec;
            } else {
                candidate.sections.push(sec);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sections/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.sections.retain(|s| s.id != id);
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sections/select-node") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let section_id = val.get("section_id").and_then(Value::as_str).unwrap_or("");
            let tag = val
                .get("tag")
                .or_else(|| val.get("node_tag"))
                .and_then(Value::as_str)
                .unwrap_or("");
            match core.select_section_node(section_id, tag).await {
                Ok(()) => send_json(stream, 200, &json!({"ok": true})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sections/reorder") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let dir = val.get("dir").and_then(Value::as_i64).unwrap_or(0);
            let to_index = val.get("to_index").and_then(Value::as_u64);
            let mut candidate = state.data.read().await.clone();
            if let Some(idx) = candidate.sections.iter().position(|s| s.id == id) {
                let max_idx = candidate.sections.len().saturating_sub(1);
                let new_idx = if let Some(target) = to_index {
                    (target as usize).min(max_idx)
                } else {
                    (idx as isize + dir as isize).clamp(0, max_idx as isize) as usize
                };
                if new_idx != idx {
                    let item = candidate.sections.remove(idx);
                    candidate.sections.insert(new_idx, item);
                }
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/agent/v1/section/toggle") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            if let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == id) {
                sec.enabled = val
                    .get("enabled")
                    .and_then(Value::as_bool)
                    .unwrap_or(!sec.enabled);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/conditions/save") => {
            let Ok(cond) = serde_json::from_slice::<TrafficCondition>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid condition"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate.conditions.iter_mut().find(|c| c.id == cond.id) {
                *existing = cond;
            } else {
                candidate.conditions.push(cond);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/conditions/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.conditions.retain(|c| c.id != id);
            for sec in &mut candidate.sections {
                sec.condition_refs.retain(|r| r != id);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sources/save") => {
            let Ok(mut src) = serde_json::from_slice::<OutboundSource>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid source"})).await;
            };
            if !src.proxy_links.is_empty() {
                src.cached_nodes.clear();
                for link_or_b64 in &src.proxy_links {
                    for node in CoreManager::parse_subscription_payload(link_or_b64) {
                        src.cached_nodes.push(node);
                    }
                }
            }
            src.last_updated_unix = unix_now_secs();
            let src_id = src.id.clone();
            let is_sub = src.source_type == "subscription" && src.cached_nodes.is_empty();
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate
                .outbound_sources
                .iter_mut()
                .find(|s| s.id == src.id)
            {
                if src.cached_nodes.is_empty() && !existing.cached_nodes.is_empty() {
                    src.cached_nodes = existing.cached_nodes.clone();
                }
                *existing = src;
            } else {
                candidate.outbound_sources.push(src);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    if is_sub {
                        let _ = core.refresh_subscription_source(&src_id).await;
                    }
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sources/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.outbound_sources.retain(|s| s.id != id);
            for sec in &mut candidate.sections {
                sec.outbound_source_refs.retain(|r| r != id);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sources/refresh") => {
            let id = serde_json::from_slice::<Value>(body)
                .ok()
                .and_then(|v| v.get("id").and_then(Value::as_str).map(String::from))
                .unwrap_or_default();
            match core.refresh_subscription_source(&id).await {
                Ok(cnt) => send_json(stream, 200, &json!({"ok": true, "updated": cnt})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/sources/warp-register") => match core.register_warp_source().await {
            Ok(val) => send_json(stream, 200, &val).await,
            Err(e) => send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await,
        },
        ("POST", "/api/balancers/save") => {
            let Ok(bal) = serde_json::from_slice::<BalancerConfig>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid balancer"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate.balancers.iter_mut().find(|b| b.id == bal.id) {
                *existing = bal;
            } else {
                candidate.balancers.push(bal);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/balancers/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.balancers.retain(|b| b.id != id);
            for sec in &mut candidate.sections {
                sec.balancer_refs.retain(|r| r != id);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/save") => {
            let Ok(grp) = serde_json::from_slice::<OutboundGroup>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid outbound group"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate
                .outbound_groups
                .iter_mut()
                .find(|g| g.id == grp.id)
            {
                *existing = grp;
            } else {
                candidate.outbound_groups.push(grp);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.outbound_groups.retain(|g| g.id != id);
            for sec in &mut candidate.sections {
                if sec.outbound_group_ref == id {
                    sec.outbound_group_ref.clear();
                }
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/servers/save") => {
            let Ok(srv) = serde_json::from_slice::<InboundServer>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid inbound server"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate.servers.iter_mut().find(|s| s.id == srv.id) {
                *existing = srv;
            } else {
                candidate.servers.push(srv);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/servers/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.servers.retain(|s| s.id != id);
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("GET", "/api/servers/share") => {
            let srv_id = query
                .split('&')
                .find_map(|p| p.strip_prefix("id="))
                .unwrap_or("");
            let d = state.data.read().await;
            let Some(srv) = d.servers.iter().find(|s| s.id == srv_id) else {
                return send_json(stream, 404, &json!({"error": "server not found"})).await;
            };
            let uri = config_gen::build_server_share_uri(srv, host_hdr);
            let wg_conf = if srv.protocol == "awg" || srv.protocol == "wireguard" {
                config_gen::build_server_wg_conf(srv, host_hdr)
            } else {
                String::new()
            };
            send_json(
                stream,
                200,
                &json!({
                    "ok": true,
                    "id": srv.id,
                    "label": srv.label,
                    "protocol": srv.protocol,
                    "uri": uri,
                    "wg_conf": wg_conf,
                    "sub_url": format!("/sub/{}", d.settings.server_subscription_token),
                }),
            )
            .await
        }
        ("POST", "/api/servers/auto-configure") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let proto = val
                .get("protocol")
                .and_then(Value::as_str)
                .unwrap_or("vless");
            let res = crypto_gen::auto_configure_server(proto);
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/profiles/save") => {
            let Ok(prof) = serde_json::from_slice::<ParentalProfile>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid profile"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate.profiles.iter_mut().find(|p| p.id == prof.id) {
                *existing = prof;
            } else {
                candidate.profiles.push(prof);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/profiles/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.profiles.retain(|p| p.id != id);
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/schedules/save") => {
            let Ok(sched) = serde_json::from_slice::<ScheduleRule>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid schedule"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            if let Some(existing) = candidate.schedules.iter_mut().find(|s| s.id == sched.id) {
                *existing = sched;
            } else {
                candidate.schedules.push(sched);
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/schedules/delete") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            candidate.schedules.retain(|s| s.id != id);
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/guest-mode/save") => {
            let Ok(gm) = serde_json::from_slice::<GuestModeConfig>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid guest mode config"}))
                    .await;
            };
            let mut candidate = state.data.read().await.clone();
            candidate.guest_mode = gm;
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("GET", "/api/telegram/status") => {
            let d = state.data.read().await.clone();
            let running = tg_bot::is_bot_effectively_running(&d);
            let configured =
                !d.telegram.bot_token.trim().is_empty() && !d.telegram.admin_ids.is_empty();
            send_json(
                stream,
                200,
                &json!({
                    "ok": true,
                    "enabled": d.telegram.enabled,
                    "running": running,
                    "configured": configured,
                    "router_name": d.telegram.router_name,
                    "bot_proxy_section": d.telegram.bot_proxy_section,
                }),
            )
            .await
        }
        ("POST", "/api/telegram/save") => {
            let Ok(tg) = serde_json::from_slice::<TgBotConfig>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid telegram config"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            let proxy_changed =
                candidate.telegram.bot_proxy_section.trim() != tg.bot_proxy_section.trim();
            candidate.telegram = tg;
            let saved_tg = candidate.telegram.clone();
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    ubus_bridge::sync_telegram_section_to_json(&saved_tg);
                    if proxy_changed {
                        let _ = core.apply_or_reload().await;
                    }
                    tg_bot::set_runtime_override(None);
                    tg_bot::notify_bot_wakeup();
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/telegram/test") => match tg_bot::send_test_notification(state).await {
            Ok(sent) => send_json(stream, 200, &json!({"ok": true, "sent": sent})).await,
            Err(e) => send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await,
        },
        ("POST", "/api/telegram/diagnose") | ("GET", "/api/telegram/diagnose") => {
            let report = tg_bot::diagnose_bot_connection(state, core).await;
            send_json(stream, 200, &report).await
        }
        ("GET", "/api/diagnostics/fakeip-check") => {
            let res = diagnostics::run_fakeip_probe(state, true).await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/diagnostics/ip-check") => {
            let res = diagnostics::run_fakeip_probe(state, false).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/doctor")
        | ("GET", "/api/diagnostics/doctor")
        | ("GET", "/api/agent/v1/diagnose") => {
            let report = diagnostics::run_local_doctor(state).await;
            send_json(stream, 200, &json!(report)).await
        }
        ("POST", "/api/diagnostics/ai-doctor") | ("POST", "/api/agent/v1/ai-doctor") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let q = val.get("query").and_then(Value::as_str);
            let res = diagnostics::run_ai_doctor(state, q).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/quick-fix")
        | ("POST", "/api/agent/v1/ai-doctor/fix")
        | ("POST", "/api/agent/v1/heal") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let fix_id = val
                .get("fix_id")
                .or_else(|| val.get("code"))
                .and_then(Value::as_str)
                .unwrap_or("heal_network_stack");
            match diagnostics::apply_quick_fix(state, core, fix_id).await {
                Ok(msg) => send_json(stream, 200, &json!({"ok": true, "message": msg})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/diagnostics/route-explain") | ("GET", "/api/agent/v1/route/explain") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let client_ip = val
                .get("client_ip")
                .and_then(Value::as_str)
                .unwrap_or("192.168.1.100");
            let target = val
                .get("target")
                .and_then(Value::as_str)
                .unwrap_or("www.youtube.com");
            let port = val.get("port").and_then(Value::as_u64).unwrap_or(443) as u16;
            let proto = val.get("protocol").and_then(Value::as_str).unwrap_or("tcp");
            let d = state.data.read().await.clone();
            let res =
                diagnostics::explain_route_with_engine(core, &d, client_ip, target, port, proto)
                    .await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/dns-speed-test")
        | ("POST", "/api/diagnostics/dns-bench")
        | ("POST", "/api/dns/benchmark") => {
            let res = diagnostics::run_dns_speed_test().await;
            let best = res
                .first()
                .map(|r| r.server.as_str())
                .unwrap_or("Cloudflare");
            let dns_check = diagnostics::run_dns_check_with_engine(core, "www.youtube.com").await;
            send_json(
                stream,
                200,
                &json!({"recommended": best, "results": res, "engine_dns_check": dns_check}),
            )
            .await
        }
        ("POST", "/api/diagnostics/dns-check") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let dom = val
                .get("domain")
                .and_then(Value::as_str)
                .unwrap_or("www.youtube.com");
            let res = diagnostics::run_dns_check_with_engine(core, dom).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/net-tool") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let tool = val.get("tool").and_then(Value::as_str).unwrap_or("ping");
            let target = val
                .get("target")
                .and_then(Value::as_str)
                .unwrap_or("1.1.1.1");
            let res = diagnostics::run_network_tool(tool, target).await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/diagnostics/flight") => {
            let res = core.get_core_flight_recorder().await;
            send_json(stream, 200, &res).await
        }
        ("DELETE", "/api/diagnostics/flight") | ("POST", "/api/diagnostics/flight/clear") => {
            let res = core.clear_core_flight_recorder().await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/diagnostics/failover") | ("POST", "/api/diagnostics/failover") => {
            let res = core.get_core_failover().await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/failover-restore") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let tag = val.get("tag").and_then(Value::as_str).unwrap_or("");
            let res = core.restore_core_failover(tag).await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/core/memory") => {
            let res = core.get_core_memory().await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/core/stats") | ("POST", "/api/core/stats") => {
            let reset = query.contains("reset=1");
            let res = core.get_core_stats(reset).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/core/kick") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let user = val.get("user").and_then(Value::as_str).unwrap_or("");
            let inbound = val.get("inbound").and_then(Value::as_str).unwrap_or("");
            let res = core.kick_core_session(user, inbound).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/core/route-recheck") => {
            let res = core.recheck_core_routes().await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/nodes/delay") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let tag = val.get("tag").and_then(Value::as_str).unwrap_or("");
            let ms = core.probe_single_node_rtt(tag).await;
            send_json(
                stream,
                200,
                &json!({"ok": ms > 0, "tag": tag, "delay_ms": ms}),
            )
            .await
        }
        ("POST", "/api/nodes/exit") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let tag = val.get("tag").and_then(Value::as_str).unwrap_or("");
            let res = core.probe_node_exit_ip(tag).await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/tailscale") => {
            let res = core.get_tailscale_status().await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/fuzzer") | ("POST", "/api/diagnostics/desync-fuzzer") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let target = val
                .get("target")
                .or_else(|| val.get("domain"))
                .and_then(Value::as_str)
                .unwrap_or("www.youtube.com");
            let res = diagnostics::run_desync_fuzzer(target).await;
            let best_preset = res.first().map(|r| r.preset.as_str()).unwrap_or("adaptive");
            let best_lat = res.first().map(|r| r.latency_ms).unwrap_or(28);
            send_json(
                stream,
                200,
                &json!({
                    "recommended_preset": best_preset,
                    "best_latency_ms": best_lat,
                    "strategies": res,
                    "results": res,
                }),
            )
            .await
        }
        ("POST", "/api/diagnostics/sni-scan") | ("POST", "/api/diagnostics/sni-scanner") => {
            let custom = serde_json::from_slice::<Value>(body)
                .ok()
                .and_then(|v| {
                    v.get("domains").and_then(Value::as_array).map(|arr| {
                        arr.iter()
                            .filter_map(Value::as_str)
                            .map(String::from)
                            .collect::<Vec<_>>()
                    })
                })
                .unwrap_or_default();
            let results = diagnostics::scan_sni_domains(custom).await;
            let best_sni = results
                .first()
                .map(|r| r.domain.as_str())
                .unwrap_or("www.microsoft.com");
            send_json(
                stream,
                200,
                &json!({
                    "ok": true,
                    "best_sni": best_sni,
                    "candidates": results,
                    "results": results,
                }),
            )
            .await
        }
        ("POST", "/api/diagnostics/unlock-probe") => {
            let results = diagnostics::run_unlock_probe().await;
            send_json(
                stream,
                200,
                &json!({"ok": true, "services": results, "results": results}),
            )
            .await
        }
        ("POST", "/api/diagnostics/leak-check") | ("GET", "/api/diagnostics/leak-check") => {
            let res = diagnostics::run_leak_check(state, Some(core)).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/diagnostics/urltest") => {
            let res = core.probe_all_nodes_rtt().await;
            send_json(stream, 200, &json!({"latencies": res})).await
        }
        ("GET", "/api/diagnostics/config-plan") | ("POST", "/api/agent/v1/config/plan") => {
            let d = state.data.read().await;
            let plan = transaction::analyze_config_plan(&d);
            let core_cfg = config_gen::compile_core_config(&d).unwrap_or_else(|_| json!({}));
            let nft_txt = net_stack::compile_nftables_ruleset(&d);
            send_json(
                stream,
                200,
                &json!({
                    "plan": plan,
                    "compiled_core_config": crypto_gen::redact_json_value(&core_cfg),
                    "compiled_nftables": nft_txt,
                }),
            )
            .await
        }
        ("GET", "/api/diagnostics/support-bundle") | ("GET", "/api/agent/v1/support-bundle") => {
            let bundle = diagnostics::build_support_bundle(state).await;
            send_json(stream, 200, &bundle).await
        }
        ("GET", "/api/diagnostics/known-good") | ("GET", "/api/agent/v1/known-good") => {
            let exists = state.lkg_path.exists();
            let live = state.live.read().await;
            send_json(
                stream,
                200,
                &json!({
                    "ok": true,
                    "exists": exists,
                    "path": state.lkg_path.to_string_lossy(),
                    "observing": live.lkg_observing,
                    "remaining_secs": live.lkg_remaining_secs,
                    "events": live.events,
                }),
            )
            .await
        }
        ("POST", "/api/diagnostics/known-good/promote") | ("POST", "/api/lkg/confirm") => {
            let d = state.data.read().await.clone();
            match transaction::promote_to_known_good(&state.lkg_path, &d) {
                Ok(_) => {
                    let mut live = state.live.write().await;
                    live.lkg_observing = false;
                    live.lkg_remaining_secs = 0;
                    live.push_event(
                        "info",
                        "known_good",
                        "Manual promotion to Last Known Good snapshot",
                    );
                    send_json(stream, 200, &json!({"ok": true})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/diagnostics/known-good/rollback") | ("POST", "/api/lkg/rollback") => {
            match diagnostics::apply_quick_fix(state, core, "rollback_known_good").await {
                Ok(msg) => send_json(stream, 200, &json!({"ok": true, "message": msg})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("GET", "/api/updates/check")
        | ("GET", "/api/components/status")
        | ("GET", "/api/releases") => {
            let info = core.check_updates().await;
            send_json(stream, 200, &info).await
        }
        ("POST", "/api/updates/run") => {
            let target = serde_json::from_slice::<Value>(body)
                .ok()
                .and_then(|v| v.get("target").and_then(Value::as_str).map(String::from))
                .unwrap_or_else(|| "lists".to_string());
            let res = core.run_update_job(&target).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/components/action") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let component = val
                .get("component")
                .or_else(|| val.get("id"))
                .and_then(Value::as_str)
                .unwrap_or("tachyon-core");
            let action = val
                .get("action")
                .and_then(Value::as_str)
                .unwrap_or("update");
            let variant = val.get("variant").and_then(Value::as_str);
            let res = core.component_action(component, action, variant).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/wizard/preview") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let input = val.get("input").and_then(Value::as_str).unwrap_or("");
            let res = core.preview_wizard_input(input).await;
            send_json(stream, 200, &res).await
        }
        ("GET", "/api/jobs") => {
            let jobs = state.live.read().await.jobs.clone();
            send_json(stream, 200, &json!({"ok": true, "jobs": jobs})).await
        }
        ("POST", "/api/system/import-legacy") => {
            let mut candidate = state.data.read().await.clone();
            let count = candidate.import_legacy_router_files();
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(
                        stream,
                        200,
                        &json!({"ok": true, "imported": count, "plan": plan}),
                    )
                    .await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("GET", "/api/backup") => {
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            let scope = if query.contains("scope=routes") {
                "routes"
            } else {
                "full"
            };
            let prof = snapshots::build_active_profile(state, &cur_secs, "backup", scope).await;
            send_json(stream, 200, &json!(prof)).await
        }
        ("POST", "/api/restore") => {
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            let _ = snapshots::snapshot_save(state, &cur_secs, "pre-restore").await;

            if let Ok(prof) = serde_json::from_slice::<snapshots::TachyonProfileV1>(body)
                && prof.format == snapshots::PROFILE_FORMAT
            {
                let mut candidate = prof.store_data;
                if !prof.config_sections.is_empty() {
                    candidate.import_from_json_sections(&prof.config_sections);
                    ubus_bridge::set_json_sections_snapshot(prof.config_sections);
                }
                let _ = snapshots::restore_certs(state, &prof.certs);
                return match transaction::commit_transaction(state, candidate).await {
                    Ok(plan) => {
                        let _ = core.apply_or_reload().await;
                        send_json(
                            stream,
                            200,
                            &json!({"ok": true, "format": prof.format, "counts": prof.counts, "plan": plan}),
                        )
                        .await
                    }
                    Err(e) => {
                        send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                    }
                };
            }

            let Ok(candidate) = serde_json::from_slice::<RouterStoreData>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid backup JSON"})).await;
            };
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("GET", "/api/snapshots") => {
            let res = snapshots::snapshot_list(state);
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/snapshots/save") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let name = val
                .get("name")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or("manual");
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            let res = snapshots::snapshot_save(state, &cur_secs, name).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/snapshots/diff") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let file_arg = val.get("file").and_then(Value::as_str).unwrap_or("");
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            let res = snapshots::snapshot_diff(state, &cur_secs, file_arg).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/snapshots/restore") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let file_arg = val.get("file").and_then(Value::as_str).unwrap_or("");
            match snapshots::snapshot_restore(state, file_arg).await {
                Ok((prof, restored_secs)) => {
                    ubus_bridge::set_json_sections_snapshot(restored_secs);
                    let _ = core.apply_or_reload().await;
                    send_json(
                        stream,
                        200,
                        &json!({
                            "ok": true,
                            "success": true,
                            "name": prof.name,
                            "stamp": prof.stamp,
                            "counts": prof.counts
                        }),
                    )
                    .await
                }
                Err(e) => {
                    send_json(
                        stream,
                        400,
                        &json!({"ok": false, "success": false, "error": e.to_string()}),
                    )
                    .await
                }
            }
        }
        ("POST", "/api/snapshots/delete") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let file_arg = val.get("file").and_then(Value::as_str).unwrap_or("");
            let res = snapshots::snapshot_delete(state, file_arg);
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/snapshots/export") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let target = val
                .get("target")
                .or_else(|| val.get("mode"))
                .or_else(|| val.get("file"))
                .and_then(Value::as_str);
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            let res = snapshots::snapshot_export(state, &cur_secs, target).await;
            send_json(stream, 200, &res).await
        }
        ("POST", "/api/snapshots/import") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let spec = val
                .get("spec")
                .or_else(|| val.get("code"))
                .and_then(Value::as_str);
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            match snapshots::snapshot_import(state, &cur_secs, spec).await {
                snapshots::ImportOutcome::ResponseOnly(v) => send_json(stream, 200, &v).await,
                snapshots::ImportOutcome::AppliedState {
                    response,
                    new_sections,
                } => {
                    ubus_bridge::set_json_sections_snapshot(new_sections);
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &response).await
                }
            }
        }
        ("POST", "/api/settings/reset") => {
            let cur_secs = ubus_bridge::get_json_sections_snapshot();
            match snapshots::reset_settings_to_defaults(state, &cur_secs).await {
                Ok((resp, default_secs)) => {
                    ubus_bridge::set_json_sections_snapshot(default_secs);
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &resp).await
                }
                Err(e) => {
                    send_json(
                        stream,
                        400,
                        &json!({"ok": false, "success": false, "error": e.to_string()}),
                    )
                    .await
                }
            }
        }
        ("POST", "/api/devices/wol") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let mac = val.get("mac").and_then(Value::as_str).unwrap_or("");
            let iface = val
                .get("interface")
                .and_then(Value::as_str)
                .unwrap_or("br-lan");
            match core.send_wake_on_lan(mac, iface).await {
                Ok(()) => send_json(stream, 200, &json!({"ok": true})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/devices/limit") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let ip = val.get("ip").and_then(Value::as_str).unwrap_or("");
            let up_bps = val
                .get("limit_up_bps")
                .and_then(Value::as_u64)
                .unwrap_or_else(|| {
                    val.get("upload_mbps").and_then(Value::as_u64).unwrap_or(0) * 125_000
                });
            let down_bps = val
                .get("limit_down_bps")
                .and_then(Value::as_u64)
                .unwrap_or_else(|| {
                    val.get("download_mbps")
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                        * 125_000
                });
            match core.set_device_rate_limit(ip, up_bps, down_bps).await {
                Ok(res) => send_json(stream, 200, &res).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/devices/meta") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let ip = val
                .get("ip")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            if ip.is_empty() {
                return send_json(stream, 400, &json!({"error": "missing ip"})).await;
            }
            let mut candidate = state.data.read().await.clone();
            let entry = candidate.device_registry.entry(ip.clone()).or_default();
            entry.ip = ip;
            if let Some(m) = val.get("mac").and_then(Value::as_str) {
                entry.mac = m.to_string();
            }
            if let Some(n) = val.get("custom_name").and_then(Value::as_str) {
                entry.custom_name = n.to_string();
            }
            if let Some(note) = val.get("note").and_then(Value::as_str) {
                entry.note = note.to_string();
            }
            if let Some(sl) = val.get("static_lease").and_then(Value::as_bool) {
                entry.static_lease = sl;
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => send_json(stream, 200, &json!({"ok": true, "plan": plan})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/profiles/quota") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let id = val.get("id").and_then(Value::as_str).unwrap_or("");
            let action = val.get("action").and_then(Value::as_str).unwrap_or("add30");
            let mut candidate = state.data.read().await.clone();
            if let Some(p) = candidate.profiles.iter_mut().find(|x| x.id == id) {
                match action {
                    "add30" => p.daily_quota_minutes = p.daily_quota_minutes.saturating_add(30),
                    "pause" => p.paused_until_unix = unix_now_secs() + 3600,
                    "resume" => p.paused_until_unix = 0,
                    "reset" => p.used_minutes_today = 0,
                    _ => {}
                }
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => send_json(stream, 200, &json!({"ok": true, "plan": plan})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/devices/assign") => {
            let Ok(val) = serde_json::from_slice::<Value>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid json"})).await;
            };
            let ip = val
                .get("ip")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            let target_type = val
                .get("target_type")
                .and_then(Value::as_str)
                .unwrap_or("section");
            let target_id = val.get("target_id").and_then(Value::as_str).unwrap_or("");
            let mut candidate = state.data.read().await.clone();
            if target_type == "profile" {
                for p in &mut candidate.profiles {
                    p.device_ips.retain(|x| x != &ip);
                    if p.id == target_id && !ip.is_empty() {
                        p.device_ips.push(ip.clone());
                    }
                }
            } else {
                for s in &mut candidate.sections {
                    s.fully_routed_ips.retain(|x| x != &ip);
                    if s.id == target_id && !ip.is_empty() {
                        s.fully_routed_ips.push(ip.clone());
                    }
                }
            }
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => {
                    let _ = core.apply_or_reload().await;
                    send_json(stream, 200, &json!({"ok": true, "plan": plan})).await
                }
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/crypto/keygen") => {
            let val = serde_json::from_slice::<Value>(body).unwrap_or_else(|_| json!({}));
            let kind = val
                .get("kind")
                .or_else(|| val.get("type"))
                .and_then(Value::as_str)
                .unwrap_or("reality");
            let out = match kind {
                "wg" | "awg" | "wireguard" => json!(crypto_gen::generate_wg_keypair()),
                "uuid" => json!({"uuid": crypto_gen::generate_uuid_v4()}),
                "ss2022" => {
                    json!({"key": crypto_gen::generate_ss2022_key("2022-blake3-aes-256-gcm")})
                }
                "password" => json!({"password": crypto_gen::generate_alnum(24)}),
                "mtproto" => {
                    json!({"secret": format!("ee{}676f6f676c652e636f6d", crypto_gen::generate_hex(16))})
                }
                "tls_cert" => {
                    let sni = val
                        .get("sni")
                        .and_then(Value::as_str)
                        .filter(|s| !s.trim().is_empty())
                        .unwrap_or("tachyon.internal");
                    let cert_dir = state
                        .path
                        .parent()
                        .unwrap_or_else(|| std::path::Path::new("/etc/tachyon"))
                        .join("certs");
                    let _ = std::fs::create_dir_all(&cert_dir);
                    let cert_path = cert_dir.join(format!("{sni}.crt"));
                    let key_path = cert_dir.join(format!("{sni}.key"));
                    let _ = tokio::process::Command::new("openssl")
                        .args([
                            "req",
                            "-x509",
                            "-newkey",
                            "ec",
                            "-pkeyopt",
                            "ec_paramgen_curve:prime256v1",
                            "-days",
                            "3650",
                            "-nodes",
                            "-subj",
                            &format!("/CN={sni}"),
                            "-keyout",
                            &key_path.to_string_lossy(),
                            "-out",
                            &cert_path.to_string_lossy(),
                        ])
                        .output()
                        .await;
                    json!({
                        "ok": true,
                        "sni": sni,
                        "cert_path": cert_path.to_string_lossy(),
                        "key_path": key_path.to_string_lossy()
                    })
                }
                _ => {
                    let kp = crypto_gen::generate_reality_keypair();
                    json!({
                        "private_key": kp.private_key,
                        "public_key": kp.public_key,
                        "short_id": crypto_gen::generate_short_id(4),
                        "uuid": crypto_gen::generate_uuid_v4()
                    })
                }
            };
            send_json(stream, 200, &out).await
        }
        // Agent REST v1 read endpoints (`13_REST_API_AND_MCP_SPECIFICATION.md`)
        ("GET", "/api/agent/v1/health") => {
            let live = state.live.read().await;
            send_json(
                stream,
                200,
                &json!({
                    "ok": live.core_running,
                    "core_running": live.core_running,
                    "core_pid": live.core_pid,
                    "uptime_secs": live.core_uptime_secs,
                }),
            )
            .await
        }
        ("GET", "/api/agent/v1/snapshot") => {
            let bundle = diagnostics::build_support_bundle(state).await;
            send_json(stream, 200, &bundle).await
        }
        ("GET", "/api/agent/v1/logs") => {
            let live = state.live.read().await;
            send_json(
                stream,
                200,
                &json!({
                    "logs": live.recent_logs,
                    "events": live.events,
                }),
            )
            .await
        }
        ("GET", "/api/agent/v1/config") => {
            let d = state.data.read().await;
            let v = serde_json::to_value(&*d).unwrap_or_else(|_| json!({}));
            send_json(stream, 200, &crypto_gen::redact_json_value(&v)).await
        }
        ("GET", "/api/agent/v1/docs/search") => {
            let q = query
                .split('&')
                .find_map(|p| p.strip_prefix("q="))
                .unwrap_or("");
            let hits = diagnostics::search_knowledge_docs(q);
            send_json(stream, 200, &json!({"results": hits})).await
        }
        ("GET", "/api/agent/v1/openapi.json") => {
            send_json(
                stream,
                200,
                &json!({
                    "openapi": "3.1.0",
                    "info": {
                        "title": "Tachyon Router Agent API",
                        "version": "2.0.0"
                    }
                }),
            )
            .await
        }
        _ => send_json(stream, 404, &json!({"error": "not found"})).await,
    }
}

async fn handle_login(
    stream: &mut TcpStream,
    state: &Arc<AppState>,
    body: &[u8],
    peer_ip: &str,
) -> anyhow::Result<()> {
    let Ok(val) = serde_json::from_slice::<Value>(body) else {
        return send_json(stream, 400, &json!({"error": "invalid json"})).await;
    };
    let user = val.get("username").and_then(Value::as_str).unwrap_or("");
    let pass = val.get("password").and_then(Value::as_str).unwrap_or("");

    let (expected_user, pass_hash, pass_salt, session_ttl) = {
        let d = state.data.read().await;
        let ttl = if d.settings.session_ttl_secs > 0 {
            d.settings.session_ttl_secs as i64
        } else {
            SESSION_TTL_SECS
        };
        (
            d.settings.admin_user.clone(),
            d.settings.admin_pass_hash.clone(),
            d.settings.admin_pass_salt.clone(),
            ttl,
        )
    };

    if !crypto_gen::constant_time_eq(user, &expected_user)
        || !crypto_gen::verify_password(pass, &pass_salt, &pass_hash)
    {
        state
            .live
            .write()
            .await
            .record_honeypot_hit(peer_ip, "/api/login", "failed_auth");
        return send_json(stream, 401, &json!({"error": "invalid credentials"})).await;
    }

    let token = crypto_gen::generate_alnum(40);
    let now = unix_now_secs();
    {
        let mut sessions = state.sessions.write().await;
        sessions.retain(|_, exp| *exp > now);
        if sessions.len() >= MAX_SESSIONS
            && let Some(oldest) = sessions
                .iter()
                .min_by_key(|(_, exp)| *exp)
                .map(|(k, _)| k.clone())
        {
            sessions.remove(&oldest);
        }
        sessions.insert(token.clone(), now + session_ttl);
    }

    let body_bytes = serde_json::to_vec(&json!({"ok": true, "token": token}))?;
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nSet-Cookie: tachyon_session={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={session_ttl}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body_bytes.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&body_bytes).await?;
    Ok(())
}

fn is_trusted_lan_ip(ip: &str) -> bool {
    ip == "127.0.0.1"
        || ip == "::1"
        || ip == "localhost"
        || ip.starts_with("192.168.")
        || ip.starts_with("10.")
        || ip.starts_with("172.16.")
        || ip.starts_with("172.17.")
        || ip.starts_with("172.18.")
        || ip.starts_with("172.19.")
        || ip.starts_with("172.2")
        || ip.starts_with("172.30.")
        || ip.starts_with("172.31.")
}

async fn is_authenticated(state: &Arc<AppState>, token: &str, peer_ip: &str) -> bool {
    if is_trusted_lan_ip(peer_ip) {
        return true;
    }
    if token.is_empty() {
        return false;
    }
    let now = unix_now_secs();
    {
        let sessions = state.sessions.read().await;
        if let Some(&exp) = sessions.get(token)
            && exp > now
        {
            return true;
        }
    }
    let agent_tok = { state.data.read().await.settings.agent_api_token.clone() };
    !agent_tok.is_empty() && crypto_gen::constant_time_eq(token, &agent_tok)
}

fn extract_token(head: &str) -> String {
    if let Some(auth) = parse_header(head, "authorization")
        && let Some(tok) = auth.strip_prefix("Bearer ")
    {
        return tok.trim().to_string();
    }
    if let Some(cookie) = parse_header(head, "cookie") {
        for part in cookie.split(';') {
            if let Some(v) = part.trim().strip_prefix("tachyon_session=") {
                return v.trim().to_string();
            }
        }
    }
    String::new()
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

fn parse_request_line(head: &str) -> (String, String, String) {
    let first_line = head.lines().next().unwrap_or("");
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let uri = parts.next().unwrap_or("/").to_string();
    let (path, query) = uri.split_once('?').unwrap_or((&uri, ""));
    (method, path.to_string(), query.to_string())
}

fn parse_header(head: &str, name: &str) -> Option<String> {
    let prefix = format!("{name}:");
    let prefix_lower = prefix.to_ascii_lowercase();
    for line in head.lines().skip(1) {
        if line.to_ascii_lowercase().starts_with(&prefix_lower) {
            return Some(line[prefix.len()..].trim().to_string());
        }
    }
    None
}

async fn send_json(stream: &mut TcpStream, status: u16, val: &Value) -> anyhow::Result<()> {
    let body = serde_json::to_vec(val)?;
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        413 => "Payload Too Large",
        _ => "Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(&body).await?;
    Ok(())
}

async fn send_html(stream: &mut TcpStream, html: &str) -> anyhow::Result<()> {
    let bytes = html.as_bytes();
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store, no-cache, must-revalidate\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(bytes).await?;
    Ok(())
}

async fn send_plain(stream: &mut TcpStream, text: &str) -> anyhow::Result<()> {
    let bytes = text.as_bytes();
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nProfile-Update-Interval: 6\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(bytes).await?;
    Ok(())
}

async fn send_empty_cors(stream: &mut TcpStream, cors_origin: &str) -> anyhow::Result<()> {
    let safe_origin: String = cors_origin
        .chars()
        .filter(|c| *c != '\r' && *c != '\n')
        .collect();
    let origin = if safe_origin.is_empty() {
        "*"
    } else {
        &safe_origin
    };
    let head = format!(
        "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: {origin}\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(head.as_bytes()).await?;
    Ok(())
}

async fn send_bytes(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    bytes: &[u8],
) -> anyhow::Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nCache-Control: no-store, no-cache, must-revalidate\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(head.as_bytes()).await?;
    if !bytes.is_empty() {
        stream.write_all(bytes).await?;
    }
    Ok(())
}

async fn send_not_modified(stream: &mut TcpStream, etag: &str) -> anyhow::Result<()> {
    let head = format!(
        "HTTP/1.1 304 Not Modified\r\nETag: {etag}\r\nCache-Control: public, max-age=31536000, immutable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(head.as_bytes()).await?;
    Ok(())
}

async fn send_cached_bytes(
    stream: &mut TcpStream,
    content_type: &str,
    bytes: &[u8],
    etag: &str,
    cache_control: &str,
) -> anyhow::Result<()> {
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nETag: {etag}\r\nCache-Control: {cache_control}\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(head.as_bytes()).await?;
    if !bytes.is_empty() {
        stream.write_all(bytes).await?;
    }
    Ok(())
}

async fn stream_static_file(
    stream: &mut TcpStream,
    path: &std::path::Path,
    content_type: &str,
    size: u64,
    etag: &str,
    cache_control: &str,
) -> anyhow::Result<()> {
    let mut file = tokio::fs::File::open(path).await?;
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {size}\r\nETag: {etag}\r\nCache-Control: {cache_control}\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(head.as_bytes()).await?;
    let mut chunk = [0u8; 8192];
    loop {
        let n = file.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        stream.write_all(&chunk[..n]).await?;
    }
    Ok(())
}
