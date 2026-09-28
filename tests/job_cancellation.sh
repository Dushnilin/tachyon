#!/usr/bin/env bash
set -eo pipefail

# Tests for cooperative job cancellation, critical section protection,
# safe point execution, and LIFO rollback compensations.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi
if [ -z "$TACHYON_BIN" ]; then
  if [ -f "$ROOT_DIR/tachyon/files/usr/bin/tachyon" ]; then
    TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"
  else
    TACHYON_BIN="/usr/bin/tachyon"
  fi
fi
JOBS_UC="$TACHYON_LIB/core/jobs.uc"

TACHYON_RUNTIME_STATE_DIR="$(mktemp -d /tmp/tachyon-cancel-test.XXXXXX)"
export TACHYON_RUNTIME_STATE_DIR
export TACHYON_LIB

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

cleanup() {
  rm -rf "$TACHYON_RUNTIME_STATE_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  ls -la "$TACHYON_RUNTIME_STATE_DIR" >&2 || true
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

echo "=== Running jobs.uc internal selftest ==="
ucode "$JOBS_UC" selftest >/dev/null 2>&1 || fail "jobs.uc selftest failed"

echo "=== Test 1: Module exports check ==="
EXPORTS_OK=$(ucode -e '
  let jobs = require("core.jobs");
  let required = [
    "request_cancel", "is_cancel_requested", "check_cancellation",
    "cancel", "cancel_force", "enter_critical_section",
    "leave_critical_section", "with_critical_section",
    "register_rollback", "execute_rollback", "handle_cancellation",
    "run_steps"
  ];
  let missing = [];
  for (let fn in required) {
    if (type(jobs[fn]) != "function")
      push(missing, fn);
  }
  print(length(missing) == 0 ? "ok" : join(",", missing));
')
assert_eq "ok" "$EXPORTS_OK" "all cancellation API functions must be exported"

echo "=== Test 2: Cooperative cancellation lifecycle ==="
COOP_RES=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "coop", "test2");
  j = jobs.queue(j);
  j = jobs.preflight(j);
  j = jobs.transition(j, "running");

  let before_cancel = jobs.is_cancel_requested(j);
  jobs.request_cancel(j.id, "Operator cancelled job");
  let after_cancel = jobs.is_cancel_requested(j);

  let chk = jobs.check_cancellation(j);
  let final_state = jobs.query(j.id);

  print((before_cancel ? "y" : "n") + "|" +
        (after_cancel ? "y" : "n") + "|" +
        (chk.cancelled ? "y" : "n") + "|" +
        final_state.phase + "|" +
        final_state.cancel_reason);
')
COOP_BEFORE=$(echo "$COOP_RES" | cut -d'|' -f1)
COOP_AFTER=$(echo "$COOP_RES" | cut -d'|' -f2)
COOP_CHK=$(echo "$COOP_RES" | cut -d'|' -f3)
COOP_PHASE=$(echo "$COOP_RES" | cut -d'|' -f4)
COOP_REASON=$(echo "$COOP_RES" | cut -d'|' -f5)

assert_eq "n" "$COOP_BEFORE" "is_cancel_requested should be false initially"
assert_eq "y" "$COOP_AFTER" "is_cancel_requested should be true after request_cancel"
assert_eq "y" "$COOP_CHK" "check_cancellation should return cancelled=true"
assert_eq "cancelled" "$COOP_PHASE" "job phase should be cancelled"
assert_eq "Operator cancelled job" "$COOP_REASON" "cancel reason should match"

echo "=== Test 3: Critical section protection and safe point deferral ==="
CS_RES=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "cs", "test3");
  j = jobs.queue(j);
  j = jobs.transition(j, "running");

  jobs.enter_critical_section(j, "firmware_write");
  let in_cs_initial = j.in_critical_section;

  // Controller requests cancellation while worker is inside critical section
  jobs.request_cancel(j.id, "Emergency stop during flash");

  // Worker periodically checks cancellation at checkpoint inside critical section
  let chk_inside = jobs.check_cancellation(j);
  let phase_inside = j.phase;

  // Worker finishes critical section and signals safe point
  let leave_res = jobs.leave_critical_section(j);
  let final_state = jobs.query(j.id);

  print((in_cs_initial ? "y" : "n") + "|" +
        (chk_inside.deferred ? "y" : "n") + "|" +
        (chk_inside.cancelled ? "y" : "n") + "|" +
        phase_inside + "|" +
        (leave_res.safe_point ? "y" : "n") + "|" +
        (leave_res.cancelled ? "y" : "n") + "|" +
        final_state.phase);
