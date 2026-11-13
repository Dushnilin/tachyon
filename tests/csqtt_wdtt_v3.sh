#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PARSER="$TACHYON_LIB/subscription/parser.uc"
SHARE_LINK="$TACHYON_LIB/subscription/share_link.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
CORE_PROFILE="$TACHYON_LIB/tachyon_core/core_profile.uc"

# 1. Verify subscription/parser.uc parses all unencrypted CSQTT / WDTT v3 URI formats
JSON_B64="$(node -e 'process.stdout.write(Buffer.from(JSON.stringify({ v: 1, ip: "json.example.com", dtls: 46002, pass: "json-pass", vpn: "wg", obfs: "unified", workers: 3 })).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""))')"

cat >"$WORK_DIR/csqtt_links.txt" <<EOF
csqtt://connect?v=2host=compact.example.compeer=46000password=compact-passobfs=audioworkers=2#csqtt-compact
csqtt://connect?v=2&host=198.51.100.10&peer=46000&password=vk-pass&turn_transport=tcp&hashes=aabbcc1122,ddeeff3344#csqtt-vk
qwdtt://config?ip=qwdtt.example.com&dtls=46000&vpn=raw&raw=46001&obfs=video&pass=qpass#qwdtt-raw
wdtt://${JSON_B64}#wdtt-json
wdtt://203.0.113.5:56000:56001:56002:colon-pass:hash1,hash2#wdtt-colon
csqtt://std-pass@std.example.com:46000?mode=csqtt&obfs=audio#csqtt-std
EOF

ucode -L "$TACHYON_LIB" "$PARSER" normalize-content-validated \
  "$WORK_DIR/csqtt_links.txt" "$WORK_DIR/parsed_plain.json" "" "ucode" ||
  fail "parser failed on CSQTT / WDTT v3 link bundle"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let data = json(fs.readfile("'"$WORK_DIR/parsed_plain.json"'"));
let obs = data.outbounds || [];
if (length(obs) != 6) {
    warn("expected 6 parsed wdtt outbounds, got " + length(obs) + "\n");
    exit(1);
}
for (let ob in obs) {
    if (ob.type != "wdtt") {
        warn("expected type=wdtt for " + ob.tag + ", got " + ob.type + "\n");
        exit(2);
    }
}
if (obs[0].server != "compact.example.com" || obs[0].server_port != 46000 || obs[0].password != "compact-pass" || obs[0].obfs != "audio" || obs[0].workers != 2) {
    warn("compact query parse mismatch: " + sprintf("%J", obs[0]) + "\n");
    exit(3);
}
if (obs[1].server != "198.51.100.10" || obs[1].server_port != 46000 || obs[1].password != "vk-pass" || obs[1].turn_transport != "tcp" || length(obs[1].hashes || []) != 2) {
    warn("vk/hashes compact parse mismatch: " + sprintf("%J", obs[1]) + "\n");
    exit(4);
}
if (obs[2].mode != "raw" || obs[2].raw_port != 46001 || obs[2].obfs != "video") {
    warn("qwdtt parse mismatch: " + sprintf("%J", obs[2]) + "\n");
    exit(5);
}
if (obs[3].server != "json.example.com" || (obs[3].mode || "wg") != "wg" || obs[3].obfs != "unified" || obs[3].workers != 3) {
    warn("base64url json parse mismatch: " + sprintf("%J", obs[3]) + "\n");
    exit(6);
}
if (obs[4].server != "203.0.113.5" || obs[4].server_port != 56000 || obs[4].wg_port != 56001 || obs[4].local_port != 56002 || obs[4].password != "colon-pass" || length(obs[4].hashes || []) != 2) {
    warn("colon format parse mismatch: " + sprintf("%J", obs[4]) + "\n");
    exit(7);
}
if (obs[5].server != "std.example.com" || obs[5].server_port != 46000 || obs[5].password != "std-pass" || obs[5].mode != "csqtt") {
    warn("standard URI parse mismatch: " + sprintf("%J", obs[5]) + "\n");
    exit(8);
}
' || fail "parsed CSQTT / WDTT v3 outbounds assertions failed"

