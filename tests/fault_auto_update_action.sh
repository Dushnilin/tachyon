#!/usr/bin/env bash
# FAULT: component auto-update dispatched action "update", which failed with "Unknown component action".
#
# At 04:00 AM, component_auto_update_apply discovered an update:
#   [auto-update] Initiating automatic update for tachyon to version 1.4.4
#   [error] Updates: Unknown component action
#
# trigger_component_auto_update() in components/updates.uc passed action "update"
# to component_action_async_job(). But components/action.uc dispatches component
# updates solely via action "install" (as used everywhere in WebUI and Telegram).
# No component in action.uc accepted "update", so every scheduled or immediate
# auto-update fell through to action_fail("Unknown component action").
#
# tests/component_auto_update.sh could not have caught this, but not for the
# reason its fixture suggests. Narrowing that mock to `if (action == "install")`
# so it matches the real dispatch table was tried here and the test still passed
# against the unfixed source: it only asserts that a background job state file
# appeared, and launch_component_worker() runs the dispatcher asynchronously, so
# the "Unknown component action" failure lands after every assertion has run. The
# mock does diverge from the real action.uc; that just was not what hid it. This
# test reads the production files instead, which is why it can see the contract
# at all.
#
# This test asserts directly against the production source files:
# 1. updates.uc must invoke component_action_async_job with "install"
# 2. action.uc must normalize action "update" to "install"
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
UPDATES_UC="$LIB_DIR/components/updates.uc"
ACTION_UC="$LIB_DIR/components/action.uc"

[ -f "$UPDATES_UC" ] || fail "components/updates.uc not found"
[ -f "$ACTION_UC" ] || fail "components/action.uc not found"

# 1. trigger_component_auto_update must pass "install" to component_action_async_job
auto_update_func="$(sed -n '/function trigger_component_auto_update/,/^}/p' "$UPDATES_UC")"
[ -n "$auto_update_func" ] || fail "could not locate trigger_component_auto_update in updates.uc"

if printf '%s\n' "$auto_update_func" | grep -q 'component_action_async_job(component, "update")'; then
  fail "trigger_component_auto_update still passes 'update' instead of 'install'"
fi

printf '%s\n' "$auto_update_func" | grep -q 'component_action_async_job(component, "install")' ||
  fail "trigger_component_auto_update must pass 'install' to component_action_async_job"

# 2. action.uc component_action must map "update" to "install"
comp_action_func="$(sed -n '/function component_action(component, action/,/acquire_component_lock/p' "$ACTION_UC")"
[ -n "$comp_action_func" ] || fail "could not locate component_action preamble in action.uc"

printf '%s\n' "$comp_action_func" | grep -q 'if (action == "update")' ||
  fail "component_action in action.uc must handle 'update' action"

printf '%s\n' "$comp_action_func" | grep -q 'action = "install"' ||
  fail "component_action in action.uc must normalize 'update' to 'install'"

printf 'fault: auto-update action dispatch checks passed\n'
