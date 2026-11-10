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
const mockFiles = {
  "/etc/tachyon/subscription-cache/Pool_src_sub_riot-subscription-1.json": JSON.stringify({
    outbounds: [
      {
        type: "vless",
        tag: "🇩🇪 Germany Pool 1",
        server: "de1.example.com",
        server_port: 443,
        tls: { enabled: true, reality: { enabled: true } }
      },
      {
        type: "vless",
        tag: "🇳🇱 Netherlands Pool 2",
        server: "nl2.example.com",
        server_port: 443,
        tls: { enabled: true, reality: { enabled: true } }
      }
    ]
  })
};
const UCI_PACKAGE = "tachyon";
const mockUciSections = {
  section: [
    {
      ".name": "VPN",
      ".type": "section",
      enabled: "1",
      action: "connection",
      outbound_source_refs: ["src_sub_riot", "src_manual_de"],
      balancer_refs: ["urltest", "priority"]
    }
  ],
  outbound_source: [
    {
      ".name": "src_sub_riot",
      ".type": "outbound_source",
      enabled: "1",
      name: "subscribeRiot",
      source_type: "subscription",
      url: "https://sub.example.com/riot",
      prefix_nodes: "0"
    },
    {
      ".name": "src_manual_de",
      ".type": "outbound_source",
      enabled: "1",
      name: "🇩🇪 Германия | VLESS | Multi",
      source_type: "proxy_links",
      proxy_links: ["vless://11111111-1111-1111-1111-111111111111@de.example.com:443#🇩🇪%20Германия%20%7C%20VLESS%20%7C%20Multi"]
    }
  ],
  outbound_group: [],
  balancer: [
    { ".name": "urltest", ".type": "balancer", enabled: "1", balancer_type: "urltest" },
    { ".name": "priority", ".type": "balancer", enabled: "1", balancer_type: "priority" }
  ]
};
const uci = {
  sections: (_pkg, type) => mockUciSections[type] || [],
  get: (_pkg, secId, opt) => {
    for (const list of Object.values(mockUciSections)) {
      const hit = list.find((s) => s[".name"] === secId);
      if (hit) return opt ? hit[opt] : hit;
    }
    return null;
  }
};
const main = {
  getProxyUrlName: (url) => {
    const idx = String(url || "").indexOf("#");
    return idx >= 0 ? decodeURIComponent(String(url).slice(idx + 1)) : "";
  }
};
function normalizeOptionValues(val) {
  if (!val) return [];
  return Array.isArray(val) ? val : String(val).trim().split(/\\s+/).filter(Boolean);
}
function normalizeDynamicListItems(val) {
  return normalizeOptionValues(val);
}
function currentSourceOptionValues(secId, opt) {
  return normalizeOptionValues(uci.get(UCI_PACKAGE, secId, opt));
}
function getRuleResolvedAction(secId) {
  return uci.get(UCI_PACKAGE, secId, "action") || "connection";
}
function readItemSettingsMap() {
  return {};
}
const fs = {
  read: (p) => Promise.resolve(mockFiles[p] || "{}"),
  list: () => Promise.resolve([])
};
const SECTION_CACHE_DIR = "/var/run/tachyon/section-cache";
const SUBSCRIPTION_CACHE_DIR = "/etc/tachyon/subscription-cache";
${protocolBlock}
${filterBlock}
return {
  filteredOutboundMetadataFromCache,
  readOutboundMetadataFromSectionCache,
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

// 6. Verify includePrefixes + includeCountries intersect with AND (#384)
const cachedWithSources = helpers.filteredOutboundMetadataFromCache({
  outboundMetadata: {
    names: {
      s1: "🇩🇪 Germany Sub 1",
      s2: "🇳🇱 Netherlands Sub 2",
      m1: "🇩🇪 Germany Manual",
    },
    countries: { s1: "DE", s2: "NL", m1: "DE" },
    protocols: { s1: "vless", s2: "vless", m1: "vless" },
    transports: { s1: "tcp", s2: "tcp", m1: "tcp" },
    securities: { s1: "reality", s2: "reality", m1: "reality" },
    ports: { s1: 443, s2: 443, m1: 443 },
    sources: { s1: "sub:1", s2: "sub:1", m1: "src_manual_de" },
    source_ids: { s1: "src_sub_riot", s2: "src_sub_riot", m1: "src_manual_de" },
    source_names: {
      s1: "subscribeRiot",
      s2: "subscribeRiot",
      m1: "Germany Manual",
    },
  },
});
const resSubAndCountry = helpers.evaluateLiveServerFilterPreview(
  cachedWithSources,
  {
    filterMode: "include",
    detectServerCountry: "flag_emoji",
    includePrefixes: ["subscribeRiot"],
    includeCountries: ["DE"],
  },
);
assert.strictEqual(resSubAndCountry.totalCount, 3);
assert.strictEqual(resSubAndCountry.matchedCount, 1);
assert.strictEqual(resSubAndCountry.matchedServers[0].tag, "s1");

// 7. Verify readOutboundMetadataFromSectionCache loads subscription pool cache + manual links (#384, #386)
helpers.readOutboundMetadataFromSectionCache("VPN").then((vpnMeta) => {
  const namesList = Object.values(vpnMeta.names || {});
  assert.strictEqual(namesList.length, 3, "Expected 2 subscription nodes + 1 manual link, got: " + JSON.stringify(namesList));
  assert(namesList.includes("🇩🇪 Germany Pool 1"));
  assert(namesList.includes("🇳🇱 Netherlands Pool 2"));
  assert(namesList.includes("🇩🇪 Германия | VLESS | Multi"));
  const preview = helpers.evaluateLiveServerFilterPreview(vpnMeta, {
    filterMode: "include",
    detectServerCountry: "flag_emoji",
    includePrefixes: ["subscribeRiot"],
    includeCountries: ["DE"],
  });
  assert.strictEqual(preview.totalCount, 3);
  assert.strictEqual(preview.matchedCount, 1);
  assert.strictEqual(preview.matchedServers[0].name, "🇩🇪 Germany Pool 1");
}).catch((err) => {
  console.error(err);
  process.exit(1);
});
NODE

echo "luci_live_filter_preview: PASS"
