#!/usr/bin/env python3
"""Build OpenWrt .tar.gz, .ipk (opkg), and .apk (apk-tools v2) packages for tachyon.

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


PREINST_SCRIPT = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ -s /etc/config/tachyon ] && [ ! -s /etc/tachyon/backup-pre-2.0/tachyon.uci ]; then
    mkdir -p /etc/tachyon/backup-pre-2.0 2>/dev/null || true
    cp -af /etc/config/tachyon /etc/tachyon/backup-pre-2.0/tachyon.uci 2>/dev/null || true
    chmod 600 /etc/tachyon/backup-pre-2.0/tachyon.uci 2>/dev/null || true
fi
if [ -d /usr/lib/tachyon ] || [ -e /usr/libexec/rpcd/tachyon ] || [ -e /usr/bin/tachyon-read ] || [ -e /etc/hotplug.d/iface/99-tachyon-wan-monitor ] || [ -e /etc/init.d/tachyon-torrserver-direct ]; then
    if [ -x /etc/init.d/tachyon ]; then
        /etc/init.d/tachyon stop >/dev/null 2>&1 || true
    fi
    if [ -x /etc/init.d/tachyon-core ]; then
        /etc/init.d/tachyon-core stop >/dev/null 2>&1 || true
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
# preserving /etc/config/tachyon so the daemon auto-imports it on first start.
if [ -f /tmp/tachyon-upgrading-from-v1 ] || [ -d /usr/lib/tachyon ] || [ -e /usr/libexec/rpcd/tachyon ] || [ -e /usr/bin/tachyon-read ] || [ -e /etc/hotplug.d/iface/99-tachyon-wan-monitor ] || [ -e /etc/init.d/tachyon-torrserver-direct ]; then
    for _old_svc in /etc/init.d/tachyon-torrserver-direct /etc/init.d/tachyon-steer-zapret /etc/init.d/tachyon-core; do
        if [ -x "$_old_svc" ]; then
            "$_old_svc" stop >/dev/null 2>&1 || true
            "$_old_svc" disable >/dev/null 2>&1 || true
        fi
    done
    rm -f /etc/rc.d/*tachyon-core* /etc/rc.d/*tachyon-torrserver-direct* 2>/dev/null || true

    killall -9 sing-box nfqws nfqws2 ciadpi >/dev/null 2>&1 || true
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    case "$(tr '\\0' ' ' < "$p/cmdline" 2>/dev/null)" in
        *"/usr/lib/tachyon/"*|*"/usr/bin/tachyon-core"*)
            kill -9 "${p##*/}" >/dev/null 2>&1 || true
            ;;
    esac
done

    if command -v crontab >/dev/null 2>&1; then
        _crontmp="$(mktemp /tmp/tachyon-cron.XXXXXX 2>/dev/null || echo "/tmp/tachyon-cron.$$")"
        if crontab -l 2>/dev/null | grep -q -E 'tachyon|parental_quota_tick'; then
            crontab -l 2>/dev/null | grep -v -E 'tachyon|parental_quota_tick' > "$_crontmp" || true
            crontab "$_crontmp" 2>/dev/null || true
        fi
        rm -f "$_crontmp" 2>/dev/null || true
    fi

    if command -v nft >/dev/null 2>&1; then
        nft delete table inet tachyon >/dev/null 2>&1 || true
nft delete table inet TachyonTable >/dev/null 2>&1 || true
        nft delete table inet steer >/dev/null 2>&1 || true
        nft delete table ip tachyon >/dev/null 2>&1 || true
        nft delete table ip6 tachyon >/dev/null 2>&1 || true
    fi
    rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft 2>/dev/null || true

    rm -rf /usr/lib/tachyon /var/run/tachyon/section-cache /var/run/tachyon/ui-state 2>/dev/null || true
    rm -f /usr/libexec/rpcd/tachyon /usr/bin/tachyon-read /etc/hotplug.d/iface/99-tachyon-wan-monitor /etc/init.d/tachyon-torrserver-direct /www/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-sub /usr/lib/cgi-bin/tachyon-agent /etc/uci-defaults/50_luci-tachyon /usr/share/luci/menu.d/luci-app-tachyon.json /usr/share/rpcd/acl.d/luci-app-tachyon.json 2>/dev/null || true
    rm -f /tmp/tachyon-upgrading-from-v1 2>/dev/null || true
fi

rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true

chmod 755 /usr/bin/tachyon /etc/init.d/tachyon 2>/dev/null || true
if [ -x /etc/init.d/tachyon ]; then
    /etc/init.d/tachyon enable >/dev/null 2>&1 || true
    /etc/init.d/tachyon restart >/dev/null 2>&1 || true
fi
exit 0
"""

