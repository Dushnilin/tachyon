#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR_SCRIPT="$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$MONITOR_SCRIPT" ] || fail "99-tachyon-wan-monitor not found"

TMP_DIR="$(mktemp -d /tmp/tachyon_wan_monitor_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
VAR_RUN="$TMP_DIR/var_run"
mkdir -p "$BIN_DIR" "$VAR_RUN"

# Mock uci
cat > "$BIN_DIR/uci" << 'EOF'
#!/bin/sh
cmd="$1"
shift
case "$cmd" in
  -q)
    subcmd="$1"
    shift
    if [ "$subcmd" = "get" ]; then
      key="$1"
      case "$key" in
        tachyon.settings.enable_badwan_interface_monitoring)
          cat "${TEST_UCI_DIR}/enable_badwan" 2>/dev/null || echo "0"
          ;;
        tachyon.telegram.enabled)
          cat "${TEST_UCI_DIR}/telegram_enabled" 2>/dev/null || echo "0"
          ;;
        tachyon.settings.badwan_monitored_interfaces)
          cat "${TEST_UCI_DIR}/monitored_ifaces" 2>/dev/null || echo ""
          ;;
        *)
          echo ""
          ;;
      esac
    fi
    ;;
esac
EOF
chmod +x "$BIN_DIR/uci"

# Mock ubus
cat > "$BIN_DIR/ubus" << 'EOF'
#!/bin/sh
# Check if call network.interface.<iface> status
for arg in "$@"; do
  case "$arg" in
    network.interface.*)
      iface="${arg#network.interface.}"
      state="$(cat "${TEST_UCI_DIR}/ubus_state_${iface}" 2>/dev/null || echo "up")"
      if [ "$state" = "up" ]; then
        echo '{"up": true, "pending": false, "available": true}'
      else
        echo '{"up": false, "pending": false, "available": false}'
      fi
      exit 0
      ;;
  esac
done
echo '{}'
EOF
chmod +x "$BIN_DIR/ubus"

# Mock logger
cat > "$BIN_DIR/logger" << 'EOF'
#!/bin/sh
echo "$@" >> "${TEST_LOG_FILE}"
EOF
chmod +x "$BIN_DIR/logger"

# Mock tachyon cli (for send_telegram_notification)
cat > "$BIN_DIR/tachyon" << 'EOF'
#!/bin/sh
echo "$@" >> "${TEST_TELEGRAM_LOG}"
exit 0
EOF
chmod +x "$BIN_DIR/tachyon"

export PATH="$BIN_DIR:$PATH"
export TEST_UCI_DIR="$TMP_DIR/uci"
export TEST_LOG_FILE="$TMP_DIR/logger.log"
export TEST_TELEGRAM_LOG="$TMP_DIR/telegram.log"
mkdir -p "$TEST_UCI_DIR"

# Patch monitor script temporarily to use our isolated /var/run/tachyon dir and fast debounce (0.1s instead of 2s)
TEST_MONITOR="$TMP_DIR/monitor_under_test.sh"
sed -e "s|/var/run/tachyon|${VAR_RUN}|g" \
    -e "s|sleep 2|sleep 0.1|g" \
    "$MONITOR_SCRIPT" > "$TEST_MONITOR"
chmod +x "$TEST_MONITOR"

# Test 1: Monitoring disabled (enable_badwan = 0)
echo "0" > "$TEST_UCI_DIR/enable_badwan"
echo "1" > "$TEST_UCI_DIR/telegram_enabled"
echo "wan" > "$TEST_UCI_DIR/monitored_ifaces"
echo "down" > "$TEST_UCI_DIR/ubus_state_wan"

ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 0.2
[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 1 failed: notification sent when enable_badwan=0"

# Test 2: Telegram disabled (telegram_enabled = 0)
echo "1" > "$TEST_UCI_DIR/enable_badwan"
echo "0" > "$TEST_UCI_DIR/telegram_enabled"
ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 0.2
[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 2 failed: notification sent when telegram.enabled=0"

# Test 3: Unmonitored interface (wan6 triggered, only wan is monitored)
echo "1" > "$TEST_UCI_DIR/enable_badwan"
echo "1" > "$TEST_UCI_DIR/telegram_enabled"
echo "wan" > "$TEST_UCI_DIR/monitored_ifaces"
echo "down" > "$TEST_UCI_DIR/ubus_state_wan6"
ACTION="ifdown" INTERFACE="wan6" sh "$TEST_MONITOR"
sleep 0.2
[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 3 failed: notification sent for unmonitored interface wan6"

# Test 4: Monitored interface drops (wan ifdown, initial up -> down transition)
echo "1" > "$TEST_UCI_DIR/enable_badwan"
echo "1" > "$TEST_UCI_DIR/telegram_enabled"
echo "wan" > "$TEST_UCI_DIR/monitored_ifaces"
echo "up" > "$VAR_RUN/wan_state_wan" # interface was previously UP
echo "down" > "$TEST_UCI_DIR/ubus_state_wan"

ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
# Wait for background verification
sleep 0.3

[ -f "$TEST_TELEGRAM_LOG" ] || fail "Test 4 failed: no notification sent on UP -> DOWN transition"
grep -Fq "Интерфейс *wan* упал!" "$TEST_TELEGRAM_LOG" || fail "Test 4 failed: expected drop message not found in log"
[ "$(cat "$VAR_RUN/wan_state_wan")" = "down" ] || fail "Test 4 failed: state file not set to down"

# Test 5: Duplicate hotplug ifdown while state is already down (NO repeated spam)
rm -f "$TEST_TELEGRAM_LOG"
ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 0.3

[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 5 failed: duplicate notification sent on repeated ifdown without state change"

# Test 6: Interface recovers (wan ifup, transition down -> up)
rm -f "$TEST_TELEGRAM_LOG"
echo "up" > "$TEST_UCI_DIR/ubus_state_wan"

ACTION="ifup" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 0.3

[ -f "$TEST_TELEGRAM_LOG" ] || fail "Test 6 failed: no notification sent on DOWN -> UP recovery"
grep -Fq "Интерфейс *wan* поднялся!" "$TEST_TELEGRAM_LOG" || fail "Test 6 failed: expected recovery message not found in log"
[ "$(cat "$VAR_RUN/wan_state_wan")" = "up" ] || fail "Test 6 failed: state file not set to up"

# Test 7: Duplicate hotplug ifup while state is already up (NO duplicate message)
rm -f "$TEST_TELEGRAM_LOG"
ACTION="ifup" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 0.3

[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 7 failed: duplicate notification sent on repeated ifup without state change"

printf 'All 7 WAN monitor hotplug tests PASSED!\n'
