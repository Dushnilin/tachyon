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
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/sing-box/subscriptions";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") ||
    (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/section-cache";

function is_enabled(section) {
    return as_string(section.enabled || "1") != "0";
}

// Apply section-level URLTest settings (url, interval, tolerance, idle_timeout,
// interrupt) as defaults to subscription-provided groups that do not carry those
// fields themselves.
// NOTE: connections.urltest_*(section, "urltest") only works when the urltest
// child has id="urltest". When the user names it "SoftPortal" etc., we must
// read the UCI "urltest" type sections directly.
function apply_section_urltest_config(state, section) {
    let groups = object_or_empty(state.urltestGroups);
    if (length(keys(groups)) == 0)
        return;

    let section_name = as_string(section[".name"]);

    // Collect all urltest child sections that belong to this section.
    let urltest_children = array_or_empty(uci_core.section_objects(CONFIG_NAME, "urltest"));
    let matched = [];
    for (let child in urltest_children) {
        if (as_string(child.section || "") == section_name)
            push(matched, child);
    }

    let cfg_url, cfg_interval, cfg_tolerance, cfg_idle_timeout, cfg_interrupt;
    if (length(matched) > 0) {
        let c = matched[0];
        cfg_url = as_string(c.testing_url || c.urltest_testing_url || "https://www.gstatic.com/generate_204");
        cfg_interval = as_string(c.check_interval || c.urltest_check_interval || "3m");
        cfg_tolerance = as_string(c.tolerance || c.urltest_tolerance || "50");
        cfg_idle_timeout = as_string(c.idle_timeout || "");
        // UCI stores booleans as "0"/"1" strings
        let intr = c.interrupt_exist_connections;
        cfg_interrupt = (intr == "1" || intr === true);
    } else {
        // Fallback: section-level flat options (legacy / single-urltest setups)
        cfg_url = connections.urltest_testing_url(section, "urltest");
        cfg_interval = connections.urltest_check_interval(section, "urltest");
        cfg_tolerance = as_string(connections.urltest_tolerance(section, "urltest") || "");
        cfg_idle_timeout = as_string(connections.urltest_idle_timeout(section, "urltest") || "");
        cfg_interrupt = connections.urltest_interrupt_exist_connections(section, "urltest");
    }

    for (let tag_name in groups) {
        let group = groups[tag_name];
        if (group.url == null && cfg_url != null && cfg_url != "")
            group.url = cfg_url;
        if (group.interval == null && cfg_interval != null && cfg_interval != "")
            group.interval = cfg_interval;
        if (group.tolerance == null && cfg_tolerance != "")
            group.tolerance = cfg_tolerance;
        if ((group.idle_timeout == null || group.idle_timeout == "") && cfg_idle_timeout != "")
            group.idle_timeout = cfg_idle_timeout;
        if (group.interrupt_exist_connections == null)
            group.interrupt_exist_connections = cfg_interrupt;
    }
}

function unique_tag(tag, taken) {
    tag = as_string(tag);
    if (!taken[tag])
        return tag;

    let index = 1;
    while (taken[tag + "-" + index])
        index++;
    return tag + "-" + index;
}

function copy_subscription_outbound(outbound, new_tag) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__tachyon_hidden" && key != "__tachyon_allow_group")
            copy[key] = value;
    }
    copy.tag = new_tag;
    return copy;
}

function subscription_urltest_group_outbound(outbound) {
    return type(outbound) == "object" && as_string(outbound.type) == "urltest";
}

function subscription_group_outbound(outbound) {
    return type(outbound) == "object" &&
        (as_string(outbound.type) == "urltest" || as_string(outbound.type) == "selector");
}

function subscription_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || outbound.remark || "") : "";
}

function subscription_visibility_refs(outbounds) {
    let refs = {
        urltest: {},
        detour: {}
    };

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        if (subscription_urltest_group_outbound(outbound)) {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    refs.urltest[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            refs.detour[detour] = true;
    }

    return refs;
}

function subscription_hidden_outbound(outbound, refs, hide_urltest_group_outbounds, hide_detour_outbounds) {
    if (type(outbound) != "object")
        return false;

    let tag_name = subscription_outbound_tag(outbound);
    let urltest_refs = object_or_empty(object_or_empty(refs).urltest);
    let detour_refs = object_or_empty(object_or_empty(refs).detour);
    let hidden_by_urltest = tag_name != "" && urltest_refs[tag_name];
    let hidden_by_detour = tag_name != "" && detour_refs[tag_name];

    if (hidden_by_urltest && hide_urltest_group_outbounds !== false)
        return true;
    if (hidden_by_detour && hide_detour_outbounds !== false)
        return true;
    let is_hidden_flag = outbound.__tachyon_hidden === true || outbound.__tachyon_hidden === "1" || outbound.__tachyon_hidden === 1;
    return is_hidden_flag && !hidden_by_urltest && !hidden_by_detour;
}

function subscription_reference_set(outbounds) {
    let refs = {};
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;
        let t = as_string(outbound.tag || "");
        if (t != "") refs[t] = true;
        let r = as_string(outbound.remark || "");
        if (r != "") refs[r] = true;
    }
    return refs;
}

