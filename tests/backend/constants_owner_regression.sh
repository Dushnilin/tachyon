#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
CLI_UC="$PODKOP_BIN"
PODKOP_MAKEFILE="$ROOT_DIR/podkop/Makefile"
BUILD_SCRIPT="$ROOT_DIR/scripts/build.sh"
CONSTANTS_SH="$PODKOP_LIB/constants.sh"
LIFECYCLE_UC="$PODKOP_LIB/service/lifecycle.uc"
CONSTANTS_UC="$PODKOP_LIB/core/constants.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$CONSTANTS_SH" ] ||
  fail "constants.sh shell owner must be removed"

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch lifecycle orchestration through service/lifecycle.uc"
grep -Fq 'core.constants' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must load constants from core/constants.uc"

if grep -R -n -E 'constants\.sh|read_shell_constants|expand_shell_constants|unquote_shell_value' \
  "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' --include='*.uc' >/dev/null 2>&1; then
  fail "shell constants owner or parser references must not remain"
fi

if grep -n 'constants\.sh' "$PODKOP_MAKEFILE" "$BUILD_SCRIPT" >/dev/null 2>&1; then
  fail "package build must not patch removed constants.sh"
fi
grep -Fq 'core/constants.uc' "$PODKOP_MAKEFILE" ||
  fail "podkop/Makefile must patch core/constants.uc"
grep -Fq 'core/constants.uc' "$BUILD_SCRIPT" ||
  fail "manual WSL build must patch core/constants.uc"

config_name="$(ucode -L "$PODKOP_LIB" "$CONSTANTS_UC" get PODKOP_CONFIG_NAME)"
[ "$config_name" = "podkop-plus" ] ||
  fail "core/constants.uc get returned unexpected PODKOP_CONFIG_NAME"

eval "$(ucode -L "$PODKOP_LIB" "$CONSTANTS_UC" shell-env)"
[ "$PODKOP_CONFIG" = "/etc/config/podkop-plus" ] ||
  fail "core/constants.uc shell-env did not derive PODKOP_CONFIG"
[ "$TMP_RULESET_FOLDER" = "/tmp/sing-box/rulesets" ] ||
  fail "core/constants.uc shell-env did not derive TMP_RULESET_FOLDER"
[ "$BYEDPI_PID_DIR" = "/var/run/podkop-plus/byedpi/pid" ] ||
  fail "core/constants.uc shell-env did not derive BYEDPI_PID_DIR"

printf 'constants ownership regression checks passed\n'
