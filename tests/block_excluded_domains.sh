#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
ROUTE_EXPLAIN_UC="$TACHYON_LIB/diagnostics/route_explain.uc"
STATE_UC="$TACHYON_LIB/service/state.uc"

printf '%s\n' "0.5.9" >"$WORK_DIR/core-version"
export TACHYON_CORE_VERSION_FILE="$WORK_DIR/core-version"
export TACHYON_DNS_FAILOVER_STATE_FILE="$WORK_DIR/missing-dns-failover.json"
export TACHYON_SECTION_FAIL_STATE_FILE="$WORK_DIR/missing-fail-state.json"

# 1. Block section with ads_hagezi_pro + excluded_domains 'full:metrika.yandex.ru'
cat >"$WORK_DIR/block-excluded.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "adblock",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "community_lists": [ "ads_hagezi_pro" ],
      "excluded_domains": [ "full:metrika.yandex.ru" ]
    },
    {
      ".name": "proxy_yandex",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"proxy_yandex-out\"}" ],
      "domain_suffix": [ "yandex.ru" ]
    }
  ]
}
JSON

OUT_BLOCK="$WORK_DIR/out-block.json"
mkdir -p "$OUT_BLOCK.section-cache" "$OUT_BLOCK.rulesets"
ucode -S -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/block-excluded.json" "$OUT_BLOCK" "127.0.0.1" "0" "1"

ucode -S -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$OUT_BLOCK"'"));
let dns_rules = cfg.dns && cfg.dns.rules ? cfg.dns.rules : [];
let route_rules = cfg.route && cfg.route.rules ? cfg.route.rules : [];

let has_dns_a = false;
let has_dns_aaaa = false;
let has_route_reject = false;

function has_inverted_metrika(subrules) {
    for (let sub in (subrules || [])) {
        if (sub.invert == true && type(sub.domain) == "array" && index(sub.domain, "metrika.yandex.ru") >= 0)
            return true;
    }
    return false;
}

function has_hagezi_ruleset(subrules) {
    for (let sub in (subrules || [])) {
        let rs = sub.rule_set;
        if (type(rs) == "string" && index(rs, "ads_hagezi_pro") >= 0)
            return true;
        if (type(rs) == "array") {
            for (let tag in rs) {
                if (index(tag, "ads_hagezi_pro") >= 0)
                    return true;
            }
        }
    }
    return false;
}

for (let r in dns_rules) {
    if (r.action == "predefined" && r.type == "logical" && r.mode == "and" &&
        has_hagezi_ruleset(r.rules) && has_inverted_metrika(r.rules)) {
        let is_a = false;
        let is_aaaa = false;
        for (let sub in r.rules) {
            if (type(sub.query_type) == "array" && index(sub.query_type, "A") >= 0)
                is_a = true;
            if (type(sub.query_type) == "array" && index(sub.query_type, "AAAA") >= 0)
                is_aaaa = true;
        }
        if (is_a && type(r.answer) == "array" && r.answer[0] && r.answer[0].value == "0.0.0.0")
            has_dns_a = true;
        if (is_aaaa && type(r.answer) == "array" && r.answer[0] && r.answer[0].value == "::")
            has_dns_aaaa = true;
    }
}

for (let r in route_rules) {
    if (r.action == "reject" && r.type == "logical" && r.mode == "and" &&
        has_hagezi_ruleset(r.rules) && has_inverted_metrika(r.rules)) {
        has_route_reject = true;
    }
}

if (!has_dns_a) {
    warn("FAIL: missing logical predefined 0.0.0.0 DNS rule with invert:true domain metrika.yandex.ru\n");
    exit(1);
}
if (!has_dns_aaaa) {
    warn("FAIL: missing logical predefined :: DNS rule with invert:true domain metrika.yandex.ru\n");
    exit(2);
}
if (!has_route_reject) {
    warn("FAIL: missing logical reject route rule with invert:true domain metrika.yandex.ru\n");
    exit(3);
}
' || fail "block excluded_domains predefined/reject verification failed"

