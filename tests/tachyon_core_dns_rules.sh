#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

# 1. Domain-only list (youtube): query route rule only, NO evaluate rule, NO match_response
printf 'v0.5.7\n' > "$WORK_DIR/core_ver"

cat > "$WORK_DIR/fixture_domain_only.json" << 'EOF'
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
      "community_lists": [ "youtube" ]
    }
  ]
}
EOF

output_dom="$WORK_DIR/out_dom.json"
mkdir -p "$output_dom.section-cache" "$output_dom.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_domain_only.json" "$output_dom" "127.0.0.1" "0" "1"

if grep -Fq '"action": "evaluate"' "$output_dom"; then
  fail "domain-only list must NOT generate evaluate DNS rule"
fi
if grep -Fq '"match_response"' "$output_dom"; then
  fail "domain-only list must NOT have match_response"
fi
grep -Fq '"action": "route"' "$output_dom" || fail "domain-only list must generate route DNS rule"

# 2. Mixed list (telegram): evaluate rule + match_response: true on response rule
cat > "$WORK_DIR/fixture_mixed.json" << 'EOF'
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
      ".name": "sec_tg",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_tg-out\"}" ],
      "community_lists": [ "telegram" ]
    }
  ]
}
EOF

output_mixed="$WORK_DIR/out_mixed.json"
mkdir -p "$output_mixed.section-cache" "$output_mixed.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_mixed.json" "$output_mixed" "127.0.0.1" "0" "1"

grep -Fq '"action": "evaluate"' "$output_mixed" || fail "mixed list must generate evaluate DNS rule"
grep -Fq '"match_response": true' "$output_mixed" || fail "mixed list must have match_response: true"

# 3. Both domain-only (russia_inside) and mixed (telegram)
cat > "$WORK_DIR/fixture_user_case.json" << 'EOF'
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
      ".name": "Main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"Main-out\"}" ],
      "community_lists": [ "russia_inside", "telegram" ],
      "community_subnets": "1"
    }
  ]
}
EOF

output_user="$WORK_DIR/out_user.json"
mkdir -p "$output_user.section-cache" "$output_user.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_user_case.json" "$output_user" "127.0.0.1" "0" "1"

ucode -L "$TACHYON_LIB" -e '
let common = require("core.common");
let cfg = common.read_json_file("'"$output_user"'");
if (!cfg || !cfg.dns || !cfg.dns.rules) {
    warn("Failed to read generated config\n");
    exit(1);
}

let svcb_rule = null;
let query_rule = null;
let eval_rule = null;
let resp_rule = null;

for (let r in cfg.dns.rules) {
    if (r.query_type && (r.query_type[0] == "HTTPS" || r.query_type[0] == "SVCB"))
        svcb_rule = r;
    if (r.action == "route" && !r.match_response && r.rule_set) {
        let rs = type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ];
        for (let s in rs) {
            if (index(s, "russia_inside") >= 0)
                query_rule = r;
        }
    }
    if (r.action == "evaluate")
        eval_rule = r;
    if (r.action == "route" && r.match_response === true && r.rule_set) {
        let rs = type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ];
        for (let s in rs) {
            if (index(s, "telegram") >= 0)
                resp_rule = r;
        }
    }
}

if (!svcb_rule) { warn("HTTPS/SVCB DNS rule missing\n"); exit(2); }
if (svcb_rule.action != "predefined" || svcb_rule.rcode != "NOERROR") {
    warn("HTTPS/SVCB rule must be predefined with rcode NOERROR, got action=" +
         svcb_rule.action + " rcode=" + svcb_rule.rcode + "\n");
    exit(7);
}
if (!query_rule) { warn("query rule for russia_inside missing\n"); exit(3); }
if (!eval_rule) { warn("eval_rule missing for telegram response\n"); exit(4); }
if (!resp_rule) { warn("resp_rule missing for telegram\n"); exit(5); }

let qrs = type(query_rule.rule_set) == "array" ? query_rule.rule_set : [ query_rule.rule_set ];
for (let s in qrs) {
    if (index(s, "telegram") >= 0) {
        warn("telegram leaked into query_rule!\n");
        exit(6);
    }
}
' || fail "user reproduction verification failed"

# 4. Source-based routing and excluded_ips with mixed ruleset
cat > "$WORK_DIR/fixture_scoped.json" << 'EOF'
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
      ".name": "sec_scoped",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_scoped-out\"}" ],
      "source_ip_cidr": [ "192.168.1.50/32" ],
      "excluded_ips": [ "192.168.1.200/32" ],
      "community_lists": [ "telegram" ]
    }
  ]
}
EOF

