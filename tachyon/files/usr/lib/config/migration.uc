#!/usr/bin/env ucode

// Keep migrations in this file. A migration is identified by a stable name;
// release checks are optional conditions inside the migration itself.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let core_url = require("core.url");
let constants_module = require("core.constants");
let singbox_constants_module = require("tachyon_core.constants");
let domain_config = require("config.domain");
let rule_config = require("config.rule");
let subscription_share_link = require("subscription.share_link");

let as_string = common.as_string;
let read_json_file = common.read_json_file;
let write_json = common.write_json;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let object_or_empty = common.object_or_empty;
let shell_quote = common.shell_quote;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const CONFIG_DIR = getenv("TACHYON_CONFIG_DIR") || "/etc/config";
const TARGET_CONFIG = getenv("TACHYON_CONFIG_FILE") || (CONFIG_DIR + "/" + CONFIG_NAME);
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/tachyon-core/subscriptions";
const TACHYON_RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const TACHYON_SUBSCRIPTION_LINKS_DIR = getenv("TACHYON_SUBSCRIPTION_LINKS_DIR") || TACHYON_RUNTIME_STATE_DIR + "/subscription-links";
const TACHYON_SUBSCRIPTION_METADATA_DIR = getenv("TACHYON_SUBSCRIPTION_METADATA_DIR") || TACHYON_RUNTIME_STATE_DIR + "/subscription-metadata";
const TACHYON_OUTBOUND_METADATA_DIR = getenv("TACHYON_OUTBOUND_METADATA_DIR") || TACHYON_RUNTIME_STATE_DIR + "/outbound-metadata";
const TACHYON_SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || TACHYON_RUNTIME_STATE_DIR + "/section-cache";
const TACHYON_RUNTIME_CACHE_FORMAT_FILE = getenv("TACHYON_RUNTIME_CACHE_FORMAT_FILE") || TACHYON_RUNTIME_STATE_DIR + "/cache-format";
const TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/tachyon/subscription-cache";
const TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "7";
const TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD = getenv("TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD") || "/var/run/tachyon.internal-config-change";
const TACHYON_RUNTIME_CACHE_FORMAT = getenv("TACHYON_RUNTIME_CACHE_FORMAT") || "8";
const CONFIG_VERSION_OPTION = "config_version";
const APPLIED_MIGRATIONS_OPTION = "applied_migrations";
const SERVER_COUNTRY_METHOD_FLAG_EMOJI = "flag_emoji";
const SERVER_COUNTRY_METHOD_COUNTRY_IS = "country_is";
const CHILD_ITEM_TYPES = [
    "subscription_url",
    "section_interface",
    "urltest",
    "priority_group",
    "priority_level",
    "condition",
    "outbound_source",
    "outbound_group",
    "balancer"
];


function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return replace(as_string(data), /[\r\n]+$/g, "");
}

function run(command) {
    return system(command) == 0;
}

function constants_context() {
    let constants = object_or_empty(constants_module);
    return {
        zapret_legacy_default_nfqws_opt: as_string(constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT),
        zapret_default_nfqws_opt: as_string(constants.ZAPRET_DEFAULT_NFQWS_OPT),
        urltest_default_idle_timeout: as_string(object_or_empty(singbox_constants_module).URLTEST_DEFAULT_IDLE_TIMEOUT || "30m")
    };
}

function section_name(section) {
    return option(section, ".name", "");
}

function clone_section(section) {
    let result = {};
    for (let key in keys(object_or_empty(section)))
        result[key] = section[key];
    return result;
}

function fixture_section_list(data, type_name) {
    let value = object_or_empty(data)[type_name];
    if (type(value) == "array")
        return value;
    if (type(value) == "object")
        return [ value ];

    let plural = object_or_empty(data)[type_name + "s"];
    return type(plural) == "array" ? plural : [];
}

function model_from_fixture(path) {
    let data = object_or_empty(read_json_file(path));
    let model = {
        settings: clone_section(object_or_empty(data.settings)),
        rules: [],
        sections: []
    };
    for (let type_name in CHILD_ITEM_TYPES)
        model[type_name] = [];

    if (model.settings[".name"] == null)
        model.settings[".name"] = "settings";
    if (model.settings[".type"] == null)
        model.settings[".type"] = "settings";

    for (let section in fixture_section_list(data, "rule"))
        push(model.rules, clone_section(section));
    for (let section in fixture_section_list(data, "section"))
        push(model.sections, clone_section(section));
    for (let type_name in CHILD_ITEM_TYPES)
        for (let section in fixture_section_list(data, type_name))
            push(model[type_name], clone_section(section));

    return model;
}

function model_from_uci(cursor) {
    let model = {
        settings: clone_section(object_or_empty(cursor.get_all(CONFIG_NAME, "settings"))),
        rules: [],
        sections: []
    };
    for (let type_name in CHILD_ITEM_TYPES)
        model[type_name] = [];

    cursor.foreach(CONFIG_NAME, "rule", function(section) {
        push(model.rules, clone_section(section));
    });
    cursor.foreach(CONFIG_NAME, "section", function(section) {
        push(model.sections, clone_section(section));
    });
    for (let type_name in CHILD_ITEM_TYPES) {
        cursor.foreach(CONFIG_NAME, type_name, function(section) {
            push(model[type_name], clone_section(section));
        });
    }

    return model;
}

function export_model(model) {
    let result = {
        settings: model.settings,
        section: model.sections
    };
    if (length(model.rules) > 0)
        result.rule = model.rules;
    for (let type_name in CHILD_ITEM_TYPES)
        if (length(model[type_name] || []) > 0)
            result[type_name] = model[type_name];
    return result;
}

function migration_context(model) {
    return {
        model,
        operations: [],
        removed_caches: [],
        added_lists: {},
        changed: false
    };
}

function record_operation(ctx, op) {
    push(ctx.operations, op);
    ctx.changed = true;
}

function option_exists(section, key) {
    return object_or_empty(section)[key] != null;
}

function set_option(ctx, section, key, value) {
    value = as_string(value);
    if (option(section, key, "") == value && option_exists(section, key))
        return;

    section[key] = value;
    record_operation(ctx, { op: "set", section: section_name(section), option: key, value });
}

function set_option_if_missing(ctx, section, key, value) {
    if (option_exists(section, key))
        return;
    set_option(ctx, section, key, value);
}

function list_values_equal(left, right) {
    if (length(left) != length(right))
        return false;

    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;

    return true;
}

function set_list_option(ctx, section, key, values) {
    let normalized = [];
    for (let value in values) {
        value = as_string(value);
        if (value != "")
            push(normalized, value);
    }

    let current = object_or_empty(section)[key];
    let current_values = [];
    if (type(current) == "array")
        current_values = current;
    else if (current != null && as_string(current) != "")
        current_values = [ as_string(current) ];

    if (option_exists(section, key) && list_values_equal(current_values, normalized))
        return;

    section[key] = normalized;
    record_operation(ctx, { op: "set_list", section: section_name(section), option: key, values: normalized });
}

function set_list_option_if_not_empty(ctx, section, key, values) {
    if (length(values || []) > 0)
        set_list_option(ctx, section, key, values);
}

function delete_option(ctx, section, key) {
    if (!option_exists(section, key))
        return;

    delete section[key];
    record_operation(ctx, { op: "delete", section: section_name(section), option: key });
}

function list_contains(section, key, value) {
    value = as_string(value);
    for (let item in list_option(section, key))
        if (as_string(item) == value)
            return true;
    return false;
}

function add_list_unique(ctx, section, key, value) {
    value = as_string(value);
    if (value == "")
        return;

    let list_key = section_name(section) + "." + key + "=" + value;
    if (ctx.added_lists[list_key] || list_contains(section, key, value))
        return;

    let current = section[key];
    if (type(current) != "array")
        current = list_option(section, key);
    push(current, value);
    section[key] = current;
    ctx.added_lists[list_key] = true;
    record_operation(ctx, { op: "add_list", section: section_name(section), option: key, values: current });
}

function create_child_section(ctx, type_name) {
    ctx.child_index = int(ctx.child_index || 0) + 1;
    let item_id = "__" + type_name + "_" + ctx.child_index;
    let section = {
        ".name": item_id,
        ".type": type_name
    };
    if (ctx.model[type_name] == null)
        ctx.model[type_name] = [];
    push(ctx.model[type_name], section);
    record_operation(ctx, { op: "create", section: item_id, type: type_name, anonymous: true });
    return section;
}

function create_child_for_section(ctx, parent, type_name) {
    let child = create_child_section(ctx, type_name);
    set_option(ctx, child, "section", section_name(parent));
    return child;
}

function create_named_section(ctx, type_name, section_id) {
    section_id = as_string(section_id);
    if (ctx.model[type_name] == null)
        ctx.model[type_name] = [];
    for (let existing in ctx.model[type_name]) {
        if (section_name(existing) == section_id)
            return existing;
    }
    let section = {
        ".name": section_id,
        ".type": type_name
    };
    push(ctx.model[type_name], section);
    record_operation(ctx, { op: "create", section: section_id, type: type_name, anonymous: false });
    return section;
}

function option_list_values(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    if (value == null)
        return [];
    value = as_string(value);
    return value == "" ? [] : [ value ];
}

function whitespace_list_values(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    return list_option(section, key);
}

function subscription_url_entry_profile(value) {
    let entry = trim(as_string(value));
    let result = {
        raw: entry,
        value: entry,
        user_agent: "",
        changed: false
    };
    let delimiter = " | ";
    let delimiter_index = rindex(entry, delimiter);

    if (delimiter_index < 0)
        return result;

    let url = trim(substr(entry, 0, delimiter_index));
    let user_agent = trim(substr(entry, delimiter_index + length(delimiter)));
    if (url == "" || user_agent == "")
        return result;

    result.value = url;
    result.user_agent = user_agent;
    result.changed = true;
    return result;
}

function normalize_connections_list(ctx, section, old_key, new_key) {
    let old_values = option_list_values(section, old_key);

    for (let value in old_values)
        add_list_unique(ctx, section, new_key, value);

    if (length(old_values) > 0)
        delete_option(ctx, section, old_key);
}

function set_section_type(ctx, section, type_name) {
    if (option(section, ".type", "") == type_name)
        return;

    section[".type"] = type_name;
    record_operation(ctx, { op: "set_type", section: section_name(section), type: type_name });
}

function normalize_detect_server_country_method(value) {
    value = as_string(value);
    if (value == SERVER_COUNTRY_METHOD_COUNTRY_IS)
        return SERVER_COUNTRY_METHOD_COUNTRY_IS;
    return SERVER_COUNTRY_METHOD_FLAG_EMOJI;
}

function urltest_filter_mode_filters_enabled(value) {
    return value == "exclude" || value == "include" || value == "mixed";
}

function duration_to_seconds_value(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        let token = as_string(matched[0]);
        let amount = matched[1] * 1;
        let unit = matched[3];
        total += amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? null : int(total + 0.5);
}

function legacy_urltest_idle_timeout(section, constants) {
    let interval = option(section, "urltest_check_interval", "3m") || "3m";
    let interval_seconds = duration_to_seconds_value(interval);
    let default_idle_seconds = duration_to_seconds_value(object_or_empty(constants).urltest_default_idle_timeout || "30m");
    return interval_seconds != null && default_idle_seconds != null && interval_seconds > default_idle_seconds
        ? interval
        : "";
}

const LEGACY_URLTEST_OPTIONS = [
    "urltest_enabled",
    "urltest_check_interval",
    "urltest_tolerance",
    "urltest_testing_url",
    "urltest_filter_mode",
    "urltest_hide_filtered_outbounds",
    "detect_server_country",
    "urltest_include_countries",
    "urltest_include_outbounds",
    "urltest_include_regex",
    "urltest_exclude_countries",
    "urltest_exclude_outbounds",
    "urltest_exclude_regex",
    "urltest_idle_timeout",
    "urltest_interrupt_exist_connections",
    "urltest_interval",
    "urltest_url",
    "urltest_proxy_links_text",
    "selector_proxy_links_text"
];

function delete_legacy_urltest_options(ctx, section) {
    for (let key in LEGACY_URLTEST_OPTIONS)
        delete_option(ctx, section, key);
}

function migrate_urltest_filter_mode(ctx, section) {
    if (option_exists(section, "urltest_filter_mode"))
        return;

    if (option_exists(section, "urltest_exclude_countries") ||
        option_exists(section, "urltest_include_countries") ||
        option_exists(section, "urltest_exclude_outbounds") ||
        option_exists(section, "urltest_exclude_regex")) {
        set_option(ctx, section, "urltest_filter_mode", "exclude");
    }
}

