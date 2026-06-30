#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let rule_config = require("config.rule");
let routing_rulesets = require("routing.rulesets");
const CONFIG_NAME = getenv("PODKOP_CONFIG_NAME") || "podkop-plus";

let common_read_json_file = common.read_json_file;
let list_option = common.list_option;
let bool_option = common.bool_option;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes";
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
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

function uci_section(section_name) {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, section_name));
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_settings() {
    return uci_section("settings");
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
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

function unlink_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];

    for (let arg in args)
        push(parts, shell_quote(arg));

    return join(" ", parts);
}

function run_args(args) {
    return system(command_from_args(args)) == 0;
}

function run_args_quiet(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";

    return as_string(data);
}

function log_debug(message) {
    run_args([ "logger", "-t", "podkop-plus", "[debug] " + as_string(message) ]);
}

function log_fatal(message) {
    run_args([ "logger", "-t", "podkop-plus", "[fatal] " + as_string(message) ]);
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
    value = as_string(value);
    if (match(value, /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) == null)
        return false;

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (part == "" || match(part, /^[0-9]+$/) == null)
            return false;
        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function valid_ipv4_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash < 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let address = substr(value, 0, slash);
    let prefix = substr(value, slash + 1);
    if (prefix == "" || match(prefix, /^[0-9]+$/) == null)
        return false;

    prefix = int(prefix);
    return valid_ipv4(address) && prefix >= 0 && prefix <= 32;
}

function valid_domain_suffix(value) {
    value = ascii_lower(value);
    if (substr(value, 0, 1) == ".")
        value = substr(value, 1);

    return match(value, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/) != null;
}

function decimal_without_leading_zero(value) {
    value = as_string(value);
    return value != "" && match(value, /^[0-9]+$/) != null && (length(value) == 1 || substr(value, 0, 1) != "0");
}

function nft_ipv4(value, allow_trailing_dot) {
    value = as_string(value);
    if (allow_trailing_dot && length(value) > 0 && substr(value, length(value) - 1, 1) == ".")
        value = substr(value, 0, length(value) - 1);

    let parts = split(value, ".");
    if (length(parts) != 4)
        return false;

    for (let part in parts) {
        if (!decimal_without_leading_zero(part))
            return false;

        let octet = int(part);
        if (octet < 0 || octet > 255)
            return false;
    }

    return true;
}

function nft_ipv4_cidr(value) {
    value = as_string(value);
    let slash = index(value, "/");
    if (slash <= 0 || index(substr(value, slash + 1), "/") >= 0)
        return false;

    let prefix = substr(value, slash + 1);
    if (!decimal_without_leading_zero(prefix))
        return false;

    let prefix_number = int(prefix);
    return nft_ipv4(substr(value, 0, slash), false) && prefix_number >= 0 && prefix_number <= 32;
}

