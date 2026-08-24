#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let runtime_constants = require("singbox.constants");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let int_or_range_option = common.int_or_range_option;
let array_or_empty = common.array_or_empty;

function safe_filename(value) {
    return replace(as_string(value), /[^A-Za-z0-9_.-]/g, "_");
}

function string_to_hex(value) {
    value = as_string(value);
    let result = "";
    for (let i = 0; i < length(value); i++)
        result += sprintf("%02x", ord(value, i));
    return result;
}

function uci_bin_to_hex(val) {
    if (val == null || val == "") return "";
    let s = as_string(val);
    s = replace(s, /^<b\s*/i, "");
    s = replace(s, /^0x/i, "");
    s = replace(s, />$/, "");
    s = replace(s, /\s+/g, "");
    return s;
}

// AWG CPS decoy values (awg_i1..awg_i5, awg_j1..awg_j3): normalized to the
// AmneziaWG 2.0 tag-chain format by common.awg_tag_chain — classic plain-hex
// payloads become "<b 0x..>", existing tag chains pass through verbatim.
function awg_cps_option(section, key) {
    return common.awg_tag_chain(option(section, key, ""));
}

function mtproto_secret(section) {
    let canonical = common.mtproto_secret_canonical(
        option(section, "mtproto_secret", ""),
        option(section, "mtproto_faketls", "google.com")
    );
    if (canonical == null)
        return "";
    return canonical;
}

function users(section, protocol) {
    let name = option(section, protocol == "socks" ? "server_username" : "label", section[".name"]);
    if (name == "")
        name = section[".name"];

    if (protocol == "vless") {
        let user = { uuid: option(section, "server_uuid", "") };
        if (name != "")
            user.name = name;
        let flow = option(section, "vless_flow", "");
        if (flow != "" && flow != "none")
            user.flow = flow;
        return [ user ];
    }
    if (protocol == "vmess") {
        let user = {
            uuid: option(section, "server_uuid", ""),
            alterId: int_option(section, "vmess_alter_id", "0")
        };
        if (name != "")
            user.name = name;
        return [ user ];
    }
    if (protocol == "trojan" || protocol == "hysteria2") {
        let user = { password: option(section, "server_password", "") };
        if (name != "")
            user.name = name;
        return [ user ];
    }
    if (protocol == "socks") {
        return [{
            username: name != "" ? name : "user",
            password: option(section, "server_password", "")
        }];
    }
    if (protocol == "mtproto" || protocol == "shadowsocks") {
        let secret = protocol == "mtproto" ? mtproto_secret(section) : option(section, "server_password", "");
        let user = { password: secret };
        if (name != "")
            user.name = name;
        return [ user ];
    }
    return [];
}

function effective_security(section, protocol) {
    let security = option(section, "security", "");
    if (security == "") {
        if (protocol == "vless")
            security = "reality";
        else if (protocol == "trojan" || protocol == "hysteria2")
            security = "tls";
        else
            security = "none";
    }

    if (protocol == "shadowsocks" || protocol == "socks" || protocol == "mtproto" ||
        protocol == "tailscale" || protocol == "json_inbound" || protocol == "awg")
        return "none";
    if (protocol == "hysteria2")
        return "tls";
    if ((protocol == "vmess" || protocol == "trojan") && security == "reality")
        return protocol == "trojan" ? "tls" : "none";
    return security;
}

function maybe_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function apply_tls(inbound, section, protocol) {
    let security = effective_security(section, protocol);
    if (security == "" || security == "none")
        return;

    let tls = { enabled: true };
    maybe_string(tls, "server_name", option(section, "tls_server_name", ""));
    let alpn = list_option(section, "tls_alpn");
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (security == "tls") {
        maybe_string(tls, "certificate_path", option(section, "tls_certificate_path", ""));
        maybe_string(tls, "key_path", option(section, "tls_key_path", ""));
    }
    else if (security == "reality") {
        let reality = {
            enabled: true,
            handshake: {
                server: option(section, "reality_handshake_server", "www.microsoft.com"),
                server_port: int_option(section, "reality_handshake_server_port", "443")
            },
            private_key: option(section, "reality_private_key", "")
        };
        let short_id = list_option(section, "reality_short_id");
        if (length(short_id) > 0)
            reality.short_id = short_id;
        maybe_string(reality, "max_time_difference", option(section, "reality_max_time_difference", "1m"));
        tls.reality = reality;
    }

    inbound.tls = tls;
}

