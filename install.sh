#!/bin/sh
# shellcheck shell=dash

INSTALLER_VERSION="3.4.0"
REPO_OWNER="Dushnilin"
REPO_NAME="tachyon"

CONNECT_TIMEOUT_SECONDS=15
METADATA_TIMEOUT_SECONDS=60
DOWNLOAD_TIMEOUT_SECONDS=600
PACKAGE_TIMEOUT_SECONDS=420
APK_LOCK_WAIT_SECONDS=120
REQUIRED_OVERLAY_KB=12288
MIN_TMP_HEADROOM_KB=8192

LOG_FILE="/tmp/tachyon-install.log"
LOCK_DIR="/tmp/tachyon.install.lock.d"
TMP_DIR=""
SNAPSHOT_DIR=""
FETCHER=""
INSTALLER_USER_AGENT="Tachyon-Installer/1.0"
GH_MIRRORS="https://ghfast.top/ https://gh-proxy.com/ https://gh-proxy.org/ https://gh.nxnow.top/ https://ghproxy.net/ https://edgeone.gh-proxy.org/"
_WORKING_GH_MIRROR=""
_DIRECT_FAILED=0
_WGET_SUPPORTS_IPV4=""
PROXY_URL_REQUESTED="${TACHYON_PROXY:-}"
CUSTOM_MIRROR="${TACHYON_MIRROR:-}"
PKG_MANAGER=""
PKG_IS_APK=0
# Indirected so the rollback contract can be tested without touching a real
# package manager state file.
APK_WORLD_FILE="${TACHYON_APK_WORLD_FILE:-/etc/apk/world}"
APK_INSTALLED_DB="${TACHYON_APK_INSTALLED_DB:-/lib/apk/db/installed}"
APK_REPOS_FILE="${TACHYON_APK_REPOS_FILE:-/etc/apk/repositories}"
APK_REPOS_DIR="${TACHYON_APK_REPOS_DIR:-/etc/apk/repositories.d}"
APK_REPO_PROBE_TIMEOUT_SECONDS="${TACHYON_APK_REPO_PROBE_TIMEOUT_SECONDS:-5}"
APK_FILTERED_REPOS_FILE=""
APK_REPOS_PREPARED=0
PACKAGE_INDEX_UPDATED=0
START_TIME="0"
TX_ACTIVE=0
TX_COMMITTED=0
TACHYON_WAS_INSTALLED=0
TACHYON_WAS_RUNNING=0
TACHYON_WAS_ENABLED=0
INSTALLER_LANG="en"
TACHYON_I18N_REQUESTED=0
WORLD_SCRUB_PACKAGES="tachyon luci-app-tachyon"
CORE_INSTALL_CHOICE=""
CORE_INSTALL_REQUESTED=""
ENGINE_INSTALL_CHOICE=""
ENGINE_INSTALL_REQUESTED=""
SING_BOX_INSTALL_VARIANT=""
SING_BOX_VARIANT_REQUESTED=""
ZRAM_INSTALL_REQUESTED=0

ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
QUIET=0
SKIP_ENGINE=0
ZRAM_INSTALL_OVERRIDE=""
REPAIR_MODE=0
REINSTALL_MODE=0
RELEASE_TAG_REQUESTED=""
RELEASE_CHANNEL="stable"
TACHYON_RELEASE_JSON=""
TACHYON_RELEASE_TAG=""
TACHYON_BACKEND_URL=""
TACHYON_BACKEND_NAME=""
TACHYON_BACKEND_FILE=""
TACHYON_APP_URL=""
TACHYON_APP_NAME=""
TACHYON_APP_FILE=""
TACHYON_I18N_URL=""
TACHYON_I18N_NAME=""
TACHYON_I18N_FILE=""
TACHYON_SHA256_URL=""
TACHYON_SHA256_FILE=""
TACHYON_DOWNLOAD_BYTES=0

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

if [ -d /opt/bin ] || [ -d /opt/sbin ]; then
    case ":${PATH:-}:" in
        *:/opt/bin:*) ;;
        *) PATH="${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}:/opt/sbin:/opt/bin"; export PATH ;;
    esac
fi

ESC="$(printf '\033')"
if [ -t 1 ] 2>/dev/null && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RESET="${ESC}[0m"; C_BOLD="${ESC}[1m"; C_RED="${ESC}[31;1m"
    C_GREEN="${ESC}[32;1m"; C_YELLOW="${ESC}[33;1m"; C_CYAN="${ESC}[36;1m"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

INSTALL_START_TS="$(date +%s 2>/dev/null || echo 0)"

ts_elapsed() {
    _now="$(date +%s 2>/dev/null || echo "$INSTALL_START_TS")"
    _el=$((_now - INSTALL_START_TS))
    [ "$_el" -ge 0 ] 2>/dev/null || _el=0
    printf '+%02d:%02d' $((_el / 60)) $((_el % 60))
}

log_line() {
    printf '[%s +%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-------------------')" "$(ts_elapsed)" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

msg() {
    log_line "INFO  $1"
    [ "$QUIET" -eq 1 ] || printf '  [%s] %s%s%s\n' "$(ts_elapsed)" "$C_CYAN" "$1" "$C_RESET"
}

ok() {
    log_line "OK    $1"
    [ "$QUIET" -eq 1 ] || printf '  [%s] %s%s✓%s %s\n' "$(ts_elapsed)" "$C_GREEN" "$C_BOLD" "$C_RESET" "$1"
}

warn() {
    log_line "WARN  $1"
    printf '  [%s] %s%s⚠%s %s\n' "$(ts_elapsed)" "$C_YELLOW" "$C_BOLD" "$C_RESET" "$1" >&2
}

err() {
    log_line "ERROR $1"
    printf '  [%s] %s%s✗%s %s\n' "$(ts_elapsed)" "$C_RED" "$C_BOLD" "$C_RESET" "$1" >&2
}

debug() {
    log_line "DEBUG $1"
    [ "$VERBOSE" -eq 1 ] && printf '  [%s] [debug] %s\n' "$(ts_elapsed)" "$1" >&2 || true
}

usage() {
    cat <<EOF_USAGE
Tachyon installer v${INSTALLER_VERSION}

Usage: $0 [options]

  -y, --yes             Use recommended defaults without prompts
  -n, --dry-run         Resolve and validate the plan without changing the router
  -v, --verbose         Print diagnostics
  -q, --quiet           Suppress informational output
      --repair          Reinstall Tachyon and repair runtime integration
      --reinstall       Force reinstall of the selected release
      --tag X.Y.Z            Install an exact published release
      --channel NAME         stable (default) or beta
      --proxy URL            Use HTTP/HTTPS/SOCKS5 proxy for downloads
      --mirror URL           Try custom GitHub mirror prefix first
      --tachyon-core         Install tachyon-core routing core
      --skip-engine          Do not install a routing core when none is present
      --zram                 Install zram-swap
      --no-zram              Never install zram-swap
      --version              Print installer version
  -h, --help                 Show this help

Log: $LOG_FILE
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -q|--quiet) QUIET=1 ;;
            --repair) REPAIR_MODE=1; REINSTALL_MODE=1 ;;
            --reinstall) REINSTALL_MODE=1 ;;
            --engine)
                shift
                [ "$#" -gt 0 ] || { err "--engine requires name (tachyon-core, sing-box, none)"; return 2; }
                case "$1" in
                    tachyon-core|tachyon_core)
                        CORE_INSTALL_REQUESTED="tachyon-core"
                        ENGINE_INSTALL_REQUESTED="tachyon-core"
                        SING_BOX_VARIANT_REQUESTED="tachyon-core"
                        ;;
                    sing-box)
                        ENGINE_INSTALL_REQUESTED="sing-box"
                        ;;
                    none|skip) SKIP_ENGINE=1 ;;
                    *) err "Unsupported engine: $1 (allowed: tachyon-core, sing-box, none)"; return 2 ;;
                esac
                ;;
            --tachyon-core)
                CORE_INSTALL_REQUESTED="tachyon-core"
                ENGINE_INSTALL_REQUESTED="tachyon-core"
                SING_BOX_VARIANT_REQUESTED="tachyon-core"
                ;;
            --sing-box-variant)
                shift
                [ "$#" -gt 0 ] || { err "--sing-box-variant requires variant name"; return 2; }
                case "$1" in
                    stable|tiny|extended|extended-compressed|lx)
                        ENGINE_INSTALL_REQUESTED="sing-box"
                        SING_BOX_VARIANT_REQUESTED="$1"
                        ;;
                    tachyon-core|tachyon_core)
                        CORE_INSTALL_REQUESTED="tachyon-core"
                        ENGINE_INSTALL_REQUESTED="tachyon-core"
                        SING_BOX_VARIANT_REQUESTED="tachyon-core"
                        ;;
                    *) err "Unsupported variant: $1"; return 2 ;;
                esac
                ;;
            --skip-engine|--skip-sing-box|--no-sing-box) SKIP_ENGINE=1 ;;
            --zram) ZRAM_INSTALL_OVERRIDE="yes" ;;
            --no-zram) ZRAM_INSTALL_OVERRIDE="no" ;;
            --tag)
                shift
                [ "$#" -gt 0 ] || { err "--tag requires X.Y.Z"; return 2; }
                RELEASE_TAG_REQUESTED="$1"
                ;;
            --channel)
                shift
                [ "$#" -gt 0 ] || { err "--channel requires stable or beta"; return 2; }
                RELEASE_CHANNEL="$1"
                case "$RELEASE_CHANNEL" in stable|beta) ;; *) err "Unsupported channel: $RELEASE_CHANNEL"; return 2 ;; esac
                ;;
            --proxy)
                shift
                [ "$#" -gt 0 ] && [ -n "$1" ] || { err "--proxy requires a URL"; return 2; }
                PROXY_URL_REQUESTED="$1"
                ;;
            --mirror)
                shift
                [ "$#" -gt 0 ] && [ -n "$1" ] || { err "--mirror requires a URL"; return 2; }
                CUSTOM_MIRROR="$1"
                ;;
            --version) printf 'tachyon-installer %s\n' "$INSTALLER_VERSION"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) err "Unknown option: $1"; return 2 ;;
        esac
        shift
    done
    if [ "$VERBOSE" -eq 1 ] && [ "$QUIET" -eq 1 ]; then
        err "--verbose and --quiet cannot be used together"
        return 2
    fi
    if [ -n "$RELEASE_TAG_REQUESTED" ]; then
        if ! printf '%s' "$RELEASE_TAG_REQUESTED" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z._-]*)?$'; then
            err "Invalid --tag value: $RELEASE_TAG_REQUESTED"
            return 2
        fi
    fi
    [ -n "$CUSTOM_MIRROR" ] && CUSTOM_MIRROR="$(_normalize_mirror_prefix "$CUSTOM_MIRROR")"
    return 0
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

read_openwrt_release_value() {
    key="$1"
    [ -r /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

check_root() {
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || { err "Run the installer as root"; return 1; }
}

init_tmp_dir() {
    TMP_DIR="$(mktemp -d /tmp/tachyon-installer.XXXXXX 2>/dev/null || true)"
    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="/tmp/tachyon-installer.$$"
        mkdir -p "$TMP_DIR" || return 1
    fi
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        return 0
    fi
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        err "Another Tachyon installer is running (pid $old_pid)"
        return 1
    fi
    warn "Removing stale installer lock"
    rm -rf "$LOCK_DIR" 2>/dev/null || return 1
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
}

release_lock() {
    [ -d "$LOCK_DIR" ] || return 0
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ "$lock_pid" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null || true
}

kill_tree() {
    _pid="$1"
    [ -n "$_pid" ] || return 0
    children_file="/proc/$_pid/task/$_pid/children"
    if [ -r "$children_file" ]; then
        for _child in $(cat "$children_file" 2>/dev/null); do
            kill_tree "$_child"
        done
    fi
    kill -TERM "$_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$_pid" 2>/dev/null || true
}

run_with_deadline() {
    _seconds="$1"
    shift
    "$@" &
    _cmd_pid=$!
    (
        sleep "$_seconds"
        kill_tree "$_cmd_pid"
    ) >/dev/null 2>&1 &
    _watch_pid=$!
    wait "$_cmd_pid"
    _rc=$?
    kill "$_watch_pid" 2>/dev/null || true
    wait "$_watch_pid" 2>/dev/null || true
    return "$_rc"
}

# Live console streaming of captured command output: LOG_FILE still gets the
# full replay after the command, the console sees each line as it arrives
# instead of staying silent for the whole deadline window.
_NL='
'

_format_console_stream_line() {
    _fcl="$1"
    case "$_fcl" in
        '{'*'"kind"'*'"component"'*|'{'*'"release_notes"'*)
            _fcl_msg="$(printf '%s\n' "$_fcl" | sed -n 's/.*"message":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
            [ -n "$_fcl_msg" ] || _fcl_msg="$(printf '%s\n' "$_fcl" | sed -n 's/.*"error":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
            _fcl_ver="$(printf '%s\n' "$_fcl" | sed -n 's/.*"current_version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
            if [ -n "$_fcl_msg" ]; then
                if [ -n "$_fcl_ver" ] && [ "$_fcl_ver" != "not installed" ] && [ "$_fcl_ver" != "unknown" ]; then
                    printf '%s (%s)' "$_fcl_msg" "$_fcl_ver"
                else
                    printf '%s' "$_fcl_msg"
                fi
                return 0
            fi
            ;;
    esac
    printf '%s' "$_fcl"
}

_stream_poll() {
    _sf="$1"
    _ssize="$(wc -c <"$_sf" 2>/dev/null)" || _ssize=0
    case "$_ssize" in ''|*[!0-9]*) _ssize=0 ;; esac
    [ "$_ssize" -gt "$_spos" ] 2>/dev/null || return 0
    _sbuf="$_sbuf$(tail -c +$((_spos + 1)) "$_sf" 2>/dev/null)"
    _spos="$_ssize"
    while :; do
        case "$_sbuf" in
            *"$_NL"*) ;;
            *) break ;;
        esac
        _sline="${_sbuf%%"$_NL"*}"
        _sbuf="${_sbuf#*"$_NL"}"
        if [ "$QUIET" -ne 1 ]; then
            _sdisp="$(_format_console_stream_line "$_sline")"
            printf '  [%s] [%s] %s\n' "$(ts_elapsed)" "$_stag" "$_sdisp"
        fi
    done
    return 0
}

stream_console_lines() {
    _sf="$1"; _stag="$2"; _sstop="$3"; _SPARENT="${4:-}"
    _spos=0
    _sbuf=""
    _sidle=0
    while :; do
        [ -e "$_sstop" ] && break
        if [ -n "$_SPARENT" ]; then
            kill -0 "$_SPARENT" 2>/dev/null || break
        fi
        _spre="$_spos"
        _stream_poll "$_sf"
        if [ "$_spos" -eq "$_spre" ]; then
            _sidle=$((_sidle + 1))
            if [ "$_sidle" -ge 10 ] && [ $((_sidle % 10)) -eq 0 ] && [ "$QUIET" -ne 1 ]; then
                printf '  [%s] [%s] … still running (%ss)\n' "$(ts_elapsed)" "$_stag" "$_sidle"
            fi
        else
            _sidle=0
        fi
        sleep 1
    done
    _stream_poll "$_sf"
    if [ -n "$_sbuf" ] && [ "$QUIET" -ne 1 ]; then
        _sdisp="$(_format_console_stream_line "$_sbuf")"
        printf '  [%s] [%s] %s\n' "$(ts_elapsed)" "$_stag" "$_sdisp"
    fi
    return 0
}

