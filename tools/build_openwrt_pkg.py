#!/usr/bin/env python3
"""Build OpenWrt .ipk (opkg) and .apk (apk-tools) packages for tachyon.

Uses only Python stdlib (tarfile, gzip, hashlib, io) and produces deterministic
artifacts for OpenWrt router architectures.
"""

import argparse
import gzip
import hashlib
import io
import os
import re
import tarfile
import time


SYSUPGRADE_KEEP_FILE = "/etc/tachyon/\n/etc/tachyon-core/\n/usr/bin/tachyon-core\n"

PREINST_SCRIPT = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ -s /etc/config/tachyon ] && [ ! -s /etc/tachyon/backup-pre-2.0/tachyon.uci ]; then
    mkdir -p /etc/tachyon/backup-pre-2.0 2>/dev/null || true
    cp -af /etc/config/tachyon /etc/tachyon/backup-pre-2.0/tachyon.uci 2>/dev/null || true
    chmod 600 /etc/tachyon/backup-pre-2.0/tachyon.uci 2>/dev/null || true
fi
_is_v1=0
if [ -d /usr/lib/tachyon ] || [ -e /usr/libexec/rpcd/tachyon ] || [ -e /usr/bin/tachyon-read ] || [ -e /etc/init.d/tachyon-torrserver-direct ]; then
    _is_v1=1
elif [ -x /usr/bin/tachyon ] && head -c 2 /usr/bin/tachyon 2>/dev/null | grep -q '^#!'; then
    _is_v1=1
fi
if [ "$_is_v1" -eq 1 ]; then
    __anc=" $$ "
    if [ -n "${PPID:-}" ]; then
        __anc="$__anc$PPID "
    fi
    __p=$$
    while [ -n "$__p" ] && [ "$__p" -gt 1 ] 2>/dev/null; do
        __anc="$__anc$__p "
        __p=$(awk '{ sub(/.*\\) /, ""); print $2 }' "/proc/$__p/stat" 2>/dev/null)
    done
    for __pdir in /proc/[0-9]*; do
        __pid="${__pdir##*/}"
        case "$__anc" in *" $__pid "*) continue;; esac
        if [ -r "$__pdir/cmdline" ]; then
            __a0="$(head -c 512 "$__pdir/cmdline" 2>/dev/null | tr '\\0' '\\n' | sed -n '1p')"
            __a1="$(head -c 512 "$__pdir/cmdline" 2>/dev/null | tr '\\0' '\\n' | sed -n '2p')"
            case "$__a0:$__a1" in
                *sh:-*c*) continue;;
            esac
            __cmd="$(head -c 512 "$__pdir/cmdline" 2>/dev/null | tr '\\0' ' ')"
            case "$__cmd" in
                *99-tachyon-wan*|*"flock 1000"*|*"/etc/init.d/tachyon"*)
                    kill -9 "$__pid" >/dev/null 2>&1 || true
                    continue
                    ;;
            esac
        fi
        if [ -e "$__pdir/fd/1000" ]; then
            case "$(readlink "$__pdir/fd/1000" 2>/dev/null)" in
                *procd_tachyon*) kill -9 "$__pid" >/dev/null 2>&1 || true ;;
            esac
        fi
    done
    _to=""
    if command -v timeout >/dev/null 2>&1; then
        if timeout 1 /bin/true >/dev/null 2>&1; then
            _to="timeout 15"
        elif timeout -t 1 /bin/true >/dev/null 2>&1; then
            _to="timeout -t 15"
        fi
    fi
    if [ -x /usr/bin/tachyon ]; then
        $_to /usr/bin/tachyon stop >/dev/null 2>&1 || true
    fi
    if [ -x /etc/init.d/tachyon ]; then
        $_to /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    fi
    if [ -x /etc/init.d/tachyon-core ]; then
        $_to /etc/init.d/tachyon-core stop >/dev/null 2>&1 || true
    fi
    : > /tmp/tachyon-upgrading-from-v1 2>/dev/null || true
