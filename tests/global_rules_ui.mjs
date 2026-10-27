// The LuCI side of a global rule claim: which values a section may still offer,
// what the exclusivity guard tells a section that tries to reuse one, and what
// saving a claim actually changes in the other sections.
//
// The view is a LuCI module, not an importable file, so like the smart_detect UI
// checks this runs the real source in a vm with the handful of globals it touches
// mocked. Everything asserted here is the file's own code - nothing is
// reimplemented, or the test would keep passing against the old behaviour.
import { createRequire } from 'module';
const assert = createRequire(import.meta.url)('assert').strict;
import fs from 'fs';
import vm from 'vm';

const read = (path) => fs.readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const view = read('luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js');

const at = (needle) => {
  const i = view.indexOf(needle);
  assert.ok(i >= 0, `section.js no longer contains: ${needle}`);
  return i;
};
const between = (from, to) => view.slice(at(from), at(to));
const fn = (name) => {
  const start = at(`function ${name}(`);
  return view.slice(start, view.indexOf('\nfunction ', start + 1));
};

// sec_other carries the value in its conditions without claiming it, which is
// what a hand-edited or imported config looks like: the claim on sec_owner is
// the only thing that may decide who owns it.
const db = {
  sec_owner: {
    '.name': 'sec_owner',
    label: 'Owner',
    community_lists: ['youtube', 'telegram'],
    global_rules: ['community_lists:youtube'],
  },
  sec_other: {
    '.name': 'sec_other',
    label: 'Other',
    community_lists: ['youtube', 'telegram'],
    global_rules: [],
  },
};

const uci = {
  get: (_pkg, id, key) => (db[id] ? db[id][key] : undefined),
  set: (_pkg, id, key, value) => {
    db[id][key] = value;
  },
  unset: (_pkg, id, key) => {
    delete db[id][key];
  },
  sections: (_pkg, _type) => Object.values(db),
};

const ctx = vm.createContext({ uci, _: (text) => text, UCI_PACKAGE: 'tachyon' });
// LuCI patches String.prototype.format onto every translated string; the vm has
// its own realm, so the patch has to be applied there too.
vm.runInContext(
  'String.prototype.format = function () {' +
    '  let i = 0; const a = arguments;' +
    '  return this.replace(/%s/g, () => String(a[i++]));' +
    '};',
  ctx,
);
vm.runInContext(
  [
    // The value readers, whose section helpers live near the top of the file.
    between(
      'function normalizeOptionValues(value) {',
      'function isOutboundDetourTargetSection(',
    ),
    // The linked-condition reader: a section may keep its conditions in a
    // child "cond_<section>" section, and the value readers have to see them.
    between(
      'const LINKED_CONDITION_OPTION_KEYS = new Set([',
      'function syncLinkedConditionOption(',
    ),
    fn('normalizeDynamicListItems'),
    fn('uniqueDynamicListItems'),
    // The claim picker is declared inside createSectionContent; only its own
    // validate matters here, so the object it lands on is recreated by hand.
    'var globalRulesOption = {};',
    between(
      '  globalRulesOption.validate = function (section_id, value) {',
      '  globalRulesOption.write = function (section_id, value) {',
    ),
    between(
      'const GLOBAL_RULE_OPTION_KEYS = {',
      'function loadRulesetValues(option, sectionId) {',
    ),
    between(
      'function copySectionOptions(sourceId, targetId, overrides = {}) {',
      'function copyChildSections(',
    ),
  ].join('\n'),
  ctx,
);

// --- claim syntax ----------------------------------------------------------
const simple = ctx.parseGlobalRule('community_lists:youtube');
assert.ok(simple && simple.kind === 'community_lists' && simple.value === 'youtube',
  'a plain claim must split on its first colon');
const url = ctx.parseGlobalRule('rule_set:https://example.com/a.srs');
assert.ok(url && url.value === 'https://example.com/a.srs',
  'a value that itself contains colons must keep them');
assert.equal(ctx.parseGlobalRule('bogus:value'), null, 'an unknown kind must not parse');
assert.equal(ctx.parseGlobalRule('community_lists'), null, 'a claim without a value must not parse');

// --- who may still offer the value ----------------------------------------
assert.deepEqual([...ctx.foreignGlobalValues('community_lists', 'sec_other')], ['youtube'],
  'a section must see the value another section claims as reserved');
assert.equal(ctx.foreignGlobalValues('community_lists', 'sec_owner').size, 0,
  'the owner itself must never be blocked from its own claim');
assert.equal(ctx.foreignGlobalValues('ports', 'sec_other').size, 0,
  'an unrelated kind must not inherit the claim');

// A claim whose owner no longer uses the value reserves nothing - otherwise
// deleting one condition from a section would starve every other section of a
// value nobody has.
db.sec_owner.community_lists = ['telegram'];
assert.equal(ctx.foreignGlobalValues('community_lists', 'sec_other').size, 0,
  'a stale claim must not reserve the value');
