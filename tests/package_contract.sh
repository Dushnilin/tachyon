#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_MAKEFILE="$ROOT_DIR/tachyon/Makefile"
TACHYON_CONFIG="$ROOT_DIR/tachyon/files/etc/config/tachyon"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

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

  grep -Eq "DEPENDS:=.*(^|[[:space:]])\\+$package([[:space:]]|$)" "$TACHYON_MAKEFILE" ||
    fail "tachyon/Makefile DEPENDS is missing +$package"
}

require_build_dep() {
  local variable="$1"
  local package="$2"

  grep -Eq "^${variable}=.*(^|[[:space:],])${package}([[:space:],\"]|$)" "$BUILD_SCRIPT" ||
    fail "build.sh ${variable} is missing $package"
}

require_package_dependency() {
  local package="$1"

  require_make_dep "$package"
  require_build_dep "BACKEND_DEPENDS_IPK" "$package"
  require_build_dep "BACKEND_DEPENDS_APK" "$package"
}

require_file "$TACHYON_MAKEFILE"
require_file "$TACHYON_CONFIG"
require_file "$BUILD_SCRIPT"
require_file "$TACHYON_LIB"

for conflict in https-dns-proxy nextdns luci-app-passwall luci-app-passwall2; do
  grep -E 'CONFLICTS:=' "$TACHYON_MAKEFILE" | grep -Fq "$conflict" ||
    fail "tachyon/Makefile conflicts are missing $conflict"
  grep -E '^BACKEND_CONFLICTS_IPK=' "$BUILD_SCRIPT" | grep -Fq "$conflict" ||
    fail "manual IPK conflicts are missing $conflict"
  grep -E '^BACKEND_DEPENDS_APK=' "$BUILD_SCRIPT" | grep -Fq "!$conflict" ||
    fail "manual APK conflicts are missing $conflict"
done

if grep -Fq 'coreutils-sort' "$TACHYON_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "unused coreutils-sort runtime dependency must not be packaged"
fi
grep -Fq "must use x.y.z format" "$TACHYON_MAKEFILE" ||
  fail "tachyon/Makefile must enforce the three-part release version contract"
grep -Fq 'APK_INTERNAL_VERSION="$RELEASE_VERSION"' "$BUILD_SCRIPT" ||
  fail "build.sh must use the exact three-part release version for APK metadata"
grep -Fq "option component_update_check_enabled '1'" "$TACHYON_CONFIG" ||
  fail "new installations must enable component update checks by default"
grep -Fq "option config_version '1.0.2'" "$TACHYON_CONFIG" ||
  fail "new installations must start at the current configuration schema version"
grep -Fq "list applied_migrations 'interface_sections'" "$TACHYON_CONFIG" ||
  fail "new installations must mark the interface section migration as applied"
grep -Fq "list applied_migrations 'enable_component_checks'" "$TACHYON_CONFIG" ||
  fail "new installations must mark the component check migration as applied"
grep -Fq '/usr/lib/tachyon/config/migration.uc migrate' "$TACHYON_MAKEFILE" ||
  fail "OpenWrt package postinst must run configuration migrations"
[ "$(grep -Fc '/usr/lib/tachyon/config/migration.uc migrate' "$BUILD_SCRIPT")" -ge 3 ] ||
  fail "manual IPK/APK package scripts must run configuration migrations after install and upgrade"

if grep -Rqs 'require("uci")' "$TACHYON_LIB"; then
  require_package_dependency "ucode-mod-uci"
fi

if grep -Rqs 'require("fs")' "$TACHYON_LIB"; then
  require_package_dependency "ucode-mod-fs"
fi

if grep -Rqs 'tachyon_dnsmasq_failsafe_restore_raw' \
  "$ROOT_DIR/tachyon/files/usr/bin" \
  "$ROOT_DIR/tachyon/files/usr/lib" \
  "$ROOT_DIR/tachyon/files/etc/init.d"; then
  fail "duplicated raw dnsmasq failsafe restore shell owner is present"
fi

printf 'package contract checks passed\n'