')
CS_IN=$(echo "$CS_RES" | cut -d'|' -f1)
CS_DEFERRED=$(echo "$CS_RES" | cut -d'|' -f2)
CS_INSIDE_CANCELLED=$(echo "$CS_RES" | cut -d'|' -f3)
CS_INSIDE_PHASE=$(echo "$CS_RES" | cut -d'|' -f4)
CS_SAFE_POINT=$(echo "$CS_RES" | cut -d'|' -f5)
CS_LEAVE_CANCELLED=$(echo "$CS_RES" | cut -d'|' -f6)
CS_FINAL_PHASE=$(echo "$CS_RES" | cut -d'|' -f7)

assert_eq "y" "$CS_IN" "in_critical_section should be true"
assert_eq "y" "$CS_DEFERRED" "check inside critical section should report deferred=true"
assert_eq "n" "$CS_INSIDE_CANCELLED" "cancellation must NOT execute inside critical section"
assert_eq "running" "$CS_INSIDE_PHASE" "job phase must remain running inside critical section"
assert_eq "y" "$CS_SAFE_POINT" "safe point must be reported upon leaving critical section"
assert_eq "y" "$CS_LEAVE_CANCELLED" "cancellation must trigger automatically when safe point is reached"
assert_eq "cancelled" "$CS_FINAL_PHASE" "final state must be cancelled"

echo "=== Test 4: with_critical_section helper wrapper ==="
WCS_RES=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "wcs", "test4");
  j = jobs.queue(j);
  j = jobs.transition(j, "running");

  let work_done = false;
  let cs_res = jobs.with_critical_section(j, "atomic_block", function() {
    work_done = true;
    jobs.request_cancel(j.id, "Cancel while inside block");
    return 42;
  });

  let final_state = jobs.query(j.id);
  print((work_done ? "y" : "n") + "|" +
        cs_res.result + "|" +
        (cs_res.cancelled ? "y" : "n") + "|" +
        final_state.phase);
')
WCS_WORK=$(echo "$WCS_RES" | cut -d'|' -f1)
WCS_VAL=$(echo "$WCS_RES" | cut -d'|' -f2)
WCS_CANC=$(echo "$WCS_RES" | cut -d'|' -f3)
WCS_PHASE=$(echo "$WCS_RES" | cut -d'|' -f4)

assert_eq "y" "$WCS_WORK" "critical work block must run to completion"
assert_eq "42" "$WCS_VAL" "critical work result must be returned"
assert_eq "y" "$WCS_CANC" "with_critical_section must report cancelled=true after exit"
assert_eq "cancelled" "$WCS_PHASE" "final state must be cancelled"

echo "=== Test 5: LIFO Rollback compensations on cancellation ==="
RB_RES=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "rb", "test5");
  j = jobs.queue(j);
  j = jobs.transition(j, "running");

  let run_order = [];
  jobs.register_rollback(j, function() { push(run_order, "comp1"); });
  jobs.register_rollback(j, function() { push(run_order, "comp2"); });
  jobs.register_rollback(j, function() { push(run_order, "comp3"); });

  jobs.request_cancel(j.id, "Cancel with compensations");
  jobs.check_cancellation(j);

  let final_state = jobs.query(j.id);
  print(join("->", run_order) + "|" +
        (final_state.rolled_back ? "y" : "n") + "|" +
        final_state.phase);
')
RB_ORDER=$(echo "$RB_RES" | cut -d'|' -f1)
RB_STATUS=$(echo "$RB_RES" | cut -d'|' -f2)
RB_PHASE=$(echo "$RB_RES" | cut -d'|' -f3)

assert_eq "comp3->comp2->comp1" "$RB_ORDER" "compensations must run in strict LIFO order"
assert_eq "y" "$RB_STATUS" "rolled_back flag must be true"
assert_eq "cancelled" "$RB_PHASE" "job phase must be cancelled"

