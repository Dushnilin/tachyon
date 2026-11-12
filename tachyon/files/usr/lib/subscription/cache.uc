#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let helpers = require("core.helpers");
let uci_core = require("core.uci");
let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let connections = require("config.connections");
let subscription_share_link = require("subscription.share_link");
let happ = require("subscription.happ");

function core_url_module_or_null() {
    try {
        return require("core.url");
    } catch (e) {
        return null;
    }
}

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || "/tmp/tachyon-core";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_SING_BOX_FOLDER + "/subscriptions";
const TACHYON_RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR = getenv("TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR") || TACHYON_RUNTIME_STATE_DIR + "/subscription-update";
const TACHYON_SUBSCRIPTION_LINKS_DIR = getenv("TACHYON_SUBSCRIPTION_LINKS_DIR") || TACHYON_RUNTIME_STATE_DIR + "/subscription-links";
const TACHYON_SUBSCRIPTION_METADATA_DIR = getenv("TACHYON_SUBSCRIPTION_METADATA_DIR") || TACHYON_RUNTIME_STATE_DIR + "/subscription-metadata";
const TACHYON_OUTBOUND_METADATA_DIR = getenv("TACHYON_OUTBOUND_METADATA_DIR") || TACHYON_RUNTIME_STATE_DIR + "/outbound-metadata";
const TACHYON_SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || TACHYON_RUNTIME_STATE_DIR + "/section-cache";
const TACHYON_RUNTIME_CACHE_FORMAT_FILE = getenv("TACHYON_RUNTIME_CACHE_FORMAT_FILE") || TACHYON_RUNTIME_STATE_DIR + "/cache-format";
const TACHYON_RUNTIME_CACHE_FORMAT = getenv("TACHYON_RUNTIME_CACHE_FORMAT") || "9";
const TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/tachyon/subscription-cache";
const TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "8";
const TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE = getenv("TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE") || TACHYON_RUNTIME_STATE_DIR + "/subscription-bootstrap-retry.pid";
const TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR = getenv("TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR") || TACHYON_RUNTIME_STATE_DIR + "/subscription-update.lock";
const TACHYON_PENDING_RELOAD_FILE = getenv("TACHYON_PENDING_RELOAD_FILE") || TACHYON_RUNTIME_STATE_DIR + "/reload.pending";
const TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE = getenv("TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE") || TACHYON_RUNTIME_STATE_DIR + "/deferred-sections";
const TACHYON_SERVICE_INIT = getenv("TACHYON_SERVICE_INIT") || "/etc/init.d/tachyon";
const SB_SERVICE_MIXED_INBOUND_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const SB_SERVICE_MIXED_INBOUND_PORT = getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534";
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || "/etc/tachyon/tachyon-core-variant";
const SB_VERSION_STATE_FILE = getenv("SB_VERSION_STATE_FILE") || "/etc/tachyon/tachyon-core-version";
const ZAPRET_PROVIDER_NFQWS_BIN = getenv("ZAPRET_PROVIDER_NFQWS_BIN") || "/opt/zapret/nfq/nfqws";
let default_zapret2_bin = "/opt/zapret2/nfq2/nfqws2";
for (let b in [ "/opt/zapret2/nfq2/nfqws2", "/opt/zapret2/nfq/nfqws2", "/opt/zapret2/nfqws2", "/usr/bin/nfqws2" ]) {
    if (fs.stat(b) != null) { default_zapret2_bin = b; break; }
}
const ZAPRET2_PROVIDER_NFQWS2_BIN = getenv("ZAPRET2_PROVIDER_NFQWS2_BIN") || default_zapret2_bin;
const BYEDPI_BIN = getenv("BYEDPI_BIN") || "/usr/bin/ciadpi";

function read_stdin() {
    let data = fs.readfile("/dev/stdin");
    return data == null ? "" : data;
}

function read_json(path) {
    if (path == null || path == "" || path == "-")
        return null;

    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function write_file(path, value) {
    return common.write_file(as_string(path), as_string(value)) != null;
}

function write_json(path, value) {
    return write_file(path, sprintf("%J", value) + "\n");
}

function write_stdout_json(value) {
    print(sprintf("%J", value), "\n");
}

let file_first_line = common.print_file_first_line;
let file_first_line_value = common.file_first_line;

function file_has_exact_line(path, needle) {
    let data = fs.readfile(path);
    if (data == null)
        return false;

    needle = as_string(needle);
    for (let line in split(data, "\n"))
        if (as_string(line) == needle)
            return true;

    return false;
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function state_list_contains(list, value) {
    value = as_string(value);
    if (value == "")
        return false;

    for (let item in whitespace_values(list))
        if (item == value)
            return true;

    return false;
}

function append_state_list_once(list, value) {
    list = trim(as_string(list));
    value = as_string(value);

    if (value == "" || state_list_contains(list, value)) {
        print(list, "\n");
        return;
    }

    print(list, list != "" ? " " : "", value, "\n");
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";

    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function bool_value(value, fallback) {
    if (value == null)
        return !!fallback;

    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    return bool_value(object_or_empty(section)[key], fallback);
}

function unsigned_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;
    return int(value);
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
        total = total + amount * multipliers[unit];
        rest = substr(rest, length(token));
    }

    if (total <= 0)
        return null;

    return int(total + 0.5);
}

function update_due_status(now_value, last_run_value, interval_value) {
    let now = unsigned_number(now_value);
    let interval = unsigned_number(interval_value);

    if (now == null || interval == null || interval <= 0)
        return 2;

    let last_run = unsigned_number(last_run_value);
    if (last_run == null)
        last_run = 0;

    if (last_run > 0 && now - last_run < interval)
        return 1;

    return 0;
}

function cache_section_is_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0;
}

function append_word_once(words, value) {
    words = trim(as_string(words));
    value = as_string(value);

    if (value == "" || state_list_contains(words, value))
        return words;

    return words + (words != "" ? " " : "") + value;
}

let section_name = common.section_name;

function source_id(section, index) {
    return as_string(section) + "-subscription-" + as_string(index);
}

function subscription_metadata_path(section) {
    section = as_string(section);
    if (!cache_section_is_safe(section))
        return "";
    return TACHYON_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json";
}

function outbound_metadata_path(section) {
    section = as_string(section);
    if (!cache_section_is_safe(section))
        return "";
    return TACHYON_OUTBOUND_METADATA_DIR + "/" + section + ".json";
}

function section_has_subscription_urls(section) {
    return length(connections.subscription_urls(section)) > 0;
}

function section_is_subscription_proxy(section) {
    return bool_option(section, "enabled", true) &&
        connections.is_connections_action(option(section, "action", "")) &&
        section_has_subscription_urls(section);
}

function section_subscription_update_interval(section) {
    let result = "";
    let result_seconds = 0;

    for (let entry in connections.subscription_urls(section)) {
        if (!connections.subscription_update_enabled(section, entry))
            continue;

        let value = connections.subscription_update_interval(section, entry);
        if (value == "")
            value = "1h";
        let seconds = duration_to_seconds_value(value);
        if (result == "" || (seconds != null && (result_seconds == 0 || seconds < result_seconds))) {
            result = value;
            result_seconds = seconds == null ? 0 : seconds;
        }
    }

    return result;
}

function section_subscription_update_jitter(section) {
    if (type(connections.subscription_update_jitter) != "function")
        return "";
    for (let entry in connections.subscription_urls(section)) {
        if (!connections.subscription_update_enabled(section, entry))
            continue;
        let jit = trim(as_string(connections.subscription_update_jitter(section, entry) || ""));
        if (jit != "")
            return jit;
    }
    return trim(as_string(connections.subscription_update_jitter(section, "") || ""));
}

function apply_subscription_jitter_seconds(base_seconds, jitter_spec, section_name_val, last_run_val) {
    base_seconds = int(base_seconds || 0);
    jitter_spec = trim(as_string(jitter_spec || ""));
    if (base_seconds <= 1 || jitter_spec == "" || jitter_spec == "0" || lc(jitter_spec) == "disabled")
        return base_seconds;
    let max_delta = 0;
    let pct_match = match(jitter_spec, /^([0-9]+)%$/);
    if (pct_match != null) {
        let pct = int(pct_match[1], 10);
        if (pct > 80)
            pct = 80;
        if (pct > 0)
            max_delta = int((base_seconds * pct) / 100.0 + 0.5);
    } else {
        let dur = duration_to_seconds_value(jitter_spec);
        if (dur != null && dur > 0)
            max_delta = dur > int(base_seconds * 0.8) ? int(base_seconds * 0.8) : dur;
        else
            max_delta = int(base_seconds * 0.15 + 0.5);
    }
    if (max_delta <= 0)
        return base_seconds;
    let seed = as_string(section_name_val || "") + ":" + as_string(last_run_val || "0");
    let h = 2166136261;
    for (let i = 0; i < length(seed); i++)
        h = ((h ^ ord(seed, i)) * 16777619) & 0x7fffffff;
    let span = max_delta * 2 + 1;
    let offset = (h % span) - max_delta;
    if (offset == 0)
        offset = (h & 1) ? 1 : -1;
    let eff = base_seconds + offset;
    return eff < 60 ? 60 : eff;
}

function subscription_source_count(section) {
    return length(connections.subscription_urls(section));
}

function cache_keep_sets(sections) {
    let keep = {
        sections: "",
        sources: "",
        all: ""
    };

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (!cache_section_is_safe(name))
            continue;

        keep.sections = append_word_once(keep.sections, name);
        keep.all = append_word_once(keep.all, name);

        let count = subscription_source_count(section);
        for (let i = 1; i <= count; i++) {
            let source = source_id(name, i);
            if (!cache_section_is_safe(source))
                continue;

            keep.sources = append_word_once(keep.sources, source);
            keep.all = append_word_once(keep.all, source);
        }
    }

    for (let src in array_or_empty(uci_core.sections(CONFIG_NAME, "outbound_source"))) {
        src = object_or_empty(src);
        let src_id = as_string(src[".name"] || "");
        let src_url = connections.outbound_source_subscription_url(src);
        if (src_id == "" || src_url == "" || (!match(lc(src_url), /^https?:\/\//) && !happ.is_encrypted(src_url)))
            continue;
        let pool_name = "Pool_" + src_id;
        if (cache_section_is_safe(pool_name)) {
            keep.sections = append_word_once(keep.sections, pool_name);
            keep.all = append_word_once(keep.all, pool_name);
            let pool_source = source_id(pool_name, 1);
            if (cache_section_is_safe(pool_source)) {
                keep.sources = append_word_once(keep.sources, pool_source);
                keep.all = append_word_once(keep.all, pool_source);
            }
        }
        if (cache_section_is_safe(src_id)) {
            keep.sections = append_word_once(keep.sections, src_id);
            keep.all = append_word_once(keep.all, src_id);
            let direct_source = source_id(src_id, 1);
            if (cache_section_is_safe(direct_source)) {
                keep.sources = append_word_once(keep.sources, direct_source);
                keep.all = append_word_once(keep.all, direct_source);
            }
        }
    }

    return keep;
}

function runtime_cache_missing(sections, section_cache_dir) {
    section_cache_dir = as_string(section_cache_dir);

    for (let section in sections) {
        section = object_or_empty(section);
        let name = section_name(section);
        if (!section_is_subscription_proxy(section))
            continue;
        if (!cache_section_is_safe(name))
            continue;
        let cache_path = section_cache_dir + "/" + name + ".json";
        if (fs.stat(cache_path) == null)
            return true;
        // Section-cache exists but has no outbounds — this happens when a new
        // subscription section was generated before its source data was downloaded.
        // If source data is now available on disk, trigger a rebuild so servers appear.
        let cached = read_json(cache_path);
        if (type(cached) == "object") {
            let names = object_or_empty(object_or_empty(cached.outboundMetadata).names);
            let has_outbounds = false;
            for (let k in names) { has_outbounds = true; break; }
            if (!has_outbounds) {
                let count = subscription_source_count(section);
                for (let i = 1; i <= count; i++) {
                    let src_path = TMP_SUBSCRIPTION_FOLDER + "/" + source_id(name, i) + ".json";
                    if (fs.stat(src_path) != null)
                        return true;
                }
            }
        }
    }

    return false;
}

function path_starts_with(path, prefix) {
    path = as_string(path);
    prefix = as_string(prefix);
    if (prefix == "")
        return false;
    return path == prefix || substr(path, 0, length(prefix) + 1) == prefix + "/";
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function cache_name_from_file(path) {
    let slash = rindex(path, "/");
    let file_name = slash >= 0 ? substr(path, slash + 1) : path;

    if (file_name == "cache-format")
        return "";
    if (ends_with(file_name, ".metadata.json"))
        return substr(file_name, 0, length(file_name) - 14);
    if (ends_with(file_name, ".json"))
        return substr(file_name, 0, length(file_name) - 5);
    if (ends_with(file_name, ".url"))
        return substr(file_name, 0, length(file_name) - 4);
    if (ends_with(file_name, ".user_agent"))
        return substr(file_name, 0, length(file_name) - 11);
    if (ends_with(file_name, ".hwid"))
        return substr(file_name, 0, length(file_name) - 5);
    if (ends_with(file_name, ".device_headers"))
        return substr(file_name, 0, length(file_name) - 15);

    return "";
}

function keep_names_for_path(path, keep, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir) {
    if (path_starts_with(path, tmp_dir) || path_starts_with(path, persistent_dir))
        return keep.sources;
    if (path_starts_with(path, section_cache_dir))
        return keep.all;
    if (path_starts_with(path, links_dir) || path_starts_with(path, metadata_dir) || path_starts_with(path, outbound_metadata_dir))
        return keep.sections;
    return "";
}

function stale_cache_delete_paths(sections, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir) {
    let keep = cache_keep_sets(sections);

    for (let path in split(read_stdin(), "\n")) {
        path = as_string(path);
        if (path == "")
            continue;

        let cache_name = cache_name_from_file(path);
        if (cache_name == "")
            continue;

        let keep_names = keep_names_for_path(path, keep, tmp_dir, persistent_dir, section_cache_dir, links_dir, metadata_dir, outbound_metadata_dir);
        if (state_list_contains(keep_names, cache_name))
            continue;

        print(path, "\n");
    }
}

function fixture_section_list(data) {
    data = object_or_empty(data);
    if (type(data.section) == "array")
        return data.section;
    if (type(data.section) == "object")
        return [ data.section ];
    if (type(data.sections) == "array")
        return data.sections;
    return [];
}

function uci_sections() {
    return uci_core.section_objects(CONFIG_NAME, "section");
}

function maintenance_plan(sections, section_cache_dir) {
    let keep = cache_keep_sets(sections);
    print("sections\t", keep.sections, "\n");
    print("sources\t", keep.sources, "\n");
    print("all\t", keep.all, "\n");
    print("missing\t", runtime_cache_missing(sections, section_cache_dir) ? "1" : "0", "\n");
}

let auto_user_agent_profiles = [
    "Happ",
    "Happ/4.6.2",
    "v2rayN",
    "v2rayNG",
    "Mihomo",
    "Clash.Meta"
];

let auto_user_agents = {
    "ClashMeta": true,
    "HiddifyNext": true,
    "Mozilla": true
};
for (let profile in auto_user_agent_profiles)
    auto_user_agents[profile] = true;

function user_agent_supported(user_agent, default_user_agent) {
    user_agent = as_string(user_agent);
    default_user_agent = as_string(default_user_agent);

    if (user_agent == "")
        return false;
    if (user_agent == default_user_agent || user_agent == "offline")
        return true;
    if (index(user_agent, "sing-box") == 0 || index(user_agent, "tachyon") == 0)
        return true;
    if (auto_user_agents[user_agent] == true)
        return true;
    for (let profile in auto_user_agent_profiles) {
        if (index(user_agent, profile + "/") == 0)
            return true;
    }

    return false;
}

function user_agent_matches_config(configured_user_agent, cached_user_agent, default_user_agent) {
    configured_user_agent = as_string(configured_user_agent);
    cached_user_agent = as_string(cached_user_agent);

    if (configured_user_agent != "")
        return cached_user_agent == configured_user_agent;

    return user_agent_supported(cached_user_agent, default_user_agent);
}

let parser_module = null;
let _usable_subscription_cache = null;
const USABLE_SUBSCRIPTION_STAMPS_FILE = TACHYON_RUNTIME_STATE_DIR + "/usable-subscriptions.json";

function subscription_parser() {
    if (parser_module == null)
        parser_module = require("subscription.parser");
    return parser_module;
}

function subscription_cache_is_usable(path) {
    let p = as_string(path);
    let st = fs.stat(p);
    if (st == null)
        return false;
    if (_usable_subscription_cache == null) {
        let loaded = read_json(USABLE_SUBSCRIPTION_STAMPS_FILE);
        _usable_subscription_cache = type(loaded) == "object" ? loaded : {};
    }
    let stamp = p + "|" + as_string(st.size || 0) + "|" + as_string(st.mtime || 0);
    if (exists(_usable_subscription_cache, stamp))
        return _usable_subscription_cache[stamp] === true;
    let ok = subscription_parser().validate_subscription(p);
    _usable_subscription_cache[stamp] = ok;
    if (ok) {
        common.ensure_dir(TACHYON_RUNTIME_STATE_DIR);
        common.write_json_file(USABLE_SUBSCRIPTION_STAMPS_FILE, _usable_subscription_cache);
    }
    return ok;
}

function usable_subscription_outbound_count(path) {
    let value = read_json(path);
    if (type(value) != "object" || type(value.outbounds) != "array")
        return 0;

    let parser = subscription_parser();
    let count = 0;
    for (let outbound in value.outbounds) {
        if (type(outbound) != "object")
            continue;
        if (parser.outbound_is_unsupported_stub(outbound))
            continue;
        count++;
    }
    return count;
}

function subscription_shrink_guard_triggers(old_path, new_path) {
    return usable_subscription_outbound_count(old_path) >= 6 &&
        usable_subscription_outbound_count(new_path) <= 2;
}

function source_json_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".json";
}

function source_url_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".url";
}

function source_user_agent_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".user_agent";
}

