#!/usr/bin/env bash
# A section that excludes a client keeps its sing-box rule: apply_excluded_source_ips
# wraps it into a logical AND and moves every matcher, the tproxy inbound included,
# into rules[]. The readiness check read only the top level, so as soon as a section
# carried excluded_ips and was not the first failover candidate - the only one that
# also gets a flat rule for the proxy-check domain - routes_configured went false.
# Status then said the section was stopped and the Zapret/Zapret2 diagnostic showed
# "routing rules are not configured" in red, while nfqws kept desyncing and
# sing-box kept routing. Reported on 1.4.9.
#
# The predicate is called through the module export, not copied here: a fixture that
# reimplements it would pass against the old code and fail against the new one.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
RUNTIME_UC="$TACHYON_LIB/providers/nfqueue/runtime.uc"
[ -f "$RUNTIME_UC" ] || fail "missing $RUNTIME_UC"

# Two zapret2 sections, so the excluded one is not the failover candidate that also
# receives a flat catch-all. The exclusion is what used to hide its inbound.
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
      ".name": "one",
      ".type": "section",
      "enabled": "1",
      "action": "zapret2",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"one-out\"}" ],
      "domain_suffix": [ "youtube.com" ]
    },
    {
      ".name": "two",
      ".type": "section",
      "enabled": "1",
      "action": "zapret2",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"two-out\"}" ],
      "domain_suffix": [ "discord.com" ],
      "excluded_ips": [ "192.168.1.50" ]
    }
  ]
}
JSON

config="$WORK_DIR/config.json"
mkdir -p "$config.section-cache" "$config.rulesets"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$config" "127.0.0.1" "0" "1" >/dev/null

ucode -L "$TACHYON_LIB" -e '
let common = require("core.common");
let runtime = require("providers.nfqueue.runtime");
let has_route_rule = runtime.has_route_rule;

let config = common.read_json_file("'"$config"'");

// Sanity: the excluded section must really have produced a wrapped rule, otherwise
// this test would pass for the wrong reason - a config without the rule at all.
let wrapped = false;
for (let rule in config.route.rules || []) {
    if (type(rule) == "object" && rule.type == "logical" && rule.outbound == "two-out")
        wrapped = true;
}
if (!wrapped)
    die("fixture did not produce a logical rule for two-out; the test would prove nothing\n");

if (!has_route_rule(config, "tproxy-in", "one-out"))
    die("plain section one-out lost its route rule\n");
if (!has_route_rule(config, "tproxy-in", "two-out"))
    die("section two-out excludes a client and is still reported unconfigured\n");

// Negative cases: the check must not turn into a rubber stamp.
let foreign_inbound = {
    route: { rules: [ { action: "route", inbound: [ "socks-in" ], outbound: "x-out" } ] }
};
if (has_route_rule(foreign_inbound, "tproxy-in", "x-out"))
    die("a rule bound to another inbound counted as ours\n");

let logical_foreign = {
    route: { rules: [ {
        type: "logical", mode: "and", action: "route", outbound: "x-out",
        rules: [ { inbound: [ "socks-in" ] }, { invert: true, source_ip_cidr: [ "10.0.0.0/8" ] } ]
    } ] }
};
if (has_route_rule(logical_foreign, "tproxy-in", "x-out"))
    die("a wrapped rule bound to another inbound counted as ours\n");

let logical_ours = {
    route: { rules: [ {
        type: "logical", mode: "and", action: "route", outbound: "x-out",
        rules: [ { inbound: [ "tproxy-in", "tproxy6-in" ] }, { invert: true, source_ip_cidr: [ "10.0.0.0/8" ] } ]
    } ] }
};
if (!has_route_rule(logical_ours, "tproxy-in", "x-out"))
    die("a wrapped rule carrying our inbound was not recognised\n");

let logical_or = {
    route: { rules: [ {
        type: "logical", mode: "or", action: "route", outbound: "x-out",
        rules: [ { inbound: [ "socks-in" ] }, { inbound: [ "tproxy-in" ] } ]
    } ] }
};
if (!has_route_rule(logical_or, "tproxy-in", "x-out"))
    die("an or-branch carrying our inbound was not recognised\n");

let missing_tag = { route: { rules: [ { action: "route", inbound: [ "tproxy-in" ], outbound: "other-out" } ] } };
if (has_route_rule(missing_tag, "tproxy-in", "x-out"))
    die("a rule for another outbound counted as ours\n");

let not_a_route = { route: { rules: [ { action: "reject", inbound: [ "tproxy-in" ], outbound: "x-out" } ] } };
if (has_route_rule(not_a_route, "tproxy-in", "x-out"))
    die("a non-route action counted as a route rule\n");
' || fail "excluded_ips must not hide a section route rule from the readiness check"

printf 'PASS: zapret_excluded_ips_route_rule\n'