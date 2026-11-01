#!/usr/bin/env ucode
//
// Package-manager transactions for component updates (apk/opkg).
//
// Owns lock-aware package transactions, index refreshes, name/file installs
// and sing-box dependency bootstrap. Sits on components/helpers.uc.
//

let fs = require("fs");
let common = require("core.common");

let helpers = require("components.helpers");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let write_file = common.write_file;
let bounded_command = common.bounded_command;
let command_env = helpers.command_env;
let command_output_lenient = helpers.command_output_lenient;
let command_exists = helpers.command_exists;
let file_exists = helpers.file_exists;
let file_nonempty = helpers.file_nonempty;
let remove_file = helpers.remove_file;
let make_tmp_file = helpers.make_tmp_file;
let now_seconds = helpers.now_seconds;
let owner_pid = helpers.owner_pid;
let updates_log = helpers.updates_log;
let update_job_phase = helpers.update_job_phase;
let job_heartbeat = helpers.job_heartbeat;
let is_apk = helpers.is_apk;
let pkg_is_installed = helpers.pkg_is_installed;
let sanitize_apk_world = helpers.sanitize_apk_world;
let service_proxy_address = helpers.service_proxy_address;
let stream_command_output = helpers.stream_command_output;
let normalize_stream_exit = helpers.normalize_stream_exit;
let detect_apk_lock = helpers.detect_apk_lock;
let diagnose_apk_lock_holder = helpers.diagnose_apk_lock_holder;
let run_logged = helpers.run_logged;
let init_tmp_dir = helpers.init_tmp_dir;

const PKG_TX_INDEX_TIMEOUT = int(getenv("TACHYON_PKG_TX_INDEX_TIMEOUT") || "60");
const PKG_TX_DEPS_TIMEOUT = int(getenv("TACHYON_PKG_TX_DEPS_TIMEOUT") || "90");
const PKG_TX_REMOVE_TIMEOUT = int(getenv("TACHYON_PKG_TX_REMOVE_TIMEOUT") || "90");
const PKG_TX_INSTALL_TIMEOUT = int(getenv("TACHYON_PKG_TX_INSTALL_TIMEOUT") || "180");
const PKG_LOCK_WAIT_MAX_SECONDS = int(getenv("TACHYON_PKG_LOCK_WAIT_MAX_SECONDS") || "60");
const JOB_HEARTBEAT_INTERVAL = int(getenv("TACHYON_JOB_HEARTBEAT_INTERVAL") || "5");
const APK_REPO_PROBE_TIMEOUT = int(getenv("TACHYON_APK_REPO_PROBE_TIMEOUT_SECONDS") || "5");

let _cached_apk_repos_file = null;

// ============================================================================
// Command builders
// ============================================================================

function probe_apk_repo_url(url, proxy_address) {
    url = as_string(url);
    let timeout_str = as_string(APK_REPO_PROBE_TIMEOUT);
    if (command_exists("curl")) {
        let curl_args = [ "curl", "--connect-timeout", timeout_str, "--max-time", timeout_str, "-fsSL", url, "-o", "/dev/null" ];
        let direct = bounded_command(command_from_args(curl_args), APK_REPO_PROBE_TIMEOUT);
        if (as_string(proxy_address) != "") {
            let p = "http://" + as_string(proxy_address);
            let proxied = bounded_command(command_env({ http_proxy: p, https_proxy: p, HTTP_PROXY: p, HTTPS_PROXY: p }) + " " + command_from_args(curl_args), APK_REPO_PROBE_TIMEOUT);
            if (command_success(proxied))
                return true;
        }
        return command_success(direct);
    }
    if (command_exists("wget")) {
        let wget_args = [ "wget", "-q", "-T", timeout_str, "-O", "/dev/null", url ];
        let direct = bounded_command(command_from_args(wget_args), APK_REPO_PROBE_TIMEOUT);
        if (as_string(proxy_address) != "") {
            let p = "http://" + as_string(proxy_address);
            let proxied = bounded_command(command_env({ http_proxy: p, https_proxy: p, HTTP_PROXY: p, HTTPS_PROXY: p }) + " " + command_from_args(wget_args), APK_REPO_PROBE_TIMEOUT);
            if (command_success(proxied))
                return true;
        }
        return command_success(direct);
    }
    return true;
}

