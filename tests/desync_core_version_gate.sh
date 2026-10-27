#!/usr/bin/env bash
# Native desync is a tachyon-core outbound and arrived in 0.1.7.
#
# Two things have to hold:
#   * the capability model answers the question from the version, so an older
#     tachyon-core says no and a 0.1.7 one says yes;
#   * every sing-box build says no, because no sing-box has the outbound at
#     all - a config that names it there aborts the whole start.
#
# The version floor has to be compared with the patch level: 0.1.6 and 0.1.7
# share major.minor, so a major/minor comparison would call them the same
# build and let a broken config through.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

out="$(TACHYON_LIB="$TACHYON_LIB" ucode -L "$TACHYON_LIB" - <<'UCODE'
let cp = require("tachyon_core.core_profile");

function check(condition, message) {
    if (!condition) {
        warn(message + "\n");
        exit(1);
    }
}

// tachyon-core: the floor is 0.1.7.
check(cp.supports_desync("0.1.7", "tachyon-core") === true, "0.1.7 must support native desync");
check(cp.supports_desync("0.2.0", "tachyon-core") === true, "0.2.0 must support native desync");
check(cp.supports_desync("1.0.0", "tachyon-core") === true, "a later major must support native desync");
check(cp.supports_desync("0.1.6", "tachyon-core") === false, "0.1.6 must not support native desync");
check(cp.supports_desync("0.1.5", "tachyon-core") === false, "0.1.5 must not support native desync");
check(cp.supports_desync("0.0.9", "tachyon-core") === false, "0.0.9 must not support native desync");

// The patch level is what decides 0.1.6 vs 0.1.7 - a major/minor
// comparison would say they are the same build.
check(cp.reaches_triple("0.1.6", "0.1.7") === false, "0.1.6 must not reach 0.1.7");
check(cp.reaches_triple("0.1.7", "0.1.7") === true, "0.1.7 must reach 0.1.7");
check(cp.reaches_triple("0.1.10", "0.1.7") === true, "0.1.10 must reach 0.1.7");
check(cp.reaches_triple("0.2.0", "0.1.7") === true, "0.2.0 must reach 0.1.7");
check(cp.reaches_triple("0.0.9", "0.1.7") === false, "0.0.9 must not reach 0.1.7");

// No sing-box build has the outbound, whatever its version says.
check(cp.supports_desync("1.14.3-extended-2.7.3", "extended") === false, "sing-box-extended must not support native desync");
check(cp.supports_desync("1.14.2-lx.12", "lx") === false, "sing-box-lx must not support native desync");
check(cp.supports_desync("1.14.3", "") === false, "stock sing-box must not support native desync");

// An empty version knows nothing, and a capability must never be claimed
// from a version that was never read.
check(cp.supports_desync("", "tachyon-core") === false, "an empty version must not claim native desync");

print("ok");
UCODE
)"

[ "$out" = "ok" ] || fail "native desync capability gate is broken: $out"

printf 'Native desync version gate passed\n'
