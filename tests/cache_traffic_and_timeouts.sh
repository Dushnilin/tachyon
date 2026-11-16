#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
export TACHYON_LIB

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
MIGRATION_UC="$TACHYON_LIB/config/migration.uc"
ROUTING_UC="$TACHYON_LIB/diagnostics/routing.uc"
EVENT_CONTROLLER_UC="$TACHYON_LIB/service/event_controller.uc"

uc() {
  command ucode -L "$TACHYON_LIB" "$@"
}

# 1. Explicit /tmp cache_path must be respected even when dns_turbo_cache=1
make_cache_fixture() {
  local cache_path="$1" out="$2"
  cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_turbo_cache": "1",
    "cache_path": "$cache_path"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ]
    }
  ]
}
JSON
}

make_cache_fixture "/tmp/tachyon-core/cache.db" "$WORK_DIR/fx_ram_tachyon.json"
mkdir -p "$WORK_DIR/sc1"
TACHYON_SECTION_CACHE_DIR="$WORK_DIR/sc1" \
  uc "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/fx_ram_tachyon.json" "$WORK_DIR/out_ram_tachyon.json" "127.0.0.1" >/dev/null
uc - "$WORK_DIR/out_ram_tachyon.json" <<'UCODE'
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cp = cfg.experimental?.cache_file?.path;
if (cp != "/tmp/tachyon-core/cache.db") {
    warn("expected explicit /tmp/tachyon-core/cache.db, got: " + cp + "\n");
    exit(1);
}
UCODE

make_cache_fixture "/tmp/custom-cache/cache.db" "$WORK_DIR/fx_ram_custom.json"
mkdir -p "$WORK_DIR/sc2"
TACHYON_SECTION_CACHE_DIR="$WORK_DIR/sc2" \
  uc "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/fx_ram_custom.json" "$WORK_DIR/out_ram_custom.json" "127.0.0.1" >/dev/null
uc - "$WORK_DIR/out_ram_custom.json" <<'UCODE'
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cp = cfg.experimental?.cache_file?.path;
if (cp != "/tmp/custom-cache/cache.db") {
    warn("expected explicit /tmp/custom-cache/cache.db, got: " + cp + "\n");
    exit(1);
}
UCODE

make_cache_fixture "" "$WORK_DIR/fx_default_turbo.json"
mkdir -p "$WORK_DIR/sc3"
TACHYON_SECTION_CACHE_DIR="$WORK_DIR/sc3" \
  uc "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/fx_default_turbo.json" "$WORK_DIR/out_default_turbo.json" "127.0.0.1" >/dev/null
uc - "$WORK_DIR/out_default_turbo.json" <<'UCODE'
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let cp = cfg.experimental?.cache_file?.path;
if (cp != "/etc/tachyon-core/cache.db") {
    warn("expected turbo default promotion to /etc/tachyon-core/cache.db, got: " + cp + "\n");
    exit(1);
}
UCODE

# migration.uc must preserve /tmp/tachyon-core/cache.db and rewrite /tmp/sing-box/cache.db -> /tmp/tachyon-core/cache.db
for pair in \
  "/tmp/tachyon-core/cache.db:/tmp/tachyon-core/cache.db" \
  "/tmp/sing-box/cache.db:/tmp/tachyon-core/cache.db" \
  "/usr/share/sing-box/cache.db:/usr/share/tachyon-core/cache.db"
do
  src="${pair%%:*}"
  dst="${pair##*:}"
  slug="$(printf '%s' "$src" | tr '/:' '__')"
  cat >"$WORK_DIR/mig_${slug}.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "cache_path": "$src"
  },
  "section": []
}
JSON
  uc "$MIGRATION_UC" migrate-fixture "$WORK_DIR/mig_${slug}.json" tachyon >"$WORK_DIR/mig_out_${slug}.json"
  uc - "$WORK_DIR/mig_out_${slug}.json" "$dst" <<'UCODE'
let fs = require("fs");
let data = json(fs.readfile(ARGV[0]));
let expected = ARGV[1];
let actual = data.config?.settings?.cache_path;
if (actual != expected) {
    warn("migration mismatch: expected " + expected + ", got " + actual + "\n");
    exit(1);
}
UCODE
done

# 2. get_clash_traffic() streaming /traffic with exit code 28
FAKE_BIN="$WORK_DIR/fake_bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CURL_CALLS"
mode="${MOCK_CURL_MODE:-stream28}"
if [ "$mode" = "stream28" ]; then
  printf '\n{"up":1234,"down":5678}\n{"up":99'
  exit 28
elif [ "$mode" = "ok0" ]; then
  printf '{"up":42,"down":84}\n'
  exit 0
else
  exit 7
fi
SH
chmod +x "$FAKE_BIN/curl"

cat >"$WORK_DIR/core-config.json" <<'JSON'
{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:19090",
      "secret": "test-secret"
    }
  }
}
JSON

cat >"$WORK_DIR/uci.state" <<EOF
tachyon.settings=settings
tachyon.settings.config_path=$WORK_DIR/core-config.json
tachyon.settings.subscription_url=https://sub.example.invalid/feed
EOF

export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run"
mkdir -p "$TACHYON_RUNTIME_STATE_DIR/ui-state"

FAKE_CURL_CALLS="$WORK_DIR/traffic_calls.log"
: >"$FAKE_CURL_CALLS"
PATH="$FAKE_BIN:$PATH" FAKE_CURL_CALLS="$FAKE_CURL_CALLS" MOCK_CURL_MODE=stream28 \
  uc - <<'UCODE'
