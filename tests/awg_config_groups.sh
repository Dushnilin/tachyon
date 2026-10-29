#!/usr/bin/env bash
# An AmneziaWG section carrying several imported .conf files expands the way an
# FPTN token does: one endpoint per config, an auto urltest over them and the
# section selector on top, so the URLTest/Priority groups have members to pick
# between. Before this the section emitted a bare endpoint wearing the section
# tag, which is neither a selector nor groupable, and a URLTest/Priority child
# on an AWG section produced nothing at all.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"

# vpn:// import and the AWG group expansion are both gated on the variant
# marker, never on a version string: both families ship a sing-box binary.
printf 'tachyon-core' >"$WORK_DIR/variant"
printf '0.0.9' >"$WORK_DIR/version"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant" SB_VERSION_STATE_FILE="$WORK_DIR/version"

generate_config() {
  local fixture="$1"
  local config="$2"

  mkdir -p "${config}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$config" "127.0.0.1" "0"
}

validate_fixture() {
  local source="$1"
  local normalized="$WORK_DIR/validator-$(basename "$source")"

  node - "$source" "$normalized" <<'JS'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (input.settings === undefined || input.settings === null) input.settings = { '.name': 'settings', '.type': 'settings' };
if (input.settings.dns_server === undefined || input.settings.dns_server === null) input.settings.dns_server = ['77.88.8.8'];
if (input.settings.bootstrap_dns_server === undefined || input.settings.bootstrap_dns_server === null) input.settings.bootstrap_dns_server = ['77.88.8.8'];
fs.writeFileSync(process.argv[3], JSON.stringify(input));
JS
  ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-runtime-fixture "$normalized" "{}"
}

assert_rejects() {
  local label="$1"
  local fixture="$2"
  local expected="$3"
  local output

  if output="$(validate_fixture "$fixture" 2>&1)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

KEY="$(node -e 'process.stdout.write(Buffer.from(Array.from({length:32},(_,i)=>i+1)).toString("base64"))')"
conf() {
  printf '[Interface]\nPrivateKey = %s\nAddress = 172.16.0.2\nJc = 4\nH1 = 100-200\nS3 = 40\nS4 = 50\n[Peer]\nPublicKey = %s\nEndpoint = %s\n' \
    "$KEY" "$KEY" "$1"
}

NL_148="$WORK_DIR/nl_148.conf"
NL_282="$WORK_DIR/nl_282.conf"
conf '192.0.2.1:51820' >"$NL_148"
conf '192.0.2.2:51821' >"$NL_282"

# Built with node, not a heredoc: the stored value is JSON inside JSON, and an
# unquoted heredoc leaves its quotes unescaped.
node - "$WORK_DIR" "$NL_148" "$NL_282" <<'JS'
const fs = require('fs');
const [work, first, second] = process.argv.slice(2);
const item = (name, path) => JSON.stringify({ name, config: fs.readFileSync(path, 'utf8') });

fs.writeFileSync(
  `${work}/awg-groups-fixture.json`,
  JSON.stringify({
    settings: { '.name': 'settings', '.type': 'settings', dns_server: ['77.88.8.8'] },
    section: [
      {
        '.name': 'proton',
        '.type': 'section',
        enabled: '1',
        action: 'awg',
        domain_suffix: ['example.org'],
        label: 'proton',
        selector_amnezia_configs: [item('NL_148', first), item('NL_282', second)],
      },
    ],
    urltest: [
      { '.name': 'ut_main', '.type': 'urltest', section: 'proton', name: 'My group', filter_mode: 'disabled' },
    ],
    priority_group: [
      { '.name': 'pg_main', '.type': 'priority_group', section: 'proton', name: 'Main priority' },
    ],
    // A levelless priority group produces no members and no tag, so it would
    // never reach the selector.
    priority_level: [
      { '.name': 'pl_main', '.type': 'priority_level', group: 'pg_main', name: 'Level 1', order: '0', filter_mode: 'disabled' },
    ],
  }),
);
JS

generate_config "$WORK_DIR/awg-groups-fixture.json" "$WORK_DIR/awg-groups-config.json"
[ -s "$WORK_DIR/awg-groups-config.json" ] ||
  fail "generator produced no config (generate-config-fixture writes it to \$2, not \$1)"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));

let members = [ "proton-out/NL_148", "proton-out/NL_282" ];

// One endpoint per imported config, AWG fields preserved, no share_link.
let endpoints = [];
for (let endpoint in config.endpoints || [])
    if (endpoint && endpoint.type == "wireguard")
        push(endpoints, endpoint);
if (length(endpoints) != 2)
    die("expected one wireguard endpoint per imported config, got " + length(endpoints) + "\n");
for (let endpoint in endpoints) {
    if (index(members, endpoint.tag) < 0)
        die("unexpected endpoint tag " + endpoint.tag + "\n");
    if (endpoint.h1 != "100-200" || endpoint.s3 != 40 || endpoint.s4 != 50)
        die("AWG header parameters were lost for " + endpoint.tag + "\n");
    if (endpoint.share_link != null || endpoint.remark != null)
        die("import metadata leaked into " + endpoint.tag + "\n");
    if (length(endpoint.address || []) != 1 || endpoint.address[0] != "172.16.0.2/32")
        die("endpoint address was not normalized to CIDR: " + json(endpoint.address) + "\n");
}

