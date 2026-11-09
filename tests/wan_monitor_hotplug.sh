#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MONITOR_SCRIPT="$ROOT_DIR/tachyon/files/etc/hotplug.d/iface/99-tachyon-wan-monitor"

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
        tachyon.settings.badwan_reload_delay)
          cat "${TEST_UCI_DIR}/reload_delay" 2>/dev/null || echo "50"
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

# Mock tachyon init.d script
cat > "$BIN_DIR/initd_tachyon" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN_DIR/initd_tachyon"

# Mock tachyon cli (for send_telegram_notification)
cat > "$BIN_DIR/tachyon" << 'EOF'
#!/bin/sh
if [ "$1" = "telegram" ]; then
  echo "$@" >> "${TEST_TELEGRAM_LOG}"
fi
exit 0
EOF
chmod +x "$BIN_DIR/tachyon"

export PATH="$BIN_DIR:$PATH"
export TEST_UCI_DIR="$TMP_DIR/uci"
export TEST_LOG_FILE="$TMP_DIR/logger.log"
export TEST_TELEGRAM_LOG="$TMP_DIR/telegram.log"
mkdir -p "$TEST_UCI_DIR"

# Patch monitor script temporarily to use our isolated /var/run/tachyon dir and fast debounce (sleep 0 instead of 2s)
TEST_MONITOR="$TMP_DIR/monitor_under_test.sh"
# shellcheck disable=SC2016
sed -e "s|/var/run/tachyon|${VAR_RUN}|g" \
    -e "s|/usr/bin/tachyon|${BIN_DIR}/tachyon|g" \
    -e "s|/etc/init.d/tachyon|${BIN_DIR}/initd_tachyon|g" \
    -e 's|sleep "\$DELAY_SEC"|sleep 0|g' \
    -e 's|sleep 2|sleep 0|g' \
    "$MONITOR_SCRIPT" > "$TEST_MONITOR"
chmod +x "$TEST_MONITOR"

# Test 1: Monitoring disabled (enable_badwan = 0)
echo "0" > "$TEST_UCI_DIR/enable_badwan"
echo "1" > "$TEST_UCI_DIR/telegram_enabled"
echo "wan" > "$TEST_UCI_DIR/monitored_ifaces"
echo "down" > "$TEST_UCI_DIR/ubus_state_wan"

ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 1 failed: notification sent when enable_badwan=0"

# Test 2: Telegram disabled (telegram_enabled = 0)
echo "1" > "$TEST_UCI_DIR/enable_badwan"
echo "0" > "$TEST_UCI_DIR/telegram_enabled"
ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 2 failed: notification sent when telegram.enabled=0"

