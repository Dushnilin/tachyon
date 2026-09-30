#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Remote rule-set download transport.
#
# sing-box 1.14.0 deprecated the rule-set `download_detour` field and removed it
# in 1.16.0, replacing it with `http_client` plus declared `http_clients`. A
# field report from an extended 1.14.1 core showed the deprecation warning on
# every start. `http_clients` is an unknown top-level field below 1.14, where
# sing-box aborts the whole configuration, so the transport is version gated and
# BOTH shapes are asserted here via SB_VERSION_STATE_FILE.
#
# A community rule-set is emitted as remote only when no cached .srs exists, so
# this test deliberately never creates the ruleset folder.
#
# When a sing-box binary is on PATH the generated configurations are also fed
# through `sing-box check`.

if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"

# A proxy section to detour through, plus a section whose community list and
# GeoIP country both resolve to uncached rule-sets.
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

generate_for_version() {
  local version="$1"
  local output="$2"
  printf '%s\n' "$version" >"$WORK_DIR/version-$version"
  mkdir -p "${output}.section-cache"
  SB_VERSION_STATE_FILE="$WORK_DIR/version-$version" \
    ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$output" "127.0.0.1"
}

assert_transport() {
  local config="$1"
  local expect="$2"
  ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
function fail(msg) { die(msg + "\n"); }

let cfg = json(fs.readfile(ARGV[0]));
let expect = ARGV[1];
let rule_sets = (cfg.route && cfg.route.rule_set) || [];

let remote = [];
for (let rs in rule_sets)
    if (rs && rs.type == "remote")
        push(remote, rs);

if (length(remote) == 0)
    fail("expected at least one remote rule-set to assert the download transport on");

if (expect == "modern") {
    if (type(cfg.http_clients) != "array" || length(cfg.http_clients) == 0)
        fail("sing-box >= 1.14 must declare http_clients");
    if (cfg.route.default_http_client == null || cfg.route.default_http_client == "")
        fail("sing-box >= 1.14 must set route.default_http_client");

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
    print("modern transport: " + length(remote) + " remote rule-sets via http_client");
}
else {
    // Below 1.14 http_clients is an unknown field and aborts the config, so the
    // legacy field must be used and the new one must be absent entirely.
    if (cfg.http_clients != null)
        fail("sing-box < 1.14 must not emit http_clients: " + sprintf("%J", cfg.http_clients));
    for (let rs in remote) {
        if (rs.http_client != null)
            fail("sing-box < 1.14 must not emit rule_set.http_client");
        if (rs.download_detour == null || rs.download_detour == "")
            fail("sing-box < 1.14 rule-set " + rs.tag + " lost its download_detour");
    }
    print("legacy transport: " + length(remote) + " remote rule-sets via download_detour");
}
' "$config" "$expect" || fail "$expect download transport regression"
}

check_with_binary() {
  local config="$1"
  local label="$2"
  command -v sing-box >/dev/null 2>&1 || return 0
  sing-box check -c "$config" >/dev/null 2>&1 ||
    fail "$label config rejected by $(sing-box version | head -1)"
  printf '  %s accepted by %s\n' "$label" "$(sing-box version | head -1)"
}

generate_for_version "1.13.0" "$WORK_DIR/legacy.json"
generate_for_version "1.14.0" "$WORK_DIR/modern.json"

assert_transport "$WORK_DIR/legacy.json" legacy
assert_transport "$WORK_DIR/modern.json" modern
check_with_binary "$WORK_DIR/legacy.json" "legacy(1.13.0)"
check_with_binary "$WORK_DIR/modern.json" "modern(1.14.0)"

# The pre-start ruleset pre-cache must also cover the GeoIP lists: they come
# from geoip_country, not from community_lists. An uncached remote rule-set makes
# sing-box download it during startup, where a GitHub hiccup kills the core with
# "initialize rule-set: context deadline exceeded".
grep -Fq 'connections.geoip_country_list(section)' "$LIFECYCLE_UC" ||
  fail "lifecycle.uc prepare_community_rulesets must cover geoip_country rule-sets"
grep -Fq 'needed["geosite_ru"] = true' "$LIFECYCLE_UC" ||
  fail "lifecycle.uc prepare_community_rulesets must pre-cache geosite_ru"

printf 'remote rule-set download transport passed\n'
