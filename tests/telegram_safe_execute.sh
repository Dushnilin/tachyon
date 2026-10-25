#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/tachyon" <<'SH'
#!/bin/sh
echo "TACHYON_STUB: $@"
exit 0
SH
chmod +x "$WORK_DIR/bin/tachyon"

cat >"$WORK_DIR/test_safe_exec.uc" <<'UCODE'
let rendering = require("service.telegram.rendering");
let common = require("core.common");
let as_string = common.as_string;

rendering.safe_exec_patterns.tachyon.bin = getenv("STUB_BIN");

let safe_execute = rendering.safe_execute;

// 1. restore_native_internet must be allowed
let res1 = safe_execute("tachyon restore_native_internet");
if (res1.status != 0) {
    print("FAILED: restore_native_internet rejected: " + as_string(res1.output) + "\n");
    exit(1);
}

// 2. restart must be allowed
let res2 = safe_execute("tachyon restart");
if (res2.status != 0) {
    print("FAILED: restart rejected: " + as_string(res2.output) + "\n");
    exit(2);
}

// 3. stop must be allowed
let res3 = safe_execute("tachyon stop");
if (res3.status != 0) {
    print("FAILED: stop rejected: " + as_string(res3.output) + "\n");
    exit(3);
}

// 4. malicious or unapproved command must be blocked
let res4 = safe_execute("tachyon dangerous_cmd");
if (res4.status == 0) {
    print("FAILED: dangerous_cmd was allowed\n");
    exit(4);
}
if (index(as_string(res4.output), "not in the whitelist") < 0) {
    print("FAILED: expected not in the whitelist, got: " + as_string(res4.output) + "\n");
    exit(5);
}

print("telegram_safe_execute: OK\n");
UCODE

STUB_BIN="$WORK_DIR/bin/tachyon" TACHYON_LIB="$LIB_DIR" PATH="$WORK_DIR/bin:$PATH" ucode -L "$LIB_DIR" "$WORK_DIR/test_safe_exec.uc"
