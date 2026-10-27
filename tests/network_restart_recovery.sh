#!/usr/bin/env bash
# Issue #240: Tachyon did not come back after a network restart.
#
# The service is enabled for boot start, so it has to be running when the
# network is back. The retry path used to answer "skip_no_retry" after a
# clean stop - and a clean stop is exactly what happens when the service
# died or was stopped before the network went down. The router was then left
# without a proxy and nothing brought the service back.
#
# The only case where staying down is right is a service the user disabled.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

INITD_UC="$TACHYON_LIB/service/initd.uc"
[ -f "$INITD_UC" ] || fail "service/initd.uc not found at $INITD_UC"

initd_ucode() {
  ucode -L "$TACHYON_LIB" "$INITD_UC" "$@"
}

# A running service must not be restarted - that would cut the live traffic.
[ "$(initd_ucode retry-start-on-wan-up-action 1 1 0 1)" = "skip_running" ] ||
  fail "a running service must not be restarted"

# A service the user disabled must stay down.
[ "$(initd_ucode retry-start-on-wan-up-action 0 0 0 1)" = "skip_disabled" ] ||
  fail "a disabled service must stay down"

# A stopped but enabled service must come back, after a clean stop and
# after an unclean one alike.
[ "$(initd_ucode retry-start-on-wan-up-action 0 1 0 1)" = "restart" ] ||
  fail "a stopped but enabled service must come back after a clean stop"
[ "$(initd_ucode retry-start-on-wan-up-action 0 1 0 0)" = "restart" ] ||
  fail "a stopped but enabled service must come back after an unclean stop"

# A recorded failed start is a restart too.
[ "$(initd_ucode retry-start-on-wan-up-action 0 1 1 1)" = "restart" ] ||
  fail "a recorded failed start must be retried"

printf 'Service comes back after a network restart passed\n'
