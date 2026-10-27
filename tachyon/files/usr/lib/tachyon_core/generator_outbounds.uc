#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let runtime_constants = require("tachyon_core.constants");
let variant_state = require("tachyon_core.variant_state");
let runtime_subscription = require("tachyon_core.subscription");
let runtime_country = require("tachyon_core.country");
let runtime_dns = require("tachyon_core.dns");
let core_profile = require("tachyon_core.core_profile");
let runtime_url = require("core.url");
let subscription_share_link = require("subscription.share_link");
let subscription_parser = require("subscription.parser");
let connections = require("config.connections");
let subscription_wireguard = require("subscription.wireguard");
let subscription_amnezia = require("subscription.amnezia_config");
let exec = require("core.exec");
let core_ip = require("core.ip");

let as_string = common.as_string;
let option = common.option;
let list_option = common.list_option;
let bool_option = common.bool_option;
let int_option = common.int_option;
let int_or_range_option = common.int_or_range_option;
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

function is_true(value) {
    if (value == null || value == "")
        return false;
    let normalized = lc(as_string(value));
    return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on";
}

function uci_bin_to_hex(val) {
    if (val == null || val == "") return "";
    let s = as_string(val);
    s = replace(s, /^<b\s*/i, "");
    s = replace(s, /^0x/i, "");
    s = replace(s, />$/, "");
    s = replace(s, /\s+/g, "");

    if (match(s, /^[0-9a-fA-F]+$/)) {
        return lc(s);
    }

    let hex = "";
    for (let i = 0; i < length(val); i++) {
        let code = ord(val, i);
        hex += sprintf("%02x", code);
    }
    return hex;
}

function internal_flag(value) {
    return value === true || value == 1 || value == "1" || value == "true" || value == "yes";
}

