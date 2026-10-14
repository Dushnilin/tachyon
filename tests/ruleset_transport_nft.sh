#!/usr/bin/env bash
# Per-rule and logical-branch transport (network: tcp / udp / any) in JSON
# rulesets must route IP+port tuples into their respective nftables sets
# (ip_ports/ip6_ports for TCP, udp_ip_ports/udp_ip6_ports for UDP), even when
# a single ruleset mixes TCP, UDP, unscoped, and logical rules, and inverted
# rules must never be emitted as positive nftables set elements.
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

export PATH="$FAKE_BIN:$PATH"
export NFT_LOG

nft_ucode() {
  ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc" "$@"
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "section": [
    {
      ".name": "mixed_sec",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ip_cidr": [ "198.51.100.1" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/mixed-ruleset.json" <<'JSON'
{
  "version": 3,
  "rules": [
    {
      "network": "tcp",
      "ip_cidr": [ "192.0.2.10", "2001:db8::10" ],
      "port": [ 443 ]
    },
    {
      "network": [ "udp" ],
      "ip_cidr": [ "192.0.2.20", "2001:db8::20" ],
      "port": [ 50008 ]
    },
    {
      "ip_cidr": [ "192.0.2.30" ]
    },
    {
      "type": "logical",
      "mode": "and",
      "rules": [
        { "network": "udp" },
        { "ip_cidr": [ "192.0.2.40" ], "port_range": [ "19000:19010" ] }
      ]
    },
    {
      "type": "logical",
      "mode": "or",
      "rules": [
        { "network": "tcp", "ip_cidr": [ "192.0.2.50" ], "port": [ 8443 ] },
        { "network": "udp", "ip_cidr": [ "192.0.2.60" ], "port": [ 3478 ] }
      ]
    },
    {
      "network": "udp",
      "ip_cidr": [ "192.0.2.70" ]
    },
    {
      "ip_cidr": [ "192.0.2.99" ],
      "port": [ 443 ],
      "invert": true
    }
  ]
}
JSON

unscoped_out="$WORK_DIR/unscoped.txt"
scoped_out="$WORK_DIR/scoped.txt"

nft_ucode nft-add-json-ruleset-subnets-for-section-fixture \
  "$WORK_DIR/fixture.json" mixed_sec "$WORK_DIR/mixed-ruleset.json" "mixed ruleset" \
  TachyonTable tachyon_subnets tachyon_ip_ports "$unscoped_out" "$scoped_out" 5000

assert_contains() {
  local haystack_file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq "$needle" "$haystack_file"; then
    printf 'Assertion failed (%s): expected to find %q\nActual log:\n' "$label" "$needle" >&2
    cat "$haystack_file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack_file="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "$needle" "$haystack_file"; then
    printf 'Assertion failed (%s): expected NOT to find %q\nActual log:\n' "$label" "$needle" >&2
    cat "$haystack_file" >&2
    exit 1
  fi
}

# 1. Unscoped any-network rule goes to subnets set
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tTachyonTable\ttachyon_rule_mixed_sec_subnets\t{ 192.0.2.30 }' "unscoped any-network subnet"

# 2. TCP-only rules (direct and logical-or branch) go to TCP ip_ports / ip6_ports sets
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tTachyonTable\ttachyon_rule_mixed_sec_ip_ports\t{ 192.0.2.10 . 443,192.0.2.50 . 8443 }' "TCP IPv4 rules in ip_ports"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tTachyonTable\ttachyon_rule_mixed_sec_ip6_ports\t{ 2001:db8::10 . 443 }' "TCP IPv6 rules in ip6_ports"

# 3. UDP-only rules (direct, logical-and, logical-or branch, portless UDP) go to UDP udp_ip_ports / udp_ip6_ports sets
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tTachyonTable\ttachyon_rule_mixed_sec_udp_ip_ports\t{ 192.0.2.20 . 50008,192.0.2.40 . 19000-19010,192.0.2.60 . 3478,192.0.2.70 . 1-65535 }' "UDP IPv4 rules in udp_ip_ports"
assert_contains "$NFT_LOG" $'nft\tadd\telement\tinet\tTachyonTable\ttachyon_rule_mixed_sec_udp_ip6_ports\t{ 2001:db8::20 . 50008 }' "UDP IPv6 rules in udp_ip6_ports"

# 4. Cross-pollution checks: UDP rules must never appear in TCP sets or unscoped subnets, and TCP rules must never appear in UDP sets
tcp_set_lines="$(grep -F $'tachyon_rule_mixed_sec_ip_ports\t{' "$NFT_LOG" || true)"
udp_set_lines="$(grep -F $'tachyon_rule_mixed_sec_udp_ip_ports\t{' "$NFT_LOG" || true)"

for udp_ip in 192.0.2.20 192.0.2.40 192.0.2.60 192.0.2.70; do
  if printf '%s\n' "$tcp_set_lines" | grep -Fq "$udp_ip"; then
    printf 'FAIL: UDP rule %s leaked into TCP ip_ports set: %s\n' "$udp_ip" "$tcp_set_lines" >&2
    exit 1
  fi
done

for tcp_ip in 192.0.2.10 192.0.2.50; do
  if printf '%s\n' "$udp_set_lines" | grep -Fq "$tcp_ip"; then
    printf 'FAIL: TCP rule %s leaked into UDP udp_ip_ports set: %s\n' "$tcp_ip" "$udp_set_lines" >&2
    exit 1
  fi
done

# 5. Inverted rule must never be emitted anywhere
assert_not_contains "$NFT_LOG" "192.0.2.99" "inverted rule must be excluded from nft sets"

echo "ruleset_transport_nft: all checks passed"
