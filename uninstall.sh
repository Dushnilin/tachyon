#!/bin/sh
# shellcheck shell=dash
# ==============================================================================
# Tachyon Uninstaller & Cleanup Script
# Полное чистое удаление Tachyon с сохранением резервной копии конфигурации.
# ==============================================================================

set -u

UNINSTALLER_VERSION="1.3.0"

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
    printf '  %s%sTachyon Clean Uninstaller%s v%s\n' "$_c_cyan" "$_c_bold" "$_c_reset" "$UNINSTALLER_VERSION"
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
            printf '      --keep-binaries  Не удалять бинарники tachyon-core\n'
            printf '  -h, --help           Показать эту справку\n\n'
            exit 0
            ;;
        *)
            ;;
    esac
done

# ─── Root check ──────────────────────────────────────────────────────────────
if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
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
        cp -af "/etc/config/tachyon" "$BACKUP_PATH" 2>/dev/null || true
        cp -af "/etc/config/tachyon" "/etc/config/tachyon.bak" 2>/dev/null || true
        chmod 600 "$BACKUP_PATH" "/etc/config/tachyon.bak" 2>/dev/null || true
        tui_ok "Конфигурация успешно сохранена в: ${BACKUP_PATH}"
    else
        tui_info "Конфигурационный файл /etc/config/tachyon не найден, бэкап пропущен."
    fi
else
    tui_warn "Режим --purge: резервное копирование конфигурации отключено."
fi

CURRENT_STEP=$((CURRENT_STEP + 1))


# ─── Non-destructive backup of external configs ──────────────────────────────
_backup_external_configs() {
    _bdir="/etc/tachyon/external-configs-backup"
    for _comp in zapret zapret2 byedpi wdtt qwdtt olcrtc sing-box; do
        _cdir="$_bdir/$_comp"
        case "$_comp" in
            zapret)
                _srcs="/etc/config/zapret /opt/zapret/config /opt/zapret/ipset"
                ;;
            zapret2)
                _srcs="/etc/config/zapret2 /opt/zapret2/config /opt/zapret2/ipset"
                ;;
            byedpi)
                _srcs="/etc/config/byedpi /etc/byedpi"
                ;;
            wdtt|qwdtt)
                _srcs="/etc/config/wdtt /etc/wdtt /etc/qwdtt"
                ;;
            olcrtc)
                _srcs="/etc/config/olcrtc /etc/olcrtc"
                ;;
            sing-box)
                _srcs="/etc/sing-box/config.json /etc/config/sing-box"
                ;;
        esac
        _has_src=0
        for _s in $_srcs; do
            [ -e "$_s" ] && _has_src=1 && break
        done
        [ "$_has_src" -eq 0 ] && continue
        mkdir -p "$_cdir" 2>/dev/null || continue
        for _s in $_srcs; do
            [ -e "$_s" ] || continue
            _dst="$_cdir/$(basename "$_s")"
            if [ -d "$_s" ]; then
                cp -a -n "$_s" "$_dst" 2>/dev/null || cp -a "$_s" "${_dst}.new" 2>/dev/null || true
            else
                [ -f "$_dst" ] && cmp -s "$_s" "$_dst" 2>/dev/null && continue
                cp -a "$_s" "$_dst" 2>/dev/null || true
            fi
        done
    done
}

_backup_external_configs

# ─── STEP 2: Stop Services & Daemons ─────────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Остановка служб и фоновых процессов..."

# Remove stale locks so stop doesn't block on orphaned states
rm -f /var/run/tachyon/starting /var/run/tachyon/reloading /var/run/tachyon*.lock 2>/dev/null || true

if [ -f "/etc/init.d/tachyon" ]; then
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    else
        /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    fi
    /etc/init.d/tachyon disable >/dev/null 2>&1 || true
    tui_ok "Служба /etc/init.d/tachyon остановлена и отключена"
fi

