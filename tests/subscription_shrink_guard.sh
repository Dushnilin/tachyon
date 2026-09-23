#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_UC="$ROOT_DIR/tachyon/files/usr/lib/subscription/cache.uc"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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

cache_ucode() {
  ucode -L "$TACHYON_LIB" "$CACHE_UC" "$@"
}

write_subscription_json() {
  local path="$1"
  local count="$2"
  local stub_count="${3:-0}"
  local i

  {
    printf '{"version":1,"format":"uri-list","outbounds":['
    local parts=()
    for ((i = 1; i <= count; i++)); do
      parts+=("{\"type\":\"vless\",\"tag\":\"node-$i\",\"server\":\"n$i.example.com\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-00000000000$i\"}")
    done
    for ((i = 1; i <= stub_count; i++)); do
      parts+=("{\"type\":\"vless\",\"tag\":\"Unsupported client - Use Happ\",\"server\":\"127.0.0.1\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-00000000000$i\"}")
    done
    local IFS=','
    printf '%s' "${parts[*]}"
    printf ']}\n'
  } >"$path"
}

OLD_JSON="$WORK_DIR/old.json"
NEW_JSON="$WORK_DIR/new.json"
SMALL_JSON="$WORK_DIR/small.json"
MID_JSON="$WORK_DIR/mid.json"
STUB_JSON="$WORK_DIR/stub.json"
MISSING="$WORK_DIR/missing.json"

write_subscription_json "$OLD_JSON" 8
write_subscription_json "$NEW_JSON" 2
write_subscription_json "$SMALL_JSON" 3
write_subscription_json "$MID_JSON" 6
write_subscription_json "$STUB_JSON" 2 6

assert_eq "8" "$(cache_ucode usable-outbound-count "$OLD_JSON")" \
  "usable count of 8-outbound cache"
assert_eq "2" "$(cache_ucode usable-outbound-count "$NEW_JSON")" \
  "usable count of 2-outbound cache"
assert_eq "2" "$(cache_ucode usable-outbound-count "$STUB_JSON")" \
  "stub outbounds must not count as usable"
assert_eq "0" "$(cache_ucode usable-outbound-count "$MISSING")" \
  "missing cache counts as 0"
assert_eq "0" "$(cache_ucode usable-outbound-count "")" \
  "empty path counts as 0"

cache_ucode shrink-guard-triggers "$OLD_JSON" "$NEW_JSON" >/dev/null ||
  fail "8 -> 2 must trigger the shrink guard"

if cache_ucode shrink-guard-triggers "$SMALL_JSON" "$NEW_JSON" >/dev/null 2>&1; then
  fail "3 -> 2 must not trigger (old cache below threshold)"
fi

if cache_ucode shrink-guard-triggers "$OLD_JSON" "$MID_JSON" >/dev/null 2>&1; then
  fail "8 -> 6 must not trigger (new cache above threshold)"
fi

if cache_ucode shrink-guard-triggers "$OLD_JSON" "$OLD_JSON" >/dev/null 2>&1; then
  fail "equal usable counts must not trigger"
fi

if cache_ucode shrink-guard-triggers "$MISSING" "$NEW_JSON" >/dev/null 2>&1; then
  fail "missing old cache must not trigger"
fi

if cache_ucode shrink-guard-triggers "$STUB_JSON" "$NEW_JSON" >/dev/null 2>&1; then
  fail "old cache with only 2 usable entries must not trigger"
fi

grep -q 'subscription_shrink_guard_triggers' "$CACHE_UC" ||
  fail "cache.uc must call subscription_shrink_guard_triggers"
grep -q 'mode == "usable-outbound-count"' "$CACHE_UC" ||
  fail "cache.uc must expose usable-outbound-count owner mode"
grep -q 'mode == "shrink-guard-triggers"' "$CACHE_UC" ||
  fail "cache.uc must expose shrink-guard-triggers owner mode"

guard_source="$(sed -n '/subscription_shrink_guard_triggers(subscription_json_path/,/return 2;/p' "$CACHE_UC")"
if [ -z "$guard_source" ]; then
  fail "shrink guard block must return 2 (unchanged)"
fi
if ! grep -Fq 'move_file(normalized_tmpfile, subscription_json_path)' <<<"$(sed -n '/subscription_shrink_guard_triggers/,/^        if (!move_file/p' "$CACHE_UC")"; then
  fail "shrink guard must run before move_file promotes the new cache"
fi

echo "subscription shrink guard checks passed"
