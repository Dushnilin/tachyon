#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function read_state_value(path, needle) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    needle = as_string(needle);
    for (let line in split(data, "\n")) {
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == needle) {
            print(equals >= 0 ? substr(line, equals + 1) : line, "\n");
            return;
        }
    }
}

function state_has_key(path, needle) {
    let data = fs.readfile(path);
    if (data == null)
        return false;

    needle = as_string(needle);
    for (let line in split(data, "\n")) {
        let equals = index(line, "=");
        let key = equals >= 0 ? substr(line, 0, equals) : line;
        if (key == needle)
            return true;
    }

    return false;
}

function write_reload_state(path) {
    let fields = [
        "format",
        "service_trigger_signature",
        "dnsmasq_signature",
        "sing_box_signature",
        "nft_signature",
        "zapret_queue_signature",
        "zapret_runtime_signature",
        "zapret2_queue_signature",
        "zapret2_runtime_signature",
        "byedpi_runtime_signature",
        "list_signature",
        "cron_signature",
        "urltest_enabled_sections",
        "dont_touch_dhcp"
    ];

    let output = "";
    for (let i = 0; i < length(fields); i++)
        output += fields[i] + "=" + as_string(ARGV[i + 2]) + "\n";

    if (!fs.writefile(path, output))
        exit(1);
}

function response_success() {
    let value = read_stdin_json();
    return type(value) == "object" && value.success === true;
}

function stdin_first_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = newline >= 0 ? substr(data, 0, newline) : data;
    let fields = split(trim(as_string(line)), /[ \t\r\n]+/);

    if (length(fields) > 0 && fields[0] != "")
        print(fields[0], "\n");
}

function sing_box_service_pid() {
    let value = read_stdin_json();
    let service = type(value) == "object" ? value["sing-box"] : null;
    let instances = service && type(service.instances) == "object" ? service.instances : {};

    for (let _, instance in instances) {
        if (type(instance) == "object" && instance.running === true && int(instance.pid || 0) > 0) {
            print(instance.pid, "\n");
            return;
        }
    }
}

let mode = ARGV[0];

if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "get")
    read_state_value(ARGV[1], ARGV[2]);
else if (mode == "has-key")
    exit(state_has_key(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "write-reload-state")
    write_reload_state(ARGV[1]);
else if (mode == "response-success")
    exit(response_success() ? 0 : 1);
else if (mode == "stdin-first-field")
    stdin_first_field();
else if (mode == "sing-box-service-pid")
    sing_box_service_pid();
else {
    warn("Usage: runtime_state.uc <operation> ...\n");
    exit(1);
}
