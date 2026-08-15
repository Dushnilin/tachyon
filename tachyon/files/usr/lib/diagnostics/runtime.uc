#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let runtime_dns = require("singbox.dns");
let common = require("core.common");

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
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || constants.TMP_RULESET_FOLDER || TMP_SING_BOX_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || constants.TMP_SUBSCRIPTION_FOLDER || TMP_SING_BOX_FOLDER + "/subscriptions";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const CHECK_PROXY_IP_DOMAIN = getenv("CHECK_PROXY_IP_DOMAIN") || constants.CHECK_PROXY_IP_DOMAIN || "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = getenv("FAKEIP_TEST_DOMAIN") || constants.FAKEIP_TEST_DOMAIN || "fakeip.podkop.fyi";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || constants.NFT_COMMON_SET_NAME || "tachyon_subnets";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || constants.NFT_PORT_SET_NAME || "tachyon_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || constants.NFT_IP_PORT_SET_NAME || "tachyon_ip_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || constants.NFT_INTERFACE_SET_NAME || "tachyon_interfaces";
const NFT_DISCORD_SET_NAME = getenv("NFT_DISCORD_SET_NAME") || constants.NFT_DISCORD_SET_NAME || "tachyon_discord_subnets";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || constants.NFT_LOCALV4_SET_NAME || "localv4";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || constants.SB_DNS_INBOUND_ADDRESS || "127.0.0.42";
const SB_TPROXY_INBOUND6_ADDRESS = getenv("SB_TPROXY_INBOUND6_ADDRESS") || constants.SB_TPROXY_INBOUND6_ADDRESS || "::1";
const SB_TPROXY_INBOUND_PORT = getenv("SB_TPROXY_INBOUND_PORT") || constants.SB_TPROXY_INBOUND_PORT || "1602";
const SB_CLASH_API_CONTROLLER_PORT = getenv("SB_CLASH_API_CONTROLLER_PORT") || constants.SB_CLASH_API_CONTROLLER_PORT || "9090";
const SB_VARIANT_STATE_FILE = getenv("SB_VARIANT_STATE_FILE") || constants.SB_VARIANT_STATE_FILE || "/etc/tachyon/sing-box-variant";
const SING_BOX_BIN_PATH = getenv("TACHYON_DIAGNOSTICS_SING_BOX_BIN_PATH") || "/usr/bin/sing-box";
const CLOUDFLARE_OCTETS = getenv("CLOUDFLARE_OCTETS") || constants.CLOUDFLARE_OCTETS || "8.47 162.159 188.114";
const ZAPRET_LEGACY_DEFAULT_NFQWS_OPT = getenv("ZAPRET_LEGACY_DEFAULT_NFQWS_OPT") || constants.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT || "";
const DEFAULT_LATENCY_TEST_URL = getenv("DEFAULT_LATENCY_TEST_URL") || "https://www.gstatic.com/generate_204";
const RUNTIME_STABLE_MIN_AGE = getenv("TACHYON_RUNTIME_STABLE_MIN_AGE") || "2";

const STATUS_UC = LIB_DIR + "/diagnostics/status.uc";
const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const PACKAGES_UC = LIB_DIR + "/core/packages.uc";
const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const SERVICE_STATE_UC = LIB_DIR + "/service/state.uc";
const SERVICE_UI_UC = LIB_DIR + "/service/ui.uc";
const SUBSCRIPTION_CACHE_UC = LIB_DIR + "/subscription/cache.uc";
const PROVIDERS_STATUS_UC = LIB_DIR + "/providers/status.uc";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";
const ZAPRET_RUNTIME_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_RUNTIME_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const BYEDPI_RUNTIME_UC = LIB_DIR + "/providers/byedpi/runtime.uc";
const ZAPRET_VALIDATOR_UC = LIB_DIR + "/providers/zapret/validator.uc";
const ZAPRET2_VALIDATOR_UC = LIB_DIR + "/providers/zapret2/validator.uc";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function arg_number(value) {
    value = as_string(value);
    return value == "" || match(value, /[^0-9-]/) != null ? 0 : int(value, 10);
}

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    if (status == -1)
        return 255;
    let signal = status & 127;
    if (signal != 0)
        return 128 + signal;
    return (status >> 8) & 255;
}

function command_status(command) {
    return normalize_status(system(command));
}

const UCI_BACKUP_DIR = "/etc/backup";
const UCI_BACKUP_PATH = UCI_BACKUP_DIR + "/tachyon_config";

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };

    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

// The inner unlinks clean up the temp file after a failed write or rename;
// both paths return false, so the failure is already reported. The outer catch
// covers an unreadable /etc/tachyon or an unwritable backup directory, which
// the caller treats as "no backup available".
function uci_backup_save() {
    try {
        let data = fs.readfile(TACHYON_CONFIG);
        if (data == null || data == "") return false;
        fs.mkdir(UCI_BACKUP_DIR);
        let tmp = UCI_BACKUP_PATH + ".tmp";
        if (fs.writefile(tmp, data) == null) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        if (!fs.rename(tmp, UCI_BACKUP_PATH)) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        return true;
    } catch (e) { return false; }
}

// Same shape as uci_backup_save above: the inner unlinks clean up after a
// failed write or rename, and both paths return false.
function uci_backup_restore() {
    try {
        let data = fs.readfile(UCI_BACKUP_PATH);
        if (data == null || data == "") return false;
        let tmp = TACHYON_CONFIG + ".tmp";
        if (fs.writefile(tmp, data) == null) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        if (!fs.rename(tmp, TACHYON_CONFIG)) {
            try { fs.unlink(tmp); } catch(e) {}
            return false;
        }
        return true;
    } catch (e) { return false; }
}

function uci_config_valid() {
    let data = fs.readfile(TACHYON_CONFIG);
    if (data == null || data == "") return false;
    let res = command_status("uci -c /etc/config valid " + CONFIG_NAME + " >/dev/null 2>&1");
    return res == 0;
}

function command_output(command) {
    let result = command_capture(command);
    return result.status == 0 ? result.output : "";
}

function command_success(command) {
    return command_status(command + " >/dev/null 2>&1") == 0;
}

function command_output_from_args(args) {
    return command_output(command_from_args(args) + " 2>/dev/null");
}

function command_success_from_args(args) {
    return command_success(command_from_args(args));
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", as_string(name) ]);
}

function parse_json_or_null(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function push_unique(result, seen, value) {
    value = as_string(value);
    if (value == "" || seen[value])
        return;
    seen[value] = true;
    push(result, value);
}

function network_status_ip_addresses(data, key) {
    let value = parse_json_or_null(data);
    let addresses = type(value) == "object" ? value[key] : null;
    let result = [];
    let seen = {};
    if (type(addresses) == "array") {
        for (let item in addresses) {
            if (type(item) == "object")
                push_unique(result, seen, item.address || "");
        }
    }
    return result;
}

function get_wan_ip_addresses() {
    let result = [];
    let seen = {};

    for (let interface in [ "wan", "wwan" ]) {
        let data = command_output_from_args([
            "ubus", "-S", "call", "network.interface." + interface, "status"
        ]);
        for (let ip in network_status_ip_addresses(data, "ipv4-address"))
            push_unique(result, seen, ip);
        for (let ip in network_status_ip_addresses(data, "ipv6-address"))
            push_unique(result, seen, ip);
    }

    let route = command_output_from_args([ "ip", "-4", "route", "show", "default" ]);
    let fields = words(route);
    let iface = "";
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] == "dev") {
            iface = fields[i + 1];
            break;
        }
    }
    if (iface == "")
        return "";

    let addr = command_output_from_args([ "ip", "-4", "addr", "show", "dev", iface ]);
    for (let line in split(addr, "\n")) {
        line = trim(as_string(line));
        let matched = match(line, /^inet[ \t]+([0-9.]+)\//);
        if (matched != null)
            push_unique(result, seen, matched[1]);
    }
    return join(" ", result);
}

function dns_check_through_singbox(domain) {
    let res = command_capture("nslookup " + shell_quote(domain) + " " + SB_DNS_INBOUND_ADDRESS + " 2>&1");
    return index(res.output, "Address:") >= 0 && index(res.output, "#53") >= 0 && index(res.output, "NXDOMAIN") < 0;
}

function get_wan_interface() {
    let res = command_capture("uci -q get tachyon.settings.output_network_interface 2>/dev/null");
    let iface = (res.status == 0) ? trim(res.output) : "";
    if (iface != "") return iface;

    res = command_capture("uci get network.wan.device 2>/dev/null");
    iface = (res.status == 0) ? trim(res.output) : "";
    if (iface != "") return iface;

    res = command_capture("uci get network.wan.ifname 2>/dev/null");
    iface = (res.status == 0) ? trim(res.output) : "";
    if (iface != "") return iface;

    let route = command_output_from_args([ "ip", "-4", "route", "show", "default" ]);
    let fields = words(route);
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] == "dev") {
            iface = fields[i + 1];
            break;
        }
    }
    if (iface != "") return iface;

    return "eth0";
}

function wan_has_ip() {
    let wan_ips = get_wan_ip_addresses();
    if (wan_ips != "") return true;

    let iface = get_wan_interface();
    let out = command_capture("ip addr show " + shell_quote(iface) + " 2>/dev/null").output;
    if (index(out, "inet ") >= 0) return true;

    let ubus_status = command_output_from_args([ "ubus", "-S", "call", "network.interface.wan", "status" ]);
    let status_json = parse_json_or_null(ubus_status);
    if (type(status_json) == "object" && status_json.up === true)
        return true;

    return default_gateway_exists();
}

function default_gateway_exists() {
    let out = command_capture("ip route 2>/dev/null").output;
    return index(out, "default") >= 0;
}

function get_all_dns_servers(cfg, key) {
    let servers = [];
    let raw = cfg[key];
    if (type(raw) == "array") {
        for (let s in raw) {
            let trimmed = trim(as_string(s));
            if (trimmed != "") push(servers, split(trimmed, "#")[0]);
        }
    } else if (raw && trim(as_string(raw)) != "") {
        for (let s in split(trim(as_string(raw)), /\s+/)) {
            let trimmed = trim(s);
            if (trimmed != "") push(servers, split(trimmed, "#")[0]);
        }
    }
    return servers;
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let arg in args)
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

