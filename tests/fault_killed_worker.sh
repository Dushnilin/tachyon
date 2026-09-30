#!/usr/bin/env bash
# FAULT: the worker is killed mid-operation.
#
# Everything in the job engine assumes the worker gets to report its own
# outcome. A worker killed by the OOM killer, by an operator, or by a crash does
# not: it never calls fail(), never calls complete(), never runs its
# compensations. So the scenario is not an edge case, it is what a router under
# memory pressure actually does.
#
# The contract when that happens: the job must not stay running forever, the
# compensations registered for it must run, and the reason must be recorded
# rather than inferred.
#
# Spawns a real process, so this needs a real kernel - it runs in the container
# and on a router alike. It is deliberately not mocked, because the thing being
# tested is precisely that the process disappeared.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

if [ -z "$TACHYON_LIB" ]; then
  if [ -d "$ROOT_DIR/tachyon/files/usr/lib/core" ]; then
    TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
  else
    TACHYON_LIB="/usr/lib/tachyon"
  fi
fi
export TACHYON_LIB
JOBS_UC="$TACHYON_LIB/core/jobs.uc"

TACHYON_RUNTIME_STATE_DIR="$(mktemp -d /tmp/tachyon-kill-worker.XXXXXX)"
export TACHYON_RUNTIME_STATE_DIR
trap 'rm -rf "$TACHYON_RUNTIME_STATE_DIR"' EXIT HUP INT TERM

