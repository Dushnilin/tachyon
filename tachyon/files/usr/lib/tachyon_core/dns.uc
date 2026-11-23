#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let runtime_constants = require("tachyon_core.constants");
let runtime_url = require("core.url");
let fs = require("fs");

let as_string = common.as_string;
let bool_option = common.bool_option;
let command_output_from_args = common.command_output_from_args;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;
let option = common.option;
let read_json_file = common.read_json_file;

const DNS_FAILOVER_STATE_FILE = getenv("TACHYON_DNS_FAILOVER_STATE_FILE") || "/var/run/tachyon/dns-failover.json";
const DNS_HEALTH_ADDRESS = getenv("TACHYON_DNS_HEALTH_ADDRESS") || "127.0.0.42";
const DNS_HEALTH_PORT_BASE = int(getenv("TACHYON_DNS_HEALTH_PORT_BASE") || "10053");

function push_wan_dns_ip(result, seen, raw_ip) {
    let ip = trim(as_string(raw_ip));
    if (ip == "" || ip == "0.0.0.0" || ip == "::" || ip == "::1" || substr(ip, 0, 4) == "127.")
        return;
    if (!core_ip.valid_ip_with_zone(ip) || seen[ip])
        return;
    seen[ip] = true;
    push(result, ip);
}

function collect_wan_dns_from_resolv_text(result, seen, text) {
    if (!text)
        return;
    for (let line in split(as_string(text), "\n")) {
        let hash = index(line, "#");
        if (hash >= 0)
            line = substr(line, 0, hash);
        let parts = split(trim(line), /[ \t]+/);
        if (length(parts) >= 2 && parts[0] == "nameserver")
            push_wan_dns_ip(result, seen, parts[1]);
    }
}

function get_wan_dns_servers() {
    let result = [];
    let seen = {};

    let env_resolv = trim(as_string(getenv("TACHYON_WAN_RESOLV_FILE") || ""));
    if (env_resolv != "") {
        collect_wan_dns_from_resolv_text(result, seen, fs.readfile(env_resolv));
        return result;
    }

    let candidates = [];
    let cand_seen = {};
    let dnsmasq_rf = trim(as_string(uci_core.get("dhcp", "@dnsmasq[0]", "resolvfile") || ""));
    for (let path in [ dnsmasq_rf, "/tmp/resolv.conf.d/resolv.conf.auto", "/tmp/resolv.conf.auto" ]) {
        if (path == "" || path == "/tmp/resolv.conf" || path == "/etc/resolv.conf" || cand_seen[path])
            continue;
        cand_seen[path] = true;
        push(candidates, path);
    }

    for (let path in candidates) {
        let resolv_data = fs.readfile(path);
        if (resolv_data) {
            collect_wan_dns_from_resolv_text(result, seen, resolv_data);
            if (length(result) > 0)
                return result;
        }
    }

    let dump_raw = trim(as_string(command_output_from_args([ "ubus", "-S", "call", "network.interface", "dump" ]) || ""));
    if (dump_raw != "") {
        let dump = null;
        try {
            dump = json(dump_raw);
        } catch (e) {
            dump = null;
        }
        for (let iface in common.array_or_empty(object_or_empty(dump).interface)) {
            if (type(iface) != "object" || iface.up !== true)
                continue;
            let iface_name = as_string(iface.interface || "");
            let has_default_route = false;
            if (iface_name != "wan" && iface_name != "wan6") {
                for (let route in common.array_or_empty(iface.route)) {
                    if (type(route) == "object" &&
                        (route.target == "0.0.0.0" || route.target == "::") &&
                        route.mask != null && int(route.mask) == 0) {
                        has_default_route = true;
                        break;
                    }
                }
            }
            if (iface_name != "wan" && iface_name != "wan6" && !has_default_route)
                continue;
            for (let dns_ip in common.array_or_empty(iface["dns-server"]))
                push_wan_dns_ip(result, seen, dns_ip);
        }
    }

    if (length(result) == 0) {
        let wan_dns = uci_core.get("network", "wan", "dns");
        if (type(wan_dns) == "array") {
            for (let dns_ip in wan_dns)
                push_wan_dns_ip(result, seen, dns_ip);
        } else if (wan_dns != null && as_string(wan_dns) != "") {
            for (let dns_ip in split(trim(as_string(wan_dns)), /[ \t,]+/))
                push_wan_dns_ip(result, seen, dns_ip);
        }
    }

    return result;
}

