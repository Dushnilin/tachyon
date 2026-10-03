#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TELEGRAM="$ROOT_DIR/tachyon/files/usr/lib/service/telegram.uc"
RUNTIME="$ROOT_DIR/tachyon/files/usr/lib/service/telegram/runtime.uc"

# process_updates() must treat an empty result array as a success (no new
# updates is a normal API response), not as a failure that increments the
# backoff counter.
#
# Before the fix, the guard was:
#   if (!res || !res.ok || !res.result || length(res.result) == 0) return false;
# This counted "result: []" as a failure, causing a permanent "API failure"
# spam and exponential backoff on every poll.
#
# After the fix, the guard is split:
#   if (!res || !res.ok || !res.result) return false;   // real errors
#   if (length(res.result) == 0) return true;            // idle poll
#
# This test used to grep telegram.uc, which is where the code lived before the
# god-module split in 57c7e2b0. What is left there is a facade that delegates to
# runtime.uc plus a comment quoting the invariant, so the grep matched the comment
# and could never fail. It now reads the file that decides.
[ -f "$RUNTIME" ] || fail "missing $RUNTIME"

# The fix: empty result must not be gated by a single expression that also
# returns false for !res.ok. Verify the two checks are separate statements.
grep -Fq 'result) == 0) return true' "$RUNTIME" ||
  fail "process_updates must return true on empty result[] (idle poll)"

# Verify the error guard does NOT include the length==0 check.
if grep -Fq 'length(res.result) == 0) return false' "$RUNTIME"; then
  fail "process_updates must NOT return false when result[] is empty"
fi

# And the facade must still route to that implementation rather than keep a copy.
grep -Fq 'runtime.process_updates' "$TELEGRAM" ||
  fail "service/telegram.uc must delegate process_updates to the telegram runtime module"

printf 'telegram empty result checks passed\n'