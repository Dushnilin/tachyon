#!/bin/sh
# shellcheck shell=dash
# Tachyon 2.0 OpenWrt Installer & 1.x -> 2.0 Migration Script

set -u

REPO_OWNER="Dushnilin"
REPO_NAME="tachyon"
CORE_REPO="Dushnilin/tachyon-core"
LOG_FILE="/tmp/tachyon-install.log"
TMP_DIR=""
FETCHER=""
PKG_MANAGER=""
PKG_IS_APK=0

ASSUME_YES=0
DRY_RUN=0
QUIET=0
TAG_REQUESTED=""
CHANNEL="auto"
PKG_FORMAT="auto"
ARCH_OVERRIDE=""
FORCE_REINSTALL=0
SKIP_CORE=0
PREPARED_CORE_BIN=""
PREPARED_CORE_VER=""
PREPARED_CORE_PKG=""

CONNECT_TIMEOUT=15
METADATA_TIMEOUT=60
DOWNLOAD_TIMEOUT=600

log_line() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '---')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

msg() {
    log_line "INFO $1"
    [ "$QUIET" -eq 1 ] || printf '[INFO] %s\n' "$1"
}

ok() {
    log_line "OK   $1"
    [ "$QUIET" -eq 1 ] || printf '[OK]   %s\n' "$1"
}

warn() {
    log_line "WARN $1"
    printf '[WARN] %s\n' "$1" >&2
}

err() {
    log_line "ERR  $1"
    printf '[ERR]  %s\n' "$1" >&2
}

cleanup() {
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Tachyon 2.0 OpenWrt Installer

Usage: $0 [options]

  -y, --yes             Install without interactive prompts
  -n, --dry-run         Resolve release and print plan without modifying router
  -q, --quiet           Suppress informational messages
      --channel CH      Release channel: auto, stable, beta (default: auto)
      --prerelease      Include beta/rc releases (alias for --channel beta)
      --tag VERSION     Install exact tag (e.g. v2.0.0-beta.1 or v2.0.0)
      --format FMT      Package format: auto, apk, ipk (default: auto)
      --arch ARCH       Override target arch (x86_64, i386_pentium4, aarch64,
                        armv7, armv6, riscv64, mipsel, mips)
      --reinstall       Force package reinstall over existing files
      --repair          Repair services, scripts, and package files in place
      --tachyon-core    Compatible flag (tachyon-core is the built-in engine)
      --repo OWNER/REPO Override GitHub repository (default: ${REPO_OWNER}/${REPO_NAME})
      --skip-core       Do not download/update tachyon-core
  -h, --help            Show this help

Log file: ${LOG_FILE}
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -q|--quiet) QUIET=1 ;;
        --skip-core) SKIP_CORE=1 ;;
        --tachyon-core) ;;
        --reinstall|--repair) FORCE_REINSTALL=1 ;;
        --prerelease) CHANNEL="beta" ;;
        --channel)
            shift
            [ "$#" -gt 0 ] || { err "--channel requires auto, stable, or beta"; exit 2; }
            case "$1" in
                auto|stable|beta) CHANNEL="$1" ;;
                *) err "Invalid --channel value: $1 (expected auto, stable, or beta)"; exit 2 ;;
            esac
            ;;
        --format)
            shift
            [ "$#" -gt 0 ] || { err "--format requires auto, apk, or ipk"; exit 2; }
            case "$1" in
                auto|apk|ipk)
                    PKG_FORMAT="$1"
                    ;;
                *) err "Invalid --format value: $1 (expected auto, apk, or ipk)"; exit 2 ;;
            esac
            ;;
        --arch)
            shift
            [ "$#" -gt 0 ] || { err "--arch requires a value"; exit 2; }
            ARCH_OVERRIDE="$1"
            ;;
        --tag)
            shift
            [ "$#" -gt 0 ] || { err "--tag requires a value"; exit 2; }
            TAG_REQUESTED="$1"
            ;;
        --repo)
            shift
            [ "$#" -gt 0 ] || { err "--repo requires OWNER/REPO"; exit 2; }
            REPO_OWNER="${1%%/*}"
            REPO_NAME="${1#*/}"
            if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ] || [ "$REPO_OWNER" = "$1" ]; then
                err "Invalid --repo format: $1"
                exit 2
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    err "Run this installer as root."
    exit 1
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_fetcher() {
    if command_exists curl; then
        FETCHER="curl"
        return 0
    fi
    if command_exists wget; then
        FETCHER="wget"
        return 0
    fi
    err "curl or wget is required."
    return 1
}