start_console_stream() {
    _STREAM_STOP="$1.stf"
    rm -f "$_STREAM_STOP"
    stream_console_lines "$1" "$2" "$_STREAM_STOP" "$$" &
    _STREAM_PID=$!
}

stop_console_stream() {
    [ -n "${_STREAM_PID:-}" ] || return 0
    : >"$_STREAM_STOP" 2>/dev/null || true
    wait "$_STREAM_PID" 2>/dev/null || true
    _STREAM_PID=""
    rm -f "$_STREAM_STOP" 2>/dev/null || true
    return 0
}

run_logged() {
    _tag="$1"; shift
    _out="$TMP_DIR/cmd.$.log"
    log_line "EXEC  [$_tag] $*"
    : >"$_out"
    start_console_stream "$_out" "$_tag"
    "$@" >"$_out" 2>&1
    _rc=$?
    stop_console_stream
    if [ -s "$_out" ]; then
        while IFS= read -r _line; do log_line "  [$_tag] $_line"; done <"$_out"
    fi
    if [ "$_rc" -ne 0 ] && [ "$VERBOSE" -eq 1 ]; then cat "$_out" >&2; fi
    rm -f "$_out"
    return "$_rc"
}

run_logged_timeout() {
    _tag="$1"; _seconds="$2"; shift 2
    _out="$TMP_DIR/cmd.$.log"
    log_line "EXEC  [$_tag] (deadline ${_seconds}s) $*"
    : >"$_out"
    start_console_stream "$_out" "$_tag"
    run_with_deadline "$_seconds" "$@" >"$_out" 2>&1
    _rc=$?
    stop_console_stream
    if [ -s "$_out" ]; then
        while IFS= read -r _line; do log_line "  [$_tag] $_line"; done <"$_out"
    fi
    if [ "$_rc" -ne 0 ] && [ "$VERBOSE" -eq 1 ]; then cat "$_out" >&2; fi
    rm -f "$_out"
    return "$_rc"
}

detect_fetcher() {
    if command_exists curl; then FETCHER="curl"; return 0; fi
    if command_exists wget; then FETCHER="wget"; return 0; fi
    err "wget or curl is required"
    return 1
}

curl_supports_doh() {
    curl --help all 2>/dev/null | grep -q -- '--doh-url' && return 0
    curl --help 2>/dev/null | grep -q -- '--doh-url' && return 0
    return 1
}

_curl_is_network_retryable_rc() {
    case "$1" in
        6|7|28|35|52|56|60) return 0 ;;
        *) return 1 ;;
    esac
}

_resolve_effective_proxy() {
    if [ -n "${PROXY_URL_REQUESTED:-}" ]; then
        printf '%s' "$PROXY_URL_REQUESTED"
    elif [ -n "${TACHYON_PROXY:-}" ]; then
        printf '%s' "$TACHYON_PROXY"
    elif [ -n "${HTTPS_PROXY:-}" ]; then
        printf '%s' "$HTTPS_PROXY"
    elif [ -n "${https_proxy:-}" ]; then
        printf '%s' "$https_proxy"
    elif [ -n "${ALL_PROXY:-}" ]; then
        printf '%s' "$ALL_PROXY"
    elif [ -n "${all_proxy:-}" ]; then
        printf '%s' "$all_proxy"
    elif [ -n "${HTTP_PROXY:-}" ]; then
        printf '%s' "$HTTP_PROXY"
    elif [ -n "${http_proxy:-}" ]; then
        printf '%s' "$http_proxy"
    fi
}

_curl_proxy_url() {
    _cpu_raw="$1"
    case "$_cpu_raw" in
        socks5://*) printf 'socks5h://%s' "${_cpu_raw#socks5://}" ;;
        socks4://*) printf 'socks4a://%s' "${_cpu_raw#socks4://}" ;;
        *) printf '%s' "$_cpu_raw" ;;
    esac
}

_export_proxy_env() {
    _epe_raw="${PROXY_URL_REQUESTED:-${TACHYON_PROXY:-}}"
    [ -n "$_epe_raw" ] || return 0
    _epe_norm="$(_curl_proxy_url "$_epe_raw")"
    ALL_PROXY="$_epe_norm"
    all_proxy="$_epe_norm"
    export ALL_PROXY all_proxy
    case "$_epe_raw" in
        http://*|https://*)
            http_proxy="$_epe_raw"
            https_proxy="$_epe_raw"
            HTTP_PROXY="$_epe_raw"
            HTTPS_PROXY="$_epe_raw"
            export http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
            ;;
    esac
}

_get_working_gh_mirror() {
    if [ -n "${_WORKING_GH_MIRROR:-}" ]; then
        printf '%s' "$_WORKING_GH_MIRROR"
    elif [ -n "${TMP_DIR:-}" ] && [ -r "$TMP_DIR/working_gh_mirror" ]; then
        cat "$TMP_DIR/working_gh_mirror" 2>/dev/null || true
    fi
}

_set_working_gh_mirror() {
    _WORKING_GH_MIRROR="$1"
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        if [ -n "$1" ]; then
            printf '%s' "$1" >"$TMP_DIR/working_gh_mirror" 2>/dev/null || true
        else
            rm -f "$TMP_DIR/working_gh_mirror" 2>/dev/null || true
        fi
    fi
}

_get_direct_failed() {
    if [ "${_DIRECT_FAILED:-0}" = "1" ]; then
        printf '1'
    elif [ -n "${TMP_DIR:-}" ] && [ -r "$TMP_DIR/direct_failed" ]; then
        cat "$TMP_DIR/direct_failed" 2>/dev/null || printf '0'
    else
        printf '0'
    fi
}

_set_direct_failed() {
    _DIRECT_FAILED="$1"
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        if [ "$1" = "1" ]; then
            printf '1' >"$TMP_DIR/direct_failed" 2>/dev/null || true
        else
            rm -f "$TMP_DIR/direct_failed" 2>/dev/null || true
        fi
    fi
}

_wget_supports_ipv4() {
    if [ -z "${_WGET_SUPPORTS_IPV4:-}" ]; then
        if wget --help 2>&1 | grep -q -- '-4'; then
            _WGET_SUPPORTS_IPV4=1
        else
            _WGET_SUPPORTS_IPV4=0
        fi
    fi
    [ "$_WGET_SUPPORTS_IPV4" = "1" ]
}

_normalize_mirror_prefix() {
    _nmp_val="$1"
    while :; do
        case "$_nmp_val" in
            */) _nmp_val="${_nmp_val%/}" ;;
            *) break ;;
        esac
    done
    [ -n "$_nmp_val" ] && printf '%s/' "$_nmp_val"
}

_append_unique_candidate() {
    _auc_list="$1"
    _auc_item="$2"
    [ -n "$_auc_item" ] || { printf '%s' "$_auc_list"; return 0; }
    case " $_auc_list " in
        *" $_auc_item "*) printf '%s' "$_auc_list" ;;
        *)
            if [ -n "$_auc_list" ]; then
                printf '%s %s' "$_auc_list" "$_auc_item"
            else
                printf '%s' "$_auc_item"
            fi
            ;;
    esac
}

_build_gh_candidates() {
    _bgc_pref="$(_get_working_gh_mirror)"
    _bgc_custom=""
    [ -n "${CUSTOM_MIRROR:-}" ] && _bgc_custom="$(_normalize_mirror_prefix "$CUSTOM_MIRROR")"
    _bgc_proxy="$(_resolve_effective_proxy)"
    _bgc_df="$(_get_direct_failed)"
    _bgc_list=""

    if [ -n "$_bgc_custom" ]; then
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_custom")"
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "direct")"
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_pref")"
    elif [ -n "$_bgc_proxy" ]; then
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "direct")"
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_pref")"
    elif [ -n "$_bgc_pref" ] && [ "$_bgc_df" = "1" ]; then
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_pref")"
        for _bgc_m in $GH_MIRRORS; do
            _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_m")"
        done
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "direct")"
        printf '%s' "$_bgc_list"
        return 0
    else
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "direct")"
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_pref")"
    fi

    for _bgc_m in $GH_MIRRORS; do
        _bgc_list="$(_append_unique_candidate "$_bgc_list" "$_bgc_m")"
    done
    printf '%s' "$_bgc_list"
}

_file_looks_like_html() {
    _flh_head="$(head -c 512 "$1" 2>/dev/null | tr -d '\000' | tr 'A-Z' 'a-z')"
    case "$_flh_head" in
        *'<!doctype'*|*'<html'*|*'<head'*|*'error code:'*) return 0 ;;
        *) return 1 ;;
    esac
}

_validate_downloaded_payload() {
    _vdp_file="$1"
    _vdp_kind="${2:-generic}"
    [ -s "$_vdp_file" ] || return 1
    if _file_looks_like_html "$_vdp_file"; then
        return 1
    fi
    case "$_vdp_kind" in
        sha256)
            _vdp_tab="$(printf '\t')"
            grep -qE "^[0-9a-fA-F]{64}[ ${_vdp_tab}]+" "$_vdp_file" 2>/dev/null || return 1
            ;;
        pkg)
            _vdp_sz="$(wc -c < "$_vdp_file" 2>/dev/null | tr -d ' \t\r\n' || echo 0)"
            case "$_vdp_sz" in ''|*[!0-9]*) _vdp_sz=0 ;; esac
            [ "$_vdp_sz" -gt 1024 ] 2>/dev/null || return 1
            _vdp_magic4="$(head -c 4 "$_vdp_file" 2>/dev/null | tr -d '\000' || true)"
            _vdp_magic2="$(head -c 2 "$_vdp_file" 2>/dev/null | tr -d '\000' || true)"
            _vdp_gz="$(printf '\037\213')"
            case "$_vdp_magic4" in
                ADBd*|"!<ar"*) return 0 ;;
            esac
            [ "$_vdp_magic2" = "$_vdp_gz" ] && return 0
            tar -ztf "$_vdp_file" >/dev/null 2>&1 && return 0
            return 1
            ;;
    esac
    return 0
}

http_get() {
    _hg_url="$1"
    case "$FETCHER" in
        wget)
            _hg_t0="$(date +%s 2>/dev/null || echo 0)"
            _hg_rc=0
            _hg_res="$(run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -U "$INSTALLER_USER_AGENT" -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$_hg_url" 2>/dev/null)" || _hg_rc=$?
            if [ "$_hg_rc" -ne 0 ] || [ -z "$_hg_res" ]; then
                _hg_t1="$(date +%s 2>/dev/null || echo "$_hg_t0")"
                _hg_el=$((_hg_t1 - _hg_t0))
                if [ "$_hg_el" -lt $((CONNECT_TIMEOUT_SECONDS - 1)) ]; then
                    if _wget_supports_ipv4; then
                        _hg_res="$(run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -4 -U "$INSTALLER_USER_AGENT" --no-check-certificate -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$_hg_url" 2>/dev/null)" || true
                    else
                        _hg_res="$(run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -U "$INSTALLER_USER_AGENT" --no-check-certificate -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$_hg_url" 2>/dev/null)" || true
                    fi
                fi
            fi
            [ -n "$_hg_res" ] || return 1
            printf '%s' "$_hg_res"
            ;;
        curl)
            _hg_proxy="$(_resolve_effective_proxy)"
            _hg_rc=0
            if [ -n "$_hg_proxy" ]; then
                _hg_cp="$(_curl_proxy_url "$_hg_proxy")"
                _hg_res="$(curl -x "$_hg_cp" -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$_hg_url" 2>/dev/null)" || _hg_rc=$?
                if [ "$_hg_rc" -ne 0 ] && _curl_is_network_retryable_rc "$_hg_rc"; then
                    _hg_rc=0
                    _hg_res="$(curl -4 -x "$_hg_cp" -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$_hg_url" 2>/dev/null)" || _hg_rc=$?
                fi
                [ "$_hg_rc" -eq 0 ] || return "$_hg_rc"
                printf '%s' "$_hg_res"
                return 0
            fi
            _hg_res="$(curl -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$_hg_url" 2>/dev/null)" || _hg_rc=$?
            if [ "$_hg_rc" -ne 0 ] && _curl_is_network_retryable_rc "$_hg_rc"; then
                _hg_rc=0
                _hg_res="$(curl -4 -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$_hg_url" 2>/dev/null)" || _hg_rc=$?
            fi
            if [ "$_hg_rc" -ne 0 ] && _curl_is_network_retryable_rc "$_hg_rc" && curl_supports_doh; then
                for _hg_doh in "https://dns.google/dns-query" "https://1.1.1.1/dns-query"; do
                    _hg_rc=0
                    _hg_res="$(curl -4 -A "$INSTALLER_USER_AGENT" --doh-url "$_hg_doh" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$_hg_url" 2>/dev/null)" || _hg_rc=$?
                    [ "$_hg_rc" -eq 0 ] && break
                    _curl_is_network_retryable_rc "$_hg_rc" || break
                done
            fi
            [ "$_hg_rc" -eq 0 ] || return "$_hg_rc"
            printf '%s' "$_hg_res"
            ;;
        *) return 1 ;;
    esac
}

