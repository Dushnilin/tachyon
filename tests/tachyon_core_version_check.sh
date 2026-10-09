#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATER="$ROOT_DIR/tachyon/files/usr/lib/components/updater.uc"
VERSIONS="$ROOT_DIR/tachyon/files/usr/lib/components/versions.uc"

ucode() {
  local has_L=0
  for arg in "$@"; do
    if [ "$arg" = "-L" ]; then
      has_L=1
      break
    fi
  done
  if [ "$has_L" -eq 1 ]; then
    command ucode "$@"
  else
    command ucode -L "$TACHYON_LIB" "$@"
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# 1. Normalization
assert_eq "0.0.1" \
  "$(ucode "$UPDATER" updates-normalize-sing-box-version "v0.0.1-tachyon.0")" \
  "tachyon-core version with v and -tachyon.0 suffix normalizes to bare semver"

assert_eq "0.0.1" \
  "$(ucode "$UPDATER" updates-normalize-sing-box-version "0.0.1-tachyon.0")" \
  "tachyon-core version without v and with -tachyon.0 suffix normalizes to bare semver"

assert_eq "0.0.1" \
  "$(ucode "$UPDATER" updates-normalize-sing-box-version "v0.0.1")" \
  "tachyon-core release tag normalizes to bare semver"

assert_eq "1.14.3-lx.14" \
  "$(ucode "$UPDATER" updates-normalize-sing-box-version "1.14.3-lx.14")" \
  "sing-box-lx version preserves fork suffix"

assert_eq "1.13.21-extended" \
  "$(ucode "$UPDATER" updates-normalize-sing-box-version "1.13.21-extended")" \
  "sing-box-extended version preserves fork suffix"

# 2. Comparison via versions.uc
assert_eq "0" \
  "$(ucode -e 'let v = require("components.versions"); print(v.compare_versions("0.0.1-tachyon.0", "0.0.1"));')" \
  "installed 0.0.1-tachyon.0 matches release 0.0.1"

assert_eq "0" \
  "$(ucode -e 'let v = require("components.versions"); print(v.compare_versions("v0.0.1-tachyon.0", "0.0.1"));')" \
  "installed v0.0.1-tachyon.0 matches release 0.0.1"

assert_eq "-1" \
  "$(ucode -e 'let v = require("components.versions"); print(v.compare_versions("0.0.1-tachyon.0", "0.0.2"));')" \
  "installed 0.0.1-tachyon.0 is outdated when release is 0.0.2"

assert_eq "1" \
  "$(ucode -e 'let v = require("components.versions"); print(v.compare_versions("0.0.2-tachyon.0", "0.0.1"));')" \
  "installed 0.0.2-tachyon.0 is dev when release is 0.0.1"

assert_eq "-1" \
  "$(ucode -e 'let v = require("components.versions"); print(v.compare_versions("0.0.1-tachyon.0", "0.0.1-tachyon.1"));')" \
  "installed 0.0.1-tachyon.0 is outdated compared to 0.0.1-tachyon.1"

printf 'tachyon-core version check tests passed\n'
