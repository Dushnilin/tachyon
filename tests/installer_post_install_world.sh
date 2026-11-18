#!/usr/bin/env bash
# BUG (issue #120): post-install cleanup must never delete tachyon or
# luci-app-tachyon from /etc/apk/world.
#
# Installed-but-not-in-world is what apk treats as an orphan, which would cause
# the next transaction to purge tachyon.
#
# The invariant: whatever cleanup does to the world file, it never touches
# tachyon or luci-app-tachyon, and only removes components that are Tachyon-managed.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER="$ROOT_DIR/install.sh"
[ -r "$INSTALLER" ] || fail "install.sh is missing"

WORLD="$WORK_DIR/world"
DB="$WORK_DIR/installed"
CALLS="$WORK_DIR/apk_calls"

seed_world() {
    cat >"$WORLD" <<'EOF'
sing-box
tachyon
luci-app-tachyon
luci-i18n-tachyon-ru
curl
EOF
    : >"$CALLS"
}

run_cleanup() {
    local managed_mode="${1:-0}"
    env -i PATH="$PATH" HOME="$HOME" \
        TACHYON_INSTALLER_TEST=1 \
        TACHYON_APK_WORLD_FILE="$WORLD" \
        TACHYON_APK_INSTALLED_DB="$DB" \
        APK_CALLS="$CALLS" \
        MANAGED_MODE="$managed_mode" \
        bash -c '. "$1"
                  PKG_IS_APK=1
                  DRY_RUN=0
                  msg() { :; }
                  warn() { :; }
                  apk() { printf "%s\n" "$*" >> "$APK_CALLS"; }
                  if [ "$MANAGED_MODE" -eq 1 ]; then
                      is_tachyon_managed_component() { return 0; }
                      eval "$(declare -f migrate_legacy_engine_files | sed "s/_sing_box_managed=0/_sing_box_managed=1/")"
                  fi
                  migrate_legacy_engine_files
                  cat "$APK_WORLD_FILE"' _ "$INSTALLER"
}

# 1. Clean / standalone install (no Tachyon markers for sing-box)
# Freshly installed tachyon and luci-app-tachyon must survive in world.
# Unmanaged sing-box must NOT be purged.
seed_world
cat >"$DB" <<'EOF'
P:tachyon
V:1.4.12
A:aarch64
P:luci-app-tachyon
V:1.4.12
A:aarch64
P:sing-box
V:1.8.0
A:aarch64
P:curl
V:8.0.0
A:aarch64
EOF

after="$(run_cleanup 0)"
printf '%s\n' "$after" | grep -qx 'tachyon' ||
  fail "tachyon was scrubbed out of apk world; apk purges it as an orphan on next transaction"
printf '%s\n' "$after" | grep -qx 'luci-app-tachyon' ||
  fail "luci-app-tachyon was scrubbed out of apk world; apk purges it as an orphan on next transaction"
printf '%s\n' "$after" | grep -qx 'luci-i18n-tachyon-ru' ||
  fail "an unrelated world entry was removed"
printf '%s\n' "$after" | grep -qx 'curl' ||
  fail "an unrelated world entry was removed"
# Standalone sing-box without Tachyon marker must remain in world
printf '%s\n' "$after" | grep -qx 'sing-box' ||
  fail "standalone sing-box was scrubbed without Tachyon-managed marker"

# 2. Tachyon-managed marker present: managed sing-box is scrubbed from world,
# but tachyon and luci-app-tachyon must still survive.
seed_world
after="$(run_cleanup 1)"

printf '%s\n' "$after" | grep -qx 'tachyon' ||
  fail "tachyon was scrubbed out of apk world during managed cleanup"
printf '%s\n' "$after" | grep -qx 'luci-app-tachyon' ||
  fail "luci-app-tachyon was scrubbed out of apk world during managed cleanup"
printf '%s\n' "$after" | grep -qx 'sing-box' &&
  fail "Tachyon-managed sing-box stayed in apk world"

printf 'PASS: post-install cleanup preserves tachyon in apk world and respects management markers (issue #120)\n'
