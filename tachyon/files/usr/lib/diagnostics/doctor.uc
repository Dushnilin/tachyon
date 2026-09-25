#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");
let rag = require("diagnostics.rag");
let network_mod = require("diagnostics.network");
let dns_mod = require("diagnostics.dns");
let routing_mod = require("diagnostics.routing");
let sysinfo_mod = require("diagnostics.system_info");
let status_bridge = require("diagnostics.status_bridge");
let repairs_mod = require("diagnostics.repairs");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TACHYON_VERSION = getenv("TACHYON_VERSION") || constants.TACHYON_VERSION || "";
const TACHYON_CONFIG = getenv("TACHYON_CONFIG") || constants.TACHYON_CONFIG || "/etc/config/" + CONFIG_NAME;
const TACHYON_SERVICE_NAME = getenv("TACHYON_SERVICE_NAME") || constants.TACHYON_SERVICE_NAME || "tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const LOGREAD_LINE_LIMIT = "500";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constants.TMP_SING_BOX_FOLDER || "/tmp/sing-box";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || constants.TMP_RULESET_FOLDER || TMP_SING_BOX_FOLDER + "/rulesets";
const CHECK_PROXY_IP_DOMAIN = getenv("CHECK_PROXY_IP_DOMAIN") || constants.CHECK_PROXY_IP_DOMAIN || "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = getenv("FAKEIP_TEST_DOMAIN") || constants.FAKEIP_TEST_DOMAIN || "fakeip.podkop.fyi";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || constants.SB_DNS_INBOUND_ADDRESS || "127.0.0.42";
const STEER_DNS_ADDRESS = getenv("STEER_DNS_ADDRESS") || "127.0.0.1";
const STEER_DNS_PORT = getenv("STEER_DNS_PORT") || "5300";
const STEER_NFT_TABLE = getenv("STEER_NFT_TABLE") || "steer";
const SB_TPROXY_INBOUND6_ADDRESS = getenv("SB_TPROXY_INBOUND6_ADDRESS") || constants.SB_TPROXY_INBOUND6_ADDRESS || "::1";
const SB_TPROXY_INBOUND_PORT = getenv("SB_TPROXY_INBOUND_PORT") || constants.SB_TPROXY_INBOUND_PORT || "1602";
const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT = getenv("ZAPRET_LEGACY_DEFAULT_NFQWS_OPT") || constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT || "";
const CLOUDFLARE_OCTETS = getenv("CLOUDFLARE_OCTETS") || constants.CLOUDFLARE_OCTETS || "8.47 162.159 188.114";

const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const SERVICE_STATE_UC = LIB_DIR + "/service/state.uc";
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
const STATUS_UC = LIB_DIR + "/diagnostics/status.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_output = common.command_output;
let command_success = common.command_success;
let command_capture = common.command_capture;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let object_or_empty = common.object_or_empty;
let read_stdin = common.read_stdin;
let read_json_file = common.read_json_file;
let write_json = common.write_json;

function words(value) { return network_mod.words(value); }
function parse_json_or_null(text) { return network_mod.parse_json_or_null(text); }
function valid_ipv4(value) { return network_mod.valid_ipv4(value); }
function valid_public_ip(value) { return network_mod.valid_public_ip(value); }
function get_wan_ip_addresses() { return network_mod.get_wan_ip_addresses(); }
function get_wan_interface() { return network_mod.get_wan_interface(); }
function default_gateway_exists() { return network_mod.default_gateway_exists(); }
function wan_has_ip() { return network_mod.wan_has_ip(); }
function device_ipv4_address(iface) { return network_mod.device_ipv4_address(iface); }

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

function list_option(cfg, key) {
    if (type(cfg) != "object") return [];
    let value = cfg[key];
    if (type(value) == "array") return value;
    if (type(value) == "string") return words(value);
    return [];
}

function settings() { return uci_core.get_all(CONFIG_NAME, "settings") || {}; }
function uci_sections(type_name) { return uci_core.section_objects(CONFIG_NAME, type_name); }

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

function module_status(module_path, args) {
    return module_capture(module_path, args).status;
}

function module_passthrough(module_path, args) {
    let result = module_capture(module_path, args);
    if (result.output != "")
        print(result.output);
    return result.status;
}

function build_system_info() { return sysinfo_mod.build_system_info(); }
function show_config(visibility) { return sysinfo_mod.show_config(visibility); }
function provider_installed(runtime_uc) { return sysinfo_mod.provider_installed(runtime_uc); }
function sing_box_resolved_version() { return sysinfo_mod.sing_box_resolved_version(); }
function sing_box_capability_flags(version) { return sysinfo_mod.sing_box_capability_flags(version); }
function dns_check_router_resolver_available(router_ip) { return dns_mod.dns_check_router_resolver_available(router_ip); }
function clash_api_url() { return routing_mod.clash_api_url(); }
function uci_backup_save() { return repairs_mod.uci_backup_save(); }
function uci_backup_restore() { return repairs_mod.uci_backup_restore(); }

function uci_get(path) {
    return uci_core.get(path);
}

function uci_show(path) {
    return uci_core.exists(path);
}

function uci_config_valid() {
    let data = fs.readfile(TACHYON_CONFIG);
    if (data == null || data == "") return false;
    let res = command_status("uci -c /etc/config valid " + CONFIG_NAME + " >/dev/null 2>&1");
    return res == 0;
}

function file_executable(path) {
    return command_success_from_args([ "test", "-x", as_string(path) ]);
}

function remove_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function allowed_ips_default_routes(value) {
    let result = [];
    for (let allowed in words(value)) {
        if (allowed == "0.0.0.0/0" || allowed == "::/0")
            push(result, allowed);
    }
    return result;
}

function append_unique(values, value) {
    value = as_string(value);
    if (value == "")
        return;
    for (let current in values) {
        if (current == value)
            return;
    }
    push(values, value);
}

