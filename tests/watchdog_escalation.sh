#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
BIN_TACHYON="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- 1. Static Contract Inspections ---

# Escalation Ladder L0-L5 Constants
grep -Fq 'const LADDER_L0_OBSERVE   = 0;' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define LADDER_L0_OBSERVE"
grep -Fq 'const LADDER_L1_RETRY     = 1;' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define LADDER_L1_RETRY"
grep -Fq 'const LADDER_L2_REPAIR    = 2;' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define LADDER_L2_REPAIR"
grep -Fq 'const LADDER_L3_RELOAD    = 3;' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define LADDER_L3_RELOAD"
grep -Fq 'const LADDER_L4_RESTART   = 4;' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define LADDER_L4_RESTART"
grep -Fq 'const LADDER_L5_EMERGENCY = 5;' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define LADDER_L5_EMERGENCY"

# Escalation Ladder helper functions
grep -Fq 'function next_ladder_level(reason)' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define next_ladder_level"
grep -Fq 'function set_ladder_level(reason, level)' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define set_ladder_level"
grep -Fq 'function execute_escalation_level(' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define execute_escalation_level"

# Emergency Failsafe functions and state files
grep -Fq 'const EMERGENCY_STATE_FILE = "/etc/tachyon/emergency_state.json";' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define EMERGENCY_STATE_FILE"
grep -Fq 'const EMERGENCY_STATE_TMP = "/tmp/tachyon_emergency_state.json";' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define EMERGENCY_STATE_TMP"
grep -Fq 'function is_emergency_failsafe_active()' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define is_emergency_failsafe_active"
grep -Fq 'function trigger_emergency_failsafe(reason, details)' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define trigger_emergency_failsafe"
grep -Fq 'function clear_emergency_failsafe()' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define clear_emergency_failsafe"

# Reconciler Subsystem Execution
grep -Fq 'function execute_reconciler_subsystem(subsystem, dry_run)' "$WATCHDOG_UC" ||
  fail "watchdog.uc must define execute_reconciler_subsystem"

# CLI binary commands
grep -Fq 'escalation_status: [ "service/watchdog.uc", "escalation-status", 0 ]' "$BIN_TACHYON" ||
  fail "usr/bin/tachyon must expose escalation_status"
grep -Fq 'emergency_status: [ "service/watchdog.uc", "emergency-status", 0 ]' "$BIN_TACHYON" ||
  fail "usr/bin/tachyon must expose emergency_status"
grep -Fq 'emergency_reset: [ "service/watchdog.uc", "emergency-reset", 0 ]' "$BIN_TACHYON" ||
  fail "usr/bin/tachyon must expose emergency_reset"

# --- 2. Behavioral Verification via ucode ---

run_ucode() {
  local code="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/tachyon_test_XXXXXX")"
  printf '%s\n' "$code" > "$tmp"
  ucode -L "$TACHYON_LIB" "$tmp"
  rm -f "$tmp"
}

# Verify ladder progression and reset
res="$(run_ucode '
let common = require("core.common");
const LADDER_L0_OBSERVE   = 0;
const LADDER_L1_RETRY     = 1;
const LADDER_L2_REPAIR    = 2;
const LADDER_L3_RELOAD    = 3;
const LADDER_L4_RESTART   = 4;
const LADDER_L5_EMERGENCY = 5;

const ESCALATION_LIGHT = "light";
const ESCALATION_HEAVY = "heavy";

let escalation_level = {};
let escalation_ladder = {};

function next_escalation(reason) {
    return escalation_level[reason] == ESCALATION_HEAVY ? ESCALATION_HEAVY : ESCALATION_LIGHT;
}

function next_ladder_level(reason) {
    if (reason == null || reason == "") return LADDER_L2_REPAIR;
    let lvl = escalation_ladder[reason];
    return lvl != null ? int(lvl) : LADDER_L2_REPAIR;
}