function apply_transport(inbound, section, protocol) {
    if (protocol != "vless" && protocol != "vmess" && protocol != "trojan")
        return;

    let transport_type = option(section, "transport", "tcp");
    if (transport_type == "" || transport_type == "tcp" || transport_type == "raw")
        return;

    let transport = { type: transport_type };
    let path = option(section, "transport_path", "");
    let host = option(section, "transport_host", "");
    if (transport_type == "ws") {
        maybe_string(transport, "path", path);
        if (host != "")
            transport.headers = { Host: host };
    }
    else if (transport_type == "grpc") {
        maybe_string(transport, "service_name", option(section, "transport_service_name", ""));
    }
    else if (transport_type == "http") {
        maybe_string(transport, "path", path);
        let hosts = list_option(section, "transport_hosts");
        if (length(hosts) > 0)
            transport.host = hosts;
    }
    else if (transport_type == "httpupgrade") {
        maybe_string(transport, "path", path);
        maybe_string(transport, "host", host);
    }
    else if (transport_type == "xhttp") {
        transport.mode = option(section, "transport_xhttp_mode", "auto");
        transport.path = path != "" ? path : "/";
        maybe_string(transport, "host", host);
        transport.headers = {};
        transport.x_padding_bytes = "100-1000";
        transport.no_sse_header = false;
        transport.sc_max_each_post_bytes = "1000000";
        transport.sc_max_buffered_posts = 30;
        transport.sc_stream_up_server_secs = "20-80";
        transport.server_max_header_bytes = 8192;
    }
    else {
        return;
    }

    inbound.transport = transport;
}