fi
exit 0
"""

POSTINST_SCRIPT = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
mkdir -p /etc/tachyon /etc/tachyon-core /usr/share/tachyon /tmp/dnsmasq.d 2>/dev/null || true

# Restore /etc/config/tachyon from preinst backup if the package manager removed it.
if [ ! -s /etc/config/tachyon ] && [ -s /etc/tachyon/backup-pre-2.0/tachyon.uci ]; then
    cp -af /etc/tachyon/backup-pre-2.0/tachyon.uci /etc/config/tachyon 2>/dev/null || true
    chmod 600 /etc/config/tachyon 2>/dev/null || true
fi

# Migrate 1.x (ucode + rpcd) -> 2.0 (Pure-Rust daemon): clean legacy hooks/services/tables,
# preserving /etc/config/tachyon for automatic store import.
_is_v1=0
if [ -f /tmp/tachyon-upgrading-from-v1 ] || [ -d /usr/lib/tachyon ] || [ -e /usr/libexec/rpcd/tachyon ] || [ -e /usr/bin/tachyon-read ] || [ -e /etc/init.d/tachyon-torrserver-direct ]; then
    _is_v1=1
fi
if [ "$_is_v1" -eq 1 ]; then
    _to=""
    if command -v timeout >/dev/null 2>&1; then
        if timeout 1 /bin/true >/dev/null 2>&1; then
            _to="timeout 15"
        elif timeout -t 1 /bin/true >/dev/null 2>&1; then
            _to="timeout -t 15"
        fi
    fi

    for _old_svc in /etc/init.d/tachyon-torrserver-direct /etc/init.d/tachyon-core; do
        if [ -x "$_old_svc" ]; then
            $_to "$_old_svc" stop >/dev/null 2>&1 || true
            "$_old_svc" disable >/dev/null 2>&1 || true
        fi
    done
    rm -f /etc/rc.d/*tachyon-core* /etc/rc.d/*tachyon-torrserver-direct* 2>/dev/null || true

    __post_anc=" $$ "
    if [ -n "${PPID:-}" ]; then
        __post_anc="$__post_anc$PPID "
    fi
    __post_p=$$
    while [ -n "$__post_p" ] && [ "$__post_p" -gt 1 ] 2>/dev/null; do
        __post_anc="$__post_anc$__post_p "
        __post_p=$(awk '{ sub(/.*\\) /, ""); print $2 }' "/proc/$__post_p/stat" 2>/dev/null)
    done
    for p in /proc/[0-9]*; do
        __pid="${p##*/}"
        case "$__post_anc" in *" $__pid "*) continue;; esac
        [ -r "$p/cmdline" ] || continue
        __a0="$(head -c 512 "$p/cmdline" 2>/dev/null | tr '\\0' '\\n' | sed -n '1p')"
        __a1="$(head -c 512 "$p/cmdline" 2>/dev/null | tr '\\0' '\\n' | sed -n '2p')"
        case "$__a0:$__a1" in
            *sh:-*c*) continue;;
        esac
        case "$(head -c 512 "$p/cmdline" 2>/dev/null | tr '\\0' ' ')" in
            *"/usr/lib/tachyon/"*|*"/usr/bin/tachyon-core"*)
                kill -9 "$__pid" >/dev/null 2>&1 || true
                ;;
        esac
    done

    if command -v nft >/dev/null 2>&1; then
        nft delete table inet tachyon >/dev/null 2>&1 || true
        nft delete table inet TachyonTable >/dev/null 2>&1 || true
        nft delete table inet TachyonKillSwitch >/dev/null 2>&1 || true
        nft delete table ip tachyon >/dev/null 2>&1 || true
        nft delete table ip6 tachyon >/dev/null 2>&1 || true
        for _h in $(nft -a list chain inet fw4 forward 2>/dev/null | sed -n 's/.*Tachyon: skip flow offload.*# handle \\([0-9][0-9]*\\).*/\\1/p'); do
            nft delete rule inet fw4 forward handle "$_h" >/dev/null 2>&1 || true
        done
    fi
    rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft /usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft /usr/share/nftables.d/ruleset-post/10-tachyon-offload.nft /usr/share/nftables.d/chain-pre/forward/10-tachyon-offload.nft 2>/dev/null || true

    if command -v ip >/dev/null 2>&1; then
        for _p in 99 105 9499 9500 9501; do
            for _fam in -4 -6; do
                while ip "$_fam" rule del pref "$_p" >/dev/null 2>&1; do :; done
            done
        done
        for _fam in -4 -6; do
            ip "$_fam" rule del fwmark 0x04000000/0x04000000 lookup 100 >/dev/null 2>&1 || true
            ip "$_fam" rule del fwmark 0x04000000 lookup 100 >/dev/null 2>&1 || true
            ip "$_fam" rule del fwmark 0x10000000/0x10000000 lookup 100 >/dev/null 2>&1 || true
            ip "$_fam" rule del fwmark 0x10000000 lookup 100 >/dev/null 2>&1 || true
            while ip "$_fam" rule del table tachyon >/dev/null 2>&1; do :; done
            ip "$_fam" route flush table 100 >/dev/null 2>&1 || true
            ip "$_fam" route flush table tachyon >/dev/null 2>&1 || true
        done
    fi

    if command -v uci >/dev/null 2>&1 && [ -f /etc/config/dhcp ]; then
        _dont_touch="$(uci -q get tachyon.settings.dont_touch_dhcp 2>/dev/null || echo '0')"
        if [ "$_dont_touch" != "1" ]; then
            _had_v1_dns=0
            if uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | grep -q '127\\.0\\.0\\.42'; then
                _had_v1_dns=1
            fi
            if [ -n "$(uci -q get dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true)" ] || \
               [ -n "$(uci -q get dhcp.@dnsmasq[0].tachyon_noresolv 2>/dev/null || true)" ] || \
               [ -n "$(uci -q get dhcp.@dnsmasq[0].tachyon_cachesize 2>/dev/null || true)" ] || \
               [ -n "$(uci -q get dhcp.tachyon 2>/dev/null || true)" ]; then
                _had_v1_dns=1
            fi
            uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.42" 2>/dev/null || true
            _orig_servers="$(uci -q get dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true)"
            if [ -n "$_orig_servers" ]; then
                uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
                for _srv in $_orig_servers; do
                    [ "$_srv" != "127.0.0.42" ] && uci -q add_list dhcp.@dnsmasq[0].server="$_srv" 2>/dev/null || true
                done
                uci -q delete dhcp.@dnsmasq[0].tachyon_server 2>/dev/null || true
            fi
            for _opt in noresolv cachesize rebind_protection localuse addn_hosts notinterface localservice; do
                _val="$(uci -q get "dhcp.@dnsmasq[0].tachyon_${_opt}" 2>/dev/null || true)"
                if [ -n "$_val" ]; then
                    if [ "$_val" = "__tachyon_unset__" ] || [ "$_val" = "__absent__" ] || [ "$_val" = "unset" ]; then
                        uci -q delete "dhcp.@dnsmasq[0].${_opt}" 2>/dev/null || true
                    else
                        uci -q set "dhcp.@dnsmasq[0].${_opt}=${_val}" 2>/dev/null || true
                    fi
                    uci -q delete "dhcp.@dnsmasq[0].tachyon_${_opt}" 2>/dev/null || true
                fi
            done
            _sf_bak="$(uci -q get dhcp.@dnsmasq[0].tachyon_serversfile 2>/dev/null || true)"
            if [ -n "$_sf_bak" ]; then
                if [ "$_sf_bak" = "1" ] || [ "$_sf_bak" = "__tachyon_unset__" ] || [ "$_sf_bak" = "__absent__" ] || [ "$_sf_bak" = "unset" ]; then
                    _cur_sf="$(uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null || true)"
                    case "$_cur_sf" in
                        ""|"1"|*tachyon*) uci -q delete dhcp.@dnsmasq[0].serversfile 2>/dev/null || true ;;
                    esac
                else
                    uci -q set "dhcp.@dnsmasq[0].serversfile=${_sf_bak}" 2>/dev/null || true
                fi
                uci -q delete dhcp.@dnsmasq[0].tachyon_serversfile 2>/dev/null || true
            fi
            if [ "$_had_v1_dns" -eq 1 ]; then
                if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
                    uci -q set dhcp.@dnsmasq[0].noresolv="0" 2>/dev/null || true
                fi
                if [ "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)" = "0" ]; then
                    uci -q set dhcp.@dnsmasq[0].cachesize="150" 2>/dev/null || true
                fi
            fi
            uci -q delete dhcp.tachyon 2>/dev/null || true
            uci -q commit dhcp 2>/dev/null || true
            rm -f /tmp/dnsmasq.d/tachyon.conf 2>/dev/null || true
            if [ "$_had_v1_dns" -eq 1 ] && [ -x /etc/init.d/dnsmasq ]; then
                /etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
            fi
        fi
    fi

    rm -rf /usr/lib/tachyon /var/run/tachyon/section-cache /var/run/tachyon/ui-state 2>/dev/null || true
    rm -f /usr/libexec/rpcd/tachyon /usr/bin/tachyon-read /etc/init.d/tachyon-torrserver-direct /www/cgi-bin/tachyon-agent /usr/lib/cgi-bin/tachyon-agent /etc/uci-defaults/50_luci-tachyon /usr/share/luci/menu.d/luci-app-tachyon.json /usr/share/rpcd/acl.d/luci-app-tachyon.json /usr/lib/lua/luci/i18n/tachyon.ru.lmo 2>/dev/null || true
    rm -f /tmp/tachyon-upgrading-from-v1 2>/dev/null || true
fi

if command -v crontab >/dev/null 2>&1; then
    _tachyon_cron_re='#[[:space:]]*tachyon-(list-update|subscription-update|component-update-check|parental-quota)([[:space:]]|$)|/usr/bin/tachyon[[:space:]]+(list_update(_if_due)?|subscription_update(_if_due)?|component_updates_if_due|component_auto_update_apply|parental_quota_tick)([[:space:]]|$)'
    _cron_cur="$(mktemp /tmp/tachyon-cron-cur.XXXXXX 2>/dev/null || echo "/tmp/tachyon-cron-cur.$$")"
    _crontmp="$(mktemp /tmp/tachyon-cron.XXXXXX 2>/dev/null || echo "/tmp/tachyon-cron.$$")"
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

rm -f /tmp/luci-indexcache* /usr/share/tachyon/tachyon.ru.po 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
for _js in /www/luci-static/resources/view/tachyon/*.js /www/luci-static/resources/luci.js /www/luci-static/resources/view/tachyon /www/luci-static/resources; do
    [ -e "$_js" ] && touch "$_js" 2>/dev/null || true
done
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true

chmod 755 /usr/bin/tachyon /etc/init.d/tachyon /www/cgi-bin/tachyon-sub 2>/dev/null || true
if [ -x /etc/init.d/tachyon ]; then
    /etc/init.d/tachyon enable >/dev/null 2>&1 || true
    /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    _wait_i=0
    while [ "$_wait_i" -lt 6 ]; do
        _alive=0
        for _p in /proc/[0-9]*; do
            [ -r "$_p/comm" ] || continue
            if [ "$(cat "$_p/comm" 2>/dev/null)" = "tachyon" ]; then
                _alive=1
                break
            fi
        done
        [ "$_alive" -eq 0 ] && break
        _wait_i=$((_wait_i + 1))
        sleep 1
    done
    killall -9 tachyon >/dev/null 2>&1 || true
    /etc/init.d/tachyon start >/dev/null 2>&1 || true
fi
exit 0
"""

