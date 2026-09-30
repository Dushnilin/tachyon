#!/usr/bin/env bash
# FAULT: the Telegram "test connection" button could never succeed.
#
# The UI runs `/usr/bin/tachyon telegram_diagnose` and renders the report only if
# the response has a `checks` array. Anything else - a crash, a non-JSON error, an
# empty body - becomes one flat line: "Failed to run diagnostics — is the
# tachyon binary installed?", which blames the binary rather than the bug.
#
# diagnose() crashed on the fourth check:
#
#   Type error: left-hand side is not a function
#   In diagnose(), file .../service/telegram/runtime.uc, line 664:
#     let proxy_info = get_mixed_proxy_info();
#
# Commit 57c7e2b0b (2026-09-25) split service/telegram.uc into submodules and
# imported twenty functions from transport.uc into runtime.uc. get_mixed_proxy_info
# was not one of the twenty: transport.uc defines and exports it, and diagnose()
# calls it, so it was simply not in scope. Every other symbol diagnose() touches
# is either local, imported from transport, or a core helper.
#
# The forward-reference lint does not catch this class. It checks that a function
# is declared before its first caller *inside one file*; this is a missing import
# from another file, which reads as an ordinary free identifier. Nothing else
# covered it either, so the button was broken for every user for as long as that
# refactor was on main.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

[ -f "$LIB_DIR/service/telegram/runtime.uc" ] || fail "service/telegram/runtime.uc not found"

out="$(TACHYON_LIB="$LIB_DIR" ucode -L "$LIB_DIR" "$LIB_DIR/service/telegram.uc" diagnose 2>&1 || true)"

# A crash is the failure this test exists for, so assert on the shape of the
# answer rather than its contents: which checks pass depends on the machine, but
# a diagnose that ran always answers with JSON carrying a non-empty checks array.
if printf '%s' "$out" | grep -q "not a function"; then
  fail "telegram diagnose crashed on an undefined function, so the UI falls back to \"Failed to run diagnostics\" and blames the binary: $out"
fi

if ! printf '%s' "$out" | grep -q '"checks"'; then
  fail "telegram diagnose did not return a checks array, which is what the UI requires before it will render anything: $out"
fi

# And the checks must actually be there, not an empty placeholder.
count="$(printf '%s' "$out" | grep -o '"name"' | wc -l)"
[ "$count" -ge 4 ] ||
  fail "telegram diagnose returned only $count checks; it is supposed to report at least bot_token, admin_ids, sing_box and dns: $out"

# The known check names guard against diagnose silently returning a short report
# that happens to satisfy the array check above.
for check in bot_token admin_ids sing_box proxy_port dns; do
  printf '%s' "$out" | grep -q "\"$check\"" ||
    fail "telegram diagnose is missing the $check check, so the report would be incomplete: $out"
done

printf 'fault: telegram diagnose returns a usable report passed\n'
