#!/bin/sh
# shellcheck shell=dash
# Tachyon Clean Uninstaller for OpenWrt

set -u

UNINSTALLER_VERSION="2.0.0-beta.4"

OPT_PURGE=0
OPT_YES=0
OPT_KEEP_BINARIES=0

for _arg in "$@"; do
    case "$_arg" in
        --purge|-p) OPT_PURGE=1 ;;
        --yes|-y) OPT_YES=1 ;;
        --keep-binaries) OPT_KEEP_BINARIES=1 ;;
        --help|-h)
            printf 'Tachyon Uninstaller v%s\n\n' "$UNINSTALLER_VERSION"
            printf 'Usage: %s [options]\n' "$0"
            printf '  -y, --yes            Uninstall without confirmation\n'
            printf '  -p, --purge          Remove all configs, state files, and backups\n'
            printf '      --keep-binaries  Keep /usr/bin/tachyon-core\n'
            printf '  -h, --help           Show this help\n'
            exit 0
            ;;
        *) ;;
    esac
done

if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    printf '[ERR] Run this uninstaller as root.\n' >&2
    exit 1
fi

if [ "$OPT_YES" -eq 0 ] && [ -t 0 ] 2>/dev/null; then
    printf 'Remove Tachyon from this router? [y/N]: '
    read -r _answer
    case "$_answer" in
        y|Y|yes|Yes|YES) ;;
        *) printf '[INFO] Uninstall cancelled.\n'; exit 0 ;;
    esac
fi

# Step 1: Backup configuration unless --purge
if [ "$OPT_PURGE" -eq 0 ]; then
    _ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%s)"
    _backup_dir="/etc/tachyon-backup-${_ts}"
    _backed=0
    if [ -f /etc/tachyon/tachyon.json ] || [ -f /etc/tachyon/data.json ] || [ -f /etc/config/tachyon ]; then
        mkdir -p "$_backup_dir"
        chmod 700 "$_backup_dir" 2>/dev/null || true
    fi
    if [ -f /etc/tachyon/tachyon.json ]; then
        cp -af /etc/tachyon/tachyon.json "$_backup_dir/tachyon.json" 2>/dev/null || true
        chmod 600 "$_backup_dir/tachyon.json" 2>/dev/null || true
        _backed=1
    fi
    if [ -f /etc/tachyon/data.json ]; then
        cp -af /etc/tachyon/data.json "$_backup_dir/data.json" 2>/dev/null || true
        chmod 600 "$_backup_dir/data.json" 2>/dev/null || true
        _backed=1
    fi
    if [ -f /etc/config/tachyon ]; then
        cp -af /etc/config/tachyon "$_backup_dir/tachyon.uci" 2>/dev/null || true
        chmod 600 "$_backup_dir/tachyon.uci" 2>/dev/null || true
        _backed=1
    fi
    if [ "$_backed" -eq 1 ]; then
        printf '[OK] Backup saved to %s\n' "$_backup_dir"
    fi
fi

# Step 2: Stop services and daemons
rm -f /var/run/tachyon/starting /var/run/tachyon/reloading /var/run/tachyon*.lock 2>/dev/null || true