let byTag = { };
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag != null)
        byTag[outbound.tag] = outbound;

// The auto urltest over every imported config. This tag is the section-level
// auto-urltest tag, not a child group tag: urltest_outbound_tag() maps the bare
// id "urltest" onto "<section>-urltest".
let auto = byTag["proton-urltest-out"];
if (!auto || auto.type != "urltest")
    die("missing auto urltest group over the imported configs\n");
for (let member in members)
    if (index(auto.outbounds || [], member) < 0)
        die("auto urltest is missing " + member + "\n");

// The section tag is a selector carrying the members and every group.
let selector = byTag["proton-out"];
if (!selector || selector.type != "selector")
    die("section tag must be a selector when the configs are grouped\n");
for (let member in members)
    if (index(selector.outbounds || [], member) < 0)
        die("section selector is missing " + member + "\n");
let groups = [ "proton-urltest-out", "proton-urltest-ut_main-out", "proton-priority-pg_main-out" ];
for (let group in groups)
    if (index(selector.outbounds || [], group) < 0)
        die("section selector is missing group " + group + "\n");

// The user-defined URLTest and Priority children group the same members.
let urltest = byTag["proton-urltest-ut_main-out"];
if (!urltest || urltest.type != "urltest" || length(urltest.outbounds || []) != 2)
    die("URLTest child did not group the imported configs\n");
let priority = byTag["proton-priority-pg_main-out"];
if (!priority || priority.type != "selector" || length(priority.outbounds || []) != 2)
    die("Priority child did not group the imported configs\n");

// The route rule still points at the section tag.
let matched = false;
for (let rule in config.route?.rules || [])
    if (rule && rule.outbound == "proton-out")
        matched = true;
if (!matched)
    die("route rule no longer points at the section tag\n");
' "$WORK_DIR/awg-groups-config.json"

printf 'PASS: imported AWG configs expand into endpoints, auto urltest and the section selector\n'

# A URLTest child on an AWG section is validated, not silently ignored.
cat >"$WORK_DIR/awg-bad-urltest.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proton", ".type": "section", "enabled": "1", "action": "awg", "domain_suffix": ["example.org"] }
  ],
  "urltest": [
    { ".name": "ut_bad", ".type": "urltest", "section": "proton", "name": "Bad", "filter_mode": "nonsense" }
  ]
}
JSON
assert_rejects "AWG URLTest child" "$WORK_DIR/awg-bad-urltest.json" "URLTest filter mode"
printf 'PASS: AWG URLTest children are validated\n'

# A manual-only AWG section keeps the old shape: one endpoint under the section
# tag, nothing grouped.
cat >"$WORK_DIR/awg-manual-fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"] },
  "section": [
    {
      ".name": "manual",
      ".type": "section",
      "enabled": "1",
      "action": "awg",
      "domain_suffix": ["example.org"],
      "awg_local_address": "172.16.0.2",
      "awg_private_key": "$KEY",
      "awg_peer_public_key": "$KEY",
      "awg_server_address": "192.0.2.9",
      "awg_server_port": "51820"
    }
  ]
}
JSON

generate_config "$WORK_DIR/awg-manual-fixture.json" "$WORK_DIR/awg-manual-config.json"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let endpoint = null;
for (let candidate in config.endpoints || [])
    if (candidate && candidate.tag == "manual-out")
        endpoint = candidate;
if (!endpoint)
    die("manual-only AWG section lost its endpoint\n");
if (length(endpoint.address || []) != 1 || endpoint.address[0] != "172.16.0.2/32")
    die("manual endpoint address was not normalized to CIDR: " + json(endpoint.address) + "\n");
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag == "manual-out")
        die("manual-only AWG section must not gain a selector\n");
' "$WORK_DIR/awg-manual-config.json"

printf 'PASS: manual-only AWG section keeps its single endpoint\n'

# An AWG section with BOTH inline WARP/AWG fields AND imported .conf files
# expands all of them (inline tunnel + imported .conf files) into endpoints,
# auto urltest, and section selector, and records links in the section cache.
node - "$WORK_DIR" "$NL_148" "$NL_282" "$KEY" <<'JS'
const fs = require('fs');
const [work, first, second, key] = process.argv.slice(2);
const item = (name, path) => JSON.stringify({ name, config: fs.readFileSync(path, 'utf8') });

fs.writeFileSync(
  `${work}/awg-hybrid-fixture.json`,
  JSON.stringify({
    settings: { '.name': 'settings', '.type': 'settings', dns_server: ['77.88.8.8'] },
    section: [
      {
        '.name': 'hybrid',
        '.type': 'section',
        enabled: '1',
        action: 'awg',
        domain_suffix: ['example.org'],
        label: 'WARP Inline',
        awg_local_address: '172.16.0.2',
        awg_private_key: key,
        awg_peer_public_key: key,
        awg_server_address: '162.159.198.1',
        awg_server_port: '2408',
        selector_amnezia_configs: [item('NL_148', first), item('NL_282', second)],
      },
    ],
  }),
);
JS

