#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
GENERATOR="$TACHYON_LIB/tachyon_core/generator.uc"
RULESETS="$TACHYON_LIB/tachyon_core/rulesets.uc"
LIFECYCLE="$TACHYON_LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "config_path": "/tmp/tachyon-core/config.json",
    "dns_type": "doh",
    "dns_server": [ "https://dns.google/dns-query" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "disable_quic": "0",
    "routing_strategy": "split"
  },
  "section": [
    {
      ".name": "RuDNS",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_type": "doh",
      "dns_server": [ "https://common.dot.dns.yandex.net/dns-query" ],
      "community_lists": [ "russia_outside" ],
      "condition_refs": [ "cond_RuDNS" ]
    },
    {
      ".name": "yt",
      ".type": "section",
      "enabled": "1",
      "action": "desync",
      "desync_preset": "tlsrec",
      "community_lists": [ "youtube" ],
      "source_ip_cidr": [ "192.168.10.222/32" ]
    },
    {
      ".name": "bye",
      ".type": "section",
      "enabled": "1",
      "action": "byedpi",
      "byedpi_cmd_opts": "-s1 -s3+s -r1+s -S",
      "condition_refs": [ "cond_bye" ]
    }
  ],
  "condition": [
    {
      ".name": "cond_RuDNS",
      ".type": "condition",
      "enabled": "1",
      "condition_type": "atomic",
      "community_lists": [ "russia_outside" ]
    },
    {
      ".name": "cond_bye",
      ".type": "condition",
      "enabled": "1",
      "condition_type": "atomic",
      "community_lists": [ "youtube" ],
      "source_ip_cidr": [ "192.168.10.119/32" ]
    }
  ]
}
JSON

TACHYON_LIB="$TACHYON_LIB" \
SB_VERSION_OVERRIDE="0.2.1" \
SB_VARIANT_OVERRIDE="tachyon-core" \
  ucode -L "$TACHYON_LIB" "$GENERATOR" generate-config-fixture \
  "$WORK_DIR/fixture.json" "$WORK_DIR/out.json" "127.0.0.1" "0" "1"

ucode -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

function assert(cond, msg) {
    if (!cond) {
        warn("FAIL: " + msg + "\n");
        exit(1);
    }
}

function as_arr(v) {
    if (v == null) return [];
    return type(v) == "array" ? v : [ v ];
}

function has(arr, item) {
    for (let x in as_arr(arr))
        if (x == item) return true;
    return false;
}

let dns_rules = cfg.dns.rules || [];
let rudns_idx = -1;
let yt_idx = -1;
let bye_idx = -1;
let fallback_rule = null;

for (let i = 0; i < length(dns_rules); i++) {
    let r = dns_rules[i];
    if (r.server == "RuDNS-dns-server" && has(r.rule_set, "RuDNS-russia_outside-community-ruleset"))
        rudns_idx = i;
    if (r.server == "fakeip-server" && has(r.rule_set, "yt-youtube-community-ruleset"))
        yt_idx = i;
    if (r.server == "fakeip-server" && has(r.rule_set, "bye-youtube-community-ruleset"))
        bye_idx = i;
    if (r.server == "dnsmasq-server" && has(r.inbound, "source-dns-in"))
        fallback_rule = r;
}

assert(yt_idx >= 0 && bye_idx >= 0 && rudns_idx >= 0,
    sprintf("expected yt (%d), bye (%d), and RuDNS (%d) DNS rules", yt_idx, bye_idx, rudns_idx));
assert(yt_idx < rudns_idx && bye_idx < rudns_idx,
    sprintf("FakeIP DNS rules (yt=%d, bye=%d) must precede RuDNS (%d)", yt_idx, bye_idx, rudns_idx));

assert(fallback_rule != null, "source-dns-in fallback rule must exist");
assert(has(fallback_rule.source_ip_cidr, "192.168.10.222/32") && has(fallback_rule.source_ip_cidr, "192.168.10.119/32"),
    "source-dns-in fallback must include source_ip_cidr from both section and condition_refs");

let route_rules = cfg.route.rules || [];
let yt_udp_reject = -1;
let yt_tcp_route = -1;
let bye_udp_reject = -1;
let bye_tcp_route = -1;

for (let i = 0; i < length(route_rules); i++) {
    let r = route_rules[i];
    if (r.action == "reject" && has(r.network, "udp") && has(r.rule_set, "yt-youtube-community-ruleset"))
        yt_udp_reject = i;
    if (r.outbound == "yt-out" && has(r.network, "tcp") && has(r.rule_set, "yt-youtube-community-ruleset"))
        yt_tcp_route = i;
    if (r.action == "reject" && has(r.network, "udp") && has(r.rule_set, "bye-youtube-community-ruleset"))
        bye_udp_reject = i;
    if (r.outbound == "bye-out" && has(r.network, "tcp") && has(r.rule_set, "bye-youtube-community-ruleset"))
        bye_tcp_route = i;
}

assert(yt_udp_reject >= 0 && yt_tcp_route > yt_udp_reject,
    sprintf("TCP-only desync must reject UDP before TCP route (udp=%d, tcp=%d)", yt_udp_reject, yt_tcp_route));
assert(bye_udp_reject >= 0 && bye_tcp_route > bye_udp_reject,
    sprintf("ByeDPI must reject UDP before TCP route (udp=%d, tcp=%d)", bye_udp_reject, bye_tcp_route));
' -- "$WORK_DIR/out.json"

grep -Fq '" >/dev/null"' "$RULESETS" ||
  fail "rulesets.uc srs_file_parses must redirect stdout to /dev/null"

grep -Fq 'append_reload_action(actions, plan.needs_sing_box_reload, "tachyon-core")' "$LIFECYCLE" ||
  fail "lifecycle.uc reload_actions_summary must label reload as tachyon-core"

printf 'PASS: bugreport_rudns_desync_byedpi\n'
