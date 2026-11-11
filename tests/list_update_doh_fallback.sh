#!/usr/bin/env bash
# Covers Issue #387 and Cloudflare Worker subscription edge cases:
# 1. When curl lacks c-ares (--dns-servers), both subscription/cache.uc and
#    components/updates.uc MUST use system DNS first (no unconditional
#    --doh-url https://1.1.1.1/dns-query) and fall back to DoH (dns.google ->
#    yandex -> 1.1.1.1) ONLY when curl fails with exit code 6 (DNS resolution).
# 2. HTTP 421 Misdirected Request triggers an automatic --http1.1 retry.
# 3. Client HTTP 404 on a single URL immediately aborts inner curl retries so
#    subscription update moves right on to the next User-Agent profile (Happ).
# 4. Noisy subprocess stdout/stderr from tachyon-core subscription CLI never
#    leaks into prepare-caches stdout / deferred_sections.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CACHE_UC="$ROOT_DIR/tachyon/files/usr/lib/subscription/cache.uc"
UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
CURL_LOG="$WORK_DIR/curl.log"

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/rulesets" "$WORK_DIR/runtime" "$WORK_DIR/persist"

cat >"$WORK_DIR/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -eo pipefail

has_dns_servers=0
has_doh=0
doh_val=""
has_http11=0
has_write_out=0
is_version=0
out_file=""
hdr_file=""
ua_val=""
url_val=""

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  arg="${args[$i]}"
  case "$arg" in
    --dns-servers)
      has_dns_servers=1
      i=$((i + 1))
      ;;
    --doh-url)
      has_doh=1
      i=$((i + 1))
      doh_val="${args[$i]:-}"
      ;;
    --http1.1)
      has_http11=1
      ;;
    -w|--write-out)
      has_write_out=1
      i=$((i + 1))
      ;;
    -V|--version)
      is_version=1
      ;;
    -o)
      i=$((i + 1))
      out_file="${args[$i]:-}"
      ;;
    -D)
      i=$((i + 1))
      hdr_file="${args[$i]:-}"
      ;;
    -A)
      i=$((i + 1))
      ua_val="${args[$i]:-}"
      ;;
    -H)
      i=$((i + 1))
      hdr_arg="${args[$i]:-}"
      case "$hdr_arg" in
        [Uu]ser-[Aa]gent:\ *)
          ua_val="${hdr_arg#*: }"
          ;;
      esac
      ;;
    http://*|https://*)
      url_val="$arg"
      ;;
  esac
  i=$((i + 1))
done

# Simulate OpenWrt curl built WITHOUT c-ares (--dns-servers fails, --doh-url supported)
if [ "$is_version" -eq 1 ]; then
  if [ "$has_dns_servers" -eq 1 ]; then
    exit 2
  fi
  printf 'curl 8.10.1 (OpenWrt) libcurl/8.10.1\n'
  exit 0
fi

printf 'url=%s\tdoh=%s\thttp11=%s\tua=%s\n' "$url_val" "$doh_val" "$has_http11" "$ua_val" >> "${CURL_LOG_TEST:?}"

case "${CURL_SCENARIO:-normal}" in
  system_dns_ok)
    if [ "$has_doh" -eq 1 ]; then
      # Simulate blocked DoH (Issue #387): if --doh-url was unconditionally injected, fail!
      [ "$has_write_out" -eq 0 ] || printf '000'
      exit 28
    fi
    [ -z "$hdr_file" ] || printf 'HTTP/2 200\r\n\r\n' > "$hdr_file"
    printf 'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=none#Node1\n' > "$out_file"
    [ "$has_write_out" -eq 0 ] || printf '200'
    exit 0
    ;;
  dns_fail_then_doh)
    if [ "$has_doh" -eq 0 ]; then
      [ "$has_write_out" -eq 0 ] || printf '000'
      exit 6
    fi
    if [ "$doh_val" = "https://dns.google/dns-query" ]; then
      [ -z "$hdr_file" ] || printf 'HTTP/2 200\r\n\r\n' > "$hdr_file"
      printf '198.51.100.0/24\n' > "$out_file"
      [ "$has_write_out" -eq 0 ] || printf '200'
      exit 0
    fi
    [ "$has_write_out" -eq 0 ] || printf '000'
    exit 6
    ;;
  worker_421_then_http11)
    if [ "$has_http11" -eq 0 ]; then
      [ -z "$hdr_file" ] || printf 'HTTP/2 421\r\n\r\n' > "$hdr_file"
      [ "$has_write_out" -eq 0 ] || printf '421'
      exit 22
    fi
    [ -z "$hdr_file" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr_file"
    printf 'vless://22222222-2222-2222-2222-222222222222@worker.example:443?security=none#WorkerNode\n' > "$out_file"
    [ "$has_write_out" -eq 0 ] || printf '200'
    exit 0
    ;;
  worker_404_except_happ)
    if [[ "$ua_val" == Happ* ]]; then
      [ -z "$hdr_file" ] || printf 'HTTP/2 200\r\n\r\n' > "$hdr_file"
      printf '%s' 'vless://33333333-3333-3333-3333-333333333333@worker.example:443?security=none#HappNode' | base64 > "$out_file"
      [ "$has_write_out" -eq 0 ] || printf '200'
      exit 0
    fi
    printf 'curl: (22) The requested URL returned error: 404\n' >&2
    [ -z "$hdr_file" ] || printf 'HTTP/2 404\r\n\r\n' > "$hdr_file"
    [ "$has_write_out" -eq 0 ] || printf '404'
    exit 22
    ;;
esac

exit 1
EOF_CURL
chmod +x "$WORK_DIR/bin/curl"