function migrate_detect_server_country(ctx, section) {
    if (!option_exists(section, "detect_server_country"))
        return;

    let value = option(section, "detect_server_country", "");
    if (value != "0" && value != "1")
        return;

    if (bool_option(section, "urltest_enabled", false) &&
        urltest_filter_mode_filters_enabled(option(section, "urltest_filter_mode", "disabled"))) {
        set_option(ctx, section, "detect_server_country", normalize_detect_server_country_method(value));
    }
    else {
        delete_option(ctx, section, "detect_server_country");
    }
}

function trim_lines(value) {
    let result = [];
    for (let line in split(as_string(value), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }
    return result;
}

function migrate_urltest_link(ctx, section, link) {
    add_list_unique(ctx, section, "selector_proxy_links", link);
}

function migrate_proxy_string(ctx, section) {
    let proxy_string = option(section, "proxy_string", "");
    if (proxy_string == "")
        return;

    let migrated = false;
    for (let link in trim_lines(proxy_string)) {
        if (substr(link, 0, 2) == "//")
            continue;
        add_list_unique(ctx, section, "selector_proxy_links", link);
        migrated = true;
    }

    if (migrated)
        delete_option(ctx, section, "proxy_string");
}

function cache_section_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0
        && match(section, /[^A-Za-z0-9_+.\-]/) == null;
}

function subscription_cache_paths(section) {
    return [
        TMP_SUBSCRIPTION_FOLDER + "/" + section + ".json",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + ".url",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + ".user_agent",
        TACHYON_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json",
        TACHYON_SUBSCRIPTION_LINKS_DIR + "/" + section + ".json",
        TACHYON_OUTBOUND_METADATA_DIR + "/" + section + ".json",
        TACHYON_SECTION_CACHE_DIR + "/" + section + ".json",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + "-subscription-*.json",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + "-subscription-*.url",
        TMP_SUBSCRIPTION_FOLDER + "/" + section + "-subscription-*.user_agent"
    ];
}

function delete_subscription_cache(ctx, section) {
    section = as_string(section);
    if (!cache_section_safe(section))
        return;

    for (let path in subscription_cache_paths(section))
        push(ctx.removed_caches, path);
}

function migrate_text_proxy_links(ctx, section, option_name) {
    let text = option(section, option_name, "");
    if (text == "")
        return false;

    let migrated = false;
    for (let link in trim_lines(text)) {
        if (substr(link, 0, 2) == "//" || substr(link, 0, 1) == "#")
            continue;
        add_list_unique(ctx, section, "selector_proxy_links", link);
        migrated = true;
    }

    delete_option(ctx, section, option_name);
    return migrated;
}

function migrate_subscription_url(ctx, section) {
    let urls = option_list_values(section, "subscription_url");
    if (length(urls) == 0)
        return;

    let subscription_user_agent = option(section, "subscription_user_agent", "");
    for (let u in urls) {
        u = trim(as_string(u));
        if (u == "")
            continue;
        let entry = subscription_user_agent != ""
            ? u + " | " + subscription_user_agent
            : u;
        add_list_unique(ctx, section, "subscription_urls", entry);
    }
    delete_option(ctx, section, "subscription_url");
    delete_option(ctx, section, "subscription_user_agent");
    delete_subscription_cache(ctx, section_name(section));
}

function migrate_interval_flags(ctx, section, proxy_config_type) {
    if (proxy_config_type == "urltest" || proxy_config_type == "subscription" || proxy_config_type == "urltest_text") {
        if (option(section, "urltest_check_interval_disabled", "") == "1")
            set_option(ctx, section, "urltest_enabled", "0");
        else
            set_option_if_missing(ctx, section, "urltest_enabled", "1");
    }
    else if (proxy_config_type == "url" || proxy_config_type == "selector" || proxy_config_type == "selector_text") {
        set_option_if_missing(ctx, section, "urltest_enabled", "0");
    }

    if (proxy_config_type == "subscription") {
        if (option(section, "subscription_update_interval_disabled", "") == "1")
            set_option(ctx, section, "subscription_update_enabled", "0");
        else
            set_option_if_missing(ctx, section, "subscription_update_enabled", "1");
    }

    delete_option(ctx, section, "urltest_check_interval_disabled");
    delete_option(ctx, section, "subscription_update_interval_disabled");
}

function migrate_proxy_rule(ctx, section, proxy_config_type) {
    if (proxy_config_type == "url")
        migrate_proxy_string(ctx, section);
    else if (proxy_config_type == "urltest") {
        for (let link in list_option(section, "urltest_proxy_links"))
            migrate_urltest_link(ctx, section, link);
        delete_option(ctx, section, "urltest_proxy_links");
    }
    else if (proxy_config_type == "subscription") {
        migrate_subscription_url(ctx, section);
        delete_subscription_cache(ctx, section_name(section));
    }
    else if (proxy_config_type == "selector_text") {
        migrate_text_proxy_links(ctx, section, "selector_proxy_links_text");
    }
    else if (proxy_config_type == "urltest_text") {
        migrate_text_proxy_links(ctx, section, "urltest_proxy_links_text");
        set_option_if_missing(ctx, section, "urltest_enabled", "1");
    }

    // Always migrate text links if present on section regardless of proxy_config_type
    migrate_text_proxy_links(ctx, section, "selector_proxy_links_text");
    if (migrate_text_proxy_links(ctx, section, "urltest_proxy_links_text"))
        set_option_if_missing(ctx, section, "urltest_enabled", "1");

    migrate_interval_flags(ctx, section, proxy_config_type);
    delete_option(ctx, section, "proxy_config_type");
}

// Podkop Plus -> Tachyon source migration.
function migrated_rule_action(section) {
    let action = option(section, "action", "");
    let proxy_config_type = option(section, "proxy_config_type", "");
    let connection_type = option(section, "connection_type", "");
    let iface = option(section, "interface", "");
    let outbound_json = option(section, "outbound_json", "");
    let selector_proxy_links = option(section, "selector_proxy_links", "");
    let subscription_urls = option(section, "subscription_urls", "");

    if (action == "proxy" || action == "vpn" || action == "outbound")
        return "connection";

    if (action == "direct")
        return "bypass";

    if (action != "")
        return action;

    if (connection_type == "proxy")
        return "connection";
    if (connection_type == "vpn")
        return "connection";
    if (connection_type == "block")
        return "block";
    if (connection_type == "exclusion")
        return "bypass";

    if (proxy_config_type == "interface")
        return "connection";
    if (proxy_config_type == "outbound")
        return "connection";
    if (proxy_config_type == "url" || proxy_config_type == "selector" ||
        proxy_config_type == "urltest" || proxy_config_type == "subscription")
        return "connection";

    if (outbound_json != "")
        return "connection";
    if (iface != "")
        return "connection";
    if (selector_proxy_links != "" || subscription_urls != "")
        return "connection";

    return "";
}

function legacy_rule_connection_kind(section) {
    let action = option(section, "action", "");
    let proxy_config_type = option(section, "proxy_config_type", "");
    let connection_type = option(section, "connection_type", "");

    if (action == "vpn" || connection_type == "vpn" || proxy_config_type == "interface")
        return "interface";
    if (action == "outbound" || proxy_config_type == "outbound")
        return "outbound";
    if (action == "proxy" || connection_type == "proxy" ||
        proxy_config_type == "url" || proxy_config_type == "selector" ||
        proxy_config_type == "urltest" || proxy_config_type == "subscription")
        return "proxy";
    if (option(section, "interface", "") != "")
        return "interface";
    if (option(section, "outbound_json", "") != "")
        return "outbound";
    return "proxy";
}

function migrate_byedpi_cmd_opts(ctx, section) {
    let cmd_opts = option(section, "cmd_opts", "");
    if (cmd_opts == "")
        return;

    if (option(section, "byedpi_cmd_opts", "") == "")
        set_option(ctx, section, "byedpi_cmd_opts", cmd_opts);
    delete_option(ctx, section, "cmd_opts");
}

function migrate_ctrack_timeouts(ctx, section) {
    let action = migrated_rule_action(section);
    let opt_name = action == "zapret2" ? "nfqws2_opt" : (action == "zapret" ? "nfqws_opt" : "");
    if (opt_name == "")
        return;
    let opt = option(section, opt_name, "");
    if (opt == "" || index(opt, "--ctrack-timeouts=") < 0)
        return;
    let normalized = replace(opt, /--ctrack-timeouts=([0-9,]+)/g, function(full, numbers) {
        if (index(numbers, ",") < 0)
            return full;
        let parts = split(numbers, ",");
        if (length(parts) >= 8 && parts[0] == "30" && parts[2] == "600")
            return "--ctrack-timeouts=30:600:30:30";
        if (length(parts) >= 4)
            return "--ctrack-timeouts=" + parts[0] + ":" + parts[1] + ":" + parts[2] + ":" + parts[3];
        if (length(parts) >= 3)
            return "--ctrack-timeouts=" + parts[0] + ":" + parts[1] + ":" + parts[2];
        return "--ctrack-timeouts=30:600:30:30";
    });
    if (normalized != opt)
        set_option(ctx, section, opt_name, normalized);
}

function migrate_zapret_nfqws_default(ctx, section, constants) {
    if (migrated_rule_action(section) != "zapret")
        return;

    let nfqws_opt = option(section, "nfqws_opt", "");
    if (nfqws_opt == "" || nfqws_opt != constants.zapret_legacy_default_nfqws_opt)
        return;

    set_option(ctx, section, "nfqws_opt", constants.zapret_default_nfqws_opt);
}

function migrate_subscription_url_item_settings(ctx, section) {
    let values = whitespace_list_values(section, "subscription_urls");
    let seen_values = {};
    let update_enabled = bool_option(section, "subscription_update_enabled", true);
    let update_interval = option(section, "subscription_update_interval", "");
    if (update_interval == "")
        update_interval = "1h";
    let index = 1;

    for (let value in values) {
        let profile = subscription_url_entry_profile(value);
        if (profile.value == "")
            continue;
        if (seen_values[profile.value])
            continue;
        seen_values[profile.value] = true;

        let child = create_child_for_section(ctx, section, "subscription_url");
        set_option(ctx, child, "url", profile.value);
        set_option(ctx, child, "subscription_update_enabled", update_enabled ? "1" : "0");
        set_option(ctx, child, "subscription_update_interval", update_enabled ? update_interval : "");
        set_option(ctx, child, "auto_user_agent", profile.user_agent != "" ? "0" : "1");
        if (profile.user_agent != "")
            set_option(ctx, child, "user_agent", profile.user_agent);
        set_option(ctx, child, "auto_hwid", "1");
        set_option(ctx, child, "show_dashboard_metadata", "1");
        set_option(ctx, child, "prefix_nodes", "0");
        set_option(ctx, child, "include_urltest_groups", "1");
        set_option(ctx, child, "hide_urltest_group_outbounds", "1");
        set_option(ctx, child, "hide_detour_outbounds", "1");
        index++;
    }

    delete_option(ctx, section, "subscription_urls");
    delete_option(ctx, section, "subscription_url_settings");
}

function migrate_urltest_item_settings(ctx, section, constants) {
    let legacy_enabled = bool_option(section, "urltest_enabled", false);

    if (legacy_enabled) {
        let child = create_child_for_section(ctx, section, "urltest");
        set_option(ctx, child, "name", "Fastest");
        let check_interval = option(section, "urltest_check_interval", "");
        if (check_interval == "")
            check_interval = option(section, "urltest_interval", "3m");
        set_option(ctx, child, "check_interval", check_interval || "3m");

        set_option(ctx, child, "tolerance", option(section, "urltest_tolerance", "50") || "50");

        let testing_url = option(section, "urltest_testing_url", "");
        if (testing_url == "")
            testing_url = option(section, "urltest_url", "https://www.gstatic.com/generate_204");
        set_option(ctx, child, "testing_url", testing_url || "https://www.gstatic.com/generate_204");
        set_option(ctx, child, "filter_mode", option(section, "urltest_filter_mode", "disabled") || "disabled");
        set_option(ctx, child, "detect_server_country", normalize_detect_server_country_method(option(section, "detect_server_country", SERVER_COUNTRY_METHOD_FLAG_EMOJI)));
        set_option(ctx, child, "interrupt_exist_connections", "1");
        set_option(ctx, child, "pin_dashboard", "1");

        let idle_timeout = option(section, "urltest_idle_timeout", "");
        if (idle_timeout == "")
            idle_timeout = legacy_urltest_idle_timeout(section, constants);
        if (idle_timeout != "")
            set_option(ctx, child, "idle_timeout", idle_timeout);

        if (option(section, "urltest_interrupt_exist_connections", "") != "")
            set_option(ctx, child, "interrupt_exist_connections", option(section, "urltest_interrupt_exist_connections", "1"));

        set_list_option_if_not_empty(ctx, child, "include_countries", option_list_values(section, "urltest_include_countries"));
        set_list_option_if_not_empty(ctx, child, "include_outbounds", option_list_values(section, "urltest_include_outbounds"));
        set_list_option_if_not_empty(ctx, child, "include_regex", option_list_values(section, "urltest_include_regex"));
        set_list_option_if_not_empty(ctx, child, "exclude_countries", option_list_values(section, "urltest_exclude_countries"));
        set_list_option_if_not_empty(ctx, child, "exclude_outbounds", option_list_values(section, "urltest_exclude_outbounds"));
        set_list_option_if_not_empty(ctx, child, "exclude_regex", option_list_values(section, "urltest_exclude_regex"));
    }

    delete_legacy_urltest_options(ctx, section);
    delete_option(ctx, section, "urltest_settings");
}

