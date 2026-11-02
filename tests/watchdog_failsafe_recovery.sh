#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail
# Execute the production functions with simulated time and external IO. None
# of the tested transitions may touch the host firewall, DNS or init services.
cat >"$WORK_DIR/probe.uc" <<'UC'
let test_now = 1000;
let time = function() { return test_now; };
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
log_message = function(msg, level) {};
let cfg = { proxy_mode: "tproxy", ai_proxy_health_interval: "30" };
settings = function() { return cfg; };
uci_core.get_all = function(pkg, section) { return {}; };
let active = "tachyon-core";
active_engine_name = function() { return active; };
let nft_ok = false;
let qos_ok = false;
let port_ok = false;
firewall_health.inspect = function(s) { return { nft_ok: nft_ok, qos_ok: qos_ok }; };
firewall_health.tproxy_listening = function(port) { return port_ok; };
controller.create_tick_context = function() {
    return { settings: cfg, singbox_running: true, proxy_port: "4534", proxy_host: "127.0.0.1" };
};
controller.tproxy_port = function() { return 4530; };
controller.check_tachyon_cli_running = function() { return false; };
let rec_calls = 0;
let changed = false;
let repair_works = false;
let bypass_during_reconcile = false;
execute_reconciler_subsystem = function(subsystem, dry_run) {
    rec_calls++;
    if (repair_works) { nft_ok = true; qos_ok = true; port_ok = true; }
    if (bypass_during_reconcile) files[EMERGENCY_STATE_TMP] = "{}";
    return { ok: true, changed: changed };
};
let background = [];
bg_system = function(cmd) { push(background, cmd); };
let lifecycle_ok = true;
let routing_ok = true;
let dns_ok = true;
let proxy_ok = true;
let fail_during_rebuild = false;
let pause_during_rebuild = false;
let commands = [];
command_success_from_args = function(args) {
    push(commands, join(" ", args));
    if (index(args, "reload_firewall") >= 0) {
        test_now += 200; // stale pre-rebuild sample must not prove recovery
        if (fail_during_rebuild) proxy_ok = false;
        if (pause_during_rebuild) cfg.recovery_bypass = "1";
        return lifecycle_ok;
    }
    if (index(args, "tachyon-running") >= 0) return routing_ok;
    if (index(args, "recovery-ready") >= 0) return dns_ok;
    if (args[0] == "curl") return proxy_ok;
    return true;
};
function check(ok, message) { if (!ok) die(message + "\n"); }
function reset() {
    files = {}; cfg.recovery_bypass = "0"; cfg.proxy_mode = "tproxy";
    background = []; commands = []; shell_calls = [];
    firewall_recoveries = {}; last_reload_time = 0; last_ai_incident = null;
    nft_ok = false; qos_ok = false; port_ok = false;
    rec_calls = 0; changed = false; repair_works = false;
    bypass_during_reconcile = false;
    lifecycle_ok = true; routing_ok = true; dns_ok = true; proxy_ok = true;
    fail_during_rebuild = false; pause_during_rebuild = false;
    active = "tachyon-core"; emergency_failsafe_active = false;
    controller.state.healthy_streak = 3;
    controller.state.proxy_consecutive_fails = 0;
    controller.state.dns_consecutive_fails = 0;
    controller.state.proxy_latency_history = [{ ok: true, ts: test_now }];
}

for (let marker in [EMERGENCY_STATE_FILE, EMERGENCY_STATE_TMP]) {
    reset(); files[marker] = "{}";
    heal_nftables({}); heal_qos({}); heal_tproxy_port({ payload: { port: 4530 } });
    heal_community_subnet_sets({ payload: { sets: ["missing"] } });
    check(rec_calls == 0 && length(background) == 0 && last_ai_incident == null,
        "Queued event defeated emergency guard");
    for (let i = 0; i < 3; i++) { test_now += 120; ai_export_status(); }
    check(controller.healthy_streak() >= 3, "Intentional missing nft blocked the healthy streak");
}

for (let change in [false, true]) {
    reset(); changed = change;
    heal_nftables({});
    check(last_ai_incident.outcome == "pending" && length(background) == 1,
        "Reconciler ok/changed was mistaken for recovery");
    check(index(background[0], "firewall-repair-worker") >= 0, "Fallback lacks in-worker failsafe guard");
    nft_ok = true; settle_firewall_recoveries();
    check(last_ai_incident.outcome == "fixed", "Observed recovery did not settle pending repair");
}
reset(); files["/var/run/tachyon.reload.lock"] = "1";
heal_qos({});
check(last_ai_incident.outcome == "skipped" && length(background) == 0,
    "Locked reload reported a repair");
