#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

INSTALLER="$ROOT_DIR/install.sh"
CATALOG_UC="$TACHYON_LIB/components/catalog.uc"

[ -r "$INSTALLER" ] || fail "install.sh is missing"
[ -r "$CATALOG_UC" ] || fail "components/catalog.uc is missing"
sh -n "$INSTALLER" || fail "install.sh must be valid POSIX shell"

RECORD_FILE="$WORK_DIR/handoff.record"
V2_SCRIPT_SAVED=""
cleanup() {
  [ -n "$V2_SCRIPT_SAVED" ] && rm -f "$V2_SCRIPT_SAVED"
  rm -f "/tmp/tachyon-v2-install.$$.sh"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export TACHYON_INSTALLER_TEST=1
# shellcheck source=/dev/null
. "$INSTALLER"

# 1. Tag validation accepts 1.x, 2.x and prerelease tags while rejecting malformed tags
for valid_tag in "1.8.8" "v2.0.0-rc.1" "2.0.0-rc.1" "v2.0.0" "2.0.0-beta.7"; do
  RELEASE_TAG_REQUESTED=""
  parse_args --tag "$valid_tag" || fail "parse_args rejected valid tag $valid_tag"
  [ "$RELEASE_TAG_REQUESTED" = "$valid_tag" ] || fail "unexpected parsed tag: $RELEASE_TAG_REQUESTED"
done

for bad_tag in "1.2.3.4" ".1.2" "1.2." "1.2..3" "v2.0.0-" "abc"; do
  RELEASE_TAG_REQUESTED=""
  if parse_args --tag "$bad_tag" 2>/dev/null; then
    fail "parse_args accepted invalid tag $bad_tag"
  fi
done

# 2. Version detection distinguishes 2.x+ from 1.x
for v2_tag in "v2.0.0-rc.1" "2.0.0-rc.1" "2.0.0" "v2.1.0" "v10.0.0"; do
  is_v2_tag "$v2_tag" || fail "is_v2_tag must accept $v2_tag"
done
for v1_tag in "1.8.8" "v1.9.9" "0.6.2" ""; do
  if is_v2_tag "$v1_tag"; then
    fail "is_v2_tag must reject $v1_tag"
  fi
done

# 3. Handoff to 2.0 installer on explicit --tag v2.0.0-rc.1 and --channel beta
MOCK_BIN="$WORK_DIR/bin"
MOCK_LOG="$WORK_DIR/curl.log"
mkdir -p "$MOCK_BIN" "$WORK_DIR/tmp"
export TMP_DIR="$WORK_DIR/tmp"
export LOG_FILE="$WORK_DIR/installer.log"
export TACHYON_V2_HANDOFF_RECORD_FILE="$RECORD_FILE"
export PATH="$MOCK_BIN:$PATH"

cat >"$MOCK_BIN/curl" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then
  printf '%s\n' '--doh-url'
  exit 0
fi
url=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -A|-x|--connect-timeout|--speed-limit|--speed-time|--max-time|--doh-url|-H) shift 2 ;;
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$MOCK_CURL_LOG"

write_body() {
  if [ -n "$out" ]; then
    printf '%s' "$1" >"$out"
  else
    printf '%s' "$1"
  fi
}

case "$url" in
  https://api.github.com/repos/Dushnilin/tachyon/releases\?per_page=20)
    write_body '[{"tag_name":"v2.0.0-rc.1","prerelease":true,"draft":false,"assets":[]}]'
    exit 0
    ;;
  https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/2.0/install.sh)
    write_body '#!/bin/sh
# mock v2 installer via raw mirror fallback
package_asset_name() { echo "tachyon-$1-v$2.$3"; }
'
    exit 0
    ;;
  *releases/download/v2.0.0-rc.1/install.sh)
    if [ "${MOCK_RELEASE_INSTALL_HTML:-0}" = "1" ]; then
      write_body '<!doctype html><html><body>mirror error</body></html>'
      exit 0
    fi
    write_body '#!/bin/sh
# mock v2 installer from release
package_asset_name() { echo "tachyon-$1-v$2.$3"; }
'
    exit 0
    ;;
  *)
    exit 22
    ;;
esac
SH
chmod +x "$MOCK_BIN/curl"
export MOCK_CURL_LOG="$MOCK_LOG"

