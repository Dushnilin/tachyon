#!/usr/bin/env bash
# Bypass-domain pre-resolution must not stall start/restart.
#
# nft populate runs before tachyon-core is up, while dnsmasq still forwards to
# the stopped core (restart() never hands DNS back, and a fail-closed hold keeps
# it on the proxy on purpose). The old loop ran `nslookup <d> 127.0.0.1`, then
# `nslookup <d>`, with no timeout, for up to 64 domains: BusyBox waits 5 s per
# unanswered lookup, so a restart sat ~5 minutes in this loop. The fail-closed
# gate correctly kept the LAN closed meanwhile; the window was what was wrong. A user log showed 22:29:31 -> 22:35:11 of
# silence between the last set load and the next section.
#
# Checked here: the decisions through the real module with stubbed lookups, and
# the real lookup path against an nslookup that never answers.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

APPLY_UC="$TACHYON_LIB/nft/apply.uc"
[ -f "$TACHYON_LIB/nft/bypass_resolve.uc" ] || fail "nft/bypass_resolve.uc not found"

# --- decisions, with injected lookups and clock -------------------------------
cat >"$WORK_DIR/decide.uc" <<'UCODE'
let br = require("nft.bypass_resolve");
let errors = [];
let note = function(m) { push(errors, m); };

let domains = [];
for (let i = 0; i < 64; i++) push(domains, "d" + i + ".example");

// A resolver that never answers: two slow lookups in a row end the pass.
let calls = 0;
let logged = [];
let r = br.resolve_bypass_domains(domains, {
    lookup: function(d) { calls++; return { output: "", timed_out: true }; },
    log: function(m) { push(logged, m); }
});
if (calls != br.MAX_SLOW_IN_A_ROW) note("dead resolver: " + calls + " lookups, want " + br.MAX_SLOW_IN_A_ROW);
if (r.stopped != "unresponsive") note("dead resolver: stopped=" + r.stopped);
if (length(logged) != 1) note("a cut-short pass must say so once, logged " + length(logged));

// Slow-but-answering lookups (no timeout binary: no timed_out flag, but the
// clock moves): stopped by elapsed time, not by the flag.
let clock = 1000;
calls = 0;
r = br.resolve_bypass_domains(domains, {
    now: function() { return clock; },
    lookup: function(d) { calls++; clock += 5; return { output: "", timed_out: false }; }
});
if (calls != br.MAX_SLOW_IN_A_ROW) note("5 s lookups without a flag: " + calls + " lookups, want " + br.MAX_SLOW_IN_A_ROW);

// Answers that each take just under the slow threshold: only the budget stops them.
clock = 1000;
calls = 0;
r = br.resolve_bypass_domains(domains, {
    now: function() { return clock; },
    lookup: function(d) { calls++; clock += 1; return { output: "Name: x\nAddress: 1.1.1." + calls, timed_out: false }; }
});
if (r.stopped != "budget") note("budget: stopped=" + r.stopped);
if (calls > br.PASS_BUDGET_S + 1) note("budget: " + calls + " lookups in a " + br.PASS_BUDGET_S + " s budget");

// One slow lookup between fast ones is not a dead resolver.
let n = 0;
r = br.resolve_bypass_domains([ "a", "b", "c", "d" ], {
    lookup: function(d) { n++; return { output: "Name: " + d + "\nAddress: 10.0.0." + n, timed_out: (n == 2) }; }
});
if (r.attempted != 4 || r.stopped != null) note("isolated slow lookup ended the pass: attempted=" + r.attempted + " stopped=" + r.stopped);

// A healthy resolver: every domain tried, answers parsed, deduplicated, and
// the server header, loopback and FakeIP addresses ignored.
let busybox = "Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nNon-authoritative answer:\nName:\tex.com\nAddress: 93.184.215.14\nAddress: 198.18.0.5\nAddress: 127.0.0.1\n\nName:\tex.com\nAddress: 2606:2800::1\n";
r = br.resolve_bypass_domains([ "ex.com", "ex.com" ], { lookup: function(d) { return { output: busybox, timed_out: false }; } });
if (r.attempted != 2 || r.stopped != null) note("healthy: attempted=" + r.attempted + " stopped=" + r.stopped);
if (length(r.ips) != 1 || r.ips[0] != "93.184.215.14") note("healthy: ips=" + sprintf("%J", r.ips));

if (length(errors) > 0) { for (let e in errors) print(e + "\n"); exit(1); }
print("decisions ok\n");
UCODE
out="$(ucode -L "$TACHYON_LIB" "$WORK_DIR/decide.uc" 2>&1)" || fail "bypass resolve decisions:
$out"
printf '%s\n' "$out"

# --- real lookup path against a resolver that never answers -------------------
command -v timeout >/dev/null 2>&1 || fail "the test needs a timeout binary"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nslookup" <<'SH'
#!/bin/sh
# BusyBox against a dead upstream: ";; connection timed out" after 5 s, exit 1.
sleep 5
echo ";; connection timed out; no servers could be reached"
exit 1
SH
chmod +x "$WORK_DIR/bin/nslookup"

cat >"$WORK_DIR/real.uc" <<'UCODE'
let br = require("nft.bypass_resolve");
let domains = [];
for (let i = 0; i < 64; i++) push(domains, "d" + i + ".example");
let r = br.resolve_bypass_domains(domains);
printf("%d %s\n", r.attempted, r.stopped);
UCODE
start=$(date +%s)
real="$(PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$WORK_DIR/real.uc" 2>&1)" || fail "real path: $real"
elapsed=$(( $(date +%s) - start ))
# Old code: 64 domains x (5 s + 5 s) = 640 s. Bounded: two 2 s lookups.
[ "$elapsed" -le 8 ] || fail "64 domains against a dead resolver took ${elapsed}s (want <= 8s): $real"
[ "$real" = "2 unresponsive" ] || fail "real path result: $real"
printf 'dead resolver: %s in %ss\n' "$real" "$elapsed"

# --- apply.uc goes through the bounded resolver -------------------------------
code="$(grep -v '^[[:space:]]*//' "$APPLY_UC")"
if grep -q '"nslookup"' <<<"$code"; then
  fail "nft/apply.uc still runs nslookup itself, outside the bounded resolver"
fi
grep -q 'require("nft.bypass_resolve").resolve_bypass_domains(bypass_domains' <<<"$code" ||
  fail "nft/apply.uc does not resolve bypass domains through nft/bypass_resolve.uc"

printf 'PASS: nft_bypass_resolve_budget\n'
