#!/usr/bin/env bash
# A zapret section must reach its NFQUEUE without going through sing-box, and the
# desync fakes nfqws2 fabricates from that hook must leave with the WAN address.
#
# Both halves are needed and neither is enough alone. Marking in prerouting only
# makes the fakes grey: they are re-injected from mangle_forward, which runs
# before masquerade, and the ISP drops them. Masquerading only does nothing
# useful: without the section mark, priority_rules hands every section to sing-box
# on fakeip_mark and the packet re-originates inside the proxy, which WebRTC
# treats as an address change. Discord voice lost its ICE candidates that way and
# reported "no route" with the desync queue sitting at zero packets.
#
# 3e716b1d traded the second for the first. This pins both back.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

APPLY="$ROOT_DIR/tachyon/files/usr/lib/nft/apply.uc"

[ -r "$APPLY" ] || fail "nft/apply.uc is missing"

# 1. A zapret2 section gets its own mark, distinct from the one every other
#    section shares, and it is the same mark the queue rules test for.
grep -Fq '0x02000000 + zapret2_idx' "$APPLY" ||
  fail "a zapret2 section must be marked with its own queue index, not the shared fakeip mark"
grep -Fq '0x01000000 + zapret_idx' "$APPLY" ||
  fail "a zapret section must be marked with its own queue index, not the shared fakeip mark"

# 2. The mark is passed per section, which is what makes it reach the queue at all.
grep -Fq 'localv6_set, sec_mark))' "$APPLY" ||
  fail "the per-section mark must be passed to the priority rules; passing the shared mark routes zapret through sing-box"

# 3. Both counters must start at 1: the queue rules built elsewhere number the
#    sections from 1, and an off-by-one sends a section's traffic to a queue
#    belonging to a different one.
grep -Eq 'let zapret2_idx = 1;' "$APPLY" ||
  fail "the zapret2 queue index must start at 1 to match the queue numbering"
grep -Eq 'let zapret_idx = 1;' "$APPLY" ||
  fail "the zapret queue index must start at 1 to match the queue numbering"

# 4. The grey-address hole has to stay closed, and the rule has to be a nat
#    postrouting rule rather than something that would also rewrite host traffic.
grep -Fq 'function nft_create_zapret_pre_nat_snat(' "$APPLY" ||
  fail "the pre-NAT masquerade that keeps desync fakes off the LAN address is missing"
grep -Fq 'type nat hook postrouting priority 110' "$APPLY" ||
  fail "the masquerade must run in a nat postrouting chain, otherwise it does not change the source address"

# 5. Both provider mark ranges are covered, and nothing else is.
grep -Fq '"0x03ffffff", "==", "0x01000000"' "$APPLY" ||
  fail "the masquerade must cover the zapret mark range"
grep -Fq '"0x03ffffff", "==", "0x02000000"' "$APPLY" ||
  fail "the masquerade must cover the zapret2 mark range"

# 6. Guarded by interface so host-originated traffic, which never traverses
#    forward, is not masqueraded a second time.
grep -Fq 'guarded = as_string(interface_set) != ""' "$APPLY" ||
  fail "the masquerade must be guarded by the Tachyon interface set"

# 7. The rule is installed alongside the forward chain, not merely defined: a
#    function nothing calls would leave the hole open while every check above
#    passed.
grep -Fq 'if (!nft_create_zapret_pre_nat_snat(table, interface_set))' "$APPLY" ||
  fail "the pre-NAT masquerade is defined but never installed"

printf 'PASS: zapret sections reach their queue directly and their fakes leave with the WAN address\n'