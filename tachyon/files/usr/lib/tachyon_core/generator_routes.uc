#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let helpers = require("core.helpers");
let core_ip = require("core.ip");
let core_url = require("core.url");
let runtime_constants = require("tachyon_core.constants");
let variant_state = require("tachyon_core.variant_state");
let runtime_country = require("tachyon_core.country");
let runtime_dns = require("tachyon_core.dns");
let runtime_route = require("tachyon_core.route");
let runtime_rulesets = require("tachyon_core.rulesets");
let runtime_subscription = require("tachyon_core.subscription");
let runtime_servers = require("tachyon_core.servers");
let runtime_urltest = require("tachyon_core.urltest");
let connections = require("config.connections");
let rule_config = require("config.rule");
let source_rulesets = require("routing.rulesets");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let read_json_file = common.read_json_file;

let outbound_tag = runtime_constants.outbound_tag;
let tag = runtime_constants.tag;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
let runtime_ruleset_folder = getenv("TACHYON_RULESET_FOLDER") || "/usr/share/tachyon/rulesets";

let ctx = {};
let section_leaf_tags = {};
let section_group_map = {};
let section_state_map = {};
let active_group_tags = {};

function settings_update_interval() {
    let settings = ctx.runtime_settings();
    if (!bool_option(settings, "list_update_enabled", true))
        return "";

    let update_interval = option(settings, "update_interval", "1d");
    return update_interval != "" ? update_interval : "1d";
}

function remote_ruleset_update_interval() {
    let update_interval = settings_update_interval();
    return update_interval != "" ? update_interval : runtime_constants.DISABLED_UPDATE_INTERVAL;
}

function init(c) {
    ctx = c;
    section_leaf_tags = {};
    section_group_map = {};
    section_state_map = {};
    active_group_tags = {};
}

function valid_section_name(name) {
    name = as_string(name);
    return match(name, /^[A-Za-z0-9_]+$/);
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function ruleset_tag(section_name, name, kind) {
    return kind == ""
        ? section_name + "-" + name + "-ruleset"
        : section_name + "-" + name + "-" + kind + "-ruleset";
}

function ruleset_registered(config, tag_name) {
    for (let rule_set in array_or_empty(config.route && config.route.rule_set)) {
        if (type(rule_set) == "object" && rule_set.tag == tag_name)
            return true;
    }
    return false;
}

function duration_to_seconds(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;
    if (match(rest, /^[0-9]+$/) != null)
        return int(rest, 10);

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
        total += (matched[1] * 1) * multipliers[matched[3]];
        rest = substr(rest, length(token));
    }

    return total <= 0 ? null : int(total + 0.5);
}

function urltest_check_interval(section, urltest_id) {
    let interval = connections.urltest_check_interval(section, urltest_id);
    return interval != "" ? interval : "3m";
}

function urltest_idle_timeout(section, urltest_id) {
    let configured = connections.urltest_idle_timeout(section, urltest_id);
    let interval = urltest_check_interval(section, urltest_id);
    let interval_seconds = duration_to_seconds(interval);
    let idle_seconds = duration_to_seconds(configured != ""
        ? configured
        : runtime_constants.URLTEST_DEFAULT_IDLE_TIMEOUT);

    // sing-box refuses to start a URLTest group whose interval exceeds its
    // idle_timeout, and substitutes URLTEST_DEFAULT_IDLE_TIMEOUT when the
    // option is omitted. Raise the timeout to the interval instead of emitting
    // a config that fails with "interval must be less or equal than idle_timeout".
    if (interval_seconds != null && idle_seconds != null && interval_seconds > idle_seconds)
        return interval;

    return configured;
}

function supported_urltest_filter_mode(mode) {
    return mode == "include" || mode == "exclude" || mode == "mixed";
}

function filter_mode_uses_include(mode) {
    return mode == "include" || mode == "mixed";
}

function filter_mode_uses_exclude(mode) {
    return mode == "exclude" || mode == "mixed";
}

function configured_country_filter(mode, include_countries, exclude_countries) {
    return (filter_mode_uses_include(mode) && length(array_or_empty(include_countries)) > 0) ||
        (filter_mode_uses_exclude(mode) && length(array_or_empty(exclude_countries)) > 0);
}

function section_needs_country_is(section) {
    let dashboard_mode = connections.dashboard_filter_mode(section);
    if (connections.dashboard_detect_server_country(section) == "country_is" &&
        configured_country_filter(
            dashboard_mode,
            connections.dashboard_include_countries(section),
            connections.dashboard_exclude_countries(section)
        ))
        return true;

    for (let urltest_id in connections.urltests(section)) {
        let mode = connections.urltest_filter_mode(section, urltest_id);
        if (connections.urltest_detect_server_country(section, urltest_id) == "country_is" &&
            configured_country_filter(
                mode,
                connections.urltest_include_countries(section, urltest_id),
                connections.urltest_exclude_countries(section, urltest_id)
            ))
            return true;
    }

    for (let group_id in connections.priority_groups(section)) {
        for (let level_id in connections.priority_levels(group_id)) {
            if (connections.priority_level_direct(group_id, level_id))
                continue;
            let mode = connections.priority_level_filter_mode(group_id, level_id);
            if (connections.priority_level_detect_server_country(group_id, level_id) == "country_is" &&
                configured_country_filter(
                    mode,
                    connections.priority_level_include_countries(group_id, level_id),
                    connections.priority_level_exclude_countries(group_id, level_id)
                ))
                return true;
        }
    }
    return false;
}

function section_has_direct_priority_level(section) {
    for (let group_id in connections.priority_groups(section))
        for (let level_id in connections.priority_levels(group_id))
            if (connections.priority_level_direct(group_id, level_id))
                return true;
    return false;
}

function urltest_country_metadata(section, urltest_id, state) {
    let names = object_or_empty(object_or_empty(state.outboundMetadata).names);
    let from_flags = runtime_urltest.countries_from_flag_names(names);
    let detect_method = connections.urltest_detect_server_country(section, urltest_id);
    if (detect_method == "flag_emoji")
        return from_flags;
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let result = {};
    for (let tag, c in from_flags)
        result[tag] = c;
    for (let tag, c in metadata)
        if (c != "")
            result[tag] = c;
    return result;
}

function array_contains(values, needle) {
    for (let value in array_or_empty(values)) {
        if (value == needle)
            return true;
    }
    return false;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function object_keys_set(values) {
    let result = {};
    for (let value in array_or_empty(values))
        result[value] = true;
    return result;
}

function tag_display_name(tag, names) {
    let name = as_string(object_or_empty(names)[tag] || "");
    return name != "" ? name : tag;
}

function regex_match_set(tags, names, regexes) {
    return object_keys_set(runtime_urltest.regex_matching_tag_array(tags, names, regexes));
}

function format_outbound_type_label(protocol, transport) {
    let p = lc(as_string(protocol || ""));
    let norm_proto = "";
    if (p == "vless") norm_proto = "VLESS";
    else if (p == "vmess") norm_proto = "VMess";
    else if (p == "shadowsocks" || p == "ss") norm_proto = "Shadowsocks";
    else if (p == "trojan") norm_proto = "Trojan";
    else if (p == "wireguard" || p == "wg") norm_proto = "WireGuard";
    else if (p == "amneziawg" || p == "awg") norm_proto = "AmneziaWG";
    else if (p == "hysteria2" || p == "hy2") norm_proto = "Hysteria2";
    else if (p == "hysteria") norm_proto = "Hysteria";
    else if (p == "tuic") norm_proto = "TUIC";
    else if (p == "anytls") norm_proto = "AnyTLS";
    else if (p == "naive") norm_proto = "NaiveProxy";
    else if (p == "mieru") norm_proto = "Mieru";
    else if (p == "snell") norm_proto = "Snell";
    else if (p == "sudoku") norm_proto = "Sudoku";
    else if (p == "masque") norm_proto = "MASQUE";
    else if (p == "openvpn") norm_proto = "OpenVPN";
    else if (p == "openconnect") norm_proto = "OpenConnect";
    else if (p == "tewfai") norm_proto = "Tewfai";
    else if (p == "trusttunnel") norm_proto = "TrustTunnel";
    else if (p == "mtproto" || p == "mtproxy") norm_proto = "MTProto";
    else if (p == "shadowtls") norm_proto = "ShadowTLS";
    else if (p == "fptn") norm_proto = "FPTN";
    else if (p == "desync") norm_proto = "Desync";
    else if (p == "chain") norm_proto = "Chain";
    else if (p == "tailscale") norm_proto = "Tailscale";
    else if (p == "socks" || p == "socks5") norm_proto = "SOCKS5";
    else if (p == "http") norm_proto = "HTTP";
    else if (p == "direct") norm_proto = "Direct";
    else if (p == "block") norm_proto = "Block";
    else if (p != "") norm_proto = uc(substr(p, 0, 1)) + substr(p, 1);

    let t = lc(as_string(transport || ""));
    let norm_trans = "";
    if (t == "xhttp") norm_trans = "XHTTP";
    else if (t == "ws" || t == "websocket") norm_trans = "WS";
    else if (t == "grpc") norm_trans = "gRPC";
    else if (t == "http" || t == "h2") norm_trans = "HTTP";
    else if (t == "tcp" || t == "raw") norm_trans = "TCP";
    else if (t == "quic") norm_trans = "QUIC";
    else if (t == "upgrade" || t == "httpupgrade") norm_trans = "HTTPUpgrade";
    else if (t != "") norm_trans = uc(t);

    if (norm_proto == "" && norm_trans == "")
        return "";
    if (norm_proto == "")
        return norm_trans;
    if (norm_trans == "")
        return norm_proto;
    if (index(uc(norm_proto), uc(norm_trans)) >= 0)
        return norm_proto;
    if (norm_proto == "WireGuard" || norm_proto == "Hysteria" || norm_proto == "Hysteria2" || norm_proto == "TUIC")
        return norm_proto;
    return norm_proto + " (" + norm_trans + ")";
}

function tag_display_name_with_type(tag, names, metadata) {
    let name = tag_display_name(tag, names);
    let proto = object_or_empty(object_or_empty(metadata).protocols)[tag];
    let trans = object_or_empty(object_or_empty(metadata).transports)[tag];
    let label = format_outbound_type_label(proto, trans);
    return label != "" ? (name + " [" + label + "]") : name;
}

function tag_name_filter_matches(tag, names, name_filter, regex_set, metadata, name_with_type_indexed) {
    let name = tag_display_name(tag, names);
    if (array_contains(name_filter, name) || array_contains(name_filter, tag) || regex_set[tag])
        return true;
    if (name_with_type_indexed != null && array_contains(name_filter, name_with_type_indexed))
        return true;
    if (name_with_type_indexed == null && type(metadata) == "object") {
        let name_with_type = tag_display_name_with_type(tag, names, metadata);
        if (name_with_type != name && array_contains(name_filter, name_with_type))
            return true;
    }
    return false;
}

function tag_country_filter_matches(tag, countries, country_filter) {
    let country = uc(as_string(object_or_empty(countries)[tag] || ""));
    return country != "" && array_contains(country_filter, country);
}

function tag_attribute_filter_matches(tag, metadata, selected_values) {
    selected_values = array_or_empty(selected_values);
    if (length(selected_values) == 0)
        return true;

    let value = lc(as_string(object_or_empty(metadata)[tag] || ""));
    if (value == "")
        return false;
    for (let selected in selected_values)
        if (lc(as_string(selected)) == value)
            return true;
    return false;
}

function port_matches_condition(port_num, condition) {
    condition = trim(as_string(condition));
    if (condition == "")
        return false;
    let dash = index(condition, "-");
    if (dash < 0)
        return int(condition) == port_num;
    let start = int(substr(condition, 0, dash));
    let end = int(substr(condition, dash + 1));
    if (start == null || end == null)
        return false;
    return port_num >= start && port_num <= end;
}

function tag_port_filter_matches(tag, ports_metadata, selected_ports) {
    if (length(array_or_empty(selected_ports)) == 0)
        return true;
    let port_str = as_string(object_or_empty(ports_metadata)[tag] || "");
    if (port_str == "")
        return false;
    let port_num = int(port_str);
    if (port_num == null || port_num <= 0)
        return false;
    for (let selected in selected_ports) {
        if (port_matches_condition(port_num, selected))
            return true;
    }
    return false;
}

function proxy_parameter_filter_matches_all(tag, metadata, protocols, transports, securities, ports) {
    metadata = object_or_empty(metadata);
    return tag_attribute_filter_matches(tag, metadata.protocols, protocols) &&
        tag_attribute_filter_matches(tag, metadata.transports, transports) &&
        tag_attribute_filter_matches(tag, metadata.securities, securities) &&
        tag_port_filter_matches(tag, metadata.ports, ports);
}

function proxy_parameter_filter_matches_any(tag, metadata, protocols, transports, securities, ports) {
    metadata = object_or_empty(metadata);
    return (length(array_or_empty(protocols)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.protocols, protocols)) ||
        (length(array_or_empty(transports)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.transports, transports)) ||
        (length(array_or_empty(securities)) > 0 &&
            tag_attribute_filter_matches(tag, metadata.securities, securities)) ||
        (length(array_or_empty(ports)) > 0 &&
            tag_port_filter_matches(tag, metadata.ports, ports));
}

function name_or_country_filter_configured(name_filter, regexes, country_filter) {
    return length(array_or_empty(name_filter)) > 0 ||
        length(array_or_empty(regexes)) > 0 ||
        length(array_or_empty(country_filter)) > 0;
}

function urltest_all_candidate_outbounds(urltest_candidate_tags) {
    return unique_string_array(urltest_candidate_tags);
}

function urltest_matching_candidate_outbounds(urltest_candidate_tags, names, countries, name_filter, regexes, country_filter,
    metadata, proxy_parameters_enabled, proxy_parameters_operator, protocols, transports, securities, ports, additional_matches) {
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    country_filter = runtime_urltest.normalized_country_list(country_filter);

    let regex_set = regex_match_set(urltest_candidate_tags, names, regexes);
    let base_filter_configured = name_or_country_filter_configured(name_filter, regexes, country_filter);
    let additional_set = object_keys_set(additional_matches);
    let result = [];

    let seen_type_counts = {};
    for (let tag in array_or_empty(urltest_candidate_tags)) {
        let name_with_type = tag_display_name_with_type(tag, names, metadata);
        seen_type_counts[name_with_type] = (seen_type_counts[name_with_type] || 0) + 1;
        let count = seen_type_counts[name_with_type];
        let name_with_type_indexed = count > 1 ? (name_with_type + " (#" + count + ")") : name_with_type;

        let base_matches = tag_name_filter_matches(tag, names, name_filter, regex_set, metadata, name_with_type_indexed) ||
            tag_country_filter_matches(tag, countries, country_filter);
        let matches = additional_set[tag] || base_matches;
        if (proxy_parameters_enabled && proxy_parameters_operator == "or") {
            matches = additional_set[tag] || base_matches || proxy_parameter_filter_matches_any(
                tag, metadata, protocols, transports, securities, ports
            );
        }
        else if (proxy_parameters_enabled) {
            if (!base_filter_configured)
                base_matches = true;
            matches = additional_set[tag] ||
                (base_matches && proxy_parameter_filter_matches_all(
                    tag, metadata, protocols, transports, securities, ports
                ));
        }

        if (matches)
            push(result, tag);
    }

    return unique_string_array(result);
}

function urltest_exclude_outbounds(all_outbounds, excluded_outbounds) {
    let excluded = object_keys_set(excluded_outbounds);
    let result = [];
    for (let tag in array_or_empty(all_outbounds)) {
        if (!excluded[tag])
            push(result, tag);
    }
    return result;
}

function filter_candidate_outbounds(filter_mode, urltest_candidate_tags, names, countries, metadata,
    include_names, include_regex, include_countries,
    include_proxy_parameters, include_protocols, include_transports, include_securities, include_ports,
    exclude_names, exclude_regex, exclude_countries,
    exclude_proxy_parameters, exclude_protocols, exclude_transports, exclude_securities, exclude_ports,
    include_additional_matches, exclude_additional_matches,
    hidden_tags) {
    let all_outbounds = urltest_all_candidate_outbounds(urltest_candidate_tags);
    let visible_outbounds = all_outbounds;
    if (hidden_tags && length(keys(hidden_tags)) > 0) {
        let filtered = [];
        for (let tag in all_outbounds) {
            if (!hidden_tags[tag])
                push(filtered, tag);
        }
        if (length(filtered) > 0)
            visible_outbounds = filtered;
    }

    if (filter_mode == "" || filter_mode == "disabled")
        return visible_outbounds;
    if (!supported_urltest_filter_mode(filter_mode))
        return visible_outbounds;

    let include_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        include_names,
        include_regex,
        include_countries,
        metadata,
        include_proxy_parameters,
        "and",
        include_protocols,
        include_transports,
        include_securities,
        include_ports,
        include_additional_matches
    );
    let exclude_outbounds = urltest_matching_candidate_outbounds(
        urltest_candidate_tags,
        names,
        countries,
        exclude_names,
        exclude_regex,
        exclude_countries,
        metadata,
        exclude_proxy_parameters,
        "or",
        exclude_protocols,
        exclude_transports,
        exclude_securities,
        exclude_ports,
        exclude_additional_matches
    );

    if (filter_mode == "include")
        return include_outbounds;
    if (filter_mode == "exclude")
        return urltest_exclude_outbounds(visible_outbounds, exclude_outbounds);
    if (filter_mode == "mixed")
        return urltest_exclude_outbounds(include_outbounds, exclude_outbounds);
    return visible_outbounds;
}

function tag_prefix_filter_matches(tag, names, metadata, prefixes) {
    prefixes = array_or_empty(prefixes);
    if (length(prefixes) == 0)
        return false;
    let stored_prefix = lc(trim(as_string(object_or_empty(object_or_empty(metadata).prefixes)[tag] || "")));
    let stored_source = lc(trim(as_string(object_or_empty(object_or_empty(metadata).sources)[tag] || "")));
    let display = lc(trim(tag_display_name(tag, names)));
    let raw_tag = lc(trim(as_string(tag)));
    for (let p in prefixes) {
        let pl = lc(trim(as_string(p)));
        if (pl == "")
            continue;
        let bare = replace(pl, /^\[|\]$/g, "");
        if (bare == "")
            continue;
        if (stored_prefix != "" && (stored_prefix == bare || stored_prefix == pl))
            return true;
        if (stored_source != "" && (stored_source == bare || stored_source == pl))
            return true;
        if (substr(bare, 0, 4) == "sub:" || substr(bare, 0, 4) == "src_")
            continue;
        if (index(display, "[" + bare + "]") == 0 ||
            index(display, bare + " ") == 0 ||
            index(display, bare + "-") == 0 ||
            index(display, bare + "_") == 0 ||
            display == bare ||
            index(raw_tag, bare) == 0)
            return true;
    }
    return false;
}

