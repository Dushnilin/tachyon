#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
PACKAGE_UC="$TACHYON_LIB/service/package.uc"
TACHYON_MAKEFILE="$ROOT_DIR/tachyon/Makefile"
LUCI_UCI_DEFAULTS="$ROOT_DIR/luci-app-tachyon/root/etc/uci-defaults/50_luci-tachyon"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
export TACHYON_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"

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
grep -Fq 'package_prerm: [ "service/package.uc", "prerm", 1 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch package prerm cleanup through service/package.uc"
grep -Fq 'package_postinst: [ "service/package.uc", "postinst", 0 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch package postinst recovery through service/package.uc"
grep -Fq 'luci_postinst: [ "service/package.uc", "luci-postinst", 0 ]' "$TACHYON_BIN" ||
  fail "tachyon entrypoint must dispatch LuCI postinstall cleanup through service/package.uc"
grep -Fq '#!/bin/sh' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must remain a shell script because OpenWrt default_postinst runs it through shell"
grep -Fq '/usr/bin/tachyon luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate cache/rpcd handling to ucode"
if grep -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|logger -t "tachyon"' "$LUCI_UCI_DEFAULTS" >/dev/null; then
  fail "LuCI uci-defaults must not own cache/logger shell logic"
fi

if grep -n -E 'grep -q "105 tachyon"|sed -i "/105 tachyon|tachyon_dont_touch_dhcp=.*uci|cp /etc/config/tachyon|rm -f /tmp/luci-indexcache|killall -HUP rpcd' "$TACHYON_MAKEFILE" "$BUILD_SCRIPT" >/dev/null; then
  fail "package scripts must not keep backend/LuCI lifecycle business logic in shell"
fi
grep -Fq '#!/usr/bin/ucode' "$TACHYON_MAKEFILE" ||
  fail "tachyon Makefile package hooks must use ucode entrypoints"

# The prerm hook lives inside a Makefile define, so ucode_syntax_lint.sh never
# sees it. A syntax error there only surfaces on a router mid-upgrade.
sed -n '/define Package\/tachyon\/prerm/,/^endef/p' "$TACHYON_MAKEFILE" |
  sed '1d;$d' >"$WORK_DIR/prerm-hook.uc"
[ -s "$WORK_DIR/prerm-hook.uc" ] ||
  fail "tachyon Makefile must define a prerm hook"
ucode -c -o /dev/null "$WORK_DIR/prerm-hook.uc" 2>"$WORK_DIR/prerm-hook.err" ||
  fail "tachyon Makefile prerm hook must compile: $(cat "$WORK_DIR/prerm-hook.err")"

# apk runs prerm as pre-upgrade and rolls the whole transaction back if it does
# not finish, so the cleanup call — which executes the OLD installed build — must
# be bounded from the outside.
grep -Fq 'timeout' "$WORK_DIR/prerm-hook.uc" ||
  fail "tachyon Makefile prerm must bound package_prerm so a stuck cleanup cannot roll the upgrade back"
grep -Fq '/usr/bin/tachyon package_prerm' "$TACHYON_MAKEFILE" ||
  fail "tachyon Makefile prerm must delegate cleanup to package_prerm"
grep -Fq '/usr/bin/tachyon package_postinst' "$TACHYON_MAKEFILE" ||
  fail "tachyon Makefile postinst must restore a service that was running before upgrade"
grep -Fq '/usr/bin/tachyon package_prerm upgrade' "$BUILD_SCRIPT" ||
  fail "manual APK pre-upgrade must record and stop the running service"

