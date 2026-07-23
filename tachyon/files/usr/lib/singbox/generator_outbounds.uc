#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let runtime_constants = require("singbox.constants");
let runtime_subscription = require("singbox.subscription");
let runtime_country = require("singbox.country");
let runtime_dns = require("singbox.dns");
let runtime_url = require("core.url");
let subscription_share_link = require("subscription.share_link");
let connections = require("config.connections");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;
let read_json_file = common.read_json_file;

let url_decode = runtime_url.decode;
let url_scheme = runtime_url.scheme;
let url_fragment = runtime_url.fragment;
let url_strip_fragment_value = runtime_url.strip_fragment;
let url_host = runtime_url.host;
let url_port = runtime_url.port;
let url_userinfo = runtime_url.userinfo;
let url_path = runtime_url.path;
let url_query_params = runtime_url.query_params;

let outbound_tag = runtime_constants.outbound_tag;
let tag = runtime_constants.tag;

let ctx = {};

function init(c) {
    ctx = c;
}

function unique_string_array(values) {
    let result = [];
    let seen = {};
    for (let value in array_or_empty(values)) {
        value = as_string(value);
        if (value == "" || seen[value])
            continue;
        seen[value] = true;
        push(result, value);
    }
    return result;
}

function uci_bin_to_hex(val) {
    if (val == null || val == "") return "";
    let s = replace("" + val, "<b 0x", "");
    s = replace(s, ">", "");
    s = replace(s, " ", "");
    return s;
}

function internal_flag(value) {
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes";
}

function subscription_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    return (t == "selector" || t == "urltest") && internal_flag(outbound.__tachyon_allow_group);
}

function subscription_urltest_group_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    return as_string(outbound.type || "") == "urltest" && internal_flag(outbound.__tachyon_allow_group);
}

function subscription_outbound_tag(outbound) {
    return type(outbound) == "object" ? as_string(outbound.tag || "") : "";
}

function subscription_visibility_refs(outbounds) {
    let refs = {
        urltest: {},
        detour: {}
    };

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        if (subscription_urltest_group_outbound(outbound)) {
            for (let tag_name in array_or_empty(outbound.outbounds)) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    refs.urltest[tag_name] = true;
            }
        }

        let detour = as_string(outbound.detour || "");
        if (detour != "")
            refs.detour[detour] = true;
    }

    return refs;
}

function subscription_hidden_outbound(outbound, refs, hide_urltest_group_outbounds, hide_detour_outbounds) {
    if (type(outbound) != "object")
        return false;

    let tag_name = subscription_outbound_tag(outbound);
    let urltest_refs = object_or_empty(object_or_empty(refs).urltest);
    let detour_refs = object_or_empty(object_or_empty(refs).detour);
    let hidden_by_urltest = tag_name != "" && urltest_refs[tag_name];
    let hidden_by_detour = tag_name != "" && detour_refs[tag_name];

    if (hidden_by_urltest && hide_urltest_group_outbounds !== false)
        return true;
    if (hidden_by_detour && hide_detour_outbounds !== false)
        return true;
    return internal_flag(outbound.__tachyon_hidden) && !hidden_by_urltest && !hidden_by_detour;
}

function supported_subscription_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    if (subscription_group_outbound(outbound))
        return true;
    if (t == "direct" || t == "selector" || t == "urltest" || t == "dns" || t == "block")
        return false;
    return t == "vless" || t == "vmess" || t == "trojan" || t == "shadowsocks" ||
        t == "socks" || t == "hysteria2";
}

function outbound_uses_xhttp(outbound) {
    return type(outbound) == "object" && type(outbound.transport) == "object" &&
        lc(as_string(outbound.transport.type || "")) == "xhttp";
}

function ensure_explicit_outbound_supported(outbound, source, name) {
    if (!ctx.runtime_supports_xhttp && outbound_uses_xhttp(outbound))
        ctx.runtime_generate_unsupported(as_string(source) + " '" + as_string(name) + "' uses XHTTP transport, but sing-box-extended is not installed");
}

function subscription_outbound_display_name(outbound) {
    return type(outbound) == "object"
        ? as_string(outbound.remark || outbound.tag || "unknown")
        : "unknown";
}

function add_subscription_reference(refs, value) {
    value = as_string(value);
    if (value != "")
        refs[value] = true;
}

function subscription_reference_set(outbounds) {
    let refs = {};
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;
        add_subscription_reference(refs, outbound.tag);
        add_subscription_reference(refs, outbound.remark);
    }
    return refs;
}

function subscription_reference_available(reference, source_refs, retained_refs) {
    reference = as_string(reference);
    return reference == "" || !source_refs[reference] || retained_refs[reference];
}

function subscription_group_has_retained_member(outbound, retained_refs) {
    for (let reference in array_or_empty(outbound.outbounds))
        if (retained_refs[as_string(reference)])
            return true;
    return false;
}

function warn_skipped_subscription_outbound(section_name, outbound, reason) {
    warn("skipped incompatible subscription outbound for rule '", section_name, "': ",
        subscription_outbound_display_name(outbound), " (", reason, ")\n");
}

