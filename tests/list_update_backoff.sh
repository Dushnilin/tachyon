#!/usr/bin/env bash
# #420: exercise real update entry points with isolated UCI/files and fake network.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run"
export TACHYON_LIST_UPDATE_PID_FILE="$WORK_DIR/list.pid"
export TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TMP_SING_BOX_FOLDER="$WORK_DIR/core"
export TMP_RULESET_FOLDER="$WORK_DIR/rulesets"
export TACHYON_PERSISTENT_RULESET_DIR="$WORK_DIR/persistent"
export CURL_LOG="$WORK_DIR/curl.log"
export HTTP_BODY="$WORK_DIR/body"
mkdir -p "$WORK_DIR/bin" "$TACHYON_RUNTIME_STATE_DIR" "$TMP_RULESET_FOLDER" "$TACHYON_PERSISTENT_RULESET_DIR"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) shift; out="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
[ -n "$out" ] || exit 0
printf '%s\n' "$url" >>"$CURL_LOG"
[ "${NETWORK_DOWN:-0}" != 1 ] || exit 28
cp "$HTTP_BODY" "$out"
SH
printf '#!/bin/sh\nprintf "192.0.2.1\\n"\n' >"$WORK_DIR/bin/dig"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/nft"
export UPDATE_LOG="$WORK_DIR/update.log"
printf '#!/bin/sh\nprintf "%%s\\\\n" "$*" >>"$UPDATE_LOG"\n' >"$WORK_DIR/bin/logger"
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"
export REAL_LIST_TEST_LIB="$TACHYON_LIB"
mkdir -p "$WORK_DIR/lib"
ln -s "$TACHYON_LIB/"* "$WORK_DIR/lib/"
rm "$WORK_DIR/lib/nft"
mkdir "$WORK_DIR/lib/nft"
cat >"$WORK_DIR/lib/nft/apply.uc" <<'UC'
let c = require("core.common");
if (index([ "nft-prepare-list-refresh", "nft-commit-list-refresh" ], ARGV[0]) >= 0)
    exit(0);
let args = [ "ucode", "-L", getenv("REAL_LIST_TEST_LIB"), getenv("REAL_LIST_TEST_LIB") + "/nft/apply.uc" ];
for (let arg in ARGV) push(args, arg);
exit(c.command_status(c.command_from_args(args)));
UC
# This fixture has no running core. A parallel test's stand-in must not turn
# cache refresh into a reload of an unrelated process (CI runs with -P4).
rm "$WORK_DIR/lib/service"
mkdir "$WORK_DIR/lib/service"
ln -s "$REAL_LIST_TEST_LIB/service/"* "$WORK_DIR/lib/service/"
rm "$WORK_DIR/lib/service/state.uc"
cat >"$WORK_DIR/lib/service/state.uc" <<'UC'
if (ARGV[0] == "tachyon-core-service-runtime-pid")
    exit(0);
let c = require("core.common");
let args = [ "ucode", "-L", getenv("REAL_LIST_TEST_LIB"), getenv("REAL_LIST_TEST_LIB") + "/service/state.uc" ];
for (let arg in ARGV) push(args, arg);
exit(c.command_status(c.command_from_args(args)));
UC
export TACHYON_LIB="$WORK_DIR/lib"
UPDATES="$TACHYON_LIB/components/updates.uc"
updates() { ucode -L "$TACHYON_LIB" "$UPDATES" "$@"; }
settings() {
  cat >"$TACHYON_UCI_STATE_FILE" <<EOF
tachyon.settings=settings
tachyon.settings.update_interval=1m
tachyon.settings.list_update_enabled=$1
tachyon.dns=section
tachyon.dns.enabled=1
tachyon.dns.action=dns
tachyon.dns.domain_ip_lists=https://raw.githubusercontent.com/example/lists/main/domains.lst
EOF
}
status_field() {
  updates list-update-status | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]]))' "$1"
}
settings 1
printf 'example.org\n' >"$HTTP_BODY"
updates list-update || { cat "$UPDATE_LOG" "$TACHYON_RUNTIME_STATE_DIR/list-update.status"; fail "initial update failed"; }
cache="$TACHYON_PERSISTENT_RULESET_DIR/dns-lists-ruleset.json"
[ -s "$cache" ] || fail "successful initial update did not save persistent cache"
cp "$cache" "$WORK_DIR/good-cache"
# A manual failure must not be reported as successful just because cache survives.
NETWORK_DOWN=1 updates list-update >/dev/null 2>&1 && fail "cached fallback reported a fresh successful update"
[ "$(status_field success)" = false ] || fail "failure hidden from UI"
[ "$(status_field failures)" = 1 ] || fail "first failure not recorded"
[ "$(status_field retry_delay)" = 3600 ] || fail "first backoff must be one hour"
[ "$(status_field using_cache)" = true ] || fail "preserved cache not exposed in status"
TACHYON_UI_STATE_DIR="$WORK_DIR/ui" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/ui.uc" get-ui-state >"$WORK_DIR/ui.json"
node - "$WORK_DIR/ui.json" <<'JS'
const s = JSON.parse(require('fs').readFileSync(process.argv[2])).list_update;
if (s.success !== false || s.retry_delay !== 3600 || !s.auto_update_enabled)
  throw new Error('failure and cooldown missing from the polled LuCI state');
