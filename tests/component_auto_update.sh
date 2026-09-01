#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
UPDATES_UC="$TACHYON_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

fake_lib="$WORK_DIR/lib"
cache_dir="$WORK_DIR/cache"
job_dir="$WORK_DIR/jobs"
timestamp_file="$WORK_DIR/component-update-check.timestamp"
mkdir -p \
  "$fake_lib/core" \
  "$fake_lib/config" \
  "$fake_lib/components" \
  "$fake_lib/service" \
  "$fake_lib/providers/zapret" \
  "$fake_lib/providers/zapret2" \
  "$fake_lib/providers/byedpi" \
  "$job_dir" \
  "$cache_dir"

cat >"$fake_lib/core/uci.uc" <<'UCODE'
function get_all(_config, section) {
    if (section == "settings") {
        return {
            component_update_check_enabled: getenv("TEST_COMPONENT_UPDATE_CHECK_ENABLED") || "1",
            component_update_check_interval: getenv("TEST_COMPONENT_UPDATE_CHECK_INTERVAL") || "1d",
            component_auto_update_enabled: getenv("TEST_COMPONENT_AUTO_UPDATE_ENABLED") || "0",
            component_auto_update_mode: getenv("TEST_COMPONENT_AUTO_UPDATE_MODE") || "immediate",
            component_auto_update_time: getenv("TEST_COMPONENT_AUTO_UPDATE_TIME") || "04:00",
            component_auto_update_targets: getenv("TEST_COMPONENT_AUTO_UPDATE_TARGETS") ? split(getenv("TEST_COMPONENT_AUTO_UPDATE_TARGETS"), " ") : [ "all" ]
        };
    }
    return {};
}

function section_objects(_config, _type) {
    return [];
}

return {
    get_all,
    section_objects
};
UCODE

cat >"$fake_lib/config/connections.uc" <<'UCODE'
return {};
UCODE

cat >"$fake_lib/components/action.uc" <<'UCODE'
#!/usr/bin/env ucode
let component = ARGV[1] || "tachyon";
let action = ARGV[2] || "check_update";
if (action == "check_update") {
    let result = {
        success: true,
        component,
        action,
        message: "Update is available",
        current_version: "1.0.0",
        latest_version: "1.1.0",
        release_url: "https://example.com/release",
        changed: 0,
        status: "outdated"
    };
    print(sprintf("%J\n", result));
    exit(0);
}

if (action == "update") {
    let result = {
        success: true,
        component,
        action,
        message: "Updated successfully",
        current_version: "1.1.0",
        latest_version: "1.1.0",
        changed: 1,
        status: "latest"
    };
    print(sprintf("%J\n", result));
    exit(0);
}
UCODE

cat >"$fake_lib/providers/zapret/runtime.uc" <<'UCODE'
#!/usr/bin/env ucode
exit(1);
UCODE
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/zapret2/runtime.uc"
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/byedpi/runtime.uc"

cat >"$fake_lib/service/state.uc" <<'UCODE'
#!/usr/bin/env ucode
exit(0);
UCODE

updates_ucode() {
  TEST_COMPONENT_UPDATE_CHECK_ENABLED="${TEST_COMPONENT_UPDATE_CHECK_ENABLED:-1}" \
    TEST_COMPONENT_UPDATE_CHECK_INTERVAL="${TEST_COMPONENT_UPDATE_CHECK_INTERVAL:-1d}" \
    TEST_COMPONENT_AUTO_UPDATE_ENABLED="${TEST_COMPONENT_AUTO_UPDATE_ENABLED:-0}" \
    TEST_COMPONENT_AUTO_UPDATE_MODE="${TEST_COMPONENT_AUTO_UPDATE_MODE:-immediate}" \
    TEST_COMPONENT_AUTO_UPDATE_TIME="${TEST_COMPONENT_AUTO_UPDATE_TIME:-04:00}" \
    TEST_COMPONENT_AUTO_UPDATE_TARGETS="${TEST_COMPONENT_AUTO_UPDATE_TARGETS:-all}" \
    TACHYON_LIB="$fake_lib" \
    TACHYON_BIN="/usr/bin/tachyon" \
    TACHYON_SERVICE_INIT="/etc/init.d/tachyon" \
    TACHYON_COMPONENT_UPDATE_CHECK_CACHE_DIR="$cache_dir" \
    TACHYON_COMPONENT_UPDATE_CHECK_STATE_FILE="$timestamp_file" \
    UPDATES_JOB_DIR="$job_dir" \
    ucode -L "$fake_lib" -L "$TACHYON_LIB" "$UPDATES_UC" "$@"
}

# 1. Test immediate auto-update trigger on check if outdated
TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=immediate \
  updates_ucode component-updates-if-due

# Verify update check cache was populated
[ -f "$cache_dir/tachyon.json" ] || fail "component update check cache missing"

# Verify that auto-update spawned a background job in job_dir
sleep 1
job_files=( "$job_dir"/*.json )
[ -f "${job_files[0]}" ] || fail "auto-update should create background job state"

# 2. Test scheduled apply
rm -rf "$job_dir"/*
TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=schedule \
  TEST_COMPONENT_AUTO_UPDATE_TIME="04:00" \
  updates_ucode component-auto-update-apply

sleep 1
job_files=( "$job_dir"/*.json )
[ -f "${job_files[0]}" ] || fail "scheduled auto-update should create background job state"

printf 'component auto update test passed\n'
