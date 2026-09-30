#!/usr/bin/env bash
# build.sh and tachyon/Makefile both define the package contents, by hand and
# separately. A data file added to only one of them ships missing from whichever
# build path skipped it: the release artifacts come from build.sh, the OpenWrt
# feed from the Makefile. The first casualty was public-suffix-list.dat, which
# Smart Detect Plus reads to reduce a hostname to its registrable domain.
#
# Every file under files/usr/share/tachyon must therefore be named in build.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

SHARE_DIR="$ROOT_DIR/tachyon/files/usr/share/tachyon"
BUILD_SH="$ROOT_DIR/build.sh"

[ -f "$SHARE_DIR" ] || true
[ -d "$SHARE_DIR" ] || fail "shared data directory missing: $SHARE_DIR"
[ -f "$BUILD_SH" ] || fail "build.sh missing"

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

printf 'PASS: build.sh installs all %d shared data files\n' "$count"
