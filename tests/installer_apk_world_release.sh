#!/usr/bin/env bash
# Exercises the apk world scrub that has to happen before the Tachyon packages
# are installed.
#
# apk's solver reads /etc/apk/world before it selects anything. If conflicting
# packages like ip-tiny or old pinned tachyon entries remain in world, apk aborts
# with solver conflicts.
#
# Both paths are checked on a real world file rather than by grepping the
# installer.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER="$ROOT_DIR/install.sh"
[ -r "$INSTALLER" ] || fail "install.sh is missing"

WORLD="$WORK_DIR/world"
DB="$WORK_DIR/installed"

seed_conflict_world() {
    cat >"$WORLD" <<'EOF'
ip-tiny
tachyon><Q1xQUnmiOp+e0PiSxLsLXIOp3Cq/Y=
luci-app-tachyon><Q1WPZ/U5n85WC30B3i9JglYX5QFxw=
luci-i18n-tachyon-ru
curl
EOF
    cat >"$DB" <<'EOF'
P:ip-tiny
V:1.0.5
A:x86_64
P:curl
V:8.0.0
A:x86_64
EOF
}

run_scrub() {
    env -i PATH="$PATH" HOME="$HOME" \
        TACHYON_INSTALLER_TEST=1 \
        TACHYON_APK_WORLD_FILE="$WORLD" \
        TACHYON_APK_INSTALLED_DB="$DB" \
        DRY_RUN=0 \
        bash -c '. "$1"
                  PKG_IS_APK=1
                  resolve_legacy_conflicts_before_install
                  cat "$APK_WORLD_FILE"' _ "$INSTALLER"
}

# 1. Conflicting ip-tiny and pinned tachyon entries: must be released from world
seed_conflict_world
after="$(run_scrub)"
printf '%s\n' "$after" | grep -qx 'ip-tiny' &&
  fail "ip-tiny stayed in apk world; conflicts with ip-full"
printf '%s\n' "$after" | grep -q '^tachyon>' &&
  fail "pinned tachyon stayed in apk world"
printf '%s\n' "$after" | grep -q '^luci-app-tachyon>' &&
  fail "pinned luci-app-tachyon stayed in apk world"
printf '%s\n' "$after" | grep -qx 'luci-i18n-tachyon-ru' ||
  fail "unrelated entry luci-i18n-tachyon-ru was removed"
printf '%s\n' "$after" | grep -qx 'curl' ||
  fail "an unrelated world entry was removed"

# 2. Clean unpinned world: the world file must be untouched
cat >"$WORLD" <<'EOF'
tachyon
luci-app-tachyon
curl
EOF
cat >"$DB" <<'EOF'
P:tachyon
V:1.4.5
A:aarch64
P:curl
V:8.0.0
A:aarch64_generic
EOF
after="$(run_scrub)"
[ "$after" = "$(cat "$WORLD")" ] ||
  fail "world file was rewritten even though no conflict exists"

printf 'PASS: conflicting and pinned packages are released from apk world before the install, and only then\n'
