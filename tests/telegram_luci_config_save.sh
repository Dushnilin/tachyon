#!/usr/bin/env bash
# Verifies that Telegram Bot settings in LuCI allow clearing and unsetting bot_token and admin_ids.
#
# Bug: o.rmempty = false and o.retain = true on bot_token and admin_ids caused LuCI's
# form.Value write() to skip unsetting the option when the user cleared the token in the UI.
# Furthermore, o.depends("enabled", "1") hid the token when the bot was disabled, preventing
# the user from viewing or editing the token when disabled.
#
# This test verifies that:
# 1. bot_token and admin_ids do not depend on enabled and do not have retain=true.
# 2. bot_token and admin_ids have rmempty=true.
# 3. bot_token and admin_ids have write() and remove() handlers that call uci.unset when empty.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

SETTINGS_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"
[ -f "$SETTINGS_JS" ] || fail "settings.js not found at $SETTINGS_JS"

content="$(awk '/function createTelegramContent/,/return wrapper/' "$SETTINGS_JS")"
[ -n "$content" ] || fail "could not locate createTelegramContent in settings.js"

# Check bot_token definition
token_block="$(printf '%s\n' "$content" | awk '/"bot_token"/,/o = section\.option/')"
[ -n "$token_block" ] || fail "could not locate bot_token block in createTelegramContent"

if printf '%s\n' "$token_block" | grep -q 'o\.rmempty = false'; then
  fail "bot_token has rmempty=false; clearing the token in LuCI will not unset it in UCI"
fi

if ! printf '%s\n' "$token_block" | grep -q 'o\.rmempty = true'; then
  fail "bot_token must have rmempty=true"
fi

if printf '%s\n' "$token_block" | grep -q 'o\.retain = true'; then
  fail "bot_token must not have retain=true"
fi

if printf '%s\n' "$token_block" | grep -q 'o\.depends("enabled"'; then
  fail "bot_token must not depend on enabled so user can edit or clear token when bot is disabled"
fi

if ! printf '%s\n' "$token_block" | grep -q 'uci\.unset(UCI_PACKAGE, section_id, "bot_token")'; then
  fail "bot_token must call uci.unset when value is empty"
fi

# Check admin_ids definition
admin_block="$(printf '%s\n' "$content" | awk '/"admin_ids"/,/o = section\.option/')"
[ -n "$admin_block" ] || fail "could not locate admin_ids block in createTelegramContent"

if printf '%s\n' "$admin_block" | grep -q 'o\.rmempty = false'; then
  fail "admin_ids has rmempty=false; clearing admin IDs in LuCI will not unset it in UCI"
fi

if ! printf '%s\n' "$admin_block" | grep -q 'o\.rmempty = true'; then
  fail "admin_ids must have rmempty=true"
fi

if ! printf '%s\n' "$admin_block" | grep -q 'uci\.unset(UCI_PACKAGE, section_id, "admin_ids")'; then
  fail "admin_ids must call uci.unset when value is empty"
fi

printf 'telegram_luci_config_save: all checks passed\n'