function country_metadata_for_method(detect_method, state) {
    let names = object_or_empty(object_or_empty(state.outboundMetadata).names);
    let from_flags = runtime_urltest.countries_from_flag_names(names);
    if (detect_method == "flag_emoji")
        return from_flags;
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let result = {};
    for (let t, c in from_flags)
        result[t] = c;
    for (let t, c in metadata)
        if (c != "")
            result[t] = c;
    return result;
}

// Multi-criteria group filter where non-empty include categories (prefix, country,
// name/regex, proxy_parameters) intersect via AND, while exclude categories subtract via OR.
function filter_tags_by_group_spec(candidate_tags, spec, state) {
    if (spec == null || type(spec) != "object")
        return unique_string_array(candidate_tags);
    let mode = as_string(spec.mode || "disabled");
    let all_tags = unique_string_array(candidate_tags);
    let hidden_tags = object_or_empty(state ? state.hiddenOutboundTags : null);
    if (mode == "" || mode == "disabled") {
        if (length(keys(hidden_tags)) > 0) {
            let vis = [];
            for (let t in all_tags)
                if (!hidden_tags[t])
                    push(vis, t);
            if (length(vis) > 0)
                return vis;
        }
        return all_tags;
    }

    let metadata = object_or_empty(state ? state.outboundMetadata : null);
    let names = object_or_empty(metadata.names);
    let countries = country_metadata_for_method(as_string(spec.country_mode || "flag_emoji"), state || {});

    let inc_prefixes = array_or_empty(spec.include_prefixes);
    let inc_countries = runtime_urltest.normalized_country_list(spec.include_countries);
    let inc_names = array_or_empty(spec.include_outbounds);
    let inc_regex = array_or_empty(spec.include_regex);
    let inc_regex_set = regex_match_set(all_tags, names, inc_regex);
    let inc_params = spec.include_proxy_parameters == true && (
        length(array_or_empty(spec.include_protocols)) > 0 ||
        length(array_or_empty(spec.include_transports)) > 0 ||
        length(array_or_empty(spec.include_securities)) > 0 ||
        length(array_or_empty(spec.include_ports)) > 0
    );

    let has_inc_prefix = length(inc_prefixes) > 0;
    let has_inc_country = length(inc_countries) > 0;
    let has_inc_name_regex = length(inc_names) > 0 || length(inc_regex) > 0;
    let any_inc_category = has_inc_prefix || has_inc_country || has_inc_name_regex || inc_params;

    if (!has_inc_name_regex && length(keys(hidden_tags)) > 0) {
        let vis = [];
        for (let t in all_tags)
            if (!hidden_tags[t])
                push(vis, t);
        if (length(vis) > 0)
            all_tags = vis;
    }

    let exc_prefixes = array_or_empty(spec.exclude_prefixes);
    let exc_countries = runtime_urltest.normalized_country_list(spec.exclude_countries);
    let exc_names = array_or_empty(spec.exclude_outbounds);
    let exc_regex = array_or_empty(spec.exclude_regex);
    let exc_regex_set = regex_match_set(all_tags, names, exc_regex);
    let exc_params = spec.exclude_proxy_parameters == true && (
        length(array_or_empty(spec.exclude_protocols)) > 0 ||
        length(array_or_empty(spec.exclude_transports)) > 0 ||
        length(array_or_empty(spec.exclude_securities)) > 0 ||
        length(array_or_empty(spec.exclude_ports)) > 0
    );

    let result = [];
    let seen_type_counts = {};
    for (let t in all_tags) {
        let name_with_type = tag_display_name_with_type(t, names, metadata);
        seen_type_counts[name_with_type] = (seen_type_counts[name_with_type] || 0) + 1;
        let count = seen_type_counts[name_with_type];
        let name_with_type_indexed = count > 1 ? (name_with_type + " (#" + count + ")") : name_with_type;

        if (mode == "include" || mode == "mixed") {
            if (!any_inc_category)
                continue;
            if (has_inc_prefix && !tag_prefix_filter_matches(t, names, metadata, inc_prefixes))
                continue;
            if (has_inc_country && !tag_country_filter_matches(t, countries, inc_countries))
                continue;
            if (has_inc_name_regex && !tag_name_filter_matches(t, names, inc_names, inc_regex_set, metadata, name_with_type_indexed))
                continue;
            if (inc_params && !proxy_parameter_filter_matches_all(
                t, metadata, spec.include_protocols, spec.include_transports, spec.include_securities, spec.include_ports
            ))
                continue;
        }

        if (mode == "exclude" || mode == "mixed") {
            let is_excluded = false;
            if (length(exc_prefixes) > 0 && tag_prefix_filter_matches(t, names, metadata, exc_prefixes))
                is_excluded = true;
            if (!is_excluded && length(exc_countries) > 0 && tag_country_filter_matches(t, countries, exc_countries))
                is_excluded = true;
            if (!is_excluded && (length(exc_names) > 0 || length(exc_regex) > 0) &&
                tag_name_filter_matches(t, names, exc_names, exc_regex_set, metadata, name_with_type_indexed))
                is_excluded = true;
            if (!is_excluded && exc_params && proxy_parameter_filter_matches_any(
                t, metadata, spec.exclude_protocols, spec.exclude_transports, spec.exclude_securities, spec.exclude_ports
            ))
                is_excluded = true;
            if (is_excluded)
                continue;
        }

        push(result, t);
    }
    return result;
}

function urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state) {
    let grefs = type(connections.urltest_group_refs) == "function"
        ? connections.urltest_group_refs(section, urltest_id)
        : [];
    if (length(grefs) > 0) {
        let union_cand = [];
        for (let grp_id in grefs) {
            let gspec = connections.outbound_group_filter_spec(grp_id, section);
            if (gspec == null)
                continue;
            for (let t in filter_tags_by_group_spec(urltest_candidate_tags, gspec, state))
                push(union_cand, t);
        }
        if (length(union_cand) > 0)
            urltest_candidate_tags = unique_string_array(union_cand);
    }
    let inc_prefixes = connections.urltest_include_prefixes(section, urltest_id);
    let exc_prefixes = connections.urltest_exclude_prefixes(section, urltest_id);
    if (length(inc_prefixes) > 0 || length(exc_prefixes) > 0) {
        return filter_tags_by_group_spec(urltest_candidate_tags, {
            mode: connections.urltest_filter_mode(section, urltest_id),
            country_mode: connections.urltest_detect_server_country(section, urltest_id),
            include_prefixes: inc_prefixes,
            include_countries: connections.urltest_include_countries(section, urltest_id),
            include_outbounds: connections.urltest_include_outbounds(section, urltest_id),
            include_regex: connections.urltest_include_regex(section, urltest_id),
            include_proxy_parameters: connections.urltest_include_proxy_parameters(section, urltest_id),
            include_protocols: connections.urltest_include_protocols(section, urltest_id),
            include_transports: connections.urltest_include_transports(section, urltest_id),
            include_securities: connections.urltest_include_securities(section, urltest_id),
            include_ports: connections.urltest_include_ports(section, urltest_id),
            exclude_prefixes: exc_prefixes,
            exclude_countries: connections.urltest_exclude_countries(section, urltest_id),
            exclude_outbounds: connections.urltest_exclude_outbounds(section, urltest_id),
            exclude_regex: connections.urltest_exclude_regex(section, urltest_id),
            exclude_proxy_parameters: connections.urltest_exclude_proxy_parameters(section, urltest_id),
            exclude_protocols: connections.urltest_exclude_protocols(section, urltest_id),
            exclude_transports: connections.urltest_exclude_transports(section, urltest_id),
            exclude_securities: connections.urltest_exclude_securities(section, urltest_id),
            exclude_ports: connections.urltest_exclude_ports(section, urltest_id)
        }, state);
    }

    return filter_candidate_outbounds(
        connections.urltest_filter_mode(section, urltest_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        urltest_country_metadata(section, urltest_id, state),
        object_or_empty(state.outboundMetadata),
        connections.urltest_include_outbounds(section, urltest_id),
        connections.urltest_include_regex(section, urltest_id),
        connections.urltest_include_countries(section, urltest_id),
        connections.urltest_include_proxy_parameters(section, urltest_id),
        connections.urltest_include_protocols(section, urltest_id),
        connections.urltest_include_transports(section, urltest_id),
        connections.urltest_include_securities(section, urltest_id),
        connections.urltest_include_ports(section, urltest_id),
        connections.urltest_exclude_outbounds(section, urltest_id),
        connections.urltest_exclude_regex(section, urltest_id),
        connections.urltest_exclude_countries(section, urltest_id),
        connections.urltest_exclude_proxy_parameters(section, urltest_id),
        connections.urltest_exclude_protocols(section, urltest_id),
        connections.urltest_exclude_transports(section, urltest_id),
        connections.urltest_exclude_securities(section, urltest_id),
        connections.urltest_exclude_ports(section, urltest_id),
        null,
        null,
        state ? state.hiddenOutboundTags : null
    );
}

function priority_level_country_metadata(group_id, level_id, state) {
    let names = object_or_empty(object_or_empty(state.outboundMetadata).names);
    let from_flags = runtime_urltest.countries_from_flag_names(names);
    let detect_method = connections.priority_level_detect_server_country(group_id, level_id);
    if (detect_method == "flag_emoji")
        return from_flags;
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let result = {};
    for (let tag, c in from_flags)
        result[tag] = c;
    for (let tag, c in metadata)
        if (c != "")
            result[tag] = c;
    return result;
}

function priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state) {
    if (connections.priority_level_direct(group_id, level_id))
        return [ runtime_constants.DIRECT_OUTBOUND_TAG ];

    let inc_prefixes = connections.priority_level_include_prefixes(group_id, level_id);
    let exc_prefixes = connections.priority_level_exclude_prefixes(group_id, level_id);
    let child_obj = connections.priority_level_items(group_id);
    let from_outbound_group = false;
    for (let it in child_obj) {
        if (as_string(it[".name"] || "") == as_string(level_id) && it.outbound_group_ref != null) {
            from_outbound_group = true;
            break;
        }
    }
    if (from_outbound_group || length(inc_prefixes) > 0 || length(exc_prefixes) > 0) {
        return filter_tags_by_group_spec(urltest_candidate_tags, {
            mode: connections.priority_level_filter_mode(group_id, level_id),
            country_mode: connections.priority_level_detect_server_country(group_id, level_id),
            include_prefixes: inc_prefixes,
            include_countries: connections.priority_level_include_countries(group_id, level_id),
            include_outbounds: connections.priority_level_include_outbounds(group_id, level_id),
            include_regex: connections.priority_level_include_regex(group_id, level_id),
            include_proxy_parameters: connections.priority_level_include_proxy_parameters(group_id, level_id),
            include_protocols: connections.priority_level_include_protocols(group_id, level_id),
            include_transports: connections.priority_level_include_transports(group_id, level_id),
            include_securities: connections.priority_level_include_securities(group_id, level_id),
            include_ports: connections.priority_level_include_ports(group_id, level_id),
            exclude_prefixes: exc_prefixes,
            exclude_countries: connections.priority_level_exclude_countries(group_id, level_id),
            exclude_outbounds: connections.priority_level_exclude_outbounds(group_id, level_id),
            exclude_regex: connections.priority_level_exclude_regex(group_id, level_id),
            exclude_proxy_parameters: connections.priority_level_exclude_proxy_parameters(group_id, level_id),
            exclude_protocols: connections.priority_level_exclude_protocols(group_id, level_id),
            exclude_transports: connections.priority_level_exclude_transports(group_id, level_id),
            exclude_securities: connections.priority_level_exclude_securities(group_id, level_id),
            exclude_ports: connections.priority_level_exclude_ports(group_id, level_id)
        }, state);
    }

    return filter_candidate_outbounds(
        connections.priority_level_filter_mode(group_id, level_id),
        urltest_candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        priority_level_country_metadata(group_id, level_id, state),
        object_or_empty(state.outboundMetadata),
        connections.priority_level_include_outbounds(group_id, level_id),
        connections.priority_level_include_regex(group_id, level_id),
        connections.priority_level_include_countries(group_id, level_id),
        connections.priority_level_include_proxy_parameters(group_id, level_id),
        connections.priority_level_include_protocols(group_id, level_id),
        connections.priority_level_include_transports(group_id, level_id),
        connections.priority_level_include_securities(group_id, level_id),
        connections.priority_level_include_ports(group_id, level_id),
        connections.priority_level_exclude_outbounds(group_id, level_id),
        connections.priority_level_exclude_regex(group_id, level_id),
        connections.priority_level_exclude_countries(group_id, level_id),
        connections.priority_level_exclude_proxy_parameters(group_id, level_id),
        connections.priority_level_exclude_protocols(group_id, level_id),
        connections.priority_level_exclude_transports(group_id, level_id),
        connections.priority_level_exclude_securities(group_id, level_id),
        connections.priority_level_exclude_ports(group_id, level_id),
        null,
        null,
        state ? state.hiddenOutboundTags : null
    );
}

function dashboard_country_metadata(section, state) {
    let names = object_or_empty(object_or_empty(state.outboundMetadata).names);
    let from_flags = runtime_urltest.countries_from_flag_names(names);
    if (connections.dashboard_detect_server_country(section) == "flag_emoji")
        return from_flags;
    let metadata = object_or_empty(object_or_empty(state.outboundMetadata).countries);
    let result = {};
    for (let tag, c in from_flags)
        result[tag] = c;
    for (let tag, c in metadata)
        if (c != "")
            result[tag] = c;
    return result;
}

function selected_group_outbounds(group_names, group_outbounds) {
    group_outbounds = object_or_empty(group_outbounds);
    let result = [];
    for (let group_name in array_or_empty(group_names))
        for (let tag_name in array_or_empty(group_outbounds[group_name]))
            push(result, tag_name);
    return unique_string_array(result);
}

function remember_dashboard_group_outbounds(group_outbounds, group_name, outbounds) {
    group_name = as_string(group_name);
    if (group_name == "")
        return;

    let combined = array_or_empty(group_outbounds[group_name]);
    for (let tag_name in array_or_empty(outbounds))
        push(combined, tag_name);
    group_outbounds[group_name] = unique_string_array(combined);
}

function dashboard_filtered_outbounds(section, selector_tags, state, group_outbounds) {
    return filter_candidate_outbounds(
        connections.dashboard_filter_mode(section),
        selector_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        dashboard_country_metadata(section, state),
        object_or_empty(state.outboundMetadata),
        connections.dashboard_include_outbounds(section),
        connections.dashboard_include_regex(section),
        connections.dashboard_include_countries(section),
        connections.dashboard_include_proxy_parameters(section),
        connections.dashboard_include_protocols(section),
        connections.dashboard_include_transports(section),
        connections.dashboard_include_securities(section),
        connections.dashboard_include_ports(section),
        connections.dashboard_exclude_outbounds(section),
        connections.dashboard_exclude_regex(section),
        connections.dashboard_exclude_countries(section),
        connections.dashboard_exclude_proxy_parameters(section),
        connections.dashboard_exclude_protocols(section),
        connections.dashboard_exclude_transports(section),
        connections.dashboard_exclude_securities(section),
        connections.dashboard_exclude_ports(section),
        selected_group_outbounds(connections.dashboard_include_groups(section), group_outbounds),
        selected_group_outbounds(connections.dashboard_exclude_groups(section), group_outbounds)
    );
}

function priority_levels_with_outbounds(group_id, urltest_candidate_tags, state) {
    let result = [];
    let assigned = {};

    for (let level_id in connections.priority_levels(group_id)) {
        let outbounds = [];
        for (let tag_name in priority_level_filtered_outbounds(group_id, level_id, urltest_candidate_tags, state)) {
            if (!assigned[tag_name]) {
                assigned[tag_name] = true;
                push(outbounds, tag_name);
            }
        }

        push(result, {
            id: level_id,
            displayName: connections.priority_level_display_name(group_id, level_id),
            order: int(connections.priority_level_order(group_id, level_id), 10),
            direct: connections.priority_level_direct(group_id, level_id),
            filter_mode: connections.priority_level_filter_mode(group_id, level_id),
            detect_server_country: connections.priority_level_detect_server_country(group_id, level_id),
            outbounds
        });
    }

    return result;
}

function priority_group_outbounds(levels) {
    let result = [];
    let seen = {};
    for (let level in array_or_empty(levels)) {
        for (let tag_name in array_or_empty(level.outbounds)) {
            tag_name = as_string(tag_name);
            if (tag_name != "" && !seen[tag_name]) {
                seen[tag_name] = true;
                push(result, tag_name);
            }
        }
    }
    return result;
}

function urltest_outbound_tag(section_name, urltest_id) {
    urltest_id = as_string(urltest_id);
    return urltest_id == "urltest"
        ? outbound_tag(section_name + "-urltest")
        : outbound_tag(section_name + "-urltest-" + urltest_id);
}

function priority_outbound_tag(section_name, group_id) {
    return outbound_tag(section_name + "-priority-" + as_string(group_id));
}

// Section group (action 'group'): members keep their own selectors, but their
// route rules are repointed at one flat urltest over the union of member
// leaves. add_proxy_selector records each section's leaf candidates; the
// post-pass add_group_urltest_outbounds builds the urltest and fills
// section_group_map, which route generation reads.
function remember_section_leaf_tags(name, tags) {
    section_leaf_tags[name] = tags;
}

function find_outbound_by_tag(config, want) {
    for (let outbound in array_or_empty(config.outbounds))
        if (as_string(outbound.tag) == want)
            return outbound;
    for (let endpoint in array_or_empty(config.endpoints))
        if (as_string(endpoint.tag) == want)
            return endpoint;
    return null;
}

