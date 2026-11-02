#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
cat >"$WORK_DIR/probe.uc" <<'UC'
let fs = require("fs");
let common = require("core.common");
let engine = require("core.engine");
let files = {};
fs.stat = function(path) { return files[path] != null ? {} : null; };
fs.readfile = function(path) { return files[path]; };
fs.opendir = function(path) { return null; };
let output = "";
let status = 0;
let active = "tachyon-core";
engine.get_active = function() { return active; };
common.command_capture = function(cmd) { return { status: status, output: output }; };
common.command_success_from_args = function(args) { return true; };
// Controller-local shell captures are also observation boundaries.
fs.popen = function(cmd, mode) {
    return { read: function(mode) { return output; }, close: function() { return status; } };
};
let cfg = { proxy_mode: "tproxy" };
let health = require("service.firewall_health");
function check(ok, message) { if (!ok) die(message + "\n"); }
for (let path in ["/etc/tachyon/emergency_state.json", "/tmp/tachyon_emergency_state.json"]) {
    files[path] = "{}";
    check(health.interception_suppressed(cfg), "Emergency marker was ignored: " + path);
    delete files[path];
}
files["/var/run/tachyon/native_internet_restored"] = "1";
check(health.interception_suppressed(cfg), "Native Internet marker ignored");
files = { "/tmp/tachyon_paused_until": "" + (time() + 60) };
check(health.interception_suppressed(cfg), "Pause ignored");
files = {};
cfg.recovery_bypass = "1";
check(health.interception_suppressed(cfg), "Recovery bypass ignored");
cfg.recovery_bypass = "0";
check(!health.interception_suppressed(cfg), "Normal operation suppressed");
output = "table inet TachyonTable { chain priority_rules {} }";
check(!health.inspect(cfg).nft_ok, "Missing tproxy rule accepted");
for (let mode in ["tun", "socks"]) {
    cfg.proxy_mode = mode;
    check(health.inspect(cfg).nft_ok, mode + " incorrectly requires tproxy");
}
cfg.proxy_mode = "tproxy";
output = "table inet TachyonTable { chain priority_rules { tproxy to :1602; dscp set ef; dscp set af41; } }";
check(health.inspect(cfg).nft_ok && health.inspect(cfg).qos_ok, "Healthy rules rejected");
output = "table inet TachyonTable { chain priority_rules { tproxy to :1602; } }";
check(!health.inspect(cfg).qos_ok, "Missing QoS accepted");
cfg.qos_priority_engine = "0";
check(health.inspect(cfg).qos_ok, "Disabled QoS required");
status = 1;
check(!health.inspect(cfg).nft_ok, "Failed nft command accepted");
status = 0;
active = "steer";
output = "table inet steer { }";
check(health.inspect(cfg).nft_ok, "Steer incorrectly requires core chains");
active = "tachyon-core";
files["/proc/net/tcp6"] = " 0: 0000:0642 0000:0000 0A ";
check(health.tproxy_listening(1602), "IPv6 listening socket not detected");
check(!health.tproxy_listening(1603), "Different port accepted");

// Exercise the real event controller, including its ubus reload entry point.
let uci = require("core.uci");
uci.get_all = function(pkg, section) { return section ? cfg : {}; };
uci.get = function(pkg, section, key) { return cfg[key]; };
let bus = require("core.events").bus();
let seen = [];
for (let event in ["nft.missing", "qos.missing", "tproxy.down", "subnets.empty", "proxy.up"])
    bus.on(event, function(ev) { push(seen, ev.type); });
let controller = require("service.event_controller").controller(bus, {});
let ctx = { settings: cfg, now: time(), singbox_pid: "123", singbox_running: true,
    proxy_port: "4534", proxy_host: "127.0.0.1", reload_in_progress: false, list_update_running: false };
output = "";
files = {};
controller.probe_normal(ctx);
check(index(seen, "nft.missing") >= 0, "Normal missing firewall produced no event");
for (let path in ["/etc/tachyon/emergency_state.json", "/tmp/tachyon_emergency_state.json"]) {
    files = {}; files[path] = "{}"; seen = [];
    controller.probe_normal(ctx);
    controller.probe_slow(ctx);
    check(length(seen) == 0, "Intentional absence produced firewall events");
    controller.state.last_proxy_probe = 0;
    controller.probe_fast(ctx);
    check(index(seen, "proxy.up") >= 0, "Failsafe disabled proxy recovery observations");
}
print("firewall health tests passed\n");
UC
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/probe.uc"
