#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CONNECTIONS="$TACHYON_LIB/config/connections.uc"
VALIDATOR="$TACHYON_LIB/config/validator.uc"
MIGRATION="$TACHYON_LIB/config/migration.uc"
GENERATOR_ROUTES="$TACHYON_LIB/tachyon_core/generator_routes.uc"

# 1. Test Boolean Conditions (AND / OR / NOT), MAC resolution, Cycle Detection, and 2-Mode Rule Tracer
export TACHYON_MOCK_DHCP_LEASES="aa:bb:cc:11:22:33=192.168.1.50"

ucode -L "$TACHYON_LIB" - <<'UCODE'
let connections = require("config.connections");

let fixture = {
    condition: [
        {
            ".name": "baned_domains",
            ".type": "condition",
            enabled: "1",
            name: "Banned Domains",
            condition_type: "atomic",
            domain_suffix: [ "youtube.com", "discord.com" ],
            community_lists: [ "discord" ]
        },
        {
            ".name": "my_devices",
            ".type": "condition",
            enabled: "1",
            name: "My Devices",
            condition_type: "atomic",
            source_macs: [ "AA:BB:CC:11:22:33" ]
        },
        {
            ".name": "ru_whitelist",
            ".type": "condition",
            enabled: "1",
            name: "RU Whitelist",
            condition_type: "atomic",
            domain_suffix: [ "gosuslugi.ru" ]
        },
        {
            ".name": "My_devices_Timbuktu",
            ".type": "condition",
            enabled: "1",
            name: "My Devices Timbuktu",
            condition_type: "composite",
            operator: "and",
            members: [ "baned_domains", "my_devices" ]
        }
    ],
    section: [
        {
            ".name": "Timbuktu",
            ".type": "section",
            enabled: "1",
            name: "Timbuktu Proxy",
            action: "connection",
            condition_expression: "My_devices_Timbuktu AND NOT ru_whitelist"
        }
    ]
};

connections.set_item_sections_from_data(fixture);

// Graph validation must succeed for valid DAG
let graph_ok = connections.validate_condition_graph();
if (!graph_ok.valid) {
    warn("Expected valid condition graph, got: " + graph_ok.message + "\n");
    exit(1);
}

// DNF clause compilation must merge baned_domains + my_devices and attach ru_whitelist as inverted condition
let clauses = connections.section_effective_clauses(fixture.section[0]);
if (length(clauses) != 1) {
    warn("Expected 1 DNF clause, got " + length(clauses) + "\n");
    exit(1);
}
let clause = clauses[0];
let resolved_src_ips = connections.resolved_source_ip_cidrs(clause);
if (length(resolved_src_ips) != 1 || resolved_src_ips[0] != "192.168.1.50") {
    warn("Expected MAC AA:BB:CC:11:22:33 to resolve to 192.168.1.50, got: " + sprintf("%J", resolved_src_ips) + "\n");
    exit(1);
}
if (length(clause.__inverted_conditions || []) != 1 || clause.__inverted_conditions[0][".name"] != "ru_whitelist") {
    warn("Expected ru_whitelist in __inverted_conditions\n");
    exit(1);
}

// Mode 1 (Presence): querying youtube.com alone must find baned_domains, My_devices_Timbuktu, and Timbuktu section
let trace_presence = connections.trace_rules({ mode: "presence", search: "youtube.com" }, fixture.section);
if (length(trace_presence.presence_conditions) != 2) {
    warn("Expected 2 presence_conditions for youtube.com, got: " + sprintf("%J", trace_presence.presence_conditions) + "\n");
    exit(1);
}
if (length(trace_presence.presence_sections) != 1 || trace_presence.presence_sections[0].id != "Timbuktu") {
    warn("Expected Timbuktu in presence_sections for youtube.com\n");
    exit(1);
}
if (length(trace_presence.exact_sections) != 0 || trace_presence.winning_section != null) {
    warn("Expected youtube.com without source device NOT to satisfy exact AND rule\n");
    exit(1);
}

