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
let engine = require("core.engine");

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

// Budgets for the package-manager steps, named so they are tuned in one place.
// The 30s index refresh was measured far too small: a cold `apk update` on a
// router whose feed list includes mirrors that answer with errors has to
// download and retry every index, and the run was cut off mid-way. Because
// coreutils-timeout exits 124 and the result was being reported as 252, the log
// showed an unexplained failure rather than an expired command.
const PKG_LIST_UPDATE_TIMEOUT = int(getenv("TACHYON_PKG_LIST_UPDATE_TIMEOUT") || "180");
const PKG_INSTALL_TIMEOUT = int(getenv("TACHYON_PKG_INSTALL_TIMEOUT") || "300");
const TACHYON_CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const SYSTEM_INFO_CACHE_FILE = getenv("TACHYON_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
// Persistent, not RUNTIME_STATE_DIR: the fingerprint describes the build that is
// on disk, so it has to survive a reboot the same way the package does.
const TACHYON_BUILD_STATE_FILE = getenv("TACHYON_BUILD_STATE_FILE") || "/etc/.tachyon/build-state";
const COMPONENT_LOCK_DIR = getenv("UPDATES_LOCK_DIR") || RUNTIME_STATE_DIR + "/component-action.lock";
const TMP_STALE_TTL_MINUTES = getenv("UPDATES_TMP_STALE_TTL_MINUTES") || "30";
const TMP_FILE_STALE_TTL_MINUTES = getenv("UPDATES_TMP_FILE_STALE_TTL_MINUTES") || "10";
const CORE_MANAGED_SERVICE_MARKER = getenv("TACHYON_CORE_MANAGED_SERVICE_MARKER") || constants.CORE_MANAGED_SERVICE_MARKER || "Tachyon managed tachyon-core service";

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
let copy_file_stream = common.copy_file_stream;
let bounded_command = common.bounded_command;
let kill_matching_command = common.kill_matching_command;

let lock_held = false;
let tachyon_was_running = false;
let tachyon_stopped_for_core_change = false;

// ============================================================================
// Helper constants and functions hoisted to avoid forward references
// ============================================================================

const TACHYON_CORE_BIN = getenv("TACHYON_CORE_BIN") || "/usr/bin/tachyon-core";
const COMPONENT_BACKUP_BASE_DIR = getenv("TACHYON_COMPONENT_BACKUPS_DIR") || "/etc/tachyon/component-backups";

function get_component_backup_enabled() { return cmp.get_component_backup_enabled(); }

function check_free_disk_space(target_dir, needed_bytes) { return cmp.check_free_disk_space(target_dir, needed_bytes); }

// ============================================================================

// Delegated to components/* modules (branch 4 god-module split).
function str_startswith(value, prefix) { return cmp.str_startswith(value, prefix); }
function str_endswith(value, suffix) { return cmp.str_endswith(value, suffix); }
function command_env(assignments) { return cmp.command_env(assignments); }
function command_output_lenient(command) { return cmp.command_output_lenient(command); }
function command_exists(name) { return cmp.command_exists(name); }
function read_file(path) { return cmp.read_file(path); }
function remove_file(path) { return cmp.remove_file(path); }
function ensure_dir(path) { return cmp.ensure_dir(path); }
function file_exists(path) { return cmp.file_exists(path); }
function file_nonempty(path) { return cmp.file_nonempty(path); }
function now_seconds() { return cmp.now_seconds(); }
function owner_pid() { return cmp.owner_pid(); }
function pid_running(pid) { return cmp.pid_running(pid); }
function log_message(message, level) { return cmp.log_message(message, level); }
function job_log_time() { return cmp.job_log_time(); }
function job_log_append(message, level) { return cmp.job_log_append(message, level); }
function updates_log(message, level) { return cmp.updates_log(message, level); }
function sanitize_package_log_line(message) { return cmp.sanitize_package_log_line(message); }
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
    let notes = (cmp_dl && type(cmp_dl.get_release_notes) == "function")
        ? as_string(cmp_dl.get_release_notes(release_url, latest_version) || "")
        : "";
    if (notes != "")
        obj.release_notes = notes;
    // Merge optional extra fields (e.g. current_sha, latest_sha) without breaking existing callers
    if (type(extra) == "object") {
        for (let k, v in extra)
            obj[k] = v;
    }
    write_json(obj);
}

