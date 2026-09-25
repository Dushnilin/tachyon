#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const SB_TPROXY_INBOUND6_ADDRESS = getenv("SB_TPROXY_INBOUND6_ADDRESS") || constants.SB_TPROXY_INBOUND6_ADDRESS || "::1";
const SB_TPROXY_INBOUND_PORT = getenv("SB_TPROXY_INBOUND_PORT") || constants.SB_TPROXY_INBOUND_PORT || "1602";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_output_from_args = common.command_output_from_args;
let command_status = common.command_status;
let read_stdin = common.read_stdin;

function words(value) {
    let result = [];
    for (let word in split(as_string(value), /[ \t\r\n]+/)) {
        if (word != "")
            push(result, word);
    }
    return result;
}

function push_unique(target, seen, value) {
    value = as_string(value);
    if (value == "" || seen[value])
        return;
    seen[value] = true;
    push(target, value);
}

function parse_json_or_null(text) {
    text = as_string(text);
    if (text == "")
        return null;
    try {
        return json(text);
    } catch (e) {
        return null;
    }
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

function is_virtual_or_tunnel_iface(dev) {
    dev = trim(as_string(dev));
    if (dev == "" || dev == "lo")
        return true;
    if (match(dev, /^(tun|tap|tailscale|wg|docker|veth|br-|dummy|gre|sit|ifb)/))
        return true;
    return false;
}

function get_wan_ip_addresses() {
    let result = [];
    let seen = {};

    let ifaces = [ "wan", "wan6", "wwan", "wwan6" ];
    let custom_iface = trim(as_string(uci_core.get(CONFIG_NAME + ".settings.output_network_interface")));
    if (custom_iface != "" && !is_virtual_or_tunnel_iface(custom_iface))
        unshift(ifaces, custom_iface);

    for (let interface in ifaces) {
        let data = command_output_from_args([
            "ubus", "-S", "call", "network.interface." + interface, "status"
        ]);
        for (let ip in network_status_ip_addresses(data, "ipv4-address"))
            push_unique(result, seen, ip);
        for (let ip in network_status_ip_addresses(data, "ipv6-address"))
            push_unique(result, seen, ip);
    }

    if (length(result) > 0)
        return join(" ", result);

    let route = command_output_from_args([ "ip", "-4", "route", "show", "default" ]);
    for (let line in split(route, "\n")) {
        let m = match(line, /dev\s+([a-zA-Z0-9_\.\-]+)/);
        if (!m || !m[1])
            continue;
        let iface = m[1];
        if (is_virtual_or_tunnel_iface(iface))
            continue;

        let addr = command_output_from_args([ "ip", "-4", "addr", "show", "dev", iface ]);
        for (let l in split(addr, "\n")) {
            l = trim(as_string(l));
            let matched = match(l, /^inet[ \t]+([0-9.]+)\//);
            if (matched != null)
                push_unique(result, seen, matched[1]);
        }
        if (length(result) > 0)
            break;
    }

    return join(" ", result);
}

function get_wan_interface() {
    let iface = trim(as_string(uci_core.get(CONFIG_NAME + ".settings.output_network_interface")));
    if (iface != "" && !is_virtual_or_tunnel_iface(iface)) return iface;

    iface = trim(as_string(uci_core.get("network.wan.device")));
    if (iface != "" && !is_virtual_or_tunnel_iface(iface)) return iface;

    iface = trim(as_string(uci_core.get("network.wan.ifname")));
    if (iface != "" && !is_virtual_or_tunnel_iface(iface)) return iface;

    let ubus_data = command_output_from_args([ "ubus", "-S", "call", "network.interface.wan", "status" ]);
    let wan_stat = parse_json_or_null(ubus_data);
    if (type(wan_stat) == "object") {
        let dev = wan_stat.l3_device || wan_stat.device;
        if (dev && !is_virtual_or_tunnel_iface(dev))
            return dev;
    }

    let route = command_output_from_args([ "ip", "-4", "route", "show", "default" ]);
    for (let line in split(route, "\n")) {
        let m = match(line, /dev\s+([a-zA-Z0-9_\.\-]+)/);
        if (m && m[1] && !is_virtual_or_tunnel_iface(m[1]))
            return m[1];
    }

    return "eth0";
}

function default_gateway_exists() {
    let out = command_output_from_args([ "ip", "route" ]);
    return index(out, "default") >= 0;
}

function wan_has_ip() {
    let wan_ips = get_wan_ip_addresses();
    if (wan_ips != "") return true;

    let iface = get_wan_interface();
    let out = command_output_from_args([ "ip", "addr", "show", iface ]);
    if (index(out, "inet ") >= 0) return true;

    let ubus_status = command_output_from_args([ "ubus", "-S", "call", "network.interface.wan", "status" ]);
    let status_json = parse_json_or_null(ubus_status);
    if (type(status_json) == "object" && status_json.up === true)
        return true;

    return default_gateway_exists();
}

function device_ipv4_address(interface) {
    let output = command_output_from_args([ "ip", "-4", "addr", "show", "dev", interface ]);
    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        let matched = match(line, /^inet[ \t]+([0-9.]+)\//);
        if (matched != null)
            return as_string(matched[1]);
    }
    return "";
}

function sing_box_standard_ports_listening(netstat) {
    netstat = as_string(netstat);
    let port_53_ok = index(netstat, "127.0.0.42:53") >= 0;
    let tproxy_suffix = ":" + SB_TPROXY_INBOUND_PORT;
    let port_1602_ok = index(netstat, "0.0.0.0" + tproxy_suffix) >= 0 ||
        index(netstat, "127.0.0.1" + tproxy_suffix) >= 0;
    let port_1602_v6_ok = !core_ip.ipv6_supported() ||
        index(netstat, SB_TPROXY_INBOUND6_ADDRESS + tproxy_suffix) >= 0 ||
        index(netstat, "[" + SB_TPROXY_INBOUND6_ADDRESS + "]" + tproxy_suffix) >= 0 ||
        index(netstat, "0:0:0:0:0:0:0:1" + tproxy_suffix) >= 0 ||
        index(netstat, ":::" + SB_TPROXY_INBOUND_PORT) >= 0;
    return port_53_ok && port_1602_ok && port_1602_v6_ok;
}

function sing_box_standard_ports_listening_fixture() {
    exit(sing_box_standard_ports_listening(read_stdin()) ? 0 : 1);
}

function server_required_port_conflict_owners(listen, port, required_proto) {
    let status_mod = require("diagnostics.status_bridge");
    let netstat = command_output_from_args([ "netstat", "-lnp" ]);
    return replace(status_mod.status_output(
        [ "server-required-port-conflict-owners", listen, port, required_proto ],
        netstat
    ), /[\r\n]+$/g, "");
}

function server_required_ports_listening(listen, port, required_proto) {
    let status_mod = require("diagnostics.status_bridge");
    let netstat = command_output_from_args([ "netstat", "-ln" ]);
    return status_mod.status_success(
        [ "server-required-ports-listening", listen, port, required_proto ],
        netstat
    );
}

function uci_settings() {
    return uci_core.get_all(CONFIG_NAME, "settings") || {};
}

function lan_clients() {
    let clients = [];
    let seen = {};

    let excluded = {};
    let cfg = uci_settings();
    let exc_list = cfg.excluded_clients || cfg.excluded_ips || [];
    if (type(exc_list) == "string") {
        exc_list = words(exc_list);
    }
    if (type(exc_list) == "array") {
        for (let item in exc_list) {
            excluded[trim(as_string(item))] = true;
        }
    }

    let lease_files = [ "/tmp/dhcp.leases", "/var/lib/misc/dnsmasq.leases", "/tmp/hosts/dhcp" ];
    for (let lpath in lease_files) {
        let data = fs.readfile(lpath);
        if (!data) continue;
        for (let line in split(as_string(data), "\n")) {
            line = trim(line);
            if (line == "" || index(line, "#") == 0) continue;
            let fields = split(line, /[ \t]+/);
            if (length(fields) >= 4) {
                let mac = lc(fields[1]);
                let ip = fields[2];
                let hostname = fields[3] != "*" ? fields[3] : "";
                if (index(mac, ":") > 0 && index(ip, ".") > 0) {
                    if (!seen[ip]) {
                        seen[ip] = true;
                        push(clients, {
                            ip: ip,
                            mac: mac,
                            hostname: hostname != "" ? hostname : "Device-" + replace(substr(mac, length(mac) - 5), /:/g, ""),
                            is_online: true,
                            mode: (excluded[ip] || excluded[mac]) ? "direct" : "proxied"
                        });
                    }
                }
            }
        }
    }

    let arp_data = fs.readfile("/proc/net/arp");
    if (arp_data) {
        for (let line in split(as_string(arp_data), "\n")) {
            line = trim(line);
            if (line == "" || index(line, "IP address") == 0) continue;
            let fields = split(line, /[ \t]+/);
            if (length(fields) >= 4) {
                let ip = fields[0];
                let mac = lc(fields[3]);
                if (mac != "00:00:00:00:00:00" && index(mac, ":") > 0 && index(ip, ".") > 0) {
                    if (!seen[ip]) {
                        seen[ip] = true;
                        push(clients, {
                            ip: ip,
                            mac: mac,
                            hostname: "Device-" + replace(substr(mac, length(mac) - 5), /:/g, ""),
                            is_online: true,
                            mode: (excluded[ip] || excluded[mac]) ? "direct" : "proxied"
                        });
                    }
                }
            }
        }
    }

    print(sprintf("%J\n", {
        success: true,
        clients: clients,
        total: length(clients)
    }));
    return 0;
}

function toggle_client_bypass(target_ip) {
    target_ip = trim(as_string(target_ip));
    if (target_ip == "") {
        print(sprintf("%J\n", { success: false, error: "IP address is required" }));
        return 1;
    }

    let cfg = uci_settings();
    let exc_list = cfg.excluded_clients || cfg.excluded_ips || [];
    if (type(exc_list) == "string") {
        exc_list = words(exc_list);
    }
    let new_list = [];
    let found = false;
    if (type(exc_list) == "array") {
        for (let item in exc_list) {
            let str = trim(as_string(item));
            if (str == target_ip) {
                found = true;
            } else if (str != "") {
                push(new_list, str);
            }
        }
    }

    if (!found) {
        push(new_list, target_ip);
    }

    uci_core.set("tachyon", "settings", "excluded_clients", new_list);
    uci_core.commit("tachyon");
    command_status("/etc/init.d/tachyon reload >/dev/null 2>&1");

    print(sprintf("%J\n", {
        success: true,
        ip: target_ip,
        mode: found ? "proxied" : "direct",
        message: found ? "Client restored to proxy routing" : "Client added to Direct WAN bypass"
    }));
    return 0;
}

return {
    words,
    push_unique,
    parse_json_or_null,
    valid_ipv4,
    valid_public_ipv4,
    valid_public_ipv6,
    valid_public_ip,
    network_status_ip_addresses,
    is_virtual_or_tunnel_iface,
    get_wan_ip_addresses,
    get_wan_interface,
    default_gateway_exists,
    wan_has_ip,
    device_ipv4_address,
    sing_box_standard_ports_listening,
    sing_box_standard_ports_listening_fixture,
    server_required_port_conflict_owners,
    server_required_ports_listening,
    lan_clients,
    toggle_client_bypass
};