function source_hwid_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".hwid";
}

function source_device_headers_path(dir, source_section) {
    return as_string(dir) + "/" + as_string(source_section) + ".device_headers";
}

function read_text(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

function write_text(path, value) {
    return common.write_file(as_string(path), as_string(value)) != null;
}

function copy_file(source, target) {
    let data = fs.readfile(as_string(source));
    if (data == null)
        return false;

    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", as_string(target), stamp[0], stamp[1]);
    if (!write_file(tmp_path, data))
        return false;
    if (!fs.rename(tmp_path, as_string(target))) {
        fs.unlink(tmp_path);
        return false;
    }
    return true;
}

// The empty catch is the point: every caller means "make sure this path is
// gone", and an absent file already satisfies that. fs.unlink throws on ENOENT,
// so the alternative is a stat() race with no better outcome.
function unlink_path(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function file_nonempty(path) {
    return helpers.file_is_usable(path, 0);
}

function files_equal(left, right) {
    let left_data = fs.readfile(as_string(left));
    let right_data = fs.readfile(as_string(right));
    return left_data != null && right_data != null && left_data == right_data;
}

function command_env(assignments) {
    let parts = [];

    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));

    return join(" ", parts);
}

function command_args_with(base, extra) {
    let result = [];

    for (let arg in base)
        push(result, arg);
    for (let arg in extra)
        push(result, arg);

    return result;
}

let command_status_from_args = common.command_status_from_args;

// curl --dns-servers requires libcurl built with c-ares (not available on all OpenWrt builds).
// When c-ares is absent, rely on the system resolver first so an unreachable DoH provider
// (e.g. 1.1.1.1; issue #387) never blocks downloads. Only fall back to DoH resolvers after
// an actual host-resolution failure.
const CURL_DOH_FALLBACK_URLS = [
    "https://dns.google/dns-query",
    "https://common.dot.dns.yandex.net/dns-query",
    "https://1.1.1.1/dns-query"
];
let _curl_has_dns_servers = null;
let _curl_has_doh_url = null;
let _curl_working_doh_url = "";
function curl_push_dns_servers(args, doh_fallback_index) {
    if (_curl_has_dns_servers === null) {
        let cap = common.command_capture(command_from_args([ "curl", "--dns-servers", "8.8.8.8", "-V" ]) + " 2>/dev/null");
        _curl_has_dns_servers = (cap != null && int(cap.status) == 0);
    }
    if (_curl_has_dns_servers) {
        push(args, "--dns-servers", "8.8.8.8,77.88.8.8,1.1.1.1");
        return "";
    }

    let idx = int(doh_fallback_index || 0);
    if (idx <= 0 && _curl_working_doh_url == "")
        return "";

    if (_curl_has_doh_url === null) {
        let cap = common.command_capture(command_from_args([ "curl", "--doh-url", "https://dns.google/dns-query", "-V" ]) + " 2>/dev/null");
        _curl_has_doh_url = (cap != null && int(cap.status) == 0);
    }
    if (!_curl_has_doh_url)
        return "";

    let chosen = (_curl_working_doh_url != "" && idx <= 0)
        ? _curl_working_doh_url
        : CURL_DOH_FALLBACK_URLS[(idx > 0 ? idx - 1 : 0) % length(CURL_DOH_FALLBACK_URLS)];
    push(args, "--doh-url", chosen);
    return chosen;
}

function run_silent(command) {
    system(command + " >/dev/null 2>&1");
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[" + level + "] " + as_string(message) ]);
}

function ensure_dir(path) {
    let stat = fs.stat(as_string(path));
    if (stat != null && stat.type == "directory")
        return true;
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function chmod_path(path, mode) {
    let stat = fs.stat(as_string(path));
    if (stat != null && type(stat.permissions) == "object") {
        let u = object_or_empty(stat.permissions.user);
        let g = object_or_empty(stat.permissions.group);
        let o = object_or_empty(stat.permissions.other);
        let g_clean = !g.read && !g.write && !g.exec;
        let o_clean = !o.read && !o.write && !o.exec;
        if (mode == "600" && u.read && u.write && !u.exec && g_clean && o_clean)
            return;
        if (mode == "700" && u.read && u.write && u.exec && g_clean && o_clean)
            return;
    }
    command_success_from_args([ "chmod", as_string(mode), as_string(path) ]);
}

function ensure_runtime_dirs() {
    ensure_dir(TMP_SING_BOX_FOLDER);
    ensure_dir(TMP_RULESET_FOLDER);
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    ensure_dir(TACHYON_RUNTIME_STATE_DIR);
    ensure_dir(TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR);
    ensure_dir(TACHYON_SUBSCRIPTION_METADATA_DIR);
    ensure_dir(TACHYON_OUTBOUND_METADATA_DIR);
    ensure_dir(TACHYON_SECTION_CACHE_DIR);
}

function clear_subscription_runtime_cache() {
    run_silent("rm -rf " +
        shell_quote(TMP_SUBSCRIPTION_FOLDER) + " " +
        shell_quote(TACHYON_SUBSCRIPTION_LINKS_DIR) + " " +
        shell_quote(TACHYON_SUBSCRIPTION_METADATA_DIR) + " " +
        shell_quote(TACHYON_OUTBOUND_METADATA_DIR) + " " +
        shell_quote(TACHYON_SECTION_CACHE_DIR));
}

function ensure_runtime_cache_format() {
    ensure_dir(TACHYON_RUNTIME_STATE_DIR);

    if (file_first_line_value(TACHYON_RUNTIME_CACHE_FORMAT_FILE) != TACHYON_RUNTIME_CACHE_FORMAT) {
        log_message("Runtime subscription cache format changed; clearing old subscription cache", "info");
        if (file_first_line_value(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) == TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT)
            subscription_share_link.populate_subscription_dir(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        clear_subscription_runtime_cache();
        ensure_runtime_dirs();
        write_file(TACHYON_RUNTIME_CACHE_FORMAT_FILE, TACHYON_RUNTIME_CACHE_FORMAT + "\n");
    }

    if (file_first_line_value(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE) != TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT) {
        run_silent("rm -rf " + shell_quote(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR));
        ensure_dir(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        chmod_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, "700");
        write_file(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT + "\n");
        chmod_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE, "600");
    }
}

function temp_path(dir, section, kind) {
    ensure_dir(dir);
    let stamp = clock();
    return sprintf("%s/%s.%s.%d.%d", dir, as_string(section), as_string(kind), stamp[0], stamp[1]);
}

function move_file(source, target) {
    return fs.rename(as_string(source), as_string(target));
}

function write_text_if_changed(path, value) {
    path = as_string(path);
    value = as_string(value);

    if (fs.readfile(path) == value)
        return true;

    let tmp_path = sprintf("%s.%d.%d.tmp", path, clock()[0], clock()[1]);
    if (!write_file(tmp_path, value)) {
        unlink_path(tmp_path);
        return false;
    }
    if (!fs.rename(tmp_path, path)) {
        unlink_path(tmp_path);
        return false;
    }

    chmod_path(path, "600");
    return true;
}

function copy_file_if_changed(source, target) {
    if (!file_nonempty(source))
        return false;
    if (files_equal(source, target))
        return true;
    if (!copy_file(source, target))
        return false;

    chmod_path(target, "600");
    return true;
}

let _cached_kernel_version = "";
let _cached_generated_hwid = "";
let _last_download_transport_failed = false;

function get_device_model() {
    let model = fs.readfile("/tmp/sysinfo/model");
    model = trim(as_string(model));
    return model != "" ? model : "OpenWrt Router";
}

function get_kernel_version() {
    if (_cached_kernel_version == "")
        _cached_kernel_version = trim(command_output_from_args([ "uname", "-r" ]));
    return _cached_kernel_version;
}

function generate_hwid() {
    if (_cached_generated_hwid != "")
        return _cached_generated_hwid;

    let mac = trim(as_string(fs.readfile("/sys/class/net/eth0/address")));
    if (mac == "")
        mac = trim(as_string(fs.readfile("/sys/class/net/br-lan/address")));

    let input = mac + "-" + get_device_model();
    let output = command_output("printf %s " + shell_quote(input) + " | md5sum");
    let hash = length(whitespace_values(output)) > 0 ? substr(whitespace_values(output)[0], 0, 16) : "";
    _cached_generated_hwid = substr(hash, 0, 4) + "-" + substr(hash, 4, 4) + "-" + substr(hash, 8, 4) + "-" + substr(hash, 12, 4);
    return _cached_generated_hwid;
}

function hwid_matches_config(configured_hwid, cached_hwid) {
    configured_hwid = as_string(configured_hwid);
    cached_hwid = as_string(cached_hwid);

    if (configured_hwid != "")
        return cached_hwid == configured_hwid;

    return cached_hwid == "" || cached_hwid == generate_hwid();
}

function device_request_headers(headers) {
    headers = object_or_empty(headers);
    if (!headers.enabled) {
        return [
            "X-Device-OS: OpenWrt Linux",
            "X-Device-Model: " + get_device_model(),
            "X-Ver-OS: " + get_kernel_version(),
            "Accept-Language: ru-RU,en,*",
            "X-Device-Locale: EN"
        ];
    }

    let result = [];
    for (let item in [
        { name: "X-Device-OS", value: headers.device_os },
        { name: "X-Ver-OS", value: headers.ver_os },
        { name: "X-Device-Model", value: headers.device_model },
        { name: "X-Device-Locale", value: headers.device_locale },
        { name: "X-App-Version", value: headers.app_version },
        { name: "Accept-Language", value: headers.accept_language }
    ]) {
        if (as_string(item.value) != "")
            push(result, item.name + ": " + as_string(item.value));
    }
    return result;
}

function restore_persistent_subscription_cache(source_section, tmp_dir, persistent_dir, expected_url, expected_user_agent, expected_hwid, default_user_agent, expected_device_headers_signature) {
    if (!cache_section_is_safe(source_section))
        return false;

    let runtime_json = source_json_path(tmp_dir, source_section);
    let runtime_url = read_text(source_url_path(tmp_dir, source_section));
    let runtime_user_agent = read_text(source_user_agent_path(tmp_dir, source_section));
    let runtime_hwid = read_text(source_hwid_path(tmp_dir, source_section));
    let runtime_device_headers = read_text(source_device_headers_path(tmp_dir, source_section));
    if (subscription_cache_is_usable(runtime_json) &&
        runtime_url == as_string(expected_url) &&
        user_agent_matches_config(expected_user_agent, runtime_user_agent, default_user_agent) &&
        hwid_matches_config(expected_hwid, runtime_hwid) &&
        runtime_device_headers == as_string(expected_device_headers_signature))
        return true;

    let candidate = null;
    let persistent_json = source_json_path(persistent_dir, source_section);
    if (subscription_cache_is_usable(persistent_json)) {
        let cached_url = read_text(source_url_path(persistent_dir, source_section));
        let cached_user_agent = read_text(source_user_agent_path(persistent_dir, source_section));
        let cached_hwid = read_text(source_hwid_path(persistent_dir, source_section));
        let cached_device_headers = read_text(source_device_headers_path(persistent_dir, source_section));
        if (cached_url == as_string(expected_url) &&
            user_agent_matches_config(expected_user_agent, cached_user_agent, default_user_agent) &&
            hwid_matches_config(expected_hwid, cached_hwid) &&
            cached_device_headers == as_string(expected_device_headers_signature)) {
            candidate = source_section;
        }
    }

    let candidate_dir = persistent_dir;
    if (candidate == null) {
        let pattern = as_string(persistent_dir) + "/*.url";
        for (let url_file in (fs.glob(pattern) || [])) {
            let name = cache_name_from_file(url_file);
            if (!cache_section_is_safe(name) || name == source_section)
                continue;

            let c_json = source_json_path(persistent_dir, name);
            if (!subscription_cache_is_usable(c_json))
                continue;
            if (read_text(url_file) != as_string(expected_url))
                continue;
            if (!user_agent_matches_config(expected_user_agent, read_text(source_user_agent_path(persistent_dir, name)), default_user_agent))
                continue;
            if (!hwid_matches_config(expected_hwid, read_text(source_hwid_path(persistent_dir, name))))
                continue;
            if (read_text(source_device_headers_path(persistent_dir, name)) != as_string(expected_device_headers_signature))
                continue;

            candidate = name;
            candidate_dir = persistent_dir;
            break;
        }
    }

    if (candidate == null && as_string(tmp_dir) != "" && as_string(tmp_dir) != as_string(persistent_dir)) {
        let tmp_pattern = as_string(tmp_dir) + "/*.url";
        for (let url_file in (fs.glob(tmp_pattern) || [])) {
            let name = cache_name_from_file(url_file);
            if (!cache_section_is_safe(name) || name == source_section)
                continue;

            let c_json = source_json_path(tmp_dir, name);
            if (!subscription_cache_is_usable(c_json))
                continue;
            if (read_text(url_file) != as_string(expected_url))
                continue;
            if (!user_agent_matches_config(expected_user_agent, read_text(source_user_agent_path(tmp_dir, name)), default_user_agent))
                continue;
            if (!hwid_matches_config(expected_hwid, read_text(source_hwid_path(tmp_dir, name))))
                continue;
            if (read_text(source_device_headers_path(tmp_dir, name)) != as_string(expected_device_headers_signature))
                continue;

            candidate = name;
            candidate_dir = tmp_dir;
            break;
        }
    }

    if (candidate == null)
        return false;

    let candidate_json = source_json_path(candidate_dir, candidate);
    let cached_url = read_text(source_url_path(candidate_dir, candidate));
    let cached_user_agent = read_text(source_user_agent_path(candidate_dir, candidate));
    let cached_hwid = read_text(source_hwid_path(candidate_dir, candidate));
    let cached_device_headers = read_text(source_device_headers_path(candidate_dir, candidate));

    let ok = copy_file(candidate_json, runtime_json) &&
        write_text(source_url_path(tmp_dir, source_section), cached_url) &&
        write_text(source_user_agent_path(tmp_dir, source_section), cached_user_agent) &&
        write_text(source_hwid_path(tmp_dir, source_section), cached_hwid) &&
        write_text(source_device_headers_path(tmp_dir, source_section), cached_device_headers);

    if (!ok)
        return false;

    let candidate_metadata = as_string(candidate_dir) + "/" + as_string(candidate) + ".metadata.json";
    let runtime_metadata = as_string(tmp_dir) + "/" + as_string(source_section) + ".metadata.json";
    if (file_nonempty(candidate_metadata))
        copy_file(candidate_metadata, runtime_metadata);
    else
        unlink_path(runtime_metadata);

    return true;
}

function subscription_source_profile(section, entry) {
    let parsed = subscription_parser().parse_subscription_source_entry(entry);
    if (type(parsed) != "object" || parsed.valid !== true)
        return parsed;

    let user_agent = connections.subscription_user_agent(section, entry);
    if (user_agent != "")
        parsed.user_agent = user_agent;

    parsed.hwid = connections.subscription_hwid(section, entry);
    parsed.insecure = connections.subscription_insecure(section, entry);
    parsed.device_headers = connections.subscription_device_headers(section, entry);
    parsed.device_headers_signature = connections.subscription_device_headers_signature(section, entry);
    parsed.download_section = connections.subscription_download_section(section, entry);
    parsed.update_enabled = connections.subscription_update_enabled(section, entry);
    parsed.update_interval = connections.subscription_update_interval(section, entry);
    parsed.show_dashboard_metadata = connections.subscription_dashboard_metadata_enabled(section, entry);
    parsed.subscription_engine = connections.subscription_engine(section, entry);
    return parsed;
}

function source_cache_profile_matches(parsed, cached_url, cached_user_agent, cached_hwid, default_user_agent, cached_device_headers) {
    return cached_url == as_string(parsed.url) &&
        user_agent_matches_config(parsed.user_agent, cached_user_agent, default_user_agent) &&
        hwid_matches_config(parsed.hwid, cached_hwid) &&
        as_string(cached_device_headers) == as_string(parsed.device_headers_signature);
}

function section_current_usable_cache(section, tmp_dir, persistent_dir, default_user_agent) {
    section = object_or_empty(section);
    let name = section_name(section);
    if (!section_has_subscription_urls(section) || !cache_section_is_safe(name))
        return false;

    let index = 0;
    for (let entry in connections.subscription_urls(section)) {
        index++;
        let parsed = subscription_source_profile(section, entry);
        if (type(parsed) != "object" || parsed.valid !== true)
            continue;

        let source_section = source_id(name, index);
        if (!restore_persistent_subscription_cache(
            source_section,
            tmp_dir,
            persistent_dir,
            parsed.url,
            parsed.user_agent,
            parsed.hwid,
            default_user_agent,
            parsed.device_headers_signature
        ))
            continue;

        if (!subscription_cache_is_usable(source_json_path(tmp_dir, source_section)))
            continue;

        let cached_url = read_text(source_url_path(tmp_dir, source_section));
        let cached_user_agent = read_text(source_user_agent_path(tmp_dir, source_section));
        let cached_hwid = read_text(source_hwid_path(tmp_dir, source_section));
        let cached_device_headers = read_text(source_device_headers_path(tmp_dir, source_section));
        if (source_cache_profile_matches(parsed, cached_url, cached_user_agent, cached_hwid, default_user_agent, cached_device_headers))
            return true;
    }

    return false;
}

function uci_section(section_name_value) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name_value));
}

