import fs from 'fs';
import path from 'path';
import vm from 'vm';
import { fileURLToPath } from 'url';
import { strict as assert } from 'assert';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const sectionJsPath =
  process.env.TACHYON_SECTION_JS ||
  path.resolve(
    __dirname,
    '..',
    'luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js',
  );

const src = fs.readFileSync(sectionJsPath, 'utf8');

function between(startMarker, endMarker) {
  const start = src.indexOf(startMarker);
  assert.notStrictEqual(start, -1, 'Missing start marker: ' + startMarker);
  const end = src.indexOf(endMarker, start);
  assert.notStrictEqual(end, -1, 'Missing end marker: ' + endMarker);
  return src.slice(start, end);
}

const normalizeCode = between(
  'function normalizeOptionValues(value) {',
  'function isOutboundDetourTargetSection(',
);
const dynamicListCode = between(
  'function normalizeDynamicListItems(value) {',
  'function readItemSettingsMap(',
);
const linkedCode = between(
  'const LINKED_CONDITION_OPTION_KEYS = new Set([',
  'function writeListOption(',
);

function createMockUci(initialDb) {
  const db = JSON.parse(JSON.stringify(initialDb));
  const ops = { add: 0, set: 0, unset: 0 };
  const api = {
    get(_pkg, id, key) {
      const rec = db[id];
      if (!rec) return undefined;
      if (key === undefined) return id;
      return rec[key];
    },
    set(_pkg, id, key, val) {
      ops.set += 1;
      if (!db[id]) db[id] = { '.name': id };
      db[id][key] = Array.isArray(val) ? [...val] : val;
    },
    unset(_pkg, id, key) {
      ops.unset += 1;
      if (db[id]) delete db[id][key];
    },
    add(_pkg, type, id) {
      ops.add += 1;
      db[id] = { '.type': type, '.name': id };
      return id;
    },
    sections(_pkg, type) {
      return Object.entries(db)
        .filter(([, rec]) => !type || rec['.type'] === type)
        .map(([id, rec]) => ({ ...rec, '.name': id }));
    },
  };
  return { db, ops, api };
}

function loadSandbox(initialDb) {
  const mock = createMockUci(initialDb);
  const sandbox = {
    UCI_PACKAGE: 'tachyon',
    uci: mock.api,
    console,
    Set,
    Array,
    Object,
    String,
    Boolean,
    RegExp,
  };
  vm.runInNewContext(
    normalizeCode + '\n' + dynamicListCode + '\n' + linkedCode,
    sandbox,
  );
  return { sandbox, db: mock.db, ops: mock.ops };
}

function countConds(db) {
  return Object.keys(db).filter((k) => k.startsWith('cond_'));
}

const initialDb = {
  cond_Direct_Games_RU: {
    '.type': 'condition',
    '.name': 'cond_Direct_Games_RU',
    enabled: '1',
    name: 'Игры и РФ напрямую Rules',
    condition_type: 'atomic',
    community_lists: ['games'],
    domain_suffix: ['steampowered.com'],
  },
  Direct_Games_RU: {
    '.type': 'section',
    '.name': 'Direct_Games_RU',
    enabled: '1',
    name: 'Игры и РФ напрямую',
    label: 'Игры и РФ напрямую',
    action: 'bypass',
  },
  Direct_Games_DNS: {
    '.type': 'section',
    '.name': 'Direct_Games_DNS',
    enabled: '1',
    name: 'Игры DNS',
    label: 'Игры DNS',
    action: 'dns',
    condition_refs: ['cond_Direct_Games_RU'],
  },
};

const { sandbox, db, ops } = loadSandbox(initialDb);

const baseOptions = [
  ['community_lists', ['games']],
  ['domain_suffix', ['steampowered.com']],
  ['domain', []],
  ['user_domains', []],
  ['ip_cidr', []],
  ['community_subnets', []],
  ['rule_set', []],
  ['domain_ip_lists', []],
  ['global_rules', []],
  ['source_ip_cidr', []],
  ['fully_routed_ips', []],
  ['excluded_ips', []],
  ['ports', []],
  ['geoip_country', []],
  ['geoip_mode', ''],
];

