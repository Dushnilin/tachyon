#!/usr/bin/env ucode
//
// Routing-engine abstraction.
//
// Tachyon can drive more than one routing engine. Today: sing-box (all its
// variants) and steer (github.com/xyzmean/steer). Each engine has its own
// runtime format and feature set, so switching engines must never silently
// drop configuration that the target engine cannot express.
//
// This module is the single source of truth for:
//   - which engines exist and how to detect them on the device
//   - what each engine can and cannot express (capability matrix)
//   - which configuration facts survive a switch to another engine and
//     which are parked as "unsupported by the active engine" so that the
//     switch back restores them
//
// It owns no process and no nftables: service/engine_runtime.uc starts and
// stops the selected engine, and the generators (singbox/generator.uc,
// steer/generator.uc) turn the internal state into each engine's format.
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let command_success_from_args = common.command_success_from_args;
let file_exists = common.file_exists;

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const DEFAULT_ENGINE = "sing-box";

// Engine ids. These are stored in UCI (settings.engine) and must stay stable.
const ENGINE_SING_BOX = "sing-box";
const ENGINE_STEER = "steer";
const ENGINE_STEER_EXTENDED = "steer-extended";

// UCI option names. Kept in one place so migrations and the frontend agree.
const OPT_ENGINE = "engine";
const OPT_ENGINE_PREVIOUS = "engine_previous";

// Engine executable / service locations.
const ENGINE_BINARIES = {
    "sing-box": "/usr/bin/sing-box",
    "steer": "/usr/sbin/steer",
    "steer-extended": "/usr/sbin/steer",
};

const ENGINE_INIT = {
    "sing-box": "/etc/init.d/sing-box",
    "steer": "/etc/init.d/steer",
    "steer-extended": "/etc/init.d/steer",
};

const ENGINE_PACKAGES = {
    "sing-box": "sing-box",
    "steer": "steer",
    "steer-extended": "steer-extended",
};

// Config paths. sing-box keeps its generated runtime under /etc/sing-box;
// steer keeps its spec and state under /etc/steer and /var/lib/steer.
const ENGINE_CONFIG = {
    "sing-box": "/etc/sing-box/config.json",
    "steer": "/etc/steer/spec.json",
    "steer-extended": "/etc/steer/spec.json",
};

// steer contract facts (docs/contract-v1.md of xyzmean/steer, as used by the
// splify2 control layer). Kept here so Tachyon writes exactly what the engine
// expects and does not invent a second data model.
const STEER_SPEC_FILE = "/etc/steer/spec.json";
const STEER_SUB_FILE = "/etc/steer/sub.txt";
// Per-section subscription files live here (one sub file per vless output so
// two subscription sections never overwrite each other's node lists). The
// package keep.d already covers subs/.
const STEER_SUBS_DIR = "/etc/steer/subs";
const STEER_LISTS_DIR = "/etc/steer/lists";
const STEER_CUSTOM_LISTS_DIR = "/etc/steer/lists/custom";
// Per-channel nfqws strategy files consumed by steer-nfqws via the opts_file
// field in spec.json. Overridable so the test suite can point it at a scratch
// directory instead of requiring root.
const STEER_ZAPRET_DIR = getenv("TACHYON_STEER_ZAPRET_DIR") || "/etc/steer/zapret";
const STEER_STATE_DIR = "/var/lib/steer";
const STEER_KEEP_D = "/lib/upgrade/keep.d/steer";
// The engine owns its own nftables table and marks, so it never collides with
// sing-box's inet fw4 rules and its marks/tables.
const STEER_NFT_TABLE = "inet steer";
const STEER_MARK_BASE = "0x100000";
const STEER_ROUTE_TABLE_BASE = "300";

// steer subcommands Tachyon relies on. Listed so a version check can warn when
// an installed engine is older than the contract we speak.
const STEER_REQUIRED_COMMANDS = [
    "apply", "status", "diag", "explain", "outputs", "needs-dnsd", "failover"
];

// keep.d paths that must survive a firmware upgrade. spec.json and sub.txt are
// not declared config files by the package itself, so Tachyon ships its own
// keep.d entry to avoid the "looks configured, no rules" failure mode.
const STEER_KEEP_PATHS = [
    STEER_SPEC_FILE,
    STEER_SUB_FILE,
    STEER_SUBS_DIR,
    STEER_CUSTOM_LISTS_DIR,
    STEER_STATE_DIR,
];

// ============================================================================
// Capability matrix
// ============================================================================
//
// Each capability is a fact about a piece of Tachyon configuration. The matrix
// answers "can this engine express it?" plus which engine it belongs to when
// the answer is no. Anything listed as unsupported by the active engine is
// preserved in UCI so a switch back restores it.
//
// Feature names are the vocabulary shared with the frontend warnings and the
// migration layer; keep them stable.