download_file_once() {
    _dfo_url="$1"; _dfo_dst="$2"
    case "$FETCHER" in
        wget)
            _dfo_t0="$(date +%s 2>/dev/null || echo 0)"
            if run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" wget -U "$INSTALLER_USER_AGENT" -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$_dfo_dst" "$_dfo_url" && [ -s "$_dfo_dst" ]; then
                return 0
            fi
            _dfo_partial=0
            [ -s "$_dfo_dst" ] && _dfo_partial=1
            rm -f "$_dfo_dst"
            [ "$_dfo_partial" -eq 1 ] && return 1
            _dfo_t1="$(date +%s 2>/dev/null || echo "$_dfo_t0")"
            _dfo_el=$((_dfo_t1 - _dfo_t0))
            if [ "$_dfo_el" -lt $((CONNECT_TIMEOUT_SECONDS - 1)) ]; then
                if _wget_supports_ipv4; then
                    run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" wget -4 -U "$INSTALLER_USER_AGENT" --no-check-certificate -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$_dfo_dst" "$_dfo_url" && [ -s "$_dfo_dst" ] && return 0
                else
                    run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" wget -U "$INSTALLER_USER_AGENT" --no-check-certificate -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$_dfo_dst" "$_dfo_url" && [ -s "$_dfo_dst" ] && return 0
                fi
                rm -f "$_dfo_dst"
            fi
            return 1
            ;;
        curl)
            _dfo_proxy="$(_resolve_effective_proxy)"
            _dfo_rc=0
            if [ -n "$_dfo_proxy" ]; then
                _dfo_cp="$(_curl_proxy_url "$_dfo_proxy")"
                run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" curl -x "$_dfo_cp" -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$_dfo_url" -o "$_dfo_dst" || _dfo_rc=$?
                _dfo_partial=0
                [ -s "$_dfo_dst" ] && _dfo_partial=1
                [ "$_dfo_rc" -eq 0 ] && [ "$_dfo_partial" -eq 1 ] && return 0
                rm -f "$_dfo_dst"
                if [ "$_dfo_partial" -eq 0 ] && _curl_is_network_retryable_rc "$_dfo_rc"; then
                    _dfo_rc=0
                    run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" curl -4 -x "$_dfo_cp" -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$_dfo_url" -o "$_dfo_dst" || _dfo_rc=$?
                    [ "$_dfo_rc" -eq 0 ] && [ -s "$_dfo_dst" ] && return 0
                    rm -f "$_dfo_dst"
                fi
                return "${_dfo_rc:-1}"
            fi

            run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" curl -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$_dfo_url" -o "$_dfo_dst" || _dfo_rc=$?
            _dfo_partial=0
            [ -s "$_dfo_dst" ] && _dfo_partial=1
            [ "$_dfo_rc" -eq 0 ] && [ "$_dfo_partial" -eq 1 ] && return 0
            rm -f "$_dfo_dst"
            # Mid-stream stall (e.g., 16 KB drop): advance straight to the next mirror.
            if [ "$_dfo_rc" -eq 28 ] && [ "$_dfo_partial" -eq 1 ]; then
                return 28
            fi
            if _curl_is_network_retryable_rc "$_dfo_rc"; then
                if [ "$_dfo_partial" -eq 0 ]; then
                    _dfo_rc=0
                    run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" curl -4 -A "$INSTALLER_USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$_dfo_url" -o "$_dfo_dst" || _dfo_rc=$?
                    _dfo_partial=0
                    [ -s "$_dfo_dst" ] && _dfo_partial=1
                    [ "$_dfo_rc" -eq 0 ] && [ "$_dfo_partial" -eq 1 ] && return 0
                    rm -f "$_dfo_dst"
                    if [ "$_dfo_rc" -eq 28 ] && [ "$_dfo_partial" -eq 1 ]; then
                        return 28
                    fi
                fi
                if _curl_is_network_retryable_rc "$_dfo_rc" && curl_supports_doh; then
                    for _dfo_doh in "https://dns.google/dns-query" "https://1.1.1.1/dns-query"; do
                        rm -f "$_dfo_dst"
                        _dfo_rc=0
                        run_logged_timeout download "$DOWNLOAD_TIMEOUT_SECONDS" curl -4 -A "$INSTALLER_USER_AGENT" --doh-url "$_dfo_doh" --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$_dfo_url" -o "$_dfo_dst" || _dfo_rc=$?
                        [ "$_dfo_rc" -eq 0 ] && [ -s "$_dfo_dst" ] && return 0
                        rm -f "$_dfo_dst"
                        _curl_is_network_retryable_rc "$_dfo_rc" || break
                    done
                fi
            fi
            return "${_dfo_rc:-1}"
            ;;
        *) return 1 ;;
    esac
}

download_with_retry() {
    _dwr_url="$1"; _dwr_dst="$2"; _dwr_label="$3"; _dwr_kind="${4:-}"
    if [ -z "$_dwr_kind" ]; then
        case "$_dwr_dst:$_dwr_label" in
            *sha256sums.txt*) _dwr_kind="sha256" ;;
            *.apk*|*.ipk*) _dwr_kind="pkg" ;;
            *) _dwr_kind="generic" ;;
        esac
    fi
    _dwr_candidates="$(_build_gh_candidates)"
    _dwr_total=0
    for _dwr_c in $_dwr_candidates; do _dwr_total=$((_dwr_total + 1)); done
    _dwr_attempt=1
    for _dwr_c in $_dwr_candidates; do
        if [ "$_dwr_c" = "direct" ]; then
            _dwr_try_url="$_dwr_url"
        else
            _dwr_try_url="${_dwr_c}${_dwr_url}"
        fi
        msg "Downloading $_dwr_label (attempt $_dwr_attempt/$_dwr_total)"
        rm -f "$_dwr_dst"
        if download_file_once "$_dwr_try_url" "$_dwr_dst" && _validate_downloaded_payload "$_dwr_dst" "$_dwr_kind"; then
            if [ "$_dwr_c" = "direct" ]; then
                _set_direct_failed 0
                _set_working_gh_mirror ""
            else
                _set_working_gh_mirror "$_dwr_c"
            fi
            return 0
        elif [ "$_dwr_c" = "direct" ]; then
            _set_direct_failed 1
        fi
        rm -f "$_dwr_dst"
        _dwr_attempt=$((_dwr_attempt + 1))
        [ "$_dwr_attempt" -le "$_dwr_total" ] && sleep 1
    done
    return 1
}

sync_time() {
    _year="$(date +%Y 2>/dev/null || echo 0)"
    case "$_year" in *[!0-9]*|"") _year=0 ;; esac
    [ "$_year" -ge 2024 ] && return 0
    warn "System clock is invalid; attempting NTP sync before HTTPS/package access"
    if command_exists ntpd; then
        ntpd -q -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123 >/dev/null 2>&1 || true
    fi
    _year="$(date +%Y 2>/dev/null || echo 0)"
    case "$_year" in *[!0-9]*|"") _year=0 ;; esac
    [ "$_year" -ge 2024 ] || warn "Clock is still invalid; TLS downloads may fail"
}

detect_package_manager() {
    if command_exists apk; then PKG_MANAGER="apk"; PKG_IS_APK=1; return 0; fi
    if command_exists opkg; then PKG_MANAGER="opkg"; PKG_IS_APK=0; return 0; fi
    err "Neither apk nor opkg is available"
    return 1
}

pkg_is_installed() {
    _pkg="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$_pkg" >/dev/null 2>&1
    else
        opkg status "$_pkg" 2>/dev/null | grep -q '^Status: .* installed'
    fi
}

apk_supports_wait() {
    apk --help 2>&1 | grep -q -- '--wait'
}

diagnose_apk_lock() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    _found=0
    for _fd in /proc/[0-9]*/fd/*; do
        [ -e "$_fd" ] || continue
        _target="$(readlink "$_fd" 2>/dev/null || true)"
        case "$_target" in
            */apk/db/lock|*/lib/apk/db/lock)
                _pid="$(printf '%s' "$_fd" | cut -d/ -f3)"
                _comm="$(cat "/proc/$_pid/comm" 2>/dev/null || echo unknown)"
                _cmd="$(tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null || true)"
                warn "APK lock holder: pid=$_pid process=$_comm command=${_cmd:-unknown}"
                _found=1
                ;;
        esac
    done
    [ "$_found" -eq 1 ] || warn "APK database is locked but the holder could not be identified"
}

apk_run() {
    _tag="$1"; _seconds="$2"; shift 2
    if apk_supports_wait; then
        run_logged_timeout "$_tag" "$_seconds" apk --wait "$APK_LOCK_WAIT_SECONDS" "$@"
        _rc=$?
        [ "$_rc" -eq 0 ] || diagnose_apk_lock
        return "$_rc"
    fi
    _attempt=1
    while [ "$_attempt" -le 12 ]; do
        run_logged_timeout "$_tag" "$_seconds" apk "$@"
        _rc=$?
        [ "$_rc" -eq 0 ] && return 0
        [ "$_rc" -eq 227 ] || return "$_rc"
        [ "$_attempt" -eq 1 ] && diagnose_apk_lock
        sleep 5
        _attempt=$((_attempt + 1))
    done
    diagnose_apk_lock
    return 227
}

probe_apk_repo_url() {
    _pru_url="$1"
    case "$FETCHER" in
        curl)
            curl --connect-timeout "$APK_REPO_PROBE_TIMEOUT_SECONDS" \
                 --max-time "$APK_REPO_PROBE_TIMEOUT_SECONDS" \
                 -fsSL "$_pru_url" -o /dev/null >/dev/null 2>&1
            ;;
        wget)
            run_with_deadline "$APK_REPO_PROBE_TIMEOUT_SECONDS" \
                wget -q -T "$APK_REPO_PROBE_TIMEOUT_SECONDS" \
                     -O /dev/null "$_pru_url" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

prepare_apk_repositories() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$APK_REPOS_PREPARED" -eq 1 ] && return 0
    APK_REPOS_PREPARED=1
    APK_FILTERED_REPOS_FILE=""

    _repo_sources=""
    [ -f "$APK_REPOS_FILE" ] && _repo_sources="$APK_REPOS_FILE"
    if [ -d "$APK_REPOS_DIR" ]; then
        for _rf in "$APK_REPOS_DIR"/*.list; do
            [ -f "$_rf" ] && _repo_sources="$_repo_sources $_rf"
        done
    fi
    [ -n "$_repo_sources" ] || return 0

    _filtered_out="$TMP_DIR/apk-repositories.list"
    : >"$_filtered_out"
    _ok_origins=" "
    _bad_origins=" "
    _had_unreachable=0

    # shellcheck disable=SC2086
    while IFS= read -r _raw_line || [ -n "$_raw_line" ]; do
        _line="$(printf '%s' "$_raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$_line" in
            ""|\#*) continue ;;
            http://*|https://*)
                _origin="$(printf '%s' "$_line" | sed -n 's|^\(https\{0,1\}://[^/]*\).*|\1|p' | tr 'A-Z' 'a-z')"
                _host="${_origin#*://}"
                case "$_bad_origins" in
                    *" $_origin "*)
                        continue
                        ;;
                esac
                if probe_apk_repo_url "$_line"; then
                    _ok_origins="${_ok_origins}${_origin} "
                    printf '%s\n' "$_line" >>"$_filtered_out"
                else
                    case "$_ok_origins" in
                        *" $_origin "*)
                            _had_unreachable=1
                            warn "Skipping broken APK repository feed: $_line (non-critical)"
                            ;;
                        *)
                            _bad_origins="${_bad_origins}${_origin} "
                            _had_unreachable=1
                            warn "Skipping unreachable APK repository host: ${_host:-$_origin} (non-critical)"
                            ;;
                    esac
                fi
                ;;
            *)
                printf '%s\n' "$_line" >>"$_filtered_out"
                ;;
        esac
    done <<EOF_REPOS
$(cat $_repo_sources 2>/dev/null || true)
EOF_REPOS

    if [ "$_had_unreachable" -eq 1 ]; then
        APK_FILTERED_REPOS_FILE="$_filtered_out"
    else
        rm -f "$_filtered_out"
    fi
    return 0
}

heal_apk_world() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -f "$APK_WORLD_FILE" ] || return 0
    apk add --simulate --no-network --repositories-file /dev/null >/dev/null 2>&1 && return 0
    _sim_out="$(apk add --simulate --no-network --repositories-file /dev/null 2>&1 || true)"
    _bad_pkgs="$(printf '%s\n' "$_sim_out" | sed -n 's/.*world\[\([A-Za-z0-9._+-]*\).*/\1/p' | sort -u)"
    [ -n "$_bad_pkgs" ] || return 0
    for _bp in $_bad_pkgs; do
        [ -n "$_bp" ] || continue
        if pkg_is_installed "$_bp"; then
            sed -i -E "s/^${_bp}[ \t<>=~].*\$/${_bp}/" "$APK_WORLD_FILE" 2>/dev/null || true
        else
            sed -i -E "/^${_bp}([ \t<>=~].*)?\$/d" "$APK_WORLD_FILE" 2>/dev/null || true
        fi
    done
    return 0
}

apk_satisfy_missing_local_deps() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$#" -gt 0 ] || return 0
    heal_apk_world
    _sim_out="$(apk add --simulate --allow-untrusted --force-overwrite --no-network --repositories-file /dev/null "$@" 2>&1 || true)"
    _missing_deps="$(printf '%s\n' "$_sim_out" | sed -n 's/^[[:space:]]*\([A-Za-z0-9._+-][A-Za-z0-9._+-]*\)[[:space:]]*(no such package):.*/\1/p' | sort -u)"
    [ -n "$_missing_deps" ] || return 0
    for _md in $_missing_deps; do
        [ -n "$_md" ] || continue
        warn "Package $_md is unavailable in repositories; registering virtual placeholder"
        apk_run apk-virtual-dep 30 add --no-network --repositories-file /dev/null --force-non-repository --virtual "$_md" || true
    done
    return 0
}

apk_can_install_local_offline() {
    [ "$PKG_IS_APK" -eq 1 ] || return 1
    [ "$#" -gt 0 ] || return 0
    for _f in "$@"; do
        [ -f "$_f" ] || return 0
    done
    heal_apk_world
    apk add --simulate --allow-untrusted --force-overwrite --no-network --repositories-file /dev/null "$@" >/dev/null 2>&1
}

pkg_update_index() {
    [ "$PACKAGE_INDEX_UPDATED" -eq 1 ] && return 0
    if [ "$DRY_RUN" -eq 1 ]; then msg "[dry-run] would refresh $PKG_MANAGER package indexes"; PACKAGE_INDEX_UPDATED=1; return 0; fi
    msg "Refreshing $PKG_MANAGER package indexes"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        prepare_apk_repositories
        if [ -n "$APK_FILTERED_REPOS_FILE" ] && [ ! -s "$APK_FILTERED_REPOS_FILE" ]; then
            warn "All APK repositories are unreachable; continuing with installed/local packages"
        elif [ -n "$APK_FILTERED_REPOS_FILE" ]; then
            apk_run apk-update 180 update --force-missing-repositories --timeout 15 --repositories-file "$APK_FILTERED_REPOS_FILE" ||
                warn "APK index refresh reported repository errors; continuing"
        else
            apk_run apk-update 180 update --force-missing-repositories --timeout 15 ||
                warn "APK index refresh reported repository errors; continuing"
        fi
    else
        run_logged_timeout opkg-update 180 opkg update ||
            warn "opkg index refresh reported repository errors; continuing"
    fi
    PACKAGE_INDEX_UPDATED=1
    return 0
}

pkg_install_names() {
    [ "$#" -gt 0 ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then msg "[dry-run] would install dependencies: $*"; return 0; fi
    msg "Installing packages: $*"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        heal_apk_world
        prepare_apk_repositories
        if [ -n "$APK_FILTERED_REPOS_FILE" ] && [ ! -s "$APK_FILTERED_REPOS_FILE" ]; then
            return 1
        elif [ -n "$APK_FILTERED_REPOS_FILE" ]; then
            apk_run apk-add "$PACKAGE_TIMEOUT_SECONDS" add --force-missing-repositories --timeout 15 --repositories-file "$APK_FILTERED_REPOS_FILE" "$@"
        else
            apk_run apk-add "$PACKAGE_TIMEOUT_SECONDS" add --force-missing-repositories --timeout 15 "$@"
        fi
    else
        run_logged_timeout opkg-add "$PACKAGE_TIMEOUT_SECONDS" opkg install "$@"
    fi
}

ensure_package() {
    _pkg="$1"
    pkg_is_installed "$_pkg" && return 0
    pkg_update_index || true
    pkg_install_names "$_pkg"
}

ensure_bootstrap_ucode_runtime() {
    if [ "$DRY_RUN" -eq 0 ] && [ "$PKG_IS_APK" -eq 1 ] && grep -qE "^ip-tiny([ \t<>=~].*)?\$" "$APK_WORLD_FILE" 2>/dev/null; then
        scrub_apk_world "ip-tiny"
    fi
    if command_exists ucode && ucode -e 'require("fs"); require("uci");' >/dev/null 2>&1; then
        return 0
    fi
    if ! command_exists ucode; then
        pkg_update_index || true
        pkg_install_names ucode || return 1
    fi
    ensure_package ucode-mod-fs || true
    ensure_package ucode-mod-uci || true
    command_exists ucode && ucode -e 'require("fs"); require("uci");' >/dev/null 2>&1
}

kmod_is_available() {
    _kmod="$1"
    pkg_is_installed "$_kmod" && return 0
    case "$_kmod" in
        kmod-nft-tproxy)
            [ -d /sys/module/nft_tproxy ] && return 0
            modprobe nft_tproxy >/dev/null 2>&1 && return 0
            ;;
        kmod-nft-fib)
            [ -d /sys/module/nft_fib_inet ] && return 0
            [ -d /sys/module/nft_fib ] && return 0
            modprobe nft_fib_inet >/dev/null 2>&1 && return 0
            ;;
        kmod-tun)
            [ -e /dev/net/tun ] && return 0
            [ -d /sys/module/tun ] && return 0
            modprobe tun >/dev/null 2>&1 && return 0
            ;;
        kmod-inet-diag)
            [ -d /sys/module/inet_diag ] && return 0
            modprobe inet_diag >/dev/null 2>&1 && return 0
            ;;
    esac
    return 1
}

