#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
MIGRATION="$TACHYON_LIB/config/migration.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. Verify CLI mapping in /usr/bin/tachyon
grep -Fq 'import_settings: [ "config/migration.uc", "import-settings", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon CLI must map import_settings to migration.uc"
grep -Fq '"import-settings": [ "config/migration.uc", "import-settings", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon CLI must map import-settings alias"

# 2. Test import from explicit legacy Forkop file
MOCK_ETC="$WORK_DIR/etc"
mkdir -p "$MOCK_ETC/config"

cat > "$MOCK_ETC/config/forkop" <<'EOF_FORKOP'
config settings 'settings'
	option enabled '1'
	option dns_server '8.8.8.8'

config rule 'youtube'
	option enabled '1'
	option connection_type 'proxy'
	option proxy_config_type 'url'
	option proxy_string 'vless://user@1.2.3.4:443?security=tls#node1'
	list domain 'youtube.com'
	list domain 'googlevideo.com'
EOF_FORKOP

# Initial dummy tachyon config
cat > "$MOCK_ETC/config/tachyon" <<'EOF_TACHYON'
config settings 'settings'
	option enabled '0'
EOF_TACHYON

cat > "$WORK_DIR/test_import.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.dns_server=8.8.8.8
tachyon.youtube=section
tachyon.youtube.enabled=1
tachyon.youtube.action=proxy
tachyon.youtube.proxy_config_type=url
tachyon.youtube.proxy_string=vless://user@1.2.3.4:443?security=tls#node1
EOF_STATE

OUTPUT="$(TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings "$MOCK_ETC/config/forkop")"

echo "$OUTPUT" | grep -Fq 'SUCCESS: Settings successfully imported' ||
  fail "import_settings must report success on valid legacy file"

echo "$OUTPUT" | grep -Fq 'Legacy Forkop / Podkop' ||
  fail "import_settings must recognize legacy format"

# 3. Test auto-scan in mock directory
SCAN_OUTPUT="$(TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings)"

echo "$SCAN_OUTPUT" | grep -Fq 'SUCCESS: Settings successfully imported' ||
  fail "import_settings auto-scan must import legacy file"

# 4. Test non-existent file path error handling
ERR_OUTPUT="$(TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings "$WORK_DIR/nonexistent.conf" 2>&1 || true)"
echo "$ERR_OUTPUT" | grep -Fq 'does not exist' ||
  fail "import_settings must handle missing file with error"

printf 'import_settings tests passed\n'
