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
if (mode == "tachyon-core-service-runtime-pid") {
    print("4567\n");
    exit(0);
}
if (mode == "reload-core-runtime" ||
    mode == "write-current-reload-state-clean") {
    if (mode == "reload-core-runtime" && getenv("FAIL_CORE_RELOAD") == "1")
        exit(1);
    exit(0);
}
exit(64);
'

write_stub "$FAKE_LIB/tachyon_core/runtime.uc" "$stub_header"'
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

write_stub "$FAKE_LIB/tachyon_core/priority.uc" "$stub_header"'
let mode = as_string(ARGV[0]);
record("singbox/priority:" + mode);
if (mode == "stop-runtime" || mode == "start-runtime")
    exit(0);
exit(64);
'

write_stub "$FAKE_LIB/tachyon_core/dns_failover.uc" "$stub_header"'
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

if grep -Eq 'reload-core-runtime|priority:stop-runtime|dns_failover:stop-runtime' "$UNCHANGED_LOG"; then
  fail "reload_singbox_after_list_update must NOT reload sing-box when config is unchanged"
fi

# Test 2: Changed config MUST trigger reload and stop/start priority & failover
CHANGED_LOG="$WORK_DIR/changed.log"
echo '{"version": 1}' > "$CONFIG_PATH"
run_reload "1" "$CHANGED_LOG"

grep -Fq 'service/state:reload-core-runtime' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must reload sing-box when config has changed"

grep -Fq 'singbox/priority:stop-runtime' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must stop priority on reload"

grep -Fq 'singbox/dns_failover:stop-runtime' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must stop dns_failover on reload"

grep -Fq 'service/state:write-current-reload-state-clean' "$CHANGED_LOG" ||
  fail "reload_singbox_after_list_update must write clean reload state"

# Test 3: Unchanged config WITH local rule_set MUST trigger reload so core re-reads updated rulesets
LOCAL_RS_LOG="$WORK_DIR/local_rs.log"
cat > "$CONFIG_PATH" <<'EOF'
{
  "route": {
    "rule_set": [
      {
        "type": "local",
        "tag": "hysteria-lists",
        "format": "source",
        "path": "/tmp/tachyon-core/rulesets/hysteria-lists-ruleset.json"
      }
    ]
  }
}
EOF
run_reload "0" "$LOCAL_RS_LOG"

grep -Fq 'service/state:reload-core-runtime' "$LOCAL_RS_LOG" ||
  fail "reload_singbox_after_list_update must reload core when local rule_set is present even if config.json hash is unchanged"

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      shift
      [ "$(stat -c %a "$1")" = 600 ] || exit 91
      grep -Fq 'Authorization: Bearer fixture-secret' "$1" || exit 92
      printf '%s\n' "$1" >> "$FAKE_CURL_CONFIG_LOG"
      ;;
    --url)
      shift
      printf 'refresh:%s\n' "$1" >> "$FAKE_CALL_LOG"
      ;;
  esac
  shift
done
[ "${FAIL_REMOTE_REFRESH:-0}" != 1 ]
SH
chmod +x "$WORK_DIR/bin/curl"
export PATH="$WORK_DIR/bin:$PATH"
export FAKE_CURL_ARGV_LOG="$WORK_DIR/curl.args"
export FAKE_CURL_CONFIG_LOG="$WORK_DIR/curl.configs"
touch "$FAKE_CURL_ARGV_LOG" "$FAKE_CURL_CONFIG_LOG"

