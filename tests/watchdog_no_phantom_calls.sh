#!/usr/bin/env bash
# The watchdog called two functions that do not exist anywhere in the codebase.
# ucode resolves a call target when the callee is defined, so an unknown name
# does not fail loudly: a bare `is_healthy` read yields null (making the AI
# status report "repaired" on a perfectly healthy router), and `log(...)`
# throws "left-hand side is not a function" on every WAN_DOWN event.
#
# Both are read-only regressions: nothing crashes, the router just lies.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WD="$TACHYON_LIB/service/watchdog.uc"

# The logger is log_message(message, level).
if grep -nE '(^|[^_[:alnum:].])log\(' "$WD"; then
    fail "watchdog calls a nonexistent log(); the logger is log_message()"
fi
grep -q 'function log_message(' "$WD" || fail "log_message() is gone - the logger was renamed"
printf 'logger call resolves\n' >&2

# The AI status has to come from state that exists. is_healthy was never defined.
if grep -nE '(^|[^_[:alnum:].])is_healthy' "$WD"; then
    fail "watchdog reads a nonexistent is_healthy; the status must come from last_ai_incident"
fi
grep -q 'last_ai_incident' "$WD" || fail "watchdog lost its AI incident source"
printf 'AI status derives from defined state\n' >&2

printf 'watchdog phantom call checks passed\n'