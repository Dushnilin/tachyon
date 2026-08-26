#!/usr/bin/env bash
# Auto-failover: generator emits the tachyon-failover selector group only when
# enabled; the failover module switches to a healthy section after N failures
# (Clash API stubbed).
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
FAILOVER_UC="$TACHYON_LIB/service/failover.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate_config() {
  local fixture="$1" output="$2"
  mkdir -p "${output}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

make_fixture() {
  local enabled_flag="$1" out="$2"
  cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "section_failover_enabled": "$enabled_flag",
    "section_failover_threshold": "2"
  },
  "section": [
    {
      ".name": "main_sec", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"A\",\"server\":\"a.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}" ]
    },
    {
      ".name": "backup_sec", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"B\",\"server\":\"b.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000002\",\"tls\":{\"enabled\":true}}" ]
    }
  ]
}
JSON
}

# --- generator: disabled (default) -> no failover group ---------------------
make_fixture 0 "$WORK_DIR/off.json"
generate_config "$WORK_DIR/off.json" "$WORK_DIR/off.out"
grep -Fq 'tachyon-failover' "$WORK_DIR/off.out" &&
  fail "disabled failover must not emit the group"

# catch-all still targets the first section outbound
grep -Fq '"outbound": "main_sec-out"' "$WORK_DIR/off.out" ||
  fail "disabled failover must keep the direct catch-all route"

# --- generator: enabled -> group with both members, persisted default -------
make_fixture 1 "$WORK_DIR/on.json"
generate_config "$WORK_DIR/on.json" "$WORK_DIR/on.out"
grep -Fq '"tag": "tachyon-failover"' "$WORK_DIR/on.out" ||
  fail "enabled failover must emit the selector group"
grep -Fq '"main_sec-out"' "$WORK_DIR/on.out" && grep -Fq '"backup_sec-out"' "$WORK_DIR/on.out" ||
  fail "group must contain both section outbounds"
grep -Fq '"default": "main_sec-out"' "$WORK_DIR/on.out" ||
  fail "group default must be the first candidate"

printf '%s' 'backup_sec' >"$WORK_DIR/state"
TACHYON_FAILOVER_STATE_FILE="$WORK_DIR/state" \
  generate_config "$WORK_DIR/on.json" "$WORK_DIR/on_persisted.out"
grep -Fq '"default": "backup_sec-out"' "$WORK_DIR/on_persisted.out" ||
  fail "persisted choice must become the group default"

# stale persisted name falls back to the first candidate
printf '%s' 'gone_sec' >"$WORK_DIR/stale"
TACHYON_FAILOVER_STATE_FILE="$WORK_DIR/stale" \
  generate_config "$WORK_DIR/on.json" "$WORK_DIR/on_stale.out"
grep -Fq '"default": "main_sec-out"' "$WORK_DIR/on_stale.out" ||
  fail "stale persisted section must fall back to first candidate"

# --- switcher logic with stubbed Clash API ---------------------------------
STUB_BIN="$WORK_DIR/bin"
mkdir -p "$STUB_BIN"
FAIL_LOG="$WORK_DIR/clash.log"

cat >"$STUB_BIN/tachyon" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$FAIL_LOG'
case "\$*" in
  *"get_proxy_latency main_sec-out"*)
    if [ "\$MAIN_DEAD" = "1" ]; then echo '{}'; else echo '{"delay":120}'; fi ;;
  *"get_proxy_latency backup_sec-out"*) echo '{"delay":200}' ;;
  *"get_proxy_latency gone_sec-out"*) echo '{}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_BIN/tachyon"

export PATH="$STUB_BIN:$PATH"
export TACHYON_CONFIG_NAME="tachyon"
export TACHYON_BIN="$STUB_BIN/tachyon"
export TACHYON_FAILOVER_STATE_FILE="$WORK_DIR/state"
export TACHYON_FAILOVER_STREAK_FILE="$WORK_DIR/streak"

# --- switcher logic with stubbed Clash API ---------------------------------
STUB_BIN="$WORK_DIR/bin"
mkdir -p "$STUB_BIN"
FAIL_LOG="$WORK_DIR/clash.log"

cat >"$STUB_BIN/tachyon" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$FAIL_LOG'
case "\$*" in
  *"get_proxy_latency main_sec-out"*)
    if [ "\${MAIN_DEAD:-0}" = "1" ]; then echo '{}'; else echo '{"delay":120}'; fi ;;
  *"get_proxy_latency backup_sec-out"*) echo '{"delay":200}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_BIN/tachyon"

export PATH="$STUB_BIN:$PATH"
export TACHYON_CONFIG_NAME="tachyon"
export TACHYON_BIN="$STUB_BIN/tachyon"
export TACHYON_FAILOVER_STATE_FILE="$WORK_DIR/state"
export TACHYON_FAILOVER_STREAK_FILE="$WORK_DIR/streak"

make_state() {
  printf '%s\n' \
    "tachyon.settings=settings" \
    "tachyon.settings.section_failover_enabled=$1" \
    "tachyon.settings.section_failover_threshold=2" \
    "tachyon.main_sec=section" "tachyon.main_sec.enabled=1" "tachyon.main_sec.action=connection" \
    "tachyon.backup_sec=section" "tachyon.backup_sec.enabled=1" "tachyon.backup_sec.action=connection" \
    "tachyon.telegram=telegram" "tachyon.telegram.enabled=1" "tachyon.telegram.bot_token=x" "tachyon.telegram.admin_ids=1" \
    >"$WORK_DIR/uci.state"
  printf '%s' 'main_sec' >"$WORK_DIR/state"
  rm -f "$WORK_DIR/streak"
}

run_check() {
  UCI_STATE="$WORK_DIR/uci.state" ucode -L "$TACHYON_LIB" "$FAILOVER_UC" check
}

# disabled -> no-op even with dead primary
make_state 0
MAIN_DEAD=1 run_check || fail "check must not fail when disabled"
[ ! -s "$WORK_DIR/streak" ] || fail "disabled check must not track streaks"

# enabled, healthy primary -> no switch
make_state 1
run_check || fail "healthy check failed"
[ "$(cat "$WORK_DIR/state")" = "main_sec" ] || fail "healthy primary must stay active"

# primary dies twice (threshold=2) -> switch to backup + persist
export MAIN_DEAD=1
run_check; run_check || fail "switch path errored"
[ "$(cat "$WORK_DIR/state")" = "backup_sec" ] ||
  fail "must switch to backup after threshold, state=$(cat "$WORK_DIR/state")"
grep -Fq "set_group_proxy tachyon-failover backup_sec-out" "$FAIL_LOG" ||
  fail "runtime switch via Clash API missing"
grep -Fq "telegram send" "$FAIL_LOG" ||
  fail "telegram notification missing"

# recovery of streak file on success
unset MAIN_DEAD
run_check
[ "$(cat "$WORK_DIR/streak")" = "0" ] || fail "success must reset the streak counter"

printf 'auto-failover checks passed\n'
