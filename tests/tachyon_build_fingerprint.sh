#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATER_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updater.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

fingerprint() {
  printf '%s' "$1" | ucode "$UPDATER_UC" release-build-fingerprint
}

commit_sha() {
  printf '%s' "$1" | ucode "$UPDATER_UC" release-commit-sha
}

# A release whose body carries "Commit: <sha>" is identified by that sha, so the
# fingerprint must not fall back to timestamps and lose precision.
BODY_SHA_RELEASE='{"tag_name":"1.2.66","html_url":"https://example.invalid/r","target_commitish":"main","body":"Notes\nCommit: a1b2c3d4e5f6\n","published_at":"2026-08-01T10:00:00Z","assets":[{"name":"tachyon_1.2.66_all.ipk","updated_at":"2026-08-01T10:05:00Z","size":123456}]}'
assert_eq "sha:a1b2c3d4e5f6" "$(fingerprint "$BODY_SHA_RELEASE")" "fingerprint prefers body commit sha"
assert_eq "a1b2c3d4e5f6" "$(commit_sha "$BODY_SHA_RELEASE")" "commit sha read from body"

# target_commitish holds a branch name on every release cut from a branch, so it
# must not be mistaken for a sha.
BRANCH_ONLY_RELEASE='{"tag_name":"1.2.66","target_commitish":"main","body":"No commit line here","published_at":"2026-08-01T10:00:00Z","assets":[{"name":"tachyon_1.2.66_all.ipk","updated_at":"2026-08-01T10:05:00Z","size":123456}]}'
assert_eq "" "$(commit_sha "$BRANCH_ONLY_RELEASE")" "branch name is not a commit sha"
assert_eq "build:pub=2026-08-01T10:00:00Z|upd=2026-08-01T10:05:00Z|size=123456" \
  "$(fingerprint "$BRANCH_ONLY_RELEASE")" \
  "fingerprint falls back to publish stamps and asset size"

# A rebuild replaces the asset, so the fingerprint has to move even when
# published_at stays exactly the same.
REBUILT_RELEASE='{"tag_name":"1.2.66","target_commitish":"main","body":"No commit line here","published_at":"2026-08-01T10:00:00Z","assets":[{"name":"tachyon_1.2.66_all.ipk","updated_at":"2026-08-02T11:30:00Z","size":123999}]}'
[ "$(fingerprint "$BRANCH_ONLY_RELEASE")" != "$(fingerprint "$REBUILT_RELEASE")" ] ||
  fail "rebuilt release must not share a fingerprint with the original build"

# created_at stands in for a release that has not been published yet.
CREATED_ONLY_RELEASE='{"tag_name":"1.2.66","target_commitish":"main","created_at":"2026-07-30T08:00:00Z","assets":[]}'
assert_eq "build:pub=2026-07-30T08:00:00Z" "$(fingerprint "$CREATED_ONLY_RELEASE")" \
  "created_at substitutes for published_at"

# Assets that are not the backend package must not drive the fingerprint.
FOREIGN_ASSET_RELEASE='{"tag_name":"1.2.66","target_commitish":"main","published_at":"2026-08-01T10:00:00Z","assets":[{"name":"luci-app-tachyon_1.2.66_all.ipk","updated_at":"2026-08-01T10:09:00Z","size":777}]}'
assert_eq "build:pub=2026-08-01T10:00:00Z" "$(fingerprint "$FOREIGN_ASSET_RELEASE")" \
  "only the tachyon_ backend asset contributes"

# Nothing identifiable at all must produce no fingerprint rather than a constant
# one, or every release would look identical.
assert_eq "" "$(fingerprint '{"tag_name":"1.2.66","target_commitish":"main"}')" \
  "release without stamps yields no fingerprint"
assert_eq "" "$(fingerprint '{}')" "empty release yields no fingerprint"

differs() {
  if ucode "$UPDATER_UC" tachyon-build-differs "$1" "$2" "$3" "$4" >/dev/null 2>&1; then
    printf 'yes'
  else
    printf 'no'
  fi
}

assert_eq no "$(differs abc1234 abc1234 '' '')" "equal shas match"
assert_eq yes "$(differs abc1234 def5678 '' '')" "different shas differ"
# build.sh and the OpenWrt Makefile stamp a short sha while the release may carry
# the full one; the comparison happens on the shorter of the two.
assert_eq no "$(differs abc1234 abc1234ffffffffffffffffffffffffffffffff '' '')" \
  "short local sha is a prefix of the full remote sha"
assert_eq yes "$(differs abc1234 abc1299ffffffffffffffffffffffffffffffff '' '')" \
  "prefix mismatch within the short sha differs"

assert_eq no "$(differs '' '' 'build:pub=A' 'build:pub=A')" "equal fingerprints match"
assert_eq yes "$(differs '' '' 'build:pub=A' 'build:pub=B')" "different fingerprints differ"

# An unknown state must never be reported as an available update: the UI would
# offer an install that changes nothing.
assert_eq no "$(differs '' '' '' '')" "no information means no update"
assert_eq no "$(differs abc1234 '' '' '')" "remote sha alone missing means no update"
assert_eq no "$(differs '' def5678 '' '')" "local sha alone missing means no update"
assert_eq no "$(differs '' '' 'build:pub=A' '')" "remote fingerprint missing means no update"
assert_eq no "$(differs '' '' '' 'build:pub=B')" "local fingerprint missing means no update"

# When both shas are known they decide, even if the fingerprints disagree.
assert_eq no "$(differs abc1234 abc1234 'build:pub=A' 'build:pub=B')" \
  "matching shas win over disagreeing fingerprints"

printf 'PASS: tachyon build fingerprint\n'