PRERM_SCRIPT = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
case "${1:-remove}" in
    remove|deinstall|purge)
        if [ -x /etc/init.d/tachyon ]; then
            /etc/init.d/tachyon stop >/dev/null 2>&1 || true
            /etc/init.d/tachyon disable >/dev/null 2>&1 || true
        fi
        rm -f /etc/nftables.d/10-tachyon.nft /tmp/luci-indexcache* 2>/dev/null || true
        if command -v nft >/dev/null 2>&1; then
            nft delete table inet TachyonTable >/dev/null 2>&1 || true
            nft delete table inet tachyon >/dev/null 2>&1 || true
        fi
        ;;
esac
exit 0
"""


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
    for entry in sorted(os.listdir(views_dir)):
        full = os.path.join(views_dir, entry)
        if os.path.isfile(full):
            with open(full, "rb") as f:
                assets.append((entry, f.read()))
    return assets


def build_tar_bundle(
    out_path: str,
    files: list[tuple[str, bytes, int]],
    dirs: list[str],
    mtime: int,
) -> None:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for d in dirs:
            _add_ustar_dir(tf, d, mtime)
        for rel_path, content, mode in files:
            _add_ustar_file(tf, rel_path, content, mode, mtime)
    with open(out_path, "wb") as f:
        f.write(_gzip_bytes(buf.getvalue(), mtime))


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
    prerm_bytes = PRERM_SCRIPT.replace("\r\n", "\n").encode("utf-8")

    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        _add_apk_tar_entry(tf, ".PKGINFO", pkginfo, 0o644, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".pre-install", preinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".pre-upgrade", preinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".post-install", postinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".post-upgrade", postinst_bytes, 0o755, is_dir=False, mtime=mtime)
        _add_apk_tar_entry(tf, ".pre-deinstall", prerm_bytes, 0o755, is_dir=False, mtime=mtime)

    ctrl_raw = _strip_tar_eof(ctrl_buf.getvalue())
    control_tar_gz = _gzip_bytes(ctrl_raw, mtime)

    with open(out_path, "wb") as f:
        f.write(control_tar_gz)
        f.write(data_tar_gz)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True, help="Path to compiled tachyon binary")
    ap.add_argument("--arch", required=True, help="Architecture name (e.g. aarch64, x86_64)")
    ap.add_argument("--version", required=True, help="Version tag (e.g. v2.0.0 or 2.0.0)")
    ap.add_argument("--init", default="openwrt/tachyon.init", help="Path to tachyon procd init script")
    ap.add_argument("--po", default="fe-app-tachyon/locales/tachyon.ru.po", help="Path to Russian .po dictionary")
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
    ap.add_argument("--out-tar", required=True, help="Output .tar.gz path")
    ap.add_argument("--out-ipk", required=True, help="Output .ipk path")
    ap.add_argument("--out-apk", required=True, help="Output .apk path")
    args = ap.parse_args()

    ver_clean = args.version.lstrip("vV")
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", int(time.time())))

    with open(args.bin, "rb") as f:
        bin_bytes = f.read()
    with open(args.init, "rb") as f:
        init_bytes = f.read().replace(b"\r\n", b"\n")

    dirs = [
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
        "www",
        "www/luci-static",
        "www/luci-static/resources",
        "www/luci-static/resources/view",
        "www/luci-static/resources/view/tachyon",
    ]
    files: list[tuple[str, bytes, int]] = [
        ("usr/bin/tachyon", bin_bytes, 0o755),
        ("etc/init.d/tachyon", init_bytes, 0o755),
    ]
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
        files.append((f"www/luci-static/resources/view/tachyon/{name}", content, 0o644))

    installed_size = sum(len(content) for _, content, _ in files)

    for p in (args.out_tar, args.out_ipk, args.out_apk):
        parent = os.path.dirname(os.path.abspath(p))
        if parent:
            os.makedirs(parent, exist_ok=True)

    build_tar_bundle(args.out_tar, files, dirs, mtime)
    build_ipk(args.out_ipk, ver_clean, args.arch, files, dirs, installed_size, mtime)
    build_apk(args.out_apk, ver_clean, args.arch, files, dirs, installed_size, mtime)
    print(
        f"Built {args.out_tar} ({os.path.getsize(args.out_tar)} bytes), "
        f"{args.out_ipk} ({os.path.getsize(args.out_ipk)} bytes), "
        f"{args.out_apk} ({os.path.getsize(args.out_apk)} bytes)"
    )


if __name__ == "__main__":
    main()
