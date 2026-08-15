#!/usr/bin/env bash
set -eo pipefail

# A Tachyon self-update restarts the service mid-worker. If the worker dies
# before writing its result, the job state stays "running" with a dead pid.
# The stale detector used a bare `kill -0` liveness check: the recycled pid of
# the next process would keep the job running forever, and LuCI's progress
# modal hung for minutes over a finished install (issue #31). The pid must
# still belong to the component-action worker (checked via /proc cmdline).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TACHYON_LIB="$ROOT_DIR/tachyon/files/usr/lib"
UPDATES_UC="$TACHYON_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d /tmp/tachyon-stale-pid-test.XXXXXX)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  ls -la "$WORK_DIR" >&2 || true
  exit 1
}

assert_stale_uc_ready() {
  [ -f "$STALE_UC" ] || fail "stale.uc is missing right before ucode runs"
  [ -s "$STALE_UC" ] || fail "stale.uc is empty right before ucode runs"
}

# ── the identity check exists and is used ────────────────────────────────────
grep -q 'function pid_is_component_worker' "$UPDATES_UC" \
  || fail "pid_is_component_worker() is gone; a recycled pid can keep a dead job running forever"
grep -q 'pid_is_component_worker(pid)' "$UPDATES_UC" \
  || fail "refresh_component_running_job_state no longer verifies the worker identity"

# ── behavior: extract the stale-detection block verbatim and drive it ────────
STALE_UC="$WORK_DIR/stale.uc"

build_stale_uc() {
  cat > "$STALE_UC" <<'PRELUDE'
let fs = require("fs");
function now_seconds() { return int(time()); }
function as_string(v) { return v == null ? "" : "" + v; }
function arg_number(v) { return int(v); }
function arg_bool(v) { return v == true || v == "1" || v == 1; }
function command_success_from_args(args) {
    let parts = [];
    for (let a in args)
        push(parts, "'" + replace(as_string(a), /'/g, "'\\''") + "'");
    return system(join(" ", parts) + " >/dev/null 2>&1") == 0;
}
function read_json_file(path) {
    let raw = fs.readfile(path);
    if (raw == null) return null;
    let value = json(raw);
    return type(value) == "object" ? value : null;
}
let stale_calls = [];
function write_component_stale_job_state(path) { push(stale_calls, path); }
PRELUDE

sed -n '/^const COMPONENT_JOB_STALE_GRACE_SECONDS/,/^$/p' "$UPDATES_UC" >> "$STALE_UC"
sed -n '/^function job_started_at_within_grace/,/^}$/p' "$UPDATES_UC" >> "$STALE_UC"
sed -n '/^function job_pid_valid/,/^}$/p' "$UPDATES_UC" >> "$STALE_UC"
sed -n '/^function pid_running/,/^}$/p' "$UPDATES_UC" >> "$STALE_UC"
sed -n '/^function pid_is_component_worker/,/^}$/p' "$UPDATES_UC" >> "$STALE_UC"
sed -n '/^function refresh_component_running_job_state/,/^}$/p' "$UPDATES_UC" >> "$STALE_UC"

cat >> "$STALE_UC" <<'DRIVER'
function write_state(path, pid, started_at) {
    let tmp = path + ".tmp";
    let payload = sprintf('{ "running": true, "pid": "%s", "started_at": %d }', pid, started_at);
    if (!fs.writefile(tmp, payload))
        return false;
    return fs.rename(tmp, path);
}
let state_path = ARGV[0];
let pid = ARGV[1];
let started_at = int(ARGV[2] || (time() - 60));
write_state(state_path, pid, started_at);
refresh_component_running_job_state(state_path);
print((length(stale_calls) > 0 ? "stale" : "running") + "\n");
DRIVER
  assert_stale_uc_ready
}

run_stale_check() {
  mkdir -p "$WORK_DIR"
  if [ ! -f "$STALE_UC" ] || [ ! -s "$STALE_UC" ]; then
    printf 'WARN: stale.uc vanished (parallel /tmp race); rebuilding before ucode\n' >&2
    build_stale_uc
  fi
  local err="$WORK_DIR/ucode.err"
  local out
  if ! out="$(ucode -L "$TACHYON_LIB" "$STALE_UC" "$@" 2>"$err")"; then
    cat "$err" >&2 || true
    fail "ucode failed: ucode -L \"$TACHYON_LIB\" \"$STALE_UC\" $*"
  fi
  printf '%s' "$out"
}

build_stale_uc

# A live worker is not stale.
mkdir -p "$WORK_DIR"
bash -c 'while true; do sleep 1; done' component-action-worker &
worker_pid=$!
actual="$(run_stale_check "$WORK_DIR/job.json" "$worker_pid")"
[ "$actual" = "running" ] || fail "a live component-action worker was marked stale (pid $worker_pid): '$actual'"
kill "$worker_pid" 2>/dev/null || true

# The regression: a recycled pid — a live process that is NOT our worker —
# must be marked stale, not kept "running" forever.
sleep 30 &
alien_pid=$!
actual="$(run_stale_check "$WORK_DIR/job.json" "$alien_pid")"
[ "$actual" = "stale" ] || fail "a dead job whose pid was recycled is never marked stale (alien pid $alien_pid): '$actual'"
kill "$alien_pid" 2>/dev/null || true

# A dead pid is stale too.
sleep 30 &
dead_pid=$!
kill "$dead_pid" 2>/dev/null || true
wait "$dead_pid" 2>/dev/null || true
actual="$(run_stale_check "$WORK_DIR/job.json" "$dead_pid")"
[ "$actual" = "stale" ] || fail "a dead worker pid is not marked stale (pid $dead_pid): '$actual'"

# Grace still protects a fresh job: an alien pid inside the grace window is
# left alone, so a worker that just started is not raced by the detector.
sleep 30 &
fresh_pid=$!
fresh_start="$(($(date +%s) - 5))"
actual="$(run_stale_check "$WORK_DIR/job.json" "$fresh_pid" "$fresh_start")"
[ "$actual" = "running" ] || fail "a fresh job was marked stale inside the grace window (pid $fresh_pid): '$actual'"
kill "$fresh_pid" 2>/dev/null || true

# ── ui.uc's running-for must not report a recycled pid as a running action ──
UI_UC="$TACHYON_LIB/service/ui.uc"
grep -q 'component-action-worker' "$UI_UC" \
  || fail "ui.uc component_action_running_for no longer verifies the worker identity"

printf 'component job stale-pid checks passed\n'