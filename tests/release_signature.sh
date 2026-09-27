#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
USIGN_EMU="$ROOT_DIR/tests/lib/usign_emu.js"
PUBKEY_FILE="$ROOT_DIR/tachyon/files/etc/tachyon/keys/tachyon-release.pub"

test_fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) test_fail "$label: expected to contain '$needle', got: $haystack" ;;
  esac
}

# 1. Check release public key packaging
[ -r "$PUBKEY_FILE" ] || test_fail "Release public key $PUBKEY_FILE is missing"
pubkey_content="$(cat "$PUBKEY_FILE")"
assert_contains "$pubkey_content" "untrusted comment: tachyon release public key" "pubkey header"
assert_contains "$pubkey_content" "RWSvrejmGGwvTwKe3zHe+DIiACxF8D3nUgR4xxcrxuQyIP6qafE52cdL" "pubkey payload"

# 2. Check build.sh packaging logic copies the key
grep -Fq 'tachyon/files/etc/tachyon/keys' "$ROOT_DIR/build.sh" || test_fail "build.sh must package etc/tachyon/keys"
grep -Fq 'sign_release_manifest' "$ROOT_DIR/build.sh" || test_fail "build.sh must contain sign_release_manifest"
grep -Fq 'sha256sums.txt.minisig' "$ROOT_DIR/build.sh" || test_fail "build.sh must reference sha256sums.txt.minisig"

# 3. Check installer contract
[ -r "$INSTALLER" ] || test_fail "install.sh is missing"
sh -n "$INSTALLER" || test_fail "install.sh must pass POSIX sh syntax"

grep -Fq 'sha256sums.txt.minisig' "$INSTALLER" || test_fail "install.sh must reference sha256sums.txt.minisig"
grep -Fq 'verify_release_signature' "$INSTALLER" || test_fail "install.sh must implement verify_release_signature"
grep -Fq 'get_release_pubkey_file' "$INSTALLER" || test_fail "install.sh must implement get_release_pubkey_file"
grep -Fq 'verify_package_metadata' "$INSTALLER" || test_fail "install.sh must verify package payload metadata"

# 4. Functional tests in a sandbox directory
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export TACHYON_INSTALLER_TEST=1
# shellcheck source=/dev/null
. "$INSTALLER"

TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"
LOG_FILE="$WORK_DIR/test.log"
: >"$LOG_FILE"

# Determine usign or usign_emu runner
if command -v usign >/dev/null 2>&1; then
  USIGN_CMD="usign"
elif command -v node >/dev/null 2>&1 && [ -f "$USIGN_EMU" ]; then
  USIGN_CMD="node $USIGN_EMU"
else
  test_fail "Neither usign nor node $USIGN_EMU is available for signing tests"
fi

# Generate test Ed25519 keypair
TEST_PUB="$WORK_DIR/test.pub"
TEST_SEC="$WORK_DIR/test.sec"
# shellcheck disable=SC2086
$USIGN_CMD -G -p "$TEST_PUB" -s "$TEST_SEC"
[ -f "$TEST_PUB" ] || test_fail "Failed to generate test public key"
[ -f "$TEST_SEC" ] || test_fail "Failed to generate test secret key"

# Prepare dummy payload files
echo "backend payload v1.5.0" > "$WORK_DIR/tachyon_1.5.0.apk"
echo "luci app payload v1.5.0" > "$WORK_DIR/luci-app-tachyon_1.5.0.apk"

# Generate sha256sums.txt
MANIFEST="$WORK_DIR/sha256sums.txt"
(
  cd "$WORK_DIR"
  sha256sum "tachyon_1.5.0.apk" "luci-app-tachyon_1.5.0.apk" > "$MANIFEST"
)

# Sign sha256sums.txt to produce sha256sums.txt.minisig
SIGFILE="$WORK_DIR/sha256sums.txt.minisig"
# shellcheck disable=SC2086
$USIGN_CMD -S -s "$TEST_SEC" -m "$MANIFEST" -x "$SIGFILE"
[ -f "$SIGFILE" ] || test_fail "Failed to generate signature"