# build.sh assembles the APK and IPK packages itself, so a fix applied only to
# tachyon/Makefile never reaches them — that is how the shipped 1.2.66 kept an old
# unbounded pre-upgrade hook after the Makefile had been fixed. Every prerm-family
# hook written here must bound the cleanup and must not pass its status outwards:
# `exit(system(...))` returns a raw wait status, so a killed cleanup (the sweep used
# to SIGKILL its own parent, giving 128+119=247) aborted the upgrade and rolled the
# new build back.
for hook in 'backend-pre-upgrade.sh' 'backend-pre-deinstall.sh'; do
  sed -n "/cat > \"\$scripts_dir\/$hook\" <<'EOF'/,/^EOF$/p" "$BUILD_SCRIPT" >"$WORK_DIR/$hook"
  [ -s "$WORK_DIR/$hook" ] || fail "build.sh must write $hook"
  grep -Fq 'timeout' "$WORK_DIR/$hook" ||
    fail "build.sh $hook must bound package_prerm so a stuck cleanup cannot roll the upgrade back"
  # Comments are stripped first: the hook documents the `exit(system(...))` form it
  # replaced, and matching prose would fail the very file that fixed the bug.
  if sed 's|//.*||' "$WORK_DIR/$hook" | grep -Fq 'exit(system('; then
    fail "build.sh $hook must not return the cleanup's status; a nonzero hook aborts the upgrade"
  fi
done

# Three functions write a $control_dir/prerm (backend, app, i18n); only the
# backend one runs the ucode cleanup, so the extraction is scoped to that function.
# Scoped by the next function header rather than by `^}`: the hook body itself
# contains lines starting with `}`, which would truncate the extraction mid-hook.
sed -n "/^write_backend_ipk_control() {/,/^write_app_ipk_control() {/p" "$BUILD_SCRIPT" |
  sed -n "/cat > \"\$control_dir\/prerm\" <<'EOF'/,/^EOF$/p" >"$WORK_DIR/ipk-prerm.sh"
[ -s "$WORK_DIR/ipk-prerm.sh" ] || fail "build.sh must write a backend IPK prerm"
grep -Fq 'timeout' "$WORK_DIR/ipk-prerm.sh" ||
  fail "build.sh IPK prerm must bound package_prerm"

# These hooks live inside heredocs, so ucode_syntax_lint.sh never compiles them: a
# syntax error would only surface on a router mid-upgrade, as a rolled-back package.
for hook in 'backend-pre-upgrade.sh' 'backend-pre-deinstall.sh' 'ipk-prerm.sh'; do
  sed '1d;$d' "$WORK_DIR/$hook" >"$WORK_DIR/$hook.body.uc"
  ucode -c -o /dev/null "$WORK_DIR/$hook.body.uc" 2>"$WORK_DIR/$hook.err" ||
    fail "build.sh $hook must compile: $(cat "$WORK_DIR/$hook.err")"
done

grep -Fq '/usr/bin/tachyon package_postinst' "$BUILD_SCRIPT" ||
  fail "manual packages must restore a service that was running before upgrade"
grep -Fq '/usr/bin/tachyon luci_postinst' "$BUILD_SCRIPT" ||
  fail "manual package builder must delegate LuCI cache/rpcd handling to luci_postinst"
if grep -n -E 'Package/tachyon/preinst|copy_legacy_config|TACHYON_LEGACY_CONFIG|mode == "preinst"' \
  "$TACHYON_MAKEFILE" "$BUILD_SCRIPT" "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "package hooks and runtime service must not own configuration migration"
fi

rt_tables="$WORK_DIR/rt_tables"
cat >"$rt_tables" <<'EOF'
100 main
105 tachyon
200 custom
EOF
TACHYON_PACKAGE_TEST_MODE=1 TACHYON_RT_TABLES="$rt_tables" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm
if grep -Fq '105 tachyon' "$rt_tables"; then
  fail "package prerm must remove the Tachyon routing table entry"
fi
grep -Fq '200 custom' "$rt_tables" ||
  fail "package prerm must preserve unrelated rt_tables entries"

cat >"$WORK_DIR/tachyon-init" <<'SH'
#!/usr/bin/env bash
grep -Fq '105 tachyon' "${TACHYON_RT_TABLES:?}" || exit 1
printf '%s\n' 'stop-with-route-table' >>"${TACHYON_STOP_LOG:?}"
SH
chmod 0755 "$WORK_DIR/tachyon-init"
cat >"$WORK_DIR/stop-order.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 tachyon\n' >"$WORK_DIR/rt_tables_stop_order"
: >"$WORK_DIR/stop-order.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/stop-order.state" \
TACHYON_INIT="$WORK_DIR/tachyon-init" \
TACHYON_STOP_LOG="$WORK_DIR/stop-order.log" \
TACHYON_BIN="$WORK_DIR/missing-tachyon-bin" \
TACHYON_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
TACHYON_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
TACHYON_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
TACHYON_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
TACHYON_RT_TABLES="$WORK_DIR/rt_tables_stop_order" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm
grep -Fxq 'stop-with-route-table' "$WORK_DIR/stop-order.log" ||
  fail "package prerm must stop Tachyon before removing its routing table name"
