#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
KG_UC="$TACHYON_LIB/service/known_good.uc"
RECONCILER_UC="$TACHYON_LIB/service/reconciler.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
API_UC="$TACHYON_LIB/service/api.uc"
AGENT_API_UC="$TACHYON_LIB/service/agent_api.uc"
AGENT_MCP_UC="$TACHYON_LIB/service/agent_mcp.uc"
BIN_TACHYON="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected to contain '$needle', got: $haystack" ;;
  esac
}

# --- 1. Static Contract Inspections ---

[ -f "$KG_UC" ] || fail "service/known_good.uc must exist"

grep -Fq 'function has_known_good(' "$KG_UC" ||
  fail "known_good.uc must define has_known_good"
grep -Fq 'function get_known_good_manifest(' "$KG_UC" ||
  fail "known_good.uc must define get_known_good_manifest"
grep -Fq 'function get_status(' "$KG_UC" ||
  fail "known_good.uc must define get_status"
grep -Fq 'function format_text_status(' "$KG_UC" ||
  fail "known_good.uc must define format_text_status"
grep -Fq 'function promote(' "$KG_UC" ||
  fail "known_good.uc must define promote"
grep -Fq 'function rollback_to_known_good(' "$KG_UC" ||
  fail "known_good.uc must define rollback_to_known_good"
grep -Fq 'function start_observation(' "$KG_UC" ||
  fail "known_good.uc must define start_observation"
grep -Fq 'function check_observation(' "$KG_UC" ||
  fail "known_good.uc must define check_observation"
grep -Fq 'function get_history(' "$KG_UC" ||
  fail "known_good.uc must define get_history"
grep -Fq 'function selftest()' "$KG_UC" ||
  fail "known_good.uc must define selftest"
grep -Fq 'function set_test_overrides(' "$KG_UC" ||
  fail "known_good.uc must define set_test_overrides"

# Wiring in /usr/bin/tachyon
grep -Fq 'known_good: [ "service/known_good.uc", "status", 2 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map known_good"
grep -Fq '"known-good": [ "service/known_good.uc", "status", 2 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map known-good"
grep -Fq 'known_good_promote: [ "service/known_good.uc", "promote", 1 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map known_good_promote"
grep -Fq 'known_good_restore: [ "service/known_good.uc", "restore", 1 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map known_good_restore"
grep -Fq 'known_good_check: [ "service/known_good.uc", "check", 0 ]' "$BIN_TACHYON" ||
  fail "/usr/bin/tachyon must map known_good_check"

# Wiring in service/reconciler.uc
grep -Fq 'require("service.known_good")' "$RECONCILER_UC" ||
  fail "service/reconciler.uc must import service.known_good"
grep -Fq 'known_good.check_observation' "$RECONCILER_UC" ||
  fail "service/reconciler.uc must hook check_observation"
grep -Fq 'known_good.rollback_to_known_good' "$RECONCILER_UC" ||
  fail "service/reconciler.uc must hook rollback_to_known_good on critical failure"

# Wiring in service/watchdog.uc
grep -Fq 'require("service.known_good")' "$WATCHDOG_UC" ||
  fail "service/watchdog.uc must import service.known_good"
grep -Fq 'check_known_good_observation' "$WATCHDOG_UC" ||
  fail "service/watchdog.uc must define check_known_good_observation"
grep -Fq 'rollback_to_known_good' "$WATCHDOG_UC" ||
  fail "service/watchdog.uc must attempt rollback before L5 emergency failsafe"

# Wiring in service/api.uc
grep -Fq 'get_known_good_status' "$API_UC" ||
  fail "service/api.uc must export get_known_good_status"
grep -Fq 'promote_known_good' "$API_UC" ||
  fail "service/api.uc must export promote_known_good"
grep -Fq 'rollback_known_good' "$API_UC" ||
  fail "service/api.uc must export rollback_known_good"
grep -Fq 'check_known_good_observation' "$API_UC" ||
  fail "service/api.uc must export check_known_good_observation"

# Wiring in service/agent_api.uc
grep -Fq 'handle_known_good_status' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must define handle_known_good_status"
grep -Fq 'handle_known_good_promote' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must define handle_known_good_promote"
grep -Fq 'handle_known_good_rollback' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must define handle_known_good_rollback"
grep -Fq 'tachyon_known_good' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must register tachyon_known_good tool"
grep -Fq '/known-good' "$AGENT_API_UC" ||
  fail "service/agent_api.uc must route /known-good endpoint"

# Wiring in service/agent_mcp.uc
grep -Fq 'tachyon_known_good' "$AGENT_MCP_UC" ||
  fail "service/agent_mcp.uc must register tachyon_known_good tool"
grep -Fq 'execute_known_good' "$AGENT_MCP_UC" ||
  fail "service/agent_mcp.uc must define execute_known_good"

# --- 2. Ucode Syntax and Forward Reference Checks ---