# Test 4.1: verify_release_signature succeeds with valid signature
RELEASE_PUBKEY_OVERRIDE="$TEST_PUB"
if ! verify_release_signature "$MANIFEST" "$SIGFILE" >/dev/null 2>&1; then
  test_fail "verify_release_signature failed on valid signature"
fi

# Test 4.2: verify_release_signature fails on tampered manifest
TAMPERED_MANIFEST="$WORK_DIR/tampered_sha256sums.txt"
cp "$MANIFEST" "$TAMPERED_MANIFEST"
echo "deadbeef  extra_file" >> "$TAMPERED_MANIFEST"
if verify_release_signature "$TAMPERED_MANIFEST" "$SIGFILE" >/dev/null 2>&1; then
  test_fail "verify_release_signature unexpectedly succeeded on tampered manifest"
fi

# Test 4.3: verify_release_signature fails on tampered signature
TAMPERED_SIG="$WORK_DIR/tampered.minisig"
line1="$(sed -n '1p' "$SIGFILE")"
line2="$(sed -n '2p' "$SIGFILE")"
tampered_line2="$(printf '%s' "$line2" | sed 's/.\{10\}$/AAAAAAAAAA=/')"
printf '%s\n%s\n' "$line1" "$tampered_line2" > "$TAMPERED_SIG"
if verify_release_signature "$MANIFEST" "$TAMPERED_SIG" >/dev/null 2>&1; then
  test_fail "verify_release_signature unexpectedly succeeded on tampered signature"
fi

# Test 4.4: verify_release_signature fails with wrong public key
OTHER_PUB="$WORK_DIR/other.pub"
OTHER_SEC="$WORK_DIR/other.sec"
# shellcheck disable=SC2086
$USIGN_CMD -G -p "$OTHER_PUB" -s "$OTHER_SEC"
RELEASE_PUBKEY_OVERRIDE="$OTHER_PUB"
if verify_release_signature "$MANIFEST" "$SIGFILE" >/dev/null 2>&1; then
  test_fail "verify_release_signature unexpectedly succeeded with wrong public key"
fi
RELEASE_PUBKEY_OVERRIDE="$TEST_PUB"

# Test 4.5: 4-line Minisign signature compatibility (simulate minisign comment lines)
FOUR_LINE_SIG="$WORK_DIR/four_line.minisig"
cat "$SIGFILE" > "$FOUR_LINE_SIG"
printf 'trusted comment: timestamp:%s\tfile:sha256sums.txt\n' "$(date +%s)" >> "$FOUR_LINE_SIG"
printf 'RWSvrejmGGwvTwKe3zHe+DIiACxF8D3nUgR4xxcrxuQyIP6qafE52cdLAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==\n' >> "$FOUR_LINE_SIG"
if ! verify_release_signature "$MANIFEST" "$FOUR_LINE_SIG" >/dev/null 2>&1; then
  test_fail "verify_release_signature failed on 4-line minisign signature format"
fi

# Test 4.6: download_release full simulation with mock fetcher
MOCK_DIR="$WORK_DIR/mock_remote"
mkdir -p "$MOCK_DIR"

# Valid package mock (create dummy valid APK with ADBd header + size > 1024)
PKG_IS_APK=1
printf 'ADBd%1024s' "x" > "$MOCK_DIR/tachyon_1.5.0.apk"
printf 'ADBd%1024s' "y" > "$MOCK_DIR/luci-app-tachyon_1.5.0.apk"

(
  cd "$MOCK_DIR"
  sha256sum "tachyon_1.5.0.apk" "luci-app-tachyon_1.5.0.apk" > "sha256sums.txt"
)
# shellcheck disable=SC2086
$USIGN_CMD -S -s "$TEST_SEC" -m "$MOCK_DIR/sha256sums.txt" -x "$MOCK_DIR/sha256sums.txt.minisig"

