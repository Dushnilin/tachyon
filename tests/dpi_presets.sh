#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PRESETS="$ROOT_DIR/tachyon/files/usr/share/tachyon/dpi-presets.json"

[ -f "$PRESETS" ] || fail "dpi-presets.json is missing"

# 1. Structural validation (no ucode required)
PRESETS="$PRESETS" node <<'NODE'
const fs = require('fs');
const path = process.env.PRESETS;
let data;
try {
  data = JSON.parse(fs.readFileSync(path, 'utf8'));
} catch (e) {
  console.error('invalid JSON: ' + e.message);
  process.exit(1);
}

const engines = ['zapret2', 'zapret', 'byedpi'];
const ids = new Map();
let total = 0;

for (const eng of engines) {
  if (!Array.isArray(data[eng])) {
    console.error(`missing or invalid engine array: ${eng}`);
    process.exit(1);
  }
  for (const p of data[eng]) {
    total++;
    if (!p.id || typeof p.id !== 'string') {
      console.error(`entry without id in ${eng}`);
      process.exit(1);
    }
    if (ids.has(p.id)) {
      console.error(`duplicate id: ${p.id}`);
      process.exit(1);
    }
    ids.set(p.id, eng);
    if (!p.args || typeof p.args !== 'string' || !p.args.trim()) {
      console.error(`entry ${p.id} has empty args`);
      process.exit(1);
    }
    if (!p.name) {
      console.error(`entry ${p.id} has no name`);
      process.exit(1);
    }
    if (p.tags && !Array.isArray(p.tags)) {
      console.error(`entry ${p.id} tags must be an array`);
      process.exit(1);
    }
    if (p.source && typeof p.source !== 'string') {
      console.error(`entry ${p.id} source must be a string`);
      process.exit(1);
    }
  }
}

if (total === 0) {
  console.error('no presets found');
  process.exit(1);
}
console.log(`structure ok: ${total} presets`);
NODE

# 2. Backend integration test (requires ucode)
if ! command -v ucode >/dev/null 2>&1; then
  printf 'ucode not found; skipping runtime preset checks\n'
  printf 'DPI presets checks passed (structural only)\n'
  exit 0
fi

cat >"$WORK_DIR/presets-load.uc" <<'UCODE'
let fs = require("fs");
let common = require("core.common");
let path = getenv("PRESETS_PATH");
if (!path || fs.stat(path) == null)
    exit(2);
let data = common.read_json_file(path);
if (type(data) != "object")
    exit(3);
let fuzzer = require("diagnostics.fuzzer");
exit(0);
UCODE

PRESETS_PATH="$PRESETS" TACHYON_PRESETS_FILE="$PRESETS" TACHYON_LIB="$TACHYON_LIB" \
  ucode -L "$TACHYON_LIB" "$WORK_DIR/presets-load.uc" ||
  fail "fuzzer module failed to load with presets"

printf 'DPI presets checks passed\n'
