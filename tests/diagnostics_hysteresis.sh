#!/usr/bin/env bash
# A failed probe is an observation, not a problem.
#
# The AI status used to be derived from a 300s incident clock alone, so it
# reported "healthy" while the proxy was down and had not been repaired yet,
# and swung back to "repaired" every five minutes after any repair no matter
# what the probes said. The probe facts themselves flap even harder: PROXY_DOWN
# fires on a single timed-out curl and PROXY_UP on the next success.
#
# diagnostics/hysteresis.uc turns those observations into a four-state problem
# tracker (clear -> pending -> active -> recovering -> clear) that needs a run
# of consistent samples in both directions, and service/watchdog.uc reports
# that state instead of the clock.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

# --- the tracker itself ---
out="$(ucode -L "$TACHYON_LIB" -e '
let hs = require("diagnostics.hysteresis");
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }

// A fresh check reports nothing.
let tr = hs.create(3, 2);
check(tr.state == "clear", "a fresh tracker is clear");

// One failure is a blip: nobody believes it, and the next success drops it
// without ever having been a problem.
check(hs.observe(tr, false) == "pending", "one failure is pending, not active");
check(hs.observe(tr, true) == "clear", "a blip that clears itself is never reported");

// Only a run of failures confirms the problem.
check(hs.observe(tr, false) == "pending", "the second failure is still pending");
check(hs.observe(tr, false) == "pending", "two failures do not reach a threshold of three");
check(hs.observe(tr, false) == "active", "three consecutive failures activate the problem");

// Recovery is confirmed too: one success does not erase a confirmed problem.
check(hs.observe(tr, true) == "recovering", "the first success starts recovery, it does not clear");
check(hs.observe(tr, true) == "clear", "two consecutive successes confirm the recovery");

// A fault coming back while the tracker is still watching relapses.
let relapse = hs.create(3, 2);
hs.observe(relapse, false);
hs.observe(relapse, false);
hs.observe(relapse, false);
check(hs.observe(relapse, true) == "recovering", "the relapse case starts in recovery");
check(hs.observe(relapse, false) == "active", "a fault during recovery drops straight back to active");

// A check that already counted its misses upstream activates at once.
let wan = hs.create(1, 2);
check(hs.observe(wan, false) == "active", "a threshold of one activates on the first miss");
check(hs.observe(wan, true) == "recovering", "even an immediate threshold holds the recovery");
check(hs.observe(wan, true) == "clear", "the held recovery still clears");

// Thresholds are read from the arguments, with sane floors.
check(hs.create(null, null).fail_threshold == 3, "a missing fail threshold falls back to three");
check(hs.create(0, 0).recover_threshold == 2, "a zero recover threshold falls back to two");

// Picking the worst of several checks.
check(hs.worst(["clear", "pending", "recovering"]) == "recovering", "recovering outranks pending");
check(hs.worst(["clear", "pending", "recovering", "active"]) == "active", "active is the worst state");
check(hs.worst(["clear", "clear"]) == "clear", "a set of clear checks stays clear");
check(hs.worst([]) == "clear", "no checks is clear");
check(hs.worst(null) == "clear", "a missing set is clear");

// Snapshot shape, including a missing tracker.
let snap = hs.snapshot(hs.create(3, 2));
check(snap.state == "clear" && snap.fail_streak == 0 && snap.ok_streak == 0,
      "a snapshot of a fresh tracker reports clear with no streaks");
check(hs.snapshot(null).state == "clear", "a missing tracker reads as clear");

// The status label is what `tachyon ai_status` and the AI doctor report. It
// was a pure incident clock, which is the flap this whole module removes.
check(hs.status_label("clear", false, false) == "healthy", "a clear system is healthy");
check(hs.status_label("active", false, false) == "degraded",
      "a confirmed problem is never reported as healthy");
check(hs.status_label("recovering", false, false) == "degraded",
      "a recovery that has not confirmed is never reported as healthy");
check(hs.status_label("pending", false, false) == "healthy",
      "a pending blip does not flap the label");
check(hs.status_label("clear", true, false) == "repaired", "a recent repair is still reported");
check(hs.status_label("active", true, false) == "degraded",
      "an active problem outranks the repair window");
check(hs.status_label("clear", false, true) == "emergency_failsafe",
      "the emergency failsafe keeps precedence");

print(sprintf("PASS: %d checks\n", checks));
' 2>&1)" || fail "hysteresis checks failed: $out"

echo "$out" | grep -q "^PASS:" || fail "hysteresis checks did not report PASS"
printf 'tracker behaviour verified\n' >&2

# --- the watchdog must actually use it ---
[ -f "$WATCHDOG_UC" ] || fail "service/watchdog.uc not found at $WATCHDOG_UC"

grep -Fq 'require("diagnostics.hysteresis")' "$WATCHDOG_UC" ||
  fail "watchdog does not load the problem tracker"
grep -Fq 'hysteresis.status_label(' "$WATCHDOG_UC" ||
  fail "the AI status label is not derived from the tracker"
grep -Fq 'problem_states: health_problem_states()' "$WATCHDOG_UC" ||
  fail "the status export does not publish the per-check problem states"
grep -Fq 'let health_state = health_problem_state();' "$WATCHDOG_UC" ||
  fail "the overall health state is not taken from the trackers"
grep -Fq 'health_state: health_state' "$WATCHDOG_UC" ||
  fail "the status export does not publish the overall health state"

# Both places that used to compute the label inline must have lost the clock.
if grep -Fq '? "repaired" : "healthy"' "$WATCHDOG_UC"; then
  fail "the AI status is still a pure 300s incident clock"
fi

# Every signal has to feed its own tracker, or the state published above is
# only ever the state of whichever check happened to fire last.
for pair in "PROXY_UP track_proxy_up" "PROXY_DOWN track_proxy_down" \
            "DNS_UP track_dns_up" "DNS_DOWN track_dns_down" \
            "WAN_UP track_wan_up" "WAN_DOWN track_wan_down"; do
  set -- $pair
  grep -Fq "subscribe(EV.$1, $2," "$WATCHDOG_UC" ||
    fail "EV.$1 does not feed the problem tracker through $2"
done

printf 'watchdog problem tracker wiring verified\n' >&2
printf 'diagnostics hysteresis checks passed\n'
