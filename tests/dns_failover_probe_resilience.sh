#!/usr/bin/env bash
# DNS health probe must survive a slow path and must say why it failed (issue #84).
#
# The reporter sees "all configured bootstrap/main DNS servers are unavailable"
# 21 and 40 minutes after a sing-box restart, with the two warnings 8 seconds
# apart in both cases, while WAN stays up and a manual nslookup works right
# after. Two servers from different providers cannot fail in sync, so those two
# warnings are consecutive probe cycles hitting one common stall rather than two
# independent outages.
#
# The probe is a single `dig` with +tries=1 and a 2s timeout against sing-box's
# own health inbound. For a DoH server that inbound resolves through the proxy
# transport, so "resolver is down" is measured as "the transport answered within
# two seconds". A degraded proxy path therefore reads as a dead resolver.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILOVER_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/dns_failover.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$FAILOVER_UC" ] || fail "dns_failover.uc not found"

# --- the probe must not be a single 2s attempt ------------------------------
# A one-shot 2s probe is the mechanism that turns a slow path into a dead
# resolver. Both the budget and the attempt count have to give a slow-but-alive
# DoH path room to answer.
default_timeout="$(grep -oE 'duration_seconds\(settings_value, [0-9]+\)' "$FAILOVER_UC" | head -1 | grep -oE '[0-9]+' | tail -1)"
[ -n "$default_timeout" ] || fail "could not read the default probe timeout"
if [ "$default_timeout" -lt 5 ]; then
  fail "default probe timeout is ${default_timeout}s, too tight for a DoH path through the proxy (want >= 5)"
fi

tries="$(grep -oE '\+tries=[0-9]+' "$FAILOVER_UC" | head -1 | grep -oE '[0-9]+')"
[ -n "$tries" ] || fail "could not read the probe attempt count"
if [ "$tries" -lt 2 ]; then
  fail "probe uses +tries=${tries}, so one lost packet is a failed server (want >= 2)"
fi

# Both probes have to get it, not just one.
dig_lines="$(grep -c 'dig -p ' "$FAILOVER_UC" || true)"
tries_lines="$(grep -c '+tries=' "$FAILOVER_UC" || true)"
[ "$dig_lines" = "$tries_lines" ] ||
  fail "not every dig invocation sets an attempt count (${dig_lines} probes, ${tries_lines} with +tries)"

# --- a failure must be explained --------------------------------------------
# Right now the raw dig output is discarded, so a report like #84 has no detail
# to act on: no return code, no latency, no answer.
grep -q 'PROBE_DETAIL' "$FAILOVER_UC" ||
  fail "probe results are still discarded; a failure carries no detail"
grep -q 'log_message("all configured bootstrap DNS servers are unavailable' "$FAILOVER_UC" ||
  fail "the bootstrap warning disappeared"
grep -q 'log_message("all configured main DNS servers are unavailable' "$FAILOVER_UC" ||
  fail "the main warning disappeared"

# Both warnings must carry the explanation, not just the headline.
warn_context="$(grep -A6 'all configured bootstrap DNS servers are unavailable' "$FAILOVER_UC")"
echo "$warn_context" | grep -q 'PROBE_DETAIL' ||
  fail "the bootstrap warning does not include what the probe actually returned"
warn_context="$(grep -A6 'all configured main DNS servers are unavailable' "$FAILOVER_UC")"
echo "$warn_context" | grep -q 'PROBE_DETAIL' ||
  fail "the main warning does not include what the probe actually returned"

printf 'dns failover probe resilience: checks passed\n'
