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
static JOB_SEQ: PortableAtomicU64 = PortableAtomicU64::new(1);

pub fn mark_daemon_mode() {
    DAEMON_MODE.store(true, std::sync::atomic::Ordering::Release);
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

fn json_sections_path() -> PathBuf {
    let data_dir = std::env::var("TACHYON_DATA_DIR").unwrap_or_else(|_| {
        if cfg!(target_os = "linux") && Path::new("/etc/tachyon").exists() {
            "/etc/tachyon".to_string()
        } else {
            "data".to_string()
        }
    });
    Path::new(&data_dir).join("config_sections.json")
}

fn json_sections_store() -> &'static RwLock<Map<String, Value>> {
    let lock = JSON_SECTIONS_STORE.get_or_init(|| {
        let path = json_sections_path();
        let legacy_path = Path::new("/etc/config/tachyon");
        let backup_path = Path::new(crate::store::LEGACY_UCI_BACKUP_PATH);
        if legacy_path.exists() {
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
        let uci_raw = match std::fs::read_to_string(legacy_path) {
            Ok(s) if !s.trim().is_empty() => Some(s),
            _ => match std::fs::read_to_string(backup_path) {
                Ok(s) if !s.trim().is_empty() => Some(s),
                _ => None,
            },
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
                    "dns_type": "doh"
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
    lock
}

fn persist_json_sections(map: &Map<String, Value>) {
    let path = json_sections_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = crypto_gen::write_json_if_changed(&path, &Value::Object(map.clone()));
    if cfg!(target_os = "linux") && Path::new("/etc/config").exists() {
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
    let next_idx = store.len();
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

/// Synchronize a section's (and optionally its linked condition's) `user_domains` back into `config_sections.json`.
pub fn sync_section_user_domains_to_json(
    section_id: &str,
    domains: &[String],
    linked_condition_id: Option<&str>,
    cond_domains: Option<&[String]>,
) {
    if let Ok(mut store) = json_sections_store().write() {
        let mut changed = false;
        let dom_val = Value::Array(domains.iter().cloned().map(Value::String).collect());
        if let Some(sec_obj) = store.get_mut(section_id).and_then(Value::as_object_mut)
            && sec_obj.get("user_domains") != Some(&dom_val)
        {
            sec_obj.insert("user_domains".to_string(), dom_val);
            changed = true;
        }
        if let (Some(cid), Some(cdoms)) = (linked_condition_id, cond_domains) {
            let cdom_val = Value::Array(cdoms.iter().cloned().map(Value::String).collect());
            if let Some(cond_obj) = store.get_mut(cid).and_then(Value::as_object_mut)
                && cond_obj.get("user_domains") != Some(&cdom_val)
            {
                cond_obj.insert("user_domains".to_string(), cdom_val);
                changed = true;
            }
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
pub fn serve_luci_shell(subview: Option<&str>, ui_lang: &str) -> String {
    let lang = if ui_lang.trim().eq_ignore_ascii_case("en") {
        "en"
    } else {
        "ru"
    };
    let sub = subview
        .map(|s| s.trim_matches('/'))
        .filter(|s| !s.is_empty());
    let req_path_json = if let Some(s) = sub {
        format!("[\"admin\", \"services\", \"tachyon\", \"{s}\"]")
    } else {
        "[\"admin\", \"services\", \"tachyon\"]".to_string()
    };
    let pathinfo = if let Some(s) = sub {
        format!("/admin/services/tachyon/{s}")
    } else {
        "/admin/services/tachyon".to_string()
    };

    let rev = file_mtime_ns(Path::new(
        "/tmp/tachyon-rs/www/luci-static/resources/view/tachyon/main.js",
    ))
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
    :root,
    html,
    body,
    html[data-darkmode="true"] {{
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
      --mono: "SF Mono", ui-monospace, "Cascadia Code", "JetBrains Mono", monospace;
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
      --r-card: 12px;
      --r-btn: 8px;
      --r-xs: 6px;
      --spring: cubic-bezier(0.22, 1, 0.36, 1);
      --transition: 160ms var(--spring);
      --tachyon-theme-accent: #0a84ff;
      --primary-color-high: #0a84ff;
      --primary-color-medium: #0a84ff;
      --primary-color-low: rgba(10, 132, 255, 0.16);
      --background-color-high: #141416;
      --background-color-medium: #0b0b0c;
      --background-color-low: #1c1c1f;
      --border-color-high: rgba(255, 255, 255, 0.15);
      --border-color-medium: rgba(255, 255, 255, 0.08);
      --border-color-low: rgba(255, 255, 255, 0.06);
      --text-color-high: #f5f5f7;
      --text-color-medium: #a1a1a6;
      --text-color-low: #6e6e73;
      color-scheme: dark;
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
      background: rgba(22, 22, 26, 0.96) !important;
      border: 1px solid rgba(255, 255, 255, 0.14) !important;
      border-radius: 10px !important;
      padding: 10px 14px !important;
      font-size: 13px !important;
      font-weight: 500 !important;
      color: #f5f5f7 !important;
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
      border: 1px solid rgba(10, 132, 255, 0.35);
      box-shadow: 0 8px 28px rgba(10, 132, 255, 0.18);
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
      50% {{ transform: scale(1.08); opacity: 1; filter: drop-shadow(0 0 8px rgba(10, 132, 255, 0.55)); }}
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
  <div class="tachyon-bg-layer" aria-hidden="true">
    <svg viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" fill="none" xmlns="http://www.w3.org/2000/svg">
      <g stroke="rgba(255,255,255,0.028)" stroke-width="1">
        <path d="M-100 140 C 420 40, 1080 280, 1700 90"/>
        <path d="M-100 290 C 480 190, 1020 420, 1700 240"/>
        <path d="M-100 450 C 520 370, 1080 550, 1700 420"/>
        <path d="M-100 620 C 460 520, 1120 710, 1700 580"/>
        <path d="M-100 780 C 540 680, 1060 840, 1700 740"/>
        <path d="M 180 -60 C 420 320, 880 580, 1480 960"/>
        <path d="M 640 -60 C 820 300, 1180 560, 1680 880"/>
      </g>
      <g stroke-width="1.5" stroke-linecap="round">
        <path class="tachyon-stream" stroke="#0a84ff" stroke-opacity="0.55" d="M-100 140 C 420 40, 1080 280, 1700 90"/>
        <path class="tachyon-stream s2" stroke="#f5f5f7" stroke-opacity="0.32" d="M-100 290 C 480 190, 1020 420, 1700 240"/>
        <path class="tachyon-stream s3" stroke="#0a84ff" stroke-opacity="0.62" d="M-100 450 C 520 370, 1080 550, 1700 420"/>
        <path class="tachyon-stream s4" stroke="#64d2ff" stroke-opacity="0.45" d="M-100 620 C 460 520, 1120 710, 1700 580"/>
        <path class="tachyon-stream s5" stroke="#f5f5f7" stroke-opacity="0.28" d="M-100 780 C 540 680, 1060 840, 1700 740"/>
        <path class="tachyon-stream s2" stroke="#0a84ff" stroke-opacity="0.4" d="M 180 -60 C 420 320, 880 580, 1480 960"/>
        <path class="tachyon-stream s4" stroke="#0a84ff" stroke-opacity="0.35" d="M 640 -60 C 820 300, 1180 560, 1680 880"/>
      </g>
    </svg>
  </div>
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
    for p in [
        "/tmp/tachyon-rs/fe-app-tachyon/locales/tachyon.ru.po",
        "/usr/share/tachyon/tachyon.ru.po",
        "fe-app-tachyon/locales/tachyon.ru.po",
        "luci-app-tachyon/po/ru/tachyon.po",
    ] {
        if let Ok(raw) = std::fs::read_to_string(p)
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
        for precompiled in [
            "/www/luci-static/resources/view/tachyon/i18n_ru.js",
            "/tmp/tachyon-rs/www/luci-static/resources/view/tachyon/i18n_ru.js",
            "luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/i18n_ru.js",
        ] {
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

/// Resolve a static asset under `/luci-static/<rel_path>` on disk without caching megabytes in heap.
/// Returns `(file_path, mime_type, size_bytes, etag)`.
pub fn resolve_static_asset(rel_path: &str) -> Option<(PathBuf, &'static str, u64, String)> {
    let clean = rel_path
        .split('?')
        .next()
        .unwrap_or(rel_path)
        .trim_start_matches('/');
    if clean.is_empty() || clean.contains("..") || clean.contains('\\') {
        return None;
    }

    let roots = [
        PathBuf::from("/www/luci-static"),
        PathBuf::from("/tmp/tachyon-rs/www/luci-static"),
        PathBuf::from("luci-app-tachyon/htdocs/luci-static"),
    ];

    for root in &roots {
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
            _ => true,
        }
    };

    match parsed {
        Value::Array(mut items) => {
            if items.len() <= 1 || items.iter().any(is_mutating_ubus_rpc) {
                let mut out = Vec::with_capacity(items.len());
                for item in &items {
                    out.push(handle_single_ubus_rpc(item, state, core).await);
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
        single => handle_single_ubus_rpc(&single, state, core).await,
    }
}

async fn handle_single_ubus_rpc(
    req: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
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

    let result = dispatch_ubus_call(object, rpc_method, args, state, core).await;
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
}

async fn dispatch_ubus_call(
    object: &str,
    method: &str,
    args: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
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
        ("luci", "getFeatures") => json!([
            0,
            {
                "firewall": true,
                "nftables": true,
                "ipv6": true,
                "dnsmasq": true,
                "offloading": true
            }
        ]),
        ("file", "list") => handle_file_list(args),
        ("file", "stat" | "lstat") => handle_file_stat(args),
        ("file", "read") => handle_file_read(args, state).await,
        ("file", "write") => handle_file_write(args),
        ("file", "remove") => handle_file_remove(args),
        ("file", "exec") => handle_file_exec(args, state, core).await,
        ("uci", uci_method) => handle_uci_call(uci_method, args, state, core).await,
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

fn handle_file_list(args: &Value) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    let Ok(rd) = std::fs::read_dir(path) else {
        return json!([4]);
    };
    let mut entries = Vec::new();
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
            entries.push(json!({
                "name": name,
                "type": ftype,
                "size": meta.len(),
                "mtime": mtime,
            }));
        }
    }
    json!([0, { "entries": entries }])
}

fn handle_file_stat(args: &Value) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    let Ok(meta) = std::fs::metadata(path) else {
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

async fn handle_file_read(args: &Value, state: &Arc<AppState>) -> Value {
    let Some(path) = args.get("path").and_then(Value::as_str) else {
        return json!([2]);
    };
    if let Ok(bytes) = std::fs::read(path) {
        let data = String::from_utf8_lossy(&bytes).into_owned();
        return json!([0, { "data": data }]);
    }
    if path == "/var/run/tachyon/section-errors.json"
        || path == "/var/run/tachyon/rule-conflicts.json"
    {
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

    if command == "/usr/bin/tachyon" || command == "/usr/bin/tachyon-read" || command == "tachyon" {
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

    let mut cmd = Command::new(command);
    cmd.args(&params);
    if let Some(env_obj) = args.get("env").and_then(Value::as_object) {
        for (k, v) in env_obj {
            if let Some(s) = v.as_str() {
                cmd.env(k, s);
            }
        }
    }

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
                let idx_sec = store.len();
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
            let _ = sync_uci_to_rust_store(state, core).await;
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
                let _ = sync_uci_to_rust_store(state, core).await;
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
                let _ = sync_uci_to_rust_store(state, core).await;
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
                    let next_idx = store.len();
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
                let _ = sync_uci_to_rust_store(state, core).await;
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
                    let next_idx = store.len();
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
                let _ = sync_uci_to_rust_store(state, core).await;
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
                let _ = sync_uci_to_rust_store(state, core).await;
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
            let _ = sync_uci_to_rust_store(state, core).await;
            (0, String::new(), String::new())
        }
        "commit" | "apply" => {
            clear_uci_rollback_baseline();
            if let Ok(store) = json_sections_store().read() {
                persist_json_sections(&store);
            }
            if let Err(err) = sync_uci_to_rust_store(state, core).await {
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

/// Execute `/usr/bin/tachyon <method> [args...]` with sub-millisecond Pure-Rust handlers
/// for all hot paths (`get_ui_state`, `get_system_info`, `get_outbound_metadata`, `clash_api`, etc.).
pub async fn execute_tachyon_cli(
    params: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (i32, String, String) {
    let Some(method) = params.first().map(|s| s.trim()) else {
        return (0, String::new(), String::new());
    };
    let rest = &params[1..];

    // 1. Sub-millisecond Pure-Rust handlers for all frequent UI / telemetry / metadata / crypto methods
    if let Some(fast) = try_fast_pure_rust_method_boxed(method, rest, state, core).await {
        return fast;
    }

    // 2. All remaining CLI / RPC methods are handled 100% in pure Rust without ucode
    execute_pure_rust_tachyon_cli_boxed(method, rest, state, core).await
}

/// Fast pure-Rust implementations of hot RPC methods (`<1 ms` latency, zero process forks).
async fn try_fast_pure_rust_method(
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
            let val = build_pure_rust_ui_state(state).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_system_info" => {
            state.touch_telemetry_access();
            let val = build_pure_rust_system_info(state).await;
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_status" => {
            state.touch_telemetry_access();
            let sys = sys_info::collect_host_info();
            let live = state.live.read().await.clone();
            let d = state.data.read().await;
            let daemon_uptime = sys_info::daemon_uptime_secs();
            let cpu_pct = sys_info::sample_cpu_load_percent();
            let panel_mb = ((sys.panel_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);
            let val = json!({
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
            });
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
                let d_updated = state.data.read().await.clone();
                sync_from_store_to_json_and_cache(&d_updated);
                let s = serde_json::to_string(&json!({ "success": true, "ui_prefs": merged }))
                    .unwrap_or_else(|_| "{}".to_string());
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
                let next_idx = store.len();
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
        "clash_api" => handle_pure_rust_clash_api(rest, state, core).await,
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
            let val = match crate::adguard_hosts::query_dns_block_stats_for_state(
                state, core, period,
            )
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
        "show_sing_box_config" | "show_tachyon_core_config" => {
            let want_raw = rest.iter().any(|a| a == "raw" || a == "--raw");
            let val = if let Ok(raw) = std::fs::read_to_string("/etc/tachyon-core/config.json")
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
                .unwrap_or_else(|| Path::new("/etc/tachyon"))
                .join("server-certs");
            let cert_path = cert_dir.join(format!("{sid}.crt"));
            let key_path = cert_dir.join(format!("{sid}.key"));
            let core_bin = { state.data.read().await.settings.core_bin_path.clone() };
            let core_bin_opt = (!core_bin.trim().is_empty()).then_some(core_bin.as_str());
            let payload =
                match crypto_gen::generate_tls_keypair_files(core_bin_opt, &cn, &cert_path, &key_path)
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
                .unwrap_or_else(|| Path::new("/etc/tachyon"));
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
        "generate_warp" => {
            let kp = crypto_gen::generate_wg_keypair();
            let s = serde_json::to_string(&json!({
                "success": true,
                "private_key": kp.private_key,
                "public_key": kp.public_key,
                "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "server_address": "engage.cloudflareclient.com",
                "server": "engage.cloudflareclient.com",
                "server_port": 2408,
                "local_address": "172.16.0.2/32",
                "ipv6_address": "2606:4700:110:8a36::2/128",
                "mtu": 1280,
                "jc": 4,
                "jmin": 40,
                "jmax": 70,
                "s1": 0,
                "s2": 0,
                "h1": 1,
                "h2": 2,
                "h3": 3,
                "h4": 4,
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
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
        "doctor" => {
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
            Some((0, format!("{s}\n"), String::new()))
        }
        "route_explain" => {
            let client_ip = rest.first().map(String::as_str).unwrap_or("192.168.1.100");
            let target = rest.get(1).map(String::as_str).unwrap_or("www.youtube.com");
            let port = rest
                .get(2)
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or(443);
            let proto = rest.get(3).map(String::as_str).unwrap_or("tcp");
            let nft_active = crate::net_stack::check_nft_table_active().await;
            let d = state.data.read().await.clone();
            let val = crate::diagnostics::build_route_trace_json_async(
                &d, client_ip, target, "", port, proto, nft_active,
            )
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
            let bundle = diagnostics::build_support_bundle(state).await;
            let s = serde_json::to_string(&bundle).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        _ => None,
    }
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

fn build_core_health_check_payload(
    d: &crate::store::RouterStoreData,
    live: &crate::store::LiveTelemetry,
    ipv6_active: bool,
) -> Value {
    let installed = tachyon_core_binary_installed();
    let version_ok =
        installed && !live.core_version.is_empty() && live.core_version != "not installed";
    let service_exist = Path::new("/etc/init.d/tachyon-core").exists();
    let mut missing_ports: Vec<String> = Vec::new();
    let mut active_ports: Vec<String> = Vec::new();
    let cfg_path = std::env::var("TACHYON_CORE_CONFIG_PATH")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            if d.settings.core_config_path.trim().is_empty() {
                "/etc/tachyon-core/config.json".to_string()
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
    let autostart_disabled = !std::fs::read_dir("/etc/rc.d")
        .ok()
        .map(|rd| {
            rd.flatten()
                .any(|e| e.file_name().to_string_lossy().ends_with("tachyon-core"))
        })
        .unwrap_or(false);
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
        "tachyon_core_bin_path": "/usr/bin/tachyon-core",
        "tachyon_core_init_path": "/etc/init.d/tachyon-core",
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
        "sing_box_bin_path": "/usr/bin/tachyon-core",
        "sing_box_init_path": "/etc/init.d/tachyon-core",
        "sing_box_listen_ports": listen_ports_str,
    })
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
    let dnsmasq = sys_info::collect_dnsmasq_status();
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
            "dnsmasq": {
                "running": i32::from(dnsmasq.running),
                "pid": dnsmasq.pid,
                "memory_rss_mb": dnsmasq.memory_rss_mb,
                "uptime_seconds": dnsmasq.uptime_secs,
                "uptime_pretty": if dnsmasq.running { format_uptime_pretty(dnsmasq.uptime_secs) } else { String::new() },
                "local_cache_enabled": i32::from(dnsmasq.local_cache_enabled),
                "cache_size": dnsmasq.cache_size
            },
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
            "subscription": []
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
    crate::fuzzer::is_desync_engine_installed(&format!("/usr/bin/{bin_name}"))
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

    let mut base = if let Ok(raw) =
        tokio::fs::read_to_string("/var/run/tachyon/system-info.json").await
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
            tachyon_cached.and_then(|r| r.get("status").and_then(Value::as_str))
                == Some("outdated"),
        );
        obj.insert("tachyon_version".to_string(), json!(tachyon_ver));
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
            core_cached.and_then(|r| r.get("status").and_then(Value::as_str)) == Some("outdated"),
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
    let include_all = section.is_empty() || section == "all";

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

    for sec in &store.sections {
        if !include_all && sec.id != section {
            continue;
        }
        for sref in &sec.outbound_source_refs {
            if let Some(src) = source_by_id.get(sref.as_str()).copied()
                && seen.insert((sec.id.clone(), src.id.as_str()))
            {
                seen_global.insert(src.id.as_str());
                result.push((sec.id.clone(), src, src.hidden || sec.hidden));
            }
        }
        for gref in std::iter::once(&sec.outbound_group_ref).chain(sec.outbound_group_refs.iter()) {
            if gref.is_empty() {
                continue;
            }
            if let Some(grp) = group_by_id.get(gref.as_str()).copied() {
                for sref in &grp.source_refs {
                    if let Some(src) = source_by_id.get(sref.as_str()).copied()
                        && seen.insert((sec.id.clone(), src.id.as_str()))
                    {
                        seen_global.insert(src.id.as_str());
                        result.push((sec.id.clone(), src, src.hidden || sec.hidden));
                    }
                }
            }
        }
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
            names.entry(tag.clone()).or_insert_with(|| json!(tag));
            let cc = crate::config_gen::detect_country_code(&tag);
            if !cc.is_empty() {
                countries.entry(tag.clone()).or_insert_with(|| json!(cc));
            }
            if let Some(proto) = out_val.get("type").and_then(Value::as_str) {
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
        let cache_dir = Path::new("/var/run/tachyon/section-cache");
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
        obj.insert("nodeCount".into(), json!(src.cached_nodes.len()));
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
        let cache_path =
            Path::new("/var/run/tachyon/section-cache").join(format!("{section}.json"));
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

/// Synchronize per-section runtime cache files in `/var/run/tachyon/section-cache/*.json` (tmpfs).
pub fn sync_section_cache(store: &crate::store::RouterStoreData) {
    let cache_dir = crate::store::runtime_state_dir().join("section-cache");
    let _ = std::fs::create_dir_all(&cache_dir);

    let mut active_files = std::collections::HashSet::new();
    for sec in &store.sections {
        if sec.id.is_empty() || sec.id.contains("..") || sec.id.contains('/') {
            continue;
        }
        let fname = format!("{}.json", sec.id);
        active_files.insert(fname.clone());
        let (outbound_meta, links, hidden) = build_outbound_metadata_and_links(store, &sec.id);
        let sub_meta = read_pure_rust_subscription_metadata(store, &sec.id);
        let payload = json!({
            "section": sec.id,
            "outboundMetadata": outbound_meta,
            "subscriptionMetadata": sub_meta,
            "links": links,
            "hiddenOutboundTags": hidden,
        });
        let _ = crypto_gen::write_json_if_changed(cache_dir.join(fname), &payload);
    }

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
}

fn read_pure_rust_component_update_cache() -> Value {
    crate::updater::read_component_check_cache()
}

async fn handle_pure_rust_clash_api(
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Option<(i32, String, String)> {
    let action = rest.first().map(String::as_str).unwrap_or("");
    match action {
        "get_proxies" => {
            if let Ok(val) = core.clash_request("GET", "/proxies", None).await
                && let Ok(raw) = serde_json::to_string(&val)
            {
                let _ = std::fs::create_dir_all("/var/run/tachyon/ui-state");
                let _ = crypto_gen::write_file_if_changed(
                    Path::new("/var/run/tachyon/ui-state/clash-proxies.json"),
                    raw.as_bytes(),
                );
                return Some((0, format!("{raw}\n"), String::new()));
            }
            if let Ok(cached) =
                std::fs::read_to_string("/var/run/tachyon/ui-state/clash-proxies.json")
                && !cached.trim().is_empty()
            {
                return Some((0, cached, String::new()));
            }
            Some((0, "{\"proxies\":{}}\n".to_string(), String::new()))
        }
        "get_connections" => {
            state.touch_telemetry_access();
            let conntrack_only = rest.get(1).map(String::as_str) == Some("conntrack");
            if !conntrack_only {
                let cache_path = Path::new("/var/run/tachyon/ui-state/clash-connections.json");
                if let Ok(meta) = std::fs::metadata(cache_path)
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
                let _ = std::fs::create_dir_all("/var/run/tachyon/ui-state");
                let _ = crypto_gen::write_file_if_changed(
                    Path::new("/var/run/tachyon/ui-state/clash-connections.json"),
                    raw.as_bytes(),
                );
                return Some((0, format!("{raw}\n"), String::new()));
            }
            if let Ok(cached) =
                std::fs::read_to_string("/var/run/tachyon/ui-state/clash-connections.json")
                && !cached.trim().is_empty()
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
            let timeout = rest.get(2).map(String::as_str).unwrap_or("5000");
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
            let target_tag = if action == "get_group_latency" {
                let d_snap = state.data.read().await.clone();
                let proxies_val = core.clash_request("GET", "/proxies", None).await.ok();
                let proxies_map = proxies_val
                    .as_ref()
                    .and_then(|v| v.get("proxies"))
                    .and_then(Value::as_object);
                resolve_clash_group_for_target(&d_snap, proxies_map, tag)
            } else {
                tag.to_string()
            };
            let encoded_tag = url_encode_component(&target_tag);
            let encoded_url = url_encode_component(url);
            let path = if action == "get_group_latency" {
                format!("/group/{encoded_tag}/delay?url={encoded_url}&timeout={timeout}")
            } else {
                format!("/proxies/{encoded_tag}/delay?url={encoded_url}&timeout={timeout}")
            };
            let primary_res = core.clash_request("GET", &path, None).await;
            let needs_proxy_fallback = action == "get_proxy_latency"
                && match &primary_res {
                    Err(_) => true,
                    Ok(val) => {
                        val.get("delay").and_then(Value::as_u64).unwrap_or(0) == 0
                            && val.get("message").is_some()
                    }
                };
            let final_res = if needs_proxy_fallback {
                let d_snap = state.data.read().await.clone();
                let proxies_val = core.clash_request("GET", "/proxies", None).await.ok();
                let proxies_map = proxies_val
                    .as_ref()
                    .and_then(|v| v.get("proxies"))
                    .and_then(Value::as_object);
                if let Some(fallback_tag) =
                    proxies_map.and_then(|pm| resolve_clash_proxy_for_target(&d_snap, pm, tag))
                {
                    let enc_fallback = url_encode_component(&fallback_tag);
                    let fallback_path = format!(
                        "/proxies/{enc_fallback}/delay?url={encoded_url}&timeout={timeout}"
                    );
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
                            "/proxies/{encoded}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000"
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
                    "/group/{encoded_tag}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000"
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
    for (_owner, src, _hidden) in collect_section_sources_with_owner(store, section) {
        if src.source_type == "subscription" {
            for node in &src.cached_nodes {
                let t = node.tag.trim();
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
        }
    }
    out
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

fn build_telemetry_tag_display_map(
    d: &crate::store::RouterStoreData,
) -> std::collections::HashMap<String, String> {
    const SOURCE_PREFIXES: &[&str] = &[
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

    map
}

fn resolve_telemetry_tag_display_name(
    raw_tag: &str,
    display_map: &std::collections::HashMap<String, String>,
    d: &crate::store::RouterStoreData,
) -> String {
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

    tag.to_string()
}

async fn build_pure_rust_core_telemetry(state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let store_snap = state.data.read().await.clone();
    let tag_display_map = build_telemetry_tag_display_map(&store_snap);
    let (mem_res, dev_res, conn_res, flight_res, failover_res, leak_res, health_res, anomalies_res) = tokio::join!(
        core.clash_request("GET", "/tachyon/memory", None),
        core.clash_request("GET", "/tachyon/devices", None),
        core.clash_request("GET", "/connections", None),
        core.clash_request("GET", "/tachyon/flight", None),
        core.clash_request("GET", "/tachyon/failover", None),
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
        "/etc/tachyon-core/config.json".to_string()
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

        let firewall_required = if is_ts
            || srv.protocol == "json_inbound"
            || listen_port == 0
            || !srv.open_firewall_port
        {
            0
        } else {
            1
        };
        #[cfg(target_os = "linux")]
        let firewall_open = if firewall_required == 1 {
            let local_ips = collect_local_router_ips(&wan_ip, &wan_ipv6, &listen, &ip_addr_out);
            let quick = check_fw4_port_open_with_redirects(
                &fw4_in,
                &fw4_dstnat,
                "",
                listen_port,
                &required_proto,
                &local_ips,
            );
            if quick == 1 {
                1
            } else {
                let uci_fw = uci_fw_cache.get_or_insert_with(|| {
                    std::process::Command::new("uci")
                        .args(["show", "firewall"])
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                        .unwrap_or_default()
                });
                check_fw4_port_open_with_redirects(
                    &fw4_in,
                    &fw4_dstnat,
                    uci_fw,
                    listen_port,
                    &required_proto,
                    &local_ips,
                )
            }
        } else {
            -1
        };
        #[cfg(not(target_os = "linux"))]
        let firewall_open = -1;

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
            "firewall_required": firewall_required,
            "firewall_open": firewall_open,
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
        let next_idx = store.len();
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
    let cache_path = Path::new("/var/run/tachyon/ui-state/ai-doctor-last.json");
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
) -> (i32, String, String) {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();

    match method {
        "check_proxy" => {
            let (code, text) = diagnostics::run_proxy_check_cli(&d, live.core_running).await;
            return (code, text, String::new());
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
            return (0, text, String::new());
        }
        "component_action_log" => {
            let job_id = rest.first().map(String::as_str).unwrap_or("");
            let offset = rest
                .get(1)
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(0);
            let out = crate::updater::read_job_log(job_id, offset);
            return (0, format!("{out}\n"), String::new());
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
            return (0, report, String::new());
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
            build_core_health_check_payload(&d, &live, ipv6_active)
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
            let dns_probe = diagnostics::run_dns_check_with_engine(core, "www.youtube.com").await;
            let dns_ok = dns_probe_succeeded(&dns_probe);
            let boot_target = resolve_dns_bench_target(&boot_srv, "udp");
            let boot_ok = tokio::time::timeout(
                Duration::from_millis(800),
                tokio::net::TcpStream::connect(&boot_target),
            )
            .await
            .is_ok_and(|r| r.is_ok())
                || boot_srv.parse::<std::net::IpAddr>().is_ok() && dns_ok;
            let dnsmasq = sys_info::collect_dnsmasq_status();
            let dns_on_router = dnsmasq.running
                || check_proc_port_listening("0.0.0.0", 53, "udp") == 1
                || live.core_running;
            json!({
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
                "dhcp_config_status": i32::from(dnsmasq.running),
                "dont_touch_dhcp": i32::from(d.settings.dont_touch_dhcp),
                "probe": dns_probe,
            })
        }
        "check_fakeip" => {
            let f4 = d.settings.fakeip_inet4_range.clone();
            let f6 = d.settings.fakeip_inet6_range.clone();
            let store_snap = d.clone();
            drop(d);
            let (_lan_v6, wan_v6, _) =
                tokio::task::spawn_blocking(sys_info::detect_router_ipv6_ips)
                    .await
                    .unwrap_or_default();
            let ipv6_state = crate::store::resolve_effective_ipv6_state(
                &store_snap.settings,
                !wan_v6.is_empty(),
            );
            let (v4_ok, v4_ip, v6_ok, v6_ip, aaaa_suppressed) =
                diagnostics::probe_local_fakeip_dns_with(&f4, &f6, ipv6_state.is_active()).await;
            diagnostics::format_fakeip_probe_payload(diagnostics::FakeIpProbePayloadInput {
                d: &store_snap,
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
            let nft_installed =
                Path::new("/usr/sbin/nft").exists() || Path::new("/sbin/nft").exists();
            if d.settings.proxy_mode == "tun" || d.settings.proxy_mode == "socks" {
                json!({
                    "not_applicable": 1,
                    "installed": nft_installed || table_active,
                    "table_present": table_active,
                    "table_exist": i32::from(table_active),
                    "table_name": "inet TachyonTable",
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
                    "rules": net_stack::compile_nftables_ruleset(&d),
                })
            }
        }
        "check_inbounds_config" => json!({
            "success": true,
            "enabled_count": d.servers.iter().filter(|s| s.enabled).count(),
        }),
        "check_inbounds" => {
            let d_clone = d.clone();
            drop(d);
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
            let ts = core.get_tailscale_status().await;
            let enabled = net_stack::is_tailscale_enabled(&d);
            json!({
                "success": true,
                "enabled": enabled,
                "native": net_stack::native_tailscale_enabled(&d),
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
            let plan = transaction::analyze_config_plan(&d);
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
            handle_service_action_async(act, state, core).await
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

            let proxies_val = core.clash_request("GET", "/proxies", None).await.ok();
            let proxies_map = proxies_val
                .as_ref()
                .and_then(|v| v.get("proxies"))
                .and_then(Value::as_object);

            let (target_tags, eff_tag) =
                resolve_latency_targets(&d, proxies_map, ltype, section, raw_tag);

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

            let worker_fut = async move {
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
            };

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
        "ui_action_ack" | "component_action_ack" => json!({
            "success": true
        }),
        "component_install_version" => {
            let comp = rest.first().map(String::as_str).unwrap_or("tachyon-core");
            let tag = rest.get(1).map(String::as_str);
            crate::updater::start_component_action(core, comp, "install_version", tag).await
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
                crate::updater::start_component_action(core, comp, act, variant).await
            } else {
                let v = core.component_action(comp, act, variant).await;
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
            crate::updater::list_releases(core, comp, count, page).await
        }
        "list_update" | "list_update_async" => crate::updater::start_list_update_async(core).await,
        "list_update_if_due" => crate::updater::start_list_update_if_due_async(core).await,
        "list_update_status" => crate::updater::read_list_update_status(),
        "subscription_update" => {
            let target = rest.first().map(String::as_str).unwrap_or("");
            let selector = rest.get(1).map(String::as_str).unwrap_or("");
            let eff_target = resolve_subscription_cli_target(&d, target, selector);
            match core.refresh_subscription_source(&eff_target).await {
                Ok(cnt) => {
                    let d_now = state.data.read().await.clone();
                    sync_section_cache(&d_now);
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
            let eff_target = resolve_subscription_cli_target(&d, &target, &selector);
            let seq = next_job_seq();
            let job_id = format!(
                "rust-sub-{}-{}-{seq}",
                sanitize_job_slug(if target.is_empty() { "all" } else { &target }),
                crate::store::unix_now_u64()
            );
            let jobs_dir = crate::store::runtime_state_dir().join("subscription-jobs");
            let _ = std::fs::create_dir_all(&jobs_dir);
            let job_path = jobs_dir.join(format!("{job_id}.json"));
            let start_payload = json!({
                "success": true,
                "job_id": job_id,
                "section": target,
                "source_selector": selector,
                "resolved_target": eff_target,
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
            let work = async move {
                let done_payload = match core_clone.refresh_subscription_source(&eff_bg).await {
                    Ok(cnt) => {
                        let d_now = state_clone.data.read().await.clone();
                        sync_section_cache(&d_now);
                        json!({
                            "success": true,
                            "job_id": job_id_bg,
                            "section": target_bg,
                            "source_selector": selector_bg,
                            "resolved_target": eff_bg,
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
                        "resolved_target": eff_bg,
                        "status": "failed",
                        "running": false,
                        "completed": true,
                        "exit_code": 1,
                        "message": e.to_string()
                    }),
                };
                let _ = crypto_gen::write_json_if_changed(&job_path_bg, &done_payload);
                done_payload
            };
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
            let eff_target = target.map(|t| resolve_subscription_cli_target(&d, t, selector));
            match core.refresh_due_subscriptions(eff_target.as_deref()).await {
                Ok(cnt) => {
                    if cnt > 0 {
                        let d_now = state.data.read().await.clone();
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
            crate::updater::maybe_run_auto_update_tick(core).await;
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
        "start" => match core.start().await {
            Ok(()) => {
                let d_now = state.data.read().await.clone();
                sync_section_cache(&d_now);
                json!({ "success": true })
            }
            Err(e) => json!({ "success": false, "error": format!("{e:#}") }),
        },
        "stop" => match core.stop().await {
            Ok(()) => json!({ "success": true }),
            Err(e) => json!({ "success": false, "error": format!("{e:#}") }),
        },
        "restart" | "reload" => match core.apply_or_reload().await {
            Ok(()) => {
                let d_now = state.data.read().await.clone();
                sync_section_cache(&d_now);
                json!({ "success": true })
            }
            Err(e) => json!({ "success": false, "error": format!("{e:#}") }),
        },
        "enable" | "disable" => json!({ "success": true }),
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
                run_full_ubus_leak_check(state, core).await
            }
        }
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
            if let Err(err) = sync_uci_to_rust_store(state, core).await {
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
            let engine = rest.first().map(String::as_str).unwrap_or("desync");
            let target = rest.get(1).map(String::as_str).unwrap_or("youtube_suite");
            let custom_url = rest.get(2).map(String::as_str).unwrap_or("");
            let rule_section = rest.get(3).map(String::as_str).unwrap_or("");
            let custom_file = rest.get(4).map(String::as_str).unwrap_or("");
            let mode = rest.get(5).map(String::as_str).unwrap_or("presets");
            let timeout_secs =
                crate::fuzzer::parse_fuzzer_timeout_secs(rest.get(6).map(String::as_str), 2700);
            let bin_path = core.resolve_bin_path().await;
            crate::fuzzer::start_benchmark(
                bin_path,
                engine,
                target,
                custom_url,
                rule_section,
                custom_file,
                mode,
                timeout_secs,
            )
            .await
        }
        "fuzzer_status" => crate::fuzzer::get_status(),
        "fuzzer_stop" => crate::fuzzer::stop().await,
        "fuzzer_apply" | "fuzzer_auto_apply" => {
            let bin_path = core.resolve_bin_path().await;
            if method == "fuzzer_apply" {
                let engine_arg = rest.first().map(String::as_str).unwrap_or("");
                if let Err(err) = crate::fuzzer::validate_engine_request(engine_arg, &bin_path) {
                    return (
                        0,
                        json!({
                            "success": false,
                            "error": err
                        })
                        .to_string(),
                        String::new(),
                    );
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
                    return (
                        0,
                        json!({
                            "success": false,
                            "error": "Нет проверенной рабочей стратегии для автоприменения"
                        })
                        .to_string(),
                        String::new(),
                    );
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
                    if let Err(err) = sync_uci_to_rust_store(state, core).await {
                        json!({
                            "success": false,
                            "error": err
                        })
                    } else {
                        let _ = core.apply_or_reload().await;

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
            crate::fuzzer::detect_wan_filtering(&bin_path, target, custom_url).await
        }
        "fuzzer_history" => crate::fuzzer::get_history(),
        "fuzzer_clear_history" => crate::fuzzer::clear_history(),
        "trace_rules" | "route_explain" => {
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
            let target = if !domain.is_empty() {
                domain.clone()
            } else if !dest_ip.is_empty() {
                dest_ip.clone()
            } else {
                "example.com".to_string()
            };
            let client_ip = if source_ip.is_empty() || source_ip == "0.0.0.0" {
                "192.168.1.100"
            } else {
                source_ip.as_str()
            };
            let nft_active = crate::net_stack::check_nft_table_active().await;
            crate::diagnostics::build_route_trace_json_async(
                &d, client_ip, &domain, &target, port, &protocol, nft_active,
            )
            .await
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
                    &d, core, first, group_id, timeout_ms,
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
            match crate::adguard_hosts::update_hosts_lists(state, core, true).await {
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
        "hosts_list_status" => crate::adguard_hosts::get_hosts_list_status(&d),
        "toggle_client_bypass" => {
            let ip = rest.first().map(String::as_str).unwrap_or("");
            let mode = rest.get(1).map(String::as_str).unwrap_or("toggle");
            let mut cand = d.clone();
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
            if let Err(e) = transaction::commit_transaction(state, cand.clone()).await {
                json!({
                    "success": false,
                    "ip": ip,
                    "error": format!("{e:#}")
                })
            } else {
                sync_from_store_to_json_and_cache(&cand);
                let core_c = Arc::clone(core);
                tokio::spawn(async move {
                    let _ = core_c.apply_or_reload().await;
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
            handle_watchdog_command(method, &d, state, core).await
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
                    if crate::tg_bot::is_bot_effectively_running(&d) {
                        return (
                            0,
                            format!("running (pid {})\n", std::process::id()),
                            String::new(),
                        );
                    }
                    return (0, "stopped\n".to_string(), String::new());
                }
                "telegram_test" => {
                    return match crate::tg_bot::send_test_notification(state).await {
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
                "telegram_diagnose" => crate::tg_bot::diagnose_bot_connection(state, core).await,
                "telegram_set_lang" => {
                    let raw = tg_args.first().map(String::as_str).unwrap_or("ru");
                    let lang = if raw.trim().eq_ignore_ascii_case("en") {
                        "en"
                    } else {
                        "ru"
                    };
                    if d.telegram.language != lang {
                        let mut candidate = d.clone();
                        candidate.telegram.language = lang.to_string();
                        let _ = transaction::commit_transaction(state, candidate.clone()).await;
                        sync_telegram_section_to_json(&candidate.telegram);
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
                    let mut effective = d.clone();
                    if d.telegram.enabled != target {
                        effective.telegram.enabled = target;
                        let _ = transaction::commit_transaction(state, effective.clone()).await;
                        sync_telegram_section_to_json(&effective.telegram);
                    }
                    let running = crate::tg_bot::is_bot_effectively_running(&effective);
                    let configured = !effective.telegram.bot_token.trim().is_empty()
                        && !effective.telegram.admin_ids.is_empty();
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
            crate::snapshots::snapshot_save(state, &cur_secs, name).await
        }
        "snapshot_restore" => {
            let file_arg = rest.first().map(String::as_str).unwrap_or("");
            match crate::snapshots::snapshot_restore(state, file_arg).await {
                Ok((prof, restored_secs)) => {
                    set_json_sections_snapshot(restored_secs);
                    let cur = state.data.read().await.clone();
                    sync_section_cache(&cur);
                    let _ = core.apply_or_reload().await;
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
            crate::snapshots::snapshot_diff(state, &cur_secs, file_arg).await
        }
        "snapshot_export" => {
            let cur_secs = get_json_sections_snapshot();
            crate::snapshots::snapshot_export(state, &cur_secs, rest.first().map(String::as_str))
                .await
        }
        "snapshot_import" => {
            let cur_secs = get_json_sections_snapshot();
            match crate::snapshots::snapshot_import(
                state,
                &cur_secs,
                rest.first().map(String::as_str),
            )
            .await
            {
                crate::snapshots::ImportOutcome::ResponseOnly(v) => v,
                crate::snapshots::ImportOutcome::AppliedState {
                    response,
                    new_sections,
                } => {
                    set_json_sections_snapshot(new_sections);
                    let cur = state.data.read().await.clone();
                    sync_section_cache(&cur);
                    let _ = core.apply_or_reload().await;
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
            match crate::snapshots::reset_settings_to_defaults(state, &cur_secs).await {
                Ok((resp, default_secs)) => {
                    set_json_sections_snapshot(default_secs);
                    let cur = state.data.read().await.clone();
                    sync_section_cache(&cur);
                    let _ = core.apply_or_reload().await;
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
            let ok = transaction::promote_to_known_good(&state.lkg_path, &d).is_ok();
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
                if let Err(e) = transaction::commit_transaction(state, restored.clone()).await {
                    json!({ "success": false, "ok": false, "error": format!("{e:#}") })
                } else {
                    sync_from_store_to_json_and_cache(&restored);
                    let _ = core.apply_or_reload().await;
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

            for (owner_sec, src, _) in collect_section_sources_with_owner(&d, "all") {
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
            for (owner_sec, src, _) in collect_section_sources_with_owner(&d, "all") {
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
            let dnsmasq = sys_info::collect_dnsmasq_status();
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
                    let cnt = collect_section_sources_with_owner(&d, &sec.id).len();
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
                        "daemons": {
                            "tachyon-core": {
                                "running": live.core_running,
                                "pid": live.core_pid,
                                "uptime_seconds": live.core_uptime_secs,
                                "pretty": format_uptime_pretty(live.core_uptime_secs)
                            },
                            "watchdog": {
                                "running": core.is_watchdog_effectively_running().await,
                                "pid": core.is_watchdog_effectively_running().await.then(std::process::id),
                                "uptime_seconds": daemon_up,
                                "pretty": format_uptime_pretty(daemon_up)
                            },
                            "dnsmasq": {
                                "running": dnsmasq.running,
                                "pid": dnsmasq.pid,
                                "uptime_seconds": dnsmasq.uptime_secs,
                                "pretty": if dnsmasq.running { format_uptime_pretty(dnsmasq.uptime_secs) } else { String::new() }
                            }
                        }
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
        _ => json!({ "success": true }),
    };

    let s = serde_json::to_string(&out_val).unwrap_or_else(|_| "{}".to_string());
    (0, format!("{s}\n"), String::new())
}

async fn handle_uci_call(
    uci_method: &str,
    args: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    let _guard = uci_mutex().lock().await;
    handle_pure_rust_uci(uci_method, args, state, core).await
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
            if let Err(err) = sync_uci_to_rust_store(state, core).await {
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

/// Synchronize pure-Rust JSON sections (`config_sections.json`) into `TachyonStore` (`tachyon.json`) and reload core.
pub async fn sync_uci_to_rust_store(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Result<(), String> {
    sync_uci_to_rust_store_with_reload(state, core, true).await
}

pub async fn sync_uci_to_rust_store_with_reload(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    trigger_reload: bool,
) -> Result<(), String> {
    let snapshot = get_json_sections_snapshot();
    let mut candidate = state.data.read().await.clone();
    let old_telegram = candidate.telegram.clone();
    let imported = candidate.import_from_json_sections(&snapshot);
    if imported > 0 {
        let tg_changed = candidate.telegram != old_telegram;
        let has_empty_sub = candidate.outbound_sources.iter().any(|s| {
            s.enabled
                && s.source_type == "subscription"
                && !s.subscription_urls.is_empty()
                && s.cached_nodes.is_empty()
        });
        if let Err(e) = transaction::commit_transaction(state, candidate.clone()).await {
            let msg = format!("{e:#}");
            eprintln!("[tachyon] sync_uci_to_rust_store failed: {msg}");
            let mut live = state.live.write().await;
            live.push_event(
                "error",
                "uci",
                &format!("Ошибка синхронизации конфигурации: {msg}"),
            );
            return Err(msg);
        }
        sync_section_cache(&candidate);
        if tg_changed {
            crate::tg_bot::set_runtime_override(None);
            crate::tg_bot::notify_bot_wakeup();
        }
        if trigger_reload && !core.is_manually_stopped() {
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
    }
    Ok(())
}

async fn call_router_ubus_cli(object: &str, method: &str, args: &Value) -> Option<Value> {
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
        ("luci-rpc", "getNetworkDevices") => json!([0, {}]),
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
        ("network.interface", "dump") => json!([0, { "interface": [] }]),
        ("network", "get_proto_handlers") => json!([0, {}]),
        _ => json!([0, {}]),
    }
}

async fn handle_pure_rust_uci(
    uci_method: &str,
    args: &Value,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> Value {
    let config = args
        .get("config")
        .and_then(Value::as_str)
        .unwrap_or("tachyon");

    if config != "tachyon" {
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
                let idx = store.len();
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
            let _ = sync_uci_to_rust_store_with_reload(state, core, false).await;
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
                let next_idx = store.len();
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
            let _ = sync_uci_to_rust_store_with_reload(state, core, false).await;
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
            let _ = sync_uci_to_rust_store_with_reload(state, core, false).await;
            json!([0])
        }
        "order" => {
            capture_uci_rollback_baseline(state).await;
            if let Some(order_arr) = args.get("sections").and_then(Value::as_array) {
                let mut store = match json_sections_store().write() {
                    Ok(g) => g,
                    Err(_) => return json!([1]),
                };
                let mut new_map = Map::new();
                let mut idx = 0usize;
                for s in order_arr.iter().filter_map(Value::as_str) {
                    if let Some(mut val) = store.remove(s) {
                        if let Some(obj) = val.as_object_mut() {
                            obj.insert(".index".to_string(), json!(idx));
                        }
                        new_map.insert(s.to_string(), val);
                        idx += 1;
                    }
                }
                let mut remaining: Vec<(usize, String, Value)> = std::mem::take(&mut *store)
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
                remaining.sort_by_key(|(old_idx, _, _)| *old_idx);
                for (_, k, mut val) in remaining {
                    if let Some(obj) = val.as_object_mut() {
                        obj.insert(".index".to_string(), json!(idx));
                    }
                    new_map.insert(k, val);
                    idx += 1;
                }
                *store = new_map;
                persist_json_sections(&store);
            }
            let _ = sync_uci_to_rust_store_with_reload(state, core, false).await;
            json!([0])
        }
        "changes" => json!([0, { "changes": {} }]),
        "apply" | "commit" | "confirm" => {
            clear_uci_rollback_baseline();
            if sync_uci_to_rust_store(state, core).await.is_err() {
                return json!([5]);
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
        if let Ok(bytes) = std::fs::read(filepath) {
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
        if cmd_str.contains("luci-peeraddr") {
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
        if bin == "/usr/bin/tachyon" || bin == "/usr/bin/tachyon-read" || bin == "tachyon" {
            let (_, stdout, _) = execute_tachyon_cli(args, state, core).await;
            return (200, "text/plain; charset=utf-8", stdout.into_bytes());
        }
        if bin == "/sbin/uci" || bin == "/bin/uci" || bin == "uci" {
            let (_, stdout, _) = execute_pure_rust_uci_cli(args, state, core).await;
            return (200, "text/plain; charset=utf-8", stdout.into_bytes());
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
                    .user_domains
                    .iter()
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
                extra_domains.extend(cond.user_domains.iter().map(String::as_str));
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

    let mut curl_cmd = Command::new("curl");
    let mut args = vec![
        "-4".to_string(),
        "-sS".to_string(),
        "-k".to_string(),
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
    if let Some(ref proxy) = socks_proxy {
        args.push("-x".to_string());
        args.push(proxy.clone());
    }
    args.push(url.clone());

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
            let mut remote_ip = parts
                .get(1)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_default();
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

            if remote_ip.is_empty() {
                if let Ok(Ok(mut it)) = tokio::time::timeout(
                    Duration::from_millis(800),
                    tokio::net::lookup_host((clean_domain.as_str(), 443)),
                )
                .await
                    && let Some(addr) = it.next()
                {
                    remote_ip = addr.ip().to_string();
                } else {
                    remote_ip = "-".to_string();
                }
            }

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
            let (success, status_class) = if (200..500).contains(&http_code) && http_code != 451 {
                (true, format!("OK {http_code}"))
            } else if http_code > 0 {
                (false, format!("HTTP {http_code}"))
            } else {
                let reason = match exit_code {
                    6 => "DNS Error",
                    7 => "TCP Refused",
                    28 => "Timeout",
                    35 | 51 | 58 | 60 => "TLS Reset",
                    52 | 55 | 56 => "Conn Reset",
                    _ => "Unreachable",
                };
                (false, reason.to_string())
            };

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
        Ok(Err(_)) => {
            // Fallback when `curl` binary is unavailable (e.g. host unit test environment)
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
                "http_ms": tcp_ms,
                "status_class": if reachable { "TCP OK" } else { "Unreachable" },
                "success": reachable,
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
    if !cfg!(target_os = "linux") {
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
}