function compatible_subscription_outbounds(outbounds, section_name) {
    let source_refs = subscription_reference_set(outbounds);
    let retained = [];
    for (let outbound in array_or_empty(outbounds)) {
        if (!supported_subscription_outbound(outbound))
            continue;
        if (!ctx.runtime_supports_xhttp && outbound_uses_xhttp(outbound)) {
            warn_skipped_subscription_outbound(section_name, outbound, "XHTTP requires sing-box-extended");
            continue;
        }
        push(retained, outbound);
    }

    while (true) {
        let retained_refs = subscription_reference_set(retained);
        let next = [];
        let changed = false;
        for (let outbound in retained) {
            let detour = as_string(outbound.detour || "");
            if (!subscription_reference_available(detour, source_refs, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound,
                    "detour depends on unavailable outbound '" + detour + "'");
                changed = true;
                continue;
            }
            if (subscription_group_outbound(outbound) &&
                !subscription_group_has_retained_member(outbound, retained_refs)) {
                warn_skipped_subscription_outbound(section_name, outbound, "group has no compatible outbounds");
                changed = true;
                continue;
            }
            push(next, outbound);
        }
        retained = next;
        if (!changed)
            return retained;
    }
}

function copy_subscription_outbound(outbound, new_tag) {
    let copy = {};
    for (let key, value in outbound) {
        if (key != "tag" && key != "remark" && key != "share_link" &&
            key != "__tachyon_hidden" && key != "__tachyon_allow_group")
            copy[key] = value;
    }
    if (as_string(copy.type || "") == "hysteria2" &&
        type(copy.tls) == "object" &&
        copy.tls.utls != null) {
        let tls = {};
        for (let key, value in copy.tls) {
            if (key != "utls")
                tls[key] = value;
        }
        copy.tls = tls;
    }
    copy.tag = new_tag;
    return copy;
}

function string_array_contains(values, needle) {
    for (let value in array_or_empty(values))
        if (as_string(value) == as_string(needle))
            return true;
    return false;
}

function rewrite_subscription_outbound_references(outbounds, tag_map, source_refs) {
    for (let outbound in outbounds) {
        if (type(outbound) != "object")
            continue;

        let detour = as_string(outbound.detour || "");
        if (detour != "" && tag_map[detour])
            outbound.detour = tag_map[detour];
        else if (detour != "" && source_refs[detour])
            delete outbound.detour;

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_map[tag_name])
                    push(rewritten, tag_map[tag_name]);
            }
            outbound.outbounds = rewritten;

            if (as_string(outbound.type || "") == "urltest") {
                delete outbound.default;
            }
            else {
                let default_tag = as_string(outbound.default || "");
                if (default_tag != "" && tag_map[default_tag])
                    default_tag = tag_map[default_tag];
                if (default_tag == "" || !string_array_contains(rewritten, default_tag))
                    default_tag = length(rewritten) > 0 ? rewritten[0] : "";
                if (default_tag != "")
                    outbound.default = default_tag;
                else
                    delete outbound.default;
            }
        }
    }
}

function subscription_skip_summary(skipped) {
    let parts = [];
    for (let t in sort(keys(skipped)))
        push(parts, skipped[t] + "x " + t);
    return join("; ", parts);
}

function reportable_skipped_subscription_type(t) {
    return t != "direct" && t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function urltest_leaf_candidate_outbound(outbound) {
    if (type(outbound) != "object")
        return false;

    let t = lc(as_string(outbound.type || ""));
    return t != "selector" && t != "urltest" && t != "dns" && t != "block";
}

function unique_tag(base, taken) {
    base = as_string(base);
    if (base == "")
        base = "server";
    if (!taken[base])
        return base;
    for (let i = 1; i < 100000; i++) {
        let candidate = base + "-" + i;
        if (!taken[candidate])
            return candidate;
    }
    return base + "-overflow";
}

function reserved_runtime_tag_set(outbounds) {
    let result = {};
    for (let tag_name in keys(object_or_empty(runtime_constants.RESERVED_TAGS)))
        result[tag_name] = true;

    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        let tag_name = as_string(outbound.tag || "");
        if (tag_name != "")
            result[tag_name] = true;
    }
    return result;
}

function assert_unique_outbound_tags(config) {
    let seen = {};
    for (let outbound in array_or_empty(config.outbounds)) {
        if (type(outbound) != "object")
            ctx.runtime_generate_unsupported("generated sing-box outbound is not an object");

        let tag_name = as_string(outbound.tag || "");
        if (tag_name == "")
            ctx.runtime_generate_unsupported("generated sing-box outbound has an empty tag");
        if (seen[tag_name])
            ctx.runtime_generate_unsupported("generated sing-box config has duplicate outbound tag '" + tag_name + "'");
        seen[tag_name] = true;
    }
}

function parse_port(value) {
    value = as_string(value);
    if (match(value, /^[0-9]+$/) == null)
        return null;
    let port = int(value, 10);
    return port >= 1 && port <= 65535 ? port : null;
}

function bool_query(value) {
    return value == "1" || value == "true";
}

function base64_decode_value(value) {
    value = replace(as_string(value), /[\r\n\t ]/g, "");
    value = replace(replace(value, /-/g, "+"), /_/g, "/");
    while (length(value) % 4 != 0)
        value += "=";
    try {
        return b64dec(value);
    }
    catch (e) {
        return null;
    }
}

function shadowsocks_userinfo_valid(value) {
    value = as_string(value);
    let first = index(value, ":");
    if (first <= 0 || first >= length(value) - 1)
        return false;
    let rest = substr(value, first + 1);
    let second = index(rest, ":");
    return second < 0 || index(substr(rest, second + 1), ":") < 0;
}

function split_host_port(value) {
    value = as_string(value);
    if (substr(value, 0, 1) == "[") {
        let close = index(value, "]");
        if (close > 0 && substr(value, close + 1, 1) == ":")
            return [ substr(value, 1, close - 1), substr(value, close + 2) ];
    }

    let colon = rindex(value, ":");
    if (colon < 0)
        return [ "", "" ];
    return [ substr(value, 0, colon), substr(value, colon + 1) ];
}

