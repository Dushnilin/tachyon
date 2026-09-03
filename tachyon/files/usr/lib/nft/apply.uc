#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let helpers = require("core.helpers");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let rule_config = require("config.rule");
let domain_config = require("config.domain");
let connections = require("config.connections");
let routing_rulesets = require("routing.rulesets");
const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const DNS_BLOCK_TARGET = getenv("SB_DNS_BLOCK_INBOUND_ADDRESS") || "127.0.0.43:1053";

let common_read_json_file = common.read_json_file;
let list_option = common.list_option;
let bool_option = common.bool_option;
let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let option = common.option;
let write_compact_string_array = common.write_compact_string_array;
let unlink_file = common.unlink_file;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output_from_args = common.command_output_from_args;

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes";
}

function uci_section(section_name) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name));
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_settings() {
    return uci_section("settings");
}

// True when at least one enabled server section runs Tailscale in native
// (tailscaled) mode; those need tailnet bypass rules in the mangle chain.
function native_tailscale_enabled() {
    for (let section in uci_sections("server")) {
        if (as_string(section["enabled"]) == "0" || as_string(section["enabled"]) == "false")
            continue;
        if (as_string(section["protocol"] || "") != "tailscale")
            continue;
        if (as_string(section["tailscale_mode"] || "singbox") == "native")
            return true;
    }
    return false;
}

function section_by_name(sections, section_name) {
    section_name = as_string(section_name);
    for (let section in sections)
        if (as_string(section[".name"]) == section_name)
            return section;
    return null;
}

function write_text_file(path, text) {
    let result = fs.writefile(path, as_string(text));
    if (result == null)
        return false;
    if (type(result) == "boolean" && !result)
        return false;
    return true;
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function run_args(args) {
    return system(command_from_args(args)) == 0;
}

function run_args_quiet(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_quiet_from_args(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function log_to_kmsg(message, level) {
    if (getenv("LOGGER_LOG") != null)
        return false;

    let priority = 6;
    let lvl = as_string(level || "info");
    if (lvl == "warn") priority = 4;
    else if (lvl == "fatal") priority = 3;
    else if (lvl == "debug") priority = 7;

    let kmsg = fs.open("/dev/kmsg", "w");
    if (kmsg) {
        kmsg.write(sprintf("<%d>tachyon: [%s] %s\n", priority, lvl, as_string(message)));
        kmsg.close();
        return true;
    }
    return false;
}

function log_debug(message) {
    if (!log_to_kmsg(message, "debug"))
        run_args([ "logger", "-t", "tachyon", "[debug] " + as_string(message) ]);
}

function log_warn(message) {
    if (!log_to_kmsg(message, "warn"))
        run_args([ "logger", "-t", "tachyon", "[warn] " + as_string(message) ]);
}

function log_fatal(message) {
    if (!log_to_kmsg(message, "fatal"))
        run_args([ "logger", "-t", "tachyon", "[fatal] " + as_string(message) ]);
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function print_csv(values) {
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(as_string(values[i]));
    }
    if (length(values) > 0)
        print("\n");
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

function text_list_to_csv(value, separator_mode) {
    print_csv(text_list_values(value, separator_mode));
}

function csv_to_json_array(value) {
    value = as_string(value);
    if (value == "") {
        print("[]\n");
        return;
    }

    write_compact_string_array(split(value, ","));
}

function csv_list_contains(value, needle) {
    needle = as_string(needle);
    if (needle == "")
        return false;

    for (let item in split(as_string(value), ",")) {
        if (item == needle)
            return true;
    }

    return false;
}

function cache_key_is_safe(value) {
    value = as_string(value);
    return value != "" && match(value, /^[A-Za-z0-9_]+$/) != null;
}

function cache_path(enabled, cache_dir, namespace, section, key, kind) {
    if (as_string(enabled) != "1")
        exit(1);

    cache_dir = as_string(cache_dir);
    if (cache_dir == "")
        exit(1);

    if (!cache_key_is_safe(namespace) || !cache_key_is_safe(section) ||
        !cache_key_is_safe(key) || !cache_key_is_safe(kind))
        exit(1);

    print(cache_dir, "/", namespace, "_", section, "_", key, "_", kind, "\n");
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, false, false);
}

function valid_ipv4_cidr(value) {
    return core_ip.valid_ipv4_cidr(value, false);
}

function nft_ip_or_cidr(value) {
    return core_ip.nft_ip_or_cidr(value);
}

function domain_subnet_line_values(data) {
    let result = [];

    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(strip_list_comment(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function normalize_domain_subnet_value(value, kind) {
    kind = as_string(kind);
    if (kind == "domains")
        return domain_config.suffix_to_ascii(value);
    if (kind == "subnets")
        return core_ip.valid_ip_or_cidr(value) ? value : null;

    exit(1);
}

function filter_domain_subnet_values(values, kind) {
    let result = [];
    kind = as_string(kind);

    if (kind != "domains" && kind != "subnets")
        exit(1);

    for (let value in values) {
        let normalized = normalize_domain_subnet_value(value, kind);
        if (normalized != null)
            push(result, normalized);
    }

    return result;
}

function combined_domain_text_csv(value, requested_kind) {
    let result = rule_config.combined_domain_text_csv_value(value, requested_kind);
    if (result != "")
        print(result, "\n");
}

function combined_domain_csv(value, requested_kind) {
    let result = rule_config.combined_domain_csv_value(value, requested_kind);
    if (result != "")
        print(result, "\n");
}

function list_value_csv(value) {
    value = as_string(value);
    if (value != "")
        print(replace(value, / /g, ","), "\n");
}

function legacy_condition_csv_value(kind, text_mode, conditions_text_mode, text_value, list_value) {
    return rule_config.legacy_condition_csv_value(kind, text_mode, conditions_text_mode, text_value, list_value);
}

function rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value) {
    return rule_config.rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value);
}

function rule_condition_csv(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value) {
    let value = rule_condition_csv_value(key, kind, text_mode, conditions_text_mode, text_value, list_value, combined_text_value, combined_list_value);

    if (value != "")
        print(value, "\n");
}

function legacy_condition_csv(kind, text_mode, conditions_text_mode, text_value, list_value) {
    let value = legacy_condition_csv_value(kind, text_mode, conditions_text_mode, text_value, list_value);
    if (value != "")
        print(value, "\n");
}

function domain_subnet_text_csv(value, kind) {
    print_csv(filter_domain_subnet_values(text_list_values(value, "comma-space"), kind));
}

function domain_subnet_file_csv(path, kind) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    print_csv(filter_domain_subnet_values(domain_subnet_line_values(data), kind));
}

function split_domain_subnet_file(path, domains_path, subnets_path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let domains = [];
    let subnets = [];

    for (let value in domain_subnet_line_values(data)) {
        let domain = normalize_domain_subnet_value(value, "domains");
        if (domain != null)
            push(domains, domain);
        else if (core_ip.valid_ip_or_cidr(value))
            push(subnets, value);
    }

    if (!write_text_file(domains_path, length(domains) > 0 ? join("\n", domains) + "\n" : ""))
        exit(1);
    if (!write_text_file(subnets_path, length(subnets) > 0 ? join("\n", subnets) + "\n" : ""))
        exit(1);
}

function normalize_port_number_value(value) {
    return rule_config.normalize_port_number_value(value);
}

function normalize_port_condition_value(value) {
    return rule_config.normalize_port_condition_value(value);
}

function normalize_port_condition_for_nft(value) {
    let normalized = normalize_port_condition_value(value);
    if (normalized == null)
        exit(1);
    print(normalized, "\n");
}

function normalize_port_range_value(value) {
    return rule_config.normalize_port_range_value(value);
}

function rule_ports_csv_value(list_values, text_value) {
    return rule_config.rule_ports_csv_value(list_values, text_value);
}

function rule_ports_csv(list_values, text_value) {
    let value = rule_ports_csv_value(list_values, text_value);
    if (value != "")
        print(value, "\n");
}

function rule_port_values(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") >= 0)
            continue;

        let port = normalize_port_number_value(item);
        if (port != null)
            push(result, port);
    }

    return result;
}

function rule_port_ranges(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        if (index(item, "-") < 0)
            continue;

        let range = normalize_port_range_value(item);
        if (range != null)
            push(result, range);
    }

    return result;
}

function csv_to_lines_file(csv, path) {
    if (!fs.writefile(path, replace(as_string(csv) + "\n", /,/g, "\n")))
        exit(1);
}

function nft_create_table(name) {
    return run_args([ "nft", "add", "table", "inet", name ]);
}

function nft_create_set(table, name, definition) {
    return run_args([ "nft", "add", "set", "inet", table, name, definition ]);
}

function nft_create_ipv4_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr; flags interval; auto-merge; }");
}

function nft_create_ipv6_set(table, name) {
    return nft_create_set(table, name, "{ type ipv6_addr; flags interval; auto-merge; }");
}

function nft_create_inet_service_set(table, name) {
    return nft_create_set(table, name, "{ type inet_service; flags interval; auto-merge; }");
}

function nft_create_ipv4_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr . inet_service; flags interval; }");
}

function nft_create_ipv6_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv6_addr . inet_service; flags interval; }");
}

function nft_create_ifname_set(table, name) {
    return nft_create_set(table, name, "{ type ifname; flags interval; }");
}

function nft_add_set_elements(table, set_name, elements) {
    let stamp = clock();
    let tmp_path = sprintf("/tmp/nft_elements.%d.%d.tmp", stamp[0], stamp[1]);
    let rules_content = sprintf("add element inet %s %s { %s }\n", table, set_name, as_string(elements));
    
    let write_stamp = clock();
    let real_tmp = sprintf("%s.write.%d.%d", tmp_path, write_stamp[0], write_stamp[1]);
    if (fs.writefile(real_tmp, rules_content) == null) {
        fs.unlink(real_tmp);
        return false;
    }
    if (!fs.rename(real_tmp, tmp_path)) {
        fs.unlink(real_tmp);
        return false;
    }

    let cmd_str = sprintf("nft -f %s", shell_quote(tmp_path));
    let res = system(cmd_str + " 2>/tmp/nft_err.log");
    fs.unlink(tmp_path);

    if (res != 0) {
        let err_msg = trim(as_string(fs.readfile("/tmp/nft_err.log") || ""));
        log_fatal("nft add element failed: cmd='" + cmd_str + "', code=" + res + ", err='" + err_msg + "'");
    }
    return res == 0;
}

function whitespace_values(value) {
    let result = [];

    for (let item in split(replace(as_string(value), /[[:space:]]+/g, " "), " ")) {
        item = trim(item);
        if (item != "")
            push(result, item);
    }

    return result;
}

function nft_create_chain(table, name, definition) {
    return run_args([ "nft", "add", "chain", "inet", table, name, definition ]);
}

function nft_add_rule(table, chain, args) {
    let command = [ "nft", "add", "rule", "inet", table, chain ];
    for (let arg in args)
        push(command, arg);
    return run_args(command);
}

function nft_insert_rule(table, chain, args) {
    let command = [ "nft", "insert", "rule", "inet", table, chain ];
    for (let arg in args)
        push(command, arg);
    return run_args(command);
}

let LOCALV4_RANGES = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0-255.255.255.255"
];

