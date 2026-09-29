#!/usr/bin/env bash
# FAULT: PID reuse. A live PID does not mean "our process is still running".
#
# Linux reuses process IDs. A watchdog that recorded only a PID concludes its
# dead worker is alive as soon as the number is handed to something else, and a
# job looks unfinished forever. core/process.uc exists to stop exactly that, by
# pairing the PID with the process starttime and the boot id.
#
# This drives the real core/process.uc rather than a mock, because the bug lives
# in reading /proc and in the comparison logic around it.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Run a snippet with core/process.uc loaded.
with_process() {
  ucode -L "$LIB_DIR" -e "
let proc = require(\"core.process\");
$1
" 2>&1
}

# A genuinely live PID, discovered from /proc rather than shelled out for.
# ucode's system() returns an exit code, not stdout, so `sleep & echo $!` is not
# an option here.
LIVE_PID="$(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | head -1)"
[ -n "$LIVE_PID" ] || fail "no live pid found under /proc"

# --- a real, live process must match its own identity -----------------------
out="$(with_process "
let pid = \"$LIVE_PID\";
let ident = proc.make_identity(pid, \"sh\");
print(\"pid=\" + ident.pid + \"\\n\");
print(\"has_start=\" + (ident.starttime != null ? \"yes\" : \"no\") + \"\\n\");
print(\"has_boot=\" + (ident.boot_id != null ? \"yes\" : \"no\") + \"\\n\");
print(\"matches=\" + (proc.identity_matches(ident, pid) ? \"yes\" : \"no\") + \"\\n\");
")"
echo "$out" | grep -q "^pid=[0-9]" || fail "make_identity returned no pid: $out"
echo "$out" | grep -q "^has_start=yes$" || fail "identity carries no starttime: $out"
echo "$out" | grep -q "^has_boot=yes$" || fail "identity carries no boot id: $out"
echo "$out" | grep -q "^matches=yes$" || fail "a live process does not match its own identity: $out"

# --- a dead process must not match ------------------------------------------
out="$(with_process '
let ident = proc.make_identity("999999", "ghost");
print("dead_matches=" + (proc.identity_matches(ident, "999999") ? "yes" : "no") + "\n");
print("dead_alive=" + (proc.pid_alive_raw("999999") ? "yes" : "no") + "\n");
')"
echo "$out" | grep -q "^dead_matches=no$" || fail "a dead pid matched a stale identity: $out"
echo "$out" | grep -q "^dead_alive=no$" || fail "pid_alive_raw() called a dead pid alive: $out"

# --- the actual fault: same PID, different process --------------------------
# This is the case a PID-only check gets wrong. We cannot make the kernel hand
# out a recycled PID on demand, so we forge the identity the way a stale state
# file would look once the number was recycled: right pid, but a starttime from
# a different incarnation.
out="$(with_process "
let pid = \"$LIVE_PID\";
let recycled = { pid: pid, starttime: \"1\", boot_id: proc.boot_id(), command: \"worker\", created_at: 1 };
print(\"recycled_matches=\" + (proc.identity_matches(recycled, pid) ? \"yes\" : \"no\") + \"\\n\");
")"
echo "$out" | grep -q "^recycled_matches=no$" \
  || fail "a recycled PID matched a stale identity - the guard is not working"

# A boot id from another boot is stale even when the PID is alive.
out="$(with_process "
let pid = \"$LIVE_PID\";
let other_boot = { pid: pid, starttime: proc.process_starttime(pid),
                   boot_id: \"00000000-0000-0000-0000-000000000000\", command: \"worker\", created_at: 1 };
print(\"other_boot_matches=\" + (proc.identity_matches(other_boot, pid) ? \"yes\" : \"no\") + \"\\n\");
")"
echo "$out" | grep -q "^other_boot_matches=no$" \
  || fail "an identity from another boot matched - boot id is not being compared"

# --- malformed input must be rejected, not crash ---------------------------
out="$(with_process '
print("null_ident=" + (proc.identity_matches(null, 1) ? "yes" : "no") + "\n");
print("empty=" + (proc.identity_matches({}, 1) ? "yes" : "no") + "\n");
print("nonpid=" + (proc.identity_matches({ pid: "abc" }, "abc") ? "yes" : "no") + "\n");
print("array=" + (proc.identity_matches([1,2,3], 1) ? "yes" : "no") + "\n");
')"
for key in null_ident empty nonpid array; do
  echo "$out" | grep -q "^$key=no$" || fail "malformed identity accepted ($key): $out"
done

printf 'fault: PID reuse checks passed\n'