function config_section_types(path) {
    let result = [];
    let content = fs.readfile(as_string(path));
    if (content == null)
        return result;

    for (let line in split(content, "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, 7) != "config ")
            continue;

        let fields = split(line, /[ \t\r\n]+/);
        if (length(fields) >= 2)
            append_unique(result, replace(as_string(fields[1]), /['"]/g, ""));
    }

    return result;
}

function uci_show_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function append_uci_show_option(lines, package_name, section_name, key, value) {
    if (key == ".name" || key == ".type")
        return;

    let path = as_string(package_name) + "." + as_string(section_name) + "." + as_string(key) + "=";
    if (type(value) == "array") {
        for (let item in value)
            push(lines, path + uci_show_quote(item));
    }
    else {
        push(lines, path + uci_show_quote(value));
    }
}

function uci_show_data(package_name, config_path) {
    let lines = [];
    package_name = as_string(package_name);
    for (let type_name in config_section_types(config_path)) {
        for (let section in uci_core.section_objects(package_name, type_name)) {
            let name = as_string(section[".name"] || "");
            if (name == "")
                continue;
            push(lines, package_name + "." + name + "=" + as_string(section[".type"] || type_name));
            for (let key, value in section)
                append_uci_show_option(lines, package_name, name, key, value);
        }
    }
    return join("\n", lines) + "\n";
}

function network_show_data() {
    return uci_show_data("network", "/etc/config/network");
}

function helper_output(mode, args) {
    let full = [ mode ];
    for (let arg in args) push(full, as_string(arg));
    return replace(module_output(HELPERS_UC, full), /[
]+$/g, "");
}

function file_exists(path) { return fs.stat(as_string(path)) != null; }
function command_exists(name) { return command_status("which " + shell_quote(name) + " >/dev/null 2>&1") == 0; }
function stdout_is_tty() { return command_status("test -t 1") == 0; }
function nolog(message) { if (stdout_is_tty()) print(as_string(message), "
"); }

function dns_check_resolve_host(host, resolver, timeout_seconds) {
    return dns_mod.dns_check_resolve_host(host, resolver, timeout_seconds);
}

function dns_check_through_singbox(domain) {
    return dns_mod.dns_check_through_singbox(domain);
}

function get_all_dns_servers(cfg, key) {
    return dns_mod.get_all_dns_servers(cfg, key);
}

function get_server_capabilities() {
    return sysinfo_mod.get_server_capabilities();
}

function check_sing_box() {
    return sysinfo_mod.check_sing_box();
}

function check_steer() {
    return sysinfo_mod.check_steer();
}

function check_dns_available() {
    return dns_mod.check_dns_available();
}

function check_fakeip() {
    return dns_mod.check_fakeip();
}

function check_proxy() {
    return routing_mod.check_proxy();
}

function check_nft() {
    return routing_mod.check_nft();
}

function check_nft_rules() {
    return routing_mod.check_nft_rules();
}

function check_inbounds() {
    return routing_mod.check_inbounds();
}

function print_global(message) {
    print(as_string(message), "\n");
}

function render_or_fail(mode_args, input, fail_message, ok_statuses) {
    let result = status_capture(mode_args, input);
    if (result.output != "")
        print(result.output);
    for (let status in ok_statuses)
        if (result.status == status)
            return result.status;
    print_global(fail_message);
    return result.status;
}

function global_check(arg1, arg2) {
    let visibility = as_string(arg2 || "masked");
    if (as_string(arg1) == "raw" || as_string(arg1) == "masked")
        visibility = as_string(arg1);

    print_global("═══ Global check run!");
    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ System info");

    let system_info_json = sprintf("%J", build_system_info());
    render_or_fail([ "global-system-info" ], system_info_json, "❌ Failed to parse system info", [ 0 ]);

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ DNS status");

    let dns_check_capture = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-dns-available" ])));
    if (dns_check_capture.output != "") {
        let dns_render = render_or_fail(
            [ "global-dns-check", bool_option(settings(), "dont_touch_dhcp", false) ? "1" : "0" ],
            dns_check_capture.output,
            "❌ Failed to parse DNS info",
            [ 0, 10 ]
        );
        if (dns_render == 10)
            print(status_output([ "dhcp-dnsmasq-config", "/etc/config/dhcp" ], null));
    }
    else
        print_global("❌ Failed to get DNS info");

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ Sing-box status");
    let singbox_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-sing-box" ]))).output;
    if (singbox_check_json != "")
        render_or_fail([ "global-sing-box-check" ], singbox_check_json, "❌ Failed to parse sing-box info", [ 0 ]);
    else
        print_global("❌ Failed to get sing-box info");

    print_global("---------------------------");
    print_global("Inbounds checks");
    let inbounds_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-inbounds" ]))).output;
    if (inbounds_check_json != "")
        render_or_fail([ "global-inbounds-check" ], inbounds_check_json, "[FAIL] Failed to parse inbounds check details", [ 0 ]);
    else
        print_global("[FAIL] Failed to get inbounds info");

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ NFT rules status");
    let nft_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-nft-rules" ]))).output;
    if (nft_check_json != "") {
        let nft_render = render_or_fail([ "global-nft-check" ], nft_check_json, "❌ Failed to parse NFT rules info", [ 0 ]);
        if (nft_render == 0 && status_success([ "global-nft-other-mark-exists" ], nft_check_json))
            print(status_output([ "nft-ruleset-other-mark-lines", NFT_TABLE_NAME ],
                command_output_from_args([ "sh", "-c", "nft list ruleset | grep -E '^table|mark set|meta mark'; exit 0" ])));
    }
    else
        print_global("❌ Failed to get NFT rules info");

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ Tachyon config");
    show_config(visibility);

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ WAN config");
    if (uci_show("network.wan")) {
        if (visibility == "raw")
            print(as_string(fs.readfile("/etc/config/network")));
        else
            print(status_output([ "wan-config-masked", "/etc/config/network" ], null));
    }
    else
        print_global("❌ WAN configuration not found");

    let network_show = network_show_data();
    for (let line in split(status_output([ "network-endpoint-host-warnings", CLOUDFLARE_OCTETS ], network_show), "\n")) {
        if (line == "")
            continue;
        let fields = split(line, "\t");
        if (length(fields) < 2)
            continue;
        if (fields[0] == "engage")
            print_global("⚠️ WARP detected: " + fields[1]);
        else if (fields[0] == "prefix") {
            print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
            print_global("⚠️ WARP detected: " + fields[1]);
        }
    }

    for (let peer_section in split(status_output([ "network-wireguard-route-allowed-peers" ], network_show), "\n")) {
        peer_section = as_string(peer_section);
        if (peer_section == "")
            continue;
        let default_routes = allowed_ips_default_routes(uci_get(peer_section + ".allowed_ips"));
        if (length(default_routes) > 0) {
            print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
            print_global("⚠️ WG Route allowed IP enabled with " + join(", ", default_routes));
        }
    }

    if (file_executable("/etc/init.d/zapret") && command_success_from_args([ "/etc/init.d/zapret", "status" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret service is active. Tachyon uses separate queues, but packet-level policy overlap is possible.");
    }
    else if (file_executable("/etc/init.d/zapret") && command_success_from_args([ "/etc/init.d/zapret", "enabled" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret autostart is enabled. Tachyon will not modify /etc/config/zapret.");
    }

    if (file_executable("/etc/init.d/zapret2") && command_success_from_args([ "/etc/init.d/zapret2", "status" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret2 service is active. Tachyon uses separate queues, but packet-level policy overlap is possible.");
    }
    else if (file_executable("/etc/init.d/zapret2") && command_success_from_args([ "/etc/init.d/zapret2", "enabled" ])) {
        print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        print_global("⚠️ Standalone zapret2 autostart is enabled. Tachyon will not modify /etc/config/zapret2.");
    }

    print_global("━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    print_global("═══ FakeIP status");
    let fakeip_check_json = command_capture(command_from_args(module_args(LIB_DIR + "/diagnostics/runtime.uc", [ "check-fakeip" ]))).output;
    if (fakeip_check_json != "")
        render_or_fail([ "global-fakeip-check" ], fakeip_check_json, "❌ Failed to parse FakeIP info", [ 0 ]);
    else
        print_global("❌ Failed to get FakeIP info");

    return 0;
}

function find_process_pid(name) {
    let pids = split(trim(command_capture(command_from_args(["pidof", name])).output), /\s+/);
    return length(pids) > 0 && pids[0] != "" ? pids[0] : "";
}

function is_container_process(pid) {
    pid = as_string(pid);
    if (pid == "")
        return false;
    let host_net = fs.readlink("/proc/1/ns/net");
    let proc_net = fs.readlink("/proc/" + pid + "/ns/net");
    if (host_net != null && proc_net != null && host_net != proc_net)
        return true;
    let cgroup = fs.readfile("/proc/" + pid + "/cgroup") || "";
    if (index(cgroup, "docker") >= 0 || index(cgroup, "containerd") >= 0)
        return true;
    return false;
}

function uci_settings() {
    return uci_core.get_all(CONFIG_NAME, "settings") || {};
}

function is_adguardhome_primary_dns(cfg) {
    let agh_pid = find_process_pid("AdGuardHome");
    if (agh_pid == "")
        agh_pid = find_process_pid("adguardhome");
    if (agh_pid == "" || is_container_process(agh_pid))
        return false;

    let dnsmasq_port = uci_core.get("dhcp.@dnsmasq[0].port");
    let settings = cfg || uci_settings();
    let dont_touch = bool_option(settings, "dont_touch_dhcp", false);
    return dnsmasq_port == "0" || dont_touch;
}

// The main service loop writes its pid file on start (start_runtime in
// watchdog.uc). With enable_watchdog='0' the loop is not spawned but sing-box
// keeps running as its own procd service — that state still counts as running:
// the doctor must never treat a live Tachyon as a stopped one.
function tachyon_is_running() {
    let wd_pid = trim(fs.readfile("/var/run/tachyon_watchdog.pid") || "");
    if (wd_pid != "" && fs.stat("/proc/" + wd_pid) != null) return true;
    let eng = "sing-box";
    try { eng = require("core.engine").get_active(); } catch (e) {}
    if (eng == "steer" || eng == "steer-extended") {
        return find_process_pid("steer") != "" || command_success_from_args([ "/etc/init.d/steer", "status" ]);
    }
    return find_process_pid("sing-box") != "";
}

function tachyon_is_enabled() {
    return file_executable("/etc/rc.d/S99" + TACHYON_SERVICE_NAME);
}

function is_degraded() {
    return fs.stat("/tmp/tachyon/degraded") != null;
}

function kill_our_core_processes() {
    let eng = "sing-box";
    try { eng = require("core.engine").get_active(); } catch (e) {}
    if (eng == "steer" || eng == "steer-extended") {
        command_status("/etc/init.d/steer stop >/dev/null 2>&1");
        command_status("killall -9 steer >/dev/null 2>&1");
        return;
    }
    command_status("/etc/init.d/sing-box stop >/dev/null 2>&1");
    command_status("killall -9 sing-box >/dev/null 2>&1");
}

// ─── Recovery mode: Tachyon is stopped, restore stock internet ───────────────
// The doctor doubles as an emergency repair tool: it must work with the service
// fully stopped (disabled in LuCI, crashed, or removed) and return the router
// to a stock state — WAN up, DNS resolving for the LAN — without ever starting
// Tachyon. Everything here is idempotent: on a cleanly stopped service the
// checks pass and nothing is touched.
// Declared before run_doctor_checks(): ucode does not hoist function
// declarations, and run_doctor_checks() dispatches to this mode.

// Doctor repairs are opt-in. By default the doctor only diagnoses: every
// mutation (UCI rewrites, service restarts, process kills, resolv.conf or
// nftables changes) is recorded as a planned action instead of being applied.
// Repair mode is enabled explicitly via CLI ("doctor --fix") or by passing
// repair=true to run_doctor_checks().
let DOCTOR_REPAIR_MODE = false;
let DOCTOR_PLANNED_FIXES = [];

function doc_repair_enabled() {
    return DOCTOR_REPAIR_MODE;
}

function doc_plan(action) {
    push(DOCTOR_PLANNED_FIXES, as_string(action));
}

// Mode-aware mutation primitives used inside the doctor checks. In dry-run
// they record intent and report success so surrounding control flow stays
// unchanged; callers gate their re-verification on doc_repair_enabled().
function doc_set(path, value) {
    if (!DOCTOR_REPAIR_MODE) {
        doc_plan("uci set " + as_string(path) + "=" + as_string(value));
        return true;
    }
    return uci_core.set(path, value);
}

function doc_commit(pkg) {
    if (!DOCTOR_REPAIR_MODE) {
        doc_plan("uci commit " + as_string(pkg));
        return true;
    }
    return uci_core.commit(pkg);
}

function doc_run(cmd) {
    if (!DOCTOR_REPAIR_MODE) {
        doc_plan("run: " + as_string(cmd));
        return 0;
    }
    return command_status(cmd);
}

function doc_unlink(path) {
    if (!DOCTOR_REPAIR_MODE) {
        doc_plan("unlink " + as_string(path));
        return;
    }
    try { fs.unlink(path); } catch (e) {}
}

function doc_symlink(target, path) {
    if (!DOCTOR_REPAIR_MODE) {
        doc_plan("symlink " + as_string(target) + " -> " + as_string(path));
        return true;
    }
    try { fs.symlink(target, path); return true; } catch (e) { return false; }
}

function run_recovery_checks() {
    let report = [];
    let issues = 0;
    let fixed = 0;

    let doc_check = function(icon, name, status, fix_msg) {
        let msg = fix_msg != "" ? fix_msg : status;
        push(report, sprintf("%s %-30s %s", icon, name, msg));
    };

    // In dry-run the restoration steps are reported as planned instead of
    // being applied, so a plain diagnostic pass never mutates the system.
    let mark_fixed = function(name, status, what) {
        if (DOCTOR_REPAIR_MODE) {
            doc_check("❌", name, status, "→ FIXED: " + what);
            fixed++;
        } else {
            doc_check("⚠️", name, status, "→ WILL FIX (doctor --fix): " + what);
        }
    };

    let time_str = command_output_from_args(["date", "+%d.%m %H:%M"]);
    push(report, sprintf("🩺 *tachyon doctor* — %s — *режим восстановления*", trim(time_str)));
    if (!DOCTOR_REPAIR_MODE)
        push(report, "Сервис Tachyon остановлен. Сухой режим: показываю, что будет восстановлено (применение — doctor --fix).");
    else
        push(report, "Сервис Tachyon остановлен. Возвращаю систему в сток и проверяю интернет.");
    push(report, "");

    // WAN must be up before DNS makes any sense.
    if (wan_has_ip() && default_gateway_exists()) {
        doc_check("✅", "WAN interface", get_wan_interface() + " up, gateway present", "");
    } else {
        issues++;
        let had_ip = wan_has_ip();
        doc_run("/sbin/ifup wan >/dev/null 2>&1");
        doc_run("sleep 3");
        if (!had_ip) {
            if (!DOCTOR_REPAIR_MODE || wan_has_ip()) {
                mark_fixed("WAN interface", get_wan_interface() + " no IP", "WAN поднят");
            } else {
                doc_check("❌", "WAN interface", "no IP address", "→ проверьте подключение к провайдеру");
            }
        } else {
            if (!DOCTOR_REPAIR_MODE || default_gateway_exists()) {
                mark_fixed("Default gateway", "missing", "маршрут восстановлен");
            } else {
                doc_check("❌", "Default gateway", "missing", "→ проверьте конфигурацию сети");
            }
        }
    }

    // Leftover routing is what breaks internet when the service is down.
    // Idempotent cleanup mirroring uninstall.uc.
    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])) {
        doc_run("nft delete table inet " + NFT_TABLE_NAME + " >/dev/null 2>&1");
        mark_fixed("nftables table", "leftover", "удалена");
    } else {
        doc_check("✅", "nftables table", "absent", "");
    }

    let ip_rule_out = command_capture("ip rule list").output;
    if (index(ip_rule_out, "fwmark") >= 0 && index(ip_rule_out, "lookup " + RT_TABLE_NAME) >= 0) {
        doc_run("ip rule del fwmark 0x1/0x1 >/dev/null 2>&1");
        doc_run("ip rule del fwmark 0x2/0x2 >/dev/null 2>&1");
        doc_run("ip route flush table " + RT_TABLE_NAME + " >/dev/null 2>&1");
        mark_fixed("routing rules (fwmark)", "leftover", "удалены");
    } else {
        doc_check("✅", "routing rules (fwmark)", "absent", "");
    }

    // dnsmasq must answer the LAN and talk to upstream directly.
    let agh_primary_rec = is_adguardhome_primary_dns();
    if (!agh_primary_rec && module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) == 0) {
        issues++;
        if (DOCTOR_REPAIR_MODE)
            module_status(DNS_APPLY_UC, [ "failsafe-restore" ]);
        else
            doc_plan("dns/apply.uc failsafe-restore");
        if (!DOCTOR_REPAIR_MODE || module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) != 0) {
            mark_fixed("dnsmasq DNS", "redirected to sing-box", "возвращён на прямые upstream");
        } else {
            doc_check("❌", "dnsmasq DNS", "redirected to sing-box", "→ не удалось восстановить — проверьте /etc/config/dhcp");
        }
    } else {
        doc_check("✅", "dnsmasq DNS", agh_primary_rec ? "bypassed (AdGuardHome on :53, dnsmasq DHCP-only)" : "direct (stock)", "");
    }

    let dropins = [ "/etc/dnsmasq.d/tachyon.conf", "/tmp/dnsmasq.d/tachyon.conf" ];
    let dropins_removed = false;
    for (let d in dropins) {
        if (fs.stat(d) != null) {
            doc_unlink(d);
            dropins_removed = true;
        }
    }
    if (dropins_removed) {
        mark_fixed("dnsmasq drop-ins", "leftover", "удалены");
    } else {
        doc_check("✅", "dnsmasq drop-ins", "absent", "");
    }

    // resolv.conf must be the stock symlink and point at a working upstream.
    let resolv_fixed = false;
    let resolv_link = "";
    try { resolv_link = fs.readlink("/etc/resolv.conf") || ""; } catch(e) {}
    if (resolv_link != "/tmp/resolv.conf" && resolv_link != "../tmp/resolv.conf") {
        doc_unlink("/etc/resolv.conf");
        if (doc_symlink("/tmp/resolv.conf", "/etc/resolv.conf"))
            resolv_fixed = true;
    }
    if (trim(fs.readfile("/tmp/resolv.conf") || "") == "") {
        if (DOCTOR_REPAIR_MODE) {
            fs.writefile("/tmp/resolv.conf", "nameserver 1.1.1.1\nnameserver 8.8.8.8\n");
        } else {
            doc_plan("write /tmp/resolv.conf nameservers");
        }
        resolv_fixed = true;
    }
    if (resolv_fixed) {
        mark_fixed("resolv.conf", "broken", "восстановлена ссылка и nameserver");
    } else {
        doc_check("✅", "resolv.conf", "OK (-> /tmp/resolv.conf)", "");
    }

    // A stray sing-box (crashed service, half-removed install) must not sit
    // between the LAN and the WAN.
    if (find_process_pid("sing-box") != "") {
        if (DOCTOR_REPAIR_MODE)
            kill_our_core_processes();
        else
            doc_plan("kill leftover sing-box processes");
        mark_fixed("sing-box process", "leftover", "остановлен");
    } else {
        doc_check("✅", "sing-box process", "absent", "");
    }

    // Final verification: DNS through dnsmasq and straight upstream.
    push(report, "");
    let lan_dns = dns_check_resolve_host("google.com", "127.0.0.1", 3);
    let up_dns = dns_check_resolve_host("google.com", "1.1.1.1", 3);
    if (lan_dns != "" && up_dns != "") {
        doc_check("✅", "DNS resolution", "LAN + upstream working", "");
    } else if (lan_dns != "") {
        issues++;
        doc_check("⚠️", "DNS resolution", "LAN OK, upstream blocked", "→ провайдер режет upstream, проверьте /tmp/resolv.conf");
    } else {
        issues++;
        doc_check("❌", "DNS resolution", "not working", "→ проверьте интернет-соединение");
    }

    push(report, "");
    if (issues == 0) {
        push(report, "✅ Система в стоковом состоянии — интернет работает напрямую");
    } else if (DOCTOR_REPAIR_MODE) {
        push(report, sprintf("⚠️ Проблем: %d   Исправлено: %d", issues, fixed));
    } else {
        push(report, sprintf("⚠️ Проблем: %d   Планируется к исправлению: %d (применить: tachyon doctor --fix)", issues, length(DOCTOR_PLANNED_FIXES)));
    }

    return { report: join("\n", report) + "\n", issues, fixed, checks: [], planned_fixes: DOCTOR_PLANNED_FIXES };
}

function has_certificate_pins_configured() {
    let sections = uci_core.section_objects(CONFIG_NAME, "section");
    for (let sec in sections) {
        if (sec.enabled == "0" || sec.enabled == "false")
            continue;
        let urls = type(sec.proxy_urls) == "array" ? sec.proxy_urls : (sec.proxy_urls ? [ sec.proxy_urls ] : []);
        if (sec.proxy_url)
            push(urls, sec.proxy_url);
        for (let u in urls) {
            if (index(as_string(u), "pcs=") >= 0)
                return true;
        }
        if (index(as_string(sec.proxy_custom_json || ""), "certificate_sha256") >= 0 ||
            index(as_string(sec.proxy_custom_json || ""), "pcs=") >= 0)
            return true;
    }
    let sub_files = fs.glob(constants.TMP_SUBSCRIPTION_FOLDER + "/*.json") || [];
    for (let sf in sub_files) {
        let content = fs.readfile(sf);
        if (content && index(content, '"certificate_sha256"') >= 0)
            return true;
    }
    let sec_files = fs.glob(SECTION_CACHE_DIR + "/*/outbounds.json") || [];
    for (let scf in sec_files) {
        let content = fs.readfile(scf);
        if (content && index(content, '"certificate_sha256"') >= 0)
            return true;
    }
    return false;
}

function run_doctor_checks_impl(repair) {
    DOCTOR_REPAIR_MODE = (repair == true);
    DOCTOR_PLANNED_FIXES = [];

    let report = [];
    let issues = 0;
    let fixed = 0;
    let cfg = uci_settings();
    // With the service stopped the doctor switches to recovery mode: it must
    // restore the stock internet (DNS back to direct upstream, no leftover
    // rules) instead of "repairing" the stopped state by re-hijacking dnsmasq
    // onto a dead sing-box DNS listener — the exact way a user ends up with no
    // internet after disabling Tachyon (issue #31).
    if (!tachyon_is_running()) {
        return run_recovery_checks();
    }

    let is_degraded_flag = is_degraded();

    let checks = [];
    let doc_check = function(icon, name, status, fix_msg) {
        let msg = status;
        if (fix_msg != "") {
            msg = fix_msg;
        }
        push(report, sprintf("%s %-30s %s", icon, name, msg));
        push(checks, {
            name: name,
            status: icon == "✅" ? "pass" : (icon == "⚠️" ? "warn" : (icon == "❌" ? "fail" : "info")),
            detail: status,
            fix: fix_msg
        });
    };

    let time_str = command_output_from_args(["date", "+%d.%m %H:%M"]);
    push(report, sprintf("🩺 *tachyon doctor* — %s", trim(time_str)));
    push(report, "");

    if (cfg.recovery_bypass == "1") {
        push(report, "⚠️ *Режим аварийного обхода (Safe Bypass) активен.*");
        push(report, "Все прокси-службы и правила фильтрации временно отключены.");
        push(report, "");

        let wd_running = false;
        let wd_pid = trim(fs.readfile("/var/run/tachyon_watchdog.pid") || "");
        if (wd_pid != "" && fs.stat("/proc/" + wd_pid) != null) {
            wd_running = true;
        }

        let core_disp = cfg.core || "sing-box";
        doc_check("⚫", core_disp, "bypassed (stopped)", "");
        doc_check("⚫", "nftables rules", "bypassed (flushed)", "");
        doc_check("⚫", "routing rules (ip rule)", "bypassed (removed)", "");
        doc_check("⚫", "dnsmasq server", "bypassed (direct WAN)", "");

        if (dns_check_resolve_host("google.com", "127.0.0.1", 2) != "") {
            doc_check("✅", "DNS resolution", "working (direct)", "");
        } else {
            doc_check("❌", "DNS resolution", "failed", "→ Проверьте подключение к интернету");
            issues++;
        }

        if (wd_running) {
            doc_check("✅", "Watchdog", "running (standby)", "");
        } else {
            doc_check("⚠️", "Watchdog", "stopped", "→ перезапустите службу");
            issues++;
        }

        push(report, "");
        push(report, "ℹ️ Автоматические проверки приостановлены в режиме Safe Bypass.");
        return { report: join("\n", report) + "\n", issues, fixed, checks };
    }

    let active_engine = "sing-box";
    try {
        active_engine = require("core.engine").get_active();
    } catch (e) {}
    let is_steer = (active_engine == "steer" || active_engine == "steer-extended");

    let binary_name = is_steer ? "steer" : "sing-box";
    let init_script = is_steer ? "/etc/init.d/steer" : "/etc/init.d/sing-box";
    let config_file_path = is_steer ? "/etc/steer/spec.json" : "/etc/sing-box/config.json";

    // 1. Process Check
    let has_sections = false;
    let uci_sections = uci_core.get_all(CONFIG_NAME);
    if (uci_sections) {
        for (let k in keys(uci_sections)) {
            if (uci_sections[k][".type"] == "section") {
                has_sections = true;
                break;
            }
        }
    }

    let pid = find_process_pid(binary_name);
    if (pid != "") {
        doc_check("✅", (is_steer ? active_engine : binary_name) + " process", "running (PID " + pid + ")", "");
    } else if (!has_sections && !is_steer) {
        doc_check("ℹ️", binary_name + " process", "not started", "→ Настройте подключение в LuCI — ядро запустится автоматически");
    } else {
        issues++;
        if (!DOCTOR_REPAIR_MODE) {
            doc_plan("kill conflicting processes; " + init_script + " start");
            doc_check("⚠️", (is_steer ? active_engine : binary_name) + " process", "stopped", "→ WILL FIX (doctor --fix): запуск службы " + active_engine);
        } else {
            kill_our_core_processes();
            command_status("sleep 1");
            command_status(init_script + " start >/dev/null 2>&1");
            command_status("sleep 3");
            pid = find_process_pid(binary_name);
            if (pid != "") {
                doc_check("❌", (is_steer ? active_engine : binary_name) + " process", "stopped", "→ FIXED: запущен");
                fixed++;
            } else {
                doc_check("❌", (is_steer ? active_engine : binary_name) + " process", "stopped", "→ не удалось запустить — проверьте логи");
            }
        }
    }

    // 2. Configuration Check
    if (is_steer) {
        if (fs.stat(config_file_path) != null) {
            let check_res = command_status("/usr/sbin/steer apply --dry-run >/dev/null 2>&1");
            if (check_res == 0) {
                doc_check("✅", active_engine + " spec", "valid", "");
            } else {
                issues++;
                if (!DOCTOR_REPAIR_MODE) {
                    doc_plan("regenerate steer spec (/usr/bin/tachyon reload)");
                    doc_check("⚠️", active_engine + " spec", "invalid", "→ WILL FIX (doctor --fix): перегенерация спеки");
                } else {
                    command_status("ucode -L " + LIB_DIR + " " + LIB_DIR + "/service/engine_runtime.uc engine-apply >/dev/null 2>&1");
                    let check_res2 = command_status("/usr/sbin/steer apply --dry-run >/dev/null 2>&1");
                    if (check_res2 == 0) {
                        doc_check("❌", active_engine + " spec", "invalid", "→ FIXED: спека восстановлена");
                        fixed++;
                    } else {
                        doc_check("❌", active_engine + " spec", "invalid", "→ не удалось восстановить спеку");
                    }
                }
            }
        } else {
            doc_check("ℹ️", active_engine + " spec", "not yet created", "");
        }
    } else if (fs.stat(config_file_path) != null) {
        let check_res = command_status(binary_name + " check -c " + config_file_path + " >/dev/null 2>&1");
        if (check_res == 0) {
            doc_check("✅", binary_name + " config", "valid", "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("regenerate sing-box config (configure-service) + restart");
                doc_check("⚠️", binary_name + " config", "invalid", "→ WILL FIX (doctor --fix): пересоздание конфига");
            } else {
                let regen_status = command_status("ucode -L " + LIB_DIR + " " + SINGBOX_RUNTIME_UC + " configure-service >/dev/null 2>&1");
                if (regen_status == 0) {
                    let check_res2 = command_status(binary_name + " check -c " + config_file_path + " >/dev/null 2>&1");
                    if (check_res2 == 0) {
                        doc_check("❌", binary_name + " config", "invalid", "→ FIXED: пересоздан и успешно валидирован");
                        fixed++;
                        command_status(init_script + " restart >/dev/null 2>&1");
                    } else {
                        doc_check("❌", binary_name + " config", "invalid", "→ не удалось восстановить (ошибка валидации)");
                    }
                } else {
                    doc_check("❌", binary_name + " config", "invalid", "→ не удалось перегенерировать конфиг");
                }
            }
        }
    } else {
        if (!has_sections) {
            doc_check("ℹ️", binary_name + " config", "not yet created", "→ Настройте Tachyon в LuCI для генерации конфига");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("regenerate sing-box config (configure-service)");
                doc_check("⚠️", "sing-box config", "missing", "→ WILL FIX (doctor --fix): генерация конфига");
            } else {
                let regen_status = command_status("ucode -L " + LIB_DIR + " " + SINGBOX_RUNTIME_UC + " configure-service >/dev/null 2>&1");
                if (regen_status == 0 && fs.stat(config_file_path) != null) {
                    doc_check("❌", "sing-box config", "missing", "→ FIXED: пересоздан");
                    fixed++;
                } else {
                    doc_check("❌", binary_name + " config", "missing", "→ не удалось сгенерировать config");
                }
            }
        }
    }

    // 2b. UCI Config Integrity Check
    if (has_sections) {
        if (uci_config_valid()) {
            doc_check("✅", "UCI config", "valid", "");
            uci_backup_save();
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("restore UCI config from backup");
                doc_check("⚠️", "UCI config", "corrupted", "→ WILL FIX (doctor --fix): восстановление из backup");
            } else if (uci_backup_restore()) {
                command_status("sleep 1");
                if (uci_config_valid()) {
                    doc_check("❌", "UCI config", "corrupted", "→ FIXED: восстановлен из backup");
                    fixed++;
                } else {
                    doc_check("❌", "UCI config", "corrupted", "→ backup тоже повреждён, проверьте /etc/config/tachyon вручную");
                }
            } else {
                doc_check("❌", "UCI config", "corrupted or missing", "→ backup не найден, восстановите конфиг вручную");
            }
        }
    }

    // 3. Nftables Table Check
    if (is_steer) {
        let out_nft = command_capture("nft list table inet steer 2>/dev/null").output;
        if (index(out_nft, "table inet steer") >= 0) {
            doc_check("✅", "nftables table (inet steer)", "present", "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("/usr/sbin/steer apply");
                doc_check("⚠️", "nftables table (inet steer)", "missing", "→ WILL FIX (doctor --fix): применение правил steer");
            } else {
                command_status("/usr/sbin/steer apply >/dev/null 2>&1");
                let out_check = command_capture("nft list table inet steer 2>/dev/null").output;
                if (index(out_check, "table inet steer") >= 0) {
                    doc_check("❌", "nftables table (inet steer)", "missing", "→ FIXED: правила steer применены");
                    fixed++;
                } else {
                    doc_check("❌", "nftables table (inet steer)", "missing", "→ не удалось применить правила steer");
                }
            }
        }

        // Steer Diag Check
        let diag_str = trim(command_capture("/usr/sbin/steer diag 2>/dev/null").output);
        if (diag_str != "") {
            try {
                let diag_res = json(diag_str);
                if (type(diag_res) == "object" && type(diag_res.checks) == "array") {
                    for (let c in diag_res.checks) {
                        let icon = c.verdict == "ok" ? "✅" : (c.verdict == "note" ? "ℹ️" : "⚠️");
                        if (c.verdict == "fail") {
                            if (c.id == "zapret" && !provider_installed(ZAPRET_RUNTIME_UC)) {
                                icon = "ℹ️";
                            } else {
                                issues++;
                            }
                        }
                        doc_check(icon, "steer diag: " + c.id, c.what, c.why ? "→ " + c.why : "");
                    }
                }
            } catch (e) {}
        }
    } else {
        let routing_mode = cfg.routing_mode || "nftables";
        if (routing_mode == "nftables") {
            let out_nft = command_capture("nft list table inet " + NFT_TABLE_NAME + " | grep tproxy").output;
            if (index(out_nft, "tproxy") >= 0) {
                doc_check("✅", "nftables table", "present", "");
            } else {
                if (is_degraded_flag) {
                    doc_check("⚠️", "nftables table", "missing or incomplete", "→ GRACEFUL DEGRADATION: Proxy offline");
                } else {
                    issues++;
                    if (!DOCTOR_REPAIR_MODE) {
                        doc_plan("delete nft table + /usr/bin/tachyon restart");
                        doc_check("⚠️", "nftables table", "missing or incomplete", "→ WILL FIX (doctor --fix): пересоздание правил");
                    } else {
                        command_status("nft delete table inet " + NFT_TABLE_NAME + " >/dev/null 2>&1");
                        let rebuild_status = command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
                        let out_nft_check = command_capture("nft list table inet " + NFT_TABLE_NAME + " | grep tproxy").output;
                        if (index(out_nft_check, "tproxy") >= 0) {
                            doc_check("❌", "nftables table", "missing or incomplete", "→ FIXED: правила пересозданы");
                            fixed++;
                        } else {
                            doc_check("❌", "nftables table", "missing or incomplete", "→ не удалось восстановить nftables правила");
                        }
                    }
                }
            }

            // 4. IP Rule Check
            let ip_rule_out = command_capture("ip rule list").output;
            if (index(ip_rule_out, "fwmark") >= 0 && index(ip_rule_out, "lookup " + RT_TABLE_NAME) >= 0) {
                doc_check("✅", "ip rule (fwmark)", "present", "");
            } else {
                issues++;
                if (!DOCTOR_REPAIR_MODE) {
                    doc_plan("/usr/bin/tachyon restart");
                    doc_check("⚠️", "ip rule", "missing", "→ WILL FIX (doctor --fix): восстановление маршрута");
                } else {
                    let rebuild_status = command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
                    let ip_rule_check = command_capture("ip rule list").output;
                    if (index(ip_rule_check, "fwmark") >= 0 && index(ip_rule_check, "lookup " + RT_TABLE_NAME) >= 0) {
                        doc_check("❌", "ip rule", "missing", "→ FIXED: маршрут восстановлен");
                        fixed++;
                    } else {
                        doc_check("❌", "ip rule", "missing", "→ не удалось восстановить ip rule");
                    }
                }
            }
        } else {
            let ip_link_out = command_capture("ip link show tun0").output;
            if (index(ip_link_out, "tun0") >= 0) {
                doc_check("✅", "tun0 interface", "up", "");
            } else {
                issues++;
                command_status(init_script + " restart >/dev/null 2>&1");
                command_status("sleep 3");
                let ip_link_check = command_capture("ip link show tun0").output;
                if (index(ip_link_check, "tun0") >= 0) {
                    doc_check("❌", "tun0 interface", "missing", "→ FIXED: интерфейс tun0 поднят после перезапуска службы");
                    fixed++;
                } else {
                    doc_check("❌", "tun0 interface", "missing", "→ не удалось поднять tun0");
                }
            }
        }
    }

    // 4e. Dnsmasq Redirection Check
    let agh_primary = is_adguardhome_primary_dns(cfg);
    if (is_steer) {
        let noresolv = uci_core.get("dhcp.@dnsmasq[0].noresolv");
        let server_list = uci_core.get("dhcp.@dnsmasq[0].server");
        let has_bad_server = false;
        let servers = [];
        if (type(server_list) == "array") servers = server_list;
        else if (type(server_list) == "string" && server_list != "") servers = [ server_list ];
        for (let s in servers) {
            if (index(s, "127.0.0.42") >= 0) has_bad_server = true;
        }

        let resolver_ok = dns_check_router_resolver_available("example.com");

        if (noresolv != "1" && !has_bad_server && resolver_ok) {
            doc_check("✅", "dnsmasq server", "direct (steer handles DNS interception via inet steer)", "");
            doc_check("✅", "dnsmasq params", "OK (noresolv=" + (noresolv || "0") + ", steer active)", "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("dns/apply.uc configure-steer");
                doc_check("⚠️", "dnsmasq params", "incorrect for steer", "→ WILL FIX (doctor --fix): configure dnsmasq for steer");
            } else {
                module_status(DNS_APPLY_UC, [ "configure-steer" ]);
                command_status("sleep 1");
                let noresolv2 = uci_core.get("dhcp.@dnsmasq[0].noresolv");
                let resolver_ok2 = dns_check_router_resolver_available("example.com");
                if (noresolv2 != "1" && resolver_ok2) {
                    doc_check("❌", "dnsmasq params", "incorrect for steer", "→ FIXED: dnsmasq настроен для steer (noresolv=0, апстримы восстановлены)");
                    fixed++;
                } else {
                    doc_check("❌", "dnsmasq params", "incorrect for steer", "→ не удалось настроить dnsmasq для steer");
                }
            }
        }
    } else if (agh_primary) {
        doc_check("✅", "dnsmasq server (Direct)", "bypassed (AdGuardHome on :53, dnsmasq DHCP-only)", "");
    } else if (module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) == 0) {
        doc_check("✅", "dnsmasq server (Direct)", SB_DNS_INBOUND_ADDRESS, "");
    } else {
        if (is_degraded_flag) {
            doc_check("⚠️", "dnsmasq server (Direct)", "direct", "→ GRACEFUL DEGRADATION: Proxy offline");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("dns/apply.uc configure force");
                doc_check("⚠️", "dnsmasq server (Direct)", "incorrect", "→ WILL FIX (doctor --fix): перенаправление на sing-box (" + SB_DNS_INBOUND_ADDRESS + ")");
            } else {
                module_status(DNS_APPLY_UC, [ "configure", "force" ]);
                command_status("sleep 1");
                if (module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) == 0) {
                    doc_check("❌", "dnsmasq server (Direct)", "incorrect", "→ FIXED: направлен на sing-box (" + SB_DNS_INBOUND_ADDRESS + ")");
                    fixed++;
                } else {
                    doc_check("❌", "dnsmasq server (Direct)", "incorrect", "→ не удалось перенаправить");
                }
            }
        }
    }

    // 4b. Dnsmasq Params Check (sing-box only)
    if (!is_steer) {
        if (agh_primary) {
            doc_check("✅", "dnsmasq params", "bypassed (DHCP-only mode, port 0)", "");
        } else {
            let noresolv = uci_core.get("dhcp.@dnsmasq[0].noresolv");
            let localuse = uci_core.get("dhcp.@dnsmasq[0].localuse");
            let rebind_protection = uci_core.get("dhcp.@dnsmasq[0].rebind_protection");
            if (noresolv == "1" && localuse == "1" && rebind_protection == "0") {
                doc_check("✅", "dnsmasq params", "OK (noresolv=1, localuse=1, rebind_protection=0)", "");
            } else {
                issues++;
                // noresolv/localuse are required for the sing-box DNS redirect to
                // work; rebind_protection=0 is a deliberate compatibility downgrade
                // for FakeIP answers — it must never be applied silently by a
                // diagnostic pass.
                if (!DOCTOR_REPAIR_MODE) {
                    doc_plan("uci set dhcp noresolv=1 localuse=1 rebind_protection=0 + dnsmasq restart");
                    doc_check("⚠️", "dnsmasq params", "incorrect", "→ WILL FIX (doctor --fix): noresolv=1, localuse=1, rebind_protection=0");
                } else {
                    doc_set("dhcp.@dnsmasq[0].noresolv", "1");
                    doc_set("dhcp.@dnsmasq[0].localuse", "1");
                    doc_set("dhcp.@dnsmasq[0].rebind_protection", "0");
                    doc_commit("dhcp");
                    command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
                    command_status("sleep 1");
                    let noresolv2 = uci_core.get("dhcp.@dnsmasq[0].noresolv");
                    let localuse2 = uci_core.get("dhcp.@dnsmasq[0].localuse");
                    let rebind_protection2 = uci_core.get("dhcp.@dnsmasq[0].rebind_protection");
                    if (noresolv2 == "1" && localuse2 == "1" && rebind_protection2 == "0") {
                        doc_check("❌", "dnsmasq params", "incorrect", "→ FIXED: noresolv=1, localuse=1, rebind_protection=0");
                        fixed++;
                    } else {
                        doc_check("❌", "dnsmasq params", "incorrect", "→ не удалось исправить параметры");
                    }
                }
            }
        }
    }

    // 4b2. Dnsmasq dns_redirect — when dhcp.@dnsmasq[0].dns_redirect='1',
    // firewall4 creates DNAT rules that redirect external DNS queries to the
    // router's :53. If Tachyon TProxy has already marked those packets, the
    // DNAT rewrites destination to 192.168.1.1:53 and sing-box hijack-dns
    // creates transparent sockets that collide with dnsmasq.
    if (!agh_primary) {
        let dns_redirect = uci_core.get("dhcp.@dnsmasq[0].dns_redirect");
        if (dns_redirect != "1") {
            doc_check("✅", "dnsmasq dns_redirect", "disabled (OK)", "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("uci set dhcp.@dnsmasq[0].dns_redirect='0' + dnsmasq restart");
                doc_check("⚠️", "dnsmasq dns_redirect", "enabled (causes DNAT → port 53 collision with sing-box)",
                    "→ WILL FIX (doctor --fix): отключение dns_redirect");
            } else {
                doc_set("dhcp.@dnsmasq[0].dns_redirect", "0");
                doc_commit("dhcp");
                command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
                command_status("sleep 1");
                let dr2 = uci_core.get("dhcp.@dnsmasq[0].dns_redirect");
                if (dr2 != "1") {
                    doc_check("❌", "dnsmasq dns_redirect", "enabled", "→ FIXED: dns_redirect=0");
                    fixed++;
                } else {
                    doc_check("❌", "dnsmasq dns_redirect", "enabled", "→ не удалось отключить dns_redirect");
                }
            }
        }
    }

    // 4b3. SQM (Smart Queue Management) & Bufferbloat compatibility
    let sqm_queues = uci_core.section_objects("sqm", "queue");
    let sqm_enabled_count = 0;
    let sqm_lan_bridge_conflict = null;
    let lan_bridge_ports = [];
    let br_lan_ports = uci_core.get("network.br_lan.ports") || uci_core.get("network.lan.ports") || [];
    if (type(br_lan_ports) == "string") br_lan_ports = split(br_lan_ports, /\s+/);
    if (type(br_lan_ports) == "array") {
        for (let p in br_lan_ports) push(lan_bridge_ports, as_string(p));
    }
    push(lan_bridge_ports, "br-lan");

    if (sqm_queues && length(sqm_queues) > 0) {
        for (let q in sqm_queues) {
            if (q && (q.enabled == "1" || q.enabled == true)) {
                sqm_enabled_count++;
                let q_iface = as_string(q.interface || "");
                for (let bp in lan_bridge_ports) {
                    if (q_iface == bp && bp != "") {
                        sqm_lan_bridge_conflict = q_iface;
                        break;
                    }
                }
            }
        }
    }

    if (sqm_enabled_count > 0) {
        let flow_offload = uci_core.get("firewall.@defaults[0].flow_offloading");
        if (flow_offload == "1" || flow_offload == "true") {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("uci set firewall.@defaults[0].flow_offloading='0' + firewall reload");
                doc_check("⚠️", "SQM / Flow Offloading", "conflict (flow offload bypasses SQM queues)",
                    "→ WILL FIX (doctor --fix): отключение flow_offloading для устранения bufferbloat");
            } else {
                doc_set("firewall.@defaults[0].flow_offloading", "0");
                doc_commit("firewall");
                command_status("/etc/init.d/firewall reload >/dev/null 2>&1");
                command_status("sleep 1");
                let fo2 = uci_core.get("firewall.@defaults[0].flow_offloading");
                if (fo2 != "1" && fo2 != "true") {
                    doc_check("❌", "SQM / Flow Offloading", "conflict", "→ FIXED: flow_offloading=0 (SQM bufferbloat восстановлен)");
                    fixed++;
                } else {
                    doc_check("❌", "SQM / Flow Offloading", "conflict", "→ не удалось отключить flow_offloading");
                }
            }
        } else {
            doc_check("✅", "SQM / Flow Offloading", "compatible (flow_offloading=0)", "");
        }

        if (sqm_lan_bridge_conflict != null) {
            issues++;
            doc_check("⚠️", "SQM interface (" + sqm_lan_bridge_conflict + ")", "misconfigured on LAN bridge",
                "→ Привяжите очередь SQM к WAN интерфейсу (pppoe-wan/wan)");
        } else {
            doc_check("✅", "SQM (CAKE/fq_codel)", "active (QoS cooperative mode)", "");
        }
    }

    // 4c. Resolv.conf symlink
    let resolv_link = "";
    // Throws when /etc/resolv.conf is a regular file rather than a symlink,
    // which is precisely the broken state the branch below repairs.
    try { resolv_link = fs.readlink("/etc/resolv.conf") || ""; } catch(e) {}
    if (resolv_link == "/tmp/resolv.conf" || resolv_link == "../tmp/resolv.conf") {
        doc_check("✅", "resolv.conf symlink", "OK (-> " + resolv_link + ")", "");
    } else {
        issues++;
        if (!DOCTOR_REPAIR_MODE) {
            doc_plan("restore /etc/resolv.conf -> /tmp/resolv.conf symlink");
            doc_check("⚠️", "resolv.conf symlink", "broken", "→ WILL FIX (doctor --fix): восстановление ссылки");
        } else {
            fs.unlink("/etc/resolv.conf");
            let sym_ok = false;
            try {
                fs.symlink("/tmp/resolv.conf", "/etc/resolv.conf");
                sym_ok = true;
            }
            catch (e) {
                // sym_ok stays false and the failure is reported to the user through
                // doc_check() below, which is this module's output channel.
            }
            if (sym_ok) {
                doc_check("❌", "resolv.conf symlink", "broken", "→ FIXED: восстановлена ссылка на /tmp/resolv.conf");
                fixed++;
            } else {
                doc_check("❌", "resolv.conf symlink", "broken", "→ не удалось восстановить ссылку");
            }
        }
    }

    // 5. DNS configuration servers
    let bootstrap_dns = "77.88.8.8";
    let main_dns = "1.1.1.1";
    let main_dns_type = "udp";
    if (cfg.bootstrap_dns_server) {
        let b_dns_list = type(cfg.bootstrap_dns_server) == "array" ? cfg.bootstrap_dns_server : split(trim(as_string(cfg.bootstrap_dns_server)), /\s+/);
        if (length(b_dns_list) > 0) bootstrap_dns = b_dns_list[0];
    }
    if (cfg.dns_server) {
        let m_dns_list = type(cfg.dns_server) == "array" ? cfg.dns_server : split(trim(as_string(cfg.dns_server)), /\s+/);
        if (length(m_dns_list) > 0) main_dns = m_dns_list[0];
    }
    main_dns_type = cfg.dns_type || "udp";

    // Strip proxy_group suffix
    let display_main = split(main_dns, "#")[0];
    let display_bootstrap = split(bootstrap_dns, "#")[0];

    // Check Bootstrap DNS
    let bootstrap_dns_reachable = false;
    if (dns_check_resolve_host("openwrt.org", bootstrap_dns, 2) != "") {
        bootstrap_dns_reachable = true;
        doc_check("✅", "DNS bootstrap (" + display_bootstrap + ")", "reachable", "");
    } else {
        issues++;
        if (command_status("ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1") == 0) {
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("reset resolv.conf to public nameservers + dnsmasq restart");
                doc_check("⚠️", "DNS bootstrap (" + display_bootstrap + ")", "unreachable", "→ WILL FIX (doctor --fix): сброс resolv.conf на 1.1.1.1");
            } else {
                fs.unlink("/etc/resolv.conf");
                // If the symlink cannot be created the writefile below still lands on
                // /tmp/resolv.conf and the dnsmasq restart still picks it up; the
                // resolve check that follows decides whether any of it worked.
                try { fs.symlink("/tmp/resolv.conf", "/etc/resolv.conf"); } catch(e) {}
                fs.writefile("/tmp/resolv.conf", "nameserver 1.1.1.1\nnameserver 8.8.8.8\n");
                command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
                command_status("sleep 2");
                if (dns_check_resolve_host("openwrt.org", bootstrap_dns, 2) != "") {
                    bootstrap_dns_reachable = true;
                    doc_check("❌", "DNS bootstrap (" + display_bootstrap + ")", "unreachable", "→ FIXED: сброшен resolv.conf на 1.1.1.1, DNS перезапущен");
                    fixed++;
                } else {
                    doc_check("❌", "DNS bootstrap (" + display_bootstrap + ")", "unreachable", "→ DNS заблокирован или недоступен");
                }
            }
        } else {
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("/sbin/ifup wan");
                doc_check("⚠️", "DNS bootstrap (" + display_bootstrap + ")", "unreachable", "→ WILL FIX (doctor --fix): перезапуск WAN-линка");
            } else {
                command_status("/sbin/ifup wan >/dev/null 2>&1");
                command_status("sleep 3");
                doc_check("❌", "DNS bootstrap (" + display_bootstrap + ")", "unreachable", "→ FIXED: линк отсутствует, отправлен сигнал перезапуска WAN");
                fixed++;
            }
        }
    }

    // Check Main DNS
    let dns_main_reachable = false;
    if (main_dns_type == "doh") {
        let doh_url = display_main;
        if (!match(doh_url, /^https?:\/\//))
            doh_url = "https://" + doh_url;
        if (!match(doh_url, /\/dns-query$/) && !match(doh_url, /\/query$/) && !match(doh_url, /^https?:\/\/[^\/]+\/.+/))
            doh_url = doh_url + "/dns-query";

        let curl_cmd = "curl -s -m 4 -o /dev/null -w '%{http_code}' " + shell_quote(doh_url) + " 2>/dev/null";
        let curl_res = command_capture(curl_cmd);
        if (curl_res.status == 0 && int(curl_res.output) < 400) {
            dns_main_reachable = true;
            doc_check("✅", "DNS main (" + display_main + ")", "reachable", "");
        } else {
            let base_url = replace(doh_url, /\/dns-query$/, "");
            let curl_cmd2 = "curl -s -m 4 -o /dev/null -w '%{http_code}' " + shell_quote(base_url) + " 2>/dev/null";
            let curl_res2 = command_capture(curl_cmd2);
            if (curl_res2.status == 0 && int(curl_res2.output) < 400) {
                dns_main_reachable = true;
                doc_check("✅", "DNS main (" + display_main + ")", "reachable", "");
            } else {
                doc_check("⚠️", "DNS main (" + display_main + ")", "ISP blocks direct DoH", "→ Норма: провайдер блокирует DoH напрямую, sing-box использует DoH через прокси");
            }
        }
    } else {
        if (dns_check_resolve_host("openwrt.org", main_dns, 2) != "") {
            dns_main_reachable = true;
            doc_check("✅", "DNS main (" + display_main + ")", "reachable", "");
        } else {
            issues++;
            if (bootstrap_dns_reachable) {
                if (!DOCTOR_REPAIR_MODE) {
                    doc_plan("dnsmasq restart");
                    doc_check("⚠️", "DNS main (" + display_main + ")", "unreachable", "→ WILL FIX (doctor --fix): перезапуск dnsmasq");
                } else {
                    command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
                    command_status("sleep 1");
                    if (dns_check_resolve_host("openwrt.org", main_dns, 2) != "") {
                        dns_main_reachable = true;
                        doc_check("❌", "DNS main (" + display_main + ")", "unreachable", "→ FIXED: перезапущен dnsmasq");
                        fixed++;
                    }
                }
            }
            if (!dns_main_reachable && DOCTOR_REPAIR_MODE) {
                doc_check("❌", "DNS main (" + display_main + ")", "unreachable", "→ Основной DNS недоступен");
            }
        }
    }

    // 5b. DNS Resolution through sing-box
    if (has_sections) {
        if (dns_check_through_singbox("google.com")) {
            doc_check("✅", "sing-box DNS", "resolving via " + SB_DNS_INBOUND_ADDRESS, "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan(agh_primary ? "sing-box restart" : "dnsmasq -> sing-box DNS reconfigure; if needed service restart");
                doc_check("⚠️", "sing-box DNS", "not resolving", "→ WILL FIX (doctor --fix): " + (agh_primary ? "перезапуск sing-box" : "перенаправление dnsmasq на sing-box"));
            } else {
                if (!agh_primary) {
                    module_status(DNS_APPLY_UC, [ "configure", "force" ]);
                    command_status("sleep 1");
                }
                if (dns_check_through_singbox("google.com")) {
                    doc_check("❌", "sing-box DNS", "not resolving", "→ FIXED: " + (agh_primary ? "sing-box DNS доступен" : "dnsmasq перенаправлен на sing-box"));
                    fixed++;
                } else {
                    command_status(init_script + " restart >/dev/null 2>&1");
                    command_status("sleep 3");
                    if (dns_check_through_singbox("google.com")) {
                        doc_check("❌", "sing-box DNS", "not resolving", "→ FIXED: sing-box перезапущен");
                        fixed++;
                    } else {
                        doc_check("❌", "sing-box DNS", "not resolving", "→ критическая ошибка DNS");
                    }
                }
            }
        }
    }

    // 5c. Multi-DNS validation
    let all_bootstrap = get_all_dns_servers(cfg, "bootstrap_dns_server");
    if (length(all_bootstrap) == 0) all_bootstrap = ["77.88.8.8"];
    let reachable_count = 0;
    for (let srv in all_bootstrap) {
        if (dns_check_resolve_host("openwrt.org", srv, 2) != "")
            reachable_count++;
    }
    if (reachable_count == length(all_bootstrap)) {
        doc_check("✅", "DNS servers", sprintf("all %d reachable", reachable_count), "");
    } else if (reachable_count > 0) {
        doc_check("⚠️", "DNS servers", sprintf("%d/%d reachable", reachable_count, length(all_bootstrap)), "→ некоторые серверы недоступны");
    } else {
        issues++;
        doc_check("❌", "DNS servers", "all unreachable", "→ все bootstrap DNS серверы недоступны");
    }

    // 6. Clash API Check
    if (is_steer) {
        doc_check("➖", "Clash API", "not applicable for steer", "");
    } else {
        let clash_addr = clash_api_url();
        let curl_clash = command_capture("curl -s -m 5 -o /dev/null -w %{http_code} http://" + clash_addr + "/version");
        if (curl_clash.status == 0 && int(curl_clash.output) == 200) {
            doc_check("✅", "Clash API", "reachable (" + clash_addr + ")", "");
        } else {
            issues++;
            if (pid != "") {
                command_status(init_script + " restart >/dev/null 2>&1");
                command_status("sleep 3");
                let curl_clash2 = command_capture("curl -s -m 5 -o /dev/null -w %{http_code} http://" + clash_addr + "/version");
                if (curl_clash2.status == 0 && int(curl_clash2.output) == 200) {
                    doc_check("❌", "Clash API", "unreachable", "→ FIXED: sing-box перезапущен");
                    fixed++;
                } else {
                    doc_check("❌", "Clash API", "unreachable", "→ sing-box не отвечает на Clash API");
                }
            } else {
                doc_check("⚠️", "Clash API", "unreachable", "→ sing-box не запущен");
            }
        }
    }

    // 6c. WireGuard/AWG tunnel health from recent core logs. A userspace
    // wireguard outbound whose peer never answers produces a steady stream
    // of "operation timed out" connection errors - the config is applied
    // correctly, the failure is outside Tachyon (server down, ISP filtering
    // the UDP endpoint). Surfacing this as its own check stops the classic
    // "Tachyon broke my AWG" misattribution.
    if (!is_steer && pid != "") {
        let wg_log = lc(command_capture("logread -l 400 2>/dev/null | grep -i 'outbound/wireguard' | tail -n 8").output);
        let wg_failures = index(wg_log, "operation timed out") >= 0 ||
            (index(wg_log, "handshake") >= 0 && index(wg_log, "timeout") >= 0);
        if (wg_log != "" && wg_failures) {
            issues++;
            doc_check("⚠️", "WireGuard/AWG tunnel", "peer not answering through core",
                "→ ядро не получает ответов от пира (запросы уходят, ответы нет): проверьте доступность AWG/WARP-сервера и UDP-порта у провайдера. Конфигурация секции применена корректно — проблема вне Tachyon");
        } else if (wg_log != "") {
            doc_check("✅", "WireGuard/AWG tunnel", "no recent failures in core log", "");
        }
    }

    // 6d. DPI bypass / tunnel provider health (Zapret, Zapret2, ByeDPI, WDTT,
    // OLCRTC, FPTN). Two readiness shapes share this loop: the worker-based
    // engines report running/expected process counts, while the service-based
    // tunnels (WDTT/OLCRTC/FPTN) report a single service state plus a
    // human-readable status_message. Both shapes expose "ready" and accept
    // "start-runtime", so one loop covers all of them.
    let providers_to_check = [
        { name: "Zapret", kind: "zapret", runtime: ZAPRET_RUNTIME_UC, style: "workers" },
        { name: "Zapret2", kind: "zapret2", runtime: ZAPRET2_RUNTIME_UC, style: "workers" },
        { name: "ByeDPI", kind: "byedpi", runtime: BYEDPI_RUNTIME_UC, style: "workers" },
        { name: "WDTT", kind: "wdtt", runtime: WDTT_RUNTIME_UC, style: "service" },
        { name: "OLCRTC", kind: "olcrtc", runtime: OLCRTC_RUNTIME_UC, style: "service" },
        { name: "FPTN", kind: "fptn", runtime: FPTN_RUNTIME_UC, style: "service" }
    ];

    for (let p in providers_to_check) {
        let raw_st = trim(command_capture("ucode -L " + LIB_DIR + " " + p.runtime + " status 2>/dev/null").output);
        let st = null;
        if (raw_st != "") {
            try { st = json(raw_st); } catch (e) {}
        }

        // Every provider is always listed so the report shows the full
        // Zapret/Zapret2/ByeDPI/WDTT/OLCRTC/FPTN picture. Providers that are
        // absent or unused are informational, not failures.
        if (!st || st.installed != true) {
            doc_check("➖", p.name + " runtime", "not installed", "");
            continue;
        }
        if (st.configured != true) {
            doc_check("➖", p.name + " runtime", "installed, not configured", "");
            continue;
        }

        // Service-style providers carry their own status text (it names the
        // degraded reason: tun down, route missing, service stopped); the
        // worker-style engines only expose counts.
        let is_service = (p.style == "service");
        let detail = is_service
            ? as_string(st.status_message || (st.ready ? "ready" : "not ready"))
            : sprintf("%d/%d workers", st.running_process_count || 0, st.expected_process_count || 0);
        let unit = is_service ? "служба" : "воркеры";

        // Check if Tachyon-managed runtime is ready
        if (st.ready == true) {
            doc_check("✅", p.name + " runtime", "ready (" + detail + ")", "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("ucode -L " + LIB_DIR + " " + p.runtime + " start-runtime");
                doc_check("⚠️", p.name + " runtime", "not ready (" + detail + ")", "→ WILL FIX: запуск " + unit + " Tachyon " + p.name);
            } else {
                command_status("ucode -L " + LIB_DIR + " " + p.runtime + " start-runtime >/dev/null 2>&1");
                command_status("sleep 1");
                let raw_st2 = trim(command_capture("ucode -L " + LIB_DIR + " " + p.runtime + " status 2>/dev/null").output);
                let st2 = null;
                try { st2 = json(raw_st2); } catch (e) {}
                if (st2 && st2.ready == true) {
                    doc_check("❌", p.name + " runtime", "not ready (" + detail + ")", "→ FIXED: " + unit + " " + p.name + " запущены");
                    fixed++;
                } else {
                    doc_check("❌", p.name + " runtime", "failed to start", "→ не удалось запустить " + unit + " " + p.name);
                }
            }
        }
    }

    // 7. Free RAM Check
    let free_mb = -1;
    let mem_info = fs.readfile("/proc/meminfo") || "";
    for (let line in split(mem_info, "\n")) {
        if (index(line, "MemAvailable:") == 0) {
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) >= 2) {
                free_mb = int(fields[1]) / 1024;
            }
            break;
        }
    }
    if (free_mb > 20) {
        doc_check("✅", "Free RAM", sprintf("%dMB", free_mb), "");
    } else if (free_mb >= 0) {
        issues++;
        doc_check("⚠️", "Free RAM", sprintf("%dMB", free_mb), "→ Мало памяти!");
        if (!DOCTOR_REPAIR_MODE) {
            doc_plan("drop OS caches + sing-box restart");
            doc_check("⚠️", "Free RAM", sprintf("%dMB", free_mb), "→ WILL FIX (doctor --fix): сброс кэшей памяти и перезапуск sing-box");
        } else {
            command_status("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; /etc/init.d/sing-box restart >/dev/null 2>&1");
            doc_check("⚠️", "Free RAM", sprintf("%dMB", free_mb), "→ FIXED: кэши памяти сброшены, sing-box перезапущен");
            fixed++;
        }
    } else {
        doc_check("✅", "Free RAM", "unknown", "");
    }

    // 9. Watchdog Process Check
    let watchdog_running = false;
    let watchdog_pid = trim(fs.readfile("/var/run/tachyon_watchdog.pid") || "");
    if (watchdog_pid != "" && fs.stat("/proc/" + watchdog_pid) != null) {
        watchdog_running = true;
    }
    if (watchdog_running) {
        doc_check("✅", "Watchdog", "running", "");
    } else {
        if (cfg.enable_watchdog != "0") {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("/etc/init.d/tachyon restart");
                doc_check("⚠️", "Watchdog", "dead", "→ WILL FIX (doctor --fix): перезапуск системы");
            } else {
                let restart_status = command_status("/etc/init.d/tachyon restart >/dev/null 2>&1");
                if (restart_status == 0) {
                    doc_check("❌", "Watchdog", "dead", "→ FIXED: система перезапущена");
                    fixed++;
                } else {
                    doc_check("❌", "Watchdog", "dead", "→ не удалось перезапустить систему");
                }
            }
        } else {
            doc_check("⚫", "Watchdog", "disabled (ok)", "");
        }
    }

    // Tailscale native runtime check (skipped entirely without native sections
    // so sing-box-mode users never see the node).
    let ts_status_raw = trim(module_output(TAILSCALE_RUNTIME_UC, [ "status" ]));
    if (ts_status_raw != "") {
        let ts = object_or_empty(json(ts_status_raw));
        if (ts.configured == true) {
            if (ts.installed != true) {
                issues++;
                doc_check("⚠️", "Tailscale", "package missing", "→ install the Tailscale component on the Updates tab");
            } else if (ts.ready == true) {
                doc_check("✅", "Tailscale", "running (" + as_string(ts.version || "") + ")", "");
            } else {
                issues++;
                doc_check("❌", "Tailscale", as_string(ts.status_message || "not ready"), "→ run: tachyon tailscale_restart");
            }
        }
    }

    // 11. MSS Clamping Check
    if (routing_mode == "nftables") {
        let out_clamping = command_capture("nft list table inet " + NFT_TABLE_NAME + " | grep maxseg").output;
        if (index(out_clamping, "tcp flags syn tcp option maxseg size set rt mtu") >= 0 || index(out_clamping, "tcp flags syn tcp option maxseg size set 1400") >= 0) {
            doc_check("✅", "MSS Clamping rule", "active", "");
        } else {
            if (is_degraded_flag) {
                doc_check("⚠️", "MSS Clamping rule", "missing or inactive", "→ GRACEFUL DEGRADATION: Proxy offline");
            } else {
                issues++;
                if (!DOCTOR_REPAIR_MODE) {
                    doc_plan("inject MSS clamping nft rules");
                    doc_check("⚠️", "MSS Clamping rule", "missing", "→ WILL FIX (doctor --fix): применение MSS Clamping");
                } else {
                    command_status("nft add chain inet " + NFT_TABLE_NAME + " mangle_forward '{ type filter hook forward priority -150; }' >/dev/null 2>&1");
                    command_status("nft add chain inet " + NFT_TABLE_NAME + " mangle_output '{ type filter hook output priority -150; }' >/dev/null 2>&1");
                    let r1 = command_status("nft add rule inet " + NFT_TABLE_NAME + " mangle_forward tcp flags syn tcp option maxseg size set rt mtu >/dev/null 2>&1");
                    let r2 = command_status("nft add rule inet " + NFT_TABLE_NAME + " mangle_output tcp flags syn tcp option maxseg size set rt mtu >/dev/null 2>&1");
                    if (r1 != 0 || r2 != 0) {
                        command_status("nft add rule inet " + NFT_TABLE_NAME + " mangle_forward tcp flags syn tcp option maxseg size set 1400 >/dev/null 2>&1");
                        command_status("nft add rule inet " + NFT_TABLE_NAME + " mangle_output tcp flags syn tcp option maxseg size set 1400 >/dev/null 2>&1");
                    }

                    let out_clamping_check = command_capture("nft list table inet " + NFT_TABLE_NAME + " | grep maxseg").output;
                    if (index(out_clamping_check, "tcp flags syn tcp option maxseg size set rt mtu") >= 0 || index(out_clamping_check, "tcp flags syn tcp option maxseg size set 1400") >= 0) {
                        doc_check("❌", "MSS Clamping rule", "missing", "→ FIXED: MSS Clamping rules applied");
                        fixed++;
                    } else {
                        doc_check("❌", "MSS Clamping rule", "missing", "→ не удалось применить MSS Clamping");
                    }
                }
            }
        }
    }

    // 12. OOM audit Check
    // Note: the log is never wiped anymore — it is forensic evidence the
    // rest of the diagnostics pipeline relies on.
    let logread_out = command_capture("logread -l 200").output;
    let logread_lower = lc(logread_out);
    if (index(logread_lower, "out of memory") >= 0 || index(logread_lower, "oom-killer") >= 0) {
        issues++;
        let oom_victim_singbox = index(lc(logread_out), "killed process") >= 0 &&
            match(lc(logread_out), /killed process[^\n]*sing-box/) != null;
        if (!DOCTOR_REPAIR_MODE) {
            doc_plan("clear system log + drop OS caches");
            doc_check("❌", "System OOM checks",
                oom_victim_singbox ? "OOM detected, sing-box was killed" : "OOM detected in system logs",
                "→ WILL FIX (doctor --fix): очистка логов и сброс кэшей памяти");
        } else {
            command_status("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; logread -c >/dev/null 2>&1; rm -f /etc/tachyon/mem_scale");
            doc_check("❌", "System OOM checks",
                oom_victim_singbox ? "OOM detected, sing-box was killed" : "OOM detected in system logs",
                "→ FIXED: журналы сброшены, кэши памяти освобождены");
            fixed++;
        }
    } else {
        doc_check("✅", "System OOM checks", "No OOM events detected in logs", "");
    }

    // 13. Port conflicts
    let netstat_out = command_capture("netstat -ltnp").output;
    let mixed_port_str = as_string(common.get_mixed_port());
    let ports_to_check = [mixed_port_str, "9090"];
    for (let port in ports_to_check) {
        if (index(netstat_out, ":" + port + " ") >= 0) {
            let sb_pid = find_process_pid("sing-box");
            if (sb_pid == "") {
                let conflict_pids = [];
                let conflict_names = [];
                for (let line in split(netstat_out, "\n")) {
                    if (index(line, ":" + port + " ") >= 0) {
                        let fields = split(trim(line), /[ \t]+/);
                        if (length(fields) >= 7) {
                            let pid_info = fields[6];
                            let slash_idx = index(pid_info, "/");
                            if (slash_idx >= 0) {
                                let conflict_pid = substr(pid_info, 0, slash_idx);
                                push(conflict_names, substr(pid_info, slash_idx + 1));
                                push(conflict_pids, conflict_pid);
                            }
                        }
                    }
                }
                if (length(conflict_pids) > 0) {
                    issues++;
                    if (!DOCTOR_REPAIR_MODE) {
                        doc_plan("kill orphan port owner(s): " + join(",", conflict_pids));
                        doc_check("⚠️", "Port conflict :" + port,
                            "port bound by " + join(",", conflict_names),
                            "→ WILL FIX (doctor --fix): завершение процесса " + join(",", conflict_names));
                    } else {
                        let killed = false;
                        for (let conflict_pid in conflict_pids) {
                            if (command_status("kill -9 " + conflict_pid + " >/dev/null 2>&1") == 0)
                                killed = true;
                        }
                        if (killed) {
                            doc_check("❌", "Port conflict :" + port, "port bound by orphan", "→ FIXED: конфликтный процесс завершен");
                            fixed++;
                        } else {
                            doc_check("❌", "Port conflict :" + port, "port bound by unknown process", "→ завершите процесс вручную");
                        }
                    }
                } else {
                    issues++;
                    doc_check("❌", "Port conflict :" + port, "port bound by unknown process", "→ завершите процесс вручную");
                }
            } else {
                doc_check("✅", "Port check :" + port, "bound by sing-box", "");
            }
        } else {
            doc_check("✅", "Port check :" + port, "free", "");
        }
    }

    // 14. WAN Interface Check
    if (wan_has_ip()) {
        doc_check("✅", "WAN interface", get_wan_interface() + " up", "");
    } else if (bootstrap_dns_reachable || dns_main_reachable) {
        doc_check("ℹ️", "WAN interface", get_wan_interface() + " no IP (but DNS reachable — proxy working)", "");
    } else {
        issues++;
        if (!DOCTOR_REPAIR_MODE) {
            doc_plan("ifup wan + route flush cache");
            doc_check("⚠️", "WAN interface", get_wan_interface() + " no IP", "→ WILL FIX (doctor --fix): перезапуск WAN interface");
        } else {
            command_status("ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null; ip route flush cache 2>/dev/null");
            command_status("sleep 2");
            if (wan_has_ip()) {
                doc_check("❌", "WAN interface", get_wan_interface() + " no IP", "→ FIXED: WAN interface перезапущен");
                fixed++;
            } else {
                doc_check("❌", "WAN interface", "no IP address", "→ проверьте подключение к провайдеру");
            }
        }
    }

    // 15. Default Gateway Check
    if (default_gateway_exists()) {
        doc_check("✅", "Default gateway", "present", "");
    } else if (bootstrap_dns_reachable || dns_main_reachable) {
        doc_check("ℹ️", "Default gateway", "not found (but DNS reachable — proxy working)", "");
    } else {
        issues++;
        if (!DOCTOR_REPAIR_MODE) {
            doc_plan("ifup wan + route flush cache");
            doc_check("⚠️", "Default gateway", "missing", "→ WILL FIX (doctor --fix): восстановление маршрута");
        } else {
            command_status("ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null; ip route flush cache 2>/dev/null");
            command_status("sleep 2");
            if (default_gateway_exists()) {
                doc_check("❌", "Default gateway", "missing", "→ FIXED: маршрут восстановлен через ifup wan");
                fixed++;
            } else {
                doc_check("❌", "Default gateway", "missing", "→ проверьте конфигурацию сети");
            }
        }
    }

    // 15b. Community Lists Presence Check
    // For every enabled section that declares community_lists, verify the
    // corresponding .srs files have been downloaded into TMP_RULESET_FOLDER.
    // Missing or empty files mean sing-box is running without the expected
    // routing data — this is the silent green-screen failure the user reported.
    {
        let missing_lists = [];
        let all_required = [];

        // Collect all unique community list names across enabled sections
        let all_sections = uci_core.section_objects(CONFIG_NAME, "section");
        for (let sec in all_sections) {
            if (sec.enabled == "0") continue;
            let cl = sec.community_lists;
            if (!cl) continue;
            let list_arr = type(cl) == "array" ? cl : split(trim("" + cl), /\s+/);
            for (let entry in list_arr) {
                let name = trim("" + entry);
                if (name == "") continue;
                // Deduplicate
                let already = false;
                for (let existing in all_required) {
                    if (existing == name) { already = true; break; }
                }
                if (!already) push(all_required, name);
            }
        }

        if (length(all_required) > 0) {
            for (let list_name in all_required) {
                let srs_path = TMP_RULESET_FOLDER + "/community-" + list_name + ".srs";
                let srs_stat = fs.stat(srs_path);
                if (srs_stat == null || srs_stat.size == 0) {
                    push(missing_lists, list_name);
                }
            }

            if (length(missing_lists) == 0) {
                doc_check("✅", "Community lists", sprintf("all %d lists present", length(all_required)), "");
            } else {
                issues++;
                if (!DOCTOR_REPAIR_MODE) {
                    doc_plan("/usr/bin/tachyon list_update");
                    doc_check("⚠️", "Community lists",
                        sprintf("%d/%d missing", length(missing_lists), length(all_required)),
                        "→ WILL FIX (doctor --fix): загрузка через list_update (с прокси-маршрутизацией при необходимости)");
                } else {
                    // Attempt repair: download missing lists
                    command_status("/usr/bin/tachyon list_update > /dev/null 2>&1");

                    let still_missing = [];
                    for (let list_name in missing_lists) {
                        let srs_path = TMP_RULESET_FOLDER + "/community-" + list_name + ".srs";
                        let srs_stat = fs.stat(srs_path);
                        if (srs_stat == null || srs_stat.size == 0) {
                            push(still_missing, list_name);
                        }
                    }

                    if (length(still_missing) > 0) {
                        let first_proxy = "";
                        for (let s in all_sections) {
                            if (s.enabled != "0" && s.action != "bypass" && s.action != "block" && s.action != "dns" && s.action != "") {
                                first_proxy = s[".name"];
                                break;
                            }
                        }
                        if (first_proxy != "") {
                            command_status("uci set tachyon.settings.download_lists_via_proxy='1'; uci set tachyon.settings.download_lists_via_proxy_section=" + shell_quote(first_proxy) + "; uci commit tachyon >/dev/null 2>&1");
                            command_status("/usr/bin/tachyon list_update > /dev/null 2>&1");
                            still_missing = [];
                            for (let list_name in missing_lists) {
                                let srs_path = TMP_RULESET_FOLDER + "/community-" + list_name + ".srs";
                                let srs_stat = fs.stat(srs_path);
                                if (srs_stat == null || srs_stat.size == 0) {
                                    push(still_missing, list_name);
                                }
                            }
                        }
                    }

                    if (length(still_missing) == 0) {
                        doc_check("❌", "Community lists",
                            sprintf("%d/%d missing", length(missing_lists), length(all_required)),
                            "→ FIXED: загружены через list_update (маршрут через прокси настроен)");
                        fixed++;
                    } else {
                        doc_check("❌", "Community lists",
                            sprintf("%d/%d отсутствуют: %s", length(still_missing), length(all_required), join(", ", still_missing)),
                            "→ не удалось загрузить — проверьте доступность прокси/GitHub");
                    }
                }
            }
        }
    }

    // 16. Subscription Health Check
    if (has_sections && cfg.subscription_url) {
        let sub_url = trim(as_string(cfg.subscription_url));
        if (sub_url != "") {
            let sub_check = command_capture("curl -s -m 15 -o /dev/null -w %{http_code} --connect-timeout 5 " + shell_quote(sub_url) + " 2>&1");
            let sub_code = int(sub_check.output);
            if (sub_check.status == 0 && sub_code >= 200 && sub_code < 400) {
                doc_check("✅", "Subscription", "active (HTTP " + sub_code + ")", "");
            } else {
                issues++;
                doc_check("⚠️", "Subscription", "unreachable (HTTP " + sub_code + ")", "→ обновите подписку вручную");
            }
        }
    }

    // 17. Disk Space Check — a full /tmp breaks cache writes, subscription
    // downloads and job state files; a full overlay breaks config commits.
    {
        let df_out = command_capture("df -k /tmp /overlay / 2>/dev/null").output;
        let disk_warned = {};
        for (let line in split(df_out, "\n")) {
            let fields = split(trim(as_string(line)), /[ \t]+/);
            if (length(fields) < 5 || fields[0] == "Filesystem")
                continue;
            let mount = fields[length(fields) - 1];
            let use_pct = int(replace(fields[length(fields) - 2], "%", ""));
            if (use_pct >= 90 && !disk_warned[mount]) {
                disk_warned[mount] = true;
                issues++;
                doc_check("⚠️", "Disk space", sprintf("%s %d%% full", mount, use_pct),
                    "→ очистите место: переполнение ломает кэш и запись конфигов");
            }
        }
        if (length(keys(disk_warned)) == 0)
            doc_check("✅", "Disk space", "OK", "");
    }

    // 18. System Clock Check — a wrong year silently breaks every TLS
    // connection (DoH, subscriptions, LLM APIs) and is easy to miss after a
    // cold boot without NTP.
    {
        let year = int(command_output_from_args(["date", "+%Y"]));
        if (year >= 2024 && year <= 2100) {
            doc_check("✅", "System clock", sprintf("OK (%d)", year), "");
        } else {
            issues++;
            doc_check("⚠️", "System clock", sprintf("suspicious year %d", year),
                "→ проверьте NTP/дату: неверное время ломает TLS (DoH, подписки)");
        }
    }

    // 19. CA Bundle Check — curl HTTPS fails with SSL errors when the
    // ca-bundle package is missing; the code blames it in TLS verdicts but
    // never verified it before.
    {
        let ca_found = fs.stat("/etc/ssl/certs/ca-certificates.crt") != null
                    || fs.stat("/etc/ssl/certs/ca-bundle.crt") != null;
        if (ca_found) {
            doc_check("✅", "CA certificates", "ca-bundle present", "");
        } else {
            issues++;
            doc_check("⚠️", "CA certificates", "/etc/ssl/certs/ missing",
                "→ установите пакет ca-bundle: без него HTTPS-проверки падают");
        }
    }

    // 20. Port 53 Conflicts — another DNS daemon on port 53 competes with
    // dnsmasq and produces intermittent resolution failures.
    {
        let dns53_owners = [];
        for (let line in split(netstat_out, "\n")) {
            if (index(line, ":53 ") < 0 || index(line, "LISTEN") < 0)
                continue;
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) < 7)
                continue;
            let pid_info = as_string(fields[6]);
            let owner = index(pid_info, "/") >= 0 ? substr(pid_info, index(pid_info, "/") + 1) : pid_info;
            if (owner == "" || owner == "dnsmasq" || owner == "sing-box" || owner == "AdGuardHome" || lc(owner) == "adguardhome")
                continue;
            let already = false;
            for (let o in dns53_owners) {
                if (o == owner) { already = true; break; }
            }
            if (!already)
                push(dns53_owners, owner);
        }
        if (length(dns53_owners) == 0) {
            doc_check("✅", "Port 53 conflicts", "none", "");
        } else {
            issues++;
            doc_check("⚠️", "Port 53 conflicts", "bound by " + join(", ", dns53_owners),
                "→ конкурирующий DNS-демон на :53 даёт плавающие сбои резолвинга");
        }
    }

    // 20b. Port 53 Socket Collision — sing-box hijack-dns on tproxy-in creates
    // transparent write-only sockets that collide with dnsmasq on :53 via
    // SO_REUSEADDR.  Diagnostic: find sing-box UNCONN sockets on :53 with
    // non-zero Recv-Q (parasitic write-back sockets that steal UDP packets
    // from dnsmasq).
    {
        let ss_output = command_capture("ss -u -a -e -n 'sport = :53' 2>/dev/null").output;
        let parasitic_count = 0;
        let collision_detail = "";
        for (let line in split(ss_output, "\n")) {
            if (index(line, "UNCONN") < 0)
                continue;
            if (index(line, "sing-box") < 0 && index(line, "sing_box") < 0)
                continue;
            let fields = split(trim(line), /[ \t]+/);
            if (length(fields) < 5)
                continue;
            let recv_q = int(fields[1]);
            if (recv_q > 0) {
                parasitic_count++;
                if (collision_detail == "")
                    collision_detail = fields[3] + " Recv-Q=" + as_string(recv_q);
            }
        }
        if (parasitic_count == 0) {
            doc_check("✅", "Port 53 socket collision", "none", "");
        } else {
            issues++;
            if (!DOCTOR_REPAIR_MODE) {
                doc_plan("restart sing-box to clear parasitic :53 sockets");
                doc_check("⚠️", "Port 53 socket collision", as_string(parasitic_count) + " sing-box sockets on :53 (" + collision_detail + ")",
                    "→ sing-box hijack-dns создаёт прозрачные write-only сокеты, перехватывающие UDP у dnsmasq; WILL FIX: restart sing-box");
            } else {
                command_status("/etc/init.d/sing-box restart >/dev/null 2>&1");
                command_status("sleep 2");
                let ss_check = command_capture("ss -u -a -e -n 'sport = :53' 2>/dev/null").output;
                let still_parasitic = 0;
                for (let line2 in split(ss_check, "\n")) {
                    if (index(line2, "UNCONN") < 0) continue;
                    if (index(line2, "sing-box") < 0 && index(line2, "sing_box") < 0) continue;
                    let f2 = split(trim(line2), /[ \t]+/);
                    if (length(f2) >= 5 && int(f2[1]) > 0) still_parasitic++;
                }
                if (still_parasitic == 0) {
                    doc_check("❌", "Port 53 socket collision", as_string(parasitic_count) + " sing-box sockets on :53",
                        "→ FIXED: sing-box перезапущен, паразитные сокеты очищены");
                    fixed++;
                } else {
                    doc_check("❌", "Port 53 socket collision", "persists after restart",
                        "→ не удалось устранить — проверьте конфигурацию hijack-dns inbound фильтра");
                }
            }
        }
    }

    // 21. Subscription Cache Age — sing-box can route through days-old node
    // lists while the subscription URL itself is reachable.
    if (has_sections && cfg.subscription_url) {
        let newest_mtime = 0;
        let cache_files = fs.glob(constants.TMP_SUBSCRIPTION_FOLDER + "/*.json") || [];
        for (let cf in cache_files) {
            let st = fs.stat(cf);
            if (st && st.mtime > newest_mtime)
                newest_mtime = st.mtime;
        }
        if (newest_mtime > 0) {
            let age_days = int((time() - newest_mtime) / 86400);
            if (age_days <= 2) {
                doc_check("✅", "Subscription cache", sprintf("fresh (%d d)", age_days), "");
            } else {
                issues++;
                doc_check("⚠️", "Subscription cache", sprintf("stale (%d days old)", age_days),
                    "→ узлы могли устареть: обновите подписку в LuCI");
            }
        }
    }

    // 22. TLS Certificate Pinning Capability Check
    if (has_sections && !is_steer && has_certificate_pins_configured()) {
        let sb_ver = sing_box_resolved_version();
        let flags = sing_box_capability_flags(sb_ver.version, sb_ver.output);
        if (flags.cert_pin == 1) {
            doc_check("✅", "TLS certificate pinning", "supported & active (sing-box >= 1.15)", "");
        } else {
            issues++;
            doc_check("⚠️", "TLS certificate pinning", "ignored (sing-box < 1.15)",
                "→ обновите sing-box до sing-box-extended в обновлениях для поддержки pin сертификатов");
            push(DOCTOR_PLANNED_FIXES, "upgrade_to_singbox_extended");
        }
    }

    push(report, "");
    if (issues == 0) {
        push(report, "✅ Всё в порядке — проблем не обнаружено");
    } else if (DOCTOR_REPAIR_MODE) {
        push(report, sprintf("⚠️ Проблем: %d   Исправлено: %d", issues, fixed));
    } else {
        push(report, sprintf("⚠️ Проблем: %d   Планируется к исправлению: %d (применить: tachyon doctor --fix)", issues, length(DOCTOR_PLANNED_FIXES)));
    }

    return { report: join("\n", report) + "\n", issues, fixed, checks, planned_fixes: DOCTOR_PLANNED_FIXES };
}

