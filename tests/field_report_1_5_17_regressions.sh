#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

printf 'tachyon-core' >"$WORK_DIR/variant"
printf '0.1.4' >"$WORK_DIR/version"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/version"

# 1 & 2: AmneziaWG JSON array subscriptions (base64 config + type:amneziawg)
# and subscription_filter_exclude_keywords on urltest groups.
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const work = process.argv[2];
const key = Buffer.from(Array.from({length: 32}, (_, i) => i + 1)).toString('base64');
const awgIniNoPeer = `[Interface]\nPrivateKey = ${key}\nAddress = 10.66.0.174/32\nDNS = 1.1.1.1\nMTU = 1280\nS1 = 0\nJc = 4\nJmin = 40\nJmax = 70\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = <b 0x494e5649544520>\nI2 = <b 0x5349502f322e30>\n`;
const awgIniWithPeer = awgIniNoPeer + `[Peer]\nPublicKey = ${key}\nEndpoint = 198.51.100.10:51820\n`;

const subJson = [
  {
    name: 'Страна 1 (Peer in INI)',
    config: Buffer.from(awgIniWithPeer).toString('base64')
  },
  {
    name: 'Страна 2 (Peer in JSON)',
    config: Buffer.from(awgIniNoPeer).toString('base64'),
    endpoint: '198.51.100.20:51820',
    public_key: key
  },
  {
    type: 'amneziawg',
    tag: 'AWG Direct JSON',
    server: '198.51.100.30',
    server_port: 51820,
    private_key: key,
    peer_public_key: key,
    local_address: ['10.66.0.2/32'],
    jc: 4, jmin: 40, jmax: 70, h1: '1', h2: '2', h3: '3', h4: '4',
    i1: '<b 0x494e5649544520>'
  },
  {
    type: 'urltest',
    tag: 'LTE Group',
    outbounds: ['lte-node-1']
  },
  {
    type: 'vless',
    tag: 'lte-node-1',
    server: '198.51.100.40',
    server_port: 443,
    uuid: '11111111-1111-1111-1111-111111111111'
  }
];
fs.writeFileSync(path.join(work, 'raw_sub.json'), JSON.stringify(subJson));
fs.writeFileSync(path.join(work, 'fixture.json'), JSON.stringify({
  settings: {'.name': 'settings', '.type': 'settings', dns_server: '1.1.1.1', service_listen_address: '127.0.0.1'},
  section: [{
    '.name': 'proxy', '.type': 'section', enabled: '1', action: 'proxy',
    domain_suffix: ['example.org'],
    subscription_urls: ['https://example.com/sub'],
    subscription_filter_exclude_keywords: ['LTE']
  }]
}));
JS

mkdir -p "$WORK_DIR/subscriptions"
CACHE="$WORK_DIR/subscriptions/proxy-subscription-1"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/parser.uc" normalize-content-validated "$WORK_DIR/raw_sub.json" "$CACHE.json"
printf '%s' 'https://example.com/sub' >"$CACHE.url"
printf '%s' 'Happ' >"$CACHE.user_agent"

TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" '127.0.0.1' '0'

node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const assert = require('assert').strict;
const path = require('path');
const work = process.argv[2];
const cfg = JSON.parse(fs.readFileSync(path.join(work, 'config.json')));
const wgEndpoints = (cfg.endpoints || []).filter(e => e.type === 'wireguard');
assert.equal(wgEndpoints.length, 3, 'All 3 AWG JSON formats should produce wireguard endpoints');
for (const ep of wgEndpoints) {
  assert.equal(ep.jc, 4);
  assert.equal(ep.i1, '<b 0x494e5649544520>');
  assert.equal(ep.amnezia, undefined, 'tachyon-core uses flat AWG fields, not nested amnezia object');
}
const allTags = (cfg.outbounds || []).map(o => o.tag);
assert(!allTags.some(t => t.includes('LTE')), 'LTE urltest group must be excluded by subscription_filter_exclude_keywords');
assert(!allTags.some(t => t.includes('lte-node-1')), 'Orphaned hidden child of excluded LTE group must also be excluded');
JS

