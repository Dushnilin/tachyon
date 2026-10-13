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

// 1. Verify (i) button has type: "button" and proper classes
const infoBtnIdx = requiredIndex("actionButtons.push(");
const infoBtnBlock = source.slice(infoBtnIdx, source.indexOf("return tdEl;", infoBtnIdx));
if (!infoBtnBlock.includes('type: "button"')) {
  fail("Info (i) button must specify type: 'button' to avoid form submit");
}
if (!infoBtnBlock.includes('fkp-server-icon-button')) {
  fail("Info (i) button must have class 'fkp-server-icon-button'");
}
if (!infoBtnBlock.includes('showServerInfoModal(sectionId)')) {
  fail("Info (i) button click must call showServerInfoModal(sectionId)");
}

// 2. Verify showServerInfoModal runs prepareServerModal before buildClientLinkContext
const showModalIdx = requiredIndex("function showServerInfoModal(sectionId)");
const showModalBlock = source.slice(showModalIdx, source.indexOf("function getServerEditButtonText", showModalIdx));
if (!showModalBlock.includes("prepareServerModal(sectionId)")) {
  fail("showServerInfoModal must invoke prepareServerModal before building client link");
}
const prepIdx = showModalBlock.indexOf("prepareServerModal(sectionId)");
const buildCtxIdx = showModalBlock.indexOf("buildClientLinkContext(sectionId)");
if (prepIdx > buildCtxIdx) {
  fail("prepareServerModal must precede buildClientLinkContext in showServerInfoModal");
}
if (showModalBlock.includes('"cbi-modal fkp-server-info-dialog"')) {
  fail("showServerInfoModal must not pass space-separated classes to ui.showModal (DOMTokenList InvalidCharacterError)");
}
if (!showModalBlock.includes('"fkp-server-info-dialog"')) {
  fail("showServerInfoModal must pass 'fkp-server-info-dialog' as modal class");
}

// 3. Verify prepareServerModal ensures missing keys and parameters
const prepFuncIdx = requiredIndex("function prepareServerModal(sectionId)");
const prepFuncBlock = source.slice(prepFuncIdx, source.indexOf("function addStreamDepends", prepFuncIdx));
if (!prepFuncBlock.includes('setDefault(sectionId, "server_uuid", generateUuid())')) {
  fail("prepareServerModal must ensure server_uuid is generated for UUID protocols");
}
if (!prepFuncBlock.includes('setDefault(sectionId, "server_password", generatePassword())')) {
  fail("prepareServerModal must ensure server_password is generated for password protocols");
}
if (!prepFuncBlock.includes('setDefault(sectionId, "reality_short_id", randomHex(4))')) {
  fail("prepareServerModal must ensure reality_short_id is generated for VLESS Reality");
}
if (!prepFuncBlock.includes('shouldGenerateRealityKeypair(sectionId)')) {
  fail("prepareServerModal must trigger Reality keypair generation when needed");
}

// 4. Verify getServerPort provides fallback ports and is used by share link generators
const portFuncIdx = requiredIndex("function getServerPort(sectionId)");
const portFuncBlock = source.slice(portFuncIdx, source.indexOf("function getTransportParams", portFuncIdx));
if (!portFuncBlock.includes('"51820"') || !portFuncBlock.includes('"8443"') || !portFuncBlock.includes('"443"')) {
  fail("getServerPort must supply standard protocol fallback ports");
}

const vlessLinkIdx = requiredIndex("function buildVlessTrojanLink");
const vlessLinkBlock = source.slice(vlessLinkIdx, source.indexOf("function buildVmessLink", vlessLinkIdx));
if (!vlessLinkBlock.includes("getServerPort(sectionId)")) {
  fail("buildVlessTrojanLink must use getServerPort to prevent missing port in URI");
}

// 5. Verify renderInfoClientLink fallback is an informative alert
const renderLinkIdx = requiredIndex("function renderInfoClientLink(sectionId, linkContext = {})");
const renderLinkBlock = source.slice(renderLinkIdx, source.indexOf("const qrUri =", renderLinkIdx));
if (!renderLinkBlock.includes('alert-message warning')) {
  fail("renderInfoClientLink must render a styled alert message when client link is unavailable");
}

NODE

printf 'LuCI server info modal and client link contracts passed\n'
