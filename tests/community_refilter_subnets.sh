#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES_UC="$TACHYON_LIB/components/updates.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
APPLY_UC="$TACHYON_LIB/nft/apply.uc"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

# 1. config/rule.uc: refilter + all 14 remaining lists + 5 aliases have subnet lists; domain-only lists do not
ucode -L "$TACHYON_LIB" - <<'UCODE'
let rule = require("config.rule");
let should_have = [
    "antifilter", "refilter", "ru_blocked", "ru_blocked_all",
    "ru_domains", "ru_whitelist", "fastly", "games_all",
    "geoip_cn", "geoip_ru", "geoip_us", "netflix", "origin", "pubg", "tor",
    "antifilter_community", "runetfreedom_blocked", "runetfreedom_blocked_all",
    "roscomvpn_whitelist", "roscomvpn_ru"
];
for (let s in should_have) {
    if (!rule.community_service_has_subnet_list(s)) {
        warn("FAIL: expected community_service_has_subnet_list('" + s + "') == true\n");
        exit(1);
    }
}
for (let s in [ "youtube", "ai_all", "geoblock", "geosite_ru" ]) {
    if (rule.community_service_has_subnet_list(s)) {
        warn("FAIL: expected community_service_has_subnet_list('" + s + "') == false\n");
        exit(1);
    }
}
if (type(rule.canonical_community_subnet_service) != "function") {
    warn("FAIL: missing canonical_community_subnet_service export\n");
    exit(1);
}
let aliases = {
    antifilter_community: "antifilter",
    runetfreedom_blocked: "ru_blocked",
    runetfreedom_blocked_all: "ru_blocked_all",
    roscomvpn_whitelist: "ru_whitelist",
    roscomvpn_ru: "ru_domains",
    refilter: "refilter"
};
for (let k, v in aliases) {
    let got = rule.canonical_community_subnet_service(k);
    if (got != v) {
        warn("FAIL: canonical_community_subnet_service('" + k + "') = '" + got + "', want '" + v + "'\n");
        exit(1);
    }
}
UCODE

# 2. components/updates.uc: BUILTIN_SUBNET_URLS includes refilter, all 14 others, and aliases
for svc in antifilter refilter ru_blocked ru_blocked_all ru_domains ru_whitelist fastly games_all geoip_cn geoip_ru geoip_us netflix origin pubg tor; do
  got_url="$(ucode -L "$TACHYON_LIB" "$UPDATES_UC" builtin-subnet-urls "$svc")"
  assert_eq "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/subnets/${svc}.lst" "$got_url" "builtin-subnet-urls $svc"
done
alias_url="$(ucode -L "$TACHYON_LIB" "$UPDATES_UC" builtin-subnet-urls antifilter_community)"
assert_eq "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/subnets/antifilter.lst" "$alias_url" "builtin-subnet-urls alias antifilter_community"

# 3. generator_routes.uc: kind=="domains" list with community-subnets-<id>.lst emits local source subnets ruleset ONLY for route.rules (never DNS), respects community_subnets=0, and omits dangling ruleset on clean install
FIX_DIR="$WORK_DIR/gen"
mkdir -p "$FIX_DIR"
cat >"$FIX_DIR/fixture-refilter.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "77.88.8.8",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "Main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"direct-out\"}" ],
      "community_lists": [ "refilter" ],
      "community_subnets": "1"
    }
  ]
}
JSON

# 3a. With populated community-subnets-refilter.lst
OUT_ON="$FIX_DIR/cfg-on.json"
mkdir -p "${OUT_ON}.rulesets"
printf '2.16.1.65/32\n2.16.1.105/32\n' > "${OUT_ON}.rulesets/community-subnets-refilter.lst"
printf 'TCRS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "${OUT_ON}.rulesets/community-refilter.trs"
TACHYON_LIB="$TACHYON_LIB" TMP_RULESET_FOLDER="${OUT_ON}.rulesets" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$FIX_DIR/fixture-refilter.json" "$OUT_ON" "127.0.0.1" "0" "1" ||
  fail "generate-config-fixture failed for refilter with subnets=1"

