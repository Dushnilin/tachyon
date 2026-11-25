//! Pure-Rust Tokio HTTP/1.1 client and JSON parsers for Keenetic NDMS RCI (`127.0.0.1:79`).

#![allow(dead_code)]

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const RCI_DEFAULT_PORT: u16 = 79;
const RCI_TIMEOUT: Duration = Duration::from_millis(1500);
const RCI_MAX_HEADER_BYTES: usize = 16 * 1024;
const RCI_MAX_BODY_BYTES: usize = 512 * 1024;
const RCI_MAX_HOTSPOT_ENTRIES: usize = 4096;
const RCI_MAX_INTERFACES: usize = 512;

/// Firmware and hardware metadata returned by Keenetic `/rci/show/version`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct KeeneticVersionInfo {
    pub model: String,
    pub release: String,
    pub ndms: String,
    pub hw_id: String,
}

/// LAN device entry returned by Keenetic `/rci/show/ip/hotspot`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct KeeneticHostEntry {
    pub ip: String,
    pub mac: String,
    pub name: String,
    pub interface: String,
    pub active: bool,
}

fn non_empty_str<'a>(val: &'a Value, key: &str) -> Option<&'a str> {
    val.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// Parse `/rci/show/version` JSON payload into `KeeneticVersionInfo`.
pub fn parse_rci_version_json(raw: &str) -> Option<KeeneticVersionInfo> {
    let parsed: Value = serde_json::from_str(raw).ok()?;
    let obj = parsed.as_object()?;

    let model = non_empty_str(&parsed, "model")
        .or_else(|| non_empty_str(&parsed, "device"))
        .or_else(|| non_empty_str(&parsed, "description"))
        .unwrap_or_default()
        .to_string();

    let release = non_empty_str(&parsed, "release")
        .or_else(|| non_empty_str(&parsed, "title"))
        .unwrap_or_default()
        .to_string();

    let ndms = parsed
        .pointer("/ndm/exact")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .or_else(|| non_empty_str(&parsed, "ndms"))
        .or_else(|| non_empty_str(&parsed, "release"))
        .unwrap_or_default()
        .to_string();

    let hw_id = non_empty_str(&parsed, "hw_id")
        .or_else(|| non_empty_str(&parsed, "hw_version"))
        .or_else(|| {
            obj.get("hw_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_default()
        .to_string();

    if model.is_empty() && release.is_empty() && ndms.is_empty() && hw_id.is_empty() {
        return None;
    }

    Some(KeeneticVersionInfo {
        model,
        release,
        ndms,
        hw_id,
    })
}

fn parse_single_host_entry(item: &Value) -> Option<KeeneticHostEntry> {
    let ip = non_empty_str(item, "ip").unwrap_or_default().to_string();
    let mac = non_empty_str(item, "mac")
        .unwrap_or_default()
        .to_ascii_lowercase();
    if ip.is_empty() && mac.is_empty() {
        return None;
    }

    let name = non_empty_str(item, "name")
        .or_else(|| non_empty_str(item, "hostname"))
        .unwrap_or_default()
        .to_string();

    let interface = match item.get("interface") {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Object(_)) => non_empty_str(item.get("interface")?, "name")
            .or_else(|| non_empty_str(item.get("interface")?, "id"))
            .unwrap_or_default()
            .to_string(),
        _ => String::new(),
    };

    let active = item
        .get("active")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| {
            item.get("link")
                .and_then(Value::as_str)
                .map(|s| s.eq_ignore_ascii_case("up"))
                .unwrap_or(false)
        });

    Some(KeeneticHostEntry {
        ip,
        mac,
        name,
        interface,
        active,
    })
}

/// Parse `/rci/show/ip/hotspot` JSON payload into LAN host entries.
/// Supports both `{"host": [...]}` objects and top-level arrays `[...]`.
pub fn parse_rci_hotspot_json(raw: &str) -> Vec<KeeneticHostEntry> {
    let Ok(parsed) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };
    let slice = if let Some(arr) = parsed.as_array() {
        arr.as_slice()
    } else if let Some(arr) = parsed.get("host").and_then(Value::as_array) {
        arr.as_slice()
    } else if let Some(arr) = parsed
        .pointer("/show/ip/hotspot/host")
        .and_then(Value::as_array)
    {
        arr.as_slice()
    } else {
        return Vec::new();
    };

    let mut out = Vec::with_capacity(slice.len().min(RCI_MAX_HOTSPOT_ENTRIES));
    for item in slice.iter().take(RCI_MAX_HOTSPOT_ENTRIES) {
        if let Some(entry) = parse_single_host_entry(item) {
            out.push(entry);
        }
    }
    out
}

