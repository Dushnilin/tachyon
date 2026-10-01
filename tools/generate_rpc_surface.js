#!/usr/bin/env node

/**
 * generate_rpc_surface.js
 *
 * Derives the whole RPC surface from the one place that actually dispatches:
 * the command table in tachyon/files/usr/bin/tachyon.
 *
 * The surface used to be described three times by hand -- that table, the
 * Tachyon.AvailableMethods enum in the frontend, and contracts/tachyon-rpc.json
 * -- and the three drifted until the contract was describing a layer that does
 * not exist (60 of the 78 methods the frontend calls were missing from it, and
 * nothing imported the generated result at all). Two sources cannot disagree if
 * only one of them is written by hand.
 *
 * Roles come from tachyon/files/usr/bin/tachyon-read, which is the read-only
 * entry point the LuCI read role is allowed to exec. A command listed there is
 * "read"; everything else is "write", because the read entry point is a
 * whitelist and a command nobody classified has to stay unreachable rather than
 * become reachable.
 *
 * Writes:
 *   contracts/tachyon-rpc.json
 *   fe-app-tachyon/src/tachyon/types.ts  (AvailableMethods block only)
 *
 * Run with --check to fail instead of writing, which is what CI wants.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const DISPATCHER = path.join(
  REPO_ROOT,
  'tachyon',
  'files',
  'usr',
  'bin',
  'tachyon',
);
const READ_ENTRY = path.join(REPO_ROOT, 'tachyon', 'files', 'usr', 'bin', 'tachyon-read');
const CONTRACT_PATH = path.join(REPO_ROOT, 'contracts', 'tachyon-rpc.json');
const TYPES_PATH = path.join(
  REPO_ROOT,
  'fe-app-tachyon',
  'src',
  'tachyon',
  'types.ts',
);

const CHECK_ONLY = process.argv.includes('--check');

/** "        start: [ "service/lifecycle.uc", "start", 0 ]," -> { name, module, fn, arity } */
function parseTable(source, { openRe, closeRe, entryRe }) {
  const table = source.slice(source.indexOf(openRe));
  const end = table.indexOf(closeRe);
  if (end < 0) throw new Error(`no closing match for ${openRe}`);
  const body = table.slice(0, end);

  const out = [];
  const re = new RegExp(entryRe, 'gm');
  let m;
  while ((m = re.exec(body))) {
    out.push({
      name: m[1].replace(/"/g, ''),
      module: m[2].replace(/"/g, ''),
      fn: m[3].replace(/"/g, ''),
      arity: Number.parseInt(m[4], 10) || 0,
    });
  }
  if (out.length === 0) throw new Error('parsed zero commands, refusing to emit');
  return out;
}

const dispatcher = fs.readFileSync(DISPATCHER, 'utf8');
const readEntry = fs.readFileSync(READ_ENTRY, 'utf8');

const all = parseTable(dispatcher, {
  openRe: 'function command_spec(command) {',
  closeRe: '\n    };\n',
  // The function name is empty for commands that dispatch on ARGV themselves,
  // and the last entry of the table carries no trailing comma.
  entryRe:
    '^[ ]{8}"?([a-z0-9_-]+)"?: \\[ "([^"]+)", "([^"]*)", ([0-9]+) \\],?$',
});

const readable = new Set(
  parseTable(readEntry, {
    openRe: 'let commands = {',
    closeRe: '\n};',
    entryRe:
      '^[ ]{4}"?([a-z0-9_-]+)"?: \\[ "([^"]+)", "([^"]*)", ([0-9]+) \\],?$',
  }).map((c) => c.name),
);

const CATEGORY_BY_MODULE_PREFIX = [
  ['service/lifecycle', 'system'],
  ['service/agent', 'ai'],
  ['service/agent_api', 'ai'],
  ['service/uninstall', 'system'],
  ['service/reset', 'system'],
  ['service/known_good', 'known_good'],
  ['service/stability', 'stability'],
  ['service/telegram', 'telegram'],
  ['service/watchdog', 'system'],
  ['components/updates', 'updates'],
  ['components/action', 'updates'],
  ['diagnostics/fuzzer', 'fuzzer'],
  ['diagnostics/dns', 'dns'],
  ['diagnostics/stability', 'stability'],
  ['diagnostics/runtime', 'diagnostics'],
  ['diagnostics/leak_check', 'diagnostics'],
  ['diagnostics/doctor', 'diagnostics'],
  ['config/connections', 'system'],
  ['singbox/', 'engine'],
  ['steer/', 'engine'],
  ['providers/', 'system'],
  ['config/', 'system'],
  ['subscription/', 'updates'],
  ['job/', 'jobs'],
  ['event/', 'events'],
  ['snapshot/', 'snapshots'],
  ['reconciler', 'reconciler'],
];

function categoryOf(module) {
  for (const [prefix, category] of CATEGORY_BY_MODULE_PREFIX) {
    if (module.startsWith(prefix)) return category;
  }
  return 'system';
}

// Params are positional in the CLI, and the contract has always described them
// by name. Arity is the only thing the dispatcher records, so the names are
// derived from the arity and the module is named by its own function where the
// generator cannot know better. This is honest: it does not invent semantics.
function paramsOf(entry) {
  if (entry.arity === 0) return [];
  return Array.from({ length: entry.arity }, (_, i) => ({
    name: `arg${i + 1}`,
    type: 'string',
    required: false,
    description: `positional argument ${i + 1} of ${entry.cli || entry.name}`,
  }));
}

const methods = all
  .map((entry) => ({
    name: entry.name,
    cli_command: entry.name,
    category: categoryOf(entry.module),
    acl: readable.has(entry.name) ? 'read' : 'write',
    description: `${entry.fn} (${entry.module})`,
    async: false,
    timeout_ms: readable.has(entry.name) ? 5000 : 60000,
    params: paramsOf(entry),
    returns: { type: 'object', description: 'command output' },
  }))
  .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

const contract = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  version: '2.0.0',
  title: 'Tachyon RPC Contract',
  description:
    'GENERATED by tools/generate_rpc_surface.js from the command table in ' +
    'tachyon/files/usr/bin/tachyon. Do not edit by hand: run ' +
    '`npm run contracts:generate` in fe-app-tachyon, or `node ' +
    'tools/generate_rpc_surface.js --check` to verify.',
  methods,
};

const contractText = `${JSON.stringify(contract, null, 2)}\n`;

/* ---- the enum block in types.ts ---- */

const ENUM_START = '  export enum AvailableMethods {';
const ENUM_END = '\n  }';

const types = fs.readFileSync(TYPES_PATH, 'utf8');
const start = types.indexOf(ENUM_START);
if (start < 0) throw new Error('AvailableMethods enum not found in types.ts');
const close = types.indexOf(ENUM_END, start);
if (close < 0) throw new Error('AvailableMethods enum has no closing brace');

// config-plan and config_plan are the same command behind two spellings, and
// both would want the key CONFIG_PLAN. Sort puts the dashed spelling first
// because "-" sorts below "_", so preferring the *first* claimant would silently
// repoint CONFIG_PLAN at 'config-plan' and change every caller's meaning. The
// underscore spelling is the one the frontend has always used, so it wins and
// the dashed alias is left out of the enum; it stays in the contract because the
// backend does accept it.
const enumKeyOf = (name) =>
  name.replace(/-/g, '_').replace(/([a-z0-9])([A-Z])/g, '$1_$2').toUpperCase();

const prefersUnderscore = (a, b) => (a.includes('-') ? 1 : 0) - (b.includes('-') ? 1 : 0);
const claimed = new Map();
const enumLines = [];
let aliasCount = 0;

for (const m of methods) {
  const key = enumKeyOf(m.name);

  if (!claimed.has(key)) {
    claimed.set(key, m.name);
    continue;
  }
  if (prefersUnderscore(m.name, claimed.get(key)) < 0) {
    aliasCount++;
    claimed.set(key, m.name);
  } else {
    aliasCount++;
  }
}

const grouped = new Map();
for (const [key, name] of claimed) {
  const m = methods.find((x) => x.name === name);
  const head = name.split(/[_-]/)[0];
  if (!grouped.has(head)) grouped.set(head, []);
  grouped.get(head).push({ key, name });
}

for (const [head, items] of [...grouped.entries()].sort()) {
  enumLines.push(`    // ${head}`);
  for (const it of items) {
    enumLines.push(`    ${it.key} = '${it.name}',`);
  }
}

const enumBlock = [
  ENUM_START,
  '    // GENERATED by tools/generate_rpc_surface.js from the command table in',
  '    // tachyon/files/usr/bin/tachyon. Do not add entries by hand.',
  ...enumLines,
  '  }',
].join('\n');

const nextTypes = types.slice(0, start) + enumBlock + types.slice(close + ENUM_END.length);

/* ---- write or verify ---- */

let stale = [];
if (CHECK_ONLY) {
  const currentContract = fs.readFileSync(CONTRACT_PATH, 'utf8');
  if (currentContract !== contractText) stale.push('contracts/tachyon-rpc.json');
  if (nextTypes !== types) stale.push('fe-app-tachyon/src/tachyon/types.ts');
  if (stale.length) {
    console.error(
      `stale: ${stale.join(', ')}\nrun: node tools/generate_rpc_surface.js`,
    );
    process.exit(1);
  }
  console.log(
    `surface is in sync: ${methods.length} commands, ${readable.size} readable`,
  );
} else {
  fs.writeFileSync(CONTRACT_PATH, contractText);
  fs.writeFileSync(TYPES_PATH, nextTypes);
  console.log(
    `wrote ${methods.length} commands (${readable.size} readable, ` +
      `${aliasCount} dashed aliases dropped from the enum) to ` +
      'contracts/tachyon-rpc.json and types.ts',
  );
}
