#!/usr/bin/env bash
set -eo pipefail

# The UI shows a live log of a running component action. The worker's progress
# messages used to go to syslog only, so the modal had nothing real to display
# and faked its steps on a timer. The contract: the worker appends every
# progress line to <job>.log (UPDATES_JOB_LOG), the running state advertises the
# path, the log outlives the job (only the age-based sweep removes it), and the
# component-action-log CLI mode serves it from an arbitrary byte offset.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_UC="$ROOT_DIR/tachyon/files/usr/lib/components/updates.uc"
ACTION_UC="$ROOT_DIR/tachyon/files/usr/lib/components/action.uc"
TACHYON_BIN="$ROOT_DIR/tachyon/files/usr/bin/tachyon"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

code_only() {
  sed 's://.*::'
}

# The worker must hand the action module a dedicated log file path.
worker="$(sed -n '/^function component_action_worker/,/^}/p' "$UPDATES_UC" | code_only)"
[ -n "$worker" ] || fail "components/updates.uc must define component_action_worker"
grep -Fq 'UPDATES_JOB_LOG' <<<"$worker" ||
  fail "component_action_worker must set UPDATES_JOB_LOG for the action module"
grep -Eq 'UPDATES_JOB_LOG[^=]*=\s*.*\.log' <<<"$worker" ||
  fail "component_action_worker must point UPDATES_JOB_LOG at a .log file"

# The log path must be derived from the job id, the same way the .out file is.
grep -Fq 'function component_job_log_path' "$UPDATES_UC" ||
  fail "components/updates.uc must define component_job_log_path"
grep -Fq '.log' "$UPDATES_UC" ||
  fail "component_job_log_path must produce a .log path"

# The running state must carry the log path so the UI can find the file.
grep -Fq 'log_path' "$UPDATES_UC" ||
  fail "the component job state must expose log_path"

# finish_component_job removes the result channel and stderr, but the log is the
# UI's evidence of what happened: it must survive until the TTL sweep.
finish="$(sed -n '/^function finish_component_job/,/^}/p' "$UPDATES_UC" | code_only)"
[ -n "$finish" ] || fail "components/updates.uc must define finish_component_job"
grep -Fq 'remove_file(output_file + ".stderr")' <<<"$finish" ||
  fail "finish_component_job must still remove the .stderr file"
if grep -Fq '"log"' <<<"$finish"; then
  fail "finish_component_job must not remove the job .log file"
fi

# Only the age-based orphan sweep may drop .log files.
grep -Fq '"*.log"' "$UPDATES_UC" ||
  fail "the age-based orphan cleanup must cover *.log"

# The progress line must reach both syslog and the job log file.
updates_log="$(sed -n '/^function updates_log/,/^}/p' "$ACTION_UC" | code_only)"
[ -n "$updates_log" ] || fail "components/action.uc must define updates_log"
grep -Fq 'log_message(' <<<"$updates_log" ||
  fail "updates_log must keep writing to syslog"
grep -Fq 'job_log_append(' <<<"$updates_log" ||
  fail "updates_log must append to the job log file"
grep -Fq 'getenv("UPDATES_JOB_LOG")' "$ACTION_UC" ||
  fail "action.uc must read the UPDATES_JOB_LOG env var"

# The CLI must expose the log mode.
grep -Fq 'component_action_log' "$TACHYON_BIN" ||
  fail "/usr/bin/tachyon must declare component_action_log"

# --- behavioural: offset reads, clamping, missing file -----------------------

if command -v ucode >/dev/null 2>&1; then
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  mkdir -p "$WORK_DIR/jobs"
  printf 'line1\nline2\nline3\n' >"$WORK_DIR/jobs/abc-1_2.log"

  run_log() {
    UPDATES_JOB_DIR="$WORK_DIR/jobs" \
      ucode -L "$ROOT_DIR/tachyon/files/usr/lib" \
      "$UPDATES_UC" component-action-log "$@"
  }

  full="$(run_log abc-1_2 0)"
  grep -Fq '"success": true' <<<"$full" ||
    fail "component-action-log must report success for an existing log: $full"
  grep -Fq '"log": "line1\nline2\nline3\n"' <<<"$full" ||
    fail "component-action-log offset 0 must return the whole file: $full"
  grep -Fq '"offset": 18' <<<"$full" ||
    fail "component-action-log must report the total byte length: $full"

  tail="$(run_log abc-1_2 12)"
  grep -Fq '"log": "line3\n"' <<<"$tail" ||
    fail "component-action-log must read from the requested byte offset: $tail"
  grep -Fq '"offset": 18' <<<"$tail" ||
    fail "component-action-log must report the new offset after a partial read: $tail"

  clamped="$(run_log abc-1_2 999)"
  grep -Fq '"log": ""' <<<"$clamped" ||
    fail "component-action-log must clamp an offset past the end of the file: $clamped"
  grep -Fq '"offset": 18' <<<"$clamped" ||
    fail "component-action-log must clamp the reported offset to the file length: $clamped"

  set +e
  missing="$(run_log nope 0 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "component-action-log must exit non-zero for a missing log file"
  grep -Fq '"success": false' <<<"$missing" ||
    fail "component-action-log must report failure for a missing log file: $missing"
fi

printf 'component action log checks passed\n'
