#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
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

# 4. Verify TorrServer direct rule recognition (FakeIP-exempted by default)
sample_nft='table inet TachyonTorrServerDirect {
    chain output {
        type route hook output priority -151; policy accept;
        ip daddr != 198.18.0.0/15 socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter comment "Tachyon TorrServer Direct"
        ip6 daddr != fc00::/18 socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter comment "Tachyon TorrServer Direct v6"
    }
}'
echo "$sample_nft" | ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" rule-output-active "/services/torrserver" ||
  fail "TorrServer rule-output-active must match FakeIP-exempted rule"

legacy_nft='table inet TachyonTorrServerDirect {
    chain output {
        type route hook output priority -151; policy accept;
        socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter comment "Tachyon TorrServer Direct"
    }
}'
if echo "$legacy_nft" | ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" rule-output-active "/services/torrserver"; then
  fail "TorrServer rule-output-active must reject un-exempted rule when FakeIP is enabled"
fi

cat >"$WORK_DIR/uci_fakeip_off.state" <<'STATE'
tachyon.settings.fakeip_enabled=0
STATE
echo "$legacy_nft" | TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_fakeip_off.state" \
  ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" rule-output-active "/services/torrserver" ||
  fail "TorrServer rule-output-active must match un-exempted rule when FakeIP is disabled"

cat >"$WORK_DIR/uci_fakeip_custom.state" <<'STATE'
tachyon.settings.fakeip_enabled=1
tachyon.settings.fakeip_inet4_range=100.64.0.0/10
tachyon.settings.fakeip_inet6_range=fd00::/16
STATE
custom_nft='table inet TachyonTorrServerDirect {
    chain output {
        type route hook output priority -151; policy accept;
        ip daddr != 100.64.0.0/10 socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter comment "Tachyon TorrServer Direct"
        ip6 daddr != fd00::/16 socket cgroupv2 level 2 "services/torrserver" meta mark set 0x08000000 counter comment "Tachyon TorrServer Direct v6"
    }
}'
echo "$custom_nft" | TACHYON_UCI_STATE_FILE="$WORK_DIR/uci_fakeip_custom.state" \
  ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" rule-output-active "/services/torrserver" ||
  fail "TorrServer rule-output-active must match custom FakeIP CIDR ranges"

# 4b. Verify NUL-delimited /proc/<pid>/cmdline matching & helper rejection
printf '/usr/bin/torrserver\0-p\08090\0-d\0/etc/torrserver\0' | \
  ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" is-torrserver-cmdline ||
  fail "is-torrserver-cmdline must match NUL-separated /usr/bin/torrserver cmdline"

printf '/opt/torrserver/torrserver-linux-arm64\0-p\08090\0' | \
  ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" is-torrserver-cmdline ||
  fail "is-torrserver-cmdline must match torrserver-* binary names"

if printf 'zsh\0-c\0tachyon component_action torrserver_direct enable\0' | \
  ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" is-torrserver-cmdline; then
  fail "is-torrserver-cmdline must not match shell commands mentioning torrserver_direct"
fi

if printf '/usr/bin/ucode\0-L\0/usr/lib/tachyon\0/usr/lib/tachyon/torrserver/direct.uc\0worker\0' | \
  ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" is-torrserver-cmdline; then
  fail "is-torrserver-cmdline must not match direct.uc worker itself"
fi

# 5. Verify TorrServer direct status outputs JSON
status_output="$(ucode -L "$TACHYON_LIB" "$TORRSERVER_UC" status)"
echo "$status_output" | grep -Fq '"available":' ||
  fail "TorrServer status must include available field"
echo "$status_output" | grep -Fq '"running":' ||
  fail "TorrServer status must include running field"
echo "$status_output" | grep -Fq '"installed":' ||
  fail "TorrServer status must include installed field"
echo "$status_output" | grep -Fq '"version":' ||
  fail "TorrServer status must include version field"

ucode -L "$TACHYON_LIB" -e '
let catalog = require("components.catalog");
if (type(catalog.resolve_torrserver_arch_suffix) != "function" || type(catalog.resolve_torrserver_release) != "function") {
    warn("FAIL: catalog TorrServer release resolvers missing\n");
    exit(1);
}
'

printf 'direct bypass and torrserver tests passed\n'