http_get() {
    _url="$1"
    case "$FETCHER" in
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT" --max-time "$METADATA_TIMEOUT" -fsSL "$_url"
            ;;
        wget)
            wget -T "$CONNECT_TIMEOUT" -qO- "$_url" 2>/dev/null || \
                wget --no-check-certificate -T "$CONNECT_TIMEOUT" -qO- "$_url" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

download_file() {
    _url="$1"
    _dst="$2"
    _label="$3"
    _attempt=1
    while [ "$_attempt" -le 4 ]; do
        case "$_attempt" in
            1) _try="$_url" ;;
            2) _try="https://ghfast.top/$_url" ;;
            3) _try="https://gh-proxy.com/$_url" ;;
            4) _try="$_url" ;;
        esac
        msg "Downloading ${_label} (attempt ${_attempt}/4)..."
        case "$FETCHER" in
            curl)
                if curl --connect-timeout "$CONNECT_TIMEOUT" --max-time "$DOWNLOAD_TIMEOUT" -fsSL "$_try" -o "$_dst" && [ -s "$_dst" ]; then
                    return 0
                fi
                ;;
            wget)
                if wget -T "$CONNECT_TIMEOUT" -q -O "$_dst" "$_try" 2>/dev/null && [ -s "$_dst" ]; then
                    return 0
                fi
                if wget --no-check-certificate -T "$CONNECT_TIMEOUT" -q -O "$_dst" "$_try" 2>/dev/null && [ -s "$_dst" ]; then
                    return 0
                fi
                ;;
        esac
        rm -f "$_dst"
        _attempt=$((_attempt + 1))
        sleep 1
    done
    return 1
}

detect_arch() {
    if [ -n "$ARCH_OVERRIDE" ]; then
        case "$ARCH_OVERRIDE" in
            aarch64|x86_64|i386_pentium4|armv7|armv6|riscv64|mipsel|mips)
                echo "$ARCH_OVERRIDE"
                return 0
                ;;
            *)
                err "Unsupported --arch '${ARCH_OVERRIDE}'. Supported: x86_64, i386_pentium4, aarch64, armv7, armv6, riscv64, mipsel, mips"
                return 1
                ;;
        esac
    fi
    _dist_arch=""
    if [ -r /etc/openwrt_release ]; then
        _dist_arch="$(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1)"
    fi
    _uname="$(uname -m 2>/dev/null || echo unknown)"
    _raw="${_dist_arch} ${_uname}"
    case "$_raw" in
        *aarch64*|*arm64*) echo "aarch64" ;;
        *x86_64*|*amd64*) echo "x86_64" ;;
        *riscv64*) echo "riscv64" ;;
        *mips64*)
            err "64-bit MIPS (${_raw}) is not supported; supported targets: x86_64, i386_pentium4, aarch64, armv7, armv6, riscv64, mipsel, mips"
            return 1
            ;;
        *mipsel*|*mips32el*) echo "mipsel" ;;
        *mips*) echo "mips" ;;
        *arm_cortex*|*armv7*) echo "armv7" ;;
        *arm*) echo "armv6" ;;
        *i386_pentium4*|*i686*|*i586*|*i386*) echo "i386_pentium4" ;;
        *)
            err "Unsupported architecture: ${_raw}"
            return 1
            ;;
    esac
}

detect_pkg_manager() {
    if command_exists apk && [ -d /lib/apk/db ]; then
        PKG_MANAGER="apk"
        PKG_IS_APK=1
        return 0
    fi
    if command_exists opkg; then
        PKG_MANAGER="opkg"
        PKG_IS_APK=0
        return 0
    fi
    warn "Neither apk nor opkg found; dependency installation will be skipped."
    return 0
}

resolve_pkg_format() {
    if [ "$PKG_FORMAT" != "auto" ]; then
        echo "$PKG_FORMAT"
        return 0
    fi
    if [ "$PKG_IS_APK" -eq 1 ]; then
        echo "apk"
    elif [ "$PKG_MANAGER" = "opkg" ]; then
        echo "ipk"
    else
        err "OpenWrt apk or opkg package manager not found; specify --format apk or --format ipk"
        return 1
    fi
}

pkg_installed() {
    _p="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$_p" >/dev/null 2>&1
    elif [ "$PKG_MANAGER" = "opkg" ]; then
        opkg status "$_p" 2>/dev/null | grep -q '^Status: .* installed'
    else
        return 1
    fi
}