// Mode 2 (Exact): querying youtube.com + MAC AA:BB:CC:11:22:33 must strictly satisfy Timbuktu
let trace_exact = connections.trace_rules({
    mode: "exact",
    domain: "www.youtube.com",
    source_mac: "AA:BB:CC:11:22:33"
}, fixture.section);
if (trace_exact.winning_section == null || trace_exact.winning_section.id != "Timbuktu") {
    warn("Expected Timbuktu to win in exact mode when both domain and MAC match, got: " + sprintf("%J", trace_exact) + "\n");
    exit(1);
}

// Mode 2 (Exact) with NOT condition triggered: gosuslugi.ru must NOT match Timbuktu even if domain_suffix was added
let trace_not = connections.trace_rules({
    mode: "exact",
    domain: "gosuslugi.ru",
    source_mac: "AA:BB:CC:11:22:33"
}, fixture.section);
if (trace_not.winning_section != null) {
    warn("Expected NOT ru_whitelist to block exact match on gosuslugi.ru\n");
    exit(1);
}

// Cycle detection: A -> B -> A must be rejected
let cyclic_fixture = {
    condition: [
        { ".name": "cond_a", ".type": "condition", condition_type: "composite", members: [ "cond_b" ] },
        { ".name": "cond_b", ".type": "condition", condition_type: "composite", members: [ "cond_a" ] }
    ]
};
connections.set_item_sections_from_data(cyclic_fixture);
let cyclic_check = connections.validate_condition_graph();
if (cyclic_check.valid) {
    warn("Expected circular dependency cond_a -> cond_b -> cond_a to fail validation\n");
    exit(1);
}

// Self-reference detection: cond_self -> cond_self must be rejected
let self_fixture = {
    condition: [
        { ".name": "cond_self", ".type": "condition", expression: "cond_self AND other" }
    ]
};
connections.set_item_sections_from_data(self_fixture);
let self_check = connections.validate_condition_graph();
if (self_check.valid) {
    warn("Expected self-referencing condition to fail validation\n");
    exit(1);
}
UCODE

# 2. Test Multi-Stage Outbound Pool Narrowing (Outbound Source -> Outbound Group AND intersection -> Section Exclude -> Reusable URLTest & Priority Balancers)
ucode -L "$TACHYON_LIB" - <<'UCODE'
let connections = require("config.connections");
let routes = require("tachyon_core.generator_routes");

let fixture = {
    outbound_source: [
        {
            ".name": "src_unlim",
            ".type": "outbound_source",
            enabled: "1",
            name: "Unlim Subscription",
            source_type: "subscription",
            url: "https://example.com/unlim",
            prefix_nodes: "1",
            node_prefix: "Unlim"
        },
        {
            ".name": "src_backup",
            ".type": "outbound_source",
            enabled: "1",
            name: "Backup Subscription",
            source_type: "subscription",
            url: "https://example.com/backup",
            prefix_nodes: "1",
            node_prefix: "Backup"
        }
    ],
    outbound_group: [
        {
            ".name": "Unlim_RU",
            ".type": "outbound_group",
            enabled: "1",
            name: "Unlim RU Group",
            source_refs: [ "src_unlim", "src_backup" ],
            filter_mode: "mixed",
            include_prefixes: [ "Unlim" ],
            include_countries: [ "RU" ],
            exclude_regex: [ "Kazan" ]
        },
        {
            ".name": "NL_or_Moscow",
            ".type": "outbound_group",
            enabled: "1",
            name: "NL Flags OR Moscow Regex",
            source_refs: [ "src_unlim" ],
            filter_mode: "include",
            include_countries: [ "NL" ],
            include_regex: [ "Moscow #1" ]
        },
        {
            ".name": "Unlim_NL",
            ".type": "outbound_group",
            enabled: "1",
            name: "Unlim NL Group",
            source_refs: [ "src_unlim" ],
            filter_mode: "include",
            include_prefixes: [ "Unlim" ],
            include_countries: [ "NL" ]
        }
    ],
    balancer: [
        {
            ".name": "Fastest",
            ".type": "balancer",
            enabled: "1",
            name: "Fastest",
            balancer_type: "urltest",
            testing_url: "https://cp.cloudflare.com/generate_204",
            check_interval: "2m",
            tolerance: "35"
        },
        {
            ".name": "RU_Then_NL",
            ".type": "balancer",
            enabled: "1",
            name: "RU Then NL Priority",
            balancer_type: "priority",
            outbound_group_levels: [ "Unlim_RU", "Unlim_NL", "direct" ],
            active_check_interval: "5s",
            check_timeout: "3s",
            recovery_check_interval: "30s"
        }
    ],
    section: [
        {
            ".name": "RU_Services_no_WL",
            ".type": "section",
            enabled: "1",
            action: "connection",
            outbound_group_refs: [ "Unlim_RU" ],
            section_filter_mode: "exclude",
            section_exclude_regex: [ "\\|WL\\|", "Обход" ],
            balancer_refs: [ "Fastest" ]
        }
    ]
};

