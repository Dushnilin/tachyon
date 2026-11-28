#!/usr/bin/env bash
# Regression test for issue #567:
#   1. remote_subnet_lists / remote_domain_lists / local_subnet_lists / local_domain_lists
#      are accepted by tachyon_core/generator_routes.uc (never rejected as unsupported matcher)
#      and wired into the section's generated rule_set and route.rules.
#   2. connections.domain_ip_lists(section) aggregates both remote_subnet_lists and local_subnet_lists
#      across the section and its attached conditions.
#   3. runtime.uc expand_check_error_reason() reports a routing-matcher hint for
#      "unsupported matcher" (not proxy pool links), and write_section_errors() removes
#      stale section-cache JSON files for quarantined sections.

. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"
RUNTIME_UC="$TACHYON_LIB/tachyon_core/runtime.uc"

export TACHYON_CORE_VERSION_FILE="$WORK_DIR/version"
printf '0.6.9' >"$TACHYON_CORE_VERSION_FILE"
export TACHYON_SECTION_FAIL_STATE_FILE="$WORK_DIR/no-fail-state.json"

# 1. Remote subnet list pre-cached into <output>.rulesets/Discord-lists-ruleset.json
OUT1="$WORK_DIR/out1.json"
mkdir -p "${OUT1}.section-cache" "${OUT1}.rulesets"
cat >"${OUT1}.rulesets/Discord-lists-ruleset.json" <<'JSON'
{
  "version": 3,
  "rules": [
    {
      "ip_cidr": [ "34.2.0.0/15", "35.192.0.0/11" ]
    }
  ]
}
JSON

cat >"$WORK_DIR/fixture_remote.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": [
    {
      ".name": "Discord",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "remote_subnet_lists": [ "https://example.test/discord.lst" ],
      "selector_proxy_links": [ "socks5://127.0.0.1:1080#node1" ]
    }
  ]
}
JSON

ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_remote.json" "$OUT1" "127.0.0.1" "0" "" "" ""

OUT1="$OUT1" ucode -e '
  let fs = require("fs");
  let cfg = json(fs.readfile(getenv("OUT1")));
  let has_rs_def = false;
  for (let rs in (cfg.route && cfg.route.rule_set ? cfg.route.rule_set : [])) {
    if (rs.tag == "Discord-lists-ruleset")
      has_rs_def = true;
  }
  let has_route = false;
  for (let r in (cfg.route && cfg.route.rules ? cfg.route.rules : [])) {
    let rs_list = type(r.rule_set) == "array" ? r.rule_set : [ r.rule_set ];
    if (r.outbound == "Discord-out" && index(rs_list, "Discord-lists-ruleset") >= 0)
      has_route = true;
  }
  if (!has_rs_def || !has_route) {
    warn("missing Discord-lists-ruleset definition or route rule\n");
    exit(1);
  }
' || fail "remote_subnet_lists must compile into Discord-lists-ruleset and route.rules"

# 2. local_subnet_lists compiles subnets into *-lists-ruleset.json and connections.domain_ip_lists merges keys
LOCAL_LST="$WORK_DIR/discord-gcp.lst"
printf '34.0.0.0/15\n35.208.0.0/12\n' >"$LOCAL_LST"

OUT2="$WORK_DIR/out2.json"
mkdir -p "${OUT2}.section-cache" "${OUT2}.rulesets"

node - "$LOCAL_LST" "$WORK_DIR/fixture_local.json" <<'JS'
const fs = require('fs');
const [,, lstPath, outPath] = process.argv;
fs.writeFileSync(outPath, JSON.stringify({
  settings: {
    '.name': 'settings',
    '.type': 'settings',
    dns_server: ['77.88.8.8'],
    bootstrap_dns_server: ['77.88.8.8'],
  },
  section: [{
    '.name': 'Discord',
    '.type': 'section',
    enabled: '1',
    action: 'connection',
    local_subnet_lists: [lstPath],
    remote_subnet_lists: ['https://example.test/discord.lst'],
    selector_proxy_links: ['socks5://127.0.0.1:1080#node1'],
  }],
}, null, 2));
JS

ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/fixture_local.json" "$OUT2" "127.0.0.1" "0" "" "" ""

[ -f "${OUT2}.rulesets/Discord-lists-ruleset.json" ] ||
  fail "local_subnet_lists must produce Discord-lists-ruleset.json"
grep -Fq '34.0.0.0/15' "${OUT2}.rulesets/Discord-lists-ruleset.json" ||
  fail "local_subnet_lists subnet missing in compiled ruleset"
grep -Fq '"Discord-lists-ruleset"' "$OUT2" ||
  fail "Discord-lists-ruleset missing in generated config for local_subnet_lists"

LOCAL_LST="$LOCAL_LST" ucode -L "$TACHYON_LIB" -e '
  let conn = require("config.connections");
  let local_lst = getenv("LOCAL_LST");
  let sec = {
    ".name": "Discord",
    ".type": "section",
    local_subnet_lists: [ local_lst ],
    remote_subnet_lists: [ "https://example.test/discord.lst" ]
  };
  let lists = conn.effective_domain_ip_lists(sec);
  if (index(lists, local_lst) < 0 || index(lists, "https://example.test/discord.lst") < 0) {
    warn("effective_domain_ip_lists did not aggregate local_subnet_lists and remote_subnet_lists\n");
    exit(1);
  }
' || fail "connections.effective_domain_ip_lists must aggregate remote_subnet_lists and local_subnet_lists"

# 3. runtime.uc: unsupported matcher hint avoids server-pool hint & quarantine cleans section cache
hint_out="$(ucode -L "$TACHYON_LIB" "$RUNTIME_UC" expand-check-reason-fixture "section has unsupported matcher foo")"
if printf '%s' "$hint_out" | grep -Fq 'Пул серверов'; then
  fail "unsupported matcher error hint must not point to server pool tab: $hint_out"
fi
printf '%s' "$hint_out" | grep -Fq 'маршрутизации' ||
  fail "unsupported matcher error hint must mention routing conditions: $hint_out"

SEC_CACHE="$WORK_DIR/sec_cache"
ERR_FILE="$WORK_DIR/section-errors.json"
mkdir -p "$SEC_CACHE"
printf '{"section":"Discord"}\n' >"$SEC_CACHE/Discord.json"

TACHYON_SECTION_CACHE_DIR="$SEC_CACHE" \
TACHYON_SECTION_ERRORS_FILE="$ERR_FILE" \
  ucode -L "$TACHYON_LIB" "$RUNTIME_UC" write-section-errors-fixture '{"Discord":"failed"}'

[ ! -f "$SEC_CACHE/Discord.json" ] ||
  fail "write_section_errors must remove stale section-cache file for quarantined section"
[ -f "$ERR_FILE" ] && grep -Fq '"Discord"' "$ERR_FILE" ||
  fail "write_section_errors must still write section-errors.json"

printf 'issue_567_remote_subnet_lists: OK\n'
