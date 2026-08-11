#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Verify runtime.uc owns local_rule_doctor
grep -Fq 'function local_rule_doctor()' "$TACHYON_LIB/diagnostics/runtime.uc" ||
  fail "runtime.uc must define local_rule_doctor heuristic engine"

# 2. Run ai-doctor without API key (local offline mode)
output="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/runtime.uc" ai-doctor 2>/dev/null || true)"

echo "$output" | grep -Fq '"success": true' ||
  fail "ai-doctor in offline mode must return success: true"

echo "$output" | grep -Fq '"provider": "local_heuristic"' ||
  fail "ai-doctor in offline mode must report provider local_heuristic"

# 3. Test apply-quick-fix for new codes
fix_out="$(ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/runtime.uc" apply-quick-fix "restart_zapret,optimize_memory" 2>/dev/null || true)"

echo "$fix_out" | grep -Fq '"code": "restart_zapret"' ||
  fail "apply_quick_fix must handle restart_zapret"

echo "$fix_out" | grep -Fq '"code": "optimize_memory"' ||
  fail "apply_quick_fix must handle optimize_memory"

printf 'local AI Doctor checks passed\n'
