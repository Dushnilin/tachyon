#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Tests for contracts/tachyon-rpc.json and tools/generate_rpc_contract.js
# Can run locally or inside router/container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTRACT_FILE="$ROOT_DIR/contracts/tachyon-rpc.json"
GENERATOR_SCRIPT="$ROOT_DIR/tools/generate_rpc_contract.js"
GENERATED_TS="$ROOT_DIR/fe-app-tachyon/src/contracts/generated/rpcContract.ts"

if [ -f "$ROOT_DIR/tachyon/files/usr/bin/tachyon" ]; then
  TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
else
  TACHYON_BIN="/usr/bin/tachyon"
fi

assert() {
  local cond="$1"
  local label="$2"
  eval "$cond" || fail "Assertion failed: $label"
}

printf '=== Testing Tachyon RPC Contract & Generator ===\n'

# 1. Contract JSON exists and is valid
assert "[ -f '$CONTRACT_FILE' ]" "contracts/tachyon-rpc.json exists"

if command -v node >/dev/null 2>&1; then
  node -e "
    const fs = require('fs');
    const file = process.argv[1];
    const c = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!c.version || !Array.isArray(c.methods)) process.exit(1);
    if (c.methods.length < 40) process.exit(2);
  " "$CONTRACT_FILE" || fail "Contract JSON failed node validation or has fewer than 40 methods"
elif command -v ucode >/dev/null 2>&1; then
  ucode -e "
    let fs = require('fs');
    let raw = fs.readfile('$CONTRACT_FILE');
    let c = json(raw);
    if (!c || !c.version || length(c.methods) < 40) exit(1);
  " || fail "Contract JSON failed ucode validation"
fi
printf 'PASS: Contract JSON parsed and validated\n'

# 2. Generator script runs and outputs valid TypeScript
if command -v node >/dev/null 2>&1; then
  # The generator overwrites the committed file with its raw output, and what is
  # committed is that output after prettier. Restoring it afterwards keeps the
  # test from leaving a formatting-only diff behind on every run, which is noise
  # that hides real changes to the generated contract.
  GENERATED_BACKUP=""
  [ -f "$GENERATED_TS" ] && GENERATED_BACKUP="$(mktemp)"
  [ -n "$GENERATED_BACKUP" ] && cp "$GENERATED_TS" "$GENERATED_BACKUP"
  restore_generated() {
    if [ -n "$GENERATED_BACKUP" ] && [ -f "$GENERATED_BACKUP" ]; then
      cp "$GENERATED_BACKUP" "$GENERATED_TS"
      rm -f "$GENERATED_BACKUP"
    fi
  }
  trap restore_generated EXIT HUP INT TERM

  node "$GENERATOR_SCRIPT" || fail "tools/generate_rpc_contract.js failed"
  assert "[ -f '$GENERATED_TS' ]" "Generated TypeScript file exists"
  assert "[ -s '$GENERATED_TS' ]" "Generated TypeScript file is non-empty"

  # Verify generated exports
  grep -q "export const TACHYON_RPC_METHODS" "$GENERATED_TS" || fail "Missing TACHYON_RPC_METHODS in generated TS"
  grep -q "export const RPC_METADATA_MAP" "$GENERATED_TS" || fail "Missing RPC_METADATA_MAP in generated TS"
  grep -q "export function validateRpcParams" "$GENERATED_TS" || fail "Missing validateRpcParams in generated TS"
  grep -q "export function serializeRpcCliArgs" "$GENERATED_TS" || fail "Missing serializeRpcCliArgs in generated TS"
  printf 'PASS: Generator produced valid TypeScript contract\n'
fi

# 3. Verify CLI commands registered in tachyon binary
if [ -f "$TACHYON_BIN" ]; then
  # Extract commands from contract and verify they are present in command_spec
  MISSING=0
  for cmd in get_status get_tachyon_core_status get_engine_status get_ui_capabilities get_ui_state \
             job_list job_query job_cancel job_request_cancel job_gc \
             event_query event_tail event_stats event_clear event_record \
             known_good known_good_promote known_good_restore route_explain; do
    if ! grep -q "$cmd" "$TACHYON_BIN"; then
      printf 'WARN: command %s not found in %s\n' "$cmd" "$TACHYON_BIN" >&2
      MISSING=$((MISSING + 1))
    fi
  done
  [ "$MISSING" -eq 0 ] || fail "Missing CLI command mappings in tachyon binary"
  printf 'PASS: All core contract CLI commands are mapped in tachyon binary\n'
