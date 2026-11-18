#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"
UPDATES_UC="$TACHYON_LIB/components/updates.uc"

TMP_RULESETS="$WORK_DIR/tmp-rulesets"
ETC_RULESETS="$WORK_DIR/etc-rulesets"
RUN_DIR="$WORK_DIR/run"
FAKE_BIN="$WORK_DIR/bin"
FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$TMP_RULESETS" "$ETC_RULESETS" "$RUN_DIR" "$FAKE_BIN" "$FAKE_LIB"

# Offline curl: fails every download so clean-install offline path executes.
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env sh
exit 22
SH
chmod +x "$FAKE_BIN/curl"

cat >"$WORK_DIR/uci.state" <<EOF
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.proxy_mode=tproxy
tachyon.settings.dns_type=udp
tachyon.settings.dns_server=77.88.8.8
tachyon.settings.config_path=$WORK_DIR/core-config.json
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=connection
tachyon.Main.community_lists=ru_whitelist ai_all
EOF

# 1. Clean-install offline prepare_community_rulesets must NEVER emit .srs stubs in .trs mode.
env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  ucode -L "$TACHYON_LIB" "$LIFECYCLE_UC" prepare-community-rulesets-fixture ||
  fail "prepare-community-rulesets-fixture failed"

if find "$TMP_RULESETS" "$ETC_RULESETS" -name '*.srs' | grep -q .; then
  fail "clean offline prepare_community_rulesets created forbidden .srs stub(s): $(find "$TMP_RULESETS" "$ETC_RULESETS" -name '*.srs')"
fi

# 2. Config generator without local files must emit remote .trs entries and ZERO .srs references.
cat >"$WORK_DIR/gen-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "77.88.8.8",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "Main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"direct-out\"}" ],
      "community_lists": [ "ru_whitelist", "ai_all" ]
    }
  ]
}
JSON

GEN_OUT="$WORK_DIR/generated-config.json"
mkdir -p "$GEN_OUT.section-cache"
cp -r "$TMP_RULESETS" "$GEN_OUT.rulesets"
TACHYON_LIB="$TACHYON_LIB" TMP_RULESET_FOLDER="$TMP_RULESETS" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/gen-fixture.json" "$GEN_OUT" "127.0.0.1" "0" "1" ||
  fail "generate-config-fixture failed"

node - "$GEN_OUT" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sets = (cfg.route && cfg.route.rule_set) || [];
const raw = JSON.stringify(sets);
if (raw.includes('.srs')) {
  console.error('Generated config references .srs in offline clean start:', raw);
  process.exit(1);
}
for (const name of ['ru_whitelist', 'ai_all']) {
  const rs = sets.find(x => x.url && x.url.includes(`/release/tachyon/${name}.trs`));
  if (!rs || rs.type !== 'remote') {
    console.error(`Missing remote .trs rule_set for ${name}:`, JSON.stringify(sets));
    process.exit(1);
  }
}
NODE

# 3. ensure_local_rulesets_exist must NEVER write EMPTY_SRS_BINARY into a missing .trs path.
cat >"$WORK_DIR/missing-trs.json" <<JSON
{
  "route": {
    "rule_set": [
      {
        "type": "local",
        "tag": "Main-ru_whitelist-community-ruleset",
        "format": "binary",
        "path": "$TMP_RULESETS/community-ru_whitelist.trs"
      }
    ]
  }
}
JSON

TACHYON_LIB="$TACHYON_LIB" TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  ucode -L "$TACHYON_LIB" "$RUNTIME_UC" ensure-local-rulesets-fixture "$WORK_DIR/missing-trs.json" ||
  fail "ensure-local-rulesets-fixture failed"

[ ! -e "$TMP_RULESETS/community-ru_whitelist.trs" ] ||
  fail "ensure_local_rulesets_exist must not write fake SRS binary to a .trs path"

node - "$WORK_DIR/missing-trs.json" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rs = cfg.route.rule_set[0];
if (rs.format !== 'source' || !rs.path.endsWith('.empty.json')) {
  console.error('Missing .trs entry should convert to empty JSON source in temp check config:', rs);
  process.exit(1);
}
const fallback = JSON.parse(fs.readFileSync(rs.path, 'utf8'));
if (!Array.isArray(fallback.rules)) {
  console.error('Fallback empty source file invalid:', fallback);
  process.exit(1);
}
NODE

# 4. import_community_srs_file in .trs mode must NOT fall back to .srs or emit .srs stubs.
printf 'SRS\x02stubplaceholder' > "$TMP_RULESETS/community-ai_all.srs"
printf 'SRS\x02stubplaceholder' > "$ETC_RULESETS/community-ai_all.srs"
if env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  ucode -L "$TACHYON_LIB" "$UPDATES_UC" import-community-ruleset-fixture ai_all 0 >/dev/null 2>&1; then
  fail "import_community_srs_file should return failure when offline and no .trs cache exists"
