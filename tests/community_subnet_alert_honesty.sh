#!/usr/bin/env bash
# BUG (TCH-1041): the router told the user the community subnet sets had been
# restored, every 900s, on a router where nothing was actually wrong.
#
# Two independent reasons, both producing the same false "fixed":
#
#   1. execute_reconciler_subsystem("nftables") inspects only the core sets
#      (localv4 and friends). The per-section tachyon_rule_*_subnets sets this
#      event is about are not in its scope at all, so it found no drift,
#      returned ok, and the first branch reported "fixed".
#   2. The second branch reported "fixed" before running reload_firewall, i.e.
#      before doing anything that could have had an effect.
#
# Either way the report described an intention, not an outcome. The Telegram
# cooldown (900s) then turned that into a message every 15 minutes.
#
# The invariant: the reported outcome must describe what the sets look like after
# the repair attempt. Unchanged sets must not be announced as restored, and a
# repair that did not work must not be announced as a success.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
EVENTS_UC="$TACHYON_LIB/components/updates.uc"
[ -f "$WATCHDOG_UC" ] || fail "service/watchdog.uc not found at $WATCHDOG_UC"
[ -f "$EVENTS_UC" ] || fail "components/updates.uc not found at $EVENTS_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. the repair must re-read the sets instead of assuming ---------------
grep -q 'function community_subnet_sets_still_empty' "$WATCHDOG_UC" ||
  fail "watchdog.uc has no community_subnet_sets_still_empty(): the report cannot be based on the state after the repair"
ok

grep -q 'community_subnet_sets_still_empty(reported)' "$WATCHDOG_UC" ||
  fail "heal_community_subnet_sets never consults community_subnet_sets_still_empty(); it reports the outcome it assumed"
ok

# --- 2. only a verified repair may claim "fixed" ---------------------------
# Scoped to this handler: "fixed" is the normal outcome for every other healer,
# so a repo-wide grep would flag unrelated and correct code.
body="$(awk '/^function heal_community_subnet_sets\(ev\) \{/,/^\}/' "$WATCHDOG_UC")"
[ -n "$body" ] || fail "could not locate heal_community_subnet_sets() in watchdog.uc"

printf '%s\n' "$body" | grep -q '"fixed"' ||
  fail "heal_community_subnet_sets no longer reports 'fixed' for this event at all"
ok

# That "fixed" must sit below the branch that measured the sets.
fixed_after_guard="$(printf '%s\n' "$body" | awk '
  /if \(length\(still_empty\) == 0\)/ { guard = NR }
  /"fixed"/ { if (guard > 0 && NR > guard) found = 1 }
  END { print found + 0 }')"
[ "$fixed_after_guard" = "1" ] ||
  fail "the 'fixed' report is not inside the branch that verified the sets were repopulated; the outcome is asserted rather than measured"
ok

# --- 3. an unsuccessful repair must not claim success ----------------------
printf '%s\n' "$body" | grep -q '"skipped"' ||
  fail "this event has no 'skipped' outcome: a repair that did not work is still reported as 'fixed'"
ok

printf '%s\n' "$body" | grep -q 'Не удалось заполнить' ||
  fail "the failure path must say what did not work; a generic 'fixed' hides the real cause"
ok

# --- 4. the built-in .lst files must have a reachable source ---------------
# The other half of the noise: the .srs rulesets go through download_candidates
# and arrive over a mirror when the origin is blocked, but the built-in community
# subnet .lst files went straight to download_to_file. Same list, two
# reachability stories: domains worked, subnets did not, and the empty set then
# alerted forever.
#
# Scoped to the two built-in importers. import_domains_from_remote_plain_file
# and import_subnets_from_remote_plain_file handle URLs the user typed in, which
# is a different question and deliberately not asserted on here.
for fn in import_all_preset_lists import_builtin_subnets_from_rule; do
  # index() rather than a regex: the '(' in a function header is not a valid
  # regex on its own, and awk fails to compile the whole program.
  fnbody="$(awk -v f="function $fn(" '
    index($0, f) == 1 { inside = 1 }
    inside && /^\}/ { inside = 0; exit }
    inside { print }
  ' "$EVENTS_UC")"
  [ -n "$fnbody" ] || fail "could not locate $fn() in components/updates.uc"

  printf '%s\n' "$fnbody" | grep -q 'download_candidates' ||
    fail "$fn() still downloads the built-in .lst from the origin only; on a router where that host is blocked the community subnet set stays empty forever (TCH-1041)"
  ok

  # Belt and braces: the download must name a candidate, never the bare url.
  # Asserted as absence, so the polarity has to be && fail, not || fail.
  printf '%s\n' "$fnbody" | grep -q 'download_to_file(url,' &&
    fail "$fn() still calls download_to_file with the bare origin url; the mirror candidates are bypassed"
  ok
done

echo "community_subnet_alert_honesty: $pass_count checks passed"