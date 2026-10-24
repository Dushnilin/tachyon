// Client URI generation for server subscriptions. No engine configuration is changed.
let common = require("core.common");
let ip = require("core.ip");
let variant_state = require("tachyon_core.variant_state");
let str = common.as_string;

function encode(value) {
    let out = "";
    value = str(value);
    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        out += match(c, /^[A-Za-z0-9_.!~*'()-]$/) ? c : sprintf("%%%02X", ord(value, i));
    }
    return out;
}

function list(value) {
    return type(value) == "array" ? value : (value == null || value == "" ? [] : [ value ]);
}

function host(value) {
    value = trim(str(value));
    if (substr(value, 0, 1) == "[" && substr(value, -1) == "]")
        value = substr(value, 1, length(value) - 2);
    if (ip.valid_ip(value))
        return value;
    if (!value || length(value) > 253) return "";
    for (let label in split(value, "."))
        if (!label || length(label) > 63 || !match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/))
            return "";
    return value;
}

function uri_host(value) {
    return ip.valid_ipv6(value) ? "[" + value + "]" : value;
}

function query(params) {
    let parts = [];
    for (let key, value in params)
        if (value != null && str(value) != "")
            push(parts, encode(key) + "=" + encode(value));
    return length(parts) ? "?" + join("&", parts) : "";
}

function security(s, protocol) {
    if (index([ "shadowsocks", "socks", "http", "mixed", "shadowtls", "mtproto", "mieru" ], protocol) >= 0)
        return "none";
    return s.security || (protocol == "vless" ? "reality" :
        (index([ "trojan", "hysteria2", "tuic", "anytls", "naive", "fptn", "trusttunnel", "tewfai", "masque", "openconnect" ], protocol) >= 0 ? "tls" : "none"));
}

function country_flag(code) {
    code = uc(trim(str(code)));
    if (!match(code, /^[A-Z]{2}$/)) return "";
    return chr(0xF0, 0x9F, 0x87, 0xA6 + ord(code, 0) - 65, 0xF0, 0x9F, 0x87, 0xA6 + ord(code, 1) - 65);
}

function identity(s) {
    let entry = str(list(s.server_users)[0]);
    let parts = split(entry, "|");
    let credential = trim(str(length(parts) > 1 ? parts[1] : parts[0]));
    let raw_name = s.label || s[".name"] || "Tachyon";
    let flag = country_flag(s.server_country);
    let name = (flag != "" && index(raw_name, "\xF0\x9F\x87") < 0) ? (flag + " " + raw_name) : raw_name;
    return {
        name,
        username: s.server_username || s.label || s[".name"] || "user",
        uuid: s.server_uuid || credential,
        password: s.server_password || credential,
        flow: s.vless_flow || trim(str(parts[2]))
    };
}

function transport(s) {
    let kind = s.transport || "tcp";
    let params = { type: kind == "raw" ? "tcp" : kind };
    if (index([ "ws", "httpupgrade", "xhttp", "http" ], kind) >= 0) {
        params.path = s.transport_path || (kind == "xhttp" ? "/" : "");
        params.host = kind == "http" ? join(",", list(s.transport_hosts)) : s.transport_host || "";
    }
    if (kind == "xhttp") params.mode = s.transport_xhttp_mode || "auto";
    if (kind == "grpc") params.serviceName = s.transport_service_name || "";
    return params;
}

