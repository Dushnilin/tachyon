#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'function evaluateLiveServerFilterPreview(' "$SECTION_JS" ||
  fail "section.js must define evaluateLiveServerFilterPreview"

grep -Fq 'function addLiveServerFilterPreviewOption(' "$SECTION_JS" ||
  fail "section.js must define addLiveServerFilterPreviewOption"

grep -Fq '_urltest_filter_preview' "$SECTION_JS" ||
  fail "section.js must attach _urltest_filter_preview to URLTest options"

grep -Fq '_priority_level_filter_preview' "$SECTION_JS" ||
  fail "section.js must attach _priority_level_filter_preview to Priority Level options"

grep -Fq '_dashboard_server_filter_preview' "$SECTION_JS" ||
  fail "section.js must attach _dashboard_server_filter_preview to Dashboard Server Filter options"

node - "$SECTION_JS" <<'NODE'
const fs = require("fs");
const assert = require("assert");

const source = fs.readFileSync(process.argv[2], "utf8");

const startIdx = source.indexOf("function normalizeProtocolName(protocol)");
const regionFallbacksIdx = source.indexOf("const REGION_NAME_FALLBACKS =");
const plainObjIdx = source.indexOf("function plainObject(value)");
const endIdx = source.indexOf("function loadOutboundNameChoices(section_id)");

if (startIdx < 0 || regionFallbacksIdx < 0 || plainObjIdx < 0 || endIdx < 0) {
  console.error("FAIL: could not locate filter preview helper functions in section.js");
  process.exit(1);
}

const protocolBlock = source.slice(startIdx, regionFallbacksIdx);
const filterBlock = source.slice(plainObjIdx, endIdx);

const contextCode = `
const fs = { read: () => Promise.resolve("{}") };
const SECTION_CACHE_DIR = "/var/run/tachyon/section-cache";
${protocolBlock}
${filterBlock}
return {
  filteredOutboundMetadataFromCache,
  extractCountryFromFlagEmojiName,
  evaluateLiveServerFilterPreview
};
`;

const helpers = new Function(contextCode)();

// 1. Verify filteredOutboundMetadataFromCache preserves securities and ports
const cached = helpers.filteredOutboundMetadataFromCache({
  outboundMetadata: {
    names: { n1: "🇩🇪 Germany 1", n2: "🇳🇱 Netherlands 1", n3: "🇫🇮 Finland HY2" },
    countries: { n1: "DE", n2: "NL", n3: "FI" },
    protocols: { n1: "vless", n2: "vless", n3: "hysteria2" },
    transports: { n1: "xhttp", n2: "tcp", n3: "quic" },
    securities: { n1: "reality", n2: "tls", n3: "tls" },
    ports: { n1: 443, n2: 8443, n3: 443 },
  },
});

assert.strictEqual(cached.securities.n1, "reality");
assert.strictEqual(cached.ports.n2, 8443);

// 2. Verify flag emoji country extraction
assert.strictEqual(helpers.extractCountryFromFlagEmojiName("🇩🇪 Germany 1"), "DE");
assert.strictEqual(helpers.extractCountryFromFlagEmojiName("🇳🇱 Netherlands 1"), "NL");

// 3. Verify include filter with country + proxy parameters ("and" semantics)
const resInclude = helpers.evaluateLiveServerFilterPreview(cached, {
  filterMode: "include",
  detectServerCountry: "flag_emoji",
  includeCountries: ["DE", "NL"],
  includeProxyParameters: "1",
  includeProtocols: ["vless"],
  includeSecurities: ["reality"],
});
assert.strictEqual(resInclude.totalCount, 3);
assert.strictEqual(resInclude.matchedCount, 1);
assert.strictEqual(resInclude.excludedCount, 2);
assert.strictEqual(resInclude.matchedServers[0].tag, "n1");

// 4. Verify exclude filter with port range + regex ("or" semantics)
const resExclude = helpers.evaluateLiveServerFilterPreview(cached, {
  filterMode: "exclude",
  detectServerCountry: "flag_emoji",
  excludeRegex: ["Finland"],
  excludeProxyParameters: "1",
  excludePorts: ["8000-9000"],
});
assert.strictEqual(resExclude.matchedCount, 1);
assert.strictEqual(resExclude.excludedCount, 2);
assert.strictEqual(resExclude.matchedServers[0].tag, "n1");

// 5. Verify mixed filter mode
const resMixed = helpers.evaluateLiveServerFilterPreview(cached, {
  filterMode: "mixed",
  detectServerCountry: "flag_emoji",
  includeCountries: ["DE", "NL", "FI"],
  excludeProxyParameters: "1",
  excludeProtocols: ["hysteria2"],
});
assert.strictEqual(resMixed.matchedCount, 2);
assert.strictEqual(resMixed.excludedCount, 1);
NODE

echo "luci_live_filter_preview: PASS"