# 1b: Issue #203 - AmneziaWG JSON array subscription with hidden [Peer]:
#     - Recovers [Peer] from HTTP headers (X-Peer-Public-Key / X-Endpoint) or nested peer object
#     - Sets get_last_normalize_error() = "incomplete_awg_missing_peer" when [Peer] is completely absent
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const work = process.argv[2];
const key = Buffer.from(Array.from({length: 32}, (_, i) => i + 1)).toString('base64');
const awgIniNoPeer = `[Interface]\nPrivateKey = ${key}\nAddress = 10.66.0.174/32\nDNS = 1.1.1.1\nMTU = 1280\nS1 = 0\nJc = 4\nJmin = 40\nJmax = 70\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = <b 0x494e5649544520>\nI2 = <b 0x5349502f322e30>\n`;

fs.writeFileSync(path.join(work, 'awg_missing_peer.json'), JSON.stringify([
  { name: 'Страна 1', config: Buffer.from(awgIniNoPeer).toString('base64') }
]));
fs.writeFileSync(path.join(work, 'awg_headers.txt'),
  `HTTP/2 200\r\nX-Peer-Public-Key: ${key}\r\nX-Endpoint: 198.51.100.99:51820\r\n`
);
JS

WORK_DIR="$WORK_DIR" ucode -L "$TACHYON_LIB" -e '
let parser = require("subscription.parser");
let work = getenv("WORK_DIR");
let ok_no_hdr = parser.normalize_content_validated(work + "/awg_missing_peer.json", work + "/awg_out_fail.json");
if (ok_no_hdr)
    die("Expected incomplete AWG subscription without [Peer] or headers to fail validation");
if (parser.get_last_normalize_error() != "incomplete_awg_missing_peer")
    die("Expected incomplete_awg_missing_peer error reason, got: " + parser.get_last_normalize_error());

let ok_with_hdr = parser.normalize_content_validated(work + "/awg_missing_peer.json", work + "/awg_out_ok.json", work + "/awg_headers.txt");
if (!ok_with_hdr)
    die("Expected AWG subscription with X-Peer-Public-Key and X-Endpoint headers to succeed");
'

# 1c: Issue #203 - Common Network / Happ AmneziaWG format: array of { type: 'amneziawg', servers: [ { name, config } ] }
#     where config contains both [Interface] and [Peer]
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const work = process.argv[2];
const key = Buffer.from(Array.from({length: 32}, (_, i) => i + 1)).toString('base64');
const awgIniFull = `[Interface]\nPrivateKey = ${key}\nAddress = 10.0.0.0/32\nDNS = 1.1.1.1\nMTU = 1280\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = <b 0x494e5649544520>\n\n[Peer]\nPublicKey = ${key}\nEndpoint = 195.34.67.36:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n`;

fs.writeFileSync(path.join(work, 'awg_common_network.json'), JSON.stringify([
  {
    type: 'amneziawg',
    version: 1,
    servers: [
      { name: '🇨🇦 Канада lines', config: Buffer.from(awgIniFull).toString('base64') }
    ]
  }
]));

fs.writeFileSync(path.join(work, 'awg_common_network_object.json'), JSON.stringify({
  type: 'amneziawg',
  version: 1,
  servers: [
    { name: '🇩🇪 Германия lines', config: Buffer.from(awgIniFull).toString('base64') }
  ]
}));

fs.writeFileSync(path.join(work, 'awg_common_network_wrapper_peer.json'), JSON.stringify([
  {
    type: 'amneziawg',
    version: 1,
    endpoint: '195.34.67.36:51820',
    public_key: key,
    servers: [
      { name: 'Страна с пиром в родителе', config: Buffer.from(`[Interface]\nPrivateKey = ${key}\nAddress = 10.0.0.0/32\nJc = 4\n`).toString('base64') }
    ]
  }
]));
JS

WORK_DIR="$WORK_DIR" ucode -L "$TACHYON_LIB" -e '
let parser = require("subscription.parser");
let work = getenv("WORK_DIR");

let ok_cn = parser.normalize_content_validated(work + "/awg_common_network.json", work + "/awg_cn_out.json");
if (!ok_cn)
    die("Expected Common Network AmneziaWG array subscription with servers[] to normalize successfully");

let ok_obj = parser.normalize_content_validated(work + "/awg_common_network_object.json", work + "/awg_obj_out.json");
if (!ok_obj)
    die("Expected top-level object with servers[] to normalize successfully");

let ok_wrap = parser.normalize_content_validated(work + "/awg_common_network_wrapper_peer.json", work + "/awg_wrap_out.json");
if (!ok_wrap)
    die("Expected subscription with peer in wrapper object to normalize successfully");
'

node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const assert = require('assert').strict;
const path = require('path');
const work = process.argv[2];

