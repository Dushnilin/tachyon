#!/usr/bin/env ucode

// Built-in Dual-WAN failover controller: probes reachability directly through
// the primary WAN L3 device (ping -I <dev>) so optical/modem upstream drops
// behind a local ONT or 4G router are detected even when the physical Ethernet
// link stays UP. On failure threshold it promotes the backup WAN default route
// metric in the main routing table, keeps the primary WAN default route at a
// high backup metric (so recovery probes bound to the primary device continue
// to work), signals tachyon-core / sing-box with SIGHUP to refresh its outbound
// interface cache without rebuilding nftables, and restores the original route
// metrics once the primary WAN recovers.
//
// NOTE: ucode does not hoist function declarations - keep callees above
// their first caller.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let option = common.option;
let list_option = common.list_option;
let int_option = common.int_option;
let bool_option = common.bool_option;
let contains = common.contains;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_output_from_args = common.command_output_from_args;
let write_file = common.write_file;
let write_json = common.write_json;
let write_json_file = common.write_json_file;
let read_json_file = common.read_json_file;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TACHYON_BIN = getenv("TACHYON_BIN") || "/usr/bin/tachyon";
const STATE_FILE = getenv("TACHYON_WAN_FAILOVER_STATE_FILE") || "/var/run/tachyon/wan_failover_state.json";
const WAN_EVENT_STAMP = getenv("TACHYON_WAN_EVENT_STAMP") || "/var/run/tachyon/wan-event.timestamp";
const BACKUP_ACTIVE_METRIC = 5;
const PRIMARY_DEMOTED_METRIC = 200;

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[wan-failover] [" + level + "] " + as_string(message) ]);
}

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function enabled(cfg) {
    cfg = cfg || settings();
    return bool_option(cfg, "wan_failover_enabled", false);
}

function primary_iface(cfg) {
    cfg = cfg || settings();
    let v = trim(option(cfg, "wan_failover_primary", "wan"));
    return v != "" ? v : "wan";
}

function configured_backup_iface(cfg) {
    cfg = cfg || settings();
    return trim(option(cfg, "wan_failover_backup", ""));
}

function probe_hosts(cfg) {
    cfg = cfg || settings();
    let hosts = [];
    for (let item in list_option(cfg, "wan_failover_probe_hosts")) {
        for (let token in split(as_string(item || ""), /[ \t\r\n,;]+/)) {
            let clean = trim(as_string(token || ""));
            if (clean != "" && !contains(hosts, clean))
                push(hosts, clean);
        }
    }
    if (length(hosts) == 0)
        hosts = [ "1.1.1.1", "8.8.8.8" ];
    return hosts;
}

function failure_threshold(cfg) {
    cfg = cfg || settings();
    let v = int_option(cfg, "wan_failover_failure_threshold", 3);
    if (v < 1)
        return 1;
    if (v > 20)
        return 20;
    return v;
}

function recovery_threshold(cfg) {
    cfg = cfg || settings();
    let v = int_option(cfg, "wan_failover_recovery_threshold", 3);
    if (v < 1)
        return 1;
    if (v > 20)
        return 20;
    return v;
}

function read_state() {
    let parsed = read_json_file(STATE_FILE);
    return type(parsed) == "object" ? parsed : {};
}

function write_state(state_obj) {
    let dir = replace(as_string(STATE_FILE), /\/[^\/]+$/, "");
    if (dir != "" && dir != STATE_FILE)
        command_success_from_args([ "mkdir", "-p", dir ]);
    write_json_file(STATE_FILE, object_or_empty(state_obj));
}

function parse_default_routes() {
    let out = as_string(command_output_from_args([ "ip", "-4", "route", "show", "default" ]) || "");
    let routes = [];
    for (let line in split(out, "\n")) {
        let trimmed = trim(as_string(line || ""));
        if (trimmed == "" || index(trimmed, "default") != 0)
            continue;
        let tokens = split(trimmed, /[ \t]+/);
        let dev = "";
        let gw = "";
        let metric = 0;
        for (let i = 0; i < length(tokens); i++) {
            let tok = as_string(tokens[i] || "");
            if (tok == "via" && i + 1 < length(tokens)) {
                gw = as_string(tokens[i + 1] || "");
                i++;
            } else if (tok == "dev" && i + 1 < length(tokens)) {
                dev = as_string(tokens[i + 1] || "");
                i++;
            } else if (tok == "metric" && i + 1 < length(tokens)) {
                metric = int(tokens[i + 1] || 0);
                i++;
            }
        }
        if (dev != "")
            push(routes, { dev: dev, gw: gw, metric: metric, raw: trimmed });
    }
    return routes;
}

