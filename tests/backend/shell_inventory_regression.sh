#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODKOP_FILES="$ROOT_DIR/podkop/files"
PODKOP_BIN="$PODKOP_FILES/usr/bin/podkop"
PODKOP_LIB="$PODKOP_FILES/usr/lib"
PODKOP_INIT="$PODKOP_FILES/etc/init.d/podkop"
LUCI_ROOT="$ROOT_DIR/luci-app-podkop-plus/root"
LUCI_UCI_DEFAULTS="$LUCI_ROOT/etc/uci-defaults/50_luci-podkop-plus"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -d "$PODKOP_LIB" ] || fail "runtime library directory is missing"
[ -r "$PODKOP_BIN" ] || fail "podkop ucode entrypoint is missing"
[ -r "$PODKOP_INIT" ] || fail "podkop init.d entrypoint is missing"
[ -r "$LUCI_UCI_DEFAULTS" ] || fail "LuCI uci-defaults entrypoint is missing"

runtime_shell_files="$(find "$PODKOP_LIB" -type f -name '*.sh' -print)"
[ -z "$runtime_shell_files" ] ||
  fail "runtime library must not contain shell owners: $runtime_shell_files"

legacy_shell_owners='runtime_state\.sh|rules_nft_runtime\.sh|config_validation\.sh|sing_box_runtime\.sh|updates_runtime\.sh|updater\.sh|status_diagnostics\.sh|helpers\.sh|constants\.sh|subscription_runtime\.sh|byedpi\.sh|zapret\.sh|zapret2\.sh'
if find "$PODKOP_FILES" -type f -print | grep -E "$legacy_shell_owners" >/dev/null 2>&1; then
  fail "legacy runtime shell owner file returned under podkop/files"
fi

shell_scripts="$(
  find "$PODKOP_FILES" "$LUCI_ROOT" -type f -print |
    while IFS= read -r file; do
      first_line="$(sed -n '1p' "$file")"
      case "$first_line" in
        '#!'*'/bin/sh'*|'#!'*'/bin/ash'*|'#!'*'rc.common'*|'#!'*' bash'*|'#!'*'/bash'*)
          printf '%s\n' "${file#$ROOT_DIR/}"
          ;;
      esac
    done |
    sort
)"

expected_shell_scripts="$(
  printf '%s\n' \
    'luci-app-podkop-plus/root/etc/uci-defaults/50_luci-podkop-plus' \
    'podkop/files/etc/init.d/podkop'
)"

[ "$shell_scripts" = "$expected_shell_scripts" ] ||
  fail "unexpected packaged shell inventory:
expected:
$expected_shell_scripts
actual:
$shell_scripts"

grep -Fq '#!/usr/bin/ucode' "$PODKOP_BIN" ||
  fail "/usr/bin/podkop must remain a direct ucode executable"
grep -Fq 'function command_spec(command)' "$PODKOP_BIN" ||
  fail "/usr/bin/podkop must own command routing in ucode"
if grep -n -E '#!/bin/(ba)?sh|exec[[:space:]]+ucode|run_module\(|PODKOP_COMMAND' "$PODKOP_BIN" >/dev/null 2>&1; then
  fail "/usr/bin/podkop must not regress to a shell loader or shell router"
fi

grep -Fq 'PODKOP_INITD_UC="$PODKOP_LIB/service/initd.uc"' "$PODKOP_INIT" ||
  fail "init.d must delegate service orchestration to service/initd.uc"
grep -Fq 'initd_ucode start-service' "$PODKOP_INIT" ||
  fail "init.d start path must delegate to ucode"
grep -Fq 'initd_ucode stop-service' "$PODKOP_INIT" ||
  fail "init.d stop path must delegate to ucode"
grep -Fq 'initd_ucode reload-service' "$PODKOP_INIT" ||
  fail "init.d reload path must delegate to ucode"
grep -Fq 'initd_ucode trigger-plan' "$PODKOP_INIT" ||
  fail "init.d trigger decisions must be produced by ucode"

if grep -n -E '(^|[^[:alnum:]_])(uci|config_load|config_get|config_foreach|jsonfilter|nft|iptables|ip6?tables|sing-box|dnsmasq|curl|wget|opkg|apk)([[:space:]]|$)' "$PODKOP_INIT" >/dev/null 2>&1; then
  fail "init.d must not own UCI, routing, download, package, dnsmasq, nft, or sing-box decisions"
fi
if grep -n -E 'PODKOP_RELOAD_LOCK|PODKOP_URLTEST_SELECTOR_SWITCHES|capture_reload_state|populate_nft_runtime_sets|rebuild_nft_runtime|apply_pending_urltest_selector_switches' "$PODKOP_INIT" >/dev/null 2>&1; then
  fail "init.d must not own runtime state or reload decisions"
fi

grep -Fq '/usr/bin/podkop-plus luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate postinstall work to ucode"
if grep -n -E '(^|[^[:alnum:]_])(uci|rm|logger|rpcd|killall|jsonfilter|config_load|config_get)([[:space:]]|$)' "$LUCI_UCI_DEFAULTS" >/dev/null 2>&1; then
  fail "LuCI uci-defaults must not own cache, rpcd, logging, or UCI logic"
fi

printf 'shell inventory regression checks passed\n'
