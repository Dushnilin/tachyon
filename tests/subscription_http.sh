#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER_UC="$TACHYON_LIB/subscription/parser.uc"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Test parsing http:// and https:// share links
cat >"$WORK_DIR/http_links.txt" <<'EOF'
http://admin:secret123@192.168.1.50:8080#My-Http-Proxy
https://user:pass@proxy.example.com:8443?sni=secure.example.com&insecure=1#My-Https-Proxy
EOF

output_json="$WORK_DIR/parsed.json"
ucode -L "$TACHYON_LIB" "$PARSER_UC" normalize-uri-list "$WORK_DIR/http_links.txt" "$output_json"

ucode -e '
let fs = require("fs");
let parsed = json(fs.readfile("'"$output_json"'"));
let list = parsed.outbounds || [];
if (length(list) != 2) {
    print("Expected 2 outbounds, got " + length(list) + "\n");
    exit(1);
}
let http = list[0];
if (http.type != "http" || http.server != "192.168.1.50" || http.server_port != 8080 ||
    http.username != "admin" || http.password != "secret123" || http.tag != "My-Http-Proxy") {
    print("HTTP outbound fields incorrect: " + sprintf("%J", http) + "\n");
    exit(2);
}

let https = list[1];
if (https.type != "http" || https.server != "proxy.example.com" || https.server_port != 8443 ||
    https.username != "user" || https.password != "pass" || https.tag != "My-Https-Proxy" ||
    !https.tls || !https.tls.enabled || https.tls.server_name != "secure.example.com" || !https.tls.insecure) {
    print("HTTPS outbound fields incorrect: " + sprintf("%J", https) + "\n");
    exit(3);
}
' || fail "HTTP/HTTPS share link parsing failed"

# 2. Test serializing http/https outbound to share link
ucode -L "$TACHYON_LIB" -e '
let share = require("subscription.share_link");
let http_out = {
    type: "http",
    server: "1.2.3.4",
    server_port: 8080,
    username: "alice",
    password: "foo",
    tag: "test-http"
};
let link = share.serialize_outbound_link(http_out);
if (link != "http://alice:foo@1.2.3.4:8080#test-http") {
    print("Failed http serialize: " + link + "\n");
    exit(1);
}

let https_out = {
    type: "http",
    server: "secure.net",
    server_port: 443,
    tls: {
        enabled: true,
        server_name: "sni.secure.net",
        insecure: true
    },
    tag: "test-https"
};
let link_tls = share.serialize_outbound_link(https_out);
if (link_tls != "https://secure.net:443?sni=sni.secure.net&insecure=1#test-https") {
    print("Failed https serialize: " + link_tls + "\n");
    exit(2);
}
' || fail "HTTP/HTTPS serialization failed"

# 3. Test UDP reject rule generation for HTTP outbound to prevent sing-box crash
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "http_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"tag\":\"http-out\",\"type\":\"http\",\"server\":\"1.2.3.4\",\"server_port\":8080}"
      ],
      "domain_suffix": [ "example.com" ]
    }
  ]
}
JSON

gen_out="$WORK_DIR/gen.json"
mkdir -p "$gen_out.section-cache" "$gen_out.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$gen_out" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$gen_out"'"));
let rules = cfg.route.rules || [];
let found_reject = false;
let found_http_route = false;

for (let r in rules) {
    if (r.network == "udp" && (r.action == "reject" || r.outbound == "block")) {
        found_reject = true;
    }
    if (r.outbound == "http_sec-out") {
        found_http_route = true;
    }
}

if (!found_reject) {
    print("ERROR: Expected UDP reject rule before HTTP outbound route rule!\n");
    exit(1);
}
if (!found_http_route) {
    print("ERROR: Expected route rule for http_sec-out!\n");
    exit(2);
}
' || fail "UDP reject rule for HTTP outbound failed"

printf "Subscription HTTP tests passed\n"