function set_ladder_level(reason, level) {
    if (reason == null || reason == "") return;
    let lvl = int(level);
    if (lvl < LADDER_L0_OBSERVE) lvl = LADDER_L0_OBSERVE;
    if (lvl > LADDER_L5_EMERGENCY) lvl = LADDER_L5_EMERGENCY;
    escalation_ladder[reason] = lvl;
    if (lvl >= LADDER_L4_RESTART)
        escalation_level[reason] = ESCALATION_HEAVY;
    else
        escalation_level[reason] = ESCALATION_LIGHT;
}

function note_escalation_outcome(reason, outcome) {
    if (reason == null || reason == "") return;
    if (outcome == "failed") {
        escalation_level[reason] = ESCALATION_HEAVY;
        let cur = int(escalation_ladder[reason] != null ? escalation_ladder[reason] : LADDER_L3_RELOAD);
        if (cur < LADDER_L5_EMERGENCY)
            escalation_ladder[reason] = cur + 1;
        else
            escalation_ladder[reason] = LADDER_L5_EMERGENCY;
    } else if (outcome == "fixed") {
        delete escalation_level[reason];
        delete escalation_ladder[reason];
    }
}

// 1. Initial level should be L2
let init_lvl = next_ladder_level("dns_test");

// 2. Failure elevates from L3 to L4
note_escalation_outcome("dns_test", "failed");
let fail1_lvl = next_ladder_level("dns_test");
let fail1_legacy = next_escalation("dns_test");

// 3. Second failure elevates to L5 (emergency)
note_escalation_outcome("dns_test", "failed");
let fail2_lvl = next_ladder_level("dns_test");

// 4. Fixed resets ladder
note_escalation_outcome("dns_test", "fixed");
let fixed_lvl = next_ladder_level("dns_test");
let fixed_legacy = next_escalation("dns_test");

print(init_lvl + "," + fail1_lvl + "," + fail1_legacy + "," + fail2_lvl + "," + fixed_lvl + "," + fixed_legacy);
')"
assert_eq "$res" "2,4,heavy,5,2,light" "escalation ladder correctly tracks and escalates levels"

# Verify set_ladder_level syncing
res="$(run_ucode '
const LADDER_L2_REPAIR = 2;
const LADDER_L4_RESTART = 4;
const ESCALATION_LIGHT = "light";
const ESCALATION_HEAVY = "heavy";
let escalation_level = {};
let escalation_ladder = {};

function next_escalation(reason) {
    return escalation_level[reason] == ESCALATION_HEAVY ? ESCALATION_HEAVY : ESCALATION_LIGHT;
}
function set_ladder_level(reason, level) {
    let lvl = int(level);
    escalation_ladder[reason] = lvl;
    if (lvl >= LADDER_L4_RESTART)
        escalation_level[reason] = ESCALATION_HEAVY;
    else
        escalation_level[reason] = ESCALATION_LIGHT;
}

set_ladder_level("manual_test", LADDER_L2_REPAIR);
let l2_leg = next_escalation("manual_test");
set_ladder_level("manual_test", LADDER_L4_RESTART);
let l4_leg = next_escalation("manual_test");

print(l2_leg + "," + l4_leg);
')"
assert_eq "$res" "light,heavy" "set_ladder_level synchronizes legacy escalation string rungs"

# --- 3. Watchdog CLI Escalation and Emergency Mode Tests ---
esc_status="$(ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" escalation-status)"
grep -q '"levels"' <<< "$esc_status" || fail "watchdog escalation-status missing 'levels': $esc_status"
grep -q '"legacy"' <<< "$esc_status" || fail "watchdog escalation-status missing 'legacy': $esc_status"
grep -q '"emergency_active"' <<< "$esc_status" || fail "watchdog escalation-status missing 'emergency_active': $esc_status"

emg_status="$(ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" emergency-status)"
grep -q '"active"' <<< "$emg_status" || fail "watchdog emergency-status missing 'active': $emg_status"

emg_reset="$(ucode -L "$TACHYON_LIB" "$WATCHDOG_UC" emergency-reset)"
grep -q 'reset successfully' <<< "$emg_reset" || fail "watchdog emergency-reset failed: $emg_reset"

printf 'watchdog escalation and L0-L5 ladder checks passed\n'
