#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES_UC="$TACHYON_LIB/components/updates.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

fake_lib="$WORK_DIR/lib"
fake_bin="$WORK_DIR/bin"
cache_dir="$WORK_DIR/cache"
job_dir="$WORK_DIR/jobs"
timestamp_file="$WORK_DIR/component-update-check.timestamp"
last_run_file="$WORK_DIR/component-auto-update.last-run"
clash_dir="$WORK_DIR/clash_api"
clash_json_file="$clash_dir/connections"
mkdir -p \
  "$fake_bin" \
  "$clash_dir" \
  "$fake_lib/core" \
  "$fake_lib/config" \
  "$fake_lib/components" \
  "$fake_lib/service" \
  "$fake_lib/providers/zapret" \
  "$fake_lib/providers/zapret2" \
  "$fake_lib/providers/byedpi" \
  "$fake_lib/providers/wdtt" \
  "$fake_lib/providers/olcrtc" \
  "$fake_lib/providers/fptn" \
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
            component_auto_update_window_start: getenv("TEST_COMPONENT_AUTO_UPDATE_WINDOW_START") || "",
            component_auto_update_window_end: getenv("TEST_COMPONENT_AUTO_UPDATE_WINDOW_END") || "",
            component_auto_update_max_connections: getenv("TEST_COMPONENT_AUTO_UPDATE_MAX_CONNECTIONS") || "0",
            component_auto_update_max_clients: getenv("TEST_COMPONENT_AUTO_UPDATE_MAX_CLIENTS") || "0",
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

