// Run the real LuCI view with synthetic data; no live profile credentials.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/outbounds.js', import.meta.url), 'utf8');
const rawLink = 'vpn://' + 'A'.repeat(2048);
const cache = {
  outboundMetadata: {
    names: { owl: 'Owl (RU)', warp: 'WARPv3_34', invalid: rawLink, group: 'Fast', hidden: 'Hidden' },
    protocols: { owl: 'amneziawg', warp: 'amneziawg' },
  },
  urltestGroups: { group: ['owl', 'warp'] },
  hiddenOutboundTags: ['hidden'],
};
const sources = [{ '.name': 'manual', name: 'Manual', source_type: 'proxy_links', proxy_links: [rawLink, 'fptnb:synthetic', 'vless://fixture@example.invalid#Named%20node'] }];
class Node {
  constructor(tag, attributes = {}, children = []) {
    this.tag = tag; this.attributes = attributes; this.value = attributes.value || '';
    this.children = Array.isArray(children) ? children : [children]; this.listeners = {};
  }
  set innerHTML(_value) { this.children = []; }
  appendChild(child) { this.children.push(child); }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  emit(name) { this.listeners[name]?.(); }
}
const main = { getProxyUrlName: (url) => url.includes('#') ? decodeURIComponent(url.split('#')[1]) : '' };
const context = vm.createContext({ main, _: (text) => text,
  E: (tag, attributes, children) => new Node(tag, attributes, children),
  fs: { read: async () => JSON.stringify(cache) },
  uci: { sections: (_pkg, type) => type === 'outbound_source' ? sources : [{ '.name': 'vpn' }] },
});
const api = vm.runInContext(`(function () { ${source.slice(0, source.lastIndexOf('return baseclass.extend('))}
return {loadGlobalPoolChoices, createServerChecklistPicker, showOutboundGroupModal}; })()`, context);
const pool = await api.loadGlobalPoolChoices();
assert.deepEqual(Array.from(pool.servers, (s) => s.value).sort(), ['Named node', 'Owl (RU)', 'WARPv3_34']);
assert.equal(pool.servers.filter((s) => s.value === 'WARPv3_34').length, 1);
assert(!JSON.stringify(pool).includes(rawLink), 'raw URIs must not appear in values or labels');
delete main.getProxyUrlName;
assert.equal((await api.loadGlobalPoolChoices()).servers.length, 2, 'cached names remain usable without a URI name parser');
const input = new Node('input', { value: 'Owl (RU), WARPv3_34' });
const picker = api.createServerChecklistPicker(input); picker.setServers(pool.servers);
const [search, list] = picker.node.children;
const find = (name) => list.children.find((node) => node.children[0].startsWith(name));
assert(find('Owl (RU)').attributes.style.includes('font-weight: 600'), 'a name with spaces must be selected');
find('Owl (RU)').attributes.click(); assert.equal(input.value, 'WARPv3_34');
find('Owl (RU)').attributes.click(); assert.equal(input.value, 'WARPv3_34, Owl (RU)');
search.value = 'owl'; search.emit('input'); assert.equal(list.children.length, 1);
input.value = 'WARPv3_34'; input.emit('input');
assert(!list.children[0].attributes.style.includes('font-weight: 600'));
find('Owl (RU)').attributes.click(); assert.equal(input.value, 'WARPv3_34, Owl (RU)');
assert(!input.value.includes('vpn://'));

// Exercise the real save handler against an in-memory UCI, never the router.
let modal;
const saved = {};
context.ui = { showModal: (_title, children) => { modal = children; }, hideModal() {}, addNotification() { assert.fail('unexpected validation error'); } };
context.uci.get = () => ({ include_outbounds: ['Owl (RU)', 'WARPv3_34'], exclude_outbounds: ['Named node'] });
context.uci.set = (_pkg, _id, key, value) => { saved[key] = value; };
context.uci.unset = () => {};
api.showOutboundGroupModal('test_group');
const nodes = [];
function visit(node) { if (node instanceof Node) { nodes.push(node); node.children.forEach(visit); } }
modal.forEach(visit);
nodes.find((n) => n.tag === 'button' && n.children[0] === 'Save Group').attributes.click();
assert.deepEqual(Array.from(saved.include_outbounds), ['Owl (RU)', 'WARPv3_34']);
assert.deepEqual(Array.from(saved.exclude_outbounds), ['Named node']);
assert(!JSON.stringify(saved).includes('vpn://'));
console.log('PASS: parsed names, no URI duplicates, full-name toggles/search and actual UCI save handler');
