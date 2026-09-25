#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");
let network_mod = require("diagnostics.network");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TMP_SING_BOX_FOLDER = getenv("TMP_SING_BOX_FOLDER") || constants.TMP_SING_BOX_FOLDER || "/tmp/sing-box";
const CHECK_PROXY_IP_DOMAIN = getenv("CHECK_PROXY_IP_DOMAIN") || constants.CHECK_PROXY_IP_DOMAIN || "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = getenv("FAKEIP_TEST_DOMAIN") || constants.FAKEIP_TEST_DOMAIN || "fakeip.podkop.fyi";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || constants.NFT_COMMON_SET_NAME || "tachyon_subnets";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || constants.NFT_PORT_SET_NAME || "tachyon_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || constants.NFT_IP_PORT_SET_NAME || "tachyon_ip_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || constants.NFT_INTERFACE_SET_NAME || "tachyon_interfaces";
const NFT_DISCORD_SET_NAME = getenv("NFT_DISCORD_SET_NAME") || constants.NFT_DISCORD_SET_NAME || "tachyon_discord_subnets";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || constants.NFT_LOCALV4_SET_NAME || "localv4";
const STEER_NFT_TABLE = getenv("STEER_NFT_TABLE") || "steer";
const SB_CLASH_API_CONTROLLER_PORT = getenv("SB_CLASH_API_CONTROLLER_PORT") || constants.SB_CLASH_API_CONTROLLER_PORT || "9090";
const DEFAULT_LATENCY_TEST_URL = getenv("DEFAULT_LATENCY_TEST_URL") || "https://www.gstatic.com/generate_204";
const HELPERS_UC = LIB_DIR + "/core/helpers.uc";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";
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

function active_engine_is_steer() {
    let name = active_engine_name();
    return name == "steer" || name == "steer-extended";
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
    return replace(module_output(HELPERS_UC, full), /[
]+$/g, "");
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

function ensure_dir(dir) {
    dir = as_string(dir);
    if (dir == "" || fs.stat(dir) != null)
        return;
    let parts = split(dir, "/");
    let current = "";
    for (let part in parts) {
        if (part == "") continue;
        current = current + "/" + part;
        if (fs.stat(current) == null)
            fs.mkdir(current);
    }
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


function check_inbounds_config() {
    let count = 0;
    for (let section in uci_sections("server"))
        if (bool_option(section, "enabled", false))
            count++;
    write_json({ enabled_count: count });
    return 0;
}

function check_inbounds() {
    // Server inbounds are sing-box runtime objects; steer has no inbound
    // management, so this check reports not_applicable there.
    if (active_engine_is_steer()) {
        write_json({ not_applicable: 1, engine: active_engine_name(), items: [], enabled_count: 0, requires_public_wan: 0 });
        return 0;
    }
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
    // Steer uses its own `inet steer` table, not the sing-box TachyonTable.
    // Reporting not_applicable avoids false errors in the diagnostics UI.
    if (active_engine_is_steer()) {
        write_json({ not_applicable: 1, engine: active_engine_name() });
        return 0;
    }
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
    let status = words(status_output([ "nft-chain-counter-status" ], output));
    while (length(status) < 2)
        push(status, "0");
    return [ arg_number(status[0]), arg_number(status[1]) ];
}

function nft_table_has_other_mark_rules(family, table_name) {
    let output = command_output_from_args([ "nft", "list", "table", family, table_name ]);
    return status_success([ "stdin-contains", "meta mark set" ], output);
}

function nft_steer_chain_has_rules(chain) {
    let output = command_output_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, chain ]);
    // chain has rules if there is at least one non-comment, non-policy line with content
    return output != null && length(split(trim(output), "\n")) > 3;
}

