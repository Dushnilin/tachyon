#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let shell_quote = common.shell_quote;

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function uri_encode(value) {
    value = as_string(value);
    let result = "";
    let len = length(value);
    for (let i = 0; i < len; i++) {
        let code = ord(value, i);
        if ((code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            code == 45 || code == 95 || code == 46 || code == 126)
            result += chr(code);
        else
            result += sprintf("%%%02X", code);
    }
    return result;
}

function base64_encode(value) {
    return replace(b64enc(as_string(value)), /=+$/, "");
}

function host_port(server, port) {
    server = as_string(server);
    if (index(server, ":") >= 0 && !starts_with(server, "["))
        server = "[" + server + "]";
    return server + ":" + as_string(port);
}

function hysteria2_server_port_entry(value) {
    value = as_string(value);
    let colon = index(value, ":");
    if (colon < 0)
        return value;

    let start = substr(value, 0, colon);
    let end = substr(value, colon + 1);
    if (start == "" || end == "")
        return "";

    return start == end ? start : (start + "-" + end);
}

function hysteria2_server_ports_uri(outbound) {
    let server_ports = array_or_empty(outbound.server_ports);
    if (length(server_ports) == 0)
        return "";

    let result = [];
    for (let item in server_ports) {
        let port = hysteria2_server_port_entry(item);
        if (port != "")
            push(result, port);
    }

    return join(",", result);
}

function add_query(params, key, value) {
    value = as_string(value);
    if (value != "")
        push(params, uri_encode(key) + "=" + uri_encode(value));
}

function add_cert_pin_query(params, tls) {
    if (type(tls) != "object" || type(tls.certificate_sha256) != "array" || length(tls.certificate_sha256) == 0)
        return;
    let decoded = b64dec(as_string(tls.certificate_sha256[0] || ""));
    if (decoded == null)
        return;
    let hex = common.bytes_to_hex(decoded);
    if (hex != "")
        add_query(params, "pcs", hex);
}

function add_xhttp_extra_query(params, transport) {
    let extra = {};
    for (let item in [
        ["xPaddingBytes", "x_padding_bytes"],
        ["noGRPCHeader", "no_grpc_header"],
        ["scMaxEachPostBytes", "sc_max_each_post_bytes"],
        ["scMinPostsIntervalMs", "sc_min_posts_interval_ms"],
        ["scStreamUpServerSecs", "sc_stream_up_server_secs"],
        ["sessionPlacement", "session_placement"],
        ["sessionKey", "session_key"],
        ["seqPlacement", "seq_placement"],
        ["seqKey", "seq_key"],
        ["uplinkDataPlacement", "uplink_data_placement"],
        ["uplinkDataKey", "uplink_data_key"],
        ["uplinkChunkSize", "uplink_chunk_size"],
        ["uplinkHttpMethod", "uplink_http_method"],
        ["xPaddingObfsMode", "x_padding_obfs_mode"],
        ["xPaddingPlacement", "x_padding_placement"],
        ["xPaddingKey", "x_padding_key"],
        ["xPaddingHeader", "x_padding_header"],
        ["xPaddingMethod", "x_padding_method"]
    ]) {
        if (transport[item[1]] != null)
            extra[item[0]] = transport[item[1]];
    }

    if (type(transport.xmux) == "object") {
        let xmux = {};
        for (let item in [
            ["maxConcurrency", "max_concurrency"],
            ["maxConnections", "max_connections"],
            ["cMaxReuseTimes", "c_max_reuse_times"],
            ["hMaxRequestTimes", "h_max_request_times"],
            ["hMaxReusableSecs", "h_max_reusable_secs"],
            ["hKeepAlivePeriod", "h_keep_alive_period"]
        ]) {
            if (transport.xmux[item[1]] != null)
                xmux[item[0]] = transport.xmux[item[1]];
        }
        if (length(keys(xmux)) > 0)
            extra.xmux = xmux;
    }

    if (length(keys(extra)) > 0)
        add_query(params, "extra", sprintf("%J", extra));
}

function add_tls_query(params, outbound, trojan_default_tls) {
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (!tls || tls.enabled === false) {
        if (trojan_default_tls)
            add_query(params, "security", "tls");
        return;
    }

    let reality = type(tls.reality) == "object" ? tls.reality : null;
    if (reality && reality.enabled !== false) {
        add_query(params, "security", "reality");
        add_query(params, "pbk", reality.public_key);
        add_query(params, "sid", reality.short_id);
        // The hybrid key share is a property of the server, so it has to
        // survive a round trip through a share link: a link built from a
        // config that has it must not silently lose it.
        if (reality.support_x25519mlkem768 != null)
            add_query(params, "support-x25519mlkem768", reality.support_x25519mlkem768 === true ? "1" : "0");
    }
    else {
        add_query(params, "security", "tls");
    }

    add_query(params, "sni", tls.server_name);
    if (tls.insecure === true)
        add_query(params, "allowInsecure", "1");
    if (type(tls.utls) == "object" && tls.utls.enabled !== false)
        add_query(params, "fp", tls.utls.fingerprint);
    if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
        add_query(params, "alpn", join(",", tls.alpn));
    add_cert_pin_query(params, tls);
}

function add_transport_query(params, outbound) {
    let transport = type(outbound.transport) == "object" ? outbound.transport : null;
    if (!transport) {
        add_query(params, "type", "tcp");
        return;
    }

    let transport_type = as_string(transport.type);
    add_query(params, "type", transport_type != "" ? transport_type : "tcp");

    if (transport_type == "ws") {
        add_query(params, "path", transport.path);
        if (type(transport.headers) == "object")
            add_query(params, "host", transport.headers.Host || transport.headers.host);
    }
    else if (transport_type == "grpc") {
        add_query(params, "serviceName", transport.service_name);
    }
    else if (transport_type == "http") {
        add_query(params, "path", transport.path);
        if (type(transport.host) == "array" && length(transport.host) > 0)
            add_query(params, "host", join(",", transport.host));
        else
            add_query(params, "host", transport.host);
    }
    else if (transport_type == "xhttp") {
        add_query(params, "path", transport.path);
        add_query(params, "host", transport.host);
        add_query(params, "mode", transport.mode);
        add_xhttp_extra_query(params, transport);
    }
}

function query_string(params) {
    return length(params) == 0 ? "" : "?" + join("&", params);
}

function fragment(outbound) {
    let tag = as_string(outbound.tag);
    return tag == "" ? "" : "#" + uri_encode(tag);
}

function serialize_vless(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, false);
    add_transport_query(params, outbound);
    let encryption = as_string(outbound.encryption);
    if (encryption != "" && encryption != "none")
        add_query(params, "encryption", encryption);
    add_query(params, "flow", outbound.flow);
    add_query(params, "packetEncoding", outbound.packet_encoding);
    return "vless://" + uri_encode(outbound.uuid) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_trojan(outbound) {
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, true);
    add_transport_query(params, outbound);
    return "trojan://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_shadowsocks(outbound) {
    if (as_string(outbound.method) == "" || as_string(outbound.password) == "" ||
        as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let userinfo = base64_encode(as_string(outbound.method) + ":" + as_string(outbound.password));
    return userinfo == "" ? "" :
        "ss://" + userinfo + "@" + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_socks(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let scheme = "socks" + as_string(outbound.version || "5");
    let auth = "";
    if (as_string(outbound.username) != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password) != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    }

    return scheme + "://" + auth + host_port(outbound.server, outbound.server_port) + fragment(outbound);
}

function serialize_http(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let is_tls = type(outbound.tls) == "object" && (outbound.tls.enabled === true || outbound.tls.enabled == 1);
    let scheme = is_tls ? "https" : "http";
    let auth = "";
    if (as_string(outbound.username) != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password) != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    }

    let params = [];
    if (is_tls && type(outbound.tls) == "object") {
        let tls = outbound.tls;
        if (tls.server_name)
            add_query(params, "sni", tls.server_name);
        if (tls.insecure === true)
            add_query(params, "insecure", "1");
        add_cert_pin_query(params, tls);
    }

    return scheme + "://" + auth + host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}