if command -v node >/dev/null 2>&1 && [ -f "$ROOT_DIR/tests/lib/ucode_forward_refs.js" ]; then
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$KG_UC" ||
    fail "forward reference lint failed for known_good.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$RECONCILER_UC" ||
    fail "forward reference lint failed for reconciler.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$WATCHDOG_UC" ||
    fail "forward reference lint failed for watchdog.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$API_UC" ||
    fail "forward reference lint failed for api.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$AGENT_API_UC" ||
    fail "forward reference lint failed for agent_api.uc"
  node "$ROOT_DIR/tests/lib/ucode_forward_refs.js" "$AGENT_MCP_UC" ||
    fail "forward reference lint failed for agent_mcp.uc"
fi

if command -v ucode >/dev/null 2>&1; then
  ucode -c "$KG_UC" || fail "ucode -c failed for known_good.uc"
  ucode -S -c "$KG_UC" || fail "ucode -S -c failed for known_good.uc"

  # --- 3. Built-in Selftest ---
  selftest_output=$(ucode -L "$TACHYON_LIB" -- "$KG_UC" selftest)
  assert_contains "$selftest_output" "passed" "selftest output"
  assert_contains "$selftest_output" "0 failed" "selftest zero failures"

  # --- 4. CLI Execution Checks ---

  # 4.1 Plain text status
  status_text=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -- "$BIN_TACHYON" known_good)
  assert_contains "$status_text" "TACHYON LAST KNOWN GOOD" "CLI plain text status banner"

  # 4.2 JSON status
  status_json=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -- "$BIN_TACHYON" known_good --json)
  assert_contains "$status_json" '"has_known_good":' "CLI JSON status key"
  assert_contains "$status_json" '"observation":' "CLI JSON observation key"

  # 4.3 Check observation CLI
  check_json=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -- "$BIN_TACHYON" known_good check)
  assert_contains "$check_json" '"status":' "CLI check status key"

  # --- 5. Full Lifecycle Integration Verification in Isolated Sandbox ---

  sandbox_test=$(ucode -L "$TACHYON_LIB" -e '
    let fs = require("fs");
    let kg = require("service.known_good");

    let tmp_dir = "/tmp/test_kg_suite_" + sprintf("%d", time());
    let kg_dir = tmp_dir + "/state";
    let obs_file = tmp_dir + "/obs.json";
    let cfg_file = tmp_dir + "/tachyon";

    system("mkdir -p " + tmp_dir);
    fs.writefile(cfg_file, "config settings\n\toption test 1\n");

    kg.set_test_overrides(kg_dir, obs_file, cfg_file);

    // Initial state: no known good
    let st0 = kg.get_status();
    if (st0.has_known_good != false) {
      print("FAIL: initial has_known_good should be false\n");
      exit(1);
    }

    // Step 1: Promote config
    let p_res = kg.promote("test_suite_bless");
    if (!p_res.ok || !p_res.success) {
      print("FAIL: promote failed: " + (p_res.error || "unknown") + "\n");
      exit(1);
    }

    // Verify manifest and state
    let st1 = kg.get_status();
    if (!st1.has_known_good || !st1.is_active_config_known_good) {
      print("FAIL: status after promote is invalid\n");
      exit(1);
    }

    // Step 2: Mutate active config
    fs.writefile(cfg_file, "config settings\n\toption test 2\n\toption bad_change 1\n");
    let st2 = kg.get_status();
    if (st2.is_active_config_known_good != false) {
      print("FAIL: active config should now differ from LKG\n");
      exit(1);
    }

    // Step 3: Start observation window
    let obs_res = kg.start_observation("config_applied", 30);
    if (!obs_res.is_observing) {
      print("FAIL: start_observation should start observing\n");
      exit(1);
    }

    // Step 4: Rollback to Known Good
    let rb_res = kg.rollback_to_known_good("bad_change_revert", { reload: false });
    if (!rb_res.ok || !rb_res.success) {
      print("FAIL: rollback failed: " + (rb_res.error || "unknown") + "\n");
      exit(1);
    }

    // Verify config is restored
    let cur_cfg = fs.readfile(cfg_file);
    if (index(cur_cfg, "option test 1") < 0) {
      print("FAIL: config was not restored to test 1\n");
      exit(1);
    }
    if (index(cur_cfg, "bad_change") >= 0) {
      print("FAIL: bad_change was not removed\n");
      exit(1);
    }

    // Verify failing config was backed up for diagnostics
    let failed_backup = fs.readfile(kg_dir + "/last_failed_config");
    if (index(failed_backup, "bad_change") < 0) {
      print("FAIL: failed config was not saved for forensics\n");
      exit(1);
    }

    // Step 5: Test loop guard (redundant rollback rejected)
    let loop_res = kg.rollback_to_known_good("redundant", { reload: false });
    if (loop_res.ok != false || loop_res.success != false) {
      print("FAIL: loop guard failed to reject redundant rollback\n");
      exit(1);
    }

    // Step 6: Verify history was appended
    let hist = kg.get_history();
    if (length(hist) < 2) {
      print("FAIL: history should have at least 2 events\n");
      exit(1);
    }

    // Clean up
    system("rm -rf " + tmp_dir);
    kg.set_test_overrides(null, null, null);

    print("OK: Sandbox lifecycle passed\n");
    exit(0);
  ')

  assert_contains "$sandbox_test" "OK: Sandbox lifecycle passed" "Sandbox lifecycle"
fi

printf 'ALL KNOWN GOOD CHECKS PASSED\n'