function check_nft_rules() {
    // When steer is active, check the `inet steer` table instead of TachyonTable.
    if (active_engine_is_steer()) {
        let table_exist = command_success_from_args([ "nft", "list", "table", "inet", STEER_NFT_TABLE ]) ? 1 : 0;
        let rules_mangle_exist = 0;
        let rules_mangle_counters = 0;
        let rules_mangle_output_exist = 0;
        let rules_mangle_output_counters = 0;
        let rules_proxy_exist = 0;
        let rules_proxy_counters = 0;
        let rules_other_mark_exist = 0;

        if (table_exist) {
            // prerouting_mark = equivalent of mangle (marks lan->proxy traffic)
            if (command_success_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, "prerouting_mark" ])) {
                rules_mangle_exist = 1;
                let out = command_output_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, "prerouting_mark" ]);
                rules_mangle_counters = (out != null && index(out, "counter") >= 0) ? 1 : 0;
            }
            // postrouting_down = equivalent of mangle_output (marks return traffic)
            if (command_success_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, "postrouting_down" ])) {
                rules_mangle_output_exist = 1;
                let out = command_output_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, "postrouting_down" ]);
                rules_mangle_output_counters = (out != null && index(out, "counter") >= 0) ? 1 : 0;
            }
            // prerouting_dns = DNS redirect chain (steer-specific, replaces proxy chain role)
            if (command_success_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, "prerouting_dns" ])) {
                rules_proxy_exist = 1;
                let out = command_output_from_args([ "nft", "list", "chain", "inet", STEER_NFT_TABLE, "prerouting_dns" ]);
                rules_proxy_counters = (out != null && index(out, "counter") >= 0) ? 1 : 0;
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
    let config_data = fs.readfile("/etc/sing-box/config.json");
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

const STEER_LATENCY_CACHE_FILE = "/var/run/tachyon/steer-latencies.json";

function steer_get_cached_latencies() {
    let data = common.read_json_file(STEER_LATENCY_CACHE_FILE);
    return type(data) == "object" ? data : {};
}

function steer_set_cached_latency(tag, delay) {
    if (tag == null || tag == "" || tag == "proxy-NaN" || index(tag, "NaN") >= 0)
        return;
    let d = int(delay);
    if (d == null || d == "NaN")
        return;
    let data = steer_get_cached_latencies();
    data[as_string(tag)] = d;
    if (index(tag, "-out") < 0 && index(tag, "-urltest-") < 0) {
        let unprefixed = replace(tag, /^.*?\s+/, "");
        if (unprefixed != tag && unprefixed != "")
            data[unprefixed] = d;
    }
    common.write_json_file(STEER_LATENCY_CACHE_FILE, data);
}

function steer_set_cached_latencies_bulk(entries) {
    let data = steer_get_cached_latencies();
    for (let tag, delay in entries) {
        if (tag != null && tag != "" && tag != "proxy-NaN" && index(tag, "NaN") < 0) {
            let d = int(delay);
            if (d != null && d != "NaN")
                data[as_string(tag)] = d;
        }
    }
    common.write_json_file(STEER_LATENCY_CACHE_FILE, data);
}

function steer_lookup_latency(latencies, tag, ctx) {
    if (type(latencies) != "object" || tag == null) return null;
    tag = as_string(tag);
    if (latencies[tag] != null && int(latencies[tag]) > 0) return int(latencies[tag]);

    if (ctx) {
        if (ctx.names && ctx.names[tag] != null && latencies[ctx.names[tag]] != null && int(latencies[ctx.names[tag]]) > 0)
            return int(latencies[ctx.names[tag]]);
        if (ctx.tag_to_idx && ctx.tag_to_idx[tag] != null) {
            let idx = ctx.tag_to_idx[tag];
            if (latencies["proxy-" + idx] != null && int(latencies["proxy-" + idx]) > 0)
                return int(latencies["proxy-" + idx]);
            if (ctx.idx_to_tag && ctx.idx_to_tag[idx] != null && latencies[ctx.idx_to_tag[idx]] != null && int(latencies[ctx.idx_to_tag[idx]]) > 0)
                return int(latencies[ctx.idx_to_tag[idx]]);
        }
    }

    let m = match(tag, /proxy-(\d+)/);
    if (m && latencies["proxy-" + m[1]] != null && int(latencies["proxy-" + m[1]]) > 0)
        return int(latencies["proxy-" + m[1]]);

    let unprefixed = replace(tag, /^.*?\s+/, "");
    if (unprefixed != tag && latencies[unprefixed] != null && int(latencies[unprefixed]) > 0)
        return int(latencies[unprefixed]);

    for (let k, v in latencies) {
        if (substr(k, -length(tag)) == tag && int(v) > 0)
            return int(v);
    }
    return null;
}

function steer_reload_vless_workers(target_sec_name) {
    let restarted = false;
    let spec_raw = fs.readfile("/etc/steer/spec.json");
    if (spec_raw != null) {
        let spec = parse_json_or_null(spec_raw);
        if (type(spec) == "object" && type(spec.outputs) == "object") {
            for (let out_name, out in spec.outputs) {
                if (type(out) == "object" && out.kind == "vless") {
                    if (target_sec_name == null || target_sec_name == "" || out_name == target_sec_name) {
                        command_status("ubus call service signal '" + sprintf('{"name":"steer","instance":"vless_%s","signal":15}', out_name) + "' >/dev/null 2>&1");
                        restarted = true;
                    }
                }
            }
        }
    }
    if (!restarted)
        command_status("/etc/init.d/steer restart >/dev/null 2>&1");
    command_status("conntrack -F >/dev/null 2>&1 || true");
    return restarted;
}

function steer_apply_best_nodes(sname, best_node_idx, candidate_indices) {
    if (sname == null || sname == "") return false;
    let spec_path = "/etc/steer/spec.json";
    let spec_raw = fs.readfile(spec_path);
    if (spec_raw == null) return false;
    let spec = parse_json_or_null(spec_raw);
    if (type(spec) != "object" || type(spec.outputs) != "object" || type(spec.outputs[sname]) != "object")
        return false;

    let out = spec.outputs[sname];
    if (out.kind != "vless") return false;

    let lat_data = steer_get_cached_latencies();
    let pool = [];
    if (type(candidate_indices) == "array" && length(candidate_indices) > 0) {
        pool = candidate_indices;
    } else if (type(out.nodes) == "array" && length(out.nodes) > 0) {
        pool = out.nodes;
    }

    if (length(pool) == 0 && best_node_idx != null)
        pool = [ best_node_idx ];

    let sorted = sort(pool, function(a, b) {
        if (best_node_idx != null) {
            if (a == best_node_idx && b != best_node_idx) return -1;
            if (b == best_node_idx && a != best_node_idx) return 1;
        }
        let da = lat_data["proxy-" + a];
        let db = lat_data["proxy-" + b];
        let sa = (da != null && int(da) > 0) ? int(da) : (da == null ? 5000000 + a : 9000000 + a);
        let sb = (db != null && int(db) > 0) ? int(db) : (db == null ? 5000000 + b : 9000000 + b);
        return sa - sb;
    });

    let unique_nodes = [];
    let seen_idx = {};
    for (let ni in sorted) {
        let nint = int(ni);
        if (nint != null && nint != "NaN" && !seen_idx[nint]) {
            push(unique_nodes, nint);
            seen_idx[nint] = true;
        }
    }
    if (length(unique_nodes) > 16)
        unique_nodes = slice(unique_nodes, 0, 16);

    if (length(unique_nodes) == 0) return false;

    let current_nodes = type(out.nodes) == "array" ? out.nodes : [];
    let changed = (length(current_nodes) != length(unique_nodes));
    if (!changed) {
        for (let i = 0; i < length(unique_nodes); i++) {
            if (current_nodes[i] != unique_nodes[i]) {
                changed = true;
                break;
            }
        }
    }

    if (!changed) return false;

    out.nodes = unique_nodes;
    let tmp_path = spec_path + ".tachyon." + as_string(time());
    if (common.write_json_file(tmp_path, spec, 2)) {
        if (fs.rename(tmp_path, spec_path)) {
            steer_reload_vless_workers(sname);
            return true;
        }
        common.remove_file(tmp_path);
    }
    return false;
}

const STEER_SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") ||
    (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/section-cache";
const STEER_SUBS_DIR = getenv("TACHYON_STEER_SUBS_DIR") || "/etc/steer/subs";

function steer_build_section_context(section_name) {
    section_name = as_string(section_name);
    if (section_name == "") return null;

    let cache_file = STEER_SECTION_CACHE_DIR + "/" + section_name + ".json";
    let cache_data = common.read_json_file(cache_file);
    if (type(cache_data) != "object")
        return null;

    let links = cache_data.links || {};
    let metadata = cache_data.outboundMetadata || {};
    let names = metadata.names || {};
    let transports = metadata.transports || {};
    let hidden = cache_data.hiddenOutboundTags || {};
    let urltest_groups = cache_data.urltestGroups || {};
    let uci_urltests = uci_core.section_objects(CONFIG_NAME, "urltest");
    for (let ut in uci_urltests) {
        if (ut.section == section_name) {
            let ut_name = ut.name || ut[".name"];
            let ut_sec_id = section_name + "-urltest-" + ut[".name"] + "-out";
            let already_exists = false;
            for (let gid, g in urltest_groups) {
                if (gid == ut_sec_id || g.displayName == ut_name) {
                    already_exists = true;
                    break;
                }
            }
            if (!already_exists) {
                let ut_id = ut_sec_id;
                let ut_outbounds = [];
                for (let tag, link in links) {
                    if (!hidden[tag])
                        push(ut_outbounds, tag);
                }
                if (length(ut_outbounds) == 0) {
                    for (let tag, link in links)
                        push(ut_outbounds, tag);
                }
                urltest_groups[ut_id] = {
                    displayName: ut_name,
                    outbounds: ut_outbounds
                };
            }
        }
    }

    let tag_to_idx = {};
    let idx_to_tag = {};
    let vless_idx = 0;
    // Numbering MUST match steer/lists.uc write_subscription_file(): urltest
    // group outbounds first, then non-hidden links, then the rest — vless-probe
    // --node N addresses nodes by their position in the sub file.
    let ordered_tags = [];
    if (type(cache_data.urltestGroups) == "object") {
        for (let grp_id, grp in cache_data.urltestGroups) {
            if (type(grp) == "object" && type(grp.outbounds) == "array") {
                for (let ob in grp.outbounds) {
                    let link = links[ob];
                    if (link != null && match(trim(as_string(link)), /^vless:\/\//) != null && index(ordered_tags, ob) < 0)
                        push(ordered_tags, ob);
                }
            }
        }
    }
    let hidden_ordered = type(hidden) == "object" ? hidden : {};
    for (let name, link in links) {
        if (index(ordered_tags, name) >= 0 || hidden_ordered[name]) continue;
        link = trim(as_string(link));
        if (match(link, /^vless:\/\//) != null)
            push(ordered_tags, name);
    }
    for (let name, link in links) {
        if (index(ordered_tags, name) >= 0) continue;
        link = trim(as_string(link));
        if (match(link, /^vless:\/\//) != null)
            push(ordered_tags, name);
    }
    for (let name in ordered_tags) {
        tag_to_idx[name] = vless_idx;
        idx_to_tag[vless_idx] = name;
        let unprefixed = replace(name, /^.*?\s+/, "");
        if (unprefixed != name && tag_to_idx[unprefixed] == null)
            tag_to_idx[unprefixed] = vless_idx;
        vless_idx++;
    }

    // This section's vless output reads its own sub file (see lists.uc);
    // fall back to the shared legacy path when the per-section file is absent.
    let sub_file = STEER_SUBS_DIR + "/" + replace(section_name, /[^A-Za-z0-9_.-]/g, "_") + ".txt";
    if (fs.stat(sub_file) == null)
        sub_file = "/etc/steer/sub.txt";

    return {
        sname: section_name,
        cache_data: cache_data,
        links: links,
        names: names,
        transports: transports,
        hidden: hidden,
        urltest_groups: urltest_groups,
        tag_to_idx: tag_to_idx,
        idx_to_tag: idx_to_tag,
        vless_count: vless_idx,
        sub_file: sub_file
    };
}

function clash_api(action, arg1, arg2, arg3) {
    if (active_engine_is_steer()) {
        if (action == "get_proxies") {
            let proxies = {};
            let latencies = steer_get_cached_latencies();
            let sections = uci_core.section_objects(CONFIG_NAME, "section");
            let persistent_state = common.read_json_file(getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json");
            if (type(persistent_state) != "object")
                persistent_state = {};

            for (let sec in sections) {
                let sname = as_string(sec[".name"]);
                if (sname == "") continue;
                let ctx = steer_build_section_context(sname);
                if (!ctx) continue;

                for (let tag, link in ctx.links) {
                    let delay = steer_lookup_latency(latencies, tag, ctx);
                    let hist = [];
                    if (delay != null && int(delay) > 0)
                        push(hist, { delay: int(delay), time: "2026-09-22T13:00:00Z" });
                    else if (delay != null && int(delay) == 0 && (latencies[tag] != null || (ctx.tag_to_idx && latencies["proxy-" + ctx.tag_to_idx[tag]] != null)))
                        push(hist, { delay: 0, time: "2026-09-22T13:00:00Z" });
                    proxies[tag] = {
                        name: ctx.names[tag] || tag,
                        type: ctx.transports[tag] || "Vless",
                        udp: true,
                        history: hist
                    };
                }

                let group_ids = [];
                for (let grp_id, grp in ctx.urltest_groups) {
                    push(group_ids, grp_id);
                    let best_child_delay = null;
                    let chosen_child = (type(grp.outbounds) == "array" && length(grp.outbounds) > 0) ? grp.outbounds[0] : "";
                    for (let child in grp.outbounds) {
                        let cd = steer_lookup_latency(latencies, child, ctx);
                        if (cd != null && int(cd) > 0) {
                            if (best_child_delay == null || int(cd) < int(best_child_delay)) {
                                best_child_delay = int(cd);
                                chosen_child = child;
                            }
                        }
                    }
                    let explicit_grp_delay = steer_lookup_latency(latencies, grp_id, ctx);
                    let effective_grp_delay = best_child_delay != null ? best_child_delay : (explicit_grp_delay != null ? int(explicit_grp_delay) : 0);
                    let hist = [];
                    if (effective_grp_delay > 0)
                        push(hist, { delay: effective_grp_delay, time: "2026-09-22T13:00:00Z" });
                    proxies[grp_id] = {
                        name: grp_id,
                        type: "URLTest",
                        all: grp.outbounds,
                        now: chosen_child,
                        history: hist
                    };
                }

                let selector_all = [];
                for (let gid in group_ids) {
                    if (index(gid, "-urltest-") >= 0)
                        push(selector_all, gid);
                }
                for (let gid in group_ids) {
                    if (index(gid, "-urltest-") < 0)
                        push(selector_all, gid);
                }
                for (let tag, link in ctx.links) {
                    if (!ctx.hidden[tag])
                        push(selector_all, tag);
                }
                if (length(selector_all) == 0) {
                    for (let tag, link in ctx.links)
                        push(selector_all, tag);
                }

                let saved_choice = as_string(persistent_state[sname] || "");
                let uci_node = uci_core.get(CONFIG_NAME + "." + sname + ".node");
                let now_tag = "";

                if (saved_choice != "" && proxies[saved_choice] != null) {
                    now_tag = saved_choice;
                } else if (uci_node == "auto" || uci_node == "urltest" || uci_node == null || uci_node == "") {
                    now_tag = length(selector_all) > 0 ? selector_all[0] : "";
                } else if (proxies[uci_node] != null) {
                    now_tag = uci_node;
                } else {
                    let m = match(uci_node, /proxy-(\d+)/);
                    let idx = m ? int(m[1]) : int(uci_node);
                    if (ctx.idx_to_tag[idx] != null)
                        now_tag = ctx.idx_to_tag[idx];
                    else
                        now_tag = length(selector_all) > 0 ? selector_all[0] : "";
                }

                let sec_delay = (proxies[now_tag] && type(proxies[now_tag].history) == "array" && length(proxies[now_tag].history) > 0)
                    ? proxies[now_tag].history[0].delay
                    : steer_lookup_latency(latencies, now_tag, ctx);
                let sec_hist = [];
                if (sec_delay != null && int(sec_delay) > 0)
                    push(sec_hist, { delay: int(sec_delay), time: "2026-09-22T13:00:00Z" });

                let sel_tag = sname + "-out";
                proxies[sel_tag] = {
                    name: sel_tag,
                    type: "Selector",
                    now: now_tag,
                    all: selector_all,
                    history: sec_hist
                };

                if (uci_node == "auto" || uci_node == "urltest" || uci_node == null || uci_node == "") {
                    let target_candidate_indices = [];
                    let best_node_to_apply = null;
                    if (proxies[now_tag] != null && proxies[now_tag].type == "URLTest") {
                        let active_grp = proxies[now_tag];
                        for (let child in active_grp.all) {
                            if (ctx.tag_to_idx[child] != null)
                                push(target_candidate_indices, ctx.tag_to_idx[child]);
                        }
                        if (active_grp.now != null && ctx.tag_to_idx[active_grp.now] != null)
                            best_node_to_apply = ctx.tag_to_idx[active_grp.now];
                    }
                    if (best_node_to_apply != null)
                        steer_apply_best_nodes(sname, best_node_to_apply, target_candidate_indices);
                }
            }
            print(sprintf("%J\n", { proxies: proxies }));
            return 0;
        }

        if (action == "get_connections") {
            let total_down = 0;
            let total_up = 0;
            let st_raw = fs.readfile("/var/lib/steer/status.json");
            let mark_to_output = {};
            if (st_raw) {
                let st_json = json(st_raw);
                if (st_json) {
                    if (type(st_json.channels) == "array") {
                        for (let ch in st_json.channels) {
                            if (ch.out != "direct") {
                                total_up += (int(ch.bytes) || 0);
                                total_down += (int(ch.down_bytes) || 0);
                            }
                        }
                    }
                    if (type(st_json.outputs) == "object") {
                        for (let oname, odata in st_json.outputs) {
                            if (odata.mark) {
                                let mv = int(odata.mark);
                                if (mv > 0) mark_to_output[mv] = oname;
                            }
                        }
                    }
                }
            }
            let rx = fs.readfile("/sys/class/net/Main/statistics/rx_bytes");
            let tx = fs.readfile("/sys/class/net/Main/statistics/tx_bytes");
            if (rx != null) {
                let rx_val = int(trim(as_string(rx))) || 0;
                if (rx_val > total_down) total_down = rx_val;
            }
            if (tx != null) {
                let tx_val = int(trim(as_string(tx))) || 0;
                if (tx_val > total_up) total_up = tx_val;
            }

            let mem_bytes = 6291456;
            let proc_dir = fs.opendir("/proc");
            if (proc_dir) {
                let ent;
                let steer_kb = 0;
                while ((ent = proc_dir.read()) != null) {
                    if (match(ent, /^[0-9]+$/)) {
                        let comm = trim(as_string(fs.readfile("/proc/" + ent + "/comm")));
                        if (comm == "steer") {
                            let status = fs.readfile("/proc/" + ent + "/status");
                            if (status) {
                                let m = match(status, /VmRSS:[ \t]+([0-9]+)/);
                                if (m) steer_kb += int(m[1]);
                            }
                        }
                    }
                }
                proc_dir.close();
                if (steer_kb > 0)
                    mem_bytes = steer_kb * 1024;
            }

            let fakeip_map = {};
            let fip_file = fs.open("/var/lib/steer/fakeip.state", "r");
            if (fip_file) {
                let fline;
                while ((fline = fip_file.read("line")) != null) {
                    let parts = split(trim(fline), /[ \t]+/);
                    if (length(parts) >= 2) {
                        let dom = parts[0];
                        for (let pi = 1; pi < length(parts); pi++)
                            fakeip_map[parts[pi]] = dom;
                    }
                }
                fip_file.close();
            }

            let conns = [];
            let ct_file = fs.open("/proc/net/nf_conntrack", "r");
            if (ct_file) {
                let line;
                while (true) {
                    line = ct_file.read("line");
                    if (line == null) break;
                    let m = match(line, /ipv[46]\s+\d+\s+([a-zA-Z0-9]+)\s+.*?src=(\d+\.\d+\.\d+\.\d+)\s+dst=(\d+\.\d+\.\d+\.\d+)\s+sport=(\d+)\s+dport=(\d+)\s+packets=\d+\s+bytes=(\d+).*?bytes=(\d+)/);
                    if (m) {
                        let src_ip = m[2];
                        if (match(src_ip, /^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/) && src_ip != "127.0.0.1") {
                            let proto = lc(m[1]);
                            let dst_ip = m[3];
                            let src_port = m[4];
                            let dst_port = m[5];
                            let up_bytes = int(m[6]) || 0;
                            let down_bytes = int(m[7]) || 0;

                            let mm = match(line, /mark=(\d+)/);
                            let conn_mark = mm ? int(mm[1]) : 0;
                            let route_name = "";
                            for (let mv, oname in mark_to_output) {
                                if ((conn_mark & mv) == mv) {
                                    route_name = oname;
                                    break;
                                }
                            }
                            if (route_name == "") {
                                if (match(dst_ip, /^(192\.168\.|10\.|127\.|172\.(1[6-9]|2\d|3[01])\.)/))
                                    route_name = "direct";
                                else
                                    route_name = "Main";
                            }

                            let host = fakeip_map[dst_ip] || "";
                            let cid = sprintf("%s-%s-%s-%s-%s", proto, src_ip, src_port, dst_ip, dst_port);

                            push(conns, {
                                id: cid,
                                metadata: {
                                    network: proto,
                                    type: "Inner",
                                    sourceIP: src_ip,
                                    sourcePort: src_port,
                                    destinationIP: dst_ip,
                                    destinationPort: dst_port,
                                    host: host
                                },
                                upload: up_bytes,
                                download: down_bytes,
                                chains: [ route_name ],
                                rule: route_name
                            });
                            if (length(conns) >= 250) break;
                        }
                    }
                }
                ct_file.close();
            }

            if (length(conns) == 0) {
                let conntrack_str = fs.readfile("/proc/sys/net/netfilter/nf_conntrack_count");
                let conn_count = conntrack_str != null ? (int(trim(as_string(conntrack_str))) || 0) : 0;
                let emit_count = conn_count > 100 ? 100 : conn_count;
                for (let i = 0; i < emit_count; i++) {
                    push(conns, { id: sprintf("c-%d", i) });
                }
            }

            print(sprintf("%J\n", {
                downloadTotal: total_down,
                uploadTotal: total_up,
                memory: mem_bytes,
                connections: conns
            }));
            return 0;
        }

        if (action == "get_proxy_latency") {
            if (as_string(arg1) == "")
                return clash_json_error("proxy_tag required");
            let target_tag = as_string(arg1);
            let timeout_sec = int((int(arg2 || "3000") + 999) / 1000);
            if (timeout_sec < 1) timeout_sec = 1;

            let tag_to_idx = {};
            let probe_ctx = null;
            let all_urltest_groups = {};
            let sections = uci_core.section_objects(CONFIG_NAME, "section");
            for (let sec in sections) {
                let sname = as_string(sec[".name"]);
                let ctx = steer_build_section_context(sname);
                if (ctx) {
                    for (let t, idx in ctx.tag_to_idx)
                        tag_to_idx[t] = idx;
                    for (let gid, grp in ctx.urltest_groups) {
                        all_urltest_groups[gid] = grp;
                        if (grp.displayName) all_urltest_groups[grp.displayName] = grp;
                    }
                    // Remember the section that owns this tag: its own sub file
                    // and node numbering are what vless-probe must use.
                    if (probe_ctx == null && (ctx.tag_to_idx[target_tag] != null || all_urltest_groups[target_tag] != null))
                        probe_ctx = ctx;
                }
            }

            let node_idx = null;
            if (all_urltest_groups[target_tag] != null) {
                let grp = all_urltest_groups[target_tag];
                let latencies = steer_get_cached_latencies();
                for (let child in grp.outbounds) {
                    if (latencies[child] != null && int(latencies[child]) > 0) {
                        if (node_idx == null || int(latencies[child]) < int(latencies[tag_to_idx[node_idx] || ""]))
                            node_idx = tag_to_idx[child];
                    }
                }
                if (node_idx == null) {
                    for (let child in grp.outbounds) {
                        if (tag_to_idx[child] != null) {
                            node_idx = tag_to_idx[child];
                            break;
                        }
                    }
                }
            } else {
                node_idx = tag_to_idx[target_tag];
                if (node_idx == null) {
                    let m = match(target_tag, /proxy-(\d+)/);
                    if (m) node_idx = int(m[1]);
                }
            }

            if (node_idx == null)
                node_idx = int(target_tag);

            let sub_file = probe_ctx != null ? probe_ctx.sub_file : "/etc/steer/sub.txt";
            let probe_out = trim(command_output_from_args([ "/usr/sbin/steer", "vless-probe", sub_file, "--node", as_string(node_idx), "--timeout", as_string(timeout_sec) ]));
            let probe_json = parse_json_or_null(probe_out);
            let res_item = (type(probe_json) == "object" && type(probe_json.results) == "array" && length(probe_json.results) > 0) ? probe_json.results[0] : probe_json;
            let ok = (type(res_item) == "object" && res_item.ok);
            let handshake = ok ? int(res_item.handshake_ms || 0) : 0;
            let ttfb = ok ? int(res_item.ttfb_ms || 0) : 0;
            let delay = ok ? (handshake > 0 ? handshake + (ttfb > 0 ? ttfb : 0) : (ttfb > 0 ? ttfb : 1)) : 0;

            steer_set_cached_latency(target_tag, delay);
            steer_set_cached_latency("proxy-" + node_idx, delay);
            print(sprintf("%J\n", { delay: delay }));
            return 0;
        }

        if (action == "get_group_latency") {
            // Clash contract: probe every member of the group and answer with a
            // {tag: delay} map (runSectionsCheck reads values, not a scalar).
            let group = as_string(arg1);
            let timeout_sec = int((int(arg2 || "5000") + 999) / 1000);
            if (timeout_sec < 1) timeout_sec = 1;

            let group_children = [];
            let probe_ctx = null;
            let sections = uci_core.section_objects(CONFIG_NAME, "section");
            for (let sec in sections) {
                let sname = as_string(sec[".name"]);
                let ctx = steer_build_section_context(sname);
                if (!ctx) continue;

                // Section selector itself: test every node in this section
                if (sname == group || sname + "-out" == group || group == "selector") {
                    for (let tag, link in ctx.links)
                        push(group_children, tag);
                    probe_ctx = ctx;
                    break;
                }

                let grp = null;
                if (type(ctx.urltest_groups) == "object") {
                    if (ctx.urltest_groups[group] != null)
                        grp = ctx.urltest_groups[group];
                    else {
                        for (let gid, gdata in ctx.urltest_groups) {
                            if (gdata.displayName == group || gid == group) {
                                grp = gdata;
                                break;
                            }
                        }
                    }
                }
                if (grp != null && type(grp.outbounds) == "array") {
                    for (let child in grp.outbounds)
                        push(group_children, child);
                    if (probe_ctx == null)
                        probe_ctx = ctx;
                    break;
                }
            }
            if (length(group_children) == 0 && probe_ctx == null) {
                for (let sec in sections) {
                    let ctx = steer_build_section_context(as_string(sec[".name"]));
                    if (ctx && ctx.links) {
                        for (let tag, link in ctx.links)
                            push(group_children, tag);
                        if (probe_ctx == null)
                            probe_ctx = ctx;
                    }
                }
            }

            let result = {};
            let sub_file = probe_ctx != null ? probe_ctx.sub_file : "/etc/steer/sub.txt";
            let latencies = steer_get_cached_latencies();
            let best_tag = null;
            let best_delay = null;
            for (let tag in group_children) {
                let node_idx = probe_ctx != null ? probe_ctx.tag_to_idx[tag] : null;
                if (node_idx == null) {
                    let m = match(as_string(tag), /proxy-(\d+)/);
                    if (m) node_idx = int(m[1]);
                }
                let delay = 0;
                if (node_idx != null) {
                    let probe_out = trim(command_output_from_args([ "/usr/sbin/steer", "vless-probe", sub_file, "--node", as_string(node_idx), "--timeout", as_string(timeout_sec) ]));
                    let probe_json = parse_json_or_null(probe_out);
                    let res_item = (type(probe_json) == "object" && type(probe_json.results) == "array" && length(probe_json.results) > 0) ? probe_json.results[0] : probe_json;
                    let ok = (type(res_item) == "object" && res_item.ok);
                    let handshake = ok ? int(res_item.handshake_ms || 0) : 0;
                    let ttfb = ok ? int(res_item.ttfb_ms || 0) : 0;
                    delay = ok ? (handshake > 0 ? handshake + (ttfb > 0 ? ttfb : 0) : (ttfb > 0 ? ttfb : 1)) : 0;
                    steer_set_cached_latency(as_string(tag), delay);
                    steer_set_cached_latency("proxy-" + as_string(node_idx), delay);
                }
                result[as_string(tag)] = delay;
                if (delay > 0 && (best_delay == null || delay < best_delay)) {
                    best_delay = delay;
                    best_tag = as_string(tag);
                }
            }

            // The group row itself shows the best member delay.
            if (best_delay != null) {
                steer_set_cached_latency(group, best_delay);
                if (probe_ctx != null && probe_ctx.sname != null)
                    steer_set_cached_latency(probe_ctx.sname + "-out", best_delay);
            }

            if (best_tag != null && probe_ctx != null && probe_ctx.sname != null) {
                let candidate_indices = [];
                for (let tag in group_children) {
                    if (probe_ctx.tag_to_idx[tag] != null)
                        push(candidate_indices, probe_ctx.tag_to_idx[tag]);
                }
                let best_node_idx = probe_ctx.tag_to_idx[best_tag];
                let uci_node = uci_core.get(CONFIG_NAME + "." + probe_ctx.sname + ".node");
                if (uci_node == "auto" || uci_node == "urltest" || uci_node == null || uci_node == "") {
                    steer_apply_best_nodes(probe_ctx.sname, best_node_idx, candidate_indices);
                }
            }
            print(sprintf("%J\n", result));
            return 0;
        }

        if (action == "get_proxy_latencies") {
            if (as_string(arg1) == "")
                return clash_json_error("proxy_tags_json required");
            let tags_list = [];
            let parsed = json(as_string(arg1));
            if (type(parsed) == "array") {
                tags_list = parsed;
            } else {
                let tags = status_capture([ "clash-proxy-tags-lines", arg1 ], null);
                if (tags.status == 0) {
                    for (let pt in split(tags.output, "\n")) {
                        pt = trim(as_string(pt));
                        if (pt != "") push(tags_list, pt);
                    }
                }
            }

            let tag_to_idx = {};
            let tag_to_sub = {};
            let sections = uci_core.section_objects(CONFIG_NAME, "section");
            let section_contexts = {};
            for (let sec in sections) {
                let sname = as_string(sec[".name"]);
                let ctx = steer_build_section_context(sname);
                if (ctx) {
                    section_contexts[sname] = ctx;
                    for (let t, idx in ctx.tag_to_idx) {
                        tag_to_idx[t] = idx;
                        tag_to_sub[t] = ctx.sub_file;
                    }
                }
            }

            let expanded_tags = [];
            for (let target_tag in tags_list) {
                let is_group = false;
                for (let sname, ctx in section_contexts) {
                    if (sname == target_tag || sname + "-out" == target_tag || target_tag == "selector") {
                        is_group = true;
                        for (let ctag, link in ctx.links) {
                            if (index(expanded_tags, ctag) < 0)
                                push(expanded_tags, ctag);
                        }
                        break;
                    }
                    if (type(ctx.urltest_groups) == "object") {
                        let grp = ctx.urltest_groups[target_tag];
                        if (!grp) {
                            for (let gid, gdata in ctx.urltest_groups) {
                                if (gid == target_tag || gdata.displayName == target_tag) {
                                    grp = gdata;
                                    break;
                                }
                            }
                        }
                        if (grp && type(grp.outbounds) == "array") {
                            is_group = true;
                            for (let ctag in grp.outbounds) {
                                if (index(expanded_tags, ctag) < 0)
                                    push(expanded_tags, ctag);
                            }
                            break;
                        }
                    }
                }
                if (!is_group && index(expanded_tags, target_tag) < 0)
                    push(expanded_tags, target_tag);
            }

            let count = 0;
            let failed = 0;
            let progress_path = as_string(arg3);
            let total = length(expanded_tags);
            if (progress_path != "")
                module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);

            let timeout_sec = int((int(arg2 || "3000") + 999) / 1000);
            if (timeout_sec < 1) timeout_sec = 1;

            for (let target_tag in expanded_tags) {
                let node_idx = tag_to_idx[target_tag];
                let sub_file = tag_to_sub[target_tag] || "/etc/steer/sub.txt";
                if (node_idx == null) {
                    let m = match(target_tag, /proxy-(\d+)/);
                    node_idx = m ? int(m[1]) : int(target_tag);
                }
                if (node_idx != null) {
                    let probe_out = trim(command_output_from_args([ "/usr/sbin/steer", "vless-probe", sub_file, "--node", as_string(node_idx), "--timeout", as_string(timeout_sec) ]));
                    let probe_json = parse_json_or_null(probe_out);
                    let res_item = (type(probe_json) == "object" && type(probe_json.results) == "array" && length(probe_json.results) > 0) ? probe_json.results[0] : probe_json;
                    let ok = (type(res_item) == "object" && res_item.ok);
                    let handshake = ok ? int(res_item.handshake_ms || 0) : 0;
                    let ttfb = ok ? int(res_item.ttfb_ms || 0) : 0;
                    let delay = ok ? (handshake > 0 ? handshake + (ttfb > 0 ? ttfb : 0) : (ttfb > 0 ? ttfb : 1)) : 0;
                    if (!ok) failed++;
                    steer_set_cached_latency(target_tag, delay);
                    steer_set_cached_latency("proxy-" + node_idx, delay);
                } else {
                    failed++;
                }
                count++;
                if (progress_path != "")
                    module_success(SERVICE_UI_UC, [ "latency-progress-state", progress_path, count, total, failed ]);
            }

            let fresh_latencies = steer_get_cached_latencies();
            for (let sname, ctx in section_contexts) {
                let uci_node = uci_core.get(CONFIG_NAME + "." + sname + ".node");
                let sec_best_delay = null;
                let sec_best_node_idx = null;
                let sec_candidate_indices = [];

                if (type(ctx.urltest_groups) == "object") {
                    for (let grp_id, grp in ctx.urltest_groups) {
                        let grp_min = null;
                        let grp_best_idx = null;
                        for (let child in grp.outbounds) {
                            let cd = steer_lookup_latency(fresh_latencies, child, ctx);
                            let cidx = ctx.tag_to_idx[child];
                            if (cidx != null && index(sec_candidate_indices, cidx) < 0)
                                push(sec_candidate_indices, cidx);
                            if (cd != null && int(cd) > 0) {
                                if (grp_min == null || int(cd) < grp_min) {
                                    grp_min = int(cd);
                                    grp_best_idx = cidx;
                                }
                            }
                        }
                        if (grp_min != null) {
                            steer_set_cached_latency(grp_id, grp_min);
                            if (grp.displayName)
                                steer_set_cached_latency(grp.displayName, grp_min);
                            if (sec_best_delay == null || grp_min < sec_best_delay) {
                                sec_best_delay = grp_min;
                                sec_best_node_idx = grp_best_idx;
                            }
                        }
                    }
                }

                if (sec_best_delay != null)
                    steer_set_cached_latency(sname + "-out", sec_best_delay);

                if (sec_best_node_idx != null && (uci_node == "auto" || uci_node == "urltest" || uci_node == null || uci_node == "")) {
                    steer_apply_best_nodes(sname, sec_best_node_idx, sec_candidate_indices);
                }
            }

            print(sprintf("%J\n", { status: 0 }));
            return 0;
        }

        if (action == "set_group_proxy") {
            if (as_string(arg1) == "" || as_string(arg2) == "")
                return clash_json_error("group_tag and proxy_tag required");

            let raw_group = as_string(arg1);
            let target_group = replace(raw_group, /-out$/, "");
            let target_proxy = as_string(arg2);
            let ctx = steer_build_section_context(target_group);

            let matched_urltest = ctx && ctx.urltest_groups ? ctx.urltest_groups[target_proxy] : null;
            if (matched_urltest == null && ctx && ctx.urltest_groups) {
                for (let gid, grp in ctx.urltest_groups) {
                    if (grp.displayName == target_proxy) {
                        matched_urltest = grp;
                        break;
                    }
                }
            }

            if (matched_urltest != null) {
                let node_indices = [];
                for (let child in matched_urltest.outbounds) {
                    if (ctx.tag_to_idx[child] != null)
                        push(node_indices, ctx.tag_to_idx[child]);
                }
                uci_core.set(CONFIG_NAME + "." + target_group + ".node", "auto");
                if (length(node_indices) > 0)
                    uci_core.set(CONFIG_NAME + "." + target_group + ".nodes", join(" ", node_indices));
                else
                    uci_core.delete(CONFIG_NAME + "." + target_group + ".nodes");
            } else if (target_proxy == "⚡ Auto (URL Test)" || target_proxy == "auto") {
                uci_core.set(CONFIG_NAME + "." + target_group + ".node", "auto");
                uci_core.delete(CONFIG_NAME + "." + target_group + ".nodes");
            } else {
                let node_idx = ctx && ctx.tag_to_idx ? ctx.tag_to_idx[target_proxy] : null;
                if (node_idx == null) {
                    let m = match(target_proxy, /proxy-(\d+)/);
                    if (m)
                        node_idx = int(m[1]);
                    else if (match(target_proxy, /^\d+$/))
                        node_idx = int(target_proxy);
                    else
                        node_idx = "auto";
                }
                uci_core.set(CONFIG_NAME + "." + target_group + ".node", as_string(node_idx));
                uci_core.delete(CONFIG_NAME + "." + target_group + ".nodes");
            }

            uci_core.commit(CONFIG_NAME);
            // The node list is read by the vless process from the spec at
            // startup: regenerate the spec, then restart only the vless
            // instances (procd re-runs them with the fresh spec). A full
            // `/etc/init.d/steer restart` would also kill dnsd and drop the
            // rules — seconds of DNS outage on every node switch.
            command_status("ucode -L " + LIB_DIR + " " + LIB_DIR + "/service/engine_runtime.uc engine-generate >/dev/null 2>&1");
            let restarted_vless = false;
            let spec_raw = fs.readfile("/etc/steer/spec.json");
            if (spec_raw != null) {
                let spec = parse_json_or_null(spec_raw);
                if (type(spec) == "object" && type(spec.outputs) == "object") {
                    for (let out_name, out in spec.outputs) {
                        if (type(out) == "object" && out.kind == "vless") {
                            command_status("ubus call service signal '" + sprintf('{"name":"steer","instance":"vless_%s","signal":15}', out_name) + "' >/dev/null 2>&1");
                            restarted_vless = true;
                        }
                    }
                }
            }
            if (!restarted_vless)
                command_status("/etc/init.d/steer restart >/dev/null 2>&1");
            command_status("conntrack -F >/dev/null 2>&1 || true");
            save_persistent_selector_choice(target_group, target_proxy);
            save_persistent_selector_choice(target_group + "-out", target_proxy);
            let result = status_capture([ "clash-set-group-proxy-result", target_group, target_proxy ], "\n204");
            if (result.output != "")
                print(result.output);
            return result.status;
        }

        if (action == "restore_selector_state") {
            let path = getenv("TACHYON_PERSISTENT_SELECTOR_STATE_FILE") || "/etc/tachyon/selector_state.json";
            let state = common.read_json_file(path);
            if (type(state) == "object") {
                for (let group, selected in state) {
                    clash_api("set_group_proxy", group, selected);
                }
            }
            return 0;
        }

        if (action == "close_connection" || action == "close_all_connections") {
            command_status("conntrack -F >/dev/null 2>&1 || true");
            print("\n204");
            return 0;
        }
    }

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
        let proxy_types = clash_proxy_type_map(base_url, auth);
        let endpoint = clash_latency_endpoint(base_url, arg1, proxy_types[arg1]);
        let args = [ "curl", "-G", "-s", endpoint ];
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

        let timeout_ms = as_string(arg2 || "2000");
        let max_time = as_string(int((int(timeout_ms, 10) + 2999) / 1000));
        if (int(max_time, 10) < 3)
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
                let batch_size = 12;
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
        if (result.status == 0) {
            command_status("conntrack -F >/dev/null 2>&1 || true");
            save_persistent_selector_choice(arg1, arg2);
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
            let grp = proxies[group];
            if (type(grp) == "object" && lc(as_string(grp.type || "")) == "selector" && index(grp.all, selected) >= 0 && as_string(grp.now || "") != selected) {
                clash_api("set_group_proxy", group, selected);
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
    nft_steer_chain_has_rules,
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
    steer_get_cached_latencies,
    steer_set_cached_latency,
    steer_set_cached_latencies_bulk,
    steer_lookup_latency,
    steer_reload_vless_workers,
    steer_apply_best_nodes,
    steer_build_section_context,
    clash_api
};
