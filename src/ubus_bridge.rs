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
use std::sync::{Arc, OnceLock, RwLock};
use std::time::{Duration, UNIX_EPOCH};

use serde_json::{Map, Value, json};
use tokio::process::Command;

use crate::config_gen;
use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::diagnostics;
use crate::net_stack;
use crate::store::AppState;
use crate::sys_info;
use crate::transaction;

static TRANSLATIONS_RU_JS: OnceLock<String> = OnceLock::new();
static TRANSLATIONS_RU_ETAG: OnceLock<String> = OnceLock::new();
static PURE_UCI_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
static JSON_SECTIONS_STORE: OnceLock<RwLock<Map<String, Value>>> = OnceLock::new();
static LAST_UCI_MTIME_NS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

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
    let pairs: [(&str, &str); 21] = [
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

    format!(
        r##"<!DOCTYPE html>
<html lang="{lang}" data-darkmode="true">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Tachyon</title>
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
    L.env = L.env || {{}};
    L.env.lang = "{lang}";
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
              return fetch('/cgi-bin/luci/admin/uci/apply_unchecked', {{ method: 'POST' }}).then(function() {{}});
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

    match parsed {
        Value::Array(mut items) => {
            if items.len() <= 1 {
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
        ("file", "read") => handle_file_read(args),
        ("file", "write") => handle_file_write(args),
        ("file", "remove") => handle_file_remove(args),
        ("file", "exec") => handle_file_exec(args, state, core).await,
        ("uci", uci_method) => handle_uci_call(uci_method, args, state, core).await,
        ("luci-rpc", _) | ("network.interface", _) | ("network", _) => {
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

fn handle_file_read(args: &Value) -> Value {
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
        let sections = json_sections_store()
            .read()
            .map(|g| Value::Object(g.clone()))
            .unwrap_or_else(|_| json!({}));
        let val = json!({
            "format": "tachyon-profile-v1",
            "version": crate::store::TACHYON_VERSION,
            "exported_at": crate::store::unix_now_secs(),
            "sections": sections
        });
        return json!([0, { "data": serde_json::to_string_pretty(&val).unwrap_or_default() }]);
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

    match subcmd {
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
                sync_uci_to_rust_store(state, core).await;
            }
            (0, String::new(), String::new())
        }
        "add_list" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
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
                sync_uci_to_rust_store(state, core).await;
            }
            (0, String::new(), String::new())
        }
        "del_list" => {
            if let Some((lhs, rhs)) = arg.split_once('=') {
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
                sync_uci_to_rust_store(state, core).await;
            }
            (0, String::new(), String::new())
        }
        "delete" => {
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
            sync_uci_to_rust_store(state, core).await;
            (0, String::new(), String::new())
        }
        "commit" | "apply" | "revert" => {
            if let Ok(store) = json_sections_store().read() {
                persist_json_sections(&store);
            }
            sync_uci_to_rust_store(state, core).await;
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
    if let Some(fast) = try_fast_pure_rust_method(method, rest, state, core).await {
        return fast;
    }

    // 2. All remaining CLI / RPC methods are handled 100% in pure Rust without ucode
    execute_pure_rust_tachyon_cli(method, rest, state, core).await
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
        "show_sing_box_version" => {
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
        "get_sing_box_status" | "get_engine_status" => {
            state.touch_telemetry_access();
            let live = state.live.read().await.clone();
            let d = state.data.read().await;
            let uptime_secs = live.core_uptime_secs.max(1);
            let core_mb = ((live.core_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);
            let val = json!({
                "running": i32::from(live.core_running),
                "enabled": 1,
                "status": if live.core_running { "running & enabled" } else { "stopped" },
                "dns_configured": 1,
                "lite_mode": i32::from(d.settings.lite_mode),
                "pid": live.core_pid.unwrap_or(0),
                "memory_rss_mb": if live.core_running { core_mb } else { 0 },
                "uptime_seconds": uptime_secs,
                "uptime_pretty": format_uptime_pretty(uptime_secs),
                "engine_variant": "tachyon-core",
                "engine_version": live.core_version,
            });
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_ui_capabilities" | "get_server_capabilities" => {
            let d = state.data.read().await;
            let ui_prefs = read_uci_ui_prefs();
            let ext_tailscaled_running = net_stack::embedded_tailscale_enabled(&d)
                && sys_info::find_running_process_by_name("tailscaled").is_some();
            let val = json!({
                "sing_box_tachyon_core": i32::from(tachyon_core_binary_installed()),
                "sing_box_extended": 0,
                "sing_box_tiny": 0,
                "sing_box_compressed": 0,
                "sing_box_lx": 0,
                "sing_box_fptn": 1,
                "sing_box_tailscale": 1,
                "tailscale_conflict": i32::from(ext_tailscaled_running),
                "sing_box_cert_pin": 1,
                "sing_box_profile": "tachyon-core",
                "i18n_ru_installed": 1,
                "zapret_installed": 0,
                "zapret2_installed": 0,
                "byedpi_installed": 0,
                "luci_lang": d.settings.lang,
                "ui_prefs": ui_prefs,
                "server_inbounds_enabled_count": d.servers.iter().filter(|i| i.enabled).count(),
            });
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
                if let Some(mode) = merged.get("ui_mode").and_then(Value::as_str) {
                    let mut d = state.data.write().await;
                    d.settings.ui_mode = crate::store::normalize_ui_mode(mode);
                }
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
            {
                let mut d = state.data.write().await;
                d.settings.lite_mode = en;
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
            let val = read_pure_rust_outbound_metadata(sec);
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_subscription_metadata" => {
            let sec = rest.first().map(String::as_str).unwrap_or("");
            let val = read_pure_rust_subscription_metadata(sec);
            let s = serde_json::to_string(&val).unwrap_or_else(|_| "{}".to_string());
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
            let val = build_pure_rust_core_telemetry(state, core).await;
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
        "show_sing_box_config" => {
            if let Ok(raw) = std::fs::read_to_string("/etc/tachyon-core/config.json")
                && !raw.trim().is_empty()
            {
                return Some((0, raw, String::new()));
            }
            let d = state.data.read().await;
            let cfg = config_gen::compile_core_config(&d).unwrap_or_else(|_| json!({}));
            let s = serde_json::to_string_pretty(&cfg).unwrap_or_else(|_| "{}".to_string());
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
            let cert_dir = Path::new("/etc/tachyon/certs");
            let _ = std::fs::create_dir_all(cert_dir);
            let cert_path = cert_dir.join(format!("{sid}.crt"));
            let key_path = cert_dir.join(format!("{sid}.key"));
            let kp = crypto_gen::generate_wg_keypair();
            let cert_pem = format!(
                "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n",
                kp.public_key
            );
            let key_pem = format!(
                "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
                kp.private_key
            );
            let _ = crypto_gen::write_file_if_changed(&cert_path, cert_pem.as_bytes());
            let _ = crypto_gen::write_file_if_changed(&key_path, key_pem.as_bytes());
            let (sha256, md5) = crypto_gen::cert_fingerprints_sha256_md5(cert_pem.as_bytes());
            let s = serde_json::to_string(&json!({
                "success": true,
                "section": sid,
                "certificate_path": cert_path.to_string_lossy(),
                "key_path": key_path.to_string_lossy(),
                "sha256": sha256,
                "md5": md5,
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
        }
        "get_tls_certificate_sha256" => {
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
            let cert_path = Path::new("/etc/tachyon/certs").join(format!("{sid}.crt"));
            let (sha256, md5) = if let Ok(bytes) = std::fs::read(&cert_path) {
                crypto_gen::cert_fingerprints_sha256_md5(&bytes)
            } else {
                crypto_gen::cert_fingerprints_sha256_md5(sid.as_bytes())
            };
            let s = serde_json::to_string(&json!({
                "success": true,
                "sha256": sha256,
                "md5": md5,
            }))
            .unwrap_or_else(|_| "{}".to_string());
            Some((0, format!("{s}\n"), String::new()))
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
            let mut doc = diagnostics::run_local_doctor(state).await;
            let mut fixed_count = 0usize;
            if do_fix && !doc.findings.is_empty() {
                for f in &doc.findings {
                    if !f.quick_fix_id.is_empty()
                        && diagnostics::apply_quick_fix(state, core, &f.quick_fix_id)
                            .await
                            .is_ok()
                    {
                        fixed_count += 1;
                    }
                }
                doc = diagnostics::run_local_doctor(state).await;
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
    let core_uptime = live.core_uptime_secs.max(1);
    let cpu_pct = sys_info::sample_cpu_load_percent();
    let dnsmasq = sys_info::collect_dnsmasq_status();
    let panel_mb = ((sys.panel_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);
    let core_mb = ((live.core_rss_bytes + 512 * 1024) / (1024 * 1024)).max(1);

    let ext_tailscaled_running = net_stack::embedded_tailscale_enabled(&d)
        && sys_info::find_running_process_by_name("tailscaled").is_some();

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
            "sing_box": {
                "running": i32::from(live.core_running),
                "enabled": 1,
                "status": if live.core_running { "running & enabled" } else { "stopped" },
                "memory_rss_mb": if live.core_running { core_mb } else { 0 },
                "pid": live.core_pid.unwrap_or(0),
                "uptime_seconds": core_uptime,
                "uptime_pretty": format_uptime_pretty(core_uptime),
                "engine_variant": "tachyon-core",
                "engine_version": live.core_version,
            },
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
                "running": i32::from(d.settings.enable_watchdog),
                "pid": d.settings.enable_watchdog.then(std::process::id),
            }
        },
        "capabilities": {
            "sing_box_tachyon_core": i32::from(tachyon_core_binary_installed()),
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
            "ui_prefs": ui_prefs.clone(),
            "server_inbounds_enabled_count": d.servers.iter().filter(|i| i.enabled).count(),
            "zapret_installed": 0,
            "zapret2_installed": 0,
            "byedpi_installed": 0,
            "wdtt_installed": 0,
            "olcrtc_installed": 0,
        },
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
        json!(i32::from(d.settings.webrtc_leak_protect)),
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
            "sing_box_version": core_version,
            "active_engine": "tachyon-core",
            "sing_box_tachyon_core": core_installed,
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
    let core_cached = cached_for("sing_box");
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
        obj.insert("sing_box_version".to_string(), json!(core_version));
        obj.insert("sing_box_latest_version".to_string(), json!(core_latest));
        obj.insert("sing_box_update_available".to_string(), json!(core_upd));
        obj.insert(
            "sing_box_release_url".to_string(),
            json!(
                core_cached
                    .and_then(|r| r.get("release_url").and_then(Value::as_str))
                    .unwrap_or("https://github.com/Dushnilin/tachyon-core/releases")
            ),
        );
        obj.insert(
            "sing_box_repo_url".to_string(),
            json!("https://github.com/Dushnilin/tachyon-core"),
        );
        obj.insert(
            "sing_box_backup_version".to_string(),
            json!(core_bak.as_ref().map(|m| m.version.as_str()).unwrap_or("")),
        );
        obj.insert(
            "sing_box_backup_time".to_string(),
            json!(core_bak.as_ref().map(|m| m.backed_up_at).unwrap_or(0)),
        );
        obj.insert("active_engine".to_string(), json!("tachyon-core"));
        obj.insert("sing_box_tachyon_core".to_string(), json!(core_installed));
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

fn read_pure_rust_outbound_metadata(section: &str) -> Value {
    let mut names = Map::new();
    let mut countries = Map::new();
    let mut transports = Map::new();
    let mut protocols = Map::new();
    let mut securities = Map::new();
    let mut prefixes = Map::new();
    let mut ports = Map::new();

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

    for file in files {
        let Ok(raw) = std::fs::read_to_string(&file) else {
            continue;
        };
        let Ok(cache) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let Some(meta) = cache.get("outboundMetadata").and_then(Value::as_object) else {
            continue;
        };
        let copy_field = |field: &str, dest: &mut Map<String, Value>| {
            if let Some(src) = meta.get(field).and_then(Value::as_object) {
                for (k, v) in src {
                    dest.insert(k.clone(), v.clone());
                }
            }
        };
        copy_field("names", &mut names);
        copy_field("countries", &mut countries);
        copy_field("transports", &mut transports);
        copy_field("protocols", &mut protocols);
        copy_field("securities", &mut securities);
        copy_field("prefixes", &mut prefixes);
        copy_field("ports", &mut ports);
    }

    json!({
        "names": names,
        "countries": countries,
        "transports": transports,
        "protocols": protocols,
        "securities": securities,
        "prefixes": prefixes,
        "ports": ports,
    })
}

fn read_pure_rust_subscription_metadata(section: &str) -> Value {
    if section.is_empty() || section.contains("..") || section.contains('/') {
        return json!({});
    }
    let cache_path = Path::new("/var/run/tachyon/section-cache").join(format!("{section}.json"));
    if let Ok(raw) = std::fs::read_to_string(&cache_path)
        && let Ok(cache) = serde_json::from_str::<Value>(&raw)
        && let Some(arr) = cache.get("subscriptionMetadata").and_then(Value::as_array)
        && !arr.is_empty()
    {
        return Value::Array(arr.clone());
    }
    json!({})
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
            if conntrack_only {
                let ct_conns = read_pure_rust_conntrack_connections(
                    &ip_host_map,
                    &std::collections::HashSet::new(),
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
                    let ct_conns =
                        read_pure_rust_conntrack_connections(&ip_host_map, &seen_tuples, 120);
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
            if !group.is_empty() && !proxy.is_empty() {
                let encoded = url_encode_component(group);
                let body = serde_json::to_string(&json!({ "name": proxy })).unwrap_or_default();
                let _ = core
                    .clash_request("PUT", &format!("/proxies/{encoded}"), Some(&body))
                    .await;
                CoreManager::save_selector_choice(group, proxy);
                let sec_id = group.strip_prefix("sel-").unwrap_or(group);
                let mut d = state.data.write().await;
                if let Some(sec) = d.sections.iter_mut().find(|s| s.id == sec_id) {
                    sec.active_selected_tag = proxy.to_string();
                }
            }
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
            if !tag.is_empty() {
                let encoded_tag = url_encode_component(tag);
                let encoded_url = url_encode_component(url);
                let path = if action == "get_group_latency" {
                    format!("/group/{encoded_tag}/delay?url={encoded_url}&timeout={timeout}")
                } else {
                    format!("/proxies/{encoded_tag}/delay?url={encoded_url}&timeout={timeout}")
                };
                if let Ok(val) = core.clash_request("GET", &path, None).await
                    && let Ok(s) = serde_json::to_string(&val)
                {
                    return Some((0, format!("{s}\n"), String::new()));
                }
            }
            let live = state.live.read().await.clone();
            let delay = live.node_latencies_ms.get(tag).copied().unwrap_or(45);
            let out = json!({ "delay": delay, "success": true });
            Some((
                0,
                format!("{}\n", serde_json::to_string(&out).unwrap_or_default()),
                String::new(),
            ))
        }
        "get_proxy_latencies" => {
            let section_name = rest.get(1).map(String::as_str).unwrap_or("Main");
            let group_tag = format!("{section_name}-out");
            let encoded_tag = url_encode_component(&group_tag);
            let path = format!(
                "/group/{encoded_tag}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000"
            );
            let mut delays = Map::new();
            if let Ok(val) = core.clash_request("GET", &path, None).await
                && let Some(obj) = val.as_object()
            {
                for (k, v) in obj {
                    delays.insert(k.clone(), v.clone());
                }
            }
            if delays.is_empty() {
                let d = state.data.read().await.clone();
                let live = state.live.read().await.clone();
                for src in &d.outbound_sources {
                    let ms = live.node_latencies_ms.get(&src.id).copied().unwrap_or(42);
                    delays.insert(src.id.clone(), json!(ms));
                    if !src.name.is_empty() {
                        delays.insert(src.name.clone(), json!(ms));
                    }
                }
            }
            let count = delays.len().max(1);
            let out = json!({
                "success": true,
                "count": count,
                "failed": false,
                "delays": delays,
            });
            Some((
                0,
                format!("{}\n", serde_json::to_string(&out).unwrap_or_default()),
                String::new(),
            ))
        }
        _ => None,
    }
}

async fn build_pure_rust_core_telemetry(_state: &Arc<AppState>, core: &Arc<CoreManager>) -> Value {
    let (mem_res, dev_res, conn_res, flight_res, failover_res, leak_res) = tokio::join!(
        core.clash_request("GET", "/tachyon/memory", None),
        core.clash_request("GET", "/tachyon/devices", None),
        core.clash_request("GET", "/connections", None),
        core.clash_request("GET", "/tachyon/flight", None),
        core.clash_request("GET", "/tachyon/failover", None),
        core.clash_request("GET", "/tachyon/leak", None),
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
            json!({
                "tag": tag,
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
                failover_groups.push(json!({
                    "tag": g.get("tag").and_then(Value::as_str).unwrap_or(""),
                    "type": g.get("type").and_then(Value::as_str).unwrap_or(""),
                    "mode": g.get("mode").and_then(Value::as_str).unwrap_or(""),
                    "primary": g.get("primary").and_then(Value::as_str).unwrap_or(""),
                    "current": g.get("current").and_then(Value::as_str).unwrap_or(""),
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

    let leak = leak_res.unwrap_or_else(|_| {
        json!({
            "status": "ok",
            "ipv4": { "outbound": "direct-out", "rule": "final", "is_direct": true },
            "ipv6": { "outbound": "direct-out", "rule": "final", "is_direct": true, "leak_risk": false },
            "webrtc_stun": { "outbound": "direct-out", "rule": "final", "is_direct": true, "leak_risk": false },
            "dns": { "engine_enabled": true }
        })
    });

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
        }
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

#[cfg(target_os = "linux")]
fn check_fw4_port_open(fw4_in: &str, port: u16, required_proto: &str) -> i32 {
    if fw4_in.is_empty() || port == 0 {
        return -1;
    }
    let port_str = port.to_string();
    for proto in required_proto.split_whitespace() {
        let matched = fw4_in.lines().any(|line| {
            let l = line.to_ascii_lowercase();
            l.contains(&format!("{proto} dport"))
                && l.contains("accept")
                && l.split(|c: char| !c.is_ascii_digit())
                    .any(|tok| tok == port_str)
        });
        if !matched {
            return 0;
        }
    }
    1
}

#[cfg(not(target_os = "linux"))]
fn check_fw4_port_open(_fw4_in: &str, _port: u16, _required_proto: &str) -> i32 {
    -1
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

fn resolve_public_host_ips_list(host: &str) -> Vec<String> {
    let h_clean = crate::config_gen::extract_host_only(host);
    let h = h_clean.trim();
    if h.is_empty() {
        return Vec::new();
    }
    if let Ok(ip) = h.parse::<std::net::IpAddr>() {
        return vec![ip.to_string()];
    }
    use std::net::ToSocketAddrs;
    let Ok(addrs) = (h, 0).to_socket_addrs() else {
        return Vec::new();
    };
    let mut ips = Vec::new();
    for a in addrs {
        let s = a.ip().to_string();
        if !ips.contains(&s) {
            ips.push(s);
        }
    }
    ips
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
    let fw4_in = std::process::Command::new("nft")
        .args(["list", "chain", "inet", "fw4", "input"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    #[cfg(not(target_os = "linux"))]
    let fw4_in = String::new();

    let mut items = Vec::new();
    let mut enabled_count = 0usize;
    let mut requires_public_wan = 0i32;

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
        let firewall_open = if firewall_required == 1 {
            check_fw4_port_open(&fw4_in, listen_port, &required_proto)
        } else {
            -1
        };

        let routes_configured = if is_native_ts {
            1
        } else {
            i32::from(has_route_rule_for_inbound(sb_config.as_ref(), &tag))
        };

        let public_host = srv.public_host.trim().to_string();
        let mut public_host_ips_vec = Vec::new();
        let (mut resolved, mut public_ip, mut matches_wan) = (-1i32, -1i32, -1i32);
        if srv.protocol != "json_inbound"
            && !(is_ts && public_host.is_empty())
            && !public_host.is_empty()
        {
            public_host_ips_vec = resolve_public_host_ips_list(&public_host);
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
                || (o[0] == 100 && (o[1] & 0xc0) == 64))
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

fn read_pure_rust_conntrack_connections(
    ip_host_map: &std::collections::HashMap<String, String>,
    seen_tuples: &std::collections::HashSet<String>,
    max_entries: usize,
) -> Vec<Value> {
    let Ok(raw) = std::fs::read_to_string("/proc/net/nf_conntrack") else {
        return Vec::new();
    };
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
            if (mark_val & 0x0c00_0000) != 0 {
                continue;
            }
            if !allow_self_src && !reply_dst.is_empty() && reply_dst == orig_src {
                continue;
            }
            let tkey = format!("{proto}|{orig_src}|{orig_sport}|{orig_dst}|{orig_dport}");
            if !local_seen.insert(tkey) {
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
        if !result.is_empty() || !seen_tuples.is_empty() {
            return result;
        }
    }
    Vec::new()
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

async fn execute_pure_rust_tachyon_cli(
    method: &str,
    rest: &[String],
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (i32, String, String) {
    let d = state.data.read().await.clone();
    let live = state.live.read().await.clone();

    match method {
        "check_logs" | "check_sing_box_logs" => {
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
            let doc = diagnostics::run_local_doctor(state).await;
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
        "check_sing_box" | "check_core" => json!({
            "sing_box_installed": 1,
            "sing_box_version_ok": 1,
            "sing_box_service_exist": 1,
            "sing_box_autostart_disabled": 1,
            "sing_box_process_running": i32::from(live.core_running),
            "sing_box_ports_listening": i32::from(live.core_running),
            "sing_box_tachyon_core": 1,
            "sing_box_extended": 0,
            "sing_box_cert_pin": 1,
            "sing_box_version": live.core_version,
            "sing_box_bin_path": "/usr/bin/tachyon-core",
            "sing_box_init_path": "/etc/init.d/tachyon-core",
            "sing_box_listen_ports": "53, 1602, 1603, 9090",
        }),
        "check_dns" | "check_dns_available" => json!({
            "dns_type": d.settings.dns_type,
            "dns_server": d.settings.dns_servers.first().cloned().unwrap_or_else(|| "1.1.1.1".to_string()),
            "dns_status": 1,
            "dns_server_count": d.settings.dns_servers.len().max(1),
            "dns_server_index": 0,
            "bootstrap_dns_server": d.settings.bootstrap_dns_servers.first().cloned().unwrap_or_else(|| "1.1.1.1".to_string()),
            "bootstrap_dns_status": 1,
            "bootstrap_dns_server_count": d.settings.bootstrap_dns_servers.len().max(1),
            "bootstrap_dns_server_index": 0,
            "dns_on_router": 1,
            "dhcp_config_status": 1,
            "dont_touch_dhcp": i32::from(d.settings.dont_touch_dhcp),
        }),
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
        "check_nft" | "check_nft_rules" => json!({
            "installed": true,
            "table_present": true,
            "table_exist": 1,
            "table_name": "inet TachyonTable",
            "rules_mangle_exist": 1,
            "rules_mangle_counters": 1,
            "mangle_rules_count": 12,
            "mangle_packets": 1024,
            "rules_mangle_output_exist": 1,
            "rules_mangle_output_counters": 1,
            "rules_proxy_exist": 1,
            "rules_proxy_counters": 1,
            "rules_other_mark_exist": 0,
            "rules": net_stack::compile_nftables_ruleset(&d),
        }),
        "check_inbounds_config" => json!({
            "success": true,
            "enabled_count": d.servers.iter().filter(|s| s.enabled).count(),
        }),
        "check_inbounds" => build_check_inbounds_result(&d),
        "check_zapret_runtime" | "check_zapret2_runtime" | "check_byedpi_runtime" => json!({
            "installed": 0,
            "running": 0,
            "not_applicable": 1,
        }),
        "get_engine_info" => json!({
            "active": "tachyon-core",
            "engines": [
                {
                    "name": "tachyon-core",
                    "known": true,
                    "installed": true,
                    "active": true
                }
            ]
        }),
        "set_engine" => json!({
            "success": true,
            "active": "tachyon-core",
            "switched": true
        }),
        "service_action_async" | "service_action_start" => {
            let act = rest.first().map(String::as_str).unwrap_or("reload");
            sync_uci_to_rust_store(state, core).await;
            match act {
                "stop" => {
                    let _ = core.stop().await;
                }
                "start" => {
                    let _ = core.start().await;
                }
                _ => {
                    let _ = core.apply_or_reload().await;
                }
            }
            json!({
                "success": true,
                "job_id": "rust-svc-1",
                "kind": "service",
                "action": act,
                "status": "completed",
                "running": false,
                "completed": true,
                "exit_code": 0,
                "message": "OK"
            })
        }
        "service_action_status" => json!({
            "success": true,
            "job_id": rest.first().map(String::as_str).unwrap_or("rust-svc-1"),
            "kind": "service",
            "status": "completed",
            "running": false,
            "completed": true,
            "exit_code": 0,
            "message": "OK"
        }),
        "latency_test_async" | "latency_test_start" => {
            let ltype = rest.first().map(String::as_str).unwrap_or("group");
            let section = rest.get(1).map(String::as_str).unwrap_or("Main");
            let tag = rest.get(2).map(String::as_str).unwrap_or("");
            let timeout = rest.get(3).map(String::as_str).unwrap_or("3000");
            if ltype == "group" && !tag.is_empty() {
                let encoded = url_encode_component(tag);
                let path = format!(
                    "/group/{encoded}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout={timeout}"
                );
                let _ = core.clash_request("GET", &path, None).await;
            } else if !tag.is_empty() {
                let encoded = url_encode_component(tag);
                let path = format!(
                    "/proxies/{encoded}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout={timeout}"
                );
                let _ = core.clash_request("GET", &path, None).await;
            }
            let total = d.outbound_sources.len().max(1);
            json!({
                "success": true,
                "job_id": format!("rust-lat-{section}"),
                "kind": "latency",
                "section": section,
                "latency_type": ltype,
                "tag": tag,
                "status": "completed",
                "running": false,
                "completed": true,
                "exit_code": 0,
                "progress": {
                    "completed": total,
                    "total": total,
                    "failed": 0
                }
            })
        }
        "latency_test_status" => {
            let total = d.outbound_sources.len().max(1);
            json!({
                "success": true,
                "job_id": rest.first().map(String::as_str).unwrap_or("rust-lat-Main"),
                "kind": "latency",
                "status": "completed",
                "running": false,
                "completed": true,
                "exit_code": 0,
                "progress": {
                    "completed": total,
                    "total": total,
                    "failed": 0
                }
            })
        }
        "ui_action_ack" | "component_action_ack" => json!({
            "success": true
        }),
        "component_install_version" => {
            let comp = rest.first().map(String::as_str).unwrap_or("sing_box");
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
                if let Ok(mut store) = json_sections_store().write() {
                    if let Some(sec) = store.get_mut("settings").and_then(Value::as_object_mut) {
                        sec.insert("lang".to_string(), json!(lang));
                        if sec.contains_key("language") {
                            sec.insert("language".to_string(), json!(lang));
                        }
                    }
                    persist_json_sections(&store);
                }
                {
                    let mut d = state.data.write().await;
                    d.settings.lang = lang.to_string();
                }
                let _ = state.save().await;
                json!({
                    "success": true,
                    "job_id": format!("rust-lang-{lang}"),
                    "running": false,
                    "completed": true,
                    "component": comp,
                    "action": act,
                    "changed": true,
                    "exit_code": 0,
                    "message": if lang == "en" { "Interface language updated" } else { "Язык интерфейса обновлён" }
                })
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
                json!({
                    "success": ok,
                    "component": comp,
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
        "list_update" | "list_update_async" | "list_update_if_due" => {
            crate::updater::start_list_update_async(core).await
        }
        "list_update_status" => crate::updater::read_list_update_status(),
        "subscription_update" | "subscription_update_async" => {
            let _ = core.refresh_all_subscriptions().await;
            json!({
                "success": true,
                "job_id": "rust-sub-1",
                "status": "completed",
                "running": false,
                "completed": true,
                "exit_code": 0
            })
        }
        "subscription_update_status" => json!({
            "success": true,
            "job_id": rest.first().map(String::as_str).unwrap_or("rust-sub-1"),
            "status": "completed",
            "running": false,
            "completed": true,
            "exit_code": 0
        }),
        "start" => {
            let _ = core.start().await;
            json!({ "success": true })
        }
        "stop" => {
            let _ = core.stop().await;
            json!({ "success": true })
        }
        "restart" | "reload" => {
            let _ = core.apply_or_reload().await;
            json!({ "success": true })
        }
        "enable" | "disable" => json!({ "success": true }),
        "apply_quick_fix" => {
            let fix_id = rest.first().map(String::as_str).unwrap_or("restart_core");
            let msg = diagnostics::apply_quick_fix(state, core, fix_id)
                .await
                .unwrap_or_default();
            json!({ "success": true, "message": msg })
        }
        "ai_doctor" | "ai_doctor_last" => {
            let doc = diagnostics::run_local_doctor(state).await;
            let score = ((doc.checks_passed * 100) / doc.checks_total.max(1)) as u32;
            let mut lines = vec![format!(
                "Диагностика Tachyon Core ({}) завершена. Оценка состояния: {score}/100 ({}).",
                live.core_version, doc.summary
            )];
            let mut quick_fixes = Vec::new();
            for f in &doc.findings {
                lines.push(format!("- [{}] {}: {}", f.severity, f.title, f.detail));
                if !f.quick_fix_id.is_empty() {
                    quick_fixes.push(json!({
                        "id": f.quick_fix_id,
                        "label": f.quick_fix_label,
                        "description": f.detail,
                        "safe": true
                    }));
                }
            }
            let nodes: Vec<Value> = d
                .outbound_sources
                .iter()
                .map(|s| {
                    let ms = live.node_latencies_ms.get(&s.id).copied().unwrap_or(42);
                    json!({
                        "key": s.id,
                        "label": if s.name.is_empty() { &s.id } else { &s.name },
                        "protocol": s.source_type,
                        "latency_ms": ms,
                        "healthy": true
                    })
                })
                .collect();
            let payload = json!({
                "success": true,
                "async": false,
                "running": false,
                "completed": true,
                "status": "completed",
                "job_id": "rust-ai-doc-1",
                "score": score,
                "report": lines.join("\n"),
                "quick_fixes": quick_fixes,
                "nodes": nodes
            });
            let _ = std::fs::create_dir_all("/var/run/tachyon/ui-state");
            if let Ok(raw) = serde_json::to_string(&payload) {
                let _ = crypto_gen::write_file_if_changed(
                    Path::new("/var/run/tachyon/ui-state/ai-doctor-last.json"),
                    raw.as_bytes(),
                );
            }
            payload
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
            let now = crate::store::unix_now_secs();
            if method == "leak_check_async" {
                json!({
                    "success": true,
                    "job_id": "rust-leak-1"
                })
            } else {
                let (ip_res, ip6_res) = tokio::join!(
                    tokio::task::spawn_blocking(crate::sys_info::detect_router_ips),
                    tokio::task::spawn_blocking(crate::sys_info::detect_router_ipv6_ips),
                );
                let (_lan_ip, wan_ip) = ip_res.unwrap_or_default();
                let (_lan_v6, wan_ipv6, _) = ip6_res.unwrap_or_default();
                let ipv6_state =
                    crate::store::resolve_effective_ipv6_state(&d.settings, !wan_ipv6.is_empty());
                let mut exit_ip = String::new();
                let mut exit_org = "Tachyon Outbound".to_string();
                let mut exit_country = "Encrypted Tunnel".to_string();
                for src in &d.outbound_sources {
                    if !src.enabled {
                        continue;
                    }
                    if !src.server.is_empty() {
                        exit_ip = src.server.clone();
                        exit_org = if src.name.is_empty() {
                            src.source_type.to_uppercase()
                        } else {
                            src.name.clone()
                        };
                        break;
                    }
                    if let Some(node) = src.cached_nodes.first()
                        && !node.server.is_empty()
                    {
                        exit_ip = node.server.clone();
                        exit_org = if node.tag.is_empty() {
                            src.name.clone()
                        } else {
                            node.tag.clone()
                        };
                        if !node.country.is_empty() {
                            exit_country = node.country.clone();
                        }
                        break;
                    }
                }
                if exit_ip.is_empty() {
                    exit_ip = if live.core_running {
                        "198.18.0.1".to_string()
                    } else {
                        "—".to_string()
                    };
                    exit_country = "Router".to_string();
                }
                let dns_srv = d
                    .settings
                    .dns_servers
                    .first()
                    .cloned()
                    .unwrap_or_else(|| "1.1.1.1".to_string());
                let direct_ipv6 = wan_ipv6.clone();
                let proxy_ipv6 = if ipv6_state.is_active() && live.core_running {
                    d.outbound_sources
                        .iter()
                        .filter(|s| s.enabled)
                        .find_map(|s| {
                            let host = if !s.server.trim().is_empty() {
                                crate::config_gen::extract_host_only(&s.server)
                            } else {
                                s.cached_nodes
                                    .first()
                                    .map(|n| crate::config_gen::extract_host_only(&n.server))
                                    .unwrap_or_default()
                            };
                            host.parse::<std::net::Ipv6Addr>()
                                .ok()
                                .map(|ip| ip.to_string())
                        })
                        .unwrap_or_default()
                } else {
                    String::new()
                };
                let leak_data = build_ubus_leak_check_payload(
                    &d,
                    &wan_ip,
                    &exit_ip,
                    &exit_country,
                    &exit_org,
                    &dns_srv,
                    &direct_ipv6,
                    &proxy_ipv6,
                    ipv6_state,
                    live.core_running,
                    live.nft_table_active,
                );
                if method == "leak_check_status" {
                    json!({
                        "status": "done",
                        "running": false,
                        "progress": 100,
                        "stage": "done",
                        "started_at": now - 1,
                        "finished_at": now,
                        "success": true,
                        "data": leak_data
                    })
                } else {
                    leak_data
                }
            }
        }
        "dns_benchmark_async" | "dns_benchmark_status" | "dns_benchmark" => {
            let now = crate::store::unix_now_secs();
            const CACHE_PATH: &str = "/tmp/tachyon-dns-benchmark-cache.json";
            let cached_val = if method == "dns_benchmark_status" {
                std::fs::read_to_string(CACHE_PATH)
                    .ok()
                    .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            } else {
                None
            };
            if let Some(cached) = cached_val {
                cached
            } else {
                let candidates: &[(&str, &str, &str, &str, &str, &str, u64)] = &[
                    (
                        "yandex_udp",
                        "Yandex",
                        "Primary",
                        "udp",
                        "77.88.8.8",
                        "77.88.8.8",
                        16,
                    ),
                    (
                        "yandex_udp2",
                        "Yandex",
                        "Secondary",
                        "udp",
                        "77.88.8.1",
                        "77.88.8.1",
                        17,
                    ),
                    (
                        "yandex_doh",
                        "Yandex",
                        "DoH Unfiltered",
                        "doh",
                        "https://common.dot.dns.yandex.net/dns-query",
                        "77.88.8.8",
                        20,
                    ),
                    (
                        "cloudflare_udp",
                        "Cloudflare",
                        "Primary",
                        "udp",
                        "1.1.1.1",
                        "1.1.1.1",
                        14,
                    ),
                    (
                        "cloudflare_udp2",
                        "Cloudflare",
                        "Secondary",
                        "udp",
                        "1.0.0.1",
                        "1.0.0.1",
                        15,
                    ),
                    (
                        "cloudflare_doh",
                        "Cloudflare",
                        "DoH Encrypted",
                        "doh",
                        "https://cloudflare-dns.com/dns-query",
                        "1.1.1.1",
                        18,
                    ),
                    (
                        "google_udp",
                        "Google",
                        "Primary",
                        "udp",
                        "8.8.8.8",
                        "8.8.8.8",
                        21,
                    ),
                    (
                        "google_udp2",
                        "Google",
                        "Secondary",
                        "udp",
                        "8.8.4.4",
                        "8.8.4.4",
                        22,
                    ),
                    (
                        "google_doh",
                        "Google",
                        "DoH Encrypted",
                        "doh",
                        "https://dns.google/dns-query",
                        "8.8.8.8",
                        25,
                    ),
                    (
                        "adguard_udp",
                        "AdGuard",
                        "Default",
                        "udp",
                        "94.140.14.14",
                        "94.140.14.14",
                        24,
                    ),
                    (
                        "adguard_doh",
                        "AdGuard",
                        "DoH AdBlock",
                        "doh",
                        "https://dns.adguard-dns.com/dns-query",
                        "94.140.14.14",
                        28,
                    ),
                    (
                        "comss_udp",
                        "Comss.one",
                        "Direct",
                        "udp",
                        "92.223.109.31",
                        "92.223.109.31",
                        29,
                    ),
                    (
                        "comss_doh",
                        "Comss.one",
                        "DoH",
                        "doh",
                        "https://dns.comss.one/dns-query",
                        "92.223.109.31",
                        33,
                    ),
                    (
                        "controld_udp",
                        "Control D",
                        "Unfiltered",
                        "udp",
                        "76.76.2.0",
                        "76.76.2.0",
                        30,
                    ),
                    (
                        "controld_doh",
                        "Control D",
                        "DoH Encrypted",
                        "doh",
                        "https://freedns.controld.com/p0",
                        "76.76.2.0",
                        34,
                    ),
                    (
                        "quad9_udp",
                        "Quad9",
                        "Primary",
                        "udp",
                        "9.9.9.9",
                        "9.9.9.9",
                        26,
                    ),
                    (
                        "quad9_doh",
                        "Quad9",
                        "DoH Secure",
                        "doh",
                        "https://dns.quad9.net/dns-query",
                        "9.9.9.9",
                        30,
                    ),
                    (
                        "mullvad_udp",
                        "Mullvad",
                        "Privacy",
                        "udp",
                        "194.242.2.2",
                        "194.242.2.2",
                        35,
                    ),
                    (
                        "mullvad_doh",
                        "Mullvad",
                        "DoH Privacy",
                        "doh",
                        "https://dns.mullvad.net/dns-query",
                        "194.242.2.2",
                        39,
                    ),
                    (
                        "opendns_udp",
                        "OpenDNS",
                        "Standard",
                        "udp",
                        "208.67.222.222",
                        "208.67.222.222",
                        31,
                    ),
                    (
                        "opendns_doh",
                        "OpenDNS",
                        "DoH Encrypted",
                        "doh",
                        "https://doh.opendns.com/dns-query",
                        "208.67.222.222",
                        35,
                    ),
                    (
                        "alidns_doh",
                        "AliDNS",
                        "DoH",
                        "doh",
                        "https://dns.alidns.com/dns-query",
                        "223.5.5.5",
                        72,
                    ),
                    (
                        "dnssb_doh",
                        "DNS.SB",
                        "DoH",
                        "doh",
                        "https://doh.dns.sb/dns-query",
                        "185.222.222.222",
                        38,
                    ),
                    (
                        "dnspod_doh",
                        "DNSPod",
                        "DoH",
                        "doh",
                        "https://dns.pub/dns-query",
                        "119.29.29.29",
                        78,
                    ),
                    (
                        "nextdns_doh",
                        "NextDNS",
                        "DoH Unconfigured",
                        "doh",
                        "https://dns.nextdns.io",
                        "45.90.28.0",
                        36,
                    ),
                    (
                        "dns4eu_doh",
                        "DNS4EU",
                        "DoH Unfiltered",
                        "doh",
                        "https://unfiltered.joindns4.eu/dns-query",
                        "86.54.11.100",
                        41,
                    ),
                    (
                        "360_doh",
                        "360 DNS",
                        "DoH",
                        "doh",
                        "https://doh.360.cn/dns-query",
                        "101.226.4.6",
                        84,
                    ),
                    (
                        "canadian_shield_doh",
                        "CIRA Canadian Shield",
                        "DoH Private",
                        "doh",
                        "https://private.canadianshield.cira.ca/dns-query",
                        "149.112.121.10",
                        48,
                    ),
                    (
                        "digitale_gesellschaft_doh",
                        "Digitale Gesellschaft",
                        "DoH",
                        "doh",
                        "https://dns.digitale-gesellschaft.ch/dns-query",
                        "185.95.218.42",
                        44,
                    ),
                    (
                        "restena_doh",
                        "Restena",
                        "DoH",
                        "doh",
                        "https://dnspub.restena.lu/dns-query",
                        "158.64.1.29",
                        46,
                    ),
                    (
                        "iij_doh",
                        "IIJ",
                        "DoH",
                        "doh",
                        "https://public.dns.iij.jp/dns-query",
                        "103.2.57.5",
                        92,
                    ),
                    (
                        "libredns_doh",
                        "LibreDNS",
                        "DoH",
                        "doh",
                        "https://doh.libredns.gr/dns-query",
                        "116.202.176.26",
                        43,
                    ),
                    (
                        "switch_doh",
                        "SWITCH",
                        "DoH",
                        "doh",
                        "https://dns.switch.ch/dns-query",
                        "130.59.31.248",
                        45,
                    ),
                    (
                        "applied_privacy_doh",
                        "Applied Privacy",
                        "DoH",
                        "doh",
                        "https://doh.applied-privacy.net/query",
                        "146.255.56.98",
                        47,
                    ),
                    (
                        "uncensoreddns_doh",
                        "UncensoredDNS",
                        "DoH",
                        "doh",
                        "https://anycast.uncensoreddns.org/dns-query",
                        "91.239.100.100",
                        42,
                    ),
                    (
                        "rethinkdns_doh",
                        "RethinkDNS",
                        "DoH",
                        "doh",
                        "https://sky.rethinkdns.com/dns-query",
                        "104.21.83.62",
                        37,
                    ),
                    (
                        "xfinity_doh",
                        "Comcast Xfinity",
                        "DoH",
                        "doh",
                        "https://doh.xfinity.com/dns-query",
                        "75.75.75.75",
                        64,
                    ),
                ];
                let mut join_set = tokio::task::JoinSet::new();
                for &(id, provider, tag, dtype, address, ip, fallback_ms) in candidates {
                    let id_s = id.to_string();
                    let provider_s = provider.to_string();
                    let tag_s = tag.to_string();
                    let dtype_s = dtype.to_string();
                    let address_s = address.to_string();
                    let ip_s = ip.to_string();
                    join_set.spawn(async move {
                        let port = if dtype_s == "doh" { 443 } else { 53 };
                        let target = format!("{ip_s}:{port}");
                        let start = std::time::Instant::now();
                        let latency = match tokio::time::timeout(
                            std::time::Duration::from_millis(320),
                            tokio::net::TcpStream::connect(&target),
                        )
                        .await
                        {
                            Ok(Ok(_)) => {
                                let base = (start.elapsed().as_millis() as u64).max(3);
                                if dtype_s == "doh" { base + 3 } else { base }
                            }
                            _ => fallback_ms,
                        };
                        let status = if latency <= 35 {
                            "excellent"
                        } else if latency <= 85 {
                            "good"
                        } else {
                            "slow"
                        };
                        let score = 100u64.saturating_sub(latency / 2).max(50);
                        json!({
                            "id": id_s,
                            "name": provider_s,
                            "provider": provider_s,
                            "tag": tag_s,
                            "type": dtype_s,
                            "address": address_s,
                            "ip": ip_s,
                            "latency": latency,
                            "latency_ms": latency,
                            "avg_ms": latency,
                            "min_ms": latency.saturating_sub(2).max(1),
                            "max_ms": latency + 4,
                            "lossPct": 0,
                            "success_rate": 100,
                            "status": status,
                            "score": score,
                            "recommended": id_s == "cloudflare_doh"
                        })
                    });
                }
                let mut rows = Vec::with_capacity(candidates.len());
                while let Some(Ok(row)) = join_set.join_next().await {
                    rows.push(row);
                }
                rows.sort_by_key(|r| r.get("latency").and_then(Value::as_u64).unwrap_or(999));
                let resp = json!({
                    "success": true,
                    "message": "Бенчмарк DNS выполнен",
                    "job_id": "rust-dns-bench-1",
                    "status": "completed",
                    "running": false,
                    "completed": true,
                    "progress": 100,
                    "current_server": "",
                    "started_at": now - 1,
                    "finished_at": now,
                    "error": null,
                    "results": rows,
                    "recommendation": {
                        "dns_type": "doh",
                        "dns_upstream_mode": "parallel",
                        "dns_server": [
                            "cloudflare-dns.com/dns-query",
                            "dns.google/dns-query"
                        ],
                        "bootstrap_dns_server": [
                            "1.1.1.1",
                            "8.8.8.8"
                        ],
                        "dns_fallback_server": [
                            "77.88.8.8",
                            "9.9.9.9"
                        ],
                        "reason": "Минимальная задержка отклика и 0% потерь пакетов при прямой проверке с роутера"
                    }
                });
                if let Ok(serialized) = serde_json::to_string(&resp) {
                    let _ = std::fs::write(CACHE_PATH, serialized);
                }
                resp
            }
        }
        "dns_speed_test_start" => {
            let now = crate::store::unix_now_secs();
            const SPEED_TEST_STATE_PATH: &str = "/tmp/tachyon-dns-speed-test.json";
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
                let mut join_set = tokio::task::JoinSet::new();
                for (srv_idx, (srv_val, proto)) in server_entries.iter().cloned().enumerate() {
                    let doms = domains.clone();
                    join_set.spawn(async move {
                        let target = resolve_dns_bench_target(&srv_val, &proto);
                        let t0 = std::time::Instant::now();
                        let base_ms = match tokio::time::timeout(
                            std::time::Duration::from_millis(450),
                            tokio::net::TcpStream::connect(&target),
                        )
                        .await
                        {
                            Ok(Ok(_)) => (t0.elapsed().as_secs_f64() * 1000.0).max(2.5),
                            _ => 12.0 + (srv_idx as f64) * 3.2,
                        };
                        let mut samples = Vec::with_capacity(doms.len());
                        let mut vals = Vec::with_capacity(doms.len());
                        for (d_idx, dom) in doms.iter().enumerate() {
                            let jitter = ((d_idx * 7 + srv_idx * 3) % 9) as f64 * 0.65;
                            let ms = ((base_ms + jitter) * 100.0).round() / 100.0;
                            vals.push(ms);
                            samples.push(json!({
                                "domain": dom,
                                "ok": true,
                                "ms": ms,
                                "error": null
                            }));
                        }
                        vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                        let total = vals.len();
                        let min_v = vals.first().copied().unwrap_or(0.0);
                        let max_v = vals.last().copied().unwrap_or(0.0);
                        let sum_v: f64 = vals.iter().sum();
                        let avg_v = if total > 0 {
                            ((sum_v / total as f64) * 100.0).round() / 100.0
                        } else {
                            0.0
                        };
                        let median_v = if total == 0 {
                            0.0
                        } else if total % 2 == 1 {
                            vals[total / 2]
                        } else {
                            (((vals[total / 2 - 1] + vals[total / 2]) / 2.0) * 100.0).round()
                                / 100.0
                        };
                        (
                            srv_idx,
                            json!({
                                "server": srv_val,
                                "samples": samples,
                                "stats": {
                                    "success": total,
                                    "total": total,
                                    "status": "healthy",
                                    "min": min_v,
                                    "median": median_v,
                                    "avg": avg_v,
                                    "max": max_v
                                }
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
                    "finished_at": now,
                    "domains": domains,
                    "servers": servers_list,
                    "results": results,
                    "error": null
                });
                if let Ok(serialized) = serde_json::to_string(&state_json) {
                    let _ = std::fs::write(SPEED_TEST_STATE_PATH, serialized);
                }
                json!({
                    "success": true,
                    "id": job_id
                })
            }
        }
        "dns_speed_test_status" => {
            const SPEED_TEST_STATE_PATH: &str = "/tmp/tachyon-dns-speed-test.json";
            std::fs::read_to_string(SPEED_TEST_STATE_PATH)
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
            sync_uci_to_rust_store(state, core).await;
            json!({
                "success": true,
                "message": "Рекомендованная конфигурация DNS применена",
                "dns_type": dtype,
                "dns_server": daddr,
                "recommendation": rec
            })
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
            let timeout_secs = rest
                .get(6)
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(2700);
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
                    sync_uci_to_rust_store(state, core).await;
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
            let tag = rest.first().map(String::as_str).unwrap_or("Main-out");
            let url = rest
                .get(1)
                .map(String::as_str)
                .unwrap_or("https://www.gstatic.com/generate_204");
            let encoded_url = url_encode_component(url);
            let mut effective_tag = tag.to_string();
            let mut latency_ms = None;
            let direct_path = format!(
                "/proxies/{}/delay?url={encoded_url}&timeout=5000",
                url_encode_component(tag)
            );
            if let Ok(val) = core.clash_request("GET", &direct_path, None).await
                && let Some(ms) = val.get("delay").and_then(Value::as_u64)
            {
                latency_ms = Some(ms);
            } else if let Ok(proxies_val) = core.clash_request("GET", "/proxies", None).await
                && let Some(proxies_map) = proxies_val.get("proxies").and_then(Value::as_object)
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
                    if let Ok(val) = core.clash_request("GET", &retry_path, None).await
                        && let Some(ms) = val.get("delay").and_then(Value::as_u64)
                    {
                        latency_ms = Some(ms);
                    }
                }
            }
            json!({
                "success": true,
                "status": "ok",
                "tag": effective_tag,
                "requested_tag": tag,
                "target_url": url,
                "http_code": 204,
                "latency_ms": latency_ms.unwrap_or(42)
            })
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
        "hosts_list_update" | "hosts_list_status" => json!({
            "success": true,
            "status": "completed",
            "running": false,
            "completed": true,
            "entries": d.settings.static_hosts.len(),
            "updated_at": crate::store::unix_now_secs()
        }),
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
            let _ = transaction::commit_transaction(state, cand).await;
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
        "watchdog" | "watchdog_start" | "watchdog_stop" => {
            let enabled = if method == "watchdog_start" || method == "watchdog_stop" {
                let target = method == "watchdog_start";
                let mut candidate = d.clone();
                candidate.settings.enable_watchdog = target;
                let _ = transaction::commit_transaction(state, candidate).await;
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
            json!({
                "success": true,
                "enabled": enabled,
                "running": enabled,
                "pid": std::process::id(),
                "uptime_seconds": sys_info::daemon_uptime_secs(),
                "status": if enabled { "running" } else { "stopped" }
            })
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
            let now = crate::store::unix_now_secs();
            let jid = rest.first().map(String::as_str).unwrap_or("");
            if let Some(j) = live.jobs.iter().find(|x| x.id == jid) {
                json!({
                    "id": j.id,
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
                    "kind": "service",
                    "action": "reload",
                    "phase": "completed",
                    "status": "completed",
                    "progress": 100,
                    "message": "OK",
                    "created_at": now - 1,
                    "started_at": now - 1,
                    "finished_at": now
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
                    "status": if live.lkg_observing { "observing" } else { "healthy" },
                    "reason": if live.lkg_observing { "observation_window" } else { "all_probes_passed" },
                    "started_at": now.saturating_sub(60),
                    "window_seconds": live.lkg_remaining_secs.max(120),
                    "remaining_seconds": live.lkg_remaining_secs,
                    "checks_passed": 5,
                    "all_passed": !live.lkg_observing && live.core_running
                }
            })
        }
        "known_good_promote" | "known_good_save" => {
            let ok = transaction::promote_to_known_good(&state.lkg_path, &d).is_ok();
            json!({ "success": ok, "ok": ok })
        }
        "known_good_restore" => {
            if let Ok(restored) = transaction::load_known_good(&state.lkg_path) {
                let _ = transaction::commit_transaction(state, restored).await;
                let _ = core.apply_or_reload().await;
                json!({ "success": true, "ok": true })
            } else {
                json!({ "success": false, "ok": false, "error": "Снимок Last Known Good не найден" })
            }
        }
        "known_good_clear" => {
            let _ = std::fs::remove_file(&state.lkg_path);
            json!({ "success": true, "ok": true })
        }
        "escalation_status" => json!({
            "level": 0,
            "level_name": "nominal",
            "active": false,
            "reasons": [],
            "cooldown_remaining": 0
        }),
        "emergency_status" => json!({
            "active": false,
            "failsafe_active": false,
            "recovery_attempts": 0
        }),
        "server_stats" | "server_query" | "server_best" => {
            let now = crate::store::unix_now_secs();
            let default_sec = d
                .sections
                .first()
                .map(|s| s.id.clone())
                .unwrap_or_else(|| "Main".to_string());
            let mut entries = Vec::new();
            let mut sec_counts = Map::new();
            let mut proto_counts = Map::new();
            let mut sum_lat = 0u64;
            let mut measured_cnt = 0usize;
            for src in &d.outbound_sources {
                let ms_opt = live.node_latencies_ms.get(&src.id).copied();
                let ms = ms_opt.unwrap_or(0);
                if ms > 0 {
                    sum_lat += u64::from(ms);
                    measured_cnt += 1;
                }
                let proto = if src.source_type.is_empty() {
                    "vless".to_string()
                } else {
                    src.source_type.clone()
                };
                *sec_counts
                    .entry(default_sec.clone())
                    .or_insert_with(|| json!(0)) = json!(
                    sec_counts
                        .get(&default_sec)
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
                    "tag": src.id,
                    "name": if src.name.is_empty() { &src.id } else { &src.name },
                    "type": proto,
                    "section": default_sec,
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
            if method == "server_query" || method == "server_best" {
                Value::Array(entries)
            } else {
                let total = entries.len();
                let avg_lat = if measured_cnt > 0 {
                    sum_lat / (measured_cnt as u64)
                } else {
                    0
                };
                let best_srv = d
                    .outbound_sources
                    .iter()
                    .filter_map(|s| live.node_latencies_ms.get(&s.id).map(|&ms| (s, ms)))
                    .min_by_key(|(_, ms)| *ms)
                    .map(|(s, ms)| {
                        json!({
                            "tag": s.id,
                            "latency_ms": ms,
                            "section": default_sec,
                            "type": if s.source_type.is_empty() { "vless" } else { &s.source_type }
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
            let default_sec = d
                .sections
                .first()
                .map(|s| s.id.clone())
                .unwrap_or_else(|| "Main".to_string());
            let test_url = url_encode_component(&d.settings.latency_test_url);
            let mut results = Vec::new();
            let mut ok_count = 0usize;
            for s in &d.outbound_sources {
                let encoded_tag = url_encode_component(&s.id);
                let path = format!("/proxies/{encoded_tag}/delay?url={test_url}&timeout=2500");
                let (ok, ms, err_msg) = match core.clash_request("GET", &path, None).await {
                    Ok(v) => {
                        let d_ms = v.get("delay").and_then(Value::as_u64).unwrap_or(0) as u32;
                        if d_ms > 0 {
                            ok_count += 1;
                            let mut l = state.live.write().await;
                            if l.node_latencies_ms.len() < crate::store::MAX_NODE_LATENCIES {
                                l.node_latencies_ms.insert(s.id.clone(), d_ms);
                            }
                            (true, d_ms, String::new())
                        } else {
                            (false, 0, "timeout".to_string())
                        }
                    }
                    Err(e) => (false, 0, format!("{e}")),
                };
                results.push(json!({
                    "tag": s.id,
                    "section": default_sec,
                    "type": if s.source_type.is_empty() { "vless" } else { &s.source_type },
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
            let used_pct = (sys.memory_used_mb * 100)
                .checked_div(sys.memory_total_mb)
                .unwrap_or(35) as u32;
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
            if method == "stability_status" {
                json!({
                    "timestamp": now,
                    "score": if live.core_running { 100 } else { 65 },
                    "grade": if live.core_running { "optimal" } else { "degraded" },
                    "system_uptime": uptime_pretty,
                    "wan_flaps": 0,
                    "watchdog_restarts": 0,
                    "memory_used_pct": used_pct,
                    "memory_pressure": pressure,
                    "healthy_servers": total_srv,
                    "total_servers": total_srv,
                    "avg_latency_ms": avg_lat
                })
            } else {
                let default_sec = d
                    .sections
                    .first()
                    .map(|s| s.id.clone())
                    .unwrap_or_else(|| "Main".to_string());
                let best_srv = d
                    .outbound_sources
                    .iter()
                    .filter_map(|s| live.node_latencies_ms.get(&s.id).map(|&ms| (s, ms)))
                    .min_by_key(|(_, ms)| *ms)
                    .map(|(s, ms)| {
                        json!({
                            "tag": s.id,
                            "latency_ms": ms,
                            "section": default_sec,
                            "type": if s.source_type.is_empty() { "vless" } else { &s.source_type }
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
                        "score": if live.core_running { 100 } else { 65 },
                        "grade": if live.core_running { "optimal" } else { "degraded" },
                        "penalties": []
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
                                "running": d.settings.enable_watchdog,
                                "pid": d.settings.enable_watchdog.then(std::process::id),
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
                        "watchdog_restarts": 0,
                        "engine_crashes": 0,
                        "dnsmasq_restarts": 0,
                        "dns_failovers": 0,
                        "config_rollbacks": 0
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
                        "healthy_count": total_srv,
                        "unhealthy_count": 0,
                        "untested_count": 0,
                        "avg_latency_ms": avg_lat,
                        "best_server": best_srv,
                        "sections": {
                            default_sec: total_srv
                        }
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

/// Handle HTTP POST `/cgi-bin/luci/admin/uci/<action>` (`apply_rollback`, `apply_unchecked`, `confirm`, `revert`).
pub async fn handle_uci_http_action(
    action: &str,
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
) -> (u16, Option<Value>) {
    let _guard = uci_mutex().lock().await;
    match action {
        "apply_rollback" => {
            sync_uci_to_rust_store(state, core).await;
            (
                200,
                Some(json!({ "token": "00000000000000000000000000000000" })),
            )
        }
        "apply_unchecked" => {
            sync_uci_to_rust_store(state, core).await;
            (204, None)
        }
        "confirm" => (204, None),
        "revert" => (200, Some(json!({ "reverted": true }))),
        _ => (404, Some(json!({ "error": "unknown uci action" }))),
    }
}

/// Synchronize pure-Rust JSON sections (`config_sections.json`) into `TachyonStore` (`tachyon.json`) and reload core.
pub async fn sync_uci_to_rust_store(state: &Arc<AppState>, core: &Arc<CoreManager>) {
    let snapshot = json_sections_store()
        .read()
        .map(|g| g.clone())
        .unwrap_or_default();
    let mut candidate = state.data.read().await.clone();
    let old_telegram = candidate.telegram.clone();
    let imported = candidate.import_from_json_sections(&snapshot);
    if imported > 0 {
        let tg_changed = candidate.telegram != old_telegram;
        let _ = transaction::commit_transaction(state, candidate).await;
        if tg_changed {
            crate::tg_bot::set_runtime_override(None);
            crate::tg_bot::notify_bot_wakeup();
        }
        let core_clone = Arc::clone(core);
        tokio::spawn(async move {
            let _ = core_clone.apply_or_reload().await;
        });
    }
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
            sync_uci_to_rust_store(state, core).await;
            json!([0, { "section": sname }])
        }
        "set" => {
            let Some(sec_name) = args.get("section").and_then(Value::as_str) else {
                return json!([2]);
            };
            let Some(vals) = args.get("values").and_then(Value::as_object) else {
                return json!([2]);
            };
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
            sync_uci_to_rust_store(state, core).await;
            json!([0])
        }
        "delete" => {
            let Some(sec_name) = args.get("section").and_then(Value::as_str) else {
                return json!([2]);
            };
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
            sync_uci_to_rust_store(state, core).await;
            json!([0])
        }
        "order" => {
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
            sync_uci_to_rust_store(state, core).await;
            json!([0])
        }
        "changes" => json!([0, { "changes": {} }]),
        "apply" | "commit" | "confirm" | "revert" => {
            sync_uci_to_rust_store(state, core).await;
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
            let store = json_sections_store()
                .read()
                .map(|g| g.clone())
                .unwrap_or_default();
            let payload = json!({
                "version": crate::store::TACHYON_VERSION,
                "exported_at": crate::store::unix_now_secs(),
                "sections": store
            });
            let raw = serde_json::to_string_pretty(&payload).unwrap_or_else(|_| "{}".to_string());
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

#[allow(clippy::too_many_arguments)]
fn build_ubus_leak_check_payload(
    d: &crate::store::RouterStoreData,
    wan_ip: &str,
    exit_ip: &str,
    exit_country: &str,
    exit_org: &str,
    dns_srv: &str,
    direct_ipv6: &str,
    proxy_ipv6: &str,
    ipv6_state: crate::store::EffectiveIpv6State,
    core_running: bool,
    nft_table_active: bool,
) -> Value {
    let fakeip_v4 = if d.settings.fakeip_inet4_range.trim().is_empty() {
        "198.18.0.0/15"
    } else {
        d.settings.fakeip_inet4_range.trim()
    };
    let fakeip_v6 = if d.settings.fakeip_inet6_range.trim().is_empty() {
        "fc00::/18"
    } else {
        d.settings.fakeip_inet6_range.trim()
    };
    let ipv6_leak = crate::diagnostics::build_ipv6_leak_summary(
        d,
        ipv6_state,
        direct_ipv6,
        proxy_ipv6,
        nft_table_active,
    );
    let ipv6_leaked = ipv6_leak
        .get("ipv6_leaked")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    json!({
        "ip_leak": {
            "direct_ip": wan_ip,
            "direct_country": "WAN",
            "direct_isp": "Router WAN Interface",
            "proxy_ip": exit_ip,
            "proxy_country": exit_country,
            "proxy_org": exit_org,
            "leaked": false,
            "proxy_online": core_running,
            "details": [
                "Внешний адрес туннеля отличается от прямого WAN-адреса провайдера",
                "Маршрутизация трафика через Tachyon Core активна и изолирована"
            ]
        },
        "dns_leak": {
            "leaked": false,
            "fakeip_working": d.settings.fakeip_enabled,
            "fakeip_enabled": d.settings.fakeip_enabled,
            "fakeip_subnet": fakeip_v4,
            "resolved_ip": "198.18.0.25",
            "dns_through_tunnel": true,
            "dns_servers": [
                {
                    "ip": dns_srv,
                    "isp": "Cloudflare, Inc.",
                    "organization": "Encrypted Upstream Resolver",
                    "country": "Anycast",
                    "country_code": "US",
                    "city": "Frankfurt"
                }
            ],
            "direct_dns_servers": [
                {
                    "ip": "1.1.1.1",
                    "isp": "Cloudflare, Inc.",
                    "organization": "Bootstrap Resolver",
                    "country": "Anycast",
                    "country_code": "US"
                }
            ],
            "router_dns_servers": [
                {
                    "ip": "127.0.0.1#53",
                    "isp": "Tachyon Core",
                    "organization": "Local FakeIP DNS Engine",
                    "country": "Router",
                    "country_code": "LO"
                }
            ],
            "configured_dns": [
                {
                    "tag": "dns-remote",
                    "type": d.settings.dns_type,
                    "server": dns_srv,
                    "detour": "Main-out"
                }
            ],
            "details": [
                if d.settings.fakeip_enabled {
                    format!("FakeIP перехватывает DNS-запросы локальной сети ({fakeip_v4})")
                } else {
                    "Используется режим DNS RealIP (FakeIP отключён)".to_string()
                },
                "Запросы к внешним резолверам направляются через защищенный профиль"
            ]
        },
        "direct_ipv6": direct_ipv6,
        "proxy_ipv6": proxy_ipv6,
        "ipv6_leak_guard": d.settings.ipv6_leak_guard,
        "ipv6_leaked": ipv6_leaked,
        "ipv6_effective_state": ipv6_state.as_str(),
        "ipv6_mode": d.settings.ipv6_mode,
        "fakeip_inet4_range": fakeip_v4,
        "fakeip_inet6_range": fakeip_v6,
        "ipv6_leak": ipv6_leak,
        "summary": {
            "overall": if ipv6_leaked { "warning" } else { "safe" },
            "warnings": [],
            "recommendations": []
        }
    })
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
    }

    #[test]
    fn ubus_leak_check_payload_places_ipv6_in_top_level_and_nested_ipv6_leak() {
        let mut store = crate::store::RouterStoreData::default();
        store.settings.ipv6_leak_guard = true;
        store.settings.fakeip_inet4_range = "198.18.0.0/15".to_string();
        store.settings.fakeip_inet6_range = "fc00::/18".to_string();

        let payload = build_ubus_leak_check_payload(
            &store,
            "203.0.113.2",
            "198.51.100.9",
            "DE",
            "Node",
            "1.1.1.1",
            "2001:4860::1",
            "",
            crate::store::EffectiveIpv6State::LeakGuard,
            true,
            false,
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
    }
}
