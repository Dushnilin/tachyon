#!/usr/bin/env bash
# Regression coverage for Telegram poll resilience and route failure alert suppression:
# 1. Dropped long-lived getUpdates via healthy proxy probes getMe instead of tripping route alerts.
# 2. Genuine proxy failure uses short direct fallback (timeout <= 5, -m <= 15).
# 3. process_updates uses timeout=25 and worker backoff keeps heartbeat fresh.
# 4. Quiet hours, tmpfs cooldown and outbox dedup_key prevent repeated route alert spam.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
CALLS_LOG="$WORK_DIR/curl_calls.log"
STAMP_FILE="$WORK_DIR/var/run/tachyon/telegram-route-alert.stamp"
OUTBOX_DIR="$WORK_DIR/outbox"
HEARTBEAT_FILE="$WORK_DIR/telegram.heartbeat"
OFFSET_FILE="$WORK_DIR/telegram.offset"
UCI_STATE="$WORK_DIR/uci.state"

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/var/run/tachyon" "$OUTBOX_DIR"
: >"$CALLS_LOG"
: >"$OFFSET_FILE"

cat >"$UCI_STATE" <<'STATE'
tachyon.telegram=telegram
tachyon.telegram.enabled=1
tachyon.telegram.bot_token=123456:test-token
tachyon.telegram.admin_ids=42
tachyon.telegram.language=en
tachyon.telegram.fallback_socks=127.0.0.1:4534
tachyon.telegram.bot_direct_fallback=1
tachyon.telegram.quiet_hours_enabled=0
tachyon.telegram.quiet_hours_start=0
tachyon.telegram.quiet_hours_end=24
STATE

cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eo pipefail

mode="${TACHYON_TEST_CURL_MODE:-idle_poll_drop}"
max_time=""
has_proxy=0
body=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-m" ]; then
    max_time="$arg"
  elif [ "$prev" = "-d" ]; then
    body="$arg"
  fi
  if [ "$arg" = "--proxy" ]; then
    has_proxy=1
  fi
  prev="$arg"
done

url="${!#}"
method="${url##*/}"
printf '%s|%s|proxy=%s|m=%s|body=%s\n' "$mode" "$method" "$has_proxy" "$max_time" "$body" >> "${CURL_CALLS_LOG}"

if [ "$mode" = "idle_poll_drop" ]; then
  if [ "$method" = "getUpdates" ]; then
    exit 28
  fi
  if [ "$method" = "getMe" ] && [ "$has_proxy" -eq 1 ]; then
    printf '{"ok":true,"result":{"id":123456,"is_bot":true}}'
    exit 0
  fi
  exit 7
fi

if [ "$mode" = "proxy_down_direct_ok" ]; then
  if [ "$has_proxy" -eq 1 ]; then
    exit 7
  fi
  printf '{"ok":true,"result":[]}'
  exit 0
fi

exit 28
STUB
chmod 0755 "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/verify_poll_resilience.uc" <<'UC'
let fs = require("fs");
let transport = require("service.telegram.transport");
let runtime = require("service.telegram.runtime");
let notifications = require("service.telegram.notifications");

let token = "123456:test-token";

// 1. Healthy proxy with dropped getUpdates long-poll must recover via getMe probe.
let poll_res = transport.tg_request(token, "getUpdates", { offset: 10, timeout: 25 });
if (!poll_res || !poll_res.ok || type(poll_res.result) != "array" || length(poll_res.result) != 0)
    die(sprintf("expected synthetic empty ok result after healthy getMe probe, got: %J\n", poll_res));

let proc_ok = runtime.process_updates(token, "42");
if (proc_ok !== true)
    die(sprintf("process_updates must succeed when getMe probe passes, got: %J\n", proc_ok));

// 2. Check worker heartbeat stays fresh during sleep_with_heartbeat.
let before_hb = fs.readfile(getenv("TACHYON_TG_HEARTBEAT")) || "";
runtime.sleep_with_heartbeat(1);
let after_hb = fs.readfile(getenv("TACHYON_TG_HEARTBEAT")) || "";
if (after_hb == "" || after_hb == before_hb && length(after_hb) == 0)
    die("sleep_with_heartbeat failed to write heartbeat file\n");

// 3. Direct submission deduplication via dedup_key.
let d1 = notifications.submit(token, "42", "alert-one", "HTML", null, null, "route_alert");
let d2 = notifications.submit(token, "42", "alert-two", "HTML", null, null, "route_alert");
if (!d1 || !d2)
    die("deduped notifications.submit calls must succeed\n");
let files = fs.glob(getenv("TACHYON_TELEGRAM_OUTBOX") + "/notice.*.json") || [];
if (length(files) != 1)
    die(sprintf("expected 1 deduplicated outbox notice, got %d\n", length(files)));
let item = json(fs.readfile(files[0]));
if (!item || item.text != "alert-two" || item.dedup_key != "route_alert")
    die(sprintf("unexpected deduplicated notice payload: %J\n", item));
fs.unlink(files[0]);

print("phase1_ok\n");
UC

PATH="$WORK_DIR/bin:$PATH" \
CURL_CALLS_LOG="$CALLS_LOG" \
TACHYON_TEST_CURL_MODE="idle_poll_drop" \
TACHYON_UCI_STATE_FILE="$UCI_STATE" \
TACHYON_TELEGRAM_OUTBOX="$OUTBOX_DIR" \
TACHYON_TG_ROUTE_ALERT_STAMP="$STAMP_FILE" \
TACHYON_TG_HEARTBEAT="$HEARTBEAT_FILE" \
TACHYON_TELEGRAM_OFFSET_FILE="$OFFSET_FILE" \
  ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_poll_resilience.uc" | grep -Fq "phase1_ok" ||
    fail "phase 1 (healthy getMe probe + process_updates + outbox dedup) failed"