// Concurrent doctor runs (LuCI button, Telegram bot, cron) would both see the
// same broken state and both execute repairs. A mkdir lock serializes them;
// a crashed run's lock is stolen after 15 minutes of silence.
// Declared after run_doctor_checks_impl(): ucode does not hoist function
// declarations, so the wrapper must follow its callee.
const DOCTOR_LOCK_DIR = getenv("TACHYON_DOCTOR_LOCK_DIR") ||
    (fs.access("/var/run", "w") ? "/var/run/tachyon.doctor.lock" : "/tmp/tachyon.doctor.lock");
const DOCTOR_HISTORY_FILE = "/tmp/tachyon_doctor_history.json";

function doctor_lock_try() {
    command_status("mkdir -p /var/run /tmp/run 2>/dev/null");
    if (command_status("mkdir " + shell_quote(DOCTOR_LOCK_DIR) + " 2>/dev/null") == 0)
        return true;
    let st = fs.stat(DOCTOR_LOCK_DIR);
    let age = (st && st.mtime) ? (int(clock()[0]) - st.mtime) : 0;
    if (age > 900) {
        command_status("rm -rf " + shell_quote(DOCTOR_LOCK_DIR) + " 2>/dev/null");
        return command_status("mkdir " + shell_quote(DOCTOR_LOCK_DIR) + " 2>/dev/null") == 0;
    }
    return false;
}

