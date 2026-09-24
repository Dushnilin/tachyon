#!/bin/sh
# shellcheck shell=dash

INSTALLER_VERSION="3.1.0"
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
PKG_MANAGER=""
PKG_IS_APK=0
PACKAGE_INDEX_UPDATED=0
START_TIME="0"
TX_ACTIVE=0
TX_COMMITTED=0
TACHYON_WAS_INSTALLED=0
TACHYON_WAS_RUNNING=0
TACHYON_WAS_ENABLED=0
INSTALLER_LANG="en"
TACHYON_I18N_REQUESTED=0
SING_BOX_INSTALL_VARIANT=""
ZRAM_INSTALL_REQUESTED=0

ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
QUIET=0
SKIP_SING_BOX=0
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

ESC="$(printf '\033')"
if [ -t 1 ] 2>/dev/null && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RESET="${ESC}[0m"; C_BOLD="${ESC}[1m"; C_RED="${ESC}[31;1m"
    C_GREEN="${ESC}[32;1m"; C_YELLOW="${ESC}[33;1m"; C_CYAN="${ESC}[36;1m"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

log_line() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-------------------')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

msg() {
    log_line "INFO  $1"
    [ "$QUIET" -eq 1 ] || printf '  %s%s%s\n' "$C_CYAN" "$1" "$C_RESET"
}

ok() {
    log_line "OK    $1"
    [ "$QUIET" -eq 1 ] || printf '  %s%s✓%s %s\n' "$C_GREEN" "$C_BOLD" "$C_RESET" "$1"
}

warn() {
    log_line "WARN  $1"
    printf '  %s%s⚠%s %s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET" "$1" >&2
}

err() {
    log_line "ERROR $1"
    printf '  %s%s✗%s %s\n' "$C_RED" "$C_BOLD" "$C_RESET" "$1" >&2
}

debug() {
    log_line "DEBUG $1"
    [ "$VERBOSE" -eq 1 ] && printf '  [debug] %s\n' "$1" >&2 || true
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
      --tag X.Y.Z       Install an exact published release
      --channel NAME    stable (default) or beta
      --skip-sing-box   Do not install sing-box when none is present
      --zram            Install zram-swap
      --no-zram         Never install zram-swap
      --version         Print installer version
  -h, --help            Show this help

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
            --skip-sing-box|--no-sing-box) SKIP_SING_BOX=1 ;;
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
    case "$RELEASE_TAG_REQUESTED" in
        "") ;;
        *[!0-9.]*|*.*.*.*|.*|*.) err "Invalid --tag value: $RELEASE_TAG_REQUESTED"; return 2 ;;
    esac
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
    ) &
    _watch_pid=$!
    wait "$_cmd_pid"
    _rc=$?
    kill "$_watch_pid" 2>/dev/null || true
    wait "$_watch_pid" 2>/dev/null || true
    return "$_rc"
}

run_logged() {
    _tag="$1"; shift
    _out="$TMP_DIR/cmd.$$.log"
    log_line "EXEC  [$_tag] $*"
    "$@" >"$_out" 2>&1
    _rc=$?
    if [ -s "$_out" ]; then
        while IFS= read -r _line; do log_line "  [$_tag] $_line"; done <"$_out"
    fi
    if [ "$_rc" -ne 0 ] && [ "$VERBOSE" -eq 1 ]; then cat "$_out" >&2; fi
    rm -f "$_out"
    return "$_rc"
}

run_logged_timeout() {
    _tag="$1"; _seconds="$2"; shift 2
    _out="$TMP_DIR/cmd.$$.log"
    log_line "EXEC  [$_tag] (deadline ${_seconds}s) $*"
    run_with_deadline "$_seconds" "$@" >"$_out" 2>&1
    _rc=$?
    if [ -s "$_out" ]; then
        while IFS= read -r _line; do log_line "  [$_tag] $_line"; done <"$_out"
    fi
    if [ "$_rc" -ne 0 ] && [ "$VERBOSE" -eq 1 ]; then cat "$_out" >&2; fi
    rm -f "$_out"
    return "$_rc"
}

