#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
CLI_UC="$TACHYON_BIN"
TACHYON_MAKEFILE="$ROOT_DIR/tachyon/Makefile"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
CONSTANTS_SH="$TACHYON_LIB/constants.sh"
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
CONSTANTS_UC="$TACHYON_LIB/core/constants.uc"
SINGBOX_CONSTANTS_UC="$TACHYON_LIB/singbox/constants.uc"
FRONTEND_CONSTANTS="$ROOT_DIR/fe-app-tachyon/src/constants.ts"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$CONSTANTS_SH" ] ||
  fail "constants.sh shell owner must be removed"

grep -Fq '#!/usr/bin/ucode' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'core.constants' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must load constants from core/constants.uc"

if grep -R -n -E 'constants\.sh|read_shell_constants|expand_shell_constants|unquote_shell_value' \
  "$TACHYON_BIN" "$TACHYON_LIB" --include='*.sh' --include='*.uc' >/dev/null 2>&1; then
  fail "shell constants owner or parser references must not remain"
fi

if grep -n 'constants\.sh' "$TACHYON_MAKEFILE" "$BUILD_SCRIPT" >/dev/null 2>&1; then
  fail "package build must not patch removed constants.sh"
fi
grep -Fq 'core/constants.uc' "$TACHYON_MAKEFILE" ||
  fail "tachyon/Makefile must patch core/constants.uc"
grep -Fq 'core/constants.uc' "$BUILD_SCRIPT" ||
  fail "manual WSL build must patch core/constants.uc"

config_name="$(ucode -L "$TACHYON_LIB" "$CONSTANTS_UC" get TACHYON_CONFIG_NAME)"
[ "$config_name" = "tachyon" ] ||
  fail "core/constants.uc get returned unexpected TACHYON_CONFIG_NAME"

eval "$(ucode -L "$TACHYON_LIB" "$CONSTANTS_UC" shell-env)"
[ "$TACHYON_CONFIG" = "/etc/config/tachyon" ] ||
  fail "core/constants.uc shell-env did not derive TACHYON_CONFIG"
[ "$TMP_RULESET_FOLDER" = "/tmp/sing-box/rulesets" ] ||
  fail "core/constants.uc shell-env did not derive TMP_RULESET_FOLDER"
[ "$BYEDPI_PID_DIR" = "/var/run/tachyon/byedpi/pid" ] ||
  fail "core/constants.uc shell-env did not derive BYEDPI_PID_DIR"

[ "$(ucode -L "$TACHYON_LIB" "$CONSTANTS_UC" get FAKEIP_TEST_DOMAIN)" = "fakeip.podkop.fyi" ] ||
  fail "FakeIP diagnostics must use the deployed public endpoint"
[ "$(ucode -L "$TACHYON_LIB" "$CONSTANTS_UC" get CHECK_PROXY_IP_DOMAIN)" = "ip.podkop.fyi" ] ||
  fail "public IP diagnostics must use the deployed public endpoint"
grep -Fq 'const FAKEIP_TEST_DOMAIN = "fakeip.podkop.fyi";' "$SINGBOX_CONSTANTS_UC" ||
  fail "sing-box constants must match the deployed FakeIP endpoint"
grep -Fq "export const FAKEIP_CHECK_DOMAIN = 'fakeip.podkop.fyi';" "$FRONTEND_CONSTANTS" ||
  fail "LuCI diagnostics must use the deployed FakeIP endpoint"
grep -Fq "export const IP_CHECK_DOMAIN = 'ip.podkop.fyi';" "$FRONTEND_CONSTANTS" ||
  fail "LuCI diagnostics must use the deployed public IP endpoint"

printf 'constants ownership checks passed\n'