connections.set_item_sections_from_data(fixture);

let config = { outbounds: [], route: { rules: [] }, dns: { servers: [], rules: [] } };
let candidate_tags = [
    "node-ru-moscow-1",
    "node-ru-spb-wl",
    "node-ru-moscow-bypass",
    "node-ru-kazan",
    "node-nl-ams",
    "node-backup-ru-moscow"
];
let state = require("tachyon_core.subscription").new_section_state("RU_Services_no_WL");
state.outboundMetadata.names = {
    "node-ru-moscow-1": "Unlim 🇷🇺 Moscow #1",
    "node-ru-spb-wl": "Unlim 🇷🇺 SPB |WL|",
    "node-ru-moscow-bypass": "Unlim 🇷🇺 Moscow Обход",
    "node-ru-kazan": "Unlim 🇷🇺 Kazan",
    "node-nl-ams": "Unlim 🇳🇱 Amsterdam",
    "node-backup-ru-moscow": "Backup 🇷🇺 Moscow"
};
state.outboundMetadata.prefixes = {
    "node-ru-moscow-1": "Unlim",
    "node-ru-spb-wl": "Unlim",
    "node-ru-moscow-bypass": "Unlim",
    "node-ru-kazan": "Unlim",
    "node-nl-ams": "Unlim",
    "node-backup-ru-moscow": "Backup"
};

routes.add_proxy_selector(config, fixture.section[0], candidate_tags, candidate_tags, state, "");

let outbounds_by_tag = {};
for (let o in config.outbounds)
    outbounds_by_tag[o.tag] = o;

let urltest_out = outbounds_by_tag["RU_Services_no_WL-urltest-Fastest-out"];
if (urltest_out == null) {
    warn("Expected reusable balancer RU_Services_no_WL-urltest-Fastest-out to be generated\n");
    exit(1);
}
// Only node-ru-moscow-1 should survive:
// - node-backup-ru-moscow fails prefix 'Unlim'
// - node-nl-ams fails country 'RU'
// - node-ru-kazan fails group regex 'Moscow|SPB'
// - node-ru-spb-wl and node-ru-moscow-bypass are narrowed out by section_exclude_regex '|WL|' and 'Обход'
if (length(urltest_out.outbounds) != 1 || urltest_out.outbounds[0] != "node-ru-moscow-1") {
    warn("Expected narrowed urltest outbounds to be ['node-ru-moscow-1'], got: " + sprintf("%J", urltest_out.outbounds) + "\n");
    exit(1);
}
if (urltest_out.url != "https://cp.cloudflare.com/generate_204" || urltest_out.interval != "2m" || urltest_out.tolerance != 35) {
    warn("Expected reusable balancer parameters on urltest outbound, got: " + sprintf("%J", urltest_out) + "\n");
    exit(1);
}