detect_fetcher() {
    if command_exists wget; then FETCHER="wget"; return 0; fi
    if command_exists curl; then FETCHER="curl"; return 0; fi
    err "wget or curl is required"
    return 1
}

http_get() {
    _url="$1"
    case "$FETCHER" in
        wget) run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$_url" ;;
        curl) curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$_url" ;;
        *) return 1 ;;
    esac
}

download_file_once() {
    _url="$1"; _dst="$2"
    case "$FETCHER" in
        wget) run_with_deadline "$DOWNLOAD_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$_dst" "$_url" ;;
        curl) curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --speed-limit 1024 --speed-time 15 --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$_url" -o "$_dst" ;;
        *) return 1 ;;
    esac
}

download_with_retry() {
    _url="$1"; _dst="$2"; _label="$3"
    _attempt=1
    while [ "$_attempt" -le 4 ]; do
        _try_url="$_url"
        case "$_attempt" in
            2) _try_url="https://gh-proxy.com/$_url" ;;
            3) _try_url="https://ghproxy.net/$_url" ;;
            4) _try_url="$_url" ;;
        esac
        msg "Downloading $_label (attempt $_attempt/4)"
        if download_file_once "$_try_url" "$_dst" && [ -s "$_dst" ]; then return 0; fi
        rm -f "$_dst"
        _attempt=$((_attempt + 1))
        sleep 2
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

pkg_update_index() {
    [ "$PACKAGE_INDEX_UPDATED" -eq 1 ] && return 0
    if [ "$DRY_RUN" -eq 1 ]; then msg "[dry-run] would refresh $PKG_MANAGER package indexes"; PACKAGE_INDEX_UPDATED=1; return 0; fi
    msg "Refreshing $PKG_MANAGER package indexes"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk_run apk-update 180 update || return 1
    else
        run_logged_timeout opkg-update 180 opkg update || return 1
    fi
    PACKAGE_INDEX_UPDATED=1
}

pkg_install_names() {
    [ "$#" -gt 0 ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then msg "[dry-run] would install dependencies: $*"; return 0; fi
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk_run apk-add "$PACKAGE_TIMEOUT_SECONDS" add "$@"
    else
        run_logged_timeout opkg-add "$PACKAGE_TIMEOUT_SECONDS" opkg install "$@"
    fi
}

ensure_package() {
    _pkg="$1"
    pkg_is_installed "$_pkg" && return 0
    pkg_update_index || return 1
    pkg_install_names "$_pkg"
}

ensure_bootstrap_ucode_runtime() {
    if ! command_exists ucode; then
        pkg_update_index || return 1
        pkg_install_names ucode || return 1
    fi
    ensure_package ucode-mod-fs || return 1
    ensure_package ucode-mod-uci || return 1
}

ensure_runtime_dependencies() {
    _missing=""
    for _pkg in ca-bundle curl coreutils-base64 coreutils-timeout bind-dig nftables ip-full; do
        pkg_is_installed "$_pkg" || _missing="$_missing $_pkg"
    done
    [ -z "$_missing" ] && return 0
    pkg_update_index || return 1
    # shellcheck disable=SC2086
    pkg_install_names $_missing
}

install_release_helper() {
    _helper="$TMP_DIR/release-helper.uc"
    cat >"$_helper" <<'EOF_UCODE'
#!/usr/bin/env ucode
let fs = require("fs");
function stdin_all() { let f = fs.open("/dev/stdin", "r"); if (!f) return ""; let d = f.read("all"); f.close(); return d || ""; }
function obj() { try { return json(stdin_all()); } catch (e) { return null; } }
function valid(v) { return match("" + (v || ""), /^[0-9]+[.][0-9]+[.][0-9]+$/) != null; }
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
let v = obj();
let r = pick_release(v, ARGV[1] || "stable");
if (!r) exit(2);
let ver = "" + (r.tag_name || "");
if (mode == "tag") { if (valid(ver)) print(ver, "\n"); else exit(3); }
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
        if (valid(t)) print(t, "\n");
    }
}
else exit(1);
EOF_UCODE
    printf '%s\n' "$_helper"
}

