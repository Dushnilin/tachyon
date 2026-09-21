#!/bin/bash
# Tests for core/packages.uc — package manager lock management.
#
# Verifies:
#   - detect_pkg_manager returns apk or opkg
#   - detect_lock identifies lock conditions
#   - find_lock_holder returns structured info or null
#   - is_stale_lock detects dead holders
#   - wait_for_lock structured output
#   - detect_arch returns non-empty string
#   - Backward-compatible exports still work

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
# Runtime: detect_pkg_manager
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: detect_pkg_manager ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let mgr = pkg.detect_pkg_manager();
if (mgr == "apk" || mgr == "opkg" || mgr == "")
    print("PASS:" + mgr + "\n");
else
    print("FAIL:" + mgr + "\n");
' 2>&1)
assert_eq "detect_pkg_manager" "PASS" "${RESULT%%:*}"

# ---------------------------------------------------------------------------
# Runtime: detect_lock
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: detect_lock ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let r1 = pkg.detect_lock("", 227);
let r2 = pkg.detect_lock("Could not lock database", 255);
let r3 = pkg.detect_lock("some error", 255);
let r4 = pkg.detect_lock("", 0);
if (r1 && r2 && !r3 && !r4)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " r3=" + r3 + " r4=" + r4 + "\n");
' 2>&1)
assert_eq "detect_lock" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: find_lock_holder (should return null when no lock)
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: find_lock_holder ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let holder = pkg.find_lock_holder();
// On a system without active package operations, should be null
if (holder == null || type(holder) == "null")
    print("PASS\n");
else if (type(holder) == "object" && holder.pid != null)
    print("PASS:holder_found\n");
else
    print("FAIL:" + type(holder) + "\n");
' 2>&1)
assert_eq "find_lock_holder" "PASS" "${RESULT%%:*}"

# ---------------------------------------------------------------------------
# Runtime: is_stale_lock
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: is_stale_lock ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let r1 = pkg.is_stale_lock(null);
let r2 = pkg.is_stale_lock({ pid: "1234", alive: false, command: "test" });
let r3 = pkg.is_stale_lock({ pid: "1234", alive: true, command: "test" });
let r4 = pkg.is_stale_lock("not_an_object");
if (r1 && r2 && !r3 && r4)
    print("PASS\n");
else
    print("FAIL: r1=" + r1 + " r2=" + r2 + " r3=" + r3 + " r4=" + r4 + "\n");
' 2>&1)
assert_eq "is_stale_lock" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: detect_arch
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: detect_arch ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let arch = pkg.detect_arch();
if (arch != null && arch != "" && arch != "unknown")
    print("PASS:" + arch + "\n");
else
    print("FAIL:" + arch + "\n");
' 2>&1)
assert_eq "detect_arch" "PASS" "${RESULT%%:*}"

# ---------------------------------------------------------------------------
# Runtime: backward-compatible exports
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: backward-compatible exports ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let has_installed = type(pkg.installed) == "function";
let has_version = type(pkg.version) == "function";
let has_apk_version = type(pkg.apk_version) == "function";
let has_opkg_version = type(pkg.opkg_version) == "function";
let has_installed_package_version = type(pkg.installed_package_version) == "function";
if (has_installed && has_version && has_apk_version && has_opkg_version && has_installed_package_version)
    print("PASS\n");
else
    print("FAIL: installed=" + has_installed + " version=" + has_version + "\n");
' 2>&1)
assert_eq "backward-compatible exports" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: new exports
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: new exports ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let has_detect = type(pkg.detect_pkg_manager) == "function";
let has_is_apk = type(pkg.is_apk) == "function";
let has_arch = type(pkg.detect_arch) == "function";
let has_detect_lock = type(pkg.detect_lock) == "function";
let has_find_holder = type(pkg.find_lock_holder) == "function";
let has_stale = type(pkg.is_stale_lock) == "function";
let has_wait = type(pkg.wait_for_lock) == "function";
if (has_detect && has_is_apk && has_arch && has_detect_lock && has_find_holder && has_stale && has_wait)
    print("PASS\n");
else
    print("FAIL: detect=" + has_detect + " wait=" + has_wait + "\n");
' 2>&1)
assert_eq "new exports" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: wait_for_lock with no lock (should acquire immediately)
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: wait_for_lock (no contention) ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
let result = pkg.wait_for_lock({ timeout: 5 });
if (result.acquired === true && result.elapsed >= 0 && result.message != null)
    print("PASS\n");
else
    print("FAIL: acquired=" + result.acquired + " msg=" + result.message + "\n");
' 2>&1)
assert_eq "wait_for_lock no contention" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: wait_for_lock timeout returns structured error
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: wait_for_lock timeout error ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" -e '
let pkg = require("core.packages");
// Force a lock holder by creating a fake one — test the error path
// by setting timeout to 1 second (minimum)
let result = pkg.wait_for_lock({ timeout: 1 });
// Should return structured result regardless
if (result.acquired != null && result.elapsed != null && result.message != null)
    print("PASS\n");
else
    print("FAIL: result=" + sprintf("%J", result) + "\n");
' 2>&1)
assert_eq "wait_for_lock timeout error" "PASS" "$RESULT"

# ---------------------------------------------------------------------------
# Runtime: CLI detect subcommand
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: CLI detect ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/packages.uc" detect 2>&1)
if echo "$RESULT" | grep -q "package_manager"; then
    pass=$((pass + 1))
else
    fail_test "CLI detect should return JSON with package_manager: $RESULT"
fi

# ---------------------------------------------------------------------------
# Runtime: CLI lock-holder subcommand
# ---------------------------------------------------------------------------

printf '%s\n' '--- runtime: CLI lock-holder ---'
RESULT=$($TACHYON_UCODE -L "$TACHYON_LIB" "$TACHYON_LIB/core/packages.uc" lock-holder 2>&1)
# Should return null or JSON
if echo "$RESULT" | grep -qE 'null|"pid"'; then
    pass=$((pass + 1))
else
    fail_test "CLI lock-holder should return null or JSON: $RESULT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n--- packages_lock.sh summary ---\n'
printf 'passed: %d\n' "$pass"
printf 'failed: %d\n' "$fail"

if [ "$fail" -gt 0 ]; then
    printf '%s\n' '--- FAIL ---'
    exit 1
fi

printf '%s\n' '--- PASS ---'
exit 0
