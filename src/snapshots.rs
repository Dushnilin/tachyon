//! Native `tachyon-rs` configuration snapshots, profile import/export,
//! compact transfer codes (`tachyon://rs2/...`), factory reset, and streaming
//! binary version backup/rollback (`tachyon` & `tachyon-core`).
//!
//! 100% pure Rust, zero C/FFI crates, zero full-binary heap allocations,
//! and flash-wear safe via `crypto_gen::write_file_if_changed`.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD as B64_STD, URL_SAFE_NO_PAD as B64_URL};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::crypto_gen;
use crate::store::{AppState, RouterStoreData, unix_now_secs};
use crate::transaction;

pub const PROFILE_FORMAT: &str = "tachyon-profile-v1";
pub const PROFILE_ENGINE: &str = "tachyon-rs";
pub const MAX_IMPORT_BYTES: usize = 4 * 1024 * 1024;
pub const DEFAULT_MAX_SNAPSHOTS: usize = 10;

static LAST_EXPORT_ASCII_JSON: OnceLock<Mutex<String>> = OnceLock::new();
static IMPORT_STAGING_BYTES: OnceLock<Mutex<Vec<u8>>> = OnceLock::new();

fn export_buffer() -> &'static Mutex<String> {
    LAST_EXPORT_ASCII_JSON.get_or_init(|| Mutex::new(String::new()))
}

fn import_buffer() -> &'static Mutex<Vec<u8>> {
    IMPORT_STAGING_BYTES.get_or_init(|| Mutex::new(Vec::new()))
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotCounts {
    pub sections: usize,
    pub servers: usize,
    pub sources: usize,
    pub balancers: usize,
    pub conditions: usize,
    #[serde(default)]
    pub files: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct SnapshotComponent {
    pub id: String,
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TachyonProfileV1 {
    pub format: String,
    #[serde(default = "default_engine")]
    pub engine: String,
    #[serde(default = "default_version")]
    pub version: String,
    #[serde(default = "default_scope")]
    pub scope: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub stamp: String,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub counts: SnapshotCounts,
    #[serde(default)]
    pub section_names: Vec<String>,
    #[serde(default)]
    pub components: Vec<SnapshotComponent>,
    #[serde(default)]
    pub store_data: RouterStoreData,
    #[serde(default)]
    pub config_sections: Map<String, Value>,
    #[serde(default)]
    pub certs: BTreeMap<String, String>,
}

fn default_engine() -> String {
    PROFILE_ENGINE.to_string()
}

fn default_version() -> String {
    crate::store::TACHYON_VERSION.to_string()
}

fn default_scope() -> String {
    "full".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BinaryBackupMeta {
    pub component: String,
    pub version: String,
    pub sha256: String,
    pub size: u64,
    pub backed_up_at: i64,
}

pub fn data_dir_for_state(state: &AppState) -> PathBuf {
    state
        .path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/etc/tachyon"))
}

pub fn snapshots_dir(state: &AppState) -> PathBuf {
    data_dir_for_state(state).join("snapshots")
}

pub fn backups_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("backups")
}

fn certs_dir(state: &AppState) -> PathBuf {
    let local = data_dir_for_state(state).join("server-certs");
    if data_dir_for_state(state) != Path::new("/etc/tachyon") || !cfg!(target_os = "linux") {
        local
    } else {
        PathBuf::from("/etc/tachyon/server-certs")
    }
}

fn legacy_certs_dir(state: &AppState) -> PathBuf {
    let local = data_dir_for_state(state).join("certs");
    if local.exists() || !cfg!(target_os = "linux") {
        local
    } else {
        PathBuf::from("/etc/tachyon/certs")
    }
}

/// Convert Unix epoch seconds (UTC) into `YYYYMMDD-HHMMSS` using Howard Hinnant's civil calendar algorithm.
pub fn unix_secs_to_stamp(secs: i64) -> String {
    let t = secs.max(0);
    let days = t.div_euclid(86_400);
    let rem = t.rem_euclid(86_400);
    let hour = rem / 3600;
    let minute = (rem % 3600) / 60;
    let second = rem % 60;

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };

    format!("{year:04}{m:02}{d:02}-{hour:02}{minute:02}{second:02}")
}

fn sanitize_slug(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len().min(48));
    for ch in raw.trim().chars() {
        if out.len() >= 48 {
            break;
        }
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
        } else if ch.is_whitespace() || ch == '.' {
            out.push('_');
        }
    }
    let trimmed = out.trim_matches('_');
    if trimmed.is_empty() {
        "snapshot".to_string()
    } else {
        trimmed.to_string()
    }
}

fn sanitize_snapshot_filename(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.contains("..")
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains('\0')
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn compute_counts(
    store_data: &RouterStoreData,
    config_sections: &Map<String, Value>,
    certs_len: usize,
) -> (SnapshotCounts, Vec<String>) {
    let mut section_names: Vec<String> = store_data
        .sections
        .iter()
        .map(|s| {
            if s.label.trim().is_empty() {
                s.id.clone()
            } else {
                s.label.clone()
            }
        })
        .collect();

    let mut sec_cnt = store_data.sections.len();
    let mut srv_cnt = store_data.servers.len();
    let mut src_cnt = store_data.outbound_sources.len();
    let mut bal_cnt = store_data.balancers.len();
    let mut cond_cnt = store_data.conditions.len();

    if !config_sections.is_empty() {
        let mut cs_sec = 0usize;
        let mut cs_srv = 0usize;
        let mut cs_src = 0usize;
        let mut cs_bal = 0usize;
        let mut cs_cond = 0usize;
        let mut cs_names = Vec::new();
        for (k, v) in config_sections {
            let Some(obj) = v.as_object() else {
                continue;
            };
            match obj.get(".type").and_then(Value::as_str).unwrap_or("") {
                "section" => {
                    cs_sec += 1;
                    let label = obj
                        .get("name")
                        .and_then(Value::as_str)
                        .filter(|s| !s.trim().is_empty())
                        .unwrap_or(k.as_str());
                    cs_names.push(label.to_string());
                }
                "server" => cs_srv += 1,
                "outbound_source" => cs_src += 1,
                "balancer" => cs_bal += 1,
                "condition" => cs_cond += 1,
                _ => {}
            }
        }
        sec_cnt = sec_cnt.max(cs_sec);
        srv_cnt = srv_cnt.max(cs_srv);
        src_cnt = src_cnt.max(cs_src);
        bal_cnt = bal_cnt.max(cs_bal);
        cond_cnt = cond_cnt.max(cs_cond);
        if section_names.is_empty() {
            section_names = cs_names;
        }
    }

    (
        SnapshotCounts {
            sections: sec_cnt,
            servers: srv_cnt,
            sources: src_cnt,
            balancers: bal_cnt,
            conditions: cond_cnt,
            files: certs_len,
        },
        section_names,
    )
}

fn read_certs_from_dir(dir: &Path, map: &mut BTreeMap<String, String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
            continue;
        };
        if !matches!(ext, "crt" | "key" | "pem") {
            continue;
        }
        let Some(fname) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if map.contains_key(fname) {
            continue;
        }
        if let Ok(meta) = entry.metadata()
            && meta.len() <= 65_536
            && let Ok(content) = std::fs::read_to_string(&path)
        {
            map.insert(fname.to_string(), content);
        }
    }
}

fn collect_certs(state: &AppState) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    read_certs_from_dir(&certs_dir(state), &mut map);
    let legacy = legacy_certs_dir(state);
    if legacy != certs_dir(state) {
        read_certs_from_dir(&legacy, &mut map);
    }
    map
}

pub(crate) fn restore_certs(state: &AppState, certs: &BTreeMap<String, String>) -> usize {
    if certs.is_empty() {
        return 0;
    }
    let dir = certs_dir(state);
    let _ = std::fs::create_dir_all(&dir);
    let mut written = 0usize;
    for (fname, content) in certs {
        let Some(safe_name) = sanitize_snapshot_filename(fname) else {
            continue;
        };
        if !safe_name.ends_with(".crt")
            && !safe_name.ends_with(".key")
            && !safe_name.ends_with(".pem")
        {
            continue;
        }
        let dest = dir.join(&safe_name);
        if crypto_gen::write_file_if_changed(&dest, content.as_bytes()).is_ok() {
            written += 1;
        }
    }
    written
}

