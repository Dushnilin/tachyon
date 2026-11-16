#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
ACTION_UC="$TACHYON_LIB/components/action.uc"
RUNTIME_UC="$TACHYON_LIB/diagnostics/runtime.uc"

MOCK_BIN_DIR="$WORK_DIR/bin"
MOCK_BACKUPS_DIR="$WORK_DIR/backups"
MOCK_CONFIG_DIR="$WORK_DIR/config"
MOCK_VAR_DIR="$WORK_DIR/run"
mkdir -p "$MOCK_BIN_DIR" "$MOCK_BACKUPS_DIR" "$MOCK_CONFIG_DIR" "$MOCK_VAR_DIR"

# 1. Create a dummy tachyon-core binary v0.5.7
cat > "$MOCK_BIN_DIR/tachyon-core" <<'EOF_CORE'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "tachyon-core version 0.5.7"
    exit 0
fi
exit 0
EOF_CORE
chmod 0755 "$MOCK_BIN_DIR/tachyon-core"

# Create UCI state with component_backup_enabled = 1
cat > "$WORK_DIR/uci.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.component_backup_enabled=1
EOF_UCI
: > "$WORK_DIR/uci.log"

export TACHYON_COMPONENT_BACKUPS_DIR="$MOCK_BACKUPS_DIR"
export TACHYON_CORE_BIN="$MOCK_BIN_DIR/tachyon-core"
export TACHYON_CONFIG_DIR="$MOCK_CONFIG_DIR"
export TACHYON_RUNTIME_STATE_DIR="$MOCK_VAR_DIR"
export TACHYON_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TACHYON_UCI_LOG_FILE="$WORK_DIR/uci.log"
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/tachyon-core-version"
export PATH="$MOCK_BIN_DIR:$PATH"

# Test 1: Triggering rollback when no backup exists should fail cleanly
ROLLBACK_NO_BACKUP_OUT="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$ACTION_UC" component-action tachyon-core rollback 2>&1 || true)"
echo "$ROLLBACK_NO_BACKUP_OUT" | grep -Eq '"success":[[:space:]]*false' ||
  fail "rollback without backup must fail cleanly with JSON success:false"

# Test 2: Simulate backup metadata
mkdir -p "$MOCK_BACKUPS_DIR/tachyon_core"
cat > "$MOCK_BIN_DIR/tachyon-core-old" <<'EOF_OLD'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "tachyon-core version 0.4.8"
    exit 0
fi
exit 0
EOF_OLD
chmod 0755 "$MOCK_BIN_DIR/tachyon-core-old"
cp -p "$MOCK_BIN_DIR/tachyon-core-old" "$MOCK_BACKUPS_DIR/tachyon_core/tachyon-core"
cat > "$MOCK_BACKUPS_DIR/tachyon_core/metadata.json" <<'EOF_META'
{
  "component": "tachyon-core",
  "version": "0.4.8",
  "timestamp": 1756728000
}
EOF_META

# Test 3: System info includes backup metadata
SYS_INFO="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$RUNTIME_UC" get-system-info)"
echo "$SYS_INFO" | grep -Eq '"tachyon_core_backup_version":[[:space:]]*"0.4.8"' ||
  fail "system_info must report tachyon_core_backup_version from metadata"

# Test 4: Rollback replaces active binary with backup version
ROLLBACK_OUT="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$ACTION_UC" component-action tachyon-core rollback)"
echo "$ROLLBACK_OUT" | grep -Eq '"success":[[:space:]]*true' ||
  fail "rollback with valid backup must return success:true"

# Test 5: Broken active binary does not overwrite existing valid backup
cp -p "$MOCK_BIN_DIR/tachyon-core-old" "$MOCK_BACKUPS_DIR/tachyon_core/tachyon-core"
cat > "$MOCK_BACKUPS_DIR/tachyon_core/metadata.json" <<'EOF_META'
{
  "component": "tachyon-core",
  "version": "0.4.8",
  "timestamp": 1756728000
}
EOF_META

cat > "$MOCK_BIN_DIR/tachyon-core" <<'EOF_BROKEN'
#!/bin/sh
echo "FATAL: binary corrupted / segmentation fault" >&2
exit 1
EOF_BROKEN
chmod 0755 "$MOCK_BIN_DIR/tachyon-core"

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$ACTION_UC" component-action tachyon-core install >/dev/null 2>&1 || true

BACKUP_VER="$("$MOCK_BACKUPS_DIR/tachyon_core/tachyon-core" version 2>/dev/null || true)"
echo "$BACKUP_VER" | grep -q "0.4.8" ||
  fail "broken binary must not overwrite valid existing backup"

# Test 6: Pre-flight config check via verifier
echo '{"inbounds":[]}' > "$MOCK_CONFIG_DIR/config.json"

# 6a: Incompatible/broken binary fails check
CHECK_FAIL="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let v = require("components.verifier");
let res = v.check_core_config_with_binary("'"$MOCK_BIN_DIR/tachyon-core"'", "'"$MOCK_CONFIG_DIR/config.json"'", "");
print(sprintf("%J\n", res));
')"
echo "$CHECK_FAIL" | grep -Eq '"ok":[[:space:]]*false' ||
  fail "broken binary must fail preflight check"

# 6b: Valid binary passes check
cat > "$MOCK_BIN_DIR/tachyon-core-good" <<'EOF_GOOD'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "tachyon-core version 0.5.7"
    exit 0
fi
if [ "$3" = "check" ] || [ "$4" = "check" ]; then
    exit 0
fi
exit 0
EOF_GOOD
chmod 0755 "$MOCK_BIN_DIR/tachyon-core-good"

CHECK_PASS="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" -e '
let v = require("components.verifier");
let res = v.check_core_config_with_binary("'"$MOCK_BIN_DIR/tachyon-core-good"'", "'"$MOCK_CONFIG_DIR/config.json"'", "");
print(sprintf("%J\n", res));
')"
echo "$CHECK_PASS" | grep -Eq '"ok":[[:space:]]*true' ||
  fail "valid binary must pass preflight check"

printf 'component backup and rollback tests passed\n'
