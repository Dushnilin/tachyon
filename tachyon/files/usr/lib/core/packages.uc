#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_LOCK_TIMEOUT = int(getenv("TACHYON_PKG_LOCK_TIMEOUT") || "60");
const LOCK_STALE_TTL = int(getenv("TACHYON_PKG_LOCK_STALE_TTL") || "300");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function command_output_args(args) {
    return command_output(command_from_args(args));
}

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_exists(name) {
    return system(command_from_args([ "command", "-v", name ]) + " >/dev/null 2>&1") == 0;
}

// ---------------------------------------------------------------------------
// Package manager detection
// ---------------------------------------------------------------------------

function detect_pkg_manager() {
    let forced = getenv("TACHYON_FORCE_PKG_MANAGER");
    if (forced == "apk" || forced == "opkg")
        return forced;
    if (command_exists("apk"))
        return "apk";
    if (command_exists("opkg"))
        return "opkg";
    return "";
}

function is_apk() {
    return detect_pkg_manager() == "apk";
}

// ---------------------------------------------------------------------------
// CPU architecture detection
// ---------------------------------------------------------------------------

function detect_arch() {
    let arch = command_output_args([ "uname", "-m" ]);
    arch = trim(arch);
    if (arch != "")
        return arch;
    let cpuinfo = as_string(fs.readfile("/proc/cpuinfo") || "");
    for (let line in split(cpuinfo, "\n")) {
        let m = match(line, /^model name\s*:\s*(.+)/i);
        if (m) return trim(m[1]);
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Binary detection and version
// ---------------------------------------------------------------------------

function binary_installed(package_name) {
    if (package_name == "zapret2")
        return fs.stat("/opt/zapret2/nfq2/nfqws2") != null || fs.stat("/opt/zapret2/nfqws2") != null || fs.stat("/usr/bin/nfqws2") != null;
    if (package_name == "zapret")
        return fs.stat("/opt/zapret/nfq/nfqws") != null || fs.stat("/opt/zapret/nfqws") != null;
    if (package_name == "byedpi")
        return fs.stat("/usr/bin/ciadpi") != null;
    if (package_name == "fptn" || package_name == "fptn-client")
        return fs.stat("/usr/bin/fptn-client-cli") != null || fs.stat("/usr/bin/fptn-client") != null;
    if (package_name == "sing-box" || package_name == "sing-box-extended" || package_name == "sing-box-lx")
        return fs.stat("/usr/bin/sing-box") != null;
    return false;
}

function apk_installed(package_name) {
    package_name = as_string(package_name);
    if (command_exists("apk") && command_success([ "apk", "info", "-e", package_name ]))
        return true;
    return binary_installed(package_name);
}

function opkg_installed(package_name) {
    package_name = as_string(package_name);
    if (command_exists("opkg")) {
        let prefix = package_name + " - ";
        for (let line in split(command_output_args([ "opkg", "list-installed" ]), "\n")) {
            line = trim(as_string(line));
            if (substr(line, 0, length(prefix)) == prefix)
                return true;
        }
    }
    return binary_installed(package_name);
}

function installed(package_name) {
    return apk_installed(package_name) || opkg_installed(package_name);
}

function apk_manifest_version(package_name, output) {
    package_name = as_string(package_name);
    let found = false;
    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, 2) == "P:")
            found = substr(line, 2) == package_name;
        else if (found && substr(line, 0, 2) == "V:")
            return substr(line, 2);
    }
    return "";
}

function apk_info_version(package_name, output) {
    package_name = as_string(package_name);
    let prefix = package_name + "-";
    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        if (substr(line, 0, length(prefix)) == prefix)
            return substr(line, length(prefix));
    }
    return "";
}

function apk_list_version(package_name, output) {
    package_name = as_string(package_name);
    let prefix = package_name + "-";
    for (let line in split(as_string(output), "\n")) {
        for (let field in split(trim(as_string(line)), /[ \t]+/)) {
            field = as_string(field);
            if (substr(field, 0, length(prefix)) != prefix)
                continue;
            let version = substr(field, length(prefix));
            if (version != "")
                return version;
        }
    }
    return "";
}

function apk_query_version(package_name, output) {
    package_name = as_string(package_name);
    let packages;
    try { packages = json(as_string(output)); } catch (e) { return ""; }
    if (type(packages) != "array")
        return "";
    for (let package in packages) {
        if (type(package) != "object" || as_string(package.name) != package_name)
            continue;
        let version = as_string(package.version);
        if (version != "")
            return version;
    }
    return "";
}