fn filter_routes_only_sections(sections: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    for (k, v) in sections {
        let stype = v
            .as_object()
            .and_then(|o| o.get(".type"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if matches!(
            stype,
            "section" | "outbound_source" | "outbound_group" | "balancer" | "condition" | "server"
        ) {
            out.insert(k.clone(), v.clone());
        }
    }
    out
}

fn filter_routes_only_store(store: &RouterStoreData) -> RouterStoreData {
    RouterStoreData {
        sections: store.sections.clone(),
        outbound_sources: store.outbound_sources.clone(),
        outbound_groups: store.outbound_groups.clone(),
        balancers: store.balancers.clone(),
        conditions: store.conditions.clone(),
        servers: store.servers.clone(),
        ..RouterStoreData::default()
    }
}

fn collect_active_components(state: &AppState, store: &RouterStoreData) -> Vec<SnapshotComponent> {
    let mut comps = vec![SnapshotComponent {
        id: "tachyon".to_string(),
        name: "Tachyon".to_string(),
        version: crate::store::TACHYON_VERSION.to_string(),
    }];

    let core_ver =
        std::fs::read_to_string(crate::store::runtime_state_dir().join("tachyon-core-version"))
            .ok()
            .or_else(|| std::fs::read_to_string("/etc/tachyon/tachyon-core-version").ok())
            .map(|s| s.trim().trim_start_matches(['v', 'V']).to_string())
            .filter(|s| !s.is_empty() && s != "unknown" && s != "not installed")
            .or_else(|| {
                state
                    .live
                    .try_read()
                    .ok()
                    .map(|l| {
                        l.core_version
                            .trim()
                            .trim_start_matches(['v', 'V'])
                            .to_string()
                    })
                    .filter(|s| !s.is_empty() && s != "unknown" && s != "not installed")
            })
            .unwrap_or_else(|| crate::store::TACHYON_VERSION.to_string());

    comps.push(SnapshotComponent {
        id: "tachyon-core".to_string(),
        name: "Tachyon Core".to_string(),
        version: core_ver,
    });

    let fptn_enabled = store
        .sections
        .iter()
        .any(|s| s.enabled && s.connection_type == "fptn")
        || store
            .outbound_sources
            .iter()
            .any(|s| s.enabled && s.source_type == "fptn");
    if fptn_enabled {
        let fptn_ver = std::fs::read_to_string("/etc/tachyon/fptn-version")
            .ok()
            .map(|s| s.trim().trim_start_matches(['v', 'V']).to_string())
            .filter(|s| !s.is_empty() && s != "unknown" && s != "not installed")
            .unwrap_or_else(|| "active".to_string());
        comps.push(SnapshotComponent {
            id: "fptn".to_string(),
            name: "FPTN".to_string(),
            version: fptn_ver,
        });
    }

    let ts_enabled = crate::net_stack::is_tailscale_enabled(store);
    if ts_enabled {
        let ts_ver = std::fs::read_to_string("/etc/tachyon/tailscale-version")
            .ok()
            .map(|s| s.trim().trim_start_matches(['v', 'V']).to_string())
            .filter(|s| !s.is_empty() && s != "unknown" && s != "not installed")
            .unwrap_or_else(|| "active".to_string());
        comps.push(SnapshotComponent {
            id: "tailscale".to_string(),
            name: "Tailscale".to_string(),
            version: ts_ver,
        });
    }

    comps
}

pub async fn build_active_profile(
    state: &AppState,
    config_sections: &Map<String, Value>,
    name: &str,
    scope: &str,
) -> TachyonProfileV1 {
    let now = unix_now_secs();
    let stamp = unix_secs_to_stamp(now);
    let full_store = state.data.read().await.clone();
    let components = collect_active_components(state, &full_store);
    let (store_data, sec_map, certs) = if scope == "routes" {
        (
            filter_routes_only_store(&full_store),
            filter_routes_only_sections(config_sections),
            BTreeMap::new(),
        )
    } else {
        (full_store, config_sections.clone(), collect_certs(state))
    };
    let (counts, section_names) = compute_counts(&store_data, &sec_map, certs.len());
    TachyonProfileV1 {
        format: PROFILE_FORMAT.to_string(),
        engine: PROFILE_ENGINE.to_string(),
        version: crate::store::TACHYON_VERSION.to_string(),
        scope: scope.to_string(),
        name: if name.trim().is_empty() {
            crypto_gen::generate_hex(4)
        } else {
            name.trim().to_string()
        },
        stamp,
        created_at: now,
        counts,
        section_names,
        components,
        store_data,
        config_sections: sec_map,
        certs,
    }
}

fn resolve_snapshot_path(dir: &Path, file_arg: &str) -> Option<PathBuf> {
    let clean = sanitize_snapshot_filename(file_arg)?;
    let direct = dir.join(&clean);
    if direct.is_file() {
        return Some(direct);
    }
    let with_profile_ext = dir.join(format!("{clean}.tachyon-profile.json"));
    if with_profile_ext.is_file() {
        return Some(with_profile_ext);
    }
    let with_json_ext = dir.join(format!("{clean}.json"));
    if with_json_ext.is_file() {
        return Some(with_json_ext);
    }
    None
}

fn parse_profile_value(
    val: Value,
    fallback_name: &str,
    fallback_ts: i64,
) -> anyhow::Result<TachyonProfileV1> {
    let unwrapped = if let Some(inner) = val.get("profile").filter(|v| v.is_object()) {
        inner.clone()
    } else {
        val
    };

    let Some(obj) = unwrapped.as_object() else {
        anyhow::bail!("Snapshot payload must be a JSON object");
    };

    if obj.get("format").and_then(Value::as_str) == Some(PROFILE_FORMAT) {
        if obj.contains_key("store_data") || obj.contains_key("config_sections") {
            let mut prof: TachyonProfileV1 = serde_json::from_value(unwrapped)?;
            if prof.created_at <= 0 {
                prof.created_at = fallback_ts;
            }
            if prof.stamp.is_empty() {
                prof.stamp = unix_secs_to_stamp(prof.created_at);
            }
            if prof.name.trim().is_empty() {
                prof.name = fallback_name.to_string();
            }
            if prof.store_data.sections.is_empty() && !prof.config_sections.is_empty() {
                prof.store_data
                    .import_from_json_sections(&prof.config_sections);
            }
            let (counts, names) =
                compute_counts(&prof.store_data, &prof.config_sections, prof.certs.len());
            prof.counts = counts;
            if prof.section_names.is_empty() {
                prof.section_names = names;
            }
            return Ok(prof);
        }
        if let Some(cfg_text) = obj.get("config_text").and_then(Value::as_str) {
            let sections = crate::store::parse_uci_text_to_json_sections(cfg_text);
            let mut store_data = RouterStoreData::default();
            store_data.import_from_json_sections(&sections);
            let created_at = obj
                .get("created_at")
                .and_then(Value::as_i64)
                .unwrap_or(fallback_ts);
            let stamp = obj
                .get("stamp")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(ToString::to_string)
                .unwrap_or_else(|| unix_secs_to_stamp(created_at));
            let name = obj
                .get("name")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(fallback_name)
                .to_string();
            let (counts, section_names) = compute_counts(&store_data, &sections, 0);
            return Ok(TachyonProfileV1 {
                format: PROFILE_FORMAT.to_string(),
                engine: PROFILE_ENGINE.to_string(),
                version: crate::store::TACHYON_VERSION.to_string(),
                scope: "full".to_string(),
                name,
                stamp,
                created_at,
                counts,
                section_names,
                components: Vec::new(),
                store_data,
                config_sections: sections,
                certs: BTreeMap::new(),
            });
        }
    }

    // Legacy raw `config_sections` map or `{"sections": {...}}` export
    let sections_map = obj
        .get("sections")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(|| obj.clone());
    let has_uci_entries = sections_map
        .values()
        .any(|v| v.as_object().and_then(|o| o.get(".type")).is_some());
    if has_uci_entries {
        let mut store_data = RouterStoreData::default();
        store_data.import_from_json_sections(&sections_map);
        let (counts, section_names) = compute_counts(&store_data, &sections_map, 0);
        return Ok(TachyonProfileV1 {
            format: PROFILE_FORMAT.to_string(),
            engine: PROFILE_ENGINE.to_string(),
            version: crate::store::TACHYON_VERSION.to_string(),
            scope: "full".to_string(),
            name: fallback_name.to_string(),
            stamp: unix_secs_to_stamp(fallback_ts),
            created_at: fallback_ts,
            counts,
            section_names,
            components: Vec::new(),
            store_data,
            config_sections: sections_map,
            certs: BTreeMap::new(),
        });
    }

    // Raw `RouterStoreData` JSON
    if obj.contains_key("settings") && obj.contains_key("outbound_sources") {
        let store_data: RouterStoreData = serde_json::from_value(unwrapped)?;
        let (counts, section_names) = compute_counts(&store_data, &Map::new(), 0);
        return Ok(TachyonProfileV1 {
            format: PROFILE_FORMAT.to_string(),
            engine: PROFILE_ENGINE.to_string(),
            version: crate::store::TACHYON_VERSION.to_string(),
            scope: "full".to_string(),
            name: fallback_name.to_string(),
            stamp: unix_secs_to_stamp(fallback_ts),
            created_at: fallback_ts,
            counts,
            section_names,
            components: Vec::new(),
            store_data,
            config_sections: Map::new(),
            certs: BTreeMap::new(),
        });
    }

    anyhow::bail!("Unrecognized snapshot profile format")
}

fn load_snapshot_profile_from_disk(path: &Path) -> anyhow::Result<TachyonProfileV1> {
    let raw = std::fs::read_to_string(path)?;
    let meta_ts = std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or_else(unix_now_secs);
    let stem = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("snapshot")
        .trim_end_matches(".tachyon-profile.json")
        .trim_end_matches(".json");
    let val: Value = serde_json::from_str(&raw)?;
    parse_profile_value(val, stem, meta_ts)
}

fn prune_excess_snapshots(dir: &Path, max_keep: usize) {
    let keep = max_keep.max(1);
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut items: Vec<(i64, String, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_file() {
            continue;
        }
        let Some(fname) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !fname.ends_with(".json") {
            continue;
        }
        let mtime = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let created = load_snapshot_profile_from_disk(&p)
            .map(|prof| prof.created_at)
            .unwrap_or(mtime);
        items.push((created, fname.to_string(), p));
    }
    items.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    for (_, _, old_path) in items.into_iter().skip(keep) {
        let _ = std::fs::remove_file(old_path);
    }
}

pub async fn snapshot_save(
    state: &AppState,
    config_sections: &Map<String, Value>,
    raw_name: &str,
) -> Value {
    let dir = snapshots_dir(state);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return json!({
            "success": false,
            "message": format!("Не удалось создать каталог снапшотов: {e}")
        });
    }

    let max_keep = {
        let d = state.data.read().await;
        if d.settings.snapshot_max_count > 0 {
            d.settings.snapshot_max_count as usize
        } else {
            DEFAULT_MAX_SNAPSHOTS
        }
    };

    let display_name = if raw_name.trim().is_empty() {
        crypto_gen::generate_hex(4)
    } else {
        raw_name.trim().to_string()
    };
    let prof = build_active_profile(state, config_sections, &display_name, "full").await;
    let slug = sanitize_slug(&display_name);
    let mut filename = format!("{}_{}.tachyon-profile.json", prof.stamp, slug);
    if dir.join(&filename).exists() {
        filename = format!(
            "{}_{}_{}.tachyon-profile.json",
            prof.stamp,
            slug,
            unix_now_secs() % 1000
        );
    }
    let path = dir.join(&filename);
    let raw = match serde_json::to_string_pretty(&prof) {
        Ok(s) => s,
        Err(e) => {
            return json!({
                "success": false,
                "message": format!("Ошибка сериализации снапшота: {e}")
            });
        }
    };
    if let Err(e) = crypto_gen::write_file_if_changed(&path, raw.as_bytes()) {
        return json!({
            "success": false,
            "message": format!("Ошибка записи снапшота: {e}")
        });
    }

    prune_excess_snapshots(&dir, max_keep);

    json!({
        "success": true,
        "file": filename,
        "id": filename,
        "name": prof.name,
        "stamp": prof.stamp,
        "size": raw.len(),
        "created_at": prof.created_at,
        "timestamp": prof.created_at,
        "counts": prof.counts,
        "components": prof.components
    })
}

pub fn snapshot_list(state: &AppState) -> Value {
    let dir = snapshots_dir(state);
    let mut rows: Vec<(i64, String, Value)> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(fname) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if !fname.ends_with(".json") {
                continue;
            }
            let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
            if let Ok(prof) = load_snapshot_profile_from_disk(&path) {
                let comps = if prof.components.is_empty() {
                    vec![SnapshotComponent {
                        id: "tachyon".to_string(),
                        name: "Tachyon".to_string(),
                        version: prof.version.clone(),
                    }]
                } else {
                    prof.components.clone()
                };
                rows.push((
                    prof.created_at,
                    fname.to_string(),
                    json!({
                        "file": fname,
                        "id": fname,
                        "name": prof.name,
                        "stamp": prof.stamp,
                        "size": size,
                        "created_at": prof.created_at,
                        "timestamp": prof.created_at,
                        "engine": prof.engine,
                        "version": prof.version,
                        "counts": prof.counts,
                        "components": comps
                    }),
                ));
            }
        }
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    let snapshots: Vec<Value> = rows.into_iter().map(|(_, _, v)| v).collect();
    json!({
        "success": true,
        "snapshots": snapshots
    })
}