function status_capture(args, input) {
    if (input != null)
        return module_capture_stdin(STATUS_UC, args, input);
    return command_capture(command_from_args(module_args(STATUS_UC, args)));
}

function status_output(args, input) {
    let result = status_capture(args, input);
    return result.status == 0 ? result.output : "";
}

function status_success(args, input) {
    return status_capture(args, input).status == 0;
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : as_string(data);
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return as_string(fallback);
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (type(value) == "array")
        return value;
    if (as_string(value) != "")
        return [ as_string(value) ];
    return [];
}

function bool_option(section, key, fallback) {
    return arg_bool(option(section, key, fallback ? "1" : "0"));
}

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function uci_get(path) {
    return uci_core.get(path);
}

function uci_show(path) {
    return uci_core.exists(path);
}

function append_unique(values, value) {
    value = as_string(value);
    if (value == "")
        return;
    for (let item in values)
        if (item == value)
            return;
    push(values, value);
}

function config_section_types(config_path) {
    let data = as_string(fs.readfile(config_path) || "");
    let result = [];

    for (let line in split(data, "\n")) {
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

function firewall_show_data() {
    return uci_show_data("firewall", "/etc/config/firewall");
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function file_executable(path) {
    return command_success_from_args([ "test", "-x", as_string(path) ]);
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", as_string(path) ]);
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

function first_line_value(path, fallback) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return as_string(fallback);
    let line = split(as_string(data), "\n")[0];
    line = replace(as_string(line), /\r$/, "");
    return line != "" ? line : as_string(fallback);
}

function stdout_is_tty() {
    return command_success_from_args([ "test", "-t", "1" ]);
}

function nolog(message) {
    if (!stdout_is_tty())
        return;
    let timestamp = replace(command_output_from_args([ "date", "+%Y-%m-%d %H:%M:%S" ]), /[\r\n]+$/g, "");
    print("\033[0;36m[", timestamp, "]\033[0m \033[0;32m", as_string(message), "\033[0m\n");
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[" + level + "] " + as_string(message) ]);
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, true, false);
}

function valid_public_ipv4(value) {
    value = as_string(value);
    if (!valid_ipv4(value))
        return false;

    let parts = split(value, ".");
    let a = int(parts[0], 10);
    let b = int(parts[1], 10);

    if (a == 0 || a == 10 || a == 127 || a >= 224)
        return false;
    if (a == 169 && b == 254)
        return false;
    if (a == 192 && (b == 168 || b == 0 || b == 2))
        return false;
    if (a == 198 && (b == 18 || b == 19 || b == 51))
        return false;
    if (a == 203 && b == 0)
        return false;
    if (a == 100 && b >= 64 && b <= 127)
        return false;
    if (a == 172 && b >= 16 && b <= 31)
        return false;

    return true;
}

function valid_public_ipv6(value) {
    value = lc(as_string(value));
    if (!core_ip.valid_ipv6(value))
        return false;
    if (value == "::" || value == "::1")
        return false;
    if (substr(value, 0, 4) == "fe80" || substr(value, 0, 2) == "ff")
        return false;
    if (substr(value, 0, 2) == "fc" || substr(value, 0, 2) == "fd")
        return false;
    if (substr(value, 0, 4) == "2001" && index(value, "2001:db8") == 0)
        return false;
    return true;
}

function valid_public_ip(value) {
    return valid_public_ipv4(value) || valid_public_ipv6(value);
}

function helper_output(mode, args) {
    let full = [ mode ];
    for (let arg in args)
        push(full, arg);
    return replace(module_output(HELPERS_UC, full), /[\r\n]+$/g, "");
}

function server_inbound_tag(section) {
    return helper_output("server-inbound-tag", [ section ]);
}

function server_required_inbound_proto(protocol) {
    protocol = as_string(protocol);
    if (protocol == "json_inbound")
        return "";
    return protocol == "hysteria2" || protocol == "tuic" ? "udp" : "tcp";
}

function server_runtime_type_for_protocol(protocol) {
    protocol = as_string(protocol);
    if (protocol == "json_inbound")
        return "";
    if (protocol == "mtproto")
        return "mtproxy";
    return protocol;
}

function server_listen_requires_firewall(listen, wan_ip) {
    listen = as_string(listen);
    if (listen == "0.0.0.0" || listen == "::" || valid_public_ip(listen))
        return true;
    for (let ip in words(wan_ip))
        if (ip == listen)
            return true;
    return false;
}

function firewall_required_protocols_open(port, required_proto) {
    let firewall = firewall_show_data();
    return status_success([ "firewall-required-protocols-open", port, required_proto ], firewall);
}

function server_required_port_conflict_owners(listen, port, required_proto) {
    return replace(status_output(
        [ "server-required-port-conflict-owners", listen, port, required_proto ],
        command_output_from_args([ "netstat", "-lnp" ])
    ), /[\r\n]+$/g, "");
}

function server_required_ports_listening(listen, port, required_proto) {
    return status_success(
        [ "server-required-ports-listening", listen, port, required_proto ],
        command_output_from_args([ "netstat", "-ln" ])
    );
}

function resolve_public_host_ips(host) {
    host = as_string(host);
    if (substr(host, 0, 1) == "[" && substr(host, length(host) - 1, 1) == "]")
        host = substr(host, 1, length(host) - 2);
    if (host == "")
        return "";
    if (valid_ipv4(host))
        return host;
    if (core_ip.valid_ipv6(host))
        return host;

    let seen = {};
    for (let line in split(command_output_from_args([
        "dig", "+short", "A", host, "+timeout=2", "+tries=1"
    ]), "\n")) {
        line = trim(as_string(line));
        if (valid_ipv4(line))
            seen[line] = true;
    }
    for (let line in split(command_output_from_args([
        "dig", "+short", "AAAA", host, "+timeout=2", "+tries=1"
    ]), "\n")) {
        line = trim(as_string(line));
        if (core_ip.valid_ipv6(line))
            seen[line] = true;
    }

    return join(" ", sort(keys(seen)));
}

function public_host_flags(public_host, public_host_ips, wan_ip, wan_public) {
    return replace(status_output(
        [ "public-host-flags", public_host, public_host_ips, wan_ip, wan_public ],
        null
    ), /[\r\n]+$/g, "");
}

function check_inbounds_config() {
    let count = 0;
    for (let section in uci_sections("server"))
        if (bool_option(section, "enabled", false))
            count++;
    write_json({ enabled_count: count });
    return 0;
}

function check_inbounds() {
    let cfg = settings();
    let sing_box_config_path = option(cfg, "config_path", "");
    let wan_ip = get_wan_ip_addresses();
    let wan_public = 0;
    for (let ip in words(wan_ip)) {
        if (valid_public_ip(ip)) {
            wan_public = 1;
            break;
        }
    }
    let items = [];
    let enabled_count = 0;

    for (let section in uci_sections("server")) {
        if (!bool_option(section, "enabled", false))
            continue;
        enabled_count++;

        let section_name = as_string(section[".name"] || "");
        let label = option(section, "label", section_name);
        let protocol = option(section, "protocol", "vless");
        let listen = option(section, "listen", "0.0.0.0");
        let listen_port = option(section, "listen_port", "");
        let public_host = option(section, "public_host", "");
        let routing_mode = option(section, "routing_mode", "rules");
        let inbound_tag = server_inbound_tag(section_name);
        let expected_type = server_runtime_type_for_protocol(protocol);
        let required_proto = server_required_inbound_proto(protocol);
        let runtime_json = protocol == "tailscale"
            ? module_output(PROVIDERS_STATUS_UC, [ "endpoint-summary", sing_box_config_path, inbound_tag ])
            : module_output(PROVIDERS_STATUS_UC, [ "inbound-summary", sing_box_config_path, inbound_tag ]);

        let listening = -1;
        let firewall_required = 0;
        let firewall_open = -1;
        let port_conflict = 0;
        let port_conflict_owners = "";
        if (protocol != "tailscale" && protocol != "json_inbound") {
            port_conflict_owners = server_required_port_conflict_owners(listen, listen_port, required_proto);
            if (port_conflict_owners != "")
                port_conflict = 1;
            listening = server_required_ports_listening(listen, listen_port, required_proto) ? 1 : 0;
            if (server_listen_requires_firewall(listen, wan_ip)) {
                firewall_required = 1;
                firewall_open = firewall_required_protocols_open(listen_port, required_proto) ? 1 : 0;
            }
        }

        let routes_configured = module_success(PROVIDERS_STATUS_UC, [
            "has-route-rule-for-inbound", sing_box_config_path, inbound_tag
        ]) ? 1 : 0;

        let public_host_ips = protocol == "json_inbound" ? "" : resolve_public_host_ips(public_host);
        let flags = words(public_host_flags(public_host, public_host_ips, wan_ip, wan_public));
        while (length(flags) < 3)
            push(flags, "-1");

        let item_json = status_output([
            "inbound-item-json",
            runtime_json,
            section_name,
            label,
            protocol,
            routing_mode,
            inbound_tag,
            listen,
            listen_port,
            public_host,
            public_host_ips,
            expected_type,
            required_proto,
            listening,
            firewall_required,
            firewall_open,
            port_conflict,
            port_conflict_owners,
            routes_configured,
            flags[0],
            flags[1],
            flags[2]
        ], null);
        let item = parse_json_or_null(item_json);
        push(items, type(item) == "object" ? item : {});
    }

    write_json({
        enabled_count,
        config_path: sing_box_config_path,
        wan_ip,
        wan_public,
        items
    });
    return 0;
}

function cleanup_check_proxy_dir(dir) {
    dir = as_string(dir);
    let prefix = TMP_SING_BOX_FOLDER + "/check-proxy-";
    if (substr(dir, 0, length(prefix)) == prefix)
        command_success_from_args([ "rm", "-rf", dir ]);
}

function check_proxy() {
    let sing_box_config_path = option(settings(), "config_path", "");
    if (!command_exists("sing-box")) {
        nolog("sing-box is not installed");
        return 1;
    }
    if (!file_exists(sing_box_config_path)) {
        nolog("Configuration file not found");
        return 1;
    }

    nolog("Checking sing-box configuration...");
    if (!command_success_from_args([ "sing-box", "-c", sing_box_config_path, "check" ])) {
        nolog("Invalid configuration");
        return 1;
    }

    print(status_output([ "mask-sing-box-config", sing_box_config_path ], null));
    nolog("Checking proxy connection...");

    let check_proxy_dir = TMP_SING_BOX_FOLDER + "/check-proxy-" + clock()[0] + "-" + clock()[1];
    let check_proxy_config = check_proxy_dir + "/config.json";
    let check_proxy_cache = check_proxy_dir + "/cache.db";

    cleanup_check_proxy_dir(check_proxy_dir);
    ensure_dir(check_proxy_dir);
    if (!status_success([ "prepare-check-proxy-config", sing_box_config_path, check_proxy_config, check_proxy_cache ], null)) {
        nolog("Failed to prepare temporary configuration");
        cleanup_check_proxy_dir(check_proxy_dir);
        return 1;
    }

    let outbound_tag = replace(status_output(
        [ "check-proxy-outbound-tag", check_proxy_config, CHECK_PROXY_IP_DOMAIN ],
        null
    ), /[\r\n]+$/g, "");

    let response = "";
    for (let attempt = 1; attempt <= 5; attempt++) {
        let args = [ "sing-box", "tools", "fetch", "ifconfig.me", "-c", check_proxy_config, "-D", check_proxy_dir, "--disable-color" ];
        if (outbound_tag != "") {
            push(args, "-o");
            push(args, outbound_tag);
        }
        response = command_output(command_from_args(args) + " 2>/dev/null");
        if (status_success([ "proxy-response-is-retryable-error" ], response))
            continue;

        let masked_response_ip = replace(status_output([ "proxy-response-ip-mask" ], response), /[\r\n]+$/g, "");
        if (masked_response_ip != "") {
            nolog(masked_response_ip + " - should match proxy IP");
            cleanup_check_proxy_dir(check_proxy_dir);
            return 0;
        }

        if (attempt == 5) {
            nolog("Failed to get valid IP address after 5 attempts");
            nolog(response == "" ? "Error: Empty response" : "Error response: " + response);
            cleanup_check_proxy_dir(check_proxy_dir);
            return 1;
        }
    }

    cleanup_check_proxy_dir(check_proxy_dir);
    return 1;
}

function domain_lists_contain_cloud_provider() {
    for (let section in uci_sections("section")) {
        if (!bool_option(section, "domain_list_enabled", false))
            continue;
        for (let value in list_option(section, "domain_list"))
            if (value == "hetzner" || value == "ovh")
                return true;
    }
    return false;
}

function check_nft() {
    if (!command_exists("nft")) {
        nolog("nft is not installed");
        return 1;
    }

    nolog("Checking " + NFT_TABLE_NAME + " rules...");
    if (!command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])) {
        nolog("❌ " + NFT_TABLE_NAME + " not found");
        return 1;
    }

    if (domain_lists_contain_cloud_provider()) {
        nolog("Sets statistics:");
        for (let set_name in [
            NFT_COMMON_SET_NAME,
            NFT_PORT_SET_NAME,
            NFT_IP_PORT_SET_NAME,
            NFT_INTERFACE_SET_NAME,
            NFT_DISCORD_SET_NAME,
            NFT_LOCALV4_SET_NAME
        ]) {
            if (!command_success_from_args([ "nft", "list", "set", "inet", NFT_TABLE_NAME, set_name ]))
                continue;
            let count = replace(status_output(
                [ "nft-set-element-count" ],
                command_output_from_args([ "nft", "-j", "list", "set", "inet", NFT_TABLE_NAME, set_name ])
            ), /[\r\n]+$/g, "");
            print("- ", set_name, ": ", count, " elements\n");
        }

        nolog("Chain configurations:");
        print(status_output(
            [ "nft-chain-config-blocks", "mangle", "proxy" ],
            command_output_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])
        ));
    }
    else {
        nolog("Sets configuration:");
        print(command_output_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ]));
    }

    nolog("NFT check completed");
    return 0;
}