function tls_params(s, protocol, address, pin) {
    let params = { sni: s.tls_server_name || (protocol == "hysteria2" ? "" : address) };
    let generated = !match(s.tls_certificate_path || "/etc/tachyon/servers/generated", /^\/etc\/(acme|letsencrypt|ssl\/certs)\//);
    if (generated || pin != "") params.insecure = "1";
    if (pin != "") params[protocol == "hysteria2" ? "pinSHA256" : "pcs"] = pin;
    return params;
}

function vless_trojan(s, user, address, port, pin) {
    let protocol = s.protocol;
    let sec = security(s, protocol);
    let params = transport(s);
    params.security = sec;
    if (protocol == "vless") params.encryption = "none";
    if (sec == "tls" || sec == "reality") {
        params.sni = s.tls_server_name || s.reality_handshake_server || "";
        params.alpn = join(",", list(s.tls_alpn));
    }
    if (sec == "tls") {
        let generated = !match(s.tls_certificate_path || "/etc/tachyon/servers/generated", /^\/etc\/(acme|letsencrypt|ssl\/certs)\//);
        if (generated || pin != "") {
            params.insecure = "1";
            params.allowInsecure = "1";
        }
        if (pin != "") params.pcs = pin;
    }
    if (sec == "reality") {
        params.pbk = s.reality_public_key;
        params.sid = list(s.reality_short_id)[0];
        params.fp = s.client_fingerprint || "chrome";
        if (!params.pbk || !params.sid) return "";
    }
    if (protocol == "vless" && user.flow == "xtls-rprx-vision") params.flow = user.flow;
    let credential = protocol == "vless" ? user.uuid : user.password;
    return credential ? protocol + "://" + encode(credential) + "@" + uri_host(address) + ":" + port + query(params) + "#" + encode(user.name) : "";
}

function vmess(s, user, address, port, pin) {
    if (!user.uuid) return "";
    let t = transport(s);
    let is_tls = security(s, "vmess") == "tls";
    let payload = {
        v: "2", ps: user.name, add: address, port: str(port), id: user.uuid,
        aid: s.vmess_alter_id || "0", scy: "auto", net: t.type, type: "none",
        host: t.host || "", path: t.path || t.serviceName || "",
        tls: is_tls ? "tls" : "",
        sni: s.tls_server_name || "", alpn: join(",", list(s.tls_alpn))
    };
    if (is_tls) {
        let generated = !match(s.tls_certificate_path || "/etc/tachyon/servers/generated", /^\/etc\/(acme|letsencrypt|ssl\/certs)\//);
        if (generated || pin != "") payload.allowInsecure = 1;
        if (pin != "") payload.pcs = pin;
    }
    return "vmess://" + b64enc(sprintf("%J", payload));
}

function password_link(s, user, address, port, pin) {
    let protocol = s.protocol;
    if (!user.password || (protocol == "tuic" && !user.uuid)) return "";
    let params = tls_params(s, protocol, address, pin);
    let credential = encode(user.password);
    if (protocol == "hysteria2" && s.hysteria2_obfs_type == "salamander") {
        params.obfs = "salamander";
        params["obfs-password"] = s.hysteria2_obfs_password || "";
    }
    if (protocol == "tuic") {
        params.congestion_control = s.tuic_congestion_control || "bbr";
        params.alpn = "h3";
        credential = encode(user.uuid) + ":" + credential;
    }
    if (protocol == "shadowtls") params = {
        sni: s.shadowtls_handshake_server || "www.microsoft.com", version: s.shadowtls_version || "3"
    };
    return protocol + "://" + credential + "@" + uri_host(address) + ":" + port + query(params) + "#" + encode(user.name);
}

function mieru(s, inbound, address) {
    let user = inbound.users?.[0];
    let port = int(inbound.listen_port);
    let network = inbound.transport || "TCP";
    if (!user?.name || !user.password || port < 1 || port > 65535 || index([ "TCP", "UDP" ], network) < 0)
        return "";
    let raw_profile = s.label || s[".name"] || "Mieru";
    let flag = country_flag(s.server_country);
    let profile = (flag != "" && index(raw_profile, "\xF0\x9F\x87") < 0) ? (flag + " " + raw_profile) : raw_profile;
    return "mierus://" + encode(user.name) + ":" + encode(user.password) + "@" + uri_host(address) +
        query({ port, protocol: network, profile });
}

function supported(s) {
    let protocol = s.protocol || "vless";
    if (protocol == "json_inbound") {
        try { return json(s.inbound_json || "{}").type == "mieru"; } catch (e) { return false; }
    }
    return index([ "vless", "vmess", "trojan", "shadowsocks", "socks", "mixed", "http", "naive",
        "hysteria2", "tuic", "anytls", "shadowtls", "fptn", "mtproto", "mieru",
        "trusttunnel", "tewfai", "masque", "openconnect", "awg" ], protocol) >= 0;
}

function build(s, fallback_host, pin) {
    let address = host(s.public_host || fallback_host);
    if (!address || !supported(s)) return "";
    let protocol = s.protocol || "vless";
    if (protocol == "json_inbound") return mieru(s, json(s.inbound_json), address);
    let defaults = { shadowsocks: 8388, socks: 1080, http: 8080, mixed: 8080, tuic: 8443, awg: 51820 };
    let port = int(s.listen_port || defaults[protocol] || 443);
    if (port < 1 || port > 65535) return "";
    let user = identity(s);
    pin = match(pin || "", /^[0-9a-f]{64}$/) ? pin : "";
    if (protocol == "vless" || protocol == "trojan") return vless_trojan(s, user, address, port, pin);
    if (protocol == "vmess") return vmess(s, user, address, port, pin);
    if (index([ "hysteria2", "tuic", "anytls", "shadowtls" ], protocol) >= 0)
        return password_link(s, user, address, port, pin);
    if (protocol == "mieru") {
        if (!user.password) return "";
        return "mierus://" + encode(user.username) + ":" + encode(user.password) + "@" + uri_host(address) +
            query({ port, protocol: s.mieru_transport || "TCP", profile: user.name });
    }
    if (protocol == "trusttunnel") {
        if (!user.password) return "";
        let params = tls_params(s, protocol, address, pin);
        if (common.bool_value(s.trusttunnel_quic)) params.quic = "1";
        return "trusttunnel://" + encode(user.username) + ":" + encode(user.password) + "@" + uri_host(address) + ":" + port + query(params) + "#" + encode(user.name);
    }
    if (protocol == "tewfai") {
        let uuid = str(s.tewfai_uuid || user.uuid);
        if (!uuid) return "";
        let pwd = str(s.tewfai_password != null && s.tewfai_password != "" ? s.tewfai_password : user.password);
        let cred = encode(uuid) + (pwd != "" ? ":" + encode(pwd) : "");
        let params = tls_params(s, protocol, address, pin);
        let transports = [];
        for (let tr in list(s.tewfai_inbound_transport)) {
            if (tr == "quic" || tr == "h3_stream" || tr == "h3_datagram") {
                if (index(transports, "quic") < 0) push(transports, "quic");
            }
            else if (tr == "tcp" || tr == "raw_tls" || tr == "h2" || tr == "ws") {
                if (index(transports, "tcp") < 0) push(transports, "tcp");
            }
        }
        if (index(transports, "quic") >= 0 && index(transports, "tcp") < 0)
            push(transports, "tcp");
        if (length(transports) > 0) params.transport = join(",", transports);
        if (s.tewfai_inner_cipher) params.inner_cipher = s.tewfai_inner_cipher;
        if (common.bool_value(s.tewfai_pqc_enabled)) params.pqc = "1";
        if (common.bool_value(s.tewfai_handover_enabled)) params.handover = "1";
        if (common.bool_value(s.tewfai_fec_enabled)) params.fec = "1";
        if (common.bool_value(s.tewfai_shaper_enabled)) {
            params.shaper = "1";
            if (s.tewfai_shaper_profile) params.shaper_profile = s.tewfai_shaper_profile;
        }
        return "tewfai://" + cred + "@" + uri_host(address) + ":" + port + query(params) + "#" + encode(user.name);
    }
    if (protocol == "masque") {
        let params = tls_params(s, protocol, address, pin);
        params.profile = "standard";
        params.uri = "https://" + uri_host(address) + ":" + port + "/.well-known/masque/ip/*/*/";
        let pool4 = list(s.masque_ipv4_pool);
        if (length(pool4) > 0) params.ip = pool4[0];
        let pool6 = list(s.masque_ipv6_pool);
        if (length(pool6) > 0) params.ipv6 = pool6[0];
        if (s.masque_mtu) params.mtu = s.masque_mtu;
        return "masque://" + uri_host(address) + ":" + port + query(params) + "#" + encode(user.name);
    }
    if (protocol == "openconnect") {
        let params = tls_params(s, protocol, address, pin);
        if (s.openconnect_flavor) params.flavor = s.openconnect_flavor;
        if (s.openconnect_cookie) params.cookie = s.openconnect_cookie;
        if (s.openconnect_urlpath) params.urlpath = s.openconnect_urlpath;
        if (s.openconnect_address) params.address = s.openconnect_address;
        if (s.openconnect_mtu) params.mtu = s.openconnect_mtu;
        if (common.bool_value(s.openconnect_ip)) params.ip = "1";
        if (common.bool_value(s.openconnect_esp)) params.esp = "1";
        if (common.bool_value(s.openconnect_dtls)) params.dtls = "1";
        let auth = user.password ? encode(user.username) + ":" + encode(user.password) + "@" : (s.openconnect_cookie ? encode(s.openconnect_cookie) + "@" : "");
        if (!auth) return "";
        return "openconnect://" + auth + uri_host(address) + ":" + port + query(params) + "#" + encode(user.name);
    }
    if (protocol == "shadowsocks") {
        if (!user.password) return "";
        let credential = replace(replace(replace(b64enc((s.shadowsocks_method || "aes-128-gcm") + ":" + user.password), /\+/g, "-"), /\//g, "_"), /=+$/, "");
        return "ss://" + credential + "@" + uri_host(address) + ":" + port + "#" + encode(user.name);
    }
    if (protocol == "mtproto") {
        let secret = common.mtproto_secret_canonical(s.mtproto_secret || user.password, s.mtproto_faketls || "google.com");
        if (secret && (s.mtproto_padding == "0" || variant_state.is_tachyon_core()))
            secret = substr(secret, 2, 32);
        return secret ? "https://t.me/proxy" + query({ server: address, port, secret }) + "#" + encode(user.name) : "";
    }
    if (protocol == "awg") {
        if (!s.awg_client_private_key || !s.awg_server_public_key) return "";
        let conf = "[Interface]\nPrivateKey = " + s.awg_client_private_key +
            "\nAddress = " + (s.awg_client_address || "10.8.0.2/32") +
            (s.awg_dns ? "\nDNS = " + s.awg_dns : "") +
            (s.awg_mtu ? "\nMTU = " + s.awg_mtu : "") +
            "\nJc = " + (s.awg_jc || "4") +
            "\nJmin = " + (s.awg_jmin || "40") +
            "\nJmax = " + (s.awg_jmax || "70") +
            "\nS1 = " + (s.awg_s1 || "0") +
            "\nS2 = " + (s.awg_s2 || "0") +
            (s.awg_s3 ? "\nS3 = " + s.awg_s3 : "") +
            (s.awg_s4 ? "\nS4 = " + s.awg_s4 : "") +
            "\nH1 = " + (s.awg_h1 || "1") +
            "\nH2 = " + (s.awg_h2 || "2") +
            "\nH3 = " + (s.awg_h3 || "3") +
            "\nH4 = " + (s.awg_h4 || "4") +
            (s.awg_header_protection_key ? "\nHeaderProtectionKey = " + s.awg_header_protection_key : "") +
            (s.awg_content_padding_addition ? "\nContentPaddingAddition = " + s.awg_content_padding_addition : "") +
            (s.awg_rekey_after_time ? "\nRekeyAfterTime = " + s.awg_rekey_after_time : "") +
            (s.awg_rekey_timeout ? "\nRekeyTimeout = " + s.awg_rekey_timeout : "") +
            (s.awg_reject_after_time ? "\nRejectAfterTime = " + s.awg_reject_after_time : "") +
            (s.awg_keepalive_timeout ? "\nKeepaliveTimeout = " + s.awg_keepalive_timeout : "") +
            (s.awg_max_handshake_attempts ? "\nMaxHandshakeAttempts = " + s.awg_max_handshake_attempts : "") +
            "\n\n[Peer]\nPublicKey = " + s.awg_server_public_key +
            (s.awg_preshared_key ? "\nPresharedKey = " + s.awg_preshared_key : "") +
            "\nEndpoint = " + uri_host(address) + ":" + port +
            "\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = " + (s.awg_keepalive || "25") + "\n";
        return "amneziawg://" + replace(b64enc(conf), /=+$/, "") + "#" + encode(user.name);
    }
    if (protocol == "fptn") {
        if (!user.password) return "";
        let payload = { version: 1, service_name: "Tachyon", username: user.username, password: user.password,
            servers: [{ name: user.name, host: address, port, md5_fingerprint: "" }], censored_zone_servers: [] };
        return "fptn://" + replace(b64enc(sprintf("%J", payload)), /=+$/, "") + "#" + encode(user.name);
    }
    let scheme = protocol == "mixed" || protocol == "socks" ? "socks5" : (protocol == "naive" ? "naive+https" : "http");
    let auth = scheme == "socks5" ? common.bool_value(s.socks_auth_enabled ?? "1") : user.password != "";
    if (protocol == "naive" && !user.password) return "";
    let credential = auth ? encode(user.username) + ":" + encode(user.password) + "@" : "";
    let naive_query = protocol == "naive" ? query({ sni: s.tls_server_name || address, pcs: pin }) : "";
    return scheme + "://" + credential + uri_host(address) + ":" + port + naive_query + "#" + encode(user.name);
}

return { build, encode, host, supported };
