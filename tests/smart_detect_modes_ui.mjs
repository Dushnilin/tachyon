import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const root = new URL('../', import.meta.url);
const source = fs.readFileSync(new URL('luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js', root), 'utf8');
const block = source.slice(source.indexOf('  // Smart Detect\n'), source.indexOf('  // Smart Detect sections (domain test order)'));
assert.ok(block.includes('smart_detect_mode'), 'test must run the actual settings block');
const options = [];
let stored;
vm.runInNewContext(block, {
  o: undefined,
  _: (s) => s,
  UCI_PACKAGE: 'tachyon',
  form: { Flag: 'Flag', ListValue: 'ListValue' },
  uci: { get: () => stored },
  section: { taboption(tab, type, name, title, description) {
    const option = { tab, type, name, title, description, choices: [], dependencies: [],
      renderWidget() { return this.description; },
      value(value, label) { this.choices.push([value, label]); },
      depends(key, value) { this.dependencies.push([key, value]); } };
    options.push(option);
    return option;
  } },
});
const [flag, mode] = options;
assert.equal(flag.name, 'smart_detect');
assert.equal(flag.default, '0');
assert.equal(mode.type, 'ListValue');
assert.equal(mode.default, 'default');
assert.deepEqual(Array.from(mode.choices, (a) => Array.from(a, (v) => v)), [
  ['default', 'Default (upstream)'], ['plus', 'Plus'],
]);
assert.equal(JSON.stringify(mode.dependencies), JSON.stringify([['smart_detect', '1']]));
for (const [value, expected] of [[undefined, 'default'], ['default', 'default'], ['bad', 'default'], ['plus', 'plus']]) {
  stored = value;
  assert.equal(mode.cfgvalue('settings'), expected);
}
const displayed = { textContent: '' };
mode.cbid = (section) => `cbid.tachyon.${section}.smart_detect_mode`;
mode.map = { findElement(key, value) {
  assert.equal(key, 'data-field');
  assert.equal(value, 'cbid.tachyon.settings.smart_detect_mode');
  return { querySelector: () => displayed };
} };
for (const selected of ['default', 'plus', 'bad', undefined]) {
  const plus = selected === 'plus';
  const description = mode.renderWidget('settings', 0, selected);
  assert.ok(description.startsWith(plus ? 'Plus:' : 'Default:'));
  assert.ok(description.includes(plus ? 'GET' : 'HEAD'));
  assert.ok(!description.includes(plus ? 'Default:' : 'Plus:'));
  for (const removed of ['Both modes', '30 seconds', 'automatic removal', 'QUIC/UDP'])
    assert.ok(!description.includes(removed), `removed extra hint ${removed}`);
  mode.onchange(null, 'settings', selected);
  assert.equal(displayed.textContent, description, 'hint updates immediately on selection');
}
for (const pair of [['fe-app-tachyon/locales/tachyon.ru.po', 'luci-app-tachyon/po/ru/tachyon.po'], ['fe-app-tachyon/locales/tachyon.pot', 'luci-app-tachyon/po/templates/tachyon.pot']])
  assert.equal(fs.readFileSync(new URL(pair[0], root), 'utf8'), fs.readFileSync(new URL(pair[1], root), 'utf8'), 'source and shipped locales synchronized');
console.log('PASS: Smart Detect settings choices, defaults, dependencies, descriptions and locales');
