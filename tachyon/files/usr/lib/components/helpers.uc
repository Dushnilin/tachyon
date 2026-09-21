#!/usr/bin/env ucode
//
// Shared low-level helpers for the components/* modules.
//
// This is the bottom layer of the component-update stack: it owns filesystem
// utilities, command plumbing, module/helper spawning, tmp-dir management,
// job logging and phase reporting. Higher layers (versions, verifier,
// downloader, installer, rollback, catalog) require this module; action.uc
// orchestrates on top and keeps the component lock + CLI dispatch.
//

let fs = require("fs");
let helpers = require("core.helpers");
let common = require("core.common");

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const SING_BOX_BIN = getenv("TACHYON_SING_BOX_BIN") || "/usr/bin/sing-box";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const JOB_HEARTBEAT_INTERVAL = int(getenv("TACHYON_JOB_HEARTBEAT_INTERVAL") || "5");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let write_file = common.write_file;
let bounded_command = common.bounded_command;

let tmp_dir = "";
let current_job_phase = "";
let job_phase_started_at = 0;

// ============================================================================
// Generic command and filesystem utilities
// ============================================================================

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    if (length(prefix) == 0)
        return true;
    return length(value) >= length(prefix) && substr(value, 0, length(prefix)) == prefix;
}

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

// Like command_output but keeps stdout regardless of the exit status. popen()'s
// close() yields a raw wait status, so a command that writes a perfectly good
// answer and then exits non-zero - or is signalled - loses all of it above.
function command_output_lenient(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data != null ? as_string(data) : "";
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function read_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? "" : as_string(data);
}

// The empty catch is the point: every caller means "make sure this path is
// gone", and an absent file already satisfies that. fs.unlink throws on ENOENT,
// so the alternative is a stat() race with no better outcome.
function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_nonempty(path) {
    return helpers.file_is_usable(path, 0);
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? as_string(parts[length(parts) - 1]) : "";
}

function now_seconds() {
    return int(clock()[0]);
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function pid_running(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null || !command_success_from_args([ "kill", "-0", pid ]))
        return false;
    let cmd = fs.readfile("/proc/" + pid + "/cmdline");
    if (cmd != null && match(cmd, /ucode|tachyon|sh/) == null)
        return false;
    return true;
}

// ============================================================================
// Logging: syslog + job log + job phase reporting
// ============================================================================

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[" + level + "] " + as_string(message) ]);
}

function job_log_time() {
    let seconds = int(clock()[0]);
    return sprintf("%02d:%02d:%02d", int(seconds / 3600) % 24, int(seconds / 60) % 60, seconds % 60);
}

function job_log_append(message, level) {
    let path = getenv("UPDATES_JOB_LOG");
    if (path == "")
        return;
    let file = fs.open(path, "a");
    if (!file)
        return;
    file.write(sprintf("[%s] [%s] %s\n", job_log_time(), as_string(level), as_string(message)));
    file.close();
}

function updates_log(message, level) {
    level = as_string(level || "info");
    log_message("Updates: " + as_string(message), level);
    job_log_append(message, level);
}

function update_job_phase(phase, message) {
    current_job_phase = as_string(phase);
    job_phase_started_at = now_seconds();
    updates_log(message || phase);
    let state_path = getenv("UPDATES_JOB_STATE_FILE");
    if (state_path == "")
        return;
    try {
        let data = fs.readfile(state_path);
        if (data == null)
            return;
        let state = json(as_string(data));
        if (type(state) != "object")
            return;
        state.phase = current_job_phase;
        state.phase_started_at = job_phase_started_at;
        state.heartbeat_at = now_seconds();
        state.updated_at = now_seconds();
        if (as_string(message) != "")
            state.message = as_string(message);
        let tmp = state_path + ".hb." + owner_pid();
        write_file(tmp, sprintf("%J\n", state));
        fs.rename(tmp, state_path);
    } catch (e) {}
}

function job_heartbeat() {
    let state_path = getenv("UPDATES_JOB_STATE_FILE");
    if (state_path == "")
        return;
    try {
        let data = fs.readfile(state_path);
        if (data == null)
            return;
        let state = json(as_string(data));
        if (type(state) != "object" || state.running !== true)
            return;
        state.heartbeat_at = now_seconds();
        state.updated_at = now_seconds();
        let tmp = state_path + ".hb." + owner_pid();
        write_file(tmp, sprintf("%J\n", state));
        fs.rename(tmp, state_path);
    } catch (e) {}
}

