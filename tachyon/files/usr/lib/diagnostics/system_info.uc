#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let common = require("core.common");

let _cmp_cat = null;
let _network_mod = null;
let _status_bridge = null;
function get_cmp_cat() { if (_cmp_cat == null) _cmp_cat = require("components.catalog"); return _cmp_cat; }
function network_mod() { if (_network_mod == null) _network_mod = require("diagnostics.network"); return _network_mod; }
function status_bridge() { if (_status_bridge == null) _status_bridge = require("diagnostics.status_bridge"); return _status_bridge; }

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TACHYON_VERSION = getenv("TACHYON_VERSION") || constants.TACHYON_VERSION || "";
const TACHYON_CONFIG = getenv("TACHYON_CONFIG") || constants.TACHYON_CONFIG || "/etc/config/" + CONFIG_NAME;
const TACHYON_SERVICE_NAME = getenv("TACHYON_SERVICE_NAME") || constants.TACHYON_SERVICE_NAME || "tachyon";
const TACHYON_RELEASE_REPO = getenv("TACHYON_RELEASE_REPO") || constants.TACHYON_RELEASE_REPO || "Dushnilin/tachyon";
const TACHYON_LUCI_VIEW_DIR = getenv("TACHYON_LUCI_VIEW_DIR") || constants.TACHYON_LUCI_VIEW_DIR || "/www/luci-static/resources/view/tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const LOGREAD_LINE_LIMIT = "500";
const SYSTEM_INFO_CACHE_FILE = getenv("TACHYON_SYSTEM_INFO_CACHE_FILE") || RUNTIME_STATE_DIR + "/system-info.json";
const SYSTEM_INFO_CACHE_TTL = int(getenv("TACHYON_SYSTEM_INFO_CACHE_TTL") || "3600");
const TMP_TACHYON_CORE_FOLDER = getenv("TMP_TACHYON_CORE_FOLDER") || constants.TMP_TACHYON_CORE_FOLDER || "/tmp/tachyon-core";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || constants.TMP_SUBSCRIPTION_FOLDER || TMP_TACHYON_CORE_FOLDER + "/subscriptions";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const TACHYON_CORE_VERSION_STATE_FILE = getenv("TACHYON_CORE_VERSION_FILE") || constants.TACHYON_CORE_VERSION_FILE || constants.CORE_VERSION_STATE_FILE || "/etc/tachyon/tachyon-core-version";
const TACHYON_CORE_BIN_PATH = getenv("TACHYON_DIAGNOSTICS_CORE_BIN_PATH") || getenv("TACHYON_CORE_BIN") || "/usr/bin/tachyon-core";
const CLOUDFLARE_OCTETS = getenv("CLOUDFLARE_OCTETS") || constants.CLOUDFLARE_OCTETS || "8.47 162.159 188.114";
const RUNTIME_STABLE_MIN_AGE = getenv("TACHYON_RUNTIME_STABLE_MIN_AGE") || "2";

const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const PACKAGES_UC = LIB_DIR + "/core/packages.uc";
const SERVICE_STATE_UC = LIB_DIR + "/service/state.uc";
const SERVICE_UI_UC = LIB_DIR + "/service/ui.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const PROVIDERS_STATUS_UC = LIB_DIR + "/providers/status.uc";
const TACHYON_CORE_RUNTIME_UC = LIB_DIR + "/tachyon_core/runtime.uc";
const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_output = common.command_output;
let command_success = common.command_success;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let command_capture = common.command_capture;
let object_or_empty = common.object_or_empty;
let read_stdin = common.read_stdin;
let read_json_file = common.read_json_file;
let write_json = common.write_json;

function arg_number(value) { return int(value); }
function words(value) {
    let out = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "") push(out, item);
    return out;
}
function parse_json_or_null(text) {
    text = trim(as_string(text));
    if (text == "") return null;
    try { return json(text); } catch (e) { return null; }
}
function get_wan_ip_addresses() { return network_mod().get_wan_ip_addresses(); }
function tachyon_core_missing_standard_ports(netstat) { return network_mod().tachyon_core_missing_standard_ports(netstat); }
function tachyon_core_standard_ports_listening(netstat) { return network_mod().tachyon_core_standard_ports_listening(netstat); }

function option(cfg, key, fallback) {
    if (type(cfg) != "object") return fallback;
    let value = cfg[key];
    return value != null && value != "" ? value : fallback;
}

function bool_option(cfg, key, fallback) {
    if (type(cfg) != "object") return fallback ? true : false;
    let value = cfg[key];
    if (value == null || value == "") return fallback ? true : false;
    return value == "1" || value == "true" || value == true;
}