function apk_filtered_repositories_file(proxy_address) {
    if (!is_apk())
        return "";
    if (_cached_apk_repos_file != null)
        return _cached_apk_repos_file;

    let repos_file = getenv("TACHYON_APK_REPOS_FILE") || "/etc/apk/repositories";
    let repos_dir = getenv("TACHYON_APK_REPOS_DIR") || "/etc/apk/repositories.d";
    let repo_files = [];
    if (file_exists(repos_file))
        push(repo_files, repos_file);
    for (let f in (fs.glob(repos_dir + "/*.list") || [])) {
        if (file_exists(f))
            push(repo_files, f);
    }
    if (length(repo_files) == 0) {
        _cached_apk_repos_file = "";
        return "";
    }

    let kept_lines = [];
    let host_status = {};
    let had_unreachable = false;

    for (let rf in repo_files) {
        let content = fs.readfile(rf);
        if (content == null)
            continue;
        for (let raw_line in split(as_string(content), "\n")) {
            let line = trim(as_string(raw_line));
            if (line == "" || substr(line, 0, 1) == "#")
                continue;
            let m = match(line, /^(https?:\/\/([^\/:]+)(:[0-9]+)?)\//i);
            if (!m) {
                push(kept_lines, line);
                continue;
            }
            let origin = lc(as_string(m[1]));
            if (host_status[origin] == false)
                continue;
            let ok = probe_apk_repo_url(line, proxy_address);
            if (ok) {
                host_status[origin] = true;
                push(kept_lines, line);
            } else {
                had_unreachable = true;
                if (host_status[origin] == null)
                    host_status[origin] = false;
                updates_log("WARNING: updating " + line + ": repository unreachable", "warn");
            }
        }
    }

    if (!had_unreachable) {
        _cached_apk_repos_file = "";
        return "";
    }

    let out_path = make_tmp_file("apk-repos");
    if (out_path == "")
        out_path = "/tmp/tachyon-apk-repos." + owner_pid() + ".list";
    let body = length(kept_lines) > 0 ? (join("\n", kept_lines) + "\n") : "";
    write_file(out_path, body);
    _cached_apk_repos_file = out_path;
    return out_path;
}

function apk_satisfy_missing_files_deps(files) {
    if (!is_apk() || type(files) != "array" || length(files) == 0)
        return false;
    for (let f in files) {
        if (!file_exists(f))
            return false;
    }
    sanitize_apk_world();
    let sim_args = [ "apk", "add", "--simulate", "--allow-untrusted", "--force-overwrite", "--no-network", "--repositories-file", "/dev/null" ];
    for (let f in files)
        push(sim_args, f);
    let sim_out = command_output_lenient(command_from_args(sim_args) + " 2>&1");
    let seen = {};
    let added = false;
    for (let line in split(sim_out, "\n")) {
        let m = match(as_string(line), /^[ \t]*([A-Za-z0-9._+-]+)[ \t]*\(no such package\):/);
        if (!m || !m[1])
            continue;
        let dep = as_string(m[1]);
        if (seen[dep] == true)
            continue;
        seen[dep] = true;
        updates_log("Package dependency " + dep + " is unavailable in repositories; registering virtual placeholder", "warn");
        if (command_success(command_from_args([ "apk", "add", "--no-network", "--repositories-file", "/dev/null", "--force-non-repository", "--virtual", dep ]) + " </dev/null"))
            added = true;
    }
    return added;
}

function apk_can_install_files_offline(files) {
    if (type(files) != "array" || length(files) == 0)
        return true;
    for (let f in files) {
        if (!file_exists(f))
            return true;
    }
    sanitize_apk_world();
    let sim_args = [ "apk", "add", "--simulate", "--allow-untrusted", "--force-overwrite", "--no-network", "--repositories-file", "/dev/null" ];
    for (let f in files)
        push(sim_args, f);
    return command_success_from_args(sim_args);
}

function pkg_list_update_command(proxy_address) {
    if (proxy_address == null)
        proxy_address = service_proxy_address();
    let direct_cmd;
    if (is_apk()) {
        let update_args = [ "apk", "update" ];
        let repos_file = apk_filtered_repositories_file(proxy_address);
        if (repos_file != "")
            push(update_args, "--repositories-file", repos_file);
        push(update_args, "--force-missing-repositories", "--timeout", "15");
        direct_cmd = command_from_args(update_args) + " </dev/null";
    } else {
        direct_cmd = "opkg update </dev/null";
    }
    if (as_string(proxy_address) != "") {
        let p = "http://" + proxy_address;
        let proxied_cmd = command_env({ http_proxy: p, https_proxy: p, HTTP_PROXY: p, HTTPS_PROXY: p }) + " " + direct_cmd;
        return "(" + proxied_cmd + " || " + direct_cmd + ")";
    }
    return direct_cmd;
}

function pkg_install_name_command(package_name, proxy_address) {
    if (proxy_address == null)
        proxy_address = service_proxy_address();
    let cmd;
    if (is_apk()) {
        let add_args = [ "apk", "add" ];
        let repos_file = apk_filtered_repositories_file(proxy_address);
        if (repos_file != "")
            push(add_args, "--repositories-file", repos_file);
        push(add_args, "--force-missing-repositories", "--timeout", "15", package_name);
        cmd = command_from_args(add_args) + " </dev/null";
    } else {
        cmd = command_from_args([ "opkg", "install", package_name ]) + " </dev/null";
    }
    if (as_string(proxy_address) != "") {
        let p = "http://" + proxy_address;
        cmd = command_env({ http_proxy: p, https_proxy: p, HTTP_PROXY: p, HTTPS_PROXY: p }) + " " + cmd;
    }
    return cmd;
}

function pkg_install_name_downgrade(package_name, package_version) {
    package_name = as_string(package_name);
    if (is_apk()) {
        package_version = as_string(package_version);
        if (package_version == "")
            return false;
        let package_spec = package_name + "=" + package_version;
        let add_args = [ "apk", "add" ];
        let repos_file = apk_filtered_repositories_file(null);
        if (repos_file != "")
            push(add_args, "--repositories-file", repos_file, "--force-missing-repositories", "--timeout", "15");
        push(add_args, package_spec);
        if (pkg_is_installed(package_name)) {
            command_success(command_from_args(add_args) + " </dev/null");
            let fix_args = [ "apk", "fix", "--reinstall", "--upgrade" ];
            if (repos_file != "")
                push(fix_args, "--repositories-file", repos_file, "--force-missing-repositories", "--timeout", "15");
            push(fix_args, package_name);
            return command_success(command_from_args(fix_args) + " </dev/null");
        }
        return command_success(command_from_args(add_args) + " </dev/null");
    }

    return command_success(command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_name ]) + " </dev/null") ||
        command_success(command_from_args([ "opkg", "install", "--force-downgrade", package_name ]) + " </dev/null");
}

