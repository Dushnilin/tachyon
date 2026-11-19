//! Pure-Rust cryptographic generators, secret redaction, and NAND-safe atomic file writers.

use std::path::Path;

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD as B64_STD, URL_SAFE_NO_PAD as B64_URL};
use rand::RngCore;
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

#[derive(Debug, Clone, Serialize)]
pub struct X25519Keypair {
    pub private_key: String,
    pub public_key: String,
}

/// Generate a RFC 4122 UUIDv4 string.
pub fn generate_uuid_v4() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15]
    )
}

/// Encode bytes to lowercase hex without per-byte heap allocations.
pub fn bytes_to_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

/// Constant-time string equality check for secrets, tokens, and password hashes.
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn generate_x25519_raw() -> ([u8; 32], [u8; 32]) {
    let mut raw = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let secret = StaticSecret::from(raw);
    let public = PublicKey::from(&secret);
    (secret.to_bytes(), *public.as_bytes())
}

/// Generate an X25519 keypair in URL-safe base64 without padding (used by REALITY).
pub fn generate_reality_keypair() -> X25519Keypair {
    let (priv_b, pub_b) = generate_x25519_raw();
    X25519Keypair {
        private_key: B64_URL.encode(priv_b),
        public_key: B64_URL.encode(pub_b),
    }
}

/// Generate an X25519 keypair in standard base64 with padding (used by WireGuard / AmneziaWG).
pub fn generate_wg_keypair() -> X25519Keypair {
    let (priv_b, pub_b) = generate_x25519_raw();
    X25519Keypair {
        private_key: B64_STD.encode(priv_b),
        public_key: B64_STD.encode(pub_b),
    }
}

/// Generate a Shadowsocks-2022 base64 PSK (16 bytes for aes-128-gcm, 32 bytes for 256/chacha20).
pub fn generate_ss2022_key(method: &str) -> String {
    let len = if method.contains("128") { 16 } else { 32 };
    let mut buf = vec![0u8; len];
    rand::thread_rng().fill_bytes(&mut buf);
    B64_STD.encode(&buf)
}

/// Generate a random hex `short_id` for REALITY (8 hex chars = 4 bytes by default).
pub fn generate_short_id(byte_len: usize) -> String {
    generate_hex(byte_len.clamp(1, 8))
}

/// Generate an alphanumeric token (used for subscription IDs, passwords, session tokens).
pub fn generate_alnum(len: usize) -> String {
    const CHARSET: &[u8] = b"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut buf = vec![0u8; len];
    rand::thread_rng().fill_bytes(&mut buf);
    buf.into_iter()
        .map(|b| CHARSET[(b as usize) % CHARSET.len()] as char)
        .collect()
}

/// Generate a hex string of `byte_len` random bytes.
pub fn generate_hex(byte_len: usize) -> String {
    let mut buf = vec![0u8; byte_len];
    rand::thread_rng().fill_bytes(&mut buf);
    bytes_to_hex(&buf)
}

/// Salted PBKDF-like iterated SHA-256 password hash (pure Rust, zero external C deps).
pub fn hash_password(password: &str, salt: &str) -> String {
    let mut acc = [0u8; 32];
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(b":");
    hasher.update(password.as_bytes());
    acc.copy_from_slice(&hasher.finalize());
    for round in 0..10_000u32 {
        let mut h = Sha256::new();
        h.update(acc);
        h.update(round.to_le_bytes());
        h.update(salt.as_bytes());
        acc.copy_from_slice(&h.finalize());
    }
    bytes_to_hex(&acc)
}

pub fn verify_password(password: &str, salt: &str, expected_hex: &str) -> bool {
    let actual = hash_password(password, salt);
    constant_time_eq(&actual, expected_hex)
}

/// Check if a JSON/UCI field key holds sensitive credentials that must be scrubbed.
pub fn is_sensitive_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    k.contains("password")
        || k.contains("pass_hash")
        || k.contains("pass_salt")
        || k.contains("secret")
        || k.contains("private_key")
        || k.contains("preshared_key")
        || k.contains("api_key")
        || k.contains("bot_token")
        || k.contains("auth_key")
        || k.contains("token")
        || k.contains("uuid")
}

