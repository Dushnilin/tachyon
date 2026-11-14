#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
# A section with fail_policy=block must never be leaked by watchdog's automatic
# direct-WAN / direct-DNS fallbacks. All IO is stubbed: no firewall, DNS, file
# or Telegram side effects on the host.
cat >"$WORK_DIR/probe.uc" <<'UC'
let shell_calls = [];
let system = function(cmd) { push(shell_calls, cmd); return 0; };
UC
awk '/^let mode = /{exit} NR > 1 {print}' \
  "$TACHYON_LIB/service/watchdog.uc" >>"$WORK_DIR/probe.uc"
cat >>"$WORK_DIR/probe.uc" <<'UC'
let files = {};
fs.stat = function(path) { return files[path] != null ? {} : null; };
fs.readfile = function(path) { return files[path]; };
fs.writefile = function(path, data) { files[path] = data; return length(data); };
fs.unlink = function(path) { delete files[path]; return true; };
common.write_json_file = function(path, data) { files[path] = data; return true; };
log_message = function(msg, level) {};
send_telegram_notification = function() { return true; };
heal_uncached_rulesets_detour = function() { return false; };
get_known_good = function() { return null; };
let cfg = { proxy_mode: "tproxy" };
settings = function() { return cfg; };
let sections = [];
uci_core.section_objects = function(pkg, type) { return sections; };
uci_core.get_all = function(pkg, section) { return {}; };
let commands = [];
command_status_from_args = function(args) { push(commands, join(" ", args)); return 0; };
let restarts = 0;
safe_proxy_restart = function(reason) { restarts++; return true; };
function check(ok, message) { if (!ok) die(message + "\n"); }
function reset(secs) {
    files = {}; shell_calls = []; commands = []; restarts = 0;
    emergency_failsafe_active = false; last_ai_incident = null;
    escalation_ladder = {}; escalation_level = {};
    sections = secs; cfg = { proxy_mode: "tproxy" };
}
let blocked = { ".name": "vpn", enabled: "1", action: "connection", fail_policy: "block" };

// L5 with a fail-closed section: no direct bypass, ladder stays on restarts.
reset([ blocked ]);
trigger_emergency_failsafe("proxy_down", "Max escalation level reached");
check(!is_emergency_failsafe_active() && length(shell_calls) == 0,
    "L5 leaked fail-closed traffic to direct WAN");
check(next_ladder_level("proxy_down") == LADDER_L4_RESTART,
    "Refused L5 left the reason stuck without further restarts");
check(last_ai_incident.outcome == "failed" && index(last_ai_incident.resolution, "vpn") >= 0,
    "Refused L5 was not reported");

// No fail-closed section (keep, direct, disabled block): L5 behaves as before.
for (let secs in [ [], [ { ".name": "a", fail_policy: "keep" }, { ".name": "b", fail_policy: "direct" } ],
                   [ { ".name": "c", enabled: "0", fail_policy: "block" } ] ]) {
    reset(secs);
    trigger_emergency_failsafe("proxy_down", "Max escalation level reached");
    check(is_emergency_failsafe_active() && index(join(" ", shell_calls), "nft delete table") >= 0,
        "L5 without a fail-closed section did not engage direct bypass");
}

// emergency_direct_bypass=0 is a router-wide kill-switch, sections or not.
reset([]); cfg.emergency_direct_bypass = "0";
trigger_emergency_failsafe("proxy_down", "Max escalation level reached");
check(!is_emergency_failsafe_active() && length(shell_calls) == 0,
    "emergency_direct_bypass=0 still engaged direct bypass");
check(index(last_ai_incident.resolution, "emergency_direct_bypass=0") >= 0,
    "Global veto was not named in the report");

// An explicit operator request is honoured even with a fail-closed section.
reset([ blocked ]);
trigger_emergency_failsafe("manual_operator_request", "Manually invoked via CLI", true);
check(is_emergency_failsafe_active(), "Operator emergency trigger was refused");

// DNS stall with a dead core listener: DNS stays on the proxy when fail-closed.
let stall = { payload: { streak: 3 } };
reset([ blocked ]); files["/proc/net/udp"] = "";
heal_dns_stall(stall);
check(index(join(" ", commands), "failsafe-restore") < 0, "DNS stall leaked DNS to direct WAN");
check(restarts == 1, "DNS stall stopped restarting the proxy");
reset([]); cfg.emergency_direct_bypass = "0"; files["/proc/net/udp"] = "";
heal_dns_stall(stall);
check(index(join(" ", commands), "failsafe-restore") < 0, "DNS stall ignored emergency_direct_bypass=0");
reset([]); files["/proc/net/udp"] = "";
heal_dns_stall(stall);
check(index(join(" ", commands), "failsafe-restore") >= 0, "DNS stall no longer restores failsafe DNS");
// A live core listener never triggers the DNS fallback at all.
reset([]); files["/proc/net/udp"] = "  0: 2A00007F:0035 00000000:0000 07";
heal_dns_stall(stall);
check(index(join(" ", commands), "failsafe-restore") < 0, "DNS fallback ran with the core still listening");
print("watchdog fail-closed tests passed\n");
UC
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/probe.uc"
