#!/usr/bin/env bash
# FAULT: opening the settings page rewrote the config for nothing.
#
# Surfaced as a Telegram feedback ticket that read:
#
#   В последней версии в конфигурации изменений нет.
#   tachyon.settings.tab_order='dashboard' 'uci add_list
#   tachyon.settings.tab_order='section' 'uci add_list
#   ... one add_list per tab ...
#
# The values never changed, so the value-level diff was empty - and the operation
# log was full of them. Both widgets on the settings page ended with an
# unconditional syncToUci() call at the end of their render, so merely loading the
# page pushed the whole tab_order list plus one show_tab_* / show_component_* option
# per entry into the UCI session, whether or not anything had been touched.
#
# That is flash wear for a value that did not change, and it is what produced the
# contradictory report. The fix compares against what is already stored and writes
# only on a real difference.
#
# settings.js is a hand-written LuCI view (tsup only builds main.js from TS), so it
# is not covered by tsc, eslint or the vitest suite. This reads the real file.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$SETTINGS_JS" ] || fail "settings.js not found at $SETTINGS_JS"

# Both widgets must still write on a genuine change, so the guard is only correct if
# the unconditional set is gone but the set itself remains.
count_sets="$(grep -c 'uci.set(UCI_PACKAGE, section_id, "tab_order", ordered)' "$SETTINGS_JS")"
[ "$count_sets" -eq 1 ] ||
  fail "expected exactly one tab_order write, found $count_sets"

count_component_sets="$(grep -c 'uci.set(UCI_PACKAGE, section_id, optKey, next)' "$SETTINGS_JS")"
[ "$count_component_sets" -eq 2 ] ||
  fail "expected the guarded optKey write in both widgets, found $count_component_sets"

# The old blanket write, unguarded by any comparison.
if grep -qE 'uci\.set\(UCI_PACKAGE, section_id, "tab_order", ordered\);' "$SETTINGS_JS" &&
   ! grep -q 'sameOrder' "$SETTINGS_JS"; then
  fail "tab_order is still written unconditionally, so every settings page load rewrites the list into UCI"
fi

grep -q 'sameOrder' "$SETTINGS_JS" ||
  fail "the tab_order write is no longer guarded by a comparison against the stored value"

# An unset option reads back as undefined, which must not be treated as a match,
# or the option would never be written the first time.
grep -q 'prev !== next' "$SETTINGS_JS" ||
  fail "the show_* writes are no longer guarded by a comparison"

grep -q 'not the same as "0"' "$SETTINGS_JS" ||
  fail 'the guard does not distinguish an unset option from "0"; a never-set option would then never be written'

# The bare syncToUci() calls at the end of widget setup stay. They are what
# materialises a show_tab_* / show_component_* default the first time, and with the
# comparison in place they cost nothing when nothing changed. An earlier draft of
# this test asserted they should be removed, which would have lost that first write.
grep -qE '^  syncToUci\(\);$' "$SETTINGS_JS" ||
  fail "the initial syncToUci() calls are gone, so a show_tab_* option would never get its default written on first visit"

printf 'fault: settings page does not rewrite unchanged config passed\n'