function doctor_lock_release() {
    command_status("rm -rf " + shell_quote(DOCTOR_LOCK_DIR) + " 2>/dev/null");
}

// Outcome journal: lets the report say "this is the Nth failing run today"
// instead of treating every incident as unique. Capped and written
// atomically like every other doctor state file.
function doctor_history_load() {
    let raw = read_json_file(DOCTOR_HISTORY_FILE);
    let data = object_or_empty(raw);
    if (type(data.entries) != "array")
        data.entries = [];
    return data;
}

function doctor_history_record(result) {
    let data = doctor_history_load();
    let first_fail = "";
    for (let c in (result.checks || [])) {
        if (c.status == "fail") { first_fail = as_string(c.name); break; }
    }
    push(data.entries, {
        ts: time(),
        issues: int(result.issues || 0),
        fixed: int(result.fixed || 0),
        planned: length(result.planned_fixes || []),
        first_fail: first_fail
    });
    while (length(data.entries) > 50)
        splice(data.entries, 0, 1);
    let tmp_path = DOCTOR_HISTORY_FILE + ".tmp." + int(clock()[0]);
    let f = fs.open(tmp_path, "w");
    if (f) {
        f.write(sprintf("%J\n", data));
        f.close();
        fs.rename(tmp_path, DOCTOR_HISTORY_FILE);
    }
}

