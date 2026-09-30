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

# Deliberately no `ucode()` wrapper here. A shell function named after a real
# binary makes `command -v ucode` answer "ucode" instead of a path, which
# silently breaks every test that copies or execs the real binary. The handful
# that want the -L wrapper define it locally.
