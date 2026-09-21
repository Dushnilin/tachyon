#!/usr/bin/env ucode
//
// Engine runtime: process-level operations for the selected routing engine.
//
// core/engine.uc decides *what* the device should run and preserves config
// across switches; this module is what actually starts, stops and inspects the
// engine process. Only one engine may own the routing dataplane at a time, so
// every entry point stops the previous engine before starting the new one.
//

let fs = require("fs");
let common = require("core.common");
let engine = require("core.engine");
let engine_state = require("components.engine_state");

let as_string = common.as_string;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_status_from_args = common.command_status_from_args;
let file_exists = common.file_exists;

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
    let status = command_status_from_args([ init, action ]);
    return { ok: status == 0, status, engine: engine_id, action };
}

// Stop every engine except `keep`. Used before starting the active one so the
// two never fight over nftables tables and policy routing rules.
function stop_other_engines(keep) {
    let stopped = [];
    for (let engine_id in engine.known_engines()) {
        if (engine_id == keep)
            continue;
        if (!init_script_present(engine_id))
            continue;
        // sing-box and steer-extended both own their init scripts; skip the
        // duplicate steer id when the extended build is the one running.
        if (engine_id == engine.ENGINE_STEER && keep == engine.ENGINE_STEER_EXTENDED)
            continue;
        if (engine_id == engine.ENGINE_STEER_EXTENDED && keep == engine.ENGINE_STEER)
            continue;
        run_init(engine_id, "stop");
        push(stopped, engine_id);
    }
    return stopped;
}

// Start the active engine, stopping the others first.
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
        // sing-box reload is reason-driven; fall back to restart on failure.
        result = run_init(active, "restart");
    }
    return { ok: result.ok, engine: active, status: result.status, reason: as_string(reason || "") };
}

// Full switch: apply the config switch, then stop the old engine and start the
// new one. Returns a JSON-serialisable result for the CLI/UI.
function switch_engine(target, opts) {
    opts = type(opts) == "object" ? opts : {};
    let before = engine.get_active();
    let plan = engine_state.apply_switch(target, {
        allow_install: opts.allow_install == "1" || opts.allow_install === true,
        dry_run: opts.dry_run == "1" || opts.dry_run === true
    });

    if (!plan.ok)
        return plan;

    if (opts.dry_run == "1" || opts.dry_run === true)
        return plan;

    let new_engine = engine.get_active();
    let stopped = stop_other_engines(new_engine);
    let started = run_init(new_engine, "start");
    if (!started.ok && init_script_present(new_engine)) {
        // Roll the configuration back so the device keeps running the engine
        // that still exists on disk.
        engine_state.apply_switch(before, {});
        run_init(before, "start");
        return {
            ok: false,
            reason: "start_failed_rolled_back",
            from_engine: before,
            to_engine: new_engine,
            stopped_others: stopped
        };
    }

    return {
        ok: true,
        from_engine: before,
        to_engine: new_engine,
        plan,
        stopped_others: stopped
    };
}

// ============================================================================
// steer contract pass-through
// ============================================================================
//
// The control layer must not keep a second data model of the engine's state.
// These helpers run steer and return its output verbatim, so the UI and the
// API always see exactly what the engine reports.

function steer_command_available(subcommand) {
    if (!engine.binary_present(engine.ENGINE_STEER))
        return false;
    return command_success_from_args([ engine.engine_binary(engine.ENGINE_STEER), "help", subcommand ]);
}

function steer_run(subcommand, args) {
    let bin = engine.engine_binary(engine.ENGINE_STEER);
    if (bin == "" || !file_exists(bin))
        return { ok: false, reason: "engine_not_installed", output: "" };
    if (!steer_command_available(subcommand))
        return { ok: false, reason: "unsupported_subcommand", subcommand, output: "" };

    let argv = [ bin, subcommand ];
    for (let arg in (type(args) == "array" ? args : []))
        push(argv, arg);
    let command = common.command_from_args(argv);
    let output = common.command_output(command + " 2>&1");
    let status = common.command_status(command + " 2>&1");
    return { ok: status == 0, status, subcommand, output };
}

function steer_apply(dry_run) {
    let args = dry_run ? [ "--dry-run" ] : [];
    return steer_run("apply", args);
}

function steer_status() {
    return steer_run("status", []);
}

function steer_diag() {
    return steer_run("diag", []);
}

function steer_explain(target) {
    if (as_string(target) == "")
        return { ok: false, reason: "missing_target", output: "" };
    return steer_run("explain", [ target ]);
}

// ============================================================================
// CLI
// ============================================================================

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

    if (mode == "engine-explain") {
        let result = steer_explain(ARGV[1] || "");
        print(result.output);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-diag") {
        let result = steer_diag();
        if (!result.ok && result.output == "")
            print_json(result);
        else
            print(result.output);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-status") {
        let active = engine.get_active();
        if (active == engine.ENGINE_SING_BOX) {
            print_json({ engine: active, note: "sing-box status is exposed through get_sing_box_status" });
            return 0;
        }
        let result = steer_status();
        if (!result.ok && result.output == "")
            print_json(result);
        else
            print(result.output);
        return result.ok ? 0 : 1;
    }

    if (mode == "engine-apply") {
        let active = engine.get_active();
        if (active == engine.ENGINE_SING_BOX) {
            // sing-box regeneration goes through the normal lifecycle reload.
            print_json(reload_active("engine-apply"));
            return 0;
        }
        let result = steer_apply(ARGV[1] == "--dry-run");
        print(result.output);
        return result.ok ? 0 : 1;
    }

    warn("Usage: service/engine_runtime.uc <engine-info|engine-features|engine-plan|engine-switch|engine-switch-back|engine-start|engine-stop|engine-reload|engine-status|engine-apply|engine-diag|engine-explain> ...\n");
    return 2;
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return {
        init_script,
        init_script_present,
        stop_other_engines,
        start_active,
        stop_active,
        reload_active,
        switch_engine,
        steer_run,
        steer_apply,
        steer_status,
        steer_diag,
        steer_explain
    };

exit(main());
