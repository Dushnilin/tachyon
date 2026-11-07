#!/usr/bin/env bash
# Regression test for:
# 1. Disappearing subscription servers when an outbound_group is attached to a
#    section that already has explicit outbound_source_refs, plus matching
#    "[Prefix] Name" filters against nodes whose name already starts with "Prefix ".
# 2. Adaptive balancer modes (stability, least_load, etc.) defaulting to
#    interrupt_exist_connections=false so live sessions are not killed on jitter shifts.
# 3. IPv6 AAAA leak and forced 15s DNS TTL on bypass / dnsmasq fallback rules when
#    ipv6_enabled='0'.
# 4. priority.uc state preservation on restart and single-spike RTT recheck before
#    same-tier switching.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# --- Part 1 & 2: Outbound groups + explicit sources + [Prefix] matching + Stability interrupt=false ---
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let connections = require("config.connections");
let routes = require("tachyon_core.generator_routes");
let subscription = require("tachyon_core.subscription");

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

routes.init({
    uci_cursor: function() { return null; },
    runtime_settings: function() { return {}; },
    runtime_generate_unsupported: function(msg) { warn("Unsupported: " + msg + "\n"); exit(1); },
    detect_sing_box_version: function() { return "0.2.3"; },
    is_sb_1_14_plus: function() { return true; },
    is_sb_1_15_plus: function() { return true; },
    is_sing_box_lx: function() { return false; },
    is_tachyon_core: function() { return true; }
});

let fixture = {
    settings: {
        ".name": "settings",
        ".type": "settings"
    },
    outbound_source: [
        {
            ".name": "src_sub_1",
            ".type": "outbound_source",
            enabled: "1",
            name: "Cloud VPN",
            source_type: "subscription",
            url: "https://sub.example.com/clouds",
            prefix_nodes: "1",
            node_prefix: "Clouds"
        },
        {
            ".name": "SoftPortal",
            ".type": "outbound_source",
            enabled: "1",
            name: "fsoft",
            source_type: "subscription",
            url: "https://sub.example.com/fsoft",
            prefix_nodes: "0"
        },
        {
            ".name": "test_grpc",
            ".type": "outbound_source",
            enabled: "1",
            name: "OrganicVPN",
            source_type: "subscription",
            url: "https://sub.example.com/organic",
            prefix_nodes: "0"
        }
    ],
    outbound_group: [
        {
            ".name": "Germany",
            ".type": "outbound_group",
            enabled: "1",
            name: "Germany",
            source_refs: [ "src_sub_1", "SoftPortal" ],
            filter_mode: "include",
            include_outbounds: [
                "[Clouds] 🇩🇪  Германия (MEGA)",
                "🇩🇪 GERMANY XHTTP #8"
            ]
        },
        {
            ".name": "grp_awg",
            ".type": "outbound_group",
            enabled: "1",
            name: "AWG Group",
            source_refs: [ "src_sub_1" ],
            filter_mode: "disabled"
        },
        {
            ".name": "grp_fptn",
            ".type": "outbound_group",
            enabled: "1",
            name: "FPTN Group",
            source_refs: [ "SoftPortal" ],
            filter_mode: "exclude",
            exclude_outbounds: [ "🇫🇮 FINLAND XHTTP #1" ]
        }
    ],
    balancer: [
        {
            ".name": "Stability",
            ".type": "balancer",
            enabled: "1",
            name: "Stability",
            balancer_type: "urltest",
            mode: "stability",
            check_interval: "2m",
            active_check_interval: "5s",
            tolerance: "50"
        },
        {
            ".name": "Priority",
            ".type": "balancer",
            enabled: "1",
            name: "Priority",
            balancer_type: "priority",
            outbound_group_levels: [ "Germany", "src_sub_1", "SoftPortal", "test_grpc" ]
        },
        {
            ".name": "PriorityTiers",
            ".type": "balancer",
            enabled: "1",
            name: "PriorityTiers",
            balancer_type: "priority",
            outbound_group_levels: [ "grp_awg", "grp_fptn" ]
        }
    ],
    section: [
        {
            ".name": "Main",
            ".type": "section",
            enabled: "1",
            action: "connection",
            outbound_source_refs: [ "src_sub_1", "SoftPortal", "test_grpc" ],
            outbound_group_refs: [ "Germany" ],
            balancer_refs: [ "Stability", "Priority", "PriorityTiers" ]
        },
        {
            ".name": "FilteredSec",
            ".type": "section",
            enabled: "1",
            action: "connection",
            outbound_source_refs: [ "src_sub_1" ],
            outbound_group_refs: [ "Germany" ],
            balancer_refs: [ "Stability" ]
        }
    ]
};

connections.set_item_sections_from_data(fixture);

let candidates = [
    "cloud-de-mega",
    "cloud-nl-1",
    "fsoft-de-8",
    "fsoft-fi-1",
    "organic-us-1"
];