function tls_alpn_array(value, transport) {
    value = as_string(value);
    transport = lc(as_string(transport));
    if (value == "" && transport == "xhttp")
        return [ "h2", "http/1.1" ];
    if (value != "" && (transport == "ws" || transport == "httpupgrade"))
        return [ "http/1.1" ];
    return value == "" ? [] : split(value, ",");
}

function apply_link_tls(outbound, scheme, query) {
    query = object_or_empty(query);
    let security = as_string(query.security || "");
    if (security == "" && (scheme == "hysteria2" || scheme == "hy2"))
        security = "tls";

    if (security == "" || security == "none")
        return;
    if (security != "tls" && security != "reality") {
        warn("unknown manual proxy link security '", security, "' ignored\n");
        return;
    }

    let tls = { enabled: true };
    if (as_string(query.sni || "") != "")
        tls.server_name = as_string(query.sni);
    if (bool_query(query.allowInsecure || query.insecure || ""))
        tls.insecure = true;

    let alpn = tls_alpn_array(query.alpn, query.type);
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (scheme != "hysteria2" && scheme != "hy2" && as_string(query.fp || "") != "") {
        tls.utls = {
            enabled: true,
            fingerprint: as_string(query.fp)
        };
    }
    if (security == "reality") {
        tls.reality = {
            enabled: true,
            public_key: as_string(query.pbk || ""),
            short_id: as_string(query.sid || "")
        };
    }
    outbound.tls = tls;
}

