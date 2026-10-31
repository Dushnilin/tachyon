#!/usr/bin/env bash
# Local release/download fixtures; no router, package manager or Internet access.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
cp -R "$TACHYON_LIB" "$WORK_DIR/lib"
export TACHYON_LIB="$WORK_DIR/lib"
export TACHYON_VERSION=1.9.0 TACHYON_RELEASE_REPO=example/tachyon
export TACHYON_SMART_CONNECT_BIN="$WORK_DIR/bin/tachyon-smart-connect"
export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/run"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci"
export TEST_SMART_FIXTURE="$WORK_DIR/release" TEST_SMART_ARCH=x86_64
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run" "$TEST_SMART_FIXTURE/content"
cat > "$TACHYON_UCI_STATE_FILE" <<'UCI'
tachyon.settings=settings
tachyon.settings.engine=tachyon-core
tachyon.settings.smart_detect=1
tachyon.settings.smart_detect_chain=1
UCI
cp "$TACHYON_UCI_STATE_FILE" "$WORK_DIR/uci-before"

mv "$TACHYON_LIB/components/helpers.uc" "$TACHYON_LIB/components/helpers_original.uc"
cat > "$TACHYON_LIB/components/helpers.uc" <<'UC'
let real=require("components.helpers_original");
real.read_openwrt_release_value=function(){return getenv("TEST_SMART_ARCH");};
let original_space_check=real.check_free_disk_space;
real.check_free_disk_space=function(path,size){return getenv("TEST_SMART_NO_SPACE")!="1" && original_space_check(path,size);};
return real;
UC
cat > "$TACHYON_LIB/components/downloader.uc" <<'UC'
let f=require("fs"),c=require("core.common"),dir=getenv("TEST_SMART_FIXTURE");
function log(line){let out=f.open(dir+"/requests","a");out.write(line+"\n");out.close();}
function download(url,path,label){
 log("download "+label+" "+url);
 if(getenv("TEST_SMART_DOWNLOAD_FAIL")=="1")return false;
 if(getenv("TEST_SMART_DELAY")=="1")c.command_success_from_args(["sleep","0.3"]);
 let source=match(url,/\.tar\.gz$/)?"helper.tar.gz":"checksums";
 return c.command_success_from_args(["cp",dir+"/"+source,path]);
}
return {
 fetch_github_release_by_tag_json:function(owner,repo,tag,origin_only){
  assert(origin_only===true,"bootstrap metadata must bypass mirrors and their cache");
  log("release "+owner+"/"+repo+" "+tag);
  return f.readfile(dir+"/release.json") || "";
 },
 download_file_once:function(url,path){assert(!match(url,/\.tar\.gz$/),"origin manifest");return download(url,path,"origin");},
 download_with_retry:function(url,path){assert(match(url,/\.tar\.gz$/),"only verified archives may use mirrors");return download(url,path,"mirrors");}
};
UC

ucode -L "$TACHYON_LIB" -e '
 let m=require("components.smart_connect");
 for(let row in [
  ["mips","mipsel_24kc","mipsel"],["mips64","mipsel_24kc","mipsel"],
  ["mips","mips_24kc","mips"],["mips64","mips64el_mips64r2","mips64el"],
  ["mips64","mips64_octeonplus","mips64"],["x86_64","i386","i386"],
  ["x86_64","x86_64","x86_64"],["aarch64","aarch64_cortex-a53","aarch64"],
  ["x86_64","i386_pentium4","i386"],
  ["aarch64","arm_cortex-a7_neon-vfpv4","armv7"],["armv6l","arm_arm1176jzf-s_vfp","armv6"],
  ["armv5tel","arm_arm926ej-s","armv5"],["riscv64","riscv64_riscv64","riscv64"],
  ["armv7l","","armv7"],["armv6l","","armv6"],["i686","","i386"],
  ["x86_64","powerpc_8540",""],["ppc64","powerpc_8540",""]
 ])assert(m.architecture(row[0],row[1])==row[2],"userspace architecture: "+row[1]);
 let hash=join("",["aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa","aaaaaaaa"]);
 assert(m.checksum(hash+"  wanted\n","wanted")==hash,"exact checksum entry");
 assert(m.checksum(hash+"  ../wanted\n","wanted")=="","no path substitution");
 assert(m.checksum(hash+"  wanted\n"+hash+"  wanted\n","wanted")=="","reject duplicate entries");
 let release={tag_name:"v1.9.0",assets:[{name:"tachyon-smart-connect-mipsel-1.9.0.tar.gz",size:100},{name:"SHA256SUMS-smart-connect.txt"}]};
 assert(m.release_assets(release,"example/tachyon","1.9.0","mipsel")?.name=="tachyon-smart-connect-mipsel-1.9.0.tar.gz","matching backend release");
 assert(!m.release_assets(release,"example/tachyon","1.8.0","mipsel"),"no unrelated version fallback");
 release.assets=slice(release.assets,0,1);
 assert(!m.release_assets(release,"example/tachyon","1.9.0","mipsel"),"manifest required");
 print("PASS: Smart Connect userspace architectures and manifest parsing\n");