# Noisy mock tachyon-core that prints JSON/errors to stdout/stderr on `subscription`
# subcommands and fails `subscription fetch` so ucode falls back to curl.
cat >"$WORK_DIR/bin/tachyon-core" <<'EOF_CORE'
#!/usr/bin/env bash
if [ "${1:-}" = "version" ]; then
  printf 'tachyon-core version 0.4.8\n'
  exit 0
fi
if [ "${1:-}" = "subscription" ]; then
  case "${2:-}" in
    --help|-h)
      printf 'subscription subcommands\n'
      exit 0
      ;;
    hwid)
      printf '{ "X-HWID": "5de2-f1f2-0eff-b56a", "X-Device-OS": "OpenWrt" }\n'
      exit 0
      ;;
    fetch)
      printf 'subscription fetch: HTTP 421 (UA: Mozilla/5.0)\n' >&2
      printf 'unexpected stdout noise from core fetch\n'
      exit 1
      ;;
    normalize)
      exit 1
      ;;
  esac
fi
exit 1
EOF_CORE
chmod +x "$WORK_DIR/bin/tachyon-core"

export PATH="$WORK_DIR/bin:$PATH"
export CURL_LOG_TEST="$CURL_LOG"
export TMP_SING_BOX_FOLDER="$WORK_DIR/sb"
export TMP_RULESET_FOLDER="$WORK_DIR/rulesets"
export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/sb/subscriptions"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
export TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persist"
export TACHYON_PERSISTENT_RULESET_DIR="$WORK_DIR/persist_rulesets"
export SB_VERSION_STATE_FILE="$WORK_DIR/sb-version"
printf '1.12.0\n' > "$SB_VERSION_STATE_FILE"

# 1. Without c-ares, download-subscription uses system DNS first (no --doh-url)!
: >"$CURL_LOG"
CURL_SCENARIO="system_dns_ok" \
  ucode -L "$TACHYON_LIB" "$CACHE_UC" download-subscription \
  "https://sub.example.org/api/v1" "$WORK_DIR/sub1.txt" "" "$WORK_DIR/sub1.hdr" "Happ"

grep -Fq $'url=https://sub.example.org/api/v1\tdoh=\thttp11=0\tua=Happ' "$CURL_LOG" || {
  cat "$CURL_LOG" >&2
  fail "expected first curl call without --doh-url when system DNS works (#387)"
}

# 2. components/updates.uc (list_update) uses system DNS first, and falls back to
#    DoH (https://dns.google/dns-query) ONLY after exit code 6!
cat >"$WORK_DIR/list_fixture.json" <<EOF_LIST
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1"
  },
  "section": [
    {
      ".name": "DirectList",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_ip_lists": [ "https://lists.example.org/subnets.txt" ]
    }
  ]
}
EOF_LIST

: >"$CURL_LOG"
CURL_SCENARIO="dns_fail_then_doh" \
  ucode -L "$TACHYON_LIB" "$UPDATES_UC" rebuild-domain-ip-lists-fixture \
  "$WORK_DIR/list_fixture.json" "DirectList" "$WORK_DIR/nft_batch"

first_call="$(sed -n '1p' "$CURL_LOG")"
second_call="$(sed -n '2p' "$CURL_LOG")"
[[ "$first_call" == *"doh=$tab"* ]] || [[ "$first_call" == *$'\tdoh=\t'* ]] || {
  cat "$CURL_LOG" >&2
  fail "updates.uc first attempt must use system DNS without --doh-url, got: $first_call"
}
[[ "$second_call" == *"doh=https://dns.google/dns-query"* ]] || {
  cat "$CURL_LOG" >&2
  fail "updates.uc second attempt after exit 6 must retry with DoH, got: $second_call"
}

# 3. HTTP 421 Misdirected Request retries with --http1.1 and succeeds
: >"$CURL_LOG"
CURL_SCENARIO="worker_421_then_http11" \
  ucode -L "$TACHYON_LIB" "$CACHE_UC" download-subscription \
  "https://red-leaf-46ef.anton-b00.workers.dev/" "$WORK_DIR/sub421.txt" "" "$WORK_DIR/sub421.hdr" "Happ"

grep -Fq $'http11=1\tua=Happ' "$CURL_LOG" || {
  cat "$CURL_LOG" >&2
  fail "expected HTTP 421 to trigger --http1.1 retry"
}

# 4. Full prepare-caches with noisy tachyon-core + 404 on default UA + 200 on Happ:
#    - default UA fails fast on 404 (1 attempt, not 3!), immediately rotates to Happ
#    - stdout of prepare-caches stays 100% clean (empty when recovered, no JSON/curl noise!)
UCI_STATE="$WORK_DIR/uci.state"
cat >"$UCI_STATE" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=connection
tachyon.Main.subscription_urls=https://red-leaf-46ef.anton-b00.workers.dev/
EOF_UCI

: >"$CURL_LOG"
prepare_stdout="$(
  CURL_SCENARIO="worker_404_except_happ" \
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -L "$TACHYON_LIB" "$CACHE_UC" prepare-caches startup 0 0
)"

if [ -n "$prepare_stdout" ]; then
  fail "prepare-caches leaked subprocess output into stdout (corrupts deferred_sections): '$prepare_stdout'"
fi

default_ua_tries="$(grep -c $'\tua=sing-box/' "$CURL_LOG" || true)"
if [ "$default_ua_tries" -ne 1 ]; then
  cat "$CURL_LOG" >&2
  fail "expected HTTP 404 on default UA to fail fast in 1 attempt before rotating to Happ, got $default_ua_tries"
fi
grep -Fq $'\tua=Happ' "$CURL_LOG" || {
  cat "$CURL_LOG" >&2
  fail "expected rotation to Happ User-Agent profile"
}

printf 'List update DoH fallback & Cloudflare Worker subscription checks passed\n'
