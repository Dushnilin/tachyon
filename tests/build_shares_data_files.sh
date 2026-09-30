#!/usr/bin/env bash
# build.sh and tachyon/Makefile both define the package contents, by hand and
# separately. A data file added to only one of them ships missing from whichever
# build path skipped it: the release artifacts come from build.sh, the OpenWrt
# feed from the Makefile. The first casualty was public-suffix-list.dat, which
# Smart Detect Plus reads to reduce a hostname to its registrable domain.
#
# Every file under files/usr/share/tachyon must therefore be named in build.sh.
# The rpcd ACL is checked separately because it is not shared data: it lives in
# files/usr/share/rpcd/acl.d and ships in the tachyon package. It was moved out
# of luci-app-tachyon precisely so the backend and its policy update apart, and
# build.sh was never taught to install it, so release artifacts shipped a
# luci package whose ACL silently did not apply to the read role.
#
# The key is the full source path, not the bare file name: build.sh mentions
# luci-app-tachyon.json for an unrelated uci-defaults guard on menu.d, so a
# name-only grep passes against a build.sh that installs no ACL at all.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

SHARE_DIR="$ROOT_DIR/tachyon/files/usr/share/tachyon"
BUILD_SH="$ROOT_DIR/build.sh"
ACL_PATH="files/usr/share/rpcd/acl.d/luci-app-tachyon.json"

[ -d "$SHARE_DIR" ] || fail "shared data directory missing: $SHARE_DIR"
[ -f "$BUILD_SH" ] || fail "build.sh missing"
[ -f "$ROOT_DIR/tachyon/$ACL_PATH" ] || fail "rpcd ACL missing from the source tree: $ACL_PATH"

missing=0
count=0
for path in "$SHARE_DIR"/*; do
  [ -f "$path" ] || continue
  count=$((count + 1))
  base="$(basename "$path")"
  # The package path is identical in both scripts, so the file name alone is
  # enough of a key.
  if ! grep -qF "$base" "$BUILD_SH"; then
    missing=$((missing + 1))
    fail "build.sh does not install shared data file: $base"
  fi
done

[ "$count" -gt 0 ] || fail "no shared data files found, the loop checked nothing"

grep -qF "$ACL_PATH" "$BUILD_SH" ||
  fail "build.sh does not install the rpcd ACL into the tachyon package"

printf 'PASS: build.sh installs all %d shared data files and the rpcd ACL\n' "$count"
