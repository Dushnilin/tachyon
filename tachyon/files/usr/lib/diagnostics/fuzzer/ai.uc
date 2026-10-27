#!/usr/bin/env ucode
//
// Fuzzer AI helpers: LLM queries and AI-synthesised strategies.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split).
//

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let uci_core = require("core.uci");
let rag = require("diagnostics.rag");
let history = require("diagnostics.fuzzer.history");
let strategies = require("diagnostics.fuzzer.strategies");
let probe = require("diagnostics.fuzzer.probe");
let binaries = require("diagnostics.fuzzer.binaries");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const STATE_DIR = history.STATE_DIR || getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";
const AI_JOB_FILE = STATE_DIR + "/fuzzer_ai_job.json";
const AI_JOB_PID = STATE_DIR + "/fuzzer_ai_job.pid";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let last_llm_error = "";

function strip_reasoning_tags(text) {
    text = trim(as_string(text || ""));
    if (text == "")
        return "";
    while (true) {
        let s = index(text, "<think>");
        if (s < 0)
            break;
        let e = index(text, "</think>");
        if (e >= s)
            text = substr(text, 0, s) + substr(text, e + 8);
        else {
            text = substr(text, 0, s);
            break;
        }
    }
    return trim(text);
}

function extract_message_text(msg) {
    if (!msg)
        return "";
    let content = msg.content;
    if (type(content) == "string" && trim(content) != "")
        return strip_reasoning_tags(content);
    if (type(content) == "array") {
        let parts = [];
        for (let item in content) {
            if (type(item) == "string")
                push(parts, item);
            else if (type(item) == "object" && item.text)
                push(parts, as_string(item.text));
        }
        let joined = strip_reasoning_tags(join("\n", parts));
        if (joined != "")
            return joined;
    }
    if (type(msg.reasoning_content) == "string" && trim(msg.reasoning_content) != "")
        return strip_reasoning_tags(msg.reasoning_content);
    if (type(msg.reasoning) == "string" && trim(msg.reasoning) != "")
        return strip_reasoning_tags(msg.reasoning);
    return "";
}

function model_supports_temperature(provider, model) {
    let m = lc(trim(as_string(model || "")));
    if (m == "")
        return true;
    if (match(m, /^(o1|o3|o4|gpt-5|gpt-6)/) || index(m, "-search") >= 0 || index(m, "codex") >= 0 || index(m, "reasoner") >= 0)
        return false;
    return true;
}

function normalize_chat_completions_url(raw_url) {
    let u = trim(as_string(raw_url || ""));
    u = replace(u, /\/+$/, "");
    if (u == "")
        return "";
    if (index(u, "generativelanguage.googleapis.com") >= 0) {
        if (match(u, /\/chat\/completions$/))
            return u;
        if (index(u, "/openai") >= 0)
            return u + "/chat/completions";
        if (index(u, "/v1beta") >= 0)
            return replace(u, /\/v1beta.*$/, "") + "/v1beta/openai/chat/completions";
        return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
    }
    if (match(u, /\/chat\/completions$/) || match(u, /\/messages$/))
        return u;
    if (match(u, /\/api\/(chat|generate|tags)$/))
        return replace(u, /\/api\/(chat|generate|tags)$/, "/v1/chat/completions");
    if (match(u, /\/models$/))
        return replace(u, /\/models$/, "/chat/completions");
    if (match(u, /^https?:\/\/[^\/]+$/))
        return u + "/v1/chat/completions";
    return u + "/chat/completions";
}

function derive_models_endpoint(chat_url) {
    let u = trim(as_string(chat_url || ""));
    if (match(u, /\/chat\/completions$/))
        return replace(u, /\/chat\/completions$/, "/models");
    return "";
}