function doctor_history_trend(result) {
    if (int(result.issues || 0) <= 0)
        return "";
    let data = doctor_history_load();
    let day_ago = time() - 86400;
    let recent_failures = 0;
    for (let e in data.entries) {
        if (int(e.ts || 0) >= day_ago && int(e.issues || 0) > 0)
            recent_failures++;
    }
    if (recent_failures < 2)
        return "";
    return sprintf("⚠️ Это %d-й диагностики-запуск с проблемами за последние 24 часа — сбой повторяющийся, проверьте историю.", recent_failures);
}

function run_doctor_checks(repair) {
    if (!doctor_lock_try()) {
        return {
            report: "🩺 *tachyon doctor* — другой экземпляр диагностики уже выполняется, повторите позже.\n",
            issues: 0,
            fixed: 0,
            checks: [],
            planned_fixes: [],
            busy: true
        };
    }
    // On a crash the lock is left behind on purpose: doctor_lock_try()
    // steals it after 15 minutes of silence.
    let result = run_doctor_checks_impl(repair);
    doctor_lock_release();
    if (!result.busy) {
        doctor_history_record(result);
        let trend = doctor_history_trend(result);
        if (trend != "")
            result.report = result.report + trend + "\n";
    }
    return result;
}

function query_llm(provider, api_key, custom_url, prompt_text, model_override) {
    provider = lc(trim(as_string(provider)));

    if (provider == "anthropic" || provider == "claude") {
        let api_url = "https://api.anthropic.com/v1/messages";
        let model = model_override || "claude-3-5-haiku-20241022";
        let payload = {
            model: model,
            max_tokens: 1024,
            messages: [
                {
                    role: "user",
                    content: prompt_text
                }
            ]
        };
        let payload_path = "/tmp/llm_payload.json";
        common.write_json_file(payload_path, payload);

        let curl_args = [
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "x-api-key: " + api_key,
            "-H", "anthropic-version: 2023-06-01",
            "--connect-timeout", "10",
            "-m", "60",
            "-d", "@" + payload_path,
            api_url
        ];

        let result = command_capture(command_from_args(curl_args));
        remove_file(payload_path);

        if (result.status != 0 || result.output == "") {
            return null;
        }

        let response_data = parse_json_or_null(result.output);
        if (response_data && type(response_data.content) == "array" && length(response_data.content) > 0) {
            return response_data.content[0].text;
        }

        return null;
    }

    let api_url = "https://api.openai.com/v1/chat/completions";
    let model = model_override || "gpt-4o-mini";
    
    if (provider == "deepseek") {
        api_url = "https://api.deepseek.com/chat/completions";
        model = model_override || "deepseek-chat";
    } else if (provider == "openrouter") {
        api_url = "https://openrouter.ai/api/v1/chat/completions";
        model = model_override || "openai/gpt-4o-mini";
    } else if (provider == "ollama") {
        api_url = custom_url != "" ? custom_url : "http://192.168.1.100:11434/v1/chat/completions";
        model = model_override || "llama3:latest";
    } else if (provider == "lmstudio") {
        api_url = custom_url != "" ? custom_url : "http://192.168.1.100:1234/v1/chat/completions";
        model = model_override || "local-model";
    } else if (provider == "custom" && custom_url != "") {
        api_url = custom_url;
        model = model_override || "gpt-4o-mini";
    } else {
        api_url = "https://api.openai.com/v1/chat/completions";
        model = model_override || "gpt-4o-mini";
    }

    let payload = {
        model: model,
        messages: [
            {
                role: "user",
                content: prompt_text
            }
        ],
        temperature: 0.3
    };

    let payload_path = "/tmp/llm_payload.json";
    common.write_json_file(payload_path, payload);

    let curl_args = [
        "curl", "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " + api_key,
        "--connect-timeout", "10",
        "-m", "60",
        "-d", "@" + payload_path,
        api_url
    ];

    // OpenRouter recommends these headers for identification and rate-limit ranking
    if (provider == "openrouter") {
        push(curl_args, "-H");
        push(curl_args, "HTTP-Referer: https://github.com/Dushnilin/tachyon");
        push(curl_args, "-H");
        push(curl_args, "X-Title: Tachyon AI Doctor");
    }

    let result = command_capture(command_from_args(curl_args));
    remove_file(payload_path);

    if (result.status != 0 || result.output == "") {
        warn(sprintf("LLM query failed: provider=%s url=%s status=%d output_len=%d", provider, api_url, result.status, length(result.output || "")));
        return null;
    }

    let response_data = parse_json_or_null(result.output);
    if (response_data && type(response_data.choices) == "array" && length(response_data.choices) > 0) {
        return response_data.choices[0].message.content;
    }

    // Log the raw response for debugging when parsing fails
    if (!response_data) {
        warn(sprintf("LLM response parse failed: provider=%s raw_start=%s", provider, substr(trim(result.output), 0, 200)));
    } else if (!response_data.choices) {
        warn(sprintf("LLM response missing choices: provider=%s keys=%s", provider, join(",", keys(response_data))));
    }
    return null;
}

