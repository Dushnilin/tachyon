#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

CACHE_UC="$ROOT_DIR/tachyon/files/usr/lib/subscription/cache.uc"
CONNECTIONS_UC="$ROOT_DIR/tachyon/files/usr/lib/config/connections.uc"

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  grep -Fq -- "$expected" "$file" || fail "$label: expected '$expected' in '$file'"
}

assert_not_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  if grep -Fq -- "$expected" "$file"; then
    fail "$label: unexpected '$expected' in '$file'"
  fi
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$WORK_DIR/curl.log"
target=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o)
      target="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [ -n "\$target" ]; then
  printf '%s\n' "dummy subscription data" > "\$target"
fi
exit 0
SH
chmod +x "$WORK_DIR/bin/curl"

export PATH="$WORK_DIR/bin:$PATH"

cache_ucode() {
  ucode -L "$TACHYON_LIB" "$CACHE_UC" "$@"
}

# Test 1: cache.download_subscription with allow_insecure = 1
: >"$WORK_DIR/curl.log"
cache_ucode download-subscription "https://example.com/sub" "$WORK_DIR/sub.txt" "" "" "" "" 1
assert_contains "$WORK_DIR/curl.log" "-k" "download_subscription with allow_insecure=1 must pass -k to curl"

# Test 2: cache.download_subscription with allow_insecure = 0
: >"$WORK_DIR/curl.log"
cache_ucode download-subscription "https://example.com/sub" "$WORK_DIR/sub.txt" "" "" "" "" 0
assert_not_contains "$WORK_DIR/curl.log" "-k" "download_subscription with allow_insecure=0 must not pass -k to curl"

# Test 3: connections.uc subscription_insecure helper contract
ucode -L "$TACHYON_LIB" -e '
let conn = require("config.connections");
let sec1 = { "subscription_insecure": "1" };
let sec0 = { "subscription_insecure": "0" };
let sec_unset = {};
if (conn.subscription_insecure(sec1) !== "1") exit(1);
if (conn.subscription_insecure(sec0) !== "0") exit(2);
if (conn.subscription_insecure(sec_unset) !== "0") exit(3);
' || fail "connections.subscription_insecure getter contract"

printf 'subscription insecure checks passed\n'