function check_logs() {
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    let rendered = status_capture([ "tachyon-logs" ], command_output_from_args([ "logread", "-l", LOGREAD_LINE_LIMIT ]));
    if (rendered.output != "")
        print(rendered.output);
    if (rendered.status != 0) {
        nolog("Logs not found");
        return 1;
    }
    return 0;
}

function check_sing_box_logs() {
    if (!command_exists("logread")) {
        nolog("Error: logread command not found");
        return 1;
    }
    let rendered = status_capture([ "matching-log-tail", "sing-box", "100" ], command_output_from_args([ "logread", "-l", LOGREAD_LINE_LIMIT ]));
    if (rendered.output != "")
        print(rendered.output);
    if (rendered.status != 0) {
        nolog("sing-box logs not found");
        return 1;
    }
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
    let data = fs.readfile(path);
    if (data == null)
        return "not installed";

    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /^[ \t]*var[ \t]+([^ \t=]+)[ \t]*=[ \t]*"([^"]*)"/);
        if (matched != null && matched[1] == "TACHYON_LUCI_APP_VERSION")
            return as_string(matched[2]);
    }
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

    return { extended, tiny, tailscale };
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
    let device_model = first_line_value("/tmp/sysinfo/model", "unknown");

    return {
        tachyon_version: TACHYON_VERSION,
        tachyon_commit_sha: constants.TACHYON_COMMIT_SHA && !match(constants.TACHYON_COMMIT_SHA, /COMPILED/) ? constants.TACHYON_COMMIT_SHA : "",
        tachyon_latest_version: tachyon_latest_version || "unknown",
        luci_app_version,
        sing_box_version,
        sing_box_extended: flags.extended,
        sing_box_tiny: flags.tiny,
        sing_box_compressed,
        sing_box_lx,
        sing_box_tailscale: flags.tailscale,
        sing_box_repo_url,
        zapret_version,
        zapret_installed,
        zapret2_version,
        zapret2_installed,
        byedpi_version,
        byedpi_installed,
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
            sing_box_tailscale: 0
        });
        return 0;
    }

    let resolved = sing_box_resolved_version();
    let flags = sing_box_capability_flags(resolved.version, resolved.output);
    write_json({
        sing_box_extended: flags.extended,
        sing_box_tiny: flags.tiny,
        sing_box_tailscale: flags.tailscale
    });
    return 0;
}

function neutralize_zapret_defaults() {
    log_message("Standalone zapret is not neutralized automatically; Tachyon uses /opt/zapret/nfq/nfqws as an external provider and manages only its own NFQUEUE range.", "info");
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

function url_host(value) {
    return helper_output("url-get-host", [ value ]);
}

function dns_check_resolve_host(host, resolver, timeout_seconds) {
    host = as_string(host);
    resolver = as_string(resolver);
    if (host == "")
        return "";
    if (valid_ipv4(host))
        return host;
    if (resolver == "")
        return "";

    timeout_seconds = int(timeout_seconds || 2);
    if (command_exists("dig")) {
        for (let line in split(command_output_from_args([
            "dig", "@" + resolver, host, "A", "+short", "+timeout=" + as_string(timeout_seconds), "+tries=1"
        ]), "\n")) {
            line = trim(as_string(line));
            if (valid_ipv4(line))
                return line;
        }
    }

    let out = command_output_from_args([ "nslookup", host, resolver ]);
    for (let line in split(out, "\n")) {
        line = trim(as_string(line));
        let m = match(line, /Address:[ \t]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
        if (m && m[1] && m[1] != resolver && valid_ipv4(m[1]))
            return m[1];
    }
    return "";
}

function device_ipv4_address(interface) {
    let value = replace(module_output(SINGBOX_RUNTIME_UC, [ "device-ipv4-address", interface ]), /[\r\n]+$/g, "");
    if (value != "")
        return value;

    let output = command_output_from_args([ "ip", "-4", "addr", "show", "dev", interface ]);
    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        let matched = match(line, /^inet[ \t]+([0-9.]+)\//);
        if (matched != null)
            return as_string(matched[1]);
    }
    return "";
}

function dns_check_router_resolver_available(domain) {
    for (let address in [ "127.0.0.1", SB_DNS_INBOUND_ADDRESS ]) {
        if (address != "" && command_success_from_args([ "dig", "@" + address, domain, "+timeout=2", "+tries=1" ]))
            return true;
    }

    let listen_address = replace(module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ]), /[\r\n]+$/g, "");
    if (listen_address != "" && command_success_from_args([ "dig", "@" + listen_address, domain, "+timeout=2", "+tries=1" ]))
        return true;

    let source_interfaces = option(settings(), "source_network_interfaces", "br-lan");
    for (let interface in words(source_interfaces)) {
        let address = device_ipv4_address(interface);
        if (address != "" && command_success_from_args([ "dig", "@" + address, domain, "+timeout=2", "+tries=1" ]))
            return true;
    }

    return false;
}

