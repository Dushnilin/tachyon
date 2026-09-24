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

    let state = runtime_subscription.new_section_state(section_name);
    state.subscriptionMetadata = existing_subscription_metadata(section_name);
    let node_prefix = trim(as_string(section.node_prefix || ""));

    let index = 0;
    for (let entry in urls) {
        index++;
        let source_section = runtime_subscription.source_id(section_name, index);
        let outbounds = array_or_empty(runtime_subscription.read_source_outbounds(source_section));

        for (let i = 0; i < length(outbounds); i++) {
            let outbound = outbounds[i];
            if (type(outbound) != "object")
                continue;
            let tag = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
            let display_name = as_string(outbound.remark || outbound.tag || tag);

            if (as_string(outbound.type) == "urltest") {
                if (length(array_or_empty(outbound.outbounds)) > 0)
                    runtime_subscription.remember_urltest_group(state, tag, display_name, outbound);
                continue;
            }
            if (as_string(outbound.type) == "selector" || as_string(outbound.type) == "direct" ||
                as_string(outbound.type) == "block" || as_string(outbound.type) == "dns")
                continue;

            let source_link = as_string(outbound.share_link || "");
            if (!share_link.is_copyable_link(source_link))
                source_link = share_link.serialize_outbound_link(outbound);
            runtime_subscription.remember_source_outbound(state, tag, display_name, outbound, source_link, node_prefix);
        }
    }

    if (length(keys(state.links)) == 0 && length(keys(state.urltestGroups)) == 0)
        return false;

    common.write_json_file(runtime_subscription.section_cache_path(section_name), state);
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
