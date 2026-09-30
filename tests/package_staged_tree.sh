#!/usr/bin/env bash
# Asserts on the package tree build.sh actually stages, not on the sources.
#
# The release artifacts come from build.sh, and the shipped package contents were
# once wrong in three ways at once: the rpcd ACL was in no package, tachyon-read
# was staged but left non-executable, and nothing reloaded rpcd on upgrade. The
# read/write split was reported working the whole time, because the suite loads
# sources through `ucode -L` and never inspects a built artifact. Grepping build.sh
# for the right strings is what the other guards do and it cannot see a mode bit
# or a file that install simply never copied.
#
# So this calls build_backend_root/build_app_root directly and checks the result.
# That costs seconds because the OpenWrt SDK, the frontend build and the archive
# assembly all live in main(), which is not invoked.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

BACKEND_ROOT="$WORK_DIR/staged/backend-root"
APP_ROOT="$WORK_DIR/staged/app-root"

# shellcheck source=/dev/null
. "$ROOT_DIR/build.sh"

rm -rf "$WORK_DIR/staged"
build_backend_root "$BACKEND_ROOT"
build_app_root "$APP_ROOT"

expect_mode() {
  local path="$1" want="$2" got
  [ -e "$path" ] || fail "staged package is missing ${path#"$BACKEND_ROOT"/}"
  got="$(stat -c '%a' "$path")"
  [ "$got" = "$want" ] || fail "staged ${path#"$BACKEND_ROOT"/} has mode $got, expected $want"
}

expect_file() {
  [ -e "$1" ] || fail "staged package is missing ${1#"$BACKEND_ROOT"/}"
}

# Both entry points have to be executable. The ACL grants tachyon-read exec, and
# a non-executable file makes that grant an error message instead of a read role.
expect_mode "$BACKEND_ROOT/usr/bin/tachyon" 755
expect_mode "$BACKEND_ROOT/usr/bin/tachyon-read" 755
expect_mode "$BACKEND_ROOT/etc/init.d/tachyon" 755

# The ACL belongs to the backend package. In luci-app-tachyon it is inert on any
# upgrade of one package without the other, which is the split it exists for.
expect_mode "$BACKEND_ROOT/usr/share/rpcd/acl.d/luci-app-tachyon.json" 644
if [ -e "$APP_ROOT/usr/share/rpcd/acl.d/luci-app-tachyon.json" ]; then
  fail "the rpcd ACL must not ship in luci-app-tachyon: it would go stale whenever only one package is upgraded"
fi
expect_file "$APP_ROOT/usr/share/luci/menu.d/luci-app-tachyon.json"

# Shared data files travel in the backend package; tests/build_shares_data_files.sh
# covers the Makefile parity for these, this pins that they were actually copied.
expect_file "$BACKEND_ROOT/usr/share/tachyon/public-suffix-list.dat"
expect_file "$BACKEND_ROOT/usr/share/tachyon/servicecheck_profiles.json"

# The read role must not reach the main binary. This is the whole point, and it is
# checkable here rather than only on a router with a read-only LuCI account.
acl="$BACKEND_ROOT/usr/share/rpcd/acl.d/luci-app-tachyon.json"
read_block="$(sed -n '/"read"/,/"write"/p' "$acl")"
printf '%s' "$read_block" | grep -qF '/usr/bin/tachyon-read' ||
  fail "the read role does not grant exec on tachyon-read"
if printf '%s' "$read_block" | grep -qF '"/usr/bin/tachyon"'; then
  fail "the read role still grants exec on the main tachyon binary"
fi
grep -qF '"/usr/bin/tachyon"' "$acl" ||
  fail "the write role no longer grants exec on the main tachyon binary"

# rpcd caches ACLs, so a package that installs a new one without reloading rpcd
# leaves the old policy serving. apk runs post-upgrade when replacing a package,
# which is the upgrade path every current user takes, so both hooks need it.
scripts_dir="$WORK_DIR/staged/scripts"
rm -rf "$scripts_dir"
mkdir -p "$scripts_dir"
write_backend_apk_scripts "$scripts_dir"
for hook in post-install post-upgrade; do
  script="$scripts_dir/backend-$hook.sh"
  expect_file "$script"
  grep -qF '/etc/init.d/rpcd reload' "$script" ||
    fail "the backend $hook hook does not reload rpcd, so a new ACL stays cached"
done

rm -rf "$WORK_DIR/staged"
printf 'PASS: staged package tree ships an executable read entry point, the ACL in the backend package, and reloads rpcd on install and upgrade\n'