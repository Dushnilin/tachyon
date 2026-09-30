#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
REAL_LIB="$ROOT_DIR/tachyon/files/usr/lib"

write_stub() {
  local path="$1"
  local body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" >"$path"
}

stub_header='#!/usr/bin/env ucode
let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function record(line) {
    let path = getenv("FAKE_CALL_LOG") || "";
    if (path != "") {
        let f = fs.open(path, "a");
        if (f) {
            f.write(as_string(line) + "\n");
            f.close();
        }
    }
}
'

FAKE_LIB="$WORK_DIR/lib"

write_stub "$FAKE_LIB/service/state.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("service/state:" + mode);
if (mode == "sing-box-service-runtime-pid") {
    print("4567\n");
    exit(0);
}
if (mode == "reload-sing-box-runtime" ||
    mode == "write-current-reload-state-clean")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/runtime.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/runtime:" + mode);
if (mode == "init-config") {
    let mutate = getenv("MUTATE_CONFIG_ON_INIT") || "0";
    let config_path = getenv("FAKE_SINGBOX_CONFIG_PATH") || "";
    if (mutate == "1" && config_path != "") {
        let f = fs.open(config_path, "w");
        if (f) {
            f.write("{\"version\": 2}\n");
            f.close();
        }
    }
    exit(0);
}
exit(64);
'

write_stub "$FAKE_LIB/singbox/priority.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/priority:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/singbox/dns_failover.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/dns_failover:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

CONFIG_PATH="$WORK_DIR/config.json"
echo '{"version": 1}' > "$CONFIG_PATH"

cat > "$WORK_DIR/uci.state" <<EOF
tachyon.settings=settings
tachyon.settings.config_path=$CONFIG_PATH
EOF

run_reload() {
  local mutate="$1"
  local log="$2"

  : >"$log"
  env \
    TACHYON_LIB="$FAKE_LIB" \
    TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    TACHYON_RELOAD_STATE_FILE="$WORK_DIR/run/reload-state" \
    TACHYON_RULE_CONDITION_CACHE_DIR="$WORK_DIR/run/rule-condition-cache" \
    TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    FAKE_CALL_LOG="$log" \
    FAKE_SINGBOX_CONFIG_PATH="$CONFIG_PATH" \
    MUTATE_CONFIG_ON_INIT="$mutate" \
    ucode -L "$REAL_LIB" "$UPDATES_UC" reload-singbox-after-list-update
}

# Test 1: Unchanged config must NOT trigger sing-box reload or stop failover/priority (Issue #54)
UNCHANGED_LOG="$WORK_DIR/unchanged.log"
echo '{"version": 1}' > "$CONFIG_PATH"
run_reload "0" "$UNCHANGED_LOG"

if grep -Eq 'reload-sing-box-runtime|priority:stop-runtime|dns_failover:stop-runtime' "$UNCHANGED_LOG"; then
  fail "reload_singbox_after_list_update must NOT reload sing-box when config is unchanged"
fi

# Test 2: Changed config MUST trigger reload and stop/start priority & failover
CHANGED_LOG="$WORK_DIR/changed.log"
echo '{"version": 1}' > "$CONFIG_PATH"
run_reload "1" "$CHANGED_LOG"

grep -Fq 'service/state:reload-sing-box-runtime' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must reload sing-box when config has changed"

grep -Fq 'singbox/priority:stop-runtime' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must stop priority on reload"

grep -Fq 'singbox/dns_failover:stop-runtime' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must stop dns_failover on reload"

grep -Fq 'service/state:write-current-reload-state-clean' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must write clean reload state"

printf 'list_update_reload_guard tests passed\n'
