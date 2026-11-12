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

let normalize_status = common.normalize_status;

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
const SING_BOX_TMP_DIR = env("TACHYON_SING_BOX_TMP_DIR", "/tmp/tachyon-core");
const SING_BOX_CONFIG_PATH = env("TACHYON_SING_BOX_CONFIG_PATH", "/etc/tachyon-core/config.json");

const PRESERVED_PERSISTENT_ENTRIES = {
    tailscale: 1,
    "tachyon-core-variant": 1,
    "tachyon-core-version": 1,
    "sing-box-variant": 1,
    "sing-box-version": 1,
    "installer-backups": 1
};

function config_has_enabled_work(path) {
    let text = fs.readfile(as_string(path));
    if (text == null)
        return false;

    let in_work_section = false;
    for (let raw_line in split(as_string(text), "\n")) {
        let line = replace(as_string(raw_line), /^[ \t\r]+|[ \t\r]+$/g, "");
        if (line == "" || substr(line, 0, 1) == "#")
            continue;
        let header = match(line, /^config[ \t]+([A-Za-z0-9_]+)/);
        if (header != null) {
            let stype = header[1];
            in_work_section = (stype == "section" || stype == "server");
            continue;
        }
        if (in_work_section && match(line, /^option[ \t]+enabled[ \t]+['"]?1['"]?([ \t#]|$)/) != null)
            return true;
    }
    return false;
}

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

function ancestor_pids() {
    let seen = {};
    let stat = fs.readfile("/proc/self/stat");
    if (stat == null)
        return seen;
    let m = match(as_string(stat), /^([0-9]+)[ \t]+\([^)]*\)[ \t]+[A-Za-z][ \t]+([0-9]+)/);
    let pid = m ? m[1] : "";
    let ppid = m ? m[2] : "";
    if (pid != "")
        seen[pid] = 1;
    let guard = 0;
    while (ppid != "" && int(ppid) > 1 && guard < 32) {
        seen[ppid] = 1;
        guard++;
        let pstat = fs.readfile("/proc/" + ppid + "/stat");
        if (pstat == null)
            break;
        let pm = match(as_string(pstat), /^[0-9]+[ \t]+\([^)]*\)[ \t]+[A-Za-z][ \t]+([0-9]+)/);
        ppid = pm ? pm[1] : "";
    }
    return seen;
}

function abort_inflight_init_and_retries() {
    let skip = ancestor_pids();
    let kill_args = [ "kill", "-9" ];

    let retry_pid = fs.readfile(RUNTIME_STATE_DIR + "/start-retry.pid");
    if (retry_pid != null) {
        retry_pid = replace(as_string(retry_pid), /[^0-9]/g, "");
        if (retry_pid != "" && !skip[retry_pid])
            push(kill_args, retry_pid);
        fs.unlink(RUNTIME_STATE_DIR + "/start-retry.pid");
    }
    fs.unlink(RUNTIME_STATE_DIR + "/start.retry");

    if (INIT_PATH != "/etc/init.d/" + CONFIG_NAME)
        return;

    let procs = fs.lsdir("/proc");
    if (type(procs) == "array") {
        for (let entry in procs) {
            entry = as_string(entry);
            if (ltrim(entry, "0123456789") != "" || skip[entry])
                continue;
            let cmd = fs.readfile("/proc/" + entry + "/cmdline");
            let text = cmd != null ? replace(as_string(cmd), /\0/g, " ") : "";
            let lock_fd = fs.readlink("/proc/" + entry + "/fd/1000");
            if (index(text, "retry_start_on_wan_up") >= 0 ||
                index(text, "retry-start-on-wan-up") >= 0 ||
                index(text, "wait-tachyon-core-service-stable") >= 0 ||
                index(text, "wait-tachyon-stable-start") >= 0 ||
                index(text, "/etc/init.d/" + CONFIG_NAME) >= 0 ||
                index(text, "components/updates.uc") >= 0 ||
                index(text, "service/lifecycle.uc") >= 0 ||
                index(text, "__service_action_worker") >= 0 ||
                (lock_fd != null && index(as_string(lock_fd), "procd_" + CONFIG_NAME) >= 0)) {
                push(kill_args, entry);
            }
        }
    }

    if (length(kill_args) > 2)
        command_success_from_args(kill_args);
}

function reset_settings(no_start) {
    let source = default_config_source();
    if (source == null) {
        log_message("Reset settings failed: default config source not found");
        print("{\"success\":false,\"message\":\"default config source not found\"}\n");
        return 1;
    }

    fs.mkdir(RUNTIME_STATE_DIR, 0755);
    common.write_file(RUNTIME_STATE_DIR + "/reset-stopped", "1\n");
    abort_inflight_init_and_retries();
    command_success_from_args([ BIN_PATH, "stop" ]);
    fs.mkdir(RUNTIME_STATE_DIR, 0755);
    common.write_file(RUNTIME_STATE_DIR + "/reset-stopped", "1\n");
    abort_inflight_init_and_retries();
    command_success_from_args([ INIT_PATH, "stop" ]);

    command_success_from_args([ "rm", "-rf",
        RUNTIME_STATE_DIR,
        "/var/run/" + CONFIG_NAME + ".reload.lock",
        "/tmp/.uci/" + CONFIG_NAME,
        SING_BOX_TMP_DIR,
        SING_BOX_CONFIG_PATH
    ]);
    if (!remove_persistent_state()) {
        log_message("Reset settings failed: unable to clean " + PERSISTENT_DIR);
        print("{\"success\":false,\"message\":\"unable to clean persistent state\"}\n");
        return 1;
    }

    if (!command_success_from_args([ "cp", "-f", source, CONFIG_PATH ])) {
        log_message("Reset settings failed: unable to write default config");
        print("{\"success\":false,\"message\":\"unable to write default config\"}\n");
        return 1;
    }
    command_success_from_args([ "chmod", "600", CONFIG_PATH ]);

    log_message("Settings have been reset to defaults");

    if (no_start == "1" || !config_has_enabled_work(CONFIG_PATH)) {
        print("{\"success\":true}\n");
        return 0;
    }

    let start_status = command_success_from_args([ INIT_PATH, "start" ]) ? 0 : 1;
    if (start_status != 0) {
        log_message("Reset settings: service failed to start after reset");
        print("{\"success\":true,\"started\":false}\n");
        return 0;
    }

    print("{\"success\":true,\"started\":true}\n");
    return 0;
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