# 2. excluded_domains_text with full:/domain:/keyword:/regex: + bare domain and connections.excluded_domain_conditions
ucode -S -L "$TACHYON_LIB" -e '
let conn = require("config.connections");
let sec = {
    ".name": "blk",
    "action": "block",
    "excluded_domains": [ "full:metrika.yandex.ru", "domain:mc.yandex.ru" ],
    "excluded_domains_text": "# comment\nanalytics.example.org\nkeyword:metric\nregex:^ads\\.[0-9]+"
};
let exc = conn.excluded_domain_conditions(sec);
if (index(exc.domain, "metrika.yandex.ru") < 0) {
    warn("FAIL: expected metrika.yandex.ru in exc.domain\n");
    exit(1);
}
if (index(exc.domain_suffix, "mc.yandex.ru") < 0 || index(exc.domain_suffix, "analytics.example.org") < 0) {
    warn("FAIL: expected mc.yandex.ru and analytics.example.org in exc.domain_suffix\n");
    exit(2);
}
if (index(exc.domain_keyword, "metric") < 0) {
    warn("FAIL: expected metric in exc.domain_keyword\n");
    exit(3);
}
if (index(exc.domain_regex, "^ads\\.[0-9]+") < 0) {
    warn("FAIL: expected regex in exc.domain_regex\n");
    exit(4);
}
' || fail "excluded_domain_conditions prefix parsing failed"

# 3. DNS (disable_fakeip=1) and Bypass ordered BEFORE Block emit their rules before Block
cat >"$WORK_DIR/order-dns-before-block.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "custom_dns",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "disable_fakeip": "1",
      "dns_type": "udp",
      "dns_server": "9.9.9.9",
      "domain_suffix": [ "ads.example.com" ]
    },
    {
      ".name": "allow_bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "ok.ads.example.com" ]
    },
    {
      ".name": "adblock",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "domain_suffix": [ "ads.example.com" ]
    }
  ]
}
JSON

OUT_ORDER="$WORK_DIR/out-order.json"
mkdir -p "$OUT_ORDER.section-cache" "$OUT_ORDER.rulesets"
ucode -S -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/order-dns-before-block.json" "$OUT_ORDER" "127.0.0.1" "0" "1"

ucode -S -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$OUT_ORDER"'"));
let dns_rules = cfg.dns && cfg.dns.rules ? cfg.dns.rules : [];
let route_rules = cfg.route && cfg.route.rules ? cfg.route.rules : [];

let custom_dns_idx = -1;
let bypass_dns_idx = -1;
let block_dns_idx = -1;

for (let i = 0; i < length(dns_rules); i++) {
    let r = dns_rules[i];
    if (r.server == "custom_dns-dns-server" && custom_dns_idx < 0)
        custom_dns_idx = i;
    if (r.server == "dns-server" && type(r.domain_suffix) == "array" && index(r.domain_suffix, "ok.ads.example.com") >= 0 && bypass_dns_idx < 0)
        bypass_dns_idx = i;
    if (r.action == "predefined" && type(r.domain_suffix) == "array" && index(r.domain_suffix, "ads.example.com") >= 0 && block_dns_idx < 0)
        block_dns_idx = i;
}

if (custom_dns_idx < 0 || bypass_dns_idx < 0 || block_dns_idx < 0) {
    warn(sprintf("FAIL: missing expected dns rules: custom=%d bypass=%d block=%d\n", custom_dns_idx, bypass_dns_idx, block_dns_idx));
    exit(1);
}
if (!(custom_dns_idx < bypass_dns_idx && bypass_dns_idx < block_dns_idx)) {
    warn(sprintf("FAIL: expected custom_dns (%d) < bypass (%d) < block (%d) in dns.rules\n", custom_dns_idx, bypass_dns_idx, block_dns_idx));
    exit(2);
}

