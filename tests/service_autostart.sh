#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -euo pipefail

LIFECYCLE_UC="${LIFECYCLE_UC:-$TACHYON_LIB/service/lifecycle.uc}"
FIXTURE="$WORK_DIR/autostart.uc"

cat >"$FIXTURE" <<'UC'
const SERVICE_INIT = "/etc/init.d/tachyon";
const CONFIG_NAME = "tachyon";
let calls = [];
let command_status = 0;
let running = false;
let uci_core = {
    set: function() { die("Autostart must not change runtime configuration\n"); },
    commit: function() { die("Autostart must not commit configuration\n"); }
};
function stop() { die("Autostart must not stop the live service\n"); }
function start() { die("Autostart must not start the live service\n"); }
function command_status_from_args(args) {
    push(calls, args);
    return command_status;
}
function assert(value, message) { if (!value) die(message + "\n"); }
UC

# Exercise the actual handlers in isolation, without changing system boot links
# or allowing a regression to stop a real service on the test machine.
sed -n '/^function enable_service()/,/^}/p' "$LIFECYCLE_UC" >>"$FIXTURE"
sed -n '/^function disable_service()/,/^}/p' "$LIFECYCLE_UC" >>"$FIXTURE"

cat >>"$FIXTURE" <<'UC'
for (let initial_running in [ false, true ]) {
    running = initial_running;
    for (let action in [ "disable", "enable" ]) {
        for (let status in [ 0, 1, 7 ]) {
            command_status = status;
            calls = [];
            let result = action == "enable" ? enable_service() : disable_service();
            assert(result == status, "Autostart must propagate init exit status");
            assert(length(calls) == 1, "Autostart must issue one init command");
            assert(calls[0][0] == SERVICE_INIT && calls[0][1] == action,
                "Autostart must use the matching init command");
            assert(running == initial_running, "Autostart must preserve runtime state");
        }
    }
}
print("PASS: service_autostart (12 cases)\n");
UC

ucode "$FIXTURE"