output_scoped="$WORK_DIR/out_scoped.json"
mkdir -p "$output_scoped.section-cache" "$output_scoped.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_scoped.json" "$output_scoped" "127.0.0.1" "0" "1"

ucode -L "$TACHYON_LIB" -e '
let common = require("core.common");
let cfg = common.read_json_file("'"$output_scoped"'");
let eval_rule = null;
let resp_rule = null;

for (let r in cfg.dns.rules) {
    if (r.action == "evaluate")
        eval_rule = r;
    if (r.action == "route" && (r.match_response === true || (r.rules && r.rules[0] && r.rules[0].match_response === true)))
        resp_rule = r;
}

if (!eval_rule) { warn("eval_rule missing in scoped section\n"); exit(1); }
if (!resp_rule) { warn("resp_rule missing in scoped section\n"); exit(2); }

if (eval_rule.type == "logical") {
    let has_invert = false;
    for (let child in eval_rule.rules) {
        if (child.invert && child.source_ip_cidr) has_invert = true;
    }
    if (!has_invert) exit(3);
} else if (!eval_rule.source_ip_cidr) {
    exit(4);
}

if (resp_rule.type == "logical") {
    let has_invert = false;
    for (let child in resp_rule.rules) {
        if (child.invert && child.source_ip_cidr) has_invert = true;
    }
    if (!has_invert) exit(5);
} else if (!resp_rule.source_ip_cidr) {
    exit(6);
}
' || fail "scoped section evaluate/response source matcher verification failed"

# 5. community_subnets=0 with mixed list
cat > "$WORK_DIR/fixture_subnets0.json" << 'EOF'
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
      ".name": "sec_no_sub",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_no_sub-out\"}" ],
      "community_lists": [ "telegram" ],
      "community_subnets": "0"
    }
  ]
}
EOF

output_subnets0="$WORK_DIR/out_subnets0.json"
mkdir -p "$output_subnets0.section-cache" "$output_subnets0.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_subnets0.json" "$output_subnets0" "127.0.0.1" "0" "1"

grep -Fq '"action": "evaluate"' "$output_subnets0" || fail "community_subnets=0 with mixed list must still generate evaluate"
grep -Fq '"match_response": true' "$output_subnets0" || fail "community_subnets=0 with mixed list must still have match_response"

# 6. Bypass section with routed DNS
cat >"$WORK_DIR/bypass_routed_dns_fixture.json" <<'EOF'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "ByPass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "community_lists": [ "russia_outside" ],
      "routed_dns_enabled": "1",
      "routed_dns_type": "doh",
      "routed_dns_server": [
        "https://dns.comss.one/dns-query",
        "https://dns2.comss.one/dns-query"
      ]
    }
  ]
}
EOF
output_bypass="$WORK_DIR/output_bypass.json"
mkdir -p "$output_bypass.section-cache" "$output_bypass.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/bypass_routed_dns_fixture.json" "$output_bypass" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));
let found_server = false;
for (let s in cfg.dns.servers || []) {
    if (s.tag == "ByPass-routed-dns-server") {
        found_server = true;
        if (s.type != "https" || s.server != "dns.comss.one" || s.detour) {
            warn("ByPass-routed-dns-server properties mismatch: " + json(s) + "\n");
            exit(1);
        }
    }
}
if (!found_server) { warn("ByPass-routed-dns-server not found in dns.servers\n"); exit(1); }

let found_dns_rule = false;
for (let r in cfg.dns.rules || []) {
    if (r.server == "ByPass-routed-dns-server")
        found_dns_rule = true;
}
if (!found_dns_rule) { warn("DNS rule targeting ByPass-routed-dns-server not found\n"); exit(1); }

let found_second = false;
for (let s in cfg.dns.servers || []) {
    if (s.tag == "ByPass-routed-dns-server-2") {
        found_second = true;
        if (s.type != "https" || s.server != "dns2.comss.one" || s.detour) {
            warn("ByPass-routed-dns-server-2 properties mismatch: " + json(s) + "\n");
            exit(1);
        }
    }
    if (s.tag == "ByPass-routed-dns-server-1") {
        warn("the first server must carry the un-indexed tag, not -1\n");
        exit(1);
    }
}
if (!found_second) { warn("second routed DNS server not found under the -2 tag\n"); exit(1); }

