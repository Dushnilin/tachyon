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

# Test that a section with DSCP configuration does NOT emit "dscp" in sing-box route rules.
# sing-box does not support DSCP in route rules and aborts with:
# decode config ... route.rules[...].dscp: json: unknown field "dscp"
# DSCP matching is handled at the nftables layer (nft/apply.uc), not inside sing-box.

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
      ".name": "dscp_voice_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"voice-out\"}" ],
      "dscp": [ "0x2e", "ef" ],
      "domain_suffix": [ "discord.gg" ]
    },
    {
      ".name": "dscp_only_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"gaming-out\"}" ],
      "dscp": [ "0x22", "af41" ]
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

# Verify that NO route rule in out.json contains "dscp"
ucode -e '
let fs = require("fs");
let raw = fs.readfile("'"$output"'");
let cfg = json(raw);
let rules = cfg.route.rules || [];

for (let i = 0; i < length(rules); i++) {
    let r = rules[i];
    if (r.dscp != null) {
        print("FAIL: route.rules[" + i + "] contains forbidden field \"dscp\"\n");
        exit(1);
    }
}

// Verify valid domain_suffix was still preserved
let found_domain = false;
for (let r in rules) {
    if (r.domain_suffix) {
        for (let d in r.domain_suffix) {
            if (d == "discord.gg")
                found_domain = true;
        }
    }
}

if (!found_domain) {
    print("FAIL: domain_suffix discord.gg not found in route rules\n");
    exit(2);
}

print("OK\n");
' || fail "DSCP route rule check failed"

printf "PASS: dscp route config (no dscp in sing-box route rules)\n"
