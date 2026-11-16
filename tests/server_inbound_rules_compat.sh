#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

printf '0.5.7' >"$WORK_DIR/version"
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/version"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": ["77.88.8.8"],
    "service_listen_address": "127.0.0.1",
    "block_doh": "1",
    "fakeip_enabled": "1",
    "routing_strategy": "full_tunnel"
  },
  "section": [
    {
      ".name": "direct_sec",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": ["direct.example"]
    },
    {
      ".name": "vpn_sec",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": ["vless://11111111-1111-4111-8111-111111111111@198.51.100.10:443?type=tcp#node1"],
      "domain_suffix": ["proxied.example"]
    }
  ],
  "server": [
    {
      ".name": "srv1",
      ".type": "server",
      "enabled": "1",
      "protocol": "vless",
      "listen_port": "8443",
      "uuid": "11111111-1111-4111-8111-111111111111",
      "routing_mode": "rules"
    }
  ]
}
JSON

ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" \
  generate-config-fixture "$WORK_DIR/fixture.json" "$WORK_DIR/config.json" "127.0.0.1" "0"

node - "$WORK_DIR/config.json" <<'JS'
const assert = require('assert').strict;
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

const srvTag = 'server-srv1-in';
const srvRouteRules = (cfg.route && cfg.route.rules) || [];
const dnsRules = (cfg.dns && cfg.dns.rules) || [];

// 1. Internal __skip_server_clone metadata must be stripped and block_doh reject rule must NOT be cloned onto server inbound.
for (const r of srvRouteRules) {
  assert.equal(r.__skip_server_clone, undefined, 'internal __skip_server_clone marker must not appear in generated config');
}
const srvDohReject = srvRouteRules.filter(r =>
  r.inbound === srvTag &&
  r.action === 'reject' &&
  Array.isArray(r.ip_cidr) &&
  r.ip_cidr.some(c => c.startsWith('1.1.1.1'))
);
assert.equal(srvDohReject.length, 0, 'block_doh reject rule must not be cloned onto server-*-in');
assert(srvRouteRules.some(r =>
  r.inbound === 'tproxy-in' &&
  r.action === 'reject' &&
  Array.isArray(r.ip_cidr) &&
  r.ip_cidr.some(c => c.startsWith('1.1.1.1'))
), 'tproxy-in must retain block_doh reject rule');

// 2. Non-Tailscale server inbound DNS rule to real DNS must precede FakeIP rules in config.dns.rules.
const srvDnsIdx = dnsRules.findIndex(r =>
  (r.inbound === srvTag || (Array.isArray(r.inbound) && r.inbound.includes(srvTag))) &&
  r.server === 'dns-server' &&
  !r.domain_suffix
);
const sectionFakeipIdx = dnsRules.findIndex(r =>
  r.server === 'fakeip-server' &&
  Array.isArray(r.domain_suffix) &&
  r.domain_suffix.includes('proxied.example')
);
assert(srvDnsIdx >= 0, 'server inbound must be routed to real dns-server before FakeIP rules');
assert(sectionFakeipIdx > srvDnsIdx, 'server inbound dns-server rule must appear before section fakeip-server rules');

// 3. Full-tunnel fallback rule must be cloned onto server inbound in routing_mode=rules.
const srvFullTunnel = srvRouteRules.filter(r =>
  r.inbound === srvTag &&
  r.action === 'route' &&
  r.outbound === 'vpn_sec-out' &&
  !r.domain_suffix && !r.ip_cidr && !r.rule_set && !r.port && !r.protocol
);
assert(srvFullTunnel.length >= 1, 'full_tunnel fallback route must be cloned onto server inbound in rules mode');
console.log('PASS: server inbound rules mode config checks');
JS

# 4. Verify clone_rules_for_inbound handles nested logical rules (>1 level deep).
ucode -L "$TACHYON_LIB" - <<'UC'
let servers = require("tachyon_core.servers");
let cfg = {
    route: {
        rules: [
            {
                type: "logical",
                mode: "and",
                action: "route",
                outbound: "vpn_sec-out",
                rules: [
                    {
                        type: "logical",
                        mode: "or",
                        rules: [
                            { inbound: "tproxy-in" },
                            { domain_suffix: ["nested.example"] }
                        ]
                    },
                    { network: "tcp" }
                ]
            }
        ]
    }
};
servers.clone_rules_for_inbound(cfg, "tproxy-in", "server-srv1-in", "");
if (length(cfg.route.rules) != 2) {
    warn("Expected nested logical rule to be cloned\n");
    exit(1);
}
let cloned = cfg.route.rules[1];
if (cloned.rules[0].rules[0].inbound != "server-srv1-in" || cfg.route.rules[0].rules[0].rules[0].inbound != "tproxy-in") {
    warn("Nested logical inbound rewrite failed\n");
    exit(1);
}
print("PASS: nested logical rule cloning\n");
UC
