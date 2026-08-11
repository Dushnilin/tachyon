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
# The general active_root_causes registry was replaced by two named deadline
# vars — WAN and sing-box are the only two causes ever claimed; proxy and DNS
# healers only need to know if either is active.
grep -q 'let wan_repair_until' "$WATCHDOG_UC" \
  || fail "wan_repair_until is gone; nothing marks a WAN repair as a root cause"
grep -q 'let singbox_repair_until' "$WATCHDOG_UC" \
  || fail "singbox_repair_until is gone; nothing marks a sing-box restart as a root cause"
grep -q 'function suppressed_by_root_cause(healer)' "$WATCHDOG_UC" \
  || fail "suppressed_by_root_cause() is gone; consequences no longer stand down"

# WAN deadline is set before ifdown, not after: ifdown is itself what makes the
# proxy and DNS probes fail, and those facts arrive while ifup is still running.
claim_line="$(grep -n 'wan_repair_until = time()' "$WATCHDOG_UC" | cut -d: -f1)"
ifdown_line="$(grep -n '/sbin/ifdown wan' "$WATCHDOG_UC" | cut -d: -f1)"
[ -n "$claim_line" ] || fail "heal_wan_and_gateway does not set wan_repair_until before ifdown"
[ -n "$ifdown_line" ] || fail "heal_wan_and_gateway no longer restarts the wan interface"
[ "$claim_line" -lt "$ifdown_line" ] \
  || fail "the WAN deadline is set after ifdown; the resulting proxy/DNS failures would not be suppressed"

grep -q 'singbox_repair_until = time()' "$WATCHDOG_UC" \
  || fail "heal_singbox_stopped does not set singbox_repair_until"

# ── every claim has a release path ────────────────────────────────────────────
# A deadline released only at expiry suppresses real faults for the full window.
# Both causes have a recovery fact that zeroes the deadline immediately.
grep -q 'wan_repair_until = 0;' "$WATCHDOG_UC" \
  || fail "the WAN deadline is never cleared on recovery"
grep -q 'singbox_repair_until = 0;' "$WATCHDOG_UC" \
  || fail "the sing-box deadline is never cleared on recovery"

# WAN_UP is new: probe_wan only ever published failure, so a recovered uplink
# was invisible.
grep -q 'WAN_UP:                 "wan.up",' "$CONTROLLER_UC" \
  || fail "EV.WAN_UP is missing from the event vocabulary"
grep -q 'bus.emit(EV.WAN_UP' "$CONTROLLER_UC" \
  || fail "probe_wan no longer publishes WAN_UP; the deadline could only lapse by expiry"
grep -qE 'subscribe\(EV\.WAN_UP, note_wan_recovered,' "$WATCHDOG_UC" \
  || fail "nothing subscribes to WAN_UP"

# ── the consequences actually check ───────────────────────────────────────────
for healer in heal_dns_stall heal_proxy_connectivity heal_proxy_health heal_dns_continuous; do
  grep -q "suppressed_by_root_cause(\"$healer\")" "$WATCHDOG_UC" \
    || fail "$healer does not stand down for an active root cause; it would repair a consequence"
done

# ── a skip is logged, never silent ────────────────────────────────────────────
# "the watchdog did nothing" and "the watchdog deliberately stood down" look
# identical in a log that omits this.
grep -qE 'standing down, WAN repair|standing down, sing-box restart' "$WATCHDOG_UC" \
  || fail "a suppressed repair is now silent; the log cannot distinguish it from inaction"

# ── the suppression state machine behaves ─────────────────────────────────────
# watchdog.uc is a CLI module with no exports, so the block is lifted out of the
# source verbatim — extracted, not copied, so a change to the logic changes the
# test's subject too.
SUPPRESS_UC="$(mktemp "${TMPDIR:-/tmp}/tachyon_suppress.XXXXXX.uc")"
trap 'rm -f "$SUPPRESS_UC"' EXIT

# log_message, as_string, sprintf are module-level in watchdog.uc, outside the
# block. They go in first so closures capture them correctly.
cat > "$SUPPRESS_UC" <<'PRELUDE'
let logged = [];
function log_message(msg, level) { push(logged, msg); }
function as_string(v) { return "" + v; }
function sprintf(...args) { return join("", args); }
PRELUDE

sed -n '/^const SUPPRESSION_DEADLINE/,/^\/\/ ─── Escalation ladder/p' "$WATCHDOG_UC" >> "$SUPPRESS_UC"
grep -q 'function suppressed_by_root_cause' "$SUPPRESS_UC" \
  || fail "could not extract the suppression block from watchdog.uc"

cat >> "$SUPPRESS_UC" <<'DRIVER'

let out = [];
// Nothing is being repaired: every healer runs.
push(out, "idle_proxy=" + (suppressed_by_root_cause("proxy") ? "skip" : "run"));

// WAN is being repaired. The proxy and DNS healers are downstream of it.
wan_repair_until = time() + SUPPRESSION_DEADLINE;
push(out, "wan_proxy=" + (suppressed_by_root_cause("proxy") ? "skip" : "run"));
push(out, "wan_dns=" + (suppressed_by_root_cause("dns") ? "skip" : "run"));
// WAN does not suppress itself (it IS the root cause).
// Both vars are in scope; singbox_repair_until is still 0, so only WAN fires.
push(out, "logged=" + (length(logged) > 0 ? "yes" : "no"));

// The uplink comes back: suppression lifts immediately, not at the deadline.
wan_repair_until = 0;
push(out, "released_proxy=" + (suppressed_by_root_cause("proxy") ? "skip" : "run"));

// A sing-box restart suppresses proxy/DNS, but not a WAN fault which must still
// be repaired.
singbox_repair_until = time() + SUPPRESSION_DEADLINE;
push(out, "singbox_blocks_proxy=" + (suppressed_by_root_cause("proxy") ? "skip" : "run"));
singbox_repair_until = 0;

// An expired deadline no longer suppresses.
wan_repair_until = time() - 1;
push(out, "expired_proxy=" + (suppressed_by_root_cause("proxy") ? "skip" : "run"));

print(join(" ", out) + "\n");
DRIVER

actual="$(ucode "$SUPPRESS_UC")"
expected="idle_proxy=run wan_proxy=skip wan_dns=skip logged=yes released_proxy=run singbox_blocks_proxy=skip expired_proxy=run"
[ "$actual" = "$expected" ] \
  || fail "root-cause suppression misbehaves
  expected: $expected
  actual:   $actual"

printf 'heal suppression checks passed\n'
