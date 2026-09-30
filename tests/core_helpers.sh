#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

HELPERS_UC="$ROOT_DIR/tachyon/files/usr/lib/core/helpers.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_eq download_lists_via_proxy \
  "$(ucode "$HELPERS_UC" download-via-proxy-option-for-purpose lists)" \
  "lists download option"
assert_eq download_components_via_proxy \
  "$(ucode "$HELPERS_UC" download-via-proxy-option-for-purpose components)" \
  "components download option"

if ucode "$HELPERS_UC" download-via-proxy-option-for-purpose subscriptions >/dev/null 2>&1; then
  fail "subscriptions download purpose should be per-subscription and no longer have a global option"
fi

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
assert_eq dns-server-out-1 \
  "$(SB_DIRECT_OUTBOUND_TAG=dns-server-out ucode "$HELPERS_UC" outbound-tag dns-server)" \
  "reserved outbound tag"
assert_eq direct-out-1 \
  "$(ucode "$HELPERS_UC" outbound-tag direct)" \
  "reserved direct outbound tag"
assert_eq bypass-out-1 \
  "$(ucode "$HELPERS_UC" outbound-tag bypass)" \
  "reserved bypass outbound tag"
assert_eq tproxy6-in-1 \
  "$(ucode "$HELPERS_UC" inbound-tag tproxy6)" \
  "reserved IPv6 TProxy inbound tag"
assert_eq direct-1-out \
  "$(ucode "$HELPERS_UC" outbound-tag direct-1)" \
  "numbered direct outbound tag"

COMPLEX_URL="vless://my-uuid-123@proxy.example.com:8443?authority=user@channel&service_name=grpc-service#my-node"
assert_eq vless "$(ucode "$HELPERS_UC" url-get-scheme "$COMPLEX_URL")" "url-get-scheme"
assert_eq my-uuid-123 "$(ucode "$HELPERS_UC" url-get-userinfo "$COMPLEX_URL")" "url-get-userinfo"
assert_eq proxy.example.com "$(ucode "$HELPERS_UC" url-get-host "$COMPLEX_URL")" "url-get-host"
assert_eq 8443 "$(ucode "$HELPERS_UC" url-get-port "$COMPLEX_URL")" "url-get-port"
assert_eq grpc-service "$(ucode "$HELPERS_UC" url-get-query-param "$COMPLEX_URL" service_name)" "url-get-query-param"

# Verify core.url module directly
assert_eq proxy.example.com \
  "$(ucode -e 'let u = require("core.url"); print(u.host(ARGV[0]));' "$COMPLEX_URL")" \
  "core.url host"
assert_eq 8443 \
  "$(ucode -e 'let u = require("core.url"); print(u.port(ARGV[0]));' "$COMPLEX_URL")" \
  "core.url port"
assert_eq my-uuid-123 \
  "$(ucode -e 'let u = require("core.url"); print(u.userinfo(ARGV[0]));' "$COMPLEX_URL")" \
  "core.url userinfo"

printf 'core helpers checks passed\n'
