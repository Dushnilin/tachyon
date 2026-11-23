#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR="$TACHYON_LIB/tachyon_core/generator.uc"

generate() {
  local fixture="$1"
  local output="$2"
  TACHYON_LIB="$TACHYON_LIB" \
    TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing-state.json" \
    ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture "$fixture" "$output" 192.168.1.1 0 "1"
}

cat >"$WORK_DIR/doh-direct.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_detour_enabled": "0",
    "fakeip": "1"
  },
  "section": [
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#EdgeNode" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/doh-detour.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "1.1.1.1/dns-query" ],
    "dns_fallback_server": [ "9.9.9.9" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_detour_enabled": "1",
    "dns_detour_section": "vpn",
    "fakeip": "1"
  },
  "section": [
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#EdgeNode" ],
      "domain_suffix": [ "example.org" ]
    }
  ]
}
JSON

generate "$WORK_DIR/doh-direct.json" "$WORK_DIR/out-direct.json"
generate "$WORK_DIR/doh-detour.json" "$WORK_DIR/out-detour.json"

ucode -e '
let fs = require("fs");
function assert(cond, msg) {
  if (!cond) {
    warn("FAIL: " + msg + "\n");
    exit(1);
  }
}
function find_tag(list, tag) {
  for (let item in (list || []))
    if (item && item.tag == tag) return item;
  return null;
}

let c1 = json(fs.readfile(ARGV[0]));
assert(c1.route.default_domain_resolver == "dns-resilient",
  "non-detoured DoH must use dns-resilient for route.default_domain_resolver so L3 targets keep DoH, got " + sprintf("%J", c1.route.default_domain_resolver));
assert(c1.dns.final == "dns-resilient",
  "dns.final must target dns-resilient, got " + sprintf("%J", c1.dns.final));
let g1 = find_tag(c1.dns.servers, "dns-resilient");
assert(g1 && g1.type == "group" && g1.mode == "stable" && g1.error_ttl == "30s",
  "c1 must include stable dns-resilient group: " + sprintf("%J", g1));
assert(length(g1.servers) >= 2 && g1.servers[0] == "dns-server" && g1.servers[length(g1.servers) - 1] == "bootstrap-dns-server",
  "c1 dns-resilient must try dns-server first and end with bootstrap-dns-server: " + sprintf("%J", g1));

let c2 = json(fs.readfile(ARGV[1]));
assert(c2.route.default_domain_resolver == "dns-resilient",
  "detoured DoH must keep route.default_domain_resolver on dns-resilient while transport outbounds pin bootstrap");
assert(c2.dns.final == "dns-resilient",
  "c2 dns.final must target dns-resilient");
let g2 = find_tag(c2.dns.servers, "dns-resilient");
assert(g2 && g2.type == "group", "c2 dns-resilient group missing");
assert(g2.servers[0] == "dns-server", "c2 dns-resilient must start with dns-server");
assert(index(g2.servers, "dns-fallback-1") >= 0, "c2 dns-resilient must include dns-fallback-1");
assert(g2.servers[length(g2.servers) - 1] == "bootstrap-dns-server", "c2 dns-resilient must end with bootstrap-dns-server");

let vpn1 = find_tag(c2.outbounds, "vpn-1-out");
assert(vpn1 && vpn1.domain_resolver == "bootstrap-dns-server",
  "c2 proxy outbound vpn-1-out must pin bootstrap-dns-server to prevent DoH detour deadlock: " + sprintf("%J", vpn1));
for (let dtag in [ "direct-out", "bypass-out" ]) {
  let dob = find_tag(c2.outbounds, dtag);
  assert(dob && dob.domain_resolver == null,
    dtag + " must not pin bootstrap domain_resolver: " + sprintf("%J", dob));
}

let fb1 = find_tag(c2.dns.servers, "dns-fallback-1");
assert(fb1 && fb1.type == "udp" && fb1.server == "9.9.9.9" && fb1.detour == null,
  "dns-fallback-1 must be direct UDP without detour: " + sprintf("%J", fb1));

