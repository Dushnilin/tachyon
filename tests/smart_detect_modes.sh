#!/bin/sh
# No changes to live UCI, network or services. Requires native ucode.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export TACHYON_PSL_FILE="$root/tachyon/files/usr/share/tachyon/public-suffix-list.dat"
ucode -L "$root/tachyon/files/usr/lib" "$root/tests/smart_detect_modes.uc"
ucode -L "$root/tachyon/files/usr/lib" "$root/tests/smart_detect_plus.uc"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
ucode "$root/tests/smart_detect_dns_guard_build.uc" "$root/tachyon/files/usr/lib/service/watchdog.uc" "$root/tests/smart_detect_plus_loop.fixture.uc" "$work/loop.uc"
ucode -L "$root/tachyon/files/usr/lib" "$work/loop.uc"
ucode "$root/tests/smart_detect_plus_apply_build.uc" "$root/tachyon/files/usr/lib/service/watchdog.uc" "$root/tests/smart_detect_plus_apply.fixture.uc" "$work/apply.uc"
ucode -L "$root/tachyon/files/usr/lib" "$work/apply.uc"
