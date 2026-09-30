#!/usr/bin/env bash
# GitHub returns /releases ordered by created_at, which is not the same as
# version order. Leadaxe published sing-box-lx v1.14.2-lx.9 at 11:51 and
# v1.14.2-lx.11 at 18:16 on the same day, so the API hands lx.9 back first and
# a "take the first match" gate offers the older build as the latest one.
#
# The order below is the one the API actually returned, tags and all.

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

# Real API ordering for Leadaxe/sing-box-lx, trimmed to what the gate looks at.
LX_RELEASES='[
  {"tag_name":"v1.14.2-lx.9","prerelease":false,"draft":false,"created_at":"2026-09-29T11:51:49Z"},
  {"tag_name":"v1.14.2-lx.11","prerelease":false,"draft":false,"created_at":"2026-09-29T18:16:55Z"},
  {"tag_name":"v1.14.2-lx.10","prerelease":false,"draft":false,"created_at":"2026-09-29T17:40:51Z"},
  {"tag_name":"v1.14.2-lx.8","prerelease":false,"draft":false,"created_at":"2026-09-28T00:20:06Z"},
  {"tag_name":"v1.14.2-lx.2-rc.3","prerelease":true,"draft":false,"created_at":"2026-09-24T19:30:58Z"}
]'

# The first entry is lx.9, so a first-match gate returns lx.9 and the router
# reports an older build as the newest one.
assert_eq "v1.14.2-lx.11" "$(selected_tag sing-box-lx-release-tag "$LX_RELEASES")" \
  "lx release tag picks the highest version, not the newest publish"

# Two digits must not lose to one: a plain string compare ranks "lx.9" above
# "lx.11" and "lx.10" above "lx.9".
MULTI_DIGIT='[
  {"tag_name":"v1.14.2-lx.9"},
  {"tag_name":"v1.14.2-lx.10"},
  {"tag_name":"v1.14.2-lx.11"}
]'
assert_eq "v1.14.2-lx.11" "$(selected_tag sing-box-lx-release-tag "$MULTI_DIGIT")" \
  "lx.11 outranks lx.10 and lx.9 numerically"

# The extended gate had the same first-match loop, so it needs the same answer.
EXTENDED_RELEASES='[
  {"tag_name":"v2.7.1"},
  {"tag_name":"v2.7.2"},
  {"tag_name":"v2.10.0"},
  {"tag_name":"v2.9.0"}
]'
assert_eq "v2.10.0" "$(selected_tag sing-box-extended-release-tag "$EXTENDED_RELEASES")" \
  "extended release tag ranks 2.10.0 above 2.9.0"

# Filters must survive the rewrite: prereleases and non-lx tags stay excluded.
assert_eq "v1.14.2-lx.9" "$(selected_tag sing-box-lx-release-tag '[
  {"tag_name":"v1.14.2-lx.2-rc.3","prerelease":true},
  {"tag_name":"v1.14.2-lx.9","prerelease":false},
  {"tag_name":"v1.14.2-lx.8","prerelease":false}
]')" "prereleases are still skipped"

assert_eq "v1.14.2-lx.9" "$(selected_tag sing-box-lx-release-tag '[
  {"tag_name":"v1.14.2-lx.9","prerelease":false},
  {"tag_name":"v1.14.2-lx.8","prerelease":false,"draft":true}
]')" "drafts are still skipped"

# Nothing to choose from must stay silent rather than print an empty tag the
# caller would then try to download.
assert_eq "" "$(selected_tag sing-box-lx-release-tag '[]')" "empty release list yields no tag"
assert_eq "" "$(selected_tag sing-box-lx-release-tag '[{"tag_name":"v1.14.2"}]')" \
  "a non-lx release list yields no tag"

printf 'PASS: release tag selection is by version, not by publish order\n'
