#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PODKOP_FILES="$ROOT_DIR/podkop/files"
PODKOP_BIN="$PODKOP_FILES/usr/bin/podkop"
PODKOP_LIB="$PODKOP_FILES/usr/lib"
CLI_UC="$PODKOP_BIN"
VALIDATOR="$PODKOP_LIB/config/validator.uc"
LIFECYCLE="$PODKOP_LIB/service/lifecycle.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$PODKOP_LIB/config_validation.sh" ] ||
  fail "config_validation.sh shell owner must be removed"

if grep -R -n "config_validation.sh" "$PODKOP_FILES" >/dev/null 2>&1; then
  fail "runtime files must not reference config_validation.sh"
fi

legacy_symbols='(^|[^A-Za-z0-9_])(config_validate_runtime|check_requirements|commit_podkop_config|mwan3_is_active|get_inline_remote_ruleset_format|detect_inline_ruleset_reference_kind)([^A-Za-z0-9_]|$)'
if grep -R -n -E "$legacy_symbols" "$PODKOP_BIN" "$PODKOP_LIB" --include='*.sh' >/dev/null 2>&1; then
  fail "runtime shell must not keep config_validation.sh symbols"
fi

grep -Fq 'mode == "check-requirements"' "$VALIDATOR" ||
  fail "config validator must own requirement checks"
grep -Fq 'mode == "mwan3-is-active"' "$VALIDATOR" ||
  fail "config validator must own mwan3 runtime predicate"
grep -Fq 'require("core.uci")' "$VALIDATOR" ||
  fail "config validator must use core.uci for runtime UCI access"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"|command_output\("uci' "$VALIDATOR" >/dev/null 2>&1; then
  fail "config validator must not own direct UCI cursor or CLI access"
fi
grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch service lifecycle through service/lifecycle.uc"
grep -Fq 'MIGRATION_UC' "$LIFECYCLE" &&
grep -Fq '"migrate"' "$LIFECYCLE" ||
  fail "service/lifecycle.uc must run config migration directly through ucode"
grep -Fq 'VALIDATOR_UC' "$LIFECYCLE" &&
grep -Fq '"validate-runtime"' "$LIFECYCLE" ||
  fail "service/lifecycle.uc must run runtime validation directly through ucode"

printf 'config validation ownership checks passed\n'