/// Parse `/rci/show/interface` JSON payload into sorted, deduplicated interface identifiers.
pub fn parse_rci_interfaces_json(raw: &str) -> Vec<String> {
    let Ok(parsed) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };

    let mut out = Vec::new();
    match &parsed {
        Value::Object(map) => {
            for (key, val) in map.iter().take(RCI_MAX_INTERFACES) {
                let candidate = non_empty_str(val, "id").unwrap_or_else(|| key.trim());
                if !candidate.is_empty() && !out.iter().any(|existing| existing == candidate) {
                    out.push(candidate.to_string());
                }
            }
        }
        Value::Array(arr) => {
            for item in arr.iter().take(RCI_MAX_INTERFACES) {
                let candidate = match item {
                    Value::String(s) => s.trim(),
                    Value::Object(_) => non_empty_str(item, "id")
                        .or_else(|| non_empty_str(item, "interface-name"))
                        .or_else(|| non_empty_str(item, "name"))
                        .unwrap_or(""),
                    _ => "",
                };
                if !candidate.is_empty() && !out.iter().any(|existing| existing == candidate) {
                    out.push(candidate.to_string());
                }
            }
        }
        _ => {}
    }
    out
}

fn decode_chunked_body(raw: &[u8], max_bytes: usize) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut pos = 0usize;

    loop {
        let rest = raw.get(pos..)?;
        let line_end = rest.windows(2).position(|w| w == b"\r\n")?;
        let size_line = std::str::from_utf8(&rest[..line_end]).ok()?;
        let size_hex = size_line.split(';').next()?.trim();
        let chunk_len = usize::from_str_radix(size_hex, 16).ok()?;
        pos = pos.checked_add(line_end)?.checked_add(2)?;

        if chunk_len == 0 {
            return Some(out);
        }
        let next_total = out.len().checked_add(chunk_len)?;
        if next_total > max_bytes {
            return None;
        }
        let data_end = pos.checked_add(chunk_len)?;
        let chunk_slice = raw.get(pos..data_end)?;
        out.extend_from_slice(chunk_slice);
        pos = data_end;

        if raw.get(pos..pos.checked_add(2)?) != Some(b"\r\n") {
            return None;
        }
        pos = pos.checked_add(2)?;
    }
}

fn parse_http_response(raw: &[u8], max_body_bytes: usize) -> Option<String> {
    let header_end = raw.windows(4).position(|w| w == b"\r\n\r\n")?;
    if header_end > RCI_MAX_HEADER_BYTES {
        return None;
    }
    let header_text = std::str::from_utf8(&raw[..header_end]).ok()?;
    let mut lines = header_text.split("\r\n");
    let status_line = lines.next()?;
    let mut status_parts = status_line.split_whitespace();
    let http_ver = status_parts.next()?;
    let status_code = status_parts.next()?;
    if !http_ver.starts_with("HTTP/1.") || status_code != "200" {
        return None;
    }

    let mut is_chunked = false;
    let mut content_length: Option<usize> = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("transfer-encoding")
            && value.to_ascii_lowercase().contains("chunked")
        {
            is_chunked = true;
        } else if name.eq_ignore_ascii_case("content-length")
            && let Ok(len) = value.trim().parse::<usize>()
        {
            content_length = Some(len);
        }
    }

    let body_raw = raw.get(header_end + 4..)?;
    let body_bytes: Vec<u8> = if is_chunked {
        decode_chunked_body(body_raw, max_body_bytes)?
    } else {
        if let Some(expected_len) = content_length
            && expected_len > max_body_bytes
        {
            return None;
        }
        if body_raw.len() > max_body_bytes {
            return None;
        }
        let slice = match content_length {
            Some(expected_len) if expected_len <= body_raw.len() => &body_raw[..expected_len],
            _ => body_raw,
        };
        slice.to_vec()
    };

    String::from_utf8(body_bytes).ok()
}

