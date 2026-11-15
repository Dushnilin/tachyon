#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

export TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions"
mkdir -p "$TMP_SUBSCRIPTION_FOLDER"

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

# 1. Direct unit checks for tachyon_core.urltest telemetry normalization and collision guards
ucode -L "$TACHYON_LIB" -e '
let ut = require("tachyon_core.urltest");

let strip_cases = [
    [ "🇪🇺 [LTE] Europe 1 [154.77 GiB] [VLESS] (#2)", "🇪🇺 [LTE] Europe 1 [VLESS] (#2)" ],
    [ "🇩🇪 Germany 1 (154,77 ГБ)", "🇩🇪 Germany 1" ],
    [ "🇳🇱 NL 1 [12.4 / 200 GB]", "🇳🇱 NL 1" ],
    [ "🇫🇮 Finland [Осталось: 98.5 ГБ]", "🇫🇮 Finland" ],
    [ "🇺🇸 US West | 154.77 GiB | 28d", "🇺🇸 US West" ],
    [ "🇵🇱 Poland [exp: 2026-12-31]", "🇵🇱 Poland" ],
    [ "🇸🇪 Sweden [До 15.12] [Traffic: 45%]", "🇸🇪 Sweden" ],
    [ "🇬🇧 UK [Exp: 2d]", "🇬🇧 UK" ],
    [ "🇩🇪 Germany 1 [10 Gbps]", "🇩🇪 Germany 1 [10 Gbps]" ],
    [ "🇳🇱 Node (100 Mbit/s)", "🇳🇱 Node (100 Mbit/s)" ],
    [ "Node [2D] (#2)", "Node [2D] (#2)" ],
    [ "Server (1)", "Server (1)" ]
];

for (let pair in strip_cases) {
    let actual = ut.strip_dynamic_server_telemetry(pair[0]);
    if (actual != pair[1]) {
        die("strip_dynamic_server_telemetry mismatch for \"" + pair[0] +
            "\": expected \"" + pair[1] + "\", got \"" + actual + "\"\n");
    }
}

if (!ut.name_filter_contains([ "🇪🇺 [LTE] Europe 1 [154.77 GiB]" ], "🇪🇺 [LTE] Europe 1 [151.02 GiB]"))
    die("name_filter_contains must match renamed quota for Europe 1\n");

if (ut.name_filter_contains([ "🇪🇺 [LTE] Europe 1 [154.77 GiB]" ], "🇪🇺 [LTE] Europe 1.1 [151.02 GiB]"))
    die("name_filter_contains must NOT collide Europe 1 with Europe 1.1\n");

if (ut.name_filter_contains([ "🇩🇪 Germany 1 [10 Gbps]" ], "🇩🇪 Germany 1 [1 Gbps]"))
    die("name_filter_contains must NOT collide 10 Gbps with 1 Gbps\n");

if (ut.name_filter_contains([ "Server (1)" ], "Server (2)"))
    die("name_filter_contains must NOT collide Server (1) with Server (2)\n");
' || fail "tachyon_core.urltest telemetry normalization checks failed"

# 2. End-to-end generator.uc fixture: dashboard exclusions and outbound_group exclusions across quota updates
node - "$WORK_DIR" <<'JS'
const fs = require("fs");
const dir = process.argv[2];

const fixture = {
  settings: {
    ".name": "settings",
    ".type": "settings",
    dns_server: "1.1.1.1",
    service_listen_address: "127.0.0.1",
    log_level: "warn"
  },
  outbound_source: [
    {
      ".name": "src_suba",
      ".type": "outbound_source",
      enabled: "1",
      name: "SubA",
      source_type: "subscription",
      url: "https://example.test/suba",
      prefix_nodes: "1",
      node_prefix: "SubA"
    }
  ],
  outbound_group: [
    {
      ".name": "grp_eu",
      ".type": "outbound_group",
      enabled: "1",
      name: "EU Group",
      source_refs: ["src_suba"],
      filter_mode: "exclude",
      exclude_outbounds: [
        "[SubA] 🇪🇺 [LTE] Europe 1.3 [154.77 GiB]"
      ]
    }
  ],
  section: [
    {
      ".name": "sec_dash",
      ".type": "section",
      enabled: "1",
      action: "proxy",
      domain_suffix: ["dash.example"],
      subscription_urls: ["https://example.test/dash"],
      dashboard_filter_mode: "exclude",
      dashboard_exclude_outbounds: [
        "🇪🇺 [LTE] Europe 1 [154.77 GiB]",
        "🇪🇺 [LTE] Europe 1.1 [154.77 GiB]",
        "🇩🇪 Germany 1 [10 Gbps]"
      ]
    },
    {
      ".name": "sec_collision",
      ".type": "section",
      enabled: "1",
      action: "proxy",
      domain_suffix: ["collision.example"],
      subscription_urls: ["https://example.test/dash"],
      dashboard_filter_mode: "exclude",
      dashboard_exclude_outbounds: [
        "🇪🇺 [LTE] Europe 1 [154.77 GiB]"
      ]
    },
    {
      ".name": "sec_group",
      ".type": "section",
      enabled: "1",
      action: "proxy",
      domain_suffix: ["group.example"],
      outbound_group_refs: ["grp_eu"]
    }
  ]
};

