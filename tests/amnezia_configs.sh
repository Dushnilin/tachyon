#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/amnezia_configs.uc"
node "$ROOT_DIR/tests/amnezia_configs_ui.mjs"
printf 'tachyon-core' >"$WORK_DIR/variant"
printf '0.0.7' >"$WORK_DIR/version"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant" SB_VERSION_STATE_FILE="$WORK_DIR/version"
node - "$WORK_DIR" <<'JS'
const fs=require('fs'), path=require('path');
const key=Buffer.from(Array.from({length:32},(_,i)=>i+1)).toString('base64');
const config=`[Interface]\nPrivateKey = ${key}\nAddress = 10.77.0.2/32\nJc = 4\nH1 = 100-200\nS3 = 40\nS4 = 50\nHeaderProtectionKey = ${key}\nRandomTrailers = on\n[Peer]\nPublicKey = ${key}\nEndpoint = 192.0.2.1:51820\n`;
fs.writeFileSync(path.join(process.argv[2],'fixture.json'),JSON.stringify({
 settings:{'.name':'settings','.type':'settings',dns_server:'1.1.1.1',service_listen_address:'127.0.0.1'},
 section:[{'.name':'proxy','.type':'section',enabled:'1',action:'proxy',domain_suffix:['example.org'],
 selector_amnezia_configs:[JSON.stringify({name:'Imported AWG',config})]}]}));
JS
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" '127.0.0.1' '0'
node - "$WORK_DIR/config.json" <<'JS'
const assert=require('assert').strict,fs=require('fs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2]));
const endpoints=cfg.endpoints.filter(e=>e.type==='wireguard');
assert.equal(endpoints.length,1);
const endpoint=endpoints[0];
assert.equal(endpoint.h1,'100-200');assert.equal(endpoint.s3,40);assert.equal(endpoint.s4,50);
assert.equal(endpoint.random_trailers,true);assert(endpoint.header_protection_key);
assert.equal(endpoint.share_link,undefined);assert.equal(endpoint.remark,undefined);
assert(cfg.outbounds.some(o=>o.type==='selector' && o.outbounds.includes(endpoint.tag)));
assert(!cfg.outbounds.some(o=>o.type==='wireguard'));
console.log('PASS: named .conf full generator, native endpoint and selector');
JS
printf 'standard' >"$WORK_DIR/variant"
printf '1.14.2' >"$WORK_DIR/version"
if ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/rejected.json" '127.0.0.1' '0' >"$WORK_DIR/error" 2>&1; then
 fail 'unsupported core must reject Amnezia imports'
fi
printf 'PASS: unsupported core fails before apply\n'