function restart_tachyon_after_failed_core_change() {
    if (!tachyon_stopped_for_core_change || !tachyon_was_running || !file_exists(SERVICE_INIT))
        return;
    updates_log("Restarting Tachyon after failed core component change");
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
    restart_tachyon_after_failed_core_change();
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

// Installs a downloaded package file, releasing stale apk world entries first.
//
// apk reads /etc/apk/world before it selects anything, so a world entry left
// behind by an earlier Tachyon makes the whole set unselectable and apk rolls
// the transaction back - which runs the prerm/postrm hooks of everything in it
// and leaves the router without the component that was just added
// (TCH-1050/TCH-1051). Self-update and package transactions go through
// pkg_tx_install_* and sanitize; run_logged_pkg_install_files() does the same
// before pkg_install_files_command().
//
// run_logged() itself is not the place: it also runs restarts and probes, and
// scrubbing world on those would be wrong.
function run_logged_pkg_install_files(description, files, timeout_seconds, force_reinstall) {
    sanitize_apk_world();
    if (run_logged(description, pkg_install_files_command(files, force_reinstall), timeout_seconds))
        return true;
    if (is_apk() && cmp_inst.apk_satisfy_missing_files_deps(files)) {
        let offline_args = [ "apk", "add", "--allow-untrusted", "--force-overwrite", "--no-network", "--repositories-file", "/dev/null" ];
        for (let file in files)
            push(offline_args, file);
        return run_logged(description + " (offline fallback)", command_from_args(offline_args) + " </dev/null", timeout_seconds);
    }
    return false;
}

function pkg_tx_update_index(proxy_address) { return cmp_inst.pkg_tx_update_index(proxy_address); }

function pkg_tx_install_files(files, force_reinstall) { return cmp_inst.pkg_tx_install_files(files, force_reinstall); }

function pkg_tx_install_name(package_name, proxy_address) { return cmp_inst.pkg_tx_install_name(package_name, proxy_address); }

function pkg_install_files(files, force_reinstall) { return cmp_inst.pkg_install_files(files, force_reinstall); }
function run_logged_retrying(description, command) { return cmp.run_logged_retrying(description, command); }

function pkg_remove_conflict(package_name) { return cmp_inst.pkg_remove_conflict(package_name); }
function run_logged_pkg_remove_conflict(package_name, description) { return cmp_inst.run_logged_pkg_remove_conflict(package_name, description); }
function compare_versions(lhs, rhs) { return cmp_ver.compare_versions(lhs, rhs); }
function status_from_compare(compare_result) { return cmp_ver.status_from_compare(compare_result); }



function check_success_compared(component, current_version, latest_version, compare_current_version, compare_latest_version, release_url, log_label) {
    let compare_result = compare_versions(compare_current_version, compare_latest_version);
    if (compare_result == null)
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let status = status_from_compare(compare_result);
    if (status == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let display_label = as_string(log_label) != "" ? as_string(log_label) : component;
    let result_row = trim(helper_output("updates-check-result-row", [ display_label, current_version, latest_version, status ]));
    if (result_row == "")
        action_fail(component, "check_update", "Failed to compare versions", current_version, latest_version);

    let fields = split(result_row, "\t");
    let message = as_string(fields[0] || "");
    let log_line = length(fields) > 1 ? as_string(fields[1]) : message;
    updates_log(log_line);
    action_success(component, "check_update", message, current_version, latest_version, 0, status, release_url || "");
}

function check_success(component, current_version, latest_version, release_url, log_label) {
    check_success_compared(component, current_version, latest_version, current_version, latest_version, release_url || "", log_label || "");
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

function fetch_github_releases_json(owner, repo, per_page, page) { return cmp_dl.fetch_github_releases_json(owner, repo, per_page, page); }


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
function ensure_core_dependencies() { return cmp_inst.ensure_core_dependencies(); }


// Delegated to components/catalog.uc (branch 4 god-module split).
function clear_version_caches() { return cmp_cat.clear_version_caches(); }

function core_process_module_or_null() {
    try {
        return require("core.process");
    } catch (e) {
        return null;
    }
}

function fallback_init_script_kills_itself(text) {
    for (let line in split(as_string(text), "\n")) {
        if (index(line, "killall") < 0)
            continue;
        if (match(line, /(^|[^A-Za-z0-9_-])tachyon-core([^A-Za-z0-9_-]|$)/) != null)
            return true;
    }
    return false;
}

function fallback_managed_core_init_script(marker, reset_log) {
    marker = as_string(marker);
    if (marker == "")
        marker = "Tachyon managed tachyon-core service";
    let log_prep = "";
    if (reset_log)
        log_prep = "    mkdir -p /tmp/tachyon-core 2>/dev/null\n" +
            "    : > /tmp/tachyon-core/tachyon-core.log 2>/dev/null\n";
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + marker + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/tachyon-core\"\n\n" +
        "_kill_daemon_instances() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core) kill -9 \"$p\" 2>/dev/null || true ;;\n" +
        "        esac\n" +
        "    done\n" +
        "}\n\n" +
        "_has_running_daemon() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core) return 0 ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    return 1\n" +
        "}\n\n" +
        "start_service() {\n" +
        "    [ -d /dev/net ] || mkdir -p /dev/net\n" +
        "    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true\n" +
        "    modprobe tun 2>/dev/null || true\n" +
        "    modprobe inet_diag 2>/dev/null || true\n\n" +
        "    config_load \"tachyon-core\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    [ -x \"$PROG\" ] || PROG=\"$(command -v tachyon-core 2>/dev/null || echo /usr/bin/tachyon-core)\"\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/tachyon-core/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/tachyon-core\"\n" +
        "    [ -d \"$working_directory\" ] || mkdir -p \"$working_directory\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    local mem_limit_mb=\"0\"\n" +
        "    config_get mem_limit_mb \"main\" \"memory_limit_mb\" \"0\"\n" +
        "    if [ \"$mem_limit_mb\" = \"0\" ] || [ -z \"$mem_limit_mb\" ]; then\n" +
        "        mem_limit_mb=\"$(uci get tachyon.settings.memory_limit_mb 2>/dev/null || echo 0)\"\n" +
        "    fi\n\n" +
        "    local scale_pct=\"\"\n" +
        "    if [ -s \"/etc/tachyon/mem_scale\" ]; then\n" +
        "        scale_pct=\"$(awk -v s=\"$(cat /etc/tachyon/mem_scale 2>/dev/null)\" 'BEGIN { if (!s) exit; pct=int(s*100); if (pct < 20) pct=20; if (pct > 100) pct=100; print pct }')\"\n" +
        "    fi\n\n" +
        "    local gomemlimit=\"\"\n" +
        "    local mem_total_kb=\"$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)\"\n" +
        "    if [ \"$mem_limit_mb\" -gt 0 ] 2>/dev/null; then\n" +
        "        gomemlimit=\"$mem_limit_mb\"\n" +
        "    elif [ \"$mem_total_kb\" -gt 0 ]; then\n" +
        "        if [ \"$mem_total_kb\" -le 524288 ] || { [ -n \"$scale_pct\" ] && [ \"$scale_pct\" -lt 100 ]; }; then\n" +
        "            gomemlimit=$(( mem_total_kb / 1024 * 50 / 100 ))\n" +
        "            [ \"$gomemlimit\" -lt 24 ] && gomemlimit=24\n" +
        "        fi\n" +
        "    fi\n\n" +
        "    if [ -n \"$gomemlimit\" ] && [ \"$gomemlimit\" -gt 0 ] 2>/dev/null; then\n" +
        "        if [ -n \"$scale_pct\" ] && [ \"$scale_pct\" -lt 100 ]; then\n" +
        "            gomemlimit=$(( gomemlimit * scale_pct / 100 ))\n" +
        "            [ \"$gomemlimit\" -lt 16 ] && gomemlimit=16\n" +
        "        fi\n" +
        "    fi\n\n" +
        log_prep +
        "    _kill_daemon_instances\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"0\"\n" +
        "    procd_set_param limits nofile=\"65535 65535\"\n" +
        "    if [ -n \"$gomemlimit\" ] && [ \"$gomemlimit\" -gt 0 ] 2>/dev/null; then\n" +
        "        procd_set_param env GODEBUG=\"madvdontneed=1\" GOGC=\"50\" TACHYON_RULESET_SOFT_START=\"1\" GOMEMLIMIT=\"${gomemlimit}MiB\"\n" +
        "    else\n" +
        "        procd_set_param env GODEBUG=\"madvdontneed=1\" GOGC=\"50\" TACHYON_RULESET_SOFT_START=\"1\"\n" +
        "    fi\n" +
        "    procd_set_param term_timeout 15\n" +
        "    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-0}\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "stop_service() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core) kill -TERM \"$p\" 2>/dev/null || true ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    local i=0\n" +
        "    while [ \"$i\" -lt 20 ]; do\n" +
        "        _has_running_daemon || return 0\n" +
        "        sleep 0.1 2>/dev/null || sleep 1\n" +
        "        i=$(( i + 1 ))\n" +
        "    done\n" +
        "    _kill_daemon_instances\n" +
        "}\n\n" +
        "reload_service() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core)\n" +
        "                if ucode -L /usr/lib/tachyon /usr/lib/tachyon/service/state.uc sighup-core-runtime \"$p\" >/dev/null 2>&1; then\n" +
        "                    return 0\n" +
        "                fi\n" +
        "                break\n" +
        "                ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    restart\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"tachyon-core\"\n" +
        "}\n";
}

function managed_core_service_installed() {
    let data = fs.readfile("/etc/init.d/tachyon-core");
    if (data == null)
        return false;
    let s = as_string(data);
    let cp = core_process_module_or_null();
    let kills_self = (cp && type(cp.init_script_kills_itself) == "function")
        ? cp.init_script_kills_itself(s)
        : fallback_init_script_kills_itself(s);
    return index(s, CORE_MANAGED_SERVICE_MARKER) >= 0 &&
        index(s, "GOGC=\"50\"") >= 0 &&
        index(s, "stop_service()") >= 0 &&
        index(s, "kill -TERM") >= 0 &&
        index(s, "reload_service()") >= 0 &&
        !kills_self;
}

function managed_core_service_text() {
    let cp = core_process_module_or_null();
    if (cp && type(cp.managed_core_init_script) == "function")
        return cp.managed_core_init_script(CORE_MANAGED_SERVICE_MARKER, true);
    return fallback_managed_core_init_script(CORE_MANAGED_SERVICE_MARKER, true);
}

function install_managed_core_service_script() {
    let tmp = "/etc/init.d/tachyon-core.tachyon." + owner_pid();
    if (!write_file(tmp, managed_core_service_text()))
        return false;
    if (!command_success_from_args([ "chmod", "0755", tmp ])) {
        remove_file(tmp);
        return false;
    }
    return fs.rename(tmp, "/etc/init.d/tachyon-core");
}

function remove_managed_core_service_script() {
    if (!managed_core_service_installed())
        return true;
    command_success_from_args([ "/etc/init.d/tachyon-core", "stop" ]);
    command_success_from_args([ "/etc/init.d/tachyon-core", "disable" ]);
    remove_file("/etc/init.d/tachyon-core");
    return true;
}

function disable_core_service_config() {
    if (!uci_core.available())
        return true;
    if (!uci_core.exists("tachyon-core.main") && !uci_core.set_section("tachyon-core.main", "tachyon-core"))
        return false;
    if (!uci_core.set("tachyon-core.main.enabled", "0"))
        return false;
    return uci_core.commit("tachyon-core");
}

function prepare_core_service_disabled() {
    disable_core_service_config();
    if (file_exists("/etc/init.d/tachyon-core")) {
        command_success_from_args([ "/etc/init.d/tachyon-core", "stop" ]);
        command_success_from_args([ "/etc/init.d/tachyon-core", "disable" ]);
    }
}

function prepare_core_package_service_install() {
    prepare_core_service_disabled();
    remove_managed_core_service_script();
}

function tachyon_status_running_with_timeout() {
    init_tmp_dir();
    let output_file = make_tmp_file("tachyon-status");
    if (output_file == "")
        return false;

    let command = command_from_args([ BIN_PATH, "get_status" ]) + " >" + shell_quote(output_file) + " 2>/dev/null & pid=$!; " +
        "( sleep 15; kill $pid 2>/dev/null || true ) & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    let ok = command_status("sh -c " + shell_quote(command)) == 0 &&
        match(read_file(output_file), /"running"[ \t]*:[ \t]*1/) != null;
    remove_file(output_file);
    return ok;
}

function capture_tachyon_running_state() {
    if (!file_exists(BIN_PATH)) {
        tachyon_was_running = false;
        return;
    }
    // get_status includes nft/policy-routing readiness, which is intentionally
    // false in failsafe. Preserve runtime intent before update stops the core.
    // A manual stop writes shutdown_correctly=1 even if core.enabled stays 1.
    let cfg = common.object_or_empty(uci_core.get_all(TACHYON_CONFIG_NAME, "settings"));
    let intended = engine.get_active() == "tachyon-core" &&
        cfg.shutdown_correctly == "0" && uci_core.get("tachyon-core", "main", "enabled") == "1" &&
        !require("service.firewall_health").manual_bypass_active(cfg);
    tachyon_was_running = tachyon_status_running_with_timeout() || intended;
}

function restart_tachyon_after_successful_change(skip_reload_if_running) {
    if (!tachyon_was_running) {
        updates_log("Tachyon was not running before component change; restart skipped");
        prepare_core_service_disabled();
        return true;
    }

    if (skip_reload_if_running && !tachyon_stopped_for_core_change && tachyon_status_running_with_timeout()) {
        updates_log("Tachyon is already running after package postinst; skipping redundant reload");
        return true;
    }

    // Clear any stuck flock holders or pending rc.common waits
    system(kill_matching_command("-E '99-tachyon-wan|flock 1000|init[.]d/tachyon'"));
    // Kill orphaned logread -f processes before restart to prevent FD cascade.
    // Anchor with $ to avoid killing system logremote/logfile processes (which
    // have extra flags like -r/-F after -f).
    // BusyBox lacks pkill, so we use pgrep + kill via common.kill_orphaned_logread().
    system(common.kill_orphaned_logread());
    system("rm -f /var/run/tachyon.reload.lock 2>/dev/null; true");

    // If tachyon-core was NOT stopped for this component change (e.g. rulesets,
    // etc.), Tachyon is still running and tachyon-core routing is intact.
    // Perform a soft reload (`reload force`) via BIN_PATH. This bypasses rc.common flock,
    // reloads runtime state and nftables without tearing down tachyon-core or dropping active connections.
    if (!tachyon_stopped_for_core_change && file_exists(BIN_PATH) && tachyon_status_running_with_timeout()) {
        let reloaded = run_logged("Reloading Tachyon after successful component change", command_from_args([ BIN_PATH, "reload", "force" ]), 300);
        if (reloaded)
            return true;
        updates_log("Tachyon reload returned non-zero; falling back to full restart", "warn");
    }

    let target_bin = file_exists(BIN_PATH) ? BIN_PATH : SERVICE_INIT;
    if (!file_exists(target_bin))
        return false;

    let action_name = (!tachyon_stopped_for_core_change && tachyon_status_running_with_timeout()) ? "restart" : "start";
    return run_logged("Restarting Tachyon after successful component change", command_from_args([ target_bin, action_name ]), 300);
}

function stop_tachyon_before_core_change() {
    if (tachyon_stopped_for_core_change)
        return;
    tachyon_stopped_for_core_change = true;

    let stop_bin = file_exists(BIN_PATH) ? BIN_PATH : SERVICE_INIT;
    if (tachyon_was_running && file_exists(stop_bin))
        run_logged("Stopping Tachyon before tachyon-core update", command_from_args([ stop_bin, "stop" ]), 30);

    if (tachyon_was_running && file_exists(BIN_PATH) &&
        uci_core.get(TACHYON_CONFIG_NAME, "settings", "keep_dns_on_upgrade") == "0")
        command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);

    prepare_core_service_disabled();
}

function get_core_cache_paths() {
    let paths = [];
    let seen = {};
    let add_path = function(p) {
        p = as_string(p);
        if (p != "" && !seen[p]) {
            seen[p] = true;
            push(paths, p);
        }
    };

    if (uci_core.available()) {
        try {
            let configured = uci_core.get(TACHYON_CONFIG_NAME, "settings", "cache_path");
            if (configured)
                add_path(configured);
        } catch (e) {}
    }

    add_path("/tmp/tachyon-core/cache.db");
    add_path("/usr/share/tachyon-core/cache.db");
    add_path("/etc/tachyon-core/cache.db");
    return paths;
}

function clear_core_cache_files(reason) {
    let cleared = 0;
    let paths = get_core_cache_paths();
    for (let p in paths) {
        if (file_exists(p)) {
            remove_file(p);
            cleared++;
        }
        if (file_exists(p + "-lock"))
            remove_file(p + "-lock");
        if (file_exists(p + ".lock"))
            remove_file(p + ".lock");
        if (file_exists(p + "-journal"))
            remove_file(p + "-journal");
    }
    for (let dir in [ "/tmp/tachyon-core", "/etc/tachyon-core", "/usr/share/tachyon-core" ]) {
        if (file_exists(dir)) {
            try {
                let matches = fs.glob(dir + "/cache.db*");
                if (matches) {
                    for (let item in matches) {
                        let s = as_string(item);
                        if (length(s) >= 13 && substr(s, length(s) - 13) == ".rollback-bak")
                            continue;
                        remove_file(s);
                        cleared++;
                    }
                }
            } catch (e) {}
        }
    }
    updates_log("Cleared core cache database" + (reason ? " (" + reason + ")" : ""), "info");
    return cleared;
}

function backup_core_cache_files() {
    let backed_up = 0;
    for (let p in get_core_cache_paths()) {
        if (file_exists(p)) {
            remove_file(p + ".rollback-bak");
            if (fs.rename(p, p + ".rollback-bak"))
                backed_up++;
        }
    }
    return backed_up;
}

function restore_core_cache_backup() {
    let paths = get_core_cache_paths();
    let has_backup = false;
    for (let p in paths) {
        if (file_exists(p + ".rollback-bak")) {
            has_backup = true;
            break;
        }
    }
    if (!has_backup)
        return 0;

    clear_core_cache_files("rollback cleanup");
    let restored = 0;
    for (let p in paths) {
        if (file_exists(p + ".rollback-bak")) {
            remove_file(p);
            if (fs.rename(p + ".rollback-bak", p))
                restored++;
        }
    }
    if (restored > 0)
        updates_log("Restored previous core cache database after rollback", "info");
    return restored;
}

function cleanup_core_cache_backup() {
    let cleaned = 0;
    for (let p in get_core_cache_paths()) {
        if (file_exists(p + ".rollback-bak")) {
            remove_file(p + ".rollback-bak");
            cleaned++;
        }
        if (file_exists(p + ".tmp")) {
            remove_file(p + ".tmp");
            cleaned++;
        }
    }
    let bin_entries = fs.lsdir("/usr/bin");
    if (type(bin_entries) == "array") {
        for (let ent in bin_entries) {
            ent = as_string(ent);
            if (index(ent, "tachyon-core.bak") == 0) {
                remove_file("/usr/bin/" + ent);
                cleaned++;
            }
        }
    }
    return cleaned;
}

// Delegated to components/catalog.uc (branch 4 god-module split).
function opkg_arch_list() { return cmp_cat.opkg_arch_list(); }

// Delegated to components/catalog.uc (branch 4 god-module split).
function resolve_arch_candidates() { return cmp_cat.resolve_arch_candidates(); }

// Delegated to components/* modules (branch 4 god-module split).
function normalize_core_version(value) { return cmp_ver.normalize_core_version(value); }

// Delegated to components/* modules (branch 4 god-module split).
function extract_core_version_from_output(output) { return cmp_ver.extract_core_version_from_output(output); }
function read_core_binary_version(binary, library_dir) { return cmp_ver.read_core_binary_version(binary, library_dir); }
function verify_binary_post_install(binary_path, expected_version, version_cmd_args) { return cmp_verify.verify_binary_post_install(binary_path, expected_version, version_cmd_args); }
function check_core_config_with_binary(binary, config_path, library_dir) { return cmp_verify.check_core_config_with_binary(binary, config_path, library_dir); }


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

function is_symlink_path(path) {
    let st = fs.lstat(as_string(path));
    return st != null && (st.type == "link" || st.type == "lnk");
}

function resolve_tachyon_core_arch_suffix() {
    let host_arch = trim(command_output_from_args([ "uname", "-m" ]));
    let distrib_arch = read_openwrt_release_value("DISTRIB_ARCH");
    return trim(helper_output("tachyon-core-arch-suffix", [ host_arch, distrib_arch ]));
}

// Tachyon's native routing core, from Dushnilin/tachyon-core.
//
// The archive holds a binary prefixed with tachyon-core-<arch>-<ver>, matched
// by prefix rather than suffix.
const TACHYON_CORE_OWNER = "Dushnilin";
const TACHYON_CORE_REPO = "tachyon-core";
const TACHYON_CORE_LABEL = "tachyon-core";

function set_tachyon_core_release_from_json(release_json, allow_prerelease) {
    if (as_string(release_json) == "")
        return null;
    let tag = trim(helper_output_input(release_json, "object-get-default", [ "tag_name", "" ]));
    let lowered = lc(tag);
    if (!allow_prerelease && (tag == "" || index(lowered, "alpha") >= 0 || index(lowered, "beta") >= 0 || index(lowered, "rc") >= 0))
        return null;

    let arch_suffix = resolve_tachyon_core_arch_suffix();
    if (arch_suffix == "")
        return null;
    let pkg_ext = is_apk() ? "apk" : "ipk";
    let asset_url = trim(helper_output_input(release_json, "tachyon-core-asset-url", [ arch_suffix, pkg_ext ]));
    if (asset_url == "")
        return null;

    return {
        tag,
        release_url: trim(helper_output_input(release_json, "object-get-default", [ "html_url", "" ])),
        asset_url,
        asset_name: common.path_basename(asset_url)
    };
}

function resolve_tachyon_core_release(target_tag) {
    if (target_tag != null && target_tag != "") {
        let release_json = fetch_github_release_by_tag_json(TACHYON_CORE_OWNER, TACHYON_CORE_REPO, target_tag);
        let resolved = set_tachyon_core_release_from_json(release_json, true);
        if (resolved != null)
            return resolved;

        // No API answer: the asset name is derivable, so the download URL can be
        // built directly. Better than refusing, and the download reports the real
        // failure if the tag or the arch is wrong.
        let arch_suffix = resolve_tachyon_core_arch_suffix();
        if (arch_suffix == "")
            return null;
        let base_arch = replace(arch_suffix, "-musl", "");
        let pkg_ext = is_apk() ? "apk" : "ipk";
        let base_dl = "https://github.com/" + TACHYON_CORE_OWNER + "/" + TACHYON_CORE_REPO + "/releases/download/" + target_tag + "/";
        let pkg_asset_name = TACHYON_CORE_LABEL + "-" + base_arch + "-" + as_string(target_tag) + "." + pkg_ext;
        if (url_exists(base_dl + pkg_asset_name)) {
            return {
                tag: target_tag,
                release_url: "https://github.com/" + TACHYON_CORE_OWNER + "/" + TACHYON_CORE_REPO + "/releases/tag/" + target_tag,
                asset_url: base_dl + pkg_asset_name,
                asset_name: pkg_asset_name
            };
        }
        // Fallback to .tar.gz (either base_arch for v0.2.5+ or arch_suffix for older releases)
        let tgz_short = TACHYON_CORE_LABEL + "-" + base_arch + "-" + as_string(target_tag) + ".tar.gz";
        let asset_name = url_exists(base_dl + tgz_short)
            ? tgz_short
            : (TACHYON_CORE_LABEL + "-" + arch_suffix + "-" + as_string(target_tag) + ".tar.gz");
        return {
            tag: target_tag,
            release_url: "https://github.com/" + TACHYON_CORE_OWNER + "/" + TACHYON_CORE_REPO + "/releases/tag/" + target_tag,
            asset_url: base_dl + asset_name,
            asset_name
        };
    }

    let release_json = fetch_github_release_json(TACHYON_CORE_OWNER, TACHYON_CORE_REPO);
    let resolved = set_tachyon_core_release_from_json(release_json, false);
    if (resolved != null)
        return resolved;

    let releases_json = fetch_github_releases_json(TACHYON_CORE_OWNER, TACHYON_CORE_REPO, "30");
    let tag = trim(helper_output_input(releases_json, "tachyon-core-release-tag", []));
    if (tag == "")
        return null;
    release_json = helper_output_input(releases_json, "release-by-tag", [ tag ]);
    resolved = set_tachyon_core_release_from_json(release_json, false);
    if (resolved != null)
        return resolved;
    return resolve_tachyon_core_release(tag);
}

function tachyon_core_runtime_output(mode, args) {
    let command_args = [ LIB_DIR + "/tachyon_core/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return trim(module_output(command_args));
}

function tachyon_core_runtime_success(mode, args) {
    let command_args = [ LIB_DIR + "/tachyon_core/runtime.uc", mode ];
    for (let arg in (type(args) == "array" ? args : []))
        push(command_args, arg);
    return module_success(command_args);
}

// A downloaded core has to be proven to be tachyon-core before it is put in place
// of the running engine. A bare exit code check would accept an unrelated binary
// or a truncated download.
function validate_tachyon_core_binary(binary, library_dir) {
    binary = as_string(binary);
    if (binary == "" || !file_exists(binary)) {
        updates_log("tachyon-core binary not found at " + binary, "warn");
        return "";
    }

    command_success_from_args([ "chmod", "0755", binary ]);

    let command = command_from_args([ binary, "version" ]);
    let lib_path = as_string(library_dir || "");
    if (lib_path != "") {
        if (lib_path == "/usr/lib")
            lib_path = "/usr/lib:/lib";
        else
            lib_path = lib_path + ":/usr/lib:/lib";
        command = command_env({ LD_LIBRARY_PATH: lib_path }) + " " + command;
    }

    let raw_output = command_output_lenient("(" + command + ") 2>&1");
    let is_core = index(raw_output, "tachyon-core") >= 0 || index(raw_output, "-tachyon.") >= 0;
    if (!is_core) {
        let trimmed_output = trim(raw_output);
        let status = command_status_from_args([ binary, "version" ]);
        if (status == 132) {
            let host_arch = lc(trim(command_output_from_args([ "uname", "-m" ])));
            let distrib_arch = lc(read_openwrt_release_value("DISTRIB_ARCH"));
            if (index(host_arch, "mips") >= 0 || index(distrib_arch, "mips") >= 0) {
                updates_log("Downloaded binary crashed with SIGILL (Illegal instruction) - MIPS FPU / soft-float ABI mismatch (router CPU has no hardware FPU)", "error");
            } else if (host_arch == "x86_64" || index(distrib_arch, "x86_64") >= 0) {
                updates_log("Downloaded binary crashed with SIGILL (Illegal instruction) - your CPU lacks required AVX2/x86-64-v3 instructions (if on Proxmox/KVM VM, set CPU type to 'host')", "error");
            } else if (host_arch == "i386" || host_arch == "i486" || host_arch == "i586" || host_arch == "i686" || index(distrib_arch, "i386") >= 0 || index(distrib_arch, "x86") >= 0) {
                updates_log("Downloaded binary crashed with SIGILL (Illegal instruction) - your 32-bit x86 CPU lacks required i686/SSE2 instructions (if on a VM, set CPU type to 'host')", "error");
            } else {
                updates_log("Downloaded binary crashed with SIGILL (Illegal instruction) - CPU instruction set or ABI mismatch for architecture " + (distrib_arch != "" ? distrib_arch : host_arch), "error");
            }
        } else if (status > 128) {
            updates_log("Downloaded binary crashed with signal " + (status - 128) + (trimmed_output != "" ? "; output: " + trimmed_output : ""), "error");
        } else if (trimmed_output == "") {
            updates_log("Downloaded binary exited with code " + status + " without output", "warn");
        } else {
            updates_log("Downloaded binary does not identify as tachyon-core; output: " + trimmed_output, "warn");
        }
        return "";
    }

    let version = extract_core_version_from_output(raw_output);
    if (version == "") {
        let candidate = trim(helper_output_input(raw_output, "stdin-first-line-last-field", []));
        if (match(candidate, /^[vV]?[0-9]+/))
            version = candidate;
    }
    if (version == "") {
        updates_log("Failed to parse tachyon-core version from binary " + binary + "; output: " + trim(raw_output), "warn");
        return "";
    }

    updates_log("validated " + TACHYON_CORE_LABEL + " build " + version + " from " + binary, "info");
    return version;
}

function install_tachyon_core(action, target_tag) {
    init_tmp_dir() || action_fail("tachyon-core", action, "Failed to create temporary directory");
    let label = TACHYON_CORE_LABEL;
    let current_version = tachyon_core_runtime_output("version", []);
    if (current_version == "" && file_exists(TACHYON_CORE_BIN))
        current_version = read_core_binary_version(TACHYON_CORE_BIN, "");
    let release = resolve_tachyon_core_release(target_tag);
    if (release == null)
        action_fail("tachyon-core", action, "Failed to resolve " + label + " release", current_version);
    let latest_version = normalize_core_version(release.tag);

    if (action == "check_update") {
        if (current_version == "")
            action_success("tachyon-core", action, label + " is not installed", current_version, latest_version, 0, "", release.release_url);
        else
            check_success("tachyon-core", normalize_core_version(current_version), normalize_core_version(latest_version), release.release_url, label);
    }

    ensure_core_dependencies();

    let archive_file = cmp.tmp_dir_path() + "/" + release.asset_name;
    if (!download_with_retry(release.asset_url, archive_file, release.asset_name))
        action_fail("tachyon-core", action, "Failed to download " + label, current_version, latest_version);

    let is_pkg_asset = str_endswith(release.asset_name, ".apk") || str_endswith(release.asset_name, ".ipk");
    if (is_pkg_asset) {
        stop_tachyon_before_core_change();

        let backup_binary = "";
        if (file_exists(TACHYON_CORE_BIN) && !is_symlink_path(TACHYON_CORE_BIN)) {
            let candidate_backup = cmp.tmp_dir_path() + "/tachyon-core.backup." + owner_pid();
            if (copy_file_stream(TACHYON_CORE_BIN, candidate_backup))
                backup_binary = candidate_backup;
        }

        // Preserve Tachyon's generated /etc/tachyon-core/config.json across package install
        let backup_cfg = cmp.tmp_dir_path() + "/tachyon-core-config.backup." + owner_pid();
        let had_cfg = file_exists("/etc/tachyon-core/config.json") && copy_file_stream("/etc/tachyon-core/config.json", backup_cfg);

        if (pkg_is_installed("tachyon-core"))
            run_logged_pkg_remove_conflict("tachyon-core", "Removing previous " + label + " package before installation");

        prepare_core_package_service_install();
        let pkg_ok = run_logged_pkg_install_files("Installing " + label + " package", [ archive_file ], 180, true);
        if (pkg_ok)
            prepare_core_service_disabled();
        if (pkg_ok && (!file_exists(TACHYON_CORE_BIN) || is_symlink_path(TACHYON_CORE_BIN))) {
            let fallback_bin = cmp.tmp_dir_path() + "/tachyon-core.pkg-fallback." + owner_pid();
            let extracted = false;
            if (str_endswith(release.asset_name, ".apk")) {
                extracted = command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", "usr/bin/tachyon-core" ]) + " >" + shell_quote(fallback_bin) + " 2>/dev/null") ||
                    command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", "./usr/bin/tachyon-core" ]) + " >" + shell_quote(fallback_bin) + " 2>/dev/null");
            } else {
                extracted = command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", "./data.tar.gz" ]) + " 2>/dev/null | " + command_from_args([ "tar", "-xzf", "-", "-O", "./usr/bin/tachyon-core" ]) + " >" + shell_quote(fallback_bin) + " 2>/dev/null") ||
                    command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", "data.tar.gz" ]) + " 2>/dev/null | " + command_from_args([ "tar", "-xzf", "-", "-O", "usr/bin/tachyon-core" ]) + " >" + shell_quote(fallback_bin) + " 2>/dev/null");
            }
            if (extracted && file_nonempty(fallback_bin) && command_success_from_args([ "chmod", "0755", fallback_bin ])) {
                remove_file(TACHYON_CORE_BIN);
                install_staged_file(fallback_bin, TACHYON_CORE_BIN, "0755");
            }
            remove_file(fallback_bin);
        }
        remove_file(archive_file);
        if (had_cfg && file_exists(backup_cfg)) {
            install_staged_file(backup_cfg, "/etc/tachyon-core/config.json", "0644");
            remove_file(backup_cfg);
        }

        if (!pkg_ok) {
            if (backup_binary != "" && file_exists(backup_binary))
                install_staged_file(backup_binary, TACHYON_CORE_BIN, "0755");
            remove_file(backup_binary);
            install_managed_core_service_script();
            action_fail("tachyon-core", action, "Failed to install " + label + " package", current_version, latest_version);
        }

        let new_version = validate_tachyon_core_binary(TACHYON_CORE_BIN, "/usr/lib");
        if (new_version == "") {
            if (backup_binary != "" && file_exists(backup_binary))
                install_staged_file(backup_binary, TACHYON_CORE_BIN, "0755");
            remove_file(backup_binary);
            install_managed_core_service_script();
            action_fail("tachyon-core", action, "Installed " + label + " package failed binary validation", current_version, latest_version);
        }

        let config_check = check_core_config_with_binary(TACHYON_CORE_BIN, "/etc/tachyon-core/config.json", cmp.tmp_dir_path());
        if (!config_check.ok) {
            if (backup_binary != "" && file_exists(backup_binary))
                install_staged_file(backup_binary, TACHYON_CORE_BIN, "0755");
            remove_file(backup_binary);
            install_managed_core_service_script();
            action_fail("tachyon-core", action, "Installed " + label + " is incompatible with current configuration: " + config_check.reason, current_version, latest_version);
        }

        tachyon_core_runtime_success("write-version-state", [ new_version ]);
        if (target_tag != null && target_tag != "" && new_version != "")
            write_file("/etc/tachyon/tachyon-core-version", normalize_core_version(new_version) + "\n");
        install_managed_core_service_script();
        let restart_ok = restart_tachyon_after_successful_change();
        cleanup_core_cache_backup();
        remove_file(backup_binary);
        clear_version_caches();
        updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
        if (!restart_ok && tachyon_was_running) {
            updates_log("Installed " + label + " " + new_version + ", but Tachyon failed to restart", "warn");
            action_fail("tachyon-core", action, label + " installed, but service restart failed", new_version, latest_version);
        } else {
            action_success("tachyon-core", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
        }
    }

    // The member is named after the build, so it is found by prefix. Entries
    // with sidecar suffixes (.sha256, .sig, .txt) are skipped so we never
    // overwrite the binary with a checksum file.
    let binary_path = trim(helper_output_input(
        command_output_from_args([ "tar", "-tzf", archive_file ]),
        "updates-archive-member-prefix",
        [ label ]
    ));
    if (binary_path == "") {
        remove_file(archive_file);
        action_fail("tachyon-core", action, "core binary was not found in the downloaded archive", current_version, latest_version);
    }

    let extract_error = cmp.tmp_dir_path() + "/tachyon-core-extract.err";
    let tmp_binary = cmp.tmp_dir_path() + "/tachyon-core." + owner_pid();
    if (!command_success(command_from_args([ "tar", "-xzf", archive_file, "-O", binary_path ]) + " >" + shell_quote(tmp_binary) + " 2>" + shell_quote(extract_error)) ||
        !file_nonempty(tmp_binary) ||
        !command_success_from_args([ "chmod", "0755", tmp_binary ])) {
        for (let line in split(read_file(extract_error), "\n"))
            if (trim(as_string(line)) != "")
                updates_log(line);
        remove_file(tmp_binary);
        remove_file(archive_file);
        action_fail("tachyon-core", action, "Failed to extract " + label, current_version, latest_version);
    }
    remove_file(archive_file);

    let new_version = validate_tachyon_core_binary(tmp_binary, cmp.tmp_dir_path());
    if (new_version == "") {
        remove_file(tmp_binary);
        action_fail("tachyon-core", action, "Downloaded " + label + " is not a tachyon-core build", current_version, latest_version);
    }

    // Refuse before installing: a core that rejects the current config would
    // leave the router with no working engine at all, which is the failure this
    // check exists to prevent.
    let config_check = check_core_config_with_binary(tmp_binary, "/etc/tachyon-core/config.json", cmp.tmp_dir_path());
    if (!config_check.ok) {
        remove_file(tmp_binary);
        action_fail("tachyon-core", action, "Downloaded " + label + " is incompatible with current configuration: " + config_check.reason, current_version, latest_version);
    }

    stop_tachyon_before_core_change();

    let backup_binary = "";
    if (file_exists(TACHYON_CORE_BIN) && !is_symlink_path(TACHYON_CORE_BIN)) {
        let candidate_backup = cmp.tmp_dir_path() + "/tachyon-core.backup." + owner_pid();
        if (copy_file_stream(TACHYON_CORE_BIN, candidate_backup))
            backup_binary = candidate_backup;
    }

    if (pkg_is_installed("tachyon-core"))
        run_logged_pkg_remove_conflict("tachyon-core", "Removing tachyon-core package before " + label + " installation");

    remove_file(TACHYON_CORE_BIN);
    if (!install_staged_file(tmp_binary, TACHYON_CORE_BIN, "0755")) {
        remove_file(tmp_binary);
        if (backup_binary != "" && file_exists(backup_binary))
            install_staged_file(backup_binary, TACHYON_CORE_BIN, "0755");
        action_fail("tachyon-core", action, "Failed to install " + label, current_version, latest_version);
    }
    remove_file(tmp_binary);

    tachyon_core_runtime_success("write-version-state", [ new_version ]);
    if (target_tag != null && target_tag != "" && new_version != "")
        write_file("/etc/tachyon/tachyon-core-version", normalize_core_version(new_version) + "\n");
    install_managed_core_service_script();
    restart_tachyon_after_successful_change();
    cleanup_core_cache_backup();
    remove_file(backup_binary);
    clear_version_caches();
    updates_log("Installed " + label + " " + (new_version != "" ? new_version : "unknown"));
    action_success("tachyon-core", action, label + " has been installed", new_version, latest_version, 1, "latest", release.release_url);
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
    command_status_from_args([ "touch", "/www/luci-static/resources", "/www/luci-static/resources/view/tachyon" ]);
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    restart_tachyon_after_successful_change(true);
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
    if (!install_result.success) {
        if (!is_apk() || !verify_package_post_install("tachyon", latest_version))
            action_fail("tachyon", "install", "Failed to install Tachyon packages: " + as_string(install_result.message), TACHYON_VERSION, latest_version);
        else
            updates_log("Tachyon packages were installed despite package manager repository warning; continuing", "warn");
    }

    if (!verify_package_post_install("tachyon", latest_version))
        updates_log("Warning: Tachyon package version may not have been updated in package database", "warn");

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    command_status_from_args([ "touch", "/www/luci-static/resources", "/www/luci-static/resources/view/tachyon" ]);
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    restart_tachyon_after_successful_change(true);
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
    if (!install_result.success) {
        if (!is_apk() || !verify_package_post_install("tachyon", target_tag))
            action_fail("tachyon", "install_version", "Failed to install Tachyon packages: " + as_string(install_result.message), TACHYON_VERSION, target_tag);
        else
            updates_log("Tachyon packages were installed despite package manager repository warning; continuing", "warn");
    }

    if (!verify_package_post_install("tachyon", target_tag))
        updates_log("Warning: Tachyon package version may not have been updated in package database", "warn");

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    command_status_from_args([ "touch", "/www/luci-static/resources", "/www/luci-static/resources/view/tachyon" ]);
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    restart_tachyon_after_successful_change(true);
    clear_version_caches();
    let new_version = installed_package_version("tachyon");
    if (new_version == "")
        new_version = target_tag;
    updates_log("Tachyon updated to " + new_version);
    let build_extra = record_tachyon_installed_build(new_version, release);
    action_success("tachyon", "install_version", "Tachyon has been installed", new_version, target_tag, 1, "latest", release.release_url, build_extra);
}

function normalize_component_name(component) {
    component = as_string(component);
    if (component == "tachyon-core" || component == "tachyon_core" || component == "tachyoncore")
        return "tachyon-core";
    if (component == "tachyon")
        return "tachyon";
    if (component == "direct-bypass" || component == "directbypass" || component == "direct_proxy")
        return "direct_bypass";
    if (component == "torrserver_direct" || component == "torrserver-direct" || component == "torrserver")
        return "torrserver_direct";
    return component;
}

function component_backup_dir(component) {
    component = normalize_component_name(component);
    if (component == "tachyon-core")
        component = "tachyon_core";
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

    if (component == "tachyon-core") {
        let source_bin = TACHYON_CORE_BIN;
        if (!file_exists(source_bin))
            return true;
        let st = fs.stat(source_bin);
        let size = (st && st.size) ? st.size : 0;
        if (size <= 0)
            return true;

        if (!check_free_disk_space("/etc", size)) {
            updates_log("Skipping tachyon-core backup before update: insufficient disk space on /etc", "warn");
            return false;
        }

        ensure_dir(bdir);
        let backup_bin = bdir + "/tachyon-core";

        let version = read_core_binary_version(source_bin, "/usr/lib");

        // Protect existing valid backup: do not backup an invalid or broken binary
        if (version == "") {
            if (file_exists(backup_bin) && file_nonempty(backup_bin)) {
                updates_log("Current tachyon-core binary is invalid or broken; preserving existing valid backup", "warn");
                return true;
            }
            updates_log("Current tachyon-core binary is invalid or broken; skipping backup creation", "warn");
            return true;
        }

        let staged_backup = backup_bin + ".tmp." + owner_pid();
        remove_file(staged_backup);
        if (!command_success_from_args([ "cp", "-L", "-p", source_bin, staged_backup ]) ||
            !file_nonempty(staged_backup)) {
            remove_file(staged_backup);
            updates_log("Failed to create tachyon-core backup copy", "warn");
            return false;
        }
        if (!command_success_from_args([ "mv", "-f", staged_backup, backup_bin ])) {
            remove_file(staged_backup);
            updates_log("Failed to finalize tachyon-core backup copy", "warn");
            return false;
        }

        if (file_exists("/etc/init.d/tachyon-core")) {
            command_success_from_args([ "cp", "-p", "/etc/init.d/tachyon-core", bdir + "/tachyon-core.init" ]);
        }

        let meta = {
            component: "tachyon-core",
            version: version,
            size: size,
            timestamp: now_seconds()
        };
        write_file(meta_file, sprintf("%J\n", meta));
        updates_log("Created local backup of tachyon-core v" + version, "info");
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

    if (component == "tachyon-core") {
        let backup_bin = bdir + "/tachyon-core";
        if (!file_exists(backup_bin) || !file_nonempty(backup_bin)) {
            action_fail("tachyon-core", "rollback", "tachyon-core backup binary is missing or empty");
        }

        stop_tachyon_before_core_change();

        remove_file(TACHYON_CORE_BIN);
        if (!command_success_from_args([ "cp", "-p", backup_bin, TACHYON_CORE_BIN ]) ||
            !command_success_from_args([ "chmod", "0755", TACHYON_CORE_BIN ])) {
            action_fail("tachyon-core", "rollback", "Failed to restore tachyon-core binary from backup");
        }

        if (file_exists(bdir + "/tachyon-core.init")) {
            command_success_from_args([ "cp", "-p", bdir + "/tachyon-core.init", "/etc/init.d/tachyon-core" ]);
            command_success_from_args([ "chmod", "0755", "/etc/init.d/tachyon-core" ]);
        } else {
            install_managed_core_service_script();
        }

        if (backup_version != "" && backup_version != "previous")
            tachyon_core_runtime_success("write-version-state", [ backup_version ]);

        clear_version_caches();
        restart_tachyon_after_successful_change();
        action_success("tachyon-core", "rollback", "tachyon-core rolled back to " + backup_version, backup_version, "", 1);
    }
    else {
        action_fail(component, "rollback", "Rollback not supported for component " + component);
    }
}

function list_component_releases(component, count, page) {
    component = normalize_component_name(component);
    count = int(count || 5);
    if (count < 1) count = 1;
    if (count > 30) count = 30;
    page = int(page || 1);
    if (page < 1) page = 1;

    let cache_file = (page == 1)
        ? ("/tmp/tachyon-releases-v3-" + component + ".json")
        : ("/tmp/tachyon-releases-v3-" + component + "-p" + page + ".json");
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
    } else if (component == "tachyon-core") {
        owner = TACHYON_CORE_OWNER; repo = TACHYON_CORE_REPO;
    } else if (component == "torrserver_direct") {
        owner = "YouROK"; repo = "TorrServer";
    } else {
        print("[]\n"); return;
    }

    let releases_json = fetch_github_releases_json(owner, repo, per_page, page);
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
                let body = trim(replace(as_string(r.body || ""), /\r/g, ""));
                if (tag == "") continue;
                let prerelease = !!r.prerelease;
                push(releases, { tag, name, published, prerelease, release_url: html_url, body });
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

const TORRSERVER_DIRECT_INIT = getenv("TACHYON_TORRSERVER_DIRECT_INIT") || "/etc/init.d/tachyon-torrserver-direct";
const TORRSERVER_DIRECT_UC = LIB_DIR + "/torrserver/direct.uc";
const TORRSERVER_BIN_PATH = "/usr/bin/torrserver";
const TORRSERVER_TMP_BIN_PATH = "/tmp/torrserver/torrserver";
const TORRSERVER_OPT_BIN_PATH = "/opt/torrserver/torrserver";
const TORRSERVER_SERVICE_INIT = "/etc/init.d/torrserver";
const TORRSERVER_VERSION_FILE = "/etc/tachyon/torrserver-version";

function path_available_kb(target_path) {
    let out = trim(command_output_from_args([ "df", "-P", "-k", target_path ]));
    if (out == "")
        return 0;
    let lines = split(out, "\n");
    if (length(lines) < 2)
        return 0;
    let last_line = trim(lines[length(lines) - 1]);
    let cols = split(last_line, /[ \t]+/);
    if (length(cols) < 4)
        return 0;
    let avail = cols[3];
    if (!match(avail, /^[0-9]+$/))
        return 0;
    return int(avail, 10);
}

function current_torrserver_version() {
    let ver = trim(read_file(TORRSERVER_VERSION_FILE));
    if (ver != "" && file_exists(TORRSERVER_BIN_PATH))
        return ver;
    let status = null;
    try {
        status = json(command_output_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "status" ]));
    } catch (e) {}
    if (type(status) == "object" && int(status.installed || 0) == 1) {
        let sver = trim(as_string(status.version || ""));
        if (sver != "" && sver != "not installed")
            return sver;
    }
    return "";
}

function write_torrserver_init_script() {
    let script = "#!/bin/sh /etc/rc.common\n\n" +
        "START=95\n" +
        "STOP=10\n" +
        "USE_PROCD=1\n\n" +
        "PROG=\"" + TORRSERVER_BIN_PATH + "\"\n" +
        "DATA_DIR=\"/opt/torrserver\"\n" +
        "PORT=\"8090\"\n\n" +
        "start_service() {\n" +
        "    [ -x \"$PROG\" ] || return 1\n" +
        "    mkdir -p \"$DATA_DIR\"\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" -d \"$DATA_DIR\" -p \"$PORT\"\n" +
        "    procd_set_param respawn\n" +
        "    procd_set_param stdout 1\n" +
        "    procd_set_param stderr 1\n" +
        "    procd_close_instance\n" +
        "}\n";
    write_file(TORRSERVER_SERVICE_INIT, script);
    command_success_from_args([ "chmod", "0755", TORRSERVER_SERVICE_INIT ]);
}

function place_torrserver_binary(tmp_bin) {
    if (!command_success_from_args([ "chmod", "0755", tmp_bin ]))
        return false;
    let st = fs.stat(tmp_bin);
    let bin_kb = st && st.size ? int(st.size / 1024) : 65536;
    let required_flash_kb = bin_kb + 16384;

    if (path_available_kb("/usr/bin") >= required_flash_kb) {
        remove_file(TORRSERVER_BIN_PATH);
        if (move_file_portable(tmp_bin, TORRSERVER_BIN_PATH) &&
            command_success_from_args([ "chmod", "0755", TORRSERVER_BIN_PATH ])) {
            return true;
        }
    }

    ensure_dir("/opt/torrserver");
    if (path_available_kb("/opt/torrserver") >= required_flash_kb &&
        path_available_kb("/opt/torrserver") != path_available_kb("/usr/bin")) {
        remove_file(TORRSERVER_OPT_BIN_PATH);
        if (move_file_portable(tmp_bin, TORRSERVER_OPT_BIN_PATH) &&
            command_success_from_args([ "chmod", "0755", TORRSERVER_OPT_BIN_PATH ])) {
            remove_file(TORRSERVER_BIN_PATH);
            return command_success_from_args([ "ln", "-sf", TORRSERVER_OPT_BIN_PATH, TORRSERVER_BIN_PATH ]);
        }
    }

    // Fallback to RAM tmpfs (/tmp/torrserver/torrserver) when root overlay lacks space for a ~60MB binary
    ensure_dir("/tmp/torrserver");
    remove_file(TORRSERVER_TMP_BIN_PATH);
    if (!command_success_from_args([ "mv", "-f", tmp_bin, TORRSERVER_TMP_BIN_PATH ]) &&
        !move_file_portable(tmp_bin, TORRSERVER_TMP_BIN_PATH)) {
        return false;
    }
    command_success_from_args([ "chmod", "0755", TORRSERVER_TMP_BIN_PATH ]);
    remove_file(TORRSERVER_BIN_PATH);
    return command_success_from_args([ "ln", "-sf", TORRSERVER_TMP_BIN_PATH, TORRSERVER_BIN_PATH ]);
}

function install_torrserver(action, target_tag) {
    init_tmp_dir() || action_fail("torrserver_direct", action, "Failed to create temporary directory");
    let current_version = current_torrserver_version();
    let release = cmp_cat.resolve_torrserver_release(target_tag);
    if (release == null)
        action_fail("torrserver_direct", action, "Failed to resolve TorrServer release from YouROK/TorrServer", current_version);
    let latest_version = as_string(release.version || release.tag || "");

    if (action == "check_update") {
        if (current_version == "")
            action_success("torrserver_direct", action, "TorrServer is not installed", "", latest_version, 0, "", release.release_url);
        else
            check_success("torrserver_direct", current_version, latest_version, release.release_url);
    }

    let tmp_bin = cmp.tmp_dir_path() + "/" + release.package_name;
    if (!download_with_retry(release.package_url, tmp_bin, release.package_name) || !file_nonempty(tmp_bin))
        action_fail("torrserver_direct", action, "Failed to download TorrServer binary (" + release.package_name + ")", current_version, latest_version);

    if (file_exists(TORRSERVER_SERVICE_INIT))
        command_status_from_args([ TORRSERVER_SERVICE_INIT, "stop" ]);

    if (!place_torrserver_binary(tmp_bin)) {
        remove_file(tmp_bin);
        action_fail("torrserver_direct", action, "Failed to install TorrServer binary to " + TORRSERVER_BIN_PATH, current_version, latest_version);
    }

    ensure_dir("/opt/torrserver");
    ensure_dir("/etc/tachyon");
    write_file(TORRSERVER_VERSION_FILE, latest_version + "\n");
    write_torrserver_init_script();

    command_success_from_args([ TORRSERVER_SERVICE_INIT, "enable" ]);
    command_success_from_args([ TORRSERVER_SERVICE_INIT, "restart" ]);
    for (let attempt = 0; attempt < 10; attempt++) {
        sleep(500);
        let st_check = null;
        try {
            st_check = json(command_output_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "status" ]));
        } catch (e) {}
        if (type(st_check) == "object" && int(st_check.running || 0) == 1 && int(st_check.available || 0) == 1)
            break;
    }

    // Automatically enable TorrServer Direct cgroup bypass if kernel supports nft_socket
    if (command_success_from_args([ "modprobe", "nft_socket" ]) ||
        (run_logged("Installing TorrServer Direct kernel support", pkg_install_name_command("kmod-nft-socket")) &&
         command_success_from_args([ "modprobe", "nft_socket" ]))) {
        let cursor = uci_core.cursor();
        cursor.load("tachyon");
        cursor.set("tachyon", "settings", "torrserver_direct_enabled", "1");
        cursor.commit("tachyon");
        if (file_exists(TORRSERVER_DIRECT_INIT)) {
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "enable" ]);
            command_success_from_args([ TORRSERVER_DIRECT_INIT, "restart" ]);
        }
        if (file_exists(TORRSERVER_DIRECT_UC))
            command_status_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "reconcile" ]);
    }

    clear_version_caches();
    remove_file(SYSTEM_INFO_CACHE_FILE);
    updates_log("Installed TorrServer " + latest_version);
    action_success("torrserver_direct", action, "TorrServer has been installed", latest_version, latest_version, 1, "latest", release.release_url);
}

