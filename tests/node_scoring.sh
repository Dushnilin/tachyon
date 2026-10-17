#!/usr/bin/env bash
# Node scoring refinements:
# 1. tachyon_core/priority.uc: choose_fastest_same_level requires at least
#    FASTEST_SWITCH_TOLERANCE_MS (50ms) improvement before switching active node.
# 2. diagnostics/server_stats.uc: candidate_score includes jitter_ms so a noisy
#    node loses to a steady one with the same average latency.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

PRIORITY_UC="$TACHYON_LIB/tachyon_core/priority.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat >"$WORK_DIR/group.json" <<'JSON'
{
  "tag": "pg-main",
  "pick_fastest": true,
  "switch_to_faster_same_priority": true,
  "levels": [
    {
      "id": "lvl-1",
      "order": 0,
      "outbounds": [ "alpha", "beta" ]
    }
  ]
}
JSON

# 1a. Sub-tolerance gain (49ms: 100ms vs 51ms) must NOT switch active node.
cat >"$WORK_DIR/lat-noise.json" <<'JSON'
{ "alpha": 100, "beta": 51 }
JSON
noise_out="$(ucode -L "$TACHYON_LIB" "$PRIORITY_UC" select-faster-fixture "$WORK_DIR/group.json" "$WORK_DIR/lat-noise.json" 0 alpha)"
printf '%s\n' "$noise_out" | grep -Fq '"tag"' &&
  fail "same-level switch must ignore sub-tolerance RTT noise (49ms < 50ms): $noise_out"

# 1b. Improvement at/above tolerance (55ms: 100ms vs 45ms) MUST switch to beta.
cat >"$WORK_DIR/lat-real.json" <<'JSON'
{ "alpha": 100, "beta": 45 }
JSON
real_out="$(ucode -L "$TACHYON_LIB" "$PRIORITY_UC" select-faster-fixture "$WORK_DIR/group.json" "$WORK_DIR/lat-real.json" 0 alpha)"
printf '%s\n' "$real_out" | grep -Fq '"tag": "beta"' ||
  fail "same-level switch must pick candidate when improvement exceeds tolerance: $real_out"

# 2. server_stats.uc candidate_score must penalize jitter_ms.
score_out="$(ucode -L "$TACHYON_LIB" -e '
let stats = require("diagnostics.server_stats");
if (type(stats.candidate_score) != "function")
    die("FAIL: candidate_score is not exported\n");

let steady = {
    avg_latency: 60,
    last_latency: 60,
    jitter_ms: 4,
    consecutive_failures: 0,
    success_rate: 100
};
let spiky = {
    avg_latency: 60,
    last_latency: 60,
    jitter_ms: 45,
    consecutive_failures: 0,
    success_rate: 100
};

let s_steady = stats.candidate_score(steady);
let s_spiky = stats.candidate_score(spiky);
if (!(s_steady < s_spiky))
    die(sprintf("FAIL: steady score (%d) must be lower than spiky score (%d)\n", s_steady, s_spiky));
if (s_spiky - s_steady != 41)
    die(sprintf("FAIL: jitter delta expected 41, got %d\n", s_spiky - s_steady));

print("PASS: node scoring checks\n");
' 2>&1)" || fail "server_stats candidate_score check failed: $score_out"

echo "$score_out" | grep -q "^PASS:" || fail "server_stats check did not report PASS"
printf 'Node scoring checks passed\n'
