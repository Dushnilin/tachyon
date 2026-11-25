#!/bin/sh
# shellcheck shell=dash
# Keenetic NDM fs.d USB safety hook: stops Tachyon before the partition hosting
# /opt is unmounted so iptables rules, ip rules, and DNS redirection are cleanly
# restored prior to USB detachment.

set -u

_chg="${change:-${action:-${1:-}}}"
case "$_chg" in
    umount|stop|unmount|remove) ;;
    *) exit 0 ;;
esac

TACHYON_ROOT="${TACHYON_ROOT:-/opt}"
INIT_SCRIPT="${TACHYON_ROOT}/etc/init.d/S99tachyon"

[ -x "$INIT_SCRIPT" ] || exit 0

_mount_device_for_path() {
    _tgt="$1"
    [ -r /proc/mounts ] || return 1
    awk -v tgt="$_tgt" '
        {
            dev = $1
            mp = $2
            if (mp == "/" || mp == tgt || index(tgt, mp "/") == 1) {
                if (length(mp) >= best_len) {
                    best_len = length(mp)
                    best_dev = dev
                }
            }
        }
        END {
            if (best_dev != "") print best_dev
        }
    ' /proc/mounts 2>/dev/null
}

_should_stop=0
_mp="${mountpoint:-}"
_dev="${device:-}"

if [ -z "$_mp" ] && [ -z "$_dev" ]; then
    # Global filesystem stop without a specific mountpoint: always stop safely.
    _should_stop=1
else
    _opt_dev="$(_mount_device_for_path "$TACHYON_ROOT" || true)"
    if [ -n "$_mp" ]; then
        case "$TACHYON_ROOT" in
            "$_mp"|"$_mp"/*) _should_stop=1 ;;
        esac
        if [ "$_should_stop" -eq 0 ] && [ -n "$_opt_dev" ]; then
            _mp_dev="$(_mount_device_for_path "$_mp" || true)"
            if [ -n "$_mp_dev" ] && [ "$_mp_dev" = "$_opt_dev" ]; then
                _should_stop=1
            fi
        fi
    fi
    if [ "$_should_stop" -eq 0 ] && [ -n "$_dev" ] && [ -n "$_opt_dev" ]; then
        if [ "$_dev" = "$_opt_dev" ] || [ "/dev/${_dev}" = "$_opt_dev" ]; then
            _should_stop=1
        fi
    fi
    if [ "$_should_stop" -eq 0 ] && [ -z "$_opt_dev" ]; then
        # Cannot determine backing device reliably: err on the side of safety.
        _should_stop=1
    fi
fi

[ "$_should_stop" -eq 1 ] || exit 0

PATH="${TACHYON_ROOT}/sbin:${TACHYON_ROOT}/bin:/opt/sbin:/opt/bin:${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH TACHYON_ROOT

"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
exit 0
