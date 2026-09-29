#!/usr/bin/env bash
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

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
  for cmd in get_status get_sing_box_status get_engine_status get_ui_capabilities get_ui_state \
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

printf '=== ALL RPC CONTRACT TESTS PASSED ===\n'
