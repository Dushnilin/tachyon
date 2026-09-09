#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
MIGRATION="$TACHYON_LIB/config/migration.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -s "$MIGRATION" ] || fail "runtime configuration migration module is missing"

# ─── 1. Test NetShift and Early Podkop Fixture Migration ─────────────────────
node >"$WORK_DIR/predecessors_fixture.json" <<'NODE'
const fixture = {
  settings: {
    '.name': 'settings',
    '.type': 'settings',
    dns_via_outbound: '1',
    dns_outbound_section: 'sec_proxy',
    block_doh: '1',
    dns_server: '8.8.8.8, 1.1.1.1',
    bootstrap_dns_server: '77.88.8.8 9.9.9.9'
  },
  rule: [
    {
      '.name': 'sec_proxy',
      '.type': 'rule',
      enabled: '1',
      connection_type: 'proxy',
      proxy_config_type: 'selector_text',
      selector_proxy_links_text: 'vless://b1234567-89ab-cdef-0123-456789abcdef@proxy1.example.com:443?encryption=none&security=reality&sni=test.com&fp=chrome&pbk=publicKey&type=tcp#ProxyOne\n\n# comment\nss://YWVzLTEyOC1nY206cGFzc3dvcmQ@proxy2.example.com:8388#ProxyTwo'
    },
    {
      '.name': 'sec_urltest',
      '.type': 'rule',
      enabled: '1',
      connection_type: 'proxy',
      proxy_config_type: 'urltest_text',
      urltest_proxy_links_text: 'trojan://password@proxy3.example.com:443#TrojanOne\nvmess://eyJ2IjoiMiIsInBzIjoiVm1lc3NPbmUiLCJhZGQiOiJwcm94eTQuZXhhbXBsZS5jb20iLCJwb3J0IjoiNDQzIiwiaWQiOiJiMTIzNDU2Ny04OWFiLWNkZWYtMDEyMy00NTY3ODlhYmNkZWYiLCJhaWQiOiIwIiwic2N5IjoiYXV0byIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0IjoidGVzdC5jb20iLCJwYXRoIjoiL3dzIiwidGxzIjoidGxzIn0=',
      urltest_idle_timeout: '25m',
      urltest_interrupt_exist_connections: '1',
      urltest_interval: '15m'
    },
    {
      '.name': 'sec_sub',
      '.type': 'rule',
      enabled: '1',
      connection_type: 'proxy',
      proxy_config_type: 'subscription',
      subscription_url: [
        'https://feed1.example.com/sub.txt',
        'https://feed2.example.com/sub.txt'
      ],
      subscription_insecure: '1',
      subscription_format_preference: 'auto',
      subscription_group_mode: 'none',
      subscription_group_prefix_len: '2',
      subscription_filter_include_keywords: 'US|NL',
      subscription_filter_exclude_keywords: 'RU|BY',
      global_proxy: '1'
    },
    {
      '.name': 'sec_early_podkop',
      '.type': 'rule',
      enabled: '1',
      connection_type: 'proxy',
      proxy_config_type: 'url',
      proxy_string: 'vless://b1234567-89ab-cdef-0123-456789abcdef@single.example.com:443?encryption=none&security=reality&sni=test.com&fp=chrome&pbk=publicKey&type=tcp#Single',
      domain_list_urls: [
        'https://antifilter.download/list/domains.lst'
      ],
      subnet_list_urls: [
        'https://antifilter.download/list/ip.lst'
      ]
    }
  ]
};

process.stdout.write(`${JSON.stringify(fixture, null, 2)}\n`);
NODE

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/predecessors_fixture.json" podkop >"$WORK_DIR/output.json"

node - "$WORK_DIR/output.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const config = out.config;

function assert(condition, message) {
  if (!condition) {
    console.error(`ASSERTION FAILED: ${message}`);
    process.exit(1);
  }
}