# Mock download_with_retry to copy from MOCK_DIR
download_with_retry() {
  local url="$1" dest="$2" name="$3"
  local src="$MOCK_DIR/$(basename "$url")"
  if [ -f "$src" ]; then
    cp "$src" "$dest"
    return 0
  fi
  return 1
}

TACHYON_RELEASE_TAG="1.5.0"
TACHYON_BACKEND_NAME="tachyon_1.5.0.apk"
TACHYON_APP_NAME="luci-app-tachyon_1.5.0.apk"
TACHYON_SHA256_URL="http://mock/sha256sums.txt"
TACHYON_MINISIG_URL="http://mock/sha256sums.txt.minisig"
TACHYON_BACKEND_URL="http://mock/tachyon_1.5.0.apk"
TACHYON_APP_URL="http://mock/luci-app-tachyon_1.5.0.apk"
TACHYON_I18N_REQUESTED=0
DRY_RUN=0
REQUIRE_SIGNATURE=1
ALLOW_UNSIGNED=0

# Clean TMP_DIR for download run
rm -rf "${TMP_DIR:?}"/*
if ! download_release; then
  test_fail "download_release failed on valid mock release with signature"
fi

# Test 4.7: download_release fails hard if signature is corrupted
printf 'untrusted comment: corrupted\ncorrupted_base64_payload_which_fails_verification\n' > "$MOCK_DIR/sha256sums.txt.minisig"
rm -rf "${TMP_DIR:?}"/*
if download_release >/dev/null 2>&1; then
  test_fail "download_release did not fail hard on corrupt signature"
fi

# Test 4.8: download_release fails hard if package checksum mismatches
# Restore valid signature for current manifest
# shellcheck disable=SC2086
$USIGN_CMD -S -s "$TEST_SEC" -m "$MOCK_DIR/sha256sums.txt" -x "$MOCK_DIR/sha256sums.txt.minisig"
# Modify backend payload after hash was recorded
echo "tampered binary injection" >> "$MOCK_DIR/tachyon_1.5.0.apk"
rm -rf "${TMP_DIR:?}"/*
if download_release >/dev/null 2>&1; then
  test_fail "download_release did not fail hard on payload SHA256 mismatch"
fi

# Test 4.9: missing signature with REQUIRE_SIGNATURE=1 fails hard
TACHYON_MINISIG_URL=""
rm -rf "${TMP_DIR:?}"/*
REQUIRE_SIGNATURE=1
ALLOW_UNSIGNED=0
if download_release >/dev/null 2>&1; then
  test_fail "download_release did not fail hard on missing signature when required"
fi

# Test 4.10: missing signature with ALLOW_UNSIGNED=1 proceeds
ALLOW_UNSIGNED=1
REQUIRE_SIGNATURE=0
# Recompute valid hash for modified binary so checksum check passes
(
  cd "$MOCK_DIR"
  sha256sum "tachyon_1.5.0.apk" "luci-app-tachyon_1.5.0.apk" > "sha256sums.txt"
)
rm -rf "${TMP_DIR:?}"/*
if ! download_release >/dev/null 2>&1; then
  test_fail "download_release failed when --allow-unsigned was specified"
fi

# Test 5: CLI argument parsing for signature flags
parse_args --require-signature
[ "$REQUIRE_SIGNATURE" -eq 1 ] || test_fail "--require-signature did not set REQUIRE_SIGNATURE=1"
[ "$ALLOW_UNSIGNED" -eq 0 ] || test_fail "--require-signature did not set ALLOW_UNSIGNED=0"

parse_args --allow-unsigned
[ "$ALLOW_UNSIGNED" -eq 1 ] || test_fail "--allow-unsigned did not set ALLOW_UNSIGNED=1"
[ "$REQUIRE_SIGNATURE" -eq 0 ] || test_fail "--allow-unsigned did not set REQUIRE_SIGNATURE=0"

parse_args --pubkey "$TEST_PUB"
[ "$RELEASE_PUBKEY_OVERRIDE" = "$TEST_PUB" ] || test_fail "--pubkey did not set RELEASE_PUBKEY_OVERRIDE"

printf 'PASS: release signature verification tests\n'