# A cached remote list must be refreshed even if the core config did not change.
# Local/inline lists are not HTTP providers; duplicate tags are refreshed once.
cat > "$CONFIG_PATH" <<'EOF'
{
  "experimental": {"clash_api": {"external_controller": "0.0.0.0:9090", "secret": "fixture-secret"}},
  "route": {"rule_set": [
    {"type": "remote", "tag": "zapret /%", "url": "https://example.test/zapret.srs"},
    {"type": "remote", "tag": "vpn", "url": "https://example.test/vpn.json"},
    {"type": "remote", "tag": "vpn", "url": "https://example.test/vpn.json"},
    {"type": "local", "tag": "local", "path": "/tmp/local.srs"},
    {"type": "inline", "tag": "inline", "rules": []}
  ]}
}
EOF
REMOTE_LOG="$WORK_DIR/remote.log"
run_reload "0" "$REMOTE_LOG"
grep -Fxq 'refresh:http://127.0.0.1:9090/providers/rules/zapret%20%2F%25' "$REMOTE_LOG" ||
  fail "remote tag must be URL encoded and wildcard controller mapped to loopback"
[ "$(grep -c '^refresh:' "$REMOTE_LOG")" = 2 ] ||
  fail "remote lists must be refreshed once per tag"
reload_line=$(grep -n 'service/state:reload-core-runtime' "$REMOTE_LOG" | cut -d: -f1)
refresh_line=$(grep -n '^refresh:' "$REMOTE_LOG" | head -1 | cut -d: -f1)
[ "$reload_line" -lt "$refresh_line" ] || fail "remote refresh must run after core reload"

# Without local files, remote refresh must not need a SIGHUP at all.
sed -i '/"type": "local"/d' "$CONFIG_PATH"
run_reload "0" "$REMOTE_LOG"
grep -q '^refresh:' "$REMOTE_LOG" || fail "unchanged remote-only config must still refresh"
if grep -q 'reload-core-runtime' "$REMOTE_LOG"; then
  fail "remote-only refresh must not reload the core"
fi

# A failed provider refresh fails the update, while still trying the other lists.
status=0
FAIL_REMOTE_REFRESH=1 run_reload "0" "$REMOTE_LOG" || status=$?
[ "$status" != 0 ] || fail "HTTP refresh failure must propagate to the update caller"
[ "$(grep -c '^refresh:' "$REMOTE_LOG")" = 2 ] || fail "one failed list must not skip the others"

# Do not refresh against the old runtime if applying its replacement failed.
sed -i 's/"type": "inline"/"type": "local", "path": "\/tmp\/inline.srs"/' "$CONFIG_PATH"
status=0
FAIL_CORE_RELOAD=1 run_reload "0" "$REMOTE_LOG" || status=$?
[ "$status" != 0 ] || fail "core reload failure must propagate"
if grep -q '^refresh:' "$REMOTE_LOG"; then
  fail "failed core reload must not refresh providers in the old runtime"
fi

# Use a compact fixture for the IPv6 controller and missing-controller cases.
cat > "$CONFIG_PATH" <<'EOF'
{
  "experimental": {"clash_api": {"external_controller": "[::]:9090", "secret": "fixture-secret"}},
  "route": {"rule_set": [{"type": "remote", "tag": "zapret", "url": "https://example.test/zapret.srs"}]}
}
EOF
run_reload "0" "$REMOTE_LOG"
grep -Fxq 'refresh:http://[::1]:9090/providers/rules/zapret' "$REMOTE_LOG" ||
  fail "IPv6 wildcard controller must map to loopback"
sed -i '/"experimental":/d' "$CONFIG_PATH"
status=0
run_reload "0" "$REMOTE_LOG" || status=$?
[ "$status" != 0 ] || fail "remote lists without a controller must report refresh failure"
if grep -q '^refresh:' "$REMOTE_LOG"; then
  fail "missing controller must not issue HTTP requests"
fi

if grep -q 'fixture-secret' "$FAKE_CURL_ARGV_LOG"; then
  fail "API secret must not appear in curl arguments"
fi
while IFS= read -r config; do
  [ ! -e "$config" ] || fail "temporary curl config must be removed, including on failure"
done < "$FAKE_CURL_CONFIG_LOG"

printf 'list_update_reload_guard tests passed\n'
