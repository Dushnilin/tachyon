#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_UC="$ROOT_DIR/tachyon/files/usr/lib/components/hosts.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TMP_DIR="$(mktemp -d)"
PASS=0
FAIL=0
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR"

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  PASS=$((PASS + 1))
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$actual" = "$expected" ]; then
    pass
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}

# --- Test 1: Parse hosts file with mixed formats ---
cat > "$TMP_DIR/test_hosts.txt" <<'EOF'
# This is a comment
127.0.0.1 localhost
localhost 127.0.0.1
45.155.204.190 chatgpt.com
45.155.204.190 ab.chatgpt.com
0.0.0.0 ad.doubleclick.net
0.0.0.0 tracker.example.com

# IPv6
::1 localhost
fe80::1 host.local
EOF

# --- Test 2: Parse file with only comments ---
cat > "$TMP_DIR/comments_only.txt" <<'EOF'
# Just comments
# Nothing else
EOF

# --- Test 3: Parse empty file ---
: > "$TMP_DIR/empty.txt"

# --- Test 4: Parse file with invalid lines ---
cat > "$TMP_DIR/invalid.txt" <<'EOF'
not a valid line
also not valid
45.155.204.190 chatgpt.com
valid.com 1.2.3.4
EOF

# Run the hosts list status command (should not fail with no URLs)
echo "=== Test: hosts_list_status with no URLs ==="
output=$(ucode "$HOSTS_UC" list-status 2>/dev/null || true)
assert_eq "false" "$(echo "$output" | grep -o '"cache_exists":[a-z]*' | cut -d: -f2)" "cache_exists should be false initially"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
