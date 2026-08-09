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

# 120s was below the time the package hooks legitimately need to stop and restart
# the service; being killed there makes apk roll the transaction back.
for pm in apk opkg; do
  if grep -nE "(apk_with_lock_retry|run_logged_timeout) \"$pm\" 120 $pm (add|install)" "$INSTALLER" >/dev/null; then
    fail "$pm package install must not keep the 120s ceiling that rolled upgrades back"
  fi
done

printf 'PASS: installer rollback detection\n'