fs.writeFileSync(dir + "/fixture.json", JSON.stringify(fixture, null, 2));

// Updated subscription nodes where quota/expiry changed since the user saved exclusions
const dashRaw = [
  { type: "socks", tag: "🇪🇺 [LTE] Europe 1 [151.02 GiB]", server: "198.51.100.1", server_port: 1080 },
  { type: "socks", tag: "🇪🇺 [LTE] Europe 1.1 [151.02 GiB]", server: "198.51.100.2", server_port: 1080 },
  { type: "socks", tag: "🇪🇺 [LTE] Europe 1.2 [151.02 GiB]", server: "198.51.100.3", server_port: 1080 },
  { type: "socks", tag: "🇩🇪 Germany 1 [10 Gbps]", server: "198.51.100.4", server_port: 1080 },
  { type: "socks", tag: "🇩🇪 Germany 1 [1 Gbps]", server: "198.51.100.5", server_port: 1080 }
];
fs.writeFileSync(dir + "/raw-dash.json", JSON.stringify(dashRaw));

const subaRaw = [
  { type: "socks", tag: "🇪🇺 [LTE] Europe 1.2 (151,02 ГБ)", server: "198.51.100.12", server_port: 1080 },
  { type: "socks", tag: "🇪🇺 [LTE] Europe 1.3 [151.02 GiB]", server: "198.51.100.13", server_port: 1080 },
  { type: "socks", tag: "🇳🇱 NL 1 [12.4 / 200 GB]", server: "198.51.100.14", server_port: 1080 }
];
fs.writeFileSync(dir + "/raw-suba.json", JSON.stringify(subaRaw));
JS

for pair in "sec_dash-subscription-1:raw-dash:https://example.test/dash" \
            "sec_collision-subscription-1:raw-dash:https://example.test/dash" \
            "src_suba-subscription-1:raw-suba:https://example.test/suba"; do
  cache_name="${pair%%:*}"
  rest="${pair#*:}"
  raw_name="${rest%%:*}"
  url="${rest#*:}"
  cache="$TMP_SUBSCRIPTION_FOLDER/$cache_name"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/parser.uc" \
    normalize-content-validated "$WORK_DIR/$raw_name.json" "$cache.json"
  printf '%s' "$url" >"$cache.url"
  printf 'Happ' >"$cache.user_agent"
done

OUT_CFG="$WORK_DIR/generated.json"
mkdir -p "${OUT_CFG}.section-cache"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$OUT_CFG" "127.0.0.1" "0" >"$WORK_DIR/gen.log" 2>&1 || {
    cat "$WORK_DIR/gen.log" >&2
    fail "generator.uc generate-config-fixture failed"
  }

node - "$OUT_CFG" "${OUT_CFG}.section-cache" <<'JS'
const fs = require("fs");
const assert = require("assert").strict;
const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const cacheDir = process.argv[3];

const byTag = new Map((cfg.outbounds || []).map((o) => [o.tag, o]));
const byServer = new Map((cfg.outbounds || []).filter((o) => o.server).map((o) => [o.server, o.tag]));

// Verify outbound_group exclusion kept working after [154.77 GiB] -> [151.02 GiB]
const secGroupSel = byTag.get("sec_group-out");
assert(secGroupSel, "sec_group-out selector must be generated");
const secGroupMembers = new Set(secGroupSel.outbounds || []);
const eu12Tag = (cfg.outbounds || []).find((o) => o.server === "198.51.100.12");
const eu13Tag = (cfg.outbounds || []).find((o) => o.server === "198.51.100.13");
const nl1Tag = (cfg.outbounds || []).find((o) => o.server === "198.51.100.14");
assert(eu12Tag && secGroupMembers.has(eu12Tag.tag), "Europe 1.2 from outbound_group must remain in sec_group-out");
assert(nl1Tag && secGroupMembers.has(nl1Tag.tag), "NL 1 from outbound_group must remain in sec_group-out");
assert(!eu13Tag || !secGroupMembers.has(eu13Tag.tag), "Excluded Europe 1.3 must not reappear in sec_group-out when quota changes");

