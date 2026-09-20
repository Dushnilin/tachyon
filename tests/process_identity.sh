#!/bin/bash
# Tests for core/process.uc — unified process identity module.
#
# Verifies:
#   - boot_id reading and caching
#   - process_starttime (field 22 from /proc/PID/stat)
#   - process_start_ticks (from raw stat content)
#   - process_age_seconds (age calculation)
#   - pid_alive_raw (kill -0 check)
#   - is_tachyon_process (PID + cmdline check)
#   - is_sing_box (exe/comm check)
#   - make_identity (identity object creation)
#   - identity_matches (PID recycling guard)
#   - identity_alive (combined check)
#   - CLI subcommands (selftest, boot-id, starttime, age, alive)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$SCRIPT_DIR/../tachyon/files/usr/lib}"
TACHYON_UCODE="${TACHYON_UCODE:-ucode}"

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

assert_false() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail_test "$label: command succeeded but expected failure: $*"
    else
        pass=$((pass + 1))
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

# ---------------------------------------------------------------------------
# Run module selftest
# ---------------------------------------------------------------------------

printf '%s\n' '--- process.uc selftest ---'
if $TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" selftest; then
    pass=$((pass + 1))
else
    fail_test "process.uc selftest failed"
fi

# ---------------------------------------------------------------------------
# CLI subcommands
# ---------------------------------------------------------------------------

printf '%s\n' '--- boot-id ---'
BOOT_ID=$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" boot-id)
assert_true "boot-id should be non-empty" test -n "$BOOT_ID"
assert_match "boot-id should look like UUID" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$BOOT_ID"

printf '%s\n' '--- starttime ---'
SELF_PID=$$
STARTTIME=$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" starttime "$SELF_PID")
assert_true "starttime for self should be readable" test -n "$STARTTIME"
assert_match "starttime should be numeric" '^[0-9]+$' "$STARTTIME"

# Nonexistent PID should fail
assert_false "starttime for nonexistent PID should fail" $TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" starttime 999999

printf '%s\n' '--- age ---'
AGE=$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" age "$SELF_PID")
assert_true "age for self should be readable" test -n "$AGE"
assert_match "age should be numeric" '^[0-9]+$' "$AGE"

# Nonexistent PID should fail
assert_false "age for nonexistent PID should fail" $TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" age 999999

printf '%s\n' '--- alive ---'
# Current process should be alive
$TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" alive "$SELF_PID" && pass=$((pass + 1)) || fail_test "self should be alive"

# Nonexistent PID should not be alive
$TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/process.uc" alive 999999 && fail_test "nonexistent PID should not be alive" || pass=$((pass + 1))

# ---------------------------------------------------------------------------
# Runtime tests: PID identity via ucode require
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: make_identity + identity_matches ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let proc = require("core.process");
let fs = require("fs");
let self_stat = trim("" + fs.readfile("/proc/self/stat"));
let self_pid = substr(self_stat, 0, index(self_stat, " "));
let id = proc.make_identity(self_pid, "test-worker");
assert(id.pid == self_pid, "pid should match");
assert(id.command == "test-worker", "command should match");
assert(id.boot_id != null && id.boot_id != "", "boot_id should be non-empty");
assert(id.starttime != null, "starttime should be non-empty");
assert(id.created_at != null, "created_at should be set");
assert(proc.identity_matches(id, self_pid), "identity should match self");
assert(!proc.identity_matches(id, "999999"), "identity should not match nonexistent");
assert(proc.identity_alive(id), "identity should be alive");
print("PASS\n");

function assert(cond, msg) {
    if (!cond) { warn("ASSERT FAILED: " + msg + "\n"); exit(1); }
}
' 2>&1)
assert_eq "runtime identity test" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: pid_alive_raw
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: pid_alive_raw ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let proc = require("core.process");
let fs = require("fs");
let self_stat = trim("" + fs.readfile("/proc/self/stat"));
let self_pid = substr(self_stat, 0, index(self_stat, " "));
let r1 = proc.pid_alive_raw(self_pid);
let r2 = proc.pid_alive_raw("999999");
let r3 = proc.pid_alive_raw("abc");
if (r1 && !r2 && !r3)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " r3=" + r3 + "\n");
' 2>&1)
assert_eq "pid_alive_raw test" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: process_starttime from raw stat
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: process_start_ticks from raw stat ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let proc = require("core.process");
let fs = require("fs");
let self_stat = trim("" + fs.readfile("/proc/self/stat"));
let ticks = proc.process_start_ticks(self_stat);
if (ticks != null && type(ticks) == "int" && ticks > 0)
    print("PASS\n");
else
    print("FAIL: ticks=" + ticks + "\n");
' 2>&1)
assert_eq "process_start_ticks from raw stat" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: age calculation
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: process_age_seconds_from_ticks ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let proc = require("core.process");
let age1 = proc.process_age_seconds_from_ticks(100, 600);
let age2 = proc.process_age_seconds_from_ticks(100, 50);
let age3 = proc.process_age_seconds_from_ticks("abc", "100");
if (age1 == 5 && age2 == null && age3 == null)
    print("PASS\n");
else
    print("FAIL: age1=" + age1 + " age2=" + age2 + " age3=" + age3 + "\n");
' 2>&1)
assert_eq "age calculation test" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: is_sing_box
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: is_sing_box ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let proc = require("core.process");
let fs = require("fs");
let self_stat = trim("" + fs.readfile("/proc/self/stat"));
let self_pid = substr(self_stat, 0, index(self_stat, " "));
// Nonexistent PID should not be sing-box
let r1 = proc.is_sing_box("999999");
// Current process is not sing-box
let r2 = proc.is_sing_box(self_pid);
if (!r1 && !r2)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + "\n");
' 2>&1)
assert_eq "is_sing_box test" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: is_tachyon_process
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: is_tachyon_process ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let proc = require("core.process");
// Nonexistent PID should not be tachyon process
let r1 = proc.is_tachyon_process("999999");
// Non-numeric PID should not be tachyon process
let r2 = proc.is_tachyon_process("abc");
if (!r1 && !r2)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + "\n");
' 2>&1)
assert_eq "is_tachyon_process test" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: boot_id consistency across modules
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: boot_id consistency exec <-> process ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let exec = require("core.exec");
let proc = require("core.process");
let b1 = exec.boot_id();
let b2 = proc.boot_id();
if (b1 == b2 && b1 != null && b1 != "")
    print("PASS\n");
else
    print("FAIL: b1=" + b1 + " b2=" + b2 + "\n");
' 2>&1)
assert_eq "boot_id consistency" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: exec.run_background returns identity
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: exec.run_background identity ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let exec = require("core.exec");
let result = exec.run_background({ command: "sleep 30", name: "test-bg" });
if (result.identity != null && result.identity.pid != null && result.identity.pid != "0") {
    // Clean up
    exec.kill_process(result.pid, 1);
    print("PASS\n");
} else {
    print("FAIL: identity=" + result.identity + "\n");
}
' 2>&1)
assert_eq "exec.run_background identity" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n--- process_identity.sh summary ---\n'
printf 'passed: %d\n' "$pass"
printf 'failed: %d\n' "$fail"

if [ "$fail" -gt 0 ]; then
    printf '%s\n' '--- FAIL ---'
    exit 1
fi

printf '%s\n' '--- PASS ---'
exit 0