install_system_deps() {
    [ -n "$PKG_MANAGER" ] || return 0
    _deps="ca-bundle curl nftables ip-full kmod-nft-tproxy kmod-tun kmod-inet-diag"
    _missing=""
    for _d in $_deps; do
        if ! pkg_installed "$_d"; then
            _missing="${_missing} ${_d}"
        fi
    done
    [ -n "$_missing" ] || { ok "System runtime packages already present"; return 0; }

    msg "Installing required system packages:${_missing}"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        apk add --no-cache $_missing >>"$LOG_FILE" 2>&1 || warn "Some packages failed to install:${_missing}"
    else
        opkg update >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        opkg install $_missing >>"$LOG_FILE" 2>&1 || warn "Some packages failed to install:${_missing}"
    fi
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

install_pkg_best_effort() {
    _pkg="$1"
    [ -n "$PKG_MANAGER" ] || return 1
    pkg_installed "$_pkg" && return 0
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --no-cache "$_pkg" >>"$LOG_FILE" 2>&1 && return 0
        apk update >/dev/null 2>&1 || true
        apk add --no-cache "$_pkg" >>"$LOG_FILE" 2>&1 && return 0
    elif [ "$PKG_MANAGER" = "opkg" ]; then
        opkg install "$_pkg" >>"$LOG_FILE" 2>&1 && return 0
        opkg update >/dev/null 2>&1 || true
        opkg install "$_pkg" >>"$LOG_FILE" 2>&1 && return 0
    fi
    return 1
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
        if install_pkg_best_effort kmod-tcp-bbr; then
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

verify_sha256_file() {
    _file="$1"
    _sums="$2"
    _asset_name="$3"

    if ! command_exists sha256sum; then
        warn "sha256sum not available; skipping checksum verification for ${_asset_name}"
        return 0
    fi

    _expected="$(awk -v name="$_asset_name" '
        {
            f = $2;
            gsub(/^\*/, "", f);
            sub(/^.*\//, "", f);
            if (f == name) { print tolower($1); exit }
        }
    ' "$_sums" 2>/dev/null)"

    if [ -z "$_expected" ]; then
        err "Checksum entry for ${_asset_name} not found in SHA256SUMS"
        return 1
    fi

    _actual="$(sha256sum "$_file" | awk '{print tolower($1)}')"
    if [ "$_actual" != "$_expected" ]; then
        err "SHA-256 mismatch for ${_asset_name}: expected ${_expected}, got ${_actual}"
        return 1
    fi
    ok "SHA-256 verified for ${_asset_name}"
}

is_v2_tag() {
    printf '%s' "$1" | grep -Eq '^v?([2-9]|[1-9][0-9]+)[.]'
}

is_prerelease_tag() {
    case "$1" in
        *-*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_core_release_tag() {
    _repo="$1"
    _api_url="https://api.github.com/repos/${_repo}/releases/latest"
    _json="$(http_get "$_api_url" || true)"
    _tag="$(printf '%s' "$_json" | tr '\n' ' ' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -n "$_tag" ]; then
        echo "$_tag"
        return 0
    fi
    _atom="$(http_get "https://github.com/${_repo}/releases.atom" || true)"
    _tag="$(printf '%s' "$_atom" | sed -n 's|.*/releases/tag/\([^"/?<]*\)".*|\1|p' | head -n 1)"
    [ -n "$_tag" ] || return 1
    echo "$_tag"
}

parse_releases_json_tags() {
    tr ',' '\n' | awk '
    function flush_rel() {
        if (tag != "" && draft != 1) {
            print tag
        }
        tag = ""; draft = 0
    }
    {
        if ($0 ~ /"draft"[[:space:]]*:[[:space:]]*true/) draft = 1
        if (match($0, /"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", s)
            sub(/".*$/, "", s)
            tag = s
        }
        if ($0 ~ /"published_at"[[:space:]]*:/) {
            flush_rel()
        }
    }
    END { flush_rel() }
    '
}

pick_best_v2_tag() {
    _tags="$1"
    _first_pre=""
    for _t in $_tags; do
        is_v2_tag "$_t" || continue
        if [ "$CHANNEL" = "beta" ]; then
            echo "$_t"
            return 0
        fi
        if is_prerelease_tag "$_t"; then
            [ -n "$_first_pre" ] || _first_pre="$_t"
        else
            echo "$_t"
            return 0
        fi
    done
    if [ "$CHANNEL" = "auto" ] && [ -n "$_first_pre" ]; then
        echo "$_first_pre"
        return 0
    fi
    return 1
}

resolve_tachyon_release_tag() {
    _repo="$1"
    _req="$2"
    if [ -n "$_req" ]; then
        echo "v${_req#[vV]}"
        return 0
    fi

    if [ "$CHANNEL" != "beta" ]; then
        _latest_json="$(http_get "https://api.github.com/repos/${_repo}/releases/latest" || true)"
        _latest_tag="$(printf '%s' "$_latest_json" | tr '\n' ' ' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
        if [ -n "$_latest_tag" ] && is_v2_tag "$_latest_tag"; then
            echo "$_latest_tag"
            return 0
        fi
    fi

    _list_json="$(http_get "https://api.github.com/repos/${_repo}/releases?per_page=100" || true)"
    _tags=""
    if [ -n "$_list_json" ]; then
        _tags="$(printf '%s' "$_list_json" | parse_releases_json_tags || true)"
    fi
    if [ -z "$_tags" ]; then
        _atom="$(http_get "https://github.com/${_repo}/releases.atom" || true)"
        _tags="$(printf '%s' "$_atom" | sed -n 's|.*/releases/tag/\([^"/?<]*\)".*|\1|p' || true)"
    fi
    [ -n "$_tags" ] || return 1
    pick_best_v2_tag "$_tags"
}

_timeout_cmd() {
    if command_exists timeout; then
        if timeout 1 /bin/true >/dev/null 2>&1; then
            echo "timeout 15"
            return 0
        elif timeout -t 1 /bin/true >/dev/null 2>&1; then
            echo "timeout -t 15"
            return 0
        fi
    fi
    echo ""
}

_kill_tachyon_init_waiters() {
    __anc=" "
    __p=$$
    while [ -n "$__p" ] && [ "$__p" -gt 1 ] 2>/dev/null; do
        __anc="$__anc$__p "
        __p=$(awk '{ sub(/.*\) /, ""); print $2 }' "/proc/$__p/stat" 2>/dev/null || true)
    done
    for __pdir in /proc/[0-9]*; do
        __pid="${__pdir##*/}"
        case "$__anc" in *" $__pid "*) continue;; esac
        if [ -r "$__pdir/cmdline" ]; then
            __cmd="$(tr '\0' ' ' < "$__pdir/cmdline" 2>/dev/null || true)"
            case "$__cmd" in
                *99-tachyon-wan*|*"flock 1000"*|*"/etc/init.d/tachyon"*)
                    kill -9 "$__pid" >/dev/null 2>&1 || true
                    continue
                    ;;
            esac
        fi
        if [ -e "$__pdir/fd/1000" ]; then
            case "$(readlink "$__pdir/fd/1000" 2>/dev/null || true)" in
                *procd_tachyon*) kill -9 "$__pid" >/dev/null 2>&1 || true ;;
            esac
        fi
    done
}