reset(); repair_works = true;
heal_qos({});
check(last_ai_incident.outcome == "fixed" && length(background) == 0,
    "Verified reconciler repair launched an unnecessary reload");
reset(); heal_tproxy_port({ payload: { port: 4530 } });
nft_ok = true; settle_firewall_recoveries();
check(last_ai_incident.outcome == "pending", "nft table was mistaken for a listening TPROXY port");
test_now += FIREWALL_RECOVERY_DEADLINE + 1;
settle_firewall_recoveries();
check(last_ai_incident.outcome == "failed", "Unrecovered port did not expire");
reset(); nft_ok = true; heal_nftables({});
check(rec_calls == 0 && length(background) == 0, "Stale event caused unnecessary repair");

// Late activation: a writer already queued before failsafe must undo its work.
for (let engine in ["tachyon-core", "steer"]) {
    reset(); active = engine; repair_works = true; bypass_during_reconcile = true;
    heal_nftables({});
    check(is_emergency_failsafe_active() && length(shell_calls) > 0 && last_ai_incident == null,
        "In-flight reconciler repair defeated emergency cleanup");
    if (engine == "steer")
        check(index(join(" ", commands), "nft delete table inet steer") >= 0, "Steer bypass did not remove interception");
}
reset(); pause_during_rebuild = true;
check(firewall_repair_worker() == 1 && length(shell_calls) > 0,
    "In-flight firewall reload defeated a newly activated bypass");
check(index(join(" ", commands), "/usr/bin/tachyon reload_firewall") >= 0,
    "Long rebuild is invisible to controller lifecycle guards");
reset(); files[EMERGENCY_STATE_TMP] = "{}";
check(firewall_repair_worker() == 1 && length(commands) == 0, "Queued worker ignored failsafe");

reset(); files[EMERGENCY_STATE_FILE] = "{}";
controller.state.proxy_latency_history = [];
check(!release_emergency_failsafe_if_recovered() && length(commands) == 0,
    "Initial zero counters were mistaken for proxy recovery");
controller.state.proxy_latency_history = [{ ok: true, ts: test_now - 90 }];
check(!release_emergency_failsafe_if_recovered(), "Stale success released failsafe");

for (let mode in ["tproxy", "tun", "socks"]) {
    reset(); cfg.proxy_mode = mode; files[EMERGENCY_STATE_TMP] = "{}";
    nft_ok = true; port_ok = mode == "tproxy";
    check(release_emergency_failsafe_if_recovered() && !is_emergency_failsafe_active(),
        "Verified " + mode + " recovery did not release failsafe");
    check(index(join(" ", commands), "curl") >= 0, "No fresh proxy check after slow rebuild");
}
for (let failure in ["nft", "routing", "listener", "dns", "proxy", "bypass"]) {
    reset(); files[EMERGENCY_STATE_FILE] = "{}"; nft_ok = true; port_ok = true;
    if (failure == "nft") nft_ok = false;
    if (failure == "routing") routing_ok = false;
    if (failure == "listener") port_ok = false;
    if (failure == "dns") dns_ok = false;
    if (failure == "proxy") fail_during_rebuild = true;
    if (failure == "bypass") pause_during_rebuild = true;
    check(!release_emergency_failsafe_if_recovered() && is_emergency_failsafe_active() && length(shell_calls) > 0,
        "Failed release did not preserve direct runtime: " + failure);
}
reset(); files[EMERGENCY_STATE_TMP] = "{}"; files["/var/run/tachyon/starting"] = "1";
check(!release_emergency_failsafe_if_recovered() && length(commands) == 0,
    "Failsafe release raced a lifecycle operation");
reset(); active = "steer"; files[EMERGENCY_STATE_FILE] = "{}";
check(!release_emergency_failsafe_if_recovered() && length(commands) == 0,
    "Steer used tachyon-core-specific release");
print("watchdog failsafe recovery tests passed\n");
UC
ucode -S -L "$TACHYON_LIB" "$WORK_DIR/probe.uc"