CGI_SUB_SCRIPT = """#!/bin/sh
_port="1680"
if [ -s /etc/tachyon/tachyon.json ]; then
    _jport="$(sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' /etc/tachyon/tachyon.json | head -n 1)"
    [ -z "$_jport" ] && _jport="$(sed -n 's/.*"web_port"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' /etc/tachyon/tachyon.json | head -n 1)"
    if [ -n "$_jport" ] && [ "$_jport" -ge 1 ] 2>/dev/null && [ "$_jport" -le 65535 ] 2>/dev/null; then
        _port="$_jport"
    fi
elif command -v uci >/dev/null 2>&1; then
    _uport="$(uci -q get tachyon.settings.listen_port 2>/dev/null)"
    [ -z "$_uport" ] && _uport="$(uci -q get tachyon.settings.web_port 2>/dev/null)"
    case "$_uport" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$_uport" -ge 1 ] 2>/dev/null && [ "$_uport" -le 65535 ] 2>/dev/null; then
                _port="$_uport"
            fi
            ;;
    esac
fi
if [ "${QUERY_STRING:-}" = "panel_port=1" ]; then
    printf 'Status: 200 OK\\r\\nContent-Type: application/json\\r\\nCache-Control: no-store\\r\\n\\r\\n{"port":%s}\\n' "$_port"
    exit 0
fi
_url="http://127.0.0.1:${_port}/cgi-bin/tachyon-sub${PATH_INFO:-}${QUERY_STRING:+?${QUERY_STRING}}"
_tmp="$(mktemp /tmp/tachyon-cgi-sub.XXXXXX 2>/dev/null || echo "/tmp/tachyon-cgi-sub.$$")"
trap 'rm -f "$_tmp" 2>/dev/null || true' EXIT INT TERM
_ok=0
if [ -n "${HTTP_HOST:-}" ] && [ -n "${HTTP_USER_AGENT:-}" ]; then
    curl -sS -i --max-time 10 -H "Host: ${HTTP_HOST}" -H "User-Agent: ${HTTP_USER_AGENT}" "$_url" > "$_tmp" 2>/dev/null && _ok=1
elif [ -n "${HTTP_HOST:-}" ]; then
    curl -sS -i --max-time 10 -H "Host: ${HTTP_HOST}" "$_url" > "$_tmp" 2>/dev/null && _ok=1
elif [ -n "${HTTP_USER_AGENT:-}" ]; then
    curl -sS -i --max-time 10 -H "User-Agent: ${HTTP_USER_AGENT}" "$_url" > "$_tmp" 2>/dev/null && _ok=1
else
    curl -sS -i --max-time 10 "$_url" > "$_tmp" 2>/dev/null && _ok=1
fi
if [ "$_ok" -eq 1 ]; then
    awk '
        NR==1 && $1 ~ /^HTTP\\// {
            code=$2;
            sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "");
            sub(/\\r$/, "");
            printf "Status: %s %s\\r\\n", code, $0;
            next;
        }
        { print }
    ' "$_tmp"
    rm -f "$_tmp" 2>/dev/null || true
    exit 0
fi
rm -f "$_tmp" 2>/dev/null || true
printf "Status: 502 Bad Gateway\\r\\nContent-Type: text/plain\\r\\n\\r\\nTachyon web daemon unavailable\\n"
exit 0
"""