function serialize_hysteria2(outbound) {
    let port = hysteria2_server_ports_uri(outbound);
    if (port == "" && outbound.server_port != null)
        port = as_string(outbound.server_port);

    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || port == "")
        return "";

    let params = [];
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (tls) {
        add_query(params, "sni", tls.server_name);
        if (tls.insecure === true)
            add_query(params, "insecure", "1");
        if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
            add_query(params, "alpn", join(",", tls.alpn));
        add_cert_pin_query(params, tls);
    }
    if (type(outbound.obfs) == "object") {
        add_query(params, "obfs", outbound.obfs.type);
        add_query(params, "obfs-password", outbound.obfs.password);
    }

    return "hysteria2://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, port) + query_string(params) + fragment(outbound);
}

function serialize_tuic(outbound) {
    let port = as_string(outbound.server_port || "");
    if (as_string(outbound.uuid || "") == "" || as_string(outbound.server || "") == "" || port == "")
        return "";

    let userinfo = as_string(outbound.uuid);
    if (as_string(outbound.password || "") != "")
        userinfo += ":" + outbound.password;

    let params = [];
    let tls = type(outbound.tls) == "object" ? outbound.tls : null;
    if (tls) {
        add_query(params, "sni", tls.server_name);
        if (tls.insecure === true)
            add_query(params, "insecure", "1");
        if (type(tls.alpn) == "array" && length(tls.alpn) > 0)
            add_query(params, "alpn", join(",", tls.alpn));
        add_cert_pin_query(params, tls);
    }
    let cc = as_string(outbound.congestion_control || "");
    if (cc != "" && cc != "bbr")
        add_query(params, "congestion_control", cc);
    let udp_mode = as_string(outbound.udp_relay_mode || "");
    if (udp_mode != "" && udp_mode != "native")
        add_query(params, "udp_relay_mode", udp_mode);
    if (outbound.zero_rtt_handshake === true)
        add_query(params, "zero_rtt_handshake", "1");
    let hb = as_string(outbound.heartbeat || "");
    if (hb != "")
        add_query(params, "heartbeat", hb);

    return "tuic://" + uri_encode(userinfo) + "@" +
        host_port(outbound.server, port) + query_string(params) + fragment(outbound);
}

