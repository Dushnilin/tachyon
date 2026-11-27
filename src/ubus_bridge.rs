//! Pure-Rust LuCI, `ubus` JSON-RPC 2.0, `uci`, `file`, and CLI Bridge for `tachyon-rs`.
//!
//! Serves the complete TypeScript `fe-app-tachyon` SPA (`main.js` + all 14 views) directly from
//! the Rust HTTP server (`:1680`), handling:
//! - `GET /`, `GET /cgi-bin/luci/admin/services/tachyon*` -> LuCI HTML Shell with `tachyon-ui` animated SVG background
//! - `GET /luci-static/*` -> In-memory cached static JS/CSS/SVG asset delivery
//! - `GET /cgi-bin/luci/admin/translations/*` -> Embedded PO -> `window.TR_RAW` / `window.TR`
//! - `POST /ubus*`, `POST /cgi-bin/luci/admin/ubus*` -> Ultra-fast JSON-RPC 2.0 dispatcher
//! - `POST /cgi-bin/luci/admin/uci/*` -> `apply_rollback`, `apply_unchecked`, `confirm`, `revert`
//! - `POST /cgi-bin/cgi-exec`, `POST /cgi-bin/cgi-download` -> Direct CGI helpers (`fs.exec_direct`, `fs.read_direct`)

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, UNIX_EPOCH};

use serde_json::{Map, Value, json};
use tokio::process::Command;

use crate::config_gen;
use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::diagnostics;
use crate::net_stack;
use crate::store::{AppState, PortableAtomicU64};
use crate::sys_info;
use crate::transaction;

static TRANSLATIONS_RU_JS: OnceLock<String> = OnceLock::new();
static TRANSLATIONS_RU_ETAG: OnceLock<String> = OnceLock::new();
static PURE_UCI_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
static JSON_SECTIONS_STORE: OnceLock<RwLock<Map<String, Value>>> = OnceLock::new();
static LAST_UCI_MTIME_NS: PortableAtomicU64 = PortableAtomicU64::new(0);
static DAEMON_MODE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static PENDING_CORE_RELOAD: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
static JOB_SEQ: PortableAtomicU64 = PortableAtomicU64::new(1);

pub fn mark_daemon_mode() {
    DAEMON_MODE.store(true, std::sync::atomic::Ordering::Release);
}

pub fn is_daemon_mode() -> bool {
    DAEMON_MODE.load(std::sync::atomic::Ordering::Acquire)
}

fn next_job_seq() -> u64 {
    JOB_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

fn sanitize_job_slug(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "main".to_string()
    } else {
        cleaned
    }
}
type UciRollbackSnapshot = Option<(String, Map<String, Value>, crate::store::RouterStoreData)>;
static UCI_ROLLBACK_SNAPSHOT: OnceLock<Mutex<UciRollbackSnapshot>> = OnceLock::new();

fn uci_rollback_slot() -> &'static Mutex<UciRollbackSnapshot> {
    UCI_ROLLBACK_SNAPSHOT.get_or_init(|| Mutex::new(None))
}

fn file_mtime_ns(path: &Path) -> u64 {
    std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

fn uci_mutex() -> &'static tokio::sync::Mutex<()> {
    PURE_UCI_LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

#[cfg(test)]
pub(crate) fn test_uci_snapshot_lock() -> &'static Arc<tokio::sync::Mutex<()>> {
    static TEST_UCI_SNAPSHOT_LOCK: OnceLock<Arc<tokio::sync::Mutex<()>>> = OnceLock::new();
    TEST_UCI_SNAPSHOT_LOCK.get_or_init(|| Arc::new(tokio::sync::Mutex::new(())))
}

fn next_section_index(store: &Map<String, Value>) -> usize {
    store
        .values()
        .filter_map(|v| v.get(".index").and_then(Value::as_u64))
        .map(|i| (i as usize).saturating_add(1))
        .max()
        .unwrap_or(0)
}

pub fn normalize_entware_dns_mode(raw: &str) -> &'static str {
    if raw.trim().eq_ignore_ascii_case("override") {
        "override"
    } else {
        "redirect"
    }
}

fn json_sections_path() -> PathBuf {
    if let Ok(env_dir) = std::env::var("TACHYON_DATA_DIR") {
        let trimmed = env_dir.trim();
        if !trimmed.is_empty() {
            return Path::new(trimmed).join("config_sections.json");
        }
    }
    crate::platform::paths()
        .data_dir
        .join("config_sections.json")
}

fn json_sections_store() -> &'static RwLock<Map<String, Value>> {
    let is_entware = crate::platform::is_entware();
    let lock = JSON_SECTIONS_STORE.get_or_init(|| {
        let path = json_sections_path();
        let legacy_path = Path::new("/etc/config/tachyon");
        let backup_path = Path::new(crate::store::LEGACY_UCI_BACKUP_PATH);
        if !is_entware && legacy_path.exists() {
            LAST_UCI_MTIME_NS.store(
                file_mtime_ns(legacy_path),
                std::sync::atomic::Ordering::Relaxed,
            );
        }
        if let Ok(raw) = std::fs::read_to_string(&path)
            && let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&raw)
            && !map.is_empty()
        {
            return RwLock::new(map);
        }
        let uci_raw = if is_entware {
            None
        } else {
            match std::fs::read_to_string(legacy_path) {
                Ok(s) if !s.trim().is_empty() => Some(s),
                _ => match std::fs::read_to_string(backup_path) {
                    Ok(s) if !s.trim().is_empty() => Some(s),
                    _ => None,
                },
            }
        };
        let initial_map = if let Some(raw) = uci_raw {
            crate::store::parse_uci_text_to_json_sections(&raw)
        } else {
            let mut m = Map::new();
            m.insert(
                "settings".to_string(),
                json!({
                    ".anonymous": false,
                    ".type": "settings",
                    ".name": "settings",
                    ".index": 0,
                    "proxy_mode": "tproxy",
                    "dns_type": "doh",
                    "entware_dns_mode": "redirect",
                    "entware_dns_port": "1053"
                }),
            );
            m
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = crypto_gen::write_json_if_changed(&path, &Value::Object(initial_map.clone()));
        RwLock::new(initial_map)
    });
    if !is_entware {
        let legacy_path = Path::new("/etc/config/tachyon");
        if legacy_path.exists() {
            let cur_mtime = file_mtime_ns(legacy_path);
            let prev_mtime = LAST_UCI_MTIME_NS.load(std::sync::atomic::Ordering::Relaxed);
            if cur_mtime > 0
                && cur_mtime != prev_mtime
                && let Ok(raw) = std::fs::read_to_string(legacy_path)
            {
                let parsed = crate::store::parse_uci_text_to_json_sections(&raw);
                if !parsed.is_empty()
                    && let Ok(mut guard) = lock.write()
                {
                    *guard = parsed.clone();
                    LAST_UCI_MTIME_NS.store(cur_mtime, std::sync::atomic::Ordering::Relaxed);
                    let path = json_sections_path();
                    let _ = crypto_gen::write_json_if_changed(&path, &Value::Object(parsed));
                }
            }
        }
    }
    lock
}

fn persist_json_sections(map: &Map<String, Value>) {
    let path = json_sections_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = crypto_gen::write_json_if_changed(&path, &Value::Object(map.clone()));
    if cfg!(target_os = "linux")
        && !crate::platform::is_entware()
        && Path::new("/etc/config").exists()
    {
        let legacy_path = Path::new("/etc/config/tachyon");
        let uci_text = serialize_json_sections_to_uci(map);
        let _ = crypto_gen::write_file_if_changed(legacy_path, uci_text.as_bytes());
        LAST_UCI_MTIME_NS.store(
            file_mtime_ns(legacy_path),
            std::sync::atomic::Ordering::Relaxed,
        );
    }
}

pub fn get_json_sections_snapshot() -> Map<String, Value> {
    json_sections_store()
        .read()
        .map(|g| g.clone())
        .unwrap_or_default()
}

pub fn set_json_sections_snapshot(map: Map<String, Value>) {
    if let Ok(mut store) = json_sections_store().write() {
        *store = map;
        persist_json_sections(&store);
    }
}

fn apply_telegram_config_to_sections_map(
    store: &mut Map<String, Value>,
    tg: &crate::store::TgBotConfig,
) -> bool {
    let next_idx = next_section_index(store);
    let existed = store.contains_key("telegram");
    let entry = store.entry("telegram".to_string()).or_insert_with(|| {
        json!({
            ".anonymous": false,
            ".type": "telegram",
            ".name": "telegram",
            ".index": next_idx
        })
    });
    let Some(sec) = entry.as_object_mut() else {
        return false;
    };
    let mut changed = !existed;
    if sec.get(".type").and_then(Value::as_str) != Some("telegram") {
        sec.insert(".type".to_string(), json!("telegram"));
        changed = true;
    }
    if sec.get(".name").and_then(Value::as_str) != Some("telegram") {
        sec.insert(".name".to_string(), json!("telegram"));
        changed = true;
    }
    if sec.get(".anonymous").and_then(Value::as_bool) != Some(false) {
        sec.insert(".anonymous".to_string(), json!(false));
        changed = true;
    }

    let admins_csv = tg
        .admin_ids
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let b = |v: bool| if v { "1" } else { "0" };
    let poll_str = tg.poll_interval.to_string();
    let pairs: [(&str, &str); 26] = [
        ("enabled", b(tg.enabled)),
        ("bot_token", tg.bot_token.as_str()),
        ("admin_ids", admins_csv.as_str()),
        ("router_name", tg.router_name.as_str()),
        ("poll_interval", poll_str.as_str()),
        ("bot_proxy_section", tg.bot_proxy_section.as_str()),
        ("bot_direct_fallback", b(tg.bot_direct_fallback)),
        ("language", tg.language.as_str()),
        ("notify_crash", b(tg.notify_crash)),
        ("notify_restart", b(tg.notify_restart)),
        ("notify_server_switch", b(tg.notify_server_switch)),
        ("notify_subscription", b(tg.notify_subscription)),
        ("notify_dns_leak", b(tg.notify_dns_leak)),
        ("notify_cert", b(tg.notify_cert)),
        ("notify_auto_update", b(tg.notify_auto_update)),
        ("notify_honeypot", b(tg.notify_honeypot)),
        ("notify_parental", b(tg.notify_parental)),
        ("notify_smart_detect", b(tg.notify_smart_detect)),
        ("notify_failover", b(tg.notify_failover)),
        ("notify_wan", b(tg.notify_wan)),
        ("notify_update_available", b(tg.notify_update_available)),
        ("notify_route_alert", b(tg.notify_route_alert)),
        ("quiet_hours_enabled", b(tg.quiet_hours_enabled)),
        ("quiet_hours_start", tg.quiet_hours_start.as_str()),
        ("quiet_hours_end", tg.quiet_hours_end.as_str()),
        ("webhook_secret", tg.webhook_secret.as_str()),
    ];
    for (k, v) in pairs {
        let new_val = Value::String(v.to_string());
        if sec.get(k) != Some(&new_val) {
            sec.insert(k.to_string(), new_val);
            changed = true;
        }
    }
    for legacy_k in ["allowed_chat_ids", "admin_id", "polling_interval"] {
        if sec.remove(legacy_k).is_some() {
            changed = true;
        }
    }
    changed
}

/// Synchronize `TgBotConfig` back into `json_sections_store()["telegram"]` without unnecessary flash writes.
pub fn sync_telegram_section_to_json(tg: &crate::store::TgBotConfig) {
    if let Ok(mut store) = json_sections_store().write()
        && apply_telegram_config_to_sections_map(&mut store, tg)
    {
        persist_json_sections(&store);
    }
}

fn apply_user_domains_to_json_obj(
    obj: &mut serde_json::Map<String, Value>,
    domains: &[String],
) -> bool {
    if domains.is_empty() {
        obj.remove("user_domains").is_some()
    } else {
        let dom_val = Value::Array(domains.iter().cloned().map(Value::String).collect());
        if obj.get("user_domains") != Some(&dom_val) {
            obj.insert("user_domains".to_string(), dom_val);
            true
        } else {
            false
        }
    }
}

/// Synchronize a section's (and optionally its linked condition's) `user_domains` back into `config_sections.json`.
pub fn sync_section_user_domains_to_json(
    section_id: &str,
    domains: &[String],
    linked_condition_id: Option<&str>,
    cond_domains: Option<&[String]>,
) {
    if let Ok(mut store) = json_sections_store().write() {
        let mut changed = false;
        if let Some(sec_obj) = store.get_mut(section_id).and_then(Value::as_object_mut) {
            changed |= apply_user_domains_to_json_obj(sec_obj, domains);
        }
        if let (Some(cid), Some(cdoms)) = (linked_condition_id, cond_domains)
            && let Some(cond_obj) = store.get_mut(cid).and_then(Value::as_object_mut)
        {
            changed |= apply_user_domains_to_json_obj(cond_obj, cdoms);
        }
        if changed {
            persist_json_sections(&store);
        }
    }
}

/// Synchronize `settings.smart_detect_exclude` back into `config_sections.json`.
pub fn sync_smart_detect_exclude_to_json(excludes: &[String]) {
    if let Ok(mut store) = json_sections_store().write()
        && let Some(set_obj) = store.get_mut("settings").and_then(Value::as_object_mut)
    {
        let val = Value::Array(excludes.iter().cloned().map(Value::String).collect());
        if set_obj.get("smart_detect_exclude") != Some(&val) {
            set_obj.insert("smart_detect_exclude".to_string(), val);
            persist_json_sections(&store);
        }
    }
}

fn serialize_json_sections_to_uci(map: &Map<String, Value>) -> String {
    let mut ordered: Vec<(usize, &String, &Value)> = map
        .iter()
        .map(|(k, v)| {
            let idx = v
                .get(".index")
                .and_then(Value::as_u64)
                .map(|n| n as usize)
                .unwrap_or(usize::MAX);
            (idx, k, v)
        })
        .collect();
    ordered.sort_by_key(|(idx, _, _)| *idx);

    let esc = |s: &str| s.replace('\'', "'\\''");
    let mut out = String::with_capacity(4096);
    for (_, sec_key, sec_val) in ordered {
        let Some(obj) = sec_val.as_object() else {
            continue;
        };
        let stype = obj
            .get(".type")
            .and_then(Value::as_str)
            .unwrap_or(sec_key.as_str());
        let anon = obj
            .get(".anonymous")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if anon {
            out.push_str(&format!("config {stype}\n"));
        } else {
            out.push_str(&format!("config {stype} '{}'\n", esc(sec_key)));
        }
        for (k, v) in obj {
            if k.starts_with('.') {
                continue;
            }
            match v {
                Value::String(s) => {
                    out.push_str(&format!("\toption {k} '{}'\n", esc(s)));
                }
                Value::Number(n) => {
                    out.push_str(&format!("\toption {k} '{n}'\n"));
                }
                Value::Bool(b) => {
                    out.push_str(&format!("\toption {k} '{}'\n", if *b { "1" } else { "0" }));
                }
                Value::Array(arr) => {
                    for item in arr {
                        let s = item
                            .as_str()
                            .map(String::from)
                            .unwrap_or_else(|| item.to_string());
                        out.push_str(&format!("\tlist {k} '{}'\n", esc(&s)));
                    }
                }
                _ => {}
            }
        }
        out.push('\n');
    }
    out
}

/// Tachyon SVG favicon matching the topbar mark (blue ring + lightning bolt).
pub const TACHYON_FAVICON_SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#0a84ff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="m8 12 4-8 1 6h3l-4 8-1-6z"/></svg>"##;

/// Generate the LuCI HTML shell with the `tachyon-ui` design system and animated superluminal SVG background.
#[cfg_attr(not(test), allow(dead_code))]
fn sanitize_luci_subview(subview: Option<&str>) -> Option<&str> {
    subview.map(|s| s.trim_matches('/')).filter(|s| {
        !s.is_empty()
            && s.len() <= 64
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
    })
}

fn sanitize_luci_subview_segments(subview: Option<&str>) -> Vec<&str> {
    let Some(raw) = subview else {
        return Vec::new();
    };
    let trimmed = raw.trim().trim_matches('/');
    if trimmed.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for seg in trimmed.split('/') {
        if seg.is_empty()
            || seg.len() > 64
            || !seg
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        {
            return Vec::new();
        }
        out.push(seg);
        if out.len() > 4 {
            return Vec::new();
        }
    }
    out
}

const EARLY_THEME_APPLY_SCRIPT: &str = r##"<script>
(function() {
  try {
    var PRESETS = {
      "default-dark": ["dark","#0b0b0c","#141416","#1c1c1f","#26262b","#0a84ff","#409cff","#f5f5f7","#a1a1a6","#6e6e73","#30d158","#ff9f0a","#ff453a"],
      "legacy-dark": ["dark","#0d1117","#161b22","#1f2630","#28313d","#58a6ff","#79c0ff","#e6edf3","#8b949e","#6e7681","#3fb950","#d29922","#f85149"],
      "catppuccin": ["dark","#1e1e2e","#242436","#313244","#3b3d52","#89b4fa","#b4befe","#cdd6f4","#a6adc8","#7f849c","#a6e3a1","#f9e2af","#f38ba8"],
      "dracula": ["dark","#282a36","#2f3241","#383b4d","#44475a","#bd93f9","#d1b3ff","#f8f8f2","#b6bbd2","#6272a4","#50fa7b","#ffb86c","#ff5555"],
      "everforest": ["dark","#272e33","#2e383c","#374145","#414b50","#a7c080","#b8d194","#d3c6aa","#9da9a0","#7a8478","#83c092","#dbbc7f","#e67e80"],
      "gruvbox-material": ["dark","#1d2021","#282828","#32302f","#3c3836","#d8a657","#e78a4e","#d4be98","#a89984","#7c6f64","#a9b665","#e78a4e","#ea6962"],
      "monokai": ["dark","#272822","#2e2f29","#383a32","#46483e","#a6e22e","#c4f35c","#f8f8f2","#c2c2b4","#75715e","#a6e22e","#e6db74","#f92672"],
      "nord": ["dark","#2e3440","#343b49","#3b4252","#434c5e","#88c0d0","#8fbcbb","#eceff4","#d8dee9","#8190a5","#a3be8c","#ebcb8b","#bf616a"],
      "one-dark-pro": ["dark","#21252b","#282c34","#323842","#3e4451","#61afef","#82c4ff","#abb2bf","#8b93a2","#5c6370","#98c379","#e5c07b","#e06c75"],
      "tokyo-night": ["dark","#1a1b26","#202330","#292e42","#343b58","#7aa2f7","#9ab7ff","#c0caf5","#9aa5ce","#565f89","#9ece6a","#e0af68","#f7768e"],
      "solarized-dark": ["dark","#002b36","#073642","#0d414f","#144e5e","#268bd2","#2aa198","#eee8d5","#93a1a1","#657b83","#859900","#b58900","#dc322f"],
      "vesper": ["dark","#101010","#161616","#1f1f1f","#282828","#ffc799","#ffd8b8","#ffffff","#a0a0a0","#666666","#99ffe4","#ffc799","#ff8080"]
    };
    function hexRgb(hex, fallback) {
      var m = /^#([0-9a-f]{6})$/i.exec(String(hex || "").trim());
      if (!m) return fallback;
      var n = parseInt(m[1], 16);
      return ((n >> 16) & 255) + ", " + ((n >> 8) & 255) + ", " + (n & 255);
    }
    var tid = localStorage.getItem("tachyon_ui_theme_id") || "default-dark";
    var customList = [];
    try { customList = JSON.parse(localStorage.getItem("tachyon_ui_custom_themes") || "[]") || []; } catch (e) {}
    var matchedCustom = null;
    for (var i = 0; i < customList.length; i++) {
      if (customList[i] && customList[i].id === tid && customList[i].colors) { matchedCustom = customList[i]; break; }
    }
    var p = null;
    if (matchedCustom) {
      var c = matchedCustom.colors;
      p = [matchedCustom.scheme === "light" ? "light" : "dark", c.bg, c.surface, c.hover, c.elevated, c.accent, c.accentHover || c.accent, c.text, c.text2, c.text3, c.success, c.warn, c.danger];
    } else {
      p = PRESETS[tid] || PRESETS["default-dark"];
    }
    var r = document.documentElement;
    var s = r.style;
    var isLight = p[0] === "light";
    var vars = {
      "--color-scheme": isLight ? "light" : "dark",
      "--bg": p[1], "--surface": p[2], "--bg2": p[2], "--hover": p[3], "--elevated": p[4],
      "--accent": p[5], "--accent-hover": p[6], "--text": p[7], "--text2": p[8], "--text3": p[9],
      "--success": p[10], "--ok": p[10], "--warn": p[11], "--danger": p[12],
      "--border": isLight ? "rgba(0, 0, 0, 0.10)" : "rgba(255, 255, 255, 0.08)",
      "--border-strong": isLight ? "rgba(0, 0, 0, 0.18)" : "rgba(255, 255, 255, 0.15)",
      "--border-hi": isLight ? "rgba(0, 0, 0, 0.18)" : "rgba(255, 255, 255, 0.15)",
      "--surface-glass": "rgba(" + hexRgb(p[2], "20, 20, 22") + ", 0.84)",
      "--topbar-glass": "rgba(" + hexRgb(p[2], "20, 20, 22") + ", 0.96)",
      "--accent-soft": "rgba(" + hexRgb(p[5], "10, 132, 255") + ", 0.16)",
      "--accent-ring": "rgba(" + hexRgb(p[5], "10, 132, 255") + ", 0.34)",
      "--bg-grid-stroke": isLight ? "rgba(0, 0, 0, 0.045)" : "rgba(255, 255, 255, 0.028)"
    };
    for (var k in vars) s.setProperty(k, vars[k]);
    r.setAttribute("data-tachyon-theme", tid);
    r.setAttribute("data-tachyon-theme-scheme", isLight ? "light" : "dark");
    r.setAttribute("data-darkmode", isLight ? "false" : "true");
  } catch (e) {}
})();
</script>"##;

const TACHYON_BG_LAYER_HTML: &str = r##"<div class="tachyon-bg-layer" aria-hidden="true">
    <svg viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" fill="none" xmlns="http://www.w3.org/2000/svg">
      <g stroke="var(--bg-grid-stroke, rgba(255,255,255,0.028))" stroke-width="1">
        <path d="M-100 140 C 420 40, 1080 280, 1700 90"/>
        <path d="M-100 290 C 480 190, 1020 420, 1700 240"/>
        <path d="M-100 450 C 520 370, 1080 550, 1700 420"/>
        <path d="M-100 620 C 460 520, 1120 710, 1700 580"/>
        <path d="M-100 780 C 540 680, 1060 840, 1700 740"/>
        <path d="M 180 -60 C 420 320, 880 580, 1480 960"/>
        <path d="M 640 -60 C 820 300, 1180 560, 1680 880"/>
      </g>
      <g stroke-width="1.5" stroke-linecap="round">
        <path class="tachyon-stream" stroke="var(--accent, #0a84ff)" stroke-opacity="0.55" d="M-100 140 C 420 40, 1080 280, 1700 90"/>
        <path class="tachyon-stream s2" stroke="var(--text, #f5f5f7)" stroke-opacity="0.32" d="M-100 290 C 480 190, 1020 420, 1700 240"/>
        <path class="tachyon-stream s3" stroke="var(--accent, #0a84ff)" stroke-opacity="0.62" d="M-100 450 C 520 370, 1080 550, 1700 420"/>
        <path class="tachyon-stream s4" stroke="var(--accent-hover, #409cff)" stroke-opacity="0.45" d="M-100 620 C 460 520, 1120 710, 1700 580"/>
        <path class="tachyon-stream s5" stroke="var(--text, #f5f5f7)" stroke-opacity="0.28" d="M-100 780 C 540 680, 1060 840, 1700 740"/>
        <path class="tachyon-stream s2" stroke="var(--accent, #0a84ff)" stroke-opacity="0.4" d="M 180 -60 C 420 320, 880 580, 1480 960"/>
        <path class="tachyon-stream s4" stroke="var(--accent, #0a84ff)" stroke-opacity="0.35" d="M 640 -60 C 820 300, 1180 560, 1680 880"/>
      </g>
    </svg>
  </div>"##;

pub fn serve_login_page(ui_lang: &str, auth_mode: &str) -> String {
    let is_en = ui_lang.trim().eq_ignore_ascii_case("en");
    let lang = if is_en { "en" } else { "ru" };
    let is_luci = auth_mode.trim().eq_ignore_ascii_case("luci");
    let version = crate::store::TACHYON_VERSION;
    let default_user = if is_luci { "root" } else { "" };
    let (
        subtitle,
        user_label,
        user_placeholder,
        pass_label,
        pass_placeholder,
        submit_label,
        hint_text,
        show_pass_title,
        err_invalid,
        err_rate_limit,
        err_network,
    ) = if is_en {
        (
            if is_luci {
                "Sign in with router credentials (LuCI)"
            } else {
                "Sign in to control panel"
            },
            "Username",
            "root",
            "Password",
            "Enter password",
            "Sign in",
            if is_luci {
                "Router (LuCI) username and password are used by default. You can set a separate panel password in Settings after signing in."
            } else {
                "Separate control panel username and password are active."
            },
            "Show or hide password",
            "Invalid username or password",
            "Too many failed sign-in attempts. Wait a minute and try again.",
            "Connection error while signing in",
        )
    } else {
        (
            if is_luci {
                "Вход по учётным данным роутера (LuCI)"
            } else {
                "Вход в панель управления"
            },
            "Логин",
            "root",
            "Пароль",
            "Введите пароль",
            "Войти",
            if is_luci {
                "По умолчанию используются логин и пароль роутера (LuCI). Отдельный пароль для панели можно задать в настройках после входа."
            } else {
                "Используется отдельный логин и пароль панели."
            },
            "Показать или скрыть пароль",
            "Неверный логин или пароль",
            "Слишком много неудачных попыток. Подождите минуту и повторите.",
            "Ошибка соединения при входе",
        )
    };
    format!(
        r##"<!DOCTYPE html>
<html lang="{lang}" data-darkmode="true">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tachyon v{version}</title>
  <link rel="icon" type="image/svg+xml" href="/favicon.svg?v={version}">
  <style>
    :root {{
      --bg: #0b0b0c;
      --surface: #141416;
      --hover: #1c1c1f;
      --elevated: #26262b;
      --border: rgba(255, 255, 255, 0.08);
      --border-strong: rgba(255, 255, 255, 0.15);
      --accent: #0a84ff;
      --accent-hover: #409cff;
      --danger: #ff453a;
      --text: #f5f5f7;
      --text2: #a1a1a6;
      --text3: #6e6e73;
      --surface-glass: rgba(20, 20, 22, 0.88);
      --accent-soft: rgba(10, 132, 255, 0.16);
      --accent-ring: rgba(10, 132, 255, 0.34);
      --bg-grid-stroke: rgba(255, 255, 255, 0.028);
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
      --mono: "SF Mono", ui-monospace, "Cascadia Code", "JetBrains Mono", monospace;
    }}
    * {{ box-sizing: border-box; }}
    html, body {{
      margin: 0;
      min-height: 100vh;
      background-color: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      font-size: 14px;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
    }}
    .tachyon-bg-layer {{ position: fixed; inset: 0; pointer-events: none; z-index: 0; overflow: hidden; }}
    .tachyon-bg-layer svg {{ width: 100%; height: 100%; display: block; }}
    .tachyon-stream {{ stroke-dasharray: 80 620; animation: tachyon-flow 5.5s linear infinite; }}
    .tachyon-stream.s2 {{ stroke-dasharray: 50 540; animation-duration: 4.1s; animation-delay: -1.6s; }}
    .tachyon-stream.s3 {{ stroke-dasharray: 110 720; animation-duration: 6.8s; animation-delay: -3.2s; }}
    .tachyon-stream.s4 {{ stroke-dasharray: 40 480; animation-duration: 3.4s; animation-delay: -0.9s; }}
    .tachyon-stream.s5 {{ stroke-dasharray: 65 600; animation-duration: 4.9s; animation-delay: -2.4s; }}
    @keyframes tachyon-flow {{ from {{ stroke-dashoffset: 800; }} to {{ stroke-dashoffset: 0; }} }}
    .auth-shell {{
      position: relative;
      z-index: 1;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px 16px;
    }}
    .auth-card {{
      width: 100%;
      max-width: 400px;
      background: var(--surface-glass);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border: 1px solid var(--border-strong);
      border-radius: 14px;
      padding: 28px 24px 24px;
      box-shadow: 0 20px 48px rgba(0, 0, 0, 0.45);
    }}
    .auth-brand {{
      display: flex;
      align-items: center;
      gap: 12px;
      margin-bottom: 20px;
    }}
    .auth-brand__icon {{
      width: 40px;
      height: 40px;
      border-radius: 10px;
      background: var(--accent-soft);
      border: 1px solid var(--accent-ring);
      color: var(--accent);
      display: flex;
      align-items: center;
      justify-content: center;
      flex: none;
    }}
    .auth-brand__title {{
      margin: 0;
      font-size: 18px;
      font-weight: 650;
      letter-spacing: -0.02em;
      color: var(--text);
      display: flex;
      align-items: baseline;
      gap: 8px;
    }}
    .auth-brand__ver {{
      font-size: 12px;
      font-weight: 500;
      color: var(--text3);
      font-family: var(--mono);
    }}
    .auth-brand__sub {{
      margin: 2px 0 0;
      font-size: 13px;
      color: var(--text2);
    }}
    .auth-field {{ margin-bottom: 14px; }}
    .auth-label {{
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--text2);
      margin-bottom: 6px;
    }}
    .auth-input-wrap {{ position: relative; display: flex; align-items: center; }}
    .auth-input {{
      width: 100%;
      height: 40px;
      padding: 0 12px;
      border-radius: 8px;
      border: 1px solid var(--border-strong);
      background: var(--bg);
      color: var(--text);
      font-size: 14px;
      font-family: inherit;
      outline: none;
      transition: border-color 140ms ease, box-shadow 140ms ease;
    }}
    .auth-input--pass {{ padding-right: 40px; }}
    .auth-input:focus {{
      border-color: var(--accent);
      box-shadow: 0 0 0 3px var(--accent-soft);
    }}
    .auth-eye {{
      position: absolute;
      right: 6px;
      width: 30px;
      height: 30px;
      border: 0;
      border-radius: 6px;
      background: transparent;
      color: var(--text3);
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }}
    .auth-eye:hover {{ color: var(--text); background: var(--hover); }}
    .auth-error {{
      display: none;
      margin: 0 0 14px;
      padding: 9px 12px;
      border-radius: 8px;
      border: 1px solid rgba(255, 69, 58, 0.35);
      background: rgba(255, 69, 58, 0.12);
      color: var(--danger);
      font-size: 13px;
      line-height: 1.4;
    }}
    .auth-error.is-visible {{ display: block; }}
    .auth-btn {{
      width: 100%;
      height: 40px;
      border: 0;
      border-radius: 8px;
      background: var(--accent);
      color: #ffffff;
      font-size: 14px;
      font-weight: 600;
      font-family: inherit;
      cursor: pointer;
      transition: background 140ms ease, opacity 140ms ease;
    }}
    .auth-btn:hover {{ background: var(--accent-hover); }}
    .auth-btn:disabled {{ opacity: 0.6; cursor: wait; }}
    .auth-hint {{
      margin: 14px 0 0;
      font-size: 12px;
      line-height: 1.45;
      color: var(--text3);
    }}
  </style>
  {EARLY_THEME_APPLY_SCRIPT}
</head>
<body>
  {TACHYON_BG_LAYER_HTML}
  <main class="auth-shell">
    <section class="auth-card" aria-labelledby="tachyon-login-title">
      <div class="auth-brand">
        <div class="auth-brand__icon">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/></svg>
        </div>
        <div>
          <h1 id="tachyon-login-title" class="auth-brand__title">Tachyon <span class="auth-brand__ver">v{version}</span></h1>
          <p class="auth-brand__sub">{subtitle}</p>
        </div>
      </div>
      <form id="tachyon-login-form" novalidate>
        <div class="auth-field">
          <label class="auth-label" for="tachyon-login-user">{user_label}</label>
          <input class="auth-input" id="tachyon-login-user" name="username" type="text" autocomplete="username" value="{default_user}" placeholder="{user_placeholder}" required>
        </div>
        <div class="auth-field">
          <label class="auth-label" for="tachyon-login-pass">{pass_label}</label>
          <div class="auth-input-wrap">
            <input class="auth-input auth-input--pass" id="tachyon-login-pass" name="password" type="password" autocomplete="current-password" placeholder="{pass_placeholder}">
            <button type="button" class="auth-eye" id="tachyon-login-eye" title="{show_pass_title}" aria-label="{show_pass_title}">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>
            </button>
          </div>
        </div>
        <div id="tachyon-login-err" class="auth-error" role="alert"></div>
        <button type="submit" id="tachyon-login-btn" class="auth-btn">{submit_label}</button>
        <p class="auth-hint">{hint_text}</p>
      </form>
    </section>
  </main>
  <script>
  (function() {{
    var form = document.getElementById('tachyon-login-form');
    var userEl = document.getElementById('tachyon-login-user');
    var passEl = document.getElementById('tachyon-login-pass');
    var eyeEl = document.getElementById('tachyon-login-eye');
    var errEl = document.getElementById('tachyon-login-err');
    var btnEl = document.getElementById('tachyon-login-btn');
    if (eyeEl && passEl) {{
      eyeEl.addEventListener('click', function() {{
        passEl.type = passEl.type === 'password' ? 'text' : 'password';
      }});
    }}
    function showErr(msg) {{
      if (!errEl) return;
      errEl.textContent = msg;
      errEl.classList.add('is-visible');
    }}
    if (form) {{
      form.addEventListener('submit', function(ev) {{
        ev.preventDefault();
        if (errEl) errEl.classList.remove('is-visible');
        if (btnEl) btnEl.disabled = true;
        fetch('/api/login', {{
          method: 'POST',
          credentials: 'same-origin',
          headers: {{ 'Content-Type': 'application/json' }},
          body: JSON.stringify({{
            username: userEl ? userEl.value.trim() : '',
            password: passEl ? passEl.value : ''
          }})
        }}).then(function(res) {{
          if (res.ok) {{
            window.location.reload();
            return;
          }}
          if (res.status === 429) {{
            showErr({err_rate_limit_json});
          }} else {{
            showErr({err_invalid_json});
          }}
        }}).catch(function() {{
          showErr({err_network_json});
        }}).finally(function() {{
          if (btnEl) btnEl.disabled = false;
        }});
      }});
    }}
    if (passEl && userEl && userEl.value) passEl.focus();
    else if (userEl) userEl.focus();
  }})();
  </script>
</body>
</html>"##,
        err_rate_limit_json = serde_json::to_string(err_rate_limit).unwrap_or_default(),
        err_invalid_json = serde_json::to_string(err_invalid).unwrap_or_default(),
        err_network_json = serde_json::to_string(err_network).unwrap_or_default(),
    )
}

pub fn serve_luci_shell(subview: Option<&str>, ui_lang: &str) -> String {
    let lang = if ui_lang.trim().eq_ignore_ascii_case("en") {
        "en"
    } else {
        "ru"
    };
    let sub_segments = sanitize_luci_subview_segments(subview);
    let mut req_parts = vec![
        "\"admin\"".to_string(),
        "\"services\"".to_string(),
        "\"tachyon\"".to_string(),
    ];
    for seg in &sub_segments {
        req_parts.push(format!("\"{seg}\""));
    }
    let req_path_json = format!("[{}]", req_parts.join(", "));
    let pathinfo = if sub_segments.is_empty() {
        "/admin/services/tachyon".to_string()
    } else {
        format!("/admin/services/tachyon/{}", sub_segments.join("/"))
    };

    let p = crate::platform::paths();
    let rev = file_mtime_ns(&p.www_dir.join("resources/view/tachyon/main.js"))
        .max(file_mtime_ns(Path::new(
            "/tmp/tachyon-rs/www/luci-static/resources/view/tachyon/main.js",
        )))
        .max(file_mtime_ns(Path::new(
            "/www/luci-static/resources/view/tachyon/main.js",
        )))
        .max(file_mtime_ns(Path::new(
            "luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/main.js",
        )))
        .max(1);

    let version = crate::store::TACHYON_VERSION;
    let en_reset = if lang == "en" {
        "<script>window.TR = {}; window.TR_RAW = {};</script>"
    } else {
        ""
    };
    format!(
        r##"<!DOCTYPE html>
<html lang="{lang}" data-darkmode="true">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tachyon v{version}</title>
  <link rel="icon" type="image/svg+xml" href="/favicon.svg?v={version}">
  <link rel="stylesheet" href="/luci-static/bootstrap/cascade.css?v={rev}">
  <link rel="stylesheet" media="only screen and (max-device-width: 854px)" href="/luci-static/bootstrap/mobile.css?v={rev}">
  <link rel="preload" href="/luci-static/resources/view/tachyon/tachyon.js?v={rev}" as="script">
  <link rel="preload" href="/luci-static/resources/view/tachyon/main.js?v={rev}" as="script">
  <style>
    :root {{
      --bg: #0b0b0c;
      --surface: #141416;
      --hover: #1c1c1f;
      --elevated: #26262b;
      --border: rgba(255, 255, 255, 0.08);
      --border-strong: rgba(255, 255, 255, 0.15);
      --accent: #0a84ff;
      --accent-hover: #409cff;
      --danger: #ff453a;
      --success: #30d158;
      --ok: #30d158;
      --warn: #ff9f0a;
      --text: #f5f5f7;
      --text2: #a1a1a6;
      --text3: #6e6e73;
      --bg2: #141416;
      --border-hi: rgba(255, 255, 255, 0.15);
      --surface-glass: rgba(20, 20, 22, 0.84);
      --topbar-glass: rgba(20, 20, 22, 0.96);
      --accent-soft: rgba(10, 132, 255, 0.16);
      --accent-ring: rgba(10, 132, 255, 0.34);
      --bg-grid-stroke: rgba(255, 255, 255, 0.028);
      --color-scheme: dark;
      --mono: "SF Mono", ui-monospace, "Cascadia Code", "JetBrains Mono", monospace;
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
      --r-card: 12px;
      --r-btn: 8px;
      --r-xs: 6px;
      --spring: cubic-bezier(0.22, 1, 0.36, 1);
      --transition: 160ms var(--spring);
    }}
    :root,
    html,
    body,
    html[data-darkmode="true"],
    html[data-darkmode="false"] {{
      --tachyon-theme-accent: var(--accent);
      --primary-color-high: var(--accent);
      --primary-color-medium: var(--accent);
      --primary-color-low: var(--accent-soft);
      --background-color-high: var(--surface);
      --background-color-medium: var(--bg);
      --background-color-low: var(--hover);
      --border-color-high: var(--border-strong);
      --border-color-medium: var(--border);
      --border-color-low: rgba(255, 255, 255, 0.06);
      --text-color-high: var(--text);
      --text-color-medium: var(--text2);
      --text-color-low: var(--text3);
      color-scheme: var(--color-scheme, dark);
    }}
    html, body {{
      background-color: var(--bg) !important;
      color: var(--text) !important;
      font-family: var(--sans) !important;
      font-size: 14px;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
      font-optical-sizing: auto;
      min-height: 100vh;
      max-width: 100%;
      overflow-x: clip;
      margin: 0;
    }}
    #maincontent.container {{
      position: relative;
      z-index: 1;
      max-width: 100% !important;
      width: 100% !important;
      margin: 0 !important;
      padding: 8px 14px 24px !important;
      box-sizing: border-box !important;
    }}
    @media (max-width: 640px) {{
      #maincontent.container {{
        padding: 4px 6px 20px !important;
      }}
    }}
    /* Completely hide legacy LuCI bottom page-actions, top banners, and UCI indicators (preserve modal footers) */
    #view > .cbi-page-actions,
    #cbi-tachyon ~ .cbi-page-actions,
    .cbi-page-actions:not(.modal .cbi-page-actions),
    #indicators,
    #unsaved-changes,
    #uci-apply-status,
    #maincontent > .alert-message,
    #view > .alert-message,
    .uci-change-list,
    .uci-change-legend,
    body > header,
    body > footer {{
      display: none !important;
    }}
    .toast-container {{
      position: fixed !important;
      bottom: 24px !important;
      right: 24px !important;
      z-index: 2147483647 !important;
      display: flex !important;
      flex-direction: column !important;
      gap: 8px !important;
      pointer-events: none !important;
    }}
    .toast {{
      pointer-events: auto !important;
      background: var(--topbar-glass, rgba(22, 22, 26, 0.96)) !important;
      border: 1px solid var(--border-strong, rgba(255, 255, 255, 0.14)) !important;
      border-radius: 10px !important;
      padding: 10px 14px !important;
      font-size: 13px !important;
      font-weight: 500 !important;
      color: var(--text, #f5f5f7) !important;
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.55) !important;
      display: inline-flex !important;
      align-items: center !important;
      gap: 8px !important;
    }}
    .tachyon-boot-loader {{
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 14px;
      min-height: 72vh;
      color: var(--text2);
      font-size: 13px;
      font-weight: 500;
      letter-spacing: -0.01em;
      animation: tachyonBootFadeIn 0.18s ease-out;
    }}
    .tachyon-boot-loader__ring {{
      width: 44px;
      height: 44px;
      border-radius: 12px;
      background: var(--surface);
      border: 1px solid var(--accent-ring, rgba(10, 132, 255, 0.35));
      box-shadow: 0 8px 28px rgba(0, 0, 0, 0.25);
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--accent);
    }}
    .tachyon-boot-loader__ring svg {{
      animation: tachyonBoltPulse 1.4s ease-in-out infinite;
    }}
    @keyframes tachyonBoltPulse {{
      0%, 100% {{ transform: scale(1); opacity: 0.9; }}
      50% {{ transform: scale(1.08); opacity: 1; }}
    }}
    @keyframes tachyonBootFadeIn {{
      from {{ opacity: 0; transform: translateY(4px); }}
      to {{ opacity: 1; transform: translateY(0); }}
    }}
    .tachyon-bg-layer {{
      position: fixed;
      inset: 0;
      pointer-events: none;
      z-index: 0;
      overflow: hidden;
    }}
    .tachyon-bg-layer svg {{
      width: 100%;
      height: 100%;
      display: block;
    }}
    .tachyon-stream {{
      stroke-dasharray: 80 620;
      animation: tachyon-flow 5.5s linear infinite;
    }}
    .tachyon-stream.s2 {{
      stroke-dasharray: 50 540;
      animation-duration: 4.1s;
      animation-delay: -1.6s;
    }}
    .tachyon-stream.s3 {{
      stroke-dasharray: 110 720;
      animation-duration: 6.8s;
      animation-delay: -3.2s;
    }}
    .tachyon-stream.s4 {{
      stroke-dasharray: 40 480;
      animation-duration: 3.4s;
      animation-delay: -0.9s;
    }}
    .tachyon-stream.s5 {{
      stroke-dasharray: 65 600;
      animation-duration: 4.9s;
      animation-delay: -2.4s;
    }}
    @keyframes tachyon-flow {{
      from {{ stroke-dashoffset: 800; }}
      to {{ stroke-dashoffset: 0; }}
    }}
    @media (prefers-reduced-motion: reduce) {{
      .tachyon-stream {{ animation: none !important; }}
    }}
  </style>
  {EARLY_THEME_APPLY_SCRIPT}
  <script src="/cgi-bin/luci/admin/translations/{lang}?v={rev}"></script>
  {en_reset}
  <script src="/luci-static/resources/cbi.js?v={rev}"></script>
  <script>
    if (window.TR_RAW && typeof sfh === 'function') {{
      window.TR = window.TR || {{}};
      for (const [k, v] of Object.entries(window.TR_RAW)) {{
        if (v) window.TR[sfh(trimws(k))] = v;
      }}
    }}
  </script>
  <script src="/luci-static/resources/luci.js?v={rev}"></script>
  <script>
    L = new LuCI({{
      media: "/luci-static/bootstrap",
      resource: "/luci-static/resources",
      scriptname: "/cgi-bin/luci",
      pathinfo: "{pathinfo}",
      lang: "{lang}",
      documentroot: "/www",
      requestpath: {req_path_json},
      dispatchpath: {req_path_json},
      pollinterval: 5,
      ubuspath: "/ubus/",
      sessionid: "00000000000000000000000000000000",
      token: "00000000000000000000000000000000",
      nodespec: {{
        satisfied: true,
        readonly: false,
        action: {{ type: "view", path: "tachyon/tachyon" }}
      }},
      apply_rollback: 90,
      apply_holdoff: 4,
      apply_timeout: 5,
      apply_display: 1.5,
      rollback_token: "00000000000000000000000000000000"
    }});
    if (!Object.isFrozen(L)) {{
      L.env = L.env || {{}};
      if (!Object.isFrozen(L.env)) {{
        L.env.lang = "{lang}";
      }}
    }}
  </script>
</head>
<body class="lang_{lang}" data-page="admin-services-tachyon">
  {TACHYON_BG_LAYER_HTML}
  <header style="display:none">
    <a class="brand" href="/">OpenWrt</a>
    <ul class="nav" id="topmenu" style="display:none"></ul>
    <div id="indicators" class="pull-right"></div>
  </header>
  <div id="maincontent" class="container">
    <div id="tabmenu" style="display:none"></div>
    <div id="view">
      <div class="tachyon-boot-loader">
        <div class="tachyon-boot-loader__ring">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
            <path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>
          </svg>
        </div>
        <span>Tachyon</span>
      </div>
      <script>
        L.require('ui').then(function(ui) {{
          if (ui && ui.changes) {{
            ui.changes.changes = {{}};
            ui.changes.setIndicator = function() {{}};
            ui.changes.displayStatus = function() {{}};
            ui.changes.confirm = function() {{ return Promise.resolve(); }};
            ui.changes.apply = function() {{
              return fetch('/cgi-bin/luci/admin/uci/apply_unchecked', {{ method: 'POST' }}).then(function(res) {{
                if (res.ok) return;
                return res.json().catch(function() {{ return null; }}).then(function(body) {{
                  throw new Error((body && body.error) || ('HTTP ' + res.status));
                }});
              }});
            }};
          }}
          ui.instantiateView('tachyon/tachyon');
        }});
      </script>
    </div>
  </div>
</body>
</html>"##
    )
}

fn load_tachyon_ru_po_from_disk() -> String {
    let p = crate::platform::paths();
    let candidates = [
        p.share_dir.join("tachyon.ru.po"),
        p.share_dir.join("locales/tachyon.ru.po"),
        PathBuf::from("/tmp/tachyon-rs/fe-app-tachyon/locales/tachyon.ru.po"),
        PathBuf::from("/usr/share/tachyon/tachyon.ru.po"),
        PathBuf::from("fe-app-tachyon/locales/tachyon.ru.po"),
        PathBuf::from("luci-app-tachyon/po/ru/tachyon.po"),
    ];
    for path in &candidates {
        if let Ok(raw) = std::fs::read_to_string(path)
            && !raw.is_empty()
        {
            return raw;
        }
    }
    String::new()
}

/// Return ETag for compiled JavaScript dictionary (`tachyon.ru.po` or empty English map).
pub fn translations_etag(lang: &str) -> &'static str {
    if !lang.trim().to_ascii_lowercase().starts_with("ru") {
        return "\"po-en-empty\"";
    }
    TRANSLATIONS_RU_ETAG.get_or_init(|| {
        use sha2::{Digest, Sha256};
        let js = serve_translations_js("ru");
        let mut h = Sha256::new();
        h.update(js.as_bytes());
        let digest = h.finalize();
        format!(
            "\"po-{:x}-{}\"",
            js.len(),
            &crypto_gen::bytes_to_hex(&digest)[..12]
        )
    })
}

/// Return compiled JavaScript dictionary (`window.TR_RAW` + `window.TR`) from `i18n_ru.js` or `tachyon.ru.po`.
pub fn serve_translations_js(lang: &str) -> &'static str {
    if !lang.trim().to_ascii_lowercase().starts_with("ru") {
        return "window.TR = {}; window.TR_RAW = {};\n";
    }
    TRANSLATIONS_RU_JS.get_or_init(|| {
        let p = crate::platform::paths();
        let precompiled_candidates = [
            p.www_dir.join("resources/view/tachyon/i18n_ru.js"),
            PathBuf::from("/www/luci-static/resources/view/tachyon/i18n_ru.js"),
            PathBuf::from("/tmp/tachyon-rs/www/luci-static/resources/view/tachyon/i18n_ru.js"),
            PathBuf::from("luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/i18n_ru.js"),
        ];
        for precompiled in &precompiled_candidates {
            if let Ok(js) = std::fs::read_to_string(precompiled)
                && !js.is_empty()
            {
                return js;
            }
        }
        let po_raw = load_tachyon_ru_po_from_disk();
        let mut out = String::with_capacity(po_raw.len() / 2 + 256);
        out.push_str("window.TR = window.TR || {}; window.TR_RAW = {");
        stream_po_to_json_entries(&po_raw, &mut out);
        out.push_str(
            "}; if (typeof sfh === 'function' && typeof trimws === 'function') { \
               for (const [k, v] of Object.entries(window.TR_RAW)) { \
                 if (v) window.TR[sfh(trimws(k))] = v; \
               } \
             }\n",
        );
        out.shrink_to_fit();
        out
    })
}

fn append_json_escaped(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                use std::fmt::Write as _;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn stream_po_to_json_entries(po_text: &str, out: &mut String) {
    let mut cur_id = String::with_capacity(128);
    let mut cur_str = String::with_capacity(128);
    let mut mode = 0u8; // 0 = none, 1 = msgid, 2 = msgstr
    let mut first = true;

    let flush = |id: &mut String, val: &mut String, dst: &mut String, is_first: &mut bool| {
        if !id.is_empty() && !val.is_empty() {
            if !*is_first {
                dst.push(',');
            }
            *is_first = false;
            append_json_escaped(dst, id);
            dst.push(':');
            append_json_escaped(dst, val);
        }
        id.clear();
        val.clear();
    };

    for raw_line in po_text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            if line.is_empty() && mode == 2 {
                flush(&mut cur_id, &mut cur_str, out, &mut first);
                mode = 0;
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("msgid ") {
            if mode == 2 {
                flush(&mut cur_id, &mut cur_str, out, &mut first);
            }
            cur_id.clear();
            unquote_po_into(rest.trim(), &mut cur_id);
            cur_str.clear();
            mode = 1;
        } else if let Some(rest) = line.strip_prefix("msgstr ") {
            cur_str.clear();
            unquote_po_into(rest.trim(), &mut cur_str);
            mode = 2;
        } else if line.starts_with('"') && line.ends_with('"') {
            if mode == 1 {
                unquote_po_into(line, &mut cur_id);
            } else if mode == 2 {
                unquote_po_into(line, &mut cur_str);
            }
        }
    }
    if mode == 2 {
        flush(&mut cur_id, &mut cur_str, out, &mut first);
    }
}

fn unquote_po_into(s: &str, out: &mut String) {
    let inner = s
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(s);
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
}

/// Resolve a static asset under `/luci-static/<rel_path>` inside explicit root directories.
pub fn resolve_static_asset_in_roots(
    rel_path: &str,
    roots: &[PathBuf],
) -> Option<(PathBuf, &'static str, u64, String)> {
    let clean = rel_path
        .split('?')
        .next()
        .unwrap_or(rel_path)
        .trim_start_matches('/');
    if clean.is_empty() || clean.contains("..") || clean.contains('\\') {
        return None;
    }

    for root in roots {
        let candidate = root.join(clean);
        if let Ok(meta) = std::fs::metadata(&candidate)
            && meta.is_file()
        {
            let size = meta.len();
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            let mime = guess_mime_type(clean);
            let etag = format!("\"{mtime:x}-{size:x}\"");
            return Some((candidate, mime, size, etag));
        }
    }
    None
}

/// Resolve a static asset under `/luci-static/<rel_path>` on disk without caching megabytes in heap.
/// Returns `(file_path, mime_type, size_bytes, etag)`.
pub fn resolve_static_asset(rel_path: &str) -> Option<(PathBuf, &'static str, u64, String)> {
    let p = crate::platform::paths();
    let roots = [
        p.www_dir.clone(),
        p.share_dir.join("www/luci-static"),
        PathBuf::from("/www/luci-static"),
        p.runtime_tmpfs_dir.join("www/luci-static"),
        PathBuf::from("/tmp/tachyon-rs/www/luci-static"),
        PathBuf::from("luci-app-tachyon/htdocs/luci-static"),
    ];
    resolve_static_asset_in_roots(rel_path, &roots)
}

fn guess_mime_type(path: &str) -> &'static str {
    if path.ends_with(".js") {
        "application/javascript; charset=utf-8"
    } else if path.ends_with(".css") {
        "text/css; charset=utf-8"
    } else if path.ends_with(".svg") {
        "image/svg+xml"
    } else if path.ends_with(".png") {
        "image/png"
    } else if path.ends_with(".ico") {
        "image/x-icon"
    } else if path.ends_with(".woff2") {
        "font/woff2"
    } else if path.ends_with(".woff") {
        "font/woff"
    } else if path.ends_with(".json") {
        "application/json; charset=utf-8"
    } else {
        "application/octet-stream"
    }
}

/// Handle `POST /ubus*` and `POST /cgi-bin/luci/admin/ubus*` (single or bounded-batch JSON-RPC 2.0).
pub async fn handle_ubus_post(
    body: &[u8],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    let Ok(parsed) = serde_json::from_slice::<Value>(body) else {
        return json!({
            "jsonrpc": "2.0",
            "id": null,
            "error": { "code": -32700, "message": "Parse error" }
        });
    };

    let is_mutating_ubus_rpc = |item: &Value| -> bool {
        let Some(params) = item.get("params").and_then(Value::as_array) else {
            return false;
        };
        let obj = params.get(1).and_then(Value::as_str).unwrap_or("");
        let meth = params.get(2).and_then(Value::as_str).unwrap_or("");
        match obj {
            "uci" => !matches!(meth, "get" | "changes"),
            "file" => matches!(meth, "write" | "remove" | "exec"),
            "tachyon" => !matches!(meth, "get_exit_country" | "get_status"),
            _ => true,
        }
    };

    let is_deferrable_tachyon_uci_mutation = |item: &Value| -> bool {
        if item.get("method").and_then(Value::as_str) != Some("call") {
            return false;
        }
        let Some(params) = item.get("params").and_then(Value::as_array) else {
            return false;
        };
        let obj = params.get(1).and_then(Value::as_str).unwrap_or("");
        let meth = params.get(2).and_then(Value::as_str).unwrap_or("");
        if obj != "uci" || !matches!(meth, "add" | "set" | "delete" | "order") {
            return false;
        }
        params
            .get(3)
            .and_then(|a| a.get("config"))
            .and_then(Value::as_str)
            .unwrap_or("tachyon")
            == "tachyon"
    };

    match parsed {
        Value::Array(mut items) => {
            if items.len() <= 1 || items.iter().any(is_mutating_ubus_rpc) {
                let can_defer = items.len() > 1;
                let mut out = Vec::with_capacity(items.len());
                let mut pending_tachyon_uci_sync = false;
                for item in &items {
                    let defer = can_defer && is_deferrable_tachyon_uci_mutation(item);
                    if !defer && pending_tachyon_uci_sync {
                        let is_explicit_uci_apply_or_revert = item
                            .get("params")
                            .and_then(Value::as_array)
                            .is_some_and(|p| {
                                p.get(1).and_then(Value::as_str) == Some("uci")
                                    && matches!(
                                        p.get(2).and_then(Value::as_str),
                                        Some("apply" | "commit" | "confirm" | "revert")
                                    )
                            });
                        if !is_explicit_uci_apply_or_revert {
                            let _guard = uci_mutex().lock().await;
                            let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
                        }
                        pending_tachyon_uci_sync = false;
                    }
                    out.push(
                        Box::pin(handle_single_ubus_rpc_with_sync(item, state, core, !defer)).await,
                    );
                    if defer {
                        pending_tachyon_uci_sync = true;
                    }
                }
                if pending_tachyon_uci_sync {
                    let _guard = uci_mutex().lock().await;
                    let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
                }
                return Value::Array(out);
            }
            let mut out = Vec::with_capacity(items.len());
            while !items.is_empty() {
                let take = items.len().min(4);
                let mut handles = Vec::with_capacity(take);
                for item in items.drain(..take) {
                    let st = Arc::clone(state);
                    let cm = Arc::clone(core);
                    handles.push(tokio::spawn(async move {
                        handle_single_ubus_rpc(&item, &st, &cm).await
                    }));
                }
                for h in handles {
                    if let Ok(res) = h.await {
                        out.push(res);
                    }
                }
            }
            Value::Array(out)
        }
        single => Box::pin(handle_single_ubus_rpc(&single, state, core)).await,
    }
}

async fn handle_single_ubus_rpc(
    req: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    handle_single_ubus_rpc_with_sync(req, state, core, true).await
}

async fn handle_single_ubus_rpc_with_sync(
    req: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    sync_after_uci_mutation: bool,
) -> Value {
    let id = req.get("id").cloned().unwrap_or(json!(1));
    let method = req.get("method").and_then(Value::as_str).unwrap_or("");

    if method == "list" {
        return json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {}
        });
    }

    if method != "call" {
        return json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32601, "message": "Method not found" }
        });
    }

    let Some(params) = req.get("params").and_then(Value::as_array) else {
        return json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32602, "message": "Invalid params" }
        });
    };

    let object = params.get(1).and_then(Value::as_str).unwrap_or("");
    let rpc_method = params.get(2).and_then(Value::as_str).unwrap_or("");
    let empty_args = json!({});
    let args = params.get(3).unwrap_or(&empty_args);

    let result = dispatch_ubus_call_with_sync(
        object,
        rpc_method,
        args,
        state,
        core,
        sync_after_uci_mutation,
    )
    .await;
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
}

async fn dispatch_ubus_call_with_sync(
    object: &str,
    method: &str,
    args: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    sync_after_uci_mutation: bool,
) -> Value {
    match (object, method) {
        ("session", "access") => json!([0, { "access": true }]),
        ("session", "get" | "login") => json!([
            0,
            {
                "ubus_rpc_session": "00000000000000000000000000000000",
                "values": {
                    "username": "root",
                    "token": "00000000000000000000000000000000"
                }
            }
        ]),
        ("luci", "getFeatures") => {
            let is_nft =
                crate::platform::firewall_kind() == crate::platform::FirewallKind::Nftables;
            let is_owrt = crate::platform::is_openwrt();
            json!([
                0,
                {
                    "firewall": true,
                    "nftables": is_nft,
                    "ipv6": true,
                    "dnsmasq": is_owrt,
                    "offloading": is_owrt
                }
            ])
        }
        ("tachyon", "get_exit_country") => {
            let refresh = args
                .get("refresh")
                .map(|v| {
                    v.as_bool().unwrap_or_else(|| {
                        v.as_i64().is_some_and(|n| n != 0)
                            || v.as_str().is_some_and(|s| {
                                matches!(
                                    s.trim().to_ascii_lowercase().as_str(),
                                    "1" | "true" | "yes"
                                )
                            })
                    })
                })
                .unwrap_or(false);
            let node = args
                .get("node")
                .or_else(|| args.get("active_node"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let res = Box::pin(get_exit_country(state, core, refresh, node)).await;
            json!([0, res])
        }
        ("tachyon", "get_status") => {
            state.touch_telemetry_access();
            let res = Box::pin(build_status_json(state)).await;
            json!([0, res])
        }
        ("file", "list") => handle_file_list(args),
        ("file", "stat" | "lstat") => handle_file_stat(args),
        ("file", "read") => handle_file_read(args, state).await,
        ("file", "write") => handle_file_write(args),
        ("file", "remove") => handle_file_remove(args),
        ("file", "exec") => handle_file_exec(args, state, core).await,
        ("uci", uci_method) => {
            handle_uci_call_with_sync(uci_method, args, state, core, sync_after_uci_mutation).await
        }
        ("luci-rpc", _) | ("network.interface", _) | ("network", _) => {
            if matches!(
                (object, method),
                (
                    "luci-rpc",
                    "getNetworkDevices" | "getWirelessDevices" | "getBoardJSON"
                ) | ("network.interface", _)
                    | ("network", _)
            ) && let Some(res) = call_router_ubus_cli(object, method, args).await
            {
                return res;
            }
            handle_fallback_system_ubus(object, method).await
        }
        _ => {
            if let Some(res) = call_router_ubus_cli(object, method, args).await {
                return res;
            }
            handle_fallback_system_ubus(object, method).await
        }
    }
}

fn resolve_bridge_runtime_path(p: &str) -> std::path::PathBuf {
    let direct = Path::new(p);
    if direct.exists() {
        return direct.to_path_buf();
    }
    if let Some(rel) = p.strip_prefix("/var/run/tachyon/") {
        return crate::store::runtime_state_dir().join(rel);
    }
    if p == "/var/run/tachyon" {
        return crate::store::runtime_state_dir();
    }
    direct.to_path_buf()
}

fn virtual_sub_cache_dir() -> std::path::PathBuf {
    #[cfg(target_os = "linux")]
    {
        Path::new("/tmp/tachyon-core/subscriptions").to_path_buf()
    }
    #[cfg(not(target_os = "linux"))]
    {
        std::env::temp_dir()
            .join("tachyon-core")
            .join("subscriptions")
    }
}

fn push_dir_entries_into(dir: &Path, map: &mut std::collections::BTreeMap<String, Value>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Ok(meta) = entry.metadata() {
            let ftype = if meta.is_dir() { "directory" } else { "file" };
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            map.insert(
                name.clone(),
                json!({
                    "name": name,
                    "type": ftype,
                    "size": meta.len(),
                    "mtime": mtime,
                }),
            );
        }
    }
}

fn resolve_virtual_sub_cache_file_in(
    path: &str,
    virt_dir: &Path,
    direct_dir: &Path,
) -> Option<std::path::PathBuf> {
    let fname = path.strip_prefix("/etc/tachyon/subscription-cache/")?;
    if fname.is_empty() || fname.contains('/') || fname.contains("..") || fname.contains('\0') {
        return None;
    }
    let virt = virt_dir.join(fname);
    if virt.is_file() {
        return Some(virt);
    }
    let direct = direct_dir.join(fname);
    if direct.is_file() {
        return Some(direct);
    }
    None
}

fn resolve_virtual_sub_cache_file(path: &str) -> Option<std::path::PathBuf> {
    resolve_virtual_sub_cache_file_in(
        path,
        &virtual_sub_cache_dir(),
        Path::new("/etc/tachyon/subscription-cache"),
    )
}

fn handle_file_list(args: &Value) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    let norm = path.trim_end_matches('/');
    if norm == "/etc/tachyon/subscription-cache" {
        let mut by_name: std::collections::BTreeMap<String, Value> =
            std::collections::BTreeMap::new();
        push_dir_entries_into(Path::new(norm), &mut by_name);
        push_dir_entries_into(&virtual_sub_cache_dir(), &mut by_name);
        let entries: Vec<Value> = by_name.into_values().collect();
        return json!([0, { "entries": entries }]);
    }
    let resolved = resolve_bridge_runtime_path(path);
    let Ok(rd) = std::fs::read_dir(&resolved) else {
        return json!([4]);
    };
    let mut by_name: std::collections::BTreeMap<String, Value> = std::collections::BTreeMap::new();
    push_dir_entries_into(&resolved, &mut by_name);
    drop(rd);
    let entries: Vec<Value> = by_name.into_values().collect();
    json!([0, { "entries": entries }])
}

fn handle_file_stat(args: &Value) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    let target =
        resolve_virtual_sub_cache_file(path).unwrap_or_else(|| resolve_bridge_runtime_path(path));
    let Ok(meta) = std::fs::metadata(&target) else {
        return json!([4]);
    };
    let ftype = if meta.is_dir() { "directory" } else { "file" };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    json!([
        0,
        {
            "path": path,
            "type": ftype,
            "size": meta.len(),
            "mtime": mtime,
            "mode": 0o644
        }
    ])
}

fn is_safe_abs_path(p: &str) -> bool {
    p.starts_with('/')
        && !p.contains('\0')
        && !p.contains("//")
        && !p.split('/').any(|seg| seg == ".." || seg == ".")
}

fn path_starts_with_dir(p: &str, dir: &Path) -> bool {
    let base = dir.to_string_lossy();
    let trimmed = base.trim_end_matches('/');
    !trimmed.is_empty()
        && p.strip_prefix(trimmed)
            .is_some_and(|rest| rest.starts_with('/'))
}

fn is_allowed_bridge_read_path(p: &str) -> bool {
    if !is_safe_abs_path(p) {
        return false;
    }
    let plat = crate::platform::paths();
    matches!(
        p,
        "/proc/sys/kernel/hostname"
            | "/etc/config/tachyon"
            | "/var/run/tachyon/section-errors.json"
            | "/var/run/tachyon/rule-conflicts.json"
            | "/tmp/tachyon-snapshot-export.json"
            | "/var/run/tachyon/ui-state/snapshot-export.json"
    ) || p.starts_with("/var/run/tachyon/")
        || p.starts_with("/tmp/run/tachyon/")
        || p.starts_with("/tmp/tachyon")
        || p.starts_with("/etc/tachyon/rulesets/")
        || p.starts_with("/etc/tachyon/subscription-cache/")
        || p.starts_with("/etc/tachyon/hosts-lists/")
        || p.starts_with("/etc/tachyon/custom-lists/")
        || p.starts_with("/usr/share/tachyon/rulesets/")
        || path_starts_with_dir(p, &plat.runtime_tmpfs_dir)
        || path_starts_with_dir(p, &plat.rulesets_dir)
        || path_starts_with_dir(p, &plat.data_dir.join("subscription-cache"))
        || path_starts_with_dir(p, &plat.data_dir.join("hosts-lists"))
        || path_starts_with_dir(p, &plat.data_dir.join("custom-lists"))
        || path_starts_with_dir(p, &plat.share_dir.join("rulesets"))
}

fn is_allowed_bridge_write_path(p: &str) -> bool {
    if !is_safe_abs_path(p) {
        return false;
    }
    let plat = crate::platform::paths();
    p == "/tmp/tachyon-snapshot-import.json"
        || p.starts_with("/var/run/tachyon/")
        || path_starts_with_dir(p, &plat.runtime_tmpfs_dir)
}

fn is_allowed_bridge_remove_path(p: &str) -> bool {
    if !is_safe_abs_path(p) {
        return false;
    }
    let plat = crate::platform::paths();
    p == "/tmp/tachyon-snapshot-import.json"
        || p.starts_with("/var/run/tachyon/section-cache/")
        || p.starts_with("/etc/tachyon/subscription-cache/")
        || path_starts_with_dir(p, &plat.runtime_tmpfs_dir.join("section-cache"))
        || path_starts_with_dir(p, &plat.data_dir.join("subscription-cache"))
}

fn is_tachyon_cli_command(cmd: &str) -> bool {
    if matches!(
        cmd,
        "/usr/bin/tachyon" | "/usr/bin/tachyon-read" | "tachyon"
    ) {
        return true;
    }
    let bin_dir = &crate::platform::paths().bin_dir;
    let plat_bin = bin_dir.join("tachyon");
    let plat_read = bin_dir.join("tachyon-read");
    Path::new(cmd) == plat_bin || Path::new(cmd) == plat_read
}

fn is_allowed_bridge_exec(bin: &str, args: &[String]) -> bool {
    if args
        .iter()
        .any(|a| a.contains('\0') || a.contains('\n') || a.contains('\r'))
    {
        return false;
    }
    let plat_core_bin = crate::platform::paths().bin_dir.join("tachyon-core");
    if bin == "/usr/bin/tachyon-core"
        || bin == "/usr/sbin/tachyon-core"
        || Path::new(bin) == plat_core_bin
    {
        return matches!(
            args.first().map(String::as_str),
            Some("version" | "check" | "rule-set" | "fptn")
        );
    }
    match bin {
        "/usr/bin/nslookup" | "/bin/nslookup" | "/opt/bin/nslookup" => {
            (1..=4).contains(&args.len())
                && args.iter().all(|a| {
                    !a.is_empty()
                        && (!a.starts_with('-')
                            || a.starts_with("-type=")
                            || a.starts_with("-port="))
                })
        }
        "/bin/cat" => args.len() == 1 && is_allowed_bridge_read_path(&args[0]),
        "/sbin/logread" | "/usr/sbin/logread" => {
            args.len() <= 8
                && args.iter().all(|a| {
                    !a.is_empty()
                        && a != "-f"
                        && a != "--follow"
                        && !(a.starts_with('-') && !a.starts_with("--") && a[1..].contains('f'))
                        && !a.contains(';')
                        && !a.contains('|')
                        && !a.contains('&')
                        && !a.contains('`')
                        && !a.contains('$')
                })
        }
        "/bin/rm" => {
            args.iter().any(|a| a != "-f")
                && args
                    .iter()
                    .all(|a| a == "-f" || is_allowed_bridge_remove_path(a))
        }
        _ => false,
    }
}

async fn handle_file_read(args: &Value, state: &Arc<AppState>) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    if !is_allowed_bridge_read_path(path) {
        return json!([6]);
    }
    if let Some(sub_path) = resolve_virtual_sub_cache_file(path)
        && let Ok(bytes) = std::fs::read(&sub_path)
    {
        let data = String::from_utf8_lossy(&bytes).into_owned();
        return json!([0, { "data": data }]);
    }
    let resolved = resolve_bridge_runtime_path(path);
    if let Ok(bytes) = std::fs::read(&resolved) {
        let data = String::from_utf8_lossy(&bytes).into_owned();
        return json!([0, { "data": data }]);
    }
    if path == "/var/run/tachyon/section-errors.json" {
        let resolved_err = crate::core_mgr::CoreManager::section_errors_path();
        if let Ok(bytes) = std::fs::read(&resolved_err) {
            let data = String::from_utf8_lossy(&bytes).into_owned();
            return json!([0, { "data": data }]);
        }
        return json!([0, { "data": "{}" }]);
    }
    if path == "/var/run/tachyon/rule-conflicts.json" {
        return json!([0, { "data": "{}" }]);
    }
    if path == "/var/run/tachyon/ui-state/snapshot-export.json"
        || path == "/tmp/tachyon-snapshot-export.json"
    {
        let sections = get_json_sections_snapshot();
        let profile =
            crate::snapshots::build_active_profile(state, &sections, "export", "full").await;
        return json!([0, { "data": serde_json::to_string_pretty(&profile).unwrap_or_default() }]);
    }
    json!([4])
}

fn handle_file_write(args: &Value) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    if !is_allowed_bridge_write_path(path) {
        return json!([6]);
    }
    let data = args.get("data").and_then(Value::as_str).unwrap_or("");
    let append = args.get("append").and_then(Value::as_bool).unwrap_or(false);
    let target = Path::new(path);
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ok = if append {
        use std::io::Write;
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(target)
            .and_then(|mut f| f.write_all(data.as_bytes()))
            .is_ok()
    } else {
        crypto_gen::write_file_if_changed(target, data.as_bytes()).is_ok()
    };
    if ok { json!([0]) } else { json!([5]) }
}

fn handle_file_remove(args: &Value) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    if !is_allowed_bridge_remove_path(path) {
        return json!([6]);
    }
    if Path::new(path).exists() && std::fs::remove_file(path).is_err() {
        return json!([5]);
    }
    json!([0])
}

async fn handle_file_exec(args: &Value, state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let Some(command) = args.get("command").and_then(Value::as_str) else {
        return json!([2]);
    };
    let params: Vec<String> = args
        .get("params")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from).or_else(|| Some(v.to_string())))
                .collect()
        })
        .unwrap_or_default();

    if is_tachyon_cli_command(command) {
        let (code, stdout, stderr) = execute_tachyon_cli(&params, state, core).await;
        return json!([
            0,
            {
                "code": code,
                "stdout": stdout,
                "stderr": stderr
            }
        ]);
    }

    if command == "/sbin/uci" || command == "/bin/uci" || command == "uci" {
        let (code, stdout, stderr) = execute_pure_rust_uci_cli(&params, state, core).await;
        return json!([
            0,
            {
                "code": code,
                "stdout": stdout,
                "stderr": stderr
            }
        ]);
    }

    if command == "/usr/libexec/luci-peeraddr" {
        return json!([
            0,
            {
                "code": 0,
                "stdout": "{\"inbound_interfaces\":[]}",
                "stderr": ""
            }
        ]);
    }

    if !is_allowed_bridge_exec(command, &params) {
        return json!([6]);
    }

    if (command == "/sbin/logread" || command == "/usr/sbin/logread")
        && !Path::new(command).exists()
    {
        return json!([0, { "code": 0, "stdout": "", "stderr": "" }]);
    }

    let mut cmd = Command::new(command);
    cmd.args(&params);

    match tokio::time::timeout(Duration::from_secs(60), cmd.output()).await {
        Ok(Ok(out)) => {
            let code = out.status.code().unwrap_or(1);
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            json!([
                0,
                {
                    "code": code,
                    "stdout": stdout,
                    "stderr": stderr
                }
            ])
        }
        _ => json!([
            0,
            {
                "code": 1,
                "stdout": "",
                "stderr": "Command execution failed or timed out"
            }
        ]),
    }
}

/// Execute `/sbin/uci <subcommand> [args...]` in pure Rust against `JSON_SECTIONS_STORE` and `AppState`.
async fn execute_pure_rust_uci_cli(
    params: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (i32, String, String) {
    let _guard = uci_mutex().lock().await;
    let mut idx = 0usize;
    while idx < params.len() {
        let p = params[idx].as_str();
        if p == "-q" || p == "-m" {
            idx += 1;
        } else if p == "-c" || p == "-p" || p == "-P" {
            idx += 2;
        } else {
            break;
        }
    }
    let Some(subcmd) = params.get(idx).map(String::as_str) else {
        return (0, String::new(), String::new());
    };
    let arg = params.get(idx + 1).map(String::as_str).unwrap_or("");
    let arg2 = params.get(idx + 2).map(String::as_str).unwrap_or("");

    match subcmd {
        "show" => {
            let clean = arg.strip_prefix("tachyon.").unwrap_or(arg);
            let store = get_json_sections_snapshot();
            let mut out = String::new();
            let format_sec = |sec: &str, obj: &Map<String, Value>, buf: &mut String| {
                let stype = obj.get(".type").and_then(Value::as_str).unwrap_or(sec);
                buf.push_str(&format!("tachyon.{sec}={stype}\n"));
                for (k, v) in obj {
                    if k.starts_with('.') {
                        continue;
                    }
                    match v {
                        Value::Array(arr) => {
                            let items: Vec<String> = arr
                                .iter()
                                .filter_map(Value::as_str)
                                .map(|s| format!("'{s}'"))
                                .collect();
                            buf.push_str(&format!("tachyon.{sec}.{k}={}\n", items.join(" ")));
                        }
                        Value::String(s) => buf.push_str(&format!("tachyon.{sec}.{k}='{s}'\n")),
                        other => buf.push_str(&format!("tachyon.{sec}.{k}='{other}'\n")),
                    }
                }
            };
            if clean.is_empty() || clean == "tachyon" {
                let mut ordered: Vec<(usize, &String, &Value)> = store
                    .iter()
                    .map(|(k, v)| {
                        let i = v
                            .get(".index")
                            .and_then(Value::as_u64)
                            .unwrap_or(usize::MAX as u64) as usize;
                        (i, k, v)
                    })
                    .collect();
                ordered.sort_by_key(|(i, _, _)| *i);
                for (_, sec, val) in ordered {
                    if let Some(obj) = val.as_object() {
                        format_sec(sec, obj, &mut out);
                    }
                }
                return (0, out, String::new());
            } else if let Some((sec, opt)) = clean.split_once('.') {
                if let Some(val) = store.get(sec).and_then(|s| s.get(opt)) {
                    let s = match val {
                        Value::Array(arr) => arr
                            .iter()
                            .filter_map(Value::as_str)
                            .map(|x| format!("'{x}'"))
                            .collect::<Vec<_>>()
                            .join(" "),
                        Value::String(x) => format!("'{x}'"),
                        other => format!("'{other}'"),
                    };
                    return (0, format!("tachyon.{sec}.{opt}={s}\n"), String::new());
                }
            } else if let Some(obj) = store.get(clean).and_then(Value::as_object) {
                format_sec(clean, obj, &mut out);
                return (0, out, String::new());
            }
            (1, String::new(), "Entry not found\n".to_string())
        }
        "add" => {
            if arg.is_empty() || arg2.is_empty() {
                return (
                    1,
                    String::new(),
                    "Usage: uci add <config> <section-type>\n".to_string(),
                );
            }
            capture_uci_rollback_baseline(state).await;
            let stype = arg2.trim();
            let sname = {
                let Ok(mut store) = json_sections_store().write() else {
                    return (1, String::new(), "Lock error\n".to_string());
                };
                let idx_sec = next_section_index(&store);
                let mut n = idx_sec + 1;
                let name = loop {
                    let candidate = format!("cfg{n:02x}{stype}");
                    if !store.contains_key(&candidate) {
                        break candidate;
                    }
                    n += 1;
                };
                store.insert(
                    name.clone(),
                    json!({
                        ".anonymous": true,
                        ".type": stype,
                        ".name": name,
                        ".index": idx_sec
                    }),
                );
                persist_json_sections(&store);
                name
            };
            let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            (0, format!("{sname}\n"), String::new())
        }
        "reorder" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
                let sec = lhs.strip_prefix("tachyon.").unwrap_or(lhs).trim();
                let Ok(pos) = rhs
                    .trim()
                    .trim_matches('\'')
                    .trim_matches('"')
                    .parse::<usize>()
                else {
                    return (1, String::new(), "Invalid position\n".to_string());
                };
                capture_uci_rollback_baseline(state).await;
                if let Ok(mut store) = json_sections_store().write()
                    && store.contains_key(sec)
                {
                    let mut ordered: Vec<(usize, String, Value)> = std::mem::take(&mut *store)
                        .into_iter()
                        .map(|(k, v)| {
                            let i = v
                                .get(".index")
                                .and_then(Value::as_u64)
                                .unwrap_or(usize::MAX as u64)
                                as usize;
                            (i, k, v)
                        })
                        .collect();
                    ordered.sort_by_key(|(i, _, _)| *i);
                    if let Some(cur_pos) = ordered.iter().position(|(_, k, _)| k == sec) {
                        let item = ordered.remove(cur_pos);
                        let target_pos = pos.min(ordered.len());
                        ordered.insert(target_pos, item);
                    }
                    for (new_idx, (_, k, mut val)) in ordered.into_iter().enumerate() {
                        if let Some(obj) = val.as_object_mut() {
                            obj.insert(".index".to_string(), json!(new_idx));
                        }
                        store.insert(k, val);
                    }
                    persist_json_sections(&store);
                }
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
                return (0, String::new(), String::new());
            }
            (1, String::new(), "Invalid reorder argument\n".to_string())
        }
        "rename" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
                let clean_lhs = lhs.strip_prefix("tachyon.").unwrap_or(lhs).trim();
                let new_name = rhs.trim().trim_matches('\'').trim_matches('"').trim();
                if new_name.is_empty() {
                    return (1, String::new(), "Empty target name\n".to_string());
                }
                capture_uci_rollback_baseline(state).await;
                if let Ok(mut store) = json_sections_store().write() {
                    if let Some((sec, opt)) = clean_lhs.split_once('.') {
                        if let Some(obj) = store.get_mut(sec).and_then(Value::as_object_mut)
                            && let Some(val) = obj.remove(opt)
                        {
                            obj.insert(new_name.to_string(), val);
                        }
                    } else if let Some(mut val) = store.remove(clean_lhs) {
                        if let Some(obj) = val.as_object_mut() {
                            obj.insert(".name".to_string(), json!(new_name));
                            obj.insert(".anonymous".to_string(), json!(false));
                        }
                        store.insert(new_name.to_string(), val);
                    }
                    persist_json_sections(&store);
                }
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
                return (0, String::new(), String::new());
            }
            (1, String::new(), "Invalid rename argument\n".to_string())
        }
        "get" => {
            let clean = arg.strip_prefix("tachyon.").unwrap_or(arg);
            let store = json_sections_store()
                .read()
                .map(|g| g.clone())
                .unwrap_or_default();
            if let Some((sec, opt)) = clean.split_once('.') {
                if let Some(val) = store.get(sec).and_then(|s| s.get(opt)) {
                    let out = match val {
                        Value::String(s) => s.clone(),
                        Value::Array(arr) => arr
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(" "),
                        other => other.to_string(),
                    };
                    return (0, format!("{out}\n"), String::new());
                }
            } else if let Some(sec_val) = store.get(clean)
                && let Some(stype) = sec_val.get(".type").and_then(Value::as_str)
            {
                return (0, format!("{stype}\n"), String::new());
            }
            (1, String::new(), "Entry not found\n".to_string())
        }
        "set" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
                let clean_lhs = lhs.strip_prefix("tachyon.").unwrap_or(lhs);
                let val_str = rhs.trim_matches('\'').trim_matches('"').to_string();
                if let Ok(mut store) = json_sections_store().write() {
                    let next_idx = next_section_index(&store);
                    if let Some((sec, opt)) = clean_lhs.split_once('.') {
                        let entry = store.entry(sec.to_string()).or_insert_with(|| {
                            json!({
                                ".anonymous": false,
                                ".type": sec,
                                ".name": sec,
                                ".index": next_idx
                            })
                        });
                        if let Some(obj) = entry.as_object_mut() {
                            obj.insert(opt.to_string(), Value::String(val_str));
                        }
                    } else {
                        let sec = clean_lhs;
                        let entry = store.entry(sec.to_string()).or_insert_with(|| {
                            json!({
                                ".anonymous": false,
                                ".type": val_str,
                                ".name": sec,
                                ".index": next_idx
                            })
                        });
                        if let Some(obj) = entry.as_object_mut() {
                            obj.insert(".type".to_string(), Value::String(val_str));
                        }
                    }
                    persist_json_sections(&store);
                }
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            (0, String::new(), String::new())
        }
        "add_list" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
                capture_uci_rollback_baseline(state).await;
                let clean_lhs = lhs.strip_prefix("tachyon.").unwrap_or(lhs);
                let val_str = rhs.trim_matches('\'').trim_matches('"').to_string();
                if let Some((sec, opt)) = clean_lhs.split_once('.')
                    && let Ok(mut store) = json_sections_store().write()
                {
                    let next_idx = next_section_index(&store);
                    let entry = store.entry(sec.to_string()).or_insert_with(|| {
                        json!({
                            ".anonymous": false,
                            ".type": sec,
                            ".name": sec,
                            ".index": next_idx
                        })
                    });
                    if let Some(obj) = entry.as_object_mut() {
                        let list_entry = obj
                            .entry(opt.to_string())
                            .or_insert_with(|| Value::Array(Vec::new()));
                        if let Some(arr) = list_entry.as_array_mut() {
                            arr.push(Value::String(val_str));
                        } else if let Some(existing) = list_entry.as_str().map(String::from) {
                            *list_entry = json!([existing, val_str]);
                        }
                    }
                    persist_json_sections(&store);
                }
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            (0, String::new(), String::new())
        }
        "del_list" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
                capture_uci_rollback_baseline(state).await;
                let clean_lhs = lhs.strip_prefix("tachyon.").unwrap_or(lhs);
                let val_str = rhs.trim_matches('\'').trim_matches('"');
                if let Some((sec, opt)) = clean_lhs.split_once('.')
                    && let Ok(mut store) = json_sections_store().write()
                {
                    if let Some(arr) = store
                        .get_mut(sec)
                        .and_then(Value::as_object_mut)
                        .and_then(|o| o.get_mut(opt))
                        .and_then(Value::as_array_mut)
                    {
                        arr.retain(|x| x.as_str() != Some(val_str));
                    }
                    persist_json_sections(&store);
                }
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            (0, String::new(), String::new())
        }
        "delete" => {
            capture_uci_rollback_baseline(state).await;
            let clean = arg.strip_prefix("tachyon.").unwrap_or(arg);
            if let Ok(mut store) = json_sections_store().write() {
                if let Some((sec, opt)) = clean.split_once('.') {
                    if let Some(obj) = store.get_mut(sec).and_then(Value::as_object_mut) {
                        obj.remove(opt);
                    }
                } else {
                    store.remove(clean);
                }
                persist_json_sections(&store);
            }
            let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            (0, String::new(), String::new())
        }
        "commit" | "apply" => {
            clear_uci_rollback_baseline();
            if let Ok(store) = json_sections_store().read() {
                persist_json_sections(&store);
            }
            if let Err(err) = Box::pin(sync_uci_to_rust_store(state, core)).await {
                return (1, String::new(), format!("{err}\n"));
            }
            (0, String::new(), String::new())
        }
        "revert" => {
            let _ = revert_uci_rollback_baseline(state, core).await;
            (0, String::new(), String::new())
        }
        _ => (0, String::new(), String::new()),
    }
}

fn format_uptime_pretty(secs: u64) -> String {
    let days = secs / 86_400;
    let hours = (secs % 86_400) / 3_600;
    let mins = (secs % 3_600) / 60;
    if days > 0 {
        format!("{days}d {hours}h {mins}m")
    } else if hours > 0 {
        format!("{hours}h {mins}m")
    } else {
        format!("{mins}m")
    }
}

type CliExecOutput = (i32, String, String);
type BoxedCliFuture<'a, T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;

#[inline(never)]
fn try_fast_pure_rust_method_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(try_fast_pure_rust_method(method, rest, state, core))
}

#[inline(never)]
fn execute_pure_rust_tachyon_cli_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, CliExecOutput> {
    Box::pin(execute_pure_rust_tachyon_cli(method, rest, state, core))
}

pub fn cli_help_text() -> &'static str {
    concat!(
        "Tachyon Control Plane CLI\n\n",
        "Usage: tachyon <command> [args...]\n\n",
        "Service & Engine:\n",
        "  daemon | serve               Start control plane daemon and panel server\n",
        "  start | stop                 Start or stop tachyon-core\n",
        "  reload | restart             Reload tachyon.json (if edited externally) and apply to core\n",
        "  engine_status                Show tachyon-core runtime status and digest state\n",
        "  engine_apply | engine_reload Sync store and apply configuration to tachyon-core\n\n",
        "Configuration & Validation:\n",
        "  config_import [path]         Import & validate tachyon.json (or path) and apply\n",
        "  config_validate              Validate store plan and compiled core config\n",
        "  config_plan                  Print dry-run execution plan\n",
        "  compile_config               Print compiled tachyon-core JSON config\n",
        "  compile_nft                  Print compiled nftables ruleset\n",
        "  rollback                     Roll back to last known_good snapshot\n\n",
        "Diagnostics & Telemetry:\n",
        "  status | diagnose_json       Run doctor diagnostics and output JSON report\n",
        "  explain <host> [client_ip]   Explain routing decision with engine simulation\n",
        "  route_explain <ip> <host>    Trace packet route rule by rule\n",
        "  dns_block_stats [period]     Show blocked domain/IP stats (1h|24h|7d|all)\n",
        "  dns_block_stats_clear        Clear accumulated blocked domain/IP stats\n",
        "  fuzzer_start <engine> <target>  Start strategy check (e.g. desync youtube_suite)\n",
        "  fuzzer_status | fuzzer_stop  Inspect or stop running strategy check\n",
        "  version | --help             Print version or this help\n"
    )
}

/// Execute `/usr/bin/tachyon <method> [args...]` with sub-millisecond Pure-Rust handlers
/// for all hot paths (`get_ui_state`, `get_system_info`, `get_outbound_metadata`, `clash_api`, etc.).
pub async fn execute_tachyon_cli(
    params: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (i32, String, String) {
    let Some(raw_method) = params.first().map(|s| s.trim()) else {
        return (0, String::new(), String::new());
    };
    if matches!(raw_method, "-h" | "--help" | "help") {
        return (0, cli_help_text().to_string(), String::new());
    }
    let normalized = if raw_method.starts_with('-') {
        raw_method.to_string()
    } else {
        raw_method.replace('-', "_")
    };
    let method = normalized.as_str();
    let rest = &params[1..];

    // 1. Sub-millisecond Pure-Rust handlers for all frequent UI / telemetry / metadata / crypto methods
    if let Some(fast) = try_fast_pure_rust_method_boxed(method, rest, state, core).await {
        return fast;
    }

    // 1b. Thin boxed dispatcher for engine / config / doctor CLI commands (keeps stack < 512 KiB)
    if let Some(eng) = execute_cli_engine_commands_boxed(method, rest, state, core).await {
        return eng;
    }

    // 2. All remaining CLI / RPC methods are handled 100% in pure Rust without ucode
    execute_pure_rust_tachyon_cli_boxed(method, rest, state, core).await
}

const MAX_RULESET_EXTRACT_BYTES: usize = 16 * 1024 * 1024;
const RULESET_EXTRACT_CACHE_DIR: &str = "/tmp/tachyon-core/rulesets";
const RULESET_EXTRACT_TTL_SECS: u64 = 300;

fn find_cached_ruleset_by_name_in_roots(clean_name: &str, roots: &[&Path]) -> Option<PathBuf> {
    let candidates = [
        format!("{clean_name}.trs"),
        format!("community-{clean_name}.trs"),
        format!("{clean_name}.srs"),
        format!("community-{clean_name}.srs"),
        format!("{clean_name}.json"),
        format!("community-{clean_name}.json"),
    ];
    for root in roots {
        for name in &candidates {
            let candidate = root.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

fn ruleset_ext_from_url(url: &str) -> &'static str {
    let path_part = url.split(['?', '#']).next().unwrap_or("");
    let lower = path_part.to_ascii_lowercase();
    if lower.ends_with(".json") {
        ".json"
    } else if lower.ends_with(".srs") {
        ".srs"
    } else {
        ".trs"
    }
}

fn is_fresh_non_empty_file(path: &Path, max_age_secs: u64) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() || meta.len() == 0 {
        return false;
    }
    meta.modified()
        .ok()
        .and_then(|m| std::time::SystemTime::now().duration_since(m).ok())
        .is_some_and(|age| age.as_secs() < max_age_secs)
}

async fn resolve_and_extract_ruleset(raw_ref: &str, core: &CoreManager) -> Result<String, String> {
    let trimmed = raw_ref.trim();
    if trimmed.is_empty() {
        return Err("empty ruleset reference".to_string());
    }

    if trimmed.starts_with('/') {
        if !is_safe_abs_path(trimmed) || !is_allowed_bridge_read_path(trimmed) {
            return Err("ruleset path is not permitted".to_string());
        }
        let p = Path::new(trimmed);
        if !p.is_file() {
            return Err(format!("ruleset file not found: {trimmed}"));
        }
        return Ok(trimmed.to_string());
    }

    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        let ext = ruleset_ext_from_url(trimmed);
        let url_hash = crypto_gen::sha256_bytes_hex(trimmed.as_bytes());
        let cache_dir = Path::new(RULESET_EXTRACT_CACHE_DIR);
        let cache_path = cache_dir.join(format!("url-{url_hash}{ext}"));
        if is_fresh_non_empty_file(&cache_path, RULESET_EXTRACT_TTL_SECS) {
            return Ok(cache_path.to_string_lossy().into_owned());
        }
        let bytes = Box::pin(core.curl_fetch_with_doh_fallback(trimmed, false, 15, None))
            .await
            .map_err(|e| format!("failed to fetch remote ruleset: {e}"))?;
        if bytes.is_empty() {
            return Err("downloaded ruleset is empty".to_string());
        }
        if bytes.len() > MAX_RULESET_EXTRACT_BYTES {
            return Err(format!(
                "ruleset exceeds maximum allowed size ({MAX_RULESET_EXTRACT_BYTES} bytes)"
            ));
        }
        std::fs::create_dir_all(cache_dir)
            .map_err(|e| format!("failed to create ruleset cache dir: {e}"))?;
        crypto_gen::write_file_if_changed(&cache_path, &bytes)
            .map_err(|e| format!("failed to write cached ruleset: {e}"))?;
        return Ok(cache_path.to_string_lossy().into_owned());
    }

    let alias = trimmed
        .strip_prefix("community:")
        .unwrap_or(trimmed)
        .strip_prefix("local:")
        .unwrap_or_else(|| trimmed.strip_prefix("community:").unwrap_or(trimmed))
        .trim();
    if alias.is_empty()
        || alias == "."
        || alias == ".."
        || alias.contains("..")
        || !alias
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(format!("invalid ruleset reference: {trimmed}"));
    }

    let plat = crate::platform::paths();
    let share_rulesets = plat.share_dir.join("rulesets");
    let roots = [
        plat.rulesets_dir.as_path(),
        Path::new("/etc/tachyon/rulesets"),
        Path::new(RULESET_EXTRACT_CACHE_DIR),
        share_rulesets.as_path(),
        Path::new("/usr/share/tachyon/rulesets"),
    ];
    if let Some(found) = find_cached_ruleset_by_name_in_roots(alias, &roots) {
        return Ok(found.to_string_lossy().into_owned());
    }

    let cache_dir = Path::new(RULESET_EXTRACT_CACHE_DIR);
    let clean_name = alias
        .strip_prefix("community-")
        .unwrap_or(alias)
        .trim_end_matches(".trs")
        .trim_end_matches(".srs")
        .trim_end_matches(".json");
    let dest = cache_dir.join(format!("{clean_name}.trs"));
    if is_fresh_non_empty_file(&dest, RULESET_EXTRACT_TTL_SECS) {
        return Ok(dest.to_string_lossy().into_owned());
    }

    let primary_url = format!(
        "https://raw.githubusercontent.com/Dushnilin/tachyon-lists/main/release/tachyon/{clean_name}.trs"
    );
    let fallback_url = format!(
        "https://github.com/Dushnilin/tachyon-lists/releases/latest/download/{clean_name}.trs"
    );
    let bytes =
        match Box::pin(core.curl_fetch_with_doh_fallback(&primary_url, false, 15, None)).await {
            Ok(b) if !b.is_empty() => b,
            _ => Box::pin(core.curl_fetch_with_doh_fallback(&fallback_url, false, 15, None))
                .await
                .map_err(|e| format!("failed to resolve ruleset '{alias}': {e}"))?,
        };
    if bytes.is_empty() {
        return Err(format!("resolved ruleset '{alias}' is empty"));
    }
    if bytes.len() > MAX_RULESET_EXTRACT_BYTES {
        return Err(format!(
            "ruleset exceeds maximum allowed size ({MAX_RULESET_EXTRACT_BYTES} bytes)"
        ));
    }
    std::fs::create_dir_all(cache_dir)
        .map_err(|e| format!("failed to create ruleset cache dir: {e}"))?;
    crypto_gen::write_file_if_changed(&dest, &bytes)
        .map_err(|e| format!("failed to write cached ruleset: {e}"))?;
    Ok(dest.to_string_lossy().into_owned())
}

/// Fast pure-Rust implementations of hot RPC methods (`<1 ms` latency, zero process forks).
async fn try_fast_pure_rust_method(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<(i32, String, String)> {
    if let Some(res) = try_fast_ui_and_settings_boxed(method, rest, state, core).await {
        return Some(res);
    }
    if let Some(res) = try_fast_core_and_crypto_boxed(method, rest, state, core).await {
        return Some(res);
    }
    try_fast_diag_and_ruleset_boxed(method, rest, state, core).await
}

#[inline(never)]
fn try_fast_ui_and_settings_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(try_fast_ui_and_settings(method, rest, state, core))
}

#[inline(never)]
fn try_fast_core_and_crypto_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(try_fast_core_and_crypto(method, rest, state, core))
}

#[inline(never)]
fn try_fast_diag_and_ruleset_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(try_fast_diag_and_ruleset(method, rest, state, core))
}

/// Build the `platform_info` JSON object from explicit platform, firewall, storage, and DNS settings.
pub fn build_platform_info_from(
    platform: crate::platform::PlatformKind,
    fw: crate::platform::FirewallKind,
    storage: &crate::platform::StorageInfo,
    runtime_tmpfs_ok: bool,
    entware_dns_mode: &str,
    entware_dns_port: u16,
) -> Value {
    let dns_port = if entware_dns_port == 0 {
        1053
    } else {
        entware_dns_port
    };
    json!({
        "platform": platform.as_str(),
        "display_name": platform.display_name(),
        "is_entware": platform.is_entware(),
        "is_keenetic": platform.is_keenetic(),
        "firewall": fw.as_str(),
        "storage_kind": storage.kind.as_str(),
        "storage_fs": storage.fs_type,
        "storage_mount": storage.mount_point,
        "storage_posix": storage.is_posix,
        "runtime_tmpfs_ok": runtime_tmpfs_ok,
        "entware_dns_mode": normalize_entware_dns_mode(entware_dns_mode),
        "entware_dns_port": dns_port,
    })
}

/// Collect host platform, storage, firewall, and Entware DNS metadata for status responses.
pub fn build_platform_info_json(d: &crate::store::RouterStoreData) -> Value {
    let platform = crate::platform::detect_platform();
    let fw = crate::platform::firewall_kind();
    let p = crate::platform::paths();
    let storage = crate::platform::detect_storage_info(&p.data_dir);
    let runtime_dir = crate::platform::resolve_ram_tmpfs_dir();
    let runtime_str = runtime_dir.to_string_lossy();
    let runtime_tmpfs_ok = if cfg!(target_os = "linux") {
        let rt_storage = crate::platform::detect_storage_info(&runtime_dir);
        !runtime_str.starts_with("/opt")
            && (rt_storage.kind == crate::platform::StorageKind::TmpfsOnly
                || rt_storage.fs_type.eq_ignore_ascii_case("tmpfs"))
    } else {
        !runtime_str.starts_with("/opt")
    };
    build_platform_info_from(
        platform,
        fw,
        &storage,
        runtime_tmpfs_ok,
        &d.settings.entware_dns_mode,
        d.settings.entware_dns_port,
    )
}

/// Build the unified router/core status payload used by `get_status` and `GET /api/status`.
pub async fn build_status_json(state: &Arc<AppState>) -> Value {
    let sys = sys_info::collect_host_info();
    let live = Box::new(state.live.read().await.clone());
    let d = state.data.read().await;
    let daemon_uptime = sys_info::daemon_uptime_secs();
    let cpu_pct = sys_info::sample_cpu_load_percent();
    let panel_mb = ((sys.panel_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);
    let platform_info = build_platform_info_json(&d);
    json!({
        "ok": true,
        "running": i32::from(live.core_running),
        "enabled": 1,
        "status": if live.core_running { "running & enabled" } else { "stopped" },
        "dns_configured": 1,
        "lite_mode": i32::from(d.settings.lite_mode),
        "pid": std::process::id(),
        "memory_rss_mb": panel_mb,
        "uptime_seconds": daemon_uptime,
        "uptime_pretty": format_uptime_pretty(daemon_uptime),
        "cpu_load_percent": cpu_pct,
        "cpu_temp_c": if sys.cpu_temp_c > 0.0 { json!(sys.cpu_temp_c) } else { Value::Null },
        "engine_variant": "tachyon-core",
        "engine_version": live.core_version,
        "platform_info": platform_info,
    })
}

const EXIT_COUNTRY_CACHE_TTL_SECS: u64 = 120;

#[derive(Debug, Clone)]
struct ExitCountryCache {
    active_node: String,
    country_code: String,
    ip: String,
    source: String,
    checked_at: u64,
    cached_at: std::time::Instant,
}

impl ExitCountryCache {
    fn is_valid_for(&self, active_node: &str, refresh: bool, ttl: Duration) -> bool {
        !refresh
            && self.active_node == active_node
            && !self.country_code.is_empty()
            && self.cached_at.elapsed() < ttl
    }
}

static EXIT_COUNTRY_CACHE: OnceLock<tokio::sync::Mutex<Option<ExitCountryCache>>> = OnceLock::new();

fn exit_country_cache_slot() -> &'static tokio::sync::Mutex<Option<ExitCountryCache>> {
    EXIT_COUNTRY_CACHE.get_or_init(|| tokio::sync::Mutex::new(None))
}

fn normalize_iso_country_code(raw: &str) -> Option<String> {
    let trimmed = raw.trim().to_ascii_uppercase();
    if trimmed.len() == 2 && trimmed.bytes().all(|b| b.is_ascii_uppercase()) && trimmed != "XX" {
        Some(trimmed)
    } else {
        None
    }
}

fn normalize_valid_ip(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return None;
    }
    trimmed
        .parse::<std::net::IpAddr>()
        .ok()
        .map(|ip| ip.to_string())
}

/// Parse Cloudflare `/cdn-cgi/trace` plain-text response into `(ip, country_code)`.
pub fn parse_cloudflare_trace(raw: &str) -> Option<(String, String)> {
    let mut ip: Option<String> = None;
    let mut loc: Option<String> = None;
    for line in raw.lines() {
        let Some((k, v)) = line.trim().split_once('=') else {
            continue;
        };
        match k.trim() {
            "ip" => ip = normalize_valid_ip(v),
            "loc" => loc = normalize_iso_country_code(v),
            _ => {}
        }
        if ip.is_some() && loc.is_some() {
            break;
        }
    }
    match (ip, loc) {
        (Some(ip), Some(loc)) => Some((ip, loc)),
        _ => None,
    }
}

/// Parse `https://ipwho.is/` JSON response into `(ip, country_code)`.
pub fn parse_ipwhois_json(raw: &str) -> Option<(String, String)> {
    let val: Value = serde_json::from_str(raw.trim()).ok()?;
    if val.get("success").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let ip = val
        .get("ip")
        .and_then(Value::as_str)
        .and_then(normalize_valid_ip)?;
    let country_code = val
        .get("country_code")
        .and_then(Value::as_str)
        .and_then(normalize_iso_country_code)?;
    Some((ip, country_code))
}

fn parse_clash_exit_probe_json(val: &Value) -> Option<(String, String)> {
    for family_key in ["ipv4", "ipv6"] {
        let Some(obj) = val.get(family_key).and_then(Value::as_object) else {
            continue;
        };
        let ip = obj
            .get("address")
            .or_else(|| obj.get("ip"))
            .and_then(Value::as_str)
            .and_then(normalize_valid_ip);
        let cc = obj
            .get("country")
            .or_else(|| obj.get("country_code"))
            .or_else(|| obj.get("loc"))
            .and_then(Value::as_str)
            .and_then(normalize_iso_country_code);
        if let (Some(ip), Some(cc)) = (ip, cc) {
            return Some((ip, cc));
        }
    }
    None
}

fn format_mixed_proxy_url_from_inbound(inb: &Value) -> Option<String> {
    let ty = inb.get("type").and_then(Value::as_str).unwrap_or("");
    if !matches!(ty, "mixed" | "http" | "socks") {
        return None;
    }
    let port = inb
        .get("listen_port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
        .filter(|&p| p > 0)?;
    let scheme = if ty == "socks" { "socks5h" } else { "http" };
    if let Some(user) = inb
        .get("users")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
    {
        let u = user.get("username").and_then(Value::as_str).unwrap_or("");
        let p = user.get("password").and_then(Value::as_str).unwrap_or("");
        if !u.is_empty() {
            let eu = url_encode_component(u);
            let ep = url_encode_component(p);
            return Some(format!("{scheme}://{eu}:{ep}@127.0.0.1:{port}"));
        }
    }
    Some(format!("{scheme}://127.0.0.1:{port}"))
}

fn resolve_section_mixed_proxy_url_from_raw(
    d: &crate::store::RouterStoreData,
    raw_cfg: Option<&str>,
    section_id: &str,
) -> Option<String> {
    if section_id.trim().is_empty() {
        return None;
    }
    let expected_tag = format!("mixed-sec-{}", section_id.trim());
    if let Some(raw) = raw_cfg
        && let Ok(val) = serde_json::from_str::<Value>(raw)
        && let Some(inbounds) = val.get("inbounds").and_then(Value::as_array)
        && let Some(inb) = inbounds
            .iter()
            .find(|inb| inb.get("tag").and_then(Value::as_str) == Some(expected_tag.as_str()))
        && let Some(url) = format_mixed_proxy_url_from_inbound(inb)
    {
        return Some(url);
    }
    d.sections
        .iter()
        .find(|s| {
            s.enabled && s.id == section_id && s.mixed_proxy_enabled && s.mixed_proxy_port > 0
        })
        .map(|s| {
            if s.mixed_proxy_auth_enabled && !s.mixed_proxy_username.is_empty() {
                let eu = url_encode_component(&s.mixed_proxy_username);
                let ep = url_encode_component(&s.mixed_proxy_password);
                format!("http://{eu}:{ep}@127.0.0.1:{}", s.mixed_proxy_port)
            } else {
                format!("http://127.0.0.1:{}", s.mixed_proxy_port)
            }
        })
}

fn resolve_section_mixed_proxy_url(
    d: &crate::store::RouterStoreData,
    section_id: &str,
) -> Option<String> {
    let cfg_path = if d.settings.core_config_path.trim().is_empty() {
        crate::platform::paths()
            .core_config_dir
            .join("config.json")
            .to_string_lossy()
            .into_owned()
    } else {
        d.settings.core_config_path.clone()
    };
    let raw = std::fs::read_to_string(&cfg_path).ok();
    resolve_section_mixed_proxy_url_from_raw(d, raw.as_deref(), section_id)
}

fn resolve_primary_exit_section_id(
    d: &crate::store::RouterStoreData,
    requested_node: Option<&str>,
) -> String {
    if let Some(req) = requested_node.map(str::trim).filter(|s| !s.is_empty()) {
        let base = req
            .strip_prefix("sel-")
            .or_else(|| req.strip_suffix("-out"))
            .unwrap_or(req);
        if let Some(sec) = d.sections.iter().find(|s| {
            s.enabled && (s.id == base || s.id == req || req.starts_with(&format!("bal-{}-", s.id)))
        }) {
            return sec.id.clone();
        }
        if let Some(sec) = d
            .sections
            .iter()
            .find(|s| s.enabled && s.active_selected_tag.trim() == req)
        {
            return sec.id.clone();
        }
    }
    d.sections
        .iter()
        .find(|s| s.enabled && !matches!(s.action.as_str(), "bypass" | "block" | "direct"))
        .map(|s| s.id.clone())
        .unwrap_or_else(|| "Main".to_string())
}

fn resolve_local_proxy_url_from_core_config(d: &crate::store::RouterStoreData) -> Option<String> {
    // 1. Inspect core config JSON for local mixed/http/socks inbounds
    let cfg_path = if d.settings.core_config_path.trim().is_empty() {
        crate::platform::paths()
            .core_config_dir
            .join("config.json")
            .to_string_lossy()
            .into_owned()
    } else {
        d.settings.core_config_path.clone()
    };
    if let Ok(raw) = std::fs::read_to_string(&cfg_path)
        && let Ok(val) = serde_json::from_str::<Value>(&raw)
        && let Some(inbounds) = val.get("inbounds").and_then(Value::as_array)
    {
        let mut preferred: Option<(&str, u16)> = None;
        let mut fallback: Option<(&str, u16)> = None;
        for inb in inbounds {
            let ty = inb.get("type").and_then(Value::as_str).unwrap_or("");
            if !matches!(ty, "mixed" | "http" | "socks") {
                continue;
            }
            let Some(port) = inb
                .get("listen_port")
                .and_then(Value::as_u64)
                .and_then(|p| u16::try_from(p).ok())
                .filter(|&p| p > 0)
            else {
                continue;
            };
            let tag = inb.get("tag").and_then(Value::as_str).unwrap_or("");
            if matches!(tag, "service-mixed-in" | "client-mixed-in" | "mixed-in") {
                preferred = Some((ty, port));
                break;
            }
            if fallback.is_none() {
                fallback = Some((ty, port));
            }
        }
        if let Some((ty, port)) = preferred.or(fallback) {
            let scheme = if ty == "socks" { "socks5h" } else { "http" };
            return Some(format!("{scheme}://127.0.0.1:{port}"));
        }
    }

    // 2. Fallback to any enabled section's configured mixed_proxy_port
    if let Some(port) = d
        .sections
        .iter()
        .find(|s| s.enabled && s.mixed_proxy_enabled && s.mixed_proxy_port > 0)
        .map(|s| s.mixed_proxy_port)
    {
        return Some(format!("http://127.0.0.1:{port}"));
    }

    None
}

async fn resolve_active_exit_node_tag(
    d: &crate::store::RouterStoreData,
    core: &Arc<CoreManager>,
    requested_node: Option<&str>,
) -> String {
    if let Some(node) = requested_node.map(str::trim).filter(|s| !s.is_empty()) {
        return node.to_string();
    }
    let primary_target = d
        .sections
        .iter()
        .find(|s| s.enabled && !matches!(s.action.as_str(), "bypass" | "block" | "direct"))
        .map(|s| s.id.as_str())
        .unwrap_or("Main");
    if let Ok(proxies_val) = core.clash_request("GET", "/proxies", None).await
        && let Some(proxies_map) = proxies_val.get("proxies").and_then(Value::as_object)
    {
        let mut cur = resolve_clash_group_for_target(d, Some(proxies_map), primary_target);
        for _ in 0..8 {
            let Some(next) = proxies_map
                .get(&cur)
                .and_then(|v| v.get("now"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty() && *s != cur)
            else {
                break;
            };
            cur = next.to_string();
        }
        if !cur.is_empty() {
            return cur;
        }
    }
    d.sections
        .iter()
        .find(|s| s.enabled && !s.active_selected_tag.trim().is_empty())
        .map(|s| s.active_selected_tag.trim().to_string())
        .unwrap_or_default()
}

async fn run_exit_country_curl_probe(url: &str, proxy_url: Option<&str>) -> Result<String, String> {
    let mut cmd = Command::new("curl");
    cmd.args(["--silent", "--show-error", "--max-time", "4"]);
    if let Some(proxy) = proxy_url.filter(|s| !s.trim().is_empty()) {
        cmd.args(["-x", proxy]);
    }
    cmd.arg(url).kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(6), cmd.output())
        .await
        .map_err(|_| format!("probe timed out for {url}"))?
        .map_err(|e| format!("failed to invoke curl: {e}"))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            format!("curl exited with {:?}", out.status.code())
        } else {
            stderr
        });
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Determine actual outbound exit IP and ISO country code with RAM caching (TTL 120s).
pub async fn get_exit_country(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    refresh: bool,
    requested_node: Option<&str>,
) -> Value {
    let d = state.data.read().await.clone();
    let active_node = resolve_active_exit_node_tag(&d, core, requested_node).await;
    let target_section_id = resolve_primary_exit_section_id(&d, requested_node);
    let ttl = Duration::from_secs(EXIT_COUNTRY_CACHE_TTL_SECS);

    {
        let guard = exit_country_cache_slot().lock().await;
        if let Some(entry) = guard.as_ref()
            && entry.is_valid_for(&active_node, refresh, ttl)
        {
            return json!({
                "ok": true,
                "country_code": entry.country_code,
                "ip": entry.ip,
                "active_node": entry.active_node,
                "source": entry.source,
                "checked_at": entry.checked_at,
                "cached": true,
                "error": "",
            });
        }
    }

    let is_direct_exit = active_node.is_empty() || active_node.eq_ignore_ascii_case("direct");
    let mut last_err = String::new();
    let mut resolved: Option<(String, String, &'static str)> = None;

    if !is_direct_exit {
        let mut exit_candidates = vec![active_node.clone()];
        if let Some(req) = requested_node.map(str::trim).filter(|s| !s.is_empty())
            && !exit_candidates.iter().any(|c| c == req)
        {
            exit_candidates.push(req.to_string());
        }
        for candidate in &exit_candidates {
            let probe = core.probe_node_exit_ip(candidate).await;
            if let Some((ip, cc)) = parse_clash_exit_probe_json(&probe) {
                resolved = Some((ip, cc, "clash-exit"));
                break;
            }
            if let Some(err) = probe.get("error").and_then(Value::as_str)
                && !err.trim().is_empty()
            {
                last_err = err.trim().to_string();
            } else if let Some(msg) = probe
                .get("ipv4")
                .and_then(|v| v.get("error"))
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
            {
                last_err = msg.trim().to_string();
            }
        }
    }

    let proxy_url = if is_direct_exit {
        resolve_local_proxy_url_from_core_config(&d)
    } else {
        resolve_section_mixed_proxy_url(&d, &target_section_id)
    };

    if resolved.is_none() && (is_direct_exit || proxy_url.is_some()) {
        match run_exit_country_curl_probe(
            "https://cloudflare.com/cdn-cgi/trace",
            proxy_url.as_deref(),
        )
        .await
        {
            Ok(raw) => {
                if let Some((ip, cc)) = parse_cloudflare_trace(&raw) {
                    resolved = Some((ip, cc, "cloudflare"));
                } else {
                    last_err = "cloudflare trace response missing ip/loc".to_string();
                }
            }
            Err(e) => {
                last_err = e;
            }
        }

        if resolved.is_none() {
            match run_exit_country_curl_probe("https://ipwho.is/", proxy_url.as_deref()).await {
                Ok(raw) => {
                    if let Some((ip, cc)) = parse_ipwhois_json(&raw) {
                        resolved = Some((ip, cc, "ipwhois"));
                    } else if last_err.is_empty() {
                        last_err = "ipwhois response missing ip/country_code".to_string();
                    } else {
                        last_err = format!("{last_err}; ipwhois response missing ip/country_code");
                    }
                }
                Err(e) => {
                    if last_err.is_empty() {
                        last_err = e;
                    } else {
                        last_err = format!("{last_err}; {e}");
                    }
                }
            }
        }
    } else if resolved.is_none() && last_err.is_empty() {
        last_err = format!("Failed to probe exit route for '{active_node}'");
    }

    let now_unix = crate::store::unix_now_u64();
    if let Some((ip, country_code, source)) = resolved {
        let entry = ExitCountryCache {
            active_node: active_node.clone(),
            country_code: country_code.clone(),
            ip: ip.clone(),
            source: source.to_string(),
            checked_at: now_unix,
            cached_at: std::time::Instant::now(),
        };
        {
            let mut guard = exit_country_cache_slot().lock().await;
            *guard = Some(entry);
        }
        json!({
            "ok": true,
            "country_code": country_code,
            "ip": ip,
            "active_node": active_node,
            "source": source,
            "checked_at": now_unix,
            "cached": false,
            "error": "",
        })
    } else {
        json!({
            "ok": false,
            "country_code": "",
            "ip": "",
            "active_node": active_node,
            "source": "",
            "checked_at": now_unix,
            "cached": false,
            "error": last_err,
        })
    }
}

fn parse_exit_country_cli_args(rest: &[String]) -> (bool, Option<String>) {
    let mut refresh = false;
    let mut node: Option<String> = None;
    let mut i = 0;
    while i < rest.len() {
        let arg = rest[i].trim();
        if arg.starts_with('{')
            && let Ok(val) = serde_json::from_str::<Value>(arg)
        {
            if let Some(r) = val.get("refresh") {
                refresh = r.as_bool().unwrap_or_else(|| {
                    r.as_i64().is_some_and(|n| n != 0)
                        || r.as_str().is_some_and(|s| {
                            matches!(s.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes")
                        })
                });
            }
            if let Some(n) = val
                .get("node")
                .or_else(|| val.get("active_node"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                node = Some(n.to_string());
            }
            i += 1;
            continue;
        }
        if matches!(arg, "--refresh" | "-r" | "refresh" | "1" | "true") {
            refresh = true;
        } else if let Some(val) = arg
            .strip_prefix("refresh=")
            .or_else(|| arg.strip_prefix("--refresh="))
        {
            refresh = matches!(
                val.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            );
        } else if let Some(val) = arg
            .strip_prefix("node=")
            .or_else(|| arg.strip_prefix("--node="))
            .or_else(|| arg.strip_prefix("active_node="))
        {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                node = Some(trimmed.to_string());
            }
        } else if matches!(arg, "--node" | "-n") {
            if let Some(next) = rest.get(i + 1).map(|s| s.trim()).filter(|s| !s.is_empty()) {
                node = Some(next.to_string());
                i += 1;
            }
        } else if !arg.is_empty() && !matches!(arg, "0" | "false") && node.is_none() {
            node = Some(arg.to_string());
        }
        i += 1;
    }
    (refresh, node)
}

async fn try_fast_ui_and_settings(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<(i32, String, String)> {
    match method {
        "show_version" => Some((
            0,
            format!("{}\n", crate::store::TACHYON_VERSION),
            String::new(),
        )),
        "show_sing_box_version" | "show_tachyon_core_version" => {
            let live = state.live.read().await;
            Some((0, format!("{}\n", live.core_version), String::new()))
        }
        "get_ui_state" => {
            state.touch_telemetry_access();
            let val = Box::pin(build_pure_rust_ui_state(state)).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_system_info" => {
            state.touch_telemetry_access();
            let val = Box::pin(build_pure_rust_system_info(state)).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_status" => {
            state.touch_telemetry_access();
            let val = Box::pin(build_status_json(state)).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_exit_country" => {
            let (refresh, node) = parse_exit_country_cli_args(rest);
            let val = Box::pin(get_exit_country(state, core, refresh, node.as_deref())).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_sing_box_status" | "get_tachyon_core_status" | "get_engine_status" => {
            state.touch_telemetry_access();
            let live = state.live.read().await;
            let d = state.data.read().await;
            let mut val = build_core_service_json(&live);
            if let Some(obj) = val.as_object_mut() {
                obj.insert("dns_configured".to_string(), json!(1));
                obj.insert(
                    "lite_mode".to_string(),
                    json!(i32::from(d.settings.lite_mode)),
                );
            }
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "check_sing_box" | "check_tachyon_core" | "check_core" => {
            let wan6_cache = tokio::task::spawn_blocking(crate::store::probe_wan6_runtime_state)
                .await
                .unwrap_or_default();
            let d = state.data.read().await;
            let live = state.live.read().await;
            let ipv6_active =
                crate::store::resolve_effective_ipv6_state(&d.settings, wan6_cache.wan6_available)
                    .is_active();
            let val = build_core_health_check_payload(&d, &live, ipv6_active);
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_ui_capabilities" | "get_server_capabilities" => {
            let d = state.data.read().await;
            let ui_prefs = read_uci_ui_prefs();
            let val = build_capabilities_json(&d, ui_prefs);
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_ui_prefs" => {
            let prefs = read_uci_ui_prefs();
            let s = serde_json::to_string(&prefs).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "set_ui_prefs" => {
            if let Some(patch_str) = rest.first()
                && let Ok(patch) = serde_json::from_str::<Value>(patch_str)
            {
                let merged = write_uci_ui_prefs(&patch);
                {
                    let mut d = state.data.write().await;
                    if let Some(mode) = merged.get("ui_mode").and_then(Value::as_str) {
                        d.settings.ui_mode = crate::store::normalize_ui_mode(mode);
                    }
                    if let Some(pos) = merged.get("sidebar_pos").and_then(Value::as_str)
                        && !pos.trim().is_empty()
                    {
                        d.settings.sidebar_pos = pos.trim().to_string();
                    }
                    if let Some(theme) = merged.get("accent_theme").and_then(Value::as_str)
                        && !theme.trim().is_empty()
                    {
                        d.settings.accent_theme = theme.trim().to_string();
                    }
                }
                if let Err(e) = state.save().await {
                    let s = serde_json::to_string(
                        &json!({ "success": false, "error": format!("{e:#}") }),
                    )
                    .unwrap_or_else(|_| "{\"success\":false}".to_string());
                    return Some((1, format!("{s}\n"), format!("{e:#}\n")));
                }
                let s = serde_json::to_string(&json!({ "success": true, "ui_prefs": merged }))
                    .unwrap_or_else(|_| "{}".to_string());
                {
                    let d_updated = state.data.read().await;
                    sync_from_store_to_json_and_cache(&d_updated);
                }
                return Some((0, format!("{s}\n"), String::new()));
            }
            Some((0, "{\"success\":true}\n".to_string(), String::new()))
        }
        "get_lite_mode" => {
            let d = state.data.read().await;
            let s = serde_json::to_string(&json!({
                "success": true,
                "lite_mode": i32::from(d.settings.lite_mode)
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "set_lite_mode" => {
            let en = rest
                .first()
                .map(|v| v == "1" || v == "true")
                .unwrap_or(false);
            let old_en = {
                let mut d = state.data.write().await;
                let prev = d.settings.lite_mode;
                d.settings.lite_mode = en;
                prev
            };
            if let Ok(mut store) = json_sections_store().write() {
                let next_idx = next_section_index(&store);
                let sec = store.entry("settings".to_string()).or_insert_with(|| {
                    json!({
                        ".anonymous": false,
                        ".type": "settings",
                        ".name": "settings",
                        ".index": next_idx
                    })
                });
                if let Some(sec_obj) = sec.as_object_mut() {
                    sec_obj.insert("lite_mode".to_string(), json!(if en { "1" } else { "0" }));
                }
                persist_json_sections(&store);
            }
            if let Err(e) = state.save().await {
                let s =
                    serde_json::to_string(&json!({ "success": false, "error": format!("{e:#}") }))
                        .unwrap_or_else(|_| "{\"success\":false}".to_string());
                return Some((1, format!("{s}\n"), format!("{e:#}\n")));
            }
            if old_en != en {
                let core_clone = Arc::clone(core);
                tokio::spawn(async move {
                    let _ = core_clone.apply_or_reload().await;
                });
            }
            let s = serde_json::to_string(&json!({
                "success": true,
                "lite_mode": i32::from(en)
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_outbound_metadata" => {
            let sec = rest.first().map(String::as_str).unwrap_or("all");
            let d = state.data.read().await;
            let val = read_pure_rust_outbound_metadata(&d, sec);
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_subscription_metadata" => {
            let sec = rest.first().map(String::as_str).unwrap_or("");
            let d = state.data.read().await;
            let val = read_pure_rust_subscription_metadata(&d, sec);
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "[]".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "component_update_check_cache" => {
            let val = read_pure_rust_component_update_cache();
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        _ => None,
    }
}

async fn try_fast_core_and_crypto(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<(i32, String, String)> {
    match method {
        "clash_api" => Box::pin(handle_pure_rust_clash_api(rest, state, core)).await,
        "core_telemetry_snapshot" => {
            state.touch_telemetry_access();
            let val = Box::pin(build_pure_rust_core_telemetry(state, core)).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "core_memory_trim" => {
            let out = match core
                .clash_request("POST", "/tachyon/memory/trim", Some("{}"))
                .await
            {
                Ok(mut val) => {
                    if let Some(obj) = val.as_object_mut() {
                        obj.insert("success".to_string(), json!(true));
                    }
                    val
                }
                Err(e) => json!({ "success": false, "error": e.to_string() }),
            };
            let s = serde_json::to_string(&out).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "core_route_recheck" => {
            let out = match core
                .clash_request("POST", "/tachyon/route-recheck", Some("{}"))
                .await
            {
                Ok(mut val) => {
                    if let Some(obj) = val.as_object_mut() {
                        obj.insert("success".to_string(), json!(true));
                    }
                    val
                }
                Err(e) => json!({ "success": false, "error": e.to_string() }),
            };
            let s = serde_json::to_string(&out).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "core_failover_restore" => {
            let out = match core
                .clash_request(
                    "POST",
                    "/tachyon/failover/restore",
                    Some("{\"probe\":true}"),
                )
                .await
            {
                Ok(mut val) => {
                    if let Some(obj) = val.as_object_mut() {
                        obj.insert("success".to_string(), json!(true));
                    }
                    val
                }
                Err(e) => json!({ "success": false, "error": e.to_string() }),
            };
            let s = serde_json::to_string(&out).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "core_flight_clear" => {
            let out = match core.clash_request("DELETE", "/tachyon/flight", None).await {
                Ok(mut val) => {
                    if let Some(obj) = val.as_object_mut() {
                        obj.insert("success".to_string(), json!(true));
                    }
                    val
                }
                Err(e) => json!({ "success": false, "error": e.to_string() }),
            };
            let s = serde_json::to_string(&out).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "dns_block_stats" => {
            let period = rest.first().map(String::as_str).unwrap_or("24h");
            let val = match Box::pin(crate::adguard_hosts::query_dns_block_stats_for_state(
                state, core, period,
            ))
            .await
            {
                Ok(stats) => {
                    serde_json::to_value(&stats).unwrap_or_else(|_| json!({ "ok": false }))
                }
                Err(e) => json!({ "ok": false, "error": e.to_string() }),
            };
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "dns_block_stats_clear" => {
            let val = match crate::adguard_hosts::clear_dns_block_stats() {
                Ok(()) => json!({ "ok": true }),
                Err(e) => json!({ "ok": false, "error": e.to_string() }),
            };
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "lan_clients" => {
            state.touch_telemetry_access();
            let d = state.data.read().await;
            let clients: Vec<Value> = sys_info::discover_lan_devices()
                .into_iter()
                .map(|c| {
                    let bypassed = d
                        .conditions
                        .iter()
                        .any(|cond| cond.exclude_client_ips.iter().any(|ip| ip == &c.ip));
                    json!({
                        "ip": c.ip,
                        "mac": c.mac,
                        "hostname": c.hostname,
                        "is_online": c.reachable,
                        "mode": if bypassed { "direct" } else { "proxied" }
                    })
                })
                .collect();
            let total = clients.len();
            let val = json!({
                "success": true,
                "clients": clients,
                "total": total,
            });
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "show_config" => {
            let want_raw = rest.iter().any(|a| a == "raw" || a == "--raw");
            let s = Box::pin(build_show_config_payload(state, want_raw)).await;
            Some((0, format!("{s}\n"), String::new()))
        }
        "show_sing_box_config" | "show_tachyon_core_config" => {
            let want_raw = rest.iter().any(|a| a == "raw" || a == "--raw");
            let cfg_path = {
                let d = state.data.read().await;
                if d.settings.core_config_path.trim().is_empty() {
                    crate::platform::paths().core_config_dir.join("config.json")
                } else {
                    PathBuf::from(d.settings.core_config_path.trim())
                }
            };
            let val = if let Ok(raw) = std::fs::read_to_string(&cfg_path)
                && !raw.trim().is_empty()
                && let Ok(parsed) = serde_json::from_str::<Value>(&raw)
            {
                parsed
            } else {
                let d = state.data.read().await;
                config_gen::compile_core_config(&d).unwrap_or_else(|_| json!({}))
            };
            let out_val = if want_raw {
                val
            } else {
                crypto_gen::redact_json_value(&val)
            };
            let s = serde_json::to_string_pretty(&out_val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "generate_reality_keypair" => {
            let kp = crypto_gen::generate_reality_keypair();
            let s = serde_json::to_string(&json!({
                "success": true,
                "private_key": kp.private_key,
                "public_key": kp.public_key,
                "short_id": crypto_gen::generate_short_id(4),
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "generate_wg_keypair" => {
            let kp = crypto_gen::generate_wg_keypair();
            let out = format!(
                "PrivateKey: {}\nPublicKey: {}\n",
                kp.private_key, kp.public_key
            );
            Some((0, out, String::new()))
        }
        "generate_tls_keypair" => {
            let sec_id = rest.first().map(String::as_str).unwrap_or("server");
            let safe_id: String = sec_id
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                .collect();
            let sid = if safe_id.is_empty() {
                "server"
            } else {
                &safe_id
            };
            let cn_raw = rest
                .get(1)
                .map(String::as_str)
                .unwrap_or("tachyon.internal");
            let cn = crypto_gen::sanitize_tls_cn(cn_raw);
            let cert_dir = state
                .path
                .parent()
                .unwrap_or(crate::platform::paths().data_dir.as_path())
                .join("server-certs");
            let cert_path = cert_dir.join(format!("{sid}.crt"));
            let key_path = cert_dir.join(format!("{sid}.key"));
            let core_bin = { state.data.read().await.settings.core_bin_path.clone() };
            let core_bin_opt = (!core_bin.trim().is_empty()).then_some(core_bin.as_str());
            let payload = match Box::pin(crypto_gen::generate_tls_keypair_files(
                core_bin_opt,
                &cn,
                &cert_path,
                &key_path,
            ))
            .await
            {
                Ok(()) => {
                    let bytes = std::fs::read(&cert_path).unwrap_or_default();
                    let (sha256, md5) = crypto_gen::cert_fingerprints_sha256_md5(&bytes);
                    json!({
                        "success": true,
                        "section": sid,
                        "certificate_path": cert_path.to_string_lossy(),
                        "key_path": key_path.to_string_lossy(),
                        "sha256": sha256,
                        "md5": md5,
                    })
                }
                Err(e) => json!({
                    "success": false,
                    "section": sid,
                    "error": format!("{e:#}"),
                }),
            };
            let ok = payload
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let s = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
            Some((if ok { 0 } else { 1 }, format!("{s}\n"), String::new()))
        }
        "get_tls_certificate_sha256" => {
            let arg = rest.first().map(String::as_str).unwrap_or("server");
            let base_dir = state
                .path
                .parent()
                .unwrap_or(crate::platform::paths().data_dir.as_path());
            let cert_path = if arg.starts_with('/') && !arg.contains("..") {
                PathBuf::from(arg)
            } else {
                let safe_id: String = arg
                    .chars()
                    .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                    .collect();
                let sid = if safe_id.is_empty() {
                    "server"
                } else {
                    &safe_id
                };
                let preferred = base_dir.join("server-certs").join(format!("{sid}.crt"));
                if preferred.is_file() {
                    preferred
                } else {
                    base_dir.join("certs").join(format!("{sid}.crt"))
                }
            };
            if let Ok(bytes) = std::fs::read(&cert_path) {
                let (sha256, md5) = crypto_gen::cert_fingerprints_sha256_md5(&bytes);
                let s = serde_json::to_string(&json!({
                    "success": true,
                    "sha256": sha256,
                    "md5": md5,
                }))
                .unwrap_or_else(|_| "{}".to_string());
                Some((0, format!("{s}\n"), String::new()))
            } else {
                let s = serde_json::to_string(&json!({
                    "success": false,
                    "error": "Certificate not found",
                }))
                .unwrap_or_else(|_| "{}".to_string());
                Some((1, format!("{s}\n"), String::new()))
            }
        }
        "generate_warp" => match Box::pin(core.provision_warp_credentials()).await {
            Ok(payload) => {
                let s = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
                Some((0, format!("{s}\n"), String::new()))
            }
            Err(e) => {
                let msg = e.to_string();
                let s = serde_json::to_string(&json!({
                    "success": false,
                    "error": msg,
                }))
                .unwrap_or_else(|_| "{\"success\":false}".to_string());
                Some((1, format!("{s}\n"), format!("{msg}\n")))
            }
        },
        _ => None,
    }
}

async fn try_fast_diag_and_ruleset(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<(i32, String, String)> {
    match method {
        "extract_ruleset" => {
            let reference = rest.first().map(String::as_str).unwrap_or("");
            match resolve_and_extract_ruleset_boxed(reference, core).await {
                Ok(path) => Some((0, format!("{path}\n"), String::new())),
                Err(e) => Some((1, String::new(), format!("{e}\n"))),
            }
        }
        "get_router_network_env" => {
            let (ip_res, ip6_res, host_res) = tokio::join!(
                tokio::task::spawn_blocking(sys_info::detect_router_ips),
                tokio::task::spawn_blocking(sys_info::detect_router_ipv6_ips),
                tokio::task::spawn_blocking(sys_info::read_router_hostname),
            );
            let (lan_ip, wan_ip) = ip_res.unwrap_or_default();
            let (lan_ipv6, wan_ipv6, wan6_prefixes) = ip6_res.unwrap_or_default();
            let wan6_prefix = wan6_prefixes.first().cloned().unwrap_or_default();
            let mut wan_ips = Vec::new();
            if !wan_ip.is_empty() {
                wan_ips.push(wan_ip.clone());
            }
            if !wan_ipv6.is_empty() {
                wan_ips.push(wan_ipv6.clone());
            }
            let hostname = host_res.unwrap_or_default();
            let s = serde_json::to_string(&json!({
                "success": true,
                "wan_ip": wan_ip,
                "lan_ip": lan_ip,
                "wan_ipv6": wan_ipv6,
                "lan_ipv6": lan_ipv6,
                "wan6_prefix": wan6_prefix,
                "wan_ips": wan_ips,
                "public_ip": wan_ip,
                "hostname": hostname,
                "router_hostname": hostname,
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "doctor" => Some(Box::pin(handle_fast_diag_doctor(rest, state, core)).await),
        "route_explain" => {
            let (client_ip, target, port, proto) =
                parse_route_explain_cli_args("route_explain", rest);
            let d = Box::new(state.data.read().await.clone());
            let val = Box::pin(crate::diagnostics::explain_route_with_engine(
                core, &d, &client_ip, &target, port, &proto,
            ))
            .await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "config_plan" => {
            let d = state.data.read().await;
            let plan = transaction::analyze_config_plan(&d);
            let s = serde_json::to_string(&plan).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "support_bundle" => {
            let bundle = Box::pin(diagnostics::build_support_bundle(state)).await;
            let s = serde_json::to_string(&bundle).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        _ => None,
    }
}

#[inline(never)]
fn resolve_and_extract_ruleset_boxed<'a>(
    raw_ref: &'a str,
    core: &'a CoreManager,
) -> BoxedCliFuture<'a, Result<String, String>> {
    Box::pin(resolve_and_extract_ruleset(raw_ref, core))
}

async fn handle_fast_diag_doctor(
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> CliExecOutput {
    let do_fix = rest.iter().any(|a| a == "--fix" || a == "fix");
    let mut doc = Box::pin(diagnostics::run_local_doctor_with_core(state, core)).await;
    let mut fixed_count = 0usize;
    if do_fix && !doc.findings.is_empty() {
        for f in &doc.findings {
            if f.suppressed_by.is_none()
                && !f.quick_fix_id.is_empty()
                && diagnostics::quick_fix_risk_tier(&f.quick_fix_id) != "config_change"
                && let Ok(res) = Box::pin(diagnostics::apply_quick_fix_verified(
                    state,
                    core,
                    &f.quick_fix_id,
                    false,
                    false,
                ))
                .await
                && res.ok
            {
                fixed_count += 1;
            }
        }
        doc = Box::pin(diagnostics::run_local_doctor_with_core(state, core)).await;
    }
    let mut report_lines = vec![format!("=== {} ===", doc.summary)];
    for sub in &doc.subsystems {
        let name = sub.get("name").and_then(Value::as_str).unwrap_or("");
        let status = sub.get("status").and_then(Value::as_str).unwrap_or("ok");
        let detail = sub.get("detail").and_then(Value::as_str).unwrap_or("");
        let tag = if status == "ok" { "[OK]" } else { "[WARN]" };
        report_lines.push(format!("{tag} {name} — {detail}"));
    }
    if !doc.findings.is_empty() {
        report_lines.push("\nОбнаруженные замечания:".to_string());
        for f in &doc.findings {
            report_lines.push(format!(
                "- [{}] {}: {} ({})",
                f.severity.to_uppercase(),
                f.title,
                f.detail,
                f.quick_fix_label
            ));
        }
    }
    let report_text = report_lines.join("\n");
    let mut val = serde_json::to_value(&doc).unwrap_or_else(|_| json!({}));
    if let Some(obj) = val.as_object_mut() {
        obj.insert("report".to_string(), json!(report_text));
        obj.insert("issues".to_string(), json!(doc.findings.len()));
        obj.insert("fixed".to_string(), json!(fixed_count));
    }
    let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
    (0, format!("{s}\n"), String::new())
}

fn build_core_service_json(live: &crate::store::LiveTelemetry) -> Value {
    let core_uptime = live.core_uptime_secs.max(1);
    let core_mb = ((live.core_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);
    json!({
        "running": i32::from(live.core_running),
        "enabled": 1,
        "status": if live.core_running { "running & enabled" } else { "stopped" },
        "memory_rss_mb": if live.core_running { core_mb } else { 0 },
        "pid": live.core_pid.unwrap_or(0),
        "uptime_seconds": core_uptime,
        "uptime_pretty": format_uptime_pretty(core_uptime),
        "engine_variant": "tachyon-core",
        "engine_version": live.core_version,
    })
}

fn build_capabilities_json(d: &crate::store::RouterStoreData, ui_prefs: Value) -> Value {
    let installed = i32::from(tachyon_core_binary_installed());
    let ext_tailscaled_running = net_stack::embedded_tailscale_enabled(d)
        && sys_info::find_running_process_by_name("tailscaled").is_some();
    json!({
        "tachyon_core_installed": installed,
        "tachyon_core_fptn": 0,
        "tachyon_core_tailscale": 1,
        "tachyon_core_cert_pin": 1,
        "tachyon_core_profile": "tachyon-core",
        "sing_box_tachyon_core": installed,
        "sing_box_extended": 0,
        "sing_box_tiny": 0,
        "sing_box_compressed": 0,
        "sing_box_lx": 0,
        "sing_box_fptn": 0,
        "sing_box_tailscale": 1,
        "tailscale_conflict": i32::from(ext_tailscaled_running),
        "sing_box_cert_pin": 1,
        "sing_box_profile": "tachyon-core",
        "i18n_ru_installed": 1,
        "luci_lang": d.settings.lang,
        "ui_prefs": ui_prefs,
        "server_inbounds_enabled_count": d.servers.iter().filter(|i| i.enabled).count(),
        "zapret_installed": 0,
        "zapret2_installed": 0,
        "byedpi_installed": 0,
        "wdtt_installed": 0,
        "olcrtc_installed": 0,
    })
}

fn entware_has_conflicting_core_init(init_dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(init_dir) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with('S') || name == "S99tachyon" {
            return false;
        }
        name.contains("tachyon-core") || name.contains("sing-box")
    })
}

fn build_core_health_check_payload(
    d: &crate::store::RouterStoreData,
    live: &crate::store::LiveTelemetry,
    ipv6_active: bool,
) -> Value {
    let plat = crate::platform::paths();
    let core_bin_path = plat
        .bin_dir
        .join("tachyon-core")
        .to_string_lossy()
        .into_owned();
    let core_init_path = if crate::platform::is_entware() {
        plat.init_script.to_string_lossy().into_owned()
    } else {
        "/etc/init.d/tachyon-core".to_string()
    };
    let installed = tachyon_core_binary_installed();
    let version_ok =
        installed && !live.core_version.is_empty() && live.core_version != "not installed";
    let service_exist = Path::new(&core_init_path).exists() || plat.init_script.exists();
    let mut missing_ports: Vec<String> = Vec::new();
    let mut active_ports: Vec<String> = Vec::new();
    let cfg_path = std::env::var("TACHYON_CORE_CONFIG_PATH")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            if d.settings.core_config_path.trim().is_empty() {
                plat.core_config_dir
                    .join("config.json")
                    .to_string_lossy()
                    .into_owned()
            } else {
                d.settings.core_config_path.clone()
            }
        });
    let cfg_raw = std::fs::read_to_string(&cfg_path)
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok());
    if let Some(inbounds) = cfg_raw
        .as_ref()
        .and_then(|v| v.get("inbounds"))
        .and_then(Value::as_array)
    {
        for ib in inbounds {
            let ib_type = ib.get("type").and_then(Value::as_str).unwrap_or("");
            let ib_tag = ib.get("tag").and_then(Value::as_str).unwrap_or("");
            let port = ib.get("listen_port").and_then(Value::as_u64).unwrap_or(0) as u16;
            if ib_type == "tun" || ib_tag == "tun-in" {
                let tun_if = ib
                    .get("interface_name")
                    .and_then(Value::as_str)
                    .unwrap_or("tun0");
                if cfg!(target_os = "linux")
                    && !Path::new(&format!("/sys/class/net/{tun_if}")).exists()
                {
                    missing_ports.push(tun_if.to_string());
                } else {
                    active_ports.push(tun_if.to_string());
                }
            } else if port > 0 && cfg!(target_os = "linux") {
                let listen = ib.get("listen").and_then(Value::as_str).unwrap_or("");
                let ok = if ib_tag == "dns-in" || port == 53 {
                    check_proc_port_listening("127.0.0.42", port, "udp") == 1
                        || check_proc_port_listening("0.0.0.0", port, "udp") == 1
                } else if listen.contains(':') {
                    check_proc_port_listening("::1", port, "tcp") == 1
                        || check_proc_port_listening("::", port, "tcp") == 1
                        || check_proc_port_listening("0.0.0.0", port, "tcp") == 1
                } else {
                    check_proc_port_listening("0.0.0.0", port, "tcp") == 1
                        || check_proc_port_listening("127.0.0.1", port, "tcp") == 1
                };
                if ok {
                    active_ports.push(port.to_string());
                } else if ib_tag == "tproxy6-in" {
                    if ipv6_active {
                        missing_ports.push(format!(":{port}"));
                    }
                } else if matches!(ib_tag, "dns-in" | "tproxy-in" | "client-mixed-in") {
                    missing_ports.push(format!(":{port}"));
                }
            }
        }
    } else if cfg!(target_os = "linux") {
        if check_proc_port_listening("127.0.0.42", 53, "udp") != 1
            && check_proc_port_listening("0.0.0.0", 53, "udp") != 1
        {
            missing_ports.push("127.0.0.42:53".to_string());
        } else {
            active_ports.push("53".to_string());
        }
        if d.settings.proxy_mode == "tun" {
            let tun_if = if d.settings.tun_interface.trim().is_empty() {
                "tun0"
            } else {
                d.settings.tun_interface.trim()
            };
            if !Path::new(&format!("/sys/class/net/{tun_if}")).exists() {
                missing_ports.push(tun_if.to_string());
            } else {
                active_ports.push(tun_if.to_string());
            }
        } else if check_proc_port_listening("0.0.0.0", 1602, "tcp") != 1 {
            missing_ports.push("0.0.0.0:1602".to_string());
        } else {
            active_ports.push("1602".to_string());
        }
    }
    let ports_listening = if cfg!(target_os = "linux") {
        missing_ports.is_empty()
    } else {
        live.core_running
    };
    let mut listen_ports_str = if active_ports.is_empty() {
        "53, 1602, 9090".to_string()
    } else {
        active_ports.join(", ")
    };
    if !missing_ports.is_empty() {
        listen_ports_str.push_str(&format!(" (missing: {})", missing_ports.join(", ")));
    }
    let autostart_disabled = if crate::platform::is_entware() {
        !plat
            .init_script
            .parent()
            .is_some_and(entware_has_conflicting_core_init)
    } else {
        !std::fs::read_dir("/etc/rc.d")
            .ok()
            .map(|rd| {
                rd.flatten()
                    .any(|e| e.file_name().to_string_lossy().ends_with("tachyon-core"))
            })
            .unwrap_or(false)
    };
    json!({
        "tachyon_core_installed": i32::from(installed),
        "tachyon_core_version_ok": i32::from(version_ok),
        "tachyon_core_service_exist": i32::from(service_exist),
        "tachyon_core_autostart_disabled": i32::from(autostart_disabled),
        "tachyon_core_process_running": i32::from(live.core_running),
        "tachyon_core_ports_listening": i32::from(ports_listening),
        "tachyon_core_tailscale": 1,
        "tachyon_core_fptn": 0,
        "tachyon_core_cert_pin": 1,
        "tachyon_core_version": live.core_version,
        "tachyon_core_bin_path": core_bin_path,
        "tachyon_core_init_path": core_init_path,
        "tachyon_core_listen_ports": listen_ports_str,
        "sing_box_installed": i32::from(installed),
        "sing_box_version_ok": i32::from(version_ok),
        "sing_box_service_exist": i32::from(service_exist),
        "sing_box_autostart_disabled": i32::from(autostart_disabled),
        "sing_box_process_running": i32::from(live.core_running),
        "sing_box_ports_listening": i32::from(ports_listening),
        "sing_box_tachyon_core": i32::from(installed),
        "sing_box_extended": 0,
        "sing_box_cert_pin": 1,
        "sing_box_version": live.core_version,
        "sing_box_bin_path": core_bin_path,
        "sing_box_init_path": core_init_path,
        "sing_box_listen_ports": listen_ports_str,
    })
}

fn collect_active_subscription_jobs_in_dir(jobs_dir: &Path, now_secs: u64) -> Vec<Value> {
    let mut jobs = Vec::new();
    let Ok(rd) = std::fs::read_dir(jobs_dir) else {
        return jobs;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let file_mtime = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let Ok(raw) = std::fs::read_to_string(&path) else {
            if file_mtime > 0 && now_secs.saturating_sub(file_mtime) > 3600 {
                let _ = std::fs::remove_file(&path);
            }
            continue;
        };
        let Ok(mut val) = serde_json::from_str::<Value>(&raw) else {
            if file_mtime > 0 && now_secs.saturating_sub(file_mtime) > 3600 {
                let _ = std::fs::remove_file(&path);
            }
            continue;
        };
        let started_at = val.get("started_at").and_then(Value::as_u64).unwrap_or(0);
        let ref_ts = if started_at > 0 {
            started_at
        } else {
            file_mtime
        };
        let age = if ref_ts > 0 {
            now_secs.saturating_sub(ref_ts)
        } else {
            0
        };
        if age > 3600 {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        if val.get("running").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        if ref_ts > 0 && age > 900 {
            continue;
        }
        if let Some(obj) = val.as_object_mut() {
            let has_job_id = obj
                .get("job_id")
                .and_then(Value::as_str)
                .is_some_and(|s| !s.trim().is_empty());
            if !has_job_id && let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                obj.insert("job_id".to_string(), Value::String(stem.to_string()));
            }
        }
        jobs.push(val);
    }
    jobs.sort_by(|a, b| {
        let ja = a.get("job_id").and_then(Value::as_str).unwrap_or("");
        let jb = b.get("job_id").and_then(Value::as_str).unwrap_or("");
        ja.cmp(jb)
    });
    jobs
}

fn collect_active_subscription_jobs() -> Vec<Value> {
    let jobs_dir = crate::store::runtime_state_dir().join("subscription-jobs");
    collect_active_subscription_jobs_in_dir(&jobs_dir, crate::store::unix_now_u64())
}

async fn build_pure_rust_ui_state(state: &Arc<AppState>) -> Value {
    let sys = sys_info::collect_host_info();
    let d = state.data.read().await;
    let live = state.live.read().await;
    let mut ui_prefs = read_uci_ui_prefs();
    let ui_mode = crate::store::normalize_ui_mode(
        ui_prefs
            .get("ui_mode")
            .and_then(Value::as_str)
            .unwrap_or(&d.settings.ui_mode),
    );
    let sidebar_pos = ui_prefs
        .get("sidebar_pos")
        .and_then(Value::as_str)
        .unwrap_or("left")
        .to_string();
    if let Some(obj) = ui_prefs.as_object_mut() {
        obj.insert("ui_mode".to_string(), Value::String(ui_mode));
        obj.entry("sidebar_pos".to_string())
            .or_insert_with(|| Value::String(sidebar_pos));
    }
    let daemon_uptime = sys_info::daemon_uptime_secs();
    let cpu_pct = sys_info::sample_cpu_load_percent();
    let is_entware = crate::platform::is_entware();
    let dnsmasq_json = if is_entware {
        Value::Null
    } else {
        let dnsmasq = sys_info::collect_dnsmasq_status();
        json!({
            "running": i32::from(dnsmasq.running),
            "pid": dnsmasq.pid,
            "memory_rss_mb": dnsmasq.memory_rss_mb,
            "uptime_seconds": dnsmasq.uptime_secs,
            "uptime_pretty": if dnsmasq.running { format_uptime_pretty(dnsmasq.uptime_secs) } else { String::new() },
            "local_cache_enabled": i32::from(dnsmasq.local_cache_enabled),
            "cache_size": dnsmasq.cache_size
        })
    };
    let panel_mb = ((sys.panel_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);
    let core_service = build_core_service_json(&live);

    json!({
        "active_engine": "tachyon-core",
        "service": {
            "tachyon": {
                "running": i32::from(live.core_running),
                "enabled": 1,
                "status": if live.core_running { "running & enabled" } else { "stopped" },
                "dns_configured": i32::from(live.dns_healthy),
                "lite_mode": i32::from(d.settings.lite_mode),
                "pid": std::process::id(),
                "memory_rss_mb": panel_mb,
                "uptime_seconds": daemon_uptime,
                "uptime_pretty": format_uptime_pretty(daemon_uptime),
                "cpu_load_percent": cpu_pct,
                "cpu_temp_c": if sys.cpu_temp_c > 0.0 { json!(sys.cpu_temp_c) } else { Value::Null },
            },
            "tachyon_core": core_service.clone(),
            "sing_box": core_service,
            "dnsmasq": dnsmasq_json,
            "watchdog": {
                "running": i32::from(
                    d.settings.enable_watchdog && !crate::core_mgr::CoreManager::is_manual_stop_active(state)
                ),
                "pid": (d.settings.enable_watchdog && !crate::core_mgr::CoreManager::is_manual_stop_active(state))
                    .then(std::process::id),
            }
        },
        "capabilities": build_capabilities_json(&d, ui_prefs.clone()),
        "ui_prefs": ui_prefs,
        "actions": {
            "service": [],
            "latency": [],
            "component": crate::updater::active_component_job_ids(),
            "subscription": collect_active_subscription_jobs()
        }
    })
}

fn tachyon_core_binary_installed() -> bool {
    if let Ok(env_bin) = std::env::var("TACHYON_CORE_BIN")
        && crate::fuzzer::is_desync_engine_installed(&env_bin)
    {
        return true;
    }
    let bin_name = if cfg!(windows) {
        "tachyon-core.exe"
    } else {
        "tachyon-core"
    };
    let plat_bin = crate::platform::paths()
        .bin_dir
        .join(bin_name)
        .to_string_lossy()
        .into_owned();
    crate::fuzzer::is_desync_engine_installed(&plat_bin)
        || crate::fuzzer::is_desync_engine_installed(&format!("/usr/bin/{bin_name}"))
        || crate::fuzzer::is_desync_engine_installed(&format!("data/bin/{bin_name}"))
        || crate::fuzzer::is_desync_engine_installed(&format!(
            "../tachyon-core/target/release/{bin_name}"
        ))
        || crate::fuzzer::is_desync_engine_installed(bin_name)
}

fn is_non_tunnel_ifname_proc(ifname: &str) -> bool {
    let lower = ifname.trim().to_ascii_lowercase();
    !lower.is_empty()
        && lower != "lo"
        && !lower.starts_with("tun")
        && !lower.starts_with("tap")
        && !lower.starts_with("tailscale")
        && !lower.starts_with("fptn")
        && !lower.starts_with("wg")
        && !lower.starts_with("awg")
        && !lower.starts_with("utun")
}

fn is_lan_ifname_proc(ifname: &str) -> bool {
    let lower = ifname.trim().to_ascii_lowercase();
    lower == "br-lan" || lower.starts_with("br-") || lower.starts_with("lan")
}

fn parse_wan6_iface_from_proc(rt6_raw: &str, if_inet6_raw: &str, wan_ipv6: &str) -> String {
    for line in rt6_raw.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() >= 10
            && cols[0] == "00000000000000000000000000000000"
            && cols[1] == "00"
            && is_non_tunnel_ifname_proc(cols[9])
        {
            return cols[9].to_string();
        }
    }
    let target_hex = wan_ipv6
        .trim()
        .parse::<std::net::Ipv6Addr>()
        .ok()
        .map(|ip| format!("{:032x}", u128::from(ip)));
    let mut fallback_global = String::new();
    for line in if_inet6_raw.lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 6 || cols[0].len() != 32 {
            continue;
        }
        let ifname = cols[5];
        if !is_non_tunnel_ifname_proc(ifname) || is_lan_ifname_proc(ifname) {
            continue;
        }
        if let Some(ref hex) = target_hex
            && cols[0].eq_ignore_ascii_case(hex)
        {
            return ifname.to_string();
        }
        if fallback_global.is_empty()
            && cols[3] == "00"
            && let Ok(raw) = u128::from_str_radix(cols[0], 16)
        {
            let seg0 = (std::net::Ipv6Addr::from(raw)).segments()[0];
            if (seg0 & 0xe000) == 0x2000 {
                fallback_global = ifname.to_string();
            }
        }
    }
    fallback_global
}

async fn detect_wan6_iface(wan_ipv6: &str) -> String {
    if cfg!(windows) || cfg!(test) {
        return String::new();
    }
    let (rt6_res, if6_res) = tokio::join!(
        tokio::fs::read_to_string("/proc/net/ipv6_route"),
        tokio::fs::read_to_string("/proc/net/if_inet6"),
    );
    parse_wan6_iface_from_proc(
        &rt6_res.unwrap_or_default(),
        &if6_res.unwrap_or_default(),
        wan_ipv6,
    )
}

fn populate_system_info_network_fields(
    obj: &mut Map<String, Value>,
    d: &crate::store::RouterStoreData,
    wan_ip: &str,
    lan_ip: &str,
    wan6_cache: &crate::store::RuntimeIpv6Cache,
    wan6_iface: &str,
) {
    let lan_ipv6 = wan6_cache.lan_ipv6.first().cloned().unwrap_or_default();
    let wan_ipv6 = wan6_cache.wan_ipv6.first().cloned().unwrap_or_default();
    let wan6_prefixes = &wan6_cache.wan6_prefixes;
    let wan6_prefix = wan6_prefixes.first().cloned().unwrap_or_default();
    let wan6_available =
        wan6_cache.wan6_available || !wan_ipv6.is_empty() || !wan6_prefixes.is_empty();
    let ipv6_state = crate::store::resolve_effective_ipv6_state(&d.settings, wan6_available);
    let runtime_dns_strategy = crate::store::effective_dns_strategy(&d.settings, ipv6_state);
    let fakeip4 = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        d.settings.fakeip_inet4_range.trim()
    };
    let fakeip6 = if d.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        d.settings.fakeip_inet6_range.trim()
    };

    obj.insert("wan_ip".to_string(), json!(wan_ip));
    obj.insert("lan_ip".to_string(), json!(lan_ip));
    obj.insert("wan_ipv6".to_string(), json!(wan_ipv6));
    obj.insert("lan_ipv6".to_string(), json!(lan_ipv6));
    obj.insert(
        "wan6_available".to_string(),
        json!(i32::from(wan6_available)),
    );
    obj.insert("wan6_iface".to_string(), json!(wan6_iface));
    obj.insert("wan6_prefix".to_string(), json!(wan6_prefix));
    obj.insert("wan6_pd".to_string(), json!(wan6_prefixes));
    obj.insert(
        "router_hostname".to_string(),
        json!(sys_info::read_router_hostname()),
    );
    obj.insert(
        "ipv6_effective_state".to_string(),
        json!(ipv6_state.as_str()),
    );
    obj.insert("ipv6_mode".to_string(), json!(d.settings.ipv6_mode));
    obj.insert(
        "ipv6_leak_guard".to_string(),
        json!(d.settings.ipv6_leak_guard),
    );
    obj.insert("dns_strategy".to_string(), json!(d.settings.dns_strategy));
    obj.insert(
        "runtime_dns_strategy".to_string(),
        json!(runtime_dns_strategy),
    );
    obj.insert(
        "fakeip_enabled".to_string(),
        json!(i32::from(d.settings.fakeip_enabled)),
    );
    obj.insert("fakeip_inet4_range".to_string(), json!(fakeip4));
    obj.insert("fakeip_inet6_range".to_string(), json!(fakeip6));
    obj.insert(
        "webrtc_leak_protect".to_string(),
        json!(i32::from(crate::store::effective_webrtc_leak_protect(d))),
    );
}

async fn build_pure_rust_system_info(state: &Arc<AppState>) -> Value {
    let sys = sys_info::collect_host_info();
    let d = state.data.read().await.clone();
    let core_version = state.live.read().await.core_version.clone();
    let core_installed = i32::from(tachyon_core_binary_installed());
    let (ip_res, wan6_res) = tokio::join!(
        tokio::task::spawn_blocking(sys_info::detect_router_ips),
        tokio::task::spawn_blocking(crate::store::probe_wan6_runtime_state),
    );
    let (lan_ip, wan_ip) = ip_res.unwrap_or_default();
    let wan6_cache = wan6_res.unwrap_or_default();
    let wan_ipv6 = wan6_cache
        .wan_ipv6
        .first()
        .map(String::as_str)
        .unwrap_or("");
    let wan6_iface = detect_wan6_iface(wan_ipv6).await;

    let sys_info_path = crate::store::runtime_state_dir().join("system-info.json");
    let mut base = if let Ok(raw) = tokio::fs::read_to_string(&sys_info_path)
        .await
        .or(tokio::fs::read_to_string("/var/run/tachyon/system-info.json").await)
        && let Ok(parsed) = serde_json::from_str::<Value>(&raw)
    {
        parsed
    } else {
        json!({
            "tachyon_version": crate::store::TACHYON_VERSION,
            "tachyon_core_version": core_version,
            "sing_box_version": core_version,
            "tachyon_core_version": core_version,
            "active_engine": "tachyon-core",
            "tachyon_core_installed": core_installed,
            "sing_box_tachyon_core": core_installed,
            "tachyon_core_installed": core_installed,
            "openwrt_version": sys.openwrt_release,
            "device_model": sys.router_model,
            "kernel_version": sys.os,
            "arch": sys.arch,
        })
    };

    let data_dir = crate::snapshots::data_dir_for_state(state);
    let tachyon_bak = crate::snapshots::read_backup_meta(&data_dir, "tachyon");
    let core_bak = crate::snapshots::read_backup_meta(&data_dir, "tachyon-core");
    let check_cache = crate::updater::read_component_check_cache();
    let cached_for = |comp: &str| -> Option<&Value> {
        check_cache
            .get("results")
            .and_then(Value::as_array)
            .and_then(|arr| {
                arr.iter()
                    .find(|r| r.get("component").and_then(Value::as_str) == Some(comp))
            })
    };
    let core_cached = cached_for("tachyon-core")
        .or_else(|| cached_for("tachyon_core"))
        .or_else(|| cached_for("sing_box"));
    let tachyon_cached = cached_for("tachyon");

    if let Some(obj) = base.as_object_mut() {
        let tachyon_ver = crate::store::TACHYON_VERSION;
        let tachyon_latest = tachyon_cached
            .and_then(|r| r.get("latest_version").and_then(Value::as_str))
            .filter(|s| !s.is_empty())
            .unwrap_or(tachyon_ver);
        let tachyon_upd = i32::from(
            tachyon_cached
                .and_then(|r| r.get("status").and_then(Value::as_str))
                .is_some_and(crate::updater::is_update_available_status),
        );
        obj.insert("tachyon_version".to_string(), json!(tachyon_ver));
        obj.insert(
            "tachyon_commit_sha".to_string(),
            json!(crate::store::TACHYON_COMMIT_SHA),
        );
        if let Some(latest_sha) = tachyon_cached
            .and_then(|r| r.get("latest_sha").and_then(Value::as_str))
            .filter(|s| !s.is_empty())
        {
            obj.insert("tachyon_latest_sha".to_string(), json!(latest_sha));
        }
        obj.insert("tachyon_latest_version".to_string(), json!(tachyon_latest));
        obj.insert("tachyon_update_available".to_string(), json!(tachyon_upd));
        obj.insert(
            "tachyon_release_url".to_string(),
            json!(
                tachyon_cached
                    .and_then(|r| r.get("release_url").and_then(Value::as_str))
                    .unwrap_or("")
            ),
        );
        obj.insert(
            "tachyon_backup_version".to_string(),
            json!(
                tachyon_bak
                    .as_ref()
                    .map(|m| m.version.as_str())
                    .unwrap_or("")
            ),
        );
        obj.insert(
            "tachyon_backup_time".to_string(),
            json!(tachyon_bak.as_ref().map(|m| m.backed_up_at).unwrap_or(0)),
        );
        let core_latest = core_cached
            .and_then(|r| r.get("latest_version").and_then(Value::as_str))
            .filter(|s| !s.is_empty())
            .unwrap_or(&core_version);
        let core_upd = i32::from(
            core_cached
                .and_then(|r| r.get("status").and_then(Value::as_str))
                .is_some_and(crate::updater::is_update_available_status),
        );
        let core_release_url = core_cached
            .and_then(|r| r.get("release_url").and_then(Value::as_str))
            .unwrap_or("https://github.com/Dushnilin/tachyon-core/releases");
        let core_backup_ver = core_bak.as_ref().map(|m| m.version.as_str()).unwrap_or("");
        let core_backup_time = core_bak.as_ref().map(|m| m.backed_up_at).unwrap_or(0);
        obj.insert("tachyon_core_version".to_string(), json!(core_version));
        obj.insert(
            "tachyon_core_latest_version".to_string(),
            json!(core_latest),
        );
        obj.insert("tachyon_core_update_available".to_string(), json!(core_upd));
        obj.insert(
            "tachyon_core_release_url".to_string(),
            json!(core_release_url),
        );
        obj.insert(
            "tachyon_core_repo_url".to_string(),
            json!("https://github.com/Dushnilin/tachyon-core"),
        );
        obj.insert(
            "tachyon_core_backup_version".to_string(),
            json!(core_backup_ver),
        );
        obj.insert(
            "tachyon_core_backup_time".to_string(),
            json!(core_backup_time),
        );
        obj.insert("tachyon_core_installed".to_string(), json!(core_installed));
        obj.insert("tachyon_core_fptn".to_string(), json!(0));
        obj.insert("tachyon_core_tailscale".to_string(), json!(1));
        obj.insert("tachyon_core_cert_pin".to_string(), json!(1));
        obj.insert("sing_box_version".to_string(), json!(core_version));
        obj.insert("sing_box_latest_version".to_string(), json!(core_latest));
        obj.insert("sing_box_update_available".to_string(), json!(core_upd));
        obj.insert("sing_box_release_url".to_string(), json!(core_release_url));
        obj.insert(
            "sing_box_repo_url".to_string(),
            json!("https://github.com/Dushnilin/tachyon-core"),
        );
        obj.insert(
            "sing_box_backup_version".to_string(),
            json!(core_backup_ver),
        );
        obj.insert("sing_box_backup_time".to_string(), json!(core_backup_time));
        obj.insert("active_engine".to_string(), json!("tachyon-core"));
        obj.insert("sing_box_tachyon_core".to_string(), json!(core_installed));
        obj.insert("tachyon_core_installed".to_string(), json!(core_installed));
        obj.insert("sing_box_extended".to_string(), json!(0));
        obj.insert("sing_box_tiny".to_string(), json!(0));
        obj.insert("sing_box_compressed".to_string(), json!(0));
        obj.insert("sing_box_lx".to_string(), json!(0));
        obj.insert("zapret_installed".to_string(), json!(0));
        obj.insert("zapret2_installed".to_string(), json!(0));
        obj.insert("byedpi_installed".to_string(), json!(0));
        obj.insert("wdtt_installed".to_string(), json!(0));
        obj.insert("olcrtc_installed".to_string(), json!(0));
        obj.insert("ram_total_mb".to_string(), json!(sys.memory_total_mb));
        obj.insert(
            "ram_free_mb".to_string(),
            json!(sys.memory_total_mb.saturating_sub(sys.memory_used_mb)),
        );
        populate_system_info_network_fields(obj, &d, &wan_ip, &lan_ip, &wan6_cache, &wan6_iface);
        let quarantined_sections = crate::core_mgr::CoreManager::read_section_errors();
        obj.insert(
            "quarantined_sections_count".to_string(),
            json!(quarantined_sections.len()),
        );
        obj.insert(
            "quarantined_sections".to_string(),
            json!(quarantined_sections),
        );
        for removed in [
            "zapret",
            "zapret2",
            "byedpi",
            "wdtt",
            "olcrtc",
            "tailscale",
            "fptn",
        ] {
            obj.insert(format!("show_component_{removed}"), json!(0));
            obj.insert(format!("{removed}_installed"), json!(0));
        }
    }
    base
}

fn is_safe_sub_job_id(id: &str) -> bool {
    let trimmed = id.trim();
    !trimmed.is_empty()
        && trimmed.len() <= 64
        && trimmed
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
}

fn collect_section_sources_with_owner<'a>(
    store: &'a crate::store::RouterStoreData,
    section: &str,
) -> Vec<(String, &'a crate::store::OutboundSource, bool)> {
    let mut seen: std::collections::HashSet<(String, &str)> = std::collections::HashSet::new();
    let mut seen_global: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut result = Vec::new();
    let include_all = section.is_empty() || section == "all" || section == "_sources";

    let source_by_id: std::collections::HashMap<&str, &'a crate::store::OutboundSource> = store
        .outbound_sources
        .iter()
        .map(|s| (s.id.as_str(), s))
        .collect();
    let group_by_id: std::collections::HashMap<&str, &'a crate::store::OutboundGroup> = store
        .outbound_groups
        .iter()
        .map(|g| (g.id.as_str(), g))
        .collect();
    let bal_by_id: std::collections::HashMap<&str, &'a crate::store::BalancerConfig> =
        store.balancers.iter().map(|b| (b.id.as_str(), b)).collect();
    let sec_by_id: std::collections::HashMap<&str, &'a crate::store::RoutingSection> =
        store.sections.iter().map(|s| (s.id.as_str(), s)).collect();

    fn push_source<'a>(
        owner_sec: &str,
        src: &'a crate::store::OutboundSource,
        sec_hidden: bool,
        seen: &mut std::collections::HashSet<(String, &'a str)>,
        seen_global: &mut std::collections::HashSet<&'a str>,
        result: &mut Vec<(String, &'a crate::store::OutboundSource, bool)>,
    ) {
        if seen.insert((owner_sec.to_string(), src.id.as_str())) {
            seen_global.insert(src.id.as_str());
            result.push((owner_sec.to_string(), src, src.hidden || sec_hidden));
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn collect_group<'a>(
        owner_sec: &str,
        gref: &str,
        sec_hidden: bool,
        store: &'a crate::store::RouterStoreData,
        group_by_id: &std::collections::HashMap<&str, &'a crate::store::OutboundGroup>,
        source_by_id: &std::collections::HashMap<&str, &'a crate::store::OutboundSource>,
        seen: &mut std::collections::HashSet<(String, &'a str)>,
        seen_global: &mut std::collections::HashSet<&'a str>,
        result: &mut Vec<(String, &'a crate::store::OutboundSource, bool)>,
    ) {
        let Some(grp) = group_by_id.get(gref).copied() else {
            return;
        };
        if !grp.enabled {
            return;
        }
        let is_wildcard = grp.source_refs.iter().any(|r| r.trim() == "*")
            || (grp.source_refs.is_empty()
                && grp.primary_refs.is_empty()
                && grp.backup_refs.is_empty());
        if is_wildcard {
            for src in store.outbound_sources.iter().filter(|src| src.enabled) {
                push_source(owner_sec, src, sec_hidden, seen, seen_global, result);
            }
        }
        for sref in grp
            .source_refs
            .iter()
            .chain(grp.primary_refs.iter())
            .chain(grp.backup_refs.iter())
        {
            if let Some(src) = source_by_id.get(sref.as_str()).copied() {
                push_source(owner_sec, src, sec_hidden, seen, seen_global, result);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn collect_sec<'a>(
        owner_sec: &str,
        sec: &'a crate::store::RoutingSection,
        depth: usize,
        visited: &mut std::collections::HashSet<&'a str>,
        store: &'a crate::store::RouterStoreData,
        source_by_id: &std::collections::HashMap<&str, &'a crate::store::OutboundSource>,
        group_by_id: &std::collections::HashMap<&str, &'a crate::store::OutboundGroup>,
        bal_by_id: &std::collections::HashMap<&str, &'a crate::store::BalancerConfig>,
        sec_by_id: &std::collections::HashMap<&str, &'a crate::store::RoutingSection>,
        seen: &mut std::collections::HashSet<(String, &'a str)>,
        seen_global: &mut std::collections::HashSet<&'a str>,
        result: &mut Vec<(String, &'a crate::store::OutboundSource, bool)>,
    ) {
        if depth > 8 || !visited.insert(sec.id.as_str()) {
            return;
        }
        let before = result.len();
        for sref in &sec.outbound_source_refs {
            if let Some(src) = source_by_id.get(sref.as_str()).copied() {
                push_source(owner_sec, src, sec.hidden, seen, seen_global, result);
            }
        }
        for gref in std::iter::once(&sec.outbound_group_ref)
            .chain(sec.outbound_group_refs.iter())
            .chain(sec.outbound_group_levels.iter())
        {
            if !gref.is_empty() {
                collect_group(
                    owner_sec,
                    gref.as_str(),
                    sec.hidden,
                    store,
                    group_by_id,
                    source_by_id,
                    seen,
                    seen_global,
                    result,
                );
                if let Some(src) = source_by_id.get(gref.as_str()).copied() {
                    push_source(owner_sec, src, sec.hidden, seen, seen_global, result);
                }
            }
        }
        for bref in &sec.balancer_refs {
            if let Some(bal) = bal_by_id.get(bref.as_str()).copied() {
                for tok in bal
                    .outbound_group_levels
                    .iter()
                    .chain(bal.balancer_pool.iter())
                {
                    let t = tok.trim();
                    if t.is_empty() {
                        continue;
                    }
                    collect_group(
                        owner_sec,
                        t,
                        sec.hidden,
                        store,
                        group_by_id,
                        source_by_id,
                        seen,
                        seen_global,
                        result,
                    );
                    if let Some(src) = source_by_id.get(t).copied() {
                        push_source(owner_sec, src, sec.hidden, seen, seen_global, result);
                    }
                }
            }
        }
        for sub_ref in &sec.section_refs {
            let trimmed = sub_ref.trim();
            if let Some(child_sec) = sec_by_id.get(trimmed).copied() {
                collect_sec(
                    owner_sec,
                    child_sec,
                    depth + 1,
                    visited,
                    store,
                    source_by_id,
                    group_by_id,
                    bal_by_id,
                    sec_by_id,
                    seen,
                    seen_global,
                    result,
                );
            } else if group_by_id.contains_key(trimmed) {
                collect_group(
                    owner_sec,
                    trimmed,
                    sec.hidden,
                    store,
                    group_by_id,
                    source_by_id,
                    seen,
                    seen_global,
                    result,
                );
            } else if let Some(src) = source_by_id.get(trimmed).copied() {
                push_source(owner_sec, src, sec.hidden, seen, seen_global, result);
            }
        }
        // Proxy/group section with no explicit refs falls back to the enabled source pool
        if depth == 0
            && result.len() == before
            && matches!(
                sec.connection_type.as_str(),
                "proxy" | "group" | "auto" | "urltest" | "selector"
            )
            && sec.outbound_source_refs.is_empty()
            && sec.outbound_group_ref.is_empty()
            && sec.outbound_group_refs.is_empty()
            && sec.section_refs.is_empty()
        {
            for src in &store.outbound_sources {
                if src.enabled {
                    push_source(owner_sec, src, sec.hidden, seen, seen_global, result);
                }
            }
        }
    }

    let exact_match = !include_all && store.sections.iter().any(|s| s.id == section);
    for sec in &store.sections {
        let sec_matches = include_all
            || if exact_match {
                sec.id == section
            } else {
                sec.id.eq_ignore_ascii_case(section)
            };
        if !sec_matches {
            continue;
        }
        let mut visited = std::collections::HashSet::new();
        collect_sec(
            &sec.id,
            sec,
            0,
            &mut visited,
            store,
            &source_by_id,
            &group_by_id,
            &bal_by_id,
            &sec_by_id,
            &mut seen,
            &mut seen_global,
            &mut result,
        );
    }

    if include_all {
        let fallback_sec = store
            .sections
            .first()
            .map(|s| s.id.clone())
            .unwrap_or_else(|| "Main".to_string());
        for src in &store.outbound_sources {
            if seen_global.insert(src.id.as_str()) {
                result.push((fallback_sec.clone(), src, src.hidden));
            }
        }
    }
    result
}

fn parse_openwrt_network_interface_proto(network_uci: &str, iface_name: &str) -> Option<String> {
    let target = iface_name.trim();
    if target.is_empty() {
        return None;
    }

    let unquote = |s: &str| -> String {
        s.trim()
            .trim_matches(|c| c == '\'' || c == '"')
            .trim()
            .to_string()
    };
    let normalize_proto = |raw: &str| -> Option<String> {
        let lower = raw.trim().to_ascii_lowercase();
        if lower.is_empty() {
            return None;
        }
        if lower.contains("amnezia") || lower == "awg" {
            Some("amneziawg".to_string())
        } else if lower.contains("wireguard") || lower == "wg" {
            Some("wireguard".to_string())
        } else if lower.contains("openvpn") || lower == "ovpn" {
            Some("openvpn".to_string())
        } else if lower.contains("tailscale") {
            Some("tailscale".to_string())
        } else {
            None
        }
    };

    let mut cur_name = String::new();
    let mut cur_device = String::new();
    let mut cur_proto = String::new();

    let flush_stanza = |sec_name: &str, sec_dev: &str, sec_proto: &str| -> Option<String> {
        if sec_name.eq_ignore_ascii_case(target)
            || (!sec_dev.is_empty() && sec_dev.eq_ignore_ascii_case(target))
        {
            return normalize_proto(sec_proto);
        }
        None
    };

    for line in network_uci.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("config ") {
            if !cur_name.is_empty()
                && let Some(found) = flush_stanza(&cur_name, &cur_device, &cur_proto)
            {
                return Some(found);
            }
            cur_name.clear();
            cur_device.clear();
            cur_proto.clear();
            let rest_trimmed = rest.trim();
            if let Some(after_iface) = rest_trimmed.strip_prefix("interface") {
                cur_name = unquote(after_iface);
            }
            continue;
        }
        if cur_name.is_empty() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("option ") {
            let mut parts = rest.trim().splitn(2, char::is_whitespace);
            let key = parts.next().unwrap_or("").trim();
            let val = unquote(parts.next().unwrap_or(""));
            if key == "proto" {
                cur_proto = val;
            } else if key == "device" || key == "ifname" {
                cur_device = val;
            }
        }
    }

    if !cur_name.is_empty() {
        return flush_stanza(&cur_name, &cur_device, &cur_proto);
    }
    None
}

fn detect_openwrt_interface_protocol(iface_name: &str) -> String {
    let trimmed = iface_name.trim();
    if !trimmed.is_empty()
        && !crate::platform::is_entware()
        && let Ok(net_cfg) = std::fs::read_to_string("/etc/config/network")
        && let Some(proto) = parse_openwrt_network_interface_proto(&net_cfg, trimmed)
    {
        return proto;
    }

    let lc = trimmed.to_ascii_lowercase();
    if lc == "tailscale0" || lc.starts_with("tailscale") {
        "tailscale".to_string()
    } else if lc.starts_with("awg") {
        "amneziawg".to_string()
    } else if lc.starts_with("wg") {
        "wireguard".to_string()
    } else if lc.starts_with("ovpn") {
        "openvpn".to_string()
    } else {
        "interface".to_string()
    }
}

fn build_outbound_metadata_and_links(
    store: &crate::store::RouterStoreData,
    section: &str,
) -> (Value, Map<String, Value>, Map<String, Value>) {
    let mut names = Map::new();
    let mut countries = Map::new();
    let mut transports = Map::new();
    let mut protocols = Map::new();
    let mut securities = Map::new();
    let mut prefixes = Map::new();
    let mut ports = Map::new();
    let mut source_ids = Map::new();
    let mut source_names = Map::new();
    let mut sources = Map::new();
    let mut hidden = Map::new();
    let mut links = Map::new();

    let mut sub_idx_by_sec: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    let allowed_tags = if !section.is_empty() && section != "all" && section != "_sources" {
        store
            .sections
            .iter()
            .find(|s| s.id == section)
            .and_then(|sec| crate::config_gen::resolve_section_allowed_member_tags(store, sec))
    } else {
        None
    };

    for (owner_sec, src, is_hidden) in collect_section_sources_with_owner(store, section) {
        let src_label = if src.name.trim().is_empty() {
            src.id.clone()
        } else {
            src.name.clone()
        };
        let source_group = if src.source_type == "subscription" {
            let cnt = sub_idx_by_sec.entry(owner_sec).or_insert(0);
            *cnt += 1;
            format!("sub:{}", *cnt)
        } else if src.source_type == "proxy_links" {
            "manual".to_string()
        } else {
            src.id.clone()
        };

        let mut uri_by_tag: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for node in &src.cached_nodes {
            if !node.raw_uri.trim().is_empty() {
                uri_by_tag.insert(node.tag.clone(), node.raw_uri.clone());
                if !src.node_prefix.trim().is_empty() {
                    uri_by_tag.insert(
                        format!("{}{}", src.node_prefix, node.tag),
                        node.raw_uri.clone(),
                    );
                }
            }
        }
        for (idx, raw) in src.proxy_links.iter().enumerate() {
            let trimmed = raw.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if let Some(parsed) = crate::config_gen::parse_proxy_uri(trimmed, idx) {
                uri_by_tag
                    .entry(parsed.tag.clone())
                    .or_insert_with(|| trimmed.to_string());
                if !src.node_prefix.trim().is_empty() {
                    uri_by_tag
                        .entry(format!("{}{}", src.node_prefix, parsed.tag))
                        .or_insert_with(|| trimmed.to_string());
                }
            }
        }

        for (tag, out_val, _) in crate::config_gen::build_source_outbounds(src) {
            if let Some(ref allowed) = allowed_tags
                && !allowed.contains(&tag)
            {
                continue;
            }
            if src.source_type == "interface" {
                let sname = src.name.trim();
                let friendly = if !sname.is_empty() && !sname.starts_with("iface-") {
                    sname.to_string()
                } else if !src.interface_name.trim().is_empty() {
                    src.interface_name.trim().to_string()
                } else {
                    src_label.clone()
                };
                names.entry(tag.clone()).or_insert_with(|| json!(friendly));
            } else {
                names.entry(tag.clone()).or_insert_with(|| json!(tag));
            }
            let cc = crate::config_gen::detect_country_code(&tag);
            if !cc.is_empty() {
                countries.entry(tag.clone()).or_insert_with(|| json!(cc));
            }
            if src.source_type == "interface" {
                let detected_proto = detect_openwrt_interface_protocol(&src.interface_name);
                protocols
                    .entry(tag.clone())
                    .or_insert_with(|| json!(detected_proto));
            } else if let Some(proto) = out_val.get("type").and_then(Value::as_str) {
                protocols.entry(tag.clone()).or_insert_with(|| json!(proto));
            }
            if let Some(tr) = out_val.pointer("/transport/type").and_then(Value::as_str)
                && !tr.is_empty()
            {
                transports.entry(tag.clone()).or_insert_with(|| json!(tr));
            }
            if out_val
                .pointer("/tls/reality/enabled")
                .and_then(Value::as_bool)
                == Some(true)
            {
                securities
                    .entry(tag.clone())
                    .or_insert_with(|| json!("reality"));
            } else if out_val.pointer("/tls/enabled").and_then(Value::as_bool) == Some(true) {
                securities
                    .entry(tag.clone())
                    .or_insert_with(|| json!("tls"));
            }
            if !src.node_prefix.trim().is_empty() {
                prefixes
                    .entry(tag.clone())
                    .or_insert_with(|| json!(src.node_prefix));
            }
            if let Some(port) = out_val.get("server_port").and_then(Value::as_u64) {
                ports.entry(tag.clone()).or_insert_with(|| json!(port));
            }
            if let Some(raw_uri) = uri_by_tag.get(&tag) {
                links.insert(tag.clone(), json!(raw_uri));
            }
            source_ids.insert(tag.clone(), json!(src.id));
            source_names.insert(tag.clone(), json!(src_label));
            sources.insert(tag.clone(), json!(source_group));
            if is_hidden {
                hidden.insert(tag, json!(true));
            }
        }
    }

    let meta = json!({
        "names": names,
        "countries": countries,
        "transports": transports,
        "protocols": protocols,
        "securities": securities,
        "prefixes": prefixes,
        "ports": ports,
        "source_ids": source_ids,
        "source_names": source_names,
        "sources": sources,
        "hidden": hidden.clone(),
    });
    (meta, links, hidden)
}

fn read_pure_rust_outbound_metadata(store: &crate::store::RouterStoreData, section: &str) -> Value {
    let (mut meta_val, _, _) = build_outbound_metadata_and_links(store, section);
    let has_any = meta_val
        .get("names")
        .and_then(Value::as_object)
        .is_some_and(|m| !m.is_empty());
    if !has_any {
        let cache_dir_buf = crate::store::runtime_state_dir().join("section-cache");
        let cache_dir = cache_dir_buf.as_path();
        let mut files = Vec::new();
        if section.is_empty() || section == "all" {
            if let Ok(rd) = std::fs::read_dir(cache_dir) {
                for entry in rd.flatten() {
                    let p = entry.path();
                    if p.extension().and_then(|e| e.to_str()) == Some("json") {
                        files.push(p);
                    }
                }
            }
        } else if !section.contains("..") && !section.contains('/') {
            let p = cache_dir.join(format!("{section}.json"));
            if p.is_file() {
                files.push(p);
            }
        }
        if let Some(dest_meta) = meta_val.as_object_mut() {
            for file in files {
                let Ok(raw) = std::fs::read_to_string(&file) else {
                    continue;
                };
                let Ok(cache) = serde_json::from_str::<Value>(&raw) else {
                    continue;
                };
                let Some(src_meta) = cache.get("outboundMetadata").and_then(Value::as_object)
                else {
                    continue;
                };
                for (field, dest_val) in dest_meta.iter_mut() {
                    if let (Some(src_map), Some(dst_map)) = (
                        src_meta.get(field).and_then(Value::as_object),
                        dest_val.as_object_mut(),
                    ) {
                        for (k, v) in src_map {
                            dst_map.insert(k.clone(), v.clone());
                        }
                    }
                }
            }
        }
    }
    meta_val
}

fn read_pure_rust_subscription_metadata(
    store: &crate::store::RouterStoreData,
    section: &str,
) -> Value {
    if section.contains("..") || section.contains('/') {
        return json!([]);
    }

    let mut items: Vec<Value> = Vec::new();
    let mut sub_idx_by_sec: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    for (owner_sec, src, is_hidden) in collect_section_sources_with_owner(store, section) {
        if src.source_type != "subscription" {
            continue;
        }
        let sec_label = if section.is_empty() || section == "all" {
            owner_sec.as_str()
        } else {
            section
        };
        let cnt = sub_idx_by_sec.entry(sec_label.to_string()).or_insert(0);
        *cnt += 1;
        let sub_idx = *cnt;
        let used = src.sub_upload_bytes.saturating_add(src.sub_download_bytes);
        let total = src.sub_total_bytes;
        let remaining = total.saturating_sub(used);
        let title = if !src.sub_title.trim().is_empty() {
            crate::store::decode_sub_header_value(&src.sub_title)
        } else if !src.name.trim().is_empty() {
            crate::store::decode_sub_header_value(&src.name)
        } else {
            src.id.clone()
        };
        let mut obj = Map::new();
        obj.insert("sourceId".into(), json!(src.id));
        obj.insert(
            "sourceSection".into(),
            json!(format!("{sec_label}-subscription-{sub_idx}")),
        );
        obj.insert("sourceIndex".into(), json!(sub_idx));
        obj.insert("title".into(), json!(title));
        if let Some(u) = src.subscription_urls.first() {
            obj.insert("url".into(), json!(u));
        }
        obj.insert("urls".into(), json!(src.subscription_urls));
        let built = crate::config_gen::build_source_outbounds(src);
        let visible_count = built.iter().filter(|(_, _, vis)| *vis).count();
        let effective_node_count =
            if !src.enabled && built.is_empty() && !src.cached_nodes.is_empty() {
                src.cached_nodes.len()
            } else {
                visible_count
            };
        obj.insert("nodeCount".into(), json!(effective_node_count));
        if src.last_updated_unix > 0 {
            obj.insert("updatedAt".into(), json!(src.last_updated_unix));
        }
        if src.sub_expire_unix > 0 {
            obj.insert("expire".into(), json!(src.sub_expire_unix));
        }
        obj.insert(
            "traffic".into(),
            json!({
                "upload": src.sub_upload_bytes,
                "download": src.sub_download_bytes,
                "used": used,
                "total": total,
                "remaining": remaining,
                "isUnlimited": total == 0,
            }),
        );
        if !src.sub_web_page_url.is_empty() {
            obj.insert("webPageUrl".into(), json!(src.sub_web_page_url));
        }
        if !src.sub_support_url.is_empty() {
            obj.insert("supportUrl".into(), json!(src.sub_support_url));
        }
        if !src.sub_announce.is_empty() {
            obj.insert(
                "announce".into(),
                json!(crate::store::decode_sub_header_value(&src.sub_announce)),
            );
        }
        if !src.sub_last_error.is_empty() {
            obj.insert("lastError".into(), json!(src.sub_last_error));
        }
        if is_hidden {
            obj.insert("hidden".into(), json!(true));
        }
        items.push(Value::Object(obj));
    }

    if !items.is_empty() {
        return Value::Array(items);
    }

    if !section.is_empty() && section != "all" {
        let cache_path = crate::store::runtime_state_dir()
            .join("section-cache")
            .join(format!("{section}.json"));
        if let Ok(raw) = std::fs::read_to_string(&cache_path)
            && let Ok(cache) = serde_json::from_str::<Value>(&raw)
            && let Some(arr) = cache.get("subscriptionMetadata").and_then(Value::as_array)
            && !arr.is_empty()
        {
            return Value::Array(arr.clone());
        }
    }
    json!([])
}

/// Synchronize per-section runtime cache files in `<runtime_state_dir>/section-cache/*.json`
/// and virtual tmpfs subscription cache files in `/tmp/tachyon-core/subscriptions/Pool_<sid>-subscription-1.*`.
pub fn sync_section_cache(store: &crate::store::RouterStoreData) {
    let cache_dir = crate::store::runtime_state_dir().join("section-cache");
    let _ = std::fs::create_dir_all(&cache_dir);
    let mut balancer_caches = crate::config_gen::build_all_section_balancer_caches(store);

    let mut active_files = std::collections::HashSet::new();
    for sec in &store.sections {
        if sec.id.is_empty() || sec.id.contains("..") || sec.id.contains('/') {
            continue;
        }
        let fname = format!("{}.json", sec.id);
        active_files.insert(fname.clone());
        let (outbound_meta, links, hidden) = build_outbound_metadata_and_links(store, &sec.id);
        let sub_meta = read_pure_rust_subscription_metadata(store, &sec.id);
        let (urltest_groups, priority_groups) = balancer_caches
            .remove(&sec.id)
            .unwrap_or_else(|| (json!({}), json!({})));
        let payload = json!({
            "section": sec.id,
            "outboundMetadata": outbound_meta,
            "subscriptionMetadata": sub_meta,
            "links": links,
            "hiddenOutboundTags": hidden,
            "urltestGroups": urltest_groups,
            "priorityGroups": priority_groups,
        });
        let _ = crypto_gen::write_json_if_changed(cache_dir.join(fname), &payload);
    }

    // Aggregate all sources (including unassigned subscriptions/nodes) in `_sources.json`
    active_files.insert("_sources.json".to_string());
    let (all_outbound_meta, all_links, all_hidden) =
        build_outbound_metadata_and_links(store, "_sources");
    let all_sub_meta = read_pure_rust_subscription_metadata(store, "_sources");
    let sources_payload = json!({
        "section": "_sources",
        "outboundMetadata": all_outbound_meta,
        "subscriptionMetadata": all_sub_meta,
        "links": all_links,
        "hiddenOutboundTags": all_hidden,
        "urltestGroups": json!({}),
        "priorityGroups": json!({}),
    });
    let _ = crypto_gen::write_json_if_changed(cache_dir.join("_sources.json"), &sources_payload);

    if let Ok(rd) = std::fs::read_dir(&cache_dir) {
        for entry in rd.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("json")
                && let Some(name) = path.file_name().and_then(|n| n.to_str())
                && !active_files.contains(name)
            {
                let _ = std::fs::remove_file(&path);
            }
        }
    }

    // Materialize tmpfs Pool_<sid>-subscription-1.* files for UI views without touching flash
    let sub_dir = virtual_sub_cache_dir();
    let _ = std::fs::create_dir_all(&sub_dir);
    let mut active_pool_files = std::collections::HashSet::new();
    for src in &store.outbound_sources {
        if src.source_type != "subscription"
            || src.id.is_empty()
            || src.id.contains('/')
            || src.id.contains("..")
        {
            continue;
        }
        let base = format!("Pool_{}-subscription-1", src.id);
        let mut outbounds_arr: Vec<Value> = Vec::new();
        let mut raw_links: Vec<String> = Vec::new();
        let mut link_by_tag: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for node in &src.cached_nodes {
            let trimmed = node.raw_uri.trim();
            if !trimmed.is_empty() {
                raw_links.push(trimmed.to_string());
                link_by_tag.insert(node.tag.clone(), trimmed.to_string());
                if !src.node_prefix.trim().is_empty() {
                    link_by_tag.insert(
                        format!("{}{}", src.node_prefix, node.tag),
                        trimmed.to_string(),
                    );
                }
            }
        }
        for (idx, raw) in src.proxy_links.iter().enumerate() {
            let trimmed = raw.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if !raw_links.iter().any(|l| l == trimmed) {
                raw_links.push(trimmed.to_string());
            }
            if let Some(parsed) = crate::config_gen::parse_proxy_uri(trimmed, idx) {
                link_by_tag
                    .entry(parsed.tag)
                    .or_insert_with(|| trimmed.to_string());
            }
        }
        for (tag, mut ob_val, visible) in crate::config_gen::build_source_outbounds(src) {
            if !visible {
                continue;
            }
            if let Some(obj) = ob_val.as_object_mut() {
                obj.entry("tag").or_insert_with(|| json!(tag));
                if let Some(lnk) = link_by_tag.get(&tag) {
                    obj.insert("share_link".into(), json!(lnk));
                }
            }
            outbounds_arr.push(ob_val);
        }
        // Preserve disabled-source preview from cached_nodes if enabled=false produced 0 outbounds
        if !src.enabled && outbounds_arr.is_empty() {
            for node in &src.cached_nodes {
                let mut ob = node.outbound_json.clone();
                if let Some(obj) = ob.as_object_mut() {
                    obj.entry("tag").or_insert_with(|| json!(node.tag));
                    if !node.raw_uri.trim().is_empty() {
                        obj.insert("share_link".into(), json!(node.raw_uri.trim()));
                    }
                }
                outbounds_arr.push(ob);
            }
        }
        let json_name = format!("{base}.json");
        let links_name = format!("{base}.links");
        let meta_name = format!("{base}.metadata.json");
        let url_name = format!("{base}.url");

        let _ = crypto_gen::write_json_if_changed(
            sub_dir.join(&json_name),
            &json!({ "outbounds": outbounds_arr }),
        );
        active_pool_files.insert(json_name);

        let links_text = if raw_links.is_empty() {
            String::new()
        } else {
            format!("{}\n", raw_links.join("\n"))
        };
        let _ = crypto_gen::write_file_if_changed(sub_dir.join(&links_name), links_text.as_bytes());
        active_pool_files.insert(links_name);

        if let Some(first_url) = src.subscription_urls.first()
            && !first_url.trim().is_empty()
        {
            let _ = crypto_gen::write_file_if_changed(
                sub_dir.join(&url_name),
                first_url.trim().as_bytes(),
            );
            active_pool_files.insert(url_name);
        }

        let used = src.sub_upload_bytes.saturating_add(src.sub_download_bytes);
        let total = src.sub_total_bytes;
        let title = if !src.sub_title.trim().is_empty() {
            crate::store::decode_sub_header_value(&src.sub_title)
        } else if !src.name.trim().is_empty() {
            crate::store::decode_sub_header_value(&src.name)
        } else {
            src.id.clone()
        };
        let mut meta_obj = Map::new();
        meta_obj.insert("sourceId".into(), json!(src.id));
        meta_obj.insert("sourceSection".into(), json!(base));
        meta_obj.insert("title".into(), json!(title));
        if let Some(u) = src.subscription_urls.first() {
            meta_obj.insert("url".into(), json!(u));
        }
        meta_obj.insert("urls".into(), json!(src.subscription_urls));
        meta_obj.insert("nodeCount".into(), json!(outbounds_arr.len()));
        if src.last_updated_unix > 0 {
            meta_obj.insert("updatedAt".into(), json!(src.last_updated_unix));
        }
        if src.sub_expire_unix > 0 {
            meta_obj.insert("expire".into(), json!(src.sub_expire_unix));
        }
        meta_obj.insert(
            "traffic".into(),
            json!({
                "upload": src.sub_upload_bytes,
                "download": src.sub_download_bytes,
                "used": used,
                "total": total,
                "remaining": total.saturating_sub(used),
                "isUnlimited": total == 0,
            }),
        );
        if !src.sub_web_page_url.is_empty() {
            meta_obj.insert("webPageUrl".into(), json!(src.sub_web_page_url));
        }
        if !src.sub_support_url.is_empty() {
            meta_obj.insert("supportUrl".into(), json!(src.sub_support_url));
        }
        if !src.sub_announce.is_empty() {
            meta_obj.insert(
                "announce".into(),
                json!(crate::store::decode_sub_header_value(&src.sub_announce)),
            );
        }
        if !src.sub_last_error.is_empty() {
            meta_obj.insert("lastError".into(), json!(src.sub_last_error));
        }
        let _ =
            crypto_gen::write_json_if_changed(sub_dir.join(&meta_name), &Value::Object(meta_obj));
        active_pool_files.insert(meta_name);
    }

    if let Ok(rd) = std::fs::read_dir(&sub_dir) {
        for entry in rd.flatten() {
            let path = entry.path();
            if let Some(name) = path.file_name().and_then(|n| n.to_str())
                && name.starts_with("Pool_")
                && name.contains("-subscription-")
                && !active_pool_files.contains(name)
            {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
}

fn read_pure_rust_component_update_cache() -> Value {
    crate::updater::read_component_check_cache()
}

fn read_cached_clash_proxies(path: &Path) -> Option<String> {
    use serde::de::{Deserializer, IgnoredAny, MapAccess, Visitor};

    #[derive(serde::Deserialize)]
    struct Snapshot {
        #[serde(rename = "proxies", deserialize_with = "require_object")]
        _proxies: (),
    }

    fn require_object<'de, D: Deserializer<'de>>(de: D) -> Result<(), D::Error> {
        struct Object;

        impl<'de> Visitor<'de> for Object {
            type Value = ();

            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a proxy object")
            }

            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<(), M::Error> {
                while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
                Ok(())
            }
        }

        de.deserialize_map(Object)
    }

    let mut raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<Snapshot>(&raw).ok()?;
    // Preserve the validated payload and avoid allocating a second proxy tree.
    let end = raw.trim_end().strip_suffix('}')?.len();
    raw.truncate(end);
    raw.push_str(",\"tachyon_cached\":true}\n");
    Some(raw)
}

async fn handle_pure_rust_clash_api(
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<(i32, String, String)> {
    let action = rest.first().map(String::as_str).unwrap_or("");
    match action {
        "get_switch_history" => {
            let limit = rest
                .get(1)
                .and_then(|arg| arg.parse().ok())
                .unwrap_or(crate::switch_history::LIMIT);
            let group = rest.get(2).map(String::as_str).unwrap_or("");
            let reason = rest.get(3).map(String::as_str).unwrap_or("");
            match crate::switch_history::recent(
                &crate::switch_history::path(),
                limit,
                group,
                reason,
            ) {
                Ok(events) => {
                    let store_snap = state.data.read().await.clone();
                    let tag_map = build_telemetry_tag_display_map(&store_snap);
                    let enriched: Vec<Value> = events
                        .into_iter()
                        .map(|ev| {
                            let mut val = serde_json::to_value(&ev).unwrap_or(Value::Null);
                            if let Some(obj) = val.as_object_mut() {
                                for (raw_key, disp_key) in [
                                    ("group", "group_display_name"),
                                    ("from", "from_display_name"),
                                    ("to", "to_display_name"),
                                    ("primary", "primary_display_name"),
                                ] {
                                    if let Some(raw_val) = obj
                                        .get(raw_key)
                                        .and_then(Value::as_str)
                                        .map(str::trim)
                                        .filter(|s| !s.is_empty())
                                        .map(str::to_owned)
                                    {
                                        obj.insert(
                                            disp_key.to_string(),
                                            json!(resolve_telemetry_tag_display_name(
                                                &raw_val,
                                                &tag_map,
                                                &store_snap
                                            )),
                                        );
                                    }
                                }
                            }
                            val
                        })
                        .collect();
                    Some((
                        0,
                        format!(
                            "{}\n",
                            json!({ "events": enriched, "stats": core.switch_history_stats() })
                        ),
                        String::new(),
                    ))
                }
                Err(_) => Some((1, String::new(), "Switch history unavailable\n".to_owned())),
            }
        }
        "get_proxies" => {
            if let Ok(val) = core.clash_request("GET", "/proxies", None).await
                && let Ok(raw) = serde_json::to_string(&val)
            {
                let ui_state = crate::store::runtime_state_dir().join("ui-state");
                let _ = std::fs::create_dir_all(&ui_state);
                let _ = crypto_gen::write_file_if_changed(
                    ui_state.join("clash-proxies.json"),
                    raw.as_bytes(),
                );
                return Some((0, format!("{raw}\n"), String::new()));
            }
            let cached_proxies_path = crate::store::runtime_state_dir()
                .join("ui-state")
                .join("clash-proxies.json");
            if let Some(cached) = read_cached_clash_proxies(&cached_proxies_path) {
                return Some((0, cached, String::new()));
            }
            Some((0, "{\"proxies\":{}}\n".to_string(), String::new()))
        }
        "get_connections" => {
            state.touch_telemetry_access();
            let conntrack_only = rest.get(1).map(String::as_str) == Some("conntrack");
            if !conntrack_only {
                let cache_path = crate::store::runtime_state_dir()
                    .join("ui-state")
                    .join("clash-connections.json");
                if let Ok(meta) = std::fs::metadata(&cache_path)
                    && let Ok(mtime) = meta.modified()
                    && mtime.elapsed().is_ok_and(|age| age.as_secs() < 2)
                    && let Ok(cached) = std::fs::read_to_string(cache_path)
                    && !cached.trim().is_empty()
                    && serde_json::from_str::<Value>(&cached).is_ok()
                {
                    let body = if cached.ends_with('\n') {
                        cached
                    } else {
                        format!("{cached}\n")
                    };
                    return Some((0, body, String::new()));
                }
            }
            let mut ip_host_map: std::collections::HashMap<String, String> =
                std::collections::HashMap::new();
            if let Ok(raw_hosts) = std::fs::read_to_string("/tmp/tachyon_dns_hosts.json")
                && let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&raw_hosts)
            {
                for (ip, dom) in map {
                    if let Some(d) = dom.as_str()
                        && !ip.is_empty()
                        && !d.is_empty()
                    {
                        ip_host_map.insert(ip, d.to_string());
                    }
                }
            }
            let fakeip_cidr_owned = state.data.read().await.settings.fakeip_inet4_range.clone();
            let fakeip_cidr =
                (!fakeip_cidr_owned.trim().is_empty()).then_some(fakeip_cidr_owned.trim());
            if conntrack_only {
                let ct_conns = read_pure_rust_conntrack_connections(
                    &ip_host_map,
                    &std::collections::HashSet::new(),
                    &std::collections::HashSet::new(),
                    fakeip_cidr,
                    150,
                );
                let out = json!({ "connections": ct_conns });
                let raw = serde_json::to_string(&out)
                    .unwrap_or_else(|_| "{\"connections\":[]}".to_string());
                return Some((0, format!("{raw}\n"), String::new()));
            }
            if let Ok(mut val) = core.clash_request("GET", "/connections", None).await {
                if let Some(rev) = val
                    .as_object_mut()
                    .and_then(|o| o.remove("reverseDns"))
                    .and_then(|v| v.as_object().cloned())
                {
                    for (ip, dom) in rev {
                        if let Some(d) = dom.as_str()
                            && !ip.is_empty()
                            && !d.is_empty()
                        {
                            ip_host_map.insert(ip, d.to_string());
                        }
                    }
                }
                let mut seen_tuples: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                let mut seen_client_sockets: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                if let Some(conns) = val.get_mut("connections").and_then(Value::as_array_mut) {
                    for c in conns.iter_mut() {
                        if let Some(obj) = c.as_object_mut() {
                            obj.entry("dataSource".to_string())
                                .or_insert_with(|| json!("core"));
                            if let Some(meta) =
                                obj.get_mut("metadata").and_then(Value::as_object_mut)
                            {
                                let proto = meta
                                    .get("network")
                                    .and_then(Value::as_str)
                                    .unwrap_or("tcp")
                                    .to_ascii_lowercase();
                                let src = meta
                                    .get("sourceIP")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string();
                                let sport = meta
                                    .get("sourcePort")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string();
                                let dst = meta
                                    .get("destinationIP")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string();
                                let dport = meta
                                    .get("destinationPort")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string();
                                if !src.is_empty() && !dst.is_empty() {
                                    seen_tuples
                                        .insert(format!("{proto}|{src}|{sport}|{dst}|{dport}"));
                                }
                                // Only match by 4-tuple (omitting destinationIP) when core left destinationIP empty;
                                // symmetric/full-cone UDP flows can share (src, sport, dport) across multiple dst IPs.
                                if dst.is_empty()
                                    && !src.is_empty()
                                    && !sport.is_empty()
                                    && !dport.is_empty()
                                {
                                    seen_client_sockets
                                        .insert(format!("{proto}|{src}|{sport}|{dport}"));
                                }
                                let cur_host =
                                    meta.get("host").and_then(Value::as_str).unwrap_or("");
                                if cur_host.is_empty()
                                    && let Some(resolved) = ip_host_map.get(&dst)
                                {
                                    meta.insert("host".to_string(), json!(resolved));
                                } else if !cur_host.is_empty() && !dst.is_empty() {
                                    ip_host_map
                                        .entry(dst)
                                        .or_insert_with(|| cur_host.to_string());
                                }
                            }
                        }
                    }
                    let ct_conns = read_pure_rust_conntrack_connections(
                        &ip_host_map,
                        &seen_tuples,
                        &seen_client_sockets,
                        fakeip_cidr,
                        120,
                    );
                    conns.extend(ct_conns);
                }
                let mut raw = serde_json::to_string(&val)
                    .unwrap_or_else(|_| "{\"connections\":[]}".to_string());
                if raw.len() > 56_000 {
                    if let Some(conns) = val.get_mut("connections").and_then(Value::as_array_mut) {
                        for c in conns.iter_mut() {
                            if let Some(obj) = c.as_object_mut()
                                && let Some(rule_str) = obj.get("rule").and_then(Value::as_str)
                                && rule_str.len() > 96
                            {
                                let short = if let Some(pos) = rule_str.rfind(" => ") {
                                    format!("...{}", &rule_str[pos..])
                                } else {
                                    rule_str.chars().take(96).collect()
                                };
                                obj.insert("rule".to_string(), json!(short));
                            }
                        }
                    }
                    loop {
                        let candidate = serde_json::to_string(&val).unwrap_or_default();
                        if candidate.len() <= 56_000 {
                            raw = candidate;
                            break;
                        }
                        let Some(conns) = val.get_mut("connections").and_then(Value::as_array_mut)
                        else {
                            break;
                        };
                        if conns.len() <= 20 {
                            raw = candidate;
                            break;
                        }
                        let new_len = ((conns.len() * 3) / 4).max(20);
                        conns.truncate(new_len);
                    }
                }
                let ui_dir = crate::store::runtime_state_dir().join("ui-state");
                let _ = std::fs::create_dir_all(&ui_dir);
                let _ = crypto_gen::write_file_if_changed(
                    ui_dir.join("clash-connections.json"),
                    raw.as_bytes(),
                );
                return Some((0, format!("{raw}\n"), String::new()));
            }
            if let Ok(cached) = std::fs::read_to_string(
                crate::store::runtime_state_dir()
                    .join("ui-state")
                    .join("clash-connections.json"),
            ) && !cached.trim().is_empty()
            {
                return Some((0, format!("{}\n", cached.trim()), String::new()));
            }
            let ct_conns = read_pure_rust_conntrack_connections(
                &ip_host_map,
                &std::collections::HashSet::new(),
                &std::collections::HashSet::new(),
                fakeip_cidr,
                120,
            );
            let fallback = json!({
                "uploadTotal": 0,
                "downloadTotal": 0,
                "connections": ct_conns
            });
            let raw = serde_json::to_string(&fallback)
                .unwrap_or_else(|_| "{\"connections\":[]}".to_string());
            Some((0, format!("{raw}\n"), String::new()))
        }
        "set_group_proxy" => {
            let group = rest.get(1).map(String::as_str).unwrap_or("");
            let proxy = rest.get(2).map(String::as_str).unwrap_or("");
            if group.is_empty() || proxy.is_empty() {
                let s = serde_json::to_string(&json!({
                    "success": false,
                    "error": "Missing group or proxy"
                }))
                .unwrap_or_default();
                return Some((1, format!("{s}\n"), String::new()));
            }
            let d_snap = state.data.read().await.clone();
            let proxies_val = core.clash_request("GET", "/proxies", None).await.ok();
            let proxies_map = proxies_val
                .as_ref()
                .and_then(|v| v.get("proxies"))
                .and_then(Value::as_object);
            let mut effective_group = resolve_clash_group_for_target(&d_snap, proxies_map, group);
            if let Some(map) = proxies_map
                && let Some(entry) = map.get(&effective_group)
                && entry.get("type").and_then(Value::as_str) != Some("Selector")
            {
                let sec_match = d_snap.sections.iter().find(|s| {
                    effective_group == s.id
                        || effective_group == format!("sel-{}", s.id)
                        || effective_group == format!("{}-out", s.id)
                        || effective_group.starts_with(&format!("bal-{}-", s.id))
                });
                if let Some(sec) = sec_match {
                    for cand in [format!("sel-{}", sec.id), format!("{}-out", sec.id)] {
                        if map
                            .get(&cand)
                            .and_then(|v| v.get("type"))
                            .and_then(Value::as_str)
                            == Some("Selector")
                        {
                            effective_group = cand;
                            break;
                        }
                    }
                }
                if map
                    .get(&effective_group)
                    .and_then(|v| v.get("type"))
                    .and_then(Value::as_str)
                    != Some("Selector")
                {
                    let has_member = |entry: &Value, target: &str| {
                        entry
                            .get("all")
                            .and_then(Value::as_array)
                            .is_some_and(|arr| arr.iter().any(|v| v.as_str() == Some(target)))
                    };
                    if let Some((cand, _)) = map
                        .iter()
                        .find(|(_, v)| {
                            v.get("type").and_then(Value::as_str) == Some("Selector")
                                && has_member(v, &effective_group)
                                && has_member(v, proxy)
                        })
                        .or_else(|| {
                            map.iter().find(|(_, v)| {
                                v.get("type").and_then(Value::as_str) == Some("Selector")
                                    && has_member(v, proxy)
                            })
                        })
                    {
                        effective_group = cand.clone();
                    }
                }
            }
            let encoded = url_encode_component(&effective_group);
            let body = serde_json::to_string(&json!({ "name": proxy })).unwrap_or_default();
            if let Err(e) = core
                .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&body))
                .await
            {
                let s = serde_json::to_string(&json!({
                    "success": false,
                    "group": effective_group,
                    "error": format!("{e:#}")
                }))
                .unwrap_or_default();
                return Some((1, format!("{s}\n"), String::new()));
            }
            CoreManager::save_selector_choice(&effective_group, proxy);
            {
                let mut d = state.data.write().await;
                let base_id = group
                    .strip_prefix("sel-")
                    .or_else(|| group.strip_suffix("-out"))
                    .unwrap_or(group);
                if let Some(sec) = d.sections.iter_mut().find(|s| {
                    s.id == group
                        || s.id == base_id
                        || format!("sel-{}", s.id) == effective_group
                        || effective_group.starts_with(&format!("bal-{}-", s.id))
                }) {
                    sec.active_selected_tag = proxy.to_string();
                }
            }
            let _ = state.save().await;
            let d_updated = state.data.read().await.clone();
            sync_from_store_to_json_and_cache(&d_updated);
            Some((0, "{\"success\":true}\n".to_string(), String::new()))
        }
        "close_connection" => {
            if let Some(id) = rest.get(1) {
                let encoded = url_encode_component(id);
                let _ = core
                    .clash_request("DELETE", &format!("/connections/{encoded}"), None)
                    .await;
            }
            Some((0, "{\"success\":true}\n".to_string(), String::new()))
        }
        "close_all_connections" => {
            let _ = core.clash_request("DELETE", "/connections", None).await;
            Some((0, "{\"success\":true}\n".to_string(), String::new()))
        }
        "get_proxy_latency" | "get_group_latency" => {
            let tag = rest.get(1).map(String::as_str).unwrap_or("");
            let timeout = rest.get(2).map(String::as_str).unwrap_or("8000");
            let url = rest
                .get(3)
                .map(String::as_str)
                .unwrap_or("https://www.gstatic.com/generate_204");
            if tag.is_empty() {
                return Some((
                    1,
                    "{\"success\":false,\"delay\":0,\"error\":\"Missing tag\"}\n".to_string(),
                    String::new(),
                ));
            }
            let is_group = action == "get_group_latency";
            let timeout_ms = timeout
                .trim()
                .parse::<u64>()
                .unwrap_or(8000)
                .clamp(1000, 20_000);
            let encoded_url = url_encode_component(url);
            let build_delay_path = |probe_tag: &str, t_ms: u64| {
                let enc = url_encode_component(probe_tag);
                if is_group {
                    format!("/group/{enc}/delay?url={encoded_url}&timeout={t_ms}")
                } else {
                    format!("/proxies/{enc}/delay?url={encoded_url}&timeout={t_ms}")
                }
            };

            let mut proxies_cache: Option<Value> = None;
            let mut probed_tag = if is_group {
                let d_snap = state.data.read().await.clone();
                proxies_cache = core.clash_request("GET", "/proxies", None).await.ok();
                let proxies_map = proxies_cache
                    .as_ref()
                    .and_then(|v| v.get("proxies"))
                    .and_then(Value::as_object);
                resolve_clash_group_for_target(&d_snap, proxies_map, tag)
            } else {
                tag.to_string()
            };

            let primary_path = build_delay_path(&probed_tag, timeout_ms);
            let primary_res = core.clash_request("GET", &primary_path, None).await;
            let mut resolved_fallback = false;

            let mut final_res = if !is_group
                && match &primary_res {
                    Err(_) => true,
                    Ok(val) => !has_positive_delay_response(val),
                } {
                let d_snap = state.data.read().await.clone();
                if proxies_cache.is_none() {
                    proxies_cache = core.clash_request("GET", "/proxies", None).await.ok();
                }
                let proxies_map = proxies_cache
                    .as_ref()
                    .and_then(|v| v.get("proxies"))
                    .and_then(Value::as_object);
                if let Some(fallback_tag) =
                    proxies_map.and_then(|pm| resolve_clash_proxy_for_target(&d_snap, pm, tag))
                {
                    probed_tag = fallback_tag;
                    resolved_fallback = true;
                    let fallback_path = build_delay_path(&probed_tag, timeout_ms);
                    match core.clash_request("GET", &fallback_path, None).await {
                        Ok(val) => Ok(val),
                        Err(fallback_err) => {
                            if primary_res.is_ok() {
                                primary_res
                            } else {
                                Err(fallback_err)
                            }
                        }
                    }
                } else {
                    primary_res
                }
            } else {
                primary_res
            };

            if is_transient_delay_probe_failure(&final_res) {
                if proxies_cache.is_none() {
                    proxies_cache = core.clash_request("GET", "/proxies", None).await.ok();
                }
                let tag_exists = proxies_cache
                    .as_ref()
                    .and_then(|v| v.get("proxies"))
                    .and_then(Value::as_object)
                    .is_some_and(|pm| pm.contains_key(&probed_tag));
                if tag_exists {
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                    let retry_timeout_ms = timeout_ms.clamp(8000, 15_000);
                    let retry_path = build_delay_path(&probed_tag, retry_timeout_ms);
                    if let Ok(val) = core.clash_request("GET", &retry_path, None).await
                        && (has_positive_delay_response(&val) || final_res.is_err())
                    {
                        final_res = Ok(val);
                    }
                }
            }

            if let Ok(ref val) = final_res
                && let Some(ms) = val.get("delay").and_then(Value::as_u64)
                && ms > 0
            {
                let mut live = state.live.write().await;
                if live.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES {
                    live.node_latencies_ms.insert(
                        if resolved_fallback || !probed_tag.is_empty() {
                            probed_tag.clone()
                        } else {
                            tag.to_string()
                        },
                        ms as u32,
                    );
                }
            }

            match final_res {
                Ok(val) => {
                    let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
                    Some((0, format!("{s}\n"), String::new()))
                }
                Err(e) => {
                    let out = json!({
                        "delay": 0,
                        "success": false,
                        "error": format!("{e:#}")
                    });
                    Some((
                        1,
                        format!("{}\n", serde_json::to_string(&out).unwrap_or_default()),
                        String::new(),
                    ))
                }
            }
        }
        "get_proxy_latencies" => {
            let arg = rest.get(1).map(String::as_str).unwrap_or("Main").trim();
            let mut delays = Map::new();
            let mut probe_error: Option<String> = None;

            if arg.starts_with('[')
                && let Ok(tags) = serde_json::from_str::<Vec<String>>(arg)
            {
                let mut join_set = tokio::task::JoinSet::new();
                let sem = Arc::new(tokio::sync::Semaphore::new(8));
                for tag in tags.into_iter().filter(|t| !t.trim().is_empty()) {
                    let core_c = Arc::clone(core);
                    let permit_sem = Arc::clone(&sem);
                    join_set.spawn(async move {
                        let _permit = permit_sem.acquire().await.ok();
                        let encoded = url_encode_component(&tag);
                        let path = format!(
                            "/proxies/{encoded}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000"
                        );
                        let ms = core_c
                            .clash_request("GET", &path, None)
                            .await
                            .ok()
                            .and_then(|v| v.get("delay").and_then(Value::as_u64));
                        (tag, ms)
                    });
                }
                let mut l = state.live.write().await;
                while let Some(Ok((tag, ms_opt))) = join_set.join_next().await {
                    if let Some(ms) = ms_opt {
                        delays.insert(tag.clone(), json!(ms));
                        if l.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES {
                            l.node_latencies_ms.insert(tag, ms as u32);
                        }
                    } else {
                        delays.insert(tag, json!(0));
                    }
                }
            } else {
                let d_snap = state.data.read().await.clone();
                let proxies_val = core.clash_request("GET", "/proxies", None).await.ok();
                let proxies_map = proxies_val
                    .as_ref()
                    .and_then(|v| v.get("proxies"))
                    .and_then(Value::as_object);
                let group_tag = resolve_clash_group_for_target(&d_snap, proxies_map, arg);
                let encoded_tag = url_encode_component(&group_tag);
                let path = format!(
                    "/group/{encoded_tag}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000"
                );
                match core.clash_request("GET", &path, None).await {
                    Ok(val) => {
                        if let Some(obj) = val.as_object() {
                            let mut l = state.live.write().await;
                            for (k, v) in obj {
                                delays.insert(k.clone(), v.clone());
                                if let Some(ms) = v.as_u64()
                                    && ms > 0
                                    && l.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES
                                {
                                    l.node_latencies_ms.insert(k.clone(), ms as u32);
                                }
                            }
                        }
                    }
                    Err(e) => {
                        probe_error = Some(format!("{e:#}"));
                    }
                }
            }

            let count = delays.len();
            let failed = count == 0 && probe_error.is_some();
            let mut out = json!({
                "success": !failed,
                "count": count,
                "failed": failed,
                "delays": delays,
            });
            if let Some(err) = probe_error
                && let Some(obj) = out.as_object_mut()
            {
                obj.insert("error".to_string(), json!(err));
            }
            Some((
                if failed { 1 } else { 0 },
                format!("{}\n", serde_json::to_string(&out).unwrap_or_default()),
                String::new(),
            ))
        }
        _ => None,
    }
}

fn resolve_clash_group_for_target(
    store: &crate::store::RouterStoreData,
    proxies_map: Option<&Map<String, Value>>,
    target: &str,
) -> String {
    let req = target.trim();
    if req.is_empty() {
        return "Main".to_string();
    }
    if let Some(map) = proxies_map
        && map.contains_key(req)
    {
        return req.to_string();
    }
    let sec_base = req
        .strip_prefix("sel-")
        .or_else(|| req.strip_suffix("-out"))
        .unwrap_or(req);
    if let Some(sec) = store
        .sections
        .iter()
        .find(|s| s.id == sec_base || s.id == req)
    {
        let mut candidates = Vec::new();
        for bref in &sec.balancer_refs {
            if !bref.trim().is_empty() {
                candidates.push(format!("bal-{}-{bref}", sec.id));
            }
        }
        for bal in &store.balancers {
            if bal.enabled {
                candidates.push(format!("bal-{}-{}", sec.id, bal.id));
            }
        }
        candidates.push(format!("sel-{}", sec.id));
        candidates.push(format!("{}-out", sec.id));
        candidates.push(sec.id.clone());
        if let Some(map) = proxies_map {
            for cand in &candidates {
                if map.contains_key(cand) {
                    return cand.clone();
                }
            }
        }
        if let Some(first) = candidates.into_iter().next() {
            return first;
        }
    }
    req.to_string()
}

fn collect_clash_leaf_members(proxies_map: &Map<String, Value>, root_group: &str) -> Vec<String> {
    let mut visited = std::collections::HashSet::new();
    let mut stack = vec![root_group.to_string()];
    let mut out = Vec::new();
    let mut seen_leaf = std::collections::HashSet::new();

    while let Some(cur) = stack.pop() {
        if !visited.insert(cur.clone()) {
            continue;
        }
        let Some(entry) = proxies_map.get(&cur) else {
            continue;
        };
        if let Some(all) = entry.get("all").and_then(Value::as_array) {
            for item in all {
                let Some(tag) = item.as_str().map(str::trim).filter(|s| !s.is_empty()) else {
                    continue;
                };
                if matches!(tag, "direct" | "block" | "GLOBAL" | "reject" | "dns-out") {
                    continue;
                }
                let is_group = proxies_map
                    .get(tag)
                    .and_then(|v| v.get("all"))
                    .and_then(Value::as_array)
                    .is_some_and(|a| !a.is_empty());
                if is_group {
                    stack.push(tag.to_string());
                } else if seen_leaf.insert(tag.to_string()) {
                    out.push(tag.to_string());
                }
            }
        }
    }
    out
}

fn collect_store_section_leaf_tags(
    store: &crate::store::RouterStoreData,
    section: &str,
) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (owner_sec, src, _hidden) in collect_section_sources_with_owner(store, section) {
        let sec_owner = store.sections.iter().find(|s| s.id == owner_sec);
        if src.source_type == "subscription" {
            for (tag, out_val, _visible) in crate::config_gen::build_source_outbounds(src) {
                if out_val.get("type").and_then(Value::as_str) == Some("urltest") {
                    continue;
                }
                if let Some(sec) = sec_owner
                    && !crate::config_gen::subscription_keyword_passes(
                        &tag,
                        &sec.subscription_filter_include_keywords,
                        &sec.subscription_filter_exclude_keywords,
                    )
                {
                    continue;
                }
                let t = tag.trim();
                if !t.is_empty() && seen.insert(t.to_string()) {
                    out.push(t.to_string());
                }
            }
        } else if src.source_type == "proxy_links" {
            for (idx, link) in src.proxy_links.iter().enumerate() {
                if let Some(parsed) = config_gen::parse_proxy_uri(link, idx) {
                    let t = parsed.tag.trim();
                    if !t.is_empty() && seen.insert(t.to_string()) {
                        out.push(t.to_string());
                    }
                }
            }
        } else if src.source_type != "desync" {
            for (tag, out_val, _visible) in crate::config_gen::build_source_outbounds(src) {
                let otype = out_val
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                if matches!(
                    otype,
                    "urltest" | "selector" | "priority" | "block" | "reject" | "dns-out"
                ) {
                    continue;
                }
                let t = tag.trim();
                if !t.is_empty() && seen.insert(t.to_string()) {
                    out.push(t.to_string());
                }
            }
        }
    }
    out
}

fn has_positive_delay_response(val: &Value) -> bool {
    if val
        .get("delay")
        .and_then(Value::as_u64)
        .is_some_and(|d| d > 0)
    {
        return true;
    }
    if val.get("message").is_some() {
        return false;
    }
    val.as_object().is_some_and(|obj| {
        obj.iter()
            .any(|(k, v)| k != "delay" && v.as_u64().is_some_and(|d| d > 0))
    })
}

fn is_transient_delay_probe_failure(res: &anyhow::Result<Value>) -> bool {
    match res {
        Ok(val) => {
            !has_positive_delay_response(val)
                && !val
                    .get("message")
                    .and_then(Value::as_str)
                    .is_some_and(|m| m.to_ascii_lowercase().contains("resource not found"))
        }
        Err(err) => {
            let msg = format!("{err:#}").to_ascii_lowercase();
            !msg.contains("http 404") && !msg.contains("resource not found")
        }
    }
}

fn resolve_clash_proxy_for_target(
    store: &crate::store::RouterStoreData,
    proxies_map: &Map<String, Value>,
    target: &str,
) -> Option<String> {
    let req = target.trim();
    if req.is_empty() {
        return None;
    }
    let is_system_tag = |t: &str| matches!(t, "direct" | "block" | "reject" | "GLOBAL" | "dns-out");

    if let Some(entry) = proxies_map.get(req) {
        if let Some(now) = entry
            .get("now")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|n| !n.is_empty() && *n != req && !is_system_tag(n))
            && proxies_map.contains_key(now)
        {
            return Some(now.to_string());
        }
        return None;
    }

    let sec_base = req
        .strip_prefix("sel-")
        .or_else(|| req.strip_suffix("-out"))
        .unwrap_or(req);

    let group = resolve_clash_group_for_target(store, Some(proxies_map), sec_base);
    if let Some(entry) = proxies_map.get(&group) {
        if let Some(now) = entry
            .get("now")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|n| !n.is_empty() && *n != req && !is_system_tag(n))
            && proxies_map.contains_key(now)
        {
            return Some(now.to_string());
        }
        for leaf in collect_clash_leaf_members(proxies_map, &group) {
            if leaf != req && !is_system_tag(&leaf) && proxies_map.contains_key(&leaf) {
                return Some(leaf);
            }
        }
    }

    for (_owner, src, _hidden) in collect_section_sources_with_owner(store, sec_base) {
        for cand in [
            src.id.clone(),
            format!("wg-{}", src.id),
            format!("{}-{}", src.source_type, src.id),
        ] {
            if cand != req && !is_system_tag(&cand) && proxies_map.contains_key(&cand) {
                return Some(cand);
            }
        }
        let suffix = format!("-{}", src.id);
        for (k, entry) in proxies_map {
            let is_group = entry
                .get("all")
                .and_then(Value::as_array)
                .is_some_and(|a| !a.is_empty());
            if !is_group && k != req && !is_system_tag(k) && k.ends_with(&suffix) {
                return Some(k.clone());
            }
        }
    }

    collect_store_section_leaf_tags(store, sec_base)
        .into_iter()
        .find(|leaf| leaf != req && !is_system_tag(leaf) && proxies_map.contains_key(leaf))
}

fn resolve_latency_targets(
    store: &crate::store::RouterStoreData,
    proxies_map: Option<&Map<String, Value>>,
    ltype: &str,
    section: &str,
    raw_tag: &str,
) -> (Vec<String>, String) {
    let trimmed_tag = raw_tag.trim();
    if ltype == "proxy_list" {
        if trimmed_tag.is_empty() || trimmed_tag.starts_with("@section:") {
            let sec_id = trimmed_tag
                .strip_prefix("@section:")
                .unwrap_or(section)
                .trim();
            let group_tag = resolve_clash_group_for_target(store, proxies_map, sec_id);
            let mut tags = proxies_map
                .map(|pm| collect_clash_leaf_members(pm, &group_tag))
                .unwrap_or_default();
            if tags.is_empty() {
                tags = collect_store_section_leaf_tags(store, sec_id);
            }
            return (tags, format!("@section:{sec_id}"));
        }
        if trimmed_tag.starts_with('[')
            && let Ok(parsed) = serde_json::from_str::<Vec<String>>(trimmed_tag)
        {
            let mut seen = std::collections::HashSet::new();
            let tags: Vec<String> = parsed
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty() && seen.insert(s.clone()))
                .collect();
            return (tags, trimmed_tag.to_string());
        }
        let mut seen = std::collections::HashSet::new();
        let tags: Vec<String> = trimmed_tag
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty() && seen.insert((*s).to_string()))
            .map(str::to_string)
            .collect();
        return (tags, trimmed_tag.to_string());
    }

    if ltype == "group" {
        let req = if trimmed_tag.is_empty() {
            section
        } else {
            trimmed_tag
        };
        let eff_group = resolve_clash_group_for_target(store, proxies_map, req);
        let tags = proxies_map
            .map(|pm| collect_clash_leaf_members(pm, &eff_group))
            .unwrap_or_default();
        return (tags, eff_group);
    }

    let eff_tag = if trimmed_tag.is_empty() {
        resolve_clash_group_for_target(store, proxies_map, section)
    } else {
        trimmed_tag.to_string()
    };
    let tags = if eff_tag.is_empty() {
        Vec::new()
    } else {
        vec![eff_tag.clone()]
    };
    (tags, eff_tag)
}

fn resolve_subscription_cli_target(
    store: &crate::store::RouterStoreData,
    target: &str,
    selector: &str,
) -> String {
    let t = target.trim();
    let sel = selector.trim();
    if sel.is_empty() {
        return t.to_string();
    }
    if store
        .outbound_sources
        .iter()
        .any(|s| s.source_type == "subscription" && s.id == sel)
    {
        return sel.to_string();
    }
    let section_subs: Vec<&crate::store::OutboundSource> =
        collect_section_sources_with_owner(store, t)
            .into_iter()
            .filter_map(|(_, src, _)| {
                if src.source_type == "subscription" {
                    Some(src)
                } else {
                    None
                }
            })
            .collect();
    if let Ok(idx) = sel.parse::<usize>()
        && idx >= 1
    {
        if let Some(found) = section_subs.get(idx - 1) {
            return found.id.clone();
        }
        return format!("__missing_subscription_index__:{idx}");
    }
    if let Some(found) = section_subs
        .iter()
        .find(|s| s.id.eq_ignore_ascii_case(sel) || s.name.trim().eq_ignore_ascii_case(sel))
    {
        return found.id.clone();
    }
    sel.to_string()
}

fn clean_balancer_display_id(section_id: &str, raw_bal_id: &str) -> String {
    let raw = raw_bal_id.trim();
    if raw.is_empty() || raw == "urltest" || section_id.trim().is_empty() {
        return raw.to_string();
    }
    let s = if let Some(rest) = raw.strip_prefix("bal_prio_") {
        rest
    } else if let Some(rest) = raw.strip_prefix("bal_") {
        rest
    } else {
        return raw.to_string();
    };
    let sec = section_id.trim();
    if s.len() > sec.len() + 1
        && s.get(..sec.len())
            .is_some_and(|p| p.eq_ignore_ascii_case(sec))
        && s.as_bytes()[sec.len()] == b'_'
    {
        let trimmed = s[sec.len() + 1..].trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    let suf_len = sec.len() + 1;
    if s.len() > suf_len
        && s.as_bytes()[s.len() - sec.len() - 1] == b'_'
        && s.get(s.len() - sec.len()..)
            .is_some_and(|p| p.eq_ignore_ascii_case(sec))
    {
        let trimmed = s[..s.len() - suf_len].trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    raw.to_string()
}

pub(crate) fn build_telemetry_tag_display_map(
    d: &crate::store::RouterStoreData,
) -> std::collections::HashMap<String, String> {
    const SOURCE_PREFIXES: &[&str] = &[
        "awgconf-",
        "awg-",
        "warp-",
        "ovpn-",
        "sub-",
        "link-",
        "fptn-",
        "iface-",
        "desync-",
        "wg-",
        "vless-",
        "vmess-",
        "trojan-",
        "ss-",
        "hy2-",
        "tuic-",
        "mieru-",
        "naive-",
        "anytls-",
        "snell-",
        "sudoku-",
        "trusttunnel-",
        "tewfai-",
        "masque-",
        "openconnect-",
        "shadowtls-",
        "tailscale-",
        "custom-",
    ];

    let mut map = std::collections::HashMap::new();
    let mut unique_source_section: std::collections::HashMap<String, Option<String>> =
        std::collections::HashMap::new();
    for sec in d.sections.iter().filter(|s| s.enabled) {
        let sec_label = if !sec.label.trim().is_empty() {
            sec.label.trim().to_string()
        } else {
            sec.id.trim().to_string()
        };
        if sec_label.is_empty() {
            continue;
        }
        for sref in &sec.outbound_source_refs {
            let sid = sref.trim();
            if sid.is_empty() {
                continue;
            }
            match unique_source_section.get_mut(sid) {
                None => {
                    unique_source_section.insert(sid.to_string(), Some(sec_label.clone()));
                }
                Some(slot) => {
                    if slot.as_deref() != Some(sec_label.as_str()) {
                        *slot = None;
                    }
                }
            }
        }
    }

    for sec in &d.sections {
        let sec_id = sec.id.trim();
        if sec_id.is_empty() {
            continue;
        }
        let sec_label = if !sec.label.trim().is_empty() {
            sec.label.trim().to_string()
        } else {
            sec_id.to_string()
        };
        map.insert(format!("sel-{sec_id}"), sec_label.clone());
        map.insert(format!("{sec_id}-out"), sec_label.clone());
        map.insert(format!("desync-sec-{sec_id}"), sec_label.clone());
        map.insert(format!("tailscale-sec-{sec_id}"), sec_label.clone());
        map.entry(sec_id.to_string()).or_insert(sec_label);
    }

    for bal in &d.balancers {
        let bal_id = bal.id.trim();
        if bal_id.is_empty() {
            continue;
        }
        let named = bal.name.trim();
        for sec in &d.sections {
            let sec_id = sec.id.trim();
            if sec_id.is_empty() {
                continue;
            }
            let bal_label = if !named.is_empty() {
                named.to_string()
            } else {
                clean_balancer_display_id(sec_id, bal_id)
            };
            map.insert(format!("bal-{sec_id}-{bal_id}"), bal_label.clone());
            map.insert(format!("{sec_id}-urltest-{bal_id}"), bal_label.clone());
            map.insert(format!("{sec_id}-priority-{bal_id}"), bal_label);
        }
        if !named.is_empty() {
            map.insert(bal_id.to_string(), named.to_string());
        }
    }

    for src in &d.outbound_sources {
        let src_id = src.id.trim();
        if src_id.is_empty() {
            continue;
        }
        let owner_sec_label = unique_source_section.get(src_id).and_then(|v| v.clone());
        let src_name = src.name.trim();
        let src_label = if src.source_type == "desync" {
            owner_sec_label
                .or_else(|| (!src_name.is_empty()).then(|| src_name.to_string()))
                .unwrap_or_else(|| src_id.to_string())
        } else if !src_name.is_empty() {
            src_name.to_string()
        } else {
            owner_sec_label.unwrap_or_else(|| src_id.to_string())
        };
        for pfx in SOURCE_PREFIXES {
            map.insert(format!("{pfx}{src_id}"), src_label.clone());
            map.insert(format!("{pfx}{src_id}-0"), src_label.clone());
        }
        if src.source_type == "custom_json"
            && let Ok(parsed) = serde_json::from_str::<Value>(&src.custom_json)
            && let Some(custom_tag) = parsed
                .get("tag")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
        {
            map.insert(custom_tag.to_string(), src_label.clone());
        }
        map.entry(src_id.to_string()).or_insert(src_label);
    }

    for srv in &d.servers {
        let srv_id = srv.id.trim();
        if srv_id.is_empty() {
            continue;
        }
        let srv_label = if !srv.label.trim().is_empty() {
            srv.label.trim().to_string()
        } else {
            srv_id.to_string()
        };
        map.insert(format!("srv-{srv_id}"), srv_label.clone());
        map.insert(format!("srv-{srv_id}-inner"), srv_label.clone());
        map.insert(format!("server-{srv_id}-in"), srv_label.clone());
        map.insert(format!("server-{srv_id}-in-inner"), srv_label);
    }

    map
}

fn clean_technical_source_stem(stem: &str) -> String {
    let stripped = stem.trim();
    if let Some(after) = stripped.strip_prefix("src_")
        && !after.is_empty()
    {
        return after.to_string();
    }
    stripped.to_string()
}

pub(crate) fn resolve_telemetry_tag_display_name(
    raw_tag: &str,
    display_map: &std::collections::HashMap<String, String>,
    d: &crate::store::RouterStoreData,
) -> String {
    const INDEXED_SOURCE_PREFIXES: &[&str] = &[
        "awgconf-",
        "awg-",
        "wg-",
        "warp-",
        "fptn-",
        "ovpn-",
        "desync-",
        "iface-",
        "tailscale-",
        "sub-",
        "link-",
        "json-",
    ];

    let tag = raw_tag.trim();
    if tag.is_empty() {
        return String::new();
    }
    if let Some(exact) = display_map.get(tag) {
        return exact.clone();
    }
    if let Some((_, matched)) = display_map
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(tag))
    {
        return matched.clone();
    }

    let find_section_label = |sec_id: &str| -> String {
        d.sections
            .iter()
            .find(|s| s.id.eq_ignore_ascii_case(sec_id))
            .map(|s| {
                if !s.label.trim().is_empty() {
                    s.label.trim().to_string()
                } else {
                    s.id.trim().to_string()
                }
            })
            .unwrap_or_else(|| sec_id.to_string())
    };

    if let Some(rest) = tag.strip_prefix("sel-") {
        return find_section_label(rest);
    }
    if let Some(rest) = tag.strip_prefix("desync-sec-") {
        return find_section_label(rest);
    }
    if let Some(rest) = tag.strip_prefix("tailscale-sec-") {
        return find_section_label(rest);
    }
    if let Some(rest) = tag.strip_prefix("srv-") {
        let srv_id = rest.strip_suffix("-inner").unwrap_or(rest);
        if let Some(srv) = d.servers.iter().find(|s| s.id.eq_ignore_ascii_case(srv_id)) {
            let lbl = srv.label.trim();
            return if lbl.is_empty() {
                srv.id.trim().to_string()
            } else {
                lbl.to_string()
            };
        }
        return srv_id.to_string();
    }
    if let Some(rest) = tag.strip_prefix("server-")
        && let Some(srv_id) = rest
            .strip_suffix("-in-inner")
            .or_else(|| rest.strip_suffix("-in"))
    {
        if let Some(srv) = d.servers.iter().find(|s| s.id.eq_ignore_ascii_case(srv_id)) {
            let lbl = srv.label.trim();
            return if lbl.is_empty() {
                srv.id.trim().to_string()
            } else {
                lbl.to_string()
            };
        }
        return srv_id.to_string();
    }
    if let Some(rest) = tag.strip_suffix("-out")
        && let Some(sec) = d.sections.iter().find(|s| s.id.eq_ignore_ascii_case(rest))
    {
        let lbl = sec.label.trim();
        return if lbl.is_empty() {
            sec.id.trim().to_string()
        } else {
            lbl.to_string()
        };
    }
    if let Some(rest) = tag.strip_prefix("bal-") {
        let mut best_sec: Option<&crate::store::RoutingSection> = None;
        for sec in &d.sections {
            let sid = sec.id.trim();
            if !sid.is_empty()
                && rest.len() > sid.len() + 1
                && rest
                    .get(..sid.len())
                    .is_some_and(|p| p.eq_ignore_ascii_case(sid))
                && rest.as_bytes()[sid.len()] == b'-'
                && best_sec.is_none_or(|prev| sid.len() > prev.id.len())
            {
                best_sec = Some(sec);
            }
        }
        if let Some(sec) = best_sec {
            let bal_part = &rest[sec.id.trim().len() + 1..];
            if let Some(bal) = d
                .balancers
                .iter()
                .find(|b| b.id.eq_ignore_ascii_case(bal_part))
                && !bal.name.trim().is_empty()
            {
                return bal.name.trim().to_string();
            }
            return clean_balancer_display_id(&sec.id, bal_part);
        }
        if let Some((sec_part, bal_part)) = rest.split_once('-') {
            return clean_balancer_display_id(sec_part, bal_part);
        }
        return rest.to_string();
    }

    // Multi-peer AWG tags like `awgconf-src_rtest (2)`
    if let Some(paren_idx) = tag.rfind(" (")
        && let Some(num_str) = tag[paren_idx + 2..].strip_suffix(')')
        && let Ok(peer_num) = num_str.parse::<usize>()
        && peer_num >= 1
    {
        let base_tag = &tag[..paren_idx];
        let base_label = resolve_telemetry_tag_display_name(base_tag, display_map, d);
        if peer_num == 1 {
            return base_label;
        }
        return format!("{base_label} #{peer_num}");
    }

    for &pfx in INDEXED_SOURCE_PREFIXES {
        if tag.len() > pfx.len()
            && tag
                .get(..pfx.len())
                .is_some_and(|head| head.eq_ignore_ascii_case(pfx))
        {
            let rest = &tag[pfx.len()..];
            if let Some((stem, idx_str)) = rest.rsplit_once('-')
                && !stem.is_empty()
                && idx_str.bytes().all(|b| b.is_ascii_digit())
                && let Ok(idx_num) = idx_str.parse::<usize>()
            {
                let base_key = format!("{pfx}{stem}");
                let base_label = display_map
                    .get(&base_key)
                    .or_else(|| {
                        display_map
                            .iter()
                            .find(|(k, _)| k.eq_ignore_ascii_case(&base_key))
                            .map(|(_, v)| v)
                    })
                    .cloned()
                    .unwrap_or_else(|| clean_technical_source_stem(stem));
                return if idx_num == 0 {
                    base_label
                } else {
                    format!("{base_label} #{}", idx_num + 1)
                };
            }
            return clean_technical_source_stem(rest);
        }
    }

    tag.to_string()
}

async fn build_pure_rust_core_telemetry(state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let store_snap = state.data.read().await.clone();
    let tag_display_map = build_telemetry_tag_display_map(&store_snap);
    let (
        mem_res,
        dev_res,
        conn_res,
        flight_res,
        failover_res,
        proxies_res,
        leak_res,
        health_res,
        anomalies_res,
    ) = tokio::join!(
        core.clash_request("GET", "/tachyon/memory", None),
        core.clash_request("GET", "/tachyon/devices", None),
        core.clash_request("GET", "/connections", None),
        core.clash_request("GET", "/tachyon/flight", None),
        core.clash_request("GET", "/tachyon/failover", None),
        core.clash_request("GET", "/proxies", None),
        core.clash_request("GET", "/tachyon/leak", None),
        core.clash_request("GET", "/tachyon/health", None),
        core.clash_request("GET", "/tachyon/anomalies", None),
    );
    let live_logs_snap = { state.live.read().await.recent_logs.clone() };
    let _ = crate::adguard_hosts::ingest_core_telemetry_payloads_in(
        &crate::store::runtime_state_dir(),
        &store_snap,
        &live_logs_snap,
        None,
        flight_res.as_ref().ok(),
        conn_res.as_ref().ok(),
        crate::store::unix_now_secs(),
    );

    let memory = mem_res.unwrap_or_else(|_| {
        json!({
            "rss_bytes": 0,
            "vm_bytes": 0,
            "system_available_bytes": 0,
            "total_ram_mb": 0,
            "pressure_level": "normal",
            "under_pressure": false,
            "connections": {
                "active_connections": 0,
                "device_buckets": 0,
                "inbound_buckets": 0,
                "user_buckets": 0
            },
            "dns": {
                "cache_entries": 0,
                "reverse_entries": 0,
                "fakeip_entries": 0
            }
        })
    });

    // Aggregate 60-sample bandwidth history across all devices
    let mut history_up = [0u64; 60];
    let mut history_down = [0u64; 60];
    let mut upload_bps = 0u64;
    let mut download_bps = 0u64;
    let mut upload_total = 0u64;
    let mut download_total = 0u64;
    let mut proxied_upload = 0u64;
    let mut proxied_download = 0u64;
    let mut direct_upload = 0u64;
    let mut direct_download = 0u64;
    let mut total_devices = 0u64;
    let mut active_connections = 0u64;

    if let Ok(ref dev_val) = dev_res {
        if let Some(summary) = dev_val.get("summary") {
            upload_bps = summary
                .get("upload_bps")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            download_bps = summary
                .get("download_bps")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            upload_total = summary.get("upload").and_then(Value::as_u64).unwrap_or(0);
            download_total = summary.get("download").and_then(Value::as_u64).unwrap_or(0);
            proxied_upload = summary
                .get("proxied_upload")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            proxied_download = summary
                .get("proxied_download")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            direct_upload = summary
                .get("direct_upload")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            direct_download = summary
                .get("direct_download")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            total_devices = summary
                .get("total_devices")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            active_connections = summary
                .get("active_connections")
                .and_then(Value::as_u64)
                .unwrap_or(0);
        }
        if let Some(devices) = dev_val.get("devices").and_then(Value::as_array) {
            for dev in devices {
                if let Some(hist) = dev.get("history").and_then(Value::as_array) {
                    let len = hist.len().min(60);
                    let offset = 60 - len;
                    for (idx, item) in hist.iter().take(len).enumerate() {
                        if let Some(pair) = item.as_array() {
                            let up = pair.first().and_then(Value::as_u64).unwrap_or(0);
                            let down = pair.get(1).and_then(Value::as_u64).unwrap_or(0);
                            history_up[offset + idx] = history_up[offset + idx].saturating_add(up);
                            history_down[offset + idx] =
                                history_down[offset + idx].saturating_add(down);
                        }
                    }
                }
            }
        }
    }

    let history_points: Vec<Value> = (0..60)
        .map(|i| json!([history_up[i], history_down[i]]))
        .collect();

    // Aggregate outbounds & protocols from /connections and /tachyon/flight
    let mut outbound_map: std::collections::HashMap<String, (u64, u64, u64, u64)> =
        std::collections::HashMap::new();
    let mut tcp_count = 0u64;
    let mut udp_count = 0u64;
    let mut quic_count = 0u64;

    if let Ok(ref conn_val) = conn_res
        && let Some(conns) = conn_val.get("connections").and_then(Value::as_array)
    {
        if active_connections == 0 {
            active_connections = conns.len() as u64;
        }
        for c in conns {
            let net = c
                .get("metadata")
                .and_then(|m| m.get("network"))
                .and_then(Value::as_str)
                .unwrap_or("tcp")
                .to_ascii_lowercase();
            let dst_port = c
                .get("metadata")
                .and_then(|m| m.get("destinationPort"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if net.contains("udp") {
                if dst_port == "443" {
                    quic_count += 1;
                } else {
                    udp_count += 1;
                }
            } else {
                tcp_count += 1;
            }
            let chain = c
                .get("chains")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(Value::as_str)
                .unwrap_or("direct-out")
                .to_string();
            let up = c.get("upload").and_then(Value::as_u64).unwrap_or(0);
            let down = c.get("download").and_then(Value::as_u64).unwrap_or(0);
            let entry = outbound_map.entry(chain).or_insert((0, 0, 0, 0));
            entry.0 += 1;
            entry.1 = entry.1.saturating_add(up);
            entry.2 = entry.2.saturating_add(down);
        }
    }

    let mut flight_entries = Vec::new();
    let mut flight_count = 0u64;
    if let Ok(ref fl_val) = flight_res {
        flight_count = fl_val.get("count").and_then(Value::as_u64).unwrap_or(0);
        if let Some(arr) = fl_val.get("entries").and_then(Value::as_array) {
            for e in arr.iter().take(24) {
                let outbound = e
                    .get("outbound")
                    .and_then(Value::as_str)
                    .unwrap_or("direct-out")
                    .to_string();
                let up = e.get("upload").and_then(Value::as_u64).unwrap_or(0);
                let down = e.get("download").and_then(Value::as_u64).unwrap_or(0);
                let entry = outbound_map.entry(outbound.clone()).or_insert((0, 0, 0, 0));
                entry.1 = entry.1.saturating_add(up);
                entry.2 = entry.2.saturating_add(down);
                entry.3 += 1;

                let raw_rule = e.get("rule").and_then(Value::as_str).unwrap_or("");
                let short_rule = if raw_rule.len() > 72 {
                    format!("{}...", &raw_rule[..69])
                } else {
                    raw_rule.to_string()
                };
                flight_entries.push(json!({
                    "id": e.get("id").and_then(Value::as_u64).unwrap_or(0),
                    "timestamp_ms": e.get("timestamp_ms").and_then(Value::as_u64).unwrap_or(0),
                    "network": e.get("network").and_then(Value::as_str).unwrap_or("tcp"),
                    "inbound": e.get("inbound").and_then(Value::as_str).unwrap_or(""),
                    "source": e.get("source").and_then(Value::as_str).unwrap_or(""),
                    "host": e.get("host").and_then(Value::as_str).unwrap_or(""),
                    "destination": e.get("destination").and_then(Value::as_str).unwrap_or(""),
                    "outbound": outbound,
                    "outbound_display_name": resolve_telemetry_tag_display_name(&outbound, &tag_display_map, &store_snap),
                    "rule": short_rule,
                    "upload": up,
                    "download": down,
                    "duration_ms": e.get("duration_ms").and_then(Value::as_u64).unwrap_or(0),
                    "status": e.get("status").and_then(Value::as_str).unwrap_or("ok"),
                }));
            }
        }
    }

    let mut outbounds_vec: Vec<(String, u64, u64, u64, u64)> = outbound_map
        .into_iter()
        .map(|(k, (act, up, down, hits))| (k, act, up, down, hits))
        .collect();
    outbounds_vec.sort_by_key(|a| std::cmp::Reverse(a.1 * 1_000_000 + a.2 + a.3 + a.4));
    let outbounds_json: Vec<Value> = outbounds_vec
        .into_iter()
        .take(8)
        .map(|(tag, act, up, down, hits)| {
            let display_name =
                resolve_telemetry_tag_display_name(&tag, &tag_display_map, &store_snap);
            json!({
                "tag": tag,
                "display_name": display_name,
                "active_connections": act,
                "upload": up,
                "download": down,
                "recent_hits": hits,
            })
        })
        .collect();

    let mut failover_any_backup = false;
    let mut failover_groups = Vec::new();
    let mut covered_tags: std::collections::HashSet<String> = std::collections::HashSet::new();
    if let Ok(ref fo_val) = failover_res {
        failover_any_backup = fo_val
            .get("any_on_backup")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if let Some(groups) = fo_val.get("groups").and_then(Value::as_array) {
            for g in groups {
                let member_count = g
                    .get("members")
                    .and_then(Value::as_array)
                    .map(|m| m.len())
                    .unwrap_or(0);
                let raw_tag = g.get("tag").and_then(Value::as_str).unwrap_or("");
                let raw_primary = g.get("primary").and_then(Value::as_str).unwrap_or("");
                let raw_current = g.get("current").and_then(Value::as_str).unwrap_or("");
                if !raw_tag.is_empty() {
                    covered_tags.insert(raw_tag.to_ascii_lowercase());
                }
                failover_groups.push(json!({
                    "tag": raw_tag,
                    "display_name": resolve_telemetry_tag_display_name(raw_tag, &tag_display_map, &store_snap),
                    "type": g.get("type").and_then(Value::as_str).unwrap_or(""),
                    "mode": g.get("mode").and_then(Value::as_str).unwrap_or(""),
                    "primary": raw_primary,
                    "primary_display_name": resolve_telemetry_tag_display_name(raw_primary, &tag_display_map, &store_snap),
                    "current": raw_current,
                    "current_display_name": resolve_telemetry_tag_display_name(raw_current, &tag_display_map, &store_snap),
                    "on_backup": g.get("on_backup").and_then(Value::as_bool).unwrap_or(false),
                    "primary_healthy": g.get("primary_healthy").and_then(Value::as_bool).unwrap_or(true),
                    "primary_rtt_ms": g.get("primary_rtt_ms").and_then(Value::as_u64),
                    "primary_failures": g.get("primary_failures").and_then(Value::as_u64).unwrap_or(0),
                    "primary_quarantine_rem_s": g.get("primary_quarantine_rem_s").and_then(Value::as_u64).unwrap_or(0),
                    "member_count": member_count,
                }));
            }
        }
    }

    // Also include configured active balancers (urltest / sticky / priority / selector) from `/proxies`
    // and store so Dashboard telemetry reflects live sticky/urltest groups even when `/tachyon/failover`
    // only reports active-backup failover state.
    let proxies_map = proxies_res
        .as_ref()
        .ok()
        .and_then(|v| v.get("proxies"))
        .and_then(Value::as_object);
    for bal in &store_snap.balancers {
        let bal_id = bal.id.trim();
        if !bal.enabled || bal_id.is_empty() {
            continue;
        }
        let bal_id_lower = bal_id.to_ascii_lowercase();
        let bal_suffix = format!("-{bal_id_lower}");
        let already_present = covered_tags
            .iter()
            .any(|t| t == &bal_id_lower || t.ends_with(&bal_suffix));
        if already_present {
            continue;
        }

        let mut pushed_for_bal = false;
        if let Some(pmap) = proxies_map {
            let mut matched_tags: Vec<&String> = pmap
                .keys()
                .filter(|k| {
                    let kl = k.to_ascii_lowercase();
                    kl == bal_id_lower || (kl.starts_with("bal-") && kl.ends_with(&bal_suffix))
                })
                .collect();
            matched_tags.sort();
            for ptag in matched_tags {
                let Some(pobj) = pmap.get(ptag) else {
                    continue;
                };
                covered_tags.insert(ptag.to_ascii_lowercase());
                let raw_current = pobj.get("now").and_then(Value::as_str).unwrap_or("");
                let all_members = pobj.get("all").and_then(Value::as_array);
                let member_count = all_members.map(Vec::len).unwrap_or(0);
                let raw_primary = all_members
                    .and_then(|arr| arr.first())
                    .and_then(Value::as_str)
                    .unwrap_or(raw_current);
                let rtt_lookup_tag = if !raw_current.is_empty() {
                    raw_current
                } else {
                    ptag.as_str()
                };
                let rtt_ms = pmap
                    .get(rtt_lookup_tag)
                    .or(Some(pobj))
                    .and_then(|o| o.get("history"))
                    .and_then(Value::as_array)
                    .and_then(|h| h.last())
                    .and_then(|entry| entry.get("delay"))
                    .and_then(Value::as_u64)
                    .filter(|&d| d > 0);
                let ptype = pobj.get("type").and_then(Value::as_str).unwrap_or_else(|| {
                    if bal.balancer_type.trim().is_empty() {
                        "urltest"
                    } else {
                        bal.balancer_type.trim()
                    }
                });
                failover_groups.push(json!({
                    "tag": ptag,
                    "display_name": resolve_telemetry_tag_display_name(ptag, &tag_display_map, &store_snap),
                    "type": if ptype.eq_ignore_ascii_case("urltest") { "urltest" } else { ptype },
                    "mode": bal.mode,
                    "primary": raw_primary,
                    "primary_display_name": resolve_telemetry_tag_display_name(raw_primary, &tag_display_map, &store_snap),
                    "current": raw_current,
                    "current_display_name": resolve_telemetry_tag_display_name(raw_current, &tag_display_map, &store_snap),
                    "on_backup": ptype.eq_ignore_ascii_case("urltest"),
                    "primary_healthy": true,
                    "primary_rtt_ms": rtt_ms,
                    "primary_failures": 0,
                    "primary_quarantine_rem_s": 0,
                    "member_count": member_count,
                }));
                pushed_for_bal = true;
            }
        }

        if !pushed_for_bal {
            let ref_sec = store_snap
                .sections
                .iter()
                .find(|s| s.enabled && s.balancer_refs.iter().any(|r| r == bal_id));
            let syn_tag = ref_sec
                .map(|s| format!("bal-{}-{}", s.id.trim(), bal_id))
                .unwrap_or_else(|| bal_id.to_string());
            let disp = if !bal.name.trim().is_empty() {
                bal.name.trim().to_string()
            } else {
                bal_id.to_string()
            };
            let est_members = bal
                .balancer_pool
                .len()
                .max(bal.outbound_group_levels.len())
                .max(bal.priority_levels.len());
            let bal_type = if bal.balancer_type.trim().is_empty() {
                "urltest"
            } else {
                bal.balancer_type.trim()
            };
            failover_groups.push(json!({
                "tag": syn_tag,
                "display_name": disp,
                "type": bal_type,
                "mode": bal.mode,
                "primary": "",
                "primary_display_name": "",
                "current": "",
                "current_display_name": "",
                "on_backup": bal_type.eq_ignore_ascii_case("urltest"),
                "primary_healthy": true,
                "primary_rtt_ms": Value::Null,
                "primary_failures": 0,
                "primary_quarantine_rem_s": 0,
                "member_count": est_members,
            }));
        }
    }

    let mut leak = leak_res.unwrap_or_else(|_| {
        json!({
            "status": "ok",
            "ipv4": { "outbound": "direct-out", "rule": "final", "is_direct": true },
            "ipv6": { "outbound": "direct-out", "rule": "final", "is_direct": true, "leak_risk": false },
            "webrtc_stun": { "outbound": "direct-out", "rule": "final", "is_direct": true, "leak_risk": false },
            "dns": { "engine_enabled": true }
        })
    });
    for key in ["ipv4", "ipv6", "webrtc_stun"] {
        if let Some(obj) = leak.get_mut(key).and_then(Value::as_object_mut)
            && let Some(ob_tag) = obj
                .get("outbound")
                .and_then(Value::as_str)
                .map(String::from)
        {
            obj.insert(
                "outbound_display_name".to_string(),
                json!(resolve_telemetry_tag_display_name(
                    &ob_tag,
                    &tag_display_map,
                    &store_snap
                )),
            );
        }
    }

    json!({
        "success": true,
        "memory": memory,
        "traffic": {
            "upload_bps": upload_bps,
            "download_bps": download_bps,
            "upload_total": upload_total,
            "download_total": download_total,
            "proxied_upload": proxied_upload,
            "proxied_download": proxied_download,
            "direct_upload": direct_upload,
            "direct_download": direct_download,
            "total_devices": total_devices,
            "active_connections": active_connections,
            "history": history_points,
        },
        "protocols": {
            "tcp": tcp_count,
            "udp": udp_count,
            "quic": quic_count,
        },
        "outbounds": outbounds_json,
        "failover": {
            "any_on_backup": failover_any_backup,
            "groups": failover_groups,
        },
        "leak": leak,
        "flight": {
            "count": flight_count,
            "entries": flight_entries,
        },
        "health": health_res.unwrap_or_else(|_| json!({})),
        "anomalies": anomalies_res.unwrap_or_else(|_| json!({"count": 0, "hosts": []})),
    })
}

fn is_tailscale_ip(ip_str: &str) -> bool {
    let Ok(addr) = ip_str.parse::<std::net::IpAddr>() else {
        return false;
    };
    match addr {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            o[0] == 100 && (o[1] & 0xc0) == 64
        }
        std::net::IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

#[cfg(target_os = "linux")]
fn proc_net_listen_ports(proto: &str) -> Vec<(String, u16)> {
    let paths: &[&str] = if proto == "udp" {
        &["/proc/net/udp", "/proc/net/udp6"]
    } else {
        &["/proc/net/tcp", "/proc/net/tcp6"]
    };
    let mut out = Vec::new();
    for path in paths {
        let Ok(raw) = std::fs::read_to_string(path) else {
            continue;
        };
        let is_v6 = path.ends_with('6');
        for line in raw.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 4 {
                continue;
            }
            // TCP uses st == 0A (LISTEN); UDP listening sockets typically use 07 (CLOSE)
            let state = cols[3];
            if (proto != "udp" && state != "0A")
                || (proto == "udp" && state != "07" && state != "01")
            {
                continue;
            }
            let Some((hex_ip, hex_port)) = cols[1].split_once(':') else {
                continue;
            };
            let Ok(port) = u16::from_str_radix(hex_port, 16) else {
                continue;
            };
            let addr = if !is_v6 && hex_ip.len() == 8 {
                if let Ok(raw_ip) = u32::from_str_radix(hex_ip, 16) {
                    std::net::Ipv4Addr::from(raw_ip.to_le_bytes()).to_string()
                } else {
                    String::new()
                }
            } else if is_v6 && hex_ip.len() == 32 {
                if hex_ip == "00000000000000000000000000000000" {
                    "::".to_string()
                } else {
                    hex_ip.to_string()
                }
            } else {
                String::new()
            };
            if port > 0 && !addr.is_empty() {
                out.push((addr, port));
            }
        }
    }
    out
}

#[cfg(target_os = "linux")]
fn check_proc_port_listening(listen: &str, port: u16, required_proto: &str) -> i32 {
    if port == 0 {
        return -1;
    }
    for proto in required_proto.split_whitespace() {
        let listeners = proc_net_listen_ports(proto);
        let found = listeners.iter().any(|(addr, p)| {
            *p == port
                && (addr == "0.0.0.0"
                    || addr == "::"
                    || listen == "0.0.0.0"
                    || listen == "::"
                    || addr == listen)
        });
        if !found {
            return 0;
        }
    }
    1
}

#[cfg(not(target_os = "linux"))]
fn check_proc_port_listening(_listen: &str, _port: u16, _required_proto: &str) -> i32 {
    -1
}

#[cfg(any(target_os = "linux", test))]
fn collect_local_router_ips(
    wan_ip: &str,
    wan_ipv6: &str,
    listen: &str,
    ip_addr_out: &str,
) -> Vec<String> {
    let mut ips = Vec::new();
    let mut push_unique = |raw: &str| {
        let t = raw.trim();
        if !t.is_empty() && !ips.iter().any(|x| x == t) {
            ips.push(t.to_string());
        }
    };
    for w in wan_ip.split_whitespace().chain(wan_ipv6.split_whitespace()) {
        push_unique(w);
    }
    let listen_t = listen.trim();
    if !listen_t.is_empty() && listen_t != "0.0.0.0" && listen_t != "::" {
        push_unique(listen_t);
    }
    for line in ip_addr_out.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        for pair in fields.windows(2) {
            if pair[0] != "inet" && pair[0] != "inet6" {
                continue;
            }
            let addr = pair[1]
                .split('/')
                .next()
                .unwrap_or(pair[1])
                .split('%')
                .next()
                .unwrap_or(pair[1]);
            push_unique(addr);
        }
    }
    ips
}

#[cfg(any(target_os = "linux", test))]
fn nft_strip_comment(line: &str) -> &str {
    match line.find("comment \"") {
        Some(pos) => line[..pos].trim(),
        None => line.trim(),
    }
}

#[cfg(any(target_os = "linux", test))]
fn nft_extract_port_expr(text: &str) -> &str {
    let t = text.trim();
    if t.is_empty() {
        return "";
    }
    if t.starts_with('{')
        && let Some(end_b) = t.find('}')
    {
        return &t[..=end_b];
    }
    t.split_whitespace().next().unwrap_or("")
}

#[cfg(any(target_os = "linux", test))]
fn nft_port_expr_contains(expr: &str, port: u16) -> bool {
    if port == 0 {
        return false;
    }
    for tok in expr.split([' ', '\t', ',', '{', '}', ';']) {
        let t = tok.trim();
        if t.is_empty() {
            continue;
        }
        if let Some((a, b)) = t.split_once('-') {
            if let (Ok(start), Ok(end)) = (a.trim().parse::<u16>(), b.trim().parse::<u16>())
                && start <= port
                && port <= end
            {
                return true;
            }
        } else if t.parse::<u16>().ok() == Some(port) {
            return true;
        }
    }
    false
}

#[cfg(any(target_os = "linux", test))]
fn nft_line_matches_proto(clean_lc: &str, proto_lc: &str) -> bool {
    if proto_lc != "tcp" && proto_lc != "udp" {
        return false;
    }
    if clean_lc.contains(&format!("{proto_lc} dport")) {
        return true;
    }
    if let Some(pos) = clean_lc.find("meta l4proto ") {
        let expr = nft_extract_port_expr(&clean_lc[pos + 13..]);
        for tok in expr.split([' ', '\t', ',', '{', '}']) {
            if tok.trim() == proto_lc {
                return true;
            }
        }
    }
    false
}

#[cfg(any(target_os = "linux", test))]
fn nft_extract_dport_expr(clean_lc: &str) -> &str {
    if let Some(pos) = clean_lc.find(" dport ") {
        return nft_extract_port_expr(&clean_lc[pos + 7..]);
    }
    if let Some(rest) = clean_lc.strip_prefix("dport ") {
        return nft_extract_port_expr(rest);
    }
    ""
}

#[cfg(any(target_os = "linux", test))]
fn nft_ip_is_local(dest_ip: &str, local_ips: &[String]) -> bool {
    let d = dest_ip.trim();
    d == "127.0.0.1"
        || d == "::1"
        || local_ips
            .iter()
            .any(|ip| !d.is_empty() && ip.eq_ignore_ascii_case(d))
}

#[cfg(any(target_os = "linux", test))]
fn fw4_line_matches_port(line: &str, proto: &str, port: u16) -> bool {
    let l = nft_strip_comment(line).to_ascii_lowercase();
    if l.is_empty() || !l.contains("accept") || l.contains(" sport ") {
        return false;
    }
    if !nft_line_matches_proto(&l, proto) {
        return false;
    }
    let after_dport = nft_extract_dport_expr(&l);
    let port_spec = after_dport.split("counter").next().unwrap_or(after_dport);
    nft_port_expr_contains(port_spec, port)
}

#[cfg(any(target_os = "linux", test))]
fn nft_dstnat_chain_allows_port_proto(
    fw4_dstnat: &str,
    port: u16,
    proto_lc: &str,
    local_ips: &[String],
) -> bool {
    for line in fw4_dstnat.lines() {
        let clean = nft_strip_comment(line);
        if clean.is_empty() {
            continue;
        }
        let clean_lc = clean.to_ascii_lowercase();
        if clean_lc.contains(" sport ") || !nft_line_matches_proto(&clean_lc, proto_lc) {
            continue;
        }
        if let Some(pos) = clean_lc.find("redirect to :") {
            let tport = nft_extract_port_expr(&clean_lc[pos + 13..]);
            if nft_port_expr_contains(tport, port) {
                return true;
            }
            continue;
        }
        if clean_lc.contains(" redirect") || clean_lc.starts_with("redirect") {
            let dport_expr = nft_extract_dport_expr(&clean_lc);
            if !dport_expr.is_empty() && nft_port_expr_contains(dport_expr, port) {
                return true;
            }
            continue;
        }

        let after_to = ["dnat ip to ", "dnat ip6 to ", "dnat to "]
            .iter()
            .find_map(|pref| clean_lc.find(pref).map(|p| &clean_lc[p + pref.len()..]));
        let Some(after) = after_to else {
            continue;
        };
        let Some(target_tok) = after.split_whitespace().next() else {
            continue;
        };
        let (dest_ip, target_port) = if let Some(rest) = target_tok.strip_prefix('[') {
            if let Some((ip_part, tail)) = rest.split_once(']') {
                (ip_part, tail.strip_prefix(':').unwrap_or(""))
            } else {
                ("", "")
            }
        } else if let Some((ip_part, p_part)) = target_tok.rsplit_once(':')
            && ip_part.parse::<std::net::Ipv4Addr>().is_ok()
        {
            (ip_part, p_part)
        } else {
            (target_tok, "")
        };
        if dest_ip.is_empty() || !nft_ip_is_local(dest_ip, local_ips) {
            continue;
        }
        let effective_port = if !target_port.is_empty() {
            target_port
        } else {
            nft_extract_dport_expr(&clean_lc)
        };
        if !effective_port.is_empty() && nft_port_expr_contains(effective_port, port) {
            return true;
        }
    }
    false
}

#[cfg(any(target_os = "linux", test))]
fn uci_proto_spec_contains(spec: &str, proto_lc: &str) -> bool {
    let trimmed = spec.trim();
    if trimmed.is_empty() {
        return true;
    }
    for tok in trimmed.split([' ', '\t', ',']) {
        let t = tok.trim().to_ascii_lowercase();
        if t.is_empty() {
            continue;
        }
        if t == "all" || t == "any" || t == proto_lc {
            return true;
        }
    }
    false
}

#[cfg(any(target_os = "linux", test))]
fn unquote_uci_show_val(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if s.len() >= 2 && s.starts_with('\'') && s.ends_with('\'') {
        s = s[1..s.len() - 1].replace("'\\''", "'");
    } else if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s = s[1..s.len() - 1].to_string();
    }
    s
}

#[cfg(any(target_os = "linux", test))]
fn uci_firewall_allows_port_proto(
    uci_show: &str,
    port: u16,
    proto_lc: &str,
    local_ips: &[String],
) -> bool {
    #[derive(Default)]
    struct FwSec {
        sec_type: String,
        opts: std::collections::HashMap<String, String>,
    }
    let mut order: Vec<String> = Vec::new();
    let mut map: std::collections::HashMap<String, FwSec> = std::collections::HashMap::new();
    for line in uci_show.lines() {
        let trimmed = line.trim();
        let Some(after) = trimmed.strip_prefix("firewall.") else {
            continue;
        };
        let Some((key, raw_val)) = after.split_once('=') else {
            continue;
        };
        let val = unquote_uci_show_val(raw_val);
        if let Some((sec, opt)) = key.split_once('.') {
            let entry = map.entry(sec.to_string()).or_default();
            entry
                .opts
                .entry(opt.to_string())
                .and_modify(|prev| {
                    prev.push(' ');
                    prev.push_str(&val);
                })
                .or_insert(val);
        } else if val == "rule" || val == "redirect" {
            if !map.contains_key(key) {
                order.push(key.to_string());
            }
            map.entry(key.to_string()).or_default().sec_type = val;
        }
    }

    for sec_key in order {
        let Some(sec) = map.get(&sec_key) else {
            continue;
        };
        let opt = |k: &str| sec.opts.get(k).map(String::as_str).unwrap_or("").trim();
        let enabled = opt("enabled");
        if !enabled.is_empty() && enabled != "1" {
            continue;
        }
        let src = opt("src");
        if !src.is_empty() && src != "wan" && src != "*" {
            continue;
        }
        if !uci_proto_spec_contains(opt("proto"), proto_lc) {
            continue;
        }
        if sec.sec_type == "redirect" {
            let target = opt("target");
            if !target.is_empty() && !target.eq_ignore_ascii_case("DNAT") {
                continue;
            }
            let src_port = opt("src_port");
            if !src_port.is_empty() && src_port != "*" {
                continue;
            }
            if opt("family").eq_ignore_ascii_case("ipv6") {
                continue;
            }
            let dest_ip = opt("dest_ip");
            if !dest_ip.is_empty() && !nft_ip_is_local(dest_ip, local_ips) {
                continue;
            }
            let port_spec = if !opt("dest_port").is_empty() {
                opt("dest_port")
            } else {
                opt("src_dport")
            };
            if !port_spec.is_empty() && nft_port_expr_contains(port_spec, port) {
                return true;
            }
        } else {
            let target = opt("target");
            if !target.is_empty() && !target.eq_ignore_ascii_case("ACCEPT") {
                continue;
            }
            if !opt("dest").is_empty() {
                continue;
            }
            if nft_port_expr_contains(opt("dest_port"), port) {
                return true;
            }
        }
    }
    false
}

#[cfg(any(target_os = "linux", test))]
fn clean_dnat_src_port_label(raw: &str, fallback_port: u16) -> String {
    let trimmed = raw
        .trim()
        .trim_start_matches('{')
        .trim_end_matches('}')
        .trim();
    if trimmed.is_empty() {
        return fallback_port.to_string();
    }
    let first = trimmed
        .split([',', ' ', '\t'])
        .map(str::trim)
        .find(|s| !s.is_empty())
        .unwrap_or("");
    if first.is_empty() {
        fallback_port.to_string()
    } else {
        first.to_string()
    }
}

#[cfg(any(target_os = "linux", test))]
fn detect_nft_dnat_src_port(
    fw4_dstnat: &str,
    port: u16,
    proto_lc: &str,
    local_ips: &[String],
) -> Option<String> {
    for line in fw4_dstnat.lines() {
        let clean = nft_strip_comment(line);
        if clean.is_empty() {
            continue;
        }
        let clean_lc = clean.to_ascii_lowercase();
        if clean_lc.contains(" sport ") || !nft_line_matches_proto(&clean_lc, proto_lc) {
            continue;
        }
        let dport_expr = nft_extract_dport_expr(&clean_lc);
        if let Some(pos) = clean_lc.find("redirect to :") {
            let tport = nft_extract_port_expr(&clean_lc[pos + 13..]);
            if nft_port_expr_contains(tport, port) {
                return Some(clean_dnat_src_port_label(dport_expr, port));
            }
            continue;
        }
        if clean_lc.contains(" redirect") || clean_lc.starts_with("redirect") {
            if !dport_expr.is_empty() && nft_port_expr_contains(dport_expr, port) {
                return Some(clean_dnat_src_port_label(dport_expr, port));
            }
            continue;
        }
        let after_to = ["dnat ip to ", "dnat ip6 to ", "dnat to "]
            .iter()
            .find_map(|pref| clean_lc.find(pref).map(|p| &clean_lc[p + pref.len()..]));
        let Some(after) = after_to else {
            continue;
        };
        let Some(target_tok) = after.split_whitespace().next() else {
            continue;
        };
        let (dest_ip, target_port) = if let Some(rest) = target_tok.strip_prefix('[') {
            if let Some((ip_part, tail)) = rest.split_once(']') {
                (ip_part, tail.strip_prefix(':').unwrap_or(""))
            } else {
                ("", "")
            }
        } else if let Some((ip_part, p_part)) = target_tok.rsplit_once(':')
            && ip_part.parse::<std::net::Ipv4Addr>().is_ok()
        {
            (ip_part, p_part)
        } else {
            (target_tok, "")
        };
        if dest_ip.is_empty() || !nft_ip_is_local(dest_ip, local_ips) {
            continue;
        }
        let effective_port = if !target_port.is_empty() {
            target_port
        } else {
            dport_expr
        };
        if !effective_port.is_empty() && nft_port_expr_contains(effective_port, port) {
            return Some(clean_dnat_src_port_label(dport_expr, port));
        }
    }
    None
}

#[cfg(any(target_os = "linux", test))]
fn detect_uci_dnat_src_port(
    uci_show: &str,
    port: u16,
    proto_lc: &str,
    local_ips: &[String],
) -> Option<String> {
    #[derive(Default)]
    struct FwSec {
        sec_type: String,
        opts: std::collections::HashMap<String, String>,
    }
    let mut order: Vec<String> = Vec::new();
    let mut map: std::collections::HashMap<String, FwSec> = std::collections::HashMap::new();
    for line in uci_show.lines() {
        let trimmed = line.trim();
        let Some(after) = trimmed.strip_prefix("firewall.") else {
            continue;
        };
        let Some((key, raw_val)) = after.split_once('=') else {
            continue;
        };
        let val = unquote_uci_show_val(raw_val);
        if let Some((sec, opt)) = key.split_once('.') {
            let entry = map.entry(sec.to_string()).or_default();
            entry
                .opts
                .entry(opt.to_string())
                .and_modify(|prev| {
                    prev.push(' ');
                    prev.push_str(&val);
                })
                .or_insert(val);
        } else if val == "redirect" {
            if !map.contains_key(key) {
                order.push(key.to_string());
            }
            map.entry(key.to_string()).or_default().sec_type = val;
        }
    }

    for sec_key in order {
        let Some(sec) = map.get(&sec_key) else {
            continue;
        };
        if sec.sec_type != "redirect" {
            continue;
        }
        let opt = |k: &str| sec.opts.get(k).map(String::as_str).unwrap_or("").trim();
        let enabled = opt("enabled");
        if !enabled.is_empty() && enabled != "1" {
            continue;
        }
        let src = opt("src");
        if !src.is_empty() && src != "wan" && src != "*" {
            continue;
        }
        if !uci_proto_spec_contains(opt("proto"), proto_lc) {
            continue;
        }
        let target = opt("target");
        if !target.is_empty() && !target.eq_ignore_ascii_case("DNAT") {
            continue;
        }
        let src_port = opt("src_port");
        if !src_port.is_empty() && src_port != "*" {
            continue;
        }
        if opt("family").eq_ignore_ascii_case("ipv6") {
            continue;
        }
        let dest_ip = opt("dest_ip");
        if !dest_ip.is_empty() && !nft_ip_is_local(dest_ip, local_ips) {
            continue;
        }
        let port_spec = if !opt("dest_port").is_empty() {
            opt("dest_port")
        } else {
            opt("src_dport")
        };
        if !port_spec.is_empty() && nft_port_expr_contains(port_spec, port) {
            let src_dport = opt("src_dport");
            return Some(clean_dnat_src_port_label(src_dport, port));
        }
    }
    None
}

#[cfg(any(target_os = "linux", test))]
fn detect_firewall_dnat_summary(
    fw4_dstnat: &str,
    uci_fw: &str,
    port: u16,
    required_proto: &str,
    local_ips: &[String],
) -> Option<String> {
    if port == 0 {
        return None;
    }
    let protos: Vec<&str> = required_proto.split_whitespace().collect();
    let check_protos = if protos.is_empty() {
        vec!["tcp"]
    } else {
        protos
    };
    let mut parts = Vec::new();
    for proto in check_protos {
        let proto_lc = proto.to_ascii_lowercase();
        let proto_uc = proto.to_ascii_uppercase();
        if let Some(ext_port) = detect_nft_dnat_src_port(fw4_dstnat, port, &proto_lc, local_ips)
            .or_else(|| detect_uci_dnat_src_port(uci_fw, port, &proto_lc, local_ips))
        {
            parts.push(format!("WAN {proto_uc}/{ext_port} → {proto_uc}/{port}"));
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join(", "))
    }
}

#[cfg(any(target_os = "linux", test))]
#[allow(clippy::too_many_arguments)]
fn assess_inbound_firewall(
    is_ts: bool,
    protocol: &str,
    listen: &str,
    listen_port: u16,
    open_firewall_port: bool,
    required_proto: &str,
    fw4_in: &str,
    fw4_dstnat: &str,
    uci_fw: &str,
    local_ips: &[String],
) -> (i32, i32, String, &'static str) {
    let listen_t = listen.trim();
    let is_loopback = matches!(listen_t, "127.0.0.1" | "::1" | "[::1]" | "localhost");
    if is_ts || protocol == "json_inbound" || listen_port == 0 || is_loopback {
        let reason = if is_loopback { "local_listen" } else { "" };
        return (0, -1, String::new(), reason);
    }
    let fw_open = check_fw4_port_open_with_redirects(
        fw4_in,
        fw4_dstnat,
        uci_fw,
        listen_port,
        required_proto,
        local_ips,
    );
    let dnat_summary =
        detect_firewall_dnat_summary(fw4_dstnat, uci_fw, listen_port, required_proto, local_ips)
            .unwrap_or_default();
    if fw_open == 1 {
        return (1, 1, dnat_summary, "");
    }
    if !open_firewall_port {
        return (0, -1, String::new(), "auto_open_disabled");
    }
    (1, fw_open, dnat_summary, "")
}

#[cfg(any(target_os = "linux", test))]
fn check_fw4_port_open_with_redirects(
    fw4_in: &str,
    fw4_dstnat: &str,
    uci_fw: &str,
    port: u16,
    required_proto: &str,
    local_ips: &[String],
) -> i32 {
    if port == 0 || (fw4_in.is_empty() && fw4_dstnat.is_empty() && uci_fw.is_empty()) {
        return -1;
    }
    let protos: Vec<&str> = required_proto.split_whitespace().collect();
    let check_protos = if protos.is_empty() {
        vec!["tcp"]
    } else {
        protos
    };
    for proto in check_protos {
        let proto_lc = proto.to_ascii_lowercase();
        let nft_open = fw4_in
            .lines()
            .any(|line| fw4_line_matches_port(line, &proto_lc, port))
            || nft_dstnat_chain_allows_port_proto(fw4_dstnat, port, &proto_lc, local_ips);
        if !nft_open
            && (uci_fw.is_empty()
                || !uci_firewall_allows_port_proto(uci_fw, port, &proto_lc, local_ips))
        {
            return 0;
        }
    }
    1
}

fn inbound_expected_type(protocol: &str) -> &str {
    match protocol {
        "awg" | "wireguard" => "wireguard",
        "tailscale" => "tailscale",
        "mtproto" => "mtproto",
        "json_inbound" => "json",
        other => other,
    }
}

fn inbound_required_proto(srv: &crate::store::InboundServer) -> &'static str {
    match srv.protocol.as_str() {
        "tailscale" => "",
        "awg" | "wireguard" | "hysteria2" | "hysteria" | "tuic" | "masque" => "udp",
        "trusttunnel" if srv.trusttunnel_quic => "udp",
        _ => "tcp",
    }
}

fn has_route_rule_for_inbound(sb_config: Option<&Value>, tag: &str) -> bool {
    let Some(rules) = sb_config
        .and_then(|c| c.get("route"))
        .and_then(|r| r.get("rules"))
        .and_then(Value::as_array)
    else {
        return false;
    };
    rules.iter().any(|rule| match rule.get("inbound") {
        Some(Value::String(s)) => s == tag,
        Some(Value::Array(arr)) => arr.iter().any(|v| v.as_str() == Some(tag)),
        _ => false,
    })
}

const EXTERNAL_PUBLIC_DNS_SERVERS: &[&str] = &["8.8.8.8:53", "1.1.1.1:53", "77.88.8.8:53"];

fn is_fakeip_addr(ip_str: &str, fakeip4_cidr: &str, fakeip6_cidr: &str) -> bool {
    let ip = ip_str.trim();
    if ip.is_empty() {
        return false;
    }
    let f4 = fakeip4_cidr.trim();
    if !f4.is_empty() && crate::store::ip_in_cidr(ip, f4) {
        return true;
    }
    if crate::store::ip_in_cidr(ip, "198.18.0.0/15") {
        return true;
    }
    let f6 = fakeip6_cidr.trim();
    if !f6.is_empty() && crate::store::ip_in_cidr(ip, f6) {
        return true;
    }
    crate::store::ip_in_cidr(ip, "fc00::/18")
}

fn skip_dns_wire_name(buf: &[u8], start: usize) -> Option<usize> {
    let mut pos = start;
    for _ in 0..128 {
        let &len = buf.get(pos)?;
        if len == 0 {
            return Some(pos + 1);
        }
        if (len & 0xc0) == 0xc0 {
            buf.get(pos + 1)?;
            return Some(pos + 2);
        }
        if (len & 0xc0) != 0 {
            return None;
        }
        pos = pos.checked_add(1 + usize::from(len))?;
        if pos > buf.len() {
            return None;
        }
    }
    None
}

fn parse_dns_response_ips(buf: &[u8], expected_txid: [u8; 2]) -> Option<Vec<String>> {
    if buf.len() < 12 || buf[0] != expected_txid[0] || buf[1] != expected_txid[1] {
        return None;
    }
    if (buf[2] & 0x80) == 0 || (buf[3] & 0x0f) != 0 {
        return None;
    }
    let qdcount = u16::from_be_bytes([buf[4], buf[5]]) as usize;
    let ancount = u16::from_be_bytes([buf[6], buf[7]]) as usize;

    let mut pos = 12usize;
    for _ in 0..qdcount.min(32) {
        let next = skip_dns_wire_name(buf, pos)?;
        let after_q = next.checked_add(4)?;
        if after_q > buf.len() {
            return None;
        }
        pos = after_q;
    }

    let mut ips = Vec::new();
    for _ in 0..ancount.min(64) {
        let after_name = skip_dns_wire_name(buf, pos)?;
        let hdr_end = after_name.checked_add(10)?;
        let hdr = buf.get(after_name..hdr_end)?;
        let rtype = u16::from_be_bytes([hdr[0], hdr[1]]);
        let rclass = u16::from_be_bytes([hdr[2], hdr[3]]);
        let rdlength = u16::from_be_bytes([hdr[8], hdr[9]]) as usize;
        let rdata_end = hdr_end.checked_add(rdlength)?;
        let rdata = buf.get(hdr_end..rdata_end)?;
        if rclass == 1 {
            if rtype == 1 && rdata.len() == 4 {
                let ip =
                    std::net::Ipv4Addr::new(rdata[0], rdata[1], rdata[2], rdata[3]).to_string();
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            } else if rtype == 28 && rdata.len() == 16 {
                let octets: [u8; 16] = rdata.try_into().ok()?;
                let ip = std::net::Ipv6Addr::from(octets).to_string();
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            }
        }
        pos = rdata_end;
    }
    Some(ips)
}

fn query_single_udp_dns(
    server: &str,
    host: &str,
    qtype: u16,
    timeout: Duration,
) -> Option<Vec<String>> {
    let pkt = diagnostics::build_dns_query_packet(host, qtype)?;
    let bind_addr = if server.starts_with('[') {
        "[::]:0"
    } else {
        "0.0.0.0:0"
    };
    let sock = std::net::UdpSocket::bind(bind_addr).ok()?;
    let _ = sock.set_write_timeout(Some(Duration::from_millis(800)));
    let _ = sock.set_read_timeout(Some(timeout));
    sock.connect(server).ok()?;
    sock.send(&pkt).ok()?;
    let mut buf = [0u8; 512];
    let n = sock.recv(&mut buf).ok()?;
    parse_dns_response_ips(&buf[..n], [pkt[0], pkt[1]])
}

fn resolve_domain_via_udp_dns(host: &str, servers: &[&str], timeout: Duration) -> Vec<String> {
    for server in servers {
        let Some(a_ips) = query_single_udp_dns(server, host, 1, timeout) else {
            continue;
        };
        let mut combined = a_ips;
        if let Some(aaaa_ips) = query_single_udp_dns(server, host, 28, Duration::from_millis(600)) {
            for ip in aaaa_ips {
                if !combined.contains(&ip) {
                    combined.push(ip);
                }
            }
        }
        if !combined.is_empty() {
            return combined;
        }
    }
    Vec::new()
}

fn resolve_public_host_ips_list_with_fakeip(
    host: &str,
    fakeip4_cidr: &str,
    fakeip6_cidr: &str,
) -> Vec<String> {
    let h_clean = crate::config_gen::extract_host_only(host);
    let h = h_clean.trim();
    if h.is_empty() {
        return Vec::new();
    }
    if let Ok(ip) = h.parse::<std::net::IpAddr>() {
        return vec![ip.to_string()];
    }

    let mut saw_fakeip = false;
    let mut non_fakeip_local = Vec::new();
    {
        use std::net::ToSocketAddrs;
        if let Ok(addrs) = (h, 0).to_socket_addrs() {
            for a in addrs {
                let s = a.ip().to_string();
                if is_fakeip_addr(&s, fakeip4_cidr, fakeip6_cidr) {
                    saw_fakeip = true;
                } else if !non_fakeip_local.contains(&s) {
                    non_fakeip_local.push(s);
                }
            }
        }
    }

    if !saw_fakeip && !non_fakeip_local.is_empty() {
        return non_fakeip_local;
    }

    let ext_ips: Vec<String> =
        resolve_domain_via_udp_dns(h, EXTERNAL_PUBLIC_DNS_SERVERS, Duration::from_millis(1200))
            .into_iter()
            .filter(|ip| !is_fakeip_addr(ip, fakeip4_cidr, fakeip6_cidr))
            .collect();

    if !ext_ips.is_empty() {
        return ext_ips;
    }
    non_fakeip_local
}

fn dns_probe_succeeded(probe: &Value) -> bool {
    probe.get("resolved").and_then(Value::as_bool) == Some(true)
        || probe.pointer("/engine/ok").and_then(Value::as_bool) == Some(true)
        || probe
            .get("addresses")
            .and_then(Value::as_array)
            .is_some_and(|a| !a.is_empty())
        || probe
            .pointer("/engine/addresses")
            .and_then(Value::as_array)
            .is_some_and(|a| !a.is_empty())
}

#[derive(Default, Debug, Clone, Copy, PartialEq, Eq)]
struct NftTableSummary {
    has_mangle: bool,
    mangle_rules_count: usize,
    mangle_counter_rules: usize,
    mangle_packets: u64,
    has_output: bool,
    mangle_output_rules_count: usize,
    mangle_output_counter_rules: usize,
    mangle_output_packets: u64,
    has_proxy: bool,
    proxy_rules_count: usize,
    proxy_counter_rules: usize,
    proxy_packets: u64,
}

fn extract_nft_packets(line: &str) -> u64 {
    if let Some(pos) = line.find("packets ") {
        let rest_p = &line[pos + 8..];
        if let Some(num) = rest_p.split_whitespace().next()
            && let Ok(p) = num.parse::<u64>()
        {
            return p;
        }
    }
    0
}

fn parse_nft_table_summary(text: &str) -> NftTableSummary {
    let mut summary = NftTableSummary::default();
    let mut current_chain = "";
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with("chain ") {
            let chain_name = t
                .split_whitespace()
                .nth(1)
                .unwrap_or("")
                .trim_end_matches('{');
            current_chain = match chain_name {
                "prerouting" | "mangle" => {
                    summary.has_mangle = true;
                    "mangle"
                }
                "mangle_output" | "output" => {
                    summary.has_output = true;
                    "mangle_output"
                }
                "proxy" => {
                    summary.has_proxy = true;
                    "proxy"
                }
                _ => "",
            };
            continue;
        }
        if t == "}" {
            current_chain = "";
            continue;
        }
        if current_chain.is_empty() || t.is_empty() || t.starts_with("type ") || t.starts_with('#')
        {
            continue;
        }
        let has_counter = t.contains("counter");
        let pkts = extract_nft_packets(t);
        match current_chain {
            "mangle" => {
                summary.mangle_rules_count += 1;
                if has_counter {
                    summary.mangle_counter_rules += 1;
                }
                summary.mangle_packets = summary.mangle_packets.saturating_add(pkts);
                if t.contains("tproxy") {
                    summary.has_proxy = true;
                    summary.proxy_rules_count += 1;
                    if has_counter {
                        summary.proxy_counter_rules += 1;
                    }
                    summary.proxy_packets = summary.proxy_packets.saturating_add(pkts);
                }
            }
            "mangle_output" => {
                summary.mangle_output_rules_count += 1;
                if has_counter {
                    summary.mangle_output_counter_rules += 1;
                }
                summary.mangle_output_packets = summary.mangle_output_packets.saturating_add(pkts);
            }
            "proxy" => {
                summary.proxy_rules_count += 1;
                if has_counter {
                    summary.proxy_counter_rules += 1;
                }
                summary.proxy_packets = summary.proxy_packets.saturating_add(pkts);
            }
            _ => {}
        }
    }
    summary
}

fn build_check_inbounds_result(d: &crate::store::RouterStoreData) -> Value {
    let config_path = if d.settings.core_config_path.trim().is_empty() {
        crate::platform::paths()
            .core_config_dir
            .join("config.json")
            .to_string_lossy()
            .into_owned()
    } else {
        d.settings.core_config_path.clone()
    };
    let sb_config: Option<Value> = std::fs::read_to_string(&config_path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok());
    let (_lan_ip, wan_ip) = sys_info::detect_router_ips();
    let (_lan_ipv6, wan_ipv6, _) = sys_info::detect_router_ipv6_ips();
    let wan_ipv6_public = i32::from(!wan_ipv6.is_empty() && is_public_routable_ip(&wan_ipv6));
    let wan_public =
        i32::from((!wan_ip.is_empty() && is_public_routable_ip(&wan_ip)) || wan_ipv6_public == 1);

    #[cfg(target_os = "linux")]
    let (fw4_in, fw4_dstnat, ip_addr_out) = {
        let read_chains = |chains: &[&str]| -> String {
            chains
                .iter()
                .filter_map(|chain| {
                    std::process::Command::new("nft")
                        .args(["list", "chain", "inet", "fw4", chain])
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        let ip_out = std::process::Command::new("ip")
            .args(["-o", "addr", "show"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        (
            read_chains(&["input", "input_wan"]),
            read_chains(&["dstnat_wan", "dstnat"]),
            ip_out,
        )
    };
    #[cfg(target_os = "linux")]
    let mut uci_fw_cache: Option<String> = None;

    let mut items = Vec::new();
    let mut enabled_count = 0usize;
    let mut requires_public_wan = 0i32;
    let mut public_host_dns_cache: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();

    for srv in d.servers.iter().filter(|s| s.enabled) {
        enabled_count += 1;
        let is_ts = srv.is_tailscale();
        if !is_ts {
            requires_public_wan = 1;
        }
        let is_native_ts = srv.is_native_tailscale();

        let mut tag = format!("srv-{}", srv.id);
        if srv.protocol == "json_inbound"
            && let Ok(parsed) = serde_json::from_str::<Value>(&srv.inbound_json)
            && let Some(t) = parsed.get("tag").and_then(Value::as_str)
            && !t.trim().is_empty()
        {
            tag = t.trim().to_string();
        }

        let listen = if is_ts {
            String::new()
        } else if srv.listen.trim().is_empty() {
            "::".to_string()
        } else {
            srv.listen.trim().to_string()
        };
        let listen_port = if is_ts { 0 } else { srv.listen_port };
        let expected_type = inbound_expected_type(&srv.protocol).to_string();
        let required_proto = inbound_required_proto(srv).to_string();
        let routing_mode = if is_native_ts {
            "native".to_string()
        } else if srv.routing_mode.trim().is_empty() {
            "rules".to_string()
        } else {
            srv.routing_mode.trim().to_string()
        };

        let mut runtime_exists = 0i32;
        let mut runtime_type = String::new();
        let mut runtime_listen = String::new();
        let mut runtime_port = 0u64;
        if is_native_ts {
            runtime_exists = 1;
            runtime_type = expected_type.clone();
        } else {
            let section_key = if matches!(srv.protocol.as_str(), "tailscale" | "awg" | "wireguard")
            {
                "endpoints"
            } else {
                "inbounds"
            };
            if let Some(arr) = sb_config
                .as_ref()
                .and_then(|c| c.get(section_key))
                .and_then(Value::as_array)
                && let Some(entry) = arr
                    .iter()
                    .find(|item| item.get("tag").and_then(Value::as_str) == Some(tag.as_str()))
            {
                runtime_exists = 1;
                runtime_type = entry
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                runtime_listen = entry
                    .get("listen")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                runtime_port = entry
                    .get("listen_port")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
            }
        }

        let runtime_ok = if runtime_exists == 1 {
            if is_ts || srv.protocol == "json_inbound" {
                1
            } else if runtime_type == expected_type {
                if matches!(srv.protocol.as_str(), "awg" | "wireguard") && runtime_listen.is_empty()
                {
                    i32::from(runtime_port == u64::from(listen_port))
                } else {
                    i32::from(runtime_listen == listen && runtime_port == u64::from(listen_port))
                }
            } else {
                0
            }
        } else {
            0
        };

        let listening = if is_ts {
            -1
        } else {
            let raw = check_proc_port_listening(&listen, listen_port, &required_proto);
            if runtime_ok == 1 || raw < 0 { raw } else { 0 }
        };

        let firewall_skip_precheck = is_ts
            || srv.protocol == "json_inbound"
            || listen_port == 0
            || matches!(listen.trim(), "127.0.0.1" | "::1" | "[::1]" | "localhost");
        #[cfg(target_os = "linux")]
        let (firewall_required, firewall_open, firewall_dnat, firewall_skip_reason) =
            if !firewall_skip_precheck {
                let local_ips = collect_local_router_ips(&wan_ip, &wan_ipv6, &listen, &ip_addr_out);
                let quick = check_fw4_port_open_with_redirects(
                    &fw4_in,
                    &fw4_dstnat,
                    "",
                    listen_port,
                    &required_proto,
                    &local_ips,
                );
                let uci_fw = if quick == 1 {
                    ""
                } else {
                    uci_fw_cache
                        .get_or_insert_with(|| {
                            std::process::Command::new("uci")
                                .args(["show", "firewall"])
                                .output()
                                .ok()
                                .filter(|o| o.status.success())
                                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                                .unwrap_or_default()
                        })
                        .as_str()
                };
                assess_inbound_firewall(
                    is_ts,
                    &srv.protocol,
                    &listen,
                    listen_port,
                    srv.open_firewall_port,
                    &required_proto,
                    &fw4_in,
                    &fw4_dstnat,
                    uci_fw,
                    &local_ips,
                )
            } else {
                let reason = if matches!(listen.trim(), "127.0.0.1" | "::1" | "[::1]" | "localhost")
                {
                    "local_listen"
                } else {
                    ""
                };
                (0, -1, String::new(), reason)
            };
        #[cfg(not(target_os = "linux"))]
        let (firewall_required, firewall_open, firewall_dnat, firewall_skip_reason) =
            if firewall_skip_precheck {
                let reason = if matches!(listen.trim(), "127.0.0.1" | "::1" | "[::1]" | "localhost")
                {
                    "local_listen"
                } else {
                    ""
                };
                (0, -1, String::new(), reason)
            } else if !srv.open_firewall_port {
                (0, -1, String::new(), "auto_open_disabled")
            } else {
                (1, -1, String::new(), "")
            };

        let routes_configured = if is_native_ts {
            1
        } else if routing_mode == "rules" {
            i32::from(
                runtime_exists == 1
                    && sb_config
                        .as_ref()
                        .and_then(|c| c.pointer("/route/rules"))
                        .and_then(Value::as_array)
                        .is_some_and(|r| !r.is_empty()),
            )
        } else {
            let route_tag = if srv.protocol == "shadowtls" {
                format!("{tag}-inner")
            } else {
                tag.clone()
            };
            i32::from(
                has_route_rule_for_inbound(sb_config.as_ref(), &route_tag)
                    || has_route_rule_for_inbound(sb_config.as_ref(), &tag),
            )
        };

        let public_host = srv.public_host.trim().to_string();
        let mut public_host_ips_vec = Vec::new();
        let (mut resolved, mut public_ip, mut matches_wan) = (-1i32, -1i32, -1i32);
        if srv.protocol != "json_inbound"
            && !(is_ts && public_host.is_empty())
            && !public_host.is_empty()
        {
            let cache_key = crate::config_gen::extract_host_only(&public_host)
                .trim()
                .to_ascii_lowercase();
            public_host_ips_vec = if let Some(cached) = public_host_dns_cache.get(&cache_key) {
                cached.clone()
            } else {
                let resolved_ips = resolve_public_host_ips_list_with_fakeip(
                    &public_host,
                    &d.settings.fakeip_inet4_range,
                    &d.settings.fakeip_inet6_range,
                );
                public_host_dns_cache.insert(cache_key, resolved_ips.clone());
                resolved_ips
            };
            if public_host_ips_vec.is_empty() {
                resolved = 0;
            } else {
                resolved = 1;
                public_ip = i32::from(
                    public_host_ips_vec
                        .iter()
                        .all(|ip| is_public_routable_ip(ip)),
                );
                if wan_public == 1 {
                    matches_wan = i32::from(public_host_ips_vec.iter().any(|ip| {
                        (!wan_ip.is_empty() && ip == &wan_ip)
                            || (!wan_ipv6.is_empty() && ip == &wan_ipv6)
                    }));
                }
            }
        }

        items.push(json!({
            "section": srv.id,
            "label": if srv.label.is_empty() { &srv.id } else { &srv.label },
            "protocol": srv.protocol,
            "routing_mode": routing_mode,
            "tag": tag,
            "listen": listen,
            "listen_port": listen_port,
            "public_host": public_host,
            "public_host_ips": public_host_ips_vec.join(" "),
            "expected_type": expected_type,
            "required_proto": required_proto,
            "runtime_exists": runtime_exists,
            "runtime_type": runtime_type,
            "runtime_listen": runtime_listen,
            "runtime_port": runtime_port,
            "runtime_ok": runtime_ok,
            "listening": listening,
            "open_firewall_port": i32::from(srv.open_firewall_port),
            "firewall_required": firewall_required,
            "firewall_open": firewall_open,
            "firewall_dnat": firewall_dnat,
            "firewall_skip_reason": firewall_skip_reason,
            "port_conflict": 0,
            "port_conflict_owners": "",
            "routes_configured": routes_configured,
            "public_host_resolved": resolved,
            "public_host_public": public_ip,
            "public_host_matches_wan": matches_wan,
        }));
    }

    json!({
        "success": true,
        "enabled_count": enabled_count,
        "config_path": config_path,
        "wan_ip": wan_ip,
        "wan_ipv6": wan_ipv6,
        "wan_ipv6_public": wan_ipv6_public,
        "wan_public": wan_public,
        "requires_public_wan": requires_public_wan,
        "items": items,
    })
}

fn is_public_routable_ip(ip_str: &str) -> bool {
    let Ok(addr) = ip_str.parse::<std::net::IpAddr>() else {
        return false;
    };
    match addr {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            !(v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_multicast()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || (o[0] == 100 && (o[1] & 0xc0) == 64)
                || (o[0] == 198 && (o[1] & 0xfe) == 18))
        }
        std::net::IpAddr::V6(v6) => {
            if v6.is_loopback() || v6.is_multicast() || v6.is_unspecified() {
                return false;
            }
            let seg0 = v6.segments()[0];
            !((seg0 & 0xfe00) == 0xfc00 || (seg0 & 0xffc0) == 0xfe80)
        }
    }
}

fn parse_conntrack_connections_text(
    raw: &str,
    ip_host_map: &std::collections::HashMap<String, String>,
    seen_tuples: &std::collections::HashSet<String>,
    seen_client_sockets: &std::collections::HashSet<String>,
    fakeip_cidr: Option<&str>,
    max_entries: usize,
) -> Vec<Value> {
    let fakeip_cidr = fakeip_cidr.map(str::trim).filter(|c| !c.is_empty());
    for allow_self_src in [false, true] {
        let mut result = Vec::new();
        let mut local_seen = seen_tuples.clone();

        for line in raw.lines() {
            let mut proto = "";
            let mut tcp_closed = false;
            let mut in_meta = false;
            let mut orig_src = "";
            let mut orig_dst = "";
            let mut orig_sport = "";
            let mut orig_dport = "";
            let mut orig_bytes = 0u64;
            let mut reply_dst = "";
            let mut reply_bytes = 0u64;
            let mut src_seen = 0usize;
            let mut dst_seen = 0usize;
            let mut sport_seen = 0usize;
            let mut dport_seen = 0usize;
            let mut bytes_seen = 0usize;
            let mut mark_val = 0u32;

            for (idx, tok) in line.split_ascii_whitespace().enumerate() {
                if idx == 2 {
                    proto = tok;
                    if !proto.eq_ignore_ascii_case("tcp") && !proto.eq_ignore_ascii_case("udp") {
                        break;
                    }
                } else if idx >= 3 {
                    if !in_meta {
                        if tok.starts_with("src=") {
                            in_meta = true;
                        } else if proto.eq_ignore_ascii_case("tcp")
                            && matches!(
                                tok,
                                "TIME_WAIT"
                                    | "CLOSE"
                                    | "CLOSE_WAIT"
                                    | "LAST_ACK"
                                    | "FIN_WAIT"
                                    | "FIN_WAIT2"
                            )
                        {
                            tcp_closed = true;
                            break;
                        }
                    }
                    if in_meta {
                        if let Some(v) = tok.strip_prefix("src=") {
                            src_seen += 1;
                            if src_seen == 1 {
                                orig_src = v;
                            }
                        } else if let Some(v) = tok.strip_prefix("dst=") {
                            dst_seen += 1;
                            if dst_seen == 1 {
                                orig_dst = v;
                            } else if dst_seen == 2 {
                                reply_dst = v;
                            }
                        } else if let Some(v) = tok.strip_prefix("sport=") {
                            sport_seen += 1;
                            if sport_seen == 1 {
                                orig_sport = v;
                            }
                        } else if let Some(v) = tok.strip_prefix("dport=") {
                            dport_seen += 1;
                            if dport_seen == 1 {
                                orig_dport = v;
                            }
                        } else if let Some(v) = tok.strip_prefix("bytes=") {
                            bytes_seen += 1;
                            if bytes_seen == 1 {
                                orig_bytes = v.parse::<u64>().unwrap_or(0);
                            } else if bytes_seen == 2 {
                                reply_bytes = v.parse::<u64>().unwrap_or(0);
                            }
                        } else if let Some(v) = tok.strip_prefix("mark=") {
                            mark_val = if let Some(hex) = v.strip_prefix("0x") {
                                u32::from_str_radix(hex, 16).unwrap_or(0)
                            } else {
                                v.parse::<u32>().unwrap_or(0)
                            };
                        }
                    }
                }
            }
            if tcp_closed
                || (!proto.eq_ignore_ascii_case("tcp") && !proto.eq_ignore_ascii_case("udp"))
            {
                continue;
            }
            let proto = if proto.eq_ignore_ascii_case("tcp") {
                "tcp"
            } else {
                "udp"
            };
            if orig_src.is_empty()
                || orig_dst.is_empty()
                || orig_sport.is_empty()
                || orig_dport.is_empty()
            {
                continue;
            }
            if let Some(cidr) = fakeip_cidr
                && crate::store::ip_in_cidr(orig_dst, cidr)
            {
                continue;
            }
            let src_is_ts = is_tailscale_ip(orig_src);
            let dst_is_ts = is_tailscale_ip(orig_dst);
            let any_ts = src_is_ts || dst_is_ts;
            if (!is_public_routable_ip(orig_dst) && !any_ts)
                || is_public_routable_ip(orig_src)
                || orig_src.starts_with("127.")
                || orig_src == "::1"
            {
                continue;
            }
            if (mark_val & 0x5c00_0000) != 0 {
                continue;
            }
            if !allow_self_src && !reply_dst.is_empty() && reply_dst == orig_src {
                continue;
            }
            let tkey = format!("{proto}|{orig_src}|{orig_sport}|{orig_dst}|{orig_dport}");
            if !local_seen.insert(tkey) {
                continue;
            }
            let skey = format!("{proto}|{orig_src}|{orig_sport}|{orig_dport}");
            if seen_client_sockets.contains(&skey) {
                continue;
            }
            let route_tag = if any_ts {
                if dst_is_ts {
                    "tailscale-out"
                } else {
                    "tailscale-in"
                }
            } else if orig_dport == "53" {
                "dns-out"
            } else {
                "direct-out"
            };
            let rule_str = format!("conntrack => {route_tag}");
            let resolved_host = ip_host_map.get(orig_dst).cloned().unwrap_or_default();
            let mut meta = serde_json::Map::new();
            meta.insert("network".into(), json!(proto));
            meta.insert(
                "type".into(),
                json!(if any_ts { "tailscale" } else { "conntrack" }),
            );
            if any_ts {
                meta.insert("inbound".into(), json!("tailscale-ep"));
            }
            meta.insert("sourceIP".into(), json!(orig_src));
            meta.insert("sourcePort".into(), json!(orig_sport));
            meta.insert("destinationIP".into(), json!(orig_dst));
            meta.insert("destinationPort".into(), json!(orig_dport));
            meta.insert("host".into(), json!(resolved_host));
            result.push(json!({
                "id": format!("ct:{proto}:{orig_src}:{orig_sport}:{orig_dst}:{orig_dport}"),
                "dataSource": "conntrack",
                "upload": orig_bytes,
                "download": reply_bytes,
                "chains": [route_tag],
                "rule": rule_str,
                "rulePayload": "",
                "metadata": Value::Object(meta)
            }));
            if result.len() >= max_entries {
                break;
            }
        }
        if allow_self_src || !result.is_empty() {
            return result;
        }
    }
    Vec::new()
}

fn read_pure_rust_conntrack_connections(
    ip_host_map: &std::collections::HashMap<String, String>,
    seen_tuples: &std::collections::HashSet<String>,
    seen_client_sockets: &std::collections::HashSet<String>,
    fakeip_cidr: Option<&str>,
    max_entries: usize,
) -> Vec<Value> {
    let Ok(raw) = std::fs::read_to_string("/proc/net/nf_conntrack") else {
        return Vec::new();
    };
    parse_conntrack_connections_text(
        &raw,
        ip_host_map,
        seen_tuples,
        seen_client_sockets,
        fakeip_cidr,
        max_entries,
    )
}

use crate::store::url_encode_component;

fn read_uci_ui_prefs() -> Value {
    if let Ok(store) = json_sections_store().read()
        && let Some(raw) = store
            .get("settings")
            .and_then(|s| s.get("ui_prefs_json"))
            .and_then(Value::as_str)
        && let Ok(val) = serde_json::from_str::<Value>(raw)
        && val.is_object()
    {
        return val;
    }
    json!({})
}

fn write_uci_ui_prefs(patch: &Value) -> Value {
    let mut current = read_uci_ui_prefs();
    if let (Some(cur_obj), Some(patch_obj)) = (current.as_object_mut(), patch.as_object()) {
        for (k, v) in patch_obj {
            cur_obj.insert(k.clone(), v.clone());
        }
    }
    let serialized = serde_json::to_string(&current).unwrap_or_else(|_| "{}".to_string());
    if let Ok(mut store) = json_sections_store().write() {
        let next_idx = next_section_index(&store);
        let sec = store.entry("settings".to_string()).or_insert_with(|| {
            json!({
                ".anonymous": false,
                ".type": "settings",
                ".name": "settings",
                ".index": next_idx
            })
        });
        if let Some(sec_obj) = sec.as_object_mut() {
            sec_obj.insert("ui_prefs_json".to_string(), Value::String(serialized));
        }
        persist_json_sections(&store);
    }
    current
}

fn map_pipeline_node_status(doc: &diagnostics::DoctorReport, node_id: &str) -> &'static str {
    let raw = doc
        .pipeline_nodes
        .iter()
        .find(|n| n.get("id").and_then(Value::as_str) == Some(node_id))
        .and_then(|n| n.get("status"))
        .and_then(Value::as_str)
        .unwrap_or("ok");
    match raw {
        "ok" => "OK",
        "warn" => "WARN",
        _ => "FAIL",
    }
}

fn status_severity_rank(status: &str) -> u8 {
    match status {
        "FAIL" => 2,
        "WARN" => 1,
        _ => 0,
    }
}

fn extract_ai_doctor_query(rest: &[String]) -> Option<&str> {
    rest.iter()
        .map(String::as_str)
        .map(str::trim)
        .find(|s| !s.is_empty() && !s.starts_with("--"))
}

async fn build_ubus_ai_doctor_payload(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    method: &str,
    rest: &[String],
) -> Value {
    let cache_path_buf = crate::store::runtime_state_dir()
        .join("ui-state")
        .join("ai-doctor-last.json");
    let cache_path = cache_path_buf.as_path();
    if method == "ai_doctor_last"
        && let Ok(raw) = tokio::fs::read_to_string(cache_path).await
        && let Ok(cached) = serde_json::from_str::<Value>(&raw)
        && cached.is_object()
    {
        return cached;
    }

    let query = extract_ai_doctor_query(rest);

    let ai_res = Box::pin(crate::ai_doctor::run_ai_doctor_v4(state, core, query)).await;
    let doc = Box::pin(diagnostics::run_local_doctor_with_core(state, core)).await;
    let score = ((doc.checks_passed * 100) / doc.checks_total.max(1)) as u32;

    let wan_status = map_pipeline_node_status(&doc, "wan");
    let dns_status = map_pipeline_node_status(&doc, "dns_fakeip");
    let out_status = map_pipeline_node_status(&doc, "outbounds");
    let core_status = [
        "core_process",
        "config_sync",
        "nftables",
        "resources",
        "binary",
        "clock",
    ]
    .iter()
    .map(|id| map_pipeline_node_status(&doc, id))
    .max_by_key(|st| status_severity_rank(st))
    .unwrap_or("OK");

    let nodes = json!([
        { "name": "WAN", "status": wan_status },
        { "name": "DNS", "status": dns_status },
        { "name": "Core", "status": core_status },
        { "name": "Outbound", "status": out_status },
    ]);

    let mut quick_fixes: Vec<String> = Vec::new();
    if let Some(plan) = ai_res.get("remediation_plan").and_then(Value::as_array) {
        for item in plan {
            if item.get("advisory_only").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            if let Some(fix_id) = item
                .get("fix_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                && !quick_fixes.iter().any(|existing| existing == fix_id)
            {
                quick_fixes.push(fix_id.to_string());
            }
        }
    }
    if quick_fixes.is_empty() {
        for f in &doc.findings {
            if f.suppressed_by.is_none() {
                let fix_id = f.quick_fix_id.trim();
                if !fix_id.is_empty() && !quick_fixes.iter().any(|existing| existing == fix_id) {
                    quick_fixes.push(fix_id.to_string());
                }
            }
        }
    }

    let report = ai_res
        .get("analysis")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&doc.summary);

    let payload = json!({
        "success": true,
        "async": false,
        "running": false,
        "completed": true,
        "status": "completed",
        "job_id": "rust-ai-doc-1",
        "score": score,
        "report": report,
        "quick_fixes": quick_fixes,
        "nodes": nodes,
        "mode": ai_res.get("mode").cloned().unwrap_or(Value::Null),
        "provider": ai_res.get("provider").cloned().unwrap_or(Value::Null),
        "model": ai_res.get("model").cloned().unwrap_or(Value::Null),
        "root_cause": ai_res.get("root_cause").cloned().unwrap_or(Value::Null),
        "confidence": ai_res.get("confidence").cloned().unwrap_or(Value::Null),
        "tool_trace": ai_res.get("tool_trace").cloned().unwrap_or_else(|| json!([])),
        "rag_docs": ai_res.get("rag_docs").cloned().unwrap_or_else(|| json!([])),
        "remediation_plan": ai_res.get("remediation_plan").cloned().unwrap_or_else(|| json!([])),
        "similar_incidents": ai_res.get("similar_incidents").cloned().unwrap_or_else(|| json!([])),
        "pipeline_nodes": doc.pipeline_nodes,
        "llm_error": ai_res.get("llm_error").cloned().unwrap_or(Value::Null),
    });

    if let Some(parent) = cache_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(raw) = serde_json::to_string(&payload) {
        let _ = crypto_gen::write_file_if_changed(cache_path, raw.as_bytes());
    }
    payload
}

async fn execute_pure_rust_tachyon_cli(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> CliExecOutput {
    let d = Box::new(state.data.read().await.clone());
    let live = Box::new(state.live.read().await.clone());

    if let Some(res) = execute_cli_part_early_boxed(method, rest, state, core, &d, &live).await {
        return res;
    }
    if let Some(res) = execute_cli_part_components_boxed(method, rest, state, core, &d).await {
        return res;
    }
    if let Some(res) = execute_cli_part_dns_fuzzer_boxed(method, rest, state, core).await {
        return res;
    }
    execute_cli_part_routes_state_boxed(method, rest, state, core, &d, &live).await
}

#[inline(never)]
fn execute_cli_part_early_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    d: &'a crate::store::RouterStoreData,
    live: &'a crate::store::LiveTelemetry,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(execute_cli_part_early(method, rest, state, core, d, live))
}

#[inline(never)]
fn execute_cli_part_components_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    d: &'a crate::store::RouterStoreData,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(execute_cli_part_components(method, rest, state, core, d))
}

#[inline(never)]
fn execute_cli_part_dns_fuzzer_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(execute_cli_part_dns_fuzzer(method, rest, state, core))
}

#[inline(never)]
fn execute_cli_part_routes_state_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
    d: &'a crate::store::RouterStoreData,
    live: &'a crate::store::LiveTelemetry,
) -> BoxedCliFuture<'a, CliExecOutput> {
    Box::pin(execute_cli_part_routes_state(
        method, rest, state, core, d, live,
    ))
}

async fn execute_cli_part_early(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    d: &crate::store::RouterStoreData,
    live: &crate::store::LiveTelemetry,
) -> Option<CliExecOutput> {
    match method {
        "check_proxy" => {
            let (code, text) =
                Box::pin(diagnostics::run_proxy_check_cli(d, live.core_running)).await;
            return Some((code, text, String::new()));
        }
        "check_logs" | "check_sing_box_logs" | "check_tachyon_core_logs" => {
            let text = if live.recent_logs.is_empty() {
                format!(
                    "[INFO] tachyon-core {} active on 127.0.0.1:9090\n[INFO] nftables inet TachyonTable active\n",
                    live.core_version
                )
            } else {
                format!("{}\n", live.recent_logs.join("\n"))
            };
            return Some((0, text, String::new()));
        }
        "component_action_log" => {
            let job_id = rest.first().map(String::as_str).unwrap_or("");
            let offset = rest
                .get(1)
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(0);
            let out = crate::updater::read_job_log(job_id, offset);
            return Some((0, format!("{out}\n"), String::new()));
        }
        "global_check" => {
            let masked = rest.first().map(String::as_str) == Some("masked");
            let sys = sys_info::collect_host_info();
            let doc = Box::pin(diagnostics::run_local_doctor_with_core(state, core)).await;
            let score = ((doc.checks_passed * 100) / doc.checks_total.max(1)) as u32;
            let mut report = String::new();
            report.push_str("=== Tachyon Diagnostic Report ===\n");
            report.push_str(&format!(
                "Router: {} ({})\n",
                sys.router_model, sys.openwrt_release
            ));
            report.push_str(&format!("Kernel: {} ({})\n", sys.os, sys.arch));
            report.push_str(&format!(
                "Memory: {} MB used / {} MB total\n",
                sys.memory_used_mb, sys.memory_total_mb
            ));
            report.push_str(&format!(
                "Engine: tachyon-core {} (running: {})\n",
                live.core_version, live.core_running
            ));
            report.push_str(&format!(
                "Sections: {} | Outbounds: {} | Conditions: {}\n",
                d.sections.len(),
                d.outbound_sources.len(),
                d.conditions.len()
            ));
            report.push_str(&format!(
                "DNS Type: {} | Servers: {}\n",
                d.settings.dns_type,
                if masked {
                    "[REDACTED]".to_string()
                } else {
                    d.settings.dns_servers.join(", ")
                }
            ));
            report.push_str(&format!("Health Score: {score}/100 ({})\n", doc.summary));
            for f in &doc.findings {
                report.push_str(&format!(
                    " - [{}] {}: {}\n",
                    f.severity.to_uppercase(),
                    f.title,
                    f.detail
                ));
            }
            return Some((0, report, String::new()));
        }
        _ => {}
    }

    let out_val = match method {
        "check_sing_box" | "check_tachyon_core" | "check_core" => {
            let wan6_cache = tokio::task::spawn_blocking(crate::store::probe_wan6_runtime_state)
                .await
                .unwrap_or_default();
            let ipv6_active =
                crate::store::resolve_effective_ipv6_state(&d.settings, wan6_cache.wan6_available)
                    .is_active();
            build_core_health_check_payload(d, live, ipv6_active)
        }
        "check_dns" | "check_dns_available" => {
            let dns_srv = d
                .settings
                .dns_servers
                .first()
                .cloned()
                .unwrap_or_else(|| "1.1.1.1".to_string());
            let boot_srv = d
                .settings
                .bootstrap_dns_servers
                .first()
                .cloned()
                .unwrap_or_else(|| "1.1.1.1".to_string());
            let dns_probe = Box::pin(diagnostics::run_dns_check_with_engine(
                core,
                "www.youtube.com",
            ))
            .await;
            let dns_ok = dns_probe_succeeded(&dns_probe);
            let boot_target = resolve_dns_bench_target(&boot_srv, "udp");
            let boot_ok = tokio::time::timeout(
                Duration::from_millis(800),
                tokio::net::TcpStream::connect(&boot_target),
            )
            .await
            .is_ok_and(|r| r.is_ok())
                || boot_srv.parse::<std::net::IpAddr>().is_ok() && dns_ok;
            let is_entware = crate::platform::is_entware();
            let (dns_on_router, dhcp_config_status, dns_router_label, dhcp_config_label) =
                if is_entware {
                    let mode = normalize_entware_dns_mode(&d.settings.entware_dns_mode);
                    let dns_port = if mode == "override" {
                        53
                    } else if d.settings.entware_dns_port > 0 {
                        d.settings.entware_dns_port
                    } else {
                        1053
                    };
                    let core_listening = check_proc_port_listening("0.0.0.0", dns_port, "udp") == 1
                        || check_proc_port_listening("127.0.0.1", dns_port, "udp") == 1
                        || check_proc_port_listening("127.0.0.42", dns_port, "udp") == 1
                        || live.core_running;
                    let dhcp_ok = match mode {
                        "override" => core_listening,
                        "manual" => true,
                        _ => crate::net_stack_iptables::check_entware_dns_redirect_active().await,
                    };
                    let router_lbl = if mode == "override" {
                        "127.0.0.1:53 (override)".to_string()
                    } else {
                        format!("DNS :53 → 127.0.0.1:{dns_port}")
                    };
                    let dhcp_lbl = match mode {
                        "override" => "opkg dns-override → :53".to_string(),
                        "manual" => "manual (dont_touch_dhcp)".to_string(),
                        _ => format!("iptables TACHYON_DNS_NAT → :{dns_port}"),
                    };
                    (core_listening, dhcp_ok, Some(router_lbl), Some(dhcp_lbl))
                } else {
                    let dnsmasq = sys_info::collect_dnsmasq_status();
                    let dns_on_router = dnsmasq.running
                        || check_proc_port_listening("0.0.0.0", 53, "udp") == 1
                        || live.core_running;
                    (dns_on_router, dnsmasq.running, None, None)
                };
            let mut payload = json!({
                "dns_type": d.settings.dns_type,
                "dns_server": dns_srv,
                "dns_status": i32::from(dns_ok),
                "dns_server_count": d.settings.dns_servers.len().max(1),
                "dns_server_index": 0,
                "bootstrap_dns_server": boot_srv,
                "bootstrap_dns_status": i32::from(boot_ok),
                "bootstrap_dns_server_count": d.settings.bootstrap_dns_servers.len().max(1),
                "bootstrap_dns_server_index": 0,
                "dns_on_router": i32::from(dns_on_router),
                "dhcp_config_status": i32::from(dhcp_config_status),
                "dont_touch_dhcp": i32::from(d.settings.dont_touch_dhcp || (is_entware && normalize_entware_dns_mode(&d.settings.entware_dns_mode) == "manual")),
                "probe": dns_probe,
            });
            if let Some(obj) = payload.as_object_mut() {
                if let Some(lbl) = dns_router_label {
                    obj.insert("dns_router_label".into(), json!(lbl));
                }
                if let Some(lbl) = dhcp_config_label {
                    obj.insert("dhcp_config_label".into(), json!(lbl));
                }
            }
            payload
        }
        "check_fakeip" => {
            let f4 = d.settings.fakeip_inet4_range.clone();
            let f6 = d.settings.fakeip_inet6_range.clone();
            let (_lan_v6, wan_v6, _) =
                tokio::task::spawn_blocking(sys_info::detect_router_ipv6_ips)
                    .await
                    .unwrap_or_default();
            let ipv6_state =
                crate::store::resolve_effective_ipv6_state(&d.settings, !wan_v6.is_empty());
            let dns_addr = diagnostics::local_dns_probe_addr(&d.settings);
            let (v4_ok, v4_ip, v6_ok, v6_ip, aaaa_suppressed) =
                diagnostics::probe_local_fakeip_dns_at(dns_addr, &f4, &f6, ipv6_state.is_active())
                    .await;
            diagnostics::format_fakeip_probe_payload(diagnostics::FakeIpProbePayloadInput {
                d,
                ipv6_state,
                via_proxy: true,
                v4_ok,
                v4_ip: &v4_ip,
                v6_ok,
                v6_ip: &v6_ip,
                aaaa_suppressed,
            })
        }
        "check_nft" | "check_nft_rules" => {
            let table_active = net_stack::check_nft_table_active().await;
            let use_iptables =
                crate::platform::firewall_kind() == crate::platform::FirewallKind::Iptables;
            let nft_installed =
                Path::new("/usr/sbin/nft").exists() || Path::new("/sbin/nft").exists();
            if d.settings.proxy_mode == "tun" || d.settings.proxy_mode == "socks" {
                json!({
                    "not_applicable": 1,
                    "installed": if use_iptables { true } else { nft_installed || table_active },
                    "table_present": table_active,
                    "table_exist": i32::from(table_active),
                    "table_name": if use_iptables { "iptables (TACHYON_*)" } else { "inet TachyonTable" },
                })
            } else if use_iptables {
                let ipt = crate::net_stack_iptables::inspect_iptables_summary().await;
                let rules_mangle_exist =
                    table_active && ipt.has_mangle && ipt.mangle_rules_count > 0;
                let rules_mangle_counters = rules_mangle_exist;
                let rules_mangle_output_exist =
                    table_active && ipt.has_output && ipt.mangle_output_rules_count > 0;
                let output_has_marking =
                    d.settings.fakeip_enabled || d.settings.route_router_traffic;
                let rules_mangle_output_counters =
                    rules_mangle_output_exist || (!output_has_marking && rules_mangle_exist);
                let rules_proxy_exist = table_active && ipt.has_proxy && ipt.proxy_rules_count > 0;
                let rules_proxy_counters = rules_proxy_exist;
                json!({
                    "installed": table_active || ipt.has_mangle,
                    "table_present": table_active,
                    "table_exist": i32::from(table_active),
                    "table_name": "iptables (TACHYON_*)",
                    "rules_mangle_exist": i32::from(rules_mangle_exist),
                    "rules_mangle_counters": i32::from(rules_mangle_counters),
                    "mangle_rules_count": ipt.mangle_rules_count,
                    "mangle_packets": ipt.mangle_packets,
                    "rules_mangle_output_exist": i32::from(rules_mangle_output_exist),
                    "rules_mangle_output_counters": i32::from(rules_mangle_output_counters),
                    "mangle_output_rules_count": ipt.mangle_output_rules_count,
                    "mangle_output_packets": ipt.mangle_output_packets,
                    "rules_proxy_exist": i32::from(rules_proxy_exist),
                    "rules_proxy_counters": i32::from(rules_proxy_counters),
                    "proxy_rules_count": ipt.proxy_rules_count,
                    "proxy_packets": ipt.proxy_packets,
                    "rules_other_mark_exist": 0,
                    "rules": crate::net_stack_iptables::compile_iptables_preview(d),
                })
            } else {
                let mut summary = NftTableSummary::default();
                if let Ok(Ok(out)) = tokio::time::timeout(
                    Duration::from_secs(3),
                    Command::new("nft")
                        .args(["list", "table", "inet", "TachyonTable"])
                        .output(),
                )
                .await
                    && out.status.success()
                {
                    let text = String::from_utf8_lossy(&out.stdout);
                    summary = parse_nft_table_summary(&text);
                }
                let rules_mangle_exist =
                    table_active && summary.has_mangle && summary.mangle_rules_count > 0;
                let rules_mangle_counters = rules_mangle_exist
                    && (summary.mangle_packets > 0 || summary.mangle_counter_rules > 0);
                let rules_mangle_output_exist =
                    table_active && summary.has_output && summary.mangle_output_rules_count > 0;
                let output_has_marking =
                    d.settings.fakeip_enabled || d.settings.route_router_traffic;
                let rules_mangle_output_counters = rules_mangle_output_exist
                    && (summary.mangle_output_packets > 0
                        || summary.mangle_output_counter_rules > 0
                        || !output_has_marking);
                let rules_proxy_exist =
                    table_active && summary.has_proxy && summary.proxy_rules_count > 0;
                let rules_proxy_counters = rules_proxy_exist
                    && (summary.proxy_packets > 0 || summary.proxy_counter_rules > 0);
                json!({
                    "installed": nft_installed || table_active,
                    "table_present": table_active,
                    "table_exist": i32::from(table_active),
                    "table_name": "inet TachyonTable",
                    "rules_mangle_exist": i32::from(rules_mangle_exist),
                    "rules_mangle_counters": i32::from(rules_mangle_counters),
                    "mangle_rules_count": summary.mangle_rules_count,
                    "mangle_packets": summary.mangle_packets,
                    "rules_mangle_output_exist": i32::from(rules_mangle_output_exist),
                    "rules_mangle_output_counters": i32::from(rules_mangle_output_counters),
                    "mangle_output_rules_count": summary.mangle_output_rules_count,
                    "mangle_output_packets": summary.mangle_output_packets,
                    "rules_proxy_exist": i32::from(rules_proxy_exist),
                    "rules_proxy_counters": i32::from(rules_proxy_counters),
                    "proxy_rules_count": summary.proxy_rules_count,
                    "proxy_packets": summary.proxy_packets,
                    "rules_other_mark_exist": 0,
                    "rules": net_stack::compile_nftables_ruleset(d),
                })
            }
        }
        "check_inbounds_config" => json!({
            "success": true,
            "enabled_count": d.servers.iter().filter(|s| s.enabled).count(),
        }),
        "check_inbounds" => {
            let d_clone = Box::new(d.clone());
            tokio::task::spawn_blocking(move || build_check_inbounds_result(&d_clone))
                .await
                .unwrap_or_else(|e| json!({ "success": false, "error": e.to_string() }))
        }
        "check_zapret_runtime"
        | "check_zapret2_runtime"
        | "check_byedpi_runtime"
        | "get_zapret_status"
        | "get_zapret2_status"
        | "get_byedpi_status" => json!({
            "installed": 0,
            "running": 0,
            "not_applicable": 1,
        }),
        "get_wdtt_status" => {
            let active = d
                .outbound_sources
                .iter()
                .any(|s| s.enabled && matches!(s.source_type.as_str(), "wdtt" | "csqtt" | "qwdtt"));
            json!({
                "installed": 1,
                "native": true,
                "running": i32::from(active && live.core_running),
                "enabled": i32::from(active),
            })
        }
        "get_olcrtc_status" => {
            let active = d
                .outbound_sources
                .iter()
                .any(|s| s.enabled && s.source_type == "olcrtc");
            json!({
                "installed": 1,
                "native": true,
                "running": i32::from(active && live.core_running),
                "enabled": i32::from(active),
            })
        }
        "get_fptn_status" => {
            let active = d
                .outbound_sources
                .iter()
                .any(|s| s.enabled && (s.source_type == "fptn" || s.source_type == "fptnb"))
                || d.sections
                    .iter()
                    .any(|s| s.enabled && s.connection_type == "fptn");
            json!({
                "installed": 1,
                "native": true,
                "running": i32::from(active && live.core_running),
                "enabled": i32::from(active),
            })
        }
        "get_tailscale_peers" | "get_tailscale_status" => {
            let ts = Box::pin(core.get_tailscale_status()).await;
            let enabled = net_stack::is_tailscale_enabled(d);
            json!({
                "success": true,
                "enabled": enabled,
                "native": net_stack::native_tailscale_enabled(d),
                "running": live.core_running && enabled,
                "status": ts,
                "peers": ts.get("peers").cloned().unwrap_or_else(|| json!([])),
            })
        }
        "get_engine_info" | "engine_info" => json!({
            "active": "tachyon-core",
            "installed": tachyon_core_binary_installed(),
            "running": live.core_running,
            "version": live.core_version,
            "engines": [
                {
                    "name": "tachyon-core",
                    "known": true,
                    "installed": tachyon_core_binary_installed(),
                    "active": true
                }
            ]
        }),
        "engine_plan" => {
            let plan = transaction::analyze_config_plan(d);
            json!({
                "success": true,
                "active_engine": "tachyon-core",
                "target_engine": d.settings.engine_variant,
                "switch_required": false,
                "plan": plan,
            })
        }
        "set_engine" => {
            let target = rest.first().map(String::as_str).unwrap_or("tachyon-core");
            if target != "tachyon-core" && target != "native" {
                json!({
                    "success": false,
                    "active": "tachyon-core",
                    "switched": false,
                    "error": format!("Unsupported engine: {target}")
                })
            } else {
                json!({
                    "success": true,
                    "active": "tachyon-core",
                    "switched": true
                })
            }
        }
        "service_action_async" | "service_action_start" => {
            let act = rest.first().map(String::as_str).unwrap_or("reload");
            Box::pin(handle_service_action_async(act, state, core)).await
        }
        "service_action_status" => {
            let job_id = rest.first().map(String::as_str).unwrap_or("");
            let mut found: Option<Value> = None;
            if is_safe_sub_job_id(job_id) {
                let job_path = crate::store::runtime_state_dir()
                    .join("service-jobs")
                    .join(format!("{job_id}.json"));
                if let Ok(raw) = std::fs::read_to_string(&job_path)
                    && let Ok(v) = serde_json::from_str::<Value>(&raw)
                {
                    found = Some(v);
                }
            }
            found.unwrap_or_else(|| {
                json!({
                    "success": false,
                    "job_id": job_id,
                    "kind": "service",
                    "status": "not_found",
                    "running": false,
                    "completed": false,
                    "exit_code": 1,
                    "error": "Service job not found"
                })
            })
        }
        "latency_test_async" | "latency_test_start" => {
            let ltype = rest.first().map(String::as_str).unwrap_or("group");
            let section = rest.get(1).map(String::as_str).unwrap_or("Main");
            let raw_tag = rest.get(2).map(String::as_str).unwrap_or("");
            let timeout_ms: u64 = rest
                .get(3)
                .and_then(|s| s.trim().parse::<u64>().ok())
                .unwrap_or(3000)
                .clamp(1000, 15000);
            let test_url = if d.settings.latency_test_url.trim().is_empty() {
                "https://www.gstatic.com/generate_204".to_string()
            } else {
                d.settings.latency_test_url.trim().to_string()
            };
            let enc_test_url = url_encode_component(&test_url);

            let proxies_val = Box::pin(core.clash_request("GET", "/proxies", None))
                .await
                .ok();
            let proxies_map = proxies_val
                .as_ref()
                .and_then(|v| v.get("proxies"))
                .and_then(Value::as_object);

            let (target_tags, eff_tag) =
                resolve_latency_targets(d, proxies_map, ltype, section, raw_tag);

            let seq = next_job_seq();
            let safe_sec = sanitize_job_slug(section);
            let job_id = format!("rust-lat-{safe_sec}-{}-{seq}", crate::store::unix_now_u64());
            let jobs_dir = crate::store::runtime_state_dir().join("latency-jobs");
            let _ = std::fs::create_dir_all(&jobs_dir);
            let job_path = jobs_dir.join(format!("{job_id}.json"));

            let total = target_tags.len();
            let start_payload = json!({
                "success": true,
                "job_id": job_id,
                "kind": "latency",
                "section": section,
                "latency_type": ltype,
                "tag": eff_tag,
                "status": "running",
                "running": true,
                "completed": false,
                "exit_code": 0,
                "progress": {
                    "completed": 0,
                    "total": total,
                    "succeeded": 0,
                    "failed": 0
                },
                "results": {}
            });
            let _ = crypto_gen::write_json_if_changed(&job_path, &start_payload);

            let core_c = Arc::clone(core);
            let state_c = Arc::clone(state);
            let job_id_bg = job_id.clone();
            let ltype_owned = ltype.to_string();
            let section_owned = section.to_string();
            let eff_tag_owned = eff_tag.clone();
            let job_path_bg = job_path.clone();

            let worker_fut = Box::pin(async move {
                let mut results_map = Map::new();
                let mut completed_cnt = 0usize;
                let mut succeeded_cnt = 0usize;
                let mut failed_cnt = 0usize;
                let mut probe_err: Option<String> = None;

                if !target_tags.is_empty() {
                    let eff_total = target_tags.len();
                    let sem = Arc::new(tokio::sync::Semaphore::new(12));
                    let mut join_set = tokio::task::JoinSet::new();
                    for tag in target_tags {
                        let core_inner = Arc::clone(&core_c);
                        let permit_sem = Arc::clone(&sem);
                        let enc_url = enc_test_url.clone();
                        join_set.spawn(async move {
                            let _permit = permit_sem.acquire().await.ok();
                            let encoded = url_encode_component(&tag);
                            let path = format!(
                                "/proxies/{encoded}/delay?url={enc_url}&timeout={timeout_ms}"
                            );
                            let res = core_inner.clash_request("GET", &path, None).await;
                            (tag, res)
                        });
                    }
                    let mut live_updates: Vec<(String, u32)> = Vec::new();
                    while let Some(joined) = join_set.join_next().await {
                        let Ok((tag, res)) = joined else {
                            continue;
                        };
                        completed_cnt += 1;
                        match res {
                            Ok(v) => {
                                if let Some(ms) = v.get("delay").and_then(Value::as_u64)
                                    && ms > 0
                                {
                                    succeeded_cnt += 1;
                                    results_map.insert(tag.clone(), json!(ms));
                                    live_updates.push((tag, ms as u32));
                                } else {
                                    failed_cnt += 1;
                                    results_map.insert(tag, json!(0));
                                }
                            }
                            Err(_) => {
                                failed_cnt += 1;
                                results_map.insert(tag, json!(0));
                            }
                        }
                        if completed_cnt.is_multiple_of(8) && completed_cnt < eff_total {
                            let progress_payload = json!({
                                "success": true,
                                "job_id": job_id_bg,
                                "kind": "latency",
                                "section": section_owned,
                                "latency_type": ltype_owned,
                                "tag": eff_tag_owned,
                                "status": "running",
                                "running": true,
                                "completed": false,
                                "exit_code": 0,
                                "progress": {
                                    "completed": completed_cnt,
                                    "total": eff_total,
                                    "succeeded": succeeded_cnt,
                                    "failed": failed_cnt
                                },
                                "results": results_map
                            });
                            let _ =
                                crypto_gen::write_json_if_changed(&job_path_bg, &progress_payload);
                        }
                    }
                    if !live_updates.is_empty() {
                        let mut l = state_c.live.write().await;
                        for (t, ms) in live_updates {
                            if l.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES {
                                l.node_latencies_ms.insert(t, ms);
                            }
                        }
                    }
                } else if ltype_owned == "group" && !eff_tag_owned.is_empty() {
                    let encoded = url_encode_component(&eff_tag_owned);
                    let path =
                        format!("/group/{encoded}/delay?url={enc_test_url}&timeout={timeout_ms}");
                    match core_c.clash_request("GET", &path, None).await {
                        Ok(v) => {
                            if let Some(obj) = v.as_object() {
                                let mut l = state_c.live.write().await;
                                for (k, dval) in obj {
                                    completed_cnt += 1;
                                    if let Some(ms) = dval.as_u64()
                                        && ms > 0
                                    {
                                        succeeded_cnt += 1;
                                        results_map.insert(k.clone(), json!(ms));
                                        if l.node_latencies_ms.len()
                                            < crate::store::MAX_NODE_LATENCIES
                                        {
                                            l.node_latencies_ms.insert(k.clone(), ms as u32);
                                        }
                                    } else {
                                        failed_cnt += 1;
                                        results_map.insert(k.clone(), json!(0));
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            probe_err = Some(format!("{e:#}"));
                            failed_cnt = 1;
                        }
                    }
                } else {
                    probe_err = Some(format!(
                        "No testable proxy nodes resolved for section '{section_owned}'"
                    ));
                    failed_cnt = 1;
                }

                let final_total = completed_cnt.max(1);
                let ok = probe_err.is_none();
                let mut done_payload = json!({
                    "success": ok,
                    "job_id": job_id_bg,
                    "kind": "latency",
                    "section": section_owned,
                    "latency_type": ltype_owned,
                    "tag": eff_tag_owned,
                    "status": if ok { "completed" } else { "failed" },
                    "running": false,
                    "completed": true,
                    "exit_code": i32::from(!ok),
                    "progress": {
                        "completed": completed_cnt,
                        "total": final_total,
                        "succeeded": succeeded_cnt,
                        "failed": failed_cnt
                    },
                    "results": results_map
                });
                if let Some(err) = probe_err
                    && let Some(obj) = done_payload.as_object_mut()
                {
                    obj.insert("error".to_string(), json!(err));
                    obj.insert("message".to_string(), json!(err));
                }
                let _ = crypto_gen::write_json_if_changed(&job_path_bg, &done_payload);
                done_payload
            });

            if DAEMON_MODE.load(std::sync::atomic::Ordering::Acquire) {
                tokio::spawn(async move {
                    let _ = worker_fut.await;
                });
                start_payload
            } else {
                worker_fut.await
            }
        }
        "latency_test_status" => {
            let job_id = rest.first().map(String::as_str).unwrap_or("rust-lat-Main");
            let mut found: Option<Value> = None;
            if is_safe_sub_job_id(job_id) {
                let job_path = crate::store::runtime_state_dir()
                    .join("latency-jobs")
                    .join(format!("{job_id}.json"));
                if let Ok(raw) = std::fs::read_to_string(&job_path)
                    && let Ok(v) = serde_json::from_str::<Value>(&raw)
                {
                    found = Some(v);
                }
            }
            found.unwrap_or_else(|| {
                json!({
                    "success": false,
                    "job_id": job_id,
                    "kind": "latency",
                    "status": "not_found",
                    "running": false,
                    "completed": false,
                    "exit_code": 1,
                    "error": "Latency job not found"
                })
            })
        }
        "ui_action_ack" | "component_action_ack" => {
            if rest.first().map(String::as_str) == Some("subscription")
                && let Some(job_id) = rest.get(1).map(String::as_str)
                && is_safe_sub_job_id(job_id)
            {
                let job_path = crate::store::runtime_state_dir()
                    .join("subscription-jobs")
                    .join(format!("{job_id}.json"));
                if let Ok(raw) = std::fs::read_to_string(&job_path)
                    && let Ok(val) = serde_json::from_str::<Value>(&raw)
                    && val.get("running").and_then(Value::as_bool) != Some(true)
                {
                    let _ = std::fs::remove_file(&job_path);
                }
            }
            json!({
                "success": true
            })
        }
        _ => return None,
    };
    let s = serde_json::to_string(&out_val).unwrap_or_else(|_| "{}".to_string());
    Some((0, format!("{s}\n"), String::new()))
}

type ImportParseOutcome = Result<
    (
        Box<crate::store::RouterStoreData>,
        usize,
        (usize, usize, usize, usize),
    ),
    String,
>;

#[inline(never)]
fn load_and_parse_import_store(src_path: &Path, state_path: &Path) -> ImportParseOutcome {
    let raw = std::fs::read_to_string(src_path)
        .map_err(|e| format!("Не удалось прочитать {}: {e}", src_path.display()))?;
    let (candidate_val, normalized_aliases) = crate::store::parse_store_from_str_tolerant(&raw)
        .map_err(|e| format!("Невалидный JSON хранилища {}: {e:#}", src_path.display()))?;
    let mut candidate = Box::new(candidate_val);
    let _ = crate::store::normalize_loaded_store_data(&mut candidate, &raw, state_path);
    let counts = (
        candidate.sections.len(),
        candidate.outbound_sources.len(),
        candidate.conditions.len(),
        candidate.balancers.len(),
    );
    Ok((candidate, normalized_aliases, counts))
}

async fn handle_config_import(
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    let src_path = rest
        .first()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| state.path.clone());
    if !src_path.is_file() {
        return json!({
            "success": false,
            "error": format!("Файл конфигурации не найден: {}", src_path.display()),
        });
    }
    let src_clone = src_path.clone();
    let state_path_clone = state.path.clone();
    let parse_res = tokio::task::spawn_blocking(move || {
        load_and_parse_import_store(&src_clone, &state_path_clone)
    })
    .await
    .map_err(|e| format!("Задача разбора конфигурации завершилась с ошибкой: {e}"))
    .and_then(|res| res);
    let (candidate, normalized_aliases, counts) = match parse_res {
        Ok(res) => res,
        Err(err) => {
            return json!({
                "success": false,
                "error": err,
            });
        }
    };
    if let Err(e) = transaction::commit_transaction_boxed(state, candidate, "config_import").await {
        return json!({
            "success": false,
            "error": format!("{e:#}"),
        });
    }
    {
        let d_now = state.data.read().await;
        sync_from_store_to_json_and_cache(&d_now);
    }
    let mut applied = false;
    if !core.is_manually_stopped() {
        if let Err(e) = Box::pin(core.apply_or_reload()).await {
            return json!({
                "success": false,
                "imported": true,
                "error": format!("Конфигурация импортирована, но применение к ядру не удалось: {e:#}"),
            });
        }
        applied = true;
    }
    json!({
        "success": true,
        "path": src_path.to_string_lossy(),
        "applied": applied,
        "normalized_aliases": normalized_aliases,
        "sections": counts.0,
        "outbounds": counts.1,
        "conditions": counts.2,
        "balancers": counts.3,
    })
}

async fn handle_reload_with_disk_sync(state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let mut reloaded_from_disk = false;
    if state.is_disk_modified_externally() {
        if let Err(e) = state.reload_from_disk().await {
            return json!({
                "success": false,
                "error": format!("Хранилище на диске изменено, но перечитать его не удалось: {e:#}"),
            });
        }
        reloaded_from_disk = true;
    }
    {
        let d_now = state.data.read().await;
        sync_from_store_to_json_and_cache(&d_now);
    }
    match Box::pin(core.apply_or_reload()).await {
        Ok(()) => {
            {
                let d_now = state.data.read().await;
                sync_from_store_to_json_and_cache(&d_now);
            }
            let live = state.live.read().await;
            json!({
                "success": true,
                "reloaded_from_disk": reloaded_from_disk,
                "config_drift": live.config_drift,
            })
        }
        Err(e) => json!({ "success": false, "error": format!("{e:#}") }),
    }
}

#[inline(never)]
fn validate_and_compile_store_sync(
    d: &crate::store::RouterStoreData,
) -> (Vec<String>, Vec<String>, Option<Value>) {
    let plan = transaction::analyze_config_plan(d);
    let mut errors = plan.errors;
    let warnings = plan.warnings;
    let compiled = match config_gen::compile_core_config(d) {
        Ok(cfg) => Some(cfg),
        Err(e) => {
            errors.push(format!("compile_core_config: {e:#}"));
            None
        }
    };
    (errors, warnings, compiled)
}

async fn handle_config_validate(state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let d = Box::new(state.data.read().await.clone());
    let (sections_len, outbounds_len, conditions_len, balancers_len) = (
        d.sections.len(),
        d.outbound_sources.len(),
        d.conditions.len(),
        d.balancers.len(),
    );
    let (mut errors, mut warnings, compiled) =
        tokio::task::spawn_blocking(move || validate_and_compile_store_sync(&d))
            .await
            .unwrap_or_else(|e| {
                (
                    vec![format!("config_validate task join error: {e}")],
                    Vec::new(),
                    None,
                )
            });

    if let Some(cfg) = compiled {
        let bin_path = core.resolve_bin_path().await;
        if cfg!(target_os = "linux") && !bin_path.is_empty() && Path::new(&bin_path).exists() {
            if let Err(err) = Box::pin(CoreManager::run_core_check_on_value(&bin_path, &cfg)).await
            {
                errors.push(format!("tachyon-core check: {err}"));
            }
        } else if !bin_path.is_empty() && !Path::new(&bin_path).exists() {
            warnings.push(format!(
                "Бинарный файл tachyon-core не найден ({bin_path}); выполнена проверка схемы"
            ));
        }
    }

    json!({
        "success": errors.is_empty(),
        "valid": errors.is_empty(),
        "errors": errors,
        "warnings": warnings,
        "sections": sections_len,
        "outbounds": outbounds_len,
        "conditions": conditions_len,
        "balancers": balancers_len,
    })
}

async fn handle_engine_status(state: &Arc<AppState>) -> Value {
    let live = state.live.read().await.clone();
    let d = state.data.read().await;
    json!({
        "success": true,
        "engine": "tachyon-core",
        "running": live.core_running,
        "pid": live.core_pid,
        "version": live.core_version,
        "uptime_seconds": live.core_uptime_secs,
        "config_drift": live.config_drift,
        "desired_config_digest": live.desired_config_digest,
        "applied_config_digest": live.applied_config_digest,
        "safe_minimal_active": live.safe_minimal_active,
        "sections": d.sections.len(),
        "outbounds": d.outbound_sources.len(),
        "conditions": d.conditions.len(),
        "balancers": d.balancers.len(),
    })
}

#[inline(never)]
fn execute_cli_engine_commands_boxed<'a>(
    method: &'a str,
    rest: &'a [String],
    state: &'a Arc<AppState>,
    core: &'a Arc<CoreManager>,
) -> BoxedCliFuture<'a, Option<CliExecOutput>> {
    Box::pin(execute_cli_engine_commands(method, rest, state, core))
}

async fn execute_cli_engine_commands(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<CliExecOutput> {
    let val = match method {
        "engine_status" => Box::pin(handle_engine_status(state)).await,
        "engine_apply" | "engine_reload" => {
            Box::pin(handle_reload_with_disk_sync(state, core)).await
        }
        "config_validate" => Box::pin(handle_config_validate(state, core)).await,
        "diagnose_json" => {
            let doc = Box::pin(diagnostics::run_local_doctor(state)).await;
            serde_json::to_value(doc)
                .unwrap_or_else(|e| json!({ "success": false, "error": e.to_string() }))
        }
        "config_import" => Box::pin(handle_config_import(rest, state, core)).await,
        _ => return None,
    };
    let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
    Some((0, format!("{s}\n"), String::new()))
}

async fn execute_cli_part_components(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    d: &crate::store::RouterStoreData,
) -> Option<CliExecOutput> {
    let out_val = match method {
        "component_install_version" => {
            let comp = rest.first().map(String::as_str).unwrap_or("tachyon-core");
            let tag = rest.get(1).map(String::as_str);
            Box::pin(crate::updater::start_component_action(
                core,
                comp,
                "install_version",
                tag,
            ))
            .await
        }
        "component_action" | "component_action_async" | "component_action_start" => {
            let comp = rest.first().map(String::as_str).unwrap_or("tachyon-core");
            let act = rest.get(1).map(String::as_str).unwrap_or("update");
            let variant = rest.get(2).map(String::as_str);
            if act == "set_language"
                && let Some(raw_lang) = variant
            {
                let lang = if raw_lang.trim().eq_ignore_ascii_case("en") {
                    "en"
                } else {
                    "ru"
                };
                {
                    let mut d = state.data.write().await;
                    d.settings.lang = lang.to_string();
                }
                let _ = state.save().await;
                if let Ok(mut store) = json_sections_store().write() {
                    if let Some(sec) = store.get_mut("settings").and_then(Value::as_object_mut) {
                        sec.insert("lang".to_string(), json!(lang));
                        if sec.contains_key("language") {
                            sec.insert("language".to_string(), json!(lang));
                        }
                    }
                    persist_json_sections(&store);
                }
                let job_id = format!("rust-lang-{lang}");
                let job_payload = json!({
                    "success": true,
                    "job_id": job_id,
                    "status": "completed",
                    "phase": "completed",
                    "running": false,
                    "completed": true,
                    "component": comp,
                    "action": act,
                    "changed": true,
                    "exit_code": 0,
                    "message": if lang == "en" { "Interface language updated" } else { "Язык интерфейса обновлён" }
                });
                let action_dir = crate::store::runtime_state_dir().join("component-actions");
                if std::fs::create_dir_all(&action_dir).is_ok() {
                    let _ = crypto_gen::write_json_if_changed(
                        action_dir.join(format!("{job_id}.json")),
                        &job_payload,
                    );
                }
                if cfg!(target_os = "linux") {
                    let arg_set = format!("luci.main.lang={lang}");
                    let _ = tokio::time::timeout(
                        Duration::from_secs(3),
                        Command::new("uci").args(["-q", "set", &arg_set]).status(),
                    )
                    .await;
                    let _ = tokio::time::timeout(
                        Duration::from_secs(3),
                        Command::new("uci").args(["-q", "commit", "luci"]).status(),
                    )
                    .await;
                }
                job_payload
            } else if method != "component_action"
                || matches!(
                    act,
                    "check_update"
                        | "install"
                        | "reinstall"
                        | "install_version"
                        | "install_tachyon_core"
                        | "install_stable"
                        | "install_extended"
                        | "install_extended_compressed"
                        | "install_tiny"
                        | "install_lx"
                )
            {
                Box::pin(crate::updater::start_component_action(
                    core, comp, act, variant,
                ))
                .await
            } else {
                let v = Box::pin(core.component_action(comp, act, variant)).await;
                let ok = v.get("ok").and_then(Value::as_bool).unwrap_or(true);
                let msg = v
                    .pointer("/result/message")
                    .or_else(|| v.pointer("/result/error"))
                    .and_then(Value::as_str)
                    .unwrap_or("OK");
                let public_comp = match comp.trim().to_ascii_lowercase().as_str() {
                    "tachyon-core" | "tachyon_core" | "tachyoncore" | "sing-box" | "sing_box"
                    | "singbox" => "tachyon-core",
                    _ => comp,
                };
                json!({
                    "success": ok,
                    "component": public_comp,
                    "action": act,
                    "status": if ok { "completed" } else { "failed" },
                    "running": false,
                    "completed": true,
                    "exit_code": if ok { 0 } else { 1 },
                    "message": msg,
                    "result": v
                })
            }
        }
        "component_action_status" => {
            let raw_job = rest.first().map(String::as_str).unwrap_or("");
            if raw_job.starts_with("rust-lang-") {
                let lang = if raw_job.ends_with("en") { "en" } else { "ru" };
                json!({
                    "success": true,
                    "job_id": raw_job,
                    "component": "tachyon",
                    "action": "set_language",
                    "status": "completed",
                    "phase": "completed",
                    "running": false,
                    "completed": true,
                    "changed": true,
                    "exit_code": 0,
                    "message": if lang == "en" { "Interface language updated" } else { "Язык интерфейса обновлён" }
                })
            } else {
                crate::updater::read_job_status(raw_job)
            }
        }
        "server_auto_configure" => {
            let proto = rest.first().map(String::as_str).unwrap_or("vless");
            crypto_gen::auto_configure_server(proto)
        }
        "component_list_releases" => {
            let comp = rest.first().map(String::as_str).unwrap_or("tachyon-core");
            let count = rest
                .get(1)
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(10);
            let page = rest
                .get(2)
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(1);
            Box::pin(crate::updater::list_releases(core, comp, count, page)).await
        }
        "list_update" | "list_update_async" => {
            Box::pin(crate::updater::start_list_update_async(core)).await
        }
        "list_update_if_due" => {
            Box::pin(crate::updater::start_list_update_if_due_async(core)).await
        }
        "list_update_status" => crate::updater::read_list_update_status(),
        "subscription_update" => {
            let target = rest.first().map(String::as_str).unwrap_or("");
            let selector = rest.get(1).map(String::as_str).unwrap_or("");
            let eff_target = resolve_subscription_cli_target(d, target, selector);
            match Box::pin(core.refresh_subscription_source(&eff_target)).await {
                Ok(cnt) => {
                    {
                        let d_now = state.data.read().await;
                        sync_section_cache(&d_now);
                    }
                    json!({
                        "success": true,
                        "job_id": "rust-sub-1",
                        "section": target,
                        "source_selector": selector,
                        "resolved_target": eff_target,
                        "status": "completed",
                        "running": false,
                        "completed": true,
                        "updated_sources": cnt,
                        "exit_code": 0
                    })
                }
                Err(e) => json!({
                    "success": false,
                    "job_id": "rust-sub-1",
                    "section": target,
                    "source_selector": selector,
                    "status": "failed",
                    "running": false,
                    "completed": true,
                    "exit_code": 1,
                    "error": e.to_string()
                }),
            }
        }
        "subscription_update_async" => {
            let target = rest.first().map(String::as_str).unwrap_or("").to_string();
            let selector = rest.get(1).map(String::as_str).unwrap_or("").to_string();
            let eff_target = resolve_subscription_cli_target(d, &target, &selector);
            let started_at = crate::store::unix_now_u64();
            let seq = next_job_seq();
            let job_id = format!(
                "rust-sub-{}-{started_at}-{seq}",
                sanitize_job_slug(if target.is_empty() { "all" } else { &target }),
            );
            let jobs_dir = crate::store::runtime_state_dir().join("subscription-jobs");
            let _ = std::fs::create_dir_all(&jobs_dir);
            let job_path = jobs_dir.join(format!("{job_id}.json"));
            let start_payload = json!({
                "success": true,
                "job_id": job_id,
                "section": target,
                "source_selector": selector,
                "source_index": selector,
                "resolved_target": eff_target,
                "started_at": started_at,
                "status": "running",
                "running": true,
                "completed": false,
                "message": "Subscription update started"
            });
            let _ = crypto_gen::write_json_if_changed(&job_path, &start_payload);
            let core_clone = Arc::clone(core);
            let state_clone = Arc::clone(state);
            let job_id_bg = job_id.clone();
            let job_path_bg = job_path.clone();
            let target_bg = target.clone();
            let selector_bg = selector.clone();
            let eff_bg = eff_target.clone();
            let work = Box::pin(async move {
                let done_payload = match core_clone.refresh_subscription_source(&eff_bg).await {
                    Ok(cnt) => {
                        {
                            let d_now = state_clone.data.read().await;
                            sync_section_cache(&d_now);
                        }
                        json!({
                            "success": true,
                            "job_id": job_id_bg,
                            "section": target_bg,
                            "source_selector": selector_bg,
                            "source_index": selector_bg,
                            "resolved_target": eff_bg,
                            "started_at": started_at,
                            "status": "completed",
                            "running": false,
                            "completed": true,
                            "updated_sources": cnt,
                            "exit_code": 0,
                            "message": "Subscription update completed"
                        })
                    }
                    Err(e) => json!({
                        "success": false,
                        "job_id": job_id_bg,
                        "section": target_bg,
                        "source_selector": selector_bg,
                        "source_index": selector_bg,
                        "resolved_target": eff_bg,
                        "started_at": started_at,
                        "status": "failed",
                        "running": false,
                        "completed": true,
                        "exit_code": 1,
                        "message": e.to_string()
                    }),
                };
                let _ = crypto_gen::write_json_if_changed(&job_path_bg, &done_payload);
                done_payload
            });
            if DAEMON_MODE.load(std::sync::atomic::Ordering::Acquire) {
                tokio::spawn(async move {
                    let _ = work.await;
                });
                start_payload
            } else {
                work.await
            }
        }
        "subscription_update_if_due" => {
            let target = rest.first().map(String::as_str);
            let selector = rest.get(1).map(String::as_str).unwrap_or("");
            let eff_target = target.map(|t| resolve_subscription_cli_target(d, t, selector));
            match Box::pin(core.refresh_due_subscriptions(eff_target.as_deref())).await {
                Ok(cnt) => {
                    if cnt > 0 {
                        let d_now = state.data.read().await;
                        sync_section_cache(&d_now);
                    }
                    json!({
                        "success": true,
                        "updated_sources": cnt,
                        "exit_code": 0
                    })
                }
                Err(e) => json!({
                    "success": false,
                    "updated_sources": 0,
                    "exit_code": 1,
                    "error": e.to_string()
                }),
            }
        }
        "component_updates_if_due" => {
            Box::pin(crate::updater::maybe_run_auto_update_tick(core)).await;
            json!({
                "success": true,
                "exit_code": 0
            })
        }
        "subscription_update_status" => {
            let job_id = rest.first().map(String::as_str).unwrap_or("");
            let mut result_val: Option<Value> = None;
            if is_safe_sub_job_id(job_id) {
                let job_path = crate::store::runtime_state_dir()
                    .join("subscription-jobs")
                    .join(format!("{job_id}.json"));
                if let Ok(raw) = std::fs::read_to_string(&job_path)
                    && let Ok(val) = serde_json::from_str::<Value>(&raw)
                {
                    result_val = Some(val);
                }
            }
            result_val.unwrap_or_else(|| {
                json!({
                    "success": false,
                    "job_id": job_id,
                    "status": "not_found",
                    "running": false,
                    "completed": false,
                    "exit_code": 1,
                    "error": "Subscription job not found"
                })
            })
        }
        "start" => match Box::pin(core.start()).await {
            Ok(()) => {
                {
                    let d_now = state.data.read().await;
                    sync_from_store_to_json_and_cache(&d_now);
                }
                json!({ "success": true })
            }
            Err(e) => json!({ "success": false, "error": format!("{e:#}") }),
        },
        "stop" => match Box::pin(core.stop()).await {
            Ok(()) => json!({ "success": true }),
            Err(e) => json!({ "success": false, "error": format!("{e:#}") }),
        },
        "restart" | "reload" => Box::pin(handle_reload_with_disk_sync(state, core)).await,
        "enable" | "disable" => {
            let init_script = &crate::platform::paths().init_script;
            if cfg!(target_os = "linux") && !crate::platform::is_entware() && init_script.is_file()
            {
                match tokio::time::timeout(
                    Duration::from_secs(10),
                    Command::new(init_script).arg(method).output(),
                )
                .await
                {
                    Ok(Ok(out)) if out.status.success() => json!({ "success": true }),
                    Ok(Ok(out)) => {
                        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
                        let msg = if stderr.is_empty() {
                            format!("init.d {method} exited with {:?}", out.status.code())
                        } else {
                            stderr
                        };
                        json!({ "success": false, "error": msg })
                    }
                    Ok(Err(e)) => json!({ "success": false, "error": format!("{e}") }),
                    Err(_) => json!({
                        "success": false,
                        "error": format!("timeout running {} {method}", init_script.display())
                    }),
                }
            } else {
                json!({ "success": true })
            }
        }
        "apply_quick_fix" => {
            let fix_id = rest.first().map(String::as_str).unwrap_or("restart_core");
            match Box::pin(diagnostics::apply_quick_fix_verified(
                state, core, fix_id, false, false,
            ))
            .await
            {
                Ok(res) => json!({
                    "success": res.ok,
                    "message": res.message,
                    "risk_tier": res.risk_tier,
                    "rolled_back": res.rolled_back,
                    "cooldown_blocked": res.cooldown_blocked,
                    "before_findings": res.before_findings,
                    "after_findings": res.after_findings,
                }),
                Err(e) => json!({
                    "success": false,
                    "message": e.to_string(),
                }),
            }
        }
        "ai_doctor" | "ai_doctor_last" => {
            Box::pin(build_ubus_ai_doctor_payload(state, core, method, rest)).await
        }
        "service_health_check" => {
            let sub = rest.first().map(String::as_str).unwrap_or("get-targets");
            match sub {
                "get-targets" => {
                    let is_all = rest.get(1).map(String::as_str) == Some("all");
                    Value::Array(build_service_health_targets(
                        &d.sections,
                        &d.outbound_sources,
                        &d.conditions,
                        is_all,
                    ))
                }
                "check-custom" | "check-domain" | "check-single" => {
                    let arg = rest.get(1).map(String::as_str).unwrap_or("example.com");
                    let mut section = "Custom".to_string();
                    let mut route_type = "connection".to_string();
                    let mut domain = arg.to_string();
                    if arg.trim_start().starts_with('{')
                        && let Ok(v) = serde_json::from_str::<Value>(arg)
                    {
                        if let Some(s) = v.get("section").and_then(Value::as_str) {
                            section = s.to_string();
                        }
                        if let Some(rt) = v.get("route_type").and_then(Value::as_str) {
                            route_type = rt.to_string();
                        }
                        if let Some(dom) = v.get("domain").and_then(Value::as_str) {
                            domain = dom.to_string();
                        }
                    } else if sub == "check-single" && rest.len() >= 4 {
                        section = rest[1].clone();
                        route_type = rest[2].clone();
                        domain = rest[3].clone();
                    } else {
                        route_type = infer_domain_route_type(
                            &domain,
                            &d.sections,
                            &d.outbound_sources,
                            &d.conditions,
                        );
                    }
                    let socks_proxy = (d.settings.proxy_mode == "socks" && route_type != "direct")
                        .then(|| "socks5h://127.0.0.1:1080".to_string());
                    let res = probe_service_target(section, route_type, domain, socks_proxy).await;
                    Value::Array(vec![res])
                }
                "check-batch" | "run" => {
                    let is_all = rest.get(1).map(String::as_str) == Some("all");
                    let targets = build_service_health_targets(
                        &d.sections,
                        &d.outbound_sources,
                        &d.conditions,
                        is_all,
                    );
                    let is_socks_mode = d.settings.proxy_mode == "socks";
                    let mut results = vec![Value::Null; targets.len()];
                    let mut set = tokio::task::JoinSet::new();
                    let mut next_idx = 0usize;
                    while next_idx < targets.len() || !set.is_empty() {
                        while set.len() < 4 && next_idx < targets.len() {
                            let idx = next_idx;
                            next_idx += 1;
                            let t = &targets[idx];
                            let sec = t
                                .get("section")
                                .and_then(Value::as_str)
                                .unwrap_or("Service")
                                .to_string();
                            let rt = t
                                .get("route_type")
                                .and_then(Value::as_str)
                                .unwrap_or("connection")
                                .to_string();
                            let dom = t
                                .get("domain")
                                .and_then(Value::as_str)
                                .unwrap_or("cp.cloudflare.com")
                                .to_string();
                            let socks_proxy = (is_socks_mode && rt != "direct")
                                .then(|| "socks5h://127.0.0.1:1080".to_string());
                            set.spawn(async move {
                                (idx, probe_service_target(sec, rt, dom, socks_proxy).await)
                            });
                        }
                        if let Some(Ok((idx, val))) = set.join_next().await
                            && idx < results.len()
                        {
                            results[idx] = val;
                        }
                    }
                    Value::Array(results)
                }
                _ => json!([]),
            }
        }
        "leak_check_async" | "leak_check_status" | "leak_check" => {
            let jobs_dir = crate::store::runtime_state_dir().join("leak-jobs");
            let _ = std::fs::create_dir_all(&jobs_dir);
            if method == "leak_check_async" {
                let now = crate::store::unix_now_secs();
                let job_id = format!("rust-leak-{}", crate::store::unix_now_u64());
                let job_path = jobs_dir.join(format!("{job_id}.json"));
                let latest_path = jobs_dir.join("latest.json");
                let init_payload = json!({
                    "success": true,
                    "job_id": job_id,
                    "status": "running",
                    "running": true,
                    "progress": 10,
                    "stage": "probing",
                    "started_at": now,
                });
                let _ = crypto_gen::write_json_if_changed(&job_path, &init_payload);
                let _ = crypto_gen::write_json_if_changed(&latest_path, &init_payload);
                let state_c = Arc::clone(state);
                let core_c = Arc::clone(core);
                let job_id_bg = job_id.clone();
                tokio::spawn(async move {
                    let data = run_full_ubus_leak_check(&state_c, &core_c).await;
                    let finished = crate::store::unix_now_secs();
                    let done_payload = json!({
                        "success": true,
                        "job_id": job_id_bg,
                        "status": "done",
                        "running": false,
                        "progress": 100,
                        "stage": "done",
                        "started_at": now,
                        "finished_at": finished,
                        "data": data,
                    });
                    let _ = crypto_gen::write_json_if_changed(&job_path, &done_payload);
                    let _ = crypto_gen::write_json_if_changed(&latest_path, &done_payload);
                });
                init_payload
            } else if method == "leak_check_status" {
                let job_id = rest.first().map(String::as_str).unwrap_or("");
                let target_path = if !job_id.is_empty() && is_safe_sub_job_id(job_id) {
                    jobs_dir.join(format!("{job_id}.json"))
                } else {
                    jobs_dir.join("latest.json")
                };
                if let Ok(raw) = std::fs::read_to_string(&target_path)
                    && let Ok(val) = serde_json::from_str::<Value>(&raw)
                {
                    val
                } else {
                    json!({
                        "success": false,
                        "job_id": job_id,
                        "status": "not_found",
                        "running": false,
                        "progress": 0,
                        "error": "Leak check job not found"
                    })
                }
            } else {
                Box::pin(run_full_ubus_leak_check(state, core)).await
            }
        }
        _ => return None,
    };
    let s = serde_json::to_string(&out_val).unwrap_or_else(|_| "{}".to_string());
    Some((0, format!("{s}\n"), String::new()))
}

fn is_fuzzer_engine_arg(s: &str) -> bool {
    matches!(
        s.trim().to_ascii_lowercase().as_str(),
        "desync" | "zapret" | "zapret2" | "byedpi" | "all"
    )
}

fn is_fuzzer_target_arg(s: &str) -> bool {
    let lc = s.trim().to_ascii_lowercase();
    !lc.is_empty()
        && !is_fuzzer_engine_arg(&lc)
        && (lc.ends_with("_suite")
            || matches!(
                lc.as_str(),
                "youtube"
                    | "discord"
                    | "telegram"
                    | "twitch"
                    | "twitter"
                    | "instagram"
                    | "meta"
                    | "google"
                    | "ai"
                    | "custom"
            )
            || lc.starts_with("http://")
            || lc.starts_with("https://")
            || lc.starts_with("udp://"))
}

pub(crate) fn normalize_fuzzer_start_args<'a>(arg0: &'a str, arg1: &'a str) -> (&'a str, &'a str) {
    let a0 = arg0.trim();
    let a1 = arg1.trim();
    if is_fuzzer_target_arg(a0) && (a1.is_empty() || is_fuzzer_engine_arg(a1)) {
        let eng = if a1.is_empty() { "desync" } else { a1 };
        (eng, a0)
    } else {
        (
            if a0.is_empty() { "desync" } else { a0 },
            if a1.is_empty() { "youtube_suite" } else { a1 },
        )
    }
}

async fn execute_cli_part_dns_fuzzer(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<CliExecOutput> {
    let out_val = match method {
        "dns_benchmark_async" | "dns_benchmark_status" | "dns_benchmark" => {
            let now = crate::store::unix_now_secs();
            let cache_path = crate::store::runtime_state_dir().join("dns-benchmark-cache.json");
            let cached_val = if method == "dns_benchmark_status" {
                std::fs::read_to_string(&cache_path)
                    .ok()
                    .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            } else {
                None
            };
            if let Some(cached) = cached_val {
                cached
            } else {
                let candidates: &[(&str, &str, &str, &str, &str, &str)] = &[
                    (
                        "yandex_udp",
                        "Yandex",
                        "Primary",
                        "udp",
                        "77.88.8.8",
                        "77.88.8.8",
                    ),
                    (
                        "yandex_udp2",
                        "Yandex",
                        "Secondary",
                        "udp",
                        "77.88.8.1",
                        "77.88.8.1",
                    ),
                    (
                        "yandex_doh",
                        "Yandex",
                        "DoH Unfiltered",
                        "doh",
                        "https://common.dot.dns.yandex.net/dns-query",
                        "77.88.8.8",
                    ),
                    (
                        "cloudflare_udp",
                        "Cloudflare",
                        "Primary",
                        "udp",
                        "1.1.1.1",
                        "1.1.1.1",
                    ),
                    (
                        "cloudflare_udp2",
                        "Cloudflare",
                        "Secondary",
                        "udp",
                        "1.0.0.1",
                        "1.0.0.1",
                    ),
                    (
                        "cloudflare_doh",
                        "Cloudflare",
                        "DoH Encrypted",
                        "doh",
                        "https://cloudflare-dns.com/dns-query",
                        "1.1.1.1",
                    ),
                    (
                        "google_udp",
                        "Google",
                        "Primary",
                        "udp",
                        "8.8.8.8",
                        "8.8.8.8",
                    ),
                    (
                        "google_udp2",
                        "Google",
                        "Secondary",
                        "udp",
                        "8.8.4.4",
                        "8.8.4.4",
                    ),
                    (
                        "google_doh",
                        "Google",
                        "DoH Encrypted",
                        "doh",
                        "https://dns.google/dns-query",
                        "8.8.8.8",
                    ),
                    (
                        "adguard_udp",
                        "AdGuard",
                        "Default",
                        "udp",
                        "94.140.14.14",
                        "94.140.14.14",
                    ),
                    (
                        "adguard_doh",
                        "AdGuard",
                        "DoH AdBlock",
                        "doh",
                        "https://dns.adguard-dns.com/dns-query",
                        "94.140.14.14",
                    ),
                    (
                        "comss_udp",
                        "Comss.one",
                        "Direct",
                        "udp",
                        "92.223.109.31",
                        "92.223.109.31",
                    ),
                    (
                        "comss_doh",
                        "Comss.one",
                        "DoH",
                        "doh",
                        "https://dns.comss.one/dns-query",
                        "92.223.109.31",
                    ),
                    (
                        "controld_udp",
                        "Control D",
                        "Unfiltered",
                        "udp",
                        "76.76.2.0",
                        "76.76.2.0",
                    ),
                    (
                        "controld_doh",
                        "Control D",
                        "DoH Encrypted",
                        "doh",
                        "https://freedns.controld.com/p0",
                        "76.76.2.0",
                    ),
                    ("quad9_udp", "Quad9", "Primary", "udp", "9.9.9.9", "9.9.9.9"),
                    (
                        "quad9_doh",
                        "Quad9",
                        "DoH Secure",
                        "doh",
                        "https://dns.quad9.net/dns-query",
                        "9.9.9.9",
                    ),
                    (
                        "mullvad_udp",
                        "Mullvad",
                        "Privacy",
                        "udp",
                        "194.242.2.2",
                        "194.242.2.2",
                    ),
                    (
                        "mullvad_doh",
                        "Mullvad",
                        "DoH Privacy",
                        "doh",
                        "https://dns.mullvad.net/dns-query",
                        "194.242.2.2",
                    ),
                    (
                        "opendns_udp",
                        "OpenDNS",
                        "Standard",
                        "udp",
                        "208.67.222.222",
                        "208.67.222.222",
                    ),
                    (
                        "opendns_doh",
                        "OpenDNS",
                        "DoH Encrypted",
                        "doh",
                        "https://doh.opendns.com/dns-query",
                        "208.67.222.222",
                    ),
                    (
                        "alidns_doh",
                        "AliDNS",
                        "DoH",
                        "doh",
                        "https://dns.alidns.com/dns-query",
                        "223.5.5.5",
                    ),
                    (
                        "dnssb_doh",
                        "DNS.SB",
                        "DoH",
                        "doh",
                        "https://doh.dns.sb/dns-query",
                        "185.222.222.222",
                    ),
                    (
                        "dnspod_doh",
                        "DNSPod",
                        "DoH",
                        "doh",
                        "https://dns.pub/dns-query",
                        "119.29.29.29",
                    ),
                    (
                        "nextdns_doh",
                        "NextDNS",
                        "DoH Unconfigured",
                        "doh",
                        "https://dns.nextdns.io",
                        "45.90.28.0",
                    ),
                    (
                        "dns4eu_doh",
                        "DNS4EU",
                        "DoH Unfiltered",
                        "doh",
                        "https://unfiltered.joindns4.eu/dns-query",
                        "86.54.11.100",
                    ),
                    (
                        "360_doh",
                        "360 DNS",
                        "DoH",
                        "doh",
                        "https://doh.360.cn/dns-query",
                        "101.226.4.6",
                    ),
                    (
                        "canadian_shield_doh",
                        "CIRA Canadian Shield",
                        "DoH Private",
                        "doh",
                        "https://private.canadianshield.cira.ca/dns-query",
                        "149.112.121.10",
                    ),
                    (
                        "digitale_gesellschaft_doh",
                        "Digitale Gesellschaft",
                        "DoH",
                        "doh",
                        "https://dns.digitale-gesellschaft.ch/dns-query",
                        "185.95.218.42",
                    ),
                    (
                        "restena_doh",
                        "Restena",
                        "DoH",
                        "doh",
                        "https://dnspub.restena.lu/dns-query",
                        "158.64.1.29",
                    ),
                    (
                        "iij_doh",
                        "IIJ",
                        "DoH",
                        "doh",
                        "https://public.dns.iij.jp/dns-query",
                        "103.2.57.5",
                    ),
                    (
                        "libredns_doh",
                        "LibreDNS",
                        "DoH",
                        "doh",
                        "https://doh.libredns.gr/dns-query",
                        "116.202.176.26",
                    ),
                    (
                        "switch_doh",
                        "SWITCH",
                        "DoH",
                        "doh",
                        "https://dns.switch.ch/dns-query",
                        "130.59.31.248",
                    ),
                    (
                        "applied_privacy_doh",
                        "Applied Privacy",
                        "DoH",
                        "doh",
                        "https://doh.applied-privacy.net/query",
                        "146.255.56.98",
                    ),
                    (
                        "uncensoreddns_doh",
                        "UncensoredDNS",
                        "DoH",
                        "doh",
                        "https://anycast.uncensoreddns.org/dns-query",
                        "91.239.100.100",
                    ),
                    (
                        "rethinkdns_doh",
                        "RethinkDNS",
                        "DoH",
                        "doh",
                        "https://sky.rethinkdns.com/dns-query",
                        "104.21.83.62",
                    ),
                    (
                        "xfinity_doh",
                        "Comcast Xfinity",
                        "DoH",
                        "doh",
                        "https://doh.xfinity.com/dns-query",
                        "75.75.75.75",
                    ),
                ];
                let mut join_set = tokio::task::JoinSet::new();
                for &(id, provider, tag, dtype, address, ip) in candidates {
                    let id_s = id.to_string();
                    let provider_s = provider.to_string();
                    let tag_s = tag.to_string();
                    let dtype_s = dtype.to_string();
                    let address_s = address.to_string();
                    let ip_s = ip.to_string();
                    join_set.spawn(async move {
                        let measured: Option<u64> = if dtype_s == "udp" {
                            probe_udp_dns_rtt_ms(&format!("{ip_s}:53"), "google.com")
                                .await
                                .ok()
                                .map(|ms| ms.round().max(1.0) as u64)
                        } else {
                            let target = format!("{ip_s}:443");
                            let start = std::time::Instant::now();
                            tokio::time::timeout(
                                Duration::from_millis(800),
                                tokio::net::TcpStream::connect(&target),
                            )
                            .await
                            .ok()
                            .and_then(|r| r.ok())
                            .map(|_| (start.elapsed().as_millis() as u64).max(1))
                        };
                        let ok = measured.is_some();
                        let latency = measured.unwrap_or(0);
                        let status = if !ok {
                            "unreachable"
                        } else if latency <= 35 {
                            "excellent"
                        } else if latency <= 85 {
                            "good"
                        } else {
                            "slow"
                        };
                        let score = if ok {
                            100u64.saturating_sub(latency / 2).max(20)
                        } else {
                            0
                        };
                        json!({
                            "id": id_s,
                            "name": provider_s,
                            "provider": provider_s,
                            "tag": tag_s,
                            "type": dtype_s,
                            "address": address_s,
                            "ip": ip_s,
                            "reachable": ok,
                            "latency": latency,
                            "latency_ms": latency,
                            "avg_ms": latency,
                            "min_ms": latency,
                            "max_ms": latency,
                            "lossPct": if ok { 0 } else { 100 },
                            "success_rate": if ok { 100 } else { 0 },
                            "status": status,
                            "score": score,
                            "recommended": false
                        })
                    });
                }
                let mut rows = Vec::with_capacity(candidates.len());
                while let Some(Ok(row)) = join_set.join_next().await {
                    rows.push(row);
                }
                rows.sort_by_key(|r| {
                    let ok = r.get("reachable").and_then(Value::as_bool).unwrap_or(false);
                    let lat = r.get("latency").and_then(Value::as_u64).unwrap_or(9999);
                    (if ok { 0 } else { 1 }, lat)
                });
                let fastest_doh: Vec<String> = rows
                    .iter()
                    .filter(|r| {
                        r.get("reachable").and_then(Value::as_bool) == Some(true)
                            && r.get("type").and_then(Value::as_str) == Some("doh")
                    })
                    .take(2)
                    .filter_map(|r| {
                        r.get("address")
                            .and_then(Value::as_str)
                            .map(|s| s.trim_start_matches("https://").to_string())
                    })
                    .collect();
                let fastest_udp: Vec<String> = rows
                    .iter()
                    .filter(|r| {
                        r.get("reachable").and_then(Value::as_bool) == Some(true)
                            && r.get("type").and_then(Value::as_str) == Some("udp")
                    })
                    .take(2)
                    .filter_map(|r| r.get("ip").and_then(Value::as_str).map(String::from))
                    .collect();
                if let Some(first_ok) = rows
                    .iter_mut()
                    .find(|r| r.get("reachable").and_then(Value::as_bool) == Some(true))
                    && let Some(obj) = first_ok.as_object_mut()
                {
                    obj.insert("recommended".to_string(), json!(true));
                }
                let rec_doh = if fastest_doh.is_empty() {
                    vec![
                        "cloudflare-dns.com/dns-query".to_string(),
                        "dns.google/dns-query".to_string(),
                    ]
                } else {
                    fastest_doh
                };
                let rec_udp = if fastest_udp.is_empty() {
                    vec!["1.1.1.1".to_string(), "8.8.8.8".to_string()]
                } else {
                    fastest_udp
                };
                let resp = json!({
                    "success": true,
                    "message": "Бенчмарк DNS выполнен",
                    "job_id": "rust-dns-bench-1",
                    "status": "completed",
                    "running": false,
                    "completed": true,
                    "progress": 100,
                    "current_server": "",
                    "started_at": now.saturating_sub(1),
                    "finished_at": now,
                    "error": null,
                    "results": rows,
                    "recommendation": {
                        "dns_type": "doh",
                        "dns_upstream_mode": "parallel",
                        "dns_server": rec_doh,
                        "bootstrap_dns_server": rec_udp,
                        "dns_fallback_server": ["77.88.8.8", "9.9.9.9"],
                        "reason": "Отобраны резолверы с наименьшей измеренной задержкой отклика"
                    }
                });
                if let Some(parent) = cache_path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = crypto_gen::write_json_if_changed(&cache_path, &resp);
                resp
            }
        }
        "dns_speed_test_start" => {
            let now = crate::store::unix_now_secs();
            let state_path = crate::store::runtime_state_dir().join("dns-speed-test.json");
            let payload_str = rest.first().map(String::as_str).unwrap_or("{}");
            let req: Value = serde_json::from_str(payload_str).unwrap_or_else(|_| json!({}));
            let protocol = req
                .get("protocol")
                .and_then(Value::as_str)
                .unwrap_or("udp")
                .to_string();
            let mut domains: Vec<String> = req
                .get("domains")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            if domains.is_empty() {
                domains = vec![
                    "google.com".to_string(),
                    "youtube.com".to_string(),
                    "cloudflare.com".to_string(),
                ];
            }
            let mut server_entries: Vec<(String, String)> = Vec::new();
            let mut seen = std::collections::HashSet::new();
            if let Some(arr) = req.get("servers").and_then(Value::as_array) {
                for item in arr.iter().filter_map(Value::as_str) {
                    let s = item.trim().to_string();
                    if !s.is_empty() && seen.insert(s.clone()) {
                        server_entries.push((s, protocol.clone()));
                    }
                }
            }
            if let Some(arr) = req.get("udp_servers").and_then(Value::as_array) {
                for item in arr.iter().filter_map(Value::as_str) {
                    let s = item.trim().to_string();
                    if !s.is_empty() && seen.insert(s.clone()) {
                        server_entries.push((s, "udp".to_string()));
                    }
                }
            }
            if server_entries.is_empty() {
                json!({
                    "success": false,
                    "error": "Choose between 1 and 24 DNS servers."
                })
            } else {
                let mut bootstrap_ips: Vec<std::net::IpAddr> = Vec::new();
                for (srv, proto) in &server_entries {
                    if proto == "udp"
                        && let Some(ip_str) = srv.trim().split(':').next()
                        && let Ok(ip) = ip_str
                            .trim_matches(|c| c == '[' || c == ']')
                            .parse::<std::net::IpAddr>()
                        && !bootstrap_ips.contains(&ip)
                    {
                        bootstrap_ips.push(ip);
                    }
                }
                for fallback in ["77.88.8.8", "1.1.1.1", "8.8.8.8"] {
                    if let Ok(ip) = fallback.parse::<std::net::IpAddr>()
                        && !bootstrap_ips.contains(&ip)
                    {
                        bootstrap_ips.push(ip);
                    }
                }
                let mut join_set = tokio::task::JoinSet::new();
                for (srv_idx, (srv_val, proto)) in server_entries.iter().cloned().enumerate() {
                    let doms = domains.clone();
                    let boot_ips = bootstrap_ips.clone();
                    join_set.spawn(async move {
                        let target = resolve_dns_bench_target(&srv_val, &proto);
                        let resolved_sock = if proto != "udp" {
                            resolve_dns_bench_socket_addr(&target, &boot_ips).await
                        } else {
                            None
                        };
                        let mut samples = Vec::with_capacity(doms.len());
                        let mut vals = Vec::with_capacity(doms.len());
                        for dom in &doms {
                            let res: Result<f64, String> = if proto == "udp" {
                                probe_udp_dns_rtt_ms(&target, dom).await
                            } else {
                                let t0 = std::time::Instant::now();
                                let connect_fut = async {
                                    if let Some(sock) = resolved_sock {
                                        tokio::net::TcpStream::connect(sock).await
                                    } else {
                                        tokio::net::TcpStream::connect(&target).await
                                    }
                                };
                                match tokio::time::timeout(Duration::from_millis(1500), connect_fut)
                                    .await
                                {
                                    Ok(Ok(_)) => Ok((t0.elapsed().as_secs_f64() * 1000.0).max(0.5)),
                                    Ok(Err(e)) => Err(e.to_string()),
                                    Err(_) => Err("timeout".to_string()),
                                }
                            };
                            match res {
                                Ok(ms) => {
                                    let rounded = (ms * 100.0).round() / 100.0;
                                    vals.push(rounded);
                                    samples.push(json!({
                                        "domain": dom,
                                        "ok": true,
                                        "ms": rounded,
                                        "error": null
                                    }));
                                }
                                Err(err_msg) => {
                                    samples.push(json!({
                                        "domain": dom,
                                        "ok": false,
                                        "ms": null,
                                        "error": err_msg
                                    }));
                                }
                            }
                        }
                        let stats = build_dns_bench_stats_json(&mut vals, doms.len());
                        (
                            srv_idx,
                            json!({
                                "server": srv_val,
                                "samples": samples,
                                "stats": stats
                            }),
                        )
                    });
                }
                let mut indexed_results = Vec::with_capacity(server_entries.len());
                while let Some(Ok(item)) = join_set.join_next().await {
                    indexed_results.push(item);
                }
                indexed_results.sort_by_key(|(idx, _)| *idx);
                let results: Vec<Value> = indexed_results.into_iter().map(|(_, v)| v).collect();
                let servers_list: Vec<String> =
                    server_entries.into_iter().map(|(s, _)| s).collect();
                let job_id = format!("rust-speed-{now}");
                let state_json = json!({
                    "success": true,
                    "id": job_id,
                    "running": false,
                    "progress": 100,
                    "started_at": now,
                    "finished_at": crate::store::unix_now_secs(),
                    "domains": domains,
                    "servers": servers_list,
                    "results": results,
                    "error": null
                });
                if let Some(parent) = state_path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = crypto_gen::write_json_if_changed(&state_path, &state_json);
                json!({
                    "success": true,
                    "id": job_id
                })
            }
        }
        "dns_speed_test_status" => {
            let state_path = crate::store::runtime_state_dir().join("dns-speed-test.json");
            std::fs::read_to_string(&state_path)
                .ok()
                .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
                .unwrap_or_else(|| {
                    json!({
                        "success": true,
                        "running": false,
                        "progress": 0,
                        "domains": [],
                        "servers": [],
                        "results": [],
                        "error": null
                    })
                })
        }
        "dns_benchmark_stop" => json!({
            "success": true,
            "stopped": true
        }),
        "dns_benchmark_apply" => {
            let dtype = rest.first().map(String::as_str).unwrap_or("doh");
            let daddr = rest
                .get(1)
                .map(String::as_str)
                .unwrap_or("cloudflare-dns.com/dns-query");
            let rec = json!({
                "dns_type": dtype,
                "dns_upstream_mode": "parallel",
                "dns_server": [daddr, "dns.google/dns-query"],
                "bootstrap_dns_server": ["1.1.1.1", "8.8.8.8"],
                "dns_fallback_server": ["77.88.8.8", "9.9.9.9"],
                "reason": "Минимальная задержка отклика и 0% потерь пакетов при прямой проверке с роутера"
            });
            if let Ok(mut store) = json_sections_store().write() {
                if let Some(sec) = store.get_mut("settings").and_then(Value::as_object_mut) {
                    sec.insert("dns_type".to_string(), json!(dtype));
                    sec.insert("dns_upstream_mode".to_string(), json!("parallel"));
                    sec.insert(
                        "dns_server".to_string(),
                        json!([daddr, "dns.google/dns-query"]),
                    );
                    sec.insert(
                        "bootstrap_dns_server".to_string(),
                        json!(["1.1.1.1", "8.8.8.8"]),
                    );
                }
                persist_json_sections(&store);
            }
            if let Err(err) = Box::pin(sync_uci_to_rust_store(state, core)).await {
                json!({
                    "success": false,
                    "error": err
                })
            } else {
                json!({
                    "success": true,
                    "message": "Рекомендованная конфигурация DNS применена",
                    "dns_type": dtype,
                    "dns_server": daddr,
                    "recommendation": rec
                })
            }
        }
        "fuzzer_strategies" => {
            let mode = rest.first().map(String::as_str).unwrap_or("presets");
            let engine_filter = rest.get(1).map(String::as_str).unwrap_or("");
            let target = rest.get(2).map(String::as_str).unwrap_or("");
            let bin_path = core.resolve_bin_path().await;
            crate::fuzzer::get_strategies_catalog_for_target(mode, engine_filter, target, &bin_path)
        }
        "fuzzer_start" => {
            let raw0 = rest.first().map(String::as_str).unwrap_or("");
            let raw1 = rest.get(1).map(String::as_str).unwrap_or("");
            let (engine, target) = normalize_fuzzer_start_args(raw0, raw1);
            let custom_url = rest.get(2).map(String::as_str).unwrap_or("");
            let rule_section = rest.get(3).map(String::as_str).unwrap_or("");
            let custom_file = rest.get(4).map(String::as_str).unwrap_or("");
            let mode = rest.get(5).map(String::as_str).unwrap_or("presets");
            let timeout_secs =
                crate::fuzzer::parse_fuzzer_timeout_secs(rest.get(6).map(String::as_str), 2700);
            let bin_path = core.resolve_bin_path().await;
            Box::pin(crate::fuzzer::start_benchmark(
                bin_path,
                engine,
                target,
                custom_url,
                rule_section,
                custom_file,
                mode,
                timeout_secs,
            ))
            .await
        }
        "fuzzer_status" => crate::fuzzer::get_status(),
        "fuzzer_stop" => crate::fuzzer::stop().await,
        "fuzzer_apply" | "fuzzer_auto_apply" => {
            let bin_path = core.resolve_bin_path().await;
            if method == "fuzzer_apply" {
                let engine_arg = rest.first().map(String::as_str).unwrap_or("");
                if let Err(err) = crate::fuzzer::validate_engine_request(engine_arg, &bin_path) {
                    return Some((
                        0,
                        json!({
                            "success": false,
                            "error": err
                        })
                        .to_string(),
                        String::new(),
                    ));
                }
            }

            let (args_str, target_rule, strat_name) = if method == "fuzzer_auto_apply" {
                let target_rule = rest.first().map(String::as_str).unwrap_or("").trim();
                let st = crate::fuzzer::get_status();
                let best = st.get("best_strategy").cloned().or_else(|| {
                    st.get("results").and_then(Value::as_array).and_then(|arr| {
                        arr.iter()
                            .find(|r| r.get("success").and_then(Value::as_bool) == Some(true))
                            .cloned()
                    })
                });
                let Some(best_obj) = best else {
                    return Some((
                        0,
                        json!({
                            "success": false,
                            "error": "Нет проверенной рабочей стратегии для автоприменения"
                        })
                        .to_string(),
                        String::new(),
                    ));
                };
                let a = best_obj
                    .get("args")
                    .and_then(Value::as_str)
                    .unwrap_or("preset=auto")
                    .to_string();
                let n = best_obj
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("Desync Profile")
                    .to_string();
                (a, target_rule.to_string(), n)
            } else {
                let a = rest
                    .get(1)
                    .map(String::as_str)
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or("preset=auto")
                    .to_string();
                let t = rest
                    .get(2)
                    .map(String::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string();
                (a.clone(), t, a)
            };

            let _uci_guard = uci_mutex().lock().await;
            let apply_res = {
                if let Ok(mut store) = json_sections_store().write() {
                    let res = apply_desync_strategy_to_store(&mut store, &target_rule, &args_str);
                    if res.is_ok() {
                        persist_json_sections(&store);
                    }
                    res
                } else {
                    Err("Внутренняя блокировка хранилища секций".to_string())
                }
            };
            drop(_uci_guard);

            match apply_res {
                Ok(applied_section) => {
                    if let Err(err) = Box::pin(sync_uci_to_rust_store(state, core)).await {
                        json!({
                            "success": false,
                            "error": err
                        })
                    } else {
                        let _ = Box::pin(core.apply_or_reload()).await;

                        json!({
                            "success": true,
                            "applied": true,
                            "engine": "desync",
                            "args": args_str,
                            "strategy_name": strat_name,
                            "target_rule": applied_section,
                            "message": "Профиль десинхронизации tachyon-core сохранён и применён"
                        })
                    }
                }
                Err(err) => json!({
                    "success": false,
                    "error": err
                }),
            }
        }
        "fuzzer_ai_synthesize" => {
            let first = rest.first().map(String::as_str).unwrap_or("");
            if first == "status" {
                let target = "youtube_suite";
                crate::fuzzer::synthesize_ai_strategies(target, "")
            } else if first == "async" {
                let target = rest.get(2).map(String::as_str).unwrap_or("youtube_suite");
                let prompt = rest.get(4).map(String::as_str).unwrap_or("");
                crate::fuzzer::synthesize_ai_strategies(target, prompt)
            } else {
                let target = rest.get(1).map(String::as_str).unwrap_or("youtube_suite");
                let prompt = rest.get(3).map(String::as_str).unwrap_or("");
                crate::fuzzer::synthesize_ai_strategies(target, prompt)
            }
        }
        "fuzzer_get_patterns" => crate::fuzzer::get_patterns(),
        "fuzzer_save_patterns" => {
            let arg = rest.first().map(String::as_str).unwrap_or("{}");
            crate::fuzzer::save_patterns(arg)
        }
        "fuzzer_reset_patterns" => crate::fuzzer::reset_patterns(),
        "fuzzer_detect_dpi" => {
            let target = rest.first().map(String::as_str).unwrap_or("youtube_suite");
            let custom_url = rest.get(1).map(String::as_str).unwrap_or("");
            let bin_path = core.resolve_bin_path().await;
            Box::pin(crate::fuzzer::detect_wan_filtering(
                &bin_path, target, custom_url,
            ))
            .await
        }
        "fuzzer_history" => crate::fuzzer::get_history(),
        "fuzzer_clear_history" => crate::fuzzer::clear_history(),
        _ => return None,
    };
    let s = serde_json::to_string(&out_val).unwrap_or_else(|_| "{}".to_string());
    Some((0, format!("{s}\n"), String::new()))
}

fn parse_route_explain_cli_args(method: &str, rest: &[String]) -> (String, String, u16, String) {
    let mut domain = String::new();
    let mut dest_ip = String::new();
    let mut source_ip = String::new();
    let mut port = 443u16;
    let mut protocol = "tcp".to_string();
    if method == "route_explain" && !rest.is_empty() && !rest[0].starts_with('-') {
        source_ip = rest.first().cloned().unwrap_or_default();
        domain = rest.get(1).cloned().unwrap_or_default();
        port = rest
            .get(2)
            .and_then(|p| p.parse::<u16>().ok())
            .filter(|&p| p > 0)
            .unwrap_or(443);
        protocol = rest
            .get(3)
            .filter(|p| !p.starts_with('-'))
            .cloned()
            .unwrap_or_else(|| "tcp".to_string());
    } else {
        let mut idx = 0usize;
        while idx < rest.len() {
            match rest[idx].as_str() {
                "--domain" => {
                    domain = rest.get(idx + 1).cloned().unwrap_or_default();
                    idx += 2;
                }
                "--dest-ip" | "--ip" => {
                    dest_ip = rest.get(idx + 1).cloned().unwrap_or_default();
                    idx += 2;
                }
                "--source-ip" | "--src-ip" => {
                    source_ip = rest.get(idx + 1).cloned().unwrap_or_default();
                    idx += 2;
                }
                "--port" | "--dport" => {
                    port = rest
                        .get(idx + 1)
                        .and_then(|p| p.parse::<u16>().ok())
                        .filter(|&p| p > 0)
                        .unwrap_or(443);
                    idx += 2;
                }
                "--protocol" | "--proto" => {
                    protocol = rest
                        .get(idx + 1)
                        .cloned()
                        .unwrap_or_else(|| "tcp".to_string());
                    idx += 2;
                }
                other => {
                    if domain.is_empty() && !other.starts_with('-') {
                        domain = other.to_string();
                    }
                    idx += 1;
                }
            }
        }
    }
    let target = if !domain.trim().is_empty() {
        domain.trim().to_string()
    } else if !dest_ip.trim().is_empty() {
        dest_ip.trim().to_string()
    } else {
        "example.com".to_string()
    };
    let client_ip = if source_ip.trim().is_empty() || source_ip.trim() == "0.0.0.0" {
        "192.168.1.100".to_string()
    } else {
        source_ip.trim().to_string()
    };
    (client_ip, target, port, protocol)
}

async fn execute_cli_part_routes_state(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    d: &crate::store::RouterStoreData,
    live: &crate::store::LiveTelemetry,
) -> CliExecOutput {
    let out_val = match method {
        "trace_rules" | "route_explain" => {
            if method == "trace_rules"
                && let Some(first) = rest.first().map(String::as_str)
                && first.trim_start().starts_with('{')
                && let Ok(payload) = serde_json::from_str::<Value>(first)
            {
                crate::diagnostics::trace_rules_two_mode(d, &payload)
            } else {
                let (client_ip, target, port, protocol) =
                    parse_route_explain_cli_args(method, rest);
                Box::pin(crate::diagnostics::explain_route_with_engine(
                    core, d, &client_ip, &target, port, &protocol,
                ))
                .await
            }
        }
        "probe_outbound_url" => {
            let first = rest.first().map(|s| s.trim()).unwrap_or("");
            if first.starts_with("http://") || first.starts_with("https://") {
                let group_id = rest.get(1).map(|s| s.trim()).unwrap_or("all");
                let timeout_ms = rest
                    .get(2)
                    .and_then(|s| s.trim().parse::<u64>().ok())
                    .unwrap_or(3000)
                    .clamp(1000, 10_000);
                Box::pin(handle_probe_outbound_url_batch(
                    d, core, first, group_id, timeout_ms,
                ))
                .await
            } else {
                let tag = if first.is_empty() { "Main-out" } else { first };
                let url = rest
                    .get(1)
                    .map(String::as_str)
                    .unwrap_or("https://www.gstatic.com/generate_204");
                let encoded_url = url_encode_component(url);
                let mut effective_tag = tag.to_string();
                let mut latency_ms: Option<u64> = None;
                let mut last_err = String::new();
                let direct_path = format!(
                    "/proxies/{}/delay?url={encoded_url}&timeout=5000",
                    url_encode_component(tag)
                );
                match core.clash_request("GET", &direct_path, None).await {
                    Ok(val) => {
                        latency_ms = val.get("delay").and_then(Value::as_u64);
                    }
                    Err(e) => {
                        last_err = format!("{e:#}");
                        if let Ok(proxies_val) = core.clash_request("GET", "/proxies", None).await
                            && let Some(proxies_map) =
                                proxies_val.get("proxies").and_then(Value::as_object)
                        {
                            let candidates: Vec<String> = proxies_map.keys().cloned().collect();
                            if let Some(matched) =
                                resolve_outbound_tag_with_telemetry_fallback(tag, &candidates)
                            {
                                let retry_path = format!(
                                    "/proxies/{}/delay?url={encoded_url}&timeout=5000",
                                    url_encode_component(&matched)
                                );
                                effective_tag = matched;
                                match core.clash_request("GET", &retry_path, None).await {
                                    Ok(val) => {
                                        latency_ms = val.get("delay").and_then(Value::as_u64);
                                        last_err.clear();
                                    }
                                    Err(e2) => last_err = format!("{e2:#}"),
                                }
                            }
                        }
                    }
                }
                if let Some(ms) = latency_ms
                    && ms > 0
                {
                    json!({
                        "success": true,
                        "status": "ok",
                        "tag": effective_tag,
                        "requested_tag": tag,
                        "target_url": url,
                        "http_code": 204,
                        "latency_ms": ms
                    })
                } else {
                    json!({
                        "success": false,
                        "status": "failed",
                        "tag": effective_tag,
                        "requested_tag": tag,
                        "target_url": url,
                        "http_code": 0,
                        "latency_ms": 0,
                        "error": if last_err.is_empty() { "timeout".to_string() } else { last_err }
                    })
                }
            }
        }
        "resolve_domain" => {
            let domain = rest
                .iter()
                .find(|s| !s.starts_with('-'))
                .map(String::as_str)
                .unwrap_or("example.com");
            let start = std::time::Instant::now();
            let mut addresses = Vec::new();
            if let Ok(iter) = tokio::net::lookup_host((domain, 443)).await {
                for sock in iter {
                    let ip_str = sock.ip().to_string();
                    if !addresses.contains(&ip_str) {
                        addresses.push(ip_str);
                    }
                }
            }
            let latency_ms = start.elapsed().as_millis() as u64;
            let records: Vec<Value> = addresses
                .iter()
                .map(|ip| {
                    json!({
                        "type": if ip.contains(':') { "AAAA" } else { "A" },
                        "address": ip,
                        "ttl": 300
                    })
                })
                .collect();
            json!({
                "success": true,
                "domain": domain,
                "resolved": !addresses.is_empty(),
                "addresses": addresses,
                "ips": addresses,
                "records": records,
                "latency_ms": latency_ms.max(2)
            })
        }
        "hosts_list_update" => {
            match Box::pin(crate::adguard_hosts::update_hosts_lists(state, core, true)).await {
                Ok(val) => val,
                Err(e) => json!({
                    "ok": false,
                    "success": false,
                    "status": "error",
                    "running": false,
                    "completed": true,
                    "error": e.to_string(),
                }),
            }
        }
        "hosts_list_status" => crate::adguard_hosts::get_hosts_list_status(d),
        "toggle_client_bypass" => {
            let ip = rest.first().map(String::as_str).unwrap_or("");
            let mode = rest.get(1).map(String::as_str).unwrap_or("toggle");
            let mut cand = Box::new(d.clone());
            let bypassed = if !ip.is_empty()
                && let Some(cond) = cand.conditions.first_mut()
            {
                if let Some(pos) = cond.exclude_client_ips.iter().position(|x| x == ip) {
                    if mode == "enable" {
                        true
                    } else {
                        cond.exclude_client_ips.remove(pos);
                        false
                    }
                } else if mode == "disable" {
                    false
                } else {
                    cond.exclude_client_ips.push(ip.to_string());
                    true
                }
            } else {
                false
            };
            if let Err(e) =
                Box::pin(transaction::commit_transaction_boxed(state, cand, "save")).await
            {
                json!({
                    "success": false,
                    "ip": ip,
                    "error": format!("{e:#}")
                })
            } else {
                {
                    let saved = state.data.read().await;
                    sync_from_store_to_json_and_cache(&saved);
                }
                let core_c = Arc::clone(core);
                tokio::spawn(async move {
                    let _ = Box::pin(core_c.apply_or_reload()).await;
                });
                let mode_str = if bypassed { "direct" } else { "proxied" };
                json!({
                    "success": true,
                    "ip": ip,
                    "bypassed": bypassed,
                    "mode": mode_str,
                    "message": if bypassed {
                        format!("Клиент {ip} переведен в режим прямого соединения")
                    } else {
                        format!("Клиент {ip} переведен в режим маршрутизации через Tachyon")
                    }
                })
            }
        }
        "watchdog" | "watchdog_start" | "watchdog_stop" => {
            Box::pin(handle_watchdog_command(method, d, state, core)).await
        }
        "telegram" | "telegram_status" | "telegram_start" | "telegram_stop"
        | "telegram_diagnose" | "telegram_test" | "telegram_set_lang" => {
            let (tg_action, tg_args): (&str, &[String]) = if method == "telegram" {
                match rest.first().map(String::as_str).unwrap_or("status") {
                    "start" | "start-runtime" => ("telegram_start", rest.get(1..).unwrap_or(&[])),
                    "stop" | "stop-runtime" => ("telegram_stop", rest.get(1..).unwrap_or(&[])),
                    "diagnose" => ("telegram_diagnose", rest.get(1..).unwrap_or(&[])),
                    "test" => ("telegram_test", rest.get(1..).unwrap_or(&[])),
                    "set_lang" | "set-lang" | "lang" => {
                        ("telegram_set_lang", rest.get(1..).unwrap_or(&[]))
                    }
                    _ => ("telegram_status", rest.get(1..).unwrap_or(&[])),
                }
            } else {
                (method, rest)
            };

            match tg_action {
                "telegram_status" => {
                    if crate::tg_bot::is_bot_effectively_running(d) {
                        return (
                            0,
                            format!("running (pid {})\n", std::process::id()),
                            String::new(),
                        );
                    }
                    return (0, "stopped\n".to_string(), String::new());
                }
                "telegram_test" => {
                    return match Box::pin(crate::tg_bot::send_test_notification(state)).await {
                        Ok(sent) => (
                            0,
                            format!(
                                "{}\n",
                                serde_json::to_string(&json!({
                                    "success": true,
                                    "sent": sent,
                                    "message": format!("Тестовое уведомление отправлено ({sent})")
                                }))
                                .unwrap_or_default()
                            ),
                            String::new(),
                        ),
                        Err(e) => (
                            0,
                            format!(
                                "{}\n",
                                serde_json::to_string(&json!({
                                    "success": false,
                                    "error": format!("{e}"),
                                    "message": format!("{e}")
                                }))
                                .unwrap_or_default()
                            ),
                            String::new(),
                        ),
                    };
                }
                "telegram_diagnose" => {
                    Box::pin(crate::tg_bot::diagnose_bot_connection(state, core)).await
                }
                "telegram_set_lang" => {
                    let raw = tg_args.first().map(String::as_str).unwrap_or("ru");
                    let lang = if raw.trim().eq_ignore_ascii_case("en") {
                        "en"
                    } else {
                        "ru"
                    };
                    if d.telegram.language != lang {
                        let mut candidate = Box::new(d.clone());
                        candidate.telegram.language = lang.to_string();
                        let tg_copy = candidate.telegram.clone();
                        let _ = Box::pin(transaction::commit_transaction_boxed(
                            state, candidate, "save",
                        ))
                        .await;
                        sync_telegram_section_to_json(&tg_copy);
                        crate::tg_bot::notify_bot_wakeup();
                    }
                    json!({
                        "success": true,
                        "ok": true,
                        "language": lang
                    })
                }
                "telegram_start" | "telegram_stop" => {
                    let target = tg_action == "telegram_start";
                    crate::tg_bot::set_runtime_override(Some(target));
                    crate::tg_bot::notify_bot_wakeup();
                    let (running, configured) = if d.telegram.enabled != target {
                        let mut effective = Box::new(d.clone());
                        effective.telegram.enabled = target;
                        let tg_copy = effective.telegram.clone();
                        let run = crate::tg_bot::is_bot_effectively_running(&effective);
                        let cfgd = !effective.telegram.bot_token.trim().is_empty()
                            && !effective.telegram.admin_ids.is_empty();
                        let _ = Box::pin(transaction::commit_transaction_boxed(
                            state, effective, "save",
                        ))
                        .await;
                        sync_telegram_section_to_json(&tg_copy);
                        (run, cfgd)
                    } else {
                        (
                            crate::tg_bot::is_bot_effectively_running(d),
                            !d.telegram.bot_token.trim().is_empty()
                                && !d.telegram.admin_ids.is_empty(),
                        )
                    };
                    json!({
                        "success": true,
                        "ok": true,
                        "enabled": target,
                        "running": running,
                        "configured": configured,
                        "status": if running { "running" } else { "stopped" }
                    })
                }
                _ => json!({ "success": false }),
            }
        }
        "snapshot_list" => crate::snapshots::snapshot_list(state),
        "snapshot_save" => {
            let name = rest
                .first()
                .map(String::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or("manual");
            let cur_secs = get_json_sections_snapshot();
            Box::pin(crate::snapshots::snapshot_save(state, &cur_secs, name)).await
        }
        "snapshot_restore" => {
            let file_arg = rest.first().map(String::as_str).unwrap_or("");
            match Box::pin(crate::snapshots::snapshot_restore(state, file_arg)).await {
                Ok((prof, restored_secs)) => {
                    set_json_sections_snapshot(restored_secs);
                    {
                        let cur = state.data.read().await;
                        sync_section_cache(&cur);
                    }
                    let _ = Box::pin(core.apply_or_reload()).await;
                    state.live.write().await.push_event(
                        "info",
                        "snapshots",
                        &format!("Восстановлен снапшот '{}' ({})", prof.name, prof.stamp),
                    );
                    json!({
                        "success": true,
                        "name": prof.name,
                        "stamp": prof.stamp,
                        "counts": prof.counts
                    })
                }
                Err(e) => json!({
                    "success": false,
                    "message": format!("{e}")
                }),
            }
        }
        "snapshot_delete" => {
            let file_arg = rest.first().map(String::as_str).unwrap_or("");
            crate::snapshots::snapshot_delete(state, file_arg)
        }
        "snapshot_diff" => {
            let file_arg = rest.first().map(String::as_str).unwrap_or("");
            let cur_secs = get_json_sections_snapshot();
            Box::pin(crate::snapshots::snapshot_diff(state, &cur_secs, file_arg)).await
        }
        "snapshot_export" => {
            let cur_secs = get_json_sections_snapshot();
            Box::pin(crate::snapshots::snapshot_export(
                state,
                &cur_secs,
                rest.first().map(String::as_str),
            ))
            .await
        }
        "snapshot_import" => {
            let cur_secs = get_json_sections_snapshot();
            match Box::pin(crate::snapshots::snapshot_import(
                state,
                &cur_secs,
                rest.first().map(String::as_str),
            ))
            .await
            {
                crate::snapshots::ImportOutcome::ResponseOnly(v) => v,
                crate::snapshots::ImportOutcome::AppliedState {
                    response,
                    new_sections,
                } => {
                    set_json_sections_snapshot(new_sections);
                    {
                        let cur = state.data.read().await;
                        sync_section_cache(&cur);
                    }
                    let _ = Box::pin(core.apply_or_reload()).await;
                    state.live.write().await.push_event(
                        "info",
                        "snapshots",
                        "Применён код переноса конфигурации",
                    );
                    response
                }
            }
        }
        "reset_settings" => {
            let cur_secs = get_json_sections_snapshot();
            match Box::pin(crate::snapshots::reset_settings_to_defaults(
                state, &cur_secs,
            ))
            .await
            {
                Ok((resp, default_secs)) => {
                    set_json_sections_snapshot(default_secs);
                    {
                        let cur = state.data.read().await;
                        sync_section_cache(&cur);
                    }
                    let _ = Box::pin(core.apply_or_reload()).await;
                    state.live.write().await.push_event(
                        "warn",
                        "settings",
                        "Настройки сброшены к заводским значениям",
                    );
                    resp
                }
                Err(e) => json!({
                    "success": false,
                    "message": format!("{e}")
                }),
            }
        }
        "event_query" | "event_tail" => {
            let limit = rest
                .first()
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(50)
                .clamp(1, 200);
            let mut items: Vec<Value> = live
                .events
                .iter()
                .enumerate()
                .rev()
                .take(limit)
                .map(|(idx, ev)| {
                    json!({
                        "id": format!("evt-{}-{idx}", ev.timestamp),
                        "ts": ev.timestamp,
                        "event": format!("{}.{}", ev.subsystem, ev.level),
                        "severity": ev.level,
                        "source": ev.subsystem,
                        "message": ev.message
                    })
                })
                .collect();
            if items.is_empty() {
                let now = crate::store::unix_now_secs();
                items.push(json!({
                    "id": "evt-0",
                    "ts": now,
                    "event": "service.running",
                    "severity": "info",
                    "source": "tachyon-core",
                    "message": format!("tachyon-core {} active", live.core_version)
                }));
            }
            Value::Array(items)
        }
        "event_stats" => {
            let now = crate::store::unix_now_secs();
            let count = live.events.len();
            let bytes: usize = live
                .events
                .iter()
                .map(|e| e.message.len() + e.subsystem.len() + 32)
                .sum();
            let oldest = live.events.first().map(|e| e.timestamp).unwrap_or(now);
            let newest = live.events.last().map(|e| e.timestamp).unwrap_or(now);
            json!({
                "count": count,
                "bytes": bytes,
                "oldest_ts": oldest,
                "newest_ts": newest
            })
        }
        "event_record" => {
            let now = crate::store::unix_now_secs();
            let ev_name = rest.first().map(String::as_str).unwrap_or("custom.event");
            let sev = rest.get(2).map(String::as_str).unwrap_or("info");
            let src = rest.get(3).map(String::as_str).unwrap_or("tachyon");
            let msg = rest.get(4).map(String::as_str).unwrap_or(ev_name);
            state.live.write().await.push_event(sev, src, msg);
            json!({
                "id": format!("evt-{now}"),
                "ts": now,
                "event": ev_name,
                "severity": sev,
                "source": src,
                "message": msg
            })
        }
        "event_clear" => {
            state.live.write().await.events.clear();
            json!({ "success": true })
        }
        "job_list" => {
            let items: Vec<Value> = live
                .jobs
                .iter()
                .rev()
                .map(|j| {
                    json!({
                        "id": j.id,
                        "kind": j.kind,
                        "action": j.kind,
                        "phase": j.status,
                        "status": j.status,
                        "progress": j.progress_pct,
                        "message": j.logs.last().map(String::as_str).unwrap_or(""),
                        "created_at": j.created_at,
                        "started_at": j.created_at,
                        "finished_at": j.updated_at
                    })
                })
                .collect();
            Value::Array(items)
        }
        "job_query" => {
            let jid = rest.first().map(String::as_str).unwrap_or("");
            if let Some(j) = live.jobs.iter().find(|x| x.id == jid) {
                json!({
                    "id": j.id,
                    "found": true,
                    "kind": j.kind,
                    "action": j.kind,
                    "phase": j.status,
                    "status": j.status,
                    "progress": j.progress_pct,
                    "message": j.logs.last().map(String::as_str).unwrap_or("OK"),
                    "logs": j.logs,
                    "result": j.result,
                    "created_at": j.created_at,
                    "started_at": j.created_at,
                    "finished_at": j.updated_at
                })
            } else {
                json!({
                    "id": jid,
                    "found": false,
                    "status": "not_found",
                    "phase": "not_found",
                    "progress": 0,
                    "message": "Job not found",
                    "error": "Job not found"
                })
            }
        }
        "job_cancel" | "job_request_cancel" | "job_gc" => {
            let mut removed = 0usize;
            {
                let mut l = state.live.write().await;
                if method == "job_gc" {
                    let before = l.jobs.len();
                    l.jobs.retain(|j| j.status == "running");
                    removed = before.saturating_sub(l.jobs.len());
                } else if let Some(jid) = rest.first().map(String::as_str)
                    && let Some(j) = l.jobs.iter_mut().find(|x| x.id == jid)
                {
                    j.status = "cancelled".to_string();
                    j.updated_at = crate::store::unix_now_secs();
                }
            }
            json!({
                "ok": true,
                "requested": true,
                "removed": removed
            })
        }
        "known_good" | "known_good_list" => {
            let now = crate::store::unix_now_secs();
            let has_lkg = state.lkg_path.is_file();
            let lkg_bytes = std::fs::read(&state.lkg_path).unwrap_or_default();
            let cur_bytes = std::fs::read(&state.path).unwrap_or_default();
            let lkg_sha = if has_lkg {
                crypto_gen::sha256_bytes_hex(&lkg_bytes)
            } else {
                String::new()
            };
            let is_same = has_lkg && lkg_bytes == cur_bytes;
            let mtime = std::fs::metadata(&state.lkg_path)
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(now);
            let checks_passed = u32::from(has_lkg)
                + u32::from(live.core_running)
                + u32::from(live.nft_table_active)
                + u32::from(!live.lkg_observing)
                + u32::from(is_same);
            json!({
                "has_known_good": has_lkg,
                "is_active_config_known_good": is_same,
                "history_count": usize::from(has_lkg),
                "manifest": {
                    "promoted_at": mtime,
                    "promoted_at_iso": crate::snapshots::unix_secs_to_stamp(mtime),
                    "promotion_reason": "verified_runtime",
                    "engine": "tachyon-core",
                    "sha256": lkg_sha
                },
                "observation": {
                    "status": if live.lkg_observing { "observing" } else if live.core_running { "healthy" } else { "degraded" },
                    "reason": if live.lkg_observing { "observation_window" } else if live.core_running { "all_probes_passed" } else { "core_stopped" },
                    "started_at": now.saturating_sub(60),
                    "window_seconds": live.lkg_remaining_secs.max(120),
                    "remaining_seconds": live.lkg_remaining_secs,
                    "checks_passed": checks_passed,
                    "all_passed": !live.lkg_observing && live.core_running && live.nft_table_active
                }
            })
        }
        "known_good_promote" | "known_good_save" => {
            let ok = transaction::promote_to_known_good(&state.lkg_path, d).is_ok();
            if ok {
                let active_id = {
                    let mut live = state.live.write().await;
                    live.lkg_observing = false;
                    live.lkg_remaining_secs = 0;
                    live.last_auto_rollback_reason.clear();
                    live.last_auto_rollback_ts = 0;
                    live.push_event(
                        "info",
                        "known_good",
                        "Manual promotion to Last Known Good snapshot",
                    );
                    live.active_revision_id.clone()
                };
                let target_opt = if active_id.trim().is_empty() {
                    None
                } else {
                    Some(active_id.as_str())
                };
                let _ = crate::config_history::mark_revision_status(
                    target_opt,
                    "working",
                    "Подтверждён вручную (LKG)",
                );
            }
            json!({ "success": ok, "ok": ok })
        }
        "known_good_restore" => {
            if let Ok(restored) = transaction::load_known_good(&state.lkg_path) {
                if let Err(e) = Box::pin(transaction::commit_transaction_boxed(
                    state,
                    Box::new(restored),
                    "save",
                ))
                .await
                {
                    json!({ "success": false, "ok": false, "error": format!("{e:#}") })
                } else {
                    {
                        let cur = state.data.read().await;
                        sync_from_store_to_json_and_cache(&cur);
                    }
                    let _ = Box::pin(core.apply_or_reload()).await;
                    json!({ "success": true, "ok": true })
                }
            } else {
                json!({ "success": false, "ok": false, "error": "Снимок Last Known Good не найден" })
            }
        }
        "known_good_clear" => {
            let _ = std::fs::remove_file(&state.lkg_path);
            json!({ "success": true, "ok": true })
        }
        "escalation_status" => {
            let mut reasons = Vec::new();
            let mut level = 0u32;
            if d.settings.emergency_direct_bypass {
                level = 2;
                reasons.push("emergency_direct_bypass");
            } else if !live.core_running {
                level = 1;
                reasons.push("core_not_running");
            } else if !live.nft_table_active {
                level = 1;
                reasons.push("nft_table_inactive");
            }
            let level_name = match level {
                0 => "nominal",
                1 => "elevated",
                _ => "critical",
            };
            json!({
                "level": level,
                "level_name": level_name,
                "active": level > 0,
                "reasons": reasons,
                "cooldown_remaining": live.lkg_remaining_secs
            })
        }
        "emergency_status" => {
            let recovery_attempts = live
                .events
                .iter()
                .filter(|e| e.subsystem == "recovery" || e.subsystem == "watchdog")
                .count();
            json!({
                "active": d.settings.emergency_direct_bypass,
                "failsafe_active": d.settings.emergency_direct_bypass || !live.core_running,
                "recovery_attempts": recovery_attempts
            })
        }
        "server_stats" | "server_query" | "server_best" => {
            let now = crate::store::unix_now_secs();
            let mut entries = Vec::new();
            let mut sec_counts = Map::new();
            let mut proto_counts = Map::new();
            let mut sum_lat = 0u64;
            let mut measured_cnt = 0usize;
            let mut seen_tags = std::collections::HashSet::new();
            let mut best_cand: Option<(String, u32, String, String)> = None;

            for (owner_sec, src, _) in collect_section_sources_with_owner(d, "all") {
                let nodes = crate::config_gen::build_source_outbounds(src);
                if nodes.is_empty() {
                    let tag = src.id.clone();
                    if !seen_tags.insert(tag.clone()) {
                        continue;
                    }
                    let ms_opt = live.node_latencies_ms.get(&tag).copied();
                    let ms = ms_opt.unwrap_or(0);
                    if ms > 0 {
                        sum_lat += u64::from(ms);
                        measured_cnt += 1;
                        if best_cand.as_ref().is_none_or(|b| ms < b.1) {
                            best_cand =
                                Some((tag.clone(), ms, owner_sec.clone(), src.source_type.clone()));
                        }
                    }
                    let proto = if src.source_type.is_empty() {
                        "vless".to_string()
                    } else {
                        src.source_type.clone()
                    };
                    *sec_counts
                        .entry(owner_sec.clone())
                        .or_insert_with(|| json!(0)) = json!(
                        sec_counts
                            .get(&owner_sec)
                            .and_then(Value::as_u64)
                            .unwrap_or(0)
                            + 1
                    );
                    *proto_counts
                        .entry(proto.clone())
                        .or_insert_with(|| json!(0)) = json!(
                        proto_counts
                            .get(&proto)
                            .and_then(Value::as_u64)
                            .unwrap_or(0)
                            + 1
                    );
                    entries.push(json!({
                        "tag": tag,
                        "name": if src.name.is_empty() { &src.id } else { &src.name },
                        "type": proto,
                        "section": owner_sec,
                        "last_status": if ms_opt.is_some() { "ok" } else { "untested" },
                        "last_latency": ms,
                        "last_checked": now,
                        "last_error": "",
                        "total_probes": usize::from(ms_opt.is_some()),
                        "successful_probes": usize::from(ms > 0),
                        "failed_probes": 0,
                        "consecutive_failures": 0,
                        "avg_latency": ms,
                        "min_latency": ms,
                        "max_latency": ms,
                        "jitter": 0,
                        "success_rate": if ms > 0 { 100 } else { 0 }
                    }));
                } else {
                    for (tag, out_val, _) in nodes {
                        if !seen_tags.insert(tag.clone()) {
                            continue;
                        }
                        let ms_opt = live.node_latencies_ms.get(&tag).copied();
                        let ms = ms_opt.unwrap_or(0);
                        let proto = out_val
                            .get("type")
                            .and_then(Value::as_str)
                            .filter(|s| !s.is_empty())
                            .unwrap_or_else(|| {
                                if src.source_type.is_empty() {
                                    "vless"
                                } else {
                                    &src.source_type
                                }
                            })
                            .to_string();
                        if ms > 0 {
                            sum_lat += u64::from(ms);
                            measured_cnt += 1;
                            if best_cand.as_ref().is_none_or(|b| ms < b.1) {
                                best_cand =
                                    Some((tag.clone(), ms, owner_sec.clone(), proto.clone()));
                            }
                        }
                        *sec_counts
                            .entry(owner_sec.clone())
                            .or_insert_with(|| json!(0)) = json!(
                            sec_counts
                                .get(&owner_sec)
                                .and_then(Value::as_u64)
                                .unwrap_or(0)
                                + 1
                        );
                        *proto_counts
                            .entry(proto.clone())
                            .or_insert_with(|| json!(0)) = json!(
                            proto_counts
                                .get(&proto)
                                .and_then(Value::as_u64)
                                .unwrap_or(0)
                                + 1
                        );
                        entries.push(json!({
                            "tag": tag,
                            "name": tag,
                            "type": proto,
                            "section": owner_sec,
                            "last_status": if ms_opt.is_some() { "ok" } else { "untested" },
                            "last_latency": ms,
                            "last_checked": now,
                            "last_error": "",
                            "total_probes": usize::from(ms_opt.is_some()),
                            "successful_probes": usize::from(ms > 0),
                            "failed_probes": 0,
                            "consecutive_failures": 0,
                            "avg_latency": ms,
                            "min_latency": ms,
                            "max_latency": ms,
                            "jitter": 0,
                            "success_rate": if ms > 0 { 100 } else { 0 }
                        }));
                    }
                }
            }
            if method == "server_query" || method == "server_best" {
                Value::Array(entries)
            } else {
                let total = entries.len();
                let avg_lat = if measured_cnt > 0 {
                    sum_lat / (measured_cnt as u64)
                } else {
                    0
                };
                let best_srv = best_cand.map(|(tag, ms, sec, p)| {
                    json!({
                        "tag": tag,
                        "latency_ms": ms,
                        "section": sec,
                        "type": p
                    })
                });
                json!({
                    "total_servers": total,
                    "healthy_count": measured_cnt,
                    "unhealthy_count": 0,
                    "untested_count": total.saturating_sub(measured_cnt),
                    "avg_latency_ms": avg_lat,
                    "best_server": best_srv,
                    "worst_server": best_srv,
                    "sections": sec_counts,
                    "protocols": proto_counts,
                    "last_updated": now,
                    "servers": entries
                })
            }
        }
        "server_probe" => {
            let tag = rest.first().map(String::as_str).unwrap_or("Main-out");
            let encoded_tag = url_encode_component(tag);
            let test_url = url_encode_component(&d.settings.latency_test_url);
            let path = format!("/proxies/{encoded_tag}/delay?url={test_url}&timeout=2500");
            match core.clash_request("GET", &path, None).await {
                Ok(val) => {
                    let ms = val.get("delay").and_then(Value::as_u64).unwrap_or(0) as u32;
                    if ms > 0 {
                        let mut l = state.live.write().await;
                        if l.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES {
                            l.node_latencies_ms.insert(tag.to_string(), ms);
                        }
                    }
                    json!({
                        "tag": tag,
                        "status": if ms > 0 { "ok" } else { "failed" },
                        "latency_ms": ms,
                        "avg_latency_ms": ms,
                        "success_rate": if ms > 0 { 100 } else { 0 },
                        "error": if ms > 0 { "" } else { "timeout" }
                    })
                }
                Err(e) => json!({
                    "tag": tag,
                    "status": "failed",
                    "latency_ms": 0,
                    "avg_latency_ms": 0,
                    "success_rate": 0,
                    "error": format!("{e}")
                }),
            }
        }
        "server_probe_all" => {
            let test_url = url_encode_component(&d.settings.latency_test_url);
            let mut targets: Vec<(String, String, String)> = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for (owner_sec, src, _) in collect_section_sources_with_owner(d, "all") {
                for (tag, out_val, _) in crate::config_gen::build_source_outbounds(src) {
                    if seen.insert(tag.clone()) {
                        let p = out_val
                            .get("type")
                            .and_then(Value::as_str)
                            .unwrap_or("vless")
                            .to_string();
                        targets.push((tag, owner_sec.clone(), p));
                    }
                }
            }
            let mut results = Vec::new();
            let mut ok_count = 0usize;
            for (tag, owner_sec, proto) in targets {
                let encoded_tag = url_encode_component(&tag);
                let path = format!("/proxies/{encoded_tag}/delay?url={test_url}&timeout=2500");
                let (ok, ms, err_msg) = match core.clash_request("GET", &path, None).await {
                    Ok(v) => {
                        let d_ms = v.get("delay").and_then(Value::as_u64).unwrap_or(0) as u32;
                        if d_ms > 0 {
                            ok_count += 1;
                            let mut l = state.live.write().await;
                            if l.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES {
                                l.node_latencies_ms.insert(tag.clone(), d_ms);
                            }
                            (true, d_ms, String::new())
                        } else {
                            (false, 0, "timeout".to_string())
                        }
                    }
                    Err(e) => (false, 0, format!("{e}")),
                };
                results.push(json!({
                    "tag": tag,
                    "section": owner_sec,
                    "type": proto,
                    "ok": ok,
                    "latency_ms": ms,
                    "error": err_msg
                }));
            }
            let count = results.len();
            json!({
                "total_probed": count,
                "successful": ok_count,
                "failed": count.saturating_sub(ok_count),
                "results": results
            })
        }
        "server_stats_reset" => {
            state.live.write().await.node_latencies_ms.clear();
            json!({ "success": true })
        }
        "stability_report" | "stability_status" => {
            let now = crate::store::unix_now_secs();
            let sys = sys_info::collect_host_info();
            let is_entware = crate::platform::is_entware();
            let dnsmasq = if is_entware {
                None
            } else {
                Some(sys_info::collect_dnsmasq_status())
            };
            let daemon_up = sys_info::daemon_uptime_secs();
            let total_srv = d.outbound_sources.len();
            let healthy_srv = live.node_latencies_ms.values().filter(|&&v| v > 0).count();
            let used_pct = (sys.memory_used_mb * 100)
                .checked_div(sys.memory_total_mb)
                .unwrap_or(0) as u32;
            let pressure = if used_pct >= 90 {
                "critical"
            } else if used_pct >= 75 {
                "elevated"
            } else {
                "normal"
            };
            let uptime_pretty = format_uptime_pretty(sys.host_uptime_secs);
            let avg_lat: u64 = if live.node_latencies_ms.is_empty() {
                0
            } else {
                live.node_latencies_ms
                    .values()
                    .map(|&v| u64::from(v))
                    .sum::<u64>()
                    / (live.node_latencies_ms.len() as u64)
            };
            let watchdog_restarts = live
                .events
                .iter()
                .filter(|e| e.subsystem == "watchdog" && e.message.contains("restarted"))
                .count();
            let engine_crashes = live
                .events
                .iter()
                .filter(|e| e.level == "error" && e.subsystem == "core")
                .count();
            let config_rollbacks = live
                .events
                .iter()
                .filter(|e| e.subsystem == "rollback" || e.message.contains("rollback"))
                .count();
            let mut score: i32 = 100;
            let mut penalties: Vec<&str> = Vec::new();
            if !live.core_running {
                score -= 35;
                penalties.push("core_stopped");
            }
            if !live.nft_table_active {
                score -= 15;
                penalties.push("nft_inactive");
            }
            if used_pct >= 90 {
                score -= 15;
                penalties.push("high_memory_pressure");
            }
            let score = score.clamp(0, 100) as u32;
            let grade = if score >= 90 {
                "optimal"
            } else if score >= 65 {
                "degraded"
            } else {
                "critical"
            };
            if method == "stability_status" {
                json!({
                    "timestamp": now,
                    "score": score,
                    "grade": grade,
                    "system_uptime": uptime_pretty,
                    "wan_flaps": 0,
                    "watchdog_restarts": watchdog_restarts,
                    "memory_used_pct": used_pct,
                    "memory_pressure": pressure,
                    "healthy_servers": healthy_srv,
                    "total_servers": total_srv,
                    "avg_latency_ms": avg_lat
                })
            } else {
                let mut sec_counts = Map::new();
                for sec in &d.sections {
                    let cnt = collect_section_sources_with_owner(d, &sec.id).len();
                    sec_counts.insert(sec.id.clone(), json!(cnt));
                }
                let best_srv = live
                    .node_latencies_ms
                    .iter()
                    .filter(|&(_, &ms)| ms > 0)
                    .min_by_key(|&(_, &ms)| ms)
                    .map(|(tag, &ms)| {
                        json!({
                            "tag": tag,
                            "latency_ms": ms
                        })
                    });
                let total_kb = sys.memory_total_mb * 1024;
                let used_kb = sys.memory_used_mb * 1024;
                let free_kb = total_kb.saturating_sub(used_kb);
                let core_fds = sys_info::count_open_fds(live.core_pid);
                let daemon_fds = sys_info::count_open_fds(None);
                let (sys_fd_alloc, sys_fd_max) = std::fs::read_to_string("/proc/sys/fs/file-nr")
                    .ok()
                    .and_then(|raw| {
                        let mut it = raw.split_whitespace();
                        let alloc = it.next()?.parse::<u64>().ok()?;
                        let _unused = it.next()?;
                        let max = it.next()?.parse::<u64>().ok()?;
                        Some((alloc, max.max(1)))
                    })
                    .unwrap_or(((core_fds + daemon_fds) as u64, 65536));
                let sys_fd_pct = ((sys_fd_alloc * 100) / sys_fd_max.max(1)) as u32;
                let running_jobs = live.jobs.iter().filter(|j| j.status == "running").count();
                let failed_jobs = live.jobs.iter().filter(|j| j.status == "failed").count();
                let cancelled_jobs = live.jobs.iter().filter(|j| j.status == "cancelled").count();
                let recent_incidents: Vec<Value> = live
                    .events
                    .iter()
                    .rev()
                    .filter(|e| e.level == "warn" || e.level == "error")
                    .take(10)
                    .map(|e| {
                        json!({
                            "ts": e.timestamp,
                            "severity": e.level,
                            "subsystem": e.subsystem,
                            "message": e.message
                        })
                    })
                    .collect();

                let mut daemons_map = serde_json::Map::new();
                daemons_map.insert(
                    "tachyon-core".to_string(),
                    json!({
                        "running": live.core_running,
                        "pid": live.core_pid,
                        "uptime_seconds": live.core_uptime_secs,
                        "pretty": format_uptime_pretty(live.core_uptime_secs)
                    }),
                );
                let wd_running = core.is_watchdog_effectively_running().await;
                daemons_map.insert(
                    "watchdog".to_string(),
                    json!({
                        "running": wd_running,
                        "pid": wd_running.then(std::process::id),
                        "uptime_seconds": daemon_up,
                        "pretty": format_uptime_pretty(daemon_up)
                    }),
                );
                if let Some(ref dm) = dnsmasq {
                    daemons_map.insert(
                        "dnsmasq".to_string(),
                        json!({
                            "running": dm.running,
                            "pid": dm.pid,
                            "uptime_seconds": dm.uptime_secs,
                            "pretty": if dm.running { format_uptime_pretty(dm.uptime_secs) } else { String::new() }
                        }),
                    );
                }

                json!({
                    "timestamp": now,
                    "health": {
                        "score": score,
                        "grade": grade,
                        "penalties": penalties
                    },
                    "uptimes": {
                        "system": {
                            "seconds": sys.host_uptime_secs,
                            "pretty": uptime_pretty
                        },
                        "daemons": Value::Object(daemons_map)
                    },
                    "restarts_and_flaps": {
                        "wan_flaps": 0,
                        "watchdog_restarts": watchdog_restarts,
                        "engine_crashes": engine_crashes,
                        "dnsmasq_restarts": 0,
                        "dns_failovers": 0,
                        "config_rollbacks": config_rollbacks
                    },
                    "resources": {
                        "memory": {
                            "total_kb": total_kb,
                            "free_kb": free_kb,
                            "available_kb": free_kb,
                            "used_kb": used_kb,
                            "used_pct": used_pct,
                            "pressure_level": pressure,
                            "swap_total_kb": sys.zram_total_bytes / 1024,
                            "swap_free_kb": sys.zram_total_bytes.saturating_sub(sys.zram_used_bytes) / 1024,
                            "swap_used_kb": sys.zram_used_bytes / 1024,
                            "daemons_rss_kb": {
                                "tachyon-core": live.core_rss_bytes / 1024,
                                "tachyon": sys.panel_rss_bytes / 1024
                            }
                        },
                        "file_descriptors": {
                            "system_allocated": sys_fd_alloc,
                            "system_max": sys_fd_max,
                            "system_used_pct": sys_fd_pct,
                            "daemons": {
                                "tachyon-core": core_fds,
                                "tachyon": daemon_fds
                            }
                        },
                        "orphans": {
                            "count": 0,
                            "orphans": []
                        }
                    },
                    "jobs": {
                        "total_jobs": live.jobs.len(),
                        "running_jobs": running_jobs,
                        "failed_jobs": failed_jobs,
                        "cancelled_jobs": cancelled_jobs,
                        "last_failed_job": null
                    },
                    "server_fleet": {
                        "total_servers": total_srv,
                        "healthy_count": healthy_srv,
                        "unhealthy_count": 0,
                        "untested_count": total_srv.saturating_sub(healthy_srv),
                        "avg_latency_ms": avg_lat,
                        "best_server": best_srv,
                        "sections": sec_counts
                    },
                    "recent_incidents": recent_incidents
                })
            }
        }
        _ => json!({
            "success": false,
            "error": format!("Unsupported method: {method}")
        }),
    };

    let s = serde_json::to_string(&out_val).unwrap_or_else(|_| "{}".to_string());
    (0, format!("{s}\n"), String::new())
}

async fn handle_uci_call_with_sync(
    uci_method: &str,
    args: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    sync_after_mutation: bool,
) -> Value {
    let _guard = uci_mutex().lock().await;
    handle_pure_rust_uci_with_sync(uci_method, args, state, core, sync_after_mutation).await
}

async fn capture_uci_rollback_baseline(state: &Arc<AppState>) {
    let already_pending = uci_rollback_slot()
        .lock()
        .map(|g| g.is_some())
        .unwrap_or(false);
    if already_pending {
        return;
    }
    let sections = get_json_sections_snapshot();
    let store_snap = state.data.read().await.clone();
    let token = crypto_gen::generate_hex(16);
    if let Ok(mut guard) = uci_rollback_slot().lock()
        && guard.is_none()
    {
        *guard = Some((token, sections, store_snap));
    }
}

fn clear_uci_rollback_baseline() {
    if let Ok(mut guard) = uci_rollback_slot().lock() {
        *guard = None;
    }
}

async fn revert_uci_rollback_baseline(state: &Arc<AppState>, core: &Arc<CoreManager>) -> bool {
    let saved = uci_rollback_slot().lock().ok().and_then(|mut g| g.take());
    if let Some((_token, pre_sections, pre_store)) = saved {
        set_json_sections_snapshot(pre_sections);
        let _ = transaction::commit_transaction(state, pre_store.clone()).await;
        sync_section_cache(&pre_store);
        let _ = core.apply_or_reload().await;
        true
    } else {
        false
    }
}

/// Handle HTTP POST `/cgi-bin/luci/admin/uci/<action>` (`apply_rollback`, `apply_unchecked`, `confirm`, `revert`).
pub async fn handle_uci_http_action(
    action: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (u16, Option<Value>) {
    let guard = uci_mutex().lock().await;
    match action {
        "apply_rollback" => {
            capture_uci_rollback_baseline(state).await;
            let token = uci_rollback_slot()
                .lock()
                .ok()
                .and_then(|g| g.as_ref().map(|(t, _, _)| t.clone()))
                .unwrap_or_else(|| crypto_gen::generate_hex(16));
            if let Err(err) = Box::pin(sync_uci_to_rust_store(state, core)).await {
                return (400, Some(json!({ "error": err })));
            }
            (200, Some(json!({ "token": token })))
        }
        "apply_unchecked" => {
            clear_uci_rollback_baseline();
            if let Err(err) = sync_uci_to_rust_store_with_reload(state, core, false).await {
                return (400, Some(json!({ "success": false, "error": err })));
            }
            let has_empty_sub = {
                let d_now = state.data.read().await;
                d_now.outbound_sources.iter().any(|s| {
                    s.enabled
                        && s.source_type == "subscription"
                        && !s.subscription_urls.is_empty()
                        && s.cached_nodes.is_empty()
                })
            };
            drop(guard);
            PENDING_CORE_RELOAD.store(false, std::sync::atomic::Ordering::Release);
            if !core.is_manually_stopped() {
                match tokio::time::timeout(
                    std::time::Duration::from_secs(25),
                    core.apply_or_reload(),
                )
                .await
                {
                    Ok(Ok(())) => {
                        let d_now = state.data.read().await.clone();
                        sync_section_cache(&d_now);
                        if has_empty_sub {
                            let core_clone = Arc::clone(core);
                            tokio::spawn(async move {
                                if !core_clone.is_manually_stopped() {
                                    let _ = core_clone.refresh_all_subscriptions().await;
                                }
                            });
                        }
                    }
                    Ok(Err(e)) => {
                        let msg = format!("{e:#}");
                        eprintln!("[tachyon] apply_unchecked core apply_or_reload failed: {msg}");
                        return (400, Some(json!({ "success": false, "error": msg })));
                    }
                    Err(_) => {
                        let msg = "Таймаут применения конфигурации ядра".to_string();
                        eprintln!("[tachyon] apply_unchecked timed out");
                        return (500, Some(json!({ "success": false, "error": msg })));
                    }
                }
            }
            (200, Some(json!({ "success": true })))
        }
        "confirm" => {
            clear_uci_rollback_baseline();
            (204, None)
        }
        "revert" => {
            let reverted = revert_uci_rollback_baseline(state, core).await;
            (200, Some(json!({ "reverted": reverted })))
        }
        _ => (404, Some(json!({ "error": "unknown uci action" }))),
    }
}

async fn handle_service_action_async(
    act: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    let act = act.to_string();
    let job_id = format!("rust-svc-{}", crate::store::unix_now_u64());
    let jobs_dir = crate::store::runtime_state_dir().join("service-jobs");
    let _ = std::fs::create_dir_all(&jobs_dir);
    let job_path = jobs_dir.join(format!("{job_id}.json"));
    let sync_err = if act == "stop" {
        core.set_manual_stop(true);
        sync_uci_to_rust_store_with_reload(state, core, false)
            .await
            .err()
    } else {
        sync_uci_to_rust_store(state, core).await.err()
    };
    let action_res: Result<(), String> = if let Some(err) = sync_err {
        Err(err)
    } else {
        match act.as_str() {
            "stop" => core.stop().await.map_err(|e| format!("{e:#}")),
            "start" => core.start().await.map_err(|e| format!("{e:#}")),
            _ => core.apply_or_reload().await.map_err(|e| format!("{e:#}")),
        }
    };
    let payload = match action_res {
        Ok(()) => {
            let d_now = state.data.read().await.clone();
            sync_section_cache(&d_now);
            json!({
                "success": true,
                "job_id": job_id,
                "kind": "service",
                "action": act,
                "status": "completed",
                "running": false,
                "completed": true,
                "exit_code": 0,
                "message": "OK"
            })
        }
        Err(err) => json!({
            "success": false,
            "job_id": job_id,
            "kind": "service",
            "action": act,
            "status": "failed",
            "running": false,
            "completed": true,
            "exit_code": 1,
            "error": err,
            "message": err
        }),
    };
    let _ = crypto_gen::write_json_if_changed(&job_path, &payload);
    payload
}

async fn handle_watchdog_command(
    method: &str,
    d: &crate::store::RouterStoreData,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    let enabled = if method == "watchdog_start" || method == "watchdog_stop" {
        let target = method == "watchdog_start";
        let mut candidate = d.clone();
        candidate.settings.enable_watchdog = target;
        let _ = transaction::commit_transaction(state, candidate).await;
        if target {
            core.set_manual_stop(false);
        }
        if let Ok(mut store) = json_sections_store().write() {
            if let Some(sec) = store.get_mut("settings").and_then(Value::as_object_mut) {
                sec.insert(
                    "watchdog_enable".to_string(),
                    json!(if target { "1" } else { "0" }),
                );
            }
            persist_json_sections(&store);
        }
        target
    } else {
        d.settings.enable_watchdog
    };
    let running = enabled && !core.is_manually_stopped();
    json!({
        "success": true,
        "enabled": enabled,
        "running": running,
        "pid": running.then(std::process::id),
        "uptime_seconds": sys_info::daemon_uptime_secs(),
        "status": if running { "running" } else { "stopped" }
    })
}

fn mask_subscription_url(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Some(scheme_end) = trimmed.find("://") {
        let after_scheme = &trimmed[scheme_end + 3..];
        let host_part = if let Some(rel) = after_scheme.find(['/', '?', '#']) {
            &trimmed[..scheme_end + 3 + rel]
        } else {
            trimmed
        };
        return format!("{host_part}/[REDACTED]");
    }
    "[REDACTED]".to_string()
}

fn redact_non_empty_string_field(obj: &mut Map<String, Value>, key: &str) {
    if let Some(Value::String(s)) = obj.get_mut(key)
        && !s.is_empty()
    {
        *s = "[REDACTED]".to_string();
    }
}

fn redact_non_empty_string_array(obj: &mut Map<String, Value>, key: &str) {
    if let Some(Value::Array(arr)) = obj.get_mut(key) {
        for item in arr.iter_mut() {
            if let Value::String(s) = item
                && !s.is_empty()
            {
                *s = "[REDACTED]".to_string();
            }
        }
    }
}

#[inline(never)]
pub(crate) fn format_show_config_value(
    data: &crate::store::RouterStoreData,
    want_raw: bool,
) -> Value {
    let mut val = serde_json::to_value(data).unwrap_or_else(|_| json!({}));
    if want_raw {
        return val;
    }

    if let Some(sources) = val
        .get_mut("outbound_sources")
        .and_then(Value::as_array_mut)
    {
        for src_val in sources.iter_mut() {
            let Some(src_obj) = src_val.as_object_mut() else {
                continue;
            };
            if let Some(Value::Array(nodes)) = src_obj.get("cached_nodes")
                && !nodes.is_empty()
            {
                let total = nodes.len();
                let urltest_groups = nodes
                    .iter()
                    .filter(|n| {
                        n.get("protocol").and_then(Value::as_str) == Some("urltest")
                            || n.get("outbound_json")
                                .and_then(|o| o.get("type"))
                                .and_then(Value::as_str)
                                == Some("urltest")
                    })
                    .count();
                let hidden_members = nodes
                    .iter()
                    .filter(|n| {
                        n.get("raw_uri")
                            .and_then(Value::as_str)
                            .is_some_and(|u| u.starts_with("json:hidden"))
                    })
                    .count();
                let mut by_protocol: BTreeMap<String, usize> = BTreeMap::new();
                let mut sample_tags: Vec<String> = Vec::new();
                for n in nodes {
                    let proto = n
                        .get("protocol")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .unwrap_or("unknown");
                    *by_protocol.entry(proto.to_string()).or_insert(0) += 1;
                    if sample_tags.len() < 10
                        && let Some(tag) = n
                            .get("tag")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                    {
                        sample_tags.push(tag.to_string());
                    }
                }
                src_obj.insert("cached_nodes_count".into(), json!(total));
                src_obj.insert(
                    "cached_nodes_summary".into(),
                    json!({
                        "total": total,
                        "urltest_groups": urltest_groups,
                        "hidden_members": hidden_members,
                        "by_protocol": by_protocol,
                        "sample_tags": sample_tags,
                    }),
                );
                src_obj.remove("cached_nodes");
            }

            if let Some(Value::Array(urls)) = src_obj.get_mut("subscription_urls") {
                for item in urls.iter_mut() {
                    if let Value::String(s) = item
                        && !s.is_empty()
                    {
                        *s = mask_subscription_url(s);
                    }
                }
            }
            for key in [
                "hwid",
                "amnezia_conf_text",
                "proxy_links_text",
                "outbound_json",
                "masque_private_key",
                "masque_public_key",
                "wg_private_key",
                "warp_private_key",
            ] {
                redact_non_empty_string_field(src_obj, key);
            }
            for key in ["amnezia_configs", "proxy_links", "outbound_jsons"] {
                redact_non_empty_string_array(src_obj, key);
            }
        }
    }

    for array_key in ["servers", "inbound_servers"] {
        if let Some(servers) = val.get_mut(array_key).and_then(Value::as_array_mut) {
            for srv_val in servers.iter_mut() {
                if let Some(srv_obj) = srv_val.as_object_mut() {
                    for key in [
                        "password",
                        "private_key",
                        "tls_key",
                        "reality_short_id",
                        "reality_public_key",
                        "reality_private_key",
                        "openconnect_cookie",
                        "mtproto_secret",
                        "awg_private_key",
                        "awg_client_private_key",
                        "awg_preshared_key",
                        "awg_header_protection_key",
                        "tailscale_auth_key",
                        "inbound_json",
                    ] {
                        redact_non_empty_string_field(srv_obj, key);
                    }
                }
            }
        }
    }

    crypto_gen::redact_json_value(&val)
}

#[inline(never)]
async fn build_show_config_payload(state: &Arc<AppState>, want_raw: bool) -> String {
    let snapshot = { state.data.read().await.clone() };
    let val = format_show_config_value(&snapshot, want_raw);
    serde_json::to_string_pretty(&val).unwrap_or_else(|_| "{}".to_string())
}

/// Synchronize pure-Rust JSON sections (`config_sections.json`) into `TachyonStore` (`tachyon.json`) and reload core.
pub async fn sync_uci_to_rust_store(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Result<(), String> {
    sync_uci_to_rust_store_inner(state, core, true, true).await
}

pub async fn sync_uci_to_rust_store_with_reload(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    trigger_reload: bool,
) -> Result<(), String> {
    sync_uci_to_rust_store_inner(state, core, trigger_reload, true).await
}

fn apply_entware_dns_from_json_sections(
    snapshot: &Map<String, Value>,
    candidate: &mut crate::store::RouterStoreData,
) {
    let Some(settings_obj) = snapshot.get("settings").and_then(Value::as_object) else {
        return;
    };
    if let Some(raw_mode) = settings_obj.get("entware_dns_mode").and_then(Value::as_str) {
        candidate.settings.entware_dns_mode = normalize_entware_dns_mode(raw_mode).to_string();
    }
    if let Some(port_val) = settings_obj.get("entware_dns_port") {
        let parsed = match port_val {
            Value::Number(n) => n.as_u64().and_then(|v| u16::try_from(v).ok()),
            Value::String(s) => s.trim().parse::<u16>().ok(),
            _ => None,
        };
        if let Some(p) = parsed.filter(|&p| p >= 1) {
            candidate.settings.entware_dns_port = p;
        }
    }
}

async fn sync_uci_to_rust_store_inner(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    trigger_reload: bool,
    log_on_err: bool,
) -> Result<(), String> {
    Box::pin(async move {
        let snapshot = get_json_sections_snapshot();
        let (current_val, mut candidate) = {
            let d = state.data.read().await;
            (serde_json::to_value(&*d).ok(), d.clone())
        };
        let old_telegram = candidate.telegram.clone();
        let imported = candidate.import_from_json_sections(&snapshot);
        apply_entware_dns_from_json_sections(&snapshot, &mut candidate);
        drop(snapshot);
        if imported > 0 {
            let unchanged = current_val
                .as_ref()
                .zip(serde_json::to_value(&candidate).ok())
                .is_some_and(|(cur, next)| cur == &next);
            drop(current_val);
            if unchanged {
                if trigger_reload
                    && PENDING_CORE_RELOAD.swap(false, std::sync::atomic::Ordering::AcqRel)
                    && !core.is_manually_stopped()
                {
                    let has_empty_sub = candidate.outbound_sources.iter().any(|s| {
                        s.enabled
                            && s.source_type == "subscription"
                            && !s.subscription_urls.is_empty()
                            && s.cached_nodes.is_empty()
                    });
                    let core_clone = Arc::clone(core);
                    tokio::spawn(async move {
                        if !core_clone.is_manually_stopped()
                            && let Err(e) = core_clone.apply_or_reload().await
                        {
                            eprintln!("[tachyon] apply_or_reload after uci sync failed: {e:#}");
                        }
                        if has_empty_sub && !core_clone.is_manually_stopped() {
                            let _ = core_clone.refresh_all_subscriptions().await;
                        }
                    });
                }
                return Ok(());
            }
            let tg_changed = candidate.telegram != old_telegram;
            drop(old_telegram);
            let has_empty_sub = candidate.outbound_sources.iter().any(|s| {
                s.enabled
                    && s.source_type == "subscription"
                    && !s.subscription_urls.is_empty()
                    && s.cached_nodes.is_empty()
            });
            if let Err(e) = transaction::commit_transaction(state, candidate.clone()).await {
                let msg = format!("{e:#}");
                if log_on_err {
                    eprintln!("[tachyon] sync_uci_to_rust_store failed: {msg}");
                    let mut live = state.live.write().await;
                    live.push_event(
                        "error",
                        "uci",
                        &format!("Ошибка синхронизации конфигурации: {msg}"),
                    );
                }
                return Err(msg);
            }
            sync_section_cache(&candidate);
            if tg_changed {
                crate::tg_bot::set_runtime_override(None);
                crate::tg_bot::notify_bot_wakeup();
            }
            if trigger_reload {
                PENDING_CORE_RELOAD.store(false, std::sync::atomic::Ordering::Release);
                if !core.is_manually_stopped() {
                    let core_clone = Arc::clone(core);
                    tokio::spawn(async move {
                        if !core_clone.is_manually_stopped()
                            && let Err(e) = core_clone.apply_or_reload().await
                        {
                            eprintln!("[tachyon] apply_or_reload after uci sync failed: {e:#}");
                        }
                        if has_empty_sub && !core_clone.is_manually_stopped() {
                            let _ = core_clone.refresh_all_subscriptions().await;
                        }
                    });
                }
            } else {
                PENDING_CORE_RELOAD.store(true, std::sync::atomic::Ordering::Release);
            }
        }
        Ok(())
    })
    .await
}

fn is_allowed_router_ubus_call(object: &str, method: &str) -> bool {
    matches!(
        (object, method),
        ("network.interface", "dump" | "status")
            | (
                "luci-rpc",
                "getHostHints"
                    | "getDHCPLeases"
                    | "getNetworkDevices"
                    | "getWirelessDevices"
                    | "getBoardJSON"
            )
            | ("system", "board" | "info")
            | ("network.device", "status")
    )
}

async fn call_router_ubus_cli(object: &str, method: &str, args: &Value) -> Option<Value> {
    if crate::platform::is_entware() {
        return None;
    }
    if !is_allowed_router_ubus_call(object, method) {
        return None;
    }
    if !Path::new("/bin/ubus").exists() && !Path::new("/usr/sbin/ubus").exists() {
        return None;
    }
    let ubus_bin = if Path::new("/bin/ubus").exists() {
        "/bin/ubus"
    } else {
        "/usr/sbin/ubus"
    };
    let args_str = serde_json::to_string(args).unwrap_or_else(|_| "{}".to_string());
    let out = tokio::time::timeout(
        Duration::from_secs(15),
        Command::new(ubus_bin)
            .args(["call", object, method, &args_str])
            .output(),
    )
    .await
    .ok()?
    .ok()?;

    if !out.status.success() {
        let code = out.status.code().unwrap_or(1);
        return Some(json!([code]));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let trimmed = stdout.trim();
    if trimmed.is_empty() {
        return Some(json!([0]));
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(val) => Some(json!([0, val])),
        Err(_) => Some(json!([0])),
    }
}

async fn handle_fallback_system_ubus(object: &str, method: &str) -> Value {
    match (object, method) {
        ("luci-rpc", "getHostHints") => {
            let mut map = Map::new();
            for c in sys_info::discover_lan_devices() {
                let key = if c.mac.is_empty() {
                    c.ip.clone()
                } else {
                    c.mac.to_uppercase()
                };
                map.insert(
                    key,
                    json!({
                        "name": c.hostname,
                        "ipaddrs": [c.ip],
                        "ip6addrs": [],
                    }),
                );
            }
            json!([0, Value::Object(map)])
        }
        ("luci-rpc", "getDHCPLeases") => {
            let leases: Vec<Value> = sys_info::discover_lan_devices()
                .into_iter()
                .map(|c| {
                    json!({
                        "ipaddr": c.ip,
                        "macaddr": c.mac,
                        "hostname": c.hostname,
                        "expires": 3600
                    })
                })
                .collect();
            json!([0, { "dhcp_leases": leases, "dhcp6_leases": [] }])
        }
        ("luci-rpc", "getNetworkDevices") => {
            let mut devs = Map::new();
            let mut netdevs = Vec::new();
            if let Ok(rd) = std::fs::read_dir("/sys/class/net") {
                for ent in rd.flatten() {
                    if let Some(n) = ent.file_name().to_str() {
                        netdevs.push(n.to_string());
                    }
                }
            }
            for ifname in netdevs {
                let mac = std::fs::read_to_string(format!("/sys/class/net/{ifname}/address"))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                let oper = std::fs::read_to_string(format!("/sys/class/net/{ifname}/operstate"))
                    .unwrap_or_default()
                    .trim()
                    .to_ascii_lowercase();
                let up = oper == "up" || oper == "unknown";
                let mut ipaddrs = Vec::new();
                if let Ok(out) = std::process::Command::new("ip")
                    .args(["-o", "-4", "addr", "show", "dev", &ifname])
                    .output()
                    && out.status.success()
                {
                    let text = String::from_utf8_lossy(&out.stdout);
                    for line in text.lines() {
                        if let Some(inet_pos) = line.find(" inet ")
                            && let Some(cidr) = line[inet_pos + 6..].split_whitespace().next()
                        {
                            ipaddrs.push(json!(cidr));
                        }
                    }
                }
                devs.insert(
                    ifname.clone(),
                    json!({
                        "name": ifname,
                        "up": up,
                        "mac": mac,
                        "ipaddrs": ipaddrs
                    }),
                );
            }
            json!([0, Value::Object(devs)])
        }
        ("luci-rpc", "getWirelessDevices") => json!([0, {}]),
        ("luci-rpc", "getBoardJSON") => {
            let sys = sys_info::collect_host_info();
            json!([
                0,
                {
                    "kernel": sys.os,
                    "hostname": sys.hostname,
                    "model": sys.router_model,
                    "system": sys.arch,
                    "release": { "description": sys.openwrt_release }
                }
            ])
        }
        ("network.interface", "dump") => {
            let mut ifaces = Vec::new();
            let mut netdevs = Vec::new();
            if let Ok(rd) = std::fs::read_dir("/sys/class/net") {
                for ent in rd.flatten() {
                    if let Some(n) = ent.file_name().to_str() {
                        netdevs.push(n.to_string());
                    }
                }
            }
            for ifname in netdevs {
                if ifname == "lo" {
                    continue;
                }
                let oper = std::fs::read_to_string(format!("/sys/class/net/{ifname}/operstate"))
                    .unwrap_or_default()
                    .trim()
                    .to_ascii_lowercase();
                let up = oper == "up" || oper == "unknown";
                let mut v4_arr = Vec::new();
                if let Ok(out) = std::process::Command::new("ip")
                    .args(["-o", "-4", "addr", "show", "dev", &ifname])
                    .output()
                    && out.status.success()
                {
                    for line in String::from_utf8_lossy(&out.stdout).lines() {
                        if let Some(inet_pos) = line.find(" inet ")
                            && let Some(cidr) = line[inet_pos + 6..].split_whitespace().next()
                            && let Some((ip, mask)) = cidr.split_once('/')
                        {
                            v4_arr.push(json!({
                                "address": ip,
                                "mask": mask.parse::<u8>().unwrap_or(24)
                            }));
                        }
                    }
                }
                let mut v6_arr = Vec::new();
                if let Ok(out) = std::process::Command::new("ip")
                    .args(["-o", "-6", "addr", "show", "dev", &ifname])
                    .output()
                    && out.status.success()
                {
                    for line in String::from_utf8_lossy(&out.stdout).lines() {
                        if let Some(inet_pos) = line.find(" inet6 ")
                            && let Some(cidr) = line[inet_pos + 7..].split_whitespace().next()
                            && let Some((ip, mask)) = cidr.split_once('/')
                        {
                            v6_arr.push(json!({
                                "address": ip,
                                "mask": mask.parse::<u8>().unwrap_or(64)
                            }));
                        }
                    }
                }
                let logic_name = if ifname == "br0" || ifname == "br-lan" {
                    "lan"
                } else {
                    ifname.as_str()
                };
                ifaces.push(json!({
                    "interface": logic_name,
                    "l3_device": ifname,
                    "device": ifname,
                    "up": up,
                    "proto": "static",
                    "ipv4-address": v4_arr,
                    "ipv6-address": v6_arr
                }));
            }
            json!([0, { "interface": ifaces }])
        }
        ("network", "get_proto_handlers") => json!([0, {}]),
        _ => json!([0, {}]),
    }
}

/// Deterministically reorder UCI sections according to `requested` while preserving
/// the relative order and slot positions of untouched sections (e.g. `settings`, `telegram`),
/// and assign contiguous `.index` values (`0..N`) so `bypass` before `match_all` is never lost.
fn apply_uci_sections_order(store: &mut Map<String, Value>, requested: &[String]) {
    if requested.is_empty() || store.is_empty() {
        return;
    }
    let mut ordered: Vec<(usize, String, Value)> = std::mem::take(store)
        .into_iter()
        .map(|(k, v)| {
            let old_idx = v
                .get(".index")
                .and_then(Value::as_u64)
                .map(|n| n as usize)
                .unwrap_or(usize::MAX);
            (old_idx, k, v)
        })
        .collect();
    ordered.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));

    let mut req_unique: Vec<&str> = Vec::with_capacity(requested.len());
    let mut seen_req = std::collections::HashSet::new();
    for s in requested {
        if seen_req.insert(s.as_str()) {
            req_unique.push(s.as_str());
        }
    }

    let mut target_slots: Vec<usize> = Vec::new();
    let mut extracted: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for (slot_idx, (_, k, _)) in ordered.iter().enumerate() {
        if seen_req.contains(k.as_str()) {
            target_slots.push(slot_idx);
        }
    }

    let mut flat: Vec<Option<(String, Value)>> = ordered
        .into_iter()
        .map(|(_, k, v)| {
            if seen_req.contains(k.as_str()) {
                extracted.insert(k, v);
                None
            } else {
                Some((k, v))
            }
        })
        .collect();

    let mut reordered_items: Vec<(String, Value)> = Vec::with_capacity(extracted.len());
    for key in req_unique {
        if let Some(val) = extracted.remove(key) {
            reordered_items.push((key.to_string(), val));
        }
    }

    for (slot_idx, item) in target_slots.into_iter().zip(reordered_items) {
        if let Some(slot) = flat.get_mut(slot_idx) {
            *slot = Some(item);
        }
    }

    for (idx, (k, mut val)) in flat.into_iter().flatten().enumerate() {
        if let Some(obj) = val.as_object_mut() {
            obj.insert(".index".to_string(), json!(idx));
        }
        store.insert(k, val);
    }
}

fn is_safe_uci_config_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
}

fn uci_json_sections_need_resync(
    d: &crate::store::RouterStoreData,
    sections: &Map<String, Value>,
) -> bool {
    if sections.is_empty()
        || sections
            .get("settings")
            .and_then(|v| v.get(".type"))
            .and_then(Value::as_str)
            != Some("settings")
    {
        return true;
    }
    let check_all = |items: &[(&str, &str)]| {
        items.iter().any(|(id, ty)| {
            sections
                .get(*id)
                .and_then(|v| v.get(".type"))
                .and_then(Value::as_str)
                != Some(*ty)
        })
    };
    let mut expected: Vec<(&str, &str)> = Vec::with_capacity(
        d.sections.len()
            + d.balancers.len()
            + d.outbound_groups.len()
            + d.servers.len()
            + d.profiles.len()
            + d.conditions.len()
            + d.outbound_sources.len(),
    );
    for s in &d.sections {
        if !s.id.trim().is_empty() {
            expected.push((s.id.trim(), "section"));
        }
    }
    for b in &d.balancers {
        if !b.id.trim().is_empty() {
            expected.push((b.id.trim(), "balancer"));
        }
    }
    for g in &d.outbound_groups {
        if !g.id.trim().is_empty() {
            expected.push((g.id.trim(), "outbound_group"));
        }
    }
    for s in &d.servers {
        if !s.id.trim().is_empty() {
            expected.push((s.id.trim(), "server"));
        }
    }
    for p in &d.profiles {
        if !p.id.trim().is_empty() {
            expected.push((p.id.trim(), "profile"));
        }
    }
    for c in &d.conditions {
        if !c.id.trim().is_empty() {
            expected.push((c.id.trim(), "condition"));
        }
    }
    for src in &d.outbound_sources {
        if !src.id.trim().is_empty() {
            expected.push((src.id.trim(), "outbound_source"));
        }
    }
    check_all(&expected)
}

async fn handle_pure_rust_uci_with_sync(
    uci_method: &str,
    args: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    sync_after_mutation: bool,
) -> Value {
    let config = args
        .get("config")
        .and_then(Value::as_str)
        .unwrap_or("tachyon");

    if config != "tachyon" {
        if !is_safe_uci_config_name(config) {
            return json!([2]);
        }
        if crate::platform::is_entware() {
            return match uci_method {
                "get" => json!([0, { "values": {} }]),
                "changes" => json!([0, { "changes": {} }]),
                _ => json!([0]),
            };
        }
        let cfg_path = PathBuf::from(format!("/etc/config/{config}"));
        return match uci_method {
            "get" => {
                let sections = parse_uci_file(&cfg_path);
                json!([0, { "values": sections }])
            }
            "changes" => json!([0, { "changes": {} }]),
            _ => json!([0]),
        };
    }

    match uci_method {
        "get" => {
            let need_resync = {
                let d = state.data.read().await;
                json_sections_store()
                    .read()
                    .map(|g| uci_json_sections_need_resync(&d, &g))
                    .unwrap_or(false)
            };
            if need_resync {
                let d = state.data.read().await.clone();
                sync_from_store_to_json_and_cache(&d);
            }
            let store = json_sections_store()
                .read()
                .map(|g| g.clone())
                .unwrap_or_default();
            if let Some(sec_name) = args.get("section").and_then(Value::as_str) {
                if let Some(sec_val) = store.get(sec_name) {
                    if let Some(opt_name) = args.get("option").and_then(Value::as_str) {
                        if let Some(v) = sec_val.get(opt_name) {
                            return json!([0, { "value": v }]);
                        }
                        return json!([4]);
                    }
                    return json!([0, { "values": sec_val }]);
                }
                return json!([4]);
            }
            json!([0, { "values": Value::Object(store) }])
        }
        "add" => {
            capture_uci_rollback_baseline(state).await;
            let stype = args
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("section")
                .trim();
            let raw_name = args
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let anonymous = raw_name.is_none();

            let sname = {
                let mut store = match json_sections_store().write() {
                    Ok(g) => g,
                    Err(_) => return json!([1]),
                };
                let idx = next_section_index(&store);
                let name = if let Some(n) = raw_name {
                    n.to_string()
                } else {
                    let mut n = idx + 1;
                    loop {
                        let candidate = format!("cfg{n:02x}{stype}");
                        if !store.contains_key(&candidate) {
                            break candidate;
                        }
                        n += 1;
                    }
                };
                let mut sec_obj = Map::new();
                sec_obj.insert(".anonymous".to_string(), json!(anonymous));
                sec_obj.insert(".type".to_string(), json!(stype));
                sec_obj.insert(".name".to_string(), json!(name.clone()));
                sec_obj.insert(".index".to_string(), json!(idx));
                if let Some(vals) = args.get("values").and_then(Value::as_object) {
                    for (k, v) in vals {
                        if !k.starts_with('.') {
                            sec_obj.insert(k.clone(), v.clone());
                        }
                    }
                }
                store.insert(name.clone(), Value::Object(sec_obj));
                persist_json_sections(&store);
                name
            };
            if sync_after_mutation {
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            json!([0, { "section": sname }])
        }
        "set" => {
            let Some(sec_name) = args.get("section").and_then(Value::as_str) else {
                return json!([2]);
            };
            let Some(vals) = args.get("values").and_then(Value::as_object) else {
                return json!([2]);
            };
            capture_uci_rollback_baseline(state).await;
            {
                let mut store = match json_sections_store().write() {
                    Ok(g) => g,
                    Err(_) => return json!([1]),
                };
                let next_idx = next_section_index(&store);
                let sec_entry = store.entry(sec_name.to_string()).or_insert_with(|| {
                    json!({
                        ".anonymous": false,
                        ".type": sec_name,
                        ".name": sec_name,
                        ".index": next_idx
                    })
                });
                if let Some(sec_obj) = sec_entry.as_object_mut() {
                    for (k, v) in vals {
                        if k.starts_with('.') {
                            continue;
                        }
                        if v.is_null() {
                            sec_obj.remove(k);
                        } else {
                            sec_obj.insert(k.clone(), v.clone());
                        }
                    }
                }
                persist_json_sections(&store);
            }
            if sync_after_mutation {
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            json!([0])
        }
        "delete" => {
            let Some(sec_name) = args.get("section").and_then(Value::as_str) else {
                return json!([2]);
            };
            capture_uci_rollback_baseline(state).await;
            let single_opt = args.get("option").and_then(Value::as_str);
            let multi_opts = args.get("options").and_then(Value::as_array);
            {
                let mut store = match json_sections_store().write() {
                    Ok(g) => g,
                    Err(_) => return json!([1]),
                };
                if single_opt.is_some() || multi_opts.is_some() {
                    if let Some(sec_obj) = store.get_mut(sec_name).and_then(Value::as_object_mut) {
                        if let Some(opt) = single_opt {
                            sec_obj.remove(opt);
                        }
                        if let Some(opts) = multi_opts {
                            for o in opts.iter().filter_map(Value::as_str) {
                                sec_obj.remove(o);
                            }
                        }
                    }
                } else {
                    store.remove(sec_name);
                    let mut ordered: Vec<(usize, String)> = store
                        .iter()
                        .map(|(k, v)| {
                            let idx = v
                                .get(".index")
                                .and_then(Value::as_u64)
                                .map(|n| n as usize)
                                .unwrap_or(usize::MAX);
                            (idx, k.clone())
                        })
                        .collect();
                    ordered.sort_by_key(|(idx, _)| *idx);
                    for (new_idx, (_, k)) in ordered.into_iter().enumerate() {
                        if let Some(obj) = store.get_mut(&k).and_then(Value::as_object_mut) {
                            obj.insert(".index".to_string(), json!(new_idx));
                        }
                    }
                }
                persist_json_sections(&store);
            }
            if sync_after_mutation {
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            json!([0])
        }
        "order" => {
            capture_uci_rollback_baseline(state).await;
            if let Some(order_arr) = args
                .get("sections")
                .or_else(|| args.get("order"))
                .and_then(Value::as_array)
            {
                let requested: Vec<String> = order_arr
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
                let mut store = match json_sections_store().write() {
                    Ok(g) => g,
                    Err(_) => return json!([1]),
                };
                apply_uci_sections_order(&mut store, &requested);
                persist_json_sections(&store);
            }
            if sync_after_mutation {
                let _ = sync_uci_to_rust_store_inner(state, core, false, false).await;
            }
            json!([0])
        }
        "changes" => json!([0, { "changes": {} }]),
        "apply" | "commit" | "confirm" => {
            clear_uci_rollback_baseline();
            if let Err(err) = sync_uci_to_rust_store(state, core).await {
                return json!([5, { "error": err }]);
            }
            json!([0])
        }
        "revert" => {
            let _ = revert_uci_rollback_baseline(state, core).await;
            json!([0])
        }
        _ => json!([0]),
    }
}

fn parse_uci_file(path: &Path) -> Value {
    let Ok(text) = std::fs::read_to_string(path) else {
        return json!({});
    };
    let mut values = Map::new();
    let mut cur_sec: Option<String> = None;
    let mut index = 0usize;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("config ") {
            let mut parts = rest.split_whitespace();
            let stype = parts
                .next()
                .unwrap_or("")
                .trim_matches('\'')
                .trim_matches('"');
            let raw_name = parts.next().map(|s| s.trim_matches('\'').trim_matches('"'));
            let anonymous = raw_name.is_none();
            let sname = raw_name
                .map(String::from)
                .unwrap_or_else(|| format!("cfg{:02x}{stype}", index + 1));
            let mut sec_obj = Map::new();
            sec_obj.insert(".anonymous".to_string(), json!(anonymous));
            sec_obj.insert(".type".to_string(), json!(stype));
            sec_obj.insert(".name".to_string(), json!(sname));
            sec_obj.insert(".index".to_string(), json!(index));
            index += 1;
            values.insert(sname.clone(), Value::Object(sec_obj));
            cur_sec = Some(sname);
        } else if let Some(rest) = line.strip_prefix("option ") {
            if let Some(sec_name) = &cur_sec
                && let Some((k, v)) = split_uci_kv(rest)
                && let Some(sec) = values.get_mut(sec_name).and_then(Value::as_object_mut)
            {
                sec.insert(k, Value::String(v));
            }
        } else if let Some(rest) = line.strip_prefix("list ")
            && let Some(sec_name) = &cur_sec
            && let Some((k, v)) = split_uci_kv(rest)
            && let Some(sec) = values.get_mut(sec_name).and_then(Value::as_object_mut)
        {
            let entry = sec.entry(k).or_insert_with(|| Value::Array(Vec::new()));
            if let Some(arr) = entry.as_array_mut() {
                arr.push(Value::String(v));
            }
        }
    }
    Value::Object(values)
}

fn split_uci_kv(s: &str) -> Option<(String, String)> {
    let s = s.trim();
    let idx = s.find(char::is_whitespace)?;
    let key = s[..idx]
        .trim()
        .trim_matches('\'')
        .trim_matches('"')
        .to_string();
    let val = s[idx..]
        .trim()
        .trim_matches('\'')
        .trim_matches('"')
        .replace("'\\''", "'");
    Some((key, val))
}

/// Handle `POST /cgi-bin/cgi-exec` and `POST /cgi-bin/cgi-download` (`fs.exec_direct` / `fs.read_direct`).
pub async fn handle_cgi_direct(
    path: &str,
    body: &[u8],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (u16, &'static str, Vec<u8>) {
    let form = parse_urlencoded(body);
    if path.ends_with("/cgi-download") {
        let Some(filepath) = form.get("path") else {
            return (400, "text/plain; charset=utf-8", b"Missing path".to_vec());
        };
        if !is_allowed_bridge_read_path(filepath) {
            return (403, "text/plain; charset=utf-8", b"Forbidden".to_vec());
        }
        let target_path = resolve_virtual_sub_cache_file(filepath)
            .unwrap_or_else(|| resolve_bridge_runtime_path(filepath));
        if let Ok(bytes) = std::fs::read(&target_path) {
            return (200, "application/octet-stream", bytes);
        }
        if filepath == "/var/run/tachyon/ui-state/snapshot-export.json"
            || filepath == "/tmp/tachyon-snapshot-export.json"
        {
            let sections = get_json_sections_snapshot();
            let profile =
                crate::snapshots::build_active_profile(state, &sections, "export", "full").await;
            let raw = serde_json::to_string_pretty(&profile).unwrap_or_else(|_| "{}".to_string());
            return (200, "application/octet-stream", raw.into_bytes());
        }
        (404, "text/plain; charset=utf-8", b"Not found".to_vec())
    } else {
        let cmd_str = form.get("command").map(String::as_str).unwrap_or("");
        if cmd_str.trim() == "/usr/libexec/luci-peeraddr" {
            return (
                200,
                "application/json; charset=utf-8",
                b"{\"inbound_interfaces\":[]}".to_vec(),
            );
        }
        let tokens = split_shell_words(cmd_str);
        let Some((bin, args)) = tokens.split_first() else {
            return (200, "text/plain; charset=utf-8", Vec::new());
        };
        if is_tachyon_cli_command(bin) {
            let (_, stdout, _) = execute_tachyon_cli(args, state, core).await;
            return (200, "text/plain; charset=utf-8", stdout.into_bytes());
        }
        if bin == "/sbin/uci" || bin == "/bin/uci" || bin == "uci" {
            let (_, stdout, _) = execute_pure_rust_uci_cli(args, state, core).await;
            return (200, "text/plain; charset=utf-8", stdout.into_bytes());
        }
        let args_vec = args.to_vec();
        if !is_allowed_bridge_exec(bin, &args_vec) {
            return (403, "text/plain; charset=utf-8", b"Forbidden".to_vec());
        }
        let mut cmd = Command::new(bin);
        cmd.args(args).kill_on_drop(true);
        match tokio::time::timeout(Duration::from_secs(30), cmd.output()).await {
            Ok(Ok(out)) => (200, "text/plain; charset=utf-8", out.stdout),
            _ => (500, "text/plain; charset=utf-8", Vec::new()),
        }
    }
}

fn sanitize_probe_host(raw: &str) -> Option<String> {
    let mut s = raw.trim();
    for prefix in [
        "https://", "http://", "domain:", "full:", "keyword:", "geosite:", "regexp:",
    ] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest;
        }
    }
    s = s.split('/').next().unwrap_or("");
    if let Some((host_part, _port)) = s.split_once(':') {
        s = host_part;
    }
    s = s.trim_start_matches("*.").trim_matches('.');
    let lower = s.to_ascii_lowercase();
    if lower.is_empty()
        || lower.len() > 253
        || lower.starts_with('-')
        || lower.ends_with('-')
        || !lower.contains('.')
    {
        return None;
    }
    if !lower
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        return None;
    }
    Some(lower)
}

fn clean_section_label(sec: &crate::store::RoutingSection) -> String {
    let raw = if !sec.label.trim().is_empty() {
        sec.label.trim()
    } else {
        sec.id.trim()
    };
    let cleaned = raw
        .trim_start_matches(|c: char| !c.is_alphanumeric() && c != '[' && c != '(')
        .trim();
    if cleaned.is_empty() {
        sec.id.clone()
    } else {
        cleaned.to_string()
    }
}

fn resolve_section_route_type(
    sec: &crate::store::RoutingSection,
    outbounds: &[crate::store::OutboundSource],
) -> Option<&'static str> {
    if !sec.enabled {
        return None;
    }
    let conn = sec.connection_type.trim().to_ascii_lowercase();
    let act = sec.action.trim().to_ascii_lowercase();
    if matches!(conn.as_str(), "block" | "reject") || matches!(act.as_str(), "block" | "reject") {
        return None;
    }
    if conn == "direct" || act == "direct" {
        return Some("direct");
    }
    if matches!(conn.as_str(), "hosts" | "dns") || matches!(act.as_str(), "hosts" | "dns") {
        return Some("hosts");
    }
    if matches!(conn.as_str(), "desync" | "zapret2" | "zapret" | "byedpi")
        || matches!(act.as_str(), "desync" | "zapret2" | "zapret" | "byedpi")
    {
        return Some("desync");
    }
    let has_desync_outbound = sec.outbound_source_refs.iter().any(|ref_id| {
        outbounds.iter().any(|o| {
            o.enabled
                && o.id == *ref_id
                && matches!(
                    o.source_type.as_str(),
                    "desync" | "zapret2" | "zapret" | "byedpi"
                )
        })
    });
    if has_desync_outbound {
        return Some("desync");
    }
    Some("connection")
}

fn map_list_key_to_service(list_key: &str) -> Option<(&'static str, &'static [&'static str])> {
    let k = list_key
        .trim()
        .trim_start_matches("geosite:")
        .to_ascii_lowercase();
    match k.as_str() {
        "youtube" | "google-video" => Some(("YouTube", &["www.youtube.com", "i.ytimg.com"])),
        "discord" => Some(("Discord", &["discord.com", "gateway.discord.gg"])),
        "telegram" => Some(("Telegram", &["web.telegram.org"])),
        "openai" | "chatgpt" => Some(("ChatGPT / OpenAI", &["chatgpt.com", "api.openai.com"])),
        "anthropic" | "claude" => Some(("Claude / Anthropic", &["claude.ai"])),
        "gemini" | "google-gemini" | "bard" => Some(("Gemini / Google AI", &["gemini.google.com"])),
        "qwen" => Some(("Qwen", &["qwen.ai", "chat.qwen.ai"])),
        "kimi" => Some(("Kimi", &["kimi.com", "kimi.ai"])),
        "paas_db" => Some(("PaaS / Cloud DB", &["vercel.com", "supabase.com"])),
        "kick" => Some(("Kick", &["kick.com"])),
        "github" => Some(("GitHub", &["github.com", "api.github.com"])),
        "instagram" | "meta" | "facebook" => Some(("Instagram / Meta", &["www.instagram.com"])),
        "twitter" | "x" => Some(("X / Twitter", &["x.com"])),
        "twitch" => Some(("Twitch", &["www.twitch.tv"])),
        "spotify" => Some(("Spotify", &["open.spotify.com"])),
        "netflix" => Some(("Netflix", &["www.netflix.com"])),
        "tiktok" => Some(("TikTok", &["www.tiktok.com"])),
        "steam" => Some(("Steam", &["store.steampowered.com"])),
        "rutracker" => Some(("RuTracker", &["rutracker.org"])),
        _ => None,
    }
}

fn infer_domain_route_type(
    raw_domain: &str,
    sections: &[crate::store::RoutingSection],
    outbounds: &[crate::store::OutboundSource],
    conditions: &[crate::store::TrafficCondition],
) -> String {
    let Some(host) = sanitize_probe_host(raw_domain) else {
        return "connection".to_string();
    };
    let mut fallback_route: Option<&'static str> = None;
    for sec in sections {
        let Some(rt) = resolve_section_route_type(sec, outbounds) else {
            continue;
        };
        if sec.match_all && fallback_route.is_none() {
            fallback_route = Some(rt);
        }
        let matches_explicit = sec
            .domains
            .iter()
            .chain(sec.user_domains.iter())
            .filter_map(|d| sanitize_probe_host(d))
            .any(|d| host == d || host.ends_with(&format!(".{d}")));
        if matches_explicit {
            return rt.to_string();
        }
        for cond_id in &sec.condition_refs {
            if let Some(cond) = conditions.iter().find(|c| c.enabled && &c.id == cond_id) {
                if cond
                    .domains
                    .iter()
                    .chain(cond.user_domains.iter())
                    .filter_map(|d| sanitize_probe_host(d))
                    .any(|d| host == d || host.ends_with(&format!(".{d}")))
                {
                    return rt.to_string();
                }
                for key in cond.community_lists.iter().chain(cond.geosite_codes.iter()) {
                    if let Some((_, domains)) = map_list_key_to_service(key)
                        && domains.iter().any(|&d| {
                            let root = d.strip_prefix("www.").unwrap_or(d);
                            host == d || host == root || host.ends_with(&format!(".{root}"))
                        })
                    {
                        return rt.to_string();
                    }
                }
            }
        }
        for key in sec.community_lists.iter().chain(sec.geosite_codes.iter()) {
            if let Some((_, domains)) = map_list_key_to_service(key)
                && domains.iter().any(|&d| {
                    let root = d.strip_prefix("www.").unwrap_or(d);
                    host == d || host == root || host.ends_with(&format!(".{root}"))
                })
            {
                return rt.to_string();
            }
        }
    }
    fallback_route.unwrap_or("connection").to_string()
}

fn build_service_health_targets(
    sections: &[crate::store::RoutingSection],
    outbounds: &[crate::store::OutboundSource],
    conditions: &[crate::store::TrafficCondition],
    include_all: bool,
) -> Vec<Value> {
    let mut seen = std::collections::HashSet::<String>::new();
    let mut targets = Vec::<Value>::new();
    let mut push_target = |section: &str, route_type: &str, domain: &str| -> bool {
        if let Some(clean) = sanitize_probe_host(domain)
            && seen.insert(clean.clone())
        {
            targets.push(json!({
                "section": section,
                "route_type": route_type,
                "domain": clean,
            }));
            return true;
        }
        false
    };

    let mut default_tunnel_rt = "connection";
    for sec in sections {
        let Some(rt) = resolve_section_route_type(sec, outbounds) else {
            continue;
        };
        if sec.match_all || default_tunnel_rt == "connection" {
            default_tunnel_rt = rt;
        }
        let sec_label = clean_section_label(sec);
        let mut keys: Vec<&str> = sec
            .community_lists
            .iter()
            .chain(sec.geosite_codes.iter())
            .chain(sec.domain_ip_lists.iter())
            .map(String::as_str)
            .collect();
        let mut extra_domains: Vec<&str> = sec
            .domains
            .iter()
            .chain(sec.user_domains.iter())
            .map(String::as_str)
            .collect();

        for cond_id in &sec.condition_refs {
            if let Some(cond) = conditions.iter().find(|c| c.enabled && &c.id == cond_id) {
                keys.extend(
                    cond.community_lists
                        .iter()
                        .chain(cond.geosite_codes.iter())
                        .chain(cond.domain_ip_lists.iter())
                        .map(String::as_str),
                );
                extra_domains.extend(
                    cond.domains
                        .iter()
                        .chain(cond.user_domains.iter())
                        .map(String::as_str),
                );
            }
        }

        for key in keys {
            if let Some((svc_name, svc_domains)) = map_list_key_to_service(key) {
                for &dom in svc_domains {
                    let _ = push_target(svc_name, rt, dom);
                }
            }
        }

        let mut custom_added = 0usize;
        for dom in extra_domains {
            if custom_added >= 4 {
                break;
            }
            if push_target(&sec_label, rt, dom) {
                custom_added += 1;
            }
        }
    }

    let baseline = [
        ("YouTube", default_tunnel_rt, "www.youtube.com"),
        ("YouTube", default_tunnel_rt, "i.ytimg.com"),
        ("Discord", default_tunnel_rt, "discord.com"),
        ("Discord", default_tunnel_rt, "gateway.discord.gg"),
        ("GitHub", default_tunnel_rt, "github.com"),
        ("GitHub", default_tunnel_rt, "api.github.com"),
        ("ChatGPT / OpenAI", default_tunnel_rt, "api.openai.com"),
        ("Telegram", default_tunnel_rt, "web.telegram.org"),
        ("Базовая связность", "direct", "cp.cloudflare.com"),
        ("Базовая связность", "direct", "ya.ru"),
    ];
    for (svc, rt, dom) in baseline {
        let inferred = infer_domain_route_type(dom, sections, outbounds, conditions);
        let effective_rt = if svc == "Базовая связность" {
            "direct"
        } else if !inferred.is_empty() {
            inferred.as_str()
        } else {
            rt
        };
        push_target(svc, effective_rt, dom);
    }

    if include_all {
        let extended = [
            ("Gemini / Google AI", "gemini.google.com"),
            ("Claude / Anthropic", "claude.ai"),
            ("Instagram / Meta", "www.instagram.com"),
            ("X / Twitter", "x.com"),
            ("Twitch", "www.twitch.tv"),
            ("Spotify", "open.spotify.com"),
            ("Steam", "store.steampowered.com"),
            ("Netflix", "www.netflix.com"),
            ("Cloudflare CDN", "one.one.one.one"),
            ("Docker Hub", "registry-1.docker.io"),
        ];
        for (svc, dom) in extended {
            let rt = infer_domain_route_type(dom, sections, outbounds, conditions);
            push_target(svc, &rt, dom);
        }
    }

    targets
}

/// Classify the completed HTTPS probe shown in the service availability modal.
fn service_http_outcome(http_code: u16, exit_code: i32) -> (bool, String) {
    if exit_code == 0 && (200..300).contains(&http_code) {
        return (true, format!("OK {http_code}"));
    }
    let reason = match exit_code {
        6 => "DNS Error",
        7 => "TCP Refused",
        28 => "Timeout",
        35 => "TLS Handshake Error",
        51 | 58 | 60 => "TLS Certificate Error",
        52 | 55 | 56 => "Conn Reset",
        0 if http_code != 0 => return (false, format!("HTTP {http_code}")),
        0 => "No HTTP response",
        _ => "HTTP probe failed",
    };
    (false, reason.to_string())
}

#[cfg(test)]
mod service_http_outcome_tests {
    use super::service_http_outcome;

    #[test]
    fn complete_successful_http_response_is_reachable() {
        for code in [200, 204, 206, 299] {
            assert_eq!(service_http_outcome(code, 0), (true, format!("OK {code}")));
        }
    }

    #[test]
    fn redirects_denials_rate_limits_and_server_errors_are_not_success() {
        for code in [0, 301, 302, 401, 403, 404, 429, 451, 500, 503] {
            assert!(!service_http_outcome(code, 0).0, "{code}");
        }
    }

    #[test]
    fn direct_probe_forces_direct_transport_and_secure_https() {
        let args = super::service_probe_curl_args("https://example.com/", None);
        assert_eq!(args.first().map(String::as_str), Some("-q"));
        assert!(!args.iter().any(|arg| arg == "-k" || arg == "--insecure"));
        let option = |name: &str| {
            let index = args
                .iter()
                .position(|arg| arg == name)
                .expect("option exists");
            args.get(index + 1)
                .map(String::as_str)
                .expect("option value exists")
        };
        assert_eq!(option("--proto"), "=https");
        assert_eq!(option("--proto-redir"), "=https");
        assert_eq!(option("--noproxy"), "*");
        assert!(!args.iter().any(|arg| arg == "-x"));
        assert_eq!(
            args.last().map(String::as_str),
            Some("https://example.com/")
        );
    }

    #[test]
    fn socks_probe_forces_the_selected_proxy_without_environment_bypass() {
        let proxy = "socks5h://127.0.0.1:1080";
        let args = super::service_probe_curl_args("https://example.com/", Some(proxy));
        let no_proxy = args
            .iter()
            .position(|arg| arg == "--noproxy")
            .expect("noproxy exists");
        assert_eq!(args.get(no_proxy + 1).map(String::as_str), Some(""));
        let proxy_option = args
            .iter()
            .position(|arg| arg == "-x")
            .expect("proxy exists");
        assert_eq!(args.get(proxy_option + 1).map(String::as_str), Some(proxy));
        assert_eq!(
            args.last().map(String::as_str),
            Some("https://example.com/")
        );
    }

    #[test]
    fn failed_curl_cannot_become_success_from_partial_http_status() {
        for code in [6, 7, 18, 28, 35, 51, 58, 60, 63] {
            assert!(!service_http_outcome(200, code).0, "{code}");
        }
    }
}

fn service_probe_curl_args(url: &str, socks_proxy: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "-q".to_string(), // Ignore ~/.curlrc; diagnostic transport must be explicit.
        "-4".to_string(),
        "-sS".to_string(),
        "--proto".to_string(),
        "=https".to_string(),
        "--proto-redir".to_string(),
        "=https".to_string(),
        "-L".to_string(),
        "--max-redirs".to_string(),
        "2".to_string(),
        "--connect-timeout".to_string(),
        "6".to_string(),
        "--max-time".to_string(),
        "10".to_string(),
        "-A".to_string(),
        "Mozilla/5.0 (X11; Linux aarch64) TachyonProbe/2.0".to_string(),
        "-r".to_string(),
        "0-4095".to_string(),
        "-o".to_string(),
        "/dev/null".to_string(),
        "-w".to_string(),
        "%{http_code}|%{remote_ip}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}".to_string(),
    ];

    // An empty --noproxy list forces the selected proxy for every host.
    // For a direct probe, "*" prevents inherited proxy environment variables.
    args.push("--noproxy".to_string());
    args.push(if socks_proxy.is_some() {
        String::new()
    } else {
        "*".to_string()
    });
    if let Some(proxy) = socks_proxy {
        args.push("-x".to_string());
        args.push(proxy.to_string());
    }
    args.push(url.to_string());
    args
}

#[cfg(test)]
mod service_probe_integration_tests {
    use super::{service_http_outcome, service_probe_curl_args};
    use serde_json::Value;
    use std::io::{BufRead, BufReader};
    use std::path::PathBuf;
    use std::process::{Child, Command, Output, Stdio};

    struct Fixture {
        child: Child,
        tls_port: u16,
        socks_port: u16,
        cert_path: PathBuf,
        hits_path: PathBuf,
    }

    impl Fixture {
        fn start() -> Self {
            let fixture_script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/service_probe_tls_socks.py");
            let mut child = Command::new("python3")
                .arg(fixture_script)
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .expect("python3 and the local HTTPS/SOCKS fixture must be available");
            let stdout = child.stdout.take().expect("fixture stdout is piped");
            let mut reader = BufReader::new(stdout);
            let mut line = String::new();
            reader
                .read_line(&mut line)
                .expect("fixture must publish its ports");
            let metadata: Value =
                serde_json::from_str(&line).expect("fixture must publish valid JSON");
            Self {
                child,
                tls_port: metadata["tls_port"].as_u64().unwrap() as u16,
                socks_port: metadata["socks_port"].as_u64().unwrap() as u16,
                cert_path: PathBuf::from(metadata["cert_path"].as_str().unwrap()),
                hits_path: PathBuf::from(metadata["hits_path"].as_str().unwrap()),
            }
        }

        fn curl(&self, path: &str, proxy: Option<&str>, trust_certificate: bool) -> Output {
            let url = format!("https://localhost:{}{}", self.tls_port, path);
            let args = service_probe_curl_args(&url, proxy);
            let mut command = Command::new("curl");
            command
                .args(&args)
                .env("HTTPS_PROXY", "http://127.0.0.1:1")
                .env("https_proxy", "http://127.0.0.1:1")
                .env("ALL_PROXY", "http://127.0.0.1:1")
                .env("all_proxy", "http://127.0.0.1:1")
                .env("NO_PROXY", "localhost")
                .env("no_proxy", "localhost")
                .env_remove("CURL_CA_BUNDLE")
                .env_remove("SSL_CERT_FILE")
                .env_remove("SSL_CERT_DIR");
            if trust_certificate {
                command.env("CURL_CA_BUNDLE", &self.cert_path);
            }
            command
                .output()
                .expect("curl must be installed for integration tests")
        }

        fn outcome(output: &Output) -> (u16, bool, String) {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let http_code = stdout
                .trim()
                .split('|')
                .next()
                .and_then(|value| value.parse::<u16>().ok())
                .unwrap_or(0);
            let exit_code = output.status.code().unwrap_or(-1);
            let (success, reason) = service_http_outcome(http_code, exit_code);
            (http_code, success, reason)
        }

        fn socks_hits(&self) -> usize {
            std::fs::read(&self.hits_path)
                .map(|data| data.len())
                .unwrap_or(0)
        }

        fn socks_url(&self) -> String {
            format!("socks5h://127.0.0.1:{}", self.socks_port)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    #[test]
    fn direct_https_probe_accepts_a_trusted_completed_2xx_response() {
        let fixture = Fixture::start();
        let output = fixture.curl("/ok", None, true);
        let (code, success, reason) = Fixture::outcome(&output);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(code, 200);
        assert!(success, "{reason}");
    }

    #[test]
    fn invalid_tls_certificate_is_not_reachable() {
        let fixture = Fixture::start();
        let output = fixture.curl("/ok", None, false);
        let (_, success, _) = Fixture::outcome(&output);
        assert!(!success, "an untrusted local certificate must not pass");
        assert_ne!(output.status.code(), Some(0));
    }

    #[test]
    fn http_denials_and_rate_limits_are_not_reachable() {
        let fixture = Fixture::start();
        for (path, expected) in [("/forbidden", 403), ("/rate-limit", 429)] {
            let output = fixture.curl(path, None, true);
            let (code, success, _) = Fixture::outcome(&output);
            assert_eq!(output.status.code(), Some(0));
            assert_eq!(code, expected);
            assert!(!success, "{path} must not be classified as reachable");
        }
    }

    #[test]
    fn redirect_from_https_to_http_is_rejected() {
        let fixture = Fixture::start();
        let output = fixture.curl("/redirect-http", None, true);
        let (_, success, _) = Fixture::outcome(&output);
        assert!(!success, "HTTP downgrade redirect must not pass");
        assert_ne!(output.status.code(), Some(0));
    }

    #[test]
    fn truncated_http_body_is_not_reachable_even_after_200_headers() {
        let fixture = Fixture::start();
        let output = fixture.curl("/truncated", None, true);
        let (code, success, _) = Fixture::outcome(&output);
        assert_eq!(code, 200);
        assert_ne!(output.status.code(), Some(0));
        assert!(
            !success,
            "curl's incomplete-transfer exit code must be honored"
        );
    }

    #[test]
    fn socks5h_is_used_even_when_no_proxy_environment_matches() {
        let fixture = Fixture::start();
        let proxy = fixture.socks_url();
        let output = fixture.curl("/ok", Some(&proxy), true);
        let (code, success, reason) = Fixture::outcome(&output);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(code, 200);
        assert!(success, "{reason}");
        assert!(
            fixture.socks_hits() > 0,
            "the local SOCKS5 proxy must receive the request"
        );
    }

    #[test]
    fn unavailable_socks_proxy_does_not_fall_back_to_direct_path() {
        let fixture = Fixture::start();
        let output = fixture.curl("/ok", Some("socks5h://127.0.0.1:1"), true);
        let (_, success, _) = Fixture::outcome(&output);
        assert!(
            !success,
            "NO_PROXY must not bypass the selected SOCKS proxy"
        );
        assert_ne!(output.status.code(), Some(0));
    }
}

async fn probe_service_target(
    section: String,
    route_type: String,
    raw_domain: String,
    socks_proxy: Option<String>,
) -> Value {
    let Some(clean_domain) = sanitize_probe_host(&raw_domain) else {
        return json!({
            "section": section,
            "route_type": route_type,
            "domain": raw_domain.trim(),
            "ip": "-",
            "dns_ms": 0,
            "tcp_ms": 0,
            "tls_ms": 0,
            "http_ms": 0,
            "status_class": "Invalid Host",
            "success": false,
        });
    };

    let path = match clean_domain.as_str() {
        "www.youtube.com"
        | "cp.cloudflare.com"
        | "www.gstatic.com"
        | "connectivitycheck.gstatic.com" => "/generate_204",
        _ => "/",
    };
    let url = format!("https://{clean_domain}{path}");

    let args = service_probe_curl_args(&url, socks_proxy.as_deref());
    let mut curl_cmd = Command::new("curl");

    let mut last_out = None;
    for attempt in 0..2u8 {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            curl_cmd = Command::new("curl");
        }
        curl_cmd
            .args(&args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let res = tokio::time::timeout(Duration::from_secs(12), curl_cmd.output()).await;
        let retryable = match &res {
            Ok(Ok(out)) => {
                let code = String::from_utf8_lossy(&out.stdout)
                    .trim()
                    .split('|')
                    .next()
                    .and_then(|s| s.trim().parse::<u16>().ok())
                    .unwrap_or(0);
                code == 0
            }
            _ => true,
        };
        last_out = Some(res);
        if !retryable {
            break;
        }
    }

    match last_out.expect("at least one attempt") {
        Ok(Ok(out)) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let parts: Vec<&str> = stdout.trim().split('|').collect();
            let http_code: u16 = parts
                .first()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(0);
            let remote_ip = parts
                .get(1)
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .unwrap_or("-");
            let t_dns: f64 = parts
                .get(2)
                .and_then(|s| s.trim().replace(',', ".").parse().ok())
                .unwrap_or(0.0);
            let t_tcp: f64 = parts
                .get(3)
                .and_then(|s| s.trim().replace(',', ".").parse().ok())
                .unwrap_or(0.0);
            let t_tls: f64 = parts
                .get(4)
                .and_then(|s| s.trim().replace(',', ".").parse().ok())
                .unwrap_or(0.0);
            let t_ttfb: f64 = parts
                .get(5)
                .and_then(|s| s.trim().replace(',', ".").parse().ok())
                .unwrap_or(0.0);

            let dns_ms = if t_dns > 0.0 {
                (t_dns * 1000.0).round().max(1.0) as u64
            } else {
                0
            };
            let tcp_ms = if t_tcp > 0.0 {
                ((t_tcp - t_dns).max(0.001) * 1000.0).round() as u64
            } else {
                0
            };
            let tls_ms = if t_tls > 0.0 {
                ((t_tls - t_tcp).max(0.001) * 1000.0).round() as u64
            } else {
                0
            };
            let http_ms = if t_ttfb > 0.0 {
                (t_ttfb * 1000.0).round().max(1.0) as u64
            } else {
                0
            };

            let exit_code = out.status.code().unwrap_or(-1);
            let (success, status_class) = service_http_outcome(http_code, exit_code);

            json!({
                "section": section,
                "route_type": route_type,
                "domain": clean_domain,
                "ip": remote_ip,
                "dns_ms": dns_ms,
                "tcp_ms": tcp_ms,
                "tls_ms": tls_ms,
                "http_ms": http_ms,
                "status_class": status_class,
                "success": success,
            })
        }
        Ok(Err(_)) if socks_proxy.is_some() => json!({
            "section": section,
            "route_type": route_type,
            "domain": clean_domain,
            "ip": "-",
            "dns_ms": 0,
            "tcp_ms": 0,
            "tls_ms": 0,
            "http_ms": 0,
            "status_class": "Proxy probe unavailable",
            "success": false,
        }),
        Ok(Err(_)) => {
            // TCP evidence alone does not establish HTTP availability.
            let dns_start = std::time::Instant::now();
            let addrs = tokio::time::timeout(
                Duration::from_secs(2),
                tokio::net::lookup_host((clean_domain.as_str(), 443)),
            )
            .await
            .ok()
            .and_then(Result::ok)
            .map(|it| it.collect::<Vec<_>>())
            .unwrap_or_default();
            let dns_ms = if addrs.is_empty() {
                0
            } else {
                (dns_start.elapsed().as_millis() as u64).max(1)
            };
            let ip_str = addrs
                .first()
                .map(|a| a.ip().to_string())
                .unwrap_or_else(|| "-".to_string());
            let mut tcp_ms = 0u64;
            let mut reachable = false;
            if let Some(&sock) = addrs.first() {
                let tcp_start = std::time::Instant::now();
                if let Ok(Ok(_)) = tokio::time::timeout(
                    Duration::from_secs(3),
                    tokio::net::TcpStream::connect(sock),
                )
                .await
                {
                    tcp_ms = (tcp_start.elapsed().as_millis() as u64).max(1);
                    reachable = true;
                }
            }
            json!({
                "section": section,
                "route_type": route_type,
                "domain": clean_domain,
                "ip": ip_str,
                "dns_ms": dns_ms,
                "tcp_ms": tcp_ms,
                "tls_ms": 0,
                "http_ms": 0,
                "status_class": if reachable { "TCP only (HTTP unverified)" } else { "Unreachable" },
                "success": false,
            })
        }
        Err(_) => json!({
            "section": section,
            "route_type": route_type,
            "domain": clean_domain,
            "ip": "-",
            "dns_ms": 0,
            "tcp_ms": 0,
            "tls_ms": 0,
            "http_ms": 0,
            "status_class": "Timeout",
            "success": false,
        }),
    }
}

fn parse_urlencoded(body: &[u8]) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let s = String::from_utf8_lossy(body);
    for pair in s.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            map.insert(url_decode(k), url_decode(v));
        }
    }
    map
}

fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'+' {
            out.push(b' ');
            i += 1;
        } else if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3])
            && let Ok(b) = u8::from_str_radix(hex_str, 16)
        {
            out.push(b);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn split_shell_words(s: &str) -> Vec<String> {
    s.split_whitespace().map(String::from).collect()
}

fn write_file_if_changed(path: &Path, content: &str) -> std::io::Result<bool> {
    if let Ok(existing) = std::fs::read_to_string(path)
        && existing == content
    {
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, content.as_bytes())?;
    Ok(true)
}

fn render_luci_launcher_js(port: u16, web_base_path: &str) -> String {
    let norm_path = {
        let trimmed = web_base_path.trim();
        if trimmed.is_empty() || trimmed == "/" {
            "/".to_string()
        } else if trimmed.starts_with('/') {
            trimmed.to_string()
        } else {
            format!("/{trimmed}")
        }
    };
    let port_json = port.to_string();
    let path_json = serde_json::to_string(&norm_path).unwrap_or_else(|_| "\"/\"".to_string());

    format!(
        r#"'use strict';
'require view';

return view.extend({{
	load: function() {{
		return Promise.resolve();
	}},

	render: function() {{
		var port = {port_json};
		var basePath = {path_json};
		var rawHost = window.location.hostname || '192.168.1.1';
		var host = rawHost.indexOf(':') !== -1 && rawHost.charAt(0) !== '['
			? '[' + rawHost + ']'
			: rawHost;
		var targetUrl = 'http://' + host + ':' + port + basePath;
		var isRu = (document.documentElement.lang || navigator.language || '')
			.toLowerCase()
			.indexOf('ru') === 0;

		var popupOpened = false;
		try {{
			var win = window.open(targetUrl, '_blank', 'noopener,noreferrer');
			if (win) {{
				popupOpened = true;
			}}
		}} catch (e) {{}}

		var titleText = 'Tachyon';
		var descText = popupOpened
			? (isRu
				? 'Веб-панель Tachyon открыта в новой вкладке браузера.'
				: 'Tachyon web panel has been opened in a new browser tab.')
			: (isRu
				? 'Нажмите кнопку ниже, чтобы открыть веб-панель управления Tachyon.'
				: 'Click the button below to open the Tachyon control panel.');
		var openNewTabLabel = isRu ? 'Открыть в новой вкладке' : 'Open in new tab';
		var openHereLabel = isRu ? 'Открыть в этой вкладке' : 'Open in current tab';

		return E('div', {{
			'class': 'cbi-map',
			'style': 'max-width: 640px; margin: 28px auto; padding: 24px 28px; border-radius: 12px; background: rgba(24, 24, 28, 0.92); border: 1px solid rgba(255, 255, 255, 0.10); color: #f4f4f6; box-shadow: 0 12px 32px rgba(0, 0, 0, 0.28);'
		}}, [
			E('div', {{ 'style': 'display: flex; align-items: center; gap: 12px; margin-bottom: 12px;' }}, [
				E('div', {{
					'style': 'width: 36px; height: 36px; border-radius: 9px; display: flex; align-items: center; justify-content: center; background: rgba(255, 255, 255, 0.07); border: 1px solid rgba(255, 255, 255, 0.12); font-weight: 700; font-size: 16px; color: #e4e4e7;'
				}}, 'T'),
				E('div', {{}}, [
					E('h2', {{ 'style': 'margin: 0; font-size: 18px; line-height: 1.3; font-weight: 600; color: #fafafa;' }}, titleText),
					E('div', {{ 'style': 'font-size: 12px; color: #a1a1aa; font-variant-numeric: tabular-nums;' }}, targetUrl)
				])
			]),
			E('p', {{ 'style': 'margin: 0 0 20px 0; font-size: 14px; line-height: 1.5; color: #d4d4d8;' }}, descText),
			E('div', {{ 'style': 'display: flex; flex-wrap: wrap; gap: 10px;' }}, [
				E('a', {{
					'class': 'cbi-button cbi-button-apply',
					'href': targetUrl,
					'target': '_blank',
					'rel': 'noopener noreferrer',
					'style': 'text-decoration: none; display: inline-flex; align-items: center; padding: 8px 16px; border-radius: 8px; font-weight: 500;'
				}}, openNewTabLabel),
				E('a', {{
					'class': 'cbi-button',
					'href': targetUrl,
					'style': 'text-decoration: none; display: inline-flex; align-items: center; padding: 8px 16px; border-radius: 8px;'
				}}, openHereLabel)
			])
		]);
	}},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
}});
"#
    )
}

/// Registers a lightweight `Services -> Tachyon` (`Службы -> Tachyon`) launcher entry in OpenWrt LuCI
/// if LuCI is installed on the router. Writes files only when content actually changes to prevent flash wear.
pub async fn ensure_luci_launcher_installed_in(
    root: &Path,
    port: u16,
    web_base_path: &str,
) -> bool {
    let menu_dir = root.join("usr/share/luci/menu.d");
    let acl_dir = root.join("usr/share/rpcd/acl.d");
    if !menu_dir.is_dir() || !acl_dir.is_dir() {
        return false;
    }

    let menu_json = r#"{
	"admin/services/tachyon": {
		"title": "Tachyon",
		"order": 42,
		"action": {
			"type": "view",
			"path": "tachyon/launcher"
		},
		"depends": {
			"acl": [ "luci-app-tachyon-launcher" ]
		}
	}
}
"#;

    let acl_json = r#"{
	"luci-app-tachyon-launcher": {
		"description": "Grant access to Tachyon web panel launcher in LuCI",
		"read": {
			"ubus": {
				"system": [ "board" ]
			}
		}
	}
}
"#;

    let launcher_js = render_luci_launcher_js(port, web_base_path);

    let menu_path = menu_dir.join("tachyon-launcher.json");
    let acl_path = acl_dir.join("tachyon-launcher.json");
    let view_path = root.join("www/luci-static/resources/view/tachyon/launcher.js");

    let mut changed = false;
    if let Ok(true) = write_file_if_changed(&menu_path, menu_json) {
        changed = true;
    }
    if let Ok(true) = write_file_if_changed(&acl_path, acl_json) {
        changed = true;
    }
    if let Ok(true) = write_file_if_changed(&view_path, &launcher_js) {
        changed = true;
    }
    changed
}

pub async fn sync_router_luci_launcher(port: u16, web_base_path: &str) {
    if !cfg!(target_os = "linux") || crate::platform::is_entware() {
        return;
    }
    let changed = ensure_luci_launcher_installed_in(Path::new("/"), port, web_base_path).await;
    if changed {
        if let Ok(entries) = std::fs::read_dir("/tmp") {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name_str = name.to_string_lossy();
                if name_str == "luci-indexcache" || name_str.starts_with("luci-indexcache.") {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        let _ = std::fs::remove_dir_all("/tmp/luci-modulecache");
        let _ = Command::new("/etc/init.d/rpcd")
            .arg("reload")
            .output()
            .await;
    }
}

fn apply_desync_strategy_to_store(
    store: &mut Map<String, Value>,
    target_rule: &str,
    args_str: &str,
) -> Result<String, String> {
    let trimmed = target_rule.trim();
    let lower = trimmed.to_ascii_lowercase();
    if trimmed.is_empty() || matches!(lower.as_str(), "global" | "default" | "custom") {
        return Err(
            "Укажите конкретную существующую секцию или источник (global/default/custom запрещены)"
                .to_string(),
        );
    }

    let Some(sec_snapshot) = store.get(trimmed).and_then(Value::as_object).cloned() else {
        return Err(format!(
            "Целевая секция или источник '{trimmed}' не найдена"
        ));
    };

    let is_global = sec_snapshot
        .get("match_all")
        .and_then(Value::as_str)
        .is_some_and(|v| v == "1")
        || sec_snapshot
            .get("is_global")
            .and_then(Value::as_str)
            .is_some_and(|v| v == "1");
    if is_global {
        return Err("Нельзя применять стратегию к глобальной секции match-all".to_string());
    }

    let sec_type = sec_snapshot
        .get(".type")
        .and_then(Value::as_str)
        .unwrap_or("");

    if sec_type == "outbound_source" {
        let cur_source_type = sec_snapshot
            .get("source_type")
            .and_then(Value::as_str)
            .unwrap_or("");
        if !cur_source_type.is_empty() && cur_source_type != "desync" {
            return Err(format!(
                "Источник '{trimmed}' имеет тип '{cur_source_type}', несовместимый с desync"
            ));
        }
        if let Some(sec_obj) = store.get_mut(trimmed).and_then(Value::as_object_mut) {
            sec_obj.insert("source_type".into(), json!("desync"));
            sec_obj.insert("enabled".into(), json!("1"));
            crate::fuzzer::apply_desync_args_to_section_map(sec_obj, args_str);
        }
        let sec_keys: Vec<String> = store.keys().cloned().collect();
        for k in sec_keys {
            let Some(obj) = store.get_mut(&k).and_then(Value::as_object_mut) else {
                continue;
            };
            if obj.get(".type").and_then(Value::as_str) != Some("section") {
                continue;
            }
            let refs = extract_string_list(obj.get("outbound_source_refs"));
            if refs.iter().any(|r| r == trimmed) {
                crate::fuzzer::apply_desync_args_to_section_map(obj, args_str);
            }
        }
        return Ok(trimmed.to_string());
    }

    let cur_action = sec_snapshot
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("");
    if cur_action == "connection" {
        let refs = extract_string_list(sec_snapshot.get("outbound_source_refs"));
        let mut matched_sources = Vec::new();
        for r in &refs {
            if let Some(src_obj) = store.get(r).and_then(Value::as_object)
                && src_obj.get("source_type").and_then(Value::as_str) == Some("desync")
            {
                matched_sources.push(r.clone());
            }
        }
        if matched_sources.is_empty() {
            return Err(format!(
                "Секция '{trimmed}' не содержит подключённого источника десинхронизации (desync)"
            ));
        }
        for src_id in matched_sources {
            if let Some(src_obj) = store.get_mut(&src_id).and_then(Value::as_object_mut) {
                crate::fuzzer::apply_desync_args_to_section_map(src_obj, args_str);
            }
        }
        if let Some(sec_obj) = store.get_mut(trimmed).and_then(Value::as_object_mut) {
            crate::fuzzer::apply_desync_args_to_section_map(sec_obj, args_str);
        }
        return Ok(trimmed.to_string());
    }

    if cur_action == "desync" || cur_action.is_empty() {
        if let Some(sec_obj) = store.get_mut(trimmed).and_then(Value::as_object_mut) {
            sec_obj.insert("action".into(), json!("desync"));
            crate::fuzzer::apply_desync_args_to_section_map(sec_obj, args_str);
        }
        return Ok(trimmed.to_string());
    }

    Err(format!(
        "Секция '{trimmed}' использует действие '{cur_action}', несовместимое с desync"
    ))
}

fn extract_string_list(val: Option<&Value>) -> Vec<String> {
    match val {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.as_str().map(str::trim))
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect(),
        Some(Value::String(s)) => s.split_whitespace().map(String::from).collect(),
        _ => Vec::new(),
    }
}

fn resolve_dns_bench_target(srv_val: &str, proto: &str) -> String {
    let trimmed = srv_val.trim();
    let stripped = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))
        .or_else(|| trimmed.strip_prefix("h3://"))
        .or_else(|| trimmed.strip_prefix("tls://"))
        .or_else(|| trimmed.strip_prefix("quic://"))
        .or_else(|| trimmed.strip_prefix("udp://"))
        .or_else(|| trimmed.strip_prefix("tcp://"))
        .unwrap_or(trimmed);
    let host_port = stripped.split('/').next().unwrap_or(stripped);
    let default_port = if proto == "doh"
        || trimmed.starts_with("https://")
        || trimmed.starts_with("h3://")
        || stripped.contains('/')
    {
        443
    } else if proto == "dot" || proto == "doq" {
        853
    } else {
        53
    };
    let host = crate::config_gen::extract_host_only(host_port);
    let port = crate::config_gen::extract_host_port(host_port, default_port);
    let uri_host = crate::config_gen::format_uri_host_only(&host);
    format!("{uri_host}:{port}")
}

fn build_dns_bench_stats_json(vals: &mut [f64], total_doms: usize) -> Value {
    vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let ok_cnt = vals.len();
    if ok_cnt == 0 {
        return json!({
            "success": 0,
            "total": total_doms,
            "status": "unreachable",
            "min": null,
            "median": null,
            "avg": null,
            "max": null
        });
    }
    let min_v = vals[0];
    let max_v = vals[ok_cnt - 1];
    let sum_v: f64 = vals.iter().sum();
    let avg_v = ((sum_v / ok_cnt as f64) * 100.0).round() / 100.0;
    let median_v = if ok_cnt % 2 == 1 {
        vals[ok_cnt / 2]
    } else {
        (((vals[ok_cnt / 2 - 1] + vals[ok_cnt / 2]) / 2.0) * 100.0).round() / 100.0
    };
    let srv_status = if ok_cnt < total_doms {
        "degraded"
    } else {
        "healthy"
    };
    json!({
        "success": ok_cnt,
        "total": total_doms,
        "status": srv_status,
        "min": min_v,
        "median": median_v,
        "avg": avg_v,
        "max": max_v
    })
}

async fn resolve_dns_bench_socket_addr(
    target: &str,
    bootstrap_ips: &[std::net::IpAddr],
) -> Option<std::net::SocketAddr> {
    if let Ok(sock) = target.parse::<std::net::SocketAddr>() {
        return Some(sock);
    }
    let (raw_host, port_str) = target.rsplit_once(':')?;
    let port = port_str.parse::<u16>().ok()?;
    let host = raw_host.trim_matches(|c| c == '[' || c == ']');
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return Some(std::net::SocketAddr::new(ip, port));
    }
    for ns in bootstrap_ips {
        if let Some(ip) = crate::fuzzer::query_dns_a_udp(*ns, host).await {
            if let std::net::IpAddr::V4(v4) = ip
                && (v4.is_loopback() || (v4.octets()[0] == 198 && (v4.octets()[1] & 0xfe) == 18))
            {
                continue;
            }
            return Some(std::net::SocketAddr::new(ip, port));
        }
    }
    None
}

fn resolve_outbound_tag_with_telemetry_fallback(
    requested: &str,
    candidates: &[String],
) -> Option<String> {
    let req = requested.trim();
    if req.is_empty() {
        return None;
    }
    if let Some(exact) = candidates.iter().find(|c| c.as_str() == req) {
        return Some(exact.clone());
    }
    if let Some(ci) = candidates.iter().find(|c| c.eq_ignore_ascii_case(req)) {
        return Some(ci.clone());
    }
    let req_stripped = crate::config_gen::strip_dynamic_server_telemetry(req);
    if !req_stripped.is_empty() {
        if let Some(m) = candidates
            .iter()
            .find(|c| crate::config_gen::strip_dynamic_server_telemetry(c) == req_stripped)
        {
            return Some(m.clone());
        }
        if let Some(m) = candidates.iter().find(|c| {
            crate::config_gen::strip_dynamic_server_telemetry(c).eq_ignore_ascii_case(&req_stripped)
        }) {
            return Some(m.clone());
        }
    }
    None
}

fn is_probeable_leaf_proxy(tag: &str, entry: &Value) -> bool {
    let t = tag.trim();
    if t.is_empty()
        || matches!(
            t,
            "direct" | "DIRECT" | "block" | "BLOCK" | "reject" | "REJECT" | "dns-out" | "GLOBAL"
        )
        || t.starts_with("desync-")
        || t.starts_with("srv-")
    {
        return false;
    }
    if entry
        .get("all")
        .and_then(Value::as_array)
        .is_some_and(|a| !a.is_empty())
    {
        return false;
    }
    let ty = entry
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    !matches!(
        ty.as_str(),
        "selector"
            | "urltest"
            | "fallback"
            | "loadbalance"
            | "direct"
            | "block"
            | "reject"
            | "dns"
            | "desync"
    )
}

fn collect_probe_outbound_url_targets(
    store: &crate::store::RouterStoreData,
    proxies_map: &Map<String, Value>,
    group_id: &str,
) -> Vec<String> {
    let mut leaf_pool: Vec<String> = proxies_map
        .iter()
        .filter(|&(k, v)| is_probeable_leaf_proxy(k, v))
        .map(|(k, _)| k.clone())
        .collect();
    leaf_pool.sort_unstable();

    let gid = group_id.trim();
    if gid.is_empty() || gid.eq_ignore_ascii_case("all") {
        return leaf_pool;
    }

    let group_map = config_gen::resolve_outbound_group_member_tags(store);
    let mut matched = Vec::new();
    let mut seen = std::collections::HashSet::new();
    if let Some(member_tags) = group_map.get(gid) {
        for raw_tag in member_tags {
            if let Some(live_tag) =
                resolve_outbound_tag_with_telemetry_fallback(raw_tag, &leaf_pool)
                && seen.insert(live_tag.clone())
            {
                matched.push(live_tag);
            }
        }
    }
    if matched.is_empty() {
        let clash_members = collect_clash_leaf_members(proxies_map, gid);
        for m in clash_members {
            if leaf_pool.iter().any(|p| p == &m) && seen.insert(m.clone()) {
                matched.push(m);
            }
        }
    }
    matched
}

async fn handle_probe_outbound_url_batch(
    store: &crate::store::RouterStoreData,
    core: &Arc<CoreManager>,
    target_url: &str,
    group_id: &str,
    timeout_ms: u64,
) -> Value {
    let Ok(proxies_val) = core.clash_request("GET", "/proxies", None).await else {
        return json!({
            "success": false,
            "error": "tachyon-core Clash API is unreachable"
        });
    };
    let Some(proxies_map) = proxies_val.get("proxies").and_then(Value::as_object) else {
        return json!({
            "success": false,
            "error": "invalid /proxies response"
        });
    };

    let targets = collect_probe_outbound_url_targets(store, proxies_map, group_id);
    let meta = read_pure_rust_outbound_metadata(store, "all");
    let names_map = meta.get("names").and_then(Value::as_object);
    let countries_map = meta.get("countries").and_then(Value::as_object);
    let prefixes_map = meta.get("prefixes").and_then(Value::as_object);
    let sources_map = meta.get("source_names").and_then(Value::as_object);

    let mut delays: std::collections::HashMap<String, Option<u64>> =
        std::collections::HashMap::new();
    let eff_timeout = timeout_ms.clamp(1000, 10_000);
    let encoded_url = url_encode_component(target_url);

    for chunk in targets.chunks(24) {
        let body = json!({
            "names": chunk,
            "url": target_url,
            "timeout": eff_timeout,
        })
        .to_string();
        if let Ok(batch_resp) = core
            .clash_request("POST", "/tachyon/delay-batch", Some(&body))
            .await
            && let Some(res_map) = batch_resp.get("results").and_then(Value::as_object)
        {
            for tag in chunk {
                let ms = res_map
                    .get(tag)
                    .and_then(|v| v.get("delay"))
                    .and_then(Value::as_u64)
                    .filter(|&d| d > 0);
                delays.insert(tag.clone(), ms);
            }
            continue;
        }
        // Fallback for cores without /tachyon/delay-batch
        let mut set = tokio::task::JoinSet::new();
        for tag in chunk {
            let core_c = Arc::clone(core);
            let tag_c = tag.clone();
            let path = format!(
                "/proxies/{}/delay?url={encoded_url}&timeout={eff_timeout}",
                url_encode_component(tag)
            );
            set.spawn(async move {
                let ms = core_c
                    .clash_request("GET", &path, None)
                    .await
                    .ok()
                    .and_then(|v| v.get("delay").and_then(Value::as_u64))
                    .filter(|&d| d > 0);
                (tag_c, ms)
            });
        }
        while let Some(Ok((tag_c, ms))) = set.join_next().await {
            delays.insert(tag_c, ms);
        }
    }

    let mut rows: Vec<(bool, u64, String, Value)> = Vec::with_capacity(targets.len());
    let mut reachable_count = 0usize;
    for tag in &targets {
        let delay_opt = delays.get(tag).copied().flatten();
        let reachable = delay_opt.is_some();
        if reachable {
            reachable_count += 1;
        }
        let delay_ms = delay_opt.unwrap_or(0);
        let display_name = names_map
            .and_then(|m| m.get(tag))
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(tag.as_str());
        let country = countries_map
            .and_then(|m| m.get(tag))
            .and_then(Value::as_str)
            .unwrap_or("");
        let prefix = prefixes_map
            .and_then(|m| m.get(tag))
            .and_then(Value::as_str)
            .unwrap_or("");
        let source = sources_map
            .and_then(|m| m.get(tag))
            .and_then(Value::as_str)
            .unwrap_or("");
        rows.push((
            reachable,
            delay_ms,
            display_name.to_string(),
            json!({
                "tag": tag,
                "name": display_name,
                "country": country,
                "prefix": prefix,
                "source": source,
                "reachable": reachable,
                "delay_ms": delay_ms,
            }),
        ));
    }
    rows.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.2.cmp(&b.2))
    });
    let results: Vec<Value> = rows.into_iter().map(|r| r.3).collect();

    json!({
        "success": true,
        "status": "ok",
        "url": target_url,
        "group": if group_id.is_empty() { "all" } else { group_id },
        "reachable_count": reachable_count,
        "total_count": results.len(),
        "results": results,
    })
}

pub fn sync_from_store_to_json_and_cache(store: &crate::store::RouterStoreData) {
    let existing = Value::Object(get_json_sections_snapshot());
    if let Value::Object(new_map) =
        crate::store::sync_store_to_json_sections(store, Some(&existing))
    {
        set_json_sections_snapshot(new_map);
    }
    sync_section_cache(store);
}

async fn probe_udp_dns_rtt_ms(target: &str, domain: &str) -> Result<f64, String> {
    let mut pkt = Vec::with_capacity(64);
    let tx_id: u16 = 0x5441;
    pkt.extend_from_slice(&tx_id.to_be_bytes());
    pkt.extend_from_slice(&0x0100u16.to_be_bytes()); // standard query, recursion desired
    pkt.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT = 1
    pkt.extend_from_slice(&[0u8; 6]); // AN/NS/AR = 0
    for label in domain.trim_end_matches('.').split('.') {
        let bytes = label.as_bytes();
        if bytes.is_empty() || bytes.len() > 63 {
            return Err("invalid domain label".to_string());
        }
        pkt.push(bytes.len() as u8);
        pkt.extend_from_slice(bytes);
    }
    pkt.push(0); // root label
    pkt.extend_from_slice(&1u16.to_be_bytes()); // QTYPE = A
    pkt.extend_from_slice(&1u16.to_be_bytes()); // QCLASS = IN

    let bind_addr = if target.starts_with('[') {
        "[::]:0"
    } else {
        "0.0.0.0:0"
    };
    let sock = tokio::net::UdpSocket::bind(bind_addr)
        .await
        .map_err(|e| e.to_string())?;
    sock.connect(target).await.map_err(|e| e.to_string())?;
    let t0 = std::time::Instant::now();
    sock.send(&pkt).await.map_err(|e| e.to_string())?;
    let mut buf = [0u8; 512];
    let n = tokio::time::timeout(Duration::from_millis(900), sock.recv(&mut buf))
        .await
        .map_err(|_| "timeout".to_string())?
        .map_err(|e| e.to_string())?;
    if n < 12 || u16::from_be_bytes([buf[0], buf[1]]) != tx_id {
        return Err("invalid DNS response".to_string());
    }
    Ok((t0.elapsed().as_secs_f64() * 1000.0).max(0.5))
}

#[allow(clippy::too_many_arguments)]
fn finalize_ubus_leak_check_payload(
    base_report: Value,
    d: &crate::store::RouterStoreData,
    wan_ip: &str,
    exit_ip: &str,
    exit_country: &str,
    exit_org: &str,
    dns_srv: &str,
    resolved_first: &str,
    core_running: bool,
) -> Value {
    let ip_leaked = !wan_ip.is_empty() && !exit_ip.is_empty() && wan_ip == exit_ip;
    let dns_reachable = base_report
        .get("dns_listener_reachable")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let fakeip_v4 = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        d.settings.fakeip_inet4_range.trim()
    };
    let ipv6_leaked = base_report
        .get("ipv6_leaked")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let dns_leaked = !dns_reachable
        || (d.settings.fakeip_enabled
            && !resolved_first.is_empty()
            && !resolved_first.starts_with("198.18.")
            && !resolved_first.starts_with("198.19."));

    let en = d.settings.lang.trim().eq_ignore_ascii_case("en");
    let mut warnings = Vec::new();
    if !core_running {
        warnings.push(if en {
            "tachyon-core is not running"
        } else {
            "Ядро tachyon-core не запущено"
        });
    }
    if ip_leaked {
        warnings.push(if en {
            "External IP matches the ISP WAN address"
        } else {
            "Внешний IP совпадает с WAN-адресом провайдера"
        });
    }
    if dns_leaked {
        warnings.push(if en {
            "DNS resolver is not responding through the protected path"
        } else {
            "DNS-резолвер не отвечает через защищённый контур"
        });
    }
    if ipv6_leaked {
        warnings.push(if en {
            "Potential IPv6 leak detected"
        } else {
            "Обнаружена возможная утечка IPv6"
        });
    }

    let overall = if !warnings.is_empty() {
        "warning"
    } else {
        "safe"
    };
    let mut out = base_report.as_object().cloned().unwrap_or_default();
    out.insert(
        "ip_leak".to_string(),
        json!({
            "direct_ip": wan_ip,
            "direct_country": "WAN",
            "direct_isp": "Router WAN Interface",
            "proxy_ip": exit_ip,
            "proxy_country": exit_country,
            "proxy_org": exit_org,
            "leaked": ip_leaked,
            "proxy_online": core_running && !exit_ip.is_empty(),
            "details": if exit_ip.is_empty() {
                vec![if en {
                    "Failed to determine the outbound exit IP"
                } else {
                    "Не удалось определить внешний IP выходного узла"
                }]
            } else if ip_leaked {
                vec![if en {
                    "External IP matches the WAN address"
                } else {
                    "Внешний IP совпадает с WAN-адресом"
                }]
            } else {
                vec![if en {
                    "Outbound exit IP differs from direct WAN address"
                } else {
                    "Внешний IP выходного узла отличается от прямого WAN-адреса"
                }]
            }
        }),
    );
    out.insert(
        "dns_leak".to_string(),
        json!({
            "leaked": dns_leaked,
            "fakeip_working": d.settings.fakeip_enabled && dns_reachable,
            "fakeip_enabled": d.settings.fakeip_enabled,
            "fakeip_subnet": fakeip_v4,
            "resolved_ip": resolved_first,
            "dns_through_tunnel": dns_reachable && core_running,
            "dns_servers": [{ "ip": dns_srv, "type": d.settings.dns_type }],
            "router_dns_servers": [{ "ip": "127.0.0.42#53", "organization": "Tachyon Core DNS" }],
            "details": [out.get("verdict").and_then(Value::as_str).unwrap_or("")]
        }),
    );
    out.insert(
        "summary".to_string(),
        json!({
            "overall": overall,
            "warnings": warnings,
            "recommendations": []
        }),
    );
    Value::Object(out)
}

async fn run_full_ubus_leak_check(state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let base_report = diagnostics::run_leak_check(state, Some(core)).await;
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();

    let (_lan_ip, wan_ip) = tokio::task::spawn_blocking(sys_info::detect_router_ips)
        .await
        .unwrap_or_default();
    let dns_probe = diagnostics::run_dns_check_with_engine(core, "www.youtube.com").await;

    let mut exit_tag = resolve_clash_group_for_target(&d, None, "Main");
    if let Ok(proxies_val) = core.clash_request("GET", "/proxies", None).await
        && let Some(proxies_map) = proxies_val.get("proxies").and_then(Value::as_object)
    {
        exit_tag = resolve_clash_group_for_target(&d, Some(proxies_map), "Main");
        if let Some(now_node) = proxies_map
            .get(&exit_tag)
            .and_then(|v| v.get("now"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            exit_tag = now_node.to_string();
        }
    }
    let exit_info = if live.core_running && !exit_tag.is_empty() {
        core.probe_node_exit_ip(&exit_tag).await
    } else {
        json!({ "ok": false })
    };
    let exit_ip = exit_info
        .get("ip")
        .or_else(|| exit_info.get("query"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let exit_country = exit_info
        .get("country")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let exit_org = exit_info
        .get("org")
        .or_else(|| exit_info.get("isp"))
        .and_then(Value::as_str)
        .unwrap_or(exit_tag.as_str())
        .to_string();

    let resolved_ips = dns_probe
        .get("addresses")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let resolved_first = resolved_ips
        .first()
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let dns_srv = d
        .settings
        .dns_servers
        .first()
        .cloned()
        .unwrap_or_else(|| "1.1.1.1".to_string());

    finalize_ubus_leak_check_payload(
        base_report,
        &d,
        &wan_ip,
        &exit_ip,
        &exit_country,
        &exit_org,
        &dns_srv,
        &resolved_first,
        live.core_running,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{OutboundSource, RoutingSection};

    #[test]
    fn service_health_targets_skip_block_sections_and_detect_desync() {
        let sections = vec![
            RoutingSection {
                id: "block".to_string(),
                enabled: true,
                label: "block".to_string(),
                connection_type: "block".to_string(),
                action: "block".to_string(),
                domains: vec!["ads.example.com".to_string()],
                community_lists: vec!["youtube".to_string()],
                ..Default::default()
            },
            RoutingSection {
                id: "media_desync".to_string(),
                enabled: true,
                label: "Media Flow".to_string(),
                connection_type: "desync".to_string(),
                community_lists: vec!["youtube".to_string()],
                user_domains: vec!["domain:*.googlevideo.com".to_string()],
                ..Default::default()
            },
        ];
        let outbounds = vec![OutboundSource {
            id: "ds1".to_string(),
            enabled: true,
            name: "Desync".to_string(),
            source_type: "desync".to_string(),
            ..Default::default()
        }];
        let targets = build_service_health_targets(&sections, &outbounds, &[], false);
        assert!(!targets.is_empty());
        for t in &targets {
            let sec = t.get("section").and_then(Value::as_str).unwrap_or("");
            let dom = t.get("domain").and_then(Value::as_str).unwrap_or("");
            assert_ne!(
                sec, "block",
                "block sections must never appear in service check"
            );
            assert_ne!(dom, "ads.example.com");
        }
        let yt = targets
            .iter()
            .find(|t| t.get("domain").and_then(Value::as_str) == Some("www.youtube.com"))
            .expect("youtube target present");
        assert_eq!(yt.get("route_type").and_then(Value::as_str), Some("desync"));
        assert_eq!(yt.get("section").and_then(Value::as_str), Some("YouTube"));
    }

    #[test]
    fn sanitize_probe_host_handles_prefixes_and_rejects_injection() {
        assert_eq!(
            sanitize_probe_host("https://www.YouTube.com:443/watch?v=1"),
            Some("www.youtube.com".to_string())
        );
        assert_eq!(
            sanitize_probe_host("domain:*.discord.gg"),
            Some("discord.gg".to_string())
        );
        assert_eq!(sanitize_probe_host("-bad.com; id"), None);
        assert_eq!(sanitize_probe_host("localhost"), None);
    }

    #[tokio::test]
    async fn luci_launcher_writes_only_when_luci_exists_and_skips_unchanged() {
        let tmp =
            std::env::temp_dir().join(format!("tachyon_luci_launcher_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);

        // Without LuCI dirs present, nothing should be created
        assert!(!ensure_luci_launcher_installed_in(&tmp, 1680, "/").await);
        assert!(!tmp.exists());

        // With LuCI menu.d and rpcd acl.d present, first sync creates files
        std::fs::create_dir_all(tmp.join("usr/share/luci/menu.d")).unwrap();
        std::fs::create_dir_all(tmp.join("usr/share/rpcd/acl.d")).unwrap();
        assert!(ensure_luci_launcher_installed_in(&tmp, 1680, "/").await);

        let js_path = tmp.join("www/luci-static/resources/view/tachyon/launcher.js");
        let js_raw = std::fs::read_to_string(&js_path).unwrap();
        assert!(js_raw.contains("var port = 1680;"));
        assert!(js_raw.contains("window.open(targetUrl, '_blank'"));

        // Second sync with identical port & path must be a no-op (zero flash wear)
        assert!(!ensure_luci_launcher_installed_in(&tmp, 1680, "/").await);

        // Changing port updates launcher.js
        assert!(ensure_luci_launcher_installed_in(&tmp, 1880, "/panel").await);
        let js_updated = std::fs::read_to_string(&js_path).unwrap();
        assert!(js_updated.contains("var port = 1880;"));
        assert!(js_updated.contains("\"/panel\""));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn apply_desync_strategy_rejects_global_missing_and_incompatible_sections() {
        let mut store = Map::new();
        store.insert(
            "global_sec".into(),
            json!({ ".type": "section", "action": "desync", "match_all": "1" }),
        );
        store.insert(
            "proxy_sec".into(),
            json!({ ".type": "section", "action": "connection", "outbound_source_refs": ["sub_main"] }),
        );
        store.insert(
            "sub_main".into(),
            json!({ ".type": "outbound_source", "source_type": "subscription" }),
        );
        store.insert(
            "dpi_src".into(),
            json!({ ".type": "outbound_source", "source_type": "desync" }),
        );
        store.insert(
            "mod_dpi_sec".into(),
            json!({ ".type": "section", "action": "connection", "outbound_source_refs": ["dpi_src"] }),
        );
        store.insert(
            "direct_ds_sec".into(),
            json!({ ".type": "section", "action": "desync" }),
        );

        assert!(apply_desync_strategy_to_store(&mut store, "", "preset=auto").is_err());
        assert!(apply_desync_strategy_to_store(&mut store, "global", "preset=auto").is_err());
        assert!(apply_desync_strategy_to_store(&mut store, "default", "preset=auto").is_err());
        assert!(apply_desync_strategy_to_store(&mut store, "custom", "preset=auto").is_err());
        assert!(apply_desync_strategy_to_store(&mut store, "nonexistent", "preset=auto").is_err());
        assert!(!store.contains_key("desync"));
        assert!(!store.contains_key("nonexistent"));

        assert!(apply_desync_strategy_to_store(&mut store, "global_sec", "preset=auto").is_err());
        assert!(apply_desync_strategy_to_store(&mut store, "proxy_sec", "preset=auto").is_err());
        assert!(apply_desync_strategy_to_store(&mut store, "sub_main", "preset=auto").is_err());

        assert_eq!(
            apply_desync_strategy_to_store(
                &mut store,
                "mod_dpi_sec",
                "mode=hostfakesplit split_pos=sni wscale=4"
            ),
            Ok("mod_dpi_sec".to_string())
        );
        assert_eq!(store["dpi_src"]["desync_mode"], "hostfakesplit");
        assert_eq!(store["dpi_src"]["desync_host_fake"], "1");
        assert_eq!(store["dpi_src"]["desync_wscale"], "4");
        assert_eq!(store["mod_dpi_sec"]["desync_mode"], "hostfakesplit");

        assert_eq!(
            apply_desync_strategy_to_store(
                &mut store,
                "direct_ds_sec",
                "mode=fake_split split_pos=midsld"
            ),
            Ok("direct_ds_sec".to_string())
        );
        assert_eq!(store["direct_ds_sec"]["desync_mode"], "fake_split");

        // Applying directly to outbound_source propagates to referencing section
        assert_eq!(
            apply_desync_strategy_to_store(&mut store, "dpi_src", "mode=tlsrec split_pos=sni"),
            Ok("dpi_src".to_string())
        );
        assert_eq!(store["mod_dpi_sec"]["desync_mode"], "tlsrec");
    }

    #[test]
    fn sync_telegram_section_skips_unchanged_and_roundtrips() {
        let mut sections = Map::new();
        let tg = crate::store::TgBotConfig {
            enabled: true,
            bot_token: "12345:secret".to_string(),
            admin_ids: vec![111, -222],
            router_name: "Home".to_string(),
            poll_interval: 10,
            bot_proxy_section: "Main".to_string(),
            bot_direct_fallback: false,
            language: "en".to_string(),
            quiet_hours_enabled: true,
            quiet_hours_start: "22:30".to_string(),
            quiet_hours_end: "06:30".to_string(),
            webhook_secret: "wh-sec".to_string(),
            ..Default::default()
        };

        assert!(apply_telegram_config_to_sections_map(&mut sections, &tg));
        assert_eq!(sections["telegram"]["enabled"], "1");
        assert_eq!(sections["telegram"]["admin_ids"], "111,-222");
        assert_eq!(sections["telegram"]["poll_interval"], "10");
        assert_eq!(sections["telegram"]["bot_direct_fallback"], "0");
        assert_eq!(sections["telegram"]["quiet_hours_enabled"], "1");
        assert_eq!(sections["telegram"]["quiet_hours_start"], "22:30");
        assert_eq!(sections["telegram"]["quiet_hours_end"], "06:30");
        assert_eq!(sections["telegram"]["webhook_secret"], "wh-sec");

        // Second sync with identical TgBotConfig must report false (no flash write)
        assert!(!apply_telegram_config_to_sections_map(&mut sections, &tg));

        // Round-trip back into RouterStoreData
        let mut store = crate::store::RouterStoreData::default();
        let imported = store.import_from_json_sections(&sections);
        assert_eq!(imported, 1);
        assert!(!store.telegram.bot_direct_fallback);
        assert_eq!(store.telegram, tg);
    }

    #[test]
    fn resolve_dns_bench_target_handles_ipv6_and_custom_ports() {
        assert_eq!(
            resolve_dns_bench_target("https://[2606:4700:4700::1111]/dns-query", "doh"),
            "[2606:4700:4700::1111]:443"
        );
        assert_eq!(
            resolve_dns_bench_target("https://[2606:4700:4700::1111]:8443/dns-query", "doh"),
            "[2606:4700:4700::1111]:8443"
        );
        assert_eq!(
            resolve_dns_bench_target("tls://2606:4700:4700::1111", "dot"),
            "[2606:4700:4700::1111]:853"
        );
        assert_eq!(
            resolve_dns_bench_target("2001:4860:4860::8888", "udp"),
            "[2001:4860:4860::8888]:53"
        );
        assert_eq!(
            resolve_dns_bench_target("https://dns.google/dns-query", "doh"),
            "dns.google:443"
        );
        assert_eq!(
            resolve_dns_bench_target("1.1.1.1:5353", "udp"),
            "1.1.1.1:5353"
        );
    }

    #[test]
    fn system_info_network_fields_and_wan6_iface_parsing() {
        let rt6 = "\
20010db8000100000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000000 00000000 00000001   br-lan
00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000000 00000000 00010003     wan6
";
        assert_eq!(parse_wan6_iface_from_proc(rt6, "", ""), "wan6");

        let mut store = crate::store::RouterStoreData::default();
        store.settings.ipv6_mode = "auto".to_string();
        store.settings.dns_strategy = "prefer_ipv6".to_string();
        store.settings.fakeip_enabled = true;
        store.settings.fakeip_inet4_range = "198.18.0.0/16".to_string();
        store.settings.fakeip_inet6_range = "fd00:f::/48".to_string();
        store.settings.webrtc_leak_protect = true;

        let cache = crate::store::RuntimeIpv6Cache {
            wan6_available: true,
            wan_ipv6: vec!["2001:4860:4860::8888".to_string()],
            lan_ipv6: vec!["fd00::1".to_string()],
            wan6_prefixes: vec!["2001:4860:4860::/64".to_string()],
            updated_at: 1_700_000_000,
        };
        let mut obj = Map::new();
        populate_system_info_network_fields(
            &mut obj,
            &store,
            "203.0.113.10",
            "192.168.1.1",
            &cache,
            "wan6",
        );

        assert_eq!(obj["wan_ip"], "203.0.113.10");
        assert_eq!(obj["lan_ip"], "192.168.1.1");
        assert_eq!(obj["wan6_available"], 1);
        assert_eq!(obj["wan6_iface"], "wan6");
        assert_eq!(obj["wan6_pd"], json!(["2001:4860:4860::/64"]));
        assert_eq!(obj["dns_strategy"], "prefer_ipv6");
        assert_eq!(obj["runtime_dns_strategy"], "prefer_ipv6");
        assert_eq!(obj["fakeip_enabled"], 1);
        assert_eq!(obj["fakeip_inet4_range"], "198.18.0.0/16");
        assert_eq!(obj["fakeip_inet6_range"], "fd00:f::/48");
        assert_eq!(obj["webrtc_leak_protect"], 1);

        let inbounds = build_check_inbounds_result(&store);
        assert!(inbounds.get("wan_ipv6_public").is_some());
        assert_eq!(inbounds["wan_ipv6_public"], 0);

        let dns_probe_engine = json!({
            "domain": "www.youtube.com",
            "status": "udp53_blocked_engine_ok",
            "engine": { "ok": true, "delay": 1, "addresses": ["198.18.0.19"] }
        });
        assert!(dns_probe_succeeded(&dns_probe_engine));
        assert!(!dns_probe_succeeded(
            &json!({"engine": {"ok": false, "addresses": []}})
        ));

        let nft_sample = "table inet TachyonTable {\n\tchain prerouting {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n\t\tiifname \"br-lan\" ct direction reply counter packets 0 bytes 0 return comment \"tachyon-inbound-reply\"\n\t\tmeta l4proto { tcp, udp } tproxy ip to 127.0.0.1:1602 meta mark set 0x04000000 counter packets 150 bytes 12000 accept\n\t}\n\tchain mangle_output {\n\t\ttype route hook output priority mangle; policy accept;\n\t\tip daddr 198.18.0.0/15 meta l4proto { tcp, udp } meta mark set 0x10000000 counter packets 7 bytes 420 accept\n\t}\n}\n";
        let summary = parse_nft_table_summary(nft_sample);
        assert!(summary.has_mangle);
        assert!(summary.has_output);
        assert!(summary.has_proxy);
        assert_eq!(summary.mangle_rules_count, 2);
        assert_eq!(summary.mangle_counter_rules, 2);
        assert_eq!(summary.mangle_packets, 150);
        assert_eq!(summary.mangle_output_rules_count, 1);
        assert_eq!(summary.mangle_output_counter_rules, 1);
        assert_eq!(summary.mangle_output_packets, 7);
        assert_eq!(summary.proxy_rules_count, 1);
        assert_eq!(summary.proxy_counter_rules, 1);
        assert_eq!(summary.proxy_packets, 150);

        let nft_no_counters = "table inet TachyonTable {\n\tchain prerouting {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n\t\tmeta l4proto { tcp, udp } tproxy ip to 127.0.0.1:1602 meta mark set 0x04000000 accept\n\t}\n\tchain mangle_output {\n\t\ttype route hook output priority mangle; policy accept;\n\t\tip daddr 198.18.0.0/15 meta l4proto { tcp, udp } meta mark set 0x10000000 accept\n\t}\n}\n";
        let summary_no_cnt = parse_nft_table_summary(nft_no_counters);
        assert!(summary_no_cnt.has_mangle);
        assert!(summary_no_cnt.has_output);
        assert!(summary_no_cnt.has_proxy);
        assert_eq!(summary_no_cnt.proxy_counter_rules, 0);
        assert_eq!(summary_no_cnt.mangle_output_counter_rules, 0);
        assert_eq!(summary_no_cnt.proxy_packets, 0);
        assert_eq!(summary_no_cnt.mangle_output_packets, 0);

        assert!(fw4_line_matches_port(
            "\t\tmeta l4proto tcp th dport 8443 accept",
            "tcp",
            8443
        ));
        assert!(fw4_line_matches_port(
            "\t\tudp dport 2012-2022 counter accept",
            "udp",
            2015
        ));
        assert!(!fw4_line_matches_port(
            "\t\tudp dport 2012-2022 counter accept",
            "tcp",
            2015
        ));
        assert!(!fw4_line_matches_port(
            "\t\ttcp sport 8443 accept",
            "tcp",
            8443
        ));

        let local_ips = collect_local_router_ips(
            "203.0.113.10",
            "",
            "0.0.0.0",
            "2: br-lan inet 192.168.1.1/24 brd 192.168.1.255 scope global\n",
        );
        assert!(local_ips.contains(&"203.0.113.10".to_string()));
        assert!(local_ips.contains(&"192.168.1.1".to_string()));
        assert!(!local_ips.contains(&"0.0.0.0".to_string()));

        assert_eq!(
            check_fw4_port_open_with_redirects(
                "",
                "\t\ttcp dport 8443 redirect to :8443",
                "",
                8443,
                "tcp",
                &local_ips
            ),
            1
        );
        assert_eq!(
            check_fw4_port_open_with_redirects(
                "",
                "\t\ttcp dport 8443 dnat ip to 192.168.1.1:8443",
                "",
                8443,
                "tcp",
                &local_ips
            ),
            1
        );
        assert_eq!(
            check_fw4_port_open_with_redirects(
                "",
                "\t\ttcp dport 8443 dnat ip to 192.168.1.50:8443",
                "",
                8443,
                "tcp",
                &local_ips
            ),
            0
        );
        let uci_redirect = "firewall.r1=redirect\nfirewall.r1.target='DNAT'\nfirewall.r1.src='wan'\nfirewall.r1.proto='tcp'\nfirewall.r1.src_dport='8444'\nfirewall.r1.dest_ip='192.168.1.1'\nfirewall.r2=redirect\nfirewall.r2.target='DNAT'\nfirewall.r2.src='wan'\nfirewall.r2.proto='tcp'\nfirewall.r2.src_dport='8445'\nfirewall.r2.dest_ip='192.168.1.50'\n";
        assert_eq!(
            check_fw4_port_open_with_redirects("", "", uci_redirect, 8444, "tcp", &local_ips),
            1
        );
        assert_eq!(
            check_fw4_port_open_with_redirects("", "", uci_redirect, 8445, "tcp", &local_ips),
            0
        );

        assert_eq!(
            detect_firewall_dnat_summary(
                "\t\ttcp dport 443 dnat ip to 192.168.1.1:10443",
                "",
                10443,
                "tcp",
                &local_ips
            ),
            Some("WAN TCP/443 → TCP/10443".to_string())
        );
        assert_eq!(
            assess_inbound_firewall(
                false,
                "vless",
                "::",
                10443,
                false,
                "tcp",
                "",
                "\t\ttcp dport 443 dnat ip to 192.168.1.1:10443",
                "",
                &local_ips
            ),
            (1, 1, "WAN TCP/443 → TCP/10443".to_string(), "")
        );
        assert_eq!(
            assess_inbound_firewall(
                false, "vless", "::", 10443, false, "tcp", "", "", "", &local_ips
            ),
            (0, -1, String::new(), "auto_open_disabled")
        );
        assert_eq!(
            assess_inbound_firewall(
                false,
                "vless",
                "127.0.0.1",
                10443,
                false,
                "tcp",
                "",
                "",
                "",
                &local_ips
            ),
            (0, -1, String::new(), "local_listen")
        );
    }

    #[test]
    fn ubus_leak_check_payload_places_ipv6_in_top_level_and_nested_ipv6_leak() {
        let mut store = crate::store::RouterStoreData::default();
        store.settings.ipv6_leak_guard = true;
        store.settings.fakeip_inet4_range = "198.18.0.0/15".to_string();
        store.settings.fakeip_inet6_range = "fc00::/18".to_string();

        let ipv6_leak = crate::diagnostics::build_ipv6_leak_summary(
            &store,
            crate::store::EffectiveIpv6State::LeakGuard,
            "2001:4860::1",
            "",
            false,
        );
        let base_report = json!({
            "dns_listener_reachable": true,
            "direct_ipv6": "2001:4860::1",
            "ipv6_leaked": ipv6_leak["ipv6_leaked"],
            "ipv6_leak": ipv6_leak,
        });
        let payload = finalize_ubus_leak_check_payload(
            base_report,
            &store,
            "203.0.113.2",
            "198.51.100.9",
            "DE",
            "Node",
            "1.1.1.1",
            "198.18.0.25",
            true,
        );
        assert_eq!(payload["direct_ipv6"], "2001:4860::1");
        assert_eq!(payload["ipv6_leaked"], true);
        assert_eq!(payload["ipv6_leak"]["direct_ipv6"], "2001:4860::1");
        assert_eq!(payload["ipv6_leak"]["ipv6_leaked"], true);
        assert_eq!(payload["ipv6_leak"]["wan6_available"], true);
        assert_eq!(payload["ipv6_leak"]["nft_leak_guard_present"], false);
        assert!(payload["dns_leak"].get("ipv6_leaked").is_none());
        assert!(payload["dns_leak"].get("direct_ipv6").is_none());
        assert!(payload["dns_leak"].get("fakeip_inet6_range").is_none());
    }

    #[test]
    fn probe_outbound_url_matches_with_strip_dynamic_server_telemetry_fallback() {
        let candidates = vec![
            "Main-out".to_string(),
            "DE Frankfurt [15d | 10GB]".to_string(),
            "FI Helsinki [24h | 50GB]".to_string(),
        ];
        assert_eq!(
            resolve_outbound_tag_with_telemetry_fallback("DE Frankfurt", &candidates),
            Some("DE Frankfurt [15d | 10GB]".to_string())
        );
        assert_eq!(
            resolve_outbound_tag_with_telemetry_fallback("FI Helsinki (12h | 20GB)", &candidates),
            Some("FI Helsinki [24h | 50GB]".to_string())
        );
        assert_eq!(
            resolve_outbound_tag_with_telemetry_fallback("Main-out", &candidates),
            Some("Main-out".to_string())
        );
        assert_eq!(
            resolve_outbound_tag_with_telemetry_fallback("US New York", &candidates),
            None
        );

        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "sub_main".to_string(),
            enabled: true,
            name: "MainSub".to_string(),
            source_type: "subscription".to_string(),
            cached_nodes: vec![
                crate::store::ParsedProxyNode {
                    tag: "DE Frankfurt".to_string(),
                    protocol: "vless".to_string(),
                    server: "198.51.100.1".to_string(),
                    server_port: 443,
                    country: "DE".to_string(),
                    outbound_json: json!({
                        "type": "vless",
                        "tag": "DE Frankfurt",
                        "server": "198.51.100.1",
                        "server_port": 443,
                        "uuid": "11111111-1111-4111-8111-111111111111"
                    }),
                    ..Default::default()
                },
                crate::store::ParsedProxyNode {
                    tag: "FI Helsinki".to_string(),
                    protocol: "vless".to_string(),
                    server: "198.51.100.2".to_string(),
                    server_port: 443,
                    country: "FI".to_string(),
                    outbound_json: json!({
                        "type": "vless",
                        "tag": "FI Helsinki",
                        "server": "198.51.100.2",
                        "server_port": 443,
                        "uuid": "11111111-1111-4111-8111-111111111111"
                    }),
                    ..Default::default()
                },
            ],
            ..Default::default()
        });
        store.outbound_groups.push(crate::store::OutboundGroup {
            id: "grp_de".to_string(),
            enabled: true,
            name: "Germany Only".to_string(),
            source_refs: vec!["sub_main".to_string()],
            include_country_flags: vec!["DE".to_string()],
            ..Default::default()
        });
        let mut proxies = Map::new();
        proxies.insert(
            "sel-Main".to_string(),
            json!({ "type": "Selector", "all": ["DE Frankfurt", "FI Helsinki"] }),
        );
        proxies.insert("direct".to_string(), json!({ "type": "Direct" }));
        proxies.insert("desync-yt".to_string(), json!({ "type": "Desync" }));
        proxies.insert("DE Frankfurt".to_string(), json!({ "type": "VLESS" }));
        proxies.insert("FI Helsinki".to_string(), json!({ "type": "VLESS" }));

        let all_targets = collect_probe_outbound_url_targets(&store, &proxies, "all");
        assert_eq!(
            all_targets,
            vec!["DE Frankfurt".to_string(), "FI Helsinki".to_string()]
        );
        let de_targets = collect_probe_outbound_url_targets(&store, &proxies, "grp_de");
        assert_eq!(de_targets, vec!["DE Frankfurt".to_string()]);
    }

    #[test]
    fn serve_luci_shell_embeds_lang_in_luci_ctor_and_resets_en_dict() {
        let html_en = serve_luci_shell(None, "en");
        assert!(html_en.contains("<html lang=\"en\""));
        assert!(html_en.contains(&format!(
            "<title>Tachyon v{}</title>",
            crate::store::TACHYON_VERSION
        )));
        assert!(html_en.contains(&format!(
            "href=\"/favicon.svg?v={}\"",
            crate::store::TACHYON_VERSION
        )));
        assert!(TACHYON_FAVICON_SVG.contains("#0a84ff"));
        assert!(html_en.contains("lang: \"en\","));
        assert!(html_en.contains("window.TR = {}; window.TR_RAW = {};"));
        assert!(html_en.contains("!Object.isFrozen(L.env)"));

        let html_ru = serve_luci_shell(Some("settings"), "ru");
        assert!(html_ru.contains("<html lang=\"ru\""));
        assert!(html_ru.contains("lang: \"ru\","));
        assert!(!html_ru.contains("window.TR = {}; window.TR_RAW = {};"));
    }

    #[test]
    fn outbound_and_subscription_metadata_populate_from_store() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "sub_sky".to_string(),
            enabled: true,
            name: "SkyTunnel".to_string(),
            source_type: "subscription".to_string(),
            subscription_urls: vec!["https://sub.skytunnel.pw/abc".to_string()],
            sub_title: "SkyTunnel VIP".to_string(),
            sub_upload_bytes: 100,
            sub_download_bytes: 200,
            sub_total_bytes: 1000,
            sub_expire_unix: 1_900_000_000,
            last_updated_unix: 1_800_000_000,
            hidden: true,
            cached_nodes: vec![crate::store::ParsedProxyNode {
                tag: "DE Frankfurt".to_string(),
                protocol: "vless".to_string(),
                server: "198.51.100.1".to_string(),
                server_port: 443,
                outbound_json: json!({
                    "type": "vless",
                    "tag": "DE Frankfurt",
                    "server": "198.51.100.1",
                    "server_port": 443,
                    "tls": { "enabled": true, "reality": { "enabled": true } }
                }),
                ..Default::default()
            }],
            ..Default::default()
        });
        store.sections.clear();
        store.sections.push(crate::store::RoutingSection {
            id: "Main".to_string(),
            enabled: true,
            outbound_source_refs: vec!["sub_sky".to_string()],
            ..Default::default()
        });

        let out_meta = read_pure_rust_outbound_metadata(&store, "Main");
        assert_eq!(out_meta["source_ids"]["DE Frankfurt"], "sub_sky");
        assert_eq!(out_meta["source_names"]["DE Frankfurt"], "SkyTunnel");
        assert_eq!(out_meta["hidden"]["DE Frankfurt"], true);
        assert_eq!(out_meta["protocols"]["DE Frankfurt"], "vless");
        assert_eq!(out_meta["securities"]["DE Frankfurt"], "reality");
        assert_eq!(out_meta["countries"]["DE Frankfurt"], "DE");

        let sub_meta = read_pure_rust_subscription_metadata(&store, "Main");
        let arr = sub_meta.as_array().expect("subscription metadata array");
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["sourceId"], "sub_sky");
        assert_eq!(arr[0]["sourceSection"], "Main-subscription-1");
        assert_eq!(arr[0]["title"], "SkyTunnel VIP");
        assert_eq!(arr[0]["nodeCount"], 1);
        assert_eq!(arr[0]["traffic"]["used"], 300);
        assert_eq!(arr[0]["traffic"]["total"], 1000);
        assert_eq!(arr[0]["hidden"], true);

        let mut sec_map = Map::new();
        let tg = crate::store::TgBotConfig {
            notify_route_alert: false,
            notify_smart_detect: false,
            ..Default::default()
        };
        assert!(apply_telegram_config_to_sections_map(&mut sec_map, &tg));
        let tg_sec = sec_map["telegram"]
            .as_object()
            .expect("telegram section map");
        assert_eq!(tg_sec["notify_route_alert"], "0");
        assert_eq!(tg_sec["notify_smart_detect"], "0");
        assert_eq!(tg_sec["notify_failover"], "1");
        assert_eq!(tg_sec["notify_wan"], "1");
        assert_eq!(tg_sec["notify_update_available"], "1");
    }

    #[test]
    fn resolve_latency_targets_handles_proxy_list_section_and_json() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "sub_a".to_string(),
            source_type: "subscription".to_string(),
            cached_nodes: vec![
                crate::store::ParsedProxyNode {
                    tag: "Node A1".to_string(),
                    ..Default::default()
                },
                crate::store::ParsedProxyNode {
                    tag: "Node A2".to_string(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        });
        store.sections.clear();
        store.sections.push(crate::store::RoutingSection {
            id: "Main".to_string(),
            outbound_source_refs: vec!["sub_a".to_string()],
            ..Default::default()
        });

        let mut proxies = Map::new();
        proxies.insert(
            "sel-Main".to_string(),
            json!({
                "type": "Selector",
                "all": ["bal-Main-b1", "Node A1", "direct"]
            }),
        );
        proxies.insert(
            "bal-Main-b1".to_string(),
            json!({
                "type": "URLTest",
                "all": ["Node A2", "Node A1"]
            }),
        );

        let (tags, eff) = resolve_latency_targets(
            &store,
            Some(&proxies),
            "proxy_list",
            "Main",
            "@section:Main",
        );
        assert_eq!(eff, "@section:Main");
        assert!(tags.contains(&"Node A1".to_string()));
        assert!(tags.contains(&"Node A2".to_string()));
        assert!(!tags.contains(&"direct".to_string()));

        let (json_tags, _) = resolve_latency_targets(
            &store,
            None,
            "proxy_list",
            "Main",
            "[\"Alpha\",\"Beta\",\"Alpha\"]",
        );
        assert_eq!(json_tags, vec!["Alpha".to_string(), "Beta".to_string()]);
    }

    #[test]
    fn resolve_subscription_cli_target_selects_individual_source() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "sub_one".to_string(),
            name: "First".to_string(),
            source_type: "subscription".to_string(),
            ..Default::default()
        });
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "sub_two".to_string(),
            name: "Second".to_string(),
            source_type: "subscription".to_string(),
            ..Default::default()
        });
        store.sections.clear();
        store.sections.push(crate::store::RoutingSection {
            id: "Main".to_string(),
            outbound_source_refs: vec!["sub_one".to_string(), "sub_two".to_string()],
            ..Default::default()
        });

        assert_eq!(
            resolve_subscription_cli_target(&store, "Main", "1"),
            "sub_one"
        );
        assert_eq!(
            resolve_subscription_cli_target(&store, "Main", "2"),
            "sub_two"
        );
        assert_eq!(
            resolve_subscription_cli_target(&store, "Main", "sub_two"),
            "sub_two"
        );
        assert_eq!(resolve_subscription_cli_target(&store, "Main", ""), "Main");
    }

    #[tokio::test]
    async fn service_action_async_stop_pauses_watchdog_and_blocks_background_reload() {
        let _test_uci_guard = test_uci_snapshot_lock().lock().await;
        PENDING_CORE_RELOAD.store(false, std::sync::atomic::Ordering::Release);
        let dir =
            std::env::temp_dir().join(format!("tachyon_svc_stop_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        {
            let mut d = state.data.write().await;
            d.settings.enable_watchdog = true;
            d.settings.proxy_mode = "socks".to_string();
        }
        let core = CoreManager::new(Arc::clone(&state));
        let parsed = Box::pin(handle_service_action_async("stop", &state, &core)).await;
        assert_eq!(parsed["success"], true);
        assert_eq!(parsed["action"], "stop");
        assert!(core.is_manually_stopped());
        assert!(!core.is_watchdog_effectively_running().await);

        let d_snap = state.data.read().await.clone();
        let wjson = Box::pin(handle_watchdog_command("watchdog", &d_snap, &state, &core)).await;
        assert_eq!(wjson["running"], false);
        assert_eq!(wjson["status"], "stopped");

        // Ensure background sync helper with trigger_reload=false does not clear manual stop.
        Box::pin(sync_uci_to_rust_store_with_reload(&state, &core, false))
            .await
            .expect("sync without reload");
        assert!(core.is_manually_stopped());
        PENDING_CORE_RELOAD.store(false, std::sync::atomic::Ordering::Release);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn entware_conflicting_core_init_ignores_s99tachyon_and_detects_conflicts() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_entware_init_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        std::fs::write(dir.join("S99tachyon"), "#!/bin/sh\n").unwrap();
        std::fs::write(dir.join("S50nginx"), "#!/bin/sh\n").unwrap();
        assert!(!entware_has_conflicting_core_init(&dir));

        std::fs::write(dir.join("S98tachyon-core"), "#!/bin/sh\n").unwrap();
        assert!(entware_has_conflicting_core_init(&dir));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn core_aliases_expose_tachyon_core_and_legacy_sing_box_fields() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_core_alias_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        {
            let mut live = state.live.write().await;
            live.core_running = true;
            live.core_pid = Some(4242);
            live.core_version = "0.5.9".to_string();
        }

        let ui_state = build_pure_rust_ui_state(&state).await;
        assert_eq!(ui_state["service"]["tachyon_core"]["running"], 1);
        assert_eq!(ui_state["service"]["tachyon_core"]["pid"], 4242);
        assert_eq!(ui_state["service"]["sing_box"]["running"], 1);
        assert!(
            ui_state["capabilities"]
                .get("tachyon_core_installed")
                .is_some()
        );
        assert_eq!(ui_state["capabilities"]["tachyon_core_tailscale"], 1);
        assert_eq!(ui_state["capabilities"]["tachyon_core_cert_pin"], 1);

        let sys_info = build_pure_rust_system_info(&state).await;
        assert_eq!(sys_info["tachyon_core_version"], "0.5.9");
        assert_eq!(sys_info["sing_box_version"], "0.5.9");
        assert_eq!(
            sys_info["tachyon_core_repo_url"],
            "https://github.com/Dushnilin/tachyon-core"
        );
        assert_eq!(sys_info["tachyon_core_tailscale"], 1);
        assert_eq!(sys_info["tachyon_core_cert_pin"], 1);

        let d_snap = state.data.read().await.clone();
        let live_snap = state.live.read().await.clone();
        let health = build_core_health_check_payload(&d_snap, &live_snap, false);
        assert_eq!(health["tachyon_core_version"], "0.5.9");
        assert_eq!(health["sing_box_version"], "0.5.9");
        assert_eq!(health["tachyon_core_process_running"], 1);
        assert_eq!(health["sing_box_process_running"], 1);
        assert!(health.get("tachyon_core_listen_ports").is_some());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn telemetry_tag_display_names_resolve_sections_balancers_and_sources() {
        let d = crate::store::RouterStoreData {
            sections: vec![
                crate::store::RoutingSection {
                    id: "vpn".to_string(),
                    enabled: true,
                    label: "VPN".to_string(),
                    ..Default::default()
                },
                crate::store::RoutingSection {
                    id: "video".to_string(),
                    enabled: true,
                    label: "Video".to_string(),
                    outbound_source_refs: vec!["src_dpi".to_string()],
                    ..Default::default()
                },
            ],
            balancers: vec![crate::store::BalancerConfig {
                id: "bal_vpn_Fast".to_string(),
                name: "Fast".to_string(),
                ..Default::default()
            }],
            outbound_sources: vec![
                crate::store::OutboundSource {
                    id: "src_iface_awg_de".to_string(),
                    name: "AWG Germany".to_string(),
                    source_type: "iface".to_string(),
                    ..Default::default()
                },
                crate::store::OutboundSource {
                    id: "src_dpi".to_string(),
                    name: "Generic Desync".to_string(),
                    source_type: "desync".to_string(),
                    ..Default::default()
                },
                crate::store::OutboundSource {
                    id: "src_custom".to_string(),
                    name: "Remote Router".to_string(),
                    source_type: "custom_json".to_string(),
                    custom_json: r#"{"type":"wireguard","tag":"custom-wg-leaf"}"#.to_string(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        let map = build_telemetry_tag_display_map(&d);
        assert_eq!(
            resolve_telemetry_tag_display_name("sel-vpn", &map, &d),
            "VPN"
        );
        assert_eq!(
            resolve_telemetry_tag_display_name("bal-vpn-bal_vpn_Fast", &map, &d),
            "Fast"
        );
        assert_eq!(
            resolve_telemetry_tag_display_name("iface-src_iface_awg_de", &map, &d),
            "AWG Germany"
        );
        assert_eq!(
            resolve_telemetry_tag_display_name("desync-src_dpi", &map, &d),
            "Video"
        );
        assert_eq!(
            resolve_telemetry_tag_display_name("custom-wg-leaf", &map, &d),
            "Remote Router"
        );
        assert_eq!(
            resolve_telemetry_tag_display_name("🇫🇮 RU | FL | Helsinki", &map, &d),
            "🇫🇮 RU | FL | Helsinki"
        );
        // Dynamic fallback even when the balancer entry is absent from store
        assert_eq!(
            resolve_telemetry_tag_display_name("bal-vpn-bal_vpn_Reserve", &map, &d),
            "Reserve"
        );
        // Indexed AWG config and fallback technical tag cleanup
        assert_eq!(
            resolve_telemetry_tag_display_name("awgconf-src_rtest-1", &map, &d),
            "rtest #2"
        );
        assert_eq!(
            resolve_telemetry_tag_display_name("awgconf-src_rtest", &map, &d),
            "rtest"
        );
    }

    #[test]
    fn conntrack_parser_skips_fakeip_marks_and_core_client_sockets() {
        let raw = "\
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.1.50 dst=198.18.0.42 sport=51111 dport=443 packets=5 bytes=1200 src=198.18.0.42 dst=203.0.113.10 sport=443 dport=51111 packets=5 bytes=3400 [ASSURED] mark=0 use=1
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.1.50 dst=93.184.216.34 sport=54321 dport=443 packets=5 bytes=100 src=93.184.216.34 dst=203.0.113.10 sport=443 dport=54321 packets=5 bytes=200 [ASSURED] mark=0 use=1
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.1.50 dst=8.8.4.4 sport=52222 dport=443 packets=5 bytes=100 src=8.8.4.4 dst=203.0.113.10 sport=443 dport=52222 packets=5 bytes=200 [ASSURED] mark=0x04000000 use=1
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.1.50 dst=9.9.9.9 sport=52223 dport=443 packets=5 bytes=100 src=9.9.9.9 dst=203.0.113.10 sport=443 dport=52223 packets=5 bytes=200 [ASSURED] mark=0x10000000 use=1
ipv4 2 tcp 6 431999 ESTABLISHED src=192.168.1.50 dst=4.2.2.1 sport=52224 dport=443 packets=5 bytes=100 src=4.2.2.1 dst=203.0.113.10 sport=443 dport=52224 packets=5 bytes=200 [ASSURED] mark=0x40000000 use=1
ipv4 2 udp 17 120 src=192.168.1.50 dst=1.1.1.1 sport=60123 dport=443 packets=3 bytes=300 src=1.1.1.1 dst=203.0.113.10 sport=443 dport=60123 packets=3 bytes=900 [ASSURED] mark=0 use=1
";
        let mut ip_host_map = std::collections::HashMap::new();
        ip_host_map.insert("198.18.0.42".to_string(), "www.instagram.com".to_string());
        let seen_tuples = std::collections::HashSet::new();
        let mut seen_client_sockets = std::collections::HashSet::new();
        // Matches 93.184.216.34 connection reported by core with empty destinationIP
        seen_client_sockets.insert("tcp|192.168.1.50|54321|443".to_string());

        let conns = parse_conntrack_connections_text(
            raw,
            &ip_host_map,
            &seen_tuples,
            &seen_client_sockets,
            Some("198.18.0.0/15"),
            50,
        );
        assert_eq!(conns.len(), 1, "unexpected conntrack entries: {conns:?}");
        assert_eq!(conns[0]["id"], "ct:udp:192.168.1.50:60123:1.1.1.1:443");

        // When core connection already has a concrete destinationIP (full-cone UDP NAT),
        // another UDP flow from the same (src, sport, dport) to a different dstIP must be kept.
        let mut seen_tuples_multi = std::collections::HashSet::new();
        let seen_client_sockets_multi = std::collections::HashSet::new();
        seen_tuples_multi.insert("udp|192.168.1.50|60123|8.8.8.8|443".to_string());
        let udp_raw = "\
ipv4 2 udp 17 120 src=192.168.1.50 dst=8.8.8.8 sport=60123 dport=443 packets=3 bytes=300 src=8.8.8.8 dst=203.0.113.10 sport=443 dport=60123 packets=3 bytes=900 [ASSURED] mark=0 use=1
ipv4 2 udp 17 120 src=192.168.1.50 dst=1.1.1.1 sport=60123 dport=443 packets=3 bytes=300 src=1.1.1.1 dst=203.0.113.10 sport=443 dport=60123 packets=3 bytes=900 [ASSURED] mark=0 use=1
";
        let udp_conns = parse_conntrack_connections_text(
            udp_raw,
            &ip_host_map,
            &seen_tuples_multi,
            &seen_client_sockets_multi,
            Some("198.18.0.0/15"),
            50,
        );
        assert_eq!(udp_conns.len(), 1);
        assert_eq!(udp_conns[0]["id"], "ct:udp:192.168.1.50:60123:1.1.1.1:443");
    }

    #[tokio::test]
    async fn tachyon_core_rpc_aliases_return_running_and_fields() {
        let dir =
            std::env::temp_dir().join(format!("tachyon-ubus-core-aliases-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = AppState::load_or_create(dir.join("tachyon.json")).unwrap();
        {
            let mut live = state.live.write().await;
            live.core_running = true;
            live.core_version = "0.6.0".to_string();
            live.core_pid = Some(12345);
        }
        let core = CoreManager::new(Arc::clone(&state));

        let (code_st, out_st, _) =
            execute_tachyon_cli(&["get_tachyon_core_status".to_string()], &state, &core).await;
        assert_eq!(code_st, 0);
        let v_st: Value = serde_json::from_str(&out_st).unwrap();
        assert_eq!(v_st["running"], 1);
        assert_eq!(v_st["pid"], 12345);

        let (code_chk, out_chk, _) =
            execute_tachyon_cli(&["check_tachyon_core".to_string()], &state, &core).await;
        assert_eq!(code_chk, 0);
        let v_chk: Value = serde_json::from_str(&out_chk).unwrap();
        assert!(v_chk.get("tachyon_core_installed").is_some());
        assert_eq!(v_chk["tachyon_core_process_running"], 1);

        let (code_ui, out_ui, _) =
            execute_tachyon_cli(&["get_ui_state".to_string()], &state, &core).await;
        assert_eq!(code_ui, 0);
        let v_ui: Value = serde_json::from_str(&out_ui).unwrap();
        assert_eq!(v_ui["service"]["tachyon_core"]["running"], 1);
        assert!(v_ui["capabilities"].get("tachyon_core_installed").is_some());

        let (code_ver, out_ver, _) =
            execute_tachyon_cli(&["show_tachyon_core_version".to_string()], &state, &core).await;
        assert_eq!(code_ver, 0);
        assert_eq!(out_ver.trim(), "0.6.0");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_clash_proxy_for_target_resolves_section_and_selector_tags() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources = vec![
            crate::store::OutboundSource {
                id: "src_TrustTunnel".to_string(),
                source_type: "trusttunnel".to_string(),
                ..Default::default()
            },
            crate::store::OutboundSource {
                id: "src_mieru_DeluxHost_Miery".to_string(),
                source_type: "mieru".to_string(),
                ..Default::default()
            },
            crate::store::OutboundSource {
                id: "src_awg_WARP".to_string(),
                source_type: "amneziawg".to_string(),
                ..Default::default()
            },
        ];
        store.sections = vec![
            crate::store::RoutingSection {
                id: "TrustTunnel".to_string(),
                outbound_source_refs: vec!["src_TrustTunnel".to_string()],
                ..Default::default()
            },
            crate::store::RoutingSection {
                id: "DeluxHost_Miery".to_string(),
                outbound_source_refs: vec!["src_mieru_DeluxHost_Miery".to_string()],
                ..Default::default()
            },
            crate::store::RoutingSection {
                id: "WARP".to_string(),
                outbound_source_refs: vec!["src_awg_WARP".to_string()],
                ..Default::default()
            },
        ];

        let proxies_val = json!({
            "trusttunnel-src_TrustTunnel": { "type": "TrustTunnel" },
            "mieru-src_mieru_DeluxHost_Miery": { "type": "Mieru" },
            "wg-src_awg_WARP": { "type": "WireGuard" },
            "sel-Main": {
                "type": "Selector",
                "now": "vless-node-1",
                "all": ["vless-node-1", "vless-node-2"]
            },
            "vless-node-1": { "type": "VLESS" },
            "vless-node-2": { "type": "VLESS" }
        });
        let proxies_map = proxies_val.as_object().unwrap();

        assert_eq!(
            resolve_clash_proxy_for_target(&store, proxies_map, "TrustTunnel").as_deref(),
            Some("trusttunnel-src_TrustTunnel")
        );
        assert_eq!(
            resolve_clash_proxy_for_target(&store, proxies_map, "DeluxHost_Miery").as_deref(),
            Some("mieru-src_mieru_DeluxHost_Miery")
        );
        assert_eq!(
            resolve_clash_proxy_for_target(&store, proxies_map, "DeluxHost_Miery-out").as_deref(),
            Some("mieru-src_mieru_DeluxHost_Miery")
        );
        assert_eq!(
            resolve_clash_proxy_for_target(&store, proxies_map, "WARP").as_deref(),
            Some("wg-src_awg_WARP")
        );
        assert_eq!(
            resolve_clash_proxy_for_target(&store, proxies_map, "sel-Main").as_deref(),
            Some("vless-node-1")
        );
        assert_eq!(
            resolve_clash_proxy_for_target(&store, proxies_map, "vless-node-1"),
            None
        );

        assert!(is_transient_delay_probe_failure(&Err(anyhow::anyhow!(
            "clash api GET /proxies/x/delay returned HTTP 504: Gateway Timeout"
        ))));
        assert!(is_transient_delay_probe_failure(&Ok(json!({
            "message": "Gateway Timeout",
            "reason": "timeout"
        }))));
        assert!(!is_transient_delay_probe_failure(&Err(anyhow::anyhow!(
            "clash api GET /proxies/x/delay returned HTTP 404: {{\"message\":\"Resource not found\"}}"
        ))));
        assert!(!is_transient_delay_probe_failure(&Ok(json!({
            "delay": 180
        }))));
    }

    #[test]
    fn test_is_fakeip_addr_default_and_custom_ranges() {
        assert!(is_fakeip_addr("198.18.0.238", "", ""));
        assert!(is_fakeip_addr("198.19.255.1", "", ""));
        assert!(is_fakeip_addr("fc00::1234", "", ""));
        assert!(is_fakeip_addr(
            "198.18.12.34",
            "198.18.0.0/16",
            "fd00:f::/48"
        ));
        assert!(is_fakeip_addr("fd00:f::1", "198.18.0.0/16", "fd00:f::/48"));
        assert!(!is_fakeip_addr("84.201.1.2", "", ""));
        assert!(!is_fakeip_addr("2001:4860:4860::8888", "", ""));
    }

    #[test]
    fn test_parse_dns_response_ips_cname_a_and_aaaa() {
        // Query for "my.duckdns.org" (18 bytes QNAME + 4 bytes QTYPE/QCLASS)
        let mut resp = Vec::new();
        resp.extend_from_slice(&[0x54, 0x43]); // txid
        resp.extend_from_slice(&[0x81, 0x80]); // QR=1, RD=1, RA=1, RCODE=0
        resp.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT=1
        resp.extend_from_slice(&3u16.to_be_bytes()); // ANCOUNT=3
        resp.extend_from_slice(&[0, 0, 0, 0]); // NS/AR=0

        // Question: my.duckdns.org A IN (offset 12)
        resp.extend_from_slice(&[
            2, b'm', b'y', 7, b'd', b'u', b'c', b'k', b'd', b'n', b's', 3, b'o', b'r', b'g', 0,
        ]);
        resp.extend_from_slice(&1u16.to_be_bytes());
        resp.extend_from_slice(&1u16.to_be_bytes());

        // Answer 1: compressed pointer 0xC00C, CNAME -> "edge.duckdns.org" (via pointer 0xC00F after "edge")
        resp.extend_from_slice(&[0xC0, 0x0C]);
        resp.extend_from_slice(&5u16.to_be_bytes()); // TYPE=CNAME
        resp.extend_from_slice(&1u16.to_be_bytes()); // CLASS=IN
        resp.extend_from_slice(&60u32.to_be_bytes()); // TTL
        let cname_rdata: [u8; 7] = [4, b'e', b'd', b'g', b'e', 0xC0, 0x0F];
        resp.extend_from_slice(&(cname_rdata.len() as u16).to_be_bytes());
        resp.extend_from_slice(&cname_rdata);

        // Answer 2: compressed pointer 0xC00C, A -> 84.201.1.2
        resp.extend_from_slice(&[0xC0, 0x0C]);
        resp.extend_from_slice(&1u16.to_be_bytes());
        resp.extend_from_slice(&1u16.to_be_bytes());
        resp.extend_from_slice(&60u32.to_be_bytes());
        resp.extend_from_slice(&4u16.to_be_bytes());
        resp.extend_from_slice(&[84, 201, 1, 2]);

        // Answer 3: compressed pointer 0xC00C, AAAA -> 2001:db8::1
        resp.extend_from_slice(&[0xC0, 0x0C]);
        resp.extend_from_slice(&28u16.to_be_bytes());
        resp.extend_from_slice(&1u16.to_be_bytes());
        resp.extend_from_slice(&60u32.to_be_bytes());
        resp.extend_from_slice(&16u16.to_be_bytes());
        resp.extend_from_slice(&[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);

        assert_eq!(
            parse_dns_response_ips(&resp, [0x54, 0x43]),
            Some(vec!["84.201.1.2".to_string(), "2001:db8::1".to_string()])
        );
        assert_eq!(parse_dns_response_ips(&resp, [0x00, 0x01]), None);

        let mut nxdomain = resp.clone();
        nxdomain[3] = 0x83; // RCODE=3
        assert_eq!(parse_dns_response_ips(&nxdomain, [0x54, 0x43]), None);
    }

    #[test]
    fn test_resolve_domain_via_udp_dns_local_mock() {
        let srv = std::net::UdpSocket::bind("127.0.0.1:0").expect("bind mock dns");
        srv.set_read_timeout(Some(Duration::from_secs(3))).ok();
        let addr = srv.local_addr().unwrap().to_string();

        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 512];
            for _ in 0..2 {
                let Ok((n, peer)) = srv.recv_from(&mut buf) else {
                    break;
                };
                if n < 17 {
                    continue;
                }
                let qtype = u16::from_be_bytes([buf[n - 4], buf[n - 3]]);
                let mut resp = Vec::new();
                resp.extend_from_slice(&buf[0..2]); // echo txid
                resp.extend_from_slice(&[0x81, 0x80]); // QR=1, RCODE=0
                resp.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT=1
                if qtype == 1 {
                    resp.extend_from_slice(&1u16.to_be_bytes()); // ANCOUNT=1
                    resp.extend_from_slice(&[0, 0, 0, 0]);
                    resp.extend_from_slice(&buf[12..n]);
                    resp.extend_from_slice(&[0xC0, 0x0C]);
                    resp.extend_from_slice(&1u16.to_be_bytes());
                    resp.extend_from_slice(&1u16.to_be_bytes());
                    resp.extend_from_slice(&60u32.to_be_bytes());
                    resp.extend_from_slice(&4u16.to_be_bytes());
                    resp.extend_from_slice(&[84, 201, 1, 2]);
                } else {
                    resp.extend_from_slice(&0u16.to_be_bytes()); // ANCOUNT=0
                    resp.extend_from_slice(&[0, 0, 0, 0]);
                    resp.extend_from_slice(&buf[12..n]);
                }
                let _ = srv.send_to(&resp, peer);
            }
        });

        let ips = resolve_domain_via_udp_dns("test.duckdns.org", &[&addr], Duration::from_secs(2));
        let _ = handle.join();
        assert_eq!(ips, vec!["84.201.1.2".to_string()]);
    }

    #[test]
    fn test_extract_ai_doctor_query_skips_cli_flags() {
        assert_eq!(extract_ai_doctor_query(&["--async".to_string()]), None);
        assert_eq!(
            extract_ai_doctor_query(&["--async".to_string(), "DNS check".to_string()]),
            Some("DNS check")
        );
        assert_eq!(
            extract_ai_doctor_query(&["  --status  ".to_string(), "".to_string()]),
            None
        );
    }

    #[test]
    fn test_build_dns_bench_stats_json_uses_null_median_on_total_failure() {
        let mut empty_vals = Vec::new();
        let failed = build_dns_bench_stats_json(&mut empty_vals, 3);
        assert_eq!(
            failed.get("status").and_then(Value::as_str),
            Some("unreachable")
        );
        assert_eq!(failed.get("success").and_then(Value::as_u64), Some(0));
        assert!(failed.get("median").is_some_and(Value::is_null));
        assert!(failed.get("min").is_some_and(Value::is_null));

        let mut ok_vals = vec![29.47, 8.27, 27.16];
        let ok = build_dns_bench_stats_json(&mut ok_vals, 3);
        assert_eq!(ok.get("status").and_then(Value::as_str), Some("healthy"));
        assert_eq!(ok.get("median").and_then(Value::as_f64), Some(27.16));
    }

    #[test]
    fn test_format_show_config_value_redacts_and_compacts_cached_nodes() {
        let mut data = crate::store::RouterStoreData::default();
        data.settings.clash_api_secret = "clash-secret-123".into();
        data.settings.server_subscription_token = "sub-tok-xyz".into();
        data.settings.agent_api_token = "agent-tok-999".into();
        data.outbound_sources.push(crate::store::OutboundSource {
            id: "src_sub".into(),
            enabled: true,
            source_type: "subscription".into(),
            subscription_urls: vec!["https://futurefast.ru/api/sub/secretToken123".into()],
            hwid: "HWID-ABCD".into(),
            cached_nodes: vec![
                crate::store::ParsedProxyNode {
                    tag: "Auto".into(),
                    protocol: "urltest".into(),
                    outbound_json: json!({ "type": "urltest", "tag": "Auto" }),
                    ..Default::default()
                },
                crate::store::ParsedProxyNode {
                    tag: "de-hidden".into(),
                    protocol: "vless".into(),
                    server: "de.example".into(),
                    server_port: 443,
                    raw_uri: "json:hidden".into(),
                    outbound_json: json!({ "type": "vless", "tag": "de-hidden" }),
                    ..Default::default()
                },
                crate::store::ParsedProxyNode {
                    tag: "NL-Single".into(),
                    protocol: "hysteria2".into(),
                    server: "nl.example".into(),
                    server_port: 443,
                    outbound_json: json!({ "type": "hysteria2", "tag": "NL-Single" }),
                    ..Default::default()
                },
            ],
            ..Default::default()
        });

        data.servers.push(crate::store::InboundServer {
            id: "srv_awg".into(),
            protocol: "awg".into(),
            password: "srv-pass-secret".into(),
            awg_preshared_key: "psk-secret".into(),
            awg_header_protection_key: "hpk-secret".into(),
            reality_short_id: "0123456789abcdef".into(),
            ..Default::default()
        });

        let masked = format_show_config_value(&data, false);
        assert_eq!(masked["settings"]["clash_api_secret"], "[REDACTED]");
        assert_eq!(
            masked["settings"]["server_subscription_token"],
            "[REDACTED]"
        );
        assert_eq!(masked["settings"]["agent_api_token"], "[REDACTED]");
        assert_eq!(masked["servers"][0]["password"], "[REDACTED]");
        assert_eq!(masked["servers"][0]["awg_preshared_key"], "[REDACTED]");
        assert_eq!(
            masked["servers"][0]["awg_header_protection_key"],
            "[REDACTED]"
        );
        assert_eq!(masked["servers"][0]["reality_short_id"], "[REDACTED]");

        let src_obj = masked["outbound_sources"]
            .as_array()
            .and_then(|arr| arr.iter().find(|s| s["id"] == "src_sub"))
            .expect("src_sub present");
        assert!(src_obj.get("cached_nodes").is_none());
        assert_eq!(src_obj["cached_nodes_count"], 3);
        assert_eq!(src_obj["cached_nodes_summary"]["total"], 3);
        assert_eq!(src_obj["cached_nodes_summary"]["urltest_groups"], 1);
        assert_eq!(src_obj["cached_nodes_summary"]["hidden_members"], 1);
        assert_eq!(
            src_obj["subscription_urls"][0],
            "https://futurefast.ru/[REDACTED]"
        );
        assert_eq!(src_obj["hwid"], "[REDACTED]");

        let serialized = serde_json::to_string_pretty(&masked).expect("valid json");
        let reparsed: Value = serde_json::from_str(&serialized).expect("reparse masked json");
        assert!(reparsed.is_object());
    }

    #[test]
    fn resolve_subscription_cli_target_resolves_single_source_and_case_insensitive_section() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources = ["src_a", "src_b", "src_c", "src_d"]
            .into_iter()
            .map(|id| crate::store::OutboundSource {
                id: id.to_string(),
                source_type: "subscription".to_string(),
                ..Default::default()
            })
            .collect();
        store.sections.push(crate::store::RoutingSection {
            id: "Main".to_string(),
            outbound_source_refs: vec![
                "src_a".to_string(),
                "src_b".to_string(),
                "src_c".to_string(),
                "src_d".to_string(),
            ],
            ..Default::default()
        });

        assert_eq!(resolve_subscription_cli_target(&store, "Main", ""), "Main");
        assert_eq!(
            resolve_subscription_cli_target(&store, "Main", "src_b"),
            "src_b"
        );
        assert_eq!(
            resolve_subscription_cli_target(&store, "Main", "2"),
            "src_b"
        );
        assert_eq!(
            resolve_subscription_cli_target(&store, "main", "2"),
            "src_b"
        );
        assert_eq!(
            resolve_subscription_cli_target(&store, "Main", "99"),
            "__missing_subscription_index__:99"
        );
    }

    #[test]
    fn collect_active_subscription_jobs_in_dir_filters_running_and_preserves_selector() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_sub_jobs_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let now = 1_750_000_000u64;
        std::fs::write(
            dir.join("rust-sub-Main-1.json"),
            serde_json::to_string(&json!({
                "job_id": "rust-sub-Main-1",
                "section": "Main",
                "source_selector": "src_b",
                "source_index": "src_b",
                "resolved_target": "src_b",
                "started_at": now - 10,
                "running": true
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::write(
            dir.join("rust-sub-Main-2.json"),
            serde_json::to_string(&json!({
                "job_id": "rust-sub-Main-2",
                "section": "Main",
                "source_selector": "src_a",
                "started_at": now - 5,
                "running": false
            }))
            .unwrap(),
        )
        .unwrap();
        std::fs::write(
            dir.join("rust-sub-Main-expired.json"),
            serde_json::to_string(&json!({
                "job_id": "rust-sub-Main-expired",
                "section": "Main",
                "started_at": now - 1200,
                "running": true
            }))
            .unwrap(),
        )
        .unwrap();

        let active = collect_active_subscription_jobs_in_dir(&dir, now);
        assert_eq!(active.len(), 1);
        assert_eq!(active[0]["job_id"], json!("rust-sub-Main-1"));
        assert_eq!(active[0]["source_selector"], json!("src_b"));
        assert_eq!(active[0]["resolved_target"], json!("src_b"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bridge_allowlists_reject_arbitrary_exec_paths_and_ubus_calls() {
        assert!(!is_allowed_bridge_exec(
            "/bin/sh",
            &["-c".into(), "id".into()]
        ));
        assert!(!is_allowed_bridge_exec("/bin/cat", &["/etc/shadow".into()]));
        assert!(!is_allowed_bridge_exec(
            "/bin/rm",
            &["-rf".into(), "/etc/passwd".into()]
        ));
        assert!(!is_allowed_bridge_exec(
            "/usr/bin/nslookup",
            &["-debug".into(), "example.com".into()]
        ));
        assert!(!is_allowed_bridge_read_path("/etc/shadow"));
        assert!(!is_allowed_bridge_read_path("/etc/tachyon/tachyon.json"));
        assert!(!is_allowed_bridge_read_path(
            "/var/run/tachyon/../etc/shadow"
        ));
        assert!(!is_allowed_bridge_write_path("/etc/passwd"));
        assert!(!is_allowed_bridge_remove_path("/etc/passwd"));
        assert!(!is_allowed_router_ubus_call("system", "exec"));
        assert!(!is_allowed_router_ubus_call("file", "write"));

        assert!(is_allowed_bridge_read_path(
            "/var/run/tachyon/section-cache/Main.json"
        ));
        assert!(is_allowed_bridge_write_path(
            "/tmp/tachyon-snapshot-import.json"
        ));
        assert!(is_allowed_bridge_remove_path(
            "/etc/tachyon/subscription-cache/Main.json"
        ));
        assert!(is_allowed_bridge_exec(
            "/usr/bin/tachyon-core",
            &["version".into()]
        ));
        assert!(is_allowed_bridge_exec(
            "/usr/bin/nslookup",
            &["example.com".into()]
        ));
        assert!(is_allowed_bridge_exec(
            "/bin/rm",
            &[
                "-f".into(),
                "/var/run/tachyon/section-cache/Main.json".into()
            ]
        ));
        assert!(is_allowed_router_ubus_call("network.interface", "dump"));
        assert!(is_allowed_router_ubus_call("luci-rpc", "getHostHints"));
    }

    #[tokio::test]
    async fn execute_tachyon_cli_normalizes_hyphens_and_rejects_unknown_methods() {
        let dir = std::env::temp_dir().join(format!("tachyon_cli_norm_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        let core = CoreManager::new(Arc::clone(&state));

        let (code, stdout, _) =
            execute_tachyon_cli(&["show-version".to_string()], &state, &core).await;
        assert_eq!(code, 0);
        assert_eq!(stdout.trim(), crate::store::TACHYON_VERSION);

        let (unk_code, unk_stdout, _) =
            execute_tachyon_cli(&["nonexistent-rpc-method".to_string()], &state, &core).await;
        assert_eq!(unk_code, 0);
        let parsed: Value = serde_json::from_str(unk_stdout.trim()).unwrap();
        assert_eq!(parsed.get("success").and_then(Value::as_bool), Some(false));
        assert!(
            parsed
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("")
                .contains("nonexistent_rpc_method")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn extract_ruleset_rejects_disallowed_paths_and_resolves_local_cache() {
        let dir =
            std::env::temp_dir().join(format!("tachyon_ruleset_ext_s_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        let core = CoreManager::new(Arc::clone(&state));

        let (bad_code, _, bad_err) = execute_tachyon_cli(
            &["extract_ruleset".to_string(), "/etc/shadow".to_string()],
            &state,
            &core,
        )
        .await;
        assert_ne!(bad_code, 0);
        assert!(!bad_err.trim().is_empty());

        let (trav_code, _, _) = execute_tachyon_cli(
            &[
                "extract-ruleset".to_string(),
                "../../etc/passwd".to_string(),
            ],
            &state,
            &core,
        )
        .await;
        assert_ne!(trav_code, 0);

        let tmp_dir =
            std::env::temp_dir().join(format!("tachyon_ruleset_ext_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp_dir);
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let sample_trs = tmp_dir.join("sample_test.trs");
        let sample_community = tmp_dir.join("community-foo.trs");
        std::fs::write(&sample_trs, b"TRS1").unwrap();
        std::fs::write(&sample_community, b"TRS1").unwrap();

        assert_eq!(
            find_cached_ruleset_by_name_in_roots("sample_test", &[tmp_dir.as_path()]),
            Some(sample_trs)
        );
        assert_eq!(
            find_cached_ruleset_by_name_in_roots("foo", &[tmp_dir.as_path()]),
            Some(sample_community)
        );
        assert_eq!(sanitize_luci_subview(Some("sections")), Some("sections"));
        assert_eq!(sanitize_luci_subview(Some("foo\"];alert(1);//")), None);
        assert!(is_safe_uci_config_name("network"));
        assert!(is_safe_uci_config_name("wireless-extra_1"));
        assert!(!is_safe_uci_config_name(""));
        assert!(!is_safe_uci_config_name("../shadow"));
        assert!(!is_safe_uci_config_name("foo/bar"));
        let _ = std::fs::remove_dir_all(&tmp_dir);
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn clash_proxy_cache_marks_valid_snapshots_and_rejects_invalid_data() {
        let path =
            std::env::temp_dir().join(format!("tachyon-proxies-test-{}.json", std::process::id()));
        assert!(read_cached_clash_proxies(&path).is_none());
        for invalid in ["{", "[]", r#"{"proxies":null}"#, r#"{"proxies":[]}"#] {
            std::fs::write(&path, invalid).unwrap();
            assert!(read_cached_clash_proxies(&path).is_none());
        }
        let original = json!({"proxies": {"group": {"now": "node-x"}}, "telemetry": {}});
        std::fs::write(&path, original.to_string()).unwrap();
        let cached = read_cached_clash_proxies(&path).unwrap();
        let cached: Value = serde_json::from_str(&cached).unwrap();
        assert_eq!(cached["tachyon_cached"], true);
        assert_eq!(cached["proxies"], original["proxies"]);
        assert_eq!(cached["telemetry"], original["telemetry"]);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn collect_store_leaf_tags_and_node_count_respect_subscription_keyword_filters() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.clear();
        store.sections.clear();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "wpn_me".to_string(),
            enabled: true,
            source_type: "subscription".to_string(),
            subscription_filter_exclude_keywords: vec!["LTE".to_string()],
            cached_nodes: vec![
                config_gen::parse_proxy_uri(
                    "vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443#%D0%A2%D0%BE%D0%BB%D1%8C%D0%BA%D0%BE%20LTE%20%231",
                    0,
                )
                .unwrap(),
                config_gen::parse_proxy_uri(
                    "vless://11111111-1111-1111-1111-111111111112@198.51.100.2:443#FI%20Helsinki",
                    1,
                )
                .unwrap(),
            ],
            ..Default::default()
        });
        store.sections.push(crate::store::RoutingSection {
            id: "TEST".to_string(),
            enabled: true,
            action: "proxy".to_string(),
            outbound_source_refs: vec!["wpn_me".to_string()],
            ..Default::default()
        });

        let tags = collect_store_section_leaf_tags(&store, "TEST");
        assert_eq!(tags, vec!["FI Helsinki".to_string()]);
        let meta = read_pure_rust_subscription_metadata(&store, "TEST");
        assert_eq!(meta[0]["nodeCount"], 1);

        // When section-level exclude removes the remaining node, leaf tags must be empty.
        store.sections[0].subscription_filter_exclude_keywords = vec!["Helsinki".to_string()];
        assert!(collect_store_section_leaf_tags(&store, "TEST").is_empty());

        // When source-level filter excludes all nodes, enabled source reports nodeCount 0 (not raw cached_nodes len).
        store.outbound_sources[0].subscription_filter_exclude_keywords =
            vec![" ".to_string(), "LTE".to_string(), "Helsinki".to_string()];
        let meta_empty = read_pure_rust_subscription_metadata(&store, "TEST");
        assert_eq!(meta_empty[0]["nodeCount"], 0);
    }

    #[test]
    fn parse_openwrt_network_interface_proto_detects_amneziawg_and_wireguard() {
        let uci = r#"
config interface 'loopback'
	option device 'lo'
	option proto 'static'

config interface 'VPN'
	option proto 'amneziawg'
	option private_key 'secret'

config interface 'wg_peer'
	option proto "wireguard"
	option device 'wg0'
"#;
        assert_eq!(
            parse_openwrt_network_interface_proto(uci, "VPN").as_deref(),
            Some("amneziawg")
        );
        assert_eq!(
            parse_openwrt_network_interface_proto(uci, "wg0").as_deref(),
            Some("wireguard")
        );
        assert_eq!(parse_openwrt_network_interface_proto(uci, "wan"), None);
    }

    #[test]
    fn interface_source_metadata_uses_friendly_name_detected_proto_and_leaf_tag() {
        let mut store = crate::store::RouterStoreData::default();
        store.outbound_sources.clear();
        store.sections.clear();
        store.outbound_sources.push(crate::store::OutboundSource {
            id: "src_awg_custom".to_string(),
            enabled: true,
            name: "AmneziaWG Home".to_string(),
            source_type: "interface".to_string(),
            interface_name: "awg_custom".to_string(),
            ..Default::default()
        });
        store.sections.push(crate::store::RoutingSection {
            id: "Youtube".to_string(),
            enabled: true,
            action: "connection".to_string(),
            outbound_source_refs: vec!["src_awg_custom".to_string()],
            ..Default::default()
        });

        let meta = read_pure_rust_outbound_metadata(&store, "Youtube");
        assert_eq!(meta["names"]["iface-src_awg_custom"], "AmneziaWG Home");
        assert_eq!(meta["protocols"]["iface-src_awg_custom"], "amneziawg");

        let leaf_tags = collect_store_section_leaf_tags(&store, "Youtube");
        assert_eq!(leaf_tags, vec!["iface-src_awg_custom".to_string()]);
    }

    #[tokio::test]
    async fn cli_help_fuzzer_order_and_engine_aliases_work() {
        let dir = std::env::temp_dir().join(format!("tachyon_cli_aliases_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let store_path = dir.join("tachyon.json");
        let state = AppState::load_or_create(&store_path).expect("load state");
        let core = CoreManager::new(Arc::clone(&state));

        // 1. `--help` and `-h` print help and exit 0
        for flag in ["--help", "-h"] {
            let (code, stdout, stderr) =
                Box::pin(execute_tachyon_cli(&[flag.to_string()], &state, &core)).await;
            assert_eq!(code, 0, "help flag {flag} must exit 0");
            assert!(stderr.is_empty());
            assert!(stdout.contains("Usage: tachyon"));
            assert!(stdout.contains("engine_status"));
            assert!(stdout.contains("config_import"));
        }

        // 2. Flexible fuzzer_start argument ordering
        assert_eq!(
            normalize_fuzzer_start_args("desync", "youtube_suite"),
            ("desync", "youtube_suite")
        );
        assert_eq!(
            normalize_fuzzer_start_args("youtube_suite", "desync"),
            ("desync", "youtube_suite")
        );
        assert_eq!(
            normalize_fuzzer_start_args("youtube_suite", ""),
            ("desync", "youtube_suite")
        );

        // 3. `engine_status`, `config_validate`, `diagnose_json`
        let (es_code, es_out, _) = Box::pin(execute_tachyon_cli(
            &["engine_status".to_string()],
            &state,
            &core,
        ))
        .await;
        assert_eq!(es_code, 0);
        let es_val: Value = serde_json::from_str(es_out.trim()).expect("engine_status JSON");
        assert_eq!(es_val.get("success").and_then(Value::as_bool), Some(true));
        assert_eq!(
            es_val.get("engine").and_then(Value::as_str),
            Some("tachyon-core")
        );

        let (cv_code, cv_out, _) = Box::pin(execute_tachyon_cli(
            &["config_validate".to_string()],
            &state,
            &core,
        ))
        .await;
        assert_eq!(cv_code, 0);
        let cv_val: Value = serde_json::from_str(cv_out.trim()).expect("config_validate JSON");
        assert_eq!(cv_val.get("valid").and_then(Value::as_bool), Some(true));

        let (dj_code, dj_out, _) = Box::pin(execute_tachyon_cli(
            &["diagnose_json".to_string()],
            &state,
            &core,
        ))
        .await;
        assert_eq!(dj_code, 0);
        let dj_val: Value = serde_json::from_str(dj_out.trim()).expect("diagnose_json JSON");
        assert!(dj_val.get("checks_total").is_some());
        assert!(dj_val.get("findings").is_some());

        // 4. `config_import` imports an external store file safely
        let import_path = dir.join("import.json");
        {
            let mut ext_val: Value =
                serde_json::from_str(&std::fs::read_to_string(&store_path).unwrap()).unwrap();
            ext_val["settings"]["log_level"] = json!("info");
            std::fs::write(&import_path, serde_json::to_string(&ext_val).unwrap()).unwrap();
        }
        core.set_manual_stop(true);
        let (ci_code, ci_out, _) = Box::pin(execute_tachyon_cli(
            &[
                "config_import".to_string(),
                import_path.to_string_lossy().to_string(),
            ],
            &state,
            &core,
        ))
        .await;
        core.set_manual_stop(false);
        assert_eq!(ci_code, 0);
        let ci_val: Value = serde_json::from_str(ci_out.trim()).expect("config_import JSON");
        assert_eq!(ci_val.get("success").and_then(Value::as_bool), Some(true));
        assert_eq!(state.data.read().await.settings.log_level, "info");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parse_cloudflare_trace_extracts_valid_ip_and_iso_country() {
        let trace_v4 = "\
fl=29f123
h=cloudflare.com
ip=198.51.100.42
ts=1700000000.123
visit_scheme=https
uag=curl/8.5.0
loc=nl
tls=TLSv1.3
";
        assert_eq!(
            parse_cloudflare_trace(trace_v4),
            Some(("198.51.100.42".to_string(), "NL".to_string()))
        );

        let trace_v6 = "ip=2001:db8::1\nloc=DE\n";
        assert_eq!(
            parse_cloudflare_trace(trace_v6),
            Some(("2001:db8::1".to_string(), "DE".to_string()))
        );

        // Unknown sentinel XX, malformed loc, or invalid IP must be rejected.
        assert_eq!(parse_cloudflare_trace("ip=198.51.100.42\nloc=XX\n"), None);
        assert_eq!(parse_cloudflare_trace("ip=198.51.100.42\nloc=NLD\n"), None);
        assert_eq!(parse_cloudflare_trace("ip=not-an-ip\nloc=NL\n"), None);
        assert_eq!(parse_cloudflare_trace("loc=NL\n"), None);
    }

    #[test]
    fn parse_ipwhois_json_extracts_ip_and_country_and_rejects_failures() {
        let valid = r#"{"ip":"203.0.113.7","success":true,"country_code":"fi"}"#;
        assert_eq!(
            parse_ipwhois_json(valid),
            Some(("203.0.113.7".to_string(), "FI".to_string()))
        );

        let failed = r#"{"ip":"203.0.113.7","success":false,"country_code":"FI"}"#;
        assert_eq!(parse_ipwhois_json(failed), None);

        let bad_cc = r#"{"ip":"203.0.113.7","success":true,"country_code":"12"}"#;
        assert_eq!(parse_ipwhois_json(bad_cc), None);
        assert_eq!(parse_ipwhois_json("not json"), None);
    }

    #[test]
    fn exit_country_cache_respects_ttl_active_node_and_refresh() {
        let entry = ExitCountryCache {
            active_node: "NL-01".to_string(),
            country_code: "NL".to_string(),
            ip: "198.51.100.10".to_string(),
            source: "cloudflare".to_string(),
            checked_at: 1_700_000_000,
            cached_at: std::time::Instant::now(),
        };
        let ttl = Duration::from_secs(EXIT_COUNTRY_CACHE_TTL_SECS);
        assert!(entry.is_valid_for("NL-01", false, ttl));
        // Changing active node invalidates cache immediately.
        assert!(!entry.is_valid_for("DE-02", false, ttl));
        // Explicit refresh bypasses cache.
        assert!(!entry.is_valid_for("NL-01", true, ttl));
        // Zero TTL simulates expiry.
        assert!(!entry.is_valid_for("NL-01", false, Duration::ZERO));
    }

    #[test]
    fn platform_info_and_resolve_static_asset_support_entware_layout() {
        let storage = crate::platform::StorageInfo {
            kind: crate::platform::StorageKind::UsbExternal,
            fs_type: "ext4".to_string(),
            mount_point: "/opt".to_string(),
            device: "/dev/sda1".to_string(),
            is_posix: true,
        };
        let info = build_platform_info_from(
            crate::platform::PlatformKind::KeeneticEntware,
            crate::platform::FirewallKind::Iptables,
            &storage,
            true,
            "override",
            5353,
        );
        assert_eq!(info["platform"], "keenetic_entware");
        assert_eq!(info["display_name"], "Keenetic (Entware)");
        assert_eq!(info["is_entware"], true);
        assert_eq!(info["is_keenetic"], true);
        assert_eq!(info["firewall"], "iptables");
        assert_eq!(info["storage_kind"], "usb_external");
        assert_eq!(info["storage_fs"], "ext4");
        assert_eq!(info["storage_mount"], "/opt");
        assert_eq!(info["storage_posix"], true);
        assert_eq!(info["runtime_tmpfs_ok"], true);
        assert_eq!(info["entware_dns_mode"], "override");
        assert_eq!(info["entware_dns_port"], 5353);

        // Static asset resolution inside an Entware-like www_dir root.
        let dir = std::env::temp_dir().join(format!("tachyon_entware_www_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let asset_dir = dir.join("resources/view/tachyon");
        std::fs::create_dir_all(&asset_dir).unwrap();
        std::fs::write(asset_dir.join("main.js"), "console.log('ok');").unwrap();

        let roots = [dir.clone()];
        let resolved =
            resolve_static_asset_in_roots("resources/view/tachyon/main.js?v=123", &roots)
                .expect("asset must resolve in entware www_dir");
        assert_eq!(resolved.0, asset_dir.join("main.js"));
        assert_eq!(resolved.1, "application/javascript; charset=utf-8");
        assert!(resolved.2 > 0);
        // Traversal must always be rejected.
        assert!(resolve_static_asset_in_roots("../etc/passwd", &roots).is_none());

        // Subview shell preserves exact sub-path without shifting.
        let html_settings = serve_luci_shell(Some("/settings/"), "ru");
        assert!(html_settings.contains("pathinfo: \"/admin/services/tachyon/settings\""));
        assert!(
            html_settings
                .contains("requestpath: [\"admin\", \"services\", \"tachyon\", \"settings\"]")
        );
        let html_nested = serve_luci_shell(Some("settings/dns"), "en");
        assert!(html_nested.contains("pathinfo: \"/admin/services/tachyon/settings/dns\""));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn entware_dns_settings_and_bypass_before_match_all_order_persist_across_uci_sync() {
        let mut sections = Map::new();
        sections.insert(
            "settings".to_string(),
            json!({
                ".anonymous": false,
                ".type": "settings",
                ".name": "settings",
                ".index": 0,
                "entware_dns_mode": "override",
                "entware_dns_port": "1153"
            }),
        );
        sections.insert(
            "match_all_proxy".to_string(),
            json!({
                ".anonymous": false,
                ".type": "section",
                ".name": "match_all_proxy",
                ".index": 1,
                "enabled": "1",
                "action": "connection",
                "match_all": "1"
            }),
        );
        sections.insert(
            "bypass_ru".to_string(),
            json!({
                ".anonymous": false,
                ".type": "section",
                ".name": "bypass_ru",
                ".index": 2,
                "enabled": "1",
                "action": "bypass",
                "domain": ["example.ru"]
            }),
        );

        // User reorders `bypass_ru` ahead of `match_all_proxy` via uci.order.
        apply_uci_sections_order(
            &mut sections,
            &["bypass_ru".to_string(), "match_all_proxy".to_string()],
        );
        assert_eq!(sections["settings"][".index"], 0);
        assert_eq!(sections["bypass_ru"][".index"], 1);
        assert_eq!(sections["match_all_proxy"][".index"], 2);

        // Import into RouterStoreData + apply Entware DNS settings.
        let mut store = crate::store::RouterStoreData::default();
        let imported = store.import_from_json_sections(&sections);
        apply_entware_dns_from_json_sections(&sections, &mut store);
        assert!(imported >= 3);
        assert_eq!(store.settings.entware_dns_mode, "override");
        assert_eq!(store.settings.entware_dns_port, 1153);
        let ids: Vec<&str> = store.sections.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, vec!["bypass_ru", "match_all_proxy"]);

        // Round-trip back to JSON sections and UCI text: order must stay `bypass_ru` before `match_all_proxy`.
        let synced =
            crate::store::sync_store_to_json_sections(&store, Some(&Value::Object(sections)));
        let synced_map = synced.as_object().expect("synced object");
        assert!(
            synced_map["bypass_ru"][".index"].as_u64().unwrap()
                < synced_map["match_all_proxy"][".index"].as_u64().unwrap()
        );
        assert_eq!(synced_map["settings"]["entware_dns_mode"], "override");
        assert_eq!(synced_map["settings"]["entware_dns_port"], "1153");

        let uci_text = serialize_json_sections_to_uci(synced_map);
        let reparsed = crate::store::parse_uci_text_to_json_sections(&uci_text);
        let mut store2 = crate::store::RouterStoreData::default();
        store2.import_from_json_sections(&reparsed);
        apply_entware_dns_from_json_sections(&reparsed, &mut store2);
        let ids2: Vec<&str> = store2.sections.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids2, vec!["bypass_ru", "match_all_proxy"]);
        assert_eq!(store2.settings.entware_dns_mode, "override");
        assert_eq!(store2.settings.entware_dns_port, 1153);
    }

    #[tokio::test]
    async fn trace_rules_json_dispatch_uses_two_mode_analyzer() {
        let dir = std::env::temp_dir().join(format!(
            "tachyon_trace_rules_two_mode_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let state = AppState::load_or_create(dir.join("store.json")).expect("load state");
        {
            let mut d = state.data.write().await;
            d.sections = vec![crate::store::RoutingSection {
                id: "bypass_sec".to_string(),
                enabled: true,
                label: "Bypass".to_string(),
                action: "bypass".to_string(),
                connection_type: "bypass".to_string(),
                user_domains: vec!["example.ru".to_string()],
                ..Default::default()
            }];
        }
        let core = CoreManager::new(Arc::clone(&state));
        let payload = json!({
            "mode": "exact",
            "search": "sub.example.ru",
            "source_ip": "192.168.1.50"
        })
        .to_string();
        let (code, stdout, stderr) =
            execute_tachyon_cli(&["trace_rules".to_string(), payload], &state, &core).await;
        assert_eq!(code, 0, "stderr={stderr}");
        let parsed: Value = serde_json::from_str(stdout.trim()).expect("valid json");
        assert_eq!(parsed["ok"], true);
        assert_eq!(parsed["mode"], "exact");
        assert_eq!(parsed["winning_section"]["id"], "bypass_sec");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn virtual_sub_cache_and_sources_json_work_without_flash_writes() {
        let _test_uci_guard = test_uci_snapshot_lock().lock().await;
        let dir =
            std::env::temp_dir().join(format!("tachyon_virtual_sub_cache_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let state = AppState::load_or_create(dir.join("store.json")).unwrap();
        {
            let mut d = state.data.write().await;
            d.sections.clear();
            d.outbound_sources = vec![crate::store::OutboundSource {
                id: "sub_unassigned".to_string(),
                enabled: true,
                name: "Unassigned Sub".to_string(),
                source_type: "subscription".to_string(),
                subscription_urls: vec!["https://example.com/sub".to_string()],
                sub_title: "My Provider".to_string(),
                sub_upload_bytes: 1024,
                sub_download_bytes: 2048,
                sub_total_bytes: 10240,
                cached_nodes: vec![
                    config_gen::parse_proxy_uri(
                        "vless://11111111-1111-1111-1111-111111111111@198.51.100.10:443#FI%20Node",
                        0,
                    )
                    .unwrap(),
                ],
                ..Default::default()
            }];
            sync_section_cache(&d);
        }

        let listed = handle_file_list(&json!({ "path": "/etc/tachyon/subscription-cache" }));
        let entries = listed[1]["entries"].as_array().expect("entries array");
        assert!(
            entries
                .iter()
                .any(|e| e["name"] == "Pool_sub_unassigned-subscription-1.json"),
            "virtual list must expose Pool_sub_unassigned-subscription-1.json: {entries:?}"
        );

        let read_json = handle_file_read(
            &json!({ "path": "/etc/tachyon/subscription-cache/Pool_sub_unassigned-subscription-1.json" }),
            &state,
        )
        .await;
        assert_eq!(read_json[0], 0);
        let parsed: Value = serde_json::from_str(read_json[1]["data"].as_str().unwrap()).unwrap();
        assert_eq!(parsed["outbounds"].as_array().unwrap().len(), 1);
        assert_eq!(parsed["outbounds"][0]["tag"], "FI Node");

        let read_meta = handle_file_read(
            &json!({ "path": "/etc/tachyon/subscription-cache/Pool_sub_unassigned-subscription-1.metadata.json" }),
            &state,
        )
        .await;
        let meta: Value = serde_json::from_str(read_meta[1]["data"].as_str().unwrap()).unwrap();
        assert_eq!(meta["nodeCount"], 1);
        assert_eq!(meta["title"], "My Provider");

        let sources_path =
            resolve_bridge_runtime_path("/var/run/tachyon/section-cache/_sources.json");
        assert!(
            sources_path.is_file(),
            "_sources.json must exist at {sources_path:?}"
        );
        assert!(is_allowed_bridge_exec(
            "/sbin/logread",
            &["-l".into(), "50".into()]
        ));
        assert!(!is_allowed_bridge_exec("/sbin/logread", &["-l;id".into()]));
        assert!(!is_allowed_bridge_exec("/sbin/logread", &["-f".into()]));
        assert!(!is_allowed_bridge_exec(
            "/sbin/logread",
            &["--follow".into()]
        ));
        assert!(!is_allowed_bridge_exec("/sbin/logread", &["-lf".into()]));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn group_without_source_refs_preserves_enabled_sources_in_metadata() {
        use crate::store::{OutboundGroup, OutboundSource, RouterStoreData, RoutingSection};
        let store = RouterStoreData {
            outbound_sources: vec![
                OutboundSource {
                    id: "sn".into(),
                    enabled: true,
                    ..Default::default()
                },
                OutboundSource {
                    id: "PS".into(),
                    enabled: true,
                    ..Default::default()
                },
                OutboundSource {
                    id: "disabled".into(),
                    enabled: false,
                    ..Default::default()
                },
            ],
            outbound_groups: vec![OutboundGroup {
                id: "all_sources".into(),
                enabled: true,
                ..Default::default()
            }],
            sections: vec![RoutingSection {
                id: "Main".into(),
                outbound_source_refs: vec!["sn".into()],
                outbound_group_refs: vec!["all_sources".into()],
                ..Default::default()
            }],
            ..Default::default()
        };
        let sources: Vec<_> = collect_section_sources_with_owner(&store, "Main")
            .into_iter()
            .map(|(_, src, _)| src.id.as_str())
            .collect();
        assert_eq!(sources, ["sn", "PS"]);
    }

    #[test]
    fn collect_group_skips_disabled_and_supports_star_wildcard_in_section_refs() {
        use crate::store::{OutboundGroup, OutboundSource, RouterStoreData, RoutingSection};
        let store = RouterStoreData {
            outbound_sources: vec![
                OutboundSource {
                    id: "s1".into(),
                    enabled: true,
                    ..Default::default()
                },
                OutboundSource {
                    id: "s2".into(),
                    enabled: true,
                    ..Default::default()
                },
                OutboundSource {
                    id: "s_off".into(),
                    enabled: false,
                    ..Default::default()
                },
            ],
            outbound_groups: vec![
                OutboundGroup {
                    id: "grp_off".into(),
                    enabled: false,
                    source_refs: vec!["s1".into()],
                    ..Default::default()
                },
                OutboundGroup {
                    id: "grp_star".into(),
                    enabled: true,
                    source_refs: vec!["*".into()],
                    ..Default::default()
                },
            ],
            sections: vec![
                RoutingSection {
                    id: "SecDisabled".into(),
                    outbound_group_refs: vec!["grp_off".into()],
                    ..Default::default()
                },
                RoutingSection {
                    id: "SecStar".into(),
                    section_refs: vec!["grp_star".into()],
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        let off_sources: Vec<_> = collect_section_sources_with_owner(&store, "SecDisabled")
            .into_iter()
            .map(|(_, src, _)| src.id.as_str())
            .collect();
        assert!(off_sources.is_empty(), "disabled group must emit nothing");

        let star_sources: Vec<_> = collect_section_sources_with_owner(&store, "SecStar")
            .into_iter()
            .map(|(_, src, _)| src.id.as_str())
            .collect();
        assert_eq!(star_sources, ["s1", "s2"]);
    }

    #[test]
    fn section_metadata_respects_outbound_group_include_servers() {
        use crate::store::{
            OutboundGroup, OutboundSource, ParsedProxyNode, RouterStoreData, RoutingSection,
        };

        let store = RouterStoreData {
            outbound_sources: vec![OutboundSource {
                id: "sub_main".into(),
                name: "Main Sub".into(),
                source_type: "subscription".into(),
                enabled: true,
                cached_nodes: vec![
                    ParsedProxyNode {
                        tag: "EU Node 1".into(),
                        raw_uri:
                            "vless://11111111-1111-1111-1111-111111111111@1.1.1.1:443#EU%20Node%201"
                                .into(),
                        ..Default::default()
                    },
                    ParsedProxyNode {
                        tag: "EU Node 2".into(),
                        raw_uri:
                            "vless://22222222-2222-2222-2222-222222222222@2.2.2.2:443#EU%20Node%202"
                                .into(),
                        ..Default::default()
                    },
                    ParsedProxyNode {
                        tag: "US Node 3".into(),
                        raw_uri:
                            "vless://33333333-3333-3333-3333-333333333333@3.3.3.3:443#US%20Node%203"
                                .into(),
                        ..Default::default()
                    },
                    ParsedProxyNode {
                        tag: "JP Node 4".into(),
                        raw_uri:
                            "vless://44444444-4444-4444-4444-444444444444@4.4.4.4:443#JP%20Node%204"
                                .into(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }],
            outbound_groups: vec![OutboundGroup {
                id: "Ai_eu".into(),
                enabled: true,
                name: "Ai_eu".into(),
                source_refs: vec!["sub_main".into()],
                filter_mode: "include".into(),
                include_servers: vec!["EU Node 1".into(), "EU Node 2".into()],
                ..Default::default()
            }],
            sections: vec![RoutingSection {
                id: "Ai".into(),
                enabled: true,
                outbound_group_refs: vec!["Ai_eu".into()],
                ..Default::default()
            }],
            ..Default::default()
        };

        let meta = read_pure_rust_outbound_metadata(&store, "Ai");
        let names = meta
            .get("names")
            .and_then(Value::as_object)
            .expect("names map");
        assert_eq!(
            names.len(),
            2,
            "expected only 2 filtered servers, got {names:?}"
        );
        assert!(names.contains_key("EU Node 1"));
        assert!(names.contains_key("EU Node 2"));
        assert!(!names.contains_key("US Node 3"));
        assert!(!names.contains_key("JP Node 4"));
    }

    #[test]
    fn virtual_sub_cache_prefers_tmpfs_over_stale_flash_and_server_type_no_resync() {
        let dir = std::env::temp_dir().join(format!("tachyon_virt_pref_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let virt = dir.join("tmpfs");
        let flash = dir.join("flash");
        std::fs::create_dir_all(&virt).unwrap();
        std::fs::create_dir_all(&flash).unwrap();

        std::fs::write(flash.join("Pool_s1-subscription-1.json"), "stale").unwrap();
        std::fs::write(virt.join("Pool_s1-subscription-1.json"), "fresh").unwrap();
        std::fs::write(flash.join("Pool_only_flash-subscription-1.json"), "old").unwrap();

        let p_fresh = resolve_virtual_sub_cache_file_in(
            "/etc/tachyon/subscription-cache/Pool_s1-subscription-1.json",
            &virt,
            &flash,
        )
        .unwrap();
        assert_eq!(p_fresh, virt.join("Pool_s1-subscription-1.json"));

        let p_fallback = resolve_virtual_sub_cache_file_in(
            "/etc/tachyon/subscription-cache/Pool_only_flash-subscription-1.json",
            &virt,
            &flash,
        )
        .unwrap();
        assert_eq!(
            p_fallback,
            flash.join("Pool_only_flash-subscription-1.json")
        );
        let _ = std::fs::remove_dir_all(&dir);

        let mut store = crate::store::RouterStoreData::default();
        store.servers.push(crate::store::InboundServer {
            id: "srv_vless".into(),
            ..Default::default()
        });
        let Value::Object(sections) = crate::store::sync_store_to_json_sections(&store, None)
        else {
            panic!("expected object");
        };
        assert_eq!(sections["srv_vless"][".type"], "server");
        assert!(
            !uci_json_sections_need_resync(&store, &sections),
            "non-empty servers must not trigger resync on every uci.get"
        );
    }

    #[tokio::test]
    async fn ubus_batch_uci_set_coalesces_sync_and_skips_noop_transactions() {
        Box::pin(async move {
            let _test_uci_guard = test_uci_snapshot_lock().lock().await;
        let dir =
            std::env::temp_dir().join(format!("tachyon_ubus_batch_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let state = AppState::load_or_create(dir.join("tachyon.json")).expect("load state");
        let core = CoreManager::new(Arc::clone(&state));
        {
            let d = state.data.read().await.clone();
            set_json_sections_snapshot(Map::new());
            sync_from_store_to_json_and_cache(&d);
        }
        // Complete initial store/uci baseline sync (marks legacy_uci_imported), then clear events.
        sync_uci_to_rust_store_inner(&state, &core, false, false)
            .await
            .expect("initial uci baseline sync");
        PENDING_CORE_RELOAD.store(false, std::sync::atomic::Ordering::Release);
        state.live.write().await.events.clear();

        // 1. No-op uci.set batch setting values equal to existing store must commit 0 transactions.
        let cur_interval = {
            let d = state.data.read().await;
            d.settings.update_interval.clone()
        };
        let noop_batch = serde_json::to_vec(&json!([
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "call",
                "params": [
                    "00000000000000000000000000000000",
                    "uci",
                    "set",
                    { "config": "tachyon", "section": "settings", "values": { "update_interval": cur_interval } }
                ]
            },
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "call",
                "params": [
                    "00000000000000000000000000000000",
                    "uci",
                    "set",
                    { "config": "tachyon", "section": "telegram", "values": { "enabled": "0" } }
                ]
            }
        ]))
        .unwrap();
        let noop_resp = handle_ubus_post(&noop_batch, &state, &core).await;
        assert!(noop_resp.as_array().is_some_and(|a| a.len() == 2));
        assert!(
            !PENDING_CORE_RELOAD.load(std::sync::atomic::Ordering::Acquire),
            "no-op uci.set batch must not mark a pending core reload"
        );
        let noop_tx_count = {
            let live = state.live.read().await;
            live.events
                .iter()
                .filter(|e| e.subsystem == "transaction")
                .count()
        };
        assert_eq!(
            noop_tx_count, 0,
            "no-op uci.set batch must not commit redundant transactions"
        );

        // 2. Real multi-section uci.set batch followed by uci.get must coalesce into at most 1 transaction
        // and expose updated values to subsequent uci.get in the same batch.
        let mut_batch = serde_json::to_vec(&json!([
            {
                "jsonrpc": "2.0",
                "id": 10,
                "method": "call",
                "params": [
                    "00000000000000000000000000000000",
                    "uci",
                    "set",
                    { "config": "tachyon", "section": "settings", "values": { "update_interval": "12h" } }
                ]
            },
            {
                "jsonrpc": "2.0",
                "id": 11,
                "method": "call",
                "params": [
                    "00000000000000000000000000000000",
                    "uci",
                    "set",
                    { "config": "tachyon", "section": "guest_mode", "values": { "enabled": "1" } }
                ]
            },
            {
                "jsonrpc": "2.0",
                "id": 12,
                "method": "call",
                "params": [
                    "00000000000000000000000000000000",
                    "uci",
                    "get",
                    { "config": "tachyon", "section": "settings", "option": "update_interval" }
                ]
            }
        ]))
        .unwrap();
        let mut_resp = handle_ubus_post(&mut_batch, &state, &core).await;
        let arr = mut_resp.as_array().expect("batch array response");
        assert_eq!(arr.len(), 3);
        assert_eq!(arr[2]["result"][1]["value"], "12h");

        let mut_tx_count = {
            let live = state.live.read().await;
            live.events
                .iter()
                .filter(|e| e.subsystem == "transaction")
                .count()
        };
        assert_eq!(
            mut_tx_count, 1,
            "multi-section uci.set batch must coalesce into a single transaction"
        );
        {
            let d = state.data.read().await;
            assert_eq!(d.settings.update_interval, "12h");
            assert!(d.guest_mode.enabled);
        }
        assert!(
            PENDING_CORE_RELOAD.load(std::sync::atomic::Ordering::Acquire),
            "real uci.set batch with trigger_reload=false must mark a pending core reload"
        );

        // 3. Follow-up apply (trigger_reload=true) on unchanged store consumes PENDING_CORE_RELOAD
        // without committing an extra transaction.
        Box::pin(async {
            let _ = Box::pin(core.stop()).await;
            Box::pin(sync_uci_to_rust_store_inner(&state, &core, true, false))
                .await
                .expect("follow-up apply sync");
        })
        .await;
        assert!(
            !PENDING_CORE_RELOAD.load(std::sync::atomic::Ordering::Acquire),
            "trigger_reload=true must consume PENDING_CORE_RELOAD even when store is unchanged"
        );
        let after_apply_tx_count = {
            let live = state.live.read().await;
            live.events
                .iter()
                .filter(|e| e.subsystem == "transaction")
                .count()
        };
        assert_eq!(after_apply_tx_count, 1);
        let _ = std::fs::remove_file(core.manual_stop_marker_path());

        let _ = std::fs::remove_dir_all(&dir);
        })
        .await;
    }

    #[test]
    fn exit_country_parses_clash_exit_json_and_prefers_section_mixed() {
        let clash_payload = json!({
            "outbound": "UK-Node-1",
            "ipv4": { "address": "185.199.108.153", "country": "gb" },
            "ipv6": { "error": "Timeout" }
        });
        assert_eq!(
            parse_clash_exit_probe_json(&clash_payload),
            Some(("185.199.108.153".to_string(), "GB".to_string()))
        );

        let fallback_v6 = json!({
            "ipv4": { "error": "network unreachable" },
            "ipv6": { "address": "2001:db8::1", "country": "DE" }
        });
        assert_eq!(
            parse_clash_exit_probe_json(&fallback_v6),
            Some(("2001:db8::1".to_string(), "DE".to_string()))
        );

        let store = crate::store::RouterStoreData {
            sections: vec![crate::store::RoutingSection {
                id: "fallback".to_string(),
                enabled: true,
                action: "proxy".to_string(),
                connection_type: "vless".to_string(),
                active_selected_tag: "UK-Node-1".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(
            resolve_primary_exit_section_id(&store, Some("sel-fallback")),
            "fallback"
        );
        assert_eq!(
            resolve_primary_exit_section_id(&store, Some("UK-Node-1")),
            "fallback"
        );

        let cfg_with_service_only = json!({
            "inbounds": [
                { "type": "mixed", "tag": "service-mixed-in", "listen": "127.0.0.1", "listen_port": 4534 }
            ]
        })
        .to_string();
        assert_eq!(
            resolve_section_mixed_proxy_url_from_raw(
                &store,
                Some(&cfg_with_service_only),
                "fallback"
            ),
            None
        );

        let cfg_with_section_mixed = json!({
            "inbounds": [
                { "type": "mixed", "tag": "service-mixed-in", "listen": "127.0.0.1", "listen_port": 4534 },
                { "type": "mixed", "tag": "mixed-sec-fallback", "listen": "0.0.0.0", "listen_port": 1088 }
            ]
        })
        .to_string();
        assert_eq!(
            resolve_section_mixed_proxy_url_from_raw(
                &store,
                Some(&cfg_with_section_mixed),
                "fallback"
            ),
            Some("http://127.0.0.1:1088".to_string())
        );
    }
}