function uci_named_section(section_name_value) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name_value));
}

function find_section(sections, name) {
    name = as_string(name);
    for (let section in sections) {
        section = object_or_empty(section);
        if (section_name(section) == name)
            return section;
    }
    if (substr(name, 0, 5) == "Pool_") {
        let src_id = substr(name, 5);
        let src_obj = uci_section(src_id);
        if (as_string(src_obj[".type"]) == "outbound_source") {
            return {
                ".name": name,
                "enabled": as_string(src_obj.enabled || "1"),
                "action": "connection",
                "proxy_config_type": "subscription",
                "outbound_source_refs": [ src_id ]
            };
        }
    }
    return {};
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function sing_box_service_running() {
    return command_success_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc", "sing-box-service-running" ]);
}

function provider_action_is_available(action) {
    if (action == "byedpi")
        return file_executable(BYEDPI_BIN);
    if (action == "zapret")
        return file_executable(ZAPRET_PROVIDER_NFQWS_BIN);
    if (action == "zapret2")
        return file_executable(ZAPRET2_PROVIDER_NFQWS2_BIN);
    return false;
}

function section_current_usable_cache_by_name(sections, section, default_user_agent) {
    return section_current_usable_cache(find_section(sections, section), TMP_SUBSCRIPTION_FOLDER, TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, default_user_agent);
}

function section_has_non_subscription_connection_sources(section) {
    return length(connections.connection_urls(section)) > 0 ||
        length(connections.interfaces(section)) > 0 ||
        length(connections.outbound_jsons(section)) > 0 ||
        connections.is_dpi_or_desync_only_section(section);
}

function subscription_download_target_section_is_ready(sections, download_section, startup_blocked_sections, default_user_agent) {
    download_section = as_string(download_section);
    if (download_section == "" || state_list_contains(startup_blocked_sections, download_section))
        return false;

    let section = find_section(sections, download_section);
    if (!bool_option(section, "enabled", true))
        return false;

    let action = option(section, "action", "");
    if (connections.is_connections_action(action)) {
        if (section_has_non_subscription_connection_sources(section))
            return true;
        if (section_current_usable_cache_by_name(sections, download_section, default_user_agent))
            return true;

        return false;
    }

    return provider_action_is_available(action);
}

function subscription_bootstrap_download_section_is_ready(sections, startup_blocked_sections, default_user_agent) {
    let any_target = false;

    for (let section_name_value in whitespace_values(startup_blocked_sections)) {
        let section = find_section(sections, section_name_value);
        let source_can_retry = false;

        for (let entry in connections.subscription_urls(section)) {
            let parsed = subscription_source_profile(section, entry);
            let download_section = as_string(object_or_empty(parsed).download_section);
            if (download_section == "" || download_section == section_name_value)
                continue;
            any_target = true;

            if (subscription_download_target_section_is_ready(sections, download_section, startup_blocked_sections, default_user_agent)) {
                source_can_retry = true;
                break;
            }
        }

        if (!source_can_retry)
            return false;
    }

    if (!any_target)
        log_message("Unavailable subscription-only rule(s) have no download-through-section target; deferring for background retry", "info");

    return any_target;
}

function cache_candidate_paths() {
    let result = [];
    for (let dir in [
        TMP_SUBSCRIPTION_FOLDER,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        TACHYON_SECTION_CACHE_DIR,
        TACHYON_SUBSCRIPTION_LINKS_DIR,
        TACHYON_SUBSCRIPTION_METADATA_DIR,
        TACHYON_OUTBOUND_METADATA_DIR
    ]) {
        let entries = fs.lsdir(dir);
        if (type(entries) != "array")
            continue;
        for (let entry in entries) {
            let path = dir + "/" + as_string(entry);
            let stat = fs.stat(path);
            if (stat != null && stat.type == "file")
                push(result, path);
        }
    }
    return result;
}

function prune_stale_subscription_caches_for_sections(sections) {
    ensure_runtime_dirs();
    let keep = cache_keep_sets(sections);

    for (let path in cache_candidate_paths()) {
        let cache_name = cache_name_from_file(path);
        if (cache_name == "")
            continue;

        let keep_names = keep_names_for_path(
            path,
            keep,
            TMP_SUBSCRIPTION_FOLDER,
            TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
            TACHYON_SECTION_CACHE_DIR,
            TACHYON_SUBSCRIPTION_LINKS_DIR,
            TACHYON_SUBSCRIPTION_METADATA_DIR,
            TACHYON_OUTBOUND_METADATA_DIR
        );
        if (!state_list_contains(keep_names, cache_name))
            unlink_path(path);
    }
}

function append_user_agent_candidate(result, seen, candidate, default_user_agent) {
    candidate = as_string(candidate);
    if (!user_agent_supported(candidate, default_user_agent) || seen[candidate])
        return;

    seen[candidate] = true;
    push(result, candidate);
}

function write_user_agent_candidates(path, configured_user_agent, preferred_user_agent, default_user_agent) {
    path = as_string(path);
    configured_user_agent = as_string(configured_user_agent);
    preferred_user_agent = as_string(preferred_user_agent);
    default_user_agent = as_string(default_user_agent);

    if (configured_user_agent != "") {
        if (!write_file(path, configured_user_agent + "\n"))
            exit(1);
        return;
    }

    let result = [];
    let seen = {};
    let candidates = [ preferred_user_agent, default_user_agent ];
    for (let profile in auto_user_agent_profiles)
        push(candidates, profile);

    for (let candidate in candidates)
        append_user_agent_candidate(result, seen, candidate, default_user_agent);

    if (!write_file(path, length(result) > 0 ? join("\n", result) + "\n" : ""))
        exit(1);
}

function write_empty_outbound_metadata() {
    write_stdout_json({
        names: {},
        countries: {},
        transports: {}
    });
}

function is_array(value) {
    return type(value) == "array";
}

function int_or_zero(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return 0;
    return int(value);
}

function count_label(count, singular, plural) {
    count = int(count || 0);
    return as_string(count) + " " + (count == 1 ? singular : plural);
}

function subscription_file_stats(path) {
    let value = object_or_empty(read_json(path));
    return {
        outbounds: length(array_or_empty(value.outbounds)),
        skipped: int_or_zero(value.skipped)
    };
}

function subscription_import_stats_text(path) {
    let stats = subscription_file_stats(path);
    let text = count_label(stats.outbounds, "proxy entry", "proxy entries");
    if (stats.skipped > 0)
        text += ", " + count_label(stats.skipped, "skipped entry", "skipped entries");
    return text;
}

function subscription_source_summary(section_name_value, source_index, normalized_path, result) {
    let prefix = "Subscription source " + as_string(source_index) + " for rule '" + as_string(section_name_value) + "'";
    let stats = subscription_import_stats_text(normalized_path);

    if (result == "unchanged")
        return prefix + " is unchanged: " + stats;
    if (result == "runtime-unchanged")
        return prefix + " refreshed: runtime proxy entries are unchanged (" + stats + ")";
    return prefix + " imported: " + stats;
}

function log_subscription_source_summary(section_name_value, source_index, normalized_path, result) {
    log_message(subscription_source_summary(section_name_value, source_index, normalized_path, result), "info");
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function valid_metadata_object(value) {
    return type(value) == "object" && object_key_count(value) > 1;
}

function json_length(path) {
    let value = read_json(path);
    if (type(value) == "array" || type(value) == "object")
        print(length(value), "\n");
    else
        print("0\n");
}

function object_has_extra_keys(path) {
    return object_key_count(read_json(path)) > 1;
}

function safe_section(section) {
    return type(section) == "string" && match(section, /^[A-Za-z0-9_-]+$/);
}

function cache_path(cache_dir, section) {
    return cache_dir + "/" + section + ".json";
}

function load_cache(cache_dir, section) {
    return object_or_empty(read_json(cache_path(cache_dir, section)));
}

function normalize_cache(cache, section, format_version) {
    cache.version = int(format_version || 0);
    cache.section = as_string(section);
    cache.links = object_or_empty(cache.links);
    cache.outboundMetadata = object_or_empty(cache.outboundMetadata);
    cache.outboundMetadata.names = object_or_empty(cache.outboundMetadata.names);
    cache.outboundMetadata.countries = object_or_empty(cache.outboundMetadata.countries);
    cache.outboundMetadata.transports = object_or_empty(cache.outboundMetadata.transports);
    cache.outboundMetadata.protocols = object_or_empty(cache.outboundMetadata.protocols);
    cache.outboundMetadata.securities = object_or_empty(cache.outboundMetadata.securities);
    cache.outboundMetadata.prefixes = object_or_empty(cache.outboundMetadata.prefixes);
    cache.outboundMetadata.ports = object_or_empty(cache.outboundMetadata.ports);
    cache.outboundMetadata.details = object_or_empty(cache.outboundMetadata.details);
    cache.outboundMetadata.sources = object_or_empty(cache.outboundMetadata.sources);
    cache.outboundMetadata.source_ids = object_or_empty(cache.outboundMetadata.source_ids);
    cache.outboundMetadata.source_names = object_or_empty(cache.outboundMetadata.source_names);
    cache.servers = object_or_empty(cache.servers);
    cache.urltestCandidateTags = array_or_empty(cache.urltestCandidateTags);
    cache.urltestGroups = object_or_empty(cache.urltestGroups);
    cache.priorityGroups = object_or_empty(cache.priorityGroups);
    cache.subscriptionMetadata = array_or_empty(cache.subscriptionMetadata);
    return cache;
}

function save_cache(cache_dir, section, format_version, cache) {
    cache = normalize_cache(cache, section, format_version);
    let path = cache_path(cache_dir, section);
    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);

    if (!write_json(tmp_path, cache))
        exit(1);
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        exit(1);
    }
}

function write_outbound_metadata(cache_dir, format_version, section, names_path, countries_path, servers_path) {
    let cache = load_cache(cache_dir, section);
    let previous_metadata = object_or_empty(cache.outboundMetadata);
    cache.outboundMetadata = {
        names: object_or_empty(read_json(names_path)),
        countries: object_or_empty(read_json(countries_path)),
        transports: object_or_empty(previous_metadata.transports),
        protocols: object_or_empty(previous_metadata.protocols),
        securities: object_or_empty(previous_metadata.securities),
        prefixes: object_or_empty(previous_metadata.prefixes),
        ports: object_or_empty(previous_metadata.ports),
        details: object_or_empty(previous_metadata.details),
        sources: object_or_empty(previous_metadata.sources),
        source_ids: object_or_empty(previous_metadata.source_ids),
        source_names: object_or_empty(previous_metadata.source_names)
    };
    cache.servers = object_or_empty(read_json(servers_path));
    save_cache(cache_dir, section, format_version, cache);
}