// urltest tag of the group this section belongs to (or the group's own urltest
// tag when the section itself has action 'group'), or "" when the section is
// not a group member (or its group produced no urltest).
function group_outbound_tag_for_section(section) {
    if (type(section) != "object")
        return "";
    if (option(section, "action", "") == "group")
        return as_string(active_group_tags[section[".name"]] || "");
    let group_name = as_string(section_group_map[section[".name"]]);
    if (group_name == "")
        return "";
    return as_string(active_group_tags[group_name] || urltest_outbound_tag(group_name, "urltest"));
}

function group_member_action_supported(action) {
    action = as_string(action);
    if (action == "group")
        return false;
    return connections.is_connections_action(action) ||
        action == "awg" || action == "warp" ||
        action == "anytls" || action == "snell" || action == "mieru" || action == "naive" || action == "sudoku" ||
        action == "masque" || action == "openvpn" || action == "fptn";
}

// Union of the member sections' leaf outbound tags. Sections that went through
// add_proxy_selector contribute their recorded candidates; single-outbound
// sections (anytls, snell, ...) fall back to their own top-level outbound.
function group_member_leaf_tags(members, config) {
    let tags = [];
    for (let member in members) {
        let name = member[".name"];
        if (ctx.deferred_sections && ctx.deferred_sections[name])
            continue;
        let recorded = section_leaf_tags[name];
        if (type(recorded) == "array") {
            for (let candidate in recorded)
                push(tags, candidate);
            continue;
        }
        let own_tag = outbound_tag(name);
        let outbound = find_outbound_by_tag(config, own_tag);
        if (outbound != null && ctx.outbounds.urltest_leaf_candidate_outbound(outbound))
            push(tags, own_tag);
    }
    return unique_string_array(tags);
}

function is_extended_variant_detected() {
    let sb_variant_val = variant_state.read_variant_marker();
    if (sb_variant_val == "extended" || sb_variant_val == "extended-compressed")
        return true;
    let sb_version_val = variant_state.read_version_state();
    return index(sb_version_val, "extended") >= 0;
}

function add_urltest_outbound(config, section, urltest_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let urltest_outbounds = urltest_filtered_outbounds(section, urltest_id, urltest_candidate_tags, state);
    let urltest_tag = urltest_outbound_tag(section_name, urltest_id);
    let display_name = connections.urltest_display_name(section, urltest_id);
    let urltest_outbound = {
        type: "urltest",
        tag: urltest_tag,
        outbounds: urltest_outbounds,
        url: connections.urltest_testing_url(section, urltest_id),
        interval: urltest_check_interval(section, urltest_id),
        tolerance: int(connections.urltest_tolerance(section, urltest_id), 10),
        interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, urltest_id)
    };
    let idle_timeout = urltest_idle_timeout(section, urltest_id);
    if (idle_timeout != "")
        urltest_outbound.idle_timeout = idle_timeout;

    runtime_subscription.remember_outbound_metadata(state, urltest_tag, display_name, urltest_outbound);
    runtime_subscription.remember_urltest_group_config(state, urltest_tag, {
        displayName: display_name,
        outbounds: urltest_outbounds,
        url: urltest_outbound.url,
        interval: urltest_outbound.interval,
        tolerance: urltest_outbound.tolerance,
        idle_timeout: urltest_outbound.idle_timeout,
        interrupt_exist_connections: urltest_outbound.interrupt_exist_connections
    });

    if (length(urltest_outbounds) == 0)
        return {
            tag: "",
            outbounds: []
        };

    push(config.outbounds, urltest_outbound);
    return {
        tag: urltest_tag,
        outbounds: urltest_outbounds
    };
}

function routed_dns_server_tag(section_name) {
    return runtime_constants.tag(section_name, "routed-dns-server");
}

function add_routed_dns_server_for_section(config, section) {
    if (!connections.routed_dns_enabled(section))
        return;
    let section_name = section[".name"];
    let action = option(section, "action", "");
    let servers = connections.routed_dns_servers(section);
    let dns_type = connections.routed_dns_type(section);
    let tag_name = routed_dns_server_tag(section_name);
    let detour = action == "bypass" ? null : (group_outbound_tag_for_section(section) || outbound_tag(section_name));

    for (let i = 0; i < length(servers); i++) {
        let s_val = servers[i];
        // The rule references the un-indexed tag, so the first server has to
        // carry it however many are configured — with a single server this is
        // the same tag as before, with several the rest get -2, -3, …
        let server_tag = i == 0
            ? tag_name
            : runtime_constants.tag(section_name, "routed-dns-server-" + (i + 1));
        let server = runtime_dns.server_from_options(
            server_tag,
            dns_type,
            s_val,
            detour
        );
        if (server.unsupported)
            ctx.runtime_generate_unsupported(server.unsupported);
        push(config.dns.servers, server);
    }
}

function merge_member_state_into_group(group_state, member, config) {
    let name = member[".name"];
    let member_state = section_state_map[name];
    if (type(member_state) == "object") {
        let recorded = section_leaf_tags[name];
        let allowed = (type(recorded) == "array") ? object_keys_set(recorded) : null;
        for (let k, v in object_or_empty(member_state.links)) {
            if (!allowed || allowed[k])
                group_state.links[k] = v;
        }
        for (let k, v in object_or_empty(member_state.servers)) {
            if (!allowed || allowed[k])
                group_state.servers[k] = v;
        }
        for (let item in array_or_empty(member_state.subscriptionMetadata))
            push(group_state.subscriptionMetadata, item);
        let member_meta = object_or_empty(member_state.outboundMetadata);
        for (let field in [ "names", "countries", "protocols", "transports", "securities", "prefixes", "ports", "details", "sources" ]) {
            if (!group_state.outboundMetadata[field])
                group_state.outboundMetadata[field] = {};
            for (let k, v in object_or_empty(member_meta[field])) {
                if (!allowed || allowed[k])
                    group_state.outboundMetadata[field][k] = v;
            }
        }
        return;
    }

    let own_tag = outbound_tag(name);
    let outbound = find_outbound_by_tag(config, own_tag);
    if (outbound != null && ctx.outbounds.urltest_leaf_candidate_outbound(outbound)) {
        let display_name = trim(option(member, "label", option(member, "name", "")));
        if (display_name == "")
            display_name = name;
        runtime_subscription.remember_outbound_metadata(group_state, own_tag, display_name, outbound);
    }
}

function add_priority_group_outbound(config, section, group_id, urltest_candidate_tags, state) {
    let section_name = section[".name"];
    let levels = priority_levels_with_outbounds(group_id, urltest_candidate_tags, state);
    let outbounds = priority_group_outbounds(levels);
    let priority_tag = priority_outbound_tag(section_name, group_id);
    let display_name = connections.priority_group_display_name(section, group_id);
    let outbound = {
        type: "selector",
        tag: priority_tag,
        outbounds,
        default: outbounds[0],
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id)
    };

    runtime_subscription.remember_outbound_metadata(state, priority_tag, display_name, outbound);
    runtime_subscription.remember_priority_group(state, priority_tag, {
        id: group_id,
        tag: priority_tag,
        section: section_name,
        displayName: display_name,
        health_url: connections.priority_group_health_url(section, group_id),
        active_check_interval: connections.priority_group_active_check_interval(section, group_id),
        check_timeout: connections.priority_group_check_timeout(section, group_id),
        recovery_check_interval: connections.priority_group_recovery_check_interval(section, group_id),
        pick_fastest: connections.priority_group_pick_fastest(section, group_id),
        switch_to_faster_same_priority: connections.priority_group_switch_to_faster_same_priority(section, group_id),
        fastest_check_interval: connections.priority_group_fastest_check_interval(section, group_id),
        interrupt_exist_connections: connections.priority_group_interrupt_exist_connections(section, group_id),
        pin_dashboard: connections.priority_group_pin_dashboard(section, group_id),
        outbounds,
        levels
    });

    if (length(outbounds) == 0)
        return {
            tag: "",
            outbounds: []
        };

    push(config.outbounds, outbound);
    return {
        tag: priority_tag,
        outbounds
    };
}

// Post-pass: after every section has generated its outbounds, build one flat
// urltest per group section over the union of member leaves and record the
// member -> group mapping used to repoint route rules. Deferred (quarantined)
// members contribute no leaves; a group with no live members is not emitted.
function add_group_urltest_outbounds(config, sections) {
    for (let section in sections) {
        if (option(section, "action", "") != "group")
            continue;
        let group_name = section[".name"];
        if (ctx.deferred_sections && ctx.deferred_sections[group_name])
            continue;
        ctx.current_section = group_name;

        let wanted = {};
        for (let member_name in list_option(section, "group_members"))
            wanted[trim(as_string(member_name))] = true;

        let members = [];
        for (let candidate in sections)
            if (wanted[candidate[".name"]])
                push(members, candidate);

        let tags = group_member_leaf_tags(members, config);
        if (length(tags) == 0) {
            warn("Section group " + group_name + " has no member servers available, the group is not generated\n");
            continue;
        }

        let state = runtime_subscription.new_section_state(group_name);
        for (let member in members)
            merge_member_state_into_group(state, member, config);

        if (section_needs_country_is(section)) {
            let previous_state = read_json_file(runtime_subscription.section_cache_path(group_name));
            state.outboundMetadata.countries = runtime_country.detect(
                state.servers,
                previous_state,
                option(ctx.runtime_settings(), "bootstrap_dns_server", "77.88.8.8")
            );
        }
        if (section_has_direct_priority_level(section))
            state.outboundMetadata.names[runtime_constants.DIRECT_OUTBOUND_TAG] = "Direct";

        let configured_urltests = connections.urltests(section);
        let urltest_ids = length(configured_urltests) > 0 ? configured_urltests : [ "urltest" ];
        let urltest_tags = [];
        let priority_tags = [];
        let leaf_outbounds = [];

        for (let urltest_id in urltest_ids) {
            let result = add_urltest_outbound(config, section, urltest_id, tags, state);
            if (result.tag == "")
                continue;
            push(urltest_tags, result.tag);
            for (let t in result.outbounds)
                push(leaf_outbounds, t);
        }

        for (let group_id in connections.priority_groups(section)) {
            let priority = add_priority_group_outbound(config, section, group_id, tags, state);
            if (priority.tag == "")
                continue;
            push(priority_tags, priority.tag);
            for (let t in priority.outbounds)
                push(leaf_outbounds, t);
        }

        if (length(urltest_tags) == 0 && length(priority_tags) == 0)
            continue;

        let selector_tag = outbound_tag(group_name);
        let merged_leaves = unique_string_array(length(leaf_outbounds) > 0 ? leaf_outbounds : tags);
        let selector_outbounds = [];
        for (let t in merged_leaves)
            push(selector_outbounds, t);
        for (let t in urltest_tags)
            push(selector_outbounds, t);
        for (let t in priority_tags)
            push(selector_outbounds, t);
        let selector_default = length(urltest_tags) > 0 ? urltest_tags[0] : priority_tags[0];
        let persistent_selector_file = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
        let saved_selector_state = read_json_file(persistent_selector_file);
        if (type(saved_selector_state) == "object" && as_string(saved_selector_state[selector_tag]) != "") {
            let saved_target = as_string(saved_selector_state[selector_tag]);
            if (index(selector_outbounds, saved_target) >= 0)
                selector_default = saved_target;
        }
        push(config.outbounds, {
            type: "selector",
            tag: selector_tag,
            outbounds: selector_outbounds,
            default: selector_default,
            interrupt_exist_connections: connections.urltest_interrupt_exist_connections(section, "urltest")
        });

        state.urltestCandidateTags = unique_string_array(tags);
        if (!getenv("SB_PREFLIGHT_BINARY") && !ctx.atomic_write_json_file(runtime_subscription.section_cache_path(group_name), state))
            ctx.runtime_generate_unsupported("failed to write section cache for " + group_name);

        active_group_tags[group_name] = selector_tag;
        for (let member in members) {
            let name = member[".name"];
            if (section_group_map[name] != null)
                warn("Rule " + name + " belongs to several section groups; " +
                    as_string(section_group_map[name]) + " wins, " + group_name + " is ignored\n");
            else
                section_group_map[name] = group_name;
        }
        add_routed_dns_server_for_section(config, section);
    }
    ctx.current_section = null;
}

function is_mieru_detour(config, tag, depth) {
    depth = int(depth || 0);
    if (depth > 5 || tag == null || tag == "")
        return false;
    for (let out in array_or_empty(config.outbounds)) {
        if (type(out) == "object" && out.tag == tag) {
            if (out.type == "mieru")
                return true;
            if ((out.type == "selector" || out.type == "urltest") && type(out.outbounds) == "array") {
                for (let sub in out.outbounds) {
                    if (is_mieru_detour(config, sub, depth + 1))
                        return true;
                }
            }
        }
    }
    return false;
}

function is_valid_detour(config, tag) {
    if (tag == null || tag == "")
        return false;
    if (tag == runtime_constants.DIRECT_OUTBOUND_TAG || tag == runtime_constants.BYPASS_OUTBOUND_TAG)
        return true;
    for (let out in array_or_empty(config.outbounds)) {
        if (type(out) == "object" && out.tag == tag) {
            if (out.tag == "DPI-out" || (out.type == "socks" && (out.server == "127.0.0.1" || out.server == "::1")))
                return false;
            if (out.routing_mark != null)
                return false;
            if (out.type == "mieru" || is_mieru_detour(config, tag, 0))
                return false;
            return true;
        }
    }
    for (let ep in array_or_empty(config.endpoints)) {
        if (type(ep) == "object" && ep.tag == tag) {
            if (ep.routing_mark != null)
                return false;
            return true;
        }
    }
    return false;
}

// sing-box 1.14.0 deprecated the remote rule-set `download_detour` field in
// favour of `http_client`, and removed it in 1.16.0. The replacement names a
// declared HTTP client, so a detour that the old field carried inline now needs
// a client of its own. `ruleset-http` already exists in base_config and covers
// the no-detour case; cores below 1.14 keep `download_detour`, since
// `http_clients` is an unknown top-level field there and sing-box aborts the
// whole config on it.
function download_http_client_tag(config, detour) {
    if (!ctx.is_sb_1_14_plus || !ctx.is_sb_1_14_plus())
        return "";
    if (!is_valid_detour(config, detour))
        return "ruleset-http";

    let tag = "tachyon-download-" + detour;
    let registered = false;
    for (let client in array_or_empty(config.http_clients)) {
        if (type(client) == "object" && client.tag == tag)
            registered = true;
    }
    if (!registered) {
        if (config.http_clients == null)
            config.http_clients = [];
        push(config.http_clients, { tag: tag, detour: detour });
    }

    return tag;
}

// Applies whichever download transport the installed core understands, so the
// three remote rule-set builders share one call.
function apply_download_transport(config, rule_set, detour) {
    let http_client = download_http_client_tag(config, detour);
    if (http_client != "") {
        rule_set.http_client = http_client;
        if (config.route.default_http_client == null || config.route.default_http_client == "")
            config.route.default_http_client = http_client;
        return;
    }
    if (is_valid_detour(config, detour))
        rule_set.download_detour = detour;
}

function section_excluded_candidate_tags(section, candidate_tags, state) {
    let mode = connections.dashboard_filter_mode(section);
    if (mode != "exclude" && mode != "mixed")
        return [];

    let exclude_names = connections.dashboard_exclude_outbounds(section);
    let exclude_regex = connections.dashboard_exclude_regex(section);
    let exclude_countries = connections.dashboard_exclude_countries(section);
    let exclude_proxy_parameters = connections.dashboard_exclude_proxy_parameters(section);
    let exclude_protocols = connections.dashboard_exclude_protocols(section);
    let exclude_transports = connections.dashboard_exclude_transports(section);
    let exclude_securities = connections.dashboard_exclude_securities(section);
    let exclude_ports = connections.dashboard_exclude_ports(section);

    let has_exclude_criteria = length(exclude_names) > 0 ||
        length(exclude_regex) > 0 ||
        length(exclude_countries) > 0 ||
        (exclude_proxy_parameters && (
            length(exclude_protocols) > 0 ||
            length(exclude_transports) > 0 ||
            length(exclude_securities) > 0 ||
            length(exclude_ports) > 0
        ));

    if (!has_exclude_criteria)
        return [];

    return urltest_matching_candidate_outbounds(
        candidate_tags,
        object_or_empty(object_or_empty(state.outboundMetadata).names),
        dashboard_country_metadata(section, state),
        exclude_names,
        exclude_regex,
        exclude_countries,
        object_or_empty(state.outboundMetadata),
        exclude_proxy_parameters,
        "or",
        exclude_protocols,
        exclude_transports,
        exclude_securities,
        exclude_ports
    );
}

