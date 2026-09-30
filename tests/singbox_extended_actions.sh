#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# sing-box-extended action shapes.
#
# Both of these shipped broken against sing-box-extended 2.7.x and aborted the
# whole configuration on start:
#   * warp carried "mtu", which that build rejects ("unknown field \"mtu\"");
#   * masque was emitted as an endpoint with a profiles[] array, while the build
#     models MASQUE as an outbound with a single "profile" object.
# The shape is asserted here so a regression cannot reach a release again; the
# real binaries were checked separately (stock 1.14.2 / extended 1.14.1-extended-2.7.2 / lx 1.14.2-lx.8).

GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$fixture" "$output" "127.0.0.1"
}

cat >"$WORK_DIR/warp.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ] },
  "section": [
    { ".name": "warp1", ".type": "section", "enabled": "1", "action": "warp",
      "warp_account_id": "acct-1", "warp_private_key": "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=",
      "warp_access_token": "tok-1" }
  ]
}
JSON

cat >"$WORK_DIR/masque.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": [ "77.88.8.8" ] },
  "section": [
    { ".name": "masque1", ".type": "section", "enabled": "1", "action": "masque",
      "masque_account_id": "acct-1", "masque_access_token": "tok-1" }
  ]
}
JSON

generate_config "$WORK_DIR/warp.json" "$WORK_DIR/warp-config.json"
generate_config "$WORK_DIR/masque.json" "$WORK_DIR/masque-config.json"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
function fail(msg) { die(msg + "\n"); }

function items(config, key) {
    return config[key] || [];
}
function find_by_tag(list, tag) {
    for (let item in list)
        if (item && item.tag == tag) return item;
    return null;
}

// WARP: endpoint, no mtu (rejected by sing-box-extended).
let warp_cfg = json(fs.readfile(ARGV[0]));
let warp = find_by_tag(items(warp_cfg, "endpoints"), "warp1-out");
if (warp == null) fail("warp endpoint not generated");
if (warp.mtu != null) fail("warp endpoint must not carry mtu: " + sprintf("%J", warp));
if (warp.profile == null || warp.profile.id != "acct-1")
    fail("warp profile.id not filled: " + sprintf("%J", warp));
if (warp.profile.auth_token != "tok-1")
    fail("warp profile.auth_token not filled: " + sprintf("%J", warp));

// MASQUE: outbound with a single profile object, not an endpoint with profiles[].
let masque_cfg = json(fs.readfile(ARGV[1]));
if (find_by_tag(items(masque_cfg, "endpoints"), "masque1-out") != null)
    fail("masque must not be generated as an endpoint");
let masque = find_by_tag(items(masque_cfg, "outbounds"), "masque1-out");
if (masque == null) fail("masque outbound not generated");
if (masque.type != "masque") fail("masque outbound has wrong type: " + sprintf("%J", masque));
if (type(masque.profile) != "object") fail("masque needs a profile object: " + sprintf("%J", masque));
if (masque.profile.id != "acct-1" || masque.profile.auth_token != "tok-1")
    fail("masque profile not filled: " + sprintf("%J", masque));
if (masque.profiles != null) fail("masque must not use a profiles[] array: " + sprintf("%J", masque));
' "$WORK_DIR/warp-config.json" "$WORK_DIR/masque-config.json" || fail "extended action shape regression"

printf 'sing-box extended action shapes passed\n'