function metadata_array_from_file(metadata_path) {
    let metadata = read_json(metadata_path);
    let result = [];

    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function metadata_source_index(item) {
    if (type(item) != "object")
        return null;
    let value = item.sourceIndex != null ? item.sourceIndex : item.source_index;
    if (value == null || as_string(value) == "")
        return null;
    return int(value);
}

function metadata_source_section(item) {
    if (type(item) != "object")
        return "";
    return as_string(item.sourceSection != null ? item.sourceSection : item.source_section);
}

function metadata_items_have_source_markers(items) {
    for (let item in items) {
        if (metadata_source_index(item) != null || metadata_source_section(item) != "")
            return true;
    }
    return false;
}

function metadata_matches_source(item, source_index, source_section, has_source_markers) {
    if (!has_source_markers)
        return false;

    let item_section = metadata_source_section(item);
    let item_index = metadata_source_index(item);
    return (item_section != "" && item_section == source_section) ||
        (item_section == "" && item_index == source_index);
}

function merge_previous_metadata_fields(target_item, prev_item) {
    if (type(target_item) != "object" || type(prev_item) != "object")
        return target_item;
    for (let k in [ "title", "announce", "traffic", "expire", "webPageUrl", "supportUrl", "updatedAt" ]) {
        if ((target_item[k] == null || target_item[k] == "") && prev_item[k] != null && prev_item[k] != "")
            target_item[k] = prev_item[k];
    }
    return target_item;
}

function write_subscription_metadata(cache_dir, format_version, section, metadata_path) {
    let cache = load_cache(cache_dir, section);
    let prev_items = array_or_empty(cache.subscriptionMetadata);
    let next_items = metadata_array_from_file(metadata_path);
    if (length(next_items) == 0 && (metadata_path == null || metadata_path == "") && length(prev_items) > 0) {
        save_cache(cache_dir, section, format_version, cache);
        return;
    }
    let has_prev_markers = metadata_items_have_source_markers(prev_items);
    for (let idx, item in next_items) {
        let s_idx = metadata_source_index(item) || (idx + 1);
        let s_sec = metadata_source_section(item);
        for (let p_idx, p_item in prev_items) {
            let matched = has_prev_markers ?
                metadata_matches_source(p_item, s_idx, s_sec, true) :
                ((p_idx + 1) == s_idx);
            if (matched) {
                merge_previous_metadata_fields(item, p_item);
                break;
            }
        }
    }
    if (int(cache.version || 0) == int(format_version || 0) &&
        as_string(cache.section) == as_string(section) &&
        sprintf("%J", prev_items) == sprintf("%J", next_items))
        return;
    cache.subscriptionMetadata = next_items;
    save_cache(cache_dir, section, format_version, cache);
}

function read_metadata_items_from_cache(cache_dir, section, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let metadata = cache.subscriptionMetadata;

    if (type(metadata) != "array")
        metadata = read_json(legacy_path);

    let result = [];
    if (is_array(metadata)) {
        for (let item in metadata) {
            if (valid_metadata_object(item))
                push(result, item);
        }
    }
    else if (valid_metadata_object(metadata)) {
        push(result, metadata);
    }

    return result;
}

function attach_source_metadata(item, source_index, source_section) {
    if (type(item) != "object")
        item = {};
    item.sourceIndex = source_index;
    item.sourceSection = as_string(source_section);
    return item;
}

function append_metadata_file(array_path, metadata_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let metadata = read_json(metadata_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    if (valid_metadata_object(metadata)) {
        push(array, attach_source_metadata(metadata, source_index, source_section));
        write_json(array_path, array);
    }
}

function append_cached_metadata(array_path, cache_dir, section, legacy_path, source_index, source_section) {
    if (array_path == null || array_path == "")
        return;

    let array = array_or_empty(read_json(array_path));
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    let has_source_markers = metadata_items_have_source_markers(items);
    let selected = null;
    if (has_source_markers) {
        for (let item in items) {
            if (metadata_matches_source(item, source_index, source_section, true)) {
                selected = item;
                break;
            }
        }
    }
    else if (source_index > 0 && source_index <= length(items)) {
        selected = items[source_index - 1];
    }

    if (valid_metadata_object(selected)) {
        push(array, attach_source_metadata(selected, source_index, source_section));
        write_json(array_path, array);
    }
}

function write_source_metadata(cache_dir, format_version, section, source_index, source_section, metadata_path, legacy_path) {
    let cache = load_cache(cache_dir, section);
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    let kept = [];
    let previous_match = null;
    let has_source_markers = metadata_items_have_source_markers(items);
    source_index = int(source_index || 0);
    source_section = as_string(source_section);

    for (let index, item in items) {
        let keep = has_source_markers ?
            !metadata_matches_source(item, source_index, source_section, true) :
            (index + 1) != source_index;
        if (keep && valid_metadata_object(item))
            push(kept, item);
        else if (!keep && valid_metadata_object(item) && previous_match == null)
            previous_match = item;
    }

    let metadata = read_json(metadata_path);
    if (valid_metadata_object(metadata)) {
        if (previous_match != null)
            merge_previous_metadata_fields(metadata, previous_match);
        push(kept, attach_source_metadata(metadata, source_index, source_section));
    }
    else if (previous_match != null) {
        push(kept, attach_source_metadata(previous_match, source_index, source_section));
    }

    sort(kept, function(first, second) {
        let first_index = metadata_source_index(first) || 999999;
        let second_index = metadata_source_index(second) || 999999;
        return first_index == second_index ? 0 : (first_index < second_index ? -1 : 1);
    });

    cache.subscriptionMetadata = kept;
    save_cache(cache_dir, section, format_version, cache);
}

function merge_section_outbound_metadata(result, cache, legacy_path) {
    let metadata = cache.outboundMetadata;
    if (type(metadata) != "object" && legacy_path != null && legacy_path != "")
        metadata = read_json(legacy_path);
    metadata = object_or_empty(metadata);
    let names = object_or_empty(metadata.names);
    let countries = object_or_empty(metadata.countries);
    let transports = object_or_empty(metadata.transports);
    let protocols = object_or_empty(metadata.protocols);
    let securities = object_or_empty(metadata.securities);
    let prefixes = object_or_empty(metadata.prefixes);
    let ports = object_or_empty(metadata.ports);
    let candidate_tags = array_or_empty(cache.urltestCandidateTags);
    let groups = object_or_empty(cache.urltestGroups);
    let priority_groups = object_or_empty(cache.priorityGroups);

    if (length(candidate_tags) > 0) {
        for (let tag in candidate_tags) {
            tag = as_string(tag);
            if (tag == "")
                continue;
            if (names[tag] != null)
                result.names[tag] = names[tag];
            if (countries[tag] != null)
                result.countries[tag] = countries[tag];
            if (transports[tag] != null)
                result.transports[tag] = transports[tag];
            if (protocols[tag] != null)
                result.protocols[tag] = protocols[tag];
            if (securities[tag] != null)
                result.securities[tag] = securities[tag];
            if (prefixes[tag] != null)
                result.prefixes[tag] = prefixes[tag];
            if (ports[tag] != null)
                result.ports[tag] = ports[tag];
        }
    }
    else {
        for (let tag, name in names) {
            if (!groups[tag] && !priority_groups[tag])
                result.names[tag] = name;
        }
        for (let tag, country in countries) {
            if (!groups[tag] && !priority_groups[tag])
                result.countries[tag] = country;
        }
        for (let tag, transport in transports) {
            if (!groups[tag] && !priority_groups[tag])
                result.transports[tag] = transport;
        }
        for (let tag, proto in protocols) {
            if (!groups[tag] && !priority_groups[tag])
                result.protocols[tag] = proto;
        }
        for (let tag, sec in securities) {
            if (!groups[tag] && !priority_groups[tag])
                result.securities[tag] = sec;
        }
        for (let tag, pfx in prefixes) {
            if (!groups[tag] && !priority_groups[tag])
                result.prefixes[tag] = pfx;
        }
        for (let tag, prt in ports) {
            if (!groups[tag] && !priority_groups[tag])
                result.ports[tag] = prt;
        }
    }
}

function get_outbound_metadata(cache_dir, section, legacy_path) {
    let result = {
        names: {},
        countries: {},
        transports: {},
        protocols: {},
        securities: {},
        prefixes: {},
        ports: {}
    };
    let sec_str = trim(as_string(section));
    if (sec_str == "" || sec_str == "all") {
        let entries = fs.lsdir(as_string(cache_dir));
        if (type(entries) == "array") {
            for (let entry in entries) {
                entry = as_string(entry);
                if (length(entry) > 5 && substr(entry, length(entry) - 5) == ".json") {
                    let sname = substr(entry, 0, length(entry) - 5);
                    if (safe_section(sname)) {
                        let c = load_cache(cache_dir, sname);
                        merge_section_outbound_metadata(result, c, "");
                    }
                }
            }
        }
    }
    else {
        let cache = load_cache(cache_dir, sec_str);
        merge_section_outbound_metadata(result, cache, legacy_path);
    }

    write_stdout_json(result);
}

function get_subscription_metadata(cache_dir, section, legacy_path) {
    let items = read_metadata_items_from_cache(cache_dir, section, legacy_path);
    if (length(items) > 0)
        write_stdout_json(items);
    else
        print("{}\n");
}

function persistent_metadata_path(source_section) {
    return TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/" + as_string(source_section) + ".metadata.json";
}

function runtime_metadata_path(source_section) {
    return TMP_SUBSCRIPTION_FOLDER + "/" + as_string(source_section) + ".metadata.json";
}

function persist_subscription_cache(source_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_path, effective_device_headers_signature) {
    if (!cache_section_is_safe(source_section) || !subscription_cache_is_usable(subscription_json_path))
        return false;

    if (fs.stat(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR) == null) {
        ensure_dir(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR);
        chmod_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, "700");
    }

    let persistent_json = source_json_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_url = source_url_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_user_agent = source_user_agent_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_hwid = source_hwid_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_device_headers = source_device_headers_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, source_section);
    let persistent_metadata = persistent_metadata_path(source_section);
    let previous_url = read_text(persistent_url);
    let previous_user_agent = read_text(persistent_user_agent);
    let previous_hwid = read_text(persistent_hwid);
    let previous_device_headers = read_text(persistent_device_headers);
    let can_keep_previous_metadata = previous_url == as_string(subscription_url) &&
        previous_user_agent == as_string(effective_user_agent) &&
        previous_hwid == as_string(effective_hwid) &&
        previous_device_headers == as_string(effective_device_headers_signature) &&
        file_nonempty(persistent_metadata) &&
        object_has_extra_keys(persistent_metadata);

    if (!copy_file_if_changed(subscription_json_path, persistent_json) ||
        !write_text_if_changed(persistent_url, subscription_url) ||
        !write_text_if_changed(persistent_user_agent, effective_user_agent) ||
        !write_text_if_changed(persistent_hwid, effective_hwid) ||
        !write_text_if_changed(persistent_device_headers, effective_device_headers_signature))
        return false;

    let runtime_metadata = runtime_metadata_path(source_section);
    if (metadata_path != null && metadata_path != "" && file_nonempty(metadata_path) && object_has_extra_keys(metadata_path)) {
        if (!copy_file_if_changed(metadata_path, persistent_metadata))
            return false;
        if (ensure_dir(TACHYON_SUBSCRIPTION_METADATA_DIR))
            copy_file_if_changed(metadata_path, runtime_metadata);
    }
    else if (!can_keep_previous_metadata) {
        unlink_path(persistent_metadata);
        unlink_path(runtime_metadata);
    }
    else if (file_nonempty(persistent_metadata) && ensure_dir(TACHYON_SUBSCRIPTION_METADATA_DIR)) {
        copy_file_if_changed(persistent_metadata, runtime_metadata);
    }

    return true;
}

function append_persistent_source_metadata(array_path, source_index, source_section) {
    let metadata_path = runtime_metadata_path(source_section);
    if (!file_nonempty(metadata_path))
        metadata_path = persistent_metadata_path(source_section);
    if (!file_nonempty(metadata_path))
        return false;

    append_metadata_file(array_path, metadata_path, source_index, source_section);
    return true;
}

function append_available_cached_metadata(array_path, section, source_index, source_section) {
    if (array_path == null || array_path == "")
        return false;

    let before = length(array_or_empty(read_json(array_path)));
    append_persistent_source_metadata(array_path, source_index, source_section) ||
        append_cached_metadata(array_path, TACHYON_SECTION_CACHE_DIR, section, TACHYON_SUBSCRIPTION_METADATA_DIR + "/" + section + ".json", source_index, source_section);
    return length(array_or_empty(read_json(array_path))) > before;
}

function sing_box_version_from_output(output) {
    let first = split(as_string(output), "\n")[0] || "";
    let fields = whitespace_values(first);
    return length(fields) > 0 ? fields[length(fields) - 1] : "";
}

function get_sing_box_version() {
    let version_state = trim(as_string(fs.readfile(SB_VERSION_STATE_FILE)));
    if (version_state != "")
        return version_state;

    let bin = command_success_from_args([ "sh", "-c", "command -v tachyon-core" ]) ? "tachyon-core" :
        (command_success_from_args([ "sh", "-c", "command -v sing-box" ]) ? "sing-box" : "");
    if (bin == "")
        return "";

    let v = sing_box_version_from_output(command_output_from_args([ bin, "version" ]));
    if (v != "")
        write_file(SB_VERSION_STATE_FILE, v + "\n");
    return v;
}

function get_subscription_user_agent(custom_user_agent) {
    custom_user_agent = as_string(custom_user_agent);
    if (custom_user_agent != "")
        return custom_user_agent;

    let version = get_sing_box_version();
    return "sing-box/" + (version != "" ? version : "unknown");
}

function user_agent_candidates(configured_user_agent, preferred_user_agent, default_user_agent) {
    configured_user_agent = as_string(configured_user_agent);
    if (configured_user_agent != "")
        return [ configured_user_agent ];

    let result = [];
    let seen = {};

    let candidates = [ preferred_user_agent, default_user_agent ];
    for (let profile in auto_user_agent_profiles)
        push(candidates, profile);

    for (let candidate in candidates) {
        candidate = as_string(candidate);
        if (user_agent_supported(candidate, default_user_agent) && !seen[candidate]) {
            seen[candidate] = true;
            push(result, candidate);
        }
    }

    return result;
}

function get_subscription_hwid(custom_hwid) {
    custom_hwid = as_string(custom_hwid);
    return custom_hwid != "" ? custom_hwid : generate_hwid();
}

