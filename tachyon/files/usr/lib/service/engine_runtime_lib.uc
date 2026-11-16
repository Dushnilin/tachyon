#!/usr/bin/env ucode
//
// Engine runtime: process-level operations for the routing engine (`tachyon-core`).
//

let common = require("core.common");
let uci_core = require("core.uci");
let engine = require("core.engine");
let engine_state = require("components.engine_state");

let as_string = common.as_string;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_status_from_args = common.command_status_from_args;
let file_exists = common.file_exists;
let option = common.option;
let runtime_constants = require("tachyon_core.constants");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

function init_script(engine_id) {
    return engine.engine_init_script(engine_id);
}

function init_script_present(engine_id) {
    let init = init_script(engine_id);
    return init != "" && file_exists(init);
}

function run_init(engine_id, action) {
    let init = init_script(engine_id);
    if (init == "" || !file_exists(init))
        return { ok: false, reason: "no_init_script", engine: engine_id, action };
    let status = command_status("(" + command_from_args([ init, action ]) + ") >/dev/null 2>&1");
    return { ok: status == 0, status, engine: engine_id, action };
}

function stop_other_engines(keep) {
    let stopped = [];
    for (let engine_id in engine.known_engines()) {
        if (engine_id == keep)
            continue;
        if (!init_script_present(engine_id))
            continue;
        run_init(engine_id, "stop");
        push(stopped, engine_id);
    }
    return stopped;
}

function start_active() {
    let active = engine.get_active();
    let info = engine.detect(active);
    if (!info.installed)
        return { ok: false, reason: "engine_not_installed", engine: active, installable: true };

    let stopped = stop_other_engines(active);
    let result = run_init(active, "start");
    return {
        ok: result.ok,
        reason: result.ok ? "" : "start_failed",
        engine: active,
        status: result.status,
        stopped_others: stopped
    };
}

function stop_active() {
    let active = engine.get_active();
    let result = run_init(active, "stop");
    return { ok: result.ok, engine: active, status: result.status };
}

function reload_active(reason) {
    let active = engine.get_active();
    let result = run_init(active, "reload");
    if (!result.ok) {
        result = run_init(active, "restart");
    }
    return { ok: result.ok, engine: active, status: result.status, reason: as_string(reason || "") };
}

function restart_tachyon_service() {
    let init = "/etc/init.d/" + CONFIG_NAME;
    if (!file_exists(init))
        return { ok: false, status: -1 };
    let status = command_status_from_args([ init, "restart" ]);
    return { ok: status == 0, status };
}

function sync_tun_firewall_zone(settings) {
    if (as_string(option(settings, "proxy_mode", "tproxy")) != "tun")
        return;

    let interface_name = trim(option(settings, "tun_interface", runtime_constants.TUN_INTERFACE));
    if (interface_name == "")
        interface_name = runtime_constants.TUN_INTERFACE;

    let zone = runtime_constants.TUN_FIREWALL_ZONE;
    let index = "";
    for (let name in uci_core.sections("firewall", "zone")) {
        if (as_string(uci_core.get("firewall", name, "name")) == zone) {
            index = name;
            break;
        }
    }

    if (index == "") {
        index = uci_core.add("firewall", "zone");
        if (as_string(index) == "")
            return;
        uci_core.set("firewall." + index + ".name", zone);
        uci_core.set("firewall." + index + ".input", "ACCEPT");
        uci_core.set("firewall." + index + ".output", "ACCEPT");
        uci_core.set("firewall." + index + ".forward", "ACCEPT");
        uci_core.set("firewall." + index + ".masq", "1");
        uci_core.set("firewall." + index + ".mtu_fix", "1");
        let forward = uci_core.add("firewall", "forwarding");
        uci_core.set("firewall." + forward + ".src", "lan");
        uci_core.set("firewall." + forward + ".dest", zone);
    }

    uci_core.set("firewall." + index + ".device", interface_name);

    if (!uci_core.commit("firewall"))
        return;
    command_status_from_args([ "/etc/init.d/firewall", "reload" ]);
}

function print_json(value) {
    print(sprintf("%J\n", value));
}

function main() {
    let mode = ARGV[0] || "";

    if (mode == "engine-info") {
        let active = engine.get_active();
        print_json({
            active,
            engines: engine.detect_all(),
            capabilities: engine.capabilities(active)
        });
        return 0;
    }

    if (mode == "engine-features") {
        print_json({
            active: engine.get_active(),
            features: engine_state.current_features()
        });
        return 0;
    }

    if (mode == "engine-start") {
        let result = start_active();
        print_json(result);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-stop") {
        let result = stop_active();
        print_json(result);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-reload") {
        let result = reload_active(ARGV[1] || "");
        print_json(result);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-status") {
        let active = engine.get_active();
        print_json({ engine: active, note: "tachyon-core status is exposed through get_tachyon_core_status" });
        return 0;
    }

    if (mode == "engine-apply") {
        print_json(reload_active("engine-apply"));
        return 0;
    }

    warn("Usage: service/engine_runtime.uc <engine-info|engine-features|engine-start|engine-stop|engine-reload|engine-status|engine-apply> ...\n");
    return 2;
}

function module_exports() {
    return {
        main,
        init_script,
        init_script_present,
        run_init,
        stop_other_engines,
        start_active,
        stop_active,
        reload_active,
        restart_tachyon_service,
        sync_tun_firewall_zone
    };
}

return module_exports();