let LOCALV6_RANGES = [
    "::/128",
    "::1/128",
    "64:ff9b::/96",
    "100::/64",
    "2001:db8::/32",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8"
];

function default_arg(value, fallback) {
    value = as_string(value);
    return value == "" ? fallback : value;
}

function combined_domain_condition_text(section) {
    if (type(object_or_empty(section)["domain"]) != "array") {
        let value = option(section, "domain", "");
        if (value != "")
            return value;
    }

    return option(section, "domain_suffix_text", "");
}

function section_rule_condition_csv(section, key, kind) {
    return rule_condition_csv_value(
        key,
        kind,
        option(section, key + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, key + "_text", ""),
        option(section, key, ""),
        combined_domain_condition_text(section),
        option(section, "domain_suffix", "")
    );
}

function section_rule_ports_csv(section) {
    return rule_ports_csv_value(option(section, "ports", ""), option(section, "ports_text", ""));
}

function section_option_nonempty(section, key) {
    return option(section, key, "") != "";
}

function section_has_destination_matchers(section) {
    return section_rule_condition_csv(section, "domain", "domains") != "" ||
        section_rule_condition_csv(section, "domain_suffix", "domains") != "" ||
        section_rule_condition_csv(section, "domain_keyword", "generic") != "" ||
        section_rule_condition_csv(section, "domain_regex", "generic") != "" ||
        section_rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        length(connections.community_lists(section)) > 0 ||
        length(connections.rule_sets(section)) > 0 ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        section_option_nonempty(section, "domain_ip_lists");
}

function section_action(section) {
    return option(section, "action", "");
}

function action_captures_traffic(action) {
    return action == "connection" || action == "proxy" || action == "outbound" || action == "vpn" ||
        action == "awg" || action == "warp" || action == "block" || action == "zapret" || action == "zapret2" || action == "byedpi";
}

function section_priority_action(section) {
    let action = section_action(section);
    if (action == "bypass")
        return "bypass";
    if (action_captures_traffic(action))
        return "capture";
    return "";
}

function section_priority_prefix(section) {
    return "tachyon_rule_" + as_string(section[".name"]);
}

function section_priority_sets(section) {
    let prefix = section_priority_prefix(section);
    return {
        subnets: prefix + "_subnets",
        subnets6: prefix + "_subnets6",
        ports: prefix + "_ports",
        ip_ports: prefix + "_ip_ports",
        ip6_ports: prefix + "_ip6_ports",
        sources: prefix + "_sources",
        sources6: prefix + "_sources6"
    };
}

function section_source_ip_values(section) {
    return section_rule_condition_csv(section, "source_ip_cidr", "subnets");
}

function section_has_source_ip_matchers(section) {
    return section_source_ip_values(section) != "";
}

function section_has_subnet_update_sources(section) {
    return rule_config.has_community_subnet_list(connections.community_lists_value(section)) ||
        length(connections.rule_sets_with_subnets(section)) > 0 ||
        option(section, "domain_ip_lists", "") != "";
}

function section_has_nft_ip_matchers(section) {
    return section_rule_condition_csv(section, "ip_cidr", "subnets") != "" ||
        section_has_subnet_update_sources(section);
}

function section_has_nft_port_only_matchers(section) {
    return section_rule_ports_csv(section) != "" && !section_has_destination_matchers(section);
}

function section_priority_needs_plain_ip_rules(section) {
    return section_has_nft_ip_matchers(section) && section_rule_ports_csv(section) == "";
}

function section_priority_needs_ip_port_rules(section) {
    return section_has_nft_ip_matchers(section) &&
        (section_rule_ports_csv(section) != "" || length(connections.rule_sets_with_subnets(section)) > 0);
}

function section_has_dscp_matchers(section) {
    return length(connections.dscp_list(section)) > 0;
}

function section_needs_priority_sets(section) {
    return section_priority_action(section) != "" &&
        (section_has_nft_ip_matchers(section) || section_has_nft_port_only_matchers(section) || section_has_dscp_matchers(section));
}

function nft_create_priority_chains(table) {
    return nft_create_chain(table, "priority_rules", "{ }") &&
        nft_create_chain(table, "priority_output_rules", "{ }") &&
        nft_add_rule(table, "priority_output_rules", [ "meta", "mark", "!=", "0", "return" ]);
}

function nft_create_priority_sets(table, sets) {
    return nft_create_ipv4_set(table, sets.subnets) &&
        nft_create_ipv6_set(table, sets.subnets6) &&
        nft_create_inet_service_set(table, sets.ports) &&
        nft_create_ipv4_port_set(table, sets.ip_ports) &&
        nft_create_ipv6_port_set(table, sets.ip6_ports) &&
        nft_create_ipv4_set(table, sets.sources) &&
        nft_create_ipv6_set(table, sets.sources6);
}

function nft_priority_verdict_args(priority_action, mark) {
    if (priority_action == "bypass")
        return [ "counter", "accept" ];
    return [ "meta", "mark", "set", mark, "counter", "accept" ];
}

function append_array(target, additions) {
    for (let item in additions)
        push(target, item);
    return target;
}

function nft_source_match_args(section, family, sets) {
    if (!section_has_source_ip_matchers(section))
        return [];
    return family == 6
        ? [ "ip6", "saddr", "@" + as_string(sets.sources6) ]
        : [ "ip", "saddr", "@" + as_string(sets.sources) ];
}

// nft accepts: ip saddr != { addr1, addr2, ... }  as a single argument.
function nft_excluded_source_match_args(section, family) {
    let excluded = list_option(section, "excluded_ips");
    if (length(excluded) == 0)
        return [];
    let ip_key = family == 6 ? "ip6" : "ip";
    let addrs = [];
    for (let ip in excluded)
        if (core_ip.ip_family(as_string(ip)) == family)
            push(addrs, as_string(ip));
    if (length(addrs) == 0)
        return [];
    return [ ip_key, "saddr", "!=", "{ " + join(", ", addrs) + " }" ];
}

function nft_priority_rule_args(section, family, local_set, match_args, mark) {
    let sets = section_priority_sets(section);
    let args = [];
    if (family == 4)
        append_array(args, nft_source_match_args(section, 4, sets));
    else
        append_array(args, nft_source_match_args(section, 6, sets));
    append_array(args, nft_excluded_source_match_args(section, family));
    append_array(args, [ family == 6 ? "ip6" : "ip", "daddr", "!=", "@" + as_string(local_set) ]);
    append_array(args, match_args);
    append_array(args, nft_priority_verdict_args(section_priority_action(section), mark));
    return args;
}


function nft_priority_prerouting_args(section, family, interface_set, local_set, match_args, mark) {
    let args = [ "iifname", "@" + as_string(interface_set) ];
    append_array(args, nft_priority_rule_args(section, family, local_set, match_args, mark));
    return args;
}

function nft_add_priority_rule_pair(table, chain, section, interface_set, localv4_set, localv6_set, match4, match6, mark) {
    if (chain == "priority_rules") {
        return nft_add_rule(table, chain, nft_priority_prerouting_args(section, 4, interface_set, localv4_set, match4, mark)) &&
            nft_add_rule(table, chain, nft_priority_prerouting_args(section, 6, interface_set, localv6_set, match6, mark));
    }

    return nft_add_rule(table, chain, nft_priority_rule_args(section, 4, localv4_set, match4, mark)) &&
        nft_add_rule(table, chain, nft_priority_rule_args(section, 6, localv6_set, match6, mark));
}

function nft_add_section_priority_rules(table, section, interface_set, localv4_set, localv6_set, mark) {
    if (!section_needs_priority_sets(section))
        return true;

    let sets = section_priority_sets(section);
    if (!nft_create_priority_sets(table, sets))
        return false;

    let needs_plain_ip_rules = section_priority_needs_plain_ip_rules(section);
    let needs_ip_port_rules = section_priority_needs_ip_port_rules(section);
    let has_port_only_matchers = section_has_nft_port_only_matchers(section);
    let is_bypass = (section_priority_action(section) == "bypass");
    let match_ip4 = [ "ip", "daddr", "@" + as_string(sets.subnets) ];
    let match_ip6 = [ "ip6", "daddr", "@" + as_string(sets.subnets6) ];
    let match_ip4_tcp = [ "ip", "daddr", "@" + as_string(sets.subnets), "meta", "l4proto", "tcp" ];
    let match_ip4_udp = [ "ip", "daddr", "@" + as_string(sets.subnets), "meta", "l4proto", "udp" ];
    let match_ip6_tcp = [ "ip6", "daddr", "@" + as_string(sets.subnets6), "meta", "l4proto", "tcp" ];
    let match_ip6_udp = [ "ip6", "daddr", "@" + as_string(sets.subnets6), "meta", "l4proto", "udp" ];
    let match_ip_port4_tcp = [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip_ports) ];
    let match_ip_port4_udp = [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip_ports) ];
    let match_ip_port6_tcp = [ "ip6", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip6_ports) ];
    let match_ip_port6_udp = [ "ip6", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip6_ports) ];
    let match_port4_tcp = [ "tcp", "dport", "@" + as_string(sets.ports) ];
    let match_port4_udp = [ "udp", "dport", "@" + as_string(sets.ports) ];
    let match_port6_tcp = [ "tcp", "dport", "@" + as_string(sets.ports) ];
    let match_port6_udp = [ "udp", "dport", "@" + as_string(sets.ports) ];

    if (needs_plain_ip_rules) {
        if (is_bypass) {
            if (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip4, match_ip6, mark) ||
                !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip4, match_ip6, mark))
                return false;
        } else {
            if (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip4_tcp, match_ip6_tcp, mark) ||
                !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip4_udp, match_ip6_udp, mark) ||
                !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip4_tcp, match_ip6_tcp, mark) ||
                !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip4_udp, match_ip6_udp, mark))
                return false;
        }
    }

    if (needs_ip_port_rules &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_tcp, match_ip_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_udp, match_ip_port6_udp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_tcp, match_ip_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_ip_port4_udp, match_ip_port6_udp, mark)))
        return false;

    if (has_port_only_matchers &&
        (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port4_tcp, match_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_port4_udp, match_port6_udp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_port4_tcp, match_port6_tcp, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_port4_udp, match_port6_udp, mark)))
        return false;

    if (section_has_dscp_matchers(section)) {
        let dscp_vals = connections.dscp_list(section);
        let dscp_str = length(dscp_vals) == 1 ? as_string(dscp_vals[0]) : "{ " + join(", ", dscp_vals) + " }";
        let match_dscp4 = [ "ip", "dscp", dscp_str ];
        let match_dscp6 = [ "ip6", "dscp", dscp_str ];
        if (!nft_add_priority_rule_pair(table, "priority_rules", section, interface_set, localv4_set, localv6_set, match_dscp4, match_dscp6, mark) ||
            !nft_add_priority_rule_pair(table, "priority_output_rules", section, interface_set, localv4_set, localv6_set, match_dscp4, match_dscp6, mark))
            return false;
    }

    return true;
}