echo "=== Test 6: Multi-step runner (run_steps) cooperative cancellation ==="
STEPS_RES=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "steps", "test6");
  j = jobs.queue(j);
  j = jobs.transition(j, "running");

  let executed = [];
  let compensated = [];

  let steps = [
    {
      name: "prepare",
      run: function(job) { push(executed, "prepare"); },
      rollback: function(job) { push(compensated, "rb_prepare"); }
    },
    {
      name: "download",
      run: function(job) {
        push(executed, "download");
        // Cancellation requested during download step
        jobs.request_cancel(job.id, "Download aborted");
      },
      rollback: function(job) { push(compensated, "rb_download"); }
    },
    {
      name: "install",
      run: function(job) { push(executed, "install"); },
      rollback: function(job) { push(compensated, "rb_install"); }
    }
  ];

  let result = jobs.run_steps(j, steps);
  let final_state = jobs.query(j.id);

  print((result.cancelled ? "y" : "n") + "|" +
        join(",", executed) + "|" +
        join(",", compensated) + "|" +
        final_state.phase);
')
STEPS_CANC=$(echo "$STEPS_RES" | cut -d'|' -f1)
STEPS_EXEC=$(echo "$STEPS_RES" | cut -d'|' -f2)
STEPS_COMP=$(echo "$STEPS_RES" | cut -d'|' -f3)
STEPS_PHASE=$(echo "$STEPS_RES" | cut -d'|' -f4)

assert_eq "y" "$STEPS_CANC" "run_steps must return cancelled=true"
assert_eq "prepare,download" "$STEPS_EXEC" "install step must NOT be executed"
assert_eq "rb_download,rb_prepare" "$STEPS_COMP" "compensations must run for completed steps in LIFO order"
assert_eq "cancelled" "$STEPS_PHASE" "final state must be cancelled"

echo "=== Test 7: CLI dispatch via tachyon binary ==="
chmod +x "$TACHYON_BIN"

run_tachyon() {
  if [ -x "$TACHYON_BIN" ] && "$TACHYON_BIN" >/dev/null 2>&1; then
    "$TACHYON_BIN" "$@"
  else
    ucode -- "$TACHYON_BIN" "$@"
  fi
}

# Create a job to manipulate via CLI
CLI_JOB_ID=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "cli", "test7");
  j = jobs.queue(j);
  j = jobs.transition(j, "running");
  print(j.id);
')

# 7a: job_list includes the job
LIST_OUT=$(run_tachyon job_list --all)
echo "$LIST_OUT" | grep -q "$CLI_JOB_ID" || fail "CLI job_list should include $CLI_JOB_ID"

# 7b: job_query returns valid JSON
QUERY_OUT=$(run_tachyon job_query "$CLI_JOB_ID")
echo "$QUERY_OUT" | grep -q "\"id\": \"$CLI_JOB_ID\"" || fail "CLI job_query should return job details"

# 7c: job_request_cancel signals cancellation
REQ_OUT=$(run_tachyon job_request_cancel "$CLI_JOB_ID" "Testing CLI request-cancel")
echo "$REQ_OUT" | grep -q '"ok": true' || fail "CLI job_request_cancel should succeed"

QUERY_OUT_AFTER=$(run_tachyon job_query "$CLI_JOB_ID")
echo "$QUERY_OUT_AFTER" | grep -q '"cancel_requested": true' || fail "job should have cancel_requested=true"

# 7d: job_cancel with --force
CANCEL_OUT=$(run_tachyon job_cancel "$CLI_JOB_ID" --force "Force stop test")
echo "$CANCEL_OUT" | grep -q '"ok": true' || fail "CLI job_cancel should succeed"

QUERY_OUT_FINAL=$(run_tachyon job_query "$CLI_JOB_ID")
echo "$QUERY_OUT_FINAL" | grep -q '"phase": "cancelled"' || fail "job should be in cancelled phase"

# 7e: job_gc runs without error
GC_OUT=$(run_tachyon job_gc)
echo "$GC_OUT" | grep -q "Removed" || fail "job_gc should report removed jobs count"

echo "job_cancellation.sh: ALL TESTS PASSED SUCCESSFULLY"
