#!/usr/bin/env bash
# FAULT: the safety net itself fails.
#
# known_good is what brings a router back after a bad config, so its own failure
# modes matter more than most: when it cannot roll back, the user is left with a
# broken proxy and no explanation. Everything here drives the real module through
# its test overrides, so no real /etc is touched.
#
# The states covered are the ones a router actually reaches: no snapshot yet, a
# snapshot truncated by a full disk, the active config already equal to the good
# one (the loop guard), a successful rollback, and a rollback that cannot write.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

KG_DIR="$WORK_DIR/known_good"
CFG="$WORK_DIR/tachyon.uci"
OBS="$WORK_DIR/observation.json"
export TACHYON_KNOWN_GOOD_DIR="$KG_DIR"
export TACHYON_OBSERVATION_FILE="$OBS"
export TACHYON_CONFIG_PATH="$CFG"

kg() {
  ucode -L "$LIB_DIR" -e '
let known_good = require("service.known_good");
known_good.set_test_overrides(
    getenv("TACHYON_KNOWN_GOOD_DIR"),
    getenv("TACHYON_OBSERVATION_FILE"),
    getenv("TACHYON_CONFIG_PATH"),
    getenv("SB_VARIANT_STATE_FILE"));
'"$1"'
' 2>&1
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

GOOD='config tachyon "main"
    option enabled "1"
    option log_level "warn"
'
BAD='config tachyon "main"
    option enabled "1"
    option log_level "debug"
    option broken_section "this config never worked"
'

# --- no snapshot yet: must say so, not crash, not claim success ------------
out="$(kg '
let r = known_good.rollback_to_known_good("test", { reload: false });
printf("ok=%s\n", r.ok ? "yes" : "no");
printf("error=%s\n", r.error || "");
')"
[ "$(field "$out" ok)" = "no" ] || fail "a rollback with no known-good state reported success: $out"
grep -qiE '^error=.*(no last known good|known good)' <<< "$out" \
  || fail "a rollback with no known-good state gives no usable reason: $out"
printf '%s' "$BAD" > "$CFG"

# --- an empty active config must not be promotable ------------------------
# A full disk or a power cut mid-write leaves a zero-length config. Promoting
# that would make "known good" mean "empty", and every later rollback would
# restore nothing while reporting success.
: > "$CFG"
out="$(kg '
let r = known_good.promote("test");
printf("ok=%s\n", r.ok ? "yes" : "no");
')"
[ "$(field "$out" ok)" = "no" ] || fail "an empty config was accepted as a known-good snapshot: $out"

# --- a healthy config becomes the snapshot ---------------------------------
printf '%s' "$GOOD" > "$CFG"
out="$(kg '
let r = known_good.promote("baseline");
printf("ok=%s\n", r.ok ? "yes" : "no");
')"
[ "$(field "$out" ok)" = "yes" ] || fail "promoting a healthy config failed: $out"
[ -s "$KG_DIR/config" ] || fail "promote() reported success but wrote no snapshot"

# --- the loop guard: rolling back to what is already active ----------------
out="$(kg '
let r = known_good.rollback_to_known_good("test", { reload: false });
printf("ok=%s\n", r.ok ? "yes" : "no");
printf("error=%s\n", r.error || "");
')"
[ "$(field "$out" ok)" = "no" ] || fail "rollback ran even though the active config already is the known-good one - that is a flapping loop"
grep -qiE '^error=.*identical' <<< "$out" || fail "the loop guard gives no reason: $out"

# --- the real thing: a bad config comes back -------------------------------
printf '%s' "$BAD" > "$CFG"
out="$(kg '
let r = known_good.rollback_to_known_good("sing-box_failed_to_start", { reload: false });
printf("ok=%s\n", r.ok ? "yes" : "no");
printf("reason=%s\n", r.reason || "");
')"
[ "$(field "$out" ok)" = "yes" ] || fail "rollback of a bad config failed: $out"
[ "$(cat "$CFG")" = "$(printf '%s' "$GOOD")" ] || fail "the good config was not restored: $(cat "$CFG")"

# The failing config has to survive, or post-mortem is impossible.
[ -s "$KG_DIR/last_failed_config" ] || fail "the failing config was not preserved for forensics"
grep -q "broken_section" "$KG_DIR/last_failed_config" \
  || fail "the preserved config is not the one that failed"

# And the reason has to be recorded, or the user cannot tell why their config
# came back by itself.
[ -s "$OBS" ] || fail "no observation state was written"
grep -q "sing-box_failed_to_start" "$OBS" \
  || fail "the rollback reason was not recorded anywhere: $(cat "$OBS")"
grep -q "rolled_back" "$OBS" || fail "the observation state does not say it rolled back: $(cat "$OBS")"
grep -q "rollback" "$KG_DIR/history.json" 2>/dev/null \
  || fail "the rollback was not appended to history: $(cat "$KG_DIR/history.json" 2>/dev/null)"

# --- a snapshot truncated by a full disk must not be used ------------------
: > "$KG_DIR/config"
printf '%s' "$BAD" > "$CFG"
out="$(kg '
let r = known_good.rollback_to_known_good("test", { reload: false });
printf("ok=%s\n", r.ok ? "yes" : "no");
printf("error=%s\n", r.error || "");
')"
[ "$(field "$out" ok)" = "no" ] || fail "an empty known-good snapshot was rolled back from - that would restore nothing and report success"
grep -qiE '^error=.*(missing|unreadable|known good)' <<< "$out" \
  || fail "an unusable snapshot gives no usable reason: $out"
[ "$(cat "$CFG")" = "$(printf '%s' "$BAD")" ] || fail "a failed rollback still modified the active config"

# --- a rollback that cannot write must report the failure ------------------
# /overlay full is the realistic case, and it is the step most likely to fail.
# A silent success here would leave the router broken while claiming it was
# fixed, which is worse than not rolling back at all.
#
# Simulated by pointing the active config at a path whose parent is a regular
# file, not a read-only directory: the suite runs as root, and chmod does not
# stop root from writing.
printf '%s' "$GOOD" > "$KG_DIR/config"
printf '%s' "$BAD" > "$CFG"
printf 'not a directory\n' > "$WORK_DIR/blocker"
out="$(TACHYON_CONFIG_PATH="$WORK_DIR/blocker/tachyon.uci" kg '
let r = known_good.rollback_to_known_good("test", { reload: false });
printf("ok=%s\n", r.ok ? "yes" : "no");
printf("error=%s\n", r.error || "");
')"
[ "$(field "$out" ok)" = "no" ] || fail "a rollback that could not write reported success: $out"
grep -qiE '^error=.*(fail|restore)' <<< "$out" \
  || fail "a failed restore gives no usable reason: $out"

# The config that is actually in place must be left alone when the restore
# failed - a partial write would destroy the very thing we were trying to save.
[ "$(cat "$CFG")" = "$(printf '%s' "$BAD")" ] \
  || fail "a failed rollback still modified the active config"

# --- the variant marker is restored too, to where it belongs ---------------
# This one was hardcoded to /etc/tachyon/sing-box-variant while every other path
# in the module was overridable, so a rollback wrote outside the directory it
# was told to use - and the module could not be exercised without touching the
# real /etc.
printf 'lx\n' > "$KG_DIR/variant"
printf '%s' "$GOOD" > "$KG_DIR/config"
printf '%s' "$BAD" > "$CFG"
out="$(SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant" kg '
let r = known_good.rollback_to_known_good("variant_test", { reload: false });
printf("ok=%s\n", r.ok ? "yes" : "no");
')"
[ "$(field "$out" ok)" = "yes" ] || fail "rollback failed while restoring the variant marker: $out"
[ -f "$WORK_DIR/sing-box-variant" ] || fail "the variant marker was not restored to the configured path"
grep -q '^lx$' "$WORK_DIR/sing-box-variant" || fail "the wrong variant marker was restored: $(cat "$WORK_DIR/sing-box-variant")"
[ -e /etc/tachyon/sing-box-variant ] \
  && fail "rollback wrote the variant marker to the hardcoded /etc path instead of the configured one"

printf 'fault: known good rollback checks passed\n'