function add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state, text_urltest_tag) {
    let section_name = section[".name"];
    if (type(state) == "object")
        section_state_map[section_name] = state;

    let group_refs = connections.section_outbound_group_refs(section);
    if (length(group_refs) > 0) {
        let union_selector = [];
        let union_cand = [];
        for (let grp_id in group_refs) {
            let gspec = connections.outbound_group_filter_spec(grp_id, section);
            if (gspec == null)
                continue;
            for (let t in filter_tags_by_group_spec(selector_tags, gspec, state))
                push(union_selector, t);
            for (let t in filter_tags_by_group_spec(urltest_candidate_tags, gspec, state))
                push(union_cand, t);
        }
        if (length(union_selector) > 0)
            selector_tags = unique_string_array(union_selector);
        if (length(union_cand) > 0)
            urltest_candidate_tags = unique_string_array(union_cand);
    }

    let sec_pool_spec = connections.section_pool_filter_spec(section);
    if (sec_pool_spec != null) {
        let narrowed_sel = filter_tags_by_group_spec(selector_tags, sec_pool_spec, state);
        let narrowed_cand = filter_tags_by_group_spec(urltest_candidate_tags, sec_pool_spec, state);
        if (length(narrowed_sel) > 0 || sec_pool_spec.mode == "exclude")
            selector_tags = narrowed_sel;
        if (length(narrowed_cand) > 0 || sec_pool_spec.mode == "exclude")
            urltest_candidate_tags = narrowed_cand;
    }

    let selector_tag = outbound_tag(section_name);
    let selector_outbounds = selector_tags;
    let selector_default = selector_tags[0];
    let urltest_tags = [];
    let priority_tags = [];
    let group_outbounds = {};

    let section_excluded = section_excluded_candidate_tags(section, urltest_candidate_tags, state);
    let group_candidate_tags = length(section_excluded) > 0
        ? urltest_exclude_outbounds(urltest_candidate_tags, section_excluded)
        : urltest_candidate_tags;

    for (let urltest_id in connections.urltests(section)) {
        let urltest = add_urltest_outbound(config, section, urltest_id, group_candidate_tags, state);
        remember_dashboard_group_outbounds(
            group_outbounds,
            connections.urltest_display_name(section, urltest_id),
            urltest.outbounds
        );
        if (urltest.tag == "")
            continue;

        push(urltest_tags, urltest.tag);
    }

    if (as_string(text_urltest_tag) != "" && index(urltest_tags, as_string(text_urltest_tag)) < 0)
        push(urltest_tags, text_urltest_tag);

    for (let group_id in connections.priority_groups(section)) {
        let priority = add_priority_group_outbound(config, section, group_id, group_candidate_tags, state);
        remember_dashboard_group_outbounds(
            group_outbounds,
            connections.priority_group_display_name(section, group_id),
            priority.outbounds
        );
        if (priority.tag == "")
            continue;

        push(priority_tags, priority.tag);
    }

    let dashboard_candidates = selector_tags;
    let mode = connections.dashboard_filter_mode(section);
    if (mode == "include" || mode == "mixed") {
        let combined = [];
        for (let t in selector_tags) push(combined, t);
        for (let t in urltest_candidate_tags) push(combined, t);
        dashboard_candidates = unique_string_array(combined);
    }

    let filtered_outbounds = dashboard_filtered_outbounds(section, dashboard_candidates, state, group_outbounds);
    // An include/mixed filter that matches nothing used to fall through to the
    // urltest/priority groups below, silently shrinking the section to just the
    // groups (TCH-1036). Fall back to every available server instead and say so.
    if ((mode == "include" || mode == "mixed") && length(filtered_outbounds) == 0 && length(selector_tags) > 0) {
        warn("Section " + section_name + ": dashboard filter \"" + mode + "\" matched none of the " +
            length(selector_tags) + " loaded servers (selected names do not match any server; " +
            "a changed node prefix or a refreshed subscription can invalidate them) — " +
            "falling back to all available subscription servers\n");
        filtered_outbounds = selector_tags;
    }

    let effective_leaf_tags = group_candidate_tags;
    if ((mode == "include" || mode == "exclude" || mode == "mixed") && length(filtered_outbounds) > 0) {
        let allowed_set = object_keys_set(filtered_outbounds);
        let narrowed = [];
        for (let t in group_candidate_tags) {
            if (allowed_set[t])
                push(narrowed, t);
        }
        if (length(narrowed) > 0 || mode == "exclude")
            effective_leaf_tags = narrowed;
    }
    remember_section_leaf_tags(section_name, effective_leaf_tags);

    let sec_source_refs = connections.section_outbound_source_refs(section);
    let sel_mode = lc(trim(option(section, "section_selection_mode", "auto")));
    let meta_sources = object_or_empty(object_or_empty(state.outboundMetadata).sources);
    let sub_urls = connections.subscription_urls(section);
    let source_level_entries = [];
    let has_dpi_source = false;
    let first_is_dpi = false;

    if (length(sec_source_refs) > 0 && length(filtered_outbounds) > 0) {
        let ordered_filtered = [];
        let seen_ordered = {};
        for (let s_idx = 0; s_idx < length(sec_source_refs); s_idx++) {
            let src_id = sec_source_refs[s_idx];
            let src = connections.outbound_source_section(src_id);
            let stype = src != null ? option(src, "source_type", "") : "";
            let is_dpi = connections.is_dpi_or_desync_source_type && connections.is_dpi_or_desync_source_type(stype);
            if (is_dpi) {
                has_dpi_source = true;
                if (s_idx == 0)
                    first_is_dpi = true;
            }
            let src_url = src != null ? trim(option(src, "url", "")) : "";
            let sub_marker = "";
            if (src_url != "") {
                for (let u_idx = 0; u_idx < length(sub_urls); u_idx++) {
                    if (trim(as_string(sub_urls[u_idx])) == src_url) {
                        sub_marker = "sub:" + (u_idx + 1);
                        break;
                    }
                }
            }
            let this_src_tags = [];
            for (let t in filtered_outbounds) {
                let m_src = as_string(meta_sources[t] || "");
                if (m_src == src_id || (sub_marker != "" && m_src == sub_marker)) {
                    push(this_src_tags, t);
                    if (!seen_ordered[t]) {
                        seen_ordered[t] = true;
                        push(ordered_filtered, t);
                    }
                }
            }
            if (length(this_src_tags) > 0) {
                push(source_level_entries, {
                    id: src_id,
                    displayName: src != null ? (option(src, "name", src_id) || src_id) : src_id,
                    outbounds: this_src_tags
                });
            }
        }
        for (let t in filtered_outbounds) {
            if (!seen_ordered[t]) {
                seen_ordered[t] = true;
                push(ordered_filtered, t);
            }
        }
        filtered_outbounds = ordered_filtered;
    }

    selector_outbounds = filtered_outbounds;
    selector_default = selector_outbounds[0];
    if (length(urltest_tags) > 0 || length(priority_tags) > 0) {
        for (let tag in urltest_tags)
            push(selector_outbounds, tag);
        for (let tag in priority_tags)
            push(selector_outbounds, tag);
        if (!first_is_dpi && sel_mode != "priority_failover")
            selector_default = length(urltest_tags) > 0 ? urltest_tags[0] : priority_tags[0];
    }

    if (sel_mode == "priority_failover" || (sel_mode != "default" && has_dpi_source)) {
        let auto_levels = [];
        let lvl_order = 1;
        for (let entry in source_level_entries) {
            push(auto_levels, {
                id: entry.id,
                displayName: entry.displayName,
                order: lvl_order++,
                direct: false,
                outbounds: entry.outbounds
            });
        }
        for (let ut_tag in urltest_tags) {
            push(auto_levels, {
                id: ut_tag,
                displayName: ut_tag,
                order: lvl_order++,
                direct: false,
                outbounds: [ ut_tag ]
            });
        }
        if (length(auto_levels) >= 2) {
            let h_url = trim(option(section, "section_health_url", "https://www.gstatic.com/generate_204"));
            if (h_url == "")
                h_url = "https://www.gstatic.com/generate_204";
            runtime_subscription.remember_priority_group(state, selector_tag, {
                id: section_name + "_failover",
                tag: selector_tag,
                section: section_name,
                displayName: option(section, "label", section_name) || section_name,
                health_url: h_url,
                active_check_interval: "5s",
                check_timeout: "2s",
                recovery_check_interval: "15s",
                pick_fastest: true,
                switch_to_faster_same_priority: true,
                fastest_check_interval: "3m",
                interrupt_exist_connections: true,
                pin_dashboard: false,
                outbounds: selector_outbounds,
                levels: auto_levels
            });
        }
    }

    if (length(selector_outbounds) == 0) {
        if (length(selector_tags) > 0) {
            selector_outbounds = selector_tags;
            selector_default = selector_outbounds[0];
            warn("Section " + section_name + ": server filtering produced no matches, falling back to all available subscription servers\n");
        }
        else {
            selector_outbounds = [ runtime_constants.DIRECT_OUTBOUND_TAG ];
            selector_default = runtime_constants.DIRECT_OUTBOUND_TAG;
            warn("Section " + section_name + ": subscription has no loaded servers yet, using direct fallback until cache is populated\n");
        }
    }

    if (state && state.hiddenOutboundTags) {
        for (let tag in selector_outbounds)
            delete state.hiddenOutboundTags[tag];
    }

    let persistent_selector_file = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
    let saved_selector_state = read_json_file(persistent_selector_file);
    if (type(saved_selector_state) == "object" && as_string(saved_selector_state[selector_tag]) != "") {
        let saved_target = as_string(saved_selector_state[selector_tag]);
        if (index(selector_outbounds, saved_target) >= 0)
            selector_default = saved_target;
    }

    push(config.outbounds, {
        type: "selector",
        tag: selector_tag,
        outbounds: selector_outbounds,
        default: selector_default,
        interrupt_exist_connections: true
    });
}

function ensure_custom_ruleset(config, reference) {
    let tag_name;
    let kind = runtime_rulesets.kind_from_reference_hint(reference);

    if (runtime_rulesets.is_community(reference)) {
        tag_name = "builtin-" + reference + "-ruleset";
        kind = runtime_rulesets.community_kind ? runtime_rulesets.community_kind(reference) : "domains";
        if (!ruleset_registered(config, tag_name)) {
            let folder = ctx.runtime_ruleset_folder || runtime_ruleset_folder;
            let tmp_srs = folder + "/community-" + reference + ".srs";
            let etc_srs = "/etc/tachyon/rulesets/community-" + reference + ".srs";
            let local_path = null;

            // is_populated_srs_file, not is_valid_srs_file: the fetch-failure
            // stub is itself a valid 17-byte SRS, and treating it as downloaded
            // emits a local rule_set with no url, so sing-box can never fetch the
            // real list and the rule matches nothing (TCH-1043).
// is_referenceable_srs_file: the question is whether sing-box can read the file,
// not whether it matches anything. The 17-byte placeholder is valid and parseable,
// so it stays referenced locally and a cold boot without a network still applies -
// emitting a remote rule-set there puts the fetch back into startup, and a GitHub
// hiccup then kills the core. A truncated list is valid-looking and unreadable, and
// that one must fall through to the remote url, because a config pointing at a file
// sing-box cannot parse is refused outright ("unexpected EOF") and leaves the router
// unable to apply anything. is_populated_srs_file alone answers neither: it accepts
// the truncation.
if (runtime_rulesets.is_referenceable_srs_file(tmp_srs))
            local_path = tmp_srs;
        else if (runtime_rulesets.is_referenceable_srs_file(etc_srs))
            local_path = etc_srs;

        if (config.route.rule_set == null)
            config.route.rule_set = [];

        if (local_path != null) {
            push(config.route.rule_set, {
                type: "local",
                tag: tag_name,
                format: "binary",
                path: local_path
            });
        }
        else {
            let rule_set = {
                type: "remote",
                tag: tag_name,
                format: "binary",
                url: runtime_rulesets.community_url(reference)
            };
                let detour = ctx.download_detour_tag(ctx.runtime_settings());
                apply_download_transport(config, rule_set, detour);
                rule_set.update_interval = remote_ruleset_update_interval();
                push(config.route.rule_set, rule_set);
            }
        }
        return { tag: tag_name, kind };
    }

    tag_name = "inline-custom-" + runtime_rulesets.hash12(reference) + "-ruleset";
    if (ruleset_registered(config, tag_name))
        return { tag: tag_name, kind };

    let extension = runtime_rulesets.file_extension(reference);
    let folder = ctx.runtime_ruleset_folder || runtime_ruleset_folder;
    common.ensure_dir(folder);

    if (runtime_rulesets.is_plain_list_reference(reference)) {
        let srs_path = folder + "/" + tag_name + ".srs";
        let json_path = folder + "/" + tag_name + ".json";
        let etc_srs = "/etc/tachyon/rulesets/" + tag_name + ".srs";
        let etc_json = "/etc/tachyon/rulesets/" + tag_name + ".json";

        if (substr(reference, 0, 1) == "/") {
            if (!helpers.file_is_usable(reference, 1))
                return null;

            let ref_st = fs.stat(reference);
            let srs_st = fs.stat(srs_path);
            if (srs_st && runtime_rulesets.is_valid_srs_file(srs_path) && ref_st && srs_st.mtime >= ref_st.mtime) {
                push(config.route.rule_set, {
                    type: "local",
                    tag: tag_name,
                    format: "binary",
                    path: srs_path
                });
                return { tag: tag_name, kind: "domains" };
            }

            let res = source_rulesets.compile_plain_list(reference, srs_path, json_path);
            push(config.route.rule_set, {
                type: "local",
                tag: tag_name,
                format: res.format,
                path: res.path
            });
            return { tag: tag_name, kind: res.has_domains ? "domains" : "unknown" };
        }
        else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
            if (runtime_rulesets.is_valid_srs_file(srs_path)) {
                push(config.route.rule_set, {
                    type: "local",
                    tag: tag_name,
                    format: "binary",
                    path: srs_path
                });
                return { tag: tag_name, kind: "domains" };
            }
            else if (runtime_rulesets.is_valid_srs_file(etc_srs)) {
                common.copy_file(etc_srs, srs_path);
                push(config.route.rule_set, {
                    type: "local",
                    tag: tag_name,
                    format: "binary",
                    path: srs_path
                });
                return { tag: tag_name, kind: "domains" };
            }
            else if (fs.stat(json_path) != null) {
                push(config.route.rule_set, {
                    type: "local",
                    tag: tag_name,
                    format: "source",
                    path: json_path
                });
                return { tag: tag_name, kind: "domains" };
            }
            else if (fs.stat(etc_json) != null) {
                common.copy_file(etc_json, json_path);
                push(config.route.rule_set, {
                    type: "local",
                    tag: tag_name,
                    format: "source",
                    path: json_path
                });
                return { tag: tag_name, kind: "domains" };
            }
            else {
                let tmp_plain = folder + "/" + tag_name + ".tmp.plain";
                let dl_ok = false;
                if (common.command_success("command -v curl"))
                    dl_ok = common.command_success_from_args([ "curl", "-fsSL", "--connect-timeout", "5", "-m", "10", reference, "-o", tmp_plain ]);
                else if (common.command_success("command -v wget"))
                    dl_ok = common.command_success_from_args([ "wget", "-q", "-T", "10", "-O", tmp_plain, reference ]);

                if (dl_ok && helpers.file_is_usable(tmp_plain, 1)) {
                    common.ensure_dir("/etc/tachyon/rulesets");
                    let res = source_rulesets.compile_plain_list(tmp_plain, srs_path, json_path);
                    if (res.format == "binary")
                        common.copy_file(srs_path, etc_srs);
                    else
                        common.copy_file(json_path, etc_json);
                    fs.unlink(tmp_plain);
                    push(config.route.rule_set, {
                        type: "local",
                        tag: tag_name,
                        format: res.format,
                        path: res.path
                    });
                    return { tag: tag_name, kind: res.has_domains ? "domains" : "unknown" };
                }
                else {
                    fs.unlink(tmp_plain);
                    runtime_rulesets.ensure_empty_srs_stub(srs_path);
                    push(config.route.rule_set, {
                        type: "local",
                        tag: tag_name,
                        format: "binary",
                        path: srs_path
                    });
                    return { tag: tag_name, kind: "domains" };
                }
            }
        }
        else {
            ctx.runtime_generate_unsupported("plain list reference is not supported by sing-box config generation");
        }
    }
    else if (substr(reference, 0, 1) == "/") {
        if (extension != "srs" && extension != "json")
            ctx.runtime_generate_unsupported("local rule_set extension is not supported by sing-box config generation");
        // Skip broken local ruleset files — nonexistent or suspiciously small
        if (!helpers.file_is_usable(reference, 100))
            return null;
        if (config.route.rule_set == null)
            config.route.rule_set = [];
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: extension == "json" ? "source" : "binary",
            path: reference
        });
    }
    else if (substr(reference, 0, 7) == "http://" || substr(reference, 0, 8) == "https://") {
        let rule_set = {
            type: "remote",
            tag: tag_name,
            format: runtime_rulesets.remote_format(reference),
            url: reference
        };
        let detour = ctx.download_detour_tag(ctx.runtime_settings());
        apply_download_transport(config, rule_set, detour);
        rule_set.update_interval = remote_ruleset_update_interval();
        if (config.route.rule_set == null)
            config.route.rule_set = [];
        push(config.route.rule_set, rule_set);
    }
    else {
        ctx.runtime_generate_unsupported("rule_set reference is not supported by sing-box config generation");
    }

    return { tag: tag_name, kind };
}



function ensure_community_ruleset(config, section_name, community) {
    if (!runtime_rulesets.is_community(community))
        ctx.runtime_generate_unsupported("unknown community list " + community);

    let tag_name = ruleset_tag(section_name, community, "community");
    if (!ruleset_registered(config, tag_name)) {
        let folder = ctx.runtime_ruleset_folder || runtime_ruleset_folder;
        let tmp_srs = folder + "/community-" + community + ".srs";
        let etc_srs = "/etc/tachyon/rulesets/community-" + community + ".srs";
        let local_path = null;

// is_referenceable_srs_file: the placeholder is valid and parseable, so it stays
// local and a boot without a network still applies (a remote rule-set here puts the
// fetch back into startup, where a GitHub hiccup kills the core). A truncated list
// passes is_populated_srs_file and is unreadable, and a config pointing at it is
// refused outright, so it falls through to the remote url below.
if (runtime_rulesets.is_referenceable_srs_file(tmp_srs))
            local_path = tmp_srs;
        else if (runtime_rulesets.is_referenceable_srs_file(etc_srs))
            local_path = etc_srs;

        if (config.route.rule_set == null)
            config.route.rule_set = [];

        if (local_path != null) {
            push(config.route.rule_set, {
                type: "local",
                tag: tag_name,
                format: "binary",
                path: local_path
            });
        }
        else {
            let rule_set = {
                type: "remote",
                tag: tag_name,
                format: "binary",
                url: runtime_rulesets.community_url(community),
                update_interval: remote_ruleset_update_interval()
            };
            let detour = ctx.download_detour_tag(ctx.runtime_settings(), "lists");
            if (detour == "" && section_name != "") {
                let sec_out = outbound_tag(section_name);
                if (sec_out != "" && sec_out != runtime_constants.DIRECT_OUTBOUND_TAG && sec_out != runtime_constants.BYPASS_OUTBOUND_TAG) {
                    detour = sec_out;
                }
            }
            apply_download_transport(config, rule_set, detour);
            push(config.route.rule_set, rule_set);
        }
    }
    return {
        tag: tag_name,
        kind: runtime_rulesets.community_kind ? runtime_rulesets.community_kind(community) : "domains"
    };
}

function domain_ip_list_ruleset_tag(section_name) {
    return ruleset_tag(section_name, "lists", "");
}

function domain_ip_list_ruleset_path(section_name) {
    let folder = ctx.runtime_ruleset_folder || runtime_ruleset_folder;
    let tag = domain_ip_list_ruleset_tag(section_name);
    let tmp_path = folder + "/" + tag + ".json";
    let etc_path = "/etc/tachyon/rulesets/" + tag + ".json";
    if (source_rulesets.has_rules(tmp_path))
        return tmp_path;
    if (source_rulesets.has_rules(etc_path))
        return etc_path;
    return tmp_path;
}

