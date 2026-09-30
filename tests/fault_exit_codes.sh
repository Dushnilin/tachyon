#!/usr/bin/env bash
# FAULT: reported exit codes were wrong for every non-zero result.
#
# normalize_stream_exit() assumed pipe.close() returns a shell wait status, where
# a signal death is encoded as 128+N. Measured on a real router, ucode returns
# the plain exit code instead, and a signal death as a negative number. So every
# code between 1 and 127 was read as "killed by that signal number" and reported
# as 128+N:
#
#   command            close()   reported
#   exit 1               1         129
#   exit 2               2         130
#   timeout 1 sleep 5  124         252
#   killed by SIGKILL   -9         247
#
# The 124 case is what made an update impossible to diagnose: coreutils-timeout
# returns 124 on expiry, the user was shown "failed with exit code 252", and
# nothing in the log said the command had run out of time. It also collides with
# this codebase's own "pipe could not be opened" sentinel of 255, which is what
# 127 (command not found) decodes to.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIB_DIR="${TACHYON_LIB:-$ROOT_DIR/tachyon/files/usr/lib}"

[ -f "$LIB_DIR/components/helpers.uc" ] || fail "components/helpers.uc not found"

out="$(ucode -L "$LIB_DIR" -e '
let helpers = require("components.helpers");
let n = helpers.normalize_stream_exit;
for (let c in [ 0, 1, 2, 42, 124, 125, 126, 127, 137, 252 ]) {
    printf("pos_%d=%d\n", c, n(c));
}
for (let c in [ -1, -9, -15 ]) {
    printf("neg_%d=%d\n", -c, n(c));
}
' 2>&1)" || fail "could not read normalize_stream_exit: $out"

got() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

# A plain exit code is already the answer. Anything else sends the user looking
# for a signal that never happened.
for c in 0 1 2 42 124 125 126 127 137 252; do
  [ "$(got "pos_$c")" = "$c" ] \
    || fail "exit code $c was reported as $(got "pos_$c") - users are told the wrong thing about why a command failed"
done

# A signal death is negative here, and only then is 128+N the right report.
[ "$(got neg_1)" = "129" ] || fail "death by SIGHUP should report 129, got $(got neg_1)"
[ "$(got neg_9)" = "137" ] || fail "death by SIGKILL should report 137, got $(got neg_9)"
[ "$(got neg_15)" = "143" ] || fail "death by SIGTERM should report 143, got $(got neg_15)"

printf 'fault: exit code reporting checks passed\n'
