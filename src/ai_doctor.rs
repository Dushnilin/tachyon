//! AI Doctor v4: Multi-provider async LLM diagnostics agent with 8 read-only tools,
//! RAII `curl -K` secret isolation (no API keys in `argv`), secret redaction,
//! tool-calling + single-shot + local fallbacks, and backend-enforced remediation risk tiers.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::process::Command;

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::diagnostics::{self, DoctorReport};
use crate::store::{AppState, RouterStoreData};
use crate::sys_info;
use crate::transaction;

const MAX_TOOL_STEPS: usize = 4;

struct TempFileGuard {
    path: PathBuf,
}

impl TempFileGuard {
    fn new(prefix: &str, ext: &str) -> Self {
        let name = format!(
            "{prefix}-{}-{}.{ext}",
            std::process::id(),
            crypto_gen::generate_hex(4)
        );
        Self {
            path: std::env::temp_dir().join(name),
        }
    }

    fn write_bytes(&self, bytes: &[u8], restrict_perms: bool) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&self.path, bytes)?;
        if restrict_perms {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ =
                    std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o600));
            }
        }
        Ok(())
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ProviderKind {
    OpenAiCompat,
    Anthropic,
    Gemini,
}

struct ProviderTarget {
    kind: ProviderKind,
    provider_name: String,
    model: String,
    url: String,
    api_key: String,
    key_required: bool,
}

fn is_loopback_url(url: &str) -> bool {
    url.starts_with("http://127.0.0.1")
        || url.starts_with("http://localhost")
        || url.starts_with("http://[::1]")
}

fn resolve_provider_target(d: &RouterStoreData, endpoint_override: Option<&str>) -> ProviderTarget {
    let raw_provider = d.settings.ai_doctor_provider.trim().to_ascii_lowercase();
    let provider = if raw_provider.is_empty() {
        "deepseek".to_string()
    } else {
        raw_provider
    };
    let configured_model = d.settings.ai_doctor_model.trim();
    let model = if !configured_model.is_empty() {
        configured_model.to_string()
    } else {
        match provider.as_str() {
            "openai" => "gpt-4o-mini".to_string(),
            "anthropic" => "claude-3-5-sonnet-latest".to_string(),
            "gemini" => "gemini-2.0-flash".to_string(),
            "openrouter" => "deepseek/deepseek-chat-v3-0324".to_string(),
            "ollama" => "qwen2.5:7b".to_string(),
            _ => "deepseek-chat".to_string(),
        }
    };

    let custom_url = d.settings.ai_doctor_custom_url.trim();
    let kind = match provider.as_str() {
        "anthropic" => ProviderKind::Anthropic,
        "gemini" => ProviderKind::Gemini,
        _ => ProviderKind::OpenAiCompat,
    };

    let url = if let Some(ov) = endpoint_override.filter(|s| !s.is_empty()) {
        ov.to_string()
    } else if !custom_url.is_empty() {
        if kind == ProviderKind::OpenAiCompat
            && !custom_url.ends_with("/chat/completions")
            && !custom_url.ends_with("/completions")
        {
            format!("{}/chat/completions", custom_url.trim_end_matches('/'))
        } else {
            custom_url.to_string()
        }
    } else {
        match provider.as_str() {
            "openai" => "https://api.openai.com/v1/chat/completions".to_string(),
            "openrouter" => "https://openrouter.ai/api/v1/chat/completions".to_string(),
            "ollama" => "http://127.0.0.1:11434/v1/chat/completions".to_string(),
            "anthropic" => "https://api.anthropic.com/v1/messages".to_string(),
            "gemini" => format!(
                "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            ),
            _ => "https://api.deepseek.com/v1/chat/completions".to_string(),
        }
    };

    let key_required = provider != "ollama" && !is_loopback_url(&url);
    ProviderTarget {
        kind,
        provider_name: provider,
        model,
        url,
        api_key: d.settings.ai_doctor_api_key.trim().to_string(),
        key_required,
    }
}

fn quote_curl_cfg_val(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len() + 2);
    out.push('"');
    for ch in raw.chars() {
        if ch == '\r' || ch == '\n' {
            continue;
        }
        if ch == '\\' || ch == '"' {
            out.push('\\');
        }
        out.push(ch);
    }
    out.push('"');
    out
}