const cnData = JSON.parse(fs.readFileSync(path.join(work, 'awg_cn_out.json')));
assert.equal(cnData.outbounds.length, 1);
assert.equal(cnData.outbounds[0].tag, '🇨🇦 Канада lines');
assert.equal(cnData.outbounds[0].peers[0].address, '195.34.67.36');
assert.equal(cnData.outbounds[0].jc, 4);

const objData = JSON.parse(fs.readFileSync(path.join(work, 'awg_obj_out.json')));
assert.equal(objData.outbounds.length, 1);
assert.equal(objData.outbounds[0].tag, '🇩🇪 Германия lines');

const wrapData = JSON.parse(fs.readFileSync(path.join(work, 'awg_wrap_out.json')));
assert.equal(wrapData.outbounds.length, 1);
assert.equal(wrapData.outbounds[0].peers[0].address, '195.34.67.36');
JS

# 1f: Issue #203 - Mixed subscription with amneziawg:// and vless:// share links (raw and base64-encoded)
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const work = process.argv[2];
const key = Buffer.from(Array.from({length: 32}, (_, i) => i + 1)).toString('base64');
const awgIni = `[Interface]\nPrivateKey = ${key}\nAddress = 10.100.1.98/32\nDNS = 1.1.1.1\nMTU = 1280\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = <b 0x494e5649544520>\n\n[Peer]\nPublicKey = ${key}\nEndpoint = 195.34.67.36:51820\nAllowedIPs = 0.0.0.0/0\n`;
const awgLink = 'amneziawg://' + Buffer.from(awgIni).toString('base64') + '#%F0%9F%87%A8%F0%9F%87%A6%20%D0%9A%D0%B0%D0%BD%D0%B0%D0%B4%D0%B0';
const vlessLink = 'vless://982cb09c-fc2e-4de4-ba50-8db12657653e@de1.commonnet.work:443?encryption=none&security=reality&type=tcp&sni=de1.commonnet.work&fp=firefox&pbk=LrFc82uBX_s2DMT3kIa7WF2EdU6EAxiiyLgkOotfQmk&sid=873b97ff19bb344f&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F';

const uriList = `${awgLink}\n${vlessLink}\n`;
fs.writeFileSync(path.join(work, 'mixed_uri_list.txt'), uriList);
const b64Sub = Buffer.from(uriList).toString('base64');
fs.writeFileSync(path.join(work, 'mixed_b64_sub.txt'), b64Sub);
JS

WORK_DIR="$WORK_DIR" ucode -L "$TACHYON_LIB" -e '
let parser = require("subscription.parser");
let work = getenv("WORK_DIR");

let ok_uri = parser.normalize_content_validated(work + "/mixed_uri_list.txt", work + "/mixed_uri_out.json");
if (!ok_uri)
    die("Expected amneziawg:// and vless:// URI list to normalize successfully");

let ok_b64 = parser.normalize_content_validated(work + "/mixed_b64_sub.txt", work + "/mixed_b64_out.json");
if (!ok_b64)
    die("Expected base64-encoded amneziawg:// + vless:// list to normalize successfully");
'

node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const assert = require('assert').strict;
const path = require('path');
const work = process.argv[2];

const uriData = JSON.parse(fs.readFileSync(path.join(work, 'mixed_uri_out.json')));
assert.equal(uriData.outbounds.length, 2);
assert.equal(uriData.outbounds[0].type, 'wireguard');
assert.equal(uriData.outbounds[0].tag, '🇨🇦 Канада');
assert.equal(uriData.outbounds[0].jc, 4);
assert.equal(uriData.outbounds[1].type, 'vless');

const b64Data = JSON.parse(fs.readFileSync(path.join(work, 'mixed_b64_out.json')));
assert.equal(b64Data.outbounds.length, 2);
assert.equal(b64Data.outbounds[0].type, 'wireguard');
assert.equal(b64Data.outbounds[1].type, 'vless');
JS

# 3: zapret2 UDP port-only profile automatic --payload=all injection (#177)
ucode -L "$TACHYON_LIB" -e '
let z2 = require("providers.zapret2.common");
let nfq = require("providers.nfqueue.runtime");
let cfg = z2.config();

let opt1 = join(" ", cfg.prepare_strategy_args("--filter-udp=50000-50099 --lua-desync=fake:blob=quic_initial_www_google_com:repeats=6"));
if (index(opt1, "--payload=all") < 0)
    die("Expected --payload=all in single UDP port-only profile: " + opt1);