function binary_version(package_name) {
    if (package_name == "zapret2") {
        for (let p in [ "/opt/zapret2/nfq2/nfqws2", "/opt/zapret2/nfqws2", "/usr/bin/nfqws2" ]) {
            if (fs.stat(p) != null) {
                let out = command_output_args([ p, "--version" ]);
                let m = match(out, /version[ \t]*([0-9a-zA-Z._-]+)/i);
                if (m) return m[1];
            }
        }
    }
    if (package_name == "zapret") {
        for (let p in [ "/opt/zapret/nfq/nfqws", "/opt/zapret/nfqws" ]) {
            if (fs.stat(p) != null) {
                let out = command_output_args([ p, "--version" ]);
                let m = match(out, /version[ \t]*([0-9a-zA-Z._-]+)/i);
                if (m) return m[1];
            }
        }
    }
    if (package_name == "byedpi" && fs.stat("/usr/bin/ciadpi") != null) {
        let out = command_output_args([ "/usr/bin/ciadpi", "--version" ]);
        let m = match(out, /([0-9a-zA-Z._-]+)/);
        if (m) return m[1];
    }
    if ((package_name == "fptn" || package_name == "fptn-client")) {
        for (let p in [ "/usr/bin/fptn-client-cli", "/usr/bin/fptn-client" ]) {
            if (fs.stat(p) != null) {
                let out = command_output_args([ p, "--version" ]);
                let m = match(out, /version[ \t]*([0-9a-zA-Z._-]+)/i) || match(out, /([0-9]+\.[0-9a-zA-Z._-]+)/);
                if (m) return m[1];
            }
        }
    }
    if ((package_name == "sing-box" || package_name == "sing-box-extended" || package_name == "sing-box-lx") && fs.stat("/usr/bin/sing-box") != null) {
        let out = command_output_args([ "/usr/bin/sing-box", "version" ]);
        let m = match(out, /version[ \t]*([0-9a-zA-Z._-]+)/i);
        if (m) return m[1];
    }
    return "";
}

function apk_version(package_name) {
    package_name = as_string(package_name);
    if (!apk_installed(package_name))
        return "";
    let ver = apk_list_version(package_name, command_output_args([ "apk", "list", "--installed", package_name ]));
    if (ver != "") return ver;
    ver = apk_info_version(package_name, command_output_args([ "apk", "info", "-v", package_name ]));
    if (ver != "") return ver;
    ver = apk_manifest_version(package_name, command_output_args([ "apk", "list", "--installed", "--manifest", package_name ]));
    if (ver != "") return ver;
    ver = apk_manifest_version(package_name, command_output_args([ "apk", "list", "--installed", "--manifest" ]));
    if (ver != "") return ver;
    return binary_version(package_name);
}

function apk_available_version(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("apk"))
        return "";
    return apk_query_version(
        package_name,
        command_output_args([ "apk", "query", "--from", "repositories", "--available", "--format", "json", "--fields", "name,version", package_name ])
    );
}

function opkg_version(package_name) {
    package_name = as_string(package_name);
    if (command_exists("opkg")) {
        let prefix = package_name + " - ";
        for (let line in split(command_output_args([ "opkg", "list-installed" ]), "\n")) {
            line = trim(as_string(line));
            if (substr(line, 0, length(prefix)) == prefix)
                return substr(line, length(prefix));
        }
    }
    return binary_version(package_name);
}

function version(package_name) {
    let value = apk_version(package_name);
    return value != "" ? value : opkg_version(package_name);
}

// ---------------------------------------------------------------------------
// Lock detection and diagnosis
// ---------------------------------------------------------------------------

function detect_lock(output_text, exit_code) {
    exit_code = int(exit_code || 0);
    if (exit_code == 227)
        return true;
    if (exit_code == 255 && match(as_string(output_text), /Could not lock|opkg\.lock|Resource temporarily unavailable/i) != null)
        return true;
    return false;
}

function find_lock_holder() {
    let lock_patterns = [ "apk/db/lock", "lib/apk/db/lock", "opkg.lock" ];
    for (let fd_path in fs.glob("/proc/[0-9]*/fd/*")) {
        let target = "";
        try { target = as_string(fs.readlink(fd_path)); } catch (e) { continue; }
        let matched = false;
        for (let pattern in lock_patterns) {
            if (match(target, pattern) != null) { matched = true; break; }
        }
        if (!matched) continue;
        let parts = split(fd_path, "/");
        if (length(parts) < 3) continue;
        let pid = as_string(parts[2]);
        let comm = "";
        let cmdline = "";
        try { comm = trim(as_string(fs.readfile("/proc/" + pid + "/comm") || "")); } catch (e) {}
        try { cmdline = trim(as_string(fs.readfile("/proc/" + pid + "/cmdline") || "")); } catch (e) {}
        let alive = command_success([ "kill", "-0", pid ]);
        return { pid: pid, command: comm != "" ? comm : (cmdline != "" ? cmdline : "unknown"), alive: alive, lock_path: target };
    }
    return null;
}

