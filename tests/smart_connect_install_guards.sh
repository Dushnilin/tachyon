#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# Trusted metadata path cannot read the general downloader's mirror-filled cache.
cat > "$WORK_DIR/origin.uc" <<'UC'
let calls=[],available=true,as_string=require("core.common").as_string;
let helpers={service_proxy_address:function(){return "127.0.0.1:4534";},helper_success_input:function(){return true;}};
function http_get_with_body(url,timeout,proxy){
 assert(index(url,"https://api.github.com/repos/example/tachyon/releases/tags/")==0,"GitHub API origin only");
 push(calls,proxy);
 return available && proxy=="" ? {status:"200",body:'{"tag_name":"v1.9.0"}'} : {status:"503",body:""};
}
function fetch_github_json(){die("must not use a mirror or cached response");}
UC
for fn in fetch_github_json_origin fetch_github_release_by_tag_json; do
 awk -v name="$fn" '$0 ~ "^function " name "\\("{active=1} active{print} active && /^}/{exit}' "$TACHYON_LIB/components/downloader.uc" >> "$WORK_DIR/origin.uc"
done
cat >> "$WORK_DIR/origin.uc" <<'UC'
assert(fetch_github_release_by_tag_json("example","tachyon","v1.9.0",true)!='',"origin direct fallback");
assert(length(calls)==2 && calls[0]=="127.0.0.1:4534" && calls[1]=="","existing VPN before direct");
available=false;
assert(fetch_github_release_by_tag_json("example","tachyon","v1.9.0",true)=="","origin failure cannot fall back to mirrors/cache");
print("PASS: executable metadata uses uncached GitHub origin\n");
UC
ucode -L "$TACHYON_LIB" "$WORK_DIR/origin.uc"

# Slow downloads must not lose their lock to age while their owner is alive.
state="$TACHYON_LIB/service/state.uc"
ucode -L "$TACHYON_LIB" "$state" acquire-runtime-dir-lock "$WORK_DIR/lock" "$$" 0
touch -d '10 minutes ago' "$WORK_DIR/lock/pid"
if ucode -L "$TACHYON_LIB" "$state" acquire-runtime-dir-lock "$WORK_DIR/lock" 999999999 0; then
 fail 'live installer lock was stolen after 300 seconds'
fi
ucode -L "$TACHYON_LIB" "$state" release-runtime-dir-lock "$WORK_DIR/lock" 999999999
[ -d "$WORK_DIR/lock" ] || fail 'foreign owner released installer lock'
ucode -L "$TACHYON_LIB" "$state" release-runtime-dir-lock "$WORK_DIR/lock" "$$"
[ ! -d "$WORK_DIR/lock" ] || fail 'owner failed to release installer lock'
mkdir "$WORK_DIR/lock"
printf '%s\n' 999999999 > "$WORK_DIR/lock/pid"
ucode -L "$TACHYON_LIB" "$state" acquire-runtime-dir-lock "$WORK_DIR/lock" "$$" 0
ucode -L "$TACHYON_LIB" "$state" release-runtime-dir-lock "$WORK_DIR/lock" "$$"
echo 'PASS: live-owner locking, guarded release and dead-owner recovery'

cat > "$WORK_DIR/clock.uc" <<'UC'
let now=100000,allow=false,attempts=0,LIB="/fixture";
function time(){return now;}
let common={command_from_args:function(args){assert(args[length(args)-1]=="sync-time-if-needed","existing clock recovery");return "clock";},
 bounded_command:function(command,timeout){assert(timeout==20,"clock recovery bounded");return command;},
 command_success:function(){attempts++;if(allow)now=1793475000;return allow;}};
UC
awk '/^function clock_ready\(/{active=1} active{print} active && /^}/{exit}' "$TACHYON_LIB/components/smart_connect.uc" >> "$WORK_DIR/clock.uc"
cat >> "$WORK_DIR/clock.uc" <<'UC'
assert(!clock_ready() && attempts==1,"invalid clock blocks HTTPS bootstrap");
allow=true;assert(clock_ready() && attempts==2,"NTP runs before bootstrap");
assert(clock_ready() && attempts==2,"valid clock skips NTP");
print("PASS: bounded cold-boot clock preflight\n");
UC
ucode "$WORK_DIR/clock.uc"
