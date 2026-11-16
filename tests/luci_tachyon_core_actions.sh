#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Verifies that LuCI views expose the unified tachyon-core section actions,
# server protocols/transports, and UI capability flags cleanly.

SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"
SERVER_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/server.js"
TACHYON_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/tachyon.js"

for file in "$SECTION_JS" "$SERVER_JS" "$TACHYON_JS"; do
  [ -f "$file" ] || fail "missing view file: $file"
done

node - "$SECTION_JS" "$SERVER_JS" "$TACHYON_JS" <<'NODE'
const fs = require("fs");

const [sectionPath, serverPath, tachyonPath] = process.argv.slice(2);
const sectionSource = fs.readFileSync(sectionPath, "utf8");
const serverSource = fs.readFileSync(serverPath, "utf8");
const tachyonSource = fs.readFileSync(tachyonPath, "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function functionBody(source, signature) {
  const start = source.indexOf(signature);
  if (start < 0) fail(`missing source contract: ${signature}`);
  const end = source.indexOf("\nfunction ", start + 1);
  return source.slice(start, end < 0 ? source.length : end);
}

function valueGates(body) {
  const gates = {};
  let current = null;

  for (const line of body.split("\n")) {
    const open = line.match(/^\s*if \((.+)\) \{$/);
    if (open) {
      current = open[1];
      continue;
    }
    if (/^\s*\}/.test(line)) {
      current = null;
      continue;
    }
    const value = line.match(/option\.value\("([a-z0-9_]+)"/);
    if (value) gates[value[1]] = current;
  }

  return gates;
}

function expectGate(gates, action, expected) {
  if (!(action in gates)) fail(`section action "${action}" is not offered at all`);
  if (gates[action] !== expected) {
    fail(
      `section action "${action}" must be gated on ${JSON.stringify(expected)}, got ${JSON.stringify(gates[action])}`,
    );
  }
}

// --- capabilities source (tachyon.js) ---------------------------------------
if (!tachyonSource.includes("tachyonCoreTailscale: true,")) {
  fail("uiCapabilities must default tachyonCoreTailscale to true");
}
if (!tachyonSource.includes("tachyon_core_tailscale")) {
  fail("updateUiCapabilities must read tachyon_core_tailscale");
}

// --- section action dropdown (section.js) -----------------------------------
const fromSystemInfo = functionBody(
  sectionSource,
  "function updateActionProvidersAvailabilityFromSystemInfo(",
);
if (!fromSystemInfo.includes("tachyon_core_fptn")) {
  fail("the built-in FPTN flag must feed action availability");
}

const gates = valueGates(
  functionBody(sectionSource, "function populateActionOptionValues(option) {"),
);

for (const base of ["connection", "group", "naive", "awg", "warp", "masque", "openvpn", "anytls", "snell", "mieru", "sudoku", "openconnect", "desync", "shadowtls", "trusttunnel", "tewfai", "csqtt", "bypass", "block", "dns", "hosts"]) {
  expectGate(gates, base, null);
}

if (!sectionSource.includes('case "naive":\n      return "NaiveProxy";')) {
  fail("naive action must carry its NaiveProxy label");
}
for (const field of ["naive_server", "naive_server_port", "naive_username", "naive_password"]) {
  if (!sectionSource.includes(`"${field}",`)) {
    fail(`naive section must expose ${field}`);
  }
}
if (!sectionSource.includes('case "mieru":\n      return "Mieru";')) {
  fail("mieru label must be plain: tachyon-core implements it");
}
if (sectionSource.includes('"Mieru (не реализован)"')) {
  fail("the stale mieru (не реализован) label must be gone");
}
if (!sectionSource.includes('case "sudoku":\n      return _("Sudoku (не реализован)");')) {
  fail("sudoku label must indicate (не реализован) for tachyon-core");
}
if (!sectionSource.includes('value === "sudoku"')) {
  fail("sudoku must stay blocked by the validate() guard");
}

expectGate(gates, "fptn", "isFptnInstalledForUi()");
for (const removed of ["zapret", "zapret2", "byedpi", "olcrtc"]) {
  if (removed in gates) fail(`removed section action "${removed}" must not be offered in UI`);
}

// --- servers (server.js) -----------------------------------------------------
const normalize = functionBody(
  serverSource,
  "function normalizeServerCapabilities(capabilities) {",
);
if (!normalize.includes("tachyonCoreTailscale")) {
  fail("normalizeServerCapabilities must read tachyonCoreTailscale");
}

const transports = functionBody(
  serverSource,
  "function populateTransportValues(option)",
);
if (!transports.includes('addOptionValue(option, "xhttp", "XHTTP");')) {
  fail("XHTTP must be registered by the transport list");
}

const protocols = functionBody(
  serverSource,
  "function populateProtocolValues(option,",
);
if (!protocols.includes("CORE_SERVER_PROTOCOL_LABELS")) {
  fail("populateProtocolValues must register CORE_SERVER_PROTOCOL_LABELS");
}

if (!tachyonSource.includes('"require view.tachyon.local_devices as localDevices";')) {
  fail("tachyon.js must pre-declare view.tachyon.local_devices to avoid a 3rd L.require HTTP wave");
}
if (!tachyonSource.includes('"require view.tachyon.dns_speed_test as dnsSpeedTest";')) {
  fail("tachyon.js must pre-declare view.tachyon.dns_speed_test to avoid a 3rd L.require HTTP wave");
}
if (!tachyonSource.includes("preloadedUiCapabilitiesResponsePromise =")) {
  fail("tachyon.js EntryPoint.load() must preload UI capabilities in parallel with uci.load");
}
NODE

printf 'tachyon-core action UI checks passed\n'
