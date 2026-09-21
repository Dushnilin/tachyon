#!/usr/bin/env ucode

let fs = require("fs");
let helpers = require("core.helpers");
let constants = require("core.constants");
let uci_core = require("core.uci");
let common = require("core.common");
let cmp = require("components.helpers");
let cmp_ver = require("components.versions");
let cmp_verify = require("components.verifier");
let cmp_dl = require("components.downloader");
let cmp_inst = require("components.installer");
let cmp_cat = require("components.catalog");

function core_url_module_or_null() {
    try {
        return require("core.url");
    } catch (e) {
        return null;
    }
}

const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const BIN_PATH = getenv("TACHYON_BIN") || constants.TACHYON_BIN || "/usr/bin/tachyon";
const SERVICE_INIT = getenv("TACHYON_SERVICE_INIT") || constants.TACHYON_SERVICE_INIT || "/etc/init.d/tachyon";
const TACHYON_VERSION = getenv("TACHYON_VERSION") || constants.TACHYON_VERSION || "";
const TACHYON_COMMIT_SHA = getenv("TACHYON_COMMIT_SHA") || constants.TACHYON_COMMIT_SHA || "";
const TACHYON_RELEASE_REPO = getenv("TACHYON_RELEASE_REPO") || constants.TACHYON_RELEASE_REPO || "Dushnilin/tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const SYSTEM_INFO_CACHE_FILE = getenv("TACHYON_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
// Persistent, not RUNTIME_STATE_DIR: the fingerprint describes the build that is
// on disk, so it has to survive a reboot the same way the package does.
const TACHYON_BUILD_STATE_FILE = getenv("TACHYON_BUILD_STATE_FILE") || "/etc/.tachyon/build-state";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const SB_MANAGED_SERVICE_MARKER = getenv("SB_MANAGED_SERVICE_MARKER") || constants.SB_MANAGED_SERVICE_MARKER || "Tachyon managed sing-box service for binary variants";
const TAILSCALE_PACKAGE_URL = getenv("TAILSCALE_PACKAGE_URL") || "https://openwrt.org/packages/pkgdata/tailscale";

const PKG_TX_INDEX_TIMEOUT = int(getenv("TACHYON_PKG_TX_INDEX_TIMEOUT") || "60");
const PKG_TX_DEPS_TIMEOUT = int(getenv("TACHYON_PKG_TX_DEPS_TIMEOUT") || "90");
const PKG_TX_REMOVE_TIMEOUT = int(getenv("TACHYON_PKG_TX_REMOVE_TIMEOUT") || "90");
const PKG_TX_INSTALL_TIMEOUT = int(getenv("TACHYON_PKG_TX_INSTALL_TIMEOUT") || "180");
const PKG_TX_SELF_UPDATE_TIMEOUT = int(getenv("TACHYON_PKG_TX_SELF_UPDATE_TIMEOUT") || "420");
const PKG_LOCK_WAIT_MAX_SECONDS = int(getenv("TACHYON_PKG_LOCK_WAIT_MAX_SECONDS") || "60");
const JOB_HEARTBEAT_INTERVAL = int(getenv("TACHYON_JOB_HEARTBEAT_INTERVAL") || "5");
const JOB_HARD_DEADLINE_SECONDS = int(getenv("TACHYON_JOB_HARD_DEADLINE_SECONDS") || "900");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_status_from_args = common.command_status_from_args;
let command_success = common.command_success;
let command_success_from_args = common.command_success_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let write_json = common.write_json;
let write_file = common.write_file;
let bounded_command = common.bounded_command;
let kill_matching_command = common.kill_matching_command;

let lock_held = false;
let tachyon_was_running = false;
let tachyon_stopped_for_sing_box_change = false;

// ============================================================================
// Helper constants and functions hoisted to avoid forward references
// ============================================================================

const SING_BOX_BIN = getenv("TACHYON_SING_BOX_BIN") || "/usr/bin/sing-box";
const COMPONENT_BACKUP_BASE_DIR = getenv("TACHYON_COMPONENT_BACKUPS_DIR") || "/etc/tachyon/component-backups";

function get_component_backup_enabled() { return cmp.get_component_backup_enabled(); }

function check_free_disk_space(target_dir, needed_bytes) { return cmp.check_free_disk_space(target_dir, needed_bytes); }

// ============================================================================

// Delegated to components/* modules (branch 4 god-module split).
function str_startswith(value, prefix) { return cmp.str_startswith(value, prefix); }
function command_env(assignments) { return cmp.command_env(assignments); }
function command_output_lenient(command) { return cmp.command_output_lenient(command); }
function command_exists(name) { return cmp.command_exists(name); }
function read_file(path) { return cmp.read_file(path); }
function remove_file(path) { return cmp.remove_file(path); }
function ensure_dir(path) { return cmp.ensure_dir(path); }
function file_exists(path) { return cmp.file_exists(path); }
function file_nonempty(path) { return cmp.file_nonempty(path); }
function path_basename(path) { return cmp.path_basename(path); }
function now_seconds() { return cmp.now_seconds(); }
function owner_pid() { return cmp.owner_pid(); }
function pid_running(pid) { return cmp.pid_running(pid); }
function log_message(message, level) { return cmp.log_message(message, level); }
function job_log_time() { return cmp.job_log_time(); }
function job_log_append(message, level) { return cmp.job_log_append(message, level); }
function updates_log(message, level) { return cmp.updates_log(message, level); }
function update_job_phase(phase, message) { return cmp.update_job_phase(phase, message); }
function job_heartbeat() { return cmp.job_heartbeat(); }
function free_kb(path) { return cmp.free_kb(path); }
function preflight_storage_check(component, asset_size_bytes, backup_required) { return cmp.preflight_storage_check(component, asset_size_bytes, backup_required); }
function preflight_backup_space_check(component) { return cmp.preflight_backup_space_check(component); }
function normalize_stream_exit(close_status) { return cmp.normalize_stream_exit(close_status); }
function stream_command_output(command, description) { return cmp.stream_command_output(command, description); }
function detect_apk_lock(output_text, exit_code) { return cmp.detect_apk_lock(output_text, exit_code); }
function diagnose_apk_lock_holder() { return cmp.diagnose_apk_lock_holder(); }
function module_command(args) { return cmp.module_command(args); }
function module_output(args) { return cmp.module_output(args); }
function module_success(args) { return cmp.module_success(args); }
function helper_output(mode, args) { return cmp.helper_output(mode, args); }
function helper_success(mode, args) { return cmp.helper_success(mode, args); }
function cleanup_stale_tmp_files() { return cmp.cleanup_stale_tmp_files(); }
function init_tmp_dir() { return cmp.init_tmp_dir(); }
function make_tmp_file(prefix) { return cmp.make_tmp_file(prefix); }
function helper_output_input(input, mode, args) { return cmp.helper_output_input(input, mode, args); }
function helper_success_input(input, mode, args) { return cmp.helper_success_input(input, mode, args); }
function cleanup_tmp_dir() { return cmp.cleanup_tmp_dir(); }


function acquire_component_lock() {
    if (lock_held)
        return true;
    ensure_dir(RUNTIME_STATE_DIR);
    if (command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ])) {
        write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
        lock_held = true;
        return true;
    }

    let current_owner = trim(read_file(COMPONENT_LOCK_DIR + "/pid"));
    let lock_stat = fs.stat(COMPONENT_LOCK_DIR + "/pid") || fs.stat(COMPONENT_LOCK_DIR);
    let lock_age = (lock_stat && lock_stat.mtime) ? (now_seconds() - lock_stat.mtime) : 9999;

    if (current_owner != "" && pid_running(current_owner) && lock_age < 300)
        return false;

    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rm", "-rf", COMPONENT_LOCK_DIR ]);
    if (!command_success_from_args([ "mkdir", COMPONENT_LOCK_DIR ]))
        return false;

    write_file(COMPONENT_LOCK_DIR + "/pid", owner_pid() + "\n");
    lock_held = true;
    return true;
}

function release_component_lock() {
    if (!lock_held)
        return;
    remove_file(COMPONENT_LOCK_DIR + "/pid");
    command_success_from_args([ "rm", "-rf", COMPONENT_LOCK_DIR ]);
    lock_held = false;
}

function cleanup_action() {
    cleanup_tmp_dir();
    release_component_lock();
}

function updates_response(success, component, action, message, current_version, latest_version, changed, status, release_url, extra) {
    let obj = {
        success: !!success,
        kind: "component",
        component: as_string(component),
        action: as_string(action),
        message: as_string(message),
        current_version: as_string(current_version),
        latest_version: as_string(latest_version),
        changed: int(changed || 0),
        status: as_string(status),
        release_url: as_string(release_url)
    };
    // Merge optional extra fields (e.g. current_sha, latest_sha) without breaking existing callers
    if (type(extra) == "object") {
        for (let k, v in extra)
            obj[k] = v;
    }
    write_json(obj);
}

function restart_tachyon_after_failed_sing_box_change() {
    if (!tachyon_stopped_for_sing_box_change || !tachyon_was_running || !file_exists(SERVICE_INIT))
        return;
    updates_log("Restarting Tachyon after failed sing-box component change");
    if (!command_success_from_args([ SERVICE_INIT, "start" ]))
        command_success_from_args([ SERVICE_INIT, "restart" ]);
}

function action_success(component, action, message, current_version, latest_version, changed, status, release_url, extra) {
    updates_response(true, component, action, message, current_version, latest_version, changed || 0, status || "", release_url || "", extra || null);
    cleanup_action();
    exit(0);
}

function action_fail(component, action, message, current_version, latest_version, status, release_url) {
    updates_log(message, "error");
    restart_tachyon_after_failed_sing_box_change();
    updates_response(false, component, action, message, current_version || "", latest_version || "", 0, status || "", release_url || "");
    cleanup_action();
    exit(1);
}

// Delegated to components/* modules (branch 4 god-module split).
function run_logged(description, command, timeout_seconds) { return cmp.run_logged(description, command, timeout_seconds); }
function is_apk() { return cmp.is_apk(); }


// Delegated to components/installer.uc (branch 4 god-module split).
function pkg_tx_run_with_lock(description, command, timeout_seconds) { return cmp_inst.pkg_tx_run_with_lock(description, command, timeout_seconds); }

function pkg_tx_remove(package_name, description) { return cmp_inst.pkg_tx_remove(package_name, description); }

function pkg_is_installed(package_name) { return cmp.pkg_is_installed(package_name); }


// Delegated to components/installer.uc (branch 4 god-module split).
function pkg_tx_downgrade(package_name, package_version) { return cmp_inst.pkg_tx_downgrade(package_name, package_version); }

function installed_package_version(package_name) { return cmp_ver.installed_package_version(package_name); }
function verify_package_post_install(package_name, expected_version) { return cmp_verify.verify_package_post_install(package_name, expected_version); }
function opkg_package_version_from_list(package_name, output) { return cmp_ver.opkg_package_version_from_list(package_name, output); }
function available_package_version(package_name) { return cmp_ver.available_package_version(package_name); }
function service_proxy_address() { return cmp.service_proxy_address(); }

function pkg_list_update_command(proxy_address) { return cmp_inst.pkg_list_update_command(proxy_address); }

function pkg_install_name_command(package_name, proxy_address) { return cmp_inst.pkg_install_name_command(package_name, proxy_address); }

function pkg_install_name_downgrade(package_name, package_version) { return cmp_inst.pkg_install_name_downgrade(package_name, package_version); }

function pkg_install_files_command(files, force_reinstall) { return cmp_inst.pkg_install_files_command(files, force_reinstall); }
function sanitize_apk_world() { return cmp.sanitize_apk_world(); }

function pkg_tx_update_index(proxy_address) { return cmp_inst.pkg_tx_update_index(proxy_address); }

function pkg_tx_install_files(files, force_reinstall) { return cmp_inst.pkg_tx_install_files(files, force_reinstall); }

function pkg_tx_install_name(package_name, proxy_address) { return cmp_inst.pkg_tx_install_name(package_name, proxy_address); }

function pkg_install_files(files, force_reinstall) { return cmp_inst.pkg_install_files(files, force_reinstall); }
function run_logged_retrying(description, command) { return cmp.run_logged_retrying(description, command); }

function pkg_remove_sing_box_conflict(package_name) { return cmp_inst.pkg_remove_sing_box_conflict(package_name); }
function run_logged_pkg_remove_sing_box_conflict(package_name, description) { return cmp_inst.run_logged_pkg_remove_sing_box_conflict(package_name, description); }
function compare_versions(lhs, rhs) { return cmp_ver.compare_versions(lhs, rhs); }
function status_from_compare(compare_result) { return cmp_ver.status_from_compare(compare_result); }



