#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_MAKEFILE="$ROOT_DIR/podkop/Makefile"
BUILD_SCRIPT="$ROOT_DIR/scripts/build.sh"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local file="$1"

  [ -r "$file" ] || fail "required file is missing: $file"
}

require_make_dep() {
  local package="$1"

  grep -Eq "DEPENDS:=.*(^|[[:space:]])\\+$package([[:space:]]|$)" "$PODKOP_MAKEFILE" ||
    fail "podkop/Makefile DEPENDS is missing +$package"
}

require_build_dep() {
  local variable="$1"
  local package="$2"

  grep -Eq "^${variable}=.*(^|[[:space:],])${package}([[:space:],\"]|$)" "$BUILD_SCRIPT" ||
    fail "scripts/build.sh ${variable} is missing $package"
}

require_package_dependency() {
  local package="$1"

  require_make_dep "$package"
  require_build_dep "BACKEND_DEPENDS_IPK" "$package"
  require_build_dep "BACKEND_DEPENDS_APK" "$package"
}

require_file "$PODKOP_MAKEFILE"
require_file "$BUILD_SCRIPT"
require_file "$PODKOP_LIB"

if grep -Rqs 'require("uci")' "$PODKOP_LIB"; then
  require_package_dependency "ucode-mod-uci"
fi

if grep -Rqs 'require("fs")' "$PODKOP_LIB"; then
  require_package_dependency "ucode-mod-fs"
fi

if grep -Rqs 'podkop_dnsmasq_failsafe_restore_raw' \
  "$ROOT_DIR/podkop/files/usr/bin" \
  "$ROOT_DIR/podkop/files/usr/lib" \
  "$ROOT_DIR/podkop/files/etc/init.d"; then
  fail "duplicated raw dnsmasq failsafe restore shell owner is present"
fi

printf 'package contract regression checks passed\n'