function pkg_install_files_command(files, force_reinstall) {
    if (is_apk()) {
        sanitize_apk_world();
        let add_args = [ "apk", "add", "--allow-untrusted", "--force-overwrite" ];
        if (apk_can_install_files_offline(files)) {
            push(add_args, "--no-network", "--repositories-file", "/dev/null");
        } else {
            let repos_file = apk_filtered_repositories_file(null);
            if (repos_file != "" && !file_nonempty(repos_file)) {
                apk_satisfy_missing_files_deps(files);
                push(add_args, "--no-network", "--repositories-file", "/dev/null");
            } else {
                if (repos_file != "")
                    push(add_args, "--repositories-file", repos_file);
                push(add_args, "--force-missing-repositories", "--timeout", "15");
            }
        }
        for (let file in files)
            push(add_args, file);
        return command_from_args(add_args) + " </dev/null";
    }
    let args = [ "opkg", "install", "--force-overwrite", "--force-downgrade", "--force-depends" ];
    if (force_reinstall)
        push(args, "--force-reinstall");
    for (let file in files)
        push(args, file);
    return command_from_args(args) + " </dev/null";
}

// ============================================================================
// Lock-aware transactions
// ============================================================================

function pkg_tx_run_with_lock(description, command, timeout_seconds) {
    update_job_phase("waiting_package_lock", "Waiting for package manager lock");
    let lock_waited = 0;
    let attempt = 0;
    let max_lock_attempts = 12;
    while (attempt < max_lock_attempts) {
        if (attempt > 0) {
            if (is_apk()) {
                updates_log("APK database still locked (" + lock_waited + "s), waiting...");
            } else {
                updates_log("opkg lock still held (" + lock_waited + "s), waiting...");
            }
            job_heartbeat();
            command_success("sleep 5");
            lock_waited += 5;
            if (lock_waited >= PKG_LOCK_WAIT_MAX_SECONDS) {
                updates_log("Package manager lock timeout after " + lock_waited + "s", "error");
                if (is_apk())
                    diagnose_apk_lock_holder();
                return { success: false, exit_code: 227, message: "Package manager lock timeout after " + lock_waited + "s" };
            }
        }
        let pipe_cmd = command + " 2>&1";
        let pipe = fs.popen(pipe_cmd, "r");
        if (!pipe) {
            attempt++;
            continue;
        }
        let output_lines = [];
        let last_activity = now_seconds();
        let last_heartbeat = now_seconds();
        while (true) {
            let line = pipe.read("line");
            if (line == null)
                break;
            line = trim(as_string(line));
            if (line != "") {
                updates_log(line);
                push(output_lines, line);
                if (length(output_lines) > 200)
                    shift(output_lines);
                last_activity = now_seconds();
            }
            // Periodic heartbeat during long operations
            if (now_seconds() - last_heartbeat >= JOB_HEARTBEAT_INTERVAL) {
                job_heartbeat();
                last_heartbeat = now_seconds();
            }
            if (now_seconds() - last_activity > timeout_seconds) {
                updates_log("Package operation timed out after " + timeout_seconds + "s of inactivity", "error");
                pipe.close();
                return { success: false, exit_code: -1, message: "Package operation timed out" };
            }
        }
        let close_status = pipe.close();
        let rc = normalize_stream_exit(close_status);
        if (rc == 0) {
            update_job_phase("package_transaction", "Package transaction completed");
            return { success: true, exit_code: 0, message: "" };
        }
        let output_text = join("\n", output_lines);
        let is_locked = detect_apk_lock(output_text, rc);
        if (attempt == 0 && is_locked)
            diagnose_apk_lock_holder();
        if (!is_locked) {
            let err_msg = "Package operation failed with exit code " + rc;
            if (length(output_lines) > 0)
                err_msg += ": " + output_lines[length(output_lines) - 1];
            return { success: false, exit_code: rc, message: err_msg };
        }
        attempt++;
    }
    return { success: false, exit_code: 227, message: "Package manager lock retry limit exceeded" };
}

