#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_FILES="$ROOT_DIR/forkop/files"
FORKOP_BIN="$FORKOP_FILES/usr/bin/forkop"
FORKOP_LIB="$FORKOP_FILES/usr/lib"
FORKOP_INIT="$FORKOP_FILES/etc/init.d/forkop"
LUCI_ROOT="$ROOT_DIR/luci-app-forkop/root"
LUCI_UCI_DEFAULTS="$LUCI_ROOT/etc/uci-defaults/50_luci-forkop"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -d "$FORKOP_LIB" ] || fail "runtime library directory is missing"
[ -r "$FORKOP_BIN" ] || fail "forkop ucode entrypoint is missing"
[ -r "$FORKOP_INIT" ] || fail "forkop init.d entrypoint is missing"
[ -r "$LUCI_UCI_DEFAULTS" ] || fail "LuCI uci-defaults entrypoint is missing"

runtime_shell_files="$(find "$FORKOP_LIB" -type f -name '*.sh' -print)"
[ -z "$runtime_shell_files" ] ||
  fail "runtime library must not contain shell owners: $runtime_shell_files"

legacy_shell_owners='runtime_state\.sh|rules_nft_runtime\.sh|config_validation\.sh|sing_box_runtime\.sh|updates_runtime\.sh|updater\.sh|status_diagnostics\.sh|helpers\.sh|constants\.sh|subscription_runtime\.sh|byedpi\.sh|zapret\.sh|zapret2\.sh'
if find "$FORKOP_FILES" -type f -print | grep -E "$legacy_shell_owners" >/dev/null 2>&1; then
  fail "legacy runtime shell owner file returned under forkop/files"
fi

shell_scripts="$(
  find "$FORKOP_FILES" "$LUCI_ROOT" -type f -print |
    while IFS= read -r file; do
      first_line="$(sed -n '1p' "$file")"
      case "$first_line" in
        '#!'*'/bin/sh'*|'#!'*'/bin/ash'*|'#!'*'rc.common'*|'#!'*' bash'*|'#!'*'/bash'*)
          printf '%s\n' "${file#$ROOT_DIR/}"
          ;;
      esac
    done |
    LC_ALL=C sort
)"

expected_shell_scripts="$(
  printf '%s\n' \
    'luci-app-forkop/root/etc/uci-defaults/50_luci-forkop' \
    'forkop/files/etc/init.d/forkop' |
    LC_ALL=C sort
)"

[ "$shell_scripts" = "$expected_shell_scripts" ] ||
  fail "unexpected packaged shell inventory:
expected:
$expected_shell_scripts
actual:
$shell_scripts"

grep -Fq '#!/usr/bin/ucode' "$FORKOP_BIN" ||
  fail "/usr/bin/forkop must remain a direct ucode executable"
grep -Fq 'function command_spec(command)' "$FORKOP_BIN" ||
  fail "/usr/bin/forkop must own command routing in ucode"
if grep -n -E '#!/bin/(ba)?sh|exec[[:space:]]+ucode|run_module\(|FORKOP_COMMAND' "$FORKOP_BIN" >/dev/null 2>&1; then
  fail "/usr/bin/forkop must not regress to a shell loader or shell router"
fi

grep -Fq 'FORKOP_INITD_UC="$FORKOP_LIB/service/initd.uc"' "$FORKOP_INIT" ||
  fail "init.d must delegate service orchestration to service/initd.uc"
grep -Fq 'initd_ucode start-service' "$FORKOP_INIT" ||
  fail "init.d start path must delegate to ucode"
grep -Fq 'initd_ucode stop-service' "$FORKOP_INIT" ||
  fail "init.d stop path must delegate to ucode"
grep -Fq 'initd_ucode reload-service' "$FORKOP_INIT" ||
  fail "init.d reload path must delegate to ucode"
grep -Fq 'initd_ucode trigger-plan' "$FORKOP_INIT" ||
  fail "init.d trigger decisions must be produced by ucode"

if grep -n -E '(^|[^[:alnum:]_])(uci|config_load|config_get|config_foreach|jsonfilter|nft|iptables|ip6?tables|sing-box|dnsmasq|curl|wget|opkg|apk)([[:space:]]|$)' "$FORKOP_INIT" >/dev/null 2>&1; then
  fail "init.d must not own UCI, routing, download, package, dnsmasq, nft, or sing-box decisions"
fi
if grep -n -E 'FORKOP_RELOAD_LOCK|FORKOP_URLTEST_SELECTOR_SWITCHES|capture_reload_state|populate_nft_runtime_sets|rebuild_nft_runtime|apply_pending_urltest_selector_switches' "$FORKOP_INIT" >/dev/null 2>&1; then
  fail "init.d must not own runtime state or reload decisions"
fi

grep -Fq '/usr/bin/forkop luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate postinstall work to ucode"
if grep -n -E '(^|[^[:alnum:]_])(uci|rm|logger|rpcd|killall|jsonfilter|config_load|config_get)([[:space:]]|$)' "$LUCI_UCI_DEFAULTS" >/dev/null 2>&1; then
  fail "LuCI uci-defaults must not own cache, rpcd, logging, or UCI logic"
fi

printf 'shell inventory checks passed\n'