function check_success_compared(component, current_version, latest_version, compare_current_version, compare_latest_version, release_url) {
    let compare_result = compare_versions(compare_current_version, compare_latest_version);
    if (compare_result == null)
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let status = status_from_compare(compare_result);
    if (status == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let result_row = trim(helper_output("updates-check-result-row", [ component, current_version, latest_version, status ]));
    if (result_row == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let fields = split(result_row, "\t");
    let message = as_string(fields[0] || "");
    let log_line = length(fields) > 1 ? as_string(fields[1]) : message;
    updates_log(log_line);
    action_success(component, "check_update", message, current_version, latest_version, 0, status, release_url || "");
}

function check_success(component, current_version, latest_version, release_url) {
    check_success_compared(component, current_version, latest_version, current_version, latest_version, release_url || "");
}

// Delegated to components/* modules (branch 4 god-module split).
function read_openwrt_release_value(key) { return cmp.read_openwrt_release_value(key); }

function http_get_once(url, output_path, proxy_address, timeout) { return cmp_dl.http_get_once(url, output_path, proxy_address, timeout); }
function http_get(url, timeout) { return cmp_dl.http_get(url, timeout); }
function download_file_once(url, output_path) { return cmp_dl.download_file_once(url, output_path); }
function download_with_retry(url, output_path, label) { return cmp_dl.download_with_retry(url, output_path, label); }
function fetch_github_release_json(owner, repo) { return cmp_dl.fetch_github_release_json(owner, repo); }
function fetch_github_release_by_tag_json(owner, repo, tag) { return cmp_dl.fetch_github_release_by_tag_json(owner, repo, tag); }
function fetch_github_tag_commit_sha(owner, repo, tag) { return cmp_dl.fetch_github_tag_commit_sha(owner, repo, tag); }

function format_fingerprint_human(fp) { return cmp_verify.format_fingerprint_human(fp); }

function fetch_github_releases_json(owner, repo, per_page) { return cmp_dl.fetch_github_releases_json(owner, repo, per_page); }


// Delegated to components/catalog.uc (branch 4 god-module split).
function latest_tachyon_release_json() { return cmp_cat.latest_tachyon_release_json(); }

// Delegated to components/* modules (branch 4 god-module split).
function fetch_github_release_tag_fallback(owner, repo) { return cmp_dl.fetch_github_release_tag_fallback(owner, repo); }
function url_exists(url) { return cmp_dl.url_exists(url); }


// Delegated to components/catalog.uc (branch 4 god-module split).
function latest_tachyon_version() { return cmp_cat.latest_tachyon_version(); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function fetch_tachyon_latest_release_metadata() { return cmp_cat.fetch_tachyon_latest_release_metadata(); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function write_tachyon_latest_version_cache(value, timestamp) { return cmp_cat.write_tachyon_latest_version_cache(value, timestamp); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function read_tachyon_build_fingerprint() { return cmp_cat.read_tachyon_build_fingerprint(); }

// A release tag can be rebuilt, so the version alone cannot answer "is the build
// on disk the build the release publishes now?". The fingerprint recorded at
// install time answers it, including for releases that carry no commit SHA.
// Delegated to components/catalog.uc (branch 4 god-module split).
function write_tachyon_build_fingerprint(version, fingerprint) { return cmp_cat.write_tachyon_build_fingerprint(version, fingerprint); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function record_tachyon_installed_build(version, release_ctx) { return cmp_cat.record_tachyon_installed_build(version, release_ctx); }

// Called after a successful install/reinstall. Uses the release context from the
// operation rather than re-fetching latest release metadata. This is critical
// for install_version where the installed tag may differ from the latest release.
// release_ctx is an optional object with {source_sha, fingerprint} from the resolved release.
// Delegated to components/catalog.uc (branch 4 god-module split).
function retry_resolve(description, fn) { return cmp_cat.retry_resolve(description, fn); }

// Delegated to components/installer.uc (branch 4 god-module split).
function ensure_package_tool(tool_name, package_name, component, action) { return cmp_inst.ensure_package_tool(tool_name, package_name, component, action); }
function ensure_sing_box_dependencies() { return cmp_inst.ensure_sing_box_dependencies(); }


// Delegated to components/catalog.uc (branch 4 god-module split).
function clear_version_caches() { return cmp_cat.clear_version_caches(); }

function managed_sing_box_service_installed() {
    let data = fs.readfile("/etc/init.d/sing-box");
    return data != null && index(as_string(data), SB_MANAGED_SERVICE_MARKER) >= 0 && index(as_string(data), "GOGC=\"50\"") >= 0;
}

function managed_sing_box_service_text() {
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + SB_MANAGED_SERVICE_MARKER + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/sing-box\"\n\n" +
        "start_service() {\n" +
        "    [ -d /dev/net ] || mkdir -p /dev/net\n" +
        "    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true\n" +
        "    modprobe tun 2>/dev/null || true\n" +
        "    modprobe inet_diag 2>/dev/null || true\n\n" +
        "    config_load \"sing-box\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/sing-box/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/sing-box\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param file \"$config_file\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"unlimited\"\n" +
        "    procd_set_param limits nofile=\"1000000 1000000\"\n" +
        "    procd_set_param env GODEBUG=\"madvdontneed=1\" GOGC=\"50\"\n" +
        "    procd_set_param term_timeout 15\n" +
        "    procd_set_param respawn\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"sing-box\"\n" +
        "}\n";
}

function install_managed_sing_box_service_script() {
    let tmp = "/etc/init.d/sing-box.tachyon." + owner_pid();
    if (!write_file(tmp, managed_sing_box_service_text()))
        return false;
    if (!command_success_from_args([ "chmod", "0755", tmp ])) {
        remove_file(tmp);
        return false;
    }
    return fs.rename(tmp, "/etc/init.d/sing-box");
}

function remove_managed_sing_box_service_script() {
    if (!managed_sing_box_service_installed())
        return true;
    command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
    command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    remove_file("/etc/init.d/sing-box");
    return true;
}

function disable_sing_box_service_config() {
    if (!uci_core.available())
        return true;
    if (!uci_core.exists("sing-box.main") && !uci_core.set_section("sing-box.main", "sing-box"))
        return false;
    if (!uci_core.set("sing-box.main.enabled", "0"))
        return false;
    return uci_core.commit("sing-box");
}

function prepare_sing_box_service_disabled() {
    disable_sing_box_service_config();
    if (file_exists("/etc/init.d/sing-box")) {
        command_success_from_args([ "/etc/init.d/sing-box", "stop" ]);
        command_success_from_args([ "/etc/init.d/sing-box", "disable" ]);
    }
}

function prepare_sing_box_package_service_install() {
    prepare_sing_box_service_disabled();
    remove_managed_sing_box_service_script();
}

function tachyon_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("tachyon-status");
    if (output_file == "")
        return false;

    let command = command_from_args([ BIN_PATH, "get_status" ]) + " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
        "( sleep 6; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    let ok = command_status("sh -c " + shell_quote(command)) == 0 &&
        match(read_file(output_file), /"running"[ \t]*:[ \t]*1/) != null;
    remove_file(output_file);
    return ok;
}

function capture_tachyon_running_state() {
    tachyon_was_running = file_exists(BIN_PATH) && tachyon_status_running_with_timeout();
}

function restart_tachyon_after_successful_change() {
    if (!tachyon_was_running) {
        updates_log("Tachyon was not running before component change; restart skipped");
        prepare_sing_box_service_disabled();
        return;
    }

    // Clear any stuck flock holders or pending rc.common waits
    system(kill_matching_command("-E '99-tachyon-wan|flock 1000|init[.]d/tachyon'"));
    // Kill orphaned logread -f processes before restart to prevent FD cascade.
    // Anchor with $ to avoid killing system logremote/logfile processes (which
    // have extra flags like -r/-F after -f).
    // BusyBox lacks pkill, so we use pgrep + kill via common.kill_orphaned_logread().
    system(common.kill_orphaned_logread());
    system("rm -f /var/run/tachyon.reload.lock 2>/dev/null; true");

    // If sing-box was NOT stopped for this component change (e.g. WDTT, Zapret, ByeDPI,
    // FPTN, OlcRTC, rulesets, etc.), Tachyon is still running and sing-box routing is intact.
    // Perform a soft reload (`reload force`) via BIN_PATH. This bypasses rc.common flock,
    // reloads provider state and nftables without tearing down sing-box or dropping active connections.
    if (!tachyon_stopped_for_sing_box_change && file_exists(BIN_PATH) && tachyon_status_running_with_timeout()) {
        let reloaded = run_logged("Reloading Tachyon after successful component change", command_from_args([ BIN_PATH, "reload", "force" ]), 45);
        if (reloaded)
            return;
        updates_log("Tachyon reload returned non-zero; falling back to full restart", "warn");
    }

    let target_bin = file_exists(BIN_PATH) ? BIN_PATH : SERVICE_INIT;
    if (!file_exists(target_bin))
        return;

    let action_name = tachyon_status_running_with_timeout() ? "restart" : "start";
    run_logged("Restarting Tachyon after successful component change", command_from_args([ target_bin, action_name ]), 90);
}

function stop_tachyon_before_sing_box_change() {
    if (tachyon_stopped_for_sing_box_change)
        return;
    tachyon_stopped_for_sing_box_change = true;

    let stop_bin = file_exists(BIN_PATH) ? BIN_PATH : SERVICE_INIT;
    if (tachyon_was_running && file_exists(stop_bin))
        run_logged("Stopping Tachyon before sing-box package change", command_from_args([ stop_bin, "stop" ]), 30);

    if (tachyon_was_running && file_exists(BIN_PATH))
        command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);

    prepare_sing_box_service_disabled();
}

function wait_tachyon_running_after_sing_box_change() {
    if (!tachyon_was_running)
        return true;
    if (!file_exists(BIN_PATH))
        return false;

    let waited = 0;
    while (waited < 60) {
        if (tachyon_status_running_with_timeout()) {
            command_success_from_args([ "sleep", "8" ]);
            if (tachyon_status_running_with_timeout())
                return true;
        }
        command_success_from_args([ "sleep", "4" ]);
        waited += 4;
    }
    return false;
}

// Delegated to components/catalog.uc (branch 4 god-module split).
function opkg_arch_list() { return cmp_cat.opkg_arch_list(); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_arch_candidates() { return cmp_cat.resolve_arch_candidates(); }

function select_inner_package_path(bundle_file, component, arch, ext) {
    return trim(helper_output_input(command_output_from_args([ "unzip", "-l", bundle_file ]), "updates-zip-inner-package-path", [ component, arch, ext ]));
}

function select_archive_member_path(archive_file, member_name) {
    return trim(helper_output_input(command_output_from_args([ "tar", "-tzf", archive_file ]), "updates-archive-member-path", [ member_name ]));
}

// Delegated to components/* modules (branch 4 god-module split).
function extract_arch_package_version(package_name, package_arch) { return cmp_ver.extract_arch_package_version(package_name, package_arch); }
function extract_zapret_bundle_version(bundle_name) { return cmp_ver.extract_zapret_bundle_version(bundle_name); }
function extract_zapret2_bundle_version(bundle_name) { return cmp_ver.extract_zapret2_bundle_version(bundle_name); }
function normalize_zapret_version(value) { return cmp_ver.normalize_zapret_version(value); }
function normalize_sing_box_version(value) { return cmp_ver.normalize_sing_box_version(value); }


// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_zapret_release(arch, tag) { return cmp_cat.resolve_zapret_release(arch, tag); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_zapret2_release(arch, tag) { return cmp_cat.resolve_zapret2_release(arch, tag); }

function download_and_extract_zip_package(release, component) {
    let bundle_file = cmp.tmp_dir_path() + "/" + release.bundle_name;
    if (!download_with_retry(release.bundle_url, bundle_file, release.bundle_name))
        return null;

    let inner_package_path = is_apk() ?
        select_inner_package_path(bundle_file, component, "", "apk") :
        select_inner_package_path(bundle_file, component, release.arch, "ipk");
    if (inner_package_path == "")
        return null;

    let package_name = path_basename(inner_package_path);
    let package_file = cmp.tmp_dir_path() + "/" + package_name;
    if (!command_success(command_from_args([ "unzip", "-p", bundle_file, inner_package_path ]) + " >" + shell_quote(package_file)) ||
        !file_nonempty(package_file))
        return null;

    let version = as_string(release.version || "");
    if (version == "")
        version = component == "zapret2" ? extract_zapret2_bundle_version(release.bundle_name) : extract_zapret_bundle_version(release.bundle_name);
    if (version == "")
        version = extract_arch_package_version(package_name, release.arch);

    return {
        name: package_name,
        file: package_file,
        version
    };
}

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_byedpi_release(arch, tag) { return cmp_cat.resolve_byedpi_release(arch, tag); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_wdtt_release(arch, tag) { return cmp_cat.resolve_wdtt_release(arch, tag); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_olcrtc_release(arch, tag) { return cmp_cat.resolve_olcrtc_release(arch, tag); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_fptn_release(arch, tag) { return cmp_cat.resolve_fptn_release(arch, tag); }

function download_direct_package(release) {
    let package_file = cmp.tmp_dir_path() + "/" + release.package_name;
    if (!download_with_retry(release.package_url, package_file, release.package_name) || !file_nonempty(package_file))
        return null;
    let version = as_string(release.version || "");
    if (version == "")
        version = extract_arch_package_version(release.package_name, release.arch);
    return {
        name: release.package_name,
        file: package_file,
        version
    };
}

function disable_standalone_service(name) {
    let init = "/etc/init.d/" + as_string(name);
    if (!file_exists(init))
        return;
    run_logged("Stopping standalone " + as_string(name) + " service", command_from_args([ init, "stop" ]), 20);
    run_logged("Disabling standalone " + as_string(name) + " autostart", command_from_args([ init, "disable" ]), 20);
}

function provider_installed(runtime_module) {
    return module_success([ runtime_module, "installed" ]);
}

function provider_package_version(runtime_module) {
    return trim(module_output([ runtime_module, "package-version" ]));
}

function install_zapret_like(component, action, runtime_module, resolve_fn, label) {
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail(component, action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving " + label + " package", function() {
        release = resolve_fn(arch);
        if (type(release) == "object" && release.fetch_failed)
            return false;
        return release != null;
    });
    if (type(release) == "object" && release.fetch_failed)
        action_fail(component, action, "Failed to fetch " + label + " releases from GitHub API (Rate limit or network error)");
    if (release == null)
        action_fail(component, action, "Failed to resolve " + label + " package for this router architecture");

    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_success(component, action, label + " is not installed", current_version, release.version, 0, "", release.release_url || "");
        check_success_compared(component, current_version, release.version, normalize_zapret_version(current_version), normalize_zapret_version(release.version), release.release_url || "");
    }

    if (!ensure_package_tool("unzip", "unzip", component, action))
        action_fail(component, action, "Failed to install unzip");
    let pkg = download_and_extract_zip_package(release, component);
    if (pkg == null)
        action_fail(component, action, "Failed to download " + label + " package", current_version, release.version, "", release.release_url || "");

    if (!run_logged("Installing " + label + " package " + pkg.name, pkg_install_files_command([ pkg.file ]), 60))
        action_fail(component, action, "Failed to install " + label + " package", current_version, pkg.version, "", release.release_url || "");

    disable_standalone_service(component);
    restart_tachyon_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = pkg.version || "unknown";
    action_success(component, action, label + " package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_zapret(action, target_tag) {
    let resolver = function(arch) { return resolve_zapret_release(arch, target_tag); };
    install_zapret_like("zapret", action, LIB_DIR + "/providers/zapret/runtime.uc", resolver, "zapret");
}

function install_zapret2(action, target_tag) {
    let component = "zapret2";
    let label = "zapret2";
    let runtime_module = LIB_DIR + "/providers/zapret2/runtime.uc";
    
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail(component, action, "Failed to detect package architecture");
    
    let release = null;
    retry_resolve("Resolving " + label + " package", function() {
        release = resolve_zapret2_release(arch, target_tag);
        if (type(release) == "object" && release.fetch_failed)
            return false;
        return release != null;
    });
    
    if (type(release) == "object" && release.fetch_failed)
        action_fail(component, action, "Failed to fetch " + label + " releases from GitHub API (Rate limit or network error)");
    if (release == null)
        action_fail(component, action, "Failed to resolve " + label + " package for this router architecture");

    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_success(component, action, label + " is not installed", current_version, release.version, 0, "", release.release_url || "");
        check_success_compared(component, current_version, release.version, normalize_zapret_version(current_version), normalize_zapret_version(release.version), release.release_url || "");
    }

    let pkg = download_direct_package(release);
    if (pkg == null)
        action_fail(component, action, "Failed to download " + label + " package", current_version, release.version, "", release.release_url || "");

    let hosts_content = read_file("/etc/hosts") || "";
    if (index(hosts_content, "::1") < 0)
        command_success("printf '\n::1 localhost ip6-localhost ip6-loopback\n' >> /etc/hosts");

    if (!file_exists("/etc/config/zapret2"))
        write_file("/etc/config/zapret2", "config zapret2 'main'\n\toption enabled '0'\n");
    if (uci_core.available()) {
        if (!uci_core.exists("zapret2.main"))
            uci_core.set_section("zapret2.main", "zapret2");
        uci_core.set("zapret2.main.enabled", "0");
        uci_core.commit("zapret2");
    }

    run_logged("Updating package lists before " + label + " package installation", pkg_list_update_command(), 30);

    if (!run_logged("Installing " + label + " package " + pkg.name, pkg_install_files_command([ pkg.file ]), 60))
        action_fail(component, action, "Failed to install " + label + " package", current_version, pkg.version, "", release.release_url || "");

    for (let p in [ "/opt/zapret2/nfq2/nfqws2", "/opt/zapret2/nfq/nfqws2", "/opt/zapret2/nfqws2", "/usr/bin/nfqws2" ]) {
        if (file_exists(p))
            command_status_from_args([ "chmod", "0755", p ]);
    }
    if (file_exists("/opt/zapret2"))
        command_status_from_args([ "chmod", "-R", "a+rX", "/opt/zapret2" ]);

    command_success_from_args([ "killall", "-9", "nfqws2" ]);
    disable_standalone_service(component);
    command_status_from_args([ "nft", "delete", "table", "inet", "zapret2" ]);
    command_status_from_args([ "nft", "delete", "table", "ip", "zapret2" ]);
    command_status_from_args([ "nft", "delete", "table", "ip6", "zapret2" ]);
    restart_tachyon_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = pkg.version || "unknown";
    action_success(component, action, label + " package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_byedpi(action, target_tag) {
    init_tmp_dir() || action_fail("byedpi", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("byedpi", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving ByeDPI package", function() {
        release = resolve_byedpi_release(arch, target_tag);
        return release != null;
    });
    if (release == null)
        action_fail("byedpi", action, "Failed to resolve ByeDPI package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/byedpi/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_success("byedpi", action, "ByeDPI is not installed", current_version, release.version, 0, "", release.release_url || "");
        check_success("byedpi", current_version, release.version, release.release_url || "");
    }

    let pkg = download_direct_package(release);
    if (pkg == null)
        action_fail("byedpi", action, "Failed to download ByeDPI package");

    run_logged("Updating package lists before ByeDPI package installation", pkg_list_update_command(), 30);

    if (!run_logged("Installing ByeDPI package " + pkg.name, pkg_install_files_command([ pkg.file ]), 60))
        action_fail("byedpi", action, "Failed to install ByeDPI package", current_version, pkg.version);

    disable_standalone_service("byedpi");
    restart_tachyon_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = pkg.version || "unknown";
    action_success("byedpi", action, "ByeDPI package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_wdtt(action, target_tag) {
    init_tmp_dir() || action_fail("wdtt", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("wdtt", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving WDTT package", function() {
        release = resolve_wdtt_release(arch, target_tag);
        return release != null;
    });
    if (release == null)
        action_fail("wdtt", action, "Failed to resolve WDTT package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/wdtt/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_success("wdtt", action, "WDTT is not installed", current_version, release.version, 0, "", release.release_url || "");
        check_success("wdtt", current_version, release.version, release.release_url || "");
    }

    let pkg = download_direct_package(release);
    if (pkg == null)
        action_fail("wdtt", action, "Failed to download WDTT package");

    run_logged("Updating package lists before WDTT package installation", pkg_list_update_command(), 30);

    if (!run_logged("Installing WDTT package " + pkg.name, pkg_install_files_command([ pkg.file ]), 60))
        action_fail("wdtt", action, "Failed to install WDTT package", current_version, pkg.version);

    disable_standalone_service("wdtt");
    restart_tachyon_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = pkg.version || "unknown";
    action_success("wdtt", action, "WDTT package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_olcrtc(action, target_tag) {
    init_tmp_dir() || action_fail("olcrtc", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("olcrtc", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving OlcRTC package", function() {
        release = resolve_olcrtc_release(arch, target_tag);
        return release != null;
    });
    if (release == null)
        action_fail("olcrtc", action, "Failed to resolve OlcRTC package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/olcrtc/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_success("olcrtc", action, "OlcRTC is not installed", current_version, release.version, 0, "", release.release_url || "");
        check_success("olcrtc", current_version, release.version, release.release_url || "");
    }

    let pkg = download_direct_package(release);
    if (pkg == null)
        action_fail("olcrtc", action, "Failed to download OlcRTC package");

    run_logged("Updating package lists before OlcRTC package installation", pkg_list_update_command(), 30);

    if (!run_logged("Installing OlcRTC package " + pkg.name, pkg_install_files_command([ pkg.file ]), 60))
        action_fail("olcrtc", action, "Failed to install OlcRTC package", current_version, pkg.version);

    disable_standalone_service("olcrtc");
    restart_tachyon_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = pkg.version || "unknown";
    action_success("olcrtc", action, "OlcRTC package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_fptn(action, target_tag) {
    init_tmp_dir() || action_fail("fptn", action, "Failed to create temporary directory");
    let arch = resolve_arch_candidates();
    if (arch == null)
        action_fail("fptn", action, "Failed to detect package architecture");
    let release = null;
    retry_resolve("Resolving FPTN package", function() {
        release = resolve_fptn_release(arch, target_tag);
        return release != null;
    });
    if (release == null)
        action_fail("fptn", action, "Failed to resolve FPTN package for this router architecture");

    let runtime_module = LIB_DIR + "/providers/fptn/runtime.uc";
    let installed = provider_installed(runtime_module);
    let current_version = provider_package_version(runtime_module);
    if (action == "check_update") {
        if (!installed)
            action_success("fptn", action, "FPTN is not installed", current_version, release.version, 0, "", release.release_url || "");
        check_success("fptn", current_version, release.version, release.release_url || "");
    }

    let pkg = download_direct_package(release);
    if (pkg == null)
        action_fail("fptn", action, "Failed to download FPTN package");

    run_logged("Updating package lists before FPTN package installation", pkg_list_update_command(), 30);

    if (!run_logged("Installing FPTN package " + pkg.name, pkg_install_files_command([ pkg.file ]), 60))
        action_fail("fptn", action, "Failed to install FPTN package", current_version, pkg.version);

    disable_standalone_service("fptn");
    disable_standalone_service("fptn-client");
    restart_tachyon_after_successful_change();
    clear_version_caches();
    current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = pkg.version || "unknown";
    action_success("fptn", action, "FPTN package has been installed", current_version, pkg.version, 1, "latest", release.release_url || "");
}

function install_tailscale(action) {
    let component = "tailscale";
    let label = "Tailscale";
    let runtime_module = LIB_DIR + "/providers/tailscale/runtime.uc";
    init_tmp_dir() || action_fail(component, action, "Failed to create temporary directory");

    if (action == "check_update") {
        if (!pkg_is_installed("tailscale")) {
            run_logged("Refreshing package index", pkg_list_update_command(), 30);
            let available_version = available_package_version("tailscale");
            action_success(component, action, label + " is not installed", "", available_version, 0, "", TAILSCALE_PACKAGE_URL);
        }
        run_logged("Refreshing package index", pkg_list_update_command(), 30);
        check_success(component, installed_package_version("tailscale"), available_package_version("tailscale"), TAILSCALE_PACKAGE_URL);
    }

    let proxy_address = service_proxy_address();
    if (!run_logged("Refreshing package index", pkg_list_update_command(proxy_address), 30))
        updates_log("Package index refresh failed; trying to install from the cached index", "warn");
    if (!run_logged("Installing " + label + " package", pkg_install_name_command("tailscale", proxy_address), 60)) {
        if (proxy_address == "")
            updates_log("Upstream package download failed. If downloads.openwrt.org is blocked by your ISP, configure a proxy section and enable 'Download components via proxy' in Settings", "warn");
        action_fail(component, "install", "Failed to install " + label + " package from the feed");
    }
    disable_standalone_service("tailscale");
    restart_tachyon_after_successful_change();
    clear_version_caches();
    let current_version = provider_package_version(runtime_module);
    if (current_version == "")
        current_version = "unknown";
    action_success(component, "install", label + " package has been installed", current_version, current_version, 1, "latest", TAILSCALE_PACKAGE_URL);
}

function remove_optional_component(component, package_name, label, runtime_module) {
    if (!pkg_is_installed(package_name)) {
        if (provider_installed(runtime_module))
            action_fail(component, "remove", label + " exists outside the package manager and was not removed automatically");
        action_success(component, "remove", label + " is already removed", "", "", 0);
    }

    let current_version = provider_package_version(runtime_module);
    let command = is_apk() ?
        command_from_args([ "apk", "del", package_name ]) + " </dev/null" :
        command_from_args([ "opkg", "remove", "--force-depends", package_name ]) + " </dev/null";
    if (!run_logged("Removing " + label + " package", command, 60))
        action_fail(component, "remove", "Failed to remove " + label + " package", current_version);

    clear_version_caches();
    if (provider_installed(runtime_module))
        action_fail(component, "remove", label + " package was removed, but provider files are still present", current_version);
    restart_tachyon_after_successful_change();
    action_success(component, "remove", label + " package has been removed", current_version, "", 1);
}

// Delegated to components/* modules (branch 4 god-module split).
function extract_sing_box_version_from_output(output) { return cmp_ver.extract_sing_box_version_from_output(output); }
function read_sing_box_binary_version(binary, library_dir) { return cmp_ver.read_sing_box_binary_version(binary, library_dir); }
function verify_binary_post_install(binary_path, expected_version, version_cmd_args) { return cmp_verify.verify_binary_post_install(binary_path, expected_version, version_cmd_args); }
function validate_sing_box_extended_binary(binary, library_dir, compressed) { return cmp_verify.validate_sing_box_extended_binary(binary, library_dir, compressed); }


function move_file_portable(source_path, target_path) {
    if (fs.rename(source_path, target_path))
        return true;

    let staged_path = as_string(target_path) + ".tachyon-move." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-p", source_path, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function install_staged_file(source_path, target_path, mode) {
    let staged_path = as_string(target_path) + ".tachyon-new." + owner_pid();
    remove_file(staged_path);
    if (!command_success_from_args([ "cp", "-f", source_path, staged_path ]) ||
        !command_success_from_args([ "chmod", mode, staged_path ]) ||
        !fs.rename(staged_path, target_path)) {
        remove_file(staged_path);
        return false;
    }
    remove_file(source_path);
    return true;
}

function move_file_to_backup(target_path, backup_path) {
    if (!file_exists(target_path))
        return true;
    remove_file(backup_path);
    return move_file_portable(target_path, backup_path);
}

// Moved to line ~67 to avoid forward reference

// Binary variants are fully extracted and validated before this helper is
// called. On storage-constrained routers the temporary rollback copy can
// be larger than the remaining /tmp space. If persistent component
// backups are disabled, it is safer to free the old binary and install
// the already validated replacement than to fail the update solely
// because a second copy cannot be kept in RAM.
function move_validated_file_to_backup_or_discard(target_path, backup_path, label) {
    if (!file_exists(target_path))
        return "";
    if (move_file_to_backup(target_path, backup_path))
        return backup_path;

    remove_file(backup_path);
    if (get_component_backup_enabled())
        return null;

    updates_log(
        "Temporary rollback copy of " + as_string(label) +
        " could not be created; component backups are disabled, removing the current file to free space for the validated replacement",
        "warn"
    );
    remove_file(target_path);
    return file_exists(target_path) ? null : "";
}

function restore_sing_box_backup(backup_binary) {
    if (as_string(backup_binary) != "" && file_nonempty(backup_binary)) {
        if (!move_file_portable(backup_binary, "/usr/bin/sing-box"))
            return false;
        return command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ]);
    }
    return false;
}

function restore_file_backup(target_path, backup_path) {
    if (as_string(backup_path) != "" && file_nonempty(backup_path))
        return move_file_portable(backup_path, target_path);
    remove_file(target_path);
    return true;
}

function restore_sing_box_service_from_marker(marker) {
    if (as_string(marker) == "extended-compressed" || as_string(marker) == "lx" ||
        (!file_exists("/etc/init.d/sing-box") && file_nonempty("/usr/bin/sing-box")))
        return install_managed_sing_box_service_script();
    remove_managed_sing_box_service_script();
    return true;
}

function resolve_sing_box_extended_arch_suffix() {
    let host_arch = trim(command_output_from_args([ "uname", "-m" ]));
    let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
    return trim(helper_output("sing-box-extended-arch-suffix", [ host_arch, distrib_arch ]));
}

function sing_box_extended_tag_is_stable(tag) {
    tag = lc(as_string(tag));
    return tag != "" && index(tag, "alpha") < 0 && index(tag, "beta") < 0 && index(tag, "rc") < 0;
}

function set_sing_box_extended_release_from_json(release_json, compressed, allow_prerelease) {
    if (as_string(release_json) == "")
        return null;
    let tag = trim(helper_output_input(release_json, "object-get-default", [ "tag_name", "" ]));
    if (!allow_prerelease && !sing_box_extended_tag_is_stable(tag))
        return null;

    let asset_url = "";
    if (compressed) {
        let arch_suffix = resolve_sing_box_extended_arch_suffix();
        if (arch_suffix == "")
            return null;
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-asset-url", [ arch_suffix, "0", "1" ]));
    }
    else {
        let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
        if (distrib_arch == "")
            return null;
        let asset_ext = is_apk() ? "apk" : "ipk";
        asset_url = trim(helper_output_input(release_json, "sing-box-extended-package-asset-url", [ distrib_arch, asset_ext ]));
    }

    if (asset_url == "")
        return null;

    return {
        tag,
        release_url: trim(helper_output_input(release_json, "object-get-default", [ "html_url", "" ])),
        asset_url,
        asset_name: path_basename(asset_url)
    };
}

function resolve_sing_box_extended_release(compressed, target_tag) {
    if (target_tag != null && target_tag != "") {
        let release_json = fetch_github_release_by_tag_json("shtorm-7", "sing-box-extended", target_tag);
        let resolved = set_sing_box_extended_release_from_json(release_json, compressed, true);
        if (resolved != null)
            return resolved;

        let tag_clean = replace(target_tag, /^v/, "");
        let base_dl = "https://github.com/shtorm-7/sing-box-extended/releases/download/" + target_tag + "/";
        let asset_name = "";
        let asset_url = "";

        if (compressed) {
            let arch_suffix = resolve_sing_box_extended_arch_suffix();
            if (arch_suffix == "")
                return null;
            asset_name = "sing-box-extended_" + tag_clean + "_linux-" + arch_suffix + "-compressed.tar.gz";
            asset_url = base_dl + asset_name;
        }
        else {
            let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
            if (distrib_arch == "")
                return null;
            let asset_ext = is_apk() ? "apk" : "ipk";
            asset_name = "sing-box-extended_" + tag_clean + "_openwrt_" + distrib_arch + "." + asset_ext;
            asset_url = base_dl + asset_name;
        }

        return {
            tag: target_tag,
            release_url: "https://github.com/shtorm-7/sing-box-extended/releases/tag/" + target_tag,
            asset_url: asset_url,
            asset_name: asset_name
        };
    }

    let release_json = fetch_github_release_json("shtorm-7", "sing-box-extended");
    let resolved = set_sing_box_extended_release_from_json(release_json, compressed, false);
    if (resolved != null)
        return resolved;

    let releases_json = fetch_github_releases_json("shtorm-7", "sing-box-extended", "30");
    if (releases_json != "") {
        let tag = trim(helper_output_input(releases_json, "sing-box-extended-release-tag", []));
        if (tag != "") {
            release_json = helper_output_input(releases_json, "release-by-tag", [ tag ]);
            resolved = set_sing_box_extended_release_from_json(release_json, compressed, false);
            if (resolved != null)
                return resolved;
        }
    }

    let tag = fetch_github_release_tag_fallback("shtorm-7", "sing-box-extended");
    if (tag == "")
        return null;

    let tag_clean = replace(tag, /^v/, "");
    let asset_name = "";
    let asset_url = "";
    let base_dl = "https://github.com/shtorm-7/sing-box-extended/releases/download/" + tag + "/";

    if (compressed) {
        let arch_suffix = resolve_sing_box_extended_arch_suffix();
        if (arch_suffix == "")
            return null;
        asset_name = "sing-box-extended_" + tag_clean + "_linux-" + arch_suffix + "-compressed.tar.gz";
        asset_url = base_dl + asset_name;
    }
    else {
        let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
        if (distrib_arch == "")
            return null;
        let asset_ext = is_apk() ? "apk" : "ipk";
        asset_name = "sing-box-extended_" + tag_clean + "_openwrt_" + distrib_arch + "." + asset_ext;
        asset_url = base_dl + asset_name;
    }

    return {
        tag: tag,
        release_url: "https://github.com/shtorm-7/sing-box-extended/releases/tag/" + tag,
        asset_url: asset_url,
        asset_name: asset_name
    };
}

function set_sing_box_lx_release_from_json(release_json, allow_prerelease) {
    if (as_string(release_json) == "")
        return null;
    let tag = trim(helper_output_input(release_json, "object-get-default", [ "tag_name", "" ]));
    let lowered = lc(tag);
    if (!allow_prerelease && (tag == "" || index(lowered, "alpha") >= 0 || index(lowered, "beta") >= 0 || index(lowered, "rc") >= 0))
        return null;

    let arch_suffix = resolve_sing_box_extended_arch_suffix();
    if (arch_suffix == "")
        return null;
    let asset_url = trim(helper_output_input(release_json, "sing-box-lx-asset-url", [ arch_suffix ]));
    if (asset_url == "")
        return null;

    return {
        tag,
        release_url: trim(helper_output_input(release_json, "object-get-default", [ "html_url", "" ])),
        asset_url,
        asset_name: path_basename(asset_url)
    };
}

function resolve_sing_box_lx_release(target_tag) {
    if (target_tag != null && target_tag != "") {
        let release_json = fetch_github_release_by_tag_json("Leadaxe", "sing-box-lx", target_tag);
        let resolved = set_sing_box_lx_release_from_json(release_json, true);
        if (resolved != null)
            return resolved;

        let tag_clean = replace(target_tag, /^v/, "");
        let arch_suffix = resolve_sing_box_extended_arch_suffix();
        if (arch_suffix == "")
            return null;
        let base_dl = "https://github.com/Leadaxe/sing-box-lx/releases/download/" + target_tag + "/";
        let asset_name = "sing-box-" + tag_clean + "-linux-" + arch_suffix + ".tar.gz";
        return {
            tag: target_tag,
            release_url: "https://github.com/Leadaxe/sing-box-lx/releases/tag/" + target_tag,
            asset_url: base_dl + asset_name,
            asset_name: asset_name
        };
    }

    let release_json = fetch_github_release_json("Leadaxe", "sing-box-lx");
    let resolved = set_sing_box_lx_release_from_json(release_json, false);
    if (resolved != null)
        return resolved;

    let releases_json = fetch_github_releases_json("Leadaxe", "sing-box-lx", "30");
    if (releases_json == "")
        return null;
    let tag = trim(helper_output_input(releases_json, "sing-box-lx-release-tag", []));
    if (tag == "")
        return null;
    release_json = helper_output_input(releases_json, "release-by-tag", [ tag ]);
    return set_sing_box_lx_release_from_json(release_json, false);
}

function sing_box_runtime_output(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return trim(module_output(command_args));
}

function sing_box_runtime_success(mode, args) {
    let command_args = [ LIB_DIR + "/singbox/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

function write_sing_box_variant_state(marker, version) {
    if (!sing_box_runtime_success("write-variant-marker", [ marker ]))
        updates_log("Failed to write sing-box variant marker", "warn");
    if (!sing_box_runtime_success("write-version-state", [ version ]))
        updates_log("Failed to write sing-box version state", "warn");
    if (marker != "extended")
        sanitize_apk_world();
}

function restore_sing_box_variant_state(previous_marker, previous_version_state) {
    sing_box_runtime_success("restore-variant-marker", [ previous_marker ]);
    sing_box_runtime_success("restore-version-state", [ previous_version_state ]);
}

function restore_sing_box_extended_package_variant() {
    init_tmp_dir();
    let release = resolve_sing_box_extended_release(false);
    if (release == null)
        return false;
    let package_file = cmp.tmp_dir_path() + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name))
        return false;
    prepare_sing_box_package_service_install();
    pkg_remove_sing_box_conflict("sing-box-tiny");
    pkg_remove_sing_box_conflict("sing-box");
    if (!pkg_install_files([ package_file ], true)) {
        remove_file(package_file);
        return false;
    }
    remove_file(package_file);
    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "")
        return false;
    write_sing_box_variant_state("extended", new_version);
    return true;
}

function replace_sing_box_package_variant(target_package, conflict_package, target_version) {
    prepare_sing_box_package_service_install();
    if ((as_string(conflict_package) == "" || !pkg_is_installed(conflict_package)) &&
        (target_package == "sing-box-extended" || !pkg_is_installed("sing-box-extended")))
        return pkg_install_name_downgrade(target_package, target_version);

    if (target_package != "sing-box-extended" && !pkg_remove_sing_box_conflict("sing-box-extended"))
        return false;
    if (as_string(conflict_package) != "" && !pkg_remove_sing_box_conflict(conflict_package))
        return false;
    return pkg_install_name_downgrade(target_package, target_version);
}

function restore_sing_box_package_variant(previous_variant) {
    if (previous_variant == "tiny")
        return replace_sing_box_package_variant("sing-box-tiny", "sing-box", available_package_version("sing-box-tiny"));
    if (previous_variant == "stable")
        return replace_sing_box_package_variant("sing-box", "sing-box-tiny", available_package_version("sing-box"));
    if (previous_variant == "extended")
        return restore_sing_box_extended_package_variant();
    if (previous_variant == "not-installed") {
        pkg_remove_sing_box_conflict("sing-box-extended");
        pkg_remove_sing_box_conflict("sing-box-tiny");
        pkg_remove_sing_box_conflict("sing-box");
        remove_managed_sing_box_service_script();
        remove_file("/usr/bin/sing-box");
        return true;
    }
    return false;
}

function sing_box_variant_is_package_managed(variant) {
    return variant == "stable" || variant == "tiny" || variant == "extended";
}

function restore_sing_box_install_backup(previous_variant, backup_binary) {
    if (as_string(backup_binary) != "" && file_nonempty(backup_binary)) {
        if (restore_sing_box_backup(backup_binary)) {
            updates_log("Restored the previous sing-box binary backup from " + backup_binary, "info");
            return true;
        }
    }

    if (sing_box_variant_is_package_managed(previous_variant)) {
        if (restore_sing_box_package_variant(previous_variant))
            return true;
        if (as_string(backup_binary) != "" && restore_sing_box_backup(backup_binary)) {
            updates_log("Package rollback failed; restored the previous sing-box binary backup", "warn");
            return true;
        }
        return false;
    }

    if (as_string(backup_binary) != "")
        return restore_sing_box_backup(backup_binary);
    return restore_sing_box_package_variant(previous_variant);
}

function restore_sing_box_after_failed_extended_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched) {
    if (as_string(archive_file) != "")
        remove_file(archive_file);
    let restore_status = true;
    if (cronet_touched)
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
    if (!restore_sing_box_install_backup(previous_variant, backup_binary))
        restore_status = false;
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_extended_package_install(previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched) {
    if (as_string(package_file) != "")
        remove_file(package_file);
    pkg_remove_sing_box_conflict("sing-box-extended");
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary);
    if (cronet_touched) {
        restore_file_backup("/usr/lib/libcronet.so", backup_cronet);
        if (file_nonempty("/usr/lib/libcronet.so"))
            command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]);
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    restore_sing_box_service_from_marker(previous_marker);
    clear_version_caches();
    return restore_status;
}

function restore_sing_box_after_failed_package_install(target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched) {
    pkg_remove_sing_box_conflict(target_package);
    let restore_status = restore_sing_box_install_backup(previous_variant, backup_binary);
    if (cronet_touched) {
        if (!restore_file_backup("/usr/lib/libcronet.so", backup_cronet))
            restore_status = false;
        if (file_nonempty("/usr/lib/libcronet.so") && !command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]))
            restore_status = false;
    }
    restore_sing_box_variant_state(previous_marker, previous_version_state);
    if (!restore_sing_box_service_from_marker(previous_marker))
        restore_status = false;
    if (restore_status) {
        remove_file(backup_binary);
        remove_file(backup_cronet);
    }
    clear_version_caches();
    return restore_status;
}

function fail_package_sing_box_install(action, tiny, reason, current_version, latest_version,
    target_package, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched) {
    let restored = restore_sing_box_after_failed_package_install(
        target_package,
        previous_variant,
        backup_binary,
        backup_cronet,
        previous_marker,
        previous_version_state,
        cronet_touched
    );

    let prefix = tiny ? "sing-box-tiny" : "Stable sing-box";
    if (restored)
        action_fail("sing_box", action, prefix + " " + reason + "; previous sing-box variant was restored", current_version, latest_version);
    action_fail("sing_box", action, prefix + " " + reason + " and previous sing-box variant could not be restored", current_version, latest_version);
}

function install_sing_box_extended_package(action, target_tag) {
    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(false, target_tag);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve sing-box-extended package release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (current_version == "" || !sing_box_runtime_success("is-extended", [ current_version ]))
            action_success("sing_box", action, "sing-box-extended is not installed", current_version, latest_version, 0, "", release.release_url);
        else
            check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    ensure_sing_box_dependencies();

    let package_file = cmp.tmp_dir_path() + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, package_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download sing-box-extended package", current_version, latest_version);

    run_logged("Updating package lists before sing-box-extended package installation", pkg_list_update_command(), 30);

    stop_tachyon_before_sing_box_change();
    prepare_sing_box_package_service_install();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (current_variant == "extended" || current_variant == "extended-compressed") {
        if (file_exists("/usr/bin/sing-box")) {
            backup_binary = cmp.tmp_dir_path() + "/sing-box.tachyon-backup";
            if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
                action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
        if (file_exists("/usr/lib/libcronet.so")) {
            cronet_touched = true;
            backup_cronet = cmp.tmp_dir_path() + "/libcronet.so.tachyon-backup";
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    if (!run_logged_pkg_remove_sing_box_conflict("sing-box-tiny", "Removing sing-box-tiny before sing-box-extended package installation")) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to remove sing-box-tiny before sing-box-extended package installation", current_version, latest_version);
    }
    if (!run_logged_pkg_remove_sing_box_conflict("sing-box", "Removing sing-box before sing-box-extended package installation")) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to remove sing-box before sing-box-extended package installation", current_version, latest_version);
    }

    if (backup_binary == "" && file_exists("/usr/bin/sing-box")) {
        backup_binary = cmp.tmp_dir_path() + "/sing-box.tachyon-backup";
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary)) {
            restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
            action_fail("sing_box", action, "Failed to backup existing sing-box binary", current_version, latest_version);
        }
    }
    if (!cronet_touched && file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = cmp.tmp_dir_path() + "/libcronet.so.tachyon-backup";
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    if (!run_logged("Installing sing-box-extended package " + release.asset_name, pkg_install_files_command([ package_file ], true), 90)) {
        restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install sing-box-extended package", current_version, latest_version);
    }
    remove_file(package_file);
    command_success_from_args([ "chmod", "0755", "/usr/bin/sing-box" ]);

    let new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched))
            action_fail("sing_box", action, "Installed sing-box-extended package failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed sing-box-extended package failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended", new_version);
    if (target_tag != null && target_tag != "")
        write_file("/etc/tachyon/sing-box-version", target_tag + "\n");
    restart_tachyon_after_successful_change();
    if (!wait_tachyon_running_after_sing_box_change()) {
        updates_log("sing-box-extended package did not start cleanly; restoring previous sing-box variant", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_package_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, package_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, "sing-box-extended package was installed but Tachyon did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, "sing-box-extended package was installed but Tachyon did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed sing-box-extended " + (new_version != "" ? new_version : "unknown") + " from package");
    action_success("sing_box", action, "sing-box-extended has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest", release.release_url);
}

function install_sing_box_extended(action, compressed, target_tag) {
    if (!compressed) {
        install_sing_box_extended_package(action, target_tag);
        return;
    }

    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let label = "sing-box-extended compressed";
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_extended_release(true, target_tag);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve " + label + " release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (current_version == "" || !sing_box_runtime_success("is-extended", [ current_version ]) || !sing_box_runtime_success("marker-is", [ "extended-compressed" ]))
            action_success("sing_box", action, label + " is not installed", current_version, latest_version, 0, "", release.release_url);
        else
            check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    ensure_sing_box_dependencies();

    let archive_file = cmp.tmp_dir_path() + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, archive_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download " + label, current_version, latest_version);

    let binary_path = select_archive_member_path(archive_file, "sing-box");
    if (binary_path == "") {
        remove_file(archive_file);
        action_fail("sing_box", action, "sing-box binary was not found in the downloaded archive", current_version, latest_version);
    }
    let cronet_path = select_archive_member_path(archive_file, "libcronet.so");
    let extract_error = cmp.tmp_dir_path() + "/sing-box-extract.err";
    let tmp_binary = cmp.tmp_dir_path() + "/sing-box.compressed." + owner_pid();
    let tmp_cronet = "";
    if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", binary_path ]) + " >" + shell_quote(tmp_binary) + " 2>" + shell_quote(extract_error)) ||
        !file_nonempty(tmp_binary) ||
        !command_success_from_args([ "chmod", "0755", tmp_binary ])) {
        for (let line in split(read_file(extract_error), "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        remove_file(tmp_binary);
        remove_file(archive_file);
        action_fail("sing_box", action, "Failed to extract " + label, current_version, latest_version);
    }

    if (cronet_path != "") {
        tmp_cronet = cmp.tmp_dir_path() + "/libcronet.so";
        if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", cronet_path ]) + " >" + shell_quote(tmp_cronet) + " 2>" + shell_quote(extract_error)) ||
            !file_nonempty(tmp_cronet) ||
            !command_success_from_args([ "chmod", "0644", tmp_cronet ])) {
            for (let line in split(read_file(extract_error), "\n"))
                if (trim(as_string(line)) != "")
                    updates_log(line);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to extract libcronet.so from sing-box-extended archive", current_version, latest_version);
        }
    }

    remove_file(archive_file);
    stop_tachyon_before_sing_box_change();
    let new_version = validate_sing_box_extended_binary(tmp_binary, cmp.tmp_dir_path(), compressed);
    if (new_version == "") {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Downloaded " + label + " failed validation", current_version, latest_version);
    }

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = move_validated_file_to_backup_or_discard(
            "/usr/bin/sing-box",
            cmp.tmp_dir_path() + "/sing-box.tachyon-backup",
            "current sing-box binary"
        );
        if (backup_binary == null) {
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
    }
    if (cronet_path != "") {
        cronet_touched = true;
        if (file_exists("/usr/lib/libcronet.so")) {
            backup_cronet = cmp.tmp_dir_path() + "/libcronet.so.tachyon-backup";
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
                remove_file(tmp_binary);
                remove_file(tmp_cronet);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    for (let item in [
        [ "sing-box-extended", "Removing sing-box-extended package before " + label + " installation" ],
        [ "sing-box-tiny", "Removing sing-box-tiny package before " + label + " installation" ],
        [ "sing-box", "Removing sing-box package before " + label + " installation" ]
    ]) {
        if (!run_logged_pkg_remove_sing_box_conflict(item[0], item[1])) {
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            action_fail("sing_box", action, "Failed to remove " + item[0] + " before " + label + " installation", current_version, latest_version);
        }
    }

    remove_managed_sing_box_service_script();
    if (!install_managed_sing_box_service_script()) {
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Failed to install managed sing-box service for " + label, current_version, latest_version);
    }

    remove_file("/usr/bin/sing-box");
    if (!install_staged_file(tmp_binary, "/usr/bin/sing-box", "0755")) {
        remove_file("/usr/bin/sing-box");
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install " + label + " binary", current_version, latest_version);
    }
    if (tmp_cronet != "") {
        remove_file("/usr/lib/libcronet.so");
        if (!install_staged_file(tmp_cronet, "/usr/lib/libcronet.so", "0644")) {
            remove_file("/usr/lib/libcronet.so");
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            action_fail("sing_box", action, "Failed to install libcronet.so for " + label, current_version, latest_version);
        }
    }
    remove_file(archive_file);

    new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib", compressed);
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched))
            action_fail("sing_box", action, "Installed " + label + " failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed " + label + " failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("extended-compressed", new_version);
    if (target_tag != null && target_tag != "")
        write_file("/etc/tachyon/sing-box-version", target_tag + "\n");
    restart_tachyon_after_successful_change();
    if (!wait_tachyon_running_after_sing_box_change()) {
        updates_log(label + " did not start cleanly; restoring previous sing-box binary", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, label + " was installed but Tachyon did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, label + " was installed but Tachyon did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function install_sing_box_lx(action, target_tag) {
    init_tmp_dir() || action_fail("sing_box", action, "Failed to create temporary directory");
    let label = "sing-box-lx";
    let current_version = sing_box_runtime_output("version", []);
    let current_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    let release = resolve_sing_box_lx_release(target_tag);
    if (release == null)
        action_fail("sing_box", action, "Failed to resolve " + label + " release", current_version);
    let latest_version = normalize_sing_box_version(release.tag);

    if (action == "check_update") {
        if (current_version == "" || !sing_box_runtime_success("is-lx", [ current_version ]) || !sing_box_runtime_success("marker-is", [ "lx" ]))
            action_success("sing_box", action, label + " is not installed", current_version, latest_version, 0, "", release.release_url);
        else
            check_success("sing_box", normalize_sing_box_version(current_version), normalize_sing_box_version(latest_version), release.release_url);
    }

    ensure_sing_box_dependencies();

    let archive_file = cmp.tmp_dir_path() + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, archive_file, release.asset_name))
        action_fail("sing_box", action, "Failed to download " + label, current_version, latest_version);

    let binary_path = select_archive_member_path(archive_file, "sing-box");
    if (binary_path == "") {
        remove_file(archive_file);
        action_fail("sing_box", action, "sing-box binary was not found in the downloaded archive", current_version, latest_version);
    }
    let cronet_path = select_archive_member_path(archive_file, "libcronet.so");
    let extract_error = cmp.tmp_dir_path() + "/sing-box-extract.err";
    let tmp_binary = cmp.tmp_dir_path() + "/sing-box.compressed." + owner_pid();
    let tmp_cronet = "";
    if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", binary_path ]) + " >" + shell_quote(tmp_binary) + " 2>" + shell_quote(extract_error)) ||
        !file_nonempty(tmp_binary) ||
        !command_success_from_args([ "chmod", "0755", tmp_binary ])) {
        for (let line in split(read_file(extract_error), "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        remove_file(tmp_binary);
        remove_file(archive_file);
        action_fail("sing_box", action, "Failed to extract " + label, current_version, latest_version);
    }

    if (cronet_path != "") {
        tmp_cronet = cmp.tmp_dir_path() + "/libcronet.so";
        if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", cronet_path ]) + " >" + shell_quote(tmp_cronet) + " 2>" + shell_quote(extract_error)) ||
            !file_nonempty(tmp_cronet) ||
            !command_success_from_args([ "chmod", "0644", tmp_cronet ])) {
            for (let line in split(read_file(extract_error), "\n"))
                if (trim(as_string(line)) != "")
                    updates_log(line);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to extract libcronet.so from sing-box-lx archive", current_version, latest_version);
        }
    }

    remove_file(archive_file);
    stop_tachyon_before_sing_box_change();
    let new_version = validate_sing_box_extended_binary(tmp_binary, cmp.tmp_dir_path());
    if (new_version == "") {
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Downloaded " + label + " failed validation", current_version, latest_version);
    }

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = move_validated_file_to_backup_or_discard(
            "/usr/bin/sing-box",
            cmp.tmp_dir_path() + "/sing-box.tachyon-backup",
            "current sing-box binary"
        );
        if (backup_binary == null) {
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            remove_file(archive_file);
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
        }
    }
    if (cronet_path != "") {
        cronet_touched = true;
        if (file_exists("/usr/lib/libcronet.so")) {
            backup_cronet = cmp.tmp_dir_path() + "/libcronet.so.tachyon-backup";
            if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
                restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
                remove_file(tmp_binary);
                remove_file(tmp_cronet);
                action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
            }
        }
    }

    for (let item in [
        [ "sing-box-extended", "Removing sing-box-extended package before " + label + " installation" ],
        [ "sing-box-tiny", "Removing sing-box-tiny package before " + label + " installation" ],
        [ "sing-box", "Removing sing-box package before " + label + " installation" ]
    ]) {
        if (!run_logged_pkg_remove_sing_box_conflict(item[0], item[1])) {
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            remove_file(tmp_binary);
            remove_file(tmp_cronet);
            action_fail("sing_box", action, "Failed to remove " + item[0] + " before " + label + " installation", current_version, latest_version);
        }
    }

    remove_managed_sing_box_service_script();
    if (!install_managed_sing_box_service_script()) {
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        remove_file(tmp_binary);
        remove_file(tmp_cronet);
        action_fail("sing_box", action, "Failed to install managed sing-box service for " + label, current_version, latest_version);
    }

    remove_file("/usr/bin/sing-box");
    if (!install_staged_file(tmp_binary, "/usr/bin/sing-box", "0755")) {
        remove_file("/usr/bin/sing-box");
        restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
        action_fail("sing_box", action, "Failed to install " + label + " binary", current_version, latest_version);
    }
    if (tmp_cronet != "") {
        remove_file("/usr/lib/libcronet.so");
        if (!install_staged_file(tmp_cronet, "/usr/lib/libcronet.so", "0644")) {
            remove_file("/usr/lib/libcronet.so");
            restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched);
            action_fail("sing_box", action, "Failed to install libcronet.so for " + label, current_version, latest_version);
        }
    }
    remove_file(archive_file);

    new_version = validate_sing_box_extended_binary("/usr/bin/sing-box", "/usr/lib");
    if (new_version == "") {
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched))
            action_fail("sing_box", action, "Installed " + label + " failed validation; previous sing-box variant was restored", current_version, latest_version);
        action_fail("sing_box", action, "Installed " + label + " failed validation and previous sing-box variant could not be restored", current_version, latest_version);
    }

    write_sing_box_variant_state("lx", new_version);
    if (target_tag != null && target_tag != "")
        write_file("/etc/tachyon/sing-box-version", target_tag + "\n");
    restart_tachyon_after_successful_change();
    if (!wait_tachyon_running_after_sing_box_change()) {
        updates_log(label + " did not start cleanly; restoring previous sing-box binary", "error");
        if (file_exists(SERVICE_INIT))
            command_success_from_args([ SERVICE_INIT, "stop" ]);
        if (restore_sing_box_after_failed_extended_install(current_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, archive_file, cronet_touched)) {
            remove_file(backup_binary);
            remove_file(backup_cronet);
            action_fail("sing_box", action, label + " was installed but Tachyon did not start cleanly; previous sing-box variant was restored", current_version, latest_version);
        }
        action_fail("sing_box", action, label + " was installed but Tachyon did not start cleanly and previous sing-box variant could not be restored", current_version, latest_version);
    }

    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
}