function download_subscription(url, filepath, http_proxy_address, headers_filepath, effective_user_agent, effective_hwid, device_headers, allow_insecure) {
    _last_download_transport_failed = false;
    // An encrypted link usually wraps an HTTP URL, not the subscription body.
    // Bound nesting and retain the configured device headers/TLS/proxy policy
    // when downloading that URL. Do not change the cache's original source ID.
    for (let depth = 0; happ.is_encrypted(url); depth++) {
        if (depth >= 2)
            return 1;
        let dec = happ.decrypt(url, effective_hwid, generate_hwid());
        if (dec == null || dec == "")
            return 1;
        dec = trim(dec);
        if (match(dec, /^https?:\/\//i) || happ.is_encrypted(dec)) {
            url = dec;
            continue;
        }
        // Keep support for encrypted inline proxy lists/configuration bodies.
        if (dec != "") {
            let stamp = clock();
            let suffix = sprintf(".part.%d.%d", stamp[0], stamp[1]);
            let tmpfile = filepath + suffix;
            if (fs.writefile(tmpfile, dec)) {
                move_file(tmpfile, filepath);
                if (headers_filepath != "")
                    unlink_path(headers_filepath);
                return 0;
            }
        }
        return 1;
    }

    // Never pass an unsupported Happ scheme to curl or a non-HTTP protocol
    // recovered from an encrypted link to the transport layer.
    if (!match(url, /^https?:\/\//i))
        return 1;

    let retries = 3;
    let wait_seconds = 1;
    let timeout = 8;
    let stamp = clock();
    let suffix = sprintf(".part.%d.%d", stamp[0], stamp[1]);
    let tmpfile = filepath + suffix;
    let headers_tmpfile = headers_filepath != "" ? headers_filepath + suffix : "";
    let resolution_failed = false;
    let saw_transport_failure = false;
    let saw_http_or_other_failure = false;
    _last_download_transport_failed = false;

    unlink_path(tmpfile);
    if (headers_tmpfile != "")
        unlink_path(headers_tmpfile);

    let core_url_mod = core_url_module_or_null();
    let candidates = core_url_mod && type(core_url_mod.download_candidates) == "function" ? core_url_mod.download_candidates(url) : [ url ];

    for (let target_url in candidates) {
        let doh_retry_index = 0;
        let force_http11 = false;
        for (let attempt = 1; attempt <= retries; attempt++) {
            let args = [
                "curl", "-fL", "-s",
                "--connect-timeout", timeout,
                "--max-time", "15",
                "--speed-time", timeout,
                "--speed-limit", "1",
                "--max-redirs", "5",
                "-b", "/dev/null",
                "--max-filesize", "15728640"
            ];
            if (force_http11)
                push(args, "--http1.1");

            let active_doh_url = "";
            if (http_proxy_address != "") {
                push(args, "-x");
                push(args, "http://" + http_proxy_address);
            } else {
                // Bootstrap DNS: use public resolvers only when c-ares is present
                // or after system DNS fails to resolve the host (#387).
                active_doh_url = curl_push_dns_servers(args, doh_retry_index);
            }
            if (bool_value(allow_insecure, false))
                push(args, "-k");
            if (headers_tmpfile != "") {
                push(args, "-D");
                push(args, headers_tmpfile);
            }

            push(args, "-o");
            push(args, tmpfile);
            let hwid_val = get_subscription_hwid(effective_hwid);
            let request_headers = [
                "User-Agent: " + get_subscription_user_agent(effective_user_agent),
                "X-HWID: " + hwid_val,
                "HWID: " + hwid_val
            ];
            for (let header in device_request_headers(device_headers))
                push(request_headers, header);
            for (let header in request_headers) {
                push(args, "-H");
                push(args, header);
            }
            push(args, "--write-out", "%{http_code}");
            push(args, target_url);

            let response = common.command_capture(command_from_args(args));
            let status = response == null ? 1 : response.status;
            let http_status = response == null ? 0 : int(response.output);
            if (status == 0 && file_nonempty(tmpfile)) {
                if (active_doh_url != "")
                    _curl_working_doh_url = active_doh_url;
                let downloaded_body = fs.readfile(tmpfile);
                if (downloaded_body != null && headers_tmpfile != "" && file_nonempty(headers_tmpfile) && type(happ.decrypt_response_body) == "function") {
                    let dec_body = happ.decrypt_response_body(downloaded_body, target_url, read_text(headers_tmpfile));
                    if (dec_body != null && dec_body != "" && dec_body != downloaded_body) {
                        fs.writefile(tmpfile, dec_body);
                        downloaded_body = dec_body;
                    }
                }
                if (downloaded_body != null && happ.is_encrypted(downloaded_body)) {
                    let dec = happ.decrypt(downloaded_body, effective_hwid, generate_hwid());
                    if (dec != null && dec != "")
                        fs.writefile(tmpfile, dec);
                }
                move_file(tmpfile, filepath);
                if (headers_filepath != "") {
                    if (file_nonempty(headers_tmpfile))
                        move_file(headers_tmpfile, headers_filepath);
                    else {
                        unlink_path(headers_filepath);
                        unlink_path(headers_tmpfile);
                    }
                }
                return 0;
            }

            unlink_path(tmpfile);
            unlink_path(headers_tmpfile);

            // Cloudflare Workers / Anycast edges can return HTTP 421 on HTTP/2 SNI
            // coalescing or packet-desynchronization collisions; retry once over HTTP/1.1.
            if (status == 22 && http_status == 421 && !force_http11 && attempt < retries) {
                force_http11 = true;
                saw_http_or_other_failure = true;
                continue;
            }

            // Provider subscriptions and Worker reverse proxies often reject non-matching
            // client User-Agent profiles with 400/401/403/404/406/421. Fail fast on single
            // URLs so download_subscription_into_cache rotates to Happ/v2rayNG immediately.
            if (status == 22 && http_status >= 400 && http_status < 500 && http_status != 408 && http_status != 429) {
                if (length(candidates) == 1)
                    return 22;
                saw_http_or_other_failure = true;
                break;
            }

            if (status == 5) {
                // Proxy/SSL tunnel failure — no point retrying this URL
                resolution_failed = true;
                saw_transport_failure = true;
                break;
            }

            if (status == 6) {
                // DNS resolution failure: switch to DoH fallback resolvers immediately
                // on the first failure, then back off if all resolvers are transiently down (#24, #387).
                saw_transport_failure = true;
                if (http_proxy_address == "")
                    doh_retry_index++;
                if (attempt < retries) {
                    if (doh_retry_index <= 1 && http_proxy_address == "") {
                        log_message("Subscription DNS resolution failed via system resolver; retrying via fallback DoH resolver", "debug");
                        continue;
                    }
                    let dns_wait = attempt * 3;
                    log_message("Subscription DNS resolution failed for rule; retrying in " + dns_wait + "s (attempt " + attempt + "/" + retries + ")", "debug");
                    system("sleep " + dns_wait);
                    continue;
                }
                resolution_failed = true;
                break;
            }

            if (status == 7 || status == 28 || status == 35 || status == 52 || status == 56) {
                saw_transport_failure = true;
                if (attempt >= 2)
                    break;
            } else {
                saw_http_or_other_failure = true;
            }

            if (attempt < retries)
                system("sleep " + int(wait_seconds));
        }
    }

    unlink_path(tmpfile);
    unlink_path(headers_tmpfile);
    _last_download_transport_failed = (saw_transport_failure && !saw_http_or_other_failure);
    return resolution_failed ? 6 : 1;
}

function subscription_update_timestamp_path(section_name_value) {
    return TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR + "/" + as_string(section_name_value) + ".timestamp";
}

function current_timestamp_value() {
    let value = trim(command_output_from_args([ "date", "+%s" ]));
    return unsigned_number(value) == null ? "" : value;
}

function write_subscription_update_timestamp(section_name_value) {
    let timestamp = current_timestamp_value();
    if (timestamp == "")
        return;

    ensure_dir(TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR);
    write_file(subscription_update_timestamp_path(section_name_value), timestamp + "\n");
}

function copy_valid_metadata_output(metadata_tmpfile, metadata_output_path) {
    if (metadata_output_path == null || metadata_output_path == "")
        return;

    if (file_nonempty(metadata_tmpfile) && object_has_extra_keys(metadata_tmpfile))
        copy_file(metadata_tmpfile, metadata_output_path) || unlink_path(metadata_output_path);
    else
        unlink_path(metadata_output_path);
}

function copy_persistent_metadata_output(source_section, metadata_output_path) {
    if (metadata_output_path == null || metadata_output_path == "")
        return;

    let metadata_path = runtime_metadata_path(source_section);
    if (!file_nonempty(metadata_path))
        metadata_path = persistent_metadata_path(source_section);
    if (file_nonempty(metadata_path) && object_has_extra_keys(metadata_path))
        copy_file(metadata_path, metadata_output_path) || unlink_path(metadata_output_path);
}

function stamp_runtime_metadata_output(source_section, metadata_output_path) {
    write_subscription_update_timestamp(source_section);
    let now_str = current_timestamp_value();
    let now_ts = now_str != "" ? int(now_str) : int(time() || 0);
    if (now_ts <= 0)
        return;
    let runtime_meta = runtime_metadata_path(source_section);
    let persistent_meta = persistent_metadata_path(source_section);
    let obj = {};
    for (let candidate_path in [ persistent_meta, runtime_meta, metadata_output_path ]) {
        if (candidate_path == null || candidate_path == "" || !file_nonempty(candidate_path))
            continue;
        let parsed = read_json(candidate_path);
        if (type(parsed) == "object") {
            for (let k, v in parsed) {
                if (v != null && v != "")
                    obj[k] = v;
            }
        }
    }
    obj.version = 1;
    obj.updatedAt = now_ts;
    if (ensure_dir(TMP_SUBSCRIPTION_FOLDER))
        write_json(runtime_meta, obj);
    if (metadata_output_path != null && metadata_output_path != "")
        write_json(metadata_output_path, obj);
}

function subscription_config_is_current(section_name_value, subscription_url, subscription_user_agent, subscription_hwid, sections, subscription_device_headers_signature) {
    let section = find_section(sections, section_name_value);
    for (let entry in connections.subscription_urls(section)) {
        let parsed = subscription_source_profile(section, entry);
        if (type(parsed) == "object" && parsed.valid === true &&
            as_string(parsed.url) == as_string(subscription_url) &&
            as_string(parsed.user_agent) == as_string(subscription_user_agent) &&
            as_string(parsed.hwid) == as_string(subscription_hwid) &&
            (subscription_device_headers_signature == null || as_string(parsed.device_headers_signature) == as_string(subscription_device_headers_signature)))
            return true;
    }

    return false;
}

function get_subscription_download_proxy_address(section_name_value, sections, parsed, phase) {
    let download_section = as_string(object_or_empty(parsed).download_section);
    if (download_section == "")
        return "";

    let is_self = (download_section == as_string(section_name_value));

    if (!sing_box_service_running()) {
        if (phase == "startup")
            log_message("Subscription source for rule '" + section_name_value + "' is configured to download via rule '" + download_section + "', but sing-box is not running yet; downloading it directly during startup", "warn");
        else
            log_message("Subscription source for rule '" + section_name_value + "' is configured to download via rule '" + download_section + "', but sing-box service proxy is not running; downloading it directly", "warn");
        return "";
    }

    let port = connections.subscription_download_target_port(sections, download_section, int(SB_SERVICE_MIXED_INBOUND_PORT));
    if (port <= 0) {
        if (is_self)
            port = int(SB_SERVICE_MIXED_INBOUND_PORT);
        else
            return "";
    }

    let address = SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(port);
    // Verify the proxy port is actually accepting connections — the sing-box
    // process may be running but the mixed inbound not yet ready after a
    // component update restart.
    let probe_status = command_status_from_args([
        "curl", "-s", "--connect-timeout", "2", "-m", "4",
        "-x", "http://" + address, "http://1.1.1.1/", "-o", "/dev/null"
    ]);
    if (probe_status == 7 || probe_status == 28) {
        log_message("Subscription source for rule '" + section_name_value +
            "' is configured to download via rule '" + download_section +
            "', but service proxy is not yet accepting connections; downloading directly", "warn");
        return "";
    }
    log_message("Downloading subscription for rule '" + section_name_value + "' via service proxy " + address, "debug");
    return address;
}

function finalize_downloaded_subscription_cache(
    section_name_value,
    subscription_url,
    subscription_json_path,
    subscription_url_cache_path,
    subscription_user_agent_cache_path,
    subscription_hwid_cache_path,
    subscription_device_headers_cache_path,
    raw_tmpfile,
    headers_tmpfile,
    normalized_tmpfile,
    metadata_tmpfile,
    metadata_output_path,
    subscription_user_agent,
    subscription_hwid,
    effective_user_agent,
    effective_hwid,
    subscription_device_headers_signature,
    source_index,
    cache_section,
    sections,
    parser
) {
    if (!subscription_share_link.populate_subscription_file(normalized_tmpfile))
        log_message("Failed to cache direct proxy links for subscription rule '" + section_name_value + "'", "warn");

    if (!subscription_config_is_current(section_name_value, subscription_url, subscription_user_agent, subscription_hwid, sections, subscription_device_headers_signature)) {
        log_message("Subscription source settings changed while updating rule '" + section_name_value + "'; discarding superseded download", "warn");
        if (metadata_output_path != "")
            unlink_path(metadata_output_path);
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(normalized_tmpfile);
        unlink_path(metadata_tmpfile);
        return 4;
    }

    if (files_equal(normalized_tmpfile, subscription_json_path)) {
        write_text_if_changed(subscription_url_cache_path, subscription_url);
        write_text_if_changed(subscription_user_agent_cache_path, effective_user_agent);
        write_text_if_changed(subscription_hwid_cache_path, effective_hwid);
        write_text_if_changed(subscription_device_headers_cache_path, subscription_device_headers_signature);
        persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile, subscription_device_headers_signature) ||
            log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
        if (!file_nonempty(metadata_output_path))
            copy_persistent_metadata_output(cache_section, metadata_output_path);
        stamp_runtime_metadata_output(cache_section, metadata_output_path);
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(normalized_tmpfile);
        unlink_path(metadata_tmpfile);
        log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "unchanged");
        return 2;
    }

    if (file_nonempty(subscription_json_path) && parser.runtime_outbounds_equal(normalized_tmpfile, subscription_json_path)) {
        // Keep the current file and running outbound ordering. The newly downloaded file
        // differs only in provider node ordering or metadata ignored by runtime comparison,
        // neither of which should churn the on-disk file or trigger a sing-box reload.
        unlink_path(normalized_tmpfile);

        write_text_if_changed(subscription_url_cache_path, subscription_url);
        write_text_if_changed(subscription_user_agent_cache_path, effective_user_agent);
        write_text_if_changed(subscription_hwid_cache_path, effective_hwid);
        write_text_if_changed(subscription_device_headers_cache_path, subscription_device_headers_signature);
        persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile, subscription_device_headers_signature) ||
            log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
        if (!file_nonempty(metadata_output_path))
            copy_persistent_metadata_output(cache_section, metadata_output_path);
        stamp_runtime_metadata_output(cache_section, metadata_output_path);
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(metadata_tmpfile);
        log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "runtime-unchanged");
        return 2;
    }

    if (file_nonempty(subscription_json_path) && subscription_shrink_guard_triggers(subscription_json_path, normalized_tmpfile)) {
        let old_usable = usable_subscription_outbound_count(subscription_json_path);
        let new_usable = usable_subscription_outbound_count(normalized_tmpfile);
        log_message(
            "Subscription source " + source_index + " for rule '" + section_name_value +
                "' shrank from " + old_usable + " to " + new_usable +
                " usable proxy entries; keeping the previous cache",
            "warn"
        );
        write_text_if_changed(subscription_url_cache_path, subscription_url);
        write_text_if_changed(subscription_user_agent_cache_path, effective_user_agent);
        write_text_if_changed(subscription_hwid_cache_path, effective_hwid);
        write_text_if_changed(subscription_device_headers_cache_path, subscription_device_headers_signature);
        persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile, subscription_device_headers_signature) ||
            log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
        if (metadata_output_path != "")
            unlink_path(metadata_output_path);
        copy_persistent_metadata_output(cache_section, metadata_output_path);
        stamp_runtime_metadata_output(cache_section, metadata_output_path);
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(normalized_tmpfile);
        unlink_path(metadata_tmpfile);
        log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "unchanged");
        return 2;
    }

    if (!move_file(normalized_tmpfile, subscription_json_path)) {
        if (metadata_output_path != "")
            unlink_path(metadata_output_path);
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(metadata_tmpfile);
        return 1;
    }

    write_text_if_changed(subscription_url_cache_path, subscription_url);
    write_text_if_changed(subscription_user_agent_cache_path, effective_user_agent);
    write_text_if_changed(subscription_hwid_cache_path, effective_hwid);
    write_text_if_changed(subscription_device_headers_cache_path, subscription_device_headers_signature);
    persist_subscription_cache(cache_section, subscription_json_path, subscription_url, effective_user_agent, effective_hwid, metadata_tmpfile, subscription_device_headers_signature) ||
        log_message("Failed to persist last working subscription cache for source '" + cache_section + "'", "warn");
    if (!file_nonempty(metadata_output_path))
        copy_persistent_metadata_output(cache_section, metadata_output_path);
    stamp_runtime_metadata_output(cache_section, metadata_output_path);
    unlink_path(raw_tmpfile);
    unlink_path(headers_tmpfile);
    unlink_path(metadata_tmpfile);
    log_subscription_source_summary(section_name_value, source_index, subscription_json_path, "imported");
    return 0;
}

function try_fetch_subscription_with_core(
    section_name_value,
    subscription_url,
    subscription_json_path,
    subscription_url_cache_path,
    subscription_user_agent_cache_path,
    subscription_hwid_cache_path,
    subscription_device_headers_cache_path,
    raw_tmpfile,
    headers_tmpfile,
    normalized_tmpfile,
    metadata_tmpfile,
    metadata_output_path,
    subscription_user_agent,
    subscription_hwid,
    subscription_device_headers_signature,
    source_index,
    cache_section,
    sections,
    allow_insecure,
    parser
) {
    if (type(parser.core_subscription_cli_supported) != "function" || !parser.core_subscription_cli_supported())
        return -1;
    if (subscription_device_headers_signature != "")
        return -1;

    let core_bin = as_string(getenv("TACHYON_CORE_BIN") || "/usr/bin/tachyon-core");
    let full_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "core-full");
    let effective_hwid = get_subscription_hwid(subscription_hwid);
    let cached_ua = trim(as_string(read_text(subscription_user_agent_cache_path)));
    let args = [ core_bin, "subscription", "fetch", subscription_url, "--format", "full", "-o", full_tmpfile ];
    if (subscription_user_agent != "") {
        push(args, "--ua");
        push(args, get_subscription_user_agent(subscription_user_agent));
    } else if (cached_ua != "") {
        push(args, "--ua");
        push(args, cached_ua);
    }
    if (effective_hwid != "") {
        push(args, "--hwid");
        push(args, effective_hwid);
    }
    if (bool_value(allow_insecure, false))
        push(args, "-k");

    unlink_path(full_tmpfile);
    let fetch_cap = common.command_capture(command_from_args(args) + " 2>/dev/null");
    if (fetch_cap == null || int(fetch_cap.status) != 0) {
        unlink_path(full_tmpfile);
        return -1;
    }

    let full_obj = read_json(full_tmpfile);
    unlink_path(full_tmpfile);
    if (type(full_obj) != "object" || type(full_obj.outbounds) != "array" || length(full_obj.outbounds) == 0)
        return -1;

    unlink_path(raw_tmpfile);
    unlink_path(headers_tmpfile);
    unlink_path(normalized_tmpfile);
    unlink_path(metadata_tmpfile);

    let effective_user_agent = as_string(full_obj.user_agent || get_subscription_user_agent(subscription_user_agent));
    let header_lines = [];
    if (type(full_obj.user_info) == "object") {
        let ui = full_obj.user_info;
        let parts = [];
        let up = ui.Upload != null ? ui.Upload : ui.Upload;
        up = ui.Upload != null ? ui.Upload : ui.upload;
        let dl = ui.Download != null ? ui.Download : ui.download;
        let tot = ui.Total != null ? ui.Total : ui.total;
        let exp = ui.Expire != null ? ui.Expire : ui.expire;
        if (up != null) push(parts, "upload=" + as_string(up));
        if (dl != null) push(parts, "download=" + as_string(dl));
        if (tot != null) push(parts, "total=" + as_string(tot));
        if (exp != null) push(parts, "expire=" + as_string(exp));
        if (length(parts) > 0)
            push(header_lines, "Subscription-Userinfo: " + join("; ", parts));
    }
    if (type(full_obj.metadata) == "object") {
        let md = full_obj.metadata;
        let clean_title = trim(replace(as_string(md.profile_title || ""), /[\r\n]+/g, " "));
        let raw_announce = trim(replace(as_string(md.announce || ""), /\r\n/g, "\n"));
        let clean_announce = index(raw_announce, "\n") >= 0
            ? ("base64:" + b64enc(raw_announce))
            : trim(replace(raw_announce, /[\r\n]+/g, " "));
        if (clean_title != "")
            push(header_lines, "Profile-Title: " + clean_title);
        if (md.update_interval_hours != null && as_string(md.update_interval_hours) != "")
            push(header_lines, "Profile-Update-Interval: " + as_string(md.update_interval_hours));
        if (as_string(md.support_url || "") != "")
            push(header_lines, "Support-Url: " + as_string(md.support_url));
        if (as_string(md.web_page_url || "") != "")
            push(header_lines, "Profile-Web-Page-Url: " + as_string(md.web_page_url));
        if (clean_announce != "")
            push(header_lines, "Announce: " + clean_announce);
        if (as_string(md.announce_url || "") != "")
            push(header_lines, "Announce-Url: " + as_string(md.announce_url));
        if (md.refill_date != null && as_string(md.refill_date) != "")
            push(header_lines, "Subscription-Refill-Date: " + as_string(md.refill_date));
        if (as_string(md.file_name || "") != "")
            push(header_lines, "Content-Disposition: attachment; filename=\"" + replace(as_string(md.file_name), /"/g, "") + "\"");
    }
    write_file(headers_tmpfile, length(header_lines) > 0 ? (join("\r\n", header_lines) + "\r\n") : "");

    let raw_body = type(full_obj.raw_body) == "string" ? full_obj.raw_body : "";
    let requires_ucode = (raw_body != "" && (index(raw_body, "fptn:") >= 0 || index(raw_body, "fptnb:") >= 0));
    write_file(raw_tmpfile, raw_body);
    parser.extract_ui_metadata_file(headers_tmpfile, raw_tmpfile, metadata_tmpfile) || unlink_path(metadata_tmpfile);
    copy_valid_metadata_output(metadata_tmpfile, metadata_output_path);

    let normalized_ok = false;
    if (!requires_ucode && type(full_obj.outbounds) == "array" && length(full_obj.outbounds) > 0) {
        let fallback_peer = parser.extract_peer_params_from_headers_file(headers_tmpfile);
        let outbounds = parser.normalize_sing_box_json_outbounds(full_obj.outbounds, fallback_peer);
        if (length(outbounds) > 0) {
            let norm_payload = {
                version: 1,
                format: "sing-box-json",
                outbounds: outbounds
            };
            if (common.write_json_file(normalized_tmpfile, norm_payload) && parser.validate_subscription(normalized_tmpfile))
                normalized_ok = true;
        }
    }
    if (!normalized_ok && raw_body != "")
        normalized_ok = parser.normalize_content_validated(raw_tmpfile, normalized_tmpfile, headers_tmpfile, "core");
    if (!normalized_ok) {
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(normalized_tmpfile);
        unlink_path(metadata_tmpfile);
        return -1;
    }

    return finalize_downloaded_subscription_cache(
        section_name_value,
        subscription_url,
        subscription_json_path,
        subscription_url_cache_path,
        subscription_user_agent_cache_path,
        subscription_hwid_cache_path,
        subscription_device_headers_cache_path,
        raw_tmpfile,
        headers_tmpfile,
        normalized_tmpfile,
        metadata_tmpfile,
        metadata_output_path,
        subscription_user_agent,
        subscription_hwid,
        effective_user_agent,
        effective_hwid,
        subscription_device_headers_signature,
        source_index,
        cache_section,
        sections,
        parser
    );
}

