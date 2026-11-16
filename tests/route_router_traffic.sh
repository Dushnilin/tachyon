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

assert_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local label="$4"

  local first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$file" | head -1 | cut -d: -f1 || true)"
  [ -n "$first_line" ] || fail "$label: '$first' is missing"
  [ -n "$second_line" ] || fail "$label: '$second' is missing"
  [ "$first_line" -lt "$second_line" ] ||
    fail "$label: '$first' (line $first_line) must come before '$second' (line $second_line), otherwise the rule is dead"
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
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tmeta\tnfproto\tipv4\tmeta\tl4proto\ttcp\tcounter\tredirect\tto\t:1604' "enable: tcp redirect to 1604"
assert_before "$NFT_LOG" $'ip\tdaddr\t@localv4\treturn' $'counter\tredirect\tto\t:1604' "enable: local bypass must precede the redirect"

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
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tmeta\tnfproto\tipv4\tmeta\tl4proto\ttcp\tcounter\tredirect\tto\t:1604' "sync(enabled): redirects to port"

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

# Test 6: Active IPv6 adds output_tproxy6 rules
: > "$NFT_LOG"
TACHYON_MOCK_WAN6_PD="2001:db8::/56" TACHYON_UCI_STATE_FILE="$STATE_ENABLED" \
  nft_ucode nft-sync-router-output-intercept TachyonTable localv4 0x00100000
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_redirect\tmeta\tnfproto\tipv4\tmeta\tl4proto\ttcp\tcounter\tredirect\tto\t:1604' "dual-stack sync: keeps ipv4 tcp redirect"
assert_contains "$NFT_LOG" $'nft\tadd\trule\tinet\tTachyonTable\toutput_tproxy6\tmeta\tl4proto\ttcp\tmeta\tmark\tset\tmeta\tmark\t|\t0x04000000\tcounter' "dual-stack sync: marks router ipv6 tcp in output_tproxy6"

printf 'ALL TESTS PASSED for route_router_traffic\n'
