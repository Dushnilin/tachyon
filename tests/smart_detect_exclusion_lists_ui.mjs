import { createRequire } from 'module';
const assert = createRequire(import.meta.url)('assert').strict;
import fs from 'fs';
import vm from 'vm';

const read = (path) => fs.readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const source = read('luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js');
const constants = read('fe-app-tachyon/src/constants.ts');
const catalog = vm.runInNewContext('(' + constants.match(/export const DOMAIN_LIST_OPTIONS = (\{[\s\S]*?\});/)[1] + ')');
const options = {};
vm.runInNewContext(source.slice(source.indexOf('  const sdExpandOpt'), source.indexOf('  const sdDomainsOpt')), {
  _: (text) => text,
  main: { DOMAIN_LIST_OPTIONS: catalog },
  form: { Flag: 'Flag', DynamicList: 'DynamicList' },
  section: { taboption(tab, type, name, title, description) {
    return options[name] = { tab, type, title, description, choices: [],
      value(key, label) { this.choices.push(key); }, depends() {} };
  } },
});
const preset = options.smart_detect_exclude_lists;
assert.equal(preset.type, 'DynamicList');
assert.equal(preset.choices.length, Object.keys(catalog).length - 5);
for (const key of ['discord', 'telegram', 'roblox', 'hodca', 'russia_inside'])
  assert.ok(preset.choices.includes(key), key + ' remains available');
for (const key of ['cloudflare', 'cloudfront', 'hetzner', 'ovh', 'digitalocean'])
  assert.ok(!preset.choices.includes(key), key + ' is IP-only');
for (const value of [null, [], 'discord', ['telegram', 'roblox']])
  assert.equal(preset.validate('settings', value), true);
for (const value of ['unknown', '../telegram', ['discord', 'cloudflare']])
  assert.notEqual(preset.validate('settings', value), true);
assert.ok(preset.description.includes('previously added domains are kept'));
assert.ok(preset.description.includes('detection waits'));
for (const title of Object.values(options).map((option) => option.title)) {
  const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  assert.ok(new RegExp('msgid "' + escaped + '"\\s+msgstr "[^"\\n]+"').test(read('luci-app-tachyon/po/ru/tachyon.po')), title + ' is translated');
}
console.log('PASS: exclusion list catalog, selection validation, hints and Russian labels');
