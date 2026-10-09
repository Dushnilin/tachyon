#!/usr/bin/env bash
# disable_quic has to reach traffic that never reaches sing-box.
#
# singbox/route.uc rejects UDP/443 inside the engine, which only helps for
# connections the tproxy rules handed over. A client whose destination is not
# marked keeps using HTTP/3 straight out of br-lan, where the local DPI mangles
# it - the measured symptom was the VK app loading nothing while Telegram, which
# goes through the proxy, worked fine.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

NFT_RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"
NFT_LOG="$WORK_DIR/nft.log"

# Real nft would need a live netlink socket and a pre-created table. Capture the
# command line instead, the same way nft_apply.sh does.
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

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$WORK_DIR/none.state" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" \
  nft-create-runtime-base TachyonTable localv4 tachyon_subnets tachyon_ports \
  tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000 0x00200000 \
  198.18.0.0/15 1602 0 "" "" "" "" "" 0 1

QUIC_RULE=$'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tmeta\tl4proto\tudp\ttcp\tdport\t443\tmeta\tmark\t&\t0x00100000\t!=\t0x00100000\tcounter\tdrop'

grep -Fq "$QUIC_RULE" "$NFT_LOG" ||
  fail "disable_quic must drop UDP/443 that was not marked for tproxy"

# The drop has to sit after the fakeip marking rules. Traffic that sing-box is
# going to handle must be left alone so the engine keeps deciding for it.
quic_line="$(awk -v pat='tcp\tdport\t443\tmeta\tmark' 'index($0, pat) { print NR; exit }' "$NFT_LOG")"
fakeip_line="$(awk -v pat='ip\tdaddr\t198.18.0.0/15\tmeta\tl4proto\tudp\tmeta\tmark\tset' 'index($0, pat) { print NR; exit }' "$NFT_LOG")"

[ -n "$quic_line" ] || fail "QUIC drop rule was not emitted"
[ -n "$fakeip_line" ] || fail "fakeip marking rule was not emitted, cannot verify ordering"
[ "$fakeip_line" -lt "$quic_line" ] ||
  fail "QUIC drop must come after fakeip marking, else proxied QUIC is dropped before sing-box sees it"

# Same base, disable_quic off: nothing may be dropped.
: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$WORK_DIR/none.state" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" \
  nft-create-runtime-base TachyonTable localv4 tachyon_subnets tachyon_ports \
  tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000 0x00200000 \
  198.18.0.0/15 1602 0 "" "" "" "" "" 0 0

if grep -Fq "$QUIC_RULE" "$NFT_LOG"; then
  fail "disable_quic=0 must not install the QUIC drop rule"
fi

# And the settings-driven entry point has to read the option too.
cat >"$WORK_DIR/quic.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.settings.disable_quic=1
EOF_UCI

: > "$NFT_LOG"
TACHYON_UCI_STATE_FILE="$WORK_DIR/quic.state" \
  ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" \
  nft-create-runtime-base-from-uci TachyonTable localv4 tachyon_subnets \
  tachyon_ports tachyon_ip_ports tachyon_interfaces 0x00100000 0x00200000 \
  198.18.0.0/15 1602

grep -Fq "$QUIC_RULE" "$NFT_LOG" ||
  fail "settings.disable_quic=1 must install the QUIC drop rule"

printf 'disable_quic direct-coverage checks passed\n'