#!/usr/bin/env bash
# Local fixtures only: never reads/writes live UCI, starts services or contacts a router.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
export TACHYON_SMART_EXCLUSIONS_DIR="$WORK_DIR/exclusions"
mkdir -p "$TACHYON_SMART_EXCLUSIONS_DIR"
cat > "$WORK_DIR/watchdog.uc" <<'UC'
let smart_plus_job={task:{id:"old"}},stopped=0;
let smart_probe={stop:function(){stopped++;}};
let pending_smart_domains={"old.example":1},pending_smart_plus={"old.example":{}};
function settings(){return {smart_detect:"1",smart_detect_chain:"1"};}
UC
awk '/^function smart_detect_process_pending\(\)/{active=1} active{print} active && /^}/{exit}' "$TACHYON_LIB/service/watchdog.uc" >> "$WORK_DIR/watchdog.uc"
cat >> "$WORK_DIR/watchdog.uc" <<'UC'
smart_detect_process_pending();
assert(stopped==1&&smart_plus_job==null,"old worker canceled in chain mode");
assert(!length(pending_smart_domains)&&!length(pending_smart_plus),"legacy UCI additions disabled");
print("PASS: chain cancels legacy detection before any UCI writes\n");
UC
ucode "$WORK_DIR/watchdog.uc"
cat > "$WORK_DIR/controller.uc" <<'UC'
let current_tick_ctx={settings:{smart_detect_chain:"1"},singbox_running:true,now:100};
let smart_plus={capture_enabled:function(){return true;}};
let state={smart_detect_connections:{old:true},smart_detect_silent_drops:{old:true}};
let last_smart_detect_poll=99;
UC
awk '/^    function probe_smart_detect_connections\(\)/{active=1} active{print} active && /^    }/{exit}' "$TACHYON_LIB/service/event_controller.uc" >> "$WORK_DIR/controller.uc"
cat >> "$WORK_DIR/controller.uc" <<'UC'
probe_smart_detect_connections();
assert(!length(state.smart_detect_connections)&&!length(state.smart_detect_silent_drops)&&last_smart_detect_poll==0,"chain skips background API polling");
print("PASS: chain owns connection decisions without legacy polling\n");
UC
ucode "$WORK_DIR/controller.uc"
cat > "$WORK_DIR/readiness.uc" <<'UC'
let CONFIG="fixture",DIR="/fixture",INIT="/fixture/init";
let active=true,readyAfter=3,polls=0,stops=0,expectedGeneration="";
let uci={get_all:function(){return {};},section_objects:function(){return [];}};
let engine={enabled:function(){return active;},plan:function(){return {helper:{generation:"new"}};}};
let fs={stat:function(){return true;},chmod:function(){},unlink:function(){},rename:function(){return true;},
    readlink:function(){return "/usr/bin/tachyon-smart-connect";}};
let common={read_json_file:function(path){
    if(path==DIR+"/status.json")return {pid:123,generation:++polls>=readyAfter?expectedGeneration:"old"};
    return {};
},write_json_file:function(path,cfg){expectedGeneration=cfg.generation;return true;},command_success_from_args:function(){return true;},command_status_from_args:function(){return 0;}};
function stop(){stops++;}
UC
awk '/^function sync\(/{active=1} active{print} active && /^}/{exit}' "$TACHYON_LIB/service/smart_connect.uc" >> "$WORK_DIR/readiness.uc"
cat >> "$WORK_DIR/readiness.uc" <<'UC'
assert(sync(true)&&polls==3,"wait for current helper generation before activation");
assert(expectedGeneration=="new:preparing","prepare uses temporary observations");
assert(sync()&&expectedGeneration=="new:active","post-core commit clears temporary observations");
active=false;assert(sync(true)&&stops==0,"prepare keeps helper for old core during disable");
assert(sync()&&stops==1,"post-reload sync stops disabled helper");
active=true;readyAfter=1000;polls=0;
assert(!sync(true)&&polls==50,"readiness timeout aborts core activation");
print("PASS: helper readiness and disable sequencing\n");
UC
ucode "$WORK_DIR/readiness.uc"
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/smart_connect.uc" "$WORK_DIR/helper.json"
if [ -n "${TACHYON_TEST_CONNECTOR:-}" ]; then
  "$TACHYON_TEST_CONNECTOR" -check -config "$WORK_DIR/helper.json"
fi
cat > "$WORK_DIR/fixture.json" <<'JSON'
{"settings":{".name":"settings",".type":"settings","smart_detect":"1","smart_detect_chain":"1","smart_detect_chain_zapret":"zapret","smart_detect_chain_vpn":"proxy","dns_type":"udp","dns_server":"1.1.1.1","service_listen_address":"127.0.0.1"},"section":[{".name":"manual",".type":"section","enabled":"1","action":"bypass","domain_suffix":["manual.example"]},{".name":"proxy",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["socks5://127.0.0.1:19999"],"domain_suffix":["vpn.example"]},{".name":"zapret",".type":"section","enabled":"1","action":"zapret2","domain_suffix":["zapret.example"],"routed_dns_enabled":"1","routed_dns_type":"doh","routed_dns_server":"https://1.1.1.1/dns-query"}]}
JSON
printf '%s\n' 1.14.1 > "$WORK_DIR/version"
output="$WORK_DIR/generated.json"
mkdir -p "$output.section-cache" "$output.rulesets"
SB_VERSION_STATE_FILE="$WORK_DIR/version" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$output" 127.0.0.1 0 1
if [ -n "${TACHYON_TEST_CORE:-}" ]; then
  "$TACHYON_TEST_CORE" check -c "$output"
fi
ucode -e '
 let fs=require("fs"),c=json(fs.readfile(ARGV[0]));let tags={};for(let o in c.outbounds)tags[o.tag]=o;
 assert(tags["smart-connect-auto-out"]?.type=="socks","real generator wires the automatic connector");
 assert(tags["smart-connect-zapret-out"]?.server_port==14701,"real generator wires the forced Zapret connector");
 let manual=-1,automatic=-1;
 for(let i,r in c.route.rules){if(r.outbound=="bypass-out")manual=i;if(r.outbound=="smart-connect-auto-out")automatic=i;}
 assert(manual>=0&&automatic>manual,"manual bypass retained before automatic routing");
 print("PASS: full generator fixture\n");
' "$output"
for key in smart_detect_chain smart_detect_chain_zapret smart_detect_chain_vpn smart_detect_chain_budget_ms smart_detect_exclude; do
  ucode -e 'let f=require("fs"),c=json(f.readfile(ARGV[0]));c.settings[ARGV[1]]="changed";print(sprintf("%J",c));' "$WORK_DIR/fixture.json" "$key" > "$WORK_DIR/changed.json"
  a=$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/state.uc" sing-box-signature-fixture "$WORK_DIR/fixture.json")
  b=$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/service/state.uc" sing-box-signature-fixture "$WORK_DIR/changed.json")
  [ "$a" != "$b" ] || fail "$key omitted from reload signature"
done
echo 'PASS: Smart Connect reload signatures'
node "$ROOT_DIR/tests/smart_connect_ui.mjs"