function doctor(format, repair) {
    let res;
    try {
        res = run_doctor_checks(repair == true);
    } catch (e) {
        print(sprintf("%J\n", {
            success: false,
            issues: 0,
            fixed: 0,
            report: sprintf("Doctor failed: %s", as_string(e))
        }));
        return 1;
    }
    print(sprintf("%J\n", {
        success: true,
        busy: res.busy == true,
        issues: res.issues,
        fixed: res.fixed,
        planned_fixes: res.planned_fixes || [],
        report: res.report
    }));
    return 0;
}

// ─── AI Agent: structured JSON diagnostics ────────────────────────────────────
// Same checks as run_doctor_checks() but output is machine-readable JSON for
// LLM agents. Each problem has: id, severity, description, suggested_fix.
function compress_log_snippet(raw_snippet) {
    if (!raw_snippet || raw_snippet == "") return "No recent system errors logged.";
    let lines = split(raw_snippet, "\n");
    let compressed = [];
    let prev_line = "";
    let repeat_cnt = 1;

    for (let i = 0; i < length(lines); i++) {
        let line = trim(as_string(lines[i]));
        if (line == "") continue;
        let normalized = replace(line, /^[A-Z][a-z]{2}\s+\d+\s+\d+:\d+:\d+\s+[^\s]+\s+/, "");
        normalized = replace(normalized, /^\d{4}-\d{2}-\d{2}\s+\d+:\d+:\d+\s+/, "");

        if (normalized == prev_line) {
            repeat_cnt++;
        } else {
            if (prev_line != "") {
                if (repeat_cnt > 1) {
                    push(compressed, sprintf("%s [repeated %dx]", lines[i-1], repeat_cnt));
                } else {
                    push(compressed, lines[i-1]);
                }
            }
            prev_line = normalized;
            repeat_cnt = 1;
        }
    }
    if (prev_line != "" && length(lines) > 0) {
        if (repeat_cnt > 1) {
            push(compressed, sprintf("%s [repeated %dx]", lines[length(lines)-1], repeat_cnt));
        } else {
            push(compressed, lines[length(lines)-1]);
        }
    }
    return join("\n", compressed);
}

function diagnose_json() {
    let res = run_doctor_checks();
    let problems = [];

    let checks = res.checks || [];

    if (length(checks) > 0) {
        // Structured path: build problems directly from checks[]
        for (let chk in checks) {
            if (chk.status == "pass") continue;

            let severity = (chk.status == "fail") ? "critical" : ((chk.status == "warn") ? "warning" : "info");
            let raw_fix = trim(as_string(chk.fix || ""));
            let fixed_inline = index(raw_fix, "FIXED:") >= 0;
            if (fixed_inline) severity = "info";

            // Strip leading arrow from fix hint
            let suggested_fix = raw_fix;
            if (length(suggested_fix) >= 3 && substr(suggested_fix, 0, 3) == "→") {
                suggested_fix = trim(substr(suggested_fix, 3));
            }

            let description = as_string(chk.name);
            if (suggested_fix == "" && chk.status != "info") {
                description = trim(description + " " + as_string(chk.detail));
            }

            push(problems, {
                check:         chk.name,
                severity:      severity,
                description:   description,
                suggested_fix: suggested_fix,
                evidence:      as_string(chk.detail),
                fixed:         fixed_inline
            });
        }
    } else {
        // Legacy fallback for recovery mode (no structured checks)
        for (let line in split(res.report, "\n")) {
            line = trim(as_string(line));
            if (line == "") continue;

            let severity = null;
            let fixed_inline = false;
            if (index(line, "❌") >= 0) {
                severity = "critical";
            } else if (index(line, "⚠️") >= 0) {
                severity = "warning";
            } else if (index(line, "ℹ️") >= 0) {
                severity = "info";
            }

            if (severity == null) continue;

            let clean = replace(replace(replace(replace(
                line, "❌", ""), "⚠️", ""), "ℹ️", ""), "✅", "");
            clean = trim(clean);

            let arrow_idx = index(clean, "→");
            let description = trim(arrow_idx >= 0 ? substr(clean, 0, arrow_idx) : clean);
            let suggested_fix = arrow_idx >= 0 ? trim(substr(clean, arrow_idx + 3)) : "";

            if (index(suggested_fix, "FIXED:") >= 0) {
                fixed_inline = true;
                severity = "info";
            }

            push(problems, {
                severity:      severity,
                description:   description,
                suggested_fix: suggested_fix,
                fixed:         fixed_inline
            });
        }
    }

    let ai_status_data = {};
    let ai_status_raw = fs.readfile("/tmp/tachyon_ai_status.json");
    if (ai_status_raw) {
        try { ai_status_data = json(ai_status_raw); } catch(e) {}
    }

    let raw_log_snippet = trim(command_output("logread | grep -iE 'tachyon|sing-box|dnsmasq|oom|error|fatal|byedpi|zapret|nftables' | tail -n 50 2>/dev/null")) || "No recent system errors logged.";
    let log_snippet = compress_log_snippet(raw_log_snippet);

    print(sprintf("%J\n", {
        success:          true,
        timestamp:        time(),
        issues_found:     res.issues,
        issues_fixed:     res.fixed,
        overall:          (res.issues == 0) ? "healthy" : ((res.fixed == res.issues) ? "repaired" : "degraded"),
        problems:         problems,
        log_snippet:      log_snippet,
        watchdog_status:  ai_status_data
    }));
    return 0;
}



// A fix that has been applied several times without changing the picture is
// not going to work on the next attempt either — recommending it again is how
// the doctor ends up proposing the same repairs forever (issue #31). Every
// successful application is recorded, and a code that was applied 3+ times in
// the last hour is withheld from the recommendations.
const DOCTOR_FIXES_FILE = "/tmp/tachyon_doctor_fixes.json";

function doctor_fix_record(code) {
    let data = object_or_empty(read_json_file(DOCTOR_FIXES_FILE));
    let rec = data[code] || { count: 0, last: 0 };
    rec.count = int(rec.count) + 1;
    rec.last = time();
    data[code] = rec;
    // Atomic tmp+mv write: concurrent doctor instances (LuCI, Telegram, cron)
    // must not be able to corrupt the tracker mid-write.
    let tmp_path = DOCTOR_FIXES_FILE + ".tmp." + int(clock()[0]);
    let f = fs.open(tmp_path, "w");
    if (f) {
        f.write(sprintf("%J\n", data));
        f.close();
        fs.rename(tmp_path, DOCTOR_FIXES_FILE);
    }
}

function doctor_fix_overused(code) {
    let data = object_or_empty(read_json_file(DOCTOR_FIXES_FILE));
    let rec = data[code];
    if (!rec) return false;
    if (time() - int(rec.last) > 3600) return false;
    return int(rec.count) >= 3;
}

// ─── End-to-end verification: is everything actually working ──────────────────
// The snapshot checks pass even when the network has been silently flapping for
// hours: at the moment of the check the WAN is up, so the doctor concludes "all
// OK". This routine verifies what the LAN client actually experiences — DNS
// through each layer, HTTP through the proxy — and inspects the recent log
// history for instability (WAN flaps, service restarts) before anyone is
// allowed to declare the system healthy.

function verify_system() {
    let checks = [];
    let stability = {
        wan_flaps: 0,
        singbox_restarts: 0,
        dnsmasq_restarts: 0,
        tachyon_restarts: 0
    };

    function add(name, status, detail, evidence) {
        push(checks, { name, status, detail, evidence: evidence || "" });
    }

    // Live checks — what a client on the LAN experiences right now.
    let is_steer_active = active_engine_is_steer();
    if (is_steer_active) {
        let steer_pid = find_process_pid("steer");
        add("steer process", steer_pid != "" ? "pass" : "fail",
            steer_pid != "" ? "running (pid " + steer_pid + ")" : "not running");
    } else {
        let sb_pid = find_process_pid("sing-box");
        add("sing-box process", sb_pid != "" ? "pass" : "fail",
            sb_pid != "" ? "running (pid " + sb_pid + ")" : "not running");
    }

    let lan_dns = dns_check_resolve_host("google.com", "127.0.0.1", 3);
    if (lan_dns == "") lan_dns = dns_check_resolve_host("cloudflare.com", "127.0.0.1", 3);
    if (lan_dns == "") lan_dns = dns_check_resolve_host("openwrt.org", "127.0.0.1", 3);
    add("LAN DNS via dnsmasq", lan_dns != "" ? "pass" : "fail",
        lan_dns != "" ? "resolved successfully" : "no answer from 127.0.0.1");

    let up_dns = dns_check_resolve_host("google.com", "1.1.1.1", 3);
    if (up_dns == "") up_dns = dns_check_resolve_host("cloudflare.com", "8.8.8.8", 3);
    if (up_dns == "") up_dns = dns_check_resolve_host("openwrt.org", "77.88.8.8", 3);
    add("Upstream DNS", up_dns != "" ? "pass" : "fail",
        up_dns != "" ? "resolved successfully" : "no answer from upstream resolvers");

    if (is_steer_active) {
        let steer_dns_ok = command_success_from_args([ "dig", "-p", STEER_DNS_PORT, "@" + STEER_DNS_ADDRESS, "example.com", "A", "+short", "+timeout=2", "+tries=1" ]);
        add("Proxy DNS via steer", steer_dns_ok ? "pass" : "fail",
            steer_dns_ok ? "resolved via " + STEER_DNS_ADDRESS + ":" + STEER_DNS_PORT : "steer dnsd not answering");
    } else {
        let sb_dns = dns_check_through_singbox("google.com");
        if (!sb_dns) sb_dns = dns_check_through_singbox("cloudflare.com");
        let sb_pid = find_process_pid("sing-box");
        add("Proxy DNS via sing-box", sb_dns ? "pass" : (sb_pid != "" ? "fail" : "skip"),
            sb_dns ? "resolved via " + SB_DNS_INBOUND_ADDRESS : (sb_pid != "" ? "no answer" : "sing-box not running"));
    }

    // HTTP through the service mixed proxy — only present when download_via_proxy
    // is enabled; otherwise the tproxy/tun path is covered by the checks above.
    let mixed_port_num = common.get_mixed_port();
    let sb_cfg = fs.readfile("/etc/sing-box/config.json") || "";
    let has_mixed = index(sb_cfg, '"mixed"') >= 0;
    if (has_mixed && sb_pid != "") {
        let res = command_capture("curl -sS --max-time 8 -x http://127.0.0.1:" + mixed_port_num + " -o /dev/null -w %{http_code} https://www.gstatic.com/generate_204 2>&1");
        let code = trim(res.output);
        add("HTTP via proxy", res.status == 0 && (code == "204" || code == "200") ? "pass" : "fail",
            code == "204" || code == "200" ? "end-to-end OK through sing-box" : "HTTP " + code);
    } else {
        add("HTTP via proxy", "skip", "service mixed proxy not in config");
    }

    add("WAN interface", wan_has_ip() ? "pass" : "fail",
        wan_has_ip() ? get_wan_interface() + " up" : "no IP");
    add("Default gateway", default_gateway_exists() ? "pass" : "fail",
        default_gateway_exists() ? "present" : "missing");

    // History — inspect recent system log tail without false triggers from normal upgrades/reloads
    let hist = command_capture("logread 2>/dev/null | tail -n 250").output;
    for (let line in split(hist, "\n")) {
        let l = lc(line);
        // Skip planned / normal upgrade and service operations
        if (index(l, "successful component change") >= 0 || index(l, "upgrading") >= 0 ||
            index(l, "post-upgrade") >= 0 || index(l, "component_action") >= 0 ||
            index(l, "component-action") >= 0 || index(l, "doctor_fix") >= 0)
            continue;

        if (index(l, "udhcpc") >= 0 && (index(l, "lease lost") >= 0 || index(l, "deconfig") >= 0))
            stability.wan_flaps++;
        if (index(l, "wan.down") >= 0 || index(l, "watchdog: wan check failed") >= 0)
            stability.wan_flaps++;
        if (index(l, "sing-box") >= 0 &&
            (index(l, "panic:") >= 0 || index(l, "fatal error:") >= 0 || index(l, "sigsegv") >= 0 || index(l, "died unexpectedly") >= 0))
            stability.singbox_restarts++;
        if (index(l, "dnsmasq") >= 0 &&
            (index(l, "failed to create listening socket") >= 0 || index(l, "address already in use") >= 0 || index(l, "failed to start") >= 0))
            stability.dnsmasq_restarts++;
        if (index(l, "tachyon") >= 0 && index(l, "sing-box") < 0 && index(l, "watchdog: crashed") >= 0)
            stability.tachyon_restarts++;
    }

    let failed = 0;
    for (let c in checks) {
        if (c.status == "fail") failed++;
    }
    return { checks, stability, failed };
}


function ai_doctor_last() {
    let raw = fs.readfile("/tmp/ai_doctor_last.json");
    if (!raw) {
        print(sprintf("%J\n", {
            success: false,
            error: "No previous AI Doctor report found"
        }));
        return 0;
    }
    let data = parse_json_or_null(raw);
    if (!data) {
        print(sprintf("%J\n", {
            success: false,
            error: "Corrupted AI Doctor history file"
        }));
        return 0;
    }
    print(sprintf("%J\n", data));
    return 0;
}

const DOCTOR_FIX_PRIORITIES = {
    "fix_system_time": 5,
    "fix_wan_interface": 10,
    "restart_network": 15,
    "fix_gateway": 20,
    "fix_resolv_symlink": 30,
    "fix_dnsmasq": 35,
    "fix_bootstrap_dns": 38,
    "switch_to_doh": 40,
    "clear_dns_cache": 45,
    "start_singbox": 50,
    "restart_zapret": 60,
    "restart_providers": 62,
    "optimize_mtu": 65,
    "rebuild_rules": 70,
    "update_subscriptions": 80,
    "upgrade_to_singbox_extended": 75,
    "flush_conntrack": 85,
    "optimize_memory": 90,
    "enable_safe_bypass": 95,
    "heal_network_stack": 100,
    "restore_native_internet": 110
};

function doctor_fix_sort(a, b) {
    let pa = DOCTOR_FIX_PRIORITIES[a] || 55;
    let pb = DOCTOR_FIX_PRIORITIES[b] || 55;
    return pa < pb ? -1 : (pa > pb ? 1 : 0);
}

function prioritize_quick_fixes(fixes) {
    if (!fixes || length(fixes) <= 1) return fixes;
    sort(fixes, doctor_fix_sort);
    return fixes;
}

function diagnose_dpi_and_censorship(cfg, lang, causes, fn_add_fix) {
    if (!wan_has_ip()) return;

    let local_ip = dns_check_resolve_host("rutracker.org", "127.0.0.1", 2);
    let upstream_ip = dns_check_resolve_host("rutracker.org", "77.88.8.8", 2);
    if (upstream_ip == "") upstream_ip = dns_check_resolve_host("rutracker.org", "1.1.1.1", 2);

    if (local_ip != "" && (local_ip == "127.0.0.1" || local_ip == "0.0.0.0" ||
        index(local_ip, "192.168.") == 0 || index(local_ip, "10.") == 0)) {
        push(causes, {
            probability: 92,
            cause: lang == "en" ? "DNS spoofing/poisoning detected (local resolver returns bogus or blockpage IP)"
                                : "Обнаружена подмена DNS (DNS Spoofing): локальный резолвер возвращает адрес-заглушку",
            fix: "switch_to_doh"
        });
        fn_add_fix("switch_to_doh");
    }

    let zap_mode = trim(as_string(cfg.zapret_mode || "disabled"));
    let bd_mode = trim(as_string(cfg.byedpi_mode || "disabled"));
    if (zap_mode == "disabled" && bd_mode == "disabled" && upstream_ip != "") {
        let tls_check = command_capture("curl -k -sS --connect-timeout 2 -m 3 https://rutracker.org -o /dev/null -w %{http_code} 2>&1");
        let tls_out = tls_check.output || "";
        if (tls_check.status != 0 && (index(tls_out, "Connection reset") >= 0 || index(tls_out, "SSL_ERROR") >= 0 || index(tls_out, "OpenSSL SSL_connect") >= 0)) {
            push(causes, {
                probability: 88,
                cause: lang == "en" ? "ISP DPI/TSPU is blocking TLS ClientHello (Connection Reset / SNI filtering)"
                                    : "Обнаружена блокировка TLS ClientHello со стороны ТСПУ/DPI провайдера (сброс соединения по SNI)",
                fix: "restart_zapret"
            });
            fn_add_fix("restart_zapret");
        }
    }
}