release_ip_tiny_conflict() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ "$PKG_IS_APK" -eq 1 ]; then
        if grep -qE "^ip-tiny([ \t<>=~].*)?\$" "$APK_WORLD_FILE" 2>/dev/null ||
           grep -q "^P:ip-tiny\$" "$APK_INSTALLED_DB" 2>/dev/null ||
           pkg_is_installed ip-tiny; then
            msg "Releasing conflicting ip-tiny before installing ip-full"
            scrub_apk_world "ip-tiny"
            apk_run apk-del-ip-tiny "$PACKAGE_TIMEOUT_SECONDS" del --no-network --repositories-file /dev/null --force-broken-world ip-tiny || true
        fi
    elif pkg_is_installed ip-tiny; then
        msg "Removing conflicting ip-tiny before installing ip-full"
        run_logged_timeout opkg-del-ip-tiny "$PACKAGE_TIMEOUT_SECONDS" opkg remove --force-depends ip-tiny || true
    fi
}

ensure_bootstrap_fetcher() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    _ebf_missing=""
    command_exists curl || _ebf_missing="$_ebf_missing curl"
    pkg_is_installed ca-bundle || _ebf_missing="$_ebf_missing ca-bundle"
    if [ -n "$_ebf_missing" ]; then
        msg "Bootstrapping TLS and download tools:$_ebf_missing"
        _ebf_saved_ap="${ALL_PROXY-__UNSET__}"
        _ebf_saved_apl="${all_proxy-__UNSET__}"
        _ebf_saved_hp="${http_proxy-__UNSET__}"
        _ebf_saved_hps="${https_proxy-__UNSET__}"
        _ebf_saved_HP="${HTTP_PROXY-__UNSET__}"
        _ebf_saved_HPS="${HTTPS_PROXY-__UNSET__}"
        unset ALL_PROXY all_proxy
        case "${http_proxy:-}" in socks*) unset http_proxy ;; esac
        case "${https_proxy:-}" in socks*) unset https_proxy ;; esac
        case "${HTTP_PROXY:-}" in socks*) unset HTTP_PROXY ;; esac
        case "${HTTPS_PROXY:-}" in socks*) unset HTTPS_PROXY ;; esac

        pkg_update_index || true
        # shellcheck disable=SC2086
        pkg_install_names $_ebf_missing || warn "Could not preinstall$_ebf_missing; continuing with $FETCHER"

        [ "$_ebf_saved_ap" = "__UNSET__" ] && unset ALL_PROXY || { ALL_PROXY="$_ebf_saved_ap"; export ALL_PROXY; }
        [ "$_ebf_saved_apl" = "__UNSET__" ] && unset all_proxy || { all_proxy="$_ebf_saved_apl"; export all_proxy; }
        [ "$_ebf_saved_hp" = "__UNSET__" ] && unset http_proxy || { http_proxy="$_ebf_saved_hp"; export http_proxy; }
        [ "$_ebf_saved_hps" = "__UNSET__" ] && unset https_proxy || { https_proxy="$_ebf_saved_hps"; export https_proxy; }
        [ "$_ebf_saved_HP" = "__UNSET__" ] && unset HTTP_PROXY || { HTTP_PROXY="$_ebf_saved_HP"; export HTTP_PROXY; }
        [ "$_ebf_saved_HPS" = "__UNSET__" ] && unset HTTPS_PROXY || { HTTPS_PROXY="$_ebf_saved_HPS"; export HTTPS_PROXY; }

        detect_fetcher || true
    fi
    if [ "$FETCHER" = "wget" ]; then
        case "$(_resolve_effective_proxy)" in
            socks*)
                warn "Configured SOCKS proxy requires curl, but only wget/uclient-fetch is available"
                ;;
        esac
    fi
    return 0
}

ensure_runtime_dependencies() {
    release_ip_tiny_conflict
    _missing=""
    for _pkg in ca-bundle curl openssl-util coreutils-base64 coreutils-timeout bind-dig nftables ip-full; do
        pkg_is_installed "$_pkg" || _missing="$_missing $_pkg"
    done
    for _kmod in kmod-nft-tproxy kmod-nft-fib kmod-tun kmod-inet-diag; do
        kmod_is_available "$_kmod" || _missing="$_missing $_kmod"
    done
    [ -z "$_missing" ] && { detect_fetcher || true; return 0; }
    pkg_update_index || true
    # shellcheck disable=SC2086
    if ! pkg_install_names $_missing; then
        warn "Batch dependency installation had errors; retrying packages individually"
        for _pkg in $_missing; do
            pkg_install_names "$_pkg" || warn "Could not install $_pkg from repository (may be built-in or unavailable in feed); continuing"
        done
    fi
    detect_fetcher || true
    modprobe nft_tproxy >/dev/null 2>&1 || true
    modprobe nft_fib_inet >/dev/null 2>&1 || true
    modprobe tun >/dev/null 2>&1 || true
    modprobe inet_diag >/dev/null 2>&1 || true
    return 0
}

install_release_helper() {
    _helper="$TMP_DIR/release-helper.uc"
    cat >"$_helper" <<'EOF_UCODE'
#!/usr/bin/env ucode
let fs = require("fs");
function stdin_all() { let f = fs.open("/dev/stdin", "r"); if (!f) return ""; let d = f.read("all"); f.close(); return d || ""; }
function obj() { try { return json(stdin_all()); } catch (e) { return null; } }
function valid(v, channel) {
    let s = "" + (v || "");
    if (channel == "beta")
        return match(s, /^v?[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z][0-9A-Za-z._-]*)?$/) != null;
    return match(s, /^[0-9]+[.][0-9]+[.][0-9]+$/) != null;
}
function pick_release(v, channel) {
    if (type(v) == "object") return v;
    if (type(v) != "array") return null;
    for (let r in v) {
        if (type(r) != "object" || r.draft) continue;
        if (channel == "beta") return r;
        if (!r.prerelease) return r;
    }
    return null;
}
function asset_name(kind, ext, ver) {
    if (kind == "sha256") return "sha256sums.txt";
    if (kind == "backend") return "tachyon_" + ver + "." + ext;
    if (kind == "app") return "luci-app-tachyon_" + ver + "." + ext;
    if (kind == "i18n") return "luci-i18n-tachyon-ru_" + ver + "." + ext;
    return "";
}
let mode = ARGV[0] || "";
let channel = ARGV[1] || "stable";
let v = obj();
let r = pick_release(v, channel);
if (!r) exit(2);
let ver = "" + (r.tag_name || "");
if (mode == "tag") { if (valid(ver, channel)) print(ver, "\n"); else exit(3); }
else if (mode == "asset") {
    let kind = ARGV[2] || ""; let ext = ARGV[3] || ""; let wanted = asset_name(kind, ext, ver);
    for (let a in (r.assets || [])) if (a.name == wanted) { print("" + (a.browser_download_url || ""), "\n"); exit(0); }
    exit(4);
}
else if (mode == "size") {
    let kind = ARGV[2] || ""; let ext = ARGV[3] || ""; let wanted = asset_name(kind, ext, ver);
    for (let a in (r.assets || [])) if (a.name == wanted) { print("" + int(a.size || 0), "\n"); exit(0); }
    exit(4);
}
else if (mode == "tags") {
    if (type(v) != "array") exit(1);
    for (let rel in v) {
        if (type(rel) != "object" || rel.draft) continue;
        if (channel != "beta" && rel.prerelease) continue;
        let t = "" + (rel.tag_name || "");
        if (valid(t, channel)) print(t, "\n");
    }
}
else exit(1);
EOF_UCODE
    printf '%s\n' "$_helper"
}

release_helper() {
    ucode "$(install_release_helper)" "$@"
}

_is_valid_release_json() {
    _vrj_body="$1"
    [ -n "$_vrj_body" ] || return 1
    _vrj_head="$(printf '%s' "$_vrj_body" | head -c 512 2>/dev/null | tr -d '\000' | tr 'A-Z' 'a-z')"
    case "$_vrj_head" in
        *'<!doctype'*|*'<html'*|*'<head'*|*'error code:'*) return 1 ;;
    esac
    case "$_vrj_body" in
        *'"tag_name"'*|*'"assets"'*) return 0 ;;
        *) return 1 ;;
    esac
}

_fetch_github_api_json() {
    _fga_url="$1"
    _fga_warn="${2:-0}"
    _fga_candidates="$(_build_gh_candidates)"
    _fga_warned=0
    for _fga_c in $_fga_candidates; do
        if [ "$_fga_c" = "direct" ]; then
            _fga_try_url="$_fga_url"
        else
            if [ "$_fga_warn" -eq 1 ] && [ "$_fga_warned" -eq 0 ]; then
                warn "GitHub release API failed; trying mirror"
                _fga_warned=1
            fi
            _fga_try_url="${_fga_c}${_fga_url}"
        fi
        _fga_json="$(http_get "$_fga_try_url" 2>/dev/null || true)"
        if _is_valid_release_json "$_fga_json"; then
            if [ "$_fga_c" = "direct" ]; then
                _set_direct_failed 0
                _set_working_gh_mirror ""
            else
                _set_working_gh_mirror "$_fga_c"
            fi
            printf '%s' "$_fga_json"
            return 0
        elif [ "$_fga_c" = "direct" ]; then
            _set_direct_failed 1
        fi
    done
    return 1
}

_is_valid_atom_feed() {
    _vaf_body="$1"
    [ -n "$_vaf_body" ] || return 1
    _vaf_head="$(printf '%s' "$_vaf_body" | head -c 512 2>/dev/null | tr -d '\000' | tr 'A-Z' 'a-z')"
    case "$_vaf_head" in
        *'<!doctype'*|*'<html'*|*'<head'*|*'error code:'*) return 1 ;;
    esac
    case "$_vaf_body" in
        *'<feed'*|*'<entry'*|*'/releases/tag/'*) return 0 ;;
        *) return 1 ;;
    esac
}

_fetch_github_atom() {
    _fga_url="$1"
    _fga_candidates="$(_build_gh_candidates)"
    for _fga_c in $_fga_candidates; do
        if [ "$_fga_c" = "direct" ]; then
            _fga_try_url="$_fga_url"
        else
            _fga_try_url="${_fga_c}${_fga_url}"
        fi
        _fga_atom="$(http_get "$_fga_try_url" 2>/dev/null || true)"
        if _is_valid_atom_feed "$_fga_atom"; then
            if [ "$_fga_c" = "direct" ]; then
                _set_direct_failed 0
                _set_working_gh_mirror ""
            else
                _set_working_gh_mirror "$_fga_c"
            fi
            printf '%s' "$_fga_atom"
            return 0
        elif [ "$_fga_c" = "direct" ]; then
            _set_direct_failed 1
        fi
    done
    return 1
}

fetch_release_json() {
    _fr_url=""
    if [ -n "$RELEASE_TAG_REQUESTED" ]; then
        _fr_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/${RELEASE_TAG_REQUESTED}"
    elif [ "$RELEASE_CHANNEL" = "beta" ]; then
        _fr_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases?per_page=20"
    else
        _fr_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    fi
    _fetch_github_api_json "$_fr_url" 1
}

fetch_release_tag_list() {
    _fr_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases?per_page=15"
    _fr_json="$(_fetch_github_api_json "$_fr_url" 0 || true)"
    if [ -n "$_fr_json" ]; then
        _fr_tags="$(printf '%s' "$_fr_json" | release_helper tags "$RELEASE_CHANNEL" 2>/dev/null || true)"
        if [ -n "$_fr_tags" ]; then
            printf '%s\n' "$_fr_tags"
            return 0
        fi
    fi
    _fr_atom="$(_fetch_github_atom "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases.atom" || true)"
    [ -n "$_fr_atom" ] || return 1
    if [ "$RELEASE_CHANNEL" = "beta" ]; then
        printf '%s' "$_fr_atom" | sed -n 's|.*/releases/tag/\([^"/?<]*\)".*|\1|p' 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z._-]*)?$' | awk '!seen[$0]++'
    else
        printf '%s' "$_fr_atom" | sed -n 's|.*/releases/tag/\([^"/?<]*\)".*|\1|p' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | awk '!seen[$0]++'
    fi
}

installer_is_interactive() {
    [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]
}

select_release_version() {
    [ -n "$RELEASE_TAG_REQUESTED" ] && return 0
    installer_is_interactive || return 0
    msg "Fetching release list"
    _tags="$(fetch_release_tag_list || true)"
    [ -n "$_tags" ] || return 0
    _count=0
    for _t in $_tags; do _count=$((_count + 1)); done
    [ "$_count" -gt 1 ] || return 0
    printf '\nSelect Tachyon release:\n'
    _i=1
    for _t in $_tags; do
        if [ "$_i" -eq 1 ]; then
            printf '  %s) %s (recommended)\n' "$_i" "$_t"
        else
            printf '  %s) %s\n' "$_i" "$_t"
        fi
        _i=$((_i + 1))
    done
    printf 'Choice [1]: '
    read -r _answer || _answer=""
    case "$_answer" in
        "") _answer=1 ;;
        *[!0-9]*) warn "Unknown choice; using latest"; return 0 ;;
    esac
    if [ "$_answer" -ge 1 ] && [ "$_answer" -le "$_count" ]; then
        _i=1
        for _t in $_tags; do
            if [ "$_i" -eq "$_answer" ]; then
                RELEASE_TAG_REQUESTED="$_t"
                msg "Selected release: $RELEASE_TAG_REQUESTED"
                return 0
            fi
            _i=$((_i + 1))
        done
    fi
    warn "Choice out of range; using latest"
    return 0
}