function reference_is_local(reference) {
    return substr(as_string(reference), 0, 1) == "/";
}

function source_file_exists(path) {
    return fs.readfile(path) != null;
}

function rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only) {
    let folder = ctx.runtime_ruleset_folder || runtime_ruleset_folder;
    let ruleset_path = folder + "/" + domain_ip_list_ruleset_tag(section_name) + ".json";
    let has_local = false;

    for (let reference in references) {
        if (reference_is_local(reference)) {
            has_local = true;
            break;
        }
    }

    if (!has_local)
        return;

    fs.unlink(ruleset_path);
    source_rulesets.create_source(ruleset_path);

    for (let reference in references) {
        reference = as_string(reference);
        if (!reference_is_local(reference))
            continue;
        if (!source_file_exists(reference)) {
            warn("local domain/IP list not found: ", reference, "\n");
            continue;
        }

        source_rulesets.import_plain_list(reference, ruleset_path, "domain_suffix", "domains", "5000");
        if (!domains_only)
            source_rulesets.import_plain_list(reference, ruleset_path, "ip_cidr", "subnets", "5000");
    }
}

function add_domain_ip_list_ruleset(config, section_name, rule_set_tags, dns_query_rule_set_tags, dns_response_rule_set_tags, references, domains_only) {
    if (length(references) == 0)
        return;

    rebuild_local_domain_ip_list_ruleset(section_name, references, domains_only);

    let ruleset_path = domain_ip_list_ruleset_path(section_name);
    if (!source_rulesets.has_rules(ruleset_path))
        return;

    let tag_name = domain_ip_list_ruleset_tag(section_name);
    let has_domains = source_rulesets.has_domain_matchers(ruleset_path);
    let has_ips = source_rulesets.has_ip_matchers(ruleset_path);

    if (config.route.rule_set == null)
        config.route.rule_set = [];

    // If ruleset has BOTH domains and IP subnets, split them so domains can go to DNS without
    // causing sing-box 1.14+ to require match_response: true, which erroneously issues FakeIP for pure-IP matches.
    if (has_domains && has_ips) {
        let folder = ctx.runtime_ruleset_folder || runtime_ruleset_folder;
        let dom_path = folder + "/" + tag_name + "-domains.json";
        let sub_path = folder + "/" + tag_name + "-subnets.json";
        let dom_tag = tag_name + "-domains";
        let sub_tag = tag_name + "-subnets";

        let raw = common.read_json_file(ruleset_path);
        if (raw && type(raw.rules) == "array") {
            let dom_rules = [];
            let sub_rules = [];
            for (let r in raw.rules) {
                if (r.domain != null || r.domain_suffix != null || r.domain_keyword != null || r.domain_regex != null)
                    push(dom_rules, r);
                if (r.ip_cidr != null)
                    push(sub_rules, r);
            }
            common.write_json_file(dom_path, { version: raw.version || 3, rules: dom_rules });
            common.write_json_file(sub_path, { version: raw.version || 3, rules: sub_rules });

            if (!ruleset_registered(config, dom_tag)) {
                push(config.route.rule_set, {
                    type: "local",
                    tag: dom_tag,
                    format: "source",
                    path: dom_path
                });
            }
            if (!ruleset_registered(config, sub_tag)) {
                push(config.route.rule_set, {
                    type: "local",
                    tag: sub_tag,
                    format: "source",
                    path: sub_path
                });
            }

            push(rule_set_tags, dom_tag);
            if (!domains_only)
                push(rule_set_tags, sub_tag);

            if (dns_query_rule_set_tags != null)
                push(dns_query_rule_set_tags, dom_tag);
            return;
        }
    }

    if (!ruleset_registered(config, tag_name)) {
        push(config.route.rule_set, {
            type: "local",
            tag: tag_name,
            format: "source",
            path: ruleset_path
        });
    }

    if (!domains_only)
        push(rule_set_tags, tag_name);

    if (has_domains && dns_query_rule_set_tags != null)
        push(dns_query_rule_set_tags, tag_name);
}

function legacy_condition_values(section, key) {
    let raw_values = object_or_empty(section)[key];
    let list_values = type(raw_values) == "array"
        ? raw_values
        : [];
    let option_text_values = type(raw_values) == "array" || key == "domain"
        ? []
        : rule_config.text_list_values(raw_values, "comma-space");
    let text_value = option(section, key + "_text", "");
    let text_values = rule_config.text_list_values(text_value, "comma-space");

    if (bool_option(section, key + "_text_mode", false) || bool_option(section, "conditions_text_mode", false))
        return text_values;
    if (length(list_values) > 0)
        return list_values;
    if (length(option_text_values) > 0)
        return option_text_values;
    return text_values;
}

function combined_domain_source_values(section) {
    let values = [];
    if (type(object_or_empty(section)["domain"]) != "array") {
        for (let value in rule_config.text_list_values(option(section, "domain", ""), "comma-space"))
            if (as_string(value) != "")
                push(values, as_string(value));
    }
    for (let value in rule_config.text_list_values(option(section, "domain_suffix_text", ""), "comma-space"))
        if (as_string(value) != "")
            push(values, as_string(value));
    for (let value in list_option(section, "domain_suffix"))
        if (as_string(value) != "")
            push(values, as_string(value));
    for (let value in list_option(section, "user_domains"))
        if (as_string(value) != "")
            push(values, as_string(value));
    for (let value in rule_config.text_list_values(option(section, "user_domains_text", ""), "comma-space"))
        if (as_string(value) != "")
            push(values, as_string(value));
    return values;
}

function domain_suffix_condition_value_kind(value) {
    return rule_config.prefixed_domain_kind_value(value);
}

function domain_conditions(section) {
    let result = {
        domain: [],
        domain_suffix: [],
        domain_keyword: [],
        domain_regex: []
    };

    for (let key in [ "domain", "domain_keyword", "domain_regex" ]) {
        for (let value in legacy_condition_values(section, key)) {
            let normalized = rule_config.domain_value_for_key(value, key);
            if (normalized != null)
                push(result[key], normalized);
        }
    }

    for (let value in combined_domain_source_values(section)) {
        let normalized = domain_suffix_condition_value_kind(value);
        if (normalized != null)
            push(result[normalized.kind], normalized.value);
    }

    return result;
}

function add_domain_array(rule, key, values) {
    if (length(values) > 0)
        rule[key] = values;
}

function sanitize_rule(rule) {
    if (!rule)
        return null;
    if (rule.type == "logical" && type(rule.rules) == "array") {
        let clean_subrules = [];
        for (let sub in rule.rules) {
            if (sub && length(keys(sub)) > 0)
                push(clean_subrules, sub);
        }
        if (length(clean_subrules) == 0)
            return null;
        if (length(clean_subrules) == 1) {
            let single = {};
            for (let k, v in rule) {
                if (k != "type" && k != "mode" && k != "rules")
                    single[k] = v;
            }
            for (let k, v in clean_subrules[0])
                single[k] = v;
            return single;
        }
        rule.rules = clean_subrules;
    }
    return rule;
}

function push_dns_matcher_rule(config, rule) {
    rule = sanitize_rule(rule);
    if (rule)
        push(config.dns.rules, rule);
}

function push_route_matcher_rule(config, rule) {
    rule = sanitize_rule(rule);
    if (rule)
        push(config.route.rules, rule);
}

function section_fail_state_map() {
    let path = getenv("TACHYON_SECTION_FAIL_STATE_FILE") || "/var/run/tachyon/section-fail-state.json";
    let data = read_json_file(path);
    return type(data) == "object" ? data : {};
}

function section_is_failed_or_quarantined(section_name) {
    section_name = as_string(section_name);
    if (section_name == "")
        return false;
    if (ctx.deferred_sections && ctx.deferred_sections[section_name])
        return true;
    if (ctx.quarantined_sections && ctx.quarantined_sections[section_name])
        return true;
    let fstate = section_fail_state_map();
    let entry = fstate[section_name];
    if (type(entry) == "object")
        return common.bool_value(entry.failed);
    return common.bool_value(entry);
}

function section_fail_policy_mode(section) {
    let raw = lc(trim(option(section, "fail_policy", "keep")));
    if (raw == "block" || raw == "direct")
        return raw;
    return "keep";
}

function section_fail_policy_override_target(section) {
    let name = as_string(section[".name"]);
    if (!section_is_failed_or_quarantined(name))
        return null;
    let policy = section_fail_policy_mode(section);
    if (policy == "block")
        return { action: "reject", fail_policy: "block" };
    if (policy == "direct")
        return { action: "route", outbound: runtime_constants.DIRECT_OUTBOUND_TAG, fail_policy: "direct" };
    return null;
}

function section_dns_server(section) {
    let override = section_fail_policy_override_target(section);
    if (override != null) {
        if (override.fail_policy == "direct")
            return runtime_constants.DNS_SERVER_TAG;
        return runtime_constants.FAKEIP_DNS_SERVER_TAG;
    }
    if (connections.routed_dns_enabled(section))
        return runtime_constants.tag(section[".name"], "routed-dns-server");
    if (option(section, "action", "") == "bypass")
        return runtime_constants.DNS_SERVER_TAG;
    return runtime_constants.FAKEIP_DNS_SERVER_TAG;
}

function section_is_ipv4_only_dpi(section) {
    let action = option(section, "action", "");
    if (action != "zapret" && action != "zapret2")
        return false;
    let opt_key = action == "zapret2" ? "nfqws2_opt" : "nfqws_opt";
    let raw = trim(option(section, opt_key, ""));
    if (raw == "" || index(raw, "--filter-l3=ipv4") < 0)
        return false;
    return match(raw, /--filter-l3=[^[:space:]]*ipv6/) == null;
}

// The fakeip server synthesises addresses and answers A and AAAA only. Without
// an explicit query_type every other type went there too and got nothing, so the
// client waited out its own timeout: MX for mail, SRV for service discovery,
// TXT for SPF/DKIM. Browsers never noticed, they only ask A and AAAA.
function add_fakeip_query_type(rule, server_tag, ipv4_only) {
    if (server_tag == runtime_constants.FAKEIP_DNS_SERVER_TAG)
        rule.query_type = ipv4_only ? [ "A" ] : [ "A", "AAAA" ];
    return rule;
}

function single_or_array(values) {
    return length(values) == 1 ? values[0] : values;
}

function dns_action_server_tag(section_name, idx) {
    if (idx == null)
        return runtime_constants.tag(section_name, "dns-server");
    return runtime_constants.tag(section_name, "dns-server-" + idx);
}

function dns_action_detour_tag(section) {
    if (!bool_option(section, "dns_detour_enabled", false))
        return "";
    let target_section = option(section, "dns_detour_section", "");
    if (target_section == "")
        return "";
    if (as_string(active_group_tags[target_section] || "") != "")
        return as_string(active_group_tags[target_section]);
    let group_name = as_string(section_group_map[target_section] || "");
    if (group_name != "")
        return as_string(active_group_tags[group_name] || urltest_outbound_tag(group_name, "urltest"));
    return outbound_tag(target_section);
}

function section_dns_servers(section) {
    let servers = list_option(section, "dns_server");
    if (length(servers) == 0) {
        let single = option(section, "dns_server", "");
        servers = [single];
    }
    return servers;
}

function add_dns_server_for_section(config, section) {
    let section_name = section[".name"];
    let servers = section_dns_servers(section);
    let dns_type = option(section, "dns_type", "udp");
    let detour = dns_action_detour_tag(section);
    let server_tags = [];

    for (let i = 0; i < length(servers); i++) {
        let s_val = servers[i];
        let tag_name = length(servers) <= 1
            ? dns_action_server_tag(section_name)
            : dns_action_server_tag(section_name, i + 1);
        let server = runtime_dns.server_from_options(
            tag_name,
            dns_type,
            s_val,
            detour
        );
        if (server.unsupported)
            ctx.runtime_generate_unsupported(server.unsupported);
        push(config.dns.servers, server);
        push(server_tags, tag_name);
    }
    return server_tags;
}

function source_dns_inbound_matcher() {
    return [ runtime_constants.SOURCE_DNS_INBOUND_TAG ];
}

function add_source_dns_matchers(rule, source_ip_cidr) {
    if (length(source_ip_cidr) == 0)
        return;

    rule.inbound = source_dns_inbound_matcher();
    rule.source_ip_cidr = single_or_array(source_ip_cidr);
}

