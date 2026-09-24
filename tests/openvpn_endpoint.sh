#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Test generator_outbounds add_openvpn_endpoint behavior
ucode -L "$TACHYON_LIB" -e '
let generator = require("singbox.generator_outbounds");

let config = { endpoints: [], outbounds: [] };
let section = {
    ".name": "vpn_sec",
    openvpn_server: "vpn.example.com",
    openvpn_server_port: "1194",
    openvpn_proto: "udp",
    openvpn_username: "testuser",
    openvpn_password: "testpassword",
    openvpn_cipher: "AES-256-CBC",
    openvpn_auth: "SHA512",
    openvpn_mtu: "1420",
    openvpn_ca: "-----BEGIN CERTIFICATE-----\nCA_DATA\n-----END CERTIFICATE-----",
    openvpn_cert: "-----BEGIN CERTIFICATE-----\nCERT_DATA\n-----END CERTIFICATE-----",
    openvpn_key: "-----BEGIN PRIVATE KEY-----\nKEY_DATA\n-----END PRIVATE KEY-----",
    openvpn_tls_crypt: "-----BEGIN OpenVPN Static key V1-----\nCRYPT_DATA\n-----END OpenVPN Static key V1-----"
};

generator.add_openvpn_endpoint(config, section);

if (length(config.endpoints) != 1) {
    warn("expected 1 endpoint\n");
    exit(1);
}

let ep = config.endpoints[0];
if (ep.type != "openvpn-client") {
    warn("expected openvpn-client type, got: " + ep.type + "\n");
    exit(2);
}
if (ep.tag != "vpn_sec-out") {
    warn("expected vpn_sec-out tag, got: " + ep.tag + "\n");
    exit(3);
}
if (ep.system === true) {
    warn("system: true must NOT be set on openvpn-client endpoint\n");
    exit(4);
}
if (ep.server != "vpn.example.com" || ep.server_port != 1194 || ep.network != "udp") {
    warn("server/port/network mismatch\n");
    exit(5);
}
if (ep.username != "testuser" || ep.password != "testpassword") {
    warn("username/password credentials mismatch\n");
    exit(6);
}
if (ep.cipher != "AES-256-CBC") {
    warn("cipher mismatch\n");
    exit(7);
}
if (!ep.data_ciphers || ep.data_ciphers[0] != "AES-256-CBC") {
    warn("data_ciphers mismatch\n");
    exit(8);
}
if (ep.auth != "SHA512") {
    warn("auth mismatch\n");
    exit(9);
}
if (ep.mtu != 1420) {
    warn("mtu mismatch\n");
    exit(10);
}
if (!ep.tls || !ep.tls.certificate || index(ep.tls.certificate[0], "CA_DATA") == -1) {
    warn("tls.certificate mismatch\n");
    exit(11);
}
if (!ep.tls.control_wrap || ep.tls.control_wrap.type != "tls_crypt") {
    warn("tls.control_wrap type mismatch\n");
    exit(12);
}

// Test tls_auth with direction
let config2 = { endpoints: [], outbounds: [] };
let section2 = {
    ".name": "vpn_auth_sec",
    openvpn_server: "198.51.100.1",
    openvpn_server_port: "443",
    openvpn_proto: "tcp",
    openvpn_tls_auth: "/etc/tachyon/ta.key",
    openvpn_key_direction: "1"
};

generator.add_openvpn_endpoint(config2, section2);
let ep2 = config2.endpoints[0];
if (!ep2.tls || !ep2.tls.control_wrap) {
    warn("ep2 tls.control_wrap missing\n");
    exit(13);
}
if (ep2.tls.control_wrap.type != "tls_auth" || ep2.tls.control_wrap.key_path != "/etc/tachyon/ta.key") {
    warn("ep2 control_wrap key_path mismatch\n");
    exit(14);
}
if (ep2.tls.control_wrap.direction != "client") {
    warn("ep2 control_wrap direction mismatch, expected client, got: " + ep2.tls.control_wrap.direction + "\n");
    exit(15);
}
' || fail "generator_outbounds openvpn endpoint test failed"