function resolve_interface_info(iface, default_routes) {
    iface = trim(as_string(iface || ""));
    if (iface == "")
        return { iface: "", up: false, dev: "", gw: "", metric: 0 };

    let up = false;
    let dev = "";
    let gw = "";
    let metric = -1;

    let ubus_raw = trim(as_string(command_output_from_args([ "ubus", "-S", "call", "network.interface." + iface, "status" ]) || ""));
    if (ubus_raw != "") {
        let parsed = null;
        try {
            parsed = json(ubus_raw);
        } catch (e) {
            parsed = null;
        }
        if (type(parsed) == "object") {
            up = parsed.up == true;
            dev = trim(as_string(parsed.l3_device || parsed.device || ""));
            if (type(parsed.route) == "array") {
                for (let r in parsed.route) {
                    if (type(r) != "object")
                        continue;
                    if (as_string(r.target || "") == "0.0.0.0" && int(r.mask || 0) == 0) {
                        if (gw == "" && as_string(r.nexthop || "") != "" && as_string(r.nexthop || "") != "0.0.0.0")
                            gw = trim(as_string(r.nexthop));
                        if (metric < 0 && r.metric != null)
                            metric = int(r.metric);
                    }
                }
            }
        }
    }

    let net_sec = object_or_empty(uci_core.get_all("network", iface));
    if (dev == "")
        dev = trim(option(net_sec, "device", option(net_sec, "ifname", "")));
    if (gw == "")
        gw = trim(option(net_sec, "gateway", ""));
    if (metric < 0 && option(net_sec, "metric", "") != "")
        metric = int_option(net_sec, "metric", 0);

    let routes = type(default_routes) == "array" ? default_routes : parse_default_routes();
    for (let rt in routes) {
        if (dev != "" && rt.dev != dev)
            continue;
        if (dev == "" && iface != rt.dev)
            continue;
        if (dev == "")
            dev = rt.dev;
        if (gw == "" && rt.gw != "")
            gw = rt.gw;
        if (metric < 0 && rt.metric != BACKUP_ACTIVE_METRIC && rt.metric != PRIMARY_DEMOTED_METRIC)
            metric = rt.metric;
        up = true;
    }

    if (metric < 0)
        metric = 0;

    return {
        iface: iface,
        up: up,
        dev: dev,
        gw: gw,
        metric: metric
    };
}

function resolve_backup_interface(cfg, prim_info, default_routes) {
    let explicit = configured_backup_iface(cfg);
    if (explicit != "" && explicit != prim_info.iface)
        return resolve_interface_info(explicit, default_routes);

    let candidates = [ "wan2", "secondwan", "wwan", "tethering", "lte", "modem", "wanb" ];
    for (let cand in candidates) {
        if (cand == prim_info.iface)
            continue;
        let info = resolve_interface_info(cand, default_routes);
        if (info.dev != "" && info.dev != prim_info.dev)
            return info;
    }

    let routes = type(default_routes) == "array" ? default_routes : parse_default_routes();
    for (let rt in routes) {
        if (rt.dev != "" && rt.dev != prim_info.dev) {
            return {
                iface: rt.dev,
                up: true,
                dev: rt.dev,
                gw: rt.gw,
                metric: rt.metric
            };
        }
    }

    return { iface: explicit, up: false, dev: "", gw: "", metric: 20 };
}

function probe_device_hosts(dev, hosts) {
    dev = trim(as_string(dev || ""));
    if (dev == "")
        return { ok: false, host: "", reason: "missing_device" };
    for (let host in hosts) {
        let h = trim(as_string(host || ""));
        if (h == "")
            continue;
        if (command_success_from_args([ "ping", "-I", dev, "-c", "1", "-W", "2", h ]))
            return { ok: true, host: h, reason: "ok" };
    }
    return { ok: false, host: "", reason: "probe_timeout" };
}