db.sec_owner.community_lists = ['youtube', 'telegram'];

// --- the guard a condition picker gets -------------------------------------
const picker = {};
ctx.enforceGlobalRuleExclusivity(picker, 'community_lists');
assert.equal(picker.validate('sec_owner', ['youtube']), true,
  'the owner must keep using the value it claimed');
const denied = picker.validate('sec_other', ['youtube']);
assert.notEqual(denied, true, 'a claimed value must be refused in another section');
assert.ok(String(denied).includes('Owner'), `the refusal must name the owner, got: ${denied}`);
assert.equal(picker.validate('sec_other', ['telegram']), true,
  'an unclaimed value must stay usable everywhere');
assert.equal(picker.validate('sec_other', []), true, 'an empty value must not be refused');

// The guard wraps whatever validate the option already had, so a format error
// must still win and must not be swallowed.
let ownValidateCalls = 0;
const wrapped = {
  validate() {
    ownValidateCalls += 1;
    return 'format error';
  },
};
ctx.enforceGlobalRuleExclusivity(wrapped, 'community_lists');
assert.equal(wrapped.validate('sec_other', ['youtube']), 'format error',
  "the option's own validate must run first");
assert.equal(ownValidateCalls, 1, "the option's own validate must run exactly once");

// --- the claim picker ------------------------------------------------------
assert.equal(ctx.globalRulesOption.validate('sec_owner', ['community_lists:youtube']), true,
  'the owner must be able to claim a value it uses');
const stolen = ctx.globalRulesOption.validate('sec_other', ['community_lists:youtube']);
assert.notEqual(stolen, true,
  'claiming a value another section already owns must be refused, or the write would strip it from the real owner');
assert.ok(String(stolen).includes('Owner'), `the refusal must name the owner, got: ${stolen}`);
const notOurs = ctx.globalRulesOption.validate('sec_owner', ['community_lists:discord']);
assert.notEqual(notOurs, true, 'a claim must be refused when this section does not use the value');
assert.notEqual(ctx.globalRulesOption.validate('sec_owner', ['nonsense']), true,
  'a malformed claim must be refused instead of silently dropped');

// --- what saving a claim changes elsewhere ---------------------------------
const before = JSON.stringify(db);
assert.deepEqual(
  [...ctx.releaseGlobalRuleFromOtherSections('sec_owner', { kind: 'community_lists', value: 'youtube' })],
  ['Other'],
  'the section that lost the value must be reported back to the user',
);
assert.deepEqual([...db.sec_other.community_lists], ['telegram'],
  'the value must actually leave the other section');
assert.equal(db.sec_owner.community_lists.length, 2, 'the owner must keep its own value');
assert.equal(JSON.parse(before).sec_owner.community_lists.length, 2, 'the owner record must be untouched');

// Re-saving an already-effective claim is a no-op: no state change and no
// notification, otherwise every save would claim a removal that never happened.
const settled = JSON.stringify(db);
assert.deepEqual(
  [...ctx.releaseGlobalRuleFromOtherSections('sec_owner', { kind: 'community_lists', value: 'youtube' })],
  [],
  'nothing left to remove must report nothing',
);
assert.equal(JSON.stringify(db), settled, 'an already-effective claim must write nothing');

// --- the badge -------------------------------------------------------------
const choices = ctx.globalRuleChoices('sec_owner').map((choice) => choice.value);
assert.ok(choices.includes('community_lists:youtube'),
  'the claim picker must offer the values this section uses');

// --- a clone must not inherit the ownership --------------------------------
// Cloning a section that owns a global rule would give the claim two owners,
// and the validator rejects that - so the duplicate would brick the apply the
// moment it was created.
db.sec_clone = { '.name': 'sec_clone' };
ctx.copySectionOptions('sec_owner', 'sec_clone', { label: 'Owner (Copy)', name: 'owner_copy' });
assert.equal(db.sec_clone.global_rules, undefined,
  'a cloned section must not inherit the global-rule claim');
assert.deepEqual([...db.sec_clone.community_lists], ['youtube', 'telegram'],
  'the clone must keep the conditions themselves');

// --- Russian labels --------------------------------------------------------
const po = read('luci-app-tachyon/po/ru/tachyon.po');
for (const title of ['Global rule', 'Global rules', 'Global rule enabled', 'Condition value']) {
  assert.ok(
    new RegExp(`msgid "${title}"\\s+msgstr "[^"\\n]+"`).test(po),
    `${title} must have a Russian translation`,
  );
}
assert.ok(
  new RegExp('msgid "Global rule enabled"\\s+msgstr "Включено глобальное правило"').test(po),
  'the badge must read Включено глобальное правило',
);

console.log('PASS: global rule claims, exclusivity guard, cross-section release and Russian labels');
