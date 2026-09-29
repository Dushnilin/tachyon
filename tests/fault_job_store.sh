#!/usr/bin/env bash
# FAULT: the job store after a crash.
#
# A job's state file is written to a filesystem that can be full or lose power
# mid-write, so an unreadable state file is an ordinary outcome, not an exotic
# one. The store has to keep working around it: a corrupt entry must not break
# listing, and it must not sit there forever.
#
# The leak this pins: gc() skips a job whose state will not parse and moves on,
# so the file is never reclaimed. It stays invisible to list_all() but occupies
# a slot and is re-read on every pass, on a router where the state directory
# lives on overlay and therefore survives reboots.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

export TACHYON_RUNTIME_STATE_DIR="$WORK_DIR/state"
export TACHYON_JOB_GC_MAX_AGE=0
mkdir -p "$TACHYON_RUNTIME_STATE_DIR/jobs"

# A well-formed finished job, so gc has something legitimate to remove and the
# corrupt one is not the only thing present.
cat > "$TACHYON_RUNTIME_STATE_DIR/jobs/goodjob.json" <<'EOF'
{"id":"goodjob","kind":"apply","target":"proxy","action":"restart","phase":"success","created_at":1,"updated_at":1}
EOF

# The fault: a state file truncated by a full disk or a power cut.
printf '{"id":"torn","kind":"apply","phase":"run' > "$TACHYON_RUNTIME_STATE_DIR/jobs/torn.json"

out="$(ucode -L "$LIB_DIR" -e '
let jobs = require("core.jobs");
let all = jobs.list_all();
let visible = [];
for (let j in all) push(visible, j.id);
printf("visible=%s\n", join(",", visible));
printf("removed=%d\n", jobs.gc());
' 2>&1)" || fail "the job store did not survive a corrupt state file: $out"

grep -q '^visible=goodjob$' <<< "$out" \
  || fail "a corrupt state file broke listing: $out"

# The point of the scenario: the corrupt entry has to be reclaimed, not skipped
# forever. It is already invisible to listing, so nothing else will ever touch
# it.
[ -f "$TACHYON_RUNTIME_STATE_DIR/jobs/torn.json" ] \
  && fail "gc() left the unreadable state file in place forever - it skips it with continue and no later pass will ever reclaim it"

# And the legitimate entry is still collected, so the fix cannot be "collect
# everything".
[ -f "$TACHYON_RUNTIME_STATE_DIR/jobs/goodjob.json" ] \
  && fail "gc() no longer removes old terminal jobs"

# --- a second pass has to be a no-op, not an error -------------------------
out="$(ucode -L "$LIB_DIR" -e '
let jobs = require("core.jobs");
printf("removed=%d\n", jobs.gc());
' 2>&1)" || fail "a second gc() pass failed: $out"
grep -q '^removed=0$' <<< "$out" || fail "gc() kept removing things on a clean store: $out"

printf 'fault: job store corruption checks passed\n'