# Numeric comparison of dotted release tags: succeeds when $1 >= $2.
version_ge() {
    _vg_a="${1#v}"; _vg_b="${2#v}"; _vg_i=0
    while [ "$_vg_i" -lt 3 ]; do
        _vg_pa="${_vg_a%%.*}"; [ "$_vg_pa" = "$_vg_a" ] && _vg_a="" || _vg_a="${_vg_a#*.}"
        _vg_pb="${_vg_b%%.*}"; [ "$_vg_pb" = "$_vg_b" ] && _vg_b="" || _vg_b="${_vg_b#*.}"
        _vg_pa="${_vg_pa%%-*}"; _vg_pb="${_vg_pb%%-*}"
        case "$_vg_pa" in ''|*[!0-9]*) _vg_pa=0 ;; esac
        case "$_vg_pb" in ''|*[!0-9]*) _vg_pb=0 ;; esac
        [ "$_vg_pa" -gt "$_vg_pb" ] && return 0
        [ "$_vg_pa" -lt "$_vg_pb" ] && return 1
        _vg_i=$((_vg_i + 1))
    done
    return 0
}

effective_release_tag() {
    printf '%s' "${TACHYON_RELEASE_TAG:-$RELEASE_TAG_REQUESTED}"
}

release_is_tachyon_core_only() {
    _rit_tag="$(effective_release_tag)"
    [ -n "$_rit_tag" ] || return 0
    version_ge "$_rit_tag" "1.8.0"
}

is_v2_tag() {
    printf '%s' "${1:-}" | grep -Eq '^v?([2-9]|[1-9][0-9]+)\.'
}

_validate_v2_installer_script() {
    _v2i_file="$1"
    [ -s "$_v2i_file" ] || return 1
    _file_looks_like_html "$_v2i_file" && return 1
    head -n 1 "$_v2i_file" 2>/dev/null | grep -q '^#!' || return 1
    grep -q 'package_asset_name' "$_v2i_file" 2>/dev/null || return 1
    return 0
}

handoff_to_v2_installer() {
    _htv_raw="${1:-}"
    [ -n "$_htv_raw" ] || return 1
    _htv_tag="v${_htv_raw#[vV]}"
    [ -n "${TMP_DIR:-}" ] || init_tmp_dir || return 1

    msg "Release ${_htv_tag} uses per-architecture packages; loading Tachyon 2.0 installer"
    _htv_dl="${TMP_DIR}/tachyon-v2-install.tmp"
    _htv_script="/tmp/tachyon-v2-install.$$.sh"
    _htv_urls=""
    _htv_rel_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${_htv_tag}/install.sh"
    _htv_raw_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/2.0/install.sh"

    for _htv_c in $(_build_gh_candidates); do
        if [ "$_htv_c" = "direct" ]; then
            _htv_u="$_htv_rel_url"
        else
            _htv_u="${_htv_c}${_htv_rel_url}"
        fi
        _htv_urls="$(_append_unique_candidate "$_htv_urls" "$_htv_u")"
    done

    [ -n "${CUSTOM_MIRROR:-}" ] && _htv_urls="$(_append_unique_candidate "$_htv_urls" "$(_normalize_mirror_prefix "$CUSTOM_MIRROR")${_htv_raw_url}")"
    _htv_pref="$(_get_working_gh_mirror)"
    [ -n "$_htv_pref" ] && _htv_urls="$(_append_unique_candidate "$_htv_urls" "${_htv_pref}${_htv_raw_url}")"
    if [ "$(_get_direct_failed)" != "1" ] || [ -n "$(_resolve_effective_proxy)" ]; then
        _htv_urls="$(_append_unique_candidate "$_htv_urls" "$_htv_raw_url")"
    fi
    for _htv_c in $GH_MIRRORS; do
        _htv_urls="$(_append_unique_candidate "$_htv_urls" "${_htv_c}${_htv_raw_url}")"
    done
    _htv_urls="$(_append_unique_candidate "$_htv_urls" "$_htv_raw_url")"

    _htv_fetched=0
    for _htv_try in $_htv_urls; do
        rm -f "$_htv_dl"
        if download_file_once "$_htv_try" "$_htv_dl" && _validate_v2_installer_script "$_htv_dl"; then
            mv -f "$_htv_dl" "$_htv_script" || { rm -f "$_htv_dl"; return 1; }
            chmod 700 "$_htv_script" 2>/dev/null || true
            _htv_fetched=1
            break
        fi
        rm -f "$_htv_dl"
    done

    if [ "$_htv_fetched" -ne 1 ]; then
        err "Failed to download Tachyon 2.0 installer for ${_htv_tag}"
        return 1
    fi

    set -- --tag "$_htv_tag" --channel "$RELEASE_CHANNEL"
    [ "$ASSUME_YES" -eq 1 ] && set -- "$@" -y
    [ "$DRY_RUN" -eq 1 ] && set -- "$@" -n
    [ "$QUIET" -eq 1 ] && set -- "$@" -q
    [ "$REINSTALL_MODE" -eq 1 ] && set -- "$@" --reinstall
    [ "$REPAIR_MODE" -eq 1 ] && set -- "$@" --repair
    [ "$SKIP_ENGINE" -eq 1 ] && set -- "$@" --skip-core
    [ -n "${PROXY_URL_REQUESTED:-}" ] && set -- "$@" --proxy "$PROXY_URL_REQUESTED"
    [ -n "${CUSTOM_MIRROR:-}" ] && set -- "$@" --mirror "$CUSTOM_MIRROR"

    if [ "${TACHYON_INSTALLER_TEST:-0}" = "1" ] || [ -n "${TACHYON_V2_HANDOFF_RECORD_FILE:-}" ]; then
        if [ -n "${TACHYON_V2_HANDOFF_RECORD_FILE:-}" ]; then
            printf '%s|%s\n' "$_htv_script" "$*" >"$TACHYON_V2_HANDOFF_RECORD_FILE"
        fi
        return 0
    fi

    msg "Handing off execution to Tachyon 2.0 installer (${_htv_tag})"
    cleanup
    exec sh "$_htv_script" "$@"
}

resolve_release() {
    if [ -n "$RELEASE_TAG_REQUESTED" ] && is_v2_tag "$RELEASE_TAG_REQUESTED"; then
        handoff_to_v2_installer "$RELEASE_TAG_REQUESTED"
        return $?
    fi
    _ext="ipk"; [ "$PKG_IS_APK" -eq 1 ] && _ext="apk"
    msg "Querying GitHub release API"
    TACHYON_RELEASE_JSON="$(fetch_release_json 2>/dev/null || true)"
    TACHYON_RELEASE_TAG=""
    if [ -n "$TACHYON_RELEASE_JSON" ]; then
        TACHYON_RELEASE_TAG="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper tag "$RELEASE_CHANNEL" 2>/dev/null || true)"
    fi
    if [ -z "$TACHYON_RELEASE_TAG" ]; then
        warn "GitHub release API unavailable; trying releases.atom fallback"
        TACHYON_RELEASE_JSON=""
        if [ -n "$RELEASE_TAG_REQUESTED" ]; then
            TACHYON_RELEASE_TAG="$RELEASE_TAG_REQUESTED"
        else
            _atom="$(_fetch_github_atom "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases.atom" || true)"
            _atom_tags="$(printf '%s' "$_atom" | sed -n 's|.*/releases/tag/\([^"/?<]*\)".*|\1|p' 2>/dev/null || true)"
            for _at in $_atom_tags; do
                if [ "$RELEASE_CHANNEL" = "beta" ]; then
                    if printf '%s' "$_at" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z._-]*)?$'; then
                        TACHYON_RELEASE_TAG="$_at"
                        break
                    fi
                elif printf '%s' "$_at" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                    TACHYON_RELEASE_TAG="$_at"
                    break
                fi
            done
        fi
    fi
    [ -n "$TACHYON_RELEASE_TAG" ] || { err "Could not resolve a valid release tag"; return 1; }
    if is_v2_tag "$TACHYON_RELEASE_TAG"; then
        handoff_to_v2_installer "$TACHYON_RELEASE_TAG"
        return $?
    fi
    if [ -n "$RELEASE_TAG_REQUESTED" ] && [ "$TACHYON_RELEASE_TAG" != "$RELEASE_TAG_REQUESTED" ]; then
        err "Resolved release $TACHYON_RELEASE_TAG does not match requested $RELEASE_TAG_REQUESTED"
        return 1
    fi
    if [ -n "$TACHYON_RELEASE_JSON" ]; then
        TACHYON_SHA256_URL="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper asset "$RELEASE_CHANNEL" sha256 txt 2>/dev/null || true)"
        TACHYON_BACKEND_URL="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper asset "$RELEASE_CHANNEL" backend "$_ext" 2>/dev/null || true)"
        TACHYON_APP_URL="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper asset "$RELEASE_CHANNEL" app "$_ext" 2>/dev/null || true)"
        [ -n "$TACHYON_SHA256_URL" ] && [ -n "$TACHYON_BACKEND_URL" ] && [ -n "$TACHYON_APP_URL" ] || {
            err "Release $TACHYON_RELEASE_TAG is missing required $_ext assets"
            return 1
        }
        TACHYON_BACKEND_NAME="$(basename "$TACHYON_BACKEND_URL")"
        TACHYON_APP_NAME="$(basename "$TACHYON_APP_URL")"
        if [ "$TACHYON_I18N_REQUESTED" -eq 1 ]; then
            TACHYON_I18N_URL="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper asset "$RELEASE_CHANNEL" i18n "$_ext" 2>/dev/null || true)"
            [ -n "$TACHYON_I18N_URL" ] || { err "Release is missing Russian LuCI package"; return 1; }
            TACHYON_I18N_NAME="$(basename "$TACHYON_I18N_URL")"
        fi
        _s1="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper size "$RELEASE_CHANNEL" backend "$_ext" 2>/dev/null || echo 0)"
        _s2="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper size "$RELEASE_CHANNEL" app "$_ext" 2>/dev/null || echo 0)"
        _s3=0
        [ "$TACHYON_I18N_REQUESTED" -eq 1 ] && _s3="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper size "$RELEASE_CHANNEL" i18n "$_ext" 2>/dev/null || echo 0)"
        TACHYON_DOWNLOAD_BYTES=$((_s1 + _s2 + _s3 + 65536))
    else
        _rel_base="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${TACHYON_RELEASE_TAG}"
        TACHYON_SHA256_URL="${_rel_base}/sha256sums.txt"
        TACHYON_BACKEND_URL="${_rel_base}/tachyon_${TACHYON_RELEASE_TAG}.${_ext}"
        TACHYON_APP_URL="${_rel_base}/luci-app-tachyon_${TACHYON_RELEASE_TAG}.${_ext}"
        TACHYON_BACKEND_NAME="tachyon_${TACHYON_RELEASE_TAG}.${_ext}"
        TACHYON_APP_NAME="luci-app-tachyon_${TACHYON_RELEASE_TAG}.${_ext}"
        if [ "$TACHYON_I18N_REQUESTED" -eq 1 ]; then
            TACHYON_I18N_URL="${_rel_base}/luci-i18n-tachyon-ru_${TACHYON_RELEASE_TAG}.${_ext}"
            TACHYON_I18N_NAME="luci-i18n-tachyon-ru_${TACHYON_RELEASE_TAG}.${_ext}"
        fi
        TACHYON_DOWNLOAD_BYTES=4194304
    fi
}

free_kb() {
    _path="$1"
    df -Pk "$_path" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_storage_preflight() {
    _overlay="$(free_kb /overlay)"
    if [ -z "$_overlay" ] || [ "$_overlay" -eq 0 ] 2>/dev/null; then
        [ -d /opt ] && _overlay="$(free_kb /opt)"
    fi
    if [ -z "$_overlay" ] || [ "$_overlay" -eq 0 ] 2>/dev/null; then
        _overlay="$(free_kb /etc)"
    fi
    [ -n "$_overlay" ] || _overlay="$(free_kb /)"
    [ -n "$_overlay" ] || _overlay=0
    if [ "$_overlay" -lt "$REQUIRED_OVERLAY_KB" ]; then
        err "Not enough persistent storage: $((_overlay / 1024)) MiB free, need at least $((REQUIRED_OVERLAY_KB / 1024)) MiB"
        return 1
    fi
}

check_tmp_for_downloads() {
    _tmp_free="$(free_kb /tmp)"; [ -n "$_tmp_free" ] || _tmp_free=0
    _need_kb=$(((TACHYON_DOWNLOAD_BYTES + 1023) / 1024 + MIN_TMP_HEADROOM_KB))
    if [ "$_tmp_free" -lt "$_need_kb" ]; then
        err "Not enough /tmp RAM: $((_tmp_free / 1024)) MiB free, need about $((_need_kb / 1024)) MiB for verified downloads"
        return 1
    fi
}

detect_language_and_i18n() {
    _lang=""
    if [ -r /etc/config/luci ]; then
        _lang="$(sed -n "s/.*option lang ['\"]\?\([a-zA-Z_-]*\)['\"]\?.*/\1/p" /etc/config/luci 2>/dev/null | head -n1)"
    fi
    if pkg_is_installed luci-i18n-tachyon-ru || pkg_is_installed luci-i18n-base-ru; then
        TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0
    fi
    case "$_lang" in ru|ru-*|ru_*) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0 ;; esac
    if [ "$_lang" = "auto" ] || [ -z "$_lang" ]; then
        _tz="$(sed -n "s/.*option \(zonename\|timezone\) ['\"]\?\([^'\"]*\)['\"]\?.*/\2/p" /etc/config/system 2>/dev/null | head -n1)"
        case "$_tz" in *Moscow*|*Europe/Moscow*|*Russia*|*MSK*) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0 ;; esac
        case "${LANG:-}" in *[rR][uU]*) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0 ;; esac
        case "${LC_ALL:-}" in *[rR][uU]*) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0 ;; esac
    fi
    INSTALLER_LANG="en"
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then return 0; fi
    printf 'Install Russian LuCI translation? [y/N]: '
    read -r _answer || true
    case "$_answer" in y|Y|yes|YES) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru" ;; esac
}

core_is_present() {
    command_exists tachyon-core || [ -x /usr/bin/tachyon-core ]
}

sing_box_is_present() {
    [ -x /usr/bin/sing-box ] || [ -x /usr/sbin/sing-box ] || [ -x /opt/bin/sing-box ]
}

engine_is_present() {
    if release_is_tachyon_core_only; then
        core_is_present
    else
        sing_box_is_present
    fi
}