release_helper() {
    ucode "$(install_release_helper)" "$@"
}

fetch_release_json() {
    if [ -n "$RELEASE_TAG_REQUESTED" ]; then
        _url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/${RELEASE_TAG_REQUESTED}"
    elif [ "$RELEASE_CHANNEL" = "beta" ]; then
        _url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases?per_page=20"
    else
        _url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    fi
    _json="$(http_get "$_url" 2>/dev/null || true)"
    if [ -z "$_json" ]; then
        warn "GitHub release API failed; trying mirror"
        _json="$(http_get "https://gh-proxy.com/$_url" 2>/dev/null || true)"
    fi
    [ -n "$_json" ] || return 1
    printf '%s' "$_json"
}

fetch_release_tag_list() {
    _url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases?per_page=15"
    _json="$(http_get "$_url" 2>/dev/null || true)"
    if [ -z "$_json" ]; then
        _json="$(http_get "https://gh-proxy.com/$_url" 2>/dev/null || true)"
    fi
    [ -n "$_json" ] || return 1
    printf '%s' "$_json" | release_helper tags "$RELEASE_CHANNEL" 2>/dev/null
}

installer_is_interactive() {
    [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]
}

select_release_version() {
    [ -n "$RELEASE_TAG_REQUESTED" ] && return 0
    installer_is_interactive || return 0
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

resolve_release() {
    _ext="ipk"; [ "$PKG_IS_APK" -eq 1 ] && _ext="apk"
    TACHYON_RELEASE_JSON="$(fetch_release_json)" || return 1
    TACHYON_RELEASE_TAG="$(printf '%s' "$TACHYON_RELEASE_JSON" | release_helper tag "$RELEASE_CHANNEL" 2>/dev/null || true)"
    [ -n "$TACHYON_RELEASE_TAG" ] || { err "Could not resolve a valid release tag"; return 1; }
    if [ -n "$RELEASE_TAG_REQUESTED" ] && [ "$TACHYON_RELEASE_TAG" != "$RELEASE_TAG_REQUESTED" ]; then
        err "Resolved release $TACHYON_RELEASE_TAG does not match requested $RELEASE_TAG_REQUESTED"
        return 1
    fi
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
}

free_kb() {
    _path="$1"
    df -Pk "$_path" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_storage_preflight() {
    _overlay="$(free_kb /overlay)"; [ -n "$_overlay" ] || _overlay="$(free_kb /)"
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
    if pkg_is_installed luci-i18n-tachyon-ru; then TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0; fi
    case "$_lang" in ru|ru-*|ru_*) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru"; return 0 ;; esac
    INSTALLER_LANG="en"
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then return 0; fi
    printf 'Install Russian LuCI translation? [y/N]: '
    read -r _answer || true
    case "$_answer" in y|Y|yes|YES) TACHYON_I18N_REQUESTED=1; INSTALLER_LANG="ru" ;; esac
}

sing_box_is_present() {
    command_exists sing-box || pkg_is_installed sing-box || pkg_is_installed sing-box-extended || pkg_is_installed sing-box-tiny || pkg_is_installed sing-box-lx
}