let bypass_route_idx = -1;
let block_route_idx = -1;
for (let i = 0; i < length(route_rules); i++) {
    let r = route_rules[i];
    if (r.outbound == "bypass-out" && type(r.domain_suffix) == "array" && index(r.domain_suffix, "ok.ads.example.com") >= 0 && bypass_route_idx < 0)
        bypass_route_idx = i;
    if (r.action == "reject" && type(r.domain_suffix) == "array" && index(r.domain_suffix, "ads.example.com") >= 0 && block_route_idx < 0)
        block_route_idx = i;
}
if (bypass_route_idx < 0 || block_route_idx < 0 || !(bypass_route_idx < block_route_idx)) {
    warn(sprintf("FAIL: expected bypass (%d) < block (%d) in route.rules\n", bypass_route_idx, block_route_idx));
    exit(3);
}
' || fail "section ordering between pre_fakeip dns / bypass and block failed"

# 3b. Reverse order: Block ordered BEFORE DNS (disable_fakeip=1) emits Block first
cat >"$WORK_DIR/order-block-before-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "1.1.1.1",
    "bootstrap_dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "adblock",
      ".type": "section",
      "enabled": "1",
      "action": "block",
      "domain_suffix": [ "ads.example.com" ]
    },
    {
      ".name": "custom_dns",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "disable_fakeip": "1",
      "dns_type": "udp",
      "dns_server": "9.9.9.9",
      "domain_suffix": [ "ads.example.com" ]
    }
  ]
}
JSON

OUT_REV_ORDER="$WORK_DIR/out-rev-order.json"
mkdir -p "$OUT_REV_ORDER.section-cache" "$OUT_REV_ORDER.rulesets"
ucode -S -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/order-block-before-dns.json" "$OUT_REV_ORDER" "127.0.0.1" "0" "1"

ucode -S -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$OUT_REV_ORDER"'"));
let dns_rules = cfg.dns && cfg.dns.rules ? cfg.dns.rules : [];
let custom_dns_idx = -1;
let block_dns_idx = -1;
for (let i = 0; i < length(dns_rules); i++) {
    let r = dns_rules[i];
    if (r.server == "custom_dns-dns-server" && custom_dns_idx < 0)
        custom_dns_idx = i;
    if (r.action == "predefined" && type(r.domain_suffix) == "array" && index(r.domain_suffix, "ads.example.com") >= 0 && block_dns_idx < 0)
        block_dns_idx = i;
}
if (custom_dns_idx < 0 || block_dns_idx < 0 || !(block_dns_idx < custom_dns_idx)) {
    warn(sprintf("FAIL: expected block (%d) < custom_dns (%d) when block comes first\n", block_dns_idx, custom_dns_idx));
    exit(1);
}
' || fail "reverse ordering between block and pre_fakeip dns failed"

# 4. Issue #440 compatibility: list community_subnets 'youtube' and legacy_condition_values fallback
ucode -S -L "$TACHYON_LIB" -e '
let conn = require("config.connections");
let list_sec = { ".name": "yt", "action": "connection", "community_subnets": [ "youtube" ] };
let res = conn.community_lists(list_sec);
if (length(res) != 1 || res[0] != "youtube") {
    warn(sprintf("FAIL: expected [youtube], got %J\n", res));
    exit(1);
}
let bool_on = conn.community_lists({ ".name": "b1", "community_subnets": "1" });
let bool_off = conn.community_lists({ ".name": "b0", "community_subnets": "0" });
if (length(bool_on) != 0 || length(bool_off) != 0) {
    warn("FAIL: boolean community_subnets tokens must not leak into community_lists()\n");
    exit(2);
}
' || fail "connections.community_lists() compatibility for community_subnets failed"

