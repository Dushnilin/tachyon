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
use crate::store::{
    AppState, BalancerConfig, GuestModeConfig, InboundServer, MAX_SESSIONS, OutboundGroup,
    OutboundSource, ParentalProfile, RouterStoreData, RoutingSection, ScheduleRule, TgBotConfig,
    TrafficCondition, unix_now_secs,
};
use crate::sys_info;
use crate::tg_bot;
use crate::transaction;

const MAX_REQ_BYTES: usize = 512 * 1024;
const SESSION_TTL_SECS: i64 = 86400;
const UI_HTML: &str = include_str!("ui.html");

pub async fn run_server(state: Arc<AppState>, core: Arc<CoreManager>) -> anyhow::Result<()> {
    let (addr, base_path) = {
        let d = state.data.read().await;
        (
            format!("{}:{}", d.settings.listen_addr, d.settings.listen_port),
            d.settings.web_base_path.clone(),
        )
    };
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
        return send_empty_cors(&mut stream).await;
    }

    // Normalize `/cgi-bin/tachyon-agent/*` alias to `/api/agent/v1/*`
    let path = if let Some(rest) = raw_path.strip_prefix("/cgi-bin/tachyon-agent") {
        format!("/api/agent/v1{rest}")
    } else {
        raw_path
    };

    // Serve SPA UI
    if method == "GET" && (path == "/" || path == "/index.html") {
        let dynamic_ui = std::fs::read_to_string("src/ui.html").ok();
        return send_html(&mut stream, dynamic_ui.as_deref().unwrap_or(UI_HTML)).await;
    }

    // Public Router Subscription Endpoint (`/sub/:token`)
    if method == "GET"
        && let Some(sub_tok) = path.strip_prefix("/sub/")
    {
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
        let fmt = if query.contains("format=raw") || query.contains("format=plain") {
            "plain"
        } else {
            &d.settings.server_subscription_format
        };
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
        ("GET", "/api/core/connections") | ("GET", "/api/diagnostics/connections") => {
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
        ("POST", "/api/telegram/save") => {
            let Ok(tg) = serde_json::from_slice::<TgBotConfig>(body) else {
                return send_json(stream, 400, &json!({"error": "invalid telegram config"})).await;
            };
            let mut candidate = state.data.read().await.clone();
            candidate.telegram = tg;
            match transaction::commit_transaction(state, candidate).await {
                Ok(plan) => send_json(stream, 200, &json!({"ok": true, "plan": plan})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("POST", "/api/telegram/test") => match tg_bot::send_test_notification(state).await {
            Ok(sent) => send_json(stream, 200, &json!({"ok": true, "sent": sent})).await,
            Err(e) => send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await,
        },
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
            let d = state.data.read().await;
            let res = diagnostics::explain_route(&d, client_ip, target, port, proto);
            send_json(stream, 200, &json!(res)).await
        }
        ("POST", "/api/diagnostics/dns-speed-test") | ("POST", "/api/diagnostics/dns-bench") => {
            let res = diagnostics::run_dns_speed_test().await;
            let best = res
                .first()
                .map(|r| r.server.as_str())
                .unwrap_or("Cloudflare");
            send_json(stream, 200, &json!({"recommended": best, "results": res})).await
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
            let res = diagnostics::run_leak_check(state).await;
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
        ("POST", "/api/diagnostics/known-good/promote") => {
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
        ("POST", "/api/diagnostics/known-good/rollback") => {
            match diagnostics::apply_quick_fix(state, core, "rollback_known_good").await {
                Ok(msg) => send_json(stream, 200, &json!({"ok": true, "message": msg})).await,
                Err(e) => {
                    send_json(stream, 400, &json!({"ok": false, "error": e.to_string()})).await
                }
            }
        }
        ("GET", "/api/updates/check") => {
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
            let d = state.data.read().await.clone();
            send_json(stream, 200, &json!(d)).await
        }
        ("POST", "/api/restore") => {
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

    let (expected_user, pass_hash, pass_salt) = {
        let d = state.data.read().await;
        (
            d.settings.admin_user.clone(),
            d.settings.admin_pass_hash.clone(),
            d.settings.admin_pass_salt.clone(),
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
        sessions.insert(token.clone(), now + SESSION_TTL_SECS);
    }

    let body_bytes = serde_json::to_vec(&json!({"ok": true, "token": token}))?;
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nSet-Cookie: tachyon_session={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL_SECS}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
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

async fn send_empty_cors(stream: &mut TcpStream) -> anyhow::Result<()> {
    let head = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    stream.write_all(head.as_bytes()).await?;
    Ok(())
}
