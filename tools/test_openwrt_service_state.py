#!/usr/bin/env python3
"""Check the service actions in the generated OpenWrt package hooks."""

import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

from build_openwrt_pkg import build_apk, build_ipk


def check_service_actions(hook, scratch, *, upgrade_env, enabled, expected):
    subprocess.run(["/bin/sh", "-n"], input=hook, text=True, check=True)

    # Execute only the service block against a fake filesystem and init command.
    header, guard, _ = hook.partition('[ -n "${IPKG_INSTROOT}" ] && exit 0\n')
    marker = "\nif [ -x /etc/init.d/tachyon ]; then\n"
    _, found, service_block = hook.rpartition(marker)
    assert guard and found

    fake_init = scratch / "tachyon-init"
    fake_init.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$1" >> "$TRACE_FILE"\n'
        'if [ "$1" = enabled ]; then [ "$SERVICE_ENABLED" = 1 ]; fi\n',
        encoding="utf-8",
    )
    fake_init.chmod(0o755)
    trace = scratch / "trace"
    trace.write_text("", encoding="utf-8")

    service = (found + service_block).replace("/etc/init.d/tachyon", '"$FAKE_INIT"')
    service = service.replace("/proc/[0-9]*", '"$EMPTY_PROC"/[0-9]*')
    subprocess.run(
        ["/bin/sh"],
        input=header + "killall() { :; }\n" + service,
        text=True,
        check=True,
        timeout=10,
        env={
            "PKG_UPGRADE": upgrade_env,
            "SERVICE_ENABLED": "1" if enabled else "0",
            "TRACE_FILE": str(trace),
            "FAKE_INIT": str(fake_init),
            "EMPTY_PROC": str(scratch),
        },
    )
    actions = trace.read_text(encoding="utf-8").splitlines()
    assert actions == expected, f"Expected service actions {expected}, got {actions}"


def main():
    with tempfile.TemporaryDirectory(prefix="tachyon-openwrt-hooks-") as temp_dir:
        scratch = Path(temp_dir)
        apk, ipk = scratch / "tachyon.apk", scratch / "tachyon.ipk"
        binary = b"fixture"
        package_args = (
            "2.0.0", "aarch64", [("usr/bin/tachyon", binary, 0o755)], [], len(binary), 0
        )
        build_apk(apk, *package_args)
        build_ipk(ipk, *package_args)

        with tarfile.open(apk, "r:gz") as archive:
            apk_install = archive.extractfile(".post-install").read().decode()
            apk_upgrade = archive.extractfile(".post-upgrade").read().decode()
        with tarfile.open(ipk, "r:gz") as archive:
            control = io.BytesIO(archive.extractfile("./control.tar.gz").read())
        with tarfile.open(fileobj=control, mode="r:gz") as archive:
            ipk_postinst = archive.extractfile("./postinst").read().decode()

        for hook in (apk_install, ipk_postinst):
            check_service_actions(
                hook, scratch, upgrade_env="0", enabled=False, expected=["enable", "stop", "start"]
            )
        for hook, upgrade_env in ((apk_upgrade, "0"), (ipk_postinst, "1")):
            check_service_actions(
                hook, scratch, upgrade_env=upgrade_env, enabled=False, expected=["enabled"]
            )
            check_service_actions(
                hook, scratch, upgrade_env=upgrade_env, enabled=True, expected=["enabled", "stop", "start"]
            )
    print("OpenWrt APK and IPK install/upgrade service actions passed")


if __name__ == "__main__":
    main()
