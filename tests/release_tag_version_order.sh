#!/usr/bin/env bash
# GitHub returns /releases ordered by created_at, which is not the same as
# version order. Ensure tachyon-core-release-tag picks the highest semver tag
# rather than the newest publish timestamp, handles multi-digit segments, and
# skips prereleases and drafts.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

UPDATER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updater.uc"

selected_tag() {
  printf '%s' "$2" | TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$UPDATER_UC" "$1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

CORE_RELEASES='[
  {"tag_name":"v0.5.9","prerelease":false,"draft":false,"created_at":"2026-09-29T11:51:49Z"},
  {"tag_name":"v0.5.11","prerelease":false,"draft":false,"created_at":"2026-09-29T18:16:55Z"},
  {"tag_name":"v0.5.10","prerelease":false,"draft":false,"created_at":"2026-09-29T17:40:51Z"},
  {"tag_name":"v0.5.8","prerelease":false,"draft":false,"created_at":"2026-09-28T00:20:06Z"},
  {"tag_name":"v0.6.0-rc.1","prerelease":true,"draft":false,"created_at":"2026-09-24T19:30:58Z"}
]'

assert_eq "v0.5.11" "$(selected_tag tachyon-core-release-tag "$CORE_RELEASES")" \
  "tachyon-core release tag picks the highest version, not the newest publish"

MULTI_DIGIT='[
  {"tag_name":"v0.5.9"},
  {"tag_name":"v0.5.10"},
  {"tag_name":"v0.5.11"}
]'
assert_eq "v0.5.11" "$(selected_tag tachyon-core-release-tag "$MULTI_DIGIT")" \
  "0.5.11 outranks 0.5.10 and 0.5.9 numerically"

assert_eq "v0.5.9" "$(selected_tag tachyon-core-release-tag '[
  {"tag_name":"v0.6.0-rc.1","prerelease":true},
  {"tag_name":"v0.5.9","prerelease":false},
  {"tag_name":"v0.5.8","prerelease":false}
]')" "prereleases are skipped"

assert_eq "v0.5.9" "$(selected_tag tachyon-core-release-tag '[
  {"tag_name":"v0.5.9","prerelease":false},
  {"tag_name":"v0.5.10","prerelease":false,"draft":true}
]')" "drafts are skipped"

assert_eq "" "$(selected_tag tachyon-core-release-tag '[]')" "empty release list yields no tag"

printf 'PASS: release tag selection is by version, not by publish order\n'
