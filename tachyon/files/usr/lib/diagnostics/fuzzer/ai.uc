#!/usr/bin/env ucode
//
// Fuzzer AI helpers: LLM queries and AI-synthesised strategies.
//
// Extracted from diagnostics/fuzzer.uc (branch 6 god-module split).
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let rag = require("diagnostics.rag");
let history = require("diagnostics.fuzzer.history");
let strategies = require("diagnostics.fuzzer.strategies");
let probe = require("diagnostics.fuzzer.probe");
let binaries = require("diagnostics.fuzzer.binaries");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const STATE_DIR = history.STATE_DIR || getenv("TACHYON_FUZZER_STATE_DIR") || "/var/run/tachyon";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let last_llm_error = "";

function query_llm(provider, api_key, custom_url, prompt_text, model_override) {
    last_llm_error = "";
    provider = lc(trim(as_string(provider || "openai")));
    model_override = trim(as_string(model_override || ""));
    api_key = trim(as_string(api_key || ""));
    custom_url = trim(as_string(custom_url || ""));

    let is_local = (provider == "ollama" || provider == "lmstudio" || (provider == "custom" && api_key == ""));
    if (!is_local && api_key == "") {
        last_llm_error = sprintf("API key is not configured for provider '%s'. Set it in Settings -> AI & Watchdog.", provider);
        return null;
    }

    if (provider == "anthropic" || provider == "claude") {
        let api_url = custom_url != "" ? custom_url : "https://api.anthropic.com/v1/messages";
        let model = model_override != "" ? model_override : "claude-haiku-4-5-20251001";
        let body = {
            model,
            max_tokens: 1000,
            messages: [{ role: "user", content: prompt_text }]
        };
        let payload_path = "/tmp/llm_payload_fuzzer.json";
        common.write_json_file(payload_path, body);

        let curl_args = [
            "curl", "-s", "--connect-timeout", "10", "-m", "35", "-X", "POST",
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
            return parsed.content[0].text;
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
    let default_model = "gpt-6-luna";
    if (provider == "deepseek") {
        base_url = "https://api.deepseek.com/v1";
        default_model = "deepseek-chat";
    } else if (provider == "openrouter") {
        base_url = "https://openrouter.ai/api/v1";
        default_model = "deepseek/deepseek-chat";
    } else if (provider == "ollama") {
        base_url = custom_url != "" ? custom_url : "http://127.0.0.1:11434/v1";
        default_model = "llama3.2";
    } else if (provider == "lmstudio" || provider == "custom") {
        base_url = custom_url != "" ? custom_url : "http://127.0.0.1:1234/v1";
        default_model = "local-model";
    }

    base_url = trim(as_string(base_url));
    base_url = replace(base_url, /\/+$/, "");
    let api_url = match(base_url, /\/chat\/completions$/) ? base_url : (base_url + "/chat/completions");
    let model = model_override != "" ? model_override : default_model;
    let body = {
        model,
        messages: [
            { role: "system", content: "You are a network censorship and DPI bypass expert. Always return responses formatted strictly as requested." },
            { role: "user", content: prompt_text }
        ],
        temperature: 0.3
    };

    let payload_path = "/tmp/llm_payload_fuzzer.json";
    common.write_json_file(payload_path, body);

    let curl_args = [
        "curl", "-s", "--connect-timeout", "10", "-m", "35", "-X", "POST",
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
    push(curl_args, api_url);

    let result = common.command_capture(common.command_from_args(curl_args));
    common.remove_file(payload_path);

    if (!result || result.status != 0 || result.output == "") {
        let rc = result ? result.status : -1;
        last_llm_error = sprintf("Network request failed (curl exit code %d) connecting to %s", rc, api_url);
        return null;
    }

    let parsed = history.safe_json_parse(result.output);
    if (parsed && parsed.choices && type(parsed.choices) == "array" && length(parsed.choices) > 0) {
        let msg = parsed.choices[0].message;
        if (msg && msg.content) {
            return msg.content;
        }
    }

    if (parsed && parsed.error) {
        let msg = (type(parsed.error) == "object" && parsed.error.message) ? parsed.error.message : as_string(parsed.error);
        last_llm_error = sprintf("%s API error: %s", provider, msg);
    } else if (parsed && parsed.message) {
        last_llm_error = sprintf("%s API error: %s", provider, parsed.message);
    } else {
        last_llm_error = sprintf("%s API returned unexpected response: %s", provider, substr(trim(result.output), 0, 200));
    }
    return null;
}

function parse_llm_json(raw_text) {
    raw_text = trim(as_string(raw_text));
    if (raw_text == "") return null;
    let direct = history.safe_json_parse(raw_text);
    if (direct && type(direct) == "object") return direct;

    let m = match(raw_text, /```json\s*([\s\S]*?)\s*```/);
    if (m && m[1]) {
        let parsed = history.safe_json_parse(m[1]);
        if (parsed && type(parsed) == "object") return parsed;
    }

    m = match(raw_text, /\{[\s\S]*\}/);
    if (m && m[0]) {
        let parsed = history.safe_json_parse(m[0]);
        if (parsed && type(parsed) == "object") return parsed;
    }
    return null;
}

function synthesize_ai_strategies(engine, target, custom_url, user_prompt) {
    let current = history.get_fuzzer_state();
    if (current.running) {
        print(sprintf("%J\n", { success: false, error: "Fuzzer is currently running a benchmark" }));
        return;
    }

    engine = lc(as_string(engine || "zapret2"));
    target = trim(as_string(target || "youtube_suite"));
    user_prompt = trim(as_string(user_prompt || ""));
    let target_url = binaries.resolve_target_url(target, custom_url);

    let baseline = probe.run_probe(engine, "", target, custom_url);

    let uci = uci_core.cursor();
    let cfg = uci != null ? (uci.get_all(CONFIG_NAME, "settings") || {}) : {};
    let ai_sec = uci != null ? (uci.get_all(CONFIG_NAME, "ai") || {}) : {};
    let provider = cfg.ai_doctor_provider || ai_sec.provider || "openai";
    let api_key = cfg.ai_doctor_api_key || ai_sec.api_key || "";
    let ai_custom_url = cfg.ai_doctor_custom_url || ai_sec.custom_url || "";
    let model_override = cfg.ai_doctor_model || ai_sec.model || "";

    // RAG retrieval uses the same provider credentials as the LLM call; the
    // old call passed the top_k into the provider slot, so retrieval silently
    // failed and the knowledge-base fragments were always empty.
    let query_text = sprintf("%s %s %s", engine, target, user_prompt);
    let rag_docs = rag.retrieve(query_text, provider, api_key, ai_custom_url, model_override, 4);

    let prompt = sprintf(
        "You are an expert DPI Bypass Engineer specializing in OpenWrt, Zapret, Zapret2 (nfqws2), and ByeDPI (ciadpi).\n" +
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
        '      "args": "Exact command-line arguments string for the engine",\n' +
        '      "description": "Why this combination should bypass the block"\n' +
        '    }\n' +
        '  ]\n' +
        "}\n\n" +
        "RULES FOR STRATEGY ARGS:\n" +
        "- For zapret2: use valid options like '--lua-desync=multisplit:pos=1,midsld:seqovl=1:fooling=badseq' or '--lua-desync=fake:ttl=4:fooling=badseq --lua-desync=multisplit:pos=1,midsld'. DO NOT include binary name.\n" +
        "- For zapret: use valid options like '--dpi-desync=fake,split2 --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-ttl=4'. DO NOT include binary name.\n" +
        "- For byedpi: use valid options like '-s 1 -d 1 --auto=t,r,s -o 1'. DO NOT include binary name.\n\n" +
        "JSON OUTPUT:",
        target, target_url, engine,
        baseline.http_code, baseline.handshake_ms, baseline.ttfb_ms,
        baseline.error != "" ? baseline.error : "none",
        user_prompt != "" ? user_prompt : "None provided",
        rag_docs,
        engine
    );

    let raw_reply = query_llm(provider, api_key, ai_custom_url, prompt, model_override);
    if (!raw_reply) {
        let err_msg = (last_llm_error && last_llm_error != "")
            ? last_llm_error
            : "Failed to receive response from AI provider. Check API key and network connectivity.";
        print(sprintf("%J\n", {
            success: false,
            error: err_msg
        }));
        return;
    }

    let parsed_json = parse_llm_json(raw_reply);
    if (!parsed_json || !parsed_json.strategies || type(parsed_json.strategies) != "array" || length(parsed_json.strategies) == 0) {
        print(sprintf("%J\n", {
            success: false,
            error: "AI returned non-JSON or invalid format",
            raw_response: raw_reply
        }));
        return;
    }

    let valid_strategies = [];
    for (let i = 0; i < length(parsed_json.strategies); i++) {
        let st = parsed_json.strategies[i];
        if (st && st.args && strategies.validate_strategy_args(engine, st.args)) {
            push(valid_strategies, {
                id: st.id || sprintf("ai_strat_%d", i + 1),
                name: st.name || sprintf("AI Strategy %d", i + 1),
                engine,
                args: trim(st.args),
                description: st.description || ""
            });
        }
    }

    if (length(valid_strategies) == 0) {
        print(sprintf("%J\n", {
            success: false,
            error: "All AI strategies failed syntax validation for engine " + engine,
            raw_strategies: parsed_json.strategies
        }));
        return;
    }

    let custom_file = STATE_DIR + "/fuzzer_ai_strategies.json";
    history.ensure_state_dir();
    common.write_json_file(custom_file, valid_strategies);

    print(sprintf("%J\n", {
        success: true,
        engine,
        target,
        target_url,
        analysis: parsed_json.analysis || "AI strategy synthesis complete",
        strategies: valid_strategies,
        custom_file
    }));
}

function module_exports() {
    return {
        query_llm,
        parse_llm_json,
        synthesize_ai_strategies,
        get_last_error: function() { return last_llm_error; }
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: diagnostics/fuzzer/ai.uc (library module, no CLI)
");
exit(1);