async fn post_json_via_curl(
    url: &str,
    headers: &[(String, String)],
    payload: &Value,
) -> anyhow::Result<(u16, String)> {
    let payload_guard = TempFileGuard::new("tachyon-ai-payload", "json");
    let payload_bytes = serde_json::to_vec(payload)?;
    payload_guard.write_bytes(&payload_bytes, false)?;

    let cfg_guard = TempFileGuard::new("tachyon-ai-curlcfg", "cfg");
    let mut cfg_lines = String::new();
    for (k, v) in headers {
        let header_line = format!("{k}: {v}");
        cfg_lines.push_str("header = ");
        cfg_lines.push_str(&quote_curl_cfg_val(&header_line));
        cfg_lines.push('\n');
    }
    cfg_guard.write_bytes(cfg_lines.as_bytes(), true)?;

    let payload_arg = format!("@{}", payload_guard.path().display());
    let output = tokio::time::timeout(
        Duration::from_secs(35),
        Command::new("curl")
            .args([
                "-sS",
                "--max-time",
                "30",
                "-X",
                "POST",
                "-K",
                &cfg_guard.path().to_string_lossy(),
                "-H",
                "Content-Type: application/json",
                "--data-binary",
                &payload_arg,
                "-w",
                "\n%{http_code}",
                url,
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("Таймаут ожидания ответа от LLM-провайдера (35 с)"))??;

    if !output.status.success() && output.stdout.is_empty() {
        let err_txt = crypto_gen::redact_string(&String::from_utf8_lossy(&output.stderr));
        anyhow::bail!("Ошибка curl при обращении к LLM: {}", err_txt.trim());
    }

    let raw_out = String::from_utf8_lossy(&output.stdout);
    let (body_part, code_part) = raw_out.rsplit_once('\n').unwrap_or(("", &raw_out));
    let status: u16 = code_part.trim().parse().unwrap_or(0);
    if status == 0 {
        let err_txt = crypto_gen::redact_string(&String::from_utf8_lossy(&output.stderr));
        anyhow::bail!("Не удалось получить HTTP-статус LLM: {}", err_txt.trim());
    }
    Ok((status, body_part.to_string()))
}

fn build_auth_headers(target: &ProviderTarget) -> Vec<(String, String)> {
    let mut headers = Vec::new();
    match target.kind {
        ProviderKind::OpenAiCompat => {
            if !target.api_key.is_empty() {
                headers.push((
                    "Authorization".to_string(),
                    format!("Bearer {}", target.api_key),
                ));
            }
        }
        ProviderKind::Anthropic => {
            if !target.api_key.is_empty() {
                headers.push(("x-api-key".to_string(), target.api_key.clone()));
            }
            headers.push(("anthropic-version".to_string(), "2023-06-01".to_string()));
        }
        ProviderKind::Gemini => {
            if !target.api_key.is_empty() {
                headers.push(("x-goog-api-key".to_string(), target.api_key.clone()));
            }
        }
    }
    headers
}

fn tool_definitions_openai() -> Vec<Value> {
    vec![
        json!({
            "type": "function",
            "function": {
                "name": "get_core_health",
                "description": "Получить телеметрию ядра tachyon-core: память, FD, UDP NAT, FakeIP, DNS-серверы и метрики подключений по outbound.",
                "parameters": { "type": "object", "properties": {} }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "get_flight_failures",
                "description": "Получить последние неудавшиеся или оборванные сессии из Flight Recorder (error_kind, error_detail, dial_ms).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "outbound": { "type": "string", "description": "Фильтр по тегу outbound" },
                        "limit": { "type": "integer", "description": "Максимум записей (до 30)" }
                    }
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "get_anomalies",
                "description": "Получить домены с аномальной долей отказов за последние 5 минут.",
                "parameters": { "type": "object", "properties": {} }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "get_recent_logs",
                "description": "Получить последние структурированные логи ядра уровня warn/error/info.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "level": { "type": "string", "description": "Минимальный уровень: warn, error, info, debug" },
                        "limit": { "type": "integer", "description": "Количество строк (до 80)" }
                    }
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "explain_route",
                "description": "Проверить трассировку маршрута и секции для указанного домена или IP.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "target": { "type": "string" },
                        "client_ip": { "type": "string" },
                        "port": { "type": "integer" },
                        "protocol": { "type": "string" }
                    },
                    "required": ["target"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "search_kb",
                "description": "Поиск по встроенной инженерной базе знаний Tachyon 2.0.",
                "parameters": {
                    "type": "object",
                    "properties": { "query": { "type": "string" } },
                    "required": ["query"]
                }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "get_config_diff",
                "description": "Проверить расхождение desired/applied config_digest (config_drift) и валидацию плана.",
                "parameters": { "type": "object", "properties": {} }
            }
        }),
        json!({
            "type": "function",
            "function": {
                "name": "get_recent_incidents",
                "description": "Посмотреть историю недавних исправлений и откатов из памяти инцидентов (tmpfs).",
                "parameters": { "type": "object", "properties": {} }
            }
        }),
    ]
}

