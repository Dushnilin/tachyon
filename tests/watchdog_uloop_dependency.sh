#!/usr/bin/env bash
# The watchdog runs an event loop from the ucode "uloop" module, but the package
# did not declare ucode-mod-uloop: on an image that ships ucode without that
# module, require("uloop") throws, every event-driven log channel silently
# degrades to nothing, and the watchdog keeps running as if healthy.
#
# Both sides of the invariant are checked: the code uses the module and the
# package declares it. Reverting either side fails the test.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

MAKEFILE="$ROOT_DIR/tachyon/Makefile"
WATCHDOG="$ROOT_DIR/tachyon/files/usr/lib/service/watchdog.uc"
[ -f "$MAKEFILE" ] || fail "missing $MAKEFILE"
[ -f "$WATCHDOG" ] || fail "missing $WATCHDOG"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

# The package must pull the module in.
grep -q '+ucode-mod-uloop' "$MAKEFILE" ||
  fail "tachyon/Makefile does not depend on ucode-mod-uloop"
ok

# And the dependency must be real: the watchdog must actually require it.
grep -q 'require("uloop")' "$WATCHDOG" ||
  fail "service/watchdog.uc no longer requires uloop - drop the dependency or restore the call"
ok

printf 'watchdog uloop dependency: %d checks passed\n' "$pass_count"
printf 'PASS: watchdog_uloop_dependency\n'
