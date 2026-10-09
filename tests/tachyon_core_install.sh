#!/usr/bin/env bash
# The core's archive holds a binary named after the build, not "sing-box".
#
# sing-box-lx and the stock variants ship a member literally called sing-box, so
# the install path looks it up by exact name. tachyon-core ships
# tachyon-core-<arch>, which is not knowable in advance, so the member is found by
# prefix, and that lookup has to survive the .sha256 sidecar and the SHA256SUMS
# file sitting beside it.
#
# The asset names below are copied verbatim from the published release v0.0.1 of
# Dushnilin/tachyon-core. They are not invented: the release ships
# tachyon-core-aarch64-musl-v0.0.1.tar.gz, carrying a Rust target triple and the
# "v" of the tag. An earlier version of this test used the plausible-but-wrong
# tachyon-core-aarch64-0.0.1.tar.gz and therefore agreed with the code while both
# were wrong - a fixture that encodes the assumption instead of the fact.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATER="$TACHYON_LIB/components/updater.uc"

mkdir -p "$WORK_DIR/arch"
printf '#!/bin/sh\necho core\n' >"$WORK_DIR/arch/tachyon-core-aarch64-musl"
sha256sum "$WORK_DIR/arch/tachyon-core-aarch64-musl" \
  >"$WORK_DIR/arch/tachyon-core-aarch64-musl.sha256"
( cd "$WORK_DIR/arch" && tar -czf "$WORK_DIR/core.tar.gz" \
    ./tachyon-core-aarch64-musl ./tachyon-core-aarch64-musl.sha256 )

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
[ "$(basename "$got")" = "tachyon-core-aarch64-musl" ] ||
  fail "unexpected member picked: $got"

# A longer prefix is a different artifact name and must not fuzzy-match into
# the full build's member.
[ -z "$(members tachyon-core-lite)" ] ||
  fail "a longer prefix must not match the full build's member"

# ─── the arch name ──────────────────────────────────────────────────────────
# The release names assets after the Rust target triple. sing-box-extended ships
# "arm64" for the same machine, so the two resolvers cannot be shared: reusing the
# Go name here resolves to nothing and the install fails with "no asset".
arch() {
  ucode -L "$TACHYON_LIB" "$UPDATER" tachyon-core-arch-suffix "$1" "" 2>/dev/null
}

[ "$(arch aarch64)" = "aarch64-musl" ] ||
  fail "aarch64 must resolve to aarch64-musl, got '$(arch aarch64)'"
[ "$(arch x86_64)" = "x86_64-musl" ] ||
  fail "x86_64 must resolve to x86_64-musl, got '$(arch x86_64)'"
[ "$(arch armv7l)" = "armv7-musl" ] ||
  fail "armv7l must resolve to armv7-musl, got '$(arch armv7l)'"
[ "$(arch mipsel)" = "mipsel-musl" ] ||
  fail "mipsel must resolve to mipsel-musl, got '$(arch mipsel)'"
# The Go name is exactly the trap: if this ever comes back "arm64", the asset
# lookup is using the wrong table again.
[ "$(arch aarch64)" != "arm64" ] ||
  fail "tachyon-core must not be resolved with the sing-box-extended GOARCH name"
# OpenWrt is musl throughout; the gnu build would not link there.
case "$(arch aarch64)" in
  *-musl) : ;;
  *) fail "the arch suffix must be a musl target on OpenWrt, got '$(arch aarch64)'" ;;
esac

# ─── asset selection, against the real asset names ──────────────────────────
RELEASE='{"tag_name":"v0.0.1","assets":[
  {"name":"tachyon-core-aarch64-musl-v0.0.1.tar.gz","browser_download_url":"https://x/full-a64.tgz"},
  {"name":"tachyon-core-armv7-musl-v0.0.1.tar.gz","browser_download_url":"https://x/full-armv7.tgz"},
  {"name":"tachyon-core-x86_64-musl-v0.0.1.tar.gz","browser_download_url":"https://x/full-x64.tgz"},
  {"name":"tachyon-core-linux-amd64-v0.0.1.tar.gz","browser_download_url":"https://x/full-amd64-gnu.tgz"},
  {"name":"tachyon-core-windows-amd64-v0.0.1.zip","browser_download_url":"https://x/windows.zip"},
  {"name":"SHA256SUMS","browser_download_url":"https://x/sums"}]}'
printf '%s' "$RELEASE" >"$WORK_DIR/release.json"

asset() {
  ucode -L "$TACHYON_LIB" "$UPDATER" tachyon-core-asset-url "$1" "$2" \
    <"$WORK_DIR/release.json" 2>/dev/null
}

[ "$(asset aarch64-musl "")" = "https://x/full-a64.tgz" ] ||
  fail "the aarch64-musl asset was not selected, got '$(asset aarch64-musl "")'"
[ "$(asset x86_64-musl "")" = "https://x/full-x64.tgz" ] ||
  fail "the x86_64-musl asset was not selected, got '$(asset x86_64-musl "")'"
# Not the gnu build, and not the Windows zip.
[ "$(asset aarch64-musl "")" != "https://x/full-amd64-gnu.tgz" ] ||
  fail "aarch64-musl must not resolve to the gnu build"
[ "$(asset aarch64-musl "")" != "https://x/windows.zip" ] ||
  fail "a musl asset lookup must not pick a zip"
# A checksum manifest is not an artifact.
[ "$(asset aarch64-musl "")" != "https://x/sums" ] ||
  fail "SHA256SUMS was picked as the artifact"

[ -z "$(asset mips64-musl "")" ] ||
  fail "an architecture with no artifact must resolve to nothing, not to another arch"

printf 'tachyon-core asset and archive lookup checks passed\n'