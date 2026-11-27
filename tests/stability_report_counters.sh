#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

STABILITY_UC="$TACHYON_LIB/diagnostics/stability.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"

FAKE_PROC="$WORK_DIR/proc"
FAKE_LOG="$WORK_DIR/logread.txt"
JOURNAL_PATH="$WORK_DIR/events.jsonl"
UCI_STATE="$WORK_DIR/uci.txt"

mkdir -p "$FAKE_PROC/self" "$FAKE_PROC/sys/fs" \
  "$FAKE_PROC/1001/fd" "$FAKE_PROC/1002/fd" "$FAKE_PROC/1003/fd"

printf '1200.00 100.00\n' > "$FAKE_PROC/uptime"
printf '100 0 1024\n' > "$FAKE_PROC/sys/fs/file-nr"
cat > "$FAKE_PROC/meminfo" <<'EOF'
MemTotal:        250000 kB
MemFree:          50000 kB
MemAvailable:     80000 kB
Buffers:          10000 kB
Cached:           20000 kB
SwapTotal:            0 kB
SwapFree:             0 kB
EOF
printf '99999 (ucode) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0 0\n' > "$FAKE_PROC/self/stat"

# 1001 = watchdog_supervisor.uc (must belong ONLY to watchdog, not tachyon)
printf 'ucode\n' > "$FAKE_PROC/1001/comm"
printf 'ucode\0-L\0/usr/lib/tachyon\0/usr/lib/tachyon/service/watchdog_supervisor.uc\0supervise\0' > "$FAKE_PROC/1001/cmdline"
printf '1001 (ucode) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 10000 0 0 0\n' > "$FAKE_PROC/1001/stat"
printf 'VmRSS:\t2048 kB\n' > "$FAKE_PROC/1001/status"

# 1002 = watchdog.uc worker
printf 'ucode\n' > "$FAKE_PROC/1002/comm"
printf 'ucode\0-L\0/usr/lib/tachyon\0/usr/lib/tachyon/service/watchdog.uc\0worker\0' > "$FAKE_PROC/1002/cmdline"
printf '1002 (ucode) S 1001 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 20000 0 0 0\n' > "$FAKE_PROC/1002/stat"
printf 'VmRSS:\t4096 kB\n' > "$FAKE_PROC/1002/status"

# 1003 = real tachyon ucode helper (dns_failover.uc)
printf 'ucode\n' > "$FAKE_PROC/1003/comm"
printf 'ucode\0-L\0/usr/lib/tachyon\0/usr/lib/tachyon/tachyon_core/dns_failover.uc\0worker\0' > "$FAKE_PROC/1003/cmdline"
printf '1003 (ucode) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 30000 0 0 0\n' > "$FAKE_PROC/1003/stat"
printf 'VmRSS:\t2048 kB\n' > "$FAKE_PROC/1003/status"

cat > "$UCI_STATE" <<'EOF'
tachyon.settings=settings
tachyon.settings.enable_watchdog=1
EOF

cat > "$FAKE_LOG" <<'EOF'
Fri Nov 27 20:10:00 2026 kern.warn kernel: tachyon: [warn] Watchdog: Restarting tachyon-core service only (proxy_down)
Fri Nov 27 20:12:00 2026 kern.warn kernel: tachyon: [warn] Watchdog: Escalating to full Tachyon restart (proxy_down): the lighter restart did not restore service
Fri Nov 27 20:14:00 2026 kern.err kernel: Out of memory: Killed process 999 (tachyon-core) total-vm:51200kB
Fri Nov 27 20:15:00 2026 user.info tachyon: [info] DNS failover: switched main DNS to priority 2 (1.1.1.1, probe_failed)
EOF

report_syslog_only="$(
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_PROC_ROOT="$FAKE_PROC" \
  TACHYON_LOGREAD_FIXTURE="$FAKE_LOG" \
  TACHYON_EVENT_JOURNAL_PATH="$JOURNAL_PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
    ucode -L "$TACHYON_LIB" "$STABILITY_UC" report
)"