function server_list(settings, key, fallback) {
    let result = [];
    for (let value in list_option(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(result, value);
    }
    // Explicit fallback servers (plain UDP) between primary and WAN-DNS fallback
    if (key == "dns_server") {
        for (let value in list_option(settings, "dns_fallback_server")) {
            value = trim(as_string(value));
            if (value != "")
                push(result, value);
        }
    }
    let fallback_key = (key == "dns_server") ? "fallback_wan_main" : "fallback_wan_bootstrap";
    if (bool_option(settings, fallback_key, false)) {
        let ipv6_ok = common.resolve_effective_ipv6_state(settings, null).ipv6_active;
        for (let wan_ip in get_wan_dns_servers()) {
            if (!ipv6_ok && index(wan_ip, ":") >= 0)
                continue;
            push(result, wan_ip);
        }
    }
    if (length(result) == 0)
        push(result, fallback);
    return result;
}

function arrays_equal(left, right) {
    if (length(left || []) != length(right || []))
        return false;
    for (let i = 0; i < length(left); i++)
        if (as_string(left[i]) != as_string(right[i]))
            return false;
    return true;
}

function detour_tag(settings) {
    if (!bool_option(settings, "dns_detour_enabled", false))
        return "";
    let section_name = option(settings, "dns_detour_section", "");
    return section_name == "" ? "" : runtime_constants.outbound_tag(section_name);
}

function configured_server_count(settings, key) {
    let count = length(list_option(settings, key));
    if (count == 0) count = 1;
    return count;
}

function explicit_fallback_count(settings) {
    return length(list_option(settings, "dns_fallback_server"));
}

function is_explicit_fallback_index(settings, index) {
    let primary = configured_server_count(settings, "dns_server");
    let fallback = explicit_fallback_count(settings);
    return int(index) >= primary && int(index) < primary + fallback;
}

function is_wan_fallback_index(settings, index) {
    if (!bool_option(settings, "fallback_wan_main", false))
        return false;
    let primary = configured_server_count(settings, "dns_server");
    let fallback = explicit_fallback_count(settings);
    return int(index) >= primary + fallback;
}

function state_template(settings) {
    return {
        version: 1,
        dns_type: option(settings, "dns_type", "udp"),
        dns_detour: detour_tag(settings),
        main_servers: server_list(settings, "dns_server", "77.88.8.8"),
        bootstrap_servers: server_list(settings, "bootstrap_dns_server", "77.88.8.8"),
        main_index: 0,
        bootstrap_index: 0
    };
}

function state_matches(template, state) {
    state = object_or_empty(state);
    return int(state.version || 0) == 1 &&
        as_string(state.dns_type) == template.dns_type &&
        as_string(state.dns_detour) == template.dns_detour &&
        arrays_equal(state.main_servers, template.main_servers) &&
        arrays_equal(state.bootstrap_servers, template.bootstrap_servers);
}

function bounded_index(value, values) {
    let index_value = int(value || 0);
    return index_value >= 0 && index_value < length(values) ? index_value : 0;
}

function normalize_state(settings, state) {
    let result = state_template(settings);
    if (!state_matches(result, state))
        return result;

    result.main_index = bounded_index(object_or_empty(state).main_index, result.main_servers);
    result.bootstrap_index = bounded_index(object_or_empty(state).bootstrap_index, result.bootstrap_servers);
    return result;
}

function runtime_state(settings, override_state) {
    let state = override_state;
    if (state == null)
        state = read_json_file(DNS_FAILOVER_STATE_FILE);
    return normalize_state(settings, state);
}

function active_values(settings, override_state) {
    let state = runtime_state(settings, override_state);
    return {
        state,
        main: state.main_servers[state.main_index],
        bootstrap: state.bootstrap_servers[state.bootstrap_index]
    };
}

const KNOWN_DNS_SERVER_NAMES = {
    "8.8.8.8": "dns.google",
    "8.8.4.4": "dns.google",
    "2001:4860:4860::8888": "dns.google",
    "2001:4860:4860::8844": "dns.google",
    "1.1.1.1": "cloudflare-dns.com",
    "1.0.0.1": "cloudflare-dns.com",
    "2606:4700:4700::1111": "cloudflare-dns.com",
    "2606:4700:4700::1001": "cloudflare-dns.com",
    "2606:4700:4700::1112": "security.cloudflare-dns.com",
    "2606:4700:4700::1113": "family.cloudflare-dns.com",
    "77.88.8.8": "common.dot.dns.yandex.net",
    "77.88.8.1": "common.dot.dns.yandex.net",
    "2a02:6b8::feed:0ff": "common.dot.dns.yandex.net",
    "2a02:6b8:0:1::feed:0ff": "common.dot.dns.yandex.net",
    "77.88.8.88": "safe.dot.dns.yandex.net",
    "77.88.8.2": "safe.dot.dns.yandex.net",
    "2a02:6b8::feed:bad": "safe.dot.dns.yandex.net",
    "2a02:6b8:0:1::feed:bad": "safe.dot.dns.yandex.net",
    "77.88.8.7": "family.dot.dns.yandex.net",
    "77.88.8.3": "family.dot.dns.yandex.net",
    "2a02:6b8::feed:a11": "family.dot.dns.yandex.net",
    "2a02:6b8:0:1::feed:a11": "family.dot.dns.yandex.net",
    "9.9.9.9": "dns.quad9.net",
    "149.112.112.112": "dns.quad9.net",
    "2620:fe::fe": "dns.quad9.net",
    "2620:fe::9": "dns.quad9.net",
    "9.9.9.10": "dns10.quad9.net",
    "149.112.112.10": "dns10.quad9.net",
    "2620:fe::10": "dns10.quad9.net",
    "2620:fe::fe:10": "dns10.quad9.net",
    "94.140.14.14": "dns.adguard-dns.com",
    "94.140.15.15": "dns.adguard-dns.com",
    "2a10:50c0::ad1:ff": "dns.adguard-dns.com",
    "2a10:50c0::ad2:ff": "dns.adguard-dns.com",
    "94.140.14.140": "unfiltered.adguard-dns.com",
    "94.140.14.141": "unfiltered.adguard-dns.com",
    "2a10:50c0::1:ff": "unfiltered.adguard-dns.com",
    "2a10:50c0::2:ff": "unfiltered.adguard-dns.com",
    "94.140.14.15": "family.adguard-dns.com",
    "94.140.15.16": "family.adguard-dns.com",
    "2a10:50c0::bad1:ff": "family.adguard-dns.com",
    "2a10:50c0::bad2:ff": "family.adguard-dns.com",
    "194.242.2.2": "dns.mullvad.net",
    "194.242.2.3": "dns.mullvad.net",
    "194.242.2.4": "dns.mullvad.net",
    "194.242.2.5": "dns.mullvad.net",
    "2a07:e340::2": "dns.mullvad.net",
    "2a07:e340::3": "dns.mullvad.net",
    "76.76.2.0": "freedns.controld.com",
    "76.76.10.0": "freedns.controld.com",
    "2606:1a40::": "freedns.controld.com",
    "2606:1a40:1::": "freedns.controld.com",
    "223.5.5.5": "dns.alidns.com",
    "223.6.6.6": "dns.alidns.com",
    "2400:3200::1": "dns.alidns.com",
    "2400:3200:baba::1": "dns.alidns.com",
    "208.67.222.222": "doh.opendns.com",
    "208.67.220.220": "doh.opendns.com",
    "2620:119:35::35": "doh.opendns.com",
    "2620:119:53::53": "doh.opendns.com",
    "185.222.222.222": "doh.dns.sb",
    "45.11.45.11": "doh.dns.sb",
    "2a09::": "doh.dns.sb",
    "2a11::": "doh.dns.sb",
    "185.228.168.9": "doh.cleanbrowsing.org",
    "185.228.169.9": "doh.cleanbrowsing.org",
    "2a0d:2a00:1::": "doh.cleanbrowsing.org",
    "2a0d:2a00:2::": "doh.cleanbrowsing.org"
};

function apply_mtls_options(result, server, mtls_settings) {
    if (mtls_settings == null || !bool_option(mtls_settings, "dns_mtls_enabled", false))
        return;
    let mtls_host = option(mtls_settings, "dns_mtls_host", "");
    if (mtls_host != "" && server != mtls_host && (!result.tls || result.tls.server_name != mtls_host))
        return;
    let client_cert = option(mtls_settings, "dns_mtls_client_certificate", "");
    let client_key = option(mtls_settings, "dns_mtls_client_key", "");
    if (client_cert != "" && client_key != "") {
        if (!result.tls) result.tls = { enabled: true };
        result.tls.client_certificate_path = client_cert;
        result.tls.client_key_path = client_key;
    }
    let ca = option(mtls_settings, "dns_mtls_ca", option(mtls_settings, "dns_mtls_certificate", ""));
    if (ca != "") {
        if (!result.tls) result.tls = { enabled: true };
        result.tls.certificate_path = ca;
    }
}

function dns_server_lookup_key(host) {
    host = as_string(host);
    let pct = index(host, "%");
    return lc(pct >= 0 ? substr(host, 0, pct) : host);
}

function server_from_options(tag_name, dns_type, dns_server, detour, mtls_settings) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
    let is_ip = core_ip.valid_ip_with_zone(server);
    let known_name = KNOWN_DNS_SERVER_NAMES[dns_server_lookup_key(server)];
    let result = {
        type: "udp",
        tag: tag_name,
        server,
        server_port: 53
    };

    if (dns_type == "udp") {
        if (port != "")
            result.server_port = int(port);
    }
    else if (dns_type == "dot") {
        result.type = "tls";
        result.server_port = port != "" ? int(port) : 853;
        result.tls = { enabled: true };
        if (is_ip && known_name)
            result.tls.server_name = known_name;
        else if (!is_ip)
            result.tls.server_name = server;
        apply_mtls_options(result, server, mtls_settings);
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port) : 443;
        let path = runtime_url.path(dns_server);
        result.path = (path != "" && path != "/") ? path : "/dns-query";
        result.tls = { enabled: true };
        if (is_ip && known_name)
            result.tls.server_name = known_name;
        else if (!is_ip)
            result.tls.server_name = server;
        apply_mtls_options(result, server, mtls_settings);
    }
    else if (dns_type == "doq") {
        result.type = "quic";
        result.server_port = port != "" ? int(port) : 784;
        result.tls = { enabled: true };
        if (is_ip && known_name)
            result.tls.server_name = known_name;
        else if (!is_ip)
            result.tls.server_name = server;
        apply_mtls_options(result, server, mtls_settings);
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!is_ip)
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function bootstrap_server(tag_name, value) {
    let raw = as_string(value);
    let url_scheme = runtime_url.scheme(raw);
    let server = runtime_url.host(raw);
    let port = runtime_url.port(raw);
    let host = server != "" ? server : raw;
    if (url_scheme == "tls" || url_scheme == "dot") {
        let dot_name = core_ip.valid_ip_with_zone(host) ? KNOWN_DNS_SERVER_NAMES[dns_server_lookup_key(host)] : host;
        let result = {
            type: "tls",
            tag: tag_name,
            server: host,
            server_port: port != "" ? int(port) : 853,
            tls: { enabled: true }
        };
        if (dot_name != null && dot_name != "")
            result.tls.server_name = dot_name;
        return result;
    }
    return {
        type: "udp",
        tag: tag_name,
        server: host,
        server_port: port != "" ? int(port) : 53
    };
}