# 2. Verify section.js contracts for OpenVPN
grep -Fq '_load_openvpn_conf' "$SECTION_JS" ||
  fail "section.js must define _load_openvpn_conf button"

grep -Fq 'parseOpenvpnConfig' "$SECTION_JS" ||
  fail "section.js must define parseOpenvpnConfig"

grep -Fq '"openvpn_username"' "$SECTION_JS" ||
  fail "section.js must expose openvpn_username"

grep -Fq '"openvpn_password"' "$SECTION_JS" ||
  fail "section.js must expose openvpn_password"

grep -Fq '"openvpn_tls_crypt"' "$SECTION_JS" ||
  fail "section.js must expose openvpn_tls_crypt"

grep -Fq '"openvpn_key_direction"' "$SECTION_JS" ||
  fail "section.js must expose openvpn_key_direction"

grep -Fq '"openvpn_mtu"' "$SECTION_JS" ||
  fail "section.js must expose openvpn_mtu"

# 3. Test parseOpenvpnConfig logic via Node
node - "$SECTION_JS" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");

// Extract parseOpenvpnConfig function
const fnMatch = source.match(/const parseOpenvpnConfig = \(([\s\S]*?)\n  \};/);
if (!fnMatch) {
  console.error("FAIL: cannot extract parseOpenvpnConfig from section.js");
  process.exit(1);
}

const fnCode = fnMatch[0].replace(/^const parseOpenvpnConfig = /, "").replace(/;\s*$/, "");
const parseOpenvpnConfig = eval(`(${fnCode})`);

const sampleOvpn = `
client
dev tun
proto udp4
remote vpn.myserver.org 1194
remote backup.myserver.org 443
resolv-retry infinite
nobind
auth SHA256
cipher AES-128-GCM
key-direction 1
tun-mtu 1400
auth-user-pass

<ca>
-----BEGIN CERTIFICATE-----
MIIB...
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIC...
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIE...
-----END PRIVATE KEY-----
</key>
<tls-crypt>
-----BEGIN OpenVPN Static key V1-----
abcd...
-----END OpenVPN Static key V1-----
</tls-crypt>
<auth-user-pass>
my_vpn_user
my_secret_password
</auth-user-pass>
`;

const parsed = parseOpenvpnConfig(sampleOvpn);
if (parsed.server !== "vpn.myserver.org") throw new Error("server mismatch: " + parsed.server);
if (parsed.port !== "1194") throw new Error("port mismatch: " + parsed.port);
if (parsed.proto !== "udp") throw new Error("proto mismatch: " + parsed.proto);
if (parsed.auth !== "SHA256") throw new Error("auth mismatch: " + parsed.auth);
if (parsed.cipher !== "AES-128-GCM") throw new Error("cipher mismatch: " + parsed.cipher);
if (parsed.key_direction !== "1") throw new Error("key_direction mismatch: " + parsed.key_direction);
if (parsed.mtu !== "1400") throw new Error("mtu mismatch: " + parsed.mtu);
if (!parsed.ca.includes("MIIB...")) throw new Error("ca mismatch");
if (!parsed.cert.includes("MIIC...")) throw new Error("cert mismatch");
if (!parsed.key.includes("MIIE...")) throw new Error("key mismatch");
if (!parsed.tls_crypt.includes("abcd...")) throw new Error("tls_crypt mismatch");
if (parsed.username !== "my_vpn_user") throw new Error("username mismatch: " + parsed.username);
if (parsed.password !== "my_secret_password") throw new Error("password mismatch: " + parsed.password);
if (!parsed.auth_user_pass_required) throw new Error("auth_user_pass_required mismatch");

console.log("parseOpenvpnConfig Node tests passed successfully");
NODE

printf 'OpenVPN endpoint and config upload checks passed\n'
