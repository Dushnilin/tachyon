#!/bin/sh
# Isolated source regressions: no real network, UCI or service changes.
# Extract the installed functions; exercise only a private FIFO, never nft/UCI.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=${TACHYON_LIB:-$root/tachyon/files/usr/lib}
export TACHYON_LIB="$lib"
source=$lib/service/watchdog.uc
work=$(mktemp -d /tmp/tachyon-watchdog-test.XXXXXX)
chmod 700 "$work"
cleanup() {
    if test -f "$work/test.uc"; then
        ucode -L "$lib" "$work/test.uc" cleanup "$work" >/dev/null 2>&1 || true
    fi
    rm -f "$work/shutdown.uc" "$work/test.uc" "$work/raw.uc" "$work/fifo" "$work/listener.pid" "$work/unrelated.pid" "$work/unrelated.txt"
    rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
grep -q '^function stop_honeypot_listeners() {' "$source"
cat > "$work/raw.uc" <<'UCODE'
let fs = require('fs');
let common = require('core.common');
let command_success_from_args = common.command_success_from_args;
let shell_quote = common.shell_quote;
let as_string = common.as_string;
let uloop = null;
function settings() { return {honeypot_ttl:'60'}; }
function remove_file(path) { try { fs.unlink(path); } catch (e) {} }
function log_message(message) { warn(message+'\n'); }
UCODE
awk '/^function stop_honeypot_listeners\(\) \{/ {active=1} active {print} active && /^}/ {exit}' "$source" >> "$work/raw.uc"
awk '/^function setup_honeypot_listener\(\) \{/ {active=1} active {print} active && /^}/ {exit}' "$source" >> "$work/raw.uc"
cat >> "$work/raw.uc" <<'UCODE'
let work = ARGV[1];
function finish() {
    stop_honeypot_listeners();
    let pid = trim(fs.readfile(work+'/unrelated.pid') || '');
    let raw = fs.readfile('/proc/'+pid+'/cmdline') || '';
    let args = split(raw,'\x00');
    if (args[0]=='tail' && args[1]=='-f' && args[2]==work+'/unrelated.txt')
        command_success_from_args(['kill','-TERM',pid]);
}
if (ARGV[0]=='cleanup') { finish(); exit(0); }
let speed = require('dns.speed_test');
let leak = require('diagnostics.leak_check');
assert(type(speed.valid_domain)=='function' && type(leak.get_direct_curl_argv)=='function','worker import contract');
assert(speed.valid_domain('example.com') && !speed.valid_domain('bad domain'),'DNS validation');
fs.writefile(work+'/unrelated.txt','test\n');
system(common.background_command_with_pid(common.command_from_args(['tail','-f',work+'/unrelated.txt']),'>/dev/null','> '+shell_quote(work+'/unrelated.pid')));
sleep(300);
let unrelated = trim(fs.readfile(work+'/unrelated.pid') || '');
assert(unrelated != '', 'unrelated PID');
for (let round=1; round<=3; round++) {
    setup_honeypot_listener(); sleep(300);
    let previous = trim(fs.readfile(work+'/listener.pid') || '');
    assert(previous != '', 'listener PID');
    setup_honeypot_listener(); sleep(300);
    assert(!fs.readfile('/proc/'+previous+'/cmdline'), 'old listener remains after replacement');
    let stopped = stop_honeypot_listeners();
    assert(stopped>=2, 'complete pipeline cleanup');
    assert(stop_honeypot_listeners()==0, 'no residual pipeline stages');
    printf('PASS: honeypot round %d, stopped %d stages\n',round,stopped);
}
assert(fs.readfile('/proc/'+unrelated+'/cmdline'), 'unrelated tail preserved');
finish();
print('PASS: worker import and unrelated process preservation\n');
UCODE
sed -e "s|/tmp/tachyon_honeypot.fifo|$work/fifo|g" \
    -e "s|/var/run/tachyon_honeypot_listener.pid|$work/listener.pid|g" \
    "$work/raw.uc" > "$work/test.uc"
ucode -L "$lib" "$work/test.uc" worker "$work"

cat > "$work/shutdown.uc" <<'UCODE'
let fs={readfile:function(p){return '123';}};
let SUPERVISOR_PID_FILE='supervisor',PID_FILE='worker',PROXY_RESTART_LOCK='lock';
let smart_plus_job={};let commands=[],removed=[];let probes=0,listeners=0;
let smart_probe={cleanup:function(){probes++;}};
let common={kill_orphaned_logread:function(){return 'orphan-fixture';}};
function process_running(pid,name){return true;}
function command_success_from_args(argv){push(commands,argv);return true;}
function remove_file(path){push(removed,path);}
function stop_honeypot_listeners(){listeners++;}
function system(command){assert(command=='orphan-fixture','bounded orphan cleanup');return 0;}
UCODE
awk '/^function stop_runtime\(/ {active=1} active {print} active && /^}/ {exit}' "$source" >> "$work/shutdown.uc"
cat >> "$work/shutdown.uc" <<'UCODE'
stop_runtime(true);
assert(length(commands)==0,'worker shutdown must not signal itself or supervisor');
assert(index(removed,SUPERVISOR_PID_FILE)<0 && index(removed,PID_FILE)>=0,'worker removes only its PID');
assert(probes==1 && listeners==1 && smart_plus_job==null,'worker shutdown releases probe/listeners');
print('PASS: worker shutdown has no recursive signal\n');
UCODE
ucode -L "$lib" "$work/shutdown.uc"