function server_config(settings, override_state) {
    let active = active_values(settings, override_state);
    let is_wan = is_wan_fallback_index(settings, active.state.main_index);
    let is_fallback = is_explicit_fallback_index(settings, active.state.main_index);
    // WAN and explicit fallback servers must always use direct UDP — never detour through proxy
    let dns_type = (is_wan || is_fallback) ? "udp" : active.state.dns_type;
    let detour = (is_wan || is_fallback) ? "" : active.state.dns_detour;
    let result = server_from_options(
        runtime_constants.DNS_SERVER_TAG,
        dns_type,
        active.main,
        detour,
        settings
    );

    if (bool_option(settings, "dns_doq_ech", false)) {
        if (result.type == "tls" || result.type == "quic") {
            if (!result.tls) result.tls = { enabled: true };
            result.tls.ech = { enabled: true };
        }
        if (result.type == "https") {
            if (!result.tls) result.tls = { enabled: true };
            result.tls.ech = { enabled: true };
        }
    }

    return result;
}

function bootstrap_config(settings, override_state) {
    let active = active_values(settings, override_state);
    return bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, active.bootstrap);
}

function failover_enabled(settings) {
    let state = state_template(settings);
    return length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1;
}

function health_tag(kind, index_value, suffix) {
    return "dns-health-" + as_string(kind) + "-" + as_string(index_value + 1) + "-" + as_string(suffix);
}

