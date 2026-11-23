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
  "https://gh-proxy.org/" \
  "https://gh.nxnow.top/" \
  "https://ghproxy.net/" \
  "https://edgeone.gh-proxy.org/"; do
  grep -Fq "$mirror" "$URL_UC" || fail "core/url.uc missing expected mirror $mirror"
done

actual_mirrors="$(TACHYON_INSTALLER_TEST=1 sh -c '. "$1" && printf "%s" "$GH_MIRRORS"' _ "$INSTALLER")"
for mirror in \
  "https://ghfast.top/" \
  "https://gh-proxy.com/" \
  "https://gh-proxy.org/" \
  "https://gh.nxnow.top/" \
  "https://ghproxy.net/" \
  "https://edgeone.gh-proxy.org/"; do
  case " $actual_mirrors " in
    *" $mirror "*) ;;
    *) fail "install.sh GH_MIRRORS missing $mirror (got: $actual_mirrors)" ;;
  esac
done

# 2. Functional POSIX sh checks for download_with_retry, _fetch_github_api_json,
#    proxy, custom mirror, partial mid-stream stall skip, _DIRECT_FAILED, and Atom fallback.
MOCK_BIN="$WORK_DIR/bin"
MOCK_LOG="$WORK_DIR/curl.log"
mkdir -p "$MOCK_BIN" "$WORK_DIR/tmp"

# Keep real sleep: the download deadline watchdog uses it too.

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
proxy=""
ipv4=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -A) ua="$2"; shift 2 ;;
        -x) proxy="$2"; shift 2 ;;
        -4) ipv4=1; shift ;;
        --doh-url) doh="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s|%s|%s|%s|%s\n' "$ua" "$proxy" "$ipv4" "$doh" "$url" >>"$MOCK_CURL_LOG"

write_body() {
    if [ -n "$out" ]; then
        printf '%s' "$1" >"$out"
    else
        printf '%s' "$1"
    fi
}

write_apk() {
    printf 'ADBd' >"$out"
    dd if=/dev/zero bs=1200 count=1 >>"$out" 2>/dev/null
}

# Scenario overrides for targeted checks
if [ "${MOCK_FORCE_RATELIMIT_API:-0}" = "1" ]; then
    case "$url" in
        *api.github.com/*)
            write_body '{"message":"API rate limit exceeded"}'
            exit 0
            ;;
        https://gh-proxy.org/https://github.com/*/releases.atom)
            write_body '<feed><entry><link href="https://github.com/Dushnilin/tachyon/releases/tag/1.8.8"/></entry></feed>'
            exit 0
            ;;
        *releases.atom)
            exit 22
            ;;
    esac
fi

if [ -n "$proxy" ]; then
    case "$url" in
        https://github.com/*)
            write_apk
            exit 0
            ;;
    esac
fi

case "$url" in
    https://custom.mirror.example/*.apk)
        write_apk
        exit 0
        ;;
    https://edgeone.gh-proxy.org/*.apk)
        printf 'ADBdpartial' >"$out"
        exit 28
        ;;
    https://api.github.com/*)
        # Direct fails with exit 6 -> -4 fails with exit 6 -> DoH retry returns HTML error stub.
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
    https://gh-proxy.org/*)
        write_body 'error code: 1015'
        exit 0
        ;;
    https://gh.nxnow.top/https://api.github.com/*)
        write_body '{"tag_name":"1.9.0","assets":[{"name":"tachyon_1.9.0.apk"}]}'
        exit 0
        ;;
    https://gh.nxnow.top/*sha256sums.txt)
        printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  tachyon_1.9.0.apk\n' >"$out"
        exit 0
        ;;
    https://gh.nxnow.top/*.apk)
        write_apk
        exit 0
        ;;
    https://ghproxy.net/*.apk)
        write_apk
        exit 0
        ;;
    https://github.com/*)
        exit 22
        ;;
esac
exit 22
SH
chmod 0755 "$MOCK_BIN/curl"

cat >"$MOCK_BIN/nslookup" <<'SH'
#!/bin/sh
exit 1
SH
chmod 0755 "$MOCK_BIN/nslookup"

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

# A. API JSON must reject DoH HTML stub and fall through mirrors 1-3 to gh.nxnow.top.
#    Also verify _DIRECT_FAILED=1 persists across $(...) subshell via TMP_DIR/direct_failed.
api_json="$(_fetch_github_api_json "https://api.github.com/repos/Dushnilin/tachyon/releases/latest" 0)"
case "$api_json" in
    *"\"tag_name\":\"1.9.0\""*) ;;
    *) printf "FAIL: unexpected release JSON: %s\n" "$api_json" >&2; exit 1 ;;
esac
[ "$(_get_direct_failed)" = "1" ] || {
    printf "FAIL: expected direct_failed=1 after direct API failure, got %s\n" "$(_get_direct_failed)" >&2
    exit 1
}

