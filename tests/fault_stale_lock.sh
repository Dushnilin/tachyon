#!/usr/bin/env bash
# FAULT: stale package-manager lock.
#
# A lock that outlives its holder wedges every later package operation: the
# router can be neither updated nor repaired until the file is cleared by hand.
# The two outcomes matter and must be told apart - a lock held by a live
# process has to be respected, a lock left behind by a dead one has to be
# treated as stale, and a lock file that exists with nobody holding it is the
# common case after a crash or a power cut.
#
# Drives the real core/packages.uc, because the decision hinges on what it
# reads out of /proc.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

out="$(ucode -L "$LIB_DIR" -e '
let packages = require("core.packages");
let process_identity = require("core.process");

// No lock file at all: nothing to wait for.
print("no_holder_stale=" + (packages.is_stale_lock(null) ? "yes" : "no") + "\n");

// Lock file present, the holder is gone. This is the crash case: a real file
// with no process behind it, which must NOT be treated as a live lock.
print("dead_stale=" + (packages.is_stale_lock({ pid: "999999", alive: false }) ? "yes" : "no") + "\n");

// A live holder must be respected, otherwise two installers run at once.
print("live_stale=" + (packages.is_stale_lock({ pid: "1", alive: true }) ? "yes" : "no") + "\n");

// Garbage from a truncated or corrupted state file must not read as "held".
print("garbage_object_stale=" + (packages.is_stale_lock("not-an-object") ? "yes" : "no") + "\n");
print("empty_object_stale=" + (packages.is_stale_lock({}) ? "yes" : "no") + "\n");
' 2>&1)" || fail "packages.uc failed to load: $out"

for key in no_holder_stale dead_stale live_stale garbage_object_stale empty_object_stale; do
  value="$(printf '%s\n' "$out" | grep "^$key=" | cut -d= -f2)"
  case "$key" in
    live_stale) [ "$value" = "no" ] || fail "a live lock holder was treated as stale: $out" ;;
    *)         [ "$value" = "yes" ] || fail "$key should be treated as stale, got '$value': $out" ;;
  esac
done

# --- the probe reads a real /proc, so a real pid must be seen as alive -------
out="$(ucode -L "$LIB_DIR" -e '
let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;
let process_identity = require("core.process");

let live_pid = "";
for (let entry in fs.glob("/proc/*")) {
    let m = match(as_string(entry), /\/([0-9]+)$/);
    if (m == null) continue;
    if (process_identity.pid_alive_raw(m[1])) { live_pid = m[1]; break; }
}

print("found_live=" + (live_pid != "" ? "yes" : "no") + "\n");
print("live_alive=" + (live_pid != "" && process_identity.pid_alive_raw(live_pid) ? "yes" : "no") + "\n");
print("ghost_alive=" + (process_identity.pid_alive_raw("999999") ? "yes" : "no") + "\n");
' 2>&1)" || fail "process probe failed: $out"

printf '%s\n' "$out" | grep -q "^found_live=yes$" || fail "no live pid discoverable under /proc: $out"
printf '%s\n' "$out" | grep -q "^live_alive=yes$" || fail "a real live pid probed as dead: $out"
printf '%s\n' "$out" | grep -q "^ghost_alive=no$" || fail "a nonexistent pid probed as alive: $out"

printf 'fault: stale package lock checks passed\n'