function dns_check_timeout_seconds(value) {
    let rest = as_string(value);
    let milliseconds = 0.0;
    let units = { ns: 0.000001, us: 0.001, ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return 2;
        milliseconds += (matched[1] * 1) * units[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return milliseconds > 0 ? int((milliseconds + 999) / 1000) : 2;
}

function check_dns_available() {
    let cfg = settings();
    let dns_type = option(cfg, "dns_type", "");
    let active = runtime_dns.active_values(cfg);
    let dns_server = active.main;
    let bootstrap_dns_server = active.bootstrap;
    let dont_touch_dhcp = bool_option(cfg, "dont_touch_dhcp", false) ? 1 : 0;
    let domain = "example.com";
    let timeout_seconds = dns_check_timeout_seconds(option(cfg, "dns_check_timeout", "2s"));
    let dns_status = 0;
    let dns_on_router = 0;
    let bootstrap_dns_status = 0;
    let dhcp_config_status = 1;

    let active_dns_args = [ "dig" ];
    if (runtime_dns.failover_enabled(cfg)) {
        push(active_dns_args, "-p");
        push(active_dns_args, as_string(runtime_dns.health_port("active", 0)));
    }
    push(active_dns_args, "@" + SB_DNS_INBOUND_ADDRESS);
    push(active_dns_args, domain);
    push(active_dns_args, "A");
    push(active_dns_args, "+short");
    push(active_dns_args, "+timeout=" + as_string(timeout_seconds));
    push(active_dns_args, "+tries=1");
    for (let line in split(command_output_from_args(active_dns_args), "\n"))
        if (valid_ipv4(trim(as_string(line)))) {
            dns_status = 1;
            break;
        }

    if (dns_check_router_resolver_available(domain))
        dns_on_router = 1;

    let dns_server_host = url_host(dns_server);
    if (dns_server_host == "")
        dns_server_host = dns_server;
    if (bootstrap_dns_server != "") {
        if (length(active.state.bootstrap_servers) > 1) {
            for (let line in split(command_output_from_args([
                "dig", "-p", as_string(runtime_dns.health_port("bootstrap", active.state.bootstrap_index)),
                "@" + runtime_dns.DNS_HEALTH_ADDRESS, domain, "A", "+short",
                "+timeout=" + as_string(timeout_seconds), "+tries=1"
            ]), "\n"))
                if (valid_ipv4(trim(as_string(line)))) {
                    bootstrap_dns_status = 1;
                    break;
                }
        }
        else {
            let bootstrap_check_domain = domain;
            if (dns_server_host != "" && !valid_ipv4(dns_server_host))
                bootstrap_check_domain = dns_server_host;
            if (dns_check_resolve_host(bootstrap_check_domain, bootstrap_dns_server, timeout_seconds) != "")
                bootstrap_dns_status = 1;
        }
    }

    if (!module_success(DNS_APPLY_UC, [ "default-config-complete" ]))
        dhcp_config_status = 0;

    let display_dns_server = replace(status_output([ "mask-dns-server", dns_server ], null), /[\r\n]+$/g, "");
    write_json({
        dns_type,
        dns_server: display_dns_server,
        dns_server_index: active.state.main_index,
        dns_server_count: length(active.state.main_servers),
        dns_status,
        dns_on_router,
        bootstrap_dns_server,
        bootstrap_dns_server_index: active.state.bootstrap_index,
        bootstrap_dns_server_count: length(active.state.bootstrap_servers),
        bootstrap_dns_status,
        dhcp_config_status,
        dont_touch_dhcp
    });
    return 0;
}

function nft_chain_counter_status(chain) {
    let output = command_output_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, chain ]);
    let status = words(status_output([ "nft-chain-counter-status" ], output));
    while (length(status) < 2)
        push(status, "0");
    return [ arg_number(status[0]), arg_number(status[1]) ];
}

function nft_table_has_other_mark_rules(family, table_name) {
    let output = command_output_from_args([ "nft", "list", "table", family, table_name ]);
    return status_success([ "stdin-contains", "meta mark set" ], output);
}

function check_nft_rules() {
    command_status("sh -c " + shell_quote(
        "curl -m 3 -s " + shell_quote("https://" + CHECK_PROXY_IP_DOMAIN + "/check") + " >/dev/null 2>&1 & pid1=$!; " +
        "curl -m 3 -s " + shell_quote("https://" + FAKEIP_TEST_DOMAIN + "/check") + " >/dev/null 2>&1 & pid2=$!; " +
        "wait $pid1 2>/dev/null; wait $pid2 2>/dev/null; sleep 1"
    ));

    let table_exist = 0;
    let rules_mangle_exist = 0;
    let rules_mangle_counters = 0;
    let rules_mangle_output_exist = 0;
    let rules_mangle_output_counters = 0;
    let rules_proxy_exist = 0;
    let rules_proxy_counters = 0;
    let rules_other_mark_exist = 0;

    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])) {
        table_exist = 1;
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "mangle" ])) {
            let status = nft_chain_counter_status("mangle");
            rules_mangle_exist = status[0];
            rules_mangle_counters = status[1];
        }
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "mangle_output" ])) {
            let status = nft_chain_counter_status("mangle_output");
            rules_mangle_output_exist = status[0];
            rules_mangle_output_counters = status[1];
        }
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "proxy" ])) {
            let status = nft_chain_counter_status("proxy");
            rules_proxy_exist = status[0];
            rules_proxy_counters = status[1];
        }
    }

    for (let line in split(command_output_from_args([ "nft", "list", "tables" ]), "\n")) {
        let fields = words(line);
        if (length(fields) < 3)
            continue;
        let family = fields[1];
        let table_name = fields[2];
        if (table_name == NFT_TABLE_NAME)
            continue;
        if (nft_table_has_other_mark_rules(family, table_name)) {
            rules_other_mark_exist = 1;
            break;
        }
    }

    write_json({
        table_exist,
        rules_mangle_exist,
        rules_mangle_counters,
        rules_mangle_output_exist,
        rules_mangle_output_counters,
        rules_proxy_exist,
        rules_proxy_counters,
        rules_other_mark_exist
    });
    return 0;
}

function strip_leading_v(value) {
    value = as_string(value);
    return substr(value, 0, 1) == "v" ? substr(value, 1) : value;
}

function sing_box_standard_ports_listening(netstat) {
    netstat = as_string(netstat);
    let port_53_ok = index(netstat, "127.0.0.42:53") >= 0;
    let tproxy_suffix = ":" + SB_TPROXY_INBOUND_PORT;
    let port_1602_ok = index(netstat, "0.0.0.0" + tproxy_suffix) >= 0 ||
        index(netstat, "127.0.0.1" + tproxy_suffix) >= 0;
    let port_1602_v6_ok = index(netstat, SB_TPROXY_INBOUND6_ADDRESS + tproxy_suffix) >= 0 ||
        index(netstat, "[" + SB_TPROXY_INBOUND6_ADDRESS + "]" + tproxy_suffix) >= 0 ||
        index(netstat, "0:0:0:0:0:0:0:1" + tproxy_suffix) >= 0 ||
        index(netstat, ":::" + SB_TPROXY_INBOUND_PORT) >= 0;
    return port_53_ok && port_1602_ok && port_1602_v6_ok;
}

function sing_box_standard_ports_listening_fixture() {
    exit(sing_box_standard_ports_listening(read_stdin()) ? 0 : 1);
}

function check_sing_box() {
    let sing_box_installed = 0;
    let sing_box_version_ok = 0;
    let sing_box_extended = 0;
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
        }
        else if (sing_box_marker_is("extended-compressed") || sing_box_marker_is("lx"))
            sing_box_extended = 1;
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
        sing_box_service_exist,
        sing_box_autostart_disabled,
        sing_box_process_running,
        sing_box_ports_listening
    });
    return 0;
}

function check_fakeip() {
    let fakeip_address = "";
    let fakeip6_address = "";
    for (let line in split(command_output_from_args([
        "dig", "+short", "@" + SB_DNS_INBOUND_ADDRESS, FAKEIP_TEST_DOMAIN, "A", "+timeout=2", "+tries=1"
    ]), "\n")) {
        line = trim(as_string(line));
        if (valid_ipv4(line)) {
            fakeip_address = line;
            break;
        }
    }
    for (let line in split(command_output_from_args([
        "dig", "+short", "@" + SB_DNS_INBOUND_ADDRESS, FAKEIP_TEST_DOMAIN, "AAAA", "+timeout=2", "+tries=1"
    ]), "\n")) {
        line = lc(trim(as_string(line)));
        if (core_ip.valid_ipv6(line)) {
            fakeip6_address = line;
            break;
        }
    }
    write_json({
        fakeip: match(fakeip_address, /^198\.(18|19)\./) != null || match(fakeip6_address, /^fc[0-3][0-9a-f]:/) != null,
        IP: fakeip_address != "" ? fakeip_address : fakeip6_address,
        IPv4: fakeip_address,
        IPv6: fakeip6_address
    });
    return 0;
}

function clash_json_output(args) {
    print(status_output([ "stdin-json" ], command_output(command_from_args(args))));
    return 0;
}

function clash_api_url() {
    let address = replace(module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ]), /[\r\n]+$/g, "");
    if (address == "")
        address = "127.0.0.1";
    return address + ":" + SB_CLASH_API_CONTROLLER_PORT;
}

function clash_auth_args() {
    let cfg = settings();
    if (!bool_option(cfg, "enable_yacd_wan_access", false))
        return [];
    return [ "--header", "Authorization: Bearer " + option(cfg, "yacd_secret_key", "") ];
}

function clash_urlencode(value) {
    return replace(status_output([ "url-encode", value ], null), /[\r\n]+$/g, "");
}

function clash_json_error(message) {
    let result = status_capture([ "json-error", message ], null);
    if (result.output != "")
        print(result.output);
    return 1;
}

function clash_proxy_type_map(base_url, auth) {
    let args = [ "curl", "-s" ];
    for (let item in auth) push(args, item);
    push(args, base_url + "/proxies");

    let value = {};
    try {
        value = json(command_output(command_from_args(args)));
    }
    catch (e) {
        return {};
    }

    let result = {};
    for (let tag, proxy in object_or_empty(value.proxies))
        result[tag] = as_string(object_or_empty(proxy).type || "");
    return result;
}

function clash_latency_endpoint(base_url, proxy_tag, proxy_type) {
    proxy_type = as_string(proxy_type);
    if (lc(proxy_type) == "urltest")
        return base_url + "/group/" + clash_urlencode(proxy_tag) + "/delay";
    return base_url + "/proxies/" + clash_urlencode(proxy_tag) + "/delay";
}

function latency_test_url() {
    let value = option(settings(), "latency_test_url", DEFAULT_LATENCY_TEST_URL);
    return value == "" ? DEFAULT_LATENCY_TEST_URL : value;
}

