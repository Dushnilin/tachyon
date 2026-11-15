#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# 1. Fail on any [\s] inside regex character classes across active .uc code.
node - "$ROOT_DIR/tachyon/files" <<'JS'
const fs = require('fs');
const path = require('path');

function walk(dir, out = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else if (ent.name.endsWith('.uc')) out.push(p);
  }
  return out;
}

const hits = [];
for (const file of walk(process.argv[2])) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  lines.forEach((line, idx) => {
    const stripped = line.replace(/^\s*\/\/.*$/, '');
    if (/\[(?:[^\]\\]|\\.)*\\s(?:[^\]\\]|\\.)*\]/.test(stripped)) {
      hits.push(`${path.relative(process.argv[2], file)}:${idx + 1}: ${line.trim()}`);
    }
  });
}
if (hits.length > 0) {
  console.error('Found \\s inside [...] character class in ucode (OpenWrt ERE treats it as literal \\ and s):\n' + hits.join('\n'));
  process.exit(1);
}
console.log('PASS: zero [\\s] character classes in active .uc code');
JS

# 2. Verify space-separated WARP local addresses and reserved bytes split cleanly in full generator.
printf 'tachyon-core' >"$WORK_DIR/variant"
printf '0.0.7' >"$WORK_DIR/version"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant" SB_VERSION_STATE_FILE="$WORK_DIR/version"

node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1)).toString('base64');
function makeFixture(ipv6Mode) {
  return JSON.stringify({
    settings: { '.name': 'settings', '.type': 'settings', dns_server: '1.1.1.1', service_listen_address: '127.0.0.1', ipv6_mode: ipv6Mode },
    outbound_source: [{
      '.name': 'warp_src',
      '.type': 'outbound_source',
      enabled: '1',
      source_type: 'warp',
      warp_private_key: key,
      warp_public_key: key,
      warp_server: 'engage.cloudflareclient.com',
      warp_port: '2408',
      warp_local_address: ['172.16.0.2/32 2606:4700:110::2/128'],
      warp_reserved: '10 20 30'
    }],
    section: [{
      '.name': 'proxy',
      '.type': 'section',
      enabled: '1',
      action: 'proxy',
      domain_suffix: ['example.org'],
      outbound_source_refs: ['warp_src']
    }]
  });
}
fs.writeFileSync(path.join(process.argv[2], 'fixture-v6.json'), makeFixture('dual_stack'));
fs.writeFileSync(path.join(process.argv[2], 'fixture-v4.json'), makeFixture('off'));
JS

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture-v6.json" "$WORK_DIR/config-v6.json" '127.0.0.1' '0'
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture "$WORK_DIR/fixture-v4.json" "$WORK_DIR/config-v4.json" '127.0.0.1' '0'

node - "$WORK_DIR/config-v6.json" "$WORK_DIR/config-v4.json" <<'JS'
const assert = require('assert').strict;
const fs = require('fs');
const cfg6 = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const wg6 = (cfg6.endpoints || []).find(e => e.type === 'wireguard');
assert(wg6, 'expected wireguard endpoint for warp section (ipv6=1)');
assert.deepEqual(wg6.address, ['172.16.0.2/32', '2606:4700:110::2/128']);
assert.equal(wg6.peers.length, 1);
assert.deepEqual(wg6.peers[0].reserved, [10, 20, 30]);

const cfg4 = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const wg4 = (cfg4.endpoints || []).find(e => e.type === 'wireguard');
assert(wg4, 'expected wireguard endpoint for warp section (ipv6=0)');
assert.deepEqual(wg4.address, ['172.16.0.2/32']);
console.log('PASS: WARP space-separated IPv4+IPv6 local_address and reserved bytes parsed cleanly');
JS
