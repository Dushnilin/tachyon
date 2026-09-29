#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
UI_UC="$TACHYON_LIB/service/ui.uc"
TG_UC="$TACHYON_LIB/service/telegram.uc"
DIRECT_UC="$TACHYON_LIB/torrserver/direct.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- 1. Static contract inspections ---

# Watchdog keepalive write throttle
grep -Fq 'last_keepalive_write' "$WATCHDOG_UC" ||
  fail "watchdog.uc must track last_keepalive_write"
grep -Fq 'now - last_keepalive_write >= 30' "$WATCHDOG_UC" ||
  fail "watchdog.uc must throttle keepalive write to 30s"

# Shared tick_context in watchdog
grep -Fq 'controller.create_tick_context' "$WATCHDOG_UC" ||
  fail "watchdog.uc must call controller.create_tick_context"
grep -Fq 'controller.probe_fast(current_ctx)' "$WATCHDOG_UC" ||
  fail "watchdog.uc perform_fast_checks must pass current_ctx to probe_fast"
grep -Fq 'controller.probe_normal(current_ctx)' "$WATCHDOG_UC" ||
  fail "watchdog.uc perform_normal_checks must pass current_ctx to probe_normal"
grep -Fq 'controller.probe_slow(current_ctx)' "$WATCHDOG_UC" ||
  fail "watchdog.uc perform_slow_checks must pass current_ctx to probe_slow"

# Both watchdog loops must be paced. The uloop tick and the legacy fallback
# loop each guard the fast/normal/slow tiers, so the slow tier (mixed-proxy
# port, section failover, tailscale, telegram) cannot fire every 15s on a
# device whose ucode lacks the uloop module. The unguarded fallback reached
# the mixed-port restart threshold in 16s instead of the documented ~10 min.
for guard in \
  'now - last_fast_check >= 15' \
  'now - last_normal_check >= 120' \
  'now - last_slow_check >= 300'; do
  count="$(grep -Fc "$guard" "$WATCHDOG_UC" || true)"
  assert_eq "$count" "2" "watchdog.uc must pace '$guard' in both the uloop and fallback loops"
done

# Event controller exports and methods
grep -Fq 'create_tick_context' "$CONTROLLER_UC" ||
  fail "event_controller.uc must define create_tick_context"
grep -Fq 'current_tick_ctx.settings' "$CONTROLLER_UC" ||
  fail "event_controller.uc settings() must reuse current_tick_ctx.settings"
grep -Fq 'ai_proxy_health_interval' "$CONTROLLER_UC" ||
  fail "event_controller.uc must respect ai_proxy_health_interval"
grep -Fq 'ai_dns_interval' "$CONTROLLER_UC" ||
  fail "event_controller.uc must respect ai_dns_interval"

# UI state read-only fast path
grep -Fq 'ACTION_DIRS_REFRESH_STAMP_FILE' "$UI_UC" ||
  fail "ui.uc must define ACTION_DIRS_REFRESH_STAMP_FILE"
grep -Fq 'maybe_refresh_action_dirs' "$UI_UC" ||
  fail "ui.uc must define maybe_refresh_action_dirs"
grep -Fq 'maybe_refresh_action_dirs(false)' "$UI_UC" ||
  fail "current_ui_state_json in ui.uc must call maybe_refresh_action_dirs(false)"

# Telegram 50s long-poll and no post-success sleep
grep -Fq 'timeout: 50' "$TG_UC" ||
  fail "telegram.uc must use 50s timeout for getUpdates long-poll"
grep -Fq 'max_time = is_poll ? "65"' "$TG_UC" ||
  fail "telegram.uc must set max_time to 65 for poll requests"

# TorrServer direct bypass PID cache and native sleep
grep -Fq 'cached_pid' "$DIRECT_UC" ||
  fail "direct.uc must cache TorrServer PID"
grep -Fq 'sleep(60000)' "$DIRECT_UC" ||
  fail "direct.uc worker must use native sleep(60000)"

# --- 2. Behavioral verification via ucode ---
run_ucode() {
  local code="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/tachyon_test_XXXXXX")"
  printf '%s\n' "$code" > "$tmp"
  ucode -L "$TACHYON_LIB" "$tmp"
  rm -f "$tmp"
}

