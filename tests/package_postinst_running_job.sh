#!/usr/bin/env bash
set -eo pipefail

# A Tachyon self-update is itself a component job: the job installs the package
# whose postinst runs remove_component_update_cache(). That cleanup used to wipe
# the whole component-actions directory, deleting the state file of the very job
# that was still running. LuCI then polled a job that no longer existed, got
# neither a message nor stderr, and rendered its "Failed to execute" fallback
# over an update that had actually succeeded.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
PACKAGE_UC="$TACHYON_LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

STATE_DIR="$WORK_DIR/run/tachyon"
ACTION_DIR="$STATE_DIR/component-actions"
CHECK_DIR="$STATE_DIR/component-update-checks"
mkdir -p "$ACTION_DIR" "$CHECK_DIR"

RUNNING_JOB="$ACTION_DIR/1786306166-287510904.json"
FINISHED_JOB="$ACTION_DIR/1786306100-111111111.json"
STALE_CHECK="$CHECK_DIR/tachyon.json"
TIMESTAMP="$STATE_DIR/component-update-check.timestamp"

printf '%s\n' '{ "success": true, "running": true, "kind": "component", "component": "tachyon", "action": "install", "message": "Component action is running", "started_at": 1786306166 }' >"$RUNNING_JOB"
printf '%s\n' '{ "success": true, "running": false, "kind": "component", "component": "sing_box", "action": "check_update", "message": "Latest version is installed" }' >"$FINISHED_JOB"
printf '%s\n' '{ "component": "tachyon", "status": "latest" }' >"$STALE_CHECK"
printf '%s\n' '1786306166' >"$TIMESTAMP"

TACHYON_PACKAGE_TEST_MODE=1 \
TACHYON_RUNTIME_STATE_DIR="$STATE_DIR" \
TACHYON_UI_COMPONENT_ACTION_DIR="$ACTION_DIR" \
TACHYON_COMPONENT_UPDATE_CHECK_CACHE_DIR="$CHECK_DIR" \
TACHYON_COMPONENT_UPDATE_CHECK_STATE_FILE="$TIMESTAMP" \
TACHYON_COMPONENT_ACTION_LOCK="$STATE_DIR/component-action.lock" \
TACHYON_CONFIG_NAME=tachyon-package-job-test \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" luci-postinst >/dev/null 2>&1 ||
  fail "luci-postinst must succeed in test mode"

# The whole point: the in-flight job survives so its worker can write the result.
[ -f "$RUNNING_JOB" ] ||
  fail "postinst deleted the state file of a running component job; the UI then reports 'Failed to execute' over a successful update"

# Finished results are genuinely stale and must still be cleared.
[ ! -f "$FINISHED_JOB" ] ||
  fail "postinst must still remove finished component job results"
[ ! -f "$STALE_CHECK" ] ||
  fail "postinst must still clear the component update check cache"
[ ! -f "$TIMESTAMP" ] ||
  fail "postinst must still clear the component update check timestamp"

# Structural: no unconditional wipe of the job directory may come back.
sweep="$(sed -n '/^function remove_component_update_cache/,/^}/p' "$PACKAGE_UC" | sed 's://.*::')"
[ -n "$sweep" ] || fail "service/package.uc must define remove_component_update_cache"
grep -Fq 'component_job_is_running' <<<"$sweep" ||
  fail "remove_component_update_cache must skip jobs that are still running"

printf 'package postinst running-job checks passed\n'
