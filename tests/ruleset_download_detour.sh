#!/usr/bin/env bash
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Verify remote rule_set gets download_detour assigned to section's proxy outbound
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "myproxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

grep -Fq '"download_detour": "myproxy-out"' "$output" || \
  fail "remote community ruleset must automatically get download_detour set to section outbound"

# 2. Verify download_via_proxy fallback selects first enabled proxy section
cat >"$WORK_DIR/fixture-detour-enabled.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "download_lists_via_proxy": "1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "first_proxy",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ]
    },
    {
      ".name": "other_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "community_lists": [ "google_ai" ]
    }
  ]
}
JSON

output2="$WORK_DIR/out2.json"
mkdir -p "$output2.section-cache" "$output2.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture-detour-enabled.json" "$output2" "127.0.0.1" "0" "1"

grep -Fq '"download_detour": "first_proxy-out"' "$output2" || \
  fail "global download_lists_via_proxy without explicit section must default to first enabled proxy section"

printf "ruleset download detour checks passed\n"
