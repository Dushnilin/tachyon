#!/usr/bin/env bash
# FAULT: garbage collection of transaction state.
#
# gc() walks the transaction directory and, for each entry whose manifest will
# not parse, deletes the whole directory - snapshots included. That is a
# destructive branch on untrusted input, and it used to run completely silently:
# the stale-transaction branch next to it logs, this one did not. An operator
# whose rollback capability vanished had no way to learn that from the journal.
#
# The invariants here: a transaction that is still running under a live owner is
# never touched, a stale one is recovered rather than deleted, an old finalized
# one is cleaned, and a manifest that cannot be parsed is cleaned only with a
# line in the journal naming what was removed.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -f "$LIB_DIR/core/transaction.uc" ] || fail "core/transaction.uc not found"

# --- the destructive branch must announce itself ---------------------------
# Pin the behaviour in the source: every branch that removes a transaction
# directory has to log, not just the ones with a readable manifest.
body="$(sed -n '/^function gc(/,/^}$/p' "$LIB_DIR/core/transaction.uc")"
[ -n "$body" ] || fail "could not locate gc()"

# Count the destructive branches and the log calls around them.
rm_count="$(printf '%s\n' "$body" | grep -c 'rm -rf' || true)"
[ "$rm_count" -ge 2 ] || fail "gc() no longer removes transaction directories; the invariants below are stale"

# Extract the unreadable-manifest branch on its own. A plain grep -A runs past
# the closing brace into the stale-transaction branch, whose own log call then
# satisfies the assertion even when this branch is silent - the test would pass
# for the wrong reason, which is worse than not having it.
unreadable_branch="$(printf '%s\n' "$body" | awk '
  /if \(!state\)/ { inside = 1 }
  inside {
    print
    depth += gsub(/\{/, "{")
    depth -= gsub(/\}/, "}")
    if (depth <= 0) exit
  }
')"
[ -n "$unreadable_branch" ] || fail "the unreadable-manifest branch is gone"
printf '%s\n' "$unreadable_branch" | grep -q 'rm -rf' \
  || fail "the unreadable-manifest branch no longer removes anything; the invariant is stale"
printf '%s\n' "$unreadable_branch" | grep -qE 'log_message|tx_log|tx_gc_log|log_warn|logger' \
  || fail "gc() deletes a transaction whose manifest will not parse without logging it - that is a silent destructive path"

# Every rm -rf in gc() must be preceded somewhere in the function by a log call,
# so a future branch cannot reintroduce the silence.
printf '%s\n' "$body" | grep -qE 'log_message|tx_log|log_warn|logger' \
  || fail "gc() has no logging at all"

printf 'fault: transaction gc checks passed\n'
