#!/usr/bin/env bash
# A rebuilt release keeps its version string, so "the package is installed and the
# version matches" stays true even when the package manager rolled the upgrade
# back — which is how a failed install used to end with a green success banner.
# The only thing that moves is the commit SHA baked into the installed constants
# module, so these checks pin how the installer reads it.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

[ -r "$INSTALLER" ] || fail "install.sh must exist"

# The function is lifted out of the installer rather than sourced: install.sh runs
# main() at the bottom, so sourcing it would attempt a real installation. Only the
# hardcoded path is redirected, so the extraction logic under test is the shipped
# one, character for character.
sed -n '/^installed_backend_sha() {/,/^}/p' "$INSTALLER" >"$WORK_DIR/sha.sh"
[ -s "$WORK_DIR/sha.sh" ] ||
  fail "install.sh must define installed_backend_sha for rollback detection"
grep -Fq '/usr/lib/tachyon/core/constants.uc' "$WORK_DIR/sha.sh" ||
  fail "installed_backend_sha must read the installed constants module"
sed 's#/usr/lib/tachyon/core/constants.uc#'"$WORK_DIR"'/constants.uc#' \
  "$WORK_DIR/sha.sh" >"$WORK_DIR/sha-under-test.sh"

read_sha() {
  local constants="$1"
  rm -f "$WORK_DIR/constants.uc"
  [ "$constants" = "" ] || cp "$constants" "$WORK_DIR/constants.uc"
  (
    # shellcheck disable=SC1090
    . "$WORK_DIR/sha-under-test.sh"
    installed_backend_sha
  )
}

printf '    c.TACHYON_COMMIT_SHA = env("TACHYON_COMMIT_SHA", "ba69e3d2");\n' \
  >"$WORK_DIR/stamped.uc"
assert_eq "ba69e3d2" "$(read_sha "$WORK_DIR/stamped.uc")" "a stamped build must report its SHA"

# An unprocessed tree keeps the literal placeholder; treating it as a SHA would
# make every install look like a rollback.
printf '    c.TACHYON_COMMIT_SHA = env("TACHYON_COMMIT_SHA", "__COMPILED_COMMIT_SHA__");\n' \
  >"$WORK_DIR/placeholder.uc"
assert_eq "" "$(read_sha "$WORK_DIR/placeholder.uc")" "the build placeholder must not read as a SHA"

# The Makefile substitutes "unknown" when git is unavailable at build time. It
# never changes between builds, so it must not be compared as a SHA either.
printf '    c.TACHYON_COMMIT_SHA = env("TACHYON_COMMIT_SHA", "unknown");\n' \
  >"$WORK_DIR/unknown.uc"
assert_eq "" "$(read_sha "$WORK_DIR/unknown.uc")" "an unstamped build must not read as a SHA"

assert_eq "" "$(read_sha "")" "a missing constants module must yield no SHA"

# A rolled-back rebuild is only detectable by comparing SHAs, so the backend
# install must refuse to accept a mere presence check when the SHA did not move.
grep -Fq 'rolled the upgrade back' "$INSTALLER" ||
  fail "install.sh must fail loudly when the backend SHA did not move after install"

# An empty "before" SHA is not evidence of a fresh install: installed_backend_sha
# rejects both the placeholder and "unknown", which is exactly what a stale build
# on disk reports. Presence before the install is what separates an upgrade from a
# first install, so the rollback check must consult it — otherwise a rolled-back
# upgrade of an unstamped build reaches the "installed — continuing" branch and the
# run marches on over a failure.
sed -n '/^install_backend_package() {/,/^}/p' "$INSTALLER" >"$WORK_DIR/backend.sh"
[ -s "$WORK_DIR/backend.sh" ] || fail "install.sh must define install_backend_package"
grep -Fq 'backend_present_before' "$WORK_DIR/backend.sh" ||
  fail "install_backend_package must record whether tachyon was installed before the upgrade"
grep -Fq 'still reports no commit SHA' "$WORK_DIR/backend.sh" ||
  fail "an upgrade that leaves the installed build without a SHA must fail, not warn and continue"

# 120s was below the time the package hooks legitimately need to stop and restart
# the service; being killed there makes apk roll the transaction back.
for pm in apk opkg; do
  if grep -nE "(apk_with_lock_retry|run_logged_timeout) \"$pm\" 120 $pm (add|install)" "$INSTALLER" >/dev/null; then
    fail "$pm package install must not keep the 120s ceiling that rolled upgrades back"
  fi
done

# Bounding the hooks only helps the build being installed; during THIS upgrade the
# package manager runs the prerm of whatever is already on disk, and every release
# up to 1.2.66 shipped one with no timeout. It blocks on rc.common's `flock -w
# 1000`, so the installer has to free that lock itself before invoking the package
# manager — otherwise the pre-upgrade hook outlives apk's patience and the whole
# transaction is rolled back.
sed -n '/^function installer_release_init_lock() {/,/^}/p' "$INSTALLER" >"$WORK_DIR/lock.uc"
[ -s "$WORK_DIR/lock.uc" ] ||
  fail "install.sh must define installer_release_init_lock to unwedge the old prerm hook"

for pattern in '99-tachyon-wan|flock 1000' '/etc/init.d/tachyon'; do
  grep -Fq "$pattern" "$WORK_DIR/lock.uc" ||
    fail "installer_release_init_lock must clear '$pattern' waiters"
done

# Killing by name misses the actual holders. procd_lock() does `exec 1000>` on the
# lock file and `flock 1000` with no -w, so every background spawn inheriting fd 1000
# keeps the lock. On a live router the holders were watchdog workers, logread, the
# zapret2 supervisors, nfqws2 and a curl — none of which match a tachyon name.
grep -Fq '/fd/1000' "$WORK_DIR/lock.uc" ||
  fail "installer_release_init_lock must clear lock holders by descriptor, not only by name"
grep -Fq 'procd_tachyon' "$WORK_DIR/lock.uc" ||
  fail "installer_release_init_lock must only kill holders of Tachyon's own procd lock"

# The installer runs as a child of /usr/bin/tachyon during an upgrade, so a sweep that
# does not exclude its own ancestors kills the process performing the install.
grep -Fq '/stat' "$WORK_DIR/lock.uc" ||
  fail "installer_release_init_lock must walk /proc/<pid>/stat to spare its own ancestors"

# ucode resolves names lexically and does not hoist, so a call placed above the
# declaration silently becomes null and the lock is never released.
lock_decl="$(grep -n '^function installer_release_init_lock() {' "$INSTALLER" | head -1 | cut -d: -f1)"
lock_call="$(grep -n 'installer_release_init_lock();' "$INSTALLER" | head -1 | cut -d: -f1)"
[ -n "$lock_decl" ] && [ -n "$lock_call" ] ||
  fail "installer_release_init_lock must be both declared and called"
[ "$lock_decl" -lt "$lock_call" ] ||
  fail "installer_release_init_lock is called before its declaration (ucode does not hoist)"

# The lock has to be dropped as part of stopping the service, i.e. before any
# package is handed to the package manager.
sed -n '/^function installer_cleanup_legacy() {/,/^}/p' "$INSTALLER" >"$WORK_DIR/cleanup.uc"
grep -Fq 'installer_release_init_lock();' "$WORK_DIR/cleanup.uc" ||
  fail "installer_cleanup_legacy must release the init lock before the packages are installed"

printf 'PASS: installer rollback detection\n'