function settings() {
    return uci_core.get_all(CONFIG_NAME, "settings") || {};
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function active_engine_name() {
    let engine = uci_core.get(CONFIG_NAME, "settings", "engine");
    return (engine != null && engine != "") ? as_string(engine) : "tachyon-core";
}

function status_capture(args, input) { return status_bridge().status_capture(args, input); }
function status_output(args, input) { return status_bridge().status_output(args, input); }
function status_success(args, input) { return status_bridge().status_success(args, input); }

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, "--", module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_capture(module_path, args) {
    return command_capture(command_from_args(module_args(module_path, args)));
}

function module_capture_stdin(module_path, args, input) {
    let tmp = trim(command_output_from_args([ "mktemp" ]));
    if (tmp == "")
        return { status: 1, output: "" };

    if (!fs.writefile(tmp, as_string(input))) {
        fs.unlink(tmp);
        return { status: 1, output: "" };
    }

    let result = command_capture(command_from_args(module_args(module_path, args)) + " < " + shell_quote(tmp));
    fs.unlink(tmp);
    return result;
}

function module_output(module_path, args) {
    let result = module_capture(module_path, args);
    return result.status == 0 ? result.output : "";
}

function module_output_stdin(module_path, args, input) {
    let result = module_capture_stdin(module_path, args, input);
    return result.status == 0 ? result.output : "";
}

function module_success(module_path, args) {
    return command_success(command_from_args(module_args(module_path, args)));
}

function helper_output(mode, args) {
    let full = [ mode ];
    for (let arg in args) push(full, as_string(arg));
    return replace(module_output(HELPERS_UC, full), /[\r\n]+$/g, "");
}

function file_exists(path) { return fs.stat(as_string(path)) != null; }
function file_executable(path) {
    let st = fs.stat(as_string(path));
    return st != null && st.mode != null && (int(st.mode) & 73) != 0;
}
function command_exists(name) { return command_success_from_args([ "command", "-v", as_string(name) ]); }
function stdout_is_tty() { return command_status("test -t 1") == 0; }
function nolog(message) { if (stdout_is_tty()) print(as_string(message), "
"); }

function remove_file(path) {
    path = as_string(path);
    if (path != "" && fs.stat(path) != null) fs.unlink(path);
}

function first_line_value(path, fallback) {
    let fb = fallback != null ? as_string(fallback) : "";
    path = as_string(path);
    if (path == "" || fs.stat(path) == null) return fb;
    let data = fs.readfile(path);
    if (!data) return fb;
    let lines = split(as_string(data), "\n");
    let val = length(lines) > 0 ? trim(lines[0]) : "";
    return val != "" ? val : fb;
}

function check_logs() {
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    // Use bounded_command to prevent logread from hanging and leaking a zombie process.
    let cmd = common.bounded_command("logread -l " + LOGREAD_LINE_LIMIT + " 2>/dev/null", "5");
    let rendered = status_capture([ "tachyon-logs" ], command_output(cmd));
    if (rendered.output != "")
        print(rendered.output);
    else
        print("No Tachyon entries found in recent system logs\n");
    return 0;
}

function check_tachyon_core_logs() {
    let log_path = TMP_TACHYON_CORE_FOLDER + "/tachyon-core.log";
    let st = fs.stat(log_path);
    if (st != null && int(st.size || 0) > 0) {
        let tail_out = command_output_from_args([ "tail", "-n", "500", log_path ]);
        if (tail_out != "") {
            let filtered = status_capture([ "matching-log-tail", "*", "100" ], tail_out);
            let out_text = filtered.output != "" ? filtered.output : tail_out;
            print(out_text);
            if (substr(out_text, length(out_text) - 1, 1) != "\n")
                print("\n");
            return 0;
        }
    }
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    let needle = "tachyon-core";
    // Use bounded_command to prevent logread from hanging and leaking a zombie process.
    let cmd = common.bounded_command("logread -l " + LOGREAD_LINE_LIMIT + " 2>/dev/null", "5");
    let raw_logs = command_output(cmd);
    let rendered = status_capture([ "matching-log-tail", needle, "100" ], raw_logs);
    if (rendered.output != "")
        print(rendered.output);
    else
        print("No matching logs found in system journal (needle: " + needle + ")\n");
    return 0;
}

function tachyon_logs_fixture() {
    let rendered = status_capture([ "tachyon-logs" ], read_stdin());
    if (rendered.output != "")
        print(rendered.output);
    return rendered.status;
}

function show_tachyon_core_config(visibility) {
    visibility = as_string(visibility || "masked");
    let core_config_path = option(settings(), "config_path", "");
    nolog("Current tachyon-core configuration:");
    if (!file_exists(core_config_path)) {
        nolog("Configuration file not found");
        return 1;
    }
    if (visibility == "raw")
        print(as_string(fs.readfile(core_config_path)));
    else
        print(status_output([ "mask-core-config", core_config_path ], null));
    return 0;
}

function show_config(visibility) {
    visibility = as_string(visibility || "masked");
    if (!file_exists(TACHYON_CONFIG)) {
        nolog("Configuration file not found");
        return 1;
    }
    if (visibility == "raw")
        print(as_string(fs.readfile(TACHYON_CONFIG)));
    else
        print(status_output([ "tachyon-config-masked", TACHYON_CONFIG ], null));
    return 0;
}

function show_version() {
    print(TACHYON_VERSION, "\n");
    return 0;
}

function show_tachyon_core_version() {
    print(replace(module_output(TACHYON_CORE_RUNTIME_UC, [ "version" ]), /[\r\n]+$/g, ""), "\n");
    return 0;
}

function get_luci_app_version() {
    let path = TACHYON_LUCI_VIEW_DIR + "/main.js";
    let data = fs.readfile(path, 131072);
    if (data == null)
        return "not installed";

    let matched = match(data, /var[ \t]+TACHYON_LUCI_APP_VERSION[ \t]*=[ \t]*"([^"]*)"/);
    if (matched != null)
        return as_string(matched[1]);

    let full = fs.readfile(path);
    if (full == null)
        return "";
    matched = match(full, /var[ \t]+TACHYON_LUCI_APP_VERSION[ \t]*=[ \t]*"([^"]*)"/);
    if (matched != null)
        return as_string(matched[1]);

    return "";
}

function system_info_cache_is_valid() {
    let cache = read_json_file(SYSTEM_INFO_CACHE_FILE);
    if (type(cache) != "object")
        return false;
    let now = int(clock()[0]);
    let generated_at = arg_number(cache.generated_at || 0);
    if (now > 0 && generated_at > 0 && SYSTEM_INFO_CACHE_TTL > 0 && now - generated_at >= SYSTEM_INFO_CACHE_TTL)
        return false;
    for (let watched_path in [ TACHYON_CONFIG, TACHYON_CORE_BIN_PATH, TACHYON_CORE_VERSION_STATE_FILE ]) {
        let st = fs.stat(watched_path);
        if (st && st.mtime > generated_at)
            return false;
    }
    return cache.tachyon_version == TACHYON_VERSION && cache.luci_app_version == get_luci_app_version();
}

function ensure_subscription_runtime_dirs() {
    module_success(SUBSCRIPTION_CACHE_UC, [
        "ensure-runtime-dirs"
    ]);
    common.ensure_dir(RUNTIME_STATE_DIR);
}

function write_system_info_cache(value) {
    ensure_subscription_runtime_dirs();
    let tmpfile = SYSTEM_INFO_CACHE_FILE + "." + clock()[0] + "." + clock()[1] + ".tmp";
    if (fs.writefile(tmpfile, as_string(value) + "\n") == null)
        return false;
    remove_file(SYSTEM_INFO_CACHE_FILE);
    if (!fs.rename(tmpfile, SYSTEM_INFO_CACHE_FILE)) {
        remove_file(tmpfile);
        return false;
    }
    return true;
}

function tachyon_core_component_action_running() {
    return module_success(SERVICE_UI_UC, [ "component-action-running-for", "tachyon-core" ]);
}

function tachyon_core_resolved_version() {
    if (tachyon_core_component_action_running()) {
        let state = replace(module_output(TACHYON_CORE_RUNTIME_UC, [ "read-version-state" ]), /[\r\n]+$/g, "");
        if (state != "")
            return { version: state, output: "" };
    }

    let output = module_output(TACHYON_CORE_RUNTIME_UC, [ "version-output" ]);
    return {
        version: replace(module_output_stdin(TACHYON_CORE_RUNTIME_UC, [ "version-from-output" ], output), /[\r\n]+$/g, ""),
        output: output
    };
}

function tachyon_core_capability_flags(core_version, core_version_output) {
    let caps = parse_json_or_null(module_output(TACHYON_CORE_RUNTIME_UC,
        [ "core-capabilities", as_string(core_version), "", as_string(core_version_output) ]));
    if (type(caps) != "object")
        caps = {};

    let tailscale = caps.tailscale ? 1 : 0;
    if (tailscale == 0 && as_string(core_version_output) == "" &&
        tachyon_core_component_action_running())
        tailscale = 1;

    let cert_pin = caps.cert_pin ? 1 : 0;
    let fptn = 0;
    for (let item in (type(caps.protocols) == "array" ? caps.protocols : []))
        if (item == "fptn")
            fptn = 1;

    return { tailscale, cert_pin, fptn };
}

function provider_installed(runtime_uc) {
    return module_success(runtime_uc, [ "installed" ]);
}

function provider_version(runtime_uc) {
    let value = replace(module_output(runtime_uc, [ "package-version" ]), /[\r\n]+$/g, "");
    return value != "" ? value : "unknown";
}

function unquote_release_value(value) {
    let v = trim(as_string(value));
    if (length(v) >= 2) {
        let quote = substr(v, 0, 1);
        if ((quote == "\"" || quote == "'") && substr(v, length(v) - 1) == quote)
            v = substr(v, 1, length(v) - 2);
    }
    return v;
}

function openwrt_release() {
    let data = fs.readfile("/etc/os-release");
    if (data != null) {
        let pretty_name = "";
        for (let line in split(as_string(data), "\n")) {
            if (substr(line, 0, length("OPENWRT_RELEASE=")) == "OPENWRT_RELEASE=") {
                let value = unquote_release_value(substr(line, length("OPENWRT_RELEASE=")));
                if (value != "")
                    return value;
            }
            if (pretty_name == "" && substr(line, 0, length("PRETTY_NAME=")) == "PRETTY_NAME=")
                pretty_name = unquote_release_value(substr(line, length("PRETTY_NAME=")));
        }
        if (pretty_name != "")
            return pretty_name;
    }
    let owrt = fs.readfile("/etc/openwrt_release");
    if (owrt != null) {
        for (let line in split(as_string(owrt), "\n")) {
            if (substr(line, 0, length("DISTRIB_DESCRIPTION=")) == "DISTRIB_DESCRIPTION=") {
                let value = unquote_release_value(substr(line, length("DISTRIB_DESCRIPTION=")));
                if (value != "")
                    return value;
            }
        }
    }
    let entware = fs.readfile("/opt/etc/entware_release");
    if (entware != null) {
        for (let line in split(as_string(entware), "\n")) {
            if (substr(line, 0, length("release=")) == "release=") {
                let value = unquote_release_value(substr(line, length("release=")));
                if (value != "")
                    return "Entware " + value;
            }
        }
    }
    return "unknown";
}

function detect_device_model() {
    let model = first_line_value("/tmp/sysinfo/model", "");
    if (model != "")
        return model;
    let dt_raw = fs.readfile("/proc/device-tree/model");
    if (dt_raw != null) {
        let dt_parts = split(as_string(dt_raw), "\x00");
        let dt_model = length(dt_parts) > 0 ? trim(dt_parts[0]) : "";
        if (dt_model != "")
            return dt_model;
    }
    let board = read_json_file("/etc/board.json");
    if (type(board) == "object" && type(board.model) == "object") {
        let bname = trim(as_string(board.model.name));
        if (bname != "")
            return bname;
    }
    if (command_exists("ndmc")) {
        let ndm_out = command_output_from_args([ "ndmc", "-c", "show version" ]);
        for (let line in split(as_string(ndm_out), "\n")) {
            let trimmed = trim(line);
            if (substr(trimmed, 0, length("model:")) == "model:") {
                let m = trim(substr(trimmed, length("model:")));
                if (m != "")
                    return m;
            }
            if (substr(trimmed, 0, length("device:")) == "device:") {
                let d = trim(substr(trimmed, length("device:")));
                if (d != "")
                    return d;
            }
        }
    }
    return "unknown";
}

function get_system_arch_candidates() {
    let arch_list = "";
    if (fs.stat("/etc/apk/arch") != null) {
        arch_list += " " + trim(as_string(fs.readfile("/etc/apk/arch")));
    }
    if (fs.stat("/etc/openwrt_release") != null) {
        let content = as_string(fs.readfile("/etc/openwrt_release"));
        for (let line in split(content, "\n")) {
            if (substr(line, 0, length("DISTRIB_ARCH=")) == "DISTRIB_ARCH=") {
                let v = substr(line, length("DISTRIB_ARCH="));
                if (length(v) >= 2) {
                    let q = substr(v, 0, 1);
                    if ((q == "\"" || q == "'") && substr(v, length(v) - 1) == q)
                        v = substr(v, 1, length(v) - 2);
                }
                arch_list += " " + v;
                break;
            }
        }
    }
    if (command_exists("uname")) {
        arch_list += " " + trim(command_output_from_args([ "uname", "-m" ]));
    }
    return arch_list;
}

function detect_primary_arch() {
    let candidates = words(get_system_arch_candidates());
    return length(candidates) > 0 ? as_string(candidates[0]) : "unknown";
}

function collect_system_telemetry() {
    let kernel_version = first_line_value("/proc/sys/kernel/osrelease", "unknown");
    let uptime_raw = first_line_value("/proc/uptime", "");
    let uptime_parts = words(uptime_raw);
    let uptime_seconds = length(uptime_parts) > 0 ? int(split(as_string(uptime_parts[0]), ".")[0] || 0) : 0;

    let load_raw = first_line_value("/proc/loadavg", "");
    let load_parts = words(load_raw);
    let load_avg = length(load_parts) >= 3
        ? (as_string(load_parts[0]) + " / " + as_string(load_parts[1]) + " / " + as_string(load_parts[2]))
        : "";

    let mem_total_kb = 0;
    let mem_avail_kb = 0;
    let mem_free_kb = 0;
    let mem_buffers_kb = 0;
    let mem_cached_kb = 0;
    let meminfo = fs.readfile("/proc/meminfo");
    if (meminfo != null) {
        for (let line in split(as_string(meminfo), "\n")) {
            let parts = words(line);
            if (length(parts) < 2)
                continue;
            let k = as_string(parts[0]);
            let v = int(parts[1] || 0);
            if (k == "MemTotal:")
                mem_total_kb = v;
            else if (k == "MemAvailable:")
                mem_avail_kb = v;
            else if (k == "MemFree:")
                mem_free_kb = v;
            else if (k == "Buffers:")
                mem_buffers_kb = v;
            else if (k == "Cached:")
                mem_cached_kb = v;
        }
    }
    if (mem_avail_kb <= 0 && mem_total_kb > 0)
        mem_avail_kb = mem_free_kb + mem_buffers_kb + mem_cached_kb;
    let mem_used_kb = mem_total_kb > mem_avail_kb ? (mem_total_kb - mem_avail_kb) : 0;
    let mem_used_pct = mem_total_kb > 0 ? int((mem_used_kb * 100) / mem_total_kb) : 0;

    let conntrack_count = int(first_line_value("/proc/sys/net/netfilter/nf_conntrack_count", "0") || 0);
    let conntrack_max = int(first_line_value("/proc/sys/net/netfilter/nf_conntrack_max", "0") || 0);

    let cfg = settings();
    let dns_type = option(cfg, "dns_type", "doh");
    let v6_info = network_mod().get_ipv6_runtime_telemetry(cfg);
    let fakeip_enabled = v6_info.fakeip_enabled;
    let inbound_mode = option(cfg, "inbound_mode", "tproxy");

    let sections_total_count = 0;
    let sections_enabled_count = 0;
    let sec_objs = uci_core.section_objects(CONFIG_NAME, "section");
    for (let s in sec_objs) {
        sections_total_count++;
        if (as_string(s.enabled) != "0" && as_string(s.enabled) != "false")
            sections_enabled_count++;
    }

    let q_path = getenv("TACHYON_QUARANTINED_SECTIONS_FILE") || "/var/run/tachyon/quarantined-sections.state";
    let d_path = getenv("TACHYON_SUBSCRIPTION_DEFERRED_SECTIONS_FILE") || "/var/run/tachyon/subscription-deferred-sections.state";
    let quarantined_sections_count = length(words(as_string(fs.readfile(q_path) || "")));
    let deferred_sections_count = length(words(as_string(fs.readfile(d_path) || "")));

    return {
        kernel_version,
        uptime_seconds,
        load_avg,
        mem_total_kb,
        mem_available_kb: mem_avail_kb,
        mem_total_mb: int((mem_total_kb + 512) / 1024),
        mem_used_mb: int((mem_used_kb + 512) / 1024),
        mem_free_mb: int((mem_avail_kb + 512) / 1024),
        mem_used_pct,
        conntrack_count,
        conntrack_max,
        dns_type,
        fakeip_enabled,
        inbound_mode,
        router_hostname: v6_info.router_hostname,
        wan_ipv6: v6_info.wan_ipv6,
        lan_ipv6: v6_info.lan_ipv6,
        wan6_available: v6_info.wan6_available,
        wan6_iface: v6_info.wan6_iface,
        wan6_prefix: v6_info.wan6_prefix,
        wan6_pd: v6_info.wan6_pd,
        ipv6_effective_state: v6_info.ipv6_effective_state,
        ipv6_mode: v6_info.ipv6_mode,
        ipv6_leak_guard: v6_info.ipv6_leak_guard,
        dns_strategy: v6_info.dns_strategy,
        runtime_dns_strategy: v6_info.runtime_dns_strategy,
        sections_total_count,
        sections_enabled_count,
        total_sections_count: sections_total_count,
        active_sections_count: sections_enabled_count,
        quarantined_sections_count,
        deferred_sections_count
    };
}

function build_system_info() {
    let tachyon_latest_version = first_line_value("/tmp/tachyon.latest-version.cache", "unknown");
    let luci_app_version = get_luci_app_version();
    let tachyon_core_version = "";
    let tachyon_core_version_output = "";

    if (command_exists("tachyon-core")) {
        let resolved = tachyon_core_resolved_version();
        tachyon_core_version = resolved.version;
        tachyon_core_version_output = resolved.output;
        if (tachyon_core_version == "")
            tachyon_core_version = "unknown";
    }
    else {
        tachyon_core_version = "not installed";
        tachyon_core_version_output = "";
    }

    let flags = tachyon_core_capability_flags(tachyon_core_version, tachyon_core_version_output);
    let tachyon_core_fptn = flags.fptn == 1 ? 1 : 0;
    let tachyon_core_repo_url = "https://github.com/Dushnilin/tachyon-core";

    let device_model = detect_device_model();

    let direct_bypass_enabled = bool_option(settings(), "direct_bypass_enabled", false) ? 1 : 0;
    let direct_bypass_port = option(settings(), "direct_bypass_port", "2080");
    let direct_bypass_address = direct_bypass_enabled
        ? trim(command_output_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/tachyon_core/runtime.uc", "service-listen-address" ]))
        : "";
    let torrserver_direct_status = parse_json_or_null(command_output_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/torrserver/direct.uc", "status" ]));
    if (type(torrserver_direct_status) != "object")
        torrserver_direct_status = {};

    let show_component_direct_bypass = bool_option(settings(), "show_component_direct_bypass", true) ? 1 : 0;
    let show_component_torrserver_direct = bool_option(settings(), "show_component_torrserver_direct", true) ? 1 : 0;

    let base_bdir = getenv("TACHYON_COMPONENT_BACKUPS_DIR") || "/etc/tachyon/component-backups";
    let read_backup_meta = function(comp) {
        let path = base_bdir + "/" + comp + "/metadata.json";
        let st = fs.stat(path);
        if (!st) return null;
        let data = as_string(fs.readfile(path));
        if (data == "") return null;
        try {
            let p = json(data);
            if (type(p) == "object" && p.version) return p;
        } catch (e) {}
        return null;
    };
    let tcore_meta = read_backup_meta("tachyon_core");
    let cmp_cat = get_cmp_cat();

    return {
        tachyon_version: TACHYON_VERSION,
        tachyon_commit_sha: constants.TACHYON_COMMIT_SHA && !match(constants.TACHYON_COMMIT_SHA, /COMPILED/) ? constants.TACHYON_COMMIT_SHA : "",
        tachyon_latest_version: tachyon_latest_version || "unknown",
        luci_app_version,
        active_engine: "tachyon-core",
        tachyon_core_version,
        tachyon_core_fptn,
        tachyon_core_tailscale: flags.tailscale,
        tachyon_core_cert_pin: flags.cert_pin,
        tachyon_core_repo_url,
        tachyon_core_backup_version: tcore_meta ? as_string(tcore_meta.version) : "",
        tachyon_core_backup_time: tcore_meta ? int(tcore_meta.timestamp || 0) : 0,
        direct_bypass_enabled,
        direct_bypass_address,
        direct_bypass_port,
        torrserver_installed: int(torrserver_direct_status.installed || 0),
        torrserver_version: as_string(torrserver_direct_status.version || "not installed"),
        torrserver_running: int(torrserver_direct_status.running || 0),
        torrserver_direct_available: int(torrserver_direct_status.available || 0),
        torrserver_direct_enabled: int(torrserver_direct_status.enabled || 0),
        torrserver_direct_active: int(torrserver_direct_status.active || 0),
        show_component_direct_bypass,
        show_component_torrserver_direct,
        dashboard_hide_na_servers: (() => {
            let sections = uci_core.section_objects(CONFIG_NAME, "section");
            for (let s in sections)
                if (uci_core.get(CONFIG_NAME, s, "enabled") != "0" &&
                    uci_core.get(CONFIG_NAME, s, "dashboard_hide_na_servers") == "1")
                    return 1;
            return 0;
        })(),
        openwrt_version: openwrt_release(),
        device_model,
        cpu_arch: detect_primary_arch(),
        ...collect_system_telemetry(),
        generated_at: int(clock()[0])
    };
}

function get_system_info() {
    if (system_info_cache_is_valid()) {
        let cached = read_json_file(SYSTEM_INFO_CACHE_FILE);
        if (type(cached) == "object") {
            let live = collect_system_telemetry();
            for (let k in live)
                cached[k] = live[k];
            print(sprintf("%J\n", cached));
            return 0;
        }
        print(as_string(fs.readfile(SYSTEM_INFO_CACHE_FILE)));
        return 0;
    }

    let system_info = sprintf("%J", build_system_info());
    write_system_info_cache(system_info);
    print(system_info, "\n");
    return 0;
}

function get_server_capabilities() {
    let bin_ok = file_executable(TACHYON_CORE_BIN_PATH);
    if (!bin_ok) {
        write_json({
            tachyon_core_tailscale: 0,
            tachyon_core_cert_pin: 0
        });
        return 0;
    }

    let resolved = tachyon_core_resolved_version();
    let flags = tachyon_core_capability_flags(resolved.version, resolved.output);
    write_json({
        tachyon_core_tailscale: flags.tailscale,
        tachyon_core_cert_pin: flags.cert_pin
    });
    return 0;
}


function tachyon_core_process_is_running() {
    return command_success_from_args([ "pgrep", "-x", "tachyon-core" ]) ||
        command_success_from_args([ "pgrep", "-f", "^/usr/bin/tachyon-core[[:space:]]" ]);
}

function service_status_label(running, enabled) {
    if (arg_number(running) == 1)
        return arg_number(enabled) == 1 ? "running & enabled" : "running but disabled";
    return arg_number(enabled) == 1 ? "stopped but enabled" : "stopped & disabled";
}

function write_service_status(running, enabled, dns_configured) {
    write_json({
        running,
        enabled,
        status: service_status_label(running, enabled),
        dns_configured
    });
}

function dnsmasq_has_tachyon_dns() {
    let addr = getenv("TACHYON_CORE_DNS_INBOUND_ADDRESS") || getenv("CORE_DNS_INBOUND_ADDRESS") || "127.0.0.42";
    let servers = uci_core.get("dhcp.@dnsmasq[0].server");
    let raw = type(servers) == "array" ? join(" ", servers) : as_string(servers);
    for (let item in words(raw))
        if (item == addr)
            return true;
    return uci_core.exists("dhcp.tachyon");
}

function get_tachyon_core_status() {
    let running = module_success(SERVICE_STATE_UC, [
        "tachyon-core-service-stable",
        RUNTIME_STABLE_MIN_AGE
    ]) ? 1 : 0;
    let enabled = file_executable("/etc/rc.d/S99" + TACHYON_SERVICE_NAME) ? 1 : 0;
    let dns_configured = dnsmasq_has_tachyon_dns() ? 1 : 0;
    write_service_status(running, enabled, dns_configured);
    return 0;
}

function get_engine_status() {
    let running = module_success(SERVICE_STATE_UC, [
        "tachyon-core-service-stable",
        RUNTIME_STABLE_MIN_AGE
    ]) ? 1 : 0;
    let enabled = file_executable("/etc/rc.d/S99" + TACHYON_SERVICE_NAME) ? 1 : 0;
    let dns_configured = dnsmasq_has_tachyon_dns() ? 1 : 0;
    write_json({
        running,
        enabled,
        engine: "tachyon-core",
        managed_by: TACHYON_SERVICE_NAME,
        status: service_status_label(running, enabled),
        dns_configured
    });
    return 0;
}

function get_status() {
    let running = module_success(SERVICE_STATE_UC, [
        "tachyon-stably-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK, RUNTIME_STABLE_MIN_AGE
    ]) ? 1 : 0;
    let enabled = file_executable("/etc/rc.d/S99" + TACHYON_SERVICE_NAME) ? 1 : 0;
    let dns_configured = dnsmasq_has_tachyon_dns() ? 1 : 0;
    write_service_status(running, enabled, dns_configured);
    return 0;
}

function subscription_cache(args) {
    return module_capture(SUBSCRIPTION_CACHE_UC, args);
}

function print_subscription_result(result, fallback) {
    if (result.status == 0 && result.output != "") {
        print(result.output);
        return 0;
    }
    print(as_string(fallback));
    return 0;
}

function section_safe(section) {
    section = as_string(section);
    return section != "" && index(section, "/") < 0 && index(section, "..") < 0;
}

function get_outbound_metadata(section) {
    subscription_cache([ "ensure-runtime-dirs" ]);
    let sec_str = trim(as_string(section));
    if (sec_str == "" || sec_str == "all") {
        let result = subscription_cache([ "get-outbound-metadata", SECTION_CACHE_DIR, "all", "" ]);
        if (result.status != 0)
            result = subscription_cache([ "empty-outbound-metadata" ]);
        return print_subscription_result(result, "");
    }
    if (!section_safe(sec_str))
        return print_subscription_result(subscription_cache([ "empty-outbound-metadata" ]), "");
    let metadata_path = replace(module_output(SUBSCRIPTION_CACHE_UC, [ "outbound-metadata-path", sec_str ]), /[\r\n]+$/g, "");
    if (metadata_path == "")
        return print_subscription_result(subscription_cache([ "empty-outbound-metadata" ]), "");
    let result = subscription_cache([ "get-outbound-metadata", SECTION_CACHE_DIR, sec_str, metadata_path ]);
    if (result.status != 0)
        result = subscription_cache([ "empty-outbound-metadata" ]);
    return print_subscription_result(result, "");
}

function get_subscription_metadata(section) {
    subscription_cache([ "ensure-runtime-dirs" ]);
    if (!section_safe(section)) {
        print("{}\n");
        return 0;
    }
    let metadata_path = replace(module_output(SUBSCRIPTION_CACHE_UC, [ "subscription-metadata-path", section ]), /[\r\n]+$/g, "");
    if (metadata_path == "") {
        print("{}\n");
        return 0;
    }
    let result = subscription_cache([ "get-subscription-metadata", SECTION_CACHE_DIR, section, metadata_path ]);
    return print_subscription_result(result, "{}\n");
}

function strip_leading_v(value) {
    value = as_string(value);
    return substr(value, 0, 1) == "v" ? substr(value, 1) : value;
}


function resolve_tachyon_core_listen_ports(netstat_out) {
    let settings = uci_core.get_all(CONFIG_NAME, "settings") || {};
    let cfg_path = trim(as_string(settings.config_path || "")) || "/etc/tachyon-core/config.json";
    let cfg = read_json_file(cfg_path);
    let ports = [];
    let seen = {};
    let add_port = function(val) {
        val = trim(as_string(val || ""));
        if (val == "" || seen[val])
            return;
        seen[val] = true;
        push(ports, val);
    };

    if (type(cfg) == "object" && type(cfg.inbounds) == "array") {
        let mode_items = [];
        let extra_items = [];
        for (let inb in cfg.inbounds) {
            if (type(inb) != "object")
                continue;
            if (inb.listen_port != null) {
                let p = as_string(inb.listen_port);
                if (p == "53")
                    add_port("53");
                else if (inb.tag == "tproxy-in" || inb.tag == "tproxy6-in" || inb.tag == "client-mixed-in")
                    push(mode_items, p);
                else
                    push(extra_items, p);
            } else if (inb.type == "tun") {
                push(mode_items, as_string(inb.interface_name || "tun0"));
            }
        }
        add_port("53");
        for (let p in mode_items)
            add_port(p);
        for (let p in extra_items)
            add_port(p);
        let ext_ctrl = trim(as_string(cfg.experimental?.clash_api?.external_controller || ""));
        let m_ctrl = match(ext_ctrl, /:([0-9]+)$/);
        if (m_ctrl != null)
            add_port(m_ctrl[1]);
    } else {
        add_port("53");
        let pmode = lc(trim(as_string(settings.proxy_mode || "tproxy")));
        if (pmode == "tun")
            add_port("tun0");
        else if (pmode == "socks")
            add_port(trim(as_string(settings.socks_port || "1080")) || "1080");
        else
            add_port("1602");
        if (index(as_string(netstat_out), ":1603") >= 0)
            add_port("1603");
        if (index(as_string(netstat_out), ":9090") >= 0)
            add_port("9090");
    }

    return join(", ", ports);
}

function check_tachyon_core() {
    let tachyon_core_installed = 0;
    let tachyon_core_version_ok = 0;
    let tachyon_core_cert_pin = 0;
    let tachyon_core_service_exist = 0;
    let tachyon_core_autostart_disabled = 0;
    let tachyon_core_process_running = 0;
    let tachyon_core_ports_listening = 0;
    let tachyon_core_version = "";

    if (command_exists("tachyon-core")) {
        tachyon_core_installed = 1;
        let version = "";
        if (system_info_cache_is_valid()) {
            let cache = read_json_file(SYSTEM_INFO_CACHE_FILE);
            version = strip_leading_v(as_string(cache.tachyon_core_version));
            tachyon_core_cert_pin = int(cache.tachyon_core_cert_pin) ? 1 : 0;
        }

        if (version == "" || version == "unknown" || version == "not installed") {
            let resolved = tachyon_core_resolved_version();
            version = strip_leading_v(as_string(resolved.version));
            let flags = tachyon_core_capability_flags(version, resolved.output);
            tachyon_core_cert_pin = flags.cert_pin;
        }
        tachyon_core_version = version;

        if (version != "" && version != "unknown" && version != "not installed") {
            tachyon_core_version_ok = 1;
        }
    }

    if (file_exists("/etc/init.d/tachyon-core")) {
        tachyon_core_service_exist = 1;
        if (!command_success_from_args([ "/etc/init.d/tachyon-core", "enabled" ]))
            tachyon_core_autostart_disabled = 1;
    }

    if (tachyon_core_process_is_running())
        tachyon_core_process_running = 1;

    let netstat_out = command_output_from_args([ "netstat", "-ln" ]);
    let missing_ports = tachyon_core_missing_standard_ports(netstat_out);
    if (length(missing_ports) == 0)
        tachyon_core_ports_listening = 1;
    let listen_ports = resolve_tachyon_core_listen_ports(netstat_out);
    if (length(missing_ports) > 0) {
        let missing_str = "missing: " + join(", ", missing_ports);
        listen_ports = listen_ports != "" ? (listen_ports + " (" + missing_str + ")") : missing_str;
    }

    write_json({
        tachyon_core_installed,
        tachyon_core_version_ok,
        tachyon_core_cert_pin,
        tachyon_core_service_exist,
        tachyon_core_autostart_disabled,
        tachyon_core_process_running,
        tachyon_core_ports_listening,
        tachyon_core_version,
        tachyon_core_bin_path: "/usr/bin/tachyon-core",
        tachyon_core_init_path: "/etc/init.d/tachyon-core",
        tachyon_core_listen_ports: listen_ports
    });
    return 0;
}


return {
    check_logs,
    check_tachyon_core_logs,
    tachyon_logs_fixture,
    show_tachyon_core_config,
    show_config,
    show_version,
    show_tachyon_core_version,
    get_luci_app_version,
    system_info_cache_is_valid,
    ensure_subscription_runtime_dirs,
    write_system_info_cache,
    tachyon_core_component_action_running,
    tachyon_core_resolved_version,
    tachyon_core_capability_flags,
    provider_installed,
    provider_version,
    openwrt_release,
    get_system_arch_candidates,
    build_system_info,
    get_system_info,
    get_server_capabilities,
    tachyon_core_process_is_running,
    service_status_label,
    write_service_status,
    get_tachyon_core_status,
    get_engine_status,
    get_status,
    subscription_cache,
    print_subscription_result,
    section_safe,
    get_outbound_metadata,
    get_subscription_metadata,
    strip_leading_v,
    check_tachyon_core
};
