#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# 1. URL normalization for local LM Studio / Ollama / Custom / Gemini endpoints
url_check="$(ucode -L "$TACHYON_LIB" -e '
let ai = require("diagnostics.fuzzer.ai");
assert(ai.normalize_chat_completions_url("http://192.168.1.50:1234") == "http://192.168.1.50:1234/v1/chat/completions", "bare host:port must get /v1/chat/completions");
assert(ai.normalize_chat_completions_url("http://192.168.1.50:1234/v1") == "http://192.168.1.50:1234/v1/chat/completions", "/v1 must get /chat/completions");
assert(ai.normalize_chat_completions_url("http://192.168.1.50:11434/api/chat") == "http://192.168.1.50:11434/v1/chat/completions", "ollama /api/chat must map to /v1/chat/completions");
assert(ai.normalize_chat_completions_url("https://generativelanguage.googleapis.com") == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini host must map to openai compat endpoint");
print("OK");
' 2>&1 || echo "FAIL")"
[ "$url_check" = "OK" ] || fail "normalize_chat_completions_url failed: $url_check"

# 2. Reasoning model <think>...</think> stripping and JSON extraction
json_check="$(ucode -L "$TACHYON_LIB" -e '
let ai = require("diagnostics.fuzzer.ai");
let raw = "<think>\nLet me analyze why YouTube is blocked on Rostelecom.\nMaybe { \"bad\": 1 } inside thinking.\n</think>\n```json\n{\n  \"analysis\": \"TLS SNI filtering\",\n  \"strategies\": [\n    { \"id\": \"s1\", \"name\": \"Multisplit\", \"args\": \"--lua-desync=multisplit:pos=1,midsld\" }\n  ]\n}\n```";
let parsed = ai.parse_llm_json(raw);
assert(parsed != null, "parsed must not be null");
assert(parsed.analysis == "TLS SNI filtering", "analysis must match");
assert(length(parsed.strategies) == 1, "strategies length must be 1");
print("OK");
' 2>&1 || echo "FAIL")"
[ "$json_check" = "OK" ] || fail "parse_llm_json with <think> failed: $json_check"

# 3. Strategy args sanitization (strip markdown backticks/quotes/whitespace)
sanitize_check="$(ucode -L "$TACHYON_LIB" -e '
let ai = require("diagnostics.fuzzer.ai");
let r = require("diagnostics.fuzzer_runner");

let ds_clean = ai.sanitize_strategy_args("desync", "`mode=fake_split split_pos=midsld fake_ttl=6`");
assert(ds_clean == "mode=fake_split split_pos=midsld fake_ttl=6", "ds_clean: " + ds_clean);
assert(r.validate_strategy_args("desync", ds_clean) === true, "ds_clean must validate");

let ds_preset = ai.sanitize_strategy_args("", "\"preset=auto\"");
assert(ds_preset == "preset=auto", "ds_preset: " + ds_preset);
assert(r.validate_strategy_args("desync", ds_preset) === true, "ds_preset must validate");
print("OK");
' 2>&1 || echo "FAIL")"
[ "$sanitize_check" = "OK" ] || fail "sanitize_strategy_args failed: $sanitize_check"

# 4. RAG get_embedding_model ignores non-embedding chat model overrides and lexical_search works offline
rag_check="$(ucode -L "$TACHYON_LIB" -e '
let rag = require("diagnostics.rag");
assert(rag.get_embedding_model("openai", "gpt-4o-mini") == "text-embedding-3-small", "chat model override must not replace embedding model");
assert(rag.get_embedding_model("openai", "text-embedding-3-large") == "text-embedding-3-large", "explicit embedding model override must be honored");
let docs = rag.retrieve("desync youtube multisplit", "lmstudio", "", "http://127.0.0.1:59999", "qwen2.5-coder", 3);
assert(length(docs) > 0, "lexical fallback must return relevant knowledge base chunks offline without calling embedding API");
print("OK");
' 2>&1 || echo "FAIL")"
[ "$rag_check" = "OK" ] || fail "rag lexical fallback check failed: $rag_check"

printf 'ai providers and fuzzer ai checks passed\n'
