#!/usr/bin/env bash
# Section group (action 'group'): one flat URLTest over the union of member
# leaves, member route rules repointed at that URLTest, members validated, and
# the whole action parked on steer.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

VALIDATOR="$TACHYON_LIB/config/validator.uc"
GENERATOR_UC="$TACHYON_LIB/tachyon_core/generator.uc"

# validator warnings go through logger(1); stub it so accepted fixtures do not
# depend on a host logger
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'BASH'
#!/usr/bin/env bash
exit 0
BASH
chmod +x "$WORK_DIR/bin/logger"

# ─── validator ────────────────────────────────────────────────────────────────

fixture() {
  local out="$1" sections="$2"
  cat >"$out" <<JSON
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "list_update_enabled": "1",
    "update_interval": "1d",
    "latency_test_url": "https://latency.example/generate_204",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query" ],
    "bootstrap_dns_server": [ "1.1.1.1" ]
  },
  "section": $sections
}
JSON
}

validate_fixture() {
  local source="$1"
  TACHYON_LIB="$TACHYON_LIB" PATH="$WORK_DIR/bin:$PATH" \
    ucode -L "$TACHYON_LIB" "$VALIDATOR" validate-runtime-fixture "$source" "$WORK_DIR/context.json"
}
printf '{}\n' >"$WORK_DIR/context.json"

assert_accepts() {
  local label="$1" fixture="$2" output
  if ! output="$(validate_fixture "$fixture" 2>&1)"; then
    fail "$label should be accepted, got '$output'"
  fi
}

assert_rejects() {
  local label="$1" fixture="$2" expected="$3" output
  if output="$(validate_fixture "$fixture" 2>&1)"; then
    fail "$label should be rejected"
  fi
  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

LINK_A1='vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha%20One'
LINK_A2='vless://00000000-0000-4000-8000-000000000002@alpha2.example:443?encryption=none&security=tls&sni=alpha2.example#Alpha%20Two'
LINK_B1='vless://00000000-0000-4000-8000-000000000003@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta%20One'

SECTIONS_OK='[
  { ".name": "alpha", ".type": "section", "enabled": "1", "action": "connection",
    "domain_suffix": [ "alpha.example" ],
    "selector_proxy_links": [ "'"$LINK_A1"'", "'"$LINK_A2"'" ] },
  { ".name": "beta", ".type": "section", "enabled": "1", "action": "connection",
    "domain_suffix": [ "beta.example" ],
    "selector_proxy_links": [ "'"$LINK_B1"'" ] },
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "alpha", "beta" ] }
]'

fixture "$WORK_DIR/group-ok.json" "$SECTIONS_OK"
# stash direction: without the action whitelist this fixture is rejected with
# "unsupported action 'group'", so the acceptance below fails on old code
assert_accepts "a group over two connection sections" "$WORK_DIR/group-ok.json"

fixture "$WORK_DIR/group-missing.json" '[
  { ".name": "alpha", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "'"$LINK_A1"'" ] },
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "alpha", "nope" ] }
]'
assert_rejects "group with missing member" "$WORK_DIR/group-missing.json" \
  "references missing rule 'nope'"

fixture "$WORK_DIR/group-disabled.json" '[
  { ".name": "alpha", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "'"$LINK_A1"'" ] },
  { ".name": "beta", ".type": "section", "enabled": "0", "action": "connection",
    "selector_proxy_links": [ "'"$LINK_B1"'" ] },
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "beta" ] }
]'
assert_rejects "group over a disabled member" "$WORK_DIR/group-disabled.json" \
  "references disabled rule 'beta'"

fixture "$WORK_DIR/group-self.json" '[
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "grp" ] }
]'
assert_rejects "group including itself" "$WORK_DIR/group-self.json" \
  "cannot include itself"

fixture "$WORK_DIR/group-empty.json" '[
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [] }
]'
assert_rejects "group without members" "$WORK_DIR/group-empty.json" \
  "has no members"

fixture "$WORK_DIR/group-duplicate.json" '[
  { ".name": "alpha", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "'"$LINK_A1"'" ] },
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "alpha", "alpha" ] }
]'
assert_rejects "group with a duplicate member" "$WORK_DIR/group-duplicate.json" \
  "lists rule 'alpha' twice"

fixture "$WORK_DIR/group-route-only.json" '[
  { ".name": "local", ".type": "section", "enabled": "1", "action": "hosts" },
  { ".name": "grp", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "local" ] }
]'
assert_rejects "group over a route-only member" "$WORK_DIR/group-route-only.json" \
  "cannot include rule 'local' with action 'hosts'"

