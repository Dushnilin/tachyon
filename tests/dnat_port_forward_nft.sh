#!/usr/bin/env bash
# Port forwarding / DNAT isolation test:
# 1. DNAT connections must be immune to TPROXY capture:
#    - ct status dnat return must be placed at the top of mangle, proxy, and mangle_forward
#    - Firewall redirects must populate tachyon_dnat_tcp_v4 and add bypass return rules
#    - Fully routed clients must check ct status dnat before marking
# 2. inet fw4 forward must NEVER contain "meta mark ... return" (which drops forwarded packets)
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

FAKE_BIN="$WORK_DIR/bin"
NFT_LOG="$WORK_DIR/nft.log"
mkdir -p "$FAKE_BIN"
: > "$NFT_LOG"

cat >"$FAKE_BIN/nft" <<'SH'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'nft'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${NFT_LOG:?}"

if [ "${1:-}" = "delete" ]; then
  touch "$WORK_DIR/deleted_9999"
  exit 0
fi

if [ "${1:-}" = "list" ] || [ "${1:-}" = "-a" ]; then
  if [[ "$*" =~ "forward" ]]; then
    if [ -f "$WORK_DIR/deleted_9999" ]; then
      printf 'table inet fw4 {\n\tchain forward { # handle 2\n\t\ttype filter hook forward priority filter; policy drop;\n\t}\n}\n'
    else
      printf 'table inet fw4 {\n\tchain forward { # handle 2\n\t\ttype filter hook forward priority filter; policy drop;\n\t\tmeta mark 0x04000000 return # handle 9999\n\t}\n}\n'
    fi
    exit 0
  fi
fi

if [ "${1:-}" = "-f" ] && [ -f "${2:-}" ]; then
  while read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^add[[:space:]]+element[[:space:]]+inet[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
      printf 'nft\tadd\telement\tinet\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >> "${NFT_LOG:?}"
    else
      printf '%s\n' "$line" >> "${NFT_LOG:?}"
    fi
  done < "$2"
fi
SH
chmod +x "$FAKE_BIN/nft"

cat >"$FAKE_BIN/modprobe" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/modprobe"

cat >"$FAKE_BIN/ip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/ip"

export PATH="$FAKE_BIN:$PATH"
export NFT_LOG
export WORK_DIR  # fake nft uses $WORK_DIR to track state; must be visible to child processes

# 1. Test base runtime generation
ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc" nft-create-runtime-base \
  TachyonTable localv4 tachyon_subnets tachyon_ports tachyon_ip_ports tachyon_interfaces "br-lan" \
  0x04000000 0x08000000 198.18.0.0/15 1602 0 localv6 tachyon_subnets6 tachyon_ip6_ports fc00::/18 ::1 0 off

# Verify ct status dnat return is in mangle, proxy, and mangle_forward
grep -E 'nft[[:space:]]+add[[:space:]]+rule[[:space:]]+inet[[:space:]]+TachyonTable[[:space:]]+mangle[[:space:]]+ct[[:space:]]+status[[:space:]]+dnat[[:space:]]+return' "$NFT_LOG" || \
  fail "expected ct status dnat return in chain mangle"

grep -E 'nft[[:space:]]+add[[:space:]]+rule[[:space:]]+inet[[:space:]]+TachyonTable[[:space:]]+proxy[[:space:]]+ct[[:space:]]+status[[:space:]]+dnat[[:space:]]+return' "$NFT_LOG" || \
  fail "expected ct status dnat return in chain proxy"

grep -E 'nft[[:space:]]+add[[:space:]]+rule[[:space:]]+inet[[:space:]]+TachyonTable[[:space:]]+mangle_forward[[:space:]]+ct[[:space:]]+status[[:space:]]+dnat[[:space:]]+return' "$NFT_LOG" || \
  fail "expected ct status dnat return in chain mangle_forward"

# 2. Test fully routed client rule insertion includes ct status dnat return
: > "$NFT_LOG"
ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc" nft-insert-fully-routed-ip-rules \
  "192.168.1.100" "TachyonTable" "tachyon_interfaces" "localv4" "localv6" "0x04000000"
ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc" nft-insert-fully-routed-ip-rules \
  "11:22:33:44:55:66" "TachyonTable" "tachyon_interfaces" "localv4" "localv6" "0x04000000"

grep -E 'nft[[:space:]]+insert[[:space:]]+rule[[:space:]]+inet[[:space:]]+TachyonTable[[:space:]]+mangle[[:space:]]+ip[[:space:]]+saddr[[:space:]]+192\.168\.1\.100[[:space:]]+ct[[:space:]]+status[[:space:]]+dnat[[:space:]]+return' "$NFT_LOG" || \
  fail "expected IP fully routed insertion to include ct status dnat return"

grep -E 'nft[[:space:]]+insert[[:space:]]+rule[[:space:]]+inet[[:space:]]+TachyonTable[[:space:]]+mangle[[:space:]]+ether[[:space:]]+saddr[[:space:]]+11:22:33:44:55:66[[:space:]]+ct[[:space:]]+status[[:space:]]+dnat[[:space:]]+return' "$NFT_LOG" || \
  fail "expected MAC fully routed insertion to include ct status dnat return"

# 3. Test ensure_tproxy_route_rule does NOT insert return into fw4 forward, and purges legacy handle
: > "$NFT_LOG"
ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc" ensure-tproxy-route-rule \
  "TachyonTable" "0x04000000" "/dev/null"

if grep -E 'nft[[:space:]]+insert[[:space:]]+rule[[:space:]]+inet[[:space:]]+fw4[[:space:]]+forward.*return' "$NFT_LOG"; then
  fail "ensure_tproxy_route_rule must NEVER insert return into fw4 forward"
fi

grep -E 'nft[[:space:]]+delete[[:space:]]+rule[[:space:]]+inet[[:space:]]+fw4[[:space:]]+forward[[:space:]]+handle[[:space:]]+9999' "$NFT_LOG" || \
  fail "ensure_tproxy_route_rule must delete legacy meta mark return rule handle in fw4 forward"

echo "PASS: DNAT port forwarding nftables isolation verified"
