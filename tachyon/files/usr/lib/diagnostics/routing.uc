#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");
let network_mod = require("diagnostics.network");
let variant_state = require("tachyon_core.variant_state");
let gomemlimit = require("core.gomemlimit");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constants.TMP_SING_BOX_FOLDER || "/tmp/tachyon-core";
const CHECK_PROXY_IP_DOMAIN = getenv("CHECK_PROXY_IP_DOMAIN") || constants.CHECK_PROXY_IP_DOMAIN || "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = getenv("FAKEIP_TEST_DOMAIN") || constants.FAKEIP_TEST_DOMAIN || "fakeip.podkop.fyi";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || constants.NFT_COMMON_SET_NAME || "tachyon_subnets";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || constants.NFT_PORT_SET_NAME || "tachyon_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || constants.NFT_IP_PORT_SET_NAME || "tachyon_ip_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || constants.NFT_INTERFACE_SET_NAME || "tachyon_interfaces";
const NFT_DISCORD_SET_NAME = getenv("NFT_DISCORD_SET_NAME") || constants.NFT_DISCORD_SET_NAME || "tachyon_discord_subnets";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || constants.NFT_LOCALV4_SET_NAME || "localv4";
const SB_CLASH_API_CONTROLLER_PORT = getenv("SB_CLASH_API_CONTROLLER_PORT") || constants.SB_CLASH_API_CONTROLLER_PORT || "9090";
const DEFAULT_LATENCY_TEST_URL = getenv("DEFAULT_LATENCY_TEST_URL") || "https://www.gstatic.com/generate_204";
const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/tachyon_core/runtime.uc";
const PROVIDERS_STATUS_UC = LIB_DIR + "/providers/status.uc";
const SERVICE_UI_UC = LIB_DIR + "/service/ui.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_output = common.command_output;
let command_success = common.command_success;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let object_or_empty = common.object_or_empty;
let write_json = common.write_json;

function arg_number(value) {
    value = as_string(value);
    return value == "" || match(value, /[^0-9-]/) != null ? 0 : int(value, 10);
}

function words(value) {
    return network_mod.words(value);
}

function valid_ipv4(value) {
    return network_mod.valid_ipv4(value);
}

function valid_public_ip(value) {
    return network_mod.valid_public_ip(value);
}

function module_args(module_path, args) {
    let result = [ "ucode", "-L", LIB_DIR, "--", module_path ];
    for (let arg in (type(args) == "array" ? args : []))
        push(result, arg);
    return result;
}

function module_success(module_path, args) {
    return command_success(command_from_args(module_args(module_path, args)));
}

function status_capture(args, input) {
    let status_bridge = require("diagnostics.status_bridge");
    return status_bridge.status_capture(args, input);
}

function status_output(args, input) {
    let status_bridge = require("diagnostics.status_bridge");
    return status_bridge.status_output(args, input);
}

function status_success(args, input) {
    let status_bridge = require("diagnostics.status_bridge");
    return status_bridge.status_success(args, input);
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
    let status_bridge = require("diagnostics.status_bridge");
    return replace(status_bridge.status_output(
        [ "public-host-flags", public_host, public_host_ips, wan_ip, wan_public ],
        null
    ), /[\r\n]+$/g, "");
}

function get_wan_ip_addresses() {
    return network_mod.get_wan_ip_addresses();
}

function server_required_port_conflict_owners(listen, port, required_proto) {
    return network_mod.server_required_port_conflict_owners(listen, port, required_proto);
}

function server_required_ports_listening(listen, port, required_proto) {
    return network_mod.server_required_ports_listening(listen, port, required_proto);
}

function option(cfg, key, fallback) {
    if (type(cfg) != "object")
        return fallback;
    let value = cfg[key];
    return value != null && value != "" ? value : fallback;
}

function list_option(cfg, key) {
    if (type(cfg) != "object")
        return [];
    let value = cfg[key];
    if (type(value) == "array")
        return value;
    if (type(value) == "string")
        return words(value);
    return [];
}

function bool_option(cfg, key, fallback) {
    if (type(cfg) != "object")
        return fallback ? true : false;
    let value = cfg[key];
    if (value == null || value == "")
        return fallback ? true : false;
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

// Native Tailscale (tailscale_mode=native) runs tailscaled outside sing-box:
// servers.uc:567 skips the endpoint, tailscaled manages its own nft rules.
// Diagnostics must not flag the absence of those as errors.
function native_tailscale_enabled() {
    for (let section in uci_sections("server")) {
        if (as_string(section["enabled"]) == "0" || as_string(section["enabled"]) == "false")
            continue;
        if (as_string(section["protocol"] || "") != "tailscale")
            continue;
        if (as_string(section["tailscale_mode"] || "singbox") == "native")
            return true;
    }
    return false;
}

function parse_json_or_null(text) {
    return network_mod.parse_json_or_null(text);
}

function module_output(module_path, args) {
    let full = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let a in args) push(full, as_string(a));
    let pipe = fs.popen(command_from_args(full), "r");
    if (!pipe) return "";
    let out = pipe.read("all");
    pipe.close();
    return out != null ? as_string(out) : "";
}

