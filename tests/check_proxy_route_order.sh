#!/usr/bin/env bash
# Verifies that CHECK_PROXY_IP_DOMAIN (ip.podkop.fyi) always routes to a real
# proxy outbound when available, regardless of whether direct DPI-bypass sections
# (like zapret2) appear before or after proxy sections in UCI config.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

generate_config() {
  local fixture="$1" output="$2"
  mkdir -p "${output}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

# 1. zapret2 section is placed BEFORE proxy section
cat >"$WORK_DIR/zapret_first.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "zapret_sec",
      ".type": "section",
      "enabled": "1",
      "action": "zapret2",
      "domain": [ "discord.com" ]
    },
    {
      ".name": "proxy_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"A\",\"server\":\"a.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}" ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/zapret_first.json" "$WORK_DIR/zapret_first.out"

# Find route rule for ip.podkop.fyi
TARGET_OUTBOUND="$(grep -B 2 -A 3 '"domain": "ip.podkop.fyi"' "$WORK_DIR/zapret_first.out" | grep '"outbound":' | head -n 1 | awk -F'"' '{print $4}')"
[ "$TARGET_OUTBOUND" = "proxy_sec-out" ] ||
  fail "CHECK_PROXY_IP_DOMAIN must route to proxy_sec-out even when zapret2 is first; got '$TARGET_OUTBOUND'"

# 2. proxy section is placed BEFORE zapret2 section
cat >"$WORK_DIR/proxy_first.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "proxy_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"vless\",\"tag\":\"A\",\"server\":\"a.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}" ]
    },
    {
      ".name": "zapret_sec",
      ".type": "section",
      "enabled": "1",
      "action": "zapret2",
      "domain": [ "discord.com" ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/proxy_first.json" "$WORK_DIR/proxy_first.out"

TARGET_OUTBOUND="$(grep -B 2 -A 3 '"domain": "ip.podkop.fyi"' "$WORK_DIR/proxy_first.out" | grep '"outbound":' | head -n 1 | awk -F'"' '{print $4}')"
[ "$TARGET_OUTBOUND" = "proxy_sec-out" ] ||
  fail "CHECK_PROXY_IP_DOMAIN must route to proxy_sec-out when proxy is first; got '$TARGET_OUTBOUND'"

# 3. Only zapret2 section exists (no proxy sections)
cat >"$WORK_DIR/zapret_only.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "zapret_sec",
      ".type": "section",
      "enabled": "1",
      "action": "zapret2",
      "domain": [ "discord.com" ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/zapret_only.json" "$WORK_DIR/zapret_only.out"

TARGET_OUTBOUND="$(grep -B 2 -A 3 '"domain": "ip.podkop.fyi"' "$WORK_DIR/zapret_only.out" | grep '"outbound":' | head -n 1 | awk -F'"' '{print $4}')"
[ "$TARGET_OUTBOUND" = "zapret_sec-out" ] ||
  fail "CHECK_PROXY_IP_DOMAIN must route to zapret_sec-out when only zapret2 is configured; got '$TARGET_OUTBOUND'"

echo "OK: CHECK_PROXY_IP_DOMAIN route selection tests passed"
