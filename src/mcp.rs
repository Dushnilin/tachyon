//! Model Context Protocol (MCP) JSON-RPC 2.0 server (`/mcp` HTTP and `tachyon mcp` stdio).
//!
//! Exposes redacted router diagnostics, `route_explain`, `config_plan`, and quick fixes to LLM agents.

use std::io::{BufRead, Write};
use std::sync::Arc;

use serde_json::{Value, json};

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::diagnostics;
use crate::store::AppState;
use crate::transaction;
use crate::watchdog;

#[inline(never)]
fn mcp_tools_list_response(id: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "tools": [
                {
                    "name": "get_status",
                    "description": "Get redacted system, core, and doctor status",
                    "inputSchema": { "type": "object", "properties": {} }
                },
                {
                    "name": "route_explain",
                    "description": "Simulate packet routing across active sections and conditions",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "client_ip": { "type": "string" },
                            "target": { "type": "string" },
                            "port": { "type": "integer" },
                            "protocol": { "type": "string" }
                        },
                        "required": ["target"]
                    }
                },
                {
                    "name": "config_plan",
                    "description": "Validate current configuration and check for collisions",
                    "inputSchema": { "type": "object", "properties": {} }
                },
                {
                    "name": "apply_quick_fix",
                    "description": "Run an automated quick-fix action by ID with before/after verification or dry-run preview",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "fix_id": { "type": "string" },
                            "dry_run": { "type": "boolean" },
                            "force": { "type": "boolean" }
                        },
                        "required": ["fix_id"]
                    }
                },
                {
                    "name": "get_core_health",
                    "description": "Get live tachyon-core telemetry: memory, FDs, UDP NAT, FakeIP pool, DNS servers, and per-outbound DialErrorClass health",
                    "inputSchema": { "type": "object", "properties": {} }
                },
                {
                    "name": "get_anomalies",
                    "description": "Get domains experiencing repeated connection failures in the last 5 minutes",
                    "inputSchema": { "type": "object", "properties": {} }
                },
                {
                    "name": "get_flight_failures",
                    "description": "Get recent failed or zero-transfer sessions from Flight Recorder with error_kind and dial_ms",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "outbound": { "type": "string" },
                            "limit": { "type": "integer" }
                        }
                    }
                },
                {
                    "name": "get_core_logs",
                    "description": "Get recent structured tachyon-core logs filtered by severity level",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "level": { "type": "string" },
                            "limit": { "type": "integer" }
                        }
                    }
                },
                {
                    "name": "capture_blackbox",
                    "description": "Capture an anonymized diagnostic Blackbox snapshot to tmpfs (no NAND flash wear)",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "reason": { "type": "string" }
                        }
                    }
                },
                {
                    "name": "flush_dns",
                    "description": "Flush tachyon-core DNS response cache and/or upstream address resolution cache",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "scope": { "type": "string", "enum": ["cache", "upstream", "all"] }
                        }
                    }
                },
                {
                    "name": "reset_outbound",
                    "description": "Reset/rebind an outbound (e.g. WireGuard rebind / Urltest probe) and optionally close stalled sessions",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "tag": { "type": "string" },
                            "close_sessions": { "type": "boolean" },
                            "stalled_only_ms": { "type": "integer" }
                        },
                        "required": ["tag"]
                    }
                }
            ]
        }
    })
}

#[inline(never)]
fn mcp_build_support_bundle(
    state: &Arc<AppState>,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Value> + Send + '_>> {
    Box::pin(diagnostics::build_support_bundle(state))
}

#[inline(never)]
fn mcp_apply_quick_fix<'a>(
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    fix_id: &'a str,
    dry_run: bool,
    force: bool,
) -> std::pin::Pin<
    Box<
        dyn std::future::Future<Output = anyhow::Result<diagnostics::VerifiedFixResult>>
            + Send
            + 'a,
    >,
> {
    Box::pin(diagnostics::apply_quick_fix_verified(
        state, core, fix_id, dry_run, force,
    ))
}

#[inline(never)]
fn mcp_capture_blackbox<'a>(
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