for _svc in /etc/init.d/tachyon /etc/init.d/tachyon-core; do
    if [ -f "$_svc" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 8 "$_svc" stop >/dev/null 2>&1 || true
        else
            "$_svc" stop >/dev/null 2>&1 || true
        fi
        "$_svc" disable >/dev/null 2>&1 || true
    fi
done

killall -9 tachyon >/dev/null 2>&1 || true
killall -9 tachyon-core >/dev/null 2>&1 || true
printf '[OK] Services and daemon processes stopped\n'

# Step 3: Clean nftables & IP policy routing
if command -v nft >/dev/null 2>&1; then
    nft delete table inet tachyon >/dev/null 2>&1 || true
    nft delete table inet TachyonTable >/dev/null 2>&1 || true
    nft delete table inet TachyonKillSwitch >/dev/null 2>&1 || true
    # TUN kill-switch rules
    for _p in 9499 9500 9501; do for _fam in -4 -6; do while ip "$_fam" rule del pref "$_p" >/dev/null 2>&1; do :; done; done; done
    nft delete table inet steer >/dev/null 2>&1 || true
    nft delete table ip tachyon >/dev/null 2>&1 || true
    nft delete table ip6 tachyon >/dev/null 2>&1 || true
    rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft /usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft /etc/nftables.d/10-tachyon.nft /etc/sysctl.d/99-tachyon-bbr.conf 2>/dev/null || true
    printf '[OK] nftables tables cleaned\n'
fi

if command -v ip >/dev/null 2>&1; then
    for _fam in -4 -6; do
        ip "$_fam" rule del fwmark 0x04000000/0x04000000 lookup 100 priority 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x04000000/0x04000000 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x04000000 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x04000000/0x04000000 table tachyon priority 105 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x04000000 table tachyon >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x100/0xff00 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x100 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x200/0xff00 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x200 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x10000000/0x10000000 lookup 100 priority 101 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x10000000/0x10000000 lookup 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x10000000 table 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x10000000 lookup 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x1/0x1 lookup 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x1 lookup 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x2/0x2 lookup 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del fwmark 0x2 lookup 100 >/dev/null 2>&1 || true
        ip "$_fam" rule del iif lo fwmark 0x1/0x1 table main >/dev/null 2>&1 || true
    done
    ip route flush table tachyon >/dev/null 2>&1 || true
    ip route flush table 105 >/dev/null 2>&1 || true
    ip route flush table 100 >/dev/null 2>&1 || true
    ip -6 route flush table tachyon >/dev/null 2>&1 || true
    ip -6 route flush table 105 >/dev/null 2>&1 || true
    ip -6 route flush table 100 >/dev/null 2>&1 || true

    if [ -f /etc/iproute2/rt_tables ]; then
        sed -i '/105[[:space:]]\+tachyon/d' /etc/iproute2/rt_tables 2>/dev/null || true
    fi
    printf '[OK] Policy routing rules restored\n'
fi

if [ -s /tmp/tachyon-sqm-iface ] && command -v tc >/dev/null 2>&1; then
    _sqm_if="$(head -n 1 /tmp/tachyon-sqm-iface 2>/dev/null | tr -d ' \r\n')"
    if [ -n "$_sqm_if" ]; then
        tc qdisc del dev "$_sqm_if" root >/dev/null 2>&1 || true
        printf '[OK] SQM qdisc removed from %s\n' "$_sqm_if"
    fi
fi

# Step 4: Restore DNS & dnsmasq
rm -f /etc/dnsmasq.d/tachyon*.conf /tmp/dnsmasq.d/tachyon*.conf /tmp/dnsmasq.*.d/tachyon*.conf 2>/dev/null || true
rm -f /etc/tachyon/dnsmasq-tailscale.servers /var/run/tachyon/dnsmasq-tailscale.servers /var/run/tachyon/tachyon-core-version 2>/dev/null || true

if command -v uci >/dev/null 2>&1 && [ -f /etc/config/dhcp ]; then
    uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.42" 2>/dev/null || true
    _orig_servers="$(uci -q get dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true)"
    if [ -n "$_orig_servers" ]; then
        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
        for _srv in $_orig_servers; do
            [ "$_srv" != "127.0.0.42" ] && uci -q add_list dhcp.@dnsmasq[0].server="$_srv" 2>/dev/null || true
        done
        uci -q delete dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true
    fi

    for _opt in noresolv cachesize rebind_protection localuse addn_hosts notinterface serversfile localservice; do
        _val="$(uci -q get "dhcp.@dnsmasq[0].tachyon_${_opt}" 2>/dev/null || true)"
        if [ -n "$_val" ]; then
            if [ "$_val" = "__tachyon_unset__" ]; then
                uci -q delete "dhcp.@dnsmasq[0].${_opt}" 2>/dev/null || true
            else
                uci -q set "dhcp.@dnsmasq[0].${_opt}=${_val}" 2>/dev/null || true
            fi
            uci -q delete "dhcp.@dnsmasq[0].tachyon_${_opt}" 2>/dev/null || true
        fi
    done

    if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
        uci -q set dhcp.@dnsmasq[0].noresolv="0" 2>/dev/null || true
    fi
    if [ "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)" = "0" ]; then
        uci -q set dhcp.@dnsmasq[0].cachesize="150" 2>/dev/null || true
    fi

    # Restore backed up odhcpd LAN options (handles both 2.0 "unset"/comma and 1.x "__absent__"/whitespace)
    for _lan_opt in ra dhcpv6 ndp ra_dns ra_default; do
        _lan_val="$(uci -q get "dhcp.lan.tachyon_lan_${_lan_opt}" 2>/dev/null || true)"
        if [ -n "$_lan_val" ]; then
            if [ "$_lan_val" = "unset" ] || [ "$_lan_val" = "__absent__" ] || [ "$_lan_val" = "__tachyon_unset__" ]; then
                uci -q delete "dhcp.lan.${_lan_opt}" 2>/dev/null || true
            else
                uci -q set "dhcp.lan.${_lan_opt}=${_lan_val}" 2>/dev/null || true
            fi
            uci -q delete "dhcp.lan.tachyon_lan_${_lan_opt}" 2>/dev/null || true
        fi
    done
    _lan_dns="$(uci -q get dhcp.lan.tachyon_lan_dns 2>/dev/null || true)"
    if [ -n "$_lan_dns" ]; then
        uci -q delete dhcp.lan.dns 2>/dev/null || true
        if [ "$_lan_dns" != "unset" ] && [ "$_lan_dns" != "__absent__" ] && [ "$_lan_dns" != "__tachyon_unset__" ]; then
            while IFS= read -r _dns_entry; do
                [ -n "$_dns_entry" ] && uci -q add_list "dhcp.lan.dns=${_dns_entry}" 2>/dev/null || true
            done <<EOF
$(printf '%s\n' "$_lan_dns" | tr ', \t' '\n')
EOF
        fi
        uci -q delete dhcp.lan.tachyon_lan_dns 2>/dev/null || true
    fi
    uci -q delete dhcp.lan.tachyon_lan_managed 2>/dev/null || true

    uci -q delete dhcp.tachyon 2>/dev/null || true
    uci -q commit dhcp 2>/dev/null || true
fi

if [ -x /etc/init.d/dnsmasq ]; then
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    printf '[OK] DNS and dnsmasq restored\n'
fi
if [ -x /etc/init.d/odhcpd ]; then
    /etc/init.d/odhcpd restart >/dev/null 2>&1 || true
    printf '[OK] IPv6 LAN (odhcpd) restored\n'
fi

# Step 5: Remove packages & crontab entries
if command -v crontab >/dev/null 2>&1; then
    _tachyon_cron_re='#[[:space:]]*tachyon-(list-update|subscription-update|component-update-check|parental-quota)([[:space:]]|$)|/usr/bin/tachyon[[:space:]]+(list_update(_if_due)?|subscription_update(_if_due)?|component_updates_if_due|component_auto_update_apply|parental_quota_tick)([[:space:]]|$)'
    _cron_cur="$(mktemp /tmp/cron-cur.XXXXXX 2>/dev/null || echo /tmp/cron-cur.tachyon.tmp)"
    _crontmp="$(mktemp /tmp/cron.XXXXXX 2>/dev/null || echo /tmp/cron.tachyon.tmp)"
    if [ -r /etc/crontabs/root ]; then
        cat /etc/crontabs/root > "$_cron_cur" 2>/dev/null || true
    else
        crontab -l > "$_cron_cur" 2>/dev/null || true
    fi
    if grep -q -E "$_tachyon_cron_re" "$_cron_cur" 2>/dev/null; then
        grep -v -E "$_tachyon_cron_re" "$_cron_cur" > "$_crontmp" || true
        crontab "$_crontmp" 2>/dev/null || true
        if [ -s "$_crontmp" ] && [ -x /etc/init.d/cron ]; then
            pgrep crond >/dev/null 2>&1 || /etc/init.d/cron start >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$_cron_cur" "$_crontmp" 2>/dev/null || true
fi

if command -v apk >/dev/null 2>&1 && [ -d /lib/apk/db ]; then
    for _pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
        if [ -f /etc/apk/world ]; then
            sed -i -E "/^${_pkg}([><= ].*)?$/d" /etc/apk/world 2>/dev/null || true
        fi
        if apk info -e "$_pkg" >/dev/null 2>&1; then
            apk del --no-network --repositories-file /dev/null "$_pkg" >/dev/null 2>&1 || true
        fi
    done
    if [ "$OPT_KEEP_BINARIES" -eq 0 ] && apk info -e tachyon-core >/dev/null 2>&1; then
        apk del --no-network --repositories-file /dev/null tachyon-core >/dev/null 2>&1 || true
    fi
elif command -v opkg >/dev/null 2>&1; then
    for _pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
        if opkg list-installed "$_pkg" 2>/dev/null | grep -q "^$_pkg "; then
            opkg remove --force-depends --force-remove "$_pkg" >/dev/null 2>&1 || true
        fi
    done
    if [ "$OPT_KEEP_BINARIES" -eq 0 ] && opkg list-installed tachyon-core 2>/dev/null | grep -q '^tachyon-core '; then
        opkg remove --force-depends --force-remove tachyon-core >/dev/null 2>&1 || true
    fi
fi

# Step 6: Remove installed files & LuCI launcher
rm -rf /usr/lib/tachyon /usr/share/tachyon /www/luci-static/resources/view/tachyon 2>/dev/null || true
rm -f /www/yacd 2>/dev/null || rm -rf /www/yacd 2>/dev/null || true
rm -f /usr/share/luci/menu.d/tachyon-launcher.json /usr/share/rpcd/acl.d/tachyon-launcher.json 2>/dev/null || true
rm -f /usr/share/luci/menu.d/luci-app-tachyon.json /usr/share/rpcd/acl.d/luci-app-tachyon.json 2>/dev/null || true
rm -f /usr/libexec/rpcd/tachyon /etc/uci-defaults/50_luci-tachyon /etc/tachyon_commit /lib/upgrade/keep.d/tachyon /usr/lib/lua/luci/i18n/tachyon.ru.lmo 2>/dev/null || true
rm -f /usr/bin/tachyon /usr/bin/tachyon.new /etc/init.d/tachyon /etc/rc.d/*tachyon* 2>/dev/null || true
rm -f /etc/hotplug.d/iface/99-tachyon-wan-monitor /www/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-sub /usr/lib/cgi-bin/tachyon-agent 2>/dev/null || true

if [ "$OPT_KEEP_BINARIES" -eq 0 ]; then
    rm -f /usr/bin/tachyon-core /usr/bin/tachyon-core.new /etc/init.d/tachyon-core 2>/dev/null || true
fi

rm -rf /var/run/tachyon* /var/log/tachyon* /tmp/tachyon* /tmp/tachyon-core /tmp/ai_doctor* /tmp/tg_* /tmp/warp_* /tmp/luci-modulecache 2>/dev/null || true
rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null || true

if [ "$OPT_PURGE" -eq 1 ]; then
    rm -f /etc/config/tachyon* 2>/dev/null || true
    rm -rf /etc/tachyon /etc/tachyon-core /etc/tachyon-backup-* 2>/dev/null || true
    printf '[OK] All configs and backups removed (--purge)\n'
fi

for _luci_svc in /etc/init.d/rpcd /etc/init.d/uhttpd; do
    [ -x "$_luci_svc" ] && "$_luci_svc" restart >/dev/null 2>&1 || true
done

printf '[OK] Tachyon removed.\n'
exit 0