// 1. Settings checks
assert(config.settings.dns_detour_enabled === '1', 'NetShift dns_via_outbound must map to dns_detour_enabled=1');
assert(config.settings.dns_detour_section === 'sec_proxy', 'NetShift dns_outbound_section must map to dns_detour_section');
assert(config.settings.block_doh === undefined, 'NetShift block_doh must be cleaned up');
assert(Array.isArray(config.settings.dns_server) && config.settings.dns_server.length === 2, 'Comma-separated dns_server must be normalized to array');
assert(config.settings.dns_server[0] === '8.8.8.8' && config.settings.dns_server[1] === '1.1.1.1', 'dns_server entries must match split elements');
assert(Array.isArray(config.settings.bootstrap_dns_server) && config.settings.bootstrap_dns_server.length === 2, 'Space-separated bootstrap_dns_server must be normalized to array');
assert(config.settings.bootstrap_dns_server[0] === '77.88.8.8' && config.settings.bootstrap_dns_server[1] === '9.9.9.9', 'bootstrap_dns_server entries must match split elements');

const sections = Object.fromEntries(config.section.map(s => [s['.name'], s]));

// 2. NetShift selector_text rule migrated to connection with selector_proxy_links
const secProxy = sections['sec_proxy'];
assert(secProxy !== undefined, 'sec_proxy section must exist');
assert(secProxy.action === 'connection', 'sec_proxy must be migrated to action=connection');
assert(secProxy.proxy_config_type === undefined, 'proxy_config_type must be deleted in Tachyon unified schema');
assert(Array.isArray(secProxy.selector_proxy_links) && secProxy.selector_proxy_links.length === 2, `Expected 2 selector_proxy_links for sec_proxy, got ${JSON.stringify(secProxy.selector_proxy_links)}`);
assert(secProxy.selector_proxy_links[0].startsWith('vless://'), 'First proxy link must be preserved');
assert(secProxy.selector_proxy_links[1].startsWith('ss://'), 'Second proxy link must be preserved');

// 3. NetShift urltest_text rule migrated to connection with child urltest
const secUrltest = sections['sec_urltest'];
assert(secUrltest !== undefined, 'sec_urltest section must exist');
assert(secUrltest.action === 'connection', 'sec_urltest must be migrated to action=connection');
assert(secUrltest.proxy_config_type === undefined, 'proxy_config_type must be deleted in Tachyon unified schema');
assert(Array.isArray(secUrltest.selector_proxy_links) && secUrltest.selector_proxy_links.length === 2, `Expected 2 selector_proxy_links for sec_urltest, got ${JSON.stringify(secUrltest.selector_proxy_links)}`);
const childUrltests = config.urltest || [];
const urltestItem = childUrltests.find(u => u.section === 'sec_urltest');
assert(urltestItem !== undefined, 'child urltest section must exist for sec_urltest');
assert(urltestItem.idle_timeout === '25m', 'urltest_idle_timeout must be inherited into child urltest');
assert(urltestItem.interrupt_exist_connections === '1', 'urltest_interrupt_exist_connections must be inherited into child urltest');
assert(urltestItem.check_interval === '15m', 'urltest check_interval must be preserved in child urltest');

// 4. NetShift multi-feed subscription_url
const secSub = sections['sec_sub'];
assert(secSub !== undefined, 'sec_sub section must exist');
assert(secSub.action === 'connection', 'sec_sub must be migrated to action=connection');
assert(secSub.proxy_config_type === undefined, 'proxy_config_type must be deleted in Tachyon unified schema');
const childSubs = config.subscription_url || [];
const subItems = childSubs.filter(s => s.section === 'sec_sub');
assert(subItems.length === 2, `Multi-feed subscription_url must generate 2 child subscription_url sections, got ${subItems.length}`);
assert(subItems[0].url === 'https://feed1.example.com/sub.txt', 'First subscription URL must be preserved');
assert(subItems[1].url === 'https://feed2.example.com/sub.txt', 'Second subscription URL must be preserved');