function migrate_interface_item_settings(ctx, section) {
    let owner = section_name(section);
    let resolver_enabled = bool_option(section, "domain_resolver_enabled", false) ? "1" : "0";
    let dns_type = option(section, "domain_resolver_dns_type", "udp") || "udp";
    let dns_server = option(section, "domain_resolver_dns_server", "8.8.8.8") || "8.8.8.8";
    let seen_values = {};

    for (let child in ctx.model.section_interface || []) {
        if (option(child, "section", "") != owner)
            continue;

        let value = option(child, "name", "");
        if (value == "" || seen_values[value])
            continue;

        seen_values[value] = true;
        set_option_if_missing(ctx, child, "domain_resolver_enabled", resolver_enabled);
        set_option_if_missing(ctx, child, "domain_resolver_dns_type", dns_type);
        set_option_if_missing(ctx, child, "domain_resolver_dns_server", dns_server);
    }

    let values = option_list_values(section, "interfaces");
    let legacy_interface = option(section, "interface", "");
    if (legacy_interface != "")
        push(values, legacy_interface);

    for (let value in values) {
        value = as_string(value);
        if (value == "" || seen_values[value])
            continue;

        seen_values[value] = true;
        let child = create_child_for_section(ctx, section, "section_interface");
        set_option(ctx, child, "name", value);
        set_option(ctx, child, "domain_resolver_enabled", resolver_enabled);
        set_option(ctx, child, "domain_resolver_dns_type", dns_type);
        set_option(ctx, child, "domain_resolver_dns_server", dns_server);
    }

    delete_option(ctx, section, "interface");
    delete_option(ctx, section, "interfaces");
    delete_option(ctx, section, "interface_settings");
    delete_option(ctx, section, "domain_resolver_enabled");
    delete_option(ctx, section, "domain_resolver_dns_type");
    delete_option(ctx, section, "domain_resolver_dns_server");
}

function migrate_legacy_outbound_json_detour(ctx, section, legacy_connection_kind) {
    if (legacy_connection_kind != "outbound" ||
        !bool_option(section, "outbound_detour_enabled", false))
        return;

    let detour_section = option(section, "outbound_detour_section", "");
    let outbound_json = option(section, "outbound_json", "");
    if (detour_section == "" || outbound_json == "")
        return;

    let outbound;
    try {
        outbound = json(outbound_json);
    }
    catch (e) {
        return;
    }
    if (type(outbound) != "object")
        return;

    if (as_string(outbound.detour || "") == "")
        outbound.detour = singbox_constants_module.outbound_tag(detour_section);
    set_option(ctx, section, "outbound_json", sprintf("%J", outbound));
    delete_option(ctx, section, "outbound_detour_enabled");
    delete_option(ctx, section, "outbound_detour_section");
}

function migrate_outbound_json_list(ctx, section, legacy_connection_kind) {
    migrate_legacy_outbound_json_detour(ctx, section, legacy_connection_kind);

    let outbound_json = option(section, "outbound_json", "");
    if (outbound_json != "") {
        let outbound;
        try {
            outbound = json(outbound_json);
        }
        catch (e) {
            outbound = null;
        }

        if (type(outbound) == "object" && trim(as_string(outbound.tag || "")) == "") {
            let existing = option_list_values(section, "outbound_jsons");
            let taken = {};
            for (let value in existing) {
                try {
                    let item = json(value);
                    let tag_name = type(item) == "object" ? trim(as_string(item.tag || "")) : "";
                    if (tag_name != "")
                        taken[tag_name] = true;
                }
                catch (e) {
                    // Collecting tags already in use so the new one does not
                    // collide. An entry that is not valid JSON has no tag to
                    // collide with, so skipping it is exactly right.
                }
            }

            let base = singbox_constants_module.outbound_tag(
                section_name(section) + "-json-" + (length(existing) + 1)
            );
            let tag_name = base;
            for (let suffix = 1; taken[tag_name]; suffix++)
                tag_name = base + "-" + suffix;
            outbound.tag = tag_name;
            set_option(ctx, section, "outbound_json", sprintf("%J", outbound));
        }
    }

    normalize_connections_list(ctx, section, "outbound_json", "outbound_jsons");
}

function migrate_connection_section(ctx, section, constants, legacy_connection_kind) {
    migrate_subscription_url_item_settings(ctx, section);
    migrate_urltest_item_settings(ctx, section, constants);
    migrate_interface_item_settings(ctx, section);
    migrate_outbound_json_list(ctx, section, legacy_connection_kind);

    delete_option(ctx, section, "subscription_update_enabled");
    delete_option(ctx, section, "subscription_update_interval");
    delete_option(ctx, section, "enable_udp_over_tcp");
}