cat >"$WORK_DIR/legacy-cond-fallback.json" <<'JSON'
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
      "conditions_text_mode": "1",
      "community_subnets": [ "youtube" ],
      "ip_cidr": [ "203.0.113.0/24" ]
    }
  ]
}
JSON

OUT_FALLBACK="$WORK_DIR/out-fallback.json"
mkdir -p "$OUT_FALLBACK.section-cache" "$OUT_FALLBACK.rulesets"
ucode -S -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/legacy-cond-fallback.json" "$OUT_FALLBACK" "127.0.0.1" "0" "1"

ucode -S -L "$TACHYON_LIB" -e '
let fs = require("fs");
let cfg = json(fs.readfile("'"$OUT_FALLBACK"'"));
let rs_tags = map(cfg.route.rule_set || [], r => r.tag);
let has_yt_rs = false;
for (let t in rs_tags) {
    if (index(t, "youtube") >= 0)
        has_yt_rs = true;
}
if (!has_yt_rs) {
    warn(sprintf("FAIL: expected youtube rule_set from list community_subnets, got %J\n", rs_tags));
    exit(1);
}
let has_cidr = false;
for (let r in (cfg.route.rules || [])) {
    if (r.outbound == "sec_yt-out" && type(r.ip_cidr) == "array" && index(r.ip_cidr, "203.0.113.0/24") >= 0)
        has_cidr = true;
}
if (!has_cidr) {
    warn("FAIL: expected 203.0.113.0/24 route rule when conditions_text_mode=1 and ip_cidr_text is empty\n");
    exit(2);
}
' || fail "generator community_subnets list or conditions_text_mode fallback failed"

# 5. route_explain records excluded_domains reason and lets subsequent section handle domain
ucode -S -L "$TACHYON_LIB" -e '
let re = require("diagnostics.route_explain");
let uci_cfg = {
    settings: { ".name": "settings", ".type": "settings", "enabled": "1", "dns_type": "udp", "dns_server": "1.1.1.1" },
    sections: [
        {
            ".name": "adblock",
            ".type": "section",
            "enabled": "1",
            "label": "AdBlock",
            "action": "block",
            "community_lists": [ "ads_hagezi_pro" ],
            "excluded_domains": [ "full:metrika.yandex.ru" ]
        },
        {
            ".name": "proxy_ru",
            ".type": "section",
            "enabled": "1",
            "label": "ProxyRU",
            "action": "connection",
            "domain_suffix": [ "yandex.ru" ]
        }
    ],
    conditions: {},
    outbound_sources: {},
    outbound_groups: {},
    balancers: {},
    nodes: [],
    dns_hosts: []
};

let m = re.explain_route("192.168.1.50", "metrika.yandex.ru", 443, "tcp", { uci_cfg: uci_cfg });
let d = re.explain_route("192.168.1.50", "doubleclick.net", 443, "tcp", { uci_cfg: uci_cfg });

if (!m || !m.success || m.verdict != "proxied" || m.matched_section != "proxy_ru") {
    warn(sprintf("FAIL: metrika.yandex.ru should fall through to proxy_ru, got verdict=%J section=%J\n", m && m.verdict, m && m.matched_section));
    exit(1);
}
if (type(m.excluded_sections) != "array" || length(m.excluded_sections) == 0 ||
    m.excluded_sections[0].section != "adblock" || m.excluded_sections[0].excluded_by != "full:metrika.yandex.ru") {
    warn(sprintf("FAIL: expected excluded_sections entry for adblock/full:metrika.yandex.ru, got %J\n", m.excluded_sections));
    exit(2);
}
if (index(m.explanation.en, "excluded_domains") < 0 || index(m.explanation.ru, "excluded_domains") < 0) {
    warn("FAIL: expected explanation.en and explanation.ru to mention excluded_domains\n");
    exit(3);
}
let text_report = re.format_text_report(m);
if (index(text_report, "excluded_domains") < 0) {
    warn("FAIL: expected format_text_report output to include excluded_domains\n");
    exit(4);
}
if (!d || !d.success || d.verdict != "blocked" || d.matched_section != "adblock") {
    warn(sprintf("FAIL: doubleclick.net must still be blocked by adblock, got verdict=%J section=%J\n", d && d.verdict, d && d.matched_section));
    exit(5);
}
' || fail "route_explain excluded_domains verification failed"

