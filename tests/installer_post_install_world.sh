#!/usr/bin/env bash
# BUG (issue #120): the post-install legacy cleanup scrubbed /etc/apk/world
# with the no-argument list, i.e. WORLD_SCRUB_PACKAGES, which is
#
#   forkop ... netshift tachyon luci-app-tachyon
#
# so a run that found *no* legacy package still deleted the world entries of
# the two packages it had installed a minute earlier. Installed-but-not-in-world
# is exactly what apk treats as an orphan, so the next transaction it ran - a
# zapret2 component update - opened with:
#
#   (1/3) Purging luci-app-tachyon (1.4.12)
#   (2/3) Purging tachyon (1.4.12)
#   (3/3) Upgrading zapret2 (0.9.20260307-r1 -> 1.0.5.2)
#
# and the user lost the backend and the LuCI menu while /etc/config/tachyon
# stayed behind.
#
# The invariant: whatever remove_legacy_packages() does to the world file, it
# never touches tachyon or luci-app-tachyon. Driven against a real world file
# through the shipped function, so a re-implementation that happens to be
# correct on its own cannot make this pass.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER="$ROOT_DIR/install.sh"
[ -r "$INSTALLER" ] || fail "install.sh is missing"

WORLD="$WORK_DIR/world"
DB="$WORK_DIR/installed"
CALLS="$WORK_DIR/apk_calls"

seed_world() {
    cat >"$WORLD" <<'EOF'
forkop
luci-app-forkop
tachyon
luci-app-tachyon
luci-i18n-tachyon-ru
curl
EOF
    : >"$CALLS"
}

# Sources the shipped installer, runs the real post-install cleanup, prints the
# world file back. apk_run is stubbed into a log so the test never needs a
# package manager; msg/warn are silenced.
run_remove() {
    env -i PATH="$PATH" HOME="$HOME" \
        TACHYON_INSTALLER_TEST=1 \
        TACHYON_APK_WORLD_FILE="$WORLD" \
        TACHYON_APK_INSTALLED_DB="$DB" \
        APK_CALLS="$CALLS" \
        bash -c '. "$1"
                  PKG_IS_APK=1
                  msg() { :; }
                  warn() { :; }
                  apk_run() { printf "%s\n" "$*" >> "$APK_CALLS"; }
                  remove_legacy_packages
                  cat "$APK_WORLD_FILE"' _ "$INSTALLER"
}

# 1. No legacy package installed - the common "fresh install on a clean router"
#    path, and the one the bug report describes. The legacy names are still
#    scrubbed (they can linger in world after an earlier removal), but the
#    freshly installed packages must survive.
seed_world
cat >"$DB" <<'EOF'
P:tachyon
V:1.4.12
A:aarch64
P:luci-app-tachyon
V:1.4.12
A:aarch64
P:curl
V:8.0.0
A:aarch64
EOF
after="$(run_remove)"
printf '%s\n' "$after" | grep -qx 'forkop' &&
  fail "forkop stayed in apk world after the post-install cleanup"
printf '%s\n' "$after" | grep -qx 'luci-app-forkop' &&
  fail "luci-app-forkop stayed in apk world after the post-install cleanup"
printf '%s\n' "$after" | grep -qx 'tachyon' ||
  fail "tachyon was scrubbed out of apk world by the post-install cleanup; apk purges it as an orphan on the next transaction"
printf '%s\n' "$after" | grep -qx 'luci-app-tachyon' ||
  fail "luci-app-tachyon was scrubbed out of apk world by the post-install cleanup; apk purges it as an orphan on the next transaction"
printf '%s\n' "$after" | grep -qx 'luci-i18n-tachyon-ru' ||
  fail "an unrelated world entry was removed"
printf '%s\n' "$after" | grep -qx 'curl' ||
  fail "an unrelated world entry was removed"
[ -s "$CALLS" ] && fail "apk del ran even though no legacy package is installed"

# 2. A legacy package really installed: it must be removed through apk *and*
#    dropped from world, with tachyon untouched all the same.
seed_world
cat >"$DB" <<'EOF'
P:forkop
V:1.0.5
A:aarch64
P:tachyon
V:1.4.12
A:aarch64
P:luci-app-tachyon
V:1.4.12
A:aarch64
EOF
after="$(run_remove)"
printf '%s\n' "$after" | grep -qx 'forkop' &&
  fail "forkop stayed in apk world although it was installed and removed"
printf '%s\n' "$after" | grep -qx 'tachyon' ||
  fail "tachyon was scrubbed out of apk world on the legacy-removal path"
printf '%s\n' "$after" | grep -qx 'luci-app-tachyon' ||
  fail "luci-app-tachyon was scrubbed out of apk world on the legacy-removal path"
grep -q 'del forkop' "$CALLS" ||
  fail "apk del was not called for the installed legacy package: $(cat "$CALLS")"

printf 'PASS: the post-install cleanup scrubs legacy packages and never tachyon (issue #120)\n'