function discover_openai_model(chat_url, api_key) {
    let models_url = derive_models_endpoint(chat_url);
    if (models_url == "")
        return "";
    let curl_args = [
        "curl", "-s", "--connect-timeout", "3", "-m", "5",
        "-H", "Accept: application/json"
    ];
    if (api_key != "") {
        push(curl_args, "-H");
        push(curl_args, "Authorization: Bearer " + api_key);
    }
    push(curl_args, models_url);
    let res = common.command_capture(common.command_from_args(curl_args));
    if (!res || res.status != 0 || res.output == "")
        return "";
    let parsed = history.safe_json_parse(res.output);
    if (!parsed)
        return "";
    if (type(parsed.data) == "array" && length(parsed.data) > 0) {
        for (let item in parsed.data) {
            if (type(item) == "object" && item.id) {
                let id_str = trim(as_string(item.id));
                if (id_str != "" && index(lc(id_str), "embed") < 0)
                    return id_str;
            }
        }
        if (type(parsed.data[0]) == "object" && parsed.data[0].id)
            return trim(as_string(parsed.data[0].id));
    }
    if (type(parsed.models) == "array" && length(parsed.models) > 0) {
        let first = parsed.models[0];
        if (type(first) == "object")
            return trim(as_string(first.id || first.name || first.model || ""));
    }
    return "";
}

function detect_provider_from_key(provider, api_key, custom_url) {
    if (custom_url != "" || api_key == "")
        return provider;
    if (provider != "openai")
        return provider;
    if (index(api_key, "sk-or-") == 0)
        return "openrouter";
    if (index(api_key, "sk-ant-") == 0)
        return "anthropic";
    if (index(api_key, "AIza") == 0)
        return "gemini";
    if (index(api_key, "gsk_") == 0)
        return "groq";
    if (index(api_key, "xai-") == 0)
        return "xai";
    return provider;
}

