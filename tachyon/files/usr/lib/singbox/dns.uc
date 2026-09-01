#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");
let fs = require("fs");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;
let option = common.option;
let read_json_file = common.read_json_file;

const DNS_FAILOVER_STATE_FILE = getenv("TACHYON_DNS_FAILOVER_STATE_FILE") || "/var/run/tachyon/dns-failover.json";
const DNS_HEALTH_ADDRESS = getenv("TACHYON_DNS_HEALTH_ADDRESS") || "127.0.0.42";
const DNS_HEALTH_PORT_BASE = int(getenv("TACHYON_DNS_HEALTH_PORT_BASE") || "10053");

function get_wan_dns_servers() {
    let result = [];
    let resolv_data = fs.readfile("/tmp/resolv.conf.d/resolv.conf.auto") || fs.readfile("/tmp/resolv.conf.auto");
    if (resolv_data) {
        for (let line in split(resolv_data, "\n")) {
            let parts = split(trim(line), /[ \t]+/);
            if (length(parts) >= 2 && parts[0] == "nameserver") {
                let ip = parts[1];
                if (ip != "127.0.0.1" && ip != "127.0.0.42" && ip != "::1") {
                    push(result, ip);
                }
            }
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
        for (let wan_ip in get_wan_dns_servers()) {
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

function server_from_options(tag_name, dns_type, dns_server, detour) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
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
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port) : 443;
        let path = runtime_url.path(dns_server);
        if (path != "")
            result.path = path;
    }
    else if (dns_type == "doq") {
        result.type = "quic";
        result.server_port = port != "" ? int(port) : 784;
        result.tls = { enabled: true };
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!core_ip.valid_ip(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function bootstrap_server(tag_name, value) {
    let server = runtime_url.host(value);
    let port = runtime_url.port(value);
    return {
        type: "udp",
        tag: tag_name,
        server: server != "" ? server : value,
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
        detour
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

function add_health_candidate(result, kind, index_value, server, override_dns_type, override_detour) {
    let server_tag = health_tag(kind, index_value, "server");
    let inbound_tag = health_tag(kind, index_value, "in");
    let dns_type = override_dns_type || result.state.dns_type;
    let detour = override_detour != null ? override_detour : result.state.dns_detour;
    let dns_server = kind == "main"
        ? server_from_options(server_tag, dns_type, server, detour)
        : bootstrap_server(server_tag, server);

    if (dns_server.unsupported) {
        result.unsupported = dns_server.unsupported;
        return;
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

function config(settings, override_state) {
    let state = runtime_state(settings, override_state);
    let main = server_config(settings, state);
    if (main.unsupported)
        return { unsupported: main.unsupported };

    let result = {
        state,
        servers: [ bootstrap_config(settings, state), main ],
        inbounds: [],
        rules: [],
        sniff_inbounds: []
    };

    if (length(state.main_servers) > 1 || length(state.bootstrap_servers) > 1)
        add_active_health_inbound(result);

    if (length(state.main_servers) > 1)
        for (let i = 0; i < length(state.main_servers); i++) {
            // Health probes always use direct connection (no detour) to test DNS server reachability
            let dns_type = is_wan_fallback_index(settings, i) ? "udp" : state.dns_type;
            add_health_candidate(result, "main", i, state.main_servers[i], dns_type, "");
        }

    if (length(state.bootstrap_servers) > 1)
        for (let i = 0; i < length(state.bootstrap_servers); i++)
            add_health_candidate(result, "bootstrap", i, state.bootstrap_servers[i]);

    return result;
}

function default_domain_resolver(settings) {
    return bool_option(settings, "dns_detour_enabled", false)
        ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

return {
    DNS_FAILOVER_STATE_FILE,
    DNS_HEALTH_ADDRESS,
    active_values,
    arrays_equal,
    bootstrap_config,
    config,
    configured_server_count,
    default_domain_resolver,
    detour_tag,
    explicit_fallback_count,
    failover_enabled,
    health_port,
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