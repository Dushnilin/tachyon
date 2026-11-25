#!/bin/sh
# shellcheck shell=dash
# Keenetic NDM netfilter.d hook: re-applies Tachyon iptables/ipset/policy rules
# after firmware netfilter reloads.

set -u

[ "${type:-}" = "iptables" ] || [ "${type:-}" = "ip6tables" ] || exit 0

TACHYON_ROOT="${TACHYON_ROOT:-/opt}"
TACHYON_DATA_DIR="${TACHYON_DATA_DIR:-${TACHYON_ROOT}/etc/tachyon}"
PROG="${TACHYON_ROOT}/bin/tachyon"
RUN_DIR="/tmp/tachyon-rs"
LOCK_DIR="${RUN_DIR}/ndm-netfilter.lock"
PENDING_FLAG="${RUN_DIR}/ndm-netfilter.pending"

[ -x "$PROG" ] || exit 0
[ -e "${RUN_DIR}/manual_stop" ] || [ -e /var/run/tachyon/manual_stop ] && exit 0

_daemon_running() {
    for _pf in "${RUN_DIR}/tachyon.pid" "${RUN_DIR}/daemon.pid" /var/run/tachyon/daemon.pid /var/run/tachyon/tachyon.pid; do
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
        # Record pending request so table updates (mangle/nat arriving after raw/filter) are reconciled
        : >"$PENDING_FLAG" 2>/dev/null || true
        exit 0
    fi
fi

date +%s >"${LOCK_DIR}/ts" 2>/dev/null || true
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

PATH="${TACHYON_ROOT}/sbin:${TACHYON_ROOT}/bin:/opt/sbin:/opt/bin:${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH TACHYON_ROOT TACHYON_DATA_DIR

"$PROG" reconcile-net >/dev/null 2>&1 || true

# Run one follow-up pass if NDMS invoked subsequent tables while lock was held
_pass=0
while [ -f "$PENDING_FLAG" ] && [ "$_pass" -lt 2 ]; do
    rm -f "$PENDING_FLAG" 2>/dev/null || true
    sleep 1
    "$PROG" reconcile-net >/dev/null 2>&1 || true
    _pass=$((_pass + 1))
done

rm -rf "$LOCK_DIR" 2>/dev/null || true
trap - EXIT INT TERM
exit 0