const CAPABILITIES = {
    "sing-box": [
        "sections.outbound",
        "sections.subscription",
        "sections.provider",
        "sections.server",
        "sections.tailscale",
        "dns.fakeip",
        "dns.realip",
        "dns.presets",
        "dns.failover",
        "routing.domain_lists",
        "routing.ip_lists",
        "routing.client_rules",
        "routing.rulesets_srs",
        "routing.urltest",
        "routing.priority",
        "routing.direct_bypass",
        "routing.torrserver_direct",
        "inbound.tproxy",
        "inbound.mixed",
        "outbound.extended_variants",
        "outbound.vless_reality",
        "obs.custom_service_script",
    ],
    "steer": [
        "routing.domain_lists",
        "routing.ip_lists",
        "routing.client_rules",
        "routing.failover",
        "routing.fakeip",
        "routing.realip",
        "routing.proto_ports",
        "routing.per_device_scope",
        "list_memory_fit",
        "outbound.interface",
        "outbound.direct",
        "obs.wireguard_over_tcp",
        "dns.upstream",
    ],
    "steer-extended": [
        "routing.domain_lists",
        "routing.ip_lists",
        "routing.client_rules",
        "routing.failover",
        "routing.fakeip",
        "routing.realip",
        "routing.proto_ports",
        "routing.per_device_scope",
        "list_memory_fit",
        "outbound.interface",
        "outbound.direct",
        "outbound.vless_reality",
        "obs.wireguard_over_tcp",
        "tunnel.tun",
        "dns.upstream",
    ],
};

function known_engines() {
    return [ ENGINE_SING_BOX, ENGINE_STEER, ENGINE_STEER_EXTENDED ];
}

function engine_is_known(engine) {
    return index(known_engines(), as_string(engine)) >= 0;
}

function capabilities(engine) {
    engine = as_string(engine);
    return CAPABILITIES[engine] != null ? CAPABILITIES[engine] : [];
}

function supports(engine, feature) {
    feature = as_string(feature);
    let caps = capabilities(engine);
    return index(caps, feature) >= 0;
}

// Given a list of configuration features in use, return the ones the target
// engine cannot express. These are what the switch must preserve for the way
// back rather than delete.
// `features` is either a list of feature names or a map { feature: payload }.
function feature_names(features) {
    if (type(features) == "array")
        return features;
    if (type(features) == "object")
        return keys(features);
    return [];
}

function unsupported_features(engine, features) {
    let out = [];
    for (let feature in feature_names(features)) {
        if (!supports(engine, feature))
            push(out, feature);
    }
    return out;
}

function unsupported_summary(from_engine, to_engine, features) {
    let unsupported = unsupported_features(to_engine, features);
    return {
        from_engine: as_string(from_engine),
        to_engine: as_string(to_engine),
        unsupported,
        loses_features: length(unsupported) > 0
    };
}

// ============================================================================
// Detection
// ============================================================================

function engine_binary(engine) {
    engine = as_string(engine);
    return ENGINE_BINARIES[engine] != null ? ENGINE_BINARIES[engine] : "";
}

function engine_init_script(engine) {
    engine = as_string(engine);
    return ENGINE_INIT[engine] != null ? ENGINE_INIT[engine] : "";
}

function engine_package(engine) {
    engine = as_string(engine);
    return ENGINE_PACKAGES[engine] != null ? ENGINE_PACKAGES[engine] : "";
}

function engine_config_path(engine) {
    engine = as_string(engine);
    return ENGINE_CONFIG[engine] != null ? ENGINE_CONFIG[engine] : "";
}

function binary_present(engine) {
    let bin = engine_binary(engine);
    return bin != "" && file_exists(bin);
}

function init_script_present(engine) {
    let init = engine_init_script(engine);
    return init != "" && file_exists(init);
}

// "steer" and "steer-extended" share /usr/sbin/steer; distinguish them by the
// vless subcommand, which only the extended build carries.
function steer_has_extended_build() {
    if (!binary_present(ENGINE_STEER))
        return false;
    return command_success_from_args([ ENGINE_BINARIES[ENGINE_STEER], "help", "vless" ]);
}

// Whether the installed steer understands every subcommand we drive it with.
// A missing command means the engine is older than our contract; callers can
// refuse to switch and tell the user to update instead of failing at apply.
function steer_contract_ready() {
    if (!binary_present(ENGINE_STEER))
        return false;
    for (let command in STEER_REQUIRED_COMMANDS) {
        if (!command_success_from_args([ ENGINE_BINARIES[ENGINE_STEER], "help", command ]))
            return false;
    }
    return true;
}

