#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR="$TACHYON_LIB/singbox/generator.uc"
VALIDATOR="$TACHYON_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/output.json.section-cache"

# 1. Test config generation: AWG cascading through a proxy hop, and proxy cascading through AWG
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "proxy_hop",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#Hop" ]
    },
    {
      ".name": "awg_section",
      ".type": "section",
      "enabled": "1",
      "action": "awg",
      "awg_version": "2.0",
      "awg_private_key": "aW5ib3VuZF9wcml2YXRlX2tleQ==",
      "awg_peer_public_key": "cGVlcl9wdWJsaWNfa2V5",
      "awg_server_address": "192.168.1.100",
      "awg_server_port": "51820",
      "awg_local_address": ["10.0.0.2/24"],
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "proxy_hop"
    },
    {
      ".name": "proxy_via_awg",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [ "socks5://127.0.0.1:1081#Target" ],
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "awg_section"
    }
  ]
}
JSON

ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/output.json" "127.0.0.1"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));

function endpoint(tag) {
    for (let item in config.endpoints || [])
        if (item && item.tag == tag)
            return item;
    return null;
}

function outbound(tag) {
    for (let item in config.outbounds || [])
        if (item && item.tag == tag)
            return item;
    return null;
}

function assert(condition, message) {
    if (!condition)
        die(message + "\n");
}

let awg_ep = endpoint("awg_section-out");
assert(awg_ep != null, "AWG endpoint was not generated");
assert(awg_ep.detour == "proxy_hop-out", "AWG endpoint detour was not set to proxy_hop-out: " + awg_ep.detour);

let proxy_out = outbound("proxy_via_awg-1-out");
assert(proxy_out != null, "proxy_via_awg outbound was not generated");
assert(proxy_out.detour == "awg_section-out", "proxy_via_awg detour was not set to awg_section-out: " + proxy_out.detour);
' "$WORK_DIR/output.json" || fail "AWG cascade config generation"

# 2. Test validator accepts AWG detour in both directions
printf 'section1\t1\tawg\t1\tsection2\nsection2\t1\tconnection\t0\t\n' | \
  ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-outbound-detours || fail "validator rejected AWG -> connection cascade"

printf 'section1\t1\tconnection\t1\tsection2\nsection2\t1\tawg\t0\t\n' | \
  ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-outbound-detours || fail "validator rejected connection -> AWG cascade"

# 3. Test validator detects cycle involving AWG
if printf 'section1\t1\tawg\t1\tsection2\nsection2\t1\tconnection\t1\tsection1\n' | \
  ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-outbound-detours >/dev/null 2>&1; then
  fail "validator failed to detect cycle between AWG and connection"
fi

printf 'AWG cascade checks passed\n'
