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

function switch_engine(target, opts) {
    opts = type(opts) == "object" ? opts : {};
    let before = engine.get_active();
    let normalized = engine.normalize_engine(target);

    if (normalized == before &&
        engine.engine_binary(normalized) == engine.engine_binary(before) &&
        engine.init_script_present(normalized) == engine.init_script_present(before) &&
        !(opts.replace_build === true || opts.replace_build === "1")) {
        let info = engine.detect(normalized);
        return {
            ok: true,
            no_op: true,
            reason: "already_active",
            from_engine: before,
            to_engine: normalized,
            build: info.build,
            message: "Already running on " + normalized + "; nothing to switch"
        };
    }

    let plan = engine_state.apply_switch(normalized, {
        allow_install: opts.allow_install == "1" || opts.allow_install === true,
        dry_run: opts.dry_run == "1" || opts.dry_run === true
    });

    if (!plan.ok)
        return plan;

    if (opts.dry_run == "1" || opts.dry_run === true)
        return plan;

    let new_engine = engine.get_active();
    let restarted = restart_tachyon_service();
    if (!restarted.ok) {
        engine_state.apply_switch(before, {});
        restart_tachyon_service();
        return {
            ok: false,
            reason: "start_failed_rolled_back",
            from_engine: before,
            to_engine: new_engine,
            service_status: restarted.status
        };
    }

    return {
        ok: true,
        from_engine: before,
        to_engine: new_engine,
        plan
    };
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
            previous: engine.get_previous(),
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

    if (mode == "engine-plan") {
        let target = ARGV[1] || engine.get_active();
        print_json(engine_state.apply_switch(target, { dry_run: true }));
        return 0;
    }

    if (mode == "engine-switch") {
        let target = ARGV[1] || "";
        if (target == "") {
            warn("Usage: service/engine_runtime.uc engine-switch <engine> [--allow-install] [--dry-run]\n");
            return 2;
        }
        let opts = {};
        for (let i = 2; i < length(ARGV); i++) {
            if (ARGV[i] == "--allow-install")
                opts.allow_install = true;
            else if (ARGV[i] == "--dry-run")
                opts.dry_run = true;
        }
        let result = switch_engine(target, opts);
        print_json(result);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-switch-back") {
        let previous = engine.get_previous();
        if (previous == "") {
            print_json({ ok: false, reason: "no_previous_engine" });
            return 1;
        }
        let result = switch_engine(previous, {});
        print_json(result);
        return result.ok ? 0 : 1;
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
        print_json({ engine: active, note: "tachyon-core status is exposed through get_sing_box_status" });
        return 0;
    }

    if (mode == "engine-apply") {
        print_json(reload_active("engine-apply"));
        return 0;
    }

    warn("Usage: service/engine_runtime.uc <engine-info|engine-features|engine-plan|engine-switch|engine-switch-back|engine-start|engine-stop|engine-reload|engine-status|engine-apply> ...\n");
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
        switch_engine,
        restart_tachyon_service,
        sync_tun_firewall_zone
    };
}

return module_exports();
