#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Remote rule-set download transport on tachyon-core uses http_clients +
# rule_set[].http_client (no deprecated download_detour).

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": [ "1.1.1.1" ],
    "service_listen_address": "127.0.0.1",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "prox"
  },
  "section": [
    {
      ".name": "prox",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"socks\",\"tag\":\"prox-out\",\"server\":\"127.0.0.1\",\"server_port\":1080}" ]
    },
    {
      ".name": "main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"main-out\"}" ],
      "community_lists": [ "meta" ],
      "geoip_country": [ "ru" ],
      "geoip_mode": "exclude"
    }
  ]
}
JSON

printf '0.5.7\n' >"$WORK_DIR/core-version"
mkdir -p "$WORK_DIR/modern.json.section-cache"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core-version" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/modern.json" "127.0.0.1"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
function fail(msg) { die(msg + "\n"); }

let cfg = json(fs.readfile(ARGV[0]));
let rule_sets = (cfg.route && cfg.route.rule_set) || [];

let remote = [];
for (let rs in rule_sets)
    if (rs && rs.type == "remote")
        push(remote, rs);

if (length(remote) == 0)
    fail("expected at least one remote rule-set to assert the download transport on");

if (type(cfg.http_clients) != "array" || length(cfg.http_clients) == 0)
    fail("tachyon-core must declare http_clients");
if (cfg.route.default_http_client == null || cfg.route.default_http_client == "")
    fail("tachyon-core must set route.default_http_client");

let tags = [];
for (let c in cfg.http_clients) {
    if (!c || c.tag == null || c.tag == "")
        fail("http_clients entry without a tag");
    push(tags, c.tag);
}
if (index(tags, cfg.route.default_http_client) < 0)
    fail("default_http_client " + cfg.route.default_http_client + " is not a declared http_client");

for (let rs in remote) {
    if (rs.download_detour != null)
        fail("rule-set " + rs.tag + " still carries deprecated download_detour: " + sprintf("%J", rs));
    if (rs.http_client == null || rs.http_client == "")
        fail("rule-set " + rs.tag + " has no http_client: " + sprintf("%J", rs));
    if (index(tags, rs.http_client) < 0)
        fail("rule-set " + rs.tag + " references undeclared http_client " + rs.http_client);
}
print("modern transport: " + length(remote) + " remote rule-sets via http_client\n");
' "$WORK_DIR/modern.json" || fail "download transport regression"

# The pre-start ruleset pre-cache must also cover the GeoIP lists.
grep -Fq 'connections.geoip_country_list(section)' "$LIFECYCLE_UC" ||
  fail "lifecycle.uc prepare_community_rulesets must cover geoip_country rule-sets"
grep -Fq 'needed["geosite_ru"] = true' "$LIFECYCLE_UC" ||
  fail "lifecycle.uc prepare_community_rulesets must pre-cache geosite_ru"

printf 'remote rule-set download transport passed\n'
