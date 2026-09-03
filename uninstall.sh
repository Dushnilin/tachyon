#!/bin/sh
# shellcheck shell=dash
# ==============================================================================
# Tachyon Uninstaller & Cleanup Script
# Полное чистое удаление Tachyon с сохранением резервной копии конфигурации.
# ==============================================================================

set -u

UNINSTALLER_VERSION="1.2.88"

# ─── TUI helpers & Color detection ───────────────────────────────────────────
ESC="$(printf '\033')"
_tui_colors=0
if [ -t 1 ] 2>/dev/null; then
    case "${TERM:-dumb}" in
        dumb) _tui_colors=0 ;;
        *)    _tui_colors=1 ;;
    esac
fi

if [ "$_tui_colors" -eq 1 ]; then
    _c_reset="${ESC}[0m"
    _c_bold="${ESC}[1m"
    _c_dim="${ESC}[2m"
    _c_red="${ESC}[31;1m"
    _c_green="${ESC}[32;1m"
    _c_yellow="${ESC}[33;1m"
    _c_blue="${ESC}[34;1m"
    _c_cyan="${ESC}[36;1m"
    _c_magenta="${ESC}[35;1m"
else
    _c_reset=''
    _c_bold=''
    _c_dim=''
    _c_red=''
    _c_green=''
    _c_yellow=''
    _c_blue=''
    _c_cyan=''
    _c_magenta=''
fi

_tui_width() {
    if [ -t 1 ] 2>/dev/null && command -v stty >/dev/null 2>&1; then
        _w="$(stty size 2>/dev/null | awk '{print $2}')"
        [ -n "$_w" ] && [ "$_w" -gt 0 ] 2>/dev/null && printf '%s' "$_w" && return 0
    fi
    printf '70'
}

_tui_hline() {
    _w="$(_tui_width)"
    _char="${1:--}"
    _i=0
    while [ "$_i" -lt "$_w" ]; do
        printf '%s' "$_char"
        _i=$((_i + 1))
    done
}

tui_banner() {
    printf '\n'
    printf '  %s%s⚡ Tachyon Clean Uninstaller%s v%s\n' "$_c_cyan" "$_c_bold" "$_c_reset" "$UNINSTALLER_VERSION"
    printf '  %sПолное удаление пакетов, сетевых правил и восстановление DNS%s\n' "$_c_dim" "$_c_reset"
    printf '  %s%s%s\n\n' "$_c_dim" "$(_tui_hline '─')" "$_c_reset"
}

tui_step() {
    _step_no="$1"
    _step_total="$2"
    _step_text="$3"
    printf '  %s%s[ %s/%s ]%s %s%s%s\n' \
        "$_c_blue" "$_c_bold" \
        "$_step_no" "$_step_total" \
        "$_c_reset" \
        "$_c_bold" "$_step_text" "$_c_reset"
}

tui_ok() {
    printf '  %s%s✓%s %s\n' "$_c_green" "$_c_bold" "$_c_reset" "$1"
}

tui_warn() {
    printf '  %s%s⚠%s %s\n' "$_c_yellow" "$_c_bold" "$_c_reset" "$1"
}

tui_info() {
    printf '  %s%sℹ%s %s\n' "$_c_cyan" "$_c_dim" "$_c_reset" "$1"
}

# ─── Options parsing ─────────────────────────────────────────────────────────
OPT_PURGE=0
OPT_YES=0
OPT_KEEP_BINARIES=0

for _arg in "$@"; do
    case "$_arg" in
        --purge|-p)
            OPT_PURGE=1
            ;;
        --yes|-y)
            OPT_YES=1
            ;;
        --keep-binaries)
            OPT_KEEP_BINARIES=1
            ;;
        --help|-h)
            printf 'Использование: %s [ОПЦИИ]\n' "$0"
            printf 'Опции:\n'
            printf '  -y, --yes            Выполнить удаление без подтверждения\n'
            printf '  -p, --purge          Полное удаление вместе с резервными копиями конфига\n'
            printf '      --keep-binaries  Не удалять бинарники sing-box / zapret / byedpi\n'
            printf '  -h, --help           Показать эту справку\n\n'
            exit 0
            ;;
        *)
            ;;
    esac
done

# ─── Root check ──────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ] 2>/dev/null; then
    printf '%sОшибка: скрипт удаления должен запускаться с правами root!%s\n' "$_c_red" "$_c_reset" >&2
    exit 1
fi

tui_banner

