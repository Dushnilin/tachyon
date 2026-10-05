#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# The Updates tab offers Remove for the steer variants, but the action
# dispatcher had no branch for it: components/action.uc handled steer
# check_update/install and then fell through to action_fail("Unknown component
# action"), which is exactly what the UI showed. Removal is also not
# remove_optional_component's shape - steer ships as a core plus feature modules
# and there is no providers/steer/runtime.uc to verify leftovers against.

ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
TACHYON_LIB_DIR="$ROOT_DIR/tachyon/files/usr/lib"

UCI_STATE="$WORK_DIR/uci_state"
export TACHYON_UCI_STATE_FILE="$UCI_STATE"
# component_action takes a directory lock under RUNTIME_STATE_DIR. The suite
# runs in parallel, so without this the test would fight every other test for
# the real /var/run/tachyon lock and answer "Another component action is
# already running".
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime"
printf 'tachyon.settings=settings\ntachyon.settings.engine=sing-box\n' >"$UCI_STATE"

# -- dispatcher contract ------------------------------------------------------
# No steer packages are installed in the test container, so a routed remove has
# to report "already removed" instead of falling through to the unknown-action
# branch. Both the stock and the extended spelling have to be routed: they are
# one binary with two builds, but two components in the UI.
assert_removable() {
  local label="$1"
  local component="$2"
  local output

  if ! output="$(ucode -L "$TACHYON_LIB_DIR" "$ACTION_UC" component-action "$component" remove 2>&1)"; then
    fail "$label: remove must not be rejected as an unknown action, got: $output"
  fi

  if grep -Fq 'Unknown component action' <<<"$output"; then
    fail "$label: remove still falls through to the unknown-action branch"
  fi

  grep -Fq '"success": true' <<<"$output" ||
    fail "$label: remove must report success, got: $output"
  grep -Fq 'already removed' <<<"$output" ||
    fail "$label: remove must report the component as already removed, got: $output"
}

assert_removable "steer remove" "steer"
assert_removable "steer-extended remove" "steer-extended"

# -- the running engine must not be pulled out from under tachyon --------------
printf 'tachyon.settings.settings\ntachyon.settings.engine=steer-extended\n' >"$UCI_STATE"
output="$(ucode -L "$TACHYON_LIB_DIR" "$ACTION_UC" component-action steer-extended remove 2>&1 || true)"
grep -Fq 'active engine' <<<"$output" ||
  fail "removing the active steer engine must refuse with an actionable message, got: $output"
grep -Fq 'already removed' <<<"$output" &&
  fail "removing the active engine must not report success, got: $output"

# -- what removal has to cover ------------------------------------------------
# 2.0.0 renames the core from "steer" to "steer-core" and ships every selected
# module as steer-<module>; a router upgraded from 1.x only carries "steer", and
# the pre-2.0 extended build is its own package. Missing any of them leaves the
# engine binary behind and the UI keeps offering an install.
remove_steer="$(sed -n '/^function steer_packages_to_remove/,/^}/p' "$ACTION_UC")"
[ -n "$remove_steer" ] || fail "action.uc must define steer_packages_to_remove"
grep -Fq 'STEER_CORE_PACKAGE' <<<"$remove_steer" ||
  fail "steer removal must consider the steer-core package name"
for legacy in steer-extended '"steer"'; do
  grep -Fq "$legacy" <<<"$remove_steer" ||
    fail "steer removal must consider the legacy $legacy package name"
done
grep -Fq 'steer_module_names()' <<<"$remove_steer" ||
  fail "steer removal must enumerate the steer feature modules"
grep -Eq '"steer-" *\+' <<<"$remove_steer" ||
  fail "steer removal must build module package names as steer-<module>"

# Modules depend on the core, so they have to be removed before it.
module_line="$(grep -n 'steer_module_names()' <<<"$remove_steer" | cut -d: -f1)"
core_line="$(grep -n 'STEER_CORE_PACKAGE' <<<"$remove_steer" | cut -d: -f1)"
[ "$module_line" -lt "$core_line" ] ||
  fail "steer modules must be collected before the core package so removal order is modules-first"

# Removal must go through the package-manager helper that tolerates the
# dependency conflicts steer carries, and must not shell out on its own.
remove_fn="$(sed -n '/^function remove_steer/,/^}/p' "$ACTION_UC")"
grep -Fq 'run_logged_pkg_remove_sing_box_conflict' <<<"$remove_fn" ||
  fail "remove_steer must remove packages via run_logged_pkg_remove_sing_box_conflict"
if grep -Eq '\bsystem\(|sh -c|\bpopen\(' <<<"$remove_fn"; then
  fail "remove_steer must not shell out directly"
fi

# A removal that leaves the binary behind is a failure, not a success.
grep -Fq 'engine.binary_present(component)' <<<"$remove_fn" ||
  fail "remove_steer must verify the engine binary is gone"
grep -Fq 'restart_tachyon_after_successful_change' <<<"$remove_fn" ||
  fail "remove_steer must restart tachyon after a successful removal"

printf 'steer component removal checks passed\n'