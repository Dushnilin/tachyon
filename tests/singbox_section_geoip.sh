#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$ROOT_DIR/tachyon/files/usr/lib" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
GENERATOR_UC="$TACHYON_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

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
      "geoip_country": [ "ru" ],
      "geoip_mode": "exclude"
    },
    {
      ".name": "sec_all_noru",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_noru-out\"}" ],
      "match_all": "1",
      "geoip_country": [ "ru" ],
      "geoip_mode": "exclude"
    },
    {
      ".name": "sec_pure_ru",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_ru-out\"}" ],
      "geoip_country": [ "ru" ],
      "geoip_mode": "include"
    },
    {
      ".name": "sec_sub",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_sub-out\"}" ],
      "domain_suffix": [ "other.com" ]
    },
    {
      ".name": "sec_both",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_both-out\"}" ],
      "domain_suffix": [ "twitch.tv" ],
      "geoip_country": [ "ru" ],
      "geoip_mode": "exclude",
      "excluded_ips": [ "192.168.1.99" ]
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

let sec_yt_logical_found = false;
let sec_yt_unscoped_found = false;
let sec_noru_rule_count = 0;
let sec_noru_inverted_found = false;
let sec_noru_unconstrained_all = false;
let sec_pure_ru_found = false;
let sec_sub_found = false;
let sec_both_found = false;

for (let r in rules) {
    if (r.domain == "ip.podkop.fyi" || (type(r.domain) == "array" && index(r.domain, "ip.podkop.fyi") >= 0))
        continue;
    if (r.inbound == "service-mixed-in" || (type(r.inbound) == "array" && index(r.inbound, "service-mixed-in") >= 0))
        continue;

    // 1. Check sec_yt: Should be a logical rule combining domain_suffix and inverted geoip/geosite rule_set
    if (r.outbound == "sec_yt-out") {
        if (r.type == "logical" && r.mode == "and" && type(r.rules) == "array") {
            let has_domain = false;
            let has_inverted_geo = false;
            for (let sub in r.rules) {
                if (sub.domain_suffix && index(sub.domain_suffix, "youtube.com") >= 0)
                    has_domain = true;
                if (sub.invert == true && sub.rule_set) {
                    let rs = type(sub.rule_set) == "array" ? sub.rule_set : [ sub.rule_set ];
                    for (let tag in rs) {
                        if (index(tag, "sec_yt-geoip_ru") >= 0 || index(tag, "sec_yt-geosite_ru") >= 0)
                            has_inverted_geo = true;
                    }
                }
            }
            if (has_domain && has_inverted_geo)
                sec_yt_logical_found = true;
        } else {
            // A non-logical rule for sec_yt-out that is unscoped
            sec_yt_unscoped_found = true;
        }
    }

    // 2. Check sec_all_noru: Should have an inverted rule_set and NOT have an unconstrained all-traffic rule
    if (r.outbound == "sec_all_noru-out") {
        sec_noru_rule_count++;
        if (r.type == "logical" && r.mode == "and") {
            for (let sub in r.rules) {
                if (sub.invert == true && sub.rule_set)
                    sec_noru_inverted_found = true;
            }
        } else if (r.invert == true && r.rule_set) {
            sec_noru_inverted_found = true;
        } else if (!r.domain && !r.domain_suffix && !r.rule_set && !r.ip_cidr && !r.source_ip_cidr) {
            sec_noru_unconstrained_all = true;
        }
    }

    // 3. Check sec_pure_ru: Pure GeoIP section without domain
    if (r.outbound == "sec_pure_ru-out") {
        if (r.type == "logical" && r.mode == "and") {
            for (let sub in r.rules) {
                if (!sub.invert && sub.rule_set)
                    sec_pure_ru_found = true;
            }
        } else if (r.rule_set && !r.invert) {
            sec_pure_ru_found = true;
        }
    }

    // 4. Check sec_sub
    if (r.outbound == "sec_sub-out") {
        sec_sub_found = true;
    }

    // 5. Check sec_both: Single logical rule combining domain, inverted GeoIP, AND inverted client IP
    if (r.outbound == "sec_both-out") {
        if (r.type == "logical" && r.mode == "and" && type(r.rules) == "array") {
            let has_domain = false;
            let has_inverted_geo = false;
            let has_inverted_src = false;
            for (let sub in r.rules) {
                if (sub.domain_suffix && index(sub.domain_suffix, "twitch.tv") >= 0)
                    has_domain = true;
                if (sub.invert == true && sub.rule_set)
                    has_inverted_geo = true;
                if (sub.invert == true && (sub.source_ip_cidr == "192.168.1.99/32" || (type(sub.source_ip_cidr) == "array" && index(sub.source_ip_cidr, "192.168.1.99/32") >= 0)))
                    has_inverted_src = true;
            }
            if (has_domain && has_inverted_geo && has_inverted_src)
                sec_both_found = true;
        }
    }
}

if (!sec_yt_logical_found)
    die("Expected scoped logical rule for sec_yt-out (youtube.com AND NOT ru) not found!\n");

if (sec_yt_unscoped_found)
    die("Found unwanted unscoped rule for sec_yt-out!\n");

if (!sec_noru_inverted_found)
    die("Expected inverted geoip rule for sec_noru-out not found!\n");

if (sec_noru_unconstrained_all)
    die("Found unconstrained all-traffic rule for sec_noru-out that negates GeoIP exclusion!\n");

if (!sec_pure_ru_found)
    die("Expected GeoIP include rule for sec_ru-out not found!\n");

if (!sec_sub_found)
    die("sec_sub-out rule not found!\n");

if (!sec_both_found)
    die("Expected combined logical rule for sec_both-out (domain + inverted geoip + inverted client ip) not found!\n");
' || fail "singbox_section_geoip verification failed"

printf 'PASS: singbox_section_geoip\n'