// ============================================================================
// Storage preflight
// ============================================================================

function free_kb(path) {
    let out = trim(command_output("df -Pk " + shell_quote(path) + " 2>/dev/null | tail -n 1 | awk '{print $4}'"));
    return int(out);
}

function get_component_backup_enabled() {
    let uci_core = require("core.uci");
    let settings = (uci_core && uci_core.get_all) ? (uci_core.get_all("tachyon", "settings") || {}) : {};
    let val = as_string(settings.component_backup_enabled || "");
    return val == "1" || val == "true" || val == "yes" || val == "on";
}

function check_free_disk_space(target_dir, needed_bytes) {
    let out = trim(command_output("df -k " + shell_quote(target_dir) + " 2>/dev/null | tail -n 1 | awk '{print $4}'"));
    let free_kb = int(out);
    if (free_kb <= 0)
        return true;
    let needed_kb = int((needed_bytes || 0) / 1024) + 1024;
    return free_kb > (needed_kb * 2) && (free_kb - needed_kb) > 4096;
}

function preflight_storage_check(component, asset_size_bytes, backup_required) {
    let tmp_free = free_kb("/tmp");
    let needed_tmp_kb = int((asset_size_bytes || 0) / 1024) + 2048;
    if (backup_required) {
        let bin_size = 0;
        if (component == "sing_box" && file_exists(SING_BOX_BIN)) {
            let st = fs.stat(SING_BOX_BIN);
            bin_size = (st && st.size) ? st.size : 0;
        }
        needed_tmp_kb += int(bin_size / 1024) + 1024;
    }
    if (tmp_free > 0 && tmp_free < needed_tmp_kb) {
        updates_log("Insufficient /tmp space for " + as_string(component) +
            ": need " + needed_tmp_kb + " KB, have " + tmp_free + " KB", "error");
        return false;
    }
    return true;
}

function preflight_backup_space_check(component) {
    if (!get_component_backup_enabled())
        return true;
    let st = null;
    if (component == "sing_box" && file_exists(SING_BOX_BIN))
        st = fs.stat(SING_BOX_BIN);
    if (st == null)
        return true;
    let size = (st.size) ? st.size : 0;
    if (size <= 0)
        return true;
    if (!check_free_disk_space("/etc", size)) {
        let avail = free_kb("/overlay") || free_kb("/");
        updates_log("Cannot create backup: insufficient persistent storage for " + as_string(component) +
            ". Required: " + int(size / 1024) + " KB, Available: " + avail + " KB. " +
            "Disable component backup or free storage.", "error");
        return false;
    }
    return true;
}

// ============================================================================
// Package manager detection
// ============================================================================

function is_apk() {
    let forced = getenv("TACHYON_FORCE_PKG_MANAGER");
    if (forced == "apk")
        return true;
    if (forced == "opkg")
        return false;
    return command_exists("apk");
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_output(args) {
    return command_output(module_command(args));
}

function module_success(args) {
    return command_success(module_command(args));
}

function helper_output(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_output(command_args);
}

function helper_success(mode, args) {
    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

// ============================================================================
// Temp dir management
// ============================================================================

function cleanup_stale_tmp_files() {
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "d", "-name", "tachyon-updates.*", "-mmin", "+" + as_string(TMP_STALE_TTL_MINUTES), "-exec", "rm", "-rf", "{}", "+" ]);
    command_success_from_args([ "find", "/tmp", "-maxdepth", "1", "-type", "f", "(", "-name", "tachyon-updates-command.*", "-o", "-name", "tachyon-updates-http.*", ")", "-mmin", "+" + as_string(TMP_FILE_STALE_TTL_MINUTES), "-delete" ]);
}

function init_tmp_dir() {
    ensure_dir("/var/lock");
    ensure_dir("/tmp/run");
    if (tmp_dir != "")
        return true;

    cleanup_stale_tmp_files();
    tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-updates.XXXXXX" ]));
    if (tmp_dir == "") {
        tmp_dir = "/tmp/tachyon-updates." + owner_pid();
        if (!ensure_dir(tmp_dir)) {
            tmp_dir = "";
            return false;
        }
    }
    return true;
}

