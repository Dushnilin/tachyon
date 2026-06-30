#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_BIN="$ROOT_DIR/podkop/files/usr/bin/podkop"
PODKOP_LIB="$ROOT_DIR/podkop/files/usr/lib"
PACKAGE_UC="$PODKOP_LIB/service/package.uc"
PODKOP_MAKEFILE="$ROOT_DIR/podkop/Makefile"
LUCI_UCI_DEFAULTS="$ROOT_DIR/luci-app-podkop-plus/root/etc/uci-defaults/50_luci-podkop-plus"
BUILD_SCRIPT="$ROOT_DIR/scripts/build.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$PACKAGE_UC" ] ||
  fail "service/package.uc must own package lifecycle logic"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "service/package.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$PACKAGE_UC" ||
  fail "service/package.uc must import core.uci"
grep -Fq 'package_prerm: [ "service/package.uc", "prerm", 0 ]' "$PODKOP_BIN" ||
  fail "podkop entrypoint must dispatch package prerm cleanup through service/package.uc"
grep -Fq 'luci_postinst: [ "service/package.uc", "luci-postinst", 0 ]' "$PODKOP_BIN" ||
  fail "podkop entrypoint must dispatch LuCI postinstall cleanup through service/package.uc"
grep -Fq '#!/bin/sh' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must remain a shell script because OpenWrt default_postinst runs it through shell"
grep -Fq '/usr/bin/podkop-plus luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate cache/rpcd handling to ucode"
if grep -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|logger -t "podkop-plus"' "$LUCI_UCI_DEFAULTS" >/dev/null; then
  fail "LuCI uci-defaults must not own cache/logger shell logic"
fi

if grep -n -E 'grep -q "105 podkopplus"|sed -i "/105 podkopplus|podkop_dont_touch_dhcp=.*uci|cp /etc/config/podkop_plus|rm -f /tmp/luci-indexcache|killall -HUP rpcd' "$PODKOP_MAKEFILE" "$BUILD_SCRIPT" >/dev/null; then
  fail "package scripts must not keep backend/LuCI lifecycle business logic in shell"
fi
grep -Fq '#!/usr/bin/ucode' "$PODKOP_MAKEFILE" ||
  fail "podkop Makefile package hooks must use ucode entrypoints"
grep -Fq '/usr/bin/podkop-plus package_prerm' "$PODKOP_MAKEFILE" ||
  fail "podkop Makefile prerm must delegate cleanup to package_prerm"
grep -Fq '/usr/bin/podkop-plus luci_postinst' "$BUILD_SCRIPT" ||
  fail "manual package builder must delegate LuCI cache/rpcd handling to luci_postinst"

legacy_config="$WORK_DIR/podkop_plus"
new_config="$WORK_DIR/podkop-plus"
printf 'config podkop_plus legacy\n' >"$legacy_config"
PODKOP_CONFIG="$new_config" PODKOP_LEGACY_CONFIG="$legacy_config" \
  ucode -L "$PODKOP_LIB" "$PACKAGE_UC" preinst
[ "$(cat "$new_config")" = "config podkop_plus legacy" ] ||
  fail "package preinst must copy legacy config when new config is absent"

printf 'existing config\n' >"$new_config"
PODKOP_CONFIG="$new_config" PODKOP_LEGACY_CONFIG="$legacy_config" \
  ucode -L "$PODKOP_LIB" "$PACKAGE_UC" preinst
[ "$(cat "$new_config")" = "existing config" ] ||
  fail "package preinst must not overwrite existing config"

rt_tables="$WORK_DIR/rt_tables"
cat >"$rt_tables" <<'EOF'
100 main
105 podkopplus
200 custom
EOF
PODKOP_PACKAGE_TEST_MODE=1 PODKOP_RT_TABLES="$rt_tables" \
  ucode -L "$PODKOP_LIB" "$PACKAGE_UC" prerm
if grep -Fq '105 podkopplus' "$rt_tables"; then
  fail "package prerm must remove the legacy podkopplus routing table entry"
fi
grep -Fq '200 custom' "$rt_tables" ||
  fail "package prerm must preserve unrelated rt_tables entries"

touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
PODKOP_PACKAGE_TEST_MODE=1 PODKOP_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
  ucode -L "$PODKOP_LIB" "$PACKAGE_UC" luci-postinst
if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "luci-postinst must remove LuCI index cache files"
fi

cat >"$WORK_DIR/podkop-bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PODKOP_RESTORE_LOG:?}"
SH
chmod 0755 "$WORK_DIR/podkop-bin"

cat >"$WORK_DIR/dont-touch.state" <<'EOF_UCI'
podkop-plus.settings=settings
podkop-plus.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 podkopplus\n' >"$WORK_DIR/rt_tables_dont_touch"
: >"$WORK_DIR/restore-dont-touch.log"
PODKOP_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
PODKOP_RESTORE_LOG="$WORK_DIR/restore-dont-touch.log" \
PODKOP_BIN="$WORK_DIR/podkop-bin" \
PODKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
PODKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
PODKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
PODKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
PODKOP_RT_TABLES="$WORK_DIR/rt_tables_dont_touch" \
  ucode -L "$PODKOP_LIB" "$PACKAGE_UC" prerm
[ ! -s "$WORK_DIR/restore-dont-touch.log" ] ||
  fail "package prerm must skip dnsmasq restore when dont_touch_dhcp is enabled"

cat >"$WORK_DIR/restore.state" <<'EOF_UCI'
podkop-plus.settings=settings
podkop-plus.settings.dont_touch_dhcp=0
EOF_UCI
printf '105 podkopplus\n' >"$WORK_DIR/rt_tables_restore"
: >"$WORK_DIR/restore.log"
PODKOP_UCI_STATE_FILE="$WORK_DIR/restore.state" \
PODKOP_RESTORE_LOG="$WORK_DIR/restore.log" \
PODKOP_BIN="$WORK_DIR/podkop-bin" \
PODKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
PODKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
PODKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
PODKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
PODKOP_RT_TABLES="$WORK_DIR/rt_tables_restore" \
  ucode -L "$PODKOP_LIB" "$PACKAGE_UC" prerm
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/restore.log" ||
  fail "package prerm must restore dnsmasq when dont_touch_dhcp is disabled"

printf 'package lifecycle regression checks passed\n'