REPORT_JSON="$report_syslog_only" node - <<'NODE'
const rep = JSON.parse(process.env.REPORT_JSON);
const daemons = (rep.uptimes && rep.uptimes.daemons) || {};
const tachyonPids = (daemons.tachyon && daemons.tachyon.pids) || [];
const watchdogPids = (daemons.watchdog && daemons.watchdog.pids) || [];

if (tachyonPids.includes(1001)) {
  console.error('watchdog_supervisor.uc (PID 1001) leaked into tachyon daemon PIDs:', tachyonPids);
  process.exit(1);
}
if (!tachyonPids.includes(1003)) {
  console.error('expected helper PID 1003 in tachyon daemon PIDs:', tachyonPids);
  process.exit(1);
}
if (!watchdogPids.includes(1001) || !watchdogPids.includes(1002)) {
  console.error('expected supervisor + worker PIDs in watchdog daemon PIDs:', watchdogPids);
  process.exit(1);
}

const rf = rep.restarts_and_flaps || {};
if (rf.watchdog_restarts !== 2) {
  console.error('expected watchdog_restarts === 2, got:', rf.watchdog_restarts);
  process.exit(1);
}
if (rf.engine_crashes !== 1) {
  console.error('expected engine_crashes === 1, got:', rf.engine_crashes);
  process.exit(1);
}
if (rf.dns_failovers !== 1) {
  console.error('expected dns_failovers === 1, got:', rf.dns_failovers);
  process.exit(1);
}

const titles = (rep.recent_incidents || []).map((i) => i.title);
for (const expected of ['watchdog_restart', 'engine_crash', 'dns_failover']) {
  if (!titles.includes(expected)) {
    console.error(`missing "${expected}" in recent_incidents:`, titles);
    process.exit(1);
  }
}
NODE

# Verify safe_proxy_restart in watchdog.uc publishes watchdog_restart to core.events
# and that simultaneous journal + syslog lines do not double-count restarts.
cat > "$WORK_DIR/test_publish.uc" <<'UC'
let events = require("core.events");
let reason = "proxy_down";
let level = "light";
events.publish("watchdog_restart", {
    reason: reason,
    level: level
}, {
    source: "watchdog",
    severity: "warning",
    message: "Watchdog restart (" + level + "): " + reason
});
UC
TACHYON_EVENT_JOURNAL_PATH="$JOURNAL_PATH" \
TACHYON_LIB="$TACHYON_LIB" \
  ucode -L "$TACHYON_LIB" "$WORK_DIR/test_publish.uc"

if ! awk '
  /^function safe_proxy_restart\(/ { in_fn = 1 }
  in_fn && /events\.publish\("watchdog_restart"/ { found = 1 }
  in_fn && /^\}/ { in_fn = 0 }
  END { exit found ? 0 : 1 }
' "$WATCHDOG_UC"; then
  fail "safe_proxy_restart in watchdog.uc must publish watchdog_restart via events.publish"
fi

report_with_journal="$(
  TACHYON_UCI_STATE_FILE="$UCI_STATE" \
  TACHYON_PROC_ROOT="$FAKE_PROC" \
  TACHYON_LOGREAD_FIXTURE="$FAKE_LOG" \
  TACHYON_EVENT_JOURNAL_PATH="$JOURNAL_PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
    ucode -L "$TACHYON_LIB" "$STABILITY_UC" report
)"

REPORT_JSON="$report_with_journal" node - <<'NODE'
const rep = JSON.parse(process.env.REPORT_JSON);
const rf = rep.restarts_and_flaps || {};
if (rf.watchdog_restarts !== 2) {
  console.error('expected deduplicated watchdog_restarts === 2 with both journal and syslog present, got:', rf.watchdog_restarts);
  process.exit(1);
}
NODE

printf 'stability_report_counters checks passed\n'