function serialize_vmess(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";

    let vmess = {
        v: "2",
        ps: as_string(outbound.tag),
        add: as_string(outbound.server),
        port: as_string(outbound.server_port),
        id: as_string(outbound.uuid),
        aid: as_string(outbound.alter_id || 0),
        scy: as_string(outbound.security || "auto"),
        net: "tcp",
        type: "none",
        host: "",
        path: "",
        tls: "",
        sni: ""
    };

    if (type(outbound.tls) == "object" && outbound.tls.enabled !== false) {
        vmess.tls = "tls";
        vmess.sni = as_string(outbound.tls.server_name);
        if (type(outbound.tls.utls) == "object")
            vmess.fp = as_string(outbound.tls.utls.fingerprint);
    }

    if (type(outbound.transport) == "object") {
        vmess.net = as_string(outbound.transport.type || "tcp");
        if (vmess.net == "ws") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.headers) == "object")
                vmess.host = as_string(outbound.transport.headers.Host || outbound.transport.headers.host);
        }
        else if (vmess.net == "grpc") {
            vmess.path = as_string(outbound.transport.service_name);
        }
        else if (vmess.net == "http") {
            vmess.path = as_string(outbound.transport.path);
            if (type(outbound.transport.host) == "array" && length(outbound.transport.host) > 0)
                vmess.host = join(",", outbound.transport.host);
            else
                vmess.host = as_string(outbound.transport.host);
        }
    }

    let encoded = base64_encode(sprintf("%J", vmess));
    return encoded == "" ? "" : "vmess://" + encoded;
}

