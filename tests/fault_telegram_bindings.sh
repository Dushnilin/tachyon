#!/usr/bin/env bash
# Guards the defect class that the split of service/telegram.uc in 57c7e2b0
# introduced: names that are called bare in one submodule but live in a sibling.
#
# Two separate failures shipped from that refactor and both were silent:
#   - BLOCKED_POLL_INTERVAL stayed in the monolith and was never carried over,
#     so the reference in the worker loop resolved to nothing and ucode raised
#     "left-hand side is not a function" after every successful poll.
#   - ten calls reached across into rendering/commands/callbacks without a
#     binding, so they threw the moment they were executed.
# Neither is a syntax error: `ucode -c` accepts all of it.

set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

RUNTIME="$TACHYON_LIB/service/telegram/runtime.uc"
CALLBACKS="$TACHYON_LIB/service/telegram/callbacks.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The explanations next to these lines name the very tokens being asserted, so
# assertions run against the code with comments stripped - otherwise this test
# would pass on its own comments.
runtime_code="$(sed -e 's/#.*$//' "$RUNTIME")"
callbacks_code="$(sed -e 's/#.*$//' "$CALLBACKS")"

for f in "$RUNTIME" "$CALLBACKS"; do
  ucode -S -c -o /dev/null "$f" || fail "$f must pass strict ucode syntax check"
done

assert_in() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected to find '$needle'" ;;
  esac
}

assert_not_in() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) fail "$label: must not contain '$needle'" ;;
  esac
}

# 1. The constant the worker loop reads on every pass.
assert_in "$runtime_code" "const BLOCKED_POLL_INTERVAL" "worker loop must define the blocked-activity interval"

# 2. Every cross-module call needs a binding in the file that makes it. A
#    missing one is not a compile error, only a throw at the call site.
for name in build_identity_key build_transition safe_execute; do
  assert_in "$runtime_code" "let $name = rendering.$name;" "runtime.uc must bind $name from rendering"
done
for name in view_set_cat view_sec_list view_test_rule view_quiet_hours; do
  assert_in "$runtime_code" "let $name = commands.$name;" "runtime.uc must bind $name from commands"
done
for name in handle_fptn_token_update handle_sec_sub_add; do
  assert_in "$runtime_code" "let $name = callbacks.$name;" "runtime.uc must bind $name from callbacks"
done
assert_in "$callbacks_code" "let save_persistent_selector_choice = commands.save_persistent_selector_choice;" \
  "callbacks.uc must bind save_persistent_selector_choice from commands"

# 3. No caller may reference a handler that does not exist anywhere. The
#    "sub_add" state is never set and the handler has never existed, not even
#    in service/telegram.uc before the split.
assert_not_in "$runtime_code" "handle_sub_add(" "runtime.uc must not call a handler that is not defined"

# 4. A Telegram answer with ok:false is the API talking, not a failed request.
#    Counting 409/429 as poll failures doubled poll_interval per occurrence
#    until the bot waited 300 seconds between messages.
assert_not_in "$runtime_code" "if (!res || !res.ok || !res.result) return false;" \
  "process_updates must not treat an API-level decline as a transport failure"
assert_in "$runtime_code" "not counted as a poll failure" \
  "process_updates must log an API-level decline instead of backing off"

printf 'telegram binding and poll-failure checks passed\n'