/// Redact inline URI credentials, UUIDs, and tokens from free-form text or logs.
pub fn redact_string(input: &str) -> String {
    let mut out = input.to_string();
    for scheme in [
        "vless://",
        "vmess://",
        "trojan://",
        "ss://",
        "hysteria2://",
        "hy2://",
        "tuic://",
        "mierus://",
        "mieru://",
        "wg://",
        "awg://",
        "fptn://",
    ] {
        let mut search_from = 0;
        while let Some(pos) = out[search_from..].find(scheme) {
            let start = search_from + pos + scheme.len();
            if let Some(at_rel) = out[start..].find('@') {
                let at_idx = start + at_rel;
                let line_end = out[start..]
                    .find(char::is_whitespace)
                    .unwrap_or(out.len() - start)
                    + start;
                if at_idx < line_end {
                    out.replace_range(start..at_idx, "[REDACTED]");
                    search_from = start + "[REDACTED]".len() + 1;
                    continue;
                }
            }
            search_from = start;
        }
    }
    out
}

/// Deep-clone and scrub a JSON value so LLMs, support bundles, and public logs never see secrets.
pub fn redact_json_value(val: &Value) -> Value {
    match val {
        Value::Object(map) => {
            let mut out = serde_json::Map::with_capacity(map.len());
            for (k, v) in map {
                if is_sensitive_key(k) {
                    if let Value::String(s) = v {
                        if s.is_empty() {
                            out.insert(k.clone(), Value::String(String::new()));
                        } else {
                            out.insert(k.clone(), Value::String("[REDACTED]".to_string()));
                        }
                    } else {
                        out.insert(k.clone(), Value::String("[REDACTED]".to_string()));
                    }
                } else {
                    out.insert(k.clone(), redact_json_value(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(arr) => Value::Array(arr.iter().map(redact_json_value).collect()),
        Value::String(s) => Value::String(redact_string(s)),
        other => other.clone(),
    }
}

/// Check if an existing file on disk already has identical byte content (fast size pre-check).
pub fn content_unchanged(path: &Path, new_bytes: &[u8]) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if meta.len() != new_bytes.len() as u64 {
        return false;
    }
    let Ok(existing) = std::fs::read(path) else {
        return false;
    };
    existing == new_bytes
}

/// NAND-wear-safe atomic file writer with explicit Unix permission mode (`content_unchanged` check + `.tmp` + `rename`).
/// If the file already exists with identical bytes but a different Unix mode, updates permissions in place without rewriting content.
pub fn write_bytes_with_mode_if_changed(
    path: impl AsRef<Path>,
    new_bytes: &[u8],
    mode: u32,
) -> anyhow::Result<bool> {
    let path = path.as_ref();
    if content_unchanged(path, new_bytes) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = std::fs::metadata(path)
                && (meta.permissions().mode() & 0o777) != (mode & 0o777)
            {
                let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
            }
        }
        let _ = mode;
        return Ok(false);
    }
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let base_name = path
        .file_name()
        .map(|s| s.to_string_lossy())
        .unwrap_or_else(|| "file".into());
    let tmp_path = path.with_file_name(format!(".{base_name}.tmp.{}", std::process::id()));
    std::fs::write(&tmp_path, new_bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(mode));
    }
    std::fs::rename(&tmp_path, path)?;
    Ok(true)
}

/// String wrapper around `write_bytes_with_mode_if_changed` returning `std::io::Result<bool>`.
pub fn write_file_with_mode_if_changed(
    path: &Path,
    content: &str,
    mode: u32,
) -> std::io::Result<bool> {
    write_bytes_with_mode_if_changed(path, content.as_bytes(), mode).map_err(std::io::Error::other)
}

/// NAND-wear-safe atomic file writer (`content_unchanged` check + `.tmp` + `rename`).
/// Returns `Ok(true)` if the file was modified on disk, or `Ok(false)` if skipped because identical.
pub fn write_file_if_changed(path: impl AsRef<Path>, new_bytes: &[u8]) -> anyhow::Result<bool> {
    if content_unchanged(path.as_ref(), new_bytes) {
        return Ok(false);
    }
    write_bytes_with_mode_if_changed(path, new_bytes, 0o600)
}

/// Compute lowercase SHA-256 hex digest of a byte slice.
pub fn sha256_bytes_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    bytes_to_hex(&hasher.finalize())
}

