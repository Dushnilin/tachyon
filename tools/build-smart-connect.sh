#!/usr/bin/env bash
# Separate static helpers keep the main Tachyon package architecture-independent.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:?release version required}
output=${2:?output directory required}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected x.y.z version' >&2; exit 1; }
mkdir -p "$output"
output=$(cd -- "$output" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cd "$root/tools/smart-connect"
while read -r target arch variant; do
  env CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GO386=softfloat GOMIPS=softfloat GOMIPS64=softfloat GOARM="${variant:-7}" \
    go build -trimpath -ldflags='-s -w' -o "$stage/tachyon-smart-connect" .
  tar -czf "$output/tachyon-smart-connect-${target}-${version}.tar.gz" -C "$stage" tachyon-smart-connect
  printf 'Built Smart Connect: %s\n' "$target"
done <<'TARGETS'
x86_64 amd64
i386 386
aarch64 arm64
armv5 arm 5
armv6 arm 6
armv7 arm 7
mips mips
mipsel mipsle
mips64 mips64
mips64el mips64le
riscv64 riscv64
TARGETS
cd "$output"
sha256sum tachyon-smart-connect-*"-$version.tar.gz" > SHA256SUMS-smart-connect.txt