migrate_from_v1() {
    _is_v1=0
    for _marker in \
        /usr/lib/tachyon \
        /usr/libexec/rpcd/tachyon \
        /usr/bin/tachyon-read \
        /etc/hotplug.d/iface/99-tachyon-wan-monitor \
        /etc/init.d/tachyon-torrserver-direct
    do
        if [ -e "$_marker" ]; then
            _is_v1=1
            break
        fi
    done
    if [ "$_is_v1" -eq 0 ] && [ -x /usr/bin/tachyon ] && head -c 2 /usr/bin/tachyon 2>/dev/null | grep -q '^#!'; then
        _is_v1=1
    fi

    if [ "$_is_v1" -eq 0 ]; then
        return 0
    fi

    msg "Detected legacy Tachyon 1.x installation; preparing 1.x -> 2.0 migration..."
    mkdir -p /etc/tachyon/backup-pre-2.0
    if [ -s /etc/config/tachyon ]; then
        cp -af /etc/config/tachyon /etc/tachyon/backup-pre-2.0/tachyon.uci 2>/dev/null || true
        chmod 600 /etc/tachyon/backup-pre-2.0/tachyon.uci 2>/dev/null || true
        ok "Backed up /etc/config/tachyon -> /etc/tachyon/backup-pre-2.0/tachyon.uci (kept for auto-import)"
    fi

    _kill_tachyon_init_waiters
    _to="$(_timeout_cmd)"
    if [ -x /usr/bin/tachyon ]; then
        $_to /usr/bin/tachyon stop >/dev/null 2>&1 || true
    fi
    for _old_svc in \
        /etc/init.d/tachyon \
        /etc/init.d/tachyon-torrserver-direct \
        /etc/init.d/tachyon-core
    do
        if [ -x "$_old_svc" ]; then
            $_to "$_old_svc" stop >/dev/null 2>&1 || true
            "$_old_svc" disable >/dev/null 2>&1 || true
        fi
    done

    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in
            *"/usr/lib/tachyon/"*|*"/usr/bin/tachyon-core"*)
                kill -9 "${p##*/}" >/dev/null 2>&1 || true
                ;;
        esac
    done

    if command_exists crontab; then
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

    if command_exists nft; then
        nft delete table inet tachyon >/dev/null 2>&1 || true
        nft delete table inet TachyonTable >/dev/null 2>&1 || true
        nft delete table inet TachyonKillSwitch >/dev/null 2>&1 || true
        nft delete table ip tachyon >/dev/null 2>&1 || true
        nft delete table ip6 tachyon >/dev/null 2>&1 || true
    fi
    rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft /usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft 2>/dev/null || true

    if command_exists ip; then
        for _p in 9499 9500 9501; do
            for _fam in -4 -6; do
                while ip "$_fam" rule del pref "$_p" >/dev/null 2>&1; do :; done
            done
        done
        for _fam in -4 -6; do
            ip "$_fam" rule del fwmark 0x04000000/0x04000000 lookup 100 >/dev/null 2>&1 || true
            ip "$_fam" rule del fwmark 0x04000000 lookup 100 >/dev/null 2>&1 || true
            ip "$_fam" rule del fwmark 0x10000000/0x10000000 lookup 100 >/dev/null 2>&1 || true
            ip "$_fam" rule del fwmark 0x10000000 lookup 100 >/dev/null 2>&1 || true
        done
    fi

    if command_exists uci && [ -f /etc/config/dhcp ]; then
        _dont_touch="$(uci -q get tachyon.settings.dont_touch_dhcp 2>/dev/null || echo '0')"
        if [ "$_dont_touch" != "1" ]; then
            _had_v1_dns=0
            if uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | grep -q '127\.0\.0\.42'; then
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
            for _opt in noresolv cachesize rebind_protection localuse addn_hosts notinterface serversfile localservice; do
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
            if [ "$_had_v1_dns" -eq 1 ] && [ -x /etc/init.d/dnsmasq ]; then
                /etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
            fi
        fi
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        for _old_pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
            if [ -f /etc/apk/world ]; then
                sed -i -E "/^${_old_pkg}([><= ].*)?$/d" /etc/apk/world 2>/dev/null || true
            fi
            if apk info -e "$_old_pkg" >/dev/null 2>&1; then
                apk del --no-network --repositories-file /dev/null "$_old_pkg" >/dev/null 2>&1 || true
            fi
        done
    elif [ "$PKG_MANAGER" = "opkg" ]; then
        for _old_pkg in luci-i18n-tachyon-ru luci-app-tachyon tachyon; do
            if opkg status "$_old_pkg" 2>/dev/null | grep -q '^Status: .* installed'; then
                opkg remove --force-depends "$_old_pkg" >/dev/null 2>&1 || true
            fi
        done
    fi

    if [ ! -s /etc/config/tachyon ] && [ -s /etc/tachyon/backup-pre-2.0/tachyon.uci ]; then
        cp -af /etc/tachyon/backup-pre-2.0/tachyon.uci /etc/config/tachyon 2>/dev/null || true
        chmod 600 /etc/config/tachyon 2>/dev/null || true
        ok "Restored /etc/config/tachyon from /etc/tachyon/backup-pre-2.0/tachyon.uci"
    fi

    rm -rf \
        /usr/lib/tachyon \
        /var/run/tachyon/section-cache \
        /var/run/tachyon/ui-state \
        2>/dev/null || true
    rm -f \
        /usr/libexec/rpcd/tachyon \
        /usr/bin/tachyon-read \
        /etc/hotplug.d/iface/99-tachyon-wan-monitor \
        /etc/init.d/tachyon-torrserver-direct \
        /etc/rc.d/*tachyon-torrserver-direct* \
        /www/cgi-bin/tachyon-agent \
        /www/cgi-bin/tachyon-sub \
        /usr/lib/cgi-bin/tachyon-agent \
        /etc/uci-defaults/50_luci-tachyon \
        /usr/share/luci/menu.d/luci-app-tachyon.json \
        /usr/share/rpcd/acl.d/luci-app-tachyon.json \
        /usr/lib/lua/luci/i18n/tachyon.ru.lmo \
        2>/dev/null || true
    ok "Legacy ucode/rpcd files removed; /etc/config/tachyon preserved for automatic import"
}

has_sha256_entry() {
    _sums="$1"
    _asset_name="$2"
    [ -s "$_sums" ] || return 1
    awk -v name="$_asset_name" '
        {
            f = $2;
            gsub(/^\*/, "", f);
            sub(/^.*\//, "", f);
            if (f == name && length($1) == 64) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$_sums" 2>/dev/null
}

