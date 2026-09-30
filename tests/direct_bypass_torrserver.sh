#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
VALIDATOR_UC="$TACHYON_LIB/config/validator.uc"
TORRSERVER_UC="$TACHYON_LIB/torrserver/direct.uc"

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

# 1. Verify direct_bypass disabled -> no direct inbound
cat >"$WORK_DIR/no_bypass.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "direct_bypass_enabled": "0"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"Alpha\",\"server\":\"alpha.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}"
      ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/no_bypass.json" "$WORK_DIR/out_no_bypass.json"
if grep -Fq '"tag": "direct-bypass-in"' "$WORK_DIR/out_no_bypass.json"; then
  fail "direct-bypass-in should not be present when direct_bypass_enabled is 0"
fi

# 2. Verify direct_bypass enabled -> mixed inbound present with correct port and detour
cat >"$WORK_DIR/bypass_on.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "direct_bypass_enabled": "1",
    "direct_bypass_port": "3128"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"type\":\"vless\",\"tag\":\"Alpha\",\"server\":\"alpha.example\",\"server_port\":443,\"uuid\":\"00000000-0000-4000-8000-000000000001\",\"tls\":{\"enabled\":true}}"
      ]
    }
  ]
}
JSON

generate_config "$WORK_DIR/bypass_on.json" "$WORK_DIR/out_bypass_on.json"
grep -Fq '"tag": "direct-bypass-in"' "$WORK_DIR/out_bypass_on.json" ||
  fail "direct-bypass-in must be present when direct_bypass_enabled is 1"
grep -Fq '"listen_port": 3128' "$WORK_DIR/out_bypass_on.json" ||
  fail "direct-bypass-in must listen on configured port 3128"
grep -Fq '"outbound": "direct-bypass-out"' "$WORK_DIR/out_bypass_on.json" ||
  fail "direct-bypass-out must be configured"
grep -Fq 'direct-bypass-in' "$WORK_DIR/out_bypass_on.json" ||
  fail "direct-bypass-in must be routed"

# 3. Verify validator validates direct_bypass_port
cat >"$WORK_DIR/invalid_port.json" <<'JSON'
{
  "settings": {
    "direct_bypass_enabled": "1",
    "direct_bypass_port": "99999"
  }
}
JSON

if ucode -L "$TACHYON_LIB" "$VALIDATOR_UC" validate-fixture "$WORK_DIR/invalid_port.json" >/dev/null 2>&1; then
  fail "validator should reject direct_bypass_port 99999"
fi

# 4. Verify TorrServer direct rule recognition
sample_nft='table inet TachyonTorrServerDirect {
    chain output {
        type route hook output priority -151; policy accept;
        socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter comment "Tachyon TorrServer Direct"
    }
}'
echo "$sample_nft" | ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" rule-output-active "/services/torrserver" ||
  fail "TorrServer rule-output-active must match valid rule"

# 5. Verify TorrServer direct status outputs JSON
status_output="$(ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" status)"
echo "$status_output" | grep -Fq '"available":' ||
  fail "TorrServer status must include available field"
echo "$status_output" | grep -Fq '"running":' ||
  fail "TorrServer status must include running field"

printf 'direct bypass and torrserver tests passed\n'
