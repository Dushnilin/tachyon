#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
EXPLAIN_UC="$TACHYON_LIB/diagnostics/route_explain.uc"
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"
API_UC="$TACHYON_LIB/service/api.uc"
AGENT_API_UC="$TACHYON_LIB/service/agent_api.uc"
BIN_TACHYON="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected to contain '$needle', got: $haystack" ;;
  esac
}

# --- 1. Static Contract Inspections ---

[ -f "$EXPLAIN_UC" ] || fail "diagnostics/route_explain.uc must exist"

grep -Fq 'function explain_route(' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define explain_route"
grep -Fq 'function format_text_report(' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define format_text_report"
grep -Fq 'function normalize_target_input(' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define normalize_target_input"
grep -Fq 'function classify_client(' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define classify_client"
grep -Fq 'function ipv4_in_cidr(' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define ipv4_in_cidr"
grep -Fq 'function is_private_ip(' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define is_private_ip"
grep -Fq 'function selftest()' "$EXPLAIN_UC" ||
  fail "route_explain.uc must define selftest"

# Wiring in /usr/bin/tachyon
grep -Fq 'route_explain: [ "diagnostics/route_explain.uc", "explain", 4 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map route_explain"
grep -Fq '"route-explain": [ "diagnostics/route_explain.uc", "explain", 4 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map route-explain"

# Wiring in diagnostics/runtime.uc
grep -Fq 'function route_explain(client, target, port, proto, format)' "$RUNTIME_UC" ||
  fail "diagnostics/runtime.uc must define route_explain delegate"
grep -Fq 'mode == "route-explain"' "$RUNTIME_UC" ||
  fail "diagnostics/runtime.uc must handle route-explain CLI dispatch"

# Wiring in service/api.uc
grep -Fq 'function route_explain(' "$API_UC" ||
  fail "service/api.uc must define route_explain function"
grep -Fq 'route_explain' "$API_UC" ||
  fail "service/api.uc must export route_explain"

# Wiring in service/agent_api.uc
grep -Fq 'handle_route_explain' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must define handle_route_explain"
grep -Fq 'tachyon_route_explain' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must register tachyon_route_explain tool"
grep -Fq '/route/explain' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must route /route/explain endpoint"

# --- 2. Ucode Syntax and Forward Reference Checks ---

if command -v node >/dev/null 2>&1 && [ -f "$ROOT_DIR/tests/lib/ucode_forward_refs.js" ]; then
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$EXPLAIN_UC" ||
    fail "forward reference lint failed for route_explain.uc"
fi

if command -v ucode >/dev/null 2>&1; then
  ucode -c "$EXPLAIN_UC" || fail "ucode -c failed for route_explain.uc"
  ucode -S -c "$EXPLAIN_UC" || fail "ucode -S -c failed for route_explain.uc"

  # --- 3. Built-in Selftest ---
  selftest_output=$(ucode -L "$TACHYON_LIB" -- "$EXPLAIN_UC" selftest)
  assert_contains "$selftest_output" "passed" "selftest output"
  assert_contains "$selftest_output" "0 failed" "selftest zero failures"

  # --- 4. CLI Execution Checks ---

  # 4.1 Plain text explain for public domain
  cli_text=$(ucode -L "$TACHYON_LIB" -- "$EXPLAIN_UC" explain 192.168.1.100 instagram.com 443 tcp)
  assert_contains "$cli_text" "TACHYON ROUTE DECISION EXPLAINER" "CLI text banner"
  assert_contains "$cli_text" "Query:   Client 192.168.1.100 -> Target instagram.com:443 (tcp)" "CLI query info"
  assert_contains "$cli_text" "Verdict:" "CLI verdict label"
  assert_contains "$cli_text" "1. Client:" "CLI stage 1"
  assert_contains "$cli_text" "2. Target:" "CLI stage 2"
  assert_contains "$cli_text" "3. Section:" "CLI stage 3"
  assert_contains "$cli_text" "4. DNS Mode:" "CLI stage 4"
  assert_contains "$cli_text" "5. nftables:" "CLI stage 5"
  assert_contains "$cli_text" "6. Routing:" "CLI stage 6"
  assert_contains "$cli_text" "7. Engine:" "CLI stage 7"
  assert_contains "$cli_text" "Explanation (RU):" "CLI RU explanation"
  assert_contains "$cli_text" "Explanation (EN):" "CLI EN explanation"

  # 4.2 Local IP routing trace
  cli_local=$(ucode -L "$TACHYON_LIB" -- "$EXPLAIN_UC" explain 192.168.1.100 192.168.1.1 80 tcp)
  assert_contains "$cli_local" "Verdict: [LOCAL]" "Local IP verdict is LOCAL"
  assert_contains "$cli_local" "Intercepted=NO" "Local IP not intercepted"

  # 4.3 JSON output format
  cli_json=$(ucode -L "$TACHYON_LIB" -- "$EXPLAIN_UC" explain 192.168.1.100 instagram.com 443 tcp --json)
  assert_contains "$cli_json" '"success": true' "JSON success"
  assert_contains "$cli_json" '"target": "instagram.com"' "JSON target"
  assert_contains "$cli_json" '"stages":' "JSON stages"
  assert_contains "$cli_json" '"1_client_classification":' "JSON stage 1"
  assert_contains "$cli_json" '"7_engine_outbound":' "JSON stage 7"

  # 4.4 URL and Port parsing
  cli_url=$(ucode -L "$TACHYON_LIB" -- "$EXPLAIN_UC" explain "" "https://test.site.org:8443/api" 0 tcp --json)
  assert_contains "$cli_url" '"target": "test.site.org"' "Target host parsed from URL"
  assert_contains "$cli_url" '"port": 8443' "Port parsed from URL"

  # 4.5 Execution via /usr/bin/tachyon wrapper
  tachyon_out=$(TACHYON_LIB="$TACHYON_LIB" ucode "$BIN_TACHYON" route_explain 192.168.1.50 github.com 443)
  assert_contains "$tachyon_out" "TACHYON ROUTE DECISION EXPLAINER" "tachyon binary route_explain execution"

  # 4.6 Execution via diagnostics/runtime.uc facade
  runtime_out=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" route-explain 192.168.1.50 github.com 443)
  assert_contains "$runtime_out" "TACHYON ROUTE DECISION EXPLAINER" "runtime.uc route-explain facade execution"

  # 4.7 Execution via service/agent_api.uc endpoint
  agent_out=$(TACHYON_LIB="$TACHYON_LIB" ucode "$BIN_TACHYON" agent "/tachyon/agent/v1/route/explain?target=github.com&client=192.168.1.50" GET)
  assert_contains "$agent_out" '"success": true' "agent_api route/explain success"
  assert_contains "$agent_out" '"target": "github.com"' "agent_api route/explain target"
fi

echo "All route_explain tests passed successfully!"
