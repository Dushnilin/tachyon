#!/usr/bin/env python3
"""Self-contained verification suite for Entware packaging and scripts."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGER = os.path.join(REPO_ROOT, "tools", "build_entware_pkg.py")

LF_CHECK_FILES = (
    "build.sh",
    "install.sh",
    "uninstall.sh",
    "entware/S99tachyon",
    "entware/ndm/netfilter.d/100-tachyon.sh",
    "entware/ndm/ifstatechanged.d/100-tachyon.sh",
    "entware/ndm/fs.d/100-tachyon.sh",
    "entware/merlin/firewall-start.snippet",
    "tools/build_entware_pkg.py",
    "tools/test_entware_pkg.py",
)

SHELL_SYNTAX_FILES = (
    "install.sh",
    "uninstall.sh",
    "entware/S99tachyon",
    "entware/ndm/netfilter.d/100-tachyon.sh",
    "entware/ndm/ifstatechanged.d/100-tachyon.sh",
    "entware/ndm/fs.d/100-tachyon.sh",
)

EXPECTED_MODES = {
    "bin/tachyon": 0o755,
    "etc/init.d/S99tachyon": 0o755,
    "share/tachyon/hooks/ndm/netfilter.d/100-tachyon.sh": 0o755,
    "share/tachyon/hooks/ndm/ifstatechanged.d/100-tachyon.sh": 0o755,
    "share/tachyon/hooks/ndm/fs.d/100-tachyon.sh": 0o755,
    "share/tachyon/hooks/merlin/firewall-start.snippet": 0o644,
    "share/tachyon/entware-manifest.json": 0o644,
    "share/tachyon/www/luci-static/bootstrap/cascade.css": 0o644,
    "share/tachyon/www/luci-static/bootstrap/mobile.css": 0o644,
    "share/tachyon/www/luci-static/resources/cbi.js": 0o644,
    "share/tachyon/www/luci-static/resources/luci.js": 0o644,
    "share/tachyon/www/luci-static/resources/ui.js": 0o644,
    "share/tachyon/www/luci-static/resources/form.js": 0o644,
    "share/tachyon/www/luci-static/resources/uci.js": 0o644,
    "share/tachyon/www/luci-static/resources/rpc.js": 0o644,
    "share/tachyon/www/luci-static/resources/fs.js": 0o644,
    "share/tachyon/www/luci-static/resources/network.js": 0o644,
    "share/tachyon/www/luci-static/resources/tools/widgets.js": 0o644,
    "share/tachyon/www/luci-static/resources/view/tachyon/app.js": 0o644,
    "share/tachyon/www/luci-static/resources/view/tachyon/style.css": 0o644,
    "share/tachyon/www/luci-static/resources/view/tachyon/logo.svg": 0o644,
    "share/tachyon/www/luci-static/resources/view/tachyon/sub/meta.json": 0o644,
}


def check_lf_line_endings() -> None:
    for rel in LF_CHECK_FILES:
        full = os.path.join(REPO_ROOT, rel)
        assert os.path.isfile(full), f"Missing expected file: {rel}"
        with open(full, "rb") as f:
            raw = f.read()
        assert b"\r\n" not in raw, f"CRLF line endings found in {rel}"
    print(f"[OK] LF line endings verified for {len(LF_CHECK_FILES)} files")


def check_posix_shell_syntax() -> None:
    sh_bin = shutil.which("sh")
    if not sh_bin or os.name == "nt":
        print("[INFO] Skipping native /bin/sh -n check on Windows")
        return
    for rel in SHELL_SYNTAX_FILES:
        full = os.path.join(REPO_ROOT, rel)
        res = subprocess.run([sh_bin, "-n", full], capture_output=True, text=True)
        assert res.returncode == 0, f"sh -n failed for {rel}: {res.stderr}"
    print(f"[OK] POSIX sh -n syntax verified for {len(SHELL_SYNTAX_FILES)} scripts")


def check_entware_tarball() -> None:
    with tempfile.TemporaryDirectory(prefix="tachyon-entware-test-") as td:
        mock_bin = os.path.join(td, "tachyon")
        with open(mock_bin, "wb") as f:
            f.write(b"\x7fELFmock-tachyon-binary-payload\n")

        views_dir = os.path.join(td, "views")
        os.makedirs(os.path.join(views_dir, "sub"), exist_ok=True)
        with open(os.path.join(views_dir, "app.js"), "wb") as f:
            f.write(b"console.log('tachyon');\n")
        with open(os.path.join(views_dir, "style.css"), "wb") as f:
            f.write(b"body { margin: 0; }\n")
        with open(os.path.join(views_dir, "logo.svg"), "wb") as f:
            f.write(b"<svg xmlns='http://www.w3.org/2000/svg'/>\n")
        with open(os.path.join(views_dir, "sub", "meta.json"), "wb") as f:
            f.write(b'{"panel": true}\n')
        with open(os.path.join(views_dir, "ignored.map"), "wb") as f:
            f.write(b"source-map-should-not-be-packaged\n")

        out1 = os.path.join(td, "tachyon-entware-mipsel-v2.0.0-rc.1.tar.gz")
        out2 = os.path.join(td, "tachyon-entware-mipsel-v2.0.0-rc.1.second.tar.gz")
        env = dict(os.environ)
        env["SOURCE_DATE_EPOCH"] = "1700000000"

        luci_base_dir = os.path.join(REPO_ROOT, "entware", "www", "luci-static")
        expected_modes = dict(EXPECTED_MODES)
        for root_dir, _dirs, filenames in os.walk(luci_base_dir):
            for fname in filenames:
                full_p = os.path.join(root_dir, fname)
                rel_p = os.path.relpath(full_p, luci_base_dir).replace(os.sep, "/")
                expected_modes[f"share/tachyon/www/luci-static/{rel_p}"] = 0o644

        for out_path in (out1, out2):
            cmd = [
                sys.executable,
                PACKAGER,
                "--bin",
                mock_bin,
                "--arch",
                "mipsel",
                "--version",
                "v2.0.0-rc.1",
                "--views-dir",
                views_dir,
                "--luci-base-dir",
                luci_base_dir,
                "--init",
                os.path.join(REPO_ROOT, "entware", "S99tachyon"),
                "--hooks-dir",
                os.path.join(REPO_ROOT, "entware"),
                "--out-tgz",
                out_path,
            ]
            res = subprocess.run(cmd, capture_output=True, text=True, env=env)
            assert res.returncode == 0, f"build_entware_pkg.py failed: {res.stderr}\n{res.stdout}"

        with open(out1, "rb") as f1, open(out2, "rb") as f2:
            assert f1.read() == f2.read(), "Entware tarball output is not deterministic"

        archived_files: dict[str, tuple[int, bytes]] = {}
        with tarfile.open(out1, "r:gz") as tf:
            for member in tf.getmembers():
                if member.isfile():
                    extracted = tf.extractfile(member)
                    assert extracted is not None
                    archived_files[member.name] = (member.mode & 0o777, extracted.read())
                elif member.isdir():
                    assert (member.mode & 0o777) == 0o755, f"Unexpected dir mode for {member.name}"

        assert "share/tachyon/www/luci-static/resources/view/tachyon/ignored.map" not in archived_files, (
            "Non-asset .map file must not be packaged"
        )

        for expected_path, expected_mode in expected_modes.items():
            assert expected_path in archived_files, f"Missing archived file: {expected_path}"
            actual_mode, data = archived_files[expected_path]
            assert actual_mode == expected_mode, (
                f"Wrong mode for {expected_path}: got {oct(actual_mode)}, expected {oct(expected_mode)}"
            )
            if expected_path != "bin/tachyon" and not expected_path.endswith((".png", ".gif", ".woff2")):
                assert b"\r\n" not in data, f"CRLF found inside archived text file {expected_path}"

        manifest_raw = archived_files["share/tachyon/entware-manifest.json"][1]
        manifest = json.loads(manifest_raw.decode("utf-8"))
        assert manifest["name"] == "tachyon"
        assert manifest["version"] == "2.0.0-rc.1"
        assert manifest["arch"] == "mipsel"
        assert manifest["format"] == "entware-tar.gz"
        assert isinstance(manifest["files"], list) and len(manifest["files"]) == len(expected_modes) - 1

        manifest_paths = set()
        for entry in manifest["files"]:
            path = entry["path"]
            manifest_paths.add(path)
            assert path in archived_files, f"Manifest references missing file: {path}"
            actual_mode, data = archived_files[path]
            assert entry["mode"] == f"{actual_mode:04o}", f"Manifest mode mismatch for {path}"
            assert entry["size"] == len(data), f"Manifest size mismatch for {path}"
            actual_sha = hashlib.sha256(data).hexdigest()
            assert entry["sha256"] == actual_sha, f"Manifest sha256 mismatch for {path}"

        expected_manifest_paths = set(expected_modes.keys()) - {"share/tachyon/entware-manifest.json"}
        assert manifest_paths == expected_manifest_paths, (
            f"Manifest path set mismatch: {manifest_paths ^ expected_manifest_paths}"
        )

        snippet_text = archived_files["share/tachyon/hooks/merlin/firewall-start.snippet"][1].decode("utf-8")
        assert "# >>> tachyon-entware >>>" in snippet_text
        assert "# <<< tachyon-entware <<<" in snippet_text
        assert "reconcile-net" in snippet_text

    print("[OK] Entware tar.gz package build, determinism, permissions, and manifest SHA256 verified")


def main() -> None:
    check_lf_line_endings()
    check_posix_shell_syntax()
    check_entware_tarball()
    print("[OK] All Entware packaging tests passed")


if __name__ == "__main__":
    main()
