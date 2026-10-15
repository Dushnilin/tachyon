#!/usr/bin/env bash
# disable_quic has to reach traffic that never reaches sing-box, and since the
# option became three modes (off/tunneled/all) every layer has to agree on them.
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

# UDP only. An earlier version of this rule said "meta l4proto udp tcp" - one
# nft expression naming two protocols - which the kernel rejects with
# "conflicting transport layer protocols", and the drop took TCP/443 with it.
#
# reject with icmpx, not drop: a client whose QUIC is dropped waits out its own
# timeout before falling back to TCP, an ICMP port-unreachable makes it
# immediate.
QUIC_TUNNELED_RULE=$'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tmeta\tl4proto\tudp\tth\tdport\t443\tmeta\tmark\t&\t0x00100000\t!=\t0x00100000\tcounter\treject\twith\ticmpx\ttype\tport-unreachable'
QUIC_ALL_RULE=$'nft\tadd\trule\tinet\tTachyonTable\tmangle\tiifname\t@tachyon_interfaces\tmeta\tl4proto\tudp\tth\tdport\t443\tcounter\treject\twith\ticmpx\ttype\tport-unreachable'

base_args=(nft-create-runtime-base TachyonTable localv4 tachyon_subnets
  tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" 0x00100000
  0x00200000 198.18.0.0/15 1602 0 "" "" "" "" "" 0)

run_base() {
  : >"$NFT_LOG"
  TACHYON_UCI_STATE_FILE="$WORK_DIR/none.state" \
    ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" "${base_args[@]}" "$1"
}

# 1. Legacy flag value "1" keeps its meaning: the tunneled rule.
run_base 1
grep -Fq "$QUIC_TUNNELED_RULE" "$NFT_LOG" ||
  fail "disable_quic=1 must reject UDP/443 that was not marked for tproxy"

# The reject has to sit after the fakeip marking rules. Traffic that sing-box is
# going to handle must be left alone so the engine keeps deciding for it.
quic_line="$(awk -v pat='th\tdport\t443\tmeta\tmark' 'index($0, pat) { print NR; exit }' "$NFT_LOG")"
fakeip_line="$(awk -v pat='ip\tdaddr\t198.18.0.0/15\tmeta\tl4proto\tudp\tmeta\tmark\tset' 'index($0, pat) { print NR; exit }' "$NFT_LOG")"

[ -n "$quic_line" ] || fail "QUIC reject rule was not emitted"
[ -n "$fakeip_line" ] || fail "fakeip marking rule was not emitted, cannot verify ordering"
[ "$fakeip_line" -lt "$quic_line" ] ||
  fail "QUIC reject must come after fakeip marking, else proxied QUIC is rejected before sing-box sees it"

# 2. The explicit mode name behaves exactly like the legacy flag.
run_base tunneled
grep -Fq "$QUIC_TUNNELED_RULE" "$NFT_LOG" ||
  fail "disable_quic=tunneled must reject UDP/443 that was not marked for tproxy"

# 3. "all" drops the mark condition: every UDP/443 is rejected, marked or not.
run_base all
grep -Fq "$QUIC_ALL_RULE" "$NFT_LOG" ||
  fail "disable_quic=all must reject every UDP/443 regardless of tproxy mark"
if grep -Fq "$QUIC_TUNNELED_RULE" "$NFT_LOG"; then
  fail "disable_quic=all must not emit the mark-conditioned variant as well"
fi

# 4. Off means no rule at all, in every spelling the normalizer accepts.
for off_value in 0 off ""; do
  run_base "$off_value"
  if grep -Fq 'dport\t443\t' "$NFT_LOG"; then
    fail "disable_quic='$off_value' must not install any UDP/443 rule"
  fi
done

# 5. The settings-driven entry point has to read the option too.
run_from_uci() {
  cat >"$WORK_DIR/quic.state" <<EOF_UCI
tachyon.settings=settings
tachyon.settings.source_network_interfaces=br-lan
tachyon.settings.disable_quic=$1
EOF_UCI
  : >"$NFT_LOG"
  TACHYON_UCI_STATE_FILE="$WORK_DIR/quic.state" \
    ucode -L "$TACHYON_LIB" "$NFT_RUNTIME" nft-create-runtime-base-from-uci \
    TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports \
    tachyon_interfaces 0x00100000 0x00200000 198.18.0.0/15 1602
}

run_from_uci 1
grep -Fq "$QUIC_TUNNELED_RULE" "$NFT_LOG" ||
  fail "settings.disable_quic=1 must reject the unmarked UDP/443"

run_from_uci all
grep -Fq "$QUIC_ALL_RULE" "$NFT_LOG" ||
  fail "settings.disable_quic=all must reject every UDP/443"

run_from_uci 0
if grep -Fq 'dport\t443\t' "$NFT_LOG"; then
  fail "settings.disable_quic=0 must not install any UDP/443 rule"
fi

# 6. The engine's own reject rules follow the same normalizer: everything but
# "off" pushes them into the route, "off" leaves the route clean.
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

route_fixture() {
  local mode="$1" out="$2"
  cat >"$WORK_DIR/route_fixture.json" <<EOF_UCI
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1",
    "disable_quic": "$mode"
  },
  "section": [
    {
      ".name": "sec_route",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_route-out\"}" ],
      "community_lists": [ "youtube" ]
    }
  ]
}
EOF_UCI
  mkdir -p "$out.section-cache" "$out.rulesets"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/route_fixture.json" "$out" "127.0.0.1" "0" "1"
}

for on_mode in 1 tunneled all; do
  route_fixture "$on_mode" "$WORK_DIR/out_quic_$on_mode"
  grep -Fq '"protocol": "quic"' "$WORK_DIR/out_quic_$on_mode" ||
    fail "disable_quic=$on_mode must push the route-level QUIC reject"
done

route_fixture off "$WORK_DIR/out_quic_off"
if grep -Fq '"protocol": "quic"' "$WORK_DIR/out_quic_off"; then
  fail "disable_quic=off must leave the route without QUIC rejects"
fi

printf 'disable_quic direct-coverage checks passed\n'
