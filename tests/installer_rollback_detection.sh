#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -r "$INSTALLER" ] || fail "install.sh must exist"

# Package manager errors are fatal. The old installer tried to infer success after
# a non-zero apk result and could accidentally accept a rolled-back upgrade.
grep -Fq 'install_core_transaction || fail "Tachyon package transaction failed"' "$INSTALLER" ||
  fail "package transaction failures must abort the install"
if grep -Fq 'Package manager reported non-critical errors during installation' "$INSTALLER"; then
  fail "installer must not convert package-manager failures into success"
fi

# Backend, LuCI and optional i18n are installed in one package-manager invocation.
grep -Fq 'pkg_install_local_bundle "$@"' "$INSTALLER" ||
  fail "release packages must be submitted as one transaction"
grep -Fq 'apk_run apk-transaction "$PACKAGE_TIMEOUT_SECONDS" add --allow-untrusted "$@"' "$INSTALLER" ||
  fail "APK install must be one bounded transaction"
grep -Fq 'run_logged_timeout opkg-transaction "$PACKAGE_TIMEOUT_SECONDS" opkg install' "$INSTALLER" ||
  fail "opkg install must be one bounded transaction"

# The historical 120s package timeout caused valid postinst hooks to be killed and
# APK to roll the upgrade back. Keep a larger package transaction budget.
grep -Fq 'PACKAGE_TIMEOUT_SECONDS=420' "$INSTALLER" ||
  fail "package transaction timeout must allow slow OpenWrt package hooks"

# Before the package manager runs, old rc.common/procd lock holders must be
# cleared. Old Tachyon releases could otherwise block prerm until APK rolled back.
grep -Fq 'release_tachyon_init_lock' "$INSTALLER" ||
  fail "installer must release stale Tachyon init locks"
grep -Fq '/proc/[0-9]*/fd/1000' "$INSTALLER" ||
  fail "installer must find leaked procd lock holders by fd 1000"
grep -Fq '*procd_tachyon*|*tachyon*lock*' "$INSTALLER" ||
  fail "fd sweep must be limited to Tachyon-owned locks"
grep -Fq 'is_protected_pid' "$INSTALLER" ||
  fail "installer must protect its own process ancestry"
grep -Fq '99-tachyon-wan|flock 1000|/etc/init.d/tachyon' "$INSTALLER" ||
  fail "installer must clear old rc.common waiters"

# The lock release must happen before packages are handed to apk/opkg.
awk '
  /^main\(\)/ { in_main=1 }
  in_main && /prepare_transaction/ && !prepare { prepare=NR }
  in_main && /install_core_transaction/ && !install { install=NR }
  END { exit !(prepare > 0 && install > prepare) }
' "$INSTALLER" || fail "stale init locks must be released before package install"

# A failed later stage restores the safety snapshot rather than leaving user
# configuration rewritten by package hooks.
grep -Fq 'TX_ACTIVE=1' "$INSTALLER" || fail "transaction recovery guard missing"
grep -Fq 'TX_COMMITTED=1' "$INSTALLER" || fail "transaction commit guard missing"
grep -Fq 'restore_snapshot' "$INSTALLER" || fail "failed transaction must restore snapshot"
grep -Fq 'chmod 0600 /etc/config/tachyon' "$INSTALLER" ||
  fail "restored Tachyon config must remain private"

# Successful completion is only printed after the runtime healthcheck and commit.
awk '
  /^main\(\)/ { in_main=1 }
  in_main && /healthcheck/ && !health { health=NR }
  in_main && /commit_transaction/ && !commit { commit=NR }
  in_main && /installed successfully/ && !success { success=NR }
  END { exit !(health > 0 && commit > health && success > commit) }
' "$INSTALLER" || fail "success must be gated by healthcheck and transaction commit"

printf 'PASS: installer rollback detection\n'
