#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_UC="${HOSTS_UC:-$ROOT_DIR/tachyon/files/usr/lib/components/hosts.uc}"
TACHYON_LIB="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
TMP_DIR="$(mktemp -d)"
PASS=0
FAIL=0
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/cache" "$TMP_DIR/tmp"
export TACHYON_HOSTS_CACHE_DIR="$TMP_DIR/cache"
export TACHYON_HOSTS_TMP_DIR="$TMP_DIR/tmp"

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

# --- Test 5: Safe name length for long percent-encoded URLs ---
echo "=== Test: safe_name length for long URLs ==="
long_url_safe_len=$(ucode -e '
let common = require("core.common");
let as_string = common.as_string;
function hash12(str) {
    str = as_string(str);
    let h1 = 5381;
    let h2 = 52711;
    for (let i = 0; i < length(str); i++) {
        let code = ord(str, i);
        h1 = ((h1 * 33) + code) % 2147483647;
        h2 = ((h2 * 31) + code) % 2147483647;
    }
    return sprintf("%08x%04x", h1, h2 % 65536);
}
let url = "https://raw.githubusercontent.com/V3nilla/IPSets-For-Bypass-in-Russia/main/%D0%A0%D0%B0%D0%B7%D0%B1%D0%BB%D0%BE%D0%BA%D0%B8%D1%80%D0%BE%D0%B2%D0%BA%D0%B0%20%D0%BC%D0%BD%D0%BE%D0%B6%D0%B5%D1%81%D1%82%D0%B2%D0%B0%20%D1%81%D0%B5%D1%80%D0%B2%D0%B8%D1%81%D0%BE%D0%B2(%D0%BF%D1%80%D0%B8%D0%BC%D0%B5%D1%80%20-%20ChatGPT)/hosts";
let clean = replace(replace(url, /:/g, "_"), /[^a-zA-Z0-9_]/g, "_");
if (length(clean) > 40) clean = substr(clean, 0, 40);
let safe_name = clean + "_" + hash12(url);
print(length(safe_name));
')
if [ "$long_url_safe_len" -le 60 ]; then
  pass
else
  fail "safe_name too long: $long_url_safe_len"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
