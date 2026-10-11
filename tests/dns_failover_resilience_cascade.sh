#!/usr/bin/env bash
# Invariants preventing cascading restart loops, false SIGHUP failures,
# and watchdog staleness across package upgrades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

STATE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/state.uc"
LIFECYCLE_UC="$ROOT_DIR/tachyon/files/usr/lib/service/lifecycle.uc"
FAILOVER_UC="$ROOT_DIR/tachyon/files/usr/lib/singbox/dns_failover.uc"
WATCHDOG_UC="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"

[ -f "$STATE_UC" ] || fail "service/state.uc not found"
[ -f "$LIFECYCLE_UC" ] || fail "service/lifecycle.uc not found"
[ -f "$FAILOVER_UC" ] || fail "singbox/dns_failover.uc not found"
[ -f "$WATCHDOG_UC" ] || fail "service/watchdog.uc not found"

# 1. try_sighup_reload must have at least 10s (>= 20 * 0.5s ticks) deadline
deadline="$(grep -A20 'function try_sighup_reload' "$STATE_UC" | grep -oE 'deadline = [0-9]+' | grep -oE '[0-9]+')"
[ -n "$deadline" ] || fail "could not find deadline in try_sighup_reload"
if [ "$deadline" -lt 20 ]; then
  fail "try_sighup_reload deadline is only $deadline ticks (< 20 ticks / 10s), causing false fallback restarts"
fi

# 2. apply_selections timeout must be >= 30s so dns_failover_apply is not SIGKILLed
apply_timeout="$(grep -E 'timeout.*SERVICE_BIN.*dns_failover_apply' "$FAILOVER_UC" | grep -oE '"timeout", "[0-9]+"' | grep -oE '[0-9]+')"
[ -n "$apply_timeout" ] || fail "could not find timeout for dns_failover_apply in singbox/dns_failover.uc"
if [ "$apply_timeout" -lt 30 ]; then
  fail "apply_selections timeout is only ${apply_timeout}s (< 30s), killing dns_failover_apply mid-reload"
fi

# 3. dns_failover worker must not tight-loop in 1 second on dead main DNS
if grep -E 'next_active = now_seconds\(\) \+ .*1 : active_interval' "$FAILOVER_UC"; then
  fail "dns_failover worker still contains 1-second retry tight loop on !main.alive"
fi

# 4. wait_dns_failover_state in dns_failover_apply must give at least 10 attempts
attempts="$(grep -A8 'sing_box_pid_before = sing_box_runtime_pid' "$LIFECYCLE_UC" | grep -oE 'wait_dns_failover_state\(candidate_state_path, [0-9]+\)' | head -1 | grep -oE '[0-9]+')"
[ -n "$attempts" ] || fail "could not find wait_dns_failover_state attempts in lifecycle.uc"
if [ "$attempts" -lt 10 ]; then
  fail "wait_dns_failover_state has only $attempts attempts (< 10), timing out before DNS inbounds are ready"
fi

# 5. stop_main in lifecycle.uc must stop watchdog
grep -A60 'function stop_main' "$LIFECYCLE_UC" | grep -Fq 'WATCHDOG_UC' ||
  fail "stop_main in lifecycle.uc must stop WATCHDOG_UC to prevent orphan supervisors across upgrades"

# 6. watchdog.uc must inspect on-disk version and have self-update check
grep -Fq 'on_disk_tachyon_version' "$WATCHDOG_UC" ||
  fail "watchdog.uc must implement on_disk_tachyon_version to avoid comparing against stale in-memory constants"
grep -Fq 'check_watchdog_outdated' "$WATCHDOG_UC" ||
  fail "watchdog.uc must check if the watchdog process itself is outdated"

printf 'dns failover and sighup resilience checks passed\n'
