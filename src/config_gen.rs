//! Master `tachyon-core` JSON configuration compiler (`/etc/tachyon-core/config.json`),
//! universal proxy URI parser (`vless://`, `vmess://`, `ss://`, `trojan://`,
//! `hysteria2://`, `tuic://`, `wg://`, `awg://`, `fptn://`), and router inbound share-link generator.
//!
//! Strictly pure `tachyon-core` target — no legacy compatibility hacks and no
//! external `zapret`/`zapret2`/`byedpi`/`wdtt`/`olcrtc`/`tailscale` processes.

use std::collections::{HashMap, HashSet};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD as B64_STD, URL_SAFE_NO_PAD as B64_URL};
use serde_json::{Map, Value, json};

use crate::store::{
    BalancerConfig, InboundClient, InboundServer, OutboundGroup, OutboundSource, ParsedProxyNode,
    RouterStoreData, RoutingSection, TrafficCondition, parse_csqtt_hashes_tokens, unix_now_secs,
    url_encode_component,
};

/// Universal URI parser converting a proxy link into a `ParsedProxyNode` with native `tachyon-core` JSON.
pub fn parse_proxy_uri(uri: &str, idx: usize) -> Option<ParsedProxyNode> {
    let uri = uri.trim();
    if uri.is_empty() || uri.starts_with('#') {
        return None;
    }
    let (scheme, rest) = uri.split_once("://")?;
    let scheme_lower = scheme.to_ascii_lowercase();

    if matches!(scheme_lower.as_str(), "csqtt" | "wdtt" | "qwdtt") {
        return parse_wdtt_uri(uri, &scheme_lower, rest, idx);
    }
    if scheme_lower == "vmess" {
        return parse_vmess_uri(uri, rest, idx);
    }
    if matches!(scheme_lower.as_str(), "mieru" | "mierus") {
        return parse_mieru_uri(uri, &scheme_lower, rest);
    }
    if scheme_lower == "vpn" {
        return parse_vpn_uri(uri, rest, idx);
    }
    if (scheme_lower == "fptn" || scheme_lower == "fptnb")
        && let Some(decoded) = decode_fptn_token_json(uri)
        && let Some(first_srv) = decoded
            .get("servers")
            .and_then(Value::as_array)
            .and_then(|arr| arr.first())
    {
        let host = first_srv
            .get("host")
            .and_then(Value::as_str)
            .unwrap_or("127.0.0.1")
            .to_string();
        let port = first_srv.get("port").and_then(Value::as_u64).unwrap_or(443) as u16;
        let srv_name = first_srv
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(&host);
        let tag = format!("fptn-{srv_name}");
        let country = detect_country_code(&tag);
        let mut obj = Map::new();
        obj.insert("type".into(), json!("fptn"));
        obj.insert("tag".into(), json!(tag));
        obj.insert("server".into(), json!(host));
        obj.insert("server_port".into(), json!(port));
        if let Some(u) = decoded.get("username").and_then(Value::as_str) {
            obj.insert("username".into(), json!(u));
        }
        if let Some(p) = decoded.get("password").and_then(Value::as_str) {
            obj.insert("password".into(), json!(p));
        }
        if let Some(fp) = first_srv
            .get("md5_fingerprint")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            obj.insert("md5_fingerprint".into(), json!(fp));
        }
        return Some(ParsedProxyNode {
            tag,
            protocol: "fptn".to_string(),
            server: host,
            server_port: port,
            country,
            raw_uri: uri.to_string(),
            outbound_json: Value::Object(obj),
        });
    }

    let (before_hash, raw_tag) = match rest.split_once('#') {
        Some((b, t)) => (b, url_decode(t)),
        None => (rest, String::new()),
    };
    let (authority_and_path, query_str) = match before_hash.split_once('?') {
        Some((a, q)) => (a, q),
        None => (before_hash, ""),
    };
    let params = parse_query_params(query_str);

    let (userinfo, host_port_path) = match authority_and_path.rsplit_once('@') {
        Some((u, hp)) => (url_decode(u), hp),
        None => (String::new(), authority_and_path),
    };
    let host_port = host_port_path.split('/').next().unwrap_or(host_port_path);
    let (host, port) = split_host_port(host_port, 443)?;

    let tag = if !raw_tag.trim().is_empty() {
        raw_tag.trim().to_string()
    } else {
        format!("{scheme_lower}-{host}:{port}-{idx}")
    };
    let country = detect_country_code(&tag);

    let outbound_json = match scheme_lower.as_str() {
        "vless" => {
            let mut obj = Map::new();
            obj.insert("type".into(), json!("vless"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(host));
            obj.insert("server_port".into(), json!(port));
            obj.insert("uuid".into(), json!(userinfo));
            if let Some(flow) = params.get("flow").filter(|s| !s.is_empty()) {
                obj.insert("flow".into(), json!(flow));
            }
            if let Some(enc) = params
                .get("encryption")
                .filter(|s| !s.is_empty() && *s != "none")
            {
                obj.insert("encryption".into(), json!(enc));
            }
            if let Some(tls) = build_tls_object(&params, &host) {
                obj.insert("tls".into(), tls);
            }
            if let Some(tr) = build_transport_object(&params) {
                obj.insert("transport".into(), tr);
            }
            Value::Object(obj)
        }
        "trojan" => {
            let mut obj = Map::new();
            obj.insert("type".into(), json!("trojan"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(host));
            obj.insert("server_port".into(), json!(port));
            obj.insert("password".into(), json!(userinfo));
            if let Some(tls) = build_tls_object(&params, &host) {
                obj.insert("tls".into(), tls);
            }
            if let Some(tr) = build_transport_object(&params) {
                obj.insert("transport".into(), tr);
            }
            Value::Object(obj)
        }
        "ss" | "shadowsocks" => {
            let (method, password) = decode_ss_userinfo(&userinfo)?;
            json!({
                "type": "shadowsocks",
                "tag": tag,
                "server": host,
                "server_port": port,
                "method": method,
                "password": password,
            })
        }
        "hysteria2" | "hy2" => {
            let sni = params.get("sni").cloned().unwrap_or_else(|| host.clone());
            let insecure = params
                .get("insecure")
                .is_some_and(|v| v == "1" || v == "true");
            let mut obj = Map::new();
            obj.insert("type".into(), json!("hysteria2"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(host));
            obj.insert("server_port".into(), json!(port));
            obj.insert("password".into(), json!(userinfo));
            obj.insert(
                "tls".into(),
                json!({
                    "enabled": true,
                    "server_name": sni,
                    "insecure": insecure,
                    "alpn": ["h3"]
                }),
            );
            if let Some(obfs) = params.get("obfs").filter(|s| !s.is_empty() && *s != "none") {
                obj.insert(
                    "obfs".into(),
                    json!({
                        "type": obfs,
                        "password": params.get("obfs-password").cloned().unwrap_or_default()
                    }),
                );
            }
            Value::Object(obj)
        }
        "tuic" => {
            let (uuid, password) = userinfo.split_once(':').unwrap_or((userinfo.as_str(), ""));
            let sni = params.get("sni").cloned().unwrap_or_else(|| host.clone());
            json!({
                "type": "tuic",
                "tag": tag,
                "server": host,
                "server_port": port,
                "uuid": uuid,
                "password": password,
                "congestion_control": params.get("congestion_control").cloned().unwrap_or_else(|| "bbr".to_string()),
                "tls": {
                    "enabled": true,
                    "server_name": sni,
                    "alpn": ["h3"]
                }
            })
        }
        "anytls" => {
            let sni = params.get("sni").cloned().unwrap_or_else(|| host.clone());
            json!({
                "type": "anytls",
                "tag": tag,
                "server": host,
                "server_port": port,
                "password": userinfo,
                "tls": {
                    "enabled": true,
                    "server_name": sni
                }
            })
        }
        "wg" | "wireguard" | "awg" => {
            let mut obj = Map::new();
            obj.insert("type".into(), json!("wireguard"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(host));
            obj.insert("server_port".into(), json!(port));
            obj.insert("private_key".into(), json!(userinfo));
            if let Some(pk) = params.get("publickey").or_else(|| params.get("public_key")) {
                obj.insert("peer_public_key".into(), json!(pk));
            }
            let addr = params
                .get("address")
                .cloned()
                .unwrap_or_else(|| "10.0.0.2/32".to_string());
            obj.insert("local_address".into(), json!([addr]));
            if let Some(ports) = params.get("server_ports").filter(|s| !s.is_empty()) {
                let list: Vec<&str> = ports.split(',').collect();
                obj.insert("server_ports".into(), json!(list));
            }
            if let Some(hop) = params.get("hop_interval").filter(|s| !s.is_empty()) {
                obj.insert("hop_interval".into(), json!(hop));
            }
            for awg_key in ["jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"] {
                if let Some(v) = params.get(awg_key).and_then(|s| s.parse::<i64>().ok()) {
                    obj.insert(awg_key.into(), json!(v));
                }
            }
            for cps_key in ["i1", "i2", "i3", "i4", "i5", "j1", "j2", "j3", "itime"] {
                if let Some(v) = params.get(cps_key).filter(|s| !s.is_empty()) {
                    obj.insert(cps_key.into(), json!(v));
                }
            }
            Value::Object(obj)
        }
        "fptn" => {
            json!({
                "type": "fptn",
                "tag": tag,
                "server": host,
                "server_port": port,
                "token": userinfo,
                "sni": params.get("sni").cloned().unwrap_or_else(|| host.clone()),
            })
        }
        "socks" | "socks5" | "http" => {
            let (u, p) = userinfo.split_once(':').unwrap_or((userinfo.as_str(), ""));
            let mut obj = Map::new();
            obj.insert(
                "type".into(),
                json!(if scheme_lower == "http" {
                    "http"
                } else {
                    "socks"
                }),
            );
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(host));
            obj.insert("server_port".into(), json!(port));
            if !u.is_empty() {
                obj.insert("username".into(), json!(u));
                obj.insert("password".into(), json!(p));
            }
            Value::Object(obj)
        }
        "tailscale" => {
            let mut obj = Map::new();
            obj.insert("type".into(), json!("tailscale"));
            obj.insert("tag".into(), json!(tag));
            if !userinfo.trim().is_empty() {
                obj.insert("auth_key".into(), json!(userinfo.trim()));
            }
            if !host.trim().is_empty() {
                obj.insert("hostname".into(), json!(host.trim()));
            }
            if let Some(cu) = params.get("control_url").filter(|s| !s.trim().is_empty()) {
                obj.insert("control_url".into(), json!(cu.trim()));
            }
            if let Some(en) = params
                .get("exit_node")
                .or_else(|| params.get("use_exit_node"))
                .filter(|s| !s.trim().is_empty())
            {
                obj.insert("exit_node".into(), json!(en.trim()));
            }
            if params
                .get("accept_routes")
                .is_some_and(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            {
                obj.insert("accept_routes".into(), json!(true));
            }
            if params
                .get("ephemeral")
                .is_some_and(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            {
                obj.insert("ephemeral".into(), json!(true));
            }
            Value::Object(obj)
        }
        _ => return None,
    };

    Some(ParsedProxyNode {
        tag,
        protocol: scheme_lower,
        server: host,
        server_port: port,
        country,
        raw_uri: uri.to_string(),
        outbound_json,
    })
}

fn url_decode_percent(s: &str) -> String {
    let mut bytes = Vec::with_capacity(s.len());
    let raw = s.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%'
            && i + 2 < raw.len()
            && let (Some(hi), Some(lo)) = (
                (raw[i + 1] as char).to_digit(16),
                (raw[i + 2] as char).to_digit(16),
            )
        {
            bytes.push(((hi << 4) | lo) as u8);
            i += 3;
            continue;
        }
        bytes.push(raw[i]);
        i += 1;
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn decode_b64_flex(s: &str) -> Option<Vec<u8>> {
    let clean: String = s
        .trim()
        .trim_end_matches('/')
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    if clean.is_empty() {
        return None;
    }
    let mut padded = clean.replace('-', "+").replace('_', "/");
    while !padded.len().is_multiple_of(4) {
        padded.push('=');
    }
    B64_STD
        .decode(&padded)
        .or_else(|_| B64_URL.decode(clean.trim_end_matches('=')))
        .ok()
}

fn parse_wdtt_port_val(raw: &str) -> Option<u16> {
    let p: u16 = raw.trim().parse().ok()?;
    (p >= 1).then_some(p)
}

fn parse_json_u16(val: &Value) -> Option<u16> {
    val.as_u64()
        .and_then(|n| u16::try_from(n).ok())
        .filter(|&p| p >= 1)
        .or_else(|| val.as_str().and_then(parse_wdtt_port_val))
}

fn strip_ipv6_brackets(host: &str) -> String {
    let t = host.trim();
    if t.starts_with('[') && t.ends_with(']') && t.len() >= 2 {
        t[1..t.len() - 1].trim().to_string()
    } else {
        t.to_string()
    }
}

fn parse_csqtt_v2_peer(raw: &str) -> (String, Option<u16>) {
    let s = raw.trim();
    if s.is_empty() {
        return (String::new(), None);
    }
    if s.bytes().all(|b| b.is_ascii_digit())
        && let Some(p) = parse_wdtt_port_val(s)
    {
        return (String::new(), Some(p));
    }
    if let Some(stripped) = s.strip_prefix('[') {
        if let Some((h, port_str)) = stripped.split_once("]:") {
            return (h.trim().to_string(), parse_wdtt_port_val(port_str));
        }
        if s.ends_with(']') {
            return (strip_ipv6_brackets(s), None);
        }
    }
    if let Some((h, p_str)) = s.rsplit_once(':')
        && !h.contains(':')
        && let Some(port) = parse_wdtt_port_val(p_str)
    {
        return (h.trim().to_string(), Some(port));
    }
    (strip_ipv6_brackets(s), None)
}

fn parse_csqtt_v2_pairs(query: &str) -> Vec<(String, String)> {
    if query.contains('&') {
        return query
            .split('&')
            .filter(|part| !part.is_empty())
            .filter_map(|part| {
                let (k, v) = part.split_once('=')?;
                (!k.is_empty()).then(|| (k.to_string(), v.to_string()))
            })
            .collect();
    }

    const KNOWN_KEYS: &[&str] = &[
        "turn_transport=",
        "turn_username=",
        "turn_password=",
        "turn_server=",
        "device_id=",
        "srtp_mode=",
        "vk_token=",
        "password=",
        "streams=",
        "workers=",
        "server=",
        "hashes=",
        "chunk1=",
        "token=",
        "hash=",
        "host=",
        "peer=",
        "port=",
        "pass=",
        "obfs=",
        "srtp=",
        "mode=",
        "name=",
        "did=",
        "mtu=",
        "ip=",
        "v=",
    ];

    let bytes = query.as_bytes();
    let mut spans: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if !query.is_char_boundary(i) {
            i += 1;
            continue;
        }
        let rest_lc = query[i..].to_ascii_lowercase();
        let matched = KNOWN_KEYS.iter().copied().find(|k| {
            if *k == "v=" && i > 0 {
                return false;
            }
            rest_lc.starts_with(k)
        });
        if let Some(k) = matched {
            spans.push((i, i + k.len()));
            i += k.len();
        } else {
            i += 1;
        }
    }

    if spans.is_empty() {
        return query
            .split_once('=')
            .filter(|(k, _)| !k.is_empty())
            .map(|(k, v)| vec![(k.to_string(), v.to_string())])
            .unwrap_or_default();
    }

    spans
        .iter()
        .enumerate()
        .map(|(idx, &(k_start, val_start))| {
            let val_end = spans.get(idx + 1).map_or(query.len(), |&(next, _)| next);
            let k_name = &query[k_start..val_start - 1];
            let val = &query[val_start..val_end];
            (k_name.to_string(), val.to_string())
        })
        .collect()
}

struct WdttParams<'a> {
    server: &'a str,
    server_port: u16,
    password: &'a str,
    mode: &'a str,
    obfs: &'a str,
    raw_port: u16,
    wg_port: u16,
    local_port: u16,
    hashes: &'a [String],
    vk_auth_mode: &'a str,
    vk_cookie: &'a str,
    vk_client_ids: &'a [String],
    turn_server: &'a str,
    turn_urls: &'a [String],
    turn_username: &'a str,
    turn_password: &'a str,
    turn_transport: &'a str,
    workers: u16,
    device_id: &'a str,
    mtu: u16,
    chunk1: bool,
    wg_private_key: &'a str,
    wg_peer_public_key: &'a str,
    wg_address: &'a str,
}

fn build_wdtt_outbound_value(tag: &str, p: &WdttParams<'_>) -> Option<Value> {
    let server = p.server.trim();
    if server.is_empty() || p.password.is_empty() {
        return None;
    }
    let mode_lc = p.mode.trim().to_ascii_lowercase();
    let mode = match mode_lc.as_str() {
        "wg" | "raw" | "csqtt" | "csqtt_v1" => mode_lc.as_str(),
        _ => "csqtt",
    };
    let default_port = if mode == "wg" || mode == "raw" {
        56000
    } else {
        46000
    };
    let port = if p.server_port > 0 {
        p.server_port
    } else {
        default_port
    };

    let mut obj = Map::new();
    obj.insert("type".into(), json!("wdtt"));
    obj.insert("tag".into(), json!(tag));
    obj.insert("server".into(), json!(server));
    obj.insert("server_port".into(), json!(port));
    obj.insert("password".into(), json!(p.password));
    obj.insert("mode".into(), json!(mode));
    if p.raw_port > 0 {
        obj.insert("raw_port".into(), json!(p.raw_port));
    }
    if p.wg_port > 0 {
        obj.insert("wg_port".into(), json!(p.wg_port));
    }
    if p.local_port > 0 {
        obj.insert("local_port".into(), json!(p.local_port));
    }
    let obfs = p.obfs.trim().to_ascii_lowercase();
    if matches!(obfs.as_str(), "audio" | "video" | "unified") {
        obj.insert("obfs".into(), json!(obfs));
    }
    if !p.hashes.is_empty() {
        obj.insert("hashes".into(), json!(p.hashes));
    }
    let vk_auth = p.vk_auth_mode.trim().to_ascii_lowercase();
    if !vk_auth.is_empty() {
        obj.insert("vk_auth_mode".into(), json!(vk_auth));
    }
    if !p.vk_cookie.is_empty() {
        obj.insert("vk_cookie".into(), json!(p.vk_cookie));
    }
    if !p.vk_client_ids.is_empty() {
        obj.insert("vk_client_ids".into(), json!(p.vk_client_ids));
    }
    if !p.turn_server.trim().is_empty() {
        obj.insert("turn_server".into(), json!(p.turn_server.trim()));
    }
    if !p.turn_urls.is_empty() {
        obj.insert("turn_urls".into(), json!(p.turn_urls));
    }
    if !p.turn_username.is_empty() {
        obj.insert("turn_username".into(), json!(p.turn_username));
    }
    if !p.turn_password.is_empty() {
        obj.insert("turn_password".into(), json!(p.turn_password));
    }
    let turn_tr = p.turn_transport.trim().to_ascii_lowercase();
    if matches!(turn_tr.as_str(), "auto" | "tcp" | "udp" | "tcp_tls" | "tls") {
        obj.insert("turn_transport".into(), json!(turn_tr));
    }
    if (1..=126).contains(&p.workers) {
        obj.insert("workers".into(), json!(p.workers));
    }
    if !p.device_id.trim().is_empty() {
        obj.insert("device_id".into(), json!(p.device_id.trim()));
    }
    if (576..=1500).contains(&p.mtu) {
        obj.insert("mtu".into(), json!(p.mtu));
    }
    if p.chunk1 {
        obj.insert("chunk1".into(), json!(true));
    }
    if !p.wg_private_key.trim().is_empty() {
        obj.insert("wg_private_key".into(), json!(p.wg_private_key.trim()));
    }
    if !p.wg_peer_public_key.trim().is_empty() {
        obj.insert(
            "wg_peer_public_key".into(),
            json!(p.wg_peer_public_key.trim()),
        );
    }
    if !p.wg_address.trim().is_empty() {
        obj.insert("wg_address".into(), json!(p.wg_address.trim()));
    }
    Some(Value::Object(obj))
}

fn make_wdtt_node(
    full_uri: &str,
    frag_tag: &str,
    name_fallback: &str,
    default_prefix: &str,
    p: &WdttParams<'_>,
) -> Option<ParsedProxyNode> {
    let server = strip_ipv6_brackets(p.server);
    if server.is_empty() || p.password.is_empty() {
        return None;
    }
    let port = if p.server_port > 0 {
        p.server_port
    } else if p.mode == "wg" || p.mode == "raw" {
        56000
    } else {
        46000
    };
    let tag = if !frag_tag.is_empty() {
        frag_tag.to_string()
    } else if !name_fallback.trim().is_empty() {
        name_fallback.trim().to_string()
    } else {
        format!("{default_prefix}-{server}:{port}")
    };
    let mut normalized = WdttParams {
        server: &server,
        server_port: port,
        password: p.password,
        mode: p.mode,
        obfs: p.obfs,
        raw_port: p.raw_port,
        wg_port: p.wg_port,
        local_port: p.local_port,
        hashes: p.hashes,
        vk_auth_mode: p.vk_auth_mode,
        vk_cookie: p.vk_cookie,
        vk_client_ids: p.vk_client_ids,
        turn_server: p.turn_server,
        turn_urls: p.turn_urls,
        turn_username: p.turn_username,
        turn_password: p.turn_password,
        turn_transport: p.turn_transport,
        workers: p.workers,
        device_id: p.device_id,
        mtu: p.mtu,
        chunk1: p.chunk1,
        wg_private_key: p.wg_private_key,
        wg_peer_public_key: p.wg_peer_public_key,
        wg_address: p.wg_address,
    };
    if normalized.mode.is_empty() {
        normalized.mode = "wg";
    }
    let outbound_json = build_wdtt_outbound_value(&tag, &normalized)?;
    let country = detect_country_code(&tag);
    Some(ParsedProxyNode {
        tag,
        protocol: "wdtt".to_string(),
        server,
        server_port: port,
        country,
        raw_uri: full_uri.to_string(),
        outbound_json,
    })
}

fn parse_wdtt_uri(
    full_uri: &str,
    scheme_lower: &str,
    rest: &str,
    _idx: usize,
) -> Option<ParsedProxyNode> {
    let (body, frag_tag) = match rest.split_once('#') {
        Some((b, f)) => (b.trim(), url_decode_percent(f).trim().to_string()),
        None => (rest.trim(), String::new()),
    };
    if body.is_empty() {
        return None;
    }

    let body_lc = body.to_ascii_lowercase();

    // 0. csqtt://connect?v=2&host=...&peer=...&password=...
    if scheme_lower == "csqtt" && (body_lc.starts_with("connect?") || body_lc == "connect") {
        let query = body.split_once('?').map_or("", |(_, q)| q);
        let mut params: HashMap<String, String> = HashMap::new();
        for (k_raw, v_raw) in parse_csqtt_v2_pairs(query) {
            let k = k_raw.trim().to_ascii_lowercase();
            if k.is_empty() {
                continue;
            }
            let v = if k == "hashes" || k == "hash" {
                url_decode_percent(&v_raw)
            } else {
                url_decode(&v_raw)
            };
            params.insert(k, v);
        }
        let (peer_host, peer_port) = params
            .get("peer")
            .map(|s| parse_csqtt_v2_peer(s))
            .unwrap_or_default();
        let server = params
            .get("host")
            .or_else(|| params.get("server"))
            .or_else(|| params.get("ip"))
            .map(|s| strip_ipv6_brackets(s))
            .filter(|s| !s.is_empty())
            .unwrap_or(peer_host);
        let password = params
            .get("password")
            .or_else(|| params.get("pass"))
            .cloned()
            .unwrap_or_default();
        if server.is_empty() || password.is_empty() {
            return None;
        }
        let server_port = peer_port
            .or_else(|| params.get("port").and_then(|s| parse_wdtt_port_val(s)))
            .unwrap_or(46000);
        let mode_lc = params
            .get("mode")
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_default();
        let mode = if matches!(mode_lc.as_str(), "csqtt_v1" | "wg" | "raw") {
            mode_lc
        } else if params.get("v").is_some_and(|v| v.trim() == "1") {
            "csqtt_v1".to_string()
        } else {
            "csqtt".to_string()
        };
        let hashes = params
            .get("hashes")
            .or_else(|| params.get("hash"))
            .map(|raw| parse_csqtt_hashes_tokens([raw.as_str()]))
            .unwrap_or_default();
        let workers = params
            .get("workers")
            .or_else(|| params.get("streams"))
            .and_then(|s| s.trim().parse::<u16>().ok())
            .filter(|&w| (1..=126).contains(&w))
            .unwrap_or(0);
        let mtu = params
            .get("mtu")
            .and_then(|s| s.trim().parse::<u16>().ok())
            .filter(|&m| (576..=1500).contains(&m))
            .unwrap_or(0);
        let raw_port = params
            .get("raw_port")
            .or_else(|| params.get("raw"))
            .and_then(|s| parse_wdtt_port_val(s))
            .unwrap_or(0);
        let chunk1 = params.get("chunk1").is_some_and(|v| {
            matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes")
        });
        return make_wdtt_node(
            full_uri,
            &frag_tag,
            params.get("name").map_or("", String::as_str),
            "csqtt",
            &WdttParams {
                server: &server,
                server_port,
                password: &password,
                mode: &mode,
                obfs: params.get("obfs").map_or("", String::as_str),
                raw_port,
                wg_port: 0,
                local_port: 0,
                hashes: &hashes,
                vk_auth_mode: "",
                vk_cookie: "",
                vk_client_ids: &[],
                turn_server: params.get("turn_server").map_or("", String::as_str),
                turn_urls: &[],
                turn_username: params.get("turn_username").map_or("", String::as_str),
                turn_password: params.get("turn_password").map_or("", String::as_str),
                turn_transport: params.get("turn_transport").map_or("", String::as_str),
                workers,
                device_id: params
                    .get("did")
                    .or_else(|| params.get("device_id"))
                    .map_or("", String::as_str),
                mtu,
                chunk1,
                wg_private_key: "",
                wg_peer_public_key: "",
                wg_address: "",
            },
        );
    }

    // 1. qwdtt://config?ip=...&dtls=...&hashes=...&pass=<unencoded_password>
    if scheme_lower == "qwdtt" {
        let query_raw = body.split_once('?').map_or(body, |(_, q)| q);
        let (head_q, raw_pass) = if let Some((head, tail)) = query_raw.split_once("&pass=") {
            (head, Some(url_decode_percent(tail)))
        } else if let Some(tail) = query_raw.strip_prefix("pass=") {
            ("", Some(url_decode_percent(tail)))
        } else {
            (query_raw, None)
        };
        let mut params = parse_query_params(head_q);
        if let Some(p) = raw_pass {
            params.insert("pass".to_string(), p);
        }
        let server = params
            .get("ip")
            .or_else(|| params.get("server"))
            .or_else(|| params.get("host"))
            .map(|s| strip_ipv6_brackets(s))
            .unwrap_or_default();
        let password = params
            .get("pass")
            .or_else(|| params.get("password"))
            .cloned()
            .unwrap_or_default();
        if server.is_empty() || password.is_empty() {
            return None;
        }
        let mode_lc = params
            .get("mode")
            .or_else(|| params.get("vpn"))
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_default();
        let mode = match mode_lc.as_str() {
            "raw" | "csqtt" | "csqtt_v1" => mode_lc,
            _ => "wg".to_string(),
        };
        let dtls_port = params
            .get("dtls")
            .or_else(|| params.get("port"))
            .and_then(|s| parse_wdtt_port_val(s))
            .unwrap_or(if mode == "csqtt" || mode == "csqtt_v1" {
                46000
            } else {
                56000
            });
        let raw_port = params
            .get("raw")
            .and_then(|s| parse_wdtt_port_val(s))
            .unwrap_or(0);
        let server_port = if mode == "raw" && raw_port > 0 {
            raw_port
        } else {
            dtls_port
        };
        let hashes = params
            .get("hashes")
            .or_else(|| params.get("hash"))
            .map(|raw| parse_csqtt_hashes_tokens([raw.as_str()]))
            .unwrap_or_default();
        let workers = params
            .get("streams")
            .or_else(|| params.get("workers"))
            .and_then(|s| s.trim().parse::<u16>().ok())
            .filter(|&w| (1..=126).contains(&w))
            .unwrap_or(0);
        return make_wdtt_node(
            full_uri,
            &frag_tag,
            params.get("name").map_or("", String::as_str),
            "wdtt",
            &WdttParams {
                server: &server,
                server_port,
                password: &password,
                mode: &mode,
                obfs: params.get("obfs").map_or("", String::as_str),
                raw_port,
                wg_port: 0,
                local_port: 0,
                hashes: &hashes,
                vk_auth_mode: "",
                vk_cookie: "",
                vk_client_ids: &[],
                turn_server: "",
                turn_urls: &[],
                turn_username: "",
                turn_password: "",
                turn_transport: "",
                workers,
                device_id: "",
                mtu: 0,
                chunk1: false,
                wg_private_key: "",
                wg_peer_public_key: "",
                wg_address: "",
            },
        );
    }

    // 2. Base64 / URL-safe Base64 JSON: wdtt://eyJ... or csqtt://eyJ...
    let b64_candidate = body.trim_end_matches('/');
    if !b64_candidate.contains(':')
        && !b64_candidate.contains('?')
        && !b64_candidate.contains('@')
        && let Some(decoded) = decode_b64_flex(b64_candidate)
        && let Ok(Value::Object(jmap)) = serde_json::from_slice::<Value>(&decoded)
    {
        let server = jmap
            .get("ip")
            .or_else(|| jmap.get("add"))
            .or_else(|| jmap.get("server"))
            .or_else(|| jmap.get("host"))
            .and_then(Value::as_str)
            .map(strip_ipv6_brackets)
            .unwrap_or_default();
        let password = jmap
            .get("pass")
            .or_else(|| jmap.get("id"))
            .or_else(|| jmap.get("password"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if server.is_empty() || password.is_empty() {
            return None;
        }
        let raw_mode = jmap
            .get("vpn")
            .or_else(|| jmap.get("mode"))
            .and_then(Value::as_str)
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_default();
        let mode = if scheme_lower == "csqtt" {
            if raw_mode == "csqtt_v1" {
                "csqtt_v1".to_string()
            } else {
                "csqtt".to_string()
            }
        } else if matches!(raw_mode.as_str(), "raw" | "csqtt" | "csqtt_v1") {
            raw_mode
        } else {
            "wg".to_string()
        };
        let dtls_port = jmap
            .get("dtls")
            .or_else(|| jmap.get("port"))
            .and_then(parse_json_u16)
            .unwrap_or(if mode == "csqtt" || mode == "csqtt_v1" {
                46000
            } else {
                56000
            });
        let raw_port = jmap.get("raw").and_then(parse_json_u16).unwrap_or(0);
        let server_port = if mode == "raw" {
            if raw_port > 0 {
                raw_port
            } else if dtls_port <= 65532 {
                dtls_port + 3
            } else {
                dtls_port
            }
        } else {
            dtls_port
        };
        let hashes = match jmap.get("hash").or_else(|| jmap.get("hashes")) {
            Some(Value::String(s)) => parse_csqtt_hashes_tokens([s.as_str()]),
            Some(Value::Array(arr)) => {
                let items: Vec<&str> = arr.iter().filter_map(Value::as_str).collect();
                parse_csqtt_hashes_tokens(items)
            }
            _ => Vec::new(),
        };
        let workers = jmap
            .get("workers")
            .or_else(|| jmap.get("streams"))
            .and_then(parse_json_u16)
            .filter(|&w| (1..=126).contains(&w))
            .unwrap_or(0);
        let mtu = jmap
            .get("mtu")
            .and_then(parse_json_u16)
            .filter(|&m| (576..=1500).contains(&m))
            .unwrap_or(0);
        let turn_urls: Vec<String> = jmap
            .get("turn_urls")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        return make_wdtt_node(
            full_uri,
            &frag_tag,
            jmap.get("name")
                .or_else(|| jmap.get("ps"))
                .and_then(Value::as_str)
                .unwrap_or(""),
            "wdtt",
            &WdttParams {
                server: &server,
                server_port,
                password: &password,
                mode: &mode,
                obfs: jmap.get("obfs").and_then(Value::as_str).unwrap_or(""),
                raw_port,
                wg_port: 0,
                local_port: 0,
                hashes: &hashes,
                vk_auth_mode: "",
                vk_cookie: "",
                vk_client_ids: &[],
                turn_server: jmap
                    .get("turn_server")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                turn_urls: &turn_urls,
                turn_username: jmap
                    .get("turn_username")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                turn_password: jmap
                    .get("turn_password")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                turn_transport: jmap
                    .get("turn_transport")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                workers,
                device_id: jmap
                    .get("did")
                    .or_else(|| jmap.get("device_id"))
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                mtu,
                chunk1: jmap.get("chunk1").and_then(Value::as_bool).unwrap_or(false),
                wg_private_key: "",
                wg_peer_public_key: "",
                wg_address: "",
            },
        );
    }

    // 3. Colon format: wdtt://host:dtls_port:wg_port:local_port:pass:hash1,hash2#remark
    if !body.contains('?') && !body.contains('@') {
        let split_host = if let Some(rest_br) = body.strip_prefix('[') {
            rest_br
                .split_once("]:")
                .map(|(h, t)| (h.trim().to_string(), t))
        } else {
            body.split_once(':').map(|(h, t)| (h.trim().to_string(), t))
        };
        if let Some((host_part, tail)) = split_host
            && !host_part.is_empty()
            && !tail.is_empty()
        {
            let parts: Vec<&str> = tail.splitn(5, ':').collect();
            if parts.len() == 5
                && let Some(dtls_port) = parse_wdtt_port_val(parts[0])
            {
                let pass = url_decode_percent(parts[3].trim());
                if !pass.is_empty() {
                    let wg_port = parse_wdtt_port_val(parts[1]).unwrap_or(0);
                    let local_port = parse_wdtt_port_val(parts[2]).unwrap_or(0);
                    let hashes_raw = url_decode_percent(parts[4].trim());
                    let hashes = parse_csqtt_hashes_tokens([hashes_raw.as_str()]);
                    let mode = if scheme_lower == "csqtt" {
                        "csqtt"
                    } else {
                        "wg"
                    };
                    return make_wdtt_node(
                        full_uri,
                        &frag_tag,
                        "",
                        "wdtt",
                        &WdttParams {
                            server: &host_part,
                            server_port: dtls_port,
                            password: &pass,
                            mode,
                            obfs: "",
                            raw_port: 0,
                            wg_port,
                            local_port,
                            hashes: &hashes,
                            vk_auth_mode: "",
                            vk_cookie: "",
                            vk_client_ids: &[],
                            turn_server: "",
                            turn_urls: &[],
                            turn_username: "",
                            turn_password: "",
                            turn_transport: "",
                            workers: 0,
                            device_id: "",
                            mtu: 0,
                            chunk1: false,
                            wg_private_key: "",
                            wg_peer_public_key: "",
                            wg_address: "",
                        },
                    );
                }
            }
        }
    }

    // 4. Standard query URI: wdtt://[pass@]host[:port]?pass=...&hashes=...&mode=...#remark
    let (before_q, q_str) = body.split_once('?').unwrap_or((body, ""));
    let (userinfo, hp) = match before_q.split_once('@') {
        Some((u, h)) => (url_decode_percent(u), h),
        None => (String::new(), before_q),
    };
    let default_port = if scheme_lower == "csqtt" {
        46000
    } else {
        56000
    };
    let (server, port) = split_host_port(hp.trim_end_matches('/'), default_port)?;
    if server.is_empty() || port == 0 {
        return None;
    }
    let mut query: HashMap<String, String> = HashMap::new();
    for pair in q_str.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k_raw, v_raw) = pair.split_once('=').unwrap_or((pair, ""));
        let k = k_raw.trim().to_ascii_lowercase();
        if k.is_empty() {
            continue;
        }
        let v = if k == "hashes" || k == "hash" {
            url_decode_percent(v_raw)
        } else {
            url_decode(v_raw)
        };
        query.insert(k, v);
    }
    let password = if !userinfo.is_empty() {
        userinfo
    } else {
        query
            .get("pass")
            .or_else(|| query.get("password"))
            .or_else(|| query.get("id"))
            .cloned()
            .unwrap_or_default()
    };
    if password.is_empty() {
        return None;
    }
    let raw_mode = query
        .get("mode")
        .or_else(|| query.get("vpn"))
        .map(|s| s.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let mode = if scheme_lower == "csqtt" {
        if raw_mode == "csqtt_v1" {
            "csqtt_v1".to_string()
        } else {
            "csqtt".to_string()
        }
    } else if matches!(raw_mode.as_str(), "raw" | "csqtt" | "csqtt_v1") {
        raw_mode
    } else {
        "wg".to_string()
    };
    let hashes = query
        .get("hashes")
        .or_else(|| query.get("hash"))
        .map(|raw| parse_csqtt_hashes_tokens([raw.as_str()]))
        .unwrap_or_default();
    let workers = query
        .get("workers")
        .or_else(|| query.get("streams"))
        .and_then(|s| s.trim().parse::<u16>().ok())
        .filter(|&w| (1..=126).contains(&w))
        .unwrap_or(0);
    let mtu = query
        .get("mtu")
        .and_then(|s| s.trim().parse::<u16>().ok())
        .filter(|&m| (576..=1500).contains(&m))
        .unwrap_or(0);
    let raw_port = query
        .get("raw_port")
        .or_else(|| query.get("raw"))
        .and_then(|s| parse_wdtt_port_val(s))
        .unwrap_or(0);
    let chunk1 = query
        .get("chunk1")
        .is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"));
    make_wdtt_node(
        full_uri,
        &frag_tag,
        query
            .get("name")
            .or_else(|| query.get("ps"))
            .map_or("", String::as_str),
        "wdtt",
        &WdttParams {
            server: &server,
            server_port: port,
            password: &password,
            mode: &mode,
            obfs: query.get("obfs").map_or("", String::as_str),
            raw_port,
            wg_port: 0,
            local_port: 0,
            hashes: &hashes,
            vk_auth_mode: "",
            vk_cookie: "",
            vk_client_ids: &[],
            turn_server: query.get("turn_server").map_or("", String::as_str),
            turn_urls: &[],
            turn_username: query.get("turn_username").map_or("", String::as_str),
            turn_password: query.get("turn_password").map_or("", String::as_str),
            turn_transport: query.get("turn_transport").map_or("", String::as_str),
            workers,
            device_id: query
                .get("did")
                .or_else(|| query.get("device_id"))
                .map_or("", String::as_str),
            mtu,
            chunk1,
            wg_private_key: "",
            wg_peer_public_key: "",
            wg_address: "",
        },
    )
}

fn parse_vmess_uri(full_uri: &str, b64_part: &str, idx: usize) -> Option<ParsedProxyNode> {
    let clean = b64_part.trim();
    let decoded = B64_STD
        .decode(clean)
        .or_else(|_| B64_URL.decode(clean))
        .ok()?;
    let v: Value = serde_json::from_slice(&decoded).ok()?;
    let host = v.get("add")?.as_str()?.to_string();
    let port = v.get("port").and_then(|p| {
        p.as_u64()
            .or_else(|| p.as_str().and_then(|s| s.parse::<u64>().ok()))
    })? as u16;
    let uuid = v.get("id")?.as_str()?.to_string();
    let ps = v.get("ps").and_then(Value::as_str).unwrap_or("");
    let tag = if !ps.trim().is_empty() {
        ps.trim().to_string()
    } else {
        format!("vmess-{host}:{port}-{idx}")
    };
    let country = detect_country_code(&tag);
    let net = v.get("net").and_then(Value::as_str).unwrap_or("tcp");
    let tls_on = v.get("tls").and_then(Value::as_str).unwrap_or("") == "tls";
    let sni = v
        .get("sni")
        .or_else(|| v.get("host"))
        .and_then(Value::as_str)
        .unwrap_or(&host);

    let mut obj = Map::new();
    obj.insert("type".into(), json!("vmess"));
    obj.insert("tag".into(), json!(tag));
    obj.insert("server".into(), json!(host));
    obj.insert("server_port".into(), json!(port));
    obj.insert("uuid".into(), json!(uuid));
    obj.insert("security".into(), json!("auto"));
    if tls_on {
        obj.insert(
            "tls".into(),
            json!({
                "enabled": true,
                "server_name": sni
            }),
        );
    }
    if net == "ws" {
        obj.insert(
            "transport".into(),
            json!({
                "type": "ws",
                "path": v.get("path").and_then(Value::as_str).unwrap_or("/")
            }),
        );
    } else if net == "grpc" {
        obj.insert(
            "transport".into(),
            json!({
                "type": "grpc",
                "service_name": v.get("path").and_then(Value::as_str).unwrap_or("")
            }),
        );
    }

    Some(ParsedProxyNode {
        tag,
        protocol: "vmess".to_string(),
        server: host,
        server_port: port,
        country,
        raw_uri: full_uri.to_string(),
        outbound_json: Value::Object(obj),
    })
}

/// Decodes a Base64-encoded `fptn://` or `fptn:` access token into its JSON payload.
pub fn decode_fptn_token_json(raw_token: &str) -> Option<Value> {
    let mut s = raw_token.trim();
    if let Some((before_hash, _)) = s.split_once('#') {
        s = before_hash.trim();
    }
    for prefix in ["fptn://", "fptnb://", "fptn:", "fptnb:"] {
        if let Some(stripped) = s.strip_prefix(prefix) {
            s = stripped.trim_start_matches('/');
            break;
        }
    }
    let clean: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if clean.is_empty() {
        return None;
    }
    let mut padded = clean.replace('-', "+").replace('_', "/");
    while !padded.len().is_multiple_of(4) {
        padded.push('=');
    }
    let decoded = B64_STD
        .decode(&padded)
        .or_else(|_| B64_URL.decode(clean.trim_end_matches('=')))
        .ok()?;
    let val: Value = serde_json::from_slice(&decoded).ok()?;
    if val.is_object() { Some(val) } else { None }
}

/// Expands an `fptn://` access token into per-server `tachyon-core` FPTN outbounds,
/// sorting `preferred_server` to the front when specified.
pub fn expand_fptn_token_outbounds(
    base_tag: &str,
    raw_token: &str,
    sni_override: &str,
    bypass_method: &str,
    preferred_server: &str,
) -> Vec<(String, Value)> {
    let Some(decoded) = decode_fptn_token_json(raw_token) else {
        return Vec::new();
    };
    let username = decoded
        .get("username")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let password = decoded
        .get("password")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if username.is_empty() || password.is_empty() {
        return Vec::new();
    }
    let mut servers = Vec::new();
    for key in ["servers", "censorship_zone_servers"] {
        if let Some(arr) = decoded.get(key).and_then(Value::as_array) {
            for item in arr {
                if item.is_object() {
                    servers.push(item.clone());
                }
            }
        }
    }
    if servers.is_empty() {
        return Vec::new();
    }
    let pref_lc = preferred_server.trim().to_ascii_lowercase();
    if !pref_lc.is_empty() {
        servers.sort_by_key(|srv| {
            let nm = srv
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let h = srv
                .get("host")
                .or_else(|| srv.get("ip"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            if nm == pref_lc || h == pref_lc {
                0usize
            } else {
                1usize
            }
        });
    }
    let mut out = Vec::new();
    for (idx, srv) in servers.iter().enumerate() {
        let host = srv
            .get("host")
            .or_else(|| srv.get("ip"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if host.is_empty() {
            continue;
        }
        let port = srv.get("port").and_then(Value::as_u64).unwrap_or(443) as u16;
        let name = srv
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(host)
            .trim();
        let member_tag = if servers.len() == 1 && idx == 0 {
            base_tag.to_string()
        } else {
            format!("{base_tag}/{name}")
        };
        let mut obj = Map::new();
        obj.insert("type".into(), json!("fptn"));
        obj.insert("tag".into(), json!(member_tag));
        obj.insert("server".into(), json!(host));
        obj.insert("server_port".into(), json!(port));
        obj.insert("username".into(), json!(username));
        obj.insert("password".into(), json!(password));
        if let Some(fp) = srv
            .get("md5_fingerprint")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            obj.insert("md5_fingerprint".into(), json!(fp));
        }
        if !sni_override.is_empty() {
            obj.insert("sni".into(), json!(sni_override));
        }
        if !bypass_method.is_empty() {
            obj.insert("bypass_method".into(), json!(bypass_method));
        }
        out.push((member_tag, Value::Object(obj)));
    }
    out
}

/// Extracts all IPv4 FPTN server addresses across enabled outbound sources and sections
/// so `net_stack` can exclude them from TProxy self-interception.
pub fn extract_fptn_server_ips(store: &RouterStoreData) -> Vec<String> {
    let mut ips = Vec::new();
    fn push_ip(ips: &mut Vec<String>, candidate: &str) {
        let trimmed = candidate.trim();
        if trimmed.parse::<std::net::Ipv4Addr>().is_ok() && !ips.iter().any(|x| x == trimmed) {
            ips.push(trimmed.to_string());
        }
    }
    fn inspect_token(ips: &mut Vec<String>, tok: &str) {
        if let Some(decoded) = decode_fptn_token_json(tok) {
            for key in ["servers", "censorship_zone_servers"] {
                if let Some(arr) = decoded.get(key).and_then(Value::as_array) {
                    for srv in arr {
                        if let Some(h) = srv
                            .get("host")
                            .or_else(|| srv.get("ip"))
                            .and_then(Value::as_str)
                        {
                            push_ip(ips, h);
                        }
                    }
                }
            }
        }
    }
    for src in &store.outbound_sources {
        if !src.enabled || src.source_type != "fptn" {
            continue;
        }
        if !src.server.is_empty() {
            push_ip(&mut ips, &src.server);
        }
        if !src.fptn_access_token.is_empty() {
            inspect_token(&mut ips, &src.fptn_access_token);
        }
        for link in &src.proxy_links {
            inspect_token(&mut ips, link);
            if let Some(node) = parse_proxy_uri(link, 0) {
                push_ip(&mut ips, &node.server);
            }
        }
    }
    for sec in &store.sections {
        if !sec.enabled {
            continue;
        }
        if !sec.fptn_access_token.is_empty() {
            inspect_token(&mut ips, &sec.fptn_access_token);
        }
        if !sec.fptn_preferred_server.is_empty() {
            push_ip(&mut ips, &sec.fptn_preferred_server);
        }
    }
    ips
}

fn parse_vpn_uri(full_uri: &str, rest: &str, idx: usize) -> Option<ParsedProxyNode> {
    let (b64_part, raw_tag) = match rest.split_once('#') {
        Some((b, t)) => (b.trim(), url_decode(t)),
        None => (rest.trim(), String::new()),
    };
    let clean: String = b64_part.chars().filter(|c| !c.is_whitespace()).collect();
    if clean.is_empty() {
        return None;
    }
    let mut padded = clean.replace('-', "+").replace('_', "/");
    while !padded.len().is_multiple_of(4) {
        padded.push('=');
    }
    let decoded = B64_STD
        .decode(&padded)
        .or_else(|_| B64_URL.decode(clean.trim_end_matches('=')))
        .ok()?;
    let text = String::from_utf8(decoded).ok()?;
    let tag_prefix = if !raw_tag.trim().is_empty() {
        raw_tag.trim().to_string()
    } else {
        format!("vpn-{idx}")
    };
    if let Some((tag, outbound_json)) = parse_amnezia_conf_outbound(&tag_prefix, idx, &text) {
        let server = outbound_json
            .get("server")
            .and_then(Value::as_str)
            .unwrap_or("127.0.0.1")
            .to_string();
        let server_port = outbound_json
            .get("server_port")
            .and_then(Value::as_u64)
            .unwrap_or(51820) as u16;
        let country = detect_country_code(&tag);
        return Some(ParsedProxyNode {
            tag,
            protocol: "wireguard".to_string(),
            server,
            server_port,
            country,
            raw_uri: full_uri.to_string(),
            outbound_json,
        });
    }
    None
}

fn split_mieru_host_optional_port(hp: &str) -> Option<(String, Option<u16>)> {
    let trimmed = hp.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix('[') {
        let (ipv6, after) = rest.split_once(']')?;
        let host = ipv6.trim();
        if host.is_empty() || host.chars().any(char::is_whitespace) {
            return None;
        }
        if after.is_empty() {
            return Some((host.to_string(), None));
        }
        let port_str = after.strip_prefix(':')?;
        if port_str.is_empty() || !port_str.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let port = port_str.parse::<u16>().ok().filter(|&p| p >= 1)?;
        return Some((host.to_string(), Some(port)));
    }

    if let Some((h, p_str)) = trimmed.rsplit_once(':') {
        if h.contains(':') {
            return None;
        }
        let host = h.trim();
        if host.is_empty() || host.chars().any(char::is_whitespace) {
            return None;
        }
        if p_str.is_empty() || !p_str.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let port = p_str.parse::<u16>().ok().filter(|&p| p >= 1)?;
        return Some((host.to_string(), Some(port)));
    }

    if trimmed.chars().any(char::is_whitespace) {
        return None;
    }
    Some((trimmed.to_string(), None))
}

fn first_port_from_specs(specs: &[String]) -> Option<u16> {
    specs.iter().find_map(|spec| {
        let first = spec.split(['-', ':']).next()?.trim();
        first.parse::<u16>().ok().filter(|&p| p >= 1)
    })
}

fn parse_mieru_uri(full_uri: &str, scheme_lower: &str, rest: &str) -> Option<ParsedProxyNode> {
    let (before_hash, raw_fragment) = match rest.split_once('#') {
        Some((b, f)) => (b, url_decode_percent(f).trim().to_string()),
        None => (rest, String::new()),
    };
    let (authority_and_path, query_str) = match before_hash.split_once('?') {
        Some((a, q)) => (a, q),
        None => (before_hash, ""),
    };
    let authority = authority_and_path
        .split('/')
        .next()
        .unwrap_or(authority_and_path);

    let (raw_userinfo, host_port_part) = match authority.rsplit_once('@') {
        Some((u, hp)) => (u, hp),
        None => ("", authority),
    };
    let (host, auth_port) = split_mieru_host_optional_port(host_port_part)?;

    let (username, mut password) = if raw_userinfo.is_empty() {
        (String::new(), String::new())
    } else if let Some((raw_u, raw_p)) = raw_userinfo.split_once(':') {
        (url_decode_percent(raw_u), url_decode_percent(raw_p))
    } else {
        (url_decode_percent(raw_userinfo), String::new())
    };

    let mut params: HashMap<String, String> = HashMap::new();
    let mut query_specs: Vec<String> = Vec::new();
    let mut seen_specs: HashSet<String> = HashSet::new();
    let mut has_explicit_range = false;

    for pair in query_str.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (raw_k, raw_v) = pair.split_once('=').unwrap_or((pair, ""));
        let key = url_decode(raw_k).trim().to_ascii_lowercase();
        let val = url_decode(raw_v).trim().to_string();
        if key.is_empty() {
            continue;
        }
        if !val.is_empty()
            && matches!(
                key.as_str(),
                "port" | "ports" | "port-range" | "server_ports"
            )
        {
            if key != "port" {
                has_explicit_range = true;
            }
            for raw_tok in val.split(|c: char| c == ',' || c.is_whitespace()) {
                let norm = raw_tok.trim().replace(':', "-");
                if norm.is_empty() {
                    continue;
                }
                let spec = if let Some((lo_s, hi_s)) = norm.split_once('-') {
                    if lo_s.is_empty()
                        || hi_s.is_empty()
                        || !lo_s.bytes().all(|b| b.is_ascii_digit())
                        || !hi_s.bytes().all(|b| b.is_ascii_digit())
                    {
                        return None;
                    }
                    let lo = lo_s.parse::<u32>().ok()?;
                    let hi = hi_s.parse::<u32>().ok()?;
                    if !(1..=65535).contains(&lo) || !(1..=65535).contains(&hi) || lo > hi {
                        return None;
                    }
                    if lo == hi {
                        lo.to_string()
                    } else {
                        has_explicit_range = true;
                        format!("{lo}-{hi}")
                    }
                } else {
                    if !norm.bytes().all(|b| b.is_ascii_digit()) {
                        return None;
                    }
                    let p = norm.parse::<u16>().ok().filter(|&p| p >= 1)?;
                    p.to_string()
                };
                if seen_specs.insert(spec.clone()) {
                    query_specs.push(spec);
                }
            }
        }
        params.insert(key, val);
    }

    if password.is_empty() {
        password = params
            .get("password")
            .or_else(|| params.get("pass"))
            .cloned()
            .unwrap_or_default();
    }
    if host.is_empty() || username.is_empty() || password.is_empty() {
        return None;
    }

    let single_port: Option<u16>;
    let mut port_ranges: Vec<String> = Vec::new();
    if !query_specs.is_empty() {
        let single_query_port = if query_specs.len() == 1
            && !has_explicit_range
            && query_specs[0].bytes().all(|b| b.is_ascii_digit())
        {
            query_specs[0].parse::<u16>().ok().filter(|&p| p >= 1)
        } else {
            None
        };
        if let Some(sqp) = single_query_port {
            if auth_port.is_none() || auth_port == Some(sqp) || scheme_lower == "mierus" {
                single_port = Some(sqp);
            } else {
                single_port = auth_port;
                port_ranges = query_specs;
            }
        } else {
            port_ranges = query_specs;
            single_port = auth_port;
        }
    } else {
        single_port = Some(auth_port?);
    }

    let transport_raw = params
        .get("protocol")
        .or_else(|| params.get("transport"))
        .or_else(|| params.get("network"))
        .map(|s| s.trim().to_ascii_uppercase())
        .unwrap_or_else(|| "TCP".to_string());
    let transport = if transport_raw == "UDP" { "UDP" } else { "TCP" };

    let display_port = port_ranges
        .first()
        .cloned()
        .or_else(|| single_port.map(|p| p.to_string()))
        .unwrap_or_default();
    let tag = if !raw_fragment.is_empty() {
        raw_fragment
    } else if let Some(prof) = params
        .get("profile")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        prof.to_string()
    } else {
        format!("{host}:{display_port}")
    };
    let country = detect_country_code(&tag);

    let mut obj = Map::new();
    obj.insert("type".into(), json!("mieru"));
    obj.insert("tag".into(), json!(tag));
    obj.insert("server".into(), json!(host));
    obj.insert("transport".into(), json!(transport));
    obj.insert("username".into(), json!(username));
    obj.insert("password".into(), json!(password));
    if !port_ranges.is_empty() {
        obj.insert("server_ports".into(), json!(port_ranges));
    }
    if let Some(sp) = single_port {
        obj.insert("server_port".into(), json!(sp));
    }
    if let Some(mux) = params
        .get("multiplexing")
        .or_else(|| params.get("mux"))
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        obj.insert("multiplexing".into(), json!(mux));
    }
    if let Some(tp) = params
        .get("traffic-pattern")
        .or_else(|| params.get("traffic_pattern"))
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        obj.insert("traffic_pattern".into(), json!(tp));
    }

    let summary_port = single_port
        .or_else(|| first_port_from_specs(&port_ranges))
        .unwrap_or(0);

    Some(ParsedProxyNode {
        tag,
        protocol: "mieru".to_string(),
        server: host,
        server_port: summary_port,
        country,
        raw_uri: full_uri.to_string(),
        outbound_json: Value::Object(obj),
    })
}

fn format_uri_host_only(server: &str) -> String {
    let s = server.trim();
    if s.contains(':') && !s.starts_with('[') {
        format!("[{s}]")
    } else {
        s.to_string()
    }
}

/// Serialize a normalized `mieru` outbound JSON object into a canonical `mierus://` share link.
pub fn serialize_mieru_outbound(outbound: &Value) -> Option<String> {
    let server = outbound
        .get("server")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let username = outbound
        .get("username")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())?;
    let password = outbound
        .get("password")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())?;

    let mut port_specs: Vec<String> = Vec::new();
    if let Some(arr) = outbound.get("server_ports").and_then(Value::as_array) {
        for item in arr {
            let spec = item
                .as_str()
                .map(|s| s.trim().replace(':', "-"))
                .unwrap_or_default();
            if !spec.is_empty() {
                port_specs.push(spec);
            }
        }
    }
    if port_specs.is_empty()
        && let Some(sp) = outbound.get("server_port").and_then(Value::as_u64)
        && (1..=65535).contains(&sp)
    {
        port_specs.push(sp.to_string());
    }
    if port_specs.is_empty() {
        return None;
    }

    let mut query_parts: Vec<String> = Vec::new();
    let tag = outbound
        .get("tag")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    if !tag.is_empty() {
        query_parts.push(format!("profile={}", url_encode_component(tag)));
    }
    for spec in &port_specs {
        query_parts.push(format!("port={}", url_encode_component(spec)));
    }
    let transport = outbound
        .get("transport")
        .and_then(Value::as_str)
        .map(|s| s.trim().to_ascii_uppercase())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "TCP".to_string());
    query_parts.push(format!("protocol={}", url_encode_component(&transport)));

    if let Some(mux) = outbound
        .get("multiplexing")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        query_parts.push(format!("multiplexing={}", url_encode_component(mux)));
    }
    if let Some(tp) = outbound
        .get("traffic_pattern")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        query_parts.push(format!("traffic-pattern={}", url_encode_component(tp)));
    }

    let userinfo = format!(
        "{}:{}",
        url_encode_component(username),
        url_encode_component(password)
    );
    let uri_host = format_uri_host_only(server);
    let query = if query_parts.is_empty() {
        String::new()
    } else {
        format!("?{}", query_parts.join("&"))
    };
    let frag = if tag.is_empty() {
        String::new()
    } else {
        format!("#{}", url_encode_component(tag))
    };
    Some(format!("mierus://{userinfo}@{uri_host}{query}{frag}"))
}

fn decode_ss_userinfo(userinfo: &str) -> Option<(String, String)> {
    if let Some((m, p)) = userinfo.split_once(':') {
        return Some((m.to_string(), p.to_string()));
    }
    let decoded = B64_URL
        .decode(userinfo)
        .or_else(|_| B64_STD.decode(userinfo))
        .ok()?;
    let s = String::from_utf8(decoded).ok()?;
    let (m, p) = s.split_once(':')?;
    Some((m.to_string(), p.to_string()))
}

fn build_tls_object(params: &HashMap<String, String>, default_host: &str) -> Option<Value> {
    let sec = params.get("security").map(String::as_str).unwrap_or("none");
    if sec != "tls" && sec != "reality" {
        return None;
    }
    let sni = params
        .get("sni")
        .or_else(|| params.get("serverName"))
        .cloned()
        .unwrap_or_else(|| default_host.to_string());
    let fp = params
        .get("fp")
        .cloned()
        .unwrap_or_else(|| "chrome".to_string());
    let mut tls = Map::new();
    tls.insert("enabled".into(), json!(true));
    tls.insert("server_name".into(), json!(sni));
    tls.insert(
        "utls".into(),
        json!({
            "enabled": true,
            "fingerprint": fp
        }),
    );
    if sec == "reality" {
        tls.insert(
            "reality".into(),
            json!({
                "enabled": true,
                "public_key": params.get("pbk").cloned().unwrap_or_default(),
                "short_id": params.get("sid").cloned().unwrap_or_default()
            }),
        );
    }
    Some(Value::Object(tls))
}

fn build_transport_object(params: &HashMap<String, String>) -> Option<Value> {
    let t = params.get("type").map(String::as_str).unwrap_or("tcp");
    match t {
        "ws" => Some(json!({
            "type": "ws",
            "path": params.get("path").cloned().unwrap_or_else(|| "/".to_string()),
        })),
        "grpc" => Some(json!({
            "type": "grpc",
            "service_name": params.get("serviceName").or_else(|| params.get("path")).cloned().unwrap_or_default(),
        })),
        "xhttp" | "splithttp" => Some(json!({
            "type": "xhttp",
            "path": params.get("path").cloned().unwrap_or_else(|| "/".to_string()),
            "mode": params.get("mode").cloned().unwrap_or_else(|| "auto".to_string()),
        })),
        "http" | "h2" => Some(json!({
            "type": "http",
            "path": params.get("path").cloned().unwrap_or_else(|| "/".to_string()),
        })),
        _ => None,
    }
}

fn split_host_port(hp: &str, default_port: u16) -> Option<(String, u16)> {
    if let Some(rest) = hp.strip_prefix('[') {
        let (ipv6, after) = rest.split_once(']')?;
        let port = after
            .strip_prefix(':')
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(default_port);
        return Some((ipv6.to_string(), port));
    }
    if let Some((h, p)) = hp.rsplit_once(':')
        && let Ok(port) = p.parse::<u16>()
    {
        return Some((h.to_string(), port));
    }
    if hp.is_empty() {
        return None;
    }
    Some((hp.to_string(), default_port))
}

fn parse_query_params(q: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for pair in q.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        map.insert(url_decode(k), url_decode(v));
    }
    map
}

fn url_decode(s: &str) -> String {
    let mut bytes = Vec::with_capacity(s.len());
    let raw = s.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' && i + 2 < raw.len() {
            if let Ok(hex_str) = std::str::from_utf8(&raw[i + 1..i + 3])
                && let Ok(b) = u8::from_str_radix(hex_str, 16)
            {
                bytes.push(b);
                i += 3;
                continue;
            }
        } else if raw[i] == b'+' {
            bytes.push(b' ');
            i += 1;
            continue;
        }
        bytes.push(raw[i]);
        i += 1;
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Detect 2-letter ISO country code from Unicode flag emojis (`🇳🇱`, `🇫🇮`, `🇩🇪`, etc.),
/// Russian/English country names (`Нидерланды`, `Финляндия`, `Germany`, etc.), or ISO codes.
pub fn detect_country_code(label: &str) -> String {
    // 1. Decode any Unicode regional indicator symbol pair (U+1F1E6..=U+1F1FF)
    let chars: Vec<char> = label.chars().collect();
    for pair in chars.windows(2) {
        let c0 = pair[0] as u32;
        let c1 = pair[1] as u32;
        if (0x1F1E6..=0x1F1FF).contains(&c0) && (0x1F1E6..=0x1F1FF).contains(&c1) {
            let a = (b'A' + (c0 - 0x1F1E6) as u8) as char;
            let b = (b'A' + (c1 - 0x1F1E6) as u8) as char;
            return format!("{a}{b}");
        }
    }

    // 2. Check Russian & English country names
    let lower = label.to_lowercase();
    for (kw, cc) in [
        ("нидерланды", "NL"),
        ("netherlands", "NL"),
        ("holland", "NL"),
        ("германия", "DE"),
        ("germany", "DE"),
        ("frankfurt", "DE"),
        ("финляндия", "FI"),
        ("finland", "FI"),
        ("helsinki", "FI"),
        ("швеция", "SE"),
        ("sweden", "SE"),
        ("stockholm", "SE"),
        ("эстония", "EE"),
        ("estonia", "EE"),
        ("латвия", "LV"),
        ("latvia", "LV"),
        ("литва", "LT"),
        ("lithuania", "LT"),
        ("польша", "PL"),
        ("poland", "PL"),
        ("warsaw", "PL"),
        ("франция", "FR"),
        ("france", "FR"),
        ("paris", "FR"),
        ("великобритания", "GB"),
        ("англия", "GB"),
        ("united kingdom", "GB"),
        ("london", "GB"),
        ("сша", "US"),
        ("usa", "US"),
        ("united states", "US"),
        ("турция", "TR"),
        ("turkey", "TR"),
        ("istanbul", "TR"),
        ("казахстан", "KZ"),
        ("kazakhstan", "KZ"),
        ("россия", "RU"),
        ("russia", "RU"),
        ("moscow", "RU"),
        ("австрия", "AT"),
        ("austria", "AT"),
        ("vienna", "AT"),
        ("швейцария", "CH"),
        ("switzerland", "CH"),
        ("zurich", "CH"),
        ("сингапур", "SG"),
        ("singapore", "SG"),
        ("япония", "JP"),
        ("japan", "JP"),
        ("tokyo", "JP"),
        ("корея", "KR"),
        ("korea", "KR"),
        ("seoul", "KR"),
        ("гонконг", "HK"),
        ("hong kong", "HK"),
        ("канада", "CA"),
        ("canada", "CA"),
        ("италия", "IT"),
        ("italy", "IT"),
        ("испания", "ES"),
        ("spain", "ES"),
        ("чехия", "CZ"),
        ("czech", "CZ"),
        ("оаэ", "AE"),
        ("uae", "AE"),
        ("dubai", "AE"),
    ] {
        if lower.contains(kw) {
            return cc.to_string();
        }
    }

    // 3. Check standalone uppercase 2-letter ISO codes
    for token in label.split(|c: char| !c.is_ascii_alphabetic()) {
        let up = token.to_ascii_uppercase();
        if matches!(
            up.as_str(),
            "NL" | "DE"
                | "FI"
                | "US"
                | "GB"
                | "UK"
                | "FR"
                | "SE"
                | "PL"
                | "TR"
                | "SG"
                | "JP"
                | "KR"
                | "HK"
                | "KZ"
                | "RU"
                | "AT"
                | "CH"
                | "EE"
                | "LV"
                | "LT"
        ) {
            return if up == "UK" { "GB".to_string() } else { up };
        }
    }
    String::new()
}

struct DesyncParams<'a> {
    opts: &'a str,
    preset: &'a str,
    mode: &'a str,
    fooling: &'a str,
    split_pos: &'a str,
    fake_ttl: u8,
    fake_sni: &'a str,
    sni_pool: &'a [String],
    repeats: u8,
    split_delay_ms: u32,
    tlsrec_first: bool,
    seqovl: u16,
    syndata: bool,
    wsize: u32,
    wscale: Option<u8>,
    host_fake: bool,
    fake_payload: &'a str,
    fake_tls: &'a str,
    ipfrag: bool,
    udp_fake: bool,
    udp_repeats: u8,
    udp_fake_ttl: u8,
    udplen: u16,
}

fn build_desync_outbound_json(tag: &str, p: &DesyncParams<'_>, with_defaults: bool) -> Value {
    if !p.opts.trim().is_empty() {
        return crate::fuzzer::parse_desync_args_to_outbound(p.opts, tag, false);
    }
    let mut obj = Map::new();
    obj.insert("type".into(), json!("desync"));
    obj.insert("tag".into(), json!(tag));
    if !p.mode.trim().is_empty() && (p.preset.trim().is_empty() || p.preset == "custom") {
        obj.insert("mode".into(), json!(p.mode.trim()));
    } else {
        let preset = if p.preset.trim().is_empty() || p.preset == "adaptive" {
            "auto"
        } else {
            p.preset.trim()
        };
        obj.insert("preset".into(), json!(preset));
    }

    let pool: Vec<String> = p
        .sni_pool
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if !p.fake_sni.trim().is_empty() {
        obj.insert("fake_sni".into(), json!(p.fake_sni.trim()));
    } else if let Some(first) = pool.first() {
        obj.insert("fake_sni".into(), json!(first));
    } else if with_defaults {
        obj.insert("fake_sni".into(), json!("ozon.ru"));
    }
    if !pool.is_empty() {
        obj.insert("sni_pool".into(), json!(pool));
    }

    let sp_raw = if !p.split_pos.trim().is_empty() {
        p.split_pos.trim()
    } else if with_defaults {
        "sni"
    } else {
        ""
    };
    if !sp_raw.is_empty() {
        if sp_raw.contains(',') {
            let arr: Vec<Value> = sp_raw
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| {
                    s.parse::<i64>()
                        .map(|n| json!(n))
                        .unwrap_or_else(|_| json!(s))
                })
                .collect();
            obj.insert("split_pos".into(), Value::Array(arr));
        } else if let Ok(n) = sp_raw.parse::<i64>() {
            obj.insert("split_pos".into(), json!(n));
        } else {
            obj.insert("split_pos".into(), json!(sp_raw));
        }
    }

    let fooling = if !p.fooling.trim().is_empty() {
        p.fooling.trim()
    } else if with_defaults {
        "autottl"
    } else {
        ""
    };
    if !fooling.is_empty() {
        obj.insert("fooling".into(), json!(fooling));
    }
    if p.fake_ttl > 0 {
        obj.insert("fake_ttl".into(), json!(p.fake_ttl.min(128)));
    }
    if p.repeats > 0 {
        obj.insert("repeats".into(), json!(p.repeats));
    }
    if p.split_delay_ms > 0 {
        obj.insert("split_delay_ms".into(), json!(p.split_delay_ms));
    }
    if p.tlsrec_first {
        obj.insert("tlsrec_first".into(), json!(true));
    }
    if p.seqovl > 0 {
        obj.insert("seqovl".into(), json!(p.seqovl));
    }
    if p.syndata {
        obj.insert("syndata".into(), json!(true));
    }
    if p.wsize > 0 {
        obj.insert("wsize".into(), json!(p.wsize));
    }
    if let Some(ws) = p.wscale {
        obj.insert("wscale".into(), json!(ws.min(14)));
    }
    if p.host_fake {
        obj.insert("host_fake".into(), json!(true));
    }
    if !p.fake_payload.trim().is_empty() {
        obj.insert("fake_payload".into(), json!(p.fake_payload.trim()));
    }
    if !p.fake_tls.trim().is_empty() {
        obj.insert("fake_tls".into(), json!(p.fake_tls.trim()));
    }
    if p.ipfrag {
        obj.insert("ipfrag".into(), json!(true));
    }
    if p.udp_fake {
        obj.insert("udp_fake".into(), json!(true));
    }
    if p.udp_repeats > 0 {
        obj.insert("udp_repeats".into(), json!(p.udp_repeats));
    }
    if p.udp_fake_ttl > 0 {
        obj.insert("udp_fake_ttl".into(), json!(p.udp_fake_ttl.min(128)));
    }
    if p.udplen > 0 {
        obj.insert("udplen".into(), json!(p.udplen));
    }
    Value::Object(obj)
}

/// Build outbound JSON objects for an `OutboundSource` and return `(tag, json, visible_in_selector)` tuples.
fn build_source_outbounds(src: &OutboundSource) -> Vec<(String, Value, bool)> {
    let mut raw_out: Vec<(String, Value)> = Vec::new();
    if !src.enabled {
        return Vec::new();
    }
    let out = &mut raw_out;
    match src.source_type.as_str() {
        "desync" => {
            let tag = format!("desync-{}", src.id);
            let val = build_desync_outbound_json(
                &tag,
                &DesyncParams {
                    opts: &src.desync_opts,
                    preset: &src.desync_preset,
                    mode: &src.desync_mode,
                    fooling: &src.desync_fooling,
                    split_pos: &src.desync_split_pos,
                    fake_ttl: src.desync_ttl,
                    fake_sni: &src.desync_fake_sni,
                    sni_pool: &src.desync_sni_pool,
                    repeats: src.desync_repeats,
                    split_delay_ms: src.desync_split_delay_ms as u32,
                    tlsrec_first: src.desync_tlsrec_first,
                    seqovl: src.desync_seqovl,
                    syndata: src.desync_syndata,
                    wsize: src.desync_wsize as u32,
                    wscale: src.desync_wscale,
                    host_fake: src.desync_host_fake,
                    fake_payload: &src.desync_fake_payload,
                    fake_tls: &src.desync_fake_tls,
                    ipfrag: src.desync_ipfrag,
                    udp_fake: src.desync_quic_fake,
                    udp_repeats: src.desync_udp_repeats,
                    udp_fake_ttl: src.desync_udp_fake_ttl,
                    udplen: src.desync_udplen,
                },
                true,
            );
            out.push((tag, val));
        }
        "wireguard" | "awg" => {
            let tag = format!("wg-{}", src.id);
            let (host, port) = split_host_port(&src.wg_endpoint, 51820)
                .unwrap_or_else(|| ("127.0.0.1".to_string(), 51820));
            let mut obj = Map::new();
            obj.insert("type".into(), json!("wireguard"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(host));
            obj.insert("server_port".into(), json!(port));
            obj.insert("private_key".into(), json!(src.wg_private_key));
            obj.insert("peer_public_key".into(), json!(src.wg_peer_public_key));
            if !src.wg_preshared_key.is_empty() {
                obj.insert("pre_shared_key".into(), json!(src.wg_preshared_key));
            }
            let addr = if src.wg_local_address.is_empty() {
                "10.8.0.2/32"
            } else {
                &src.wg_local_address
            };
            obj.insert("local_address".into(), json!([addr]));
            if src.wg_mtu > 0 {
                obj.insert("mtu".into(), json!(src.wg_mtu));
            }
            if !src.server_ports.is_empty() {
                obj.insert("server_ports".into(), json!(src.server_ports));
            }
            if !src.hop_interval.is_empty() {
                obj.insert("hop_interval".into(), json!(src.hop_interval));
            }
            if src.awg_jc > 0 {
                obj.insert("jc".into(), json!(src.awg_jc));
                obj.insert("jmin".into(), json!(src.awg_jmin));
                obj.insert("jmax".into(), json!(src.awg_jmax));
                obj.insert("s1".into(), json!(src.awg_s1));
                obj.insert("s2".into(), json!(src.awg_s2));
                if src.awg_s3 > 0 {
                    obj.insert("s3".into(), json!(src.awg_s3));
                }
                if src.awg_s4 > 0 {
                    obj.insert("s4".into(), json!(src.awg_s4));
                }
                obj.insert("h1".into(), json!(src.awg_h1));
                obj.insert("h2".into(), json!(src.awg_h2));
                obj.insert("h3".into(), json!(src.awg_h3));
                obj.insert("h4".into(), json!(src.awg_h4));
            }
            for (k, v) in [
                ("i1", &src.awg_i1),
                ("i2", &src.awg_i2),
                ("i3", &src.awg_i3),
                ("i4", &src.awg_i4),
                ("i5", &src.awg_i5),
                ("j1", &src.awg_j1),
                ("j2", &src.awg_j2),
                ("j3", &src.awg_j3),
            ] {
                if !v.trim().is_empty() {
                    obj.insert(k.into(), json!(v.trim()));
                }
            }
            if src.awg_itime > 0 {
                obj.insert("itime".into(), json!(src.awg_itime));
            }
            out.push((tag, Value::Object(obj)));
        }
        "amnezia_config" => {
            let mut parsed_any = false;
            let mut texts = src.amnezia_configs.clone();
            if !src.amnezia_conf_text.trim().is_empty() {
                texts.push(src.amnezia_conf_text.clone());
            }
            for (idx, conf_text) in texts.iter().enumerate() {
                let trimmed = conf_text.trim();
                if (trimmed.starts_with("vpn://")
                    || trimmed.starts_with("awg://")
                    || trimmed.starts_with("wg://"))
                    && let Some(node) = parse_proxy_uri(trimmed, idx)
                {
                    out.push((node.tag, node.outbound_json));
                    parsed_any = true;
                    continue;
                }
                if let Some((tag, val)) = parse_amnezia_conf_outbound(&src.id, idx, conf_text) {
                    out.push((tag, val));
                    parsed_any = true;
                }
            }
            if !parsed_any && !src.wg_private_key.is_empty() {
                let tag = format!("awg-{}", src.id);
                let (host, port) = split_host_port(&src.wg_endpoint, 51820)
                    .unwrap_or_else(|| ("127.0.0.1".to_string(), 51820));
                out.push((
                    tag.clone(),
                    json!({
                        "type": "wireguard",
                        "tag": tag,
                        "server": host,
                        "server_port": port,
                        "private_key": src.wg_private_key,
                        "peer_public_key": src.wg_peer_public_key,
                        "local_address": [if src.wg_local_address.is_empty() { "10.8.0.2/32" } else { &src.wg_local_address }],
                    }),
                ));
            }
        }
        "warp" => {
            let tag = format!("warp-{}", src.id);
            let server = if src.warp_server.trim().is_empty() {
                "engage.cloudflareclient.com"
            } else {
                src.warp_server.trim()
            };
            let port = if src.warp_server_port > 0 {
                src.warp_server_port
            } else {
                2408
            };
            let priv_key = if !src.warp_private_key.is_empty() {
                &src.warp_private_key
            } else {
                &src.wg_private_key
            };
            let pub_key = if !src.warp_peer_public_key.is_empty() {
                src.warp_peer_public_key.as_str()
            } else if !src.wg_peer_public_key.is_empty() {
                src.wg_peer_public_key.as_str()
            } else {
                "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
            };
            let mut local_addrs = vec![if src.warp_ipv4.is_empty() {
                "172.16.0.2/32".to_string()
            } else {
                src.warp_ipv4.clone()
            }];
            if !src.warp_ipv6.trim().is_empty() {
                local_addrs.push(src.warp_ipv6.trim().to_string());
            }
            let mut obj = Map::new();
            obj.insert("type".into(), json!("wireguard"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            obj.insert("private_key".into(), json!(priv_key));
            obj.insert("peer_public_key".into(), json!(pub_key));
            obj.insert("local_address".into(), json!(local_addrs));
            obj.insert(
                "mtu".into(),
                json!(if src.warp_mtu > 0 { src.warp_mtu } else { 1280 }),
            );
            if !src.warp_reserved.trim().is_empty() {
                let bytes: Vec<u8> = src
                    .warp_reserved
                    .split([',', ' '])
                    .filter_map(|t| t.trim().parse::<u8>().ok())
                    .collect();
                if bytes.len() == 3 {
                    obj.insert("reserved".into(), json!(bytes));
                } else {
                    obj.insert("reserved".into(), json!(src.warp_reserved.trim()));
                }
            }
            if !src.warp_fake_packets.trim().is_empty() {
                obj.insert("fake_packets".into(), json!(src.warp_fake_packets.trim()));
                if !src.warp_fake_packets_size.trim().is_empty() {
                    obj.insert(
                        "fake_packets_size".into(),
                        json!(src.warp_fake_packets_size.trim()),
                    );
                }
                if !src.warp_fake_packets_delay.trim().is_empty() {
                    obj.insert(
                        "fake_packets_delay".into(),
                        json!(src.warp_fake_packets_delay.trim()),
                    );
                }
                if !src.warp_fake_packets_mode.trim().is_empty() {
                    obj.insert(
                        "fake_packets_mode".into(),
                        json!(src.warp_fake_packets_mode.trim()),
                    );
                }
            }
            out.push((tag, Value::Object(obj)));
        }
        "wdtt" | "csqtt" => {
            if !src.proxy_links.is_empty() {
                for (idx, link) in src.proxy_links.iter().enumerate() {
                    if let Some(node) = parse_proxy_uri(link, idx)
                        && passes_source_filters(src, &node.tag, &node.country)
                        && !out.iter().any(|(t, _)| t == &node.tag)
                    {
                        out.push((node.tag, node.outbound_json));
                    }
                }
            }
            if out.is_empty() {
                let tag = format!("wdtt-{}", src.id);
                let direct_server = if !src.csqtt_server.trim().is_empty() {
                    src.csqtt_server.trim()
                } else {
                    src.server.trim()
                };
                let uri = src.csqtt_uri.trim();
                if direct_server.is_empty() && !uri.is_empty() {
                    if let Some(mut node) = parse_proxy_uri(uri, 0)
                        && let Some(obj) = node.outbound_json.as_object_mut()
                    {
                        obj.insert("tag".into(), json!(tag));
                        out.push((tag, node.outbound_json));
                    }
                } else {
                    let server_port = if src.csqtt_server_port > 0 {
                        src.csqtt_server_port
                    } else {
                        src.server_port
                    };
                    let password = if !src.csqtt_password.is_empty() {
                        src.csqtt_password.as_str()
                    } else {
                        src.password.as_str()
                    };
                    let params = WdttParams {
                        server: direct_server,
                        server_port,
                        password,
                        mode: &src.csqtt_mode,
                        obfs: &src.csqtt_obfs,
                        raw_port: src.csqtt_raw_port,
                        wg_port: src.csqtt_wg_port,
                        local_port: src.csqtt_local_port,
                        hashes: &src.csqtt_hashes,
                        vk_auth_mode: &src.csqtt_vk_auth_mode,
                        vk_cookie: &src.csqtt_vk_cookie,
                        vk_client_ids: &src.csqtt_vk_client_ids,
                        turn_server: &src.csqtt_turn_server,
                        turn_urls: &src.csqtt_turn_urls,
                        turn_username: &src.csqtt_turn_username,
                        turn_password: &src.csqtt_turn_password,
                        turn_transport: &src.csqtt_turn_transport,
                        workers: src.csqtt_workers,
                        device_id: &src.csqtt_device_id,
                        mtu: src.csqtt_mtu,
                        chunk1: src.csqtt_chunk1,
                        wg_private_key: &src.csqtt_wg_private_key,
                        wg_peer_public_key: &src.csqtt_wg_peer_public_key,
                        wg_address: &src.csqtt_wg_address,
                    };
                    if let Some(val) = build_wdtt_outbound_value(&tag, &params) {
                        out.push((tag, val));
                    }
                }
            }
        }
        "fptn" => {
            let sni_val = if !src.fptn_sni.trim().is_empty() {
                src.fptn_sni.trim()
            } else {
                src.sni.trim()
            };
            let bypass_val = src.fptn_bypass_method.trim();
            let pref_val = src.fptn_preferred_server.trim();

            if !src.fptn_access_token.trim().is_empty() {
                out.extend(expand_fptn_token_outbounds(
                    &format!("fptn-{}", src.id),
                    &src.fptn_access_token,
                    sni_val,
                    bypass_val,
                    pref_val,
                ));
            }
            for (idx, link) in src.proxy_links.iter().enumerate() {
                let expanded = expand_fptn_token_outbounds(
                    &format!("fptn-{}-{idx}", src.id),
                    link,
                    sni_val,
                    bypass_val,
                    pref_val,
                );
                if !expanded.is_empty() {
                    out.extend(expanded);
                } else if let Some(node) = parse_proxy_uri(link, idx) {
                    out.push((node.tag, node.outbound_json));
                }
            }
            if out.is_empty() {
                let tag = format!("fptn-{}", src.id);
                let mut obj = Map::new();
                obj.insert("type".into(), json!("fptn"));
                obj.insert("tag".into(), json!(tag));
                if !src.fptn_access_token.trim().is_empty() {
                    obj.insert("token".into(), json!(src.fptn_access_token.trim()));
                }
                if !sni_val.is_empty() {
                    obj.insert("sni".into(), json!(sni_val));
                }
                if !bypass_val.is_empty() {
                    obj.insert("bypass_method".into(), json!(bypass_val));
                }
                out.push((tag, Value::Object(obj)));
            }
        }
        "tailscale" => {
            let tag = format!("tailscale-{}", src.id);
            if src.is_native_tailscale() {
                let bind_iface = if !src.bind_interface.trim().is_empty() {
                    src.bind_interface.trim()
                } else if !src.interface_name.trim().is_empty() {
                    src.interface_name.trim()
                } else {
                    "tailscale0"
                };
                out.push((
                    tag.clone(),
                    json!({
                        "type": "direct",
                        "tag": tag,
                        "bind_interface": bind_iface,
                    }),
                ));
            } else {
                let ep = build_tailscale_endpoint_json(
                    &tag,
                    &tag,
                    false,
                    &TailscaleEndpointParams::from_source(src),
                );
                out.push((tag, ep));
            }
        }
        "mtproto" => {
            let tag = format!("mtproto-{}", src.id);
            out.push((
                tag.clone(),
                json!({
                    "type": "mtproto",
                    "tag": tag,
                    "mode": if src.mtproto_telegram_ws { "telegram-ws" } else { "direct" }
                }),
            ));
        }
        "vless" | "vmess" | "trojan" | "shadowsocks" | "ss" | "hysteria2" | "tuic" | "socks"
        | "http" | "ssh" | "direct"
            if !src.server.is_empty() || src.source_type == "direct" =>
        {
            let tag = format!("{}-{}", src.source_type, src.id);
            let proto = if src.source_type == "ss" {
                "shadowsocks"
            } else {
                src.source_type.as_str()
            };
            let mut obj = Map::new();
            obj.insert("type".into(), json!(proto));
            obj.insert("tag".into(), json!(tag));
            if !src.server.is_empty() {
                obj.insert("server".into(), json!(src.server));
            }
            if src.server_port > 0 {
                obj.insert("server_port".into(), json!(src.server_port));
            }
            if !src.uuid.is_empty() {
                obj.insert("uuid".into(), json!(src.uuid));
            }
            if !src.username.is_empty() {
                obj.insert(
                    if proto == "ssh" {
                        "user".into()
                    } else {
                        "username".into()
                    },
                    json!(src.username),
                );
            }
            if !src.password.is_empty() {
                obj.insert("password".into(), json!(src.password));
            }
            if !src.method.is_empty() && proto == "shadowsocks" {
                obj.insert("method".into(), json!(src.method));
            }
            if !src.flow.is_empty() && src.flow != "none" && proto == "vless" {
                obj.insert("flow".into(), json!(src.flow));
            }
            let eff_sni = if !src.tls_sni.is_empty() {
                &src.tls_sni
            } else {
                &src.sni
            };
            if !eff_sni.is_empty()
                || !src.reality_public_key.is_empty()
                || matches!(proto, "hysteria2" | "tuic" | "trojan")
            {
                let mut tls = Map::new();
                tls.insert("enabled".into(), json!(true));
                tls.insert(
                    "server_name".into(),
                    json!(if eff_sni.is_empty() {
                        &src.server
                    } else {
                        eff_sni
                    }),
                );
                if src.tls_insecure || src.insecure {
                    tls.insert("insecure".into(), json!(true));
                }
                if !src.reality_public_key.is_empty() {
                    tls.insert(
                        "reality".into(),
                        json!({
                            "enabled": true,
                            "public_key": src.reality_public_key,
                            "short_id": src.reality_short_id
                        }),
                    );
                }
                obj.insert("tls".into(), Value::Object(tls));
            }
            if !src.transport.is_empty() && src.transport != "tcp" {
                let mut tr = Map::new();
                tr.insert("type".into(), json!(src.transport));
                if !src.transport_path.is_empty() {
                    let key = if src.transport == "grpc" {
                        "service_name"
                    } else {
                        "path"
                    };
                    tr.insert(key.into(), json!(src.transport_path));
                }
                if !src.transport_host.is_empty() && src.transport == "ws" {
                    tr.insert("headers".into(), json!({"Host": src.transport_host}));
                }
                obj.insert("transport".into(), Value::Object(tr));
            }
            out.push((tag, Value::Object(obj)));
        }
        "anytls" | "naive" | "mieru" | "snell" | "sudoku" | "masque" | "openconnect"
        | "shadowtls" | "trusttunnel" | "tewfai" | "tor" | "openvpn" => {
            let tag = format!("{}-{}", src.source_type, src.id);
            let mut obj = Map::new();
            obj.insert("type".into(), json!(src.source_type));
            obj.insert("tag".into(), json!(tag));
            if !src.server.is_empty() {
                obj.insert("server".into(), json!(src.server));
            }
            if src.server_port > 0 {
                obj.insert("server_port".into(), json!(src.server_port));
            }
            if src.source_type == "mieru" {
                let tr = src.mieru_transport.trim();
                let tr_norm = if tr.eq_ignore_ascii_case("UDP") {
                    "UDP"
                } else {
                    "TCP"
                };
                obj.insert("transport".into(), json!(tr_norm));
                if !src.server_ports.is_empty() {
                    obj.insert("server_ports".into(), json!(src.server_ports));
                }
                if !src.mieru_multiplexing.trim().is_empty() {
                    obj.insert("multiplexing".into(), json!(src.mieru_multiplexing.trim()));
                }
            }
            if !src.username.is_empty() {
                obj.insert("username".into(), json!(src.username));
            }
            if !src.password.is_empty() {
                obj.insert("password".into(), json!(src.password));
            } else if !src.psk.is_empty() {
                obj.insert("psk".into(), json!(src.psk));
            }
            if !src.uuid.is_empty() {
                obj.insert("uuid".into(), json!(src.uuid));
            }
            if !src.tls_sni.is_empty() {
                obj.insert(
                    "tls".into(),
                    json!({
                        "enabled": true,
                        "server_name": src.tls_sni,
                        "insecure": src.tls_insecure
                    }),
                );
            }
            out.push((tag, Value::Object(obj)));
        }
        "interface" => {
            let tag = format!("iface-{}", src.id);
            out.push((
                tag.clone(),
                json!({
                    "type": "direct",
                    "tag": tag,
                    "bind_interface": src.interface_name,
                }),
            ));
        }
        "custom_json" => {
            if let Ok(mut v) = serde_json::from_str::<Value>(&src.custom_json) {
                let tag = v
                    .get("tag")
                    .and_then(Value::as_str)
                    .map(String::from)
                    .unwrap_or_else(|| format!("custom-{}", src.id));
                if let Some(obj) = v.as_object_mut() {
                    obj.insert("tag".into(), json!(tag));
                    if !src.server_ports.is_empty() {
                        obj.insert("server_ports".into(), json!(src.server_ports));
                    }
                    if !src.hop_interval.is_empty() {
                        obj.insert("hop_interval".into(), json!(src.hop_interval));
                    }
                    if !src.hop_interval_max.is_empty() {
                        obj.insert("hop_interval_max".into(), json!(src.hop_interval_max));
                    }
                }
                out.push((tag, v));
            }
        }
        _ => {
            return build_filtered_source_nodes(src);
        }
    }
    raw_out
        .into_iter()
        .map(|(tag, mut v)| {
            apply_outbound_common_opts(src, &mut v);
            (tag, v, true)
        })
        .collect()
}

fn safe_tailscale_id(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[derive(Clone, Debug)]
struct TailscaleEndpointDnsMeta {
    ep_tag: String,
    is_server: bool,
    accept_dns: bool,
    accept_default_resolvers: bool,
    advertise_exit_node: bool,
}

struct TailscaleEndpointParams<'a> {
    auth_key: &'a str,
    control_url: &'a str,
    hostname: &'a str,
    ephemeral: bool,
    accept_routes: bool,
    exit_node: &'a str,
    exit_node_allow_lan_access: bool,
    advertise_routes: &'a [String],
    advertise_exit_node: bool,
    relay_server_port: &'a str,
    relay_server_static_endpoints: &'a [String],
    system_interface: bool,
    system_interface_name: &'a str,
    system_interface_mtu: &'a str,
    udp_timeout: &'a str,
    detour: &'a str,
    bind_interface: &'a str,
}

impl<'a> TailscaleEndpointParams<'a> {
    fn from_source(src: &'a OutboundSource) -> Self {
        let detour =
            if src.outbound_detour_enabled && !src.outbound_detour_section.trim().is_empty() {
                src.outbound_detour_section.trim()
            } else {
                ""
            };
        let bind_interface = if !src.bind_interface.trim().is_empty() {
            src.bind_interface.trim()
        } else {
            src.interface_name.trim()
        };
        Self {
            auth_key: &src.tailscale_auth_key,
            control_url: &src.tailscale_control_url,
            hostname: &src.tailscale_hostname,
            ephemeral: src.tailscale_ephemeral,
            accept_routes: src.tailscale_accept_routes,
            exit_node: &src.tailscale_use_exit_node,
            exit_node_allow_lan_access: src.tailscale_exit_node_allow_lan_access,
            advertise_routes: &src.tailscale_advertise_routes,
            advertise_exit_node: src.tailscale_advertise_exit_node,
            relay_server_port: &src.tailscale_relay_server_port,
            relay_server_static_endpoints: &src.tailscale_relay_server_static_endpoints,
            system_interface: src.tailscale_system_interface,
            system_interface_name: &src.tailscale_system_interface_name,
            system_interface_mtu: &src.tailscale_system_interface_mtu,
            udp_timeout: &src.tailscale_udp_timeout,
            detour,
            bind_interface,
        }
    }

    fn from_section(sec: &'a RoutingSection) -> Self {
        let detour =
            if sec.outbound_detour_enabled && !sec.outbound_detour_section.trim().is_empty() {
                sec.outbound_detour_section.trim()
            } else {
                ""
            };
        Self {
            auth_key: &sec.tailscale_auth_key,
            control_url: &sec.tailscale_control_url,
            hostname: &sec.tailscale_hostname,
            ephemeral: sec.tailscale_ephemeral,
            accept_routes: sec.tailscale_accept_routes,
            exit_node: &sec.tailscale_use_exit_node,
            exit_node_allow_lan_access: sec.tailscale_exit_node_allow_lan_access,
            advertise_routes: &sec.tailscale_advertise_routes,
            advertise_exit_node: sec.tailscale_advertise_exit_node,
            relay_server_port: &sec.tailscale_relay_server_port,
            relay_server_static_endpoints: &sec.tailscale_relay_server_static_endpoints,
            system_interface: sec.tailscale_system_interface,
            system_interface_name: &sec.tailscale_system_interface_name,
            system_interface_mtu: &sec.tailscale_system_interface_mtu,
            udp_timeout: &sec.tailscale_udp_timeout,
            detour,
            bind_interface: sec.bind_interface.trim(),
        }
    }

    fn from_server(srv: &'a InboundServer) -> Self {
        Self {
            auth_key: &srv.tailscale_auth_key,
            control_url: &srv.tailscale_control_url,
            hostname: &srv.tailscale_hostname,
            ephemeral: srv.tailscale_ephemeral,
            accept_routes: srv.tailscale_accept_routes,
            exit_node: &srv.tailscale_use_exit_node,
            exit_node_allow_lan_access: srv.tailscale_exit_node_allow_lan_access,
            advertise_routes: &srv.tailscale_advertise_routes,
            advertise_exit_node: srv.tailscale_advertise_exit_node,
            relay_server_port: &srv.tailscale_relay_server_port,
            relay_server_static_endpoints: &srv.tailscale_relay_server_static_endpoints,
            system_interface: srv.tailscale_system_interface,
            system_interface_name: &srv.tailscale_system_interface_name,
            system_interface_mtu: &srv.tailscale_system_interface_mtu,
            udp_timeout: &srv.tailscale_udp_timeout,
            detour: "",
            bind_interface: "",
        }
    }
}

fn split_csv_list(items: &[String]) -> Vec<String> {
    items
        .iter()
        .flat_map(|item| item.split(','))
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

fn build_tailscale_endpoint_json(
    tag: &str,
    state_id: &str,
    is_server: bool,
    p: &TailscaleEndpointParams<'_>,
) -> Value {
    let safe_id = safe_tailscale_id(state_id);
    let state_dir = format!(
        "{}{safe_id}",
        if p.ephemeral {
            "/var/run/tachyon/tailscale/"
        } else {
            "/etc/tachyon/tailscale/"
        }
    );
    let ctrl = if p.control_url.trim().is_empty() {
        "https://controlplane.tailscale.com"
    } else {
        p.control_url.trim()
    };
    let hostname = if p.hostname.trim().is_empty() {
        format!("tachyon-{safe_id}")
    } else {
        p.hostname.trim().to_string()
    };
    let mut ep = Map::new();
    ep.insert("type".into(), json!("tailscale"));
    ep.insert("tag".into(), json!(tag));
    ep.insert("state_directory".into(), json!(state_dir));
    ep.insert("control_url".into(), json!(ctrl));
    ep.insert("hostname".into(), json!(hostname));
    if !p.auth_key.trim().is_empty() {
        ep.insert("auth_key".into(), json!(p.auth_key.trim()));
    }
    if !is_server || p.ephemeral {
        ep.insert("ephemeral".into(), json!(p.ephemeral));
    }
    if !is_server || p.accept_routes {
        ep.insert("accept_routes".into(), json!(p.accept_routes));
    }
    if !p.exit_node.trim().is_empty() {
        ep.insert("exit_node".into(), json!(p.exit_node.trim()));
    }
    if p.exit_node_allow_lan_access {
        ep.insert("exit_node_allow_lan_access".into(), json!(true));
    }
    let advertise_routes = split_csv_list(p.advertise_routes);
    if !advertise_routes.is_empty() {
        ep.insert("advertise_routes".into(), json!(advertise_routes));
    }
    if p.advertise_exit_node {
        ep.insert("advertise_exit_node".into(), json!(true));
    }
    if let Ok(port) = p.relay_server_port.trim().parse::<u16>()
        && port > 0
    {
        ep.insert("relay_server_port".into(), json!(port));
    }
    let relay_endpoints = split_csv_list(p.relay_server_static_endpoints);
    if !relay_endpoints.is_empty() {
        ep.insert(
            "relay_server_static_endpoints".into(),
            json!(relay_endpoints),
        );
    }
    if p.system_interface {
        ep.insert("system_interface".into(), json!(true));
        if !p.system_interface_name.trim().is_empty() {
            ep.insert(
                "system_interface_name".into(),
                json!(p.system_interface_name.trim()),
            );
        }
        if let Ok(mtu) = p.system_interface_mtu.trim().parse::<u32>()
            && mtu > 0
        {
            ep.insert("system_interface_mtu".into(), json!(mtu));
        }
    }
    if !p.udp_timeout.trim().is_empty() {
        ep.insert("udp_timeout".into(), json!(p.udp_timeout.trim()));
    }
    if !is_server {
        if !p.detour.trim().is_empty() {
            ep.insert("detour".into(), json!(p.detour.trim()));
        } else if !p.bind_interface.trim().is_empty() {
            ep.insert("bind_interface".into(), json!(p.bind_interface.trim()));
        }
    }
    Value::Object(ep)
}

fn normalize_imported_tailscale_endpoint(
    mut val: Value,
    default_tag: &str,
    dns_overrides: Option<(bool, bool)>,
) -> (Value, TailscaleEndpointDnsMeta) {
    let mut ep_tag = default_tag.to_string();
    let mut accept_dns = true;
    let mut accept_default_resolvers = true;
    let mut advertise_exit_node = false;
    if let Some(obj) = val.as_object_mut() {
        if let Some(t) = obj
            .get("tag")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            ep_tag = t.to_string();
        } else {
            obj.insert("tag".into(), json!(ep_tag));
        }
        let json_accept_dns = obj
            .remove("accept_dns")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let json_accept_default_resolvers = obj
            .remove("accept_default_resolvers")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        if let Some((ovr_dns, ovr_res)) = dns_overrides {
            accept_dns = ovr_dns;
            accept_default_resolvers = ovr_res;
        } else {
            accept_dns = json_accept_dns;
            accept_default_resolvers = json_accept_default_resolvers;
        }
        advertise_exit_node = obj
            .get("advertise_exit_node")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if obj
            .get("auth_key")
            .and_then(Value::as_str)
            .is_some_and(|s| s.trim().is_empty())
        {
            obj.remove("auth_key");
        }
        if let Some(legacy_exit) = obj.remove("use_exit_node")
            && !obj.contains_key("exit_node")
            && let Some(s) = legacy_exit
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty())
        {
            obj.insert("exit_node".into(), json!(s));
        }
        let missing_state = obj
            .get("state_directory")
            .and_then(Value::as_str)
            .is_none_or(|s| s.trim().is_empty());
        if missing_state {
            let ephemeral = obj
                .get("ephemeral")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let base = if ephemeral {
                "/var/run/tachyon/tailscale/"
            } else {
                "/etc/tachyon/tailscale/"
            };
            obj.insert(
                "state_directory".into(),
                json!(format!("{base}{}", safe_tailscale_id(&ep_tag))),
            );
        }
    }
    (
        val,
        TailscaleEndpointDnsMeta {
            ep_tag,
            is_server: false,
            accept_dns,
            accept_default_resolvers,
            advertise_exit_node,
        },
    )
}

fn xray_duration_seconds(raw: &str) -> Option<f64> {
    let text = raw.trim();
    if text.is_empty() {
        return None;
    }
    if text.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        && text != "."
        && let Ok(v) = text.parse::<f64>()
        && v.is_finite()
    {
        return Some(v);
    }
    let mut total = 0.0_f64;
    let mut found = false;
    let mut rest = text;
    while !rest.is_empty() {
        let num_end = rest
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(rest.len());
        if num_end == 0 {
            return None;
        }
        let num_str = &rest[..num_end];
        if num_str == "." {
            return None;
        }
        let num: f64 = num_str.parse().ok()?;
        if !num.is_finite() {
            return None;
        }
        rest = &rest[num_end..];
        let (unit_len, scale) = if rest.starts_with("ns") {
            (2, 1e-9)
        } else if rest.starts_with("us") {
            (2, 1e-6)
        } else if rest.starts_with("µs") {
            ("µs".len(), 1e-6)
        } else if rest.starts_with("μs") {
            ("μs".len(), 1e-6)
        } else if rest.starts_with("ms") {
            (2, 1e-3)
        } else if rest.starts_with('d') {
            (1, 86_400.0)
        } else if rest.starts_with('h') {
            (1, 3_600.0)
        } else if rest.starts_with('m') {
            (1, 60.0)
        } else if rest.starts_with('s') {
            (1, 1.0)
        } else {
            return None;
        };
        total += num * scale;
        found = true;
        rest = &rest[unit_len..];
    }
    found.then_some(total)
}

fn xray_clamp_probe_interval(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Some(secs) = xray_duration_seconds(trimmed)
        && secs < 30.0
    {
        return "30s".to_string();
    }
    trimmed.to_string()
}

fn json_str_at<'a>(val: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|k| val.get(*k).and_then(Value::as_str).map(str::trim))
        .filter(|s| !s.is_empty())
}

fn json_bool_at(val: &Value, keys: &[&str]) -> bool {
    keys.iter().any(|k| {
        val.get(*k).is_some_and(|v| {
            v.as_bool() == Some(true)
                || v.as_i64() == Some(1)
                || v.as_str()
                    .is_some_and(|s| matches!(s.trim().to_ascii_lowercase().as_str(), "1" | "true"))
        })
    })
}

fn json_opt_bool_at(val: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|k| {
        let v = val.get(*k)?;
        if let Some(b) = v.as_bool() {
            return Some(b);
        }
        if let Some(n) = v.as_i64() {
            return Some(n != 0);
        }
        v.as_str()
            .and_then(|s| match s.trim().to_ascii_lowercase().as_str() {
                "1" | "true" | "yes" => Some(true),
                "0" | "false" | "no" => Some(false),
                _ => None,
            })
    })
}

fn json_port_at(vals: &[Option<&Value>]) -> Option<u16> {
    for v in vals.iter().flatten() {
        if let Some(p) = parse_json_u16(v)
            && p > 0
        {
            return Some(p);
        }
    }
    None
}

fn make_unique_tag(base: &str, taken: &mut HashSet<String>) -> String {
    let base = if base.trim().is_empty() {
        "server"
    } else {
        base.trim()
    };
    if taken.insert(base.to_string()) {
        return base.to_string();
    }
    for n in 1..100_000usize {
        let cand = format!("{base}-{n}");
        if taken.insert(cand.clone()) {
            return cand;
        }
    }
    format!("{base}-overflow")
}

fn has_ascii_digits_with_optional_sep(s: &str) -> bool {
    if s.is_empty() {
        return true;
    }
    let trimmed = s.strip_prefix(['-', '_', ' ']).unwrap_or(s);
    !trimmed.is_empty() && trimmed.chars().all(|c| c.is_ascii_digit())
}

fn is_bal_internal_tag(tag_lc: &str) -> bool {
    let Some(rest) = tag_lc.strip_prefix("bal-") else {
        return false;
    };
    let digits = rest.chars().take_while(|c| c.is_ascii_digit()).count();
    digits > 0 && rest[digits..].starts_with('-')
}

fn is_reserve_like_tag(tag_lc: &str) -> bool {
    let prefixes = ["reserve", "backup", "fallback"];
    for p in prefixes {
        if let Some(rest) = tag_lc.strip_prefix(p) {
            if rest.is_empty() || has_ascii_digits_with_optional_sep(rest) {
                return true;
            }
            if let Some((first, second)) = rest.split_once('-')
                && has_ascii_digits_with_optional_sep(first)
                && !second.is_empty()
                && second.chars().all(|c| c.is_ascii_digit())
            {
                return true;
            }
        }
    }
    false
}

fn is_generic_proxy_tag(tag_lc: &str) -> bool {
    for p in [
        "proxy",
        "main",
        "out",
        "vless",
        "vmess",
        "trojan",
        "shadowsocks",
        "ss",
        "hysteria2",
        "hysteria",
        "tuic",
        "server",
    ] {
        if let Some(rest) = tag_lc.strip_prefix(p)
            && has_ascii_digits_with_optional_sep(rest)
        {
            return true;
        }
    }
    false
}

fn parse_packet_size_range(val: &Value) -> Option<(u64, u64)> {
    let raw = val.as_str()?.trim();
    let (a, b) = raw.split_once('-')?;
    let lo = a.trim().parse::<u64>().ok()?;
    let hi = b.trim().parse::<u64>().ok()?;
    if lo > 0 && hi >= lo {
        Some((lo, hi))
    } else {
        None
    }
}

fn xray_tls_from_stream(stream: &Value, network: &str) -> Option<Value> {
    let security = json_str_at(stream, &["security"])
        .unwrap_or("")
        .to_ascii_lowercase();
    let reality = stream.get("realitySettings").unwrap_or(&Value::Null);
    let tls_settings = stream.get("tlsSettings").unwrap_or(&Value::Null);
    let settings = if security == "reality" {
        reality
    } else {
        tls_settings
    };
    let has_settings = settings.as_object().is_some_and(|m| !m.is_empty());
    if !matches!(security.as_str(), "tls" | "xtls" | "reality") && !has_settings {
        return None;
    }

    let mut tls = Map::new();
    tls.insert("enabled".into(), json!(true));
    if let Some(sni) = json_str_at(settings, &["serverName", "server_name", "sni"]) {
        tls.insert("server_name".into(), json!(sni));
    }
    if json_bool_at(settings, &["allowInsecure", "insecure"]) {
        tls.insert("insecure".into(), json!(true));
    }
    let mut alpn: Vec<String> = match settings.get("alpn") {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect(),
        Some(Value::String(s)) => s
            .split(',')
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(String::from)
            .collect(),
        _ => Vec::new(),
    };
    if alpn.is_empty() && matches!(network, "http" | "h2" | "grpc" | "xhttp") {
        alpn.push("h2".to_string());
    }
    if !alpn.is_empty() {
        tls.insert("alpn".into(), json!(alpn));
    }
    if let Some(fp) = json_str_at(settings, &["fingerprint", "fp"]) {
        tls.insert("utls".into(), json!({ "enabled": true, "fingerprint": fp }));
    }
    if let Some(pin) = json_str_at(
        settings,
        &["pinnedPeerCertSha256", "pinned_peer_cert_sha256"],
    ) {
        tls.insert("certificate_sha256".into(), json!([pin]));
    }
    let has_reality = reality.as_object().is_some_and(|m| !m.is_empty());
    if security == "reality" || has_reality {
        let mut r_obj = Map::new();
        r_obj.insert("enabled".into(), json!(true));
        if let Some(pk) = json_str_at(reality, &["publicKey", "public_key"])
            .or_else(|| json_str_at(settings, &["publicKey", "public_key"]))
        {
            r_obj.insert("public_key".into(), json!(pk));
        }
        if let Some(sid) = json_str_at(reality, &["shortId", "short_id"])
            .or_else(|| json_str_at(settings, &["shortId", "short_id"]))
        {
            r_obj.insert("short_id".into(), json!(sid));
        }
        if let Some(mlkem) = json_opt_bool_at(
            reality,
            &[
                "support_x25519mlkem768",
                "supportX25519MLKEM768",
                "support-x25519mlkem768",
            ],
        )
        .or_else(|| {
            json_opt_bool_at(
                settings,
                &[
                    "support_x25519mlkem768",
                    "supportX25519MLKEM768",
                    "support-x25519mlkem768",
                ],
            )
        }) {
            r_obj.insert("support_x25519mlkem768".into(), json!(mlkem));
        } else if json_str_at(reality, &["mldsa65Verify", "pqv"])
            .or_else(|| json_str_at(settings, &["mldsa65Verify", "pqv"]))
            .is_some()
        {
            r_obj.insert("support_x25519mlkem768".into(), json!(true));
        }
        tls.insert("reality".into(), Value::Object(r_obj));
        if !tls.contains_key("utls") {
            tls.insert(
                "utls".into(),
                json!({ "enabled": true, "fingerprint": "chrome" }),
            );
        }
    }
    let has_tcp_frag = stream
        .get("finalmask")
        .and_then(|fm| fm.get("tcp"))
        .and_then(Value::as_array)
        .is_some_and(|arr| {
            arr.iter().any(|e| {
                json_str_at(e, &["type"]).is_some_and(|t| t.eq_ignore_ascii_case("fragment"))
            })
        });
    if json_bool_at(settings, &["fragment", "tls_fragment"]) || has_tcp_frag {
        tls.insert("fragment".into(), json!(true));
    }
    Some(Value::Object(tls))
}

fn xray_transport_from_stream(stream: &Value) -> Option<Value> {
    let network = json_str_at(stream, &["network"])
        .unwrap_or("")
        .to_ascii_lowercase();
    match network.as_str() {
        "" | "tcp" => None,
        "ws" => {
            let s = stream.get("wsSettings").unwrap_or(&Value::Null);
            let mut tr = Map::new();
            tr.insert("type".into(), json!("ws"));
            tr.insert(
                "path".into(),
                json!(json_str_at(s, &["path"]).unwrap_or("/")),
            );
            if let Some(host) = s
                .get("headers")
                .and_then(|h| json_str_at(h, &["Host", "host"]))
                .or_else(|| json_str_at(s, &["host"]))
            {
                tr.insert("headers".into(), json!({ "Host": host }));
            }
            Some(Value::Object(tr))
        }
        "grpc" => {
            let s = stream.get("grpcSettings").unwrap_or(&Value::Null);
            let mut tr = Map::new();
            tr.insert("type".into(), json!("grpc"));
            if let Some(sn) = json_str_at(s, &["serviceName", "service_name"]) {
                tr.insert("service_name".into(), json!(sn));
            }
            Some(Value::Object(tr))
        }
        "http" | "h2" => {
            let s = stream.get("httpSettings").unwrap_or(&Value::Null);
            let mut tr = Map::new();
            tr.insert("type".into(), json!("http"));
            if let Some(path) = s.get("path").and_then(|p| {
                p.as_array()
                    .and_then(|a| a.first())
                    .and_then(Value::as_str)
                    .or_else(|| p.as_str())
            }) {
                tr.insert("path".into(), json!(path));
            }
            if let Some(host) = s.get("host") {
                if let Some(arr) = host.as_array() {
                    tr.insert("host".into(), Value::Array(arr.clone()));
                } else if let Some(h) = host.as_str()
                    && !h.trim().is_empty()
                {
                    let hosts: Vec<&str> = h
                        .split(',')
                        .map(str::trim)
                        .filter(|v| !v.is_empty())
                        .collect();
                    tr.insert("host".into(), json!(hosts));
                }
            }
            Some(Value::Object(tr))
        }
        "httpupgrade" => {
            let s = stream.get("httpupgradeSettings").unwrap_or(&Value::Null);
            let mut tr = Map::new();
            tr.insert("type".into(), json!("httpupgrade"));
            if let Some(path) = json_str_at(s, &["path"]) {
                tr.insert("path".into(), json!(path));
            }
            if let Some(host) = json_str_at(s, &["host"]) {
                tr.insert("host".into(), json!(host));
            }
            Some(Value::Object(tr))
        }
        "xhttp" => {
            let s = stream.get("xhttpSettings").unwrap_or(&Value::Null);
            let mode = match json_str_at(s, &["mode"]).unwrap_or("auto") {
                m @ ("auto" | "packet-up" | "stream-up" | "stream-one") => m,
                _ => "auto",
            };
            let mut tr = Map::new();
            tr.insert("type".into(), json!("xhttp"));
            tr.insert("mode".into(), json!(mode));
            tr.insert(
                "path".into(),
                json!(json_str_at(s, &["path"]).unwrap_or("/")),
            );
            if let Some(host) = json_str_at(s, &["host"]) {
                tr.insert("host".into(), json!(host));
            }
            if let Some(xp) = json_str_at(s, &["xPaddingBytes", "x_padding_bytes"]) {
                tr.insert("x_padding_bytes".into(), json!(xp));
            }
            if let Some(ng) =
                json_opt_bool_at(s, &["noGRPCHeader", "noGrpcHeader", "no_grpc_header"])
            {
                tr.insert("no_grpc_header".into(), json!(ng));
            }
            if let Some(xmux) = s.get("xmux").filter(|v| v.is_object()) {
                tr.insert("xmux".into(), xmux.clone());
            }
            Some(Value::Object(tr))
        }
        _ => None,
    }
}

fn convert_xray_outbound_to_singbox(outbound: &Value, tag: &str) -> Option<Value> {
    let proto = json_str_at(outbound, &["protocol"])?.to_ascii_lowercase();
    let settings = outbound.get("settings").unwrap_or(&Value::Null);
    let stream = outbound.get("streamSettings").unwrap_or(&Value::Null);
    let network = json_str_at(stream, &["network"])
        .unwrap_or("")
        .to_ascii_lowercase();

    let mut obj = Map::new();
    obj.insert("tag".into(), json!(tag));

    match proto.as_str() {
        "vless" => {
            let vnext = settings
                .get("vnext")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let user = vnext
                .get("users")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let server = json_str_at(vnext, &["address"])
                .or_else(|| json_str_at(outbound, &["server", "address"]))
                .or_else(|| json_str_at(settings, &["address"]))?;
            let port = json_port_at(&[
                vnext.get("port"),
                outbound.get("server_port"),
                outbound.get("port"),
                settings.get("port"),
            ])?;
            let uuid = json_str_at(user, &["id"])
                .or_else(|| json_str_at(outbound, &["uuid", "id"]))
                .or_else(|| json_str_at(settings, &["id"]))?;
            obj.insert("type".into(), json!("vless"));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            obj.insert("uuid".into(), json!(uuid));
            if let Some(flow) = json_str_at(user, &["flow"])
                .or_else(|| json_str_at(outbound, &["flow"]))
                .or_else(|| json_str_at(settings, &["flow"]))
            {
                obj.insert("flow".into(), json!(flow));
            }
            if let Some(tls) = xray_tls_from_stream(stream, &network) {
                obj.insert("tls".into(), tls);
            }
            if let Some(tr) = xray_transport_from_stream(stream) {
                obj.insert("transport".into(), tr);
            }
        }
        "vmess" => {
            let vnext = settings
                .get("vnext")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let user = vnext
                .get("users")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let server = json_str_at(vnext, &["address"])
                .or_else(|| json_str_at(outbound, &["server", "address"]))
                .or_else(|| json_str_at(settings, &["address"]))?;
            let port = json_port_at(&[
                vnext.get("port"),
                outbound.get("server_port"),
                outbound.get("port"),
                settings.get("port"),
            ])?;
            let uuid = json_str_at(user, &["id"])
                .or_else(|| json_str_at(outbound, &["uuid", "id"]))
                .or_else(|| json_str_at(settings, &["id"]))?;
            let sec = json_str_at(user, &["security"])
                .or_else(|| json_str_at(outbound, &["security"]))
                .unwrap_or("auto");
            obj.insert("type".into(), json!("vmess"));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            obj.insert("uuid".into(), json!(uuid));
            obj.insert("security".into(), json!(sec));
            if let Some(aid) = user.get("alterId").and_then(Value::as_u64) {
                obj.insert("alter_id".into(), json!(aid));
            }
            if let Some(tls) = xray_tls_from_stream(stream, &network) {
                obj.insert("tls".into(), tls);
            }
            if let Some(tr) = xray_transport_from_stream(stream) {
                obj.insert("transport".into(), tr);
            }
        }
        "trojan" => {
            let srv = settings
                .get("servers")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let server = json_str_at(srv, &["address"])
                .or_else(|| json_str_at(outbound, &["server", "address"]))
                .or_else(|| json_str_at(settings, &["address"]))?;
            let port = json_port_at(&[
                srv.get("port"),
                outbound.get("server_port"),
                outbound.get("port"),
                settings.get("port"),
            ])?;
            let password = json_str_at(srv, &["password"])
                .or_else(|| json_str_at(outbound, &["password"]))
                .or_else(|| json_str_at(settings, &["password"]))?;
            obj.insert("type".into(), json!("trojan"));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            obj.insert("password".into(), json!(password));
            if let Some(tls) = xray_tls_from_stream(stream, &network) {
                obj.insert("tls".into(), tls);
            }
            if let Some(tr) = xray_transport_from_stream(stream) {
                obj.insert("transport".into(), tr);
            }
        }
        "shadowsocks" | "ss" => {
            let srv = settings
                .get("servers")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let server = json_str_at(srv, &["address"])
                .or_else(|| json_str_at(outbound, &["server", "address"]))
                .or_else(|| json_str_at(settings, &["address"]))?;
            let port = json_port_at(&[
                srv.get("port"),
                outbound.get("server_port"),
                outbound.get("port"),
                settings.get("port"),
            ])?;
            let method = json_str_at(srv, &["method", "cipher"])
                .or_else(|| json_str_at(outbound, &["method", "cipher"]))
                .or_else(|| json_str_at(settings, &["method", "cipher"]))?;
            let password = json_str_at(srv, &["password"])
                .or_else(|| json_str_at(outbound, &["password"]))
                .or_else(|| json_str_at(settings, &["password"]))?;
            obj.insert("type".into(), json!("shadowsocks"));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            obj.insert("method".into(), json!(method));
            obj.insert("password".into(), json!(password));
        }
        "socks" | "http" => {
            let srv = settings
                .get("servers")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let user = srv
                .get("users")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .unwrap_or(&Value::Null);
            let server = json_str_at(srv, &["address"])
                .or_else(|| json_str_at(outbound, &["server", "address"]))?;
            let port = json_port_at(&[
                srv.get("port"),
                outbound.get("server_port"),
                outbound.get("port"),
            ])?;
            obj.insert("type".into(), json!(proto));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            if let Some(u) = json_str_at(user, &["user", "username"]) {
                obj.insert("username".into(), json!(u));
            }
            if let Some(pw) = json_str_at(user, &["pass", "password"]) {
                obj.insert("password".into(), json!(pw));
            }
            if proto == "http"
                && let Some(tls) = xray_tls_from_stream(stream, &network)
            {
                obj.insert("tls".into(), tls);
            }
        }
        "hysteria" | "hysteria2" | "hy2" => {
            let hy_set = stream.get("hysteriaSettings").unwrap_or(&Value::Null);
            let version = settings
                .get("version")
                .and_then(Value::as_u64)
                .or_else(|| hy_set.get("version").and_then(Value::as_u64))
                .unwrap_or(if matches!(proto.as_str(), "hysteria2" | "hy2") {
                    2
                } else {
                    0
                });
            if version != 2 {
                return None;
            }
            let server = json_str_at(settings, &["address", "server"])
                .or_else(|| json_str_at(outbound, &["server", "address"]))?;
            let port = json_port_at(&[
                settings.get("port"),
                outbound.get("server_port"),
                outbound.get("port"),
            ])?;
            let password = json_str_at(hy_set, &["auth"])
                .or_else(|| json_str_at(settings, &["auth", "password"]))
                .or_else(|| json_str_at(outbound, &["password"]))?;
            obj.insert("type".into(), json!("hysteria2"));
            obj.insert("server".into(), json!(server));
            obj.insert("server_port".into(), json!(port));
            obj.insert("password".into(), json!(password));

            let tls_s = stream.get("tlsSettings").unwrap_or(&Value::Null);
            let mut tls = Map::new();
            tls.insert("enabled".into(), json!(true));
            if let Some(sni) = json_str_at(tls_s, &["serverName", "server_name", "sni"]) {
                tls.insert("server_name".into(), json!(sni));
            }
            if json_bool_at(tls_s, &["allowInsecure", "insecure"]) {
                tls.insert("insecure".into(), json!(true));
            }
            if let Some(Value::Array(arr)) = tls_s.get("alpn")
                && !arr.is_empty()
            {
                tls.insert("alpn".into(), Value::Array(arr.clone()));
            }
            obj.insert("tls".into(), Value::Object(tls));

            let finalmask = stream.get("finalmask").unwrap_or(&Value::Null);
            let mask_entries: Vec<&Value> = match finalmask.get("udp") {
                Some(Value::Array(arr)) => arr.iter().collect(),
                Some(v @ Value::Object(_)) => vec![v],
                _ => Vec::new(),
            };
            let mut obfs_pw = String::new();
            let mut is_gecko = false;
            let mut min_ps = 0u64;
            let mut max_ps = 0u64;
            for entry in mask_entries {
                let utype = json_str_at(entry, &["type"])
                    .unwrap_or("salamander")
                    .to_ascii_lowercase();
                let u_set = entry.get("settings").unwrap_or(&Value::Null);
                if matches!(utype.as_str(), "salamander" | "gecko") {
                    if utype == "gecko"
                        || json_str_at(u_set, &["mode"])
                            .or_else(|| json_str_at(entry, &["mode"]))
                            .is_some_and(|m| m.eq_ignore_ascii_case("gecko"))
                    {
                        is_gecko = true;
                    }
                    if let Some(pw) = json_str_at(u_set, &["password"])
                        .or_else(|| json_str_at(entry, &["password"]))
                    {
                        obfs_pw = pw.to_string();
                    }
                    if let Some((lo, hi)) = u_set
                        .get("packetSize")
                        .or_else(|| u_set.get("packet_size"))
                        .or_else(|| entry.get("packetSize"))
                        .and_then(parse_packet_size_range)
                    {
                        min_ps = lo;
                        max_ps = hi;
                    }
                    if let Some(lo) = u_set
                        .get("minPacketSize")
                        .or_else(|| u_set.get("min_packet_size"))
                        .and_then(Value::as_u64)
                    {
                        min_ps = lo;
                    }
                    if let Some(hi) = u_set
                        .get("maxPacketSize")
                        .or_else(|| u_set.get("max_packet_size"))
                        .and_then(Value::as_u64)
                    {
                        max_ps = hi;
                    }
                }
            }
            if !obfs_pw.is_empty() {
                let mut obfs = Map::new();
                obfs.insert(
                    "type".into(),
                    json!(if is_gecko { "gecko" } else { "salamander" }),
                );
                obfs.insert("password".into(), json!(obfs_pw));
                if is_gecko && min_ps > 0 {
                    obfs.insert("min_packet_size".into(), json!(min_ps));
                }
                if is_gecko && max_ps > 0 {
                    obfs.insert("max_packet_size".into(), json!(max_ps));
                }
                obj.insert("obfs".into(), Value::Object(obfs));
            }
        }
        _ => return None,
    }
    Some(Value::Object(obj))
}

fn normalize_xray_json_configs(configs: &[Value]) -> Vec<ParsedProxyNode> {
    struct PlannedXray {
        outbound: Value,
        orig_tag: String,
        unique_tag: String,
        detour_orig: Option<String>,
    }

    let mut taken: HashSet<String> = HashSet::new();
    let mut nodes: Vec<ParsedProxyNode> = Vec::new();

    for cfg in configs {
        let Some(raw_obs) = cfg.get("outbounds").and_then(Value::as_array) else {
            continue;
        };
        let display_name = json_str_at(cfg, &["remarks", "remark", "name", "ps"])
            .unwrap_or("")
            .to_string();

        let mut planned: Vec<PlannedXray> = Vec::new();
        let mut tag_map: HashMap<String, String> = HashMap::new();
        for (i, ob) in raw_obs.iter().enumerate() {
            let Some(proto) = json_str_at(ob, &["protocol"]) else {
                continue;
            };
            let proto_lc = proto.to_ascii_lowercase();
            if !matches!(
                proto_lc.as_str(),
                "vless"
                    | "vmess"
                    | "trojan"
                    | "shadowsocks"
                    | "ss"
                    | "socks"
                    | "http"
                    | "hysteria"
                    | "hysteria2"
                    | "hy2"
            ) {
                continue;
            }
            let orig_tag = json_str_at(ob, &["tag"])
                .map(String::from)
                .unwrap_or_else(|| format!("{proto_lc}-{}", i + 1));
            let unique_tag = make_unique_tag(&orig_tag, &mut taken);
            tag_map.insert(orig_tag.clone(), unique_tag.clone());
            let detour_orig = ob
                .get("proxySettings")
                .and_then(|p| json_str_at(p, &["tag"]))
                .or_else(|| {
                    ob.get("streamSettings")
                        .and_then(|s| s.get("sockopt"))
                        .and_then(|so| json_str_at(so, &["dialerProxy"]))
                })
                .map(String::from);
            planned.push(PlannedXray {
                outbound: ob.clone(),
                orig_tag,
                unique_tag,
                detour_orig,
            });
        }
        if planned.is_empty() {
            continue;
        }

        let balancers = cfg
            .get("routing")
            .and_then(|r| r.get("balancers"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        struct BalPlan {
            tag: String,
            member_orig_tags: Vec<String>,
        }
        let mut bal_plans: Vec<BalPlan> = Vec::new();
        let mut in_balancer_orig: HashSet<String> = HashSet::new();
        for bal in &balancers {
            let sels: Vec<String> = bal
                .get("selector")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(String::from)
                        .collect()
                })
                .unwrap_or_default();
            let mut matched = Vec::new();
            for item in &planned {
                if sels
                    .iter()
                    .any(|sel| item.orig_tag.starts_with(sel.as_str()))
                    && !matched.contains(&item.orig_tag)
                {
                    in_balancer_orig.insert(item.orig_tag.clone());
                    matched.push(item.orig_tag.clone());
                }
            }
            if !matched.is_empty() {
                bal_plans.push(BalPlan {
                    tag: json_str_at(bal, &["tag"]).unwrap_or("").to_string(),
                    member_orig_tags: matched,
                });
            }
        }

        let mut detour_deps: HashSet<String> = HashSet::new();
        for item in &planned {
            if let Some(d) = &item.detour_orig
                && tag_map.contains_key(d)
            {
                detour_deps.insert(d.clone());
            }
        }

        if !bal_plans.is_empty() {
            let obs = cfg.get("observatory");
            let burst = cfg
                .get("burstObservatory")
                .or_else(|| cfg.get("burst_observatory"));
            let ping_cfg = burst.and_then(|b| b.get("pingConfig").or_else(|| b.get("ping_config")));
            let xray_ut_url = [
                ping_cfg.and_then(|p| json_str_at(p, &["destination"])),
                burst.and_then(|b| json_str_at(b, &["probeUrl", "probe_url"])),
                obs.and_then(|o| json_str_at(o, &["probeUrl", "probe_url"])),
            ]
            .into_iter()
            .flatten()
            .find(|s| !s.is_empty())
            .map(String::from);
            let xray_ut_interval = [
                ping_cfg.and_then(|p| json_str_at(p, &["interval"])),
                burst.and_then(|b| json_str_at(b, &["probeInterval", "probe_interval"])),
                obs.and_then(|o| json_str_at(o, &["probeInterval", "probe_interval"])),
            ]
            .into_iter()
            .flatten()
            .find(|s| !s.is_empty())
            .map(xray_clamp_probe_interval)
            .filter(|s| !s.is_empty());

            let mut member_group_label: HashMap<String, String> = HashMap::new();
            for (plan_idx, plan) in bal_plans.iter().enumerate() {
                let group_base = if bal_plans.len() == 1 && !display_name.is_empty() {
                    display_name.clone()
                } else if !plan.tag.is_empty() {
                    plan.tag.clone()
                } else if !display_name.is_empty() {
                    format!("{display_name}-{}", plan_idx + 1)
                } else {
                    "urltest".to_string()
                };
                let group_tag = make_unique_tag(&group_base, &mut taken);
                let mut ut_members = Vec::new();
                for orig in &plan.member_orig_tags {
                    if let Some(utag) = tag_map.get(orig) {
                        member_group_label.insert(orig.clone(), group_base.clone());
                        ut_members.push(utag.clone());
                    }
                }
                if !ut_members.is_empty() {
                    let mut ut_obj = json!({
                        "type": "urltest",
                        "tag": group_tag,
                        "outbounds": ut_members,
                    });
                    if let Some(m) = ut_obj.as_object_mut() {
                        if let Some(ref url) = xray_ut_url {
                            m.insert("url".into(), json!(url));
                        }
                        if let Some(ref interval) = xray_ut_interval {
                            m.insert("interval".into(), json!(interval));
                        }
                    }
                    nodes.push(ParsedProxyNode {
                        tag: group_tag.clone(),
                        protocol: "urltest".to_string(),
                        server: String::new(),
                        server_port: 0,
                        country: detect_country_code(&group_base),
                        raw_uri: format!("json:urltest|{group_base}"),
                        outbound_json: ut_obj,
                    });
                }
            }
            for item in &planned {
                if !in_balancer_orig.contains(&item.orig_tag)
                    && !detour_deps.contains(&item.orig_tag)
                {
                    continue;
                }
                if let Some(mut ob_val) =
                    convert_xray_outbound_to_singbox(&item.outbound, &item.unique_tag)
                {
                    if let Some(d) = item.detour_orig.as_deref().and_then(|k| tag_map.get(k))
                        && let Some(m) = ob_val.as_object_mut()
                    {
                        m.insert("detour".into(), json!(d));
                    }
                    let otype = ob_val
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let server = ob_val
                        .get("server")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let server_port = ob_val
                        .get("server_port")
                        .and_then(Value::as_u64)
                        .unwrap_or(0) as u16;
                    let group_lbl = member_group_label
                        .get(&item.orig_tag)
                        .map(String::as_str)
                        .unwrap_or(&display_name);
                    let mut cc = detect_country_code(&item.unique_tag);
                    if cc.is_empty() && !group_lbl.is_empty() {
                        cc = detect_country_code(group_lbl);
                    }
                    nodes.push(ParsedProxyNode {
                        tag: item.unique_tag.clone(),
                        protocol: otype,
                        server,
                        server_port,
                        country: cc,
                        raw_uri: format!("json:hidden|{group_lbl}"),
                        outbound_json: ob_val,
                    });
                }
            }
        } else {
            let primary_idx = planned
                .iter()
                .position(|p| p.orig_tag == "proxy")
                .unwrap_or(0);
            if !display_name.is_empty() {
                let old_unique = planned[primary_idx].unique_tag.clone();
                taken.remove(&old_unique);
                let new_unique = make_unique_tag(&display_name, &mut taken);
                let orig = planned[primary_idx].orig_tag.clone();
                planned[primary_idx].unique_tag = new_unique.clone();
                tag_map.insert(orig, new_unique);
            }
            for (idx, item) in planned.iter().enumerate() {
                let is_primary = idx == primary_idx;
                if !is_primary && !detour_deps.contains(&item.orig_tag) {
                    continue;
                }
                if let Some(mut ob_val) =
                    convert_xray_outbound_to_singbox(&item.outbound, &item.unique_tag)
                {
                    if let Some(d) = item.detour_orig.as_deref().and_then(|k| tag_map.get(k))
                        && let Some(m) = ob_val.as_object_mut()
                    {
                        m.insert("detour".into(), json!(d));
                    }
                    let otype = ob_val
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let server = ob_val
                        .get("server")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let server_port = ob_val
                        .get("server_port")
                        .and_then(Value::as_u64)
                        .unwrap_or(0) as u16;
                    let cc = detect_country_code(&item.unique_tag);
                    nodes.push(ParsedProxyNode {
                        tag: item.unique_tag.clone(),
                        protocol: otype,
                        server,
                        server_port,
                        country: cc,
                        raw_uri: if is_primary {
                            "json:standalone".to_string()
                        } else {
                            "json:hidden|detour".to_string()
                        },
                        outbound_json: ob_val,
                    });
                }
            }
        }
    }
    nodes
}

fn normalize_singbox_json_outbounds(items: &[Value]) -> Vec<ParsedProxyNode> {
    let mut urltest_labels: HashMap<String, String> = HashMap::new();
    for item in items {
        if item.get("type").and_then(Value::as_str) == Some("urltest") {
            let lbl = json_str_at(item, &["remark", "tag"]).unwrap_or("");
            if let Some(arr) = item.get("outbounds").and_then(Value::as_array) {
                for m in arr.iter().filter_map(Value::as_str) {
                    urltest_labels.insert(m.to_string(), lbl.to_string());
                }
            }
        }
    }

    let mut nodes = Vec::new();
    for (idx, item) in items.iter().enumerate() {
        let Some(otype) = json_str_at(item, &["type"]).map(|s| s.to_ascii_lowercase()) else {
            continue;
        };
        if matches!(otype.as_str(), "direct" | "block" | "dns" | "selector") {
            continue;
        }
        let raw_tag = json_str_at(item, &["tag"]).unwrap_or("");
        let remark = json_str_at(item, &["remark"]).unwrap_or("");
        let tag = if !raw_tag.is_empty() {
            raw_tag.to_string()
        } else if !remark.is_empty() {
            remark.to_string()
        } else {
            format!("{otype}-{}", idx + 1)
        };
        let mut clean_val = item.clone();
        if let Some(m) = clean_val.as_object_mut() {
            m.remove("remark");
            m.remove("__tachyon_hidden");
            m.remove("__tachyon_allow_group");
            m.insert("tag".into(), json!(tag));
        }
        let is_hidden = item
            .get("__tachyon_hidden")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let group_lbl = urltest_labels.get(&tag).map(String::as_str).unwrap_or("");
        let mut cc = detect_country_code(if remark.is_empty() { &tag } else { remark });
        if cc.is_empty() && !group_lbl.is_empty() {
            cc = detect_country_code(group_lbl);
        }
        if otype == "urltest" {
            let raw_uri = if remark.is_empty() {
                format!("json:urltest|{tag}")
            } else {
                format!("json:urltest|{remark}")
            };
            nodes.push(ParsedProxyNode {
                tag,
                protocol: "urltest".to_string(),
                server: String::new(),
                server_port: 0,
                country: cc,
                raw_uri,
                outbound_json: clean_val,
            });
        } else {
            let server = item
                .get("server")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let mut server_port =
                item.get("server_port").and_then(Value::as_u64).unwrap_or(0) as u16;
            if server_port == 0
                && let Some(arr) = item.get("server_ports").and_then(Value::as_array)
            {
                let specs: Vec<String> = arr
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect();
                server_port = first_port_from_specs(&specs).unwrap_or(0);
            }
            nodes.push(ParsedProxyNode {
                tag,
                protocol: otype,
                server,
                server_port,
                country: cc,
                raw_uri: if is_hidden {
                    format!("json:hidden|{group_lbl}")
                } else {
                    "json:standalone".to_string()
                },
                outbound_json: clean_val,
            });
        }
    }
    nodes
}

/// Parse an Xray JSON or sing-box/tachyon-core JSON subscription payload into `ParsedProxyNode` items.
pub fn parse_json_subscription_payload(decoded: &str) -> Option<Vec<ParsedProxyNode>> {
    let trimmed = decoded.trim_start_matches('\u{feff}').trim();
    if !trimmed.starts_with('{') && !trimmed.starts_with('[') {
        return None;
    }
    let val: Value = serde_json::from_str(trimmed).ok()?;
    let is_xray = |v: &Value| {
        v.get("outbounds")
            .and_then(Value::as_array)
            .is_some_and(|arr| {
                arr.iter()
                    .any(|o| o.get("protocol").and_then(Value::as_str).is_some())
            })
    };
    let nodes = match &val {
        Value::Array(arr) if arr.iter().any(is_xray) => normalize_xray_json_configs(arr),
        Value::Object(_) if is_xray(&val) => {
            normalize_xray_json_configs(std::slice::from_ref(&val))
        }
        Value::Object(m) => {
            let obs = m.get("outbounds").and_then(Value::as_array);
            let eps = m.get("endpoints").and_then(Value::as_array);
            if obs.is_none() && eps.is_none() {
                return None;
            }
            let mut combined = Vec::new();
            if let Some(arr) = obs {
                combined.extend(arr.iter().cloned());
            }
            if let Some(arr) = eps {
                combined.extend(arr.iter().cloned());
            }
            normalize_singbox_json_outbounds(&combined)
        }
        Value::Array(arr) => normalize_singbox_json_outbounds(arr),
        _ => return None,
    };
    if nodes.is_empty() { None } else { Some(nodes) }
}

fn build_filtered_source_nodes(src: &OutboundSource) -> Vec<(String, Value, bool)> {
    let mut nodes: Vec<ParsedProxyNode> = src.cached_nodes.clone();
    for (idx, link) in src.proxy_links.iter().enumerate() {
        if let Some(node) = parse_proxy_uri(link, idx)
            && !nodes.iter().any(|n| n.tag == node.tag)
        {
            nodes.push(node);
        }
    }
    if nodes.is_empty() {
        return Vec::new();
    }

    let mut nodes_by_tag: HashMap<String, &ParsedProxyNode> = HashMap::new();
    for n in &nodes {
        nodes_by_tag.insert(n.tag.clone(), n);
    }

    let mut urltest_member_tags: HashSet<String> = HashSet::new();
    let mut survivor_endpoints: HashSet<(String, String, u16)> = HashSet::new();
    for n in &nodes {
        let is_ut = n.protocol == "urltest"
            || n.outbound_json.get("type").and_then(Value::as_str) == Some("urltest");
        if is_ut {
            if let Some(arr) = n.outbound_json.get("outbounds").and_then(Value::as_array) {
                for m in arr.iter().filter_map(Value::as_str) {
                    urltest_member_tags.insert(m.to_string());
                }
            }
        } else if !n.raw_uri.starts_with("json:hidden") && !n.server.is_empty() {
            survivor_endpoints.insert((
                n.protocol.to_ascii_lowercase(),
                n.server.to_ascii_lowercase(),
                n.server_port,
            ));
        }
    }

    let mut aux_balancer_members: HashSet<String> = HashSet::new();
    let mut covered_group_hidden_members: HashSet<String> = HashSet::new();
    let mut fallback_group_remarks: HashMap<String, String> = HashMap::new();

    for cand in &nodes {
        let is_ut = cand.protocol == "urltest"
            || cand.outbound_json.get("type").and_then(Value::as_str) == Some("urltest");
        if !is_ut {
            continue;
        }
        let group_label = cand
            .raw_uri
            .strip_prefix("json:urltest|")
            .unwrap_or(&cand.tag)
            .trim()
            .to_string();
        let mut has_survivor_member = false;
        let mut group_hidden_tags: Vec<String> = Vec::new();
        let mut candidate_aux_tags: Vec<String> = Vec::new();
        let mut non_aux_members: Vec<String> = Vec::new();

        if let Some(arr) = cand
            .outbound_json
            .get("outbounds")
            .and_then(Value::as_array)
        {
            for m_tag in arr.iter().filter_map(Value::as_str) {
                let Some(m_obj) = nodes_by_tag.get(m_tag) else {
                    continue;
                };
                let m_hidden = m_obj.raw_uri.starts_with("json:hidden");
                let ep_key = (
                    m_obj.protocol.to_ascii_lowercase(),
                    m_obj.server.to_ascii_lowercase(),
                    m_obj.server_port,
                );
                let is_dup_ep = !m_obj.server.is_empty() && survivor_endpoints.contains(&ep_key);
                if m_hidden && is_dup_ep {
                    has_survivor_member = true;
                }
                let m_tag_lc = m_tag.to_ascii_lowercase();
                let is_aux = m_hidden
                    && (is_bal_internal_tag(&m_tag_lc)
                        || is_reserve_like_tag(&m_tag_lc)
                        || is_dup_ep);
                if m_hidden {
                    group_hidden_tags.push(m_tag.to_string());
                }
                if is_aux {
                    candidate_aux_tags.push(m_tag.to_string());
                } else {
                    non_aux_members.push(m_tag.to_string());
                }
            }
        }
        if has_survivor_member || !non_aux_members.is_empty() {
            aux_balancer_members.extend(candidate_aux_tags);
        }
        if has_survivor_member {
            covered_group_hidden_members.extend(group_hidden_tags);
        } else if !group_label.is_empty() && non_aux_members.len() == 1 {
            fallback_group_remarks.insert(non_aux_members[0].clone(), group_label);
        }
    }

    let drop_urltest_members = !src.include_urltest_groups && !survivor_endpoints.is_empty();
    let mut detour_targets: HashSet<String> = HashSet::new();
    if src.hide_detour_outbounds {
        for n in &nodes {
            if let Some(d) = n.outbound_json.get("detour").and_then(Value::as_str)
                && !d.is_empty()
            {
                detour_targets.insert(d.to_string());
            }
        }
    }

    let mut used_tags: HashSet<String> = HashSet::new();
    let mut renamed_tags: HashMap<String, String> = HashMap::new();
    let mut staged: Vec<(String, Value, bool, bool)> = Vec::new();

    for n in &nodes {
        let is_ut = n.protocol == "urltest"
            || n.outbound_json.get("type").and_then(Value::as_str) == Some("urltest");
        if is_ut {
            if !src.include_urltest_groups {
                continue;
            }
            if !src.filter_deny_regex.is_empty()
                && n.tag
                    .to_ascii_lowercase()
                    .contains(&src.filter_deny_regex.to_ascii_lowercase())
            {
                continue;
            }
            let base = if src.prefix_nodes && !src.node_prefix.trim().is_empty() {
                format!("{} {}", src.node_prefix.trim(), n.tag)
            } else {
                n.tag.clone()
            };
            let final_tag = make_unique_tag(&base, &mut used_tags);
            let mut val = n.outbound_json.clone();
            if let Some(m) = val.as_object_mut() {
                m.remove("remark");
                m.remove("__tachyon_hidden");
                m.remove("__tachyon_allow_group");
                m.insert("tag".into(), json!(final_tag));
                if !src.urltest_idle_timeout.trim().is_empty() {
                    m.insert(
                        "idle_timeout".into(),
                        json!(src.urltest_idle_timeout.trim()),
                    );
                }
            }
            staged.push((final_tag, val, true, true));
            continue;
        }

        if !src.include_urltest_groups && urltest_member_tags.contains(&n.tag) {
            if aux_balancer_members.contains(&n.tag)
                || covered_group_hidden_members.contains(&n.tag)
            {
                continue;
            }
            if drop_urltest_members
                && n.raw_uri == "json:hidden"
                && !fallback_group_remarks.contains_key(&n.tag)
            {
                continue;
            }
        }

        let mut base_name = n.tag.clone();
        if !src.include_urltest_groups
            && let Some(group_lbl) = fallback_group_remarks.get(&n.tag)
            && is_generic_proxy_tag(&n.tag.to_ascii_lowercase())
        {
            base_name = group_lbl.clone();
        }
        let eff_cc = if n.country.is_empty() {
            detect_country_code(&base_name)
        } else {
            n.country.clone()
        };
        if !passes_source_filters(src, &base_name, &eff_cc) {
            continue;
        }
        if src.prefix_nodes && !src.node_prefix.trim().is_empty() {
            base_name = format!("{} {}", src.node_prefix.trim(), base_name);
        }
        let final_tag = make_unique_tag(&base_name, &mut used_tags);
        renamed_tags.insert(n.tag.clone(), final_tag.clone());

        let mut val = n.outbound_json.clone();
        if let Some(m) = val.as_object_mut() {
            m.remove("remark");
            m.remove("__tachyon_hidden");
            m.remove("__tachyon_allow_group");
            m.insert("tag".into(), json!(final_tag));
        }
        apply_outbound_common_opts(src, &mut val);

        let visible_in_selector = !(aux_balancer_members.contains(&n.tag)
            || (src.include_urltest_groups && n.raw_uri.starts_with("json:hidden"))
            || (src.hide_urltest_group_outbounds && urltest_member_tags.contains(&n.tag))
            || (src.hide_detour_outbounds && detour_targets.contains(&n.tag)));
        staged.push((final_tag, val, visible_in_selector, false));
    }

    let surviving_leaf_tags: HashSet<String> = staged
        .iter()
        .filter(|(_, _, _, is_ut)| !*is_ut)
        .map(|(t, _, _, _)| t.clone())
        .collect();

    let mut out = Vec::with_capacity(staged.len());
    for (tag, mut val, visible, is_ut) in staged {
        if is_ut {
            let mut kept_members = Vec::new();
            if let Some(arr) = val.get("outbounds").and_then(Value::as_array) {
                for m in arr.iter().filter_map(Value::as_str) {
                    let mapped = renamed_tags.get(m).map(String::as_str).unwrap_or(m);
                    if surviving_leaf_tags.contains(mapped)
                        && !kept_members
                            .iter()
                            .any(|existing: &String| existing == mapped)
                    {
                        kept_members.push(mapped.to_string());
                    }
                }
            }
            if kept_members.is_empty() {
                continue;
            }
            if let Some(m) = val.as_object_mut() {
                m.insert("outbounds".into(), json!(kept_members));
            }
        } else if let Some(d_old) = val.get("detour").and_then(Value::as_str).map(String::from)
            && let Some(d_new) = renamed_tags.get(&d_old)
            && let Some(m) = val.as_object_mut()
        {
            m.insert("detour".into(), json!(d_new));
        }
        out.push((tag, val, visible));
    }
    out
}

fn apply_outbound_common_opts(src: &OutboundSource, v: &mut Value) {
    let Some(obj) = v.as_object_mut() else {
        return;
    };
    let otype_early = obj.get("type").and_then(Value::as_str).unwrap_or("");
    if otype_early == "urltest" {
        return;
    }
    if otype_early == "tailscale" {
        if src.outbound_detour_enabled
            && !src.outbound_detour_section.trim().is_empty()
            && !obj.contains_key("detour")
        {
            obj.insert("detour".into(), json!(src.outbound_detour_section.trim()));
        } else if !src.bind_interface.trim().is_empty()
            && !obj.contains_key("bind_interface")
            && !obj.contains_key("detour")
        {
            obj.insert("bind_interface".into(), json!(src.bind_interface.trim()));
        }
        return;
    }
    if src.tcp_fast_open {
        obj.insert("tcp_fast_open".into(), json!(true));
    }
    if !src.bind_interface.trim().is_empty() && !obj.contains_key("bind_interface") {
        obj.insert("bind_interface".into(), json!(src.bind_interface.trim()));
    }
    if src.outbound_detour_enabled
        && !src.outbound_detour_section.trim().is_empty()
        && !obj.contains_key("detour")
    {
        obj.insert("detour".into(), json!(src.outbound_detour_section.trim()));
    }
    if !src.tls_fingerprint.trim().is_empty()
        && let Some(tls_obj) = obj.get_mut("tls").and_then(Value::as_object_mut)
        && tls_obj.get("enabled").and_then(Value::as_bool) == Some(true)
    {
        tls_obj.insert(
            "utls".into(),
            json!({
                "enabled": true,
                "fingerprint": src.tls_fingerprint.trim()
            }),
        );
    }
    if src.multiplex_enabled && !obj.contains_key("multiplex") {
        let otype = obj.get("type").and_then(Value::as_str).unwrap_or("");
        if matches!(
            otype,
            "vless" | "vmess" | "trojan" | "shadowsocks" | "anytls"
        ) {
            let proto = match src.multiplex_protocol.trim() {
                "smux" | "yamux" | "h2mux" => src.multiplex_protocol.trim(),
                _ => "h2mux",
            };
            obj.insert(
                "multiplex".into(),
                json!({
                    "enabled": true,
                    "protocol": proto,
                    "max_connections": src.multiplex_max_connections.max(4),
                    "padding": src.multiplex_padding
                }),
            );
        }
    }
}

fn parse_amnezia_conf_outbound(src_id: &str, idx: usize, conf: &str) -> Option<(String, Value)> {
    let mut priv_key = String::new();
    let mut pub_key = String::new();
    let mut psk = String::new();
    let mut address = "10.8.0.2/32".to_string();
    let mut endpoint = String::new();
    let mut mtu: u16 = 0;
    let mut jc: i64 = 0;
    let mut jmin: i64 = 0;
    let mut jmax: i64 = 0;
    let mut s1: i64 = 0;
    let mut s2: i64 = 0;
    let mut h1: i64 = 0;
    let mut h2: i64 = 0;
    let mut h3: i64 = 0;
    let mut h4: i64 = 0;

    for line in conf.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('[') {
            continue;
        }
        let Some((k, v)) = trimmed.split_once('=') else {
            continue;
        };
        let key = k.trim().to_ascii_lowercase();
        let val = v.trim();
        match key.as_str() {
            "privatekey" => priv_key = val.to_string(),
            "publickey" => pub_key = val.to_string(),
            "presharedkey" => psk = val.to_string(),
            "address" => {
                if let Some(first) = val.split(',').next() {
                    address = first.trim().to_string();
                }
            }
            "endpoint" => endpoint = val.to_string(),
            "mtu" => mtu = val.parse().unwrap_or(0),
            "jc" => jc = val.parse().unwrap_or(0),
            "jmin" => jmin = val.parse().unwrap_or(0),
            "jmax" => jmax = val.parse().unwrap_or(0),
            "s1" => s1 = val.parse().unwrap_or(0),
            "s2" => s2 = val.parse().unwrap_or(0),
            "h1" => h1 = val.parse().unwrap_or(0),
            "h2" => h2 = val.parse().unwrap_or(0),
            "h3" => h3 = val.parse().unwrap_or(0),
            "h4" => h4 = val.parse().unwrap_or(0),
            _ => {}
        }
    }
    if priv_key.is_empty() || pub_key.is_empty() || endpoint.is_empty() {
        return None;
    }
    let (host, port) = split_host_port(&endpoint, 51820)?;
    let tag = if idx == 0 {
        format!("awgconf-{src_id}")
    } else {
        format!("awgconf-{src_id}-{idx}")
    };
    let mut obj = Map::new();
    obj.insert("type".into(), json!("wireguard"));
    obj.insert("tag".into(), json!(tag));
    obj.insert("server".into(), json!(host));
    obj.insert("server_port".into(), json!(port));
    obj.insert("private_key".into(), json!(priv_key));
    obj.insert("peer_public_key".into(), json!(pub_key));
    obj.insert("local_address".into(), json!([address]));
    if !psk.is_empty() {
        obj.insert("pre_shared_key".into(), json!(psk));
    }
    if mtu > 0 {
        obj.insert("mtu".into(), json!(mtu));
    }
    if jc > 0 {
        obj.insert("jc".into(), json!(jc));
        obj.insert("jmin".into(), json!(jmin));
        obj.insert("jmax".into(), json!(jmax));
        obj.insert("s1".into(), json!(s1));
        obj.insert("s2".into(), json!(s2));
        obj.insert("h1".into(), json!(h1));
        obj.insert("h2".into(), json!(h2));
        obj.insert("h3".into(), json!(h3));
        obj.insert("h4".into(), json!(h4));
    }
    Some((tag, Value::Object(obj)))
}

fn passes_source_filters(src: &OutboundSource, tag: &str, country: &str) -> bool {
    if !src.include_countries.is_empty()
        && !country.is_empty()
        && !src
            .include_countries
            .iter()
            .any(|c| c.eq_ignore_ascii_case(country))
    {
        return false;
    }
    if !src.exclude_countries.is_empty()
        && !country.is_empty()
        && src
            .exclude_countries
            .iter()
            .any(|c| c.eq_ignore_ascii_case(country))
    {
        return false;
    }
    if !src.filter_allow_regex.is_empty()
        && !tag
            .to_ascii_lowercase()
            .contains(&src.filter_allow_regex.to_ascii_lowercase())
    {
        return false;
    }
    if !src.filter_deny_regex.is_empty()
        && tag
            .to_ascii_lowercase()
            .contains(&src.filter_deny_regex.to_ascii_lowercase())
    {
        return false;
    }
    true
}

const DISCORD_VOICE_PORT_RANGES: &[&str] = &[
    "443:443",
    "5000:5020",
    "3478:3478",
    "19294:19344",
    "50000:65535",
];
const DISCORD_MEDIA_PORT_RANGES: &[&str] = &[
    "443:443",
    "1080:1080",
    "2053:2053",
    "2083:2083",
    "2087:2087",
    "2096:2096",
    "8443:8443",
];
const DEFAULT_DISCORD_VOICE_SUBNETS_V4: &[&str] =
    &["104.16.0.0/12", "162.158.0.0/15", "172.64.0.0/13"];
const DISCORD_VOICE_SUBNET_V6: &str = "2606:4700::/32";
const DISCORD_DEDICATED_SUBNETS: &[&str] = &["162.159.128.0/20"];
const DEFAULT_TELEGRAM_SUBNETS: &[&str] = &[
    "5.28.192.0/18",
    "91.105.192.0/23",
    "91.108.4.0/22",
    "91.108.8.0/21",
    "91.108.16.0/21",
    "91.108.56.0/22",
    "95.161.64.0/20",
    "149.154.160.0/20",
    "185.76.151.0/24",
    "194.221.0.0/16",
];

fn strip_node_tag_prefix<'a>(tag: &'a str, known_prefixes: &[String]) -> &'a str {
    let mut t = tag.trim();
    if let Some(rest) = t.strip_prefix('[')
        && let Some((_, tail)) = rest.split_once(']')
    {
        t = tail.trim();
    }
    for prefix in known_prefixes {
        let p = prefix.trim();
        if !p.is_empty()
            && let Some(after) = t.strip_prefix(p)
            && after.starts_with(char::is_whitespace)
        {
            t = after.trim();
            break;
        }
    }
    t
}

fn server_tag_matches(tag: &str, filter: &str, known_prefixes: &[String]) -> bool {
    let tag_trim = tag.trim();
    let flt_trim = filter.trim();
    if flt_trim.is_empty() {
        return false;
    }
    if tag_trim == flt_trim {
        return true;
    }
    strip_node_tag_prefix(tag_trim, known_prefixes)
        == strip_node_tag_prefix(flt_trim, known_prefixes)
}

fn parse_valid_cidr_token(raw: &str) -> Option<String> {
    let tok = raw.trim();
    if tok.is_empty() {
        return None;
    }
    if let Some((ip_part, prefix_part)) = tok.split_once('/') {
        let p: u8 = prefix_part.trim().parse().ok()?;
        let ip_clean = ip_part.trim();
        if ip_clean.parse::<std::net::Ipv4Addr>().is_ok() && p <= 32 {
            return Some(format!("{ip_clean}/{p}"));
        }
        if ip_clean.parse::<std::net::Ipv6Addr>().is_ok() && p <= 128 {
            return Some(format!("{ip_clean}/{p}"));
        }
        return None;
    }
    if let Ok(v4) = tok.parse::<std::net::Ipv4Addr>() {
        return Some(format!("{v4}/32"));
    }
    if let Ok(v6) = tok.parse::<std::net::Ipv6Addr>() {
        return Some(format!("{v6}/128"));
    }
    None
}

fn resolve_device_targets_with_tables(
    items: &[String],
    arp_content: &str,
    leases_content: &str,
) -> Vec<String> {
    let has_mac = items.iter().any(|s| crate::store::is_mac_address(s));
    let mut mac_to_ips: HashMap<String, Vec<String>> = HashMap::new();
    if has_mac {
        for line in arp_content.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() >= 4
                && cols[2] != "0x0"
                && crate::store::is_mac_address(cols[3])
                && cols[3] != "00:00:00:00:00:00"
                && let Ok(v4) = cols[0].parse::<std::net::Ipv4Addr>()
            {
                let mac = cols[3].to_ascii_lowercase();
                let cidr = format!("{v4}/32");
                let entry = mac_to_ips.entry(mac).or_default();
                if !entry.contains(&cidr) {
                    entry.push(cidr);
                }
            }
        }
        for line in leases_content.lines() {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() >= 3
                && crate::store::is_mac_address(cols[1])
                && let Ok(v4) = cols[2].parse::<std::net::Ipv4Addr>()
            {
                let mac = cols[1].to_ascii_lowercase();
                let cidr = format!("{v4}/32");
                let entry = mac_to_ips.entry(mac).or_default();
                if !entry.contains(&cidr) {
                    entry.push(cidr);
                }
            }
        }
    }

    let mut out = Vec::new();
    for raw in items {
        let tok = raw.trim();
        if crate::store::is_mac_address(tok) {
            if let Some(ips) = mac_to_ips.get(&tok.to_ascii_lowercase()) {
                for cidr in ips {
                    if !out.contains(cidr) {
                        out.push(cidr.clone());
                    }
                }
            }
        } else if let Some(cidr) = parse_valid_cidr_token(tok)
            && !out.contains(&cidr)
        {
            out.push(cidr);
        }
    }
    out
}

fn resolve_device_targets_to_cidrs(items: &[String]) -> Vec<String> {
    let has_mac = items.iter().any(|s| crate::store::is_mac_address(s));
    if !has_mac {
        return resolve_device_targets_with_tables(items, "", "");
    }
    let arp = std::fs::read_to_string("/proc/net/arp").unwrap_or_default();
    let leases = std::fs::read_to_string("/tmp/dhcp.leases").unwrap_or_default();
    resolve_device_targets_with_tables(items, &arp, &leases)
}

/// Compile the complete `/etc/tachyon-core/config.json` document from `RouterStoreData`.
pub fn parse_system_ntp_domains(content: &str) -> Vec<String> {
    let mut domains = Vec::new();
    let mut in_timeserver = false;
    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let Some(kw) = parts.next() else {
            continue;
        };
        if kw == "config" {
            let sec_type = parts
                .next()
                .map(|s| s.trim_matches(['\'', '"']))
                .unwrap_or("");
            in_timeserver = sec_type == "timeserver";
            continue;
        }
        if !in_timeserver || (kw != "list" && kw != "option") {
            continue;
        }
        let Some(opt_name) = parts.next().map(|s| s.trim_matches(['\'', '"'])) else {
            continue;
        };
        if opt_name != "server" {
            continue;
        }
        let Some(raw_val) = parts.next() else {
            continue;
        };
        let host = raw_val
            .trim_matches(['\'', '"'])
            .split(':')
            .next()
            .unwrap_or("")
            .trim()
            .trim_end_matches('.');
        if host.is_empty() || !host.contains('.') || host.parse::<std::net::IpAddr>().is_ok() {
            continue;
        }
        let lower = host.to_ascii_lowercase();
        if !domains.iter().any(|existing| existing == &lower) {
            domains.push(lower);
        }
    }
    domains
}

fn collect_system_ntp_domains() -> Vec<String> {
    std::fs::read_to_string("/etc/config/system")
        .map(|content| parse_system_ntp_domains(&content))
        .unwrap_or_default()
}

fn allocate_loopback_port(preferred: u16, used_ports: &mut HashSet<u16>) -> u16 {
    for p in (preferred..=u16::MAX).chain(1024..preferred) {
        if used_ports.insert(p) {
            return p;
        }
    }
    preferred
}

pub fn compile_core_config(store: &RouterStoreData) -> anyhow::Result<Value> {
    let mut inbounds: Vec<Value> = Vec::new();
    let mut outbounds: Vec<Value> = Vec::new();
    let mut rules: Vec<Value> = Vec::new();
    let mut rule_sets: Vec<Value> = Vec::new();
    let mut seen_rule_sets: HashMap<String, bool> = HashMap::new();
    let mut seen_outbound_tags: HashMap<String, bool> = HashMap::new();

    // 1. Primary router interception inbound (`tproxy` :1602 or `tun` tun0)
    match store.settings.proxy_mode.as_str() {
        "tun" => {
            inbounds.push(json!({
                "type": "tun",
                "tag": "tun-in",
                "interface_name": store.settings.tun_interface,
                "address": ["172.19.0.1/30"],
                "mtu": store.settings.tun_mtu,
                "auto_route": true,
                "strict_route": true,
                "stack": store.settings.tun_stack
            }));
        }
        "socks" => {
            inbounds.push(json!({
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "0.0.0.0",
                "listen_port": 1080
            }));
        }
        _ => {
            inbounds.push(json!({
                "type": "tproxy",
                "tag": "tproxy-in",
                "listen": "::",
                "listen_port": 1602,
                "tcp_fast_open": true,
                "udp_fragment": true
            }));
        }
    }

    // Dedicated DNS inbound on `127.0.0.42:53`
    inbounds.push(json!({
        "type": "direct",
        "tag": "dns-in",
        "listen": "127.0.0.42",
        "listen_port": 53
    }));

    // Optional Direct Bypass SOCKS5/HTTP port (`settings.direct_bypass_enabled`)
    if store.settings.direct_bypass_enabled && store.settings.direct_bypass_port > 0 {
        inbounds.push(json!({
            "type": "mixed",
            "tag": "direct-bypass-in",
            "listen": "0.0.0.0",
            "listen_port": store.settings.direct_bypass_port
        }));
        rules.push(json!({
            "inbound": ["direct-bypass-in"],
            "outbound": "direct"
        }));
    }

    // Router-hosted Inbound Servers & Endpoints
    let is_tachyon_core = !store
        .settings
        .engine_variant
        .to_ascii_lowercase()
        .contains("sing-box")
        && !store
            .settings
            .core_bin_path
            .to_ascii_lowercase()
            .contains("sing-box");
    let mut ts_dns_metas: Vec<TailscaleEndpointDnsMeta> = Vec::new();
    let mut endpoints: Vec<Value> = Vec::new();
    for srv in store.servers.iter().filter(|s| s.enabled) {
        if matches!(srv.protocol.as_str(), "awg" | "wireguard" | "tailscale") {
            if let Some(ep) = build_endpoint_server(srv) {
                if srv.protocol == "tailscale"
                    && let Some(ep_tag) = ep.get("tag").and_then(Value::as_str)
                {
                    seen_outbound_tags.insert(ep_tag.to_string(), true);
                    ts_dns_metas.push(TailscaleEndpointDnsMeta {
                        ep_tag: ep_tag.to_string(),
                        is_server: true,
                        accept_dns: srv.tailscale_accept_dns,
                        accept_default_resolvers: srv.tailscale_accept_default_resolvers,
                        advertise_exit_node: srv.tailscale_advertise_exit_node,
                    });
                }
                endpoints.push(ep);
            }
        } else {
            for inb in build_inbound_servers(srv) {
                inbounds.push(inb);
            }
        }
    }

    // Track all configured inbound/endpoint/section/daemon ports before emitting internal loopback inbounds
    let mut used_ports: HashSet<u16> = HashSet::new();
    for inb in &inbounds {
        if let Some(p) = inb.get("listen_port").and_then(Value::as_u64)
            && let Ok(port) = u16::try_from(p)
            && port > 0
        {
            used_ports.insert(port);
        }
    }
    for ep in &endpoints {
        if let Some(p) = ep.get("listen_port").and_then(Value::as_u64)
            && let Ok(port) = u16::try_from(p)
            && port > 0
        {
            used_ports.insert(port);
        }
    }
    for sec in store.sections.iter().filter(|s| s.enabled) {
        if sec.action != "dns"
            && sec.connection_type != "dns"
            && sec.mixed_proxy_enabled
            && sec.mixed_proxy_port > 0
        {
            used_ports.insert(sec.mixed_proxy_port);
        }
    }
    if store.settings.listen_port > 0 {
        used_ports.insert(store.settings.listen_port);
    }
    if let Some(clash_p) = store
        .settings
        .clash_api_addr
        .rsplit_once(':')
        .and_then(|(_, p)| p.trim().parse::<u16>().ok())
        .filter(|&p| p > 0)
    {
        used_ports.insert(clash_p);
    }

    // Internal loopback mixed inbound for daemon services (e.g. Telegram bot auto-proxy)
    let service_mixed_port = allocate_loopback_port(4534, &mut used_ports);
    inbounds.push(json!({
        "type": "mixed",
        "tag": "service-mixed-in",
        "listen": "127.0.0.1",
        "listen_port": service_mixed_port
    }));

    // 2. Collect all outbounds from `outbound_sources`
    let mut source_tag_map: HashMap<String, Vec<String>> = HashMap::new();
    for src in &store.outbound_sources {
        let pairs = build_source_outbounds(src);
        let mut tags = Vec::new();
        for (tag, obj, visible_in_selector) in pairs {
            if obj.get("type").and_then(Value::as_str) == Some("tailscale") {
                let dns_overrides = if src.source_type == "tailscale" {
                    Some((
                        src.tailscale_accept_dns,
                        src.tailscale_accept_default_resolvers,
                    ))
                } else {
                    None
                };
                let (ep_obj, meta) =
                    normalize_imported_tailscale_endpoint(obj, &tag, dns_overrides);
                let ep_tag = meta.ep_tag.clone();
                if visible_in_selector {
                    tags.push(ep_tag.clone());
                }
                if let std::collections::hash_map::Entry::Vacant(e) =
                    seen_outbound_tags.entry(ep_tag)
                {
                    e.insert(true);
                    ts_dns_metas.push(meta);
                    endpoints.push(ep_obj);
                }
                continue;
            }
            if visible_in_selector {
                tags.push(tag.clone());
            }
            if let std::collections::hash_map::Entry::Vacant(e) = seen_outbound_tags.entry(tag) {
                e.insert(true);
                outbounds.push(obj);
            }
        }
        source_tag_map.insert(src.id.clone(), tags);
    }

    // Always ensure a default `adaptive-desync-default` outbound exists when any section uses `desync`
    if store
        .sections
        .iter()
        .any(|s| s.enabled && s.connection_type == "desync")
        && !seen_outbound_tags.contains_key("adaptive-desync-default")
    {
        seen_outbound_tags.insert("adaptive-desync-default".to_string(), true);
        outbounds.push(json!({
            "type": "desync",
            "tag": "adaptive-desync-default",
            "preset": "auto",
            "fooling": "autottl",
            "split_pos": "sni",
            "fake_sni": "ozon.ru"
        }));
    }

    // 3. Build section-scoped selectors / balancers, outbound groups, and route rules
    let cond_map: HashMap<&str, &TrafficCondition> = store
        .conditions
        .iter()
        .map(|c| (c.id.as_str(), c))
        .collect();
    let bal_map: HashMap<&str, &BalancerConfig> =
        store.balancers.iter().map(|b| (b.id.as_str(), b)).collect();
    let sec_map: HashMap<&str, &RoutingSection> =
        store.sections.iter().map(|s| (s.id.as_str(), s)).collect();
    let group_tag_map = build_outbound_group_map(
        &store.outbound_groups,
        &store.outbound_sources,
        &source_tag_map,
    );

    // Protocol sniff + DNS hijack rule first
    rules.push(json!({
        "action": "sniff"
    }));
    rules.push(json!({
        "inbound": ["dns-in"],
        "action": "hijack-dns"
    }));

    if !store.settings.excluded_ips.is_empty() {
        let global_excl = resolve_device_targets_to_cidrs(&store.settings.excluded_ips);
        if !global_excl.is_empty() {
            rules.push(json!({
                "source_ip_cidr": global_excl,
                "outbound": "direct"
            }));
        }
    }

    // Optional dedicated loopback inbound + top-priority route rule for Telegram bot section override
    let tg_sec_ref = store.telegram.bot_proxy_section.trim();
    if !tg_sec_ref.is_empty() {
        let tg_out = if tg_sec_ref.eq_ignore_ascii_case("direct") {
            Some("direct".to_string())
        } else if let Some(sec) = store.sections.iter().find(|s| {
            s.enabled
                && s.action != "dns"
                && s.connection_type != "dns"
                && (s.id == tg_sec_ref || s.label.eq_ignore_ascii_case(tg_sec_ref))
        }) {
            let mut visited_secs = Vec::new();
            Some(resolve_section_outbound(
                sec,
                &source_tag_map,
                &group_tag_map,
                &sec_map,
                &bal_map,
                &mut outbounds,
                &mut endpoints,
                &mut ts_dns_metas,
                &mut seen_outbound_tags,
                &mut visited_secs,
            ))
        } else {
            None
        };
        if let Some(tg_out) = tg_out {
            let tg_bot_port = allocate_loopback_port(4535, &mut used_ports);
            inbounds.push(json!({
                "type": "mixed",
                "tag": "tg-bot-in",
                "listen": "127.0.0.1",
                "listen_port": tg_bot_port
            }));
            rules.push(json!({
                "inbound": ["tg-bot-in"],
                "outbound": tg_out
            }));
        }
    }

    // Parental control (7 categories, SafeSearch, pause/quota, DoH block) & Schedule rules
    let now_unix = unix_now_secs();
    let mut safe_search_ips: Vec<String> = Vec::new();
    for prof in store.profiles.iter().filter(|p| p.enabled) {
        let dev_ips = resolve_device_targets_to_cidrs(&prof.device_ips);
        if dev_ips.is_empty() {
            continue;
        }
        if prof.safe_search {
            for ip in &dev_ips {
                if !safe_search_ips.contains(ip) {
                    safe_search_ips.push(ip.clone());
                }
            }
        }
        let quota_exhausted =
            prof.daily_quota_minutes > 0 && prof.used_minutes_today >= prof.daily_quota_minutes;
        if prof.paused_until_unix > now_unix || quota_exhausted {
            rules.push(json!({
                "source_ip_cidr": dev_ips,
                "outbound": "block"
            }));
            continue;
        }
        if prof.block_doh {
            rules.push(json!({
                "source_ip_cidr": dev_ips,
                "ip_cidr": ["1.1.1.1/32", "1.0.0.1/32", "8.8.8.8/32", "8.8.4.4/32", "9.9.9.9/32"],
                "port": [443, 853],
                "outbound": "block"
            }));
        }
        let mut blocked_doms = prof.blocked_domains.clone();
        for cat in &prof.blocked_categories {
            for dom in parental_category_domains(cat) {
                if !blocked_doms.iter().any(|d| d == dom) {
                    blocked_doms.push((*dom).to_string());
                }
            }
        }
        if !blocked_doms.is_empty() {
            rules.push(json!({
                "source_ip_cidr": dev_ips,
                "domain_suffix": blocked_doms,
                "outbound": "block"
            }));
        }
    }

    for sched in store.schedules.iter().filter(|s| s.enabled) {
        if sched.start_time.trim().is_empty() || sched.end_time.trim().is_empty() {
            continue;
        }
        let tw = format_schedule_time_window(&sched.days, &sched.start_time, &sched.end_time);
        if tw.is_empty() || tw == "-" {
            continue;
        }
        let mut raw_device_targets: Vec<String> = sched.device_ips.clone();
        for pref in &sched.profile_refs {
            if let Some(p) = store.profiles.iter().find(|p| &p.id == pref) {
                for target in &p.device_ips {
                    if !raw_device_targets.contains(target) {
                        raw_device_targets.push(target.clone());
                    }
                }
            }
        }
        let has_device_targets = raw_device_targets.iter().any(|s| !s.trim().is_empty());
        let ips = resolve_device_targets_to_cidrs(&raw_device_targets);
        if has_device_targets && ips.is_empty() {
            continue;
        }
        let mut sched_doms = sched.blocked_domains.clone();
        for cat in &sched.blocked_categories {
            for dom in parental_category_domains(cat) {
                if !sched_doms.iter().any(|d| d == dom) {
                    sched_doms.push((*dom).to_string());
                }
            }
        }
        if ips.is_empty() && sched_doms.is_empty() {
            continue;
        }
        let mut r = Map::new();
        r.insert("time_window".into(), json!(tw));
        if !ips.is_empty() {
            r.insert("source_ip_cidr".into(), json!(ips));
        }
        if !sched_doms.is_empty() {
            r.insert("domain_suffix".into(), json!(sched_doms));
        }
        r.insert(
            "outbound".into(),
            json!(if sched.action == "direct" {
                "direct"
            } else {
                "block"
            }),
        );
        rules.push(Value::Object(r));
    }

    let mut base_policy_emitted = false;
    let emit_base_policy = |rules: &mut Vec<Value>, emitted: &mut bool| {
        if *emitted {
            return;
        }
        *emitted = true;
        if store.settings.isolate_p2p {
            rules.push(json!({
                "protocol": ["bittorrent"],
                "outbound": "direct"
            }));
        }
        if store.settings.disable_quic {
            rules.push(json!({
                "network": "udp",
                "port": [443],
                "outbound": "block"
            }));
        }
    };

    let ts_route_insert_idx = rules.len();
    for sec in store.sections.iter().filter(|s| s.enabled) {
        if sec.action == "dns" || sec.connection_type == "dns" {
            continue;
        }
        let mut visited_secs = Vec::new();
        let target_outbound_tag = resolve_section_outbound(
            sec,
            &source_tag_map,
            &group_tag_map,
            &sec_map,
            &bal_map,
            &mut outbounds,
            &mut endpoints,
            &mut ts_dns_metas,
            &mut seen_outbound_tags,
            &mut visited_secs,
        );

        if target_outbound_tag != "direct" && target_outbound_tag != "block" {
            emit_base_policy(&mut rules, &mut base_policy_emitted);
        }

        // Optional local Mixed Proxy port exposing this section
        if sec.mixed_proxy_enabled && sec.mixed_proxy_port > 0 {
            let mixed_in_tag = format!("mixed-sec-{}", sec.id);
            let mut mixed_in = json!({
                "type": "mixed",
                "tag": mixed_in_tag,
                "listen": "0.0.0.0",
                "listen_port": sec.mixed_proxy_port,
            });
            if sec.mixed_proxy_auth_enabled && !sec.mixed_proxy_username.is_empty() {
                mixed_in["users"] = json!([{
                    "username": sec.mixed_proxy_username,
                    "password": sec.mixed_proxy_password
                }]);
            }
            inbounds.push(mixed_in);
            rules.push(json!({
                "inbound": [mixed_in_tag],
                "outbound": target_outbound_tag
            }));
        }

        // Capture traffic arriving on selected local Inbound Servers (`source_inbounds`)
        if !sec.source_inbounds.is_empty() {
            let in_tags: Vec<String> = sec
                .source_inbounds
                .iter()
                .map(|id| {
                    if id.starts_with("srv-") {
                        id.clone()
                    } else {
                        format!("srv-{id}")
                    }
                })
                .collect();
            rules.push(json!({
                "inbound": in_tags,
                "outbound": target_outbound_tag
            }));
        }

        // Section-level Exclusions (excluded LAN devices, domains, subnets) -> bypass to `direct`
        if !sec.excluded_ips.is_empty() {
            let mut cidrs = resolve_device_targets_to_cidrs(&sec.excluded_ips);
            if !store.settings.enable_ipv6 {
                cidrs.retain(|s| !s.contains(':'));
            }
            if !cidrs.is_empty() {
                rules.push(json!({
                    "source_ip_cidr": cidrs,
                    "outbound": "direct"
                }));
            }
        }
        if !sec.exclude_domains.is_empty() {
            rules.push(json!({
                "domain_suffix": sec.exclude_domains,
                "outbound": "direct"
            }));
        }
        if !sec.exclude_subnets.is_empty() {
            rules.push(json!({
                "ip_cidr": sec.exclude_subnets,
                "outbound": "direct"
            }));
        }
        if !sec.exclude_ports.is_empty() {
            let mut pr = Map::new();
            insert_port_matchers(&mut pr, &sec.exclude_ports, "port", "port_range");
            if !pr.is_empty() {
                pr.insert("outbound".into(), json!("direct"));
                rules.push(Value::Object(pr));
            }
        }

        // Pinned Server-to-Domain rules (`ServerName=domain1.com, domain2.com`)
        for pin in &sec.server_domain_rules {
            if let Some((srv_tag, doms_str)) = pin.split_once('=') {
                let st = srv_tag.trim();
                let doms: Vec<String> = doms_str
                    .split([',', ' '])
                    .map(|d| d.trim().to_string())
                    .filter(|d| !d.is_empty())
                    .collect();
                if !st.is_empty() && !doms.is_empty() {
                    rules.push(json!({
                        "domain_suffix": doms,
                        "outbound": st
                    }));
                }
            }
        }

        if !sec.fully_routed_ips.is_empty() {
            let mut cidrs = resolve_device_targets_to_cidrs(&sec.fully_routed_ips);
            if !store.settings.enable_ipv6 {
                cidrs.retain(|s| !s.contains(':'));
            }
            if !cidrs.is_empty() {
                rules.push(json!({
                    "source_ip_cidr": cidrs,
                    "outbound": target_outbound_tag
                }));
            }
        }

        let pre_resolve_ip = sec.connection_type == "desync" || sec.resolve_real_ip_for_routing;

        let mut section_matched_any = false;
        for cref in &sec.condition_refs {
            let Some(cond) = cond_map.get(cref.as_str()).copied() else {
                continue;
            };
            if !cond.enabled {
                continue;
            }
            let cond_rules = build_condition_rules(
                cond,
                &cond_map,
                &target_outbound_tag,
                &store.settings.rulesets_dir,
                &store.settings.github_mirror,
                &mut rule_sets,
                &mut seen_rule_sets,
                store.settings.enable_ipv6,
                pre_resolve_ip,
                &mut outbounds,
            );
            if !cond_rules.is_empty() {
                rules.extend(cond_rules);
                section_matched_any = true;
            }
        }

        // Also compile inline section lists/domains/subnets/ports/protocols
        let mut combined_domains = sec.domains.clone();
        for d in &sec.user_domains {
            if !combined_domains.contains(d) {
                combined_domains.push(d.clone());
            }
        }
        if !section_matched_any
            && (!sec.community_lists.is_empty()
                || !combined_domains.is_empty()
                || !sec.user_subnets.is_empty()
                || !sec.geoip_codes.is_empty()
                || !sec.geosite_codes.is_empty()
                || !sec.ports.is_empty()
                || !sec.source_ip_cidr.is_empty()
                || !sec.source_ports.is_empty()
                || !sec.protocol.is_empty()
                || !sec.dscp.is_empty())
        {
            let synthetic = TrafficCondition {
                id: format!("inline-{}", sec.id),
                enabled: true,
                name: sec.label.clone(),
                condition_type: "atomic".to_string(),
                community_lists: sec.community_lists.clone(),
                community_subnets: sec.community_subnets,
                user_domains: combined_domains,
                user_subnets: sec.user_subnets.clone(),
                geoip_codes: sec.geoip_codes.clone(),
                geoip_mode: sec.geoip_mode.clone(),
                geosite_codes: sec.geosite_codes.clone(),
                client_ips: sec.source_ip_cidr.clone(),
                ports: sec.ports.clone(),
                source_ports: sec.source_ports.clone(),
                protocol: sec.protocol.clone(),
                dscp: sec.dscp.clone(),
                ..Default::default()
            };
            let cond_rules = build_condition_rules(
                &synthetic,
                &cond_map,
                &target_outbound_tag,
                &store.settings.rulesets_dir,
                &store.settings.github_mirror,
                &mut rule_sets,
                &mut seen_rule_sets,
                store.settings.enable_ipv6,
                pre_resolve_ip,
                &mut outbounds,
            );
            if !cond_rules.is_empty() {
                rules.extend(cond_rules);
                section_matched_any = true;
            }
        }

        if (!section_matched_any && sec.condition_refs.is_empty()) || sec.match_all {
            rules.push(json!({
                "outbound": target_outbound_tag
            }));
        }
    }

    let mut ts_route_rules: Vec<Value> = Vec::new();
    let mut has_cgnat_rule = rules.iter().any(|r| {
        let Some(cidr) = r.get("ip_cidr") else {
            return false;
        };
        cidr.as_str()
            .is_some_and(|s| s == "100.64.0.0/10" || s == "fd7a:115c:a1e0::/48")
            || cidr.as_array().is_some_and(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .any(|s| s == "100.64.0.0/10" || s == "fd7a:115c:a1e0::/48")
            })
    });
    for srv in store
        .servers
        .iter()
        .filter(|s| s.enabled && s.is_embedded_tailscale())
    {
        let inb_tag = format!("srv-{}", srv.id);
        if !has_cgnat_rule {
            has_cgnat_rule = true;
            ts_route_rules.push(json!({
                "ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"],
                "outbound": inb_tag,
            }));
        }
        if is_tachyon_core
            && (srv.tailscale_accept_routes || !srv.tailscale_use_exit_node.trim().is_empty())
        {
            ts_route_rules.push(json!({
                "preferred_by": inb_tag,
                "outbound": inb_tag,
            }));
        }
    }
    let client_ts_eps: Vec<&Value> = endpoints
        .iter()
        .filter(|ep| {
            ep.get("type").and_then(Value::as_str) == Some("tailscale")
                && ep
                    .get("tag")
                    .and_then(Value::as_str)
                    .is_some_and(|t| !t.is_empty() && !t.starts_with("srv-"))
        })
        .collect();
    if !client_ts_eps.is_empty() {
        if !has_cgnat_rule
            && let Some(first_tag) = client_ts_eps[0].get("tag").and_then(Value::as_str)
        {
            ts_route_rules.push(json!({
                "ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"],
                "outbound": first_tag,
            }));
        }
        if is_tachyon_core {
            for ep in &client_ts_eps {
                let ep_tag = ep.get("tag").and_then(Value::as_str).unwrap_or("");
                let accept_routes = ep.get("accept_routes").and_then(Value::as_bool) != Some(false);
                let exit_node_empty = ep
                    .get("exit_node")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .unwrap_or("")
                    .is_empty();
                if !ep_tag.is_empty() && accept_routes && exit_node_empty {
                    ts_route_rules.push(json!({
                        "preferred_by": ep_tag,
                        "outbound": ep_tag,
                    }));
                }
            }
        }
    }
    if !ts_route_rules.is_empty() {
        rules.splice(ts_route_insert_idx..ts_route_insert_idx, ts_route_rules);
    }

    if !base_policy_emitted {
        emit_base_policy(&mut rules, &mut base_policy_emitted);
    }

    // Built-in `direct` and `block` outbounds
    outbounds.push(json!({
        "type": "direct",
        "tag": "direct"
    }));
    outbounds.push(json!({
        "type": "block",
        "tag": "block"
    }));

    // 4. DNS configuration (`127.0.0.42:53` + FakeIP + SafeSearch + bootstrap resolver)
    let boot_dns = store
        .settings
        .bootstrap_dns_servers
        .first()
        .cloned()
        .unwrap_or_else(|| "77.88.8.8".to_string());
    let boot_host = boot_dns
        .trim_start_matches("udp://")
        .trim_start_matches("https://")
        .split(['/', ':'])
        .next()
        .unwrap_or("77.88.8.8");

    let main_dns = store
        .settings
        .dns_servers
        .first()
        .cloned()
        .unwrap_or_else(|| "1.1.1.1".to_string());
    let main_host = main_dns
        .trim_start_matches("https://")
        .trim_start_matches("tls://")
        .trim_start_matches("quic://")
        .trim_start_matches("h3://")
        .trim_start_matches("udp://")
        .split(['/', ':'])
        .next()
        .unwrap_or("1.1.1.1");
    let dns_remote_obj = if main_dns.starts_with("https://") || store.settings.dns_type == "doh" {
        json!({
            "type": "https",
            "tag": "dns-remote",
            "server": main_host,
            "server_port": 443,
            "domain_resolver": "dns-bootstrap",
            "detour": "direct"
        })
    } else if main_dns.starts_with("tls://") || store.settings.dns_type == "dot" {
        json!({
            "type": "tls",
            "tag": "dns-remote",
            "server": main_host,
            "server_port": 853,
            "domain_resolver": "dns-bootstrap",
            "detour": "direct"
        })
    } else if main_dns.starts_with("quic://") || store.settings.dns_type == "doq" {
        json!({
            "type": "quic",
            "tag": "dns-remote",
            "server": main_host,
            "server_port": 853,
            "domain_resolver": "dns-bootstrap",
            "detour": "direct"
        })
    } else {
        json!({
            "type": "udp",
            "tag": "dns-remote",
            "server": main_host,
            "server_port": 53,
            "detour": "direct"
        })
    };

    let fakeip_v4 = if store.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        store.settings.fakeip_inet4_range.trim()
    };
    let fakeip_v6 = if store.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        store.settings.fakeip_inet6_range.trim()
    };

    let mut dns_servers_vec = vec![
        json!({
            "type": "udp",
            "tag": "dns-bootstrap",
            "server": boot_host,
            "server_port": 53,
            "detour": "direct"
        }),
        dns_remote_obj,
        {
            let mut fakeip_srv = json!({
                "type": "fakeip",
                "tag": "dns-fakeip",
                "inet4_range": fakeip_v4
            });
            if store.settings.enable_ipv6 {
                fakeip_srv["inet6_range"] = json!(fakeip_v6);
            }
            fakeip_srv
        },
    ];
    let mut dns_rules_vec: Vec<Value> = Vec::new();
    let ntp_domains = collect_system_ntp_domains();
    if !ntp_domains.is_empty() {
        dns_rules_vec.push(json!({
            "domain": ntp_domains,
            "server": "dns-bootstrap"
        }));
    }
    dns_rules_vec.push(json!({
        "query_type": ["HTTPS", "SVCB"],
        "action": "predefined",
        "rcode": "NOERROR"
    }));
    dns_rules_vec.push(json!({
        "domain": ["use-application-dns.net"],
        "domain_suffix": [".use-application-dns.net"],
        "action": "reject"
    }));
    if !safe_search_ips.is_empty() {
        dns_servers_vec.push(json!({
            "type": "hosts",
            "tag": "dns-safesearch",
            "predefined": {
                "www.google.com": ["216.239.38.120"],
                "google.com": ["216.239.38.120"],
                "www.youtube.com": ["216.239.38.120"],
                "m.youtube.com": ["216.239.38.120"],
                "youtubei.googleapis.com": ["216.239.38.120"],
                "www.bing.com": ["204.79.197.220"],
                "duckduckgo.com": ["52.142.124.215"],
                "www.duckduckgo.com": ["52.142.124.215"],
                "yandex.ru": ["213.180.193.56"],
                "ya.ru": ["213.180.193.56"]
            }
        }));
        dns_rules_vec.push(json!({
            "source_ip_cidr": safe_search_ips,
            "domain": [
                "www.google.com",
                "google.com",
                "www.youtube.com",
                "m.youtube.com",
                "youtubei.googleapis.com",
                "www.bing.com",
                "duckduckgo.com",
                "www.duckduckgo.com",
                "yandex.ru",
                "ya.ru"
            ],
            "server": "dns-safesearch"
        }));
    }
    if !store.settings.fakeip_exclude.is_empty() {
        dns_rules_vec.push(json!({
            "domain_suffix": store.settings.fakeip_exclude,
            "server": "dns-remote"
        }));
    }
    if !store.settings.enable_ipv6 {
        dns_rules_vec.push(json!({
            "query_type": ["AAAA"],
            "action": "predefined",
            "rcode": "NOERROR"
        }));
    }
    if !ts_dns_metas.is_empty() {
        let mut has_ts_net_rule = false;
        for meta in &ts_dns_metas {
            if !meta.accept_dns {
                continue;
            }
            let safe_ep = safe_tailscale_id(&meta.ep_tag);
            let dns_tag = format!("dns-{safe_ep}");
            if !dns_servers_vec
                .iter()
                .any(|s| s.get("tag").and_then(Value::as_str) == Some(dns_tag.as_str()))
            {
                dns_servers_vec.push(json!({
                    "type": "tailscale",
                    "tag": dns_tag,
                    "endpoint": meta.ep_tag,
                    "accept_default_resolvers": meta.accept_default_resolvers,
                }));
            }
            if meta.is_server && !meta.advertise_exit_node {
                dns_rules_vec.push(json!({
                    "inbound": [meta.ep_tag],
                    "server": dns_tag,
                }));
            }
            if !has_ts_net_rule {
                has_ts_net_rule = true;
                dns_rules_vec.push(json!({
                    "domain_suffix": ["ts.net"],
                    "server": dns_tag,
                }));
            }
            if is_tachyon_core {
                dns_rules_vec.push(json!({
                    "preferred_by": meta.ep_tag,
                    "server": dns_tag,
                }));
            }
        }
    }
    dns_rules_vec.push(json!({
        "query_type": if store.settings.enable_ipv6 {
            json!(["A", "AAAA"])
        } else {
            json!(["A"])
        },
        "server": "dns-fakeip",
        "rewrite_ttl": store.settings.dns_rewrite_ttl
    }));

    let eff_dns_strategy = if !store.settings.enable_ipv6 {
        "ipv4_only"
    } else if store.settings.dns_strategy.trim().is_empty() {
        "prefer_ipv4"
    } else {
        store.settings.dns_strategy.trim()
    };
    let mut dns_map = Map::new();
    dns_map.insert("servers".into(), Value::Array(dns_servers_vec));
    dns_map.insert("rules".into(), Value::Array(dns_rules_vec));
    dns_map.insert("final".into(), json!("dns-remote"));
    dns_map.insert("strategy".into(), json!(eff_dns_strategy));
    dns_map.insert("reverse_mapping".into(), json!(true));
    if store.settings.dns_local_cache {
        dns_map.insert("independent_cache".into(), json!(true));
    } else {
        dns_map.insert("disable_cache".into(), json!(true));
    }
    let dns_block = Value::Object(dns_map);

    let clash_port = store
        .settings
        .clash_api_addr
        .rsplit_once(':')
        .and_then(|(_, p)| p.trim().parse::<u16>().ok())
        .unwrap_or(9090);
    let clash_controller = if store.settings.enable_yacd || store.settings.enable_yacd_wan_access {
        format!("0.0.0.0:{clash_port}")
    } else if store.settings.clash_api_addr.starts_with("127.0.0.1:") {
        store.settings.clash_api_addr.clone()
    } else {
        format!("127.0.0.1:{clash_port}")
    };
    let clash_secret = if !store.settings.yacd_secret_key.trim().is_empty() {
        store.settings.yacd_secret_key.trim().to_string()
    } else {
        store.settings.clash_api_secret.clone()
    };
    let mut clash_api_obj = Map::new();
    clash_api_obj.insert("external_controller".into(), json!(clash_controller));
    clash_api_obj.insert("secret".into(), json!(clash_secret));
    if store.settings.enable_yacd {
        clash_api_obj.insert("external_ui".into(), json!("ui"));
    }

    Ok(json!({
        "log": {
            "level": store.settings.log_level,
            "timestamp": true
        },
        "dns": dns_block,
        "endpoints": endpoints,
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": rules,
            "rule_set": rule_sets,
            "final": "direct",
            "auto_detect_interface": true,
            "default_mark": 1073741824,
            "default_domain_resolver": "dns-bootstrap"
        },
        "experimental": {
            "cache_file": {
                "enabled": true,
                "path": store.settings.cache_path,
                "store_fakeip": true
            },
            "clash_api": Value::Object(clash_api_obj)
        }
    }))
}

fn parental_category_domains(cat: &str) -> &'static [&'static str] {
    match cat.trim().to_ascii_lowercase().as_str() {
        "social" => &[
            "instagram.com",
            "facebook.com",
            "tiktok.com",
            "vk.com",
            "ok.ru",
            "x.com",
            "twitter.com",
            "snapchat.com",
            "reddit.com",
        ],
        "video" => &[
            "youtube.com",
            "youtu.be",
            "googlevideo.com",
            "rutube.ru",
            "vimeo.com",
            "dailymotion.com",
            "vkvideo.ru",
        ],
        "gaming" => &[
            "steampowered.com",
            "steamcommunity.com",
            "epicgames.com",
            "roblox.com",
            "rbxcdn.com",
            "battle.net",
            "riotgames.com",
            "ea.com",
            "minecraft.net",
        ],
        "adult" => &[
            "pornhub.com",
            "xvideos.com",
            "xnxx.com",
            "xhamster.com",
            "onlyfans.com",
            "chaturbate.com",
            "redtube.com",
        ],
        "messengers" => &[
            "telegram.org",
            "t.me",
            "web.telegram.org",
            "whatsapp.com",
            "whatsapp.net",
            "discord.com",
            "discord.gg",
            "viber.com",
            "signal.org",
        ],
        "shopping" => &[
            "wildberries.ru",
            "ozon.ru",
            "aliexpress.com",
            "aliexpress.ru",
            "market.yandex.ru",
            "avito.ru",
            "amazon.com",
        ],
        "streaming" => &[
            "twitch.tv",
            "ttvnw.net",
            "kick.com",
            "netflix.com",
            "nflxvideo.net",
            "kinopoisk.ru",
            "ivi.ru",
            "okko.tv",
            "spotify.com",
        ],
        _ => &[],
    }
}

fn build_outbound_group_map(
    groups: &[OutboundGroup],
    sources: &[OutboundSource],
    source_tag_map: &HashMap<String, Vec<String>>,
) -> HashMap<String, Vec<String>> {
    let known_prefixes: Vec<String> = sources
        .iter()
        .filter(|s| s.prefix_nodes && !s.node_prefix.trim().is_empty())
        .map(|s| s.node_prefix.trim().to_string())
        .collect();
    let mut map = HashMap::new();
    for grp in groups.iter().filter(|g| g.enabled) {
        let mut refs = Vec::new();
        for r in grp
            .primary_refs
            .iter()
            .chain(grp.backup_refs.iter())
            .chain(grp.source_refs.iter())
        {
            if !refs.contains(r) {
                refs.push(r.clone());
            }
        }
        if refs.is_empty() {
            refs = sources
                .iter()
                .filter(|s| s.enabled)
                .map(|s| s.id.clone())
                .collect();
        }
        let mut tags = Vec::new();
        for sref in &refs {
            if let Some(stags) = source_tag_map.get(sref) {
                for t in stags {
                    if !tags.contains(t) {
                        tags.push(t.clone());
                    }
                }
            }
        }
        let inc_cc: Vec<String> = grp
            .include_country_flags
            .iter()
            .map(|c| c.to_uppercase())
            .collect();
        let exc_cc: Vec<String> = grp
            .exclude_country_flags
            .iter()
            .map(|c| c.to_uppercase())
            .collect();
        let inc_kw = grp.include_name_regex.trim().to_lowercase();
        let exc_kw = grp.exclude_name_regex.trim().to_lowercase();
        if !inc_cc.is_empty()
            || !exc_cc.is_empty()
            || !inc_kw.is_empty()
            || !exc_kw.is_empty()
            || !grp.include_prefixes.is_empty()
            || !grp.exclude_prefixes.is_empty()
            || !grp.include_servers.is_empty()
            || !grp.exclude_servers.is_empty()
        {
            let filtered: Vec<String> = tags
                .iter()
                .filter(|tag| {
                    let cc = detect_country_code(tag).to_uppercase();
                    let tl = tag.to_lowercase();
                    if !inc_cc.is_empty() && !inc_cc.contains(&cc) {
                        return false;
                    }
                    if !exc_cc.is_empty() && exc_cc.contains(&cc) {
                        return false;
                    }
                    if !grp.include_prefixes.is_empty()
                        && !grp.include_prefixes.iter().any(|p| {
                            let pt = p.trim();
                            tag.starts_with(&format!("[{pt}]"))
                                || tag.starts_with(&format!("{pt} "))
                        })
                    {
                        return false;
                    }
                    if !grp.exclude_prefixes.is_empty()
                        && grp.exclude_prefixes.iter().any(|p| {
                            let pt = p.trim();
                            tag.starts_with(&format!("[{pt}]"))
                                || tag.starts_with(&format!("{pt} "))
                        })
                    {
                        return false;
                    }
                    if !inc_kw.is_empty() && !tl.contains(&inc_kw) {
                        return false;
                    }
                    if !exc_kw.is_empty() && tl.contains(&exc_kw) {
                        return false;
                    }
                    if !grp.include_servers.is_empty()
                        && !grp
                            .include_servers
                            .iter()
                            .any(|inc| server_tag_matches(tag, inc, &known_prefixes))
                    {
                        return false;
                    }
                    if grp
                        .exclude_servers
                        .iter()
                        .any(|exc| server_tag_matches(tag, exc, &known_prefixes))
                    {
                        return false;
                    }
                    true
                })
                .cloned()
                .collect();
            tags = filtered;
        }
        map.insert(grp.id.clone(), tags);
    }
    map
}

/// Resolve the outbound tag for a `RoutingSection`.
/// Strictly adheres to the balancer invariant: candidate nodes come from `sec.outbound_source_refs`,
/// `sec.outbound_group_ref(s)`, or nested `sec.section_refs`, while `sec.balancer_refs` provides
/// the selection policy across all 14 balancer modes.
#[allow(clippy::too_many_arguments)]
fn resolve_section_outbound(
    sec: &RoutingSection,
    source_tag_map: &HashMap<String, Vec<String>>,
    group_tag_map: &HashMap<String, Vec<String>>,
    sec_map: &HashMap<&str, &RoutingSection>,
    bal_map: &HashMap<&str, &BalancerConfig>,
    outbounds: &mut Vec<Value>,
    endpoints: &mut Vec<Value>,
    ts_dns_metas: &mut Vec<TailscaleEndpointDnsMeta>,
    seen_outbound_tags: &mut HashMap<String, bool>,
    visited: &mut Vec<String>,
) -> String {
    match sec.connection_type.as_str() {
        "direct" | "hosts" => return "direct".to_string(),
        "block" => return "block".to_string(),
        _ => {}
    }

    if visited.contains(&sec.id) || visited.len() >= 8 {
        return "direct".to_string();
    }
    visited.push(sec.id.clone());

    let mut candidate_tags: Vec<String> = Vec::new();
    for sref in &sec.outbound_source_refs {
        if let Some(tags) = source_tag_map.get(sref) {
            for t in tags {
                if !candidate_tags.contains(t) {
                    candidate_tags.push(t.clone());
                }
            }
        }
    }
    if !sec.outbound_group_ref.is_empty()
        && let Some(tags) = group_tag_map.get(&sec.outbound_group_ref)
    {
        for t in tags {
            if !candidate_tags.contains(t) {
                candidate_tags.push(t.clone());
            }
        }
    }
    for gref in &sec.outbound_group_refs {
        if let Some(tags) = group_tag_map.get(gref) {
            for t in tags {
                if !candidate_tags.contains(t) {
                    candidate_tags.push(t.clone());
                }
            }
        }
    }
    for child_sec_id in &sec.section_refs {
        if let Some(child_sec) = sec_map.get(child_sec_id.as_str()).copied()
            && child_sec.enabled
        {
            let child_tag = resolve_section_outbound(
                child_sec,
                source_tag_map,
                group_tag_map,
                sec_map,
                bal_map,
                outbounds,
                endpoints,
                ts_dns_metas,
                seen_outbound_tags,
                visited,
            );
            if !child_tag.is_empty() && !candidate_tags.contains(&child_tag) {
                candidate_tags.push(child_tag);
            }
        }
    }

    visited.pop();

    // Apply section-level server narrowing filters (country filter & keyword/regex filter)
    let filter_mode = sec.section_filter_mode.trim();
    if !filter_mode.is_empty()
        && !filter_mode.eq_ignore_ascii_case("disabled")
        && (!sec.include_countries.is_empty()
            || !sec.exclude_countries.is_empty()
            || !sec.node_filter_allow.trim().is_empty()
            || !sec.node_filter_deny.trim().is_empty())
    {
        let inc_c: Vec<String> = sec
            .include_countries
            .iter()
            .map(|c| c.to_uppercase())
            .collect();
        let exc_c: Vec<String> = sec
            .exclude_countries
            .iter()
            .map(|c| c.to_uppercase())
            .collect();
        let allow_kw: Vec<String> = sec
            .node_filter_allow
            .split('|')
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        let deny_kw: Vec<String> = sec
            .node_filter_deny
            .split('|')
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        let filtered: Vec<String> = candidate_tags
            .iter()
            .filter(|tag| {
                let cc = detect_country_code(tag).to_uppercase();
                let tl = tag.to_lowercase();
                if !inc_c.is_empty() && !inc_c.contains(&cc) {
                    return false;
                }
                if !exc_c.is_empty() && exc_c.contains(&cc) {
                    return false;
                }
                if !allow_kw.is_empty() && !allow_kw.iter().any(|k| tl.contains(k)) {
                    return false;
                }
                if !deny_kw.is_empty() && deny_kw.iter().any(|k| tl.contains(k)) {
                    return false;
                }
                true
            })
            .cloned()
            .collect();
        candidate_tags = filtered;
    }

    if candidate_tags.is_empty()
        && sec.connection_type == "fptn"
        && !sec.fptn_access_token.trim().is_empty()
    {
        let expanded = expand_fptn_token_outbounds(
            &format!("fptn-sec-{}", sec.id),
            &sec.fptn_access_token,
            sec.fptn_sni.trim(),
            sec.fptn_bypass_method.trim(),
            sec.fptn_preferred_server.trim(),
        );
        for (m_tag, m_val) in expanded {
            if !seen_outbound_tags.contains_key(&m_tag) {
                seen_outbound_tags.insert(m_tag.clone(), true);
                outbounds.push(m_val);
            }
            candidate_tags.push(m_tag);
        }
    }

    if candidate_tags.is_empty() {
        if sec.connection_type == "csqtt" || sec.connection_type == "wdtt" {
            let sec_tag = format!("wdtt-sec-{}", sec.id);
            let uri = if !sec.csqtt_uri.trim().is_empty() {
                sec.csqtt_uri.trim()
            } else {
                sec.warp_flow_uri.trim()
            };
            let eff_workers = if sec.csqtt_workers > 0 {
                sec.csqtt_workers
            } else {
                sec.wdtt_workers
            };
            let eff_mtu = if sec.csqtt_mtu > 0 {
                sec.csqtt_mtu
            } else {
                sec.wdtt_mtu
            };
            let eff_did = if !sec.csqtt_device_id.trim().is_empty() {
                sec.csqtt_device_id.trim()
            } else {
                sec.warp_flow_device_id.trim()
            };
            let built_val = if sec.csqtt_server.trim().is_empty() && !uri.is_empty() {
                parse_proxy_uri(uri, 0).map(|mut node| {
                    if let Some(obj) = node.outbound_json.as_object_mut() {
                        obj.insert("tag".into(), json!(sec_tag));
                        if (1..=126).contains(&eff_workers) {
                            obj.insert("workers".into(), json!(eff_workers));
                        }
                        if (576..=1500).contains(&eff_mtu) {
                            obj.insert("mtu".into(), json!(eff_mtu));
                        }
                        if !eff_did.is_empty() && !obj.contains_key("device_id") {
                            obj.insert("device_id".into(), json!(eff_did));
                        }
                    }
                    node.outbound_json
                })
            } else {
                build_wdtt_outbound_value(
                    &sec_tag,
                    &WdttParams {
                        server: &sec.csqtt_server,
                        server_port: sec.csqtt_server_port,
                        password: &sec.csqtt_password,
                        mode: &sec.csqtt_mode,
                        obfs: &sec.csqtt_obfs,
                        raw_port: sec.csqtt_raw_port,
                        wg_port: sec.csqtt_wg_port,
                        local_port: sec.csqtt_local_port,
                        hashes: &sec.csqtt_hashes,
                        vk_auth_mode: &sec.csqtt_vk_auth_mode,
                        vk_cookie: &sec.csqtt_vk_cookie,
                        vk_client_ids: &sec.csqtt_vk_client_ids,
                        turn_server: &sec.csqtt_turn_server,
                        turn_urls: &sec.csqtt_turn_urls,
                        turn_username: &sec.csqtt_turn_username,
                        turn_password: &sec.csqtt_turn_password,
                        turn_transport: &sec.csqtt_turn_transport,
                        workers: eff_workers,
                        device_id: eff_did,
                        mtu: eff_mtu,
                        chunk1: sec.csqtt_chunk1,
                        wg_private_key: &sec.csqtt_wg_private_key,
                        wg_peer_public_key: &sec.csqtt_wg_peer_public_key,
                        wg_address: &sec.csqtt_wg_address,
                    },
                )
            };
            if let Some(out_obj) = built_val {
                if !seen_outbound_tags.contains_key(&sec_tag) {
                    seen_outbound_tags.insert(sec_tag.clone(), true);
                    outbounds.push(out_obj);
                }
                candidate_tags.push(sec_tag);
            }
        }
        if sec.connection_type == "desync" {
            if !sec.desync_opts.trim().is_empty()
                || !sec.desync_mode.trim().is_empty()
                || !sec.desync_preset.trim().is_empty()
                || !sec.desync_sni_pool.is_empty()
                || sec.desync_host_fake
                || sec.desync_wscale.is_some()
                || !sec.desync_fake_payload.trim().is_empty()
                || !sec.desync_fake_tls.trim().is_empty()
            {
                let sec_tag = format!("desync-sec-{}", sec.id);
                if !seen_outbound_tags.contains_key(&sec_tag) {
                    seen_outbound_tags.insert(sec_tag.clone(), true);
                    let out_obj = build_desync_outbound_json(
                        &sec_tag,
                        &DesyncParams {
                            opts: &sec.desync_opts,
                            preset: &sec.desync_preset,
                            mode: &sec.desync_mode,
                            fooling: &sec.desync_fooling,
                            split_pos: &sec.desync_split_pos,
                            fake_ttl: sec.desync_fake_ttl,
                            fake_sni: &sec.desync_fake_sni,
                            sni_pool: &sec.desync_sni_pool,
                            repeats: sec.desync_repeats,
                            split_delay_ms: sec.desync_split_delay_ms,
                            tlsrec_first: sec.desync_tlsrec_first,
                            seqovl: sec.desync_seqovl,
                            syndata: sec.desync_syndata,
                            wsize: sec.desync_wsize,
                            wscale: sec.desync_wscale,
                            host_fake: sec.desync_host_fake,
                            fake_payload: &sec.desync_fake_payload,
                            fake_tls: &sec.desync_fake_tls,
                            ipfrag: sec.desync_ipfrag,
                            udp_fake: sec.desync_udp_fake,
                            udp_repeats: sec.desync_udp_repeats,
                            udp_fake_ttl: sec.desync_udp_fake_ttl,
                            udplen: sec.desync_udplen,
                        },
                        false,
                    );
                    outbounds.push(out_obj);
                }
                return sec_tag;
            }
            return "adaptive-desync-default".to_string();
        }
        if sec.is_native_tailscale() {
            let sec_tag = format!("tailscale-sec-{}", sec.id);
            if !seen_outbound_tags.contains_key(&sec_tag) {
                seen_outbound_tags.insert(sec_tag.clone(), true);
                let bind_iface = if !sec.bind_interface.trim().is_empty() {
                    sec.bind_interface.trim()
                } else {
                    "tailscale0"
                };
                outbounds.push(json!({
                    "type": "direct",
                    "tag": sec_tag,
                    "bind_interface": bind_iface,
                }));
            }
            return sec_tag;
        }
        if sec.is_embedded_tailscale() {
            let sec_tag = format!("tailscale-sec-{}", sec.id);
            if !seen_outbound_tags.contains_key(&sec_tag) {
                seen_outbound_tags.insert(sec_tag.clone(), true);
                let ep = build_tailscale_endpoint_json(
                    &sec_tag,
                    &sec_tag,
                    false,
                    &TailscaleEndpointParams::from_section(sec),
                );
                ts_dns_metas.push(TailscaleEndpointDnsMeta {
                    ep_tag: sec_tag.clone(),
                    is_server: false,
                    accept_dns: sec.tailscale_accept_dns,
                    accept_default_resolvers: sec.tailscale_accept_default_resolvers,
                    advertise_exit_node: sec.tailscale_advertise_exit_node,
                });
                endpoints.push(ep);
            }
            return sec_tag;
        }
        let fp = sec.fail_policy.trim().to_ascii_lowercase();
        if fp == "block" || fp == "isolate" || fp == "reject" || fp == "drop" {
            return "block".to_string();
        }
        return "direct".to_string();
    }

    // If balancers are attached to this section, synthesize section-scoped balancer outbounds
    // populated strictly with `candidate_tags` from this section across all 14 algorithms!
    let mut built_bal_tags = Vec::new();
    for bal_id in &sec.balancer_refs {
        if let Some(bal) = bal_map.get(bal_id.as_str()).copied()
            && bal.enabled
        {
            let bal_tag = format!("bal-{}-{}", sec.id, bal.id);
            if !seen_outbound_tags.contains_key(&bal_tag) {
                seen_outbound_tags.insert(bal_tag.clone(), true);
                outbounds.push(build_balancer_outbound(
                    &bal_tag,
                    bal,
                    candidate_tags.clone(),
                ));
            }
            built_bal_tags.push(bal_tag);
        }
    }
    if built_bal_tags.len() == 1 {
        return built_bal_tags.remove(0);
    } else if built_bal_tags.len() > 1 {
        let sel_tag = format!("sel-{}", sec.id);
        if !seen_outbound_tags.contains_key(&sel_tag) {
            seen_outbound_tags.insert(sel_tag.clone(), true);
            outbounds.push(json!({
                "type": "selector",
                "tag": sel_tag,
                "outbounds": built_bal_tags,
                "default": built_bal_tags[0],
                "interrupt_exist_connections": false
            }));
        }
        return sel_tag;
    }

    if candidate_tags.len() == 1 {
        return candidate_tags[0].clone();
    }

    let sel_tag = format!("sel-{}", sec.id);
    if !seen_outbound_tags.contains_key(&sel_tag) {
        seen_outbound_tags.insert(sel_tag.clone(), true);
        let default_tag = if !sec.active_selected_tag.is_empty()
            && candidate_tags.contains(&sec.active_selected_tag)
        {
            sec.active_selected_tag.clone()
        } else {
            candidate_tags[0].clone()
        };
        outbounds.push(json!({
            "type": "selector",
            "tag": sel_tag,
            "outbounds": candidate_tags,
            "default": default_tag,
            "interrupt_exist_connections": false
        }));
    }
    sel_tag
}

fn normalize_sticky_hash(raw: &str) -> Vec<&'static str> {
    let trimmed = raw.trim().to_ascii_lowercase();
    if trimmed.is_empty() || trimmed == "src_ip" || trimmed == "source_ip" {
        return vec!["source_ip"];
    }
    if trimmed == "src_dst" {
        return vec!["source_ip", "dest_ip"];
    }
    if trimmed == "none" {
        return vec!["none"];
    }
    let mut parts = Vec::new();
    for tok in trimmed.split(|c: char| c == ',' || c.is_whitespace()) {
        let mapped = match tok.trim() {
            "src_ip" | "source_ip" => Some("source_ip"),
            "dst_ip" | "dest_ip" => Some("dest_ip"),
            "dst_port" | "dest_port" => Some("dest_port"),
            "domain" => Some("domain"),
            "process" => Some("process"),
            _ => None,
        };
        if let Some(m) = mapped
            && !parts.contains(&m)
        {
            parts.push(m);
        }
    }
    if parts.is_empty() {
        vec!["source_ip"]
    } else {
        parts
    }
}

fn build_balancer_outbound(bal_tag: &str, bal: &BalancerConfig, mut tags: Vec<String>) -> Value {
    let fb = bal.fallback_section.trim();
    if !fb.is_empty() && !tags.iter().any(|t| t == fb) {
        tags.push(fb.to_string());
    }
    let raw_mode = if !bal.mode.trim().is_empty() {
        bal.mode.trim().to_ascii_lowercase()
    } else if bal.balancer_type == "priority" {
        "priority".to_string()
    } else {
        "least_test".to_string()
    };
    let mode = match raw_mode.as_str() {
        "urltest" | "least_test" => "least_test",
        "random" | "round_robin" => "round_robin",
        "least_connections" | "least_load" => "least_load",
        "priority" => "priority",
        "stability" => "stability",
        "sticky" => "sticky",
        "weighted" => "weighted",
        "passive" => "passive",
        "hedged" => "hedged",
        "throughput" => "throughput",
        "quota" => "quota",
        "failover" => "failover",
        _ => "least_test",
    };
    let mut obj = Map::new();
    obj.insert("type".into(), json!("urltest"));
    obj.insert("tag".into(), json!(bal_tag));
    obj.insert("outbounds".into(), json!(tags));
    obj.insert("mode".into(), json!(mode));
    obj.insert(
        "url".into(),
        json!(if bal.testing_url.is_empty() {
            "https://www.gstatic.com/generate_204"
        } else {
            &bal.testing_url
        }),
    );
    obj.insert(
        "interval".into(),
        json!(format!("{}s", bal.check_interval.max(15))),
    );
    obj.insert("tolerance".into(), json!(bal.tolerance.max(50)));
    obj.insert(
        "interrupt_exist_connections".into(),
        json!(bal.interrupt_exist_connections),
    );
    obj.insert(
        "idle_timeout".into(),
        json!(if bal.idle_timeout.is_empty() {
            "30m"
        } else {
            &bal.idle_timeout
        }),
    );
    let mut balancer_opts = Map::new();
    if mode == "sticky" {
        balancer_opts.insert(
            "sticky_hash".into(),
            json!(normalize_sticky_hash(&bal.sticky_hash)),
        );
    }
    if mode == "quota" && bal.quota_mib > 0 {
        balancer_opts.insert("quota_mib".into(), json!(bal.quota_mib));
    }
    if !balancer_opts.is_empty() {
        obj.insert("balancer".into(), Value::Object(balancer_opts));
    }
    Value::Object(obj)
}

#[allow(clippy::too_many_arguments)]
struct AtomicConditionParts {
    scope: Map<String, Value>,
    branches: Vec<Map<String, Value>>,
    discord_udp_voice_fired: bool,
    blocked_unresolved_clients: bool,
}

fn push_unique_str(vec: &mut Vec<String>, s: &str) {
    let clean = s.trim();
    if !clean.is_empty() && !vec.iter().any(|x| x == clean) {
        vec.push(clean.to_string());
    }
}

fn insert_port_matchers(
    map: &mut Map<String, Value>,
    ports: &[String],
    port_key: &str,
    range_key: &str,
) {
    let mut exact_ports: Vec<u16> = Vec::new();
    let mut port_ranges: Vec<String> = Vec::new();
    for p in ports {
        let clean = p.trim();
        if clean.is_empty() {
            continue;
        }
        if clean.contains('-') || clean.contains(':') {
            port_ranges.push(clean.replace('-', ":"));
        } else if let Ok(num) = clean.parse::<u16>() {
            exact_ports.push(num);
        }
    }
    if !exact_ports.is_empty() {
        map.insert(port_key.into(), json!(exact_ports));
    }
    if !port_ranges.is_empty() {
        map.insert(range_key.into(), json!(port_ranges));
    }
}

fn register_remote_ruleset(
    rs_tags: &mut Vec<String>,
    rs_tag: String,
    base_url: String,
    update_interval: &str,
    github_mirror: &str,
    rule_sets: &mut Vec<Value>,
    seen_rule_sets: &mut HashMap<String, bool>,
) {
    if !rs_tags.contains(&rs_tag) {
        rs_tags.push(rs_tag.clone());
    }
    if !seen_rule_sets.contains_key(&rs_tag) {
        seen_rule_sets.insert(rs_tag.clone(), true);
        let remote_url = if github_mirror.trim().is_empty() {
            base_url
        } else {
            format!("{}/{}", github_mirror.trim_end_matches('/'), base_url)
        };
        rule_sets.push(json!({
            "tag": rs_tag,
            "type": "remote",
            "format": "binary",
            "url": remote_url,
            "download_detour": "direct",
            "update_interval": update_interval
        }));
    }
}

fn enable_desync_udp_fake(outbounds: &mut [Value], outbound_tag: &str) {
    for ob in outbounds.iter_mut() {
        if ob.get("tag").and_then(|v| v.as_str()) == Some(outbound_tag)
            && ob.get("type").and_then(|v| v.as_str()) == Some("desync")
            && ob.get("udp_fake").and_then(|v| v.as_bool()) != Some(false)
            && let Some(map) = ob.as_object_mut()
        {
            map.insert("udp_fake".into(), json!(true));
        }
    }
}

fn collect_atomic_condition_parts(
    cond: &TrafficCondition,
    _rulesets_dir: &str,
    github_mirror: &str,
    rule_sets: &mut Vec<Value>,
    seen_rule_sets: &mut HashMap<String, bool>,
    enable_ipv6: bool,
) -> AtomicConditionParts {
    let mut scope = Map::new();
    let mut branches = Vec::new();
    let mut discord_udp_voice_fired = false;

    let has_client_targets = cond.client_ips.iter().any(|s| !s.trim().is_empty());
    if has_client_targets {
        let mut cidrs = resolve_device_targets_to_cidrs(&cond.client_ips);
        if !enable_ipv6 {
            cidrs.retain(|s| !s.contains(':'));
        }
        if cidrs.is_empty() {
            return AtomicConditionParts {
                scope,
                branches,
                discord_udp_voice_fired: false,
                blocked_unresolved_clients: true,
            };
        }
        scope.insert("source_ip_cidr".into(), json!(cidrs));
    }

    if !cond.ports.is_empty() {
        insert_port_matchers(&mut scope, &cond.ports, "port", "port_range");
    }
    let l4 = cond.l4_proto.trim().to_ascii_lowercase();
    if !l4.is_empty() && !matches!(l4.as_str(), "all" | "both") {
        scope.insert("network".into(), json!(l4));
    }
    if !cond.source_ports.is_empty() {
        insert_port_matchers(
            &mut scope,
            &cond.source_ports,
            "source_port",
            "source_port_range",
        );
    }
    if !cond.protocol.is_empty() {
        scope.insert("protocol".into(), json!(cond.protocol));
    }
    if !cond.dscp.is_empty() {
        scope.insert("dscp".into(), json!(cond.dscp));
    }
    if !cond.time_window.trim().is_empty() {
        scope.insert("time_window".into(), json!(cond.time_window.trim()));
    }

    let mut rs_tags = Vec::new();
    let mut has_telegram = false;
    let mut has_discord = false;
    for list_name in &cond.community_lists {
        let clean = list_name.trim();
        if clean.is_empty() {
            continue;
        }
        if clean.eq_ignore_ascii_case("telegram") {
            has_telegram = true;
        }
        if clean.eq_ignore_ascii_case("discord") {
            has_discord = true;
        }
        register_remote_ruleset(
            &mut rs_tags,
            format!("trs-{clean}"),
            format!(
                "https://github.com/Dushnilin/tachyon-lists/releases/latest/download/{clean}.trs"
            ),
            "6h",
            github_mirror,
            rule_sets,
            seen_rule_sets,
        );
    }
    for code in &cond.geoip_codes {
        let clean = code.trim().to_ascii_lowercase();
        if clean.is_empty() {
            continue;
        }
        register_remote_ruleset(
            &mut rs_tags,
            format!("geoip-{clean}"),
            format!(
                "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-{clean}.srs"
            ),
            "24h",
            github_mirror,
            rule_sets,
            seen_rule_sets,
        );
    }
    for code in &cond.geosite_codes {
        let clean = code.trim().to_ascii_lowercase();
        if clean.is_empty() {
            continue;
        }
        register_remote_ruleset(
            &mut rs_tags,
            format!("geosite-{clean}"),
            format!(
                "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-{clean}.srs"
            ),
            "24h",
            github_mirror,
            rule_sets,
            seen_rule_sets,
        );
    }
    if !rs_tags.is_empty() {
        let mut b = Map::new();
        b.insert("rule_set".into(), json!(rs_tags));
        branches.push(b);
    }

    let mut domains = Vec::new();
    for d in &cond.user_domains {
        push_unique_str(&mut domains, d);
    }
    if !domains.is_empty() {
        let mut b = Map::new();
        b.insert("domain_suffix".into(), json!(domains));
        branches.push(b);
    }

    let mut ip_cidrs = Vec::new();
    for sub in &cond.user_subnets {
        if let Some(cidr) = parse_valid_cidr_token(sub) {
            if !enable_ipv6 && cidr.contains(':') {
                continue;
            }
            push_unique_str(&mut ip_cidrs, &cidr);
        }
    }
    if cond.community_subnets {
        if has_telegram {
            for sub in DEFAULT_TELEGRAM_SUBNETS {
                push_unique_str(&mut ip_cidrs, sub);
            }
        }
        if has_discord {
            for sub in DISCORD_DEDICATED_SUBNETS {
                push_unique_str(&mut ip_cidrs, sub);
            }
        }
    }
    if !ip_cidrs.is_empty() {
        let mut b = Map::new();
        b.insert("ip_cidr".into(), json!(ip_cidrs));
        branches.push(b);
    }

    if has_discord && cond.community_subnets && cond.ports.is_empty() {
        let mut voice_cidrs: Vec<String> = DEFAULT_DISCORD_VOICE_SUBNETS_V4
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        if enable_ipv6 {
            voice_cidrs.push(DISCORD_VOICE_SUBNET_V6.to_string());
        }
        if l4.is_empty() || l4 == "all" || l4 == "both" || l4 == "udp" {
            let mut b = Map::new();
            b.insert("network".into(), json!("udp"));
            b.insert("port_range".into(), json!(DISCORD_VOICE_PORT_RANGES));
            b.insert("ip_cidr".into(), json!(voice_cidrs.clone()));
            branches.push(b);
            discord_udp_voice_fired = true;
        }
        if l4.is_empty() || l4 == "all" || l4 == "both" || l4 == "tcp" {
            let mut b = Map::new();
            b.insert("network".into(), json!("tcp"));
            b.insert("port_range".into(), json!(DISCORD_MEDIA_PORT_RANGES));
            b.insert("ip_cidr".into(), json!(voice_cidrs));
            branches.push(b);
        }
    }

    AtomicConditionParts {
        scope,
        branches,
        discord_udp_voice_fired,
        blocked_unresolved_clients: false,
    }
}

fn build_atomic_single_rule(
    mut parts: AtomicConditionParts,
    invert: bool,
    outbound_tag: Option<&str>,
) -> Option<Value> {
    if parts.blocked_unresolved_clients || (parts.branches.is_empty() && parts.scope.is_empty()) {
        return None;
    }
    if parts.branches.is_empty() {
        if invert {
            parts.scope.insert("invert".into(), json!(true));
        }
        if let Some(tag) = outbound_tag {
            parts.scope.insert("outbound".into(), json!(tag));
        }
        return Some(Value::Object(parts.scope));
    }
    if parts.branches.len() == 1 {
        let mut branch = parts.branches.into_iter().next().unwrap();
        if !invert || parts.scope.is_empty() {
            let mut r = parts.scope;
            for (k, v) in branch {
                r.insert(k, v);
            }
            if invert {
                r.insert("invert".into(), json!(true));
            }
            if let Some(tag) = outbound_tag {
                r.insert("outbound".into(), json!(tag));
            }
            return Some(Value::Object(r));
        }
        branch.insert("invert".into(), json!(true));
        let mut and_obj = Map::new();
        and_obj.insert("type".into(), json!("logical"));
        and_obj.insert("mode".into(), json!("and"));
        and_obj.insert(
            "rules".into(),
            json!([Value::Object(parts.scope), Value::Object(branch)]),
        );
        if let Some(tag) = outbound_tag {
            and_obj.insert("outbound".into(), json!(tag));
        }
        return Some(Value::Object(and_obj));
    }

    let branch_vals: Vec<Value> = parts.branches.into_iter().map(Value::Object).collect();
    let mut or_obj = Map::new();
    or_obj.insert("type".into(), json!("logical"));
    or_obj.insert("mode".into(), json!("or"));
    or_obj.insert("rules".into(), Value::Array(branch_vals));
    if invert {
        or_obj.insert("invert".into(), json!(true));
    }
    if parts.scope.is_empty() {
        if let Some(tag) = outbound_tag {
            or_obj.insert("outbound".into(), json!(tag));
        }
        return Some(Value::Object(or_obj));
    }

    let mut and_obj = Map::new();
    and_obj.insert("type".into(), json!("logical"));
    and_obj.insert("mode".into(), json!("and"));
    and_obj.insert(
        "rules".into(),
        json!([Value::Object(parts.scope), Value::Object(or_obj)]),
    );
    if let Some(tag) = outbound_tag {
        and_obj.insert("outbound".into(), json!(tag));
    }
    Some(Value::Object(and_obj))
}

#[allow(clippy::too_many_arguments)]
fn build_condition_rule(
    cond: &TrafficCondition,
    cond_map: &HashMap<&str, &TrafficCondition>,
    outbound_tag: &str,
    rulesets_dir: &str,
    github_mirror: &str,
    rule_sets: &mut Vec<Value>,
    seen_rule_sets: &mut HashMap<String, bool>,
    enable_ipv6: bool,
    outbounds: &mut [Value],
    depth: usize,
) -> Option<Value> {
    if depth > 8 {
        return None;
    }
    let ctype = cond.condition_type.trim().to_ascii_lowercase();
    if matches!(ctype.as_str(), "all" | "any" | "not") && !cond.children.is_empty() {
        let mut sub_rules = Vec::new();
        for child_id in &cond.children {
            if let Some(child_cond) = cond_map.get(child_id.as_str()).copied()
                && child_cond.enabled
                && let Some(mut child_val) = build_condition_rule(
                    child_cond,
                    cond_map,
                    outbound_tag,
                    rulesets_dir,
                    github_mirror,
                    rule_sets,
                    seen_rule_sets,
                    enable_ipv6,
                    outbounds,
                    depth + 1,
                )
            {
                if let Some(m) = child_val.as_object_mut() {
                    m.remove("outbound");
                }
                sub_rules.push(child_val);
            }
        }
        if !sub_rules.is_empty() {
            let parent_parts = collect_atomic_condition_parts(
                cond,
                rulesets_dir,
                github_mirror,
                rule_sets,
                seen_rule_sets,
                enable_ipv6,
            );
            if parent_parts.blocked_unresolved_clients {
                return None;
            }
            let mut log_obj = Map::new();
            log_obj.insert("type".into(), json!("logical"));
            log_obj.insert(
                "mode".into(),
                json!(if ctype == "any" { "or" } else { "and" }),
            );
            log_obj.insert("rules".into(), Value::Array(sub_rules));
            if ctype == "not" || cond.invert {
                log_obj.insert("invert".into(), json!(true));
            }
            if !parent_parts.scope.is_empty() {
                let mut and_obj = Map::new();
                and_obj.insert("type".into(), json!("logical"));
                and_obj.insert("mode".into(), json!("and"));
                and_obj.insert(
                    "rules".into(),
                    json!([Value::Object(parent_parts.scope), Value::Object(log_obj)]),
                );
                and_obj.insert("outbound".into(), json!(outbound_tag));
                return Some(Value::Object(and_obj));
            }
            log_obj.insert("outbound".into(), json!(outbound_tag));
            return Some(Value::Object(log_obj));
        }
        return None;
    }

    let parts = collect_atomic_condition_parts(
        cond,
        rulesets_dir,
        github_mirror,
        rule_sets,
        seen_rule_sets,
        enable_ipv6,
    );
    if parts.discord_udp_voice_fired && !cond.invert {
        enable_desync_udp_fake(outbounds, outbound_tag);
    }
    build_atomic_single_rule(parts, cond.invert, Some(outbound_tag))
}

#[allow(clippy::too_many_arguments)]
fn build_condition_rules(
    cond: &TrafficCondition,
    cond_map: &HashMap<&str, &TrafficCondition>,
    outbound_tag: &str,
    rulesets_dir: &str,
    github_mirror: &str,
    rule_sets: &mut Vec<Value>,
    seen_rule_sets: &mut HashMap<String, bool>,
    enable_ipv6: bool,
    pre_resolve_ip: bool,
    outbounds: &mut [Value],
) -> Vec<Value> {
    let ctype = cond.condition_type.trim().to_ascii_lowercase();
    if matches!(ctype.as_str(), "all" | "any" | "not") && !cond.children.is_empty() {
        return build_condition_rule(
            cond,
            cond_map,
            outbound_tag,
            rulesets_dir,
            github_mirror,
            rule_sets,
            seen_rule_sets,
            enable_ipv6,
            outbounds,
            0,
        )
        .into_iter()
        .collect();
    }

    let parts = collect_atomic_condition_parts(
        cond,
        rulesets_dir,
        github_mirror,
        rule_sets,
        seen_rule_sets,
        enable_ipv6,
    );
    if parts.blocked_unresolved_clients {
        return Vec::new();
    }
    if parts.discord_udp_voice_fired && !cond.invert {
        enable_desync_udp_fake(outbounds, outbound_tag);
    }
    if cond.invert {
        return build_atomic_single_rule(parts, true, Some(outbound_tag))
            .into_iter()
            .collect();
    }
    if parts.branches.is_empty() {
        return build_atomic_single_rule(parts, false, Some(outbound_tag))
            .into_iter()
            .collect();
    }

    let mut out_rules = Vec::new();
    for branch in parts.branches {
        if pre_resolve_ip
            && (branch.contains_key("rule_set") || branch.contains_key("domain_suffix"))
        {
            let mut resolve_rule = parts.scope.clone();
            for (k, v) in &branch {
                resolve_rule.insert(k.clone(), v.clone());
            }
            resolve_rule.insert("action".into(), json!("resolve"));
            resolve_rule.insert("server".into(), json!("dns-remote"));
            out_rules.push(Value::Object(resolve_rule));
        }

        let mut route_rule = parts.scope.clone();
        for (k, v) in branch {
            route_rule.insert(k, v);
        }
        route_rule.insert("outbound".into(), json!(outbound_tag));
        out_rules.push(Value::Object(route_rule));
    }
    out_rules
}

fn active_inbound_clients(srv: &InboundServer) -> Vec<&InboundClient> {
    let now_secs = unix_now_secs();
    let now_ms = now_secs.saturating_mul(1000);
    srv.clients
        .iter()
        .filter(|c| {
            if !c.enabled {
                return false;
            }
            if c.expiry_time > 0 {
                let expired = if c.expiry_time > 100_000_000_000 {
                    now_ms >= c.expiry_time
                } else {
                    now_secs >= c.expiry_time
                };
                if expired {
                    return false;
                }
            }
            if c.total_limit_bytes > 0 && c.up.saturating_add(c.down) >= c.total_limit_bytes {
                return false;
            }
            true
        })
        .collect()
}

fn build_inbound_transport(srv: &InboundServer) -> Option<Value> {
    let net = srv.transport.trim();
    if net.is_empty() || net == "tcp" {
        return None;
    }
    let mut t = Map::new();
    t.insert("type".into(), json!(net));
    if !srv.transport_path.is_empty() {
        t.insert("path".into(), json!(srv.transport_path));
    }
    if !srv.transport_service_name.is_empty() {
        t.insert("service_name".into(), json!(srv.transport_service_name));
    }
    if !srv.transport_host.is_empty() {
        if net == "ws" || net == "httpupgrade" {
            t.insert("headers".into(), json!({ "Host": srv.transport_host }));
        } else {
            t.insert("host".into(), json!([srv.transport_host]));
        }
    } else if !srv.transport_hosts.is_empty() {
        t.insert("host".into(), json!(srv.transport_hosts));
    }
    if net == "xhttp" && !srv.transport_xhttp_mode.is_empty() {
        t.insert("mode".into(), json!(srv.transport_xhttp_mode));
    }
    Some(Value::Object(t))
}

fn build_endpoint_server(srv: &InboundServer) -> Option<Value> {
    let tag = format!("srv-{}", srv.id);
    match srv.protocol.as_str() {
        "awg" | "wireguard" => {
            if srv.awg_private_key.is_empty() {
                return None;
            }
            let active_clients = active_inbound_clients(srv);
            let mut peers = Vec::new();
            for c in &active_clients {
                if !c.wg_public_key.trim().is_empty() {
                    peers.push(json!({
                        "public_key": c.wg_public_key.trim(),
                        "allowed_ips": [if c.wg_client_ip.trim().is_empty() { "10.8.0.2/32" } else { c.wg_client_ip.trim() }],
                        "pre_shared_key": srv.awg_preshared_key,
                        "persistent_keepalive_interval": srv.awg_keepalive.max(25)
                    }));
                }
            }
            if peers.is_empty() {
                if srv.awg_peer_public_key.is_empty() {
                    return None;
                }
                peers.push(json!({
                    "public_key": srv.awg_peer_public_key,
                    "allowed_ips": [if srv.awg_client_address.is_empty() { "10.8.0.2/32" } else { &srv.awg_client_address }],
                    "pre_shared_key": srv.awg_preshared_key,
                    "persistent_keepalive_interval": srv.awg_keepalive.max(25)
                }));
            }
            let mut ep = json!({
                "type": "wireguard",
                "tag": tag,
                "listen_port": srv.listen_port,
                "address": [if srv.awg_local_address.is_empty() { "10.8.0.1/24" } else { &srv.awg_local_address }],
                "private_key": srv.awg_private_key,
                "mtu": srv.awg_mtu.max(1280),
                "peers": peers,
                "jc": srv.awg_jc,
                "jmin": srv.awg_jmin,
                "jmax": srv.awg_jmax,
                "s1": srv.awg_s1,
                "s2": srv.awg_s2,
                "s3": srv.awg_s3,
                "s4": srv.awg_s4,
                "h1": srv.awg_h1,
                "h2": srv.awg_h2,
                "h3": srv.awg_h3,
                "h4": srv.awg_h4
            });
            for (k, v) in [
                ("i1", &srv.awg_i1),
                ("i2", &srv.awg_i2),
                ("i3", &srv.awg_i3),
                ("i4", &srv.awg_i4),
                ("i5", &srv.awg_i5),
                ("j1", &srv.awg_j1),
                ("j2", &srv.awg_j2),
                ("j3", &srv.awg_j3),
            ] {
                if !v.trim().is_empty() {
                    ep[k] = json!(v.trim());
                }
            }
            if srv.awg_itime > 0 {
                ep["itime"] = json!(srv.awg_itime);
            }
            Some(ep)
        }
        "tailscale" => {
            if srv.is_native_tailscale() {
                return None;
            }
            Some(build_tailscale_endpoint_json(
                &tag,
                &srv.id,
                true,
                &TailscaleEndpointParams::from_server(srv),
            ))
        }
        _ => None,
    }
}

fn build_inbound_servers(srv: &InboundServer) -> Vec<Value> {
    if srv.protocol == "json_inbound" && !srv.inbound_json.trim().is_empty() {
        return serde_json::from_str::<Value>(&srv.inbound_json)
            .ok()
            .into_iter()
            .collect();
    }
    let tag = format!("srv-{}", srv.id);
    let cert_name = if srv.label.is_empty() {
        &srv.id
    } else {
        &srv.label
    };
    let default_cert = format!("/etc/tachyon/server-certs/{cert_name}.crt");
    let default_key = format!("/etc/tachyon/server-certs/{cert_name}.key");
    let cert_path = if srv.tls_certificate_path.is_empty() {
        &default_cert
    } else {
        &srv.tls_certificate_path
    };
    let key_path = if srv.tls_key_path.is_empty() {
        &default_key
    } else {
        &srv.tls_key_path
    };
    let tls_obj = if srv.security == "reality" {
        Some(json!({
            "enabled": true,
            "server_name": if srv.tls_server_name.is_empty() { "www.microsoft.com" } else { &srv.tls_server_name },
            "reality": {
                "enabled": true,
                "handshake": {
                    "server": if srv.reality_handshake_server.is_empty() { "www.microsoft.com" } else { &srv.reality_handshake_server },
                    "server_port": srv.reality_handshake_server_port.max(443)
                },
                "private_key": srv.reality_private_key,
                "short_id": [srv.reality_short_id],
                "max_time_difference": "1m"
            }
        }))
    } else if srv.security == "tls"
        || matches!(
            srv.protocol.as_str(),
            "tewfai"
                | "naive"
                | "hysteria2"
                | "tuic"
                | "anytls"
                | "fptn"
                | "trusttunnel"
                | "masque"
                | "openconnect"
                | "trojan"
        )
    {
        Some(json!({
            "enabled": true,
            "server_name": if srv.tls_server_name.is_empty() { "192.168.1.205" } else { &srv.tls_server_name },
            "certificate_path": cert_path,
            "key_path": key_path,
            "alpn": if srv.tls_alpn.is_empty() { vec!["h3".to_string()] } else { srv.tls_alpn.clone() }
        }))
    } else {
        None
    };

    let active_clients = active_inbound_clients(srv);
    if !srv.clients.is_empty() && active_clients.is_empty() {
        return Vec::new();
    }
    let transport_obj = build_inbound_transport(srv);

    match srv.protocol.as_str() {
        "vless" => {
            let users: Vec<Value> = if active_clients.is_empty() {
                let mut u = json!({
                    "name": srv.label,
                    "uuid": srv.server_uuid
                });
                if !srv.vless_flow.is_empty() && srv.vless_flow != "none" {
                    u["flow"] = json!(srv.vless_flow);
                }
                vec![u]
            } else {
                active_clients
                    .iter()
                    .map(|c| {
                        let flow = if !c.flow.is_empty() {
                            &c.flow
                        } else {
                            &srv.vless_flow
                        };
                        let mut u = json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "uuid": if c.uuid.is_empty() { &srv.server_uuid } else { &c.uuid }
                        });
                        if !flow.is_empty() && flow != "none" {
                            u["flow"] = json!(flow);
                        }
                        u
                    })
                    .collect()
            };
            let mut obj = json!({
                "type": "vless",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": users,
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            if let Some(tr) = transport_obj {
                obj["transport"] = tr;
            }
            vec![obj]
        }
        "vmess" => {
            let users: Vec<Value> = if active_clients.is_empty() {
                vec![json!({
                    "name": srv.label,
                    "uuid": srv.server_uuid,
                    "alterId": srv.vmess_alter_id
                })]
            } else {
                active_clients
                    .iter()
                    .map(|c| {
                        json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "uuid": if c.uuid.is_empty() { &srv.server_uuid } else { &c.uuid },
                            "alterId": srv.vmess_alter_id
                        })
                    })
                    .collect()
            };
            let mut obj = json!({
                "type": "vmess",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": users,
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            if let Some(tr) = transport_obj {
                obj["transport"] = tr;
            }
            vec![obj]
        }
        "trojan" => {
            let users: Vec<Value> = if active_clients.is_empty() {
                vec![json!({
                    "name": srv.label,
                    "password": srv.password
                })]
            } else {
                active_clients
                    .iter()
                    .map(|c| {
                        json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "password": if c.password.is_empty() { &srv.password } else { &c.password }
                        })
                    })
                    .collect()
            };
            let mut obj = json!({
                "type": "trojan",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": users,
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            if let Some(tr) = transport_obj {
                obj["transport"] = tr;
            }
            vec![obj]
        }
        "shadowsocks" | "ss" => {
            let mut obj = json!({
                "type": "shadowsocks",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "method": if srv.method.is_empty() { "aes-128-gcm" } else { &srv.method },
                "password": srv.password
            });
            if !active_clients.is_empty() {
                obj["users"] = json!(
                    active_clients
                        .iter()
                        .map(|c| json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "password": if c.password.is_empty() { &srv.password } else { &c.password }
                        }))
                        .collect::<Vec<Value>>()
                );
            }
            vec![obj]
        }
        "hysteria2" => {
            let users: Vec<Value> = if active_clients.is_empty() {
                vec![json!({
                    "name": srv.label,
                    "password": srv.password
                })]
            } else {
                active_clients
                    .iter()
                    .map(|c| {
                        json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "password": if c.password.is_empty() { &srv.password } else { &c.password }
                        })
                    })
                    .collect()
            };
            let mut obj = json!({
                "type": "hysteria2",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": users,
            });
            if srv.hysteria2_up_mbps > 0 {
                obj["up_mbps"] = json!(srv.hysteria2_up_mbps);
            }
            if srv.hysteria2_down_mbps > 0 {
                obj["down_mbps"] = json!(srv.hysteria2_down_mbps);
            }
            if !srv.hysteria2_obfs_type.is_empty() && !srv.hysteria2_obfs_password.is_empty() {
                obj["obfs"] = json!({
                    "type": srv.hysteria2_obfs_type,
                    "password": srv.hysteria2_obfs_password
                });
            }
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "tuic" => {
            let users: Vec<Value> = if active_clients.is_empty() {
                vec![json!({
                    "name": srv.label,
                    "uuid": srv.server_uuid,
                    "password": srv.password
                })]
            } else {
                active_clients
                    .iter()
                    .map(|c| {
                        json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "uuid": if c.uuid.is_empty() { &srv.server_uuid } else { &c.uuid },
                            "password": if c.password.is_empty() { &srv.password } else { &c.password }
                        })
                    })
                    .collect()
            };
            let mut obj = json!({
                "type": "tuic",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "congestion_control": if srv.tuic_congestion_control.is_empty() { "bbr" } else { &srv.tuic_congestion_control },
                "users": users,
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "anytls" => {
            let mut obj = json!({
                "type": "anytls",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "password": srv.password,
            });
            if !srv.anytls_padding_scheme.trim().is_empty() {
                obj["padding_scheme"] = json!(
                    srv.anytls_padding_scheme
                        .lines()
                        .map(str::trim)
                        .filter(|l| !l.is_empty())
                        .collect::<Vec<&str>>()
                );
            }
            if !active_clients.is_empty() {
                obj["users"] = json!(
                    active_clients
                        .iter()
                        .map(|c| json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "password": if c.password.is_empty() { &srv.password } else { &c.password }
                        }))
                        .collect::<Vec<Value>>()
                );
            }
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "shadowtls" => {
            let inner_tag = format!("{tag}-inner");
            let inner_port = srv.listen_port.saturating_add(15000);
            vec![
                json!({
                    "type": "shadowsocks",
                    "tag": inner_tag,
                    "listen": "127.0.0.1",
                    "listen_port": inner_port,
                    "method": "aes-128-gcm",
                    "password": srv.password
                }),
                json!({
                    "type": "shadowtls",
                    "tag": tag,
                    "listen": srv.listen,
                    "listen_port": srv.listen_port,
                    "password": srv.password,
                    "version": srv.shadowtls_version.max(3),
                    "users": [{
                        "name": srv.label,
                        "password": srv.password
                    }],
                    "handshake": {
                        "server": if srv.shadowtls_handshake_server.is_empty() { "www.microsoft.com" } else { &srv.shadowtls_handshake_server },
                        "server_port": srv.shadowtls_handshake_server_port.max(443)
                    },
                    "detour": inner_tag
                }),
            ]
        }
        "naive" => {
            let mut obj = json!({
                "type": "naive",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "username": if srv.server_username.is_empty() { &srv.label } else { &srv.server_username },
                    "password": srv.password
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "tewfai" => {
            let mut obj = json!({
                "type": "tewfai",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "uuid": if srv.tewfai_uuid.is_empty() { &srv.server_uuid } else { &srv.tewfai_uuid },
                "password": if srv.tewfai_password.is_empty() { &srv.password } else { &srv.tewfai_password },
                "quic": {
                    "enabled": true
                },
                "inner_cipher": if srv.tewfai_inner_cipher.is_empty() { "aes-256-gcm" } else { &srv.tewfai_inner_cipher },
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "wdtt" => {
            let mode_lc = srv.wdtt_mode.trim().to_ascii_lowercase();
            let mode = match mode_lc.as_str() {
                "all" | "wg" | "raw" | "csqtt" | "csqtt_v1" => mode_lc.as_str(),
                _ => "csqtt",
            };
            let mut obj = json!({
                "type": "wdtt",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "mode": mode,
            });
            let obfs = srv.wdtt_obfs.trim().to_ascii_lowercase();
            if matches!(obfs.as_str(), "audio" | "video" | "unified") {
                obj["obfs"] = json!(obfs);
            } else if srv.wdtt_obfs.trim().is_empty() {
                obj["obfs"] = json!("audio");
            }
            if !srv.password.is_empty() {
                obj["password"] = json!(srv.password);
            }
            let default_user_name = if srv.server_username.is_empty() {
                &srv.label
            } else {
                &srv.server_username
            };
            let wdtt_users: Vec<Value> = if !active_clients.is_empty() {
                active_clients
                    .iter()
                    .filter(|c| !c.password.is_empty())
                    .map(|c| {
                        json!({
                            "name": if c.name.is_empty() { &c.id } else { &c.name },
                            "password": c.password,
                        })
                    })
                    .collect()
            } else if !srv.password.is_empty() {
                vec![json!({
                    "name": default_user_name,
                    "password": srv.password,
                })]
            } else {
                Vec::new()
            };
            if !wdtt_users.is_empty() {
                obj["users"] = Value::Array(wdtt_users);
            } else if srv.password.is_empty() {
                return Vec::new();
            }
            if srv.wdtt_raw_port > 0 {
                obj["raw_port"] = json!(srv.wdtt_raw_port);
            }
            let network = if srv.wdtt_network.trim().is_empty() {
                "10.66.0.1/16"
            } else {
                srv.wdtt_network.trim()
            };
            obj["network"] = json!(network);
            if !srv.wdtt_ipv4_pool.trim().is_empty() {
                obj["ipv4_pool"] = json!(srv.wdtt_ipv4_pool.trim());
            }
            if !srv.wdtt_raw_ipv4_pool.trim().is_empty() {
                obj["raw_ipv4_pool"] = json!(srv.wdtt_raw_ipv4_pool.trim());
            }
            if !srv.wdtt_client_dns.trim().is_empty() {
                obj["client_dns"] = json!(srv.wdtt_client_dns.trim());
            }
            if (576..=1500).contains(&srv.wdtt_mtu) {
                obj["mtu"] = json!(srv.wdtt_mtu);
            }
            vec![obj]
        }
        "mieru" => vec![json!({
            "type": "mieru",
            "tag": tag,
            "listen": srv.listen,
            "listen_port": srv.listen_port,
            "users": [{
                "name": if srv.server_username.is_empty() { &srv.label } else { &srv.server_username },
                "password": srv.password
            }],
            "transport": if srv.mieru_transport.is_empty() { "TCP" } else { &srv.mieru_transport },
            "listen_ports": [if srv.listen_port_range.is_empty() {
                format!("{}-{}", srv.listen_port, srv.listen_port.saturating_add(10))
            } else {
                srv.listen_port_range.clone()
            }]
        })],
        "fptn" | "trusttunnel" | "snell" => {
            let mut obj = json!({
                "type": srv.protocol,
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "username": if srv.server_username.is_empty() { &srv.label } else { &srv.server_username },
                    "password": srv.password
                }],
            });
            if srv.protocol == "trusttunnel" && srv.trusttunnel_quic {
                obj["quic"] = json!(true);
            }
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "masque" => {
            let mut obj = json!({
                "type": "masque",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "username": if srv.server_username.is_empty() { &srv.label } else { &srv.server_username },
                    "password": srv.password
                }],
                "ipv4_pool": [if srv.masque_ipv4_pool.is_empty() { "172.16.0.0/24" } else { &srv.masque_ipv4_pool }],
                "mtu": srv.masque_mtu.max(1400),
            });
            if !srv.masque_ipv6_pool.is_empty() {
                obj["ipv6_pool"] = json!([srv.masque_ipv6_pool]);
            }
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "openconnect" => {
            let mut obj = json!({
                "type": "openconnect",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "flavor": if srv.openconnect_flavor.is_empty() { "anyconnect" } else { &srv.openconnect_flavor },
                "cookie": if srv.openconnect_cookie.is_empty() { &srv.password } else { &srv.openconnect_cookie },
                "address": if srv.openconnect_address.is_empty() { "172.16.1.2/24" } else { &srv.openconnect_address },
                "mtu": srv.openconnect_mtu.max(1400),
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            vec![obj]
        }
        "mtproto" => {
            let raw_secret = srv.mtproto_secret.trim().to_ascii_lowercase();
            let secret = if raw_secret.is_empty() {
                "daa0dc1ef3940ec586aa54e73b045fd1".to_string()
            } else if raw_secret.len() >= 34
                && (raw_secret.starts_with("ee") || raw_secret.starts_with("dd"))
            {
                raw_secret[2..34].to_string()
            } else {
                raw_secret
            };
            vec![json!({
                "type": "mtproto",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "name": srv.label,
                    "secret": secret
                }]
            })]
        }
        "mixed" | "socks" | "http" => {
            let mut obj = json!({
                "type": srv.protocol,
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port
            });
            if srv.socks_auth_enabled
                && (!srv.server_username.is_empty() || !srv.password.is_empty())
            {
                obj["users"] = json!([{
                    "username": srv.server_username,
                    "password": srv.password
                }]);
            }
            vec![obj]
        }
        _ => Vec::new(),
    }
}

/// Build a shareable client URI for a router-hosted `InboundServer`.
pub fn build_server_share_uri(srv: &InboundServer, host_override: Option<&str>) -> String {
    let host = host_override
        .filter(|h| !h.trim().is_empty())
        .map(|h| h.split(':').next().unwrap_or(h))
        .unwrap_or_else(|| {
            if srv.public_host.is_empty() {
                "192.168.1.205"
            } else {
                &srv.public_host
            }
        });
    let port = srv.listen_port;
    let label = &srv.label;
    let sni = if srv.tls_server_name.is_empty() {
        host
    } else {
        &srv.tls_server_name
    };
    let user_or_label = if srv.server_username.is_empty() {
        label.as_str()
    } else {
        &srv.server_username
    };

    match srv.protocol.as_str() {
        "vless" => {
            if srv.security == "reality" {
                let flow_q = if srv.vless_flow.is_empty() || srv.vless_flow == "none" {
                    String::new()
                } else {
                    format!("&flow={}", srv.vless_flow)
                };
                format!(
                    "vless://{}@{host}:{port}?encryption=none&security=reality&sni={sni}&fp={}&pbk={}&sid={}{flow_q}&type={}#{label}",
                    srv.server_uuid,
                    if srv.client_fingerprint.is_empty() {
                        "chrome"
                    } else {
                        &srv.client_fingerprint
                    },
                    srv.reality_public_key,
                    srv.reality_short_id,
                    if srv.transport.is_empty() {
                        "tcp"
                    } else {
                        &srv.transport
                    }
                )
            } else {
                format!(
                    "vless://{}@{host}:{port}?encryption=none&security=tls&sni={sni}&insecure=1&type={}#{label}",
                    srv.server_uuid,
                    if srv.transport.is_empty() {
                        "tcp"
                    } else {
                        &srv.transport
                    }
                )
            }
        }
        "vmess" => {
            let v = json!({
                "v": "2",
                "ps": label,
                "add": host,
                "port": port.to_string(),
                "id": srv.server_uuid,
                "aid": srv.vmess_alter_id.to_string(),
                "scy": "auto",
                "net": if srv.transport.is_empty() { "tcp" } else { &srv.transport },
                "type": "none",
                "host": sni,
                "tls": if srv.security == "tls" { "tls" } else { "" },
                "sni": sni
            });
            format!("vmess://{}", B64_STD.encode(v.to_string().as_bytes()))
        }
        "trojan" => {
            format!(
                "trojan://{}@{host}:{port}?security=tls&sni={sni}&insecure=1#{label}",
                srv.password
            )
        }
        "shadowsocks" | "ss" => {
            let method = if srv.method.is_empty() {
                "aes-128-gcm"
            } else {
                &srv.method
            };
            let user_b64 = B64_URL.encode(format!("{method}:{}", srv.password));
            format!("ss://{user_b64}@{host}:{port}#{label}")
        }
        "hysteria2" => {
            let obfs_q =
                if !srv.hysteria2_obfs_type.is_empty() && !srv.hysteria2_obfs_password.is_empty() {
                    format!(
                        "&obfs={}&obfs-password={}",
                        srv.hysteria2_obfs_type, srv.hysteria2_obfs_password
                    )
                } else {
                    String::new()
                };
            format!(
                "hysteria2://{}@{host}:{port}?sni={sni}&insecure=1{obfs_q}#{label}",
                srv.password
            )
        }
        "tuic" => {
            format!(
                "tuic://{}:{}@{host}:{port}?congestion_control={}&alpn=h3&sni={sni}&allow_insecure=1#{label}",
                srv.server_uuid,
                srv.password,
                if srv.tuic_congestion_control.is_empty() {
                    "bbr"
                } else {
                    &srv.tuic_congestion_control
                }
            )
        }
        "anytls" => {
            format!(
                "anytls://{}@{host}:{port}?sni={sni}&insecure=1#{label}",
                srv.password
            )
        }
        "shadowtls" => {
            let handshake_sni = if srv.shadowtls_handshake_server.is_empty() {
                sni
            } else {
                &srv.shadowtls_handshake_server
            };
            format!(
                "shadowtls://{}@{host}:{port}?version={}&sni={handshake_sni}#{label}",
                srv.password,
                srv.shadowtls_version.max(3)
            )
        }
        "naive" => {
            format!(
                "naive+https://{user_or_label}:{}@{host}:{port}#{label}",
                srv.password
            )
        }
        "mieru" => {
            let tr_raw = srv.mieru_transport.trim();
            let transport = if tr_raw.eq_ignore_ascii_case("UDP") {
                "UDP"
            } else {
                "TCP"
            };
            let mut port_specs: Vec<String> = Vec::new();
            if !srv.listen_port_range.trim().is_empty() {
                for tok in srv
                    .listen_port_range
                    .split(|c: char| c == ',' || c.is_whitespace())
                {
                    let norm = tok.trim().replace(':', "-");
                    if !norm.is_empty() {
                        port_specs.push(norm);
                    }
                }
            }
            let mut ob = Map::new();
            ob.insert("type".into(), json!("mieru"));
            ob.insert("tag".into(), json!(label));
            ob.insert("server".into(), json!(host));
            ob.insert("username".into(), json!(user_or_label));
            ob.insert("password".into(), json!(srv.password));
            ob.insert("transport".into(), json!(transport));
            if !port_specs.is_empty() {
                ob.insert("server_ports".into(), json!(port_specs));
            } else if port > 0 {
                ob.insert("server_port".into(), json!(port));
            }
            serialize_mieru_outbound(&Value::Object(ob)).unwrap_or_else(|| {
                let uri_host = format_uri_host_only(host);
                format!(
                    "mierus://{}:{}@{uri_host}?protocol={transport}#{label}",
                    url_encode_component(user_or_label),
                    url_encode_component(&srv.password),
                )
            })
        }
        "fptn" => {
            format!(
                "fptn://{user_or_label}:{}@{host}:{port}?sni={sni}#{label}",
                srv.password
            )
        }
        "trusttunnel" => {
            let quic_q = if srv.trusttunnel_quic { "&quic=1" } else { "" };
            format!(
                "trusttunnel://{user_or_label}:{}@{host}:{port}?sni={sni}{quic_q}#{label}",
                srv.password
            )
        }
        "snell" => {
            format!("snell://{}@{host}:{port}?version=4#{label}", srv.password)
        }
        "masque" => {
            format!(
                "masque://{user_or_label}:{}@{host}:{port}?sni={sni}&mtu={}#{label}",
                srv.password,
                srv.masque_mtu.max(1400)
            )
        }
        "openconnect" => {
            let flavor = if srv.openconnect_flavor.is_empty() {
                "anyconnect"
            } else {
                &srv.openconnect_flavor
            };
            let cookie = if srv.openconnect_cookie.is_empty() {
                &srv.password
            } else {
                &srv.openconnect_cookie
            };
            format!("openconnect://{cookie}@{host}:{port}?flavor={flavor}&sni={sni}#{label}")
        }
        "tailscale" => {
            let ctrl = if srv.tailscale_control_url.is_empty() {
                "https://controlplane.tailscale.com"
            } else {
                &srv.tailscale_control_url
            };
            format!(
                "tailscale://{}@{}:{}?control_url={ctrl}#{label}",
                srv.tailscale_auth_key,
                if srv.tailscale_hostname.is_empty() {
                    host
                } else {
                    &srv.tailscale_hostname
                },
                port.max(41641)
            )
        }
        "tewfai" => {
            let uuid = if srv.tewfai_uuid.is_empty() {
                &srv.server_uuid
            } else {
                &srv.tewfai_uuid
            };
            let pw = if srv.tewfai_password.is_empty() {
                &srv.password
            } else {
                &srv.tewfai_password
            };
            format!(
                "tewfai://{uuid}:{pw}@{host}:{port}?transport={}&cipher={}&morph={}&sni={sni}#{label}",
                if srv.tewfai_inbound_transport.is_empty() {
                    "quic"
                } else {
                    &srv.tewfai_inbound_transport
                },
                if srv.tewfai_inner_cipher.is_empty() {
                    "aes-256-gcm"
                } else {
                    &srv.tewfai_inner_cipher
                },
                if srv.tewfai_morph_profile.is_empty() {
                    "auto"
                } else {
                    &srv.tewfai_morph_profile
                }
            )
        }
        "wdtt" => {
            let pw = if !srv.password.is_empty() {
                srv.password.as_str()
            } else {
                srv.clients
                    .iter()
                    .find(|c| c.enabled && !c.password.is_empty())
                    .map(|c| c.password.as_str())
                    .unwrap_or("")
            };
            if pw.is_empty() {
                return String::new();
            }
            let mode = match srv.wdtt_mode.trim().to_ascii_lowercase().as_str() {
                "wg" | "raw" | "csqtt" | "csqtt_v1" => srv.wdtt_mode.trim().to_ascii_lowercase(),
                _ => "csqtt".to_string(),
            };
            let obfs = match srv.wdtt_obfs.trim().to_ascii_lowercase().as_str() {
                "audio" | "video" | "unified" => srv.wdtt_obfs.trim().to_ascii_lowercase(),
                _ if srv.wdtt_obfs.trim().is_empty() => "audio".to_string(),
                _ => String::new(),
            };
            let encoded_label = url_encode_component(label);
            if mode == "wg" || mode == "raw" {
                let mut payload = json!({
                    "v": 1,
                    "ip": host,
                    "dtls": port,
                    "pass": pw,
                    "vpn": mode,
                });
                if srv.wdtt_raw_port > 0 {
                    payload["raw"] = json!(srv.wdtt_raw_port);
                }
                if !obfs.is_empty() && obfs != "audio" {
                    payload["obfs"] = json!(obfs);
                }
                format!(
                    "wdtt://{}#{encoded_label}",
                    B64_URL.encode(payload.to_string().as_bytes())
                )
            } else {
                let is_v1 = mode == "csqtt_v1";
                let mut uri = format!(
                    "csqtt://connect?v={}&host={}&peer={port}&password={}",
                    if is_v1 { "1" } else { "2" },
                    url_encode_component(host),
                    url_encode_component(pw)
                );
                if is_v1 {
                    uri.push_str("&mode=csqtt_v1");
                }
                if !obfs.is_empty() {
                    uri.push_str("&obfs=");
                    uri.push_str(&obfs);
                }
                uri.push('#');
                uri.push_str(&encoded_label);
                uri
            }
        }
        "awg" | "wireguard" => {
            let mut extra = String::new();
            if srv.awg_s3 > 0 {
                extra.push_str(&format!("&s3={}", srv.awg_s3));
            }
            if srv.awg_s4 > 0 {
                extra.push_str(&format!("&s4={}", srv.awg_s4));
            }
            for (k, v) in [
                ("i1", &srv.awg_i1),
                ("i2", &srv.awg_i2),
                ("i3", &srv.awg_i3),
                ("i4", &srv.awg_i4),
                ("i5", &srv.awg_i5),
            ] {
                if !v.trim().is_empty() {
                    extra.push_str(&format!("&{k}={}", v.trim()));
                }
            }
            format!(
                "awg://{}@{host}:{port}?publickey={}&address={}&jc={}&jmin={}&jmax={}&s1={}&s2={}&h1={}&h2={}&h3={}&h4={}{extra}#{label}",
                srv.awg_client_private_key,
                srv.awg_server_public_key,
                if srv.awg_client_address.is_empty() {
                    "10.8.0.2/32"
                } else {
                    &srv.awg_client_address
                },
                srv.awg_jc,
                srv.awg_jmin,
                srv.awg_jmax,
                srv.awg_s1,
                srv.awg_s2,
                srv.awg_h1,
                srv.awg_h2,
                srv.awg_h3,
                srv.awg_h4
            )
        }
        "mtproto" => {
            format!(
                "tg://proxy?server={host}&port={port}&secret={}",
                srv.mtproto_secret
            )
        }
        "socks" => {
            if srv.server_username.is_empty() {
                format!("socks5://{host}:{port}#{label}")
            } else {
                format!(
                    "socks5://{}:{}@{host}:{port}#{label}",
                    srv.server_username, srv.password
                )
            }
        }
        "http" | "mixed" => {
            if srv.server_username.is_empty() {
                format!("http://{host}:{port}#{label}")
            } else {
                format!(
                    "http://{}:{}@{host}:{port}#{label}",
                    srv.server_username, srv.password
                )
            }
        }
        _ => format!(
            "{}://{user_or_label}:{}@{host}:{port}#{label}",
            srv.protocol, srv.password
        ),
    }
}

/// Build an AmneziaWG / WireGuard `.conf` file for a router-hosted `InboundServer`.
pub fn build_server_wg_conf(srv: &InboundServer, host_override: Option<&str>) -> String {
    let host = host_override
        .filter(|h| !h.trim().is_empty())
        .map(|h| h.split(':').next().unwrap_or(h))
        .unwrap_or_else(|| {
            if srv.public_host.is_empty() {
                "192.168.1.205"
            } else {
                &srv.public_host
            }
        });
    let mut lines = vec![
        "[Interface]".to_string(),
        format!("PrivateKey = {}", srv.awg_client_private_key),
        format!(
            "Address = {}",
            if srv.awg_client_address.is_empty() {
                "10.8.0.2/32"
            } else {
                &srv.awg_client_address
            }
        ),
        format!(
            "DNS = {}",
            if srv.awg_dns.is_empty() {
                "1.1.1.1"
            } else {
                &srv.awg_dns
            }
        ),
        format!("MTU = {}", srv.awg_mtu.max(1280)),
    ];
    if srv.protocol == "awg" && srv.awg_jc > 0 {
        lines.push(format!("Jc = {}", srv.awg_jc));
        lines.push(format!("Jmin = {}", srv.awg_jmin));
        lines.push(format!("Jmax = {}", srv.awg_jmax));
        lines.push(format!("S1 = {}", srv.awg_s1));
        lines.push(format!("S2 = {}", srv.awg_s2));
        if srv.awg_s3 > 0 {
            lines.push(format!("S3 = {}", srv.awg_s3));
        }
        if srv.awg_s4 > 0 {
            lines.push(format!("S4 = {}", srv.awg_s4));
        }
        lines.push(format!("H1 = {}", srv.awg_h1));
        lines.push(format!("H2 = {}", srv.awg_h2));
        lines.push(format!("H3 = {}", srv.awg_h3));
        lines.push(format!("H4 = {}", srv.awg_h4));
        for (k, v) in [
            ("I1", &srv.awg_i1),
            ("I2", &srv.awg_i2),
            ("I3", &srv.awg_i3),
            ("I4", &srv.awg_i4),
            ("I5", &srv.awg_i5),
            ("J1", &srv.awg_j1),
            ("J2", &srv.awg_j2),
            ("J3", &srv.awg_j3),
        ] {
            if !v.trim().is_empty() {
                lines.push(format!("{k} = {}", v.trim()));
            }
        }
        if srv.awg_itime > 0 {
            lines.push(format!("ITime = {}", srv.awg_itime));
        }
    }
    lines.push(String::new());
    lines.push("[Peer]".to_string());
    lines.push(format!("PublicKey = {}", srv.awg_server_public_key));
    if !srv.awg_preshared_key.is_empty() {
        lines.push(format!("PresharedKey = {}", srv.awg_preshared_key));
    }
    lines.push(format!("Endpoint = {host}:{}", srv.listen_port));
    lines.push("AllowedIPs = 0.0.0.0/0, ::/0".to_string());
    lines.push(format!(
        "PersistentKeepalive = {}",
        srv.awg_keepalive.max(25)
    ));
    lines.join("\n")
}

/// Build the router's universal subscription payload (`/sub/:token`) across all enabled `InboundServer`s.
/// Supports formats/apps: `raw`/`plain`, `base64`, `happ`, `v2rayng`, `streisand`, `hiddify`, `clash`, `tachyon`, `json`, `amnezia`, `wireguard`.
pub fn build_router_subscription_payload(
    store: &RouterStoreData,
    host_override: Option<&str>,
    format: &str,
) -> String {
    let fmt = format.trim().to_ascii_lowercase();
    let enabled_servers: Vec<&InboundServer> = store.servers.iter().filter(|s| s.enabled).collect();

    if matches!(fmt.as_str(), "wireguard" | "amnezia" | "conf" | "wg")
        && let Some(wg_srv) = enabled_servers
            .iter()
            .find(|s| s.protocol == "awg" || s.protocol == "wireguard")
            .or_else(|| enabled_servers.first())
    {
        return build_server_wg_conf(wg_srv, host_override);
    }

    let uris: Vec<String> = enabled_servers
        .iter()
        .map(|s| build_server_share_uri(s, host_override))
        .collect();

    if fmt == "clash" || fmt == "yaml" {
        let mut yaml = String::from(
            "mixed-port: 7890\nallow-lan: true\nmode: rule\nlog-level: info\nproxies:\n",
        );
        let mut names = Vec::new();
        for (i, u) in uris.iter().enumerate() {
            if let Some(node) = parse_proxy_uri(u, i) {
                names.push(format!("  - \"{}\"", node.tag.replace('"', "")));
                yaml.push_str(&format!(
                    "  - name: \"{}\"\n    type: {}\n    server: {}\n    port: {}\n    udp: true\n",
                    node.tag.replace('"', ""),
                    node.protocol,
                    node.server,
                    node.server_port
                ));
            }
        }
        yaml.push_str(
            "proxy-groups:\n  - name: \"Tachyon Router\"\n    type: select\n    proxies:\n",
        );
        for n in names {
            yaml.push_str(&format!("    {n}\n"));
        }
        yaml.push_str("rules:\n  - MATCH,Tachyon Router\n");
        return yaml;
    }

    if fmt == "json" || fmt == "tachyon" || fmt == "hiddify" {
        let mut outs = Vec::new();
        let mut tags = Vec::new();
        for (i, u) in uris.iter().enumerate() {
            if let Some(node) = parse_proxy_uri(u, i) {
                tags.push(node.tag);
                outs.push(node.outbound_json);
            }
        }
        outs.insert(
            0,
            json!({
                "type": "selector",
                "tag": "proxy",
                "outbounds": tags
            }),
        );
        outs.push(json!({"type": "direct", "tag": "direct"}));
        return serde_json::to_string_pretty(&json!({
            "outbounds": outs,
            "route": { "final": "proxy" }
        }))
        .unwrap_or_default();
    }

    let plain = uris.join("\n");
    if fmt == "plain" || fmt == "raw" {
        plain
    } else {
        B64_STD.encode(plain.as_bytes())
    }
}

fn format_schedule_time_window(days: &[String], start: &str, end: &str) -> String {
    let range = format!("{start}-{end}");
    if days.is_empty() {
        return range;
    }
    let short_days: Vec<&str> = days
        .iter()
        .map(|d| match d.to_ascii_lowercase().as_str() {
            "monday" | "mon" => "mon",
            "tuesday" | "tue" => "tue",
            "wednesday" | "wed" => "wed",
            "thursday" | "thu" => "thu",
            "friday" | "fri" => "fri",
            "saturday" | "sat" => "sat",
            "sunday" | "sun" => "sun",
            _ => "mon",
        })
        .collect();
    format!("{} {}", short_days.join(","), range)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_vless_and_awg_uris() {
        let vless = "vless://11111111-2222-3333-4444-555555555555@198.51.100.10:443?security=reality&sni=www.microsoft.com&pbk=PUBKEY123&sid=5a&type=xhttp&path=%2Fapi#NL%20Fast";
        let node = parse_proxy_uri(vless, 0).expect("valid vless");
        assert_eq!(node.tag, "NL Fast");
        assert_eq!(node.country, "NL");
        assert_eq!(node.outbound_json["type"], "vless");
        assert_eq!(node.outbound_json["transport"]["type"], "xhttp");

        let awg = "awg://PRIVKEY@198.51.100.20:51820?publickey=PUBKEY&server_ports=51820,51821&hop_interval=30s&jc=4&jmin=40&jmax=70#DE-AWG";
        let awg_node = parse_proxy_uri(awg, 1).expect("valid awg");
        assert_eq!(awg_node.outbound_json["type"], "wireguard");
        assert_eq!(awg_node.outbound_json["hop_interval"], "30s");
        assert_eq!(awg_node.outbound_json["jc"], 4);
    }

    #[test]
    fn test_detect_country_code_from_emoji_and_russian() {
        assert_eq!(detect_country_code("🇳🇱 Нидерланды 1 NovoServe"), "NL");
        assert_eq!(detect_country_code("🇫🇮 Финляндия Hetzner"), "FI");
        assert_eq!(detect_country_code("🇸🇪 Швеция Cherry"), "SE");
        assert_eq!(detect_country_code("🇪🇪 Эстония ExpressHost"), "EE");
        assert_eq!(detect_country_code("🇰🇷 Южная Корея Alibaba"), "KR");
        assert_eq!(detect_country_code("🇯🇵 Япония Evoxt"), "JP");
    }

    #[test]
    fn test_compile_core_config_with_section_scoped_balancer_and_trs() {
        let mut store = RouterStoreData::default();
        store.sections[0].balancer_refs = vec!["bal_fastest".to_string()];
        store.sections[0].mixed_proxy_enabled = true;
        store.sections[0].mixed_proxy_port = 1085;
        store.sections[0].exclude_domains = vec!["sberbank.ru".to_string()];
        store.sections[0].excluded_ips = vec!["192.168.1.250".to_string()];
        store.sections[0].server_domain_rules =
            vec!["src-src_native_desync=netflix.com, fast.com".to_string()];
        let cfg = compile_core_config(&store).expect("compile core config");
        assert_eq!(cfg["route"]["default_domain_resolver"], "dns-bootstrap");
        let inbounds = cfg["inbounds"].as_array().unwrap();
        assert!(
            inbounds
                .iter()
                .any(|i| i["tag"] == "mixed-sec-sec_media_desync" && i["listen_port"] == 1085)
        );
        let rules = cfg["route"]["rules"].as_array().unwrap();
        assert!(
            rules
                .iter()
                .any(|r| r["inbound"] == json!(["mixed-sec-sec_media_desync"]))
        );
        assert!(
            rules
                .iter()
                .any(|r| r["domain_suffix"] == json!(["netflix.com", "fast.com"])
                    && r["outbound"] == "src-src_native_desync")
        );
        let outbounds = cfg["outbounds"].as_array().unwrap();
        assert!(
            outbounds
                .iter()
                .any(|o| o["type"] == "desync" && o["preset"] == "auto")
        );
        assert!(
            outbounds
                .iter()
                .any(|o| o["tag"] == "bal-sec_media_desync-bal_fastest")
        );
        let rule_sets = cfg["route"]["rule_set"].as_array().unwrap();
        assert!(
            rule_sets.iter().any(|rs| rs["tag"] == "trs-youtube"
                && rs["url"].as_str().unwrap().ends_with("youtube.trs"))
        );
    }

    #[test]
    fn test_all_14_balancer_modes_and_nested_section_refs() {
        let mut store = RouterStoreData::default();
        let modes = [
            "least_test",
            "random",
            "least_connections",
            "priority",
            "stability",
            "sticky",
            "least_load",
            "weighted",
            "passive",
            "hedged",
            "throughput",
            "quota",
            "round_robin",
            "failover",
        ];
        store.balancers.clear();
        for m in modes {
            store.balancers.push(BalancerConfig {
                id: format!("bal_{m}"),
                enabled: true,
                name: format!("Bal {m}"),
                mode: m.to_string(),
                fallback_section: "direct".to_string(),
                quota_mib: 512,
                sticky_hash: "src_dst".to_string(),
                ..Default::default()
            });
        }
        // Create cyclic nested section_refs to verify cycle protection and group selector synthesis
        store.sections[0].balancer_refs = modes.iter().map(|m| format!("bal_{m}")).collect();
        let child_ids: Vec<String> = store
            .sections
            .iter()
            .take(2)
            .map(|s| s.id.clone())
            .chain(std::iter::once("sec_parent".to_string()))
            .collect();
        store.sections.push(RoutingSection {
            id: "sec_parent".to_string(),
            enabled: true,
            label: "Parent Group".to_string(),
            connection_type: "group".to_string(),
            section_refs: child_ids,
            user_domains: vec!["example.org".to_string()],
            ..Default::default()
        });
        let cfg = compile_core_config(&store).expect("compile core config with 14 balancers");
        let outbounds = cfg["outbounds"].as_array().unwrap();
        for m in modes {
            let tag = format!("bal-{}-bal_{m}", store.sections[0].id);
            let found = outbounds
                .iter()
                .find(|o| o["tag"] == tag)
                .unwrap_or_else(|| panic!("missing balancer outbound {tag}"));
            assert!(
                found["outbounds"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|x| x == "direct"),
                "fallback outbound 'direct' missing on {tag}"
            );
            assert!(found.get("passive_check").is_none());
            assert!(found.get("fallback_outbound").is_none());
            if m == "sticky" {
                assert_eq!(
                    found["balancer"]["sticky_hash"],
                    json!(["source_ip", "dest_ip"])
                );
            }
            if m == "quota" {
                assert_eq!(found["balancer"]["quota_mib"], json!(512));
            }
        }
        assert!(outbounds.iter().any(|o| o["tag"] == "sel-sec_parent"));
    }

    #[test]
    fn test_parental_categories_safesearch_and_time_window_conditions() {
        let mut store = RouterStoreData::default();
        store.profiles.push(crate::store::ParentalProfile {
            id: "kid1".to_string(),
            enabled: true,
            label: "Kid".to_string(),
            device_ips: vec!["192.168.1.55".to_string()],
            safe_search: true,
            block_doh: true,
            blocked_categories: vec![
                "adult".to_string(),
                "gaming".to_string(),
                "social".to_string(),
            ],
            ..Default::default()
        });
        store.conditions.push(TrafficCondition {
            id: "cond_night".to_string(),
            enabled: true,
            name: "Night Window".to_string(),
            user_domains: vec!["twitch.tv".to_string()],
            time_window: "mon,tue 22:00-07:00".to_string(),
            ..Default::default()
        });
        store.conditions.push(TrafficCondition {
            id: "cond_composite".to_string(),
            enabled: true,
            name: "Composite".to_string(),
            condition_type: "all".to_string(),
            children: vec!["cond_night".to_string()],
            ..Default::default()
        });
        store.sections[0].condition_refs = vec!["cond_composite".to_string()];

        let cfg = compile_core_config(&store).expect("compile parental & condition config");
        let dns_servers = cfg["dns"]["servers"].as_array().unwrap();
        assert!(dns_servers.iter().any(|s| s["tag"] == "dns-safesearch"));
        let rules = cfg["route"]["rules"].as_array().unwrap();
        assert!(
            rules
                .iter()
                .any(|r| r["type"] == "logical" && r["mode"] == "and")
        );
        let serialized = serde_json::to_string(&cfg["route"]["rules"]).unwrap();
        assert!(serialized.contains("mon,tue 22:00-07:00"));
        assert!(serialized.contains("roblox.com"));
    }

    #[test]
    fn test_inbound_client_quota_filter_and_share_uris() {
        let srv = InboundServer {
            id: "srv_vless".to_string(),
            enabled: true,
            label: "MainVLESS".to_string(),
            protocol: "vless".to_string(),
            listen: "0.0.0.0".to_string(),
            listen_port: 8443,
            security: "reality".to_string(),
            server_uuid: "11111111-2222-3333-4444-555555555555".to_string(),
            reality_private_key: "PRIV".to_string(),
            reality_public_key: "PUB".to_string(),
            reality_short_id: "a1b2".to_string(),
            clients: vec![
                InboundClient {
                    id: "c_ok".to_string(),
                    name: "ActiveUser".to_string(),
                    enabled: true,
                    uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_string(),
                    total_limit_bytes: 1_000_000,
                    up: 100,
                    down: 200,
                    ..Default::default()
                },
                InboundClient {
                    id: "c_over".to_string(),
                    name: "OverQuota".to_string(),
                    enabled: true,
                    uuid: "ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee".to_string(),
                    total_limit_bytes: 500,
                    up: 300,
                    down: 300,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let built = build_inbound_servers(&srv);
        assert_eq!(built.len(), 1);
        let users = built[0]["users"].as_array().unwrap();
        assert_eq!(users.len(), 1);
        assert_eq!(users[0]["name"], "ActiveUser");

        let st_srv = InboundServer {
            id: "srv_st".to_string(),
            label: "Shadow".to_string(),
            protocol: "shadowtls".to_string(),
            listen_port: 9443,
            password: "pw".to_string(),
            shadowtls_handshake_server: "www.apple.com".to_string(),
            ..Default::default()
        };
        let uri = build_server_share_uri(&st_srv, Some("203.0.113.5"));
        assert!(
            uri.starts_with("shadowtls://pw@203.0.113.5:9443?version=3&sni=www.apple.com#Shadow")
        );
    }

    #[test]
    fn test_fptn_token_expansion_tailscale_exit_and_clash_api_bind() {
        let token_payload = json!({
            "version": 1,
            "service_name": "MyFPTN",
            "username": "u1",
            "password": "p1",
            "servers": [
                { "name": "DE-1", "host": "198.51.100.10", "port": 443, "md5_fingerprint": "0123456789abcdef0123456789abcdef" },
                { "name": "NL-1", "host": "198.51.100.20", "port": 8443 }
            ]
        });
        let raw_b64 = B64_STD.encode(serde_json::to_vec(&token_payload).unwrap());
        let fptn_token = format!("fptn://{raw_b64}");

        let expanded = expand_fptn_token_outbounds(
            "fptn-main",
            &fptn_token,
            "sni.example.com",
            "obfs",
            "NL-1",
        );
        assert_eq!(expanded.len(), 2);
        assert_eq!(expanded[0].0, "fptn-main/NL-1");
        assert_eq!(expanded[0].1["server"], "198.51.100.20");
        assert_eq!(expanded[0].1["sni"], "sni.example.com");
        assert_eq!(expanded[1].0, "fptn-main/DE-1");

        let mut store = RouterStoreData::default();
        store.outbound_sources.push(OutboundSource {
            id: "src_fptn".to_string(),
            enabled: true,
            source_type: "fptn".to_string(),
            fptn_access_token: fptn_token,
            ..Default::default()
        });
        store.outbound_sources.push(OutboundSource {
            id: "src_ts".to_string(),
            enabled: true,
            source_type: "tailscale".to_string(),
            tailscale_auth_key: "tskey-auth-123".to_string(),
            tailscale_use_exit_node: "100.64.0.9".to_string(),
            tailscale_accept_routes: true,
            ..Default::default()
        });

        let ips = extract_fptn_server_ips(&store);
        assert_eq!(ips, vec!["198.51.100.10", "198.51.100.20"]);

        store.settings.enable_yacd = false;
        store.settings.enable_yacd_wan_access = false;
        let cfg1 = compile_core_config(&store).unwrap();
        assert_eq!(
            cfg1["experimental"]["clash_api"]["external_controller"],
            "127.0.0.1:9090"
        );
        let outs = cfg1["outbounds"].as_array().unwrap();
        assert!(
            !outs.iter().any(|o| o["tag"] == "tailscale-src_ts"),
            "Tailscale client must not be emitted in outbounds"
        );
        let eps = cfg1["endpoints"].as_array().unwrap();
        let ts_ep = eps
            .iter()
            .find(|e| e["tag"] == "tailscale-src_ts")
            .expect("tailscale endpoint present in endpoints");
        assert_eq!(ts_ep["exit_node"], "100.64.0.9");
        assert_eq!(ts_ep["accept_routes"], true);
        assert!(ts_ep.get("use_exit_node").is_none());
        assert!(ts_ep.get("accept_dns").is_none());

        store.settings.enable_yacd = true;
        store.settings.yacd_secret_key = "custom-yacd-sec".to_string();
        let cfg2 = compile_core_config(&store).unwrap();
        assert_eq!(
            cfg2["experimental"]["clash_api"]["external_controller"],
            "0.0.0.0:9090"
        );
        assert_eq!(cfg2["experimental"]["clash_api"]["external_ui"], "ui");
        assert_eq!(
            cfg2["experimental"]["clash_api"]["secret"],
            "custom-yacd-sec"
        );
    }

    #[test]
    fn test_mtproto_inbound_matches_tachyon_core_schema() {
        let srv = InboundServer {
            id: "mtproto1".to_string(),
            label: "MtProto".to_string(),
            enabled: true,
            protocol: "mtproto".to_string(),
            listen: "0.0.0.0".to_string(),
            listen_port: 8457,
            mtproto_secret: "EEdaa0dc1ef3940ec586aa54e73b045fd1676f6f676c652e636f6d".to_string(),
            mtproto_faketls: "google.com".to_string(),
            mtproto_adtag: "adtag123".to_string(),
            mtproto_padding: true,
            mtproto_telegram_ws: true,
            mtproto_concurrency: 4,
            ..Default::default()
        };

        let inbounds = build_inbound_servers(&srv);
        assert_eq!(inbounds.len(), 1);
        let ib = &inbounds[0];
        assert_eq!(ib["type"], "mtproto");
        assert_eq!(ib["users"][0]["secret"], "daa0dc1ef3940ec586aa54e73b045fd1");
        assert!(ib.get("faketls_domain").is_none());
        assert!(ib.get("adtag").is_none());
        assert!(ib.get("padding").is_none());
        assert!(ib.get("telegram_ws").is_none());
        assert!(ib.get("concurrency").is_none());
    }

    #[test]
    fn test_wdtt_csqtt_uri_parsing_and_strict_outbound_schema() {
        let uris = [
            "csqtt://connect?v=2&host=203.0.113.10&peer=46000&password=sec123&obfs=video&hashes=aa11+bb22&workers=4&mtu=1360&chunk1=1#CSQTT-V2".to_string(),
            "csqtt://connect?v=2host=203.0.113.11peer=203.0.113.11:46001password=sec456mode=csqtt_v1".to_string(),
            "qwdtt://config?ip=203.0.113.12&dtls=56000&hashes=cc33,dd44&pass=p+a+s+s#QWDTT".to_string(),
            format!(
                "wdtt://{}#B64Node",
                B64_URL.encode(
                    json!({
                        "v": 1,
                        "ip": "203.0.113.13",
                        "dtls": 56001,
                        "pass": "pw77",
                        "vpn": "wg",
                        "obfs": "unified"
                    })
                    .to_string()
                    .as_bytes()
                )
            ),
            "wdtt://203.0.113.14:56002:51820:1080:pw88:h1,h2#ColonNode".to_string(),
            "wdtt://pw99@203.0.113.15:46002?mode=raw&raw_port=47000#QueryNode".to_string(),
        ];

        let parsed: Vec<ParsedProxyNode> = uris
            .iter()
            .enumerate()
            .map(|(i, u)| parse_proxy_uri(u, i).unwrap_or_else(|| panic!("failed to parse {u}")))
            .collect();

        for node in &parsed {
            assert_eq!(node.protocol, "wdtt");
            assert_eq!(node.outbound_json["type"], "wdtt");
            assert!(node.outbound_json.get("srtp_mode").is_none());
            assert!(node.outbound_json.get("vk_token").is_none());
            assert!(node.outbound_json.get("share_link").is_none());
            assert!(node.outbound_json.get("remark").is_none());
        }

        assert_eq!(parsed[0].tag, "CSQTT-V2");
        assert_eq!(parsed[0].outbound_json["mode"], "csqtt");
        assert_eq!(parsed[0].outbound_json["obfs"], "video");
        assert_eq!(parsed[0].outbound_json["hashes"], json!(["aa11", "bb22"]));
        assert_eq!(parsed[0].outbound_json["workers"], 4);
        assert_eq!(parsed[0].outbound_json["mtu"], 1360);
        assert_eq!(parsed[0].outbound_json["chunk1"], true);

        assert_eq!(parsed[1].server, "203.0.113.11");
        assert_eq!(parsed[1].server_port, 46001);
        assert_eq!(parsed[1].outbound_json["mode"], "csqtt_v1");
        assert_eq!(parsed[1].outbound_json["password"], "sec456");

        assert_eq!(parsed[2].outbound_json["password"], "p+a+s+s");
        assert_eq!(parsed[2].outbound_json["mode"], "wg");
        assert_eq!(parsed[2].outbound_json["hashes"], json!(["cc33", "dd44"]));

        assert_eq!(parsed[3].tag, "B64Node");
        assert_eq!(parsed[3].outbound_json["mode"], "wg");
        assert_eq!(parsed[3].outbound_json["obfs"], "unified");

        assert_eq!(parsed[4].tag, "ColonNode");
        assert_eq!(parsed[4].server_port, 56002);
        assert_eq!(parsed[4].outbound_json["wg_port"], 51820);
        assert_eq!(parsed[4].outbound_json["local_port"], 1080);

        assert_eq!(parsed[5].tag, "QueryNode");
        assert_eq!(parsed[5].outbound_json["mode"], "raw");
        assert_eq!(parsed[5].outbound_json["raw_port"], 47000);
    }

    #[test]
    fn test_wdtt_inbound_and_share_uri_formats() {
        let mut srv = InboundServer {
            id: "wdtt1".to_string(),
            label: "WDTT-Srv".to_string(),
            enabled: true,
            protocol: "wdtt".to_string(),
            listen: "0.0.0.0".to_string(),
            listen_port: 46000,
            password: "srvpass".to_string(),
            wdtt_mode: "csqtt".to_string(),
            wdtt_obfs: "audio".to_string(),
            wdtt_network: "10.66.0.1/16".to_string(),
            wdtt_mtu: 1350,
            wdtt_raw_port: 46001,
            ..Default::default()
        };

        let inbounds = build_inbound_servers(&srv);
        assert_eq!(inbounds.len(), 1);
        let ib = &inbounds[0];
        assert_eq!(ib["type"], "wdtt");
        assert_eq!(ib["mode"], "csqtt");
        assert_eq!(ib["obfs"], "audio");
        assert_eq!(ib["password"], "srvpass");
        assert_eq!(ib["users"][0]["password"], "srvpass");
        assert_eq!(ib["raw_port"], 46001);
        assert_eq!(ib["network"], "10.66.0.1/16");
        assert_eq!(ib["mtu"], 1350);
        assert!(ib.get("tls").is_none());

        let csqtt_uri = build_server_share_uri(&srv, Some("198.51.100.5"));
        assert!(
            csqtt_uri
                .starts_with("csqtt://connect?v=2&host=198.51.100.5&peer=46000&password=srvpass")
        );
        let roundtrip_csqtt = parse_proxy_uri(&csqtt_uri, 0).expect("roundtrip csqtt uri");
        assert_eq!(roundtrip_csqtt.outbound_json["type"], "wdtt");
        assert_eq!(roundtrip_csqtt.outbound_json["mode"], "csqtt");

        srv.wdtt_mode = "wg".to_string();
        let wg_uri = build_server_share_uri(&srv, Some("198.51.100.5"));
        assert!(wg_uri.starts_with("wdtt://"));
        let roundtrip_wg = parse_proxy_uri(&wg_uri, 0).expect("roundtrip wdtt wg uri");
        assert_eq!(roundtrip_wg.outbound_json["type"], "wdtt");
        assert_eq!(roundtrip_wg.outbound_json["mode"], "wg");
    }

    #[test]
    fn test_dns_apple_ios_and_ipv6_disabled_rules_and_ntp_bootstrap() {
        let system_uci = r#"
config timeserver 'ntp'
	list server '0.openwrt.pool.ntp.org'
	list server '1.openwrt.pool.ntp.org'
	list server '192.168.1.1'
	list server '0.openwrt.pool.ntp.org'
"#;
        let ntp_domains = parse_system_ntp_domains(system_uci);
        assert_eq!(
            ntp_domains,
            vec![
                "0.openwrt.pool.ntp.org".to_string(),
                "1.openwrt.pool.ntp.org".to_string()
            ]
        );

        let mut store = RouterStoreData::default();
        store.settings.enable_ipv6 = false;
        store.settings.fakeip_enabled = true;
        store.settings.dns_local_cache = false;

        let cfg = compile_core_config(&store).expect("compile core config");
        let dns = &cfg["dns"];
        assert_eq!(dns["final"], "dns-remote");
        assert_eq!(dns["strategy"], "ipv4_only");
        assert_eq!(dns["reverse_mapping"], true);
        assert_eq!(dns["disable_cache"], true);

        let servers = dns["servers"].as_array().unwrap();
        let fakeip_srv = servers
            .iter()
            .find(|s| s["tag"] == "dns-fakeip")
            .expect("dns-fakeip server");
        assert!(fakeip_srv.get("inet4_range").is_some());
        assert!(fakeip_srv.get("inet6_range").is_none());

        let rules = dns["rules"].as_array().unwrap();
        assert!(rules.iter().any(|r| {
            r["query_type"] == json!(["HTTPS", "SVCB"])
                && r["action"] == "predefined"
                && r["rcode"] == "NOERROR"
        }));
        assert!(rules.iter().any(|r| {
            r["domain"] == json!(["use-application-dns.net"]) && r["action"] == "reject"
        }));
        assert!(rules.iter().any(|r| {
            r["query_type"] == json!(["AAAA"])
                && r["action"] == "predefined"
                && r["rcode"] == "NOERROR"
        }));
        let fakeip_rule = rules
            .iter()
            .find(|r| r["server"] == "dns-fakeip")
            .expect("dns-fakeip rule");
        assert_eq!(fakeip_rule["query_type"], json!(["A"]));
    }

    #[test]
    fn test_empty_filtered_outbound_group_does_not_fallback_to_unfiltered() {
        let mut store = RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_de".to_string(),
            enabled: true,
            source_type: "urls".to_string(),
            proxy_links: vec!["vless://11111111-1111-1111-1111-111111111111@203.0.113.50:443#%F0%9F%87%A9%F0%9F%87%AA%20Germany".to_string()],
            ..Default::default()
        });
        store.outbound_groups.push(crate::store::OutboundGroup {
            id: "grp_jp".to_string(),
            enabled: true,
            name: "Only JP".to_string(),
            primary_refs: vec!["src_de".to_string()],
            include_country_flags: vec!["JP".to_string()],
            ..Default::default()
        });
        store.sections.push(RoutingSection {
            id: "sec_jp_only".to_string(),
            enabled: true,
            label: "JP Only".to_string(),
            action: "proxy".to_string(),
            connection_type: "vless".to_string(),
            outbound_group_refs: vec!["grp_jp".to_string()],
            user_domains: vec!["example.jp".to_string()],
            ..Default::default()
        });

        let mut source_tag_map = HashMap::new();
        source_tag_map.insert("src_de".to_string(), vec!["🇩🇪 Germany".to_string()]);
        let grp_map = build_outbound_group_map(
            &store.outbound_groups,
            &store.outbound_sources,
            &source_tag_map,
        );
        assert_eq!(grp_map.get("grp_jp").map(Vec::as_slice), Some(&[][..]));

        let cfg = compile_core_config(&store).expect("compile core config");
        let rules = cfg["route"]["rules"].as_array().unwrap();
        let jp_rule = rules
            .iter()
            .find(|r| r["domain_suffix"] == json!(["example.jp"]));
        assert!(jp_rule.is_none_or(|r| r["outbound"] != "🇩🇪 Germany"));
    }

    #[test]
    fn test_desync_schema_new_fields_and_inline_section() {
        let mut store = RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_desync".to_string(),
            enabled: true,
            source_type: "desync".to_string(),
            desync_preset: "custom".to_string(),
            desync_mode: "hostfakesplit".to_string(),
            desync_host_fake: true,
            desync_wscale: Some(7),
            desync_fake_sni: "ozon.ru".to_string(),
            desync_sni_pool: vec!["ozon.ru".to_string(), "vk.com".to_string()],
            desync_fake_payload: "0x160301".to_string(),
            desync_fake_tls: "tls_clienthello_www_google_com.bin".to_string(),
            desync_split_pos: "1,sni".to_string(),
            desync_tlsrec_first: true,
            ..Default::default()
        });
        store.sections.push(RoutingSection {
            id: "sec_inline_desync".to_string(),
            enabled: true,
            label: "Inline Desync".to_string(),
            action: "proxy".to_string(),
            connection_type: "desync".to_string(),
            desync_preset: "custom".to_string(),
            desync_mode: "multisplit".to_string(),
            desync_host_fake: true,
            desync_wscale: Some(0),
            desync_sni_pool: vec!["ya.ru".to_string()],
            desync_fake_payload: "GET / HTTP/1.1".to_string(),
            desync_tlsrec_first: true,
            user_domains: vec!["video.example".to_string()],
            ..Default::default()
        });

        let cfg = compile_core_config(&store).expect("compile core config");
        let outbounds = cfg["outbounds"].as_array().unwrap();
        let src_ob = outbounds
            .iter()
            .find(|o| o["tag"] == "desync-src_desync")
            .expect("source desync outbound");
        assert_eq!(src_ob["mode"], "hostfakesplit");
        assert_eq!(src_ob["host_fake"], true);
        assert_eq!(src_ob["wscale"], 7);
        assert_eq!(src_ob["sni_pool"], json!(["ozon.ru", "vk.com"]));
        assert_eq!(src_ob["fake_payload"], "0x160301");
        assert_eq!(src_ob["fake_tls"], "tls_clienthello_www_google_com.bin");
        assert_eq!(src_ob["split_pos"], json!([1, "sni"]));
        assert_eq!(src_ob["tlsrec_first"], true);

        let sec_ob = outbounds
            .iter()
            .find(|o| o["tag"] == "desync-sec-sec_inline_desync")
            .expect("inline section desync outbound");
        assert_eq!(sec_ob["wscale"], 0);
        assert_eq!(sec_ob["host_fake"], true);
        assert_eq!(sec_ob["sni_pool"], json!(["ya.ru"]));
        assert_eq!(sec_ob["fake_payload"], "GET / HTTP/1.1");
        assert_eq!(sec_ob["tlsrec_first"], true);
    }

    #[test]
    fn test_xray_json_subscription_balancers_and_filters() {
        let sub_json = json!([
            {
                "remarks": "🇩🇪 Германия",
                "routing": {
                    "balancers": [{ "tag": "balancer", "selector": ["proxy", "reserve-"] }]
                },
                "outbounds": [
                    {
                        "protocol": "vless",
                        "tag": "proxy",
                        "settings": { "vnext": [{ "address": "de-main.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111" }] }] },
                        "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "de-main.example" } }
                    },
                    {
                        "protocol": "vless",
                        "tag": "reserve-2",
                        "settings": { "vnext": [{ "address": "de-res.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111112" }] }] },
                        "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "de-res.example" } }
                    }
                ]
            },
            {
                "remarks": "🇫🇮 Финляндия",
                "routing": {
                    "balancers": [{ "tag": "balancer", "selector": ["proxy", "reserve-"] }]
                },
                "outbounds": [
                    {
                        "protocol": "hysteria2",
                        "tag": "proxy",
                        "settings": { "address": "fi-only-bal.example", "port": 443, "auth": "hy2-pass", "version": 2 },
                        "streamSettings": {
                            "tlsSettings": { "serverName": "fi-only-bal.example" },
                            "finalmask": { "udp": [{ "type": "gecko", "settings": { "password": "gp", "packetSize": "512-1200" } }] }
                        }
                    },
                    {
                        "protocol": "vless",
                        "tag": "reserve-3",
                        "settings": { "vnext": [{ "address": "fi-res.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111113" }] }] },
                        "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "fi-res.example" } }
                    }
                ]
            },
            {
                "remarks": "🇩🇪 Германия (Main)",
                "outbounds": [
                    {
                        "protocol": "vless",
                        "tag": "proxy",
                        "settings": { "vnext": [{ "address": "de-main.example", "port": 443, "users": [{ "id": "11111111-1111-4111-8111-111111111111" }] }] },
                        "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "de-main.example" } }
                    }
                ]
            }
        ])
        .to_string();

        let parsed = parse_json_subscription_payload(&sub_json).expect("xray json nodes");
        assert!(parsed.iter().any(|n| n.protocol == "hysteria2"
            && n.outbound_json["obfs"]["type"] == "gecko"
            && n.outbound_json["obfs"]["min_packet_size"] == 512
            && n.outbound_json["obfs"]["max_packet_size"] == 1200));

        // 1) include_urltest_groups = false: drop urltest groups & reserve-*, inherit Finland label
        let mut store_off = RouterStoreData::default();
        store_off
            .outbound_sources
            .push(crate::store::OutboundSource {
                id: "src_xray".to_string(),
                enabled: true,
                source_type: "subscription".to_string(),
                include_urltest_groups: false,
                cached_nodes: parsed.clone(),
                ..Default::default()
            });
        store_off.sections.push(RoutingSection {
            id: "MAIN".to_string(),
            enabled: true,
            label: "Main".to_string(),
            action: "proxy".to_string(),
            connection_type: "vless".to_string(),
            outbound_source_refs: vec!["src_xray".to_string()],
            user_domains: vec!["example.com".to_string()],
            ..Default::default()
        });
        let cfg_off = compile_core_config(&store_off).expect("compile with groups off");
        let obs_off = cfg_off["outbounds"].as_array().unwrap();
        assert!(!obs_off.iter().any(|o| o["type"] == "urltest"));
        assert!(
            !obs_off
                .iter()
                .any(|o| o["tag"].as_str().unwrap_or("").contains("reserve"))
        );
        let sel_off = obs_off.iter().find(|o| o["tag"] == "sel-MAIN").unwrap()["outbounds"]
            .as_array()
            .unwrap();
        assert!(sel_off.iter().any(|t| t == "🇫🇮 Финляндия"));
        assert!(sel_off.iter().any(|t| t == "🇩🇪 Германия (Main)"));

        // 2) include_urltest_groups = true: keep urltest groups, hide internal balancer members from sel-MAIN
        let mut store_on = store_off.clone();
        store_on
            .outbound_sources
            .iter_mut()
            .find(|s| s.id == "src_xray")
            .unwrap()
            .include_urltest_groups = true;
        let cfg_on = compile_core_config(&store_on).expect("compile with groups on");
        let obs_on = cfg_on["outbounds"].as_array().unwrap();
        assert!(
            obs_on
                .iter()
                .any(|o| o["type"] == "urltest" && o["tag"] == "🇩🇪 Германия")
        );
        assert!(
            obs_on
                .iter()
                .any(|o| o["type"] == "urltest" && o["tag"] == "🇫🇮 Финляндия")
        );
        let sel_on = obs_on.iter().find(|o| o["tag"] == "sel-MAIN").unwrap()["outbounds"]
            .as_array()
            .unwrap();
        assert!(sel_on.iter().any(|t| t == "🇩🇪 Германия"));
        assert!(sel_on.iter().any(|t| t == "🇫🇮 Финляндия"));
        assert!(
            !sel_on
                .iter()
                .any(|t| t.as_str().unwrap_or("").contains("reserve"))
        );
    }

    #[test]
    fn test_zero_match_keyword_filter_source_does_not_fail_other_source() {
        let mut store = RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_empty".to_string(),
            enabled: true,
            source_type: "subscription".to_string(),
            filter_allow_regex: "nonexistent-pop".to_string(),
            cached_nodes: vec![
                parse_proxy_uri(
                    "vless://11111111-1111-1111-1111-111111111111@203.0.113.10:443#DE",
                    0,
                )
                .unwrap(),
            ],
            ..Default::default()
        });
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_live".to_string(),
            enabled: true,
            source_type: "urls".to_string(),
            proxy_links: vec![
                "vless://11111111-1111-1111-1111-111111111112@203.0.113.11:443#FI-Live".to_string(),
            ],
            ..Default::default()
        });
        store.sections.push(RoutingSection {
            id: "sec_multi".to_string(),
            enabled: true,
            label: "Multi".to_string(),
            action: "proxy".to_string(),
            connection_type: "vless".to_string(),
            outbound_source_refs: vec!["src_empty".to_string(), "src_live".to_string()],
            user_domains: vec!["example.org".to_string()],
            ..Default::default()
        });
        let cfg = compile_core_config(&store).expect("compile core config cleanly");
        let rules = cfg["route"]["rules"].as_array().unwrap();
        let org_rule = rules
            .iter()
            .find(|r| r["domain_suffix"] == json!(["example.org"]))
            .expect("rule for example.org");
        assert_eq!(org_rule["outbound"], "FI-Live");
        assert!(
            !cfg["outbounds"]
                .as_array()
                .unwrap()
                .iter()
                .any(|o| o["tag"] == "DE")
        );
    }

    #[test]
    fn test_service_mixed_inbound_generated_in_tproxy_mode() {
        let mut store = RouterStoreData::default();
        store.settings.proxy_mode = "tproxy".to_string();
        store.telegram.bot_proxy_section.clear();

        let cfg = compile_core_config(&store).expect("compile tproxy config");
        let inbounds = cfg["inbounds"].as_array().unwrap();
        let svc_in = inbounds
            .iter()
            .find(|i| i["tag"] == "service-mixed-in")
            .expect("service-mixed-in must be emitted");
        assert_eq!(svc_in["type"], "mixed");
        assert_eq!(svc_in["listen"], "127.0.0.1");
        assert_eq!(svc_in["listen_port"], 4534);
        assert!(!inbounds.iter().any(|i| i["tag"] == "tg-bot-in"));

        // Must not bind service-mixed-in to a forced outbound so normal rules govern it
        let rules = cfg["route"]["rules"].as_array().unwrap();
        assert!(!rules.iter().any(|r| {
            r.get("inbound")
                .and_then(Value::as_array)
                .is_some_and(|arr| arr.iter().any(|x| x == "service-mixed-in"))
        }));
    }

    #[test]
    fn test_tg_bot_inbound_for_section_and_direct() {
        let mut store = RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_tg".to_string(),
            enabled: true,
            source_type: "urls".to_string(),
            proxy_links: vec![
                "vless://11111111-1111-1111-1111-111111111111@203.0.113.20:443#FI-Edge".to_string(),
            ],
            ..Default::default()
        });
        store.sections.push(RoutingSection {
            id: "sec_main".to_string(),
            enabled: true,
            label: "Main".to_string(),
            action: "proxy".to_string(),
            connection_type: "vless".to_string(),
            outbound_source_refs: vec!["src_tg".to_string()],
            match_all: true,
            ..Default::default()
        });
        // Case-insensitive label match
        store.telegram.bot_proxy_section = "main".to_string();

        let cfg = compile_core_config(&store).expect("compile tg-bot-in section config");
        let inbounds = cfg["inbounds"].as_array().unwrap();
        let tg_in = inbounds
            .iter()
            .find(|i| i["tag"] == "tg-bot-in")
            .expect("tg-bot-in emitted for section");
        assert_eq!(tg_in["type"], "mixed");
        assert_eq!(tg_in["listen"], "127.0.0.1");
        assert_eq!(tg_in["listen_port"], 4535);

        let rules = cfg["route"]["rules"].as_array().unwrap();
        let hijack_idx = rules
            .iter()
            .position(|r| r["action"] == "hijack-dns")
            .expect("hijack-dns rule");
        let tg_idx = rules
            .iter()
            .position(|r| r["inbound"] == json!(["tg-bot-in"]))
            .expect("tg-bot-in rule");
        let catch_all_idx = rules
            .iter()
            .position(|r| r["outbound"] == "FI-Edge" && r.get("inbound").is_none())
            .expect("section catch-all rule");
        assert_eq!(rules[tg_idx]["outbound"], "FI-Edge");
        assert!(tg_idx > hijack_idx);
        assert!(tg_idx < catch_all_idx);

        // Now test "direct" override
        let mut store_direct = store.clone();
        store_direct.telegram.bot_proxy_section = "direct".to_string();
        let cfg_direct = compile_core_config(&store_direct).expect("compile direct tg-bot-in");
        let inbounds_direct = cfg_direct["inbounds"].as_array().unwrap();
        let tg_in_direct = inbounds_direct
            .iter()
            .find(|i| i["tag"] == "tg-bot-in")
            .expect("tg-bot-in emitted for direct");
        assert_eq!(tg_in_direct["listen_port"], 4535);
        let rules_direct = cfg_direct["route"]["rules"].as_array().unwrap();
        assert!(
            rules_direct
                .iter()
                .any(|r| r["inbound"] == json!(["tg-bot-in"]) && r["outbound"] == "direct")
        );
    }

    #[test]
    fn test_loopback_service_and_tg_bot_port_collision_shifts() {
        let mut store = RouterStoreData::default();
        store.servers.push(InboundServer {
            id: "srv_4534".to_string(),
            enabled: true,
            label: "Mixed 4534".to_string(),
            protocol: "mixed".to_string(),
            listen: "0.0.0.0".to_string(),
            listen_port: 4534,
            ..Default::default()
        });
        store.sections[0].mixed_proxy_enabled = true;
        store.sections[0].mixed_proxy_port = 4535;
        store.telegram.bot_proxy_section = "direct".to_string();

        let cfg = compile_core_config(&store).expect("compile config with port collisions");
        let inbounds = cfg["inbounds"].as_array().unwrap();
        let svc_in = inbounds
            .iter()
            .find(|i| i["tag"] == "service-mixed-in")
            .expect("service-mixed-in");
        let tg_in = inbounds
            .iter()
            .find(|i| i["tag"] == "tg-bot-in")
            .expect("tg-bot-in");
        assert_eq!(svc_in["listen_port"], 4536);
        assert_eq!(tg_in["listen_port"], 4537);

        let mut ports: Vec<u64> = inbounds
            .iter()
            .filter_map(|i| i.get("listen_port").and_then(Value::as_u64))
            .collect();
        let total_ports = ports.len();
        ports.sort_unstable();
        ports.dedup();
        assert_eq!(ports.len(), total_ports, "all inbound ports must be unique");
    }

    #[test]
    fn test_outbound_group_empty_sources_and_prefix_hashtag_preserve() {
        let mut store = RouterStoreData::default();
        store.outbound_sources = vec![
            crate::store::OutboundSource {
                id: "Clouds".to_string(),
                enabled: true,
                name: "Clouds".to_string(),
                prefix_nodes: true,
                node_prefix: "Clouds".to_string(),
                ..Default::default()
            },
            crate::store::OutboundSource {
                id: "SoftPortal".to_string(),
                enabled: true,
                name: "SoftPortal".to_string(),
                prefix_nodes: true,
                node_prefix: "SoftPortal".to_string(),
                ..Default::default()
            },
        ];
        store.outbound_groups.push(crate::store::OutboundGroup {
            id: "grp_de".to_string(),
            enabled: true,
            name: "Germany".to_string(),
            source_refs: Vec::new(),
            include_servers: vec![
                "[Clouds] 🇩🇪  Германия (MEGA)".to_string(),
                "🇩🇪 GERMANY DOUBLE HOPE #10".to_string(),
            ],
            ..Default::default()
        });

        let mut source_tag_map = HashMap::new();
        source_tag_map.insert(
            "Clouds".to_string(),
            vec!["Clouds 🇩🇪  Германия (MEGA)".to_string()],
        );
        source_tag_map.insert(
            "SoftPortal".to_string(),
            vec![
                "SoftPortal 🇩🇪 GERMANY DOUBLE HOPE #10".to_string(),
                "SoftPortal 🇺🇸 USA".to_string(),
            ],
        );

        let grp_map = build_outbound_group_map(
            &store.outbound_groups,
            &store.outbound_sources,
            &source_tag_map,
        );
        assert_eq!(
            grp_map.get("grp_de").map(Vec::as_slice),
            Some(
                &[
                    "Clouds 🇩🇪  Германия (MEGA)".to_string(),
                    "SoftPortal 🇩🇪 GERMANY DOUBLE HOPE #10".to_string()
                ][..]
            )
        );
    }

    #[test]
    fn test_zapret2_disabled_section_filter_and_nahui_quota_schedule_no_global_block() {
        let mut store = RouterStoreData::default();
        store.sections.clear();
        store.sections.push(RoutingSection {
            id: "Zapret2".to_string(),
            enabled: true,
            label: "Zapret2".to_string(),
            action: "desync".to_string(),
            connection_type: "desync".to_string(),
            desync_mode: "hostfakesplit".to_string(),
            section_filter_mode: "disabled".to_string(),
            include_countries: vec!["US".to_string()],
            node_filter_allow: "nonexistent".to_string(),
            user_domains: vec!["youtube.com".to_string()],
            ..Default::default()
        });
        store.schedules.push(crate::store::ScheduleRule {
            id: "Nahui".to_string(),
            enabled: true,
            label: "Nahui".to_string(),
            start_time: String::new(),
            end_time: String::new(),
            blocked_categories: vec!["social".to_string()],
            action: "block".to_string(),
            ..Default::default()
        });
        store.schedules.push(crate::store::ScheduleRule {
            id: "OfflineMac".to_string(),
            enabled: true,
            label: "Offline".to_string(),
            start_time: "08:00".to_string(),
            end_time: "22:00".to_string(),
            device_ips: vec!["ff:ee:dd:cc:bb:01".to_string()],
            action: "block".to_string(),
            ..Default::default()
        });

        let cfg = compile_core_config(&store).expect("compile Zapret2 + schedules");
        let rules = cfg["route"]["rules"].as_array().unwrap();
        assert!(rules.iter().any(|r| {
            r["domain_suffix"] == json!(["youtube.com"]) && r["outbound"] == "desync-sec-Zapret2"
        }));
        assert!(
            !rules
                .iter()
                .any(|r| r["outbound"] == "block" && r.get("time_window").is_some()),
            "empty-time or unresolved-MAC schedules must not emit global time_window block rules"
        );
    }

    #[test]
    fn test_bypass_section_ordered_before_disable_quic_and_isolate_p2p() {
        let mut store = RouterStoreData::default();
        store.settings.disable_quic = true;
        store.settings.isolate_p2p = true;
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_dummy".to_string(),
            enabled: true,
            name: "Dummy".to_string(),
            source_type: "subscription".to_string(),
            cached_nodes: vec![crate::store::ParsedProxyNode {
                tag: "DummyNode".to_string(),
                protocol: "vless".to_string(),
                server: "198.51.100.30".to_string(),
                server_port: 443,
                outbound_json: json!({
                    "type": "vless",
                    "tag": "DummyNode",
                    "server": "198.51.100.30",
                    "server_port": 443,
                    "uuid": "33333333-3333-3333-3333-333333333333"
                }),
                ..Default::default()
            }],
            ..Default::default()
        });
        store.sections.clear();
        store.sections.push(RoutingSection {
            id: "ByPass".to_string(),
            enabled: true,
            label: "ByPass".to_string(),
            action: "direct".to_string(),
            user_domains: vec!["yandex.ru".to_string()],
            ..Default::default()
        });
        store.sections.push(RoutingSection {
            id: "Main".to_string(),
            enabled: true,
            label: "Main".to_string(),
            action: "proxy".to_string(),
            outbound_source_refs: vec!["src_dummy".to_string()],
            user_domains: vec!["example.com".to_string()],
            ..Default::default()
        });

        let cfg = compile_core_config(&store).expect("compile ByPass ordering");
        let rules = cfg["route"]["rules"].as_array().unwrap();
        let bypass_pos = rules
            .iter()
            .position(|r| r["domain_suffix"] == json!(["yandex.ru"]) && r["outbound"] == "direct")
            .expect("ByPass rule present");
        let p2p_pos = rules
            .iter()
            .position(|r| r["protocol"] == json!(["bittorrent"]) && r["outbound"] == "direct")
            .expect("isolate_p2p rule present");
        let quic_pos = rules
            .iter()
            .position(|r| {
                r["network"] == "udp" && r["port"] == json!([443]) && r["outbound"] == "block"
            })
            .expect("disable_quic rule present");
        let main_pos = rules
            .iter()
            .position(|r| r["domain_suffix"] == json!(["example.com"]))
            .expect("Main rule present");

        assert!(bypass_pos < p2p_pos);
        assert!(p2p_pos < quic_pos);
        assert!(quic_pos < main_pos);
    }

    #[test]
    fn test_or_condition_rules_discord_voice_resolve_and_inverted_composite() {
        let mut store = RouterStoreData::default();
        store.settings.enable_ipv6 = true;
        store.conditions.push(TrafficCondition {
            id: "cond_dc".to_string(),
            enabled: true,
            name: "Discord".to_string(),
            condition_type: "atomic".to_string(),
            community_lists: vec!["telegram".to_string(), "discord".to_string()],
            community_subnets: true,
            user_domains: vec!["example.org".to_string()],
            user_subnets: vec!["10.20.0.0/16".to_string()],
            client_ips: vec!["192.168.1.0/24".to_string()],
            ..Default::default()
        });
        store.conditions.push(TrafficCondition {
            id: "cond_inv".to_string(),
            enabled: true,
            invert: true,
            condition_type: "atomic".to_string(),
            user_domains: vec!["local.test".to_string()],
            user_subnets: vec!["10.99.0.0/16".to_string()],
            client_ips: vec!["192.168.1.50/32".to_string()],
            ..Default::default()
        });
        store.sections.clear();
        store.sections.push(RoutingSection {
            id: "discord_desync".to_string(),
            enabled: true,
            label: "Discord Desync".to_string(),
            action: "desync".to_string(),
            connection_type: "desync".to_string(),
            desync_mode: "fake".to_string(),
            condition_refs: vec!["cond_dc".to_string(), "cond_inv".to_string()],
            ..Default::default()
        });

        let cfg = compile_core_config(&store).expect("compile discord desync");
        let outbounds = cfg["outbounds"].as_array().unwrap();
        let dc_ob = outbounds
            .iter()
            .find(|o| o["tag"] == "desync-sec-discord_desync")
            .expect("desync outbound present");
        assert_eq!(dc_ob["udp_fake"], json!(true));

        let rules = cfg["route"]["rules"].as_array().unwrap();
        let rs_resolve_idx = rules
            .iter()
            .position(|r| {
                r["action"] == "resolve"
                    && r["server"] == "dns-remote"
                    && r["rule_set"] == json!(["trs-telegram", "trs-discord"])
                    && r["source_ip_cidr"] == json!(["192.168.1.0/24"])
            })
            .expect("resolve rule before rule_set");
        let rs_route_idx = rules
            .iter()
            .position(|r| {
                r["rule_set"] == json!(["trs-telegram", "trs-discord"])
                    && r["outbound"] == "desync-sec-discord_desync"
                    && r["source_ip_cidr"] == json!(["192.168.1.0/24"])
            })
            .expect("separate rule_set branch");
        assert!(rs_resolve_idx < rs_route_idx);

        assert!(rules.iter().any(|r| {
            r["domain_suffix"] == json!(["example.org"])
                && r["outbound"] == "desync-sec-discord_desync"
                && r.get("ip_cidr").is_none()
        }));
        let ip_rule = rules
            .iter()
            .find(|r| {
                r["outbound"] == "desync-sec-discord_desync"
                    && r.get("ip_cidr").is_some()
                    && r.get("port_range").is_none()
            })
            .expect("separate ip_cidr branch");
        let cidrs = ip_rule["ip_cidr"].as_array().unwrap();
        assert!(cidrs.contains(&json!("10.20.0.0/16")));
        assert!(cidrs.contains(&json!("149.154.160.0/20")));
        assert!(cidrs.contains(&json!("162.159.128.0/20")));

        assert!(rules.iter().any(|r| {
            r["network"] == "udp"
                && r["port_range"] == json!(DISCORD_VOICE_PORT_RANGES)
                && r["outbound"] == "desync-sec-discord_desync"
        }));
        assert!(rules.iter().any(|r| {
            r["network"] == "tcp"
                && r["port_range"] == json!(DISCORD_MEDIA_PORT_RANGES)
                && r["outbound"] == "desync-sec-discord_desync"
        }));

        let inv_rule = rules
            .iter()
            .find(|r| r["type"] == "logical" && r["mode"] == "and")
            .expect("multi-branch inverted rule wraps OR inside outer AND");
        let inner = inv_rule["rules"].as_array().unwrap();
        assert_eq!(inner[0]["source_ip_cidr"], json!(["192.168.1.50/32"]));
        assert_eq!(inner[1]["type"], "logical");
        assert_eq!(inner[1]["mode"], "or");
        assert_eq!(inner[1]["invert"], json!(true));
    }

    #[test]
    fn test_resolve_device_targets_with_arp_and_dhcp_tables() {
        let arp = "IP address       HW type     Flags       HW address            Mask     Device\n\
                   192.168.1.205    0x1         0x2         3e:83:67:22:fe:65     *        br-lan\n";
        let leases = "1700000000 aa:bb:cc:dd:ee:02 192.168.1.206 phone *\n";
        let resolved = resolve_device_targets_with_tables(
            &[
                "3E:83:67:22:FE:65".to_string(),
                "aa:bb:cc:dd:ee:02".to_string(),
                "192.168.1.50".to_string(),
                "ff:ff:ff:ff:ff:ff".to_string(),
            ],
            arp,
            leases,
        );
        assert_eq!(
            resolved,
            vec!["192.168.1.205/32", "192.168.1.206/32", "192.168.1.50/32"]
        );
    }

    #[test]
    fn test_tailscale_endpoints_magicdns_routes_and_xray_clamp() {
        let mut store = RouterStoreData::default();
        store.settings.fakeip_enabled = true;
        store.settings.enable_ipv6 = true;
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "ts1".to_string(),
            enabled: true,
            source_type: "tailscale".to_string(),
            tailscale_mode: "singbox".to_string(),
            tailscale_ephemeral: true,
            tailscale_relay_server_port: "41641".to_string(),
            tailscale_accept_dns: true,
            tailscale_accept_default_resolvers: true,
            ..Default::default()
        });
        store.servers.push(crate::store::InboundServer {
            id: "srv_nat".to_string(),
            enabled: true,
            protocol: "tailscale".to_string(),
            tailscale_mode: "native".to_string(),
            ..Default::default()
        });

        let cfg = compile_core_config(&store).expect("compile core config with tailscale");
        let eps = cfg["endpoints"]
            .as_array()
            .expect("endpoints array must exist");
        assert_eq!(eps.len(), 1, "native server must not emit an endpoint");
        let ts_ep = &eps[0];
        assert_eq!(ts_ep["type"], "tailscale");
        assert_eq!(ts_ep["ephemeral"], json!(true));
        let state_dir = ts_ep["state_directory"]
            .as_str()
            .expect("state_directory string");
        assert!(state_dir.starts_with("/var/run/tachyon/tailscale/"));
        assert!(ts_ep.get("auth_key").is_none());
        assert_eq!(ts_ep["relay_server_port"], json!(41641));
        assert!(ts_ep.get("accept_dns").is_none());
        assert!(ts_ep.get("accept_default_resolvers").is_none());

        let dns_servers = cfg["dns"]["servers"].as_array().expect("dns servers array");
        assert!(dns_servers.iter().any(|s| s["type"] == "tailscale"));

        let dns_rules = cfg["dns"]["rules"].as_array().expect("dns rules array");
        let ts_rule_pos = dns_rules
            .iter()
            .position(|r| {
                r["domain_suffix"]
                    .as_array()
                    .is_some_and(|arr| arr.iter().any(|d| d == "ts.net"))
            })
            .expect("MagicDNS ts.net rule must exist");
        let fakeip_rule_pos = dns_rules
            .iter()
            .position(|r| r["server"] == "dns-fakeip")
            .expect("FakeIP fallback rule must exist");
        assert!(ts_rule_pos < fakeip_rule_pos);

        let route_rules = cfg["route"]["rules"].as_array().expect("route rules array");
        assert!(route_rules.iter().any(|r| {
            r["ip_cidr"].as_array().is_some_and(|arr| {
                arr.iter().any(|c| c == "100.64.0.0/10")
                    && arr.iter().any(|c| c == "fd7a:115c:a1e0::/48")
            })
        }));

        assert_eq!(xray_clamp_probe_interval("5s"), "30s");
        assert_eq!(xray_clamp_probe_interval("10s"), "30s");
        assert_eq!(xray_clamp_probe_interval("45s"), "45s");
    }

    #[test]
    fn test_mieru_simple_share_links_and_roundtrip() {
        let sample_uri = "mierus://testuser:testpass@198.51.100.10?profile=%F0%9F%87%AB%F0%9F%87%AE+Finland%7CLainDEV&mtu=1400&port=20100&protocol=TCP#%F0%9F%87%AB%F0%9F%87%AE%20Finland%7CLainDEV";
        let node1 = parse_proxy_uri(sample_uri, 0).expect("sample mierus:// must parse");
        assert_eq!(node1.protocol, "mieru");
        assert_eq!(node1.server, "198.51.100.10");
        assert_eq!(node1.server_port, 20100);
        assert_eq!(node1.tag, "\u{1F1EB}\u{1F1EE} Finland|LainDEV");
        assert_eq!(node1.outbound_json["transport"], "TCP");
        assert_eq!(node1.outbound_json["username"], "testuser");
        assert_eq!(node1.outbound_json["password"], "testpass");
        assert!(
            node1.outbound_json.get("mtu").is_none(),
            "mieru outbound must not emit unknown mtu field"
        );

        let link1 = serialize_mieru_outbound(&node1.outbound_json).expect("serialize sample mieru");
        assert!(link1.starts_with("mierus://testuser:testpass@198.51.100.10?"));
        assert!(!link1.contains(":443"));
        assert!(link1.contains("port=20100"));
        assert!(link1.contains("protocol=TCP"));
        assert!(link1.contains("profile="));
        let roundtrip1 = parse_proxy_uri(&link1, 1).expect("round-trip mierus:// must parse");
        assert_eq!(roundtrip1.server_port, 20100);
        assert_eq!(roundtrip1.tag, "\u{1F1EB}\u{1F1EE} Finland|LainDEV");

        let encoded_uri = "mierus://user%3Aone:p%3Ass@203.0.113.5?port=20200&protocol=UDP#EncCreds";
        let enc_node = parse_proxy_uri(encoded_uri, 2).expect("encoded credentials mierus://");
        assert_eq!(enc_node.outbound_json["username"], "user:one");
        assert_eq!(enc_node.outbound_json["password"], "p:ss");
        assert_eq!(enc_node.server_port, 20200);
        assert_eq!(enc_node.outbound_json["transport"], "UDP");

        let range_uri = "mierus://u:p@203.0.113.6?port=2010-2020&protocol=UDP#RangeBug";
        let range_node = parse_proxy_uri(range_uri, 3).expect("range mierus://");
        assert!(range_node.outbound_json.get("server_port").is_none());
        assert_eq!(
            range_node.outbound_json["server_ports"],
            json!(["2010-2020"])
        );
        assert_eq!(range_node.server_port, 2010);
        let range_link =
            serialize_mieru_outbound(&range_node.outbound_json).expect("serialize range mieru");
        assert!(range_link.starts_with("mierus://u:p@203.0.113.6?"));
        assert!(range_link.contains("port=2010-2020"));

        let multi_uri = "mierus://u:p@203.0.113.7?port=2010&port=2020-2030&protocol=TCP&traffic-pattern=random#MultiPort";
        let multi_node = parse_proxy_uri(multi_uri, 4).expect("multi-port mierus://");
        assert!(multi_node.outbound_json.get("server_port").is_none());
        assert_eq!(
            multi_node.outbound_json["server_ports"],
            json!(["2010", "2020-2030"])
        );
        assert_eq!(multi_node.outbound_json["traffic_pattern"], "random");
        let multi_link =
            serialize_mieru_outbound(&multi_node.outbound_json).expect("serialize multi mieru");
        assert!(multi_link.contains("port=2010&port=2020-2030"));
        assert!(multi_link.contains("traffic-pattern=random"));

        let ipv6_uri = "mierus://u:p@[2001:db8::1]?port=20443&protocol=UDP#V6Node";
        let v6_node = parse_proxy_uri(ipv6_uri, 5).expect("IPv6 mierus://");
        assert_eq!(v6_node.server, "2001:db8::1");
        assert_eq!(v6_node.server_port, 20443);
        let v6_link = serialize_mieru_outbound(&v6_node.outbound_json).expect("serialize v6 mieru");
        assert!(v6_link.starts_with("mierus://u:p@[2001:db8::1]?"));
        assert!(v6_link.contains("port=20443"));

        let query_profile_uri =
            "mierus://u:p@203.0.113.8?profile=FromQuery&port=20500&protocol=TCP";
        let qp_node = parse_proxy_uri(query_profile_uri, 6).expect("query profile mierus://");
        assert_eq!(qp_node.tag, "FromQuery");

        assert!(parse_proxy_uri("mierus://u:p@203.0.113.10", 7).is_none());
        assert!(parse_proxy_uri("mierus://203.0.113.10?port=20100", 8).is_none());
        assert!(parse_proxy_uri("mierus://u:p@203.0.113.10?port=20200-20100", 9).is_none());
        assert!(parse_proxy_uri("mierus://u:p@203.0.113.10?port=70000", 10).is_none());

        let srv = crate::store::InboundServer {
            id: "srv_m".to_string(),
            enabled: true,
            label: "Node1".to_string(),
            protocol: "mieru".to_string(),
            listen_port: 20500,
            server_username: "u".to_string(),
            password: "p".to_string(),
            mieru_transport: "UDP".to_string(),
            ..Default::default()
        };
        let srv_uri = build_server_share_uri(&srv, Some("203.0.113.50"));
        assert!(srv_uri.starts_with("mierus://u:p@203.0.113.50?"));
        assert!(!srv_uri.contains("203.0.113.50:20500"));
        assert!(srv_uri.contains("port=20500"));
        assert!(srv_uri.contains("protocol=UDP"));

        let mut store = RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "m1".to_string(),
            enabled: true,
            source_type: "mieru".to_string(),
            server: "203.0.113.9".to_string(),
            server_ports: vec!["20100-20110".to_string()],
            username: "u".to_string(),
            password: "p".to_string(),
            mieru_transport: "UDP".to_string(),
            mieru_multiplexing: "MULTIPLEXING_HIGH".to_string(),
            ..Default::default()
        });
        let cfg = compile_core_config(&store).expect("compile mieru source outbound");
        let ob = cfg["outbounds"]
            .as_array()
            .and_then(|arr| arr.iter().find(|o| o["type"] == "mieru"))
            .expect("mieru outbound must exist");
        assert_eq!(ob["transport"], "UDP");
        assert_eq!(ob["server_ports"], json!(["20100-20110"]));
        assert_eq!(ob["multiplexing"], "MULTIPLEXING_HIGH");
        assert!(ob.get("server_port").is_none());
    }
}
