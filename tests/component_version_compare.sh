#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VERSIONS="$ROOT_DIR/tachyon/files/usr/lib/components/versions.uc"

ucode() {
  local has_L=0
  for arg in "$@"; do
    if [ "$arg" = "-L" ]; then
      has_L=1
      break
    fi
  done
  if [ "$has_L" -eq 1 ]; then
    command ucode "$@"
  else
    command ucode -L "$TACHYON_LIB" "$@"
  fi
}

assert_cmp() {
  local lhs="$1"
  local rhs="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(ucode -e "let v = require('components.versions'); print(v.compare_versions('$lhs', '$rhs'));")"
  [ "$actual" = "$expected" ] || fail "$label: compare_versions('$lhs', '$rhs') expected '$expected', got '$actual'"
}

# 1. Package revision compatibility (e.g. wdtt / qwdtt APK -r1 vs release asset -1)
assert_cmp "1.0.3-r1" "1.0.3-1" "0" "APK revision -r1 matches release -1"
assert_cmp "1.0.3-1" "1.0.3-r1" "0" "Release -1 matches APK revision -r1"
assert_cmp "1.0.3" "1.0.3-1" "0" "Unrevisioned base matches release revision 1"
assert_cmp "1.0.3" "1.0.3-r1" "0" "Unrevisioned base matches APK revision 1"
assert_cmp "1.0.3-1" "1.0.3" "0" "Release revision 1 matches unrevisioned base"
assert_cmp "1.0.3-r1" "1.0.3" "0" "APK revision 1 matches unrevisioned base"

# 2. Package revision updates
assert_cmp "1.0.3-r1" "1.0.3-r2" "-1" "APK revision 1 is outdated when revision 2 is released"
assert_cmp "1.0.3-r2" "1.0.3-r1" "1" "APK revision 2 is newer than revision 1"
assert_cmp "1.0.3-1" "1.0.3-2" "-1" "Package revision 1 is outdated when revision 2 is released"
assert_cmp "1.0.3-2" "1.0.3-1" "1" "Package revision 2 is newer than revision 1"
assert_cmp "1.0.3-r1" "1.0.3-2" "-1" "APK revision -r1 is outdated when release has revision 2"
assert_cmp "1.0.3-r2" "1.0.3-1" "1" "APK revision -r2 is newer than release revision 1"

# 3. Base semver differences
assert_cmp "1.0.3-r1" "1.0.4-1" "-1" "1.0.3-r1 is outdated compared to 1.0.4-1"
assert_cmp "1.0.4-r1" "1.0.3-1" "1" "1.0.4-r1 is newer than 1.0.3-1"
assert_cmp "1.0.3" "1.0.4" "-1" "1.0.3 is outdated compared to 1.0.4"
assert_cmp "1.0.4" "1.0.3" "1" "1.0.4 is newer than 1.0.3"

# 4. v prefix stripping
assert_cmp "v1.0.3-r1" "1.0.3-1" "0" "Prefixed v1.0.3-r1 matches 1.0.3-1"
assert_cmp "1.0.3-r1" "v1.0.3-1" "0" "1.0.3-r1 matches prefixed v1.0.3-1"

printf 'component version compare tests passed\n'
