#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const CORE_TPROXY_INBOUND6_ADDRESS = getenv("TACHYON_CORE_TPROXY_INBOUND6_ADDRESS") || getenv("CORE_TPROXY_INBOUND6_ADDRESS") || constants.TACHYON_CORE_TPROXY_INBOUND6_ADDRESS || constants.CORE_TPROXY_INBOUND6_ADDRESS || "::1";
const CORE_TPROXY_INBOUND_PORT = getenv("TACHYON_CORE_TPROXY_INBOUND_PORT") || getenv("CORE_TPROXY_INBOUND_PORT") || constants.TACHYON_CORE_TPROXY_INBOUND_PORT || constants.CORE_TPROXY_INBOUND_PORT || "1602";
const TACHYON_CORE_RUNTIME_UC = LIB_DIR + "/tachyon_core/runtime.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_output_from_args = common.command_output_from_args;
let command_status = common.command_status;
let read_stdin = common.read_stdin;

function words(value) {
    if (type(value) == "array") {
        let result = [];
        for (let item in value) {
            let s = trim(as_string(item));
            if (s != "")
                push(result, s);
        }
        return result;
    }
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

function is_non_local_ipv6(value) {
    value = lc(trim(as_string(value)));
    if (!core_ip.valid_ipv6(value))
        return false;
    if (value == "::" || value == "::1")
        return false;
    if (substr(value, 0, 2) == "ff" || match(value, /^fe[89ab]/) != null)
        return false;
    // Exclude FakeIPv6 pool fc00::/18 (fc00..fc3f)
    if (match(value, /^fc[0-3][0-9a-f]:/) != null)
        return false;
    return true;
}

function is_ula_ipv6(value) {
    return match(lc(trim(as_string(value))), /^f[cd][0-9a-f]{2}:/) != null;
}

function strip_cidr_suffix(cidr) {
    let s = trim(as_string(cidr));
    if (s == "")
        return "";
    return replace(s, /\/.*$/, "");
}

function first_ipv6_from_list(list_or_str) {
    let tokens = words(list_or_str);
    let ula = "";
    for (let tok in tokens) {
        let addr = strip_cidr_suffix(tok);
        if (!is_non_local_ipv6(addr))
            continue;
        if (!is_ula_ipv6(addr))
            return addr;
        if (ula == "")
            ula = addr;
    }
    return ula;
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
    let has_v4 = false;
    let has_v6 = false;

    let ifaces = [ "wan", "wan6", "wwan", "wwan6" ];
    let custom_iface = trim(as_string(uci_core.get(CONFIG_NAME + ".settings.output_network_interface")));
    if (custom_iface != "" && !is_virtual_or_tunnel_iface(custom_iface))
        unshift(ifaces, custom_iface);

    for (let interface in ifaces) {
        let data = command_output_from_args([
            "ubus", "-S", "call", "network.interface." + interface, "status"
        ]);
        for (let ip in network_status_ip_addresses(data, "ipv4-address")) {
            if (valid_ipv4(ip))
                has_v4 = true;
            push_unique(result, seen, ip);
        }
        for (let ip in network_status_ip_addresses(data, "ipv6-address")) {
            let addr = strip_cidr_suffix(ip);
            if (!is_non_local_ipv6(addr))
                continue;
            has_v6 = true;
            push_unique(result, seen, addr);
        }
    }

    if (!has_v4) {
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
                if (matched != null) {
                    has_v4 = true;
                    push_unique(result, seen, matched[1]);
                }
            }
            if (has_v4)
                break;
        }
    }

    if (!has_v6) {
        let route6 = command_output_from_args([ "ip", "-6", "route", "show", "default" ]);
        for (let line in split(route6, "\n")) {
            let m = match(line, /dev[ \t]+([a-zA-Z0-9_.-]+)/);
            if (!m || !m[1])
                continue;
            let iface = m[1];
            if (is_virtual_or_tunnel_iface(iface))
                continue;

            let addr6 = command_output_from_args([ "ip", "-6", "-o", "addr", "show", "dev", iface, "scope", "global" ]);
            for (let l in split(addr6, "\n")) {
                let matched = match(trim(as_string(l)), /(^|[ \t])inet6[ \t]+([0-9a-fA-F:]+)(\/[0-9]+)?/);
                if (matched != null && is_non_local_ipv6(matched[2]) && !is_ula_ipv6(matched[2])) {
                    has_v6 = true;
                    push_unique(result, seen, matched[2]);
                }
            }
            if (has_v6)
                break;
        }
        if (!has_v6 && ((getenv("TACHYON_MOCK_WAN6_STATUS_JSON") || "") != "" || (getenv("TACHYON_MOCK_WAN6_PD") || "") != "")) {
            let live = common.wan6_live_status();
            for (let cidr in (type(live.wan6_gua) == "array" ? live.wan6_gua : [])) {
                let addr = strip_cidr_suffix(cidr);
                if (is_non_local_ipv6(addr) && !is_ula_ipv6(addr))
                    push_unique(result, seen, addr);
            }
        }
    }

    return join(" ", result);
}