prepare_tachyon_core() {
    _arch="$1"
    _fmt="${2:-}"
    PREPARED_CORE_BIN=""
    PREPARED_CORE_VER=""
    PREPARED_CORE_PKG=""
    [ "$SKIP_CORE" -eq 1 ] && return 0

    msg "Resolving latest tachyon-core release from ${CORE_REPO}..."
    _core_tag="$(resolve_core_release_tag "$CORE_REPO" || true)"
    if [ -z "$_core_tag" ]; then
        if [ -x /usr/bin/tachyon-core ]; then
            warn "Could not resolve latest tachyon-core release; keeping existing /usr/bin/tachyon-core"
            return 0
        fi
        err "Failed to resolve tachyon-core release from ${CORE_REPO}"
        return 1
    fi

    _core_ver="${_core_tag#v}"
    _need_core_update=1
    if [ -x /usr/bin/tachyon-core ]; then
        _cur_core="$(/usr/bin/tachyon-core version 2>/dev/null | awk 'NR==1 {print $NF}' | tr -d 'vV')"
        if [ "$_cur_core" = "$_core_ver" ]; then
            if [ "$PKG_IS_APK" -eq 1 ] && command_exists apk; then
                _apk_core_ver="$(apk list -I tachyon-core 2>/dev/null | head -n 1 | sed -n 's/^tachyon-core-\([^ ]*\).*/\1/p')"
                if [ -z "$_apk_core_ver" ] || [ "${_apk_core_ver%%-r*}" = "$_core_ver" ]; then
                    _need_core_update=0
                fi
            else
                _need_core_update=0
            fi
        fi
    fi
    if [ "$_need_core_update" -eq 0 ]; then
        ok "tachyon-core ${_core_ver} is already up to date"
        return 0
    fi

    _sums_url="https://github.com/${CORE_REPO}/releases/download/${_core_tag}/SHA256SUMS"
    _has_sums=0
    if download_file "$_sums_url" "$TMP_DIR/core.SHA256SUMS" "tachyon-core SHA256SUMS"; then
        _has_sums=1
    fi

    _core_base="tachyon-core-${_arch}-${_core_tag}"
    _core_asset=""
    _core_is_pkg=0
    _core_ext=""
    if [ "$_fmt" = "apk" ] || [ "$_fmt" = "ipk" ]; then
        _pkg_asset="${_core_base}.${_fmt}"
        _pkg_url="https://github.com/${CORE_REPO}/releases/download/${_core_tag}/${_pkg_asset}"
        if download_file "$_pkg_url" "$TMP_DIR/$_pkg_asset" "tachyon-core ${_core_tag} (.${_fmt})"; then
            _core_asset="$_pkg_asset"
            _core_is_pkg=1
            _core_ext="$_fmt"
        fi
    fi

    if [ -z "$_core_asset" ]; then
        _tgz_asset="${_core_base}.tar.gz"
        _tgz_url="https://github.com/${CORE_REPO}/releases/download/${_core_tag}/${_tgz_asset}"
        if ! download_file "$_tgz_url" "$TMP_DIR/$_tgz_asset" "tachyon-core ${_core_tag} (.tar.gz)"; then
            err "Failed to download tachyon-core (${_core_base})"
            return 1
        fi
        _core_asset="$_tgz_asset"
        _core_ext="tar.gz"
    fi

    _verified_archive=0
    if [ "$_has_sums" -eq 1 ]; then
        if [ "$_core_is_pkg" -eq 1 ] || has_sha256_entry "$TMP_DIR/core.SHA256SUMS" "$_core_asset"; then
            verify_sha256_file "$TMP_DIR/$_core_asset" "$TMP_DIR/core.SHA256SUMS" "$_core_asset" || return 1
            _verified_archive=1
        fi
    fi

    rm -rf "$TMP_DIR/core_extract" "$TMP_DIR/core_ipk_outer"
    mkdir -p "$TMP_DIR/core_extract"
    case "$_core_ext" in
        apk)
            gzip -dc "$TMP_DIR/$_core_asset" | tar -x -C "$TMP_DIR/core_extract" || return 1
            ;;
        ipk)
            mkdir -p "$TMP_DIR/core_ipk_outer"
            tar -xzf "$TMP_DIR/$_core_asset" -C "$TMP_DIR/core_ipk_outer" || return 1
            if [ -f "$TMP_DIR/core_ipk_outer/data.tar.gz" ]; then
                tar -xzf "$TMP_DIR/core_ipk_outer/data.tar.gz" -C "$TMP_DIR/core_extract" || return 1
            else
                err "data.tar.gz not found inside ${_core_asset}"
                return 1
            fi
            rm -rf "$TMP_DIR/core_ipk_outer"
            ;;
        *)
            tar -xzf "$TMP_DIR/$_core_asset" -C "$TMP_DIR/core_extract" || return 1
            ;;
    esac

    if [ -f "$TMP_DIR/core_extract/usr/bin/tachyon-core" ]; then
        _core_bin="$TMP_DIR/core_extract/usr/bin/tachyon-core"
    else
        _core_bin="$(find "$TMP_DIR/core_extract" -type f -name 'tachyon-core*' ! -path '*/etc/*' | head -n 1)"
    fi
    if [ -z "$_core_bin" ] || [ ! -f "$_core_bin" ]; then
        err "tachyon-core binary not found in ${_core_asset}"
        return 1
    fi

    if [ "$_has_sums" -eq 1 ] && [ "$_verified_archive" -eq 0 ]; then
        verify_sha256_file "$_core_bin" "$TMP_DIR/core.SHA256SUMS" "$_core_base" || return 1
    fi

    chmod 755 "$_core_bin"
    if ! "$_core_bin" version >/dev/null 2>&1; then
        err "Downloaded tachyon-core failed smoke test"
        return 1
    fi

    PREPARED_CORE_BIN="$_core_bin"
    PREPARED_CORE_VER="$_core_ver"
    if [ "$_core_is_pkg" -eq 1 ]; then
        PREPARED_CORE_PKG="$TMP_DIR/$_core_asset"
    fi
}

