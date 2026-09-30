#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

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
      ".name": "sec_yt",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_yt-out\"}" ],
      "domain_suffix": [ "youtube.com" ],
      "excluded_ips": [ "192.168.1.50" ]
    },
    {
      ".name": "sec_gg",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_gg-out\"}" ],
      "domain_suffix": [ "google.com" ]
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

let found_global_direct = false;
let found_scoped_logical = false;
let found_sec_gg = false;

for (let r in rules) {
    // A global direct rule would have outbound direct-out, source_ip_cidr set, and no domain conditions
    if (r.outbound == "direct-out" && r.source_ip_cidr && !r.domain_suffix && !r.domain && !r.rule_set) {
        found_global_direct = true;
    }
    // Scoped logical rule for sec_yt-out
    if (r.type == "logical" && r.outbound == "sec_yt-out" && r.mode == "and" && type(r.rules) == "array") {
        let has_domain = false;
        let has_inverted_src = false;
        for (let sub in r.rules) {
            if (sub.domain_suffix && index(sub.domain_suffix, "youtube.com") >= 0)
                has_domain = true;
            if (sub.invert == true && (sub.source_ip_cidr == "192.168.1.50/32" || index(sub.source_ip_cidr, "192.168.1.50/32") >= 0))
                has_inverted_src = true;
        }
        if (has_domain && has_inverted_src)
            found_scoped_logical = true;
    }
    if (r.outbound == "sec_gg-out") {
        found_sec_gg = true;
    }
}

if (found_global_direct)
    die("Found unconditional global direct-out rule for excluded IP, breaking subsequent sections!\n");

if (!found_scoped_logical)
    die("Expected scoped logical rule for sec_yt-out with inverted source_ip_cidr not found!\n");

if (!found_sec_gg)
    die("sec_gg-out rule not found in generated sing-box rules!\n");
' || fail "section_excluded_ips failed verification"

printf 'PASS: section_excluded_ips\n'
