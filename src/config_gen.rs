//! Master `tachyon-core` JSON configuration compiler (`/etc/tachyon-core/config.json`),
//! universal proxy URI parser (`vless://`, `vmess://`, `ss://`, `trojan://`,
//! `hysteria2://`, `tuic://`, `wg://`, `awg://`, `fptn://`), and router inbound share-link generator.
//!
//! Strictly pure `tachyon-core` target — no `sing-box` compatibility hacks and no
//! external `zapret`/`zapret2`/`byedpi`/`wdtt`/`olcrtc`/`tailscale` processes.

use std::collections::HashMap;

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD as B64_STD, URL_SAFE_NO_PAD as B64_URL};
use serde_json::{Map, Value, json};

use crate::store::{
    BalancerConfig, InboundServer, OutboundSource, ParsedProxyNode, RouterStoreData,
    RoutingSection, TrafficCondition,
};

/// Universal URI parser converting a proxy link into a `ParsedProxyNode` with native `tachyon-core` JSON.
pub fn parse_proxy_uri(uri: &str, idx: usize) -> Option<ParsedProxyNode> {
    let uri = uri.trim();
    if uri.is_empty() || uri.starts_with('#') {
        return None;
    }
    let (scheme, rest) = uri.split_once("://")?;
    let scheme_lower = scheme.to_ascii_lowercase();

    if scheme_lower == "vmess" {
        return parse_vmess_uri(uri, rest, idx);
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

/// Build an outbound JSON object for an `OutboundSource` and return all generated outbound `(tag, json)` pairs.
fn build_source_outbounds(src: &OutboundSource) -> Vec<(String, Value)> {
    let mut out = Vec::new();
    if !src.enabled {
        return out;
    }
    match src.source_type.as_str() {
        "desync" => {
            let tag = format!("desync-{}", src.id);
            let preset = if src.desync_preset.trim().is_empty() {
                "adaptive"
            } else {
                src.desync_preset.trim()
            };
            // Invariant: `auto_tune` is enabled only for `adaptive`/`auto` or when explicitly set.
            let auto_tune = if preset == "adaptive" || preset == "auto" {
                true
            } else {
                src.desync_auto_tune
            };
            let mut obj = Map::new();
            obj.insert("type".into(), json!("desync"));
            obj.insert("tag".into(), json!(tag));
            obj.insert("preset".into(), json!(preset));
            obj.insert("auto_tune".into(), json!(auto_tune));
            let mut pool = src.desync_sni_pool.clone();
            if !src.desync_fake_sni.is_empty() && !pool.contains(&src.desync_fake_sni) {
                pool.insert(0, src.desync_fake_sni.clone());
            }
            if !pool.is_empty() {
                obj.insert("sni_pool".into(), json!(pool));
            }
            if !src.desync_split_pos.is_empty() {
                obj.insert("split_pos".into(), json!(src.desync_split_pos));
            }
            if src.desync_ttl > 0 {
                obj.insert("ttl".into(), json!(src.desync_ttl));
            }
            if !src.desync_fooling.is_empty() {
                obj.insert("fooling".into(), json!(src.desync_fooling));
            }
            if src.desync_quic_fake {
                obj.insert("quic_fake".into(), json!(true));
            }
            out.push((tag, Value::Object(obj)));
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
                obj.insert("h1".into(), json!(src.awg_h1));
                obj.insert("h2".into(), json!(src.awg_h2));
                obj.insert("h3".into(), json!(src.awg_h3));
                obj.insert("h4".into(), json!(src.awg_h4));
            }
            out.push((tag, Value::Object(obj)));
        }
        "warp" => {
            let tag = format!("warp-{}", src.id);
            out.push((
                tag.clone(),
                json!({
                    "type": "wireguard",
                    "tag": tag,
                    "server": "engage.cloudflareclient.com",
                    "server_port": 2408,
                    "private_key": src.wg_private_key,
                    "peer_public_key": if src.wg_peer_public_key.is_empty() {
                        "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
                    } else {
                        &src.wg_peer_public_key
                    },
                    "local_address": [if src.warp_ipv4.is_empty() { "172.16.0.2/32" } else { &src.warp_ipv4 }],
                    "mtu": 1280
                }),
            ));
        }
        "wdtt" => {
            let tag = format!("wdtt-{}", src.id);
            out.push((
                tag.clone(),
                json!({
                    "type": "wdtt",
                    "tag": tag,
                }),
            ));
        }
        "fptn" => {
            for (idx, link) in src.proxy_links.iter().enumerate() {
                if let Some(node) = parse_proxy_uri(link, idx) {
                    out.push((node.tag, node.outbound_json));
                }
            }
            if out.is_empty() {
                let tag = format!("fptn-{}", src.id);
                out.push((
                    tag.clone(),
                    json!({
                        "type": "fptn",
                        "tag": tag,
                    }),
                ));
            }
        }
        "tailscale" => {
            let tag = format!("tailscale-{}", src.id);
            out.push((
                tag.clone(),
                json!({
                    "type": "tailscale",
                    "tag": tag,
                    "auth_key": src.tailscale_auth_key,
                    "control_url": if src.tailscale_control_url.is_empty() {
                        "https://controlplane.tailscale.com"
                    } else {
                        &src.tailscale_control_url
                    },
                    "hostname": if src.tailscale_hostname.is_empty() {
                        "tachyon-router"
                    } else {
                        &src.tailscale_hostname
                    }
                }),
            ));
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
            for node in &src.cached_nodes {
                if passes_source_filters(src, &node.tag, &node.country) {
                    out.push((node.tag.clone(), node.outbound_json.clone()));
                }
            }
            for (idx, link) in src.proxy_links.iter().enumerate() {
                if let Some(node) = parse_proxy_uri(link, idx)
                    && passes_source_filters(src, &node.tag, &node.country)
                    && !out.iter().any(|(t, _)| t == &node.tag)
                {
                    out.push((node.tag, node.outbound_json));
                }
            }
        }
    }
    out
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

/// Compile the complete `/etc/tachyon-core/config.json` document from `RouterStoreData`.
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
                "inet4_address": "172.19.0.1/30",
                "mtu": store.settings.tun_mtu,
                "auto_route": true,
                "strict_route": true,
                "stack": store.settings.tun_stack,
                "sniff": true,
                "sniff_override_destination": false
            }));
        }
        "socks" => {
            inbounds.push(json!({
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "0.0.0.0",
                "listen_port": 1080,
                "sniff": true
            }));
        }
        _ => {
            inbounds.push(json!({
                "type": "tproxy",
                "tag": "tproxy-in",
                "listen": "::",
                "listen_port": 1602,
                "sniff": true,
                "sniff_override_destination": false
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

    // Router-hosted Inbound Servers
    for srv in store.servers.iter().filter(|s| s.enabled) {
        if let Some(inb) = build_inbound_server(srv) {
            inbounds.push(inb);
        }
    }

    // 2. Collect all outbounds from `outbound_sources`
    let mut source_tag_map: HashMap<String, Vec<String>> = HashMap::new();
    for src in &store.outbound_sources {
        let pairs = build_source_outbounds(src);
        let mut tags = Vec::new();
        for (tag, obj) in pairs {
            tags.push(tag.clone());
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
            "preset": "adaptive",
            "auto_tune": true
        }));
    }

    // 3. Build section-scoped selectors / balancers and route rules
    let cond_map: HashMap<&str, &TrafficCondition> = store
        .conditions
        .iter()
        .map(|c| (c.id.as_str(), c))
        .collect();
    let bal_map: HashMap<&str, &BalancerConfig> =
        store.balancers.iter().map(|b| (b.id.as_str(), b)).collect();

    // Protocol sniff + DNS hijack rule first
    rules.push(json!({
        "inbound": ["dns-in"],
        "action": "hijack-dns"
    }));

    // Optional QUIC block (forces HTTP/2 TCP fallback for TLS desync)
    if store.settings.disable_quic {
        rules.push(json!({
            "network": "udp",
            "port": [443],
            "outbound": "block"
        }));
    }

    // Parental control & Schedule rules
    for prof in store.profiles.iter().filter(|p| p.enabled) {
        if !prof.device_ips.is_empty() && !prof.blocked_domains.is_empty() {
            rules.push(json!({
                "source_ip_cidr": prof.device_ips,
                "domain_suffix": prof.blocked_domains,
                "outbound": "block"
            }));
        }
    }

    for sched in store.schedules.iter().filter(|s| s.enabled) {
        let tw = format_schedule_time_window(&sched.days, &sched.start_time, &sched.end_time);
        let mut r = Map::new();
        r.insert("time_window".into(), json!(tw));
        let mut ips = Vec::new();
        for pref in &sched.profile_refs {
            if let Some(p) = store.profiles.iter().find(|p| &p.id == pref) {
                ips.extend(p.device_ips.clone());
            }
        }
        if !ips.is_empty() {
            r.insert("source_ip_cidr".into(), json!(ips));
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

    for sec in store.sections.iter().filter(|s| s.enabled) {
        if sec.action == "dns" || sec.connection_type == "dns" {
            continue;
        }
        let target_outbound_tag = resolve_section_outbound(
            sec,
            &source_tag_map,
            &bal_map,
            &mut outbounds,
            &mut seen_outbound_tags,
        );

        if !sec.fully_routed_ips.is_empty() {
            let cidrs: Vec<String> = sec
                .fully_routed_ips
                .iter()
                .filter(|s| !s.contains(':'))
                .cloned()
                .collect();
            if !cidrs.is_empty() {
                rules.push(json!({
                    "source_ip_cidr": cidrs,
                    "outbound": target_outbound_tag
                }));
            }
        }

        let mut section_matched_any = false;
        for cref in &sec.condition_refs {
            let Some(cond) = cond_map.get(cref.as_str()).copied() else {
                continue;
            };
            if !cond.enabled {
                continue;
            }
            if let Some(rule_obj) = build_condition_rule(
                cond,
                &target_outbound_tag,
                &store.settings.rulesets_dir,
                &store.settings.github_mirror,
                &mut rule_sets,
                &mut seen_rule_sets,
            ) {
                rules.push(rule_obj);
                section_matched_any = true;
            }
        }

        // Also compile inline section lists/domains/subnets if the section has no condition_refs
        if !section_matched_any
            && (!sec.community_lists.is_empty()
                || !sec.user_domains.is_empty()
                || !sec.user_subnets.is_empty())
        {
            let synthetic = TrafficCondition {
                id: format!("inline-{}", sec.id),
                enabled: true,
                name: sec.label.clone(),
                condition_type: "atomic".to_string(),
                community_lists: sec.community_lists.clone(),
                user_domains: sec.user_domains.clone(),
                user_subnets: sec.user_subnets.clone(),
                geoip_codes: sec.geoip_codes.clone(),
                geoip_mode: sec.geoip_mode.clone(),
                ..Default::default()
            };
            if let Some(rule_obj) = build_condition_rule(
                &synthetic,
                &target_outbound_tag,
                &store.settings.rulesets_dir,
                &store.settings.github_mirror,
                &mut rule_sets,
                &mut seen_rule_sets,
            ) {
                rules.push(rule_obj);
                section_matched_any = true;
            }
        }

        if !section_matched_any && sec.condition_refs.is_empty() {
            rules.push(json!({
                "outbound": target_outbound_tag
            }));
        }
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

    // 4. DNS configuration (`127.0.0.42:53` + FakeIP + bootstrap resolver)
    let boot_dns = store
        .settings
        .bootstrap_dns_servers
        .first()
        .cloned()
        .unwrap_or_else(|| "77.88.8.8".to_string());
    let main_dns = store
        .settings
        .dns_servers
        .first()
        .cloned()
        .unwrap_or_else(|| "https://1.1.1.1/dns-query".to_string());

    let dns_block = json!({
        "servers": [
            {
                "tag": "dns-remote",
                "address": main_dns,
                "address_resolver": "dns-bootstrap",
                "strategy": store.settings.dns_strategy,
                "detour": "direct"
            },
            {
                "tag": "dns-bootstrap",
                "address": boot_dns,
                "detour": "direct"
            },
            {
                "tag": "dns-fakeip",
                "address": "fakeip"
            }
        ],
        "rules": [
            {
                "query_type": ["A", "AAAA"],
                "server": "dns-fakeip",
                "rewrite_ttl": store.settings.dns_rewrite_ttl
            }
        ],
        "fakeip": {
            "enabled": true,
            "inet4_range": "198.18.0.0/15",
            "inet6_range": "fc00::/18"
        },
        "independent_cache": store.settings.dns_local_cache
    });

    Ok(json!({
        "log": {
            "level": store.settings.log_level,
            "timestamp": true
        },
        "dns": dns_block,
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "rules": rules,
            "rule_set": rule_sets,
            "final": "direct",
            "auto_detect_interface": true
        },
        "experimental": {
            "cache_file": {
                "enabled": true,
                "path": store.settings.cache_path,
                "store_fakeip": true
            },
            "clash_api": {
                "external_controller": store.settings.clash_api_addr,
                "secret": store.settings.clash_api_secret
            }
        }
    }))
}

/// Resolve the outbound tag for a `RoutingSection`.
/// Strictly adheres to the balancer invariant: candidate nodes come from `sec.outbound_source_refs`,
/// while `sec.balancer_refs` provides the selection policy (`least_test`, `stability`, `sticky`, etc.).
fn resolve_section_outbound(
    sec: &RoutingSection,
    source_tag_map: &HashMap<String, Vec<String>>,
    bal_map: &HashMap<&str, &BalancerConfig>,
    outbounds: &mut Vec<Value>,
    seen_outbound_tags: &mut HashMap<String, bool>,
) -> String {
    match sec.connection_type.as_str() {
        "direct" | "hosts" => return "direct".to_string(),
        "block" => return "block".to_string(),
        _ => {}
    }

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

    if candidate_tags.is_empty() {
        if sec.connection_type == "desync" {
            return "adaptive-desync-default".to_string();
        }
        return "direct".to_string();
    }

    // If a balancer is attached to this section, synthesize a section-scoped balancer outbound
    // populated strictly with `candidate_tags` from this section!
    if let Some(bal_id) = sec.balancer_refs.first()
        && let Some(bal) = bal_map.get(bal_id.as_str()).copied()
        && bal.enabled
    {
        let bal_tag = format!("bal-{}-{}", sec.id, bal.id);
        if !seen_outbound_tags.contains_key(&bal_tag) {
            seen_outbound_tags.insert(bal_tag.clone(), true);
            outbounds.push(json!({
                "type": "urltest",
                "tag": bal_tag,
                "outbounds": candidate_tags,
                "url": bal.testing_url,
                "interval": format!("{}s", bal.check_interval.max(15)),
                "tolerance": bal.tolerance,
                "mode": bal.mode,
                "sticky_hash": bal.sticky_hash,
                "passive_check": bal.passive_check,
                "interrupt_exist_connections": bal.interrupt_exist_connections
            }));
        }
        return bal_tag;
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

fn build_condition_rule(
    cond: &TrafficCondition,
    outbound_tag: &str,
    rulesets_dir: &str,
    github_mirror: &str,
    rule_sets: &mut Vec<Value>,
    seen_rule_sets: &mut HashMap<String, bool>,
) -> Option<Value> {
    let mut r = Map::new();

    // Community lists -> native `.trs` zero-copy mmap rule-sets from `Dushnilin/tachyon-lists`
    let mut rs_tags = Vec::new();
    for list_name in &cond.community_lists {
        let clean = list_name.trim();
        if clean.is_empty() {
            continue;
        }
        let rs_tag = format!("trs-{clean}");
        rs_tags.push(rs_tag.clone());
        if !seen_rule_sets.contains_key(&rs_tag) {
            seen_rule_sets.insert(rs_tag.clone(), true);
            let local_path = format!("{rulesets_dir}/{clean}.trs");
            let base_url = format!(
                "https://github.com/Dushnilin/tachyon-lists/releases/latest/download/{clean}.trs"
            );
            let remote_url = if github_mirror.trim().is_empty() {
                base_url
            } else {
                format!("{}/{}", github_mirror.trim_end_matches('/'), base_url)
            };
            rule_sets.push(json!({
                "tag": rs_tag,
                "type": "remote",
                "format": "binary",
                "path": local_path,
                "url": remote_url,
                "download_detour": "direct",
                "update_interval": "6h"
            }));
        }
    }
    if !rs_tags.is_empty() {
        r.insert("rule_set".into(), json!(rs_tags));
    }
    if !cond.user_domains.is_empty() {
        r.insert("domain_suffix".into(), json!(cond.user_domains));
    }
    if !cond.user_subnets.is_empty() {
        r.insert("ip_cidr".into(), json!(cond.user_subnets));
    }
    if !cond.client_ips.is_empty() {
        let cidrs: Vec<String> = cond
            .client_ips
            .iter()
            .filter(|s| !s.contains(':'))
            .cloned()
            .collect();
        if !cidrs.is_empty() {
            r.insert("source_ip_cidr".into(), json!(cidrs));
        }
    }
    if !cond.ports.is_empty() {
        let mut exact_ports: Vec<u16> = Vec::new();
        let mut port_ranges: Vec<String> = Vec::new();
        for p in &cond.ports {
            if p.contains('-') || p.contains(':') {
                port_ranges.push(p.replace('-', ":"));
            } else if let Ok(num) = p.parse::<u16>() {
                exact_ports.push(num);
            }
        }
        if !exact_ports.is_empty() {
            r.insert("port".into(), json!(exact_ports));
        }
        if !port_ranges.is_empty() {
            r.insert("port_range".into(), json!(port_ranges));
        }
    }
    if !cond.l4_proto.is_empty() {
        r.insert("network".into(), json!(cond.l4_proto));
    }
    if !cond.time_window.is_empty() {
        r.insert("time_window".into(), json!(cond.time_window));
    }
    if r.is_empty() {
        return None;
    }
    r.insert("outbound".into(), json!(outbound_tag));
    Some(Value::Object(r))
}

fn build_inbound_server(srv: &InboundServer) -> Option<Value> {
    if srv.protocol == "json_inbound" && !srv.inbound_json.trim().is_empty() {
        return serde_json::from_str::<Value>(&srv.inbound_json).ok();
    }
    let tag = format!("srv-{}", srv.id);
    let tls_obj = if srv.security == "reality" {
        Some(json!({
            "enabled": true,
            "server_name": srv.tls_server_name,
            "reality": {
                "enabled": true,
                "handshake": {
                    "server": srv.reality_handshake_server,
                    "server_port": srv.reality_handshake_server_port.max(443)
                },
                "private_key": srv.reality_private_key,
                "short_id": [srv.reality_short_id]
            }
        }))
    } else if srv.security == "tls" {
        Some(json!({
            "enabled": true,
            "server_name": srv.tls_server_name,
            "certificate_path": srv.tls_certificate_path,
            "key_path": srv.tls_key_path,
            "alpn": if srv.tls_alpn.is_empty() { vec!["h2".to_string(), "http/1.1".to_string()] } else { srv.tls_alpn.clone() }
        }))
    } else {
        None
    };

    match srv.protocol.as_str() {
        "vless" => {
            let mut obj = json!({
                "type": "vless",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "name": srv.label,
                    "uuid": srv.server_uuid,
                    "flow": if srv.vless_flow == "none" { "" } else { &srv.vless_flow }
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "vmess" => {
            let mut obj = json!({
                "type": "vmess",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "name": srv.label,
                    "uuid": srv.server_uuid,
                    "alterId": 0
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "trojan" => {
            let mut obj = json!({
                "type": "trojan",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "name": srv.label,
                    "password": srv.password
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "shadowsocks" | "ss" => Some(json!({
            "type": "shadowsocks",
            "tag": tag,
            "listen": srv.listen,
            "listen_port": srv.listen_port,
            "method": if srv.method.is_empty() { "aes-128-gcm" } else { &srv.method },
            "password": srv.password
        })),
        "hysteria2" => {
            let mut obj = json!({
                "type": "hysteria2",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "name": srv.label,
                    "password": srv.password
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "tuic" => {
            let mut obj = json!({
                "type": "tuic",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "congestion_control": if srv.tuic_congestion_control.is_empty() { "bbr" } else { &srv.tuic_congestion_control },
                "users": [{
                    "name": srv.label,
                    "uuid": srv.server_uuid,
                    "password": srv.password
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "anytls" => {
            let mut obj = json!({
                "type": "anytls",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "users": [{
                    "name": srv.label,
                    "password": srv.password
                }],
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "shadowtls" => Some(json!({
            "type": "shadowtls",
            "tag": tag,
            "listen": srv.listen,
            "listen_port": srv.listen_port,
            "version": srv.shadowtls_version.max(3),
            "users": [{
                "name": srv.label,
                "password": srv.password
            }],
            "handshake": {
                "server": if srv.shadowtls_handshake_server.is_empty() { "www.microsoft.com" } else { &srv.shadowtls_handshake_server },
                "server_port": srv.shadowtls_handshake_server_port.max(443)
            }
        })),
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
            Some(obj)
        }
        "tewfai" => {
            let mut obj = json!({
                "type": "tewfai",
                "tag": tag,
                "listen": srv.listen,
                "listen_port": srv.listen_port,
                "uuid": if srv.tewfai_uuid.is_empty() { &srv.server_uuid } else { &srv.tewfai_uuid },
                "password": if srv.tewfai_password.is_empty() { &srv.password } else { &srv.tewfai_password },
                "transport": if srv.tewfai_inbound_transport.is_empty() { "quic" } else { &srv.tewfai_inbound_transport },
                "inner_cipher": if srv.tewfai_inner_cipher.is_empty() { "aes-256-gcm" } else { &srv.tewfai_inner_cipher },
                "shaper_profile": if srv.tewfai_shaper_profile.is_empty() { "adaptive" } else { &srv.tewfai_shaper_profile },
                "morph_profile": if srv.tewfai_morph_profile.is_empty() { "auto" } else { &srv.tewfai_morph_profile },
            });
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "mieru" | "fptn" | "trusttunnel" | "masque" | "openconnect" => {
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
            if let Some(tls) = tls_obj {
                obj["tls"] = tls;
            }
            Some(obj)
        }
        "awg" | "wireguard" => Some(json!({
            "type": "wireguard",
            "tag": tag,
            "listen": srv.listen,
            "listen_port": srv.listen_port,
            "private_key": srv.awg_private_key,
            "local_address": [if srv.awg_local_address.is_empty() { "10.8.0.1/24" } else { &srv.awg_local_address }],
            "mtu": srv.awg_mtu.max(1280),
            "jc": srv.awg_jc,
            "jmin": srv.awg_jmin,
            "jmax": srv.awg_jmax,
            "s1": srv.awg_s1,
            "s2": srv.awg_s2,
            "h1": srv.awg_h1,
            "h2": srv.awg_h2,
            "h3": srv.awg_h3,
            "h4": srv.awg_h4,
        })),
        "mtproto" => Some(json!({
            "type": "mtproto",
            "tag": tag,
            "listen": srv.listen,
            "listen_port": srv.listen_port,
            "secret": srv.mtproto_secret,
            "faketls_domain": srv.mtproto_faketls
        })),
        "mixed" | "socks" | "http" => Some(json!({
            "type": srv.protocol,
            "tag": tag,
            "listen": srv.listen,
            "listen_port": srv.listen_port
        })),
        _ => None,
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
                "aid": "0",
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
            format!(
                "hysteria2://{}@{host}:{port}?sni={sni}&insecure=1#{label}",
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
        "naive" => {
            let user = if srv.server_username.is_empty() {
                label.as_str()
            } else {
                &srv.server_username
            };
            format!(
                "naive+https://{user}:{}@{host}:{port}#{label}",
                srv.password
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
        "awg" | "wireguard" => {
            format!(
                "awg://{}@{host}:{port}?publickey={}&address={}&jc={}&jmin={}&jmax={}&s1={}&s2={}&h1={}&h2={}&h3={}&h4={}#{label}",
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
            "{}://{}:{}@{host}:{port}#{label}",
            srv.protocol,
            if srv.server_username.is_empty() {
                &srv.label
            } else {
                &srv.server_username
            },
            srv.password
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
        lines.push(format!("H1 = {}", srv.awg_h1));
        lines.push(format!("H2 = {}", srv.awg_h2));
        lines.push(format!("H3 = {}", srv.awg_h3));
        lines.push(format!("H4 = {}", srv.awg_h4));
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
pub fn build_router_subscription_payload(
    store: &RouterStoreData,
    host_override: Option<&str>,
    format: &str,
) -> String {
    let uris: Vec<String> = store
        .servers
        .iter()
        .filter(|s| s.enabled)
        .map(|s| build_server_share_uri(s, host_override))
        .collect();
    let plain = uris.join("\n");
    if format.eq_ignore_ascii_case("plain") || format.eq_ignore_ascii_case("raw") {
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
        let cfg = compile_core_config(&store).expect("compile core config");
        let outbounds = cfg["outbounds"].as_array().unwrap();
        assert!(
            outbounds
                .iter()
                .any(|o| o["type"] == "desync" && o["auto_tune"] == true)
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
}