// Verify section selector & dashboard exclusions in sec_dash
const dashSel = byTag.get("sec_dash-out");
assert(dashSel, "sec_dash-out selector must be generated");
const dashOutbounds = dashSel.outbounds || [];
const dashCache = JSON.parse(fs.readFileSync(cacheDir + "/sec_dash.json", "utf8"));
const dashHidden = new Set(Object.keys(dashCache.hiddenOutboundTags || {}));
assert(!dashOutbounds.some((n) => n.includes("Europe 1 [")), "sec_dash-out must keep Europe 1 excluded");
assert(!dashOutbounds.some((n) => n.includes("Europe 1.1 [")), "sec_dash-out must keep Europe 1.1 excluded");
assert(dashOutbounds.some((n) => n.includes("Europe 1.2 [")), "sec_dash-out must keep Europe 1.2 visible");
assert(!dashOutbounds.some((n) => n.includes("[10 Gbps]")), "sec_dash-out must exclude Germany 1 [10 Gbps]");
assert(dashOutbounds.some((n) => n.includes("[1 Gbps]")), "sec_dash-out must NOT exclude Germany 1 [1 Gbps]");
assert(dashHidden.has("🇪🇺 [LTE] Europe 1 [151.02 GiB]"), "sec_dash cache must mark Europe 1 hidden");
assert(dashHidden.has("🇪🇺 [LTE] Europe 1.1 [151.02 GiB]"), "sec_dash cache must mark Europe 1.1 hidden");
assert(!dashHidden.has("🇪🇺 [LTE] Europe 1.2 [151.02 GiB]"), "sec_dash cache must not mark Europe 1.2 hidden");
assert(dashHidden.has("🇩🇪 Germany 1 [10 Gbps]"), "sec_dash cache must mark Germany 1 [10 Gbps] hidden");
assert(!dashHidden.has("🇩🇪 Germany 1 [1 Gbps]"), "sec_dash cache must not mark Germany 1 [1 Gbps] hidden");

// Verify Europe 1 exclusion does NOT touch Europe 1.1
const collSel = byTag.get("sec_collision-out");
assert(collSel, "sec_collision-out selector must be generated");
const collOutbounds = collSel.outbounds || [];
const collCache = JSON.parse(fs.readFileSync(cacheDir + "/sec_collision.json", "utf8"));
const collHidden = new Set(Object.keys(collCache.hiddenOutboundTags || {}));
const collNamesMap = (collCache.outboundMetadata && collCache.outboundMetadata.names) || {};
const collHiddenNames = Array.from(collHidden).map((t) => collNamesMap[t] || t);
assert(!collOutbounds.some((n) => n.includes("Europe 1 [")), "sec_collision-out must exclude Europe 1");
assert(collOutbounds.some((n) => n.includes("Europe 1.1 [")), "sec_collision-out must keep Europe 1.1 visible");
assert(collOutbounds.some((n) => n.includes("Europe 1.2 [")), "sec_collision-out must keep Europe 1.2 visible");
assert(collHiddenNames.includes("🇪🇺 [LTE] Europe 1 [151.02 GiB]"), "sec_collision cache must mark Europe 1 hidden");
assert(!collHiddenNames.includes("🇪🇺 [LTE] Europe 1.1 [151.02 GiB]"), "sec_collision cache must NOT mark Europe 1.1 hidden");
JS

# 3. Direct checks on config.connections and tachyon_core.generator_routes with changed telemetry
ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let connections = require("config.connections");
let routes = require("tachyon_core.generator_routes");
let subscription = require("tachyon_core.subscription");

let fixture = json(fs.readfile(ARGV[0]));
push(fixture.section, {
    ".name": "sec_prio",
    ".type": "section",
    "enabled": "1",
    "action": "proxy",
    "section_selection_mode": "priority_failover",
    "outbound_group_levels": [ "srv:[SubA] 🇪🇺 [LTE] Europe 1.3 [154.77 GiB]" ]
});
connections.set_item_sections_from_data(fixture);

let prio_sec = fixture.section[length(fixture.section) - 1];
let levels = connections.priority_level_items("sec_prio", prio_sec, false);
let expanded = length(levels) > 0 ? (levels[0].include_outbounds || []) : [];
let has_canon_prefixed = false;
let has_canon_bare = false;
for (let item in expanded) {
    if (item == "[SubA] 🇪🇺 [LTE] Europe 1.3")
        has_canon_prefixed = true;
    if (item == "🇪🇺 [LTE] Europe 1.3")
        has_canon_bare = true;
}
if (!has_canon_prefixed || !has_canon_bare)
    die("priority_level_items must emit canonical telemetry-free variants, got: " + sprintf("%J", expanded) + "\n");

let st = subscription.new_section_state("sec_dash");
let tags = [ "n1", "n2", "n3" ];
st.outboundMetadata.names = {
    "n1": "🇪🇺 [LTE] Europe 1 [151.02 GiB]",
    "n2": "🇪🇺 [LTE] Europe 1.1 [151.02 GiB]",
    "n3": "🇪🇺 [LTE] Europe 1.2 [151.02 GiB]"
};
let filtered = routes.dashboard_filtered_outbounds(fixture.section[0], tags, st);
if (length(filtered) != 1 || filtered[0] != "n3")
    die("dashboard_filtered_outbounds expected only [\"n3\"], got: " + sprintf("%J", filtered) + "\n");
' "$WORK_DIR/fixture.json" || fail "config.connections and generator_routes canonical exclusion checks failed"

printf 'subscription_dynamic_server_exclusions: PASS\n'