async fn execute_readonly_tool(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    name: &str,
    args: &Value,
) -> (Value, String) {
    let raw = match name {
        "get_core_health" => match core.get_core_health().await {
            Ok(v) => v,
            Err(e) => {
                let live = state.live.read().await.clone();
                json!({
                    "error": e.to_string(),
                    "core_running": live.core_running,
                    "wan_healthy": live.wan_healthy,
                    "dns_healthy": live.dns_healthy,
                    "outbound_health": live.outbound_health,
                })
            }
        },
        "get_flight_failures" => {
            let outbound = args
                .get("outbound")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let limit = args
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(15)
                .clamp(1, 30) as usize;
            core.get_core_flight_filtered(true, outbound, limit)
                .await
                .unwrap_or_else(|e| json!({ "error": e.to_string(), "entries": [] }))
        }
        "get_anomalies" => core
            .get_core_anomalies()
            .await
            .unwrap_or_else(|e| json!({ "error": e.to_string(), "hosts": [] })),
        "get_recent_logs" => {
            let level = args.get("level").and_then(Value::as_str).unwrap_or("warn");
            let limit = args
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(40)
                .clamp(1, 80) as usize;
            core.get_core_recent_logs(level, limit)
                .await
                .unwrap_or_else(|e| json!({ "error": e.to_string(), "entries": [] }))
        }
        "explain_route" => {
            let d = Box::new(state.data.read().await.clone());
            let target = args
                .get("target")
                .and_then(Value::as_str)
                .unwrap_or("www.youtube.com");
            let client_ip = args
                .get("client_ip")
                .and_then(Value::as_str)
                .unwrap_or("192.168.1.100");
            let port = args.get("port").and_then(Value::as_u64).unwrap_or(443) as u16;
            let proto = args
                .get("protocol")
                .and_then(Value::as_str)
                .unwrap_or("tcp");
            Box::pin(diagnostics::explain_route_with_engine(
                core, &d, client_ip, target, port, proto,
            ))
            .await
        }
        "search_kb" => {
            let q = args.get("query").and_then(Value::as_str).unwrap_or("");
            json!({ "hits": diagnostics::search_knowledge_docs(q) })
        }
        "get_config_diff" => {
            let (plan_valid, plan_errors, plan_warnings) = {
                let d = state.data.read().await;
                let plan = transaction::analyze_config_plan(&d);
                (plan.valid, plan.errors, plan.warnings)
            };
            let live = state.live.read().await.clone();
            json!({
                "config_drift": live.config_drift,
                "desired_digest": live.desired_config_digest,
                "applied_digest": live.applied_config_digest,
                "plan_valid": plan_valid,
                "plan_errors": plan_errors,
                "plan_warnings": plan_warnings,
            })
        }
        "get_recent_incidents" => {
            let list = diagnostics::load_incidents();
            let tail: Vec<_> = list.into_iter().rev().take(10).collect();
            json!({ "count": tail.len(), "incidents": tail })
        }
        other => json!({ "error": format!("Неизвестный инструмент read-only: {other}") }),
    };

    let redacted = crypto_gen::redact_json_value(&raw);
    let summary = match name {
        "get_core_health" => format!(
            "outbounds: {}, dns_servers: {}",
            redacted
                .get("outbounds")
                .and_then(Value::as_array)
                .map_or(0, Vec::len),
            redacted
                .pointer("/dns/servers")
                .and_then(Value::as_array)
                .map_or(0, Vec::len)
        ),
        "get_flight_failures" | "get_recent_logs" => format!(
            "entries: {}",
            redacted
                .get("entries")
                .and_then(Value::as_array)
                .map_or(0, Vec::len)
        ),
        "get_anomalies" => format!(
            "hosts: {}",
            redacted
                .get("hosts")
                .and_then(Value::as_array)
                .map_or(0, Vec::len)
        ),
        "search_kb" => format!(
            "hits: {}",
            redacted
                .get("hits")
                .and_then(Value::as_array)
                .map_or(0, Vec::len)
        ),
        "get_config_diff" => format!(
            "drift: {}",
            redacted
                .get("config_drift")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        ),
        "get_recent_incidents" => format!(
            "incidents: {}",
            redacted.get("count").and_then(Value::as_u64).unwrap_or(0)
        ),
        _ => "ok".to_string(),
    };
    (redacted, summary)
}

fn system_prompt_ru() -> &'static str {
    "Ты инженерный AI Doctor для роутерного оркестратора Tachyon 2.0 и ядра tachyon-core.\n\
Используй ТОЛЬКО нейтральную сетевую терминологию (промежуточные/транзитные узлы, десинхронизация пакетов, фильтрация на маршруте). Никогда не упоминай названия регуляторов и не используй эмодзи.\n\
У тебя есть read-only инструменты для проверки состояния ядра, Flight Recorder, аномалий, логов, маршрутов и конфигурации. Сначала определи первопричину по графу зависимостей (WAN -> Время -> Бинарник -> Ядро -> Конфиг -> nftables -> DNS -> Узлы -> Ресурсы), затем предложи план исправления.\n\
Верни строго JSON-объект следующей структуры (без лишнего текста вне JSON, можно внутри ```json):\n\
{\n\
  \"root_cause\": \"краткая техническая формулировка первопричины\",\n\
  \"confidence\": 0.85,\n\
  \"analysis\": \"подробное инженерное объяснение в Markdown\",\n\
  \"remediation_plan\": [\n\
    {\n\
      \"fix_id\": \"идентификатор из разрешённого списка\",\n\
      \"label\": \"краткое название действия\",\n\
      \"reason\": \"почему это поможет\",\n\
      \"risk_tier\": \"safe\"\n\
    }\n\
  ]\n\
}\n\
Доступные fix_id: trim_core_memory, flush_core_dns, clear_dns_cache, capture_blackbox, restore_primary_failover, hot_reload_core, restart_core, reset_outbound_pool, reset_outbound_pool:<tag>, reconcile_nftables, fix_dnsmasq, fix_wan_interface, switch_to_doh, fix_bootstrap_dns, optimize_mtu, fix_system_time, disable_flow_offloading, rollback_core_binary, rollback_known_good, update_subscriptions."
}

fn extract_json_object_from_text(text: &str) -> Option<Value> {
    let trimmed = text.trim();
    if let Ok(v) = serde_json::from_str::<Value>(trimmed)
        && v.is_object()
    {
        return Some(v);
    }
    if let Some(start) = trimmed.find("```json") {
        let after = &trimmed[start + 7..];
        if let Some(end) = after.find("```")
            && let Ok(v) = serde_json::from_str::<Value>(after[..end].trim())
            && v.is_object()
        {
            return Some(v);
        }
    }
    if let Some(start) = trimmed.find("```") {
        let after = &trimmed[start + 3..];
        if let Some(end) = after.find("```")
            && let Ok(v) = serde_json::from_str::<Value>(after[..end].trim())
            && v.is_object()
        {
            return Some(v);
        }
    }
    if let (Some(l), Some(r)) = (trimmed.find('{'), trimmed.rfind('}'))
        && r > l
        && let Ok(v) = serde_json::from_str::<Value>(&trimmed[l..=r])
        && v.is_object()
    {
        return Some(v);
    }
    None
}