generate_config "$WORK_DIR/awg-hybrid-fixture.json" "$WORK_DIR/awg-hybrid-config.json"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));

let expected = [ "hybrid-out/WARP Inline", "hybrid-out/NL_148", "hybrid-out/NL_282" ];
let wg_tags = [];
for (let ep in config.endpoints || [])
    if (ep && ep.type == "wireguard")
        push(wg_tags, ep.tag);
if (length(wg_tags) != 3)
    die("expected 3 wireguard endpoints (inline WARP + 2 .conf files), got " + length(wg_tags) + ": " + json(wg_tags) + "\n");
for (let tag in expected) {
    if (index(wg_tags, tag) < 0)
        die("missing wireguard endpoint " + tag + " in " + json(wg_tags) + "\n");
    if (!cache.links || !cache.links[tag])
        die("section cache is missing link for " + tag + "\n");
}
' "$WORK_DIR/awg-hybrid-config.json" "$WORK_DIR/awg-hybrid-config.json.section-cache/hybrid.json"

printf 'PASS: hybrid AWG section (inline WARP + imported .conf files) includes all endpoints and caches links\n'

# Verify that service/state.uc sing-box-signature-fixture changes when
# selector_amnezia_configs or awg_private_key changes on an action=awg section.
STATE_UC="$TACHYON_LIB/service/state.uc"
SIG_MANUAL="$(ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/awg-manual-fixture.json")"
SIG_HYBRID="$(ucode -L "$TACHYON_LIB" "$STATE_UC" sing-box-signature-fixture "$WORK_DIR/awg-hybrid-fixture.json")"
[ -n "$SIG_MANUAL" ] && [ -n "$SIG_HYBRID" ] && [ "$SIG_MANUAL" != "$SIG_HYBRID" ] ||
  fail "sing-box-signature-fixture did not change when AWG configs changed ($SIG_MANUAL vs $SIG_HYBRID)"
UT_SECTIONS="$(ucode -L "$TACHYON_LIB" "$STATE_UC" urltest-enabled-sections-fixture "$WORK_DIR/awg-hybrid-fixture.json")"
printf '%s\n' "$UT_SECTIONS" | grep -Fxq "hybrid" ||
  fail "urltest-enabled-sections-fixture missed AWG section with selector_amnezia_configs (got '$UT_SECTIONS')"

printf 'PASS: service/state.uc tracks AWG configs in sing-box-signature and urltest-enabled-sections\n'

# Verify that config/migration.uc syncs a newly added action=awg section into
# outbound_source (src_awg_<name> and src_amnezia_<name>) even when
# modular_entities_v1 is already in applied_migrations.
MIGRATION_UC="$TACHYON_LIB/config/migration.uc"
node - "$WORK_DIR" "$NL_148" "$KEY" <<'JS'
const fs = require('fs');
const [work, first, key] = process.argv.slice(2);
const item = (name, path) => JSON.stringify({ name, config: fs.readFileSync(path, 'utf8') });

fs.writeFileSync(
  `${work}/awg-post-migration-fixture.json`,
  JSON.stringify({
    settings: {
      '.name': 'settings',
      '.type': 'settings',
      config_version: '1.0.5',
      applied_migrations: [
        'interface_sections',
        'enable_component_checks',
        'http_connection_urls',
        'dns_hosts_to_option',
        'global_hosts_to_section',
        'orphan_section_interface_cleanup',
        'ensure_dns_server_defaults',
        'steer_spec_v2',
        'engine_identity_tachyon_core',
        'modular_entities_v1',
      ],
    },
    section: [
      {
        '.name': 'new_awg',
        '.type': 'section',
        enabled: '1',
        action: 'awg',
        label: 'New AWG',
        awg_local_address: '172.16.0.2',
        awg_private_key: key,
        awg_peer_public_key: key,
        awg_server_address: '162.159.198.1',
        awg_server_port: '2408',
        selector_amnezia_configs: [item('NL_148', first)],
      },
    ],
  }),
);
JS

ucode -L "$TACHYON_LIB" "$MIGRATION_UC" migrate-fixture "$WORK_DIR/awg-post-migration-fixture.json" tachyon >"$WORK_DIR/awg-post-migration-out.json"
ucode -e '
let fs = require("fs");
let res = json(fs.readfile(ARGV[0]));
let sources = res.config?.outbound_source || [];
let has_awg = false;
let has_amn = false;
for (let src in sources) {
    if (src[".name"] == "src_awg_new_awg" && src.awg_private_key != null)
        has_awg = true;
    if (src[".name"] == "src_amnezia_new_awg" && length(src.amnezia_configs || []) == 1)
        has_amn = true;
}
if (!has_awg || !has_amn)
    die(sprintf("expected both src_awg_new_awg and src_amnezia_new_awg in outbound_source after migration cleanup, got %J\n", sources));
' "$WORK_DIR/awg-post-migration-out.json"

printf 'PASS: post-migration AWG section syncs into outbound_source\n'