function make_tmp_file(prefix) {
    init_tmp_dir();
    let base = tmp_dir != "" ? tmp_dir + "/" + as_string(prefix) + ".XXXXXX" : "/tmp/tachyon-updates-" + as_string(prefix) + ".XXXXXX";
    let path = trim(command_output_from_args([ "mktemp", base ]));
    if (path == "") {
        path = (tmp_dir != "" ? tmp_dir : "/tmp") + "/" + as_string(prefix) + "." + owner_pid() + "." + now_seconds();
        if (!write_file(path, ""))
            return "";
    }
    return path;
}

function helper_output_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return "";
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let output = command_output(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return output;
}

function helper_success_input(input, mode, args) {
    let input_path = make_tmp_file("helper-input");
    if (input_path == "")
        return false;
    write_file(input_path, as_string(input));

    let command_args = [ LIB_DIR + "/components/updater.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    let ok = command_success(command_from_args([ "cat", input_path ]) + " | " + module_command(command_args));
    remove_file(input_path);
    return ok;
}

function tmp_dir_path() {
    return tmp_dir;
}

function cleanup_tmp_dir() {
    if (tmp_dir != "") {
        command_success_from_args([ "rm", "-rf", tmp_dir ]);
        tmp_dir = "";
    }
    cleanup_stale_tmp_files();
}

function pkg_is_installed(package_name) {
    package_name = as_string(package_name);
    if (is_apk())
        return command_success_from_args([ "apk", "info", "-e", package_name ]);
    return module_success([ LIB_DIR + "/core/packages.uc", "opkg-installed", package_name ]);
}

// Drop stale references to managed sing-box packages from /etc/apk/world so
// that subsequent package transactions do not trip over removed variants.
function sanitize_apk_world() {
    if (!is_apk() || !file_exists("/etc/apk/world"))
        return;
    for (let pkg in [ "sing-box-extended", "sing-box", "sing-box-tiny", "sing-box-lx" ]) {
        if (!pkg_is_installed(pkg))
            command_success("sed -i -E " + shell_quote("/^" + pkg + "([><= ].*)?$/d") + " /etc/apk/world 2>/dev/null");
    }
}

// ============================================================================
// Module / helper spawning (ucode -L subprocesses)
// ============================================================================


// ============================================================================
// Logged command execution
// ============================================================================

function run_logged(description, command, timeout_seconds) {
    init_tmp_dir();
    let output_file = make_tmp_file("command");
    if (output_file == "")
        output_file = "/tmp/tachyon-updates-command." + owner_pid();

    updates_log(description);
    timeout_seconds = timeout_seconds || 120;
    let run_cmd = bounded_command(command, timeout_seconds);
    let status = command_status(run_cmd + " >" + shell_quote(output_file) + " 2>&1");
    for (let line in split(read_file(output_file), "\n"))
        if (trim(as_string(line)) != "")
            updates_log(line);
    remove_file(output_file);
    if (status != 0)
        updates_log(description + " failed with exit code " + status, "warn");
    return status == 0;
}

function normalize_stream_exit(close_status) {
    if (close_status == null)
        return 0;
    let s = int(close_status);
    let signal = s & 127;
    if (signal != 0)
        return 128 + signal;
    return (s >> 8) & 255;
}

function detect_apk_lock(output_text, exit_code) {
    if (exit_code == 227)
        return true;
    if (exit_code == 255 && match(output_text, /Could not lock|opkg\.lock|Resource temporarily unavailable/i) != null)
        return true;
    return false;
}

function diagnose_apk_lock_holder() {
    for (let fd_path in fs.glob("/proc/[0-9]*/fd/*")) {
        let target = "";
        try { target = as_string(fs.readlink(fd_path)); } catch (e) { continue; }
        if (match(target, /apk\/db\/lock|lib\/apk\/db\/lock/) == null)
            continue;
        let parts = split(fd_path, "/");
        if (length(parts) < 3)
            continue;
        let pid = as_string(parts[2]);
        let comm = "";
        try { comm = trim(as_string(fs.readfile("/proc/" + pid + "/comm"))); } catch (e) {}
        updates_log("APK lock holder: pid=" + pid + " process=" + (comm != "" ? comm : "unknown"), "warn");
        return;
    }
    updates_log("APK database is locked but holder could not be identified", "warn");
}

function stream_command_output(command, description) {
    updates_log(description);
    let pipe = fs.popen(command + " 2>&1", "r");
    if (!pipe) {
        updates_log(description + ": failed to execute", "error");
        return 255;
    }
    let last_output_at = now_seconds();
    let last_heartbeat = now_seconds();
    let exit_code = 0;
    while (true) {
        let line = pipe.read("line");
        if (line == null)
            break;
        line = trim(as_string(line));
        if (line != "")
            updates_log(line);
        last_output_at = now_seconds();
        // Periodic heartbeat during long streaming operations
        if (now_seconds() - last_heartbeat >= JOB_HEARTBEAT_INTERVAL) {
            job_heartbeat();
            last_heartbeat = now_seconds();
        }
    }
    exit_code = normalize_stream_exit(pipe.close());
    return exit_code;
}

// Like run_logged but retries while the package manager database stays locked.
// Streams the output instead of buffered file reads.
function run_logged_retrying(description, command) {
    init_tmp_dir();
    sanitize_apk_world();

    let output_file = make_tmp_file("command");
    if (output_file == "")
        output_file = "/tmp/tachyon-updates-command." + owner_pid();

    let status = 227;
    let max_attempts = 10;
    for (let attempt = 0; attempt < max_attempts; attempt++) {
        if (attempt > 0) {
            let mgr_name = is_apk() ? "APK" : "opkg";
            updates_log(description + ": " + mgr_name + " database locked, retrying in 3s (attempt " + (attempt + 1) + "/" + max_attempts + ")");
            command_success("sleep 3");
        }
        let pipe = fs.popen(as_string(command) + " 2>&1 | tee " + shell_quote(output_file) + " | tail -c 16384 > /dev/null", "r");
        let output_text = "";
        let last_activity = now_seconds();
        if (pipe) {
            while (true) {
                let line = pipe.read("line");
                if (line == null)
                    break;
                line = trim(as_string(line));
                if (line != "") {
                    updates_log(line, attempt > 0 ? "warn" : "info");
                    last_activity = now_seconds();
                }
            }
            status = normalize_stream_exit(pipe.close());
        } else {
            status = 255;
        }
        output_text = as_string(read_file(output_file)) || "";
        let is_locked = detect_apk_lock(output_text, status) &&
            match(output_text, /unable to select packages|no such package/i) == null;
        if (!is_locked)
            break;
    }
    remove_file(output_file);
    if (status != 0)
        updates_log(description + " failed with exit code " + status, "warn");
    return status == 0;
}

// ============================================================================
// Environment introspection
// ============================================================================

function read_openwrt_release_value(key) {
    return trim(helper_output("openwrt-release-value", [ "/etc/openwrt_release", key ]));
}

function service_proxy_address() {
    if (!file_exists(LIB_DIR + "/singbox/runtime.uc"))
        return "";
    if (file_exists(LIB_DIR + "/service/state.uc") &&
        !module_success([ LIB_DIR + "/service/state.uc", "sing-box-service-running" ]))
        return "";
    let addr = trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-proxy-address", "components" ]));
    if (addr == "")
        addr = trim(module_output([ LIB_DIR + "/singbox/runtime.uc", "service-proxy-address", "lists" ]));
    return addr;
}

// Forward-referenced helpers

function module_exports() {
    return {
        LIB_DIR,
        SING_BOX_BIN,
        str_startswith,
        command_env,
        command_output_lenient,
        command_exists,
        read_file,
        remove_file,
        ensure_dir,
        file_exists,
        file_nonempty,
        path_basename,
        now_seconds,
        owner_pid,
        pid_running,
        log_message,
        job_log_time,
        job_log_append,
        updates_log,
        update_job_phase,
        job_heartbeat,
        free_kb,
        get_component_backup_enabled,
        check_free_disk_space,
        preflight_storage_check,
        preflight_backup_space_check,
        is_apk,
        pkg_is_installed,
        sanitize_apk_world,
        module_command,
        module_output,
        module_success,
        helper_output,
        helper_success,
        cleanup_stale_tmp_files,
        init_tmp_dir,
        make_tmp_file,
        helper_output_input,
        helper_success_input,
        cleanup_tmp_dir,
        tmp_dir_path,
        run_logged,
        normalize_stream_exit,
        detect_apk_lock,
        diagnose_apk_lock_holder,
        stream_command_output,
        run_logged_retrying,
        read_openwrt_release_value,
        service_proxy_address
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: components/helpers.uc (library module, no CLI)\n");
exit(1);
