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
if (!fptnPayloadBlock.includes('md5_fingerprint: ""')) {
  fail("FPTN server entry must include md5_fingerprint");
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

printf 'LuCI server FPTN and modal contracts passed\n'
