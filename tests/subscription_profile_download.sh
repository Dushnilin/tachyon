#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CACHE_UC="$TACHYON_LIB/subscription/cache.uc"
export REAL_UCODE="$(command -v ucode)"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TMP_SING_BOX_FOLDER="$WORK_DIR/core"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent"
export SB_VERSION_STATE_FILE="$WORK_DIR/core-version"
export CURL_LOG="$WORK_DIR/requests"
printf '1.12.0\n' >"$SB_VERSION_STATE_FILE"
mkdir -p "$WORK_DIR/bin"

cat >"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.settings=settings
tachyon.settings.subscription_engine=ucode
tachyon.proxy=section
tachyon.proxy.enabled=1
tachyon.proxy.action=connection
tachyon.proxy.subscription_urls=https://provider.example/sub/private-token
STATE

# Only replace the service availability probe; all cache/config/parser code runs.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "$*" in
  *'/service/state.uc sing-box-service-running') exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
target= headers= ua= proxy=direct max_time= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -V) exit 0 ;;
    -o) target="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -x) proxy=proxy; shift 2 ;;
    --max-time) max_time="$2"; shift 2 ;;
    -H)
      case "$2" in 'User-Agent: '*) ua="${2#User-Agent: }" ;; esac
      shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$max_time" ] || exit 99
printf '%s|%s|%s\n' "$proxy" "$ua" "$url" >>"$CURL_LOG"
case "${PROVIDER_MODE:-profile}" in
  unavailable) printf 000; exit 28 ;;
  transport) [ "$proxy" = proxy ] || { printf 000; exit 7; } ;;
  blocked) [ "$proxy" = proxy ] || { printf 403; exit 22; } ;;
  github)
    case "$url" in https://raw.githubusercontent.com/*) printf 403; exit 22 ;; esac
    ;;
  transient)
    [ "$(wc -l <"$CURL_LOG")" -ne 1 ] || { printf '%s' "$TRANSIENT_HTTP"; exit 22; }
    ;;
esac
if [ "$ua" != "${REQUIRED_UA:-Happ}" ]; then
  printf '%s' "${REJECT_HTTP:-403}"
  exit 22
