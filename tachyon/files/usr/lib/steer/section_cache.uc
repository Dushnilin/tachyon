#!/usr/bin/env ucode
//
// steer/section_cache.uc — builds the runtime section cache on the steer engine.
//
// On sing-box the section cache (/var/run/tachyon/section-cache/<section>.json)
// is a side product of config generation: singbox/generator_outbounds.uc walks
// every subscription source and records the nodes (links, urltest groups,
// display names). The steer lifecycle never runs that pipeline, so the cache
// stayed empty and write_subscription_file produced sub files with no nodes —
// vless outputs fell back to direct and no server was selectable after a
// reboot.
//
// This module rebuilds the same cache straight from the normalized sources in
// /tmp/sing-box/subscriptions (populated by subscription/cache.uc prepare), reusing
// the singbox/subscription.uc state builders so the format stays identical.
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let runtime_subscription = require("singbox.subscription");
let share_link = require("subscription.share_link");

let generator_outbounds = require("singbox.generator_outbounds");
let generator_routes = require("singbox.generator_routes");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") ||
    (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/section-cache";

function is_enabled(section) {
    return as_string(section.enabled || "1") != "0";
}

// Preserve the quota/title metadata written by the subscription cache prepare
// step; this module only rebuilds the node lists around it.
function existing_subscription_metadata(section_name) {
    let data = common.read_json_file(runtime_subscription.section_cache_path(section_name));
    if (type(data) == "object" && type(data.subscriptionMetadata) == "array")
        return data.subscriptionMetadata;
    return [];
}

function build_section_cache(section) {
    let section_name = as_string(section[".name"]);
    if (section_name == "")
        return false;

    let urls = array_or_empty(connections.subscription_urls(section));
    if (length(urls) == 0)
        return false;

    let existing_meta = existing_subscription_metadata(section_name);

    let config = { outbounds: [] };
    let taken = {};

    generator_outbounds.init({
        runtime_supports_xhttp: true,
        routes: generator_routes,
        atomic_write_json_file: common.write_json_file,
        runtime_settings: function() { return uci_core.get_all(CONFIG_NAME, "settings") || {}; },
        runtime_generate_unsupported: function(msg) {}
    });
    generator_routes.init({
        runtime_settings: function() { return uci_core.get_all(CONFIG_NAME, "settings") || {}; }
    });

    generator_outbounds.add_connections_outbound(config, section, taken);

    if (length(existing_meta) > 0) {
        let cache_path = runtime_subscription.section_cache_path(section_name);
        let cache_data = common.read_json_file(cache_path);
        if (type(cache_data) == "object" && (!cache_data.subscriptionMetadata || length(cache_data.subscriptionMetadata) == 0)) {
            cache_data.subscriptionMetadata = existing_meta;
            common.write_json_file(cache_path, cache_data);
        }
    }

    return true;
}

// Rebuild the cache for every enabled subscription-backed section. Returns the
// number of caches (re)written.
function build_section_caches() {
    let sections = uci_core.section_objects(CONFIG_NAME, "section") || [];
    let built = 0;
    for (let section in sections) {
        if (type(section) != "object" || !is_enabled(section))
            continue;
        if (build_section_cache(section))
            built++;
    }
    return built;
}

function module_exports() {
    return {
        build_section_cache,
        build_section_caches,
        SECTION_CACHE_DIR
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: steer/section_cache.uc (library module, no CLI)\n");
exit(1);