function query_llm(provider, api_key, custom_url, prompt_text, model_override) {
    last_llm_error = "";
    provider = lc(trim(as_string(provider || "openai")));
    model_override = trim(as_string(model_override || ""));
    api_key = trim(as_string(api_key || ""));
    custom_url = trim(as_string(custom_url || ""));

    provider = detect_provider_from_key(provider, api_key, custom_url);

    let is_local = (provider == "ollama" || provider == "lmstudio" || (provider == "custom" && custom_url != "" && api_key == ""));
    if (!is_local && api_key == "" && custom_url == "") {
        last_llm_error = sprintf("API key is not configured for provider '%s'. Set it in Settings -> AI & Watchdog.", provider);
        return null;
    }

    if (provider == "anthropic" || provider == "claude") {
        let api_url = custom_url != "" ? custom_url : "https://api.anthropic.com/v1/messages";
        if (custom_url != "" && !match(api_url, /\/messages$/) && !match(api_url, /\/chat\/completions$/))
            api_url = replace(api_url, /\/+$/, "") + "/v1/messages";
        let model = model_override != "" ? model_override : "claude-haiku-4-5-20251001";
        let body = {
            model,
            max_tokens: 1500,
            messages: [{ role: "user", content: prompt_text }]
        };
        let payload_path = "/tmp/llm_payload_fuzzer.json";
        common.write_json_file(payload_path, body);

        let curl_args = [
            "curl", "-s", "--connect-timeout", "10", "-m", "150", "-X", "POST",
            "-H", "x-api-key: " + api_key,
            "-H", "anthropic-version: 2023-06-01",
            "-H", "content-type: application/json",
            "-d", "@" + payload_path,
            api_url
        ];
        let result = common.command_capture(common.command_from_args(curl_args));
        common.remove_file(payload_path);

        if (!result || result.status != 0 || result.output == "") {
            let rc = result ? result.status : -1;
            last_llm_error = sprintf("Network request failed (curl exit code %d) connecting to %s", rc, api_url);
            return null;
        }

        let parsed = history.safe_json_parse(result.output);
        if (parsed && parsed.content && type(parsed.content) == "array" && length(parsed.content) > 0) {
            return strip_reasoning_tags(parsed.content[0].text);
        }

        if (parsed && parsed.error) {
            let msg = (type(parsed.error) == "object" && parsed.error.message) ? parsed.error.message : as_string(parsed.error);
            last_llm_error = sprintf("Anthropic API error: %s", msg);
        } else if (parsed && parsed.message) {
            last_llm_error = sprintf("Anthropic API error: %s", parsed.message);
        } else {
            last_llm_error = sprintf("Anthropic API returned unexpected response: %s", substr(trim(result.output), 0, 200));
        }
        return null;
    }

    let base_url = "https://api.openai.com/v1";
    let default_model = "gpt-4o-mini";
    if (provider == "deepseek") {
        base_url = "https://api.deepseek.com/v1";
        default_model = "deepseek-chat";
    } else if (provider == "gemini") {
        base_url = "https://generativelanguage.googleapis.com/v1beta/openai";
        default_model = "gemini-2.5-flash";
    } else if (provider == "openrouter") {
        base_url = "https://openrouter.ai/api/v1";
        default_model = "deepseek/deepseek-chat";
    } else if (provider == "groq") {
        base_url = "https://api.groq.com/openai/v1";
        default_model = "llama-3.3-70b-versatile";
    } else if (provider == "xai") {
        base_url = "https://api.x.ai/v1";
        default_model = "grok-2-latest";
    } else if (provider == "ollama") {
        base_url = custom_url != "" ? custom_url : "http://127.0.0.1:11434/v1";
        default_model = "llama3.2";
    } else if (provider == "lmstudio") {
        base_url = custom_url != "" ? custom_url : "http://127.0.0.1:1234/v1";
        default_model = "local-model";
    } else if (provider == "custom") {
        base_url = custom_url != "" ? custom_url : "http://127.0.0.1:1234/v1";
        default_model = "gpt-4o-mini";
    }

    if (custom_url != "")
        base_url = custom_url;

    let api_url = normalize_chat_completions_url(base_url);
    let model = model_override;
    if (model == "" && (provider == "lmstudio" || provider == "ollama" || provider == "custom" || custom_url != "")) {
        let discovered = discover_openai_model(api_url, api_key);
        if (discovered != "")
            model = discovered;
    }
    if (model == "")
        model = default_model;

    let send_request = function(target_url, target_model, include_temp) {
        let body = {
            model: target_model,
            messages: [
                { role: "system", content: "You are a network censorship and DPI bypass expert. Always return responses formatted strictly as requested." },
                { role: "user", content: prompt_text }
            ]
        };
        if (include_temp)
            body.temperature = 0.3;

        let payload_path = "/tmp/llm_payload_fuzzer.json";
        common.write_json_file(payload_path, body);

        let curl_args = [
            "curl", "-s", "--connect-timeout", "10", "-m", "150", "-X", "POST",
            "-H", "Content-Type: application/json"
        ];
        if (api_key != "") {
            push(curl_args, "-H");
            push(curl_args, "Authorization: Bearer " + api_key);
        }
        if (provider == "openrouter") {
            push(curl_args, "-H");
            push(curl_args, "HTTP-Referer: https://github.com/Dushnilin/tachyon");
            push(curl_args, "-H");
            push(curl_args, "X-Title: Tachyon DPI Fuzzer");
        }
        push(curl_args, "-d");
        push(curl_args, "@" + payload_path);
        push(curl_args, target_url);

        let res = common.command_capture(common.command_from_args(curl_args));
        common.remove_file(payload_path);
        return res;
    };

    let use_temp = model_supports_temperature(provider, model);
    let result = send_request(api_url, model, use_temp);

    if (!result || result.status != 0 || result.output == "") {
        let rc = result ? result.status : -1;
        let reason = rc == 28 ? "request timed out (model took too long to respond)" : sprintf("curl exit code %d", rc);
        last_llm_error = sprintf("Network request failed (%s) connecting to %s", reason, api_url);
        return null;
    }

    let parsed = history.safe_json_parse(result.output);

    // If custom URL returned non-JSON or 404 and lacked /v1/, retry with /v1/chat/completions
    if ((!parsed || (parsed.error && index(lc(as_string(parsed.error.message || parsed.error)), "not found") >= 0)) &&
        index(api_url, "/v1/") < 0 && match(api_url, /\/chat\/completions$/)) {
        let alt_url = replace(api_url, /\/chat\/completions$/, "/v1/chat/completions");
        let alt_res = send_request(alt_url, model, use_temp);
        if (alt_res && alt_res.status == 0 && alt_res.output != "") {
            let alt_parsed = history.safe_json_parse(alt_res.output);
            if (alt_parsed) {
                api_url = alt_url;
                result = alt_res;
                parsed = alt_parsed;
            }
        }
    }

    // Retry without temperature if the model rejects custom temperature
    if (use_temp && parsed && type(parsed.error) == "object") {
        let err_param = lc(as_string(parsed.error.param || ""));
        let err_code = lc(as_string(parsed.error.code || ""));
        let err_msg_lc = lc(as_string(parsed.error.message || ""));
        if (err_param == "temperature" || index(err_msg_lc, "temperature") >= 0 || err_code == "unsupported_value") {
            let retry_res = send_request(api_url, model, false);
            if (retry_res && retry_res.status == 0 && retry_res.output != "") {
                result = retry_res;
                parsed = history.safe_json_parse(result.output);
            }
        }
    }

    // Retry with discovered model if the server rejected the default model name
    if (parsed && type(parsed.error) == "object") {
        let err_msg_lc = lc(as_string(parsed.error.message || parsed.error.code || ""));
        if (index(err_msg_lc, "model") >= 0) {
            let discovered = discover_openai_model(api_url, api_key);
            if (discovered != "" && discovered != model) {
                model = discovered;
                let retry_res = send_request(api_url, model, model_supports_temperature(provider, model));
                if (retry_res && retry_res.status == 0 && retry_res.output != "") {
                    result = retry_res;
                    parsed = history.safe_json_parse(result.output);
                }
            }
        }
    }

    if (parsed && parsed.choices && type(parsed.choices) == "array" && length(parsed.choices) > 0) {
        let choice = parsed.choices[0];
        let text = extract_message_text(choice.message);
        if (text == "" && type(choice.text) == "string")
            text = strip_reasoning_tags(choice.text);
        if (text != "")
            return text;
    }

    if (parsed && type(parsed.message) == "object") {
        let text = extract_message_text(parsed.message);
        if (text != "")
            return text;
    }

    if (parsed && type(parsed.response) == "string" && trim(parsed.response) != "") {
        return strip_reasoning_tags(parsed.response);
    }

    if (parsed && parsed.error) {
        let msg = (type(parsed.error) == "object" && parsed.error.message) ? parsed.error.message : as_string(parsed.error);
        if (provider == "openai" && custom_url == "" && (index(lc(msg), "incorrect api key") >= 0 || index(lc(msg), "invalid_api_key") >= 0)) {
            msg += " (If this key is from DeepSeek, OpenRouter, or a third-party OpenAI proxy, select the matching AI Provider or Custom API Endpoint URL in Settings -> AI & Watchdog)";
        }
        last_llm_error = sprintf("%s API error: %s", provider, msg);
    } else if (parsed && parsed.message) {
        last_llm_error = sprintf("%s API error: %s", provider, as_string(parsed.message));
    } else {
        last_llm_error = sprintf("%s API returned unexpected response: %s", provider, substr(trim(result.output), 0, 200));
    }
    return null;
}