let quic_opt = join(" ", cfg.prepare_strategy_args("--filter-udp=443 --filter-l7=quic --lua-desync=fake:blob=quic_initial_www_google_com:repeats=6"));
if (index(quic_opt, "--payload=all") >= 0)
    die("Did not expect --payload=all when --filter-l7=quic is set: " + quic_opt);

let multi = join(" ", nfq.strategy_words("--filter-tcp=443 --lua-desync=multisplit --new --filter-udp=9000-9100,20000-65535 --lua-desync=fake:blob=0x00000000:repeats=2"));
if (index(multi, "--filter-udp=9000-9100,20000-65535 --payload=all --lua-desync=fake") < 0)
    die("Expected --payload=all before --lua-desync in --new UDP port-only profile: " + multi);
'

# 4: Tailscale exit_node in sing-box endpoint mode rejected on tachyon-core
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >&2
SH
chmod +x "$WORK_DIR/bin/logger"
export PATH="$WORK_DIR/bin:$PATH"

node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const path = require('path');
const work = process.argv[2];
const makeFixture = (exitNode) => ({
  settings: {'.name': 'settings', '.type': 'settings', dns_server: '1.1.1.1', service_listen_address: '127.0.0.1'},
  server: [{
    '.name': 'ts_srv', '.type': 'server', enabled: '1', protocol: 'tailscale',
    tailscale_mode: 'singbox', tailscale_advertise_exit_node: exitNode
  }],
  section: [{
    '.name': 'ts_sec', '.type': 'section', enabled: '1', action: 'proxy',
    outbound_server: 'ts_srv', domain_suffix: ['example.org']
  }]
});
fs.writeFileSync(path.join(work, 'ts_bad.json'), JSON.stringify(makeFixture('1')));
fs.writeFileSync(path.join(work, 'ts_good.json'), JSON.stringify(makeFixture('0')));
JS

if ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-section-action-variant-support "$WORK_DIR/ts_bad.json" "" "0.1.3" >"$WORK_DIR/ts_err" 2>&1; then
  fail 'tailscale_advertise_exit_node in singbox mode must be rejected on tachyon-core'
fi
grep -Fq 'tailscale_advertise_exit_node' "$WORK_DIR/ts_err" || fail 'expected tailscale_advertise_exit_node error message'

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-section-action-variant-support "$WORK_DIR/ts_good.json" "" "0.1.3" || fail 'tailscale without exit_node should pass'

# 5: Cookie engine enabled in subscription/cache.uc
grep -Fq '"-b", "/dev/null"' "$TACHYON_LIB/subscription/cache.uc" || fail 'expected -b /dev/null in subscription/cache.uc'

# 7) Server Inbounds:
#    - inbound-item-json must NOT report listening=1 when runtime_ok=0 (e.g. when a user sets port 1602 which is tproxy-in)
#    - validator rejects reserved internal port 1602 on server sections
#    - TLS server inbound without existing cert file gets fallback certificate so tachyon-core does not fail to bind port 8443
INBOUND_ITEM_JSON=$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/status.uc" -- inbound-item-json '{"exists":0}' 'srv1' 'MyServer' 'vless' 'rules' 'srv1-server-in' '0.0.0.0' '1602' '' '' 'vless' 'tcp' '1' '1' '1' '0' '' '0' '-1' '-1' '-1' '0')
printf '%s\n' "$INBOUND_ITEM_JSON" | grep -Eq '"runtime_ok":[[:space:]]*0' || fail "expected runtime_ok=0: $INBOUND_ITEM_JSON"
printf '%s\n' "$INBOUND_ITEM_JSON" | grep -Eq '"listening":[[:space:]]*0' || fail "expected listening=0 when runtime_ok=0 (port 1602 tproxy-in false positive): $INBOUND_ITEM_JSON"

cat >"$WORK_DIR/srv_1602_fixture.json" <<'EOF'
{
  "settings": {
    "dns_type": "udp",
    "dns_server": ["8.8.8.8"],
    "bootstrap_dns_server": ["1.1.1.1"]
  },
  "server": [
    {
      ".name": "srv_bad_port",
      "enabled": "1",
      "protocol": "vless",
      "listen": "0.0.0.0",
      "listen_port": "1602",
      "routing_mode": "direct"
    }
  ],
  "section": []
}
EOF
if ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/srv_1602_fixture.json" "" >"$WORK_DIR/srv_1602.err" 2>&1; then
    fail 'expected validator to reject server inbound on reserved port 1602'
