#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
NFT_LOG="$WORK_DIR/nft.log"
LOGGER_LOG="$WORK_DIR/logger.log"
export NFT_LOG LOGGER_LOG WORK_DIR

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'nft log:\n' >&2
  cat "$NFT_LOG" >&2 2>/dev/null || true
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  grep -Fq "$expected" "$file" || fail "$label: expected '$expected'"
}

mkdir -p "$WORK_DIR/bin"

cat >"$WORK_DIR/bin/nft" <<NFT
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "\$@"; do
    printf '\t%s' "\$arg"
  done
  printf '\n'
} >> "\${NFT_LOG:?}"

if [ "\$#" -ge 5 ] && [ "\$1" = "flush" ] && [ "\$2" = "chain" ]; then
  if [ ! -f "$WORK_DIR/chain_exists" ]; then
    exit 1
  fi
fi

if [ "\$#" -ge 5 ] && [ "\$1" = "add" ] && [ "\$2" = "chain" ]; then
  touch "$WORK_DIR/chain_exists"
fi

if [ "\$#" -ge 5 ] && [ "\$1" = "delete" ] && [ "\$2" = "chain" ]; then
  rm -f "$WORK_DIR/chain_exists"
fi
NFT
chmod 0755 "$WORK_DIR/bin/nft"

cat >"$WORK_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
set -eo pipefail
printf 'logger\t%s\n' "$*" >> "${LOGGER_LOG:?}"
LOGGER
chmod 0755 "$WORK_DIR/bin/logger"

export PATH="$WORK_DIR/bin:$PATH"

nft_ucode() {
  ucode -S -L "$TACHYON_LIB" "$NFT_RUNTIME" "$@"
}

# Test 1: Direct enable call
: > "$NFT_LOG"
rm -f "$WORK_DIR/chain_exists"
nft_ucode nft-enable-router-output-intercept TachyonTable localv4 0x00100000 1
assert_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tTachyonTable\toutput_redirect\t{ type nat hook output priority -100; policy accept; }' "enable: creates chain output_redirect"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tct\tstatus\tdnat\treturn' "enable: ct status dnat return"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tip\tdaddr\t@localv4\treturn' "enable: localv4 bypass"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\ttcp\tdport\t53\treturn' "enable: port 53 bypass"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tudp\tdport\t123\treturn' "enable: exclude_ntp bypass"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tmeta\tmark\t0x00100000\treturn' "enable: outbound_mark bypass"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tmeta\tl4proto\ttcp\tcounter\tredirect\tto\t:1604' "enable: tcp redirect to 1604"

# Test 2: Direct disable call
: > "$NFT_LOG"
nft_ucode nft-disable-router-output-intercept TachyonTable
assert_contains "$NFT_LOG" $'nft\tdelete\tchain\tinet\tTachyonTable\toutput_redirect' "disable: deletes chain output_redirect"

# Test 3: Sync from UCI - when enabled
STATE_ENABLED="$WORK_DIR/enabled.state"
cat >"$STATE_ENABLED" <<'STATE'
tachyon.settings=settings
tachyon.settings.route_router_traffic=1
tachyon.settings.route_router_traffic_section=proxy_sec
tachyon.settings.exclude_ntp=1
tachyon.proxy_sec=section
tachyon.proxy_sec.enabled=1
tachyon.proxy_sec.routing_mode=proxy
tachyon.proxy_sec.mark=354
tachyon.proxy_sec.tproxy_port=10080
STATE

: > "$NFT_LOG"
rm -f "$WORK_DIR/chain_exists"
TACHYON_UCI_STATE_FILE="$STATE_ENABLED" nft_ucode nft-sync-router-output-intercept TachyonTable localv4 0x00100000
assert_contains "$NFT_LOG" $'nft\tadd\tchain\tinet\tTachyonTable\toutput_redirect\t{ type nat hook output priority -100; policy accept; }' "sync(enabled): creates chain"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tmeta\tl4proto\ttcp\tcounter\tredirect\tto\t:1604' "sync(enabled): redirects to port"

# Test 4: Sync from UCI - when disabled
STATE_DISABLED="$WORK_DIR/disabled.state"
cat >"$STATE_DISABLED" <<'STATE'
tachyon.settings=settings
tachyon.settings.route_router_traffic=0
tachyon.settings.route_router_traffic_section=proxy_sec
tachyon.proxy_sec=section
tachyon.proxy_sec.enabled=1
tachyon.proxy_sec.routing_mode=proxy
tachyon.proxy_sec.mark=354
STATE

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$STATE_DISABLED" nft_ucode nft-sync-router-output-intercept TachyonTable localv4 0x00100000
assert_contains "$NFT_LOG" $'nft\tdelete\tchain\tinet\tTachyonTable\toutput_redirect' "sync(disabled): deletes chain"

# Test 5: Verify UCI setting loads route_router_traffic
CHECK_SETTINGS=$(TACHYON_UCI_STATE_FILE="$STATE_DISABLED" ucode -S -L "$TACHYON_LIB" -e '
  let uci = require("core.uci");
  let val = uci.get("tachyon.settings.route_router_traffic");
  print("val=" + val);
')
if [ "$CHECK_SETTINGS" != "val=0" ]; then
  fail "UCI route_router_traffic expected val=0, got '$CHECK_SETTINGS'"
fi

printf 'ALL TESTS PASSED for route_router_traffic\n'