function install_package_sing_box(action, tiny) {
    let package_name = tiny ? "sing-box-tiny" : "sing-box";
    let conflict = tiny ? "sing-box" : "sing-box-tiny";
    let label = tiny ? "tiny sing-box" : "stable sing-box";
    let package_version = installed_package_version(package_name);
    let binary_version = sing_box_runtime_output("version", []);
    let current_version = package_version;
    if (sing_box_runtime_success("is-extended", [ binary_version ]))
        current_version = binary_version;
    if (current_version == "")
        current_version = binary_version;
    let latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);

    if (action == "check_update") {
        if (latest_version == "") {
            let proxy_address = service_proxy_address();
            run_logged("Refreshing package index", pkg_list_update_command(proxy_address), 30);
            latest_version = available_package_version(package_name);
            if (latest_version == "")
                latest_version = installed_package_version(package_name);
        }
        if (latest_version == "")
            action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);
        if (current_version == "" || (tiny && !sing_box_runtime_success("is-tiny", [ binary_version ])))
            action_success("sing_box", action, label + " is not installed", current_version, latest_version, 0, "", "");
        else
            check_success("sing_box", current_version, latest_version, "");
    }

    ensure_sing_box_dependencies();

    run_logged("Updating package lists before " + package_name + " installation", pkg_list_update_command(), 30);
    latest_version = available_package_version(package_name);
    if (latest_version == "")
        latest_version = installed_package_version(package_name);
    if (latest_version == "")
        action_fail("sing_box", action, "Failed to resolve " + (tiny ? "tiny" : "stable") + " sing-box package version", current_version);

    let previous_variant = sing_box_runtime_output("variant", []);
    let previous_marker = sing_box_runtime_output("read-variant-marker", []);
    let previous_version_state = sing_box_runtime_output("read-version-state", []);
    stop_tachyon_before_sing_box_change();

    let backup_binary = "";
    let backup_cronet = "";
    let cronet_touched = false;
    let backup_on_tmpfs = previous_variant == "extended-compressed";
    if (file_exists("/usr/bin/sing-box")) {
        backup_binary = backup_on_tmpfs ? cmp.tmp_dir_path() + "/sing-box.tachyon-backup" :
            cmp.tmp_dir_path() + "/sing-box.tachyon-backup";
        if (!move_file_to_backup("/usr/bin/sing-box", backup_binary))
            action_fail("sing_box", action, "Failed to backup current sing-box binary", current_version, latest_version);
    }
    if (file_exists("/usr/lib/libcronet.so")) {
        cronet_touched = true;
        backup_cronet = backup_on_tmpfs ? cmp.tmp_dir_path() + "/libcronet.so.tachyon-backup" :
            cmp.tmp_dir_path() + "/libcronet.so.tachyon-backup";
        if (!move_file_to_backup("/usr/lib/libcronet.so", backup_cronet)) {
            restore_sing_box_backup(backup_binary);
            action_fail("sing_box", action, "Failed to backup current libcronet.so", current_version, latest_version);
        }
    }

    if (!run_logged("Installing " + label + " package", "sh -c " + shell_quote("exit 0")) ||
        !replace_sing_box_package_variant(package_name, conflict, latest_version))
        fail_package_sing_box_install(action, tiny, "package installation failed", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);

    let new_version = read_sing_box_binary_version("/usr/bin/sing-box", "");
    if (new_version == "")
        fail_package_sing_box_install(action, tiny, "package was installed, but sing-box binary is not available", current_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    if (sing_box_runtime_success("is-extended", [ new_version ]))
        fail_package_sing_box_install(action, tiny, "package was installed, but the active binary is still sing-box-extended", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    write_sing_box_variant_state(tiny ? "tiny" : "stable", new_version);
    restart_tachyon_after_successful_change();
    if (!wait_tachyon_running_after_sing_box_change())
        fail_package_sing_box_install(action, tiny, "was installed, but Tachyon did not start cleanly", new_version, latest_version,
            package_name, previous_variant, backup_binary, backup_cronet, previous_marker, previous_version_state, cronet_touched);
    remove_file(backup_binary);
    remove_file(backup_cronet);
    clear_version_caches();
    action_success("sing_box", action, label + " has been installed", new_version, latest_version, new_version == current_version ? 0 : 1, "latest");
}

function check_tachyon() {
    let release_json = latest_tachyon_release_json();
    let metadata = "";
    let latest_version = "unknown";
    let release_url = "";

    if (release_json != "") {
        let tsv = trim(helper_output_input(release_json, "release-metadata-tsv", []));
        if (tsv != "") {
            let fields = split(tsv, "\t");
            latest_version = length(fields) > 0 && as_string(fields[0]) != "" ? replace(as_string(fields[0]), /^[vV]/, "") : "unknown";
            release_url = length(fields) > 1 ? as_string(fields[1]) : "";
        }
    }

    if (latest_version == "unknown") {
        metadata = fetch_tachyon_latest_release_metadata();
        let fields = split(metadata, "\t");
        latest_version = length(fields) > 0 && as_string(fields[0]) != "" ? replace(as_string(fields[0]), /^[vV]/, "") : "unknown";
        release_url = length(fields) > 1 ? as_string(fields[1]) : "";
    }

    if (latest_version == "unknown")
        action_fail("tachyon", "check_update", "Failed to check Tachyon updates", TACHYON_VERSION, latest_version);

    write_tachyon_latest_version_cache(latest_version, now_seconds());
    if (!helper_success("tachyon-release-version-valid", [ TACHYON_VERSION ])) {
        updates_log("Tachyon current version is not a release version (" + TACHYON_VERSION + ")");
        action_success("tachyon", "check_update", "Installed version is newer than release", TACHYON_VERSION, latest_version, 0, "dev", release_url);
    }

    let compare = trim(helper_output("tachyon-release-version-compare", [ TACHYON_VERSION, latest_version ]));
    if (compare == "")
        action_fail("tachyon", "check_update", "Failed to compare Tachyon versions", TACHYON_VERSION, latest_version);
    let status = status_from_compare(int(compare));
    if (status == "")
        action_fail("tachyon", "check_update", "Failed to compare Tachyon versions", TACHYON_VERSION, latest_version);

    // Fetch remote commit SHA for information display
    let remote_sha = "";
    let remote_fingerprint = "";
    let local_sha = TACHYON_COMMIT_SHA != "" && TACHYON_COMMIT_SHA != "unknown" ? TACHYON_COMMIT_SHA : "";
    let local_fingerprint = read_tachyon_build_fingerprint();
    if (release_json != "") {
        remote_sha = trim(helper_output_input(release_json, "release-commit-sha", []));
        if (remote_sha != "" && match(remote_sha, /^[0-9a-fA-F]{7,40}$/) == null)
            remote_sha = "";
        remote_fingerprint = trim(helper_output_input(release_json, "release-build-fingerprint", []));
    }

    if (remote_sha == "" && latest_version != "unknown" && latest_version != "") {
        let parts = split(TACHYON_RELEASE_REPO, "/");
        if (length(parts) == 2) {
            remote_sha = fetch_github_tag_commit_sha(parts[0], parts[1], latest_version);
            if (remote_sha != "" && (remote_fingerprint == "" || str_startswith(remote_fingerprint, "build:")))
                remote_fingerprint = "sha:" + remote_sha;
        }
    }

    let sha_extra = null;
    if (local_sha != "" || remote_sha != "" || remote_fingerprint != "" || local_fingerprint != "") {
        sha_extra = { current_sha: local_sha, latest_sha: remote_sha };
        if (local_fingerprint != "")
            sha_extra.current_build = local_fingerprint;
        if (remote_fingerprint != "")
            sha_extra.latest_build = remote_fingerprint;
    }

    if (status == "latest") {
        // Same tag can carry several builds. Decide via SHA when both sides have
        // one, otherwise via the fingerprint recorded at install time.
        if (helper_success("tachyon-build-differs", [ local_sha, remote_sha, local_fingerprint, remote_fingerprint ])) {
            status = "outdated_same_release";
            let short_local = length(local_sha) >= 7 ? substr(local_sha, 0, 7) : local_sha;
            let short_remote = length(remote_sha) >= 7 ? substr(remote_sha, 0, 7) : remote_sha;
            updates_log("Tachyon build update found for current release (" + TACHYON_VERSION + "): " +
                (short_local != "" && short_remote != "" ? short_local + " -> " + short_remote :
                    format_fingerprint_human(local_fingerprint) + " -> " + format_fingerprint_human(remote_fingerprint)));
            action_success("tachyon", "check_update", "Update is available for current release", TACHYON_VERSION, latest_version, 0, status, release_url, sha_extra);
        } else {
            updates_log("Tachyon is already up to date (" + TACHYON_VERSION + ")");
            action_success("tachyon", "check_update", "Latest version is installed", TACHYON_VERSION, latest_version, 0, status, release_url, sha_extra);
        }
    }
    if (status == "outdated") {
        updates_log("Tachyon update found: " + TACHYON_VERSION + " -> " + latest_version);
        action_success("tachyon", "check_update", "Update is available", TACHYON_VERSION, latest_version, 0, status, release_url, sha_extra);
    }
    updates_log("Tachyon installed version is newer than upstream release: " + TACHYON_VERSION + " -> " + latest_version);
    action_success("tachyon", "check_update", "Installed version is newer than release", TACHYON_VERSION, latest_version, 0, status, release_url, sha_extra);
}

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_tachyon_release(latest_version) { return cmp_cat.resolve_tachyon_release(latest_version); }

function reinstall_tachyon() {
    let latest_version = latest_tachyon_version();
    if (latest_version == "")
        latest_version = "unknown";
    if (latest_version == "unknown")
        action_fail("tachyon", "reinstall", "Failed to resolve Tachyon release", TACHYON_VERSION, latest_version);

    write_tachyon_latest_version_cache(latest_version, now_seconds());
    init_tmp_dir() || action_fail("tachyon", "reinstall", "Failed to create temporary directory", TACHYON_VERSION, latest_version);
    updates_log("Resolving Tachyon release " + latest_version + " packages");
    let release = resolve_tachyon_release(latest_version);
    if (release == null)
        action_fail("tachyon", "reinstall", "Failed to resolve Tachyon release packages", TACHYON_VERSION, latest_version);

    let backend_file = cmp.tmp_dir_path() + "/" + release.backend_name;
    let app_file = cmp.tmp_dir_path() + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? cmp.tmp_dir_path() + "/" + release.i18n_name : "";
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name) ||
        !download_with_retry(release.app_url, app_file, release.app_name) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name)))
        action_fail("tachyon", "reinstall", "Failed to download Tachyon release packages", TACHYON_VERSION, latest_version);

    let reinstall_files = [ backend_file, app_file ];
    if (i18n_file != "")
        push(reinstall_files, i18n_file);

    // Self-update uses longer timeout: download + install + postinst on slow storage
    let install_result = pkg_tx_install_files(reinstall_files, true);
    if (!install_result.success)
        action_fail("tachyon", "reinstall", "Failed to reinstall Tachyon packages: " + as_string(install_result.message), TACHYON_VERSION, latest_version);

    // Verify package DB was updated
    if (!verify_package_post_install("tachyon", latest_version))
        updates_log("Warning: Tachyon package version may not have been updated in package database", "warn");

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    restart_tachyon_after_successful_change();
    clear_version_caches();
    let new_version = installed_package_version("tachyon");
    if (new_version == "")
        new_version = latest_version;
    updates_log("Tachyon reinstalled to " + new_version);
    let build_extra = record_tachyon_installed_build(new_version, release);
    action_success("tachyon", "reinstall", "Tachyon has been reinstalled", new_version, latest_version, 1, "latest", release.release_url, build_extra);
}