fi

[ ! -e "$TMP_RULESETS/community-ai_all.srs" ] ||
  fail "failed offline .trs import left stale /tmp .srs stub behind"
[ ! -e "$ETC_RULESETS/community-ai_all.srs" ] ||
  fail "failed offline .trs import left stale /etc .srs stub behind"

# 5. Partial list_update: when one community list updates (.srs deleted -> .trs created) and
#    another community list fails (ok=false), core reload still regenerates config.json.
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *ru_whitelist.trs*)
    printf 'TCRS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$out"
    exit 0
    ;;
  https://github.com|https://github.com/)
    exit 0
    ;;
  *)
    exit 22
    ;;
esac
SH
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/dig" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "1.1.1.1"
exit 0
SH
chmod +x "$FAKE_BIN/dig"
cat >"$FAKE_BIN/nslookup" <<'SH'
#!/usr/bin/env sh
echo "Address: 1.1.1.1"
exit 0
SH
chmod +x "$FAKE_BIN/nslookup"

# Point initial config.json to stale .srs so we verify partial failure triggers core reload
printf 'SRS\x02stale012345678' > "$TMP_RULESETS/community-ru_whitelist.srs"
cat >"$WORK_DIR/core-config.json" <<JSON
{
  "route": {
    "rule_set": [
      {
        "type": "local",
        "tag": "Main-ru_whitelist-community-ruleset",
        "format": "binary",
        "path": "$TMP_RULESETS/community-ru_whitelist.srs"
      }
    ]
  }
}
JSON

stub_header='#!/usr/bin/env ucode
let fs = require("fs");
function as_string(v) { return v == null ? "" : "" + v; }
function record(line) {
    let p = getenv("FAKE_CALL_LOG") || "";
    if (p != "") {
        let f = fs.open(p, "a");
        if (f) { f.write(as_string(line) + "\n"); f.close(); }
    }
}
'
cp -r "$TACHYON_LIB"/. "$FAKE_LIB"/
cat >"$FAKE_LIB/service/state.uc" <<EOF
$stub_header
let mode = as_string(ARGV[0]);
record("service/state:" + mode);
if (mode == "tachyon-core-service-runtime-pid") { print("7890\n"); exit(0); }
exit(0);
EOF
cat >"$FAKE_LIB/nft/apply.uc" <<EOF
$stub_header
record("nft/apply:" + as_string(ARGV[0]));
exit(0);
EOF
cat >"$FAKE_LIB/tachyon_core/priority.uc" <<EOF
$stub_header
exit(0);
EOF
cat >"$FAKE_LIB/tachyon_core/dns_failover.uc" <<EOF
$stub_header
exit(0);
EOF
cat >"$FAKE_LIB/tachyon_core/runtime.uc" <<EOF
$stub_header
let mode = as_string(ARGV[0]);
record("tachyon_core/runtime:" + mode);
if (mode == "init-config") {
    let f = fs.open(getenv("FAKE_CORE_CONFIG") || "", "w");
    if (f) { f.write('{"route":{"rule_set":[]}}\n'); f.close(); }
    exit(0);
}
exit(0);
EOF

CALL_LOG="$WORK_DIR/partial-update.log"
: > "$CALL_LOG"
env PATH="$FAKE_BIN:$PATH" \
  TACHYON_LIB="$FAKE_LIB" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  TMP_RULESET_FOLDER="$TMP_RULESETS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RULESETS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_LIST_UPDATE_PID_FILE="$RUN_DIR/list_update.pid" \
  TACHYON_RELOAD_LOCK_DIR="$WORK_DIR/reload.lock" \
  FAKE_CORE_CONFIG="$WORK_DIR/core-config.json" \
  FAKE_CALL_LOG="$CALL_LOG" \
  ucode -L "$FAKE_LIB" -L "$TACHYON_LIB" "$UPDATES_UC" list-update >/dev/null 2>&1 || true

[ ! -e "$TMP_RULESETS/community-ru_whitelist.srs" ] ||
  fail "partial update must delete replaced .srs stub when .trs succeeds"
[ -f "$TMP_RULESETS/community-ru_whitelist.trs" ] ||
  fail "partial update did not write ru_whitelist .trs"
grep -Fq 'tachyon_core/runtime:init-config' "$CALL_LOG" ||
  fail "partial list_update changing local rulesets must still regenerate core config (calls: $(tr '\n' ',' < "$CALL_LOG"))"
grep -Fq 'service/state:reload-core-runtime' "$CALL_LOG" ||
  fail "partial list_update changing core config must reload core runtime"

printf 'clean_install_trs_offline: all checks passed\n'