let state = subscription.new_section_state("Main");
state.outboundMetadata.names = {
    "cloud-de-mega": "Clouds 🇩🇪  Германия (MEGA)",
    "cloud-nl-1": "Clouds 🇳🇱 Нидерланды",
    "fsoft-de-8": "🇩🇪 GERMANY XHTTP #8",
    "fsoft-fi-1": "🇫🇮 FINLAND XHTTP #1",
    "organic-us-1": "🇺🇸 USA Reality"
};
state.outboundMetadata.prefixes = {
    "cloud-de-mega": "Clouds",
    "cloud-nl-1": "Clouds"
};
state.outboundMetadata.sources = {
    "cloud-de-mega": "sub:1",
    "cloud-nl-1": "sub:1",
    "fsoft-de-8": "sub:2",
    "fsoft-fi-1": "sub:2",
    "organic-us-1": "sub:3"
};
state.outboundMetadata.source_ids = {
    "cloud-de-mega": "src_sub_1",
    "cloud-nl-1": "src_sub_1",
    "fsoft-de-8": "SoftPortal",
    "fsoft-fi-1": "SoftPortal",
    "organic-us-1": "test_grpc"
};

let cfg = { outbounds: [], route: { rules: [] }, dns: { servers: [], rules: [] } };
routes.add_proxy_selector(cfg, fixture.section[0], candidates, candidates, state, "");

let by_tag = {};
for (let o in cfg.outbounds)
    by_tag[o.tag] = o;

let main_sel = by_tag["Main-out"];
assert(main_sel != null, "Main-out selector must be generated");

// 1a. All 5 servers from the 3 explicitly attached sources must remain visible in Main-out
for (let expected_tag in candidates) {
    assert(index(main_sel.outbounds, expected_tag) >= 0,
        "Main-out must retain server '" + expected_tag + "' from explicit outbound_source_refs even when outbound_group_refs is present, got: " + sprintf("%J", main_sel.outbounds));
    assert(!state.hiddenOutboundTags[expected_tag],
        "Server '" + expected_tag + "' must not be marked hidden in state.hiddenOutboundTags");
}

// 1b. Germany group must match "[Clouds] 🇩🇪  Германия (MEGA)" against "Clouds 🇩🇪  Германия (MEGA)"
let prio_cached = state.priorityGroups["Main-priority-Priority-out"];
assert(prio_cached != null && length(prio_cached.levels) == 4,
    "Priority group must have 4 levels, got: " + sprintf("%J", prio_cached));
let lvl0_outbounds = prio_cached.levels[0].outbounds;
assert(index(lvl0_outbounds, "cloud-de-mega") >= 0 && index(lvl0_outbounds, "fsoft-de-8") >= 0,
    "Priority level 0 (Germany) must include both 'cloud-de-mega' and 'fsoft-de-8', got: " + sprintf("%J", lvl0_outbounds));

// 1c. Outbound groups with filter_mode='disabled' or 'exclude' must strictly scope by source_refs in Priority levels
let prio_tiers = state.priorityGroups["Main-priority-PriorityTiers-out"];
assert(prio_tiers != null && length(prio_tiers.levels) == 2,
    "PriorityTiers must have 2 levels (grp_awg -> grp_fptn), got: " + sprintf("%J", prio_tiers));
let tier0 = prio_tiers.levels[0].outbounds;
assert(length(tier0) == 2 && index(tier0, "cloud-de-mega") >= 0 && index(tier0, "cloud-nl-1") >= 0,
    "PriorityTiers level 0 (grp_awg with filter_mode=disabled and source_refs=[src_sub_1]) must only include src_sub_1 nodes, got: " + sprintf("%J", tier0));
let tier1 = prio_tiers.levels[1].outbounds;
assert(length(tier1) == 1 && tier1[0] == "fsoft-de-8",
    "PriorityTiers level 1 (grp_fptn with filter_mode=exclude and source_refs=[SoftPortal]) must only include remaining SoftPortal node, got: " + sprintf("%J", tier1));

// 1d. Section with outbound_source_refs=['src_sub_1'] and outbound_group_refs=['Germany'] (without Priority level referencing src_sub_1)
// must filter its pool to ONLY nodes matching Germany ('cloud-de-mega'), excluding 'cloud-nl-1'
let state_filt = subscription.new_section_state("FilteredSec");
state_filt.outboundMetadata = state.outboundMetadata;
let cfg_filt = { outbounds: [], route: { rules: [] }, dns: { servers: [], rules: [] } };
let filt_candidates = [ "cloud-de-mega", "cloud-nl-1" ];
routes.add_proxy_selector(cfg_filt, fixture.section[1], filt_candidates, filt_candidates, state_filt, "");
let filt_by_tag = {};
for (let o in cfg_filt.outbounds)
    filt_by_tag[o.tag] = o;
