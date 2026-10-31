#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

MIGRATION="$TACHYON_LIB/config/migration.uc"
VALIDATOR="$TACHYON_LIB/config/validator.uc"

# Use the same legacy source selector as the Forkop installer/import command.
# Every address and credential in these fixtures is synthetic.
node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
const settings = {
  '.name': 'settings', '.type': 'settings', config_version: '1.0.5',
  dns_server: ['1.1.1.1'], bootstrap_dns_server: ['1.1.1.1']
};
const links = [
  'vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha%20One',
  'vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta%20Two'
];
const patterns = ['^(Alpha One|Beta Two)$', '^Node[ ,]{1,3}EU$'];
for (const shape of ['scalar', 'list']) {
  const filters = {
    include_regex: shape === 'scalar' ? patterns[0] : patterns,
    exclude_regex: shape === 'scalar' ? patterns[1] : [...patterns].reverse()
  };
  const fixture = {
    settings,
    section: [{ '.name': 'demo', '.type': 'section', enabled: '1', action: 'connection', selector_proxy_links: links }],
    priority_group: [{ '.name': 'pg', '.type': 'priority_group', section: 'demo', name: 'Main', interrupt_exist_connections: '0' }],
    priority_level: [{ '.name': 'pl', '.type': 'priority_level', group: 'pg', name: 'Primary', order: '0', ...filters }],
    urltest: [{ '.name': 'ut', '.type': 'urltest', section: 'demo', name: 'Fastest', ...filters }]
  };
  fs.writeFileSync(`${dir}/regex-${shape}.json`, JSON.stringify(fixture));
  const alias = structuredClone(fixture);
  alias.priority_level[0].regex = alias.priority_level[0].include_regex;
  delete alias.priority_level[0].include_regex;
  fs.writeFileSync(`${dir}/alias-${shape}.json`, JSON.stringify(alias));
}
for (const shape of ['scalar', 'list', 'text']) {
  const domains = ['example.com', 'full:exact.example.net', 'keyword:video', 'regex:^api[.]example[.]org$'];
  const section = { '.name': 'demo', '.type': 'section', enabled: '1', action: 'bypass' };
  if (shape === 'text') {
    section.domain_text_mode = '1';
    section.domain_text = domains.join('\n');
  } else {
    section.domain = shape === 'scalar' ? domains.join('\n') : domains;
  }
  fs.writeFileSync(`${dir}/domains-${shape}.json`, JSON.stringify({ settings, section: [section] }));
}
NODE

for name in regex-scalar regex-list alias-scalar alias-list domains-scalar domains-list domains-text; do
  ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/$name.json" podkop >"$WORK_DIR/$name-result.json"
  node - "$WORK_DIR/$name-result.json" "$WORK_DIR/$name-migrated.json" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[3], JSON.stringify(JSON.parse(fs.readFileSync(process.argv[2])).config));
NODE
  ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-runtime-fixture "$WORK_DIR/$name-migrated.json" '{}'
  ucode -L "$TACHYON_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/$name-migrated.json" tachyon >"$WORK_DIR/$name-repeat.json"
done

node - "$WORK_DIR" <<'NODE'
const fs = require('fs');
const assert = require('assert/strict');
const dir = process.argv[2];
for (const prefix of ['regex', 'alias']) {
  for (const shape of ['scalar', 'list']) {
    const source = JSON.parse(fs.readFileSync(`${dir}/${prefix}-${shape}.json`));
    const first = JSON.parse(fs.readFileSync(`${dir}/${prefix}-${shape}-result.json`)).config;
    const repeat = JSON.parse(fs.readFileSync(`${dir}/${prefix}-${shape}-repeat.json`)).config;
    for (const config of [first, repeat]) {
      const group = config.outbound_group.find(g => g.name === 'Primary');
      const balancer = config.balancer.find(b => b.name === 'Fastest');
      for (const key of ['include_regex', 'exclude_regex']) {
        const value = source.urltest[0][key];
        const expected = Array.isArray(value) ? value : [value];
        assert.deepEqual(group[key], expected, `${prefix}/${shape}: priority ${key}`);
        assert.deepEqual(balancer[key], expected, `${prefix}/${shape}: URLTest ${key}`);
      }
    }
    assert.deepEqual(repeat.section, first.section, `${prefix}/${shape}: repeated section migration`);
    assert.deepEqual(repeat.outbound_group, first.outbound_group, `${prefix}/${shape}: repeated group migration`);
    assert.deepEqual(repeat.balancer, first.balancer, `${prefix}/${shape}: repeated balancer migration`);
  }
}
for (const shape of ['scalar', 'list', 'text']) {
  const first = JSON.parse(fs.readFileSync(`${dir}/domains-${shape}-result.json`)).config;
  const repeat = JSON.parse(fs.readFileSync(`${dir}/domains-${shape}-repeat.json`)).config;
  for (const config of [first, repeat]) {
    const expected = ['example.com', 'full:exact.example.net', 'keyword:video', 'regex:^api[.]example[.]org$'];
    assert.deepEqual(config.section[0].domain.split('\n'), expected, `${shape}: section domain`);
    const condition = config.condition.find(c => c['.name'] === config.section[0].condition_refs[0]);
    const values = Array.isArray(condition.domain) ? condition.domain : condition.domain.split('\n');
    assert.deepEqual(values, expected, `${shape}: referenced condition domain`);
  }
  assert.deepEqual(repeat.section, first.section, `${shape}: repeated section migration`);
}
NODE

# Trace through the referenced condition without falling back to legacy fields.
ucode -L "$TACHYON_LIB" - "$WORK_DIR/domains-list-migrated.json" <<'UCODE'
let fs = require("fs");
let connections = require("config.connections");
let fixture = json(fs.readfile(ARGV[0]));
connections.set_item_sections_from_data(fixture);
delete fixture.section[0].domain;
for (let pair in [
    [ "example.com", true ],
    [ "api.example.com", true ],
    [ "exact.example.net", true ],
    [ "child.exact.example.net", false ],
    [ "myvideo.example", true ],
    [ "unrelated.example", false ]
]) {
    let trace = connections.trace_rules({ mode: "exact", domain: pair[0] }, fixture.section);
    if ((trace.winning_section != null) != pair[1])
        die("Changed domain semantics for " + pair[0] + ": " + sprintf("%J", trace) + "\n");
}
UCODE

printf 'legacy import semantics checks passed\n'
