#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TG_CONFIG="$ROOT_DIR/tachyon/files/etc/config/tachyon"
RENDERING_UC="$TACHYON_LIB/service/telegram/rendering.uc"
COMMANDS_UC="$TACHYON_LIB/service/telegram/commands.uc"
CALLBACKS_UC="$TACHYON_LIB/service/telegram/callbacks.uc"
RUNTIME_UC="$TACHYON_LIB/service/telegram/runtime.uc"
TRANSPORT_UC="$TACHYON_LIB/service/telegram/transport.uc"
I18N_UC="$TACHYON_LIB/service/i18n.uc"
WATCHDOG_UC="$TACHYON_LIB/service/watchdog.uc"
FAILOVER_UC="$TACHYON_LIB/service/failover.uc"
WAN_FAILOVER_UC="$TACHYON_LIB/service/wan_failover.uc"
PARENTAL_QUOTA_UC="$TACHYON_LIB/service/parental_quota.uc"
DNS_FAILOVER_UC="$TACHYON_LIB/tachyon_core/dns_failover.uc"
WAN_HOTPLUG="$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"
SETTINGS_TS="$ROOT_DIR/fe-app-tachyon/src/views/settings.ts"
SETTINGS_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"

# 1. Config, schema, i18n, and LuCI coverage for all notification toggles
for flag in \
  notify_crash \
  notify_restart \
  notify_server_switch \
  notify_subscription \
  notify_cert \
  notify_dns_leak \
  notify_auto_update \
  notify_smart_detect \
  notify_failover \
  notify_wan \
  notify_update_available \
  notify_parental \
  notify_route_alert
do
  grep -Fq "option $flag '1'" "$TG_CONFIG" || fail "etc/config/tachyon missing option $flag '1'"
  grep -Fq "$flag" "$SETTINGS_TS" || fail "settings.ts missing $flag"
  grep -Fq "$flag" "$SETTINGS_JS" || fail "built settings.js missing $flag"
done

# 2. Watchdog must use the dedicated flag rather than notify_crash for non-crash alerts
grep -Fq 'tcfg.notify_smart_detect != "0"' "$WATCHDOG_UC" ||
  fail "watchdog.uc must gate Smart Detect messages with notify_smart_detect"
grep -Fq 'notify_enabled(tcfg, "notify_server_switch")' "$WATCHDOG_UC" ||
  fail "watchdog.uc notify_urltest_switch must use notify_server_switch"
grep -Fq 'notify_enabled(tcfg, "notify_subscription")' "$WATCHDOG_UC" ||
  fail "watchdog.uc heal_subscriptions must use notify_subscription"
grep -Fq 'notify_enabled(tcfg, "notify_wan")' "$WATCHDOG_UC" ||
  fail "watchdog.uc heal_wan_and_gateway must use notify_wan"
grep -Fq 'notify_enabled(tcfg, "notify_restart")' "$WATCHDOG_UC" ||
  fail "watchdog.uc must gate restarts/resume/tailscale with notify_restart"

# 3. Other senders must check their dedicated flags
grep -Fq 'notify_failover' "$FAILOVER_UC" || fail "failover.uc must gate on notify_failover"
grep -Fq 'notify_wan' "$WAN_FAILOVER_UC" || fail "wan_failover.uc must gate on notify_wan"
grep -Fq 'notify_wan' "$WAN_HOTPLUG" || fail "99-tachyon-wan-monitor must gate on notify_wan"
grep -Fq 'notify_parental' "$PARENTAL_QUOTA_UC" || fail "parental_quota.uc must gate on notify_parental"
grep -Fq 'notify_dns_leak' "$DNS_FAILOVER_UC" || fail "dns_failover.uc must gate on notify_dns_leak"

# ── Runtime verification via isolated UCI state & stub tools ─────────────────
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/outbox" "$WORK_DIR/var_run"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_state.json"
export TACHYON_TELEGRAM_OUTBOX="$WORK_DIR/outbox"
export TACHYON_TG_ROUTE_ALERT_STAMP="$WORK_DIR/route_alert.stamp"
export TACHYON_TELEGRAM_BLOCKED_STATE_FILE="$WORK_DIR/blocked_counts.json"
export TACHYON_TEST_CURL_LOG="$WORK_DIR/curl.log"
export TACHYON_TEST_LAST_PAYLOAD="$WORK_DIR/last_payload.json"
export TACHYON_TEST_TACHYON_LOG="$WORK_DIR/tachyon_bin.log"
export TACHYON_BIN="$WORK_DIR/bin/tachyon"
export PATH="$WORK_DIR/bin:$PATH"

cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TACHYON_TEST_CURL_LOG"
for arg in "$@"; do
  case "$arg" in
    *"delay"*|*"proxies"*)
      printf '{"error":"unavailable"}'
      exit 0
      ;;
    "{}"|*"{"*)
      printf '%s' "$arg" > "$TACHYON_TEST_LAST_PAYLOAD"
      ;;
  esac
done
printf '{"ok":true,"result":{"message_id":101}}'
STUB
chmod +x "$WORK_DIR/bin/curl"