let filt_sel = filt_by_tag["FilteredSec-out"];
let filt_ut = filt_by_tag["FilteredSec-urltest-Stability-out"];
assert(filt_sel != null && index(filt_sel.outbounds, "cloud-de-mega") >= 0 && index(filt_sel.outbounds, "cloud-nl-1") < 0,
    "FilteredSec-out must only include 'cloud-de-mega' from attached Germany group and exclude 'cloud-nl-1', got: " + sprintf("%J", filt_sel ? filt_sel.outbounds : null));
assert(filt_ut != null && length(filt_ut.outbounds) == 1 && filt_ut.outbounds[0] == "cloud-de-mega",
    "FilteredSec-urltest-Stability-out must only include 'cloud-de-mega', got: " + sprintf("%J", filt_ut ? filt_ut.outbounds : null));
assert(state_filt.hiddenOutboundTags["cloud-nl-1"] == true,
    "FilteredSec must mark 'cloud-nl-1' hidden in state.hiddenOutboundTags");

// 2. Stability balancer must default to interrupt_exist_connections === false, while Main-out selector keeps true
let stab_out = by_tag["Main-urltest-Stability-out"];
assert(stab_out != null, "Main-urltest-Stability-out must be generated");
assert(stab_out.interrupt_exist_connections === false,
    "Stability balancer must default to interrupt_exist_connections=false so active connections are not dropped on jitter shift, got: " + sprintf("%J", stab_out.interrupt_exist_connections));
assert(stab_out.interval == "2m",
    "Stability balancer must ignore leftover priority active_check_interval='5s' and use check_interval='2m', got: " + sprintf("%J", stab_out.interval));
assert(main_sel.interrupt_exist_connections === true,
    "Main-out selector must keep interrupt_exist_connections=true by default");

print("✓ Part 1 & 2 passed\n");
UCODE

# --- Part 3: DNS strategy ipv4_only when ipv6_enabled='0' and no forced 15s rewrite_ttl on bypass / dnsmasq ---
cat >"$WORK_DIR/dns-ipv6-off.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "ipv6_enabled": "0",
    "dns_type": "doh",
    "dns_server": "common.dot.dns.yandex.net",
    "bootstrap_dns_server": "77.88.8.8",
    "excluded_clients": [ "192.168.1.50" ]
  },
  "section": [
    {
      ".name": "ByPass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "routed_dns_enabled": "0",
      "source_ip_cidr": [ "192.168.1.0/24" ],
      "user_domains": [ "kimi.ai" ],
      "community_lists": [ "russia_outside" ]
    }
  ]
}
JSON

OUTPUT_DNS="$WORK_DIR/dns-out.json"
mkdir -p "$OUTPUT_DNS.section-cache" "$OUTPUT_DNS.rulesets"
TACHYON_LIB="$TACHYON_LIB" \
TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing.json" \
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
  "$WORK_DIR/dns-ipv6-off.json" "$OUTPUT_DNS" 192.168.1.1 0

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - "$OUTPUT_DNS" <<'UCODE'
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

assert(cfg.dns.strategy == "ipv4_only",
    "When ipv6_enabled='0' and dns_strategy is not ipv6, dns.strategy must be 'ipv4_only' to prevent AAAA leaks, got: " + sprintf("%J", cfg.dns.strategy));

for (let r in cfg.dns.rules || []) {
    if (r.server == "dnsmasq-server") {
        assert(r.rewrite_ttl == null,
            "dnsmasq-server rule must not force rewrite_ttl=15 when dns_rewrite_ttl is not set, got: " + sprintf("%J", r));
    }
    if (r.server == "dns-server" && r.action == "route") {
        assert(r.rewrite_ttl == null,
            "bypass section dns-server rule must not force rewrite_ttl=15 when dns_rewrite_ttl is not set, got: " + sprintf("%J", r));
    }
}

print("✓ Part 3 passed\n");
UCODE

# --- Part 4: priority.uc activeDelay reporting in choose_fastest_same_level ---
TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let priority = require("tachyon_core.priority");

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

let grp = {
    tag: "Main-priority-Priority-out",
    kind: "priority",
    tolerance: 50,
    levels: [
        { outbounds: [ "node-a", "node-b" ] }
    ]
};

let res = priority.choose_fastest_same_level(grp, 0, "node-a", function(tag_name) {
    if (tag_name == "node-a")
        return { alive: true, delay: 285 };
    return { alive: true, delay: 149 };
});

assert(res != null && res.tag == "node-b", "choose_fastest_same_level must pick node-b when active spiked to 285ms");
assert(res.activeDelay === 285,
    "choose_fastest_same_level must expose activeDelay (285) so tick_group can detect single-spike anomaly against prior activeDelay, got: " + sprintf("%J", res));

print("✓ Part 4 passed\n");
UCODE