_COMMON_DEINSTALL_BODY = """if [ -x /etc/init.d/tachyon ]; then
    /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    /etc/init.d/tachyon disable >/dev/null 2>&1 || true
fi
rm -f /etc/nftables.d/10-tachyon.nft /usr/share/nftables.d/chain-pre/input/10-tachyon.nft /usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft /usr/share/nftables.d/ruleset-post/10-tachyon-offload.nft /usr/share/nftables.d/chain-pre/forward/10-tachyon-offload.nft /etc/sysctl.d/99-tachyon-bbr.conf /www/cgi-bin/tachyon-sub /tmp/luci-indexcache* 2>/dev/null || true
if command -v nft >/dev/null 2>&1; then
    nft delete table inet TachyonTable >/dev/null 2>&1 || true
    nft delete table inet TachyonKillSwitch >/dev/null 2>&1 || true
    nft delete table inet tachyon >/dev/null 2>&1 || true
    for _h in $(nft -a list chain inet fw4 forward 2>/dev/null | sed -n 's/.*Tachyon: skip flow offload.*# handle \\([0-9][0-9]*\\).*/\\1/p'); do
        nft delete rule inet fw4 forward handle "$_h" >/dev/null 2>&1 || true
    done
fi
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/firewall ]; then
    _fw_changed=0
    for _fwsec in $(uci -q show firewall 2>/dev/null | sed -n 's/^firewall\\.\\(tachyon_[^.=]*\\)=.*/\\1/p' | sort -u); do
        uci -q delete "firewall.${_fwsec}" 2>/dev/null && _fw_changed=1 || true
    done
    if [ "$_fw_changed" -eq 1 ]; then
        uci -q commit firewall 2>/dev/null || true
        [ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1 || true
    fi
fi
if command -v ip >/dev/null 2>&1; then
    for _p in 9499 9500 9501; do
        for _fam in -4 -6; do
            while ip "$_fam" rule del pref "$_p" >/dev/null 2>&1; do :; done
        done
    done
fi
"""

PRERM_SCRIPT = (
    "#!/bin/sh\n"
    "[ -n \"${IPKG_INSTROOT}\" ] && exit 0\n"
    "case \"${1:-remove}\" in\n"
    "    remove|deinstall|purge)\n"
    + _COMMON_DEINSTALL_BODY
    + "        ;;\n"
    "esac\n"
    "exit 0\n"
)

# apk passes the package version as $1 to .pre-deinstall (and never runs it on upgrade),
# so unlike opkg prerm we must clean up unconditionally rather than matching $1 == remove.
APK_PRE_DEINSTALL_SCRIPT = (
    "#!/bin/sh\n"
    "[ -n \"${IPKG_INSTROOT}\" ] && exit 0\n"
    + _COMMON_DEINSTALL_BODY
    + "exit 0\n"
)


def _gzip_bytes(raw: bytes, mtime: int = 0) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, compresslevel=9, mtime=mtime) as gz:
        gz.write(raw)
    return buf.getvalue()


def _strip_tar_eof(tar_bytes: bytes) -> bytes:
    """Strip trailing 512-byte zero blocks from a tar stream (required for APK control segment)."""
    end = len(tar_bytes)
    while end >= 512 and tar_bytes[end - 512 : end] == b"\x00" * 512:
        end -= 512
    return tar_bytes[:end]


def _make_pax_record(key: str, value: str) -> bytes:
    body = f" {key}={value}\n".encode("utf-8")
    length = len(body) + 3
    while True:
        rec = f"{length}{body.decode('utf-8')}".encode("utf-8")
        if len(rec) == length:
            return rec
        length = len(rec)


def _add_ustar_dir(tf: tarfile.TarFile, name: str, mtime: int) -> None:
    ti = tarfile.TarInfo(name=name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    ti.mtime = mtime
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    tf.addfile(ti)


def _add_ustar_file(tf: tarfile.TarFile, name: str, content: bytes, mode: int, mtime: int) -> None:
    ti = tarfile.TarInfo(name=name)
    ti.type = tarfile.REGTYPE
    ti.size = len(content)
    ti.mode = mode
    ti.mtime = mtime
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    tf.addfile(ti, io.BytesIO(content))


def _add_apk_tar_entry(
    tf: tarfile.TarFile,
    name: str,
    data: bytes | None,
    mode: int,
    is_dir: bool = False,
    mtime: int = 0,
) -> None:
    """Add an entry to an APK tar stream with APK-TOOLS.checksum.SHA1 PAX extended header."""
    if not is_dir and data is not None:
        sha1_hex = hashlib.sha1(data).hexdigest()
        pax_bytes = _make_pax_record("APK-TOOLS.checksum.SHA1", sha1_hex)
        pax_info = tarfile.TarInfo(name=f"PaxHeader/{os.path.basename(name)}")
        pax_info.type = tarfile.XHDTYPE
        pax_info.size = len(pax_bytes)
        pax_info.mtime = mtime
        pax_info.mode = 0o644
        pax_info.uid = 0
        pax_info.gid = 0
        pax_info.uname = "root"
        pax_info.gname = "root"
        tf.addfile(pax_info, io.BytesIO(pax_bytes))

    ti = tarfile.TarInfo(name=name)
    ti.mtime = mtime
    ti.mode = mode
    ti.uid = 0
    ti.gid = 0
    ti.uname = "root"
    ti.gname = "root"
    if is_dir:
        ti.type = tarfile.DIRTYPE
        ti.size = 0
        tf.addfile(ti)
    else:
        assert data is not None
        ti.type = tarfile.REGTYPE
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))