select_core_installation() {
    CORE_INSTALL_CHOICE=""
    ENGINE_INSTALL_CHOICE=""
    SING_BOX_INSTALL_VARIANT=""
    [ "$SKIP_ENGINE" -eq 1 ] && return 0

    if release_is_tachyon_core_only; then
        if [ "$ENGINE_INSTALL_REQUESTED" = "sing-box" ]; then
            err "Release $(effective_release_tag) supports tachyon-core only (use --tag <1.7.x> for sing-box)"
            return 1
        fi
        if [ -n "$SING_BOX_VARIANT_REQUESTED" ] && [ "$SING_BOX_VARIANT_REQUESTED" != "tachyon-core" ] && [ "$SING_BOX_VARIANT_REQUESTED" != "tachyon_core" ]; then
            err "Release $(effective_release_tag) supports tachyon-core only (--sing-box-variant $SING_BOX_VARIANT_REQUESTED requires < 1.8.0)"
            return 1
        fi
        if [ -n "$CORE_INSTALL_REQUESTED" ]; then
            CORE_INSTALL_CHOICE="$CORE_INSTALL_REQUESTED"
            ENGINE_INSTALL_CHOICE="tachyon-core"
            return 0
        fi
        if engine_is_present && core_is_present; then
            return 0
        fi
        if [ "$ASSUME_YES" -eq 1 ] || ! installer_is_interactive; then
            CORE_INSTALL_CHOICE="tachyon-core"
            ENGINE_INSTALL_CHOICE="tachyon-core"
            return 0
        fi
        printf '\ntachyon-core routing core is not installed.\n'
        printf 'Install tachyon-core? [Y/n]: '
        read -r _answer || _answer=""
        case "${_answer:-y}" in
            n|N|no|NO) CORE_INSTALL_CHOICE="" ;;
            *) CORE_INSTALL_CHOICE="tachyon-core"; ENGINE_INSTALL_CHOICE="tachyon-core" ;;
        esac
        return 0
    fi

    # Legacy releases (< 1.8.0): retain sing-box variant and tachyon-core selection
    if [ -n "$ENGINE_INSTALL_REQUESTED" ]; then
        case "$ENGINE_INSTALL_REQUESTED" in
            tachyon-core|tachyon_core)
                ENGINE_INSTALL_CHOICE="tachyon-core"
                SING_BOX_INSTALL_VARIANT="tachyon-core"
                CORE_INSTALL_CHOICE="tachyon-core"
                return 0
                ;;
            sing-box)
                ENGINE_INSTALL_CHOICE="sing-box"
                SING_BOX_INSTALL_VARIANT="${SING_BOX_VARIANT_REQUESTED:-stable}"
                return 0
                ;;
        esac
    fi
    engine_is_present && return 0
    if [ "$ASSUME_YES" -eq 1 ] || ! installer_is_interactive; then
        ENGINE_INSTALL_CHOICE="sing-box"
        SING_BOX_INSTALL_VARIANT="stable"
        return 0
    fi
    printf '\nRouting core is not installed. Choose routing core to install:\n'
    printf '  1) sing-box (official)\n'
    printf '  2) sing-box (tiny, minimal RAM footprint)\n'
    printf '  3) sing-box (extended, shtorm-7)\n'
    printf '  4) sing-box (extended-compressed, UPX)\n'
    printf '  5) sing-box (lx, Leadaxe)\n'
    printf '  6) tachyon-core\n'
    printf '  7) Skip (do not install routing core now)\n'
    printf 'Select [1-7, default: 1]: '
    read -r _choice || _choice=""
    case "$_choice" in
        2) ENGINE_INSTALL_CHOICE="sing-box"; SING_BOX_INSTALL_VARIANT="tiny" ;;
        3) ENGINE_INSTALL_CHOICE="sing-box"; SING_BOX_INSTALL_VARIANT="extended" ;;
        4) ENGINE_INSTALL_CHOICE="sing-box"; SING_BOX_INSTALL_VARIANT="extended-compressed" ;;
        5) ENGINE_INSTALL_CHOICE="sing-box"; SING_BOX_INSTALL_VARIANT="lx" ;;
        6) CORE_INSTALL_CHOICE="tachyon-core"; ENGINE_INSTALL_CHOICE="tachyon-core"; SING_BOX_INSTALL_VARIANT="tachyon-core" ;;
        7) ENGINE_INSTALL_CHOICE=""; SING_BOX_INSTALL_VARIANT="" ;;
        *) ENGINE_INSTALL_CHOICE="sing-box"; SING_BOX_INSTALL_VARIANT="stable" ;;
    esac
    return 0
}

decide_zram() {
    ZRAM_INSTALL_REQUESTED=0
    case "$ZRAM_INSTALL_OVERRIDE" in yes) ZRAM_INSTALL_REQUESTED=1; return 0 ;; no) return 0 ;; esac
    pkg_is_installed zram-swap && return 0
    _ram_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
    case "$_ram_kb" in *[!0-9]*|"") _ram_kb=0 ;; esac
    [ "$_ram_kb" -gt 0 ] && [ "$_ram_kb" -le 262144 ] || return 0
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then ZRAM_INSTALL_REQUESTED=1; return 0; fi
    printf 'Low RAM detected (%s MiB). Install zram-swap? [Y/n]: ' "$((_ram_kb / 1024))"
    read -r _answer || true
    case "$_answer" in n|N|no|NO) ;; *) ZRAM_INSTALL_REQUESTED=1 ;; esac
}

record_service_state() {
    pkg_is_installed tachyon && TACHYON_WAS_INSTALLED=1 || TACHYON_WAS_INSTALLED=0
    if ls /etc/rc.d/S*tachyon >/dev/null 2>&1; then TACHYON_WAS_ENABLED=1; fi
    if [ -x /usr/bin/tachyon ]; then
        _status="$TMP_DIR/status-before.json"
        if run_with_deadline 8 /usr/bin/tachyon get_status >"$_status" 2>/dev/null && grep -Eq '"running"[[:space:]]*:[[:space:]]*(1|true)' "$_status"; then
            TACHYON_WAS_RUNNING=1
        fi
    fi
}

snapshot_state() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    _stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo $$)"
    SNAPSHOT_DIR="/etc/tachyon/installer-backups/$_stamp"
    mkdir -p "$SNAPSHOT_DIR" || return 1
    chmod 0700 "$SNAPSHOT_DIR" 2>/dev/null || true
    for _f in /etc/config/tachyon; do
        [ -f "$_f" ] || continue
        cp -a "$_f" "$SNAPSHOT_DIR/$(basename "$_f")" || return 1
    done
    [ "$PKG_IS_APK" -eq 1 ] && [ -f /etc/apk/world ] && cp -a /etc/apk/world "$SNAPSHOT_DIR/apk-world" || true
    printf 'installed=%s\nrunning=%s\nenabled=%s\n' "$TACHYON_WAS_INSTALLED" "$TACHYON_WAS_RUNNING" "$TACHYON_WAS_ENABLED" >"$SNAPSHOT_DIR/state"
    prune_old_snapshots
    TX_ACTIVE=1
    ok "Recovery snapshot created: $SNAPSHOT_DIR"
}

# Keep only the newest few recovery snapshots. Every install creates one and
# nothing ever removed them, so the directory only grew - measured on 192.168.1.1
# with two sets, 7 files, 40 KB, and one more per install from then on. The
# snapshots are copies of /etc/config/tachyon, so they are flash writes that buy
# nothing after the previous few installs.
#
# Timestamp format is YYYYMMDD-HHMMSS, which sorts chronologically as a string, so
# `sort -r` gives newest first with no date parsing. BusyBox-safe throughout: the
# routers have no GNU date and no -printf.
prune_old_snapshots() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    _keep="${TACHYON_SNAPSHOT_KEEP:-3}"
    case "$_keep" in
        '' | *[!0-9]*) _keep=3 ;;
    esac
    [ "$_keep" -ge 1 ] 2>/dev/null || _keep=3
    [ -d /etc/tachyon/installer-backups ] || return 0
    _old="$(ls -1d /etc/tachyon/installer-backups/*/ 2>/dev/null | sort -r | tail -n "+$((_keep + 1))")"
    [ -n "$_old" ] || return 0
    # shellcheck disable=SC2086
    printf '%s\n' "$_old" | while read -r _d; do
        [ -n "$_d" ] && [ -d "$_d" ] && rm -rf "$_d"
    done
    return 0
}

restore_snapshot() {
    [ "$TX_ACTIVE" -eq 1 ] || return 0
    [ "$TX_COMMITTED" -eq 0 ] || return 0
    [ -n "$SNAPSHOT_DIR" ] && [ -d "$SNAPSHOT_DIR" ] || return 0
    warn "Restoring configuration from recovery snapshot"
    if [ -f "$SNAPSHOT_DIR/tachyon" ]; then
        cp -a "$SNAPSHOT_DIR/tachyon" /etc/config/tachyon 2>/dev/null || true
        chmod 0600 /etc/config/tachyon 2>/dev/null || true
    fi
    if [ "$PKG_IS_APK" -eq 1 ] && [ -f "$SNAPSHOT_DIR/apk-world" ]; then
        cp -a "$SNAPSHOT_DIR/apk-world" "$APK_WORLD_FILE" 2>/dev/null || true
    fi
    if [ "$TACHYON_WAS_INSTALLED" -eq 1 ] && [ -x /usr/bin/tachyon ]; then
        [ "$TACHYON_WAS_ENABLED" -eq 1 ] && /etc/init.d/tachyon enable >/dev/null 2>&1 || /etc/init.d/tachyon disable >/dev/null 2>&1 || true
        [ "$TACHYON_WAS_RUNNING" -eq 1 ] && run_logged_timeout tachyon-rollback-start 120 /usr/bin/tachyon start || true
    fi
}

is_protected_pid() {
    _candidate="$1"
    _p="$$"
    while [ -n "$_p" ] && [ "$_p" -gt 1 ] 2>/dev/null; do
        [ "$_candidate" = "$_p" ] && return 0
        _stat="$(cat "/proc/$_p/stat" 2>/dev/null || true)"
        [ -n "$_stat" ] || break
        _rest="${_stat#*) }"
        set -- $_rest
        _p="$2"
    done
    return 1
}

release_tachyon_init_lock() {
    [ -d /proc ] || return 0
    _killed=0
    for _fd in /proc/[0-9]*/fd/1000; do
        [ -e "$_fd" ] || continue
        _target="$(readlink "$_fd" 2>/dev/null || true)"
        case "$_target" in *procd_tachyon*|*tachyon*lock*) ;; *) continue ;; esac
        _pid="$(printf '%s' "$_fd" | cut -d/ -f3)"
        is_protected_pid "$_pid" && continue
        debug "Killing stale Tachyon init-lock holder pid=$_pid target=$_target"
        kill -KILL "$_pid" 2>/dev/null || true
        _killed=1
    done
    ps 2>/dev/null | grep -E '99-tachyon-wan|flock 1000|/etc/init.d/tachyon' | grep -v grep | awk '{print $1}' | while read -r _pid; do
        [ -n "$_pid" ] || continue
        is_protected_pid "$_pid" && continue
        kill -KILL "$_pid" 2>/dev/null || true
    done
    [ "$_killed" -eq 0 ] || sleep 1
}

check_name_resolution() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ -n "$(_resolve_effective_proxy)" ] || [ -n "${CUSTOM_MIRROR:-}" ]; then
        return 0
    fi
    command_exists nslookup || command_exists drill || return 0
    _resolved=1
    for _probe in "github.com" "raw.githubusercontent.com" "ghfast.top" "gh-proxy.com" "downloads.openwrt.org"; do
        if nslookup "$_probe" >/dev/null 2>&1 || drill "$_probe" >/dev/null 2>&1; then
            _resolved=0
            break
        fi
    done
    [ "$_resolved" -eq 0 ] && return 0
    err "Cannot resolve host names. Everything from here on will fail."
    err "Point dnsmasq at a reachable resolver, or check the WAN link, then run"
    err "the installer again."
    return 1
}

