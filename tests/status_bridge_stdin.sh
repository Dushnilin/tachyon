#!/bin/sh
# status_bridge must deliver input on stdin AND hand the child's stdout back,
# running status.uc exactly once. Before the fix the input went through a
# write-only popen(): output came back empty and status_output() ran the
# command a second time with no stdin.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib=${TACHYON_LIB:-$root/tachyon/files/usr/lib}
export TACHYON_LIB="$lib"
work=$(mktemp -d /tmp/tachyon-status-bridge-test.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM

cat > "$work/test.uc" <<'UCODE'
let bridge = require("diagnostics.status_bridge");
let input = '{"a":1,"b":[2,3]}';
let out = bridge.status_output([ "stdin-json" ], input);
assert(out != null && length(trim(out)) > 0, "status_output returned no stdout for stdin input");
assert(index(out, "\"a\"") >= 0 || index(out, "a") >= 0, "stdin was not delivered: " + out);
let res = bridge.status_capture([ "stdin-json" ], input);
assert(res.status == 0, "status_capture exit " + res.status);
assert(length(trim(res.output)) > 0, "status_capture lost stdout");
assert(bridge.status_success([ "stdin-json" ], input) == true, "status_success");
assert(bridge.status_success([ "stdin-json" ], "") != null, "empty input must not crash");
print("PASS: status_bridge stdin round trip\n");
UCODE

ucode -L "$lib" "$work/test.uc"
leftover=$(ls /tmp/tachyon-status-in.* 2>/dev/null | wc -l)
test "$leftover" -eq 0 || { echo "FAIL: leaked stdin temp files"; exit 1; }