function download_subscription_into_cache(section_name_value, subscription_url, subscription_json_path, subscription_url_cache_path, service_proxy_address_value, subscription_user_agent, subscription_hwid, source_index, cache_section, metadata_output_path, sections, subscription_device_headers, allow_insecure, subscription_engine_mode) {
    ensure_dir(TMP_SUBSCRIPTION_FOLDER);
    let subscription_user_agent_cache_path = source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let subscription_hwid_cache_path = source_hwid_path(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let subscription_device_headers_cache_path = source_device_headers_path(TMP_SUBSCRIPTION_FOLDER, cache_section);
    let raw_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "download");
    let headers_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "headers");
    let normalized_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "normalized");
    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, cache_section, "metadata");
    let cached_user_agent = read_text(subscription_user_agent_cache_path);
    let default_user_agent = get_subscription_user_agent("");
    let parser = subscription_parser();
    let effective_engine = lc(trim(as_string(subscription_engine_mode || connections.subscription_engine(find_section(sections, section_name_value), subscription_url))));
    let subscription_device_headers_signature = connections.device_headers_signature(subscription_device_headers, effective_engine);

    let can_use_core_fetch = as_string(service_proxy_address_value) == "" &&
        !object_or_empty(subscription_device_headers).enabled;
    if (effective_engine == "core" && can_use_core_fetch) {
        let core_res = try_fetch_subscription_with_core(
            section_name_value,
            subscription_url,
            subscription_json_path,
            subscription_url_cache_path,
            subscription_user_agent_cache_path,
            subscription_hwid_cache_path,
            subscription_device_headers_cache_path,
            raw_tmpfile,
            headers_tmpfile,
            normalized_tmpfile,
            metadata_tmpfile,
            metadata_output_path,
            subscription_user_agent,
            subscription_hwid,
            subscription_device_headers_signature,
            source_index,
            cache_section,
            sections,
            allow_insecure,
            parser
        );
        if (core_res >= 0)
            return core_res;
    }

    let attempt_index = 0;
    let deferred_proxy_fallback = false;
    let prefer_fallback_proxy = false;
    for (let effective_user_agent in user_agent_candidates(subscription_user_agent, cached_user_agent, default_user_agent)) {
        attempt_index++;
        unlink_path(raw_tmpfile);
        unlink_path(headers_tmpfile);
        unlink_path(normalized_tmpfile);
        unlink_path(metadata_tmpfile);

        let effective_hwid = get_subscription_hwid(subscription_hwid);
        let fallback_proxy = SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + SB_SERVICE_MIXED_INBOUND_PORT;
        let primary_proxy = (service_proxy_address_value == "" && prefer_fallback_proxy && sing_box_service_running())
            ? fallback_proxy
            : service_proxy_address_value;
        let download_status = download_subscription(subscription_url, raw_tmpfile, primary_proxy, headers_tmpfile, effective_user_agent, effective_hwid, subscription_device_headers, allow_insecure);
        let direct_transport_failed = (primary_proxy == "") ? _last_download_transport_failed : true;
        if (download_status != 0 && primary_proxy == "" && service_proxy_address_value == "" && sing_box_service_running()) {
            if (download_status == 22 && subscription_user_agent == "") {
                // Try the other direct client profiles before a potentially
                // slow proxy retry. Keep proxy fallback for IP-based rejection.
                deferred_proxy_fallback = true;
            }
            else {
                log_message("Direct subscription download failed for rule '" + section_name_value + "'; retrying via active service proxy " + fallback_proxy, "info");
                download_status = download_subscription(subscription_url, raw_tmpfile, fallback_proxy, headers_tmpfile, effective_user_agent, effective_hwid, subscription_device_headers, allow_insecure);
                if (direct_transport_failed && !_last_download_transport_failed)
                    prefer_fallback_proxy = true;
            }
        }
        if (download_status != 0) {
            if (metadata_output_path != "")
                unlink_path(metadata_output_path);
            if (download_status == 6) {
                log_message("Subscription download failed for rule '" + section_name_value + "' because the subscription host could not be resolved; compatibility retries skipped", "warn");
                break;
            }
            else if (direct_transport_failed && _last_download_transport_failed) {
                log_message("Subscription download failed for rule '" + section_name_value + "' due to connection/timeout error; skipping User-Agent compatibility retries", "warn");
                break;
            }
            else if (subscription_user_agent != "")
                log_message("Subscription download failed for rule '" + section_name_value + "' with the configured request profile", "warn");
            else
                log_message("Subscription download attempt " + attempt_index + " failed for rule '" + section_name_value + "'; trying another compatibility profile", "warn");
            continue;
        }

        if (parser.try_decode_gzip_content_file(raw_tmpfile))
            log_message("Decoded gzip-compressed subscription body for rule '" + section_name_value + "'", "info");

        parser.extract_ui_metadata_file(headers_tmpfile, raw_tmpfile, metadata_tmpfile) || unlink_path(metadata_tmpfile);
        copy_valid_metadata_output(metadata_tmpfile, metadata_output_path);

        if (!parser.normalize_content_validated(raw_tmpfile, normalized_tmpfile, headers_tmpfile, effective_engine)) {
            if (metadata_output_path != "")
                unlink_path(metadata_output_path);
            let norm_err = type(parser.get_last_normalize_error) == "function" ? parser.get_last_normalize_error() : "";
            if (norm_err == "incomplete_awg_missing_peer") {
                log_message("AmneziaWG subscription for rule '" + section_name_value + "' contains [Interface] without [Peer] server parameters (Endpoint/PublicKey); provider returned an incomplete/proprietary client profile — skipping User-Agent retries", "error");
                break;
            }
            if (subscription_user_agent != "")
                log_message("Downloaded subscription for rule '" + section_name_value + "' is invalid with the configured request profile", "error");
            else
                log_message("Downloaded subscription for rule '" + section_name_value + "' is invalid; trying another compatibility profile", "warn");
            continue;
        }

        return finalize_downloaded_subscription_cache(
            section_name_value,
            subscription_url,
            subscription_json_path,
            subscription_url_cache_path,
            subscription_user_agent_cache_path,
            subscription_hwid_cache_path,
            subscription_device_headers_cache_path,
            raw_tmpfile,
            headers_tmpfile,
            normalized_tmpfile,
            metadata_tmpfile,
            metadata_output_path,
            subscription_user_agent,
            subscription_hwid,
            effective_user_agent,
            effective_hwid,
            subscription_device_headers_signature,
            source_index,
            cache_section,
            sections,
            parser
        );
    }

    if (metadata_output_path != "")
        unlink_path(metadata_output_path);
    unlink_path(raw_tmpfile);
    unlink_path(headers_tmpfile);
    unlink_path(normalized_tmpfile);
    unlink_path(metadata_tmpfile);
    if (effective_engine != "core" && can_use_core_fetch) {
        let core_res = try_fetch_subscription_with_core(
            section_name_value,
            subscription_url,
            subscription_json_path,
            subscription_url_cache_path,
            subscription_user_agent_cache_path,
            subscription_hwid_cache_path,
            subscription_device_headers_cache_path,
            raw_tmpfile,
            headers_tmpfile,
            normalized_tmpfile,
            metadata_tmpfile,
            metadata_output_path,
            subscription_user_agent,
            subscription_hwid,
            subscription_device_headers_signature,
            source_index,
            cache_section,
            sections,
            allow_insecure,
            parser
        );
        if (core_res >= 0)
            return core_res;
    }
    if (deferred_proxy_fallback && sing_box_service_running()) {
        let fallback_proxy = SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + SB_SERVICE_MIXED_INBOUND_PORT;
        log_message("Direct subscription client profiles failed for rule '" + section_name_value + "'; retrying via active service proxy " + fallback_proxy, "info");
        return download_subscription_into_cache(section_name_value, subscription_url, subscription_json_path,
            subscription_url_cache_path, fallback_proxy, subscription_user_agent, subscription_hwid,
            source_index, cache_section, metadata_output_path, sections, subscription_device_headers, allow_insecure, effective_engine);
    }
    if (subscription_user_agent != "")
        log_message("Configured subscription request profile for rule '" + section_name_value + "' did not produce valid proxy entries", "error");
    else
        log_message("No compatible subscription request profile produced valid proxy entries for rule '" + section_name_value + "'", "error");
    return 1;
}

function cached_source_status(source_section, parsed) {
    restore_persistent_subscription_cache(
        source_section,
        TMP_SUBSCRIPTION_FOLDER,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        parsed.url,
        parsed.user_agent,
        parsed.hwid,
        get_subscription_user_agent(""),
        parsed.device_headers_signature
    );

    let json_path = source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let url_path = source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let user_agent_path = source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let hwid_path = source_hwid_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let device_headers_path = source_device_headers_path(TMP_SUBSCRIPTION_FOLDER, source_section);
    let had_usable_cache = subscription_cache_is_usable(json_path);
    if (!had_usable_cache)
        unlink_path(json_path);

    let cached_url = read_text(url_path);
    let cached_user_agent = read_text(user_agent_path);
    let cached_hwid = read_text(hwid_path);
    let cached_device_headers = read_text(device_headers_path);
    if (had_usable_cache &&
        !source_cache_profile_matches(parsed, cached_url, cached_user_agent, cached_hwid, get_subscription_user_agent(""), cached_device_headers)) {
        // Usable, but fetched under other settings. The file stays: if the
        // download fails it is the only node list left, and `current` is false
        // so nothing treats it as up to date. Deleting it here left the source
        // with nothing at all whenever the network was down at the same time
        // as the settings change.
        return {
            usable: true,
            current: false,
            cached_url,
            cached_user_agent,
            cached_hwid,
            cached_device_headers
        };
    }

    return {
        usable: had_usable_cache,
        current: had_usable_cache,
        cached_url,
        cached_user_agent,
        cached_hwid,
        cached_device_headers
    };
}

function update_subscription_source(section_name_value, index_value, entry, phase, metadata_output_path) {
    ensure_runtime_dirs();
    let sections = uci_sections();
    let settings = uci_named_section("settings");
    let index = int(index_value || 0);
    let section = find_section(sections, section_name_value);
    let parsed = subscription_source_profile(section, entry);
    if (type(parsed) != "object" || parsed.valid !== true) {
        log_message("Invalid subscription URL in rule '" + section_name_value + "': " + as_string(parsed.error || "Invalid subscription source entry"), "error");
        return 1;
    }

    let source_section = source_id(section_name_value, index);
    let status = cached_source_status(source_section, parsed);
    if (status.usable && !status.current) {
        log_message("Subscription cache for rule '" + section_name_value + "' source '" + index + "' was fetched with other settings and is kept only as a fallback until a download succeeds", "info");
    }

    let proxy = get_subscription_download_proxy_address(section_name_value, sections, parsed, phase || "runtime");
    return download_subscription_into_cache(
        section_name_value,
        parsed.url,
        source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        proxy,
        parsed.user_agent,
        parsed.hwid,
        index,
        source_section,
        as_string(metadata_output_path),
        sections,
        parsed.device_headers,
        parsed.insecure,
        parsed.subscription_engine
    );
}

function subscription_update_due_result(section) {
    section = object_or_empty(section);
    let interval = section_subscription_update_interval(section);
    if (interval == "")
        return 1;

    let seconds = duration_to_seconds_value(interval);
    if (seconds == null) {
        log_message("Invalid subscription_update_interval value for rule '" + section_name(section) + "': " + interval, "error");
        return 2;
    }

    let last_run = file_first_line_value(subscription_update_timestamp_path(section_name(section)));
    let jitter = section_subscription_update_jitter(section);
    if (jitter != "")
        seconds = apply_subscription_jitter_seconds(seconds, jitter, section_name(section), last_run);

    return update_due_status(current_timestamp_value(), last_run, seconds);
}

function finalize_subscription_section_metadata(section_name_value, metadata_tmpfile, superseded) {
    if (as_string(metadata_tmpfile) == "")
        return;

    if (!superseded) {
        if (length(array_or_empty(read_json(metadata_tmpfile))) > 0)
            write_subscription_metadata(TACHYON_SECTION_CACHE_DIR, TACHYON_RUNTIME_CACHE_FORMAT, section_name_value, metadata_tmpfile);
        else
            write_subscription_metadata(TACHYON_SECTION_CACHE_DIR, TACHYON_RUNTIME_CACHE_FORMAT, section_name_value, "");
    }

    unlink_path(metadata_tmpfile);
}

function update_count_summary(updated, unchanged, failed) {
    let parts = [];
    if (updated > 0)
        push(parts, count_label(updated, "source updated", "sources updated"));
    if (unchanged > 0)
        push(parts, count_label(unchanged, "source unchanged", "sources unchanged"));
    if (failed > 0)
        push(parts, count_label(failed, "source failed", "sources failed"));
    return length(parts) > 0 ? join(", ", parts) : "no subscription sources checked";
}

function subscription_update_section(section, force) {
    section = object_or_empty(section);
    if (!section_is_subscription_proxy(section))
        return 3;

    let section_name_value = section_name(section);
    if (!force) {
        let due_result = subscription_update_due_result(section);
        if (due_result == 1)
            return 3;
        if (due_result != 0)
            return 1;
    }

    ensure_runtime_dirs();
    log_message("Updating subscriptions for rule '" + section_name_value + "'", "info");

    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, section_name_value, "metadata-section");
    write_json(metadata_tmpfile, []);

    let changed = 0;
    let unchanged = 0;
    let failed = 0;
    let superseded = 0;
    let total = 0;

    for (let entry in connections.subscription_urls(section)) {
        // total++ first, for the same positional reason as in
        // prepare_subscription_cache_section: the slot of a skipped source must
        // not be handed to the next one.
        total++;
        if (!connections.subscription_url_enabled(section, entry))
            continue;
        if (!force && !connections.subscription_update_enabled(section, entry))
            continue;
        let source_section = source_id(section_name_value, total);
        let metadata_output_path = temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output");
        let update_result = update_subscription_source(section_name_value, total, entry, "runtime", metadata_output_path);

        if (update_result == 0) {
            append_metadata_file(metadata_tmpfile, metadata_output_path, total, source_section);
            changed++;
        }
        else if (update_result == 2) {
            append_metadata_file(metadata_tmpfile, metadata_output_path, total, source_section);
            unchanged++;
        }
        else if (update_result == 4) {
            superseded++;
        }
        else {
            append_available_cached_metadata(metadata_tmpfile, section_name_value, total, source_section);
            failed++;
        }

        unlink_path(metadata_output_path);
    }

    if (total == 0) {
        unlink_path(metadata_tmpfile);
        log_message("Subscription URL is not set for rule '" + section_name_value + "'", "info");
        return 1;
    }

    let update_result = 2;
    if (changed > 0)
        update_result = 0;
    else if (failed > 0)
        update_result = 1;
    else if (superseded > 0)
        update_result = 4;

    finalize_subscription_section_metadata(section_name_value, metadata_tmpfile, superseded > 0);

    if (update_result == 0) {
        write_subscription_update_timestamp(section_name_value);
        log_message("Subscription update for rule '" + section_name_value + "' completed: " + update_count_summary(changed, unchanged, failed), "info");
    }
    else if (update_result == 2) {
        write_subscription_update_timestamp(section_name_value);
        log_message("Subscription update for rule '" + section_name_value + "' completed: no changes (" + count_label(unchanged, "source checked", "sources checked") + ")", "info");
    }
    else if (update_result == 4) {
        log_message("Subscription update for rule '" + section_name_value + "' was superseded by newer URLs", "info");
    }
    else {
        log_message("Subscription update for rule '" + section_name_value + "' failed: " + update_count_summary(changed, unchanged, failed), "warn");
    }

    return update_result;
}

