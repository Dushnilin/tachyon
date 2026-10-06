#!/bin/sh
# Exercise the actual API adapter against a fixture UCI owner, never live UCI.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=${TACHYON_LIB:-$root/tachyon/files/usr/lib}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cat > "$work/test.uc" <<'UCODE'
let fs=require('fs');let common=require('core.common');
let as_string=common.as_string;let object_or_empty=common.object_or_empty;
let live={'.type':'priority_group',check_timeout:'3s'},captured=null;
let require=function(name){assert(name=='core.uci','expected owner lookup');return {get_all:function(config,id){assert(id=='fixture','owned group');return live;}};};
function module_capture(argv){captured=argv;return {status:0,output:'{"delay":123}'};}
UCODE
for fn in duration_to_milliseconds parse_delay_output clash_probe; do
    awk -v name="$fn" '$0 ~ "^function " name "\\(" {active=1} active {print} active && /^}/ {exit}' "$lib/singbox/priority.uc" >> "$work/test.uc"
done
cat >> "$work/test.uc" <<'UCODE'
let group={id:'fixture',check_timeout:'20s',health_url:'https://health.example/'};
assert(clash_probe('test-out',group).alive && captured[2]=='3000','current UCI wins over stale cache');
live.check_timeout='4s';clash_probe('test-out',group);assert(captured[2]=='4000','next probe observes updated timeout');
live={};clash_probe('test-out',group);assert(captured[2]=='20000','unowned fixture keeps cache fallback');
print('PASS: current Priority UCI timeout and fixture fallback\n');
UCODE
ucode -L "$lib" "$work/test.uc"
