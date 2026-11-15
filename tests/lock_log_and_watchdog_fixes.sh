#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
SUPERVISOR_UC="$TACHYON_LIB/service/watchdog_supervisor.uc"
BINARIES_UC="$TACHYON_LIB/diagnostics/fuzzer/binaries.uc"
HOTPLUG_SRC="$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"

uc() {
  command ucode -L "$TACHYON_LIB" "$@"
}

# 1. binaries.uc syntax & zero strict equality JS-isms, plus no orphan children on timeout
grep -qE '===|!==' "$BINARIES_UC" && fail "binaries.uc still contains strict equality JS operator"
ucode -S -c -o /dev/null "$BINARIES_UC" || fail "binaries.uc failed strict syntax check"

CHILD_PID_FILE="$WORK_DIR/orphan_child.pid"
CHILD_CMD="sh -c 'sleep 30 & echo \$! > \"$CHILD_PID_FILE\"; wait'"
uc - "$CHILD_CMD" <<'UCODE'
let b = require("diagnostics.fuzzer.binaries");
b.run_bounded(ARGV[0], 1);
UCODE
[ -s "$CHILD_PID_FILE" ] || fail "run_bounded test child did not write its PID"
ORPHAN_PID="$(cat "$CHILD_PID_FILE")"
sleep 0.1
if kill -0 "$ORPHAN_PID" 2>/dev/null; then
  kill -9 "$ORPHAN_PID" 2>/dev/null || true
  fail "run_bounded left orphaned child PID $ORPHAN_PID running after timeout"
fi

# 2. watchdog_supervisor.uc .err file rotation & O_APPEND trimming without sparse bloat
ERR_FILE="$WORK_DIR/worker.err"
uc - "$ERR_FILE" <<'UCODE'
let fs = require("fs");
let big = [];
for (let i = 0; i < 1500; i++)
    push(big, sprintf("line-%04d: sample diagnostic error message padding 0123456789abcdef\n", i));
fs.writefile(ARGV[0], join("", big));
UCODE

ORIG_SIZE="$(wc -c <"$ERR_FILE")"
[ "$ORIG_SIZE" -gt 65536 ] || fail "setup err file was not oversized: $ORIG_SIZE"

TACHYON_WATCHDOG_ERR_FILE="$ERR_FILE" \
TACHYON_WATCHDOG_ERR_MAX_BYTES=65536 \
TACHYON_WATCHDOG_ERR_KEEP_BYTES=16384 \
  uc - <<'UCODE'
let sup = require("service.watchdog_supervisor");
if (!sup.trim_worker_err_file()) {
    warn("expected trim_worker_err_file() to return true on oversized file\n");
    exit(1);
}
UCODE

TRIM_SIZE="$(wc -c <"$ERR_FILE")"
[ "$TRIM_SIZE" -le 16384 ] || fail "trimmed err file exceeded keep bound: $TRIM_SIZE"
head -n 1 "$ERR_FILE" | grep -qE '^line-[0-9]{4}:' || fail "trimmed err file did not align on line boundary"
grep -Fq 'line-1499:' "$ERR_FILE" || fail "trimmed err file lost newest trailing line"