# 2. Verify encrypted csqtt:// delegates to tachyon-core subscription parse CLI
ENC_B64="$(node -e 'process.stdout.write(Buffer.from("encrypted-csqtt-v2-blob-0123456789abcdef").toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""))')"
printf 'csqtt://%s#csqtt-encrypted\n' "$ENC_B64" >"$WORK_DIR/csqtt_enc.txt"

cat >"$WORK_DIR/mock-tachyon-core" <<'SH'
#!/bin/sh
if [ "$1" = "version" ]; then
  echo "tachyon-core version 0.5.2-tachyon"
  exit 0
fi
if [ "$1" = "subscription" ] && [ "$2" = "hwid" ]; then
  echo "{}"
  exit 0
fi
if [ "$1" = "subscription" ] && [ "$2" = "parse" ]; then
  OUT=""
  shift 2
  while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then
      OUT="$2"
      shift 2
      continue
    fi
    shift
  done
  cat <<'JSON' >"${OUT:-/dev/stdout}"
[{"type":"wdtt","tag":"csqtt-encrypted","server":"enc.example.com","server_port":46000,"password":"decrypted-pass","mode":"csqtt","obfs":"audio"}]
JSON
  exit 0
fi
exit 1
SH
chmod +x "$WORK_DIR/mock-tachyon-core"

TACHYON_CORE_BIN="$WORK_DIR/mock-tachyon-core" ucode -L "$TACHYON_LIB" "$PARSER" \
  normalize-content-validated "$WORK_DIR/csqtt_enc.txt" "$WORK_DIR/parsed_enc.json" "" "ucode" ||
  fail "encrypted csqtt:// core delegation failed"

grep -Fq '"enc.example.com"' "$WORK_DIR/parsed_enc.json" ||
  fail "expected decrypted host enc.example.com in parsed_enc.json"
grep -Fq '"decrypted-pass"' "$WORK_DIR/parsed_enc.json" ||
  fail "expected decrypted password in parsed_enc.json"

# 3. Verify share_link serialization & copyability for wdtt/csqtt/qwdtt
ucode -L "$TACHYON_LIB" -e '
let sl = require("subscription.share_link");
for (let link in [
    "csqtt://connect?v=2&host=a.com&peer=46000&password=p",
    "wdtt://a.com:46000:46001:46002:p:hash1,hash2",
    "qwdtt://config?v=1&ip=a.com&dtls=46000&pass=p"
]) {
    if (!sl.is_copyable_link(link)) {
        warn("expected copyable link: " + link + "\n");
        exit(1);
    }
}
let out = sl.serialize_outbound_link({
    type: "wdtt",
    tag: "MyCSQTT",
    server: "vpn.example.com",
    server_port: 46000,
    password: "secret",
    mode: "csqtt",
    obfs: "audio",
    workers: 2,
    mtu: 1350
});
if (index(out, "csqtt://") != 0 || index(out, "vpn.example.com") < 0 || index(out, "obfs=audio") < 0) {
    warn("unexpected serialized csqtt link: " + out + "\n");
    exit(2);
}
' || fail "share_link wdtt/csqtt checks failed"

# 4. Verify core_profile recognizes wdtt protocol and cs_out + wdtt_in end-to-end fixture config
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "engine": "tachyon-core",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "CSQTT_SEC",
      ".type": "section",
      "enabled": "1",
      "action": "csqtt",
      "csqtt_server": "vpn.example.com",
      "csqtt_server_port": "46000",
      "csqtt_password": "secret",
      "csqtt_mode": "csqtt",
      "csqtt_obfs": "audio",
      "csqtt_workers": "2",
      "domain_suffix": [ "example.com" ]
    },
    {
      ".name": "RAW_JSON_SEC",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_jsons": [
        "{\"type\":\"wdtt\",\"tag\":\"raw-wdtt\",\"server\":\"raw.example.com\",\"server_port\":46000,\"password\":\"p\",\"srtp_mode\":\"dtls\",\"vk_token\":\"tok\"}"
      ],
      "domain_suffix": [ "example.org" ]
    }
  ],
  "server": [
    {
      ".name": "CSQTTServer",
      ".type": "server",
      "enabled": "1",
      "protocol": "wdtt",
      "listen_port": "46000",
      "server_username": "user1",
      "server_password": "srvpassword",
      "wdtt_mode": "csqtt",
      "wdtt_obfs": "audio",
      "wdtt_raw_port": "46001",
      "wdtt_network": "10.66.0.1/16",
      "wdtt_mtu": "1350"
    }
  ]
}
JSON

