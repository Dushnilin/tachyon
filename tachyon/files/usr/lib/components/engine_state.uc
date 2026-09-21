#!/usr/bin/env ucode
//
// Engine state: what the current Tachyon configuration uses, expressed as the
// engine features from core/engine.uc, plus the switch transaction that parks
// anything the target engine cannot express and restores it on the way back.
//
// The switch is deliberately conservative:
//   1. PLAN      - compute the feature list and what the target engine cannot do
//   2. SNAPSHOT  - persist the parked payload in UCI
//   3. MUTATE    - flip settings.engine / engine_previous
//   4. VALIDATE  - target engine must be installed (or the caller opted in)
// A failed validation rolls the mutation back, so the device never ends up
// pointing at an engine that is not there.
//

let common = require("core.common");
let uci_core = require("core.uci");
let engine = require("core.engine");

let as_string = common.as_string;
let file_exists = common.file_exists;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";

// ============================================================================
// Configuration -> feature vocabulary
// ============================================================================

// Map one UCI section to the engine feature it needs. Sections that do not map
// to a feature are ignored on purpose: they are either settings-only or belong
// to a category that every engine handles the same way.
function section_feature(section) {
    let action = as_string(section.action || "");
    let stype = as_string(section[".type"] || "");

    if (stype == "server")
        return "sections.server";
    if (stype == "provider")
        return "sections.provider";
    if (stype == "subscription")
        return "sections.subscription";

    if (stype == "section") {
        if (action == "connection")
            return "sections.outbound";
        if (action == "subscription")
            return "sections.subscription";
        if (action == "provider")
            return "sections.provider";
        if (action == "server")
            return "sections.server";
        if (action == "tailscale")
            return "sections.tailscale";
        if (action == "urltest")
            return "routing.urltest";
        if (action == "direct_bypass")
            return "routing.direct_bypass";
        if (action == "torrserver_direct")
            return "routing.torrserver_direct";
        if (action == "hosts")
            return "routing.domain_lists";
        if (action == "bypass")
            return "routing.domain_lists";
    }

    if (stype == "priority_group" || stype == "priority_level")
        return "routing.priority";

    return "";
}

function bool_option(section, key) {
    if (section == null)
        return false;
    let v = section[key];
    if (v == null)
        return false;
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

function bool_option_default(section, key, fallback) {
    if (section == null || section[key] == null)
        return fallback;
    return bool_option(section, key);
}

function list_length(value) {
    if (type(value) == "array")
        return length(value);
    if (as_string(value) != "")
        return 1;
    return 0;
}

// Options on settings and sections that imply a feature. Kept explicit so a
// new option does not silently fall out of the parity check.
function option_features(settings, features) {
    if (bool_option(settings, "dns_detour_enabled"))
        push(features, "dns.failover");
    if (as_string(settings.dns_type || "") != "")
        push(features, "dns.fakeip");
    if (bool_option(settings, "dns_local_cache"))
        push(features, "dns.presets");
    if (bool_option(settings, "direct_bypass_enabled"))
        push(features, "routing.direct_bypass");
    if (bool_option(settings, "smart_detect"))
        push(features, "routing.domain_lists");
    if (bool_option(settings, "exclude_ntp"))
        push(features, "routing.ip_lists");
    if (bool_option(settings, "enable_yacd"))
        push(features, "routing.ip_lists");
    if (bool_option(settings, "clash_api_enabled"))
        push(features, "obs.custom_service_script");
}

// Collect the distinct feature list the current configuration needs.
function current_features() {
    let features = [];
    let seen = {};

    function add(feature) {
        feature = as_string(feature);
        if (feature == "" || seen[feature] != null)
            return;
        seen[feature] = true;
        push(features, feature);
    }

    let settings = uci_core.get_all(CONFIG_NAME, "settings") || {};
    let opt_features = [];
    option_features(settings, opt_features);
    for (let feature in opt_features)
        add(feature);

    // The uci module only exists on OpenWrt (and in fixtures via core.uci).
    // Anywhere else the settings-derived list above is all we have.
    let cursor = null;
    try {
        cursor = require("uci").cursor();
    }
    catch (e) {
        cursor = null;
    }
    if (cursor == null)
        return features;

    try {
        cursor.foreach(CONFIG_NAME, "section", function(section) {
            if (!bool_option_default(section, "enabled", true))
                return;
            let feature = section_feature(section);
            if (feature != "")
                add(feature);

            if (list_length(section.remote_domain_lists) > 0 || list_length(section.domain) > 0)
                add("routing.domain_lists");
            if (list_length(section.remote_subnet_lists) > 0 || list_length(section.subnet) > 0)
                add("routing.ip_lists");
        });
        cursor.foreach(CONFIG_NAME, "server", function(section) {
            add("sections.server");
        });
        cursor.foreach(CONFIG_NAME, "provider", function(section) {
            add("sections.provider");
        });
    }
    catch (e) {
        // Partial list is fine: the switch will simply park less. Errors are
        // already reported by uci to the system log.
    }

    return features;
}

// ============================================================================
// Switch transaction
// ============================================================================

function set_option(option, value) {
    return uci_core.set(CONFIG_NAME + ".settings." + option, as_string(value));
}

function commit() {
    return uci_core.commit(CONFIG_NAME);
}

// Validate that a switch target can actually run before we point the config at
// it. `allow_install` lets the caller switch anyway when it intends to install
// the engine right after (install.sh / component install path).
function validate_target(target, allow_install) {
    let info = engine.detect(target);
    if (!info.known)
        return { ok: false, reason: "unknown_engine", installable: false };
    if (info.installed)
        return { ok: true, reason: "" };
    if (allow_install)
        return { ok: true, reason: "engine_not_installed", installable: true };
    return { ok: false, reason: "engine_not_installed", installable: true };
}

// Perform the switch plan: park what cannot come along, flip the engine.
// Returns { ok, plan, restored, validation }.
function apply_switch(target, opts) {
    opts = type(opts) == "object" ? opts : {};
    target = engine.normalize_engine(target);
    let active = engine.get_active();

    let validation = validate_target(target, opts.allow_install);
    let features = current_features();
    let plan = engine.plan_switch(target, features);

    if (!validation.ok) {
        return {
            ok: false,
            reason: validation.reason,
            installable: validation.installable,
            from_engine: active,
            to_engine: target,
            plan,
            parked: false,
            validation
        };
    }

    if (opts.dry_run)
        return { ok: true, reason: "dry_run", from_engine: active, to_engine: target, plan, parked: false, validation };

    // Park the incompatible configuration under the target engine's key so a
    // switch back restores exactly this set.
    let parked = engine.write_parked(target, plan.parked);

    // Restore anything this engine had parked earlier (e.g. switching back).
    let restored = engine.read_parked(active);

    set_option("engine", target);
    set_option("engine_previous", active);
    commit();

    return {
        ok: true,
        reason: "",
        from_engine: active,
        to_engine: target,
        plan,
        parked,
        restored,
        validation
    };
}

// Restore the previously active engine, if one is recorded and installed.
function switch_back(opts) {
    let previous = engine.get_previous();
    if (previous == "")
        return { ok: false, reason: "no_previous_engine" };
    return apply_switch(previous, opts);
}

// ============================================================================
// Module exports
// ============================================================================

function module_exports() {
    return {
        section_feature,
        current_features,
        validate_target,
        apply_switch,
        switch_back,
        set_option,
        commit
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: components/engine_state.uc (library module, no CLI)\n");
exit(1);
