#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# tachyon-core is flagged as its own variant (sing_box_tachyon_core) while
# sing_box_extended stays 0, so every frontend capability gate keyed on
# sing_box_extended hid the AmneziaWG and AnyTLS section actions, the built-in
# FPTN action and the XHTTP transport on servers, even though the backend
# validator accepts all of them on a tachyon-core install. The same gates must
# not open up what the validator still rejects (warp/masque/openvpn/snell/
# mieru/sudoku) or MTProto, which tachyon-core has no inbound for: an offered
# value there aborts the whole config on apply.

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

// Map every option.value(...) registration in a flat option builder to the
// capability gate it sits behind (null = offered unconditionally).
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
if (!tachyonSource.includes("singBoxTachyonCore: false,")) {
  fail("uiCapabilities must default singBoxTachyonCore to false");
}
if (!tachyonSource.includes("typeof data?.sing_box_tachyon_core !== \"undefined\"")) {
  fail("updateUiCapabilities must read sing_box_tachyon_core without clobbering it");
}
if (!tachyonSource.includes("singBoxTachyonCore: uiCapabilities.singBoxTachyonCore,")) {
  fail("the action providers event must carry singBoxTachyonCore");
}

// --- section action dropdown (section.js) -----------------------------------
const stateBlock = functionBody(
  sectionSource,
  "const actionProvidersAvailabilityState = {",
);
if (!stateBlock.includes("singBoxTachyonCore: false,")) {
  fail("actionProvidersAvailabilityState must track singBoxTachyonCore");
}

const updateBlock = functionBody(
  sectionSource,
  "function updateActionProvidersAvailabilityState(",
);
if (!updateBlock.includes("typeof nextState.singBoxTachyonCore !== \"undefined\"")) {
  fail("updateActionProvidersAvailabilityState must consume singBoxTachyonCore");
}

const fromSystemInfo = functionBody(
  sectionSource,
  "function updateActionProvidersAvailabilityFromSystemInfo(",
);
if (!fromSystemInfo.includes("singBoxTachyonCore: Boolean(systemInfo.sing_box_tachyon_core)")) {
  fail("system-info must feed singBoxTachyonCore into the action providers state");
}
if (!fromSystemInfo.includes("systemInfo.fptn_installed || systemInfo.sing_box_fptn")) {
  fail("the built-in FPTN flag must make the FPTN action available");
}

if (!sectionSource.includes("singBoxTachyonCore: Boolean(capabilities?.singBoxTachyonCore)")) {
  fail("the capabilities loader path must feed singBoxTachyonCore");
}
if (!sectionSource.includes("function isTachyonCoreForUi()")) {
  fail("section.js must expose an isTachyonCoreForUi gate");
}

const gates = valueGates(
  functionBody(sectionSource, "function populateActionOptionValues(option) {"),
);

const tachyonGate = "isSingBoxExtendedForUi() || isTachyonCoreForUi()";

// Offered unconditionally: the routing base every engine understands.
for (const base of ["connection", "bypass", "block", "dns", "hosts"]) {
  expectGate(gates, base, null);
}

// NaiveProxy ships an outbound in every core, so its action carries no variant
// gate - gating it would hide it on stock sing-box, which has it too.
expectGate(gates, "naive", null);
if (!sectionSource.includes('case "naive":\n      return "NaiveProxy";')) {
  fail("naive action must carry its NaiveProxy label");
}
for (const field of ["naive_server", "naive_server_port", "naive_username", "naive_password"]) {
  if (!sectionSource.includes(`"${field}",`)) {
    fail(`naive section must expose ${field}`);
  }
}

// Supported or unreleased actions offered when extended or tachyon-core is active.
for (const action of [
  "awg",
  "warp",
  "masque",
  "openvpn",
  "anytls",
  "snell",
  "mieru",
  "sudoku",
]) {
  expectGate(gates, action, tachyonGate);
}

if (!sectionSource.includes('case "mieru":\n      return "Mieru";')) {
  fail("mieru label must be plain: tachyon-core implements it");
}
if (sectionSource.includes('"Mieru (не реализован)"')) {
  fail("the stale mieru (не реализован) label must be gone");
}
// mieru is implemented on tachyon-core, so neither the validate() guard nor the
// disabled-<option> pass may touch it: an offered value there is a value the
// validator refuses on apply.
if (sectionSource.includes('value === "mieru" || value === "sudoku"')) {
  fail("mieru must not be blocked by the tachyon-core validate() guard");
}
if (sectionSource.includes('option[value="mieru"]')) {
  fail("mieru must not be disabled in the action dropdown for tachyon-core");
}
if (!sectionSource.includes('case "sudoku":\n      return isTachyonCoreForUi() ? _("Sudoku (не реализован)") : "Sudoku";')) {
  fail("sudoku label must indicate (не реализован) for tachyon-core");
}
if (!sectionSource.includes('value === "sudoku"')) {
  fail("sudoku must stay blocked by the tachyon-core validate() guard");
}

// Component-gated actions must keep their own gates.
expectGate(gates, "fptn", "isFptnInstalledForUi()");
expectGate(gates, "zapret2", "isZapret2InstalledForUi()");
expectGate(gates, "byedpi", "isByedpiInstalledForUi()");

// --- servers (server.js) -----------------------------------------------------
const normalize = functionBody(
  serverSource,
  "function normalizeServerCapabilities(capabilities) {",
);
if (!normalize.includes("singBoxTachyonCore,")) {
  fail("normalizeServerCapabilities must expose singBoxTachyonCore");
}
if (!normalize.includes("singBoxXhttp: singBoxTachyonCore,")) {
  fail("server-side XHTTP must only be offered on tachyon-core (sing-box-lx/extended only have client-side xhttp)");
}
if (!normalize.includes("singBoxExtended,")) {
  fail("normalizeServerCapabilities must keep singBoxExtended as its own flag");
}

const transports = functionBody(
  serverSource,
  "function populateTransportValues(option,",
);
if (!transports.includes("if (supportsXhttp)")) {
  fail("the transport list must gate XHTTP on the xhttp capability, not on the variant flag");
}
const xhttpLine = transports.indexOf('addOptionValue(option, "xhttp", "XHTTP");');
const xhttpGuard = transports.lastIndexOf("if (", xhttpLine);
if (xhttpLine < 0 || xhttpGuard < 0) {
  fail("XHTTP must be registered by the transport list");
}
if (!transports.slice(xhttpGuard, xhttpLine).includes("supportsXhttp")) {
  fail("XHTTP must not be part of the unconditional transport list");
}

const protocols = functionBody(
  serverSource,
  "function populateProtocolValues(option, capabilities) {",
);
if (!protocols.includes("if (normalized.singBoxExtended)")) {
  fail("extended-only protocols (MTProto) must stay behind singBoxExtended");
}

const applyBlock = functionBody(
  serverSource,
  "function applyServerCapabilities(sectionRef, capabilities) {",
);
if (!applyBlock.includes("populateTransportValues(options.transport, normalized.singBoxXhttp)")) {
  fail("applyServerCapabilities must refresh transports with the XHTTP capability");
}

if (!serverSource.includes("populateTransportValues(o, singBoxXhttp);")) {
  fail("createServerContent must render transports with the XHTTP capability");
}
if (serverSource.includes("populateTransportValues(o, singBoxExtended);")) {
  fail("stale transport gate on singBoxExtended found");
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
