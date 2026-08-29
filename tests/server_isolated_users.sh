#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
if [ ! -d "$TACHYON_LIB" ]; then
  TACHYON_LIB="/usr/lib/tachyon"
fi
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

fixture_with_server() {
  cat >"$WORK_DIR/fixture.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1"
  },
  "server": [
    $1
  ],
  "section": [
    {
      ".name": "default_direct",
      ".type": "section",
      "enabled": "1",
      "action": "bypass"
    }
  ]
}
JSON
}

generate() {
  mkdir -p "$WORK_DIR/out.section-cache"
  ucode -L "$TACHYON_LIB" "$TACHYON_LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/singbox.json" "127.0.0.1" 0 0
}

# 1. Test isolate_lan_for_users with specific isolated_users list
fixture_with_server '{
  ".name": "my_vless_server",
  ".type": "server",
  "enabled": "1",
  "protocol": "vless",
  "listen_port": "443",
  "server_uuid": "00000000-0000-0000-0000-000000000000",
  "routing_mode": "direct",
  "isolate_lan_for_users": "1",
  "isolated_users": ["friend-1", "friend-2"]
}'
generate

# Verify reject rule exists with auth_user and ip_is_private
grep -q '"action": "reject"' "$WORK_DIR/singbox.json" ||
  fail "expected action reject rule for isolated users"
grep -q '"inbound": "server-my_vless_server-in"' "$WORK_DIR/singbox.json" ||
  fail "expected inbound tag on reject rule"
grep -q '"ip_is_private": true' "$WORK_DIR/singbox.json" ||
  fail "expected ip_is_private on reject rule"
grep -q '"auth_user": \[' "$WORK_DIR/singbox.json" ||
  fail "expected auth_user array on reject rule"
grep -q '"friend-1"' "$WORK_DIR/singbox.json" ||
  fail "expected friend-1 in auth_user"
grep -q '"friend-2"' "$WORK_DIR/singbox.json" ||
  fail "expected friend-2 in auth_user"

# 2. Test isolate_lan_for_users without specific users (blocks all users on that inbound)
fixture_with_server '{
  ".name": "guest_vless",
  ".type": "server",
  "enabled": "1",
  "protocol": "vless",
  "listen_port": "443",
  "server_uuid": "00000000-0000-0000-0000-000000000000",
  "routing_mode": "direct",
  "isolate_lan_for_users": "1"
}'
generate

grep -q '"action": "reject"' "$WORK_DIR/singbox.json" ||
  fail "expected action reject rule for guest_vless"
grep -q '"inbound": "server-guest_vless-in"' "$WORK_DIR/singbox.json" ||
  fail "expected inbound tag on reject rule for guest_vless"
grep -q '"ip_is_private": true' "$WORK_DIR/singbox.json" ||
  fail "expected ip_is_private on reject rule for guest_vless"

# 3. Test custom isolated_subnets and block_private_for_users alias
fixture_with_server '{
  ".name": "custom_subnet_server",
  ".type": "server",
  "enabled": "1",
  "protocol": "vless",
  "listen_port": "443",
  "server_uuid": "00000000-0000-0000-0000-000000000000",
  "routing_mode": "direct",
  "block_private_for_users": "1",
  "blocked_users": ["guest"],
  "isolated_subnets": ["192.168.1.0/24", "10.10.0.0/16"]
}'
generate

grep -q '"action": "reject"' "$WORK_DIR/singbox.json" ||
  fail "expected reject rule for custom_subnet_server"
grep -q '"192.168.1.0/24"' "$WORK_DIR/singbox.json" ||
  fail "expected custom subnet 192.168.1.0/24 in reject rule"
grep -q '"guest"' "$WORK_DIR/singbox.json" ||
  fail "expected guest in auth_user"

# 4. Test custom_route_rules injection
fixture_with_server '{
  ".name": "custom_rules_server",
  ".type": "server",
  "enabled": "1",
  "protocol": "vless",
  "listen_port": "443",
  "server_uuid": "00000000-0000-0000-0000-000000000000",
  "routing_mode": "direct",
  "custom_route_rules": ["{\"action\":\"reject\",\"domain\":[\"blocked.local\"]}"]
}'
generate

grep -q '"domain": \[' "$WORK_DIR/singbox.json" ||
  fail "expected custom domain rule"
grep -q '"blocked.local"' "$WORK_DIR/singbox.json" ||
  fail "expected blocked.local domain in rules"
grep -q '"inbound": "server-custom_rules_server-in"' "$WORK_DIR/singbox.json" ||
  fail "expected auto-assigned inbound tag on custom route rule"

printf 'PASS: server isolated users and custom route rules tests passed\n'