function pkg_tx_remove(package_name, description) {
    update_job_phase("package_transaction", description || ("Removing " + package_name));
    let cmd;
    if (is_apk()) {
        cmd = command_from_args([ "apk", "del", "--no-network", "--repositories-file", "/dev/null", "--force-broken-world", package_name ]) + " </dev/null";
    } else {
        cmd = command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    }
    return pkg_tx_run_with_lock(description || ("Removing " + package_name), cmd, PKG_TX_REMOVE_TIMEOUT);
}

function pkg_tx_downgrade(package_name, package_version) {
    package_name = as_string(package_name);
    package_version = as_string(package_version);
    update_job_phase("package_transaction", "Downgrading " + package_name + " to " + package_version);
    let cmd;
    if (is_apk()) {
        if (package_version == "")
            return { success: false, exit_code: 1, message: "Version required for APK downgrade" };
        let package_spec = package_name + "=" + package_version;
        let add_args = [ "apk", "add" ];
        let repos_file = apk_filtered_repositories_file(null);
        if (repos_file != "")
            push(add_args, "--force-missing-repositories", "--timeout", "15", "--repositories-file", repos_file);
        push(add_args, package_spec);
        if (pkg_is_installed(package_name)) {
            let fix_args = [ "apk", "fix", "--reinstall", "--upgrade" ];
            if (repos_file != "")
                push(fix_args, "--force-missing-repositories", "--timeout", "15", "--repositories-file", repos_file);
            push(fix_args, package_name);
            cmd = command_from_args(add_args) + " </dev/null && " + command_from_args(fix_args) + " </dev/null";
        } else {
            cmd = command_from_args(add_args) + " </dev/null";
        }
    } else {
        cmd = command_from_args([ "opkg", "install", "--force-overwrite", "--force-reinstall", "--force-downgrade", package_name ]) + " </dev/null";
    }
    return pkg_tx_run_with_lock("Downgrading " + package_name, cmd, PKG_TX_INSTALL_TIMEOUT);
}