function is_stale_lock(holder) {
    if (holder == null) return true;
    if (type(holder) != "object") return true;
    return !holder.alive;
}

// ---------------------------------------------------------------------------
// Structured lock wait
// ---------------------------------------------------------------------------

function wait_for_lock(opts) {
    opts = type(opts) == "object" ? opts : {};
    let timeout = int(opts.timeout || DEFAULT_LOCK_TIMEOUT);
    let on_wait = type(opts.on_wait) == "function" ? opts.on_wait : null;
    let log_fn = type(opts.log_fn) == "function" ? opts.log_fn : null;

    function log_msg(msg, level) {
        if (log_fn) log_fn(msg, level);
    }

    let pkg = detect_pkg_manager();
    let elapsed = 0;
    let attempt = 0;
    let last_holder = null;

    while (elapsed < timeout) {
        let holder = find_lock_holder();
        if (holder == null) {
            log_msg("Package manager lock acquired (no holder found after " + elapsed + "s)", "info");
            return { acquired: true, elapsed: elapsed, holder: null, message: "Lock acquired" };
        }
        last_holder = holder;
        if (is_stale_lock(holder)) {
            log_msg("Package manager lock holder PID " + holder.pid + " is dead (stale lock), waiting for kernel to release", "warn");
        } else {
            log_msg(sprintf("Waiting for %s database lock: owner PID=%s (%s) elapsed=%ds timeout=%ds",
                upper(pkg), holder.pid, holder.command, elapsed, timeout), "warn");
        }
        if (on_wait) on_wait(attempt, holder, elapsed);
        command_success([ "sleep", "2" ]);
        elapsed += 2;
        attempt++;
    }

    let error_msg;
    if (last_holder != null) {
        if (is_stale_lock(last_holder)) {
            error_msg = sprintf("FAILED: package database lock held by dead process PID=%s after %ds (stale lock)", last_holder.pid, elapsed);
        } else {
            error_msg = sprintf("FAILED: %s database remained locked for %ds by PID %s (%s)", upper(pkg), elapsed, last_holder.pid, last_holder.command);
        }
    } else {
        error_msg = sprintf("FAILED: package manager lock timeout after %ds (no holder identified)", elapsed);
    }
    log_msg(error_msg, "error");
    return { acquired: false, elapsed: elapsed, holder: last_holder, message: error_msg };
}

// ---------------------------------------------------------------------------
// Module exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        detect_pkg_manager,
        is_apk,
        detect_arch,
        installed,
        apk_installed,
        opkg_installed,
        version,
        installed_package_version: version,
        apk_version,
        apk_available_version,
        opkg_version,
        binary_installed,
        binary_version,
        detect_lock,
        find_lock_holder,
        is_stale_lock,
        wait_for_lock,
        DEFAULT_LOCK_TIMEOUT,
        LOCK_STALE_TTL
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";

if (mode == "installed")
    exit(installed(ARGV[1]) ? 0 : 1);
else if (mode == "apk-installed")
    exit(apk_installed(ARGV[1]) ? 0 : 1);
else if (mode == "opkg-installed")
    exit(opkg_installed(ARGV[1]) ? 0 : 1);
else if (mode == "version")
    print(version(ARGV[1]), "\n");
else if (mode == "apk-version")
    print(apk_version(ARGV[1]), "\n");
else if (mode == "apk-available-version")
    print(apk_available_version(ARGV[1]), "\n");
else if (mode == "opkg-version")
    print(opkg_version(ARGV[1]), "\n");
else if (mode == "detect") {
    let mgr = detect_pkg_manager();
    let arch = detect_arch();
    print(sprintf("%J\n", { package_manager: mgr, arch: arch }));
}
else if (mode == "lock-holder") {
    let holder = find_lock_holder();
    if (holder != null) print(sprintf("%J\n", holder));
    else print("null\n");
}
else if (mode == "detect-lock") {
    let output = ARGV[1] || "";
    let exit_code = int(ARGV[2] || 0);
    exit(detect_lock(output, exit_code) ? 0 : 1);
}
else if (mode == "wait-lock") {
    let timeout = int(ARGV[1] || DEFAULT_LOCK_TIMEOUT);
    let result = wait_for_lock({
        timeout: timeout,
        log_fn: function(msg, level) {
            system(command_from_args([ "logger", "-t", "tachyon.packages", "[" + as_string(level) + "] " + msg ]) + " >/dev/null 2>&1");
        }
    });
    print(sprintf("%J\n", result));
    exit(result.acquired ? 0 : 1);
}
else {
    warn("Usage: core/packages.uc <installed|apk-installed|opkg-installed|version|apk-version|apk-available-version|opkg-version|detect|lock-holder|detect-lock|wait-lock> ...\n");
    exit(1);
}
