#!/usr/bin/env bash
# FAULT: a failed install must not leave the package manager broken.
#
# Issue #85. Podkop binds sing-box's DNS to 127.0.0.42:53 and users point dnsmasq
# at it manually. The installer purges podkop, that resolver disappears, and the
# rest of the install cannot resolve names - so it fails, and the failure path is
# where the damage becomes permanent.
#
# The damage: the snapshot of /etc/apk/world is taken BEFORE the legacy packages
# are removed, and the rollback copies that snapshot back afterwards. The
# restored world therefore names packages that the installer itself uninstalled,
# and from then on every apk operation fails with "no such package ... required by
# world[...]" until the user edits the file by hand. The router is fine; the
# package manager is bricked, and nothing tells them how to fix it.
#
# The invariant: after a rollback, the world file must not name anything that is
# not installed - and in particular nothing the installer removed.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER="$ROOT_DIR/install.sh"

[ -r "$INSTALLER" ] || fail "install.sh is missing"
sh -n "$INSTALLER" || fail "install.sh must be valid POSIX shell"

TACHYON_INSTALLER_TEST=1
export TACHYON_INSTALLER_TEST
# Must be exported before sourcing: the installer resolves the world file at
# load time, and pointing it at a scratch file is the whole point.
export TACHYON_APK_WORLD_FILE=""

# shellcheck source=/dev/null
. "$INSTALLER"

trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

WORLD="$WORK_DIR/world"
CONFIG="$WORK_DIR/podkop"
APK_WORLD_FILE="$WORLD"

cat > "$WORLD" <<'EOF'
podkop
luci-app-podkop
tachyon
luci-base
EOF

# --- removal must not take the user's config with it ------------------------
# The user keeps /etc/config/podkop on purpose: the migration reads it, and
# there is no reason for the installer to destroy it. --purge did exactly that,
# and only on apk - the opkg path used the same removal without it.
if grep -Fq 'del --purge' "$INSTALLER"; then
  fail "legacy removal still purges the user's config (/etc/config/podkop) - the migration needs it and the user asked to keep it"
fi

# --- the rollback must not name packages the installer removed ---------------
# Reproduce the ordering the installer uses: snapshot, then remove, then roll
# back. The stub keeps the removal side effect but skips the real apk.
PKG_IS_APK=1
TX_ACTIVE=1
TX_COMMITTED=0
SNAPSHOT_DIR="$WORK_DIR/snapshot"
mkdir -p "$SNAPSHOT_DIR"
cp -a "$WORLD" "$SNAPSHOT_DIR/apk-world"

# Stands in for `apk del`: the package leaves /lib/apk/db/installed, and world
# is scrubbed the way the installer scrubs it.
fake_remove_legacy() {
  for _pkg in $LEGACY_PACKAGES; do
    printf 'P:%s\n' "$_pkg" >>"$WORK_DIR/apk-installed"
  done
  for _pkg in $WORLD_SCRUB_PACKAGES; do
    sed -i "/^${_pkg}\$/d" "$APK_WORLD_FILE" 2>/dev/null || true
  done
}
printf 'P:tachyon\nP:luci-base\n' >"$WORK_DIR/apk-installed"
fake_remove_legacy

grep -q '^podkop$' "$WORLD" && fail "the test setup did not scrub world"

restore_snapshot

if grep -q '^podkop$' "$WORLD" || grep -q '^luci-app-podkop$' "$WORLD"; then
  fail "the rollback restored /etc/apk/world to a state naming podkop packages the installer had already uninstalled - apk is now bricked until the user edits the file by hand (issue #85): $(tr '\n' ' ' <"$WORLD")"
fi

# The rest of the world file must survive the rollback untouched.
grep -q '^tachyon$' "$WORLD" || fail "the rollback lost an unrelated package entry: $(tr '\n' ' ' <"$WORLD")"
grep -q '^luci-base$' "$WORLD" || fail "the rollback lost an unrelated package entry: $(tr '\n' ' ' <"$WORLD")"

# --- and legacy removal must not happen before Tachyon is proven working ----
# Removing podkop kills the resolver the user's dnsmasq points at, and at that
# point in the install Tachy's own DNS is not up yet. That window is the whole
# failure, so the removal belongs after the healthcheck.
# Extract prepare_transaction's body on its own. A plain grep over the file
# would also match the call in main() and pass for the wrong reason.
pt_body="$(sed -n '/^prepare_transaction()/,/^}/p' "$INSTALLER")"
[ -n "$pt_body" ] || fail "could not locate prepare_transaction()"
if printf '%s\n' "$pt_body" | grep -q 'remove_legacy_packages'; then
  fail "legacy packages are still removed before the healthcheck, which leaves a window with no working DNS resolver (issue #85)"
fi

# And the call has to exist, after the healthcheck, in main().
awk '
  /^main\(\)/ { in_main = 1 }
  in_main && /healthcheck/ && !hc { hc = NR }
  in_main && /remove_legacy_packages/ && !late { late = NR }
  END { exit !(hc > 0 && late > hc) }
' "$INSTALLER" || fail "legacy removal must happen after the healthcheck, and somewhere in main() at that"

# --- the resolver must be checked before anything is downloaded -------------
# Otherwise the install fails later, deeper in, with a download error that says
# nothing about the real cause.
if ! grep -Fq 'check_name_resolution' "$INSTALLER"; then
  fail "the installer has no name-resolution check - with a dead resolver it fails later and deeper, blaming the download"
fi

# Ordering: the check has to come before the first thing that needs a network.
awk '
  /^main\(\)/ { in_main = 1 }
  in_main && /check_name_resolution/ && !chk { chk = NR }
  in_main && /download_release/ && !dl { dl = NR }
  END { exit !(chk > 0 && dl > 0 && chk < dl) }
' "$INSTALLER" || fail "the name-resolution check must run before the release download"

printf 'fault: installer rollback checks passed\n'
