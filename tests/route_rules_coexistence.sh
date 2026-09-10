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

# 1. Test coexistence: section with both domains and community_lists MUST generate separate rules
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
      ".name": "mixed_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\"}" ],
      "domain_suffix": [ "customdomain.org" ],
      "community_lists": [ "discord" ]
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

# Verify route rules in out.json
ucode -e '
let fs = require("fs");
let raw = fs.readfile("'"$output"'");
let cfg = json(raw);
let rules = cfg.route.rules || [];

let found_domain_only = false;
let found_ruleset_only = false;
let found_combined = false;

for (let r in rules) {
    if (r.domain_suffix && r.rule_set) {
        found_combined = true;
    }
    if (r.domain_suffix && !r.rule_set) {
        for (let d in r.domain_suffix) {
            if (d == "customdomain.org")
                found_domain_only = true;
        }
    }
    if (r.rule_set && !r.domain_suffix) {
        let rs_str = sprintf("%s", r.rule_set);
        if (index(rs_str, "discord") >= 0)
            found_ruleset_only = true;
    }
}

if (found_combined) {
    print("ERROR: found merged domain_suffix AND rule_set in single rule! Sing-box treats this as logical AND!\n");
    exit(1);
}
if (!found_domain_only) {
    print("ERROR: domain_suffix rule missing for customdomain.org\n");
    exit(2);
}
if (!found_ruleset_only) {
    print("ERROR: rule_set rule missing for discord\n");
    exit(3);
}
' || fail "Coexistence check failed: domain and ruleset rules are not cleanly separated"

# 2. Verify DPI-out is never selected as download_detour
cat >"$WORK_DIR/fixture_dpi.json" <<'JSON'
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
      ".name": "dpi_sec",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [
        "{\"tag\":\"DPI-out\",\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":1080}"
      ],
      "community_lists": [ "discord" ]
    }
  ]
}
JSON

output_dpi="$WORK_DIR/out_dpi.json"
mkdir -p "$output_dpi.section-cache" "$output_dpi.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_dpi.json" "$output_dpi" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let raw = fs.readfile("'"$output_dpi"'");
let cfg = json(raw);
let rulesets = cfg.route.rule_set || [];
for (let rs in rulesets) {
    if (rs.download_detour == "DPI-out") {
        print("ERROR: DPI-out was selected as download_detour!\n");
        exit(1);
    }
}
' || fail "DPI-out must never be set as download_detour"

# 3. Verify zapret section generates resolve action for rulesets and domains
cat >"$WORK_DIR/fixture_zapret_resolve.json" <<'JSON'
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
      ".name": "zapret",
      ".type": "section",
      "enabled": "1",
      "action": "zapret",
      "community_lists": [ "youtube" ]
    }
  ]
}
JSON

output_zapret_resolve="$WORK_DIR/out_zapret_resolve.json"
mkdir -p "$output_zapret_resolve.section-cache" "$output_zapret_resolve.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_zapret_resolve.json" "$output_zapret_resolve" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let raw = fs.readfile("'"$output_zapret_resolve"'");
let cfg = json(raw);
let rules = cfg.route.rules || [];
let found_resolve = false;
let found_route = false;
for (let r in rules) {
    if (r.action == "resolve" && r.rule_set)
        found_resolve = true;
    if (r.action == "route" && r.outbound == "zapret-out")
        found_route = true;
}
if (!found_resolve) {
    print("ERROR: zapret section did not generate action: resolve rule!\n");
    exit(1);
}
if (!found_route) {
    print("ERROR: zapret section did not generate action: route rule to zapret-out!\n");
    exit(2);
}
' || fail "zapret section must generate resolve rule before route rule"

printf "Route rules coexistence and detour checks passed\n"
