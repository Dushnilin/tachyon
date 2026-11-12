#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SERVER_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/server.js"

node - "$SERVER_JS" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function requiredIndex(needle, from = 0) {
  const index = source.indexOf(needle, from);
  if (index < 0) fail(`missing source contract: ${needle}`);
  return index;
}

// 1. Verify buildFptnPayload contains standard upstream FPTN schema keys
const fptnPayloadIndex = requiredIndex("function buildFptnPayload");
const fptnPayloadBlock = source.slice(fptnPayloadIndex, source.indexOf("function buildFptnToken", fptnPayloadIndex));

if (!fptnPayloadBlock.includes("version: 1")) {
  fail("FPTN payload must include version: 1");
}
if (!fptnPayloadBlock.includes('service_name: "Tachyon"')) {
  fail("FPTN payload must include service_name");
}
if (!fptnPayloadBlock.includes("host: host")) {
  fail("FPTN server entry must use 'host' instead of 'server'");
}
if (!fptnPayloadBlock.includes("md5_fingerprint: normalizeMd5(options.tlsCertificateMd5)")) {
  fail("FPTN server entry must populate md5_fingerprint from options.tlsCertificateMd5");
}
if (!source.includes("function loadTlsCertificateFingerprints(")) {
  fail("server.js must define loadTlsCertificateFingerprints");
}
if (!fptnPayloadBlock.includes("censored_zone_servers: []")) {
  fail("FPTN payload must include censored_zone_servers array");
}

// 2. Verify buildFptnToken and buildFptnLink return canonical fptn: prefix and unpadded base64
const tokenIndex = requiredIndex("function buildFptnToken");
const tokenBlock = source.slice(tokenIndex, source.indexOf("function buildHttpLink", tokenIndex));

if (!tokenBlock.includes('`fptn:${b64}`')) {
  fail("buildFptnToken must prefix token with 'fptn:'");
}
if (!tokenBlock.includes('replace(/=+$/, "")')) {
  fail("FPTN base64 must strip trailing padding '=' for mobile app compatibility");
}
if (!tokenBlock.includes('`fptn://${b64}#${encodeURIComponent(serverName)}`')) {
  fail("buildFptnLink must emit valid fptn:// URI with server anchor");
}

// 3. Verify getModalNode is resilient across LuCI themes
const getModalNodeIndex = requiredIndex("function getModalNode()");
const getModalNodeBlock = source.slice(getModalNodeIndex, source.indexOf("function clearServerValidationMessage", getModalNodeIndex));

if (getModalNodeBlock.includes("body.modal-overlay-active > #modal_overlay > .modal.cbi-modal")) {
  fail("getModalNode must not use fragile strict ancestor selector");
}

// 4. Verify autoConfigureServer uses non-intrusive toast instead of ui.addNotification
const autoConfigIndex = requiredIndex("function autoConfigureServer");
const autoConfigBlock = source.slice(autoConfigIndex, source.indexOf("function prepareServerModal", autoConfigIndex));

if (autoConfigBlock.includes("ui.addNotification")) {
  fail("autoConfigureServer must not flood page with persistent ui.addNotification");
}
if (!autoConfigBlock.includes("main.showToast")) {
  fail("autoConfigureServer must notify user via showToast");
}

// 5. Verify tailscale auth key description
const tailscaleIndex = requiredIndex('"tailscale_auth_key"');
const tailscaleBlock = source.slice(tailscaleIndex, source.indexOf('"tailscale_control_url"', tailscaleIndex));
if (!tailscaleBlock.includes("login.tailscale.com/admin/settings/keys")) {
  fail("tailscale_auth_key option must include admin console URL in description");
}

NODE

# 6. Verify backend server/service.uc MD5 fingerprint calculation and server/links.uc FPTN URI pin propagation
CERT_PEM="$WORK_DIR/fptn_test_cert.pem"
KEY_PEM="$WORK_DIR/fptn_test_key.pem"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_PEM" -out "$CERT_PEM" \
  -days 1 -subj "/CN=vpn.example.com" >/dev/null 2>&1

EXPECTED_MD5="$(openssl x509 -in "$CERT_PEM" -noout -fingerprint -md5 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"
[ "${#EXPECTED_MD5}" -eq 32 ] || fail "openssl did not produce a 32-hex MD5 fingerprint: $EXPECTED_MD5"

UCI_STATE="$WORK_DIR/uci.state"
cat >"$UCI_STATE" <<EOF_UCI
tachyon.fptn_srv=server
tachyon.fptn_srv.enabled=1
tachyon.fptn_srv.protocol=fptn
tachyon.fptn_srv.label=HomeFPTN
tachyon.fptn_srv.listen_port=8443
tachyon.fptn_srv.server_username=alice
tachyon.fptn_srv.server_password=secretpass
tachyon.fptn_srv.tls_certificate_path=$CERT_PEM
tachyon.fptn_srv.tls_key_path=$KEY_PEM
EOF_UCI

FP_JSON="$(TACHYON_UCI_STATE_FILE="$UCI_STATE" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/server/service.uc" tls-certificate-sha256 fptn_srv)"
ucode -L "$TACHYON_LIB" -e '
let links = require("server.links");
let fp = json(ARGV[0]);
let expected_md5 = ARGV[1];
if (!fp.success || fp.md5 != expected_md5) {
    warn(sprintf("unexpected TLS fingerprint response: %J (expected md5 %s)\n", fp, expected_md5));
    exit(1);
}
if (!fp.sha256 || length(fp.sha256) != 64) {
    warn(sprintf("missing 64-hex sha256 in TLS fingerprint response: %J\n", fp));
    exit(1);
}
let server = {
    ".name": "fptn_srv",
    protocol: "fptn",
    label: "HomeFPTN",
    listen_port: "8443",
    server_username: "alice",
    server_password: "secretpass"
};
let uri = links.build(server, "vpn.example.com", fp.md5);
if (index(uri, "fptn://") != 0) {
    warn("expected fptn:// URI, got: " + uri + "\n");
    exit(1);
}
let b64 = split(substr(uri, length("fptn://")), "#")[0];
while (length(b64) % 4 != 0)
    b64 += "=";
let payload = json(b64dec(b64));
if (!payload || type(payload.servers) != "array" || length(payload.servers) != 1) {
    warn(sprintf("invalid decoded FPTN payload: %J\n", payload));
    exit(1);
}
let actual_md5 = payload.servers[0].md5_fingerprint;
if (actual_md5 != expected_md5) {
    warn(sprintf("expected md5_fingerprint %s in FPTN link, got %J\n", expected_md5, actual_md5));
    exit(1);
}
' "$FP_JSON" "$EXPECTED_MD5"

printf 'LuCI server FPTN and modal contracts passed\n'