JS
cmp "$cache" "$WORK_DIR/good-cache" || fail "network failure changed persistent cache"
cmp "$TMP_RULESET_FOLDER/dns-lists-ruleset.json" "$WORK_DIR/good-cache" || fail "network failure changed runtime cache"
# Cron and service-start/reload paths must both respect backoff, without network I/O.
: >"$CURL_LOG"
NETWORK_DOWN=1 updates list-update-if-due
NETWORK_DOWN=1 updates list-update auto
[ ! -s "$CURL_LOG" ] || fail "automatic update ignored backoff"
# The shared due check used by service callers must honor cooldown too.
due=0
updates list-update-due-status "$TACHYON_RUNTIME_STATE_DIR/list-update.timestamp" "$(date +%s)" || due=$?
[ "$due" = 1 ] || fail "shared due check ignored cooldown or could not evaluate it (exit $due)"
# Clock rollback must not pin a previous failure into an indefinite cooldown.
cp "$TACHYON_RUNTIME_STATE_DIR/list-update.status" "$WORK_DIR/saved-status"
node - "$TACHYON_RUNTIME_STATE_DIR/list-update.status" <<'JS'
const fs = require('fs'); const p = process.argv[2]; const s = JSON.parse(fs.readFileSync(p));
s.timestamp = Math.floor(Date.now()/1000)+172800; s.retry_at = s.timestamp+3600;
fs.writeFileSync(p, JSON.stringify(s));
JS
updates list-update-due-status "$TACHYON_RUNTIME_STATE_DIR/list-update.timestamp" "$(date +%s)" ||
  fail "backwards clock change left list update in cooldown"
cp "$WORK_DIR/saved-status" "$TACHYON_RUNTIME_STATE_DIR/list-update.status"
# Manual retry bypasses cooldown, doubles it, and caps at one day.
for expected in 7200 14400 28800 57600 86400 86400; do
  NETWORK_DOWN=1 updates list-update >/dev/null 2>&1 && fail "failed manual retry returned success"
  [ "$(status_field retry_delay)" = "$expected" ] || fail "incorrect exponential delay, expected $expected"
done
# Expiring cooldown enables scheduled recovery, regardless of last success interval.
node - "$TACHYON_RUNTIME_STATE_DIR/list-update.status" <<'JS'
const fs = require('fs'); const p = process.argv[2]; const s = JSON.parse(fs.readFileSync(p));
s.retry_at = Math.floor(Date.now()/1000)-1; fs.writeFileSync(p, JSON.stringify(s));
JS
updates list-update-if-due
[ "$(status_field success)" = true ] || fail "scheduled recovery not successful"
[ "$(status_field failures)" = 0 ] || fail "successful recovery did not reset failures"
[ "$(status_field retry_at)" = 0 ] || fail "successful recovery did not clear cooldown"
# Disabled updates must suppress service-start, not just cron. Manual still works.
settings 0
: >"$CURL_LOG"
updates list-update auto
updates list-update-if-due
[ ! -s "$CURL_LOG" ] || fail "disabled automatic updates performed network I/O"
updates list-update
[ -s "$CURL_LOG" ] || fail "disabling automatic updates disabled manual updates too"
# Honor the spelling reported in #420 even before the next config migration.
settings 1
printf 'tachyon.settings.list_update_interval=0\n' >>"$TACHYON_UCI_STATE_FILE"
: >"$CURL_LOG"
updates list-update auto
updates list-update-if-due
[ ! -s "$CURL_LOG" ] || fail "list_update_interval=0 ignored"

# Reload removes stale list cron entries without removing unrelated jobs.
printf '{"settings":{"list_update_enabled":"1","list_update_interval":"0","update_interval":"1d"},"section":[{".name":"dns","enabled":"1","action":"dns","domain_ip_lists":["https://example.test/list"]}]}' >"$WORK_DIR/config.json"
printf '0 1 * * * /bin/true # keep\n* * * * * /usr/bin/tachyon list_update_if_due # list\n' >"$WORK_DIR/crontab"
updates refresh-cron-fixture "$WORK_DIR/config.json" "$WORK_DIR/crontab" /usr/bin/tachyon '# list' '# sub' '# comp' >"$WORK_DIR/cron.json"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/migration.uc" migrate-fixture "$WORK_DIR/config.json" tachyon >"$WORK_DIR/migrated.json"
node - "$WORK_DIR/cron.json" "$WORK_DIR/migrated.json" <<'JS'
const fs = require('fs'); const assert = require('assert').strict;
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).crontab, '0 1 * * * /bin/true # keep\n');
const s = JSON.parse(fs.readFileSync(process.argv[3])).config.settings;
assert.equal(s.list_update_enabled, '0');
assert.equal(s.update_interval, '1d');
assert.equal(s.list_update_interval, undefined);
JS
printf 'PASS: list update cache preservation, backoff, scheduled recovery, disable and manual retry\n'
