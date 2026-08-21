#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="$ROOT_DIR/tachyon/Makefile"
BUILD_SH="$ROOT_DIR/build.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$MAKEFILE" ] || fail "tachyon/Makefile not found"
[ -f "$BUILD_SH" ] || fail "build.sh not found"

# Release packages are produced by build.sh, while the OpenWrt feed build uses
# tachyon/Makefile. Both must ship an identical file inventory or installs
# silently lose hotplug handlers, the agent CGI and reset defaults.
required_sources=(
  "files/etc/init.d/tachyon"
  "files/etc/config/tachyon"
  "files/usr/bin/tachyon"
  "files/etc/hotplug.d/iface/99-tachyon-wan-monitor"
  "files/usr/lib/cgi-bin/tachyon-agent"
  "files/usr/share/tachyon/servicecheck_profiles.json"
)

for rel in "${required_sources[@]}"; do
  [ -f "$ROOT_DIR/tachyon/$rel" ] || fail "source file missing: tachyon/$rel"
  grep -Fq "$rel" "$MAKEFILE" || fail "Makefile no longer ships $rel — update tests/package_inventory.sh"
  grep -Fq "$rel" "$BUILD_SH" || fail "build.sh does not package $rel (diverges from Makefile)"
done

# Derived file installed only by the packaging recipes (not present in files/).
grep -Fq '/usr/lib/tachyon/defaults/config' "$MAKEFILE" ||
  fail "Makefile no longer installs defaults/config"
grep -Fq 'usr/lib/tachyon/defaults/config' "$BUILD_SH" ||
  fail "build.sh does not package /usr/lib/tachyon/defaults/config (reset_settings would break)"

# Secrets-bearing files must not be world-readable in release packages.
grep -Eq 'chmod 0600 .*etc/config/tachyon' "$BUILD_SH" ||
  fail "build.sh must enforce mode 0600 on /etc/config/tachyon"
grep -Eq 'chmod 0600 .*usr/lib/tachyon/defaults/config' "$BUILD_SH" ||
  fail "build.sh must enforce mode 0600 on defaults/config"

printf 'package inventory checks passed\n'
