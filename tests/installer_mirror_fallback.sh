#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

INSTALLER="$ROOT_DIR/install.sh"
URL_UC="$TACHYON_LIB/core/url.uc"

[ -r "$INSTALLER" ] || fail "install.sh is missing"
[ -r "$URL_UC" ] || fail "core/url.uc is missing"

# 1. All 6 GitHub mirrors in core/url.uc must match GH_MIRRORS in install.sh.
for mirror in \
  "https://ghfast.top/" \
  "https://gh-proxy.com/" \
  "https://gh.llkk.cc/" \
  "https://ghproxy.net/" \
  "https://mirror.ghproxy.com/" \
  "https://github.moeyy.xyz/"; do
  grep -Fq "$mirror" "$URL_UC" || fail "core/url.uc missing expected mirror $mirror"
done

actual_mirrors="$(TACHYON_INSTALLER_TEST=1 sh -c '. "$1" && printf "%s" "$GH_MIRRORS"' _ "$INSTALLER")"
for mirror in \
  "https://ghfast.top/" \
  "https://gh-proxy.com/" \
  "https://gh.llkk.cc/" \
  "https://ghproxy.net/" \
  "https://mirror.ghproxy.com/" \
  "https://github.moeyy.xyz/"; do
  case " $actual_mirrors " in
    *" $mirror "*) ;;
    *) fail "install.sh GH_MIRRORS missing $mirror (got: $actual_mirrors)" ;;
  esac
done

# 2. Functional POSIX sh checks for download_with_retry & _fetch_github_api_json.
MOCK_BIN="$WORK_DIR/bin"
MOCK_LOG="$WORK_DIR/curl.log"
mkdir -p "$MOCK_BIN" "$WORK_DIR/tmp"

# Deterministic fast sleep so retry backoff never slows the suite.
cat >"$MOCK_BIN/sleep" <<'SH'
#!/bin/sh
exit 0
SH

cat >"$MOCK_BIN/curl" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then
    printf '%s\n' '--doh-url'
    exit 0
fi
url=""
out=""
doh=""
ua=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -A) ua="$2"; shift 2 ;;
        --doh-url) doh="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s|%s|%s\n' "$ua" "$doh" "$url" >>"$MOCK_CURL_LOG"

write_body() {
    if [ -n "$out" ]; then
        printf '%s' "$1" >"$out"
    else
        printf '%s' "$1"
    fi
}

case "$url" in
    https://api.github.com/*)
        # Direct fails with exit 6 -> DoH retry returns HTML error stub.
        if [ -z "$doh" ]; then
            exit 6
        fi
        write_body '<!DOCTYPE html><html><body>blocked</body></html>'
        exit 0
        ;;
    https://ghfast.top/*)
        write_body '<!doctype html><title>Blocked</title>'
        exit 0
        ;;
    https://gh-proxy.com/*)
        write_body '<html><body>proxy gateway error</body></html>'
        exit 0
        ;;
    https://gh.llkk.cc/*)
        write_body 'error code: 1015'
        exit 0
        ;;
    https://ghproxy.net/https://api.github.com/*)
        write_body '{"tag_name":"1.9.0","assets":[{"name":"tachyon_1.9.0.apk"}]}'
        exit 0
        ;;
    https://ghproxy.net/*sha256sums.txt)
        printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  tachyon_1.9.0.apk\n' >"$out"
        exit 0
        ;;
    https://ghproxy.net/*.apk)
        # Valid ADBd apk magic (> 1024 bytes).
        printf 'ADBd' >"$out"
        dd if=/dev/zero bs=1200 count=1 >>"$out" 2>/dev/null
        exit 0
        ;;
    https://github.com/*)
        exit 22
        ;;
esac
exit 22
SH
chmod 0755 "$MOCK_BIN/sleep" "$MOCK_BIN/curl"

PATH="$MOCK_BIN:$PATH" \
MOCK_CURL_LOG="$MOCK_LOG" \
TACHYON_INSTALLER_TEST=1 \
TMP_DIR="$WORK_DIR/tmp" \
WORK_DIR="$WORK_DIR" \
LOG_FILE="$WORK_DIR/installer.log" \
sh -c '
set -eu
. "$1"
TMP_DIR="$WORK_DIR/tmp"
FETCHER="curl"

# API JSON must reject DoH HTML stub and fall through mirrors 1-3 to ghproxy.net.
api_json="$(_fetch_github_api_json "https://api.github.com/repos/Dushnilin/tachyon/releases/latest" 0)"
case "$api_json" in
    *"\"tag_name\":\"1.9.0\""*) ;;
    *) printf "FAIL: unexpected release JSON: %s\n" "$api_json" >&2; exit 1 ;;
esac

# Working mirror must be cached and prioritized on the next download.
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/tachyon_1.9.0.apk" "$WORK_DIR/pkg.apk" "tachyon package" pkg
[ -s "$WORK_DIR/pkg.apk" ] || { printf "FAIL: pkg.apk missing\n" >&2; exit 1; }

# Because ghproxy.net was cached as _WORKING_GH_MIRROR, direct + ghproxy.net
# succeed without hitting ghfast.top / gh-proxy.com / gh.llkk.cc again.
if grep -Fq "ghfast.top" "$MOCK_CURL_LOG" || grep -Fq "gh-proxy.com" "$MOCK_CURL_LOG"; then
    printf "FAIL: _WORKING_GH_MIRROR was not prioritized before slow mirrors:\n%s\n" "$(cat "$MOCK_CURL_LOG")" >&2
    exit 1
fi
grep -Fq "Tachyon-Installer/1.0|" "$MOCK_CURL_LOG" || {
    printf "FAIL: missing Tachyon-Installer/1.0 User-Agent in curl calls\n" >&2
    exit 1
}

# Reset working mirror and verify download_with_retry rejects HTML/error stubs on mirrors 1-3 for sha256sums & pkg.
_set_working_gh_mirror ""
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/sha256sums.txt" "$WORK_DIR/sha256sums.txt" "sha256sums.txt" sha256
grep -Fq "tachyon_1.9.0.apk" "$WORK_DIR/sha256sums.txt" || {
    printf "FAIL: sha256sums.txt fallback content mismatch\n" >&2
    exit 1
}
[ "$(_get_working_gh_mirror)" = "https://ghproxy.net/" ] || {
    printf "FAIL: expected working mirror https://ghproxy.net/, got %s\n" "$(_get_working_gh_mirror)" >&2
    exit 1
}

# Invalid release JSON without tag_name or assets must be rejected.
if _is_valid_release_json "{\"message\":\"API rate limit exceeded\"}"; then
    printf "FAIL: error JSON without tag_name/assets must be rejected\n" >&2
    exit 1
fi
' _ "$INSTALLER"

printf 'installer mirror fallback tests passed\n'
