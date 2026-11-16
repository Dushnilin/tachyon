#!/usr/bin/env bash
# Test offline package install resilience and suppression of midnight update notifications for auto-update targets
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INSTALLER_UC="$TACHYON_LIB/components/installer.uc"
ACTION_UC="$TACHYON_LIB/components/action.uc"
UPDATES_UC="$TACHYON_LIB/components/updates.uc"
TELEGRAM_UC="$TACHYON_LIB/service/telegram.uc"
RUNTIME_UC="$TACHYON_LIB/service/telegram/runtime.uc"

[ -f "$INSTALLER_UC" ] || fail "installer.uc not found"
[ -f "$ACTION_UC" ] || fail "action.uc not found"
[ -f "$UPDATES_UC" ] || fail "updates.uc not found"
[ -f "$TELEGRAM_UC" ] || fail "telegram.uc not found"
[ -f "$RUNTIME_UC" ] || fail "runtime.uc not found"

# 1. installer.uc must have offline fallback in pkg_tx_install_files on APK
grep -Fq 'res = pkg_tx_run_with_lock("Installing packages (offline fallback)' "$INSTALLER_UC" ||
  fail "installer.uc pkg_tx_install_files must have offline fallback"

# 2. action.uc must check verify_package_post_install before action_fail on APK
grep -Fq 'verify_package_post_install("tachyon", latest_version)' "$ACTION_UC" ||
  fail "action.uc install_tachyon must verify package post-install"

grep -Fq 'verify_package_post_install("tachyon", target_tag)' "$ACTION_UC" ||
  fail "action.uc install_tachyon_version must verify package post-install"

# 3. runtime.uc must define is_component_auto_update_active and check it in check_notified_updates
grep -Fq 'function is_component_auto_update_active' "$RUNTIME_UC" ||
  fail "runtime.uc must define is_component_auto_update_active"

grep -Fq 'if (is_component_auto_update_active(name))' "$RUNTIME_UC" ||
  fail "runtime.uc check_notified_updates must skip active auto-update components"

# 4. telegram.uc and runtime.uc must support notify-auto-update-failed
grep -Fq 'mode == "notify-auto-update-failed"' "$TELEGRAM_UC" ||
  fail "telegram.uc must handle notify-auto-update-failed CLI mode"

grep -Fq 'function notify_auto_update_failed_cli' "$RUNTIME_UC" ||
  fail "runtime.uc must define notify_auto_update_failed_cli"

# 5. updates.uc must define notify_component_auto_update_failed and call it in finish_component_job
grep -Fq 'function notify_component_auto_update_failed' "$UPDATES_UC" ||
  fail "updates.uc must define notify_component_auto_update_failed"

finish_job_func="$(sed -n '/function finish_component_job/,/^}/p' "$UPDATES_UC")"
printf '%s\n' "$finish_job_func" | grep -q 'notify_component_auto_update_failed(component' ||
  fail "finish_component_job must call notify_component_auto_update_failed on error"

printf 'auto-update offline and midnight notification suppression checks passed\n'
