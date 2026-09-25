#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");
let network_mod = require("diagnostics.network");
let dns_mod = require("diagnostics.dns");
let status_bridge = require("diagnostics.status_bridge");

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
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constants.TMP_SING_BOX_FOLDER || "/tmp/sing-box";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || constants.TMP_SUBSCRIPTION_FOLDER || TMP_SING_BOX_FOLDER + "/subscriptions";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || constants.SB_VARIANT_STATE_FILE || "/etc/tachyon/sing-box-variant";
const SING_BOX_BIN_PATH = getenv("TACHYON_DIAGNOSTICS_SING_BOX_BIN_PATH") || "/usr/bin/sing-box";
const CLOUDFLARE_OCTETS = getenv("CLOUDFLARE_OCTETS") || constants.CLOUDFLARE_OCTETS || "8.47 162.159 188.114";
const RUNTIME_STABLE_MIN_AGE = getenv("TACHYON_RUNTIME_STABLE_MIN_AGE") || "2";

const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const PACKAGES_UC = LIB_DIR + "/core/packages.uc";
const SERVICE_STATE_UC = LIB_DIR + "/service/state.uc";
const SERVICE_UI_UC = LIB_DIR + "/service/ui.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const PROVIDERS_STATUS_UC = LIB_DIR + "/providers/status.uc";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";
const ZAPRET_RUNTIME_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_RUNTIME_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const BYEDPI_RUNTIME_UC = LIB_DIR + "/providers/byedpi/runtime.uc";
const WDTT_RUNTIME_UC = LIB_DIR + "/providers/wdtt/runtime.uc";
const OLCRTC_RUNTIME_UC = LIB_DIR + "/providers/olcrtc/runtime.uc";
const FPTN_RUNTIME_UC = LIB_DIR + "/providers/fptn/runtime.uc";
const TAILSCALE_RUNTIME_UC = LIB_DIR + "/providers/tailscale/runtime.uc";
const ZAPRET_VALIDATOR_UC = LIB_DIR + "/providers/zapret/validator.uc";
const ZAPRET2_VALIDATOR_UC = LIB_DIR + "/providers/zapret2/validator.uc";
const BYEDPI_VALIDATOR_UC = LIB_DIR + "/providers/byedpi/validator.uc";

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
function words(value) { return network_mod.words(value); }
function parse_json_or_null(text) { return network_mod.parse_json_or_null(text); }
function get_wan_ip_addresses() { return network_mod.get_wan_ip_addresses(); }
function sing_box_standard_ports_listening(netstat) { return network_mod.sing_box_standard_ports_listening(netstat); }

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
    return (engine != null && engine != "") ? as_string(engine) : "sing-box";
}

function active_engine_is_steer() {
    let name = active_engine_name();
    return name == "steer" || name == "steer-extended";
}