apply_tachyon_core() {
    [ -n "$PREPARED_CORE_BIN" ] || return 0
    mv -f "$PREPARED_CORE_BIN" /usr/bin/tachyon-core.new && mv -f /usr/bin/tachyon-core.new /usr/bin/tachyon-core
    chmod 755 /usr/bin/tachyon-core
    if [ -n "$PREPARED_CORE_PKG" ] && [ -f "$PREPARED_CORE_PKG" ]; then
        case "$PREPARED_CORE_PKG" in
            *.apk)
                if [ "$PKG_IS_APK" -eq 1 ] && command_exists apk; then
                    apk add --allow-untrusted --no-network --repositories-file /dev/null --force-overwrite --force-reinstall --scripts=no "$PREPARED_CORE_PKG" >>"$LOG_FILE" 2>&1 || true
                    rm -f /etc/tachyon-core/config.json.apk-new /etc/config/tachyon-core.apk-new 2>/dev/null || true
                fi
                ;;
            *.ipk)
                if [ "$PKG_MANAGER" = "opkg" ] && command_exists opkg; then
                    opkg install --force-reinstall --force-overwrite "$PREPARED_CORE_PKG" >>"$LOG_FILE" 2>&1 || true
                    rm -f /etc/tachyon-core/config.json-opkg /etc/config/tachyon-core-opkg 2>/dev/null || true
                    if [ -x /etc/init.d/tachyon-core ]; then
                        /etc/init.d/tachyon-core stop >/dev/null 2>&1 || true
                    fi
                fi
                ;;
        esac
    fi
    mkdir -p /etc/tachyon /etc/tachyon-core /var/run/tachyon
    printf '%s\n' "$PREPARED_CORE_VER" > /var/run/tachyon/tachyon-core-version
    if [ -x /etc/init.d/tachyon-core ]; then
        /etc/init.d/tachyon-core disable >/dev/null 2>&1 || true
    fi
    rm -f /etc/rc.d/S*tachyon-core /etc/rc.d/K*tachyon-core 2>/dev/null || true
    ok "Installed tachyon-core ${PREPARED_CORE_VER} -> /usr/bin/tachyon-core"
}