FETCHER="curl"
PKG_IS_APK=1
PKG_MANAGER="apk"
QUIET=1
ASSUME_YES=1
DRY_RUN=0
REINSTALL_MODE=0
REPAIR_MODE=0
SKIP_ENGINE=0
PROXY_URL_REQUESTED="socks5://127.0.0.1:1080"
CUSTOM_MIRROR=""

# Scenario A: explicit --tag v2.0.0-rc.1 must hand off instead of constructing tachyon_2.0.0-rc.1.apk
: >"$MOCK_LOG"
rm -f "$RECORD_FILE"
RELEASE_TAG_REQUESTED="v2.0.0-rc.1"
RELEASE_CHANNEL="stable"
TACHYON_BACKEND_URL=""
MOCK_RELEASE_INSTALL_HTML=0
resolve_release
[ -z "$TACHYON_BACKEND_URL" ] || fail "Scenario A must not construct legacy backend URL (got: $TACHYON_BACKEND_URL)"
[ -r "$RECORD_FILE" ] || fail "Scenario A did not trigger 2.0 handoff"
IFS='|' read -r V2_SCRIPT_SAVED recorded_args <"$RECORD_FILE"
[ -s "$V2_SCRIPT_SAVED" ] || fail "Scenario A did not save downloaded 2.0 installer script"
case "$recorded_args" in
  *"--tag v2.0.0-rc.1"*);;
  *) fail "Scenario A missing --tag v2.0.0-rc.1 in handoff args: $recorded_args" ;;
esac
case "$recorded_args" in
  *"--proxy socks5://127.0.0.1:1080"*);;
  *) fail "Scenario A missing --proxy in handoff args: $recorded_args" ;;
esac
if grep -qE 'tachyon_v?2\.0\.0-rc\.1\.apk' "$MOCK_LOG"; then
  fail "Scenario A attempted legacy arch-less URL download"
fi
rm -f "$V2_SCRIPT_SAVED"

# Scenario B: --channel beta resolves v2.0.0-rc.1 and falls back from HTML release page to 2.0/install.sh mirror
: >"$MOCK_LOG"
rm -f "$RECORD_FILE"
RELEASE_TAG_REQUESTED=""
RELEASE_CHANNEL="beta"
PROXY_URL_REQUESTED=""
TACHYON_BACKEND_URL=""
export MOCK_RELEASE_INSTALL_HTML=1
resolve_release
[ -z "$TACHYON_BACKEND_URL" ] || fail "Scenario B must not construct legacy backend URL (got: $TACHYON_BACKEND_URL)"
[ -r "$RECORD_FILE" ] || fail "Scenario B did not trigger 2.0 handoff"
IFS='|' read -r V2_SCRIPT_SAVED recorded_args <"$RECORD_FILE"
[ -s "$V2_SCRIPT_SAVED" ] || fail "Scenario B did not save downloaded 2.0 installer script"
case "$recorded_args" in
  *"--tag v2.0.0-rc.1 --channel beta -y"*) ;;
  *) fail "Scenario B unexpected handoff args: $recorded_args" ;;
esac
grep -Fq 'https://ghfast.top/https://raw.githubusercontent.com/Dushnilin/tachyon/2.0/install.sh' "$MOCK_LOG" ||
  fail "Scenario B must fall back to 2.0/install.sh mirror when release download returns HTML"
if grep -qE 'tachyon_v?2\.0\.0-rc\.1\.apk' "$MOCK_LOG"; then
  fail "Scenario B attempted legacy arch-less URL download"
fi
rm -f "$V2_SCRIPT_SAVED"

# 4. 1.8.x updater catalog must refuse synthesizing arch-less v2 package URLs
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let cat = require("components.catalog");
assert(cat.is_tachyon_v2_tag("v2.0.0-rc.1") == true, "v2 tag check");
assert(cat.is_tachyon_v2_tag("2.0.0") == true, "2.0.0 tag check");
assert(cat.is_tachyon_v2_tag("1.8.8") == false, "1.8.8 tag check");
assert(cat.resolve_tachyon_release("v2.0.0-rc.1") == null, "must not synthesize tachyon_2.0.0-rc.1 url");
assert(cat.resolve_tachyon_release("2.0.0") == null, "must not synthesize tachyon_2.0.0 url");
' || fail "catalog.uc v2 guard check failed"

printf 'PASS: installer v2 handoff and arch-less URL guard\n'