fi
printf '%s\n' 'vless://00000000-0000-4000-8000-000000000001@node.example:443?security=tls#Node' >"$target"
[ -z "$headers" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
printf 200
SH
# Network retries stay deterministic; request counts assert they are bounded.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/sleep"
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

cache_ucode() {
  ucode -L "$TACHYON_LIB" "$CACHE_UC" "$@"
}
update_source() {
  local result=0
  cache_ucode update-source proxy 1 https://provider.example/sub/private-token || result=$?
  [ "$result" = 0 ] || [ "$result" = 2 ] || fail "subscription update failed: $result"
}
assert_requests() {
  local expected="$1" actual
  actual="$(cat "$CURL_LOG")"
  [ "$actual" = "$expected" ] || fail "unexpected requests: $actual"
}
source_base="$TMP_SING_BOX_FOLDER/subscriptions/proxy-subscription-1"

# A new subscription must reach the compatible UA without mirrors or a proxy
# detour for every rejected profile, then persist the working profile.
update_source
assert_requests $'direct|sing-box/1.12.0|https://provider.example/sub/private-token\ndirect|Happ|https://provider.example/sub/private-token'
[ "$(cat "$source_base.user_agent")" = Happ ] || fail "working UA was not cached"
[ "$(cat "$TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR/proxy-subscription-1.user_agent")" = Happ ] || fail "working UA was not persisted"

: >"$CURL_LOG"
update_source
assert_requests 'direct|Happ|https://provider.example/sub/private-token'

# Editing routing lists must reuse this current cache, not fetch the provider.
: >"$CURL_LOG"
cache_ucode prepare-caches runtime 0 0
[ ! -s "$CURL_LOG" ] || fail "runtime prepare redownloaded a current subscription"

# Reboot-like runtime cache loss must restore the working profile from disk.
for extension in json url user_agent hwid device_headers; do
  rm -f "$source_base.$extension"
done
cache_ucode prepare-caches runtime 0 0
[ ! -s "$CURL_LOG" ] || fail "runtime prepare did not restore the persistent subscription"
[ "$(cat "$source_base.user_agent")" = Happ ] || fail "persistent restore lost the working UA"

# A source with a working cache still needs the service proxy on transport loss.
: >"$CURL_LOG"
PROVIDER_MODE=transport update_source
assert_requests $'direct|Happ|https://provider.example/sub/private-token\ndirect|Happ|https://provider.example/sub/private-token\nproxy|Happ|https://provider.example/sub/private-token'

# IP-based HTTP rejection must keep proxy fallback, after direct profiles.
: >"$CURL_LOG"
PROVIDER_MODE=blocked update_source
assert_requests $'direct|Happ|https://provider.example/sub/private-token\ndirect|sing-box/1.12.0|https://provider.example/sub/private-token\ndirect|Happ/4.6.2|https://provider.example/sub/private-token\ndirect|v2rayN|https://provider.example/sub/private-token\ndirect|v2rayNG|https://provider.example/sub/private-token\ndirect|Mihomo|https://provider.example/sub/private-token\ndirect|Clash.Meta|https://provider.example/sub/private-token\nproxy|Happ|https://provider.example/sub/private-token'

# Failure must leave both the active node list and its profile intact.
cp "$source_base.json" "$WORK_DIR/last-good.json"
: >"$CURL_LOG"
if PROVIDER_MODE=unavailable cache_ucode update-source proxy 1 https://provider.example/sub/private-token; then
  fail "an unavailable subscription must report failure"
fi
cmp "$source_base.json" "$WORK_DIR/last-good.json" || fail "failure replaced the working node list"
[ "$(cat "$source_base.user_agent")" = Happ ] || fail "failure replaced the working UA"
[ "$(wc -l <"$CURL_LOG")" -eq 4 ] || fail "transport failure retried unrelated profiles"

# If every automatic profile is rejected on both paths, make only one proxy
# pass and retain the working cache.
: >"$CURL_LOG"
if PROVIDER_MODE=blocked REQUIRED_UA=Unavailable cache_ucode update-source proxy 1 https://provider.example/sub/private-token; then
  fail "rejection of all profiles must report failure"
fi
[ "$(grep -c '^direct|' "$CURL_LOG")" -eq 7 ] || fail "direct profiles were retried after HTTP rejection"
[ "$(grep -c '^proxy|' "$CURL_LOG")" -eq 7 ] || fail "proxy fallback must run at most once per profile"
cmp "$source_base.json" "$WORK_DIR/last-good.json" || fail "HTTP rejection replaced the working node list"

# An explicitly configured profile overrides the cached automatic one, and must
# never silently fall back to another client when the provider rejects it.
cat >>"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.sub=subscription_url
tachyon.sub.section=proxy
tachyon.sub.url=https://provider.example/sub/private-token
tachyon.sub.auto_user_agent=0
tachyon.sub.user_agent=Custom/1.0
STATE
: >"$CURL_LOG"
REQUIRED_UA=Custom/1.0 update_source
assert_requests 'direct|Custom/1.0|https://provider.example/sub/private-token'
: >"$CURL_LOG"
if cache_ucode update-source proxy 1 https://provider.example/sub/private-token; then
  fail "a rejected configured UA must report failure"
fi
assert_requests $'direct|Custom/1.0|https://provider.example/sub/private-token\nproxy|Custom/1.0|https://provider.example/sub/private-token'
[ "$(cat "$source_base.user_agent")" = Custom/1.0 ] || fail "failure replaced the configured UA"

# A GitHub 403 can be an IP block. Keep the established mirror fallback for
# actual GitHub URLs, including URLs normalized from blob to raw.
: >"$CURL_LOG"
PROVIDER_MODE=github cache_ucode download-subscription \
  https://github.com/owner/repo/blob/main/sub.txt "$WORK_DIR/github-sub.txt" "" "" Happ
assert_requests $'direct|Happ|https://raw.githubusercontent.com/owner/repo/main/sub.txt\ndirect|Happ|https://cdn.jsdelivr.net/gh/owner/repo@main/sub.txt'

# Throttling and temporary server errors must still retry the same profile.
for http_status in 429 503; do
  : >"$CURL_LOG"
  PROVIDER_MODE=transient TRANSIENT_HTTP="$http_status" cache_ucode download-subscription \
    https://provider.example/sub/private-token "$WORK_DIR/transient-sub.txt" "" "" Happ
  assert_requests $'direct|Happ|https://provider.example/sub/private-token\ndirect|Happ|https://provider.example/sub/private-token'
done

# Authentication rejection also advances profiles without retrying the same UA.
: >"$CURL_LOG"
if REJECT_HTTP=401 cache_ucode download-subscription \
  https://provider.example/sub/private-token "$WORK_DIR/rejected.txt" "" "" Unsupported; then
  fail "HTTP 401 must report a failed download"
fi
assert_requests 'direct|Unsupported|https://provider.example/sub/private-token'

printf 'subscription profile download checks passed\n'
