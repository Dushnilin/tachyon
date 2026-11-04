#!/usr/bin/env ucode
//
// Routing-engine abstraction.
//
// Single source of truth for the active routing engine (`tachyon-core`),
// its binary/init/config paths, and its capability list.
//

let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let file_exists = common.file_exists;

const DEFAULT_ENGINE = "tachyon-core";

// Engine ids. These are stored in UCI (settings.engine) and must stay stable.
const ENGINE_TACHYON_CORE = "tachyon-core";
// A config written before the rename still says "sing-box"; it is normalized to
// the new id instead of falling back to the default.
const ENGINE_SING_BOX_LEGACY = "sing-box";

// UCI option names. Kept in one place so migrations and the frontend agree.
const OPT_ENGINE = "engine";
const OPT_ENGINE_PREVIOUS = "engine_previous";

const ENGINE_BINARIES = {
    "tachyon-core": "/usr/bin/tachyon-core",
};

const ENGINE_INIT = {
    "tachyon-core": "/etc/init.d/tachyon-core",
};

const ENGINE_PACKAGES = {
    "tachyon-core": "tachyon",
};

const ENGINE_CONFIG = {
    "tachyon-core": "/etc/tachyon-core/config.json",
};

// ============================================================================
// Capability matrix
// ============================================================================

const CAPABILITIES = {
    "tachyon-core": [
        "sections.outbound",
        "sections.subscription",
        "sections.provider",
        "sections.server",
        "sections.tailscale",
        "sections.group",
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
        "outbound.zapret",
        "outbound.zapret_lua",
        "obs.custom_service_script",
    ],
};

function known_engines() {
    return [ ENGINE_TACHYON_CORE ];
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
    if (bin != "" && file_exists(bin))
        return true;
    if (as_string(engine) == ENGINE_TACHYON_CORE && file_exists("/usr/bin/sing-box"))
        return true;
    return false;
}

function init_script_present(engine) {
    let init = engine_init_script(engine);
    return init != "" && file_exists(init);
}

function detect(engine) {
    engine = as_string(engine);
    if (!engine_is_known(engine))
        return { engine, known: false, installed: false, note: "unknown engine" };

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
    if (value == ENGINE_SING_BOX_LEGACY)
        return ENGINE_TACHYON_CORE;
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

function feature_payload(feature, features) {
    if (type(features) == "object")
        return features[feature] != null ? features[feature] : true;
    return true;
}

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
        ENGINE_TACHYON_CORE,
        ENGINE_SING_BOX_LEGACY,
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
        detect,
        detect_all,
        normalize_engine,
        get_active,
        get_previous,
        plan_switch
    };
}

return module_exports();