pub fn snapshot_delete(state: &AppState, file_arg: &str) -> Value {
    let dir = snapshots_dir(state);
    let Some(path) = resolve_snapshot_path(&dir, file_arg) else {
        return json!({
            "success": false,
            "message": "Снапшот не найден"
        });
    };
    match std::fs::remove_file(&path) {
        Ok(()) => json!({
            "success": true,
            "file": file_arg
        }),
        Err(e) => json!({
            "success": false,
            "message": format!("Не удалось удалить снапшот: {e}")
        }),
    }
}

fn is_secret_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    matches!(
        k.as_str(),
        "password"
            | "private_key"
            | "wg_private_key"
            | "preshared_key"
            | "wg_preshared_key"
            | "awg_header_protection_key"
            | "header_protection_key"
            | "reality_private_key"
            | "bot_token"
            | "ai_api_key"
            | "clash_api_secret"
            | "agent_api_token"
            | "uuid"
            | "secret"
            | "auth_str"
            | "obfs_password"
            | "ssh_private_key"
            | "tailscale_auth_key"
    ) || k.ends_with("_secret")
        || k.ends_with("_token")
        || k.ends_with("_password")
        || k.ends_with("_private_key")
}

fn mask_secrets_value(val: &Value) -> Value {
    match val {
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                if k == "certs" {
                    if let Some(cm) = v.as_object() {
                        let mut masked_certs = Map::new();
                        for ck in cm.keys() {
                            masked_certs.insert(ck.clone(), Value::String("***".to_string()));
                        }
                        out.insert(k.clone(), Value::Object(masked_certs));
                    }
                    continue;
                }
                if is_secret_key(k) {
                    if let Some(s) = v.as_str() {
                        if s.is_empty() {
                            out.insert(k.clone(), Value::String(String::new()));
                        } else {
                            out.insert(k.clone(), Value::String("***".to_string()));
                        }
                    } else {
                        out.insert(k.clone(), Value::String("***".to_string()));
                    }
                } else {
                    out.insert(k.clone(), mask_secrets_value(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(arr) => Value::Array(arr.iter().map(mask_secrets_value).collect()),
        other => other.clone(),
    }
}

fn build_line_diff(old_text: &str, new_text: &str) -> (usize, usize, String) {
    let old_lines: Vec<&str> = old_text.lines().collect();
    let new_lines: Vec<&str> = new_text.lines().collect();
    if old_lines == new_lines {
        return (0, 0, String::new());
    }

    // Bounded Myers/LCS window when <= 800 lines per side; linear fallback for huge configs.
    let n = old_lines.len();
    let m = new_lines.len();
    let mut ops: Vec<(char, &str)> = Vec::new();

    if n.saturating_mul(m) <= 640_000 {
        let stride = m + 1;
        let mut dp = vec![0u16; (n + 1) * stride];
        for i in (0..n).rev() {
            for j in (0..m).rev() {
                dp[i * stride + j] = if old_lines[i] == new_lines[j] {
                    dp[(i + 1) * stride + j + 1].saturating_add(1)
                } else {
                    dp[(i + 1) * stride + j].max(dp[i * stride + j + 1])
                };
            }
        }
        let (mut i, mut j) = (0usize, 0usize);
        while i < n && j < m {
            if old_lines[i] == new_lines[j] {
                ops.push((' ', old_lines[i]));
                i += 1;
                j += 1;
            } else if dp[(i + 1) * stride + j] >= dp[i * stride + j + 1] {
                ops.push(('-', old_lines[i]));
                i += 1;
            } else {
                ops.push(('+', new_lines[j]));
                j += 1;
            }
        }
        while i < n {
            ops.push(('-', old_lines[i]));
            i += 1;
        }
        while j < m {
            ops.push(('+', new_lines[j]));
            j += 1;
        }
    } else {
        let max_len = n.max(m);
        for idx in 0..max_len {
            match (old_lines.get(idx), new_lines.get(idx)) {
                (Some(a), Some(b)) if a == b => ops.push((' ', a)),
                (Some(a), Some(b)) => {
                    ops.push(('-', a));
                    ops.push(('+', b));
                }
                (Some(a), None) => ops.push(('-', a)),
                (None, Some(b)) => ops.push(('+', b)),
                (None, None) => {}
            }
        }
    }

    let mut added = 0usize;
    let mut removed = 0usize;
    let changed_idx: Vec<bool> = ops
        .iter()
        .map(|(tag, _)| {
            if *tag == '+' {
                added += 1;
                true
            } else if *tag == '-' {
                removed += 1;
                true
            } else {
                false
            }
        })
        .collect();

    let mut out = String::from("--- snapshot\n+++ active\n");
    let context = 2usize;
    let mut last_printed: Option<usize> = None;
    for (idx, (tag, line)) in ops.iter().enumerate() {
        let near_change = (idx.saturating_sub(context)..=(idx + context).min(ops.len() - 1))
            .any(|k| changed_idx[k]);
        if !near_change {
            continue;
        }
        if let Some(prev) = last_printed
            && idx > prev + 1
        {
            out.push_str("@@ ... @@\n");
        }
        out.push(*tag);
        out.push(' ');
        out.push_str(line);
        out.push('\n');
        last_printed = Some(idx);
        if out.len() > 64_000 {
            out.push_str("... (diff truncated)\n");
            break;
        }
    }
    (added, removed, out)
}

pub async fn snapshot_diff(
    state: &AppState,
    current_sections: &Map<String, Value>,
    file_arg: &str,
) -> Value {
    let dir = snapshots_dir(state);
    let Some(path) = resolve_snapshot_path(&dir, file_arg) else {
        return json!({
            "success": false,
            "message": "Снапшот не найден"
        });
    };
    let snap_prof = match load_snapshot_profile_from_disk(&path) {
        Ok(p) => p,
        Err(e) => {
            return json!({
                "success": false,
                "message": format!("Не удалось прочитать снапшот: {e}")
            });
        }
    };
    let active_prof = build_active_profile(state, current_sections, "active", "full").await;

    let snap_cmp = mask_secrets_value(&json!({
        "store_data": snap_prof.store_data,
        "config_sections": snap_prof.config_sections,
    }));
    let active_cmp = mask_secrets_value(&json!({
        "store_data": active_prof.store_data,
        "config_sections": active_prof.config_sections,
    }));

    let snap_str = serde_json::to_string_pretty(&snap_cmp).unwrap_or_default();
    let active_str = serde_json::to_string_pretty(&active_cmp).unwrap_or_default();
    let (added_count, removed_count, diff) = build_line_diff(&snap_str, &active_str);
    let has_changes = added_count > 0 || removed_count > 0;

    json!({
        "success": true,
        "file": file_arg,
        "name": snap_prof.name,
        "has_changes": has_changes,
        "added_count": added_count,
        "removed_count": removed_count,
        "diff": diff
    })
}

pub async fn snapshot_restore(
    state: &std::sync::Arc<AppState>,
    file_arg: &str,
) -> anyhow::Result<(TachyonProfileV1, Map<String, Value>)> {
    let dir = snapshots_dir(state);
    let path = resolve_snapshot_path(&dir, file_arg)
        .ok_or_else(|| anyhow::anyhow!("Снапшот '{file_arg}' не найден"))?;
    let mut prof = load_snapshot_profile_from_disk(&path)?;
    if prof.store_data.sections.is_empty() && !prof.config_sections.is_empty() {
        prof.store_data
            .import_from_json_sections(&prof.config_sections);
    }
    restore_certs(state, &prof.certs);
    transaction::commit_transaction_with_source(state, prof.store_data.clone(), "snapshot").await?;
    let committed = state.data.read().await.clone();
    let existing_val = Value::Object(prof.config_sections.clone());
    let sections = match crate::store::sync_store_to_json_sections(&committed, Some(&existing_val))
    {
        Value::Object(map) => map,
        _ => prof.config_sections.clone(),
    };
    Ok((prof, sections))
}

/// Escape non-ASCII chars as `\uXXXX` so UTF-8 byte offsets and JS UTF-16 `.length` match 1:1
/// during `read-chunk:<offset>:<step>` streaming in `settings.ts`.
fn to_ascii_safe_json(val: &Value) -> String {
    let raw = serde_json::to_string_pretty(val).unwrap_or_else(|_| "{}".to_string());
    if raw.is_ascii() {
        return raw;
    }
    let mut out = String::with_capacity(raw.len() + 64);
    for ch in raw.chars() {
        if ch.is_ascii() {
            out.push(ch);
        } else {
            let mut utf16 = [0u16; 2];
            for unit in ch.encode_utf16(&mut utf16) {
                out.push_str(&format!("\\u{unit:04x}"));
            }
        }
    }
    out
}

fn cache_export_json(ascii_json: &str) {
    if cfg!(target_os = "linux") {
        let _ = std::fs::create_dir_all("/var/run/tachyon/ui-state");
        let _ = crypto_gen::write_file_if_changed(
            Path::new("/var/run/tachyon/ui-state/snapshot-export.json"),
            ascii_json.as_bytes(),
        );
        let _ = crypto_gen::write_file_if_changed(
            Path::new("/tmp/tachyon-snapshot-export.json"),
            ascii_json.as_bytes(),
        );
    } else if let Ok(mut guard) = export_buffer().lock() {
        *guard = ascii_json.to_string();
        guard.shrink_to_fit();
    }
}

pub fn encode_transfer_code(prof: &TachyonProfileV1) -> anyhow::Result<String> {
    let scope = if prof.scope == "full" {
        "full"
    } else {
        "routes"
    };
    let compact_bytes = serde_json::to_vec(prof)?;
    let mut hasher = Sha256::new();
    hasher.update(&compact_bytes);
    let full_hex = crypto_gen::bytes_to_hex(&hasher.finalize());
    let short_hash = &full_hex[..8];
    let encoded = B64_URL.encode(&compact_bytes);
    Ok(format!("tachyon://rs2/{scope}/{short_hash}/{encoded}"))
}

pub fn decode_transfer_payload(raw_input: &str) -> anyhow::Result<TachyonProfileV1> {
    let mut text = raw_input.trim().to_string();
    if text.starts_with('{')
        && let Ok(val) = serde_json::from_str::<Value>(&text)
    {
        if let Some(code_str) = val
            .get("code")
            .or_else(|| val.get("transfer_code"))
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
        {
            text = code_str.trim().to_string();
        } else {
            return parse_profile_value(val, "transfer", unix_now_secs());
        }
    }

    if let Some(rest) = text.strip_prefix("tachyon://rs2/") {
        let mut parts = rest.splitn(3, '/');
        let scope = parts
            .next()
            .filter(|s| *s == "routes" || *s == "full")
            .ok_or_else(|| anyhow::anyhow!("Некорректный тип кода переноса"))?;
        let expected_hash = parts
            .next()
            .filter(|h| h.len() == 8)
            .ok_or_else(|| anyhow::anyhow!("Отсутствует контрольная сумма кода"))?;
        let b64_payload = parts
            .next()
            .filter(|b| !b.is_empty())
            .ok_or_else(|| anyhow::anyhow!("Пустое тело кода переноса"))?;
        let bytes = B64_URL
            .decode(b64_payload.trim())
            .or_else(|_| B64_STD.decode(b64_payload.trim()))
            .map_err(|_| anyhow::anyhow!("Повреждённые данные Base64 в коде переноса"))?;
        if bytes.len() > MAX_IMPORT_BYTES {
            anyhow::bail!("Превышен допустимый размер кода переноса (4 МБ)");
        }
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        let actual_hex = crypto_gen::bytes_to_hex(&hasher.finalize());
        if !actual_hex[..8].eq_ignore_ascii_case(expected_hash) {
            anyhow::bail!("Контрольная сумма SHA-256 кода переноса не совпадает");
        }
        let val: Value = serde_json::from_slice(&bytes)?;
        let mut prof = parse_profile_value(val, "transfer", unix_now_secs())?;
        prof.scope = scope.to_string();
        return Ok(prof);
    }

    if let Some(rest) = text.strip_prefix("tachyon://cfg1/") {
        // Support plain base64 JSON `tachyon://cfg1/<scope>/<b64>` if uncompressed
        let payload_part = rest.rsplit('/').next().unwrap_or(rest).trim();
        if let Ok(bytes) = B64_URL
            .decode(payload_part)
            .or_else(|_| B64_STD.decode(payload_part))
            && let Ok(val) = serde_json::from_slice::<Value>(&bytes)
        {
            return parse_profile_value(val, "transfer-cfg1", unix_now_secs());
        }
        anyhow::bail!(
            "Устаревший формат кода tachyon://cfg1; сгенерируйте новый код tachyon://rs2"
        );
    }

    anyhow::bail!("Неверный формат кода переноса (ожидается tachyon://rs2/...)")
}

pub async fn snapshot_export(
    state: &AppState,
    current_sections: &Map<String, Value>,
    arg: Option<&str>,
) -> Value {
    let raw_arg = arg.unwrap_or("").trim();

    if let Some(rest) = raw_arg.strip_prefix("read-chunk:") {
        let mut parts = rest.split(':');
        let offset = parts
            .next()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(0);
        let step = parts
            .next()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(32_768)
            .clamp(512, 65_536);

        if let Ok(mut guard) = export_buffer().lock()
            && !guard.is_empty()
        {
            if offset >= guard.len() {
                guard.clear();
                guard.shrink_to_fit();
                return json!({
                    "success": true,
                    "chunk": "",
                    "eof": true
                });
            }
            let mut end = (offset + step).min(guard.len());
            while end < guard.len() && !guard.is_char_boundary(end) {
                end += 1;
            }
            let piece = guard[offset..end].to_string();
            let eof = end >= guard.len();
            if eof {
                guard.clear();
                guard.shrink_to_fit();
            }
            return json!({
                "success": true,
                "chunk": piece,
                "eof": eof
            });
        }

        let buf = std::fs::read_to_string("/tmp/tachyon-snapshot-export.json").unwrap_or_default();
        if offset >= buf.len() {
            return json!({
                "success": true,
                "chunk": "",
                "eof": true
            });
        }
        let mut end = (offset + step).min(buf.len());
        while end < buf.len() && !buf.is_char_boundary(end) {
            end += 1;
        }
        let piece = &buf[offset..end];
        let eof = end >= buf.len();
        return json!({
            "success": true,
            "chunk": piece,
            "eof": eof
        });
    }

    if let Some(scope) = raw_arg.strip_prefix("code:") {
        let clean_scope = if scope == "full" { "full" } else { "routes" };
        let prof = build_active_profile(state, current_sections, "transfer", clean_scope).await;
        match encode_transfer_code(&prof) {
            Ok(code) => {
                let fallback_doc = json!({
                    "format": PROFILE_FORMAT,
                    "scope": clean_scope,
                    "code": code,
                    "transfer_code": code,
                    "counts": prof.counts,
                    "section_names": prof.section_names,
                });
                cache_export_json(&to_ascii_safe_json(&fallback_doc));
                if code.len() > 48_000 {
                    return json!({
                        "success": true,
                        "chunked_export": true,
                        "scope": clean_scope,
                        "counts": prof.counts,
                        "section_names": prof.section_names
                    });
                }
                return json!({
                    "success": true,
                    "scope": clean_scope,
                    "code": code,
                    "counts": prof.counts,
                    "section_names": prof.section_names
                });
            }
            Err(e) => {
                return json!({
                    "success": false,
                    "message": format!("Не удалось сформировать код переноса: {e}")
                });
            }
        }
    }

    let prof = if raw_arg.is_empty() || raw_arg == "current" {
        build_active_profile(state, current_sections, "export", "full").await
    } else {
        let dir = snapshots_dir(state);
        match resolve_snapshot_path(&dir, raw_arg)
            .ok_or_else(|| anyhow::anyhow!("Снапшот не найден"))
            .and_then(|p| load_snapshot_profile_from_disk(&p))
        {
            Ok(p) => p,
            Err(e) => {
                return json!({
                    "success": false,
                    "message": format!("{e}")
                });
            }
        }
    };

    let prof_val = serde_json::to_value(&prof).unwrap_or_else(|_| json!({}));
    let ascii_json = to_ascii_safe_json(&prof_val);
    cache_export_json(&ascii_json);

    if ascii_json.len() > 48_000 {
        json!({
            "success": true,
            "chunked_export": true,
            "path": "/tmp/tachyon-snapshot-export.json"
        })
    } else {
        json!({
            "success": true,
            "profile": prof_val,
            "path": "/tmp/tachyon-snapshot-export.json"
        })
    }
}

fn read_import_target_text(target: &str) -> anyhow::Result<String> {
    let trimmed = target.trim();
    if trimmed.is_empty() || trimmed == "/tmp/tachyon-snapshot-import.json" {
        if let Ok(guard) = import_buffer().lock()
            && !guard.is_empty()
        {
            return Ok(String::from_utf8(guard.clone())?);
        }
        let content = std::fs::read_to_string("/tmp/tachyon-snapshot-import.json")?;
        if content.len() > MAX_IMPORT_BYTES {
            anyhow::bail!("Превышен лимит импорта (4 МБ)");
        }
        return Ok(content);
    }
    if (trimmed.starts_with('/') || trimmed.ends_with(".json"))
        && !trimmed.starts_with('{')
        && Path::new(trimmed).is_file()
    {
        let meta = std::fs::metadata(trimmed)?;
        if meta.len() as usize > MAX_IMPORT_BYTES {
            anyhow::bail!("Файл превышает максимальный размер 4 МБ");
        }
        return Ok(std::fs::read_to_string(trimmed)?);
    }
    Ok(trimmed.to_string())
}

fn merge_vec_by_id<T, F>(dest: &mut Vec<T>, incoming: Vec<T>, id_fn: F)
where
    F: Fn(&T) -> &str,
{
    for item in incoming {
        let id = id_fn(&item);
        if let Some(existing) = dest.iter_mut().find(|x| id_fn(x) == id) {
            *existing = item;
        } else {
            dest.push(item);
        }
    }
}

fn apply_profile_to_state_data(
    current_store: &RouterStoreData,
    current_sections: &Map<String, Value>,
    incoming: &TachyonProfileV1,
    mode: &str,
) -> (RouterStoreData, Map<String, Value>) {
    let is_merge = mode == "merge";
    let is_full = incoming.scope == "full";

    if !is_merge && is_full {
        let mut next_store = incoming.store_data.clone();
        if next_store.sections.is_empty() && !incoming.config_sections.is_empty() {
            next_store.import_from_json_sections(&incoming.config_sections);
        }
        let existing_opt = if incoming.config_sections.is_empty() {
            None
        } else {
            Some(Value::Object(incoming.config_sections.clone()))
        };
        let next_sections =
            match crate::store::sync_store_to_json_sections(&next_store, existing_opt.as_ref()) {
                Value::Object(map) => map,
                _ => incoming.config_sections.clone(),
            };
        return (next_store, next_sections);
    }

    if !is_merge {
        // Replace routes only, keep global settings / parental / telegram
        let mut next_store = current_store.clone();
        next_store.sections = incoming.store_data.sections.clone();
        next_store.outbound_sources = incoming.store_data.outbound_sources.clone();
        next_store.outbound_groups = incoming.store_data.outbound_groups.clone();
        next_store.balancers = incoming.store_data.balancers.clone();
        next_store.conditions = incoming.store_data.conditions.clone();
        next_store.servers = incoming.store_data.servers.clone();

        let mut next_sections = Map::new();
        for (k, v) in current_sections {
            let stype = v
                .as_object()
                .and_then(|o| o.get(".type"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if !matches!(
                stype,
                "section"
                    | "outbound_source"
                    | "outbound_group"
                    | "balancer"
                    | "condition"
                    | "server"
            ) {
                next_sections.insert(k.clone(), v.clone());
            }
        }
        for (k, v) in &incoming.config_sections {
            next_sections.insert(k.clone(), v.clone());
        }
        return (next_store, next_sections);
    }

    // Merge mode
    let mut next_store = if is_full {
        let mut base = incoming.store_data.clone();
        base.sections = current_store.sections.clone();
        base.outbound_sources = current_store.outbound_sources.clone();
        base.outbound_groups = current_store.outbound_groups.clone();
        base.balancers = current_store.balancers.clone();
        base.conditions = current_store.conditions.clone();
        base.servers = current_store.servers.clone();
        base
    } else {
        current_store.clone()
    };

    merge_vec_by_id(
        &mut next_store.sections,
        incoming.store_data.sections.clone(),
        |s| &s.id,
    );
    merge_vec_by_id(
        &mut next_store.outbound_sources,
        incoming.store_data.outbound_sources.clone(),
        |s| &s.id,
    );
    merge_vec_by_id(
        &mut next_store.outbound_groups,
        incoming.store_data.outbound_groups.clone(),
        |g| &g.id,
    );
    merge_vec_by_id(
        &mut next_store.balancers,
        incoming.store_data.balancers.clone(),
        |b| &b.id,
    );
    merge_vec_by_id(
        &mut next_store.conditions,
        incoming.store_data.conditions.clone(),
        |c| &c.id,
    );
    merge_vec_by_id(
        &mut next_store.servers,
        incoming.store_data.servers.clone(),
        |s| &s.id,
    );

    let mut next_sections = current_sections.clone();
    for (k, v) in &incoming.config_sections {
        if !is_full && k == "settings" {
            continue;
        }
        next_sections.insert(k.clone(), v.clone());
    }
    (next_store, next_sections)
}

pub enum ImportOutcome {
    ResponseOnly(Value),
    AppliedState {
        response: Value,
        new_sections: Map<String, Value>,
    },
}

pub async fn snapshot_import(
    state: &std::sync::Arc<AppState>,
    current_sections: &Map<String, Value>,
    arg: Option<&str>,
) -> ImportOutcome {
    let raw_arg = arg.unwrap_or("/tmp/tachyon-snapshot-import.json").trim();

    if raw_arg == "chunk-init" {
        if let Ok(mut guard) = import_buffer().lock() {
            guard.clear();
            guard.shrink_to_fit();
        }
        if cfg!(target_os = "linux") {
            let _ = std::fs::write("/tmp/tachyon-snapshot-import.json", b"");
        }
        return ImportOutcome::ResponseOnly(json!({ "success": true }));
    }

    if let Some(b64_chunk) = raw_arg.strip_prefix("chunk-append:") {
        let decoded = match B64_STD
            .decode(b64_chunk.trim())
            .or_else(|_| B64_URL.decode(b64_chunk.trim()))
        {
            Ok(b) => b,
            Err(e) => {
                return ImportOutcome::ResponseOnly(json!({
                    "success": false,
                    "message": format!("Некорректный Base64-фрагмент: {e}")
                }));
            }
        };
        let mut total_len = 0usize;
        if let Ok(mut guard) = import_buffer().lock() {
            if guard.len().saturating_add(decoded.len()) > MAX_IMPORT_BYTES {
                return ImportOutcome::ResponseOnly(json!({
                    "success": false,
                    "message": "Превышен максимальный размер импортируемого профиля (4 МБ)"
                }));
            }
            guard.extend_from_slice(&decoded);
            total_len = guard.len();
            if cfg!(target_os = "linux") {
                let _ = std::fs::write("/tmp/tachyon-snapshot-import.json", &*guard);
            }
        }
        return ImportOutcome::ResponseOnly(json!({
            "success": true,
            "bytes": total_len
        }));
    }

    if let Some(target) = raw_arg.strip_prefix("code-inspect:") {
        let res = read_import_target_text(target).and_then(|txt| decode_transfer_payload(&txt));
        return match res {
            Ok(prof) => ImportOutcome::ResponseOnly(json!({
                "success": true,
                "scope": prof.scope,
                "engine": prof.engine,
                "version": prof.version,
                "counts": prof.counts,
                "section_names": prof.section_names
            })),
            Err(e) => ImportOutcome::ResponseOnly(json!({
                "success": false,
                "message": format!("{e}")
            })),
        };
    }

    if let Some(rest) = raw_arg.strip_prefix("code-apply:") {
        let (mode, target) = if let Some(t) = rest.strip_prefix("merge:") {
            ("merge", t)
        } else if let Some(t) = rest.strip_prefix("replace:") {
            ("replace", t)
        } else {
            ("replace", rest)
        };
        let prof =
            match read_import_target_text(target).and_then(|txt| decode_transfer_payload(&txt)) {
                Ok(p) => p,
                Err(e) => {
                    return ImportOutcome::ResponseOnly(json!({
                        "success": false,
                        "message": format!("{e}")
                    }));
                }
            };

        // Save automatic pre-transfer snapshot first
        let _ = snapshot_save(state, current_sections, "pre-transfer").await;

        let current_store = state.data.read().await.clone();
        let (next_store, next_sections) =
            apply_profile_to_state_data(&current_store, current_sections, &prof, mode);
        restore_certs(state, &prof.certs);

        if let Ok(mut guard) = import_buffer().lock() {
            guard.clear();
            guard.shrink_to_fit();
        }

        if let Err(e) =
            transaction::commit_transaction_with_source(state, next_store, "import").await
        {
            return ImportOutcome::ResponseOnly(json!({
                "success": false,
                "message": format!("Не удалось применить конфигурацию: {e}")
            }));
        }

        return ImportOutcome::AppliedState {
            response: json!({
                "success": true,
                "mode": mode,
                "scope": prof.scope,
                "counts": prof.counts
            }),
            new_sections: next_sections,
        };
    }

    // Profile JSON import into the snapshots list (used by "Import Profile" button in settings.ts)
    let raw_text = match read_import_target_text(raw_arg) {
        Ok(t) => t,
        Err(e) => {
            return ImportOutcome::ResponseOnly(json!({
                "success": false,
                "message": format!("Не удалось прочитать профиль: {e}")
            }));
        }
    };
    if let Ok(mut guard) = import_buffer().lock() {
        guard.clear();
        guard.shrink_to_fit();
    }

    let parsed_val: Value = match serde_json::from_str(&raw_text) {
        Ok(v) => v,
        Err(e) => {
            return ImportOutcome::ResponseOnly(json!({
                "success": false,
                "message": format!("Некорректный JSON профиля: {e}")
            }));
        }
    };

    let mut prof = match parse_profile_value(parsed_val, "imported", unix_now_secs()) {
        Ok(p) => p,
        Err(e) => {
            return ImportOutcome::ResponseOnly(json!({
                "success": false,
                "message": format!("{e}")
            }));
        }
    };

    let dir = snapshots_dir(state);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return ImportOutcome::ResponseOnly(json!({
            "success": false,
            "message": format!("Ошибка создания каталога снапшотов: {e}")
        }));
    }
    let now = unix_now_secs();
    if prof.created_at <= 0 {
        prof.created_at = now;
    }
    if prof.stamp.is_empty() {
        prof.stamp = unix_secs_to_stamp(prof.created_at);
    }
    let slug = sanitize_slug(&prof.name);
    let mut filename = format!("{}_{}.tachyon-profile.json", prof.stamp, slug);
    if dir.join(&filename).exists() {
        filename = format!(
            "{}_{}_{}.tachyon-profile.json",
            prof.stamp,
            slug,
            now % 1000
        );
    }
    let serialized = match serde_json::to_string_pretty(&prof) {
        Ok(s) => s,
        Err(e) => {
            return ImportOutcome::ResponseOnly(json!({
                "success": false,
                "message": format!("{e}")
            }));
        }
    };
    if let Err(e) = crypto_gen::write_file_if_changed(dir.join(&filename), serialized.as_bytes()) {
        return ImportOutcome::ResponseOnly(json!({
            "success": false,
            "message": format!("Ошибка сохранения импортированного профиля: {e}")
        }));
    }
    let max_keep = {
        let d = state.data.read().await;
        if d.settings.snapshot_max_count > 0 {
            d.settings.snapshot_max_count as usize
        } else {
            DEFAULT_MAX_SNAPSHOTS
        }
    };
    prune_excess_snapshots(&dir, max_keep);

    ImportOutcome::ResponseOnly(json!({
        "success": true,
        "file": filename,
        "name": prof.name,
        "stamp": prof.stamp,
        "size": serialized.len(),
        "counts": prof.counts
    }))
}

pub async fn reset_settings_to_defaults(
    state: &std::sync::Arc<AppState>,
    current_sections: &Map<String, Value>,
) -> anyhow::Result<(Value, Map<String, Value>)> {
    let backup = snapshot_save(state, current_sections, "pre-reset").await;
    let backup_file = backup
        .get("file")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    let default_store = RouterStoreData::factory_defaults();
    transaction::commit_transaction_with_source(state, default_store.clone(), "reset").await?;

    let default_sections = match crate::store::sync_store_to_json_sections(&default_store, None) {
        Value::Object(map) => map,
        _ => Map::new(),
    };

    let resp = json!({
        "success": true,
        "backup_file": backup_file,
        "message": "Настройки сброшены к заводским значениям"
    });
    Ok((resp, default_sections))
}

// ---------------------------------------------------------------------------
// Streaming Binary Self-Version Backup & Rollback (`tachyon` & `tachyon-core`)
// ---------------------------------------------------------------------------

pub fn normalize_backup_component(component: &str) -> Option<&'static str> {
    match component.trim() {
        "tachyon" => Some("tachyon"),
        "tachyon-core" | "sing_box" | "sing-box" | "sing-box-lx" | "sing-box-extended" => {
            Some("tachyon-core")
        }
        _ => None,
    }
}

pub fn resolve_tachyon_daemon_bin_path() -> PathBuf {
    if let Ok(exe) = std::env::current_exe()
        && exe.is_file()
    {
        return exe;
    }
    let default_bin = PathBuf::from("/usr/bin/tachyon");
    if default_bin.is_file() {
        return default_bin;
    }
    PathBuf::from("/tmp/tachyon-rs/tachyon")
}

fn sha256_file_streaming(path: &Path) -> anyhow::Result<(String, u64)> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 65_536];
    let mut total = 0u64;
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        total += n as u64;
    }
    Ok((crypto_gen::bytes_to_hex(&hasher.finalize()), total))
}

