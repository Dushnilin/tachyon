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
let r = require("service.telegram.rendering");

function check(condition, message) {
    if (!condition) {
        warn(message + "\n");
        exit(1);
    }
}

check(type(r.section_condition_sections) == "function", "section_condition_sections is missing");
check(type(r.section_own_and_conditions) == "function", "section_own_and_conditions is missing");
check(type(r.section_condition_values) == "function", "section_condition_values is missing");
check(type(r.section_outbound_sources) == "function", "section_outbound_sources is missing");
check(type(r.section_balancers) == "function", "section_balancers is missing");

print("ok");
UCODE
)"

[ "$out" = "ok" ] || fail "the telegram modular helpers are missing: $out"

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