function nft_ip_or_cidr(value) {
    return nft_ipv4(value, true) || nft_ipv4_cidr(value);
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

function domain_subnet_value_valid(value, kind) {
    kind = as_string(kind);
    if (kind == "domains")
        return valid_domain_suffix(value);
    if (kind == "subnets")
        return valid_ipv4(value) || valid_ipv4_cidr(value);

    exit(1);
}

function normalize_domain_subnet_value(value, kind) {
    kind = as_string(kind);
    if (kind == "domains") {
        let normalized = ascii_lower(value);
        return valid_domain_suffix(normalized) ? normalized : null;
    }
    if (kind == "subnets")
        return valid_ipv4(value) || valid_ipv4_cidr(value) ? value : null;

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
        else if (valid_ipv4(value) || valid_ipv4_cidr(value))
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

function nft_create_inet_service_set(table, name) {
    return nft_create_set(table, name, "{ type inet_service; flags interval; auto-merge; }");
}

function nft_create_ipv4_port_set(table, name) {
    return nft_create_set(table, name, "{ type ipv4_addr . inet_service; flags interval; auto-merge; }");
}

function nft_create_ifname_set(table, name) {
    return nft_create_set(table, name, "{ type ifname; flags interval; }");
}

function nft_add_set_elements(table, set_name, elements) {
    return run_args([ "nft", "add", "element", "inet", table, set_name, "{ " + as_string(elements) + " }" ]);
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

function nft_create_runtime_base(table, localv4_set, common_set, port_set, ip_port_set, interface_set, source_interfaces, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, exclude_ntp) {
    if (!nft_create_table(table) ||
        !nft_create_ipv4_set(table, localv4_set) ||
        !nft_add_set_elements(table, localv4_set, join(",", LOCALV4_RANGES)) ||
        !nft_create_ipv4_set(table, common_set) ||
        !nft_create_inet_service_set(table, port_set) ||
        !nft_create_ipv4_port_set(table, ip_port_set) ||
        !nft_create_ifname_set(table, interface_set))
        return false;

    for (let interface in whitespace_values(source_interfaces))
        if (!nft_add_set_elements(table, interface_set, interface))
            return false;

    if (!nft_create_chain(table, "mangle", "{ type filter hook prerouting priority -150; policy accept; }") ||
        !nft_create_chain(table, "mangle_output", "{ type route hook output priority -150; policy accept; }") ||
        !nft_create_chain(table, "proxy", "{ type filter hook prerouting priority -100; policy accept; }"))
        return false;

    if (!nft_add_rule(table, "mangle", [ "ct", "status", "dnat", "return" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", ".", "tcp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", ".", "udp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "!=", "@" + as_string(localv4_set), "tcp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", "!=", "@" + as_string(localv4_set), "udp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "mangle", [ "iifname", "@" + as_string(interface_set), "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "tcp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "proxy", [ "meta", "mark", "&", fakeip_mark, "==", fakeip_mark, "meta", "l4proto", "udp", "tproxy", "ip", "to", ":" + as_string(tproxy_port), "counter" ]) ||
        !nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(localv4_set), "return" ]) ||
        !nft_add_rule(table, "mangle_output", [ "meta", "mark", outbound_mark, "counter", "return" ]))
        return false;

    if (arg_bool(exclude_ntp) && !nft_insert_rule(table, "mangle", [ "udp", "dport", "123", "return" ]))
        return false;

    return true;
}

function nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port) {
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
        option(settings, "exclude_ntp", "0")
    );
}

function nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range) {
    return (
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", "@" + as_string(common_set), "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", ".", "tcp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", ".", "udp", "dport", "@" + as_string(ip_port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "tcp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "udp", "dport", "@" + as_string(port_set), "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "tcp", "meta", "mark", "set", fakeip_mark, "counter" ]) &&
        nft_add_rule(table, "mangle_output", [ "ip", "daddr", fakeip_range, "meta", "l4proto", "udp", "meta", "mark", "set", fakeip_mark, "counter" ])
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

function str_last_index(value, needle) {
    value = as_string(value);
    needle = as_string(needle);
    let result = -1;
    let start = 0;

    while (true) {
        let offset = index(substr(value, start), needle);
        if (offset < 0)
            return result;

        result = start + offset;
        start = result + length(needle);
    }
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

function nft_build_chunks_from_values(values, kind, ports_csv, chunk_size_text) {
    let chunk_size = nft_chunk_size(chunk_size_text);
    let chunks = [];
    let invalid = [];
    let chunk = [];
    let ports = split(as_string(ports_csv), ",");

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
            let last_separator = str_last_index(line, " . ");
            if (separator < 0 || last_separator < 0) {
                nft_invalid(invalid, line, "is not an IPv4/CIDR and port nft tuple");
                continue;
            }

            let ip = substr(line, 0, separator);
            let port = substr(line, last_separator + 3);
            let original_port = port;
            if (!nft_ip_or_cidr(ip)) {
                nft_invalid(invalid, ip, "is not IPv4 or IPv4 CIDR");
                continue;
            }

            port = normalize_port_condition_value(port);
            if (port == null) {
                nft_invalid(invalid, original_port, "is not a valid port or port range");
                continue;
            }

            chunk = nft_push_chunk_value(chunks, chunk, ip + " . " + port, chunk_size);
            continue;
        }

        if (!nft_ip_or_cidr(line)) {
            nft_invalid(invalid, line, "is not IPv4 or IPv4 CIDR");
            continue;
        }

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
    return nft_build_chunks_from_values(nft_trimmed_lines(path), kind, ports_csv, chunk_size_text);
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

function nft_add_file_chunks_to_set(path, table, set_name, kind, ports_csv, chunk_size_text) {
    let prepared = nft_build_chunks(path, kind, ports_csv, chunk_size_text);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_csv_chunks_to_set(csv, table, set_name, kind, ports_csv, chunk_size_text) {
    let prepared = nft_build_chunks_from_values(nft_csv_values(csv), kind, ports_csv, chunk_size_text);
    return nft_add_chunks_to_set(table, set_name, prepared.chunks, prepared.invalid);
}

function nft_add_inline_ip_cidr_matchers(csv, ports_csv, table, common_set, ip_port_set, chunk_size_text) {
    if (as_string(csv) == "")
        return true;

    if (as_string(ports_csv) != "")
        return nft_add_csv_chunks_to_set(csv, table, ip_port_set, "ip-port-from-ip", ports_csv, chunk_size_text);

    return nft_add_csv_chunks_to_set(csv, table, common_set, "ips", "", chunk_size_text);
}

function nft_insert_fully_routed_ip_rules(source_ip, table, interface_set, localv4_set, mark) {
    return (
        run_args([ "nft", "insert", "rule", "inet", table, "mangle", "iifname", "@" + as_string(interface_set), "ip", "saddr", source_ip, "meta", "l4proto", "tcp", "meta", "mark", "set", mark, "counter" ]) &&
        run_args([ "nft", "insert", "rule", "inet", table, "mangle", "iifname", "@" + as_string(interface_set), "ip", "saddr", source_ip, "meta", "l4proto", "udp", "meta", "mark", "set", mark, "counter" ]) &&
        run_args([ "nft", "insert", "rule", "inet", table, "mangle", "ip", "saddr", source_ip, "ip", "daddr", "@" + as_string(localv4_set), "return" ])
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

    return source_ip;
}

function nft_chain_has_source_ip(chain_text, source_ip) {
    chain_text = as_string(chain_text);
    source_ip = as_string(source_ip);

    if (index(chain_text, "ip saddr " + source_ip) >= 0)
        return true;

    let display_source_ip = nft_source_ip_display_value(source_ip);
    return display_source_ip != source_ip && index(chain_text, "ip saddr " + display_source_ip) >= 0;
}

function nft_ensure_fully_routed_ip_rules_from_chain(source_ip, table, interface_set, localv4_set, mark, chain_text, inserted) {
    source_ip = as_string(source_ip);
    if (source_ip == "")
        return true;

    if (inserted[source_ip] || nft_chain_has_source_ip(chain_text, source_ip))
        return true;

    if (!nft_insert_fully_routed_ip_rules(source_ip, table, interface_set, localv4_set, mark))
        return false;

    inserted[source_ip] = true;
    return true;
}

function nft_ensure_fully_routed_ip_rules(source_ip, table, interface_set, localv4_set, mark) {
    return nft_ensure_fully_routed_ip_rules_from_chain(source_ip, table, interface_set, localv4_set, mark, read_stdin(), {});
}

function nft_ensure_discord_udp_fakeip_rule_from_chain(table, interface_set, discord_set, mark, chain_text) {
    if (!nft_create_ipv4_set(table, discord_set))
        return false;

    let needle = "iifname @" + as_string(interface_set) + " ip daddr @" + as_string(discord_set) + " udp dport { 19000-20000, 50000-65535 } meta mark set " + as_string(mark);
    if (index(as_string(chain_text), needle) >= 0)
        return true;

    return run_args([ "nft", "add", "rule", "inet", table, "mangle", "iifname", "@" + as_string(interface_set), "ip", "daddr", "@" + as_string(discord_set), "udp", "dport", "{ 19000-20000, 50000-65535 }", "meta", "mark", "set", mark, "counter" ]);
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

function has_local_default_route_text(route_list) {
    for (let line in split(as_string(route_list), "\n")) {
        line = trim(replace(as_string(line), /\r/g, ""));
        line = replace(line, /[[:space:]]+/g, " ");
        if (index(line, "local default dev lo scope host") >= 0)
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
    if (data != "" && substr(data, length(data) - 1, 1) != "\n")
        data += "\n";

    return write_text_file(path, data + as_string(table_id) + " " + as_string(table_name) + "\n");
}

function tproxy_route_present(table) {
    return has_local_default_route_text(command_output_from_args([ "ip", "route", "list", "table", table ]));
}

function tproxy_marking_rule_present(table, mark) {
    return has_tproxy_marking_rule_text(command_output_from_args([ "ip", "-4", "rule", "list" ]), table, mark);
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

    if (!tproxy_route_present(table)) {
        log_debug("Added route for tproxy");
        if (!run_args([ "ip", "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", table ]) && !tproxy_route_present(table)) {
            log_fatal("Failed to add route for tproxy. Aborted.");
            return false;
        }
    }
    else {
        log_debug("Route for tproxy exists");
    }

    if (!tproxy_marking_rule_present(table, mark)) {
        log_debug("Create marking rule");
        if (!run_args([ "ip", "-4", "rule", "add", "fwmark", as_string(mark) + "/" + as_string(mark), "table", table, "priority", "105" ]) && !tproxy_marking_rule_present(table, mark)) {
            log_fatal("Failed to create marking rule. Aborted.");
            return false;
        }
    }
    else {
        log_debug("Marking rule exist");
    }

    return true;
}

function ensure_bridge_netfilter_disabled() {
    if (index(command_output_from_args([ "lsmod" ]), "br_netfilter") < 0)
        return true;

    if (trim(command_output_from_args([ "sysctl", "-n", "net.bridge.bridge-nf-call-iptables" ])) != "1")
        return true;

    log_debug("br_netfilter enabled detected. Disabling");
    return run_args([ "sysctl", "-w", "net.bridge.bridge-nf-call-iptables=0" ]) &&
        run_args([ "sysctl", "-w", "net.bridge.bridge-nf-call-ip6tables=0" ]);
}

function section_rule_condition_csv(section, key, kind) {
    return rule_condition_csv_value(
        key,
        kind,
        option(section, key + "_text_mode", "0"),
        option(section, "conditions_text_mode", "0"),
        option(section, key + "_text", ""),
        option(section, key, ""),
        option(section, "domain_suffix_text", ""),
        option(section, "domain_suffix", "")
    );
}

function section_rule_ports_csv(section) {
    return rule_ports_csv_value(option(section, "ports", ""), option(section, "ports_text", ""));
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
    let path = trim(command_output_from_args([ "mktemp" ]));
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

    body = signature_add_value(body, "rule." + section_name + ".ip_cidr", section_rule_condition_csv(section, "ip_cidr", "subnets"));
    body = signature_add_value(body, "rule." + section_name + ".ports", section_rule_ports_csv(section));
    body = signature_add_value(body, "rule." + section_name + ".fully_routed_ips", option(section, "fully_routed_ips", ""));
    body = signature_add_value(body, "rule." + section_name + ".community_subnet_lists", filter_community_subnet_lists_value(option(section, "community_lists", "")));
    body = signature_add_value(body, "rule." + section_name + ".remote_subnet_lists", option(section, "remote_subnet_lists", ""));
    body = signature_add_value(body, "rule." + section_name + ".rule_set_with_subnets", option(section, "rule_set_with_subnets", ""));
    body = signature_add_value(body, "rule." + section_name + ".domain_ip_lists", option(section, "domain_ip_lists", ""));

    return body;
}

function nft_runtime_signature_from_settings_and_sections(settings, sections) {
    let body = "";

    body = signature_add_value(body, "settings.source_network_interfaces", option(settings, "source_network_interfaces", "br-lan"));
    body = signature_add_value(body, "settings.exclude_ntp", bool_option(settings, "exclude_ntp", false) ? "1" : "0");

    for (let section in sections)
        body = nft_rule_signature_body(body, object_or_empty(section));

    return signature_hash(body);
}

function print_nft_runtime_signature_from_settings_and_sections(settings, sections) {
    let hash = nft_runtime_signature_from_settings_and_sections(settings, sections);
    if (hash == "")
        return false;

    print(hash, "\n");
    return true;
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
        section_option_nonempty(section, "community_lists") ||
        section_option_nonempty(section, "rule_set") ||
        section_option_nonempty(section, "rule_set_with_subnets") ||
        section_option_nonempty(section, "domain_ip_lists");
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

function section_by_name(sections, section_name) {
    section_name = as_string(section_name);
    for (let section in sections)
        if (as_string(section[".name"]) == section_name)
            return section;
    return null;
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

function nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat) {
    log_debug("Create nft runtime model");

    return ensure_tproxy_route_rule(rt_table, fakeip_mark) &&
        nft_create_runtime_base_from_uci(table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port) &&
        nft_create_provider_output_rules_from_uci(table, "zapret", zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat) &&
        nft_create_provider_output_rules_from_uci(table, "zapret2", zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat) &&
        nft_create_runtime_output_rules(table, localv4_set, common_set, port_set, ip_port_set, fakeip_mark, fakeip_range);
}

function nft_table_present(table) {
    return run_args_quiet([ "nft", "list", "table", "inet", table ]);
}

function nft_delete_table(table) {
    return run_args([ "nft", "delete", "table", "inet", table ]);
}

function nft_rebuild_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat) {
    log_debug("Rebuilding nft runtime");

    if (nft_table_present(table) && !nft_delete_table(table))
        return false;

    return nft_create_full_runtime_from_uci(rt_table, table, localv4_set, common_set, port_set, ip_port_set, interface_set, fakeip_mark, outbound_mark, fakeip_range, tproxy_port, zapret_bin, zapret_route_mark_base, zapret_queue_base, zapret_desync_mark, zapret_desync_mark_postnat, zapret2_bin, zapret2_route_mark_base, zapret2_queue_base, zapret2_desync_mark, zapret2_desync_mark_postnat);
}

function nft_runtime_signature_from_uci() {
    return print_nft_runtime_signature_from_settings_and_sections(
        uci_settings(),
        uci_sections("section")
    );
}

function fixture_section(path, section_name) {
    return section_by_name(fixture_section_list(object_or_empty(common_read_json_file(path)), "section"), section_name);
}

function fixture_settings(data) {
    return object_or_empty(object_or_empty(data).settings);
}

function nft_runtime_signature_from_fixture(path) {
    let data = object_or_empty(common_read_json_file(path));
    return print_nft_runtime_signature_from_settings_and_sections(fixture_settings(data), fixture_section_list(data, "section"));
}

function nft_mangle_chain_text(context, table) {
    if (context.text == null)
        context.text = command_output_from_args([ "nft", "list", "chain", "inet", table, "mangle" ]);
    return context.text;
}

function nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, mangle_chain_context, inserted_fully_routed_ips) {
    if (!bool_option(section, "enabled", true))
        return true;

    if (deferred_sections[as_string(section[".name"])])
        return true;

    let ports = section_rule_ports_csv(section);
    let ip_values = section_rule_condition_csv(section, "ip_cidr", "subnets");

    if (!nft_add_inline_ip_cidr_matchers(ip_values, ports, table, common_set, ip_port_set, 5000))
        return false;

    if (ports != "" && !section_has_destination_matchers(section) &&
        !nft_add_set_elements(table, port_set, ports))
        return false;

    for (let source_ip in list_option(section, "fully_routed_ips"))
        if (!nft_ensure_fully_routed_ip_rules_from_chain(source_ip, table, interface_set, localv4_set, mark, nft_mangle_chain_text(mangle_chain_context, table), inserted_fully_routed_ips))
            return false;

    return true;
}

function nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text) {
    let ports = section_rule_ports_csv(section);

    if (ports != "")
        return nft_add_file_chunks_to_set(filepath, table, ip_port_set, "ip-port-from-ip", ports, chunk_size_text);

    return nft_add_file_chunks_to_set(filepath, table, common_set, "ips", "", chunk_size_text);
}

function file_nonempty(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && int(stat.size) > 0;
}

function nft_add_extracted_ruleset_subnets(unscoped_path, scoped_path, label, table, common_set, ip_port_set, chunk_size_text) {
    let has_entries = false;

    if (file_nonempty(unscoped_path)) {
        if (!nft_add_file_chunks_to_set(unscoped_path, table, common_set, "ips", "", chunk_size_text))
            return false;
        has_entries = true;
    }

    if (file_nonempty(scoped_path)) {
        if (!nft_add_file_chunks_to_set(scoped_path, table, ip_port_set, "ip-ports", "", chunk_size_text))
            return false;
        has_entries = true;
    }

    if (!has_entries)
        run_args([ "logger", "-t", "podkop-plus", "[warn] " + as_string(label) + " has no ip_cidr entries for nftables" ]);

    return true;
}

function nft_add_json_ruleset_subnets_for_section(section, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text) {
    let ports = section_rule_ports_csv(section);

    routing_rulesets.extract_ip_cidr_nft_elements(
        json_path,
        unscoped_path,
        scoped_path,
        sprintf("%J", rule_port_values(ports)),
        sprintf("%J", rule_port_ranges(ports))
    );

    return nft_add_extracted_ruleset_subnets(unscoped_path, scoped_path, label, table, common_set, ip_port_set, chunk_size_text);
}

function nft_add_community_subnet_file_for_section(section, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text) {
    let ports = section_rule_ports_csv(section);

    if (as_string(service) == "discord" && ports == "") {
        if (!nft_ensure_discord_udp_fakeip_rule_from_chain(table, interface_set, discord_set, mark, command_output_from_args([ "nft", "list", "chain", "inet", table, "mangle" ])))
            return false;
        return nft_add_file_chunks_to_set(filepath, table, discord_set, "ips", "", chunk_size_text);
    }

    return nft_add_subnet_file_for_section(section, filepath, table, common_set, ip_port_set, chunk_size_text);
}

function nft_add_subnet_file_for_uci_section(section_name, filepath, table, common_set, ip_port_set, chunk_size_text) {
    return nft_add_subnet_file_for_section(uci_section(section_name), filepath, table, common_set, ip_port_set, chunk_size_text);
}

function nft_add_json_ruleset_subnets_for_uci_section(section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text) {
    return nft_add_json_ruleset_subnets_for_section(uci_section(section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text);
}

function nft_add_community_subnet_file_for_uci_section(section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text) {
    return nft_add_community_subnet_file_for_section(uci_section(section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text);
}

function nft_add_subnet_file_for_fixture_section(fixture_path, section_name, filepath, table, common_set, ip_port_set, chunk_size_text) {
    return nft_add_subnet_file_for_section(fixture_section(fixture_path, section_name), filepath, table, common_set, ip_port_set, chunk_size_text);
}

function nft_add_json_ruleset_subnets_for_fixture_section(fixture_path, section_name, json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text) {
    return nft_add_json_ruleset_subnets_for_section(fixture_section(fixture_path, section_name), json_path, label, table, common_set, ip_port_set, unscoped_path, scoped_path, chunk_size_text);
}

function nft_add_community_subnet_file_for_fixture_section(fixture_path, section_name, service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text) {
    return nft_add_community_subnet_file_for_section(fixture_section(fixture_path, section_name), service, filepath, table, common_set, ip_port_set, interface_set, discord_set, mark, chunk_size_text);
}

function nft_populate_runtime_sets_from_sections(sections, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark) {
    if (!arg_bool(populate_enabled))
        return true;

    let deferred_sections = word_set(deferred_section_names);
    let mangle_chain_context = {};
    let inserted_fully_routed_ips = {};

    for (let section in sections)
        if (!nft_populate_runtime_set_for_section(section, deferred_sections, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark, mangle_chain_context, inserted_fully_routed_ips))
            return false;

    return true;
}

function nft_populate_runtime_sets_from_uci(populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark) {
    if (!arg_bool(populate_enabled))
        return true;

    return nft_populate_runtime_sets_from_sections(uci_sections("section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark);
}

function nft_populate_runtime_sets_fixture(path, populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark) {
    let data = object_or_empty(common_read_json_file(path));
    return nft_populate_runtime_sets_from_sections(fixture_section_list(data, "section"), populate_enabled, deferred_section_names, table, common_set, port_set, ip_port_set, interface_set, localv4_set, mark);
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
    exit(nft_create_runtime_base(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12]) ? 0 : 1);
else if (mode == "nft-create-runtime-base-from-uci")
    exit(nft_create_runtime_base_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10]) ? 0 : 1);
else if (mode == "nft-create-runtime-output-rules")
    exit(nft_create_runtime_output_rules(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]) ? 0 : 1);
else if (mode == "nft-create-provider-output-rules-from-uci")
    exit(nft_create_provider_output_rules_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]) ? 0 : 1);
else if (mode == "nft-create-provider-output-rules-fixture")
    exit(nft_create_provider_output_rules_from_sections(fixture_section_list(object_or_empty(common_read_json_file(ARGV[1])), "section"), ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8]) ? 0 : 1);
else if (mode == "nft-create-full-runtime-from-uci")
    exit(nft_create_full_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17], ARGV[18], ARGV[19], ARGV[20], ARGV[21]) ? 0 : 1);
else if (mode == "nft-rebuild-runtime-from-uci")
    exit(nft_rebuild_runtime_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11], ARGV[12], ARGV[13], ARGV[14], ARGV[15], ARGV[16], ARGV[17], ARGV[18], ARGV[19], ARGV[20], ARGV[21]) ? 0 : 1);