function csv_array(value) {
    value = as_string(value);
    if (value == "")
        return [];
    let result = [];
    for (let item in split(value, ",")) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function optional_query_string(object, key, value) {
    value = as_string(value);
    if (value != "")
        object[key] = value;
}

function optional_query_number(object, key, value) {
    value = as_string(value);
    if (value != "" && match(value, /^[0-9]+$/) != null)
        object[key] = int(value, 10);
}

function apply_link_transport(outbound, query) {
    let transport = lc(as_string(object_or_empty(query).type || ""));
    if (transport == "" || transport == "tcp" || transport == "raw")
        return;

    if (transport == "h2")
        transport = "http";

    let result = { type: transport };
    if (transport == "http") {
        optional_query_string(result, "path", query.path);
        let hosts = csv_array(query.host);
        if (length(hosts) > 0)
            result.host = hosts;
    }
    else if (transport == "ws") {
        result.path = as_string(query.path || "");
        if (as_string(query.host || "") != "")
            result.headers = { Host: as_string(query.host) };
        optional_query_number(result, "max_early_data", query.ed);
    }
    else if (transport == "grpc") {
        optional_query_string(result, "service_name", query.serviceName);
    }
    else if (transport == "httpupgrade") {
        optional_query_string(result, "path", query.path);
        optional_query_string(result, "host", query.host);
    }
    else if (transport == "xhttp") {
        let mode = as_string(query.mode || "auto");
        if (mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one")
            mode = "auto";
        result.mode = mode;
        result.path = as_string(query.path || "") != "" ? as_string(query.path) : "/";
        result.x_padding_bytes = "100-1000";
        result.no_grpc_header = false;
        result.sc_max_each_post_bytes = "1000000";
        result.sc_min_posts_interval_ms = "30";
        optional_query_string(result, "host", as_string(query.host || "") != "" ? query.host : query.sni);
    }
    else {
        warn("unknown manual proxy link transport '", transport, "' ignored\n");
        return;
    }

    outbound.transport = result;
}

function manual_socks_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    if (host == "" || port == null)
        ctx.runtime_generate_unsupported("manual SOCKS proxy link is invalid");

    let outbound = {
        type: "socks",
        tag: tag_name,
        server: host,
        server_port: port,
        version: scheme == "socks4" || scheme == "socks4a" ? "4" : "5"
    };
    if (scheme == "socks5") {
        let userinfo = url_userinfo(link);
        if (userinfo != "") {
            let colon = index(userinfo, ":");
            outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
            if (colon >= 0)
                outbound.password = substr(userinfo, colon + 1);
        }
    }
    return outbound;
}

function manual_shadowsocks_outbound(link, tag_name) {
    let raw = url_strip_fragment_value(url_decode(link));
    let body = substr(raw, 5);
    let question = index(body, "?");
    let query_string = "";
    if (question >= 0) {
        query_string = substr(body, question + 1);
        body = substr(body, 0, question);
    }

    let at = rindex(body, "@");
    let userinfo = "";
    let hostport = "";
    if (at >= 0) {
        userinfo = substr(body, 0, at);
        hostport = substr(body, at + 1);
    }
    else {
        let decoded = base64_decode_value(body);
        if (decoded == null)
            ctx.runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        at = rindex(decoded, "@");
        if (at < 0)
            ctx.runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = substr(decoded, 0, at);
        hostport = substr(decoded, at + 1);
    }

    userinfo = url_decode(userinfo);
    if (!shadowsocks_userinfo_valid(userinfo)) {
        let decoded = base64_decode_value(userinfo);
        if (decoded == null)
            ctx.runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");
        userinfo = decoded;
    }

    let cred_colon = index(userinfo, ":");
    let host_port = split_host_port(hostport);
    let port = parse_port(host_port[1]);
    if (cred_colon <= 0 || host_port[0] == "" || port == null)
        ctx.runtime_generate_unsupported("manual Shadowsocks proxy link is invalid");

    let outbound = {
        type: "shadowsocks",
        tag: tag_name,
        server: host_port[0],
        server_port: port,
        method: substr(userinfo, 0, cred_colon),
        password: substr(userinfo, cred_colon + 1)
    };
    let query = url_query_params("ss://placeholder/?" + query_string);
    if (as_string(query.plugin || "") != "")
        outbound.plugin = as_string(query.plugin);
    if (as_string(query["plugin-opts"] || "") != "")
        outbound.plugin_opts = as_string(query["plugin-opts"]);
    return outbound;
}

function manual_vless_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let uuid = url_userinfo(link);
    if (host == "" || port == null || uuid == "")
        ctx.runtime_generate_unsupported("manual VLESS proxy link is invalid");

    let outbound = {
        type: "vless",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid
    };
    let flow = as_string(query.flow || "");
    if (flow != "")
        outbound.flow = flow;
    let encryption = as_string(query.encryption || "");
    if (encryption != "" && encryption != "none")
        outbound.encryption = encryption;
    let packet_encoding = as_string(query.packetEncoding || "");
    if (packet_encoding == "xudp" || packet_encoding == "packetaddr")
        outbound.packet_encoding = packet_encoding;
    apply_link_tls(outbound, "vless", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function vmess_json_value(value) {
    return value == null ? "" : as_string(value);
}

function manual_vmess_outbound(link, tag_name) {
    let encoded = substr(url_strip_fragment_value(link), 8);
    let decoded = base64_decode_value(encoded);
    if (decoded == null)
        ctx.runtime_generate_unsupported("manual VMess proxy link is invalid");

    if (index(decoded, "\r") >= 0 || index(decoded, "\n") >= 0)
        decoded = replace(decoded, /[\r\n]/g, "");
    decoded = trim(decoded);

    let vmess;
    try {
        vmess = json(decoded);
    }
    catch (e) {
        ctx.runtime_generate_unsupported("manual VMess proxy link is invalid");
    }
    if (type(vmess) != "object")
        ctx.runtime_generate_unsupported("manual VMess proxy link is invalid");

    let host = vmess_json_value(vmess.add);
    let port = parse_port(vmess_json_value(vmess.port));
    let uuid = vmess_json_value(vmess.id);
    if (host == "" || port == null || uuid == "")
        ctx.runtime_generate_unsupported("manual VMess proxy link is invalid");

    let outbound = {
        type: "vmess",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid,
        security: vmess_json_value(vmess.scy) != "" ? vmess_json_value(vmess.scy) : "auto"
    };

    if (vmess_json_value(vmess.aid) != "")
        outbound.alter_id = int(vmess.aid || 0);

    let network = lc(vmess_json_value(vmess.net));
    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let tls = { enabled: true };
        optional_query_string(tls, "server_name", vmess_json_value(vmess.sni));
        let alpn = tls_alpn_array(vmess_json_value(vmess.alpn), network);
        if (length(alpn) > 0)
            tls.alpn = alpn;
        if (vmess_json_value(vmess.fp) != "") {
            tls.utls = {
                enabled: true,
                fingerprint: vmess_json_value(vmess.fp)
            };
        }
        outbound.tls = tls;
    }

    if (network == "ws") {
        outbound.transport = {
            type: "ws",
            path: vmess_json_value(vmess.path) != "" ? vmess_json_value(vmess.path) : "/"
        };
        if (vmess_json_value(vmess.host) != "")
            outbound.transport.headers = { Host: vmess_json_value(vmess.host) };
    }
    else if (network == "grpc") {
        outbound.transport = { type: "grpc" };
        optional_query_string(outbound.transport, "service_name", vmess_json_value(vmess.path));
    }
    else if (network == "http" || network == "h2") {
        outbound.transport = { type: "http" };
        optional_query_string(outbound.transport, "path", vmess_json_value(vmess.path));
        let hosts = csv_array(vmess_json_value(vmess.host));
        if (length(hosts) > 0)
            result.host = hosts;
    }

    return outbound;
}

function manual_trojan_outbound(link, tag_name) {
    let query = url_query_params(link);

    let host = url_host(link);
    let port = parse_port(url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        ctx.runtime_generate_unsupported("manual Trojan proxy link is invalid");

    let outbound = {
        type: "trojan",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    apply_link_tls(outbound, "trojan", query);
    apply_link_transport(outbound, query);
    return outbound;
}

function manual_hysteria2_outbound(link, tag_name) {
    let query = url_query_params(link);
    let host = url_host(link);
    let port = parse_port(as_string(query.mport || "") != "" ? query.mport : url_port(link));
    let password = url_userinfo(link);
    if (host == "" || port == null || password == "")
        ctx.runtime_generate_unsupported("manual Hysteria2 proxy link is invalid");

    let outbound = {
        type: "hysteria2",
        tag: tag_name,
        server: host,
        server_port: port,
        password
    };
    if (as_string(query.obfs || "") != "")
        outbound.obfs = { type: as_string(query.obfs), password: as_string(query["obfs-password"] || "") };
    if (as_string(query.upmbps || "") != "")
        outbound.up_mbps = int(query.upmbps, 10);
    if (as_string(query.downmbps || "") != "")
        outbound.down_mbps = int(query.downmbps, 10);
    apply_link_tls(outbound, url_scheme(link), query);
    return outbound;
}

function manual_link_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    if (scheme == "vmess")
        return manual_vmess_outbound(link, tag_name);

    link = url_strip_fragment_value(url_decode(link));
    scheme = url_scheme(link);
    if (scheme == "socks4" || scheme == "socks4a" || scheme == "socks5")
        return manual_socks_outbound(link, tag_name);
    if (scheme == "ss")
        return manual_shadowsocks_outbound(link, tag_name);
    if (scheme == "vless")
        return manual_vless_outbound(link, tag_name);
    if (scheme == "trojan")
        return manual_trojan_outbound(link, tag_name);
    if (scheme == "hysteria2" || scheme == "hy2")
        return manual_hysteria2_outbound(link, tag_name);
    ctx.runtime_generate_unsupported("manual proxy link scheme is not supported by sing-box config generation yet");
}

function add_manual_proxy_link(config, state, section_name, manual_index, link, taken, selector_tags, urltest_candidate_tags) {
    let tag_name = outbound_tag(section_name + "-" + manual_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let outbound = manual_link_outbound(link, tag_name);
    let display_name = url_fragment(link);
    if (display_name == "")
        display_name = tag_name;
    ensure_explicit_outbound_supported(outbound, "manual outbound", display_name);
    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);

    state.links[tag_name] = as_string(link);
    runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
    return tag_name;
}

function connection_item_tag(section_name, kind, item_index) {
    return outbound_tag(section_name + "-" + as_string(kind) + "-" + item_index);
}

function add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let manual_links = connections.connection_urls(section);
    for (let i = 0; i < length(manual_links); i++) {
        let link = manual_links[i];
        add_manual_proxy_link(
            config,
            state,
            section_name,
            i + 1,
            link,
            taken,
            selector_tags,
            urltest_candidate_tags
        );
    }
}

function add_subscription_source_with_state(config, section, source_index, source_entry, taken, selector_tags, urltest_candidate_tags, state, show_metadata, include_urltest_groups, hide_urltest_group_outbounds, hide_detour_outbounds, node_prefix) {
    let section_name = section[".name"];
    let source_section = runtime_subscription.source_id(section_name, source_index);
    if (!runtime_subscription.source_cache_is_current(
        source_section,
        source_entry,
        connections.subscription_user_agent(section, source_entry),
        connections.subscription_hwid(section, source_entry),
        connections.subscription_device_headers_signature(section, source_entry)
    ))
        return 0;

    let source_outbounds = runtime_subscription.read_source_outbounds(source_section);
    if (length(source_outbounds) == 0)
        return 0;

    let skipped = {};
    for (let outbound in source_outbounds) {
        if (supported_subscription_outbound(outbound))
            continue;
        let t = type(outbound) == "object" ? as_string(outbound.type || "missing-type") : "non-object";
        if (reportable_skipped_subscription_type(t))
            skipped[t] = (skipped[t] || 0) + 1;
    }
    let outbounds = compatible_subscription_outbounds(source_outbounds, section_name);

    if (show_metadata !== false)
        runtime_subscription.merge_source_metadata(state, section_name, source_section, source_index, source_entry);
    let visibility_refs = subscription_visibility_refs(outbounds);
    if (include_urltest_groups === false)
        hide_urltest_group_outbounds = false;
    node_prefix = trim(as_string(node_prefix));
    let prepared = [];
    let display_names = [];
    let source_links = [];
    let group_flags = [];
    let hidden_flags = [];
    let tag_map = {};
    for (let i = 0; i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (include_urltest_groups === false && subscription_urltest_group_outbound(outbound))
            continue;
        let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
        let base = as_string(outbound.tag || outbound.remark || ("server-" + (i + 1)));
        if (node_prefix != "") {
            display_name = node_prefix + " " + display_name;
            base = display_name;
        }
        let new_tag = unique_tag(base, taken);
        taken[new_tag] = true;
        tag_map[base] = new_tag;
        if (as_string(outbound.tag || "") != "")
            tag_map[as_string(outbound.tag)] = new_tag;
        if (as_string(outbound.remark || "") != "")
            tag_map[as_string(outbound.remark)] = new_tag;
        push(prepared, copy_subscription_outbound(outbound, new_tag));
        push(display_names, display_name);
        let source_link = as_string(outbound.share_link || "");
        if (!subscription_share_link.is_copyable_link(source_link))
            source_link = subscription_share_link.serialize_outbound_link(outbound);
        push(source_links, source_link);
        push(group_flags, subscription_group_outbound(outbound));
        push(hidden_flags, subscription_hidden_outbound(outbound, visibility_refs, hide_urltest_group_outbounds, hide_detour_outbounds));
    }

    if (length(keys(skipped)) > 0)
        warn("skipped unsupported subscription outbounds for rule '", section_name, "': ", subscription_skip_summary(skipped), "\n");

    rewrite_subscription_outbound_references(prepared, tag_map, subscription_reference_set(source_outbounds));
    let added = 0;
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        let is_group = group_flags[i] === true;
        if (is_group && length(array_or_empty(outbound.outbounds)) == 0) {
            warn("skipped empty subscription group for rule '", section_name, "': ", as_string(display_names[i] || outbound.tag || "unknown"), "\n");
            continue;
        }

        push(config.outbounds, outbound);
        added++;
        if (!is_group)
            push(urltest_candidate_tags, outbound.tag);
        runtime_subscription.remember_source_outbound(
            state,
            outbound.tag,
            display_names[i],
            outbound,
            source_links[i]
        );
        if (hidden_flags[i] !== true) {
            push(selector_tags, outbound.tag);
            runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
        }
    }
    return added;
}