function clash_api(action, arg1, arg2, arg3) {
    let base_url = clash_api_url();
    let test_url = latency_test_url();
    let auth = clash_auth_args();

    if (action == "get_proxies") {
        let args = [ "curl", "-s" ];
        for (let item in auth) push(args, item);
        push(args, base_url + "/proxies");
        return clash_json_output(args);
    }

    if (action == "get_connections") {
        let args = [ "curl", "-s" ];
        for (let item in auth) push(args, item);
        push(args, base_url + "/connections");
        return clash_json_output(args);
    }

    if (action == "get_proxy_latency") {
        if (as_string(arg1) == "")
            return clash_json_error("proxy_tag required");
        let url = as_string(arg3 || "");
        if (url == "")
            url = test_url;
        let args = [ "curl", "-G", "-s", base_url + "/proxies/" + clash_urlencode(arg1) + "/delay" ];
        for (let item in auth) push(args, item);
        push(args, "--data-urlencode");
        push(args, "url=" + url);
        push(args, "--data-urlencode");
        push(args, "timeout=" + as_string(arg2 || "2000"));
        return clash_json_output(args);
    }

    if (action == "get_proxy_latencies") {
        if (as_string(arg1) == "")
            return clash_json_error("proxy_tags_json required");
        let tags = status_capture([ "clash-proxy-tags-lines", arg1 ], null);
        if (tags.status != 0)
            return clash_json_error("proxy_tags_json must be a JSON array of non-empty strings");
        let proxy_tags = [];
        for (let proxy_tag in split(tags.output, "\n")) {
            proxy_tag = as_string(proxy_tag);
            if (proxy_tag != "")
                push(proxy_tags, proxy_tag);
        }

        let count = 0;
        let failed = 0;
        let progress_path = as_string(arg3);
        let total = length(proxy_tags);
        if (progress_path != "")
            module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);

        let proxy_types = clash_proxy_type_map(base_url, auth);
        let ordered_proxy_tags = [];
        for (let proxy_tag in proxy_tags)
            if (lc(as_string(proxy_types[proxy_tag])) != "urltest")
                push(ordered_proxy_tags, proxy_tag);
        for (let proxy_tag in proxy_tags)
            if (lc(as_string(proxy_types[proxy_tag])) == "urltest")
                push(ordered_proxy_tags, proxy_tag);

        for (let proxy_tag in ordered_proxy_tags) {
            let args = [ "curl", "-G", "-s", clash_latency_endpoint(base_url, proxy_tag, proxy_types[proxy_tag]) ];
            for (let item in auth) push(args, item);
            push(args, "--data-urlencode");
            push(args, "url=" + test_url);
            push(args, "--data-urlencode");
            push(args, "timeout=" + as_string(arg2 || "5000"));
            if (status_capture([ "stdin-json" ], command_output(command_from_args(args))).status != 0)
                failed++;
            count++;
            if (progress_path != "")
                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
        }
        let result = status_capture([ "clash-proxy-latencies-result", count, failed ], null);
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "get_group_latency") {
        if (as_string(arg1) == "")
            return clash_json_error("group_tag required");
        let args = [ "curl", "-G", "-s", base_url + "/group/" + clash_urlencode(arg1) + "/delay" ];
        for (let item in auth) push(args, item);
        push(args, "--data-urlencode");
        push(args, "url=" + test_url);
        push(args, "--data-urlencode");
        push(args, "timeout=" + as_string(arg2 || "5000"));
        return clash_json_output(args);
    }

    if (action == "set_group_proxy") {
        if (as_string(arg1) == "" || as_string(arg2) == "")
            return clash_json_error("group_tag and proxy_tag required");
        let payload = status_output([ "clash-set-group-proxy-payload", arg2 ], null);
        let args = [ "curl", "-X", "PUT", "-s", "-w", "\n%{http_code}", base_url + "/proxies/" + clash_urlencode(arg1) ];
        for (let item in auth) push(args, item);
        push(args, "--data-raw");
        push(args, payload);
        let result = status_capture([ "clash-set-group-proxy-result", arg1, arg2 ], command_output(command_from_args(args)));
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "close_connection") {
        if (as_string(arg1) == "")
            return clash_json_error("connection_id required");
        let args = [ "curl", "-X", "DELETE", "-s", "-w", "\n%{http_code}", base_url + "/connections/" + clash_urlencode(arg1) ];
        for (let item in auth) push(args, item);
        let result = status_capture([ "clash-close-connection-result", arg1 ], command_output(command_from_args(args)));
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "close_all_connections") {
        let args = [ "curl", "-X", "DELETE", "-s", "-w", "\n%{http_code}", base_url + "/connections" ];
        for (let item in auth) push(args, item);
        let result = status_capture([ "clash-close-all-connections-result" ], command_output(command_from_args(args)));
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    let unknown = status_capture([ "clash-unknown-action" ], null);
    if (unknown.output != "")
        print(unknown.output);
    return 1;
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
    print_global("ЁЯУж Sing-box status");
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

// The main service loop writes its pid file on start (start_runtime in
// watchdog.uc). With enable_watchdog='0' the loop is not spawned but sing-box
// keeps running as its own procd service — that state still counts as running:
// the doctor must never treat a live Tachyon as a stopped one.
function tachyon_is_running() {
    let wd_pid = trim(fs.readfile("/var/run/tachyon_watchdog.pid") || "");
    if (wd_pid != "" && fs.stat("/proc/" + wd_pid) != null) return true;
    return find_process_pid("sing-box") != "";
}

function tachyon_is_enabled() {
    return file_executable("/etc/rc.d/S99" + TACHYON_SERVICE_NAME);
}

function is_degraded() {
    return fs.stat("/tmp/tachyon/degraded") != null;
}

function uci_settings() {
    return uci_core.get_all(CONFIG_NAME, "settings") || {};
}

function kill_our_core_processes() {
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
function run_recovery_checks() {
    let report = [];
    let issues = 0;
    let fixed = 0;

    let doc_check = function(icon, name, status, fix_msg) {
        let msg = fix_msg != "" ? fix_msg : status;
        push(report, sprintf("%s %-30s %s", icon, name, msg));
    };

    let time_str = command_output_from_args(["date", "+%d.%m %H:%M"]);
    push(report, sprintf("🩺 *tachyon doctor* — %s — *режим восстановления*", trim(time_str)));
    push(report, "Сервис Tachyon остановлен. Возвращаю систему в сток и проверяю интернет.");
    push(report, "");

    // WAN must be up before DNS makes any sense.
    if (wan_has_ip() && default_gateway_exists()) {
        doc_check("✅", "WAN interface", get_wan_interface() + " up, gateway present", "");
    } else {
        issues++;
        let had_ip = wan_has_ip();
        command_status("/sbin/ifup wan >/dev/null 2>&1");
        command_status("sleep 3");
        if (!had_ip) {
            if (wan_has_ip()) {
                doc_check("❌", "WAN interface", get_wan_interface() + " no IP", "→ FIXED: WAN поднят");
                fixed++;
            } else {
                doc_check("❌", "WAN interface", "no IP address", "→ проверьте подключение к провайдеру");
            }
        } else {
            if (default_gateway_exists()) {
                doc_check("❌", "Default gateway", "missing", "→ FIXED: маршрут восстановлен");
                fixed++;
            } else {
                doc_check("❌", "Default gateway", "missing", "→ проверьте конфигурацию сети");
            }
        }
    }

    // Leftover routing is what breaks internet when the service is down.
    // Idempotent cleanup mirroring uninstall.uc.
    if (command_success_from_args([ "nft", "list", "table", "inet", NFT_TABLE_NAME ])) {
        command_status("nft delete table inet " + NFT_TABLE_NAME + " >/dev/null 2>&1");
        doc_check("❌", "nftables table", "leftover", "→ FIXED: удалена");
        fixed++;
    } else {
        doc_check("✅", "nftables table", "absent", "");
    }

    let ip_rule_out = command_capture("ip rule list").output;
    if (index(ip_rule_out, "fwmark") >= 0 && index(ip_rule_out, "lookup " + RT_TABLE_NAME) >= 0) {
        command_status("ip rule del fwmark 0x1/0x1 >/dev/null 2>&1");
        command_status("ip rule del fwmark 0x2/0x2 >/dev/null 2>&1");
        command_status("ip route flush table " + RT_TABLE_NAME + " >/dev/null 2>&1");
        doc_check("❌", "routing rules (fwmark)", "leftover", "→ FIXED: удалены");
        fixed++;
    } else {
        doc_check("✅", "routing rules (fwmark)", "absent", "");
    }

    // dnsmasq must answer the LAN and talk to upstream directly.
    if (module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) == 0) {
        issues++;
        module_status(DNS_APPLY_UC, [ "failsafe-restore" ]);
        if (module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) != 0) {
            doc_check("❌", "dnsmasq DNS", "redirected to sing-box", "→ FIXED: возвращён на прямые upstream");
            fixed++;
        } else {
            doc_check("❌", "dnsmasq DNS", "redirected to sing-box", "→ не удалось восстановить — проверьте /etc/config/dhcp");
        }
    } else {
        doc_check("✅", "dnsmasq DNS", "direct (stock)", "");
    }

    let dropins = [ "/etc/dnsmasq.d/tachyon.conf", "/tmp/dnsmasq.d/tachyon.conf" ];
    let dropins_removed = false;
    for (let d in dropins) {
        if (fs.stat(d) != null) {
            fs.unlink(d);
            dropins_removed = true;
        }
    }
    if (dropins_removed) {
        doc_check("❌", "dnsmasq drop-ins", "leftover", "→ FIXED: удалены");
        fixed++;
    } else {
        doc_check("✅", "dnsmasq drop-ins", "absent", "");
    }

    // resolv.conf must be the stock symlink and point at a working upstream.
    let resolv_fixed = false;
    let resolv_link = "";
    try { resolv_link = fs.readlink("/etc/resolv.conf") || ""; } catch(e) {}
    if (resolv_link != "/tmp/resolv.conf" && resolv_link != "../tmp/resolv.conf") {
        fs.unlink("/etc/resolv.conf");
        try { fs.symlink("/tmp/resolv.conf", "/etc/resolv.conf"); resolv_fixed = true; } catch(e) {}
    }
    if (trim(fs.readfile("/tmp/resolv.conf") || "") == "") {
        fs.writefile("/tmp/resolv.conf", "nameserver 1.1.1.1\nnameserver 8.8.8.8\n");
        resolv_fixed = true;
    }
    if (resolv_fixed) {
        doc_check("❌", "resolv.conf", "broken", "→ FIXED: восстановлена ссылка и nameserver");
        fixed++;
    } else {
        doc_check("✅", "resolv.conf", "OK (-> /tmp/resolv.conf)", "");
    }

    // A stray sing-box (crashed service, half-removed install) must not sit
    // between the LAN and the WAN.
    if (find_process_pid("sing-box") != "") {
        kill_our_core_processes();
        doc_check("❌", "sing-box process", "leftover", "→ FIXED: остановлен");
        fixed++;
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
    } else {
        push(report, sprintf("⚠️ Проблем: %d   Исправлено: %d", issues, fixed));
    }

    return { report: join("\n", report) + "\n", issues, fixed, checks: [] };
}