node - "$OUT_ON" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const ruleSets = (cfg.route && cfg.route.rule_set) || [];
const subRs = ruleSets.find(rs => rs && rs.tag === 'builtin-refilter-subnets-ruleset');
if (!subRs) {
  console.error('FAIL: missing builtin-refilter-subnets-ruleset in route.rule_set:', JSON.stringify(ruleSets.map(x => x && x.tag)));
  process.exit(1);
}
if (subRs.type !== 'local' || subRs.format !== 'source' || !subRs.path) {
  console.error('FAIL: unexpected builtin-refilter-subnets-ruleset entry:', subRs);
  process.exit(1);
}
const srcDoc = JSON.parse(fs.readFileSync(subRs.path, 'utf8'));
const cidrs = (srcDoc.rules || []).flatMap(r => r.ip_cidr || []);
if (!cidrs.includes('2.16.1.65/32')) {
  console.error('FAIL: 2.16.1.65/32 missing from generated subnet JSON ruleset:', cidrs);
  process.exit(1);
}
const routeUsesSub = (cfg.route && cfg.route.rules || []).some(r => {
  const rs = r && r.rule_set;
  return Array.isArray(rs) ? rs.includes('builtin-refilter-subnets-ruleset') : rs === 'builtin-refilter-subnets-ruleset';
});
if (!routeUsesSub) {
  console.error('FAIL: route.rules does not reference builtin-refilter-subnets-ruleset');
  process.exit(1);
}
const dnsUsesSub = (cfg.dns && cfg.dns.rules || []).some(r => {
  const rs = r && r.rule_set;
  return Array.isArray(rs) ? rs.includes('builtin-refilter-subnets-ruleset') : rs === 'builtin-refilter-subnets-ruleset';
});
if (dnsUsesSub) {
  console.error('FAIL: dns.rules must NEVER reference builtin-refilter-subnets-ruleset');
  process.exit(1);
}
const dnsUsesDomains = (cfg.dns && cfg.dns.rules || []).some(r => {
  const rs = r && r.rule_set;
  return Array.isArray(rs) ? rs.includes('Main-refilter-community-ruleset') : rs === 'Main-refilter-community-ruleset';
});
if (!dnsUsesDomains) {
  console.error('FAIL: dns.rules must still reference Main-refilter-community-ruleset');
  process.exit(1);
}
NODE

# 3b. With community_subnets="0": no subnet ruleset generated
cat >"$FIX_DIR/fixture-refilter-off.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "enabled": "1",
    "dns_type": "udp",
    "dns_server": "77.88.8.8",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "Main",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"direct-out\"}" ],
      "community_lists": [ "refilter" ],
      "community_subnets": "0"
    }
  ]
}
JSON

OUT_OFF="$FIX_DIR/cfg-off.json"
mkdir -p "${OUT_OFF}.rulesets"
printf '2.16.1.65/32\n' > "${OUT_OFF}.rulesets/community-subnets-refilter.lst"
printf 'TCRS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "${OUT_OFF}.rulesets/community-refilter.trs"
TACHYON_LIB="$TACHYON_LIB" TMP_RULESET_FOLDER="${OUT_OFF}.rulesets" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$FIX_DIR/fixture-refilter-off.json" "$OUT_OFF" "127.0.0.1" "0" "1" ||
  fail "generate-config-fixture failed for refilter with subnets=0"

node - "$OUT_OFF" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const ruleSets = (cfg.route && cfg.route.rule_set) || [];
if (ruleSets.some(rs => rs && rs.tag === 'builtin-refilter-subnets-ruleset')) {
  console.error('FAIL: community_subnets=0 must NOT emit builtin-refilter-subnets-ruleset');
  process.exit(1);
}
NODE

