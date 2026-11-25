#!/bin/sh
# shellcheck shell=dash
# Keenetic NDM ifstatechanged.d hook: triggers debounced Tachyon reload on WAN/interface changes.

set -u

[ "${change:-}" = "link" ] || [ "${change:-}" = "ip" ] || [ "${change:-}" = "connected" ] || exit 0

# Ignore loopback and Tachyon's own TUN interface to prevent reload feedback loops.
case "${system_name:-${id:-}}" in
    lo|tun*|tachyon*) exit 0 ;;
esac

TACHYON_ROOT="${TACHYON_ROOT:-/opt}"
TACHYON_DATA_DIR="${TACHYON_DATA_DIR:-${TACHYON_ROOT}/etc/tachyon}"
PROG="${TACHYON_ROOT}/bin/tachyon"
RUN_DIR="/tmp/tachyon-rs"
LOCK_DIR="${RUN_DIR}/ndm-ifstate.lock"

[ -x "$PROG" ] || exit 0
[ -e "${RUN_DIR}/manual_stop" ] || [ -e /var/run/tachyon/manual_stop ] && exit 0

_daemon_running() {
    for _pf in "${RUN_DIR}/tachyon.pid" "${RUN_DIR}/daemon.pid" /var/run/tachyon/daemon.pid; do
        [ -r "$_pf" ] || continue
        _p="$(head -n 1 "$_pf" 2>/dev/null | tr -d ' \t\r\n')"
        case "$_p" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ -d "/proc/${_p}" ]; then
            return 0
        fi
    done
    return 1
}

_daemon_running || exit 0

mkdir -p "$RUN_DIR" 2>/dev/null || exit 0

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _now="$(date +%s 2>/dev/null || echo 0)"
    _ts="$(cat "${LOCK_DIR}/ts" 2>/dev/null || echo 0)"
    case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
    if [ "$_now" -gt 0 ] && [ "$_ts" -gt 0 ] && [ $((_now - _ts)) -ge 15 ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi

date +%s >"${LOCK_DIR}/ts" 2>/dev/null || true

(
    sleep 2
    PATH="${TACHYON_ROOT}/sbin:${TACHYON_ROOT}/bin:/opt/sbin:/opt/bin:${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"
    export PATH TACHYON_ROOT TACHYON_DATA_DIR
    if [ ! -e "${RUN_DIR}/manual_stop" ] && [ ! -e /var/run/tachyon/manual_stop ] && _daemon_running; then
        TACHYON_RELOAD_REASON="ndm_ifstate_${change:-event}" "$PROG" reload >/dev/null 2>&1 || true
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
) >/dev/null 2>&1 &

exit 0
