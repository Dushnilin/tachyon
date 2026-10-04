#!/usr/bin/env bash
# The watchdog worker used to be spawned detached with stdout and stderr both
# sent to /dev/null, with nothing reaping it: on firmware where the ucode
# uloop event loop segfaults, the worker died seconds after start, the death
# was never logged (the exec'd process has no shell left to print
# "Segmentation fault") and the watchdog stayed dead until the next manual
# start. start-runtime must spawn a supervisor that watches the worker pid
# file, logs every death with the uptime and respawns - and after two early
# deaths in TACHYON_WATCHDOG_LEGACY=1 mode, which forces the polling branch
# that never touches uloop. stop-runtime must take the supervisor down first,
# or it would respawn the worker we just killed.
#
# Both halves are exercised at runtime against a fake worker, so reverting
# any of it fails here.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"
[ -f "$WATCHDOG" ] || fail "missing $WATCHDOG"
command -v ucode >/dev/null 2>&1 || fail "ucode not on PATH"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# ─── Static wiring ───────────────────────────────────────────────────────────
grep -Fq 'WATCHDOG_UC, "supervise"' "$WATCHDOG" ||
  fail "start_runtime must spawn the supervisor, not the worker directly"
ok

grep -Fq 'shell_quote(SUPERVISOR_PID_FILE)' "$WATCHDOG" ||
  fail "start_runtime must record the supervisor pid for stop_runtime to find"
ok

grep -Fq 'remove_file(SUPERVISOR_PID_FILE)' "$WATCHDOG" ||
  fail "stop_runtime must remove the supervisor pid file"
ok

grep -Fq 'mode == "supervise"' "$WATCHDOG" ||
  fail "dispatcher must expose the supervise mode"
ok

grep -Fq 'getenv("TACHYON_WATCHDOG_LEGACY") == "1"' "$WATCHDOG" ||
  fail "worker must honour the legacy fallback flag"
ok

# ─── Runtime: crash loop escalates to legacy mode ────────────────────────────
cat >"$WORK_DIR/fake_worker.uc" <<'UCODE'
let fs = require("fs");
let log_path = getenv("TACHYON_TEST_SPAWN_LOG");
let fh = fs.open(log_path, "a");
if (fh) {
    fh.write((getenv("TACHYON_WATCHDOG_LEGACY") == "1" ? "legacy" : "normal") + "\n");
    fh.close();
}
if ((getenv("TACHYON_TEST_FAKE_MODE") || "fast") == "hold") {
    while (true) sleep(500);
}
exit(1);
UCODE

export TACHYON_WATCHDOG_PID_FILE="$WORK_DIR/wd.pid"
export TACHYON_WATCHDOG_SUPERVISOR_PID_FILE="$WORK_DIR/wd.sup.pid"
export TACHYON_WATCHDOG_WORKER_UC="$WORK_DIR/fake_worker.uc"
export TACHYON_WATCHDOG_RESTART_DELAY_MS=200
export TACHYON_WATCHDOG_STABLE_SECONDS=2
export TACHYON_TEST_SPAWN_LOG="$WORK_DIR/spawns.log"
export TACHYON_TEST_FAKE_MODE=fast

ucode -L "$TACHYON_LIB" "$WATCHDOG" supervise >/dev/null 2>"$WORK_DIR/sup1.err" &
SUP1=$!

for _ in $(seq 1 100); do
  if [ -f "$TACHYON_TEST_SPAWN_LOG" ] && [ "$(wc -l < "$TACHYON_TEST_SPAWN_LOG")" -ge 3 ]; then
    break
  fi
  sleep 0.1
done

[ -f "$TACHYON_TEST_SPAWN_LOG" ] || { kill "$SUP1" 2>/dev/null || true; fail "supervisor never spawned the worker"; }
SPAWNS="$(wc -l < "$TACHYON_TEST_SPAWN_LOG")"
[ "$SPAWNS" -ge 3 ] || { kill "$SUP1" 2>/dev/null || true; fail "expected at least 3 spawns after a crash loop, got $SPAWNS"; }
ok

mapfile -t SPAWN_LINES < "$TACHYON_TEST_SPAWN_LOG"
[ "${SPAWN_LINES[0]}" = "normal" ] ||
  { kill "$SUP1" 2>/dev/null || true; fail "first spawn must run the normal (uloop) worker, got ${SPAWN_LINES[0]}"; }
ok

[ "${SPAWN_LINES[1]}" = "normal" ] ||
  { kill "$SUP1" 2>/dev/null || true; fail "second spawn must still be normal before escalation, got ${SPAWN_LINES[1]}"; }
ok

[ "${SPAWN_LINES[2]}" = "legacy" ] ||
  { kill "$SUP1" 2>/dev/null || true; fail "third spawn after two early deaths must be legacy mode, got ${SPAWN_LINES[2]}"; }
ok

if ! kill -0 "$SUP1" 2>/dev/null; then
  fail "supervisor died while respawning instead of supervising"
fi
ok

kill "$SUP1" 2>/dev/null || true
for _ in $(seq 1 50); do
  kill -0 "$SUP1" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SUP1" 2>/dev/null; then
  kill -9 "$SUP1" 2>/dev/null || true
  fail "supervisor ignored SIGTERM"
fi
ok

# ─── Runtime: healthy worker is left alone, stop-runtime takes both down ─────
export TACHYON_TEST_SPAWN_LOG="$WORK_DIR/spawns2.log"
export TACHYON_TEST_FAKE_MODE=hold

ucode -L "$TACHYON_LIB" "$WATCHDOG" supervise >/dev/null 2>"$WORK_DIR/sup2.err" &
SUP2=$!
printf '%s' "$SUP2" >"$TACHYON_WATCHDOG_SUPERVISOR_PID_FILE"

WORKER_PID=""
for _ in $(seq 1 100); do
  if [ -s "$TACHYON_WATCHDOG_PID_FILE" ]; then
    WORKER_PID="$(cat "$TACHYON_WATCHDOG_PID_FILE")"
    kill -0 "$WORKER_PID" 2>/dev/null && break
  fi
  WORKER_PID=""
  sleep 0.1
done
[ -n "$WORKER_PID" ] || { kill "$SUP2" 2>/dev/null || true; fail "supervisor never got a live worker up"; }
ok

sleep 2
SPAWNS2="$(wc -l < "$TACHYON_TEST_SPAWN_LOG")"
[ "$SPAWNS2" -eq 1 ] ||
  { kill "$SUP2" 2>/dev/null || true; fail "healthy worker must not be respawned, saw $SPAWNS2 spawns"; }
ok

ucode -L "$TACHYON_LIB" "$WATCHDOG" stop-runtime >/dev/null 2>"$WORK_DIR/stop.err" ||
  fail "stop-runtime failed"
ok

for _ in $(seq 1 50); do
  kill -0 "$SUP2" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$SUP2" 2>/dev/null && { kill -9 "$SUP2" 2>/dev/null || true; fail "stop-runtime left the supervisor running"; }
ok

kill -0 "$WORKER_PID" 2>/dev/null && { kill -9 "$WORKER_PID" 2>/dev/null || true; fail "stop-runtime left the worker running"; }
ok

[ ! -f "$TACHYON_WATCHDOG_PID_FILE" ] || fail "worker pid file must be removed"
[ ! -f "$TACHYON_WATCHDOG_SUPERVISOR_PID_FILE" ] || fail "supervisor pid file must be removed"
ok

printf 'watchdog supervisor: %d checks passed\n' "$pass_count"
printf 'PASS: watchdog_supervisor\n'