function add_dns_action_rules_for_clause(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let query_rule_set_tags = [];
    let response_rule_set_tags = [];
    let section_name = section[".name"];
    let source_ip_cidr = core_ip.normalize_to_cidrs(legacy_condition_values(section, "source_ip_cidr"));
    let fully_routed_ips = core_ip.normalize_to_cidrs(list_option(section, "fully_routed_ips"));

    for (let community in connections.community_lists(section)) {
        let ensured = ensure_community_ruleset(config, section_name, as_string(community));
        if (ensured.kind == "domains")
            push(query_rule_set_tags, ensured.tag);
        else if (ensured.kind == "subnets" || ensured.kind == "mixed")
            push(response_rule_set_tags, ensured.tag);
        else
            push(response_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        if (ensured == null)
            continue;
        if (ensured.kind == "domains")
            push(query_rule_set_tags, ensured.tag);
        else
            push(response_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets_with_subnets(section)) {
        let ensured = ensure_custom_ruleset(config, as_string(reference));
        if (ensured == null)
            continue;
        push(response_rule_set_tags, ensured.tag);
    }
    add_domain_ip_list_ruleset(
        config,
        section_name,
        [],
        query_rule_set_tags,
        response_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        true
    );

    let rewrite_ttl = int_option(ctx.runtime_settings(), "dns_rewrite_ttl", "60");
    let section_servers = section_dns_servers(section);
    let server_tags = [];
    if (length(section_servers) <= 1) {
        push(server_tags, dns_action_server_tag(section_name));
    } else {
        for (let i = 0; i < length(section_servers); i++)
            push(server_tags, dns_action_server_tag(section_name, i + 1));
    }
    let server_tag = length(server_tags) > 0 ? server_tags[0] : dns_action_server_tag(section_name);
    let has_inline_domains = length(domain) > 0 || length(domain_suffix) > 0 ||
        length(domain_keyword) > 0 || length(domain_regex) > 0;

    if (length(fully_routed_ips) > 0) {
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_source_dns_matchers(dns_rule, fully_routed_ips);
        push_dns_matcher_rule(config, dns_rule);
    }
    if (has_inline_domains) {
        let domain_matchers = [
            [ "domain", domain ],
            [ "domain_suffix", domain_suffix ],
            [ "domain_keyword", domain_keyword ],
            [ "domain_regex", domain_regex ]
        ];
        for (let dm in domain_matchers) {
            let key = dm[0];
            let values = dm[1];
            if (length(values) == 0)
                continue;
            let dns_rule = {
                action: "route",
                server: server_tag,
                rewrite_ttl
            };
            add_domain_array(dns_rule, key, values);
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_dns_matcher_rule(config, dns_rule);
        }
    }

    let is_1_14 = ctx.is_sb_1_14_plus && ctx.is_sb_1_14_plus();
    if (is_1_14) {
        if (length(query_rule_set_tags) > 0) {
            let dns_rule = {
                action: "route",
                server: server_tag,
                rewrite_ttl,
                rule_set: single_or_array(query_rule_set_tags)
            };
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_dns_matcher_rule(config, dns_rule);
        }
        if (length(response_rule_set_tags) > 0) {
            let eval_rule = {
                action: "evaluate",
                server: runtime_constants.DNS_SERVER_TAG
            };
            add_source_dns_matchers(eval_rule, source_ip_cidr);
            push_dns_matcher_rule(config, eval_rule);

            let dns_rule = {
                action: "route",
                server: server_tag,
                rewrite_ttl,
                rule_set: single_or_array(response_rule_set_tags),
                match_response: true
            };
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_dns_matcher_rule(config, dns_rule);
        }
    }
    else {
        let all_rule_set_tags = [];
        for (let tag in query_rule_set_tags)
            push(all_rule_set_tags, tag);
        for (let tag in response_rule_set_tags)
            push(all_rule_set_tags, tag);

        if (length(all_rule_set_tags) > 0) {
            let dns_rule = {
                action: "route",
                server: server_tag,
                rewrite_ttl,
                rule_set: single_or_array(all_rule_set_tags)
            };
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_dns_matcher_rule(config, dns_rule);
        }
    }

    if (!has_inline_domains && length(query_rule_set_tags) == 0 && length(response_rule_set_tags) == 0 && length(fully_routed_ips) == 0)
        ctx.runtime_generate_unsupported("DNS action '" + section_name + "' has no domain matchers");
}

function add_dns_action_rules_for_section(config, section) {
    for (let clause in connections.section_effective_clauses(section))
        add_dns_action_rules_for_clause(config, clause);
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function add_dscp_matchers(rule, section) {
    // DSCP matching is handled exclusively at the firewall/nftables layer (nft/apply.uc).
    // sing-box route rules do not support a "dscp" field; emitting it causes sing-box
    // to abort config loading with: route.rules[...].dscp: json: unknown field "dscp".
}

function add_port_matchers(rule, section) {
    let values = [];
    for (let value in list_option(section, "ports"))
        push(values, value);
    for (let value in rule_config.text_list_values(option(section, "ports_text", ""), "comma-space"))
        push(values, value);

    let ports = [];
    let port_ranges = [];
    let seen = {};
    for (let value in values) {
        value = trim(as_string(value));
        if (value == "" || seen[value])
            continue;
        seen[value] = true;

        let dash = index(value, "-");
        if (dash < 0) {
            let port = normalize_port_number_value(value);
            if (port != null)
                push(ports, port);
            continue;
        }

        let start = normalize_port_number_value(substr(value, 0, dash));
        let end = normalize_port_number_value(substr(value, dash + 1));
        if (start != null && end != null && start <= end)
            push(port_ranges, start == end ? as_string(start) : sprintf("%d:%d", start, end));
    }

    if (length(ports) > 0)
        rule.port = ports;
    if (length(port_ranges) > 0)
        rule.port_range = port_ranges;
}

function tproxy_inbound_matcher() {
    if (!core_ip.ipv6_supported())
        return [ runtime_constants.TPROXY_INBOUND_TAG ];
    return [ runtime_constants.TPROXY_INBOUND_TAG, runtime_constants.TPROXY_INBOUND6_TAG ];
}

function outbound_supports_udp(config, tag_name, visited) {
    tag_name = as_string(tag_name);
    if (tag_name == "")
        return false;
    if (tag_name == runtime_constants.DIRECT_OUTBOUND_TAG || tag_name == runtime_constants.BYPASS_OUTBOUND_TAG)
        return true;
    visited = visited || {};
    if (visited[tag_name])
        return true;
    visited[tag_name] = true;
    for (let outb in (config.outbounds || [])) {
        if (as_string(outb.tag) == tag_name) {
            let t = as_string(outb.type);
            if (t == "http" || (t == "socks" && as_string(outb.version) == "4") || t == "block")
                return false;
            if (t == "selector" || t == "urltest") {
                if (type(outb.outbounds) == "array" && length(outb.outbounds) > 0) {
                    for (let nested_tag in outb.outbounds) {
                        if (!outbound_supports_udp(config, nested_tag, visited))
                            return false;
                    }
                    return true;
                }
                return false;
            }
            return true;
        }
    }
    for (let ep in (config.endpoints || [])) {
        if (as_string(ep.tag) == tag_name)
            return true;
    }
    return false;
}

const ACTION_KEYS = {
    action: true,
    outbound: true,
    server: true,
    rewrite_ttl: true,
    client_subnet: true,
    disable_cache: true,
    disable_optimistic_cache: true,
    timeout: true,
    method: true,
    no_drop: true,
    strategy: true
};

// The two "everything except the selected countries" modes match the inverted
// set; the other two match the selected countries themselves.
function geoip_mode_inverts(country_mode) {
    return country_mode == "exclude" || country_mode == "exclude_direct";
}

function geoip_matcher_rule(geo_tags, country_mode) {
    let geo_rule = {
        rule_set: single_or_array(geo_tags)
    };
    if (geoip_mode_inverts(country_mode))
        geo_rule.invert = true;
    return geo_rule;
}

function apply_section_geoip_filter(rule, geo_tags, country_mode) {
    if (!rule || !geo_tags || length(geo_tags) == 0)
        return rule;

    let geo_rule = geoip_matcher_rule(geo_tags, country_mode);

    if (rule.type == "logical" && rule.mode == "and" && type(rule.rules) == "array") {
        let cloned = {};
        for (let k, v in rule) {
            if (k == "rules") {
                cloned.rules = [];
                for (let r in v) {
                    if (r && length(keys(r)) > 0)
                        push(cloned.rules, r);
                }
                push(cloned.rules, geo_rule);
            } else {
                cloned[k] = v;
            }
        }
        return cloned;
    }

    let match_part = {};
    for (let k, v in rule) {
        if (!ACTION_KEYS[k] && substr(k, 0, 2) != "__")
            match_part[k] = v;
    }

    if (length(keys(match_part)) == 0) {
        let single_rule = {};
        for (let k, v in rule)
            single_rule[k] = v;
        single_rule.rule_set = single_or_array(geo_tags);
        if (geoip_mode_inverts(country_mode))
            single_rule.invert = true;
        return single_rule;
    }

    let logical_rule = {
        type: "logical",
        mode: "and",
        rules: [
            match_part,
            geo_rule
        ]
    };
    for (let k, v in rule) {
        if (ACTION_KEYS[k] || substr(k, 0, 2) == "__")
            logical_rule[k] = v;
    }
    return logical_rule;
}

function apply_excluded_source_ips(rule, excluded_cidrs) {
    if (!rule || !excluded_cidrs || length(excluded_cidrs) == 0)
        return rule;

    if (rule.type == "logical" && rule.mode == "and" && type(rule.rules) == "array") {
        let cloned = {};
        for (let k, v in rule) {
            if (k == "rules") {
                cloned.rules = [];
                for (let r in v) {
                    if (r && length(keys(r)) > 0)
                        push(cloned.rules, r);
                }
                push(cloned.rules, {
                    invert: true,
                    source_ip_cidr: single_or_array(excluded_cidrs)
                });
            } else {
                cloned[k] = v;
            }
        }
        return cloned;
    }

    let match_part = {};
    for (let k, v in rule) {
        if (!ACTION_KEYS[k] && substr(k, 0, 2) != "__")
            match_part[k] = v;
    }

    if (length(keys(match_part)) == 0) {
        let single_rule = {};
        for (let k, v in rule)
            single_rule[k] = v;
        single_rule.invert = true;
        single_rule.source_ip_cidr = single_or_array(excluded_cidrs);
        return single_rule;
    }

    let logical_rule = {
        type: "logical",
        mode: "and",
        rules: [
            match_part,
            {
                invert: true,
                source_ip_cidr: single_or_array(excluded_cidrs)
            }
        ]
    };
    for (let k, v in rule) {
        if (ACTION_KEYS[k] || substr(k, 0, 2) == "__")
            logical_rule[k] = v;
    }
    return logical_rule;
}

function apply_inverted_subrules(rule, inv_subrules) {
    if (!rule)
        return rule;
    delete rule.__inv_subrules;
    if (!inv_subrules || length(inv_subrules) == 0)
        return rule;

    if (rule.type == "logical" && rule.mode == "and" && type(rule.rules) == "array") {
        let cloned = {};
        for (let k, v in rule) {
            if (k == "rules") {
                cloned.rules = [];
                for (let r in v) {
                    if (r && length(keys(r)) > 0)
                        push(cloned.rules, r);
                }
                for (let sub in inv_subrules)
                    push(cloned.rules, sub);
            } else {
                cloned[k] = v;
            }
        }
        return cloned;
    }

    let match_part = {};
    for (let k, v in rule) {
        if (!ACTION_KEYS[k] && substr(k, 0, 2) != "__")
            match_part[k] = v;
    }

    let rules_list = [];
    if (length(keys(match_part)) > 0)
        push(rules_list, match_part);
    for (let sub in inv_subrules)
        push(rules_list, sub);

    let logical_rule = {
        type: "logical",
        mode: "and",
        rules: rules_list
    };
    for (let k, v in rule) {
        if (ACTION_KEYS[k] || substr(k, 0, 2) == "__")
            logical_rule[k] = v;
    }
    return logical_rule;
}

function push_section_dns_matcher_rule(config, section, rule, excluded_cidrs, domain_rule_set_tags) {
    let action = option(section, "action", "");
    let routed_tag = runtime_constants.tag(section[".name"], "routed-dns-server");
    if ((action == "zapret" || action == "zapret2" || action == "byedpi") &&
        connections.routed_dns_enabled(section) && rule.server == routed_tag &&
        !connections.geoip_country_mode_is_closed(section) &&
        !rule.match_response && (rule.rule_set == null || length(domain_rule_set_tags) > 0)) {
        // Domain-only traffic enters TPROXY through FakeIP. Returning the
        // routed resolver's real address here lets it bypass the DPI output.
        // The route's resolve action still uses this resolver and its detour.
        // Closed GeoIP modes skip that resolve and need real DNS addresses
        // to decide the destination country before choosing an outbound.
        let fakeip_rule = {};
        for (let key, value in rule)
            fakeip_rule[key] = value;
        // In the legacy branch the fallback combines domain and mixed sets.
        // Only domain-only sets may produce FakeIP: an IP-only match loses
        // its real destination and cannot match the subsequent DPI route.
        if (rule.rule_set != null)
            fakeip_rule.rule_set = single_or_array(domain_rule_set_tags);
        fakeip_rule.server = runtime_constants.FAKEIP_DNS_SERVER_TAG;
        add_fakeip_query_type(fakeip_rule, fakeip_rule.server, section_is_ipv4_only_dpi(section));
        push_dns_matcher_rule(config, apply_excluded_source_ips(fakeip_rule, excluded_cidrs));
    }
    // Retain routed DNS for other query types and non-domain rulesets.
    push_dns_matcher_rule(config, apply_excluded_source_ips(rule, excluded_cidrs));
}

function push_section_route_rule(config, rule, target_outbound, excluded_cidrs, geo_tags, country_mode) {
    let inv_subrules = rule ? rule.__inv_subrules : null;
    if (rule)
        delete rule.__inv_subrules;
    let apply_filters = function(r) {
        let filtered = apply_section_geoip_filter(r, geo_tags, country_mode);
        filtered = apply_excluded_source_ips(filtered, excluded_cidrs);
        return apply_inverted_subrules(filtered, inv_subrules);
    };

    if (target_outbound && !outbound_supports_udp(config, target_outbound)) {
        if (rule.network == "tcp") {
            push_route_matcher_rule(config, apply_filters(rule));
            return;
        }
        if (rule.network == "udp") {
            delete rule.outbound;
            rule.action = "reject";
            push_route_matcher_rule(config, apply_filters(rule));
            return;
        }
        let udp_rule = {};
        for (let k, v in rule)
            udp_rule[k] = v;
        delete udp_rule.outbound;
        if (rule.source_ip_cidr && !rule.domain && !rule.ip_cidr && !rule.rule_set) {
            udp_rule.action = "route";
            udp_rule.outbound = runtime_constants.DIRECT_OUTBOUND_TAG;
        } else {
            udp_rule.action = "reject";
        }
        udp_rule.network = "udp";
        push_route_matcher_rule(config, apply_filters(udp_rule));

        rule.network = "tcp";
    }
    push_route_matcher_rule(config, apply_filters(rule));
}

// The closed GeoIP modes do not let the other half of the traffic fall through
// to whatever section comes next. "exclude_direct" pins the selected countries
// to direct, which is what makes a bypass section work whatever its position in
// the order; "include_all" keeps the remainder in the section.
function push_section_geoip_remainder(config, base_rule, target, excluded_cidrs, geo_tags, country_mode) {
    let remainder = {};
    for (let k, v in base_rule)
        remainder[k] = v;

    if (country_mode == "exclude_direct") {
        remainder.rule_set = single_or_array(geo_tags);
        remainder.action = "route";
        remainder.outbound = runtime_constants.DIRECT_OUTBOUND_TAG;
        push_route_matcher_rule(config, apply_excluded_source_ips(remainder, excluded_cidrs));
        return;
    }

    push_section_route_rule(config, remainder, target.outbound, excluded_cidrs, null, country_mode);
}

function add_fully_routed_ips_rule(config, section) {
    let source_ip_cidr = core_ip.normalize_to_cidrs(list_option(section, "fully_routed_ips"));
    if (length(source_ip_cidr) == 0)
        return;

    let target = section_fail_policy_override_target(section) ||
        runtime_route.target(section, group_outbound_tag_for_section(section) || outbound_tag(section[".name"]));
    if (target.unsupported)
        ctx.runtime_generate_unsupported(target.unsupported);

    let route_rule = {
        action: target.action,
        inbound: tproxy_inbound_matcher()
    };
    if (target.outbound)
        route_rule.outbound = target.outbound;
    route_rule.source_ip_cidr = single_or_array(source_ip_cidr);
    push_section_route_rule(config, route_rule, target.outbound);

    let routed_dns = connections.routed_dns_enabled(section);
    if (routed_dns) {
        let server_tag = runtime_constants.tag(section[".name"], "routed-dns-server");
        let rewrite_ttl = int_option(ctx.runtime_settings(), "dns_rewrite_ttl", "60");
        let dns_rule = {
            action: "route",
            server: server_tag,
            rewrite_ttl
        };
        add_source_dns_matchers(dns_rule, source_ip_cidr);
        push_dns_matcher_rule(config, dns_rule);
    }
}

function add_excluded_ips_rule(config, section) {
    let excluded = list_option(section, "excluded_ips");
    if (length(excluded) == 0)
        return;

    let resolved = core_ip.normalize_to_cidrs(excluded);
    if (length(resolved) == 0)
        return;

    let route_rule = {
        action: "route",
        inbound: tproxy_inbound_matcher(),
        outbound: runtime_constants.DIRECT_OUTBOUND_TAG,
        source_ip_cidr: single_or_array(resolved)
    };
    push(config.route.rules, route_rule);
}

function add_excluded_protocol_rule(config, section) {
    let excluded = list_option(section, "excluded_protocol");
    if (length(excluded) == 0)
        return;

    let route_rule = {
        action: "route",
        inbound: tproxy_inbound_matcher(),
        outbound: runtime_constants.DIRECT_OUTBOUND_TAG,
        protocol: single_or_array(excluded)
    };
    push(config.route.rules, route_rule);
}

function add_protocol_matchers(rule, section) {
    let protocols = list_option(section, "protocol");
    if (length(protocols) > 0)
        rule.protocol = single_or_array(protocols);
}


function load_community_subnet_cidrs(community, filter_mode) {
    let service = as_string(community);
    let paths = [
        "/tmp/tachyon-core/rulesets/community-subnets-" + service + ".lst",
        "/etc/tachyon/rulesets/community-subnets-" + service + ".lst",
        (ctx.runtime_ruleset_folder || runtime_ruleset_folder || "/tmp/tachyon-core/rulesets") + "/community-subnets-" + service + ".lst"
    ];
    let cidrs = [];
    for (let path in paths) {
        let content = fs.readfile(path);
        if (content != null && content != "") {
            for (let line in split(as_string(content), "\n")) {
                line = trim(replace(as_string(line), /\r/g, ""));
                if (line != "" && substr(line, 0, 1) != "#" && match(line, /^[0-9a-fA-F:.]+(\/[0-9]+)?$/) && !match(line, /\.$/)) {
                    let is_cf = core_ip.is_cloudflare_shared_cidr(line);
                    if (filter_mode == "only_cloudflare") {
                        if (service == "discord" && is_cf)
                            push(cidrs, line);
                    } else if (filter_mode == "exclude_cloudflare" || filter_mode == null) {
                        if (service == "discord" && is_cf)
                            continue;
                        push(cidrs, line);
                    } else {
                        push(cidrs, line);
                    }
                }
            }
            if (length(cidrs) > 0)
                return cidrs;
        }
    }

    if (service == "discord") {
        if (filter_mode == "only_cloudflare" && length(cidrs) == 0)
            return core_ip.DEFAULT_DISCORD_VOICE_SUBNETS || [ "104.16.0.0/12", "162.158.0.0/15", "172.64.0.0/13", "2606:4700::/32" ];
        if ((filter_mode == "exclude_cloudflare" || filter_mode == null) && length(cidrs) == 0)
            return core_ip.DISCORD_DEDICATED_SUBNETS || [ "162.159.128.0/20" ];
    }

    if (service == "telegram" && length(cidrs) == 0) {
        let res = [];
        for (let c in (core_ip.DEFAULT_TELEGRAM_SUBNETS || [])) push(res, c);
        for (let c in (core_ip.DEFAULT_TELEGRAM_SUBNETS6 || [])) push(res, c);
        return res;
    }

    if (service == "cloudflare" && length(cidrs) == 0)
        return core_ip.CLOUDFLARE_SHARED_CIDRS || [];

    return [];
}

function build_inverted_subrules(config, section_name, inverted_conditions) {
    let subs = [];
    for (let neg in array_or_empty(inverted_conditions)) {
        if (type(neg) != "object")
            continue;
        let sub = { invert: true };
        let ndom = domain_conditions(neg);
        add_domain_array(sub, "domain", ndom.domain);
        add_domain_array(sub, "domain_suffix", ndom.domain_suffix);
        add_domain_array(sub, "domain_keyword", ndom.domain_keyword);
        add_domain_array(sub, "domain_regex", ndom.domain_regex);
        let nip = core_ip.normalize_to_cidrs(legacy_condition_values(neg, "ip_cidr"));
        if (length(nip) > 0)
            sub.ip_cidr = single_or_array(nip);
        let nsrc_raw = [];
        for (let v in legacy_condition_values(neg, "source_ip_cidr")) push(nsrc_raw, v);
        for (let m in list_option(neg, "source_macs")) push(nsrc_raw, m);
        let nsrc = core_ip.normalize_to_cidrs(nsrc_raw);
        if (length(nsrc) > 0)
            sub.source_ip_cidr = single_or_array(nsrc);
        add_port_matchers(sub, neg);
        add_protocol_matchers(sub, neg);
        let nrs = [];
        for (let comm in list_option(neg, "community_lists")) {
            let ens = ensure_community_ruleset(config, section_name, as_string(comm));
            if (ens && ens.tag)
                push(nrs, ens.tag);
        }
        for (let rset in list_option(neg, "rule_set")) {
            let ens = ensure_custom_ruleset(config, as_string(rset));
            if (ens && ens.tag)
                push(nrs, ens.tag);
        }
        for (let rset_sub in list_option(neg, "rule_set_with_subnets")) {
            let ens = ensure_custom_ruleset(config, as_string(rset_sub));
            if (ens && ens.tag)
                push(nrs, ens.tag);
        }
        if (length(nrs) > 0)
            sub.rule_set = single_or_array(nrs);
        if (length(keys(sub)) > 1)
            push(subs, sub);
    }
    return subs;
}

function add_combined_route_for_clause(config, section) {
    let domains = domain_conditions(section);
    let domain = domains.domain;
    let domain_suffix = domains.domain_suffix;
    let domain_keyword = domains.domain_keyword;
    let domain_regex = domains.domain_regex;
    let ip_cidr = core_ip.normalize_to_cidrs(legacy_condition_values(section, "ip_cidr"));
    let source_ip_cidr = core_ip.normalize_to_cidrs(legacy_condition_values(section, "source_ip_cidr"));
    let excluded_cidrs = core_ip.normalize_to_cidrs(list_option(section, "excluded_ips"));
    let rule_set_tags = [];
    let dns_query_rule_set_tags = [];
    let dns_response_rule_set_tags = [];
    // The query-side tags that also match addresses. A set like that may not
    // produce FakeIP: the match would lose the real destination and could not
    // match the DPI rule afterwards.
    let dns_non_domain_query_tags = [];
    let section_name = section[".name"];
    let inv_subrules = build_inverted_subrules(config, section_name, section.__inverted_conditions);


    let include_community_subnets = bool_option(section, "community_subnets", true);
    let discord_cf_subnets = [];
    for (let community in connections.community_lists(section)) {
        let service = as_string(community);
        let ensured = ensure_community_ruleset(config, section_name, service);
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains" || service == "discord") {
            push(dns_query_rule_set_tags, ensured.tag);
            if (ensured.kind != "domains")
                push(dns_non_domain_query_tags, ensured.tag);
        } else if (ensured.kind == "mixed")
            push(dns_response_rule_set_tags, ensured.tag);

        if (include_community_subnets) {
            for (let cidr in load_community_subnet_cidrs(community, "exclude_cloudflare"))
                push(ip_cidr, cidr);
            if (service == "discord") {
                for (let cidr in load_community_subnet_cidrs(community, "only_cloudflare"))
                    push(discord_cf_subnets, cidr);
            }
        }
    }
    for (let reference in connections.rule_sets(section)) {
        let ref_str = as_string(reference);
        let ensured = ensure_custom_ruleset(config, ref_str);
        if (ensured == null)
            continue;
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains" || ref_str == "discord" || ref_str == "community-discord") {
            push(dns_query_rule_set_tags, ensured.tag);
            if (ensured.kind != "domains")
                push(dns_non_domain_query_tags, ensured.tag);
        } else if (ensured.kind == "mixed")
            push(dns_response_rule_set_tags, ensured.tag);
    }
    for (let reference in connections.rule_sets_with_subnets(section)) {
        let ref_str = as_string(reference);
        let ensured = ensure_custom_ruleset(config, ref_str);
        if (ensured == null)
            continue;
        push(rule_set_tags, ensured.tag);
        if (ensured.kind == "domains" || ref_str == "discord" || ref_str == "community-discord") {
            push(dns_query_rule_set_tags, ensured.tag);
            if (ensured.kind != "domains")
                push(dns_non_domain_query_tags, ensured.tag);
        } else if (ensured.kind == "mixed")
            push(dns_response_rule_set_tags, ensured.tag);
    }
    add_domain_ip_list_ruleset(
        config,
        section_name,
        rule_set_tags,
        dns_query_rule_set_tags,
        dns_response_rule_set_tags,
        list_option(section, "domain_ip_lists"),
        false
    );

    let override = section_fail_policy_override_target(section);
    let target = override ||
        runtime_route.target(section, group_outbound_tag_for_section(section) || outbound_tag(section_name));
    if (target.unsupported)
        ctx.runtime_generate_unsupported(target.unsupported);

    let has_domain = length(domain) > 0 || length(domain_suffix) > 0 ||
        length(domain_keyword) > 0 || length(domain_regex) > 0;
    let has_ruleset = length(rule_set_tags) > 0;
    let has_ip_cidr = length(ip_cidr) > 0;

    let country_list = connections.geoip_country_list(section);
    let country_mode = connections.geoip_country_mode(section);
    if (option(section, "action", "") == "bypass" &&
        country_mode == "exclude" &&
        !has_domain && !has_ruleset && !has_ip_cidr &&
        length(discord_cf_subnets) == 0 &&
        length(source_ip_cidr) == 0 &&
        !bool_option(section, "match_all", false)) {
        country_mode = "include";
    }
    let bypass_geo_only = option(section, "action", "") == "bypass" &&
        !has_domain && !has_ruleset && !has_ip_cidr &&
        length(discord_cf_subnets) == 0 &&
        !geoip_mode_inverts(country_mode) &&
        length(country_list) > 0;
    let geo_tags = [];
    if ((target.outbound || target.action) && length(country_list) > 0) {
        for (let cc in country_list) {
            let ip_ruleset = ensure_community_ruleset(config, section_name, "geoip_" + cc);
            if (ip_ruleset && ip_ruleset.tag) {
                push(geo_tags, ip_ruleset.tag);
                if (bypass_geo_only && index(dns_response_rule_set_tags, ip_ruleset.tag) < 0)
                    push(dns_response_rule_set_tags, ip_ruleset.tag);
            }

            if (cc == "ru") {
                let site_ruleset = ensure_community_ruleset(config, section_name, "geosite_ru");
                if (site_ruleset && site_ruleset.tag) {
                    push(geo_tags, site_ruleset.tag);
                    if (bypass_geo_only && index(dns_query_rule_set_tags, site_ruleset.tag) < 0)
                        push(dns_query_rule_set_tags, site_ruleset.tag);
                }
            }
        }
    }

    let create_section_route_rule = function() {
        let r = {
            action: target.action,
            inbound: tproxy_inbound_matcher()
        };
        if (target.outbound)
            r.outbound = target.outbound;
        if (length(source_ip_cidr) > 0)
            r.source_ip_cidr = single_or_array(source_ip_cidr);
        if (length(inv_subrules) > 0)
            r.__inv_subrules = inv_subrules;
        add_port_matchers(r, section);
        add_dscp_matchers(r, section);
        add_protocol_matchers(r, section);
        return r;
    };

    let closed_geo = connections.geoip_country_mode_is_closed(section);
    if (closed_geo && (has_domain || has_ruleset || has_ip_cidr || length(discord_cf_subnets) > 0))
        warn("Section " + section_name + ": GeoIP mode '" + country_mode +
            "' defines the whole section, so the other matchers in it are ignored\n");

    if (has_domain && !closed_geo) {
        let domain_rule = create_section_route_rule();
        add_domain_array(domain_rule, "domain", domain);
        add_domain_array(domain_rule, "domain_suffix", domain_suffix);
        add_domain_array(domain_rule, "domain_keyword", domain_keyword);
        add_domain_array(domain_rule, "domain_regex", domain_regex);

        if (override == null) {
            let resolve = runtime_route.resolve_rule_for_section(section, domain_rule);
            if (type(resolve) == "object" && resolve.warning)
                warn(resolve.warning, "\n");
            else if (type(resolve) == "object" && resolve.rule)
                push_route_matcher_rule(config, apply_excluded_source_ips(resolve.rule, excluded_cidrs));
        }

        push_section_route_rule(config, domain_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);
    }

    if (has_ruleset && !closed_geo) {
        let rs_rule = create_section_route_rule();
        rs_rule.rule_set = single_or_array(rule_set_tags);

        if (override == null) {
            let resolve = runtime_route.resolve_rule_for_section(section, rs_rule);
            if (type(resolve) == "object" && resolve.warning)
                warn(resolve.warning, "\n");
            else if (type(resolve) == "object" && resolve.rule)
                push_route_matcher_rule(config, apply_excluded_source_ips(resolve.rule, excluded_cidrs));
        }

        push_section_route_rule(config, rs_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);
    }

    if (has_ip_cidr && !closed_geo) {
        let ip_rule = create_section_route_rule();
        ip_rule.ip_cidr = ip_cidr;
        push_section_route_rule(config, ip_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);
    }

    if (length(discord_cf_subnets) > 0 && !closed_geo) {
        let voice_rule = create_section_route_rule();
        voice_rule.network = "udp";
        voice_rule.ip_cidr = discord_cf_subnets;
        voice_rule.port_range = core_ip.DISCORD_VOICE_PORT_RANGES || [ "5000:5020", "3478:3478", "19294:19344", "50000:65535" ];
        push_section_route_rule(config, voice_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);

        // Media is TCP and rides the alternate Cloudflare edge ports. Without this
        // the section captured voice but let media past on 443 alone, which is the
        // half of Discord a user notices as "voice works, screen share does not".
        let media_rule = create_section_route_rule();
        media_rule.network = "tcp";
        media_rule.ip_cidr = discord_cf_subnets;
        media_rule.port_range = core_ip.DISCORD_MEDIA_PORT_RANGES || [ "2053:2053", "2083:2083", "2087:2087", "2096:2096", "8443:8443" ];
        push_section_route_rule(config, media_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);
    }

    let section_is_geo_only = !has_domain && !has_ruleset && !has_ip_cidr && length(discord_cf_subnets) == 0;

    if (bool_option(section, "match_all", false) && !closed_geo) {
        let all_rule = create_section_route_rule();
        push_section_route_rule(config, all_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);
    }
    else if (section_is_geo_only || closed_geo) {
        if (length(geo_tags) > 0) {
            let geoip_route_rule = create_section_route_rule();
            push_section_route_rule(config, geoip_route_rule, target.outbound, excluded_cidrs, geo_tags, country_mode);
        }
        else if (!closed_geo) {
            let fallback_rule = create_section_route_rule();
            let has_any_matcher = fallback_rule.source_ip_cidr != null ||
                fallback_rule.port != null || fallback_rule.port_range != null ||
                fallback_rule.protocol != null ||
                (fallback_rule.__inv_subrules != null && length(fallback_rule.__inv_subrules) > 0);
            if (has_any_matcher)
                push_section_route_rule(config, fallback_rule, target.outbound, excluded_cidrs);
        }
    }

    if (closed_geo && length(geo_tags) > 0)
        push_section_geoip_remainder(config, create_section_route_rule(), target, excluded_cidrs, geo_tags, country_mode);

    if (bypass_geo_only) {
        let cctld_map = {
            ru: [ "ru", "su", "xn--p1ai" ],
            ua: [ "ua", "xn--j1amh" ],
            by: [ "by", "xn--90ais" ],
            kz: [ "kz", "xn--80ao21a" ]
        };
        let cctlds = [];
        for (let cc in country_list) {
            cc = lc(trim(as_string(cc)));
            if (match(cc, /^[a-z]{2}$/) == null)
                continue;
            for (let tld in (cctld_map[cc] || [ cc ])) {
                if (index(cctlds, tld) < 0)
                    push(cctlds, tld);
                if (index(domain_suffix, tld) < 0)
                    push(domain_suffix, tld);
            }
        }
        if (length(cctlds) > 0) {
            let cctld_rule = create_section_route_rule();
            add_domain_array(cctld_rule, "domain_suffix", cctlds);
            push_section_route_rule(config, cctld_rule, target.outbound, excluded_cidrs, null, country_mode);
        }
    }

    let rewrite_ttl = int_option(ctx.runtime_settings(), "dns_rewrite_ttl", "60");
    let dns_server_tag = section_dns_server(section);
    let ipv4_only_dpi = section_is_ipv4_only_dpi(section) &&
        dns_server_tag == runtime_constants.FAKEIP_DNS_SERVER_TAG;
    if (length(domain) > 0 || length(domain_suffix) > 0 || length(domain_keyword) > 0 || length(domain_regex) > 0) {
        let domain_matchers = [
            [ "domain", domain ],
            [ "domain_suffix", domain_suffix ],
            [ "domain_keyword", domain_keyword ],
            [ "domain_regex", domain_regex ]
        ];
        for (let dm in domain_matchers) {
            let key = dm[0];
            let values = dm[1];
            if (length(values) == 0)
                continue;
            let dns_rule = {
                action: "route",
                server: dns_server_tag,
                rewrite_ttl
            };
            add_fakeip_query_type(dns_rule, dns_server_tag, ipv4_only_dpi);
            add_domain_array(dns_rule, key, values);
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_section_dns_matcher_rule(config, section, dns_rule, excluded_cidrs);
            if (ipv4_only_dpi) {
                let aaaa_rule = {
                    action: "route",
                    server: runtime_constants.DNS_SERVER_TAG,
                    rewrite_ttl,
                    query_type: [ "AAAA" ]
                };
                add_domain_array(aaaa_rule, key, values);
                add_source_dns_matchers(aaaa_rule, source_ip_cidr);
                push_dns_matcher_rule(config, apply_excluded_source_ips(aaaa_rule, excluded_cidrs));
            }
        }
    }
    // The tags that match domains only. A set that also matches addresses may
    // not produce FakeIP: the match would lose the real destination and could
    // not match the DPI rule afterwards.
    let domain_only_dns_tags = [];
    for (let tag in dns_query_rule_set_tags)
        if (index(dns_non_domain_query_tags, tag) < 0)
            push(domain_only_dns_tags, tag);
    let is_1_14 = ctx.is_sb_1_14_plus && ctx.is_sb_1_14_plus();
    if (is_1_14) {
        if (length(dns_query_rule_set_tags) > 0) {
            let dns_rule = {
                action: "route",
                server: dns_server_tag,
                rewrite_ttl,
                rule_set: single_or_array(dns_query_rule_set_tags)
            };
            add_fakeip_query_type(dns_rule, dns_server_tag, ipv4_only_dpi);
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_section_dns_matcher_rule(config, section, dns_rule, excluded_cidrs, domain_only_dns_tags);
            if (ipv4_only_dpi) {
                let aaaa_rule = {
                    action: "route",
                    server: runtime_constants.DNS_SERVER_TAG,
                    rewrite_ttl,
                    query_type: [ "AAAA" ],
                    rule_set: single_or_array(dns_query_rule_set_tags)
                };
                add_source_dns_matchers(aaaa_rule, source_ip_cidr);
                push_dns_matcher_rule(config, apply_excluded_source_ips(aaaa_rule, excluded_cidrs));
            }
        }
        if (length(dns_response_rule_set_tags) > 0) {
            let eval_rule = {
                action: "evaluate",
                server: runtime_constants.DNS_SERVER_TAG
            };
            add_source_dns_matchers(eval_rule, source_ip_cidr);
            push_dns_matcher_rule(config, apply_excluded_source_ips(eval_rule, excluded_cidrs));

            let dns_rule = {
                action: "route",
                server: dns_server_tag,
                rewrite_ttl,
                rule_set: single_or_array(dns_response_rule_set_tags),
                match_response: true
            };
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_section_dns_matcher_rule(config, section, dns_rule, excluded_cidrs);
        }
    }
    else {
        let all_dns_tags = [];
        for (let tag in dns_query_rule_set_tags)
            push(all_dns_tags, tag);
        for (let tag in dns_response_rule_set_tags)
            push(all_dns_tags, tag);

        if (length(all_dns_tags) > 0) {
            let dns_rule = {
                action: "route",
                server: dns_server_tag,
                rewrite_ttl,
                rule_set: single_or_array(all_dns_tags)
            };
            add_fakeip_query_type(dns_rule, dns_server_tag, ipv4_only_dpi);
            add_source_dns_matchers(dns_rule, source_ip_cidr);
            push_section_dns_matcher_rule(config, section, dns_rule, excluded_cidrs, domain_only_dns_tags);
            if (ipv4_only_dpi) {
                let aaaa_rule = {
                    action: "route",
                    server: runtime_constants.DNS_SERVER_TAG,
                    rewrite_ttl,
                    query_type: [ "AAAA" ],
                    rule_set: single_or_array(all_dns_tags)
                };
                add_source_dns_matchers(aaaa_rule, source_ip_cidr);
                push_dns_matcher_rule(config, apply_excluded_source_ips(aaaa_rule, excluded_cidrs));
            }
        }
    }
}

function add_combined_route_for_section(config, section) {
    add_excluded_protocol_rule(config, section);
    add_fully_routed_ips_rule(config, section);
    for (let clause in connections.section_effective_clauses(section))
        add_combined_route_for_clause(config, clause);
}

function unsupported_matcher_key(section) {
    let unsupported_options = [
        "subnet", "subnet_text",
        "local_domain_lists", "local_subnet_lists",
        "remote_domain_lists", "remote_subnet_lists"
    ];
    for (let key in unsupported_options) {
        if (length(list_option(section, key)) > 0 || option(section, key, "") != "")
            return key;
    }
    return "";
}

function add_outbound_for_section(config, section, taken, sections) {
    let section_name = section[".name"];
    if (ctx.deferred_sections && ctx.deferred_sections[section_name])
        return;
    let action = option(section, "action", "");
    if (!valid_section_name(section_name))
        ctx.runtime_generate_unsupported("section name is not safe for sing-box config generation");
    let unsupported_matcher = unsupported_matcher_key(section);
    if (unsupported_matcher != "")
        ctx.runtime_generate_unsupported("section has unsupported matcher " + unsupported_matcher);

    if (connections.is_connections_action(action))
        ctx.outbounds.add_connections_outbound(config, section, taken);
    else if (action == "awg")
        ctx.outbounds.add_awg_endpoint(config, section);
    else if (action == "warp")
        ctx.outbounds.add_warp_endpoint(config, section);
    else if (action == "anytls")
        ctx.outbounds.add_anytls_outbound(config, section);
    else if (action == "snell")
        ctx.outbounds.add_snell_outbound(config, section);
    else if (action == "mieru")
        ctx.outbounds.add_mieru_outbound(config, section);
    else if (action == "naive")
        ctx.outbounds.add_naive_outbound(config, section);
    else if (action == "sudoku")
        ctx.outbounds.add_sudoku_outbound(config, section);
    else if (action == "masque")
        ctx.outbounds.add_masque_outbound(config, section);
    else if (action == "openvpn")
        ctx.outbounds.add_openvpn_endpoint(config, section);
    else if (action == "openconnect")
        ctx.outbounds.add_openconnect_outbound(config, section);
    else if (action == "tewfai")
        ctx.outbounds.add_tewfai_outbound(config, section);
    else if (action == "trusttunnel")
        ctx.outbounds.add_trusttunnel_outbound(config, section);
    else if (action == "mtproto")
        ctx.outbounds.add_mtproto_outbound(config, section);
    else if (action == "shadowtls")
        ctx.outbounds.add_shadowtls_outbound(config, section);
    else if (action == "desync")
        ctx.outbounds.add_desync_outbound(config, section);
    else if (action == "chain")
        ctx.outbounds.add_chain_outbound(config, section);
    else if (action == "tailscale")
        ctx.outbounds.add_tailscale_client_endpoint(config, section);
    else if (action == "zapret")
        ctx.outbounds.add_zapret_outbound(config, section, sections);
    else if (action == "zapret2")
        ctx.outbounds.add_zapret2_outbound(config, section, sections);
    else if (action == "byedpi")
        ctx.outbounds.add_byedpi_outbound(config, section, sections);
    else if (action == "wdtt")
        ctx.outbounds.add_wdtt_outbound(config, section, sections);
    else if (action == "olcrtc")
        ctx.outbounds.add_olcrtc_outbound(config, section, sections);
    else if (action == "fptn")
        ctx.outbounds.add_fptn_outbound(config, section, sections);
    else if (action == "group") {
        /* container — the flat urltest is built by add_group_urltest_outbounds
           after every member section has generated its outbounds */
    }
    else if (action == "bypass") {
        /* route-only action */
    }
    else if (action == "block") {
        /* route-only action */
    }
    else if (action == "dns") {
        add_dns_server_for_section(config, section);
    }
    else if (action == "hosts") {
        /* hosts-only action — no outbound or route needed */
    }
    else {
        ctx.runtime_generate_unsupported("unsupported action " + action);
    }

    if (action != "dns" && action != "hosts" && action != "block" && action != "group")
        add_routed_dns_server_for_section(config, section);
}

function reserve_section_outbound_tags(sections, taken) {
    for (let section in sections) {
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "awg" || action == "warp" || action == "byedpi" || action == "zapret" || action == "zapret2" ||
            action == "wdtt" || action == "olcrtc" || action == "fptn" ||
            action == "anytls" || action == "snell" || action == "mieru" || action == "naive" || action == "sudoku" ||
            action == "masque" || action == "openvpn" || action == "openconnect" ||
            action == "tewfai" || action == "trusttunnel" || action == "mtproto" || action == "shadowtls" ||
            action == "desync" || action == "chain" || action == "tailscale")
            taken[outbound_tag(section[".name"])] = true;

        if (action == "group") {
            taken[urltest_outbound_tag(section[".name"], "urltest")] = true;
            for (let urltest_id in connections.urltests(section))
                taken[urltest_outbound_tag(section[".name"], urltest_id)] = true;
            for (let group_id in connections.priority_groups(section))
                taken[priority_outbound_tag(section[".name"], group_id)] = true;
            continue;
        }

        if (!connections.is_connections_action(action))
            continue;

        for (let urltest_id in connections.urltests(section))
            taken[urltest_outbound_tag(section[".name"], urltest_id)] = true;
        for (let group_id in connections.priority_groups(section))
            taken[priority_outbound_tag(section[".name"], group_id)] = true;
    }
}