function add_standard_inbound(config, section, protocol, tag_name) {
    let inbound = {
        type: protocol,
        tag: tag_name,
        listen: option(section, "listen", "0.0.0.0"),
        listen_port: int_option(section, "listen_port", "443")
    };

    if (protocol == "shadowsocks") {
        inbound.method = option(section, "shadowsocks_method", "aes-128-gcm");
        inbound.password = option(section, "server_password", "");
    }
    else if (protocol == "socks") {
        if (bool_option(section, "socks_auth_enabled", true)) {
            let server_users = users(section, protocol);
            if (length(server_users) > 0)
                inbound.users = server_users;
        }
    }
    else if (protocol == "hysteria2") {
        inbound.users = users(section, protocol);
        let up_mbps = option(section, "hysteria2_up_mbps", "");
        let down_mbps = option(section, "hysteria2_down_mbps", "");
        if (up_mbps != "")
            inbound.up_mbps = int(up_mbps, 10);
        if (down_mbps != "")
            inbound.down_mbps = int(down_mbps, 10);
        let obfs_type = option(section, "hysteria2_obfs_type", "");
        let obfs_password = option(section, "hysteria2_obfs_password", "");
        if (obfs_type != "" && obfs_password != "")
            inbound.obfs = { type: obfs_type, password: obfs_password };
    }
    else if (protocol == "mtproto") {
        inbound.type = "mtproxy";
        inbound.users = users(section, protocol);
        let concurrency = option(section, "mtproto_concurrency", "");
        if (concurrency != "")
            inbound.concurrency = int(concurrency, 10);
        inbound.type = "shadowsocks";
        inbound.method = "2022-blake3-aes-128-gcm";
        inbound.password = option(section, "server_password", "");
        let server_users = users(section, protocol);
        if (length(server_users) > 0)
            inbound.users = server_users;
        maybe_string(inbound, "network", option(section, "mtproto_network", "tcp"));
        maybe_string(inbound, "prefer_ip", option(section, "mtproto_prefer_ip", "prefer-ipv4"));
        if (bool_option(section, "mtproto_auto_update", false))
            inbound.auto_update = true;
        if (bool_option(section, "mtproto_allow_fallback_on_unknown_dc", false))
            inbound.allow_fallback_on_unknown_dc = true;
        maybe_string(inbound, "tolerate_time_skewness", option(section, "mtproto_tolerate_time_skewness", "3s"));
        maybe_string(inbound, "idle_timeout", option(section, "mtproto_idle_timeout", "5m"));
        maybe_string(inbound, "handshake_timeout", option(section, "mtproto_handshake_timeout", "10s"));
    }
    else if (protocol == "awg") {
        inbound.type = "wireguard";
        inbound.address = list_option(section, "awg_local_address");
        inbound.private_key = option(section, "awg_private_key", "");
        inbound.mtu = int_option(section, "awg_mtu", "1280");

        let server_address = option(section, "awg_server_address", "");
        let server_port = int_option(section, "awg_server_port", "51820");
        let peer_public_key = option(section, "awg_peer_public_key", "");

        let allowed_ips = list_option(section, "awg_allowed_ips");
        if (length(allowed_ips) == 0) {
            let allowed_str = option(section, "awg_allowed_ips", "");
            if (allowed_str != "")
                allowed_ips = split(allowed_str, /[,\s]+/);
            else
                allowed_ips = [ "0.0.0.0/0", "::/0" ];
        }

        let peer = {
            public_key: peer_public_key,
            allowed_ips: allowed_ips
        };
        if (server_address != "")
            peer.address = server_address;
        if (server_port > 0)
            peer.port = server_port;

        let preshared_key = option(section, "awg_preshared_key", "");
        if (preshared_key != "")
            peer.pre_shared_key = preshared_key;

        let keepalive = int_option(section, "awg_keepalive", "0");
        if (keepalive > 0)
            peer.persistent_keepalive_interval = keepalive;

        inbound.peers = [ peer ];

        let jc = int_option(section, "awg_jc", "4");
        if (jc > 10) jc = 10;
        let jmin = int_option(section, "awg_jmin", "40");
        let jmax = int_option(section, "awg_jmax", "70");
        if (jmax > 1200) jmax = 1200;
        let is_lx = trim(fs.readfile("/etc/tachyon/sing-box-variant") || "") == "lx";

        let amnezia = {
            jc: jc,
            jmin: jmin,
            jmax: jmax,
            s1: int_option(section, "awg_s1", "0"),
            s2: int_option(section, "awg_s2", "0"),
            // H1-H4 use badoption.Range on both sing-box-extended and
            // sing-box-lx, so a "min-max" string passes through.
            h1: int_or_range_option(section, "awg_h1", 1),
            h2: int_or_range_option(section, "awg_h2", 2),
            h3: int_or_range_option(section, "awg_h3", 3),
            h4: int_or_range_option(section, "awg_h4", 4),
            s3: int_option(section, "awg_s3", "0"),
            s4: int_option(section, "awg_s4", "0")
        };

        let i1 = awg_cps_option(section, "awg_i1");
        let i2 = awg_cps_option(section, "awg_i2");
        let i3 = awg_cps_option(section, "awg_i3");
        let i4 = awg_cps_option(section, "awg_i4");
        let i5 = awg_cps_option(section, "awg_i5");
        let j1 = awg_cps_option(section, "awg_j1");
        let j2 = awg_cps_option(section, "awg_j2");
        let j3 = awg_cps_option(section, "awg_j3");
        let itime = int_option(section, "awg_itime", "0");

        if (is_lx) {
            // sing-box-lx expects AWG fields at the inbound root (AWG 2.0 schema);
            // magic headers accept a single value or an AWG 2.0 "min-max" range.
            // j1-j3/itime are sing-box-extended-only and are not emitted here.
            inbound.jc = amnezia.jc;
            inbound.jmin = amnezia.jmin;
            inbound.jmax = amnezia.jmax;
            inbound.s1 = amnezia.s1;
            inbound.s2 = amnezia.s2;
            inbound.h1 = amnezia.h1;
            inbound.h2 = amnezia.h2;
            inbound.h3 = amnezia.h3;
            inbound.h4 = amnezia.h4;
            inbound.s3 = amnezia.s3;
            inbound.s4 = amnezia.s4;
            if (i1 != "") inbound.i1 = i1;
            if (i2 != "") inbound.i2 = i2;
            if (i3 != "" && i3 != "0") inbound.i3 = i3;
            if (i4 != "" && i4 != "0") inbound.i4 = i4;
            if (i5 != "" && i5 != "0") inbound.i5 = i5;
        } else {
            if (i1 != "") amnezia.i1 = i1;
            if (i2 != "") amnezia.i2 = i2;
            if (i3 != "" && i3 != "0") amnezia.i3 = i3;
            if (i4 != "" && i4 != "0") amnezia.i4 = i4;
            if (i5 != "" && i5 != "0") amnezia.i5 = i5;
            // j1-j3/itime were removed from the extended schema in 2.6.1 and
            // sing-box fatals on unknown fields, so emit them only for builds
            // whose schema still accepts them.
            let sb_version_state_file = getenv("SB_VERSION_STATE_FILE") || "/etc/tachyon/sing-box-version";
            let sb_version = trim(fs.readfile(sb_version_state_file) || "");
            if (common.extended_awg_schema_has_junk_signatures(sb_version)) {
                if (j1 != "") amnezia.j1 = j1;
                if (j2 != "") amnezia.j2 = j2;
                if (j3 != "") amnezia.j3 = j3;
                if (itime > 0) amnezia.itime = itime;
            }
            inbound.amnezia = amnezia;
        }
    }
    else {
        inbound.users = users(section, protocol);
    }

    apply_tls(inbound, section, protocol);
    apply_transport(inbound, section, protocol);
    push(config.inbounds, inbound);
}