// 1) 5 saves with 15 unchanged options -> 0 clones and 0 UCI writes
for (let save = 0; save < 5; save++) {
  for (const [k, v] of baseOptions) {
    sandbox.syncLinkedConditionOption(
      'Direct_Games_RU',
      k,
      Array.isArray(v) ? [...v] : v,
    );
  }
}
assert.strictEqual(
  countConds(db).length,
  1,
  'unchanged saves must produce 0 clones',
);
assert.strictEqual(ops.add, 0, 'unchanged saves must not call uci.add');
assert.strictEqual(ops.set, 0, 'unchanged saves must not call uci.set');
assert.strictEqual(ops.unset, 0, 'unchanged saves must not call uci.unset');

// 2) Modify 1 option + 14 unchanged -> exactly 1 clone (cond_Direct_Games_RU_copy), not 15
const updatedOptions = baseOptions.map(([k, v]) =>
  k === 'user_domains'
    ? [k, ['example.com']]
    : [k, Array.isArray(v) ? [...v] : v],
);
for (const [k, v] of updatedOptions) {
  sandbox.syncLinkedConditionOption('Direct_Games_RU', k, v);
}
assert.deepStrictEqual(
  countConds(db).sort(),
  ['cond_Direct_Games_RU', 'cond_Direct_Games_RU_copy'],
  'modifying 1 option across 15 fields must produce exactly 1 clone',
);
assert.deepStrictEqual(
  db.Direct_Games_RU.condition_refs,
  ['cond_Direct_Games_RU_copy'],
  'Direct_Games_RU condition_refs must point to the detached clone',
);
assert.deepStrictEqual(
  db.cond_Direct_Games_RU_copy.user_domains,
  ['example.com'],
  'detached clone must receive the modified option',
);
assert.strictEqual(
  db.cond_Direct_Games_RU.user_domains,
  undefined,
  'original shared condition must remain untouched',
);
assert.strictEqual(
  db.cond_Direct_Games_RU_copy.name,
  'Игры и РФ напрямую Rules',
  'cloned condition name must not duplicate Rules suffix',
);

// 3) 5 more saves with unchanged updated options -> still 1 clone, 0 extra writes
const opsBeforeRepeat = { ...ops };
for (let save = 0; save < 5; save++) {
  for (const [k, v] of updatedOptions) {
    sandbox.syncLinkedConditionOption(
      'Direct_Games_RU',
      k,
      Array.isArray(v) ? [...v] : v,
    );
  }
}
assert.strictEqual(
  countConds(db).length,
  2,
  'repeat saves must still have only 1 clone',
);
assert.deepStrictEqual(
  ops,
  opsBeforeRepeat,
  'repeat unchanged saves must perform 0 UCI writes',
);

// 4) Section whose label already ends with " Rules" must not become " Rules Rules"
const labelTest = loadSandbox({
  cond_SecA: {
    '.type': 'condition',
    '.name': 'cond_SecA',
    enabled: '1',
    name: 'Already Named Rules',
    condition_type: 'atomic',
    domain_suffix: ['a.example'],
  },
  SecA: {
    '.type': 'section',
    '.name': 'SecA',
    name: 'Already Named Rules',
    label: 'Already Named Rules',
  },
  SecB: {
    '.type': 'section',
    '.name': 'SecB',
    condition_refs: ['cond_SecA'],
  },
});
labelTest.sandbox.syncLinkedConditionOption('SecA', 'domain_suffix', [
  'b.example',
]);
assert.strictEqual(
  labelTest.db.cond_SecA_copy.name,
  'Already Named Rules',
  'must not append duplicate Rules suffix',
);

console.log(
  'PASS: section condition duplication guard (0 noop clones, 1 clone on edit, no duplicate Rules suffix)',
);
