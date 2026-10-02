#!/usr/bin/env bash
# verify_system() declared sb_pid inside the sing-box branch of an if/else but
# read it further down, outside that block. `let` in ucode is block scoped and
# an out-of-scope read yields null silently, and `null != ""` is true - so the
# HTTP-via-proxy probe ran against a dead sing-box, scored a FAIL, and
# local_rule_doctor escalates two failures to restore_native_internet
# (stopping Tachyon) on a router that was merely offline.
#
# This asserts the observed verdict, not the source text: with a mixed inbound
# declared and no engine process, the row must be `skip`, never `fail`.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PROBE="$WORK_DIR/probe.uc"
SB_CONFIG=/etc/sing-box/config.json

cleanup() {
    rm -f "$SB_CONFIG"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if pidof sing-box >/dev/null 2>&1; then
    fail "test needs no sing-box process running"
fi

# Real fixture: a config that declares a mixed inbound, so the check is
# reachable at all. Without it the row is skipped for a different reason and
# the test would pass against the broken code too.
mkdir -p /etc/sing-box
printf '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":2080}]}\n' >"$SB_CONFIG"

cat >"$PROBE" <<'EOF'
let doctor = require("diagnostics.doctor");
let res = doctor.verify_system();
let row = null;
for (let c in (res.checks || [])) {
    if (c.name == "HTTP via proxy") row = c;
}
if (row == null) exit(2);
printf("%s\n", row.status);
EOF

out="$(ucode -L "$TACHYON_LIB" "$PROBE" 2>/dev/null)" || fail "verify_system probe did not run"
printf 'HTTP via proxy => %s\n' "$out" >&2

case "$out" in
    skip) ;;
    fail) fail "probed a dead sing-box as 'fail' (escalates to restore_native_internet)" ;;
    *)    fail "unexpected verdict: $out" ;;
esac

printf 'verify_system dead-engine probe checks passed\n'