prepare_transaction() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ -x /usr/bin/tachyon ]; then
        msg "Stopping running Tachyon services"
        _t0="$(date +%s 2>/dev/null || echo 0)"
        run_logged_timeout tachyon-stop 45 /usr/bin/tachyon stop || true
        _t1="$(date +%s 2>/dev/null || echo 0)"
        ok "Tachyon services stopped in $((_t1 - _t0))s"
    fi
    for _legacy_steer in /etc/init.d/tachyon-steer-zapret /etc/init.d/steer; do
        if [ -f "$_legacy_steer" ]; then
            "$_legacy_steer" stop >/dev/null 2>&1 || true
            "$_legacy_steer" disable >/dev/null 2>&1 || true
            rm -f "$_legacy_steer" 2>/dev/null || true
        fi
    done
    rm -rf /etc/rc.d/*steer* /etc/steer /usr/lib/tachyon/steer /usr/sbin/steer /usr/bin/steer /var/run/tachyon/*steer* /tmp/*steer* 2>/dev/null || true
    nft delete table inet steer >/dev/null 2>&1 || true
    release_tachyon_init_lock
}


# Drop the listed packages from the world file so a later 'apk add' starts from
# a clean slate. Also used on the rollback path: the snapshot of the world file
# is taken before the legacy packages are removed, so restoring it verbatim
# would name packages this installer had just uninstalled, and every subsequent
# apk operation would fail with "no such package ... required by world[...]"
# (issue #85).
scrub_apk_world() {
    _scrub_list="${1:-$WORLD_SCRUB_PACKAGES}"
    [ -n "$_scrub_list" ] || return 0
    [ -f "$APK_WORLD_FILE" ] || return 0
    for _pkg in $_scrub_list; do
        # Match the bare name and the pinned forms. After a local .apk install
        # apk rewrites the entry with a version and hash constraint, so a live
        # world reads `tachyon><Q1xQ...=`, not `tachyon`. An anchored "^pkg$"
        # never matched that, so reinstalling over the package this installer
        # previously installed left the pin in place and the next apk add had to
        # satisfy a world entry describing a build that is no longer on the box.
        # ^pkg followed by end-of-line, or by any of the constraint operators
        # apk uses (space, <, >, =, ~), covers both.
        sed -i -E "/^${_pkg}([ \t<>=~].*)?\$/d" "$APK_WORLD_FILE" 2>/dev/null || true
    done
    debug "APK world file scrubbed: $_scrub_list"
}

# Release stale apk world entries before install so the solver starts clean.
# Reinstalling over a Tachyon that a previous run installed leaves world entries
# like `tachyon><Q1xQ...=`, and the new package has to satisfy a constraint
# describing a build that is no longer on the box (issue #85, #120).
resolve_legacy_conflicts_before_install() {
    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    if grep -qE "^ip-tiny([ \t<>=~].*)?$" "$APK_WORLD_FILE" 2>/dev/null; then
        msg "Releasing conflicting ip-tiny from apk world"
        scrub_apk_world "ip-tiny"
    fi

    # Release this installer's own pinned entries.
    _pinned=""
    for _pkg in $WORLD_SCRUB_PACKAGES; do
        if grep -qE "^${_pkg}[ \t<>=~]" "$APK_WORLD_FILE" 2>/dev/null; then
            _pinned="$_pinned $_pkg"
        fi
    done
    if [ -n "$_pinned" ]; then
        msg "Releasing pinned apk world entries:$_pinned"
        scrub_apk_world "$WORLD_SCRUB_PACKAGES"
    fi
    return 0
}

download_release() {
    TACHYON_SHA256_FILE="$TMP_DIR/sha256sums.txt"
    TACHYON_BACKEND_FILE="$TMP_DIR/$TACHYON_BACKEND_NAME"
    TACHYON_APP_FILE="$TMP_DIR/$TACHYON_APP_NAME"
    [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would download and verify $TACHYON_RELEASE_TAG"; return 0; }

    # Phase 1: Download manifest
    download_with_retry "$TACHYON_SHA256_URL" "$TACHYON_SHA256_FILE" sha256sums.txt sha256 || return 1
    # Phase 2: Download package payloads after manifest integrity is proven
    download_with_retry "$TACHYON_BACKEND_URL" "$TACHYON_BACKEND_FILE" "$TACHYON_BACKEND_NAME" pkg || return 1
    download_with_retry "$TACHYON_APP_URL" "$TACHYON_APP_FILE" "$TACHYON_APP_NAME" pkg || return 1
    if [ "$TACHYON_I18N_REQUESTED" -eq 1 ]; then
        TACHYON_I18N_FILE="$TMP_DIR/$TACHYON_I18N_NAME"
        download_with_retry "$TACHYON_I18N_URL" "$TACHYON_I18N_FILE" "$TACHYON_I18N_NAME" pkg || return 1
    fi

    # Phase 3: SHA256 checksum verification
    verify_one() {
        _file="$1"; _name="$(basename "$_file")"
        _expected="$(awk -v n="$_name" '$2 == n || $2 == "*" n {print $1; exit}' "$TACHYON_SHA256_FILE")"
        [ -n "$_expected" ] || { err "Checksum entry missing for $_name"; return 1; }
        _actual="$(sha256sum "$_file" 2>/dev/null | awk '{print $1}')"
        [ "$_expected" = "$_actual" ] || { err "Checksum mismatch for $_name"; return 1; }
    }
    verify_one "$TACHYON_BACKEND_FILE" || return 1
    verify_one "$TACHYON_APP_FILE" || return 1
    [ -z "$TACHYON_I18N_FILE" ] || verify_one "$TACHYON_I18N_FILE" || return 1
    ok "Release checksums verified"

    # Phase 4: Package payload metadata / integrity verification
    verify_package_metadata() {
        _pkg="$1"
        [ -r "$_pkg" ] || { err "Package archive $(basename "$_pkg") is unreadable"; return 1; }
        _sz="$(wc -c < "$_pkg" 2>/dev/null || echo 0)"
        [ "$_sz" -gt 1024 ] || { err "Package archive $(basename "$_pkg") is suspiciously small (${_sz}B)"; return 1; }
        _magic="$(head -c 4 "$_pkg" 2>/dev/null || true)"
        if [ "$PKG_IS_APK" -eq 1 ]; then
            case "$_magic" in
                ADBd*|*ADBd*) ;;
                *)
                    tar -ztf "$_pkg" >/dev/null 2>&1 || {
                        err "Package archive $(basename "$_pkg") is not a valid APK package"
                        return 1
                    }
                    ;;
            esac
        else
            case "$_magic" in
                "!<ar"*) ;;
                *)
                    tar -ztf "$_pkg" >/dev/null 2>&1 || {
                        err "Package archive $(basename "$_pkg") is not a valid IPK package"
                        return 1
                    }
                    ;;
            esac
        fi
    }
    verify_package_metadata "$TACHYON_BACKEND_FILE" || return 1
    verify_package_metadata "$TACHYON_APP_FILE" || return 1
    [ -z "$TACHYON_I18N_FILE" ] || verify_package_metadata "$TACHYON_I18N_FILE" || return 1
    ok "Package archive metadata verified"
}

pkg_install_local_bundle() {
    [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would install local package transaction: $*"; return 0; }
    if [ "$PKG_IS_APK" -eq 1 ]; then
        heal_apk_world
        if apk_can_install_local_offline "$@"; then
            set -- --force-overwrite --no-network --repositories-file /dev/null "$@"
        else
            prepare_apk_repositories
            if [ -n "$APK_FILTERED_REPOS_FILE" ] && [ ! -s "$APK_FILTERED_REPOS_FILE" ]; then
                apk_satisfy_missing_local_deps "$@"
                set -- --force-overwrite --no-network --repositories-file /dev/null "$@"
            elif [ -n "$APK_FILTERED_REPOS_FILE" ]; then
                if apk_run apk-transaction "$PACKAGE_TIMEOUT_SECONDS" add --allow-untrusted --force-overwrite --force-missing-repositories --timeout 15 --repositories-file "$APK_FILTERED_REPOS_FILE" "$@"; then
                    return 0
                fi
                warn "Online APK transaction failed; satisfying missing dependencies offline"
                apk_satisfy_missing_local_deps "$@"
                set -- --force-overwrite --no-network --repositories-file /dev/null "$@"
            else
                if apk_run apk-transaction "$PACKAGE_TIMEOUT_SECONDS" add --allow-untrusted --force-overwrite --force-missing-repositories --timeout 15 "$@"; then
                    return 0
                fi
                warn "Online APK transaction failed; satisfying missing dependencies offline"
                apk_satisfy_missing_local_deps "$@"
                set -- --force-overwrite --no-network --repositories-file /dev/null "$@"
            fi
        fi
        apk_run apk-transaction "$PACKAGE_TIMEOUT_SECONDS" add --allow-untrusted "$@"
    else
        run_logged_timeout opkg-transaction "$PACKAGE_TIMEOUT_SECONDS" opkg install --force-reinstall --force-overwrite --force-downgrade --force-depends "$@"
    fi
}

install_core_transaction() {
    set -- "$TACHYON_BACKEND_FILE" "$TACHYON_APP_FILE"
    [ -z "$TACHYON_I18N_FILE" ] || set -- "$@" "$TACHYON_I18N_FILE"
    msg "Installing Tachyon package transaction"
    pkg_install_local_bundle "$@"
}

install_zram_if_requested() {
    [ "$ZRAM_INSTALL_REQUESTED" -eq 1 ] || return 0
    ensure_package zram-swap || { warn "Could not install zram-swap; continuing"; return 0; }
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -x /etc/init.d/zram ] && /etc/init.d/zram enable >/dev/null 2>&1 || true
    [ -x /etc/init.d/zram ] && /etc/init.d/zram start >/dev/null 2>&1 || true
}

write_if_changed() {
    _wic_path="$1"
    _wic_content="$2"
    [ "$DRY_RUN" -eq 1 ] && return 0
    _wic_dir="$(dirname "$_wic_path")"
    [ -d "$_wic_dir" ] || mkdir -p "$_wic_dir" 2>/dev/null || return 1
    _wic_tmp="${_wic_path}.tmp.$$"
    printf '%s' "$_wic_content" >"$_wic_tmp" || { rm -f "$_wic_tmp" 2>/dev/null || true; return 1; }
    if [ -f "$_wic_path" ] && cmp -s "$_wic_path" "$_wic_tmp" 2>/dev/null; then
        rm -f "$_wic_tmp" 2>/dev/null || true
        return 0
    fi
    mv -f "$_wic_tmp" "$_wic_path"
}

ensure_tcp_bbr_best_effort() {
    if [ "$DRY_RUN" -eq 1 ]; then
        msg "[dry-run] would probe/install kmod-tcp-bbr best-effort and configure TCP BBR if supported"
        return 0
    fi
    _bbr_uci="1"
    if command_exists uci; then
        _bbr_uci="$(uci -q get tachyon.settings.tcp_bbr 2>/dev/null || echo '1')"
    fi
    [ "$_bbr_uci" = "0" ] && return 0

    _avail_cc="${TACHYON_PROC_TCP_AVAIL_CC:-/proc/sys/net/ipv4/tcp_available_congestion_control}"
    _conf_file="${TACHYON_SYSCTL_BBR_CONF:-/etc/sysctl.d/99-tachyon-bbr.conf}"

    if ! grep -qw bbr "$_avail_cc" 2>/dev/null; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    if ! grep -qw bbr "$_avail_cc" 2>/dev/null; then
        if ensure_package kmod-tcp-bbr; then
            modprobe tcp_bbr >/dev/null 2>&1 || true
        else
            warn "kmod-tcp-bbr is unavailable for the current kernel; skipping kernel TCP BBR (userspace BBR remains active)"
        fi
    fi
    if ! grep -qw bbr "$_avail_cc" 2>/dev/null; then
        msg "Kernel TCP BBR is unavailable; skipping 99-tachyon-bbr.conf (userspace BBR remains active)"
        return 0
    fi

    modprobe sch_fq >/dev/null 2>&1 || true
    _qdisc="fq_codel"
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        _qdisc="fq"
    else
        sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    fi
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    _desired="$(printf 'net.core.default_qdisc=%s\nnet.ipv4.tcp_congestion_control=bbr\n' "$_qdisc")"
    write_if_changed "$_conf_file" "$_desired" || warn "Could not write $_conf_file"
    return 0
}

# Non-destructive backup of external configs before any cleanup.
# Saves copies into /etc/tachyon/external-configs-backup/<component>/ without
# overwriting existing backups (cp -n).
backup_external_configs() {
    _bkup_root="/etc/tachyon/external-configs-backup"
    for _comp in zapret zapret2 byedpi wdtt qwdtt olcrtc sing-box; do
        _comp_dir="$_bkup_root/$_comp"
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
            wdtt)
                _srcs="/etc/config/wdtt /etc/wdtt"
                ;;
            qwdtt)
                _srcs="/etc/config/qwdtt /etc/qwdtt"
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
        [ "$_has_src" -eq 1 ] || continue
        mkdir -p "$_comp_dir" 2>/dev/null || continue
        for _s in $_srcs; do
            [ -e "$_s" ] || continue
            _base="$(basename "$_s")"
            if [ -d "$_s" ]; then
                [ -d "$_comp_dir/$_base" ] || cp -a "$_s" "$_comp_dir/$_base" 2>/dev/null || true
            else
                [ -f "$_comp_dir/$_base" ] || cp -a "$_s" "$_comp_dir/$_base" 2>/dev/null || true
            fi
        done
    done
}

# Check whether a component was installed/managed by Tachyon. Returns 0 (true)
# if a Tachyon marker exists, 1 (false) if the component is standalone.
is_tachyon_managed_component() {
    _comp="$1"
    # Check "Tachyon managed" marker in init script
    if [ -f "/etc/init.d/$_comp" ] && grep -q "Tachyon managed" "/etc/init.d/$_comp" 2>/dev/null; then
        return 0
    fi
    # Check component-backups marker
    [ -d "/etc/tachyon/component-backups/$_comp" ] && return 0
    # Check supervisor runtime dir
    [ -d "/var/run/tachyon/$_comp" ] && return 0
    return 1
}

# Selectively stop/disable/remove a component only if Tachyon-managed.
selective_cleanup_component() {
    _comp="$1"
    _svc="${2:-$_comp}"
    is_tachyon_managed_component "$_comp" || return 0
    if [ -f "/etc/init.d/$_svc" ]; then
        "/etc/init.d/$_svc" stop >/dev/null 2>&1 || true
        "/etc/init.d/$_svc" disable >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$_svc" 2>/dev/null || true
    fi
}

migrate_legacy_engine_files() {
    [ "$DRY_RUN" -eq 1 ] && return 0

    # Non-destructive backup of all external configs first
    backup_external_configs

    # Selective sing-box cleanup: only if Tachyon-managed
    _sing_box_managed=0
    if [ -f /etc/init.d/sing-box ] && grep -q "Tachyon managed" /etc/init.d/sing-box 2>/dev/null; then
        _sing_box_managed=1
    fi
    [ -f /etc/tachyon/sing-box-version ] && _sing_box_managed=1
    [ -f /etc/tachyon/sing-box-variant ] && _sing_box_managed=1
    [ -d /etc/tachyon/component-backups/sing_box ] && _sing_box_managed=1

    if [ "$_sing_box_managed" -eq 1 ]; then
        if [ -f /etc/init.d/sing-box ]; then
            /etc/init.d/sing-box stop >/dev/null 2>&1 || true
            /etc/init.d/sing-box disable >/dev/null 2>&1 || true
            rm -f /etc/init.d/sing-box /etc/rc.d/*sing-box* 2>/dev/null || true
        fi
        killall -9 sing-box >/dev/null 2>&1 || true

        for _legacy_pkg in sing-box sing-box-extended sing-box-tiny sing-box-lx; do
            if [ "$PKG_IS_APK" -eq 1 ]; then
                if grep -q "^P:${_legacy_pkg}$" "$APK_INSTALLED_DB" 2>/dev/null; then
                    scrub_apk_world "$_legacy_pkg"
                    apk del --no-network --repositories-file /dev/null "$_legacy_pkg" >/dev/null 2>&1 || true
                fi
            else
                if opkg status "$_legacy_pkg" 2>/dev/null | grep -q '^Status:'; then
                    opkg remove --force-depends "$_legacy_pkg" >/dev/null 2>&1 || true
                fi
            fi
        done

        if [ -d /etc/sing-box ]; then
            mkdir -p /etc/tachyon-core 2>/dev/null || true
            for _legacy_item in /etc/sing-box/*; do
                [ -e "$_legacy_item" ] || continue
                _base="$(basename "$_legacy_item")"
                if [ ! -e "/etc/tachyon-core/$_base" ]; then
                    cp -a "$_legacy_item" "/etc/tachyon-core/$_base" 2>/dev/null || true
                fi
            done
            rm -rf /etc/sing-box 2>/dev/null || true
        fi

        rm -f /usr/bin/sing-box /etc/tachyon/sing-box-variant /etc/tachyon/sing-box-version /etc/tachyon/mem_scale 2>/dev/null || true
        rm -rf /tmp/sing-box /usr/share/sing-box /var/run/sing-box* 2>/dev/null || true
    fi

    # Tachyon's own internal steer subsystem: always clean up (these are ours)
    for _steer_svc in tachyon-steer-zapret steer; do
        if [ -f "/etc/init.d/${_steer_svc}" ]; then
            "/etc/init.d/${_steer_svc}" stop >/dev/null 2>&1 || true
            "/etc/init.d/${_steer_svc}" disable >/dev/null 2>&1 || true
            rm -f "/etc/init.d/${_steer_svc}" 2>/dev/null || true
        fi
    done
    rm -rf /etc/rc.d/*steer* /etc/steer /usr/lib/tachyon/steer /usr/sbin/steer /usr/bin/steer /var/run/tachyon/*steer* /tmp/*steer* 2>/dev/null || true

    # Selective cleanup of external legacy provider components
    _managed_legacy_pkgs=""
    for _comp in zapret zapret2 byedpi wdtt-client qwdtt olcrtc; do
        # Map service name to package/component name for marker check
        _comp_marker="$_comp"
        case "$_comp" in wdtt-client) _comp_marker="wdtt" ;; esac
        selective_cleanup_component "$_comp_marker" "$_comp"
        if is_tachyon_managed_component "$_comp_marker"; then
            case "$_comp" in wdtt-client) _managed_legacy_pkgs="$_managed_legacy_pkgs wdtt" ;; *) _managed_legacy_pkgs="$_managed_legacy_pkgs $_comp" ;; esac
        fi
    done

    _managed_tailscale=0
    if [ -f /etc/init.d/tailscale ] && grep -q "Tachyon managed" /etc/init.d/tailscale 2>/dev/null; then
        _managed_tailscale=1
        /etc/init.d/tailscale stop >/dev/null 2>&1 || true
        /etc/init.d/tailscale disable >/dev/null 2>&1 || true
        rm -f /etc/init.d/tailscale /etc/rc.d/*tailscale* 2>/dev/null || true
    fi

    # Only kill processes of Tachyon-managed components
    killall -9 tachyon-core steer >/dev/null 2>&1 || true
    for _proc in nfqws nfqws2 ciadpi qwdtt-client wdtt olcrtc; do
        _proc_comp="$_proc"
        case "$_proc" in nfqws|nfqws2) _proc_comp="zapret" ;; ciadpi) _proc_comp="byedpi" ;; qwdtt-client) _proc_comp="qwdtt" ;; esac
        is_tachyon_managed_component "$_proc_comp" && killall -9 "$_proc" >/dev/null 2>&1 || true
    done

    # Remove packages only for Tachyon-managed components
    [ "$_managed_tailscale" -eq 1 ] && _managed_legacy_pkgs="$_managed_legacy_pkgs tailscale"
    for _legacy_pkg in $_managed_legacy_pkgs; do
        if [ "$PKG_IS_APK" -eq 1 ]; then
            if grep -q "^P:${_legacy_pkg}$" "$APK_INSTALLED_DB" 2>/dev/null; then
                scrub_apk_world "$_legacy_pkg"
                apk del --no-network --repositories-file /dev/null "$_legacy_pkg" >/dev/null 2>&1 || true
            fi
        else
            if opkg status "$_legacy_pkg" 2>/dev/null | grep -q '^Status:'; then
                opkg remove --force-depends "$_legacy_pkg" >/dev/null 2>&1 || true
            fi
        fi
    done

    # Remove rc.d symlinks and runtime state only for Tachyon-managed components
    for _comp in zapret zapret2 byedpi wdtt qwdtt olcrtc; do
        if is_tachyon_managed_component "$_comp"; then
            rm -f /etc/rc.d/*"$_comp"* 2>/dev/null || true
        fi
    done

    # Remove binaries, configs, and state only for Tachyon-managed components
    if is_tachyon_managed_component "zapret"; then
        rm -rf /opt/zapret /etc/config/zapret /var/run/tachyon/zapret* 2>/dev/null || true
        rm -f /usr/bin/nfqws /usr/bin/nfqws2 2>/dev/null || true
        rm -rf /etc/tachyon/component-backups/zapret 2>/dev/null || true
        rm -f /var/run/tachyon/component-update-checks/zapret.json 2>/dev/null || true
    fi
    if is_tachyon_managed_component "zapret2"; then
        rm -rf /opt/zapret2 /etc/config/zapret2 /var/run/tachyon/zapret2* 2>/dev/null || true
        rm -rf /etc/tachyon/component-backups/zapret2 2>/dev/null || true
        rm -f /var/run/tachyon/component-update-checks/zapret2.json 2>/dev/null || true
    fi
    if is_tachyon_managed_component "byedpi"; then
        rm -rf /etc/config/byedpi /var/run/tachyon/byedpi 2>/dev/null || true
        rm -f /usr/bin/ciadpi 2>/dev/null || true
        rm -rf /etc/tachyon/component-backups/byedpi 2>/dev/null || true
        rm -f /var/run/tachyon/component-update-checks/byedpi.json 2>/dev/null || true
    fi
    if is_tachyon_managed_component "wdtt"; then
        rm -rf /etc/wdtt /etc/config/wdtt /var/run/tachyon/wdtt 2>/dev/null || true
        rm -f /usr/bin/wdtt /usr/sbin/wdtt-genlists /usr/sbin/wdtt-resolve 2>/dev/null || true
        rm -rf /etc/tachyon/component-backups/wdtt 2>/dev/null || true
        rm -f /var/run/tachyon/component-update-checks/wdtt.json 2>/dev/null || true
    fi
    if is_tachyon_managed_component "qwdtt"; then
        rm -rf /etc/qwdtt /var/run/qwdtt 2>/dev/null || true
        rm -f /usr/bin/qwdtt-client 2>/dev/null || true
    fi
    if is_tachyon_managed_component "olcrtc"; then
        rm -rf /etc/olcrtc /etc/config/olcrtc /var/run/tachyon/olcrtc 2>/dev/null || true
        rm -f /usr/bin/olcrtc 2>/dev/null || true
        rm -f /var/run/tachyon/component-update-checks/olcrtc.json 2>/dev/null || true
    fi
    if [ "$_managed_tailscale" -eq 1 ]; then
        rm -rf /var/run/tachyon/tailscale /etc/tachyon/tailscale/*/native 2>/dev/null || true
        rm -rf /etc/tachyon/component-backups/tailscale 2>/dev/null || true
        rm -f /etc/tachyon/dnsmasq-tailscale.servers /tmp/dnsmasq.d/tachyon-tailscale.conf 2>/dev/null || true
    fi

    if command_exists nft; then
        nft delete table inet steer >/dev/null 2>&1 || true
        nft delete table inet tachyon_tailscale >/dev/null 2>&1 || true
        for _legacy_tbl in zapret zapret2; do
            if is_tachyon_managed_component "$_legacy_tbl"; then
                nft delete table inet "$_legacy_tbl" >/dev/null 2>&1 || true
                nft delete table ip "$_legacy_tbl" >/dev/null 2>&1 || true
                nft delete table ip6 "$_legacy_tbl" >/dev/null 2>&1 || true
            fi
        done
    fi
    return 0
}


