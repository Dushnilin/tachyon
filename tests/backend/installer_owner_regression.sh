#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$INSTALLER" ] || fail "install.sh is missing"

if grep -n -E '(^|[;&|[:space:]])uci[[:space:]]+-q|command_exists[[:space:]]+uci|/usr/bin/uci' "$INSTALLER" >/dev/null; then
  fail "install.sh must not own UCI reads/writes through shell"
fi

shell_sing_box_owner_symbols='REQUIRED_SING_BOX_VERSION|SING_BOX_EXTENDED_|SING_BOX_MANAGED_SERVICE_MARKER|remove_old_sing_box_if_needed|install_managed_sing_box_service_script|remove_managed_sing_box_service_script|disable_sing_box_service_config|prepare_sing_box_service_disabled|prepare_sing_box_package_service_install|stop_podkop_for_sing_box_install|pkg_install_sing_box_variant|pkg_install_name_downgrade|pkg_remove_sing_box_conflict|resolve_sing_box_extended_release|install_sing_box_extended_(package|binary)|restore_sing_box_after_failed|move_file_to_backup|validate_extended_sing_box_binary|archive-member-path|sing-box-extended-arch-suffix|sing-box-extended-asset-url|sing-box-extended-package-asset-url'
if grep -n -E "$shell_sing_box_owner_symbols" "$INSTALLER" >/dev/null; then
  fail "install.sh must not contain shell sing-box install/runtime ownership"
fi

grep -Fq 'ensure_bootstrap_package "ucode-mod-fs"' "$INSTALLER" ||
  fail "install.sh must bootstrap ucode-mod-fs before embedded ucode helper use"
grep -Fq 'ensure_bootstrap_package "ucode-mod-uci"' "$INSTALLER" ||
  fail "install.sh must bootstrap ucode-mod-uci before embedded UCI helper use"

grep -Fq '/usr/bin/podkop-plus component_action sing_box "$action"' "$INSTALLER" ||
  fail "selected sing-box install must delegate to podkop-plus component_action"
for action in install_stable install_tiny install_extended install_extended_compressed; do
  grep -Fq "action=\"$action\"" "$INSTALLER" ||
    fail "selected sing-box installer is missing action mapping: $action"
done

grep -Fq 'run_args([ INSTALLER_PODKOP_PLUS_BIN, "restore_dnsmasq" ])' "$INSTALLER" ||
  fail "installer dnsmasq restore must prefer installed podkop-plus ucode entrypoint"
grep -Fq 'else if (mode == "dnsmasq-failsafe-restore")' "$INSTALLER" ||
  fail "dnsmasq restore fallback mode must remain available in embedded ucode helper"
grep -Fq 'else if (mode == "installer-cleanup-legacy")' "$INSTALLER" ||
  fail "installer cleanup must be exposed as an embedded ucode mode"
grep -Fq 'else if (mode == "installer-post-install")' "$INSTALLER" ||
  fail "installer post-install must be exposed as an embedded ucode mode"
grep -Fq 'install_json_ucode installer-cleanup-legacy' "$INSTALLER" ||
  fail "install.sh cleanup must delegate to embedded ucode"
grep -Fq 'install_json_ucode installer-post-install' "$INSTALLER" ||
  fail "install.sh post-install must delegate to embedded ucode"

if grep -n -E 'restore_podkop_dnsmasq_failsafe|remember_service_state|stop_conflicting_services|deactivate_original_podkop_if_present|remove_conflicting_dns_proxy|pkg_remove_if_installed|pkg_remove_matching_prefix|pkg_list_installed_names' "$INSTALLER" >/dev/null 2>&1; then
  fail "install.sh must not keep shell cleanup/remove service owners"
fi
if grep -n -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|/etc/init\.d/rpcd[[:space:]]+reload|/etc/init\.d/podkop-plus[[:space:]]+(start|stop|disable|enable|restart)|/etc/init\.d/podkop[[:space:]]+(stop|disable)' "$INSTALLER" >/dev/null 2>&1; then
  fail "install.sh shell must not own service/cache lifecycle actions"
fi