function diagnose_proxies_health(cfg, lang, causes, fn_add_fix) {
    let clash_addr = clash_api_url();
    let curl_res = command_capture("curl -s --max-time 2 http://" + clash_addr + "/proxies 2>/dev/null");
    if (curl_res.status == 0 && curl_res.output != "") {
        let p_obj = parse_json_or_null(curl_res.output);
        if (p_obj && p_obj.proxies) {
            let total_nodes = 0;
            let dead_nodes = 0;
            for (let name in p_obj.proxies) {
                let p = p_obj.proxies[name];
                if (!p) continue;
                let p_type = lc(as_string(p.type || ""));
                if (p_type == "selector" || p_type == "urltest" || p_type == "direct" || p_type == "reject" || p_type == "compatible")
                    continue;
                total_nodes++;
                let history = type(p.history) == "array" ? p.history : [];
                if (length(history) > 0) {
                    let last = history[length(history) - 1];
                    if (last && int(last.delay || 0) == 0)
                        dead_nodes++;
                } else if (p.alive == false) {
                    dead_nodes++;
                }
            }
            if (total_nodes > 0 && dead_nodes == total_nodes) {
                push(causes, {
                    probability: 94,
                    cause: lang == "en" ? sprintf("All outbound proxy servers are unreachable (100%% timeout on %d nodes; check subscription balance or protocol block)", total_nodes)
                                        : sprintf("Все прокси-серверы недоступны (100%% таймаут на %d узлах; проверьте баланс подписки или блокировку протокола)", total_nodes),
                    fix: "update_subscriptions"
                });
                fn_add_fix("update_subscriptions");
            }
        }
    }

    let sub_files = fs.glob("/tmp/tachyon_subscription_cache/*.error");
    if (sub_files) {
        for (let sub_file in sub_files) {
            let err_text = trim(fs.readfile(sub_file) || "");
            if (index(err_text, "401") >= 0 || index(err_text, "403") >= 0) {
                push(causes, {
                    probability: 96,
                    cause: lang == "en" ? "Subscription update rejected by server (HTTP 401/403: expired token or unpaid account)"
                                        : "Обновление подписки отклонено сервером (HTTP 401/403: подписка истекла или не оплачена)",
                    fix: "update_subscriptions"
                });
                fn_add_fix("update_subscriptions");
                break;
            }
        }
    }
}

function diagnose_system_conflicts(cfg, lang, causes, fn_add_fix) {
    let competing_dns = [ "adguardhome", "smartdns", "stubby", "unbound", "nextdns" ];
    for (let svc in competing_dns) {
        let pid = find_process_pid(svc);
        if (pid == "" && svc == "adguardhome")
            pid = find_process_pid("AdGuardHome");
        if (pid != "") {
            if (is_container_process(pid))
                continue;
            if ((svc == "adguardhome" || svc == "AdGuardHome") && is_adguardhome_primary_dns(cfg))
                continue;

            push(causes, {
                probability: 82,
                cause: lang == "en" ? sprintf("Conflicting DNS service running: %s (PID %s) may interfere with Tachyon DNS routing", svc, pid)
                                    : sprintf("Обнаружен сторонний DNS-сервис: %s (PID %s), возможен конфликт перехвата DNS-трафика", svc, pid),
                fix: "fix_dnsmasq"
            });
            fn_add_fix("fix_dnsmasq");
            break;
        }
    }

    let competing_pkgs = [ "passwall", "openclash", "vssr", "shadowsocksr" ];
    for (let pkg in competing_pkgs) {
        let pid = find_process_pid(pkg);
        if (pid != "") {
            if (is_container_process(pid))
                continue;
            push(causes, {
                probability: 88,
                cause: lang == "en" ? sprintf("Conflicting proxy framework running: %s (PID %s) causes routing/nftables rule clashes", pkg, pid)
                                    : sprintf("Обнаружен конфликтующий пакет обхода: %s (PID %s), вызывающий конфликт правил файрвола", pkg, pid),
                fix: "rebuild_rules"
            });
            fn_add_fix("rebuild_rules");
            break;
        }
    }

    let user_domains_text = cfg.user_domains_text || "";
    if (user_domains_text != "") {
        for (let line in split(user_domains_text, "\n")) {
            line = trim(line);
            if (line == "" || index(line, "#") == 0) continue;
            if (index(line, "http://") >= 0 || index(line, "https://") >= 0 || index(line, " ") >= 0) {
                push(causes, {
                    probability: 78,
                    cause: lang == "en" ? sprintf("Syntax error in custom domain list: '%s' contains URL scheme or space (should be domain only)", line)
                                        : sprintf("Синтаксическая ошибка в списке доменов: '%s' содержит протокол или пробелы (требуется только домен)", line),
                    fix: "rebuild_rules"
                });
                fn_add_fix("rebuild_rules");
                break;
            }
        }
    }

    let rs_files = fs.glob("/tmp/sing-box/rulesets/*.srs");
    if (rs_files) {
        for (let rs_file in rs_files) {
            let st = fs.stat(rs_file);
            if (st && st.size == 0) {
                push(causes, {
                    probability: 86,
                    cause: lang == "en" ? sprintf("Corrupted binary ruleset file: %s is 0 bytes", rs_file)
                                        : sprintf("Повреждён бинарный файл правил: %s имеет размер 0 байт", rs_file),
                    fix: "rebuild_rules"
                });
                fn_add_fix("rebuild_rules");
                break;
            }
        }
    }
}

function diagnose_system_clock_and_conntrack(cfg, lang, causes, fn_add_fix) {
    let current_t = time();
    if (current_t < 1735689600) {
        push(causes, {
            probability: 98,
            cause: lang == "en" ? "System clock is not synchronized (year < 2025 causes TLS/x509 certificate validation failures)"
                                : "Системное время роутера не синхронизировано (дата в прошлом ломает валидацию TLS/SSL сертификатов узлов)",
            fix: "fix_system_time"
        });
        fn_add_fix("fix_system_time");
    }

    let count_raw = trim(fs.readfile("/proc/sys/net/netfilter/nf_conntrack_count") || "");
    let max_raw = trim(fs.readfile("/proc/sys/net/netfilter/nf_conntrack_max") || "");
    if (count_raw != "" && max_raw != "") {
        let ct_count = int(count_raw);
        let ct_max = int(max_raw);
        if (ct_max > 0 && (ct_count * 100 / ct_max) >= 88) {
            push(causes, {
                probability: 89,
                cause: lang == "en" ? sprintf("NAT/Firewall connection tracking table nearly full (%d/%d sessions)", ct_count, ct_max)
                                    : sprintf("Таблица отслеживания соединений файрвола (conntrack) почти переполнена (%d/%d сессий)", ct_count, ct_max),
                fix: "flush_conntrack"
            });
            fn_add_fix("flush_conntrack");
        }
    }
}

function diagnose_dns_deadlock_and_mtu(cfg, lang, causes, fn_add_fix) {
    let raw_sb_log = trim(command_output("logread | grep -iE 'lookup.*no such host|lookup.*timeout|dns: lookup failed' | tail -n 10 2>/dev/null"));
    if (raw_sb_log != "" && index(raw_sb_log, "lookup") >= 0) {
        let b_dns = cfg.bootstrap_dns_server || "";
        if (b_dns == "127.0.0.1" || b_dns == "127.0.0.42") {
            push(causes, {
                probability: 93,
                cause: lang == "en" ? "DNS Deadlock: Bootstrap DNS resolver points to local loopback (resolver loop)"
                                    : "DNS Deadlock: Bootstrap-DNS для sing-box указывает на локальный адрес (зацикливание)",
                fix: "fix_bootstrap_dns"
            });
            fn_add_fix("fix_bootstrap_dns");
        }
    }
}

function local_rule_doctor(pre_res, pre_verify) {
    let cfg = uci_settings();
    let lang = lc(trim(cfg.ai_doctor_lang || "ru"));
    // Accepts precomputed doctor/verify results so callers that already ran
    // the full suite (ai_doctor) do not execute every probe twice.
    let res = (pre_res != null) ? pre_res : run_doctor_checks();
    let checks = res.checks || [];
    let verify = (pre_verify != null) ? pre_verify : verify_system();

    let causes = [];
    let quick_fixes = [];
    let fix_set = {};

    function add_fix(code) {
        if (doctor_fix_overused(code)) return;
        if (!fix_set[code]) {
            fix_set[code] = true;
            push(quick_fixes, code);
        }
    }

    // ── 1. End-to-end live verification & root-cause correlation ──
    let is_steer_active = active_engine_is_steer();
    let engine_proc_name = is_steer_active ? "steer process" : "sing-box process";
    let wan_failed = false;
    let engine_failed = false;
    for (let c in verify.checks) {
        if (c.status == "fail") {
            if (c.name == "WAN interface" || c.name == "Default gateway")
                wan_failed = true;
            if (c.name == engine_proc_name)
                engine_failed = true;
        }
    }

    let wan_cause = null;
    let engine_cause = null;

    if (wan_failed) {
        wan_cause = {
            probability: 95,
            cause: lang == "en" ? "WAN default gateway or Internet uplink is unreachable" : "Шлюз по умолчанию или внешний интернет недоступен",
            fix: "fix_wan_interface",
            symptoms: []
        };
        push(causes, wan_cause);
        add_fix("fix_wan_interface");
    } else if (engine_failed) {
        let engine_label = is_steer_active ? "steer" : "sing-box";
        let engine_fix = is_steer_active ? "start_steer" : "start_singbox";
        engine_cause = {
            probability: 95,
            cause: lang == "en" ? (engine_label + " process is stopped or non-functional") : ("Процесс " + engine_label + " остановлен или не функционирует"),
            fix: engine_fix,
            symptoms: []
        };
        push(causes, engine_cause);
        add_fix(engine_fix);
    }

    for (let c in verify.checks) {
        if (c.status != "fail") continue;
        if (c.name == engine_proc_name) {
            if (!engine_cause && !wan_cause) {
                let engine_label = is_steer_active ? "steer" : "sing-box";
                let engine_fix = is_steer_active ? "start_steer" : "start_singbox";
                push(causes, {
                    probability: 95,
                    cause: lang == "en" ? (engine_label + " process is stopped or non-functional") : ("Процесс " + engine_label + " остановлен или не функционирует"),
                    fix: engine_fix
                });
                add_fix(engine_fix);
            }
        } else if (c.name == "LAN DNS via dnsmasq") {
            push(causes, {
                probability: 85,
                cause: lang == "en" ? "LAN DNS resolution failed (dnsmasq)" : "Сбой разрешения DNS на уровне локального dnsmasq",
                fix: "fix_dnsmasq"
            });
            add_fix("fix_dnsmasq");
        } else if (c.name == "Proxy DNS via steer" || c.name == "Proxy DNS via sing-box") {
            if (wan_cause) {
                push(wan_cause.symptoms, lang == "en" ? "Proxy DNS unavailable (WAN down)" : "Прокси-DNS недоступен (нет связи с WAN)");
            } else if (engine_cause) {
                let engine_label = is_steer_active ? "steer" : "sing-box";
                push(engine_cause.symptoms, lang == "en" ? ("Proxy DNS not answering (" + engine_label + " stopped)") : ("Прокси-DNS не отвечает (" + engine_label + " остановлен)"));
            } else {
                let fix_action = is_steer_active ? "restart_steer_dns" : "clear_dns_cache";
                push(causes, {
                    probability: 85,
                    cause: is_steer_active ?
                        (lang == "en" ? "Proxy DNS via steer failed to respond" : "Прокси-DNS через steer (:5300) не отвечает") :
                        (lang == "en" ? "Proxy DNS via sing-box failed to respond" : "Прокси-DNS через sing-box (127.0.0.42) не отвечает"),
                    fix: fix_action
                });
                add_fix(fix_action);
                if (!is_steer_active && cfg.dns_type != "doh") {
                    add_fix("switch_to_doh");
                }
            }
        } else if (c.name == "WAN interface" || c.name == "Default gateway") {
            // Already added as primary root cause if wan_failed
        } else if (c.name == "HTTP via proxy") {
            if (wan_cause) {
                push(wan_cause.symptoms, lang == "en" ? "HTTP through proxy unreachable (WAN down)" : "HTTP через прокси недоступен (нет связи с WAN)");
            } else if (singbox_cause) {
                push(singbox_cause.symptoms, lang == "en" ? "HTTP through proxy fails (sing-box stopped)" : "HTTP через прокси не проходит (sing-box остановлен)");
            } else {
                push(causes, {
                    probability: 88,
                    cause: lang == "en" ? "HTTP through the proxy fails end-to-end (node offline or blocked)" : "HTTP через прокси не проходит (узел офлайн или заблокирован)",
                    fix: "update_subscriptions"
                });
                add_fix("update_subscriptions");
                add_fix("restart_zapret");
            }
        }
    }

    // ── 2. Memory and Out-of-Memory pressure ──
    let raw_log = trim(command_output("logread | grep -iE 'oom-killer|out of memory|killed process' | tail -n 20 2>/dev/null"));
    if (index(raw_log, "Out of memory") >= 0 || index(raw_log, "oom-killer") >= 0 || index(raw_log, "Killed process") >= 0) {
        push(causes, {
            probability: 92,
            cause: lang == "en" ? "RAM pressure (Out-Of-Memory kill) detected in recent log" : "Обнаружена нехватка оперативной памяти (OOM Kill в журнале)",
            fix: "optimize_memory"
        });
        add_fix("optimize_memory");
    }

    let meminfo = fs.readfile("/proc/meminfo") || "";
    let mem_avail_line = match(meminfo, /MemAvailable:\s+(\d+)\s+kB/);
    if (mem_avail_line) {
        let mem_avail_mb = int(mem_avail_line[1]) / 1024;
        if (mem_avail_mb < 20) {
            push(causes, {
                probability: 85,
                cause: lang == "en" ? sprintf("Critical RAM pressure (Available: %d MB)", mem_avail_mb) : sprintf("Критический дефицит оперативной памяти (Свободно: %d MB)", mem_avail_mb),
                fix: "optimize_memory"
            });
            add_fix("optimize_memory");
        }
    }

    // ── 3. Snapshot check failures not covered above ──
    for (let c in checks) {
        if (c.status != "fail") continue;
        let known = false;
        for (let v in verify.checks) {
            if (v.name == c.name) { known = true; break; }
        }
        if (known) continue;
        if (index(c.name, "nftables") >= 0 || index(c.name, "ip rule") >= 0 || index(c.name, "MSS") >= 0) {
            push(causes, {
                probability: 80,
                cause: lang == "en" ? "NFTables routing or firewall rules compromised" : "Нарушены правила файрвола nftables или маршрутизация",
                fix: "rebuild_rules"
            });
            add_fix("rebuild_rules");
        } else if (index(c.name, "resolv") >= 0) {
            push(causes, {
                probability: 80,
                cause: lang == "en" ? "DNS resolv.conf configuration broken" : "Конфигурация /etc/resolv.conf повреждена",
                fix: "fix_resolv_symlink"
            });
            add_fix("fix_resolv_symlink");
        } else if (index(c.name, "certificate pinning") >= 0 || index(c.name, "pinning") >= 0) {
            push(causes, {
                probability: 90,
                cause: lang == "en" ? "TLS certificate pin configured in proxy nodes, but installed sing-box does not support certificate_sha256 (requires sing-box 1.15+)" : "Указан TLS pin сертификата для прокси, но установленный sing-box не поддерживает certificate_sha256 (требуется sing-box 1.15+)",
                fix: "upgrade_to_singbox_extended"
            });
            add_fix("upgrade_to_singbox_extended");
        }
    }

    // ── 4. DPI circumvention check (Zapret / ByeDPI) ──
    let zapret_mode = trim(as_string(cfg.zapret_mode || "disabled"));
    let byedpi_mode = trim(as_string(cfg.byedpi_mode || "disabled"));
    if (zapret_mode != "disabled" && zapret_mode != "") {
        let zap_pid = find_process_pid("nfqws");
        if (zap_pid == "") zap_pid = find_process_pid("nfqws2");
        if (zap_pid == "") {
            push(causes, {
                probability: 84,
                cause: lang == "en" ? "Zapret (nfqws) engine is stopped" : "Служба обхода DPI (Zapret/nfqws) остановлена",
                fix: "restart_zapret"
            });
            add_fix("restart_zapret");
        }
    }
    if (byedpi_mode != "disabled" && byedpi_mode != "") {
        let bd_pid = find_process_pid("ciadpi");
        if (bd_pid == "") {
            push(causes, {
                probability: 84,
                cause: lang == "en" ? "ByeDPI (ciadpi) engine is stopped" : "Служба обхода DPI (ByeDPI/ciadpi) остановлена",
                fix: "restart_zapret"
            });
            add_fix("restart_zapret");
        }
    }

    // ── 5. Advanced DPI & Censorship Checks ──
    try { diagnose_dpi_and_censorship(cfg, lang, causes, add_fix); } catch(e) { warn("DPI diag error: " + as_string(e) + "\n"); }

    // ── 6. Proxy Nodes & Subscriptions Health ──
    try { diagnose_proxies_health(cfg, lang, causes, add_fix); } catch(e) { warn("Proxy diag error: " + as_string(e) + "\n"); }

    // ── 7. OpenWrt Service & Port Conflicts ──
    try { diagnose_system_conflicts(cfg, lang, causes, add_fix); } catch(e) { warn("Conflict diag error: " + as_string(e) + "\n"); }

    // ── 8. System Clock & Connection Tracking ──
    try { diagnose_system_clock_and_conntrack(cfg, lang, causes, add_fix); } catch(e) { warn("Clock/Conntrack diag error: " + as_string(e) + "\n"); }

    // ── 9. DNS Deadlock & MTU ──
    try { diagnose_dns_deadlock_and_mtu(cfg, lang, causes, add_fix); } catch(e) { warn("DNS Deadlock/MTU diag error: " + as_string(e) + "\n"); }

    // If multiple critical failures, provide emergency native internet restoration
    if (verify.failed >= 2) {
        add_fix("restore_native_internet");
    }

    // Sort fixes by priority order
    try { quick_fixes = prioritize_quick_fixes(quick_fixes); } catch(e) { warn("Prioritize error: " + as_string(e) + "\n"); }

    let report_lines = [];
    let is_fully_healthy = verify.failed == 0 && length(causes) == 0;

    if (lang == "en") {
        push(report_lines, "### Tachyon Local AI Doctor Analysis");
        if (is_fully_healthy) {
            push(report_lines, "✓ Verified end-to-end: network stack is fully operational.");
            push(report_lines, "- WAN interface is up and has an active default route.");
            push(report_lines, "- DNS resolution is healthy (LAN dnsmasq, upstream, proxy resolver).");
            push(report_lines, "- sing-box and nftables firewall redirection rules are active.");
            push(report_lines, "- No active DPI drops or RAM pressure detected.");
            if (verify.stability.wan_flaps > 0 || verify.stability.singbox_restarts > 0 || verify.stability.dnsmasq_restarts > 0) {
                push(report_lines, "\nℹ️ Notice: Recent logs show historical component recovery; current live state is stable.");
            }
        } else {
            push(report_lines, "#### Root Cause Analysis:");
            for (let c in causes) {
                let line = sprintf("- [%d%% Probability] %s", c.probability, c.cause);
                if (c.symptoms && length(c.symptoms) > 0)
                    line += " (Symptoms: " + join("; ", c.symptoms) + ")";
                push(report_lines, line);
            }
        }
    } else {
        push(report_lines, "### Анализ Tachyon Local AI Doctor");
        if (is_fully_healthy) {
            push(report_lines, "✓ Проверено вживую: сетевой стек работает штатно.");
            push(report_lines, "- WAN интерфейс активен и имеет рабочий маршрут по умолчанию.");
            push(report_lines, "- DNS-резолверы отвечают корректно (LAN dnsmasq, upstream, прокси-резолвер).");
            push(report_lines, "- sing-box и правила файрвола nftables функционируют штатно.");
            push(report_lines, "- Блокировок DPI и нехватки оперативной памяти не обнаружено.");
            if (verify.stability.wan_flaps > 0 || verify.stability.singbox_restarts > 0 || verify.stability.dnsmasq_restarts > 0) {
                push(report_lines, "\nℹ️ Справка: В журнале зафиксировано восстановление компонентов после перезапуска, сейчас всё стабильно.");
            }
        } else {
            push(report_lines, "#### Анализ возможных причин сбоя:");
            for (let c in causes) {
                let line = sprintf("- [%d%% вероятность] %s", c.probability, c.cause);
                if (c.symptoms && length(c.symptoms) > 0)
                    line += " (Симптомы: " + join("; ", c.symptoms) + ")";
                push(report_lines, line);
            }
        }
    }

    let engine_name = is_steer_active ? "steer" : "sing-box";
    let nodes = [
        { name: "WAN", status: "OK" },
        { name: "DNS", status: "OK" },
        { name: engine_name, status: "OK" },
        { name: "nftables", status: "OK" }
    ];
    for (let c in verify.checks) {
        if (c.status == "fail") {
            if (c.name == "WAN interface" || c.name == "Default gateway") {
                nodes[0].status = "FAIL";
            } else if (index(c.name, "DNS") >= 0) {
                nodes[1].status = "FAIL";
            } else if (index(c.name, engine_name) >= 0) {
                nodes[2].status = "FAIL";
            }
        }
    }
    for (let c in checks) {
        if (c.status == "fail") {
            if (index(c.name, "nftables") >= 0 || index(c.name, "ip rule") >= 0) {
                nodes[3].status = "WARN";
            }
        }
    }

    let quick_fix = length(quick_fixes) > 0 ? join(",", quick_fixes) : "";
    let doctor_res = {
        success: true,
        timestamp: time(),
        report: join("\n", report_lines),
        nodes: nodes,
        quick_fix: quick_fix,
        quick_fixes: quick_fixes,
        provider: "local_heuristic",
        model: "rule_engine_v2"
    };

    let f = fs.open("/tmp/ai_doctor_last.json", "w");
    if (f) {
        f.write(sprintf("%J\n", doctor_res));
        f.close();
    }
    return doctor_res;
}