install_selected_core() {
    [ -n "$CORE_INSTALL_CHOICE" ] || [ -n "$ENGINE_INSTALL_CHOICE" ] || [ -n "$SING_BOX_INSTALL_VARIANT" ] || return 0
    [ -x /usr/bin/tachyon ] || return 1

    if release_is_tachyon_core_only || [ "$ENGINE_INSTALL_CHOICE" = "tachyon-core" ]; then
        [ -n "$CORE_INSTALL_CHOICE" ] || [ "$ENGINE_INSTALL_CHOICE" = "tachyon-core" ] || return 0
        [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would install tachyon-core"; return 0; }
        msg "Installing tachyon-core"
        run_logged_timeout tachyon-core "$PACKAGE_TIMEOUT_SECONDS" /usr/bin/tachyon component_action tachyon-core install || return 1
        return 0
    fi

    local _var="${SING_BOX_INSTALL_VARIANT:-stable}"
    [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would install sing-box ($_var)"; return 0; }
    msg "Installing sing-box ($_var)"
    run_logged_timeout "sing-box-${_var}" "$PACKAGE_TIMEOUT_SECONDS" /usr/bin/tachyon component_action "sing-box-${_var}" install || {
        err "Failed to install sing-box variant ${_var}"
        return 1
    }
}

restore_service_intent() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -x /etc/init.d/tachyon ] || return 1
    if [ "$TACHYON_WAS_INSTALLED" -eq 1 ]; then
        if [ "$TACHYON_WAS_ENABLED" -eq 1 ]; then /etc/init.d/tachyon enable >/dev/null 2>&1 || true; else /etc/init.d/tachyon disable >/dev/null 2>&1 || true; fi
        if [ "$TACHYON_WAS_RUNNING" -eq 1 ]; then
            msg "Starting Tachyon service (DNS, nft rules, tachyon-core — usually 20-40s)"
            _t0="$(date +%s 2>/dev/null || echo 0)"
            run_logged_timeout tachyon-start 120 /usr/bin/tachyon start || return 1
            _t1="$(date +%s 2>/dev/null || echo 0)"
            ok "Tachyon service started in $((_t1 - _t0))s"
        else
            msg "Tachyon was stopped before install; keeping it stopped"
            run_logged_timeout tachyon-stop 45 /usr/bin/tachyon stop || true
        fi
    else
        msg "First Tachyon launch (DNS, nft rules, tachyon-core — usually 20-40s)"
        /etc/init.d/tachyon enable >/dev/null 2>&1 || true
        _t0="$(date +%s 2>/dev/null || echo 0)"
        run_logged_timeout tachyon-start 120 /usr/bin/tachyon start || true
        _t1="$(date +%s 2>/dev/null || echo 0)"
        ok "Tachyon service started in $((_t1 - _t0))s"
    fi
}

healthcheck() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    msg "Running installation healthcheck"
    msg "Verifying package registration"
    pkg_is_installed tachyon || { err "tachyon package is not registered"; return 1; }
    pkg_is_installed luci-app-tachyon || { err "luci-app-tachyon package is not registered"; return 1; }
    msg "Verifying runtime files and configuration"
    [ -x /usr/bin/tachyon ] || { err "/usr/bin/tachyon is missing"; return 1; }
    [ -r /usr/lib/tachyon/core/constants.uc ] || { err "Tachyon runtime is incomplete"; return 1; }
    [ -f /usr/share/luci/menu.d/luci-app-tachyon.json ] || { err "LuCI menu file is missing"; return 1; }
    [ -r /etc/config/tachyon ] || { err "Tachyon UCI config is missing"; return 1; }
    chmod 0600 /etc/config/tachyon 2>/dev/null || true
    msg "Verifying installed version matches $TACHYON_RELEASE_TAG"
    _version="$(/usr/bin/tachyon get_system_info 2>/dev/null | sed -n 's/.*"tachyon_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$_version" ] && [ "$_version" != "$TACHYON_RELEASE_TAG" ]; then
        err "Installed runtime reports version $_version, expected $TACHYON_RELEASE_TAG"
        return 1
    fi
    msg "Verifying ucode runtime load"
    ucode -L /usr/lib/tachyon -e 'require("core.common");' >/dev/null 2>&1 || { err "ucode cannot load Tachyon runtime"; return 1; }
    ok "Healthcheck passed"
}

commit_transaction() {
    TX_COMMITTED=1
    TX_ACTIVE=0
    [ -n "$SNAPSHOT_DIR" ] && printf '%s\n' "$TACHYON_RELEASE_TAG" >"$SNAPSHOT_DIR/installed-release" 2>/dev/null || true
}

cleanup() {
    if [ "$TX_ACTIVE" -eq 1 ] && [ "$TX_COMMITTED" -eq 0 ]; then restore_snapshot; fi
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true
    release_lock
}

on_hup() { exit 129; }
on_int() { exit 130; }
on_term() { exit 143; }
# stdout/stderr closed (ssh/session drop): ignore further SIGPIPE and run
# EXIT cleanup instead of dying mid-transaction with a stale lock
on_pipe() { trap '' PIPE; exit 141; }

fail() {
    err "$1"
    err "Installer log: $LOG_FILE"
    exit 1
}

banner() {
    [ "$QUIET" -eq 1 ] && return 0
    printf '\n%s%sTachyon Installer%s v%s\n' "$C_CYAN" "$C_BOLD" "$C_RESET" "$INSTALLER_VERSION"
    printf 'Reliable OpenWrt install / update / repair\n\n'
}

is_entware_env() {
    [ -r /opt/etc/entware_release ] || [ -x /opt/bin/opkg ]
}

is_keenetic_or_netcraze() {
    if command_exists ndmc || [ -d /proc/ndm ]; then
        return 0
    fi
    for _kn_file in /tmp/sysinfo/model /proc/device-tree/model /etc/openwrt_release /etc/os-release /opt/etc/entware_release; do
        [ -r "$_kn_file" ] || continue
        if grep -qiE 'keenetic|netcraze|netcreaze|ndms' "$_kn_file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

system_preflight() {
    if [ ! -r /etc/openwrt_release ] && [ ! -r /etc/os-release ] && ! is_entware_env && ! is_keenetic_or_netcraze; then
        err "This installer supports OpenWrt only"
        return 1
    fi
    _release="$(read_openwrt_release_value DISTRIB_RELEASE)"
    _major="$(printf '%s' "$_release" | sed 's/[^0-9].*$//')"
    case "$_major" in *[!0-9]*|"") _major=0 ;; esac
    [ "$_major" -lt 15 ] || [ "$_major" -ge 23 ] || { err "OpenWrt 23.05 or newer is required"; return 1; }
    if is_keenetic_or_netcraze; then
        msg "Detected Keenetic / Netcraze environment"
    fi
    check_storage_preflight
}

print_plan() {
    msg "Release: ${TACHYON_RELEASE_TAG} (${PKG_MANAGER})"
    [ "$TACHYON_I18N_REQUESTED" -eq 1 ] && msg "Russian LuCI translation: yes" || msg "Russian LuCI translation: no"
    if release_is_tachyon_core_only; then
        if [ -n "$CORE_INSTALL_CHOICE" ]; then
            msg "Routing core: $CORE_INSTALL_CHOICE"
        else
            msg "Routing core: keep existing / skip"
        fi
    else
        if [ -n "$ENGINE_INSTALL_CHOICE" ]; then
            if [ "$ENGINE_INSTALL_CHOICE" = "tachyon-core" ]; then
                msg "Routing core: tachyon-core"
            elif [ -n "$SING_BOX_INSTALL_VARIANT" ]; then
                msg "Routing core: sing-box ($SING_BOX_INSTALL_VARIANT)"
            else
                msg "Routing core: sing-box"
            fi
        else
            msg "Routing core: keep existing configuration"
        fi
    fi
    [ "$ZRAM_INSTALL_REQUESTED" -eq 1 ] && msg "zram-swap: install" || true
}

main() {
    trap cleanup EXIT
    trap on_hup HUP
    trap on_int INT
    trap on_term TERM
    trap on_pipe PIPE

    parse_args "$@" || exit $?
    _export_proxy_env
    START_TIME="$(date +%s 2>/dev/null || echo 0)"
    : >"$LOG_FILE" 2>/dev/null || true

    acquire_lock || exit 1
    check_root || fail "Root privileges are required"
    init_tmp_dir || fail "Could not create temporary directory"
    detect_fetcher || fail "No download client available"
    detect_package_manager || fail "No supported package manager available"
    banner

    sync_time
    msg "Checking system requirements"
    system_preflight || fail "System preflight failed"

    msg "Bootstrapping ucode runtime"
    ensure_bootstrap_ucode_runtime || fail "Could not bootstrap ucode runtime"
    ensure_bootstrap_fetcher
    msg "Detecting language and release selection"
    detect_language_and_i18n
    decide_zram
    record_service_state
    check_name_resolution || fail "Name resolution is broken - see the message above"
    select_release_version

    msg "Resolving release metadata"
    resolve_release || fail "Could not resolve Tachyon release"
    check_tmp_for_downloads || fail "Temporary storage preflight failed"

    msg "Detecting routing core configuration"
    select_core_installation || fail "Incompatible engine selection for release $TACHYON_RELEASE_TAG"
    print_plan
    msg "Downloading release files"
    download_release || fail "Release download or verification failed"

    msg "Checking runtime dependencies"
    ensure_runtime_dependencies || fail "Could not install Tachyon dependencies"
    msg "Creating recovery snapshot"
    snapshot_state || fail "Could not create recovery snapshot"
    msg "Preparing package transaction"
    prepare_transaction || fail "Could not prepare package transaction"
    resolve_legacy_conflicts_before_install
    install_core_transaction || fail "Tachyon package transaction failed"
    if release_is_tachyon_core_only; then
        migrate_legacy_engine_files
    fi
    install_zram_if_requested
    ensure_tcp_bbr_best_effort
    install_selected_core || fail "Routing core installation failed"
    msg "Restoring service state"
    restore_service_intent || fail "Could not restore Tachyon service state"
    healthcheck || fail "Installed Tachyon did not pass healthcheck"
    commit_transaction

    _end="$(date +%s 2>/dev/null || echo 0)"
    _elapsed=$((_end - START_TIME)); [ "$_elapsed" -ge 0 ] 2>/dev/null || _elapsed=0
    ok "Tachyon ${TACHYON_RELEASE_TAG} installed successfully in ${_elapsed}s"
    msg "Log: $LOG_FILE"
    [ -n "$SNAPSHOT_DIR" ] && msg "Recovery snapshot: $SNAPSHOT_DIR" || true
}

if [ "${TACHYON_INSTALLER_TEST:-0}" != "1" ]; then
    main "$@"
fi