awk '
  /^[[:space:]]*main\(\)[[:space:]]*\{/ { in_main = 1 }
  in_main && /ensure_bootstrap_ucode_runtime/ { ensure = NR }
  in_main && /decide_i18n_installation/ { i18n = NR }
  in_main && /install_packages/ { install_packages = NR }
  in_main && /install_selected_sing_box/ { sing_box = NR }
  in_main && /^[[:space:]]*\}/ { in_main = 0 }
  END {
    if (ensure > 0 && i18n > 0 && ensure < i18n &&
        install_packages > 0 && sing_box > 0 && install_packages < sing_box)
      exit 0
    exit 1
  }
' "$INSTALLER" || fail "install.sh main order must bootstrap ucode before UCI reads and install backend before sing-box component_action"

helper="$WORK_DIR/install-json.uc"
awk '
  /cat > "\$helper_path" <<'\''EOF'\''/ { capture = 1; next }
  capture && /^EOF$/ { exit }
  capture { print }
' "$INSTALLER" > "$helper"
[ -s "$helper" ] || fail "failed to extract embedded installer ucode helper"

printf '%s\n' '{"tag_name":"v-test"}' | ucode "$helper" release-tag | grep -Fxq 'v-test' ||
  fail "embedded helper release-tag mode must parse release JSON"

cat >"$WORK_DIR/opkg" <<'SH'
#!/usr/bin/env sh
case "$1" in
  list-installed)
    printf '%s\n' \
      'https-dns-proxy - 1.0' \
      'luci-app-https-dns-proxy - 1.0' \
      'luci-i18n-https-dns-proxy-ru - 1.0'
    ;;
  remove)
    shift
    [ "$1" = "--force-depends" ] && shift
    printf '%s\n' "$1" >> "$PODKOP_INSTALLER_OPKG_LOG"
    ;;
esac
exit 0
SH
chmod 0755 "$WORK_DIR/opkg"

: >"$WORK_DIR/opkg.log"
printf '%s\n' '1' |
  PATH="$WORK_DIR:$PATH" \
  PODKOP_INSTALLER_OPKG_LOG="$WORK_DIR/opkg.log" \
  PODKOP_INSTALLER_PODKOP_PLUS_INIT="$WORK_DIR/missing-podkop-plus-init" \
  PODKOP_INSTALLER_PODKOP_PLUS_BIN="$WORK_DIR/missing-podkop-bin" \
  PODKOP_INSTALLER_PODKOP_PLUS_LIB="$WORK_DIR/missing-podkop-lib" \
  PODKOP_INSTALLER_PODKOP_PLUS_UCI_DEFAULTS="$WORK_DIR/missing-uci-defaults" \
  PODKOP_INSTALLER_PODKOP_PLUS_LUCI_VIEW="$WORK_DIR/missing-luci-view" \
  PODKOP_INSTALLER_MENU_JSON="$WORK_DIR/missing-menu.json" \
  PODKOP_INSTALLER_ACL_JSON="$WORK_DIR/missing-acl.json" \
  PODKOP_INSTALLER_RU_LMO="$WORK_DIR/missing-ru.lmo" \
  PODKOP_INSTALLER_EN_LMO="$WORK_DIR/missing-en.lmo" \
  PODKOP_INSTALLER_RU_LUA="$WORK_DIR/missing-ru.lua" \
  PODKOP_INSTALLER_EN_LUA="$WORK_DIR/missing-en.lua" \
  PODKOP_INSTALLER_ORIGINAL_PODKOP_INIT="$WORK_DIR/missing-original-init" \
  PODKOP_UCI_STATE_FILE="$WORK_DIR/empty-uci.state" \
    ucode "$helper" installer-cleanup-legacy >"$WORK_DIR/conflict-state.env" 2>"$WORK_DIR/conflict.err"

grep -Fxq 'https-dns-proxy' "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove confirmed https-dns-proxy conflict"
grep -Fxq 'luci-app-https-dns-proxy' "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove confirmed https-dns-proxy LuCI package"
grep -Fxq 'luci-i18n-https-dns-proxy-ru' "$WORK_DIR/opkg.log" ||
  fail "installer cleanup must remove confirmed https-dns-proxy i18n packages"

write_fake_podkop_init() {
  cat >"$WORK_DIR/podkop-plus-init" <<'SH'
#!/usr/bin/env sh
case "$1" in
  enabled) exit 0 ;;
  status) printf '%s\n' running; exit 0 ;;
  stop|disable|enable|start|restart) printf '%s\n' "$1" >> "$PODKOP_INSTALLER_INIT_LOG"; exit 0 ;;