select_sing_box_installation() {
    SING_BOX_INSTALL_VARIANT=""
    sing_box_is_present && return 0
    [ "$SKIP_SING_BOX" -eq 1 ] && return 0
    if ! installer_is_interactive; then SING_BOX_INSTALL_VARIANT="stable"; return 0; fi
    printf '\nSelect sing-box build:\n  1) stable (recommended)\n  2) tiny (low memory)\n  3) extended (xHTTP)\n  4) extended-compressed (xHTTP, smaller)\n  5) lx\n  6) skip\nChoice [1]: '
    read -r _answer || _answer=""
    case "${_answer:-1}" in
        1) SING_BOX_INSTALL_VARIANT="stable" ;;
        2) SING_BOX_INSTALL_VARIANT="tiny" ;;
        3) SING_BOX_INSTALL_VARIANT="extended" ;;
        4) SING_BOX_INSTALL_VARIANT="extended-compressed" ;;
        5) SING_BOX_INSTALL_VARIANT="lx" ;;
        6) SING_BOX_INSTALL_VARIANT="" ;;
        *) warn "Unknown choice; using stable"; SING_BOX_INSTALL_VARIANT="stable" ;;
    esac
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
    for _f in /etc/config/tachyon /etc/config/netshift /etc/config/forkop /etc/config/forkop_plus /etc/config/podkop /etc/config/podkop_plus; do
        [ -f "$_f" ] || continue
        cp -a "$_f" "$SNAPSHOT_DIR/$(basename "$_f")" || return 1
    done
    [ "$PKG_IS_APK" -eq 1 ] && [ -f /etc/apk/world ] && cp -a /etc/apk/world "$SNAPSHOT_DIR/apk-world" || true
    printf 'installed=%s\nrunning=%s\nenabled=%s\n' "$TACHYON_WAS_INSTALLED" "$TACHYON_WAS_RUNNING" "$TACHYON_WAS_ENABLED" >"$SNAPSHOT_DIR/state"
    TX_ACTIVE=1
    ok "Recovery snapshot created: $SNAPSHOT_DIR"
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
        cp -a "$SNAPSHOT_DIR/apk-world" /etc/apk/world 2>/dev/null || true
    fi
    if [ "$TACHYON_WAS_INSTALLED" -eq 1 ] && [ -x /usr/bin/tachyon ]; then
        [ "$TACHYON_WAS_ENABLED" -eq 1 ] && /etc/init.d/tachyon enable >/dev/null 2>&1 || /etc/init.d/tachyon disable >/dev/null 2>&1 || true
        [ "$TACHYON_WAS_RUNNING" -eq 1 ] && run_with_deadline 45 /usr/bin/tachyon start >/dev/null 2>&1 || true
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

prepare_transaction() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ -x /usr/bin/tachyon ]; then
        run_with_deadline 45 /usr/bin/tachyon stop >/dev/null 2>&1 || true
    fi
    remove_legacy_packages
    release_tachyon_init_lock
}

remove_legacy_packages() {
    _legacy_pkgs=""
    if [ "$PKG_IS_APK" -eq 1 ]; then
        for _pkg in forkop luci-app-forkop podkop luci-app-podkop forkop_plus luci-app-forkop_plus podkop_plus luci-app-podkop_plus netshift luci-app-netshift; do
            if apk info -e "$_pkg" >/dev/null 2>&1; then
                _legacy_pkgs="$_legacy_pkgs $_pkg"
            fi
        done
        if [ -n "$_legacy_pkgs" ]; then
            msg "Removing legacy packages:$_legacy_pkgs"
            apk_run apk-legacy-cleanup "$PACKAGE_TIMEOUT_SECONDS" del --purge $_legacy_pkgs || warn "Could not remove legacy packages (will retry during install)"
        fi
    else
        for _pkg in forkop luci-app-forkop podkop luci-app-podkop forkop_plus luci-app-forkop_plus podkop_plus luci-app-podkop_plus netshift luci-app-netshift; do
            if opkg status "$_pkg" 2>/dev/null | grep -q '^Status:'; then
                _legacy_pkgs="$_legacy_pkgs $_pkg"
            fi
        done
        if [ -n "$_legacy_pkgs" ]; then
            msg "Removing legacy packages:$_legacy_pkgs"
            opkg remove --force-depends $_legacy_pkgs 2>/dev/null || warn "Could not remove legacy packages"
        fi
    fi
}