/// Auto-generate cryptographic keys, ports, SNI, and obfuscation defaults for any of the 22 inbound server protocols.
pub fn auto_configure_server(protocol: &str) -> Value {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let proto = protocol.trim().to_ascii_lowercase();
    let random_port: u16 = rng.gen_range(20000..=55000);
    let uuid = generate_uuid_v4();
    let password = generate_alnum(22);

    match proto.as_str() {
        "vless" => {
            let kp = generate_reality_keypair();
            let sid = generate_short_id(4);
            serde_json::json!({
                "protocol": "vless",
                "listen_port": 443,
                "security": "reality",
                "vless_flow": "xtls-rprx-vision",
                "server_uuid": uuid,
                "reality_handshake_server": "www.microsoft.com",
                "reality_handshake_server_port": 443,
                "reality_private_key": kp.private_key,
                "reality_public_key": kp.public_key,
                "reality_short_id": sid,
                "client_fingerprint": "chrome",
                "transport": "tcp"
            })
        }
        "shadowsocks" | "ss" => {
            let method = "2022-blake3-aes-128-gcm";
            let psk = generate_ss2022_key(method);
            serde_json::json!({
                "protocol": "shadowsocks",
                "listen_port": random_port,
                "method": method,
                "shadowsocks_method": method,
                "password": psk,
                "server_password": psk
            })
        }
        "awg" | "wireguard" => {
            let srv_kp = generate_wg_keypair();
            let cli_kp = generate_wg_keypair();
            let psk = generate_wg_keypair().private_key;
            let jc: u16 = rng.gen_range(4..=8);
            let jmin: u16 = rng.gen_range(35..=55);
            let jmax: u16 = jmin + rng.gen_range(30..=60);
            let s1: u16 = rng.gen_range(15..=45);
            let s2: u16 = rng.gen_range(46..=95);
            let h1: u32 = rng.gen_range(100_000_000..=500_000_000);
            let h2: u32 = rng.gen_range(500_000_001..=1_000_000_000);
            let h3: u32 = rng.gen_range(1_000_000_001..=1_500_000_000);
            let h4: u32 = rng.gen_range(1_500_000_001..=2_000_000_000);
            serde_json::json!({
                "protocol": proto,
                "listen_port": random_port,
                "awg_version": "2.0",
                "awg_mtu": 1280,
                "awg_local_address": "10.8.0.1/24",
                "awg_client_address": "10.8.0.2/32",
                "awg_dns": "1.1.1.1",
                "awg_private_key": srv_kp.private_key,
                "awg_server_public_key": srv_kp.public_key,
                "awg_client_private_key": cli_kp.private_key,
                "awg_peer_public_key": cli_kp.public_key,
                "awg_preshared_key": psk,
                "awg_jc": jc,
                "awg_jmin": jmin,
                "awg_jmax": jmax,
                "awg_s1": s1,
                "awg_s2": s2,
                "awg_h1": h1,
                "awg_h2": h2,
                "awg_h3": h3,
                "awg_h4": h4,
                "awg_keepalive": 25
            })
        }
        "mtproto" => {
            let faketls_host = "www.google.com";
            let secret = format!(
                "ee{}{}",
                generate_hex(16),
                bytes_to_hex(faketls_host.as_bytes())
            );
            serde_json::json!({
                "protocol": "mtproto",
                "listen_port": 443,
                "mtproto_secret": secret,
                "mtproto_faketls": faketls_host,
                "mtproto_padding": true,
                "mtproto_tolerate_time_skewness": true
            })
        }
        "hysteria2" | "hy2" => {
            let obfs_pw = generate_alnum(18);
            serde_json::json!({
                "protocol": "hysteria2",
                "listen_port": random_port,
                "security": "tls",
                "password": password,
                "server_password": password,
                "hysteria2_obfs_type": "salamander",
                "hysteria2_obfs_password": obfs_pw,
                "hysteria2_up_mbps": 100,
                "hysteria2_down_mbps": 100
            })
        }
        "tuic" => serde_json::json!({
            "protocol": "tuic",
            "listen_port": random_port,
            "security": "tls",
            "server_uuid": uuid,
            "password": password,
            "server_password": password,
            "tuic_congestion_control": "bbr"
        }),
        "tewfai" => serde_json::json!({
            "protocol": "tewfai",
            "listen_port": random_port,
            "tewfai_uuid": uuid,
            "tewfai_password": password,
            "tewfai_inbound_transport": "quic",
            "tewfai_inner_cipher": "aes-256-gcm",
            "tewfai_shaper_profile": "adaptive",
            "tewfai_morph_profile": "auto",
            "tewfai_pqc_enabled": true
        }),
        "wdtt" => serde_json::json!({
            "protocol": "wdtt",
            "listen_port": 46000,
            "password": password,
            "server_password": password,
            "wdtt_mode": "csqtt",
            "wdtt_obfs": "audio",
            "wdtt_network": "10.66.0.1/16",
            "wdtt_mtu": 1350
        }),
        "shadowtls" => serde_json::json!({
            "protocol": "shadowtls",
            "listen_port": 443,
            "password": password,
            "server_password": password,
            "shadowtls_version": 3,
            "shadowtls_handshake_server": "www.microsoft.com",
            "shadowtls_handshake_server_port": 443
        }),
        "tailscale" => serde_json::json!({
            "protocol": "tailscale",
            "listen_port": 0,
            "open_firewall_port": false,
            "tailscale_mode": "singbox",
            "tailscale_control_url": "https://controlplane.tailscale.com",
            "tailscale_hostname": "tachyon-router",
            "tailscale_advertise_exit_node": true,
            "tailscale_accept_dns": true,
            "tailscale_accept_default_resolvers": true,
            "tailscale_ephemeral": false,
            "tailscale_exit_node_allow_lan_access": false,
            "tailscale_auto_firewall": true
        }),
        _ => serde_json::json!({
            "protocol": proto,
            "listen_port": random_port,
            "server_uuid": uuid,
            "server_username": "tachyon",
            "password": password,
            "server_password": password
        }),
    }
}

