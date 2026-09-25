#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let runtime_dns = require("singbox.dns");
let common = require("core.common");
let network_mod = require("diagnostics.network");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || constants.SB_DNS_INBOUND_ADDRESS || "127.0.0.42";
const STEER_DNS_ADDRESS = getenv("STEER_DNS_ADDRESS") || "127.0.0.1";
const STEER_DNS_PORT = getenv("STEER_DNS_PORT") || "5300";
const FAKEIP_TEST_DOMAIN = getenv("FAKEIP_TEST_DOMAIN") || constants.FAKEIP_TEST_DOMAIN || "fakeip.podkop.fyi";
const DNS_APPLY_UC = LIB_DIR + "/dns/apply.uc";
const SINGBOX_RUNTIME_UC = LIB_DIR + "/singbox/runtime.uc";
const HELPERS_UC = LIB_DIR + "/core/helpers.uc";

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let command_capture = common.command_capture;
function command_exists(name) { return command_success_from_args([ "command", "-v", as_string(name) ]); }
let write_json = common.write_json;

function option(cfg, key, fallback) {
    if (type(cfg) != "object")
        return fallback;
    let value = cfg[key];
    return value != null && value != "" ? value : fallback;
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

function active_engine_name() {
    let engine = uci_core.get(CONFIG_NAME, "settings", "engine");
    return (engine != null && engine != "") ? as_string(engine) : "sing-box";
}

function active_engine_is_steer() {
    let name = active_engine_name();
    return name == "steer" || name == "steer-extended";
}

function valid_ipv4(value) {
    return core_ip.valid_ipv4(value, false, false);
}

function url_host(value) {
    let url_mod = require("core.url");
    if (url_mod && url_mod.get_host)
        return url_mod.get_host(value);
    let common_url = require("core.url");
    let pipe = fs.popen(sprintf("ucode -L %s %s url-get-host %s", shell_quote(LIB_DIR), shell_quote(HELPERS_UC), shell_quote(as_string(value))), "r");
    if (!pipe) return "";
    let out = pipe.read("all");
    pipe.close();
    return replace(as_string(out), /[\r\n]+$/g, "");
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

function dns_check_through_singbox(domain) {
    let resolved = dns_check_resolve_host(domain, SB_DNS_INBOUND_ADDRESS, 3);
    if (resolved != "")
        return true;

    let res = command_capture("nslookup " + shell_quote(domain) + " " + SB_DNS_INBOUND_ADDRESS + " 2>&1");
    return (index(res.output, "Address") >= 0 || index(res.output, "name =") >= 0) &&
           index(res.output, "NXDOMAIN") < 0 &&
           index(res.output, "can't resolve") < 0 &&
           index(res.output, "timed out") < 0;
}

function dns_check_router_resolver_available(domain) {
    for (let address in [ "127.0.0.1", SB_DNS_INBOUND_ADDRESS ]) {
        if (address != "" && command_success_from_args([ "dig", "@" + address, domain, "+timeout=2", "+tries=1" ]))
            return true;
    }

    let pipe = fs.popen(sprintf("ucode -L %s %s service-listen-address", shell_quote(LIB_DIR), shell_quote(SINGBOX_RUNTIME_UC)), "r");
    let listen_address = "";
    if (pipe) {
        listen_address = replace(as_string(pipe.read("all")), /[\r\n]+$/g, "");
        pipe.close();
    }
    if (listen_address != "" && command_success_from_args([ "dig", "@" + listen_address, domain, "+timeout=2", "+tries=1" ]))
        return true;

    let source_interfaces = option(settings(), "source_network_interfaces", "br-lan");
    for (let interface in network_mod.words(source_interfaces)) {
        let address = network_mod.device_ipv4_address(interface);
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

function dnsmasq_has_tachyon_dns() {
    let status = common.command_status(sprintf("ucode -L %s %s has-tachyon-dns >/dev/null 2>&1", shell_quote(LIB_DIR), shell_quote(DNS_APPLY_UC)));
    return status == 0;
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
    if (active_engine_is_steer()) {
        push(active_dns_args, "-p", STEER_DNS_PORT);
        push(active_dns_args, "@" + STEER_DNS_ADDRESS);
    } else {
        if (runtime_dns.failover_enabled(cfg)) {
            push(active_dns_args, "-p");
            push(active_dns_args, as_string(runtime_dns.health_port("active", 0)));
        }
        push(active_dns_args, "@" + SB_DNS_INBOUND_ADDRESS);
    }
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

    if (active_engine_is_steer()) {
        dhcp_config_status = 1;
    } else {
        let complete_rc = common.command_status(sprintf("ucode -L %s %s default-config-complete >/dev/null 2>&1", shell_quote(LIB_DIR), shell_quote(DNS_APPLY_UC)));
        if (complete_rc != 0)
            dhcp_config_status = 0;
    }

    let status_mod = require("diagnostics.status_bridge");
    let display_dns_server = replace(status_mod.status_output([ "mask-dns-server", dns_server ], null), /[\r\n]+$/g, "");
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

function check_fakeip() {
    if (active_engine_is_steer()) {
        let fakeip_address = "";
        let fakeip6_address = "";
        for (let line in split(command_output_from_args([
            "dig", "+short", "-p", STEER_DNS_PORT, "@" + STEER_DNS_ADDRESS,
            FAKEIP_TEST_DOMAIN, "A", "+timeout=2", "+tries=1"
        ]), "\n")) {
            line = trim(as_string(line));
            if (valid_ipv4(line)) {
                fakeip_address = line;
                break;
            }
        }
        write_json({
            fakeip: match(fakeip_address, /^198\.(18|19)\./) != null,
            IP: fakeip_address,
            IPv4: fakeip_address,
            IPv6: fakeip6_address,
            engine: active_engine_name()
        });
        return 0;
    }
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

function resolve_domain_cli(domain) {
    domain = trim(as_string(domain));
    if (domain == "") {
        print("[]\n");
        return 0;
    }

    let m_dom = match(domain, /^https?:\/\/([^/:]+)/i);
    if (m_dom && m_dom[1])
        domain = m_dom[1];
    else {
        let parts = split(domain, "/");
        domain = split(parts[0], ":")[0];
    }
    domain = trim(domain);

    let ips = [];
    let seen = {};

    let add_ip = function(ip) {
        ip = trim(as_string(ip));
        if (ip == "" || ip == "127.0.0.1" || ip == "::1" || ip == "0.0.0.0" || seen[ip])
            return;
        if (!core_ip.valid_ip(ip))
            return;
        seen[ip] = true;
        push(ips, ip);
    };

    let cmd_local = command_output_from_args([ "nslookup", domain, "127.0.0.1" ]);
    let cmd_def = command_output_from_args([ "nslookup", domain ]);
    let outputs = [ cmd_local, cmd_def ];

    for (let out in outputs) {
        if (!out) continue;
        let past_header = false;
        for (let line in split(out, "\n")) {
            line = trim(as_string(line));
            if (match(line, /^(Name:|Non-authoritative answer:)/i))
                past_header = true;
            if (past_header) {
                let m = match(line, /^Address[0-9 \t]*:[ \t]*([0-9a-fA-F:.]+)/);
                if (m && m[1] && m[1] != "127.0.0.1" && m[1] != "::1")
                    add_ip(m[1]);
            }
        }
    }

    print(sprintf("%J\n", ips));
    return 0;
}

return {
    url_host,
    get_all_dns_servers,
    dns_check_resolve_host,
    dns_check_through_singbox,
    dns_check_router_resolver_available,
    dns_check_timeout_seconds,
    dnsmasq_has_tachyon_dns,
    check_dns_available,
    check_fakeip,
    resolve_domain_cli
};
