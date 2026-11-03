#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

WGET_WRAPPER="$TACHYON_LIB/bin/wget"
INSTALLER_UC="$TACHYON_LIB/components/installer.uc"

[ -x "$WGET_WRAPPER" ] || fail "wget wrapper $WGET_WRAPPER is missing or not executable"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected to find '$needle' in '$haystack'" ;;
  esac
}

# 1. Test wget wrapper delegating to fake curl
FAKE_BIN_DIR="$WORK_DIR/fake-bin"
mkdir -p "$FAKE_BIN_DIR"
CURL_LOG="$WORK_DIR/curl.log"

cat << EOF > "$FAKE_BIN_DIR/curl"
#!/bin/sh
echo "CURL CALLED: \$@" >> "$CURL_LOG"
for arg in "\$@"; do
  if [ "\$prev" = "-o" ]; then
    printf 'mock-content' > "\$arg"
    exit 0
  fi
  prev="\$arg"
done
printf 'mock-stdout-content'
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/curl"

# Test 1.1: stdout mode (-O -)
OUT_STDOUT=$(PATH="$FAKE_BIN_DIR:$PATH" "$WGET_WRAPPER" -q -T 30 "https://example.com/test.apk" -O -)
[ "$OUT_STDOUT" = "mock-stdout-content" ] || fail "wget wrapper failed stdout mode: got '$OUT_STDOUT'"
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$LAST_CURL" "-m 30" "curl timeout argument"
assert_contains "$LAST_CURL" "https://example.com/test.apk" "curl url argument"

# Test 1.2: file output mode (-O /path/to/file)
OUT_FILE="$WORK_DIR/test_download.apk"
PATH="$FAKE_BIN_DIR:$PATH" "$WGET_WRAPPER" -q -T 45 --no-check-certificate "https://example.com/test2.apk" -O "$OUT_FILE"
[ -f "$OUT_FILE" ] || fail "wget wrapper did not create output file"
[ "$(cat "$OUT_FILE")" = "mock-content" ] || fail "wget wrapper file content mismatch"
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$LAST_CURL" "-k" "curl insecure flag"
assert_contains "$LAST_CURL" "-m 45" "curl timeout argument"

# Test 1.3: directory output mode (-P /dir)
OUT_DIR="$WORK_DIR/dest_dir"
mkdir -p "$OUT_DIR"
PATH="$FAKE_BIN_DIR:$PATH" "$WGET_WRAPPER" -q -P "$OUT_DIR" "https://example.com/sub/package.ipk"
[ -f "$OUT_DIR/package.ipk" ] || fail "wget wrapper did not create file in dest_dir"

# 2. Test installer command builders when ucode is available
if command -v ucode >/dev/null 2>&1; then
  # Test 2.1: pkg_install_name_command with proxy includes PATH and fallback
  CMD_WITH_PROXY=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    print(inst.pkg_install_name_command("tailscale", "127.0.0.1:4535"), "\n");
  ')
  assert_contains "$CMD_WITH_PROXY" "http_proxy='http://127.0.0.1:4535'" "http_proxy variable"
  assert_contains "$CMD_WITH_PROXY" "https_proxy='http://127.0.0.1:4535'" "https_proxy variable"
  assert_contains "$CMD_WITH_PROXY" "PATH=" "PATH variable override"
  assert_contains "$CMD_WITH_PROXY" "$TACHYON_LIB/bin" "TACHYON_LIB/bin in PATH"
  assert_contains "$CMD_WITH_PROXY" " || " "fallback on failure"

  # Test 2.2: pkg_install_name_command without proxy has no proxy env and no PATH override
  CMD_NO_PROXY=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    print(inst.pkg_install_name_command("tailscale", ""), "\n");
  ')
  case "$CMD_NO_PROXY" in
    *http_proxy*) fail "unexpected http_proxy in direct command: $CMD_NO_PROXY" ;;
    *https_proxy*) fail "unexpected https_proxy in direct command: $CMD_NO_PROXY" ;;
  esac

  # Test 2.3: pkg_list_update_command with proxy includes PATH and fallback
  UPDATE_WITH_PROXY=$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
    let inst = require("components.installer");
    print(inst.pkg_list_update_command("127.0.0.1:4535"), "\n");
  ')
  assert_contains "$UPDATE_WITH_PROXY" "http_proxy='http://127.0.0.1:4535'" "update http_proxy"
  assert_contains "$UPDATE_WITH_PROXY" "$TACHYON_LIB/bin" "update PATH override"
  assert_contains "$UPDATE_WITH_PROXY" " || " "update fallback"
fi

printf 'All pkg_proxy_wget_wrapper tests passed\n'
