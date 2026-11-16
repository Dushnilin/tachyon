#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let read_stdin = common.read_stdin;
let read_json_file = common.read_json_file;
let array_or_empty = common.array_or_empty;
let write_json = common.write_json;

function int_arg(value) {
    value = as_string(value);
    return value == "" ? 0 : int(value, 10);
}

function first_field(line) {
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function stdin_first_nonempty_field() {
    for (let line in split(read_stdin(), "\n")) {
        let field = first_field(line);
        if (field != "") {
            print(field, "\n");
            return;
        }
    }
}

function stdin_first_line_version_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;

    if (match(line, /^.*version[ \t]*/) == null)
        return;

    let field = first_field(replace(line, /^.*version[ \t]*/, ""));
    if (field != "")
        print(field, "\n");
}

function has_socks_outbound(config_path, tag, address, port) {
    let config = read_json_file(config_path);
    port = int_arg(port);
    for (let outbound in array_or_empty(config && config.outbounds)) {
        if (type(outbound) == "object" &&
            outbound.type == "socks" &&
            outbound.tag == tag &&
            outbound.server == address &&
            int(outbound.server_port || 0) == port)
            return true;
    }
    return false;
}

function has_direct_mark_outbound(config_path, tag, routing_mark) {
    let config = read_json_file(config_path);
    routing_mark = int_arg(routing_mark);
    for (let outbound in array_or_empty(config && config.outbounds)) {
        if (type(outbound) == "object" &&
            outbound.type == "direct" &&
            outbound.tag == tag &&
            int(outbound.routing_mark || 0) == routing_mark)
            return true;
    }
    return false;
}

function has_route_rule(config_path, inbound, outbound_tag) {
    let config = read_json_file(config_path);
    for (let rule in array_or_empty(config && config.route && config.route.rules)) {
        if (type(rule) == "object" &&
            rule.action == "route" &&
            rule.inbound == inbound &&
            rule.outbound == outbound_tag)
            return true;
    }
    return false;
}

function value_contains(value, needle) {
    if (type(value) == "array") {
        for (let item in value) {
            if (as_string(item) == needle)
                return true;
        }
        return false;
    }

    return as_string(value) == needle;
}

function find_tagged_item(items, tag) {
    for (let item in array_or_empty(items)) {
        if (type(item) == "object" && item.tag == tag)
            return item;
    }

    return null;
}

function tagged_runtime_summary(config_path, section_name, tag) {
    let config = read_json_file(config_path);
    let item = find_tagged_item(config && config[section_name], tag);
    // AWG is an endpoint in tachyon-core, so an inbound asked for by tag may answer from endpoints.
    if (item == null && section_name == "inbounds")
        item = find_tagged_item(config && config.endpoints, tag);

    if (item == null) {
        write_json({ exists: 0 });
        return;
    }

    write_json({
        exists: 1,
        type: as_string(item.type),
        listen: as_string(item.listen),
        listen_port: int_arg(item.listen_port)
    });
}

function has_route_rule_for_inbound(config_path, inbound) {
    let config = read_json_file(config_path);
    for (let rule in array_or_empty(config && config.route && config.route.rules)) {
        if (type(rule) == "object" &&
            (rule.action == "route" || rule.action == "reject") &&
            value_contains(rule.inbound, inbound))
            return true;
    }

    return false;
}

let mode = ARGV[0] || "";

if (mode == "stdin-first-nonempty-field")
    stdin_first_nonempty_field();
else if (mode == "stdin-first-line-version-field")
    stdin_first_line_version_field();
else if (mode == "has-socks-outbound")
    exit(has_socks_outbound(ARGV[1], ARGV[2], ARGV[3], ARGV[4]) ? 0 : 1);
else if (mode == "has-direct-mark-outbound")
    exit(has_direct_mark_outbound(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "has-route-rule")
    exit(has_route_rule(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "inbound-summary")
    tagged_runtime_summary(ARGV[1], "inbounds", ARGV[2]);
else if (mode == "endpoint-summary")
    tagged_runtime_summary(ARGV[1], "endpoints", ARGV[2]);
else if (mode == "has-route-rule-for-inbound")
    exit(has_route_rule_for_inbound(ARGV[1], ARGV[2]) ? 0 : 1);
else {
    warn("Usage: providers/status.uc <operation> ...\n");
    exit(1);
}