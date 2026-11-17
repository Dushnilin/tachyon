#!/usr/bin/env bash
# An OOM healer that restarts Tachyon or shrinks fake Go caps creates reboot loops.
#
# Checked here:
# 1. heal_oom() never calls `tachyon restart`, `logread -c`, or writes `/etc/tachyon/mem_scale`.
# 2. service.oom_report classifies host/cgroup/core OOM outcomes without restarts.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
[ -f "$WATCHDOG_UC" ] || fail "missing $WATCHDOG_UC"

body="$(sed -n '/^function heal_oom/,/^}/p' "$WATCHDOG_UC" | grep -v '^[[:space:]]*//')"
[ -n "$body" ] || fail "heal_oom not found"

if grep -q 'tachyon restart' <<<"$body"; then
  fail "heal_oom must not restart all of Tachyon on OOM (procd respawns tachyon-core on its own)"
fi

if grep -q 'logread -c' <<<"$body"; then
  fail "heal_oom must not wipe syslog via logread -c"
fi

if grep -qE 'mem_scale|write_state_file|GOMEMLIMIT' <<<"$body"; then
  fail "heal_oom must not touch legacy Go GOMEMLIMIT or mem_scale files"
fi

grep -q 'read_oom_report()' <<<"$body" || fail "heal_oom must wait for the complete kernel OOM report"
grep -q 'oom_report_mod.oom_response(' <<<"$body" || fail "heal_oom must classify OOM response via service.oom_report"

printf 'PASS: watchdog_oom_loop\n'