fn stream_copy_executable(src: &Path, dst: &Path) -> anyhow::Result<()> {
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = dst.with_extension(format!("tmp.{}", std::process::id()));
    {
        let mut reader = std::fs::File::open(src)?;
        let mut writer = std::fs::File::create(&tmp)?;
        let mut buf = [0u8; 65_536];
        loop {
            let n = reader.read(&mut buf)?;
            if n == 0 {
                break;
            }
            writer.write_all(&buf[..n])?;
        }
        writer.sync_all()?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755));
    }
    if std::fs::rename(&tmp, dst).is_err() {
        std::fs::copy(&tmp, dst)?;
        let _ = std::fs::remove_file(&tmp);
    }
    Ok(())
}

pub fn read_backup_meta(data_dir: &Path, component: &str) -> Option<BinaryBackupMeta> {
    let norm = normalize_backup_component(component)?;
    let comp_dir = backups_dir(data_dir).join(norm);
    let bin_path = comp_dir.join("binary");
    let meta_path = comp_dir.join("meta.json");
    if !bin_path.is_file() || !meta_path.is_file() {
        return None;
    }
    let raw = std::fs::read_to_string(&meta_path).ok()?;
    let meta: BinaryBackupMeta = serde_json::from_str(&raw).ok()?;
    if meta.version.trim().is_empty() {
        return None;
    }
    Some(meta)
}

