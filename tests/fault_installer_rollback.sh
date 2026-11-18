#!/usr/bin/env bash
# FAULT: a failed install must not leave the package manager broken.
#
# Issue #85. The installer snapshots /etc/apk/world before the transaction.
# If an installation step fails, rollback restores the snapshot so the world
# file is returned to its clean pre-installation state.
#
# The invariant: after a rollback, the world file must accurately reflect
# the snapshot and unrelated packages survive untouched.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER="$ROOT_DIR/install.sh"

[ -r "$INSTALLER" ] || fail "install.sh is missing"
sh -n "$INSTALLER" || fail "install.sh must be valid POSIX shell"

TACHYON_INSTALLER_TEST=1
export TACHYON_INSTALLER_TEST
export TACHYON_APK_WORLD_FILE=""

# shellcheck source=/dev/null
. "$INSTALLER"

trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

WORLD="$WORK_DIR/world"
APK_WORLD_FILE="$WORLD"

cat > "$WORLD" <<'EOF'
tachyon
luci-app-tachyon
luci-base
curl
EOF

# --- removal must not take the user's config with it ------------------------
# apk del must not use --purge which destroys user config files.
if grep -Fq 'del --purge' "$INSTALLER"; then
  fail "installer still uses del --purge which destroys user configuration"
fi

# --- the rollback must restore world cleanly from snapshot -------------------
PKG_IS_APK=1
TX_ACTIVE=1
TX_COMMITTED=0
SNAPSHOT_DIR="$WORK_DIR/snapshot"
mkdir -p "$SNAPSHOT_DIR"
cp -a "$WORLD" "$SNAPSHOT_DIR/apk-world"

# Simulate a failed transaction modifying the world file
echo "transient-broken-package" >> "$WORLD"

restore_snapshot

if grep -q '^transient-broken-package$' "$WORLD"; then
  fail "the rollback failed to restore world from snapshot: $(tr '\n' ' ' <"$WORLD")"
fi

# The rest of the world file must survive the rollback untouched.
grep -q '^tachyon$' "$WORLD" || fail "the rollback lost an unrelated package entry: $(tr '\n' ' ' <"$WORLD")"
grep -q '^luci-app-tachyon$' "$WORLD" || fail "the rollback lost an unrelated package entry: $(tr '\n' ' ' <"$WORLD")"
grep -q '^luci-base$' "$WORLD" || fail "the rollback lost an unrelated package entry: $(tr '\n' ' ' <"$WORLD")"
grep -q '^curl$' "$WORLD" || fail "the rollback lost an unrelated package entry: $(tr '\n' ' ' <"$WORLD")"

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