# Stop and remove tachyon-core service if present
if [ -f "/etc/init.d/tachyon-core" ]; then
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 /etc/init.d/tachyon-core stop >/dev/null 2>&1 || true
    else
        /etc/init.d/tachyon-core stop >/dev/null 2>&1 || true
    fi
    /etc/init.d/tachyon-core disable >/dev/null 2>&1 || true
    rm -f /etc/init.d/tachyon-core /etc/rc.d/*tachyon-core* 2>/dev/null || true
    tui_ok "Сервис tachyon-core остановлен и удален"
fi

# Silently stop and remove legacy init script if created by older Tachyon
if [ -f "/etc/init.d/sing-box" ]; then
    if grep -q "Tachyon managed" "/etc/init.d/sing-box" 2>/dev/null; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 8 /etc/init.d/sing-box stop >/dev/null 2>&1 || true
        else
            /etc/init.d/sing-box stop >/dev/null 2>&1 || true
        fi
        /etc/init.d/sing-box disable >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box /etc/rc.d/*sing-box* 2>/dev/null || true
    fi
fi

# Stop and remove Tachyon's internal steer subsystem
for _legacy_svc in /etc/init.d/tachyon-steer-zapret /etc/init.d/steer; do
    if [ -f "$_legacy_svc" ]; then
        "$_legacy_svc" stop >/dev/null 2>&1 || true
        "$_legacy_svc" disable >/dev/null 2>&1 || true
        rm -f "$_legacy_svc" 2>/dev/null || true
    fi
done

# Selectively stop/remove legacy external provider services only if Tachyon-managed
_is_tachyon_managed() {
    _comp="$1"
    [ -f "/etc/init.d/$_comp" ] && grep -q "Tachyon managed" "/etc/init.d/$_comp" 2>/dev/null && return 0
    [ -d "/etc/tachyon/component-backups/$_comp" ] && return 0
    [ -d "/var/run/tachyon/$_comp" ] && return 0
    return 1
}
for _comp in zapret zapret2 byedpi wdtt-client qwdtt olcrtc; do
    _comp_marker="$_comp"
    case "$_comp" in wdtt-client) _comp_marker="wdtt" ;; esac
    if _is_tachyon_managed "$_comp_marker" && [ -f "/etc/init.d/$_comp" ]; then
        "/etc/init.d/$_comp" stop >/dev/null 2>&1 || true
        "/etc/init.d/$_comp" disable >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$_comp" 2>/dev/null || true
    fi
done
MANAGED_TAILSCALE=0
if [ -f "/etc/init.d/tailscale" ] && grep -q "Tachyon managed" "/etc/init.d/tailscale" 2>/dev/null; then
    MANAGED_TAILSCALE=1
    /etc/init.d/tailscale stop >/dev/null 2>&1 || true
    /etc/init.d/tailscale disable >/dev/null 2>&1 || true
    rm -f /etc/init.d/tailscale /etc/rc.d/*tailscale* 2>/dev/null || true
fi
# Always clean Tachyon internal steer subsystem and tailscale native markers
rm -rf /etc/rc.d/*steer* /etc/steer /usr/lib/tachyon/steer /usr/sbin/steer /usr/bin/steer /etc/tachyon/tailscale/*/native /var/run/qwdtt 2>/dev/null || true
# Selectively clean rc.d symlinks for external components only if Tachyon-managed
for _comp in zapret zapret2 byedpi wdtt qwdtt olcrtc; do
    _comp_marker="$_comp"
    case "$_comp" in wdtt-client) _comp_marker="wdtt" ;; esac
    if _is_tachyon_managed "$_comp_marker"; then
        rm -f /etc/rc.d/*"${_comp}"* 2>/dev/null || true
    fi
done

# Terminate running core and legacy processes if any
killall -9 tachyon-core >/dev/null 2>&1 || true
killall -9 steer >/dev/null 2>&1 || true
killall -9 tachyon >/dev/null 2>&1 || true
# Kill external component processes only if Tachyon-managed
if _is_tachyon_managed "sing_box"; then killall -9 sing-box >/dev/null 2>&1 || true; fi
for _comp in zapret zapret2 byedpi wdtt olcrtc; do
    if _is_tachyon_managed "$_comp"; then
        case "$_comp" in
            zapret)  killall -9 nfqws >/dev/null 2>&1 || true ;;
            zapret2) killall -9 nfqws2 >/dev/null 2>&1 || true ;;
            byedpi)  killall -9 ciadpi >/dev/null 2>&1 || true ;;
            wdtt)    killall -9 wdtt >/dev/null 2>&1 || true; killall -9 qwdtt-client >/dev/null 2>&1 || true ;;
            olcrtc)  killall -9 olcrtc >/dev/null 2>&1 || true ;;
        esac
    fi
done

# Terminate running background Tachyon daemons (watchdog, telegram, failover, etc.)
_self_pid="$$"
ps 2>/dev/null | grep -E 'dns_failover|watchdog|telegram' | grep -v grep | awk '{print $1}' | while read -r _pid; do
    if [ -n "$_pid" ] && [ "$_pid" != "$_self_pid" ]; then
        kill -9 "$_pid" 2>/dev/null || true
    fi
done

tui_ok "Фоновые процессы tachyon-core и сервисы Tachyon завершены"

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 3: Clean up Network, nftables & Policy Routing ─────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Очистка сетевых таблиц nftables и политик маршрутизации..."

# Remove nftables tables & drop-in file
if command -v nft >/dev/null 2>&1; then
    nft delete table inet TachyonTable >/dev/null 2>&1 || true
    rm -f /usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft 2>/dev/null || true
    nft delete table inet TachyonKillSwitch >/dev/null 2>&1 || true
    # TUN kill-switch rules (service/kill_switch.uc)
    for pref in 9499 9500 9501; do for fam in -4 -6; do while ip $fam rule del pref $pref >/dev/null 2>&1; do :; done; done; done
    nft delete table inet tachyon >/dev/null 2>&1 || true
    nft delete table inet steer >/dev/null 2>&1 || true
    nft delete table inet tachyon_tailscale >/dev/null 2>&1 || true
    nft delete table inet zapret >/dev/null 2>&1 || true
    nft delete table ip zapret >/dev/null 2>&1 || true
    nft delete table ip6 zapret >/dev/null 2>&1 || true
    nft delete table inet zapret2 >/dev/null 2>&1 || true
    nft delete table ip zapret2 >/dev/null 2>&1 || true
    nft delete table ip6 zapret2 >/dev/null 2>&1 || true
    nft delete table ip tachyon >/dev/null 2>&1 || true
    nft delete table ip6 tachyon >/dev/null 2>&1 || true
    rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft 2>/dev/null || true
    # Restart firewall to purge in-memory dynamic rules from inet fw4
    if [ -x "/etc/init.d/firewall" ]; then
        /etc/init.d/firewall restart >/dev/null 2>&1 || true
    fi
    tui_ok "Таблицы nftables (TachyonTable) удалены, фаервол сброшен"
fi

# Remove IP policy routing rules & flush routing tables
if command -v ip >/dev/null 2>&1; then
    # IPv4 and IPv6 rules used by Tachyon (0x04000000 / table tachyon / priority 105)
    ip -4 rule del fwmark 0x04000000/0x04000000 table tachyon priority 105 >/dev/null 2>&1 || true
    ip -6 rule del fwmark 0x04000000/0x04000000 table tachyon priority 105 >/dev/null 2>&1 || true
    ip -4 rule del fwmark 0x10000000/0x10000000 lookup 100 >/dev/null 2>&1 || true
    ip -4 rule del fwmark 0x1/0x1 lookup 100 >/dev/null 2>&1 || true
    ip -4 rule del fwmark 0x2/0x2 lookup 100 >/dev/null 2>&1 || true
    ip route flush table tachyon >/dev/null 2>&1 || true
    ip route flush table 105 >/dev/null 2>&1 || true
    ip route flush table 100 >/dev/null 2>&1 || true
    ip rule del to 100.64.0.0/10 priority 100 table 4247 >/dev/null 2>&1 || true
    ip -6 rule del to fd7a:115c:a1e0::/48 priority 100 table 4247 >/dev/null 2>&1 || true
    ip rule del fwmark 0x00200000/0x00ff0000 priority 90 table 4248 >/dev/null 2>&1 || true
    ip route flush table 4247 >/dev/null 2>&1 || true
    ip route flush table 4248 >/dev/null 2>&1 || true
    ip -6 route flush table 4247 >/dev/null 2>&1 || true

    # Clean /etc/iproute2/rt_tables entry
    if [ -f "/etc/iproute2/rt_tables" ]; then
        sed -i '/105[[:space:]]\+tachyon/d' /etc/iproute2/rt_tables 2>/dev/null || true
    fi

    # Clean network namespaces and diagnostic veth pairs
    ip netns del fkpsc >/dev/null 2>&1 || true
    ip link del fkpsc0 >/dev/null 2>&1 || true
    rm -rf /etc/netns/fkpsc 2>/dev/null || true

    tui_ok "Политики маршрутизации (table tachyon/105/100, fwmark) полностью сброшены"
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 4: Restore DNS & dnsmasq ───────────────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Восстановление конфигурации DNS и dnsmasq..."

rm -f /etc/dnsmasq.d/tachyon*.conf 2>/dev/null || true
rm -f /tmp/dnsmasq.d/tachyon*.conf 2>/dev/null || true
rm -f /etc/tachyon/dnsmasq-tailscale.servers 2>/dev/null || true
rm -rf /tmp/tachyon 2>/dev/null || true

# Restore /etc/config/dhcp via UCI
if command -v uci >/dev/null 2>&1 && [ -f "/etc/config/dhcp" ]; then
    # Remove local core DNS 127.0.0.42
    uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.42" 2>/dev/null || true

    # Restore original servers from tachyon_server backup
    _orig_servers="$(uci -q get dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true)"
    if [ -n "$_orig_servers" ]; then
        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
        for _srv in $_orig_servers; do
            [ "$_srv" != "127.0.0.42" ] && uci -q add_list dhcp.@dnsmasq[0].server="$_srv" 2>/dev/null || true
        done
        uci -q delete dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true
    fi

    # Restore backed-up options
    for _opt in noresolv cachesize rebind_protection localuse addn_hosts notinterface; do
        _val="$(uci -q get "dhcp.@dnsmasq[0].tachyon_${_opt}" 2>/dev/null || true)"
        if [ -n "$_val" ]; then
            uci -q set "dhcp.@dnsmasq[0].${_opt}=${_val}" 2>/dev/null || true
            uci -q delete "dhcp.@dnsmasq[0].tachyon_${_opt}" 2>/dev/null || true
        fi
    done

    # Failsafe: if noresolv remains 1, reset to 0 so router queries ISP/upstream resolvers
    if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
        uci -q set dhcp.@dnsmasq[0].noresolv="0" 2>/dev/null || true
    fi
    # Failsafe: if cachesize remains 0, restore standard default 150
    if [ "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)" = "0" ]; then
        uci -q set dhcp.@dnsmasq[0].cachesize="150" 2>/dev/null || true
    fi

    uci -q delete dhcp.tachyon 2>/dev/null || true
    uci -q commit dhcp 2>/dev/null || true
    tui_ok "Параметры DHCP и DNS dnsmasq возвращены в исходное состояние"
fi

# Restart dnsmasq to apply clean DNS configuration
if [ -f "/etc/init.d/dnsmasq" ]; then
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    tui_ok "Служба dnsmasq перезапущена в штатном режиме"
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 5: Clean Crontabs & Remove Packages ────────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Очистка crontab и удаление установленных пакетов..."

# Clean root crontab from Tachyon jobs
if command -v crontab >/dev/null 2>&1; then
    _crontmp="$(mktemp /tmp/cron.XXXXXX 2>/dev/null || echo '/tmp/cron.tachyon.tmp')"
    crontab -l 2>/dev/null | grep -v -E 'tachyon|parental_quota_tick' > "$_crontmp" || true
    crontab "$_crontmp" 2>/dev/null || true
    rm -f "$_crontmp" 2>/dev/null || true
    tui_ok "Задачи планировщика crontab очищены"
fi

if command -v apk >/dev/null 2>&1 && [ -d "/lib/apk/db" ]; then
    for _pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
        if [ -f /etc/apk/world ]; then
            sed -i -E "/^${_pkg}([><= ].*)?$/d" /etc/apk/world 2>/dev/null || true
        fi
        if apk info -e "$_pkg" >/dev/null 2>&1; then
            apk del --no-network --repositories-file /dev/null "$_pkg" >/dev/null 2>&1 || true
        fi
    done
    if [ "$OPT_KEEP_BINARIES" -eq 0 ] || [ "$OPT_PURGE" -eq 1 ]; then
        _legacy_pkgs="zapret zapret2 byedpi wdtt qwdtt olcrtc"
        [ "$MANAGED_TAILSCALE" -eq 1 ] && _legacy_pkgs="$_legacy_pkgs tailscale"
        for _pkg in $_legacy_pkgs; do
            _comp_marker="$_pkg"
            case "$_pkg" in wdtt) _comp_marker="wdtt" ;; qwdtt) _comp_marker="qwdtt" ;; esac
            if ! _is_tachyon_managed "$_comp_marker"; then continue; fi
            if [ -f /etc/apk/world ]; then
                sed -i -E "/^${_pkg}([><= ].*)?$/d" /etc/apk/world 2>/dev/null || true
            fi
            if apk info -e "$_pkg" >/dev/null 2>&1; then
                apk del --no-network --repositories-file /dev/null "$_pkg" >/dev/null 2>&1 || true
            fi
        done
    fi
    if [ "$OPT_KEEP_BINARIES" -eq 0 ] || [ "$OPT_PURGE" -eq 1 ]; then
        _legacy_pkgs="zapret zapret2 byedpi wdtt qwdtt olcrtc"
        [ "$MANAGED_TAILSCALE" -eq 1 ] && _legacy_pkgs="$_legacy_pkgs tailscale"
        for _pkg in $_legacy_pkgs; do
            _comp_marker="$_pkg"
            case "$_pkg" in wdtt) _comp_marker="wdtt" ;; qwdtt) _comp_marker="qwdtt" ;; esac
            if ! _is_tachyon_managed "$_comp_marker"; then continue; fi
            if opkg list-installed "$_pkg" 2>/dev/null | grep -q "^$_pkg "; then
                opkg remove --force-depends --force-remove "$_pkg" >/dev/null 2>&1 || true
            fi
        done
    fi
    if [ "$OPT_PURGE" -eq 1 ]; then
        # Only remove sing-box packages if Tachyon-managed
        if _is_tachyon_managed "sing_box"; then
            for _pkg in sing-box sing-box-extended sing-box-tiny sing-box-lx; do
                if [ -f /etc/apk/world ]; then
                    sed -i -E "/^${_pkg}([><= ].*)?$/d" /etc/apk/world 2>/dev/null || true
                fi
                if apk info -e "$_pkg" >/dev/null 2>&1; then
                    apk del --no-network --repositories-file /dev/null "$_pkg" >/dev/null 2>&1 || true
                fi
            done
        fi
    fi
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
    if [ "$OPT_KEEP_BINARIES" -eq 0 ] || [ "$OPT_PURGE" -eq 1 ]; then
        _legacy_pkgs="zapret zapret2 byedpi wdtt qwdtt olcrtc"
        [ "$MANAGED_TAILSCALE" -eq 1 ] && _legacy_pkgs="$_legacy_pkgs tailscale"
        for _pkg in $_legacy_pkgs; do
            _comp_marker="$_pkg"
            case "$_pkg" in wdtt) _comp_marker="wdtt" ;; qwdtt) _comp_marker="qwdtt" ;; esac
            if ! _is_tachyon_managed "$_comp_marker"; then continue; fi
            if opkg list-installed "$_pkg" 2>/dev/null | grep -q "^$_pkg "; then
                opkg remove --force-depends --force-remove "$_pkg" >/dev/null 2>&1 || true
            fi
        done
    fi
    if [ "$OPT_PURGE" -eq 1 ]; then
        # Only remove sing-box packages if Tachyon-managed
        if _is_tachyon_managed "sing_box"; then
            for _pkg in sing-box sing-box-extended sing-box-tiny sing-box-lx; do
                if opkg list-installed "$_pkg" 2>/dev/null | grep -q "^$_pkg "; then
                    opkg remove --force-depends --force-remove "$_pkg" >/dev/null 2>&1 || true
                fi
            done
        fi
    fi
    tui_ok "Пакеты удалены через opkg"
fi

CURRENT_STEP=$((CURRENT_STEP + 1))

# ─── STEP 6: Remove Leftover Files & LuCI Cache ──────────────────────────────
tui_step "$CURRENT_STEP" "$TOTAL_STEPS" "Очистка оставшихся файлов, хуков и кэша LuCI..."

rm -rf /usr/lib/tachyon 2>/dev/null || true
rm -rf /usr/share/tachyon 2>/dev/null || true
rm -rf /www/luci-static/resources/view/tachyon 2>/dev/null || true
rm -f /usr/share/luci/menu.d/luci-app-tachyon.json 2>/dev/null || true
rm -f /usr/share/rpcd/acl.d/luci-app-tachyon.json 2>/dev/null || true
rm -f /etc/uci-defaults/50_luci-tachyon 2>/dev/null || true
rm -f /etc/tachyon_commit 2>/dev/null || true
rm -f /usr/bin/tachyon 2>/dev/null || true
rm -f /etc/init.d/tachyon 2>/dev/null || true
rm -f /etc/init.d/tachyon-core 2>/dev/null || true
rm -f /etc/hotplug.d/iface/99-tachyon-wan-monitor 2>/dev/null || true
rm -f /www/cgi-bin/tachyon-agent 2>/dev/null || true
rm -f /www/cgi-bin/tachyon-sub 2>/dev/null || true
rm -f /usr/lib/cgi-bin/tachyon-agent 2>/dev/null || true

# Optional binary removal
if [ "$OPT_KEEP_BINARIES" -eq 0 ] || [ "$OPT_PURGE" -eq 1 ]; then
    rm -f /usr/bin/tachyon-core 2>/dev/null || true
    rm -f /usr/lib/libcronet.so 2>/dev/null || true
    # Selectively remove external component binaries/configs only if Tachyon-managed
    for _comp in zapret zapret2 byedpi wdtt olcrtc; do
        if _is_tachyon_managed "$_comp"; then
            case "$_comp" in
                zapret)  rm -f /usr/bin/nfqws 2>/dev/null || true; rm -rf /opt/zapret /etc/config/zapret 2>/dev/null || true ;;
                zapret2) rm -f /usr/bin/nfqws2 2>/dev/null || true; rm -rf /opt/zapret2 /etc/config/zapret2 2>/dev/null || true ;;
                byedpi)  rm -f /usr/bin/ciadpi 2>/dev/null || true; rm -rf /etc/config/byedpi 2>/dev/null || true ;;
                wdtt)    rm -f /usr/bin/wdtt /usr/bin/qwdtt-client /usr/sbin/wdtt-genlists /usr/sbin/wdtt-resolve 2>/dev/null || true; rm -rf /etc/qwdtt /etc/wdtt /etc/config/wdtt 2>/dev/null || true ;;
                olcrtc)  rm -f /usr/bin/olcrtc 2>/dev/null || true; rm -rf /etc/olcrtc /etc/config/olcrtc 2>/dev/null || true ;;
            esac
        fi
    done
    if _is_tachyon_managed "sing_box"; then
        rm -f /usr/bin/sing-box 2>/dev/null || true
    fi
fi

# Clean translations
rm -f /usr/lib/lua/luci/i18n/tachyon.* 2>/dev/null || true
find /usr/lib/lua/luci/i18n/ -name "tachyon.*" -delete 2>/dev/null || true

# Clear runtime and temporary state
rm -rf /var/run/tachyon* /var/log/tachyon* /tmp/tachyon* /tmp/tachyon-core /tmp/ai_doctor* /tmp/tg_* /tmp/warp_* 2>/dev/null || true

# Clear LuCI index and module caches
rm -f /var/luci-indexcache* /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true

# Clean ucitrack entry
if [ -f "/etc/config/ucitrack" ]; then
    uci -q delete ucitrack.@tachyon[0] 2>/dev/null || true
    uci -q commit ucitrack 2>/dev/null || true
fi

# Purge configs, persistent state, and any leftover legacy paths if requested
if [ "$OPT_PURGE" -eq 1 ]; then
    rm -f /etc/config/tachyon* 2>/dev/null || true
    if _is_tachyon_managed "sing_box"; then
        rm -f /usr/bin/sing-box /etc/init.d/sing-box /etc/rc.d/*sing-box* 2>/dev/null || true
        rm -rf /etc/sing-box /tmp/sing-box /usr/share/sing-box /var/run/sing-box* 2>/dev/null || true
    fi
    rm -rf /etc/tachyon /etc/.tachyon /etc/backup/tachyon_config /etc/tachyon-core /usr/share/tachyon-core /var/run/tachyon-core* 2>/dev/null || true
    tui_ok "Все конфигурации и скрытые состояния Tachyon удалены (--purge)"
fi

# Restart rpcd and uhttpd to immediately update LuCI menu
if [ -f "/etc/init.d/rpcd" ]; then
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
if [ -f "/etc/init.d/uhttpd" ]; then
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

tui_ok "Кэш LuCI очищен, файлы и остаточные фрагменты полностью удалены"

# ─── Final Summary ───────────────────────────────────────────────────────────
printf '\n'
printf '  %s%s%s\n' "$_c_dim" "$(_tui_hline '─')" "$_c_reset"
printf '  %s%s✓ Tachyon успешно и чисто удален с вашего роутера!%s\n' "$_c_green" "$_c_bold" "$_c_reset"

if [ "$OPT_PURGE" -eq 0 ] && [ -n "$BACKUP_PATH" ]; then
    printf '  %sРезервная копия конфигурации сохранена:%s %s%s%s\n' "$_c_cyan" "$_c_reset" "$_c_bold" "$BACKUP_PATH" "$_c_reset"
    printf '  %s(а также продублирована в /etc/config/tachyon.bak)%s\n' "$_c_dim" "$_c_reset"
fi

printf '  %sСетевой стек и DNS возвращены в штатный режим OpenWrt.%s\n\n' "$_c_dim" "$_c_reset"

exit 0
