#!/usr/bin/env bash
# Regression test for Issue #114:
# 1. Built-in Discord ruleset must be included in dns_query_rule_set_tags so
#    discord domains (including discord-attachments-uploads-prd.storage.googleapis.com)
#    are matched during DNS resolution.
# 2. Discord ruleset must NOT be in dns_response_rule_set_tags (match_response: true),
#    leaving DNS responses alone and preventing FakeIP issuance on voice endpoints.
# 3. route_explain matches discord-attachments-uploads-prd.storage.googleapis.com as Discord.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/singbox" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi

ucode() { command ucode -L "$TACHYON_LIB" "$@"; }

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# Check 1: route_explain recognizes discord-attachments-uploads-prd.storage.googleapis.com
cat >"$WORK_DIR/test_explain.uc" <<'UCODE'
let re = require("diagnostics.route_explain");
let target = "discord-attachments-uploads-prd.storage.googleapis.com";
let matched = re.check_community_domain_match(target, "discord");
if (!matched) {
    printf("route_explain did not match %s for discord\n", target);
    exit(1);
}
UCODE

if ucode "$WORK_DIR/test_explain.uc" >/dev/null 2>&1; then
  ok
else
  fail "route_explain must match discord-attachments-uploads-prd.storage.googleapis.com"
fi

# Check 2: community_kind remains "subnets" in rulesets.uc
cat >"$WORK_DIR/test_kind.uc" <<'UCODE'
let rs = require("singbox.rulesets");
let kind = rs.community_kind("discord");
if (kind !== "subnets") {
    printf("community_kind(discord) returned %s, expected subnets\n", kind);
    exit(1);
}
UCODE

if ucode "$WORK_DIR/test_kind.uc" >/dev/null 2>&1; then
  ok
else
  fail "community_kind for discord must stay subnets"
fi

# Check 3: generator_routes creates DNS query rule for builtin-discord-ruleset without match_response
cat >"$WORK_DIR/test_routes.uc" <<'UCODE'
let gr = require("singbox.generator_routes");

gr.init({
    runtime_settings: () => ({}),
    runtime_ruleset_folder: "/tmp",
    download_detour_tag: (settings, kind) => "direct-out",
    runtime_generate_unsupported: (msg) => { warn(msg + "\n"); exit(1); },
    is_sb_1_14_plus: () => true
});

let config = {
    route: { rules: [], rule_set: [] },
    dns: { rules: [], servers: [] },
    outbounds: [
        { type: "direct", tag: "direct-out" },
        { type: "direct", tag: "proxy" }
    ]
};

let section = {
    ".name": "test_discord_sec",
    action: "outbound",
    outbound: "proxy",
    community_subnets: "1",
    community_lists: [ "discord" ]
};

gr.add_combined_route_for_section(config, section, { outbound: "proxy" });

let found_dns_query = false;
let found_dns_response = false;

for (let r in config.dns.rules) {
    let sets = type(r.rule_set) == "array" ? r.rule_set : (r.rule_set ? [r.rule_set] : []);
    for (let s in sets) {
        if (index(s, "discord") >= 0) {
            if (r.match_response) {
                found_dns_response = true;
            } else {
                found_dns_query = true;
            }
        }
    }
}

if (!found_dns_query) {
    printf("discord ruleset not found in dns query rules!\n");
    exit(1);
}

if (found_dns_response) {
    printf("discord ruleset must NOT have match_response: true in DNS rules!\n");
    exit(1);
}

// Verify routing rule has it too
let found_route_rs = false;
for (let r in config.route.rules) {
    let sets = type(r.rule_set) == "array" ? r.rule_set : (r.rule_set ? [r.rule_set] : []);
    for (let s in sets) {
        if (index(s, "discord") >= 0) {
            found_route_rs = true;
            break;
        }
    }
}

if (!found_route_rs) {
    printf("discord ruleset not found in route rules!\n");
    exit(1);
}

printf("discord routing and dns verified ok\n");
UCODE

if out="$(ucode "$WORK_DIR/test_routes.uc" 2>&1)"; then
  ok
else
  fail "Discord route generator check failed: $out"
fi

printf 'discord domain ruleset: %d checks passed\n' "$pass_count"
printf 'PASS: discord_domain_ruleset\n'
