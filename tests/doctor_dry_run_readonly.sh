#!/usr/bin/env bash
# doctor promises in its own header that a plain pass only diagnoses. Two
# branches broke that: the tun0 branch and the Clash API branch counted an
# issue and then immediately restarted the whole stack, so running `tachyon
# doctor` from LuCI -- without --fix -- rebooted the engine and reported the
# result as "FIXED".
#
# The invariant under test is behavioural, not textual: a counted issue must be
# announced as planned before anything acts on it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

DOCTOR="$TACHYON_LIB/diagnostics/doctor.uc"

# 1. Nothing may restart the engine straight off the back of `issues++`.
#    In dry-run that branch must call doc_plan instead.
violations="$(
    awk '
        prev ~ /issues\+\+;/ && $0 ~ /command_status\(init_script/ { print NR ": " $0 }
        { prev = $0 }
    ' "$DOCTOR"
)"
if [ -n "$violations" ]; then
    printf '%s\n' "$violations" >&2
    fail "doctor restarts the engine during a dry run right after counting an issue"
fi
printf 'no unguarded restart after issues++\n' >&2

# 2. Both repairs that used to fire unannounced must now be planned instead, so
#    a user sees what --fix would do before opting in.
planned="$(grep -c 'doc_plan(init_script + " restart")' "$DOCTOR" || true)"
[ "$planned" -ge 2 ] ||
    fail "expected the tun0 and Clash repairs to be planned in dry-run, found $planned"
printf 'planned restarts: %s\n' "$planned" >&2

printf 'doctor dry-run contract checks passed\n'