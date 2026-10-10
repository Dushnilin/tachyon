#!/usr/bin/env bash
# Shared scaffolding for the standalone tests. Sourced, never run directly:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
#
# This is plain bash, not a test runner. Every test stays runnable on its own,
# with no framework and no registry - it just stops repeating the same four
# blocks. A test that needs a richer teardown or a louder failure message
# defines its own cleanup() or fail() after sourcing; the later definition
# wins, and the trap installed here already calls cleanup() by name.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TACHYON_LIB="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Serialise the two tests that care about processes named like the real daemon.
# One has to run a stand-in called "sing-box" (process_identity matches on the
# exe basename and on comm), another asserts that no such process exists. Under
# run_all's -P4 those two run at the same time and each one breaks the other.
# mkdir is atomic on POSIX, so it serves as the lock; no framework needed.
SING_BOX_PROC_LOCK="${TMPDIR:-/tmp}/tachyon-test-singbox-proc.lock"

acquire_sing_box_proc_lock() {
  local waited=0
  while ! mkdir "$SING_BOX_PROC_LOCK" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 120 ]; then
      printf 'FAIL: timed out waiting for %s (stale lock?)\n' "$SING_BOX_PROC_LOCK" >&2
      exit 1
    fi
  done
}

release_sing_box_proc_lock() {
  rmdir "$SING_BOX_PROC_LOCK" 2>/dev/null || true
}

# Deliberately no `ucode()` wrapper here. A shell function named after a real
# binary makes `command -v ucode` answer "ucode" instead of a path, which
# silently breaks every test that copies or execs the real binary. The handful
# that want the -L wrapper define it locally.
