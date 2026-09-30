#!/usr/bin/env bash
# FAULT: every install left a recovery snapshot behind, forever.
#
# Measured on 192.168.1.1: /etc/tachyon/installer-backups held two timestamped sets,
# 7 files, 40 KB, dated Sep 22 and Sep 28 - one per install, with nothing removing
# them. Each set is a copy of /etc/config/tachyon (13 KB on that device) plus
# /etc/apk/world, so the directory grows by a flash write per install, forever,
# and the older snapshots buy nothing once a few installs have passed.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

[ -f "$ROOT_DIR/install.sh" ] || fail "install.sh not found"

grep -q 'prune_old_snapshots' "$ROOT_DIR/install.sh" ||
  fail "install.sh never prunes old recovery snapshots, so they accumulate one per install"

# The prune has to run after the new snapshot exists, otherwise the snapshot just
# taken would be the one deleted when only one is kept.
grep -q 'prune_old_snapshots$' "$ROOT_DIR/install.sh" ||
  fail "prune_old_snapshots is not called from snapshot_state"

# Exercise the retention logic itself, since it is the part that can delete the
# wrong thing. Newest-first by name, because YYYYMMDD-HHMMSS sorts chronologically.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/backups"
for stamp in 20260901-100000 20260910-100000 20260920-100000 20260930-100000; do
  mkdir -p "$sandbox/backups/$stamp"
  printf 'installed=1\n' > "$sandbox/backups/$stamp/state"
done

kept="$(ls -1d "$sandbox"/backups/*/ | sort -r | head -3)"
count="$(printf '%s\n' "$kept" | wc -l)"
[ "$count" -eq 3 ] || fail "expected to keep 3 snapshots, kept $count"

newest="$(ls -1d "$sandbox"/backups/*/ | sort -r | head -1)"
[ -d "$newest" ] || fail "retention dropped the newest snapshot, which is the one needed to roll back the current install"

# Oldest *kept*, not oldest overall. `sort -r | tail -1` is the oldest snapshot in
# existence, which retention is supposed to remove - reading it as the survivor is
# what made the correct implementation look wrong.
oldest_left="$(printf '%s\n' "$kept" | tail -1)"
case "$oldest_left" in
  */20260930-100000/) fail "retention kept only the newest snapshot" ;;
  */20260910-100000/) ;;
  *) fail "retention kept the wrong set: oldest survivor is $oldest_left" ;;
esac

# And the one that should have gone must actually be the deletion candidate.
dropped="$(ls -1d "$sandbox"/backups/*/ | sort -r | tail -n +4)"
case "$dropped" in
  */20260901-100000/) ;;
  *) fail "retention did not select the oldest snapshot for removal: $dropped" ;;
esac

printf 'fault: installer snapshot retention passed\n'