function parse_llm_json(raw_text) {
    raw_text = strip_reasoning_tags(raw_text);
    if (raw_text == "") return null;
    let direct = history.safe_json_parse(raw_text);
    if (direct && type(direct) == "object") return direct;

    let fence_start = index(raw_text, "```");
    if (fence_start >= 0) {
        let rest = substr(raw_text, fence_start + 3);
        rest = replace(rest, /^[a-zA-Z0-9_-]*[ \t\r\n]*/, "");
        let fence_end = index(rest, "```");
        if (fence_end >= 0) {
            let block = trim(substr(rest, 0, fence_end));
            let parsed = history.safe_json_parse(block);
            if (parsed && type(parsed) == "object") return parsed;
        }
    }

    let first_brace = index(raw_text, "{");
    let last_brace = rindex(raw_text, "}");
    if (first_brace >= 0 && last_brace > first_brace) {
        let candidate = substr(raw_text, first_brace, (last_brace - first_brace) + 1);
        let parsed = history.safe_json_parse(candidate);
        if (parsed && type(parsed) == "object") return parsed;
    }
    return null;
}

function run_baseline_probe(target_url) {
    let url = trim(as_string(target_url || ""));
    if (url == "")
        url = "https://www.youtube.com/";
    let curl_args = [
        "curl", "-k", "-s", "-o", "/dev/null",
        "-w", "%{http_code}\t%{time_appconnect}\t%{time_starttransfer}",
        "--connect-timeout", "3", "-m", "4",
        url
    ];
    let res = common.command_capture(common.command_from_args(curl_args));
    let out = res ? trim(as_string(res.output || "")) : "";
    let parts = split(out, "\t");
    let http_code = length(parts) > 0 ? int(parts[0] || 0) : 0;
    let hs_sec = length(parts) > 1 ? (1.0 * (parts[1] || 0)) : 0.0;
    let ttfb_sec = length(parts) > 2 ? (1.0 * (parts[2] || 0)) : 0.0;
    let handshake_ms = int(hs_sec * 1000.0);
    let ttfb_ms = int(ttfb_sec * 1000.0);
    let err_str = "";
    if (!res || res.status != 0 || http_code == 0) {
        let rc = res ? res.status : -1;
        if (rc == 28) err_str = "Connection or TLS handshake timeout (curl exit 28)";
        else if (rc == 35) err_str = "TLS/SSL handshake reset or blocked by DPI (curl exit 35)";
        else if (rc == 56) err_str = "TCP connection reset by peer / TSPU RST injection (curl exit 56)";
        else if (rc == 7) err_str = "Failed to connect to host (curl exit 7)";
        else if (rc == 6) err_str = "Could not resolve host / DNS blocked (curl exit 6)";
        else err_str = sprintf("Direct probe failed (curl exit %d)", rc);
    }
    return {
        http_code,
        handshake_ms,
        ttfb_ms,
        error: err_str
    };
}

