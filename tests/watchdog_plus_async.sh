#!/bin/sh
# Read source functions; use only a private job namespace and fake curl.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=${TACHYON_LIB:-$root/tachyon/files/usr/lib}
export TACHYON_LIB="$lib"
work=$(mktemp -d /tmp/tachyon-optimization-test.XXXXXX)
chmod 700 "$work"
mkdir -p "$work/bin" "$work/parent"
cat > "$work/cleanup.uc" <<'UCODE'
require('service.smart_detect_probe').cleanup();
UCODE
cleanup() {
    TACHYON_SMART_PROBE_DIR="$work/job" ucode -L "$lib" -L /usr/lib/tachyon "$work/cleanup.uc" >/dev/null 2>&1 || true
    test "$(readlink -f "$work")" = "$work" && rm -rf "$work"
}
trap cleanup EXIT INT TERM
cat > "$work/bin/curl" <<'CURL'
#!/bin/sh
set -eu
countfile=$TACHYON_TEST_COUNT_FILE
count=0
if test -f "$countfile"; then count=$(cat "$countfile"); fi
count=$((count+1)); echo "$count" > "$countfile"
sleep 2
if test "$count" -le 2; then exit 28; fi
exit 0
CURL
chmod 700 "$work/bin/curl"
cat > "$work/baseline.uc" <<'UCODE'
let plus=require('service.smart_detect_plus');let detect=require('service.smart_detect');
let stamp=clock();
let decision=plus.probe('example.com',{scheme:'https'},'127.0.0.1:4534',[],detect.probe_status);
let elapsed=(clock()[0]-stamp[0])*1000+(clock()[1]-stamp[1])/1000000;
assert(decision.act,'same fixture outcome');printf('SYNC_BASELINE_MS=%.3f\n',elapsed);
UCODE
cat > "$work/probe.uc" <<'UCODE'
let fs=require('fs');
let exec=require('core.exec');
let probe=require('service.smart_detect_probe');
let start=clock();
let job=probe.start({domain:'example.com',item:{scheme:'https'},proxy_addr:'127.0.0.1:4534',direct_flags:[]});
assert(job != null,'worker started');
let elapsed=(clock()[0]-start[0])*1000+(clock()[1]-start[1])/1000000;
assert(elapsed<500,'start is bounded');
printf('PROBE_START_MS=%.3f\n',elapsed);
let loops=0, decision=null;
while (decision == null) {
    loops++;
    let before=clock();
    decision=probe.poll(job);
    let duration=(clock()[0]-before[0])*1000+(clock()[1]-before[1])/1000000;
    assert(duration<100,'poll is nonblocking');
    assert(loops<60,'worker deadline');
    if(decision == null) sleep(200);
}
probe.stop(job);
printf('PASS: asynchronous result, polls=%d, act=%J\n',loops,decision.act);
assert(loops>=15 && decision.act==true,'two Direct failures and proxy success outside event loop');
job=probe.start({domain:'example.com',item:{scheme:'https'},proxy_addr:'127.0.0.1:4534',direct_flags:[]});
sleep(300);
let members=0, directory=fs.opendir('/proc'),entry;
let identities=[];
while((entry=directory.read())!=null){
 if(!match(entry,/^[0-9]+$/))continue;
 let s=fs.readfile('/proc/'+entry+'/stat')||'',p=rindex(s,') ');
 if(p>=0 && split(substr(s,p+2),' ')[2]==job.identity.pid){push(identities,exec.make_identity(entry,'test')); members++;}
}
directory.close();assert(members>=2,'worker and child process group');
probe.stop(job);sleep(100);
for(let identity in identities) assert(!exec.identity_matches(identity,identity.pid) || !fs.readfile('/proc/'+identity.pid+'/cmdline'),'group cleanup');
assert(!fs.stat(getenv('TACHYON_SMART_PROBE_DIR')+'/job.json'),'job state cleanup');
print('PASS: bounded worker group cleanup\n');
UCODE
cat > "$work/parent.uc" <<'UCODE'
let fs=require('fs');let common=require('core.common');
let smart_plus=require('service.smart_detect_plus');
let cfg={smart_detect:'1',smart_detect_mode:'plus',smart_detect_sections:['vpn']};
let dns={ready:true,signature:'a'};
let smart_detect_dns_state={};let smart_plus_seen={};let smart_plus_job=null;
let smart_plus_last_run=0;let pending_smart_plus={};let PENDING_SMART_DOMAINS_MAX=500;
let starts=0,stops=0,applied=0,result=null;
let smart_probe={start:function(r){starts++;return {id:'fixture'};},poll:function(j){return result;},stop:function(j){stops++;}};
let controller={proxy_port:function(){return '4534';}};
function smart_detect_observe_dns(){return dns;}
function smart_detect_get_proxy_sections(){return ['vpn'];}
function smart_detect_direct_curl_argv(){return [];}
function smart_detect_apply_domains(items){applied+=length(items);return items;}
function log_message(m,l){}
function candidate(){pending_smart_plus={'a.example.com':{queued:time(),scheme:'https',priority:3}};smart_plus_last_run=0;}
UCODE
awk '/^function smart_detect_plus_seen\(/ {active=1} /^function smart_detect_process_pending\(/ {exit} active {print}' "$lib/service/watchdog.uc" >> "$work/parent.uc"
cat >> "$work/parent.uc" <<'UCODE'
candidate();dns.ready=false;smart_detect_process_plus(cfg);assert(starts==0,'DNS guard before start');
dns.ready=true;smart_detect_process_plus(cfg);assert(starts==1 && smart_plus_job!=null && applied==0,'start without applying');
smart_detect_process_plus(cfg);assert(starts==1 && applied==0,'one pending worker');
result={act:true,seen:true};smart_detect_process_plus(cfg);assert(applied==1 && smart_plus_job==null,'valid result applied once');
assert(smart_plus_seen['a.example.com']!=null,'RAM cooldown');
smart_plus_seen={};candidate();result=null;smart_detect_process_plus(cfg);dns.signature='b';result={act:true,seen:true};smart_detect_process_plus(cfg);assert(applied==1 && pending_smart_plus['a.example.com']!=null,'stale DNS result discarded');
candidate();result=null;smart_detect_process_plus(cfg);dns.ready=false;smart_detect_process_plus(cfg);dns.ready=true;result={act:true,seen:true};smart_detect_process_plus(cfg);assert(applied==1,'transient DNS outage invalidates result');
candidate();result=null;smart_detect_process_plus(cfg);cfg.smart_detect_sections=['other'];result={act:true,seen:true};smart_detect_process_plus(cfg);assert(applied==1,'selection change invalidates result');cfg.smart_detect_sections=['vpn'];
candidate();result=null;smart_detect_process_plus(cfg);result={defer:true,dns_error:true};smart_detect_process_plus(cfg);assert(applied==1 && smart_detect_dns_state.ready==false,'DNS error defers without cooldown');
assert(starts==5 && stops==5,'every completed job released');
print('PASS: real Plus loop, single worker, valid apply, DNS/selection guards, transient outage, RAM cooldown, DNS defer\n');
UCODE
PATH="$work/bin:$PATH" TACHYON_TEST_COUNT_FILE="$work/count" ucode -L "$lib" -L /usr/lib/tachyon "$work/baseline.uc"
rm -f "$work/count"
PATH="$work/bin:$PATH" TACHYON_TEST_COUNT_FILE="$work/count" TACHYON_SMART_PROBE_DIR="$work/job" ucode -L "$lib" -L /usr/lib/tachyon "$work/probe.uc"
TACHYON_RUNTIME_STATE_DIR="$work/parent" ucode -L "$lib" -L /usr/lib/tachyon "$work/parent.uc"