/// Serialize a value to pretty JSON and write it atomically only if content changed.
pub fn write_json_if_changed<T: Serialize>(
    path: impl AsRef<Path>,
    value: &T,
) -> anyhow::Result<bool> {
    let raw = serde_json::to_vec_pretty(value)?;
    write_file_if_changed(path, &raw)
}

/// Extract and Base64-decode the first X.509 certificate block from PEM bytes into DER.
pub fn pem_certificate_to_der(pem: &[u8]) -> Option<Vec<u8>> {
    let text = std::str::from_utf8(pem).ok()?;
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let start = text.find(BEGIN)? + BEGIN.len();
    let end = text[start..].find(END)?;
    let b64: String = text[start..start + end]
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    if b64.is_empty() {
        return None;
    }
    B64_STD.decode(b64.as_bytes()).ok()
}

/// Pure-Rust RFC 1321 MD5 message digest (used only for TLS certificate pin compatibility).
pub fn md5_hex(data: &[u8]) -> String {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];

    let mut msg = Vec::with_capacity(((data.len() + 8) / 64 + 1) * 64);
    msg.extend_from_slice(data);
    msg.push(0x80);
    while (msg.len() % 64) != 56 {
        msg.push(0);
    }
    let bit_len = (data.len() as u64).wrapping_mul(8);
    msg.extend_from_slice(&bit_len.to_le_bytes());

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    for chunk in msg.as_chunks::<64>().0 {
        let mut m = [0u32; 16];
        for (i, w) in chunk.as_chunks::<4>().0.iter().enumerate() {
            m[i] = u32::from_le_bytes(*w);
        }
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = if i < 16 {
                ((b & c) | ((!b) & d), i)
            } else if i < 32 {
                ((d & b) | ((!d) & c), (5 * i + 1) % 16)
            } else if i < 48 {
                (b ^ c ^ d, (3 * i + 5) % 16)
            } else {
                (c ^ (b | (!d)), (7 * i) % 16)
            };
            let temp = d;
            d = c;
            c = b;
            let sum = a.wrapping_add(f).wrapping_add(K[i]).wrapping_add(m[g]);
            b = b.wrapping_add(sum.rotate_left(S[i]));
            a = temp;
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&a0.to_le_bytes());
    out[4..8].copy_from_slice(&b0.to_le_bytes());
    out[8..12].copy_from_slice(&c0.to_le_bytes());
    out[12..16].copy_from_slice(&d0.to_le_bytes());
    bytes_to_hex(&out)
}

