#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export TACHYON_TELEGRAM_OUTBOX="$WORK_DIR/outbox"
cat >"$WORK_DIR/test.uc" <<'UCODE'
let fs = require("fs");
let now = 1000;
let calls = 0;
let response = null;
let fixture_time = function() { return now; };
let fixture_transport = {
    send_message: function(token, chat, text, mode, keyboard) { calls++; return response; }
};
let notifications = (function() {
let time = fixture_time;
UCODE
sed 's/require("service.telegram.transport")/fixture_transport/' \
  "$TACHYON_LIB/service/telegram/notifications.uc" >>"$WORK_DIR/test.uc"
cat >>"$WORK_DIR/test.uc" <<'UCODE'
})();
let dir = getenv("TACHYON_TELEGRAM_OUTBOX");
function check(ok, message) { if (!ok) die(message + "\n"); }
function files() { return fs.glob(dir + "/notice.*.json") || []; }
check(!notifications.submit("", "42", "x"), "missing token accepted");
check(!notifications.submit("123:secret", "../42", "x"), "invalid recipient accepted");
check(notifications.submit("123:secret", "42", "notice", "HTML", null), "submission failed");
check(length(files()) == 1, "job missing");
let path = files()[0];
check(index(fs.readfile(path), "secret") < 0, "bot credential persisted");
check((fs.stat(path).mode & 0777) == 0600 && (fs.stat(dir).mode & 0777) == 0700, "outbox permissions too broad");
notifications.drain("999:another-bot");
check(calls == 0, "job sent as a different bot");
notifications.drain("123:secret");
let item = json(fs.readfile(path));
check(calls == 1 && item.attempts == 1 && item.next_try == 1060, "failed send lost job or backoff");
notifications.drain("123:secret");
check(calls == 1, "retry ran too early");
now = 1060;
response = { ok: false, error_code: 429, parameters: { retry_after: 500 } };
notifications.drain("123:secret");
item = json(fs.readfile(path));
check(item.next_try == 1560 && item.attempts == 2, "retry_after ignored");
response = { ok: true, result: { message_id: 7 } };
now = 1560;
notifications.drain("123:rotated-secret");
check(length(files()) == 0 && calls == 3, "confirmed job not removed after credential rotation");

// Jobs survive a new module instance/process: only files carry the state.
check(notifications.submit("123:secret", "42", "restart"), "restart submission failed");
check(length(files()) == 1, "restart job missing");
print("outbox retry and credential isolation passed\n");
UCODE
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/test.uc"
# Fresh interpreter, with the real module and no Telegram request: the wrong bot
# must retain the saved job without touching the transport.
ucode -S -L "$TACHYON_LIB" -e 'require("service.telegram.notifications").drain("999:other");'
[ "$(find "$TACHYON_TELEGRAM_OUTBOX" -name 'notice.*.json' | wc -l)" -eq 1 ] || fail 'restart lost queued notification'
printf 'Telegram notification outbox passed\n'
