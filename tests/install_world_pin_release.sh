#!/usr/bin/env bash
# BUG: reinstalling over an existing Tachyon left its own pins in the apk world
# file, so the next `apk add` had to satisfy a constraint describing a build that
# is no longer on the box.
#
# After a local .apk install apk rewrites the world entry with a version and hash
# constraint. A router that had 1.4.5 installed by this very installer reads
# (captured verbatim from the test router at 192.168.1.205):
#
#   tachyon><Q1xQUnmiOp+e0PiSxLsLXIOp3Cq/Y=
#   luci-app-tachyon><Q1WPZ/U5n85WC30B3i9JglYX5QFxw=
#   luci-i18n-tachyon-ru><Q1ztNcPp2thKHC5nHJ5yipyXAedgo=
#
# scrub_apk_world() deleted with "/^${_pkg}$/d", anchored to end of line, which
# matches none of those. It runs on three paths, but the only one that runs
# before `apk add` passed an explicit LEGACY list containing no Tachyon package,
# so the pins survived every reinstall - including the ordinary "install over the
# version already on the box" that most upgrades are.
#
# The invariant: a reinstall must release this installer's own pinned entries
# before the transaction, and must leave unrelated packages alone.
#
# The scrub is driven by extracting the function out of install.sh, so this
# cannot pass against a re-implementation that happens to be correct on its own.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALL_SH="$ROOT_DIR/install.sh"
[ -f "$INSTALL_SH" ] || fail "install.sh not found at $INSTALL_SH"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SANDBOX="$(mktemp -d /tmp/tachyon-world.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

# Pull the real function out of the shipped installer. debug() is stubbed
# because install.sh defines it in the main flow, not next to the function.
{
  debug() { :; }
  eval "$(awk '/^scrub_apk_world\(\) \{/,/^\}/' "$INSTALL_SH")"
} || fail "could not extract scrub_apk_world() from install.sh"
type scrub_apk_world >/dev/null 2>&1 || fail "scrub_apk_world() was not extracted; the test cannot describe the shipped flow"

APK_WORLD_FILE="$SANDBOX/world"
LEGACY_PACKAGES="forkop luci-app-forkop"
WORLD_SCRUB_PACKAGES="$LEGACY_PACKAGES tachyon luci-app-tachyon"

# The world as the test router has it, pins included.
cat >"$APK_WORLD_FILE" <<'WORLD'
apk-mbedtls
busybox
luci-app-tachyon><Q1WPZ/U5n85WC30B3i9JglYX5QFxw=
tachyon><Q1xQUnmiOp+e0PiSxLsLXIOp3Cq/Y=
luci-i18n-tachyon-ru><Q1ztNcPp2thKHC5nHJ5yipyXAedgo=
steer-extended
zapret2
WORLD

scrub_apk_world

# --- 1. the pinned Tachyon entries must be gone ----------------------------
for entry in 'tachyon>' 'luci-app-tachyon>'; do
  grep -q "^${entry}" "$APK_WORLD_FILE" &&
    fail "pinned entry survived scrub_apk_world: $(grep "^${entry}" "$APK_WORLD_FILE")"
  ok
done

# --- 2. unrelated packages must survive ------------------------------------
# steer-extended and zapret2 are both in scope for scrubbing in other lists, so
# they are the interesting ones here; an unanchored match would eat them.
for keep in apk-mbedtls busybox steer-extended zapret2; do
  grep -qx "$keep" "$APK_WORLD_FILE" ||
    fail "scrub removed unrelated package '$keep': $(cat "$APK_WORLD_FILE")"
  ok
done

# --- 3. a bare entry is still removed --------------------------------------
# The old $ anchor is what made the unpinned case work, and it has to keep
# working: a world entry with no constraint is just as fatal to the solver.
printf 'tachyon\nbusybox\nforkop\n' >"$APK_WORLD_FILE"
scrub_apk_world
grep -qx "tachyon" "$APK_WORLD_FILE" &&
  fail "a bare 'tachyon' entry must also be removed from world"
ok
grep -qx "forkop" "$APK_WORLD_FILE" &&
  fail "forkop is in WORLD_SCRUB_PACKAGES, so a bare forkop entry is removed too"
ok
grep -qx "busybox" "$APK_WORLD_FILE" || fail "scrub removed an unrelated package"
ok

# --- 4. a clean world is left byte-identical -------------------------------
# Guards the opposite failure: a scrub that rewrites unconditionally would churn
# /etc/apk/world on flash for no reason.
printf 'apk-mbedtls\nbusybox\nsteer-extended\n' >"$APK_WORLD_FILE"
cp "$APK_WORLD_FILE" "$SANDBOX/clean.before"
scrub_apk_world
cmp -s "$SANDBOX/clean.before" "$APK_WORLD_FILE" ||
  fail "scrub rewrote an already-clean world file: $(cat "$APK_WORLD_FILE")"
ok

# --- 5. the release must happen before the transaction ---------------------
# apk reads world before it selects, so scrubbing afterwards cannot help. And the
# only pre-install path used to pass the LEGACY list, which has no Tachyon in it.
grep -q 'scrub_apk_world "\$LEGACY_PACKAGES"' "$INSTALL_SH" ||
  fail "the legacy-only scrub is gone; this test no longer describes the flow it guards"
ok

grep -qE 'for _pkg in \$WORLD_SCRUB_PACKAGES' "$INSTALL_SH" ||
  fail "install.sh never releases \$WORLD_SCRUB_PACKAGES before apk add, so this installer's own pinned entries survive a reinstall"
ok

release_line="$(grep -n 'WORLD_SCRUB_PACKAGES' "$INSTALL_SH" | tail -n1 | cut -d: -f1)"
txn_line="$(grep -n 'install_core_transaction ||' "$INSTALL_SH" | head -n1 | cut -d: -f1)"
[ -n "$release_line" ] && [ -n "$txn_line" ] ||
  fail "could not locate both the world release and the transaction in install.sh"
[ "$release_line" -lt "$txn_line" ] ||
  fail "pinned world entries are released at line $release_line, after the transaction at line $txn_line; apk reads world before it selects, so releasing afterwards cannot help"
ok

echo "install_world_pin_release: $pass_count checks passed"