#!/usr/bin/env bash
# A UDP strategy used to win the fuzzer without ever being exercised.
#
# The probe is curl over HTTPS, so it only puts TCP on the wire. The queue rule
# matched "l4proto { tcp, udp }", nfqws received the TCP packets, its
# --filter-udp did not apply to them, so it accepted them untouched, the probe
# succeeded and the strategy collected a full score. The winner is what the user
# ends up applying, so a Discord voice strategy could be declared the winner for a
# path that was never tested - and the queue total in /proc/net/netfilter could
# not tell the difference, because it counts both protocols together.
#
# The fix splits the queue rule per protocol and lets the verdict depend on
# whether the packets the strategy filters actually arrived. These checks drive the
# real functions; the fixture is verbatim `nft list table` output captured on a
# router after real TCP and UDP traffic went through both rules.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/diagnostics" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

BINARIES="$TACHYON_LIB/diagnostics/fuzzer/binaries.uc"
PROBE="$TACHYON_LIB/diagnostics/fuzzer/probe.uc"
FUZZER="$TACHYON_LIB/diagnostics/fuzzer.uc"
for f in "$BINARIES" "$PROBE" "$FUZZER"; do
  [ -f "$f" ] || fail "missing $f"
done

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

strip_ucode_comments() { grep -v '^[[:space:]]*//' "$1"; }

# Real output from an nft table with a TCP rule and a UDP rule, counters
# populated, plus the mark-return rule that carries a counter but no comment.
cat >"$WORK_DIR/nft_both.txt" <<'NFT'
table inet fz_test {
	chain postnat {
		type filter hook postrouting priority srcnat + 1; policy accept;
		meta mark & 0x08000000 == 0x08000000 counter packets 54 bytes 7096 return
		tcp dport { 80, 443 } counter packets 3 bytes 180 queue to 250 comment "tcp-proto"
		udp dport { 443, 50000-65535 } counter packets 1 bytes 122 queue to 250 comment "udp-proto"
	}
}
NFT

# The shape a UDP-strategy run produces: curl sent no UDP, so the udp counter
# stays at zero while tcp climbs. This is the case that used to look like a win.
cat >"$WORK_DIR/nft_tcp_only.txt" <<'NFT'
table inet fz_test {
	chain postnat {
		tcp dport { 80, 443 } counter packets 9 bytes 540 queue to 250 comment "tcp-proto"
	}
}
NFT

cat >"$WORK_DIR/udp_contract.uc" <<'UCODE'
let fs = require("fs");
let b = require("diagnostics.fuzzer.binaries");
let p = require("diagnostics.fuzzer.probe");

let both = b.parse_proto_counters(fs.readfile(ARGV[0]));
if (both.tcp != 3) exit(10);
if (both.udp != 1) exit(11);

let tcp_only = b.parse_proto_counters(fs.readfile(ARGV[1]));
if (tcp_only.tcp != 9) exit(12);
if (tcp_only.udp != 0) exit(13);

// An unreadable table must not invent traffic.
let none = b.parse_proto_counters("");
if (none.tcp != 0 || none.udp != 0) exit(14);
let garbage = b.parse_proto_counters("nft: command not found\n");
if (garbage.tcp != 0 || garbage.udp != 0) exit(15);

// The verdict itself.
if (p.udp_probe_verdict(true, both, 2) != null) exit(16);
if (p.udp_probe_verdict(false, { tcp: 0, udp: 0 }, 2) != null) exit(17);
// Nothing ran, so a missing UDP counter proves nothing (QUIC target without HTTP/3).
if (p.udp_probe_verdict(true, { tcp: 0, udp: 0 }, 0) != null) exit(18);

let msg = p.udp_probe_verdict(true, tcp_only, 2);
if (msg == null) exit(19);
if (index(msg, "9 TCP packets") < 0) exit(20);
UCODE

if out="$(ucode "$WORK_DIR/udp_contract.uc" "$WORK_DIR/nft_both.txt" "$WORK_DIR/nft_tcp_only.txt" 2>&1)"; then
  ok
else
  fail "udp probe honesty contract: $out"
fi

# The counters are only meaningful if the rules that feed them exist and are split
# per protocol. One combined "l4proto { tcp, udp }" rule is the bug itself: it
# cannot attribute a packet to a protocol.
#
# Asked of the generator function rather than of the source text: the rule is built
# with a %s for the protocol name, so a grep for the literal string is checking
# formatting, not behaviour.
cat >"$WORK_DIR/spec.uc" <<'UCODE'
let b = require("diagnostics.fuzzer.binaries");
let protocol = ARGV[0];
let ports = protocol == "udp" ? b.FUZZER_QUEUE_PORTS_UDP : b.FUZZER_QUEUE_PORTS_TCP;
print(b.fuzzer_queue_rule_spec("ip daddr { 203.0.113.7 } ", protocol, 200, ports));
UCODE

for protocol in tcp udp; do
  rule="$(ucode "$WORK_DIR/spec.uc" "$protocol")"
  case "$rule" in
    *"comment \"$protocol-proto\""*) ok ;;
    *) fail "the $protocol queue rule must carry its own counter comment, got: $rule" ;;
  esac
  case "$rule" in
    *"meta l4proto $protocol $protocol"*) ok ;;
    *) fail "the $protocol queue rule must match only its own protocol, got: $rule" ;;
  esac
done

strip_ucode_comments "$BINARIES" >"$WORK_DIR/binaries_nc.uc"

if grep -q 'l4proto { tcp, udp }' "$WORK_DIR/binaries_nc.uc"; then
  fail "the queue rule is combined again; a single rule cannot say which protocol a packet belonged to"
fi
ok

# run_probe must read the counters and refuse to score on them.
grep -q 'read_fuzzer_proto_counters' "$PROBE" ||
  fail "probe.uc must read the per-protocol queue counters"
ok

grep -q 'udp_probe_verdict' "$PROBE" ||
  fail "probe.uc must gate UDP strategies on whether their filter ran"
ok

# The winner is what gets applied, so an unmeasured strategy must not be eligible.
grep -q 'r.success && r.score > highest_vscore' "$FUZZER" ||
  fail "fuzzer.uc must keep requiring success before naming a best match"
ok

printf 'fuzzer udp probe honesty: checks passed\n'
printf 'PASS: fuzzer_udp_probe_honesty\n'