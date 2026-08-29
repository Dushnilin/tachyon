#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
FUZZER="$ROOT_DIR/tachyon/files/usr/lib/diagnostics/fuzzer.uc"
BYEDPI_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/byedpi/validator.uc"
ZAPRET_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret/validator.uc"
ZAPRET2_VALIDATOR="$ROOT_DIR/tachyon/files/usr/lib/providers/zapret2/validator.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Check strategies JSON output
strategies_json="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies)"
[ -n "$strategies_json" ] || fail "fuzzer strategies returned empty output"

# Validate JSON structure using node
JSON_VALUE="$strategies_json" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (typeof val.available_engines !== 'object') {
  console.error("Missing available_engines");
  process.exit(1);
}
if (!Array.isArray(val.zapret2) || val.zapret2.length === 0) {
  console.error("Missing zapret2 strategies");
  process.exit(1);
}
if (!Array.isArray(val.zapret) || val.zapret.length === 0) {
  console.error("Missing zapret strategies");
  process.exit(1);
}
if (!Array.isArray(val.byedpi) || val.byedpi.length === 0) {
  console.error("Missing byedpi strategies");
  process.exit(1);
}
NODE

# 2. Check each strategy passes its respective engine validator
byedpi_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.byedpi) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  check="$(ucode -L "$TACHYON_LIB" -- "$BYEDPI_VALIDATOR" validate-json "$args")"
  JSON_VALUE="$check" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("ByeDPI strategy invalid:", val);
  process.exit(1);
}
NODE
done <<< "$byedpi_args"

zapret_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.zapret) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  check="$(ucode -L "$TACHYON_LIB" -- "$ZAPRET_VALIDATOR" validate-json nfqws "$args")"
  JSON_VALUE="$check" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("Zapret strategy invalid:", val);
  process.exit(1);
}
NODE
done <<< "$zapret_args"

zapret2_args="$(JSON_VALUE="$strategies_json" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
for (const s of val.zapret2) {
  console.log(s.args);
}
NODE
)"

while IFS= read -r args; do
  [ -n "$args" ] || continue
  check="$(ucode -L "$TACHYON_LIB" -- "$ZAPRET2_VALIDATOR" validate-json nfqws2 "$args")"
  JSON_VALUE="$check" node - <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (!val.valid) {
  console.error("Zapret2 strategy invalid:", val);
  process.exit(1);
}
NODE
done <<< "$zapret2_args"

# 3. Check status returns clean default state
status_json="$(ucode -L "$TACHYON_LIB" -- "$FUZZER" status)"
JSON_VALUE="$status_json" node <<'NODE'
const val = JSON.parse(process.env.JSON_VALUE);
if (val.running !== false) {
  console.error("Default fuzzer status should have running: false");
  process.exit(1);
}
if (!Array.isArray(val.results)) {
  console.error("Results should be an array");
  process.exit(1);
}
NODE

# 4. Check tachyon CLI command map contains fuzzer commands
grep -q 'fuzzer_start:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_start"
grep -q 'fuzzer_status:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_status"
grep -q 'fuzzer_stop:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_stop"
grep -q 'fuzzer_apply:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_apply"
grep -q 'fuzzer_strategies:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_strategies"
grep -q 'fuzzer_generate:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_generate"
grep -q 'fuzzer_ai_synthesize:' "$TACHYON_BIN" || fail "tachyon CLI missing fuzzer_ai_synthesize"

# 5. Check combinatorial strategies generation
combo_tmp="$(mktemp "${TMPDIR:-/tmp}/fuzzer_combo_XXXXXX")"
trap 'rm -f "$combo_tmp"' EXIT
ucode -L "$TACHYON_LIB" -- "$FUZZER" strategies combinatorial > "$combo_tmp"
COMBO_FILE="$combo_tmp" node <<'NODE'
const fs = require('fs');
const raw = fs.readFileSync(process.env.COMBO_FILE, 'utf8');
const val = JSON.parse(raw);
if (!Array.isArray(val.zapret2) || val.zapret2.length < 30) {
  console.error("Combinatorial zapret2 should have >= 30 strategies, got:", val.zapret2 ? val.zapret2.length : 0);
  process.exit(1);
}
if (!Array.isArray(val.zapret) || val.zapret.length < 20) {
  console.error("Combinatorial zapret should have >= 20 strategies, got:", val.zapret ? val.zapret.length : 0);
  process.exit(1);
}
if (!Array.isArray(val.byedpi) || val.byedpi.length < 20) {
  console.error("Combinatorial byedpi should have >= 20 strategies, got:", val.byedpi ? val.byedpi.length : 0);
  process.exit(1);
}
console.log("Generated matrix: Zapret2=" + val.zapret2.length + ", Zapret=" + val.zapret.length + ", ByeDPI=" + val.byedpi.length);
NODE

printf 'PASS: fuzzer_strategy_cli\n'
