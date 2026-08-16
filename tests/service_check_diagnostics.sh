#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
SERVICE_CHECK_UC="$TACHYON_LIB/diagnostics/service_check.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Test get-targets
targets_json="$(ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" get-targets)"
[ -n "$targets_json" ] || fail "service_check get-targets returned empty output"

# 2. Test get-targets with all mode
targets_all_json="$(ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" get-targets all)"
[ -n "$targets_all_json" ] || fail "service_check get-targets all returned empty output"

# 3. Test check-custom parses and returns structured result
check_json="$(ucode -L "$TACHYON_LIB" "$SERVICE_CHECK_UC" check-custom 127.0.0.1 2>/dev/null || true)"
[ -n "$check_json" ] || fail "service_check check-custom returned empty output"

printf 'service check diagnostics passed\n'