def _collect_view_assets(views_dir: str) -> list[tuple[str, bytes]]:
    assets: list[tuple[str, bytes]] = []
    if not os.path.isdir(views_dir):
        return assets
    for root, dirs, files in os.walk(views_dir):
        dirs.sort()
        for entry in sorted(files):
            full = os.path.join(root, entry)
            if os.path.isfile(full):
                rel = os.path.relpath(full, views_dir).replace(os.sep, "/")
                with open(full, "rb") as f:
                    assets.append((rel, f.read()))
    return sorted(assets, key=lambda item: item[0])


def _format_ipk_version(ver_clean: str) -> str:
    """Format SemVer for opkg using `~` before prerelease tags so 2.0.0~beta.1-1 < 2.0.0-1."""
    base_only = ver_clean.split("+", 1)[0].strip()
    if "-" in base_only:
        base, pre = base_only.split("-", 1)
        if pre.strip():
            return f"{base}~{pre.strip()}-1"
    return f"{base_only}-1"


def _format_apk_version(ver_clean: str) -> str:
    """Format SemVer for apk-tools v2/v3 (`_alphaN`/`_betaN`/`_rcN`/`_preN-r1`)."""
    base_only = ver_clean.split("+", 1)[0].strip()
    if "-" not in base_only:
        return f"{base_only}-r1"
    base, pre = base_only.split("-", 1)
    m = re.fullmatch(r"(alpha|beta|pre|rc)[._-]?([0-9]+)?", pre.strip().lower())
    if m:
        kind, num = m.group(1), m.group(2) or "0"
        return f"{base}_{kind}{num}-r1"
    num_m = re.search(r"([0-9]+)", pre)
    num = num_m.group(1) if num_m else "0"
    return f"{base}_pre{num}-r1"


