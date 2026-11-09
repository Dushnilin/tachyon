//! Model Context Protocol (MCP) JSON-RPC 2.0 server (`/mcp` HTTP and `tachyon mcp` stdio).
//!
//! Exposes redacted router diagnostics, `route_explain`, `config_plan`, and quick fixes to LLM agents.

use std::io::{BufRead, Write};
use std::sync::Arc;

use serde_json::{Value, json};

use crate::core_mgr::CoreManager;
use crate::diagnostics;
use crate::store::AppState;
use crate::transaction;

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
                    "version": "2.0.0"
                },
                "capabilities": {
                    "tools": {}
                }
            }
        }),
        "tools/list" => json!({
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
                        "description": "Run an automated quick-fix action by ID",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "fix_id": { "type": "string" }
                            },
                            "required": ["fix_id"]
                        }
                    }
                ]
            }
        }),
        "tools/call" => {
            let tool_name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let output = match tool_name {
                "get_status" => diagnostics::build_support_bundle(state).await,
                "route_explain" => {
                    let d = state.data.read().await;
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
                    match diagnostics::apply_quick_fix(state, core, fix_id).await {
                        Ok(msg) => json!({ "ok": true, "message": msg }),
                        Err(e) => json!({ "ok": false, "error": e.to_string() }),
                    }
                }
                _ => json!({ "error": format!("Unknown tool: {tool_name}") }),
            };
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "content": [{
                        "type": "text",
                        "text": serde_json::to_string_pretty(&output).unwrap_or_default()
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