function add_route_for_section(config, section) {
    if (ctx.quarantined_sections && ctx.quarantined_sections[section[".name"]])
        return;
    let override = section_fail_policy_override_target(section);
    if (ctx.deferred_sections && ctx.deferred_sections[section[".name"]] && override == null)
        return;
    let action = option(section, "action", "");
    if (action == "dns")
        add_dns_action_rules_for_section(config, section);
    else if (action == "hosts") {
        /* hosts-only action — entries are consumed globally via combined cache */
    }
    else if (action == "group") {
        // Members keep their own rules repointed at the group urltest; if the
        // group section itself also has matchers configured, route them through
        // the group urltest too.
        if (group_outbound_tag_for_section(section) != "" || override != null)
            add_combined_route_for_section(config, section);
    }
    else
        add_combined_route_for_section(config, section);
}

function failover_candidate(sections) {
    let result = [];
    for (let section in sections) {
        if (ctx.deferred_sections && ctx.deferred_sections[section[".name"]])
            continue;
        let action = option(section, "action", "");
        if (connections.is_connections_action(action) ||
            action == "awg" || action == "warp" || action == "byedpi" || action == "zapret" || action == "zapret2" ||
            action == "wdtt" || action == "olcrtc" ||
            action == "anytls" || action == "snell" || action == "mieru" || action == "naive" || action == "sudoku" ||
            action == "masque" || action == "openvpn" || action == "openconnect" ||
            action == "tewfai" || action == "trusttunnel" || action == "mtproto" || action == "shadowtls" ||
            action == "desync" || action == "chain" || action == "tailscale") {
            push(result, section);
        }
    }
    return result;
}

