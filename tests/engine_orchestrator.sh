#!/bin/bash
# Tests for core/engine.uc and components/engine_state.uc — the multi-core
# routing-engine orchestrator.
#
# Verifies:
#   - engine registry and capability matrix
#   - feature -> unsupported mapping for a switch
#   - switch plan parks configuration the target engine cannot express
#   - switching back restores what was parked
#   - switch is refused when the target engine is not installed
#   - UCI option read/write through the fixture backend

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$SCRIPT_DIR/../tachyon/files/usr/lib}"
TACHYON_UCODE="${TACHYON_UCODE:-ucode}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

pass=0
fail=0

fail_test() {
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail_test "$label: expected '$expected', got '$actual'"
    fi
}

assert_true() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
    else
        fail_test "$label: command failed: $*"
    fi
}

assert_match() {
    local label="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        pass=$((pass + 1))
    else
        fail_test "$label: expected pattern '$pattern', got '$actual'"
    fi
}

run_uc() {
    $TACHYON_UCODE -L "$TACHYON_LIB" -e "$1" 2>&1
}

# ---------------------------------------------------------------------------
# Engine registry and capability matrix
# ---------------------------------------------------------------------------

printf '%s\n' '--- engine registry ---'
out="$(run_uc '
let e = require("core.engine");
let known = e.known_engines();
print("count=" + length(known) + "\n");
print("has_singbox=" + e.engine_is_known("sing-box") + "\n");
print("has_steer=" + e.engine_is_known("steer") + "\n");
print("has_ext=" + e.engine_is_known("steer-extended") + "\n");
print("has_bogus=" + e.engine_is_known("nonsense") + "\n");
')"
assert_match "registry lists engines" 'count=3' "$out"
assert_match "sing-box is known" 'has_singbox=true' "$out"
assert_match "steer is known" 'has_steer=true' "$out"
assert_match "steer-extended is known" 'has_ext=true' "$out"
assert_match "unknown engine rejected" 'has_bogus=false' "$out"

printf '%s\n' '--- capability matrix ---'
out="$(run_uc '
let e = require("core.engine");
print("sb_sub=" + e.supports("sing-box", "sections.subscription") + "\n");
print("sb_vless=" + e.supports("sing-box", "outbound.vless_reality") + "\n");
print("steer_sub=" + e.supports("steer", "sections.subscription") + "\n");
print("steer_fit=" + e.supports("steer", "list_memory_fit") + "\n");
print("ext_vless=" + e.supports("steer-extended", "outbound.vless_reality") + "\n");
print("ext_sub=" + e.supports("steer-extended", "sections.subscription") + "\n");
')"
assert_match "sing-box supports subscriptions" 'sb_sub=true' "$out"
assert_match "sing-box supports vless" 'sb_vless=true' "$out"
assert_match "steer cannot express subscriptions" 'steer_sub=false' "$out"
assert_match "steer supports list fit" 'steer_fit=true' "$out"
assert_match "steer-extended supports vless" 'ext_vless=true' "$out"
assert_match "steer-extended cannot express subscriptions" 'ext_sub=false' "$out"

printf '%s\n' '--- unsupported feature mapping ---'
out="$(run_uc '
let e = require("core.engine");
let feats = [ "sections.subscription", "routing.domain_lists", "outbound.vless_reality", "list_memory_fit" ];
let to_steer = e.unsupported_features("steer", feats);
print("to_steer=" + join(",", to_steer) + "\n");
let to_sb = e.unsupported_features("sing-box", feats);
print("to_sb=" + join(",", to_sb) + "\n");
let summary = e.unsupported_summary("sing-box", "steer", feats);
print("loses=" + summary.loses_features + "\n");
')"
assert_match "steer parks subscription" 'to_steer=sections.subscription' "$out"
assert_match "steer parks vless" 'to_steer=.*outbound.vless_reality' "$out"
assert_match "sing-box parks fit" 'to_sb=list_memory_fit' "$out"
assert_match "switch reports feature loss" 'loses=true' "$out"

# ---------------------------------------------------------------------------
# Switch plan: park and restore
# ---------------------------------------------------------------------------

printf '%s\n' '--- switch plan parks incompatible config ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" run_uc '
let e = require("core.engine");
let feats = [ "sections.subscription", "routing.domain_lists" ];
let plan = e.plan_switch("steer", feats);
print("from=" + plan.from_engine + "\n");
print("to=" + plan.to_engine + "\n");
print("unsupported=" + join(",", plan.unsupported) + "\n");
print("parked_sub=" + (plan.parked["sections.subscription"] != null) + "\n");
print("parked_domains=" + (plan.parked["routing.domain_lists"] != null) + "\n");
')"
assert_match "plan from sing-box" 'from=sing-box' "$out"
assert_match "plan to steer" 'to=steer' "$out"
assert_match "plan parks subscription" 'parked_sub=true' "$out"
assert_match "plan parks only incompatible" 'parked_domains=false' "$out"

printf '%s\n' '--- parked payload round-trips through UCI ---'
out="$(TACHYON_UCI_STATE_FILE="$WORK_DIR/uci2.state" run_uc '
let e = require("core.engine");
e.write_parked("steer", { "sections.subscription": "main" });
let back = e.read_parked("steer");
print("restored=" + back["sections.subscription"] + "\n");
')"
assert_match "parked payload restores" 'restored=main' "$out"

# ---------------------------------------------------------------------------
# Module selftests
# ---------------------------------------------------------------------------

printf '%s\n' '--- steer contract facts ---'
out="$(run_uc '
let e = require("core.engine");
print("spec=" + e.STEER_SPEC_FILE + "\n");
print("state=" + e.STEER_STATE_DIR + "\n");
print("table=" + e.STEER_NFT_TABLE + "\n");
print("cmds=" + length(e.STEER_REQUIRED_COMMANDS) + "\n");
print("keep=" + length(e.STEER_KEEP_PATHS) + "\n");
print("ready=" + e.steer_contract_ready() + "\n");
')"
assert_match "steer spec path" 'spec=/etc/steer/spec.json' "$out"
assert_match "steer state dir" 'state=/var/lib/steer' "$out"
assert_match "steer nft table isolated" 'table=inet steer' "$out"
assert_match "steer contract commands listed" 'cmds=7' "$out"
assert_match "steer keep paths listed" 'keep=4' "$out"
assert_match "contract not ready without engine" 'ready=false' "$out"

printf '%s\n' '--- CLI info surface ---'
out="$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/service/engine_runtime.uc" engine-info 2>&1)"
assert_match "engine-info reports active engine" '"active": *"sing-box"' "$out"
assert_match "engine-info lists engines" '"engine": *"steer"' "$out"

out="$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/service/engine_runtime.uc" engine-plan steer 2>&1)"
assert_match "engine-plan targets steer" '"to_engine": *"steer"' "$out"

out="$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/service/engine_runtime.uc" engine-diag 2>&1 || true)"
assert_match "engine-diag refuses without engine" 'engine_not_installed|not installed|No such file' "$out"

printf '\n--- engine_orchestrator.sh summary ---\n'
printf 'passed: %d\n' "$pass"
printf 'failed: %d\n' "$fail"

if [ "$fail" -gt 0 ]; then
    printf '%s\n' '--- FAIL ---'
    exit 1
fi

printf '%s\n' '--- PASS ---'
exit 0