function health_port(kind, index_value) {
    if (kind == "active")
        return DNS_HEALTH_PORT_BASE + 2000;
    return DNS_HEALTH_PORT_BASE + int(index_value) * 2 + (kind == "bootstrap" ? 1 : 0);
}

function add_active_health_inbound(result) {
    let inbound_tag = "dns-health-active-main-in";
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port("active", 0)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: runtime_constants.DNS_SERVER_TAG,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function add_health_candidate(result, kind, index_value, server, override_dns_type, override_detour, settings) {
    let server_tag = health_tag(kind, index_value, "server");
    let inbound_tag = health_tag(kind, index_value, "in");
    let dns_type = override_dns_type || result.state.dns_type;
    let detour = override_detour != null ? override_detour : result.state.dns_detour;
    let active_settings = settings || result.settings;
    let dns_server = kind == "main"
        ? server_from_options(server_tag, dns_type, server, detour, active_settings)
        : bootstrap_server(server_tag, server);

    if (dns_server.unsupported) {
        result.unsupported = dns_server.unsupported;
        return;
    }

    if (kind == "main" && bool_option(active_settings, "dns_doq_ech", false)) {
        if (dns_server.type == "tls" || dns_server.type == "quic" || dns_server.type == "https") {
            if (!dns_server.tls) dns_server.tls = { enabled: true };
            dns_server.tls.ech = { enabled: true };
        }
    }

    push(result.servers, dns_server);
    push(result.inbounds, {
        type: "direct",
        tag: inbound_tag,
        listen: DNS_HEALTH_ADDRESS,
        listen_port: health_port(kind, index_value)
    });
    push(result.rules, {
        action: "route",
        inbound: inbound_tag,
        server: server_tag,
        disable_cache: true
    });
    push(result.sniff_inbounds, inbound_tag);
}

function is_encrypted_dns_server(entry) {
    if (type(entry) != "object")
        return false;
    let srv_type = as_string(entry.type);
    return srv_type == "https" || srv_type == "tls" || srv_type == "quic";
}

function encrypted_dns_type_from_url(raw) {
    let s = lc(trim(as_string(raw)));
    if (substr(s, 0, 8) == "https://")
        return "doh";
    if (substr(s, 0, 6) == "tls://" || substr(s, 0, 6) == "dot://")
        return "dot";
    if (substr(s, 0, 7) == "quic://" || substr(s, 0, 6) == "doq://")
        return "doq";
    return "";
}

function encrypted_dns_endpoint_key(entry) {
    if (type(entry) != "object")
        return "";
    return as_string(entry.type) + "|" + as_string(entry.server) + "|" +
        as_string(entry.server_port || "") + "|" + as_string(entry.path || "") + "|" +
        as_string(entry.detour || "");
}

function apply_dns_ech_option(entry, settings) {
    if (type(entry) != "object" || !is_encrypted_dns_server(entry) || !bool_option(settings, "dns_doq_ech", false))
        return;
    if (!entry.tls)
        entry.tls = { enabled: true };
    entry.tls.ech = { enabled: true };
}

function append_resilient_dns_group(result, settings, bootstrap, main) {
    let ipv6_ok = common.resolve_effective_ipv6_state(settings, null).ipv6_active;
    let group_members = [ runtime_constants.DNS_SERVER_TAG ];

    if (is_encrypted_dns_server(main)) {
        // When active DNS is encrypted (DoH/DoT/DoQ), never place plain UDP
        // servers into dns-resilient: group[mode=stable] picks a clean member
        // randomly and treats spoofed NXDOMAIN/empty answers as valid successes.
        // Keep only encrypted primary servers and explicitly encrypted fallbacks
        // in dns-resilient; dns_failover handles full-outage fallback to UDP.
        let seen_encrypted = {};
        seen_encrypted[encrypted_dns_endpoint_key(main)] = true;

        let existing_health_by_key = {};
        for (let srv in result.servers) {
            if (is_encrypted_dns_server(srv) && index(as_string(srv.tag), "dns-health-main-") == 0)
                existing_health_by_key[encrypted_dns_endpoint_key(srv)] = as_string(srv.tag);
        }

        let dns_type = result.state ? result.state.dns_type : option(settings, "dns_type", "udp");
        let dns_detour = result.state ? result.state.dns_detour : detour_tag(settings);
        let extra_idx = 1;
        for (let raw_primary in list_option(settings, "dns_server")) {
            let primary = trim(as_string(raw_primary));
            if (primary == "")
                continue;
            let host = runtime_url.host(primary);
            if (host == "")
                host = primary;
            if (!ipv6_ok && index(host, ":") >= 0)
                continue;
            let eff_type = encrypted_dns_type_from_url(primary) || dns_type;
            let entry = server_from_options("", eff_type, primary, dns_detour, settings);
            if (entry.unsupported || !is_encrypted_dns_server(entry))
                continue;
            apply_dns_ech_option(entry, settings);
            let k = encrypted_dns_endpoint_key(entry);
            if (seen_encrypted[k])
                continue;
            seen_encrypted[k] = true;
            if (existing_health_by_key[k]) {
                push(group_members, existing_health_by_key[k]);
            } else {
                extra_idx++;
                entry.tag = "dns-primary-" + as_string(extra_idx);
                push(result.servers, entry);
                push(group_members, entry.tag);
            }
        }

        let fb_enc_idx = 0;
        for (let raw_fb in list_option(settings, "dns_fallback_server")) {
            let fb = trim(as_string(raw_fb));
            if (fb == "")
                continue;
            let enc_type = encrypted_dns_type_from_url(fb);
            if (enc_type == "")
                continue;
            let host = runtime_url.host(fb);
            if (host == "")
                host = fb;
            if (!ipv6_ok && index(host, ":") >= 0)
                continue;
            let entry = server_from_options("", enc_type, fb, "", settings);
            if (entry.unsupported || !is_encrypted_dns_server(entry))
                continue;
            apply_dns_ech_option(entry, settings);
            let k = encrypted_dns_endpoint_key(entry);
            if (seen_encrypted[k])
                continue;
            seen_encrypted[k] = true;
            fb_enc_idx++;
            entry.tag = "dns-fallback-enc-" + as_string(fb_enc_idx);
            push(result.servers, entry);
            push(group_members, entry.tag);
        }
    } else {
        let seen_endpoints = {};
        if (type(bootstrap) == "object" && as_string(bootstrap.type) == "udp" && as_string(bootstrap.server) != "") {
            seen_endpoints[as_string(bootstrap.server) + ":" + as_string(bootstrap.server_port || 53)] = true;
        }
        if (type(main) == "object" && as_string(main.type) == "udp" && as_string(main.server) != "") {
            seen_endpoints[as_string(main.server) + ":" + as_string(main.server_port || 53)] = true;
        }

        let fb_idx = 0;
        for (let raw_fb in list_option(settings, "dns_fallback_server")) {
            let fb = trim(as_string(raw_fb));
            if (fb == "")
                continue;
            let host = runtime_url.host(fb);
            if (host == "")
                host = fb;
            if (!ipv6_ok && index(host, ":") >= 0)
                continue;
            let port = runtime_url.port(fb);
            let ep_key = host + ":" + (port != "" ? port : "53");
            if (seen_endpoints[ep_key])
                continue;
            seen_endpoints[ep_key] = true;
            fb_idx++;
            let fb_tag = "dns-fallback-" + as_string(fb_idx);
            let entry = server_from_options(fb_tag, "udp", fb, "", null);
            if (!entry.unsupported) {
                push(result.servers, entry);
                push(group_members, fb_tag);
            }
        }

        if (bool_option(settings, "fallback_wan_main", false)) {
            let wan_idx = 0;
            for (let wan_ip in get_wan_dns_servers()) {
                if (!ipv6_ok && index(wan_ip, ":") >= 0)
                    continue;
                let ep_key = wan_ip + ":53";
                if (seen_endpoints[ep_key])
                    continue;
                seen_endpoints[ep_key] = true;
                wan_idx++;
                let wan_tag = "dns-wan-fallback-" + as_string(wan_idx);
                let entry = server_from_options(wan_tag, "udp", wan_ip, "", null);
                if (!entry.unsupported) {
                    push(result.servers, entry);
                    push(group_members, wan_tag);
                }
            }
        }

        if (index(group_members, runtime_constants.BOOTSTRAP_DNS_SERVER_TAG) < 0)
            push(group_members, runtime_constants.BOOTSTRAP_DNS_SERVER_TAG);
    }

    push(result.servers, {
        type: "group",
        tag: runtime_constants.DNS_RESILIENT_SERVER_TAG,
        mode: "stable",
        error_ttl: "30s",
        timeout: "4s",
        servers: group_members
    });
}

function config(settings, override_state) {
    let state = runtime_state(settings, override_state);
    if (getenv("TACHYON_SAFE_DNS_FALLBACK") == "1") {
        let safe_bootstrap = bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, "77.88.8.8");
        let safe_main = server_from_options(runtime_constants.DNS_SERVER_TAG, "udp", "1.1.1.1", "", null);
        let safe_group = {
            type: "group",
            tag: runtime_constants.DNS_RESILIENT_SERVER_TAG,
            mode: "stable",
            error_ttl: "30s",
            timeout: "4s",
            servers: [ runtime_constants.DNS_SERVER_TAG, runtime_constants.BOOTSTRAP_DNS_SERVER_TAG ]
        };
        return {
            settings,
            state,
            servers: [ safe_bootstrap, safe_main, safe_group ],
            inbounds: [],
            rules: [],
            sniff_inbounds: []
        };
    }

    let bootstrap = bootstrap_config(settings, state);
    let main = server_config(settings, state);
    if (main.unsupported)
        return { unsupported: main.unsupported };

    let result = {
        settings,
        state,
        servers: [ bootstrap, main ],
        inbounds: [],
        rules: [],
        sniff_inbounds: []
    };

    // The failover worker probes a kind whenever failover is active at all,
    // including a single server of that kind: choose_index's single path exists
    // so a dead lone resolver is not reported as alive (commit 93195fdb). That
    // probe digs the health port, so the listener has to exist for the single
    // server too - otherwise every start of a multi-main/one-bootstrap config
    // logged a false "all configured bootstrap DNS servers are unavailable"
    // against a port that is deliberately never bound. A config where both
    // kinds are single keeps no listeners, because the worker never starts
    // there (dns_failover.uc worker() early return).
    let failover_active = length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1;
    if (failover_active) {
        add_active_health_inbound(result);

        if (length(state.main_servers) > 0)
            for (let i = 0; i < length(state.main_servers); i++) {
                let is_wan = is_wan_fallback_index(settings, i);
                let is_fallback = is_explicit_fallback_index(settings, i);
                let dns_type = (is_wan || is_fallback) ? "udp" : state.dns_type;
                let detour = (is_wan || is_fallback) ? "" : state.dns_detour;
                add_health_candidate(result, "main", i, state.main_servers[i], dns_type, detour, settings);
            }

        if (length(state.bootstrap_servers) > 0)
            for (let i = 0; i < length(state.bootstrap_servers); i++)
                add_health_candidate(result, "bootstrap", i, state.bootstrap_servers[i], null, null, settings);
    }

    append_resilient_dns_group(result, settings, bootstrap, main);

    return result;
}

function default_domain_resolver(settings) {
    return runtime_constants.DNS_RESILIENT_SERVER_TAG;
}

return {
    DNS_FAILOVER_STATE_FILE,
    DNS_HEALTH_ADDRESS,
    active_values,
    apply_dns_ech_option,
    arrays_equal,
    bootstrap_config,
    bootstrap_server,
    config,
    configured_server_count,
    default_domain_resolver,
    detour_tag,
    encrypted_dns_type_from_url,
    explicit_fallback_count,
    failover_enabled,
    get_wan_dns_servers,
    health_port,
    is_encrypted_dns_server,
    is_explicit_fallback_index,
    is_wan_fallback_index,
    normalize_state,
    runtime_state,
    server_config,
    server_from_options,
    server_list,
    state_matches,
    state_template
};