fn validate_remediation_steps(raw_steps: Option<&Vec<Value>>) -> Vec<Value> {
    let mut validated = Vec::new();
    let Some(items) = raw_steps else {
        return validated;
    };
    for step in items.iter().take(8) {
        let fix_id = step
            .get("fix_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if fix_id.is_empty() {
            continue;
        }
        let known = diagnostics::is_known_quick_fix(fix_id);
        let enforced_risk = if known {
            diagnostics::quick_fix_risk_tier(fix_id)
        } else {
            "advisory"
        };
        let label = step
            .get("label")
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(fix_id);
        let reason = step
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        validated.push(json!({
            "fix_id": fix_id,
            "label": label,
            "reason": reason,
            "risk_tier": enforced_risk,
            "advisory_only": !known,
        }));
    }
    validated
}

fn fallback_plan_from_report(report: &DoctorReport) -> (String, Vec<Value>) {
    let root_cause = report.root_causes.first().cloned().unwrap_or_else(|| {
        if report.healthy {
            "Критических аномалий не выявлено".to_string()
        } else {
            report.summary.clone()
        }
    });
    let mut steps = Vec::new();
    for f in report.findings.iter().filter(|f| f.suppressed_by.is_none()) {
        let risk = diagnostics::quick_fix_risk_tier(&f.quick_fix_id);
        steps.push(json!({
            "fix_id": f.quick_fix_id,
            "label": f.quick_fix_label,
            "reason": f.title,
            "risk_tier": risk,
            "advisory_only": !diagnostics::is_known_quick_fix(&f.quick_fix_id),
        }));
    }
    if steps.is_empty() {
        steps.push(json!({
            "fix_id": "trim_core_memory",
            "label": "Сжать буферы памяти",
            "reason": "Профилактическое освобождение буферов и кэшей",
            "risk_tier": "safe",
            "advisory_only": false,
        }));
        steps.push(json!({
            "fix_id": "capture_blackbox",
            "label": "Снять контрольный дамп Blackbox",
            "reason": "Фиксация рабочего состояния в tmpfs",
            "risk_tier": "safe",
            "advisory_only": false,
        }));
    }
    (root_cause, steps)
}