fi

# 4. Cleanup contract: removed external providers must stay absent across contract, catalog, and modules
# while core components & native transports remain supported.
CONTRACT_FILE="$CONTRACT_FILE" ROOT_DIR="$ROOT_DIR" node <<'NODE'
const fs = require('fs');
const path = require('path');

const contract = JSON.parse(fs.readFileSync(process.env.CONTRACT_FILE, 'utf8'));
const names = new Set(contract.methods.map((m) => m.name));

const forbiddenMethods = [
  'check_byedpi_runtime',
  'check_zapret_runtime',
  'check_zapret2_runtime',
  'get_byedpi_status',
  'get_olcrtc_status',
  'get_tailscale_peers',
  'get_tailscale_status',
  'get_wdtt_status',
  'get_zapret_status',
  'get_zapret2_status',
  'neutralize_zapret_defaults',
  'tailscale_restart',
  'validate_byedpi_strategy_json',
  'validate_nfqws_strategy_json',
  'validate_nfqws2_strategy_json',
];
for (const method of forbiddenMethods) {
  if (names.has(method)) {
    console.error(`Removed external provider RPC method still present in contract: ${method}`);
    process.exit(1);
  }
}

const root = process.env.ROOT_DIR;
const catalogText = fs.readFileSync(path.join(root, 'tachyon/files/usr/lib/components/catalog.uc'), 'utf8');
for (const removedResolver of [
  'resolve_zapret_release',
  'resolve_zapret2_release',
  'resolve_byedpi_release',
  'resolve_wdtt_release',
  'resolve_olcrtc_release',
]) {
  if (catalogText.includes(removedResolver)) {
    console.error(`Removed release resolver still present in catalog.uc: ${removedResolver}`);
    process.exit(1);
  }
}
for (const keptResolver of ['resolve_tachyon_release', 'resolve_torrserver_release']) {
  if (!catalogText.includes(keptResolver)) {
    console.error(`Required resolver missing from catalog.uc: ${keptResolver}`);
    process.exit(1);
  }
}

const removedProviderDirs = [
  'providers/byedpi',
  'providers/zapret',
  'providers/zapret2',
  'providers/nfqueue',
  'providers/olcrtc',
  'providers/wdtt',
  'providers/tailscale',
];
for (const rel of removedProviderDirs) {
  if (fs.existsSync(path.join(root, 'tachyon/files/usr/lib', rel))) {
    console.error(`Removed provider directory still exists: ${rel}`);
    process.exit(1);
  }
}

const validatorText = fs.readFileSync(path.join(root, 'tachyon/files/usr/lib/config/validator.uc'), 'utf8');
for (const keptAction of ['desync', 'csqtt', 'tailscale', 'fptn', 'hosts']) {
  if (!validatorText.includes(`"${keptAction}"`)) {
    console.error(`Kept action/feature missing from validator.uc: ${keptAction}`);
    process.exit(1);
  }
}

const installText = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
const uninstallText = fs.readFileSync(path.join(root, 'uninstall.sh'), 'utf8');
if (!installText.includes('tachyon-core')) {
  console.error('install.sh must reference tachyon-core');
  process.exit(1);
}
if (/pkg_install.*\b(zapret|zapret2|byedpi|olcrtc|qwdtt|tailscale)\b/.test(installText)) {
  console.error('install.sh must not install removed external provider packages');
  process.exit(1);
}
if (!uninstallText.includes('/etc/init.d/zapret') || !uninstallText.includes('/etc/init.d/olcrtc')) {
  console.error('uninstall.sh must keep legacy provider cleanup');
  process.exit(1);
}
NODE

printf '=== ALL RPC CONTRACT TESTS PASSED ===\n'