// AWG CPS decoy values (awg_i1..awg_i5, awg_j1..awg_j3): normalized to the
// AmneziaWG 2.0 tag-chain format by common.awg_tag_chain — classic plain-hex
// payloads become "<b 0x..>", existing tag chains pass through verbatim.
function awg_cps_option(section, key) {
    return common.awg_tag_chain(option(section, key, ""));
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

function is_dummy_outbound_server(server, port) {
    server = trim(lc(as_string(server)));
    if (server == "" || server == "0.0.0.0" || server == "::" ||
        substr(server, 0, 8) == "0.0.0.0:")
        return true;
    if (port != null && int(port) == 0)
        return true;
    return false;
}

function supported_subscription_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type);
    if (t == "wireguard") {
        let peer = array_or_empty(outbound.peers)[0];
        return type(peer) == "object" && !is_dummy_outbound_server(peer.address, peer.port) &&
            as_string(outbound.private_key) != "" && as_string(peer.public_key) != "" &&
            length(array_or_empty(outbound.address)) > 0;
    }
    if (subscription_group_outbound(outbound))
        return true;
    if (t == "direct" || t == "selector" || t == "urltest" || t == "dns" || t == "block")
        return false;
    if (t == "desync" || t == "chain" || t == "tor" || t == "tailscale")
        return true;
    if (t == "fptn" && as_string(outbound.token || "") != "")
        return true;
    let is_proto = (t == "vless" || t == "vmess" || t == "trojan" || t == "shadowsocks" ||
        t == "socks" || t == "http" || t == "hysteria2" || t == "tuic" ||
        t == "fptn" || t == "anytls" || t == "naive" || t == "mieru" ||
        t == "snell" || t == "masque" || t == "sudoku" || t == "openvpn" ||
        t == "openconnect" || t == "tewfai" || t == "trusttunnel" ||
        t == "mtproto" || t == "shadowtls" || t == "ssh");
    if (!is_proto)
        return false;
    if (t == "masque" && type(outbound.profile) == "object")
        return true;
    if (is_dummy_outbound_server(outbound.server, outbound.server_port))
        return false;
    return true;
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
    if (as_string(copy.type || "") == "hysteria2" && (copy.server_port == null || copy.server_port == 0) && copy.server_ports != null) {
        let raw = type(copy.server_ports) == "array" ? copy.server_ports[0] : copy.server_ports;
        let parts = split(as_string(raw), ":");
        let p = int(parts[0], 10);
        if (p > 0)
            copy.server_port = p;
    }
    if (as_string(copy.type || "") == "tuic" &&
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
    if (t == "selector" || t == "urltest" || t == "dns" || t == "block" || t == "desync")
        return false;
    if (t == "direct" && outbound.routing_mark != null && as_string(outbound.bind_interface || "") == "")
        return false;
    if (t == "socks" && as_string(outbound.server || "") == "127.0.0.1" && int(outbound.server_port || 0) >= 1080 && int(outbound.server_port || 0) < 1180)
        return false;
    if (t == "wireguard") {
        let peer = array_or_empty(outbound.peers)[0];
        if (type(peer) == "object")
            return !is_dummy_outbound_server(peer.address, peer.port);
        return !is_dummy_outbound_server(outbound.server, outbound.server_port);
    }
    if (t == "warp") {
        return !is_dummy_outbound_server(outbound.endpoint || outbound.server, outbound.server_port);
    }
    if (is_dummy_outbound_server(outbound.server, outbound.server_port))
        return false;
    return true;
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

// Which TLS field this build accepts for a pin. The answer comes from the
// capability model in tachyon_core/runtime.uc rather than from a second copy of the
// rules: two copies of "which field does this core take" is exactly how the
// generator and the validator ended up disagreeing about the same binary, and a
// disagreement here is silent - the pin is simply dropped from the config.
//
// SB_VERSION_OVERRIDE still wins, because the whole point of it is to generate a
// config for a build that is not the one installed.
function certificate_pin_field() {
    let override = trim(as_string(getenv("SB_VERSION_OVERRIDE") || ""));
    let version = override != ""
        ? override
        : variant_state.read_version_state();
    let variant = variant_state.read_variant_marker();

    // With no state file to go on, let the model look at the installed binary
    // rather than guessing from an empty version.
    return core_profile.pin_field(version, variant);
}

function apply_link_tls(outbound, scheme, query) {
    query = object_or_empty(query);
    let security = as_string(query.security || "");
    if (security == "" && (scheme == "hysteria2" || scheme == "hy2" || scheme == "tuic"))
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
    let certificate_pin = common.certificate_pin_base64(as_string(query.pcs || query.pinSHA256 || ""));
    if (certificate_pin != "") {
        let pin_field = certificate_pin_field();
        if (pin_field != "")
            tls[pin_field] = [ certificate_pin ];
        else
            warn("this sing-box build has no usable TLS pin field; certificate pin from the link ignored\n");
    }

    let alpn = tls_alpn_array(query.alpn, query.type);
    if (length(alpn) > 0)
        tls.alpn = alpn;

    if (scheme != "hysteria2" && scheme != "hy2" && scheme != "tuic" && as_string(query.fp || "") != "") {
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
        // Only carry the flag when the link actually asks for it. Injecting it
        // unconditionally broke two things: sing-box-lx and stock sing-box reject
        // the field outright, and a server doing plain X25519 cannot complete a
        // handshake that demands the hybrid exchange.
        // Three spellings of the same flag are in the wild: the sing-box
        // snake_case one, the camelCase one some panels emit, and the
        // kebab-case one a share link carries. Priority order is kept: the
        // first one that is present wins, and an explicit false is never
        // turned into true by a later spelling.
        let mlkem_preference = query.support_x25519mlkem768;
        if (mlkem_preference == null)
            mlkem_preference = query.supportX25519MLKEM768;
        if (mlkem_preference == null)
            mlkem_preference = query["support-x25519mlkem768"];
        if (mlkem_preference != null)
            tls.reality.support_x25519mlkem768 = bool_query(mlkem_preference);
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
        optional_query_string(result, "service_name", query.serviceName || query.service_name);
    }
    else if (transport == "httpupgrade") {
        optional_query_string(result, "path", query.path);
        optional_query_string(result, "host", query.host);
    }
    else if (transport == "xhttp") {
        // xHTTP settings travel in `extra` (JSON) on real share links: xmux,
        // padding, sc* limits. The subscription parser already knows all of
        // that mapping — hand the query over to it instead of keeping a second,
        // dumber copy that silently drops everything extra carries.
        let built = subscription_parser.add_transport({ query: object_or_empty(query) });
        if (type(built) != "object")
            return;
        result = built;
    }
    else {
        warn("unknown manual proxy link transport '", transport, "' ignored\n");
        return;
    }

    outbound.transport = result;
}

function manual_http_outbound(link, tag_name) {
    let scheme = url_scheme(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    let path = url_path(link);
    if (host == "" || port == null || (path != "" && path != "/") || index(link, "?") >= 0)
        ctx.runtime_generate_unsupported("manual HTTP proxy link is invalid");

    let outbound = {
        type: "http",
        tag: tag_name,
        server: host,
        server_port: port
    };
    let userinfo = url_userinfo(link);
    if (userinfo != "") {
        let colon = index(userinfo, ":");
        outbound.username = colon >= 0 ? substr(userinfo, 0, colon) : userinfo;
        if (colon >= 0)
            outbound.password = substr(userinfo, colon + 1);
    }
    if (scheme == "https")
        outbound.tls = { enabled: true };
    return outbound;
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
    if (as_string(query.uot || query.udp_over_tcp || query["udp-over-tcp"] || "") != "")
        outbound.udp_over_tcp = true;
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
    let packet_encoding = lc(trim(as_string(query.packetEncoding || query.packet_encoding || query["packet-encoding"] || query.packetencoding || "")));
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

    let packet_encoding = lc(trim(as_string(vmess.packetEncoding || vmess["packet-encoding"] || vmess.packet_encoding || vmess.packetencoding || "")));
    if (packet_encoding == "xudp" || packet_encoding == "packetaddr")
        outbound.packet_encoding = packet_encoding;

    let network = lc(vmess_json_value(vmess.net));
    if (vmess.tls === true || vmess.tls == "tls" || vmess.tls == "true") {
        let tls = { enabled: true };
        optional_query_string(tls, "server_name", vmess_json_value(vmess.sni));
        if (bool_query(vmess_json_value(vmess.allowInsecure || vmess.insecure)))
            tls.insecure = true;
        let certificate_pin = common.certificate_pin_base64(vmess_json_value(vmess.pcs));
        if (certificate_pin != "") {
            let pin_field = certificate_pin_field();
            if (pin_field != "")
                tls[pin_field] = [ certificate_pin ];
        }
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

function manual_tuic_outbound(link, tag_name) {
    let query = url_query_params(link);
    let host = url_host(link);
    let port = parse_port(url_port(link));
    let userinfo = url_userinfo(link);
    if (host == "" || port == null || userinfo == "")
        ctx.runtime_generate_unsupported("manual TUIC proxy link is invalid");

    let uuid = "";
    let password = "";
    let colon_index = index(userinfo, ":");
    if (colon_index >= 0) {
        uuid = substr(userinfo, 0, colon_index);
        password = substr(userinfo, colon_index + 1);
    } else {
        uuid = userinfo;
    }

    if (uuid == "")
        ctx.runtime_generate_unsupported("manual TUIC proxy link is missing UUID");

    let outbound = {
        type: "tuic",
        tag: tag_name,
        server: host,
        server_port: port,
        uuid: uuid
    };
    if (password != "")
        outbound.password = password;

    let cc = as_string(query.congestion_control || "");
    if (cc != "")
        outbound.congestion_control = cc;
    else
        outbound.congestion_control = "bbr";

    let udp_mode = as_string(query.udp_relay_mode || "");
    if (udp_mode != "")
        outbound.udp_relay_mode = udp_mode;

    if (is_true(query.zero_rtt_handshake))
        outbound.zero_rtt_handshake = true;

    let hb = as_string(query.heartbeat || "");
    if (hb != "")
        outbound.heartbeat = hb;

    apply_link_tls(outbound, url_scheme(link), query);
    return outbound;
}

function ensure_imported_vpn_lx() {
    let variant = variant_state.read_variant_marker();
    let version = variant_state.read_version_state();
    if (variant != "lx" && variant != "tachyon-core" && index(version, "-lx") < 0 && index(version, "-tachyon.") < 0 && match(version, /^v?0\.[0-9]+\./) == null)
        ctx.runtime_generate_unsupported("vpn:// import is available only with sing-box-lx or tachyon-core");
}

// A desync outbound exists only in tachyon-core, and only from 0.1.7 on. On
// any other core the emitted config would be rejected outright, so refuse with
// a clear error instead of shipping a broken config.
function ensure_desync_outbound_supported() {
    let version = variant_state.read_version_state();
    let variant = variant_state.read_variant_marker();
    if (core_profile.supports_desync(version, variant) === true)
        return;
    ctx.runtime_generate_unsupported("Native Desync requires tachyon-core 0.1.7 or newer (installed: " + as_string(version) + ")");
}

// An fptn outbound exists only in tachyon-core's protocol list: on every other
// core the emitted config would be rejected outright, so refuse with a clear
// error instead of shipping a broken config. fptn_transport_mode() is the one
// resolver that already knows the answer — native exists on tachyon-core only.
function ensure_fptn_outbound_supported() {
    if (connections && connections.fptn_transport_mode() != "native")
        ctx.runtime_generate_unsupported("fptn:// links require tachyon-core; this core cannot dial FPTN");
}

function add_imported_wireguard_endpoint(config, endpoint) {
    ensure_imported_vpn_lx();
    if (type(endpoint) == "object") {
        if (type(endpoint.amnezia) == "object") {
            for (let k, v in endpoint.amnezia) {
                if (endpoint[k] == null)
                    endpoint[k] = v;
            }
            delete endpoint.amnezia;
        }
        if (endpoint.address != null)
            endpoint.address = core_ip.normalize_to_cidrs(endpoint.address);
        if (type(endpoint.peers) == "array") {
            for (let peer in endpoint.peers) {
                if (type(peer) == "object" && peer.allowed_ips != null)
                    peer.allowed_ips = core_ip.normalize_to_cidrs(peer.allowed_ips);
            }
        }
    }
    push(config.endpoints, endpoint);
}

// Validate a decoded payload exactly the way core fptn::parse_token does —
// same field errors, same ranges — so the backend and the core's own token
// expansion can never disagree about which token is usable. Returns the
// normalized payload or null.
function fptn_token_payload(payload) {
    if (type(payload) != "object")
        return null;
    // ucode numbers are "int"/"double", there is no "number" type — and both
    // fields are integers in fptn::parse_token too.
    if (payload.version != null && type(payload.version) != "int")
        return null;
    if (payload.service_name != null && type(payload.service_name) != "string")
        return null;
    if (type(payload.username) != "string" || payload.username == "")
        return null;
    if (type(payload.password) != "string" || payload.password == "")
        return null;
    if (type(payload.servers) != "array" || length(payload.servers) == 0)
        return null;

    let servers = [];
    let seen = {};
    for (let entry in payload.servers) {
        if (type(entry) != "object")
            return null;
        if (type(entry.name) != "string" || entry.name == "")
            return null;
        if (seen[entry.name])
            return null;
        if (type(entry.host) != "string" || entry.host == "")
            return null;
        if (type(entry.port) != "int" || entry.port < 1 || entry.port > 65535)
            return null;
        let fingerprint = "";
        if (entry.md5_fingerprint != null) {
            if (type(entry.md5_fingerprint) != "string")
                return null;
            fingerprint = entry.md5_fingerprint;
            if (fingerprint != "" && !match(fingerprint, /^[0-9a-fA-F]{32}$/))
                return null;
        }
        seen[entry.name] = true;
        push(servers, {
            name: entry.name,
            host: entry.host,
            port: int(entry.port),
            md5_fingerprint: fingerprint
        });
    }

    return {
        service_name: as_string(payload.service_name || ""),
        username: payload.username,
        password: payload.password,
        servers
    };
}

// fptnb: is brotli, which ucode has not got — the core CLI decodes it for us
// (`tachyon-core fptn decode <token>`). Returns null when the binary is
// missing or refuses, and the caller falls back to the raw-token form.
function fptn_token_decode_via_core(token) {
    let binary = getenv("SB_PREFLIGHT_BINARY") || getenv("TACHYON_SING_BOX_BIN") || "/usr/bin/tachyon-core";
    if (fs.stat(binary) == null)
        return null;
    let result = exec.run({ argv: [ binary, "fptn", "decode", token ], timeout: 15 });
    if (result.status != 0)
        return null;
    try {
        return json(result.output);
    }
    catch (e) {
        return null;
    }
}

// Decode an access token into its payload, or null for anything undecodable
// (bad prefix, bad base64, invalid payload). fptn: is base64+JSON inline;
// fptnb: goes through the core.
function fptn_token_decode(token) {
    token = trim(as_string(token));
    let hash_idx = index(token, "#");
    if (hash_idx >= 0)
        token = substr(token, 0, hash_idx);

    let body = null;
    let compressed = false;
    if (substr(token, 0, 8) == "fptnb://") {
        body = substr(token, 8);
        compressed = true;
    } else if (substr(token, 0, 6) == "fptnb:") {
        body = substr(token, 6);
        if (substr(body, 0, 2) == "//")
            body = substr(body, 2);
        compressed = true;
    } else if (substr(token, 0, 7) == "fptnb//") {
        body = substr(token, 7);
        compressed = true;
    } else if (substr(token, 0, 7) == "fptn://") {
        body = substr(token, 7);
    } else if (substr(token, 0, 5) == "fptn:") {
        body = substr(token, 5);
        if (substr(body, 0, 2) == "//")
            body = substr(body, 2);
    } else {
        return null;
    }

    let payload = null;
    if (compressed) {
        payload = fptn_token_decode_via_core("fptnb:" + body);
    } else {
        let raw = base64_decode_value(body);
        if (raw == null)
            return null;
        try {
            payload = json(raw);
        }
        catch (e) {
            return null;
        }
    }
    return fptn_token_payload(payload);
}

function manual_link_outbound(link, tag_name, display_info) {
    let scheme = url_scheme(link);
    // Preserve the base64 payload; do not URL-decode the complete link first.
    if (scheme == "vpn") {
        ensure_imported_vpn_lx();
        let endpoint = subscription_wireguard.from_vpn(link);
        if (endpoint == null)
            ctx.runtime_generate_unsupported("invalid vpn:// export: expected a valid WG/AWG .conf or Amnezia WG/AWG container");
        if (type(display_info) == "object")
            display_info.name = subscription_outbound_display_name(endpoint);
        return copy_subscription_outbound(endpoint, tag_name);
    }
    if (scheme == "fptn" || scheme == "fptnb" || index(link, "fptn:") == 0 || index(link, "fptnb:") == 0) {
        if (type(display_info) == "object")
            display_info.name = tag_name;
        return {
            type: "fptn",
            tag: tag_name,
            token: url_strip_fragment_value(link)
        };
    }
    if (scheme == "vmess")
        return manual_vmess_outbound(link, tag_name);

    if (scheme == "anytls" || scheme == "naive+https" || scheme == "naive+quic" ||
        scheme == "snell" || scheme == "mieru" || scheme == "mierus" ||
        scheme == "tg" || scheme == "mtproto" || scheme == "shadowtls" ||
        scheme == "tewfai" || scheme == "trusttunnel" || scheme == "masque" ||
        scheme == "openconnect" || scheme == "anyconnect" ||
        ((scheme == "http" || scheme == "https") && (index(link, "://t.me/proxy?") >= 0 || index(link, "://telegram.me/proxy?") >= 0))) {
        let parsed = subscription_parser.parse_share_link(link);
        if (parsed == null)
            ctx.runtime_generate_unsupported("invalid manual proxy link for scheme " + scheme);
        if (type(display_info) == "object")
            display_info.name = subscription_outbound_display_name(parsed);
        return copy_subscription_outbound(parsed, tag_name);
    }

    // Strip the fragment, nothing else. Decoding the whole link up front used
    // to run before the query was split, so a percent-encoded `&` (extra=...,
    // plugin=..., any JSON blob) turned into a real one and cut the link in
    // half. Every parser below decodes what it needs itself — userinfo()
    // and query_params() decode per field.
    link = url_strip_fragment_value(link);
    scheme = url_scheme(link);
    if (scheme == "http" || scheme == "https")
        return manual_http_outbound(link, tag_name);
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
    if (scheme == "tuic")
        return manual_tuic_outbound(link, tag_name);
    ctx.runtime_generate_unsupported("manual proxy link scheme is not supported by sing-box config generation yet");
}

// fptn:// is a share link whose scheme is not a standard URI scheme the
// generic parser knows, so recognize it exactly the way manual_link_outbound
// does — both the //-forms and the bare fptn:/fptnb: forms.
function is_fptn_link(link) {
    let scheme = url_scheme(link);
    return scheme == "fptn" || scheme == "fptnb" ||
        index(link, "fptn:") == 0 || index(link, "fptnb:") == 0;
}

// An fptn: link in a connection section is an access token carrying a whole
// server list, not one server. Expand it here the same way the fptn action
// does, so the dashboard lists the servers instead of one opaque card. Falls
// back to false for anything undecodable, and the caller then keeps the raw
// token for the core to expand itself.
function add_fptn_manual_members(config, state, section_name, tag_name, link, taken, selector_tags, urltest_candidate_tags, source_id) {
    if (!is_fptn_link(link))
        return false;
    ensure_fptn_outbound_supported();
    let decoded = fptn_token_decode(link);
    if (decoded == null)
        return false;

    let src_tag = as_string(source_id || "") != "" ? as_string(source_id) : "manual";
    let src_obj = (connections && connections.outbound_source_section && src_tag != "manual")
        ? connections.outbound_source_section(src_tag)
        : null;
    let fptn_sni = src_obj != null ? trim(option(src_obj, "sni", "")) : "";
    let fptn_bypass = src_obj != null ? trim(option(src_obj, "bypass_method", "")) : "";
    let fptn_pref = src_obj != null ? lc(trim(option(src_obj, "preferred_server", ""))) : "";
    let ordered_servers = [];
    for (let s in decoded.servers) {
        if (fptn_pref != "" && (lc(as_string(s.name || "")) == fptn_pref || lc(as_string(s.host || "")) == fptn_pref))
            push(ordered_servers, s);
    }
    for (let s in decoded.servers) {
        if (fptn_pref == "" || (lc(as_string(s.name || "")) != fptn_pref && lc(as_string(s.host || "")) != fptn_pref))
            push(ordered_servers, s);
    }
    for (let server in ordered_servers) {
        let member_tag = tag_name + "/" + server.name;
        if (taken[member_tag])
            member_tag = unique_tag(member_tag, taken);
        taken[member_tag] = true;

        let member = {
            type: "fptn",
            tag: member_tag,
            server: server.host,
            server_port: server.port,
            username: decoded.username,
            password: decoded.password
        };
        if (server.md5_fingerprint != "")
            member.md5_fingerprint = server.md5_fingerprint;
        if (fptn_sni != "")
            member.sni = fptn_sni;
        if (fptn_bypass != "")
            member.bypass_method = fptn_bypass;

        push(config.outbounds, member);
        push(selector_tags, member_tag);
        push(urltest_candidate_tags, member_tag);
        state.links[member_tag] = as_string(link);
        runtime_subscription.remember_outbound_metadata(state, member_tag, server.name, member);
        state.outboundMetadata.sources[member_tag] = src_tag;
    }
    return true;
}

function add_manual_proxy_link(config, state, section_name, manual_index, link, taken, selector_tags, urltest_candidate_tags, source_id) {
    let tag_name = outbound_tag(section_name + "-" + manual_index);
    if (taken[tag_name])
        tag_name = unique_tag(tag_name, taken);
    taken[tag_name] = true;

    let src_tag = as_string(source_id || "") != "" ? as_string(source_id) : "manual";
    if (add_fptn_manual_members(config, state, section_name, tag_name, link, taken, selector_tags, urltest_candidate_tags, src_tag))
        return tag_name;

    let display_info = {};
    let outbound = manual_link_outbound(link, tag_name, display_info);
    let display_name = url_fragment(link);
    if (display_name == "")
        display_name = as_string(display_info.name || tag_name);
    ensure_explicit_outbound_supported(outbound, "manual outbound", display_name);
    if (outbound.type == "wireguard")
        add_imported_wireguard_endpoint(config, outbound);
    else if (outbound.type == "shadowtls") {
        let stls_tag = unique_tag(tag_name + "-stls", taken);
        taken[stls_tag] = true;
        let stls_outbound = {};
        for (let k, v in outbound)
            stls_outbound[k] = v;
        stls_outbound.tag = stls_tag;
        push(config.outbounds, stls_outbound);
        outbound = {
            type: "shadowsocks",
            tag: tag_name,
            server: stls_outbound.server,
            server_port: stls_outbound.server_port,
            method: "aes-128-gcm",
            password: as_string(stls_outbound.password || ""),
            detour: stls_tag
        };
        push(config.outbounds, outbound);
    } else
        push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    push(urltest_candidate_tags, tag_name);

    state.links[tag_name] = as_string(link);
    runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
    state.outboundMetadata.sources[tag_name] = src_tag;
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
        let src_id = (connections && connections.source_id_for_manual_item)
            ? connections.source_id_for_manual_item(section, link)
            : "";
        add_manual_proxy_link(
            config,
            state,
            section_name,
            i + 1,
            link,
            taken,
            selector_tags,
            urltest_candidate_tags,
            src_id
        );
    }
}

function is_extended_variant_detected() {
    let sb_variant_val = variant_state.read_variant_marker();
    if (sb_variant_val == "extended" || sb_variant_val == "extended-compressed")
        return true;
    let sb_version_val = variant_state.read_version_state();
    return index(sb_version_val, "extended") >= 0;
}

function add_connection_text_urltest(config, state, section, taken, selector_tags, urltest_candidate_tags, index_offset) {
    let section_name = section[".name"];
    if (index(connections.urltests(section), "urltest") >= 0)
        return "";

    let text_links = connections.urltest_text_links(section);
    if (length(text_links) == 0)
        return "";

    let text_tags = [];
    for (let i = 0; i < length(text_links); i++)
        add_manual_proxy_link(
            config,
            state,
            section_name,
            int(index_offset || 0) + i + 1,
            text_links[i],
            taken,
            selector_tags,
            text_tags
        );

    if (length(text_tags) == 0)
        return "";

    let urltest_tag = ctx.routes.urltest_outbound_tag(section_name, "urltest");
    let url = connections.urltest_testing_url(section, "urltest");
    let interval = connections.urltest_check_interval(section, "urltest");
    let tolerance = int(connections.urltest_tolerance(section, "urltest"), 10);
    let idle_timeout = ctx.routes.urltest_idle_timeout(section, "urltest");
    let interrupt = connections.urltest_interrupt_exist_connections(section, "urltest");
    let outbound = {
        type: "urltest",
        tag: urltest_tag,
        outbounds: text_tags,
        url,
        interval,
        tolerance,
        interrupt_exist_connections: interrupt
    };
    if (idle_timeout != "")
        outbound.idle_timeout = idle_timeout;
    runtime_subscription.remember_outbound_metadata(state, urltest_tag, "Fastest", outbound);
    runtime_subscription.remember_urltest_group_config(state, urltest_tag, {
        displayName: "Fastest",
        outbounds: text_tags,
        url,
        interval,
        tolerance,
        idle_timeout: outbound.idle_timeout || "",
        interrupt_exist_connections: interrupt
    });
    push(config.outbounds, outbound);
    return urltest_tag;
}

function subscription_keyword_fold(value) {
    value = as_string(value);
    let bytes = [];
    let i = 0;
    while (i < length(value)) {
        let b = ord(substr(value, i, 1));
        if (b >= 65 && b <= 90) {
            push(bytes, b + 32);
            i += 1;
        }
        else if (b == 0xD0 && i + 1 < length(value)) {
            let b2 = ord(substr(value, i + 1, 1));
            if (b2 >= 0x90 && b2 <= 0x9F)
                push(bytes, 0xD0, b2 + 0x20);
            else if (b2 >= 0xA0 && b2 <= 0xAF)
                push(bytes, 0xD1, b2 - 0x20);
            else if (b2 == 0x81)
                push(bytes, 0xD1, 0x91);
            else
                push(bytes, b, b2);
            i += 2;
        }
        else {
            push(bytes, b);
            i += 1;
        }
    }

    let result = "";
    for (let byte in bytes)
        result += chr(byte);
    return result;
}

function subscription_keyword_filter(section, source_entry) {
    let include = [];
    let exclude = [];
    for (let kw in list_option(section, "subscription_filter_include_keywords"))
        push(include, kw);
    for (let kw in list_option(section, "subscription_filter_exclude_keywords"))
        push(exclude, kw);
    if (source_entry != null && source_entry != "" && connections && connections.subscription_url_settings) {
        let src_settings = connections.subscription_url_settings(section, source_entry);
        if (src_settings != null && type(src_settings) == "object") {
            for (let kw in list_option(src_settings, "subscription_filter_include_keywords"))
                push(include, kw);
            for (let kw in list_option(src_settings, "subscription_filter_exclude_keywords"))
                push(exclude, kw);
        }
    }
    if (length(include) == 0 && length(exclude) == 0)
        return null;

    let folded_include = [];
    for (let keyword in include) {
        keyword = as_string(keyword);
        if (keyword != "")
            push(folded_include, subscription_keyword_fold(keyword));
    }
    let folded_exclude = [];
    for (let keyword in exclude) {
        keyword = as_string(keyword);
        if (keyword != "")
            push(folded_exclude, subscription_keyword_fold(keyword));
    }
    if (length(folded_include) == 0 && length(folded_exclude) == 0)
        return null;

    return {
        include: folded_include,
        exclude: folded_exclude
    };
}

function subscription_keyword_name_passes(filter, name) {
    let folded = subscription_keyword_fold(name);
    for (let keyword in filter.exclude)
        if (index(folded, keyword) >= 0)
            return false;
    if (length(filter.include) == 0)
        return true;
    for (let keyword in filter.include)
        if (index(folded, keyword) >= 0)
            return true;
    return false;
}

function add_subscription_source_with_state(config, section, source_index, source_entry, taken, selector_tags, urltest_candidate_tags, state, show_metadata, include_urltest_groups, hide_urltest_group_outbounds, hide_detour_outbounds, node_prefix) {
    let section_name = section[".name"];
    let source_section = runtime_subscription.source_id(section_name, source_index);
    let ua = connections.subscription_user_agent(section, source_entry);
    let hwid = connections.subscription_hwid(section, source_entry);
    let hdr_sig = connections.subscription_device_headers_signature(section, source_entry);
    if (!runtime_subscription.source_cache_is_current(source_section, source_entry, ua, hwid, hdr_sig)) {
        let resolved_source_section = "";
        for (let src in connections.outbound_source_sections()) {
            let sname = as_string(src[".name"] || "");
            if (sname == "" || as_string(src.url || "") != source_entry)
                continue;
            for (let cand in [ runtime_subscription.source_id(sname, 1), sname ]) {
                if (runtime_subscription.source_cache_is_current(cand, source_entry, ua, hwid, hdr_sig)) {
                    resolved_source_section = cand;
                    break;
                }
            }
            if (resolved_source_section != "")
                break;
        }
        if (resolved_source_section == "") {
            let sub_folder = getenv("TMP_SUBSCRIPTION_FOLDER") || "/tmp/tachyon-core/subscriptions";
            for (let upath in (fs.glob(sub_folder + "/*.url") || [])) {
                let base_name = replace(replace(upath, /^.*\//, ""), /\.url$/, "");
                if (base_name != "" && runtime_subscription.source_cache_is_current(base_name, source_entry, ua, hwid, hdr_sig)) {
                    resolved_source_section = base_name;
                    break;
                }
            }
        }
        if (resolved_source_section == "")
            return 0;
        source_section = resolved_source_section;
    }

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
    // Decide before the loop whether the members can be dropped at all: only
    // when at least one outbound that is neither a group nor a member of one
    // survives. This keeps a section whose rules name the members working, and
    // still declutters large subscriptions.
    let urltest_member_tags = include_urltest_groups === false
        ? (visibility_refs.urltest || {})
        : {};
    let survivors = 0;
    for (let candidate in array_or_empty(outbounds)) {
        if (type(candidate) != "object")
            continue;
        if (subscription_urltest_group_outbound(candidate))
            continue;
        let candidate_tag = as_string(candidate.tag || "");
        if (candidate_tag == "" || !(candidate_tag in urltest_member_tags))
            survivors++;
    }
    let drop_urltest_members = include_urltest_groups === false && survivors > 0;
    node_prefix = trim(as_string(node_prefix));
    let keyword_filter = subscription_keyword_filter(section, source_entry);
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
        // A node that only a disabled urltest group pointed at is unreachable
        // and only clutters the selector, so it is dropped. But "unreachable
        // through a group" is not "unused": a section whose rules name these
        // nodes has them as its only outbounds, and dropping them leaves the
        // section with none, which generation reports as a terminal error. The
        // filter is therefore applied only while something else survives.
        if (drop_urltest_members && (as_string(outbound.tag || "") in urltest_member_tags))
            continue;
        let display_name = as_string(outbound.remark || outbound.tag || ("server-" + (i + 1)));
        if (keyword_filter != null && subscription_group_outbound(outbound) && !subscription_keyword_name_passes({ include: [], exclude: keyword_filter.exclude }, display_name))
            continue;
        if (keyword_filter != null && !subscription_group_outbound(outbound) && !subscription_keyword_name_passes(keyword_filter, display_name))
            continue;
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

    if (keyword_filter != null && length(prepared) == 0)
        ctx.runtime_generate_unsupported("subscription keyword filter removed all nodes for rule '" + section_name + "'");

    if (length(keys(skipped)) > 0)
        warn("skipped unsupported subscription outbounds for rule '", section_name, "': ", subscription_skip_summary(skipped), "\n");

    rewrite_subscription_outbound_references(prepared, tag_map, subscription_reference_set(source_outbounds));
    let active_hidden_refs = {};
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        if (group_flags[i]) {
            for (let member_tag in array_or_empty(outbound.outbounds)) {
                let mt = as_string(member_tag);
                if (mt != "")
                    active_hidden_refs[mt] = true;
            }
        }
        let detour_tag = as_string(outbound.detour || "");
        if (detour_tag != "")
            active_hidden_refs[detour_tag] = true;
    }

    let added = 0;
    for (let i = 0; i < length(prepared); i++) {
        let outbound = prepared[i];
        let is_group = group_flags[i];
        if (is_group && length(array_or_empty(outbound.outbounds)) == 0) {
            warn("skipped empty subscription group for rule '", section_name, "': ", as_string(display_names[i] || outbound.tag || "unknown"), "\n");
            continue;
        }
        if (hidden_flags[i] === true && !(as_string(outbound.tag || "") in active_hidden_refs))
            continue;

        if (outbound.type == "urltest") {
            let sub_idle_timeout = connections.subscription_urltest_idle_timeout(section, source_entry);
            if (sub_idle_timeout != "")
                outbound.idle_timeout = sub_idle_timeout;
            else if (as_string(outbound.idle_timeout || "") == "") {
                let sec_idle = ctx.routes.urltest_idle_timeout(section, "urltest");
                if (sec_idle != "")
                    outbound.idle_timeout = sec_idle;
            }
        }
        if (outbound.type == "wireguard") {
            add_imported_wireguard_endpoint(config, outbound);
        } else if (outbound.type == "shadowtls" && !(as_string(outbound.tag || "") in active_hidden_refs)) {
            let stls_tag = unique_tag(outbound.tag + "-stls", taken);
            taken[stls_tag] = true;
            let stls_outbound = {};
            for (let k, v in outbound)
                stls_outbound[k] = v;
            stls_outbound.tag = stls_tag;
            push(config.outbounds, stls_outbound);
            outbound = {
                type: "shadowsocks",
                tag: outbound.tag,
                server: stls_outbound.server,
                server_port: stls_outbound.server_port,
                method: "aes-128-gcm",
                password: as_string(stls_outbound.password || ""),
                detour: stls_tag
            };
            push(config.outbounds, outbound);
        } else {
            push(config.outbounds, outbound);
        }
        added++;
        if (!is_group)
            push(urltest_candidate_tags, outbound.tag);
        runtime_subscription.remember_source_outbound(
            state,
            outbound.tag,
            display_names[i],
            outbound,
            source_links[i],
            node_prefix,
            "sub:" + source_index
        );
        if (hidden_flags[i] !== true) {
            push(selector_tags, outbound.tag);
            runtime_subscription.remember_urltest_group(state, outbound.tag, display_names[i], outbound);
        } else if (state && state.hiddenOutboundTags) {
            state.hiddenOutboundTags[outbound.tag] = true;
        }
    }
    if (keyword_filter != null && added == 0)
        ctx.runtime_generate_unsupported("subscription keyword filter removed all nodes for rule '" + section_name + "'");
    return added;
}

function add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let subscription_urls = connections.subscription_urls(section);

    // Index 1-based on purpose: the source id is positional, so a disabled URL
    // must keep its slot instead of the list being renumbered underneath it.
    for (let i = 0; i < length(subscription_urls); i++)
        if (connections.subscription_url_enabled(section, subscription_urls[i]))
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
    let src_id = (connections && connections.source_id_for_manual_item)
        ? connections.source_id_for_manual_item(section, interface_name)
        : "";
    state.outboundMetadata.sources[tag_name] = src_id != "" ? src_id : "manual";
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
        let src_id = (connections && connections.source_id_for_manual_item)
            ? connections.source_id_for_manual_item(section, items[i])
            : "";
        push(prepared, {
            outbound,
            displayName: display_name != "" ? display_name : "JSON outbound " + (i + 1),
            sourceId: src_id != "" ? src_id : "manual"
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
        state.outboundMetadata.sources[tag_name] = item.sourceId || "manual";
    }
}

function add_connection_inline_uci_outbound(config, state, section, taken, selector_tags, urltest_candidate_tags) {
    let raw_type = lc(trim(option(section, "type", "")));
    if (raw_type == "")
        raw_type = lc(trim(option(section, "protocol", "")));
    if (raw_type == "") {
        let act = lc(trim(option(section, "action", "")));
        if (act == "socks" || act == "socks5" || act == "socks4" || act == "http" ||
            act == "shadowsocks" || act == "ss" || act == "vless" || act == "vmess" ||
            act == "trojan" || act == "hysteria2" || act == "hy2" || act == "tuic")
            raw_type = act;
    }
    if (raw_type == "socks5" || raw_type == "socks4" || raw_type == "socks4a")
        raw_type = "socks";
    else if (raw_type == "ss")
        raw_type = "shadowsocks";
    else if (raw_type == "hy2")
        raw_type = "hysteria2";

    let server = trim(option(section, "server", option(section, "address", option(section, "host", option(section, "socks_server", "")))));
    let port_raw = trim(option(section, "server_port", option(section, "port", option(section, "socks_port", ""))));

    if (raw_type == "socks" && server == "" && port_raw != "")
        server = "127.0.0.1";
    if (raw_type == "socks" && server != "" && port_raw == "")
        port_raw = "1080";

    if (raw_type == "" || server == "" || port_raw == "")
        return;

    let port = parse_port(port_raw);
    if (port == null)
        return;

    let section_name = section[".name"];
    let base_tag = connection_item_tag(section_name, raw_type, 1);
    let tag_name = unique_tag(base_tag, taken);
    taken[tag_name] = true;

    let outbound = {
        type: raw_type,
        tag: tag_name,
        server: server,
        server_port: port
    };

    if (raw_type == "socks") {
        let ver = trim(option(section, "version", "5"));
        outbound.version = (ver == "4" || ver == "4a") ? ver : "5";
        let username = option(section, "username", option(section, "user", ""));
        let password = option(section, "password", option(section, "pass", ""));
        if (username != "")
            outbound.username = username;
        if (password != "")
            outbound.password = password;
    }
    else if (raw_type == "http") {
        let username = option(section, "username", option(section, "user", ""));
        let password = option(section, "password", option(section, "pass", ""));
        if (username != "")
            outbound.username = username;
        if (password != "")
            outbound.password = password;
    }
    else if (raw_type == "shadowsocks") {
        outbound.method = option(section, "method", option(section, "cipher", "aes-256-gcm"));
        outbound.password = option(section, "password", "");
        let plugin = option(section, "plugin", "");
        let plugin_opts = option(section, "plugin_opts", option(section, "plugin-opts", ""));
        if (plugin != "")
            outbound.plugin = plugin;
        if (plugin_opts != "")
            outbound.plugin_opts = plugin_opts;
    }
    else if (raw_type == "vless" || raw_type == "vmess") {
        outbound.uuid = option(section, "uuid", option(section, "id", ""));
        let flow = option(section, "flow", "");
        if (flow != "" && raw_type == "vless")
            outbound.flow = flow;
    }
    else if (raw_type == "trojan" || raw_type == "hysteria2" || raw_type == "tuic") {
        outbound.password = option(section, "password", "");
        if (raw_type == "tuic")
            outbound.uuid = option(section, "uuid", "");
    }

    let display_name = trim(option(section, "label", option(section, "name", "")));
    if (display_name == "")
        display_name = server + ":" + port;

    push(config.outbounds, outbound);
    push(selector_tags, tag_name);
    if (urltest_leaf_candidate_outbound(outbound))
        push(urltest_candidate_tags, tag_name);
    runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
}

function outbound_detour_tag_for_section(section) {
    if (!bool_option(section, "outbound_detour_enabled", false))
        return "";

    let detour_section = option(section, "outbound_detour_section", "");
    if (detour_section == "")
        return "";
    // A deferred or quarantined detour target contributes no outbound at all;
    // emitting its tag anyway would leave a dangling detour and take the whole
    // config down at sing-box check time.
    if (ctx.deferred_sections && ctx.deferred_sections[detour_section])
        return "";
    if (ctx.routes && type(ctx.routes.enabled_sections) == "function") {
        for (let s in ctx.routes.enabled_sections()) {
            if (as_string(s[".name"]) == detour_section && option(s, "action", "") == "group")
                return ctx.routes.urltest_outbound_tag(detour_section, "urltest");
        }
    }
    return outbound_tag(detour_section);
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
            outbound_type == "block" || outbound_type == "direct" ||
            outbound_type == "desync")
            continue;

        if (as_string(outbound.detour || "") == "")
            outbound.detour = detour_tag;
    }
}

function apply_section_packet_encoding_to_connection_outbounds(config, start_index, encoding) {
    encoding = lc(trim(as_string(encoding || "")));
    if (encoding == "" || encoding == "auto")
        return;

    let outbounds = array_or_empty(config.outbounds);
    for (let i = int(start_index || 0); i < length(outbounds); i++) {
        let outbound = outbounds[i];
        if (type(outbound) != "object")
            continue;

        let outbound_type = lc(as_string(outbound.type || ""));
        if (outbound_type == "vless" || outbound_type == "vmess") {
            if (encoding == "disabled" || encoding == "none" || encoding == "off") {
                delete outbound.packet_encoding;
            } else if (encoding == "xudp" || encoding == "packetaddr") {
                outbound.packet_encoding = encoding;
            }
        } else if (outbound_type == "shadowsocks") {
            if (encoding == "xudp" || encoding == "packetaddr" || encoding == "1" || encoding == "true") {
                outbound.udp_over_tcp = true;
            } else if (encoding == "disabled" || encoding == "none" || encoding == "off" || encoding == "0") {
                delete outbound.udp_over_tcp;
            }
        }
    }
}

function enabled_action_index(sections, target_section, action_name) {
    if (connections && connections.active_provider_section_index)
        return connections.active_provider_section_index(action_name, sections, target_section);
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

function add_openvpn_endpoint(config, section) {
    let tag = outbound_tag(section[".name"]);
    let server = option(section, "openvpn_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("OpenVPN section '" + section[".name"] + "' missing openvpn_server");
    let port = int_option(section, "openvpn_server_port", "1194");
    let proto = option(section, "openvpn_proto", "udp");
    let endpoint = {
        type: "openvpn-client",
        tag,
        server,
        server_port: port,
        network: proto
    };

    let username = option(section, "openvpn_username", "");
    if (username != "") endpoint.username = username;
    let password = option(section, "openvpn_password", "");
    if (password != "") endpoint.password = password;

    let cipher = option(section, "openvpn_cipher", "");
    if (cipher != "") {
        endpoint.cipher = cipher;
        let dc = [ cipher ];
        if (cipher != "AES-256-GCM") push(dc, "AES-256-GCM");
        if (cipher != "AES-128-GCM") push(dc, "AES-128-GCM");
        if (cipher != "CHACHA20-POLY1305") push(dc, "CHACHA20-POLY1305");
        endpoint.data_ciphers = dc;
    }
    let auth = option(section, "openvpn_auth", "");
    if (auth != "") endpoint.auth = auth;

    let mtu = int_option(section, "openvpn_mtu", "0");
    if (mtu > 0) endpoint.mtu = mtu;

    let tls = {};
    let ca   = option(section, "openvpn_ca", "");
    if (ca != "") {
        if (index(ca, "\n") == -1 && index(ca, "/") == 0)
            tls.certificate_path = ca;
        else
            tls.certificate = [ ca ];
    }
    let cert = option(section, "openvpn_cert", "");
    if (cert != "") {
        if (index(cert, "\n") == -1 && index(cert, "/") == 0)
            tls.client_certificate_path = cert;
        else
            tls.client_certificate = [ cert ];
    }
    let key  = option(section, "openvpn_key", "");
    if (key != "") {
        if (index(key, "\n") == -1 && index(key, "/") == 0)
            tls.client_key_path = key;
        else
            tls.client_key = [ key ];
    }

    let tls_crypt = option(section, "openvpn_tls_crypt", "");
    let tls_auth = option(section, "openvpn_tls_auth", "");
    let direction = option(section, "openvpn_key_direction", "");

    if (tls_crypt != "") {
        let cw = { type: "tls_crypt" };
        if (index(tls_crypt, "\n") == -1 && index(tls_crypt, "/") == 0)
            cw.key_path = tls_crypt;
        else
            cw.key = [ tls_crypt ];
        tls.control_wrap = cw;
    } else if (tls_auth != "") {
        let cw = { type: "tls_auth" };
        if (index(tls_auth, "\n") == -1 && index(tls_auth, "/") == 0)
            cw.key_path = tls_auth;
        else
            cw.key = [ tls_auth ];
        if (direction == "0" || direction == "server")
            cw.direction = "server";
        else if (direction == "1" || direction == "client")
            cw.direction = "client";
        tls.control_wrap = cw;
    }

    let detour = outbound_detour_tag_for_section(section);
    if (detour == "") {
        let legacy_detour = option(section, "openvpn_detour", "");
        if (legacy_detour != "")
            detour = outbound_tag(legacy_detour);
    }
    if (detour != "") {
        endpoint.detour = detour;
    }

    if (length(keys(tls)) > 0)
        endpoint.tls = tls;

    push(config.endpoints, endpoint);
}

function add_connection_dpi_sources(config, state, section, taken, selector_tags, urltest_candidate_tags, single_dpi_only) {
    if (!connections || !connections.section_effective_outbound_sources)
        return;
    let section_name = section[".name"];
    let sec_tag = outbound_tag(section_name);
    let all_sections = null;
    // The section list is only needed for DPI sources, and reading it needs a
    // UCI cursor the generator may not have (fixtures, unit tests). Read it
    // lazily so a section without DPI sources never needs the cursor.
    let dpi_sections = function() {
        if (all_sections == null) {
            all_sections = (ctx.routes && type(ctx.routes.enabled_sections) == "function" &&
                ctx.uci_cursor && type(ctx.uci_cursor) == "function")
                ? ctx.routes.enabled_sections()
                : [];
        }
        return all_sections;
    };
    for (let src in connections.section_effective_outbound_sources(section)) {
        let stype = lc(trim(option(src, "source_type", "")));
        let src_id = as_string(src[".name"] || "");
        let display_name = trim(option(src, "name", src_id)) || src_id;
        if (stype == "zapret2") {
            let idx = enabled_action_index(dpi_sections(), section, "zapret2");
            if (idx <= 0)
                idx = 1;
            let tag_name = single_dpi_only ? sec_tag : unique_tag(outbound_tag(section_name + "-zapret2-" + src_id), taken);
            taken[tag_name] = true;
            let outbound = {
                type: "direct",
                tag: tag_name,
                routing_mark: runtime_constants.ZAPRET2_ROUTE_MARK_BASE + idx
            };
            push(config.outbounds, outbound);
            push(selector_tags, tag_name);
            runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
            state.outboundMetadata.sources[tag_name] = src_id;
        } else if (stype == "zapret") {
            let idx = enabled_action_index(dpi_sections(), section, "zapret");
            if (idx <= 0)
                idx = 1;
            let tag_name = single_dpi_only ? sec_tag : unique_tag(outbound_tag(section_name + "-zapret-" + src_id), taken);
            taken[tag_name] = true;
            let outbound = {
                type: "direct",
                tag: tag_name,
                routing_mark: runtime_constants.ZAPRET_ROUTE_MARK_BASE + idx
            };
            push(config.outbounds, outbound);
            push(selector_tags, tag_name);
            runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
            state.outboundMetadata.sources[tag_name] = src_id;
        } else if (stype == "byedpi") {
            let idx = enabled_action_index(all_sections, section, "byedpi");
            if (idx <= 0)
                idx = 1;
            let tag_name = unique_tag(outbound_tag(section_name + "-byedpi-" + src_id), taken);
            taken[tag_name] = true;
            let outbound = {
                type: "socks",
                tag: tag_name,
                server: runtime_constants.BYEDPI_LISTEN_ADDRESS,
                server_port: runtime_constants.BYEDPI_PORT_BASE + idx - 1,
                version: "5"
            };
            push(config.outbounds, outbound);
            push(selector_tags, tag_name);
            runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
            state.outboundMetadata.sources[tag_name] = src_id;
        } else if (stype == "wdtt") {
            let idx = enabled_action_index(all_sections, section, "wdtt");
            if (idx <= 0)
                idx = 1;
            let tag_name = unique_tag(outbound_tag(section_name + "-wdtt-" + src_id), taken);
            taken[tag_name] = true;
            let outbound = {
                type: "socks",
                tag: tag_name,
                server: runtime_constants.WDTT_LISTEN_ADDRESS,
                server_port: runtime_constants.WDTT_PORT_BASE + idx - 1,
                version: "5"
            };
            push(config.outbounds, outbound);
            push(selector_tags, tag_name);
            push(urltest_candidate_tags, tag_name);
            runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
            state.outboundMetadata.sources[tag_name] = src_id;
        } else if (stype == "olcrtc") {
            let idx = enabled_action_index(all_sections, section, "olcrtc");
            if (idx <= 0)
                idx = 1;
            let tag_name = unique_tag(outbound_tag(section_name + "-olcrtc-" + src_id), taken);
            taken[tag_name] = true;
            let outbound = {
                type: "socks",
                tag: tag_name,
                server: runtime_constants.OLCRTC_LISTEN_ADDRESS,
                server_port: runtime_constants.OLCRTC_PORT_BASE + idx - 1,
                version: "5"
            };
            push(config.outbounds, outbound);
            push(selector_tags, tag_name);
            push(urltest_candidate_tags, tag_name);
            runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, outbound);
            state.outboundMetadata.sources[tag_name] = src_id;
        } else if (stype == "openvpn") {
            let server = trim(option(src, "openvpn_server", ""));
            if (server == "")
                continue;
            let tag_name = unique_tag(outbound_tag(section_name + "-openvpn-" + src_id), taken);
            taken[tag_name] = true;
            let ovpn_sec = {};
            for (let k, v in src)
                ovpn_sec[k] = v;
            ovpn_sec[".name"] = tag_name;
            add_openvpn_endpoint(config, ovpn_sec);
            push(selector_tags, tag_name);
            push(urltest_candidate_tags, tag_name);
            runtime_subscription.remember_outbound_metadata(state, tag_name, display_name, {
                type: "openvpn-client",
                tag: tag_name,
                server,
                server_port: int_option(src, "openvpn_server_port", "1194")
            });
            state.outboundMetadata.sources[tag_name] = src_id;
        }
    }
}

function add_connections_outbound(config, section, taken) {
    let section_name = section[".name"];
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let state = runtime_subscription.new_section_state(section_name);
    let cascade_start = length(array_or_empty(config.outbounds));

    let eff_sources = (connections && connections.section_effective_outbound_sources)
        ? connections.section_effective_outbound_sources(section)
        : [];
    let single_dpi_only = false;
    if (length(eff_sources) == 1 &&
        length(connections.balancer_refs(section)) == 0 &&
        length(connections.outbound_group_refs(section)) == 0 &&
        length(connections.connection_urls(section)) == 0 &&
        length(connections.subscription_urls(section)) == 0 &&
        length(connections.interfaces(section)) == 0 &&
        length(connections.outbound_jsons(section)) == 0) {
        let only_stype = lc(trim(option(eff_sources[0], "source_type", "")));
        if (only_stype == "zapret" || only_stype == "zapret2")
            single_dpi_only = true;
    }

    add_connection_dpi_sources(config, state, section, taken, selector_tags, urltest_candidate_tags, single_dpi_only);
    if (single_dpi_only && length(selector_tags) == 1)
        return;
    let manual_count = length(connections.connection_urls(section));
    add_connection_manual_links(config, state, section, taken, selector_tags, urltest_candidate_tags);
    let text_urltest_tag = add_connection_text_urltest(config, state, section, taken, selector_tags, urltest_candidate_tags, manual_count);
    add_connection_subscriptions(config, state, section, taken, selector_tags, urltest_candidate_tags);
    
    apply_section_detour_to_connection_outbounds(
        config,
        cascade_start,
        outbound_detour_tag_for_section(section)
    );
    add_connection_interfaces(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_json_outbounds(config, state, section, taken, selector_tags, urltest_candidate_tags);
    add_connection_inline_uci_outbound(config, state, section, taken, selector_tags, urltest_candidate_tags);
    apply_section_packet_encoding_to_connection_outbounds(
        config,
        cascade_start,
        connections.packet_encoding(section)
    );

    if (length(selector_tags) == 0) {
        if (ctx.deferred_sections && ctx.deferred_sections[section_name])
            return;
        if (getenv("SB_PREFLIGHT_BINARY")) {
            let dummy_tag = unique_tag("preflight-dummy-" + section_name, taken);
            taken[dummy_tag] = true;
            push(config.outbounds, {
                type: "direct",
                tag: dummy_tag
            });
            push(selector_tags, dummy_tag);
            push(urltest_candidate_tags, dummy_tag);
            runtime_subscription.remember_outbound_metadata(state, dummy_tag, dummy_tag, { type: "direct", tag: dummy_tag });
        } else {
            ctx.runtime_generate_unsupported("connection section has no usable outbounds");
        }
    }

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
    ctx.routes.add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state, text_urltest_tag);
    if (!getenv("SB_PREFLIGHT_BINARY") && !ctx.atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        ctx.runtime_generate_unsupported("failed to write section cache for " + section_name);
}

// An AmneziaWG section carrying imported .conf files is shaped the way an FPTN
// token is: one endpoint per config, an auto urltest group over them, and the
// section selector on top — so several configs behave like several servers and
// the urltest/priority children have something to group. A bare endpoint
// cannot carry those children, and the Clash API rejects a non-selector as the
// section tag on every dashboard group switch.
function add_awg_config_members(config, section) {
    let section_name = section[".name"];
    let tag = outbound_tag(section_name);
    let state = runtime_subscription.new_section_state(section_name);
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let taken = { };
    taken[tag] = true;
    let detour = outbound_detour_tag_for_section(section);

    for (let value in connections.amnezia_configs(section)) {
        let item = subscription_amnezia.parse(value);
        if (item == null)
            ctx.runtime_generate_unsupported("Invalid imported Amnezia configuration");
        let endpoints = subscription_wireguard.from_vpn_endpoints(item.link);
        if (endpoints == null)
            ctx.runtime_generate_unsupported("invalid imported Amnezia configuration: " + as_string(item.name));
        // Every peer of the .conf is its own member: a multi-peer file behaves
        // like several configs, and each server joins the urltest pool.
        for (let i = 0; i < length(endpoints); i++) {
            let display_name = as_string(endpoints[i].tag || item.name);
            let member_tag = unique_tag(tag + "/" + display_name, taken);
            taken[member_tag] = true;
            let member = copy_subscription_outbound(endpoints[i], member_tag);
            if (detour != "")
                member.detour = detour;
            add_imported_wireguard_endpoint(config, member);
            push(selector_tags, member_tag);
            push(urltest_candidate_tags, member_tag);
            runtime_subscription.remember_outbound_metadata(state, member_tag, display_name, member);
        }
    }

    // The group the selector defaults to. Same shape as the FPTN expansion;
    // a section urltest child called "urltest" owns this very tag, and then it
    // is the group and nothing is emitted here.
    let text_urltest_tag = "";
    if (index(connections.urltests(section), "urltest") < 0) {
        text_urltest_tag = ctx.routes.urltest_outbound_tag(section_name, "urltest");
        let group_members = [];
        for (let member_tag in selector_tags)
            push(group_members, member_tag);
        let auto_group = {
            type: "urltest",
            tag: text_urltest_tag,
            outbounds: group_members
        };
        push(config.outbounds, auto_group);
        let group_name = option(section, "label", "");
        if (group_name == "") group_name = text_urltest_tag;
        runtime_subscription.remember_outbound_metadata(state, text_urltest_tag, group_name, auto_group);
        runtime_subscription.remember_urltest_group_config(state, text_urltest_tag, {
            displayName: group_name,
            outbounds: group_members
        });
    }

    state.urltestCandidateTags = unique_string_array(urltest_candidate_tags);
    ctx.routes.add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state, text_urltest_tag);
    if (!getenv("SB_PREFLIGHT_BINARY") && !ctx.atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        ctx.runtime_generate_unsupported("failed to write section cache for " + section_name);
}

function add_awg_endpoint(config, section) {
    if (length(connections.amnezia_configs(section)) > 0) {
        add_awg_config_members(config, section);
        return;
    }
    let tag = outbound_tag(section[".name"]);
    let endpoint = {
        type: "wireguard",
        tag: tag,
        name: tag,
        address: core_ip.normalize_to_cidrs(list_option(section, "awg_local_address")),
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

    let mtu = int_option(section, "awg_mtu", "1280");
    endpoint.mtu = mtu > 0 ? mtu : 1280;

    let sb_version_val = variant_state.read_version_state();
    let sb_variant_val = variant_state.read_variant_marker();
    let is_lx = sb_variant_val == "lx" || index(sb_version_val, "-lx") >= 0;
    // tachyon-core reads the AmneziaWG params flat off the wireguard endpoint -
    // the same layout sing-box-lx uses. Its KNOWN_ENDPOINT_FIELDS has no
    // "amnezia" wrapper, so a config carrying one is rejected outright.
    let is_core = ctx.is_tachyon_core != null ? ctx.is_tachyon_core(sb_version_val) : false;
    let flat_awg = is_lx || is_core;

    let keepalive = int_or_range_option(section, "awg_keepalive", 25);
    if (is_lx) {
        endpoint.peers[0].persistent_keepalive_interval = keepalive;
    } else {
        if (type(keepalive) == "string") {
            let m = match(keepalive, /^([0-9]+)/);
            endpoint.peers[0].persistent_keepalive_interval = m ? int(m[1], 10) : 25;
        } else {
            endpoint.peers[0].persistent_keepalive_interval = keepalive > 0 ? keepalive : 25;
        }
    }

    let jc = int_option(section, "awg_jc", "4");
    if (jc > 10) jc = 10;

    let jmin = int_option(section, "awg_jmin", "40");

    let jmax = int_option(section, "awg_jmax", "70");
    if (jmax > 1200) jmax = 1200;

    // AmneziaWG obfuscation parameters. H1-H4 use badoption.Range on both
    // sing-box-extended and sing-box-lx, so a "min-max" string passes through.
    let amnezia = {
        jc: jc,
        jmin: jmin,
        jmax: jmax,
        s1: int_option(section, "awg_s1", "0"),
        s2: int_option(section, "awg_s2", "0"),
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

    if (flat_awg) {
        // sing-box-lx and tachyon-core expect AWG fields at the endpoint root
        // (AWG 2.0 schema). Magic headers accept a single value or an AWG 2.0
        // "min-max" range; junk-packet fields are plain integers.
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
        // j1-j3/itime were removed from the extended schema in 2.6.1 and
        // sing-box fatals on unknown fields, so emit them only for builds
        // whose schema still accepts them.
        let sb_version = variant_state.read_version_state();
        if (common.extended_awg_schema_has_junk_signatures(sb_version)) {
            if (j1 != "") amnezia.j1 = j1;
            if (j2 != "") amnezia.j2 = j2;
            if (j3 != "") amnezia.j3 = j3;
            if (itime > 0) amnezia.itime = itime;
        }

        endpoint.amnezia = amnezia;
    }

    // AmneziaWG version handling: 2.0, 3.0, and 3.1 (sing-box-lx & sing-box-extended 2.7.0+)
    let awg_ver = option(section, "awg_version", "");
    if (awg_ver == "") {
        if (option(section, "awg_rekey_after_time", "") != "" || option(section, "awg_rekey_timeout", "") != "" ||
            option(section, "awg_reject_after_time", "") != "" || option(section, "awg_keepalive_timeout", "") != "" ||
            option(section, "awg_max_handshake_attempts", "") != "" ||
            bool_option(section, "awg_random_trailers", false) || bool_option(section, "awg_disable_cookies", false)) {
            awg_ver = "3.1";
        } else if (option(section, "awg_header_protection_key", "") != "" || option(section, "awg_content_padding_addition", "") != "") {
            awg_ver = "3.0";
        } else {
            awg_ver = "2.0";
        }
    }

    if (awg_ver == "3.0" || awg_ver == "3.1") {
        let hpk = option(section, "awg_header_protection_key", "");
        if (hpk != "") {
            if (flat_awg) {
                if (endpoint.s1 < 12) endpoint.s1 = 20;
                if (endpoint.s2 < 12) endpoint.s2 = 20;
                if (endpoint.s3 < 12) endpoint.s3 = 20;
                if (endpoint.s4 < 12) endpoint.s4 = 20;
                endpoint.header_protection_key = hpk;
            } else {
                if (endpoint.amnezia.s1 < 12) endpoint.amnezia.s1 = 20;
                if (endpoint.amnezia.s2 < 12) endpoint.amnezia.s2 = 20;
                if (endpoint.amnezia.s3 < 12) endpoint.amnezia.s3 = 20;
                if (endpoint.amnezia.s4 < 12) endpoint.amnezia.s4 = 20;
                endpoint.amnezia.header_protection_key = hpk;
            }
        }

        let cpa = option(section, "awg_content_padding_addition", "");
        if (cpa != "") {
            if (flat_awg) endpoint.content_padding_addition = cpa;
            else endpoint.amnezia.content_padding_addition = cpa;
        }
    }

    if (awg_ver == "3.1") {
        let rka = option(section, "awg_rekey_after_time", "");
        if (rka != "") {
            if (flat_awg) endpoint.rekey_after_time = rka;
            else endpoint.amnezia.rekey_after_time = rka;
        }

        let rkt = option(section, "awg_rekey_timeout", "");
        if (rkt != "") {
            if (flat_awg) endpoint.rekey_timeout = rkt;
            else endpoint.amnezia.rekey_timeout = rkt;
        }

        let rja = option(section, "awg_reject_after_time", "");
        if (rja != "") {
            if (flat_awg) endpoint.reject_after_time = rja;
            else endpoint.amnezia.reject_after_time = rja;
        }

        let kpt = option(section, "awg_keepalive_timeout", "");
        if (kpt != "") {
            if (flat_awg) endpoint.keepalive_timeout = kpt;
            else endpoint.amnezia.keepalive_timeout = kpt;
        }

        let mha = option(section, "awg_max_handshake_attempts", "");
        if (mha != "") {
            if (flat_awg) endpoint.max_handshake_attempts = mha;
            else endpoint.amnezia.max_handshake_attempts = mha;
        }

        if (flat_awg) {
            if (bool_option(section, "awg_random_trailers", false))
                endpoint.random_trailers = true;
            if (bool_option(section, "awg_disable_cookies", false))
                endpoint.disable_cookies = true;
        }
    }

    let detour = outbound_detour_tag_for_section(section);
    if (detour == "") {
        let legacy_detour = option(section, "awg_detour", "");
        if (legacy_detour != "")
            detour = outbound_tag(legacy_detour);
    }
    if (detour != "") {
        endpoint.detour = detour;
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
    // NB: was ctx.sing_box_tachyon_core, which nothing ever set - the branch was
    // dead and tachyon-core got the sing-box-extended masque shape instead.
    if (ctx.is_tachyon_core != null && ctx.is_tachyon_core(null)) {
        let masque_out = {
            type: "masque",
            tag,
            server: "162.159.198.2",
            server_port: 443,
            profile: "cloudflare",
            private_key,
            ip: "172.16.0.2/32"
        };
        if (access_token != "")
            masque_out.auth_token = access_token;
        if (detour != "")
            masque_out.detour = outbound_tag(detour);
        push(config.outbounds, masque_out);
        return;
    }

    // NB: no "mtu" here. sing-box-extended 2.7.x rejects it on the warp
    // endpoint ("endpoints[0].mtu: json: unknown field \"mtu\"") and aborts the
    // whole config. warp_mtu stays readable for backwards compatibility.
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
    let server = option(section, "anytls_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("AnyTLS section '" + section[".name"] + "' missing anytls_server");
    let outbound = {
        type: "anytls",
        tag,
        server,
        server_port: int_option(section, "anytls_server_port", "0"),
        password: option(section, "anytls_password", "")
    };
    let sni = option(section, "anytls_sni", "");
    let insecure = internal_flag(option(section, "anytls_insecure", "0"));
    outbound.tls = { enabled: true };
    // Fall back to server hostname when no explicit SNI is configured
    outbound.tls.server_name = sni != "" ? sni : server;
    if (insecure) outbound.tls.insecure = true;
    let min_idle = int_option(section, "anytls_min_idle_session", "0");
    if (min_idle > 0) outbound.min_idle_session = min_idle;
    let check_interval = option(section, "anytls_idle_session_check_interval", "");
    if (check_interval != "") outbound.idle_session_check_interval = check_interval;
    let idle_timeout = option(section, "anytls_idle_session_timeout", "");
    if (idle_timeout != "") outbound.idle_session_timeout = idle_timeout;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_snell_outbound(config, section) {
    let outbound = {
        type: "snell",
        tag: outbound_tag(section[".name"]),
        server: option(section, "snell_server", ""),
        server_port: int_option(section, "snell_server_port", "0"),
        psk: option(section, "snell_psk", ""),
        version: int_option(section, "snell_version", "4")
    };
    let obfs = option(section, "snell_obfs", "");
    if (obfs != "" && obfs != "none") {
        let obfs_obj = { mode: obfs };
        let obfs_host = option(section, "snell_obfs_host", "");
        if (obfs_host != "") obfs_obj.host = obfs_host;
        outbound.obfs = obfs_obj;
    }
    if (bool_option(section, "snell_uot", false))
        outbound.udp_over_tcp = true;
    if (bool_option(section, "snell_reuse", false))
        outbound.reuse = true;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_mieru_outbound(config, section) {
    let outbound = {
        type: "mieru",
        tag: outbound_tag(section[".name"]),
        server: option(section, "mieru_server", ""),
        server_port: int_option(section, "mieru_server_port", "0"),
        transport: option(section, "mieru_transport", "TCP"),
        username: option(section, "mieru_username", ""),
        password: option(section, "mieru_password", "")
    };
    let server_ports = list_option(section, "mieru_server_ports");
    if (length(server_ports) > 0)
        outbound.server_ports = server_ports;
    let multiplexing = option(section, "mieru_multiplexing", "");
    if (multiplexing != "")
        outbound.multiplexing = multiplexing;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_naive_outbound(config, section) {
    let tls = { enabled: true };
    let sni = option(section, "naive_sni", "");
    if (sni != "")
        tls.server_name = sni;
    let outbound = {
        type: "naive",
        tag: outbound_tag(section[".name"]),
        server: option(section, "naive_server", ""),
        server_port: int_option(section, "naive_server_port", "0"),
        username: option(section, "naive_username", ""),
        password: option(section, "naive_password", ""),
        // NaiveProxy is HTTPS-only: tachyon-core refuses a naive outbound with
        // no tls block, and tls.insecure is rejected by it outright.
        tls: tls
    };
    if (bool_option(section, "naive_quic", false))
        outbound.quic = true;
    let cc = option(section, "naive_quic_congestion_control", "");
    if (cc != "")
        outbound.quic_congestion_control = cc;
    let conc = int_option(section, "naive_insecure_concurrency", "0");
    if (conc > 0)
        outbound.insecure_concurrency = conc;
    if (bool_option(section, "naive_uot", false))
        outbound.udp_over_tcp = true;
    let raw_headers = trim(option(section, "naive_extra_headers", ""));
    if (raw_headers != "") {
        let parsed_headers = null;
        if (substr(raw_headers, 0, 1) == "{") {
            try { parsed_headers = json(raw_headers); } catch (e) { parsed_headers = null; }
        }
        if (type(parsed_headers) == "object") {
            outbound.extra_headers = parsed_headers;
        } else {
            let hdrs = {};
            for (let line in split(raw_headers, /\r?\n/)) {
                let colon = index(line, ":");
                if (colon > 0) {
                    let hk = trim(substr(line, 0, colon));
                    let hv = trim(substr(line, colon + 1));
                    if (hk != "") hdrs[hk] = hv;
                }
            }
            if (length(keys(hdrs)) > 0)
                outbound.extra_headers = hdrs;
        }
    }
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
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
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_masque_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let account_id  = option(section, "masque_account_id", "");
    let access_token = option(section, "masque_access_token", "");
    let core_state = require("tachyon_core.variant_state");
    let is_core = (ctx.is_tachyon_core != null && ctx.is_tachyon_core(null)) ||
        core_state.current_profile() == "tachyon-core" ||
        core_state.current_profile() == "lx";

    let masque_server = option(section, "masque_server", "");
    let masque_priv = option(section, "masque_private_key", "");

    if (is_core || masque_server != "" || masque_priv != "") {
        let profile = option(section, "masque_profile", "cloudflare");
        let server = masque_server != "" ? masque_server : "162.159.198.2";
        let server_port = int_option(section, "masque_server_port", "443");
        let outbound = {
            type: "masque",
            tag,
            server,
            server_port,
            profile
        };
        let vhttp = option(section, "masque_vhttp", "");
        if (vhttp != "") outbound.vhttp = vhttp;
        if (masque_priv != "") outbound.private_key = masque_priv;
        let pub = option(section, "masque_public_key", "");
        if (pub != "") outbound.public_key = pub;
        let ip = option(section, "masque_ip", profile == "cloudflare" ? "172.16.0.2/32" : "");
        if (ip != "") outbound.ip = ip;
        let ipv6 = option(section, "masque_ipv6", "");
        if (ipv6 != "") outbound.ipv6 = ipv6;
        let uri = option(section, "masque_uri", "");
        if (uri != "") outbound.uri = uri;
        let mtu = int_option(section, "masque_mtu", "0");
        if (mtu > 0) outbound.mtu = mtu;
        if (access_token != "") outbound.auth_token = access_token;
        let sni = option(section, "masque_sni", "");
        let insecure = bool_option(section, "masque_insecure", false);
        let fragment = bool_option(section, "masque_fragment", false);
        let record_fragment = bool_option(section, "masque_record_fragment", false);
        if (sni != "" || insecure || fragment || record_fragment) {
            let tls = { enabled: true };
            if (sni != "") tls.server_name = sni;
            if (insecure) tls.insecure = true;
            if (fragment) tls.fragment = true;
            if (record_fragment) tls.record_fragment = true;
            outbound.tls = tls;
        }
        let detour = outbound_detour_tag_for_section(section);
        if (detour != "") outbound.detour = detour;
        push(config.outbounds, outbound);
        return;
    }

    if (account_id == "")
        ctx.runtime_generate_unsupported("MASQUE section '" + section[".name"] + "' missing masque_account_id");
    if (access_token == "")
        ctx.runtime_generate_unsupported("MASQUE section '" + section[".name"] + "' missing masque_access_token");
    // sing-box-extended 2.7.x models MASQUE as an outbound with a single
    // "profile" object; the endpoint + profiles[] form we used to emit is not
    // known to it ("unknown endpoint type: masque") and aborts the config.
    // masque_private_key is not part of that profile, so it is not emitted.
    push(config.outbounds, {
        type: "masque",
        tag,
        name: tag,
        profile: { id: account_id, auth_token: access_token }
    });
}

function normalize_desync_preset_value(val) {
    val = lc(trim(as_string(val)));
    if (val == "" || val == "none" || val == "custom")
        return "";
    if (val in ["fake_split", "fakesplit", "split", "disorder", "tlsrec", "tls_rec", "fake", "oob", "auto"])
        return val == "fakesplit" ? "fake_split" : (val == "tls_rec" ? "tlsrec" : val);
    if (val == "youtube" || val == "google_youtube" || val == "discord" || val == "general" || val == "general_fake_tls")
        return "fake_split";
    if (val == "general_alt")
        return "tlsrec";
    if (val == "aggressive" || val == "general_alt2" || val == "general_multisplit")
        return "disorder";
    if (val == "light" || val == "general_simple_fake")
        return "split";
    return "fake_split";
}

function normalize_desync_mode_value(val) {
    val = lc(trim(as_string(val)));
    if (val == "")
        return "";
    if (val in ["fake_split", "fakesplit", "split", "disorder", "tlsrec", "tls_rec", "fake", "oob", "none"])
        return val == "fakesplit" ? "fake_split" : (val == "tls_rec" ? "tlsrec" : val);
    if (val == "fake+split")
        return "fake_split";
    if (val == "fake+disorder" || val == "fake_disorder" || val == "fakedisorder" || val == "multidisorder")
        return "disorder";
    if (val == "multisplit")
        return "split";
    return "fake_split";
}

function normalize_desync_split_pos_value(val) {
    val = lc(trim(as_string(val)));
    if (val == "midsld" || val == "sld" || val == "host")
        return "midsld";
    if (val == "sni" || val == "sniext")
        return "sni";
    if (val != "" && match(val, /^[0-9]+$/)) {
        let n = int(val, 10);
        if (n >= 1 && n <= 1400)
            return n;
    }
    return null;
}

function apply_desync_opts_string(outbound, opts_str) {
    opts_str = trim(as_string(opts_str));
    if (opts_str == "")
        return;
    for (let token in split(opts_str, /\s+/)) {
        let eq = index(token, "=");
        if (eq <= 0)
            continue;
        let k = lc(trim(substr(token, 0, eq)));
        if (substr(k, 0, 2) == "--")
            k = replace(substr(k, 2), /-/g, "_");
        let v = trim(substr(token, eq + 1));
        if (v == "")
            continue;
        if (k == "preset") {
            let np = normalize_desync_preset_value(v);
            if (np != "")
                outbound.preset = np;
        } else if (k == "mode") {
            let nm = normalize_desync_mode_value(v);
            if (nm != "")
                outbound.mode = nm;
        } else if (k == "split_pos") {
            let nsp = normalize_desync_split_pos_value(v);
            if (nsp != null)
                outbound.split_pos = nsp;
        } else if (k == "fake_ttl") {
            if (match(v, /^[0-9]+$/))
                outbound.fake_ttl = int(v, 10);
        } else if (k == "fake_sni") {
            outbound.fake_sni = v;
        } else if (k == "repeats") {
            if (match(v, /^[0-9]+$/))
                outbound.repeats = int(v, 10);
        } else if (k == "split_delay_ms") {
            if (match(v, /^[0-9]+$/))
                outbound.split_delay_ms = int(v, 10);
        } else if (k == "udp_fake") {
            outbound.udp_fake = is_true(v);
        } else if (k == "udp_repeats") {
            if (match(v, /^[0-9]+$/))
                outbound.udp_repeats = int(v, 10);
        } else if (k == "udp_fake_ttl") {
            if (match(v, /^[0-9]+$/))
                outbound.udp_fake_ttl = int(v, 10);
        }
    }
}

function add_desync_outbound(config, section) {
    ensure_desync_outbound_supported();
    let outbound = {
        type: "desync",
        tag: outbound_tag(section[".name"])
    };
    let raw_preset = option(section, "desync_preset", "");
    let preset = normalize_desync_preset_value(raw_preset);
    let mode = normalize_desync_mode_value(option(section, "desync_mode", ""));
    if (preset != "")
        outbound.preset = preset;
    if (mode != "")
        outbound.mode = mode;
    if (lc(trim(raw_preset)) == "discord" && !bool_option(section, "desync_udp_fake", false))
        outbound.udp_fake = true;
    let split_pos = normalize_desync_split_pos_value(option(section, "desync_split_pos", ""));
    if (split_pos != null)
        outbound.split_pos = split_pos;
    let fake_ttl = int_option(section, "desync_fake_ttl", "0");
    if (fake_ttl > 0)
        outbound.fake_ttl = fake_ttl;
    let fake_sni = option(section, "desync_fake_sni", "");
    if (fake_sni != "")
        outbound.fake_sni = fake_sni;
    let repeats = int_option(section, "desync_repeats", "0");
    if (repeats > 0)
        outbound.repeats = repeats;
    let delay_raw = option(section, "desync_split_delay_ms", "");
    if (delay_raw != "" && match(delay_raw, /^[0-9]+$/))
        outbound.split_delay_ms = int(delay_raw, 10);
    if (bool_option(section, "desync_udp_fake", false))
        outbound.udp_fake = true;
    let udp_repeats = int_option(section, "desync_udp_repeats", "0");
    if (udp_repeats > 0)
        outbound.udp_repeats = udp_repeats;
    let udp_fake_ttl = int_option(section, "desync_udp_fake_ttl", "0");
    if (udp_fake_ttl > 0)
        outbound.udp_fake_ttl = udp_fake_ttl;

    apply_desync_opts_string(outbound, option(section, "desync_opts", ""));

    if (outbound.preset == null && outbound.mode == null)
        outbound.preset = "tlsrec";
    if (outbound.preset == "fake_split" || outbound.preset == "auto" || outbound.preset == "fake") {
        outbound.preset = "disorder";
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
        if (outbound.udp_fake == null) outbound.udp_fake = true;
    }
    if (outbound.mode == "fake_split" || outbound.mode == "fake") {
        outbound.mode = "disorder";
        if (outbound.split_pos == null) outbound.split_pos = "midsld";
    }

    let detour = outbound_detour_tag_for_section(section);
    if (detour != "")
        outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_tewfai_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let server = option(section, "tewfai_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("Tewfai section '" + section[".name"] + "' missing tewfai_server");
    let outbound = {
        type: "tewfai",
        tag,
        server,
        server_port: int_option(section, "tewfai_server_port", "443"),
        uuid: option(section, "tewfai_uuid", "")
    };
    let password = option(section, "tewfai_password", "");
    if (password != "") outbound.password = password;
    let raw_tr = list_option(section, "tewfai_transport");
    if (length(raw_tr) == 0) {
        let tr_str = option(section, "tewfai_transport", "");
        if (tr_str != "")
            raw_tr = split(tr_str, ",");
    }
    let tr_list = [];
    for (let item in raw_tr) {
        item = lc(trim(as_string(item)));
        if (item == "raw_tls" || item == "h2" || item == "ws") item = "tcp";
        else if (item == "h3_stream" || item == "h3_datagram") item = "quic";
        if (item == "tcp" || item == "quic") {
            if (index(tr_list, item) < 0)
                push(tr_list, item);
        }
    }
    if (length(tr_list) > 0)
        outbound.transport = tr_list;
    let cipher = option(section, "tewfai_inner_cipher", "");
    if (cipher == "aes-256-gcm" || cipher == "none")
        outbound.inner_cipher = cipher;
    let morph = option(section, "tewfai_morph_profile", "");
    if (morph == "browsing" || morph == "video" || morph == "webrtc" || morph == "bulk")
        outbound.morph_profile = morph;
    let max_streams = int_option(section, "tewfai_max_streams", "0");
    if (max_streams > 0) outbound.max_streams = max_streams;
    let mtu = int_option(section, "tewfai_mtu", "0");
    if (mtu > 0) outbound.mtu = mtu;
    if (bool_option(section, "tewfai_pqc_enabled", false))
        outbound.pqc = true;
    if (bool_option(section, "tewfai_handover_enabled", false))
        outbound.handover = { enabled: true };
    if (bool_option(section, "tewfai_fec_enabled", false))
        outbound.fec = true;
    if (bool_option(section, "tewfai_shaper_enabled", false)) {
        let sp = option(section, "tewfai_shaper_profile", "adaptive");
        let mode = (sp == "fixed" || sp == "off") ? sp : "adaptive";
        outbound.shaper = { mode };
    }
    let sni = option(section, "tewfai_sni", "");
    let tls = {
        enabled: true,
        server_name: sni != "" ? sni : server
    };
    if (bool_option(section, "tewfai_insecure", false))
        tls.insecure = true;
    let alpn = list_option(section, "tewfai_alpn");
    if (length(alpn) > 0) tls.alpn = alpn;
    let fp = option(section, "tewfai_fingerprint", "");
    if (fp != "") tls.utls = { enabled: true, fingerprint: fp };
    let r_pbk = option(section, "tewfai_reality_public_key", "");
    if (r_pbk != "") {
        let reality = { enabled: true, public_key: r_pbk };
        let r_sid = option(section, "tewfai_reality_short_id", "");
        if (r_sid != "") reality.short_id = r_sid;
        tls.reality = reality;
        if (tls.utls == null)
            tls.utls = { enabled: true, fingerprint: "chrome" };
    }
    outbound.tls = tls;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_trusttunnel_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let server = option(section, "trusttunnel_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("TrustTunnel section '" + section[".name"] + "' missing trusttunnel_server");
    let outbound = {
        type: "trusttunnel",
        tag,
        server,
        server_port: int_option(section, "trusttunnel_server_port", "443")
    };
    let username = option(section, "trusttunnel_username", "");
    if (username != "") outbound.username = username;
    let password = option(section, "trusttunnel_password", "");
    if (password != "") outbound.password = password;
    if (bool_option(section, "trusttunnel_quic", false))
        outbound.quic = "true";
    let cc = option(section, "trusttunnel_congestion_control", "");
    if (cc != "") outbound.quic_congestion_control = cc;
    let sni = option(section, "trusttunnel_sni", "");
    let tls = {
        enabled: true,
        server_name: sni != "" ? sni : server
    };
    if (bool_option(section, "trusttunnel_insecure", false))
        tls.insecure = true;
    let alpn = list_option(section, "trusttunnel_alpn");
    if (length(alpn) > 0) tls.alpn = alpn;
    outbound.tls = tls;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_openconnect_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let server = option(section, "openconnect_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("OpenConnect section '" + section[".name"] + "' missing openconnect_server");
    let outbound = {
        type: "openconnect",
        tag,
        server,
        server_port: int_option(section, "openconnect_server_port", "443"),
        flavor: option(section, "openconnect_flavor", "anyconnect")
    };
    let username = option(section, "openconnect_username", "");
    if (username != "") outbound.username = username;
    let password = option(section, "openconnect_password", "");
    if (password != "") outbound.password = password;
    let cookie = option(section, "openconnect_cookie", "");
    if (cookie != "") outbound.cookie = cookie;
    let urlpath = option(section, "openconnect_urlpath", "");
    if (urlpath != "") outbound.urlpath = urlpath;
    let realm = option(section, "openconnect_realm", "");
    if (realm != "") outbound.realm = realm;
    let region = option(section, "openconnect_region", "");
    if (region != "") outbound.region = region;
    let ua = option(section, "openconnect_user_agent", "");
    if (ua != "") outbound.user_agent = ua;
    let lhost = option(section, "openconnect_local_hostname", "");
    if (lhost != "") outbound.local_hostname = lhost;
    if (bool_option(section, "openconnect_ip", false))
        outbound.ip = true;
    if (bool_option(section, "openconnect_esp", false))
        outbound.esp = true;
    if (bool_option(section, "openconnect_dtls", false))
        outbound.dtls = true;
    if (bool_option(section, "openconnect_hip_report", false))
        outbound.hip_report = true;
    let pin = option(section, "openconnect_server_cert_pin", "");
    if (pin != "") outbound.server_cert_pin = pin;
    let addr = option(section, "openconnect_address", "");
    if (addr != "") outbound.address = split(addr, "/")[0];
    let addrv6 = option(section, "openconnect_address_v6", "");
    if (addrv6 != "") outbound.address_v6 = split(addrv6, "/")[0];
    let mtu = int_option(section, "openconnect_mtu", "0");
    if (mtu > 0) outbound.mtu = as_string(mtu);
    let sni = option(section, "openconnect_sni", "");
    let tls = {
        enabled: true,
        server_name: sni != "" ? sni : server
    };
    if (bool_option(section, "openconnect_insecure", false))
        tls.insecure = true;
    outbound.tls = tls;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_mtproto_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let server = option(section, "mtproto_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("MTProto section '" + section[".name"] + "' missing mtproto_server");
    let raw_secret = option(section, "mtproto_secret", "");
    let norm_secret = lc(trim(as_string(raw_secret)));
    let padded_prefix = false;
    if (length(norm_secret) >= 34 && match(norm_secret, /^(ee|dd)[0-9a-f]{32}/)) {
        padded_prefix = substr(norm_secret, 0, 2) == "dd";
        raw_secret = substr(norm_secret, 2, 32);
    } else if (length(norm_secret) == 32 && match(norm_secret, /^[0-9a-f]{32}$/)) {
        raw_secret = norm_secret;
    }
    let outbound = {
        type: "mtproto",
        tag,
        server,
        server_port: int_option(section, "mtproto_server_port", "443"),
        secret: raw_secret
    };
    let transport = option(section, "mtproto_transport", "");
    if (transport != "") outbound.transport = transport;
    else if (padded_prefix) outbound.transport = "padded_intermediate";
    let mode = option(section, "mtproto_mode", "");
    if (mode != "") outbound.mode = mode;
    let sni = option(section, "mtproto_sni", "");
    if (sni != "")
        outbound.tls = { enabled: true, server_name: sni };
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_shadowtls_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let server = option(section, "shadowtls_server", "");
    if (server == "")
        ctx.runtime_generate_unsupported("ShadowTLS section '" + section[".name"] + "' missing shadowtls_server");
    let sni = option(section, "shadowtls_sni", "");
    let outbound = {
        type: "shadowtls",
        tag,
        server,
        server_port: int_option(section, "shadowtls_server_port", "443"),
        version: int_option(section, "shadowtls_version", "3"),
        password: option(section, "shadowtls_password", ""),
        tls: {
            enabled: true,
            server_name: sni != "" ? sni : server
        }
    };
    if (bool_option(section, "shadowtls_insecure", false))
        outbound.tls.insecure = true;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") outbound.detour = detour;
    push(config.outbounds, outbound);
}

function add_chain_outbound(config, section) {
    let tag = outbound_tag(section[".name"]);
    let hops = [];
    for (let s in list_option(section, "chain_sections")) {
        s = trim(as_string(s));
        if (s != "")
            push(hops, outbound_tag(s));
    }
    for (let o in list_option(section, "chain_outbounds")) {
        o = trim(as_string(o));
        if (o != "")
            push(hops, o);
    }
    let outbound = {
        type: "chain",
        tag,
        outbounds: unique_string_array(hops)
    };
    if (bool_option(section, "chain_strip", false))
        outbound.strip = true;
    if (bool_option(section, "chain_interrupt", false))
        outbound.interrupt_exist_connections = true;
    push(config.outbounds, outbound);
}

function add_tailscale_client_endpoint(config, section) {
    let tag = outbound_tag(section[".name"]);
    let endpoint = {
        type: "tailscale",
        tag,
        state_directory: "/etc/tachyon/tailscale/" + section[".name"],
        control_url: option(section, "tailscale_control_url", "https://controlplane.tailscale.com"),
        hostname: option(section, "tailscale_hostname", "tachyon-" + section[".name"]),
        ephemeral: bool_option(section, "tailscale_ephemeral", false),
        accept_routes: bool_option(section, "tailscale_accept_routes", true)
    };
    let auth_key = option(section, "tailscale_auth_key", "");
    if (auth_key != "") endpoint.auth_key = auth_key;
    let exit_node = option(section, "tailscale_exit_node", "");
    if (exit_node != "") endpoint.exit_node = exit_node;
    if (bool_option(section, "tailscale_exit_node_allow_lan_access", false))
        endpoint.exit_node_allow_lan_access = true;
    let detour = outbound_detour_tag_for_section(section);
    if (detour != "") endpoint.detour = detour;
    push(config.endpoints, endpoint);
}

function add_zapret_outbound(config, section, sections) {
    if (connections && !connections.section_is_active_provider(section, "zapret"))
        return;
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
    if (connections && !connections.section_is_active_provider(section, "zapret2"))
        return;
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
    if (connections && !connections.section_is_active_provider(section, "byedpi"))
        return;
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

function add_wdtt_outbound(config, section, sections) {
    if (connections && !connections.section_is_active_provider(section, "wdtt"))
        return;
    let index = enabled_action_index(sections, section, "wdtt");
    if (index <= 0)
        ctx.runtime_generate_unsupported("unable to resolve WDTT index for " + section[".name"]);
    push(config.outbounds, {
        type: "socks",
        tag: outbound_tag(section[".name"]),
        server: runtime_constants.WDTT_LISTEN_ADDRESS,
        server_port: runtime_constants.WDTT_PORT_BASE + index - 1,
        version: "5"
    });
}

function add_olcrtc_outbound(config, section, sections) {
    if (connections && !connections.section_is_active_provider(section, "olcrtc"))
        return;
    let index = enabled_action_index(sections, section, "olcrtc");
    if (index <= 0)
        ctx.runtime_generate_unsupported("unable to resolve OlcRTC index for " + section[".name"]);
    push(config.outbounds, {
        type: "socks",
        tag: outbound_tag(section[".name"]),
        server: runtime_constants.OLCRTC_LISTEN_ADDRESS,
        server_port: runtime_constants.OLCRTC_PORT_BASE + index - 1,
        version: "5"
    });
}

// Emit the section the way a connection section is shaped: one outbound per
// token server (`<tag>/<name>`), the auto urltest group over them, and the
// section selector on top — a urltest group as the section tag gets a 400
// "Must be a Selector" from the Clash API on every dashboard group switch.
// Returns false when the token cannot be decoded here.
function add_fptn_token_members(config, section, token) {
    let section_name = section[".name"];
    let decoded = fptn_token_decode(token);
    if (decoded == null)
        return false;

    let tag = outbound_tag(section_name);
    let state = runtime_subscription.new_section_state(section_name);
    let selector_tags = [];
    let urltest_candidate_tags = [];
    let detour = outbound_detour_tag_for_section(section);

    for (let server in decoded.servers) {
        let member = {
            type: "fptn",
            tag: tag + "/" + server.name,
            server: server.host,
            server_port: server.port,
            username: decoded.username,
            password: decoded.password
        };
        if (server.md5_fingerprint != "")
            member.md5_fingerprint = server.md5_fingerprint;
        if (detour != "")
            member.detour = detour;
        push(config.outbounds, member);
        push(selector_tags, member.tag);
        push(urltest_candidate_tags, member.tag);
        runtime_subscription.remember_outbound_metadata(state, member.tag, server.name, member);
    }

    // The group the selector defaults to. No url/interval/tolerance: this is
    // the same bare urltest core's own token expansion emits, and the two
    // shapes must not drift. A section urltest child called "urltest" owns
    // this very tag, so then it is the group and nothing is emitted here.
    let text_urltest_tag = "";
    if (index(connections.urltests(section), "urltest") < 0) {
        text_urltest_tag = ctx.routes.urltest_outbound_tag(section_name, "urltest");
        let group_members = [];
        for (let member_tag in selector_tags)
            push(group_members, member_tag);
        let auto_group = {
            type: "urltest",
            tag: text_urltest_tag,
            outbounds: group_members
        };
        push(config.outbounds, auto_group);
        let group_name = decoded.service_name != "" ? decoded.service_name : text_urltest_tag;
        runtime_subscription.remember_outbound_metadata(state, text_urltest_tag, group_name, auto_group);
        runtime_subscription.remember_urltest_group_config(state, text_urltest_tag, {
            displayName: group_name,
            outbounds: group_members
        });
    }

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
    ctx.routes.add_proxy_selector(config, section, selector_tags, urltest_candidate_tags, state, text_urltest_tag);
    if (!getenv("SB_PREFLIGHT_BINARY") && !ctx.atomic_write_json_file(runtime_subscription.section_cache_path(section_name), state))
        ctx.runtime_generate_unsupported("failed to write section cache for " + section_name);
    return true;
}

// FPTN routes traffic through its TUN interface (tun-fptn) via kernel routing.
// fwmark 0x00300000 (3145728) → ip rule → routing table 4249 → dev tun-fptn.
//
// tachyon-core speaks FPTN itself: in native mode the section expands into
// per-server outbounds plus a selector — the same shape a connection section
// gets — instead of a single outbound carrying the access token. The mode
// comes from the single resolver in config.connections so the generator and
// the provider runtime can never disagree.
function add_fptn_outbound(config, section, sections) {
    if (connections && !connections.section_is_active_provider(section, "fptn"))
        return;
    let tag = outbound_tag(section[".name"]);

    if (connections && connections.fptn_transport_mode() == "native") {
        // access_token is the canonical field; an fptn:// link pasted into the
        // section URL list feeds the same resolver, so a pasted token works
        // everywhere the section is read.
        let token = connections.fptn_section_token(section);
        if (token == "")
            return;
        if (add_fptn_token_members(config, section, token))
            return;
        // Undecodable on this box (brotli without the core binary, malformed
        // token): hand the raw token to the core, which expands it into the
        // same members itself.
        let fptn_out = {
            type: "fptn",
            tag,
            token: url_strip_fragment_value(token)
        };
        let detour = outbound_detour_tag_for_section(section);
        if (detour != "")
            fptn_out.detour = detour;
        push(config.outbounds, fptn_out);
        return;
    }

    push(config.outbounds, {
        type: "direct",
        tag,
        routing_mark: 3145728
    });
}

return {
    init,
    reserved_runtime_tag_set,
    assert_unique_outbound_tags,
    uci_bin_to_hex,
    unique_string_array,
    manual_http_outbound,
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
    add_naive_outbound,
    add_sudoku_outbound,
    add_masque_outbound,
    add_desync_outbound,
    add_tewfai_outbound,
    add_trusttunnel_outbound,
    add_openconnect_outbound,
    add_mtproto_outbound,
    add_shadowtls_outbound,
    add_chain_outbound,
    add_tailscale_client_endpoint,
    add_openvpn_endpoint,
    add_zapret_outbound,
    add_zapret2_outbound,
    add_byedpi_outbound,
    add_wdtt_outbound,
    add_olcrtc_outbound,
    add_fptn_outbound,
    fptn_token_decode,
    urltest_leaf_candidate_outbound,
    apply_section_packet_encoding_to_connection_outbounds
};