esac
exit 0
SH
  chmod 0755 "$WORK_DIR/podkop-plus-init"
}

write_fake_podkop_init

cat >"$WORK_DIR/podkop-bin" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$PODKOP_INSTALLER_BIN_LOG"
case "$1" in
  get_status) printf '%s\n' '{"running":1}' ;;
esac
exit 0
SH
chmod 0755 "$WORK_DIR/podkop-bin"

: >"$WORK_DIR/init.log"
: >"$WORK_DIR/bin.log"
state="$WORK_DIR/state.env"
PODKOP_INSTALLER_PODKOP_PLUS_INIT="$WORK_DIR/podkop-plus-init" \
PODKOP_INSTALLER_PODKOP_PLUS_BIN="$WORK_DIR/podkop-bin" \
PODKOP_INSTALLER_PODKOP_PLUS_LIB="$WORK_DIR/podkop-lib" \
PODKOP_INSTALLER_PODKOP_PLUS_UCI_DEFAULTS="$WORK_DIR/uci-defaults" \
PODKOP_INSTALLER_PODKOP_PLUS_LUCI_VIEW="$WORK_DIR/luci-view" \
PODKOP_INSTALLER_MENU_JSON="$WORK_DIR/menu.json" \
PODKOP_INSTALLER_ACL_JSON="$WORK_DIR/acl.json" \
PODKOP_INSTALLER_RU_LMO="$WORK_DIR/ru.lmo" \
PODKOP_INSTALLER_EN_LMO="$WORK_DIR/en.lmo" \
PODKOP_INSTALLER_RU_LUA="$WORK_DIR/ru.lua" \
PODKOP_INSTALLER_EN_LUA="$WORK_DIR/en.lua" \
PODKOP_INSTALLER_ORIGINAL_PODKOP_INIT="$WORK_DIR/missing-original-init" \
PODKOP_INSTALLER_INIT_LOG="$WORK_DIR/init.log" \
PODKOP_INSTALLER_BIN_LOG="$WORK_DIR/bin.log" \
PODKOP_UCI_STATE_FILE="$WORK_DIR/empty-uci.state" \
  ucode "$helper" installer-cleanup-legacy >"$state"

grep -Fxq 'PODKOP_WAS_ENABLED=1' "$state" ||
  fail "installer cleanup must export previous enabled state"
grep -Fxq 'PODKOP_WAS_RUNNING=1' "$state" ||
  fail "installer cleanup must export previous running state"
grep -Fxq 'stop' "$WORK_DIR/init.log" ||
  fail "installer cleanup must stop old Podkop Plus through ucode owner"
grep -Fxq 'disable' "$WORK_DIR/init.log" ||
  fail "installer cleanup must disable old Podkop Plus through ucode owner"
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/bin.log" ||
  fail "installer cleanup must prefer backend restore_dnsmasq"

write_fake_podkop_init
touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
: >"$WORK_DIR/init.log"
PODKOP_INSTALLER_PODKOP_PLUS_INIT="$WORK_DIR/podkop-plus-init" \
PODKOP_INSTALLER_RPCD_INIT="$WORK_DIR/missing-rpcd" \
PODKOP_INSTALLER_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
PODKOP_INSTALLER_LATEST_VERSION_CACHE="$WORK_DIR/latest.cache" \
PODKOP_INSTALLER_SYSTEM_INFO_CACHE="$WORK_DIR/system-info.json" \
PODKOP_INSTALLER_SERVER_COUNTRY_CACHE="$WORK_DIR/server-country.json" \
PODKOP_INSTALLER_SING_BOX_VERSION_CACHE="$WORK_DIR/sing-box-version" \
PODKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE="$WORK_DIR/tmp-system-info.json" \
PODKOP_WAS_ENABLED=1 \
PODKOP_WAS_RUNNING=1 \
PODKOP_INSTALLER_INIT_LOG="$WORK_DIR/init.log" \
  ucode "$helper" installer-post-install

if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "installer post-install must clear LuCI caches through ucode owner"
fi
grep -Fxq 'enable' "$WORK_DIR/init.log" ||
  fail "installer post-install must restore enabled state through ucode owner"
grep -Fxq 'start' "$WORK_DIR/init.log" ||
  fail "installer post-install must restore running state through ucode owner"

printf 'installer ownership regression checks passed\n'