download_release() {
    TACHYON_SHA256_FILE="$TMP_DIR/sha256sums.txt"
    TACHYON_BACKEND_FILE="$TMP_DIR/$TACHYON_BACKEND_NAME"
    TACHYON_APP_FILE="$TMP_DIR/$TACHYON_APP_NAME"
    [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would download and verify $TACHYON_RELEASE_TAG"; return 0; }
    download_with_retry "$TACHYON_SHA256_URL" "$TACHYON_SHA256_FILE" sha256sums.txt || return 1
    download_with_retry "$TACHYON_BACKEND_URL" "$TACHYON_BACKEND_FILE" "$TACHYON_BACKEND_NAME" || return 1
    download_with_retry "$TACHYON_APP_URL" "$TACHYON_APP_FILE" "$TACHYON_APP_NAME" || return 1
    if [ "$TACHYON_I18N_REQUESTED" -eq 1 ]; then
        TACHYON_I18N_FILE="$TMP_DIR/$TACHYON_I18N_NAME"
        download_with_retry "$TACHYON_I18N_URL" "$TACHYON_I18N_FILE" "$TACHYON_I18N_NAME" || return 1
    fi
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
}

pkg_install_local_bundle() {
    [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would install local package transaction: $*"; return 0; }
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk_run apk-transaction "$PACKAGE_TIMEOUT_SECONDS" add --allow-untrusted "$@"
    else
        run_logged_timeout opkg-transaction "$PACKAGE_TIMEOUT_SECONDS" opkg install --force-reinstall --force-overwrite --force-downgrade "$@"
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

install_selected_sing_box() {
    [ -n "$SING_BOX_INSTALL_VARIANT" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && { msg "[dry-run] would install sing-box variant $SING_BOX_INSTALL_VARIANT"; return 0; }
    [ -x /usr/bin/tachyon ] || return 1
    case "$SING_BOX_INSTALL_VARIANT" in
        stable) _action="install_stable" ;;
        tiny) _action="install_tiny" ;;
        extended) _action="install_extended" ;;
        extended-compressed) _action="install_extended_compressed" ;;
        lx) _action="install_lx" ;;
        *) return 1 ;;
    esac
    msg "Installing sing-box ($SING_BOX_INSTALL_VARIANT)"
    run_logged_timeout sing-box "$PACKAGE_TIMEOUT_SECONDS" /usr/bin/tachyon component_action sing_box "$_action"
}

restore_service_intent() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -x /etc/init.d/tachyon ] || return 1
    if [ "$TACHYON_WAS_INSTALLED" -eq 1 ]; then
        if [ "$TACHYON_WAS_ENABLED" -eq 1 ]; then /etc/init.d/tachyon enable >/dev/null 2>&1 || true; else /etc/init.d/tachyon disable >/dev/null 2>&1 || true; fi
        if [ "$TACHYON_WAS_RUNNING" -eq 1 ]; then run_with_deadline 60 /usr/bin/tachyon start >/dev/null 2>&1 || return 1; else run_with_deadline 45 /usr/bin/tachyon stop >/dev/null 2>&1 || true; fi
    else
        /etc/init.d/tachyon enable >/dev/null 2>&1 || true
        run_with_deadline 60 /usr/bin/tachyon start >/dev/null 2>&1 || true
    fi
}