function nft_add_section_priority_rules_from_sections(sections, table, interface_set, localv4_set, localv6_set, mark) {
    localv6_set = default_arg(localv6_set, "localv6");
    let zapret2_idx = 1;
    let zapret_idx = 1;
    for (let section in sections) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true))
            continue;
        let sec_mark = mark;
        let action = option(section, "action", "connection");
        if (action == "zapret2") {
            sec_mark = sprintf("0x%08x", 0x02000000 + zapret2_idx);
            zapret2_idx++;
        } else if (action == "zapret") {
            sec_mark = sprintf("0x%08x", 0x01000000 + zapret_idx);
            zapret_idx++;
        }
        if (!nft_add_section_priority_rules(table, section, interface_set, localv4_set, localv6_set, sec_mark))
            return false;
    }
    return true;
}

function normalize_schedule_day_name(day) {
    let d = lc(trim(as_string(day)));
    let map = {
        "mon": "Monday", "monday": "Monday", "1": "Monday",
        "tue": "Tuesday", "tuesday": "Tuesday", "2": "Tuesday",
        "wed": "Wednesday", "wednesday": "Wednesday", "3": "Wednesday",
        "thu": "Thursday", "thursday": "Thursday", "4": "Thursday",
        "fri": "Friday", "friday": "Friday", "5": "Friday",
        "sat": "Saturday", "saturday": "Saturday", "6": "Saturday",
        "sun": "Sunday", "sunday": "Sunday", "7": "Sunday", "0": "Sunday"
    };
    return map[d] || null;
}

function nft_schedule_days_match_args(schedule) {
    let raw_days = list_option(schedule, "days");
    if (length(raw_days) == 0)
        return [];
    
    let days_set = {};
    for (let day in raw_days) {
        let norm = normalize_schedule_day_name(day);
        if (norm) days_set[norm] = true;
    }
    let day_names = sort(keys(days_set));
    if (length(day_names) == 0 || length(day_names) == 7)
        return [];
    
    if (length(day_names) == 1)
        return [ "meta", "day", day_names[0] ];
    
    return [ "meta", "day", "{ " + join(", ", day_names) + " }" ];
}

function nft_schedule_time_intervals(start_time, end_time) {
    start_time = trim(as_string(start_time));
    end_time = trim(as_string(end_time));
    
    if (start_time == "" || end_time == "")
        return [ [ "00:00:00", "23:59:59" ] ];
    
    if (length(start_time) == 5) start_time += ":00";
    if (length(end_time) == 5) end_time += ":00";
    
    if (start_time > end_time) {
        // Crosses midnight, e.g. 22:00:00 to 08:00:00
        return [
            [ start_time, "23:59:59" ],
            [ "00:00:00", end_time ]
        ];
    }
    
    return [ [ start_time, end_time ] ];
}

function resolve_schedule_devices(schedule, profiles) {
    let raw_ips = list_option(schedule, "device_ip");
    if (length(raw_ips) == 0) {
        let single_ip = option(schedule, "device_ip", "");
        if (single_ip != "") raw_ips = [ single_ip ];
    }
    let result = [];
    for (let ip in raw_ips) {
        let clean = trim(as_string(ip));
        if (clean != "" && index(result, clean) < 0)
            push(result, clean);
    }
    let prof_names = list_option(schedule, "profile");
    if (length(prof_names) == 0) {
        let single_p = option(schedule, "profile", "");
        if (single_p != "") prof_names = [ single_p ];
    }
    if (profiles != null && length(prof_names) > 0) {
        for (let p_name in prof_names) {
            for (let profile in profiles) {
                profile = object_or_empty(profile);
                if (as_string(profile[".name"]) == p_name && bool_option(profile, "enabled", true)) {
                    let p_ips = list_option(profile, "device_ip");
                    if (length(p_ips) == 0) {
                        let single_p_ip = option(profile, "device_ip", "");
                        if (single_p_ip != "") p_ips = [ single_p_ip ];
                    }
                    for (let p_ip in p_ips) {
                        let clean_p = trim(as_string(p_ip));
                        if (clean_p != "" && index(result, clean_p) < 0)
                            push(result, clean_p);
                    }
                }
            }
        }
    }
    return result;
}

function nft_add_profile_doh_block_rules(profiles, table) {
    if (!profiles || length(profiles) == 0)
        return true;

    for (let profile in profiles) {
        profile = object_or_empty(profile);
        if (!bool_option(profile, "enabled", true) || !bool_option(profile, "block_doh", false))
            continue;

        let raw_ips = list_option(profile, "device_ip");
        if (length(raw_ips) == 0) {
            let single_ip = option(profile, "device_ip", "");
            if (single_ip != "") raw_ips = [ single_ip ];
        }
        if (length(raw_ips) == 0)
            continue;

        let label = as_string(option(profile, "label", profile[".name"]));
        let comment = "tachyon-doh:" + label;

        for (let raw_ip in raw_ips) {
            let dev_str = trim(as_string(raw_ip));
            if (dev_str == "") continue;
            let is_mac = match(dev_str, /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/) != null;
            let family = is_mac ? 0 : core_ip.ip_family(dev_str);
            let saddr_key = family == 6 ? "ip6" : "ip";

            let tcp_rule = is_mac ?
                [ "ether", "saddr", lc(replace(dev_str, "-", ":")), "tcp", "dport", "853", "counter", "drop", "comment", "\"" + comment + "\"" ] :
                [ saddr_key, "saddr", dev_str, "tcp", "dport", "853", "counter", "drop", "comment", "\"" + comment + "\"" ];
            let udp_rule = is_mac ?
                [ "ether", "saddr", lc(replace(dev_str, "-", ":")), "udp", "dport", "853", "counter", "drop", "comment", "\"" + comment + "\"" ] :
                [ saddr_key, "saddr", dev_str, "udp", "dport", "853", "counter", "drop", "comment", "\"" + comment + "\"" ];

            nft_add_rule(table, "parental_forward", tcp_rule);
            nft_add_rule(table, "parental_forward", udp_rule);
            nft_add_rule(table, "parental_control", tcp_rule);
            nft_add_rule(table, "parental_control", udp_rule);
        }
    }
    return true;
}

function nft_add_schedule_rules_from_schedules(schedules, sections, table, profiles) {
    for (let schedule in schedules) {
        schedule = object_or_empty(schedule);
        if (!bool_option(schedule, "enabled", true))
            continue;
        
        let raw_ips = resolve_schedule_devices(schedule, profiles);
        if (length(raw_ips) == 0)
            continue;
        
        let start_time = option(schedule, "start_time", "");
        let end_time = option(schedule, "end_time", "");
        let intervals = nft_schedule_time_intervals(start_time, end_time);
        let days_args = nft_schedule_days_match_args(schedule);
        let target = option(schedule, "target", "all");
        let action = option(schedule, "action", "block");
        let verdict = action == "allow" ? "accept" : "drop";
        
        let target_sec_names = [];
        if (target == "sections" || (target != "all" && target != "")) {
            let raw_secs = list_option(schedule, "sections");
            if (length(raw_secs) == 0) {
                let single_sec = option(schedule, "sections", "");
                if (single_sec != "") raw_secs = [ single_sec ];
                else if (target != "sections") raw_secs = [ target ];
            }
            target_sec_names = raw_secs;
        }

        for (let raw_ip in raw_ips) {
            let dev_str = trim(as_string(raw_ip));
            if (dev_str == "") continue;
            let is_mac = match(dev_str, /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/) != null;
            let family = is_mac ? 0 : core_ip.ip_family(dev_str);
            let saddr_key = family == 6 ? "ip6" : "ip";
            
            for (let interval in intervals) {
                let time_args = [ "meta", "hour", sprintf("\"%s\"-\"%s\"", interval[0], interval[1]) ];
                let base_match = is_mac ?
                    [ "ether", "saddr", lc(replace(dev_str, "-", ":")) ] :
                    [ saddr_key, "saddr", dev_str ];
                append_array(base_match, days_args);
                append_array(base_match, time_args);
                
                if (target == "all" || (length(target_sec_names) == 0 && target != "sections")) {
                    let fwd_rule = [];
                    append_array(fwd_rule, base_match);
                    append_array(fwd_rule, [ "counter", verdict ]);
                    nft_add_rule(table, "parental_forward", fwd_rule);
                    
                    let ctrl_rule = [];
                    append_array(ctrl_rule, base_match);
                    append_array(ctrl_rule, [ "counter", verdict ]);
                    nft_add_rule(table, "parental_control", ctrl_rule);
                } else {
                    for (let sec_name in target_sec_names) {
                        let target_section = section_by_name(sections, sec_name);
                        if (!target_section) continue;
                        
                        let sets = section_priority_sets(target_section);
                        if (!sets) continue;

                        if (sets.subnets) {
                            let sub_rule = [];
                            append_array(sub_rule, base_match);
                            append_array(sub_rule, [ "ip", "daddr", "@" + as_string(sets.subnets), "counter", verdict ]);
                            nft_add_rule(table, "parental_control", sub_rule);
                            nft_add_rule(table, "parental_forward", sub_rule);
                        }
                        if (sets.subnets6 && (family == 6 || is_mac)) {
                            let sub6_rule = [];
                            append_array(sub6_rule, base_match);
                            append_array(sub6_rule, [ "ip6", "daddr", "@" + as_string(sets.subnets6), "counter", verdict ]);
                            nft_add_rule(table, "parental_control", sub6_rule);
                            nft_add_rule(table, "parental_forward", sub6_rule);
                        }
                        if (sets.ip_ports) {
                            let ipport_tcp = [];
                            append_array(ipport_tcp, base_match);
                            append_array(ipport_tcp, [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(sets.ip_ports), "counter", verdict ]);
                            nft_add_rule(table, "parental_control", ipport_tcp);
                            nft_add_rule(table, "parental_forward", ipport_tcp);

                            let ipport_udp = [];
                            append_array(ipport_udp, base_match);
                            append_array(ipport_udp, [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(sets.ip_ports), "counter", verdict ]);
                            nft_add_rule(table, "parental_control", ipport_udp);
                            nft_add_rule(table, "parental_forward", ipport_udp);
                        }
                        if (sets.ports) {
                            let port_tcp = [];
                            append_array(port_tcp, base_match);
                            append_array(port_tcp, [ "tcp", "dport", "@" + as_string(sets.ports), "counter", verdict ]);
                            nft_add_rule(table, "parental_control", port_tcp);
                            nft_add_rule(table, "parental_forward", port_tcp);

                            let port_udp = [];
                            append_array(port_udp, base_match);
                            append_array(port_udp, [ "udp", "dport", "@" + as_string(sets.ports), "counter", verdict ]);
                            nft_add_rule(table, "parental_control", port_udp);
                            nft_add_rule(table, "parental_forward", port_udp);
                        }
                    }
                }
            }
        }
    }
    return true;
}

function nft_add_schedule_rules_from_uci(table, sections) {
    return nft_add_schedule_rules_from_schedules(uci_sections("schedule"), sections, table, uci_sections("profile"));
}

// ─── Content blocking DNS redirect ───────────────────────────────────────────
// Schedules with blocked_domains redirect the device's DNS queries (udp/tcp
// 53) to the dedicated sing-box dns-block-in inbound (127.0.0.43:1053) when
// the schedule's time window is active. Inside the window the block inbound
// rejects the blocked domains; outside it the query flows to the normal
// dns-in inbound as usual. MAC-address devices match via ether saddr, which
// also covers devices whose IP is DHCP-assigned.