# 3c. Clean install without .lst file: no dangling local subnet ruleset
OUT_EMPTY="$FIX_DIR/cfg-empty.json"
mkdir -p "${OUT_EMPTY}.rulesets"
TACHYON_LIB="$TACHYON_LIB" TMP_RULESET_FOLDER="${OUT_EMPTY}.rulesets" \
  ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$FIX_DIR/fixture-refilter.json" "$OUT_EMPTY" "127.0.0.1" "0" "1" ||
  fail "generate-config-fixture failed for clean refilter"

node - "$OUT_EMPTY" <<'NODE'
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const ruleSets = (cfg.route && cfg.route.rule_set) || [];
if (ruleSets.some(rs => rs && rs.tag === 'builtin-refilter-subnets-ruleset')) {
  console.error('FAIL: missing .lst file must NOT emit dangling builtin-refilter-subnets-ruleset');
  process.exit(1);
}
NODE

# 4. nft/apply.uc runtime signature changes when refilter has community_subnets=1 vs 0 (and 0 matches domain-only baseline)
cat >"$FIX_DIR/uci-sig-on.state" <<'UCI'
tachyon.settings=settings
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=proxy
tachyon.Main.community_lists=refilter
tachyon.Main.community_subnets=1
UCI
cat >"$FIX_DIR/uci-sig-off.state" <<'UCI'
tachyon.settings=settings
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=proxy
tachyon.Main.community_lists=refilter
tachyon.Main.community_subnets=0
UCI
cat >"$FIX_DIR/uci-sig-baseline.state" <<'UCI'
tachyon.settings=settings
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=proxy
tachyon.Main.community_lists=youtube
tachyon.Main.community_subnets=1
UCI

sig_on="$(TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$FIX_DIR/uci-sig-on.state" \
  ucode -L "$TACHYON_LIB" "$APPLY_UC" nft-runtime-signature)"
sig_off="$(TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$FIX_DIR/uci-sig-off.state" \
  ucode -L "$TACHYON_LIB" "$APPLY_UC" nft-runtime-signature)"
sig_base="$(TACHYON_LIB="$TACHYON_LIB" TACHYON_UCI_STATE_FILE="$FIX_DIR/uci-sig-baseline.state" \
  ucode -L "$TACHYON_LIB" "$APPLY_UC" nft-runtime-signature)"

[ "$sig_on" != "$sig_off" ] ||
  fail "nft-runtime-signature must differ between refilter+subnets=1 ($sig_on) and refilter+subnets=0 ($sig_off)"
assert_eq "$sig_base" "$sig_off" "nft-runtime-signature with refilter+subnets=0 vs domain-only baseline"

# 5. diagnostics/route_explain.uc: matches 2.16.1.65 via community-subnets-refilter.lst when enabled, skips when community_subnets=0
EXP_DIR="$WORK_DIR/explain"
EXP_RS="$EXP_DIR/rulesets"
mkdir -p "$EXP_RS"
printf '2.16.1.65/32\n' > "$EXP_RS/community-subnets-refilter.lst"
printf '198.51.100.0/24\n' > "$EXP_RS/community-subnets-antifilter.lst"

TACHYON_LIB="$TACHYON_LIB" TMP_RULESET_FOLDER="$EXP_RS" ucode -S -L "$TACHYON_LIB" -e '
let re = require("diagnostics.route_explain");
let uci_on = {
    settings: { ".name": "settings", ".type": "settings", "enabled": "1", "dns_type": "udp", "dns_server": "1.1.1.1" },
    sections: [
        {
            ".name": "Main",
            ".type": "section",
            "enabled": "1",
            "action": "connection",
            "outbound_type": "vless",
            "community_lists": [ "refilter", "antifilter_community" ],
            "community_subnets": "1"
        }
    ],
    conditions: {},
    outbound_sources: {},
    outbound_groups: {},
    balancers: {},
    nodes: [],
    dns_hosts: []
};
let uci_off = {
    settings: uci_on.settings,
    sections: [
        {
            ".name": "Main",
            ".type": "section",
            "enabled": "1",
            "action": "connection",
            "outbound_type": "vless",
            "community_lists": [ "refilter" ],
            "community_subnets": "0"
        }
    ],
    conditions: {},
    outbound_sources: {},
    outbound_groups: {},
    balancers: {},
    nodes: [],
    dns_hosts: []
};

