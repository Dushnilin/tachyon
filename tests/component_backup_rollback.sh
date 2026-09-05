#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
ACTION_UC="$TACHYON_LIB/components/action.uc"
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

MOCK_BIN_DIR="$WORK_DIR/bin"
MOCK_BACKUPS_DIR="$WORK_DIR/backups"
MOCK_CONFIG_DIR="$WORK_DIR/config"
MOCK_VAR_DIR="$WORK_DIR/run"
mkdir -p "$MOCK_BIN_DIR" "$MOCK_BACKUPS_DIR" "$MOCK_CONFIG_DIR" "$MOCK_VAR_DIR"

# 1. Create a dummy sing-box binary v1.10.0
cat > "$MOCK_BIN_DIR/sing-box" <<'EOF_SB'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "sing-box version 1.10.0"
    exit 0
fi
exit 0
EOF_SB
chmod 0755 "$MOCK_BIN_DIR/sing-box"

# Create UCI state with component_backup_enabled = 1
cat > "$WORK_DIR/uci.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.component_backup_enabled=1
EOF_UCI
: > "$WORK_DIR/uci.log"

export TACHYON_LIB="$TACHYON_LIB"
export TACHYON_COMPONENT_BACKUPS_DIR="$MOCK_BACKUPS_DIR"
export TACHYON_SING_BOX_BIN="$MOCK_BIN_DIR/sing-box"
export TACHYON_CONFIG_DIR="$MOCK_CONFIG_DIR"
export TACHYON_RUNTIME_STATE_DIR="$MOCK_VAR_DIR"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TACHYON_UCI_LOG_FILE="$WORK_DIR/uci.log"
export SB_VERSION_STATE_FILE="$WORK_DIR/sing-box-version"
export SB_VARIANT_STATE_FILE="$WORK_DIR/sing-box-variant"
export PATH="$MOCK_BIN_DIR:$PATH"

# Test 1: Triggering rollback when no backup exists should fail cleanly
ROLLBACK_NO_BACKUP_OUT="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$ACTION_UC" component-action sing_box rollback 2>&1 || true)"
echo "$ROLLBACK_NO_BACKUP_OUT" | grep -Eq '"success":[[:space:]]*false' ||
  fail "rollback without backup must fail cleanly with JSON success:false"

# Test 2: Manually simulate backup creation or verify backup metadata reading
mkdir -p "$MOCK_BACKUPS_DIR/sing_box"
cat > "$MOCK_BIN_DIR/sing-box-old" <<'EOF_OLD'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "sing-box version 1.9.5"
    exit 0
fi
exit 0
EOF_OLD
chmod 0755 "$MOCK_BIN_DIR/sing-box-old"
cp -p "$MOCK_BIN_DIR/sing-box-old" "$MOCK_BACKUPS_DIR/sing_box/sing-box"
cat > "$MOCK_BACKUPS_DIR/sing_box/metadata.json" <<'EOF_META'
{
  "component": "sing_box",
  "version": "1.9.5",
  "variant": "extended",
  "marker": "extended",
  "timestamp": 1756728000
}
EOF_META

# Test 3: System info includes backup metadata
SYS_INFO="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" get-system-info)"
echo "$SYS_INFO" | grep -Eq '"sing_box_backup_version":[[:space:]]*"1.9.5"' ||
  fail "system_info must report sing_box_backup_version from metadata"

# Test 4: Rollback replaces active binary with backup version
ROLLBACK_OUT="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$ACTION_UC" component-action sing_box rollback)"
echo "$ROLLBACK_OUT" | grep -Eq '"success":[[:space:]]*true' ||
  fail "rollback with valid backup must return success:true"

printf 'component backup and rollback tests passed\n'
