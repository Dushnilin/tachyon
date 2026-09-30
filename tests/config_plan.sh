#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PLAN_UC="$TACHYON_LIB/service/config_plan.uc"
API_UC="$TACHYON_LIB/service/api.uc"
AGENT_API_UC="$TACHYON_LIB/service/agent_api.uc"
AGENT_MCP_UC="$TACHYON_LIB/service/agent_mcp.uc"
BIN_TACHYON="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected to contain '$needle', got: $haystack" ;;
  esac
}

# --- 1. Static Contract Inspections ---

[ -f "$PLAN_UC" ] || fail "service/config_plan.uc must exist"

grep -Fq 'function plan(' "$PLAN_UC" ||
  fail "config_plan.uc must define plan"
grep -Fq 'function compute_uci_diff(' "$PLAN_UC" ||
  fail "config_plan.uc must define compute_uci_diff"
grep -Fq 'function analyze_subsystem_impact(' "$PLAN_UC" ||
  fail "config_plan.uc must define analyze_subsystem_impact"
grep -Fq 'function validate_uci_semantics(' "$PLAN_UC" ||
  fail "config_plan.uc must define validate_uci_semantics"
grep -Fq 'function check_candidate_port_collisions(' "$PLAN_UC" ||
  fail "config_plan.uc must define check_candidate_port_collisions"
grep -Fq 'function load_candidate_uci(' "$PLAN_UC" ||
  fail "config_plan.uc must define load_candidate_uci"
grep -Fq 'function parse_uci_text_to_dict(' "$PLAN_UC" ||
  fail "config_plan.uc must define parse_uci_text_to_dict"
grep -Fq 'function format_text_plan(' "$PLAN_UC" ||
  fail "config_plan.uc must define format_text_plan"
grep -Fq 'function selftest()' "$PLAN_UC" ||
  fail "config_plan.uc must define selftest"

# Wiring in /usr/bin/tachyon
grep -Fq 'config_plan: [ "service/config_plan.uc", "plan", 2 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map config_plan"
grep -Fq '"config-plan": [ "service/config_plan.uc", "plan", 2 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map config-plan"
grep -Fq 'config_validate: [ "service/config_plan.uc", "validate", 1 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map config_validate"
grep -Fq '"config-validate": [ "service/config_plan.uc", "validate", 1 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map config-validate"

# Wiring in service/api.uc
grep -Fq 'function get_config_plan(' "$API_UC" ||
  fail "service/api.uc must define get_config_plan"
grep -Fq 'get_config_plan' "$API_UC" ||
  fail "service/api.uc must export get_config_plan"

# Wiring in service/agent_api.uc
grep -Fq 'handle_config_plan' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must define handle_config_plan"
grep -Fq 'tachyon_config_plan' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must register tachyon_config_plan tool"
grep -Fq '/config/plan' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must route /config/plan endpoint"

# Wiring in service/agent_mcp.uc
grep -Fq 'tachyon_config_plan' "$AGENT_MCP_UC" ||
  fail "service/agent_mcp.uc must register tachyon_config_plan tool"
grep -Fq 'execute_config_plan' "$AGENT_MCP_UC" ||
  fail "service/agent_mcp.uc must define execute_config_plan"

# --- 2. Ucode Syntax and Forward Reference Checks ---

if command -v node >/dev/null 2>&1 && [ -f "$ROOT_DIR/tests/lib/ucode_forward_refs.js" ]; then
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$PLAN_UC" ||
    fail "forward reference lint failed for config_plan.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$AGENT_API_UC" ||
    fail "forward reference lint failed for agent_api.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$AGENT_MCP_UC" ||
    fail "forward reference lint failed for agent_mcp.uc"
fi

if command -v ucode >/dev/null 2>&1; then
  ucode -c "$PLAN_UC" || fail "ucode -c failed for config_plan.uc"
  ucode -S -c "$PLAN_UC" || fail "ucode -S -c failed for config_plan.uc"

  # --- 3. Built-in Selftest ---
  selftest_output=$(ucode -L "$TACHYON_LIB" -- "$PLAN_UC" selftest)
  assert_contains "$selftest_output" "passed" "selftest output"
  assert_contains "$selftest_output" "0 failed" "selftest zero failures"

  # --- 4. CLI Execution Checks ---

  # 4.1 Plain text plan against active
  cli_text=$(ucode -L "$TACHYON_LIB" -- "$PLAN_UC" plan)
  assert_contains "$cli_text" "TACHYON CONFIGURATION PLAN" "CLI text banner"
  assert_contains "$cli_text" "Status:   [VALID]" "CLI text status"

  # 4.2 JSON plan against active
  cli_json=$(ucode -L "$TACHYON_LIB" -- "$PLAN_UC" plan --json)
  assert_contains "$cli_json" '"success": true' "CLI JSON success"
  assert_contains "$cli_json" '"valid": true' "CLI JSON valid"

  # 4.3 Candidate config file with addition & modification
  TMP_CANDIDATE=$(mktemp)
  cat <<'EOF' > "$TMP_CANDIDATE"
config settings 'settings'
	option engine 'sing-box'
	option fakeip '1'
	option mixed_port '4534'

config section 'test_addition'
	option action 'proxy'
	list domain 'youtube.com'
	list domain 'googlevideo.com'
EOF

  cand_plan=$(ucode -L "$TACHYON_LIB" -- "$PLAN_UC" plan "$TMP_CANDIDATE" --json)
  assert_contains "$cand_plan" '"success": true' "Candidate JSON success"
  assert_contains "$cand_plan" 'test_addition' "Candidate JSON added section detected"

  # 4.4 Candidate with invalid parameters (validate subcommand)
  TMP_BAD=$(mktemp)
  cat <<'EOF' > "$TMP_BAD"
config section 'broken_section'
	option action 'invalid_nonexistent_action'
	option port '99999'
EOF

  if ucode -L "$TACHYON_LIB" -- "$PLAN_UC" validate "$TMP_BAD" >/dev/null 2>&1; then
    fail "validate should have returned non-zero for invalid action and port"
  fi

  rm -f "$TMP_CANDIDATE" "$TMP_BAD"
fi

printf 'ALL CONFIG PLAN CHECKS PASSED\n'