cat >"$WORK_DIR/bin/tachyon" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TACHYON_TEST_TACHYON_LOG"
if [ "$1" = "component_update_check_cache" ]; then
  printf '{"results":[{"component":"tachyon_core","success":true,"status":"outdated","current_version":"1.0.0","latest_version":"1.1.0"}]}'
fi
exit 0
STUB
chmod +x "$WORK_DIR/bin/tachyon"

cat >"$WORK_DIR/bin/nft" <<'STUB'
#!/bin/sh
printf 'table inet TachyonTable {\n chain dns_block {\n  meta l4proto udp packets 5 counter comment "tachyon-block:Kids"\n }\n}\n'
STUB
chmod +x "$WORK_DIR/bin/nft"

# Point runtime helper paths to WORK_DIR/bin/tachyon is tested for failover/update checks
cat >"$TACHYON_UCI_STATE_FILE" <<'STATE'
tachyon.settings=settings
tachyon.settings.smart_detect=0
tachyon.settings.smart_detect_mode=default
tachyon.settings.disable_quic=0
tachyon.settings.enable_watchdog=1
tachyon.telegram=telegram
tachyon.telegram.enabled=1
tachyon.telegram.bot_token=123456:TESTTOKEN
tachyon.telegram.admin_ids=999001
tachyon.telegram.language=ru
tachyon.telegram.daily_report_enabled=0
tachyon.telegram.quiet_hours_enabled=0
tachyon.kids=profile
tachyon.kids.label=Детский
tachyon.kids.avatar=👶
tachyon.kids.enabled=1
tachyon.bedtime=schedule
tachyon.bedtime.label=Ночной режим
tachyon.bedtime.enabled=1
tachyon.bedtime.notify=1
tachyon.bedtime.blocked_domains=youtube.com
STATE

# 4. Test rendering, commands, and callbacks end-to-end
ucode -L "$TACHYON_LIB" -e '
let uci_core = require("core.uci");
let rendering = require("service.telegram.rendering");
let callbacks = require("service.telegram.callbacks");
let commands = require("service.telegram.commands");

let check = function(cond, msg) {
    if (!cond) {
        warn("ASSERT FAIL: " + msg + "\n");
        exit(1);
    }
};

// Default-ON semantics when option is omitted in upgraded UCI config
check(rendering.effective_bool_value({}, "telegram", "notify_smart_detect"), "unset notify_smart_detect");
check(rendering.effective_bool_value({ notify_smart_detect: "1" }, "telegram", "notify_smart_detect"), "notify_smart_detect=1");
check(!rendering.effective_bool_value({ notify_smart_detect: "0" }, "telegram", "notify_smart_detect"), "notify_smart_detect=0");
check(!rendering.effective_bool_value({}, "settings", "smart_detect"), "unset smart_detect");
check(rendering.effective_bool_value({}, "settings", "qos_priority_engine"), "unset qos_priority_engine");

// /notifications renders all 13 flags cleanly
commands.view_notifications("123456:TESTTOKEN", 999001, null);

// First tap on unset notify_smart_detect MUST set it to "0" (not "1")
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/notif_tog notify_smart_detect", 101);
check(uci_core.get("tachyon", "telegram", "notify_smart_detect") == "0",
    "notify_smart_detect=" + uci_core.get("tachyon", "telegram", "notify_smart_detect"));

// Legacy /set_tog on unset default-true notify_wan MUST also set it to "0"
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/set_tog telegram telegram notify_wan 0", 101);
check(uci_core.get("tachyon", "telegram", "notify_wan") == "0",
    "notify_wan=" + uci_core.get("tachyon", "telegram", "notify_wan"));

// Tapping from watchdog context flips back to "1"
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/notif_tog notify_smart_detect watchdog", 101);
check(uci_core.get("tachyon", "telegram", "notify_smart_detect") == "1", "notify_smart_detect back to 1");

// Bulk disable and bulk enable
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/notif_all 0", 101);
for (let nk in rendering.NOTIFICATION_KEYS) {
    check(uci_core.get("tachyon", "telegram", nk) == "0", "notif_all 0 " + nk);
}
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/notif_all 1", 101);
for (let nk in rendering.NOTIFICATION_KEYS) {
    check(uci_core.get("tachyon", "telegram", nk) == "1", "notif_all 1 " + nk);
}

// Feature toggles: core, sd_mode, net, quic cycle
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/toggles core", 101);
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/tog core smart_detect", 101);
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/tog_sd_mode", 101);
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/tog net fakeip_enabled", 101);
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/tog_quic", 101);
check(uci_core.get("tachyon", "settings", "smart_detect") == "1", "smart_detect=1");
check(uci_core.get("tachyon", "settings", "smart_detect_mode") == "plus", "smart_detect_mode=plus");
check(uci_core.get("tachyon", "settings", "fakeip_enabled") == "0", "fakeip_enabled=0");
check(uci_core.get("tachyon", "settings", "disable_quic") == "tunneled", "disable_quic=tunneled");

callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/tog_quic", 101);
check(uci_core.get("tachyon", "settings", "disable_quic") == "all", "disable_quic=all");
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/tog_quic", 101);
check(uci_core.get("tachyon", "settings", "disable_quic") == "0", "disable_quic=0");

// Profile & schedule toggles
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/prof_tog kids", 101);
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/sched_tog bedtime", 101);
callbacks.dispatch_command("123456:TESTTOKEN", 999001, "/sched_notif bedtime", 101);
check(uci_core.get("tachyon", "kids", "enabled") == "0", "kids enabled=0");
check(uci_core.get("tachyon", "bedtime", "enabled") == "0", "bedtime enabled=0");
check(uci_core.get("tachyon", "bedtime", "notify") == "0", "bedtime notify=0");
' || fail "telegram toggles / callbacks ucode checks failed"

# Check rendered keyboard contains Smart Detect button in /notifications
ucode -L "$TACHYON_LIB" -e '
require("service.telegram.commands").view_notifications("123456:TESTTOKEN", 999001, null);
' >/dev/null
grep -Fq '/notif_tog notify_smart_detect' "$WORK_DIR/last_payload.json" ||
  fail "/notifications keyboard must include notify_smart_detect toggle"

# 5. Notification suppression checks (transport route alert + runtime blocked activity)
rm -f "$TACHYON_TG_ROUTE_ALERT_STAMP" "$WORK_DIR/outbox"/*.json 2>/dev/null || true
ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let uci_core = require("core.uci");
let transport = require("service.telegram.transport");
let runtime = require("service.telegram.runtime");

// Route alert suppressed when notify_route_alert == 0
uci_core.set("tachyon", "telegram", "notify_route_alert", "0");
uci_core.set("tachyon", "telegram", "notify_parental", "0");
uci_core.commit("tachyon");

if (transport.alert_route_failure(5, true) !== false) {
    warn("expected alert_route_failure false when notify_route_alert=0\n");
    exit(1);
}
if (length(fs.glob(getenv("TACHYON_TELEGRAM_OUTBOX") + "/*.json") || []) != 0) {
    warn("outbox must stay empty when notify_route_alert=0\n");
    exit(2);
}

// Blocked activity counter still updates, but sends no message when notify_parental=0
uci_core.set("tachyon", "bedtime", "enabled", "1");
uci_core.set("tachyon", "bedtime", "notify", "1");
uci_core.commit("tachyon");
runtime.check_blocked_activity({ admin_ids: "999001", bot_token: "123456:TESTTOKEN", notify_parental: "0" });
if (length(fs.glob(getenv("TACHYON_TELEGRAM_OUTBOX") + "/*.json") || []) != 0) {
    warn("outbox must stay empty when notify_parental=0\n");
    exit(3);
}

// Now re-enable notify_route_alert=1 -> alert_route_failure submits 1 receipt
uci_core.set("tachyon", "telegram", "notify_route_alert", "1");
uci_core.commit("tachyon");
if (!transport.alert_route_failure(5, false)) {
    warn("expected alert_route_failure truthy when notify_route_alert=1\n");
    exit(4);
}
if (length(fs.glob(getenv("TACHYON_TELEGRAM_OUTBOX") + "/*.json") || []) == 0) {
    warn("expected outbox receipt when notify_route_alert=1\n");
    exit(5);
}
' || fail "notification suppression runtime/transport checks failed"

# 6. Verify 99-tachyon-wan-monitor skips tachyon telegram send when notify_wan=0
cat >"$WORK_DIR/bin/uci" <<'STUB'
#!/bin/sh
case "$*" in
  *"tachyon.telegram.notify_wan"*)
    printf '%s\n' "${TACHYON_TEST_NOTIFY_WAN:-1}"
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$WORK_DIR/bin/uci"

# Ensure the hotplug notification block respects TACHYON_TEST_NOTIFY_WAN=0 vs 1
awk '/NOTIFY_WAN=/,/^    fi$/' "$WAN_HOTPLUG" > "$WORK_DIR/hotplug_snippet.sh"
cat >"$WORK_DIR/test_hotplug.sh" <<'SH'
#!/bin/sh
set -eu
INTERFACE="wan"
CURRENT_STATE="down"
PREV_STATE="up"
STATE_FILE="$WORK_DIR/wan_state"
TACHYON_BIN="$WORK_DIR/bin/tachyon"
SH
cat "$WORK_DIR/hotplug_snippet.sh" >> "$WORK_DIR/test_hotplug.sh"

: > "$TACHYON_TEST_TACHYON_LOG"
WORK_DIR="$WORK_DIR" TACHYON_TEST_NOTIFY_WAN="0" sh "$WORK_DIR/test_hotplug.sh"
[ ! -s "$TACHYON_TEST_TACHYON_LOG" ] || fail "hotplug sent telegram message when notify_wan=0"

WORK_DIR="$WORK_DIR" TACHYON_TEST_NOTIFY_WAN="1" sh "$WORK_DIR/test_hotplug.sh"
grep -Fq 'telegram send' "$TACHYON_TEST_TACHYON_LOG" || fail "hotplug did not send telegram message when notify_wan=1"

printf 'telegram toggles and notification gating tests passed\n'
