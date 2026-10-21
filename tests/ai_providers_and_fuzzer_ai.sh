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

# 3. Strategy args sanitization (strip binary name, strip Tachyon-managed flags, convert zapret1 -> zapret2 if hallucinated)
sanitize_check="$(ucode -L "$TACHYON_LIB" -e '
let ai = require("diagnostics.fuzzer.ai");
let s = require("diagnostics.fuzzer.strategies");

let z2_clean = ai.sanitize_strategy_args("zapret2", "nfqws2 --qnum=200 --fwmark=0x40000000 --lua-desync=multisplit:pos=1,midsld");
assert(z2_clean == "--lua-desync=multisplit:pos=1,midsld", "z2_clean: " + z2_clean);
assert(s.validate_strategy_args("zapret2", z2_clean) === true, "z2_clean must validate");

let z2_converted = ai.sanitize_strategy_args("zapret2", "--dpi-desync=fake,disorder2 --dpi-desync-split-pos=1,midsld --dpi-desync-ttl=5 --dpi-desync-fooling=badseq");
assert(index(z2_converted, "--lua-desync=") >= 0, "zapret1 flags must convert to --lua-desync for zapret2: " + z2_converted);
assert(s.validate_strategy_args("zapret2", z2_converted) === true, "converted zapret2 strategy must validate: " + z2_converted);

let bd_clean = ai.sanitize_strategy_args("byedpi", "ciadpi -i 127.0.0.1 -p 1080 -s 1 -d 1 --auto=t,r,s");
assert(bd_clean == "-s 1 -d 1 --auto=t,r,s", "bd_clean: " + bd_clean);
assert(s.validate_strategy_args("byedpi", bd_clean) === true, "bd_clean must validate");
print("OK");
' 2>&1 || echo "FAIL")"
[ "$sanitize_check" = "OK" ] || fail "sanitize_strategy_args failed: $sanitize_check"

# 4. RAG get_embedding_model ignores non-embedding chat model overrides and lexical_search works offline
rag_check="$(ucode -L "$TACHYON_LIB" -e '
let rag = require("diagnostics.rag");
assert(rag.get_embedding_model("openai", "gpt-4o-mini") == "text-embedding-3-small", "chat model override must not replace embedding model");
assert(rag.get_embedding_model("openai", "text-embedding-3-large") == "text-embedding-3-large", "explicit embedding model override must be honored");
let docs = rag.retrieve("zapret2 youtube multisplit", "lmstudio", "", "http://127.0.0.1:59999", "qwen2.5-coder", 3);
assert(length(docs) > 0, "lexical fallback must return relevant knowledge base chunks offline without calling embedding API");
print("OK");
' 2>&1 || echo "FAIL")"
[ "$rag_check" = "OK" ] || fail "rag lexical fallback check failed: $rag_check"

printf 'ai providers and fuzzer ai checks passed\n'
