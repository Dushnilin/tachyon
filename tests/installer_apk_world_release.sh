#!/usr/bin/env bash
# Exercises the apk world scrub that has to happen before the Tachyon packages
# are installed.
#
# apk's solver reads /etc/apk/world before it selects anything. A user migrating
# from forkop has world[forkop] satisfied by luci-app-forkop, while tachyon
# declares both Conflicts: forkop and breaks: world[forkop]. That set is not
# selectable, apk aborts with "unable to select packages" and rolls the whole
# transaction back, so the router is left running forkop with no Tachyon at all.
# The error text a user sees names world[forkop] explicitly, which is what this
# test pins the fix to.
#
# Both paths are checked on a real world file rather than by grepping the
# installer: the previous scrub ran after `apk del`, i.e. after the solver had
# already failed, and no source-level assertion would have noticed.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER="$ROOT_DIR/install.sh"
[ -r "$INSTALLER" ] || fail "install.sh is missing"

WORLD="$WORK_DIR/world"
DB="$WORK_DIR/installed"

seed_forkop_world() {
    cat >"$WORLD" <<'EOF'
forkop
luci-app-forkop
tachyon
luci-app-tachyon
luci-i18n-tachyon-ru
curl
EOF
    cat >"$DB" <<'EOF'
P:forkop
V:1.0.5
A:x86_64
P:luci-app-forkop
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

# 1. forkop installed: the legacy entries must go, so apk can drop forkop inside
#    the same transaction that installs Tachyon.
seed_forkop_world
after="$(run_scrub)"
printf '%s\n' "$after" | grep -qx 'forkop' &&
  fail "forkop stayed in apk world; apk cannot select it against tachyon"
printf '%s\n' "$after" | grep -qx 'luci-app-forkop' &&
  fail "luci-app-forkop stayed in apk world; it satisfies world[forkop]"
# tachyon itself must not be dropped: if the install fails afterwards and the
# world file is restored, a missing tachyon entry would leave the package
# installed but no longer tracked.
printf '%s\n' "$after" | grep -qx 'tachyon' ||
  fail "the pre-install scrub must not remove tachyon from world"
printf '%s\n' "$after" | grep -qx 'luci-app-tachyon' ||
  fail "the pre-install scrub must not remove luci-app-tachyon from world"
printf '%s\n' "$after" | grep -qx 'curl' ||
  fail "an unrelated world entry was removed"

# 2. No legacy package installed: the world file must be untouched, so a plain
#    upgrade never rewrites it.
seed_forkop_world
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
  fail "world file was rewritten even though no legacy package is installed"

printf 'PASS: legacy packages are released from apk world before the install, and only then\n'