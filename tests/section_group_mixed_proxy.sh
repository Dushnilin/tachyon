#!/usr/bin/env bash
# Group member section with a mixed proxy: the mixed inbound must route into
# the group urltest, not at the member selector (issues #143/#155).
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

LINK_A1='vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha'
LINK_B1='vless://00000000-0000-4000-8000-000000000003@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta'

cat >"$WORK_DIR/fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn" },
  "section": [
    { ".name": "alpha", ".type": "section", "enabled": "1", "action": "connection",
      "domain_suffix": [ "alpha.example" ],
      "selector_proxy_links": [ "$LINK_A1" ],
      "mixed_proxy_enabled": "1", "mixed_proxy_port": "2090",
      "mixed_proxy_auth_enabled": "1",
      "mixed_proxy_username": "u", "mixed_proxy_password": "p" },
    { ".name": "beta", ".type": "section", "enabled": "1", "action": "connection",
      "domain_suffix": [ "beta.example" ],
      "selector_proxy_links": [ "$LINK_B1" ] },
    { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
      "group_members": [ "alpha", "beta" ] }
  ]
}
JSON

cfg="$WORK_DIR/config.json"
mkdir -p "${cfg}.section-cache"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$cfg" "127.0.0.1"

ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));

function outbound_exists(want) {
    for (let outbound in config.outbounds || [])
        if (outbound && outbound.tag == want)
            return true;
    return false;
}

let rule = null;
for (let r in config.route.rules || [])
    if (r.inbound == "alpha-mixed-in" && r.outbound && r.outbound != "direct-out")
        rule = r;
if (!rule)
    die("no mixed inbound route rule for the group member section\n");
if (rule.outbound != "grp-urltest-out")
    die("mixed proxy of a group member must route into the group urltest, got " +
        rule.outbound + "\n");
if (!outbound_exists(rule.outbound))
    die("mixed route rule points at a missing outbound " + rule.outbound + "\n");
' "$cfg" || fail "group member mixed proxy behavior"

printf 'Group member mixed proxy checks passed\n'
