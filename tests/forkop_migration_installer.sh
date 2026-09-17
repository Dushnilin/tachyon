#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
MAKEFILE="$ROOT_DIR/tachyon/Makefile"
MIGRATION="$ROOT_DIR/tachyon/files/usr/lib/config/migration.uc"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -r "$INSTALLER" ] || fail "install.sh is missing"
[ -r "$MAKEFILE" ] || fail "tachyon/Makefile is missing"
[ -r "$MIGRATION" ] || fail "runtime migration module is missing"

# Installer v3 deliberately does not duplicate legacy conversion logic. Package
# postinst owns the move into /etc/config/tachyon and the runtime migration module
# owns schema conversion.
if grep -Fq 'installer_cleanup_legacy' "$INSTALLER"; then
  fail "installer must not embed legacy cleanup/migration ownership"
fi
if grep -Fq 'migrate-podkop' "$INSTALLER"; then
  fail "installer must delegate legacy schema migration to package/runtime code"
fi

grep -Fq 'if [ -f /etc/config/netshift ]; then' "$MAKEFILE" ||
  fail "package postinst must detect NetShift config"
grep -Fq 'elif [ -f /etc/config/forkop ]; then' "$MAKEFILE" ||
  fail "package postinst must detect Forkop config"
grep -Fq 'elif [ -f /etc/config/podkop ]; then' "$MAKEFILE" ||
  fail "package postinst must detect Podkop config"
grep -Fq '/usr/lib/tachyon/config/migration.uc migrate-podkop' "$MAKEFILE" ||
  fail "legacy package postinst must call migrate-podkop"
grep -Fq 'migrate-podkop' "$MIGRATION" ||
  fail "runtime migration module must expose migrate-podkop"

# Before package hooks can move/remove legacy files, the installer takes a safety
# snapshot of every supported legacy config.
for path in \
  /etc/config/netshift \
  /etc/config/forkop \
  /etc/config/forkop_plus \
  /etc/config/podkop \
  /etc/config/podkop_plus; do
  grep -Fq "$path" "$INSTALLER" ||
    fail "installer recovery snapshot must include $path"
done

grep -Fq 'snapshot_state || fail "Could not create recovery snapshot"' "$INSTALLER" ||
  fail "recovery snapshot must be created before package installation"
awk '
  /^main\(\)/ { in_main=1 }
  in_main && /snapshot_state/ && !snapshot { snapshot=NR }
  in_main && /install_core_transaction/ && !install { install=NR }
  END { exit !(snapshot > 0 && install > snapshot) }
' "$INSTALLER" || fail "legacy configs must be snapshotted before package hooks run"

printf 'PASS: legacy migration ownership and installer recovery contract\n'