grep -Fq "idle_poll_drop|getUpdates|proxy=1|m=35|body=offset=10&timeout=25" "$CALLS_LOG" ||
  { cat "$CALLS_LOG" >&2; fail "expected getUpdates call with -m 35 and timeout=25"; }

grep -Fq "idle_poll_drop|getUpdates|proxy=1|m=35|body=offset=0&timeout=25" "$CALLS_LOG" ||
  { cat "$CALLS_LOG" >&2; fail "process_updates did not pass timeout=25 to getUpdates"; }

grep -Fq "idle_poll_drop|getMe|proxy=1|m=12|" "$CALLS_LOG" ||
  { cat "$CALLS_LOG" >&2; fail "expected getMe liveness probe through proxy after getUpdates drop"; }

if grep -Fq "idle_poll_drop|getUpdates|proxy=0|" "$CALLS_LOG"; then
  cat "$CALLS_LOG" >&2
  fail "tg_request fell back to direct even though proxy getMe succeeded"
fi

# Phase 2: dead proxy triggers direct fallback with capped timeout=5 and -m 15.
: >"$CALLS_LOG"
cat >"$WORK_DIR/verify_direct_fallback.uc" <<'UC'
let transport = require("service.telegram.transport");
let res = transport.tg_request("123456:test-token", "getUpdates", { offset: 7, timeout: 25 });
if (!res || !res.ok)
    die(sprintf("expected direct fallback recovery when proxy fails, got: %J\n", res));
print("phase2_ok\n");
UC

PATH="$WORK_DIR/bin:$PATH" \
CURL_CALLS_LOG="$CALLS_LOG" \
TACHYON_TEST_CURL_MODE="proxy_down_direct_ok" \
TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_direct_fallback.uc" | grep -Fq "phase2_ok" ||
    fail "phase 2 (short direct fallback) failed"

grep -Fq "proxy_down_direct_ok|getUpdates|proxy=0|m=15|body=offset=7&timeout=5" "$CALLS_LOG" ||
  { cat "$CALLS_LOG" >&2; fail "direct fallback for getUpdates must cap timeout=5 and -m 15"; }

# Phase 3: quiet hours suppression and persistent cooldown across separate ucode processes.
cat >"$UCI_STATE" <<'STATE'
tachyon.telegram=telegram
tachyon.telegram.enabled=1
tachyon.telegram.bot_token=123456:test-token
tachyon.telegram.admin_ids=42
tachyon.telegram.language=en
tachyon.telegram.quiet_hours_enabled=1
tachyon.telegram.quiet_hours_start=0
tachyon.telegram.quiet_hours_end=24
STATE

cat >"$WORK_DIR/verify_alert_call.uc" <<'UC'
let transport = require("service.telegram.transport");
let res = transport.alert_route_failure(int(ARGV[0] || "5"), true);
print(res ? "true" : "false", "\n");
UC

quiet_res="$(
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_TELEGRAM_OUTBOX="$OUTBOX_DIR" \
  TACHYON_TG_ROUTE_ALERT_STAMP="$STAMP_FILE" \
  TACHYON_TG_ROUTE_ALERT_COOLDOWN="21600" \
    ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_alert_call.uc" 5
)"
[ "$quiet_res" = "false" ] || fail "alert_route_failure should return false during quiet hours, got: $quiet_res"
[ "$(find "$OUTBOX_DIR" -name 'notice.*.json' | wc -l)" -eq 0 ] ||
  fail "alert_route_failure queued a notice during quiet hours"
[ ! -f "$STAMP_FILE" ] || fail "quiet hours suppression must not consume cooldown stamp"

sed -i 's/quiet_hours_enabled=1/quiet_hours_enabled=0/' "$UCI_STATE"

first_res="$(
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_TELEGRAM_OUTBOX="$OUTBOX_DIR" \
  TACHYON_TG_ROUTE_ALERT_STAMP="$STAMP_FILE" \
  TACHYON_TG_ROUTE_ALERT_COOLDOWN="21600" \
    ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_alert_call.uc" 5
)"
[ "$first_res" = "true" ] || fail "first alert_route_failure outside quiet hours failed: $first_res"
[ -f "$STAMP_FILE" ] || fail "first alert_route_failure did not write cooldown stamp file"
[ "$(find "$OUTBOX_DIR" -name 'notice.*.json' | wc -l)" -eq 1 ] ||
  fail "expected 1 outbox notice after first alert"

# Remove queued item as if drained, then invoke alert_route_failure again from a fresh
# ucode process (simulating worker restart resetting RAM route_alert_sent).
rm -f "$OUTBOX_DIR"/notice.*.json

second_res="$(
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_TELEGRAM_OUTBOX="$OUTBOX_DIR" \
  TACHYON_TG_ROUTE_ALERT_STAMP="$STAMP_FILE" \
  TACHYON_TG_ROUTE_ALERT_COOLDOWN="21600" \
    ucode -S -L "$LIB_DIR" "$WORK_DIR/verify_alert_call.uc" 5
)"
[ "$second_res" = "true" ] || fail "cooldown alert_route_failure should return true, got: $second_res"
[ "$(find "$OUTBOX_DIR" -name 'notice.*.json' | wc -l)" -eq 0 ] ||
  fail "persistent cooldown stamp failed to suppress repeat alert after worker restart"

printf 'telegram poll resilience tests passed\n'
