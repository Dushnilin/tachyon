#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
VALIDATOR="$LIB_DIR/config/validator.uc"

LOGGER_LOG="$WORK_DIR/logger.log"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<BASH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOGGER_LOG"
BASH
chmod +x "$WORK_DIR/bin/logger"

cat >"$WORK_DIR/context.json" <<'JSON'
{
  "byedpi_installed": true,
  "zapret_installed": true,
  "zapret2_installed": true
}
JSON
context="$(cat "$WORK_DIR/context.json")"

validate_fixture() {
  local fixture="$1"
  TACHYON_LIB="$LIB_DIR" PATH="$WORK_DIR/bin:$PATH" ucode -L "$LIB_DIR" "$VALIDATOR" validate-runtime-fixture "$fixture" "$context"
}

# 1. Provider section (byedpi) with no rules and mixed_proxy_enabled=0 must FAIL validation
cat >"$WORK_DIR/byedpi_no_rules_disabled_proxy.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": [
    {
      ".name": "byedpi_sec",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi",
      "mixed_proxy_enabled": "0"
    }
  ]
}
JSON

: >"$LOGGER_LOG"
if validate_fixture "$WORK_DIR/byedpi_no_rules_disabled_proxy.json" >/dev/null 2>&1; then
  fail "byedpi section with no rules and mixed_proxy_enabled=0 should fail validation"
fi
grep -Fq "has no routing conditions" "$LOGGER_LOG" || fail "expected 'has no routing conditions' in log, got $(cat "$LOGGER_LOG")"

# 2. Provider section (byedpi) with no rules and mixed_proxy_enabled=1 must PASS validation
cat >"$WORK_DIR/byedpi_no_rules_enabled_proxy.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": [
    {
      ".name": "byedpi_sec",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi",
      "mixed_proxy_enabled": "1",
      "mixed_proxy_port": "1080"
    }
  ]
}
JSON

: >"$LOGGER_LOG"
if ! validate_fixture "$WORK_DIR/byedpi_no_rules_enabled_proxy.json" >/dev/null 2>&1; then
  fail "byedpi section with no rules and mixed_proxy_enabled=1 should pass validation, log: $(cat "$LOGGER_LOG")"
fi

# 3. Verify section_is_active_provider recognizes mixed_proxy_enabled
cat >"$WORK_DIR/test_active_provider.uc" <<'UCODE'
let connections = require("config.connections");

let sec_no_proxy = {
    ".name": "test_sec",
    "enabled": "1",
    "action": "byedpi",
    "mixed_proxy_enabled": "0"
};
if (connections.section_is_active_provider(sec_no_proxy, "byedpi"))
    exit(1);

let sec_with_proxy = {
    ".name": "test_sec",
    "enabled": "1",
    "action": "byedpi",
    "mixed_proxy_enabled": "1"
};
if (!connections.section_is_active_provider(sec_with_proxy, "byedpi"))
    exit(2);

print("active provider check OK\n");
UCODE

ucode -L "$LIB_DIR" "$WORK_DIR/test_active_provider.uc"

printf 'mixed_proxy_no_rules: OK\n'