function add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let subscription_urls = connections.subscription_urls(section);

    for (let i = 0; i < length(subscription_urls); i++)
        add_subscription_source_with_state(
            config,
            section,
            i + 1,
            subscription_urls[i],
            taken,
            selector_tags,
            urltest_candidate_tags,
            state,
            connections.subscription_dashboard_metadata_enabled(section, subscription_urls[i]),
            connections.subscription_include_urltest_groups(section, subscription_urls[i]),
            connections.subscription_hide_urltest_group_outbounds(section, subscription_urls[i]),
            connections.subscription_hide_detour_outbounds(section, subscription_urls[i]),
            connections.subscription_node_prefix(section, subscription_urls[i])
        );
}

function add_interface_connection_outbound(config, state, section, interface_index, interface_name, taken, selector_tags, urltest_candidate_tags) {
    let section_name = section[".name"];
    let tag_name = connection_item_tag(section_name, "interface", interface_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let domain_resolver = "";
    if (connections.interface_domain_resolver_enabled(section, interface_name)) {
        domain_resolver = runtime_constants.domain_resolver_tag(section_name + "-interface-" + interface_index);
        let dns_server = runtime_dns.server_from_options(
            domain_resolver,
            connections.interface_domain_resolver_dns_type(section, interface_name),
            connections.interface_domain_resolver_dns_server(section, interface_name),
            tag_name
        );
        if (dns_server.unsupported)
            ctx.runtime_generate_unsupported(dns_server.unsupported);
        push(config.dns.servers, dns_server);
    }

    let outbound = {
        type: "direct",
        tag: tag_name,
        bind_interface: interface_name,
        domain_resolver,
        routing_mark: runtime_constants.OUTBOUND_MARK
    };
    if (domain_resolver == "")
        delete outbound.domain_resolver;

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);
    runtime_subscription.remember_outbound_metadata(state, tag_name, interface_name, outbound);
}