let r_on = re.explain_route("192.168.1.50", "2.16.1.65", 443, "tcp", { uci_cfg: uci_on });
let s_on = r_on && r_on.stages && r_on.stages["3_section_matching"];
if (!r_on || r_on.matched_section != "Main" || !r_on.matched_rule ||
    r_on.matched_rule.type != "community_subnets" || r_on.matched_rule.value != "refilter" ||
    !s_on || s_on.matched_section != "Main") {
    warn(sprintf("FAIL: expected route_explain to match 2.16.1.65 via refilter community_subnets, got %J\n", r_on));
    exit(1);
}

let r_alias = re.explain_route("192.168.1.50", "198.51.100.10", 443, "tcp", { uci_cfg: uci_on });
let s_alias = r_alias && r_alias.stages && r_alias.stages["3_section_matching"];
if (!r_alias || r_alias.matched_section != "Main" || !r_alias.matched_rule ||
    r_alias.matched_rule.type != "community_subnets" || r_alias.matched_rule.value != "antifilter_community" ||
    !s_alias || s_alias.matched_section != "Main") {
    warn(sprintf("FAIL: expected route_explain to match 198.51.100.10 via antifilter_community alias, got %J\n", r_alias));
    exit(2);
}

let r_off = re.explain_route("192.168.1.50", "2.16.1.65", 443, "tcp", { uci_cfg: uci_off });
let s_off = r_off && r_off.stages && r_off.stages["3_section_matching"];
if (!r_off || r_off.matched_section != null || !s_off || s_off.matched_section != null ||
    (r_off.matched_rule && r_off.matched_rule.type != "default_fallback")) {
    warn(sprintf("FAIL: expected route_explain NOT to match 2.16.1.65 when community_subnets=0, got %J\n", r_off));
    exit(3);
}
' || fail "route_explain community_subnets verification failed"

# 6. updates.uc list-update guard: geoip_country=['ru'], geoip_mode='exclude' MUST NOT download geoip_ru.lst,
#    and download_all_presets=1 MUST skip geoip_us.lst while downloading refilter.lst
UPD_DIR="$WORK_DIR/updates"
TMP_RS="$UPD_DIR/tmp-rs"
ETC_RS="$UPD_DIR/etc-rs"
RUN_DIR="$UPD_DIR/run"
FAKE_BIN="$UPD_DIR/bin"
FAKE_LIB="$UPD_DIR/fake-lib"
CURL_LOG="$UPD_DIR/curl.log"
mkdir -p "$TMP_RS" "$ETC_RS" "$RUN_DIR" "$FAKE_BIN" "$FAKE_LIB"

cat >"$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -n "$CURL_LOG" ] && [ -n "$url" ]; then
  echo "$url" >> "$CURL_LOG"