function nft_add_dns_block_rules_from_schedules(schedules, table, profiles) {
    let added = false;
    for (let schedule in schedules) {
        schedule = object_or_empty(schedule);
        if (!bool_option(schedule, "enabled", true))
            continue;
        if (length(list_option(schedule, "blocked_domains")) == 0) {
            let single_domain = option(schedule, "blocked_domains", "");
            if (single_domain == "") continue;
        }

        let raw_ips = resolve_schedule_devices(schedule, profiles);
        if (length(raw_ips) == 0)
            continue;

        let label = as_string(option(schedule, "label", schedule[".name"]));
        let comment = "tachyon-block:" + label;

        let start_time = option(schedule, "start_time", "");
        let end_time = option(schedule, "end_time", "");
        let intervals = nft_schedule_time_intervals(start_time, end_time);
        let days_args = nft_schedule_days_match_args(schedule);
        let always_on = start_time == "" && end_time == "";

        for (let raw_ip in raw_ips) {
            let dev_str = trim(as_string(raw_ip));
            if (dev_str == "") continue;
            let is_mac = match(dev_str, /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/) != null;
            let family = is_mac ? 0 : core_ip.ip_family(dev_str);
            if (!is_mac && family != 4)
                continue; // dns-block-in listens on IPv4 only

            for (let interval in intervals) {
                let match_args = [];
                if (is_mac) {
                    append_array(match_args, [ "ether", "saddr", lc(replace(dev_str, "-", ":")) ]);
                } else {
                    append_array(match_args, [ "ip", "saddr", dev_str ]);
                }
                if (!always_on) {
                    append_array(match_args, [ "meta", "hour", sprintf("\"%s\"-\"%s\"", interval[0], interval[1]) ]);
                }
                append_array(match_args, days_args);
                append_array(match_args, [ "udp", "dport", "53", "redirect", "to", DNS_BLOCK_TARGET, "counter", "comment", "\"" + comment + "\"" ]);
                if (!nft_add_rule(table, "dns_block", match_args))
                    return false;
                added = true;

                let tcp_args = [];
                if (is_mac) {
                    append_array(tcp_args, [ "ether", "saddr", lc(replace(dev_str, "-", ":")) ]);
                } else {
                    append_array(tcp_args, [ "ip", "saddr", dev_str ]);
                }
                if (!always_on) {
                    append_array(tcp_args, [ "meta", "hour", sprintf("\"%s\"-\"%s\"", interval[0], interval[1]) ]);
                }
                append_array(tcp_args, days_args);
                append_array(tcp_args, [ "tcp", "dport", "53", "redirect", "to", DNS_BLOCK_TARGET, "counter", "comment", "\"" + comment + "\"" ]);
                if (!nft_add_rule(table, "dns_block", tcp_args))
                    return false;
                added = true;
            }
        }
    }

    // Profiles with blocked_domains or safe_search also redirect DNS to sing-box block inbound
    if (profiles != null && length(profiles) > 0) {
        for (let profile in profiles) {
            profile = object_or_empty(profile);
            if (!bool_option(profile, "enabled", true))
                continue;
            let has_domains = length(list_option(profile, "blocked_domains")) > 0 || option(profile, "blocked_domains", "") != "";
            let has_safesearch = bool_option(profile, "safe_search", false);
            if (!has_domains && !has_safesearch)
                continue;

            let p_ips = list_option(profile, "device_ip");
            if (length(p_ips) == 0) {
                let single_p_ip = option(profile, "device_ip", "");
                if (single_p_ip != "") p_ips = [ single_p_ip ];
            }
            if (length(p_ips) == 0)
                continue;

            let label = as_string(option(profile, "label", profile[".name"]));
            let comment = "tachyon-profile:" + label;

            for (let raw_ip in p_ips) {
                let dev_str = trim(as_string(raw_ip));
                if (dev_str == "") continue;
                let is_mac = match(dev_str, /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/) != null;
                let family = is_mac ? 0 : core_ip.ip_family(dev_str);
                if (!is_mac && family != 4)
                    continue;

                let match_args = [];
                if (is_mac)
                    append_array(match_args, [ "ether", "saddr", lc(replace(dev_str, "-", ":")) ]);
                else
                    append_array(match_args, [ "ip", "saddr", dev_str ]);
                append_array(match_args, [ "udp", "dport", "53", "redirect", "to", DNS_BLOCK_TARGET, "counter", "comment", "\"" + comment + "\"" ]);
                if (!nft_add_rule(table, "dns_block", match_args))
                    return false;
                added = true;

                let tcp_args = [];
                if (is_mac)
                    append_array(tcp_args, [ "ether", "saddr", lc(replace(dev_str, "-", ":")) ]);
                else
                    append_array(tcp_args, [ "ip", "saddr", dev_str ]);
                append_array(tcp_args, [ "tcp", "dport", "53", "redirect", "to", DNS_BLOCK_TARGET, "counter", "comment", "\"" + comment + "\"" ]);
                if (!nft_add_rule(table, "dns_block", tcp_args))
                    return false;
                added = true;
            }
        }
    }

    return true;
}

function nft_add_dns_block_rules_from_uci(table) {
    return nft_add_dns_block_rules_from_schedules(uci_sections("schedule"), table, uci_sections("profile"));
}