pub async fn handle_mcp_rpc(state: &Arc<AppState>, core: &Arc<CoreManager>, req: &Value) -> Value {
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    let method = req.get("method").and_then(Value::as_str).unwrap_or("");
    let params = req.get("params").cloned().unwrap_or_else(|| json!({}));

    match method {
        "initialize" => json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "protocolVersion": "2024-11-05",
                "serverInfo": {
                    "name": "tachyon-mcp",
                    "version": crate::store::TACHYON_VERSION
                },
                "capabilities": {
                    "tools": {}
                }
            }
        }),
        "tools/list" => mcp_tools_list_response(id),
        "tools/call" => {
            let tool_name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let output = match tool_name {
                "get_status" => mcp_build_support_bundle(state).await,
                "route_explain" => {
                    let d = Box::new(state.data.read().await.clone());
                    let client_ip = args
                        .get("client_ip")
                        .and_then(Value::as_str)
                        .unwrap_or("192.168.1.100");
                    let target = args
                        .get("target")
                        .and_then(Value::as_str)
                        .unwrap_or("youtube.com");
                    let port = args.get("port").and_then(Value::as_u64).unwrap_or(443) as u16;
                    let proto = args
                        .get("protocol")
                        .and_then(Value::as_str)
                        .unwrap_or("tcp");
                    json!(diagnostics::explain_route(
                        &d, client_ip, target, port, proto
                    ))
                }
                "config_plan" => {
                    let d = state.data.read().await;
                    json!(transaction::analyze_config_plan(&d))
                }
                "apply_quick_fix" => {
                    let fix_id = args.get("fix_id").and_then(Value::as_str).unwrap_or("");
                    let dry_run = args
                        .get("dry_run")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let force = args.get("force").and_then(Value::as_bool).unwrap_or(false);
                    match mcp_apply_quick_fix(state, core, fix_id, dry_run, force).await {
                        Ok(res) => json!(res),
                        Err(e) => json!({ "ok": false, "error": e.to_string() }),
                    }
                }
                "get_core_health" => core
                    .get_core_health()
                    .await
                    .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() })),
                "get_anomalies" => core
                    .get_core_anomalies()
                    .await
                    .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() })),
                "get_flight_failures" => {
                    let outbound = args.get("outbound").and_then(Value::as_str);
                    let limit = args
                        .get("limit")
                        .and_then(Value::as_u64)
                        .unwrap_or(20)
                        .clamp(1, 100) as usize;
                    core.get_core_flight_filtered(true, outbound, limit)
                        .await
                        .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() }))
                }
                "get_core_logs" => {
                    let level = args.get("level").and_then(Value::as_str).unwrap_or("warn");
                    let limit = args
                        .get("limit")
                        .and_then(Value::as_u64)
                        .unwrap_or(50)
                        .clamp(1, 256) as usize;
                    core.get_core_recent_logs(level, limit)
                        .await
                        .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() }))
                }
                "capture_blackbox" => {
                    let reason = args
                        .get("reason")
                        .and_then(Value::as_str)
                        .unwrap_or("manual");
                    match mcp_capture_blackbox(state, core, reason).await {
                        Ok(summary) => json!({ "ok": true, "blackbox": summary }),
                        Err(e) => json!({ "ok": false, "error": e.to_string() }),
                    }
                }
                "flush_dns" => {
                    let scope = args.get("scope").and_then(Value::as_str).unwrap_or("all");
                    core.flush_core_dns(scope)
                        .await
                        .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() }))
                }
                "reset_outbound" => {
                    let tag = args.get("tag").and_then(Value::as_str).unwrap_or("");
                    let close_sessions = args
                        .get("close_sessions")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    let stalled_only_ms = args.get("stalled_only_ms").and_then(Value::as_u64);
                    core.reset_core_outbound(tag, close_sessions, stalled_only_ms)
                        .await
                        .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() }))
                }
                _ => json!({ "error": format!("Unknown tool: {tool_name}") }),
            };
            let redacted = crypto_gen::redact_json_value(&output);
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "content": [{
                        "type": "text",
                        "text": serde_json::to_string_pretty(&redacted).unwrap_or_default()
                    }]
                }
            })
        }
        _ => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {
                "code": -32601,
                "message": format!("Method not found: {method}")
            }
        }),
    }
}

/// Run MCP server over stdin/stdout (`tachyon mcp`).
pub async fn run_stdio_mcp(state: Arc<AppState>, core: Arc<CoreManager>) -> anyhow::Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else {
            break;
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Ok(req) = serde_json::from_str::<Value>(trimmed) {
            let resp = handle_mcp_rpc(&state, &core, &req).await;
            let mut out = serde_json::to_vec(&resp)?;
            out.push(b'\n');
            stdout.write_all(&out)?;
            stdout.flush()?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_mcp_tools_list_and_verified_dry_run_call() {
        let dir = std::env::temp_dir().join(format!("tachyon-mcp-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = AppState::load_or_create(dir.join("tachyon.json")).unwrap();
        let core = CoreManager::new(Arc::clone(&state));

        let list_resp = handle_mcp_rpc(
            &state,
            &core,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
        )
        .await;
        let tools = list_resp["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 11);
        for required in [
            "get_core_health",
            "get_anomalies",
            "get_flight_failures",
            "get_core_logs",
            "capture_blackbox",
            "flush_dns",
            "reset_outbound",
        ] {
            assert!(
                tools.iter().any(|t| t["name"] == required),
                "missing tool {required}"
            );
        }

        let fix_resp = handle_mcp_rpc(
            &state,
            &core,
            &json!({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {
                    "name": "apply_quick_fix",
                    "arguments": { "fix_id": "trim_core_memory", "dry_run": true }
                }
            }),
        )
        .await;
        let text = fix_resp["result"]["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(parsed["ok"], true);
        assert_eq!(parsed["dry_run"], true);
        assert_eq!(parsed["risk_tier"], "safe");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