function source_index_number(value) {
    value = as_string(value);
    if (value == "" || match(value, /[^0-9]/) != null)
        return null;

    let result = int(value);
    return result > 0 ? result : null;
}

function subscription_update_selected_source(sections, section_name_value, source_index_value, force) {
    if (!cache_section_is_safe(section_name_value)) {
        log_message("Invalid subscription rule name", "error");
        return 1;
    }

    let source_index = source_index_number(source_index_value);
    if (source_index == null) {
        log_message("Invalid subscription source index for rule '" + section_name_value + "'", "error");
        return 1;
    }

    let section = find_section(sections, section_name_value);
    if (!section_is_subscription_proxy(section)) {
        log_message("Rule '" + section_name_value + "' has no subscription sources", "info");
        return 1;
    }

    if (!force) {
        let due_result = subscription_update_due_result(section);
        if (due_result == 1)
            return 3;
        if (due_result != 0)
            return 1;
    }

    ensure_runtime_dirs();
    log_message("Updating subscription source " + source_index + " for rule '" + section_name_value + "'", "info");

    let current_index = 0;
    let selected_entry = null;
    for (let entry in connections.subscription_urls(section)) {
        current_index++;
        if (current_index == source_index) {
            selected_entry = entry;
            break;
        }
    }

    if (selected_entry == null) {
        log_message("Subscription source '" + source_index + "' was not found for rule '" + section_name_value + "'", "info");
        return 1;
    }

    let source_section = source_id(section_name_value, source_index);
    let metadata_output_path = temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output");
    let update_result = update_subscription_source(section_name_value, source_index, selected_entry, "runtime", metadata_output_path);

    if (update_result == 0 || update_result == 2)
        write_source_metadata(
            TACHYON_SECTION_CACHE_DIR,
            TACHYON_RUNTIME_CACHE_FORMAT,
            section_name_value,
            source_index,
            source_section,
            metadata_output_path,
            TACHYON_SUBSCRIPTION_METADATA_DIR + "/" + section_name_value + ".json"
        );

    unlink_path(metadata_output_path);

    if (update_result == 0) {
        write_subscription_update_timestamp(section_name_value);
    }
    else if (update_result == 2) {
        write_subscription_update_timestamp(section_name_value);
    }
    else if (update_result == 4) {
        log_message("Subscription source '" + source_index + "' update for rule '" + section_name_value + "' was superseded by newer URLs", "info");
    }
    else {
        log_message("Failed to download subscription source '" + source_index + "' for rule '" + section_name_value + "'", "info");
    }

    return update_result;
}

function empty_subscription_update_summary() {
    return {
        updated: 0,
        failed: 0,
        unchanged: 0,
        superseded: 0
    };
}

function add_subscription_update_result(summary, result) {
    if (result == 0)
        summary.updated++;
    else if (result == 1)
        summary.failed++;
    else if (result == 2)
        summary.unchanged++;
    else if (result == 4)
        summary.superseded++;
}

function print_subscription_update_summary(summary) {
    print(summary.updated, "\t", summary.failed, "\t", summary.unchanged, "\t", summary.superseded, "\n");
}

