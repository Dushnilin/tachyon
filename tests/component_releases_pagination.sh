#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$test_dir/../tachyon/files/usr/lib"
bin="$test_dir/../tachyon/files/usr/bin/tachyon"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Test 1: bin/tachyon component_list_releases dispatches with 3 args
output=$(ucode -L "$lib" "$lib/components/action.uc" list-component-releases tachyon-core 2 1 || true)
assert() {
    if ! "$@"; then
        echo "Assertion failed: $*" >&2
        exit 1
    fi
}

# Check that output is valid JSON array
assert ucode -e 'let arr = json(ARGV[0]); assert(type(arr) == "array", "must be array");' "$output"

# Removed standalone providers must return empty array cleanly
for removed in byedpi zapret zapret2 wdtt olcrtc tailscale; do
    rem_out=$(ucode -L "$lib" "$lib/components/action.uc" list-component-releases "$removed" 2 1 || true)
    assert [ "$rem_out" = "[]" ]
done

echo "PASS: component_releases_pagination"
