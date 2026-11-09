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

/// NAND-wear-safe atomic file writer (`content_unchanged` check + `.tmp` + `rename`).
/// Returns `Ok(true)` if the file was modified on disk, or `Ok(false)` if skipped because identical.
pub fn write_file_if_changed(path: impl AsRef<Path>, new_bytes: &[u8]) -> anyhow::Result<bool> {
    let path = path.as_ref();
    if content_unchanged(path, new_bytes) {
        return Ok(false);
    }
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let tmp_path = path.with_extension("tmp");
    std::fs::write(&tmp_path, new_bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp_path, path)?;
    Ok(true)
}

/// Serialize a value to pretty JSON and write it atomically only if content changed.
pub fn write_json_if_changed<T: Serialize>(
    path: impl AsRef<Path>,
    value: &T,
) -> anyhow::Result<bool> {
    let raw = serde_json::to_vec_pretty(value)?;
    write_file_if_changed(path, &raw)
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
            "proxy": "trojan://my_pass@example.com:443"
        });
        let rj = redact_json_value(&j);
        assert_eq!(rj["ai_doctor_api_key"], "[REDACTED]");
        assert_eq!(rj["label"], "My Section");
        assert_eq!(rj["proxy"], "trojan://[REDACTED]@example.com:443");
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
}
