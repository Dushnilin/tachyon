#!/bin/bash
# Tests for core/logging.uc — unified structured logging module.
#
# Verifies:
#   - log_message backward compatibility
#   - Structured write with subsystem, operation, job_id
#   - Level-specific convenience methods (debug, info, warn, error, fatal)
#   - Job log append
#   - LEVELS constant
#   - CLI subcommands (selftest, log)

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

# ---------------------------------------------------------------------------
# Run module selftest
# ---------------------------------------------------------------------------

printf '--- logging.uc selftest ---\n'
if $TACHYON_UCODE "$TACHYON_LIB/core/logging.uc" selftest; then
    pass=$((pass + 1))
else
    fail_test "logging.uc selftest failed"
fi

# ---------------------------------------------------------------------------
# Runtime: backward-compatible log_message
# ---------------------------------------------------------------------------

printf '--- runtime: log_message backward compatibility ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let r1 = log.log_message("backward compat test");
let r2 = log.log_message("warn test", "warn");
let r3 = log.log_message("tag test", "info", "tachyon-test");
if (r1 === true && r2 === true && r3 === true)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " r3=" + r3 + "\n");
' 2>&1)
assert_eq "log_message backward compat" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: structured write
# ---------------------------------------------------------------------------

printf '--- runtime: structured write ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let r1 = log.write({ level: "info", subsystem: "test", message: "hello" });
let r2 = log.write({ level: "error", subsystem: "test", operation: "deploy", job_id: "j-123", correlation_id: "c-456", message: "deploy failed" });
if (r1 === true && r2 === true)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + "\n");
' 2>&1)
assert_eq "structured write" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: level-specific methods
# ---------------------------------------------------------------------------

printf '--- runtime: level-specific methods ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let r1 = log.debug("debug msg");
let r2 = log.info("info msg");
let r3 = log.warn("warn msg");
let r4 = log.error("error msg");
let r5 = log.fatal("fatal msg");
if (r1 === true && r2 === true && r3 === true && r4 === true && r5 === true)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " r3=" + r3 + " r4=" + r4 + " r5=" + r5 + "\n");
' 2>&1)
assert_eq "level-specific methods" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: job_log_append
# ---------------------------------------------------------------------------

printf '--- runtime: job_log_append ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let fs = require("fs");
let tmp = "/tmp/tachyon-test-log." + getpid();
let r1 = log.job_log_append(tmp, "entry 1", "info");
let r2 = log.job_log_append(tmp, "entry 2", "error");
let content = trim("" + fs.readfile(tmp));
let has1 = index(content, "entry 1") >= 0;
let has2 = index(content, "entry 2") >= 0;
let hasLevel = index(content, "[info]") >= 0;
try { fs.unlink(tmp); } catch(e) {}
if (r1 === true && r2 === true && has1 && has2 && hasLevel)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " has1=" + has1 + " has2=" + has2 + " hasLevel=" + hasLevel + "\n");
' 2>&1)
assert_eq "job_log_append" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: empty/null path returns false
# ---------------------------------------------------------------------------

printf '--- runtime: job_log_append edge cases ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let r1 = log.job_log_append("", "msg");
let r2 = log.job_log_append(null, "msg");
if (r1 === false && r2 === false)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + "\n");
' 2>&1)
assert_eq "job_log_append edge cases" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: LEVELS constant
# ---------------------------------------------------------------------------

printf '--- runtime: LEVELS constant ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let ok = log.LEVELS.info == 6 && log.LEVELS.warn == 4 && log.LEVELS.error == 3 && log.LEVELS.debug == 7;
if (ok)
    print("PASS\n");
else
    print("FAIL: LEVELS=" + sprintf("%J", log.LEVELS) + "\n");
' 2>&1)
assert_eq "LEVELS constant" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: common.log_message delegates to logging
# ---------------------------------------------------------------------------

printf '--- runtime: common.log_message delegation ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let common = require("core.common");
let r1 = common.log_message("delegated message");
let r2 = common.log_message("delegated warn", "warn");
let r3 = common.log_message("delegated tag", "info", "tachyon-custom");
if (r1 === true && r2 === true && r3 === true)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " r3=" + r3 + "\n");
' 2>&1)
assert_eq "common.log_message delegation" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: CLI subcommand
# ---------------------------------------------------------------------------

printf '--- runtime: CLI log subcommand ---\n'
$TACHYON_UCODE "$TACHYON_LIB/core/logging.uc" log info "CLI test message" test op1
pass=$((pass + 1))

# ---------------------------------------------------------------------------
# Verify all modules can import core.logging
# ---------------------------------------------------------------------------

printf '--- runtime: import chain works ---\n'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let log = require("core.logging");
let common = require("core.common");
let jobs = require("core.jobs");
let exec = require("core.exec");
// All should import without errors
if (typeof(log.write) == "function" && typeof(common.log_message) == "function")
    print("PASS\n");
else
    print("FAIL\n");
' 2>&1)
assert_eq "import chain" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n--- logging_module.sh summary ---\n'
printf 'passed: %d\n' "$pass"
printf 'failed: %d\n' "$fail"

if [ "$fail" -gt 0 ]; then
    printf '--- FAIL ---\n'
    exit 1
fi

printf '--- PASS ---\n'
exit 0
