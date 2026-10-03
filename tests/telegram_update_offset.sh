#!/usr/bin/env bash
# Pressing one button produced fifteen replies.
#
# Telegram forgets an update only when a later getUpdates carries an offset past
# it, so the offset file is the only thing that stops a handled update from being
# answered a second time. process_updates() used to read it at the start of a poll
# and write it once at the very end - after every reply of the batch had already
# been sent. A worker that died mid-batch therefore lost the acknowledgement of
# updates it had already answered, and the next poll fetched them again, once per
# restart. That is what "already 15 messages" looks like.
#
# The invariant, asserted directly: the offset is on disk before the reply that the
# update authorises. The stub reads the offset file at the moment it is asked to
# send, so a run that answers first and acknowledges afterwards is a failure rather
# than a comment in a log.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
RUNTIME_UC="$LIB_DIR/service/telegram/runtime.uc"
[ -f "$RUNTIME_UC" ] || fail "missing $RUNTIME_UC"

OFFSET_FILE="$WORK_DIR/tachyon_telegram_offset"
VIOLATIONS="$WORK_DIR/violations.log"
CALLS="$WORK_DIR/calls.log"
: >"$OFFSET_FILE"
: >"$VIOLATIONS"
: >"$CALLS"

cat >"$WORK_DIR/uci.state" <<'STATE'
tachyon.telegram=telegram
tachyon.telegram.enabled=1
tachyon.telegram.bot_token=123456:test-token
tachyon.telegram.admin_ids=42
tachyon.telegram.language=en
STATE

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<STUB
#!/usr/bin/env bash
set -eo pipefail
url="\${!#}"
method="\${url##*/}"

if [ "\$method" = "getUpdates" ]; then
  printf 'poll\n' >> "$CALLS"
  printf '{"ok":true,"result":[{"update_id":500,"message":{"message_id":1,"chat":{"id":42},"text":"/menu"}}]}'
  exit 0
fi

if [ "\$method" = "sendMessage" ] || [ "\$method" = "editMessageText" ]; then
  printf 'reply\n' >> "$CALLS"
  # An absent or empty offset file means "nothing acknowledged yet". Defaulting it
  # matters: comparing an empty string with -lt is a shell error, not a failure, so
  # the violation would be silently skipped on exactly the run that needs it.
  offset="\$(cat "$OFFSET_FILE" 2>/dev/null || true)"
  offset="\${offset:-0}"
  if [ "\$offset" -lt 501 ]; then
    printf 'answered update 500 while the offset was still %s\n' "\$offset" >> "$VIOLATIONS"
  fi
fi

printf '{"ok":true,"result":{}}'
STUB
chmod 0755 "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/poll.uc" <<'UCODE'
let runtime = require("service.telegram.runtime");
runtime.process_updates("123456:test-token", "42");
UCODE

PATH="$WORK_DIR/bin:$PATH" \
TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
TACHYON_TELEGRAM_OFFSET_FILE="$OFFSET_FILE" \
  ucode -S -L "$LIB_DIR" "$WORK_DIR/poll.uc" >"$WORK_DIR/run.log" 2>&1 || {
    cat "$WORK_DIR/run.log" >&2
    fail "process_updates failed"
  }

[ -s "$VIOLATIONS" ] &&
  { cat "$VIOLATIONS" >&2; fail "the bot answered before acknowledging the update"; }

replies="$(grep -c '^reply$' "$CALLS" || true)"
[ "$replies" -ge 1 ] ||
  { cat "$CALLS" >&2; fail "the bot never answered the update"; }

[ "$(cat "$OFFSET_FILE")" = "501" ] ||
  fail "offset ended at $(cat "$OFFSET_FILE"), expected 501"

printf 'telegram update offset: acknowledged before answering, %s reply\n' "$replies"
printf 'PASS: telegram_update_offset\n'