fixture "$WORK_DIR/group-nested.json" '[
  { ".name": "alpha", ".type": "section", "enabled": "1", "action": "connection",
    "selector_proxy_links": [ "'"$LINK_A1"'" ] },
  { ".name": "inner", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "alpha" ] },
  { ".name": "outer", ".type": "section", "enabled": "1", "action": "group",
    "group_members": [ "inner" ] }
]'
assert_rejects "nested groups" "$WORK_DIR/group-nested.json" \
  "with action 'group'"

# ─── generator: flat urltest + repointed member rules ─────────────────────────

cat >"$WORK_DIR/group-fixture.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "log_level": "warn" },
  "section": $SECTIONS_OK
}
JSON

group_config="$WORK_DIR/group-config.json"
mkdir -p "${group_config}.section-cache"
ucode -L "$TACHYON_LIB" "$GENERATOR_UC" generate-config-fixture \
  "$WORK_DIR/group-fixture.json" "$group_config" "127.0.0.1"

ucode -e '
let fs = require("fs");
function outbound_by_tag(config, want) {
    for (let outbound in config.outbounds || [])
        if (outbound && outbound.tag == want)
            return outbound;
    return null;
}
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
let config = json(fs.readfile(ARGV[0]));

let group = outbound_by_tag(config, "grp-urltest-out");
if (!group || group.type != "urltest")
    die("the group section must produce a grp-urltest-out outbound\n");
for (let want in [ "alpha-1-out", "alpha-2-out", "beta-1-out" ])
    if (!contains(group.outbounds || [], want))
        die("flat group urltest is missing member leaf " + want + "\n");
if (length(group.outbounds || []) != 3)
    die("flat group urltest must be exactly the union of member leaves, got " +
        length(group.outbounds || []) + "\n");

// merge semantics keep member selectors — they stay usable as detour targets
if (!outbound_by_tag(config, "alpha-out") || !outbound_by_tag(config, "beta-out"))
    die("member section selectors must survive the merge\n");

let alpha_rule = null;
let beta_rule = null;
let group_rule_count = 0;
for (let rule in config.route.rules || []) {
    if (rule.outbound == "grp-urltest-out")
        group_rule_count++;
    if (contains(rule.domain_suffix || [], "alpha.example"))
        alpha_rule = rule;
    if (contains(rule.domain_suffix || [], "beta.example"))
        beta_rule = rule;
}
if (!alpha_rule || !beta_rule)
    die("member routing rules were not generated\n");
if (alpha_rule.outbound != "grp-urltest-out" || beta_rule.outbound != "grp-urltest-out")
    die("member rules must route through the group urltest, got alpha=" +
        (alpha_rule.outbound || "null") + " beta=" + (beta_rule.outbound || "null") + "\n");
if (group_rule_count != 2)
    die("the group itself must not add route rules; expected 2, got " + group_rule_count + "\n");
' "$group_config" || fail "generated section group behavior"

# ─── parking: sing-box supports sections.group, steer does not ────────────────

parking="$(ucode -L "$TACHYON_LIB" -e '
let st = require("components.engine_state");
let e = require("core.engine");
function has(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
printf("feat=%s\n", st.section_feature({ ".type": "section", "action": "group" }));
printf("singbox=%d\n", has(e.capabilities("tachyon-core"), "sections.group"));
printf("steer=%d\n", has(e.capabilities("steer"), "sections.group"));
let g = require("steer.generator");
printf("steer_supported=%d\n", g.section_supported({ ".name": "grp", "action": "group" }));
' 2>&1)" || fail "could not read group parking metadata: $parking"

grep -q '^feat=sections.group$' <<<"$parking" ||
  fail "a group section must map to the sections.group feature: $parking"
grep -q '^singbox=1$' <<<"$parking" ||
  fail "sing-box capabilities must include sections.group: $parking"
grep -q '^steer=0$' <<<"$parking" ||
  fail "steer capabilities must not include sections.group: $parking"
grep -q '^steer_supported=0$' <<<"$parking" ||
  fail "the steer generator must skip group sections: $parking"

# ─── UI: action is choosable and members are pickable ─────────────────────────

SECTION_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"
[ -f "$SECTION_JS" ] || fail "section.js not found at $SECTION_JS"
grep -Fq 'option.value("group", getActionOptionLabel("group"))' "$SECTION_JS" ||
  fail "the action chooser must offer the group action"
grep -Fq '"group_members"' "$SECTION_JS" ||
  fail "the section modal must declare the group_members picker"
grep -Fq 'getOutboundDetourTargetSections(section_id).map' "$SECTION_JS" ||
  fail "the group members picker must reuse the eligible-section choices"

printf 'Section group checks passed\n'