function pkg_tx_update_index(proxy_address) {
    sanitize_apk_world();
    let cmd = pkg_list_update_command(proxy_address);
    update_job_phase("package_index", "Refreshing package index");
    let rc = stream_command_output(cmd, "Updating package index");
    if (rc != 0)
        updates_log("Package index update failed with exit code " + rc, "warn");
    return rc == 0;
}

function pkg_tx_install_files(files, force_reinstall) {
    sanitize_apk_world();
    update_job_phase("package_transaction", "Installing package files");
    let cmd = pkg_install_files_command(files, force_reinstall);
    let res = pkg_tx_run_with_lock("Installing packages", cmd, PKG_TX_INSTALL_TIMEOUT);
    if (!res.success && is_apk() && apk_satisfy_missing_files_deps(files)) {
        let offline_args = [ "apk", "add", "--allow-untrusted", "--force-overwrite", "--no-network", "--repositories-file", "/dev/null" ];
        for (let file in files)
            push(offline_args, file);
        let offline_cmd = command_from_args(offline_args) + " </dev/null";
        res = pkg_tx_run_with_lock("Installing packages (offline fallback)", offline_cmd, PKG_TX_INSTALL_TIMEOUT);
    }
    return res;
}

// force_reinstall matters only for opkg: installing an .ipk whose version equals
// the installed one is a no-op unless --force-reinstall is passed, so a rebuild
// published under the same tag would silently not be applied. apk always writes
// the file it is handed, so its argument list stays untouched.
// IMPORTANT: No fallback to raw tar/apk-extract. Package manager failure means
// the operation must fail. Direct extraction bypasses package DB, maintainer
// scripts, and dependency tracking.
function pkg_tx_install_name(package_name, proxy_address) {
    sanitize_apk_world();
    update_job_phase("package_transaction", "Installing " + package_name);
    let cmd = pkg_install_name_command(package_name, proxy_address);
    return pkg_tx_run_with_lock("Installing " + package_name, cmd, PKG_TX_DEPS_TIMEOUT);
}

function pkg_install_files(files, force_reinstall) {
    init_tmp_dir();
    let result = pkg_tx_install_files(files, force_reinstall);
    return result.success;
}

// ============================================================================
// Conflict removal and dependency bootstrap
// ============================================================================