# B. Because direct_failed=1 AND gh.nxnow.top was cached as _WORKING_GH_MIRROR,
#    the next download_with_retry MUST hit gh.nxnow.top immediately without retrying dead direct or slower mirrors.
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/tachyon_1.9.0.apk" "$WORK_DIR/pkg.apk" "tachyon package" pkg
[ -s "$WORK_DIR/pkg.apk" ] || { printf "FAIL: pkg.apk missing\n" >&2; exit 1; }
line_count="$(wc -l <"$MOCK_CURL_LOG" | tr -d " ")"
[ "$line_count" = "1" ] || {
    printf "FAIL: expected exactly 1 curl call via cached working mirror, got %s:\n%s\n" "$line_count" "$(cat "$MOCK_CURL_LOG")" >&2
    exit 1
}
grep -Fq "Tachyon-Installer/1.0||0||https://gh.nxnow.top/" "$MOCK_CURL_LOG" || {
    printf "FAIL: expected cached gh.nxnow.top on first attempt:\n%s\n" "$(cat "$MOCK_CURL_LOG")" >&2
    exit 1
}

# C. Reset state and verify download_with_retry rejects HTML/error stubs on mirrors 1-3 for sha256sums.
_set_working_gh_mirror ""
_set_direct_failed 0
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/sha256sums.txt" "$WORK_DIR/sha256sums.txt" "sha256sums.txt" sha256
grep -Fq "tachyon_1.9.0.apk" "$WORK_DIR/sha256sums.txt" || {
    printf "FAIL: sha256sums.txt fallback content mismatch\n" >&2
    exit 1
}
[ "$(_get_working_gh_mirror)" = "https://gh.nxnow.top/" ] || {
    printf "FAIL: expected working mirror https://gh.nxnow.top/, got %s\n" "$(_get_working_gh_mirror)" >&2
    exit 1
}

# D. Partial download + rc 28 (16 KB stall) must skip -4 and DoH retries and advance immediately.
_set_working_gh_mirror "https://edgeone.gh-proxy.org/"
_set_direct_failed 1
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/tachyon_1.9.0.apk" "$WORK_DIR/pkg_stall.apk" "tachyon package" pkg
edge_calls="$(grep -c "edgeone.gh-proxy.org" "$MOCK_CURL_LOG" || true)"
[ "$edge_calls" = "1" ] || {
    printf "FAIL: mid-stream stall (partial + rc 28) should not retry -4 or DoH (calls=%s):\n%s\n" "$edge_calls" "$(cat "$MOCK_CURL_LOG")" >&2
    exit 1
}

# E. --proxy socks5://... passes -x socks5h://... without --doh-url, and check_name_resolution bypasses local DNS check.
_set_working_gh_mirror ""
_set_direct_failed 0
PROXY_URL_REQUESTED=""
parse_args --proxy socks5://127.0.0.1:10808
DRY_RUN=0
check_name_resolution || {
    printf "FAIL: check_name_resolution must succeed when --proxy is configured\n" >&2
    exit 1
}
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/tachyon_1.9.0.apk" "$WORK_DIR/pkg_proxy.apk" "tachyon package" pkg
grep -Fq "Tachyon-Installer/1.0|socks5h://127.0.0.1:10808|0||https://github.com/" "$MOCK_CURL_LOG" || {
    printf "FAIL: --proxy did not pass -x socks5h:// without DoH:\n%s\n" "$(cat "$MOCK_CURL_LOG")" >&2
    exit 1
}

# F. --mirror normalizes trailing slashes and tries custom mirror first.
PROXY_URL_REQUESTED=""
CUSTOM_MIRROR=""
parse_args --mirror https://custom.mirror.example///
[ "$CUSTOM_MIRROR" = "https://custom.mirror.example/" ] || {
    printf "FAIL: expected normalized CUSTOM_MIRROR, got %s\n" "$CUSTOM_MIRROR" >&2
    exit 1
}
: >"$MOCK_CURL_LOG"
download_with_retry "https://github.com/Dushnilin/tachyon/releases/download/1.9.0/tachyon_1.9.0.apk" "$WORK_DIR/pkg_custom.apk" "tachyon package" pkg
grep -Fq "https://custom.mirror.example/https://github.com/" "$MOCK_CURL_LOG" || {
    printf "FAIL: --mirror was not tried first:\n%s\n" "$(cat "$MOCK_CURL_LOG")" >&2
    exit 1
}

# G. Invalid release JSON without tag_name or assets must be rejected.
if _is_valid_release_json "{\"message\":\"API rate limit exceeded\"}"; then
    printf "FAIL: error JSON without tag_name/assets must be rejected\n" >&2
    exit 1
fi

# H. resolve_release falls back to releases.atom when API returns rate-limit everywhere.
CUSTOM_MIRROR=""
PROXY_URL_REQUESTED=""
_set_working_gh_mirror ""
_set_direct_failed 0
PKG_IS_APK=1
RELEASE_CHANNEL="stable"
RELEASE_TAG_REQUESTED=""
TACHYON_I18N_REQUESTED=0
QUIET=1
MOCK_FORCE_RATELIMIT_API=1 resolve_release
[ "$TACHYON_RELEASE_TAG" = "1.8.8" ] || {
    printf "FAIL: expected Atom fallback tag 1.8.8, got %s\n" "$TACHYON_RELEASE_TAG" >&2
    exit 1
}
[ "$TACHYON_BACKEND_URL" = "https://github.com/Dushnilin/tachyon/releases/download/1.8.8/tachyon_1.8.8.apk" ] || {
    printf "FAIL: unexpected Atom fallback backend URL %s\n" "$TACHYON_BACKEND_URL" >&2
    exit 1
}
' _ "$INSTALLER"

printf 'installer mirror fallback tests passed\n'
