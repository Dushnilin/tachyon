#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Structural checks in CLI and backend ucode
grep -Fq 'delete_section' "$ROOT_DIR/tachyon/files/usr/bin/tachyon" ||
  fail "tachyon CLI must declare delete_section command"
grep -Fq 'cascade_delete_section' "$ROOT_DIR/tachyon/files/usr/lib/config/connections.uc" ||
  fail "connections.uc must implement cascade_delete_section"
grep -Fq 'cli_delete_section' "$ROOT_DIR/tachyon/files/usr/lib/config/connections.uc" ||
  fail "connections.uc must export cli_delete_section"
grep -Fq 'priority_group' "$ROOT_DIR/tachyon/files/usr/lib/config/migration.uc" ||
  fail "migration.uc CHILD_ITEM_TYPES must include priority_group"
grep -Fq 'priority_level' "$ROOT_DIR/tachyon/files/usr/lib/config/migration.uc" ||
  fail "migration.uc CHILD_ITEM_TYPES must include priority_level"

# 2. Structural checks in LuCI JS view
grep -Fq 'cascadeDeleteSection' "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js" ||
  fail "section.js must implement cascadeDeleteSection"
grep -Fq 'cascadeDeleteSection(section_id)' "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js" ||
  fail "section.js remove handler must invoke cascadeDeleteSection"
grep -Fq 'cascadeDeleteSection' "$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/tachyon.js" ||
  fail "tachyon.js must invoke cascadeDeleteSection on section remove/add"

# 3. Installer safety contract: never mutate user configuration before it is
# snapshotted, and verify the resulting runtime before declaring success.
INSTALLER="$ROOT_DIR/install.sh"
grep -Fq 'snapshot_state()' "$INSTALLER" ||
  fail "install.sh must provide a recovery snapshot stage"
grep -Fq '/etc/config/tachyon' "$INSTALLER" ||
  fail "installer snapshot/healthcheck must cover /etc/config/tachyon"
grep -Fq 'chmod 0600 /etc/config/tachyon' "$INSTALLER" ||
  fail "installer must keep Tachyon config private"
grep -Fq 'healthcheck()' "$INSTALLER" ||
  fail "installer must verify the installed runtime"
grep -Fq '/usr/share/luci/menu.d/luci-app-tachyon.json' "$INSTALLER" ||
  fail "installer healthcheck must verify the LuCI menu"

awk '
  /^main\(\)/ { in_main=1 }
  in_main && /snapshot_state/ && !snapshot { snapshot=NR }
  in_main && /install_core_transaction/ && !install { install=NR }
  END { exit !(snapshot > 0 && install > snapshot) }
' "$INSTALLER" || fail "installer must snapshot configuration before package hooks run"

printf 'section cascade deletion and installer checks passed\n'