function helper_output(mode, args) {
    let full = [ mode ];
    for (let arg in args)
        push(full, as_string(arg));
    return replace(module_output(HELPERS_UC, full), /[\r\n]+$/g, "");
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

function config_section_types(config_path) {
    let result = [];
    let seen = {};
    let data = fs.readfile(config_path);
    if (!data) return result;
    for (let line in split(as_string(data), "
")) {
        let m = match(trim(line), /^config[ 	]+([a-zA-Z0-9_-]+)/);
        if (m && m[1] && !seen[m[1]]) {
            seen[m[1]] = true;
            push(result, m[1]);
        }
    }
    return result;
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
    return join("
", lines) + "
";
}

function firewall_show_data() {
    return uci_show_data("firewall", "/etc/config/firewall");
}

function file_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function command_exists(name) {
    return command_status("which " + shell_quote(name) + " >/dev/null 2>&1") == 0;
}

function stdout_is_tty() {
    return command_status("test -t 1") == 0;
}

function nolog(message) {
    if (stdout_is_tty())
        print(as_string(message), "
");
}

function server_inbound_tag(section) {
    return "server-" + as_string(section) + "-in";
}

function find_tagged_runtime_item(items, tag) {
    if (type(items) != "array")
        return null;
    for (let item in items) {
        if (type(item) == "object" && as_string(item.tag) == tag)
            return item;
    }
    return null;
}

function runtime_summary_json_from_config(sb_config, section_name, tag) {
    if (type(sb_config) != "object")
        return sprintf("%J", { exists: 0 });
    let item = find_tagged_runtime_item(sb_config[section_name], tag);
    if (item == null && section_name == "inbounds")
        item = find_tagged_runtime_item(sb_config.endpoints, tag);
    if (item == null)
        return sprintf("%J", { exists: 0 });
    return sprintf("%J", {
        exists: 1,
        type: as_string(item.type),
        listen: as_string(item.listen),
        listen_port: arg_number(item.listen_port)
    });
}

function has_route_rule_for_inbound_in_config(sb_config, inbound_tag) {
    if (type(sb_config) != "object" || type(sb_config.route) != "object" || type(sb_config.route.rules) != "array")
        return false;
    for (let rule in sb_config.route.rules) {
        if (type(rule) != "object" || (rule.action != "route" && rule.action != "reject"))
            continue;
        let inb = rule.inbound;
        if (type(inb) == "array") {
            for (let v in inb)
                if (as_string(v) == inbound_tag)
                    return true;
        } else if (as_string(inb) == inbound_tag) {
            return true;
        }
    }
    return false;
}

function server_required_inbound_proto(protocol, section) {
    protocol = as_string(protocol);
    if (protocol == "json_inbound")
        return "";
    if (protocol == "mieru" && type(section) == "object")
        return uc(as_string(option(section, "mieru_transport", "TCP"))) == "UDP" ? "udp" : "tcp";
    // AWG is WireGuard underneath, whichever schema the core puts it in;
    // MASQUE is HTTP/3 over QUIC (UDP).
    return protocol == "hysteria2" || protocol == "tuic" || protocol == "awg" || protocol == "masque" ? "udp" : "tcp";
}

function server_runtime_type_for_protocol(protocol) {
    protocol = as_string(protocol);
    if (protocol == "json_inbound")
        return "";
    if (protocol == "mtproto")
        return "mtproxy";
    // Every schema Tachyon generates calls the AWG object "wireguard": an
    // inbound on extended, an endpoint on lx / tachyon-core.
    if (protocol == "awg")
        return "wireguard";
    return protocol;
}

// The port an AWG server actually listens on, mirroring the generator:
// singbox/servers.uc gives awg_server_port precedence, then listen_port, then
// the 51820 WireGuard default - and nft/apply.uc opens exactly that port. The
// generic listen_port option alone is not what the core binds, so every probe
// below has to ask about the effective port.
function server_effective_listen_port(section, protocol) {
    if (protocol == "awg")
        return option(section, "awg_server_port", option(section, "listen_port", "51820"));
    let raw_lp = trim(as_string(option(section, "listen_port", "")));
    if (protocol == "mieru") {
        if (raw_lp == "")
            return "443";
        let m = match(raw_lp, /^([0-9]+)/);
        if (m)
            return as_string(m[1]);
    }
    return raw_lp;
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

function uci_fixture_enabled() {
    let f = getenv("TACHYON_UCI_STATE_FILE") || getenv("UCI_STATE") || "";
    return f != "";
}

function netstat_addr_matches_port(addr, listen, port) {
    addr = as_string(addr);
    listen = as_string(listen);
    port = as_string(port);
    let colon = rindex(addr, ":");
    let addr_port = colon >= 0 ? substr(addr, colon + 1) : addr;
    if (addr_port != port)
        return false;
    let host = addr;
    if (substr(addr, 0, 1) == "[") {
        let end = index(addr, "]");
        host = end > 0 ? substr(addr, 1, end - 1) : addr;
    } else if (colon >= 0) {
        host = substr(addr, 0, colon);
    }
    if (host == "0.0.0.0" || host == "::")
        return true;
    if (listen == "0.0.0.0")
        return match(host, /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) != null;
    if (listen == "::")
        return index(host, ":") >= 0;
    return host == listen;
}

function in_memory_ports_listening(netstat_data, listen, port, required_proto) {
    for (let proto in words(required_proto)) {
        let found = false;
        for (let line in split(as_string(netstat_data), "\n")) {
            let fields = words(line);
            if (length(fields) < 4 || substr(fields[0], 0, length(proto)) != proto)
                continue;
            if (netstat_addr_matches_port(fields[3], listen, port)) {
                found = true;
                break;
            }
        }
        if (!found)
            return false;
    }
    return true;
}

function in_memory_port_conflict_owners(netstat_data, listen, port, required_proto, comm_names) {
    let owners = [];
    let seen = {};
    let lines = split(as_string(netstat_data), "\n");
    if (length(lines) < 2 || index(as_string(lines[1]), "PID/Program") < 0)
        return "";
    for (let proto in words(required_proto)) {
        for (let i = 2; i < length(lines); i++) {
            let fields = words(lines[i]);
            if (length(fields) < 4 || substr(fields[0], 0, length(proto)) != proto)
                continue;
            if (!netstat_addr_matches_port(fields[3], listen, port))
                continue;
            let owner = as_string(fields[length(fields) - 1]);
            if (owner == "" || owner == "-" || owner == "LISTEN")
                owner = "unknown";
            let is_daemon = false;
            for (let name in comm_names) {
                let suffix = "/" + as_string(name);
                if (length(owner) >= length(suffix) && substr(owner, length(owner) - length(suffix)) == suffix) {
                    is_daemon = true;
                    break;
                }
            }
            if (!is_daemon && !seen[owner]) {
                seen[owner] = true;
                push(owners, owner);
            }
        }
    }
    return join(" ", sort(owners));
}

function firewall_required_protocols_open_cached(port, required_proto, firewall, fw4_in) {
    if (!uci_fixture_enabled() && fw4_in != "") {
        let p_str = trim(as_string(port));
        let proto_str = lc(trim(as_string(required_proto || "tcp")));
        if (p_str != "" && (proto_str == "tcp" || proto_str == "udp")) {
            if (index(fw4_in, proto_str + " dport " + p_str + " accept") >= 0)
                return true;
            for (let line in split(fw4_in, "\n")) {
                if (index(line, proto_str + " dport") >= 0 && index(line, "accept") >= 0) {
                    for (let tok in split(replace(line, /[^0-9]+/g, " "), " ")) {
                        if (tok == p_str)
                            return true;
                    }
                }
            }
        }
    }
    if (firewall == null)
        firewall = firewall_show_data();
    return status_success([ "firewall-required-protocols-open", port, required_proto ], firewall);
}

function firewall_required_protocols_open(port, required_proto) {
    let firewall = firewall_show_data();
    let fw4_in = uci_fixture_enabled() ? "" : command_output_from_args([ "nft", "list", "chain", "inet", "fw4", "input" ]);
    return firewall_required_protocols_open_cached(port, required_proto, firewall, fw4_in);
}

function compute_public_host_flags(public_host, public_host_ips, wan_ip, wan_public) {
    let resolved = -1;
    let public_ip = -1;
    let matches_wan = -1;
    let ips = words(public_host_ips);
    if (as_string(public_host) != "") {
        if (length(ips) > 0) {
            resolved = 1;
            public_ip = 1;
            for (let ip in ips)
                if (!valid_public_ip(ip))
                    public_ip = 0;
            if (as_string(wan_public) == "1") {
                matches_wan = 0;
                for (let wan in words(wan_ip)) {
                    for (let ip in ips) {
                        if (ip == wan) {
                            matches_wan = 1;
                            break;
                        }
                    }
                    if (matches_wan == 1)
                        break;
                }
            }
        } else {
            resolved = 0;
        }
    }
    return [ resolved, public_ip, matches_wan ];
}

function build_inbound_item_object(runtime_obj, section_name, label, protocol, routing_mode, tag, listen, listen_port, public_host, public_host_ips, expected_type, required_proto, listening, firewall_required, firewall_open, port_conflict, port_conflict_owners, routes_configured, flags, native_mode) {
    let runtime = type(runtime_obj) == "object" ? runtime_obj : {};
    let runtime_exists = runtime.exists ? 1 : 0;
    let runtime_type = as_string(runtime.type || "");
    let runtime_listen = as_string(runtime.listen || "");
    let runtime_port = arg_number(runtime.listen_port || 0);
    let runtime_port_text = as_string(runtime_port);
    if (native_mode) {
        runtime_exists = 1;
        runtime_type = expected_type;
    }
    let runtime_ok_flag = 0;
    if (runtime_exists == 1) {
        if (protocol == "json_inbound" || protocol == "tailscale") {
            runtime_ok_flag = 1;
        } else if (runtime_type == expected_type || (protocol == "mtproto" && (runtime_type == "mtproto" || runtime_type == "mtproxy"))) {
            if (protocol == "awg" && runtime_type == "wireguard" && runtime_listen == "")
                runtime_ok_flag = runtime_port_text == as_string(listen_port) ? 1 : 0;
            else
                runtime_ok_flag = (runtime_listen == as_string(listen) && runtime_port_text == as_string(listen_port)) ? 1 : 0;
        }
    }
    let raw_listening = arg_number(listening);
    let effective_listening = (runtime_ok_flag == 1 || raw_listening < 0) ? raw_listening : 0;
    return {
        section: as_string(section_name),
        label: as_string(label),
        protocol: as_string(protocol),
        routing_mode: as_string(routing_mode),
        tag: as_string(tag),
        listen: as_string(listen),
        listen_port: arg_number(listen_port),
        public_host: as_string(public_host),
        public_host_ips: as_string(public_host_ips),
        expected_type: as_string(expected_type),
        required_proto: as_string(required_proto),
        runtime_exists,
        runtime_type,
        runtime_listen,
        runtime_port,
        runtime_ok: runtime_ok_flag,
        listening: effective_listening,
        firewall_required: arg_number(firewall_required),
        firewall_open: arg_number(firewall_open),
        port_conflict: arg_number(port_conflict),
        port_conflict_owners: as_string(port_conflict_owners),
        routes_configured: arg_number(routes_configured),
        public_host_resolved: arg_number(flags[0]),
        public_host_public: arg_number(flags[1]),
        public_host_matches_wan: arg_number(flags[2])
    };
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
    let requires_public_wan = 0;
    let native_tailscale = native_tailscale_enabled();
    let sb_config = sing_box_config_path != "" ? common.read_json_file(sing_box_config_path) : null;
    let netstat_lnp_cache = null;
    let netstat_ln_cache = null;
    let firewall_cache = null;
    let fw4_in_cache = null;
    let resolved_hosts_cache = {};
    let daemon_comm_names = require("core.process").core_contract().comm_names || [];

    for (let section in uci_sections("server")) {
        if (!bool_option(section, "enabled", false))
            continue;
        enabled_count++;

        let section_name = as_string(section[".name"] || "");
        let label = option(section, "label", section_name);
        let protocol = option(section, "protocol", "vless");
        if (protocol != "tailscale" && protocol != "json_inbound")
            requires_public_wan = 1;
        let listen = option(section, "listen", "0.0.0.0");
        let listen_port = server_effective_listen_port(section, protocol);
        let public_host = option(section, "public_host", "");
        let routing_mode = option(section, "routing_mode", "rules");
        let inbound_tag = server_inbound_tag(section_name);
        let expected_type = server_runtime_type_for_protocol(protocol);
        let required_proto = server_required_inbound_proto(protocol, section);
        let runtime_json = protocol == "tailscale"
            ? runtime_summary_json_from_config(sb_config, "endpoints", inbound_tag)
            : runtime_summary_json_from_config(sb_config, "inbounds", inbound_tag);
        // Native mode: tailscaled runs outside sing-box, no endpoint is
        // generated (servers.uc add_server) and no route rule is expected.
        if (protocol == "tailscale" && native_tailscale) {
            runtime_json = "";
            routing_mode = "native";
        }

        let listening = -1;
        let firewall_required = 0;
        let firewall_open = -1;
        let port_conflict = 0;
        let port_conflict_owners = "";
        if (protocol != "tailscale" && protocol != "json_inbound") {
            if (netstat_lnp_cache == null)
                netstat_lnp_cache = command_output_from_args([ "netstat", "-lnp" ]);
            if (netstat_ln_cache == null)
                netstat_ln_cache = command_output_from_args([ "netstat", "-ln" ]);
            port_conflict_owners = in_memory_port_conflict_owners(netstat_lnp_cache, listen, listen_port, required_proto, daemon_comm_names);
            if (port_conflict_owners != "")
                port_conflict = 1;
            listening = in_memory_ports_listening(netstat_ln_cache, listen, listen_port, required_proto) ? 1 : 0;
            if (server_listen_requires_firewall(listen, wan_ip)) {
                firewall_required = 1;
                if (fw4_in_cache == null)
                    fw4_in_cache = uci_fixture_enabled() ? "" : command_output_from_args([ "nft", "list", "chain", "inet", "fw4", "input" ]);
                if (uci_fixture_enabled() && firewall_cache == null)
                    firewall_cache = firewall_show_data();
                firewall_open = firewall_required_protocols_open_cached(listen_port, required_proto, firewall_cache, fw4_in_cache) ? 1 : 0;
            }
        }

        let routes_configured = protocol == "tailscale" && native_tailscale
            ? 1
            : (has_route_rule_for_inbound_in_config(sb_config, inbound_tag) ? 1 : 0);

        let public_host_ips = "";
        if (protocol != "json_inbound") {
            if (!(public_host in resolved_hosts_cache))
                resolved_hosts_cache[public_host] = resolve_public_host_ips(public_host);
            public_host_ips = resolved_hosts_cache[public_host];
        }
        let flags = compute_public_host_flags(public_host, public_host_ips, wan_ip, wan_public);
        let runtime_obj = runtime_json != "" ? parse_json_or_null(runtime_json) : null;
        let item = build_inbound_item_object(
            runtime_obj,
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
            flags,
            protocol == "tailscale" && native_tailscale
        );
        push(items, item);
    }

    write_json({
        enabled_count,
        config_path: sing_box_config_path,
        wan_ip,
        wan_public,
        requires_public_wan,
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
    let bin = command_exists("tachyon-core") ? "tachyon-core" : (command_exists("sing-box") ? "sing-box" : "");
    if (bin == "") {
        nolog("sing-box is not installed");
        return 1;
    }
    if (!file_exists(sing_box_config_path)) {
        nolog("Configuration file not found");
        return 1;
    }

    nolog("Checking sing-box configuration...");
    if (!command_success_from_args([ bin, "-c", sing_box_config_path, "check" ])) {
        nolog("Invalid configuration");
        return 1;
    }

    print(status_output([ "mask-sing-box-config", sing_box_config_path ], null));
    nolog("Checking proxy connection...");

    let check_proxy_dir = TMP_SING_BOX_FOLDER + "/check-proxy-" + clock()[0] + "-" + clock()[1];
    let check_proxy_config = check_proxy_dir + "/config.json";
    let check_proxy_cache = check_proxy_dir + "/cache.db";

    cleanup_check_proxy_dir(check_proxy_dir);
    common.ensure_dir(check_proxy_dir);
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
        let args = [ bin, "tools", "fetch", "ifconfig.me", "-c", check_proxy_config, "-D", check_proxy_dir, "--disable-color" ];
        if (outbound_tag != "") {
            push(args, "-o");
            push(args, outbound_tag);
        }
        // A full core run next to the daemon, rulesets included - same ceiling
        // as `check`, and this one is retried five times.
        response = command_output(gomemlimit.gomemlimit_env() + command_from_args(args) + " 2>/dev/null");
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


function nft_chain_counter_status(chain) {
    let output = command_output_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, chain ]);
    if (output == null || output == "")
        return [ 0, 0 ];
    let rules_exist = 0;
    let counters = 0;
    for (let line in split(output, "\n")) {
        line = as_string(line);
        if (index(line, "counter") < 0)
            continue;
        rules_exist = 1;
        if (index(line, "packets 0 bytes 0") < 0)
            counters = 1;
    }
    return [ rules_exist, counters ];
}

// Tachyon installs marking rules of its own outside TachyonTable: two rules in
// `inet fw4` for the TPROXY mark, so marked traffic survives the firewall. A
// check for "another package is marking packets" must not count those, or every
// router reports a false positive against its own firewall.
const TACHYON_OWN_MARKS = [
    constants.NFT_FAKEIP_MARK || "0x04000000",
    constants.NFT_OUTBOUND_MARK || "0x08000000",
    constants.ZAPRET_DESYNC_MARK || "0x40000000",
    constants.ZAPRET_DESYNC_MARK_POSTNAT || "0x20000000",
    constants.ZAPRET2_DESYNC_MARK || "0x40000000",
    constants.ZAPRET2_DESYNC_MARK_POSTNAT || "0x20000000",
    constants.ZAPRET_ROUTE_MARK_BASE || "0x01000000",
    constants.ZAPRET2_ROUTE_MARK_BASE || "0x02000000",
    "0x00200000",
    "0x00300000",
    "0x00340000",
    "0x00ff0000"
];

function line_marks_are_all_ours(line) {
    let seen = false;
    line = replace(line, /comment "[^"]*"/g, "");
    line = replace(line, /@[a-z0-9]+,[0-9]+,[0-9]+(\s*&\s*0x[0-9a-fA-F]+)?(\s*(==|!=))?\s*0x[0-9a-fA-F]+/g, "");
    let mark_idx = index(line, "meta mark set");
    if (mark_idx >= 0)
        line = substr(line, mark_idx);
    for (let token in match(line, /0x[0-9a-fA-F]+/g) || []) {
        // A capture-less /g match yields [whole-match] per element.
        let value = lc(as_string(token[0]));
        if (int(value, 0) == 0)
            continue;
        seen = true;
        let ours = false;
        for (let mark in TACHYON_OWN_MARKS) {
            if (lc(as_string(mark)) == value) {
                ours = true;
                break;
            }
        }
        if (!ours)
            return false;
    }
    return seen;
}

function nft_table_has_other_mark_rules(family, table_name) {
    let output = command_output_from_args([ "nft", "list", "table", family, table_name ]);
    if (output == null)
        return false;
    for (let line in split(output, "\n")) {
        line = as_string(line);
        if (index(line, "meta mark set") < 0)
            continue;
        if (line_marks_are_all_ours(line))
            continue;
        return true;
    }
    return false;
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
            rules_mangle_counters = (status[1] || rules_mangle_exist) ? 1 : 0;
        }
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "mangle_output" ])) {
            let status = nft_chain_counter_status("mangle_output");
            rules_mangle_output_exist = status[0];
            rules_mangle_output_counters = (status[1] || rules_mangle_output_exist) ? 1 : 0;
        }
        if (command_success_from_args([ "nft", "list", "chain", "inet", NFT_TABLE_NAME, "proxy" ])) {
            let status = nft_chain_counter_status("proxy");
            rules_proxy_exist = status[0];
            rules_proxy_counters = (status[1] || rules_proxy_exist) ? 1 : 0;
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
        // Native Tailscale: tailscaled (and Tachyon's own exit-node/firewall
        // rules) live in their own table — their marking rules are expected.
        if (table_name == "tachyon_tailscale" && native_tailscale_enabled())
            continue;
        // Zapret / Zapret2 companion tables managed alongside Tachyon
        if (table_name == "zapret" || table_name == "zapret2")
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
        rules_other_mark_exist,
        engine: active_engine_name()
    });
    return 0;
}


function clash_json_output(args) {
    let out = command_output(command_from_args(args));
    if (out != null && out != "")
        print(out);
    else
        print("{}\n");
    return 0;
}

function clash_json_data(args, auth) {
    let full_args = [];
    for (let item in args) push(full_args, item);
    for (let item in auth) push(full_args, item);
    let out = command_output(command_from_args(full_args));
    try {
        return json(out);
    } catch (e) {
        return null;
    }
}

function clash_api_url() {
    let address = replace(module_output(SINGBOX_RUNTIME_UC, [ "service-listen-address" ]), /[\r\n]+$/g, "");
    if (address == "")
        address = "127.0.0.1";
    return address + ":" + SB_CLASH_API_CONTROLLER_PORT;
}

function clash_auth_args() {
    let secret = "";
    let config_data = fs.readfile("/etc/tachyon-core/config.json");
    if (config_data) {
        try {
            let sb_cfg = json(config_data);
            let sb_secret = sb_cfg.experimental?.clash_api?.secret;
            if (sb_secret && sb_secret != "")
                secret = sb_secret;
        } catch (e) {}
    }
    if (secret == "") {
        let cfg = settings();
        let uci_secret = option(cfg, "yacd_secret_key", "");
        if (uci_secret != "")
            secret = uci_secret;
    }
    if (secret != "")
        return [ "--header", "Authorization: Bearer " + secret ];
    return [];
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

function clash_proxy_info_map(base_url, auth) {
    let args = [ "curl", "-s" ];
    if (getenv("FAKE_CURL_LOG") == null) {
        push(args, "-m");
        push(args, "5");
    }
    for (let item in auth) push(args, item);
    push(args, base_url + "/proxies");

    let value = {};
    try {
        value = json(command_output(command_from_args(args)));
    }
    catch (e) {
        return {};
    }

    return object_or_empty(value.proxies);
}

function clash_proxy_type_map(base_url, auth) {
    let proxies = clash_proxy_info_map(base_url, auth);
    let result = {};
    for (let tag, proxy in proxies)
        result[tag] = as_string(object_or_empty(proxy).type || "");
    return result;
}

function resolve_selector_leaf_tag(proxies, tag) {
    let cur = as_string(tag);
    let visited = {};
    for (let depth = 0; depth < 6; depth++) {
        if (cur == "" || visited[cur])
            break;
        visited[cur] = true;
        let info = object_or_empty(proxies[cur]);
        let ptype = lc(as_string(info.type || ""));
        let now = trim(as_string(info.now || ""));
        let all = type(info.all) == "array" ? info.all : [];
        if (ptype == "selector") {
            if (now != "" && now != cur && proxies[now] != null) {
                cur = now;
                continue;
            }
            if (length(all) > 0 && as_string(all[0]) != "" && as_string(all[0]) != cur && proxies[as_string(all[0])] != null) {
                cur = as_string(all[0]);
                continue;
            }
            break;
        }
        if (ptype == "urltest" || ptype == "fallback") {
            if (now != "" && now != cur && proxies[now] != null) {
                cur = now;
                continue;
            }
            if (length(all) == 1 && as_string(all[0]) != "" && as_string(all[0]) != cur && proxies[as_string(all[0])] != null) {
                cur = as_string(all[0]);
                continue;
            }
            break;
        }
        break;
    }
    return cur != "" ? cur : as_string(tag);
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

function save_persistent_selector_choice(group_tag, proxy_tag) {
    group_tag = as_string(group_tag);
    proxy_tag = as_string(proxy_tag);
    if (group_tag == "" || proxy_tag == "")
        return false;
    let path = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
    let state = common.read_json_file(path);
    if (type(state) != "object")
        state = {};
    state[group_tag] = proxy_tag;
    return common.write_json_file(path, state, 2);
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
        let proxies = clash_proxy_info_map(base_url, auth);
        let resolved_tag = resolve_selector_leaf_tag(proxies, arg1);
        let resolved_type = as_string(object_or_empty(proxies[resolved_tag]).type || "");
        let endpoint = clash_latency_endpoint(base_url, resolved_tag, resolved_type);
        let timeout_ms = as_string(arg2 || "2000");
        let args = [ "curl", "-G", "-s" ];
        if (getenv("FAKE_CURL_LOG") == null) {
            let max_time = int((int(timeout_ms, 10) + 2999) / 1000);
            if (max_time < 3)
                max_time = 3;
            push(args, "-m");
            push(args, as_string(max_time));
        }
        push(args, endpoint);
        for (let item in auth) push(args, item);
        push(args, "--data-urlencode");
        push(args, "url=" + url);
        push(args, "--data-urlencode");
        push(args, "timeout=" + timeout_ms);
        return clash_json_output(args);
    }

    if (action == "get_proxy_latencies") {
        let raw_tags = as_string(arg1);
        if (substr(raw_tags, 0, 1) == "@") {
            let tag_target = substr(raw_tags, 1);
            if (substr(tag_target, 0, 8) == "section:") {
                let sec_name = substr(tag_target, 8);
                let cache_dir = getenv("TACHYON_SECTION_CACHE_DIR") || ((getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/section-cache");
                let sec_cache = common.read_json_file(cache_dir + "/" + sec_name + ".json");
                if (type(sec_cache) == "object") {
                    let sec_tags = [];
                    let seen_tags = {};
                    for (let ct in (type(sec_cache.urltestCandidateTags) == "array" ? sec_cache.urltestCandidateTags : [])) {
                        ct = as_string(ct);
                        if (ct != "" && !seen_tags[ct]) {
                            seen_tags[ct] = true;
                            push(sec_tags, ct);
                        }
                    }
                    for (let gt in keys(object_or_empty(sec_cache.urltestGroups))) {
                        gt = as_string(gt);
                        if (gt != "" && !seen_tags[gt]) {
                            seen_tags[gt] = true;
                            push(sec_tags, gt);
                        }
                    }
                    raw_tags = sprintf("%J", sec_tags);
                }
            } else {
                let file_content = fs.readfile(tag_target);
                if (file_content != null)
                    raw_tags = as_string(file_content);
            }
        }
        if (raw_tags == "")
            return clash_json_error("proxy_tags_json required");
        let parsed_tags = parse_json_or_null(raw_tags);
        if (type(parsed_tags) != "array")
            return clash_json_error("proxy_tags_json must be a JSON array of non-empty strings");
        let proxy_tags = [];
        for (let proxy_tag in parsed_tags) {
            if (type(proxy_tag) != "string" || proxy_tag == "")
                return clash_json_error("proxy_tags_json must be a JSON array of non-empty strings");
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

        let timeout_ms = as_string(arg2 || "3500");
        let max_time = as_string(int((int(timeout_ms) + 1999) / 1000));
        if (int(max_time) < 3)
            max_time = "3";

        if (getenv("FAKE_CURL_LOG") != null || length(ordered_proxy_tags) <= 1 || getenv("TACHYON_SEQUENTIAL_LATENCY") == "1") {
            for (let proxy_tag in ordered_proxy_tags) {
                let args = [ "curl", "-G", "-s", "-m", max_time, clash_latency_endpoint(base_url, proxy_tag, proxy_types[proxy_tag]) ];
                for (let item in auth) push(args, item);
                push(args, "--data-urlencode");
                push(args, "url=" + test_url);
                push(args, "--data-urlencode");
                push(args, "timeout=" + timeout_ms);
                if (status_capture([ "stdin-json" ], command_output(command_from_args(args))).status != 0)
                    failed++;
                count++;
                if (progress_path != "")
                    module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
            }
        }
        else {
            let tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-lat.XXXXXX" ]));
            if (tmp_dir == "") {
                for (let proxy_tag in ordered_proxy_tags) {
                    let args = [ "curl", "-G", "-s", "-m", max_time, clash_latency_endpoint(base_url, proxy_tag, proxy_types[proxy_tag]) ];
                    for (let item in auth) push(args, item);
                    push(args, "--data-urlencode");
                    push(args, "url=" + test_url);
                    push(args, "--data-urlencode");
                    push(args, "timeout=" + timeout_ms);
                    if (status_capture([ "stdin-json" ], command_output(command_from_args(args))).status != 0)
                        failed++;
                    count++;
                    if (progress_path != "")
                        module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
                }
            }
            else {
                let batch_supported = false;
                let probe_chunk_size = 12;
                let parallel_chunks = 1;
                let retry_failed_batch = function(failed_tags, wave_results, wave_id) {
                    if (length(failed_tags) == 0)
                        return;
                    let r_req = tmp_dir + "/retry_req_" + wave_id + ".json";
                    let r_res = tmp_dir + "/retry_res_" + wave_id + ".json";
                    let retry_timeout = int(timeout_ms) + 1500;
                    common.write_json_file(r_req, {
                        names: failed_tags,
                        url: test_url,
                        timeout: retry_timeout
                    });
                    let r_args = [ "curl", "-s", "-m", as_string(int((retry_timeout + 1999) / 1000) + 5), "-X", "POST", "-H", "Content-Type: application/json" ];
                    for (let item in auth) push(r_args, item);
                    push(r_args, "-d", "@" + r_req, base_url + "/tachyon/delay-batch", "-o", r_res);
                    common.command_status(command_from_args(r_args));
                    let r_content = fs.readfile(r_res);
                    try { fs.unlink(r_req); } catch(e) {}
                    try { fs.unlink(r_res); } catch(e) {}
                    let r_parsed = parse_json_or_null(r_content);
                    if (type(r_parsed) == "object" && type(r_parsed.results) == "object") {
                        for (let k, v in r_parsed.results) {
                            if (type(v) == "object" && v.message == null && v.error == null && int(v.delay || 0) > 0)
                                wave_results[k] = v;
                        }
                    }
                };
                let wave_tags = slice(ordered_proxy_tags, 0, probe_chunk_size * parallel_chunks);
                if (length(wave_tags) > 0) {
                    let wave_cmds = [];
                    let wave_chunks = [];
                    for (let c = 0; c < length(wave_tags); c += probe_chunk_size) {
                        let c_tags = slice(wave_tags, c, c + probe_chunk_size);
                        let chunk_idx = int(c / probe_chunk_size);
                        let req_file = tmp_dir + "/batch_req_" + chunk_idx + ".json";
                        let res_file = tmp_dir + "/batch_res_" + chunk_idx + ".json";
                        common.write_json_file(req_file, {
                            names: c_tags,
                            url: test_url,
                            timeout: int(timeout_ms)
                        });
                        let b_args = [ "curl", "-s", "-m", as_string(int(max_time) + 5), "-X", "POST", "-H", "Content-Type: application/json" ];
                        for (let item in auth) push(b_args, item);
                        push(b_args, "-d", "@" + req_file, base_url + "/tachyon/delay-batch", "-o", res_file);
                        push(wave_cmds, command_from_args(b_args));
                        push(wave_chunks, { tags: c_tags, req: req_file, res: res_file });
                    }
                    if (length(wave_cmds) > 0) {
                        common.command_status("{ " + join(" & ", wave_cmds) + " & wait; }");
                        let wave_results = {};
                        let wave_valid = true;
                        for (let ch in wave_chunks) {
                            let content = fs.readfile(ch.res);
                            try { fs.unlink(ch.req); } catch(e) {}
                            try { fs.unlink(ch.res); } catch(e) {}
                            let parsed = parse_json_or_null(content);
                            if (type(parsed) == "object" && type(parsed.results) == "object") {
                                for (let k, v in parsed.results)
                                    wave_results[k] = v;
                            } else {
                                wave_valid = false;
                            }
                        }
                        if (wave_valid) {
                            batch_supported = true;
                            let retry_tags = [];
                            for (let t in wave_tags) {
                                let entry = wave_results[t];
                                let is_ok = (type(entry) == "object" && entry.message == null && entry.error == null && int(entry.delay || 0) > 0);
                                if (!is_ok && lc(as_string(proxy_types[t])) != "urltest")
                                    push(retry_tags, t);
                            }
                            if (length(retry_tags) > 0)
                                retry_failed_batch(retry_tags, wave_results, 0);
                            for (let t in wave_tags) {
                                let entry = wave_results[t];
                                let is_ok = (type(entry) == "object" && entry.message == null && entry.error == null && int(entry.delay || 0) > 0);
                                if (!is_ok)
                                    failed++;
                                count++;
                            }
                            if (progress_path != "")
                                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
                        }
                    }
                }

                if (batch_supported) {
                    let wave_step = probe_chunk_size * parallel_chunks;
                    for (let w = wave_step; w < length(ordered_proxy_tags); w += wave_step) {
                        let w_tags = slice(ordered_proxy_tags, w, w + wave_step);
                        let wave_cmds = [];
                        let wave_chunks = [];
                        for (let c = 0; c < length(w_tags); c += probe_chunk_size) {
                            let c_tags = slice(w_tags, c, c + probe_chunk_size);
                            let chunk_idx = int((w + c) / probe_chunk_size);
                            let req_file = tmp_dir + "/batch_req_" + chunk_idx + ".json";
                            let res_file = tmp_dir + "/batch_res_" + chunk_idx + ".json";
                            common.write_json_file(req_file, {
                                names: c_tags,
                                url: test_url,
                                timeout: int(timeout_ms)
                            });
                            let b_args = [ "curl", "-s", "-m", as_string(int(max_time) + 5), "-X", "POST", "-H", "Content-Type: application/json" ];
                            for (let item in auth) push(b_args, item);
                            push(b_args, "-d", "@" + req_file, base_url + "/tachyon/delay-batch", "-o", res_file);
                            push(wave_cmds, command_from_args(b_args));
                            push(wave_chunks, { tags: c_tags, req: req_file, res: res_file });
                        }
                        if (length(wave_cmds) > 0) {
                            common.command_status("{ " + join(" & ", wave_cmds) + " & wait; }");
                            let wave_results = {};
                            for (let ch in wave_chunks) {
                                let content = fs.readfile(ch.res);
                                try { fs.unlink(ch.req); } catch(e) {}
                                try { fs.unlink(ch.res); } catch(e) {}
                                let parsed = parse_json_or_null(content);
                                if (type(parsed) == "object" && type(parsed.results) == "object") {
                                    for (let k, v in parsed.results)
                                        wave_results[k] = v;
                                }
                            }
                            let retry_tags = [];
                            for (let t in w_tags) {
                                let entry = wave_results[t];
                                let is_ok = (type(entry) == "object" && entry.message == null && entry.error == null && int(entry.delay || 0) > 0);
                                if (!is_ok && lc(as_string(proxy_types[t])) != "urltest")
                                    push(retry_tags, t);
                            }
                            if (length(retry_tags) > 0)
                                retry_failed_batch(retry_tags, wave_results, w);
                            for (let t in w_tags) {
                                let entry = wave_results[t];
                                let is_ok = (type(entry) == "object" && entry.message == null && entry.error == null && int(entry.delay || 0) > 0);
                                if (!is_ok)
                                    failed++;
                                count++;
                            }
                            if (progress_path != "")
                                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
                        }
                    }
                }
                else {
                    let batch_size = 64;
                    for (let i = 0; i < length(ordered_proxy_tags); i += batch_size) {
                        let cmds = [];
                        let batch_tags = [];
                        for (let j = i; j < i + batch_size && j < length(ordered_proxy_tags); j++) {
                            let proxy_tag = ordered_proxy_tags[j];
                            push(batch_tags, { tag: proxy_tag, index: j });
                            let out_file = tmp_dir + "/" + j + ".json";
                            let args = [ "curl", "-G", "-s", "-m", max_time, clash_latency_endpoint(base_url, proxy_tag, proxy_types[proxy_tag]) ];
                            for (let item in auth) push(args, item);
                            push(args, "--data-urlencode");
                            push(args, "url=" + test_url);
                            push(args, "--data-urlencode");
                            push(args, "timeout=" + timeout_ms);
                            push(cmds, command_from_args(args) + " > " + shell_quote(out_file) + " 2>/dev/null &");
                        }
                        if (length(cmds) > 0) {
                            system("{ " + join(" ", cmds) + " wait; }");
                            for (let item in batch_tags) {
                                let out_file = tmp_dir + "/" + item.index + ".json";
                                let content = fs.readfile(out_file);
                                try { fs.unlink(out_file); } catch(e) {}
                                let is_ok = false;
                                if (content != null && content != "") {
                                    try {
                                        let parsed = json(content);
                                        if (type(parsed) == "object" && parsed.message == null && parsed.error == null)
                                            is_ok = true;
                                    }
                                    catch (e) {}
                                }
                                if (!is_ok)
                                    failed++;
                                count++;
                            }
                            if (progress_path != "")
                                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
                        }
                    }
                }
                system("rm -rf " + shell_quote(tmp_dir) + " >/dev/null 2>&1 || true");
            }
        }
        let result = status_capture([ "clash-proxy-latencies-result", count, failed ], null);
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "get_group_latency") {
        if (as_string(arg1) == "")
            return clash_json_error("group_tag required");
        let group_tag = as_string(arg1);
        let timeout_ms = as_string(arg2 || "3500");
        if (getenv("FAKE_CURL_LOG") == null && getenv("TACHYON_SEQUENTIAL_LATENCY") != "1") {
            let proxies = clash_proxy_info_map(base_url, auth);
            let grp = object_or_empty(proxies[group_tag]);
            let members = type(grp.all) == "array" ? grp.all : [];
            if (length(members) > 12) {
                let tmp_dir = trim(command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-glat.XXXXXX" ]));
                if (tmp_dir != "") {
                    let probe_tags = [];
                    for (let m in members) {
                        let mt = as_string(m);
                        if (mt != "" && mt != group_tag)
                            push(probe_tags, mt);
                    }
                    push(probe_tags, group_tag);
                    let probe_chunk_size = 12;
                    let parallel_chunks = 1;
                    let retry_failed_group_batch = function(failed_tags, target_out_map, wave_id) {
                        if (length(failed_tags) == 0)
                            return;
                        let r_req = tmp_dir + "/gretry_req_" + wave_id + ".json";
                        let r_res = tmp_dir + "/gretry_res_" + wave_id + ".json";
                        let retry_timeout = int(timeout_ms) + 1500;
                        common.write_json_file(r_req, {
                            names: failed_tags,
                            url: test_url,
                            timeout: retry_timeout
                        });
                        let r_args = [ "curl", "-s", "-m", as_string(int((retry_timeout + 1999) / 1000) + 5), "-X", "POST", "-H", "Content-Type: application/json" ];
                        for (let item in auth) push(r_args, item);
                        push(r_args, "-d", "@" + r_req, base_url + "/tachyon/delay-batch", "-o", r_res);
                        common.command_status(command_from_args(r_args));
                        let r_content = fs.readfile(r_res);
                        try { fs.unlink(r_req); } catch(e) {}
                        try { fs.unlink(r_res); } catch(e) {}
                        let r_parsed = parse_json_or_null(r_content);
                        if (type(r_parsed) == "object" && type(r_parsed.results) == "object") {
                            for (let k, v in r_parsed.results) {
                                if (type(v) == "object" && v.message == null && v.error == null && int(v.delay || 0) > 0) {
                                    target_out_map[k] = int(v.delay);
                                }
                            }
                        }
                    };
                    let wave_step = probe_chunk_size * parallel_chunks;
                    let max_time = int((int(timeout_ms) + 1999) / 1000) + 5;
                    if (max_time < 8) max_time = 8;
                    let batch_ok = true;
                    let out_map = {};
                    let count = 0;
                    let failed = 0;
                    let total = length(probe_tags);
                    let progress_path = as_string(arg3 || "");
                    if (progress_path != "")
                        module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
                    for (let w = 0; w < length(probe_tags); w += wave_step) {
                        let w_tags = slice(probe_tags, w, w + wave_step);
                        let wave_cmds = [];
                        let wave_chunks = [];
                        for (let c = 0; c < length(w_tags); c += probe_chunk_size) {
                            let c_tags = slice(w_tags, c, c + probe_chunk_size);
                            let chunk_idx = int((w + c) / probe_chunk_size);
                            let req_file = tmp_dir + "/greq_" + chunk_idx + ".json";
                            let res_file = tmp_dir + "/gres_" + chunk_idx + ".json";
                            common.write_json_file(req_file, {
                                names: c_tags,
                                url: test_url,
                                timeout: int(timeout_ms)
                            });
                            let b_args = [ "curl", "-s", "-m", as_string(max_time), "-X", "POST", "-H", "Content-Type: application/json" ];
                            for (let item in auth) push(b_args, item);
                            push(b_args, "-d", "@" + req_file, base_url + "/tachyon/delay-batch", "-o", res_file);
                            push(wave_cmds, command_from_args(b_args));
                            push(wave_chunks, { req: req_file, res: res_file });
                        }
                        if (length(wave_cmds) > 0) {
                            common.command_status("{ " + join(" & ", wave_cmds) + " & wait; }");
                            let wave_results = {};
                            for (let ch in wave_chunks) {
                                let content = fs.readfile(ch.res);
                                try { fs.unlink(ch.req); } catch(e) {}
                                try { fs.unlink(ch.res); } catch(e) {}
                                let parsed = parse_json_or_null(content);
                                if (type(parsed) == "object" && type(parsed.results) == "object") {
                                    for (let k, v in parsed.results)
                                        wave_results[k] = v;
                                } else {
                                    batch_ok = false;
                                }
                            }
                            if (batch_ok) {
                                let retry_tags = [];
                                for (let t in w_tags) {
                                    let entry = wave_results[t];
                                    let is_ok = (type(entry) == "object" && entry.message == null && entry.error == null && int(entry.delay || 0) > 0);
                                    if (is_ok)
                                        out_map[t] = int(entry.delay);
                                    else
                                        push(retry_tags, t);
                                }
                                if (length(retry_tags) > 0)
                                    retry_failed_group_batch(retry_tags, out_map, w);
                                for (let t in w_tags) {
                                    count++;
                                    if (out_map[t] == null || out_map[t] <= 0)
                                        failed++;
                                }
                            }
                            if (!batch_ok)
                                break;
                            if (progress_path != "")
                                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
                        }
                    }
                    common.command_status("rm -rf " + shell_quote(tmp_dir) + " >/dev/null 2>&1 || true");
                    if (batch_ok) {
                        print(sprintf("%J\n", out_map));
                        return 0;
                    }
                }
            }
        }
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
        let target_group_tag = as_string(arg1);
        if (match(target_group_tag, /-urltest-out$/))
            target_group_tag = replace(target_group_tag, /-urltest-out$/, "-out");
        let payload = status_output([ "clash-set-group-proxy-payload", arg2 ], null);
        let args = [ "curl", "-X", "PUT", "-s", "-w", "\n%{http_code}", base_url + "/proxies/" + clash_urlencode(target_group_tag) ];
        for (let item in auth) push(args, item);
        push(args, "--data-raw");
        push(args, payload);
        let result = status_capture([ "clash-set-group-proxy-result", target_group_tag, arg2 ], command_output(command_from_args(args)));
        if (result.status == 0 && as_string(arg3) != "ephemeral") {
            save_persistent_selector_choice(target_group_tag, arg2);
        }
        if (result.output != "")
            print(result.output);
        return result.status;
    }

    if (action == "restore_selector_state") {
        let path = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
        let state = common.read_json_file(path);
        if (type(state) != "object" || length(keys(state)) == 0)
            return 0;
        let proxies_res = clash_json_data([ "curl", "-s", base_url + "/proxies" ], auth);
        let proxies = object_or_empty(object_or_empty(proxies_res).proxies);
        for (let group, selected in state) {
            if (index(as_string(group), "-priority-") >= 0)
                continue;
            let grp = proxies[group];
            if (type(grp) == "object" && lc(as_string(grp.type || "")) == "selector" && index(grp.all, selected) >= 0 && as_string(grp.now || "") != selected) {
                clash_api("set_group_proxy", group, selected, "ephemeral");
            }
        }
        return 0;
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


return {
    server_inbound_tag,
    server_required_inbound_proto,
    server_runtime_type_for_protocol,
    server_effective_listen_port,
    server_listen_requires_firewall,
    firewall_required_protocols_open,
    resolve_public_host_ips,
    public_host_flags,
    check_inbounds_config,
    check_inbounds,
    cleanup_check_proxy_dir,
    check_proxy,
    domain_lists_contain_cloud_provider,
    check_nft,
    nft_chain_counter_status,
    nft_table_has_other_mark_rules,
    check_nft_rules,
    clash_json_output,
    clash_json_data,
    clash_api_url,
    clash_auth_args,
    clash_urlencode,
    clash_json_error,
    clash_proxy_type_map,
    clash_latency_endpoint,
    latency_test_url,
    save_persistent_selector_choice,
    clash_api
};
