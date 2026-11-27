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
assert(g1 && g1.type == "group" && g1.mode == "stable" && g1.error_ttl == "30s" && g1.timeout == "8s",
  "c1 must include stable dns-resilient group with 8s timeout: " + sprintf("%J", g1));
assert(length(g1.servers) == 1 && g1.servers[0] == "dns-server",
  "c1 DoH dns-resilient must contain only encrypted servers (no plain UDP bootstrap leak): " + sprintf("%J", g1));

let c2 = json(fs.readfile(ARGV[1]));
assert(c2.route.default_domain_resolver == "dns-resilient",
  "detoured DoH must keep route.default_domain_resolver on dns-resilient while transport outbounds pin bootstrap");
assert(c2.dns.final == "dns-resilient",
  "c2 dns.final must target dns-resilient");
let g2 = find_tag(c2.dns.servers, "dns-resilient");
assert(g2 && g2.type == "group", "c2 dns-resilient group missing");
assert(length(g2.servers) == 1 && g2.servers[0] == "dns-server",
  "c2 DoH dns-resilient must not mix plain UDP fallbacks or bootstrap: " + sprintf("%J", g2));
assert(index(g2.servers, "dns-fallback-1") < 0 && index(g2.servers, "bootstrap-dns-server") < 0,
  "c2 dns-resilient must exclude plain UDP fallbacks and bootstrap while DoH is active");

let vpn1 = find_tag(c2.outbounds, "vpn-1-out");
assert(vpn1 && vpn1.domain_resolver == "bootstrap-dns-server",
  "c2 proxy outbound vpn-1-out must pin bootstrap-dns-server to prevent DoH detour deadlock: " + sprintf("%J", vpn1));
for (let dtag in [ "direct-out", "bypass-out" ]) {
  let dob = find_tag(c2.outbounds, dtag);
  assert(dob && dob.domain_resolver == null,
    dtag + " must not pin bootstrap domain_resolver: " + sprintf("%J", dob));
}

let health_fb = find_tag(c2.dns.servers, "dns-health-main-2-server");
assert(health_fb && health_fb.type == "udp" && health_fb.server == "9.9.9.9" && health_fb.detour == null,
  "fallback candidate 9.9.9.9 must stay direct UDP without detour for health failover: " + sprintf("%J", health_fb));

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

# Issue #489 regression: multi-DoH primary + UDP fallbacks + bootstrap keeps only
# encrypted servers in dns-resilient; when failover switches main_index to UDP
# fallback, dns-resilient includes UDP fallbacks and bootstrap.
cat >"$WORK_DIR/doh-multi-issue489.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "1.1.1.1/dns-query", "dns.google/dns-query", "dns.adguard-dns.com/dns-query" ],
    "dns_fallback_server": [ "8.8.4.4", "77.88.8.1" ],
    "bootstrap_dns_server": [ "8.8.8.8" ],
    "fallback_wan_main": "0",
    "fakeip": "1"
  },
  "section": [
    {
      ".name": "vpn",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#EdgeNode" ],
      "domain_suffix": [ "youtube.com" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/doh-multi-udp-state.json" <<'JSON'
{
  "version": 1,
  "dns_type": "doh",
  "dns_detour": "",
  "main_servers": [ "1.1.1.1/dns-query", "dns.google/dns-query", "dns.adguard-dns.com/dns-query", "8.8.4.4", "77.88.8.1" ],
  "bootstrap_servers": [ "8.8.8.8" ],
  "main_index": 3,
  "bootstrap_index": 0
}
JSON

generate "$WORK_DIR/doh-multi-issue489.json" "$WORK_DIR/out-489-doh.json"
TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/doh-multi-udp-state.json" \
  ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture "$WORK_DIR/doh-multi-issue489.json" "$WORK_DIR/out-489-udp.json" 192.168.1.1 0 "1"

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

let doh = json(fs.readfile(ARGV[0]));
let gd = find_tag(doh.dns.servers, "dns-resilient");
assert(gd && gd.type == "group", "#489 doh dns-resilient group missing");
assert(length(gd.servers) == 3, "#489 doh dns-resilient must contain all 3 primary DoH servers only: " + sprintf("%J", gd.servers));
for (let tag in gd.servers) {
  let s = find_tag(doh.dns.servers, tag);
  assert(s && s.type == "https", "#489 doh dns-resilient member must be https, got: " + sprintf("%J", s));
}
assert(index(gd.servers, "bootstrap-dns-server") < 0, "#489 doh dns-resilient must exclude UDP bootstrap");
assert(index(gd.servers, "dns-fallback-1") < 0 && index(gd.servers, "dns-fallback-2") < 0,
  "#489 doh dns-resilient must exclude plain UDP fallbacks");

let udp = json(fs.readfile(ARGV[1]));
let gu = find_tag(udp.dns.servers, "dns-resilient");
assert(gu && gu.type == "group", "#489 udp failover dns-resilient group missing");
assert(index(gu.servers, "dns-server") >= 0, "#489 udp failover must include dns-server");
let fb_rem = find_tag(udp.dns.servers, "dns-fallback-1");
assert(index(gu.servers, "dns-fallback-1") >= 0 && fb_rem && fb_rem.server == "77.88.8.1",
  "#489 udp failover must include remaining UDP fallback 77.88.8.1: " + sprintf("%J", gu.servers));
assert(index(gu.servers, "bootstrap-dns-server") >= 0, "#489 udp failover must include bootstrap UDP");
' "$WORK_DIR/out-489-doh.json" "$WORK_DIR/out-489-udp.json"

printf 'dns_resilient_failover_anti_deadlock: OK\n'
