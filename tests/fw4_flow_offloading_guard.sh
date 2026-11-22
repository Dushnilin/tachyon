#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

APPLY_UC="$TACHYON_LIB/nft/apply.uc"

cat >"$WORK_DIR/tproxy-v6.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "proxy_mode": "tproxy",
    "fakeip": "1",
    "fakeip_inet4_range": "198.18.0.0/15",
    "fakeip_inet6_range": "fc00::/18",
    "ipv6_enabled": "1",
    "ipv6_mode": "dual_stack"
  }
}
JSON

cat >"$WORK_DIR/tun.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "proxy_mode": "tun",
    "tun_interface": "tun0",
    "fakeip": "1",
    "ipv6_enabled": "0",
    "ipv6_mode": "off"
  }
}
JSON

OUT_TPROXY="$(ucode -L "$TACHYON_LIB" "$APPLY_UC" render-fw4-flow-offload-guard-fixture "$WORK_DIR/tproxy-v6.json")"
printf '%s\n' "$OUT_TPROXY" | grep -Fq 'meta mark & 0x04000000 != 0 ct state established,related accept comment "Tachyon: skip flow offload"' ||
  fail "missing TProxy fwmark offload guard"
printf '%s\n' "$OUT_TPROXY" | grep -Fq 'meta mark & 0x08000000 != 0 ct state established,related accept' ||
  fail "missing outbound fwmark offload guard"
printf '%s\n' "$OUT_TPROXY" | grep -Fq 'meta mark & 0x40000000 != 0 ct state established,related accept' ||
  fail "missing bypass fwmark offload guard"
printf '%s\n' "$OUT_TPROXY" | grep -Fq 'ip daddr 198.18.0.0/15 ct state established,related accept' ||
  fail "missing FakeIPv4 daddr offload guard"
printf '%s\n' "$OUT_TPROXY" | grep -Fq 'ip6 daddr fc00::/18 ct state established,related accept' ||
  fail "missing FakeIPv6 daddr offload guard"
printf '%s\n' "$OUT_TPROXY" | grep -Fq 'meta l4proto { tcp, udp } th dport 53 ct state established,related accept' ||
  fail "missing DNS dport 53 offload guard"
if printf '%s\n' "$OUT_TPROXY" | grep -Eq 'ct state[^a-zA-Z]*new'; then
  fail "offload guard must never accept ct state new packets"
fi

OUT_TUN="$(ucode -L "$TACHYON_LIB" "$APPLY_UC" render-fw4-flow-offload-guard-fixture "$WORK_DIR/tun.json")"
printf '%s\n' "$OUT_TUN" | grep -Fq 'iifname "tun0" ct state established,related accept comment "Tachyon: skip flow offload"' ||
  fail "missing TUN iifname offload guard"
printf '%s\n' "$OUT_TUN" | grep -Fq 'oifname "tun0" ct state established,related accept comment "Tachyon: skip flow offload"' ||
  fail "missing TUN oifname offload guard"
printf '%s\n' "$OUT_TUN" | grep -Fq 'meta mark & 0x00002022 != 0 ct state established,related accept' ||
  fail "missing TUN auto_route fwmark offload guard"
if printf '%s\n' "$OUT_TUN" | grep -Fq 'ip6 daddr fc00::/18'; then
  fail "ipv6_mode=off must not emit FakeIPv6 offload guard"
fi

mkdir -p "$WORK_DIR/uci" "$WORK_DIR/fw4_inc" "$WORK_DIR/fw4_inc/chain-pre/forward"
cat >"$WORK_DIR/uci/tachyon" <<'UCI'
config settings 'settings'
	option proxy_mode 'tproxy'
	option fakeip '1'
	option ipv6_enabled '0'
UCI

LEGACY_FILE="$WORK_DIR/fw4_inc/chain-pre/forward/10-tachyon-offload.nft"
printf 'meta mark & 0x04000000 != 0 ct state established,related accept comment "Tachyon: skip flow offload"\n' >"$LEGACY_FILE"

TACHYON_UCI_CONFIG_DIR="$WORK_DIR/uci" \
TACHYON_FW4_INCLUDE_ROOT="$WORK_DIR/fw4_inc" \
  ucode -L "$TACHYON_LIB" "$APPLY_UC" sync-fw4-flow-offload-guard >/dev/null

INC_FILE="$WORK_DIR/fw4_inc/ruleset-post/10-tachyon-offload.nft"
[ -s "$INC_FILE" ] || fail "sync-fw4-flow-offload-guard must write $INC_FILE"
[ ! -e "$LEGACY_FILE" ] || fail "sync-fw4-flow-offload-guard must delete legacy $LEGACY_FILE"
grep -Fq 'insert rule inet fw4 forward meta mark & 0x04000000 != 0 ct state established,related accept comment "Tachyon: skip flow offload"' "$INC_FILE" ||
  fail "persisted fw4 ruleset-post include missing insert skip rule"

line_sport53="$(grep -n 'th sport 53' "$INC_FILE" | head -n1 | cut -d: -f1)"
line_04="$(grep -n '0x04000000' "$INC_FILE" | head -n1 | cut -d: -f1)"
[ -n "$line_sport53" ] && [ -n "$line_04" ] && [ "$line_sport53" -lt "$line_04" ] ||
  fail "ruleset-post include must reverse insert order so 0x04000000 lands first in chain forward"

cat >"$WORK_DIR/broken-forward.txt" <<'TXT'
table inet fw4 {
	chain forward {
		type filter hook forward priority filter; policy drop;
		meta l4proto { tcp, udp } flow add @ft
		meta mark & 0x04000000 != 0x00000000 ct state established,related accept comment "Tachyon: skip flow offload"
	}
}
TXT
if ucode -L "$TACHYON_LIB" "$APPLY_UC" check-fw4-flow-offload-order "$WORK_DIR/broken-forward.txt" >/dev/null 2>&1; then
  fail "check-fw4-flow-offload-order must fail when flow add @ft precedes Tachyon: skip flow offload"
fi

cat >"$WORK_DIR/fixed-forward.txt" <<'TXT'
table inet fw4 {
	chain forward {
		type filter hook forward priority filter; policy drop;
		meta mark & 0x04000000 != 0x00000000 ct state established,related accept comment "Tachyon: skip flow offload"
		meta l4proto { tcp, udp } flow add @ft
	}
}
TXT
ucode -L "$TACHYON_LIB" "$APPLY_UC" check-fw4-flow-offload-order "$WORK_DIR/fixed-forward.txt" ||
  fail "check-fw4-flow-offload-order must pass when Tachyon: skip flow offload precedes flow add @ft"

TACHYON_UCI_CONFIG_DIR="$WORK_DIR/uci" \
TACHYON_FW4_INCLUDE_ROOT="$WORK_DIR/fw4_inc" \
  ucode -L "$TACHYON_LIB" "$APPLY_UC" remove-fw4-flow-offload-guard >/dev/null
[ ! -e "$INC_FILE" ] || fail "remove-fw4-flow-offload-guard must remove $INC_FILE"
[ ! -e "$LEGACY_FILE" ] || fail "remove-fw4-flow-offload-guard must remove $LEGACY_FILE"

printf 'fw4_flow_offloading_guard: OK\n'
