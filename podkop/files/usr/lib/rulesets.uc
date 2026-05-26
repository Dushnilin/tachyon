#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function json_decode_text(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

function read_json_file(path) {
    let data = fs.readfile(path);
    return data == null ? null : json_decode_text(data);
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J", value) + "\n");
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function sort_values(values) {
    sort(values, function(first, second) {
        first = sprintf("%J", first);
        second = sprintf("%J", second);
        return first == second ? 0 : (first < second ? -1 : 1);
    });
    return values;
}

function unique_values(values) {
    values = sort_values(values);
    let result = [];
    let previous = null;
    let has_previous = false;

    for (let value in values) {
        let encoded = sprintf("%J", value);
        if (!has_previous || encoded != previous) {
            push(result, value);
            previous = encoded;
            has_previous = true;
        }
    }

    return result;
}

function create_source(path) {
    if (!write_json_file(path, { version: 3, rules: [] }))
        exit(1);
}

function patch_source(path, key, value_text) {
    let ruleset = object_or_empty(read_json_file(path));
    let values = array_or_empty(json_decode_text(value_text));

    if (type(ruleset.rules) != "array")
        ruleset.rules = [];

    let found = false;
    for (let rule in ruleset.rules) {
        if (type(rule) == "object" && rule[key] != null) {
            let merged = [];
            for (let item in array_or_empty(rule[key]))
                push(merged, item);
            for (let item in values)
                push(merged, item);
            rule[key] = unique_values(merged);
            found = true;
            break;
        }
    }

    if (!found) {
        let rule = {};
        rule[key] = values;
        push(ruleset.rules, rule);
    }

    if (!write_json_file(path, ruleset))
        exit(1);
}

function extract_ip_cidr(json_path, output_path) {
    let ruleset = object_or_empty(read_json_file(json_path));
    let lines = [];

    for (let rule in array_or_empty(ruleset.rules)) {
        if (type(rule) != "object")
            continue;
        for (let ip in array_or_empty(rule.ip_cidr))
            push(lines, as_string(ip));
    }

    if (!fs.writefile(output_path, length(lines) > 0 ? join("\n", lines) + "\n" : ""))
        exit(1);
}

function value_has_domain_matchers(value) {
    if (type(value) == "array") {
        for (let item in value) {
            if (value_has_domain_matchers(item))
                return true;
        }
        return false;
    }

    if (type(value) != "object")
        return false;

    for (let key, item in value) {
        if (key == "domain" || key == "domain_suffix" || key == "domain_keyword" || key == "domain_regex") {
            if (type(item) == "array" && length(item) > 0)
                return true;
            if (type(item) == "string" && item != "")
                return true;
        }

        if (value_has_domain_matchers(item))
            return true;
    }

    return false;
}

function has_domain_matchers(path) {
    return value_has_domain_matchers(read_json_file(path));
}

let mode = ARGV[0] || "";

if (mode == "create-source")
    create_source(ARGV[1]);
else if (mode == "patch-source")
    patch_source(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "extract-ip-cidr")
    extract_ip_cidr(ARGV[1], ARGV[2]);
else if (mode == "has-domain-matchers")
    exit(has_domain_matchers(ARGV[1]) ? 0 : 1);
else {
    warn("Usage: rulesets.uc <create-source|patch-source|extract-ip-cidr> ...\n");
    exit(1);
}
