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


def _uleb(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _arm_attributes(cpu_arch, vfp_args):
    attributes = _uleb(6) + _uleb(cpu_arch) + _uleb(28) + _uleb(vfp_args)
    file_scope = b"\x01" + (5 + len(attributes)).to_bytes(4, "little") + attributes
    vendor_payload = b"aeabi\0" + file_scope
    vendor = (4 + len(vendor_payload)).to_bytes(4, "little") + vendor_payload
    return b"A" + vendor


def elf_header(
    elf_class, endian, machine, *, arm_arch=None, vfp_args=0,
    arm_flags=None, include_arm_attributes=True,
):
    """Build minimal ELF headers, including real ARM section/attribute tables."""
    raw = bytearray(52 if elf_class == 1 else 64)
    raw[:7] = b"\x7fELF" + bytes((elf_class, endian, 1))
    order = "little" if endian == 1 else "big"
    raw[16:18] = (2).to_bytes(2, order)
    raw[18:20] = machine.to_bytes(2, order)
    raw[20:24] = (1).to_bytes(4, order)
    if machine != 40:
        return bytes(raw)

    if elf_class != 1 or endian != 1:
        raise ValueError("ARM fixture expects ELF32 little-endian")
    flags = arm_flags if arm_flags is not None else 0x05000400
    raw[36:40] = flags.to_bytes(4, "little")
    shstrtab = b"\0.shstrtab\0.ARM.attributes\0"
    shstr_off = len(raw)
    if not include_arm_attributes:
        shoff = shstr_off + len(shstrtab)
        raw[32:36] = shoff.to_bytes(4, "little")
        raw[40:42] = (52).to_bytes(2, "little")
        raw[46:48] = (40).to_bytes(2, "little")
        raw[48:50] = (2).to_bytes(2, "little")
        raw[50:52] = (1).to_bytes(2, "little")
        null = bytes(40)
        shstr = b"".join(value.to_bytes(4, "little") for value in
                         (1, 3, 0, 0, shstr_off, len(shstrtab), 0, 0, 1, 0))
        return bytes(raw) + shstrtab + null + shstr

    if arm_arch is None:
        arm_arch = 10
    attrs = _arm_attributes(arm_arch, vfp_args)
    attrs_off = shstr_off + len(shstrtab)
    shoff = attrs_off + len(attrs)
    raw[32:36] = shoff.to_bytes(4, "little")
    raw[40:42] = (52).to_bytes(2, "little")
    raw[46:48] = (40).to_bytes(2, "little")
    raw[48:50] = (3).to_bytes(2, "little")
    raw[50:52] = (1).to_bytes(2, "little")
    null = bytes(40)
    shstr = b"".join(value.to_bytes(4, "little") for value in
                     (1, 3, 0, 0, shstr_off, len(shstrtab), 0, 0, 1, 0))
    arm_attrs = b"".join(value.to_bytes(4, "little") for value in
                         (11, 0x70000003, 0, 0, attrs_off, len(attrs), 0, 0, 1, 0))
    return bytes(raw) + shstrtab + attrs + null + shstr + arm_attrs


def arm_fixture(target):
    if target == "armv7":
        return {"arm_arch": 10, "vfp_args": 1, "arm_flags": 0x05000400}
    return {"arm_arch": 6, "vfp_args": 0, "arm_flags": 0x05000200}


class OpenWrtPackageTest(unittest.TestCase):
    def test_all_build_script_targets_are_supported(self):
        build_script = (ROOT / "build.sh").read_text(encoding="utf-8")
        match = re.search(r'^ALL_TACHYON_TARGETS="([^"]+)"$', build_script, re.MULTILINE)
        self.assertIsNotNone(match, "build.sh must declare ALL_TACHYON_TARGETS")
        for pair in match.group(1).split():
            triple, arch = pair.split(":", 1)
            family = _target_triple_family(triple)
            fixture = arm_fixture(family) if family in ("armv6", "armv7") else {}
            with self.subTest(triple=triple, arch=arch):
                validate_binary_arch(elf_header(*ELF_TARGETS[family], **fixture), arch, triple)

    def test_target_matrix_with_rust_triples(self):
        for target, expected in TARGETS.items():
            triple = TARGET_TRIPLES[target]
            fixture = arm_fixture(target) if target in ("armv6", "armv7") else {}
            with self.subTest(target=target, triple=triple):
                validate_binary_arch(elf_header(*expected, **fixture), target, triple)

    def test_arm_eabi_float_abi_and_attributes_are_enforced(self):
        cases = [
            ("old EABI", {"arm_arch": 10, "vfp_args": 1, "arm_flags": 0x04000400},
             "EABI version 5"),
            ("soft-float v7", {"arm_arch": 10, "vfp_args": 1, "arm_flags": 0x05000200},
             "hard-float"),
            ("newer ISA", {"arm_arch": 14, "vfp_args": 1, "arm_flags": 0x05000400},
             "exceeds armv7 target"),
            ("base PCS on hard-float", {"arm_arch": 10, "vfp_args": 0, "arm_flags": 0x05000400},
             "VFP argument ABI"),
        ]
        for label, fixture, message in cases:
            with self.subTest(case=label), self.assertRaisesRegex(ValueError, message):
                validate_binary_arch(
                    elf_header(*TARGETS["armv7"], **fixture),
                    "armv7", TARGET_TRIPLES["armv7"],
                )

        hard_float_v6 = elf_header(
            *TARGETS["armv6"], arm_arch=6, vfp_args=0, arm_flags=0x05000400,
        )
        with self.assertRaisesRegex(ValueError, "soft-float"):
            validate_binary_arch(hard_float_v6, "armv6", TARGET_TRIPLES["armv6"])

    def test_arm_attributes_are_required_and_validated(self):
        missing = elf_header(
            *TARGETS["armv7"], arm_arch=10, vfp_args=1,
            arm_flags=0x05000400, include_arm_attributes=False,
        )
        with self.assertRaisesRegex(ValueError, "missing .ARM.attributes"):
            validate_binary_arch(missing, "armv7", TARGET_TRIPLES["armv7"])

        malformed = bytearray(elf_header(
            *TARGETS["armv7"], arm_arch=10, vfp_args=1, arm_flags=0x05000400,
        ))
        shstrtab = b"\0.shstrtab\0.ARM.attributes\0"
        malformed[52 + len(shstrtab)] = ord("X")
        with self.assertRaisesRegex(ValueError, "attributes format"):
            validate_binary_arch(bytes(malformed), "armv7", TARGET_TRIPLES["armv7"])

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