pub fn backup_binary(
    data_dir: &Path,
    component: &str,
    src_bin_path: &Path,
    version: &str,
) -> anyhow::Result<BinaryBackupMeta> {
    let norm = normalize_backup_component(component).ok_or_else(|| {
        anyhow::anyhow!("Компонент '{component}' не поддерживает резервное копирование бинарника")
    })?;
    if !src_bin_path.is_file() {
        anyhow::bail!("Бинарный файл '{}' не найден", src_bin_path.display());
    }
    let (sha256, size) = sha256_file_streaming(src_bin_path)?;
    let comp_dir = backups_dir(data_dir).join(norm);
    std::fs::create_dir_all(&comp_dir)?;
    let dst_bin = comp_dir.join("binary");
    let meta_path = comp_dir.join("meta.json");

    let existing_matches = read_backup_meta(data_dir, norm)
        .is_some_and(|m| m.sha256 == sha256 && m.size == size && dst_bin.is_file());

    if !existing_matches {
        stream_copy_executable(src_bin_path, &dst_bin)?;
    }

    let meta = BinaryBackupMeta {
        component: norm.to_string(),
        version: if version.trim().is_empty() {
            "unknown".to_string()
        } else {
            version.trim().to_string()
        },
        sha256,
        size,
        backed_up_at: unix_now_secs(),
    };
    crypto_gen::write_json_if_changed(&meta_path, &serde_json::to_value(&meta)?)?;
    Ok(meta)
}