config="$WORK_DIR/config.json"
mkdir -p "$config.section-cache" "$config.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$config" "127.0.0.1" "0" "1" >/dev/null ||
  fail "generate-config-fixture failed for CSQTT / WDTT v3"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let profile = require("tachyon_core.core_profile");
if (!profile.supports_protocol("wdtt", "0.5.2-tachyon", "tachyon-core") || !profile.supports_inbound("wdtt", "0.5.2-tachyon", "tachyon-core") || profile.supports_protocol("wdtt", "1.12.0", "")) {
    warn("core_profile wdtt capability check mismatch\n");
    exit(1);
}
let cfg = json(fs.readfile("'"$config"'"));
let csqtt_out = null;
let raw_out = null;
for (let ob in (cfg.outbounds || [])) {
    if (ob.tag == "CSQTT_SEC-out") csqtt_out = ob;
    if (ob.tag == "raw-wdtt") raw_out = ob;
}
if (!csqtt_out || csqtt_out.type != "wdtt" || csqtt_out.server != "vpn.example.com" || csqtt_out.server_port != 46000 || csqtt_out.obfs != "audio" || csqtt_out.workers != 2) {
    warn("missing or invalid CSQTT_SEC-out: " + sprintf("%J", csqtt_out) + "\n");
    exit(2);
}
if (!raw_out || raw_out.type != "wdtt") {
    warn("missing raw-wdtt outbound\n");
    exit(3);
}
if (exists(raw_out, "srtp_mode") || exists(raw_out, "vk_token")) {
    warn("sanitize_wdtt_outbound must strip srtp_mode and vk_token when core version < 0.5.3\n");
    exit(4);
}
let wdtt_in = null;
for (let ib in (cfg.inbounds || [])) {
    if (ib.type == "wdtt") wdtt_in = ib;
}
if (!wdtt_in || wdtt_in.listen_port != 46000 || wdtt_in.mode != "csqtt" || wdtt_in.obfs != "audio" || wdtt_in.raw_port != 46001 || wdtt_in.mtu != 1350 || !wdtt_in.users || length(wdtt_in.users) == 0 || exists(wdtt_in, "tls")) {
    warn("invalid or missing wdtt inbound: " + sprintf("%J", wdtt_in) + "\n");
    exit(5);
}
' || fail "generated config assertions failed for CSQTT / WDTT v3"

# 5. Verify server/links.uc generates csqtt:// and wdtt:// client links
ucode -L "$TACHYON_LIB" -e '
let links = require("server.links");
let csqtt_link = links.build({
    protocol: "wdtt",
    listen_port: "46000",
    public_host: "srv.example.com",
    server_username: "user1",
    server_password: "srvpassword",
    wdtt_mode: "csqtt",
    wdtt_obfs: "audio",
    ".name": "CSQTTNode"
}, "srv.example.com", "");
if (index(csqtt_link, "csqtt://connect?") != 0 || index(csqtt_link, "host=srv.example.com") < 0 || index(csqtt_link, "peer=46000") < 0) {
    warn("unexpected server csqtt link: " + csqtt_link + "\n");
    exit(1);
}
let wg_link = links.build({
    protocol: "wdtt",
    listen_port: "46000",
    public_host: "srv.example.com",
    server_username: "user1",
    server_password: "srvpassword",
    wdtt_mode: "wg",
    wdtt_obfs: "unified",
    ".name": "WDTTWg"
}, "srv.example.com", "");
if (index(wg_link, "wdtt://") != 0) {
    warn("unexpected server wdtt link: " + wg_link + "\n");
    exit(2);
}
' || fail "server/links.uc wdtt/csqtt generation failed"

printf 'csqtt / wdtt v3 integration checks passed\n'
