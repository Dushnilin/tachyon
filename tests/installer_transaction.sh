#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -r "$INSTALLER" ] || fail "install.sh is missing"
sh -n "$INSTALLER" || fail "install.sh must be valid POSIX shell"

grep -Fq 'mkdir "$LOCK_DIR"' "$INSTALLER" || fail "installer lock must use atomic mkdir"
grep -Fq 'Removing stale installer lock' "$INSTALLER" || fail "stale installer lock must be recoverable"

grep -Fq 'trap cleanup EXIT' "$INSTALLER" || fail "cleanup must run on EXIT"
grep -Fq 'trap on_int INT' "$INSTALLER" || fail "INT handler missing"
grep -Fq 'on_int() { exit 130; }' "$INSTALLER" || fail "INT must return 130"
grep -Fq 'on_term() { exit 143; }' "$INSTALLER" || fail "TERM must return 143"
if grep -Fq 'trap cleanup EXIT HUP INT TERM' "$INSTALLER"; then
  fail "cleanup-only signal trap can resume installation after a signal"
fi

awk '
  /^main\(\)/ { in_main=1 }
  in_main && /sync_time/ && !sync { sync=NR }
  in_main && /ensure_bootstrap_ucode_runtime/ && !bootstrap { bootstrap=NR }
  END { exit !(sync > 0 && bootstrap > sync) }
' "$INSTALLER" || fail "sync_time must happen before bootstrap package/network operations"

grep -Fq 'apk --wait "$APK_LOCK_WAIT_SECONDS"' "$INSTALLER" || fail "apk --wait support is required"
grep -Fq 'diagnose_apk_lock' "$INSTALLER" || fail "APK lock diagnosis is required"
if grep -Fq 'sanitize_apk_world' "$INSTALLER"; then
  fail "installer must not mutate /etc/apk/world as generic APK cleanup"
fi

grep -Fq 'TACHYON_DOWNLOAD_BYTES=' "$INSTALLER" || fail "release download size accounting missing"
grep -Fq 'free_kb /tmp' "$INSTALLER" || fail "/tmp free-space check missing"
grep -Fq 'MIN_TMP_HEADROOM_KB' "$INSTALLER" || fail "/tmp safety headroom missing"

grep -Fq 'pkg_install_local_bundle "$@"' "$INSTALLER" || fail "bundle transaction helper is not used"
grep -Fq 'apk-transaction' "$INSTALLER" || fail "APK transaction tag missing"
grep -Fq 'opkg-transaction' "$INSTALLER" || fail "opkg transaction tag missing"

awk '
  /^main\(\)/ { in_main=1 }
  in_main && /download_release/ && !download { download=NR }
  in_main && /snapshot_state/ && !snapshot { snapshot=NR }
  in_main && /prepare_transaction/ && !prepare { prepare=NR }
  in_main && /install_core_transaction/ && !install { install=NR }
  in_main && /healthcheck/ && !health { health=NR }
  in_main && /commit_transaction/ && !commit { commit=NR }
  END { exit !(download > 0 && snapshot > download && prepare > snapshot && install > prepare && health > install && commit > health) }
' "$INSTALLER" || fail "transaction phase ordering is unsafe"

grep -Fq 'restore_snapshot' "$INSTALLER" || fail "failed transaction must restore recovery snapshot"
grep -Fq 'TX_COMMITTED' "$INSTALLER" || fail "transaction commit guard missing"

grep -Fq '/fd/1000' "$INSTALLER" || fail "procd fd1000 lock-holder cleanup missing"
grep -Fq 'is_protected_pid' "$INSTALLER" || fail "installer must protect its own process ancestry"
grep -Fq '99-tachyon-wan|flock 1000|/etc/init.d/tachyon' "$INSTALLER" || fail "legacy init-lock waiter cleanup missing"

for pattern in 'tachyon_' 'luci-app-tachyon_' 'luci-i18n-tachyon-ru_' 'sha256sums.txt'; do
  grep -Fq "$pattern" "$INSTALLER" || fail "release asset contract missing: $pattern"
done
grep -Fq 'Checksum mismatch' "$INSTALLER" || fail "checksum failure path missing"

if grep -qi 'jsdelivr' "$INSTALLER"; then
  fail "GitHub release assets must not use the jsDelivr Git-tree endpoint"
fi

grep -Fq '/usr/bin/tachyon component_action sing_box "$_action"' "$INSTALLER" || fail "sing-box must be delegated to component_action"
grep -Fq 'require("core.common")' "$INSTALLER" || fail "runtime healthcheck must require core.common"

export TACHYON_INSTALLER_TEST=1
# shellcheck source=/dev/null
. "$INSTALLER"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
LOCK_DIR="$TEST_TMP/lock"
acquire_lock || fail "first atomic lock acquisition failed"
[ -f "$LOCK_DIR/pid" ] || fail "lock PID was not recorded"
release_lock
[ ! -e "$LOCK_DIR" ] || fail "lock was not released"

start="$(date +%s)"
if run_with_deadline 1 sh -c 'sleep 5'; then
  fail "deadline watchdog accepted an over-deadline command"
fi
elapsed="$(( $(date +%s) - start ))"
[ "$elapsed" -lt 4 ] || fail "deadline watchdog did not stop the command promptly"
run_with_deadline 3 sh -c 'exit 0' || fail "deadline helper changed a successful exit status"

printf 'PASS: ultimate installer transaction contract\n'