if (action == "update" || action == "install") {
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
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/wdtt/runtime.uc"
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/olcrtc/runtime.uc"
cp "$fake_lib/providers/zapret/runtime.uc" "$fake_lib/providers/fptn/runtime.uc"

cat >"$fake_lib/service/state.uc" <<'UCODE'
#!/usr/bin/env ucode
exit(0);
UCODE

cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env sh
last_arg=""
for arg in "$@"; do
  last_arg="$arg"
done
case "$last_arg" in
  file://*)
    path="${last_arg#file://}"
    [ -f "$path" ] && cat "$path" && exit 0
    exit 22
    ;;
esac
exit 7
SH
chmod +x "$fake_bin/curl"

updates_ucode() {
  PATH="$fake_bin:$PATH" \
  TEST_COMPONENT_UPDATE_CHECK_ENABLED="${TEST_COMPONENT_UPDATE_CHECK_ENABLED:-1}" \
    TEST_COMPONENT_UPDATE_CHECK_INTERVAL="${TEST_COMPONENT_UPDATE_CHECK_INTERVAL:-1d}" \
    TEST_COMPONENT_AUTO_UPDATE_ENABLED="${TEST_COMPONENT_AUTO_UPDATE_ENABLED:-0}" \
    TEST_COMPONENT_AUTO_UPDATE_MODE="${TEST_COMPONENT_AUTO_UPDATE_MODE:-immediate}" \
    TEST_COMPONENT_AUTO_UPDATE_TIME="${TEST_COMPONENT_AUTO_UPDATE_TIME:-04:00}" \
    TEST_COMPONENT_AUTO_UPDATE_WINDOW_START="${TEST_COMPONENT_AUTO_UPDATE_WINDOW_START:-}" \
    TEST_COMPONENT_AUTO_UPDATE_WINDOW_END="${TEST_COMPONENT_AUTO_UPDATE_WINDOW_END:-}" \
    TEST_COMPONENT_AUTO_UPDATE_MAX_CONNECTIONS="${TEST_COMPONENT_AUTO_UPDATE_MAX_CONNECTIONS:-0}" \
    TEST_COMPONENT_AUTO_UPDATE_MAX_CLIENTS="${TEST_COMPONENT_AUTO_UPDATE_MAX_CLIENTS:-0}" \
    TEST_COMPONENT_AUTO_UPDATE_TARGETS="${TEST_COMPONENT_AUTO_UPDATE_TARGETS:-all}" \
    TACHYON_LIB="$fake_lib" \
    TACHYON_BIN="/usr/bin/tachyon" \
    TACHYON_SERVICE_INIT="/etc/init.d/tachyon" \
    TACHYON_RUNTIME_STATE_DIR="$WORK_DIR" \
    TACHYON_COMPONENT_UPDATE_CHECK_CACHE_DIR="$cache_dir" \
    TACHYON_COMPONENT_UPDATE_CHECK_STATE_FILE="$timestamp_file" \
    TACHYON_COMPONENT_AUTO_UPDATE_LAST_RUN_FILE="$last_run_file" \
    TACHYON_CLASH_API_URL="${TACHYON_CLASH_API_URL:-file://$clash_dir}" \
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
rm -rf "${job_dir:?}"/*
TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=schedule \
  TEST_COMPONENT_AUTO_UPDATE_TIME="04:00" \
  updates_ucode component-auto-update-apply force

sleep 1
job_files=( "$job_dir"/*.json )
[ -f "${job_files[0]}" ] || fail "scheduled auto-update should create background job state"

# 2a. A window that does not contain the current time must block the run
rm -rf "${job_dir:?}"/*
WIN_START=$(date -d '+3 hours' +%H:%M)
WIN_END=$(date -d '+4 hours' +%H:%M)
TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=schedule \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_START="$WIN_START" \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_END="$WIN_END" \
  updates_ucode component-auto-update-apply

sleep 1
job_files=( "$job_dir"/*.json )
if [ -f "${job_files[0]}" ]; then
  fail "scheduled auto-update must not run outside the configured window"
fi

# 2b. High active load defers inside an open 24h window without writing last-run marker
rm -rf "${job_dir:?}"/* "$last_run_file"
cat >"$clash_json_file" <<'JSON'
{
  "connections": [
    { "metadata": { "sourceIP": "192.168.1.10" } },
    { "metadata": { "sourceIP": "192.168.1.20" } },
    { "metadata": { "sourceIP": "127.0.0.1" } }
  ]
}
JSON

TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=schedule \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_START="00:00" \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_END="00:00" \
  TEST_COMPONENT_AUTO_UPDATE_MAX_CLIENTS=1 \
  updates_ucode component-auto-update-apply

sleep 1
job_files=( "$job_dir"/*.json )
if [ -f "${job_files[0]}" ]; then
  fail "scheduled auto-update must defer when active LAN clients exceed threshold"
fi
if [ -f "$last_run_file" ]; then
  fail "deferred auto-update must not record the daily completion marker"
fi

# 2c. Loopback-only traffic is ignored for client count; once allowed, run once per window
cat >"$clash_json_file" <<'JSON'
{
  "connections": [
    { "metadata": { "sourceIP": "192.168.1.10" } },
    { "metadata": { "sourceIP": "127.0.0.1" } },
    { "metadata": { "sourceIP": "::1" } }
  ]
}
JSON

TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=schedule \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_START="00:00" \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_END="00:00" \
  TEST_COMPONENT_AUTO_UPDATE_MAX_CLIENTS=1 \
  updates_ucode component-auto-update-apply

sleep 1
job_files=( "$job_dir"/*.json )
[ -f "${job_files[0]}" ] || fail "scheduled auto-update should run once LAN client count fits threshold"
[ -f "$last_run_file" ] || fail "scheduled auto-update should record the daily window marker"

# Second tick in the same window must skip immediately due to the marker
rm -rf "${job_dir:?}"/*
cat >"$cache_dir/tachyon.json" <<'JSON'
{"success":true,"component":"tachyon","action":"check_update","current_version":"1.0.0","latest_version":"1.1.0","status":"outdated","updated_at":4102444800}
JSON
TEST_COMPONENT_AUTO_UPDATE_ENABLED=1 \
  TEST_COMPONENT_AUTO_UPDATE_MODE=schedule \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_START="00:00" \
  TEST_COMPONENT_AUTO_UPDATE_WINDOW_END="00:00" \
  TEST_COMPONENT_AUTO_UPDATE_MAX_CLIENTS=1 \
  updates_ucode component-auto-update-apply

sleep 1
job_files=( "$job_dir"/*.json )
if [ -f "${job_files[0]}" ]; then
  fail "scheduled auto-update must not run twice in the same window"
fi

printf 'component auto update test passed\n'