function add_json_inbound(config, section, tag_name) {
    let inbound = {};
    try {
        inbound = json(option(section, "inbound_json", ""));
    }
    catch (e) {
        inbound = {};
    }
    if (type(inbound) != "object")
        inbound = {};
    inbound.tag = tag_name;
    push(config.inbounds, inbound);
}

function add_tailscale_endpoint(config, section, tag_name) {
    let section_name = section[".name"];
    let endpoint = {
        type: "tailscale",
        tag: tag_name,
        state_directory: "/etc/tachyon/tailscale/" + safe_filename(section_name),
        auth_key: option(section, "tailscale_auth_key", ""),
        control_url: option(section, "tailscale_control_url", "https://controlplane.tailscale.com"),
        hostname: option(section, "tailscale_hostname", "tachyon-" + safe_filename(section_name))
    };
    if (bool_option(section, "tailscale_accept_routes", false))
        endpoint.accept_routes = true;
    let advertise_routes = list_option(section, "tailscale_advertise_routes");
    if (length(advertise_routes) > 0)
        endpoint.advertise_routes = advertise_routes;
    if (bool_option(section, "tailscale_advertise_exit_node", false))
        endpoint.advertise_exit_node = true;
    push(config.endpoints, endpoint);
}

function add_dns_bypass(config, section) {
    if (option(section, "protocol", "vless") != "tailscale")
        return;

    let section_name = section[".name"];
    let inbound = runtime_constants.server_inbound_tag(section_name);
    let dns_tag = runtime_constants.tailscale_dns_server_tag(section_name);
    let rule_tag = "tailscale-server-dns-" + safe_filename(section_name);
    push(config.dns.servers, {
        type: "tailscale",
        tag: dns_tag,
        endpoint: inbound,
        accept_default_resolvers: true
    });
    push(config.dns.rules, {
        action: "route",
        server: dns_tag,
        inbound,
        __service_tag: rule_tag
    });
}

function add_server(config, section) {
    let section_name = section[".name"];
    let protocol = option(section, "protocol", "vless");
    let tag_name = runtime_constants.server_inbound_tag(section_name);

    if (protocol == "tailscale")
        add_tailscale_endpoint(config, section, tag_name);
    else if (protocol == "json_inbound")
        add_json_inbound(config, section, tag_name);
    else
        add_standard_inbound(config, section, protocol, tag_name);
    add_dns_bypass(config, section);
}

function add_sniff_rule(config, section) {
    let rules = array_or_empty(config.route.rules);
    let rule = {
        action: "sniff",
        inbound: runtime_constants.server_inbound_tag(section[".name"])
    };
    let insert_at = 0;
    while (insert_at < length(rules) && type(rules[insert_at]) == "object" && rules[insert_at].action == "sniff")
        insert_at++;

    let result = [];
    for (let i = 0; i < insert_at; i++)
        push(result, rules[i]);
    push(result, rule);
    for (let i = insert_at; i < length(rules); i++)
        push(result, rules[i]);
    config.route.rules = result;
}

function clone(value) {
    try {
        return json(sprintf("%J", value));
    }
    catch (e) {
        return null;
    }
}

function value_contains(value, item) {
    if (type(value) == "array") {
        for (let entry in value)
            if (entry == item)
                return true;
        return false;
    }
    return value == item;
}

function clone_rules_for_inbound(config, source_inbound, target_inbound, skip_domain) {
    let cloned_rules = [];
    for (let rule in array_or_empty(config.route.rules)) {
        if (type(rule) != "object")
            continue;
        if (rule.action != "route" && rule.action != "reject")
            continue;
        if (!value_contains(rule.inbound, source_inbound))
            continue;
        if (skip_domain != "" && value_contains(rule.domain, skip_domain))
            continue;
        if (rule.source_ip_cidr != null)
            continue;

        let cloned = clone(rule);
        if (type(cloned) != "object")
            continue;
        cloned.inbound = target_inbound;
        push(cloned_rules, cloned);
    }
    for (let cloned_rule in cloned_rules)
        push(config.route.rules, cloned_rule);
}

return {
    add_server,
    add_sniff_rule,
    clone_rules_for_inbound
};