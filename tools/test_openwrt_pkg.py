#!/usr/bin/env python3
"""Offline regression tests for OpenWrt package architecture selection."""

import gzip
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

from build_openwrt_pkg import ELF_TARGETS, _target_triple_family, validate_binary_arch

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    "x86_64": (2, 1, 62),
    "i386_pentium4": (1, 1, 3),
    "aarch64": (2, 1, 183),
    "armv7": (1, 1, 40),
    "armv6": (1, 1, 40),
    "riscv64": (2, 1, 243),
    "mipsel": (1, 1, 8),
    "mips": (1, 2, 8),
}

TARGET_TRIPLES = {
    "x86_64": "x86_64-unknown-linux-musl",
    "i386_pentium4": "i686-unknown-linux-musl",
    "aarch64": "aarch64-unknown-linux-musl",
    "armv7": "armv7-unknown-linux-musleabihf",
    "armv6": "arm-unknown-linux-musleabi",
    "riscv64": "riscv64gc-unknown-linux-musl",
    "mipsel": "mipsel-unknown-linux-musl",
    "mips": "mips-unknown-linux-musl",
}


def elf_header(elf_class, endian, machine):
    """Construct the fields the packager reads from an ELF header."""
    raw = bytearray(52 if elf_class == 1 else 64)
    raw[:7] = b"\x7fELF" + bytes((elf_class, endian, 1))
    order = "little" if endian == 1 else "big"
    raw[16:18] = (2).to_bytes(2, order)
    raw[18:20] = machine.to_bytes(2, order)
    raw[20:24] = (1).to_bytes(4, order)
    return bytes(raw)


class OpenWrtPackageTest(unittest.TestCase):
    def test_all_build_script_targets_are_supported(self):
        build_script = (ROOT / "build.sh").read_text(encoding="utf-8")
        match = re.search(r'^ALL_TACHYON_TARGETS="([^"]+)"$', build_script, re.MULTILINE)
        self.assertIsNotNone(match, "build.sh must declare ALL_TACHYON_TARGETS")
        for pair in match.group(1).split():
            triple, arch = pair.split(":", 1)
            family = _target_triple_family(triple)
            with self.subTest(triple=triple, arch=arch):
                validate_binary_arch(elf_header(*ELF_TARGETS[family]), arch, triple)

    def test_target_matrix_with_rust_triples(self):
        for target, expected in TARGETS.items():
            triple = TARGET_TRIPLES[target]
            with self.subTest(target=target, triple=triple):
                validate_binary_arch(elf_header(*expected), target, triple)

    def test_rejects_mismatched_binary_and_target_triple(self):
        payload = elf_header(*TARGETS["aarch64"])
        with self.assertRaisesRegex(ValueError, "ELF architecture"):
            validate_binary_arch(payload, "vendor-profile", "x86_64-unknown-linux-musl")

    def test_rejects_package_label_that_disagrees_with_build_target(self):
        payload = elf_header(*TARGETS["aarch64"])
        with self.assertRaisesRegex(ValueError, "does not match Rust target triple"):
            validate_binary_arch(payload, "x86_64", "aarch64-unknown-linux-musl")

    def test_custom_package_arch_requires_and_uses_target_triple(self):
        payload = elf_header(*TARGETS["aarch64"])
        validate_binary_arch(payload, "vendor-profile", "aarch64-unknown-linux-musl")
        with self.assertRaisesRegex(ValueError, "pass --target-triple"):
            validate_binary_arch(payload, "vendor-profile")
        with self.assertRaisesRegex(ValueError, "Unsupported Rust target triple"):
            validate_binary_arch(payload, "vendor-profile", "unknown-vendor-triple")

    def test_known_architecture_aliases_remain_supported_without_triple(self):
        payload = elf_header(*TARGETS["aarch64"])
        validate_binary_arch(payload, "aarch64_cortex-a53")
        with self.assertRaisesRegex(ValueError, "ELF architecture"):
            validate_binary_arch(payload, "arm_cortex-a9")

    def test_malformed_headers(self):
        good = elf_header(*TARGETS["aarch64"])
        variants = [
            b"", b"not ELF", good[:16], good[:63],
            good[:4] + b"\x03" + good[5:],  # class
            good[:5] + b"\x00" + good[6:],  # encoding
            good[:6] + b"\x00" + good[7:],  # identification version
            good[:16] + b"\x01\x00" + good[18:],  # relocatable object
            good[:20] + b"\x00" * 4 + good[24:],  # ELF version
        ]
        for raw in variants:
            with self.subTest(raw=raw.hex()), self.assertRaises(ValueError):
                validate_binary_arch(raw, "aarch64")

    def test_package_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            payload = elf_header(*TARGETS["aarch64"]) + b"fixture-only"
            binary = directory / "tachyon"
            binary.write_bytes(payload)
            views = directory / "views"
            views.mkdir()
            ipk, apk = directory / "test.ipk", directory / "test.apk"

            def run(arch, target_triple):
                return subprocess.run(
                    [
                        sys.executable, ROOT / "tools/build_openwrt_pkg.py",
                        "--bin", binary, "--arch", arch,
                        "--target-triple", target_triple,
                        "--version", "2.0.0-test",
                        "--views-dir", views, "--out-ipk", ipk, "--out-apk", apk,
                    ],
                    cwd=ROOT,
                    env={**os.environ, "SOURCE_DATE_EPOCH": "1700000000"},
                    capture_output=True, text=True, timeout=30,
                )

            bad = run("x86_64", "aarch64-unknown-linux-musl")
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("does not match Rust target triple", bad.stderr)
            self.assertFalse(ipk.exists())
            self.assertFalse(apk.exists())

            good = run("vendor-profile", "aarch64-unknown-linux-musl")
            self.assertEqual(good.returncode, 0, good.stderr)
            with tarfile.open(ipk, "r:gz") as outer:
                data = outer.extractfile("./data.tar.gz").read()
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
                self.assertEqual(archive.extractfile("./usr/bin/tachyon").read(), payload)
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(apk.read_bytes())),
                              mode="r:", ignore_zeros=True) as archive:
                self.assertEqual(archive.extractfile("usr/bin/tachyon").read(), payload)


if __name__ == "__main__":
    unittest.main()
