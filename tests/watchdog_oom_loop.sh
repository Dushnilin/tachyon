#!/usr/bin/env bash
# An OOM healer that restarts services forever is worse than no healer.
#
# heal_oom() shrank the GOMEMLIMIT scale by 20% per event, floored at 0.2, and
# restarted every service each time - including once the floor was reached, where
# the value it wrote could not change. Restarting under memory pressure is what
# produced the next OOM, so a router could stay in that loop indefinitely. The log
# screenshots showed seven notifications in sixteen minutes, one per 20% step, and
# the last ones after there was nothing left to lower.
#
# It also ran `logread -c`, wiping the whole syslog buffer. The replay of the
# historical buffer on start is already filtered by the controller's
# syslog_start_time guard, so the clear gained nothing and destroyed the only record
# of what ran the router out of memory.
#
# The decisions are exercised as pure functions here, and the healer body is checked
# for the restart and the log wipe.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/service" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
[ -f "$WATCHDOG_UC" ] || fail "missing $WATCHDOG_UC"

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# The floor rule and the shrink, driven through the real module rather than a copy of
# it: a fixture that re-implements the arithmetic passes against the old code and
# breaks against the new one, which is the whole trap here.
cat >"$WORK_DIR/oom.uc" <<'UCODE'
let oom = require("service.oom_scale");

let errors = [];
let note = function(m) { push(errors, m); };

// Shrinking walks down in 20% steps and must stop above the floor, because past it
// sing-box is starved into not working at all. The walk ends on the last value that
// already counts as "at the floor" - one more step would clamp, and the healer must
// not take it.
let scale = 1.0;
let steps = 0;
while (!oom.oom_scale_at_floor(scale) && steps < 50) {
    let next = oom.next_oom_scale(scale);
    if (next >= scale) { note("the scale stopped shrinking at " + scale); break; }
    if (next < oom.OOM_SCALE_FLOOR) { note("the scale fell below the floor"); break; }
    scale = next;
    steps++;
}
if (steps > 20) note("the scale took " + steps + " steps to reach the floor");
if (!oom.oom_scale_at_floor(scale)) note("the scale never reached the floor");

// A fresh install must not look like it is at the floor, or the healer would never
// act at all.
if (oom.oom_scale_at_floor(1.0)) note("a fresh install must not be treated as at the floor");
if (oom.oom_scale_at_floor(0.5)) note("scale 0.50 must still be reducible");
if (oom.oom_scale_at_floor(0.25)) note("scale 0.25 must still be reducible");
if (!oom.oom_scale_at_floor(0.21)) note("scale 0.21 must count as at the floor");
if (oom.next_oom_scale(0.21) < oom.OOM_SCALE_FLOOR) note("next_oom_scale must clamp to the floor, not below it");

// Float equality is not the assertion here; the size of the step is.
let shrunk = oom.next_oom_scale(0.8);
if (shrunk > 0.65 || shrunk < 0.63) note("a 20% shrink from 0.80 gave " + shrunk);

// Reading a missing or nonsensical file must not read as "already at the floor".
if (oom.read_oom_scale() < 0.9) note("an absent scale file must read as 1.0");

if (length(errors) > 0) {
    for (let e in errors) printf("%s\n", e);
    exit(1);
}
printf("oom floor ok after %d steps at %.2f\n", steps, scale);
UCODE
if out="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/oom.uc" 2>&1)"; then
  printf 'oom floor arithmetic: %s\n' "$out"
  ok
else
  fail "OOM floor arithmetic is wrong:
$out"
fi

# The healer body must not restart unconditionally, and must not wipe the log.
# Comment lines are stripped first: the comment explaining why logread -c is gone
# names it, and a grep that matched the explanation could never pass.
body="$(sed -n '/^function heal_oom/,/^}/p' "$WATCHDOG_UC" | grep -v '^[[:space:]]*//')"
[ -n "$body" ] || fail "heal_oom not found"

if ! grep -q 'oom_scale_at_floor' <<<"$body"; then
  fail "heal_oom must check the floor before restarting anything; a restart that cannot change a value is what made the loop"
fi
ok

if grep -q 'logread -c' <<<"$body"; then
  fail "heal_oom still wipes the syslog buffer; the replay guard already covers the replay, and the clear destroyed the only record of the OOM"
fi
ok

# The restart must sit after the floor guard, not before it.
guard_line="$(grep -n 'oom_scale_at_floor' <<<"$body" | head -1 | cut -d: -f1)"
restart_line="$(grep -n 'tachyon restart' <<<"$body" | head -1 | cut -d: -f1)"
if [ -n "$guard_line" ] && [ -n "$restart_line" ] && [ "$guard_line" -lt "$restart_line" ]; then
  ok
else
  fail "the restart must come after the floor guard (guard line ${guard_line:-none}, restart line ${restart_line:-none})"
fi

printf 'watchdog oom loop: %d checks passed\n' "$pass_count"
printf 'PASS: watchdog_oom_loop\n'