package_asset_name() {
    _arch="$1"
    _ver="$2"
    _fmt="$3"
    case "$_fmt" in
        apk) echo "tachyon-${_arch}-v${_ver}.apk" ;;
        ipk) echo "tachyon-${_arch}-v${_ver}.ipk" ;;
        *)
            err "Unsupported package format: ${_fmt} (expected apk or ipk)"
            return 1
            ;;
    esac
}

verify_bundle_checksum() {
    _asset="$1"
    _sums_url="$2"
    _tag="$3"
    if [ ! -f "$TMP_DIR/SHA256SUMS.fetched" ]; then
        if download_file "$_sums_url" "$TMP_DIR/SHA256SUMS" "SHA256SUMS"; then
            : > "$TMP_DIR/SHA256SUMS.fetched"
        else
            warn "SHA256SUMS not available for ${_tag}; continuing without checksum verification"
            return 0
        fi
    fi
    verify_sha256_file "$TMP_DIR/$_asset" "$TMP_DIR/SHA256SUMS" "$_asset"
}

download_tachyon_package() {
    _asset="$1"
    _url="$2"
    _sums_url="$3"
    _tag="$4"
    _fmt="$5"

    download_file "$_url" "$TMP_DIR/$_asset" "tachyon ${_tag} (.${_fmt})" || return 1
    verify_bundle_checksum "$_asset" "$_sums_url" "$_tag" || return 1
}