let main2 = find_tag(c2.dns.servers, "dns-server");
assert(main2 && main2.detour == "vpn-out",
  "primary dns-server must keep vpn-out detour, got " + sprintf("%J", main2));

// Fallback DNS IP 9.9.9.9 must never be forced through vpn-out detour route rule
for (let r in (c2.route.rules || [])) {
  if (r.outbound == "vpn-out" && r.ip_cidr != null) {
    let cidrs = type(r.ip_cidr) == "array" ? r.ip_cidr : [ r.ip_cidr ];
    for (let c in cidrs) {
      assert(index("" + c, "9.9.9.9") < 0,
        "fallback DNS 9.9.9.9 must not be detoured via vpn-out: " + sprintf("%J", r));
    }
  }
}
' "$WORK_DIR/out-direct.json" "$WORK_DIR/out-detour.json"

# Issue #479 regression: external L3 interface (bind_interface awg0) and built-in AWG/WireGuard
# must resolve tunneled target domains via dns-resilient, while peer/server transports pin bootstrap-dns-server.
cat >"$WORK_DIR/l3-awg-issue479.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "https://dns.google/dns-query" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_detour_enabled": "1",
    "dns_detour_section": "vpn",
    "fakeip": "1"
  },
  "outbound_source": [
    {
      ".name": "src_iface_awg",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "interface",
      "interface_name": "awg0"
    },
    {
      ".name": "src_vless",
      ".type": "outbound_source",
      "enabled": "1",
      "source_type": "proxy_links",
      "proxy_links": [ "vless://11111111-1111-4111-8111-111111111111@vpn.example.org:443?security=tls#VPN1" ]
    }
  ],
  "section": [
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_source_refs": [ "src_iface_awg", "src_vless" ],
      "domain_suffix": [ "youtube.com" ]
    },
    {
      ".name": "my_awg",
      ".type": "section",
      "enabled": "1",
      "action": "awg",
      "awg_private_key": "aW5ib3VuZF9wcml2YXRlX2tleQ==",
      "awg_peer_public_key": "cGVlcl9wdWJsaWNfa2V5",
      "awg_server_address": "awg.example.org",
      "awg_server_port": "51820",
      "awg_local_address": [ "10.8.1.2/32" ],
      "domain_suffix": [ "youtu.be" ]
    }
  ]
}
JSON

generate "$WORK_DIR/l3-awg-issue479.json" "$WORK_DIR/out-l3-awg.json"

ucode -e '
let fs = require("fs");
function assert(cond, msg) {
  if (!cond) {
    warn("FAIL: " + msg + "\n");
    exit(1);
  }
}
let c3 = json(fs.readfile(ARGV[0]));
assert(c3.route.default_domain_resolver == "dns-resilient",
  "#479: route.default_domain_resolver must use dns-resilient, got " + sprintf("%J", c3.route.default_domain_resolver));

let iface_ob = null;
let vless_ob = null;
for (let ob in (c3.outbounds || [])) {
  if (ob && ob.type == "direct" && ob.bind_interface == "awg0")
    iface_ob = ob;
  if (ob && ob.type == "vless")
    vless_ob = ob;
}
assert(iface_ob != null, "#479: external awg0 direct outbound must be generated");
assert(iface_ob.domain_resolver == null,
  "#479: bind_interface direct outbound must inherit dns-resilient default_domain_resolver, got " + sprintf("%J", iface_ob));
assert(vless_ob != null && vless_ob.domain_resolver == "bootstrap-dns-server",
  "#479: vless outbound must pin bootstrap-dns-server, got " + sprintf("%J", vless_ob));

let wg_ep = null;
for (let ep in (c3.endpoints || [])) {
  if (ep && ep.type == "wireguard")
    wg_ep = ep;
}
assert(wg_ep != null && wg_ep.domain_resolver == "bootstrap-dns-server",
  "#479: wireguard/awg endpoint must pin bootstrap-dns-server for peer resolution, got " + sprintf("%J", wg_ep));
' "$WORK_DIR/out-l3-awg.json"

printf 'dns_resilient_failover_anti_deadlock: OK\n'
