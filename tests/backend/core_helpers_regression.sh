#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPERS_UC="$ROOT_DIR/podkop/files/usr/lib/core/helpers.uc"

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

assert_eq download_lists_via_proxy \
  "$(ucode "$HELPERS_UC" download-via-proxy-option-for-purpose lists)" \
  "lists download option"
assert_eq download_subscriptions_via_proxy \
  "$(ucode "$HELPERS_UC" download-via-proxy-option-for-purpose subscriptions)" \
  "subscriptions download option"
assert_eq download_components_via_proxy \
  "$(ucode "$HELPERS_UC" download-via-proxy-option-for-purpose components)" \
  "components download option"

if ucode "$HELPERS_UC" download-via-proxy-option-for-purpose unknown >/dev/null 2>&1; then
  fail "unknown download purpose should fail"
fi

assert_eq proxy-out \
  "$(ucode "$HELPERS_UC" outbound-tag proxy)" \
  "outbound tag"
assert_eq server-edge-in \
  "$(ucode "$HELPERS_UC" server-inbound-tag edge)" \
  "server inbound tag"
assert_eq server-edge-tailscale-dns \
  "$(ucode "$HELPERS_UC" tailscale-dns-tag edge)" \
  "tailscale DNS tag"
assert_eq dns-server-1-out \
  "$(SB_DIRECT_OUTBOUND_TAG=dns-server-out ucode "$HELPERS_UC" outbound-tag dns-server)" \
  "reserved outbound tag"

printf 'core helpers regression checks passed\n'