function install_tachyon() {
    let latest_version = latest_tachyon_version();
    if (latest_version == "")
        latest_version = "unknown";
    if (latest_version == "unknown")
        action_fail("tachyon", "install", "Failed to resolve Tachyon release", TACHYON_VERSION, latest_version);

    write_tachyon_latest_version_cache(latest_version, now_seconds());
    init_tmp_dir() || action_fail("tachyon", "install", "Failed to create temporary directory", TACHYON_VERSION, latest_version);
    updates_log("Resolving Tachyon release " + latest_version + " packages");
    let release = resolve_tachyon_release(latest_version);
    if (release == null)
        action_fail("tachyon", "install", "Failed to resolve Tachyon release packages", TACHYON_VERSION, latest_version);

    let backend_file = cmp.tmp_dir_path() + "/" + release.backend_name;
    let app_file = cmp.tmp_dir_path() + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? cmp.tmp_dir_path() + "/" + release.i18n_name : "";
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name) ||
        !download_with_retry(release.app_url, app_file, release.app_name) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name)))
        action_fail("tachyon", "install", "Failed to download Tachyon release packages", TACHYON_VERSION, latest_version);

    let install_files = [ backend_file, app_file ];
    if (i18n_file != "")
        push(install_files, i18n_file);
    let same_release_build = trim(as_string(latest_version)) == trim(as_string(TACHYON_VERSION));

    let install_result = pkg_tx_install_files(install_files, same_release_build);
    if (!install_result.success)
        action_fail("tachyon", "install", "Failed to install Tachyon packages: " + as_string(install_result.message), TACHYON_VERSION, latest_version);

    if (!verify_package_post_install("tachyon", latest_version))
        updates_log("Warning: Tachyon package version may not have been updated in package database", "warn");

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    restart_tachyon_after_successful_change();
    clear_version_caches();
    let new_version = installed_package_version("tachyon");
    if (new_version == "")
        new_version = latest_version;
    updates_log("Tachyon updated to " + new_version);
    let build_extra = record_tachyon_installed_build(new_version, release);
    action_success("tachyon", "install", "Tachyon has been installed", new_version, latest_version, 1, "latest", release.release_url, build_extra);
}

