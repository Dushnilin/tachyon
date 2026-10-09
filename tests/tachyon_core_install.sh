#!/usr/bin/env bash
# The core's archive holds a binary named after the build, not "sing-box".
#
# sing-box-lx and the stock variants ship a member literally called sing-box, so
# the install path looks it up by exact name. tachyon-core ships
# tachyon-core-<arch>-<version>, which is not knowable in advance - the version is
# in the name. So the member is found by prefix, and that lookup has to survive
# two things the exact-name matcher never had to: a name carrying two dots
# ("0.0.1") and a .sha256 sidecar sitting next to the binary in the same archive.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATER="$TACHYON_LIB/components/updater.uc"

mkdir -p "$WORK_DIR/arch"
printf '#!/bin/sh\necho core\n' >"$WORK_DIR/arch/tachyon-core-aarch64-0.0.1"
sha256sum "$WORK_DIR/arch/tachyon-core-aarch64-0.0.1" \
  >"$WORK_DIR/arch/tachyon-core-aarch64-0.0.1.sha256"
( cd "$WORK_DIR/arch" && tar -czf "$WORK_DIR/core.tar.gz" \
    ./tachyon-core-aarch64-0.0.1 ./tachyon-core-aarch64-0.0.1.sha256 )

members() {
  tar -tzf "$WORK_DIR/core.tar.gz" |
    ucode -L "$TACHYON_LIB" "$UPDATER" updates-archive-member-prefix "$1" 2>/dev/null
}

# The binary is found...
got="$(members tachyon-core)"
[ -n "$got" ] ||
  fail "the core binary is named after the build, so an exact 'sing-box' lookup finds nothing"

# ...and it is the binary, not the checksum beside it. Extracting the sidecar
# over the binary would leave an engine that cannot start, and the two differ only
# by the extension.
case "$got" in
  *.sha256) fail "the prefix match picked the checksum file, not the binary: $got" ;;
esac
[ "$(basename "$got")" = "tachyon-core-aarch64-0.0.1" ] ||
  fail "unexpected member picked: $got"

# A different variant is a different artifact; picking it here would install the
# wrong build and no one would notice until a feature went missing.
[ -z "$(members tachyon-core-lite)" ] ||
  fail "a lite lookup must not match the full build's member"

# And the asset name carries the arch in the middle, which is why the suffix
# matcher the other variants use cannot be reused here.
RELEASE='{"assets":[
  {"name":"tachyon-core-aarch64-0.0.1.tar.gz","browser_download_url":"https://x/full.tgz"},
  {"name":"tachyon-core-lite-aarch64-0.0.1.tar.gz","browser_download_url":"https://x/lite.tgz"},
  {"name":"notes.txt","browser_download_url":"https://x/n"}]}'
printf '%s' "$RELEASE" >"$WORK_DIR/release.json"

asset() {
  ucode -L "$TACHYON_LIB" "$UPDATER" tachyon-core-asset-url "$1" "$2" \
    <"$WORK_DIR/release.json" 2>/dev/null
}

[ "$(asset aarch64 "")" = "https://x/full.tgz" ] ||
  fail "the full build's asset was not selected"
[ "$(asset aarch64 lite)" = "https://x/lite.tgz" ] ||
  fail "the lite build's asset was not selected"
[ -z "$(asset mips lite)" ] ||
  fail "an architecture with no artifact must resolve to nothing, not to another arch"

printf 'tachyon-core asset and archive lookup checks passed\n'