function rewrite_subscription_outbound_references(outbounds, tag_map, source_refs) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        let detour = as_string(outbound.detour || "");
        if (detour != "" && tag_map[detour])
            outbound.detour = tag_map[detour];
        else if (detour != "" && source_refs[detour])
            delete outbound.detour;

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_map[tag_name])
                    push(rewritten, tag_map[tag_name]);
            }
            outbound.outbounds = rewritten;
            delete outbound.default;
        }
    }
}

function build_section_cache(section) {
    let section_name = as_string(section[".name"]);
    if (section_name == "")
        return false;

    let urls = array_or_empty(connections.subscription_urls(section));
    if (length(urls) == 0)
        return false;

    let state = runtime_subscription.new_section_state(section_name);
    // Delete the existing cache BEFORE building so that read_section_metadata()
    // (called inside merge_source_metadata) cannot read stale data from the old
    // Main.json and re-inflate subscriptionMetadata on every rebuild.
    // NOTE: fs.unlink throws on ENOENT — wrap in try/catch (pattern from migration.uc).
    try { fs.unlink(runtime_subscription.section_cache_path(section_name)); } catch(e) {}
    let taken = {};

    let index = 0;
    for (let entry in urls) {
        index++;
        let source_section = runtime_subscription.source_id(section_name, index);
        let outbounds = array_or_empty(runtime_subscription.read_source_outbounds(source_section));
        if (length(outbounds) == 0)
            continue;

        let show_metadata = connections.subscription_dashboard_metadata_enabled(section, entry);
        if (show_metadata !== false)
            runtime_subscription.merge_source_metadata(state, section_name, source_section, index, entry);

        let include_urltest_groups = connections.subscription_include_urltest_groups(section, entry);
        let hide_urltest_group_outbounds = connections.subscription_hide_urltest_group_outbounds(section, entry);
        let hide_detour_outbounds = connections.subscription_hide_detour_outbounds(section, entry);
        let node_prefix = connections.subscription_node_prefix(section, entry);

        if (include_urltest_groups === false)
            hide_urltest_group_outbounds = false;

        let visibility_refs = subscription_visibility_refs(outbounds);
        let prepared = [];
        let display_names = [];
        let source_links = [];
        let group_flags = [];
        let hidden_flags = [];
        let tag_map = {};

        for (let i = 0; i < length(outbounds); i++) {
            let outbound = outbounds[i];
            if (type(outbound) != "object")
                continue;

            if (include_urltest_groups === false && subscription_urltest_group_outbound(outbound))
                continue;

            let t = as_string(outbound.type || "");
            if (t == "selector" || t == "direct" || t == "block" || t == "dns")
                continue;

            let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
            let base = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
            if (node_prefix != "") {
                display_name = node_prefix + " " + display_name;
                base = display_name;
            }

            let new_tag = unique_tag(base, taken);
            taken[new_tag] = true;
            tag_map[base] = new_tag;
            if (as_string(outbound.tag || "") != "")
                tag_map[as_string(outbound.tag)] = new_tag;
            if (as_string(outbound.remark || "") != "")
                tag_map[as_string(outbound.remark)] = new_tag;

            push(prepared, copy_subscription_outbound(outbound, new_tag));
            push(display_names, display_name);

            let source_link = as_string(outbound.share_link || "");
            if (!share_link.is_copyable_link(source_link))
                source_link = share_link.serialize_outbound_link(outbound);
            push(source_links, source_link);

            let is_group = subscription_group_outbound(outbound);
            push(group_flags, is_group);
            push(hidden_flags, subscription_hidden_outbound(outbound, visibility_refs, hide_urltest_group_outbounds, hide_detour_outbounds));
        }

        rewrite_subscription_outbound_references(prepared, tag_map, subscription_reference_set(outbounds));

        for (let i = 0; i < length(prepared); i++) {
            let outbound = prepared[i];
            let is_group = group_flags[i];
            if (is_group) {
                if (length(array_or_empty(outbound.outbounds)) > 0)
                    runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
                continue;
            }

            runtime_subscription.remember_source_outbound(
                state,
                outbound.tag,
                display_names[i],
                outbound,
                source_links[i],
                node_prefix
            );

            if (hidden_flags[i] === true) {
                state.hiddenOutboundTags[outbound.tag] = true;
            }
        }
    }

    if (length(keys(state.links)) == 0 && length(keys(state.urltestGroups)) == 0)
        return false;

    // Patch urltest groups with Tachyon-configured settings where the subscription
    // outbounds didn't carry url / interval / tolerance themselves.
    apply_section_urltest_config(state, section);

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