/// Compute SHA-256 and MD5 fingerprints over X.509 DER bytes (decoding PEM if present).
pub fn cert_fingerprints_sha256_md5(pem_or_der: &[u8]) -> (String, String) {
    let der = pem_certificate_to_der(pem_or_der);
    let target = der.as_deref().unwrap_or(pem_or_der);
    let mut sha = Sha256::new();
    sha.update(target);
    (bytes_to_hex(&sha.finalize()), md5_hex(target))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_uuid_and_keys() {
        let u = generate_uuid_v4();
        assert_eq!(u.len(), 36);
        let r = generate_reality_keypair();
        assert_eq!(r.private_key.len(), 43);
        let wg = generate_wg_keypair();
        assert_eq!(wg.private_key.len(), 44);
    }

    #[test]
    fn test_redact_secrets() {
        let s =
            "node: vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?security=reality#Test";
        let scrubbed = redact_string(s);
        assert!(!scrubbed.contains("11111111-2222"));
        assert!(scrubbed.contains("vless://[REDACTED]@1.2.3.4:443"));

        let j = serde_json::json!({
            "ai_doctor_api_key": "sk-secret123",
            "label": "My Section",
            "proxy": "trojan://my_pass@example.com:443",
            "mieru_proxy": "mierus://testuser:supersecret@198.51.100.10?port=20100#Mieru"
        });
        let rj = redact_json_value(&j);
        assert_eq!(rj["ai_doctor_api_key"], "[REDACTED]");
        assert_eq!(rj["label"], "My Section");
        assert_eq!(rj["proxy"], "trojan://[REDACTED]@example.com:443");
        assert_eq!(
            rj["mieru_proxy"],
            "mierus://[REDACTED]@198.51.100.10?port=20100#Mieru"
        );
        assert!(!rj["mieru_proxy"].as_str().unwrap().contains("supersecret"));
    }

    #[test]
    fn test_nand_guard_write_if_changed() {
        let dir = std::env::temp_dir().join(format!("tachyon_test_{}", generate_hex(4)));
        let file = dir.join("config.json");
        let modified1 = write_file_if_changed(&file, b"{\"a\":1}").unwrap();
        assert!(modified1);
        let modified2 = write_file_if_changed(&file, b"{\"a\":1}").unwrap();
        assert!(!modified2);
        let modified3 = write_file_if_changed(&file, b"{\"a\":2}").unwrap();
        assert!(modified3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_auto_configure_server_protocols() {
        let vless = auto_configure_server("vless");
        assert_eq!(vless["security"], "reality");
        assert!(!vless["reality_private_key"].as_str().unwrap().is_empty());

        let ss = auto_configure_server("shadowsocks");
        assert_eq!(ss["method"], "2022-blake3-aes-128-gcm");
        assert!(!ss["password"].as_str().unwrap().is_empty());

        let awg = auto_configure_server("awg");
        assert_eq!(awg["awg_version"], "2.0");
        assert!(!awg["awg_private_key"].as_str().unwrap().is_empty());

        let mtp = auto_configure_server("mtproto");
        assert!(mtp["mtproto_secret"].as_str().unwrap().starts_with("ee"));
    }

    #[test]
    fn test_md5_and_pem_der_fingerprints() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");

        let pem = format!(
            "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n",
            B64_STD.encode(b"abc")
        );
        let der = pem_certificate_to_der(pem.as_bytes()).expect("PEM should decode");
        assert_eq!(der, b"abc");
        let (sha256, md5) = cert_fingerprints_sha256_md5(pem.as_bytes());
        assert_eq!(
            sha256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(md5, "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn test_auto_configure_server_tailscale() {
        let ts = auto_configure_server("tailscale");
        assert_eq!(ts["listen_port"], 0);
        assert_eq!(ts["open_firewall_port"], false);
        assert_eq!(ts["tailscale_mode"], "singbox");
        assert_eq!(ts["tailscale_hostname"], "tachyon-router");
        assert_eq!(
            ts["tailscale_control_url"],
            "https://controlplane.tailscale.com"
        );
    }
}
