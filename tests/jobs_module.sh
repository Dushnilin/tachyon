#!/usr/bin/env bash
set -eo pipefail

# Tests for core/jobs.uc — unified Job Engine.
# Run on the router: bash /tmp/jobs_module.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
  TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
else
  TACHYON_LIB="/usr/lib/tachyon"
fi
JOBS_UC="$TACHYON_LIB/core/jobs.uc"

export TACHYON_RUNTIME_STATE_DIR=$(mktemp -d /tmp/tachyon-jobs-test.XXXXXX)

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

# ── Selftest passes ──────────────────────────────────────────────────────────
ucode "$JOBS_UC" selftest >/dev/null 2>&1 || fail "jobs.uc selftest failed"

# ── Create a job ─────────────────────────────────────────────────────────────
JOB=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "unit", "echo");
  print(j.id + "|" + j.phase + "|" + j.kind + "|" + j.target + "|" + j.action);
')
JOB_ID=$(echo "$JOB" | cut -d'|' -f1)
JOB_PHASE=$(echo "$JOB" | cut -d'|' -f2)
JOB_KIND=$(echo "$JOB" | cut -d'|' -f3)
JOB_TARGET=$(echo "$JOB" | cut -d'|' -f4)
JOB_ACTION=$(echo "$JOB" | cut -d'|' -f5)

[ -n "$JOB_ID" ] || fail "job should have an ID"
assert_eq "created" "$JOB_PHASE" "new job should be in created phase"
assert_eq "test" "$JOB_KIND" "kind should match"
assert_eq "unit" "$JOB_TARGET" "target should match"
assert_eq "echo" "$JOB_ACTION" "action should match"

# ── State file exists ────────────────────────────────────────────────────────
[ -f "$TACHYON_RUNTIME_STATE_DIR/jobs/$JOB_ID.json" ] || fail "job state file should exist"

# ── Lifecycle transitions ────────────────────────────────────────────────────
LIFECYCLE=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "lc", "full");
  j = jobs.queue(j);
  let p1 = j.phase;
  j = jobs.preflight(j);
  let p2 = j.phase;
  j = jobs.transition(j, "running", { pid: "9999" });
  let p3 = j.phase;
  j = jobs.transition(j, "verifying");
  let p4 = j.phase;
  j = jobs.transition(j, "committing");
  let p5 = j.phase;
  j = jobs.complete(j, { exit_code: 0 });
  let p6 = j.phase;
  print(p1 + "," + p2 + "," + p3 + "," + p4 + "," + p5 + "," + p6);
')
assert_eq "queued,preflight,running,verifying,committing,success" "$LIFECYCLE" "full lifecycle should work"

# ── Invalid transitions are rejected ─────────────────────────────────────────
BAD_TRANS=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "bad", "trans");
  j = jobs.queue(j);
  j = jobs.preflight(j);
  let before = j.phase;
  j = jobs.transition(j, "success");
  let after = j.phase;
  print(before + ":" + after + ":" + (j.error != null ? "error" : "no_error"));
')
BAD_BEFORE=$(echo "$BAD_TRANS" | cut -d: -f1)
BAD_AFTER=$(echo "$BAD_TRANS" | cut -d: -f2)
BAD_ERR=$(echo "$BAD_TRANS" | cut -d: -f3)
assert_eq "preflight" "$BAD_BEFORE" "phase should remain before invalid transition"
assert_eq "preflight" "$BAD_AFTER" "phase should remain after invalid transition"
assert_eq "error" "$BAD_ERR" "error should be set on invalid transition"

# ── Query job state ──────────────────────────────────────────────────────────
QUERY=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "q", "query");
  let q = jobs.query(j.id);
  print(q != null && q.id == j.id ? "found" : "missing");
')
assert_eq "found" "$QUERY" "query should find existing job"

# ── List all jobs ────────────────────────────────────────────────────────────
LIST=$(ucode -e '
  let jobs = require("core.jobs");
  let j1 = jobs.create("test", "l1", "list");
  let j2 = jobs.create("test", "l2", "list");
  let all = jobs.list_all();
  print(length(all) >= 2 ? "ok" : "missing");
')
assert_eq "ok" "$LIST" "list_all should find created jobs"

# ── List active jobs excludes terminal ───────────────────────────────────────
ACTIVE=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "a", "active");
  j = jobs.queue(j);
  j = jobs.preflight(j);
  let before = jobs.list_active();
  j = jobs.transition(j, "running", { pid: "1" });
  j = jobs.transition(j, "verifying");
  j = jobs.transition(j, "committing");
  j = jobs.complete(j);
  let after = jobs.list_active();
  let found_before = false;
  let found_after = false;
  for (let j2 in before) { if (j2.id == j.id) found_before = true; }
  for (let j2 in after) { if (j2.id == j.id) found_after = true; }
  print((found_before ? "y" : "n") + ":" + (found_after ? "y" : "n"));
')
ACTIVE_BEFORE=$(echo "$ACTIVE" | cut -d: -f1)
ACTIVE_AFTER=$(echo "$ACTIVE" | cut -d: -f2)
assert_eq "y" "$ACTIVE_BEFORE" "running job should be in active list"
assert_eq "n" "$ACTIVE_AFTER" "completed job should not be in active list"

# ── Stale detection ──────────────────────────────────────────────────────────
STALE=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "s", "stale");
  print(jobs.is_stale(j) ? "stale" : "fresh");
')
assert_eq "fresh" "$STALE" "created job should not be stale"

# ── Generate unique IDs ──────────────────────────────────────────────────────
IDS=$(ucode -e '
  let jobs = require("core.jobs");
  let id1 = jobs.generate_id("cmp", "sing_box", "update");
  let id2 = jobs.generate_id("cmp", "sing_box", "update");
  print(id1 != id2 ? "unique" : "duplicate");
')
assert_eq "unique" "$IDS" "IDs should be unique"

# ── GC removes old terminal jobs ─────────────────────────────────────────────
GC=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "gc", "remove");
  j = jobs.queue(j);
  j = jobs.preflight(j);
  j = jobs.transition(j, "running", { pid: "1" });
  j = jobs.transition(j, "verifying");
  j = jobs.transition(j, "committing");
  j = jobs.complete(j);
  let removed = jobs.gc();
  print(removed >= 0 ? "ok" : "error");
')
assert_eq "ok" "$GC" "gc should run without error"

# ── State file persists across reads ─────────────────────────────────────────
PERSIST=$(ucode -e '
  let jobs = require("core.jobs");
  let j = jobs.create("test", "p", "persist");
  j = jobs.queue(j);
  j = jobs.preflight(j);
  j = jobs.transition(j, "running", { pid: "1" });
  let q1 = jobs.query(j.id);
  let q2 = jobs.query(j.id);
  print(q1.id == q2.id && q1.phase == q2.phase ? "ok" : "mismatch");
')
assert_eq "ok" "$PERSIST" "state should persist across reads"

echo "core/jobs.uc: all tests passed"