# ─── Confirmation prompt ─────────────────────────────────────────────────────
if [ "$OPT_YES" -eq 0 ] && [ -t 0 ] 2>/dev/null; then
    printf '  Вы действительно хотите удалить %sTachyon%s с этого роутера?\n' "$_c_bold" "$_c_reset"
    if [ "$OPT_PURGE" -eq 1 ]; then
        printf '  %sВнимание: указан флаг --purge. Все конфигурации и бэкапы будут удалены!%s\n' "$_c_red" "$_c_reset"
    else
        printf '  Рабочая конфигурация будет сохранена в резервную копию.\n'
    fi
    printf '  Продолжить? [y/N]: '
    read -r _answer
    case "$_answer" in
        y|Y|yes|Yes|YES|да|Да|ДА)
            ;;
        *)
            printf '\n  %sУдаление отменено пользователем.%s\n\n' "$_c_yellow" "$_c_reset"
            exit 0
            ;;
    esac
    printf '\n'
fi

TOTAL_STEPS=6
CURRENT_STEP=1

# ─── STEP 1: Backup Configuration ────────────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Создание резервной копии конфигурации..."
BACKUP_PATH=""
if [ "$OPT_PURGE" -eq 0 ]; then
    TIMESTAMP="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)"
    if [ -f "/etc/config/tachyon" ]; then
        BACKUP_PATH="/etc/config/tachyon.backup-${TIMESTAMP}"
        cp -af "/etc/config/tachyon" "$BACKUP_PATH" 2>/dev/null
        cp -af "/etc/config/tachyon" "/etc/config/tachyon.bak" 2>/dev/null
        chmod 600 "$BACKUP_PATH" "/etc/config/tachyon.bak" 2>/dev/null
        tui_ok "Конфигурация успешно сохранена в: ${BACKUP_PATH}"
    else
        tui_info "Конфигурационный файл /etc/config/tachyon не найден, бэкап пропущен."
    fi
else
    tui_warn "Режим --purge: резервное копирование конфигурации отключено."
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 2: Stop Services & Daemons ─────────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Остановка служб и фоновых процессов..."

if [ -f "/etc/init.d/tachyon" ]; then
    /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    /etc/init.d/tachyon disable >/dev/null 2>&1 || true
    tui_ok "Служба /etc/init.d/tachyon остановлена и отключена"
fi

# Terminate running DPI and proxy processes if any
killall sing-box >/dev/null 2>&1 || true
killall nfqws >/dev/null 2>&1 || true
killall nfqws2 >/dev/null 2>&1 || true
killall ciadpi >/dev/null 2>&1 || true

tui_ok "Фоновые процессы sing-box, zapret и byedpi завершены"

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 3: Clean up Network & nftables ─────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Очистка сетевых таблиц nftables и политик маршрутизации..."

# Remove nftables tables
if command -v nft >/dev/null 2>&1; then
    nft delete table inet TachyonTable >/dev/null 2>&1 || true
    nft delete table inet tachyon >/dev/null 2>&1 || true
    nft delete table ip tachyon >/dev/null 2>&1 || true
    nft delete table ip6 tachyon >/dev/null 2>&1 || true
    rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft 2>/dev/null || true
    tui_ok "Таблицы nftables (TachyonTable) успешно удалены"
fi

# Remove IP policy routing rules & flush table 100
if command -v ip >/dev/null 2>&1; then
    ip rule del fwmark 0x10000000/0x10000000 lookup 100 >/dev/null 2>&1 || true
    ip rule del fwmark 0x1/0x1 lookup 100 >/dev/null 2>&1 || true
    ip rule del fwmark 0x2/0x2 lookup 100 >/dev/null 2>&1 || true
    ip route flush table 100 >/dev/null 2>&1 || true
    tui_ok "Политики маршрутизации (table 100, fwmark) сброшены"
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 4: Restore DNS & dnsmasq ───────────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Восстановление конфигурации DNS и dnsmasq..."

rm -f /etc/dnsmasq.d/tachyon*.conf 2>/dev/null || true
rm -f /tmp/dnsmasq.d/tachyon*.conf 2>/dev/null || true
rm -rf /tmp/tachyon 2>/dev/null || true

# Restore dnsmasq backup if exists
if [ -f "/etc/config/dnsmasq.tachyon-bak" ]; then
    cp -f "/etc/config/dnsmasq.tachyon-bak" "/etc/config/dnsmasq" 2>/dev/null
    rm -f "/etc/config/dnsmasq.tachyon-bak" 2>/dev/null
    tui_ok "Восстановлен исходный /etc/config/dnsmasq из бэкапа"
fi

