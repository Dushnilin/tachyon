#!/usr/bin/env bash
# The Discord community list carries shared Cloudflare Anycast ranges. Those
# ranges are there for the voice ports (UDP), but they were added to the shared
# ip_ports set, which feeds BOTH the TCP and the UDP matcher. A TCP:443
# connection to any other Cloudflare-hosted site therefore matched the Discord
# section and picked up its desync strategy.
#
# The fix splits them into a UDP-only pair of sets. The invariant is that an
# ip.port entry which may only match UDP is never reachable from a TCP matcher -
# and that is a property of which set name each matcher names, so it is asserted
# on the generated rules rather than on the section configuration.
#
# This is the class of defect behind the Discord voice regression documented in
# the 1.4.6 release notes: traffic that belongs to nobody gets captured by
# somebody.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

APPLY_UC="$TACHYON_LIB/nft/apply.uc"
[ -f "$APPLY_UC" ] || fail "nft/apply.uc not found at $APPLY_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

body="$(awk '/^function nft_add_section_priority_rules\(/,/^\}/' "$APPLY_UC")"
[ -n "$body" ] || fail "could not locate nft_add_section_priority_rules() in nft/apply.uc"

# --- 1. the split exists ---------------------------------------------------
grep -q 'udp_ip_ports:' "$APPLY_UC" ||
  fail "nft/apply.uc defines no udp_ip_ports set: the shared set keeps feeding the TCP matcher"
ok

grep -q 'udp_ip6_ports:' "$APPLY_UC" ||
  fail "nft/apply.uc defines no udp_ip6_ports set"
ok

# --- 2. the UDP matchers must name the UDP-only sets -----------------------
# This is the load-bearing assertion: the bug was precisely a UDP matcher
# pointing at the TCP-shared set.
for pair in "match_ip_port4_udp:udp_ip_ports" "match_ip_port6_udp:udp_ip6_ports"; do
  var="${pair%%:*}"
  want="${pair##*:}"
  line="$(printf '%s\n' "$body" | grep "let ${var} = ")"
  [ -n "$line" ] || fail "$var is not defined in nft_add_section_priority_rules()"

  printf '%s\n' "$line" | grep -q "sets\.${want}" ||
    fail "$var must reference sets.$want; a UDP matcher bound to the shared ip_ports set captures unrelated TCP traffic (got: $line)"
  ok

  printf '%s\n' "$line" | grep -qE 'sets\.ip6?_?ports\b' &&
    fail "$var still references the shared set: $line"
  ok
done

# --- 3. the TCP matchers must keep the shared sets -------------------------
# The other direction: confining Discord's ranges must not stop ordinary TCP
# section matching from working.
for pair in "match_ip_port4_tcp:ip_ports" "match_ip_port6_tcp:ip6_ports"; do
  var="${pair%%:*}"
  want="${pair##*:}"
  line="$(printf '%s\n' "$body" | grep "let ${var} = ")"
  printf '%s\n' "$line" | grep -q "sets\.${want}" ||
    fail "$var must keep referencing sets.$want: TCP section matching regressed (got: $line)"
  ok
done

# --- 4. the UDP-only sets must actually be created -------------------------
# Declaring a set name is not enough; nft_create_priority_sets has to create it,
# or the rule references a set that does not exist and the whole table fails to
# load.
creator="$(awk '/^function nft_create_priority_sets\(/,/^\}/' "$APPLY_UC")"
printf '%s\n' "$creator" | grep -q 'sets\.udp_ip_ports' ||
  fail "nft_create_priority_sets() never creates udp_ip_ports: the rules would reference a set that does not exist"
ok

printf '%s\n' "$creator" | grep -q 'sets\.udp_ip6_ports' ||
  fail "nft_create_priority_sets() never creates udp_ip6_ports"
ok

# --- 5. Discord's Cloudflare voice ports must land in the UDP set ---------
# The whole point of the split: only Discord's Cloudflare entries move.
disc="$(awk '/^function nft_add_community_subnet_file_to_family_sets\(/,/^\}/' "$APPLY_UC")"
[ -n "$disc" ] || fail "could not locate nft_add_community_subnet_file_to_family_sets()"

printf '%s\n' "$disc" | grep -q 'as_string(service) == "discord"' ||
  fail "the Cloudflare carve-out is no longer scoped to discord"
ok

printf '%s\n' "$disc" | grep -qE 'udp_ports_v4, udp_ports_v6, "ip-port-from-ip"' ||
  fail "discord's Cloudflare voice ports are not written to the UDP-only sets"
ok

echo "discord_cloudflare_udp_only: $pass_count checks passed"