pass_count=0
ok() { pass_count=$((pass_count + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$JOBS_UC" ] || fail "core/jobs.uc not found at $JOBS_UC"

j() { ucode -L "$TACHYON_LIB" -e "$1" 2>&1; }

# --- a job whose worker is killed ------------------------------------------
# Built by hand rather than through start_shell() so the recorded pid is a
# process we control and can kill for real. The process starts first, because the
# job records its pid and starttime at creation.
setsid sleep 300 &
worker_pid=$!
sleep 1
kill -0 "$worker_pid" 2>/dev/null || fail "the worker process never started"

out="$(K_PID="$worker_pid" j '
let jobs = require("core.jobs");
let proc = require("core.process");
let job = jobs.create("test", "killed", "worker");
let ident = proc.make_identity(getenv("K_PID"), "sleep");
// created -> queued -> preflight -> running; the phase machine refuses to skip.
jobs.queue(job);
jobs.preflight(job);
jobs.transition(job, jobs.PHASE_RUNNING, {
    pid: ident.pid,
    starttime: ident.starttime,
    boot_id: ident.boot_id
});
jobs.register_rollback(job, function(j2, reason) {
    let fs = require("fs");
    fs.writefile(j2.id + ".rolledback", reason);
});
printf("id=%s\n", job.id);
')"

ok

id="$(printf '%s\n' "$out" | sed -n 's/^id=//p')"
[ -n "$id" ] || fail "could not create the job: $out"

kill -9 "$worker_pid" 2>/dev/null || true
# Wait for the kernel to actually reap it, so the liveness probe is not racing.
i=0
while kill -0 "$worker_pid" 2>/dev/null && [ "$i" -lt 50 ]; do
  i=$((i + 1))
  sleep 0.1
done
kill -0 "$worker_pid" 2>/dev/null && fail "the worker survived SIGKILL"
ok

# --- before GC: the job still claims to be running -------------------------
# Not an assertion that this is desirable, just a record of the starting point,
# so a failure below is unambiguous.
phase="$(j "
let jobs = require(\"core.jobs\");
printf(\"phase=%s\\n\", jobs.query(\"$id\").phase);
")"
[ "$phase" = "phase=running" ] || fail "the job was not running to begin with: $phase"

# --- GC must reap it --------------------------------------------------------
out="$(j "
let jobs = require(\"core.jobs\");
jobs.gc();
let s = jobs.query(\"$id\");
printf(\"phase=%s\\n\", s.phase);
printf(\"error=%s\\n\", s.error || \"\");
printf(\"rolled_back=%s\\n\", s.rolled_back ? \"yes\" : \"no\");
")"

grep -q '^phase=failed$' <<< "$out" \
  || fail "a job whose worker was killed is still not terminal after GC - it shows as running forever: $out"
grep -qiE '^error=.*(disappeared|stale|reap)' <<< "$out" \
  || fail "the reaped job carries no reason the user could act on: $out"
ok

# --- the compensations must be accounted for, not assumed ------------------
# A compensation written as a shell command or a file operation lives in the
# state file, so it can still be executed after the worker is gone. That is the
# case worth proving.
: > "$TACHYON_RUNTIME_STATE_DIR/leftover"
setsid sleep 300 &
persist_pid=$!
sleep 1
kill -0 "$persist_pid" 2>/dev/null || fail "the persist worker never started"

out="$(K_PID="$persist_pid" \
       K_MARK="$TACHYON_RUNTIME_STATE_DIR/leftover" \
       K_RAN="$TACHYON_RUNTIME_STATE_DIR/compensation-ran" \
       j '
let jobs = require("core.jobs");
let proc = require("core.process");
let job = jobs.create("test", "persist", "worker");
let ident = proc.make_identity(getenv("K_PID"), "sleep");
jobs.queue(job);
jobs.preflight(job);
jobs.transition(job, jobs.PHASE_RUNNING, {
    pid: ident.pid,
    starttime: ident.starttime,
    boot_id: ident.boot_id
});
// register_rollback persists, which is the whole point: a compensation the
// state file does not know about cannot outlive the worker. Passed through the
// environment rather than ARGV, because core/jobs.uc only returns its exports
// when ARGV is empty - a real argument turns the require into a CLI run.
jobs.register_rollback(job, { type: "remove_file", path: getenv("K_MARK") });
jobs.register_rollback(job, { type: "command", cmd: "touch " + getenv("K_RAN") });
printf("id=%s\n", job.id);
')"

kill -9 "$persist_pid" 2>/dev/null || true
i=0
while kill -0 "$persist_pid" 2>/dev/null && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done

persist_id="$(printf '%s\n' "$out" | sed -n 's/^id=//p')"
[ -n "$persist_id" ] || fail "could not create the persisted-compensation job: $out"
j "
let jobs = require(\"core.jobs\");
jobs.gc();
" > /dev/null 2>&1 || fail "gc() failed on the persisted-compensation job"

[ -f "$TACHYON_RUNTIME_STATE_DIR/leftover" ] \
  && fail "a persisted remove_file compensation did not run after the worker died"
[ -f "$TACHYON_RUNTIME_STATE_DIR/compensation-ran" ] \
  || fail "a persisted command compensation did not run after the worker died"
ok

# --- a compensation that died with the worker must be said out loud ---------
# Registering a ucode callback keeps it in the worker's memory. It cannot be
# executed after the worker is killed, and the state file holds only a
# placeholder. Reporting the job as rolled back without mentioning that would
# leave an operator believing a half-applied system had been undone.
setsid sleep 300 &
lost_pid=$!
sleep 1
kill -0 "$lost_pid" 2>/dev/null || fail "the lost-compensation worker never started"

out="$(K_PID="$lost_pid" j '
let jobs = require("core.jobs");
let proc = require("core.process");
let job = jobs.create("test", "lost", "worker");
let ident = proc.make_identity(getenv("K_PID"), "sleep");
jobs.queue(job);
jobs.preflight(job);
jobs.transition(job, jobs.PHASE_RUNNING, {
    pid: ident.pid,
    starttime: ident.starttime,
    boot_id: ident.boot_id
});
jobs.register_rollback(job, function(j2, reason) {
    let fs = require("fs");
    fs.writefile(j2.id + ".ran", reason);
});
printf("id=%s\n", job.id);
')"

kill -9 "$lost_pid" 2>/dev/null || true
i=0
while kill -0 "$lost_pid" 2>/dev/null && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done

lost_id="$(printf '%s\n' "$out" | sed -n 's/^id=//p')"
out="$(j "
let jobs = require(\"core.jobs\");
jobs.gc();
printf(\"error=%s\\n\", jobs.query(\"$lost_id\").error || \"\");
")"

grep -qiE '^error=.*compensation' <<< "$out" \
  || fail "a job whose in-process compensation could not be run reports no such thing - the operator is left believing a half-applied system was undone: $out"
[ -f "$TACHYON_RUNTIME_STATE_DIR/$lost_id.ran" ] \
  && fail "an in-process compensation ran after its worker was killed, which should be impossible"
ok

# --- and it must not be reaped twice ---------------------------------------
# Second GC must leave the recorded reason alone rather than re-running the
# compensations over an already-rolled-back system.
out="$(j "
let jobs = require(\"core.jobs\");
jobs.gc();
printf(\"phase=%s\\n\", jobs.query(\"$id\").phase);
")"
grep -q '^phase=failed$' <<< "$out" || fail "a second GC disturbed an already-reaped job: $out"
ok

# --- a live worker is never reaped -----------------------------------------
# The mirror image, and the one that matters: a reaper that cannot tell a dead
# worker from a running one is worse than none, because it rolls back work that
# is still in progress.
setsid sleep 300 &
live_pid=$!
sleep 1
kill -0 "$live_pid" 2>/dev/null || fail "the live worker never started"

out="$(K_PID="$live_pid" K_RAN="$TACHYON_RUNTIME_STATE_DIR/live-rolledback" j '
let jobs = require("core.jobs");
let proc = require("core.process");
let job = jobs.create("test", "alive", "worker");
let ident = proc.make_identity(getenv("K_PID"), "sleep");
// created -> queued -> preflight -> running; the phase machine refuses to skip.
jobs.queue(job);
jobs.preflight(job);
jobs.transition(job, jobs.PHASE_RUNNING, {
    pid: ident.pid,
    starttime: ident.starttime,
    boot_id: ident.boot_id
});
jobs.register_rollback(job, { type: "command", cmd: "touch " + getenv("K_RAN") });
printf("id=%s\n", job.id);
')"

live_id="$(printf '%s\n' "$out" | sed -n 's/^id=//p')"

j "
let jobs = require(\"core.jobs\");
let s = jobs.query(\"$live_id\");
printf(\"phase=%s pid=%s starttime=%s stale=%s identity=%s\\n\", s.phase, s.pid, s.starttime, jobs.is_stale(s) ? \"yes\" : \"no\", \"?\");
" >&2 || true
out="$(j "
let jobs = require(\"core.jobs\");
jobs.gc();
printf(\"phase=%s\\n\", jobs.query(\"$live_id\").phase);
")"
grep -q '^phase=running$' <<< "$out" \
  || fail "GC reaped a job whose worker is still alive - it is rolling back work that is in progress: $out"
[ -f "$TACHYON_RUNTIME_STATE_DIR/live-rolledback" ] \
  && fail "GC rolled back a job whose worker is still running"
ok

kill -9 "$live_pid" 2>/dev/null || true

# --- a queued job is not stale ---------------------------------------------
# Not running and not preflight, so a job that has not started yet must be left
# alone. A reaper that swept these would cancel work before it began.
out="$(j '
let jobs = require("core.jobs");
let job = jobs.create("test", "queued", "worker");
jobs.queue(job);
printf("id=%s\n", job.id);
')"
queued_id="$(printf '%s\n' "$out" | sed -n 's/^id=//p')"
out="$(j "
let jobs = require(\"core.jobs\");
jobs.gc();
printf(\"phase=%s\\n\", jobs.query(\"$queued_id\").phase);
")"
grep -q '^phase=queued$' <<< "$out" \
  || fail "GC reaped a job that had not started: $out"
ok

printf 'fault: killed worker checks passed (%d assertions groups)\n' "$pass_count"
