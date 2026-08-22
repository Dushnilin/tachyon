#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TG="$TACHYON_LIB/service/telegram.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$TG" ] || fail "telegram.uc not found"

# 1. Proxy selection must verify the mixed port actually listens; a running
#    sing-box with a failed inbound used to blackhole every bot request.
grep -Fq 'function mixed_port_alive()' "$TG" ||
  fail "telegram.uc must define mixed_port_alive()"
grep -Fq 'if (!mixed_port_alive()) {' "$TG" ||
  fail "get_proxy_args must gate the 4534 route on an actual listener"
grep -Fq 'netstat' "$TG" ||
  fail "mixed_port_alive must probe netstat listeners"

# 2. Direct fallback: when the proxy route fails, tg_request retries without
#    proxy; UCI telegram.bot_direct_fallback='0' opts out.
grep -Fq 'function tg_request_via(token, method, payload, proxy_args)' "$TG" ||
  fail "tg_request must be split into a per-route worker (tg_request_via)"
grep -Fq 'function direct_fallback_enabled()' "$TG" ||
  fail "telegram.uc must define direct_fallback_enabled()"
grep -Fq 'res = tg_request_via(token, method, payload, []);' "$TG" ||
  fail "tg_request must retry over the direct route when the proxy fails"

# 3. One-shot admin alert per failure episode after repeated poll failures.
grep -Fq 'route_alert_sent = true;' "$TG" ||
  fail "worker loop must raise a one-shot route failure alert"
grep -Fq 'alert_route_failure(consecutive_failures, mixed_port_alive());' "$TG" ||
  fail "worker loop must call alert_route_failure with the port state"
grep -Fq 'route_alert_sent = false;' "$TG" ||
  fail "worker loop must re-arm the alert after recovery"

# 4. Heartbeat for the watchdog liveness check + tmpfs log ceiling.
grep -Fq 'function write_heartbeat()' "$TG" ||
  fail "worker must expose a heartbeat writer"
grep -Fq 'write_heartbeat();' "$TG" ||
  fail "worker loop must stamp the heartbeat after a successful poll"
grep -Fq 'function rotate_log_if_needed()' "$TG" ||
  fail "worker must rotate its tmpfs log"

# 5. /doctor renders a readable summary instead of raw JSON.
grep -Fn 'header = sprintf("Проблем: %s", as_string(data.issues));' "$TG" >/dev/null ||
  fail "exec_doctor must render issue counts from the doctor JSON envelope"

printf 'telegram proxy fallback checks passed\n'