function strip_list_comment(line) {
    line = replace(as_string(line), /^(full|keyword|regex):[[:space:]]*\/\/.*$/, "");
    line = replace(line, /^(full|keyword|regex):[[:space:]]*#.*$/, "");
    line = replace(line, /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function text_list_values(value, separator_mode) {
    let result = [];
    separator_mode = as_string(separator_mode);

    for (let line in split(as_string(value), "\n")) {
        line = strip_list_comment(line);
        line = separator_mode == "comma-space"
            ? replace(line, /[ ,]/g, "\n")
            : replace(line, /,/g, "\n");

        for (let item in split(line, "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    }

    return result;
}

function filter_domain_values(values) {
    let result = [];
    for (let value in values) {
        let colon = index(value, ":");
        if (colon > 0) {
            let prefix = domain_config.ascii_lower(substr(value, 0, colon));
            if (prefix == "full" || prefix == "keyword" || prefix == "regex") {
                let body = substr(value, colon + 1);
                let norm = (prefix == "keyword")
                    ? domain_config.keyword_to_ascii(body)
                    : (prefix == "regex")
                        ? domain_config.regex_to_ascii(body)
                        : domain_config.suffix_to_ascii(body);
                if (norm != null)
                    push(result, prefix + ":" + norm);
                continue;
            }
        }
        let normalized = domain_config.suffix_to_ascii(value);
        if (normalized != null)
            push(result, normalized);
    }
    return result;
}

function generic_values_from_text(value) {
    return text_list_values(value, "comma");
}

function legacy_condition_values(kind, text_mode, conditions_text_mode, text_value, list_value) {
    if (int(text_mode || 0) == 1 || int(conditions_text_mode || 0) == 1)
        return kind == "domains"
            ? filter_domain_values(text_list_values(text_value, "comma-space"))
            : generic_values_from_text(text_value);

    let raw = [];
    if (type(list_value) == "array")
        raw = list_value;
    else if (list_value != null && as_string(list_value) != "")
        raw = [ as_string(list_value) ];

    if (length(raw) > 0) {
        let result = [];
        let sep_mode = (kind == "domains" || kind == "subnets") ? "comma-space" : "comma";
        for (let item in raw) {
            for (let sub in text_list_values(item, sep_mode))
                push(result, sub);
        }
        if (length(result) > 0)
            return result;
    }

    if (as_string(text_value) != "")
        return kind == "domains"
            ? filter_domain_values(text_list_values(text_value, "comma-space"))
            : generic_values_from_text(text_value);

    return [];
}

function add_unique_value(result, seen, value) {
    value = as_string(value);
    if (value == "" || seen[value])
        return;

    seen[value] = true;
    push(result, value);
}

function has_domain_condition_prefix(value) {
    let colon = index(value, ":");
    if (colon <= 0)
        return false;

    let prefix = domain_config.ascii_lower(substr(value, 0, colon));
    return prefix == "full" || prefix == "keyword" || prefix == "regex";
}

function add_values_with_prefix(result, seen, values, prefix) {
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "")
            continue;
        let candidate = has_domain_condition_prefix(value) ? value : prefix + value;
        if (rule_config.prefixed_domain_kind_value(candidate) != null)
            add_unique_value(result, seen, candidate);
    }
}

function legacy_values_for_option(section, option_name, kind) {
    return legacy_condition_values(
        kind,
        option(section, option_name + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, option_name + "_text", ""),
        section[option_name]
    );
}

function raw_text_condition_values(section, option_name) {
    return text_list_values(option(section, option_name, ""), "comma-space");
}

function add_domain_values_with_prefix(result, seen, section, option_name, prefix, kind) {
    let values = legacy_condition_values(
        kind,
        option(section, option_name + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, option_name + "_text", ""),
        section[option_name]
    );

    add_values_with_prefix(result, seen, values, prefix);
}

function migrate_combined_domain_conditions(ctx, section) {
    let values = [];
    let seen = {};

    for (let value in list_option(section, "domain_suffix")) {
        for (let sub in text_list_values(value, "comma-space")) {
            if (rule_config.prefixed_domain_kind_value(sub) != null)
                add_unique_value(values, seen, sub);
        }
    }
    for (let value in raw_text_condition_values(section, "domain_suffix_text")) {
        for (let sub in text_list_values(value, "comma-space")) {
            if (rule_config.prefixed_domain_kind_value(sub) != null)
                add_unique_value(values, seen, sub);
        }
    }

    add_domain_values_with_prefix(values, seen, section, "domain", "full:", "domains");
    add_domain_values_with_prefix(values, seen, section, "domain_keyword", "keyword:", "generic");
    add_domain_values_with_prefix(values, seen, section, "domain_regex", "regex:", "generic");

    if (length(values) > 0)
        set_option(ctx, section, "domain", join("\n", values));
    else
        delete_option(ctx, section, "domain");

    delete_option(ctx, section, "domain_suffix");
    delete_option(ctx, section, "domain_suffix_text");
    delete_option(ctx, section, "domain_suffix_text_mode");
    delete_option(ctx, section, "domain_keyword");
    delete_option(ctx, section, "domain_regex");
    delete_option(ctx, section, "domain_text");
    delete_option(ctx, section, "domain_keyword_text");
    delete_option(ctx, section, "domain_regex_text");
    delete_option(ctx, section, "domain_text_mode");
    delete_option(ctx, section, "domain_keyword_text_mode");
    delete_option(ctx, section, "domain_regex_text_mode");
}

function migrate_text_condition(ctx, section, option_name, kind) {
    let values = legacy_values_for_option(section, option_name, kind);
    if (length(values) > 0)
        set_option(ctx, section, option_name, join("\n", values));
    else if (option_exists(section, option_name) && type(section[option_name]) == "array")
        delete_option(ctx, section, option_name);

    delete_option(ctx, section, option_name + "_text");
    delete_option(ctx, section, option_name + "_text_mode");
}

function migrate_rule(ctx, section, converted_from_rule, constants) {
    let action = migrated_rule_action(section);
    let legacy_connection_kind = legacy_rule_connection_kind(section);
    let proxy_config_type = option(section, "proxy_config_type", "");
    let subscription_urls = option(section, "subscription_urls", "");

    if (action != "")
        set_option(ctx, section, "action", action);

    delete_option(ctx, section, "connection_type");
    delete_option(ctx, section, "subscription_group_by_countries");
    delete_option(ctx, section, "group_by_countries");
    delete_option(ctx, section, "subscription_detect_server_countries");
    delete_option(ctx, section, "subscription_insecure");
    delete_option(ctx, section, "subscription_format_preference");
    delete_option(ctx, section, "subscription_group_mode");
    delete_option(ctx, section, "subscription_group_prefix_len");
    delete_option(ctx, section, "global_proxy");

    // Migrate legacy domain_list_urls and subnet_list_urls (early Podkop)
    if (option_exists(section, "domain_list_urls")) {
        for (let entry in option_list_values(section, "domain_list_urls")) {
            entry = trim(as_string(entry));
            if (entry == "") continue;
            if (match(entry, /\.srs$/i))
                add_list_unique(ctx, section, "rule_set", entry);
            else
                add_list_unique(ctx, section, "remote_domain_lists", entry);
        }
        delete_option(ctx, section, "domain_list_urls");
    }

    if (option_exists(section, "subnet_list_urls")) {
        for (let entry in option_list_values(section, "subnet_list_urls")) {
            entry = trim(as_string(entry));
            if (entry == "") continue;
            if (match(entry, /\.srs$/i) || match(entry, /\.json$/i))
                add_list_unique(ctx, section, "rule_set_with_subnets", entry);
            else
                add_list_unique(ctx, section, "remote_subnet_lists", entry);
        }
        delete_option(ctx, section, "subnet_list_urls");
    }

    if (action == "connection") {
        migrate_urltest_filter_mode(ctx, section);
        migrate_detect_server_country(ctx, section);
        if (legacy_connection_kind == "proxy")
            migrate_proxy_rule(ctx, section, proxy_config_type);
        else {
            delete_option(ctx, section, "proxy_config_type");
            delete_option(ctx, section, "proxy_string");
            delete_option(ctx, section, "urltest_proxy_links");
            delete_option(ctx, section, "subscription_url");
            delete_option(ctx, section, "subscription_user_agent");
            delete_option(ctx, section, "urltest_check_interval_disabled");
            delete_option(ctx, section, "subscription_update_interval_disabled");
        }
        migrate_connection_section(ctx, section, constants, legacy_connection_kind);
        if (converted_from_rule && subscription_urls != "")
            delete_subscription_cache(ctx, section_name(section));
    }
    else if (action == "block" ||
        action == "bypass" || action == "zapret" || action == "zapret2" || action == "byedpi") {
        delete_option(ctx, section, "proxy_config_type");
        delete_option(ctx, section, "proxy_string");
        delete_option(ctx, section, "urltest_proxy_links");
        delete_option(ctx, section, "subscription_url");
        delete_option(ctx, section, "subscription_user_agent");
        delete_option(ctx, section, "urltest_check_interval_disabled");
        delete_option(ctx, section, "subscription_update_interval_disabled");
    }

    if (action != "connection")
        delete_legacy_urltest_options(ctx, section);

    migrate_byedpi_cmd_opts(ctx, section);
    migrate_zapret_nfqws_default(ctx, section, constants);
    migrate_ctrack_timeouts(ctx, section);
}

function migrate_rule_section(ctx, section, constants) {
    set_section_type(ctx, section, "section");
    migrate_rule(ctx, section, true, constants);
    migrate_combined_domain_conditions(ctx, section);
    migrate_text_condition(ctx, section, "ip_cidr", "subnets");
}

function migrate_list_update_enabled(ctx) {
    let settings = ctx.model.settings;
    if (option_exists(settings, "list_update_enabled")) {
        if (bool_option(settings, "list_update_enabled", true) &&
            option(settings, "update_interval", "") == "") {
            set_option(ctx, settings, "update_interval", "1d");
        }
        return;
    }

    if (option(settings, "update_interval", "") != "") {
        set_option(ctx, settings, "list_update_enabled", "1");
    }
    else {
        set_option(ctx, settings, "list_update_enabled", "0");
        set_option(ctx, settings, "update_interval", "1d");
    }
}

function normalize_existing_list_option(ctx, section, key) {
    let current = object_or_empty(section)[key];
    if (current == null)
        return;

    let values = [];
    if (type(current) == "array") {
        for (let item in current) {
            item = trim(as_string(item));
            if (item != "")
                push(values, item);
        }
    }
    else {
        let text = trim(as_string(current));
        if (text != "") {
            for (let item in split(text, /[ \t\r\n,]+/)) {
                item = trim(item);
                if (item != "")
                    push(values, item);
            }
        }
    }

    if (type(current) == "array" && length(values) == length(current))
        return;

    section[key] = values;
    record_operation(ctx, { op: "set_list", section: section_name(section), option: key, values });
}

function migrate_dns_server_lists(ctx) {
    normalize_existing_list_option(ctx, ctx.model.settings, "dns_server");
    normalize_existing_list_option(ctx, ctx.model.settings, "bootstrap_dns_server");
}

function migrate_download_via_proxy_flags(ctx) {
    let settings = ctx.model.settings;
    let legacy_section = option(settings, "download_lists_via_proxy_section", "");
    let lists_enabled = bool_option(settings, "download_lists_via_proxy", false);
    let components_enabled = option_exists(settings, "download_components_via_proxy")
        ? bool_option(settings, "download_components_via_proxy", false)
        : lists_enabled;

    set_option(ctx, settings, "download_lists_via_proxy", lists_enabled ? "1" : "0");
    if (!lists_enabled)
        delete_option(ctx, settings, "download_lists_via_proxy_section");

    set_option(ctx, settings, "download_components_via_proxy", components_enabled ? "1" : "0");
    if (components_enabled) {
        if (option(settings, "download_components_via_proxy_section", "") == "" && legacy_section != "")
            set_option(ctx, settings, "download_components_via_proxy_section", legacy_section);
    }
    else {
        delete_option(ctx, settings, "download_components_via_proxy_section");
    }
}

function migrate_subscription_download_via_proxy_settings(ctx) {
    let settings_section = ctx.model.settings;
    let enabled = bool_option(settings_section, "download_subscriptions_via_proxy", false);
    let target_section = option(settings_section, "download_lists_via_proxy_section", "");

    if (enabled && target_section != "") {
        for (let child in ctx.model.subscription_url || []) {
            let name = option(child, "section", "");
            if (name == "" || name == target_section)
                continue;
            set_option(ctx, child, "download_via_proxy_enabled", "1");
            set_option(ctx, child, "download_via_proxy_section", target_section);
        }
    }

    delete_option(ctx, settings_section, "download_subscriptions_via_proxy");
}

function migrate_rule_set_settings(ctx, section) {
    let normalize_list = function(key) {
        let seen = {};
        let result = [];
        for (let reference in option_list_values(section, key)) {
            reference = as_string(reference);
            if (reference == "" || seen[reference])
                continue;
            seen[reference] = true;
            push(result, reference);
        }
        if (length(result) > 0)
            set_list_option(ctx, section, key, result);
        else
            delete_option(ctx, section, key);
    };

    normalize_list("community_lists");
    normalize_list("rule_set");
    normalize_list("rule_set_with_subnets");
    delete_option(ctx, section, "rule_set_settings");
}

function version_parts(value) {
    let matched = match(as_string(value), /^([0-9]+)\.([0-9]+)\.([0-9]+)$/);
    if (!matched)
        return [ 0, 0, 0 ];
    return [ int(matched[1]), int(matched[2]), int(matched[3]) ];
}

function compare_versions(left, right) {
    left = version_parts(left);
    right = version_parts(right);
    for (let i = 0; i < 3; i++) {
        if (left[i] < right[i])
            return -1;
        if (left[i] > right[i])
            return 1;
    }
    return 0;
}

function release_at_most(ctx, version) {
    return compare_versions(ctx.source_release, version) <= 0;
}

function migrate_interface_sections(ctx) {
    if (!release_at_most(ctx, "1.0.1"))
        return;

    for (let section in ctx.model.sections)
        migrate_interface_item_settings(ctx, section);
}

function migrate_enable_component_checks(ctx) {
    if (!release_at_most(ctx, "1.0.1"))
        return;

    set_option(ctx, ctx.model.settings, "component_update_check_enabled", "1");
}

function migration_port(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return null;

    value = int(value);
    return value >= 1 && value <= 65535 ? value : null;
}

function unique_migration_tag(base, taken) {
    base = trim(as_string(base));
    if (base == "")
        base = "http";
    if (!taken[base])
        return base;

    for (let suffix = 1; suffix < 100000; suffix++) {
        let candidate = base + "-" + suffix;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function migrated_http_outbound(link, tag_name) {
    link = core_url.strip_fragment(core_url.decode(link));
    let scheme = core_url.scheme(link);
    if (scheme != "http" && scheme != "https")
        return null;

    let host = core_url.host(link);
    let port = migration_port(core_url.port(link));
    let path = core_url.path(link);
    if (host == "" || port == null || (path != "" && path != "/") || index(link, "?") >= 0)
        return null;

    let outbound = {
        type: "http",
        tag: tag_name,
        server: host,
        server_port: port
    };
    let userinfo = core_url.userinfo(link);
    if (userinfo != "") {
        let colon = index(userinfo, ":");
        outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
        if (colon >= 0)
            outbound.password = substr(userinfo, colon + 1);
    }
    if (scheme == "https")
        outbound.tls = { enabled: true };
    return outbound;
}

function migrate_http_connection_urls(ctx) {
    if (!release_at_most(ctx, "1.0.4"))
        return;

    for (let section in ctx.model.sections) {
        let existing_jsons = option_list_values(section, "outbound_jsons");
        let taken = {};
        for (let value in existing_jsons) {
            try {
                let outbound = json(value);
                let tag_name = type(outbound) == "object" ? trim(as_string(outbound.tag || "")) : "";
                if (tag_name != "")
                    taken[tag_name] = true;
            }
            catch (e) {
                // Same as above: an unparseable entry owns no tag, so it
                // cannot collide with the one being generated.
            }
        }

        let remaining_links = [];
        let migrated_jsons = [];
        for (let link in option_list_values(section, "selector_proxy_links")) {
            let tag_name = unique_migration_tag(core_url.fragment(link), taken);
            let outbound = migrated_http_outbound(link, tag_name);
            if (outbound == null) {
                push(remaining_links, link);
                continue;
            }

            taken[tag_name] = true;
            push(migrated_jsons, sprintf("%J", outbound));
        }

        if (length(migrated_jsons) == 0)
            continue;

        if (length(remaining_links) > 0)
            set_list_option(ctx, section, "selector_proxy_links", remaining_links);
        else
            delete_option(ctx, section, "selector_proxy_links");

        for (let value in existing_jsons)
            push(migrated_jsons, value);
        set_list_option(ctx, section, "outbound_jsons", migrated_jsons);
    }
}

// Ensure both main and bootstrap DNS server lists have at least one entry.
// forkop/podkop did not require bootstrap_dns_server, so it is often absent after
// migration. The validator refuses to start Tachyon when either list is empty.
// The default "77.88.8.8" matches the runtime fallback in singbox/dns.uc.
function migrate_ensure_dns_server_defaults(ctx) {
    let settings = ctx.model.settings;
    let dns_server = list_option(settings, "dns_server");
    let has_dns = false;
    for (let v in dns_server) {
        if (as_string(v) != "") {
            has_dns = true;
            break;
        }
    }
    if (!has_dns)
        set_list_option(ctx, settings, "dns_server", [ "77.88.8.8" ]);

    let bootstrap = list_option(settings, "bootstrap_dns_server");
    let has_bootstrap = false;
    for (let v in bootstrap) {
        if (as_string(v) != "") {
            has_bootstrap = true;
            break;
        }
    }
    if (!has_bootstrap)
        set_list_option(ctx, settings, "bootstrap_dns_server", [ "77.88.8.8" ]);
}

// Record that this configuration targets steer spec v2, and say so once if the
// installed steer cannot read it.
//
// No UCI data is rewritten here, and that is the finding rather than an
// omission: contract-v1's `prefer`, `latency_interval_s` and
// `latency_tolerance_ms` were never stored. They were computed at generate time
// from the `config urltest` child options, which are still named the same and
// now feed a v2 `pick: latency` group. So the options carry over untouched and
// anything that renamed them would have broken sing-box as well.
//
// What genuinely does not carry over is the kernel. Spec v2 is a different
// document, only steer 2.0+ reads it, and the failure is a refusal rather than a
// degradation - so an upgrading router on a 1.x steer is told here rather than
// discovering it when the proxy refuses to come up.
function migrate_steer_spec_v2(ctx) {
    let settings = ctx.model.settings;
    set_option(ctx, settings, "steer_spec_format", "2");

    let engine_id = as_string(option(settings, "engine", ""));
    if (engine_id != "steer" && engine_id != "steer-extended")
        return;

    let engine = null;
    try {
        engine = require("core.engine");
    }
    catch (e) {
        return;
    }
    if (engine == null || !engine.binary_present(engine.ENGINE_STEER))
        return;

    if (engine.steer_supports_spec_v2())
        return;

    let parts = engine.steer_version_parts();
    warn("Tachyon now writes steer spec v2, which needs steer 2.0 or newer" +
        (parts != null ? " (installed: " + as_string(parts[0]) + "." + as_string(parts[1]) +
            "." + as_string(parts[2]) + ")" : " (installed version could not be read)") +
        ". Update steer before switching to it, or stay on sing-box.\n");
}

function migrate_dns_hosts_to_option(ctx) {
    let raw = object_or_empty(ctx.model.settings)["dns_hosts"];
    if (raw == null)
        return;

    if (type(raw) != "array")
        return;

    let entries = [];
    for (let value in raw) {
        value = as_string(value);
        if (value != "")
            push(entries, value);
    }

    if (length(entries) == 0) {
        delete_option(ctx, ctx.model.settings, "dns_hosts");
        return;
    }

    set_option(ctx, ctx.model.settings, "dns_hosts", join("\n", entries));
}

function migrate_global_hosts_to_section(ctx) {
    let settings = object_or_empty(ctx.model.settings);
    let has_urls = option_exists(settings, "hosts_list_urls");
    let has_disabled = option_exists(settings, "hosts_list_disabled");
    let has_auto_update = option_exists(settings, "hosts_list_auto_update");
    let has_update_interval = option_exists(settings, "hosts_list_update_interval");
    let has_dns_hosts = option_exists(settings, "dns_hosts");

    if (!has_urls && !has_disabled && !has_auto_update && !has_update_interval && !has_dns_hosts)
        return;

    let already_migrated = false;
    for (let section in ctx.model.sections) {
        if (option(section, "action", "") == "hosts") {
            already_migrated = true;
            break;
        }
    }
    if (already_migrated) {
        delete_option(ctx, ctx.model.settings, "hosts_list_urls");
        delete_option(ctx, ctx.model.settings, "hosts_list_disabled");
        delete_option(ctx, ctx.model.settings, "hosts_list_auto_update");
        delete_option(ctx, ctx.model.settings, "hosts_list_update_interval");
        return;
    }

    let hosts_section_name = "hosts";
    let hosts_section = { ".name": hosts_section_name, ".type": "section" };

    record_operation(ctx, { op: "create", section: hosts_section_name, type: "section", anonymous: false });

    set_option(ctx, hosts_section, "label", "Hosts");
    set_option(ctx, hosts_section, "enabled", "1");
    set_option(ctx, hosts_section, "action", "hosts");

    if (has_urls) {
        let urls = list_option(settings, "hosts_list_urls");
        if (length(urls) > 0)
            set_list_option(ctx, hosts_section, "hosts_list_urls", urls);
        delete_option(ctx, ctx.model.settings, "hosts_list_urls");
    }
    if (has_disabled) {
        let disabled = list_option(settings, "hosts_list_disabled");
        if (length(disabled) > 0)
            set_list_option(ctx, hosts_section, "hosts_list_disabled", disabled);
        delete_option(ctx, ctx.model.settings, "hosts_list_disabled");
    }
    if (has_auto_update) {
        set_option(ctx, hosts_section, "hosts_list_auto_update", option(settings, "hosts_list_auto_update", "0"));
        delete_option(ctx, ctx.model.settings, "hosts_list_auto_update");
    }
    if (has_update_interval) {
        set_option(ctx, hosts_section, "hosts_list_update_interval", option(settings, "hosts_list_update_interval", "24h"));
        delete_option(ctx, ctx.model.settings, "hosts_list_update_interval");
    }
    if (has_dns_hosts) {
        set_option(ctx, hosts_section, "dns_hosts", option(settings, "dns_hosts", ""));
        delete_option(ctx, ctx.model.settings, "dns_hosts");
    }
}

function migrate_orphan_section_interfaces(ctx) {
    // Deleting a routing section used to leave its child records
    // (subscription_url, section_interface, urltest, priority_group, priority_level)
    // behind. A parent-less record never matches any section during
    // config generation - dead weight that only confuses config readers.
    let owners = {};
    for (let section in ctx.model.sections)
        owners[section_name(section)] = true;

    let group_owners = {};
    for (let group in ctx.model.priority_group || [])
        group_owners[section_name(group)] = true;

    let child_types = [ "subscription_url", "section_interface", "urltest", "priority_group", "priority_level" ];
    for (let type_name in child_types) {
        let kept = [];
        let changed = false;
        for (let child in ctx.model[type_name] || []) {
            let owner = option(child, "section", "");
            let group = option(child, "group", "");
            let is_orphan = false;
            if (owner != "" && !owners[owner])
                is_orphan = true;
            if (type_name == "priority_level" && group != "" && !group_owners[group])
                is_orphan = true;

            if (is_orphan) {
                record_operation(ctx, { op: "delete_section", section: section_name(child) });
                changed = true;
                continue;
            }
            push(kept, child);
        }
        if (changed)
            ctx.model[type_name] = kept;
    }
}
function migrate_cleanup_accidental_full_domain_prefixes(ctx) {
    let targets = [];
    for (let s in ctx.model.sections) push(targets, s);
    for (let r in ctx.model.rules) push(targets, r);

    for (let section in targets) {
        for (let opt_name in [ "domain", "user_domains" ]) {
            let domain_val = section[opt_name];
            if (domain_val == null)
                continue;
            let was_array = type(domain_val) == "array";
            let raw_items = was_array ? domain_val : split(as_string(domain_val), "\n");
            let changed = was_array;
            let new_lines = [];
            let seen = {};
            for (let line in raw_items) {
                line = trim(as_string(line));
                if (line == "")
                    continue;
                if (index(line, ",") >= 0) {
                    for (let sub in text_list_values(line, "comma-space")) {
                        sub = trim(sub);
                        if (sub == "") continue;
                        if (substr(sub, 0, 5) == "full:") {
                            let rest = trim(substr(sub, 5));
                            if (rest != "" && domain_config.suffix_to_ascii(rest) != null)
                                sub = rest;
                        }
                        if (!seen[sub]) {
                            seen[sub] = true;
                            push(new_lines, sub);
                        }
                        changed = true;
                    }
                    continue;
                }
                if (substr(line, 0, 5) == "full:") {
                    let rest = trim(substr(line, 5));
                    if (rest != "" && domain_config.suffix_to_ascii(rest) != null) {
                        line = rest;
                        changed = true;
                    }
                }
                if (!seen[line]) {
                    seen[line] = true;
                    push(new_lines, line);
                }
            }
            if (changed) {
                if (was_array)
                    delete_option(ctx, section, opt_name);
                set_option(ctx, section, opt_name, join("\n", new_lines));
            }
        }
    }
}

/// The engine became a product of its own: binary, service, config directory
/// and UCI package all carry `tachyon-core` now. An upgrade from the previous
/// release has to land on the new names without losing the running config, so
/// this migration rewrites what UCI stores, moves the config file when the new
/// path is still empty, and leaves the old file in place — a downgrade still
/// finds a working setup.
function migrate_engine_identity(ctx) {
    let settings = object_or_empty(object_or_empty(ctx.model).settings);
    const OLD_CONFIG_DIR = "/etc/sing-box";
    const NEW_CONFIG_DIR = "/etc/tachyon-core";
    const OLD_TMP_DIR = "/tmp/sing-box";
    const NEW_TMP_DIR = "/tmp/tachyon-core";
    const OLD_SHARE_DIR = "/usr/share/sing-box";
    const NEW_SHARE_DIR = "/usr/share/tachyon-core";

    if (option(settings, "engine", "") == "sing-box")
        set_option(ctx, settings, "engine", "tachyon-core");
    if (option(settings, "engine_previous", "") == "sing-box")
        set_option(ctx, settings, "engine_previous", "tachyon-core");

    for (let key in [ "config_path", "cache_path" ]) {
        if (!option_exists(settings, key))
            continue;
        let value = option(settings, key, "");
        let updated = "";
        if (key == "cache_path" && (value == "/tmp/sing-box/cache.db" ||
                                    value == "/tmp/tachyon-core/cache.db" ||
                                    value == "/usr/share/sing-box/cache.db")) {
            updated = NEW_SHARE_DIR + "/cache.db";
        }
        else if (index(value, OLD_CONFIG_DIR + "/") == 0) {
            updated = NEW_CONFIG_DIR + "/" + substr(value, length(OLD_CONFIG_DIR + "/"));
        }
        else if (index(value, OLD_SHARE_DIR + "/") == 0) {
            updated = NEW_SHARE_DIR + "/" + substr(value, length(OLD_SHARE_DIR + "/"));
        }
        else if (index(value, OLD_TMP_DIR + "/") == 0) {
            updated = NEW_TMP_DIR + "/" + substr(value, length(OLD_TMP_DIR + "/"));
        }
        if (updated == "" || updated == value)
            continue;
        // the file itself follows the option, so an upgrade keeps the proxy's
        // own configuration instead of silently starting from an empty one
        if (fs.stat(updated) == null && fs.stat(value) != null) {
            let slash = rindex(updated, "/");
            if (slash > 0) {
                let dir = substr(updated, 0, slash);
                try {
                    fs.mkdir(dir, 0755);
                }
                catch (e) {
                }
            }
            let moved = false;
            try {
                moved = fs.rename(value, updated) == true;
            }
            catch (e) {
            }
            if (!moved) {
                try {
                    let raw = fs.readfile(value);
                    if (raw != null && fs.writefile(updated, raw) != null)
                        fs.unlink(value);
                }
                catch (e) {
                }
            }
        }
        set_option(ctx, settings, key, updated);
    }

    // the engine's own UCI package
    if (uci_core.exists("sing-box.main") && !uci_core.exists("tachyon-core.main")) {
        uci_core.rename_package("sing-box", "tachyon-core");
        uci_core.commit("tachyon-core");
    }

    // the managed init script reads conffile and workdir from the engine
    // package, so a renamed package carrying the old paths would start the
    // core on a file this migration just moved away
    if (uci_core.exists("tachyon-core.main")) {
        for (let pair in [
            [ "conffile", OLD_CONFIG_DIR + "/", NEW_CONFIG_DIR + "/" ],
            [ "workdir", "/usr/share/sing-box", "/usr/share/tachyon-core" ]
        ]) {
            let value = uci_core.get("tachyon-core", "main", pair[0]);
            if (value == "" || index(value, pair[1]) != 0)
                continue;
            uci_core.set("tachyon-core", "main", pair[0], pair[2] + substr(value, length(pair[1])));
        }
        uci_core.commit("tachyon-core");
    }

    // the variant and version markers decide what the UI shows and which
    // engine the config generator targets; losing them would make a working
    // install look like it has no core at all
    for (let pair in [
        [ "/etc/tachyon/sing-box-variant", "/etc/tachyon/tachyon-core-variant" ],
        [ "/etc/tachyon/sing-box-version", "/etc/tachyon/tachyon-core-version" ]
    ]) {
        if (fs.stat(pair[1]) == null && fs.stat(pair[0]) != null) {
            try {
                fs.rename(pair[0], pair[1]);
            }
            catch (e) {
            }
        }
    }

    // create compatibility symlink if sing-box exists and tachyon-core does not
    if (fs.stat("/usr/bin/sing-box") != null && fs.stat("/usr/bin/tachyon-core") == null) {
        try { fs.unlink("/usr/bin/tachyon-core"); } catch (e) {}
        try { fs.symlink("/usr/bin/sing-box", "/usr/bin/tachyon-core"); } catch (e) {}
        if (fs.stat("/usr/bin/tachyon-core") == null)
            run("ln -sf /usr/bin/sing-box /usr/bin/tachyon-core >/dev/null 2>&1");
    }
}

function sanitize_uci_id(raw) {
    let clean = replace(as_string(raw), /[^A-Za-z0-9_]/g, "_");
    clean = replace(clean, /^_+/, "");
    clean = replace(clean, /_+$/, "");
    return clean != "" ? clean : "item";
}

function condition_list_tokens(section, key) {
    let raw = object_or_empty(section)[key];
    if (raw == null)
        return [];
    let lines = type(raw) == "array" ? raw : split(as_string(raw), /[\r\n]+/);
    let out = [];
    for (let line in lines) {
        line = replace(as_string(line), /(^|[ \t]+)\/\/.*$/, "");
        line = replace(line, /(^|[ \t]+)#.*$/, "");
        line = trim(line);
        if (line == "")
            continue;
        for (let tok in split(line, /[ \t,]+/)) {
            tok = trim(as_string(tok));
            if (tok != "")
                push(out, tok);
        }
    }
    return out;
}

function migrate_modular_entities_v1(ctx) {
    let condition_list_keys = [
        "community_lists",
        "rule_set",
        "rule_set_with_subnets",
        "domain_ip_lists",
        "domain_suffix",
        "domain_keyword",
        "domain_regex",
        "user_domains",
        "ip_cidr",
        "source_ip_cidr",
        "source_macs",
        "ports",
        "protocol",
        "dscp",
        "geoip_country",
        "fully_routed_ips"
    ];
    let condition_scalar_keys = [
        "domain",
        "domain_text",
        "domain_suffix_text",
        "domain_keyword_text",
        "domain_regex_text",
        "user_domains_text",
        "ip_cidr_text",
        "source_ip_cidr_text",
        "ports_text",
        "geoip_mode"
    ];

    let sub_source_by_url = {};
    let sub_index = 0;
    for (let existing_src in (ctx.model.outbound_source || [])) {
        let u = trim(option(existing_src, "url", ""));
        if (u != "")
            sub_source_by_url[u] = section_name(existing_src);
    }

    for (let section in (ctx.model.sections || [])) {
        let sname = section_name(section);
        if (sname == "")
            continue;
        let safe_sname = sanitize_uci_id(sname);
        let sec_action = lc(trim(option(section, "action", "")));

        // 1. Extract inline routing conditions into a reusable condition entity
        if (length(list_option(section, "condition_refs")) == 0) {
            let has_cond = false;
            for (let k in condition_list_keys) {
                if (length(condition_list_tokens(section, k)) > 0) {
                    has_cond = true;
                    break;
                }
            }
            if (!has_cond) {
                for (let k in condition_scalar_keys) {
                    if (trim(option(section, k, "")) != "") {
                        has_cond = true;
                        break;
                    }
                }
            }
            if (has_cond) {
                let cond_id = "cond_" + safe_sname;
                let cond = create_named_section(ctx, "condition", cond_id);
                set_option_if_missing(ctx, cond, "enabled", "1");
                set_option_if_missing(ctx, cond, "name", option(section, "name", sname));
                set_option_if_missing(ctx, cond, "condition_type", "atomic");
                for (let k in condition_list_keys) {
                    let vals = condition_list_tokens(section, k);
                    if (length(vals) > 0)
                        set_list_option(ctx, cond, k, vals);
                }
                for (let k in condition_scalar_keys) {
                    let val = trim(option(section, k, ""));
                    if (val != "")
                        set_option(ctx, cond, k, val);
                }
                add_list_unique(ctx, section, "condition_refs", cond_id);
            }
        }

        // 2. Extract subscription_url children into deduplicated outbound_source entities
        for (let sub in (ctx.model.subscription_url || [])) {
            if (option(sub, "section", "") != sname)
                continue;
            let url = trim(option(sub, "url", ""));
            if (url == "")
                continue;
            let src_id = sub_source_by_url[url];
            if (src_id == null || src_id == "") {
                sub_index++;
                src_id = "src_sub_" + sub_index;
                sub_source_by_url[url] = src_id;
                let src = create_named_section(ctx, "outbound_source", src_id);
                set_option_if_missing(ctx, src, "enabled", "1");
                set_option_if_missing(ctx, src, "name", option(sub, "node_prefix", "") != "" ? option(sub, "node_prefix", "") : ("Subscription " + sub_index));
                set_option_if_missing(ctx, src, "source_type", "subscription");
                set_option(ctx, src, "url", url);
                for (let sk in [
                    "user_agent", "auto_user_agent", "hwid", "auto_hwid",
                    "prefix_nodes", "node_prefix", "include_urltest_groups",
                    "hide_urltest_group_outbounds", "hide_detour_outbounds",
                    "subscription_update_enabled", "subscription_update_interval",
                    "download_via_proxy_enabled", "download_via_proxy_section"
                ]) {
                    let sval = option(sub, sk, "");
                    if (sval != "")
                        set_option(ctx, src, sk, sval);
                }
            }
            add_list_unique(ctx, section, "outbound_source_refs", src_id);
        }

        // 2b. Extract other connection types (fptn, proxy_links, amnezia_config, awg, interface, outbound_json) into outbound_source
        let sec_display_name = option(section, "name", sname);
        let fptn_token = trim(option(section, "access_token", ""));
        if (fptn_token != "") {
            let fptn_src_id = "src_fptn_" + safe_sname;
            let fptn_src = create_named_section(ctx, "outbound_source", fptn_src_id);
            set_option_if_missing(ctx, fptn_src, "enabled", "1");
            set_option_if_missing(ctx, fptn_src, "name", sec_display_name);
            set_option_if_missing(ctx, fptn_src, "source_type", "fptn");
            set_option_if_missing(ctx, fptn_src, "access_token", fptn_token);
            add_list_unique(ctx, section, "outbound_source_refs", fptn_src_id);
        }

        let sec_links = list_option(section, "selector_proxy_links");
        let sec_links_text = trim(option(section, "selector_proxy_links_text", ""));
        if (length(sec_links) > 0 || sec_links_text != "") {
            let links_src_id = "src_links_" + safe_sname;
            let links_src = create_named_section(ctx, "outbound_source", links_src_id);
            set_option_if_missing(ctx, links_src, "enabled", "1");
            set_option_if_missing(ctx, links_src, "name", sec_display_name + " (Links)");
            set_option_if_missing(ctx, links_src, "source_type", "proxy_links");
            if (length(sec_links) > 0 && !option_exists(links_src, "proxy_links"))
                set_list_option(ctx, links_src, "proxy_links", sec_links);
            if (sec_links_text != "")
                set_option_if_missing(ctx, links_src, "proxy_links_text", sec_links_text);
            add_list_unique(ctx, section, "outbound_source_refs", links_src_id);
        }

        let sec_amnezia = list_option(section, "selector_amnezia_configs");
        if (length(sec_amnezia) == 0)
            sec_amnezia = list_option(section, "amnezia_configs");
        let sec_amnezia_text = trim(option(section, "amnezia_conf_text", ""));
        if (length(sec_amnezia) > 0 || sec_amnezia_text != "") {
            let amn_src_id = "src_amnezia_" + safe_sname;
            let amn_src = create_named_section(ctx, "outbound_source", amn_src_id);
            set_option_if_missing(ctx, amn_src, "enabled", "1");
            set_option_if_missing(ctx, amn_src, "name", sec_display_name + " (Amnezia)");
            set_option_if_missing(ctx, amn_src, "source_type", "amnezia_config");
            if (length(sec_amnezia) > 0 && !option_exists(amn_src, "amnezia_configs"))
                set_list_option(ctx, amn_src, "amnezia_configs", sec_amnezia);
            if (sec_amnezia_text != "")
                set_option_if_missing(ctx, amn_src, "amnezia_conf_text", sec_amnezia_text);
            add_list_unique(ctx, section, "outbound_source_refs", amn_src_id);
        }

        if (sec_action == "awg" || (trim(option(section, "awg_private_key", "")) != "" && trim(option(section, "awg_server_address", "")) != "")) {
            let awg_src_id = "src_awg_" + safe_sname;
            let awg_src = create_named_section(ctx, "outbound_source", awg_src_id);
            set_option_if_missing(ctx, awg_src, "enabled", "1");
            set_option_if_missing(ctx, awg_src, "name", sec_display_name + " (AWG)");
            set_option_if_missing(ctx, awg_src, "source_type", "awg");
            for (let ak in [
                "awg_private_key", "awg_server_address", "awg_server_port",
                "awg_peer_public_key", "awg_preshared_key", "awg_mtu", "awg_keepalive",
                "awg_jc", "awg_jmin", "awg_jmax", "awg_s1", "awg_s2",
                "awg_h1", "awg_h2", "awg_h3", "awg_h4"
            ]) {
                let aval = trim(option(section, ak, ""));
                if (aval != "")
                    set_option_if_missing(ctx, awg_src, ak, aval);
            }
            let awg_addrs = list_option(section, "awg_local_address");
            if (length(awg_addrs) > 0 && !option_exists(awg_src, "awg_local_address"))
                set_list_option(ctx, awg_src, "awg_local_address", awg_addrs);
            add_list_unique(ctx, section, "outbound_source_refs", awg_src_id);
        }

        for (let sif in (ctx.model.section_interface || [])) {
            if (option(sif, "section", "") != sname)
                continue;
            let iname = trim(option(sif, "name", ""));
            if (iname == "")
                continue;
            let iface_src_id = "src_iface_" + sanitize_uci_id(iname);
            let iface_src = create_named_section(ctx, "outbound_source", iface_src_id);
            set_option_if_missing(ctx, iface_src, "enabled", "1");
            set_option_if_missing(ctx, iface_src, "name", "Interface " + iname);
            set_option_if_missing(ctx, iface_src, "source_type", "interface");
            set_option_if_missing(ctx, iface_src, "interface_name", iname);
            for (let ik in [ "domain_resolver_enabled", "domain_resolver_dns_type", "domain_resolver_dns_server" ]) {
                let ival = trim(option(sif, ik, ""));
                if (ival != "")
                    set_option_if_missing(ctx, iface_src, ik, ival);
            }
            add_list_unique(ctx, section, "outbound_source_refs", iface_src_id);
        }

        let direct_ifaces = list_option(section, "interfaces");
        let single_iface = trim(option(section, "interface", ""));
        if (single_iface != "" && index(direct_ifaces, single_iface) < 0)
            push(direct_ifaces, single_iface);
        for (let iname in direct_ifaces) {
            iname = trim(as_string(iname));
            if (iname == "")
                continue;
            let iface_src_id = "src_iface_" + sanitize_uci_id(iname);
            let iface_src = create_named_section(ctx, "outbound_source", iface_src_id);
            set_option_if_missing(ctx, iface_src, "enabled", "1");
            set_option_if_missing(ctx, iface_src, "name", "Interface " + iname);
            set_option_if_missing(ctx, iface_src, "source_type", "interface");
            set_option_if_missing(ctx, iface_src, "interface_name", iname);
            add_list_unique(ctx, section, "outbound_source_refs", iface_src_id);
        }

        let sec_jsons = list_option(section, "outbound_jsons");
        let sec_json_single = trim(option(section, "outbound_json", ""));
        if (length(sec_jsons) > 0 || sec_json_single != "") {
            let json_src_id = "src_json_" + safe_sname;
            let json_src = create_named_section(ctx, "outbound_source", json_src_id);
            set_option_if_missing(ctx, json_src, "enabled", "1");
            set_option_if_missing(ctx, json_src, "name", sec_display_name + " (JSON)");
            set_option_if_missing(ctx, json_src, "source_type", "outbound_json");
            if (length(sec_jsons) > 0 && !option_exists(json_src, "outbound_jsons"))
                set_list_option(ctx, json_src, "outbound_jsons", sec_jsons);
            if (sec_json_single != "")
                set_option_if_missing(ctx, json_src, "outbound_json", sec_json_single);
            add_list_unique(ctx, section, "outbound_source_refs", json_src_id);
        }

        let single_proto_actions = [
            "anytls", "naive", "mieru", "snell", "sudoku", "masque", "tewfai",
            "trusttunnel", "openconnect", "shadowtls", "warp", "openvpn", "tailscale", "tor", "desync",
            "zapret2", "zapret", "byedpi", "wdtt", "olcrtc"
        ];
        if (index(single_proto_actions, sec_action) >= 0) {
            let proto_src_id = "src_" + sanitize_uci_id(sec_action) + "_" + safe_sname;
            let proto_src = create_named_section(ctx, "outbound_source", proto_src_id);
            set_option_if_missing(ctx, proto_src, "enabled", "1");
            set_option_if_missing(ctx, proto_src, "name", sec_display_name);
            set_option_if_missing(ctx, proto_src, "source_type", sec_action);
            for (let pk, pval in section) {
                if (substr(pk, 0, 1) == "." || pk == "enabled" || pk == "name" || pk == "action" ||
                    pk == "condition_refs" || pk == "outbound_source_refs" || pk == "outbound_group_refs" || pk == "balancer_refs" ||
                    index(condition_list_keys, pk) >= 0 || index(condition_scalar_keys, pk) >= 0)
                    continue;
                if (type(pval) == "array") {
                    if (length(pval) > 0 && !option_exists(proto_src, pk))
                        set_list_option(ctx, proto_src, pk, pval);
                } else {
                    let s_pval = trim(as_string(pval));
                    if (s_pval != "")
                        set_option_if_missing(ctx, proto_src, pk, s_pval);
                }
            }
            add_list_unique(ctx, section, "outbound_source_refs", proto_src_id);
        }

        // 3. Extract urltest & priority_group children into reusable balancer entities
        for (let ut in (ctx.model.urltest || [])) {
            if (option(ut, "section", "") != sname)
                continue;
            let ut_id = section_name(ut);
            let ut_name = option(ut, "name", "Fastest");
            let existing_bal = null;
            for (let b in (ctx.model.balancer || [])) {
                if (option(b, "name", "") == ut_name && lc(option(b, "balancer_type", "urltest")) == "urltest") {
                    existing_bal = b;
                    break;
                }
            }
            let name_slug = sanitize_uci_id(option(ut, "name", ut_id));
            if (name_slug == "item" && option(ut, "name", ut_id) != "item")
                name_slug = sanitize_uci_id(ut_id);
            let bal_id = existing_bal != null ? section_name(existing_bal) : ("bal_" + sanitize_uci_id(sname + "_" + name_slug));
            let bal = existing_bal != null ? existing_bal : create_named_section(ctx, "balancer", bal_id);
            set_option_if_missing(ctx, bal, "enabled", "1");
            set_option_if_missing(ctx, bal, "balancer_type", "urltest");
            set_option_if_missing(ctx, bal, "name", ut_name);
            for (let bk in [
                "testing_url", "check_interval", "tolerance", "idle_timeout",
                "interrupt_exist_connections", "pin_dashboard",
                "mode", "sticky_hash", "passive_check",
                "filter_mode", "detect_server_country",
                "include_proxy_parameters", "exclude_proxy_parameters"
            ]) {
                let bval = option(ut, bk, "");
                if (bval != "")
                    set_option_if_missing(ctx, bal, bk, bval);
            }
            for (let lk in [
                "include_prefixes", "exclude_prefixes",
                "include_countries", "exclude_countries",
                "include_outbounds", "exclude_outbounds",
                "include_regex", "exclude_regex",
                "include_protocols", "exclude_protocols",
                "include_transports", "exclude_transports",
                "include_securities", "exclude_securities",
                "include_ports", "exclude_ports"
            ]) {
                let lvals = list_option(ut, lk);
                if (length(lvals) > 0 && !option_exists(bal, lk))
                    set_list_option(ctx, bal, lk, lvals);
            }
            add_list_unique(ctx, section, "balancer_refs", bal_id);
        }

        for (let pg in (ctx.model.priority_group || [])) {
            if (option(pg, "section", "") != sname)
                continue;
            let pg_id = section_name(pg);
            let pg_name = option(pg, "name", pg_id);
            let existing_bal = null;
            for (let b in (ctx.model.balancer || [])) {
                if (option(b, "name", "") == pg_name && lc(option(b, "balancer_type", "urltest")) == "priority") {
                    existing_bal = b;
                    break;
                }
            }
            let name_slug = sanitize_uci_id(pg_name);
            if (name_slug == "item" && pg_name != "item")
                name_slug = sanitize_uci_id(pg_id);
            let bal_id = existing_bal != null ? section_name(existing_bal) : ("bal_" + sanitize_uci_id(sname + "_" + name_slug));
            let bal = existing_bal != null ? existing_bal : create_named_section(ctx, "balancer", bal_id);
            set_option_if_missing(ctx, bal, "enabled", "1");
            set_option_if_missing(ctx, bal, "balancer_type", "priority");
            set_option_if_missing(ctx, bal, "name", pg_name);
            for (let bk in [ "health_url", "active_check_interval", "check_timeout", "recovery_check_interval", "pick_fastest", "switch_to_faster_same_priority", "fastest_check_interval", "pin_dashboard" ]) {
                let bval = option(pg, bk, "");
                if (bval != "")
                    set_option_if_missing(ctx, bal, bk, bval);
            }
            add_list_unique(ctx, section, "balancer_refs", bal_id);
        }

        let sec_src_refs = list_option(section, "outbound_source_refs");
        if (length(sec_src_refs) > 0) {
            for (let b_ref in list_option(section, "balancer_refs")) {
                for (let b_obj in (ctx.model.balancer || [])) {
                    if (section_name(b_obj) == b_ref && length(list_option(b_obj, "source_refs")) == 0) {
                        for (let s_ref in sec_src_refs) {
                            if (index(s_ref, "src_zapret") == 0 || index(s_ref, "src_byedpi") == 0 || index(s_ref, "src_desync") == 0)
                                continue;
                            add_list_unique(ctx, b_obj, "source_refs", s_ref);
                        }
                    }
                }
            }
        }

        if (sec_action != "" && sec_action != "connection" && sec_action != "bypass" && sec_action != "block" && sec_action != "dns" && sec_action != "hosts") {
            set_option(ctx, section, "action", "connection");
        }
    }
}

const MIGRATIONS = [
    { id: "interface_sections", run: migrate_interface_sections },
    { id: "enable_component_checks", run: migrate_enable_component_checks },
    { id: "http_connection_urls", run: migrate_http_connection_urls },
    { id: "dns_hosts_to_option", run: migrate_dns_hosts_to_option },
    { id: "steer_spec_v2", run: migrate_steer_spec_v2 },
    { id: "global_hosts_to_section", run: migrate_global_hosts_to_section },
    { id: "orphan_section_interface_cleanup", run: migrate_orphan_section_interfaces },
    { id: "ensure_dns_server_defaults", run: migrate_ensure_dns_server_defaults },
    { id: "engine_identity_tachyon_core", run: migrate_engine_identity },
    { id: "modular_entities_v1", run: migrate_modular_entities_v1 }
];



function apply_migrations(ctx) {
    ctx.source_release = option(ctx.model.settings, CONFIG_VERSION_OPTION, "");

    let applied = [];
    let seen = {};
    let added = false;
    for (let id in list_option(ctx.model.settings, APPLIED_MIGRATIONS_OPTION)) {
        id = as_string(id);
        if (id == "" || seen[id])
            continue;
        seen[id] = true;
        push(applied, id);
    }

    for (let migration in MIGRATIONS) {
        if (seen[migration.id])
            continue;

        try {
            migration.run(ctx);
        } catch(e) {
            warn("Migration '" + migration.id + "' failed: " + as_string(e) + "\n");
            continue;
        }
        seen[migration.id] = true;
        push(applied, migration.id);
        added = true;
    }

    if (added)
        set_list_option(ctx, ctx.model.settings, APPLIED_MIGRATIONS_OPTION, applied);

    if (release_at_most(ctx, "1.0.4"))
        set_option(ctx, ctx.model.settings, CONFIG_VERSION_OPTION, "1.0.5");
}

function migrate_podkop_model(model, constants) {
    let ctx = migration_context(model);
    constants = object_or_empty(constants);

    delete_option(ctx, model.settings, "routing_excluded_ips");

    // NetShift: dns_via_outbound and dns_outbound_section
    if (bool_option(model.settings, "dns_via_outbound", false)) {
        set_option_if_missing(ctx, model.settings, "dns_detour_enabled", "1");
        let detour_sec = option(model.settings, "dns_outbound_section", "");
        if (detour_sec != "")
            set_option_if_missing(ctx, model.settings, "dns_detour_section", detour_sec);
    }
    delete_option(ctx, model.settings, "dns_via_outbound");
    delete_option(ctx, model.settings, "dns_outbound_section");
    delete_option(ctx, model.settings, "block_doh");
    delete_option(ctx, model.settings, "enable_ipv6");

    migrate_dns_server_lists(ctx);
    migrate_list_update_enabled(ctx);

    let converted_sections = [];
    for (let section in model.rules) {
        migrate_rule_section(ctx, section, constants);
        push(converted_sections, section);
    }
    model.rules = [];

    for (let section in model.sections) {
        migrate_rule(ctx, section, false, constants);
        migrate_combined_domain_conditions(ctx, section);
        migrate_text_condition(ctx, section, "ip_cidr", "subnets");
        migrate_rule_set_settings(ctx, section);
    }
    for (let section in converted_sections) {
        migrate_rule_set_settings(ctx, section);
        push(model.sections, section);
    }
    migrate_subscription_download_via_proxy_settings(ctx);
    migrate_download_via_proxy_flags(ctx);
    apply_migrations(ctx);

    return ctx;
}

function migrate_tachyon_model(model) {
    let ctx = migration_context(model);
    migrate_cleanup_accidental_full_domain_prefixes(ctx);
    apply_migrations(ctx);
    migrate_modular_entities_v1(ctx);
    // How client traffic reaches the proxy. Defaulted rather than left absent:
    // the generator has to be able to express a legal config for a router that
    // predates this option, and "no proxy_mode" would have to be read as tproxy
    // in every caller - one of them forgetting is a silent mode switch.
    set_option_if_missing(ctx, ctx.model.settings, "proxy_mode", "tproxy");
    set_option_if_missing(ctx, ctx.model.settings, "tun_interface", "tun0");
    set_option_if_missing(ctx, ctx.model.settings, "tun_inet4", "172.19.0.1/30");
    set_option_if_missing(ctx, ctx.model.settings, "tun_mtu", "9000");
    return ctx;
}

// Runtime UCI adapter and external command dispatcher.
function first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function ensure_dir(path) {
    run("mkdir -p " + shell_quote(path) + " >/dev/null 2>&1");
}

function clear_subscription_runtime_cache() {
    run("rm -rf " +
        shell_quote(TMP_SUBSCRIPTION_FOLDER) + " " +
        shell_quote(TACHYON_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(TACHYON_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(TACHYON_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(TACHYON_SECTION_CACHE_DIR));
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(TACHYON_RUNTIME_STATE_DIR);
    ensure_dir(TACHYON_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(TACHYON_OUTBOUND_METADATA_DIR);
    ensure_dir(TACHYON_SECTION_CACHE_DIR);
}

function write_cache_format_file(path, format) {
    let tmp = path + ".tmp";
    if (fs.writefile(tmp, format + "\n") == null)
        return null;
    return fs.rename(tmp, path) ? path : null;
}

function ensure_runtime_cache_format() {
    ensure_dir(TACHYON_RUNTIME_STATE_DIR);

    if (first_line(TACHYON_RUNTIME_CACHE_FORMAT_FILE) != TACHYON_RUNTIME_CACHE_FORMAT) {
        if (first_line(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) == TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT)
            subscription_share_link.populate_subscription_dir(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        if (write_cache_format_file(TACHYON_RUNTIME_CACHE_FORMAT_FILE, TACHYON_RUNTIME_CACHE_FORMAT) == null)
            warn("Failed to write runtime cache format file\n");
    }

    if (first_line(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) {
        run("rm -rf " + shell_quote(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        run("chmod 700 " + shell_quote(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR) + " >/dev/null 2>&1");
        if (write_cache_format_file(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) == null)
            warn("Failed to write persistent cache format file\n");
        run("chmod 600 " + shell_quote(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) + " >/dev/null 2>&1");
    }
}

function remove_legacy_server_country_cache() {
    // Absent file already satisfies the caller; fs.unlink throws on ENOENT.
    try { fs.unlink(TACHYON_RUNTIME_STATE_DIR + "/server-country-cache.json"); } catch(e) {}
}

function remove_cache_path(path) {
    path = as_string(path);
    try {
        if (index(path, "*") >= 0)
            run("rm -f " + shell_quote(path));
        else
            fs.unlink(path);
    } catch(e) {
        warn("Failed to remove cache path: " + path + "\n");
    }
}

function apply_operations(cursor, operations) {
    let created = {};
    let section_ref = function(name) {
        name = as_string(name);
        return as_string(created[name] || name);
    };

    for (let op in operations) {
        try {
            if (op.op == "create") {
                if (op.anonymous && type(cursor.add) == "function")
                    created[as_string(op.section)] = cursor.add(CONFIG_NAME, op.type);
                else
                    cursor.set(CONFIG_NAME, op.section, op.type);
            }
            else if (op.op == "set")
                cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.value);
            else if (op.op == "delete")
                cursor.delete(CONFIG_NAME, section_ref(op.section), op.option);
            else if (op.op == "delete_section")
                cursor.delete(CONFIG_NAME, section_ref(op.section));
            else if (op.op == "add_list")
                cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.values);
            else if (op.op == "set_list")
                cursor.set(CONFIG_NAME, section_ref(op.section), op.option, op.values);
            else if (op.op == "set_type")
                cursor.set(CONFIG_NAME, section_ref(op.section), op.type);
        } catch(e) {
            warn("Migration operation '" + op.op + "' failed: " + as_string(e) + "\n");
        }
    }
}

function runtime_cursor() {
    return {
        load: function(package_name) {
            return uci_core.load(package_name);
        },
        get_all: function(package_name, section_name) {
            return uci_core.get_all(package_name, section_name);
        },
        foreach: function(package_name, type_name, callback) {
            for (let section in uci_core.section_objects(package_name, type_name))
                callback(section);
        },
        add: function(package_name, type_name) {
            return uci_core.add(package_name, type_name);
        },
        set: function(package_name, section_name, option_name, value) {
            if (value == null)
                return uci_core.set_section(package_name + "." + section_name, option_name);
            return uci_core.set(package_name + "." + section_name + "." + option_name, value);
        },
        delete: function(package_name, section_name, option_name) {
            return uci_core.delete(package_name + "." + section_name + "." + option_name);
        },
        commit: function(package_name) {
            return uci_core.commit(package_name);
        }
    };
}

function current_config_hash() {
    let config_path = "/etc/config/" + CONFIG_NAME;
    if (fs.stat(config_path) == null)
        return "";

    let output = command_output("md5sum " + shell_quote(config_path) + " 2>/dev/null");
    let fields = split(trim(output), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function mark_internal_config_guard() {
    let hash = current_config_hash();
    if (hash == "") {
        fs.unlink(TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD);
        return;
    }

    let stamp = clock();
    let tmp_path = TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD + "." + stamp[0] + "." + stamp[1];
    fs.writefile(tmp_path, as_string(stamp[0]) + "\n" + hash + "\n");
    if (!fs.rename(tmp_path, TACHYON_INTERNAL_CONFIG_TRIGGER_GUARD))
        fs.unlink(tmp_path);
}

function commit_cursor(cursor) {
    if (!cursor.commit(CONFIG_NAME))
        return false;
    mark_internal_config_guard();
    return true;
}

function migrate_model(model, source) {
    return source == "podkop"
        ? migrate_podkop_model(model, constants_context())
        : migrate_tachyon_model(model);
}

function migrate_runtime(source) {
    ensure_runtime_cache_format();
    remove_legacy_server_country_cache();

    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    let ctx = migrate_model(model_from_uci(cursor), source);
    if (!ctx.changed)
        return true;

    try {
        apply_operations(cursor, ctx.operations);
    } catch(e) {
        warn("Migration apply_operations failed: " + as_string(e) + "\n");
        return false;
    }
    let committed = commit_cursor(cursor);
    for (let path in ctx.removed_caches)
        remove_cache_path(path);

    // UCI rewrote the config file; keep the token-bearing mode tight.
    system("chmod 0600 /etc/config/" + CONFIG_NAME + " 2>/dev/null");

    return committed;
}

function commit_runtime() {
    let cursor = runtime_cursor();
    cursor.load(CONFIG_NAME);
    let committed = commit_cursor(cursor);
    system("chmod 0600 /etc/config/" + CONFIG_NAME + " 2>/dev/null");
    return committed;
}

function migrate_fixture(path, source) {
    let ctx = migrate_model(model_from_fixture(path), source);
    write_json({
        changed: ctx.changed,
        config: export_model(ctx.model),
        operations: ctx.operations,
        removed_caches: ctx.removed_caches
    });
}

// Config files that are legacy by definition, by name.
//
// The name is the only reliable discriminator, and content is not merely
// unreliable here but structurally incapable. Tachyon is a fork of forkop, so
// a forkop config carries forkop's OWN config_version and applied_migrations,
// and a diff of the two default configs shows forkop introducing no option that
// Tachyon lacks. A forkop install therefore detected as "tachyon" and skipped
// the migration while reporting success.
const LEGACY_CONFIG_BASENAMES = {
    forkop: true,
    forkop_plus: true,
    podkop: true,
    podkop_plus: true,
    netshift: true
};

function detect_config_migration_source(path) {
    path = as_string(path || "");

    // Recognised legacy path means legacy, whatever the contents say. The
    // scanner already used the name to find this file, so throwing that away
    // and re-deciding from the text loses the one piece of information that
    // actually settles it.
    let slash = rindex(path, "/");
    let basename = (slash >= 0) ? substr(path, slash + 1) : path;
    if (LEGACY_CONFIG_BASENAMES[basename])
        return "podkop";

    let content = fs.readfile(path);
    if (content == null || content == "")
        return "tachyon";

    // Unknown path (a backup, most likely) and content is genuinely ambiguous:
    // Tachyon is a fork of forkop, so the two share config_version and the
    // applied_migrations names. There is no marker that separates them. So keep
    // the existing heuristic, which prefers "native" when the new-style
    // markers are present - running the legacy conversion over a current config
    // is destructive, whereas skipping it is merely unhelpful, and
    // migrate-podkop is there for the cases that need a forced conversion.
    //
    // Note config[ \t]+rule is BOTH a legacy marker and a current Tachyon
    // section type, so it only counts on the legacy side.
    if ((match(content, /option[ \t]+config_version/) || match(content, /list[ \t]+applied_migrations/)) &&
        !match(content, /option[ \t]+connection_type/) &&
        !match(content, /option[ \t]+proxy_config_type/)) {
        return "tachyon";
    }

    // Only markers Tachyon does NOT support are decisive. `config rule` is
    // deliberately not one of them: it is both a legacy Podkop section type and
    // a current Tachyon one, so counting it made a native config with rules
    // detect as legacy, and the legacy conversion is the destructive direction.
    if (match(content, /option[ \t]+domain_list_urls/) ||
        match(content, /option[ \t]+subnet_list_urls/) ||
        match(content, /option[ \t]+routing_excluded_ips/) ||
        match(content, /option[ \t]+connection_type/) ||
        match(content, /option[ \t]+proxy_config_type/) ||
        match(content, /option[ \t]+proxy_string/) ||
        match(content, /option[ \t]+subscription_url/) ||
        match(content, /list[ \t]+subscription_url/) ||
        match(content, /option[ \t]+dns_via_outbound/) ||
        match(content, /option[ \t]+global_proxy/) ||
        match(content, /option[ \t]+enable_udp_over_tcp/)) {
        return "podkop";
    }

    return "tachyon";
}

function scan_legacy_config_candidates() {
    let base_cfg_dir = CONFIG_DIR;
    let known = [
        base_cfg_dir + "/forkop",
        base_cfg_dir + "/forkop_plus",
        base_cfg_dir + "/podkop",
        base_cfg_dir + "/podkop_plus",
        base_cfg_dir + "/netshift",
        "/tmp/legacy-config.backup",
        "/etc/.tachyon/.cfg-backup.pre-install"
    ];
    let candidates = [];
    let seen = {};

    // 1. Check if current active config itself contains unconverted legacy rules
    let current_tachyon = TARGET_CONFIG;
    if (detect_config_migration_source(current_tachyon) == "podkop") {
        let st = fs.stat(current_tachyon);
        if (st != null && (st.size || 0) > 10) {
            push(candidates, {
                path: current_tachyon,
                size: st.size || 0,
                mtime: st.mtime || 0,
                in_place_legacy: true
            });
            seen[current_tachyon] = true;
        }
    }

    for (let path in known) {
        if (seen[path]) continue;
        let st = fs.stat(path);
        if (st != null && (st.type == "file" || st.type == null) && (st.size || 0) > 10) {
            push(candidates, { path: path, size: st.size || 0, mtime: st.mtime || 0 });
            seen[path] = true;
        }
    }

    let globs = [
        base_cfg_dir + "/*forkop*",
        base_cfg_dir + "/*podkop*",
        base_cfg_dir + "/*netshift*",
        base_cfg_dir + "/tachyon.backup*",
        base_cfg_dir + "/tachyon.bak*",
        base_cfg_dir + "/tachyon.pre-import-*",
        base_cfg_dir + "/tachyon.pre-install*",
        "/tmp/legacy-config*",
        "/tmp/*forkop*",
        "/tmp/*podkop*",
        "/tmp/*netshift*",
        "/tmp/*tachyon*",
        "/tmp/tmp.*/legacy-config*",
        "/etc/.tachyon/*",
        "/root/*forkop*",
        "/root/*podkop*",
        "/root/*netshift*",
        "/root/*tachyon*",
        "/root/*.backup*",
        "/root/*.bak*"
    ];
    for (let g in globs) {
        let paths = fs.glob(g);
        if (type(paths) == "array") {
            for (let path in paths) {
                if (seen[path])
                    continue;
                let st = fs.stat(path);
                if (st != null && (st.type == "file" || st.type == null) && (st.size || 0) > 10) {
                    push(candidates, { path: path, size: st.size || 0, mtime: st.mtime || 0 });
                    seen[path] = true;
                }
            }
        }
    }

    return candidates;
}

function import_settings_cli(source_path) {
    source_path = trim(as_string(source_path));
    let target_config = TARGET_CONFIG;

    print("=== Tachyon Settings Importer ===\n\n");

    let chosen_path = "";
    let candidate_list = [];

    if (source_path != "") {
        let st = fs.stat(source_path);
        if (st == null || (st.type != "file" && st.type != null)) {
            warn("Error: Specified configuration file '" + source_path + "' does not exist or is not readable.\n");
            return false;
        }
        chosen_path = source_path;
        print("[1/3] Using specified configuration file:\n");
        print("  ✓ " + chosen_path + " (" + sprintf("%.1f KB", (st.size || 0) / 1024.0) + ")\n\n");
    } else {
        print("[1/3] Scanning system for legacy or backup configurations...\n");
        candidate_list = scan_legacy_config_candidates();
        if (length(candidate_list) == 0) {
            print("  Notice: No legacy or backup configurations found in standard directories.\n\n");
            print("To locate any leftover configurations, you can search with:\n");
            print("  grep -rnE 'vless://|vmess://|ss://|trojan://|config rule' /etc/ /root/ /tmp/ 2>/dev/null\n\n");
            print("And specify the file path directly:\n");
            print("  tachyon import_settings /path/to/backup-file\n\n");
            return false;
        }

        print("  Found candidates:\n");
        for (let i = 0; i < length(candidate_list); i++) {
            let c = candidate_list[i];
            let note = c.in_place_legacy ? " (unconverted legacy rules in active config)" : "";
            print("  [" + (i + 1) + "] " + c.path + " (" + sprintf("%.1f KB", c.size / 1024.0) + ")" + note + "\n");
        }
        print("\n");

        chosen_path = candidate_list[0].path;
        print("  ✓ Selected primary candidate: " + chosen_path + "\n\n");
    }

    print("[2/3] Backing up current Tachyon configuration...\n");
    let current_st = fs.stat(target_config);
    if (current_st != null && (current_st.size || 0) > 0) {
        let date_stamp = trim(command_output("date +%Y%m%d_%H%M%S 2>/dev/null || date +%s"));
        if (date_stamp == "") date_stamp = "backup";
        let backup_path = target_config + ".pre-import-" + date_stamp;
        if (system("cp -a " + shell_quote(target_config) + " " + shell_quote(backup_path)) == 0) {
            print("  ✓ Current configuration backed up to: " + backup_path + "\n\n");
        } else {
            warn("  Warning: Could not create safety backup of current configuration.\n\n");
        }
    } else {
        print("  ✓ No existing configuration to back up.\n\n");
    }

    print("[3/3] Migrating configuration structure...\n");
    if (chosen_path != target_config) {
        let target_dir = "";
        let idx = rindex(target_config, "/");
        if (idx > 0) target_dir = substr(target_config, 0, idx);
        if (target_dir != "" && fs.stat(target_dir) == null) {
            system("mkdir -p " + shell_quote(target_dir) + " 2>/dev/null");
        }
        if (system("cp -a " + shell_quote(chosen_path) + " " + shell_quote(target_config)) != 0) {
            warn("Error: Failed to copy " + chosen_path + " to " + target_config + "\n");
            return false;
        }
    }
    system("chmod 0600 " + shell_quote(target_config) + " 2>/dev/null");

    // Detect on the file the user actually chose, not on the destination. The
    // two are the same bytes here, but the destination is always named
    // "tachyon", and now that the file name decides, asking about it would
    // report the source's format as Tachyon every time.
    let source_type = detect_config_migration_source(chosen_path);
    print("  ✓ Detected format: " + (source_type == "podkop" ? "Legacy Forkop / Podkop / NetShift" : "Tachyon") + "\n");

    let ok = migrate_runtime(source_type);
    if (!ok) {
        warn("Error: Configuration migration failed during UCI commit.\n");
        return false;
    }

    system("chmod 0600 " + shell_quote(target_config) + " 2>/dev/null");
    print("  ✓ Configuration successfully migrated and verified.\n\n");

    let is_system_config = (target_config == "/etc/config/" + CONFIG_NAME) && (getenv("TACHYON_CONFIG_FILE") == null || getenv("TACHYON_CONFIG_FILE") == ("/etc/config/" + CONFIG_NAME));
    if (is_system_config && !bool_option(getenv("TACHYON_SKIP_RESTART"), false) && fs.stat("/etc/init.d/tachyon") != null) {
        print("Restarting Tachyon service...\n");
        system("/usr/bin/tachyon restart </dev/null >/dev/null 2>&1");
        print("  ✓ Tachyon restarted with imported configuration.\n\n");
    }

    print("====================================================\n");
    print("SUCCESS: Settings successfully imported from:\n");
    print("   " + chosen_path + "\n");
    print("====================================================\n");
    return true;
}

function main(argv) {
    let mode = argv[0] || "";

    if (mode == "migrate") {
        let source = detect_config_migration_source(TARGET_CONFIG);
        return migrate_runtime(source) ? 0 : 1;
    }
    if (mode == "migrate-podkop")
        return migrate_runtime("podkop") ? 0 : 1;
    if (mode == "import-settings" || mode == "import_settings")
        return import_settings_cli(argv[1]) ? 0 : 1;
    if (mode == "commit")
        return commit_runtime() ? 0 : 1;
    if (mode == "migrate-fixture") {
        migrate_fixture(argv[1], argv[2] || "tachyon");
        return 0;
    }

    warn("Usage: config/migration.uc migrate\n");
    warn("       config/migration.uc migrate-podkop\n");
    warn("       config/migration.uc import-settings [file]\n");
    warn("       config/migration.uc commit\n");
    warn("       config/migration.uc migrate-fixture <fixture.json> [tachyon|podkop]\n");
    return 1;
}

function module_exports() {
    return {
        main: main,
        migrate_model: migrate_model,
        migrate_tachyon_model: migrate_tachyon_model,
        migrate_podkop_model: migrate_podkop_model,
        migrate_modular_entities_v1: migrate_modular_entities_v1,
        scan_legacy_config_candidates: scan_legacy_config_candidates,
        detect_config_migration_source: detect_config_migration_source,
        import_settings_cli: import_settings_cli,
        mark_internal_config_guard: mark_internal_config_guard
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

exit(main(ARGV));