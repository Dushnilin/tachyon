#!/bin/sh
# Isolated regressions: no live DNS, UCI, services or routes are changed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=$root/tachyon/files/usr/lib
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
ucode -L "$lib" "$root/tests/smart_detect_dns_guard.uc"
ucode "$root/tests/smart_detect_dns_guard_build.uc" "$lib/service/watchdog.uc" \
    "$root/tests/smart_detect_dns_guard.fixture.uc" "$work/test.uc"
ucode -L "$lib" "$work/test.uc"