let found_route_rule = false;
for (let r in cfg.route.rules || []) {
    if (r.outbound == "bypass-out" && r.rule_set == "ByPass-russia_outside-community-ruleset")
        found_route_rule = true;
}
if (!found_route_rule) { warn("Route rule for ByPass community ruleset not found\n"); exit(1); }
' "$output_bypass" || fail "bypass with routed DNS verification failed"

# 7. Section with mixed list and excluded_ips WITHOUT source_ip_cidr
cat > "$WORK_DIR/fixture_issue60.json" << 'EOF'
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
      ".name": "vpn_issue60",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"vpn_issue60-out\"}" ],
      "community_lists": [ "telegram" ],
      "excluded_ips": [ "192.168.1.200" ]
    }
  ]
}
EOF

output_issue60="$WORK_DIR/out_issue60.json"
mkdir -p "$output_issue60.section-cache" "$output_issue60.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_issue60.json" "$output_issue60" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

let eval_rule = null;
let resp_rule = null;

for (let r in cfg.dns.rules || []) {
    if (r.action == "evaluate")
        eval_rule = r;
    if (r.action == "route" && (r.match_response === true || (r.rules && r.rules[0] && r.rules[0].match_response === true)))
        resp_rule = r;
}

if (!eval_rule) { warn("eval_rule missing in issue60 reproduction config\n"); exit(1); }
if (!resp_rule) { warn("resp_rule missing in issue60 reproduction config\n"); exit(2); }

if (eval_rule.type == "logical") {
    for (let child in eval_rule.rules || []) {
        if (!child || length(keys(child)) == 0) { warn("eval_rule contains empty condition sub-rule!\n"); exit(3); }
    }
}

if (!eval_rule.invert || !eval_rule.source_ip_cidr) {
    warn("eval_rule missing invert or source_ip_cidr\n");
    exit(4);
}

for (let r in cfg.dns.rules || []) {
    if (r.type == "logical") {
        for (let child in r.rules || []) {
            if (!child || length(keys(child)) == 0) { warn("dns rule contains empty sub-rule!\n"); exit(5); }
        }
    }
}
for (let r in cfg.route.rules || []) {
    if (r.type == "logical") {
        for (let child in r.rules || []) {
            if (!child || length(keys(child)) == 0) { warn("route rule contains empty sub-rule!\n"); exit(6); }
        }
    }
}
' "$output_issue60" || fail "issue60 reproduction config verification failed"

# 8. Cloudflare (infrastructure subnet) list
cat > "$WORK_DIR/fixture_cloudflare.json" << 'EOF'
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
      ".name": "sec_cf",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"sec_cf-out\"}" ],
      "community_lists": [ "cloudflare" ]
    }
  ]
}
EOF

output_cf="$WORK_DIR/out_cf.json"
mkdir -p "$output_cf.section-cache" "$output_cf.rulesets"
TACHYON_CORE_VERSION_FILE="$WORK_DIR/core_ver" \
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_cloudflare.json" "$output_cf" "127.0.0.1" "0" "1"

ucode -e '
let fs = require("fs");
let cfg = json(fs.readfile(ARGV[0]));

for (let r in cfg.dns.rules || []) {
    if (r.rule_set != null) {
        let rs = type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ];
        for (let s in rs) {
            if (s != null && index(s, "cloudflare") >= 0) {
                warn("cloudflare ruleset must NOT be in dns.rules!\n");
                exit(1);
            }
        }
    }
    if (r.action == "evaluate") {
        warn("evaluate DNS rule must not be created for pure subnet/CDN list!\n");
        exit(2);
    }
}

let found_route = false;
for (let r in cfg.route.rules || []) {
    if (r.outbound == "sec_cf-out") {
        let has_ruleset = false;
        let rs = type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ];
        for (let s in rs) {
            if (index(s, "cloudflare") >= 0) has_ruleset = true;
        }
        let has_cidrs = (type(r.ip_cidr) == "array" && length(r.ip_cidr) > 0) || (type(r.ip_cidr) == "string" && r.ip_cidr != "");
        if (has_ruleset || has_cidrs)
            found_route = true;
    }
}

if (!found_route) {
    warn("sec_cf-out route rule with cloudflare ruleset or ip_cidr not found!\n");
    exit(3);
}
' "$output_cf" || fail "cloudflare CDN subnet routing verification failed"

echo "tachyon-core DNS rules tests passed"
