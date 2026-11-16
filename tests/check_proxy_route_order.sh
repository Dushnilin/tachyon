#!/usr/bin/env bash
# Verifies that CHECK_PROXY_IP_DOMAIN (ip.podkop.fyi) always routes to a real
# proxy outbound when available, regardless of whether local desync sections
# appear before or after proxy sections in UCI config.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

generate_config() {
  local fixture="$1" output="$2"
  mkdir -p "${output}.section-cache"
  TACHYON_CORE_VERSION_OVERRIDE="0.5.7" ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

# 1. desync section is placed BEFORE proxy section
cat >"$WORK_DIR/desync_first.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "desync_sec",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
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

generate_config "$WORK_DIR/desync_first.json" "$WORK_DIR/desync_first.out"

# Find route rule for ip.podkop.fyi
TARGET_OUTBOUND="$(grep -B 2 -A 3 '"domain": "ip.podkop.fyi"' "$WORK_DIR/desync_first.out" | grep '"outbound":' | head -n 1 | awk -F'"' '{print $4}')"
[ "$TARGET_OUTBOUND" = "proxy_sec-out" ] ||
  fail "CHECK_PROXY_IP_DOMAIN must route to proxy_sec-out even when desync is first; got '$TARGET_OUTBOUND'"

# 2. proxy section is placed BEFORE desync section
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
      ".name": "desync_sec",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
      "domain": [ "discord.com" ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/proxy_first.json" "$WORK_DIR/proxy_first.out"

TARGET_OUTBOUND="$(grep -B 2 -A 3 '"domain": "ip.podkop.fyi"' "$WORK_DIR/proxy_first.out" | grep '"outbound":' | head -n 1 | awk -F'"' '{print $4}')"
[ "$TARGET_OUTBOUND" = "proxy_sec-out" ] ||
  fail "CHECK_PROXY_IP_DOMAIN must route to proxy_sec-out when proxy is first; got '$TARGET_OUTBOUND'"

# 3. Only desync section exists (no proxy sections)
cat >"$WORK_DIR/desync_only.json" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "desync_sec",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "auto",
      "domain": [ "discord.com" ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/desync_only.json" "$WORK_DIR/desync_only.out"

TARGET_OUTBOUND="$(grep -B 2 -A 3 '"domain": "ip.podkop.fyi"' "$WORK_DIR/desync_only.out" | grep '"outbound":' | head -n 1 | awk -F'"' '{print $4}')"
[ "$TARGET_OUTBOUND" = "desync_sec-out" ] ||
  fail "CHECK_PROXY_IP_DOMAIN must route to desync_sec-out when only desync is configured; got '$TARGET_OUTBOUND'"

echo "OK: CHECK_PROXY_IP_DOMAIN route selection tests passed"
