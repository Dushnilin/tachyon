// The test image runs Node 12, which understands neither the `node:` prefix for
// builtin subpaths nor a bare 'assert/strict' in ESM. createRequire reaches the
// strict API through CommonJS resolution, which works on every version we run on.
import { createRequire } from 'module';
const assert = createRequire(import.meta.url)('assert').strict;
import fs from 'fs';
import vm from 'vm';

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

const widgetBlock = source.slice(
  source.indexOf('function createSmartDetectSectionsWidget(section_id) {'),
  source.indexOf('function createMenuTabsOrderWidget(option, section_id) {'),
);
assert.ok(widgetBlock.includes('createSmartDetectSectionsWidget'), 'test must run the actual Smart Detect sections widget');

function makeElement(tag, attrs = {}) {
  return {
    tag,
    attrs: { ...attrs },
    children: [],
    listeners: {},
    textContent: '',
    checked: false,
    disabled: false,
    get firstChild() {
      return this.children[0] || null;
    },
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    removeChild(child) {
      const idx = this.children.indexOf(child);
      if (idx >= 0) this.children.splice(idx, 1);
    },
    addEventListener(type, fn) {
      this.listeners[type] = fn;
    },
  };
}

let mockSections = [
  { '.name': 'main_proxy', action: 'connection', enabled: '1' },
  { '.name': 'policy_group', action: 'group', enabled: '1' },
  { '.name': 'disabled_group', action: 'group', enabled: '0' },
  { '.name': 'local_dpi', action: 'zapret2', enabled: '1' },
  { '.name': 'direct_bypass', action: 'bypass', enabled: '1' },
];
let savedSdSections = ['policy_group'];

const widgetCtx = {
  UCI_PACKAGE: 'tachyon',
  _: (s) => s,
  E: (tag, attrs) => makeElement(tag, attrs),
  L: { toArray: (v) => (Array.isArray(v) ? v : v ? [v] : []) },
  uci: {
    sections: () => mockSections,
    get: (_pkg, _sec, opt) => (opt === 'smart_detect_sections' ? savedSdSections : undefined),
  },
};
vm.runInNewContext(widgetBlock, widgetCtx);

const widget = widgetCtx.createSmartDetectSectionsWidget('settings');
assert.deepEqual(Array.from(widget.value), ['policy_group'], 'group section is accepted as selected Smart Detect target');
const listEl = widget.children[0];
assert.equal(listEl.children.length, 2, 'only active testable proxy and group sections are listed');

const [groupRow, proxyRow] = listEl.children;
const groupLabels = groupRow.children.filter((c) => c.tag === 'span');
assert.equal(groupLabels[0].textContent, 'policy_group');
const groupBadge = groupRow.children.find((c) => c.attrs && c.attrs['data-section-type'] === 'group');
assert.ok(groupBadge, 'group row must explicitly mark the group section type');
assert.equal(groupBadge.textContent, 'Group');
assert.ok(groupBadge.attrs.title && groupBadge.attrs.title.includes('Routing rule target'), 'group badge must explain rule target semantics');

const proxyBadge = proxyRow.children.find((c) => c.attrs && c.attrs['data-section-type'] === 'group');
assert.equal(proxyBadge, undefined, 'regular proxy section must not have group badge');

console.log('PASS: Smart Detect settings choices, defaults, dependencies, descriptions and locales');