async fn run_openai_compat_loop(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    target: &ProviderTarget,
    context_bundle: &Value,
    user_query: &str,
    tool_trace: &mut Vec<Value>,
) -> anyhow::Result<(String, &'static str)> {
    let auth_headers = build_auth_headers(target);
    let user_msg = format!(
        "Запрос: {}\n\nТекущий обезличенный диагностический контекст:\n{}",
        crypto_gen::redact_string(user_query),
        serde_json::to_string_pretty(context_bundle).unwrap_or_default()
    );

    let mut messages = vec![
        json!({ "role": "system", "content": system_prompt_ru() }),
        json!({ "role": "user", "content": user_msg }),
    ];
    let tools = tool_definitions_openai();

    for step in 0..MAX_TOOL_STEPS {
        let req_payload = json!({
            "model": target.model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "temperature": 0.1
        });
        let (status, resp_raw) =
            post_json_via_curl(&target.url, &auth_headers, &req_payload).await?;
        if status >= 400 {
            if step == 0 {
                // Provider or endpoint may reject `tools`: fall back cleanly to single-shot
                return run_openai_single_shot(target, &auth_headers, &messages[..2]).await;
            }
            anyhow::bail!(
                "HTTP {status} от LLM: {}",
                crypto_gen::redact_string(&resp_raw)
            );
        }

        let resp_json: Value = serde_json::from_str(&resp_raw)
            .map_err(|e| anyhow::anyhow!("Некорректный JSON от LLM: {e}"))?;
        let Some(choice_msg) = resp_json.pointer("/choices/0/message").cloned() else {
            anyhow::bail!("В ответе LLM отсутствует choices[0].message");
        };

        if let Some(tool_calls) = choice_msg.get("tool_calls").and_then(Value::as_array)
            && !tool_calls.is_empty()
        {
            messages.push(choice_msg.clone());
            for tc in tool_calls {
                let call_id = tc.get("id").and_then(Value::as_str).unwrap_or("call_0");
                let tool_name = tc
                    .pointer("/function/name")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let raw_args = tc
                    .pointer("/function/arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("{}");
                let parsed_args =
                    serde_json::from_str::<Value>(raw_args).unwrap_or_else(|_| json!({}));
                let t0 = Instant::now();
                let (result, summary) =
                    execute_readonly_tool(state, core, tool_name, &parsed_args).await;
                let dur_ms = u64::try_from(t0.elapsed().as_millis()).unwrap_or(0);
                tool_trace.push(json!({
                    "step": step + 1,
                    "tool": tool_name,
                    "arguments": crypto_gen::redact_json_value(&parsed_args),
                    "duration_ms": dur_ms,
                    "summary": summary,
                }));
                messages.push(json!({
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": serde_json::to_string(&result).unwrap_or_default(),
                }));
            }
            continue;
        }

        let content = choice_msg
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if content.trim().is_empty() {
            anyhow::bail!("LLM вернул пустой ответ");
        }
        return Ok((content, "llm_agent"));
    }

    // Final synthesis step without tools after exhausting tool steps
    let req_payload = json!({
        "model": target.model,
        "messages": messages,
        "temperature": 0.1
    });
    let (status, resp_raw) = post_json_via_curl(&target.url, &auth_headers, &req_payload).await?;
    if status >= 400 {
        anyhow::bail!("HTTP {status} на финальном шаге LLM");
    }
    let resp_json: Value = serde_json::from_str(&resp_raw)?;
    let content = resp_json
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Ok((content, "llm_agent"))
}

async fn run_openai_single_shot(
    target: &ProviderTarget,
    auth_headers: &[(String, String)],
    base_messages: &[Value],
) -> anyhow::Result<(String, &'static str)> {
    let req_payload = json!({
        "model": target.model,
        "messages": base_messages,
        "temperature": 0.1
    });
    let (status, resp_raw) = post_json_via_curl(&target.url, auth_headers, &req_payload).await?;
    if status >= 400 {
        anyhow::bail!(
            "HTTP {status} от LLM: {}",
            crypto_gen::redact_string(&resp_raw)
        );
    }
    let resp_json: Value = serde_json::from_str(&resp_raw)?;
    let content = resp_json
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    anyhow::ensure!(!content.trim().is_empty(), "Пустой single-shot ответ LLM");
    Ok((content, "llm_single_shot"))
}

async fn run_anthropic_loop(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    target: &ProviderTarget,
    context_bundle: &Value,
    user_query: &str,
    tool_trace: &mut Vec<Value>,
) -> anyhow::Result<(String, &'static str)> {
    let auth_headers = build_auth_headers(target);
    let user_msg = format!(
        "Запрос: {}\n\nТекущий обезличенный диагностический контекст:\n{}",
        crypto_gen::redact_string(user_query),
        serde_json::to_string_pretty(context_bundle).unwrap_or_default()
    );
    let mut messages = vec![json!({ "role": "user", "content": user_msg })];
    let tools: Vec<Value> = tool_definitions_openai()
        .into_iter()
        .map(|t| {
            json!({
                "name": t["function"]["name"],
                "description": t["function"]["description"],
                "input_schema": t["function"]["parameters"],
            })
        })
        .collect();

    for step in 0..MAX_TOOL_STEPS {
        let req_payload = json!({
            "model": target.model,
            "max_tokens": 1600,
            "system": system_prompt_ru(),
            "tools": tools,
            "messages": messages,
        });
        let (status, resp_raw) =
            post_json_via_curl(&target.url, &auth_headers, &req_payload).await?;
        if status >= 400 {
            if step == 0 {
                let ss = json!({
                    "model": target.model,
                    "max_tokens": 1600,
                    "system": system_prompt_ru(),
                    "messages": &messages[..1],
                });
                let (st2, raw2) = post_json_via_curl(&target.url, &auth_headers, &ss).await?;
                if st2 >= 400 {
                    anyhow::bail!("HTTP {st2} от Anthropic");
                }
                let v2: Value = serde_json::from_str(&raw2)?;
                let txt = v2["content"]
                    .as_array()
                    .and_then(|arr| {
                        arr.iter()
                            .find_map(|b| b.get("text").and_then(Value::as_str))
                    })
                    .unwrap_or("")
                    .to_string();
                return Ok((txt, "llm_single_shot"));
            }
            anyhow::bail!("HTTP {status} от Anthropic");
        }

        let v: Value = serde_json::from_str(&resp_raw)?;
        let content_blocks = v["content"].as_array().cloned().unwrap_or_default();
        let tool_uses: Vec<&Value> = content_blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_use"))
            .collect();

        if !tool_uses.is_empty() {
            messages.push(json!({ "role": "assistant", "content": content_blocks }));
            let mut results = Vec::new();
            for tu in tool_uses {
                let id = tu.get("id").and_then(Value::as_str).unwrap_or("tu_0");
                let name = tu.get("name").and_then(Value::as_str).unwrap_or("");
                let args = tu.get("input").cloned().unwrap_or_else(|| json!({}));
                let t0 = Instant::now();
                let (res, summary) = execute_readonly_tool(state, core, name, &args).await;
                let dur_ms = u64::try_from(t0.elapsed().as_millis()).unwrap_or(0);
                tool_trace.push(json!({
                    "step": step + 1,
                    "tool": name,
                    "arguments": crypto_gen::redact_json_value(&args),
                    "duration_ms": dur_ms,
                    "summary": summary,
                }));
                results.push(json!({
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": serde_json::to_string(&res).unwrap_or_default(),
                }));
            }
            messages.push(json!({ "role": "user", "content": results }));
            continue;
        }

        let text = content_blocks
            .iter()
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n");
        return Ok((text, "llm_agent"));
    }

    anyhow::bail!("Anthropic exceeded max tool steps without final text")
}

async fn run_gemini_loop(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    target: &ProviderTarget,
    context_bundle: &Value,
    user_query: &str,
    tool_trace: &mut Vec<Value>,
) -> anyhow::Result<(String, &'static str)> {
    let auth_headers = build_auth_headers(target);
    let user_msg = format!(
        "Запрос: {}\n\nТекущий обезличенный диагностический контекст:\n{}",
        crypto_gen::redact_string(user_query),
        serde_json::to_string_pretty(context_bundle).unwrap_or_default()
    );
    let mut contents = vec![json!({
        "role": "user",
        "parts": [{ "text": user_msg }]
    })];
    let decls: Vec<Value> = tool_definitions_openai()
        .into_iter()
        .map(|t| {
            json!({
                "name": t["function"]["name"],
                "description": t["function"]["description"],
                "parameters": t["function"]["parameters"],
            })
        })
        .collect();

    for step in 0..MAX_TOOL_STEPS {
        let payload = json!({
            "systemInstruction": { "parts": [{ "text": system_prompt_ru() }] },
            "tools": [{ "functionDeclarations": decls }],
            "contents": contents,
        });
        let (status, resp_raw) = post_json_via_curl(&target.url, &auth_headers, &payload).await?;
        if status >= 400 {
            if step == 0 {
                let ss = json!({
                    "systemInstruction": { "parts": [{ "text": system_prompt_ru() }] },
                    "contents": &contents[..1],
                });
                let (st2, raw2) = post_json_via_curl(&target.url, &auth_headers, &ss).await?;
                if st2 >= 400 {
                    anyhow::bail!("HTTP {st2} от Gemini");
                }
                let v2: Value = serde_json::from_str(&raw2)?;
                let txt = v2
                    .pointer("/candidates/0/content/parts/0/text")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                return Ok((txt, "llm_single_shot"));
            }
            anyhow::bail!("HTTP {status} от Gemini");
        }
        let v: Value = serde_json::from_str(&resp_raw)?;
        let parts = v
            .pointer("/candidates/0/content/parts")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let fn_calls: Vec<&Value> = parts
            .iter()
            .filter(|p| p.get("functionCall").is_some())
            .collect();
        if !fn_calls.is_empty() {
            contents.push(json!({ "role": "model", "parts": parts }));
            let mut fn_resps = Vec::new();
            for fc_part in fn_calls {
                let fc = &fc_part["functionCall"];
                let name = fc.get("name").and_then(Value::as_str).unwrap_or("");
                let args = fc.get("args").cloned().unwrap_or_else(|| json!({}));
                let t0 = Instant::now();
                let (res, summary) = execute_readonly_tool(state, core, name, &args).await;
                let dur_ms = u64::try_from(t0.elapsed().as_millis()).unwrap_or(0);
                tool_trace.push(json!({
                    "step": step + 1,
                    "tool": name,
                    "arguments": crypto_gen::redact_json_value(&args),
                    "duration_ms": dur_ms,
                    "summary": summary,
                }));
                fn_resps.push(json!({
                    "functionResponse": {
                        "name": name,
                        "response": res,
                    }
                }));
            }
            contents.push(json!({ "role": "user", "parts": fn_resps }));
            continue;
        }
        let text = parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n");
        return Ok((text, "llm_agent"));
    }

    anyhow::bail!("Gemini exceeded max tool steps without final text")
}

/// Public AI Doctor v4 entry point used by `/api/diagnostics/ai-doctor`.
pub async fn run_ai_doctor_v4(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    user_query: Option<&str>,
) -> Value {
    run_ai_doctor_v4_with_endpoint(state, core, user_query, None).await
}

/// Internal testable AI Doctor v4 entry point allowing custom HTTP endpoint override for mock tests.
pub async fn run_ai_doctor_v4_with_endpoint(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    user_query: Option<&str>,
    endpoint_override: Option<&str>,
) -> Value {
    let report = Box::pin(diagnostics::run_local_doctor_with_core(state, core)).await;
    let target = {
        let d = state.data.read().await;
        resolve_provider_target(&d, endpoint_override)
    };
    let live = Box::new(state.live.read().await.clone());
    let sys = sys_info::collect_host_info();
    let query_str = user_query
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("Проведи причинную диагностику маршрутизации, DNS и узлов роутера");

    let rag_hits = diagnostics::search_knowledge_docs(query_str);
    let incidents = diagnostics::load_incidents();
    let similar_incidents: Vec<Value> = incidents
        .iter()
        .rev()
        .take(5)
        .filter_map(|i| serde_json::to_value(i).ok())
        .collect();

    let redacted_context = crypto_gen::redact_json_value(&json!({
        "doctor_summary": report.summary,
        "healthy": report.healthy,
        "root_causes": report.root_causes,
        "pipeline_nodes": report.pipeline_nodes,
        "findings": report.findings,
        "telemetry": {
            "core_running": live.core_running,
            "core_rss_bytes": live.core_rss_bytes,
            "core_pressure_level": live.core_pressure_level,
            "core_fd_open": live.core_fd_open,
            "core_fd_limit": live.core_fd_limit,
            "wan_healthy": live.wan_healthy,
            "wan_probe_ms": live.wan_probe_ms,
            "dns_healthy": live.dns_healthy,
            "dns_probe_ms": live.dns_probe_ms,
            "fakeip_v4_used": live.fakeip_v4_used,
            "fakeip_v4_cap": live.fakeip_v4_cap,
            "fakeip_evictions": live.fakeip_evictions,
            "udp_nat_active": live.udp_nat_active,
            "udp_nat_evictions": live.udp_nat_evictions,
            "config_drift": live.config_drift,
            "outbound_health": live.outbound_health,
            "recent_flight_failures": live.recent_flight_failures,
            "anomalies_count": live.anomalies_count,
        },
        "rag_hits": rag_hits,
        "recent_incidents": similar_incidents,
    }));

    let mut tool_trace: Vec<Value> = Vec::new();
    let mut llm_error: Option<String> = None;
    let mut mode = "local_fallback";
    let mut root_cause = String::new();
    let mut confidence = 0.0f64;
    let mut analysis_text = String::new();
    let mut remediation_plan: Vec<Value> = Vec::new();

    if target.key_required && target.api_key.is_empty() {
        llm_error = Some(format!(
            "API-ключ для провайдера '{}' не задан; использован локальный инженерный анализ",
            target.provider_name
        ));
    } else {
        let llm_res = match target.kind {
            ProviderKind::OpenAiCompat => {
                Box::pin(run_openai_compat_loop(
                    state,
                    core,
                    &target,
                    &redacted_context,
                    query_str,
                    &mut tool_trace,
                ))
                .await
            }
            ProviderKind::Anthropic => {
                Box::pin(run_anthropic_loop(
                    state,
                    core,
                    &target,
                    &redacted_context,
                    query_str,
                    &mut tool_trace,
                ))
                .await
            }
            ProviderKind::Gemini => {
                Box::pin(run_gemini_loop(
                    state,
                    core,
                    &target,
                    &redacted_context,
                    query_str,
                    &mut tool_trace,
                ))
                .await
            }
        };

        match llm_res {
            Ok((raw_text, used_mode)) => {
                mode = used_mode;
                if let Some(parsed) = extract_json_object_from_text(&raw_text) {
                    root_cause = parsed
                        .get("root_cause")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    confidence = parsed
                        .get("confidence")
                        .and_then(Value::as_f64)
                        .unwrap_or(0.8)
                        .clamp(0.0, 1.0);
                    analysis_text = parsed
                        .get("analysis")
                        .and_then(Value::as_str)
                        .unwrap_or(&raw_text)
                        .to_string();
                    remediation_plan = validate_remediation_steps(
                        parsed.get("remediation_plan").and_then(Value::as_array),
                    );
                } else {
                    analysis_text = raw_text;
                }
            }
            Err(e) => {
                llm_error = Some(crypto_gen::redact_string(&e.to_string()));
            }
        }
    }

    if mode == "local_fallback" {
        let (rc, steps) = fallback_plan_from_report(&report);
        root_cause = rc;
        confidence = if report.findings.is_empty() {
            0.95
        } else {
            0.85
        };
        remediation_plan = steps;

        let mem_mb = live.core_rss_bytes as f64 / (1024.0 * 1024.0);
        let findings_md = if report.findings.is_empty() {
            "Критических сбоев не выявлено. Pipeline WAN -> Часы -> Бинарник -> Ядро -> Конфиг -> nftables -> DNS -> Узлы согласован.".to_string()
        } else {
            report
                .findings
                .iter()
                .map(|f| {
                    let prefix = if let Some(ref sup) = f.suppressed_by {
                        format!("[ПОДАВЛЕНО: {sup}]")
                    } else if f.root_cause {
                        "[ПЕРВОПРИЧИНА]".to_string()
                    } else {
                        format!("[{}]", f.severity.to_uppercase())
                    };
                    format!("- **{prefix}** {}: {}", f.title, f.detail)
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        analysis_text = format!(
            "### Инженерный отчёт AI Doctor (локальный режим)\n\n\
             - **Ядро `tachyon-core`**: {} (PID: {}, RSS: {:.2} МБ, давление: `{}`)\n\
             - **Канал WAN / DNS**: WAN={} ({} мс) · DNS={} ({} мс, FakeIP {}/{})\n\
             - **Первопричина**: {}\n\
             - **Запрос**: _{}_\n\n\
             #### Результаты анализа подсистем\n\
             {}\n",
            if live.core_running {
                "РАБОТАЕТ"
            } else {
                "ОСТАНОВЛЕНО"
            },
            live.core_pid
                .map(|p| p.to_string())
                .unwrap_or_else(|| "-".to_string()),
            mem_mb,
            if live.core_pressure_level.is_empty() {
                "normal"
            } else {
                &live.core_pressure_level
            },
            if live.wan_healthy { "OK" } else { "ERR" },
            live.wan_probe_ms,
            if live.dns_healthy { "OK" } else { "ERR" },
            live.dns_probe_ms,
            live.fakeip_v4_used,
            live.fakeip_v4_cap,
            root_cause,
            crypto_gen::redact_string(query_str),
            findings_md,
        );
    } else if root_cause.is_empty() || remediation_plan.is_empty() {
        let (rc, steps) = fallback_plan_from_report(&report);
        if root_cause.is_empty() {
            root_cause = rc;
        }
        if remediation_plan.is_empty() {
            remediation_plan = steps;
        }
    }

    let recommendations: Vec<Value> = remediation_plan
        .iter()
        .filter(|s| {
            !s.get("advisory_only")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .cloned()
        .collect();

    json!({
        "ok": true,
        "mode": mode,
        "provider": target.provider_name,
        "model": target.model,
        "healthy": report.healthy,
        "root_cause": root_cause,
        "confidence": confidence,
        "analysis": crypto_gen::redact_string(&analysis_text),
        "tool_trace": tool_trace,
        "remediation_plan": remediation_plan,
        "recommendations": recommendations,
        "similar_incidents": similar_incidents,
        "rag_docs": rag_hits,
        "llm_error": llm_error,
        "system": {
            "hostname": sys.router_model,
            "mem_available_bytes": sys.mem_total_bytes.saturating_sub(sys.mem_used_bytes),
            "mem_total_bytes": sys.mem_total_bytes
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn test_backend_enforces_risk_tier_over_llm_claim() {
        let raw_steps = vec![
            json!({
                "fix_id": "switch_to_doh",
                "label": "DoH",
                "reason": "ISP blocks UDP 53",
                "risk_tier": "safe" // LLM falsely tries to downgrade risk!
            }),
            json!({
                "fix_id": "invented_unknown_fix",
                "label": "Mystery",
                "reason": "Guess",
                "risk_tier": "safe"
            }),
        ];
        let validated = validate_remediation_steps(Some(&raw_steps));
        assert_eq!(validated.len(), 2);
        assert_eq!(validated[0]["risk_tier"], "config_change");
        assert_eq!(validated[0]["advisory_only"], false);
        assert_eq!(validated[1]["risk_tier"], "advisory");
        assert_eq!(validated[1]["advisory_only"], true);
    }

    #[tokio::test]
    async fn test_ai_doctor_v4_tool_calling_loop_and_redaction_against_mock_server() {
        let dir = std::env::temp_dir().join(format!("tachyon-ai-mock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = AppState::load_or_create(dir.join("tachyon.json")).unwrap();
        {
            let mut d = state.data.write().await;
            d.settings.ai_doctor_provider = "openai".to_string();
            d.settings.ai_doctor_model = "gpt-4o-mini".to_string();
            d.settings.ai_doctor_api_key = "sk-test-super-secret-token-123456".to_string();
            d.settings.clash_api_secret = "super_hash_secret_value".to_string();
        }
        let core = CoreManager::new(Arc::clone(&state));

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let captured_bodies = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let captured_clone = Arc::clone(&captured_bodies);

        let server_task = tokio::spawn(async move {
            for step in 0..2usize {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = Vec::new();
                let mut tmp = [0u8; 4096];
                let mut content_len = 0usize;
                let mut header_end = None;
                while let Ok(n) = stream.read(&mut tmp).await {
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..n]);
                    if header_end.is_none()
                        && let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n")
                    {
                        header_end = Some(pos + 4);
                        let hdr = String::from_utf8_lossy(&buf[..pos]);
                        for line in hdr.lines() {
                            if let Some((k, v)) = line.split_once(':')
                                && k.trim().eq_ignore_ascii_case("content-length")
                            {
                                content_len = v.trim().parse().unwrap_or(0);
                            }
                        }
                    }
                    if let Some(he) = header_end
                        && buf.len() >= he + content_len
                    {
                        break;
                    }
                }
                let raw_req = String::from_utf8_lossy(&buf).to_string();
                let body_only = raw_req
                    .split_once("\r\n\r\n")
                    .map(|(_, b)| b.to_string())
                    .unwrap_or_default();
                captured_clone.lock().unwrap().push(body_only);

                let resp_json = if step == 0 {
                    json!({
                        "choices": [{
                            "message": {
                                "role": "assistant",
                                "tool_calls": [{
                                    "id": "call_1",
                                    "type": "function",
                                    "function": {
                                        "name": "get_config_diff",
                                        "arguments": "{}"
                                    }
                                }]
                            }
                        }]
                    })
                } else {
                    json!({
                        "choices": [{
                            "message": {
                                "role": "assistant",
                                "content": serde_json::to_string(&json!({
                                    "root_cause": "DNS upstream timeouts detected",
                                    "confidence": 0.91,
                                    "analysis": "Switching DNS to DoH resolves upstream instability.",
                                    "remediation_plan": [{
                                        "fix_id": "switch_to_doh",
                                        "label": "Switch to DoH",
                                        "reason": "Avoid plain UDP 53 drops",
                                        "risk_tier": "safe"
                                    }]
                                })).unwrap()
                            }
                        }]
                    })
                };
                let body_str = resp_json.to_string();
                let http_resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body_str.len(),
                    body_str
                );
                let _ = stream.write_all(http_resp.as_bytes()).await;
            }
        });

        let endpoint = format!("http://{addr}/v1/chat/completions");
        let res = run_ai_doctor_v4_with_endpoint(
            &state,
            &core,
            Some("Check DNS timeout with key=my_inline_secret_xyz"),
            Some(&endpoint),
        )
        .await;

        assert_eq!(res["mode"], "llm_agent");
        assert_eq!(res["tool_trace"].as_array().unwrap().len(), 1);
        assert_eq!(res["tool_trace"][0]["tool"], "get_config_diff");
        assert_eq!(res["remediation_plan"][0]["fix_id"], "switch_to_doh");
        // Backend MUST enforce config_change even though mock LLM claimed "safe"
        assert_eq!(res["remediation_plan"][0]["risk_tier"], "config_change");

        let sent = captured_bodies.lock().unwrap().join("\n");
        assert!(!sent.contains("my_inline_secret_xyz"));
        assert!(!sent.contains("sk-test-super-secret-token-123456"));

        server_task.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_ai_doctor_v4_local_fallback_without_key_and_on_http_error() {
        let dir = std::env::temp_dir().join(format!("tachyon-ai-fb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = AppState::load_or_create(dir.join("tachyon.json")).unwrap();
        let core = CoreManager::new(Arc::clone(&state));

        let no_key = run_ai_doctor_v4_with_endpoint(&state, &core, Some("DNS check"), None).await;
        assert_eq!(no_key["mode"], "local_fallback");
        assert!(no_key["llm_error"].as_str().is_some());
        assert!(!no_key["remediation_plan"].as_array().unwrap().is_empty());

        {
            let mut d = state.data.write().await;
            d.settings.ai_doctor_api_key = "sk-test-fallback-key".to_string();
        }
        let err_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let err_addr = err_listener.local_addr().unwrap();
        let err_task = tokio::spawn(async move {
            while let Ok((mut s, _)) = err_listener.accept().await {
                let mut tmp = [0u8; 2048];
                let _ = s.read(&mut tmp).await;
                let _ = s
                    .write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 5\r\nConnection: close\r\n\r\nerror")
                    .await;
            }
        });

        let endpoint = format!("http://{err_addr}/v1/chat/completions");
        let on_err =
            run_ai_doctor_v4_with_endpoint(&state, &core, Some("DNS check"), Some(&endpoint)).await;
        assert_eq!(on_err["mode"], "local_fallback");
        assert!(on_err["llm_error"].as_str().is_some());

        err_task.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
