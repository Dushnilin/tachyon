#!/usr/bin/env bash
# Test scheduled auto-update chaining for tachyon + tachyon-core and Telegram notifications
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

UPDATES_UC="$TACHYON_LIB/components/updates.uc"
ACTION_UC="$TACHYON_LIB/components/action.uc"
TELEGRAM_UC="$TACHYON_LIB/service/telegram.uc"
RUNTIME_UC="$TACHYON_LIB/service/telegram/runtime.uc"
RENDERING_UC="$TACHYON_LIB/service/telegram/rendering.uc"
I18N_UC="$TACHYON_LIB/service/i18n.uc"
CONFIG_FILE="$ROOT_DIR/tachyon/files/etc/config/tachyon"
SETTINGS_JS="$ROOT_DIR/luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/settings.js"

[ -f "$UPDATES_UC" ] || fail "updates.uc not found"
[ -f "$ACTION_UC" ] || fail "action.uc not found"
[ -f "$TELEGRAM_UC" ] || fail "telegram.uc not found"
[ -f "$RUNTIME_UC" ] || fail "runtime.uc not found"
[ -f "$RENDERING_UC" ] || fail "rendering.uc not found"
[ -f "$I18N_UC" ] || fail "i18n.uc not found"
[ -f "$CONFIG_FILE" ] || fail "etc/config/tachyon not found"
[ -f "$SETTINGS_JS" ] || fail "settings.js not found"

# 1. normalize_component_name must map tachyon-core to sing_box in BOTH updates.uc AND action.uc
grep -Fq 'component == "tachyon-core"' "$UPDATES_UC" ||
  fail "updates.uc normalize_component_name must map tachyon-core to sing_box"
grep -Fq 'component == "tachyon-core"' "$ACTION_UC" ||
  fail "action.uc normalize_component_name must map tachyon-core to sing_box"

# 2. updates.uc must define continue_component_auto_update and notify_component_auto_updated
grep -Fq 'function continue_component_auto_update' "$UPDATES_UC" ||
  fail "updates.uc must define continue_component_auto_update"
grep -Fq 'function notify_component_auto_updated' "$UPDATES_UC" ||
  fail "updates.uc must define notify_component_auto_updated"

# continue_component_auto_update must be forward-only to prevent infinite re-trigger cycles
continue_func="$(sed -n '/function continue_component_auto_update/,/^}/p' "$UPDATES_UC")"
printf '%s\n' "$continue_func" | grep -q 'start_idx' ||
  fail "continue_component_auto_update must use forward index tracking to avoid re-trigger loops"

# 3. finish_component_job must notify and continue auto-update
finish_job_func="$(sed -n '/function finish_component_job/,/^}/p' "$UPDATES_UC")"
[ -n "$finish_job_func" ] || fail "could not locate finish_component_job in updates.uc"

printf '%s\n' "$finish_job_func" | grep -q 'notify_component_auto_updated(component' ||
  fail "finish_component_job must call notify_component_auto_updated"
printf '%s\n' "$finish_job_func" | grep -q 'continue_component_auto_update(component)' ||
  fail "finish_component_job must call continue_component_auto_update"

# 4. telegram.uc and runtime.uc must support notify-auto-update
grep -Fq 'mode == "notify-auto-update"' "$TELEGRAM_UC" ||
  fail "telegram.uc must handle notify-auto-update CLI mode"
grep -Fq 'function notify_auto_update_cli' "$RUNTIME_UC" ||
  fail "runtime.uc must define notify_auto_update_cli"

# 5. i18n keys for auto-update must exist in en and ru
grep -Fq 'notify_auto_update: "Auto-Updates"' "$I18N_UC" ||
  fail "i18n.uc must contain notify_auto_update in en"
grep -Fq 'notify_auto_update: "Автообновления"' "$I18N_UC" ||
  fail "i18n.uc must contain notify_auto_update in ru"
grep -Fq 'auto_update_from_to: "Version automatically updated from %s to %s"' "$I18N_UC" ||
  fail "i18n.uc must contain auto_update_from_to in en"
grep -Fq 'auto_update_from_to: "Версия автоматически обновилась с %s по %s"' "$I18N_UC" ||
  fail "i18n.uc must contain auto_update_from_to in ru"

# 6. rendering.uc schema and boolean keys
grep -Fq 'notify_auto_update: "notify_auto_update"' "$RENDERING_UC" ||
  fail "rendering.uc must include notify_auto_update in telegram schema"
grep -Fq '"notify_auto_update"' "$RENDERING_UC" ||
  fail "rendering.uc must include notify_auto_update in boolean keys"

# 7. UCI config and LuCI settings
grep -Fq "option notify_auto_update '1'" "$CONFIG_FILE" ||
  fail "etc/config/tachyon must have option notify_auto_update '1'"
grep -Fq '"notify_auto_update"' "$SETTINGS_JS" ||
  fail "settings.js must have notify_auto_update option"
grep -Fq 'o.value("tachyon-core"' "$SETTINGS_JS" ||
  fail "settings.js must include tachyon-core option in component_auto_update_targets"
grep -Fq 'o.value("tachyon", _("Tachyon"))' "$SETTINGS_JS" ||
  fail "settings.js must label tachyon as Tachyon"

# 8. If ucode is available, run functional verification
if command -v ucode >/dev/null 2>&1; then
  ucode -e '
  let i18n = loadfile("'"$I18N_UC"'")();
  let t_ru = i18n.bind("ru");
  let t_en = i18n.bind("en");
  let ru_msg = t_ru("auto_update_from_to", "0.0.9", "0.1.0");
  if (index(ru_msg, "Версия автоматически обновилась с 0.0.9 по 0.1.0") < 0) exit(1);
  let en_msg = t_en("auto_update_from_to", "0.0.9", "0.1.0");
  if (index(en_msg, "Version automatically updated from 0.0.9 to 0.1.0") < 0) exit(2);
  ' || fail "ucode evaluation of auto-update translation strings failed"
fi

printf 'scheduled auto-update core and notify checks passed\n'