function sanitize_strategy_args(engine, raw_args) {
    engine = lc(trim(as_string(engine || "zapret2")));
    let s = trim(as_string(raw_args || ""));
    if (s == "")
        return "";
    s = replace(s, /^`+|`+$/g, "");
    s = replace(s, /^["']+|["']+$/g, "");
    s = replace(s, /[\r\n\t]+/g, " ");
    s = replace(s, /^[ \t]*(\/usr\/(sbin|bin)\/|\/opt\/zapret2?\/nfq2?\/)?(nfqws2|nfqws|ciadpi|byedpi)[ \t]+/, "");

    let raw_tokens = split(s, /[ \t]+/);
    let filtered = [];
    for (let i = 0; i < length(raw_tokens); i++) {
        let tok = trim(as_string(raw_tokens[i]));
        if (tok == "" || tok == "\\") continue;
        let base = split(tok, "=")[0];
        if (base == "--qnum" || base == "--pidfile" || base == "--fwmark" ||
            base == "--dpi-desync-fwmark" || base == "--hostlist" || base == "--hostlist-domains" ||
            base == "--hostlist-exclude" || base == "--hostlist-auto" || base == "--ipset" ||
            base == "--ipset-ip" || base == "--ip" || base == "--port") {
            if (base == tok && (i + 1) < length(raw_tokens) && substr(as_string(raw_tokens[i + 1]), 0, 1) != "-")
                i++;
            continue;
        }
        if (tok == "--daemon" || tok == "--dry-run" || tok == "--version" ||
            tok == "<HOSTLIST>" || tok == "<HOSTLIST_NOAUTO>")
            continue;
        if (engine == "byedpi" && (tok == "-i" || tok == "-p" || tok == "-D" || tok == "-E" || tok == "-w")) {
            if ((tok == "-i" || tok == "-p" || tok == "-w") && (i + 1) < length(raw_tokens) && substr(as_string(raw_tokens[i + 1]), 0, 1) != "-")
                i++;
            continue;
        }
        push(filtered, tok);
    }

    let cleaned = trim(join(" ", filtered));
    if (engine == "zapret2" && index(cleaned, "--dpi-desync") >= 0 && index(cleaned, "--lua-desync") < 0) {
        let has_fake = index(cleaned, "fake") >= 0;
        let has_disorder = index(cleaned, "disorder") >= 0;
        let pos_m = match(cleaned, /--dpi-desync-split-pos=([^ \t]+)/);
        let pos = (pos_m && pos_m[1]) ? pos_m[1] : "1,midsld";
        let ttl_m = match(cleaned, /--dpi-desync-ttl=([0-9]+)/);
        let ttl = (ttl_m && ttl_m[1]) ? ttl_m[1] : "4";
        let fool_m = match(cleaned, /--dpi-desync-fooling=([^ \t]+)/);
        let fool = (fool_m && fool_m[1]) ? replace(fool_m[1], /,/g, ":") : "tcp_seq=1000000";
        fool = replace(fool, /\bbadseq\b/g, "tcp_seq=1000000");
        fool = replace(fool, /\bmd5sig\b/g, "tcp_md5");
        fool = replace(fool, /\bbadack\b/g, "tcp_ack=-66000");
        fool = replace(fool, /\bdatanoack\b/g, "tcp_flags_unset=ack");
        let z2_parts = [];
        if (has_fake)
            push(z2_parts, sprintf("--lua-desync=fake:blob=tls_max:ip_ttl=%s:fooling=%s", ttl, fool));
        push(z2_parts, sprintf("--lua-desync=%s:pos=%s", has_disorder ? "multidisorder" : "multisplit", pos));
        cleaned = join(" ", z2_parts);
    }
    return cleaned;
}

function compute_ai_strategies_result(engine, target, custom_url, user_prompt) {
    let current = history.get_fuzzer_state();
    if (current.running) {
        return { success: false, error: "Fuzzer is currently running a benchmark" };
    }

    engine = lc(as_string(engine || "zapret2"));
    target = trim(as_string(target || "youtube_suite"));
    user_prompt = trim(as_string(user_prompt || ""));
    let target_url = binaries.resolve_target_url(target, custom_url);

    let baseline = run_baseline_probe(target_url);

    let uci = uci_core.cursor();
    let cfg = uci != null ? (uci.get_all(CONFIG_NAME, "settings") || {}) : {};
    let ai_sec = uci != null ? (uci.get_all(CONFIG_NAME, "ai") || {}) : {};
    let provider = cfg.ai_doctor_provider || ai_sec.provider || "openai";
    let api_key = cfg.ai_doctor_api_key || ai_sec.api_key || "";
    let ai_custom_url = cfg.ai_doctor_custom_url || ai_sec.custom_url || "";
    let model_override = cfg.ai_doctor_model || ai_sec.model || "";

    let query_text = sprintf("%s %s %s", engine, target, user_prompt);
    let rag_docs = rag.retrieve(query_text, provider, api_key, ai_custom_url, model_override, 4);

    let target_engines = (engine == "all") ? "zapret2, zapret, byedpi, and desync" : engine;
    let prompt = sprintf(
        "You are an expert DPI Bypass Engineer specializing in OpenWrt, Zapret, Zapret2 (nfqws2), ByeDPI (ciadpi), and Tachyon Native Desync.\n" +
        "We need to bypass censorship / TSPU blocking for target service '%s' (%s) using engine '%s'.\n\n" +
        "LIVE PROBE DIAGNOSTICS:\n" +
        "- Direct HTTP Code: %d\n" +
        "- Connect Time: %d ms\n" +
        "- TTFB: %d ms\n" +
        "- Probe Error: %s\n" +
        "- User Notes / ISP Context: %s\n\n" +
        "TECHNICAL KNOWLEDGE BASE FRAGMENTS:\n%s\n\n" +
        "TASK:\n" +
        "1. Analyze why this target is blocked or throttled.\n" +
        "2. Formulate 3 to 5 highly effective, syntactically valid DPI desync strategies for '%s'.\n" +
        "3. Output MUST be strictly valid JSON matching this schema:\n" +
        "{\n" +
        '  "analysis": "Brief 1-2 sentence diagnosis of the blocking pattern",\n' +
        '  "strategies": [\n' +
        '    {\n' +
        '      "id": "ai_strat_1",\n' +
        '      "name": "Human-readable descriptive strategy name",\n' +
        '      "engine": "%s",\n' +
        '      "args": "Exact command-line arguments string for the engine",\n' +
        '      "description": "Why this combination should bypass the block"\n' +
        '    }\n' +
        '  ]\n' +
        "}\n\n" +
        "RULES FOR STRATEGY ARGS:\n" +
        "- For zapret2 (nfqws2): ONLY use '--lua-desync=...' syntax (NEVER use zapret1 '--dpi-desync' flags!). Examples: '--lua-desync=multisplit:pos=1,midsld:seqovl=1' or '--lua-desync=fake:blob=tls_max:ip_ttl=4:fooling=tcp_seq=1000000 --lua-desync=multidisorder:pos=1,midsld'. DO NOT include binary name, --qnum, --fwmark, or --hostlist.\n" +
        "- For zapret (nfqws v1): ONLY use '--dpi-desync=...' syntax like '--dpi-desync=fake,split2 --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-ttl=4'. DO NOT include binary name, --qnum, or --hostlist.\n" +
        "- For byedpi (ciadpi): ONLY use valid ciadpi flags like '-s 1 -d 1 --auto=t,r,s -o 1' or '--split 1 --disorder 3+s --tlsrec 1+s'. DO NOT include binary name, -i, or -p.\n" +
        "- For desync (tachyon-core native): ONLY use space-separated key=value pairs from: preset=(fake_split|tlsrec|disorder|split|fake|oob|auto), mode=(fake_split|tlsrec|disorder|split|fake|oob), split_pos=(1|2|midsld|sni), fake_ttl=(2..12), fake_sni=(max.ru|www.google.com|gosuslugi.ru|sberbank.ru), repeats=(1..12), split_delay_ms=(0..50), udp_fake=(true|false), udp_repeats=(1..12), udp_fake_ttl=(2..12). Example: 'mode=fake_split split_pos=midsld fake_ttl=4 fake_sni=max.ru repeats=6'.\n\n" +
        "JSON OUTPUT:",
        target, target_url, target_engines,
        baseline.http_code, baseline.handshake_ms, baseline.ttfb_ms,
        baseline.error != "" ? baseline.error : "none",
        user_prompt != "" ? user_prompt : "None provided",
        rag_docs,
        target_engines,
        engine == "all" ? "zapret2" : engine
    );

    let raw_reply = query_llm(provider, api_key, ai_custom_url, prompt, model_override);
    if (!raw_reply) {
        let err_msg = (last_llm_error && last_llm_error != "")
            ? last_llm_error
            : "Failed to receive response from AI provider. Check API key and network connectivity.";
        return {
            success: false,
            error: err_msg
        };
    }

    let parsed_json = parse_llm_json(raw_reply);
    if (!parsed_json || !parsed_json.strategies || type(parsed_json.strategies) != "array" || length(parsed_json.strategies) == 0) {
        return {
            success: false,
            error: "AI returned non-JSON or invalid format",
            raw_response: raw_reply
        };
    }

    let valid_strategies = [];
    for (let i = 0; i < length(parsed_json.strategies); i++) {
        let st = parsed_json.strategies[i];
        if (!st || !st.args) continue;
        let st_engine = (engine == "all" && st.engine) ? lc(trim(as_string(st.engine))) : engine;
        if (st_engine == "all") st_engine = "zapret2";
        let clean_args = sanitize_strategy_args(st_engine, st.args);
        if (clean_args != "" && strategies.validate_strategy_args(st_engine, clean_args)) {
            push(valid_strategies, {
                id: st.id || sprintf("ai_strat_%d", i + 1),
                name: st.name || sprintf("AI Strategy %d", i + 1),
                engine: st_engine,
                args: clean_args,
                description: st.description || ""
            });
        }
    }

    if (length(valid_strategies) == 0) {
        return {
            success: false,
            error: "All AI strategies failed syntax validation for engine " + engine,
            raw_strategies: parsed_json.strategies
        };
    }

    let custom_file = STATE_DIR + "/fuzzer_ai_strategies.json";
    history.ensure_state_dir();
    common.write_json_file(custom_file, valid_strategies);

    return {
        success: true,
        engine,
        target,
        target_url,
        analysis: parsed_json.analysis || "AI strategy synthesis complete",
        strategies: valid_strategies,
        custom_file
    };
}

function synthesize_ai_strategies(engine, target, custom_url, user_prompt) {
    let res = compute_ai_strategies_result(engine, target, custom_url, user_prompt);
    print(sprintf("%J\n", res));
    return res;
}

function run_ai_synthesize_worker(engine, target, custom_url, user_prompt, job_id) {
    history.ensure_state_dir();
    let res = compute_ai_strategies_result(engine, target, custom_url, user_prompt);
    res.running = false;
    res.job_id = job_id || "";
    res.finished_at = time();
    common.write_json_file(AI_JOB_FILE, res);
    common.remove_file(AI_JOB_PID);
}

function start_ai_synthesize_async(engine, target, custom_url, user_prompt) {
    let current = history.get_fuzzer_state();
    if (current.running) {
        let busy = { success: false, running: false, error: "Fuzzer is currently running a benchmark" };
        print(sprintf("%J\n", busy));
        return busy;
    }

    history.ensure_state_dir();
    let old_pid = trim(as_string(fs.readfile(AI_JOB_PID) || ""));
    if (old_pid != "" && exec.is_alive(old_pid)) {
        exec.kill_process(old_pid, 1);
    }

    let job_id = sprintf("fuzzer_ai_%d", time());
    let init_state = {
        running: true,
        job_id: job_id,
        engine: lc(as_string(engine || "zapret2")),
        target: trim(as_string(target || "youtube_suite")),
        started_at: time()
    };
    common.write_json_file(AI_JOB_FILE, init_state);

    let fuzzer_bin = LIB_DIR + "/diagnostics/fuzzer.uc";
    if (fs.stat(fuzzer_bin) == null)
        fuzzer_bin = "/usr/lib/tachyon/diagnostics/fuzzer.uc";

    let spawned = exec.run_background({
        argv: [
            "ucode", "-L", LIB_DIR, fuzzer_bin,
            "ai_synthesize_worker",
            as_string(engine || "zapret2"),
            as_string(target || "youtube_suite"),
            as_string(custom_url || ""),
            as_string(user_prompt || ""),
            job_id
        ],
        name: "fuzzer-ai"
    });
    if (spawned && spawned.pid && spawned.pid != "0")
        common.write_file(AI_JOB_PID, spawned.pid + "\n");

    let out = {
        success: true,
        async: true,
        running: true,
        job_id: job_id
    };
    print(sprintf("%J\n", out));
    return out;
}

function get_ai_synthesize_status() {
    let state = common.read_json_file(AI_JOB_FILE);
    if (!state || type(state) != "object") {
        let empty = { running: false, success: false, error: "No AI synthesis job found" };
        print(sprintf("%J\n", empty));
        return empty;
    }
    if (state.running === true) {
        let pid = trim(as_string(fs.readfile(AI_JOB_PID) || ""));
        let age = time() - int(state.started_at || 0);
        if ((pid != "" && !exec.is_alive(pid)) || age > 180) {
            let recheck = common.read_json_file(AI_JOB_FILE);
            if (recheck && recheck.running === false) {
                state = recheck;
            } else {
                state.running = false;
                state.success = false;
                state.error = age > 180
                    ? "AI synthesis timed out after 180 seconds"
                    : "AI synthesis worker exited unexpectedly";
                common.write_json_file(AI_JOB_FILE, state);
            }
        }
    }
    print(sprintf("%J\n", state));
    return state;
}

function module_exports() {
    return {
        query_llm,
        parse_llm_json,
        normalize_chat_completions_url,
        sanitize_strategy_args,
        run_baseline_probe,
        synthesize_ai_strategies,
        run_ai_synthesize_worker,
        start_ai_synthesize_async,
        get_ai_synthesize_status,
        get_last_error: function() { return last_llm_error; }
    };
}

return module_exports();