function add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let items = connections.interfaces(section);
    for (let i = 0; i < length(items); i++)
        add_interface_connection_outbound(config, state, section, i + 1, items[i], taken, selector_tags, urltest_candidate_tags);
}

function parse_outbound_json(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

function rewrite_json_outbound_references(outbounds, tag_map) {
    for (let outbound in array_or_empty(outbounds)) {
        if (type(outbound) != "object")
            continue;

        for (let key in [ "detour", "default" ]) {
            let reference = as_string(outbound[key] || "");
            if (reference != "" && tag_map[reference])
                outbound[key] = tag_map[reference];
        }

        if (type(outbound.outbounds) == "array") {
            let rewritten = [];
            for (let tag_name in outbound.outbounds) {
                tag_name = as_string(tag_name);
                if (tag_name != "")
                    push(rewritten, as_string(tag_map[tag_name] || tag_name));
            }
            outbound.outbounds = rewritten;
        }
    }
}

function prepare_json_connection_outbounds(section, taken) {
    let items = connections.outbound_jsons(section);
    let prepared = [];
    let outbounds = [];
    let tag_map = {};
    let legacy_tags = [];

    for (let i = 0; i < length(items); i++) {
        let outbound = parse_outbound_json(items[i]);
        if (outbound == null)
            ctx.runtime_generate_unsupported("JSON outbound is invalid");

        let display_name = trim(as_string(outbound.tag || ""));
        let legacy_tag = connection_item_tag(section[".name"], "json", i + 1);
        let base = display_name != "" ? display_name : legacy_tag;
        let tag_name = unique_tag(base, taken);
        ensure_explicit_outbound_supported(outbound, "JSON outbound", display_name != "" ? display_name : legacy_tag);
        taken[tag_name] = true;
        if (display_name != "" && !tag_map[display_name])
            tag_map[display_name] = tag_name;
        push(legacy_tags, [ legacy_tag, tag_name ]);

        outbound.tag = tag_name;
        push(outbounds, outbound);
        push(prepared, {
            outbound,
            displayName: display_name != "" ? display_name : "JSON outbound " + (i + 1)
        });
    }

    for (let entry in legacy_tags)
        if (!tag_map[entry[0]])
            tag_map[entry[0]] = entry[1];

    rewrite_json_outbound_references(outbounds, tag_map);
    return prepared;
}

function add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    for (let item in prepare_json_connection_outbounds(section, taken)) {
        let outbound = item.outbound;
        let tag_name = outbound.tag;
        push(config.outbounds, outbound);
        push(selector_tags, tag_name);
        if (urltest_leaf_candidate_outbound(outbound))
            push(urltest_candidate_tags, tag_name);
        runtime_subscription.remember_outbound_metadata(state, tag_name, item.displayName, outbound);
        runtime_subscription.remember_urltest_group(state, tag_name, item.displayName, outbound);
    }
}

function outbound_detour_tag_for_section(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";

    let detour_section = option(section, "outbound_detour_section", "");
    return detour_section == "" ? "" : outbound_tag(detour_section);
}

function apply_section_detour_to_connection_outbounds(config, start_index, detour_tag) {
    if (detour_tag == "")
        return;

    let outbounds = array_or_empty(config.outbounds);
    for (let i = int(start_index || 0); i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (type(outbound) != "object")
            continue;

        let outbound_type = lc(as_string(outbound.type || ""));
        if (outbound_type == "" ||
            outbound_type == "selector" ||
            outbound_type == "urltest" || outbound_type == "dns" ||
            outbound_type == "block")
            continue;

        if (as_string(outbound.detour || "") == "")
            outbound.detour = detour_tag;
    }
}