// Verify obsolete NetShift options were cleaned up
assert(secSub.subscription_insecure === undefined, 'subscription_insecure must be cleaned up');
assert(secSub.subscription_format_preference === undefined, 'subscription_format_preference must be cleaned up');
assert(secSub.subscription_group_mode === undefined, 'subscription_group_mode must be cleaned up');
assert(secSub.global_proxy === undefined, 'global_proxy must be cleaned up');

// 5. Early Podkop domain_list_urls and subnet_list_urls
const secEarly = sections['sec_early_podkop'];
assert(secEarly !== undefined, 'sec_early_podkop section must exist');
assert(Array.isArray(secEarly.remote_domain_lists) && secEarly.remote_domain_lists.includes('https://antifilter.download/list/domains.lst'), 'domain_list_urls must migrate to remote_domain_lists');
assert(Array.isArray(secEarly.remote_subnet_lists) && secEarly.remote_subnet_lists.includes('https://antifilter.download/list/ip.lst'), 'subnet_list_urls must migrate to remote_subnet_lists');
assert(secEarly.domain_list_urls === undefined, 'domain_list_urls key must be deleted');
assert(secEarly.subnet_list_urls === undefined, 'subnet_list_urls key must be deleted');

console.log('Predecessor fixtures assertion passed successfully.');
NODE

# ─── 2. Test Format Detection for All Predecessors ───────────────────────────
cat >"$WORK_DIR/mock_netshift.conf" <<'EOF'
config settings 'settings'
	option enabled '1'
	option dns_via_outbound '1'
	option dns_outbound_section 'main_proxy'

config rule 'main_proxy'
	option enabled '1'
	option proxy_config_type 'selector_text'
	option selector_proxy_links_text 'vless://example'
EOF

cat >"$WORK_DIR/mock_forkop.conf" <<'EOF'
config settings 'settings'
	option enabled '1'

config section 'my_wg'
	option enabled '1'
	option connection_type 'vpn'
	option proxy_config_type 'interface'
	option interface 'wg0'
EOF

cat >"$WORK_DIR/mock_podkop.conf" <<'EOF'
config settings 'settings'
	option enabled '1'

config rule 'antifilter'
	option enabled '1'
	option connection_type 'proxy'
	option proxy_config_type 'url'
	list domain_list_urls 'https://antifilter.download/list/domains.lst'
EOF

cat >"$WORK_DIR/mock_tachyon.conf" <<'EOF'
config settings 'settings'
	option enabled '1'
	option config_version '1.0.5'
	list applied_migrations 'interface_sections'
	list applied_migrations 'ensure_dns_server_defaults'

config section 'my_proxy'
	option enabled '1'
	option action 'connection'
	list selector_proxy_links 'vless://example'
EOF

cat >"$WORK_DIR/detect_test.uc" <<'UCODE'
let migration = require("config.migration");

function assert(val, msg) {
    if (!val) {
        warn("ASSERTION FAILED: " + msg + "\n");
        exit(1);
    }
}

let ns_src = migration.detect_config_migration_source(ARGV[0]);
assert(ns_src == "podkop", "NetShift config must be detected as legacy podkop format, got: " + ns_src);

let fk_src = migration.detect_config_migration_source(ARGV[1]);
assert(fk_src == "podkop", "Forkop config must be detected as legacy podkop format, got: " + fk_src);

let pk_src = migration.detect_config_migration_source(ARGV[2]);
assert(pk_src == "podkop", "Podkop config must be detected as legacy podkop format, got: " + pk_src);

let tc_src = migration.detect_config_migration_source(ARGV[3]);
assert(tc_src == "tachyon", "Tachyon config must be detected as native tachyon format, got: " + tc_src);

print("Format detection tests passed successfully.\n");
UCODE

ucode -L "$TACHYON_LIB" "$WORK_DIR/detect_test.uc" \
  "$WORK_DIR/mock_netshift.conf" \
  "$WORK_DIR/mock_forkop.conf" \
  "$WORK_DIR/mock_podkop.conf" \
  "$WORK_DIR/mock_tachyon.conf"

printf 'ALL predecessor migration tests passed successfully.\n'