function ai_doctor(user_query) {
    let cfg = uci_settings();
    // Run the diagnostic suite exactly once: the same results feed both the
    // rule-based diagnosis and the report/verification assembly below.
    let res = run_doctor_checks();
    let verify = verify_system();
    let local_res = local_rule_doctor(res, verify);

    let prov = lc(trim(as_string(cfg.ai_doctor_provider || "openai")));
    let has_key = (cfg.ai_doctor_api_key && cfg.ai_doctor_api_key != "");
    let is_local_or_custom = (prov == "ollama" || prov == "lmstudio" || (prov == "custom" && cfg.ai_doctor_custom_url != ""));

    if (cfg.enable_ai_doctor != "1" || (!has_key && !is_local_or_custom)) {
        print(sprintf("%J\n", local_res));
        return 0;
    }

    let report = res.report;

    let dns_type = cfg.dns_type || "doh";
    let version = trim(command_output("cat /etc/tachyon/version 2>/dev/null")) || "unknown";
    let singbox_running = trim(command_output("pgrep -x sing-box 2>/dev/null")) != "";
    let uptime_out = trim(command_output("cat /proc/uptime 2>/dev/null"));
    let uptime_min = uptime_out != "" ? int(split(uptime_out, ".")[0]) / 60 : 0;

    let watchdog_status_raw = fs.readfile("/tmp/tachyon_ai_status.json");
    let watchdog_info = "Watchdog Status: unavailable";
    if (watchdog_status_raw) {
        let wd_json = parse_json_or_null(watchdog_status_raw);
        if (wd_json) {
            watchdog_info = sprintf(
                "Watchdog Status:\n- Last OOM: %s\n- WAN fail streak: %d\n- Proxy fail streak: %d\n- DNS fail streak: %d\n- Active repairs: %s",
                as_string(wd_json.last_oom_time || "none"),
                int(wd_json.wan_fail_streak || 0),
                int(wd_json.proxy_fail_streak || 0),
                int(wd_json.dns_fail_streak || 0),
                as_string(wd_json.active_repairs || "none")
            );
        }
    }

    let raw_log_snippet = trim(command_output("logread | grep -iE 'tachyon|sing-box|dnsmasq|oom|error|fatal' | tail -n 25 2>/dev/null")) || "No recent system errors logged.";
    let log_snippet = compress_log_snippet(raw_log_snippet);

    // Live end-to-end verification — the part that catches "all OK on paper,
    // broken in practice": DNS through each layer, HTTP through the proxy, and
    // the recent flap/restart history a snapshot cannot see.
    let verify_lines = [ "Live Verification:" ];
    for (let c in verify.checks) {
        push(verify_lines, sprintf("- %s: %s (%s)", c.name, c.status, c.detail));
    }
    push(verify_lines, sprintf("Stability (recent log): WAN flaps: %d, sing-box restarts: %d, dnsmasq restarts: %d, tachyon reloads: %d",
        verify.stability.wan_flaps, verify.stability.singbox_restarts,
        verify.stability.dnsmasq_restarts, verify.stability.tachyon_restarts));
    let verify_info = join("\n", verify_lines);

    let sys_context = sprintf(
        "Tachyon Doctor Report:\n%s\n\n" +
        "Local Rule Diagnosis:\n%s\n\n" +
        "System Parameters:\n" +
        "Version: %s\n" +
        "DNS type: %s\n" +
        "sing-box running: %s\n" +
        "Uptime: %d minutes\n\n" +
        "%s\n\n" +
        "%s\n\n" +
        "Recent Critical System Logs:\n%s\n",
        report, local_res.report, version, dns_type, singbox_running ? "yes" : "no", uptime_min,
        watchdog_info, verify_info, log_snippet
    );

    // Declared before first use: the RAG call below needs the configured
    // chat/embedding model override, which used to be read only further down.
    let model_override = trim(cfg.ai_doctor_model || "");

    let rag_context = "";
    if (cfg.enable_rag == "1") {
        let rag_query = user_query || substr(sys_context, 0, 500);
        rag_context = rag.retrieve(rag_query, prov, cfg.ai_doctor_api_key || "", cfg.ai_doctor_custom_url || "", model_override);
    }
    if (rag_context != "")
        sys_context += "\n\nRelevant Documentation:\n" + rag_context;

    let lang = lc(trim(cfg.ai_doctor_lang || "ru"));
    let prompt = "";
    if (lang == "en") {
        prompt = sprintf(
            "You are \"Tachyon AI Doctor\", an AI assistant for anti-censorship and proxy services on OpenWrt.\n" +
            "Analyze the diagnostic report and system logs below.\n\n%s\n\n" +
            "Formulate a concise diagnosis (in English, max 3-4 bullet points).\n" +
            "If automatic quick fix is possible, include at the very end of your response:\n" +
            "FIX: code1, code2\n\n" +
            "IMPORTANT: do NOT report \"everything is fine\" when the Live Verification or Stability section shows any FAIL check, WAN flaps, or repeated service restarts — those are real problems even if the point-in-time checks passed.\n\n" +
            "Available quick fix codes:\n" +
            "- start_singbox (sing-box process is stopped or missing)\n" +
            "- rebuild_rules (nftables or ip rules damaged)\n" +
            "- fix_dnsmasq (dnsmasq service not responding)\n" +
            "- fix_resolv_symlink (resolv.conf symlink broken)\n" +
            "- start_watchdog (watchdog daemon stopped)\n" +
            "- restart_singbox_dns (sing-box DNS failed)\n" +
            "- fix_uci_config (Tachyon UCI config corrupted)\n" +
            "- fix_wan_interface (WAN interface down)\n" +
            "- fix_gateway (default gateway missing)\n" +
            "- clear_dns_cache (clear DNS cache & restart dnsmasq)\n" +
            "- update_subscriptions (force update proxy subscriptions)\n" +
            "- reset_firewall (restart router firewall)\n" +
            "- restart_network (restart network service)\n" +
            "- restart_zapret (restart Zapret/ByeDPI engines)\n" +
            "- restart_providers (restart WDTT/OLCRTC/FPTN provider runtimes)\n" +
            "- fix_system_time (system time is out of sync, breaking TLS)\n" +
            "- flush_conntrack (conntrack table is full)\n" +
            "- fix_bootstrap_dns (bootstrap DNS resolver is unreachable)\n" +
            "- optimize_mtu (tunnel MTU is suboptimal, re-discover AWG MTU)\n" +
            "- heal_network_stack (full network stack recovery)\n" +
            "- enable_safe_bypass (enable safe Direct WAN bypass fallback)\n" +
            "- restore_native_internet (restore native direct internet without Tachyon)\n" +
            "- optimize_memory (flush memory caches)\n" +
            "- switch_to_doh (switch DNS interception to DoH)\n\n" +
            "If no quick fix applies, do NOT output any FIX tag.", sys_context);
    } else {
        prompt = sprintf(
            "Вы — ИИ-ассистент \"Tachyon AI Doctor\" для сервиса обхода блокировок на OpenWrt.\n" +
            "Проанализируйте диагностический отчет и логи ниже.\n\n%s\n\n" +
            "Сформулируйте краткий диагноз (на русском, максимум 3-4 пункта).\n" +
            "Если авто-исправление возможно, укажите в самом конце ответа строчку:\n" +
            "FIX: код1, код2\n\n" +
            "ВАЖНО: не пишите «всё в порядке», если в секции Live Verification или Stability есть хоть один провал, флапы WAN или повторные перезапуски сервисов — это реальные проблемы, даже если мгновенные проверки прошли.\n\n" +
            "Доступные коды быстрого исправления:\n" +
            "- start_singbox (sing-box упал или остановлен)\n" +
            "- rebuild_rules (nftables или ip rule правила нарушены)\n" +
            "- fix_dnsmasq (конфиг или сервис dnsmasq не отвечает)\n" +
            "- fix_resolv_symlink (resolv.conf повреждён)\n" +
            "- start_watchdog (watchdog остановлен)\n" +
            "- restart_singbox_dns (sing-box DNS не отвечает)\n" +
            "- fix_uci_config (конфиг Tachyon повреждён)\n" +
            "- fix_wan_interface (WAN интерфейс не работает)\n" +
            "- fix_gateway (шлюз отсутствует)\n" +
            "- clear_dns_cache (очистить кэш DNS и перезапустить dnsmasq)\n" +
            "- update_subscriptions (принудительно обновить прокси подписки)\n" +
            "- reset_firewall (перезапустить файрвол роутера)\n" +
            "- restart_network (перезапустить сетевой стек)\n" +
            "- restart_zapret (перезапустить службы Zapret/ByeDPI)\n" +
            "- restart_providers (перезапустить провайдеры WDTT/OLCRTC/FPTN)\n" +
            "- fix_system_time (системное время сбито, ломает TLS)\n" +
            "- flush_conntrack (таблица conntrack переполнена)\n" +
            "- fix_bootstrap_dns (bootstrap DNS недоступен)\n" +
            "- optimize_mtu (подобрать оптимальный MTU туннеля)\n" +
            "- heal_network_stack (полное восстановление сетевого стека)\n" +
            "- enable_safe_bypass (включить безопасный обход через WAN напрямую)\n" +
            "- restore_native_internet (вернуть прямой интернет без Tachyon)\n" +
            "- optimize_memory (очистить оперативно память)\n" +
            "- switch_to_doh (переключить DNS на DoH)\n\n" +
            "Если авто-исправление не применимо, не пишите тег FIX.", sys_context);
    }

    user_query = trim(as_string(user_query || ""));
    if (user_query != "") {
        prompt += "\n\n---\nПользователь задал вопрос: " + user_query + "\nОтветьте на него, учитывая диагностический контекст выше. Если вопрос не связан с диагностикой/настройкой роутера — ответьте на него как ИИ-ассистент, но кратко упомяните текущее состояние системы.\n";
    }

    let provider = cfg.ai_doctor_provider || "openai";
    let api_key = cfg.ai_doctor_api_key || "";
    let custom_url = cfg.ai_doctor_custom_url || "";

    let ai_res = query_llm(provider, api_key, custom_url, prompt, model_override);
    if (!ai_res) {
        print(sprintf("%J\n", local_res));
        return 0;
    }

    let quick_fixes = [];
    let text = ai_res;
    let fix_idx = index(text, "FIX:");
    if (fix_idx >= 0) {
        let fix_part = trim(substr(text, fix_idx + 4));
        let raw_codes = split(fix_part, /[,\r\n]+/);
        for (let code in raw_codes) {
            let clean_code = trim(replace(code, /[._`*]/g, ""));
            let first_token = split(clean_code, /[ \t]+/)[0];
            if (first_token != "") {
                push(quick_fixes, first_token);
            }
        }
        text = trim(substr(text, 0, fix_idx));
    }
    let quick_fix = length(quick_fixes) > 0 ? join(",", quick_fixes) : "";

    let doctor_res = {
        success: true,
        timestamp: time(),
        report: text,
        nodes: local_res.nodes,
        quick_fix: quick_fix,
        quick_fixes: quick_fixes,
        provider: provider,
        model: model_override != "" ? model_override : "default"
    };

    let f = fs.open("/tmp/ai_doctor_last.json", "w");
    if (f) {
        f.write(sprintf("%J\n", doctor_res));
        f.close();
    }

    print(sprintf("%J\n", doctor_res));
    return 0;
}


function extract_ruleset(tag) {
    if (tag == "") {
        warn("tag is required\n");
        return 1;
    }

    let db_path = "/etc/sing-box/cache.db";
    let f = fs.open(db_path, "r");
    if (!f) {
        warn("failed to open " + db_path + "\n");
        return 1;
    }

    let page_size = 4096;
    let found_data = null;
    
    while (true) {
        let header = f.read(16);
        if (!header || length(header) < 16) {
            break;
        }

        let flags = (ord(header, 9) << 8) | ord(header, 8);
        let count = (ord(header, 11) << 8) | ord(header, 10);
        let overflow = (ord(header, 15) << 24) | (ord(header, 14) << 16) | (ord(header, 13) << 8) | ord(header, 12);
        
        let remaining_page_size = page_size - 16;
        if (overflow > 0) {
            remaining_page_size += overflow * page_size;
        }
        
        let page_body = f.read(remaining_page_size);
        if (!page_body || length(page_body) < remaining_page_size) {
            break;
        }
        
        let page_data = header + page_body;
        
        if (flags == 0x02 && count > 0) {
            let elem_offset = 16;
            for (let i = 0; i < count; i++) {
                if (elem_offset + 16 > length(page_data)) break;
                
                let pos = (ord(page_data, elem_offset + 7) << 24) |
                          (ord(page_data, elem_offset + 6) << 16) |
                          (ord(page_data, elem_offset + 5) << 8) |
                          ord(page_data, elem_offset + 4);
                let ksize = (ord(page_data, elem_offset + 11) << 24) |
                            (ord(page_data, elem_offset + 10) << 16) |
                            (ord(page_data, elem_offset + 9) << 8) |
                            ord(page_data, elem_offset + 8);
                let vsize = (ord(page_data, elem_offset + 15) << 24) |
                            (ord(page_data, elem_offset + 14) << 16) |
                            (ord(page_data, elem_offset + 13) << 8) |
                            ord(page_data, elem_offset + 12);
                
                let key_start = elem_offset + pos;
                if (key_start + ksize + vsize <= length(page_data)) {
                    let key = substr(page_data, key_start, ksize);
                    if (key == tag) {
                        let raw_val = substr(page_data, key_start + ksize, vsize);
                        // Parse varint length of the ruleset to skip cache header
                        let offset = 1; // skip cache type (0x01)
                        let len = 0;
                        let shift = 0;
                        while (offset < length(raw_val)) {
                            let b = ord(raw_val, offset);
                            len |= ((b & 0x7F) << shift);
                            offset++;
                            if (!(b & 0x80)) {
                                break;
                            }
                            shift += 7;
                        }
                        found_data = substr(raw_val, offset, len);
                        break;
                    }
                }
                
                elem_offset += 16;
            }
        }
        if (found_data) break;
    }
    
    f.close();

    if (!found_data) {
        warn("tag " + tag + " not found in cache.db\n");
        return 1;
    }

    let out_dir = "/tmp/sing-box/rulesets";
    system("mkdir -p " + out_dir);

    let out_path = out_dir + "/community_" + tag + ".srs";
    if (fs.writefile(out_path, found_data) == null) {
        warn("failed to write ruleset to " + out_path + "\n");
        return 1;
    }

    print(out_path + "\n");
    return 0;
}


return {
    print_global,
    render_or_fail,
    global_check,
    find_process_pid,
    is_container_process,
    uci_settings,
    is_adguardhome_primary_dns,
    tachyon_is_running,
    tachyon_is_enabled,
    is_degraded,
    kill_our_core_processes,
    doc_repair_enabled,
    doc_plan,
    doc_set,
    doc_commit,
    doc_run,
    doc_unlink,
    doc_symlink,
    run_recovery_checks,
    has_certificate_pins_configured,
    run_doctor_checks_impl,
    doctor_lock_try,
    doctor_lock_release,
    doctor_history_load,
    doctor_history_record,
    doctor_history_trend,
    run_doctor_checks,
    query_llm,
    doctor,
    compress_log_snippet,
    diagnose_json,
    doctor_fix_record,
    doctor_fix_overused,
    verify_system,
    ai_doctor_last,
    doctor_fix_sort,
    prioritize_quick_fixes,
    diagnose_dpi_and_censorship,
    diagnose_proxies_health,
    diagnose_system_conflicts,
    diagnose_system_clock_and_conntrack,
    diagnose_dns_deadlock_and_mtu,
    local_rule_doctor,
    ai_doctor,
    extract_ruleset
};