function add_connections_outbound(config, section, taken) {
    let section_name = section[".name"];
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let state = runtime_subscription.new_section_state(section_name);
    let cascade_start = length(array_or_empty(config.outbounds));

    add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags);
    
    apply_section_detour_to_connection_outbounds(
        config,
        cascade_start,
        outbound_detour_tag_for_section(section)
    );
    add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags);

    if (length(selector_tags) == 0)
        ctx.runtime_generate_unsupported("connection section has no usable outbounds");

    if (ctx.routes.section_needs_country_is(section)) {
        let previous_state = read_json_file(runtime_subscription.section_cache_path(section_name));
        state.outboundMetadata.countries = runtime_country.detect(
            state.servers,
            previous_state,
            option(ctx.runtime_settings(), "bootstrap_dns_server", "77.88.8.8")
        );
    }
    if (ctx.routes.section_has_direct_priority_level(section))
        state.outboundMetadata.names[runtime_constants.DIRECT_OUTBOUND_TAG] = "Direct";

    state.urltestCandidateTags = unique_string_array(urltest_candidate_tags);
    ctx.routes.add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state);
    if (!ctx.atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        ctx.runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function add_awg_endpoint(config, section) {
    let tag = outbound_tag(section[".name"]);
    let endpoint = {
        type: "wireguard",
        tag: tag,
        name: tag,
        address: list_option(section, "awg_local_address"),
        private_key: option(section, "awg_private_key", ""),
        peers: [{
            address: option(section, "awg_server_address", ""),
            port: int_option(section, "awg_server_port", "0"),
            public_key: option(section, "awg_peer_public_key", ""),
            allowed_ips: ["0.0.0.0/0", "::/0"]
        }]
    };

    let preshared_key = option(section, "awg_preshared_key", "");
    if (preshared_key != "")
        endpoint.peers[0].pre_shared_key = preshared_key;

    let mtu = int_option(section, "awg_mtu", "0");
    if (mtu > 0)
        endpoint.mtu = mtu;

    let keepalive = int_option(section, "awg_keepalive", "0");
    if (keepalive > 0)
        endpoint.peers[0].persistent_keepalive_interval = keepalive;

    // AmneziaWG obfuscation parameters
    let amnezia = {
        jc: int_option(section, "awg_jc", "120"),
        jmin: int_option(section, "awg_jmin", "23"),
        jmax: int_option(section, "awg_jmax", "911"),
        s1: int_option(section, "awg_s1", "0"),
        s2: int_option(section, "awg_s2", "0"),
        h1: int_option(section, "awg_h1", "1"),
        h2: int_option(section, "awg_h2", "2"),
        h3: int_option(section, "awg_h3", "3"),
        h4: int_option(section, "awg_h4", "4"),
        s3: int_option(section, "awg_s3", "0"),
        s4: int_option(section, "awg_s4", "0")
    };
    let i1 = uci_bin_to_hex(option(section, "awg_i1", ""));
    let i2 = uci_bin_to_hex(option(section, "awg_i2", ""));
    let i3 = uci_bin_to_hex(option(section, "awg_i3", ""));
    let i4 = uci_bin_to_hex(option(section, "awg_i4", ""));
    let i5 = uci_bin_to_hex(option(section, "awg_i5", ""));
    let is_lx = trim(fs.readfile("/etc/tachyon/sing-box-variant") || "") == "lx";

    if (is_lx) {
        endpoint.jc = amnezia.jc;
        endpoint.jmin = amnezia.jmin;
        endpoint.jmax = amnezia.jmax;
        endpoint.s1 = amnezia.s1;
        endpoint.s2 = amnezia.s2;
        endpoint.h1 = amnezia.h1;
        endpoint.h2 = amnezia.h2;
        endpoint.h3 = amnezia.h3;
        endpoint.h4 = amnezia.h4;
        endpoint.s3 = amnezia.s3;
        endpoint.s4 = amnezia.s4;
        if (i1 != "") endpoint.i1 = i1;
        if (i2 != "") endpoint.i2 = i2;
        if (i3 != "" && i3 != "0") endpoint.i3 = i3;
        if (i4 != "" && i4 != "0") endpoint.i4 = i4;
        if (i5 != "" && i5 != "0") endpoint.i5 = i5;
    } else {
        if (i1 != "") amnezia.i1 = i1;
        if (i2 != "") amnezia.i2 = i2;
        if (i3 != "" && i3 != "0") amnezia.i3 = i3;
        if (i4 != "" && i4 != "0") amnezia.i4 = i4;
        if (i5 != "" && i5 != "0") amnezia.i5 = i5;
        endpoint.amnezia = amnezia;
    }

    let detour = option(section, "awg_detour", "");
    if (detour != "") {
        endpoint.detour = outbound_tag(detour);
    }

    push(config.endpoints, endpoint);
}

function add_warp_endpoint(config, section) {
    let tag = outbound_tag(section[".name"]);
    let account_id = option(section, "warp_account_id", "");
    let access_token = replace(option(section, "warp_access_token", ""), /^ +| +$/g, "");
    let private_key = option(section, "warp_private_key", "");

    if (private_key == "")
        ctx.runtime_generate_unsupported("WARP section '" + section[".name"] + "' missing warp_private_key");
    if (account_id == "")
        ctx.runtime_generate_unsupported("WARP section '" + section[".name"] + "' missing warp_account_id");

    let profile = { id: account_id, private_key };
    if (access_token != "") {
        profile.auth_token = access_token;
    }

    let detour = option(section, "warp_detour", "");
    let endpoint = {
        type: "warp",
        tag,
        name: tag,
        profile
    };

    if (detour != "") {
        endpoint.detour = outbound_tag(detour);
    }

    push(config.endpoints, endpoint);
}

function add_anytls_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let outbound = {
        type: "anytls",
        tag,
        server: option(section, "anytls_server", ""),
        server_port: int_option(section, "anytls_server_port", "0"),
        password: option(section, "anytls_password", "")
    };
    let sni = option(section, "anytls_sni", "");
    let insecure = internal_flag(option(section, "anytls_insecure", "0"));
    outbound.tls = { enabled: true };
    if (sni != "") outbound.tls.server_name = sni;
    if (insecure)   outbound.tls.insecure = true;
    push(config.outbounds, outbound);
}

