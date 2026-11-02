#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
# Load the actual action functions, replacing only external effects. In
# particular, a successful update and rollback must reuse the captured intent.
printf '%s\n' 'let system = function(cmd) { return 0; };' >"$WORK_DIR/probe.uc"
awk '/^let mode = ARGV\[0\]/{exit} NR > 1 {print}' \
  "$TACHYON_LIB/components/action.uc" >>"$WORK_DIR/probe.uc"
cat >>"$WORK_DIR/probe.uc" <<'UC'
let healthy = false;
let cfg = { shutdown_correctly: "0" };
let core_enabled = "1";
let disabled = 0;
let starts = [];
file_exists = function(path) { return true; };
tachyon_status_running_with_timeout = function() { return healthy; };
engine.get_active = function() { return "tachyon-core"; };
uci_core.get_all = function(pkg, section) { return cfg; };
uci_core.get = function(pkg, section, key) { return core_enabled; };
require("service.firewall_health").manual_bypass_active = function(s) { return s.bypass == true; };
updates_log = function(msg, level) {};
prepare_sing_box_service_disabled = function() { disabled++; };
run_logged = function(label, cmd, timeout) { push(starts, cmd); return true; };
command_success_from_args = function(args) { push(starts, join(" ", args)); return true; };
function check(ok, message) { if (!ok) die(message + "\n"); }

capture_tachyon_running_state();
check(tachyon_was_running, "Missing nft during failsafe lost restart intent");
// The component update temporarily disables/stops the service after capture.
cfg.shutdown_correctly = "1";
core_enabled = "0";
tachyon_stopped_for_sing_box_change = true;
check(restart_tachyon_after_successful_change(), "Success path failed");
check(length(starts) == 1 && index(starts[0], "start") >= 0 && disabled == 0,
    "Success path did not preserve pre-update intent");
restart_tachyon_after_failed_sing_box_change();
check(length(starts) == 2, "Failed core update did not restore the prior running state");

starts = [];
core_enabled = "1"; // manual stop does not necessarily clear this flag
capture_tachyon_running_state();
check(!tachyon_was_running, "Manual stop was mistaken for failed runtime");
restart_tachyon_after_successful_change();
restart_tachyon_after_failed_sing_box_change();
check(length(starts) == 0 && disabled == 1, "Update restarted a manually stopped service");

cfg.shutdown_correctly = "0";
core_enabled = "0";
capture_tachyon_running_state();
check(!tachyon_was_running, "Disabled core gained restart intent");
core_enabled = "1";
cfg.bypass = true;
capture_tachyon_running_state();
check(!tachyon_was_running, "Explicit bypass gained restart intent");
cfg.bypass = false;
engine.get_active = function() { return "steer"; };
capture_tachyon_running_state();
check(!tachyon_was_running, "Inactive core configuration started steer");
healthy = true;
capture_tachyon_running_state();
check(tachyon_was_running, "Existing positive running evidence was lost");
file_exists = function(path) { return false; };
engine.get_active = function() { die("Absent Tachyon must not inspect runtime intent\n"); };
capture_tachyon_running_state();
check(!tachyon_was_running, "Absent Tachyon gained restart intent");
print("component restart intent tests passed\n");
UC
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/probe.uc"