function replace_default_route(dev, gw, metric) {
    dev = trim(as_string(dev || ""));
    gw = trim(as_string(gw || ""));
    if (dev == "")
        return false;
    let args = [ "ip", "-4", "route", "replace", "default" ];
    if (gw != "") {
        push(args, "via");
        push(args, gw);
    }
    push(args, "dev");
    push(args, dev);
    if (metric != null && int(metric) > 0) {
        push(args, "metric");
        push(args, as_string(int(metric)));
    }
    return command_success_from_args(args);
}

function delete_default_route_metric(dev, gw, metric) {
    dev = trim(as_string(dev || ""));
    gw = trim(as_string(gw || ""));
    if (dev == "")
        return false;
    let args = [ "ip", "-4", "route", "del", "default" ];
    if (gw != "") {
        push(args, "via");
        push(args, gw);
    }
    push(args, "dev");
    push(args, dev);
    if (metric != null && int(metric) >= 0) {
        if (int(metric) > 0) {
            push(args, "metric");
            push(args, as_string(int(metric)));
        }
    }
    return command_success_from_args(args);
}

function touch_wan_event_stamp(now) {
    let dir = replace(as_string(WAN_EVENT_STAMP), /\/[^\/]+$/, "");
    if (dir != "" && dir != WAN_EVENT_STAMP)
        command_success_from_args([ "mkdir", "-p", dir ]);
    write_file(WAN_EVENT_STAMP, as_string(now) + "\n");
}

function signal_core_hup() {
    for (let proc_name in [ "tachyon-core", "sing-box" ]) {
        let out = trim(as_string(command_output_from_args([ "pgrep", "-x", proc_name ]) || ""));
        if (out == "")
            continue;
        for (let pid in split(out, /[ \t\r\n]+/)) {
            let clean_pid = trim(as_string(pid || ""));
            if (clean_pid != "" && match(clean_pid, /^[0-9]+$/) != null)
                command_success_from_args([ "kill", "-HUP", clean_pid ]);
        }
    }
}

function send_notification(message) {
    let tcfg = object_or_empty(uci_core.get_all(CONFIG_NAME, "telegram"));
    if (as_string(tcfg.enabled || "0") != "1" || !tcfg.bot_token || !tcfg.admin_ids)
        return;
    if (TACHYON_BIN != "/usr/bin/tachyon" || getenv("TACHYON_WAN_FAILOVER_SYNC_NOTIFY") == "1") {
        command_success_from_args([ TACHYON_BIN, "telegram", "send", as_string(message) ]);
        return;
    }
    command_status(common.background_command(command_from_args([ TACHYON_BIN, "telegram", "send", as_string(message) ])));
}

function apply_backup_routes(prim_info, back_info, orig_prim_metric) {
    if (!replace_default_route(back_info.dev, back_info.gw, BACKUP_ACTIVE_METRIC))
        return false;
    if (prim_info.dev != "") {
        replace_default_route(prim_info.dev, prim_info.gw, PRIMARY_DEMOTED_METRIC);
        if (int(orig_prim_metric) < BACKUP_ACTIVE_METRIC)
            delete_default_route_metric(prim_info.dev, prim_info.gw, orig_prim_metric);
    }
    return true;
}

function restore_primary_routes(state_obj, prim_info, back_info) {
    let p_dev = trim(as_string(prim_info.dev || state_obj.primary_dev || ""));
    let p_gw = trim(as_string(prim_info.gw || state_obj.primary_gw || ""));
    let p_metric = state_obj.orig_primary_metric != null ? int(state_obj.orig_primary_metric) : int(prim_info.metric || 0);
    let b_dev = trim(as_string(back_info.dev || state_obj.backup_dev || ""));
    let b_gw = trim(as_string(back_info.gw || state_obj.backup_gw || ""));
    let b_metric = state_obj.orig_backup_metric != null ? int(state_obj.orig_backup_metric) : int(back_info.metric || 20);

    if (p_dev == "")
        return false;
    if (!replace_default_route(p_dev, p_gw, p_metric))
        return false;
    if (p_metric != PRIMARY_DEMOTED_METRIC)
        delete_default_route_metric(p_dev, p_gw, PRIMARY_DEMOTED_METRIC);
    if (b_dev != "") {
        if (b_metric != BACKUP_ACTIVE_METRIC && b_metric > p_metric)
            replace_default_route(b_dev, b_gw, b_metric);
        if (b_metric != BACKUP_ACTIVE_METRIC)
            delete_default_route_metric(b_dev, b_gw, BACKUP_ACTIVE_METRIC);
    }
    return true;
}