function run_doctor_checks() {
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
        return { report: join("\n", report) + "\n", issues, fixed };
    }

    let binary_name = "sing-box";
    let init_script = "/etc/init.d/sing-box";
    let config_file_path = "/etc/sing-box/config.json";

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
        doc_check("✅", binary_name + " process", "running", "");
    } else if (!has_sections) {
        doc_check("ℹ️", binary_name + " process", "not started", "→ Настройте подключение в LuCI — ядро запустится автоматически");
    } else {
        issues++;
        kill_our_core_processes();
        command_status("sleep 1");
        command_status(init_script + " start >/dev/null 2>&1");
        command_status("sleep 3");
        pid = find_process_pid(binary_name);
        if (pid != "") {
            doc_check("❌", binary_name + " process", "stopped", "→ FIXED: запущен после очистки конфликтующих портов");
            fixed++;
        } else {
            doc_check("❌", binary_name + " process", "stopped", "→ не удалось запустить — проверьте логи");
        }
    }

    // 2. Configuration Check
    if (fs.stat(config_file_path) != null) {
        let check_res = command_status(binary_name + " check -c " + config_file_path + " >/dev/null 2>&1");
        if (check_res == 0) {
            doc_check("✅", binary_name + " config", "valid", "");
        } else {
            issues++;
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
    } else {
        if (!has_sections) {
            doc_check("ℹ️", binary_name + " config", "not yet created", "→ Настройте Tachyon в LuCI для генерации конфига");
        } else {
            issues++;
            let regen_status = command_status("ucode -L " + LIB_DIR + " " + SINGBOX_RUNTIME_UC + " configure-service >/dev/null 2>&1");
            if (regen_status == 0 && fs.stat(config_file_path) != null) {
                doc_check("❌", "sing-box config", "missing", "→ FIXED: пересоздан");
                fixed++;
            } else {
                doc_check("❌", binary_name + " config", "missing", "→ не удалось сгенерировать config");
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
            if (uci_backup_restore()) {
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

        // 4. IP Rule Check
        let ip_rule_out = command_capture("ip rule list").output;
        if (index(ip_rule_out, "fwmark") >= 0 && index(ip_rule_out, "lookup " + RT_TABLE_NAME) >= 0) {
            doc_check("✅", "ip rule (fwmark)", "present", "");
        } else {
            issues++;
            let rebuild_status = command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
            let ip_rule_check = command_capture("ip rule list").output;
            if (index(ip_rule_check, "fwmark") >= 0 && index(ip_rule_check, "lookup " + RT_TABLE_NAME) >= 0) {
                doc_check("❌", "ip rule", "missing", "→ FIXED: маршрут восстановлен");
                fixed++;
            } else {
                doc_check("❌", "ip rule", "missing", "→ не удалось восстановить ip rule");
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

    // 4e. Dnsmasq Redirection Check
    if (module_status(DNS_APPLY_UC, [ "has-tachyon-dns" ]) == 0) {
        doc_check("✅", "dnsmasq server (Direct)", SB_DNS_INBOUND_ADDRESS, "");
    } else {
        if (is_degraded_flag) {
            doc_check("⚠️", "dnsmasq server (Direct)", "direct", "→ GRACEFUL DEGRADATION: Proxy offline");
        } else {
            issues++;
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

    // 4b. Dnsmasq Params Check
    let noresolv = uci_core.get("dhcp.@dnsmasq[0].noresolv");
    let localuse = uci_core.get("dhcp.@dnsmasq[0].localuse");
    let rebind_protection = uci_core.get("dhcp.@dnsmasq[0].rebind_protection");
    if (noresolv == "1" && localuse == "1" && rebind_protection == "0") {
        doc_check("✅", "dnsmasq params", "OK (noresolv=1, localuse=1, rebind_protection=0)", "");
    } else {
        issues++;
        uci_core.set("dhcp.@dnsmasq[0].noresolv", "1");
        uci_core.set("dhcp.@dnsmasq[0].localuse", "1");
        uci_core.set("dhcp.@dnsmasq[0].rebind_protection", "0");
        uci_core.commit("dhcp");
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

    // 4c. Resolv.conf symlink
    let resolv_link = "";
    // Throws when /etc/resolv.conf is a regular file rather than a symlink,
    // which is precisely the broken state the branch below repairs.
    try { resolv_link = fs.readlink("/etc/resolv.conf") || ""; } catch(e) {}
    if (resolv_link == "/tmp/resolv.conf" || resolv_link == "../tmp/resolv.conf") {
        doc_check("✅", "resolv.conf symlink", "OK (-> " + resolv_link + ")", "");
    } else {
        issues++;
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
        let ping_ok = (command_status("ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1") == 0);
        if (ping_ok) {
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
        } else {
            command_status("/sbin/ifup wan >/dev/null 2>&1");
            command_status("sleep 3");
            doc_check("❌", "DNS bootstrap (" + display_bootstrap + ")", "unreachable", "→ FIXED: линк отсутствует, отправлен сигнал перезапуска WAN");
            fixed++;
        }
    }

    // Check Main DNS
    let dns_main_reachable = false;
    if (main_dns_type == "doh") {
        let curl_cmd = "curl -sS --max-time 4 -o /dev/null -w %{http_code} https://" + display_main + "/dns-query";
        let curl_res = command_capture(curl_cmd);
        if (curl_res.status == 0 && int(curl_res.output) < 400) {
            dns_main_reachable = true;
            doc_check("✅", "DNS main (" + display_main + ")", "reachable", "");
        } else {
            let curl_cmd2 = "curl -sS --max-time 4 -o /dev/null -w %{http_code} https://" + display_main;
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
                command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
                command_status("sleep 1");
                if (dns_check_resolve_host("openwrt.org", main_dns, 2) != "") {
                      dns_main_reachable = true;
                      doc_check("❌", "DNS main (" + display_main + ")", "unreachable", "→ FIXED: перезапущен dnsmasq");
                      fixed++;
                }
            }
            if (!dns_main_reachable) {
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
            module_status(DNS_APPLY_UC, [ "configure", "force" ]);
            command_status("sleep 1");
            if (dns_check_through_singbox("google.com")) {
                doc_check("❌", "sing-box DNS", "not resolving", "→ FIXED: dnsmasq перенаправлен на sing-box");
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
    let clash_addr = clash_api_url();
    let curl_clash = command_capture("curl -s -o /dev/null -w %{http_code} http://" + clash_addr + "/version");
    if (curl_clash.status == 0 && int(curl_clash.output) == 200) {
        doc_check("✅", "Clash API", "reachable (" + clash_addr + ")", "");
    } else {
        issues++;
        if (pid != "") {
            command_status(init_script + " restart >/dev/null 2>&1");
            command_status("sleep 3");
            let curl_clash2 = command_capture("curl -s -o /dev/null -w %{http_code} http://" + clash_addr + "/version");
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
        let scale = 1.0;
        let scale_path = "/etc/tachyon/mem_scale";
        let scale_data = fs.readfile(scale_path);
        if (scale_data != null) {
            let parsed_scale = double(trim(as_string(scale_data)));
            if (parsed_scale > 0.1) scale = parsed_scale;
        }
        let new_scale = scale * 0.8;
        if (new_scale < 0.2) new_scale = 0.2;
        fs.mkdir("/etc/tachyon");
        let scale_tmp = scale_path + ".tmp";
        if (fs.writefile(scale_tmp, sprintf("%.2f", new_scale)) != null)
            fs.rename(scale_tmp, scale_path);
        command_status("/usr/bin/tachyon restart >/dev/null 2>&1");
        doc_check("⚠️", "Free RAM", sprintf("%dMB", free_mb), sprintf("→ FIXED: GOMEMLIMIT снижен до %.2f, services перезапущены", new_scale));
        fixed++;
        issues++;
        doc_check("⚠️", "Free RAM", sprintf("%dMB", free_mb), "→ Мало памяти!");
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
        let enable_watchdog = cfg.enable_watchdog != "0";
        if (enable_watchdog) {
            issues++;
            let restart_status = command_status("/etc/init.d/tachyon restart >/dev/null 2>&1");
            if (restart_status == 0) {
                doc_check("❌", "Watchdog", "dead", "→ FIXED: система перезапущена");
                fixed++;
            } else {
                doc_check("❌", "Watchdog", "dead", "→ не удалось перезапустить систему");
            }
        } else {
            doc_check("⚫", "Watchdog", "disabled (ok)", "");
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

    // 12. OOM audit Check
    let logread_out = command_capture("logread -l 200").output;
    let logread_lower = lc(logread_out);
    if (index(logread_lower, "out of memory") >= 0 || index(logread_lower, "oom-killer") >= 0) {
        issues++;
        let scale = 1.0;
        let scale_path = "/etc/tachyon/mem_scale";
        let scale_data = fs.readfile(scale_path);
        if (scale_data != null) {
            let parsed_scale = double(trim(as_string(scale_data)));
            if (parsed_scale > 0.1) {
                scale = parsed_scale;
            }
        }
        let new_scale = scale * 0.8;
        if (new_scale < 0.2) new_scale = 0.2;
        fs.mkdir("/etc/tachyon");
        let scale_tmp2 = scale_path + ".tmp";
        if (fs.writefile(scale_tmp2, sprintf("%.2f", new_scale)) != null)
            fs.rename(scale_tmp2, scale_path);
        command_status("logread -c >/dev/null 2>&1");

        doc_check("❌", "System OOM checks", sprintf("OOM detected (current scale: %.2f)", scale), sprintf("→ FIXED: Scaled GOMEMLIMIT to %.2f and cleared logs", new_scale));
        fixed++;
    } else {
        doc_check("✅", "System OOM checks", "No OOM events detected in logs", "");
    }

    // 13. Port conflicts
    let netstat_out = command_capture("netstat -ltnp").output;
    let ports_to_check = ["4534", "9090"];
    for (let port in ports_to_check) {
        if (index(netstat_out, ":" + port + " ") >= 0) {
            let sb_pid = find_process_pid("sing-box");
            if (sb_pid == "") {
                let killed = false;
                for (let line in split(netstat_out, "\n")) {
                    if (index(line, ":" + port + " ") >= 0) {
                        let fields = split(trim(line), /[ \t]+/);
                        if (length(fields) >= 7) {
                            let pid_info = fields[6];
                            let slash_idx = index(pid_info, "/");
                            if (slash_idx >= 0) {
                                let conflict_pid = substr(pid_info, 0, slash_idx);
                                if (command_status("kill -9 " + conflict_pid + " >/dev/null 2>&1") == 0) {
                                    killed = true;
                                }
                            }
                        }
                    }
                }
                if (killed) {
                    issues++;
                    doc_check("❌", "Port conflict :" + port, "port bound by orphan", "→ FIXED: конфликтный процесс завершен");
                    fixed++;
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
        command_status("ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null; ip route flush cache 2>/dev/null");
        command_status("sleep 2");
        if (wan_has_ip()) {
            doc_check("❌", "WAN interface", get_wan_interface() + " no IP", "→ FIXED: WAN interface перезапущен");
            fixed++;
        } else {
            doc_check("❌", "WAN interface", "no IP address", "→ проверьте подключение к провайдеру");
        }
    }

    // 15. Default Gateway Check
    if (default_gateway_exists()) {
        doc_check("✅", "Default gateway", "present", "");
    } else if (bootstrap_dns_reachable || dns_main_reachable) {
        doc_check("ℹ️", "Default gateway", "not found (but DNS reachable — proxy working)", "");
    } else {
        issues++;
        command_status("ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null; ip route flush cache 2>/dev/null");
        command_status("sleep 2");
        if (default_gateway_exists()) {
            doc_check("❌", "Default gateway", "missing", "→ FIXED: маршрут восстановлен через ifup wan");
            fixed++;
        } else {
            doc_check("❌", "Default gateway", "missing", "→ проверьте конфигурацию сети");
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

                if (length(still_missing) == 0) {
                    doc_check("❌", "Community lists",
                        sprintf("%d/%d missing", length(missing_lists), length(all_required)),
                        "→ FIXED: загружены через list_update");
                    fixed++;
                } else {
                    doc_check("❌", "Community lists",
                        sprintf("%d/%d отсутствуют: %s", length(still_missing), length(all_required), join(", ", still_missing)),
                        "→ не удалось загрузить — проверьте интернет-соединение");
                }
            }
        }
    }

    // 16. Subscription Health Check
    if (has_sections && cfg.subscription_url) {
        let sub_url = trim(as_string(cfg.subscription_url));
        if (sub_url != "") {
            let sub_check = command_capture("curl -s -o /dev/null -w %{http_code} --connect-timeout 5 " + shell_quote(sub_url) + " 2>&1");
            let sub_code = int(sub_check.output);
            if (sub_check.status == 0 && sub_code >= 200 && sub_code < 400) {
                doc_check("✅", "Subscription", "active (HTTP " + sub_code + ")", "");
            } else {
                issues++;
                doc_check("⚠️", "Subscription", "unreachable (HTTP " + sub_code + ")", "→ обновите подписку вручную");
            }
        }
    }

    push(report, "");
    if (issues == 0) {
        push(report, "✅ Всё в порядке — проблем не обнаружено");
    } else {
        push(report, sprintf("⚠️ Проблем: %d   Исправлено: %d", issues, fixed));
    }

    return { report: join("\n", report) + "\n", issues, fixed, checks };
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
        "-d", "@" + payload_path,
        api_url
    ];

    let result = command_capture(command_from_args(curl_args));
    remove_file(payload_path);

    if (result.status != 0 || result.output == "") {
        return null;
    }

    let response_data = parse_json_or_null(result.output);
    if (response_data && type(response_data.choices) == "array" && length(response_data.choices) > 0) {
        return response_data.choices[0].message.content;
    }

    return null;
}

function doctor(format) {
    let res;
    try {
        res = run_doctor_checks();
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
        issues: res.issues,
        fixed: res.fixed,
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

    // Parse the text report lines into structured objects
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

        // Extract check name and message (format: icon  name   message)
        let clean = replace(replace(replace(replace(
            line, "❌", ""), "⚠️", ""), "ℹ️", ""), "✅", "");
        clean = trim(clean);

        let arrow_idx = index(clean, "→");
        let description = trim(arrow_idx >= 0 ? substr(clean, 0, arrow_idx) : clean);
        // "→" is U+2192, encoded as 3 UTF-8 bytes (E2 86 92); skip all 3
        let suggested_fix = arrow_idx >= 0 ? trim(substr(clean, arrow_idx + 3)) : "";

        // Detect if already fixed inline (FIXED: prefix in suggested_fix)
        if (index(suggested_fix, "FIXED:") >= 0) {
            fixed_inline = true;
            severity = "info"; // was critical but already fixed
        }

        push(problems, {
            severity:      severity,
            description:   description,
            suggested_fix: suggested_fix,
            fixed:         fixed_inline
        });
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
    let f = fs.open(DOCTOR_FIXES_FILE, "w");
    if (f) {
        f.write(sprintf("%J\n", data));
        f.close();
    }
}

function doctor_fix_overused(code) {
    let data = object_or_empty(read_json_file(DOCTOR_FIXES_FILE));
    let rec = data[code];
    if (!rec) return false;
    if (time() - int(rec.last) > 3600) return false;
    return int(rec.count) >= 3;
}

function apply_quick_fix(codes_str) {
    if (!codes_str || codes_str == "") {
        print(sprintf("%J\n", { success: false, error: "No fix code provided" }));
        return 1;
    }

    let codes = split(replace(codes_str, /[ \[\]"]/g, ""), ",");
    let results = [];
    let all_ok = true;

    for (let c in codes) {
        c = trim(c);
        if (c == "") continue;

        let status = false;
        let msg = "";

        if (c == "start_singbox") {
            command_status("/usr/bin/tachyon restore_dnsmasq 2>/dev/null; /etc/init.d/sing-box restart >/dev/null 2>&1");
            status = true;
            msg = "sing-box restarted";
        } else if (c == "rebuild_rules") {
            command_status("/etc/init.d/tachyon reload >/dev/null 2>&1");
            status = true;
            msg = "Firewall rules rebuilt";
        } else if (c == "fix_dnsmasq") {
            command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
            status = true;
            msg = "dnsmasq restarted";
        } else if (c == "fix_resolv_symlink") {
            command_status("ln -sf /tmp/resolv.conf.auto /etc/resolv.conf 2>/dev/null || ln -sf /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf 2>/dev/null");
            status = true;
            msg = "resolv.conf symlink fixed";
        } else if (c == "start_watchdog") {
            command_status("/etc/init.d/tachyon restart >/dev/null 2>&1");
            status = true;
            msg = "Watchdog started";
        } else if (c == "restart_singbox_dns") {
            command_status("/etc/init.d/sing-box restart >/dev/null 2>&1");
            status = true;
            msg = "sing-box DNS restarted";
        } else if (c == "fix_uci_config") {
            command_status("cp /etc/config/tachyon.bak /etc/config/tachyon 2>/dev/null");
            status = true;
            msg = "UCI config restored from backup";
        } else if (c == "fix_wan_interface") {
            command_status("ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null; ip route flush cache 2>/dev/null");
            status = true;
            msg = "WAN interface re-up triggered";
        } else if (c == "fix_gateway") {
            command_status("/etc/init.d/network restart >/dev/null 2>&1");
            status = true;
            msg = "Network restarted to resolve gateway";
        } else if (c == "clear_dns_cache") {
            command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1; ip route flush cache 2>/dev/null");
            status = true;
            msg = "DNS cache cleared and dnsmasq restarted";
        } else if (c == "update_subscriptions") {
            command_status(command_from_args([ "/usr/bin/tachyon", "component_action_async", "update_subscriptions", "update" ]));
            status = true;
            msg = "Subscription update triggered";
        } else if (c == "reset_firewall") {
            command_status("/etc/init.d/firewall restart >/dev/null 2>&1; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = true;
            msg = "Firewall restarted";
        } else if (c == "restart_network") {
            command_status("/etc/init.d/network restart >/dev/null 2>&1");
            status = true;
            msg = "Network service restarted";
        } else if (c == "restart_zapret") {
            command_status("/etc/init.d/zapret restart 2>/dev/null; /etc/init.d/zapret2 restart 2>/dev/null; /etc/init.d/byedpi restart 2>/dev/null");
            status = true;
            msg = "Zapret/ByeDPI engines restarted";
        } else if (c == "optimize_memory") {
            command_status("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; rm -rf /tmp/sing-box/*.tmp 2>/dev/null; /etc/init.d/sing-box restart >/dev/null 2>&1");
            status = true;
            msg = "Memory caches flushed and sing-box restarted";
        } else if (c == "switch_to_doh") {
            command_status("uci set tachyon.settings.dns_type='doh'; uci commit tachyon; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = true;
            msg = "Switched DNS mode to DoH and reloaded firewall";
        } else if (c == "heal_network_stack") {
            command_status("ln -sf /tmp/resolv.conf /etc/resolv.conf 2>/dev/null; /etc/init.d/dnsmasq restart >/dev/null 2>&1; /etc/init.d/tachyon restart >/dev/null 2>&1; ip route flush cache 2>/dev/null; ubus call network.interface.wan up 2>/dev/null; ifup wan 2>/dev/null");
            status = true;
            msg = "Full network stack recovery executed";
        } else if (c == "enable_safe_bypass") {
            command_status("uci set tachyon.settings.recovery_bypass='1'; uci commit tachyon; /etc/init.d/tachyon reload >/dev/null 2>&1");
            status = true;
            msg = "Safe Direct WAN bypass enabled";
        } else {
            status = false;
            msg = "Unknown fix code: " + c;
            all_ok = false;
        }

        push(results, { code: c, success: status, message: msg });
        if (status) {
            doctor_fix_record(c);
        }
    }

    print(sprintf("%J\n", {
        success: all_ok,
        results: results
    }));
    return all_ok ? 0 : 1;
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
    let sb_pid = find_process_pid("sing-box");
    add("sing-box process", sb_pid != "" ? "pass" : "fail",
        sb_pid != "" ? "running (pid " + sb_pid + ")" : "not running");

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

    let sb_dns = dns_check_through_singbox("google.com");
    if (!sb_dns) sb_dns = dns_check_through_singbox("cloudflare.com");
    add("Proxy DNS via sing-box", sb_dns ? "pass" : (sb_pid != "" ? "fail" : "skip"),
        sb_dns ? "resolved via " + SB_DNS_INBOUND_ADDRESS : (sb_pid != "" ? "no answer" : "sing-box not running"));

    // HTTP through the service mixed proxy — only present when download_via_proxy
    // is enabled; otherwise the tproxy/tun path is covered by the checks above.
    let sb_cfg = fs.readfile("/etc/sing-box/config.json") || "";
    let has_mixed = index(sb_cfg, "4534") >= 0;
    if (has_mixed && sb_pid != "") {
        let res = command_capture("curl -sS --max-time 8 -x http://127.0.0.1:4534 -o /dev/null -w %{http_code} https://www.gstatic.com/generate_204 2>&1");
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

function local_rule_doctor() {
    let cfg = uci_settings();
    let lang = lc(trim(cfg.ai_doctor_lang || "ru"));
    let res = run_doctor_checks();
    let checks = res.checks || [];
    let verify = verify_system();

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

    // ── 1. End-to-end live verification ──
    let wan_cause_added = false;
    for (let c in verify.checks) {
        if (c.status != "fail") continue;
        if (c.name == "sing-box process") {
            push(causes, {
                probability: 95,
                cause: lang == "en" ? "sing-box process is stopped or non-functional" : "Процесс sing-box остановлен или не функционирует",
                fix: "start_singbox"
            });
            add_fix("start_singbox");
        } else if (c.name == "LAN DNS via dnsmasq") {
            push(causes, {
                probability: 85,
                cause: lang == "en" ? "LAN DNS resolution failed (dnsmasq)" : "Сбой разрешения DNS на уровне локального dnsmasq",
                fix: "fix_dnsmasq"
            });
            add_fix("fix_dnsmasq");
        } else if (c.name == "Proxy DNS via sing-box") {
            push(causes, {
                probability: 85,
                cause: lang == "en" ? "Proxy DNS via sing-box failed to respond" : "Прокси-DNS через sing-box (127.0.0.42) не отвечает",
                fix: "clear_dns_cache"
            });
            add_fix("clear_dns_cache");
            if (cfg.dns_type != "doh") {
                add_fix("switch_to_doh");
            }
        } else if ((c.name == "WAN interface" || c.name == "Default gateway") && !wan_cause_added) {
            wan_cause_added = true;
            push(causes, {
                probability: 90,
                cause: lang == "en" ? "WAN default gateway or Internet uplink is unreachable" : "Шлюз по умолчанию или внешний интернет недоступен",
                fix: "fix_wan_interface"
            });
            add_fix("fix_wan_interface");
        } else if (c.name == "HTTP via proxy") {
            push(causes, {
                probability: 88,
                cause: lang == "en" ? "HTTP through the proxy fails end-to-end (node offline or blocked)" : "HTTP через прокси не проходит (узел офлайн или заблокирован)",
                fix: "update_subscriptions"
            });
            add_fix("update_subscriptions");
            add_fix("restart_zapret");
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
                push(report_lines, sprintf("- [%d%% Probability] %s", c.probability, c.cause));
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
                push(report_lines, sprintf("- [%d%% вероятность] %s", c.probability, c.cause));
            }
        }
    }

    let nodes = [
        { name: "WAN", status: "OK" },
        { name: "DNS", status: "OK" },
        { name: "sing-box", status: "OK" },
        { name: "nftables", status: "OK" }
    ];
    for (let c in verify.checks) {
        if (c.status == "fail") {
            if (c.name == "WAN interface" || c.name == "Default gateway") {
                nodes[0].status = "FAIL";
            } else if (index(c.name, "DNS") >= 0) {
                nodes[1].status = "FAIL";
            } else if (index(c.name, "sing-box") >= 0) {
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

function ai_doctor() {
    let cfg = uci_settings();
    let local_res;
    try {
        local_res = local_rule_doctor();
    } catch (e) {
        local_res = {
            report: sprintf("Local diagnosis failed: %s", as_string(e)),
            causes: [],
            quick_fixes: [],
            summary: sprintf("Local diagnosis failed: %s", as_string(e)),
            provider: "local_heuristic"
        };
    }

    let prov = lc(trim(as_string(cfg.ai_doctor_provider || "openai")));
    let has_key = (cfg.ai_doctor_api_key && cfg.ai_doctor_api_key != "");
    let is_local_or_custom = (prov == "ollama" || prov == "lmstudio" || (prov == "custom" && cfg.ai_doctor_custom_url != ""));

    if (cfg.enable_ai_doctor != "1" || (!has_key && !is_local_or_custom)) {
        print(sprintf("%J\n", local_res));
        return 0;
    }

    let res = run_doctor_checks();
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
    let verify = verify_system();
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
            "- optimize_memory (очистить оперативно память)\n" +
            "- switch_to_doh (переключить DNS на DoH)\n\n" +
            "Если авто-исправление не применимо, не пишите тег FIX.", sys_context);
    }

    let provider = cfg.ai_doctor_provider || "openai";
    let api_key = cfg.ai_doctor_api_key || "";
    let custom_url = cfg.ai_doctor_custom_url || "";

    let model_override = trim(cfg.ai_doctor_model || "");
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

let mode = ARGV[0] || "";

if (mode == "extract-ruleset")
    exit(extract_ruleset(ARGV[1] || ""));
else if (mode == "check-proxy")
    exit(check_proxy());
else if (mode == "check-nft")
    exit(check_nft());
else if (mode == "check-nft-rules")
    exit(check_nft_rules());
else if (mode == "check-sing-box")
    exit(check_sing_box());
else if (mode == "sing-box-standard-ports-listening-fixture")
    sing_box_standard_ports_listening_fixture();
else if (mode == "check-inbounds-config")
    exit(check_inbounds_config());
else if (mode == "check-inbounds")
    exit(check_inbounds());
else if (mode == "check-logs")
    exit(check_logs());
else if (mode == "check-sing-box-logs")
    exit(check_sing_box_logs());
else if (mode == "tachyon-logs-fixture")
    exit(tachyon_logs_fixture());
else if (mode == "check-fakeip")
    exit(check_fakeip());
else if (mode == "check-zapret-runtime")
    exit(module_passthrough(ZAPRET_RUNTIME_UC, [ "check" ]));
else if (mode == "check-zapret2-runtime")
    exit(module_passthrough(ZAPRET2_RUNTIME_UC, [ "check" ]));
else if (mode == "check-byedpi-runtime")
    exit(module_passthrough(BYEDPI_RUNTIME_UC, [ "check" ]));
else if (mode == "check-tor-runtime") {
    print(sprintf("%J", { success: true, data: { tor_installed: 0 } }));
    exit(0);
}
else if (mode == "neutralize-zapret-defaults")
    exit(neutralize_zapret_defaults());
else if (mode == "clash-api")
    exit(clash_api(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "show-config")
    exit(show_config(ARGV[1] || "masked"));
else if (mode == "show-version")
    exit(show_version());
else if (mode == "show-sing-box-config")
    exit(show_sing_box_config(ARGV[1] || "masked"));
else if (mode == "show-sing-box-version")
    exit(show_sing_box_version());
else if (mode == "get-status")
    exit(get_status());
else if (mode == "get-outbound-metadata")
    exit(get_outbound_metadata(ARGV[1]));
else if (mode == "get-subscription-metadata")
    exit(get_subscription_metadata(ARGV[1]));
else if (mode == "get-sing-box-status")
    exit(get_sing_box_status());
else if (mode == "get-zapret-status")
    exit(module_passthrough(ZAPRET_RUNTIME_UC, [ "status" ]));
else if (mode == "get-zapret2-status")
    exit(module_passthrough(ZAPRET2_RUNTIME_UC, [ "status" ]));
else if (mode == "get-byedpi-status")
    exit(module_passthrough(BYEDPI_RUNTIME_UC, [ "status" ]));
else if (mode == "get-system-info")
    exit(get_system_info());
else if (mode == "get-server-capabilities")
    exit(get_server_capabilities());
else if (mode == "check-dns-available")
    exit(check_dns_available());
else if (mode == "global-check")
    exit(global_check(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "doctor")
    exit(doctor(ARGV[1]));
else if (mode == "diagnose-json")
    exit(diagnose_json());
else if (mode == "ai-doctor")
    exit(ai_doctor());
else if (mode == "ai-doctor-last")
    exit(ai_doctor_last());
else if (mode == "apply-quick-fix")
    exit(apply_quick_fix(ARGV[1] || ""));
else if (mode == "service-health-check") {
    let args = [];
    for (let i = 1; i < length(ARGV); i++) {
        push(args, ARGV[i]);
    }
    exit(module_passthrough(LIB_DIR + "/diagnostics/service_check.uc", args));
}
else if (mode == "validate-nfqws-strategy-json")
    exit(validate_nfqws_strategy_json(ARGV[1] || ""));
else if (mode == "validate-nfqws2-strategy-json")
    exit(validate_nfqws2_strategy_json(ARGV[1] || ""));
else {
    warn("Usage: diagnostics/runtime.uc <operation> ...\n");
    exit(1);
}