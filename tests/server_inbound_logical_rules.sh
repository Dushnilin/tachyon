#!/usr/bin/env bash
# Issue #144: server inbound with routing_mode = "rules" must clone logical route rules
# (e.g. sections using geoip/rulesets producing type: "logical" rules for tproxy-in).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
SERVERS_UC="$TACHYON_LIB/singbox/servers.uc"
[ -f "$GENERATOR_UC" ] || fail "missing $GENERATOR_UC"

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
      ".name": "MAIN",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"MAIN-out\"}" ],
      "domain_suffix": [ "example.com" ],
      "geoip_mode": "exclude",
      "geoip_country": [ "ru" ]
    }
  ],
  "server": [
    {
      ".name": "Hysteria2Home",
      ".type": "server",
      "enabled": "1",
      "protocol": "hysteria2",
      "listen_port": "24444",
      "server_password": "testpassword",
      "routing_mode": "rules"
    }
  ]
}
JSON

config="$WORK_DIR/config.json"
mkdir -p "$config.section-cache" "$config.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$config" "127.0.0.1" "0" "1" >/dev/null

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let raw = fs.readfile("'"$config"'");
let parsed = json(raw);

let server_logical_rules = 0;
let home_logical_rules = 0;

for (let rule in parsed.route.rules) {
  if (rule.type == "logical" && rule.outbound == "MAIN-out") {
    for (let child in rule.rules) {
      if (child.inbound == "server-Hysteria2Home-in")
        server_logical_rules++;
      if (child.inbound == "tproxy-in" || (type(child.inbound) == "array" && child.inbound[0] == "tproxy-in"))
        home_logical_rules++;
    }
  }
}

if (home_logical_rules == 0) {
  warn("FAIL: expected logical rules for home inbound\n");
  exit(1);
}

if (server_logical_rules == 0) {
  warn("FAIL: server-Hysteria2Home-in received 0 logical rules for MAIN-out (Issue #144)\n");
  exit(1);
}

print("PASS: found " + server_logical_rules + " cloned logical rules for server inbound\n");
'