function subscription_update_request(force_value, target_section_name, target_source_index) {
    let force = as_string(force_value) == "1";
    let sections = uci_sections();
    let summary = empty_subscription_update_summary();

    target_section_name = as_string(target_section_name);
    target_source_index = as_string(target_source_index);

    if (target_section_name != "") {
        let matched_sec = find_section(sections, target_section_name);
        if (section_name(matched_sec) != "") {
            if (target_source_index != "")
                add_subscription_update_result(summary, subscription_update_selected_source(sections, target_section_name, target_source_index, force));
            else
                add_subscription_update_result(summary, subscription_update_section(matched_sec, force));
            print_subscription_update_summary(summary);
            return;
        }

        let src_obj = uci_section(target_section_name);
        if (as_string(src_obj[".type"]) == "outbound_source") {
            let src_url = connections.outbound_source_subscription_url(src_obj);
            let matched_any_section = false;
            if (src_url != "") {
                for (let sec in sections) {
                    let sec_id = section_name(sec);
                    let idx = 0;
                    for (let entry in connections.subscription_urls(sec)) {
                        idx++;
                        if (trim(as_string(entry || "")) == src_url) {
                            matched_any_section = true;
                            add_subscription_update_result(summary, subscription_update_selected_source(sections, sec_id, as_string(idx), force));
                        }
                    }
                }
            }
            if (!matched_any_section) {
                let pool_sec = {
                    ".name": "Pool_" + target_section_name,
                    "enabled": "1",
                    "action": "connection",
                    "proxy_config_type": "subscription",
                    "outbound_source_refs": [ target_section_name ]
                };
                add_subscription_update_result(summary, subscription_update_section(pool_sec, force));
            }
            print_subscription_update_summary(summary);
            return;
        }

        add_subscription_update_result(summary, 1);
        print_subscription_update_summary(summary);
        return;
    }

    let covered_urls = {};
    for (let section in sections) {
        for (let u in connections.subscription_urls(section))
            covered_urls[trim(as_string(u || ""))] = true;
        add_subscription_update_result(summary, subscription_update_section(section, force));
    }

    for (let src in array_or_empty(uci_core.sections(CONFIG_NAME, "outbound_source"))) {
        src = object_or_empty(src);
        let src_id = as_string(src[".name"] || "");
        let stype = lc(trim(as_string(src.source_type || "subscription")));
        let src_url = connections.outbound_source_subscription_url(src);
        if (src_id == "" || as_string(src.enabled || "1") == "0")
            continue;
        if ((stype == "subscription" || src_url != "") && (match(lc(src_url), /^https?:\/\//) || happ.is_encrypted(src_url)) && covered_urls[src_url] !== true) {
            covered_urls[src_url] = true;
            let pool_sec = {
                ".name": "Pool_" + src_id,
                "enabled": "1",
                "action": "connection",
                "proxy_config_type": "subscription",
                "outbound_source_refs": [ src_id ]
            };
            add_subscription_update_result(summary, subscription_update_section(pool_sec, force));
        }
    }

    print_subscription_update_summary(summary);
}

function ensure_subscription_source_for_prepare(state, section, source_index, entry, metadata_tmpfile) {
    let section_name_value = section_name(section);
    let parsed = subscription_source_profile(section, entry);
    if (type(parsed) != "object" || parsed.valid !== true) {
        log_message("Invalid subscription source for rule '" + section_name_value + "': " + as_string(parsed.error || "Invalid subscription source entry"), "error");
        return false;
    }

    let source_section = source_id(section_name_value, source_index);
    let cached = cached_source_status(source_section, parsed);
    if (cached.usable && cached.current) {
        append_available_cached_metadata(metadata_tmpfile, section_name_value, source_index, source_section);
        return true;
    }

    if (state.no_refresh) {
        log_message("No current subscription cache for rule '" + section_name_value + "' source '" + source_index + "'; skipping refresh during scoped runtime rebuild", "warn");
        return false;
    }

    let metadata_output_path = metadata_tmpfile != "" ? temp_path(TMP_SUBSCRIPTION_FOLDER, source_section, "metadata-output") : "";
    let proxy = get_subscription_download_proxy_address(section_name_value, state.sections, parsed, state.phase);
    let update_result = download_subscription_into_cache(
        section_name_value,
        parsed.url,
        source_json_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        source_url_path(TMP_SUBSCRIPTION_FOLDER, source_section),
        proxy,
        parsed.user_agent,
        parsed.hwid,
        source_index,
        source_section,
        metadata_output_path,
        state.sections,
        parsed.device_headers,
        parsed.insecure,
        parsed.subscription_engine
    );

    if (update_result == 0 || update_result == 2) {
        append_metadata_file(metadata_tmpfile, metadata_output_path, source_index, source_section);
        unlink_path(metadata_output_path);
        return true;
    }

    unlink_path(metadata_output_path);

    if (cached.usable) {
        log_message("Keeping the last usable subscription cache for rule '" + section_name_value + "' until a fresh download succeeds", "warn");
        append_available_cached_metadata(metadata_tmpfile, section_name_value, source_index, source_section);
        return true;
    }

    log_message("No usable subscription cache for rule '" + section_name_value + "'", "warn");
    return false;
}

function prepare_subscription_cache_section(state, section) {
    section = object_or_empty(section);
    if (!section_is_subscription_proxy(section))
        return;

    let section_name_value = section_name(section);
    let metadata_tmpfile = temp_path(TMP_SUBSCRIPTION_FOLDER, section_name_value, "metadata-section");
    write_json(metadata_tmpfile, []);

    let total = 0;
    let ready = 0;
    let failed = 0;
    for (let entry in connections.subscription_urls(section)) {
        // total++ stays before every continue. Sources are addressed positionally
        // (source_id is "<section>-subscription-<n>"), so skipping a disabled URL
        // has to leave its slot unclaimed - counting only the enabled ones would
        // shift every later source by one and read one source's cache as another's.
        total++;
        if (!connections.subscription_url_enabled(section, entry))
            continue;
        if (ensure_subscription_source_for_prepare(state, section, total, entry, metadata_tmpfile))
            ready++;
        else {
            failed++;
            state.unavailable_sources = append_word_once(state.unavailable_sources, source_id(section_name_value, total));
        }
    }

    if (total > 0 && ready == 0) {
        if (section_has_non_subscription_connection_sources(section)) {
            log_message("All subscription sources for rule '" + section_name_value + "' are unavailable; starting with manual proxy links only", "warn");
        }
        else {
            if (state.phase == "startup")
                log_message("No usable subscription cache for rule '" + section_name_value + "' and no manual proxy links are configured; checking whether startup can be bootstrapped through the selected proxy/VPN rule", "warn");
            else
                log_message("No usable subscription cache for rule '" + section_name_value + "' and no manual proxy links are configured; fast runtime generation cannot use this rule", "warn");
            state.startup_blocked_sections = append_word_once(state.startup_blocked_sections, section_name_value);
        }
    }
    else if (failed > 0) {
        log_message("Skipping unavailable subscription source(s) for rule '" + section_name_value + "'; using available outbounds", "warn");
    }

    for (let i = 1; i <= total; i++) {
        let sid = source_id(section_name_value, i);
        let runtime_json = source_json_path(TMP_SUBSCRIPTION_FOLDER, sid);
        if (!subscription_cache_is_usable(runtime_json))
            continue;
        let r_url = read_text(source_url_path(TMP_SUBSCRIPTION_FOLDER, sid));
        let p_url = read_text(source_url_path(TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR, sid));
        if (p_url != r_url) {
            let r_ua = read_text(source_user_agent_path(TMP_SUBSCRIPTION_FOLDER, sid));
            let r_hwid = read_text(source_hwid_path(TMP_SUBSCRIPTION_FOLDER, sid));
            let r_headers = read_text(source_device_headers_path(TMP_SUBSCRIPTION_FOLDER, sid));
            let r_meta = runtime_metadata_path(sid);
            if (!file_nonempty(r_meta))
                r_meta = persistent_metadata_path(sid);
            persist_subscription_cache(sid, runtime_json, r_url, r_ua, r_hwid, r_meta, r_headers);
        }
    }

    let metadata_count = length(array_or_empty(read_json(metadata_tmpfile)));
    if (metadata_count > 0)
        write_subscription_metadata(TACHYON_SECTION_CACHE_DIR, TACHYON_RUNTIME_CACHE_FORMAT, section_name_value, metadata_tmpfile);
    else
        write_subscription_metadata(TACHYON_SECTION_CACHE_DIR, TACHYON_RUNTIME_CACHE_FORMAT, section_name_value, "");
    unlink_path(metadata_tmpfile);
}

function prepared_runtime_cache_should_skip(sections, section_cache_dir, phase, already_prepared) {
    return as_string(phase) == "runtime" &&
        as_string(already_prepared) == "1" &&
        !runtime_cache_missing(sections, section_cache_dir);
}

function prepare_subscription_caches(phase, already_prepared, no_refresh) {
    phase = as_string(phase || "startup");
    let sections = uci_sections();

    if (prepared_runtime_cache_should_skip(sections, TACHYON_SECTION_CACHE_DIR, phase, already_prepared)) {
        let saved_deferred = trim(as_string(fs.readfile(TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE)) || "");
        print(saved_deferred, "\n");
        return 0;
    }

    ensure_runtime_dirs();
    let state = {
        phase,
        sections,
        settings: uci_named_section("settings"),
        startup_blocked: false,
        startup_blocked_sections: "",
        unavailable_sources: "",
        no_refresh: as_string(no_refresh) == "1"
    };

    let covered_urls = {};
    for (let section in sections) {
        for (let u in connections.subscription_urls(section))
            covered_urls[trim(as_string(u || ""))] = true;
        prepare_subscription_cache_section(state, section);
    }
    for (let src in array_or_empty(uci_core.sections(CONFIG_NAME, "outbound_source"))) {
        src = object_or_empty(src);
        let src_id = as_string(src[".name"] || "");
        let stype = lc(trim(as_string(src.source_type || "subscription")));
        let src_url = connections.outbound_source_subscription_url(src);
        if (src_id == "" || as_string(src.enabled || "1") == "0")
            continue;
        if ((stype == "subscription" || src_url != "") && (match(lc(src_url), /^https?:\/\//) || happ.is_encrypted(src_url)) && covered_urls[src_url] !== true) {
            covered_urls[src_url] = true;
            let pool_sec = {
                ".name": "Pool_" + src_id,
                "enabled": "1",
                "action": "connection",
                "proxy_config_type": "subscription",
                "outbound_source_refs": [ src_id ]
            };
            let pool_state = {
                phase: state.phase,
                sections: state.sections,
                settings: state.settings,
                startup_blocked: false,
                startup_blocked_sections: "",
                unavailable_sources: "",
                no_refresh: state.no_refresh
            };
            prepare_subscription_cache_section(pool_state, pool_sec);
        }
    }
    prune_stale_subscription_caches_for_sections(sections);

    if (state.startup_blocked)
        return 1;

    if (state.startup_blocked_sections == "") {
        unlink_path(TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE);
        print("\n");
        return 0;
    }

    if (phase == "startup" || phase == "runtime") {
        if (subscription_bootstrap_download_section_is_ready(sections, state.startup_blocked_sections, get_subscription_user_agent("")))
            log_message("Starting temporarily without subscription-only rule(s): " + state.startup_blocked_sections + ". They will be retried through the service proxy after sing-box starts", "warn");
        else
            log_message("Starting temporarily without unavailable subscription-only rule(s): " + state.startup_blocked_sections + ". Other rules remain active and failed rules will apply fail_policy / retry in background", "warn");
        write_file(TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE, state.startup_blocked_sections + "\n");
        print(state.startup_blocked_sections, "\n");
        return 0;
    }

    for (let section in whitespace_values(state.startup_blocked_sections))
        log_message("No usable subscription cache for rule '" + section + "' and no manual proxy links are configured; startup cannot continue", "error");

    return 1;
}

function current_pid() {
    return trim(command_output("sh -c 'echo $PPID'"));
}

function pid_running(pid) {
    pid = as_string(pid);
    return match(pid, /^[0-9]+$/) != null && command_success_from_args([ "kill", "-0", pid ]);
}

function state_ucode_status(args) {
    return command_status_from_args(command_args_with([ "ucode", "-L", LIB_DIR, LIB_DIR + "/service/state.uc" ], args)) == 0;
}

function mark_pending_subscription_recovery_reload() {
    state_ucode_status([ "mark-pending-reload", TACHYON_PENDING_RELOAD_FILE, "subscription_deferred_recovery" ]);
}

// A recovered subscription cache only needs config.json regenerated and pushed
// into the running sing-box, which `updates.uc subscription-deferred-recovery-
// apply` does in place. Escalating to `/etc/init.d/tachyon reload` walked the
// whole validate/capture/plan pipeline and restarted both helper workers, so a
// background bootstrap retry could take the router's proxy down for minutes
// (issue #119).
function trigger_subscription_recovery_reload(worker) {
    if (worker)
        command_status_from_args(command_args_with([
            "ucode", "-L", LIB_DIR, LIB_DIR + "/components/updates.uc",
            "subscription-deferred-recovery-apply"
        ], []));
    else
        mark_pending_subscription_recovery_reload();
}

function sanitize_deferred_sections(deferred_sections) {
    let cleaned = "";
    for (let token in whitespace_values(deferred_sections)) {
        if (safe_section(token))
            cleaned = append_word_once(cleaned, token);
    }
    return cleaned;
}

function subscription_bootstrap_retry_result(deferred_sections) {
    let sections = uci_sections();
    let default_user_agent = get_subscription_user_agent("");
    let result = {
        recovered: "",
        remaining: ""
    };

    for (let section in whitespace_values(sanitize_deferred_sections(deferred_sections))) {
        let value = find_section(sections, section);
        if (!section_is_subscription_proxy(value)) {
            log_message("Deferred subscription rule '" + section + "' no longer has subscription proxy sources; removing it from bootstrap retry list", "warn");
            if (section_name(value) != "")
                result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        log_message("Retrying deferred subscription rule '" + section + "' through the service proxy", "info");
        let update_result = subscription_update_section(value, true);
        if (update_result == 0 || update_result == 2) {
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        if (section_current_usable_cache_by_name(sections, section, default_user_agent)) {
            log_message("Deferred subscription rule '" + section + "' has a usable cache after retry despite partial update errors", "warn");
            result.recovered = append_word_once(result.recovered, section);
            continue;
        }

        result.remaining = append_word_once(result.remaining, section);
        log_message("Deferred subscription rule '" + section + "' is still unavailable; keeping it disabled for this startup", "warn");
    }

    if (result.remaining != "")
        write_file(TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE, result.remaining + "\n");
    else
        unlink_path(TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE);

    return result;
}

function worker_env() {
    return {
        TACHYON_CONFIG_NAME: CONFIG_NAME,
        TACHYON_LIB: LIB_DIR,
        TMP_SING_BOX_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        TACHYON_RUNTIME_STATE_DIR,
        TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR,
        TACHYON_SUBSCRIPTION_LINKS_DIR,
        TACHYON_SUBSCRIPTION_METADATA_DIR,
        TACHYON_OUTBOUND_METADATA_DIR,
        TACHYON_SECTION_CACHE_DIR,
        TACHYON_RUNTIME_CACHE_FORMAT_FILE,
        TACHYON_RUNTIME_CACHE_FORMAT,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE,
        TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR,
        TACHYON_PENDING_RELOAD_FILE,
        TACHYON_SERVICE_INIT,
        SB_SERVICE_MIXED_INBOUND_ADDRESS,
        SB_SERVICE_MIXED_INBOUND_PORT,
        SB_VARIANT_STATE_FILE,
        SB_VERSION_STATE_FILE,
        ZAPRET_PROVIDER_NFQWS_BIN,
        ZAPRET2_PROVIDER_NFQWS2_BIN,
        BYEDPI_BIN
    };
}

function launch_self_worker(args) {
    let command_args = command_args_with([ "ucode", "-L", LIB_DIR, LIB_DIR + "/subscription/cache.uc" ], args);
    let command = common.background_command_with_pid(
        command_env(worker_env()) + " " + command_from_args(command_args));
    return trim(command_output("sh -c " + shell_quote(command)));
}

function start_deferred_subscription_bootstrap_retry_worker(deferred_sections) {
    deferred_sections = trim(as_string(deferred_sections));
    if (deferred_sections == "")
        return;

    ensure_runtime_dirs();
    let existing_pid = trim(file_first_line_value(TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE));
    if (pid_running(existing_pid)) {
        log_message("Subscription bootstrap retry worker is already running with PID " + existing_pid, "debug");
        return;
    }

    let pid = launch_self_worker([ "deferred-bootstrap-worker", deferred_sections ]);
    if (pid != "")
        write_file(TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE, pid + "\n");
    log_message("Started subscription bootstrap retry worker for rule(s): " + deferred_sections, "info");
}

function stop_deferred_subscription_bootstrap_retry_worker() {
    let pid = trim(file_first_line_value(TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE));
    if (pid_running(pid)) {
        command_success_from_args([ "kill", pid ]);
        log_message("Stopped subscription bootstrap retry worker", "info");
    }
    unlink_path(TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE);
}

function run_deferred_subscription_bootstrap(deferred_sections) {
    deferred_sections = sanitize_deferred_sections(deferred_sections);
    if (deferred_sections == "")
        return;

    log_message("Waiting for sing-box service proxy before retrying deferred subscription rule(s): " + deferred_sections, "info");
    let process_ready = false;
    for (let attempt = 1; attempt <= 10; attempt++) {
        if (sing_box_service_running()) {
            process_ready = true;
            break;
        }
        system("sleep 1");
    }

    if (!process_ready) {
        log_message("sing-box service proxy did not become ready in time; deferred subscription rule(s) will remain disabled until the next successful subscription update", "warn");
        start_deferred_subscription_bootstrap_retry_worker(deferred_sections);
        return;
    }

    // Wait for the proxy port to actually accept TCP connections — the sing-box
    // process may be running but the mixed inbound port not yet ready. Without
    // this check, the deferred download falls back to a direct connection that
    // may fail for subscription URLs only reachable through the proxy.
    let proxy_address = SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + SB_SERVICE_MIXED_INBOUND_PORT;
    let port_ready = false;
    for (let attempt = 1; attempt <= 10; attempt++) {
        let probe = command_status_from_args([
            "curl", "-s", "--connect-timeout", "2", "-m", "4",
            "-x", "http://" + proxy_address, "http://1.1.1.1/", "-o", "/dev/null"
        ]);
        if (probe != 7 && probe != 28) {
            log_message("Service proxy is ready for deferred subscription bootstrap", "info");
            port_ready = true;
            break;
        }
        log_message("Service proxy port not yet ready for deferred bootstrap [" + attempt + "/10]", "info");
        system("sleep 3");
    }

    if (!port_ready) {
        log_message("Service proxy port is not accepting connections; starting bootstrap retry worker for: " + deferred_sections, "warn");
        start_deferred_subscription_bootstrap_retry_worker(deferred_sections);
        return;
    }

    let result = subscription_bootstrap_retry_result(deferred_sections);
    if (result.recovered != "") {
        log_message("Recovered deferred subscription rule(s): " + result.recovered + "; scheduling Tachyon reload", "info");
        trigger_subscription_recovery_reload(false);
    }

    if (result.remaining != "") {
        log_message("Some deferred subscription rule(s) are still disabled for this startup: " + result.remaining, "warn");
        start_deferred_subscription_bootstrap_retry_worker(result.remaining);
    }
}

function deferred_subscription_bootstrap_retry_worker(remaining_sections) {
    remaining_sections = trim(as_string(remaining_sections));
    let attempts = 0;
    let max_attempts = 20;

    while (remaining_sections != "" && attempts < max_attempts) {
        attempts++;
        let sleep_sec = attempts <= 2 ? 30 : (attempts <= 5 ? 60 : (attempts <= 10 ? 120 : 300));
        system("sleep " + sleep_sec);
        if (!sing_box_service_running()) {
            log_message("Stopping subscription bootstrap retry worker because sing-box is not running", "warn");
            break;
        }

        ensure_runtime_dirs();
        if (!state_ucode_status([ "acquire-runtime-dir-lock", TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR, current_pid() ])) {
            log_message("Subscription bootstrap retry skipped because another subscription update is running", "debug");
            continue;
        }

        let result = subscription_bootstrap_retry_result(remaining_sections);
        state_ucode_status([ "release-runtime-dir-lock", TACHYON_SUBSCRIPTION_UPDATE_LOCK_DIR ]);

        if (result.recovered != "") {
            log_message("Recovered deferred subscription rule(s): " + result.recovered + "; reloading Tachyon", "info");
            trigger_subscription_recovery_reload(true);
        }

        remaining_sections = result.remaining;
    }

    if (remaining_sections != "" && attempts >= max_attempts)
        log_message("Giving up subscription bootstrap retry after " + attempts + " attempts for: " + remaining_sections, "warn");

    unlink_path(TACHYON_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE);
}

let mode = ARGV[0] || "";

if (mode == "file-first-line") {
    file_first_line(ARGV[1]);
}
else if (mode == "file-has-exact-line") {
    exit(file_has_exact_line(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "state-list-contains") {
    exit(state_list_contains(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "append-state-list-once") {
    append_state_list_once(ARGV[1], ARGV[2]);
}
else if (mode == "maintenance-plan") {
    maintenance_plan(uci_sections(), ARGV[1]);
}
else if (mode == "maintenance-plan-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    maintenance_plan(fixture_section_list(data), ARGV[2]);
}
else if (mode == "runtime-cache-needs-rebuild") {
    exit(runtime_cache_missing(uci_sections(), ARGV[1]) ? 0 : 1);
}
else if (mode == "runtime-cache-needs-rebuild-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    exit(runtime_cache_missing(fixture_section_list(data), ARGV[2]) ? 0 : 1);
}
else if (mode == "prepared-runtime-cache-should-skip-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    exit(prepared_runtime_cache_should_skip(fixture_section_list(data), ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
}
else if (mode == "ensure-runtime-dirs") {
    ensure_runtime_dirs();
}
else if (mode == "clear-runtime-cache") {
    clear_subscription_runtime_cache();
}
else if (mode == "ensure-runtime-cache-format") {
    ensure_runtime_cache_format();
}
else if (mode == "stale-cache-delete-paths") {
    stale_cache_delete_paths(uci_sections(), ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "stale-cache-delete-paths-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    stale_cache_delete_paths(fixture_section_list(data), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
}
else if (mode == "section-current-usable-cache") {
    exit(section_current_usable_cache(uci_section(ARGV[1]), ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
}
else if (mode == "restore-persistent-source") {
    let expected_hwid = ARGV[7] == null ? "" : ARGV[6];
    let default_user_agent = ARGV[7] == null ? ARGV[6] : ARGV[7];
    let expected_device_headers_signature = ARGV[8] == null ? "" : ARGV[8];
    exit(restore_persistent_subscription_cache(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], expected_hwid, default_user_agent, expected_device_headers_signature) ? 0 : 1);
}
else if (mode == "persist-source-cache") {
    let effective_hwid = ARGV[6] == null ? "" : ARGV[5];
    let metadata_path = ARGV[6] == null ? ARGV[5] : ARGV[6];
    let effective_device_headers_signature = ARGV[7] == null ? "" : ARGV[7];
    exit(persist_subscription_cache(ARGV[1], ARGV[2], ARGV[3], ARGV[4], effective_hwid, metadata_path, effective_device_headers_signature) ? 0 : 1);
}
else if (mode == "section-current-usable-cache-fixture") {
    let data = object_or_empty(read_json(ARGV[1]));
    connections.set_item_sections_from_data(data);
    let target = as_string(ARGV[2]);
    let selected = {};
    for (let section in fixture_section_list(data)) {
        if (section_name(section) == target) {
            selected = section;
            break;
        }
    }
    exit(section_current_usable_cache(selected, ARGV[3], ARGV[4], ARGV[5]) ? 0 : 1);
}
else if (mode == "cached-source-status-fixture") {
    let status = cached_source_status(as_string(ARGV[1]), object_or_empty(read_json(ARGV[2])));
    print("usable=", status.usable ? "1" : "0", " current=", status.current ? "1" : "0", "\n");
}
else if (mode == "user-agent-supported") {
    exit(user_agent_supported(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "user-agent-matches-config") {
    exit(user_agent_matches_config(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
}
else if (mode == "write-user-agent-candidates") {
    write_user_agent_candidates(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
}
else if (mode == "source-id") {
    print(source_id(ARGV[1], int(ARGV[2] || 0)), "\n");
}
else if (mode == "subscription-metadata-path") {
    let path = subscription_metadata_path(ARGV[1]);
    if (path == "")
        exit(1);
    print(path, "\n");
}
else if (mode == "outbound-metadata-path") {
    let path = outbound_metadata_path(ARGV[1]);
    if (path == "")
        exit(1);
    print(path, "\n");
}
else if (mode == "section-is-subscription-proxy") {
    exit(section_is_subscription_proxy(uci_section(ARGV[1])) ? 0 : 1);
}
else if (mode == "update-source") {
    exit(update_subscription_source(ARGV[1], ARGV[2], ARGV[3], ARGV[4] || "runtime", ARGV[5] || ""));
}
else if (mode == "download-subscription") {
    exit(download_subscription(ARGV[1], ARGV[2], ARGV[3] || "", ARGV[4] || "", ARGV[5] || "", ARGV[6] || "", {}, ARGV[7] == "1") == 0 ? 0 : 1);
}
else if (mode == "update-section") {
    exit(subscription_update_section(find_section(uci_sections(), ARGV[1] || ""), as_string(ARGV[2] || "0") == "1"));
}
else if (mode == "update-request") {
    subscription_update_request(ARGV[1] || "0", ARGV[2] || "", ARGV[3] || "");
}
else if (mode == "prepare-caches") {
    exit(prepare_subscription_caches(ARGV[1] || "startup", ARGV[2] || "0", ARGV[3] || "0"));
}
else if (mode == "run-deferred-bootstrap") {
    run_deferred_subscription_bootstrap(ARGV[1] || "");
}
else if (mode == "start-deferred-bootstrap-worker") {
    start_deferred_subscription_bootstrap_retry_worker(ARGV[1] || "");
}
else if (mode == "stop-deferred-bootstrap-worker") {
    stop_deferred_subscription_bootstrap_retry_worker();
}
else if (mode == "deferred-bootstrap-worker") {
    deferred_subscription_bootstrap_retry_worker(ARGV[1] || "");
}
else if (mode == "json-length") {
    json_length(ARGV[1]);
}
else if (mode == "usable-outbound-count") {
    print(usable_subscription_outbound_count(ARGV[1]), "\n");
}
else if (mode == "shrink-guard-triggers") {
    exit(subscription_shrink_guard_triggers(ARGV[1], ARGV[2]) ? 0 : 1);
}
else if (mode == "subscription-import-stats") {
    print(subscription_import_stats_text(ARGV[1]), "\n");
}
else if (mode == "subscription-source-summary") {
    print(subscription_source_summary(ARGV[1], ARGV[2], ARGV[3], ARGV[4]), "\n");
}
else if (mode == "object-has-extra-keys") {
    exit(object_has_extra_keys(ARGV[1]) ? 0 : 1);
}
else if (mode == "write-outbound-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_outbound_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "write-subscription-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_subscription_metadata(cache_dir, format_version, section, ARGV[4]);
}
else if (mode == "append-metadata-file") {
    append_metadata_file(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
}
else if (mode == "append-cached-metadata") {
    append_cached_metadata(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
}
else if (mode == "write-source-metadata") {
    let cache_dir = ARGV[1], format_version = ARGV[2], section = ARGV[3];
    if (!safe_section(section))
        exit(1);
    write_source_metadata(cache_dir, format_version, section, ARGV[4], ARGV[5], ARGV[6], ARGV[7]);
}
else if (mode == "get-outbound-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (section == null || trim(as_string(section)) == "" || as_string(section) == "all")
        get_outbound_metadata(cache_dir, "all", "");
    else if (!safe_section(section))
        write_empty_outbound_metadata();
    else
        get_outbound_metadata(cache_dir, section, ARGV[3]);
}
else if (mode == "empty-outbound-metadata") {
    write_empty_outbound_metadata();
}
else if (mode == "get-subscription-metadata") {
    let cache_dir = ARGV[1], section = ARGV[2];
    if (!safe_section(section))
        print("{}\n");
    else
        get_subscription_metadata(cache_dir, section, ARGV[3]);
}
else {
    warn("Usage: subscription/cache.uc <mode> ...\n");
    exit(1);
}