function check() {
    let cfg = settings();
    let prev = read_state();
    let now = time();

    if (!enabled(cfg)) {
        if (as_string(prev.active || "") == "backup") {
            let routes = parse_default_routes();
            let prim = resolve_interface_info(primary_iface(cfg), routes);
            let back = resolve_backup_interface(cfg, prim, routes);
            restore_primary_routes(prev, prim, back);
            touch_wan_event_stamp(now);
            signal_core_hup();
            write_state({ active: "primary", enabled: false, updated_at: now });
        }
        return 0;
    }

    let routes = parse_default_routes();
    let prim = resolve_interface_info(primary_iface(cfg), routes);
    let back = resolve_backup_interface(cfg, prim, routes);
    let hosts = probe_hosts(cfg);
    let fail_max = failure_threshold(cfg);
    let rec_max = recovery_threshold(cfg);

    let prev_active = as_string(prev.active || "primary");
    let prev_fail_streak = int(prev.fail_streak || 0);
    let prev_rec_streak = int(prev.recover_streak || 0);
    let orig_prim_metric = prev.orig_primary_metric != null ? int(prev.orig_primary_metric) : int(prim.metric || 0);
    let orig_back_metric = prev.orig_backup_metric != null ? int(prev.orig_backup_metric) : int(back.metric || 20);

    // Ensure primary dev has a fallback route while on backup so `ping -I <prim.dev>`
    // can reach the upstream gateway to detect recovery.
    if (prev_active == "backup" && prim.dev != "" && (prim.gw != "" || as_string(prev.primary_gw || "") != "")) {
        replace_default_route(prim.dev, prim.gw != "" ? prim.gw : as_string(prev.primary_gw || ""), PRIMARY_DEMOTED_METRIC);
    }

    let prim_probe = prim.dev != "" ? probe_device_hosts(prim.dev, hosts) : { ok: false, host: "", reason: "interface_down" };

    if (prim_probe.ok) {
        if (prev_active == "backup") {
            let rec_streak = prev_rec_streak + 1;
            if (rec_streak >= rec_max) {
                if (restore_primary_routes(prev, prim, back)) {
                    touch_wan_event_stamp(now);
                    signal_core_hup();
                    write_state({
                        enabled: true,
                        active: "primary",
                        primary_iface: prim.iface,
                        backup_iface: back.iface,
                        primary_dev: prim.dev,
                        backup_dev: back.dev,
                        primary_gw: prim.gw != "" ? prim.gw : as_string(prev.primary_gw || ""),
                        backup_gw: back.gw != "" ? back.gw : as_string(prev.backup_gw || ""),
                        orig_primary_metric: orig_prim_metric,
                        orig_backup_metric: orig_back_metric,
                        fail_streak: 0,
                        recover_streak: 0,
                        last_probe_host: prim_probe.host,
                        last_reason: "recovered",
                        last_transition_at: now,
                        updated_at: now
                    });
                    log_message("primary WAN " + prim.iface + " (" + prim.dev + ") recovered after " + as_string(rec_streak) + " probes; restored primary route", "info");
                    send_notification("🌐 *WAN Failover*: основной канал `" + prim.iface + "` (`" + prim.dev + "`) восстановился. Маршрутизация возвращена с резервного канала `" + (back.iface || back.dev) + "`.");
                    return 0;
                }
            }
            write_state({
                ...prev,
                enabled: true,
                active: "backup",
                fail_streak: 0,
                recover_streak: rec_streak,
                last_probe_host: prim_probe.host,
                last_reason: "recovering",
                updated_at: now
            });
            return 0;
        }

        write_state({
            enabled: true,
            active: "primary",
            primary_iface: prim.iface,
            backup_iface: back.iface,
            primary_dev: prim.dev,
            backup_dev: back.dev,
            primary_gw: prim.gw,
            backup_gw: back.gw,
            orig_primary_metric: prim.metric,
            orig_backup_metric: back.metric,
            fail_streak: 0,
            recover_streak: 0,
            last_probe_host: prim_probe.host,
            last_reason: "ok",
            last_transition_at: int(prev.last_transition_at || 0),
            updated_at: now
        });
        return 0;
    }

    // Primary WAN probe failed
    let fail_streak = prev_fail_streak + 1;
    if (prev_active != "backup" && fail_streak >= fail_max) {
        if (back.dev == "") {
            log_message("primary WAN " + prim.iface + " failed (" + prim_probe.reason + "), but no backup WAN device is available", "warn");
            write_state({
                ...prev,
                enabled: true,
                active: "primary",
                primary_iface: prim.iface,
                backup_iface: back.iface,
                primary_dev: prim.dev,
                backup_dev: "",
                fail_streak: fail_streak,
                recover_streak: 0,
                last_reason: "no_backup_device",
                updated_at: now
            });
            return 0;
        }

        let back_probe = probe_device_hosts(back.dev, hosts);
        if (!back_probe.ok) {
            log_message("primary WAN " + prim.iface + " failed, and backup WAN " + back.iface + " (" + back.dev + ") also failed probe", "warn");
            write_state({
                ...prev,
                enabled: true,
                active: "primary",
                primary_iface: prim.iface,
                backup_iface: back.iface,
                primary_dev: prim.dev,
                backup_dev: back.dev,
                fail_streak: fail_streak,
                recover_streak: 0,
                last_reason: "backup_unreachable",
                updated_at: now
            });
            return 0;
        }

        if (apply_backup_routes(prim, back, orig_prim_metric)) {
            touch_wan_event_stamp(now);
            signal_core_hup();
            write_state({
                enabled: true,
                active: "backup",
                primary_iface: prim.iface,
                backup_iface: back.iface,
                primary_dev: prim.dev,
                backup_dev: back.dev,
                primary_gw: prim.gw != "" ? prim.gw : as_string(prev.primary_gw || ""),
                backup_gw: back.gw,
                orig_primary_metric: orig_prim_metric,
                orig_backup_metric: orig_back_metric,
                fail_streak: fail_streak,
                recover_streak: 0,
                last_probe_host: back_probe.host,
                last_reason: "switched_to_backup",
                last_transition_at: now,
                updated_at: now
            });
            log_message("primary WAN " + prim.iface + " (" + prim.dev + ") unreachable after " + as_string(fail_streak) + " probes; switched default route to backup WAN " + back.iface + " (" + back.dev + ")", "warn");
            send_notification("⚠️ *WAN Failover*: основной канал `" + prim.iface + "` (`" + (prim.dev || "down") + "`) недоступен. Трафик переключён на резервный WAN `" + (back.iface || back.dev) + "` (`" + back.dev + "`).");
            return 0;
        }
    }

    write_state({
        ...prev,
        enabled: true,
        active: prev_active,
        primary_iface: prim.iface,
        backup_iface: back.iface,
        primary_dev: prim.dev != "" ? prim.dev : as_string(prev.primary_dev || ""),
        backup_dev: back.dev != "" ? back.dev : as_string(prev.backup_dev || ""),
        primary_gw: prim.gw != "" ? prim.gw : as_string(prev.primary_gw || ""),
        backup_gw: back.gw != "" ? back.gw : as_string(prev.backup_gw || ""),
        orig_primary_metric: orig_prim_metric,
        orig_backup_metric: orig_back_metric,
        fail_streak: fail_streak,
        recover_streak: 0,
        last_reason: prim_probe.reason,
        updated_at: now
    });
    return 0;
}

function status_object() {
    let cfg = settings();
    let state = read_state();
    return {
        enabled: enabled(cfg),
        primary_iface: primary_iface(cfg),
        backup_iface: configured_backup_iface(cfg),
        probe_hosts: probe_hosts(cfg),
        failure_threshold: failure_threshold(cfg),
        recovery_threshold: recovery_threshold(cfg),
        state: state
    };
}

function status_json() {
    write_json(status_object());
}

if (length(ARGV) == 0) {
    return {
        enabled,
        check,
        status_object,
        status_json
    };
}

let mode = ARGV[0] || "";
if (mode == "check")
    exit(check());
else if (mode == "status")
    status_json();
else {
    warn("Usage: service/wan_failover.uc <check|status>\n");
    exit(1);
}
