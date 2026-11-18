#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RUNTIME_MIGRATION="$TACHYON_LIB/config/migration.uc"
INSTALLER="$ROOT_DIR/install.sh"
MIGRATION="$RUNTIME_MIGRATION"
MIGRATIONS_DIR="$TACHYON_LIB/config/migrations"

if grep -n -E 'TACHYON_CONFIG_MIGRATION_EOF|installer_config_migration_path' "$INSTALLER" >/dev/null 2>&1; then
  fail "install.sh must not embed configuration migration logic"
fi
[ -s "$MIGRATION" ] || fail "runtime configuration migration module is missing"
[ ! -e "$MIGRATIONS_DIR" ] || fail "configuration migrations must stay in one migration.uc file"

if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$MIGRATION" >/dev/null 2>&1; then
  fail "installer config migration must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$MIGRATION" ||
  fail "installer config migration must import core.uci"
grep -Fq '{ id: "interface_sections", run: migrate_interface_sections }' "$MIGRATION" ||
  fail "interface section migration must have a stable named marker"
grep -Fq '{ id: "enable_component_checks", run: migrate_enable_component_checks }' "$MIGRATION" ||
  fail "component check migration must have a stable named marker"
grep -Fq '{ id: "http_connection_urls", run: migrate_http_connection_urls }' "$MIGRATION" ||
  fail "HTTP connection URL migration must have a stable named marker"
grep -Fq '{ id: "ensure_dns_server_defaults", run: migrate_ensure_dns_server_defaults }' "$MIGRATION" ||
  fail "DNS server defaults migration must have a stable named marker"
grep -Fq 'release_at_most(ctx, "1.0.1")' "$MIGRATION" ||
  fail "release-specific migrations must use the source release only as a condition"
grep -Fq 'release_at_most(ctx, "1.0.4")' "$MIGRATION" ||
  fail "HTTP connection URLs must only migrate from 1.0.4 and below"