function serialize_anytls(outbound) {
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_tls_query(params, outbound, true);
    if (outbound.min_idle_session != null)
        add_query(params, "min_idle_session", outbound.min_idle_session);
    if (as_string(outbound.idle_session_check_interval || "") != "")
        add_query(params, "idle_session_check_interval", outbound.idle_session_check_interval);
    if (as_string(outbound.idle_session_timeout || "") != "")
        add_query(params, "idle_session_timeout", outbound.idle_session_timeout);
    return "anytls://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_naive(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let scheme = outbound.quic === true ? "naive+quic" : "naive+https";
    let auth = "";
    if (as_string(outbound.username) != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password) != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    }
    let params = [];
    if (type(outbound.tls) == "object") {
        add_query(params, "sni", outbound.tls.server_name);
        if (outbound.tls.insecure === true)
            add_query(params, "insecure", "1");
        add_cert_pin_query(params, outbound.tls);
    }
    if (as_string(outbound.quic_congestion_control || "") != "")
        add_query(params, "quic_congestion_control", outbound.quic_congestion_control);
    if (outbound.insecure_concurrency != null)
        add_query(params, "insecure_concurrency", outbound.insecure_concurrency);
    return scheme + "://" + auth + host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_snell(outbound) {
    if (as_string(outbound.psk) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    if (outbound.version != null && int(outbound.version) != 5)
        add_query(params, "version", outbound.version);
    if (type(outbound.obfs) == "object" && as_string(outbound.obfs.mode || "") != "") {
        add_query(params, "obfs", outbound.obfs.mode);
        add_query(params, "obfs-host", outbound.obfs.host);
    }
    if (outbound.udp_over_tcp === true)
        add_query(params, "uot", "1");
    return "snell://" + uri_encode(outbound.psk) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_mieru(outbound) {
    if (as_string(outbound.username) == "" || as_string(outbound.password) == "" ||
        as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_query(params, "port", outbound.server_port);
    add_query(params, "protocol", outbound.transport || "TCP");
    if (as_string(outbound.multiplexing || "") != "")
        add_query(params, "multiplexing", outbound.multiplexing);
    let userinfo = uri_encode(outbound.username) + ":" + uri_encode(outbound.password);
    return "mierus://" + userinfo + "@" + host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_mtproto(outbound) {
    if (as_string(outbound.secret) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_query(params, "server", outbound.server);
    add_query(params, "port", outbound.server_port);
    add_query(params, "secret", outbound.secret);
    return "tg://proxy" + query_string(params) + fragment(outbound);
}

function serialize_shadowtls(outbound) {
    if (as_string(outbound.password) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let params = [];
    add_query(params, "version", outbound.version || 3);
    add_tls_query(params, outbound, true);
    return "shadowtls://" + uri_encode(outbound.password) + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_tewfai(outbound) {
    if (as_string(outbound.uuid) == "" || as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let userinfo = uri_encode(outbound.uuid);
    if (as_string(outbound.password || "") != "")
        userinfo += ":" + uri_encode(outbound.password);
    let params = [];
    add_tls_query(params, outbound, true);
    if (type(outbound.transport) == "array" && length(outbound.transport) > 0)
        add_query(params, "transport", join(",", outbound.transport));
    else if (type(outbound.transport) == "string" && outbound.transport != "")
        add_query(params, "transport", outbound.transport);
    add_query(params, "inner_cipher", outbound.inner_cipher);
    add_query(params, "morph_profile", outbound.morph_profile);
    if (outbound.pqc === true || (type(outbound.pqc) == "object" && outbound.pqc.enabled === true))
        add_query(params, "pqc", "1");
    if (outbound.handover === true || (type(outbound.handover) == "object" && outbound.handover.enabled === true))
        add_query(params, "handover", "1");
    if (outbound.fec === true || (type(outbound.fec) == "object" && outbound.fec.enabled === true))
        add_query(params, "fec", "1");
    if (type(outbound.shaper) == "object" && (outbound.shaper.enabled === true || outbound.shaper.mode != null)) {
        add_query(params, "shaper", "1");
        add_query(params, "shaper_profile", outbound.shaper.mode || outbound.shaper.profile);
    }
    return "tewfai://" + userinfo + "@" +
        host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_trusttunnel(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let auth = "";
    if (as_string(outbound.username || "") != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password || "") != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    } else if (as_string(outbound.password || "") != "") {
        auth = uri_encode(outbound.password) + "@";
    }
    let params = [];
    add_tls_query(params, outbound, true);
    if (outbound.quic === true || outbound.quic == "true")
        add_query(params, "quic", "1");
    add_query(params, "quic_congestion_control", outbound.quic_congestion_control);
    return "trusttunnel://" + auth + host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_masque(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let auth = "";
    if (as_string(outbound.username || "") != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password || "") != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    } else if (as_string(outbound.private_key || "") != "") {
        auth = uri_encode(outbound.private_key) + "@";
    }
    let params = [];
    add_tls_query(params, outbound, true);
    add_query(params, "profile", outbound.profile);
    add_query(params, "vhttp", outbound.vhttp);
    add_query(params, "public_key", outbound.public_key);
    add_query(params, "ip", outbound.ip);
    add_query(params, "ipv6", outbound.ipv6);
    add_query(params, "uri", outbound.uri);
    if (outbound.mtu != null)
        add_query(params, "mtu", outbound.mtu);
    return "masque://" + auth + host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_openconnect(outbound) {
    if (as_string(outbound.server) == "" || outbound.server_port == null)
        return "";
    let auth = "";
    if (as_string(outbound.username || "") != "") {
        auth = uri_encode(outbound.username);
        if (as_string(outbound.password || "") != "")
            auth += ":" + uri_encode(outbound.password);
        auth += "@";
    } else if (as_string(outbound.password || "") != "") {
        auth = uri_encode(outbound.password) + "@";
    } else if (as_string(outbound.cookie || "") != "") {
        auth = uri_encode(outbound.cookie) + "@";
    }
    let params = [];
    add_tls_query(params, outbound, true);
    add_query(params, "flavor", outbound.flavor);
    add_query(params, "cookie", outbound.cookie);
    add_query(params, "urlpath", outbound.urlpath);
    add_query(params, "realm", outbound.realm);
    add_query(params, "region", outbound.region);
    add_query(params, "user_agent", outbound.user_agent);
    add_query(params, "local_hostname", outbound.local_hostname);
    add_query(params, "server_cert_pin", outbound.server_cert_pin);
    add_query(params, "address", outbound.address);
    add_query(params, "address_v6", outbound.address_v6);
    if (outbound.ip === true)
        add_query(params, "ip", "1");
    if (outbound.esp === true)
        add_query(params, "esp", "1");
    if (outbound.dtls === true)
        add_query(params, "dtls", "1");
    if (outbound.hip_report === true)
        add_query(params, "hip_report", "1");
    if (outbound.mtu != null)
        add_query(params, "mtu", outbound.mtu);
    return "openconnect://" + auth + host_port(outbound.server, outbound.server_port) + query_string(params) + fragment(outbound);
}

function serialize_outbound_link(outbound) {
    if (type(outbound) != "object")
        return "";

    let outbound_type = as_string(outbound.type);
    if (outbound_type == "vless")
        return serialize_vless(outbound);
    if (outbound_type == "trojan")
        return serialize_trojan(outbound);
    if (outbound_type == "shadowsocks")
        return serialize_shadowsocks(outbound);
    if (outbound_type == "socks")
        return serialize_socks(outbound);
    if (outbound_type == "http")
        return serialize_http(outbound);
    if (outbound_type == "hysteria2")
        return serialize_hysteria2(outbound);
    if (outbound_type == "tuic")
        return serialize_tuic(outbound);
    if (outbound_type == "vmess")
        return serialize_vmess(outbound);
    if (outbound_type == "anytls")
        return serialize_anytls(outbound);
    if (outbound_type == "naive")
        return serialize_naive(outbound);
    if (outbound_type == "snell")
        return serialize_snell(outbound);
    if (outbound_type == "mieru")
        return serialize_mieru(outbound);
    if (outbound_type == "mtproto")
        return serialize_mtproto(outbound);
    if (outbound_type == "shadowtls")
        return serialize_shadowtls(outbound);
    if (outbound_type == "tewfai")
        return serialize_tewfai(outbound);
    if (outbound_type == "trusttunnel")
        return serialize_trusttunnel(outbound);
    if (outbound_type == "masque")
        return serialize_masque(outbound);
    if (outbound_type == "openconnect")
        return serialize_openconnect(outbound);
    return "";
}

function is_copyable_link(value) {
    value = lc(as_string(value));
    let prefixes = [
        "vless://", "vmess://", "trojan://", "ss://", "ssr://",
        "hysteria2://", "hy2://", "tuic://",
        "socks4://", "socks4a://", "socks5://",
        "http://", "https://", "vpn://", "amneziawg://", "awg://",
        "fptn://", "fptnb://", "fptn:", "fptnb:",
        "anytls://", "naive+https://", "naive+quic://",
        "snell://", "mieru://", "mierus://",
        "tg://", "mtproto://", "shadowtls://",
        "tewfai://", "trusttunnel://", "masque://",
        "openconnect://", "anyconnect://"
    ];
    for (let prefix in prefixes) {
        if (starts_with(value, prefix))
            return true;
    }
    return false;
}

function populate_subscription_links(subscription) {
    if (type(subscription) != "object" || type(subscription.outbounds) != "array")
        return 0;

    let changed = 0;
    for (let outbound in subscription.outbounds) {
        if (type(outbound) != "object" || is_copyable_link(outbound.share_link))
            continue;

        let link = serialize_outbound_link(outbound);
        if (link == "")
            continue;

        outbound.share_link = link;
        changed++;
    }

    return changed;
}

function populate_subscription_file(path) {
    path = as_string(path);
    let data = fs.readfile(path);
    if (data == null)
        return false;

    let subscription;
    try {
        subscription = json(data);
    }
    catch (e) {
        return false;
    }

    if (populate_subscription_links(subscription) == 0)
        return true;

    let stamp = clock();
    let tmp_path = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (fs.writefile(tmp_path, sprintf("%J\n", subscription)) == null)
        return false;

    system("chmod 600 " + shell_quote(tmp_path) + " >/dev/null 2>&1");
    if (!fs.rename(tmp_path, path)) {
        fs.unlink(tmp_path);
        return false;
    }

    return true;
}

function populate_subscription_dir(path) {
    path = as_string(path);
    let ok = true;
    for (let file_path in fs.glob(path + "/*.json"))
        if (!populate_subscription_file(file_path))
            ok = false;

    return ok;
}

return {
    serialize_outbound_link,
    is_copyable_link,
    populate_subscription_links,
    populate_subscription_file,
    populate_subscription_dir
};
