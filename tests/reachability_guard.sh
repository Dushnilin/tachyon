#!/usr/bin/env bash
# Three-signal reachability guard (diagnostics/reachability_guard.uc) and
# priority-level recovery hysteresis in tachyon_core/priority.uc:
#   - distinguishes wan_down vs tunnel_broken vs foreign_blocked vs normal
#   - requires 3 consecutive anomalous samples to escalate
#   - holds escalated state for dwell_seconds (120s) + 8 consecutive normal
#     samples before returning
#   - adds +5 recovery penalty when >3 transitions occur within 600s
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PRIORITY_UC="$TACHYON_LIB/tachyon_core/priority.uc"

out="$(ucode -L "$TACHYON_LIB" -e '
let rg = require("diagnostics.reachability_guard");
let checks = 0;
function check(ok, name) { if (!ok) die("FAIL: " + name + "\n"); checks++; }

// 1. Signal classification
check(rg.classify({ direct_domestic: true, direct_foreign: true, tunnel_foreign: true }) == "normal",
      "all paths healthy -> normal");
check(rg.classify({ direct_domestic: true, direct_foreign: false, tunnel_foreign: true }) == "foreign_blocked",
      "domestic up + direct foreign down + tunnel up -> foreign_blocked");
check(rg.classify({ direct_domestic: true, direct_foreign: true, tunnel_foreign: false }) == "tunnel_broken",
      "domestic up + tunnel down -> tunnel_broken");
check(rg.classify({ direct_domestic: false, direct_foreign: false, tunnel_foreign: false }) == "wan_down",
      "all three paths down -> wan_down");

// 2. WAN outage must NOT escalate tunnel switching
let g = rg.create({ fail_threshold: 3, recover_threshold: 8, dwell_seconds: 120 });
for (let i = 0; i < 5; i++) {
    let s = rg.observe(g, { direct_domestic: false, direct_foreign: false, tunnel_foreign: false, now: 100 + i * 10 });
    check(s.mode == "wan_down" && !s.escalated && s.fail_streak == 0,
          "wan_down does not increment fail_streak or escalate");
}

// 3. Asymmetric confirmation: 3 consecutive foreign_blocked samples escalate
check(!rg.observe(g, { direct_domestic: true, direct_foreign: false, tunnel_foreign: true, now: 200 }).escalated,
      "1st foreign_blocked sample does not escalate");
check(!rg.observe(g, { direct_domestic: true, direct_foreign: false, tunnel_foreign: true, now: 210 }).escalated,
      "2nd foreign_blocked sample does not escalate");
let esc = rg.observe(g, { direct_domestic: true, direct_foreign: false, tunnel_foreign: true, now: 220 });
check(esc.escalated && esc.escalated_at == 220, "3rd consecutive foreign_blocked sample escalates");

// 4. Dwell window (120s) + 8 consecutive normal samples required to de-escalate
for (let i = 1; i <= 8; i++) {
    let s = rg.observe(g, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: 220 + i * 10 });
    check(s.escalated, "stays escalated while inside 120s dwell window (sample " + i + ")");
}
// Once past dwell_seconds (now = 350 >= 220 + 120) and ok_streak >= 8, de-escalates
let deesc = rg.observe(g, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: 350 });
check(!deesc.escalated, "de-escalates once both dwell_seconds and recover_threshold are met");

// 5. Anti-flap penalty: >3 transitions within 600s adds +5 to recover_threshold (8 -> 13)
let flap = rg.create({ fail_threshold: 1, recover_threshold: 8, dwell_seconds: 0, flap_window: 600, flap_limit: 3, flap_penalty: 5 });
let t = 1000;
// Trigger 4 transitions (escalate -> recover -> escalate -> recover)
rg.observe(flap, { direct_domestic: true, direct_foreign: false, tunnel_foreign: true, now: t += 5 });
for (let i = 0; i < 8; i++) rg.observe(flap, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: t += 5 });
rg.observe(flap, { direct_domestic: true, direct_foreign: false, tunnel_foreign: true, now: t += 5 });
for (let i = 0; i < 8; i++) rg.observe(flap, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: t += 5 });

// Next escalation occurs with 4 transitions in window (>3), so recovery now needs 8 + 5 = 13 successes
let fifth = rg.observe(flap, { direct_domestic: true, direct_foreign: false, tunnel_foreign: true, now: t += 5 });
check(fifth.escalated && fifth.recover_target == 13, "anti-flap penalty raises recover_target from 8 to 13");
for (let i = 1; i <= 12; i++) {
    let s = rg.observe(flap, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: t += 5 });
    check(s.escalated, "flap-penalized guard stays escalated at " + i + "/13 successes");
}
let cleared = rg.observe(flap, { direct_domestic: true, direct_foreign: true, tunnel_foreign: true, now: t += 5 });
check(!cleared.escalated, "flap-penalized guard clears on 13th consecutive success");

print(sprintf("PASS: %d reachability_guard checks\n", checks));
' 2>&1)" || fail "reachability_guard checks failed: $out"

echo "$out" | grep -q "^PASS:" || fail "reachability_guard did not report PASS"

grep -Fq 'require("diagnostics.reachability_guard")' "$PRIORITY_UC" ||
  fail "priority.uc does not load diagnostics.reachability_guard"
grep -Fq 'reachability_guard.observe(' "$PRIORITY_UC" ||
  fail "priority.uc does not feed reachability_guard"

printf 'Reachability guard checks passed\n'