install_local_apk_package() {
    _pkg="$1"

    if apk add --allow-untrusted --no-network --repositories-file /dev/null --force-reinstall --force-overwrite "$_pkg" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    if apk add --allow-untrusted --force-reinstall --force-overwrite "$_pkg" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    if apk add --allow-untrusted --force-overwrite "$_pkg" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    if apk add --allow-untrusted "$_pkg" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    return 1
}

install_local_ipk_package() {
    _pkg="$1"

    if opkg install --force-reinstall --force-overwrite "$_pkg" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    return 1
}

main() {
    TMP_DIR="$(mktemp -d /tmp/tachyon-install.XXXXXX 2>/dev/null || echo "/tmp/tachyon-install.$$")"
    mkdir -p "$TMP_DIR" || { err "Cannot create temporary directory"; exit 1; }

    detect_fetcher || exit 1
    ARCH="$(detect_arch)" || exit 1
    detect_pkg_manager
    FMT="$(resolve_pkg_format)" || exit 1

    REPO="${REPO_OWNER}/${REPO_NAME}"
    TAG="$(resolve_tachyon_release_tag "$REPO" "$TAG_REQUESTED" || true)"
    if [ -z "$TAG" ]; then
        err "Failed to resolve Tachyon 2.x release tag for ${REPO}"
        exit 1
    fi
    VER="${TAG#[vV]}"
    BUNDLE="$(package_asset_name "$ARCH" "$VER" "$FMT")" || exit 1
    BUNDLE_URL="https://github.com/${REPO}/releases/download/${TAG}/${BUNDLE}"
    SUMS_URL="https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS"

    msg "Target architecture : ${ARCH}"
    msg "Package format      : ${FMT}"
    msg "Release channel     : ${CHANNEL}"
    msg "Repository          : ${REPO}"
    msg "Release version     : ${TAG}"
    msg "Package asset       : ${BUNDLE}"

    if [ "$DRY_RUN" -eq 1 ]; then
        ok "Dry-run complete; no changes made."
        exit 0
    fi

    if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        printf 'Proceed with Tachyon %s (%s) installation on %s? [Y/n]: ' "$TAG" "$FMT" "$ARCH"
        read -r _ans
        case "$_ans" in
            ""|y|Y|yes|Yes|YES) ;;
            *) msg "Installation cancelled."; exit 0 ;;
        esac
    fi

    install_system_deps
    # Download and verify all release artifacts before stopping or modifying any running 1.x/2.x services.
    download_tachyon_package "$BUNDLE" "$BUNDLE_URL" "$SUMS_URL" "$TAG" "$FMT" || { err "Failed to download ${BUNDLE} (see ${LOG_FILE})"; exit 1; }
    prepare_tachyon_core "$ARCH" "$FMT" || exit 1

    migrate_from_v1
    apply_tachyon_core

    if [ -x /etc/init.d/tachyon ]; then
        /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    fi

    case "$FMT" in
        apk)
            if install_local_apk_package "$TMP_DIR/$BUNDLE"; then
                ok "Installed package ${BUNDLE} via apk"
            else
                err "Failed to install ${BUNDLE} via apk (see ${LOG_FILE})"
                exit 1
            fi
            ;;
        ipk)
            if install_local_ipk_package "$TMP_DIR/$BUNDLE"; then
                ok "Installed package ${BUNDLE} via opkg"
            else
                err "Failed to install ${BUNDLE} via opkg (see ${LOG_FILE})"
                exit 1
            fi
            ;;
        *)
            err "Unsupported package format: ${FMT}"
            exit 1
            ;;
    esac

    if [ ! -x /usr/bin/tachyon ] || ! /usr/bin/tachyon --version >/dev/null 2>&1; then
        err "Installed /usr/bin/tachyon failed --version verification"
        exit 1
    fi

    rm -f /tmp/luci-indexcache* 2>/dev/null || true
    rm -rf /tmp/luci-modulecache 2>/dev/null || true
    if [ -x /etc/init.d/rpcd ]; then
        /etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    fi

    mkdir -p /etc/tachyon /etc/tachyon-core /tmp/dnsmasq.d
    ensure_tcp_bbr_best_effort
    /etc/init.d/tachyon enable >/dev/null 2>&1 || true
    /etc/init.d/tachyon restart || { err "Failed to start /etc/init.d/tachyon"; exit 1; }

    sleep 1
    ok "Installed $(/usr/bin/tachyon --version 2>/dev/null || echo "tachyon $VER")"
    _lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)"
    [ -n "$_lan_ip" ] || _lan_ip="192.168.1.1"
    ok "Tachyon panel: http://${_lan_ip}:1680/"
}

main "$@"