let selector_out = outbounds_by_tag["RU_Services_no_WL-out"];
if (selector_out == null || length(selector_out.outbounds) != 2 ||
    selector_out.outbounds[0] != "node-ru-moscow-1" ||
    selector_out.outbounds[1] != "RU_Services_no_WL-urltest-Fastest-out" ||
    selector_out.default != "RU_Services_no_WL-urltest-Fastest-out") {
    warn("Expected selector outbounds ['node-ru-moscow-1', 'RU_Services_no_WL-urltest-Fastest-out'] with default Fastest, got: " + sprintf("%J", selector_out) + "\n");
    exit(1);
}

// Verify Priority balancer levels synthesized from outbound_group_levels
let prio_levels = connections.priority_levels("RU_Then_NL");
if (length(prio_levels) != 3) {
    warn("Expected 3 priority levels synthesized from outbound_group_levels, got: " + sprintf("%J", prio_levels) + "\n");
    exit(1);
}
if (!connections.priority_level_direct("RU_Then_NL", prio_levels[2])) {
    warn("Expected 3rd priority tier to be direct fallback\n");
    exit(1);
}

// Verify outbound_group with BOTH include_countries ("NL") and include_regex ("Moscow #1")
// combines them via OR (union) instead of returning empty intersection and falling back to all servers.
let union_sec = {
    ".name": "Union_NL_Moscow",
    ".type": "section",
    enabled: "1",
    action: "connection",
    outbound_group_refs: [ "NL_or_Moscow" ]
};
let union_cfg = { outbounds: [], route: { rules: [] }, dns: { servers: [], rules: [] } };
routes.add_proxy_selector(union_cfg, union_sec, candidate_tags, candidate_tags, state, "");
let union_sel = null;
for (let o in union_cfg.outbounds)
    if (o.tag == "Union_NL_Moscow-out")
        union_sel = o;
if (union_sel == null || length(union_sel.outbounds) != 2 ||
    union_sel.outbounds[0] != "node-ru-moscow-1" ||
    union_sel.outbounds[1] != "node-nl-ams") {
    warn("Expected include_countries + include_regex in outbound_group to produce union ['node-ru-moscow-1', 'node-nl-ams'], got: " + sprintf("%J", union_sel) + "\n");
    exit(1);
}
UCODE