fi
grep -Fq 'reserved internal Tachyon port 1602' "$WORK_DIR/srv_1602.err" || fail "unexpected error for port 1602: $(cat "$WORK_DIR/srv_1602.err")"

TLS_SRV_OUT=$(ucode -L "$TACHYON_LIB" -e '
    let servers = require("tachyon_core.servers");
    let cfg = { inbounds: [], endpoints: [], dns: { servers: [], rules: [] }, route: { rules: [] } };
    servers.add_server(cfg, {
        ".name": "tuic8443",
        enabled: "1",
        protocol: "tuic",
        security: "tls",
        listen: "0.0.0.0",
        listen_port: "8443",
        tls_certificate_path: "/nonexistent/cert.crt",
        tls_key_path: "/nonexistent/key.key"
    });
    printf("%J\n", cfg.inbounds[0]);
')
printf '%s\n' "$TLS_SRV_OUT" | grep -Eq '"certificate":[[:space:]]*\[' || fail "expected fallback inline certificate when cert file is missing: $TLS_SRV_OUT"

# ---------------------------------------------------------------------------
# 6. Bug 1 & Bug 4 (1.5.16 report):
#    - sing-box-json / Xray JSON subscription with Shadowsocks + WebSocket
#    - UCI local SOCKS section (`type='socks'`) generates valid outbound
# ---------------------------------------------------------------------------
cat >"$WORK_DIR/ss_ws_sub.json" <<'EOF'
{
  "format": "sing-box-json",
  "outbounds": [
    {
      "tag": "SS-WS-Node",
      "protocol": "shadowsocks",
      "settings": {
        "servers": [
          {
            "address": "198.51.100.77",
            "port": 443,
            "method": "chacha20-ietf-poly1305",
            "password": "secret-password"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "cdn.example.com"
        },
        "wsSettings": {
          "path": "/ws-stream",
          "headers": {
            "Host": "cdn.example.com"
          }
        }
      }
    }
  ]
}
EOF
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/parser.uc" normalize-content-validated "$WORK_DIR/ss_ws_sub.json" "$WORK_DIR/ss_ws_out.json" || fail 'failed to normalize Shadowsocks+WS subscription JSON'
grep -Eq '"type":[[:space:]]*"shadowsocks"' "$WORK_DIR/ss_ws_out.json" || fail "expected shadowsocks type in normalized JSON: $(cat "$WORK_DIR/ss_ws_out.json")"
grep -Eq '"plugin":[[:space:]]*"v2ray-plugin"' "$WORK_DIR/ss_ws_out.json" || fail "expected v2ray-plugin in normalized JSON: $(cat "$WORK_DIR/ss_ws_out.json")"
grep -Fq 'mode=websocket;tls;host=cdn.example.com;path=/ws-stream' "$WORK_DIR/ss_ws_out.json" || fail "expected plugin_opts in normalized JSON: $(cat "$WORK_DIR/ss_ws_out.json")"

SOCKS_UCI_OUT=$(ucode -L "$TACHYON_LIB" -e '
    let outbounds_mod = require("tachyon_core.generator_outbounds");
    let routes_mod = require("tachyon_core.generator_routes");
    let ctx = {
        outbounds: outbounds_mod,
        routes: routes_mod,
        runtime_settings: function() { return {}; },
        runtime_generate_unsupported: function(msg) { die(msg); },
        atomic_write_json_file: function() { return true; },
        is_sb_1_14_plus: function() { return true; }
    };
    outbounds_mod.init(ctx);
    routes_mod.init(ctx);
    let cfg = { outbounds: [], endpoints: [], dns: { servers: [], rules: [] }, route: { rules: [] } };
    let taken = {};
    let sec = {
        ".name": "XraySection",
        enabled: "1",
        action: "connection",
        type: "socks",
        server: "127.0.0.1",
        server_port: "1080"
    };
    routes_mod.add_outbound_for_section(cfg, sec, taken, [sec]);
    printf("%J\n", cfg.outbounds);
')
printf '%s\n' "$SOCKS_UCI_OUT" | grep -Eq '"type":[[:space:]]*"socks"' || fail "expected socks outbound from inline UCI section: $SOCKS_UCI_OUT"
printf '%s\n' "$SOCKS_UCI_OUT" | grep -Eq '"server_port":[[:space:]]*1080' || fail "expected port 1080 in inline UCI socks outbound: $SOCKS_UCI_OUT"

printf 'All 1.5.17 field report & issue regression checks passed\n'
