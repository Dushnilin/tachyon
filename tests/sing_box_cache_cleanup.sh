#!/usr/bin/env bash
# Core switching between different families (or between extended and compressed)
# must clear the sing-box cache database to prevent bbolt schema/data corruption (issue #130).
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

should_clear() {
  ucode "$ACTION_UC" should-clear-sing-box-cache "$1" "$2" 2>/dev/null
}

# 1. Family transitions must trigger cache cleanup:
# Extended / Compressed -> Upstream / Tiny
should_clear "extended" "stable" || fail "extended -> stable must trigger cache clear"
should_clear "extended" "tiny" || fail "extended -> tiny must trigger cache clear"
should_clear "extended-compressed" "stable" || fail "extended-compressed -> stable must trigger cache clear"
should_clear "extended-compressed" "tiny" || fail "extended-compressed -> tiny must trigger cache clear"

# Upstream -> Extended / Compressed
should_clear "stable" "extended" || fail "stable -> extended must trigger cache clear"
should_clear "tiny" "extended-compressed" || fail "tiny -> extended-compressed must trigger cache clear"

# To / from tachyon-core
should_clear "extended" "tachyon-core" || fail "extended -> tachyon-core must trigger cache clear"
should_clear "tachyon-core" "extended" || fail "tachyon-core -> extended must trigger cache clear"
should_clear "tachyon-core" "stable" || fail "tachyon-core -> stable must trigger cache clear"
should_clear "tachyon-core" "tiny" || fail "tachyon-core -> tiny must trigger cache clear"
should_clear "stable" "tachyon-core" || fail "stable -> tachyon-core must trigger cache clear"
should_clear "tiny" "tachyon-core" || fail "tiny -> tachyon-core must trigger cache clear"

# Between extended and extended-compressed (compressed storage variant)
should_clear "extended" "extended-compressed" || fail "extended -> extended-compressed must trigger cache clear"
should_clear "extended-compressed" "extended" || fail "extended-compressed -> extended must trigger cache clear"

# LX transitions
should_clear "lx" "stable" || fail "lx -> stable must trigger cache clear"
should_clear "lx" "tachyon-core" || fail "lx -> tachyon-core must trigger cache clear"
should_clear "lx" "extended" || fail "lx -> extended must trigger cache clear"

# Fresh installation
should_clear "" "stable" || fail "empty -> stable must trigger cache clear"
should_clear "not-installed" "tachyon-core" || fail "not-installed -> tachyon-core must trigger cache clear"

# 2. Same-family updates must NOT clear cache unnecessarily:
if should_clear "extended" "extended"; then
  fail "extended -> extended update must NOT clear cache"
fi
if should_clear "tachyon-core" "tachyon-core"; then
  fail "tachyon-core -> tachyon-core update must NOT clear cache"
fi
if should_clear "stable" "stable"; then
  fail "stable -> stable update must NOT clear cache"
fi
if should_clear "tiny" "tiny"; then
  fail "tiny -> tiny update must NOT clear cache"
fi

# 3. Test actual file removal by clear-sing-box-cache
mkdir -p /tmp/sing-box
touch /tmp/sing-box/cache.db
touch /tmp/sing-box/cache.db.lock
touch /tmp/sing-box/cache.db-journal

[ -f /tmp/sing-box/cache.db ] || fail "failed to create test cache.db fixture"

ucode "$ACTION_UC" clear-sing-box-cache "unit-test"

if [ -f /tmp/sing-box/cache.db ] || [ -f /tmp/sing-box/cache.db.lock ] || [ -f /tmp/sing-box/cache.db-journal ]; then
  fail "clear-sing-box-cache failed to remove /tmp/sing-box/cache.db*"
fi

printf 'PASS: sing_box_cache_cleanup\n'