fn inspect_expected_total_len(buf: &[u8]) -> Option<Result<Option<usize>, ()>> {
    let header_end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    if header_end > RCI_MAX_HEADER_BYTES {
        return Some(Err(()));
    }
    let header_text = std::str::from_utf8(&buf[..header_end]).ok()?;
    let mut is_chunked = false;
    let mut content_length: Option<usize> = None;
    for line in header_text.split("\r\n").skip(1) {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("transfer-encoding")
            && value.to_ascii_lowercase().contains("chunked")
        {
            is_chunked = true;
        } else if name.eq_ignore_ascii_case("content-length")
            && let Ok(len) = value.trim().parse::<usize>()
        {
            content_length = Some(len);
        }
    }
    if !is_chunked && let Some(cl) = content_length {
        if cl > RCI_MAX_BODY_BYTES {
            return Some(Err(()));
        }
        let total = header_end.checked_add(4)?.checked_add(cl)?;
        return Some(Ok(Some(total)));
    }
    Some(Ok(None))
}

async fn fetch_rci_get_from(addr: SocketAddr, path: &str) -> Option<String> {
    let max_wire_bytes = RCI_MAX_HEADER_BYTES + RCI_MAX_BODY_BYTES + 4;
    let fut = async move {
        let mut stream = TcpStream::connect(addr).await.ok()?;
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: {}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
            addr
        );
        stream.write_all(req.as_bytes()).await.ok()?;
        stream.flush().await.ok()?;

        let mut buf = Vec::with_capacity(4096);
        let mut chunk = [0u8; 4096];
        let mut headers_parsed = false;
        let mut expected_total: Option<usize> = None;
        loop {
            let n = stream.read(&mut chunk).await.ok()?;
            if n == 0 {
                break;
            }
            if buf.len().checked_add(n)? > max_wire_bytes {
                return None;
            }
            buf.extend_from_slice(&chunk[..n]);
            if !headers_parsed {
                match inspect_expected_total_len(&buf) {
                    Some(Ok(total)) => {
                        headers_parsed = true;
                        expected_total = total;
                    }
                    Some(Err(())) => return None,
                    None if buf.len() > RCI_MAX_HEADER_BYTES + 4 => return None,
                    None => {}
                }
            }
            if let Some(total) = expected_total
                && buf.len() >= total
            {
                break;
            }
        }
        parse_http_response(&buf, RCI_MAX_BODY_BYTES)
    };

    tokio::time::timeout(RCI_TIMEOUT, fut).await.ok().flatten()
}

fn rci_default_addr() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), RCI_DEFAULT_PORT)
}

/// Query Keenetic local RCI `/rci/show/version`.
pub async fn fetch_rci_version() -> Option<KeeneticVersionInfo> {
    let raw = fetch_rci_get_from(rci_default_addr(), "/rci/show/version").await?;
    parse_rci_version_json(&raw)
}

/// Query Keenetic local RCI `/rci/show/ip/hotspot`.
pub async fn fetch_rci_hotspot_devices() -> Vec<KeeneticHostEntry> {
    match fetch_rci_get_from(rci_default_addr(), "/rci/show/ip/hotspot").await {
        Some(raw) => parse_rci_hotspot_json(&raw),
        None => Vec::new(),
    }
}