# Test 3: Unmonitored interface (wan6 triggered, only wan is monitored)
echo "1" > "$TEST_UCI_DIR/enable_badwan"
echo "1" > "$TEST_UCI_DIR/telegram_enabled"
echo "wan" > "$TEST_UCI_DIR/monitored_ifaces"
echo "down" > "$TEST_UCI_DIR/ubus_state_wan6"
ACTION="ifdown" INTERFACE="wan6" sh "$TEST_MONITOR"
[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 3 failed: notification sent for unmonitored interface wan6"

# Test 4: Monitored interface drops (wan ifdown, initial up -> down transition)
echo "1" > "$TEST_UCI_DIR/enable_badwan"
echo "1" > "$TEST_UCI_DIR/telegram_enabled"
echo "wan" > "$TEST_UCI_DIR/monitored_ifaces"
echo "up" > "$VAR_RUN/wan_state_wan" # interface was previously UP
echo "down" > "$TEST_UCI_DIR/ubus_state_wan"

ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
# Wait for background verification
sleep 1

[ -f "$TEST_TELEGRAM_LOG" ] || fail "Test 4 failed: no notification sent on UP -> DOWN transition"
grep -Fq "Интерфейс *wan* упал!" "$TEST_TELEGRAM_LOG" || fail "Test 4 failed: expected drop message not found in log"
[ "$(cat "$VAR_RUN/wan_state_wan")" = "down" ] || fail "Test 4 failed: state file not set to down"

# Test 5: Duplicate hotplug ifdown while state is already down (NO repeated spam)
rm -f "$TEST_TELEGRAM_LOG"
ACTION="ifdown" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 1

[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 5 failed: duplicate notification sent on repeated ifdown without state change"

# Test 6: Interface recovers (wan ifup, transition down -> up)
rm -f "$TEST_TELEGRAM_LOG"
echo "up" > "$TEST_UCI_DIR/ubus_state_wan"

ACTION="ifup" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 1

[ -f "$TEST_TELEGRAM_LOG" ] || fail "Test 6 failed: no notification sent on DOWN -> UP recovery"
grep -Fq "Интерфейс *wan* поднялся!" "$TEST_TELEGRAM_LOG" || fail "Test 6 failed: expected recovery message not found in log"
[ "$(cat "$VAR_RUN/wan_state_wan")" = "up" ] || fail "Test 6 failed: state file not set to up"

# Test 7: Duplicate hotplug ifup while state is already up (NO duplicate message)
rm -f "$TEST_TELEGRAM_LOG"
ACTION="ifup" INTERFACE="wan" sh "$TEST_MONITOR"
sleep 1

[ ! -f "$TEST_TELEGRAM_LOG" ] || fail "Test 7 failed: duplicate notification sent on repeated ifup without state change"

# Test 8: GL.iNet secondwan / tethering transport state tracking on ifup and ifdown
ACTION="ifup" INTERFACE="secondwan" sh "$TEST_MONITOR"
[ "$(cat "$VAR_RUN/wan_transport_secondwan" 2>/dev/null)" = "up" ] || fail "Test 8 failed: secondwan transport not marked up"
ACTION="ifdown" INTERFACE="secondwan" sh "$TEST_MONITOR"
[ "$(cat "$VAR_RUN/wan_transport_secondwan" 2>/dev/null)" = "down" ] || fail "Test 8 failed: secondwan transport not marked down"

# Test 9: GL.iNet kmwan member detection in validator.uc and route.uc badwan_monitoring auto_detect_interface=false
if command -v ucode >/dev/null 2>&1; then
    printf "kmwan.wan=member\nkmwan.wan.disabled='0'\nkmwan.secondwan=member\nkmwan.secondwan.disabled='0'\n" | \
        ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc" mwan3-has-enabled-interface || \
        fail "Test 9a failed: kmwan active member must be recognized by mwan3-has-enabled-interface"

    printf "kmwan.wan=member\nkmwan.wan.disabled='1'\n" | \
        ucode -L "$ROOT_DIR/tachyon/files/usr/lib" "$ROOT_DIR/tachyon/files/usr/lib/config/validator.uc" mwan3-has-enabled-interface && \
        fail "Test 9b failed: disabled kmwan member must not be treated as active"

    ucode -L "$ROOT_DIR/tachyon/files/usr/lib" -e '
        let route = require("tachyon_core.route");
        let cfg = route.config({ enable_badwan_interface_monitoring: "1" }, { mwan3_active: false });
        if (cfg.auto_detect_interface !== false)
            exit(1);
        let cfg2 = route.config({ wan_failover_enabled: "1" }, { mwan3_active: false });
        if (cfg2.auto_detect_interface !== false)
            exit(1);
    ' || fail "Test 9c failed: enable_badwan_interface_monitoring=1 or wan_failover_enabled=1 must disable auto_detect_interface"

    # Test 10: generator_routes.uc emits default_interface_address and interface_address matchers
    ucode -L "$ROOT_DIR/tachyon/files/usr/lib" -e '
        let gen = require("tachyon_core.generator_routes");
        let sec = {
            ".name": "backup_wan_rule",
            ".type": "section",
            enabled: "1",
            action: "connection",
            default_interface_address: [ "192.168.1.0/24", "10.0.0.0/8" ],
            interface_address: [ "eth1=192.168.1.0/24", "wan2:100.64.0.0/10" ],
            preferred_by: [ "wan2" ]
        };
        let rule = {};
        if (!gen.add_interface_address_matchers(rule, sec))
            exit(1);
        if (type(rule.default_interface_address) != "array" || length(rule.default_interface_address) != 2 || rule.default_interface_address[0] != "192.168.1.0/24")
            exit(2);
        if (type(rule.interface_address) != "object" || type(rule.interface_address.eth1) != "array" || rule.interface_address.eth1[0] != "192.168.1.0/24")
            exit(3);
        if (type(rule.interface_address.wan2) != "array" || rule.interface_address.wan2[0] != "100.64.0.0/10")
            exit(4);
        if (rule.preferred_by != "wan2")
            exit(5);
    ' || fail "Test 10 failed: generator_routes.uc must emit default_interface_address, interface_address, and preferred_by"

    # Test 11: validator.uc accepts valid default_interface_address / interface_address and rejects invalid ones
    ucode -L "$ROOT_DIR/tachyon/files/usr/lib" -e '
        let core_ip = require("core.ip");
        if (!core_ip.valid_ip_or_cidr("192.168.1.0/24"))
            exit(1);
        if (core_ip.valid_ip_or_cidr("not-an-ip"))
            exit(2);
    ' || fail "Test 11 failed: CIDR validation check failed"
fi

printf 'All 10 WAN monitor, failover, and interface matcher tests PASSED!\n'
