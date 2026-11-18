#!/usr/bin/env bash
# The feedback bot has no local ticket store: the form, the issue body and the
# group card are its whole contract. Its parsing and rendering helpers are pure
# functions, so they are pinned here without network, UCI or a running daemon.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

BOT="$ROOT_DIR/sandbox/tachyon-feedback-bot/src/usr/bin/tachyon-feedback-bot"

if [ ! -f "$BOT" ]; then
  echo "SKIP: bot script not found (sandbox only)"
  exit 0
fi
command -v ucode >/dev/null 2>&1 || fail "ucode is required"

# Syntax first: a parse error would otherwise look like a failing helper.
ucode -c -o /dev/null "$BOT" || fail "ucode syntax check failed"

out="$(ucode "$BOT" selftest)" || fail "selftest failed: $out"
case "$out" in
  *"selftest OK"*) ;;
  *) fail "unexpected selftest output: $out" ;;
esac

# The bot must never grow a ticket database again.
if grep -q "tickets.json" "$BOT"; then
  fail "bot still references a local ticket database"
fi

printf 'ok: feedback bot selftest\n'
