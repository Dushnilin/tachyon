#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

printf 'lx' >"$WORK_DIR/variant"
printf '1.14.2-lx.11' >"$WORK_DIR/version"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/version"

for fixture in amnezia_subscription amnezia_manual amnezia_container amnezia_labels; do
  ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/$fixture.uc"
done
printf 'standard' >"$WORK_DIR/variant"
printf '1.14.2' >"$WORK_DIR/version"
ucode -L "$TACHYON_LIB" "$ROOT_DIR/tests/amnezia_manual.uc" --reject-non-lx
printf 'lx' >"$WORK_DIR/variant"
printf '1.14.2-lx.11' >"$WORK_DIR/version"

# Exercise the public subscription parser and full config generator, not only
# the helper modules. All credentials are deterministic synthetic test data.
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const work = process.argv[2];
const key = Buffer.from(Array.from({length:32}, (_, i) => i + 1)).toString('base64');
const conf = `[Interface]\nPrivateKey = ${key}\nAddress = 10.77.0.2/32\nJc = 4\nH1 = 100-200\nRandomTrailers = on\nDisableCookies = on\n[Peer]\nPublicKey = ${key}\nEndpoint = 192.0.2.1:51820\n`;
// Buffer's 'base64url' encoding only exists on Node >= 15, and the test image
// ships Node 12. Encode by hand so the fixture matches what ucode expects.
const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const link = 'vpn://' + b64url(Buffer.from(conf)) + '#Test%20AWG';
fs.writeFileSync(path.join(work, 'links'), link + '\nhy2://test@example.com:443#Existing\n');
fs.writeFileSync(path.join(work, 'fixture.json'), JSON.stringify({
  settings:{'.name':'settings','.type':'settings',dns_server:'1.1.1.1',service_listen_address:'127.0.0.1'},
  section:[{'.name':'proxy','.type':'section',enabled:'1',action:'proxy',domain_suffix:['example.org'],
    subscription_urls:['https://example.com/sub'],selector_proxy_links:[link]}]
}));
JS
mkdir -p "$WORK_DIR/subscriptions"
PARSER="$TACHYON_LIB/subscription/parser.uc"
CACHE="$WORK_DIR/subscriptions/proxy-subscription-1"
ucode -L "$TACHYON_LIB" "$PARSER" normalize-uri-list "$WORK_DIR/links" "$CACHE.json"
printf '%s' 'https://example.com/sub' >"$CACHE.url"
printf '%s' 'Happ' >"$CACHE.user_agent"
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" '127.0.0.1' '0'
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const assert = require('assert').strict;
const path = require('path');
const work = process.argv[2];
const parsed = JSON.parse(fs.readFileSync(path.join(work,'subscriptions/proxy-subscription-1.json')));
assert.equal(parsed.outbounds.length, 2);
assert.equal(parsed.outbounds[1].type, 'hysteria2');
const cfg = JSON.parse(fs.readFileSync(path.join(work,'config.json')));
const endpoints = cfg.endpoints.filter(e => e.type === 'wireguard');
assert.equal(endpoints.length, 2, 'manual and subscription AWG endpoints');
for (const endpoint of endpoints) {
  assert.equal(endpoint.h1, '100-200');
  assert.equal(endpoint.random_trailers, true);
  assert.equal(endpoint.disable_cookies, true);
  assert.equal(endpoint.share_link, undefined);
  assert.equal(endpoint.remark, undefined);
  assert(cfg.outbounds.some(o => o.type === 'selector' && o.outbounds.includes(endpoint.tag)));
}
assert(!cfg.outbounds.some(o => o.type === 'wireguard'));
assert(cfg.outbounds.some(o => o.type === 'hysteria2'));
JS
printf 'standard' >"$WORK_DIR/variant"
printf '1.14.2' >"$WORK_DIR/version"
if TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/rejected.json" '127.0.0.1' '0' >"$WORK_DIR/error" 2>&1; then
  fail 'full vpn:// generation must reject non-LX core'
fi
grep -Fq 'only with sing-box-lx' "$WORK_DIR/error" || fail 'expected LX compatibility error'
printf 'Amnezia subscription and full generator checks passed\n'