# 3. Test Automatic Migration (modular_entities_v1) deduplicating shared subscriptions and extracting conditions & balancers
cat >"$WORK_DIR/legacy_monolithic.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "sec_one",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "community_lists": [ "discord", "youtube" ],
      "ports": [ "443" ]
    },
    {
      ".name": "sec_two",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "domain_suffix": [ "example.org" ]
    }
  ],
  "subscription_url": [
    {
      ".name": "sub1",
      ".type": "subscription_url",
      "section": "sec_one",
      "url": "https://provider.example/shared-sub",
      "prefix_nodes": "1",
      "node_prefix": "Unlim"
    },
    {
      ".name": "sub2",
      ".type": "subscription_url",
      "section": "sec_two",
      "url": "https://provider.example/shared-sub",
      "prefix_nodes": "1",
      "node_prefix": "Unlim"
    }
  ],
  "urltest": [
    {
      ".name": "ut1",
      ".type": "urltest",
      "section": "sec_one",
      "name": "Fastest",
      "check_interval": "3m",
      "tolerance": "50",
      "testing_url": "https://www.gstatic.com/generate_204"
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/legacy_monolithic.json" >"$WORK_DIR/migrated_modular.json"

node - "$WORK_DIR/migrated_modular.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const cfg = out.config;

function assert(cond, msg) {
  if (!cond) {
    console.error(msg);
    process.exit(1);
  }
}

assert(Array.isArray(cfg.condition) && cfg.condition.length === 2, 'Expected 2 extracted condition entities');
assert(Array.isArray(cfg.outbound_source) && cfg.outbound_source.length === 1, 'Expected shared subscription URL to be deduplicated into 1 outbound_source');
assert(cfg.outbound_source[0].url === 'https://provider.example/shared-sub', 'Expected deduplicated subscription URL to match');
assert(Array.isArray(cfg.balancer) && cfg.balancer.length === 1, 'Expected 1 extracted balancer entity');

const secOne = cfg.section.find(s => s['.name'] === 'sec_one');
const secTwo = cfg.section.find(s => s['.name'] === 'sec_two');
assert(JSON.stringify(secOne.condition_refs) === JSON.stringify(['cond_sec_one']), 'sec_one should reference cond_sec_one');
assert(JSON.stringify(secTwo.condition_refs) === JSON.stringify(['cond_sec_two']), 'sec_two should reference cond_sec_two');
assert(JSON.stringify(secOne.outbound_source_refs) === JSON.stringify(['src_sub_1']), 'sec_one should reference src_sub_1');
assert(JSON.stringify(secTwo.outbound_source_refs) === JSON.stringify(['src_sub_1']), 'sec_two should share reference src_sub_1');
assert(JSON.stringify(secOne.balancer_refs) === JSON.stringify(['bal_sec_one_Fastest']), 'sec_one should reference bal_sec_one_Fastest');
NODE

# 4. Test that deleting modular entities after migration does NOT resurrect them on subsequent reloads
# and automatically prunes dangling references from sections/balancers/groups
node - "$WORK_DIR/migrated_modular.json" "$WORK_DIR/deleted_modular_input.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const cfg = out.config;
cfg.outbound_source = [];
cfg.condition = cfg.condition.filter(c => c['.name'] !== 'cond_sec_one');
cfg.balancer = [];
fs.writeFileSync(process.argv[3], JSON.stringify(cfg, null, 2));
NODE

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/deleted_modular_input.json" >"$WORK_DIR/deleted_modular_output.json"

node - "$WORK_DIR/deleted_modular_output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const cfg = out.config;

function assert(cond, msg) {
  if (!cond) {
    console.error(msg);
    process.exit(1);
  }
}

assert(!cfg.outbound_source || cfg.outbound_source.length === 0, 'Deleted outbound_source must NOT be resurrected from legacy subscription_url');
assert(Array.isArray(cfg.condition) && cfg.condition.length === 1 && cfg.condition[0]['.name'] === 'cond_sec_two', 'Deleted condition cond_sec_one must NOT be resurrected');
assert(!cfg.balancer || cfg.balancer.length === 0, 'Deleted balancer must NOT be resurrected from legacy urltest');

const secOne = cfg.section.find(s => s['.name'] === 'sec_one');
const secTwo = cfg.section.find(s => s['.name'] === 'sec_two');
assert(!secOne.outbound_source_refs || secOne.outbound_source_refs.length === 0, 'Dangling outbound_source_refs on sec_one must be pruned');
assert(!secTwo.outbound_source_refs || secTwo.outbound_source_refs.length === 0, 'Dangling outbound_source_refs on sec_two must be pruned');
assert(!secOne.condition_refs || secOne.condition_refs.length === 0, 'Dangling condition_refs on sec_one must be pruned');
assert(!secOne.balancer_refs || secOne.balancer_refs.length === 0, 'Dangling balancer_refs on sec_one must be pruned');
NODE

# 5. Test #252 (unified_delay profile), #253 (ANSI expand_check_error_reason, single leaf strip, dangling outbound dependency), and #255 (subscription_tls_fingerprint)
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"

EXPANDED_REASON="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" expand-check-reason-fixture $'\x1b[31mFATAL\x1b[0m[0000] initialize outbound[52]: parse encryption: invalid encryption key length: 9')"
case "$EXPANDED_REASON" in
  initialize\ outbound\[52\]:*Причина:*) ;;
  *)
    printf 'Unexpected expand_check_error_reason output: %s\n' "$EXPANDED_REASON" >&2
    exit 1
    ;;
