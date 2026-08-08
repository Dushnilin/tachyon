#!/usr/bin/env bash
set -eo pipefail

# Pins consequence suppression: while a root cause is being repaired, the
# healers for its downstream effects stand down.
#
# A dead WAN takes the proxy, DNS and the health check with it. Each has its own
# subscriber, and each used to conclude independently that a restart was in
# order — three repairs for one fault, none of which could work until the uplink
# came back. safe_proxy_restart()'s rate limit throttled the pile-up after the
# fact; nothing expressed that they were consequences.
#
# The failure mode this guards against is quiet: without suppression the router
# still heals, it just thrashes while doing it. Only a log read would show it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# ── causality is expressed once ───────────────────────────────────────────────
# The bus already ranked healers by cause. Those ranks are named so the
# subscription priority and the suppression check cannot drift apart — a drift
# would either suppress nothing or let a cause suppress itself.
for c in 'PRIORITY_WAN     = 10' 'PRIORITY_SINGBOX = 20' \
         'PRIORITY_PROXY   = 40' 'PRIORITY_DNS     = 50'; do
  grep -q "const $c;" "$WATCHDOG_UC" || fail "the causal rank '$c' is gone"
done

# The registrations must use the constants, not literals, or naming them buys
# nothing.
for reg in 'heal_wan_and_gateway", priority: PRIORITY_WAN' \
           'heal_singbox_stopped", priority: PRIORITY_SINGBOX' \
           'heal_proxy_connectivity", priority: PRIORITY_PROXY' \
           'heal_dns_stall", priority: PRIORITY_DNS'; do
  grep -q "$reg" "$WATCHDOG_UC" \
    || fail "a subscription re-hardcodes its priority instead of using the named rank: $reg"
done

# ── the root cause is claimed and released ────────────────────────────────────
grep -q 'function claim_root_cause(priority)' "$WATCHDOG_UC" \
  || fail "claim_root_cause() is gone; nothing marks a repair as a root cause"
grep -q 'function release_root_cause(priority)' "$WATCHDOG_UC" \
  || fail "release_root_cause() is gone; a claim could never be cleared early"
grep -q 'function suppressed_by_root_cause(healer, priority)' "$WATCHDOG_UC" \
  || fail "suppressed_by_root_cause() is gone; consequences no longer stand down"

# WAN claims before ifdown, not after: ifdown is itself what makes the proxy and
# DNS probes fail, and those facts arrive while ifup is still running.
claim_line="$(grep -n 'claim_root_cause(PRIORITY_WAN);' "$WATCHDOG_UC" | cut -d: -f1)"
ifdown_line="$(grep -n '/sbin/ifdown wan' "$WATCHDOG_UC" | cut -d: -f1)"
[ -n "$claim_line" ] || fail "heal_wan_and_gateway does not claim the WAN root cause"
[ -n "$ifdown_line" ] || fail "heal_wan_and_gateway no longer restarts the wan interface"
[ "$claim_line" -lt "$ifdown_line" ] \
  || fail "the WAN claim is taken after ifdown; the resulting proxy/DNS failures would not be suppressed"

grep -q 'claim_root_cause(PRIORITY_SINGBOX);' "$WATCHDOG_UC" \
  || fail "heal_singbox_stopped does not claim its restart as a root cause"

# ── every claim has a release path ────────────────────────────────────────────
# A claim released only by its deadline suppresses real faults for the full
# window. Both causes have a recovery fact, so both release on it.
grep -q 'release_root_cause(PRIORITY_WAN);' "$WATCHDOG_UC" \
  || fail "the WAN claim is never released on recovery"
grep -q 'release_root_cause(PRIORITY_SINGBOX);' "$WATCHDOG_UC" \
  || fail "the sing-box claim is never released on recovery"

# WAN_UP is new: probe_wan only ever published failure, so a recovered uplink
# was invisible.
grep -q 'WAN_UP:                 "wan.up",' "$CONTROLLER_UC" \
  || fail "EV.WAN_UP is missing from the event vocabulary"
grep -q 'bus.emit(EV.WAN_UP' "$CONTROLLER_UC" \
  || fail "probe_wan no longer publishes WAN_UP; the claim could only lapse by deadline"
grep -qE 'subscribe\(EV\.WAN_UP, note_wan_recovered,' "$WATCHDOG_UC" \
  || fail "nothing subscribes to WAN_UP"