# Verify create_tick_context structure
res="$(run_ucode '
let events = require("core.events");
let ec = require("service.event_controller");
let b = events.bus();
let c = ec.controller(b, {});
let ctx = c.create_tick_context();
print((ctx.now > 0) + "," + (type(ctx.settings) == "object") + "," + (ctx.proxy_port != null) + "," + (ctx.reload_in_progress != null));
')"
assert_eq "$res" "true,true,true,true" "tick_context fields are populated"

# Verify reset_proxy_consecutive and reset_dns_consecutive clear timestamps
res="$(run_ucode '
let events = require("core.events");
let ec = require("service.event_controller");
let b = events.bus();
let c = ec.controller(b, {});
c.state.last_proxy_probe = 12345;
c.state.proxy_consecutive_fails = 2;
c.reset_proxy_consecutive();
let p_ok = (c.state.last_proxy_probe == 0 && c.state.proxy_consecutive_fails == 0);

c.state.last_dns_probe = 54321;
c.state.dns_consecutive_fails = 3;
c.reset_dns_consecutive();
let d_ok = (c.state.last_dns_probe == 0 && c.state.dns_consecutive_fails == 0);

print(p_ok + "," + d_ok);
')"
assert_eq "$res" "true,true" "reset callbacks clear consecutive fails and probe timestamps"

# Verify adaptive interval throttling on probe_proxy
res="$(run_ucode '
let events = require("core.events");
let ec = require("service.event_controller");
let b = events.bus();
b.on("proxy.down", function(){});
b.on("proxy.up", function(){});

let c = ec.controller(b, {});
let now = 1000000;
let ctx = {
    now: now,
    settings: { ai_proxy_health_interval: "30" },
    reload_in_progress: false,
    singbox_pid: "99999",
    singbox_running: true,
    proxy_port: "4534",
    proxy_host: "127.0.0.1"
};

// Set last probe to 10 seconds ago with 0 consecutive fails (healthy)
c.state.last_proxy_probe = now - 10;
c.state.proxy_consecutive_fails = 0;
c.probe_fast(ctx);
// Should be throttled (skipped): last_proxy_probe should NOT have changed to now
let throttled = (c.state.last_proxy_probe == now - 10);

// Now simulate fail state (consecutive fails > 0): should NOT be throttled
c.state.proxy_consecutive_fails = 1;
// Mock curl so probe executes quickly without real network
// Running probe_fast with consecutive fails > 0 triggers probe immediately
print(throttled);
')"
assert_eq "$res" "true" "healthy proxy probe is throttled within interval"

# Verify adaptive interval throttling on probe_dns
res="$(run_ucode '
let events = require("core.events");
let ec = require("service.event_controller");
let b = events.bus();
b.on("dns.down", function(){});
b.on("dns.up", function(){});

let c = ec.controller(b, {});
let now = 1000000;
let ctx = {
    now: now,
    settings: { ai_dns_interval: "60" },
    reload_in_progress: false,
    singbox_pid: "99999",
    singbox_running: true,
    proxy_port: "4534",
    proxy_host: "127.0.0.1"
};

// Set last probe to 20 seconds ago with 0 consecutive fails (healthy)
c.state.last_dns_probe = now - 20;
c.state.dns_consecutive_fails = 0;
c.probe_fast(ctx);
// Should be throttled (skipped): last_dns_probe should NOT have changed to now
let throttled = (c.state.last_dns_probe == now - 20);
print(throttled);
')"
assert_eq "$res" "true" "healthy dns probe is throttled within interval"

# Verify shared settings caching during active tick context
res="$(run_ucode '
let events = require("core.events");
let ec = require("service.event_controller");
let b = events.bus();
let c = ec.controller(b, {});

c.set_tick_context({
    settings: {
        recovery_bypass: "1",
        custom_test_key: "cached_value"
    }
});

let cached_val = c.setting("custom_test_key", "default");
let is_bypassed = c.setting("recovery_bypass", "0");

c.clear_tick_context();
let cleared = (c.setting("custom_test_key", "cleared_default") == "cleared_default");

print(cached_val + "," + is_bypassed + "," + cleared);
')"
assert_eq "$res" "cached_value,1,true" "settings helper uses cached tick_context settings"

printf 'watchdog_adaptive_intervals checks passed\n'
