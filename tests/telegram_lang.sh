#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

TG="$TACHYON_LIB/service/telegram.uc"
I18N="$TACHYON_LIB/service/i18n.uc"

[ -f "$TG" ] || fail "telegram.uc not found"
[ -f "$I18N" ] || fail "i18n.uc not found"

# 1. Available languages: Russian must be unconditionally available (not gated by current==ru)
grep -Fq '{ code: "ru", label: "Русский", available: true }' "$I18N" ||
  fail "i18n.uc must make Russian unconditionally available"

# 2. telegram.uc must not have the broken substr(cmd, 11) for lang_set that chopped 'ru' to 'u'
if grep -E 'lang.*substr\(cmd, 11\)' "$TG"; then
  fail "telegram.uc must NOT use substr(cmd, 11) for language commands"
fi

# 3. /lang_set matching must capture the full language code
grep -Fq 'lang_match = match(cmd, /^\/(lang_set|lang|language)' "$TG" ||
  fail "telegram.uc must robustly match /lang_set and /lang commands with arguments"

# 4. handle_lang_set must rebind t immediately
grep -Fq 't = i18n.bind(lang);' "$TG" ||
  fail "handle_lang_set must rebind translation function 't' immediately"

# 5. handle_lang_set must update Telegram bot commands menu
grep -Fq 'register_bot_commands(token);' "$TG" ||
  fail "handle_lang_set must call register_bot_commands to update bot menu"

# 6. /guest and /guest_toggle routes must be defined in telegram.uc
grep -Fq 'function view_guest_mode(token, chat_id, msg_id)' "$TG" ||
  fail "telegram.uc must define view_guest_mode"
grep -Fq 'function handle_guest_toggle(token, chat_id, msg_id)' "$TG" ||
  fail "telegram.uc must define handle_guest_toggle"
grep -Fq 'if (cmd == "/guest")' "$TG" ||
  fail "dispatch_command must route /guest"
grep -Fq 'if (cmd == "/guest_toggle")' "$TG" ||
  fail "dispatch_command must route /guest_toggle"

# 7. Run ucode evaluation test of i18n language resolution, sprintf args, and regex
ucode -e '
let i18n = loadfile("'"$I18N"'")();
if (i18n.resolve_lang("ru") != "ru") exit(1);
if (i18n.resolve_lang("en") != "en") exit(2);
if (i18n.resolve_lang("invalid") != "en") exit(3);
let t_ru = i18n.bind("ru");
if (t_ru("lang_saved") != "Язык сохранён!") exit(4);
if (t_ru("cmd_guest") != "Гостевой режим") exit(5);
if (t_ru("lang_current", "Русский") != "Текущий язык: Русский") exit(6);
let t_en = i18n.bind("en");
if (t_en("lang_saved") != "Language saved!") exit(7);
if (t_en("cmd_guest") != "Guest mode") exit(8);
if (t_en("lang_current", "English") != "Current language: English") exit(9);
let langs = i18n.available_languages("en");
if (length(langs) != 2 || !langs[0].available || !langs[1].available) exit(10);
let m1 = match("/lang_set ru", /^\/(lang_set|lang|language)[ \t]+([a-zA-Z0-9_-]+)/);
if (!m1 || m1[2] != "ru") exit(11);
let m2 = match("/lang en", /^\/(lang_set|lang|language)[ \t]+([a-zA-Z0-9_-]+)/);
if (!m2 || m2[2] != "en") exit(12);
' || fail "ucode i18n evaluation failed"

printf 'telegram language and guest route checks passed\n'
