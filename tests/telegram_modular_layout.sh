#!/usr/bin/env bash
# The Telegram bot has to speak the modular layout.
#
# A section no longer carries its conditions and its server sources itself:
# the conditions live in reusable "condition" sections, the sources in
# "outbound_source" sections, the auto-selection rules in "balancer"
# sections. A bot that only reads the section's own fields sees empty lists
# - and the user is told a section has no domains and no subscriptions.
#
# The bot also has to keep working with a config from before the layout:
# there the conditions are still in the section itself.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

RENDERING="$TACHYON_LIB/service/telegram/rendering.uc"
COMMANDS="$TACHYON_LIB/service/telegram/commands.uc"
[ -f "$RENDERING" ] || fail "service/telegram/rendering.uc not found at $RENDERING"
[ -f "$COMMANDS" ] || fail "service/telegram/commands.uc not found at $COMMANDS"

# The helpers have to exist and be exported.
out="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let fs = require("fs");
let r = require("service.telegram.rendering");
let conn = require("config.connections");
let re = require("diagnostics.route_explain");

function check(condition, message) {
    if (!condition) {
        warn(message + "\n");
        exit(1);
    }
}

check(type(r.section_condition_sections) == "function", "section_condition_sections is missing");
check(type(r.section_own_and_conditions) == "function", "section_own_and_conditions is missing");
check(type(r.section_primary_atomic_condition) == "function", "section_primary_atomic_condition is missing");
check(type(r.section_match_all_enabled) == "function", "section_match_all_enabled is missing");
check(type(r.section_condition_values) == "function", "section_condition_values is missing");
check(type(r.section_outbound_sources) == "function", "section_outbound_sources is missing");
check(type(r.section_has_fptn) == "function", "section_has_fptn is missing");
check(type(r.section_balancers) == "function", "section_balancers is missing");
check(type(conn.is_dpi_or_desync_only_section) == "function", "is_dpi_or_desync_only_section is missing");
check(type(conn.is_remote_proxy_section) == "function", "is_remote_proxy_section is missing");

// Verify user_domains prefix extraction in section_condition_values
let fake_sec = {
    ".name": "Main",
    action: "connection",
    user_domains: [ "youtube.com", "full:exact.example.org", "keyword:openai", "regex:^.*\\.claude\\.ai$" ],
    fully_routed_ips: [ "192.168.1.50/32" ],
    devices: [ "br-lan" ],
    ports: [ "443,8443" ],
    geoip_country: [ "RU" ]
};
let sfx = r.section_condition_values(fake_sec, "domain_suffix");
let dom = r.section_condition_values(fake_sec, "domain");
let kw = r.section_condition_values(fake_sec, "domain_keyword");
let rx = r.section_condition_values(fake_sec, "domain_regex");
let sip = r.section_condition_values(fake_sec, "source_ip_cidr");
let dev = r.section_condition_values(fake_sec, "devices");
let prt = r.section_condition_values(fake_sec, "ports");
check(index(sfx, "youtube.com") >= 0, "user_domains bare domain must appear in domain_suffix");
check(index(dom, "exact.example.org") >= 0, "user_domains full: prefix must appear in domain");
check(index(kw, "openai") >= 0, "user_domains keyword: prefix must appear in domain_keyword");
check(index(rx, "^.*\\.claude\\.ai$") >= 0, "user_domains regex: prefix must appear in domain_regex");
check(index(sip, "192.168.1.50/32") >= 0, "fully_routed_ips must appear in source_ip_cidr");
check(index(dev, "br-lan") >= 0, "devices must appear in devices");
check(index(prt, "443") >= 0 && index(prt, "8443") >= 0, "ports must be split and returned");
check(re.check_community_domain_match("gemini.google.com", "google_ai") == true, "google_ai community list must match gemini.google.com");

// Verify component_display_title and clean_release_notes for tachyon-core updates
check(type(r.component_display_title) == "function", "component_display_title is missing");
check(type(r.clean_release_notes) == "function", "clean_release_notes is missing");
let tc_title = r.component_display_title({
    component: "sing_box",
    message: "tachyon-core update available: 0.1.7",
    release_url: "https://github.com/Dushnilin/tachyon-core/releases/tag/v0.1.7"
});
check(tc_title == "tachyon-core", "sing_box component with tachyon-core release must display as tachyon-core, got: " + tc_title);

let cleaned_notes = r.clean_release_notes(
    "[![GitHub Release](https://img.shields.io/github/v/release/Dushnilin/tachyon-core?style=flat-square)](https://github.com/Dushnilin/tachyon-core/releases)\n" +
    "# Tachyon Core — высокопроизводительное сетевое ядро\n" +
    "- Added XHTTP support\n"
);
check(index(cleaned_notes, "img.shields.io") < 0, "clean_release_notes must strip shields.io badges");
check(index(cleaned_notes, "Added XHTTP support") >= 0, "clean_release_notes must keep release bullets");

// Verify config_plan accepts modular actions (connection, group, desync)
let cp = require("service.config_plan");
let v_res = cp.validate_uci_semantics({
    settings: {},
    sections: {
        Main: { ".name": "Main", ".type": "section", action: "connection" },
        Grp: { ".name": "Grp", ".type": "section", action: "group", group_members: [ "Main" ] },
        Des: { ".name": "Des", ".type": "section", action: "desync" }
    },
    servers: {}
});
check(v_res.status == "ok" && length(v_res.errors) == 0, "config_plan must accept connection, group, and desync actions");

print("ok");
UCODE
)"

[ "$out" = "ok" ] || fail "the telegram modular helpers are missing: $out"

TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/diagnostics/route_explain.uc" selftest >/dev/null ||
  fail "route_explain selftest failed"

# The bot must not read the condition lists from the section alone any more:
# that is the code path that made a modular section look empty.
if grep -Fq 'common.list_option(s, "domain_suffix")' "$COMMANDS"; then
  fail "the bot still reads the domains from the section alone - a modular section carries them in its condition"
fi
if grep -Fq 'common.list_option(s, "ip_cidr")' "$COMMANDS"; then
  fail "the bot still reads the IP list from the section alone - a modular section carries it in its condition"
fi
if grep -Fq 'common.list_option(s, "community_lists")' "$COMMANDS"; then
  fail "the bot still reads the ruleset list from the section alone - a modular section carries it in its condition"
fi

# The subscription view has to follow the sources, not the legacy children.
if grep -Fq '".type" == "subscription_url" && s.section == sec_name' "$COMMANDS"; then
  fail "the bot still lists the legacy subscription children - the sources are outbound_source sections now"
fi

# The editor has to name the conditions and the balancers, so the user can
# see which reusable entities the section is built from.
grep -Fq 'section_condition_sections(s)' "$COMMANDS" ||
  fail "the section editor does not show the conditions the section is built from"
grep -Fq 'section_balancers(s)' "$COMMANDS" ||
  fail "the section editor does not show the balancers the section uses"

# The translation keys have to exist in both languages.
for lang in en ru; do
  :
done
grep -Fq 'section_conditions:' "$TACHYON_LIB/service/i18n.uc" ||
  fail "the section_conditions translation key is missing"
grep -Fq 'section_balancers:' "$TACHYON_LIB/service/i18n.uc" ||
  fail "the section_balancers translation key is missing"

printf 'Telegram bot speaks the modular layout passed\n'