# 6. service/state.uc reload signatures include excluded_domains only when non-empty
cat >"$WORK_DIR/state-empty.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "enabled": "1" },
  "section": [
    { ".name": "adblock", ".type": "section", "enabled": "1", "action": "block", "community_lists": [ "ads_hagezi_pro" ] }
  ]
}
JSON
cat >"$WORK_DIR/state-excl.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "enabled": "1" },
  "section": [
    { ".name": "adblock", ".type": "section", "enabled": "1", "action": "block", "community_lists": [ "ads_hagezi_pro" ], "excluded_domains": [ "full:metrika.yandex.ru" ] }
  ]
}
JSON
cat >"$WORK_DIR/state-excl2.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "enabled": "1" },
  "section": [
    { ".name": "adblock", ".type": "section", "enabled": "1", "action": "block", "community_lists": [ "ads_hagezi_pro" ], "excluded_domains": [ "full:metrika.yandex.ru" ], "excluded_domains_text": "domain:tracker.example" }
  ]
}
JSON

BODY_EMPTY="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-body-fixture "$WORK_DIR/state-empty.json")"
BODY_EXCL="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-body-fixture "$WORK_DIR/state-excl.json")"
BODY_EXCL2="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-body-fixture "$WORK_DIR/state-excl2.json")"
if printf '%s\n' "$BODY_EMPTY" | grep -Fq "excluded_domains"; then
  fail "tachyon-core signature body must omit excluded_domains when empty"
fi
if ! printf '%s\n' "$BODY_EXCL" | grep -Fq "[rule.adblock.excluded_domains]"; then
  printf '%s\n' "$BODY_EXCL" >&2
  fail "tachyon-core signature body must include [rule.adblock.excluded_domains] when non-empty"
fi
if ! printf '%s\n' "$BODY_EXCL" | grep -Fq "full:metrika.yandex.ru|"; then
  printf '%s\n' "$BODY_EXCL" >&2
  fail "tachyon-core signature body must include excluded_domains value when non-empty"
fi
if ! printf '%s\n' "$BODY_EXCL2" | grep -Fq "full:metrika.yandex.ru|domain:tracker.example"; then
  printf '%s\n' "$BODY_EXCL2" >&2
  fail "tachyon-core signature body must include excluded_domains_text when non-empty"
fi

CORE_HASH_EMPTY="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/state-empty.json")"
CORE_HASH_EXCL="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/state-excl.json")"
CORE_HASH_EXCL2="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" tachyon-core-signature-fixture "$WORK_DIR/state-excl2.json")"
if [ "$CORE_HASH_EMPTY" = "$CORE_HASH_EXCL" ] || [ "$CORE_HASH_EXCL" = "$CORE_HASH_EXCL2" ]; then
  fail "tachyon-core signature hash must change when excluded_domains or excluded_domains_text changes"
fi

NFT_HASH_EMPTY="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" nft-signature-fixture "$WORK_DIR/state-empty.json")"
NFT_HASH_EXCL="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" nft-signature-fixture "$WORK_DIR/state-excl.json")"
NFT_HASH_EXCL2="$(ucode -S -L "$TACHYON_LIB" "$STATE_UC" nft-signature-fixture "$WORK_DIR/state-excl2.json")"
if [ "$NFT_HASH_EMPTY" = "$NFT_HASH_EXCL" ] || [ "$NFT_HASH_EXCL" = "$NFT_HASH_EXCL2" ]; then
  fail "nft signature hash must change when excluded_domains or excluded_domains_text changes"
fi

printf 'PASS: block_excluded_domains\n'