function remove_torrserver() {
    let cursor = uci_core.cursor();
    cursor.load("tachyon");
    cursor.set("tachyon", "settings", "torrserver_direct_enabled", "0");
    cursor.commit("tachyon");

    if (file_exists(TORRSERVER_DIRECT_INIT)) {
        command_status_from_args([ TORRSERVER_DIRECT_INIT, "stop" ]);
        command_status_from_args([ TORRSERVER_DIRECT_INIT, "disable" ]);
    }
    if (file_exists(TORRSERVER_DIRECT_UC))
        command_status_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "remove" ]);
    if (file_exists(TORRSERVER_SERVICE_INIT)) {
        command_status_from_args([ TORRSERVER_SERVICE_INIT, "stop" ]);
        command_status_from_args([ TORRSERVER_SERVICE_INIT, "disable" ]);
        remove_file(TORRSERVER_SERVICE_INIT);
    }
    remove_file(TORRSERVER_BIN_PATH);
    remove_file(TORRSERVER_TMP_BIN_PATH);
    remove_file(TORRSERVER_OPT_BIN_PATH);
    remove_file(TORRSERVER_VERSION_FILE);
    clear_version_caches();
    remove_file(SYSTEM_INFO_CACHE_FILE);
    updates_log("Removed TorrServer");
    action_success("torrserver_direct", "remove", "TorrServer has been removed", "not installed", "", 1);
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
    } else if (component == "tachyon-core") {
        install_tachyon_core("install", tag);
    } else if (component == "torrserver_direct") {
        install_torrserver("install", tag);
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
        if ((type(status) != "object" || int(status.running || 0) != 1) && file_exists(TORRSERVER_SERVICE_INIT)) {
            command_success_from_args([ TORRSERVER_SERVICE_INIT, "enable" ]);
            command_success_from_args([ TORRSERVER_SERVICE_INIT, "restart" ]);
            sleep(1000);
            try {
                status = json(command_output_from_args([ "ucode", "-L", LIB_DIR, TORRSERVER_DIRECT_UC, "status" ]));
            } catch (e) {}
        }
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

function switch_engine_component(target) {
    target = engine.normalize_engine(target);
    updates_log("Switching routing engine to " + target);
    // The library, not the CLI shim: requiring service/engine_runtime.uc would run
    // its main() with this process's arguments and then exit the interpreter.
    let engine_rt = require("service.engine_runtime_lib");
    let result = engine_rt.switch_engine(target, { allow_install: true });
    if (!result.ok)
        action_fail("engine", "switch", "Engine switch failed: " + as_string(result.reason || "unknown"), "", "", as_string(result.reason || ""));
    let final_display = as_string(result.to_engine);
    updates_log("Routing engine is now " + final_display);
    action_success("engine", "switch", "Switched to " + final_display, result.from_engine, result.to_engine, 1, "latest", "");
}

function set_tachyon_language(lang_code) {
    let lang = lc(trim(as_string(lang_code || "")));
    if (lang == "" || match(lang, /^[a-z]{2,3}(_[a-zA-Z]{2})?$/) == null)
        action_fail("tachyon", "set_language", "Invalid language code: " + as_string(lang_code || ""));

    let release_url = "";
    if (lang != "en") {
        let lmo_path = "/usr/lib/lua/luci/i18n/tachyon." + lang + ".lmo";
        if (!file_exists(lmo_path)) {
            init_tmp_dir() || action_fail("tachyon", "set_language", "Failed to create temporary directory");
            let target_ver = helper_success("tachyon-release-version-valid", [ TACHYON_VERSION ])
                ? TACHYON_VERSION
                : latest_tachyon_version();
            updates_log("Resolving language package luci-i18n-tachyon-" + lang + " for version " + (target_ver != "" ? target_ver : "latest"));
            let release = cmp_cat.resolve_tachyon_i18n_release(target_ver, lang);
            if (release == null)
                action_fail("tachyon", "set_language", "Failed to resolve language package for " + lang);
            release_url = release.release_url || "";
            let i18n_file = cmp.tmp_dir_path() + "/" + release.package_name;
            if (!download_with_retry(release.package_url, i18n_file, release.package_name)) {
                let latest_ver = latest_tachyon_version();
                if (latest_ver != "" && latest_ver != target_ver) {
                    release = cmp_cat.resolve_tachyon_i18n_release(latest_ver, lang);
                    if (release != null) {
                        release_url = release.release_url || "";
                        i18n_file = cmp.tmp_dir_path() + "/" + release.package_name;
                    }
                }
                if (release == null || !download_with_retry(release.package_url, i18n_file, release.package_name))
                    action_fail("tachyon", "set_language", "Failed to download language package " + (release ? release.package_name : lang));
            }
            let install_result = pkg_tx_install_files([ i18n_file ], true);
            if (!install_result.success)
                action_fail("tachyon", "set_language", "Failed to install language package: " + as_string(install_result.message));
        }
    }

    if (uci_core.available()) {
        let cursor = uci_core.cursor();
        cursor.load("luci");
        if (cursor.get("luci", "languages") == null)
            cursor.set("luci", "languages", "internal");
        cursor.set("luci", "languages", "en", "English");
        if (lang == "ru" || file_exists("/usr/lib/lua/luci/i18n/tachyon.ru.lmo"))
            cursor.set("luci", "languages", "ru", "Русский (Russian)");
        cursor.set("luci", "main", "lang", lang);
        cursor.commit("luci");
    }

    remove_file("/var/luci-indexcache");
    command_success("rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null");
    command_success("rm -rf /tmp/luci-modulecache/ 2>/dev/null");
    command_status_from_args([ "touch", "/www/luci-static/resources", "/www/luci-static/resources/view/tachyon" ]);
    if (file_exists("/etc/init.d/rpcd"))
        command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);

    remove_file(SYSTEM_INFO_CACHE_FILE);
    updates_log("Tachyon UI language set to " + lang);
    action_success("tachyon", "set_language", "Language set to " + lang, lang, lang, 1, "latest", release_url);
}