function install_tachyon_version(target_tag) {
    target_tag = trim(as_string(target_tag));
    if (target_tag == "")
        action_fail("tachyon", "install_version", "Target version tag cannot be empty", TACHYON_VERSION, "");

    init_tmp_dir() || action_fail("tachyon", "install_version", "Failed to create temporary directory", TACHYON_VERSION, target_tag);
    updates_log("Resolving Tachyon release " + target_tag + " packages");
    let release = resolve_tachyon_release(target_tag);
    if (release == null)
        action_fail("tachyon", "install_version", "Failed to resolve Tachyon release packages for " + target_tag, TACHYON_VERSION, target_tag);

    let backend_file = cmp.tmp_dir_path() + "/" + release.backend_name;
    let app_file = cmp.tmp_dir_path() + "/" + release.app_name;
    let i18n_file = release.i18n_url != "" ? cmp.tmp_dir_path() + "/" + release.i18n_name : "";
    if (!download_with_retry(release.backend_url, backend_file, release.backend_name) ||
        !download_with_retry(release.app_url, app_file, release.app_name) ||
        (release.i18n_url != "" && !download_with_retry(release.i18n_url, i18n_file, release.i18n_name)))
        action_fail("tachyon", "install_version", "Failed to download Tachyon release packages", TACHYON_VERSION, target_tag);

    let install_files = [ backend_file, app_file ];
    if (i18n_file != "")
        push(install_files, i18n_file);

    let install_result = pkg_tx_install_files(install_files, true);
    if (!install_result.success)
        action_fail("tachyon", "install_version", "Failed to install Tachyon packages: " + as_string(install_result.message), TACHYON_VERSION, target_tag);

    if (!verify_package_post_install("tachyon", target_tag))
        updates_log("Warning: Tachyon package version may not have been updated in package database", "warn");

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    restart_tachyon_after_successful_change();
    clear_version_caches();
    let new_version = installed_package_version("tachyon");
    if (new_version == "")
        new_version = target_tag;
    updates_log("Tachyon updated to " + new_version);
    let build_extra = record_tachyon_installed_build(new_version, release);
    action_success("tachyon", "install_version", "Tachyon has been installed", new_version, target_tag, 1, "latest", release.release_url, build_extra);
}