# Live supervise loop bounds growing stderr without sparse offset jump
cat >"$WORK_DIR/spam_worker.uc" <<'UCODE'
for (let i = 0; i < 6; i++) {
    for (let j = 0; j < 20; j++)
        printf("spam-chunk-%02d-%02d: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i, j);
    sleep(400);
}
while (true) sleep(500);
UCODE

SUP_ERR="$WORK_DIR/live_worker.err"
SUP_PID_FILE="$WORK_DIR/wd.sup.pid"
W_PID_FILE="$WORK_DIR/wd.pid"

TACHYON_WATCHDOG_ERR_FILE="$SUP_ERR" \
TACHYON_WATCHDOG_ERR_MAX_BYTES=2048 \
TACHYON_WATCHDOG_ERR_KEEP_BYTES=512 \
TACHYON_WATCHDOG_PID_FILE="$W_PID_FILE" \
TACHYON_WATCHDOG_SUPERVISOR_PID_FILE="$SUP_PID_FILE" \
TACHYON_WATCHDOG_WORKER_UC="$WORK_DIR/spam_worker.uc" \
TACHYON_WATCHDOG_RESTART_DELAY_MS=200 \
  uc "$WATCHDOG_UC" supervise >/dev/null 2>"$WORK_DIR/sup.err" &
SUP_PID=$!
printf '%s' "$SUP_PID" >"$SUP_PID_FILE"

for _ in $(seq 1 50); do
  [ -s "$W_PID_FILE" ] && break
  sleep 0.1
done
sleep 3
LIVE_SIZE="$(wc -c <"$SUP_ERR")"
uc "$WATCHDOG_UC" stop-runtime >/dev/null 2>&1 || {
  kill -9 "$SUP_PID" 2>/dev/null || true
  fail "stop-runtime failed in err rotation test"
}
[ "$LIVE_SIZE" -le 4096 ] || fail "live supervisor worker.err grew past expected trim bound (sparse offset?): $LIVE_SIZE bytes"

# 3. RELOAD_LOCK_DIR synchronization in wan_failover.uc and 99-tachyon-wan-monitor
LOCK_DIR="$WORK_DIR/run/reload.lock"
mkdir -p "$WORK_DIR/run" "$WORK_DIR/mock_bin"
HUP_STAMP="$WORK_DIR/hup_received.stamp"

sh -c 'trap "printf 1 >> \"'"$HUP_STAMP"'\"" HUP; trap "exit 0" TERM; while :; do sleep 1; done' &
TARGET_PID=$!
cleanup_with_target() {
  kill "$TARGET_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup_with_target EXIT

cat >"$WORK_DIR/mock_bin/pgrep" <<EOF
#!/usr/bin/env bash
if [ "\$2" = "tachyon-core" ]; then
  printf '%s\n' "$TARGET_PID"
  exit 0
fi
exit 1
EOF
cat >"$WORK_DIR/mock_bin/pidof" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$TARGET_PID"
EOF
chmod +x "$WORK_DIR/mock_bin/pgrep" "$WORK_DIR/mock_bin/pidof"

# 3a. wan_failover.signal_core_hup skips while live holder holds lock, clears stale dead holder lock
sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
HOLDER_PID=$!
mkdir -p "$LOCK_DIR"
printf '%s\n' "$HOLDER_PID" >"$LOCK_DIR/pid"
rm -f "$HUP_STAMP"

PATH="$WORK_DIR/mock_bin:$PATH" \
TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
TACHYON_HUP_LOCK_TIMEOUT=1 \
  uc - <<'UCODE'
let wf = require("service.wan_failover");
if (wf.signal_core_hup()) {
    warn("signal_core_hup should skip when live reload lock is busy\n");
    exit(1);
}
UCODE
[ -d "$LOCK_DIR" ] || fail "wan_failover removed another live holder's RELOAD_LOCK_DIR"
[ ! -e "$HUP_STAMP" ] || fail "wan_failover sent SIGHUP despite busy RELOAD_LOCK_DIR"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true

# Now HOLDER_PID is dead while LOCK_DIR/pid still points to it (simulates SIGKILLed holder)
rm -f "$HUP_STAMP"
PATH="$WORK_DIR/mock_bin:$PATH" \
TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
TACHYON_HUP_LOCK_TIMEOUT=3 \
  uc - <<'UCODE'
let wf = require("service.wan_failover");
if (!wf.signal_core_hup()) {
    warn("signal_core_hup should recover stale dead-PID lock and send HUP\n");
    exit(1);
}
UCODE
for _ in $(seq 1 20); do
  [ -s "$HUP_STAMP" ] && break
  sleep 0.05
done
[ -s "$HUP_STAMP" ] || fail "wan_failover did not deliver SIGHUP after recovering stale lock"
[ ! -d "$LOCK_DIR" ] || fail "wan_failover leaked RELOAD_LOCK_DIR after sending SIGHUP"

# 3b. 99-tachyon-wan-monitor synchronizes schedule_core_hup via RELOAD_LOCK_DIR
TEST_HOTPLUG="$WORK_DIR/hotplug.sh"
cat >"$WORK_DIR/mock_bin/tachyon" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$WORK_DIR/mock_bin/initd_tachyon" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$WORK_DIR/mock_bin/logger" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$WORK_DIR/mock_bin/tachyon" "$WORK_DIR/mock_bin/initd_tachyon" "$WORK_DIR/mock_bin/logger"

sed -e "s|/var/run/tachyon|${WORK_DIR}/run|g" \
    -e "s|/usr/bin/tachyon|${WORK_DIR}/mock_bin/tachyon|g" \
    -e "s|/etc/init.d/tachyon|${WORK_DIR}/mock_bin/initd_tachyon|g" \
    -e 's|schedule_core_hup 1|schedule_core_hup 0|g' \
    "$HOTPLUG_SRC" >"$TEST_HOTPLUG"
chmod +x "$TEST_HOTPLUG"

sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
HP_HOLDER=$!
mkdir -p "$LOCK_DIR"
printf '%s\n' "$HP_HOLDER" >"$LOCK_DIR/pid"
rm -f "$HUP_STAMP"

PATH="$WORK_DIR/mock_bin:$PATH" \
TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
TACHYON_HUP_LOCK_TIMEOUT=1 \
ACTION=ifup INTERFACE=wan \
  sh "$TEST_HOTPLUG"
sleep 1.4
[ -d "$LOCK_DIR" ] || fail "hotplug stole live reload lock"
[ ! -e "$HUP_STAMP" ] || fail "hotplug sent SIGHUP while live reload lock was held"
kill "$HP_HOLDER" 2>/dev/null || true
wait "$HP_HOLDER" 2>/dev/null || true

# Stale dead-PID lock left by crashed holder must be cleared and SIGHUP sent
rm -f "$HUP_STAMP"
PATH="$WORK_DIR/mock_bin:$PATH" \
TACHYON_RELOAD_LOCK_DIR="$LOCK_DIR" \
TACHYON_HUP_LOCK_TIMEOUT=3 \
ACTION=ifup INTERFACE=wan \
  sh "$TEST_HOTPLUG"
for _ in $(seq 1 30); do
  [ -s "$HUP_STAMP" ] && [ ! -d "$LOCK_DIR" ] && break
  sleep 0.1
done
[ -s "$HUP_STAMP" ] || fail "hotplug failed to send SIGHUP after stale lock recovery"
[ ! -d "$LOCK_DIR" ] || fail "hotplug leaked RELOAD_LOCK_DIR after sending SIGHUP"

# 4. watchdog.uc failover gating & runtime worker err log path
grep -Fq 'has_active_section_failover_policy' "$WATCHDOG_UC" ||
  fail "watchdog.uc must gate check_section_failover on active policy"
grep -Fq 'tachyon_watchdog_worker.err' "$WATCHDOG_UC" ||
  fail "watchdog.uc trim_runtime_logs must include tachyon_watchdog_worker.err"
ucode -S -c -o /dev/null "$WATCHDOG_UC" || fail "watchdog.uc failed strict syntax check"

printf 'PASS: lock_log_and_watchdog_fixes\n'