fi
case "$url" in
  *.trs*)
    printf 'TCRS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$out"
    exit 0
    ;;
  *release/subnets/*.lst*)
    printf '2.16.1.65/32\n' > "$out"
    exit 0
    ;;
  https://github.com|https://github.com/)
    exit 0
    ;;
  *)
    exit 22
    ;;
esac
SH
cat >"$FAKE_BIN/dig" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "1.1.1.1"
exit 0
SH
cat >"$FAKE_BIN/nslookup" <<'SH'
#!/usr/bin/env sh
echo "Address: 1.1.1.1"
exit 0
SH
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/dig" "$FAKE_BIN/nslookup"

cp -r "$TACHYON_LIB"/. "$FAKE_LIB"/
stub_hdr='#!/usr/bin/env ucode
exit(0);
'
printf '%s' "$stub_hdr" > "$FAKE_LIB/nft/apply.uc"
printf '%s' "$stub_hdr" > "$FAKE_LIB/tachyon_core/priority.uc"
printf '%s' "$stub_hdr" > "$FAKE_LIB/tachyon_core/dns_failover.uc"
cat >"$FAKE_LIB/service/state.uc" <<'UC'
#!/usr/bin/env ucode
if ((ARGV[0] || "") == "tachyon-core-service-runtime-pid") { print("0\n"); }
exit(0);
UC
cat >"$FAKE_LIB/tachyon_core/runtime.uc" <<'UC'
#!/usr/bin/env ucode
exit(0);
UC

cat >"$UPD_DIR/uci-geoip.state" <<EOF
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.config_path=$UPD_DIR/core-config.json
tachyon.Main=section
tachyon.Main.enabled=1
tachyon.Main.action=connection
tachyon.Main.community_lists=refilter
tachyon.Main.geoip_country=ru
tachyon.Main.geoip_mode=exclude
EOF
: > "$CURL_LOG"
printf '{}\n' > "$UPD_DIR/core-config.json"

env PATH="$FAKE_BIN:$PATH" \
  CURL_LOG="$CURL_LOG" \
  TACHYON_LIB="$FAKE_LIB" \
  TACHYON_UCI_STATE_FILE="$UPD_DIR/uci-geoip.state" \
  TMP_RULESET_FOLDER="$TMP_RS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_LIST_UPDATE_PID_FILE="$RUN_DIR/list_update.pid" \
  TACHYON_RELOAD_LOCK_DIR="$UPD_DIR/reload.lock" \
  ucode -L "$FAKE_LIB" -L "$TACHYON_LIB" "$UPDATES_UC" list-update >/dev/null 2>&1 || true

grep -Fq 'release/subnets/refilter.lst' "$CURL_LOG" ||
  fail "list-update must download refilter.lst for section with community_lists=refilter"
if grep -Fq 'release/subnets/geoip_ru.lst' "$CURL_LOG"; then
  fail "list-update MUST NOT download geoip_ru.lst just because geoip_country=ru filter is enabled"
fi

# Test import_all_preset_lists skips geoip_us.lst
cat >"$UPD_DIR/uci-presets.state" <<EOF
tachyon.settings=settings
tachyon.settings.enabled=1
tachyon.settings.download_all_presets=1
tachyon.settings.config_path=$UPD_DIR/core-config.json
EOF
rm -rf "$TMP_RS"/* "$ETC_RS"/* "$RUN_DIR"/*
: > "$CURL_LOG"
env PATH="$FAKE_BIN:$PATH" \
  CURL_LOG="$CURL_LOG" \
  TACHYON_LIB="$FAKE_LIB" \
  TACHYON_UCI_STATE_FILE="$UPD_DIR/uci-presets.state" \
  TMP_RULESET_FOLDER="$TMP_RS" \
  TACHYON_PERSISTENT_RULESETS_DIR="$ETC_RS" \
  TACHYON_RUNTIME_STATE_DIR="$RUN_DIR" \
  TACHYON_LIST_UPDATE_PID_FILE="$RUN_DIR/list_update.pid" \
  TACHYON_RELOAD_LOCK_DIR="$UPD_DIR/reload.lock" \
  ucode -L "$FAKE_LIB" -L "$TACHYON_LIB" "$UPDATES_UC" list-update >/dev/null 2>&1 || true

if grep -Fq 'release/subnets/geoip_us.lst' "$CURL_LOG"; then
  fail "download_all_presets=1 must skip huge geoip_us.lst pre-download"
fi
grep -Fq 'release/subnets/refilter.lst' "$CURL_LOG" ||
  fail "download_all_presets=1 must pre-download refilter.lst"

echo "community_refilter_subnets: all checks passed"