// What is actually installed on this device. Returns one entry per engine id
// with availability plus a note the UI can show.
function detect(engine) {
    engine = as_string(engine);
    if (!engine_is_known(engine))
        return { engine, known: false, installed: false, note: "unknown engine" };

    if (engine == ENGINE_STEER || engine == ENGINE_STEER_EXTENDED) {
        // "steer" and "steer-extended" name the same binary and the same init
        // script; the only thing that differs is the build. So installation is
        // one fact, not two, and the build is reported as its own field instead
        // of being folded into a note. Previously detect("steer") reported
        // installed on an extended build and the only hint was a note string.
        let present = binary_present(ENGINE_STEER);
        let build = !present ? "none" : (steer_has_extended_build() ? "extended" : "stock");
        return {
            engine,
            known: true,
            installed: present,
            build,
            matches_build: engine == ENGINE_STEER_EXTENDED ? build == "extended" : build != "none",
            binary: ENGINE_BINARIES[engine],
            init: ENGINE_INIT[engine],
            package: ENGINE_PACKAGES[engine],
            note: !present ? "" : (build == "extended" ? "extended build installed" : "stock build installed")
        };
    }

    return {
        engine,
        known: true,
        installed: binary_present(engine),
        binary: ENGINE_BINARIES[engine],
        init: ENGINE_INIT[engine],
        package: ENGINE_PACKAGES[engine],
        note: ""
    };
}

function detect_all() {
    let out = [];
    for (let engine in known_engines())
        push(out, detect(engine));
    return out;
}

// ============================================================================
// Active engine state (UCI)
// ============================================================================

function normalize_engine(value) {
    value = as_string(value);
    if (!engine_is_known(value))
        return DEFAULT_ENGINE;
    return value;
}

function get_active() {
    let settings = uci_core.get_all("tachyon", "settings") || {};
    return normalize_engine(settings[OPT_ENGINE] || DEFAULT_ENGINE);
}

function get_previous() {
    let settings = uci_core.get_all("tachyon", "settings") || {};
    let value = as_string(settings[OPT_ENGINE_PREVIOUS] || "");
    return engine_is_known(value) ? value : "";
}

// ============================================================================
// Feature plan: what survives a switch
//
// There is no parked snapshot any more. read_parked()/write_parked() persisted
// a JSON blob per target engine and returned it as `restored`, and nothing ever
// applied it - the restore they documented was never performed. Parking is a
// per-section decision the generator makes by skipping what the active engine
// cannot express, and the sections are never modified, so there is nothing to
// restore.
// ============================================================================

// Feature payloads are supplied by the caller as either a plain list of names
// or an object { feature: payload }. Plain names park a boolean marker so the
// switch back knows the feature was in use.
function feature_payload(feature, features) {
    if (type(features) == "object")
        return features[feature] != null ? features[feature] : true;
    return true;
}

// Build the plan for switching to `target`: which features cannot come along,
// and the parked payload captured for the way back. `features` is the list of
// configuration features currently in use (see components/engine_state.uc).
function plan_switch(target, features) {
    target = normalize_engine(target);
    let active = get_active();
    let summary = unsupported_summary(active, target, features);

    let parked = {};
    for (let feature in summary.unsupported) {
        let payload = feature_payload(feature, features);
        if (payload != null)
            parked[feature] = payload;
    }

    return {
        from_engine: active,
        to_engine: target,
        unsupported: summary.unsupported,
        loses_features: summary.loses_features,
        parked
    };
}

// ============================================================================
// Module exports
// ============================================================================

function module_exports() {
    return {
        ENGINE_SING_BOX,
        ENGINE_STEER,
        ENGINE_STEER_EXTENDED,
        DEFAULT_ENGINE,
        known_engines,
        engine_is_known,
        capabilities,
        supports,
        unsupported_features,
        unsupported_summary,
        engine_binary,
        engine_init_script,
        engine_package,
        engine_config_path,
        binary_present,
        init_script_present,
        steer_has_extended_build,
        steer_contract_ready,
        detect,
        detect_all,
        normalize_engine,
        get_active,
        get_previous,
        plan_switch,
        STEER_SPEC_FILE,
        STEER_SUB_FILE,
        STEER_LISTS_DIR,
        STEER_CUSTOM_LISTS_DIR,
        STEER_ZAPRET_DIR,
        STEER_STATE_DIR,
        STEER_KEEP_D,
        STEER_NFT_TABLE,
        STEER_MARK_BASE,
        STEER_ROUTE_TABLE_BASE,
        STEER_REQUIRED_COMMANDS,
        STEER_KEEP_PATHS
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: core/engine.uc (library module, no CLI)\n");
exit(1);