function pkg_remove_sing_box_conflict(package_name) {
    package_name = as_string(package_name);
    if (is_apk()) {
        if (file_exists("/etc/apk/world"))
            command_success("sed -i -E " + shell_quote("/^" + package_name + "([><= ].*)?$/d") + " /etc/apk/world 2>/dev/null");
        if (!pkg_is_installed(package_name))
            return true;
        return command_success(command_from_args([ "apk", "del", "--no-network", "--repositories-file", "/dev/null", "--force-broken-world", package_name ]) + " </dev/null");
    }
    if (!pkg_is_installed(package_name))
        return true;
    return command_success(command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null");
}

function run_logged_pkg_remove_sing_box_conflict(package_name, description) {
    if (is_apk() && file_exists("/etc/apk/world"))
        command_success("sed -i -E " + shell_quote("/^" + package_name + "([><= ].*)?$/d") + " /etc/apk/world 2>/dev/null");

    if (!pkg_is_installed(package_name)) {
        updates_log(description);
        return true;
    }

    let command = is_apk() ?
        command_from_args([ "apk", "del", "--no-network", "--repositories-file", "/dev/null", "--force-broken-world", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    return run_logged(description, command, 60);
}

function ensure_package_tool(tool_name, package_name, component, action) {
    if (command_exists(tool_name))
        return true;
    run_logged("Updating package lists before installing " + as_string(package_name), pkg_list_update_command(), 30);
    return run_logged("Installing bootstrap package " + as_string(package_name), pkg_install_name_command(package_name), 60);
}

function ensure_sing_box_dependencies() {
    let kmods = [ "kmod-inet-diag", "kmod-netlink-diag", "kmod-tun", "kmod-nft-tproxy", "kmod-nft-nat", "ca-bundle" ];
    let missing = [];
    for (let kmod in kmods) {
        if (!pkg_is_installed(kmod)) {
            if (kmod == "kmod-tun" && file_exists("/dev/net/tun"))
                continue;
            push(missing, kmod);
        }
    }

    if (length(missing) > 0) {
        updates_log("Installing missing dependencies for tachyon-core: " + join(", ", missing));
        run_logged("Updating package lists for tachyon-core dependencies", pkg_list_update_command(), 30);

        for (let kmod in missing) {
            if (!run_logged("Installing dependency " + kmod, pkg_install_name_command(kmod), 60)) {
                if (kmod == "kmod-tun" && file_exists("/dev/net/tun"))
                    continue;
                updates_log("Could not install " + kmod + " (may be built-in or custom firmware)", "warn");
            }
        }
    }

    command_success_from_args([ "modprobe", "tun" ]);
    command_success_from_args([ "modprobe", "inet_diag" ]);
    command_success_from_args([ "modprobe", "netlink_diag" ]);
    command_success_from_args([ "modprobe", "nft_tproxy" ]);
    command_success_from_args([ "modprobe", "nft_nat" ]);
    if (!file_exists("/dev/net/tun")) {
        command_success_from_args([ "mkdir", "-p", "/dev/net" ]);
        command_success_from_args([ "mknod", "/dev/net/tun", "c", "10", "200" ]);
        command_success_from_args([ "chmod", "0666", "/dev/net/tun" ]);
    }
    return true;
}

// Forward-referenced helpers

function module_exports() {
    return {
        apk_filtered_repositories_file,
        apk_satisfy_missing_files_deps,
        pkg_list_update_command,
        pkg_install_name_command,
        pkg_install_name_downgrade,
        pkg_install_files_command,
        pkg_tx_run_with_lock,
        pkg_tx_remove,
        pkg_tx_downgrade,
        pkg_tx_update_index,
        pkg_tx_install_files,
        pkg_tx_install_name,
        pkg_install_files,
        pkg_remove_sing_box_conflict,
        run_logged_pkg_remove_sing_box_conflict,
        ensure_package_tool,
        ensure_sing_box_dependencies
    };
}

return module_exports();