function get_wan_ipv6_addresses(settings_cfg, wan6_live) {
    let result = [];
    let seen = {};
    let ula = [];
    let seen_ula = {};
    let live = type(wan6_live) == "object" ? wan6_live : common.wan6_live_status();
    for (let cidr in (type(live.wan6_gua) == "array" ? live.wan6_gua : [])) {
        let addr = strip_cidr_suffix(cidr);
        if (!is_non_local_ipv6(addr))
            continue;
        if (is_ula_ipv6(addr))
            push_unique(ula, seen_ula, addr);
        else
            push_unique(result, seen, addr);
    }
    if (length(result) == 0) {
        for (let tok in words(get_wan_ip_addresses())) {
            let addr = strip_cidr_suffix(tok);
            if (!is_non_local_ipv6(addr))
                continue;
            if (is_ula_ipv6(addr))
                push_unique(ula, seen_ula, addr);
            else
                push_unique(result, seen, addr);
        }
    }
    return length(result) > 0 ? result : ula;
}

function get_lan_ipv6_addresses(settings_cfg) {
    let gua = [];
    let seen_gua = {};
    let ula = [];
    let seen_ula = {};
    let add_candidate = function(raw) {
        let addr = strip_cidr_suffix(raw);
        if (!is_non_local_ipv6(addr))
            return;
        if (is_ula_ipv6(addr))
            push_unique(ula, seen_ula, addr);
        else
            push_unique(gua, seen_gua, addr);
    };

    let ifaces = words(type(settings_cfg) == "object" ? settings_cfg.source_network_interfaces : null);
    let lan_ubus = parse_json_or_null(command_output_from_args([
        "ubus", "-S", "call", "network.interface.lan", "status"
    ]));
    if (type(lan_ubus) == "object") {
        if (type(lan_ubus["ipv6-address"]) == "array") {
            for (let item in lan_ubus["ipv6-address"])
                if (type(item) == "object")
                    add_candidate(item.address || "");
        }
        if (type(lan_ubus["ipv6-prefix-assignment"]) == "array") {
            for (let pa in lan_ubus["ipv6-prefix-assignment"]) {
                if (type(pa) == "object" && type(pa["local-address"]) == "object")
                    add_candidate(pa["local-address"].address || "");
            }
        }
        let dev = trim(as_string(lan_ubus.l3_device || lan_ubus.device || ""));
        if (dev != "")
            push(ifaces, dev);
    }

    if (length(ifaces) == 0)
        ifaces = [ "br-lan" ];
    let checked_dev = {};
    for (let iface in ifaces) {
        if (checked_dev[iface])
            continue;
        checked_dev[iface] = true;
        let out = command_output_from_args([
            "ip", "-6", "-o", "addr", "show", "dev", iface, "scope", "global"
        ]);
        for (let line in split(out, "\n")) {
            let m = match(trim(as_string(line)), /(^|[ \t])inet6[ \t]+([0-9a-fA-F:]+)(\/[0-9]+)?/);
            if (m && m[2])
                add_candidate(m[2]);
        }
    }

    let out = [];
    for (let ip in gua)
        push(out, ip);
    for (let ip in ula)
        push(out, ip);
    return out;
}

function get_router_hostname() {
    let h = trim(as_string(uci_core.get("system", "@system[0]", "hostname") || ""));
    if (h != "")
        return h;
    let proc_h = trim(as_string(fs.readfile("/proc/sys/kernel/hostname") || ""));
    if (proc_h != "")
        return proc_h;
    return "";
}