function status_capture(args, input) { return status_bridge.status_capture(args, input); }
function status_output(args, input) { return status_bridge.status_output(args, input); }
function status_success(args, input) { return status_bridge.status_success(args, input); }

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
function file_executable(path) { return command_success_from_args([ "test", "-x", as_string(path) ]); }
function command_exists(name) { return command_success_from_args([ "command", "-v", as_string(name) ]); }
function stdout_is_tty() { return command_status("test -t 1") == 0; }
function nolog(message) { if (stdout_is_tty()) print(as_string(message), "
"); }

function ensure_dir(dir) {
    dir = as_string(dir);
    if (dir == "" || fs.stat(dir) != null) return;
    let parts = split(dir, "/");
    let current = "";
    for (let part in parts) {
        if (part == "") continue;
        current = current + "/" + part;
        if (fs.stat(current) == null) fs.mkdir(current);
    }
}

function remove_file(path) {
    path = as_string(path);
    if (path != "" && fs.stat(path) != null) fs.unlink(path);
}

function first_line_value(path) {
    path = as_string(path);
    if (path == "" || fs.stat(path) == null) return "";
    let data = fs.readfile(path);
    if (!data) return "";
    let lines = split(as_string(data), "
");
    return length(lines) > 0 ? trim(lines[0]) : "";
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

function check_sing_box_logs() {
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    // Use bounded_command to prevent logread from hanging and leaking a zombie process.
    let cmd = common.bounded_command("logread -l " + LOGREAD_LINE_LIMIT + " 2>/dev/null", "5");
    let rendered = status_capture([ "matching-log-tail", "sing-box", "100" ], command_output(cmd));
    if (rendered.output != "")
        print(rendered.output);
    else
        print("No matching logs found in system journal (needle: sing-box)\n");
    return 0;
}

function tachyon_logs_fixture() {
    let rendered = status_capture([ "tachyon-logs" ], read_stdin());
    if (rendered.output != "")
        print(rendered.output);
    return rendered.status;
}

function show_sing_box_config(visibility) {
    visibility = as_string(visibility || "masked");
    let sing_box_config_path = option(settings(), "config_path", "");
    nolog("Current sing-box configuration:");
    if (!file_exists(sing_box_config_path)) {
        nolog("Configuration file not found");
        return 1;
    }
    if (visibility == "raw")
        print(as_string(fs.readfile(sing_box_config_path)));
    else
        print(status_output([ "mask-sing-box-config", sing_box_config_path ], null));
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

function show_sing_box_version() {
    print(replace(module_output(SINGBOX_RUNTIME_UC, [ "version" ]), /[\r\n]+$/g, ""), "\n");
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
    let cfg_st = fs.stat(TACHYON_CONFIG);
    if (cfg_st && cfg_st.mtime > generated_at)
        return false;
    return cache.tachyon_version == TACHYON_VERSION && cache.luci_app_version == get_luci_app_version();
}

function ensure_subscription_runtime_dirs() {
    module_success(SUBSCRIPTION_CACHE_UC, [
        "ensure-runtime-dirs"
    ]);
    ensure_dir(RUNTIME_STATE_DIR);
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

function sing_box_marker_is(expected) {
    return module_success(SINGBOX_RUNTIME_UC, [ "marker-is", expected ]);
}

function sing_box_component_action_running() {
    return module_success(SERVICE_UI_UC, [ "component-action-running-for", "sing_box" ]);
}

// Only the variants whose binary cannot be executed for a version string fall back
// to the state file: `extended-compressed` is a self-extracting stub and `lx` needs
// a runtime that may be absent. Plain `extended` runs `sing-box version` fine, and
// listing it here made the UI show whatever was last written to
// /etc/tachyon/sing-box-version — a file only the component action updates. A
// sing-box installed any other way (install.sh, opkg, by hand) then displayed a
// stale version forever, and the update badge compared against it.
function sing_box_live_probe_disabled() {
    return sing_box_marker_is("extended-compressed") ||
        sing_box_marker_is("lx") ||
        sing_box_component_action_running();
}

// Resolves the pair (version, version-output) both callers below need. The state
// file is only consulted for variants whose binary cannot be run, and an empty or
// missing state falls through to the live probe rather than reporting "unknown":
// the state is written by the component action alone, so any sing-box installed by
// install.sh, opkg or by hand has none.
function sing_box_resolved_version() {
    if (sing_box_live_probe_disabled()) {
        let state = replace(module_output(SINGBOX_RUNTIME_UC, [ "read-version-state" ]), /[\r\n]+$/g, "");
        if (state != "")
            return { version: state, output: "" };
    }

    let output = module_output(SINGBOX_RUNTIME_UC, [ "version-output" ]);
    return {
        version: replace(module_output_stdin(SINGBOX_RUNTIME_UC, [ "version-from-output" ], output), /[\r\n]+$/g, ""),
        output: output
    };
}

function sing_box_tiny_package_installed() {
    return module_success(PACKAGES_UC, [ "installed", "sing-box-tiny" ]);
}

function sing_box_capability_flags(sing_box_version, sing_box_version_output) {
    let extended = 0;
    let tiny = 0;
    let tailscale = 0;
    let cert_pin = 0;

    if (sing_box_marker_is("extended") ||
        sing_box_marker_is("extended-compressed") ||
        module_success(SINGBOX_RUNTIME_UC, [ "is-extended", sing_box_version ]))
        extended = 1;

    if (sing_box_marker_is("lx") || module_success(SINGBOX_RUNTIME_UC, [ "is-lx", sing_box_version ]))
        extended = 1;

    if (extended == 0 && (sing_box_marker_is("tiny") || sing_box_tiny_package_installed()))
        tiny = 1;

    if (extended == 1)
        tailscale = 1;
    else if (as_string(sing_box_version_output) != "") {
        if (module_success(SINGBOX_RUNTIME_UC, [ "supports-tailscale", sing_box_version, sing_box_version_output ]))
            tailscale = 1;
    }
    else if (tiny == 0 && sing_box_component_action_running())
        tailscale = 1;

    if (module_success(SINGBOX_RUNTIME_UC, [ "supports-cert-pin", sing_box_version ]))
        cert_pin = 1;

    return { extended, tiny, tailscale, cert_pin };
}

function provider_installed(runtime_uc) {
    return module_success(runtime_uc, [ "installed" ]);
}

function provider_version(runtime_uc) {
    let value = replace(module_output(runtime_uc, [ "package-version" ]), /[\r\n]+$/g, "");
    return value != "" ? value : "unknown";
}

function openwrt_release() {
    let data = fs.readfile("/etc/os-release");
    if (data == null)
        return "unknown";
    for (let line in split(as_string(data), "\n")) {
        if (substr(line, 0, length("OPENWRT_RELEASE=")) != "OPENWRT_RELEASE=")
            continue;
        let value = substr(line, length("OPENWRT_RELEASE="));
        if (length(value) >= 2) {
            let quote = substr(value, 0, 1);
            if ((quote == "\"" || quote == "'") && substr(value, length(value) - 1) == quote)
                value = substr(value, 1, length(value) - 2);
        }
        return value != "" ? value : "unknown";
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

function is_fptn_supported() {
    let arch_list = get_system_arch_candidates();
    let supported = [
        "x86_64", "amd64",
        "aarch64", "arm64",
        "arm_cortex-a7_neon-vfpv4",
        "arm_cortex-a7"
    ];
    for (let s in supported) {
        if (index(arch_list, s) >= 0)
            return true;
    }
    return false;
}

function build_system_info() {
    let tachyon_latest_version = first_line_value("/tmp/tachyon.latest-version.cache", "unknown");
    let luci_app_version = get_luci_app_version();
    let sing_box_version = "";
    let sing_box_version_output = "";

    if (command_exists("sing-box")) {
        let resolved = sing_box_resolved_version();
        sing_box_version = resolved.version;
        sing_box_version_output = resolved.output;
        if (sing_box_version == "")
            sing_box_version = "unknown";
    }
    else {
        sing_box_version = "not installed";
        sing_box_version_output = "";
    }

    let flags = sing_box_capability_flags(sing_box_version, sing_box_version_output);
    let sing_box_compressed = flags.extended == 1 && sing_box_marker_is("extended-compressed") ? 1 : 0;
    let sing_box_lx = flags.extended == 1 && sing_box_marker_is("lx") ? 1 : 0;

    let sing_box_repo_url = "https://github.com/SagerNet/sing-box";
    if (sing_box_lx == 1)
        sing_box_repo_url = "https://github.com/Leadaxe/sing-box-lx";
    else if (flags.extended == 1)
        sing_box_repo_url = "https://github.com/shtorm-7/sing-box-extended";

    let zapret_installed = provider_installed(ZAPRET_RUNTIME_UC) ? 1 : 0;
    let zapret_version = zapret_installed ? provider_version(ZAPRET_RUNTIME_UC) : "not installed";
    let zapret2_installed = provider_installed(ZAPRET2_RUNTIME_UC) ? 1 : 0;
    let zapret2_version = zapret2_installed ? provider_version(ZAPRET2_RUNTIME_UC) : "not installed";
    let byedpi_installed = provider_installed(BYEDPI_RUNTIME_UC) ? 1 : 0;
    let byedpi_version = byedpi_installed ? provider_version(BYEDPI_RUNTIME_UC) : "not installed";
    let wdtt_installed = provider_installed(WDTT_RUNTIME_UC) ? 1 : 0;
    let wdtt_version = wdtt_installed ? provider_version(WDTT_RUNTIME_UC) : "not installed";
    let olcrtc_installed = provider_installed(OLCRTC_RUNTIME_UC) ? 1 : 0;
    let olcrtc_version = olcrtc_installed ? provider_version(OLCRTC_RUNTIME_UC) : "not installed";
    let tailscale_installed = provider_installed(TAILSCALE_RUNTIME_UC) ? 1 : 0;
    let tailscale_version = tailscale_installed ? provider_version(TAILSCALE_RUNTIME_UC) : "not installed";
    let fptn_installed = provider_installed(FPTN_RUNTIME_UC) ? 1 : 0;
    let fptn_supported = (fptn_installed == 1 || is_fptn_supported()) ? 1 : 0;
    let fptn_version = fptn_installed ? provider_version(FPTN_RUNTIME_UC) : "not installed";
    let steer_installed = file_executable("/usr/sbin/steer") ? 1 : 0;
    let steer_version = "not installed";
    let steer_extended = 0;
    if (steer_installed) {
        let steer_out = trim(command_output_from_args([ "/usr/sbin/steer", "version" ]));
        let m = match(steer_out, /steer\s+([0-9a-zA-Z\.\-]+)/);
        steer_version = m ? m[1] : (steer_out != "" ? steer_out : "installed");
        steer_extended = (match(steer_out, /расширенная|extended/i) != null ||
            command_success_from_args([ "/usr/sbin/steer", "help", "vless" ]) ||
            module_success(PACKAGES_UC, [ "installed", "steer-extended" ])) ? 1 : 0;
    }
    let device_model = first_line_value("/tmp/sysinfo/model", "unknown");

    let direct_bypass_enabled = bool_option(settings(), "direct_bypass_enabled", false) ? 1 : 0;
    let direct_bypass_port = option(settings(), "direct_bypass_port", "2080");
    let direct_bypass_address = direct_bypass_enabled
        ? trim(command_output_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/singbox/runtime.uc", "service-listen-address" ]))
        : "";
    let torrserver_direct_status = parse_json_or_null(command_output_from_args([ "ucode", "-L", LIB_DIR, LIB_DIR + "/torrserver/direct.uc", "status" ]));
    if (type(torrserver_direct_status) != "object")
        torrserver_direct_status = {};

    let show_component_zapret = bool_option(settings(), "show_component_zapret", true) ? 1 : 0;
    let show_component_zapret2 = bool_option(settings(), "show_component_zapret2", true) ? 1 : 0;
    let show_component_byedpi = bool_option(settings(), "show_component_byedpi", true) ? 1 : 0;
    let show_component_wdtt = bool_option(settings(), "show_component_wdtt", true) ? 1 : 0;
    let show_component_olcrtc = bool_option(settings(), "show_component_olcrtc", true) ? 1 : 0;
    let show_component_fptn = bool_option(settings(), "show_component_fptn", true) ? 1 : 0;
    let show_component_tailscale = bool_option(settings(), "show_component_tailscale", true) ? 1 : 0;
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
    let sb_meta = read_backup_meta("sing_box");
    let zapret_meta = read_backup_meta("zapret");
    let zapret2_meta = read_backup_meta("zapret2");
    let byedpi_meta = read_backup_meta("byedpi");
    let wdtt_meta = read_backup_meta("wdtt");
    let olcrtc_meta = read_backup_meta("olcrtc");
    let tailscale_meta = read_backup_meta("tailscale");
    let fptn_meta = read_backup_meta("fptn");

    return {
        tachyon_version: TACHYON_VERSION,
        tachyon_commit_sha: constants.TACHYON_COMMIT_SHA && !match(constants.TACHYON_COMMIT_SHA, /COMPILED/) ? constants.TACHYON_COMMIT_SHA : "",
        tachyon_latest_version: tachyon_latest_version || "unknown",
        luci_app_version,
        active_engine: active_engine_name(),
        sing_box_version,
        sing_box_extended: flags.extended,
        sing_box_tiny: flags.tiny,
        sing_box_compressed,
        sing_box_lx,
        sing_box_tailscale: flags.tailscale,
        sing_box_cert_pin: flags.cert_pin,
        sing_box_repo_url,
        sing_box_backup_version: sb_meta ? as_string(sb_meta.version) : "",
        sing_box_backup_time: sb_meta ? int(sb_meta.timestamp || 0) : 0,
        zapret_version,
        zapret_installed,
        zapret_backup_version: zapret_meta ? as_string(zapret_meta.version) : "",
        zapret_backup_time: zapret_meta ? int(zapret_meta.timestamp || 0) : 0,
        zapret2_version,
        zapret2_installed,
        zapret2_backup_version: zapret2_meta ? as_string(zapret2_meta.version) : "",
        zapret2_backup_time: zapret2_meta ? int(zapret2_meta.timestamp || 0) : 0,
        byedpi_version,
        byedpi_installed,
        byedpi_backup_version: byedpi_meta ? as_string(byedpi_meta.version) : "",
        byedpi_backup_time: byedpi_meta ? int(byedpi_meta.timestamp || 0) : 0,
        wdtt_version,
        wdtt_installed,
        wdtt_backup_version: wdtt_meta ? as_string(wdtt_meta.version) : "",
        wdtt_backup_time: wdtt_meta ? int(wdtt_meta.timestamp || 0) : 0,
        olcrtc_version,
        olcrtc_installed,
        olcrtc_backup_version: olcrtc_meta ? as_string(olcrtc_meta.version) : "",
        olcrtc_backup_time: olcrtc_meta ? int(olcrtc_meta.timestamp || 0) : 0,
        tailscale_version,
        tailscale_installed,
        tailscale_backup_version: tailscale_meta ? as_string(tailscale_meta.version) : "",
        tailscale_backup_time: tailscale_meta ? int(tailscale_meta.timestamp || 0) : 0,
        fptn_version,
        fptn_installed,
        fptn_supported,
        fptn_backup_version: fptn_meta ? as_string(fptn_meta.version) : "",
        fptn_backup_time: fptn_meta ? int(fptn_meta.timestamp || 0) : 0,
        steer_version,
        steer_installed,
        steer_extended,
        steer_repo_url: "https://github.com/xyzmean/steer",
        direct_bypass_enabled,
        direct_bypass_address,
        direct_bypass_port,
        torrserver_running: int(torrserver_direct_status.running || 0),
        torrserver_direct_available: int(torrserver_direct_status.available || 0),
        torrserver_direct_enabled: int(torrserver_direct_status.enabled || 0),
        torrserver_direct_active: int(torrserver_direct_status.active || 0),
        show_component_zapret,
        show_component_zapret2,
        show_component_byedpi,
        show_component_wdtt,
        show_component_olcrtc,
        show_component_fptn,
        show_component_tailscale,
        show_component_direct_bypass,
        show_component_torrserver_direct,
        dashboard_hide_na_servers: (() => {
            let sections = uci_core.section_objects(CONFIG_NAME, "section");
            for (let s in sections)
                if (uci_core.get(CONFIG_NAME, s, "dashboard_hide_na_servers") == "1")
                    return 1;
            return 0;
        })(),
        openwrt_version: openwrt_release(),
        device_model,
        generated_at: int(clock()[0])
    };
}

function get_system_info() {
    if (system_info_cache_is_valid()) {
        print(as_string(fs.readfile(SYSTEM_INFO_CACHE_FILE)));
        return 0;
    }

    let system_info = sprintf("%J", build_system_info());
    write_system_info_cache(system_info);
    print(system_info, "\n");
    return 0;
}

function get_server_capabilities() {
    if (!file_executable(SING_BOX_BIN_PATH)) {
        write_json({
            sing_box_extended: 0,
            sing_box_tiny: 0,
            sing_box_tailscale: 0,
            sing_box_cert_pin: 0
        });
        return 0;
    }

    let resolved = sing_box_resolved_version();
    let flags = sing_box_capability_flags(resolved.version, resolved.output);
    write_json({
        sing_box_extended: flags.extended,
        sing_box_tiny: flags.tiny,
        sing_box_tailscale: flags.tailscale,
        sing_box_cert_pin: flags.cert_pin
    });
    return 0;
}


function sing_box_process_is_running() {
    return command_success_from_args([ "pgrep", "-x", "sing-box" ]) ||
        command_success_from_args([ "pgrep", "-f", "^/usr/bin/sing-box[[:space:]]" ]);
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
    return module_success(DNS_APPLY_UC, [ "has-tachyon-dns" ]);
}

function get_sing_box_status() {
    let running = module_success(SERVICE_STATE_UC, [
        "sing-box-service-stable",
        RUNTIME_STABLE_MIN_AGE
    ]) ? 1 : 0;
    let enabled = file_executable("/etc/rc.d/S99sing-box") ? 1 : 0;
    let dns_configured = dnsmasq_has_tachyon_dns() ? 1 : 0;
    write_service_status(running, enabled, dns_configured);
    return 0;
}

// Engine-aware service status for the dashboard. On sing-box it is the same
// answer as get_sing_box_status; on steer it reports the steer service and the
// active engine, so the UI does not show a false "sing-box stopped".
function get_engine_status() {
    let active = "sing-box";
    try {
        active = require("core.engine").get_active();
    }
    catch (e) {
        active = "sing-box";
    }

    if (active == "sing-box")
        return get_sing_box_status();

    let running = 0;
    let enabled = 0;
    let channels = [];
    try {
        let engine_runtime = require("service.engine_runtime");
        let info = require("core.engine").detect(active);
        // steer registers with START=94, so the enable symlink is S94steer
        // (get_status below has the same check). Liveness comes from the init
        // script itself, not from the symlink: an enabled-but-dead service
        // must not be reported as running.
        enabled = command_success_from_args([ "sh", "-c", "ls /etc/rc.d/S*steer >/dev/null 2>&1" ]) ? 1 : 0;
        running = info.installed && command_success_from_args([ "/etc/init.d/steer", "status" ]) ? 1 : 0;
        if (running) {
            let status_raw = fs.readfile("/var/lib/steer/status.json");
            if (status_raw == null || status_raw == "") {
                status_raw = command_output_from_args([ "/usr/sbin/steer", "status" ]);
            }
            if (status_raw != null && status_raw != "") {
                let parsed = json(status_raw);
                if (parsed && type(parsed.channels) == "array")
                    channels = parsed.channels;
            }
        }
    }
    catch (e) {
        running = 0;
        enabled = 0;
    }
    let dns_configured = 1;
    write_json({
        running,
        enabled,
        engine: active,
        status: service_status_label(running, enabled),
        dns_configured,
        channels
    });
    return 0;
}

function get_status() {
    // On steer the sing-box runtime checks do not apply: liveness comes from
    // the steer init script and its own nftables table.
    if (active_engine_is_steer()) {
        let running = command_success_from_args([ "/etc/init.d/steer", "status" ]) ? 1 : 0;
        // steer uses START=94, so the enable symlink is S94steer.
        let enabled = command_success_from_args([ "sh", "-c", "ls /etc/rc.d/S*steer >/dev/null 2>&1" ]) ? 1 : 0;
        let dns_configured = 1;
        write_service_status(running, enabled, dns_configured);
        return 0;
    }

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
    if (!section_safe(section))
        return print_subscription_result(subscription_cache([ "empty-outbound-metadata" ]), "");
    let metadata_path = replace(module_output(SUBSCRIPTION_CACHE_UC, [ "outbound-metadata-path", section ]), /[\r\n]+$/g, "");
    if (metadata_path == "")
        return print_subscription_result(subscription_cache([ "empty-outbound-metadata" ]), "");
    let result = subscription_cache([ "get-outbound-metadata", SECTION_CACHE_DIR, section, metadata_path ]);
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

function validate_nfqws_strategy_json(raw_opt) {
    let result = module_capture(ZAPRET_VALIDATOR_UC, [
        "validate-json", "nfqws", as_string(raw_opt), ZAPRET_LEGACY_DEFAULT_NFQWS_OPT
    ]);
    if (result.output != "")
        print(result.output);
    return 0;
}

function validate_nfqws2_strategy_json(raw_opt) {
    let result = module_capture(ZAPRET2_VALIDATOR_UC, [ "validate-json", "nfqws2", as_string(raw_opt) ]);
    if (result.output != "")
        print(result.output);
    return 0;
}

function validate_byedpi_strategy_json(raw_opt) {
    let result = module_capture(BYEDPI_VALIDATOR_UC, [ "validate-json", as_string(raw_opt) ]);
    if (result.output != "")
        print(result.output);
    else
        print("{\"valid\":false,\"message\":\"ByeDPI validator produced no output\"}\n");
    return 0;
}

function strip_leading_v(value) {
    value = as_string(value);
    return substr(value, 0, 1) == "v" ? substr(value, 1) : value;
}


function check_steer() {
    // These checks describe steer state; on sing-box they are not applicable.
    if (!active_engine_is_steer()) {
        write_json({ not_applicable: 1, engine: active_engine_name() });
        return 0;
    }

    let steer_installed = 0;
    let steer_version = "";
    let steer_service_exist = 0;
    let steer_autostart_enabled = 0;
    let steer_process_running = 0;
    let steer_extended = 0;

    let steer_bin = "/usr/sbin/steer";
    if (file_executable(steer_bin)) {
        steer_installed = 1;
        let ver = trim(command_output(command_from_args([steer_bin, "version"]) + " 2>/dev/null"));
        if (ver == "")
            ver = trim(command_output(command_from_args([steer_bin, "--version"]) + " 2>/dev/null"));
        steer_version = ver != "" ? ver : "";

        // Detect extended build: check version string, active engine ID, or binary size heuristic
        let stat = fs.stat(steer_bin);
        if ((stat != null && stat.size > 8 * 1024 * 1024) ||
            match(steer_version, /расширенная|extended/i) != null ||
            active_engine_name() == "steer-extended")
            steer_extended = 1;
    }

    if (file_exists("/etc/init.d/steer")) {
        steer_service_exist = 1;
        // Steer uses START=94, enabled if S94steer symlink is present in /etc/rc.d/
        steer_autostart_enabled = command_success_from_args(
            ["sh", "-c", "ls /etc/rc.d/S*steer >/dev/null 2>&1"]
        ) ? 1 : 0;
    }

    if (steer_installed && file_exists("/etc/init.d/steer")) {
        steer_process_running = command_success_from_args(
            ["/etc/init.d/steer", "status"]
        ) ? 1 : 0;
    }

    write_json({
        steer_installed,
        steer_version,
        steer_extended,
        steer_service_exist,
        steer_autostart_enabled,
        steer_process_running
    });
    return 0;
}

function check_sing_box() {
    // These checks describe sing-box state; on steer they are not applicable
    // rather than failing, so the dashboard shows an honest answer.
    if (active_engine_is_steer()) {
        write_json({ not_applicable: 1, engine: active_engine_name() });
        return 0;
    }
    let sing_box_installed = 0;
    let sing_box_version_ok = 0;
    let sing_box_extended = 0;
    let sing_box_cert_pin = 0;
    let sing_box_service_exist = 0;
    let sing_box_autostart_disabled = 0;
    let sing_box_process_running = 0;
    let sing_box_ports_listening = 0;

    if (command_exists("sing-box")) {
        sing_box_installed = 1;
        let version = strip_leading_v(replace(module_output(SINGBOX_RUNTIME_UC, [ "version" ]), /[\r\n]+$/g, ""));
        if (version != "") {
            if (sing_box_marker_is("lx") || module_success(SINGBOX_RUNTIME_UC, [ "is-lx", version ]))
                sing_box_extended = 1;
            else if (sing_box_marker_is("extended-compressed") || module_success(SINGBOX_RUNTIME_UC, [ "is-extended", version ]))
                sing_box_extended = 1;
            if (module_success(HELPERS_UC, [ "version-at-least", version, "1.12.4" ]))
                sing_box_version_ok = 1;
            if (module_success(SINGBOX_RUNTIME_UC, [ "supports-cert-pin", version ]))
                sing_box_cert_pin = 1;
        }
        else if (sing_box_marker_is("extended-compressed") || sing_box_marker_is("lx")) {
            sing_box_extended = 1;
            if (module_success(SINGBOX_RUNTIME_UC, [ "supports-cert-pin", "" ]))
                sing_box_cert_pin = 1;
        }
    }

    if (file_exists("/etc/init.d/sing-box")) {
        sing_box_service_exist = 1;
        if (!command_success_from_args([ "/etc/init.d/sing-box", "enabled" ]))
            sing_box_autostart_disabled = 1;
    }

    if (sing_box_process_is_running())
        sing_box_process_running = 1;

    if (sing_box_standard_ports_listening(command_output_from_args([ "netstat", "-ln" ])))
        sing_box_ports_listening = 1;

    write_json({
        sing_box_installed,
        sing_box_version_ok,
        sing_box_extended,
        sing_box_cert_pin,
        sing_box_service_exist,
        sing_box_autostart_disabled,
        sing_box_process_running,
        sing_box_ports_listening
    });
    return 0;
}


return {
    check_logs,
    check_sing_box_logs,
    tachyon_logs_fixture,
    show_sing_box_config,
    show_config,
    show_version,
    show_sing_box_version,
    get_luci_app_version,
    system_info_cache_is_valid,
    ensure_subscription_runtime_dirs,
    write_system_info_cache,
    sing_box_marker_is,
    sing_box_component_action_running,
    sing_box_live_probe_disabled,
    sing_box_resolved_version,
    sing_box_tiny_package_installed,
    sing_box_capability_flags,
    provider_installed,
    provider_version,
    openwrt_release,
    get_system_arch_candidates,
    is_fptn_supported,
    build_system_info,
    get_system_info,
    get_server_capabilities,
    sing_box_process_is_running,
    service_status_label,
    write_service_status,
    get_sing_box_status,
    get_engine_status,
    get_status,
    subscription_cache,
    print_subscription_result,
    section_safe,
    get_outbound_metadata,
    get_subscription_metadata,
    validate_nfqws_strategy_json,
    validate_nfqws2_strategy_json,
    validate_byedpi_strategy_json,
    strip_leading_v,
    check_steer,
    check_sing_box
};