function add_snell_outbound(config, section) {
    push(config.outbounds, {
        type: "snell",
        tag: outbound_tag(section[".name"]),
        server: option(section, "snell_server", ""),
        server_port: int_option(section, "snell_server_port", "0"),
        psk: option(section, "snell_psk", ""),
        version: int_option(section, "snell_version", "4")
    });
}

function add_mieru_outbound(config, section) {
    push(config.outbounds, {
        type: "mieru",
        tag: outbound_tag(section[".name"]),
        server: option(section, "mieru_server", ""),
        server_port: int_option(section, "mieru_server_port", "0"),
        transport: option(section, "mieru_transport", "TCP"),
        username: option(section, "mieru_username", ""),
        password: option(section, "mieru_password", "")
    });
}

function add_sudoku_outbound(config, section) {
    let outbound = {
        type: "sudoku",
        tag: outbound_tag(section[".name"]),
        server: option(section, "sudoku_server", ""),
        server_port: int_option(section, "sudoku_server_port", "0"),
        key: option(section, "sudoku_key", "")
    };
    let method = option(section, "sudoku_aead_method", "");
    if (method != "") outbound.aead_method = method;
    push(config.outbounds, outbound);
}

function add_masque_endpoint(config, section) {
    let tag = outbound_tag(section[".name"]);
    let private_key = option(section, "masque_private_key", "");
    let account_id  = option(section, "masque_account_id", "");
    let access_token = option(section, "masque_access_token", "");
    if (private_key == "")
        ctx.runtime_generate_unsupported("MASQUE section '" + section[".name"] + "' missing masque_private_key");
    if (account_id == "")
        ctx.runtime_generate_unsupported("MASQUE section '" + section[".name"] + "' missing masque_account_id");
    if (access_token == "")
        ctx.runtime_generate_unsupported("MASQUE section '" + section[".name"] + "' missing masque_access_token");
    push(config.endpoints, {
        type: "masque",
        tag,
        name: tag,
        profiles: [{ id: account_id, auth_token: access_token, private_key }]
    });
}

function add_openvpn_endpoint(config, section) {
    let tag = outbound_tag(section[".name"]);
    let endpoint = {
        type: "openvpn",
        tag,
        name: tag,
        system: true,
        servers: [{
            server: option(section, "openvpn_server", ""),
            server_port: int_option(section, "openvpn_server_port", "1194")
        }],
        proto: option(section, "openvpn_proto", "udp")
    };
    let cipher = option(section, "openvpn_cipher", "");
    if (cipher != "") endpoint.cipher = cipher;
    let auth = option(section, "openvpn_auth", "");
    if (auth != "") endpoint.auth = auth;
    let ca   = option(section, "openvpn_ca", "");
    if (ca != "")   endpoint.ca = ca;
    let cert = option(section, "openvpn_cert", "");
    if (cert != "") endpoint.cert = cert;
    let key  = option(section, "openvpn_key", "");
    if (key != "")  endpoint.key = key;
    let tls_auth = option(section, "openvpn_tls_auth", "");
    if (tls_auth != "") endpoint.tls_auth = tls_auth;
    push(config.endpoints, endpoint);
}

function enabled_action_index(sections, target_section, action_name) {
    let index = 0;
    for (let section in sections) {
        if (option(section, "action", "") != action_name)
            continue;
        index++;
        if (section[".name"] == target_section[".name"])
            return index;
    }
    return 0;
}

function add_zapret_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret");
    if (index <= 0)
        ctx.runtime_generate_unsupported("unable to resolve Zapret index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET_ROUTE_MARK_BASE + index
    });
}

function add_zapret2_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "zapret2");
    if (index <= 0)
        ctx.runtime_generate_unsupported("unable to resolve Zapret2 index for " + section[".name"]);
    push(config.outbounds, {
        type: "direct",
        tag: outbound_tag(section[".name"]),
        routing_mark: runtime_constants.ZAPRET2_ROUTE_MARK_BASE + index
    });
}

function add_byedpi_outbound(config, section, sections) {
    let index = enabled_action_index(sections, section, "byedpi");
    if (index <= 0)
        ctx.runtime_generate_unsupported("unable to resolve ByeDPI index for " + section[".name"]);
    push(config.outbounds, {
        type: "socks",
        tag: outbound_tag(section[".name"]),
        server: runtime_constants.BYEDPI_LISTEN_ADDRESS,
        server_port: runtime_constants.BYEDPI_PORT_BASE + index - 1,
        version: "5"
    });
}

return {
    init,
    reserved_runtime_tag_set,
    assert_unique_outbound_tags,
    uci_bin_to_hex,
    unique_string_array,
    manual_socks_outbound,
    manual_shadowsocks_outbound,
    manual_vless_outbound,
    manual_vmess_outbound,
    manual_trojan_outbound,
    manual_hysteria2_outbound,
    manual_link_outbound,
    add_manual_proxy_link,
    add_connection_manual_links,
    add_connection_subscriptions,
    add_interface_connection_outbound,
    add_connection_interfaces,
    parse_outbound_json,
    rewrite_json_outbound_references,
    prepare_json_connection_outbounds,
    add_connection_json_outbounds,
    add_connections_outbound,
    add_awg_endpoint,
    add_warp_endpoint,
    add_anytls_outbound,
    add_snell_outbound,
    add_mieru_outbound,
    add_sudoku_outbound,
    add_masque_endpoint,
    add_openvpn_endpoint,
    add_zapret_outbound,
    add_zapret2_outbound,
    add_byedpi_outbound
};
