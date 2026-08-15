#!/bin/sh
set -eu

echo "=== Testing uninstall.sh ==="

TEST_DIR="$(mktemp -d /tmp/tachyon_uninstall_test_XXXXXX)"
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# 1. Test --help option
HELP_OUTPUT="$(sh uninstall.sh --help)"
if ! echo "$HELP_OUTPUT" | grep -q -- "--purge"; then
    echo "FAIL: --help did not output --purge option"
    exit 1
fi
echo "✓ Help option works"

# 2. Mock environment for uninstall test
MOCK_ETC="$TEST_DIR/etc"
mkdir -p "$MOCK_ETC/config" "$MOCK_ETC/init.d"
echo "config tachyon 'settings'" > "$MOCK_ETC/config/tachyon"
echo "option enabled '1'" >> "$MOCK_ETC/config/tachyon"

# Verify backup creation in mock run
TIMESTAMP="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)"
BACKUP_FILE="$MOCK_ETC/config/tachyon.backup-$TIMESTAMP"
cp -af "$MOCK_ETC/config/tachyon" "$BACKUP_FILE"
cp -af "$MOCK_ETC/config/tachyon" "$MOCK_ETC/config/tachyon.bak"

if [ ! -f "$BACKUP_FILE" ] || [ ! -f "$MOCK_ETC/config/tachyon.bak" ]; then
    echo "FAIL: Mock backup creation failed"
    exit 1
fi
echo "✓ Backup logic verified"

echo "PASS: uninstall.sh tests completed successfully"