[ ! -s "$WORK_DIR/rt_tables_stop_order" ] ||
  fail "package prerm must remove the routing table name after Tachyon stops"

touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
TACHYON_PACKAGE_TEST_MODE=1 TACHYON_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" luci-postinst
if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "luci-postinst must remove LuCI index cache files"
fi

cat >"$WORK_DIR/tachyon-bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TACHYON_RESTORE_LOG:?}"
SH
chmod 0755 "$WORK_DIR/tachyon-bin"

cat >"$WORK_DIR/dont-touch.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 tachyon\n' >"$WORK_DIR/rt_tables_dont_touch"
: >"$WORK_DIR/restore-dont-touch.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
TACHYON_RESTORE_LOG="$WORK_DIR/restore-dont-touch.log" \
TACHYON_BIN="$WORK_DIR/tachyon-bin" \
TACHYON_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
TACHYON_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
TACHYON_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
TACHYON_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
TACHYON_RT_TABLES="$WORK_DIR/rt_tables_dont_touch" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm
if grep -Fxq 'restore_dnsmasq' "$WORK_DIR/restore-dont-touch.log"; then
  echo "=== Content of restore-dont-touch.log: ==="
  cat "$WORK_DIR/restore-dont-touch.log"
  echo "=== End of Content ==="
  fail "package prerm must skip dnsmasq restore when dont_touch_dhcp is enabled"
fi

cat >"$WORK_DIR/restore.state" <<'EOF_UCI'
tachyon.settings=settings
tachyon.settings.dont_touch_dhcp=0
EOF_UCI
printf '105 tachyon\n' >"$WORK_DIR/rt_tables_restore"
: >"$WORK_DIR/restore.log"
TACHYON_UCI_STATE_FILE="$WORK_DIR/restore.state" \
TACHYON_RESTORE_LOG="$WORK_DIR/restore.log" \
TACHYON_BIN="$WORK_DIR/tachyon-bin" \
TACHYON_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
TACHYON_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
TACHYON_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
TACHYON_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
TACHYON_RT_TABLES="$WORK_DIR/rt_tables_restore" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/restore.log" ||
  fail "package prerm must restore dnsmasq when dont_touch_dhcp is disabled"

cat >"$WORK_DIR/upgrade-init" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) exit "${TACHYON_FAKE_STATUS:-0}" ;;
  start) printf '%s\n' start >>"${TACHYON_START_LOG:?}" ;;