# ── the consequences actually check ───────────────────────────────────────────
for healer in heal_dns_stall heal_proxy_connectivity heal_proxy_health heal_dns_continuous; do
  grep -q "suppressed_by_root_cause(\"$healer\"" "$WATCHDOG_UC" \
    || fail "$healer does not stand down for an active root cause; it would repair a consequence"
done

# ── a skip is logged, never silent ────────────────────────────────────────────
# "the watchdog did nothing" and "the watchdog deliberately stood down" look
# identical in a log that omits this.
grep -q 'standing down, a higher-priority repair' "$WATCHDOG_UC" \
  || fail "a suppressed repair is now silent; the log cannot distinguish it from inaction"

# ── the suppression state machine behaves ─────────────────────────────────────
# watchdog.uc is a CLI module with no exports, so the block is lifted out of the
# source verbatim — extracted, not copied, so a change to the logic changes the
# test's subject too.
SUPPRESS_UC="$(mktemp "${TMPDIR:-/tmp}/tachyon_suppress.XXXXXX.uc")"
trap 'rm -f "$SUPPRESS_UC"' EXIT

# log_message and as_string are module-level in watchdog.uc, outside the block.
# They go in first: ucode captures a closure's upvalues when the closure is
# created, so a helper declared below the extracted code would not be captured at
# all — it would resolve as a global and come back null.
cat > "$SUPPRESS_UC" <<'PRELUDE'
let logged = [];
function log_message(msg, level) { push(logged, msg); }
function as_string(v) { return "" + v; }
PRELUDE

sed -n '/^const SUPPRESSION_DEADLINE/,/^\/\/ ─── Escalation ladder/p' "$WATCHDOG_UC" >> "$SUPPRESS_UC"
grep -q 'function suppressed_by_root_cause' "$SUPPRESS_UC" \
  || fail "could not extract the suppression block from watchdog.uc"

cat >> "$SUPPRESS_UC" <<'DRIVER'

let out = [];
// Nothing is being repaired: every healer runs.
push(out, "idle_proxy=" + (suppressed_by_root_cause("proxy", PRIORITY_PROXY) ? "skip" : "run"));

// WAN is being repaired. The proxy and DNS healers are downstream of it.
claim_root_cause(PRIORITY_WAN);
push(out, "wan_proxy=" + (suppressed_by_root_cause("proxy", PRIORITY_PROXY) ? "skip" : "run"));
push(out, "wan_dns=" + (suppressed_by_root_cause("dns", PRIORITY_DNS) ? "skip" : "run"));
// A cause never suppresses itself, or WAN could not repair its own fault.
push(out, "wan_self=" + (suppressed_by_root_cause("wan", PRIORITY_WAN) ? "skip" : "run"));
// Nor does a consequence suppress its cause: sing-box outranks the proxy, not
// the other way round.
push(out, "logged=" + (length(logged) > 0 ? "yes" : "no"));

// The uplink comes back: suppression lifts immediately, not at the deadline.
release_root_cause(PRIORITY_WAN);
push(out, "released_proxy=" + (suppressed_by_root_cause("proxy", PRIORITY_PROXY) ? "skip" : "run"));

// A lower-ranked repair does not suppress a higher-ranked one: while the proxy
// is being fixed, a WAN fault must still be repairable.
claim_root_cause(PRIORITY_PROXY);
push(out, "proxy_blocks_wan=" + (suppressed_by_root_cause("wan", PRIORITY_WAN) ? "skip" : "run"));
push(out, "proxy_blocks_dns=" + (suppressed_by_root_cause("dns", PRIORITY_DNS) ? "skip" : "run"));
release_root_cause(PRIORITY_PROXY);

// A root cause that never recovers must not suppress forever. The claim is
// backdated past SUPPRESSION_DEADLINE to stand in for a repair that hung.
claim_root_cause(PRIORITY_WAN);
active_root_causes["10"] = time() - 1;
push(out, "expired_proxy=" + (suppressed_by_root_cause("proxy", PRIORITY_PROXY) ? "skip" : "run"));

print(join(" ", out) + "\n");
DRIVER

actual="$(ucode "$SUPPRESS_UC")"
expected="idle_proxy=run wan_proxy=skip wan_dns=skip wan_self=run logged=yes released_proxy=run proxy_blocks_wan=run proxy_blocks_dns=skip expired_proxy=run"
[ "$actual" = "$expected" ] \
  || fail "root-cause suppression misbehaves
  expected: $expected
  actual:   $actual"

printf 'heal suppression checks passed\n'