let api = require("service.api");
let tr = api.get_clash_traffic();
if (!tr || tr.up != 1234 || tr.down != 5678) {
    warn("stream28 failed: " + sprintf("%J", tr) + "\n");
    exit(1);
}
UCODE
grep -Fq -- "-N" "$WORK_DIR/traffic_calls.log" || fail "get_clash_traffic must pass -N"
grep -Fq -- "-m 2" "$WORK_DIR/traffic_calls.log" || fail "get_clash_traffic must pass -m 2"
grep -Fq -- "--connect-timeout 2" "$WORK_DIR/traffic_calls.log" || fail "get_clash_traffic must pass --connect-timeout 2"

PATH="$FAKE_BIN:$PATH" FAKE_CURL_CALLS="$FAKE_CURL_CALLS" MOCK_CURL_MODE=ok0 \
  uc - <<'UCODE'
let api = require("service.api");
let tr = api.get_clash_traffic();
if (!tr || tr.up != 42 || tr.down != 84) {
    warn("ok0 failed: " + sprintf("%J", tr) + "\n");
    exit(1);
}
UCODE

PATH="$FAKE_BIN:$PATH" FAKE_CURL_CALLS="$FAKE_CURL_CALLS" MOCK_CURL_MODE=err7 \
  uc - <<'UCODE'
let api = require("service.api");
let tr = api.get_clash_traffic();
if (tr != null) {
    warn("err7 must return null, got: " + sprintf("%J", tr) + "\n");
    exit(1);
}
UCODE

# 3. routing.uc :9090 curl timeouts & single-line args
ROUTING_BIN="$WORK_DIR/routing_bin"
mkdir -p "$ROUTING_BIN"
ROUTING_CALLS="$WORK_DIR/routing_calls.log"
: >"$ROUTING_CALLS"
cat >"$ROUTING_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${*//$'\n'/ }" >>"$ROUTING_CALLS"
case " $* " in
  *" -w "*) printf '\n204' ;;
  *"/connections"*) printf '{"connections":[]}\n' ;;
  *"/delay"*) printf '{"delay":55}\n' ;;
  *"/proxies"*) printf '{"proxies":{"g1":{"type":"Selector","all":["a"],"now":"b"}}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$ROUTING_BIN/curl"

cat >"$WORK_DIR/selector_state.json" <<'JSON'
{"g1":"a"}
JSON

for act in \
  "get_proxies" \
  "get_connections" \
  "get_group_latency g1 5000" \
  "set_group_proxy g1 a ephemeral" \
  "restore_selector_state" \
  "close_connection conn-1" \
  "close_all_connections"
do
  read -r -a args <<<"$act"
  : >"$ROUTING_CALLS"
  PATH="$ROUTING_BIN:$PATH" \
    ROUTING_CALLS="$ROUTING_CALLS" \
    TACHYON_SEQUENTIAL_LATENCY=1 \
    TACHYON_PERSISTENT_SELECTOR_STATE_FILE="$WORK_DIR/selector_state.json" \
    uc - "${args[@]}" >/dev/null <<'UCODE'
let routing = require("diagnostics.routing");
exit(routing.clash_api(ARGV[0], ARGV[1], ARGV[2], ARGV[3]));
UCODE
  lines="$(wc -l <"$ROUTING_CALLS")"
  [ "$lines" -ge 1 ] || fail "routing action '$act' made no curl calls"
  while IFS= read -r call_line; do
    case " $call_line " in
      *" --connect-timeout 2 "*) ;;
      *) fail "routing action '$act' missing --connect-timeout 2: $call_line" ;;
    esac
    case " $call_line " in
      *" -m 3 "*|*" -m 5 "*) ;;
      *) fail "routing action '$act' missing -m timeout: $call_line" ;;
    esac
  done <"$ROUTING_CALLS"
done

# 4. event_controller.uc probe_subscription() --max-time 15
SUB_BIN="$WORK_DIR/sub_bin"
mkdir -p "$SUB_BIN"
SUB_CALLS="$WORK_DIR/sub_calls.log"
: >"$SUB_CALLS"
cat >"$SUB_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUB_CALLS"
printf '200'
SH
chmod +x "$SUB_BIN/curl"

mkdir -p "$WORK_DIR/ec_state"
PATH="$SUB_BIN:$PATH" SUB_CALLS="$SUB_CALLS" \
  TACHYON_EVENT_LOG="$WORK_DIR/ec_events.jsonl" \
  TACHYON_STATE_DIR="$WORK_DIR/ec_state" \
  uc - <<'UCODE'
let events = require("core.events");
let ec = require("service.event_controller");
let bus = events.bus();
let ctrl = ec.controller(bus);
ctrl.probe_slow({
    now: time(),
    settings: { subscription_url: "https://sub.example.invalid/feed" },
    reload_in_progress: false,
    tachyon_core_pid: "",
    tachyon_core_running: false,
    proxy_port: "",
    proxy_host: "127.0.0.1"
});
UCODE
grep -Fq -- "--connect-timeout 10" "$SUB_CALLS" || fail "probe_subscription missing --connect-timeout 10"
grep -Fq -- "--max-time 15" "$SUB_CALLS" || fail "probe_subscription missing --max-time 15"

printf 'PASS: cache_traffic_and_timeouts\n'