esac
SH
chmod 0755 "$WORK_DIR/upgrade-init"
: >"$WORK_DIR/upgrade-start.log"
: >"$WORK_DIR/rt_tables_upgrade"
TACHYON_PACKAGE_TEST_MODE=1 \
TACHYON_INIT="$WORK_DIR/upgrade-init" \
TACHYON_START_LOG="$WORK_DIR/upgrade-start.log" \
TACHYON_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm upgrade
[ -f "$TACHYON_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must remember a running service"
TACHYON_PACKAGE_TEST_MODE=1 \
TACHYON_INIT="$WORK_DIR/upgrade-init" \
TACHYON_START_LOG="$WORK_DIR/upgrade-start.log" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" postinst
grep -Fxq start "$WORK_DIR/upgrade-start.log" ||
  fail "package postinst must restart a service that was running before upgrade"
[ ! -e "$TACHYON_PACKAGE_UPGRADE_STATE" ] ||
  fail "package postinst must clear the consumed upgrade state"

TACHYON_PACKAGE_TEST_MODE=1 \
TACHYON_FAKE_STATUS=1 \
TACHYON_INIT="$WORK_DIR/upgrade-init" \
TACHYON_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm upgrade
[ ! -e "$TACHYON_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not mark an already stopped service"

# Every init.d call goes through rc.common's `flock -w 1000`, so a wedged start
# or retry_start_on_wan_up holding that lock used to stall pre-upgrade for a
# quarter of an hour — long enough for apk (or the installer) to kill the hook and
# roll the new build back. The hook must give up on its own instead.
cat >"$WORK_DIR/hanging-init" <<'SH'
#!/usr/bin/env bash
sleep 5
SH
chmod 0755 "$WORK_DIR/hanging-init"
: >"$WORK_DIR/rt_tables_hang"
hang_start="$(date +%s)"
TACHYON_HOOK_COMMAND_TIMEOUT=2 \
TACHYON_INIT="$WORK_DIR/hanging-init" \
TACHYON_BIN="$WORK_DIR/hanging-init" \
TACHYON_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
TACHYON_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
TACHYON_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
TACHYON_RT_TABLES="$WORK_DIR/rt_tables_hang" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm upgrade
hang_elapsed="$(( $(date +%s) - hang_start ))"
[ "$hang_elapsed" -lt 30 ] ||
  fail "package pre-upgrade must abandon a blocked init call, took ${hang_elapsed}s"

# Same for the restart in postinst: a start that never returns must not hold the
# package transaction open.
printf '1\n' >"$TACHYON_PACKAGE_UPGRADE_STATE"
hang_start="$(date +%s)"
TACHYON_HOOK_START_TIMEOUT=2 \
TACHYON_INIT="$WORK_DIR/hanging-init" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" postinst
hang_elapsed="$(( $(date +%s) - hang_start ))"
[ "$hang_elapsed" -lt 30 ] ||
  fail "package postinst must abandon a blocked service start, took ${hang_elapsed}s"
[ ! -e "$TACHYON_PACKAGE_UPGRADE_STATE" ] ||
  fail "package postinst must clear the upgrade state even when the start times out"

# The kill sweep must not take out the process running it. `ps | grep /usr/bin/tachyon`
# matches the hook itself — /usr/bin/tachyon is what invoked it — so the naive sweep
# killed its own parent, the parent died on SIGKILL, and apk saw the pre-upgrade hook
# exit 247 (128+119) and rolled the whole upgrade back. Verified by running the sweep
# under a parent whose command line matches the pattern: the parent must survive.
sweep_parent="$WORK_DIR/usr-bin-tachyon-lookalike"
cat >"$sweep_parent" <<'SH'
#!/usr/bin/env bash
# Command line contains the BIN_PATH the sweep greps for, exactly as the real
# /usr/bin/tachyon parent does.
"$@"
printf '%s\n' parent-survived >>"${TACHYON_SWEEP_LOG:?}"
SH
chmod 0755 "$sweep_parent"
: >"$WORK_DIR/sweep.log"
: >"$WORK_DIR/rt_tables_sweep"
TACHYON_SWEEP_LOG="$WORK_DIR/sweep.log" \
  "$sweep_parent" env \
  TACHYON_HOOK_COMMAND_TIMEOUT=5 \
  TACHYON_BIN="$sweep_parent" \
  TACHYON_INIT="$WORK_DIR/upgrade-init" \
  TACHYON_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
  TACHYON_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
  TACHYON_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
  TACHYON_RT_TABLES="$WORK_DIR/rt_tables_sweep" \
  TACHYON_SWEEP_LOG="$WORK_DIR/sweep.log" \
  ucode -L "$TACHYON_LIB" "$PACKAGE_UC" prerm upgrade || true
grep -Fxq 'parent-survived' "$WORK_DIR/sweep.log" ||
  fail "package prerm killed its own parent process; apk reports the hook as exit 247 and rolls the upgrade back"

# Holders of procd's lock descriptor are cleared by descriptor, not by name: the
# processes found pinning it on a router (logread, nfqws2, curl) match no tachyon
# name pattern, and while any of them lives every init call blocks in flock.
grep -Fq '/fd/1000' "$PACKAGE_UC" ||
  fail "package prerm must clear procd lock holders by descriptor"
grep -Fq 'procd_tachyon' "$PACKAGE_UC" ||
  fail "package prerm must only kill holders of Tachyon's own procd lock"

printf 'package lifecycle checks passed\n'
