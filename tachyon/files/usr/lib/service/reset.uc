#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

let shell_quote = common.shell_quote;

let command_from_args = common.command_from_args;

function normalize_status(status) {
    status = int(status);
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function log_message(message) {
    system(command_from_args([ "logger", "-t", CONFIG_NAME, "[info] " + message ]) + " >/dev/null 2>&1");
}

const CONFIG_NAME = env("TACHYON_CONFIG_NAME", "tachyon");
const LIB_DIR = env("TACHYON_LIB", "/usr/lib/tachyon");
const BIN_PATH = env("TACHYON_BIN", "/usr/bin/tachyon");
const INIT_PATH = env("TACHYON_SERVICE_INIT", "/etc/init.d/" + CONFIG_NAME);
const CONFIG_PATH = env("TACHYON_CONFIG_PATH", "/etc/config/" + CONFIG_NAME);
const PERSISTENT_DIR = env("TACHYON_PERSISTENT_DIR", "/etc/" + CONFIG_NAME);
const RUNTIME_STATE_DIR = env("TACHYON_RUNTIME_STATE_DIR", "/var/run/" + CONFIG_NAME);
const SING_BOX_TMP_DIR = env("TACHYON_SING_BOX_TMP_DIR", "/tmp/sing-box");
const SING_BOX_CONFIG_PATH = env("TACHYON_SING_BOX_CONFIG_PATH", "/etc/sing-box/config.json");

const PRESERVED_PERSISTENT_ENTRIES = {
    tailscale: 1
};

function default_config_source() {
    for (let candidate in [
        "/rom/etc/config/" + CONFIG_NAME,
        LIB_DIR + "/defaults/" + CONFIG_NAME + ".conf",
        LIB_DIR + "/defaults/config"
    ]) {
        candidate = as_string(candidate);
        if (fs.stat(candidate) != null)
            return candidate;
    }
    return null;
}

function remove_persistent_state() {
    if (fs.stat(PERSISTENT_DIR) == null)
        return true;

    let entries = fs.lsdir(PERSISTENT_DIR);
    if (type(entries) != "array")
        return false;

    for (let entry in entries) {
        entry = as_string(entry);
        if (PRESERVED_PERSISTENT_ENTRIES[entry])
            continue;
        if (!command_success_from_args([ "rm", "-rf", PERSISTENT_DIR + "/" + entry ]))
            return false;
    }
    return true;
}

function reset_settings(no_start) {
    command_success_from_args([ BIN_PATH, "stop" ]);
    command_success_from_args([ INIT_PATH, "stop" ]);

    command_success_from_args([ "rm", "-rf",
        RUNTIME_STATE_DIR,
        SING_BOX_TMP_DIR,
        SING_BOX_CONFIG_PATH
    ]);
    if (!remove_persistent_state()) {
        log_message("Reset settings failed: unable to clean " + PERSISTENT_DIR);
        print("{\"success\":false,\"message\":\"unable to clean persistent state\"}\n");
        return 1;
    }

    let source = default_config_source();
    if (source == null) {
        log_message("Reset settings failed: default config source not found");
        print("{\"success\":false,\"message\":\"default config source not found\"}\n");
        return 1;
    }

    if (!command_success_from_args([ "cp", "-f", source, CONFIG_PATH ])) {
        log_message("Reset settings failed: unable to write default config");
        print("{\"success\":false,\"message\":\"unable to write default config\"}\n");
        return 1;
    }
    command_success_from_args([ "chmod", "600", CONFIG_PATH ]);

    log_message("Settings have been reset to defaults");
    print("{\"success\":true}\n");

    if (no_start == "1")
        return 0;

    let start_status = command_success_from_args([ INIT_PATH, "start" ]) ? 0 : 1;
    if (start_status != 0) {
        log_message("Reset settings: service failed to start after reset");
        print("{\"success\":true,\"started\":false}\n");
    }
    return start_status;
}

let mode = as_string(ARGV[0]);
let no_start = "0";
for (let i = 1; i < length(ARGV); i++) {
    let arg = as_string(ARGV[i]);
    if (arg == "no-start" || arg == "--no-start")
        no_start = "1";
}

if (mode == "reset-settings")
    exit(reset_settings(no_start));

warn("Usage: service/reset.uc reset-settings [no-start]\n");
exit(1);