function dispatch_sing_box(action, target_tag) {
    if (action == "install_extended") {
        install_sing_box_extended(action, false, target_tag);
        return;
    }
    if (action == "install_extended_compressed") {
        install_sing_box_extended(action, true, target_tag);
        return;
    }
    if (action == "install_lx") {
        install_sing_box_lx(action, target_tag);
        return;
    }
    if (action == "install_tiny") {
        install_package_sing_box(action, true);
        return;
    }
    if (action == "install_stable") {
        install_package_sing_box(action, false);
        return;
    }

    let variant = sing_box_runtime_output("variant", []);
    if (variant == "lx")
        install_sing_box_lx(action, target_tag);
    else if (variant == "extended-compressed")
        install_sing_box_extended(action, true, target_tag);
    else if (variant == "extended")
        install_sing_box_extended(action, false, target_tag);
    else if (variant == "tiny")
        install_package_sing_box(action, true);
    else
        install_package_sing_box(action, false);
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "sing-box" || component == "singbox")
        return "sing_box";
    if (component == "fptn-client" || component == "fptn_client")
        return "fptn";
    if (component == "tachyon")
        return "tachyon";
    if (component == "direct-bypass" || component == "directbypass" || component == "direct_proxy")
        return "direct_bypass";
    if (component == "torrserver_direct" || component == "torrserver-direct")
        return "torrserver_direct";
    return component;
}