healthcheck() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    msg "Running installation healthcheck"
    pkg_is_installed tachyon || { err "tachyon package is not registered"; return 1; }
    pkg_is_installed luci-app-tachyon || { err "luci-app-tachyon package is not registered"; return 1; }
    [ -x /usr/bin/tachyon ] || { err "/usr/bin/tachyon is missing"; return 1; }
    [ -r /usr/lib/tachyon/core/constants.uc ] || { err "Tachyon runtime is incomplete"; return 1; }
    [ -f /usr/share/luci/menu.d/luci-app-tachyon.json ] || { err "LuCI menu file is missing"; return 1; }
    [ -r /etc/config/tachyon ] || { err "Tachyon UCI config is missing"; return 1; }
    chmod 0600 /etc/config/tachyon 2>/dev/null || true
    _version="$(/usr/bin/tachyon get_system_info 2>/dev/null | sed -n 's/.*"tachyon_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$_version" ] && [ "$_version" != "$TACHYON_RELEASE_TAG" ]; then
        err "Installed runtime reports version $_version, expected $TACHYON_RELEASE_TAG"
        return 1
    fi
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

system_preflight() {
    [ -r /etc/openwrt_release ] || { err "This installer supports OpenWrt only"; return 1; }
    _release="$(read_openwrt_release_value DISTRIB_RELEASE)"
    _major="$(printf '%s' "$_release" | sed 's/[^0-9].*$//')"
    case "$_major" in *[!0-9]*|"") _major=0 ;; esac
    [ "$_major" -eq 0 ] || [ "$_major" -ge 23 ] || { err "OpenWrt 23.05 or newer is required"; return 1; }
    check_storage_preflight
}

print_plan() {
    msg "Release: ${TACHYON_RELEASE_TAG} (${PKG_MANAGER})"
    [ "$TACHYON_I18N_REQUESTED" -eq 1 ] && msg "Russian LuCI translation: yes" || msg "Russian LuCI translation: no"
    [ -n "$SING_BOX_INSTALL_VARIANT" ] && msg "sing-box: $SING_BOX_INSTALL_VARIANT" || msg "sing-box: keep existing / skip"
    [ "$ZRAM_INSTALL_REQUESTED" -eq 1 ] && msg "zram-swap: install" || true
}

main() {
    trap cleanup EXIT
    trap on_hup HUP
    trap on_int INT
    trap on_term TERM

    parse_args "$@" || exit $?
    START_TIME="$(date +%s 2>/dev/null || echo 0)"
    : >"$LOG_FILE" 2>/dev/null || true

    acquire_lock || exit 1
    check_root || fail "Root privileges are required"
    init_tmp_dir || fail "Could not create temporary directory"
    detect_fetcher || fail "No download client available"
    detect_package_manager || fail "No supported package manager available"
    banner

    sync_time
    system_preflight || fail "System preflight failed"

    ensure_bootstrap_ucode_runtime || fail "Could not bootstrap ucode runtime"
    detect_language_and_i18n
    select_sing_box_installation
    decide_zram
    record_service_state
    select_release_version

    resolve_release || fail "Could not resolve Tachyon release"
    check_tmp_for_downloads || fail "Temporary storage preflight failed"
    print_plan
    download_release || fail "Release download or verification failed"

    ensure_runtime_dependencies || fail "Could not install Tachyon dependencies"
    snapshot_state || fail "Could not create recovery snapshot"
    prepare_transaction || fail "Could not prepare package transaction"
    install_core_transaction || fail "Tachyon package transaction failed"
    install_zram_if_requested
    install_selected_sing_box || fail "sing-box installation failed"
    restore_service_intent || fail "Could not restore Tachyon service state"
    healthcheck || fail "Installed Tachyon did not pass healthcheck"
    commit_transaction

    _end="$(date +%s 2>/dev/null || echo 0)"
    _elapsed=$((_end - START_TIME)); [ "$_elapsed" -ge 0 ] 2>/dev/null || _elapsed=0
    ok "Tachyon ${TACHYON_RELEASE_TAG} installed successfully in ${_elapsed}s"
    msg "Log: $LOG_FILE"
    [ -n "$SNAPSHOT_DIR" ] && msg "Recovery snapshot: $SNAPSHOT_DIR"
}

if [ "${TACHYON_INSTALLER_TEST:-0}" != "1" ]; then
    main "$@"
fi