function nft_create_runtime_base(table, localv4_set, common_set, port_set, ip_port_set, interface_set, source_interfaces, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, exclude_ntp, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    localv6_set = default_arg(localv6_set, "localv6");
    common6_set = default_arg(common6_set, "tachyon_subnets6");
    ip_port6_set = default_arg(ip_port6_set, "tachyon_ip6_ports");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");
    tproxy6_address = default_arg(tproxy6_address, "::1");

    if (!nft_create_table(table) ||
        !nft_create_ipv4_set(table, localv4_set) ||
        !nft_add_set_elements(table, localv4_set, join(",", LOCALV4_RANGES)) ||
        !nft_create_ipv6_set(table, localv6_set) ||
        !nft_add_set_elements(table, localv6_set, join(",", LOCALV6_RANGES)) ||
        !nft_create_ipv4_set(table, common_set) ||
        !nft_create_ipv6_set(table, common6_set) ||
        !nft_create_inet_service_set(table, port_set) ||
        !nft_create_ipv4_port_set(table, ip_port_set) ||
        !nft_create_ipv6_port_set(table, ip_port6_set) ||
        !nft_create_ifname_set(table, interface_set))
        return false;

    for (let interface in whitespace_values(source_interfaces))
        if (!nft_add_set_elements(table, interface_set, interface))
            return false;

    if (!nft_create_chain(table, "mangle", "{ type filter hook prerouting priority -149; policy accept; }") ||
        !nft_create_chain(table, "mangle_output", "{ type route hook output priority -150; policy accept; }") ||
        !nft_create_priority_chains(table) ||
        !nft_create_chain(table, "parental_control", "{ }") ||
        !nft_create_chain(table, "parental_forward", "{ }") ||
        !nft_create_chain(table, "dns_block", "{ type nat hook prerouting priority -101; policy accept; }") ||
        !nft_create_chain(table, "proxy", "{ type filter hook prerouting priority -100; policy accept; }"))
        return false;

    if (!nft_add_rule(table, "mangle", [ "ct", "status", "dnat", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "jump", "parental_control" ]))
        return false;

    // Native Tailscale: tailnet-bound traffic and anything already marked by
    // the Tailscale runtime (mask 0x00ff0000, see config validator) must not
    // be captured into tproxy — it is routed to tailscale0 instead.
    if (native_tailscale_enabled()) {
        if (!nft_add_rule(table, "mangle", [ "meta", "mark", "&", "0x00ff0000", "!=", "0", "return" ]) ||
            !nft_add_rule(table, "mangle", [ "ip", "daddr", "100.64.0.0/10", "return" ]) ||
            !nft_add_rule(table, "mangle", [ "ip6", "daddr", "fd7a:115c:a1e0::/48", "return" ]))
            return false;
        log_debug("Native Tailscale bypass rules added to mangle chain");
    }

    if (!nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", "@" + as_string(localv6_set), "return" ]))
        return false;

    let console_ips_list = list_option(uci_settings(), "game_console_ips");
    if (bool_option(uci_settings(), "game_console_optimizer", false) && length(console_ips_list) > 0) {
        let v4_ips = [];
        let v6_ips = [];
        for (let ip in console_ips_list) {
            if (core_ip.ip_family(ip) == 4) push(v4_ips, ip);
            else if (core_ip.ip_family(ip) == 6) push(v6_ips, ip);
        }
        if (length(v4_ips) > 0) {
            if (!nft_create_ipv4_set(table, "tachyon_consoles") ||
                !nft_add_set_elements(table, "tachyon_consoles", join(",", v4_ips)) ||
                !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "saddr", "@tachyon_consoles", "meta", "l4proto", "udp", "counter", "return" ]))
                return false;
        }
        if (length(v6_ips) > 0) {
            if (!nft_create_ipv6_set(table, "tachyon_consoles6") ||
                !nft_add_set_elements(table, "tachyon_consoles6", join(",", v6_ips)) ||
                !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "saddr", "@tachyon_consoles6", "meta", "l4proto", "udp", "counter", "return" ]))
                return false;
        }
    }

    if (bool_option(uci_settings(), "webrtc_leak_protect", false)) {
        if (!nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "udp", "dport", "3478", "counter", "drop" ]) ||
            !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "udp", "dport", "5349", "counter", "drop" ]) ||
            !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "udp", "dport", "19302", "counter", "drop" ]))
            return false;
    }

    if (!nft_add_rule(table, "mangle", [ "jump", "priority_rules" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", "@" + as_string(common6_set), "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", "@" + as_string(common6_set), "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", ".", "tcp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", ".", "udp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", ".", "tcp", "dport", "@" + as_string(ip_port6_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", ".", "udp", "dport", "@" + as_string(ip_port6_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "!=", "@" + as_string(localv4_set), "tcp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "!=", "@" + as_string(localv4_set), "udp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", "!=", "@" + as_string(localv6_set), "tcp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", "!=", "@" + as_string(localv6_set), "udp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", fakeip6_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip6", "daddr", fakeip6_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "tcp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "udp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "tcp", "tproxy", "ip6", "to", core_ip.format_ipv6_tproxy_target(tproxy6_address, tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "udp", "tproxy", "ip6", "to", core_ip.format_ipv6_tproxy_target(tproxy6_address, tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ip6", "daddr", "@" + as_string(localv6_set), "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "meta", "mark", outbound_mark, "counter", "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "jump", "priority_output_rules" ]))
        return false;

    if (!nft_create_chain(table, "mangle_forward", "{ type filter hook forward priority -150; policy accept; }") ||
        !nft_add_rule(table, "mangle_forward", [ "jump", "parental_forward" ]))
        return false;

    if (nft_add_rule(table, "mangle_forward", [ "tcp", "flags", "syn", "tcp", "option", "maxseg", "size", "set", "rt", "mtu" ])) {
        if (!nft_add_rule(table, "mangle_output", [ "tcp", "flags", "syn", "tcp", "option", "maxseg", "size", "set", "rt", "mtu" ]))
            return false;
    } else {
        if (!nft_add_rule(table, "mangle_forward", [ "tcp", "flags", "syn", "tcp", "option", "maxseg", "size", "set", "1400" ]) ||
            !nft_add_rule(table, "mangle_output", [ "tcp", "flags", "syn", "tcp", "option", "maxseg", "size", "set", "1400" ]))
            return false;
    }

    if (arg_bool(exclude_ntp) && !nft_insert_rule(table, "mangle", [ "udp", "dport", "123", "return" ]))
        return false;

    // QoS Low-Latency Gaming & Voice Acceleration Engine
    if (uci_settings().qos_priority_engine != "0") {
        // Voice & Discord RTC (DSCP EF 0x2e)
        nft_add_rule(table, "mangle_forward", [ "udp", "dport", "{ 5000-5020, 3478, 19302, 50000-65535 }", "ip", "dscp", "set", "0x2e" ]);
        nft_add_rule(table, "mangle_output", [ "udp", "dport", "{ 5000-5020, 3478, 19302, 50000-65535 }", "ip", "dscp", "set", "0x2e" ]);

        // Gaming Traffic (Steam, CS, Dota, Valorant, Apex, PUBG, Roblox) (DSCP AF41 0x22)
        nft_add_rule(table, "mangle_forward", [ "udp", "dport", "{ 3074, 7000-9000, 27000-27050, 28960 }", "ip", "dscp", "set", "0x22" ]);
        nft_add_rule(table, "mangle_output", [ "udp", "dport", "{ 3074, 7000-9000, 27000-27050, 28960 }", "ip", "dscp", "set", "0x22" ]);

        // TCP ACK Acceleration (DSCP CS2)
        nft_add_rule(table, "mangle_forward", [ "tcp", "flags", "&", "(fin|syn|rst|ack)", "==", "ack", "ip", "dscp", "set", "cs2" ]);
    }

    return true;
}

function nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    let settings = uci_settings();

    return nft_create_runtime_base(
        table,
        localv4_set,
        common_set,
        port_set,
        ip_port_set,
        interface_set,
        option(settings, "source_network_interfaces", "br-lan"),
        fakeip_mark,
        outbound_mark,
        fakeip_range,
        tproxy_port,
        option(settings, "exclude_ntp", "0"),
        localv6_set,
        common6_set,
        ip_port6_set,
        fakeip6_range,
        tproxy6_address
    );
}

function nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range, localv6_set, common6_set, ip_port6_set, fakeip6_range) {
    localv6_set = default_arg(localv6_set, "localv6");
    common6_set = default_arg(common6_set, "tachyon_subnets6");
    ip_port6_set = default_arg(ip_port6_set, "tachyon_ip6_ports");
    fakeip6_range = default_arg(fakeip6_range, "fc00::/18");

    return (
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", "@" + as_string(common6_set), "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", "@" + as_string(common6_set), "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", ".", "tcp", "dport", "@" + as_string(ip_port6_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", ".", "udp", "dport", "@" + as_string(ip_port6_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "tcp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "udp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip6", "daddr", fakeip6_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ])
    );
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_mark_number(value) {
    value = lc(trim(as_string(value)));
    if (value == "")
        return null;

    if (substr(value, 0, 2) == "0x") {
        value = substr(value, 2);
        if (value == "")
            return null;

        let result = 0;
        for (let i = 0; i < length(value); i++) {
            let digit = hex_digit_value(substr(value, i, 1));
            if (digit == null)
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    return match(value, /^[0-9]+$/) == null ? null : int(value);
}

function nft_provider_mark_hex(route_mark_base, index) {
    let base = parse_mark_number(route_mark_base);
    index = int(index || 0);
    if (base == null || index < 1)
        return "";

    return sprintf("0x%08x", base + index);
}

function nft_create_provider_output_rules_from_sections(sections, table, action, provider_bin, route_mark_base, queue_base, desync_mark, desync_mark_postnat) {
    if (!file_executable(provider_bin))
        return true;

    let index = 0;
    let added = false;

    for (let section in sections) {
        section = object_or_empty(section);
        if (!bool_option(section, "enabled", true) || option(section, "action", "") != action)
            continue;

        index++;
        let mark_hex = nft_provider_mark_hex(route_mark_base, index);
        let queue_number = int(queue_base || 0) + index - 1;
        if (mark_hex == "" || queue_number < 0)
            return false;

        if (!added) {
            if (!nft_add_rule(table, "mangle_output", [ "meta", "mark", "&", desync_mark, "==", desync_mark, "return" ]) ||
                !nft_add_rule(table, "mangle_output", [ "meta", "mark", "&", desync_mark_postnat, "==", desync_mark_postnat, "return" ]))
                return false;
            added = true;
        }

        if (!nft_add_rule(table, "mangle_output", [ "meta", "mark", mark_hex, "meta", "l4proto", "tcp", "counter", "queue", "num", queue_number, "bypass" ]) ||
            !nft_add_rule(table, "mangle_output", [ "meta", "mark", mark_hex, "meta", "l4proto", "udp", "counter", "queue", "num", queue_number, "bypass" ]))
            return false;
    }

    return true;
}

function nft_write_chunk(chunks, chunk) {
    if (length(chunk) > 0)
        push(chunks, "" + length(chunk) + "\t" + join(",", chunk));
}

function nft_push_chunk_value(chunks, chunk, value, chunk_size) {
    push(chunk, value);
    if (length(chunk) < chunk_size)
        return chunk;

    nft_write_chunk(chunks, chunk);
    return [];
}

function nft_invalid(invalid, value, message) {
    push(invalid, as_string(value) + "\t" + message);
}

function nft_trimmed_lines(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let result = [];
    for (let line in split(as_string(data), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        if (line != "")
            push(result, line);
    }

    return result;
}

function nft_chunk_size(value) {
    value = int(value || 5000);
    return value > 0 ? value : 5000;
}

function nft_csv_values(csv) {
    let result = [];

    for (let item in split(as_string(csv), ",")) {
        item = trim(replace(as_string(item), /\r/g, ""));
        if (item != "")
            push(result, item);
    }

    return result;
}

function nft_build_chunks_from_values(values, kind, ports_csv, chunk_size_text, family_filter) {
    let chunk_size = nft_chunk_size(chunk_size_text);
    let chunks = [];
    let invalid = [];
    let chunk = [];
    let ports = split(as_string(ports_csv), ",");
    family_filter = int(family_filter || 0);

    for (let line in values) {
        if (kind == "ports") {
            let port = normalize_port_condition_value(line);
            if (port == null) {
                nft_invalid(invalid, line, "is not a valid port or port range");
                continue;
            }
            chunk = nft_push_chunk_value(chunks, chunk, port, chunk_size);
            continue;
        }

        if (kind == "ip-ports") {
            let separator = index(line, " . ");
            let last_separator = rindex(line, " . ");
            if (separator < 0 || last_separator < 0) {
                nft_invalid(invalid, line, "is not an IP/CIDR and port nft tuple");
                continue;
            }

            let ip = substr(line, 0, separator);
            let port = substr(line, last_separator + 3);
            let original_port = port;
            if (!nft_ip_or_cidr(ip)) {
                nft_invalid(invalid, ip, "is not IP or CIDR");
                continue;
            }

            if (family_filter != 0 && core_ip.ip_family(ip) != family_filter)
                continue;

            port = normalize_port_condition_value(port);
            if (port == null) {
                nft_invalid(invalid, original_port, "is not a valid port or port range");
                continue;
            }

            chunk = nft_push_chunk_value(chunks, chunk, ip + " . " + port, chunk_size);
            continue;
        }

        if (!nft_ip_or_cidr(line)) {
            nft_invalid(invalid, line, "is not IP or CIDR");
            continue;
        }

        if (family_filter != 0 && core_ip.ip_family(line) != family_filter)
            continue;

        if (kind == "ip-port-from-ip") {
            for (let port in ports) {
                if (port == "")
                    continue;

                let normalized = normalize_port_condition_value(port);
                if (normalized == null) {
                    nft_invalid(invalid, port, "is not a valid port or port range");
                    continue;
                }

                chunk = nft_push_chunk_value(chunks, chunk, line + " . " + normalized, chunk_size);
            }
        }
        else if (kind == "ips") {
            chunk = nft_push_chunk_value(chunks, chunk, line, chunk_size);
        }
        else {
            exit(1);
        }
    }

    nft_write_chunk(chunks, chunk);

    return {
        chunks: chunks,
        invalid: invalid
    };
}

function nft_build_chunks(path, kind, ports_csv, chunk_size_text) {
    return nft_build_chunks_from_values(nft_trimmed_lines(path), kind, ports_csv, chunk_size_text, 0);
}

function nft_prepare_chunks(path, kind, ports_csv, chunk_size_text, chunks_path, invalid_path) {
    let prepared = nft_build_chunks(path, kind, ports_csv, chunk_size_text);

    if (!write_text_file(chunks_path, length(prepared.chunks) > 0 ? join("\n", prepared.chunks) + "\n" : ""))
        exit(1);
    if (!write_text_file(invalid_path, length(prepared.invalid) > 0 ? join("\n", prepared.invalid) + "\n" : ""))
        exit(1);
}

function nft_log_invalid_elements(invalid) {
    for (let item in invalid) {
        let separator = index(item, "\t");
        if (separator < 0)
            continue;

        let value = substr(item, 0, separator);
        let message = substr(item, separator + 1);
        if (value != "")
            log_debug("'" + value + "' " + message);
    }
}

function nft_add_chunks_to_set(table, set_name, chunks, invalid) {
    nft_log_invalid_elements(invalid);

    for (let item in chunks) {
        let separator = index(item, "\t");
        if (separator < 0)
            continue;

        let count = substr(item, 0, separator);
        let elements = substr(item, separator + 1);
        if (elements == "")
            continue;

        log_debug("Adding " + count + " elements to nft set " + set_name);
        if (!nft_add_set_elements(table, set_name, elements))
            return false;
    }

    return true;
}

function nft_add_file_chunks_to_set(path, table, set_name, kind, ports_csv, chunk_size_text, family_filter) {
    let prepared = nft_build_chunks_from_values(nft_trimmed_lines(path), kind, ports_csv, chunk_size_text, family_filter);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_csv_chunks_to_set(csv, table, set_name, kind, ports_csv, chunk_size_text, family_filter) {
    let prepared = nft_build_chunks_from_values(nft_csv_values(csv), kind, ports_csv, chunk_size_text, family_filter);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_file_chunks_to_family_sets(path, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_file_chunks_to_set(path, table, ipv4_set, kind, ports_csv, chunk_size_text, 4) &&
        nft_add_file_chunks_to_set(path, table, ipv6_set, kind, ports_csv, chunk_size_text, 6);
}

function nft_add_csv_chunks_to_family_sets(csv, table, ipv4_set, ipv6_set, kind, ports_csv, chunk_size_text) {
    return nft_add_csv_chunks_to_set(csv, table, ipv4_set, kind, ports_csv, chunk_size_text, 4) &&
        nft_add_csv_chunks_to_set(csv, table, ipv6_set, kind, ports_csv, chunk_size_text, 6);
}

function nft_add_inline_ip_cidr_matchers(csv, ports_csv, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    if (as_string(csv) == "")
        return true;

    if (as_string(ports_csv) != "")
        return nft_add_csv_chunks_to_family_sets(csv, table, ip_port_set, default_arg(ip_port6_set, "tachyon_ip6_ports"), "ip-port-from-ip", ports_csv, chunk_size_text);

    return nft_add_csv_chunks_to_family_sets(csv, table, common_set, default_arg(common6_set, "tachyon_subnets6"), "ips", "", chunk_size_text);
}

function nft_insert_fully_routed_ip_rules(source_ip, table, interface_set, localv4_set, localv6_set, mark) {
    let family = core_ip.ip_family(source_ip);
    let ip_key = family == 6 ? "ip6" : "ip";
    let local_set = family == 6 ? default_arg(localv6_set, "localv6") : localv4_set;

    if (family == 0)
        return true;

    return (
        run_args([ "nft", "insert", "rule", "inet", table, "mangle", "iifname", "@" + as_string(interface_set), ip_key, "saddr", source_ip, "meta", "l4proto", "tcp", "meta", "mark", "set", mark, "counter" ]) &&
        run_args([ "nft", "insert", "rule", "inet", table, "mangle", "iifname", "@" + as_string(interface_set), ip_key, "saddr", source_ip, "meta", "l4proto", "udp", "meta", "mark", "set", mark, "counter" ]) &&
        run_args([ "nft", "insert", "rule", "inet", table, "mangle", ip_key, "saddr", source_ip, ip_key, "daddr", "@" + as_string(local_set), "return" ])
    );
}

function nft_source_ip_display_value(source_ip) {
    source_ip = as_string(source_ip);
    let suffix = "/32";

    if (length(source_ip) > length(suffix) &&
        substr(source_ip, length(source_ip) - length(suffix), length(suffix)) == suffix) {
        let address = substr(source_ip, 0, length(source_ip) - length(suffix));
        if (valid_ipv4(address))
            return address;
    }

    suffix = "/128";
    if (length(source_ip) > length(suffix) &&
        substr(source_ip, length(source_ip) - length(suffix), length(suffix)) == suffix) {
        let address = substr(source_ip, 0, length(source_ip) - length(suffix));
        if (core_ip.valid_ipv6(address))
            return address;
    }

    return source_ip;
}

function nft_chain_has_source_ip(chain_text, source_ip) {
    chain_text = as_string(chain_text);
    source_ip = as_string(source_ip);

    let ip_key = core_ip.ip_family(source_ip) == 6 ? "ip6" : "ip";

    if (index(chain_text, ip_key + " saddr " + source_ip) >= 0)
        return true;

    let display_source_ip = nft_source_ip_display_value(source_ip);
    return display_source_ip != source_ip && index(chain_text, ip_key + " saddr " + display_source_ip) >= 0;
}

function nft_ensure_fully_routed_ip_rules_from_chain(source_ip, table, interface_set, localv4_set, localv6_set, mark, chain_text, inserted) {
    source_ip = as_string(source_ip);
    if (source_ip == "")
        return true;

    if (inserted[source_ip] || nft_chain_has_source_ip(chain_text, source_ip))
        return true;

    if (!nft_insert_fully_routed_ip_rules(source_ip, table, interface_set, localv4_set, localv6_set, mark))
        return false;

    inserted[source_ip] = true;
    return true;
}

function normalized_fields(line) {
    line = trim(replace(as_string(line), /\r/g, ""));
    line = replace(line, /[[:space:]]+/g, " ");
    return line == "" ? [] : split(line, " ");
}

function rule_line_has_lookup_table(fields, table) {
    table = as_string(table);

    for (let i = 0; i + 1 < length(fields); i++)
        if (fields[i] == "lookup" && fields[i + 1] == table)
            return true;

    return false;
}

function rule_line_has_fwmark(fields, expected_mark) {
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] != "fwmark")
            continue;

        let parts = split(fields[i + 1], "/");
        if (length(parts) != 2)
            continue;

        if (parse_mark_number(parts[0]) == expected_mark && parse_mark_number(parts[1]) == expected_mark)
            return true;
    }

    return false;
}

function has_tproxy_marking_rule_text(rule_list, table, mark) {
    let expected_mark = parse_mark_number(mark);
    let has_lookup = false;
    let has_fwmark = false;

    if (expected_mark == null)
        return false;

    for (let line in split(rule_list, "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) == 0)
            continue;

        if (!has_lookup && rule_line_has_lookup_table(fields, table))
            has_lookup = true;
        if (!has_fwmark && rule_line_has_fwmark(fields, expected_mark))
            has_fwmark = true;

        if (has_lookup && has_fwmark)
            return true;
    }

    return false;
}

function has_local_default_route_text(route_list, family) {
    family = int(family || 4);

    for (let line in split(as_string(route_list), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        line = replace(line, /[[:space:]]+/g, " ");
        if (family == 4 && index(line, "local default dev lo scope host") >= 0)
            return true;
        if (family == 6 && (index(line, "local ::") >= 0 || index(line, "local default") >= 0) && index(line, " dev lo") >= 0)
            return true;
    }

    return false;
}

function rt_table_has_entry(text, table_id, table_name) {
    table_id = as_string(table_id);
    table_name = as_string(table_name);

    for (let line in split(as_string(text), "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) >= 2 && fields[0] == table_id && fields[1] == table_name)
            return true;
    }

    return false;
}

function ensure_rt_table_entry(path, table_id, table_name) {
    let data = fs.readfile(path);
    if (data != null && rt_table_has_entry(data, table_id, table_name))
        return true;

    data = data == null ? "" : as_string(data);
    let out = [];
    for (let line in split(data, "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) >= 2 && fields[0] == as_string(table_id))
            continue;
        push(out, line);
    }
    
    while (length(out) > 0 && out[length(out) - 1] == "")
        pop(out);

    push(out, as_string(table_id) + " " + as_string(table_name));
    return write_text_file(path, join("\n", out) + "\n");
}

function tproxy_route4_present(table) {
    return has_local_default_route_text(command_output_quiet_from_args([ "ip", "route", "list", "table", table ]), 4);
}

function tproxy_route6_present(table) {
    return has_local_default_route_text(command_output_quiet_from_args([ "ip", "-6", "route", "list", "table", table ]), 6);
}

function tproxy_route_present(table) {
    return tproxy_route4_present(table) && tproxy_route6_present(table);
}

function tproxy_marking_rule4_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-4", "rule", "list" ]), table, mark);
}

function tproxy_marking_rule6_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-6", "rule", "list" ]), table, mark);
}

function tproxy_marking_rule_present(table, mark) {
    return tproxy_marking_rule4_present(table, mark) && tproxy_marking_rule6_present(table, mark);
}

function tproxy_route_rule_present(table, mark) {
    return tproxy_route_present(table) && tproxy_marking_rule_present(table, mark);
}

function ensure_tproxy_route_rule(table, mark, rt_tables_path) {
    rt_tables_path = as_string(rt_tables_path || "/etc/iproute2/rt_tables");

    if (!ensure_rt_table_entry(rt_tables_path, "105", table)) {
        log_fatal("Failed to update route table registry. Aborted.");
        return false;
    }

    if (!tproxy_route4_present(table)) {
        log_debug("Added IPv4 TPROXY route");
        if (!run_args([ "ip", "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", table ]) && !tproxy_route4_present(table)) {
            log_fatal("Failed to add IPv4 route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv4 TPROXY route already exists");
    }

    if (!tproxy_route6_present(table)) {
        log_debug("Added IPv6 TPROXY route");
        if (!run_args([ "ip", "-6", "route", "add", "local", "::/0", "dev", "lo", "table", table ]) && !tproxy_route6_present(table)) {
            log_fatal("Failed to add IPv6 route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv6 TPROXY route already exists");
    }

    if (!tproxy_marking_rule4_present(table, mark)) {
        log_debug("Creating IPv4 TPROXY marking rule");
        if (!run_args([ "ip", "-4", "rule", "add", "fwmark", as_string(mark) + "/" + as_string(mark), "table", table, "priority", "105" ]) && !tproxy_marking_rule4_present(table, mark)) {
            log_fatal("Failed to create IPv4 marking rule. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv4 TPROXY marking rule already exists");
    }

    if (!tproxy_marking_rule6_present(table, mark)) {
        log_debug("Creating IPv6 TPROXY marking rule");
        if (!run_args([ "ip", "-6", "rule", "add", "fwmark", as_string(mark) + "/" + as_string(mark), "table", table, "priority", "105" ]) && !tproxy_marking_rule6_present(table, mark)) {
            log_fatal("Failed to create IPv6 marking rule. Aborted.");
            return false;
        }
    }
    else {
        log_debug("IPv6 TPROXY marking rule already exists");
    }

    let fw4_forward_out = command_output_from_args([ "nft", "list", "chain", "inet", "fw4", "forward" ]);
    if (index(fw4_forward_out, "meta mark " + as_string(mark)) < 0) {
        run_args([ "nft", "insert", "rule", "inet", "fw4", "forward", "meta", "mark", as_string(mark), "return" ]);
    }

    let fw4_input_out = command_output_from_args([ "nft", "list", "chain", "inet", "fw4", "input" ]);
    if (index(fw4_input_out, "meta mark & " + as_string(mark)) < 0 && index(fw4_input_out, "meta mark " + as_string(mark)) < 0) {
        run_args([ "nft", "insert", "rule", "inet", "fw4", "input", "meta", "mark", "&", as_string(mark), "==", as_string(mark), "accept", "comment", "\"Allow Tachyon TPROXY marked traffic\"" ]);
    }

    let fw4_include_dir = "/usr/share/nftables.d/chain-pre/input";
    let fw4_include_file = fw4_include_dir + "/10-tachyon.nft";
    if (fs.stat("/usr/share/nftables.d") != null) {
        fs.mkdir("/usr/share/nftables.d/chain-pre");
        fs.mkdir(fw4_include_dir);
        write_text_file(fw4_include_file, sprintf("meta mark & %s == %s accept comment \"Allow Tachyon TPROXY marked traffic\"\n", as_string(mark), as_string(mark)));
    }
    return true;
}

function ensure_bridge_netfilter_disabled() {
    if (index(command_output_from_args([ "lsmod" ]), "br_netfilter") < 0)
        return true;

    if (trim(command_output_from_args([ "sysctl", "-n", "net.bridge.bridge-nf-call-iptables" ])) != "1")
        return true;

    log_debug("br_netfilter is enabled; disabling it for transparent proxy routing");
    return run_args([ "sysctl", "-w", "net.bridge.bridge-nf-call-iptables=0" ]) &&
        run_args([ "sysctl", "-w", "net.bridge.bridge-nf-call-ip6tables=0" ]);
}

// TCP keepalive: detect dead connections in ~90s instead of kernel default (hours).
// Conntrack: expire stale TCP entries in 10 min instead of 5 days.
// Buffers & TCP fastopen: accelerate QUIC/Hysteria2 and reduce TLS handshake RTT.
function apply_connection_tuning() {
    let sysctls = [
        [ "net.ipv4.tcp_keepalive_time", "60" ],
        [ "net.ipv4.tcp_keepalive_intvl", "10" ],
        [ "net.ipv4.tcp_keepalive_probes", "3" ],
        [ "net.ipv4.tcp_fastopen", "3" ],
        [ "net.netfilter.nf_conntrack_tcp_timeout_established", "600" ],
        [ "net.netfilter.nf_conntrack_tcp_timeout_time_wait", "30" ]
    ];
    let ok = true;
    for (let pair in sysctls) {
        let current = trim(command_output_from_args([ "sysctl", "-n", pair[0] ]) || "");
        if (current == pair[1]) continue;
        if (!run_args_quiet([ "sysctl", "-w", pair[0] + "=" + pair[1] ]))
            ok = false;
    }

    let ct_max = int(trim(command_output_from_args([ "sysctl", "-n", "net.netfilter.nf_conntrack_max" ]) || "0"));
    if (ct_max > 0 && ct_max < 65536)
        run_args_quiet([ "sysctl", "-w", "net.netfilter.nf_conntrack_max=65536" ]);

    let rmem_max = int(trim(command_output_from_args([ "sysctl", "-n", "net.core.rmem_max" ]) || "0"));
    if (rmem_max > 0 && rmem_max < 2621440)
        run_args_quiet([ "sysctl", "-w", "net.core.rmem_max=2621440" ]);

    let wmem_max = int(trim(command_output_from_args([ "sysctl", "-n", "net.core.wmem_max" ]) || "0"));
    if (wmem_max > 0 && wmem_max < 2621440)
        run_args_quiet([ "sysctl", "-w", "net.core.wmem_max=2621440" ]);

    if (ok)
        log_debug("Connection tuning applied: tcp_keepalive=60/10/3, tcp_fastopen=3, conntrack_established=600");
    return ok;
}

function community_service_has_subnet_list(value) {
    return rule_config.community_service_has_subnet_list(value);
}

function filter_community_subnet_lists_value(value) {
    return rule_config.filter_community_subnet_lists_value(value);
}

function signature_add_value(body, key, value) {
    return body + "[" + as_string(key) + "]\n" + as_string(value) + "\n";
}

function signature_hash(body) {
    let path = trim(command_output_from_args([ "mktemp", "/tmp/tachyon-XXXXXX" ]));
    if (path == "")
        return "";

    if (!write_text_file(path, body)) {
        unlink_file(path);
        return "";
    }

    let hash_line = command_output_from_args([ "md5sum", path ]);
    unlink_file(path);
    hash_line = trim(hash_line);

    return length(hash_line) >= 32 ? substr(hash_line, 0, 32) : "";
}

function nft_rule_signature_body(body, section) {
    let section_name = as_string(section[".name"]);

    if (section_name == "" || !bool_option(section, "enabled", true))
        return body;

    let action = option(section, "action", "");
    body = signature_add_value(body, "rule." + section_name + ".action", action);
    if (action == "dns" || action == "hosts")
        return body;
    body = signature_add_value(body, "rule." + section_name + ".ip_cidr", section_rule_condition_csv(section, "ip_cidr", "subnets"));
    body = signature_add_value(body, "rule." + section_name + ".source_ip_cidr", section_rule_condition_csv(section, "source_ip_cidr", "subnets"));
    body = signature_add_value(body, "rule." + section_name + ".ports", section_rule_ports_csv(section));
    body = signature_add_value(body, "rule." + section_name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
    body = signature_add_value(body, "rule." + section_name + ".excluded_ips", option(section, "excluded_ips", ""));
    body = signature_add_value(body, "rule." + section_name + ".excluded_protocol", option(section, "excluded_protocol", ""));
    body = signature_add_value(body, "rule." + section_name + ".protocol", option(section, "protocol", ""));
    body = signature_add_value(body, "rule." + section_name + ".community_subnet_lists", filter_community_subnet_lists_value(connections.community_lists_value(section)));
    body = signature_add_value(body, "rule." + section_name + ".remote_subnet_lists", option(section, "remote_subnet_lists", ""));
    body = signature_add_value(body, "rule." + section_name + ".rule_set_with_subnets", connections.rule_sets_with_subnets_value(section));
    body = signature_add_value(body, "rule." + section_name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));
    body = signature_add_value(body, "rule." + section_name + ".dscp", connections.dscp_value(section));

    return body;
}

function nft_schedule_signature_body(body, schedule) {
    let name = as_string(schedule[".name"]);
    body = signature_add_value(body, "schedule." + name + ".enabled", bool_option(schedule, "enabled", true) ? "1" : "0");
    body = signature_add_value(body, "schedule." + name + ".device_ip", option(schedule, "device_ip", ""));
    body = signature_add_value(body, "schedule." + name + ".profile", join(",", list_option(schedule, "profile")));
    body = signature_add_value(body, "schedule." + name + ".target", option(schedule, "target", "all"));
    body = signature_add_value(body, "schedule." + name + ".sections", join(",", list_option(schedule, "sections")));
    body = signature_add_value(body, "schedule." + name + ".action", option(schedule, "action", "block"));
    body = signature_add_value(body, "schedule." + name + ".start_time", option(schedule, "start_time", ""));
    body = signature_add_value(body, "schedule." + name + ".end_time", option(schedule, "end_time", ""));
    body = signature_add_value(body, "schedule." + name + ".days", join(",", list_option(schedule, "days")));
    body = signature_add_value(body, "schedule." + name + ".blocked_domains", join(",", list_option(schedule, "blocked_domains")));
    body = signature_add_value(body, "schedule." + name + ".mode", option(schedule, "mode", "block"));
    return body;
}

function nft_profile_signature_body(body, profile) {
    let name = as_string(profile[".name"]);
    body = signature_add_value(body, "profile." + name + ".enabled", bool_option(profile, "enabled", true) ? "1" : "0");
    body = signature_add_value(body, "profile." + name + ".device_ip", join(",", list_option(profile, "device_ip")));
    body = signature_add_value(body, "profile." + name + ".safe_search", option(profile, "safe_search", "0"));
    body = signature_add_value(body, "profile." + name + ".block_doh", option(profile, "block_doh", "0"));
    body = signature_add_value(body, "profile." + name + ".blocked_domains", join(",", list_option(profile, "blocked_domains")));
    body = signature_add_value(body, "profile." + name + ".daily_quota_minutes", option(profile, "daily_quota_minutes", "0"));
    return body;
}

function nft_runtime_signature_from_settings_and_sections(settings, sections, schedules, profiles) {
    let body = "";

    body = signature_add_value(body, "settings.source_network_interfaces", option(settings, "source_network_interfaces", "br-lan"));
    body = signature_add_value(body, "settings.exclude_ntp", bool_option(settings, "exclude_ntp", false) ? "1" : "0");
    body = signature_add_value(body, "settings.game_console_optimizer", option(settings, "game_console_optimizer", "0"));
    body = signature_add_value(body, "settings.game_console_ips", option(settings, "game_console_ips", ""));

    for (let section in sections)
        body = nft_rule_signature_body(body, object_or_empty(section));

    for (let profile in profiles)
        body = nft_profile_signature_body(body, object_or_empty(profile));

    for (let schedule in schedules)
        body = nft_schedule_signature_body(body, object_or_empty(schedule));

    return signature_hash(body);
}

function print_nft_runtime_signature_from_settings_and_sections(settings, sections, schedules, profiles) {
    let hash = nft_runtime_signature_from_settings_and_sections(settings, sections, schedules, profiles);
    if (hash == "")
        return false;

    print(hash, "\n");
    return true;
}

function word_set(value) {
    let result = {};
    for (let item in whitespace_values(value))
        result[item] = true;
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

function nft_create_provider_output_rules_from_uci(table, action, provider_bin, route_mark_base, queue_base, desync_mark, desync_mark_postnat) {
    return nft_create_provider_output_rules_from_sections(
        uci_sections("section"),
        table,
        action,
        provider_bin,
        route_mark_base,
        queue_base,
        desync_mark,
        desync_mark_postnat
    );
}

function nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    log_debug("Building nftables runtime model");

    return ensure_bridge_netfilter_disabled() &&
        apply_connection_tuning() &&
        ensure_tproxy_route_rule(rt_table, fakeip_mark) &&
        nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) &&
        nft_add_section_priority_rules_from_sections(uci_sections("section"), table, interface_set, localv4_set, localv6_set, fakeip_mark) &&
        nft_add_schedule_rules_from_uci(table, uci_sections("section")) &&
        nft_add_dns_block_rules_from_uci(table) &&
        nft_add_profile_doh_block_rules(uci_sections("profile"), table) &&
        nft_create_provider_output_rules_from_uci(table, "zapret", zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat) &&
        nft_create_provider_output_rules_from_uci(table, "zapret2", zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat) &&
        nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range, localv6_set, common6_set, ip_port6_set, fakeip6_range);
}

function nft_table_present(table) {
    return run_args_quiet([ "nft", "list", "table", "inet", table ]);
}

function nft_delete_table(table) {
    return run_args([ "nft", "delete", "table", "inet", table ]);
}

function nft_rebuild_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address) {
    log_debug("Applying nftables runtime rules");

    if (nft_table_present(table) && !nft_delete_table(table))
        return false;

    return nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat, localv6_set, common6_set, ip_port6_set, fakeip6_range, tproxy6_address);
}

function nft_runtime_signature_from_uci() {
    return print_nft_runtime_signature_from_settings_and_sections(
        uci_settings(),
        uci_sections("section"),
        uci_sections("schedule"),
        uci_sections("profile")
    );
}

function fixture_section(path, section_name) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return section_by_name(fixture_section_list(data, "section"), section_name);
}

function fixture_settings(data) {
    return object_or_empty(object_or_empty(data).settings);
}

function nft_runtime_signature_from_fixture(path) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return print_nft_runtime_signature_from_settings_and_sections(
        fixture_settings(data),
        fixture_section_list(data, "section"),
        fixture_section_list(data, "schedule"),
        fixture_section_list(data, "profile")
    );
}

function nft_mangle_chain_text(context, table) {
    if (context.text == null)
        context.text = command_output_from_args([ "nft", "list", "chain", "inet", table, "mangle" ]);
    return context.text;
}

function nft_add_section_source_matchers(section, table, chunk_size_text) {
    let source_values = section_source_ip_values(section);
    if (source_values == "")
        return true;

    let sets = section_priority_sets(section);
    return nft_add_csv_chunks_to_family_sets(source_values, table, sets.sources, sets.sources6, "ips", "", chunk_size_text);
}

function nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, mangle_chain_context, inserted_fully_routed_ips, common6_set, ip_port6_set, localv6_set) {
    if (!bool_option(section, "enabled", true))
        return true;
    if (section_action(section) == "dns" || section_action(section) == "hosts")
        return true;

    let ports = section_rule_ports_csv(section);
    let ip_values = section_rule_condition_csv(section, "ip_cidr", "subnets");
    let sets = section_priority_sets(section);

    if (section_needs_priority_sets(section) && !nft_add_section_source_matchers(section, table, 5000))
        return false;

    if (deferred_sections[as_string(section[".name"])])
        return true;

    if (section_needs_priority_sets(section)) {
        if (!nft_add_inline_ip_cidr_matchers(ip_values, ports, table, sets.subnets, sets.ip_ports, 5000, sets.subnets6, sets.ip6_ports))
            return false;

        if (ports != "" && !section_has_destination_matchers(section) &&
            !nft_add_set_elements(table, sets.ports, ports))
            return false;

        // Load cached community subnet files into nftables (populated at list-update and persisted)
        // Note: call nft_add_file_chunks_to_family_sets directly because ucode does not hoist
        // function declarations, and nft_add_subnet_file_for_section is defined below this function.
        for (let community in connections.community_lists(section)) {
            let service = as_string(community);
            let cached_paths = [
                "/tmp/sing-box/rulesets/community-subnets-" + service + ".lst",
                "/etc/tachyon/rulesets/community-subnets-" + service + ".lst"
            ];
            for (let path in cached_paths) {
                if (helpers.file_is_usable(path, 50)) {
                    nft_add_file_chunks_to_family_sets(path, table, sets.subnets, sets.subnets6, "ips", "", "5000");
                    break;
                }
            }
        }
    }

    for (let source_ip in list_option(section, "fully_routed_ips"))
        if (!nft_ensure_fully_routed_ip_rules_from_chain(source_ip, table, interface_set, localv4_set, localv6_set, mark, nft_mangle_chain_text(mangle_chain_context, table), inserted_fully_routed_ips))
            return false;

    return true;
}

function nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    if (!nft_create_priority_sets(table, sets))
        return false;

    if (ports != "")
        return nft_add_file_chunks_to_family_sets(filepath, table, sets.ip_ports, sets.ip6_ports, "ip-port-from-ip", ports, chunk_size_text);

    return nft_add_file_chunks_to_family_sets(filepath, table, sets.subnets, sets.subnets6, "ips", "", chunk_size_text);
}

function file_nonempty(path) {
    return helpers.file_is_usable(path, 0);
}

function nft_add_extracted_ruleset_subnets(unscoped_path, scoped_path, label, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    let has_entries = false;

    if (file_nonempty(unscoped_path)) {
        if (!nft_add_file_chunks_to_family_sets(unscoped_path, table, common_set, default_arg(common6_set, "tachyon_subnets6"), "ips", "", chunk_size_text))
            return false;
        has_entries = true;
    }

    if (file_nonempty(scoped_path)) {
        if (!nft_add_file_chunks_to_family_sets(scoped_path, table, ip_port_set, default_arg(ip_port6_set, "tachyon_ip6_ports"), "ip-ports", "", chunk_size_text))
            return false;
        has_entries = true;
    }

    if (!has_entries)
        log_warn(as_string(label) + " has no ip_cidr entries for nftables");

    return true;
}

function nft_add_json_ruleset_subnets_for_section(section, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    let ports = section_rule_ports_csv(section);
    let sets = section_priority_sets(section);

    if (!section_needs_priority_sets(section))
        return true;

    if (!nft_create_priority_sets(table, sets))
        return false;

    routing_rulesets.extract_ip_cidr_nft_elements(
        json_path,
        unscoped_path,
        scoped_path,
        sprintf("%J", rule_port_values(ports)),
        sprintf("%J", rule_port_ranges(ports))
    );

    return nft_add_extracted_ruleset_subnets(unscoped_path, scoped_path, label, table, sets.subnets, sets.ip_ports, chunk_size_text, sets.subnets6, sets.ip6_ports);
}

function nft_add_community_subnet_file_for_section(section, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    if (section_needs_priority_sets(section))
        return nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);

    return nft_add_file_chunks_to_family_sets(filepath, table, common_set, default_arg(common6_set, "tachyon_subnets6"), "ips", "", chunk_size_text);
}

function nft_add_subnet_file_for_uci_section(section_name, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_subnet_file_for_section(uci_section(section_name), filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_json_ruleset_subnets_for_uci_section(section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_json_ruleset_subnets_for_section(uci_section(section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_community_subnet_file_for_uci_section(section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    return nft_add_community_subnet_file_for_section(uci_section(section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set);
}

function nft_add_subnet_file_for_fixture_section(fixture_path, section_name, filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_subnet_file_for_section(fixture_section(fixture_path, section_name), filepath, table, common_set, ip_port_set, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_json_ruleset_subnets_for_fixture_section(fixture_path, section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set) {
    return nft_add_json_ruleset_subnets_for_section(fixture_section(fixture_path, section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text, common6_set, ip_port6_set);
}

function nft_add_community_subnet_file_for_fixture_section(fixture_path, section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set) {
    return nft_add_community_subnet_file_for_section(fixture_section(fixture_path, section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text, common6_set, ip_port6_set, discord6_set);
}

function nft_populate_runtime_sets_from_sections(sections, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    if (!arg_bool(populate_enabled))
        return true;

    let deferred_sections = word_set(deferred_section_names);
    let mangle_chain_context = {};
    let inserted_fully_routed_ips = {};

    for (let section in sections)
        if (!nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, mangle_chain_context, inserted_fully_routed_ips, common6_set, ip_port6_set, localv6_set))
            return false;

    return true;
}

function nft_populate_runtime_sets_from_uci(populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    if (!arg_bool(populate_enabled))
        return true;

    if (!nft_table_present(table)) {
        log_warn("nft_populate_runtime_sets_from_uci: Table " + table + " does not exist. Rebuilding firewall rules dynamically.");
                let rt_table = getenv("RT_TABLE_NAME") || "tachyon";
        let localv4 = default_arg(localv4_set, "localv4");
        let common = default_arg(common_set, "tachyon_subnets");
        let port = default_arg(port_set, "tachyon_ports");
        let ip_port = default_arg(ip_port_set, "tachyon_ip_ports");
        let iface = default_arg(interface_set, "tachyon_interfaces");
        let fmark = default_arg(mark, "0x04000000");
        let omark = "0x08000000";
        let frange4 = "198.18.0.0/15";
        let tport = "1602";
        let localv6 = default_arg(localv6_set, "localv6");
        let common6 = default_arg(common6_set, "tachyon_subnets6");
        let ip_port6 = default_arg(ip_port6_set, "tachyon_ip6_ports");
        let frange6 = "fc00::/18";
        let taddr6 = "[::1]:1602";
        nft_rebuild_runtime_from_uci(rt_table, table, localv4, common, port, ip_port, iface, fmark, omark, frange4, tport, "", "", "", "", "", "/opt/zapret2/bin/nfqws2", "0x02000000", "200", "0x00000002", "0x00000004", localv6, common6, ip_port6, frange6, taddr6);
    }

    return nft_populate_runtime_sets_from_sections(uci_sections("section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set);
}

function nft_populate_runtime_sets_fixture(path, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set) {
    let data = object_or_empty(common_read_json_file(path));
    connections.set_item_sections_from_data(data);
    return nft_populate_runtime_sets_from_sections(fixture_section_list(data, "section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, common6_set, ip_port6_set, localv6_set);
}

let mode = ARGV[0] || "";

if (mode == "text-list-to-csv")
    text_list_to_csv(ARGV[1], ARGV[2]);
else if (mode == "csv-to-json-array")
    csv_to_json_array(ARGV[1]);
else if (mode == "cache-path")
    cache_path(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "list-value-to-csv")
    list_value_csv(ARGV[1]);
else if (mode == "csv-list-contains")
    exit(csv_list_contains(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "domain-subnet-text-csv")
    domain_subnet_text_csv(ARGV[1], ARGV[2]);
else if (mode == "combined-domain-text-csv")
    combined_domain_text_csv(ARGV[1], ARGV[2]);
else if (mode == "combined-domain-csv")
    combined_domain_csv(ARGV[1], ARGV[2]);
else if (mode == "rule-condition-csv")
    rule_condition_csv(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]);
else if (mode == "legacy-condition-csv")
    legacy_condition_csv(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]);
else if (mode == "domain-subnet-file-csv")
    domain_subnet_file_csv(ARGV[1], ARGV[2]);
else if (mode == "split-domain-subnet-file")
    split_domain_subnet_file(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "normalize-port-condition-for-nft")
    normalize_port_condition_for_nft(ARGV[1]);
else if (mode == "rule-ports-csv")
    rule_ports_csv(ARGV[1], ARGV[2]);
else if (mode == "csv-to-lines-file")
    csv_to_lines_file(ARGV[1], ARGV[2]);
else if (mode == "nft-create-runtime-base")
    exit(nft_create_runtime_base(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17]) ? 0 : 1);
else if (mode == "nft-create-runtime-base-from-uci")
    exit(nft_create_runtime_base_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15]) ? 0 : 1);
else if (mode == "nft-create-runtime-output-rules")
    exit(nft_create_runtime_output_rules(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-create-provider-output-rules-from-uci")
    exit(nft_create_provider_output_rules_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]) ? 0 : 1);
else if (mode == "nft-create-provider-output-rules-fixture")
    exit(nft_create_provider_output_rules_from_sections(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-add-section-priority-rules-fixture")
    exit(nft_add_section_priority_rules_from_sections(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]) ? 0 : 1);
else if (mode == "nft-add-schedule-rules-fixture")
    exit(nft_add_schedule_rules_from_schedules(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "schedule"), fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "profile")) ? 0 : 1);
else if (mode == "nft-add-dns-block-rules-fixture")
    exit(nft_add_dns_block_rules_from_schedules(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "schedule"), ARGV[2], fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "profile")) ? 0 : 1);
else if (mode == "nft-create-full-runtime-from-uci")
    exit(nft_create_full_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17], ARGV[18], ARGV[19], ARGV[20], ARGV[21], ARGV[22], ARGV[23], ARGV[24], ARGV[25], ARGV[26]) ? 0 : 1);
else if (mode == "nft-rebuild-runtime-from-uci")
    exit(nft_rebuild_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17], ARGV[18], ARGV[19], ARGV[20], ARGV[21], ARGV[22], ARGV[23], ARGV[24], ARGV[25], ARGV[26]) ? 0 : 1);
else if (mode == "nft-prepare-chunks")
    nft_prepare_chunks(ARGV[1], ARGV[2], ARGV[3] || "", ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "nft-add-file-chunks-to-set")
    exit(nft_add_file_chunks_to_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-uci-section")
    exit(nft_add_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-uci-section")
    exit(nft_add_json_ruleset_subnets_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-uci-section")
    exit(nft_add_community_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-section-fixture")
    exit(nft_add_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-section-fixture")
    exit(nft_add_json_ruleset_subnets_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-section-fixture")
    exit(nft_add_community_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-from-uci")
    exit(nft_populate_runtime_sets_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-fixture")
    exit(nft_populate_runtime_sets_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13]) ? 0 : 1);
else if (mode == "nft-runtime-signature")
    exit(nft_runtime_signature_from_uci() ? 0 : 1);
else if (mode == "nft-runtime-signature-fixture")
    exit(nft_runtime_signature_from_fixture(ARGV[1]) ? 0 : 1);
else if (mode == "nft-table-present-fixture")
    exit(nft_table_present(ARGV[1]) ? 0 : 1);
else if (mode == "ensure-tproxy-route-rule")
    exit(ensure_tproxy_route_rule(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "tproxy-route-present")
    exit(tproxy_route_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-route4-present")
    exit(tproxy_route4_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-route6-present")
    exit(tproxy_route6_present(ARGV[1]) ? 0 : 1);
else if (mode == "tproxy-marking-rule-present")
    exit(tproxy_marking_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-marking-rule4-present")
    exit(tproxy_marking_rule4_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-marking-rule6-present")
    exit(tproxy_marking_rule6_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-route-rule-present")
    exit(tproxy_route_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "ensure-bridge-netfilter-disabled")
    exit(ensure_bridge_netfilter_disabled() ? 0 : 1);
else {
    warn("Usage: nft/apply.uc <operation> ...\n");
    exit(1);
}