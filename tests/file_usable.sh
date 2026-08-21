#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_UC="$ROOT_DIR/tachyon/files/usr/lib/core/helpers.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR"

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# --- file-is-usable CLI tests ---
# Nonexistent file
assert 1 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/nonexistent.srs" 100 2>/dev/null; echo $?)" "nonexistent file not usable"

# Empty file
touch "$TMP_DIR/empty.srs"
assert 1 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/empty.srs" 100 2>/dev/null; echo $?)" "empty file not usable"

# 1-byte file
printf x > "$TMP_DIR/1byte.srs"
assert 1 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/1byte.srs" 100 2>/dev/null; echo $?)" "1-byte file not usable at min 100"

# 49-byte file
dd if=/dev/urandom of="$TMP_DIR/49byte.srs" bs=1 count=49 2>/dev/null
assert 1 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/49byte.srs" 50 2>/dev/null; echo $?)" "49-byte file not usable at min 50"
assert 0 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/49byte.srs" 0 2>/dev/null; echo $?)" "49-byte file usable at min 0"

# 50-byte file
dd if=/dev/urandom of="$TMP_DIR/50byte.srs" bs=1 count=50 2>/dev/null
assert 0 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/50byte.srs" 50 2>/dev/null; echo $?)" "50-byte file usable at min 50"

# 100-byte file
dd if=/dev/urandom of="$TMP_DIR/100byte.srs" bs=1 count=100 2>/dev/null
assert 0 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/100byte.srs" 100 2>/dev/null; echo $?)" "100-byte file usable at min 100"
assert 1 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/100byte.srs" 200 2>/dev/null; echo $?)" "100-byte file not usable at min 200"

# No min_bytes = always usable if exists
assert 0 "$(ucode "$HELPERS_UC" file-is-usable "$TMP_DIR/1byte.srs" 2>/dev/null; echo $?)" "1-byte file usable with no min"

# --- file-size CLI tests ---
assert "-1" "$(ucode "$HELPERS_UC" file-size "$TMP_DIR/nonexistent.srs" 2>/dev/null)" "nonexistent file size is -1"
assert "0" "$(ucode "$HELPERS_UC" file-size "$TMP_DIR/empty.srs" 2>/dev/null)" "empty file size is 0"
assert "49" "$(ucode "$HELPERS_UC" file-size "$TMP_DIR/49byte.srs" 2>/dev/null)" "49-byte file size is 49"
assert "100" "$(ucode "$HELPERS_UC" file-size "$TMP_DIR/100byte.srs" 2>/dev/null)" "100-byte file size is 100"

# Clean up
rm -rf "$TMP_DIR"

printf 'file_usable checks passed\n'
