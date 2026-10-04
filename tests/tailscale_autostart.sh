#!/usr/bin/env bash
# Native Tailscale must come up on boot, not only on the first reload (#110).
#
# After a reboot with the sing-box engine the daemon was gone:
# expected_process_count=1, running_process_count=0, and only a manual
# `tachyon tailscale_restart` brought it back. The reload path starts the
# runtime and so does the steer start branch, but start_main() - the sequence
# the boot actually runs for sing-box - never did, and a reload with an
# unchanged configuration is skipped, so nothing else started it either.
#
# The test reads the real function bodies: the wiring lives in lifecycle
# branches that cannot be executed without a router, and the ordering is part
# of the contract - the reload path documents that tailnet routes must exist
# before sing-box installs policy routing.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

LIFECYCLE_UC="$TACHYON_LIB/service/lifecycle.uc"
[ -f "$LIFECYCLE_UC" ] || fail "missing $LIFECYCLE_UC"

pass_count=0
ok() { pass_count=$((pass_count + 1)); }

start_main_body="$(sed -n '/^function start_main/,/^}/p' "$LIFECYCLE_UC")"
[ -n "$start_main_body" ] || fail "start_main not found in lifecycle.uc"

steer_body="$(sed -n '/^function start_steer_main/,/^}/p' "$LIFECYCLE_UC")"
[ -n "$steer_body" ] || fail "start_steer_main not found in lifecycle.uc"

reload_body="$(sed -n '/^function reload(/,/^}/p' "$LIFECYCLE_UC")"
[ -n "$reload_body" ] || fail "reload not found in lifecycle.uc"

# 1. The sing-box boot path must start the runtime itself.
grep -qF 'TAILSCALE_UC, [ "start-runtime" ]' <<<"$start_main_body" ||
  fail "start_main() never starts the native Tailscale runtime - after a reboot the daemon is only up if some reload happened to run"
ok

# 2. ...and before sing-box, the same order the reload path documents: tailnet
# routes must exist from the first packet, not after policy routing is live.
tailscale_line="$(grep -nF 'TAILSCALE_UC, [ "start-runtime" ]' <<<"$start_main_body" | head -1 | cut -d: -f1)"
singbox_line="$(grep -nF '/etc/init.d/sing-box", "start"' <<<"$start_main_body" | head -1 | cut -d: -f1)"
[ -n "$tailscale_line" ] && [ -n "$singbox_line" ] ||
  fail "could not locate the tailscale/sing-box start lines in start_main()"
if [ "$tailscale_line" -ge "$singbox_line" ]; then
  fail "start_main() starts Tailscale (line $tailscale_line) after sing-box (line $singbox_line); tailnet routes must win from the first packet"
fi
ok

# 3. The other two call sites are what kept this alive on some devices - both
# must keep starting the runtime so the regression cannot hide in either.
grep -qF 'TAILSCALE_UC, [ "start-runtime" ]' <<<"$steer_body" ||
  fail "the steer start branch no longer starts the native Tailscale runtime"
ok

grep -qF 'TAILSCALE_UC, [ "start-runtime" ]' <<<"$reload_body" ||
  fail "the reload path no longer starts the native Tailscale runtime"
ok

printf 'tailscale autostart: %d checks passed\n' "$pass_count"
printf 'PASS: tailscale_autostart\n'