pub fn rollback_binary(
    data_dir: &Path,
    component: &str,
    target_bin_path: &Path,
) -> anyhow::Result<BinaryBackupMeta> {
    let norm = normalize_backup_component(component)
        .ok_or_else(|| anyhow::anyhow!("Компонент '{component}' не поддерживает откат версии"))?;
    let meta = read_backup_meta(data_dir, norm)
        .ok_or_else(|| anyhow::anyhow!("Резервная копия для '{norm}' не найдена"))?;
    let src_bin = backups_dir(data_dir).join(norm).join("binary");
    let (actual_sha, actual_size) = sha256_file_streaming(&src_bin)?;
    if actual_sha != meta.sha256 || actual_size != meta.size {
        anyhow::bail!("Контрольная сумма резервной копии '{norm}' повреждена");
    }
    stream_copy_executable(&src_bin, target_bin_path)?;
    Ok(meta)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_state(dir: &Path) -> std::sync::Arc<AppState> {
        let _ = std::fs::create_dir_all(dir);
        let store_path = dir.join("tachyon.json");
        AppState::load_or_create(&store_path).expect("load test AppState")
    }

    #[tokio::test]
    async fn test_snapshot_lifecycle_retention_diff_and_restore() {
        let tmp = std::env::temp_dir().join(format!("tachyon_snap_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let state = make_test_state(&tmp);

        {
            let mut d = state.data.write().await;
            d.settings.snapshot_max_count = 3;
            d.settings.dns_type = "doh".to_string();
            d.settings.clash_api_secret = "top-secret-token".to_string();
        }

        let mut sections = Map::new();
        sections.insert(
            "Main".to_string(),
            json!({ ".type": "section", ".name": "Main", "name": "Основной контур" }),
        );

        for idx in 1..=5 {
            let saved = snapshot_save(&state, &sections, &format!("snap-{idx}")).await;
            assert_eq!(saved.get("success").and_then(Value::as_bool), Some(true));
            let stamp = saved.get("stamp").and_then(Value::as_str).unwrap_or("");
            assert_eq!(stamp.len(), 15, "stamp must match YYYYMMDD-HHMMSS");
            let comps = saved
                .get("components")
                .and_then(Value::as_array)
                .expect("components array");
            assert!(
                comps
                    .iter()
                    .any(|c| c.get("id").and_then(Value::as_str) == Some("tachyon")),
                "components must include tachyon"
            );
        }

        // Empty name auto-generates an 8-char lowercase hex ID
        let auto_saved = snapshot_save(&state, &sections, "").await;
        assert_eq!(
            auto_saved.get("success").and_then(Value::as_bool),
            Some(true)
        );
        let auto_name = auto_saved.get("name").and_then(Value::as_str).unwrap_or("");
        assert_eq!(auto_name.len(), 8);
        assert!(
            auto_name
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );

        // Pruned to snapshot_max_count = 3
        let listed = snapshot_list(&state);
        let arr = listed
            .get("snapshots")
            .and_then(Value::as_array)
            .expect("snapshots array");
        assert_eq!(arr.len(), 3);
        let newest_file = arr[0]
            .get("file")
            .and_then(Value::as_str)
            .expect("file field")
            .to_string();

        // Mutate active state and verify masked diff
        {
            let mut d = state.data.write().await;
            d.settings.dns_type = "dot".to_string();
            d.settings.clash_api_secret = "rotated-secret-value".to_string();
        }
        let diff_res = snapshot_diff(&state, &sections, &newest_file).await;
        assert_eq!(
            diff_res.get("has_changes").and_then(Value::as_bool),
            Some(true)
        );
        let diff_txt = diff_res.get("diff").and_then(Value::as_str).unwrap_or("");
        assert!(diff_txt.contains("dot"));
        assert!(!diff_txt.contains("top-secret-token"));
        assert!(!diff_txt.contains("rotated-secret-value"));

        // Restore and verify dns_type rolled back
        let (_prof, _restored_sec) = snapshot_restore(&state, &newest_file)
            .await
            .expect("restore ok");
        assert_eq!(state.data.read().await.settings.dns_type, "doh");

        // Delete
        let del = snapshot_delete(&state, &newest_file);
        assert_eq!(del.get("success").and_then(Value::as_bool), Some(true));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn test_transfer_code_inspect_apply_merge_and_chunked_export() {
        let tmp = std::env::temp_dir().join(format!("tachyon_xfer_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let state = make_test_state(&tmp);

        let mut sections = Map::new();
        sections.insert(
            "Gaming".to_string(),
            json!({ ".type": "section", ".name": "Gaming", "name": "Игровой профиль" }),
        );

        let exp = snapshot_export(&state, &sections, Some("code:routes")).await;
        assert_eq!(exp.get("success").and_then(Value::as_bool), Some(true));
        let code = exp
            .get("code")
            .and_then(Value::as_str)
            .expect("transfer code");
        assert!(code.starts_with("tachyon://rs2/routes/"));

        // Inspect transfer code
        let inspect =
            match snapshot_import(&state, &Map::new(), Some(&format!("code-inspect:{code}"))).await
            {
                ImportOutcome::ResponseOnly(v) => v,
                ImportOutcome::AppliedState { response, .. } => response,
            };
        assert_eq!(inspect.get("success").and_then(Value::as_bool), Some(true));
        assert_eq!(inspect.get("scope").and_then(Value::as_str), Some("routes"));

        // Merge into existing sections
        let mut target_sections = Map::new();
        target_sections.insert(
            "Existing".to_string(),
            json!({ ".type": "section", ".name": "Existing", "name": "Текущий" }),
        );
        match snapshot_import(
            &state,
            &target_sections,
            Some(&format!("code-apply:merge:{code}")),
        )
        .await
        {
            ImportOutcome::AppliedState {
                response,
                new_sections,
            } => {
                assert_eq!(response.get("success").and_then(Value::as_bool), Some(true));
                assert!(new_sections.contains_key("Existing"));
                assert!(new_sections.contains_key("Gaming"));
            }
            ImportOutcome::ResponseOnly(v) => panic!("expected AppliedState, got {v}"),
        }

        // Chunked export reader preserves UTF-8 / Cyrillic names cleanly
        let _ = snapshot_export(&state, &sections, Some("current")).await;
        let mut assembled = String::new();
        let mut offset = 0usize;
        loop {
            let chunk_res =
                snapshot_export(&state, &sections, Some(&format!("read-chunk:{offset}:512"))).await;
            let piece = chunk_res.get("chunk").and_then(Value::as_str).unwrap_or("");
            assembled.push_str(piece);
            offset += piece.encode_utf16().count();
            if chunk_res
                .get("eof")
                .and_then(Value::as_bool)
                .unwrap_or(true)
                || piece.is_empty()
            {
                break;
            }
        }
        let parsed: Value = serde_json::from_str(&assembled).expect("valid chunked JSON");
        assert_eq!(
            parsed.get("format").and_then(Value::as_str),
            Some(PROFILE_FORMAT)
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_binary_backup_and_rollback_streaming() {
        let tmp = std::env::temp_dir().join(format!("tachyon_binbak_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("mkdir");

        let bin_path = tmp.join("tachyon-bin");
        std::fs::write(&bin_path, b"ELF-tachyon-v2.0.0-binary-image").expect("write v1");

        let meta = backup_binary(&tmp, "tachyon", &bin_path, "2.0.0").expect("backup");
        assert_eq!(meta.version, "2.0.0");
        assert_eq!(
            read_backup_meta(&tmp, "tachyon").unwrap().sha256,
            meta.sha256
        );

        // Simulate upgrade to broken v2.0.1 and rollback to v2.0.0
        std::fs::write(&bin_path, b"ELF-tachyon-v2.0.1-broken").expect("write v2");
        let rolled = rollback_binary(&tmp, "tachyon", &bin_path).expect("rollback");
        assert_eq!(rolled.version, "2.0.0");
        assert_eq!(
            std::fs::read(&bin_path).expect("read rolled"),
            b"ELF-tachyon-v2.0.0-binary-image"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_reset_settings_to_defaults_uses_factory_defaults_not_legacy_uci() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt");
        let tmp = std::env::temp_dir().join(format!("tachyon_reset_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("mkdir");
        let store_path = tmp.join("tachyon.json");

        let mut custom = RouterStoreData::factory_defaults();
        custom.settings.dns_type = "dot".to_string();
        custom.settings.listen_port = 18080;
        let state = AppState::load_or_create(&store_path).expect("state");
        {
            let mut w = state.data.blocking_write();
            *w = custom;
        }
        rt.block_on(async {
            state.save().await.expect("save custom");
            let cur_secs =
                match crate::store::sync_store_to_json_sections(&*state.data.read().await, None) {
                    Value::Object(m) => m,
                    _ => Map::new(),
                };
            let (resp, _default_secs) = reset_settings_to_defaults(&state, &cur_secs)
                .await
                .expect("reset");
            assert_eq!(resp.get("success").and_then(Value::as_bool), Some(true));
            let after = state.data.read().await;
            let expected = RouterStoreData::factory_defaults();
            assert_eq!(after.settings.dns_type, expected.settings.dns_type);
            assert_eq!(after.settings.listen_port, expected.settings.listen_port);
            assert_eq!(after.sections.len(), expected.sections.len());
        });

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