else if (mode == "nft-prepare-chunks")
    nft_prepare_chunks(ARGV[1], ARGV[2], ARGV[3] || "", ARGV[4], ARGV[5], ARGV[6]);
else if (mode == "nft-add-file-chunks-to-set")
    exit(nft_add_file_chunks_to_set(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5] || "", ARGV[6]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-uci-section")
    exit(nft_add_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-uci-section")
    exit(nft_add_json_ruleset_subnets_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-uci-section")
    exit(nft_add_community_subnet_file_for_uci_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10]) ? 0 : 1);
else if (mode == "nft-add-subnet-file-for-section-fixture")
    exit(nft_add_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7]) ? 0 : 1);
else if (mode == "nft-add-json-ruleset-subnets-for-section-fixture")
    exit(nft_add_json_ruleset_subnets_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10]) ? 0 : 1);
else if (mode == "nft-add-community-subnet-file-for-section-fixture")
    exit(nft_add_community_subnet_file_for_fixture_section(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10], ARGV[11]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-from-uci")
    exit(nft_populate_runtime_sets_from_uci(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9]) ? 0 : 1);
else if (mode == "nft-populate-runtime-sets-fixture")
    exit(nft_populate_runtime_sets_fixture(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10]) ? 0 : 1);
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
else if (mode == "tproxy-marking-rule-present")
    exit(tproxy_marking_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "tproxy-route-rule-present")
    exit(tproxy_route_rule_present(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "ensure-bridge-netfilter-disabled")
    exit(ensure_bridge_netfilter_disabled() ? 0 : 1);
else {
    warn("Usage: nft/apply.uc <operation> ...\n");
    exit(1);
}