# Native Tachyon migration semantics: priority_level -> outbound_group (including regex alias),
# urltest -> balancer, scalar/list domain and domain_text extraction -> condition,
# validator.uc fixture check, connections.trace_rules verification, and idempotency.
cat >"$WORK_DIR/native-semantics.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.4",
    "dns_server": [ "9.9.9.9" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443#Alpha"
      ],
      "domain": [
        "example.com",
        "full:exact.example.net",
        "keyword:video",
        "regex:^api[.]example[.]org$"
      ]
    },
    {
      ".name": "scalar_dom",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000002@example.com:443#Beta"
      ],
      "domain": "scalar.example full:exact-scalar.example"
    },
    {
      ".name": "text_dom",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000003@example.com:443#Gamma"
      ],
      "domain_text_mode": "1",
      "domain_text": "exact-text.example",
      "domain_suffix_text_mode": "1",
      "domain_suffix_text": "textdom.example"
    }
  ],
  "priority_group": [
    {
      ".name": "pg_main",
      ".type": "priority_group",
      "section": "main",
      "name": "Primary"
    }
  ],
  "priority_level": [
    {
      ".name": "pl_inc",
      ".type": "priority_level",
      "group": "pg_main",
      "order": "1",
      "name": "Level1",
      "filter_mode": "include",
      "include_regex": [ "US.*", "DE.*" ],
      "exclude_regex": ".*bad.*"
    },
    {
      ".name": "pl_legacy_re",
      ".type": "priority_level",
      "group": "pg_main",
      "order": "2",
      "name": "Level2",
      "filter_mode": "include",
      "regex": "NL.*"
    }
  ],
  "urltest": [
    {
      ".name": "ut_main",
      ".type": "urltest",
      "section": "main",
      "name": "Fastest",
      "check_interval": "3m",
      "tolerance": "50"
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/native-semantics.json" >"$WORK_DIR/native-semantics-out.json"

node - "$WORK_DIR/native-semantics-out.json" "$WORK_DIR/native-semantics-config.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = out.config;

function assert(cond, msg) {
  if (!cond) {
    console.error(msg);
    process.exit(1);
  }
}

assert(out.changed === true, '1.0.4 native fixture should migrate');
assert(config.settings.config_version === '1.8.0', 'migrated config_version must be 1.8.0');

const sections = Object.fromEntries((config.section || []).map(s => [s['.name'], s]));
const groups = config.outbound_group || [];
const balancers = config.balancer || [];
const conditions = config.condition || [];

assert(groups.length >= 2, 'priority_level entries must migrate to outbound_group sections');
assert(groups.some(g => Array.isArray(g.include_regex) && g.include_regex.includes('US.*') && g.include_regex.includes('DE.*')),
  'outbound_group must preserve array include_regex');
assert(groups.some(g => Array.isArray(g.exclude_regex) ? g.exclude_regex.includes('.*bad.*') : g.exclude_regex === '.*bad.*'),
  'outbound_group must preserve scalar exclude_regex');
assert(groups.some(g => Array.isArray(g.include_regex) ? g.include_regex.includes('NL.*') : g.include_regex === 'NL.*'),
  'outbound_group must preserve legacy regex alias as include_regex');
assert((sections.main.outbound_group_refs || []).length >= 2, 'section must reference migrated outbound_groups');

assert(balancers.some(b => b.name === 'Fastest'), 'urltest must migrate to balancer Fastest');
assert((sections.main.balancer_refs || []).length >= 1, 'section must reference migrated balancer');

assert(conditions.length >= 3, 'domain/domain_text rules must extract to condition sections');
for (const name of ['main', 'scalar_dom', 'text_dom']) {
  assert(Boolean(sections[name].condition_refs && sections[name].condition_refs.length), `${name} must reference extracted condition`);
}

fs.writeFileSync(process.argv[3], JSON.stringify(config, null, 2) + '\n');
NODE

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/config/validator.uc" validate-runtime-fixture "$WORK_DIR/native-semantics-config.json" '{}'

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/native-semantics-config.json" >"$WORK_DIR/native-semantics-out2.json"
node - "$WORK_DIR/native-semantics-out2.json" <<'NODE'
const fs = require('fs');
const out2 = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out2.changed !== false) {
  console.error('Second migration pass on migrated native semantics config must be a no-op');
  process.exit(1);
}
NODE

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - "$WORK_DIR/native-semantics-config.json" <<'UCODE'
let fs = require("fs");
let connections = require("config.connections");
let fixture = json(fs.readfile(ARGV[0]));
for (let s in (fixture.section || [])) {
    delete s.domain;
    delete s.domain_text;
    delete s.domain_text_mode;
    delete s.domain_suffix_text;
    delete s.domain_suffix_text_mode;
}
connections.set_item_sections_from_data(fixture);
let check_win = function(domain, expected_id) {
    let tr = connections.trace_rules({ mode: "exact", domain }, fixture.section);
    if (tr.winning_section == null || tr.winning_section.id != expected_id) {
        warn("Expected " + domain + " -> " + expected_id + ", got: " + sprintf("%J", tr.winning_section) + "\n");
        exit(1);
    }
};
check_win("sub.example.com", "main");
check_win("exact.example.net", "main");
check_win("myvideo.net", "main");
let tr_rx = connections.trace_rules({ mode: "presence", search: "^api[.]example[.]org$" }, fixture.section);
if (length(tr_rx.presence_sections || []) == 0 || tr_rx.presence_sections[0].id != "main") {
    warn("Expected presence match for regex:^api[.]example[.]org$ -> main, got: " + sprintf("%J", tr_rx) + "\n");
    exit(1);
}
check_win("sub.scalar.example", "scalar_dom");
check_win("exact-scalar.example", "scalar_dom");
check_win("sub.textdom.example", "text_dom");
check_win("exact-text.example", "text_dom");
UCODE

# Minimal native config (rule section, block_doh, ip_cidr, domain, community_lists) + idempotency
cat >"$WORK_DIR/native-minimal.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.3",
    "block_doh": "1",
    "dns_server": [ "9.9.9.9" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "rule": [
    {
      ".name": "minimal_rule",
      ".type": "rule",
      "enabled": "1",
      "action": "connection",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@example.com:443#Minimal"
      ],
      "ip_cidr": [ "203.0.113.0/24" ],
      "domain": [ "minimal.example" ],
      "community_lists": [ "youtube" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/native-minimal.json" >"$WORK_DIR/native-minimal-out.json"

node - "$WORK_DIR/native-minimal-out.json" "$WORK_DIR/native-minimal-config.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = out.config;
if (out.changed !== true || config.settings.config_version !== '1.8.0') {
  console.error('Minimal native fixture must migrate to 1.8.0');
  process.exit(1);
}
if (config.settings.block_doh !== '1') {
  console.error('Minimal native fixture must preserve block_doh');
  process.exit(1);
}
if (config.rule || !(config.section && config.section.length === 1 && config.section[0]['.name'] === 'minimal_rule')) {
  console.error('Minimal native rule section must normalize to section');
  process.exit(1);
}
fs.writeFileSync(process.argv[3], JSON.stringify(config, null, 2) + '\n');
NODE

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/native-minimal-config.json" >"$WORK_DIR/native-minimal-out2.json"
node - "$WORK_DIR/native-minimal-out2.json" <<'NODE'
const fs = require('fs');
const out2 = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out2.changed !== false) {
  console.error('Minimal native fixture second migration pass must be idempotent');
  process.exit(1);
}
NODE

cat >"$WORK_DIR/tachyon-1.0.1.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.1",
    "component_update_check_enabled": "0"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "action": "connection",
      "interfaces": [ "awg0", "tun0" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/tachyon-1.0.1.json" >"$WORK_DIR/tachyon-1.0.2.json"

node - "$WORK_DIR/tachyon-1.0.2.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const section = out.config.section[0];
const interfaces = out.config.section_interface || [];

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

assert(out.changed === true, '1.0.1 config should require migration');
assert(out.config.settings.config_version === '1.8.0', 'config schema version should advance to 1.8.0');
assert(out.config.settings.component_update_check_enabled === '1', 'updates from 1.0.1 and below should enable component update checks');
assert(JSON.stringify(out.config.settings.applied_migrations) === JSON.stringify(['interface_sections', 'enable_component_checks', 'http_connection_urls', 'dns_hosts_to_option', 'global_hosts_to_section', 'orphan_section_interface_cleanup', 'ensure_dns_server_defaults', 'engine_identity_tachyon_core', 'modular_entities_v1', 'priority_levels_to_outbound_groups', 'relax_probe_intervals_v1', 'ensure_tcp_bbr_default', 'fail_closed_auto_defaults', 'ai_lists_1_8']), 'named migrations should be recorded');
assert(!Object.prototype.hasOwnProperty.call(section, 'interfaces'), 'parent interface list should be removed');
assert(JSON.stringify(interfaces.map(item => item.name)) === JSON.stringify(['awg0', 'tun0']), 'interfaces should keep their order');
for (const item of interfaces) {
  assert(item.section === 'main', 'interface child should reference its parent');
  assert(item.domain_resolver_enabled === '0', 'resolver should default to disabled');
  assert(item.domain_resolver_dns_type === 'udp', 'resolver protocol default');
  assert(item.domain_resolver_dns_server === '8.8.8.8', 'resolver server default');
}
NODE

cat >"$WORK_DIR/tachyon-1.0.2-disabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.2",
    "component_update_check_enabled": "0"
  },
  "section": []
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/tachyon-1.0.2-disabled.json" >"$WORK_DIR/tachyon-1.0.2-disabled-output.json"

node - "$WORK_DIR/tachyon-1.0.2-disabled-output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

assert(out.config.settings.component_update_check_enabled === '0', '1.0.2 config must preserve an explicitly disabled component check');
assert(out.config.settings.config_version === '1.8.0', '1.0.2 config should advance through the HTTP URL migration schema');
assert(JSON.stringify(out.config.settings.applied_migrations) === JSON.stringify(['interface_sections', 'enable_component_checks', 'http_connection_urls', 'dns_hosts_to_option', 'global_hosts_to_section', 'orphan_section_interface_cleanup', 'ensure_dns_server_defaults', 'engine_identity_tachyon_core', 'modular_entities_v1', 'priority_levels_to_outbound_groups', 'relax_probe_intervals_v1', 'ensure_tcp_bbr_default', 'fail_closed_auto_defaults', 'ai_lists_1_8']), 'newer configs should mark skipped migrations');
NODE

cat >"$WORK_DIR/tachyon-1.0.4-http.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.4"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "action": "connection",
      "selector_proxy_links": [
        "https://user:p%2540ss@[2001:db8::1]:8443/#Secure%20HTTP",
        "vless://00000000-0000-4000-8000-000000000001@example.com:443",
        "http://proxy.example:8080",
        "https://invalid.example/no-port"
      ],
      "outbound_jsons": [
        "{\"type\":\"direct\",\"tag\":\"http\"}"
      ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/tachyon-1.0.4-http.json" >"$WORK_DIR/tachyon-1.0.4-http-output.json"

node - "$WORK_DIR/tachyon-1.0.4-http-output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const section = out.config.section[0];
const jsonOutbounds = section.outbound_jsons.map(JSON.parse);

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exit(1);
  }
}

assert(out.config.settings.config_version === '1.8.0', '1.0.4 config should advance to schema 1.8.0');
assert(JSON.stringify(section.selector_proxy_links) === JSON.stringify([
  'vless://00000000-0000-4000-8000-000000000001@example.com:443',
  'https://invalid.example/no-port',
]), 'only valid native HTTP proxy links should leave Connection URLs');
assert(jsonOutbounds.length === 3, 'migrated HTTP outbounds should precede the existing JSON list');
assert(JSON.stringify(jsonOutbounds[0]) === JSON.stringify({
  type: 'http',
  tag: 'Secure HTTP',
  server: '2001:db8::1',
  server_port: 8443,
  username: 'user',
  password: 'p@ss',
  tls: { enabled: true },
}), 'HTTPS URL should preserve its name, credentials, IPv6 server, port, and TLS');
assert(JSON.stringify(jsonOutbounds[1]) === JSON.stringify({
  type: 'http',
  tag: 'http-1',
  server: 'proxy.example',
  server_port: 8080,
}), 'unnamed HTTP URL should receive a unique http tag');
assert(jsonOutbounds[2].type === 'direct' && jsonOutbounds[2].tag === 'http', 'existing JSON outbounds should remain unchanged');
assert(JSON.stringify(out.config.settings.applied_migrations) === JSON.stringify(['interface_sections', 'enable_component_checks', 'http_connection_urls', 'dns_hosts_to_option', 'global_hosts_to_section', 'orphan_section_interface_cleanup', 'ensure_dns_server_defaults', 'engine_identity_tachyon_core', 'modular_entities_v1', 'priority_levels_to_outbound_groups', 'relax_probe_intervals_v1', 'ensure_tcp_bbr_default', 'fail_closed_auto_defaults', 'ai_lists_1_8']), 'HTTP URL migration should be recorded');
NODE

cat >"$WORK_DIR/tachyon-1.0.5-http.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_version": "1.0.5"
  },
  "section": [
    {
      ".name": "main",
      ".type": "section",
      "action": "connection",
      "selector_proxy_links": [ "http://proxy.example:8080" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/tachyon-1.0.5-http.json" >"$WORK_DIR/tachyon-1.0.5-http-output.json"

node - "$WORK_DIR/tachyon-1.0.5-http-output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const section = out.config.section[0];

if (out.changed !== true || out.config.settings.config_version !== '1.8.0') {
  console.error('1.0.5 config should advance schema version to 1.8.0');
  process.exit(1);
}
if (JSON.stringify(section.selector_proxy_links) !== JSON.stringify(['http://proxy.example:8080']) || section.outbound_jsons) {
  console.error('1.0.5 and newer configs must not run the legacy HTTP URL conversion');
  process.exit(1);
}
NODE

cat >"$WORK_DIR/runtime-migrate.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.legacy=rule
tachyon.legacy.enabled=1
tachyon.legacy.connection_type=proxy
tachyon.legacy.proxy_config_type=url
tachyon.legacy.proxy_string=vless://one
tachyon.old_direct=rule
tachyon.old_direct.enabled=1
tachyon.old_direct.action=direct
tachyon.vpn=section
tachyon.vpn.enabled=1
tachyon.vpn.action=connection
tachyon.vpn.interfaces=awg0
EOF_UCI
mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/persistent-cache"
: >"$WORK_DIR/runtime-migrate.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/runtime-migrate.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/runtime-migrate.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fxq 'tachyon.legacy=section' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert legacy rule type through core.uci"
grep -Fxq 'tachyon.legacy.action=connection' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must write migrated action through core.uci"
grep -Fxq 'tachyon.old_direct=section' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert legacy direct rule type to section"
grep -Fxq 'tachyon.old_direct.action=bypass' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must convert direct rule action to bypass through core.uci"
grep -Eq '^tachyon\\.cfg[0-9a-f]+=$' "$WORK_DIR/runtime-migrate.state" && fail "anonymous fixture section should include a type"
grep -Fxq 'tachyon.legacy.selector_proxy_links=vless://one' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must keep connection URLs in the parent section"
if grep -Fq '=connection_url' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must not create connection_url child sections"
fi
grep -Eq '^tachyon\.cfg[0-9a-f]+=section_interface$' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime migration must create an anonymous interface settings section"
grep -Eq '^tachyon\.cfg[0-9a-f]+\.section=vpn$' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime interface settings section must reference its parent"
grep -Eq '^tachyon\.cfg[0-9a-f]+\.name=awg0$' "$WORK_DIR/runtime-migrate.state" ||
  fail "runtime interface settings section must store the interface name"
if grep -Fq 'tachyon.legacy.urltest_enabled=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete migrated urltest_enabled through core.uci"
fi
if grep -Fq 'tachyon.legacy.proxy_string=' "$WORK_DIR/runtime-migrate.state"; then
  fail "runtime migration must delete legacy proxy_string through core.uci"
fi
grep -Fxq 'commit tachyon' "$WORK_DIR/runtime-migrate.log" ||
  fail "runtime migration must commit through core.uci"

cat >"$WORK_DIR/runtime-version.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.config_version=1.0.1
tachyon.settings.component_update_check_enabled=0
tachyon.main=section
tachyon.main.enabled=1
tachyon.main.action=connection
tachyon.main.interfaces=awg0
tachyon.main.selector_proxy_links=http://proxy.example:8080
EOF_UCI
: >"$WORK_DIR/runtime-version.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/runtime-version.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/runtime-version.log" \
TACHYON_CONFIG_NAME="tachyon" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fxq 'tachyon.settings.config_version=1.8.0' "$WORK_DIR/runtime-version.state" ||
  fail "runtime version migration must advance config_version"
grep -Fxq 'tachyon.settings.component_update_check_enabled=1' "$WORK_DIR/runtime-version.state" ||
  fail "runtime version migration must enable component update checks"
grep -Fq 'tachyon.settings.applied_migrations=interface_sections enable_component_checks http_connection_urls dns_hosts_to_option global_hosts_to_section orphan_section_interface_cleanup ensure_dns_server_defaults' "$WORK_DIR/runtime-version.state" ||
  fail "runtime migration must record stable migration names"
grep -Eq '^tachyon\.main\.outbound_jsons=\{ "type": "http", "tag": "http", "server": "proxy\.example", "server_port": 8080 \}$' "$WORK_DIR/runtime-version.state" ||
  fail "runtime migration must convert native HTTP proxy links to JSON outbounds"
if grep -Fq 'tachyon.main.selector_proxy_links=' "$WORK_DIR/runtime-version.state"; then
  fail "runtime migration must remove converted HTTP connection URLs"
fi
grep -Eq '^tachyon\.cfg[0-9a-f]+=section_interface$' "$WORK_DIR/runtime-version.state" ||
  fail "runtime version migration must create interface child settings"
if grep -Fq 'tachyon.main.interfaces=' "$WORK_DIR/runtime-version.state"; then
  fail "runtime version migration must remove the parent interface list"
fi

: >"$WORK_DIR/runtime-version.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/runtime-version.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/runtime-version.log" \
TACHYON_CONFIG_NAME="tachyon" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate
if grep -Fq 'commit tachyon' "$WORK_DIR/runtime-version.log"; then
  fail "completed named migrations must be idempotent"
fi

mkdir -p \
  "$WORK_DIR/cache-migration/runtime/section-cache" \
  "$WORK_DIR/cache-migration/runtime/subscription-links" \
  "$WORK_DIR/cache-migration/persistent"
printf '7\n' >"$WORK_DIR/cache-migration/runtime/cache-format"
printf 'stale\n' >"$WORK_DIR/cache-migration/runtime/section-cache/stale.json"
printf 'stale\n' >"$WORK_DIR/cache-migration/runtime/subscription-links/stale.json"
printf '8\n' >"$WORK_DIR/cache-migration/persistent/cache-format"
cat >"$WORK_DIR/cache-migration/persistent/proxy-subscription-1.json" <<'JSON'
{
  "version": 1,
  "format": "sing-box-json",
  "outbounds": [
    {
      "type": "vless",
      "tag": "stable-cache-node",
      "server": "stable.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000001"
    }
  ]
}
JSON

TACHYON_UCI_STATE_FILE="$WORK_DIR/runtime-version.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/runtime-version.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/cache-migration/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/cache-migration/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/cache-migration/persistent" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

[ "$(sed -n '1p' "$WORK_DIR/cache-migration/runtime/cache-format")" = "9" ] ||
  fail "package migration must advance the runtime cache format"
[ ! -e "$WORK_DIR/cache-migration/runtime/section-cache/stale.json" ] ||
  fail "package migration must clear the legacy section cache"
[ ! -d "$WORK_DIR/cache-migration/runtime/subscription-links" ] ||
  fail "package migration must remove the retired subscription link cache"
node - "$WORK_DIR/cache-migration/persistent/proxy-subscription-1.json" <<'NODE'
const fs = require('fs');
const subscription = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outbound = subscription.outbounds[0];
if (outbound.server !== 'stable.example' || !outbound.share_link || !outbound.share_link.startsWith('vless://')) {
  console.error('package migration must preserve stable subscription data and backfill its direct link');
  process.exit(1);
}
NODE

cat >"$WORK_DIR/dns_hosts_list.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dns_hosts=0.0.0.0 ads.example.com
tachyon.settings.dns_hosts=127.0.0.1 tracker.local
EOF_UCI
: >"$WORK_DIR/dns_hosts_list.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/dns_hosts_list.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/dns_hosts_list.log" \
TACHYON_CONFIG_NAME="tachyon" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fxq 'tachyon.settings.dns_hosts=0.0.0.0 ads.example.com
127.0.0.1 tracker.local' "$WORK_DIR/dns_hosts_list.state" ||
  fail "dns_hosts list-to-option migration must join entries with newline"

: >"$WORK_DIR/uci-commit.log"
: >"$WORK_DIR/uci-commit.state"
TACHYON_UCI_STATE_FILE="$WORK_DIR/uci-commit.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/uci-commit.log" \
TACHYON_CONFIG_NAME="tachyon" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" commit

grep -Fxq 'commit tachyon' "$WORK_DIR/uci-commit.log" ||
  fail "commit mode must commit tachyon through core.uci"

# Regression: pre-1.0.5 configs often lack bootstrap_dns_server.
# The ensure_dns_server_defaults migration must inject a default so the validator
# does not abort Tachyon startup with "At least one Bootstrap DNS server is required".
cat >"$WORK_DIR/no_bootstrap.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dns_server=8.8.8.8
EOF_UCI
: >"$WORK_DIR/no_bootstrap.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/no_bootstrap.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/no_bootstrap.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fq 'tachyon.settings.bootstrap_dns_server=77.88.8.8' "$WORK_DIR/no_bootstrap.state" ||
  fail "ensure_dns_server_defaults must inject 77.88.8.8 when bootstrap_dns_server is missing"

# Regression: pre-1.0.5 configs with neither dns_server nor bootstrap_dns_server must
# get both defaults injected.
cat >"$WORK_DIR/no_dns.state" <<'EOF_UCI'
tachyon.settings=settings
EOF_UCI
: >"$WORK_DIR/no_dns.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/no_dns.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/no_dns.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fq 'tachyon.settings.dns_server=77.88.8.8' "$WORK_DIR/no_dns.state" ||
  fail "ensure_dns_server_defaults must inject 77.88.8.8 for missing dns_server"
grep -Fq 'tachyon.settings.bootstrap_dns_server=77.88.8.8' "$WORK_DIR/no_dns.state" ||
  fail "ensure_dns_server_defaults must inject 77.88.8.8 for missing bootstrap_dns_server"

# Regression: awg section with selector_amnezia_configs must not get an empty duplicate src_awg_*
# alongside src_amnezia_*, and existing src_sub_* options must not be overwritten by legacy subscription_url.
cat >"$WORK_DIR/awg_and_sub.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dns_server=77.88.8.8
tachyon.settings.bootstrap_dns_server=77.88.8.8
tachyon.proton=section
tachyon.proton.enabled=1
tachyon.proton.connection_type=proxy
tachyon.proton.action=awg
tachyon.proton.selector_amnezia_configs={"name":"NL_1","config":"[Interface]"}
tachyon.gemini=section
tachyon.gemini.enabled=1
tachyon.gemini.connection_type=proxy
tachyon.gemini.action=connection
tachyon.gemini.outbound_source_refs=src_sub_gemini_1
tachyon.src_sub_gemini_1=outbound_source
tachyon.src_sub_gemini_1.enabled=1
tachyon.src_sub_gemini_1.source_type=subscription
tachyon.src_sub_gemini_1.url=https://sub.example/v1
tachyon.src_sub_gemini_1.include_urltest_groups=0
tachyon.src_sub_gemini_1.hide_urltest_group_outbounds=0
tachyon.legacy_sub=subscription_url
tachyon.legacy_sub.section=gemini
tachyon.legacy_sub.url=https://sub.example/v1
tachyon.legacy_sub.include_urltest_groups=1
tachyon.legacy_sub.hide_urltest_group_outbounds=1
EOF_UCI
: >"$WORK_DIR/awg_and_sub.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/awg_and_sub.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/awg_and_sub.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fq 'tachyon.src_amnezia_proton=outbound_source' "$WORK_DIR/awg_and_sub.state" ||
  fail "migrate must create src_amnezia_proton for selector_amnezia_configs"
if grep -Fq 'tachyon.src_awg_proton=outbound_source' "$WORK_DIR/awg_and_sub.state"; then
  fail "migrate must not create duplicate empty src_awg_proton when selector_amnezia_configs exists without awg_private_key"
fi
grep -Fq 'tachyon.src_sub_gemini_1.include_urltest_groups=0' "$WORK_DIR/awg_and_sub.state" ||
  fail "migrate must not overwrite existing src_sub_gemini_1.include_urltest_groups=0 from legacy subscription_url"

# Regression: relax_probe_intervals_v1 upgrades untouched aggressive defaults while
# keeping intentionally customized probe intervals untouched.
cat >"$WORK_DIR/relax_intervals.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dns_server=77.88.8.8
tachyon.settings.bootstrap_dns_server=77.88.8.8
tachyon.settings.dns_check_interval=10s
tachyon.settings.ai_proxy_health_interval=30
tachyon.settings.ai_dns_interval=60
tachyon.main=section
tachyon.main.enabled=1
tachyon.main.action=connection
tachyon.backup=section
tachyon.backup.enabled=1
tachyon.backup.action=connection
tachyon.prio_default=balancer
tachyon.prio_default.enabled=1
tachyon.prio_default.section=main
tachyon.prio_default.balancer_type=priority
tachyon.prio_default.active_check_interval=5s
tachyon.prio_default.recovery_check_interval=15s
tachyon.prio_custom=balancer
tachyon.prio_custom.enabled=1
tachyon.prio_custom.section=backup
tachyon.prio_custom.balancer_type=priority
tachyon.prio_custom.active_check_interval=20s
tachyon.pg_legacy=priority_group
tachyon.pg_legacy.enabled=1
tachyon.pg_legacy.section=main
tachyon.pg_legacy.active_check_interval=5s
tachyon.ut_default=urltest
tachyon.ut_default.enabled=1
tachyon.ut_default.section=main
tachyon.ut_default.interval=5s
tachyon.bal_ut=balancer
tachyon.bal_ut.enabled=1
tachyon.bal_ut.section=backup
tachyon.bal_ut.balancer_type=urltest
tachyon.bal_ut.interval=10s
EOF_UCI
: >"$WORK_DIR/relax_intervals.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/relax_intervals.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/relax_intervals.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

grep -Fq 'tachyon.settings.dns_check_interval=30s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax default dns_check_interval from 10s to 30s"
grep -Fq 'tachyon.settings.ai_proxy_health_interval=60' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax default ai_proxy_health_interval from 30 to 60"
grep -Fq 'tachyon.settings.ai_dns_interval=180' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax default ai_dns_interval from 60 to 180"
grep -Fq 'tachyon.prio_default.active_check_interval=15s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax default priority active_check_interval from 5s to 15s"
grep -Fq 'tachyon.prio_default.recovery_check_interval=30s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax default priority recovery_check_interval from 15s to 30s"
grep -Fq 'tachyon.prio_custom.active_check_interval=20s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must preserve custom priority active_check_interval"
grep -Fq 'tachyon.pg_legacy.active_check_interval=15s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax legacy priority_group active_check_interval"
grep -Fq 'tachyon.ut_default.interval=30s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax aggressive urltest interval 5s to 30s"
grep -Fq 'tachyon.bal_ut.interval=30s' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must relax aggressive balancer urltest interval 10s to 30s"
grep -Fq 'relax_probe_intervals_v1' "$WORK_DIR/relax_intervals.state" ||
  fail "relax_probe_intervals_v1 must record migration name"

# Provider unification migration:
# - byedpi / zapret / zapret2 sections and sources migrate to native desync (preset=auto) and stay enabled
# - olcrtc, non-native external wdtt, and external tailscaled (tailscale_mode='native') are disabled (enabled='0')
# - native CSQTT/WDTT and native tachyon-core Tailscale stay enabled without wdtt_native or tailscale_mode='native'
cat >"$WORK_DIR/provider_unify.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.engine=sing-box
tachyon.settings.engine_previous=tachyon-core
tachyon.settings.component_auto_update_targets=tachyon zapret zapret2 byedpi wdtt olcrtc tailscale sing-box
tachyon.sec_byedpi=section
tachyon.sec_byedpi.enabled=1
tachyon.sec_byedpi.action=byedpi
tachyon.sec_byedpi.byedpi_cmd_opts=-s1 -d1
tachyon.sec_byedpi.domain_suffix=youtube.com
tachyon.sec_zapret=section
tachyon.sec_zapret.enabled=1
tachyon.sec_zapret.action=zapret
tachyon.sec_zapret.nfqws_opt=--dpi-desync=fake
tachyon.sec_zapret.domain_suffix=discord.com
tachyon.sec_zapret2=section
tachyon.sec_zapret2.enabled=1
tachyon.sec_zapret2.action=zapret2
tachyon.sec_zapret2.nfqws2_opt=--lua-desync=multisplit
tachyon.sec_zapret2.domain_suffix=googlevideo.com
tachyon.src_zapret2=outbound_source
tachyon.src_zapret2.enabled=1
tachyon.src_zapret2.source_type=zapret2
tachyon.src_zapret2.nfqws2_opt=--lua-desync=fake
tachyon.src_byedpi=outbound_source
tachyon.src_byedpi.enabled=1
tachyon.src_byedpi.source_type=byedpi
tachyon.src_byedpi.byedpi_opts=-o1
tachyon.src_udp_keep=outbound_source
tachyon.src_udp_keep.enabled=1
tachyon.src_udp_keep.source_type=desync
tachyon.src_udp_keep.desync_preset=custom
tachyon.src_udp_keep.desync_udp_keep_socket=1
tachyon.src_udp_rotate=outbound_source
tachyon.src_udp_rotate.enabled=1
tachyon.src_udp_rotate.source_type=desync
tachyon.src_udp_rotate.desync_preset=custom
tachyon.src_udp_rotate.desync_udp_keep_socket=0
tachyon.sec_olcrtc=section
tachyon.sec_olcrtc.enabled=1
tachyon.sec_olcrtc.action=olcrtc
tachyon.srv_olcrtc=server
tachyon.srv_olcrtc.enabled=1
tachyon.srv_olcrtc.protocol=olcrtc
tachyon.sec_ext_wdtt=section
tachyon.sec_ext_wdtt.enabled=1
tachyon.sec_ext_wdtt.action=wdtt
tachyon.src_ext_wdtt=outbound_source
tachyon.src_ext_wdtt.enabled=1
tachyon.src_ext_wdtt.source_type=wdtt
tachyon.sec_nat_wdtt=section
tachyon.sec_nat_wdtt.enabled=1
tachyon.sec_nat_wdtt.action=wdtt
tachyon.sec_nat_wdtt.wdtt_native=1
tachyon.sec_nat_wdtt.warp_flow_uri=csqtt://connect?v=2&host=wdtt.example&peer=46000&password=pw
tachyon.sec_nat_wdtt.wdtt_workers=6
tachyon.sec_nat_wdtt.wdtt_mtu=1360
tachyon.sec_nat_wdtt.warp_flow_device_id=dev-1
tachyon.src_csqtt=outbound_source
tachyon.src_csqtt.enabled=1
tachyon.src_csqtt.source_type=csqtt
tachyon.src_csqtt.wdtt_native=1
tachyon.src_csqtt.csqtt_server=csqtt.example
tachyon.sec_ext_ts=section
tachyon.sec_ext_ts.enabled=1
tachyon.sec_ext_ts.action=tailscale
tachyon.sec_ext_ts.tailscale_mode=native
tachyon.src_ext_ts=outbound_source
tachyon.src_ext_ts.enabled=1
tachyon.src_ext_ts.source_type=tailscale
tachyon.src_ext_ts.interface_name=tailscale0
tachyon.src_nat_ts=outbound_source
tachyon.src_nat_ts.enabled=1
tachyon.src_nat_ts.source_type=tailscale
tachyon.src_nat_ts.tailscale_mode=embedded
tachyon.src_nat_ts.tailscale_auth_key=tskey-auth-123
tachyon.srv_nat_ts=server
tachyon.srv_nat_ts.enabled=1
tachyon.srv_nat_ts.protocol=tailscale
tachyon.srv_nat_ts.tailscale_mode=singbox
EOF_UCI
: >"$WORK_DIR/provider_unify.log"
run_provider_unify() {
  TACHYON_UCI_STATE_FILE="$WORK_DIR/provider_unify.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/provider_unify.log" \
  TACHYON_CONFIG_NAME="tachyon" \
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
  TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
  TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" migrate
}
run_provider_unify
run_provider_unify

TACHYON_UCI_STATE_FILE="$WORK_DIR/provider_unify.state" ucode -L "$TACHYON_LIB" - <<'UCODE'
let uci = require("core.uci");
let must = function(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
};

// Settings normalized to tachyon-core and removed targets stripped
must(uci.get("tachyon", "settings", "engine") == "tachyon-core", "engine must normalize to tachyon-core");
must(uci.get("tachyon", "settings", "engine_previous") == "", "engine_previous must be deleted");
let targets_str = uci.get("tachyon", "settings", "component_auto_update_targets");
must(targets_str == "tachyon tachyon-core",
    "component_auto_update_targets must strip removed providers and map sing-box -> tachyon-core, got: " + sprintf("%J", targets_str));

// byedpi / zapret / zapret2 sections & sources migrate to desync preset=auto and stay enabled
for (let s in [ "sec_byedpi", "sec_zapret", "sec_zapret2" ]) {
    must(uci.get("tachyon", s, "enabled") == "1", s + " must stay enabled");
    must(uci.get("tachyon", s, "action") == "desync", s + " must migrate to desync");
    must(uci.get("tachyon", s, "desync_preset") == "auto", s + " must set desync_preset=auto");
}
must(uci.get("tachyon", "sec_byedpi", "byedpi_cmd_opts") == "", "byedpi_cmd_opts must be removed");
must(uci.get("tachyon", "sec_zapret", "nfqws_opt") == "", "nfqws_opt must be removed");
must(uci.get("tachyon", "sec_zapret2", "nfqws2_opt") == "", "nfqws2_opt must be removed");

// zapret2 outbound_source migrates to desync preset=auto and stays enabled;
// identical byedpi outbound_source in the same config is deduplicated onto the canonical desync source
must(uci.get("tachyon", "src_zapret2", "enabled") == "1", "src_zapret2 must stay enabled");
must(uci.get("tachyon", "src_zapret2", "source_type") == "desync", "src_zapret2 must migrate to desync");
must(uci.get("tachyon", "src_zapret2", "desync_preset") == "auto", "src_zapret2 must set desync_preset=auto");
must(uci.get("tachyon", "src_udp_keep", "desync_udp_keep_socket") == "1",
    "migration must preserve the keep-socket Desync source");
must(uci.get("tachyon", "src_udp_rotate", "desync_udp_keep_socket") == "0",
    "migration must preserve a Desync source differing only by its UDP socket policy");
must(uci.get("tachyon", "src_zapret2", "nfqws2_opt") == "", "src_zapret2.nfqws2_opt must be removed");

// olcrtc, external wdtt, external tailscaled become disabled (enabled=0)
for (let dead in [ "sec_olcrtc", "srv_olcrtc", "sec_ext_wdtt", "src_ext_wdtt", "sec_ext_ts", "src_ext_ts" ]) {
    must(uci.get("tachyon", dead, "enabled") == "0", dead + " must be disabled on migration");
}

// Native CSQTT/WDTT stays enabled and extracts into canonical csqtt outbound_source without wdtt_native
must(uci.get("tachyon", "sec_nat_wdtt", "enabled") == "1", "sec_nat_wdtt must stay enabled");
must(uci.get("tachyon", "sec_nat_wdtt", "action") == "connection", "sec_nat_wdtt must normalize to connection + csqtt source");
let nat_wdtt_refs = uci.get("tachyon", "sec_nat_wdtt", "outbound_source_refs");
must(index(nat_wdtt_refs, "src_csqtt_sec_nat_wdtt") >= 0, "sec_nat_wdtt must reference extracted csqtt outbound_source, got: " + nat_wdtt_refs);
must(uci.get("tachyon", "src_csqtt_sec_nat_wdtt", "enabled") == "1", "src_csqtt_sec_nat_wdtt must stay enabled");
must(uci.get("tachyon", "src_csqtt_sec_nat_wdtt", "source_type") == "csqtt", "src_csqtt_sec_nat_wdtt must normalize to csqtt");
must(uci.get("tachyon", "src_csqtt_sec_nat_wdtt", "wdtt_native") == "", "src_csqtt_sec_nat_wdtt.wdtt_native must be deleted");
must(uci.get("tachyon", "src_csqtt_sec_nat_wdtt", "csqtt_workers") == "6", "src_csqtt_sec_nat_wdtt.csqtt_workers must migrate");
must(uci.get("tachyon", "src_csqtt_sec_nat_wdtt", "csqtt_mtu") == "1360", "src_csqtt_sec_nat_wdtt.csqtt_mtu must migrate");
must(uci.get("tachyon", "src_csqtt_sec_nat_wdtt", "csqtt_device_id") == "dev-1", "src_csqtt_sec_nat_wdtt.csqtt_device_id must migrate");
must(uci.get("tachyon", "src_csqtt", "enabled") == "1", "src_csqtt must stay enabled");
must(uci.get("tachyon", "src_csqtt", "source_type") == "csqtt", "src_csqtt must keep source_type=csqtt");
must(uci.get("tachyon", "src_csqtt", "wdtt_native") == "", "src_csqtt.wdtt_native must be deleted");

// Native tachyon-core Tailscale stays enabled and normalizes tailscale_mode=tachyon-core
must(uci.get("tachyon", "src_nat_ts", "enabled") == "1", "src_nat_ts must stay enabled");
must(uci.get("tachyon", "src_nat_ts", "tailscale_mode") == "tachyon-core", "src_nat_ts must normalize to tachyon-core");
must(uci.get("tachyon", "srv_nat_ts", "enabled") == "1", "srv_nat_ts must stay enabled");
must(uci.get("tachyon", "srv_nat_ts", "tailscale_mode") == "tachyon-core", "srv_nat_ts must normalize to tachyon-core");
UCODE

# Verify standalone byedpi outbound_source migrates to desync without colliding in desync deduplication
cat >"$WORK_DIR/provider_unify_byedpi.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.engine=byedpi
tachyon.src_byedpi=outbound_source
tachyon.src_byedpi.enabled=1
tachyon.src_byedpi.source_type=byedpi
tachyon.src_byedpi.byedpi_opts=-o1
EOF_UCI
: >"$WORK_DIR/provider_unify_byedpi.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/provider_unify_byedpi.state" \
TACHYON_UCI_LOG_FILE="$WORK_DIR/provider_unify_byedpi.log" \
TACHYON_CONFIG_NAME="tachyon" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/tmp-subscriptions" \
TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/runtime" \
TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent-cache" \
TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
ucode -L "$TACHYON_LIB" "$MIGRATION" migrate

TACHYON_UCI_STATE_FILE="$WORK_DIR/provider_unify_byedpi.state" ucode -L "$TACHYON_LIB" - <<'UCODE'
let uci = require("core.uci");
let must = function(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
};
must(uci.get("tachyon", "src_byedpi", "enabled") == "1", "standalone src_byedpi must stay enabled");
must(uci.get("tachyon", "src_byedpi", "source_type") == "desync", "standalone src_byedpi must migrate to desync");
must(uci.get("tachyon", "src_byedpi", "desync_preset") == "auto", "standalone src_byedpi must set desync_preset=auto");
must(uci.get("tachyon", "src_byedpi", "byedpi_opts") == "", "standalone src_byedpi.byedpi_opts must be removed");
UCODE

# Negative case: standalone user-installed sing-box must be backed up non-destructively
# without deleting standalone init, binary, config, or cache artifacts.
STANDALONE_ROOT="$WORK_DIR/cleanup_standalone"
mkdir -p \
  "$STANDALONE_ROOT/etc/sing-box" \
  "$STANDALONE_ROOT/etc/config" \
  "$STANDALONE_ROOT/etc/init.d" \
  "$STANDALONE_ROOT/etc/rc.d" \
  "$STANDALONE_ROOT/usr/bin" \
  "$STANDALONE_ROOT/tmp/sing-box"
printf '{"standalone":true,"v":1}\n' >"$STANDALONE_ROOT/etc/sing-box/config.json"
printf "config sing-box 'standalone'\n" >"$STANDALONE_ROOT/etc/config/sing-box"
cat >"$STANDALONE_ROOT/etc/init.d/sing-box" <<'EOF_INIT'
#!/bin/sh
printf '%s\n' "$*" >>"${0}.invoked"
EOF_INIT
chmod +x "$STANDALONE_ROOT/etc/init.d/sing-box"
printf '#!/bin/sh\n' >"$STANDALONE_ROOT/etc/rc.d/S99sing-box"
printf 'standalone-bin\n' >"$STANDALONE_ROOT/usr/bin/sing-box"
printf 'standalone-cache\n' >"$STANDALONE_ROOT/tmp/sing-box/cache.db"

TACHYON_LEGACY_CLEANUP_ROOT="$STANDALONE_ROOT" ucode -L "$TACHYON_LIB" - <<'UCODE'
let mig = require("config.migration");
if (mig.has_tachyon_managed_singbox_marker()) {
    warn("FAIL: standalone sing-box root must not report Tachyon managed marker\n");
    exit(1);
}
mig.cleanup_legacy_core_artifacts();
UCODE

test -f "$STANDALONE_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json" ||
  fail "standalone cleanup check must back up /etc/sing-box/config.json"
test -f "$STANDALONE_ROOT/etc/tachyon/external-configs-backup/sing-box/sing-box" ||
  fail "standalone cleanup check must back up /etc/config/sing-box"
grep -Fq '"v":1' "$STANDALONE_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json" ||
  fail "backed up sing-box config.json content mismatch"
grep -Fq "config sing-box 'standalone'" "$STANDALONE_ROOT/etc/tachyon/external-configs-backup/sing-box/sing-box" ||
  fail "backed up /etc/config/sing-box content mismatch"

for keep_path in \
  "$STANDALONE_ROOT/etc/sing-box/config.json" \
  "$STANDALONE_ROOT/etc/config/sing-box" \
  "$STANDALONE_ROOT/etc/init.d/sing-box" \
  "$STANDALONE_ROOT/etc/rc.d/S99sing-box" \
  "$STANDALONE_ROOT/usr/bin/sing-box" \
  "$STANDALONE_ROOT/tmp/sing-box/cache.db"; do
  test -f "$keep_path" || fail "standalone sing-box artifact must be preserved: $keep_path"
done
test ! -e "$STANDALONE_ROOT/etc/init.d/sing-box.invoked" ||
  fail "standalone /etc/init.d/sing-box must never be invoked during cleanup"

# Re-running backup/cleanup must preserve pre-existing backups without overwriting
printf '{"backup":"preserved"}\n' >"$STANDALONE_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json"
printf '{"standalone":true,"v":2}\n' >"$STANDALONE_ROOT/etc/sing-box/config.json"
TACHYON_LEGACY_CLEANUP_ROOT="$STANDALONE_ROOT" ucode -L "$TACHYON_LIB" - <<'UCODE'
let mig = require("config.migration");
mig.cleanup_legacy_core_artifacts();
UCODE
grep -Fq '"backup":"preserved"' "$STANDALONE_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json" ||
  fail "existing external sing-box backup must be preserved across subsequent runs"

# Positive cases: every Tachyon-managed marker creates external backups first and removes managed artifacts
for marker_case in init_marker version_marker variant_marker backup_marker; do
  CASE_ROOT="$WORK_DIR/cleanup_${marker_case}"
  mkdir -p \
    "$CASE_ROOT/etc/sing-box" \
    "$CASE_ROOT/etc/config" \
    "$CASE_ROOT/etc/init.d" \
    "$CASE_ROOT/etc/rc.d" \
    "$CASE_ROOT/etc/tachyon/component-backups" \
    "$CASE_ROOT/usr/bin" \
    "$CASE_ROOT/tmp/sing-box"
  printf '{"managed":"%s"}\n' "$marker_case" >"$CASE_ROOT/etc/sing-box/config.json"
  printf "config sing-box '%s'\n" "$marker_case" >"$CASE_ROOT/etc/config/sing-box"
  if [ "$marker_case" = "init_marker" ]; then
    cat >"$CASE_ROOT/etc/init.d/sing-box" <<'EOF_INIT'
#!/bin/sh
# Tachyon managed sing-box service
printf '%s\n' "$*" >>"$(dirname "$0")/sing-box-init-calls.log"
EOF_INIT
  else
    cat >"$CASE_ROOT/etc/init.d/sing-box" <<'EOF_INIT'
#!/bin/sh
printf '%s\n' "$*" >>"$(dirname "$0")/sing-box-init-calls.log"
EOF_INIT
  fi
  chmod +x "$CASE_ROOT/etc/init.d/sing-box"
  printf '#!/bin/sh\n' >"$CASE_ROOT/etc/rc.d/S99sing-box"
  printf 'managed-bin\n' >"$CASE_ROOT/usr/bin/sing-box"
  printf 'managed-cache\n' >"$CASE_ROOT/tmp/sing-box/cache.db"

  case "$marker_case" in
    version_marker) printf '1.10.0\n' >"$CASE_ROOT/etc/tachyon/sing-box-version" ;;
    variant_marker) printf 'extended\n' >"$CASE_ROOT/etc/tachyon/sing-box-variant" ;;
    backup_marker) printf 'backup-data\n' >"$CASE_ROOT/etc/tachyon/component-backups/sing_box" ;;
  esac

  TACHYON_LEGACY_CLEANUP_ROOT="$CASE_ROOT" ucode -L "$TACHYON_LIB" - <<'UCODE'
let mig = require("config.migration");
if (!mig.has_tachyon_managed_singbox_marker()) {
    warn("FAIL: expected Tachyon managed sing-box marker to be detected\n");
    exit(1);
}
mig.cleanup_legacy_core_artifacts();
UCODE

  test -f "$CASE_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json" ||
    fail "$marker_case: /etc/sing-box/config.json backup missing"
  grep -Fq "\"$marker_case\"" "$CASE_ROOT/etc/tachyon/external-configs-backup/sing-box/config.json" ||
    fail "$marker_case: backed up config.json mismatch"
  test -f "$CASE_ROOT/etc/tachyon/external-configs-backup/sing-box/sing-box" ||
    fail "$marker_case: /etc/config/sing-box backup missing"
  grep -Fq "config sing-box '$marker_case'" "$CASE_ROOT/etc/tachyon/external-configs-backup/sing-box/sing-box" ||
    fail "$marker_case: backed up /etc/config/sing-box mismatch"

  grep -Fxq 'stop' "$CASE_ROOT/etc/init.d/sing-box-init-calls.log" ||
    fail "$marker_case: expected /etc/init.d/sing-box stop"
  grep -Fxq 'disable' "$CASE_ROOT/etc/init.d/sing-box-init-calls.log" ||
    fail "$marker_case: expected /etc/init.d/sing-box disable"

  test ! -e "$CASE_ROOT/etc/init.d/sing-box" ||
    fail "$marker_case: managed /etc/init.d/sing-box should be removed"
  test ! -e "$CASE_ROOT/etc/rc.d/S99sing-box" ||
    fail "$marker_case: managed rc.d symlink should be removed"
  test ! -e "$CASE_ROOT/etc/tachyon/sing-box-version" ||
    fail "$marker_case: sing-box-version marker should be removed"
  test ! -e "$CASE_ROOT/etc/tachyon/sing-box-variant" ||
    fail "$marker_case: sing-box-variant marker should be removed"
  test ! -e "$CASE_ROOT/etc/tachyon/component-backups/sing_box" ||
    fail "$marker_case: component-backups/sing_box marker should be removed"
done

printf 'installer config migration checks passed\n'
