#!/usr/bin/env bash
# The DPI fuzzer installs its own NFQUEUE so a probe can be measured with one
# strategy at a time. Three properties of that installation are what keep the
# router usable while a benchmark runs, and all three were wrong:
#
#   1. The queue used to live in the `output` hook at priority -200. Upstream
#      zapret and blockcheck queue in `postrouting` at priority 101, after
#      routing and NAT. On a real router the same nfqws and the same strategy
#      gave curl exit 35/28 from `output` and HTTP 200 from `postrouting`, so
#      the fuzzer threw away working strategies and reported nothing found.
#
#   2. The queue rule matched every router TCP/443 with no mark guard, and the
#      mark was applied with `meta mark set meta mark | MARK`. Sing-box's own
#      outbound dials carry the same 0x08000000 mark, so they were captured by
#      the test queue, and a zapret section mark like 0x01000001 became
#      0x09000001 and fell out of its production queue. The internet broke for
#      the duration of every benchmark.
#
#   3. googlevideo hosts were pinned with --resolve to the left-hand side of
#      redirector.googlevideo.com/report_mapping. That address is the client's
#      own egress IP, not a Google cache node - the response is
#      "<client ip> => <pop name> (<prefix>)". On an IPv4-egress router every
#      YouTube probe therefore dialled the router itself and timed out.
#
# These are properties of the generated nft rules, so they are asserted against
# the source that emits them.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/diagnostics" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

BINARIES="$TACHYON_LIB/diagnostics/fuzzer/binaries.uc"
TARGETS="$TACHYON_LIB/diagnostics/fuzzer/targets.uc"
PROBE="$TACHYON_LIB/diagnostics/fuzzer/probe.uc"
for f in "$BINARIES" "$TARGETS" "$PROBE"; do
  [ -f "$f" ] || fail "missing $f"
done

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. the queue belongs in postrouting, like upstream zapret --------------
grep -q 'type filter hook postrouting priority 101' "$BINARIES" ||
  fail "the fuzzer queue must sit in the postrouting hook at priority 101, the way zapret and blockcheck place it"
ok

grep -q 'type filter hook output priority -200' "$BINARIES" &&
  fail "the fuzzer queue is back in the output hook at priority -200, which measures a different path than the one zapret uses"
ok

# --- 2. the bypass mark must replace, never OR onto, an existing mark -------
grep -q 'meta mark set meta mark |' "$BINARIES" &&
  fail "the bypass mark is OR-ed onto whatever mark the packet already carries; a zapret section mark 0x01000001 becomes 0x09000001 and leaves its production queue"
ok

grep -q 'meta mark 0 meta l4proto' "$BINARIES" ||
  fail "the bypass chain must only touch unmarked traffic (meta mark 0), or it captures sing-box's own outbound dials"
ok

# --- 3. queue rules must be scoped to the probe targets when they are known -
grep -q 'function target_scope_match' "$BINARIES" ||
  fail "binaries.uc must expose target_scope_match so the queue rules can be limited to the probe targets"
ok

grep -q 'function probe_target_ips' "$BINARIES" ||
  fail "binaries.uc must expose probe_target_ips to collect the addresses the probe will dial"
ok

grep -q 'ip daddr { %s }' "$BINARIES" ||
  fail "the scoped rule must match the probe target addresses (ip daddr)"
ok

# The queue has no bypass flag, so until nfqws binds it every matching packet is
# dropped. A live PID is not proof that the queue is bound.
grep -q 'function wait_nfqueue_bound' "$BINARIES" ||
  fail "binaries.uc must expose wait_nfqueue_bound; the queue rule drops packets until the daemon binds"
ok

grep -q 'wait_nfqueue_bound' "$PROBE" ||
  fail "probe.uc must refuse to score a strategy whose NFQUEUE never bound"
ok

# --- 4. no self-dialling googlevideo ----------------------------------------
# Mentioning it in a comment is fine, and the reason it is gone is worth
# keeping; what must not come back is executable use of it.
for f in "$BINARIES" "$TARGETS"; do
  offenders="$(grep -n 'report_mapping' "$f" | grep -v '^[[:space:]]*[0-9]\+:[[:space:]]*//' || true)"
  [ -z "$offenders" ] ||
    fail "$f uses report_mapping in executable code; the address there is the client's own egress IP, so the probe dials the router itself:
$offenders"
  ok
done

printf 'fuzzer queue isolation: %d checks passed\n' "$pass_count"
printf 'PASS: fuzzer_queue_isolation\n'
