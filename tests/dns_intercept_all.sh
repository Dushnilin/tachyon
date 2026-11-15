#!/usr/bin/env bash
# dns_intercept_all closes the "own resolver" hole: a LAN client asking 8.8.8.8
# directly gets real IPs instead of fakeip and walks past domain sections, even
# with Tachyon healthy. Plain DNS is redirected to the router resolver, DoT is
# refused, DoH is blocked; off by default, so nothing changes unless enabled.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
NFT_LOG="$WORK_DIR/nft.log"

# Capture nft command lines instead of touching a live ruleset.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'NFT_STUB'
#!/usr/bin/env bash
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"
exit 0
NFT_STUB
chmod +x "$WORK_DIR/bin/nft"
export PATH="$WORK_DIR/bin:$PATH"
export NFT_LOG

DNS_UDP_RULE=$'nft\tadd\trule\tinet\tTachyonTable\tdns_redirect\tiifname\t@tachyon_interfaces\tudp\tdport\t53\tcounter\tredirect\tto\t:53'
DNS_TCP_RULE=$'nft\tadd\trule\tinet\tTachyonTable\tdns_redirect\tiifname\t@tachyon_interfaces\ttcp\tdport\t53\tcounter\tredirect\tto\t:53'
DOT_RULE=$'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tmeta\tl4proto\t{ tcp, udp }\tth\tdport\t853\tmeta\tmark\tset\tmeta\tmark\t&\t0xffefffff\tcounter\treject\twith\ticmpx\ttype\tport-unreachable'

base_args=(nft-create-runtime-base TachyonTable localv4 tachyon_subnets
  tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000
  0x00200000 198.18.0.0/15 1602 0 "" "" "" "" "" 0 0)

# Runs nft_create_runtime_base with the stub nft; $1 is dns_intercept_all.
run_base() {
  : >"$NFT_LOG"
  TACHYON_UCI_STATE_FILE="$WORK_DIR/none.state" \
    ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" "${base_args[@]}" "$@"
}

# Off (default and explicit): no redirect, no DoT reject.
for value in "" 0; do
  run_base "$value"
  if grep -Fq $'redirect\tto\t:53' "$NFT_LOG" || grep -Fq $'dport\t853' "$NFT_LOG"; then
    fail "dns_intercept_all='$value' must not intercept LAN DNS"
  fi
done

run_base 1
grep -Fq "$DNS_UDP_RULE" "$NFT_LOG" || fail "UDP DNS from LAN is not redirected to the router resolver"
grep -Fq "$DNS_TCP_RULE" "$NFT_LOG" || fail "TCP DNS from LAN is not redirected to the router resolver"
grep -Fq "$DOT_RULE" "$NFT_LOG" || fail "DNS-over-TLS is not refused"

# Source-aware redirects to the core DNS inbound must still win: they come first.
source_line="$(awk -v pat=$'dns_redirect\tiifname\t@tachyon_interfaces\tip\tsaddr' 'index($0, pat) { print NR; exit }' "$NFT_LOG")"
intercept_line="$(awk -v pat=$'udp\tdport\t53\tcounter\tredirect\tto\t:53' 'index($0, pat) { print NR; exit }' "$NFT_LOG")"
[[ -n "$source_line" && "$source_line" -lt "$intercept_line" ]] ||
  fail "general DNS intercept must come after the source-aware DNS redirects"

# The from-UCI path turns DoH blocking on together with the intercept, in nft
# and in the core route rules.
grep -Fq 'bool_option(settings, "block_doh", false) || bool_option(settings, "dns_intercept_all", false) ? "1" : "0"' "$NFT_RUNTIME" ||
  fail "dns_intercept_all must enable the nft DoH block"
grep -Fq 'bool_option(settings, "block_doh", false) || bool_option(settings, "dns_intercept_all", false)' \
  "$TACHYON_LIB/tachyon_core/route.uc" || fail "dns_intercept_all must enable the core DoH reject"
for f in "$TACHYON_LIB/service/state.uc" "$NFT_RUNTIME"; do
  grep -Fq '"settings.dns_intercept_all"' "$f" || fail "${f##*/}: toggling dns_intercept_all must change the nft signature"
done
printf 'dns intercept tests passed\n'
