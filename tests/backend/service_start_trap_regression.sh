#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
CLI_UC="$PODKOP_BIN"
LIFECYCLE_UC="$ROOT_DIR/podkop/files/usr/lib/service/lifecycle.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_pattern() {
  local pattern="$1"
  local label="$2"

  grep -Fq "$pattern" "$LIFECYCLE_UC" || fail "$label"
}

reject_pattern() {
  local pattern="$1"
  local label="$2"

  ! grep -Fq "$pattern" "$PODKOP_BIN" || fail "$label"
}

[ -r "$PODKOP_BIN" ] || fail "podkop binary source is missing"
[ -r "$PODKOP_BIN" ] || fail "podkop entrypoint is missing"
[ -r "$LIFECYCLE_UC" ] || fail "service/lifecycle.uc is missing"

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "podkop entrypoint must be a direct ucode executable"
grep -Fq 'service/lifecycle.uc' "$CLI_UC" ||
  fail "service/cli.uc must dispatch startup through service/lifecycle.uc"
reject_pattern "trap " \
  "podkop shell entrypoint must not own startup fail-safe traps"
reject_pattern "clear_startup_failsafe_trap" \
  "podkop shell entrypoint must not keep old trap helper"
require_pattern 'module_background(UPDATES_UC, [ "list-update" ])' \
  "startup list_update background job must be owned by service/lifecycle.uc"
require_pattern 'module_background(DIAGNOSTICS_UC, [ "get-system-info" ])' \
  "startup system-info background job must be owned by service/lifecycle.uc"
require_pattern "tproxy-marking-rule-present" \
  "service stop must use direct ucode tproxy marking rule check"
require_pattern "tproxy-route-present" \
  "service stop must use direct ucode tproxy route check"
grep -Fq 'require("core.uci")' "$LIFECYCLE_UC" ||
  fail "service/lifecycle.uc must use core.uci for lifecycle UCI state"
if grep -n -E 'uci -q|require\("uci"\)\.cursor|function uci_|uci_set\(' "$LIFECYCLE_UC" >/dev/null 2>&1; then
  fail "service/lifecycle.uc must not own direct UCI CLI/cursor helpers"
fi
reject_pattern "tproxy_marking_rule_present" \
  "service stop must not call the removed shell tproxy marking helper"
reject_pattern "tproxy_route_present" \
  "service stop must not call the removed shell tproxy route helper"
reject_pattern "has_tproxy_marking_rule" \
  "service stop must not call the removed shell tproxy marking helper"
reject_pattern "has_tproxy_route" \
  "service stop must not call the removed shell tproxy route helper"

printf 'service start trap regression checks passed\n'