function failover_state_file() {
    return getenv("TACHYON_FAILOVER_STATE_FILE") || "/etc/tachyon/failover_section";
}

// Persisted user/agent choice survives restarts; ignored when the section
// disappeared from the candidate list.
function failover_default_name(candidates) {
    let raw = "";
    try {
        raw = trim(as_string(fs.readfile(failover_state_file())) || "");
    } catch (e) {
        raw = "";
    }
    if (raw != "") {
        for (let section in candidates)
            if (as_string(section[".name"]) == raw)
                return raw;
    }
    return as_string(candidates[0][".name"]);
}

const FAILOVER_GROUP_TAG = "tachyon-failover";

function section_by_name(sections, name) {
    name = as_string(name);
    for (let section in sections)
        if (as_string(section[".name"]) == name)
            return section;
    return null;
}

function add_service_route_rules(config, sections) {
    let settings = object_or_empty(ctx.uci_cursor().get_all(CONFIG_NAME, "settings"));
    if (bool_option(settings, "dns_detour_enabled", false)) {
        let detour_section = option(settings, "dns_detour_section", "");
        if (detour_section != "" && !(ctx.deferred_sections && ctx.deferred_sections[detour_section])) {
            let detour_sec_obj = section_by_name(sections, detour_section);
            let detour_target = (detour_sec_obj && group_outbound_tag_for_section(detour_sec_obj)) || outbound_tag(detour_section);
            let dns_servers = list_option(settings, "dns_server");
            if (length(dns_servers) == 0) {
                let single_dns = option(settings, "dns_server", "");
                if (single_dns != "")
                    dns_servers = [single_dns];
            }
            let fallback_servers = list_option(settings, "dns_fallback_server");
            if (length(fallback_servers) == 0) {
                let single_fb = option(settings, "dns_fallback_server", "");
                if (single_fb != "")
                    fallback_servers = [single_fb];
            }
            let all_dns = [];
            for (let s in dns_servers)
                push(all_dns, s);
            for (let s in fallback_servers)
                push(all_dns, s);

            let detour_ips = [];
            let detour_domains = [];
            for (let s in all_dns) {
                s = trim(as_string(s));
                if (s == "")
                    continue;
                s = split(s, "#")[0];
                let host = core_url.host(s);
                if (host == "")
                    host = s;
                host = split(host, "/")[0];
                if (core_ip.valid_ipv4(host) || core_ip.valid_ipv6(host))
                    push(detour_ips, host);
                else if (host != "")
                    push(detour_domains, host);
            }
            if (length(detour_ips) > 0) {
                push_section_route_rule(config, {
                    action: "route",
                    inbound: tproxy_inbound_matcher(),
                    outbound: detour_target,
                    ip_cidr: single_or_array(detour_ips)
                }, detour_target);
            }
            if (length(detour_domains) > 0) {
                push_section_route_rule(config, {
                    action: "route",
                    inbound: tproxy_inbound_matcher(),
                    outbound: detour_target,
                    domain: single_or_array(detour_domains)
                }, detour_target);
            }
        }
    }

    let candidates = failover_candidate(sections);
    let proxy_candidates = [];
    for (let section in candidates) {
        if (connections.is_remote_proxy_section ? connections.is_remote_proxy_section(section) : connections.is_remote_proxy_action(option(section, "action", "")))
            push(proxy_candidates, section);
    }
    let target_candidates = length(proxy_candidates) > 0 ? proxy_candidates : candidates;
    let first = length(target_candidates) > 0 ? target_candidates[0] : null;
    let failover_active = bool_option(settings, "section_failover_enabled", false) &&
        length(target_candidates) > 1;
    if (first != null) {
        push(config.route.rules, {
            action: "resolve",
            inbound: tproxy_inbound_matcher(),
            server: runtime_constants.DNS_SERVER_TAG,
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        });
        let catchall_target = outbound_tag(first[".name"]);
        if (failover_active) {
            let member_tags = [];
            for (let section in target_candidates)
                push(member_tags, outbound_tag(section[".name"]));
            let def_name = failover_default_name(target_candidates);
            push(config.outbounds, {
                type: "selector",
                tag: FAILOVER_GROUP_TAG,
                outbounds: member_tags,
                default: outbound_tag(def_name),
                interrupt_exist_connections: true
            });
            catchall_target = FAILOVER_GROUP_TAG;
        }
        push_section_route_rule(config, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: catchall_target,
            domain: runtime_constants.CHECK_PROXY_IP_DOMAIN
        }, catchall_target);
    }

    push(config.route.rules, {
        action: "route-options",
        domain: runtime_constants.FAKEIP_TEST_DOMAIN,
        override_port: 8443
    });
}

function add_full_tunnel_route_rule(config, sections) {
    let settings = object_or_empty(ctx.uci_cursor().get_all(CONFIG_NAME, "settings"));
    let is_full_tunnel = option(settings, "routing_strategy", option(settings, "global_routing_mode", "split")) == "full_tunnel";
    if (!is_full_tunnel)
        return;

    let def_tunnel_name = trim(option(settings, "default_tunnel_section", ""));
    let full_tunnel_target = "";
    if (def_tunnel_name != "" && !(ctx.deferred_sections && ctx.deferred_sections[def_tunnel_name])) {
        let def_sec = section_by_name(sections, def_tunnel_name);
        if (def_sec != null && section_enabled(def_sec))
            full_tunnel_target = group_outbound_tag_for_section(def_sec) || outbound_tag(def_tunnel_name);
    }
    if (full_tunnel_target == "" || !is_valid_detour(config, full_tunnel_target)) {
        full_tunnel_target = "";
        let fallback_dpi_target = "";
        for (let section in sections) {
            if (!section_enabled(section))
                continue;
            if (ctx.deferred_sections && ctx.deferred_sections[section[".name"]])
                continue;
            let action = option(section, "action", "");
            if (connections.is_connections_action(action) || action == "awg" || action == "fptn" || action == "group") {
                let cand_tag = group_outbound_tag_for_section(section) || outbound_tag(section[".name"]);
                if (is_valid_detour(config, cand_tag)) {
                    if (connections.is_dpi_or_desync_only_section && connections.is_dpi_or_desync_only_section(section)) {
                        if (fallback_dpi_target == "")
                            fallback_dpi_target = cand_tag;
                    } else {
                        full_tunnel_target = cand_tag;
                        break;
                    }
                }
            }
        }
        if (full_tunnel_target == "" && fallback_dpi_target != "")
            full_tunnel_target = fallback_dpi_target;
    }
    if (full_tunnel_target != "" && is_valid_detour(config, full_tunnel_target)) {
        push_section_route_rule(config, {
            action: "route",
            inbound: tproxy_inbound_matcher(),
            outbound: full_tunnel_target
        }, full_tunnel_target);
    }
}

function enabled_sections() {
    let result = [];
    ctx.uci_cursor().foreach(CONFIG_NAME, "section", function(section) {
        if (section_enabled(section))
            push(result, section);
    });
    return result;
}

function enabled_servers() {
    let result = [];
    ctx.uci_cursor().foreach(CONFIG_NAME, "server", function(section) {
        if (section_enabled(section) && !(ctx.deferred_sections && ctx.deferred_sections[section[".name"]]))
            push(result, section);
    });
    return result;
}

function has_outbound_tag(config, tag_name) {
    if (type(config) != "object" || type(config.outbounds) != "array")
        return false;
    for (let item in config.outbounds) {
        if (type(item) == "object" && as_string(item.tag) == as_string(tag_name))
            return true;
    }
    return false;
}

function ensure_dnsmasq_dns_server(config) {
    if (type(config) != "object" || type(config.dns) != "object")
        return;
    if (type(config.dns.servers) != "array")
        config.dns.servers = [];
    for (let s in config.dns.servers) {
        if (type(s) == "object" && as_string(s.tag) == runtime_constants.DNSMASQ_DNS_SERVER_TAG)
            return;
    }
    push(config.dns.servers, {
        type: "udp",
        tag: runtime_constants.DNSMASQ_DNS_SERVER_TAG,
        server: "127.0.0.1",
        server_port: 53
    });
}

function add_server_routes(config, servers, sections) {
    let has_lo_direct = has_outbound_tag(config, runtime_constants.LO_DIRECT_OUTBOUND_TAG);
    let has_lan_direct = has_outbound_tag(config, runtime_constants.LAN_DIRECT_OUTBOUND_TAG);
    let lan_cidrs = type(config.__lan_interface_cidrs) == "array" ? config.__lan_interface_cidrs : [];
    for (let server in servers) {
        ctx.current_section = server[".name"];
        // Native-mode Tailscale runs outside sing-box: no inbound, no rules.
        if (runtime_servers.is_native_tailscale(server))
            continue;
        runtime_servers.add_sniff_rule(config, server);

        let base_inbound = runtime_constants.server_inbound_tag(server[".name"]);
        let inbound = base_inbound;
        if (option(server, "protocol", "vless") == "shadowtls" &&
            variant_state.is_tachyon_core() &&
            trim(as_string(option(server, "shadowtls_detour", ""))) == "") {
            push(config.route.rules, {
                action: "route",
                inbound: base_inbound,
                outbound: has_lo_direct ? runtime_constants.LO_DIRECT_OUTBOUND_TAG : runtime_constants.DIRECT_OUTBOUND_TAG,
                override_address: "127.0.0.1",
                override_port: runtime_servers.shadowtls_inner_port(server)
            });
            inbound = base_inbound + "-inner";
        }

        let isolate_lan = bool_option(server, "isolate_lan_for_users", false) || bool_option(server, "block_private_for_users", false);
        let isolated_users = list_option(server, "isolated_users");
        if (length(isolated_users) == 0)
            isolated_users = list_option(server, "blocked_users");

        if (isolate_lan) {
            let isolate_rule = {
                action: "reject",
                inbound: inbound,
                ip_is_private: true
            };
            if (length(isolated_users) > 0)
                isolate_rule.auth_user = isolated_users;
            let isolated_subnets = list_option(server, "isolated_subnets");
            if (length(isolated_subnets) > 0)
                isolate_rule.ip_cidr = isolated_subnets;
            push(config.route.rules, isolate_rule);
        }

        push(config.route.rules, {
            action: "hijack-dns",
            inbound: inbound,
            port: 53
        });
        push(config.route.rules, {
            action: "hijack-dns",
            inbound: inbound,
            protocol: "dns"
        });

        if (!isolate_lan) {
            ensure_dnsmasq_dns_server(config);
            if (type(config.dns) == "object" && type(config.dns.rules) == "array") {
                unshift(config.dns.rules, {
                    action: "route",
                    inbound: inbound,
                    domain_suffix: [ "lan", "local", "internal", "home.arpa", "localdomain" ],
                    server: runtime_constants.DNSMASQ_DNS_SERVER_TAG
                });
            }
            if (has_lo_direct) {
                push(config.route.rules, {
                    action: "route",
                    inbound: inbound,
                    ip_cidr: core_ip.ipv6_supported() ? [ "127.0.0.0/8", "::1/128" ] : [ "127.0.0.0/8" ],
                    outbound: runtime_constants.LO_DIRECT_OUTBOUND_TAG
                });
            }
            if (has_lan_direct && length(lan_cidrs) > 0) {
                push(config.route.rules, {
                    action: "route",
                    inbound: inbound,
                    ip_cidr: lan_cidrs,
                    outbound: runtime_constants.LAN_DIRECT_OUTBOUND_TAG
                });
            }
            push(config.route.rules, {
                action: "route",
                inbound: inbound,
                ip_is_private: true,
                outbound: runtime_constants.DIRECT_OUTBOUND_TAG
            });
        }

        let custom_rules = list_option(server, "custom_route_rules");
        if (length(custom_rules) == 0)
            custom_rules = list_option(server, "custom_rules_json");
        for (let rule_str in custom_rules) {
            try {
                let r = json(rule_str);
                if (type(r) == "object") {
                    if (!r.inbound)
                        r.inbound = inbound;
                    push(config.route.rules, r);
                }
            } catch(e) {}
        }

        let routing_mode = option(server, "routing_mode", "rules");
        if (routing_mode == "rules") {
            runtime_servers.clone_rules_for_inbound(
                config,
                runtime_constants.TPROXY_INBOUND_TAG,
                inbound,
                runtime_constants.CHECK_PROXY_IP_DOMAIN
            );
        }
        else if (routing_mode == "direct") {
            push(config.route.rules, {
                action: "route",
                inbound,
                outbound: runtime_constants.DIRECT_OUTBOUND_TAG
            });
        }
        else if (routing_mode == "section") {
            let routing_section_name = option(server, "routing_section", "");
            let routing_section = section_by_name(sections, routing_section_name);
            if (routing_section == null || (ctx.deferred_sections && ctx.deferred_sections[routing_section_name]))
                ctx.runtime_generate_unsupported("server references missing or quarantined routing section " + routing_section_name);
            let action = option(routing_section, "action", "");
            if (action == "bypass" || action == "block")
                ctx.runtime_generate_unsupported("server routing section " + routing_section_name + " cannot use action " + action);
            let target = runtime_route.target(routing_section, group_outbound_tag_for_section(routing_section) || outbound_tag(routing_section[".name"]));
            if (target.unsupported)
                ctx.runtime_generate_unsupported(target.unsupported);
            let rule = {
                action: target.action,
                inbound
            };
            if (target.outbound)
                rule.outbound = target.outbound;
            push_section_route_rule(config, rule, target.outbound);
        }
        else {
            ctx.runtime_generate_unsupported("unsupported server routing_mode " + routing_mode);
        }

        if (option(server, "protocol", "vless") == "tailscale") {
            push(config.route.rules, {
                action: "route",
                ip_cidr: [ "100.64.0.0/10", "fd7a:115c:a1e0::/48" ],
                outbound: inbound
            });
        }
    }
    ctx.current_section = null;
}

return {
    init,
    ensure_custom_ruleset,
    ruleset_registered,
    section_needs_country_is,
    section_has_direct_priority_level,
    urltest_outbound_tag,
    priority_outbound_tag,
    add_urltest_outbound,
    add_group_urltest_outbounds,
    group_outbound_tag_for_section,
    add_priority_group_outbound,
    add_proxy_selector,
    dashboard_filtered_outbounds,
    ensure_community_ruleset,
    domain_ip_list_ruleset_tag,
    domain_ip_list_ruleset_path,
    add_domain_ip_list_ruleset,
    legacy_condition_values,
    domain_conditions,
    add_domain_array,
    push_dns_matcher_rule,
    section_dns_server,
    add_dns_server_for_section,
    add_dns_action_rules_for_section,
    add_port_matchers,
    add_fully_routed_ips_rule,
    add_excluded_ips_rule,
    add_combined_route_for_section,
    unsupported_matcher_key,
    add_outbound_for_section,
    reserve_section_outbound_tags,
    add_route_for_section,
    add_service_route_rules,
    add_full_tunnel_route_rule,
    enabled_sections,
    enabled_servers,
    section_by_name,
    add_server_routes,
    outbound_supports_udp,
    push_section_route_rule,
    apply_section_geoip_filter,
    apply_excluded_source_ips,
    is_valid_detour,
    load_community_subnet_cidrs,
    section_excluded_candidate_tags,
    urltest_exclude_outbounds,
    urltest_filtered_outbounds,
    urltest_idle_timeout
};
