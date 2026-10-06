#!/usr/bin/env bash
# The subscription URL list has to be able to switch a single source off.
#
# Two halves, checked separately because they are checked differently.
#
# The backend half is behavioural and lives in tests/subscription_url_lifecycle.sh.
# This file covers the UI half, which is a LuCI widget and can only be inspected
# as source: the list lives in the hand-written section.js, not in the generated
# main.js, and the widget is built from LuCI form classes at render time, so there
# is nothing to execute here.
#
# What matters is that the toggle is not merely cosmetic - it has to reach UCI
# under the same child section the backend reads, default to enabled so that a
# configuration written before the flag keeps working, and be inert on the lists
# that did not ask for it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

SECTION_JS="luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js"
[ -f "$SECTION_JS" ] || fail "$SECTION_JS not found"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*" >&2; }

# ─── the row toggle exists and is opt-in ─────────────────────────────────────
# Rendering a checkbox in every dynamic list would put a stray control next to
# every list on the page, so the hook has to be a capability the option declares
# rather than something the widget always draws.
grep -Fq 'fkp-dynlist-enabled' "$SECTION_JS" \
  || fail "the dynamic list has no per-row toggle element"
grep -Fq 'typeof this.options.setItemEnabled === "function"' "$SECTION_JS" \
  || fail "the row toggle must be opt-in through setItemEnabled, or every dynamic list on the page grows one"
grep -Fq 'o.setItemEnabled = function' "$SECTION_JS" \
  || fail "no dynamic list declares setItemEnabled, so the toggle never renders"

# ─── it targets the same child section the backend reads ─────────────────────
# The writer has to name the type, the owner check has to use the section id, and
# the flag has to land on the child - a set() on the parent section would be
# silently ignored by config.connections.
toggle="$(sed -n '/o\.setItemEnabled = function/,/^  };/p' "$SECTION_JS")"
[ -n "$toggle" ] || fail "could not read the setItemEnabled implementation"

for needle in 'isExistingChildItem(section_id, itemId, "subscription_url")' \
              'uci.set(UCI_PACKAGE, itemId, "enabled"' 'uci.save()'; do
    grep -Fq "$needle" <<< "$toggle" \
      || fail "setItemEnabled is missing: $needle"
done

# ─── absent flag means enabled, never disabled ───────────────────────────────
# Every subscription_url section written before this flag existed has no
# `enabled` option. Reading that as "off" would silently disable every existing
# subscription the first time the section page opened, with nothing in the log.
grep -q 'raw == null || raw === "" || raw === "1"' <<< "$toggle" \
  || fail "a missing enabled option must read as enabled; defaulting to off would silently disable every pre-existing subscription"
grep -Fq 'return true;' <<< "$toggle" \
  || fail "setItemEnabled must return true for a value that is not a stored child section yet"
pass "toggle targets the child section and defaults to enabled"

# ─── the flag is also reachable from the item's settings modal ───────────────
# The row checkbox is the fast path; the modal is where the rest of this URL's
# options live, and the key has to be in both lists or the modal will drop it on
# save through applyChildItemSettings.
keys="$(sed -n '/^function subscriptionUrlSettingsKeys()/,/^}/p' "$SECTION_JS")"
grep -Eq '^\s*"enabled",' <<< "$keys" \
  || fail "enabled is missing from subscriptionUrlSettingsKeys(), so the settings modal would not carry it"

defaults="$(sed -n '/^function defaultSubscriptionUrlSettings()/,/^}/p' "$SECTION_JS")"
grep -Eq '^\s*enabled: "1",' <<< "$defaults" \
  || fail "enabled is missing from defaultSubscriptionUrlSettings(), so a newly added URL would carry no flag"

modal="$(sed -n '/^function addSubscriptionUrlItemOptions(/,/^}/p' "$SECTION_JS")"
grep -q '"enabled",' <<< "$modal" \
  || fail "the item modal has no Enabled flag for a subscription URL"
pass "flag is present in the keys, the defaults and the item modal"

# ─── it must not steal clicks from the row ───────────────────────────────────
# handleClick delegates to ui.DynamicList, which removes the item. A click on
# the checkbox would therefore delete the subscription.
handler="$(sed -n '/^  handleClick(event) {/,/^  },/p' "$SECTION_JS")"
grep -Fq '.fkp-dynlist-enabled' <<< "$handler" \
  || fail "handleClick does not ignore the toggle, so clicking it would delete the row"
pass "the toggle does not fall through to the row's remove handler"

# ─── and it must not be confused with the settings gear ─────────────────────
# Both are opt-in per row; a checkbox left unhandled by the gear's guard would
# open the settings modal on every toggle.
grep -Fq 'event.target.closest(".fkp-dynlist-settings")' "$SECTION_JS" \
  || fail "handleClick no longer guards the settings gear"

printf 'fault: subscription URL toggle UI checks passed\n'