'

# A small native ELF exercises installation and executable verification without Go.
cat > "$WORK_DIR/check.c" <<'C'
#include <string.h>
int main(int argc,char **argv) {
 return argc==4 && !strcmp(argv[1],"-check") && !strcmp(argv[2],"-config") ? 0 : 7;
}
C
cc -o "$TEST_SMART_FIXTURE/content/tachyon-smart-connect" "$WORK_DIR/check.c"
make_release() {
 tar -czf "$TEST_SMART_FIXTURE/helper.tar.gz" -C "$TEST_SMART_FIXTURE/content" tachyon-smart-connect
 sha256sum "$TEST_SMART_FIXTURE/helper.tar.gz" | awk '{print $1 "  tachyon-smart-connect-x86_64-1.9.0.tar.gz"}' > "$TEST_SMART_FIXTURE/checksums"
 local size
 size=$(wc -c < "$TEST_SMART_FIXTURE/helper.tar.gz")
 cat > "$TEST_SMART_FIXTURE/release.json" <<JSON
{"tag_name":"v1.9.0","assets":[{"name":"tachyon-smart-connect-x86_64-1.9.0.tar.gz","size":$size},{"name":"SHA256SUMS-smart-connect.txt","size":100}]}
JSON
}
ensure() { ucode -L "$TACHYON_LIB" "$TACHYON_LIB/components/smart_connect.uc" ensure; }
expect_failure() {
 local before
 before=$(sha256sum "$TACHYON_SMART_CONNECT_BIN" | awk '{print $1}')
 if ensure > "$WORK_DIR/failure.log" 2>&1; then fail "installation unexpectedly succeeded: $1"; fi
 grep -q "$1" "$WORK_DIR/failure.log" || { cat "$WORK_DIR/failure.log"; fail "missing failure reason: $1"; }
 [ "$(sha256sum "$TACHYON_SMART_CONNECT_BIN" | awk '{print $1}')" = "$before" ] || fail "failed install changed the previous file"
 [ ! -d "$WORK_DIR/run/smart-connect-install.lock" ] || fail "installation lock leaked"
}
make_release
: > "$TEST_SMART_FIXTURE/requests"
ensure
[ -x "$TACHYON_SMART_CONNECT_BIN" ] || fail "helper not executable"
cmp "$TACHYON_SMART_CONNECT_BIN" "$TEST_SMART_FIXTURE/content/tachyon-smart-connect"
cp "$TEST_SMART_FIXTURE/requests" "$WORK_DIR/requests-before"
ensure
cmp "$WORK_DIR/requests-before" "$TEST_SMART_FIXTURE/requests" || fail "existing helper was downloaded again"
echo 'PASS: automatic installation and offline reuse'

# Turning the feature off never downloads or installs even if no helper exists.
printf original > "$TACHYON_SMART_CONNECT_BIN"
chmod 0644 "$TACHYON_SMART_CONNECT_BIN"
sed -i 's/smart_detect_chain=1/smart_detect_chain=0/' "$TACHYON_UCI_STATE_FILE"
ensure
cmp "$WORK_DIR/requests-before" "$TEST_SMART_FIXTURE/requests" || fail 'disabled mode downloaded a helper'
cp "$WORK_DIR/uci-before" "$TACHYON_UCI_STATE_FILE"

