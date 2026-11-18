#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
MIGRATION="$TACHYON_LIB/config/migration.uc"

# 1. Verify CLI mapping in /usr/bin/tachyon
grep -Fq 'import_settings: [ "config/migration.uc", "import-settings", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon CLI must map import_settings to migration.uc"
grep -Fq '"import-settings": [ "config/migration.uc", "import-settings", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon CLI must map import-settings alias"

# 2. Test import from explicit Tachyon backup file
MOCK_ETC="$WORK_DIR/etc"
mkdir -p "$MOCK_ETC/config"

cat > "$WORK_DIR/tachyon-backup.conf" <<'EOF_BACKUP'
config settings 'settings'
	option enabled '1'
	option config_version '1.8.0'
	list dns_server '8.8.8.8'
	list bootstrap_dns_server '1.1.1.1'

config section 'youtube'
	option enabled '1'
	option action 'connection'
	list selector_proxy_links 'vless://user@1.2.3.4:443?security=tls#node1'
	option domain 'youtube.com'
EOF_BACKUP

cat > "$MOCK_ETC/config/tachyon" <<'EOF_TACHYON'
config settings 'settings'
	option enabled '0'
EOF_TACHYON

cat > "$WORK_DIR/test_import.state" <<'EOF_STATE'
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.config_version=1.8.0
tachyon.settings.dns_server=8.8.8.8
tachyon.settings.bootstrap_dns_server=1.1.1.1
tachyon.youtube=section
tachyon.youtube.enabled=1
tachyon.youtube.action=connection
tachyon.youtube.selector_proxy_links=vless://user@1.2.3.4:443?security=tls#node1
EOF_STATE

export TACHYON_SKIP_RESTART="1"

OUTPUT="$(env \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  TACHYON_SKIP_RESTART="1" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings "$WORK_DIR/tachyon-backup.conf")"

echo "$OUTPUT" | grep -Fq 'SUCCESS: Settings successfully imported' ||
  fail "import_settings must report success on valid backup file"

echo "$OUTPUT" | grep -Fq 'Detected format: Tachyon' ||
  fail "import_settings must report Tachyon format"

# 3. Auto-scan must ignore unrelated config filenames and find Tachyon backups
MOCK_SCAN_ETC="$WORK_DIR/etc_scan"
mkdir -p "$MOCK_SCAN_ETC/config"
cp "$MOCK_ETC/config/tachyon" "$MOCK_SCAN_ETC/config/tachyon"
for legacy_name in legacy_cfg legacy_plus foreign_cfg foreign_plus other_router; do
  cp "$WORK_DIR/tachyon-backup.conf" "$MOCK_SCAN_ETC/config/$legacy_name"
done

if env \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_SCAN_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_SCAN_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  TACHYON_SKIP_RESTART="1" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings >/dev/null 2>&1; then
  fail "import_settings auto-scan must not pick up unrelated config filenames"
fi

cp "$WORK_DIR/tachyon-backup.conf" "$MOCK_SCAN_ETC/config/tachyon.backup-20261118"
SCAN_OUTPUT="$(env \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_SCAN_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_SCAN_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  TACHYON_SKIP_RESTART="1" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings)"

echo "$SCAN_OUTPUT" | grep -Fq 'SUCCESS: Settings successfully imported' ||
  fail "import_settings auto-scan must import Tachyon backup file"
echo "$SCAN_OUTPUT" | grep -Fq 'tachyon.backup-20261118' ||
  fail "import_settings auto-scan must pick tachyon.backup-20261118"

# 4. Test non-existent file path error handling
ERR_OUTPUT="$(env \
  TACHYON_LIB="$TACHYON_LIB" \
  TACHYON_CONFIG_FILE="$MOCK_ETC/config/tachyon" \
  TACHYON_CONFIG_DIR="$MOCK_ETC/config" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/test_import.state" \
  TACHYON_UCI_LOG_FILE="$WORK_DIR/test_import.log" \
  TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/internal-config-change" \
  TACHYON_SKIP_RESTART="1" \
  ucode -L "$TACHYON_LIB" "$MIGRATION" import-settings "$WORK_DIR/nonexistent.conf" 2>&1 || true)"
echo "$ERR_OUTPUT" | grep -Fq 'does not exist' ||
  fail "import_settings must handle missing file with error"

printf 'import_settings tests passed\n'
