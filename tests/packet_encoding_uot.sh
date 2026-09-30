#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
PARSER_UC="$TACHYON_LIB/subscription/parser.uc"

# 1. Test subscription/parser.uc share-link-outbound for VLESS with various packetEncoding casing
r1=$(ucode -L "$TACHYON_LIB" "$PARSER_UC" share-link-outbound "vless://00000000-0000-0000-0000-000000000001@1.2.3.4:443?security=none&packetEncoding=xudp#t1" "t1")
printf '%s\n' "$r1" | grep -q '"packet_encoding": "xudp"' || fail "parser.uc failed to parse packetEncoding=xudp"

r2=$(ucode -L "$TACHYON_LIB" "$PARSER_UC" share-link-outbound "vless://00000000-0000-0000-0000-000000000001@1.2.3.4:443?security=none&packet_encoding=xudp#t2" "t2")
printf '%s\n' "$r2" | grep -q '"packet_encoding": "xudp"' || fail "parser.uc failed to parse packet_encoding=xudp"

r3=$(ucode -L "$TACHYON_LIB" "$PARSER_UC" share-link-outbound "vless://00000000-0000-0000-0000-000000000001@1.2.3.4:443?security=none&packet-encoding=packetaddr#t3" "t3")
printf '%s\n' "$r3" | grep -q '"packet_encoding": "packetaddr"' || fail "parser.uc failed to parse packet-encoding=packetaddr"

# 2. Test full sing-box config generation with section packet_encoding override
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
      ".name": "sec_xudp",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "packet_encoding": "xudp",
      "selector_proxy_links_text": "vless://00000000-0000-0000-0000-000000000001@1.1.1.1:443?security=none#vless_srv",
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"custom_vless\",\"server\":\"2.2.2.2\",\"server_port\":443,\"uuid\":\"00000000-0000-0000-0000-000000000002\"}",
        "{\"type\":\"shadowsocks\",\"tag\":\"custom_ss\",\"server\":\"3.3.3.3\",\"server_port\":8388,\"method\":\"aes-128-gcm\",\"password\":\"pass\"}"
      ]
    },
    {
      ".name": "sec_disabled",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "packet_encoding": "disabled",
      "selector_proxy_links_text": "vless://00000000-0000-0000-0000-000000000001@1.1.1.1:443?security=none&packetEncoding=xudp#vless_strip"
    }
  ]
}
JSON

OUT_JSON="$WORK_DIR/output.json"
mkdir -p "$OUT_JSON.section-cache" "$OUT_JSON.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture "$WORK_DIR/fixture.json" "$OUT_JSON" 127.0.0.1 0 1 >/dev/null

# Verify sec_xudp outbounds received packet_encoding / udp_over_tcp
ucode -e '
let fs = require("fs");
let raw = fs.readfile("'"$OUT_JSON"'");
let cfg = json(raw);
let vless_link = null;
let vless_json = null;
let ss_json = null;
let vless_disabled = null;

for (let ob in cfg.outbounds) {
    if (ob.type == "vless" && index(ob.tag, "sec_xudp") != -1) vless_link = ob;
    if (ob.tag == "custom_vless") vless_json = ob;
    if (ob.tag == "custom_ss") ss_json = ob;
    if (ob.type == "vless" && index(ob.tag, "sec_disabled") != -1) vless_disabled = ob;
}

if (!vless_link || vless_link.packet_encoding != "xudp")
    die("vless_link missing xudp packet_encoding: " + sprintf("%J", vless_link));
if (!vless_json || vless_json.packet_encoding != "xudp")
    die("vless_json missing xudp packet_encoding: " + sprintf("%J", vless_json));
if (!ss_json || !ss_json.udp_over_tcp)
    die("ss_json missing udp_over_tcp: " + sprintf("%J", ss_json));
if (!vless_disabled || vless_disabled.packet_encoding != null)
    die("vless_disabled has unexpected packet_encoding: " + sprintf("%J", vless_disabled));

print("PACKET_ENCODING_TESTS_PASS\n");
'

printf 'packet_encoding UoT tests passed\n'
