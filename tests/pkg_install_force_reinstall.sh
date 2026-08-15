#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# is_apk() probes for an apk binary, so the package manager under test is chosen
# by what is on PATH. Both fake dirs shadow the real tools.
mkdir -p "$WORK_DIR/opkg-bin" "$WORK_DIR/apk-bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/opkg-bin/opkg"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/apk-bin/apk"
chmod +x "$WORK_DIR/opkg-bin/opkg" "$WORK_DIR/apk-bin/apk"

install_command() {
  local pm_dir="$1"
  local force="$2"
  shift 2

  local force_pm=""
  [ "$pm_dir" = "opkg-bin" ] && force_pm="opkg"
  [ "$pm_dir" = "apk-bin" ] && force_pm="apk"

  TACHYON_FORCE_PKG_MANAGER="$force_pm" PATH="$WORK_DIR/$pm_dir:$PATH" command ucode -L "$TACHYON_LIB" "$ACTION_UC" \
    pkg-install-files-command "$force" "$@"
}

# opkg treats an .ipk whose version equals the installed one as already
# installed. Without --force-reinstall a rebuild published under the same tag is
# downloaded, "installed" successfully, and never actually written.
OPKG_FORCED="$(install_command opkg-bin 1 /tmp/a.ipk /tmp/b.ipk)"
case "$OPKG_FORCED" in
  *--force-reinstall*) ;;
  *) fail "opkg install must carry --force-reinstall when forced, got: $OPKG_FORCED" ;;
esac

# A plain version upgrade needs no forcing; opkg installs it on its own.
OPKG_PLAIN="$(install_command opkg-bin 0 /tmp/a.ipk /tmp/b.ipk)"
case "$OPKG_PLAIN" in
  *--force-reinstall*) fail "opkg install must not force when not asked, got: $OPKG_PLAIN" ;;
esac

for expected_flag in --force-overwrite --force-downgrade; do
  case "$OPKG_PLAIN" in
    *"$expected_flag"*) ;;
    *) fail "opkg install lost $expected_flag, got: $OPKG_PLAIN" ;;
  esac
done

case "$OPKG_PLAIN" in
  *"/tmp/a.ipk"*"/tmp/b.ipk"*) ;;
  *) fail "opkg install must keep the file list in order, got: $OPKG_PLAIN" ;;
esac

# apk add always writes the file it is handed, and has no --force-reinstall, so
# forcing must not alter its argument list.
APK_FORCED="$(install_command apk-bin 1 /tmp/a.apk)"
APK_PLAIN="$(install_command apk-bin 0 /tmp/a.apk)"
assert_eq "$APK_PLAIN" "$APK_FORCED" "apk command must be identical whether or not reinstall is forced"

case "$APK_PLAIN" in
  *--force-reinstall*) fail "apk has no --force-reinstall, got: $APK_PLAIN" ;;
esac

# Arguments are shell-quoted individually by command_from_args.
case "$APK_PLAIN" in
  *"'apk' 'add' '--allow-untrusted'"*"'/tmp/a.apk'"*) ;;
  *) fail "apk install command malformed, got: $APK_PLAIN" ;;
esac

printf 'PASS: pkg install force reinstall\n'