function get_ipv6_runtime_telemetry(settings_cfg) {
    if (type(settings_cfg) != "object")
        settings_cfg = uci_core.get_all(CONFIG_NAME, "settings") || {};
    let wan6_live = common.wan6_live_status();
    let eff = common.resolve_effective_ipv6_state(settings_cfg, wan6_live);
    let wan6_addrs = get_wan_ipv6_addresses(settings_cfg, wan6_live);
    let lan6_addrs = get_lan_ipv6_addresses(settings_cfg);
    return {
        router_hostname: get_router_hostname(),
        wan_ipv6: length(wan6_addrs) > 0 ? wan6_addrs[0] : "",
        wan_ipv6_list: wan6_addrs,
        lan_ipv6: length(lan6_addrs) > 0 ? lan6_addrs[0] : "",
        lan_ipv6_list: lan6_addrs,
        wan6_available: eff.wan6_available ? 1 : 0,
        wan6_iface: as_string(eff.wan6_iface || ""),
        wan6_prefix: length(eff.wan6_pd) > 0 ? as_string(eff.wan6_pd[0]) : "",
        wan6_pd: type(eff.wan6_pd) == "array" ? eff.wan6_pd : [],
        ipv6_effective_state: as_string(eff.effective || "disabled"),
        ipv6_mode: as_string(eff.ipv6_mode || "auto"),
        ipv6_leak_guard: eff.ipv6_leak_guard ? 1 : 0,
        dns_strategy: as_string(eff.configured_dns_strategy || "prefer_ipv4"),
        runtime_dns_strategy: as_string(eff.runtime_dns_strategy || "ipv4_only"),
        fakeip_enabled: eff.fakeip_enabled ? 1 : 0
    };
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
    if (index(out, "default") >= 0)
        return true;
    let out6 = command_output_from_args([ "ip", "-6", "route", "show", "default" ]);
    return index(out6, "default") >= 0;
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

function uci_settings() {
    return uci_core.get_all(CONFIG_NAME, "settings") || {};
}

function tachyon_core_standard_ports_listening(netstat) {
    netstat = as_string(netstat);
    let port_53_ok = index(netstat, "127.0.0.42:53") >= 0;
    let proxy_mode = lc(trim(as_string(uci_settings().proxy_mode || "tproxy")));
    if (proxy_mode == "tun") {
        let tun_ok = fs.stat("/sys/class/net/tun0") != null ||
            index(command_output_from_args([ "ip", "link", "show", "tun0" ]), "tun0") >= 0;
        return port_53_ok && tun_ok;
    }
    if (proxy_mode == "socks") {
        let socks_port = as_string(uci_settings().socks_port || "1080");
        return port_53_ok && index(netstat, ":" + socks_port) >= 0;
    }
    let tproxy_suffix = ":" + CORE_TPROXY_INBOUND_PORT;
    let port_1602_ok = index(netstat, "0.0.0.0" + tproxy_suffix) >= 0 ||
        index(netstat, "127.0.0.1" + tproxy_suffix) >= 0;
    let eff_v6 = common.resolve_effective_ipv6_state(uci_settings(), null);
    let v6_active = (eff_v6 && eff_v6.ipv6_active) ? true : false;
    let port_1602_v6_ok = !v6_active ||
        index(netstat, CORE_TPROXY_INBOUND6_ADDRESS + tproxy_suffix) >= 0 ||
        index(netstat, "[" + CORE_TPROXY_INBOUND6_ADDRESS + "]" + tproxy_suffix) >= 0 ||
        index(netstat, "0:0:0:0:0:0:0:1" + tproxy_suffix) >= 0 ||
        index(netstat, ":::" + CORE_TPROXY_INBOUND_PORT) >= 0;
    return port_53_ok && port_1602_ok && port_1602_v6_ok;
}

function tachyon_core_standard_ports_listening_fixture() {
    exit(tachyon_core_standard_ports_listening(read_stdin()) ? 0 : 1);
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
    is_non_local_ipv6,
    is_ula_ipv6,
    strip_cidr_suffix,
    first_ipv6_from_list,
    network_status_ip_addresses,
    is_virtual_or_tunnel_iface,
    get_wan_ip_addresses,
    get_wan_ipv6_addresses,
    get_lan_ipv6_addresses,
    get_router_hostname,
    get_ipv6_runtime_telemetry,
    get_wan_interface,
    default_gateway_exists,
    wan_has_ip,
    device_ipv4_address,
    tachyon_core_standard_ports_listening,
    tachyon_core_standard_ports_listening_fixture,
    server_required_port_conflict_owners,
    server_required_ports_listening,
    lan_clients,
    toggle_client_bypass
};
