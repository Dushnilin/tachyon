#!/usr/bin/env bash
# Package manager (apk/opkg) feed update errors can produce alarming raw logs
# such as "Updates: ERROR: wget: exited with error 8" when optional community
# or blocked repositories fail, even though --force-missing-repositories allows
# the operation to succeed.
#
# sanitize_package_log_line() suppresses raw wget/opkg error noise and turns
# feed refresh warnings into friendly, non-critical notifications in Russian or English.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "${TACHYON_LIB:-}" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

HELPERS="$TACHYON_LIB/components/helpers.uc"
ACTION="$TACHYON_LIB/components/action.uc"
[ -f "$HELPERS" ] || fail "missing $HELPERS"
[ -f "$ACTION" ] || fail "missing $ACTION"

code_only() {
  sed 's://.*::'
}

# 1. Static checks: helpers.uc must define and export sanitize_package_log_line
grep -Fq 'function sanitize_package_log_line' "$HELPERS" ||
  fail "components/helpers.uc must define sanitize_package_log_line"
grep -Fq 'sanitize_package_log_line' "$HELPERS" ||
  fail "components/helpers.uc must export sanitize_package_log_line"

# action.uc must export sanitize_package_log_line
grep -Fq 'function sanitize_package_log_line(' "$ACTION" ||
  fail "components/action.uc must re-export sanitize_package_log_line"

# updates_log in helpers.uc must call sanitize_package_log_line
fn_updates_log="$(sed -n '/^function updates_log/,/^}/p' "$HELPERS" | code_only)"
grep -Fq 'sanitize_package_log_line(' <<<"$fn_updates_log" ||
  fail "updates_log must invoke sanitize_package_log_line"

# 2. Behavioural checks if ucode is available
if command -v ucode >/dev/null 2>&1; then
  ucode_cmd() {
    command ucode -L "$TACHYON_LIB" "$@"
  }

  cat >"$WORK_DIR/test_sanitize.uc" <<'UCODE'
let helpers = require("components.helpers");
let errors = [];
let note = function(m) { push(errors, m); };

// Test suppression of raw wget failure messages
let suppressed = [
    "ERROR: wget: exited with error 8",
    "ERROR: wget: exited with error 4",
    "wgetFailed to send request: Operation not permitted",
    "wget: server returned error: HTTP/1.1 404 Not Found",
    "Collected errors:",
    " * opkg_download: Check your network settings and connectivity."
];

for (let line in suppressed) {
    let res = helpers.sanitize_package_log_line(line);
    if (res != null)
        note("Expected suppression for '" + line + "', got: '" + res + "'");
}

// Test preservation of legitimate install/config messages
let preserved = [
    "Installing sing-box (1.10.0) to root...",
    "Configuring sing-box.",
    "Updating database at /tmp/apk..."
];

for (let line in preserved) {
    let res = helpers.sanitize_package_log_line(line);
    if (res != line)
        note("Expected line to be preserved: '" + line + "', got: '" + res + "'");
}

// Test transformation of repo warnings
let apk_warning = "WARNING: updating and opening https://owfeed.org/packages.adb: Connection refused";
let res_apk = helpers.sanitize_package_log_line(apk_warning);
if (!match(res_apk, /owfeed\.org/))
    note("Expected sanitized repo warning to mention host 'owfeed.org', got: '" + res_apk + "'");

let opkg_warning = "* opkg_download: Failed to download https://downloads.openwrt.org/snapshots/packages/Packages.gz";
let res_opkg = helpers.sanitize_package_log_line(opkg_warning);
if (!match(res_opkg, /downloads\.openwrt\.org/))
    note("Expected sanitized repo warning to mention host 'downloads.openwrt.org', got: '" + res_opkg + "'");

if (length(errors) > 0) {
    for (let err in errors)
        warn("FAIL: " + err + "\n");
    exit(1);
}
UCODE

  ucode_cmd "$WORK_DIR/test_sanitize.uc" || fail "behavioural sanitization checks failed"
fi

printf 'package log sanitization checks passed\n'