# Restart dnsmasq to apply clean DNS configuration
if [ -f "/etc/init.d/dnsmasq" ]; then
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    tui_ok "Служба dnsmasq перезапущена в штатном режиме"
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 5: Remove Packages ─────────────────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Удаление установленных пакетов Tachyon..."

if command -v apk >/dev/null 2>&1 && [ -d "/lib/apk/db" ]; then
    for _pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
        if apk info -e "$_pkg" >/dev/null 2>&1; then
            apk del "$_pkg" >/dev/null 2>&1 || true
        fi
    done
    tui_ok "Пакеты удалены через apk-tools"
elif command -v opkg >/dev/null 2>&1; then
    _wait=0
    while [ -f /var/lock/opkg.lock ] || [ -f /var/run/opkg.lock ]; do
        _wait=$((_wait + 1))
        [ "$_wait" -ge 10 ] && break
        sleep 1
    done
    for _pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
        if opkg list-installed "$_pkg" 2>/dev/null | grep -q "^$_pkg "; then
            opkg remove --force-depends --force-remove "$_pkg" >/dev/null 2>&1 || true
        fi
    done
    tui_ok "Пакеты удалены через opkg"
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 6: Remove Leftover Files & LuCI Cache ──────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Очистка оставшихся файлов и кэша LuCI..."

rm -rf /usr/lib/tachyon 2>/dev/null || true
rm -rf /usr/share/tachyon 2>/dev/null || true
rm -rf /www/luci-static/resources/view/tachyon 2>/dev/null || true
rm -f /usr/share/luci/menu.d/luci-app-tachyon.json 2>/dev/null || true
rm -f /usr/share/rpcd/acl.d/luci-app-tachyon.json 2>/dev/null || true
rm -f /etc/uci-defaults/50_luci-tachyon 2>/dev/null || true
rm -f /etc/tachyon_commit 2>/dev/null || true
rm -f /usr/bin/tachyon 2>/dev/null || true
rm -f /etc/init.d/tachyon 2>/dev/null || true

# Optional binary removal
if [ "$OPT_KEEP_BINARIES" -eq 0 ]; then
    # Only remove binaries if they were placed for tachyon
    rm -f /usr/lib/libcronet.so 2>/dev/null || true
fi

# Clean translations
rm -f /usr/lib/lua/luci/i18n/tachyon.* 2>/dev/null || true
find /usr/lib/lua/luci/i18n/ -name "tachyon.*" -delete 2>/dev/null || true

# Clear LuCI index and module caches
rm -f /var/luci-indexcache* /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true

# Purge configs if requested
if [ "$OPT_PURGE" -eq 1 ]; then
    rm -f /etc/config/tachyon* 2>/dev/null || true
    rm -rf /etc/tachyon 2>/dev/null || true
    tui_ok "Все конфигурации Tachyon удалены (--purge)"
fi

# Restart rpcd and uhttpd to update LuCI menu
if [ -f "/etc/init.d/rpcd" ]; then
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
if [ -f "/etc/init.d/uhttpd" ]; then
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

# Check if parent Forkop / Podkop services exist and restore them
if [ -f "/etc/init.d/forkop" ]; then
    /etc/init.d/forkop enable >/dev/null 2>&1 || true
    /etc/init.d/forkop restart >/dev/null 2>&1 || true
    tui_ok "Обнаружен родительский сервис Forkop — восстановлен и запущен"
elif [ -f "/etc/init.d/podkop" ]; then
    /etc/init.d/podkop enable >/dev/null 2>&1 || true
    /etc/init.d/podkop restart >/dev/null 2>&1 || true
    tui_ok "Обнаружен родительский сервис Podkop — восстановлен и запущен"
fi

tui_ok "Кэш LuCI очищен, файлы удалены"

# ─── Final Summary ───────────────────────────────────────────────────────────
printf '\n'
printf '  %s%s%s\n' "$_c_dim" "$(_tui_hline '─')" "$_c_reset"
printf '  %s%s✓ Tachyon успешно и чисто удален с вашего роутера!%s\n' "$_c_green" "$_c_bold" "$_c_reset"

if [ "$OPT_PURGE" -eq 0 ] && [ -n "$BACKUP_PATH" ]; then
    printf '  %s📁 Резервная копия конфигурации сохранена:%s %s%s%s\n' "$_c_cyan" "$_c_reset" "$_c_bold" "$BACKUP_PATH" "$_c_reset"
    printf '  %s   (а также продублирована в /etc/config/tachyon.bak)%s\n' "$_c_dim" "$_c_reset"
fi

printf '  %s🌐 Сетевой стек и DNS возвращены в штатный режим OpenWrt.%s\n\n' "$_c_dim" "$_c_reset"

exit 0