function component_action(component, action, extra) {
    component = normalize_component_name(component);
    action = as_string(action);
    if (action == "update")
        action = "install";
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

    if (component == "engine" && action == "switch") {
        switch_engine_component(extra);
        return;
    }

    if (action != "check_update" && action != "remove" &&
        action != "set_language" &&
        component != "direct_bypass" && component != "torrserver_direct" && component != "engine") {
        create_component_backup(component);
    }

    if (component == "tachyon" && action == "check_update")
        check_tachyon();
    else if (component == "tachyon" && action == "install")
        install_tachyon();
    else if (component == "tachyon" && action == "reinstall")
        reinstall_tachyon();
    else if (component == "tachyon" && action == "set_language")
        set_tachyon_language(extra);
    else if (component == "tachyon-core" && (action == "check_update" || action == "install" ||
        action == "reinstall"))
        install_tachyon_core(action, extra);
    else if (component == "direct_bypass" && (action == "enable" || action == "disable"))
        set_direct_bypass(action);
    else if (component == "torrserver_direct" && (action == "check_update" || action == "install"))
        install_torrserver(action, extra);
    else if (component == "torrserver_direct" && action == "remove")
        remove_torrserver();
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
        if (e && e.stacktrace) {
            for (let frame in e.stacktrace)
                updates_log("  at " + frame.filename + ":" + frame.line, "error");
        }
        let err_str = as_string(e);
        updates_log("Unhandled component action error: " + err_str, "error");
        action_fail(ARGV[1] || "unknown", ARGV[2] || "unknown", "Unexpected error: " + err_str);
    }
}
else if (mode == "list-component-releases")
    list_component_releases(ARGV[1], ARGV[2], ARGV[3]);
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
else if (mode == "clear-core-cache")
    exit(clear_core_cache_files(ARGV[1] || "manual") >= 0 ? 0 : 1);
else if (mode == "backup-core-cache")
    exit(backup_core_cache_files() >= 0 ? 0 : 1);
else if (mode == "restore-core-cache-backup")
    exit(restore_core_cache_backup() >= 0 ? 0 : 1);
else if (mode == "cleanup-core-cache-backup")
    exit(cleanup_core_cache_backup() >= 0 ? 0 : 1);
else if (mode == "validate-tachyon-core-binary")
    print(validate_tachyon_core_binary(ARGV[1], ARGV[2] || ""), "\n");
else {
    warn("Usage: components/action.uc <component-action|list-component-releases|install-component-version|latest-tachyon-version|tachyon-release-metadata> ...\n");
    exit(1);
}