function component_backup_dir(component) {
    component = normalize_component_name(component);
    return COMPONENT_BACKUP_BASE_DIR + "/" + component;
}

function component_backup_metadata_file(component) {
    return component_backup_dir(component) + "/metadata.json";
}

function read_component_backup_metadata(component) {
    let file = component_backup_metadata_file(component);
    if (!file_exists(file))
        return null;
    let data = read_file(file);
    if (data == "")
        return null;
    try {
        let parsed = json(data);
        if (type(parsed) == "object" && parsed.version)
            return parsed;
    } catch (e) {}
    return null;
}

// Moved to line ~76 to avoid forward reference

// Moved to line ~66 to avoid forward reference

function create_component_backup(component) {
    component = normalize_component_name(component);
    if (!get_component_backup_enabled())
        return true;

    let bdir = component_backup_dir(component);
    let meta_file = component_backup_metadata_file(component);

    if (component == "sing_box") {
        if (!file_exists(SING_BOX_BIN))
            return true;
        let st = fs.stat(SING_BOX_BIN);
        let size = (st && st.size) ? st.size : 0;
        if (size <= 0)
            return true;

        if (!check_free_disk_space("/etc", size)) {
            updates_log("Skipping sing-box backup before update: insufficient disk space on /etc", "warn");
            return false;
        }

        ensure_dir(bdir);
        let backup_bin = bdir + "/sing-box";
        remove_file(backup_bin);
        if (!command_success_from_args([ "cp", "-p", SING_BOX_BIN, backup_bin ])) {
            updates_log("Failed to create sing-box backup copy", "warn");
            return false;
        }

        let variant = sing_box_runtime_output("variant", []);
        let marker = sing_box_runtime_output("read-variant-marker", []);
        let version = read_sing_box_binary_version(SING_BOX_BIN, "/usr/lib");
        if (version == "")
            version = sing_box_runtime_output("version", []);

        if (file_exists("/etc/init.d/sing-box")) {
            command_success_from_args([ "cp", "-p", "/etc/init.d/sing-box", bdir + "/sing-box.init" ]);
        }
        if (file_exists("/usr/lib/libcronet.so")) {
            command_success_from_args([ "cp", "-p", "/usr/lib/libcronet.so", bdir + "/libcronet.so" ]);
        }

        let meta = {
            component: "sing_box",
            version: version,
            variant: variant,
            marker: marker,
            size: size,
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        updates_log("Created local backup of sing-box v" + version + " (" + variant + ")", "info");
        return true;
    }
    else if (component == "byedpi") {
        if (!file_exists("/usr/bin/ciadpi"))
            return true;
        let st = fs.stat("/usr/bin/ciadpi");
        let size = (st && st.size) ? st.size : 0;
        if (!check_free_disk_space("/etc", size)) return false;
        ensure_dir(bdir);
        command_success_from_args([ "cp", "-p", "/usr/bin/ciadpi", bdir + "/ciadpi" ]);
        let version = trim(command_output("/usr/bin/ciadpi --version 2>&1 || true"));
        let meta = {
            component: "byedpi",
            version: version,
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        return true;
    }
    else if (component == "zapret") {
        let nfqws = "/opt/zapret/nfq/nfqws";
        if (!file_exists(nfqws)) nfqws = "/usr/bin/nfqws";
        if (!file_exists(nfqws)) return true;
        ensure_dir(bdir);
        command_success_from_args([ "cp", "-p", nfqws, bdir + "/nfqws" ]);
        let meta = {
            component: "zapret",
            version: provider_package_version(LIB_DIR + "/providers/zapret/runtime.uc"),
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        return true;
    }
    else if (component == "zapret2") {
        let nfqws2 = "/opt/zapret2/nfq2/nfqws2";
        if (!file_exists(nfqws2)) nfqws2 = "/opt/zapret2/nfq/nfqws2";
        if (!file_exists(nfqws2)) nfqws2 = "/usr/bin/nfqws2";
        if (!file_exists(nfqws2)) return true;
        ensure_dir(bdir);
        command_success_from_args([ "cp", "-p", nfqws2, bdir + "/nfqws2" ]);
        let meta = {
            component: "zapret2",
            version: provider_package_version(LIB_DIR + "/providers/zapret2/runtime.uc"),
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        return true;
    }
    else if (component == "tailscale") {
        if (!file_exists("/usr/sbin/tailscale")) return true;
        ensure_dir(bdir);
        command_success_from_args([ "cp", "-p", "/usr/sbin/tailscale", bdir + "/tailscale" ]);
        let meta = {
            component: "tailscale",
            version: provider_package_version(LIB_DIR + "/providers/tailscale/runtime.uc"),
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        return true;
    }
    else if (component == "fptn") {
        let bin = "/usr/bin/fptn-client-cli";
        if (!file_exists(bin)) bin = "/usr/bin/fptn-client";
        if (!file_exists(bin)) return true;
        let st = fs.stat(bin);
        let size = (st && st.size) ? st.size : 0;
        if (!check_free_disk_space("/etc", size)) return false;
        ensure_dir(bdir);
        command_success_from_args([ "cp", "-p", bin, bdir + "/fptn-client-cli" ]);
        let version = provider_package_version(LIB_DIR + "/providers/fptn/runtime.uc");
        let meta = {
            component: "fptn",
            version: version,
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        return true;
    }

    return true;
}

function rollback_component(component) {
    component = normalize_component_name(component);
    let bdir = component_backup_dir(component);
    let meta = read_component_backup_metadata(component);
    if (meta == null) {
        action_fail(component, "rollback", "No local backup found for " + component);
    }

    let backup_version = as_string(meta.version || "previous");
    updates_log("Starting rollback of " + component + " to backup version " + backup_version, "info");

    if (component == "sing_box") {
        let backup_bin = bdir + "/sing-box";
        if (!file_exists(backup_bin) || !file_nonempty(backup_bin)) {
            action_fail("sing_box", "rollback", "Sing-box backup binary is missing or empty");
        }

        stop_tachyon_before_sing_box_change();

        remove_file(SING_BOX_BIN);
        if (!command_success_from_args([ "cp", "-p", backup_bin, SING_BOX_BIN ]) ||
            !command_success_from_args([ "chmod", "0755", SING_BOX_BIN ])) {
            action_fail("sing_box", "rollback", "Failed to restore sing-box binary from backup");
        }

        if (file_exists(bdir + "/libcronet.so")) {
            remove_file("/usr/lib/libcronet.so");
            command_success_from_args([ "cp", "-p", bdir + "/libcronet.so", "/usr/lib/libcronet.so" ]);
            command_success_from_args([ "chmod", "0644", "/usr/lib/libcronet.so" ]);
        }

        if (file_exists(bdir + "/sing-box.init")) {
            command_success_from_args([ "cp", "-p", bdir + "/sing-box.init", "/etc/init.d/sing-box" ]);
            command_success_from_args([ "chmod", "0755", "/etc/init.d/sing-box" ]);
        }

        if (meta.marker) {
            write_sing_box_variant_state(meta.marker, backup_version);
        }

        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("sing_box", "rollback", "Sing-box rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "byedpi") {
        let backup_bin = bdir + "/ciadpi";
        if (!file_exists(backup_bin)) action_fail("byedpi", "rollback", "ByeDPI backup binary is missing");
        remove_file("/usr/bin/ciadpi");
        command_success_from_args([ "cp", "-p", backup_bin, "/usr/bin/ciadpi" ]);
        command_success_from_args([ "chmod", "0755", "/usr/bin/ciadpi" ]);
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("byedpi", "rollback", "ByeDPI rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "wdtt") {
        let backup_bin = bdir + "/wdtt";
        if (!file_exists(backup_bin)) action_fail("wdtt", "rollback", "WDTT backup binary is missing");
        remove_file("/usr/bin/wdtt");
        command_success_from_args([ "cp", "-p", backup_bin, "/usr/bin/wdtt" ]);
        command_success_from_args([ "chmod", "0755", "/usr/bin/wdtt" ]);
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("wdtt", "rollback", "WDTT rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "olcrtc") {
        let backup_bin = bdir + "/olcrtc";
        if (!file_exists(backup_bin)) action_fail("olcrtc", "rollback", "OlcRTC backup binary is missing");
        remove_file("/usr/bin/olcrtc");
        command_success_from_args([ "cp", "-p", backup_bin, "/usr/bin/olcrtc" ]);
        command_success_from_args([ "chmod", "0755", "/usr/bin/olcrtc" ]);
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("olcrtc", "rollback", "OlcRTC rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "fptn") {
        let backup_bin = bdir + "/fptn-client-cli";
        if (!file_exists(backup_bin)) action_fail("fptn", "rollback", "FPTN backup binary is missing");
        remove_file("/usr/bin/fptn-client-cli");
        command_success_from_args([ "cp", "-p", backup_bin, "/usr/bin/fptn-client-cli" ]);
        command_success_from_args([ "chmod", "0755", "/usr/bin/fptn-client-cli" ]);
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("fptn", "rollback", "FPTN rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "zapret") {
        let backup_bin = bdir + "/nfqws";
        if (!file_exists(backup_bin)) action_fail("zapret", "rollback", "Zapret backup binary is missing");
        if (file_exists("/opt/zapret/nfq/nfqws")) {
            command_success_from_args([ "cp", "-p", backup_bin, "/opt/zapret/nfq/nfqws" ]);
            command_success_from_args([ "chmod", "0755", "/opt/zapret/nfq/nfqws" ]);
        } else {
            command_success_from_args([ "cp", "-p", backup_bin, "/usr/bin/nfqws" ]);
            command_success_from_args([ "chmod", "0755", "/usr/bin/nfqws" ]);
        }
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("zapret", "rollback", "Zapret rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "zapret2") {
        let backup_bin = bdir + "/nfqws2";
        if (!file_exists(backup_bin)) action_fail("zapret2", "rollback", "Zapret2 backup binary is missing");
        let dest = "/opt/zapret2/nfq2/nfqws2";
        if (!file_exists(dest) && file_exists("/opt/zapret2/nfq/nfqws2")) dest = "/opt/zapret2/nfq/nfqws2";
        else if (!file_exists(dest) && file_exists("/usr/bin/nfqws2")) dest = "/usr/bin/nfqws2";
        command_success_from_args([ "cp", "-p", backup_bin, dest ]);
        command_success_from_args([ "chmod", "0755", dest ]);
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("zapret2", "rollback", "Zapret2 rolled back to " + backup_version, backup_version, "", 1);
    }
    else if (component == "tailscale") {
        let backup_bin = bdir + "/tailscale";
        if (!file_exists(backup_bin)) action_fail("tailscale", "rollback", "Tailscale backup binary is missing");
        command_success_from_args([ "cp", "-p", backup_bin, "/usr/sbin/tailscale" ]);
        command_success_from_args([ "chmod", "0755", "/usr/sbin/tailscale" ]);
        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("tailscale", "rollback", "Tailscale rolled back to " + backup_version, backup_version, "", 1);
    }
    else {
        action_fail(component, "rollback", "Rollback not supported for component " + component);
    }
}

function list_component_releases(component, count) {
    component = normalize_component_name(component);
    count = int(count || 3);
    if (count < 1) count = 1;
    if (count > 10) count = 10;

    let cache_file = "/tmp/tachyon-releases-" + component + ".json";
    let cached_stat = fs.stat(cache_file);
    if (cached_stat != null && (time() - cached_stat.mtime) < 600) {
        let cached_data = read_file(cache_file);
        if (cached_data != null && cached_data != "" && cached_data != "[]\n" && cached_data != "[]") {
            print(cached_data);
            return;
        }
    }

    let owner = "";
    let repo = "";
    let per_page = as_string(count);

    if (component == "tachyon") {
        let parts = split(TACHYON_RELEASE_REPO, "/");
        if (length(parts) != 2) { print("[]\n"); return; }
        owner = parts[0]; repo = parts[1];
    } else if (component == "sing_box") {
        let variant = sing_box_runtime_output("variant", []);
        if (variant == "lx") { owner = "Leadaxe"; repo = "sing-box-lx"; }
        else if (variant == "extended" || variant == "extended-compressed") { owner = "shtorm-7"; repo = "sing-box-extended"; }
        else { owner = "SagerNet"; repo = "sing-box"; }
    } else if (component == "zapret") {
        owner = "remittor"; repo = "zapret-openwrt";
    } else if (component == "zapret2") {
        owner = "Dushnilin"; repo = "zapret2-openwrt";
    } else if (component == "byedpi") {
        owner = "DPITrickster"; repo = "ByeDPI-OpenWrt";
    } else if (component == "wdtt") {
        owner = "Dushnilin"; repo = "qwdtt-openwrt";
    } else if (component == "olcrtc") {
        owner = "Dushnilin"; repo = "openwrt-olcrtc";
    } else if (component == "fptn") {
        owner = "Dushnilin"; repo = "fptn";
    } else {
        print("[]\n"); return;
    }

    let releases_json = fetch_github_releases_json(owner, repo, per_page);
    if ((releases_json == "" || releases_json == "[]") && (component == "wdtt" || component == "olcrtc" || component == "fptn")) {
        if (component == "wdtt") { owner = "SpaceNeuroX"; repo = "qwdtt-openwrt"; }
        else if (component == "olcrtc") { owner = "alekvol"; repo = "openwrt-olcrtc"; }
        else if (component == "fptn") { owner = "fptn-project"; repo = "fptn"; }
        releases_json = fetch_github_releases_json(owner, repo, per_page);
    }
    if (releases_json == "" || releases_json == "[]") { print("[]\n"); return; }

    let releases = [];
    try {
        let parsed = json(releases_json);
        if (type(parsed) == "array") {
            for (let r in parsed) {
                let tag = trim(as_string(r.tag_name || ""));
                let name = trim(as_string(r.name || tag));
                let published = trim(as_string(r.published_at || r.created_at || ""));
                let html_url = trim(as_string(r.html_url || ""));
                if (tag == "") continue;
                let prerelease = !!r.prerelease;
                push(releases, { tag, name, published, prerelease, release_url: html_url });
            }
        }
    } catch (e) {}

    if (length(releases) > 0) {
        let f = fs.open(cache_file, "w");
        if (f) {
            f.write(sprintf("%J\n", releases));
            f.close();
        }
    }
    write_json(releases);
}

function install_component_version(component, tag) {
    component = normalize_component_name(component);
    tag = trim(as_string(tag));
    if (tag == "" || component == "") {
        action_fail(component != "" ? component : "unknown", "install_version", "Invalid component or version tag specified");
    }

    create_component_backup(component);

    if (component == "tachyon") {
        install_tachyon_version(tag);
    } else if (component == "sing_box") {
        dispatch_sing_box("install", tag);
    } else if (component == "zapret") {
        install_zapret("install", tag);
    } else if (component == "zapret2") {
        install_zapret2("install", tag);
    } else if (component == "byedpi") {
        install_byedpi("install", tag);
    } else if (component == "wdtt") {
        install_wdtt("install", tag);
    } else if (component == "olcrtc") {
        install_olcrtc("install", tag);
    } else if (component == "fptn") {
        install_fptn("install", tag);
    } else {
        action_fail(component, "install_version", "Component " + component + " does not support version installation");
    }
}

function set_direct_bypass(action) {
    let enable = action == "enable";
    let cursor = uci_core.cursor();
    cursor.load("tachyon");

    if (enable) {
        cursor.set("tachyon", "settings", "direct_bypass_enabled", "1");
        let current_port = trim(as_string(cursor.get("tachyon", "settings", "direct_bypass_port") || ""));
        if (current_port == "" || match(current_port, /^[0-9]+$/) == null)
            cursor.set("tachyon", "settings", "direct_bypass_port", "2080");
    } else {
        cursor.set("tachyon", "settings", "direct_bypass_enabled", "0");
    }
    cursor.commit("tachyon");

    remove_file(SYSTEM_INFO_CACHE_FILE);
    restart_tachyon_after_successful_change();

    action_success(
        "direct_bypass",
        action,
        enable ? "Direct bypass enabled" : "Direct bypass disabled",
        enable ? "enabled" : "disabled",
        enable ? "enabled" : "disabled",
        1
    );
}

const TORRSERVER_DIRECT_INIT = getenv("TACHYON_TORRSERVER_DIRECT_INIT") || "/etc/init.d/tachyon-torrserver-direct";
const TORRSERVER_DIRECT_UC = LIB_DIR + "/torrserver/direct.uc";

function set_torrserver_direct(action) {
    let cursor = uci_core.cursor();
    cursor.load("tachyon");
    let current_enabled = trim(as_string(cursor.get("tachyon", "settings", "torrserver_direct_enabled") || "0")) == "1" ? "1" : "0";
    let target_enabled = action == "enable" ? "1" : "0";

    if (!file_exists(TORRSERVER_DIRECT_INIT) || !file_exists(TORRSERVER_DIRECT_UC))
        action_fail("torrserver_direct", action, "TorrServer Direct service is not available", current_enabled, target_enabled);

    if (target_enabled == "1") {
        if (!command_success_from_args([ "modprobe", "nft_socket" ]) &&
            (!run_logged("Installing TorrServer Direct kernel support", pkg_install_name_command("kmod-nft-socket")) ||
             !command_success_from_args([ "modprobe", "nft_socket" ])))
            action_fail("torrserver_direct", action, "This firmware does not provide kmod-nft-socket required for TorrServer Direct", current_enabled, target_enabled);
        let status = null;
        try {
            status = json(command_output_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "status" ]));
        } catch (e) {}
        if (type(status) != "object" || int(status.running || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer is not running", current_enabled, target_enabled);
        if (int(status.available || 0) != 1)
            action_fail("torrserver_direct", action, "TorrServer does not have a dedicated cgroup", current_enabled, target_enabled);
    }

    cursor.set("tachyon", "settings", "torrserver_direct_enabled", target_enabled);
    cursor.commit("tachyon");

    let applied = target_enabled == "1"
        ? command_success_from_args([ TORRSERVER_DIRECT_INIT, "enable" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "restart" ]) &&
            command_success_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "reconcile" ])
        : command_success_from_args([ TORRSERVER_DIRECT_INIT, "stop" ]) &&
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "disable" ]);
    if (!applied) {
        cursor.set("tachyon", "settings", "torrserver_direct_enabled", current_enabled);
        cursor.commit("tachyon");
        action_fail("torrserver_direct", action, "Failed to apply TorrServer Direct settings", current_enabled, target_enabled);
    }
    remove_file(SYSTEM_INFO_CACHE_FILE);
    action_success(
        "torrserver_direct",
        action,
        target_enabled == "1" ? "TorrServer Direct has been enabled" : "TorrServer Direct has been disabled",
        target_enabled == "1" ? "enabled" : "disabled",
        target_enabled == "1" ? "enabled" : "disabled",
        current_enabled == target_enabled ? 0 : 1
    );
}

function component_action(component, action, extra) {
    component = normalize_component_name(component);
    action = as_string(action);
    if (!acquire_component_lock()) {
        if (action == "check_update") {
            updates_log("Component action lock is busy; skipping background check for " + component, "debug");
            updates_response(false, component, action, "Another component action is already running", "", "", 0, "busy", "", null);
            cleanup_action();
            exit(0);
        }
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Another component action is already running");
    }
    if (!init_tmp_dir())
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Failed to create temporary directory");
    capture_tachyon_running_state();

    if (action == "rollback") {
        rollback_component(component);
        return;
    }

    if (action == "install_version") {
        install_component_version(component, extra);
        return;
    }

    if (action != "check_update" && action != "remove" && component != "direct_bypass" && component != "torrserver_direct") {
        create_component_backup(component);
    }

    if (component == "tachyon" && action == "check_update")
        check_tachyon();
    else if (component == "tachyon" && action == "install")
        install_tachyon();
    else if (component == "tachyon" && action == "reinstall")
        reinstall_tachyon();
    else if (component == "sing_box" && (action == "check_update" || action == "install" ||
        action == "install_extended" || action == "install_extended_compressed" ||
        action == "install_lx" ||
        action == "install_tiny" || action == "install_stable"))
        dispatch_sing_box(action);
    else if (component == "zapret" && (action == "check_update" || action == "install"))
        install_zapret(action);
    else if (component == "zapret" && action == "remove")
        remove_optional_component("zapret", "zapret", "zapret", LIB_DIR + "/providers/zapret/runtime.uc");
    else if (component == "zapret2" && (action == "check_update" || action == "install"))
        install_zapret2(action);
    else if (component == "zapret2" && action == "remove")
        remove_optional_component("zapret2", "zapret2", "zapret2", LIB_DIR + "/providers/zapret2/runtime.uc");
    else if (component == "byedpi" && (action == "check_update" || action == "install"))
        install_byedpi(action);
    else if (component == "byedpi" && action == "remove")
        remove_optional_component("byedpi", "byedpi", "ByeDPI", LIB_DIR + "/providers/byedpi/runtime.uc");
    else if (component == "wdtt" && (action == "check_update" || action == "install"))
        install_wdtt(action);
    else if (component == "wdtt" && action == "remove")
        remove_optional_component("wdtt", "wdtt", "WDTT", LIB_DIR + "/providers/wdtt/runtime.uc");
    else if (component == "olcrtc" && (action == "check_update" || action == "install"))
        install_olcrtc(action);
    else if (component == "olcrtc" && action == "remove")
        remove_optional_component("olcrtc", "olcrtc", "OlcRTC", LIB_DIR + "/providers/olcrtc/runtime.uc");
    else if (component == "fptn" && (action == "check_update" || action == "install"))
        install_fptn(action);
    else if (component == "fptn" && action == "remove")
        remove_optional_component("fptn", "fptn-client", "FPTN", LIB_DIR + "/providers/fptn/runtime.uc");
    else if (component == "tailscale" && (action == "check_update" || action == "install"))
        install_tailscale(action);
    else if (component == "tailscale" && action == "remove")
        remove_optional_component("tailscale", "tailscale", "Tailscale", LIB_DIR + "/providers/tailscale/runtime.uc");
    else if (component == "direct_bypass" && (action == "enable" || action == "disable"))
        set_direct_bypass(action);
    else if (component == "torrserver_direct" && (action == "enable" || action == "disable"))
        set_torrserver_direct(action);
    else
        action_fail(component != "" ? component : "unknown", action != "" ? action : "unknown", "Unknown component action");
}

let mode = ARGV[0] || "";

if (mode == "component-action") {
    try {
        component_action(ARGV[1], ARGV[2], ARGV[3]);
    } catch (e) {
        let err_str = as_string(e);
        updates_log("Unhandled component action error: " + err_str, "error");
        action_fail(ARGV[1] || "unknown", ARGV[2] || "unknown", "Unexpected error: " + err_str);
    }
}
else if (mode == "list-component-releases")
    list_component_releases(ARGV[1], ARGV[2]);
else if (mode == "install-component-version") {
    try {
        component_action(ARGV[1], "install_version", ARGV[2]);
    } catch (e) {
        let err_str = as_string(e);
        updates_log("Unhandled install component version error: " + err_str, "error");
        action_fail(ARGV[1] || "unknown", "install_version", "Unexpected error: " + err_str);
    }
}
else if (mode == "latest-tachyon-release-json")
    print(latest_tachyon_release_json());
else if (mode == "latest-tachyon-version")
    print(latest_tachyon_version(), "\n");
else if (mode == "tachyon-release-metadata")
    print(fetch_tachyon_latest_release_metadata(), "\n");
else if (mode == "pkg-install-files-command")
    print(pkg_install_files_command(slice(ARGV, 2), ARGV[1] == "1"), "\n");
else {
    warn("Usage: components/action.uc <component-action|list-component-releases|install-component-version|latest-tachyon-version|tachyon-release-metadata> ...\n");
    exit(1);
}