esac

cat >"$WORK_DIR/leaf_strip_cfg.json" <<'JSON'
{
  "outbounds": [
    { "type": "vless", "tag": "good-node-1", "server": "1.1.1.1", "server_port": 443 },
    { "type": "vless", "tag": "bad-node-2", "server": "2.2.2.2", "server_port": 443, "encryption": "mlkem768x25519plus.bad" },
    { "type": "selector", "tag": "Proxy-out", "outbounds": [ "good-node-1", "bad-node-2" ], "default": "bad-node-2" },
    { "type": "selector", "tag": "Instagram-out", "outbounds": [ "Proxy-out" ], "default": "Proxy-out" }
  ]
}
JSON

STRIP_RES="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" strip-leaf-outbound-fixture "$WORK_DIR/leaf_strip_cfg.json" "FATAL[0000] initialize outbound[1]: parse encryption: invalid encryption key length: 9")"
[ "$STRIP_RES" = "stripped" ] || { printf 'Expected strip-leaf-outbound-fixture to return stripped, got %s\n' "$STRIP_RES" >&2; exit 1; }

node - "$WORK_DIR/leaf_strip_cfg.json" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const proxySel = cfg.outbounds.find(o => o.tag === 'Proxy-out');
if (!proxySel || JSON.stringify(proxySel.outbounds) !== JSON.stringify(['good-node-1']) || proxySel.default !== 'good-node-1') {
  console.error('Expected Proxy-out to retain good-node-1 after stripping bad-node-2, got:', proxySel);
  process.exit(1);
}
NODE

cat >"$WORK_DIR/dangling_dep_cfg.json" <<'JSON'
{
  "outbounds": [
    { "type": "direct", "tag": "direct-out" },
    { "type": "selector", "tag": "Instagram-CDN-via-Proxy-out", "outbounds": [ "Proxy-out" ], "default": "Proxy-out" }
  ]
}
JSON

DANGLING_RES="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" dangling-dependency-fixture "$WORK_DIR/dangling_dep_cfg.json")"
case "$DANGLING_RES" in
  *dependency\[Proxy-out\]\ not\ found\ for\ outbound\[Instagram-CDN-via-Proxy-out\]*) ;;
  *)
    printf 'Expected dangling dependency on Proxy-out to be reported, got: %s\n' "$DANGLING_RES" >&2
    exit 1
    ;;
esac

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let core_profile = require("tachyon_core.core_profile");
let connections = require("config.connections");

if (!core_profile.supports_unified_delay("1.14.3-extended-2.7.3", "extended")) {
    warn("Expected extended profile to support unified_delay\n");
    exit(1);
}
if (core_profile.supports_unified_delay("0.1.7", "tachyon-core") || core_profile.supports_unified_delay("1.14.3", "")) {
    warn("Expected tachyon-core and upstream profiles to NOT claim unified_delay\n");
    exit(1);
}

connections.set_item_sections_from_data({
    outbound_source: [
        {
            ".name": "src_sub_fp",
            ".type": "outbound_source",
            enabled: "1",
            source_type: "subscription",
            url: "https://provider.example/sub",
            tls_fingerprint: "chrome"
        }
    ],
    section: [
        {
            ".name": "Proxy",
            ".type": "section",
            enabled: "1",
            action: "connection",
            outbound_source_refs: [ "src_sub_fp" ]
        }
    ]
});

let fp = connections.subscription_tls_fingerprint({
    ".name": "Proxy",
    ".type": "section",
    enabled: "1",
    action: "connection",
    outbound_source_refs: [ "src_sub_fp" ]
}, "https://provider.example/sub");
if (fp != "chrome") {
    warn("Expected subscription_tls_fingerprint to return 'chrome', got: " + fp + "\n");
    exit(1);
}
UCODE

printf 'modular redesign #242 checks passed\n'