printf original > "$TACHYON_SMART_CONNECT_BIN"
chmod 0644 "$TACHYON_SMART_CONNECT_BIN"
TEST_SMART_DOWNLOAD_FAIL=1 expect_failure 'download failed'
printf '\177ELF' > "$TACHYON_SMART_CONNECT_BIN"
chmod 0755 "$TACHYON_SMART_CONNECT_BIN"
TEST_SMART_DOWNLOAD_FAIL=1 expect_failure 'download failed'
ensure
cmp "$TACHYON_SMART_CONNECT_BIN" "$TEST_SMART_FIXTURE/content/tachyon-smart-connect" || fail 'broken installed ELF was not repaired'
printf original > "$TACHYON_SMART_CONNECT_BIN"
chmod 0644 "$TACHYON_SMART_CONNECT_BIN"
cp "$TEST_SMART_FIXTURE/checksums" "$WORK_DIR/sums-before"
printf '%064d  tachyon-smart-connect-x86_64-1.9.0.tar.gz\n' 0 > "$TEST_SMART_FIXTURE/checksums"
expect_failure 'checksum verification failed'
cp "$WORK_DIR/sums-before" "$TEST_SMART_FIXTURE/checksums"
cp "$TEST_SMART_FIXTURE/release.json" "$WORK_DIR/release-before"
printf '{"tag_name":"v9.0.0","assets":[]}' > "$TEST_SMART_FIXTURE/release.json"
expect_failure 'unavailable in Tachyon 1.9.0'
cp "$WORK_DIR/release-before" "$TEST_SMART_FIXTURE/release.json"
TEST_SMART_ARCH=powerpc_8540 expect_failure 'unsupported router architecture'
TEST_SMART_NO_SPACE=1 expect_failure 'insufficient storage'

mv "$TEST_SMART_FIXTURE/content/tachyon-smart-connect" "$WORK_DIR/native-helper"
ln -s /etc/passwd "$TEST_SMART_FIXTURE/content/tachyon-smart-connect"
make_release
expect_failure 'unexpected helper archive'
rm "$TEST_SMART_FIXTURE/content/tachyon-smart-connect"
printf '#!/bin/sh\nexit 0\n' > "$TEST_SMART_FIXTURE/content/tachyon-smart-connect"
make_release
expect_failure 'not a supported executable'
cp "$WORK_DIR/native-helper" "$TEST_SMART_FIXTURE/content/tachyon-smart-connect"
make_release

# Corrupt a real ELF's machine field while keeping its manifest valid.
python3 - "$TEST_SMART_FIXTURE/content/tachyon-smart-connect" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);data=bytearray(p.read_bytes());data[18:20]=b'\xff\xff';p.write_bytes(data)
PY
make_release
expect_failure 'cannot run on this router'
cp "$WORK_DIR/native-helper" "$TEST_SMART_FIXTURE/content/tachyon-smart-connect"
make_release
echo 'PASS: failed downloads, hashes, releases, architectures and unsafe members preserve old files'

: > "$TEST_SMART_FIXTURE/requests"
export TEST_SMART_DELAY=1
ensure > "$WORK_DIR/parallel-1.log" 2>&1 & first_pid=$!
ensure > "$WORK_DIR/parallel-2.log" 2>&1 & second_pid=$!
wait "$first_pid" || { cat "$WORK_DIR/parallel-1.log"; fail 'first concurrent install'; }
wait "$second_pid" || { cat "$WORK_DIR/parallel-2.log"; fail 'second concurrent install'; }
unset TEST_SMART_DELAY
[ "$(grep -c '^download ' "$TEST_SMART_FIXTURE/requests")" = 2 ] || fail 'concurrent requests downloaded multiple helpers'
cmp "$TACHYON_UCI_STATE_FILE" "$WORK_DIR/uci-before" || fail 'installer changed UCI'

# Lifecycle dependency failures must return before stopping or cleaning old core.
cat > "$WORK_DIR/lifecycle.uc" <<'UC'
let touched=0;
function ensure_smart_connect_helper(){return false;}
function ensure_core_binary_installed(){touched++;}
function start_impl(){touched++;}
function stop_main(){touched++;}
function cleanup_failed_runtime(){touched++;}
function log_message(){}
UC
for fn in validate_start_config start restart; do
 awk -v name="$fn" '$0 ~ "^function " name "\\("{active=1} active{print} active && /^}/{exit}' "$TACHYON_LIB/service/lifecycle.uc" >> "$WORK_DIR/lifecycle.uc"
done
cat >> "$WORK_DIR/lifecycle.uc" <<'UC'
assert(validate_start_config()==1 && start()==1 && restart()==1,"dependency failure propagated");
assert(touched==0,"old runtime stays intact on dependency failure");
print("PASS: concurrent installation, UCI preservation and lifecycle failure sequencing\n");
UC
ucode "$WORK_DIR/lifecycle.uc"
