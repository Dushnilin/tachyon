#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_FILES="$ROOT_DIR/tachyon/files"
TACHYON_BIN="$TACHYON_FILES/usr/bin/tachyon"
TACHYON_LIB="$TACHYON_FILES/usr/lib"
TACHYON_INIT="$TACHYON_FILES/etc/init.d/tachyon"
LUCI_ROOT="$ROOT_DIR/luci-app-tachyon/root"
LUCI_UCI_DEFAULTS="$LUCI_ROOT/etc/uci-defaults/50_luci-tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -d "$TACHYON_LIB" ] || fail "runtime library directory is missing"
[ -r "$TACHYON_BIN" ] || fail "tachyon ucode entrypoint is missing"
[ -r "$TACHYON_INIT" ] || fail "tachyon init.d entrypoint is missing"
[ -r "$LUCI_UCI_DEFAULTS" ] || fail "LuCI uci-defaults entrypoint is missing"

runtime_shell_files="$(find "$TACHYON_LIB" -type f -name '*.sh' -print)"
[ -z "$runtime_shell_files" ] ||
  fail "runtime library must not contain shell owners: $runtime_shell_files"

legacy_shell_owners='runtime_state\.sh|rules_nft_runtime\.sh|config_validation\.sh|sing_box_runtime\.sh|updates_runtime\.sh|updater\.sh|status_diagnostics\.sh|helpers\.sh|constants\.sh|subscription_runtime\.sh|byedpi\.sh|zapret\.sh|zapret2\.sh'
if find "$TACHYON_FILES" -type f -print | grep -E "$legacy_shell_owners" >/dev/null 2>&1; then
  fail "legacy runtime shell owner file returned under tachyon/files"
fi

shell_scripts="$(
  find "$TACHYON_FILES" "$LUCI_ROOT" -type f -print |
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
    'luci-app-tachyon/root/etc/uci-defaults/50_luci-tachyon' \
    'tachyon/files/etc/init.d/tachyon' |
    LC_ALL=C sort
)"

[ "$shell_scripts" = "$expected_shell_scripts" ] ||
  fail "unexpected packaged shell inventory:
expected:
$expected_shell_scripts
actual:
$shell_scripts"

grep -Fq '#!/usr/bin/ucode' "$TACHYON_BIN" ||
  fail "/usr/bin/tachyon must remain a direct ucode executable"
grep -Fq 'function command_spec(command)' "$TACHYON_BIN" ||
  fail "/usr/bin/tachyon must own command routing in ucode"
if grep -n -E '#!/bin/(ba)?sh|exec[[:space:]]+ucode|run_module\(|TACHYON_COMMAND' "$TACHYON_BIN" >/dev/null 2>&1; then
  fail "/usr/bin/tachyon must not regress to a shell loader or shell router"
fi

grep -Fq 'TACHYON_INITD_UC="$TACHYON_LIB/service/initd.uc"' "$TACHYON_INIT" ||
  fail "init.d must delegate service orchestration to service/initd.uc"
grep -Fq 'initd_ucode start-service' "$TACHYON_INIT" ||
  fail "init.d start path must delegate to ucode"
grep -Fq 'initd_ucode stop-service' "$TACHYON_INIT" ||
  fail "init.d stop path must delegate to ucode"
grep -Fq 'initd_ucode reload-service' "$TACHYON_INIT" ||
  fail "init.d reload path must delegate to ucode"
grep -Fq 'initd_ucode trigger-plan' "$TACHYON_INIT" ||
  fail "init.d trigger decisions must be produced by ucode"

if grep -n -E '(^|[^[:alnum:]_])(uci|config_load|config_get|config_foreach|jsonfilter|nft|iptables|ip6?tables|sing-box|dnsmasq|curl|wget|opkg|apk)([[:space:]]|$)' "$TACHYON_INIT" >/dev/null 2>&1; then
  fail "init.d must not own UCI, routing, download, package, dnsmasq, nft, or sing-box decisions"
fi
if grep -n -E 'TACHYON_RELOAD_LOCK|TACHYON_URLTEST_SELECTOR_SWITCHES|capture_reload_state|populate_nft_runtime_sets|rebuild_nft_runtime|apply_pending_urltest_selector_switches' "$TACHYON_INIT" >/dev/null 2>&1; then
  fail "init.d must not own runtime state or reload decisions"
fi

grep -Fq '/usr/bin/tachyon luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate postinstall work to ucode"
if grep -n -E '(^|[^[:alnum:]_])(uci|rm|logger|rpcd|killall|jsonfilter|config_load|config_get)([[:space:]]|$)' "$LUCI_UCI_DEFAULTS" >/dev/null 2>&1; then
  fail "LuCI uci-defaults must not own cache, rpcd, logging, or UCI logic"
fi

printf 'shell inventory checks passed\n'