/// Query Keenetic local RCI `/rci/show/interface`.
pub async fn fetch_rci_interfaces() -> Vec<String> {
    match fetch_rci_get_from(rci_default_addr(), "/rci/show/interface").await {
        Some(raw) => parse_rci_interfaces_json(&raw),
        None => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[test]
    fn test_parse_rci_version_json_real_payload() {
        let raw = r#"{
            "release": "4.2.3",
            "sandbox": "stable",
            "title": "4.2.3",
            "ndm": {
                "exact": "0-4.2.3",
                "cdate": "01 Jan 2025"
            },
            "model": "Ultra (KN-1811)",
            "hw_version": "18110000",
            "hw_id": "KN-1811",
            "device": "Keenetic Ultra"
        }"#;
        let info = parse_rci_version_json(raw).expect("version parsed");
        assert_eq!(info.model, "Ultra (KN-1811)");
        assert_eq!(info.release, "4.2.3");
        assert_eq!(info.ndms, "0-4.2.3");
        assert_eq!(info.hw_id, "KN-1811");

        assert!(parse_rci_version_json("{}").is_none());
        assert!(parse_rci_version_json("not-json").is_none());
    }

    #[test]
    fn test_parse_rci_hotspot_json_object_and_array() {
        let raw_obj = r#"{
            "host": [
                {
                    "mac": "AA:BB:CC:DD:EE:01",
                    "ip": "192.168.1.42",
                    "hostname": "workstation",
                    "name": "Office PC",
                    "interface": {
                        "id": "Bridge0",
                        "name": "Home"
                    },
                    "active": true
                },
                {
                    "mac": "AA:BB:CC:DD:EE:02",
                    "ip": "192.168.1.55",
                    "hostname": "printer",
                    "interface": "br0",
                    "active": false
                }
            ]
        }"#;
        let hosts = parse_rci_hotspot_json(raw_obj);
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0].ip, "192.168.1.42");
        assert_eq!(hosts[0].mac, "aa:bb:cc:dd:ee:01");
        assert_eq!(hosts[0].name, "Office PC");
        assert_eq!(hosts[0].interface, "Home");
        assert!(hosts[0].active);
        assert_eq!(hosts[1].name, "printer");
        assert_eq!(hosts[1].interface, "br0");
        assert!(!hosts[1].active);

        let raw_arr = r#"[
            {"mac": "11:22:33:44:55:66", "ip": "192.168.1.99", "name": "Phone", "active": true}
        ]"#;
        let hosts_arr = parse_rci_hotspot_json(raw_arr);
        assert_eq!(hosts_arr.len(), 1);
        assert_eq!(hosts_arr[0].ip, "192.168.1.99");
        assert_eq!(hosts_arr[0].name, "Phone");
    }

    #[test]
    fn test_parse_rci_interfaces_json_map_and_array() {
        let raw_map = r#"{
            "Bridge0": {
                "id": "Bridge0",
                "interface-name": "Home",
                "type": "Bridge",
                "state": "up"
            },
            "ISP": {
                "id": "ISP",
                "type": "Ethernet",
                "state": "up"
            },
            "Wireguard0": {
                "type": "Wireguard",
                "state": "up"
            }
        }"#;
        let ifaces = parse_rci_interfaces_json(raw_map);
        assert_eq!(ifaces, vec!["Bridge0", "ISP", "Wireguard0"]);

        let raw_arr = r#"[{"id":"Bridge0"},{"interface-name":"Guest"},"ISP"]"#;
        let ifaces_arr = parse_rci_interfaces_json(raw_arr);
        assert_eq!(ifaces_arr, vec!["Bridge0", "Guest", "ISP"]);
    }

    #[tokio::test]
    async fn test_fetch_rci_http_client_content_length_chunked_and_limit() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let server = tokio::spawn(async move {
            // 1. Standard 200 OK with Content-Length
            {
                let (mut s1, _) = listener.accept().await.unwrap();
                let mut req_buf = [0u8; 512];
                let _ = s1.read(&mut req_buf).await;
                let body = r#"{"model":"Peak (KN-2710)","release":"4.2.1","hw_id":"KN-2710"}"#;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = s1.write_all(resp.as_bytes()).await;
                let _ = s1.shutdown().await;
            }

            // 2. Chunked 200 OK
            {
                let (mut s2, _) = listener.accept().await.unwrap();
                let mut req_buf = [0u8; 512];
                let _ = s2.read(&mut req_buf).await;
                let chunk_part = r#"{"Bridge0":{"id":"Bridge0"}}"#;
                let resp2 = format!(
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\n",
                    chunk_part.len(),
                    chunk_part
                );
                let _ = s2.write_all(resp2.as_bytes()).await;
                let _ = s2.shutdown().await;
            }

            // 3. Oversized body (> 512 KiB) must be rejected
            {
                let (mut s3, _) = listener.accept().await.unwrap();
                let mut req_buf = [0u8; 512];
                let _ = s3.read(&mut req_buf).await;
                let huge = "a".repeat(RCI_MAX_BODY_BYTES + 1024);
                let resp3 = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    huge.len(),
                    huge
                );
                let _ = s3.write_all(resp3.as_bytes()).await;
                let _ = s3.shutdown().await;
            }
        });

        let raw1 = fetch_rci_get_from(addr, "/rci/show/version")
            .await
            .expect("first response");
        let ver = parse_rci_version_json(&raw1).expect("parsed version");
        assert_eq!(ver.model, "Peak (KN-2710)");

        let raw2 = fetch_rci_get_from(addr, "/rci/show/interface")
            .await
            .expect("chunked response");
        assert_eq!(parse_rci_interfaces_json(&raw2), vec!["Bridge0"]);

        let raw3 = fetch_rci_get_from(addr, "/rci/show/huge").await;
        assert!(raw3.is_none());

        server.await.unwrap();
    }
}
