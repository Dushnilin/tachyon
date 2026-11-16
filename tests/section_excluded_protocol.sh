#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

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
      ".name": "sec_youtube",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_youtube-out\"}" ],
      "domain_suffix": [ "youtube.com" ],
      "excluded_protocol": [ "quic" ]
    },
    {
      ".name": "sec_main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_main-out\"}" ],
      "domain_suffix": [ "chatgpt.com" ],
      "match_all": "1"
    }
  ]
}
JSON

output="$WORK_DIR/out.json"
mkdir -p "$output.section-cache" "$output.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$output"'"));
let rules = cfg.route.rules || [];

let found_global_quic_direct = false;
let found_scoped_yt_logical = false;
let found_sec_main = false;

for (let r in rules) {
    // Global regression: direct-out rule with protocol quic and no section domain/ip/rule_set
    if (r.outbound == "direct-out" && !r.domain_suffix && !r.domain && !r.rule_set && !r.ip_cidr &&
        (r.protocol == "quic" || (type(r.protocol) == "array" && index(r.protocol, "quic") >= 0))) {
        found_global_quic_direct = true;
    }
    if (r.outbound == "sec_youtube-out" && r.type == "logical" && r.mode == "and" && type(r.rules) == "array") {
        let has_yt = false;
        let has_inv_quic = false;
        for (let sub in r.rules) {
            if (sub.domain_suffix && index(type(sub.domain_suffix) == "array" ? sub.domain_suffix : [sub.domain_suffix], "youtube.com") >= 0)
                has_yt = true;
            if (sub.invert == true && (sub.protocol == "quic" || (type(sub.protocol) == "array" && index(sub.protocol, "quic") >= 0)))
                has_inv_quic = true;
        }
        if (has_yt && has_inv_quic)
            found_scoped_yt_logical = true;
    }
    if (r.outbound == "sec_main-out")
        found_sec_main = true;
}

if (found_global_quic_direct) {
    warn("FAIL: excluded_protocol emitted a global quic -> direct-out rule\n");
    exit(1);
}
if (!found_scoped_yt_logical) {
    warn("FAIL: expected scoped logical rule on sec_youtube-out with invert:true protocol quic\n");
    exit(2);
}
if (!found_sec_main) {
    warn("FAIL: expected sec_main-out rule\n");
    exit(3);
}
' || fail "section_excluded_protocol assertions failed"

printf 'section_excluded_protocol checks passed\n'
