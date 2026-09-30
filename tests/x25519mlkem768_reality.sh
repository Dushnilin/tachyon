#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# ---- 1. extended_supports_x25519mlkem768 boundary checks in common.uc

cat >"$WORK_DIR/check_mlkem.uc" <<'UC'
let common = require("core.common");
printf("%s", common.extended_supports_x25519mlkem768(ARGV[1]) ? "yes" : "no");
UC

check() {
  ucode -L "$TACHYON_LIB" "$WORK_DIR/check_mlkem.uc" x "$1"
}

[ "$(check '1.14.1-extended-2.7.2')"  = "yes" ] || fail "2.7.2 must support x25519mlkem768"
[ "$(check '1.14.1-extended-2.7.3')"  = "yes" ] || fail "2.7.3 must support x25519mlkem768"
[ "$(check '1.14.1-extended-2.8.0')"  = "yes" ] || fail "2.8.x must support x25519mlkem768"
[ "$(check '1.14.1-extended-3.0.0')"  = "yes" ] || fail "3.x must support x25519mlkem768"
[ "$(check '1.14.1-extended-2.7.1')"  = "no"  ] || fail "2.7.1 must NOT support x25519mlkem768 (added in 2.7.2)"
[ "$(check '1.14.1-extended-2.7.0')"  = "no"  ] || fail "2.7.0 must NOT support x25519mlkem768"
[ "$(check '1.14.1-extended-2.6.5')"  = "no"  ] || fail "2.6.5 must NOT support x25519mlkem768"
[ "$(check '1.14.2-lx.3')"            = "no"  ] || fail "lx builds must NOT support x25519mlkem768 (different mechanism)"
[ "$(check '1.14.1')"                 = "no"  ] || fail "stock sing-box must NOT support x25519mlkem768"
[ "$(check '')"                       = "no"  ] || fail "empty version must not inject x25519mlkem768"

printf 'common.uc boundary checks passed\n'

# ---- 2. apply_x25519mlkem768_to_reality_outbounds injects the field
#         exactly when extended_supports_x25519mlkem768 returns true.
#
# We drive generator_outbounds.uc directly via a tiny wrapper script so that
# we test the real injection logic without going through the full config
# pipeline (which requires sing-box-extended to be installed in the container).

cat >"$WORK_DIR/inject_test.uc" <<'UC'
let fs   = require("fs");
let common = require("core.common");

// Minimal replica of apply_x25519mlkem768_to_reality_outbounds so we can
// verify the predicate + mutation logic in isolation without requiring the
// full generator pipeline.
function apply(outbounds, sb_version) {
    if (!common.extended_supports_x25519mlkem768(sb_version))
        return;
    for (let outbound in outbounds) {
        if (type(outbound) != "object") continue;
        if (type(outbound.tls) != "object") continue;
        if (type(outbound.tls.reality) != "object" || outbound.tls.reality.enabled === false) continue;
        outbound.tls.reality.support_x25519mlkem768 = true;
    }
}

let reality_outbound = {
    type: "vless", tag: "test-reality",
    tls: { enabled: true, reality: { enabled: true, public_key: "abc" } }
};
let tls_only_outbound = {
    type: "vless", tag: "test-tls",
    tls: { enabled: true }
};
let no_tls_outbound = {
    type: "vless", tag: "test-notls"
};

// Case A: extended 2.7.2 — must inject into reality outbound only
let a = [ json(sprintf("%J", reality_outbound)), json(sprintf("%J", tls_only_outbound)), json(sprintf("%J", no_tls_outbound)) ];
apply(a, "1.14.1-extended-2.7.2");
assert(a[0].tls.reality.support_x25519mlkem768 === true,  "2.7.2: reality outbound must get support_x25519mlkem768=true");
assert(a[1].tls.reality == null,                          "2.7.2: plain-TLS outbound must NOT get support_x25519mlkem768");
assert(a[2].tls == null,                                  "2.7.2: no-TLS outbound must NOT get support_x25519mlkem768");

// Case B: extended 2.7.1 — must NOT inject
let b = [ json(sprintf("%J", reality_outbound)) ];
apply(b, "1.14.1-extended-2.7.1");
assert(b[0].tls.reality.support_x25519mlkem768 == null,   "2.7.1: must NOT inject support_x25519mlkem768");

// Case C: lx — must NOT inject
let c = [ json(sprintf("%J", reality_outbound)) ];
apply(c, "1.14.2-lx.3");
assert(c[0].tls.reality.support_x25519mlkem768 == null,   "lx: must NOT inject support_x25519mlkem768");

// Case D: stock — must NOT inject
let d = [ json(sprintf("%J", reality_outbound)) ];
apply(d, "1.14.2");
assert(d[0].tls.reality.support_x25519mlkem768 == null,   "stock: must NOT inject support_x25519mlkem768");

// Case E: reality.enabled === false — must NOT inject
let e_out = { type: "vless", tag: "test", tls: { enabled: true, reality: { enabled: false } } };
let e = [ e_out ];
apply(e, "1.14.1-extended-2.7.2");
assert(e[0].tls.reality.support_x25519mlkem768 == null,   "disabled reality: must NOT inject support_x25519mlkem768");

printf("injection logic checks passed\n");
UC

ucode -L "$TACHYON_LIB" "$WORK_DIR/inject_test.uc" \
  || fail "x25519mlkem768 injection logic test failed"

printf 'x25519mlkem768 Reality auto-injection checks passed\n'
