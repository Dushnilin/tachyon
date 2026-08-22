#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WD="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"
UPD="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
VAL="$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Watchdog self-healing for the mixed proxy port: live core + dead 4534
#    triggers a bounded restart, then an hourly-capped admin notification.
grep -Fq 'function check_mixed_proxy_port()' "$WD" ||
  fail "watchdog must define check_mixed_proxy_port()"
grep -Fq 'safe_call(check_mixed_proxy_port, "check_mixed_proxy_port");' "$WD" ||
  fail "slow checks must run check_mixed_proxy_port"
grep -Fq '/usr/bin/tachyon restart >/dev/null 2>&1' "$WD" ||
  fail "mixed port healing must restart the core once"
grep -Fq 'now - mixed_port_last_notify >= 3600' "$WD" ||
  fail "mixed port notifications must be capped to one per hour"

# 2. Telegram worker liveness: stale heartbeat with the bot enabled restarts
#    the worker instead of waiting for a user to notice the silence.
grep -Fq 'function check_telegram_worker()' "$WD" ||
  fail "watchdog must define check_telegram_worker()"
grep -Fq 'safe_call(check_telegram_worker, "check_telegram_worker");' "$WD" ||
  fail "slow checks must run check_telegram_worker"
grep -Fq '/var/run/tachyon_telegram.heartbeat' "$WD" ||
  fail "worker liveness must read the heartbeat file"
grep -Fq '/usr/bin/tachyon telegram_start >/dev/null 2>&1' "$WD" ||
  fail "liveness healing must restart the worker via telegram_start"

# 3. Legacy unmarked tachyon cron lines are stripped so crond stops running
#    component_updates_if_due twice per tick.
grep -Fq 'function strip_unmarked_tachyon_cron_lines(' "$UPD" ||
  fail "updates.uc must strip legacy unmarked cron lines"
grep -Fq 'strip_unmarked_tachyon_cron_lines(' "$UPD" || true
[ "$(grep -c 'strip_unmarked_tachyon_cron_lines(' "$UPD")" -ge 3 ] ||
  fail "unmarked cron line stripping must be applied to remove and refresh paths"
grep -Fq '(list_update|subscription_update|component_updates_if_due)' "$UPD" ||
  fail "legacy cron pattern must cover all three tachyon jobs"

# 4. Tunnel-style sections count as outbound configuration: a lone AWG/WARP
#    section must not trigger "No proxy outbound sections found".
grep -Fq 'contains([ "awg", "warp", "vpn", "openvpn", "masque",' "$VAL" ||
  fail "has_outbound_section must recognise tunnel-style actions"

printf 'watchdog self-heal checks passed\n'
