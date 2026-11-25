#!/usr/bin/env python3
"""Build deterministic Entware tar.gz bundles for tachyon.

Uses only Python stdlib (tarfile, gzip, hashlib, io, json) and produces
reproducible archives rooted at an Entware prefix (typically /opt).
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import tarfile
import time


VIEW_EXTENSIONS = (".js", ".css", ".svg", ".json")

HOOK_SPECS = (
    ("ndm/netfilter.d/100-tachyon.sh", "share/tachyon/hooks/ndm/netfilter.d/100-tachyon.sh", 0o755),
    (
        "ndm/ifstatechanged.d/100-tachyon.sh",
        "share/tachyon/hooks/ndm/ifstatechanged.d/100-tachyon.sh",
        0o755,
    ),
    ("ndm/fs.d/100-tachyon.sh", "share/tachyon/hooks/ndm/fs.d/100-tachyon.sh", 0o755),
    ("merlin/firewall-start.snippet", "share/tachyon/hooks/merlin/firewall-start.snippet", 0o644),
)


def _gzip_bytes(raw: bytes, mtime: int = 0) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, compresslevel=9, mtime=mtime) as gz:
        gz.write(raw)
    return buf.getvalue()


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


def _collect_view_assets(views_dir: str) -> list[tuple[str, bytes]]:
    assets: list[tuple[str, bytes]] = []
    if not views_dir or not os.path.isdir(views_dir):
        return assets
    for root, dirs, files in os.walk(views_dir):
        dirs.sort()
        for entry in sorted(files):
            if not entry.lower().endswith(VIEW_EXTENSIONS):
                continue
            full = os.path.join(root, entry)
            if os.path.isfile(full):
                rel = os.path.relpath(full, views_dir).replace(os.sep, "/")
                with open(full, "rb") as f:
                    raw = f.read().replace(b"\r\n", b"\n")
                assets.append((rel, raw))
    return sorted(assets, key=lambda item: item[0])


def _collect_parent_dirs(paths: list[str]) -> list[str]:
    dirs: set[str] = set()
    for path in paths:
        parts = path.strip("/").split("/")[:-1]
        cur = ""
        for part in parts:
            cur = f"{cur}/{part}" if cur else part
            dirs.add(cur)
    return sorted(dirs)


def build_entware_tarball(
    bin_path: str,
    arch: str,
    version: str,
    views_dir: str,
    init_path: str,
    hooks_dir: str,
    out_tgz: str,
    mtime: int | None = None,
) -> dict:
    ver_clean = version.lstrip("vV")
    if mtime is None:
        mtime = int(os.environ.get("SOURCE_DATE_EPOCH", int(time.time())))

    with open(bin_path, "rb") as f:
        bin_bytes = f.read()
    with open(init_path, "rb") as f:
        init_bytes = f.read().replace(b"\r\n", b"\n")

    files: list[tuple[str, bytes, int]] = [
        ("bin/tachyon", bin_bytes, 0o755),
        ("etc/init.d/S99tachyon", init_bytes, 0o755),
    ]

    for src_rel, dst_rel, mode in HOOK_SPECS:
        src_full = os.path.join(hooks_dir, src_rel)
        if not os.path.isfile(src_full):
            raise FileNotFoundError(f"Required Entware hook file not found: {src_full}")
        with open(src_full, "rb") as f:
            hook_bytes = f.read().replace(b"\r\n", b"\n")
        files.append((dst_rel, hook_bytes, mode))

    for rel_name, content in _collect_view_assets(views_dir):
        dst_rel = f"share/tachyon/www/luci-static/resources/view/tachyon/{rel_name}"
        files.append((dst_rel, content, 0o644))

    files.sort(key=lambda item: item[0])

    manifest_files = [
        {
            "path": rel_path,
            "mode": f"{mode:04o}",
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        }
        for rel_path, content, mode in files
    ]
    manifest = {
        "name": "tachyon",
        "version": ver_clean,
        "arch": arch,
        "format": "entware-tar.gz",
        "files": manifest_files,
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    files.append(("share/tachyon/entware-manifest.json", manifest_bytes, 0o644))
    files.sort(key=lambda item: item[0])

    dirs = _collect_parent_dirs([rel_path for rel_path, _, _ in files])

    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for d in dirs:
            _add_ustar_dir(tf, d, mtime)
        for rel_path, content, mode in files:
            _add_ustar_file(tf, rel_path, content, mode, mtime)

    parent = os.path.dirname(os.path.abspath(out_tgz))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out_tgz, "wb") as f:
        f.write(_gzip_bytes(tar_buf.getvalue(), mtime))

    return manifest


def main() -> None:
    ap = argparse.ArgumentParser(description="Build Entware tar.gz package for tachyon")
    ap.add_argument("--bin", required=True, help="Path to compiled tachyon binary")
    ap.add_argument("--arch", required=True, help="Target architecture (e.g. aarch64, mipsel)")
    ap.add_argument("--version", required=True, help="Release version (e.g. v2.0.0 or 2.0.0)")
    ap.add_argument(
        "--views-dir",
        default="luci-app-tachyon/htdocs/luci-static/resources/view/tachyon",
        help="Path to compiled web UI assets directory",
    )
    ap.add_argument("--init", default="entware/S99tachyon", help="Path to Entware init script")
    ap.add_argument("--hooks-dir", default="entware", help="Root directory containing ndm/ and merlin/ hooks")
    ap.add_argument("--out-tgz", required=True, help="Output .tar.gz path")
    args = ap.parse_args()

    build_entware_tarball(
        bin_path=args.bin,
        arch=args.arch,
        version=args.version,
        views_dir=args.views_dir,
        init_path=args.init,
        hooks_dir=args.hooks_dir,
        out_tgz=args.out_tgz,
    )
    print(f"Built {args.out_tgz} ({os.path.getsize(args.out_tgz)} bytes)")


if __name__ == "__main__":
    main()
