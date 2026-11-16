#!/usr/bin/env bash
# Tests core cache cleanup and rollback-safe backup/restore helpers in components/action.uc.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/components" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

ACTION_UC="$TACHYON_LIB/components/action.uc"
[ -f "$ACTION_UC" ] || fail "missing $ACTION_UC"

# 1. Test actual file removal by clear-core-cache
mkdir -p /tmp/tachyon-core
touch /tmp/tachyon-core/cache.db
touch /tmp/tachyon-core/cache.db.lock
touch /tmp/tachyon-core/cache.db-journal

[ -f /tmp/tachyon-core/cache.db ] || fail "failed to create test cache.db fixture"

ucode "$ACTION_UC" clear-core-cache "unit-test"

if [ -f /tmp/tachyon-core/cache.db ] || [ -f /tmp/tachyon-core/cache.db.lock ] || [ -f /tmp/tachyon-core/cache.db-journal ]; then
  fail "clear-core-cache failed to remove /tmp/tachyon-core/cache.db*"
fi

# 2. Test rollback-safe backup and restore of cache.db across core change failure
printf 'prev-core-fakeip-records' > /tmp/tachyon-core/cache.db
ucode "$ACTION_UC" backup-core-cache
[ ! -f /tmp/tachyon-core/cache.db ] || fail "backup-core-cache should move cache.db to .rollback-bak"
[ -f /tmp/tachyon-core/cache.db.rollback-bak ] || fail "backup-core-cache did not create .rollback-bak"

# Simulate failed replacement creating an incompatible cache.db before rollback
printf 'corrupt-new-core-db' > /tmp/tachyon-core/cache.db
touch /tmp/tachyon-core/cache.db-lock
ucode "$ACTION_UC" restore-core-cache-backup
[ -f /tmp/tachyon-core/cache.db ] || fail "restore-core-cache-backup did not restore cache.db"
[ ! -f /tmp/tachyon-core/cache.db.rollback-bak ] || fail "restore-core-cache-backup left .rollback-bak behind"
[ ! -f /tmp/tachyon-core/cache.db-lock ] || fail "restore-core-cache-backup did not clean lock file"
[ "$(cat /tmp/tachyon-core/cache.db)" = "prev-core-fakeip-records" ] ||
  fail "restore-core-cache-backup did not preserve original cache.db contents"

# Simulate successful switch cleanup
ucode "$ACTION_UC" backup-core-cache
ucode "$ACTION_UC" cleanup-core-cache-backup
[ ! -f /tmp/tachyon-core/cache.db.rollback-bak ] || fail "cleanup-core-cache-backup did not remove .rollback-bak"

printf 'PASS: tachyon_core_cache_cleanup\n'