def build_ipk(
    out_path: str,
    ver_clean: str,
    arch_label: str,
    files: list[tuple[str, bytes, int]],
    dirs: list[str],
    installed_size: int,
    mtime: int,
) -> None:
    data_buf = io.BytesIO()
    with tarfile.open(fileobj=data_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for d in dirs:
            _add_ustar_dir(tf, f"./{d}", mtime)
        for rel_path, content, mode in files:
            _add_ustar_file(tf, f"./{rel_path}", content, mode, mtime)
    data_tar_gz = _gzip_bytes(data_buf.getvalue(), mtime)

    # No hard Depends so offline opkg install works immediately after reboot
    # when package lists in /tmp are absent or WAN is unreachable.
    control_text = (
        f"Package: tachyon\n"
        f"Version: {_format_ipk_version(ver_clean)}\n"
        f"Section: net\n"
        f"Category: Network\n"
        f"Maintainer: Dushnilin <dushnilin@gmail.com>\n"
        f"Architecture: all\n"
        f"Replaces: luci-app-tachyon, luci-i18n-tachyon-ru\n"
        f"Installed-Size: {installed_size}\n"
        f"Description: Pure-Rust routing orchestrator and web panel for OpenWrt ({arch_label})\n"
    ).encode("utf-8")
    preinst_bytes = PREINST_SCRIPT.replace("\r\n", "\n").encode("utf-8")
    postinst_bytes = POSTINST_SCRIPT.replace("\r\n", "\n").encode("utf-8")
    prerm_bytes = PRERM_SCRIPT.replace("\r\n", "\n").encode("utf-8")

    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for path, content, mode in (
            ("./control", control_text, 0o644),
            ("./preinst", preinst_bytes, 0o755),
            ("./postinst", postinst_bytes, 0o755),
            ("./prerm", prerm_bytes, 0o755),
        ):
            _add_ustar_file(tf, path, content, mode, mtime)
    control_tar_gz = _gzip_bytes(ctrl_buf.getvalue(), mtime)

    ipk_buf = io.BytesIO()
    with tarfile.open(fileobj=ipk_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for path, content in (
            ("./debian-binary", b"2.0\n"),
            ("./control.tar.gz", control_tar_gz),
            ("./data.tar.gz", data_tar_gz),
        ):
            _add_ustar_file(tf, path, content, 0o644, mtime)

    with open(out_path, "wb") as f:
        f.write(_gzip_bytes(ipk_buf.getvalue(), mtime))


def build_apk(
    out_path: str,
    ver_clean: str,
    arch_label: str,
    files: list[tuple[str, bytes, int]],
    dirs: list[str],
    installed_size: int,
    mtime: int,
) -> None:
    data_buf = io.BytesIO()
    with tarfile.open(fileobj=data_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for d in dirs:
            _add_apk_tar_entry(tf, d, None, 0o755, is_dir=True, mtime=mtime)
        for rel_path, content, mode in files:
            _add_apk_tar_entry(tf, rel_path, content, mode, is_dir=False, mtime=mtime)

    data_tar_gz = _gzip_bytes(data_buf.getvalue(), mtime)
    data_hash = hashlib.sha256(data_tar_gz).hexdigest()

    pkginfo = (
        f"# Generated by tachyon build_openwrt_pkg.py\n"
        f"pkgname = tachyon\n"
        f"pkgver = {_format_apk_version(ver_clean)}\n"
        f"pkgdesc = Pure-Rust routing orchestrator and web panel for OpenWrt ({arch_label})\n"
        f"url = https://github.com/Dushnilin/tachyon\n"
        f"builddate = {mtime}\n"
        f"packager = Dushnilin\n"
        f"size = {installed_size}\n"
        f"arch = noarch\n"
        f"license = GPL-2.0-only\n"
        f"replaces = luci-app-tachyon\n"
        f"replaces = luci-i18n-tachyon-ru\n"
        f"datahash = {data_hash}\n"
    ).encode("utf-8")
    preinst_bytes = PREINST_SCRIPT.replace("\r\n", "\n").encode("utf-8")
    postinst_bytes = POSTINST_SCRIPT.replace("\r\n", "\n").encode("utf-8")
    apk_prerm_bytes = APK_PRE_DEINSTALL_SCRIPT.replace("\r\n", "\n").encode("utf-8")

    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        _add_apk_tar_entry(tf, ".PKGINFO", pkginfo, 0o644, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".pre-install", preinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".pre-upgrade", preinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".post-install", postinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".post-upgrade", postinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".pre-deinstall", apk_prerm_bytes, 0o755, is_dir=False, mtime=mtime)

    ctrl_raw = _strip_tar_eof(ctrl_buf.getvalue())
    control_tar_gz = _gzip_bytes(ctrl_raw, mtime)

    with open(out_path, "wb") as f:
        f.write(control_tar_gz)
        f.write(data_tar_gz)


# ELF class, byte order and machine for the CPU families used by build.sh.
# ARMv6 and ARMv7 share the same ELF machine identifier; the Rust target triple
# preserves the distinction in the build contract.
ELF_TARGETS = {
    "x86_64": (2, 1, 62),
    "i386": (1, 1, 3),
    "aarch64": (2, 1, 183),
    "arm": (1, 1, 40),
    "armv7": (1, 1, 40),
    "armv6": (1, 1, 40),
    "riscv64": (2, 1, 243),
    "mipsel": (1, 1, 8),
    "mips": (1, 2, 8),
}

# Rust target triple architecture prefixes used by build.sh. Package labels may
# be custom, but the compiled target must always resolve to a known ELF family.
RUST_TARGET_FAMILIES = {
    "x86_64": "x86_64",
    "i686": "i386",
    "i386": "i386",
    "aarch64": "aarch64",
    "armv7": "armv7",
    "arm": "armv6",
    "riscv64gc": "riscv64",
    "riscv64": "riscv64",
    "mipsel": "mipsel",
    "mips": "mips",
}


def _package_arch_family(arch: str) -> str | None:
    for family in ELF_TARGETS:
        if arch == family or arch.startswith(f"{family}_"):
            return family
    return None


def _target_triple_family(target_triple: str) -> str:
    prefix = target_triple.strip().lower().split("-", 1)[0]
    family = RUST_TARGET_FAMILIES.get(prefix)
    if family is None:
        raise ValueError(f"Unsupported Rust target triple architecture: {target_triple}")
    return family



def _read_uleb128(data: bytes, offset: int, end: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < end and shift <= 63:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise ValueError("Malformed ARM attribute ULEB128")


def _read_arm_attributes(binary: bytes, byte_order: str) -> tuple[list[int], list[int]]:
    """Read CPU architecture and VFP calling-convention attributes from ELF32."""
    if len(binary) < 52 or binary[4] != 1:
        raise ValueError("ARM target must use ELF32")
    shoff = int.from_bytes(binary[32:36], byte_order)
    shentsize = int.from_bytes(binary[46:48], byte_order)
    shnum = int.from_bytes(binary[48:50], byte_order)
    shstrndx = int.from_bytes(binary[50:52], byte_order)
    if shoff == 0 or shentsize < 40 or shoff + 40 > len(binary):
        raise ValueError("ARM ELF section table is missing or malformed")

    def section(index: int) -> tuple[int, int, int, int]:
        start = shoff + index * shentsize
        if start + 40 > len(binary):
            raise ValueError("Truncated ARM ELF section header")
        name = int.from_bytes(binary[start:start + 4], byte_order)
        kind = int.from_bytes(binary[start + 4:start + 8], byte_order)
        offset = int.from_bytes(binary[start + 16:start + 20], byte_order)
        size = int.from_bytes(binary[start + 20:start + 24], byte_order)
        link = int.from_bytes(binary[start + 24:start + 28], byte_order)
        return name, kind, offset, size, link

    zero = section(0)
    if shnum == 0:
        shnum = zero[3]
    if shstrndx == 0xFFFF:
        shstrndx = zero[4]
    if shnum < 2 or shnum > 65536 or shstrndx >= shnum:
        raise ValueError("Invalid ARM ELF section indexes")
    _, shstr_type, shstr_off, shstr_size, _ = section(shstrndx)
    if shstr_type != 3 or shstr_off + shstr_size > len(binary):
        raise ValueError("Invalid ARM ELF section-name string table")
    names = binary[shstr_off:shstr_off + shstr_size]

    attributes = None
    for index in range(1, shnum):
        name_off, kind, offset, size, _ = section(index)
        if name_off >= len(names):
            raise ValueError("Invalid ARM ELF section name")
        name_end = names.find(b"\\0", name_off)
        if name_end < 0:
            raise ValueError("Unterminated ARM ELF section name")
        name = names[name_off:name_end]
        if name == b".ARM.attributes" or kind == 0x70000003:
            if name != b".ARM.attributes" or kind != 0x70000003:
                raise ValueError("Malformed ARM attributes section identity")
            if attributes is not None:
                raise ValueError("Duplicate ARM attributes sections")
            if offset + size > len(binary) or size == 0:
                raise ValueError("Truncated ARM attributes section")
            attributes = binary[offset:offset + size]
    if attributes is None:
        raise ValueError("ARM binary is missing .ARM.attributes")

    if attributes[0] != ord("A"):
        raise ValueError("Unsupported ARM attributes format")
    cpu_arch: list[int] = []
    vfp_args: list[int] = []
    cursor = 1
    known_numeric_tags = {1, 2, 3, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                          17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
                          30, 31, 34, 36, 38, 42, 44, 46, 48, 50, 52, 64, 66,
                          68, 70, 72, 74, 76}
    known_string_tags = {4, 5, 65, 67}

    def skip_string(data: bytes, pos: int, limit: int) -> int:
        end = data.find(b"\\0", pos, limit)
        if end < 0:
            raise ValueError("Unterminated ARM attribute string")
        return end + 1

    while cursor < len(attributes):
        vendor_start = cursor
        if cursor + 4 > len(attributes):
            raise ValueError("Truncated ARM attribute vendor header")
        vendor_size = int.from_bytes(attributes[cursor:cursor + 4], byte_order)
        vendor_end = vendor_start + vendor_size
        if vendor_size < 5 or vendor_end > len(attributes):
            raise ValueError("Invalid ARM attribute vendor length")
        vendor_name_start = cursor + 4
        vendor_name_end = attributes.find(b"\\0", vendor_name_start, vendor_end)
        if vendor_name_end < 0:
            raise ValueError("Unterminated ARM attribute vendor name")
        vendor = attributes[vendor_name_start:vendor_name_end]
        pos = vendor_name_end + 1
        if vendor == b"aeabi":
            while pos < vendor_end:
                sub_start = pos
                sub_tag, pos = _read_uleb128(attributes, pos, vendor_end)
                if pos + 4 > vendor_end:
                    raise ValueError("Truncated ARM attribute subsection")
                sub_size = int.from_bytes(attributes[pos:pos + 4], byte_order)
                sub_end = sub_start + sub_size
                if sub_size < pos + 4 - sub_start or sub_end > vendor_end:
                    raise ValueError("Invalid ARM attribute subsection length")
                attr_pos = pos + 4
                if sub_tag in (2, 3):
                    while attr_pos < sub_end:
                        index, attr_pos = _read_uleb128(attributes, attr_pos, sub_end)
                        if index == 0:
                            break
                    else:
                        raise ValueError("Unterminated ARM section/symbol attribute indexes")
                elif sub_tag != 1:
                    raise ValueError(f"Unknown ARM attribute subsection tag: {sub_tag}")

                while attr_pos < sub_end:
                    tag, attr_pos = _read_uleb128(attributes, attr_pos, sub_end)
                    if tag in (4, 5, 65, 67):
                        attr_pos = skip_string(attributes, attr_pos, sub_end)
                    elif tag == 32:
                        _, attr_pos = _read_uleb128(attributes, attr_pos, sub_end)
                        attr_pos = skip_string(attributes, attr_pos, sub_end)
                    elif tag in known_numeric_tags:
                        value, attr_pos = _read_uleb128(attributes, attr_pos, sub_end)
                        if tag == 6:
                            cpu_arch.append(value)
                        elif tag == 28:
                            vfp_args.append(value)
                    elif tag >= 128:
                        if tag % 128 % 2 == 0:
                            _, attr_pos = _read_uleb128(attributes, attr_pos, sub_end)
                        else:
                            attr_pos = skip_string(attributes, attr_pos, sub_end)
                    else:
                        raise ValueError(f"Unknown mandatory ARM attribute tag: {tag}")
                pos = sub_end
        cursor = vendor_end

    return cpu_arch, vfp_args


def validate_arm_abi(binary: bytes, target_family: str, byte_order: str) -> None:
    flags = int.from_bytes(binary[36:40], byte_order)
    if flags & 0xFF000000 != 0x05000000:
        raise ValueError("ARM binary must use EABI version 5")
    float_abi = flags & 0x600
    if target_family == "armv7":
        if float_abi != 0x400:
            raise ValueError("ARMv7 target requires the hard-float ELF ABI")
        expected_arch = 10
        allowed_vfp_args = {1, 3}
    else:
        if float_abi == 0x400 or float_abi == 0x600:
            raise ValueError("ARMv6 target requires the base/soft-float ELF ABI")
        expected_arch = 6
        allowed_vfp_args = {0, 3}

    cpu_arch, vfp_args = _read_arm_attributes(binary, byte_order)
    if not cpu_arch:
        raise ValueError("ARM binary has no file/section CPU architecture attribute")
    if max(cpu_arch) > expected_arch:
        raise ValueError(
            f"ARM CPU architecture attribute {max(cpu_arch)} exceeds {target_family} target"
        )
    effective_vfp_args = vfp_args or [0]
    if any(value not in allowed_vfp_args for value in effective_vfp_args):
        raise ValueError(
            f"ARM VFP argument ABI {effective_vfp_args} does not match {target_family} target"
        )


def validate_binary_arch(
    binary: bytes, arch: str, target_triple: str | None = None
) -> None:
    if len(binary) < 16 or binary[:4] != b"\x7fELF":
        raise ValueError("Tachyon binary is not ELF")
    elf_class, endian, ident_version = binary[4:7]
    if elf_class not in (1, 2) or endian not in (1, 2) or ident_version != 1:
        raise ValueError("Invalid ELF identification")
    header_size = 52 if elf_class == 1 else 64
    if len(binary) < header_size:
        raise ValueError("Truncated ELF header")
    order = "little" if endian == 1 else "big"
    kind = int.from_bytes(binary[16:18], order)
    machine = int.from_bytes(binary[18:20], order)
    version = int.from_bytes(binary[20:24], order)
    if kind not in (2, 3) or version != 1:
        raise ValueError("Expected an executable ELF binary")

    package_family = _package_arch_family(arch)
    if target_triple:
        target_family = _target_triple_family(target_triple)
        if package_family is not None and package_family != target_family:
            raise ValueError(
                f"Package architecture {arch} does not match Rust target triple {target_triple}"
            )
        expected_family = target_family
    else:
        if package_family is None:
            raise ValueError(
                f"Unknown package architecture {arch}; pass --target-triple to validate the build target"
            )
        expected_family = package_family

    expected = ELF_TARGETS[expected_family]
    if expected_family in ("armv6", "armv7"):
        validate_arm_abi(binary, expected_family, order)
    if (elf_class, endian, machine) != expected:
        raise ValueError(
            f"ELF architecture does not match release target {arch}"
            + (f" ({target_triple})" if target_triple else "")
        )

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True, help="Path to compiled tachyon binary")
    ap.add_argument("--arch", required=True, help="Architecture name (e.g. aarch64, x86_64)")
    ap.add_argument("--target-triple", default="", help="Rust target triple used to build the binary")
    ap.add_argument("--version", required=True, help="Version tag (e.g. v2.0.0 or 2.0.0)")
    ap.add_argument("--init", default="openwrt/tachyon.init", help="Path to tachyon procd init script")
    ap.add_argument("--hotplug", default="", help="Path to 99-tachyon-wan-monitor hotplug script")
    ap.add_argument("--po", default="", help="Optional path to Russian .po dictionary (unused when i18n_ru.js is precompiled)")
    ap.add_argument(
        "--views-dir",
        default="luci-app-tachyon/htdocs/luci-static/resources/view/tachyon",
        help="Path to compiled LuCI JS views directory",
    )
    ap.add_argument("--launcher-js", default="openwrt/launcher.js", help="Path to LuCI launcher JS view")
    ap.add_argument(
        "--launcher-menu",
        default="openwrt/tachyon-launcher.menu.json",
        help="Path to LuCI menu JSON definition",
    )
    ap.add_argument(
        "--launcher-acl",
        default="openwrt/tachyon-launcher.acl.json",
        help="Path to rpcd ACL JSON definition",
    )
    ap.add_argument("--out-ipk", required=True, help="Output .ipk path")
    ap.add_argument("--out-apk", required=True, help="Output .apk path")
    args = ap.parse_args()

    ver_clean = args.version.lstrip("vV")
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", int(time.time())))

    with open(args.bin, "rb") as f:
        bin_bytes = f.read()
    try:
        validate_binary_arch(bin_bytes, args.arch, args.target_triple or None)
    except ValueError as exc:
        ap.error(str(exc))
    with open(args.init, "rb") as f:
        init_bytes = f.read().replace(b"\r\n", b"\n")

    dirs = [
        "lib",
        "lib/upgrade",
        "lib/upgrade/keep.d",
        "usr",
        "usr/bin",
        "usr/share",
        "usr/share/tachyon",
        "usr/share/luci",
        "usr/share/luci/menu.d",
        "usr/share/rpcd",
        "usr/share/rpcd/acl.d",
        "etc",
        "etc/init.d",
        "etc/hotplug.d",
        "etc/hotplug.d/iface",
        "www",
        "www/cgi-bin",
        "www/luci-static",
        "www/luci-static/resources",
        "www/luci-static/resources/view",
        "www/luci-static/resources/view/tachyon",
    ]
    def _ensure_dir(dpath: str) -> None:
        cur = ""
        for part in dpath.strip("/").split("/"):
            cur = f"{cur}/{part}" if cur else part
            if cur not in dirs:
                dirs.append(cur)

    files: list[tuple[str, bytes, int]] = [
        ("lib/upgrade/keep.d/tachyon", SYSUPGRADE_KEEP_FILE.encode("utf-8"), 0o644),
        ("usr/bin/tachyon", bin_bytes, 0o755),
        ("etc/init.d/tachyon", init_bytes, 0o755),
        ("www/cgi-bin/tachyon-sub", CGI_SUB_SCRIPT.replace("\r\n", "\n").encode("utf-8"), 0o755),
    ]
    hotplug_path = args.hotplug or os.path.join(os.path.dirname(os.path.abspath(args.init)), "99-tachyon-wan-monitor")
    if hotplug_path and os.path.isfile(hotplug_path):
        with open(hotplug_path, "rb") as f:
            files.append(("etc/hotplug.d/iface/99-tachyon-wan-monitor", f.read().replace(b"\r\n", b"\n"), 0o755))

    if args.po and os.path.isfile(args.po):
        with open(args.po, "rb") as f:
            files.append(("usr/share/tachyon/tachyon.ru.po", f.read().replace(b"\r\n", b"\n"), 0o644))

    has_launcher_js = False
    if args.launcher_js and os.path.isfile(args.launcher_js):
        with open(args.launcher_js, "rb") as f:
            files.append(
                ("www/luci-static/resources/view/tachyon/launcher.js", f.read().replace(b"\r\n", b"\n"), 0o644)
            )
        has_launcher_js = True

    if args.launcher_menu and os.path.isfile(args.launcher_menu):
        with open(args.launcher_menu, "rb") as f:
            files.append(
                ("usr/share/luci/menu.d/tachyon-launcher.json", f.read().replace(b"\r\n", b"\n"), 0o644)
            )

    if args.launcher_acl and os.path.isfile(args.launcher_acl):
        with open(args.launcher_acl, "rb") as f:
            files.append(
                ("usr/share/rpcd/acl.d/tachyon-launcher.json", f.read().replace(b"\r\n", b"\n"), 0o644)
            )

    for name, content in _collect_view_assets(args.views_dir):
        if has_launcher_js and name == "launcher.js":
            continue
        rel_target = f"www/luci-static/resources/view/tachyon/{name}"
        parent_rel = os.path.dirname(rel_target).replace(os.sep, "/")
        if parent_rel:
            _ensure_dir(parent_rel)
        files.append((rel_target, content, 0o644))

    installed_size = sum(len(content) for _, content, _ in files)

    for p in (args.out_ipk, args.out_apk):
        parent = os.path.dirname(os.path.abspath(p))
        if parent:
            os.makedirs(parent, exist_ok=True)

    build_ipk(args.out_ipk, ver_clean, args.arch, files, dirs, installed_size, mtime)
    build_apk(args.out_apk, ver_clean, args.arch, files, dirs, installed_size, mtime)
    print(
        f"Built {args.out_ipk} ({os.path.getsize(args.out_ipk)} bytes), "
        f"{args.out_apk} ({os.path.getsize(args.out_apk)} bytes)"
    )


if __name__ == "__main__":
    main()
