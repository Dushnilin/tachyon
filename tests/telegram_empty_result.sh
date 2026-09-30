#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TELEGRAM="$ROOT_DIR/tachyon/files/usr/lib/service/telegram.uc"

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

# The fix: empty result must not be gated by a single expression that also
# returns false for !res.ok. Verify the two checks are separate statements.
grep -Fq 'result) == 0) return true' "$TELEGRAM" ||
  fail "process_updates must return true on empty result[] (idle poll)"

# Verify the error guard does NOT include the length==0 check.
if grep -Fq 'length(res.result) == 0) return false' "$TELEGRAM"; then
  fail "process_updates must NOT return false when result[] is empty"
fi

printf 'telegram empty result checks passed\n'
