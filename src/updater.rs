use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::process::Command;

use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::snapshots;
use crate::store;

const ACTION_DIR: &str = "/var/run/tachyon/component-actions";
const CHECK_CACHE_DIR: &str = "/var/run/tachyon/component-update-checks";
const RELEASES_CACHE_DIR: &str = "/var/run/tachyon/releases-cache";
const LIST_STATUS_PATH: &str = "/var/run/tachyon/list-update-status.json";
const TACHYON_CORE_REPO: &str = "Dushnilin/tachyon-core";
const TACHYON_LISTS_REPO: &str = "Dushnilin/tachyon-lists";
const RELEASES_CACHE_TTL_SECS: i64 = 300;
const STALE_JOB_SECS: i64 = 300;

static AUTO_UPDATE_IN_FLIGHT: AtomicBool = AtomicBool::new(false);
static LIST_UPDATE_IN_FLIGHT: AtomicBool = AtomicBool::new(false);

pub fn canonical_component(raw: &str) -> &'static str {
    match raw.trim().to_ascii_lowercase().as_str() {
        "tachyon" => "tachyon",
        "lists" | "rulesets" => "lists",
        "subscriptions" => "subscriptions",
        _ => "sing_box",
    }
}

pub fn component_display_name(comp: &str) -> &'static str {
    match canonical_component(comp) {
        "tachyon" => "Tachyon",
        "lists" => "Списки и наборы правил",
        "subscriptions" => "Подписки",
        _ => "Tachyon Core",
    }
}

pub fn tachyon_release_repo() -> String {
    std::env::var("TACHYON_RELEASE_REPO")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Dushnilin/tachyon".to_string())
}

pub fn component_repo(comp: &str) -> String {
    match canonical_component(comp) {
        "tachyon" => tachyon_release_repo(),
        "lists" => TACHYON_LISTS_REPO.to_string(),
        _ => TACHYON_CORE_REPO.to_string(),
    }
}

fn sanitize_job_id(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(80)
        .collect()
}

pub fn split_version_parts(raw: &str) -> (Vec<u64>, Option<&str>) {
    let trimmed = raw.trim().trim_start_matches(['v', 'V']);
    let trimmed = trimmed.split('+').next().unwrap_or(trimmed);
    let (core_part, pre) = match trimmed.split_once('-') {
        Some((left, right)) => {
            let r = right.trim();
            (left, if r.is_empty() { None } else { Some(r) })
        }
        None => (trimmed, None),
    };
    let nums = core_part
        .split('.')
        .filter_map(|seg| {
            let digits: String = seg.chars().take_while(|c| c.is_ascii_digit()).collect();
            if digits.is_empty() {
                None
            } else {
                digits.parse::<u64>().ok()
            }
        })
        .collect::<Vec<_>>();
    (nums, pre)
}

pub fn is_tachyon_v2_or_newer(tag: &str) -> bool {
    let (nums, _) = split_version_parts(tag);
    nums.first().copied().unwrap_or(0) >= 2
}

fn compare_prerelease_segment(a: &str, b: &str) -> std::cmp::Ordering {
    match (a.parse::<u64>(), b.parse::<u64>()) {
        (Ok(na), Ok(nb)) => na.cmp(&nb),
        (Ok(_), Err(_)) => std::cmp::Ordering::Less,
        (Err(_), Ok(_)) => std::cmp::Ordering::Greater,
        (Err(_), Err(_)) => a.to_ascii_lowercase().cmp(&b.to_ascii_lowercase()),
    }
}

fn compare_prerelease(a: &str, b: &str) -> std::cmp::Ordering {
    let mut segs_a = a.split(['.', '-']).filter(|s| !s.is_empty());
    let mut segs_b = b.split(['.', '-']).filter(|s| !s.is_empty());
    loop {
        match (segs_a.next(), segs_b.next()) {
            (Some(sa), Some(sb)) => {
                let ord = compare_prerelease_segment(sa, sb);
                if ord != std::cmp::Ordering::Equal {
                    return ord;
                }
            }
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (None, None) => return std::cmp::Ordering::Equal,
        }
    }
}

pub fn compare_versions(a: &str, b: &str) -> std::cmp::Ordering {
    let (va, pre_a) = split_version_parts(a);
    let (vb, pre_b) = split_version_parts(b);
    let max_len = va.len().max(vb.len()).max(3);
    for i in 0..max_len {
        let x = *va.get(i).unwrap_or(&0);
        let y = *vb.get(i).unwrap_or(&0);
        if x != y {
            return x.cmp(&y);
        }
    }
    match (pre_a, pre_b) {
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (Some(pa), Some(pb)) => compare_prerelease(pa, pb),
        (None, None) => std::cmp::Ordering::Equal,
    }
}

pub fn classify_version_status(current: &str, latest: &str) -> &'static str {
    if latest.trim().is_empty() || current.trim().is_empty() {
        return "";
    }
    match compare_versions(current, latest) {
        std::cmp::Ordering::Less => "outdated",
        std::cmp::Ordering::Greater => "dev",
        std::cmp::Ordering::Equal => "latest",
    }
}

pub fn detect_arch_keywords() -> Vec<&'static str> {
    let mut raw = String::new();
    if let Ok(rel) = std::fs::read_to_string("/etc/openwrt_release") {
        raw.push_str(&rel);
        raw.push('\n');
    }
    if let Ok(os_rel) = std::fs::read_to_string("/etc/os-release") {
        raw.push_str(&os_rel);
        raw.push('\n');
    }
    raw.push_str(std::env::consts::ARCH);
    map_arch_str_to_keywords(&raw)
}

pub fn map_arch_str_to_keywords(raw: &str) -> Vec<&'static str> {
    let lower = raw.to_ascii_lowercase();
    if lower.contains("aarch64") || lower.contains("arm64") {
        vec!["aarch64", "arm64"]
    } else if lower.contains("x86_64") || lower.contains("amd64") {
        vec!["x86_64", "amd64", "linux-amd64"]
    } else if lower.contains("riscv64") {
        vec!["riscv64"]
    } else if lower.contains("mips64el") {
        vec!["mips64el", "mipsel"]
    } else if lower.contains("mips64") {
        vec!["mips64", "mips"]
    } else if lower.contains("mipsel") {
        vec!["mipsel"]
    } else if lower.contains("mips") {
        vec!["mips"]
    } else if lower.contains("armv7") || lower.contains("arm_cortex") {
        vec!["armv7", "armv7l", "armv6", "arm"]
    } else if lower.contains("arm") {
        vec!["armv6", "armel", "arm"]
    } else if lower.contains("i386")
        || lower.contains("i586")
        || lower.contains("i686")
        || lower.contains("386")
        || lower.contains("x86")
    {
        vec!["i386_pentium4", "i686", "386", "i386", "x86"]
    } else {
        vec![std::env::consts::ARCH]
    }
}

pub fn select_release_asset(assets: &[Value], arch_keywords: &[&str]) -> Option<(String, String)> {
    let is_32bit_x86_target = arch_keywords.iter().any(|k| {
        matches!(
            *k,
            "i386_pentium4" | "386" | "i386" | "i586" | "i686" | "x86"
        )
    }) && !arch_keywords
        .iter()
        .any(|k| matches!(*k, "x86_64" | "amd64" | "linux-amd64"));
    let is_excluded_platform_asset = |lower: &str| {
        (is_32bit_x86_target && (lower.contains("x86_64") || lower.contains("amd64")))
            || lower.contains("sha256")
            || lower.ends_with(".sig")
            || lower.ends_with(".asc")
            || lower.contains("android")
            || lower.contains("darwin")
            || lower.contains("ios")
            || lower.contains("windows")
            || lower.contains("xcframework")
            || lower.ends_with(".exe")
            || lower.ends_with(".so")
            || lower.ends_with(".ipk")
            || lower.ends_with(".apk")
    };
    let arch_matches = |lower: &str, kw: &str| {
        if kw == "mips" && (lower.contains("mipsel") || lower.contains("mips64")) {
            return false;
        }
        if kw == "mipsel" && lower.contains("mips64") {
            return false;
        }
        if kw == "mips64" && lower.contains("mips64el") {
            return false;
        }
        if kw == "arm"
            && (lower.contains("aarch64") || lower.contains("arm64") || lower.contains("armv7"))
        {
            return false;
        }
        lower.contains(kw)
    };
    for kw in arch_keywords {
        for a in assets {
            let name = a.get("name").and_then(Value::as_str).unwrap_or("");
            let url = a
                .get("browser_download_url")
                .and_then(Value::as_str)
                .unwrap_or("");
            let lower = name.to_ascii_lowercase();
            if url.is_empty() || is_excluded_platform_asset(&lower) {
                continue;
            }
            if arch_matches(&lower, kw) && lower.ends_with(".tar.gz") {
                return Some((name.to_string(), url.to_string()));
            }
        }
    }
    for kw in arch_keywords {
        for a in assets {
            let name = a.get("name").and_then(Value::as_str).unwrap_or("");
            let url = a
                .get("browser_download_url")
                .and_then(Value::as_str)
                .unwrap_or("");
            let lower = name.to_ascii_lowercase();
            if url.is_empty() || is_excluded_platform_asset(&lower) {
                continue;
            }
            if arch_matches(&lower, kw)
                && (lower.ends_with(".tgz") || lower.ends_with(".zip") || !lower.contains('.'))
            {
                return Some((name.to_string(), url.to_string()));
            }
        }
    }
    None
}

pub fn find_sha256sums_url(assets: &[Value]) -> Option<String> {
    for a in assets {
        let name = a.get("name").and_then(Value::as_str).unwrap_or("");
        let lower = name.to_ascii_lowercase();
        if (lower == "sha256sums" || lower == "sha256sums.txt" || lower.ends_with(".sha256"))
            && let Some(u) = a.get("browser_download_url").and_then(Value::as_str)
            && !u.is_empty()
        {
            return Some(u.to_string());
        }
    }
    None
}

pub fn verify_sha256_against_manifest(
    manifest: &str,
    asset_name: &str,
    actual_sha256: &str,
) -> Result<(), String> {
    let target = asset_name.trim().trim_start_matches("./");
    let mut saw_any = false;
    for line in manifest.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        saw_any = true;
        let mut parts = trimmed.split_whitespace();
        let hash = parts.next().unwrap_or("").trim().to_ascii_lowercase();
        let file_part = parts
            .next()
            .unwrap_or("")
            .trim()
            .trim_start_matches('*')
            .trim_start_matches("./");
        if file_part == target || file_part.rsplit('/').next() == Some(target) {
            if hash.len() == 64 && hash == actual_sha256.to_ascii_lowercase() {
                return Ok(());
            }
            return Err(format!(
                "Несовпадение SHA-256 для {target}: ожидалось {hash}, получено {actual_sha256}"
            ));
        }
    }
    if saw_any && target.ends_with(".sha256") {
        return Ok(());
    }
    // Single bare hash file (`<hex>` alone with no filename token)
    let mut toks = manifest.split_whitespace();
    if let (Some(first_token), None) = (toks.next(), toks.next()) {
        let h = first_token.trim().to_ascii_lowercase();
        if h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()) {
            if h == actual_sha256.to_ascii_lowercase() {
                return Ok(());
            }
            return Err(format!(
                "Несовпадение SHA-256 для {target}: ожидалось {h}, получено {actual_sha256}"
            ));
        }
    }
    Err(format!("В SHA256SUMS не найдена запись для {target}"))
}

fn sha256_hex_bytes(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    crypto_gen::bytes_to_hex(&h.finalize())
}

pub fn verify_sha256_for_candidates(
    manifest: &str,
    candidates: &[(&str, String)],
) -> Result<String, String> {
    let mut last_err = "В SHA256SUMS не найдено подходящих записей".to_string();
    for (name, actual_hash) in candidates {
        match verify_sha256_against_manifest(manifest, name, actual_hash) {
            Ok(()) => return Ok(actual_hash.clone()),
            Err(e) if e.starts_with("Несовпадение SHA-256") => return Err(e),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

fn decode_xml_entities(input: &str) -> String {
    input
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
}

fn html_to_plain_notes(encoded_html: &str) -> String {
    let decoded = decode_xml_entities(encoded_html);
    let mut out = String::with_capacity(decoded.len());
    let mut in_tag = false;
    let mut tag_buf = String::new();
    for ch in decoded.chars() {
        if in_tag {
            if ch == '>' {
                in_tag = false;
                let t = tag_buf.trim().to_ascii_lowercase();
                if t == "li" {
                    if !out.ends_with('\n') && !out.is_empty() {
                        out.push('\n');
                    }
                    out.push_str("- ");
                } else if matches!(
                    t.split_whitespace().next().unwrap_or(""),
                    "/p" | "/h1" | "/h2" | "/h3" | "/h4" | "/ul" | "/ol" | "/li" | "br" | "br/"
                ) && !out.ends_with('\n')
                {
                    out.push('\n');
                }
                tag_buf.clear();
            } else {
                tag_buf.push(ch);
            }
        } else if ch == '<' {
            in_tag = true;
            tag_buf.clear();
        } else {
            out.push(ch);
        }
    }
    out.lines()
        .map(str::trim_end)
        .filter(|l| !l.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn extract_xml_tag_value(block: &str, tag: &str) -> String {
    let open_exact = format!("<{tag}>");
    let open_prefix = format!("<{tag} ");
    let start_pos = if let Some(p) = block.find(&open_exact) {
        p + open_exact.len()
    } else if let Some(p) = block.find(&open_prefix) {
        let Some(gt) = block[p..].find('>') else {
            return String::new();
        };
        p + gt + 1
    } else {
        return String::new();
    };
    let close = format!("</{tag}>");
    let Some(end_rel) = block[start_pos..].find(&close) else {
        return String::new();
    };
    block[start_pos..start_pos + end_rel].trim().to_string()
}

pub fn parse_releases_atom(xml: &str, repo: &str) -> Vec<Value> {
    let mut items = Vec::new();
    let mut cursor = xml;
    while let Some(start) = cursor.find("<entry>") {
        let rest = &cursor[start + "<entry>".len()..];
        let Some(end) = rest.find("</entry>") else {
            break;
        };
        let entry = &rest[..end];
        cursor = &rest[end + "</entry>".len()..];

        let mut href = String::new();
        if let Some(lp) = entry.find("href=\"") {
            let after = &entry[lp + 6..];
            if let Some(q) = after.find('"') {
                href = after[..q].to_string();
            }
        }
        let id_val = extract_xml_tag_value(entry, "id");
        let tag = href
            .rsplit("/releases/tag/")
            .next()
            .filter(|s| !s.is_empty() && !s.contains("://"))
            .or_else(|| id_val.rsplit('/').next())
            .unwrap_or("")
            .trim()
            .to_string();
        if tag.is_empty() {
            continue;
        }
        let title = decode_xml_entities(&extract_xml_tag_value(entry, "title"));
        let name = if title.is_empty() { tag.clone() } else { title };
        let published = extract_xml_tag_value(entry, "updated");
        let raw_content = extract_xml_tag_value(entry, "content");
        let body = html_to_plain_notes(&raw_content);
        let release_url = if href.is_empty() {
            format!("https://github.com/{repo}/releases/tag/{tag}")
        } else {
            href
        };
        let lower_tag = tag.to_ascii_lowercase();
        let prerelease = lower_tag.contains('-');
        items.push(json!({
            "tag": tag,
            "version": tag.trim_start_matches(['v', 'V']),
            "name": name,
            "published": published,
            "published_at": published,
            "prerelease": prerelease,
            "release_url": release_url,
            "body": body,
        }));
    }
    items
}

pub fn parse_expanded_assets_html(html: &str, repo: &str, tag: &str) -> Vec<Value> {
    let prefix = format!("/{repo}/releases/download/{tag}/");
    let mut assets = Vec::new();
    let mut seen = HashSet::new();
    let mut cursor = html;
    while let Some(pos) = cursor.find(&prefix) {
        let after = &cursor[pos + prefix.len()..];
        let end = after
            .find(['"', '\'', '<', '>', ' ', '\n', '\r'])
            .unwrap_or(after.len());
        let asset_name = after[..end].trim();
        if !asset_name.is_empty()
            && !asset_name.contains('/')
            && seen.insert(asset_name.to_string())
        {
            assets.push(json!({
                "name": asset_name,
                "browser_download_url": format!("https://github.com/{repo}/releases/download/{tag}/{asset_name}"),
            }));
        }
        cursor = &after[end..];
    }
    assets
}

pub fn apply_github_mirror(mirror: &str, url: &str) -> String {
    let m = mirror.trim().trim_end_matches('/');
    if m.is_empty() || !url.starts_with("https://github.com/") {
        return url.to_string();
    }
    format!("{m}/{url}")
}

fn format_utc_hhmm_from_unix(unix_secs: i64) -> String {
    let secs_of_day = unix_secs.rem_euclid(86400);
    let h = secs_of_day / 3600;
    let m = (secs_of_day % 3600) / 60;
    format!("{h:02}:{m:02}")
}

fn local_hhmm_now() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    // Try `date +%H:%M` first so router's configured timezone is respected, fallback to UTC.
    if let Ok(out) = std::process::Command::new("date").arg("+%H:%M").output()
        && out.status.success()
    {
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if parse_hhmm_minutes(&s).is_some() {
            return s;
        }
    }
    format_utc_hhmm_from_unix(now)
}

pub fn parse_hhmm_minutes(raw: &str) -> Option<u16> {
    let (h_s, m_s) = raw.trim().split_once(':')?;
    let h = h_s.parse::<u16>().ok()?;
    let m = m_s.parse::<u16>().ok()?;
    if h >= 24 || m >= 60 {
        return None;
    }
    Some(h * 60 + m)
}

pub fn is_within_update_window(now_hhmm: &str, start_hhmm: &str, end_hhmm: &str) -> bool {
    let Some(now_m) = parse_hhmm_minutes(now_hhmm) else {
        return true;
    };
    let start_m = parse_hhmm_minutes(start_hhmm).unwrap_or(0);
    let end_m = parse_hhmm_minutes(end_hhmm).unwrap_or(23 * 60 + 59);
    if start_m == end_m {
        return true;
    }
    if start_m < end_m {
        now_m >= start_m && now_m <= end_m
    } else {
        now_m >= start_m || now_m <= end_m
    }
}

pub fn read_conntrack_load() -> (u32, u32) {
    let Ok(raw) = std::fs::read_to_string("/proc/net/nf_conntrack") else {
        return (0, 0);
    };
    let mut conns: u32 = 0;
    let mut clients = HashSet::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        conns = conns.saturating_add(1);
        for tok in trimmed.split_ascii_whitespace() {
            if let Some(ip) = tok.strip_prefix("src=") {
                if !ip.starts_with("127.") && ip != "::1" {
                    clients.insert(ip.to_string());
                }
                break;
            }
        }
    }
    (conns, clients.len() as u32)
}

fn ensure_runtime_dirs() {
    let _ = std::fs::create_dir_all(ACTION_DIR);
    let _ = std::fs::create_dir_all(CHECK_CACHE_DIR);
    let _ = std::fs::create_dir_all(RELEASES_CACHE_DIR);
}

fn job_status_path(job_id: &str) -> PathBuf {
    Path::new(ACTION_DIR).join(format!("{}.json", sanitize_job_id(job_id)))
}

fn job_log_path(job_id: &str) -> PathBuf {
    Path::new(ACTION_DIR).join(format!("{}.log", sanitize_job_id(job_id)))
}

fn write_job_status(job_id: &str, payload: &Value) {
    ensure_runtime_dirs();
    if let Ok(raw) = serde_json::to_string_pretty(payload) {
        let _ = std::fs::write(job_status_path(job_id), raw);
    }
}

fn append_job_log(job_id: &str, phase: Option<&str>, line: &str) {
    ensure_runtime_dirs();
    let now = store::unix_now_secs();
    let p = job_log_path(job_id);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
    {
        use std::io::Write;
        let _ = writeln!(file, "{line}");
    }
    let sp = job_status_path(job_id);
    if let Ok(raw) = std::fs::read_to_string(&sp)
        && let Ok(mut obj) = serde_json::from_str::<Value>(&raw)
        && let Some(map) = obj.as_object_mut()
    {
        map.insert("heartbeat_at".to_string(), json!(now));
        map.insert("updated_at".to_string(), json!(now));
        if let Some(ph) = phase {
            let prev = map.get("phase").and_then(Value::as_str).unwrap_or("");
            if prev != ph {
                map.insert("phase".to_string(), json!(ph));
                map.insert("phase_started_at".to_string(), json!(now));
            }
        }
        if let Ok(out) = serde_json::to_string_pretty(&obj) {
            let _ = std::fs::write(sp, out);
        }
    }
}

fn write_component_check_cache(comp: &str, result: &Value) {
    ensure_runtime_dirs();
    let canon = canonical_component(comp);
    let path = Path::new(CHECK_CACHE_DIR).join(format!("{canon}.json"));
    if let Ok(raw) = serde_json::to_string_pretty(result) {
        let _ = std::fs::write(path, raw);
    }
}

pub fn read_component_check_cache() -> Value {
    let mut results = Vec::new();
    for name in ["tachyon", "sing_box"] {
        let path = Path::new(CHECK_CACHE_DIR).join(format!("{name}.json"));
        if let Ok(raw) = std::fs::read_to_string(&path)
            && let Ok(val) = serde_json::from_str::<Value>(&raw)
        {
            results.push(val);
        }
    }
    json!({
        "enabled": true,
        "results": results,
    })
}

pub fn read_job_status(raw_job_id: &str) -> Value {
    let job_id = sanitize_job_id(raw_job_id);
    if job_id.is_empty() {
        return json!({
            "success": false,
            "job_id": "",
            "kind": "component",
            "status": "failed",
            "running": false,
            "completed": true,
            "exit_code": 1,
            "message": "Не указан идентификатор задачи"
        });
    }
    let sp = job_status_path(&job_id);
    let Ok(raw) = std::fs::read_to_string(&sp) else {
        return json!({
            "success": false,
            "job_id": job_id,
            "kind": "component",
            "status": "failed",
            "running": false,
            "completed": true,
            "exit_code": 1,
            "message": "Состояние операции не найдено"
        });
    };
    let Ok(mut val) = serde_json::from_str::<Value>(&raw) else {
        return json!({
            "success": false,
            "job_id": job_id,
            "kind": "component",
            "status": "failed",
            "running": false,
            "completed": true,
            "exit_code": 1,
            "message": "Повреждённый файл состояния операции"
        });
    };
    let running = val.get("running").and_then(Value::as_bool).unwrap_or(false);
    if running {
        let hb = val
            .get("heartbeat_at")
            .or_else(|| val.get("started_at"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let owner_pid = val
            .get("pid")
            .and_then(Value::as_str)
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(0);
        let now = store::unix_now_secs();
        let pid_alive = owner_pid > 0 && Path::new(&format!("/proc/{owner_pid}")).exists();
        if (!pid_alive && owner_pid > 0) || (hb > 0 && now.saturating_sub(hb) > STALE_JOB_SECS) {
            if let Some(map) = val.as_object_mut() {
                map.insert("running".to_string(), json!(false));
                map.insert("completed".to_string(), json!(true));
                map.insert("success".to_string(), json!(false));
                map.insert("exit_code".to_string(), json!(1));
                map.insert(
                    "message".to_string(),
                    json!("Операция прервана или превысила таймаут ожидания"),
                );
                map.insert("updated_at".to_string(), json!(now));
            }
            write_job_status(&job_id, &val);
        }
    }
    val
}

pub fn read_job_log(raw_job_id: &str, offset: usize) -> Value {
    let job_id = sanitize_job_id(raw_job_id);
    if job_id.is_empty() {
        return json!({
            "success": false,
            "log": "",
            "offset": 0
        });
    }
    let lp = job_log_path(&job_id);
    let Ok(bytes) = std::fs::read(&lp) else {
        return json!({
            "success": true,
            "log": "",
            "offset": offset
        });
    };
    let total = bytes.len();
    let start = offset.min(total);
    let chunk = String::from_utf8_lossy(&bytes[start..]).into_owned();
    json!({
        "success": true,
        "log": chunk,
        "offset": total
    })
}

pub fn active_component_job_ids() -> Vec<String> {
    let mut ids = Vec::new();
    let Ok(rd) = std::fs::read_dir(ACTION_DIR) else {
        return ids;
    };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
            let status = read_job_status(stem);
            if status.get("running").and_then(Value::as_bool) == Some(true) {
                ids.push(stem.to_string());
            }
        }
    }
    ids.sort();
    ids
}

async fn resolve_component_proxy(core: &Arc<CoreManager>) -> Option<String> {
    let d = core.state.data.read().await;
    if !d.settings.download_components_via_proxy {
        return None;
    }
    if let Some(sec) = d.sections.iter().find(|s| {
        s.enabled
            && s.id == d.settings.download_components_via_proxy_section
            && s.mixed_proxy_enabled
            && s.mixed_proxy_port > 0
    }) {
        return Some(format!("http://127.0.0.1:{}", sec.mixed_proxy_port));
    }
    d.sections
        .iter()
        .find(|s| s.enabled && s.mixed_proxy_enabled && s.mixed_proxy_port > 0)
        .map(|s| format!("http://127.0.0.1:{}", s.mixed_proxy_port))
}

async fn current_component_version(core: &Arc<CoreManager>, comp: &str) -> String {
    match canonical_component(comp) {
        "tachyon" => store::TACHYON_VERSION.to_string(),
        _ => {
            let v = core.state.live.read().await.core_version.clone();
            if v.trim().is_empty() {
                "0.0.0".to_string()
            } else {
                v
            }
        }
    }
}

async fn fetch_url_with_mirror_and_proxy(
    core: &Arc<CoreManager>,
    url: &str,
    mirror: &str,
    proxy: Option<&str>,
    timeout_secs: u64,
) -> anyhow::Result<Vec<u8>> {
    let mirrored = apply_github_mirror(mirror, url);
    if mirrored != url
        && let Ok(bytes) = core
            .curl_fetch_with_doh_fallback(&mirrored, false, timeout_secs, proxy)
            .await
        && !bytes.is_empty()
    {
        return Ok(bytes);
    }
    core.curl_fetch_with_doh_fallback(url, false, timeout_secs, proxy)
        .await
}

fn map_github_release_to_item(rel: &Value) -> Option<Value> {
    let tag = rel.get("tag_name").and_then(Value::as_str)?.trim();
    if tag.is_empty() {
        return None;
    }
    let name = rel
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(tag);
    let published = rel
        .get("published_at")
        .or_else(|| rel.get("created_at"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let prerelease = rel
        .get("prerelease")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let release_url = rel.get("html_url").and_then(Value::as_str).unwrap_or("");
    let body = rel.get("body").and_then(Value::as_str).unwrap_or("");
    Some(json!({
        "tag": tag,
        "version": tag.trim_start_matches(['v', 'V']),
        "name": name,
        "published": published,
        "published_at": published,
        "prerelease": prerelease,
        "release_url": release_url,
        "body": body,
    }))
}

pub async fn list_releases(
    core: &Arc<CoreManager>,
    raw_comp: &str,
    count: usize,
    page: usize,
) -> Value {
    ensure_runtime_dirs();
    let canon = canonical_component(raw_comp);
    let per_page = count.clamp(1, 30);
    let page = page.max(1);
    let cache_path = Path::new(RELEASES_CACHE_DIR).join(format!("{canon}_{per_page}_{page}.json"));
    let now = store::unix_now_secs();
    if let Ok(meta) = std::fs::metadata(&cache_path)
        && let Ok(mod_t) = meta.modified()
        && let Ok(age) = SystemTime::now().duration_since(mod_t)
        && (age.as_secs() as i64) < RELEASES_CACHE_TTL_SECS
        && let Ok(raw) = std::fs::read_to_string(&cache_path)
        && let Ok(val) = serde_json::from_str::<Value>(&raw)
        && val.is_array()
    {
        return val;
    }

    let repo = component_repo(canon);
    let api_per_page = if canon == "tachyon" { 30 } else { per_page };
    let api_url =
        format!("https://api.github.com/repos/{repo}/releases?per_page={api_per_page}&page={page}");
    let proxy = resolve_component_proxy(core).await;
    if let Ok(bytes) = core
        .curl_fetch_with_doh_fallback(&api_url, false, 10, proxy.as_deref())
        .await
        && let Ok(raw_list) = serde_json::from_slice::<Vec<Value>>(&bytes)
    {
        let mut items: Vec<Value> = raw_list
            .iter()
            .filter(|r| !r.get("draft").and_then(Value::as_bool).unwrap_or(false))
            .filter_map(map_github_release_to_item)
            .filter(|item| {
                canon != "tachyon"
                    || is_tachyon_v2_or_newer(item.get("tag").and_then(Value::as_str).unwrap_or(""))
            })
            .collect();
        items.truncate(per_page);
        if !items.is_empty() {
            let out = Value::Array(items);
            if let Ok(s) = serde_json::to_string(&out) {
                let _ = std::fs::write(&cache_path, s);
            }
            return out;
        }
    }

    // Fallback without GitHub REST API rate limits: Atom feed on github.com.
    let atom_url = format!("https://github.com/{repo}/releases.atom");
    if let Ok(atom_bytes) = core
        .curl_fetch_with_doh_fallback(&atom_url, false, 12, proxy.as_deref())
        .await
    {
        let xml = String::from_utf8_lossy(&atom_bytes);
        let parsed: Vec<Value> = parse_releases_atom(&xml, &repo)
            .into_iter()
            .filter(|item| {
                canon != "tachyon"
                    || is_tachyon_v2_or_newer(item.get("tag").and_then(Value::as_str).unwrap_or(""))
            })
            .skip((page - 1) * per_page)
            .take(per_page)
            .collect();
        if !parsed.is_empty() {
            let out = Value::Array(parsed);
            if let Ok(s) = serde_json::to_string(&out) {
                let _ = std::fs::write(&cache_path, s);
            }
            return out;
        }
    }

    // Fallback: return local build entry so dropdown never crashes UI when offline/private repo.
    let cur = current_component_version(core, canon).await;
    let disp = component_display_name(canon);
    let fallback_tag = if cur.starts_with('v') {
        cur.clone()
    } else {
        format!("v{cur}")
    };
    let _ = now;
    json!([
        {
            "tag": fallback_tag,
            "version": cur.trim_start_matches(['v', 'V']),
            "name": format!("{disp} v{}", cur.trim_start_matches(['v', 'V'])),
            "published": "",
            "published_at": "",
            "prerelease": false,
            "release_url": format!("https://github.com/{repo}/releases"),
            "body": if canon == "tachyon" {
                "Локальная pure-Rust сборка Tachyon (репозиторий релизов недоступен или не опубликован)."
            } else {
                "Список релизов временно недоступен; отображается текущая установленная версия."
            }
        }
    ])
}

pub fn pick_best_tachyon_v2_release(releases: &[Value], include_prerelease: bool) -> Option<Value> {
    let mut best: Option<(String, Value)> = None;
    for rel in releases {
        if rel.get("draft").and_then(Value::as_bool).unwrap_or(false) {
            continue;
        }
        let tag = rel
            .get("tag_name")
            .or_else(|| rel.get("tag"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if tag.is_empty() || !is_tachyon_v2_or_newer(tag) {
            continue;
        }
        let (_, tag_pre) = split_version_parts(tag);
        let is_pre = rel
            .get("prerelease")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            || tag_pre.is_some();
        if is_pre && !include_prerelease {
            continue;
        }
        let ver = tag.trim_start_matches(['v', 'V']).to_string();
        let take = match &best {
            None => true,
            Some((best_ver, _)) => compare_versions(best_ver, &ver) == std::cmp::Ordering::Less,
        };
        if take {
            best = Some((ver, rel.clone()));
        }
    }
    best.map(|(_, val)| val)
}

async fn fetch_component_release_json(
    core: &Arc<CoreManager>,
    canon: &str,
    repo: &str,
    tag: Option<&str>,
    proxy: Option<&str>,
) -> anyhow::Result<Value> {
    let is_tachyon_self = canon == "tachyon";
    let include_prerelease =
        is_tachyon_self && split_version_parts(store::TACHYON_VERSION).1.is_some();
    let wanted_tag = tag.map(str::trim).filter(|s| !s.is_empty());

    if let Some(clean) = wanted_tag {
        let url = format!("https://api.github.com/repos/{repo}/releases/tags/{clean}");
        if let Ok(bytes) = core
            .curl_fetch_with_doh_fallback(&url, false, 10, proxy)
            .await
            && let Ok(val) = serde_json::from_slice::<Value>(&bytes)
            && val.get("tag_name").is_some()
        {
            return Ok(val);
        }
    } else {
        if !include_prerelease {
            let latest_url = format!("https://api.github.com/repos/{repo}/releases/latest");
            if let Ok(bytes) = core
                .curl_fetch_with_doh_fallback(&latest_url, false, 10, proxy)
                .await
                && let Ok(val) = serde_json::from_slice::<Value>(&bytes)
                && let Some(latest_tag) = val.get("tag_name").and_then(Value::as_str)
                && (!is_tachyon_self || is_tachyon_v2_or_newer(latest_tag))
            {
                return Ok(val);
            }
        }
        if is_tachyon_self {
            let list_url = format!("https://api.github.com/repos/{repo}/releases?per_page=30");
            if let Ok(bytes) = core
                .curl_fetch_with_doh_fallback(&list_url, false, 10, proxy)
                .await
                && let Ok(list) = serde_json::from_slice::<Vec<Value>>(&bytes)
            {
                if let Some(best) = pick_best_tachyon_v2_release(&list, include_prerelease) {
                    return Ok(best);
                }
                anyhow::bail!("В репозитории {repo} нет релиза Tachyon 2.x для текущего канала");
            }
        }
    }

    // Fallback without GitHub REST API rate limits: Atom feed + expanded_assets fragment.
    let atom_url = format!("https://github.com/{repo}/releases.atom");
    let atom_bytes = core
        .curl_fetch_with_doh_fallback(&atom_url, false, 12, proxy)
        .await?;
    let atom_xml = String::from_utf8_lossy(&atom_bytes);
    let entries = parse_releases_atom(&atom_xml, repo);
    let picked_entry: Option<Value> = match wanted_tag {
        Some(wt) => entries
            .iter()
            .find(|e| {
                let t = e.get("tag").and_then(Value::as_str).unwrap_or("");
                let v = e.get("version").and_then(Value::as_str).unwrap_or("");
                t.eq_ignore_ascii_case(wt)
                    || v.eq_ignore_ascii_case(wt.trim_start_matches(['v', 'V']))
            })
            .cloned(),
        None if is_tachyon_self => pick_best_tachyon_v2_release(&entries, include_prerelease),
        None => entries.first().cloned(),
    };
    let resolved_tag = match picked_entry
        .as_ref()
        .and_then(|e| e.get("tag").and_then(Value::as_str))
        .map(str::to_string)
        .or_else(|| wanted_tag.map(str::to_string))
    {
        Some(t) if !t.is_empty() => t,
        _ => anyhow::bail!("Не найден релиз в Atom-ленте {repo}"),
    };

    let assets_url = format!("https://github.com/{repo}/releases/expanded_assets/{resolved_tag}");
    let assets = match core
        .curl_fetch_with_doh_fallback(&assets_url, false, 15, proxy)
        .await
    {
        Ok(b) => parse_expanded_assets_html(&String::from_utf8_lossy(&b), repo, &resolved_tag),
        Err(_) => Vec::new(),
    };
    let prerelease = picked_entry
        .as_ref()
        .and_then(|e| e.get("prerelease").and_then(Value::as_bool))
        .unwrap_or_else(|| split_version_parts(&resolved_tag).1.is_some());

    Ok(json!({
        "tag_name": resolved_tag,
        "name": picked_entry
            .as_ref()
            .and_then(|e| e.get("name").and_then(Value::as_str))
            .unwrap_or(&resolved_tag),
        "prerelease": prerelease,
        "html_url": format!("https://github.com/{repo}/releases/tag/{resolved_tag}"),
        "body": picked_entry
            .as_ref()
            .and_then(|e| e.get("body").and_then(Value::as_str))
            .unwrap_or(""),
        "published_at": picked_entry
            .as_ref()
            .and_then(|e| e.get("published_at").and_then(Value::as_str))
            .unwrap_or(""),
        "assets": assets,
    }))
}

async fn perform_check_update(core: &Arc<CoreManager>, canon: &str, job_id: Option<&str>) -> Value {
    let disp = component_display_name(canon);
    let current = current_component_version(core, canon).await;
    let repo = component_repo(canon);
    let proxy = resolve_component_proxy(core).await;
    let now = store::unix_now_secs();
    if let Some(jid) = job_id {
        append_job_log(
            jid,
            Some("checking"),
            &format!("[INFO] Получение метаданных для {disp} (текущая версия: {current})..."),
        );
    }

    match fetch_component_release_json(core, canon, &repo, None, proxy.as_deref()).await {
        Ok(rel) => {
            let tag = rel
                .get("tag_name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            let latest = tag.trim_start_matches(['v', 'V']).to_string();
            let release_url = rel
                .get("html_url")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let release_notes = rel
                .get("body")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let status = classify_version_status(&current, &latest);
            let msg = match status {
                "outdated" => {
                    format!("{disp}: доступна новая версия {latest} (установлена {current})")
                }
                "dev" => format!("{disp}: установлена сборка {current} (новее релиза {latest})"),
                _ => format!("{disp}: установлена актуальная версия {current}"),
            };
            if let Some(jid) = job_id {
                append_job_log(jid, Some("completed"), &format!("[OK] {msg}"));
            }
            let payload = json!({
                "success": true,
                "running": false,
                "completed": true,
                "kind": "component",
                "job_id": job_id.unwrap_or(""),
                "component": canon,
                "action": "check_update",
                "message": msg,
                "current_version": current,
                "latest_version": latest,
                "release_url": release_url,
                "release_notes": release_notes,
                "changed": status == "outdated",
                "status": status,
                "exit_code": 0,
                "updated_at": now,
            });
            write_component_check_cache(canon, &payload);
            payload
        }
        Err(e) => {
            if canon == "tachyon" {
                let msg = format!(
                    "{disp}: установлена локальная сборка {current} (внешний репозиторий {repo} не опубликован)"
                );
                if let Some(jid) = job_id {
                    append_job_log(jid, Some("completed"), &format!("[OK] {msg}"));
                }
                let payload = json!({
                    "success": true,
                    "running": false,
                    "completed": true,
                    "kind": "component",
                    "job_id": job_id.unwrap_or(""),
                    "component": canon,
                    "action": "check_update",
                    "message": msg,
                    "current_version": current,
                    "latest_version": current,
                    "release_url": format!("https://github.com/{repo}"),
                    "release_notes": "",
                    "changed": false,
                    "status": "latest",
                    "exit_code": 0,
                    "updated_at": now,
                });
                write_component_check_cache(canon, &payload);
                payload
            } else {
                let err_msg = format!("Не удалось проверить обновления для {disp}: {e}");
                if let Some(jid) = job_id {
                    append_job_log(jid, Some("failed"), &format!("[ERR] {err_msg}"));
                }
                json!({
                    "success": false,
                    "running": false,
                    "completed": true,
                    "kind": "component",
                    "job_id": job_id.unwrap_or(""),
                    "component": canon,
                    "action": "check_update",
                    "message": err_msg,
                    "current_version": current,
                    "latest_version": current,
                    "changed": false,
                    "status": "",
                    "exit_code": 1,
                    "updated_at": now,
                })
            }
        }
    }
}

fn is_ignored_extracted_artifact(lower_name: &str) -> bool {
    [
        ".tar.gz", ".tgz", ".zip", ".ipk", ".apk", ".sha256", ".sig", ".asc", ".js", ".po", ".pot",
        ".json", ".txt", ".md",
    ]
    .iter()
    .any(|ext| lower_name.ends_with(ext))
}

async fn find_extracted_binary(dir: &Path, expected_name: &str) -> Option<PathBuf> {
    let mut stack = vec![dir.to_path_buf()];
    let mut prefix_match: Option<PathBuf> = None;
    let prefix = format!("{expected_name}-");
    while let Some(cur) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&cur) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.is_file() {
                let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                let lower = name.to_ascii_lowercase();
                if is_ignored_extracted_artifact(&lower) {
                    continue;
                }
                if name == expected_name {
                    return Some(p);
                }
                if name.starts_with(&prefix) && prefix_match.is_none() {
                    prefix_match = Some(p);
                }
            }
        }
    }
    prefix_match
}

pub fn collect_staged_luci_sync_pairs(
    stage_dir: &Path,
    target_root: &Path,
) -> Vec<(PathBuf, PathBuf)> {
    let mut pairs = Vec::new();
    let mut stack = vec![stage_dir.to_path_buf()];
    while let Some(cur) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&cur) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            if !p.is_file() {
                continue;
            }
            let Ok(rel) = p.strip_prefix(stage_dir) else {
                continue;
            };
            let rel_slash = rel.to_string_lossy().replace('\\', "/");
            let dst_rel = if let Some(sub) = rel_slash.strip_prefix("htdocs/") {
                Some(format!("www/{sub}"))
            } else if rel_slash.starts_with("www/luci-static/resources/view/tachyon/")
                || rel_slash.starts_with("usr/share/tachyon/")
                || rel_slash.starts_with("usr/lib/lua/luci/")
                || rel_slash.starts_with("usr/share/luci/")
                || rel_slash.starts_with("usr/share/rpcd/")
            {
                Some(rel_slash)
            } else {
                None
            };
            if let Some(dst_str) = dst_rel {
                let mut dst = target_root.to_path_buf();
                for seg in dst_str.split('/').filter(|s| !s.is_empty()) {
                    dst.push(seg);
                }
                pairs.push((p, dst));
            }
        }
    }
    pairs.sort_by(|a, b| a.1.cmp(&b.1));
    pairs
}

fn sync_staged_luci_assets(stage_dir: &Path, target_root: &Path) -> usize {
    let mut updated = 0usize;
    for (src, dst) in collect_staged_luci_sync_pairs(stage_dir, target_root) {
        if let Ok(bytes) = std::fs::read(&src)
            && crypto_gen::write_file_if_changed(&dst, &bytes).unwrap_or(false)
        {
            updated += 1;
        }
    }
    updated
}

pub fn resolve_tachyon_self_bin_path() -> PathBuf {
    if let Ok(over) = std::env::var("TACHYON_BIN") {
        let trimmed = over.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    let default_bin = Path::new("/usr/bin/tachyon");
    if default_bin.exists() || cfg!(target_os = "linux") {
        return default_bin.to_path_buf();
    }
    std::env::current_exe().unwrap_or_else(|_| default_bin.to_path_buf())
}

async fn run_command_checked(bin: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new(bin)
        .args(args)
        .output()
        .await
        .map_err(|e| format!("Ошибка запуска {}: {e}", bin.display()))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if !out.status.success() {
        return Err(if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("Код выхода {:?}", out.status.code())
        });
    }
    Ok(if !stdout.is_empty() { stdout } else { stderr })
}

struct StagedRelease {
    stage_dir: PathBuf,
    extracted_bin: PathBuf,
    target_ver: String,
    release_url: String,
    release_notes: String,
    backup_enabled: bool,
    current: String,
}

fn component_error_payload(
    canon: &str,
    action: &str,
    job_id: &str,
    current: &str,
    msg: String,
) -> Value {
    append_job_log(job_id, Some("failed"), &format!("[ERR] {msg}"));
    json!({
        "success": false,
        "running": false,
        "completed": true,
        "kind": "component",
        "job_id": job_id,
        "component": canon,
        "action": action,
        "message": msg,
        "current_version": current,
        "latest_version": current,
        "changed": false,
        "status": "",
        "exit_code": 1,
        "updated_at": store::unix_now_secs(),
    })
}

fn atomic_swap_binary(extracted_bin: &Path, target_bin: &Path) -> std::io::Result<()> {
    let tmp_swap = target_bin.with_extension("new");
    let res = (|| -> std::io::Result<()> {
        if let Some(parent) = target_bin.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(extracted_bin, &tmp_swap)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp_swap, std::fs::Permissions::from_mode(0o755));
        }
        std::fs::rename(&tmp_swap, target_bin)?;
        Ok(())
    })();
    if res.is_err() {
        let _ = std::fs::remove_file(&tmp_swap);
    }
    res
}

struct StageReleaseSpec<'a> {
    canon: &'a str,
    disp: &'a str,
    repo: &'a str,
    expected_bin_name: &'a str,
    version_check_args: &'a [&'a str],
    action: &'a str,
    tag_opt: Option<&'a str>,
}

async fn stage_release_binary(
    core: &Arc<CoreManager>,
    job_id: &str,
    spec: &StageReleaseSpec<'_>,
) -> Result<StagedRelease, Value> {
    let StageReleaseSpec {
        canon,
        disp,
        repo,
        expected_bin_name,
        version_check_args,
        action,
        tag_opt,
    } = *spec;
    let now = store::unix_now_secs();
    let current = current_component_version(core, canon).await;
    let proxy = resolve_component_proxy(core).await;
    let (backup_enabled, mirror) = {
        let d = core.state.data.read().await;
        (
            d.settings.component_backup_enabled,
            d.settings.github_mirror.clone(),
        )
    };

    append_job_log(
        job_id,
        Some("checking"),
        &format!(
            "[INFO] Получение метаданных релиза {disp} ({})...",
            tag_opt.unwrap_or("latest")
        ),
    );
    let rel = fetch_component_release_json(core, canon, repo, tag_opt, proxy.as_deref())
        .await
        .map_err(|e| {
            component_error_payload(
                canon,
                action,
                job_id,
                &current,
                format!("Не удалось получить релиз {disp}: {e}"),
            )
        })?;

    let tag = rel
        .get("tag_name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let target_ver = tag.trim_start_matches(['v', 'V']).to_string();
    let release_url = rel
        .get("html_url")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let release_notes = rel
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    if action != "reinstall"
        && action != "install_version"
        && compare_versions(&current, &target_ver) == std::cmp::Ordering::Equal
    {
        let msg = format!("{disp} уже обновлён до версии {target_ver}");
        append_job_log(job_id, Some("completed"), &format!("[OK] {msg}"));
        let ok = json!({
            "success": true,
            "running": false,
            "completed": true,
            "kind": "component",
            "job_id": job_id,
            "component": canon,
            "action": action,
            "message": msg,
            "current_version": current,
            "latest_version": target_ver,
            "release_url": release_url,
            "release_notes": release_notes,
            "changed": false,
            "status": "latest",
            "exit_code": 0,
            "updated_at": now,
        });
        write_component_check_cache(canon, &ok);
        return Err(ok);
    }

    let assets = rel
        .get("assets")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let arch_kws = detect_arch_keywords();
    let Some((asset_name, asset_url)) = select_release_asset(assets, &arch_kws) else {
        return Err(component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Не найден архив {disp} для архитектуры {arch_kws:?} в релизе {tag}"),
        ));
    };

    append_job_log(
        job_id,
        Some("downloading"),
        &format!("[INFO] Скачивание {asset_name}..."),
    );
    let archive_bytes =
        fetch_url_with_mirror_and_proxy(core, &asset_url, &mirror, proxy.as_deref(), 90)
            .await
            .map_err(|e| {
                component_error_payload(
                    canon,
                    action,
                    job_id,
                    &current,
                    format!("Ошибка загрузки {asset_name}: {e}"),
                )
            })?;
    if archive_bytes.is_empty() {
        return Err(component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Скачан пустой файл {asset_name}"),
        ));
    }

    let sums_manifest: Option<String> = if let Some(sums_url) = find_sha256sums_url(assets) {
        append_job_log(
            job_id,
            Some("verifying"),
            "[INFO] Загрузка контрольных сумм SHA256SUMS...",
        );
        let sums_bytes =
            fetch_url_with_mirror_and_proxy(core, &sums_url, &mirror, proxy.as_deref(), 20)
                .await
                .map_err(|e| {
                    component_error_payload(
                        canon,
                        action,
                        job_id,
                        &current,
                        format!("Не удалось загрузить SHA256SUMS для проверки: {e}"),
                    )
                })?;
        Some(String::from_utf8_lossy(&sums_bytes).into_owned())
    } else {
        None
    };

    let stage_dir = PathBuf::from(format!("/tmp/tachyon-update-{job_id}"));
    let _ = std::fs::remove_dir_all(&stage_dir);
    if let Err(e) = std::fs::create_dir_all(&stage_dir) {
        return Err(component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Не удалось создать каталог распаковки: {e}"),
        ));
    }

    let archive_path = stage_dir.join(&asset_name);
    if let Err(e) = std::fs::write(&archive_path, &archive_bytes) {
        let _ = std::fs::remove_dir_all(&stage_dir);
        return Err(component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Не удалось записать архив во временный каталог: {e}"),
        ));
    }

    append_job_log(
        job_id,
        Some("extracting"),
        "[INFO] Распаковка и проверка бинарного файла...",
    );
    let lower_asset = asset_name.to_ascii_lowercase();
    let extracted_bin = if lower_asset.ends_with(".tar.gz") || lower_asset.ends_with(".tgz") {
        let mut cmd = Command::new("tar");
        cmd.arg("-xzf")
            .arg(&archive_path)
            .arg("-C")
            .arg(&stage_dir)
            .kill_on_drop(true);
        let out = tokio::time::timeout(Duration::from_secs(60), cmd.output()).await;
        match out {
            Ok(Ok(o)) if o.status.success() => {}
            Ok(Ok(o)) => {
                let err = String::from_utf8_lossy(&o.stderr).trim().to_string();
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(component_error_payload(
                    canon,
                    action,
                    job_id,
                    &current,
                    format!("Ошибка tar -xzf: {err}"),
                ));
            }
            Ok(Err(e)) => {
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(component_error_payload(
                    canon,
                    action,
                    job_id,
                    &current,
                    format!("Не удалось запустить tar: {e}"),
                ));
            }
            Err(_) => {
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(component_error_payload(
                    canon,
                    action,
                    job_id,
                    &current,
                    "Таймаут распаковки архива tar -xzf (60s)".to_string(),
                ));
            }
        }
        match find_extracted_binary(&stage_dir, expected_bin_name).await {
            Some(p) => p,
            None => {
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(component_error_payload(
                    canon,
                    action,
                    job_id,
                    &current,
                    format!("В архиве не найден бинарный файл {expected_bin_name}"),
                ));
            }
        }
    } else {
        archive_path.clone()
    };

    if let Some(manifest) = &sums_manifest {
        let bin_name = extracted_bin
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&asset_name);
        let mut candidates = vec![(asset_name.as_str(), sha256_hex_bytes(&archive_bytes))];
        if bin_name != asset_name {
            let Ok(bin_bytes) = std::fs::read(&extracted_bin) else {
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(component_error_payload(
                    canon,
                    action,
                    job_id,
                    &current,
                    "Не удалось прочитать распакованный бинарный файл для проверки SHA-256"
                        .to_string(),
                ));
            };
            candidates.push((bin_name, sha256_hex_bytes(&bin_bytes)));
        }
        match verify_sha256_for_candidates(manifest, &candidates) {
            Ok(matched_hash) => append_job_log(
                job_id,
                Some("verifying"),
                &format!("[OK] SHA-256 подтверждён: {matched_hash}"),
            ),
            Err(err) => {
                let _ = std::fs::remove_dir_all(&stage_dir);
                return Err(component_error_payload(
                    canon, action, job_id, &current, err,
                ));
            }
        }
    }

    let _ = Command::new("chmod")
        .arg("755")
        .arg(&extracted_bin)
        .output()
        .await;
    let ver_output = match run_command_checked(&extracted_bin, version_check_args).await {
        Ok(s) => s,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&stage_dir);
            return Err(component_error_payload(
                canon,
                action,
                job_id,
                &current,
                format!("Новый бинарный файл не прошёл проверку версии: {e}"),
            ));
        }
    };
    append_job_log(
        job_id,
        Some("verifying"),
        &format!(
            "[OK] Проверка версии новой сборки: {}",
            ver_output.lines().next().unwrap_or(&ver_output)
        ),
    );

    Ok(StagedRelease {
        stage_dir,
        extracted_bin,
        target_ver,
        release_url,
        release_notes,
        backup_enabled,
        current,
    })
}

async fn install_core_binary_release(
    core: &Arc<CoreManager>,
    job_id: &str,
    action: &str,
    tag_opt: Option<&str>,
) -> Value {
    let canon = "sing_box";
    let disp = "Tachyon Core";
    let core_bin_cfg = core.state.data.read().await.settings.core_bin_path.clone();
    let core_bin_path = if !core_bin_cfg.trim().is_empty() {
        PathBuf::from(core_bin_cfg.trim())
    } else {
        PathBuf::from("/usr/bin/tachyon-core")
    };

    let staged = match stage_release_binary(
        core,
        job_id,
        &StageReleaseSpec {
            canon,
            disp,
            repo: TACHYON_CORE_REPO,
            expected_bin_name: "tachyon-core",
            version_check_args: &["version"],
            action,
            tag_opt,
        },
    )
    .await
    {
        Ok(s) => s,
        Err(early_payload) => return early_payload,
    };

    let stage_dir = staged.stage_dir;
    let extracted_bin = staged.extracted_bin;
    let target_ver = staged.target_ver;
    let current = staged.current;

    if Path::new("/etc/tachyon-core/config.json").exists() {
        if let Err(e) = run_command_checked(
            &extracted_bin,
            &["check", "-c", "/etc/tachyon-core/config.json"],
        )
        .await
        {
            let _ = std::fs::remove_dir_all(&stage_dir);
            return component_error_payload(
                canon,
                action,
                job_id,
                &current,
                format!("Конфигурация не прошла проверку `check`: {e}"),
            );
        }
        append_job_log(
            job_id,
            Some("verifying"),
            "[OK] Текущая конфигурация совместима с новой версией",
        );
    }

    let data_dir = snapshots::data_dir_for_state(&core.state);
    if staged.backup_enabled && core_bin_path.is_file() {
        append_job_log(
            job_id,
            Some("backup"),
            &format!("[INFO] Создание резервной копии текущей версии ({current})..."),
        );
        let dd = data_dir.clone();
        let src = core_bin_path.clone();
        let cv = current.clone();
        let _ = tokio::task::spawn_blocking(move || {
            snapshots::backup_binary(&dd, "tachyon-core", &src, &cv)
        })
        .await;
    }

    append_job_log(
        job_id,
        Some("installing"),
        &format!(
            "[INFO] Установка {disp} {target_ver} в {}...",
            core_bin_path.display()
        ),
    );
    let _ = core.stop().await;
    let install_res = atomic_swap_binary(&extracted_bin, &core_bin_path);
    let _ = std::fs::remove_dir_all(&stage_dir);

    if let Err(e) = install_res {
        let _ = core.start().await;
        return component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Ошибка замены бинарного файла ядра: {e}"),
        );
    }

    let _ = crypto_gen::write_file_if_changed(
        "/etc/tachyon/tachyon-core-version",
        format!("{target_ver}\n").as_bytes(),
    );

    append_job_log(
        job_id,
        Some("restarting"),
        "[INFO] Запуск обновлённого ядра...",
    );
    if let Err(e) = core.start().await {
        append_job_log(
            job_id,
            Some("rollback"),
            &format!("[WARN] Ошибка запуска нового ядра ({e}), выполняю откат..."),
        );
        let dd = data_dir.clone();
        let dst = core_bin_path.clone();
        let _ = tokio::task::spawn_blocking(move || {
            snapshots::rollback_binary(&dd, "tachyon-core", &dst)
        })
        .await;
        let _ = crypto_gen::write_file_if_changed(
            "/etc/tachyon/tachyon-core-version",
            format!("{current}\n").as_bytes(),
        );
        let _ = core.start().await;
        core.refresh_core_version().await;
        return component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Новое ядро не запустилось ({e}); выполнен откат на {current}"),
        );
    }

    let final_ver = core.refresh_core_version().await;
    let display_ver = if final_ver.is_empty() {
        target_ver.clone()
    } else {
        final_ver
    };
    let msg = format!("{disp} успешно обновлён: {current} -> {display_ver}");
    append_job_log(job_id, Some("completed"), &format!("[OK] {msg}"));
    crate::tg_bot::queue_or_send_notification(format!("[Tachyon] {msg}"));

    let ok = json!({
        "success": true,
        "running": false,
        "completed": true,
        "kind": "component",
        "job_id": job_id,
        "component": canon,
        "action": action,
        "message": msg,
        "current_version": display_ver,
        "latest_version": target_ver,
        "release_url": staged.release_url,
        "release_notes": staged.release_notes,
        "changed": true,
        "status": "latest",
        "exit_code": 0,
        "updated_at": store::unix_now_secs(),
    });
    write_component_check_cache(canon, &ok);
    ok
}

fn schedule_tachyon_service_restart() {
    let init = PathBuf::from("/etc/init.d/tachyon");
    if !init.exists() {
        return;
    }
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1500)).await;
        let _ = Command::new(&init)
            .arg("restart")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    });
}

async fn install_tachyon_release(
    core: &Arc<CoreManager>,
    job_id: &str,
    action: &str,
    tag_opt: Option<&str>,
) -> Value {
    let canon = "tachyon";
    let disp = "Tachyon";
    let repo = tachyon_release_repo();
    let self_bin_path = resolve_tachyon_self_bin_path();

    let staged = match stage_release_binary(
        core,
        job_id,
        &StageReleaseSpec {
            canon,
            disp,
            repo: &repo,
            expected_bin_name: "tachyon",
            version_check_args: &["--version"],
            action,
            tag_opt,
        },
    )
    .await
    {
        Ok(s) => s,
        Err(early_payload) => return early_payload,
    };

    let stage_dir = staged.stage_dir;
    let extracted_bin = staged.extracted_bin;
    let target_ver = staged.target_ver;
    let current = staged.current;

    let data_dir = snapshots::data_dir_for_state(&core.state);
    if staged.backup_enabled && self_bin_path.is_file() {
        append_job_log(
            job_id,
            Some("backup"),
            &format!("[INFO] Создание резервной копии текущей версии ({current})..."),
        );
        let dd = data_dir.clone();
        let src = self_bin_path.clone();
        let cv = current.clone();
        let _ = tokio::task::spawn_blocking(move || {
            snapshots::backup_binary(&dd, "tachyon", &src, &cv)
        })
        .await;
    }

    append_job_log(
        job_id,
        Some("installing"),
        &format!(
            "[INFO] Установка {disp} {target_ver} в {}...",
            self_bin_path.display()
        ),
    );
    let swap_res = atomic_swap_binary(&extracted_bin, &self_bin_path);
    if let Err(e) = swap_res {
        let _ = std::fs::remove_dir_all(&stage_dir);
        return component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Ошибка замены бинарного файла {disp}: {e}"),
        );
    }

    let luci_updated = sync_staged_luci_assets(&stage_dir, Path::new("/"));
    let _ = std::fs::remove_dir_all(&stage_dir);
    if luci_updated > 0 {
        append_job_log(
            job_id,
            Some("installing"),
            &format!("[OK] Обновлено статических файлов LuCI: {luci_updated}"),
        );
    }

    let msg = format!("{disp} успешно обновлён: {current} -> {target_ver}");
    append_job_log(job_id, Some("completed"), &format!("[OK] {msg}"));
    crate::tg_bot::queue_or_send_notification(format!("[Tachyon] {msg}"));

    let restart_scheduled = Path::new("/etc/init.d/tachyon").exists();
    if restart_scheduled {
        append_job_log(
            job_id,
            Some("restarting"),
            "[INFO] Планирую перезапуск службы /etc/init.d/tachyon...",
        );
        schedule_tachyon_service_restart();
    }

    let ok = json!({
        "success": true,
        "running": false,
        "completed": true,
        "kind": "component",
        "job_id": job_id,
        "component": canon,
        "action": action,
        "message": msg,
        "current_version": target_ver,
        "latest_version": target_ver,
        "release_url": staged.release_url,
        "release_notes": staged.release_notes,
        "luci_files_updated": luci_updated,
        "restart_scheduled": restart_scheduled,
        "changed": true,
        "status": "latest",
        "exit_code": 0,
        "updated_at": store::unix_now_secs(),
    });
    write_component_check_cache(canon, &ok);
    ok
}

async fn run_component_job(
    core: Arc<CoreManager>,
    job_id: String,
    canon: String,
    action: String,
    arg: Option<String>,
) {
    let result = match (canon.as_str(), action.as_str()) {
        (_, "check_update" | "check") => perform_check_update(&core, &canon, Some(&job_id)).await,
        (
            "sing_box",
            "install"
            | "reinstall"
            | "install_tachyon_core"
            | "install_stable"
            | "install_extended"
            | "install_extended_compressed"
            | "install_tiny"
            | "install_lx",
        ) => install_core_binary_release(&core, &job_id, &action, None).await,
        ("sing_box", "install_version") => {
            install_core_binary_release(&core, &job_id, &action, arg.as_deref()).await
        }
        ("tachyon", "install" | "reinstall") => {
            install_tachyon_release(&core, &job_id, &action, None).await
        }
        ("tachyon", "install_version") => {
            install_tachyon_release(&core, &job_id, &action, arg.as_deref()).await
        }
        _ => {
            let sync_res = core.component_action(&canon, &action, arg.as_deref()).await;
            let ok = sync_res.get("ok").and_then(Value::as_bool).unwrap_or(true);
            let msg = sync_res
                .pointer("/result/message")
                .or_else(|| sync_res.pointer("/result/error"))
                .and_then(Value::as_str)
                .unwrap_or("Операция выполнена")
                .to_string();
            append_job_log(
                &job_id,
                Some(if ok { "completed" } else { "failed" }),
                &format!("{} {msg}", if ok { "[OK]" } else { "[ERR]" }),
            );
            let cur = current_component_version(&core, &canon).await;
            json!({
                "success": ok,
                "running": false,
                "completed": true,
                "kind": "component",
                "job_id": job_id,
                "component": canon,
                "action": action,
                "message": msg,
                "current_version": cur,
                "latest_version": cur,
                "changed": ok,
                "status": "",
                "exit_code": if ok { 0 } else { 1 },
                "result": sync_res,
                "updated_at": store::unix_now_secs(),
            })
        }
    };
    write_job_status(&job_id, &result);
}

pub async fn start_component_action(
    core: &Arc<CoreManager>,
    raw_comp: &str,
    raw_action: &str,
    arg: Option<&str>,
) -> Value {
    let canon = canonical_component(raw_comp);
    let disp = component_display_name(canon);
    let act = raw_action.trim();
    let now = store::unix_now_secs();
    let safe_act = sanitize_job_id(act);
    let job_slug = if canon == "sing_box" {
        "tachyon-core"
    } else {
        canon
    };
    let job_id = format!("comp-{job_slug}-{safe_act}-{now}");
    let cur = current_component_version(core, canon).await;
    let initial = json!({
        "success": true,
        "running": true,
        "completed": false,
        "kind": "component",
        "job_id": job_id,
        "component": canon,
        "action": act,
        "message": format!("Запуск '{act}' для {disp}..."),
        "current_version": cur,
        "latest_version": "",
        "changed": false,
        "status": "",
        "pid": std::process::id().to_string(),
        "started_at": now,
        "phase": "starting",
        "phase_started_at": now,
        "heartbeat_at": now,
        "updated_at": now,
        "exit_code": Value::Null,
    });
    write_job_status(&job_id, &initial);
    append_job_log(
        &job_id,
        Some("starting"),
        &format!("[INFO] Старт операции '{act}' для компонента {disp}"),
    );

    let core_c = core.clone();
    let jid_c = job_id.clone();
    let canon_c = canon.to_string();
    let act_c = act.to_string();
    let arg_c = arg.map(str::to_string);
    tokio::spawn(async move {
        run_component_job(core_c, jid_c, canon_c, act_c, arg_c).await;
    });
    initial
}

pub fn read_list_update_status() -> Value {
    if let Ok(raw) = std::fs::read_to_string(LIST_STATUS_PATH)
        && let Ok(val) = serde_json::from_str::<Value>(&raw)
    {
        return val;
    }
    json!({
        "success": true,
        "running": false,
        "completed": true,
        "progress": "completed",
        "message": "Готово",
        "exit_code": 0
    })
}

fn write_list_update_status(val: &Value) {
    ensure_runtime_dirs();
    if let Ok(raw) = serde_json::to_string_pretty(val) {
        let _ = std::fs::write(LIST_STATUS_PATH, raw);
    }
}

pub async fn start_list_update_async(core: &Arc<CoreManager>) -> Value {
    if LIST_UPDATE_IN_FLIGHT.swap(true, Ordering::SeqCst) {
        return read_list_update_status();
    }
    let now = store::unix_now_secs();
    let job_id = format!("rust-list-{now}");
    let initial = json!({
        "success": true,
        "job_id": job_id,
        "running": true,
        "completed": false,
        "progress": "starting",
        "message": "Подготовка обновления списков...",
        "started_at": now,
        "exit_code": Value::Null,
    });
    write_list_update_status(&initial);

    let core_c = core.clone();
    tokio::spawn(async move {
        write_list_update_status(&json!({
            "success": true,
            "job_id": job_id,
            "running": true,
            "completed": false,
            "progress": "downloading",
            "message": "Скачивание списков и наборов правил...",
            "started_at": now,
        }));
        let res = core_c.component_action("lists", "update", None).await;
        let ok = res.get("ok").and_then(Value::as_bool).unwrap_or(false);
        let msg = res
            .pointer("/result/message")
            .and_then(Value::as_str)
            .unwrap_or("Списки обновлены")
            .to_string();
        let cnt = res
            .pointer("/result/lists_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        write_list_update_status(&json!({
            "success": ok,
            "job_id": job_id,
            "running": false,
            "completed": true,
            "status": if ok { "completed" } else { "failed" },
            "progress": "applying",
            "message": msg,
            "updated": cnt,
            "updated_at": store::unix_now_secs(),
            "exit_code": if ok { 0 } else { 1 },
        }));
        LIST_UPDATE_IN_FLIGHT.store(false, Ordering::SeqCst);
    });
    initial
}

fn interval_to_secs(spec: &str) -> i64 {
    let s = spec.trim().to_ascii_lowercase();
    if let Some(h) = s.strip_suffix('h').and_then(|n| n.parse::<i64>().ok()) {
        return (h.max(1)) * 3600;
    }
    if let Some(d) = s.strip_suffix('d').and_then(|n| n.parse::<i64>().ok()) {
        return (d.max(1)) * 86400;
    }
    if let Some(m) = s.strip_suffix('m').and_then(|n| n.parse::<i64>().ok()) {
        return (m.max(5)) * 60;
    }
    12 * 3600
}

pub async fn maybe_run_auto_update_tick(core: &Arc<CoreManager>) {
    if AUTO_UPDATE_IN_FLIGHT.swap(true, Ordering::SeqCst) {
        return;
    }
    let _guard = ResetBoolOnDrop(&AUTO_UPDATE_IN_FLIGHT);

    let (
        check_enabled,
        check_interval,
        auto_enabled,
        auto_mode,
        win_start,
        win_end,
        max_conns,
        max_clients,
        targets,
    ) = {
        let d = core.state.data.read().await;
        (
            d.settings.component_update_check_enabled,
            d.settings.component_update_check_interval.clone(),
            d.settings.component_auto_update_enabled,
            d.settings.component_auto_update_mode.clone(),
            d.settings.component_auto_update_window_start.clone(),
            d.settings.component_auto_update_window_end.clone(),
            d.settings.component_auto_update_max_connections,
            d.settings.component_auto_update_max_clients,
            d.settings.component_auto_update_targets.clone(),
        )
    };

    if !check_enabled && !auto_enabled {
        return;
    }

    let now = store::unix_now_secs();
    let check_ttl = interval_to_secs(&check_interval);
    let core_cache = Path::new(CHECK_CACHE_DIR).join("sing_box.json");
    let cache_stale = std::fs::read_to_string(&core_cache)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.get("updated_at").and_then(Value::as_i64))
        .map(|ts| now.saturating_sub(ts) >= check_ttl)
        .unwrap_or(true);

    if cache_stale {
        let _ = perform_check_update(core, "sing_box", None).await;
        let _ = perform_check_update(core, "tachyon", None).await;
    }

    if !auto_enabled {
        return;
    }

    if auto_mode.eq_ignore_ascii_case("scheduled") {
        let hhmm = local_hhmm_now();
        if !is_within_update_window(&hhmm, &win_start, &win_end) {
            return;
        }
    }

    if max_conns > 0 || max_clients > 0 {
        let (conns, clients) = read_conntrack_load();
        if (max_conns > 0 && conns > max_conns) || (max_clients > 0 && clients > max_clients) {
            return;
        }
    }

    let wants_core =
        targets.is_empty() || targets.iter().any(|t| canonical_component(t) == "sing_box");
    if wants_core {
        let outdated = std::fs::read_to_string(&core_cache)
            .ok()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            .and_then(|v| v.get("status").and_then(Value::as_str).map(str::to_string))
            .is_some_and(|s| s == "outdated");
        if outdated {
            let job = start_component_action(core, "sing_box", "install", None).await;
            let jid = job
                .get("job_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if !jid.is_empty() {
                for _ in 0..45 {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    let st = read_job_status(&jid);
                    if st.get("running").and_then(Value::as_bool) != Some(true) {
                        break;
                    }
                }
            }
        }
    }
}

struct ResetBoolOnDrop<'a>(&'a AtomicBool);
impl Drop for ResetBoolOnDrop<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version_comparison_and_status() {
        assert_eq!(
            compare_versions("0.4.8", "v0.5.1"),
            std::cmp::Ordering::Less
        );
        assert_eq!(
            compare_versions("v0.5.1", "0.5.1"),
            std::cmp::Ordering::Equal
        );
        assert_eq!(
            compare_versions("2.0.0", "1.7.27"),
            std::cmp::Ordering::Greater
        );
        assert_eq!(
            compare_versions("0.5.1-rc1", "0.5.1"),
            std::cmp::Ordering::Less
        );
        assert_eq!(classify_version_status("0.4.8", "0.5.1"), "outdated");
        assert_eq!(classify_version_status("0.5.1", "0.5.1"), "latest");
    }

    #[test]
    fn test_arch_mapping_and_asset_selection() {
        assert_eq!(
            map_arch_str_to_keywords("DISTRIB_ARCH='aarch64_generic'")[0],
            "aarch64"
        );
        assert_eq!(map_arch_str_to_keywords("mipsel_24kc")[0], "mipsel");
        assert_eq!(map_arch_str_to_keywords("mips_24kc")[0], "mips");
        assert_eq!(
            map_arch_str_to_keywords("DISTRIB_ARCH='i386_pentium4'")[0],
            "i386_pentium4"
        );
        assert_eq!(map_arch_str_to_keywords("x86_64")[0], "x86_64");
        let assets = vec![
            json!({ "name": "SHA256SUMS", "browser_download_url": "https://example/SHA256SUMS" }),
            json!({ "name": "libtachyon-arm64-v8a.so", "browser_download_url": "https://example/lib.so" }),
            json!({ "name": "tachyon-core-aarch64-linux-android-v0.5.1.tar.gz", "browser_download_url": "https://example/android.tar.gz" }),
            json!({ "name": "tachyon-core-aarch64-v0.5.1.ipk", "browser_download_url": "https://example/aarch64.ipk" }),
            json!({ "name": "tachyon-core-x86_64-v0.5.1.tar.gz", "browser_download_url": "https://example/x86.tar.gz" }),
            json!({ "name": "tachyon-core-aarch64-v0.5.1.tar.gz", "browser_download_url": "https://example/aarch64.tar.gz" }),
        ];
        let picked = select_release_asset(&assets, &["aarch64", "arm64"]).unwrap();
        assert_eq!(picked.0, "tachyon-core-aarch64-v0.5.1.tar.gz");
        assert!(find_sha256sums_url(&assets).is_some());

        // 32-bit x86 / i386_pentium4 must never pick x86_64/amd64 binaries even when "x86" keyword matches
        let x86_assets = vec![
            json!({ "name": "tachyon-core-x86_64-v0.5.2.tar.gz", "browser_download_url": "https://example/x86_64.tar.gz" }),
            json!({ "name": "tachyon-core-amd64-v0.5.2.tar.gz", "browser_download_url": "https://example/amd64.tar.gz" }),
        ];
        assert!(
            select_release_asset(&x86_assets, &map_arch_str_to_keywords("i386_pentium4")).is_none()
        );

        let mixed_x86_assets = vec![
            json!({ "name": "tachyon-core-x86_64-v0.5.2.tar.gz", "browser_download_url": "https://example/x86_64.tar.gz" }),
            json!({ "name": "tachyon-core-i386-v0.5.2.tar.gz", "browser_download_url": "https://example/i386.tar.gz" }),
        ];
        let picked_386 = select_release_asset(
            &mixed_x86_assets,
            &map_arch_str_to_keywords("i386_pentium4"),
        )
        .unwrap();
        assert_eq!(picked_386.0, "tachyon-core-i386-v0.5.2.tar.gz");
    }

    #[test]
    fn test_sha256_manifest_verification() {
        let digest = sha256_hex_bytes(b"tachyon");
        let manifest = format!("{digest}  tachyon-core-aarch64-v0.5.1.tar.gz\n");
        assert!(
            verify_sha256_against_manifest(
                &manifest,
                "tachyon-core-aarch64-v0.5.1.tar.gz",
                &digest
            )
            .is_ok()
        );
        assert!(
            verify_sha256_against_manifest(
                &manifest,
                "tachyon-core-aarch64-v0.5.1.tar.gz",
                "0000000000000000000000000000000000000000000000000000000000000000"
            )
            .is_err()
        );
    }

    #[test]
    fn test_update_window_midnight_wrap() {
        assert!(is_within_update_window("03:30", "02:00", "06:00"));
        assert!(!is_within_update_window("12:00", "02:00", "06:00"));
        assert!(is_within_update_window("23:45", "23:00", "05:00"));
        assert!(is_within_update_window("04:15", "23:00", "05:00"));
        assert!(!is_within_update_window("18:00", "23:00", "05:00"));
    }

    #[test]
    fn test_atom_and_expanded_assets_and_candidate_sha256() {
        let atom = r#"<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>tag:github.com,2008:Repository/1/v0.5.1</id>
    <updated>2026-11-12T19:20:03Z</updated>
    <link rel="alternate" type="text/html" href="https://github.com/Dushnilin/tachyon-core/releases/tag/v0.5.1"/>
    <title>tachyon-core v0.5.1</title>
    <content type="html">&lt;ul&gt;&lt;li&gt;Fix 1&lt;/li&gt;&lt;/ul&gt;</content>
  </entry>
</feed>"#;
        let items = parse_releases_atom(atom, "Dushnilin/tachyon-core");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["tag"], "v0.5.1");
        assert_eq!(items[0]["version"], "0.5.1");
        assert!(items[0]["body"].as_str().unwrap().contains("- Fix 1"));

        let html = r#"<a href="/Dushnilin/tachyon-core/releases/download/v0.5.1/SHA256SUMS">s</a>
<a href="/Dushnilin/tachyon-core/releases/download/v0.5.1/tachyon-core-aarch64-v0.5.1.tar.gz">b</a>"#;
        let assets = parse_expanded_assets_html(html, "Dushnilin/tachyon-core", "v0.5.1");
        assert_eq!(assets.len(), 2);
        let picked = select_release_asset(&assets, &["aarch64"]).unwrap();
        assert_eq!(picked.0, "tachyon-core-aarch64-v0.5.1.tar.gz");
        assert!(find_sha256sums_url(&assets).is_some());

        let bin_digest = sha256_hex_bytes(b"binary-elf");
        let manifest = format!("{bin_digest}  ./tachyon-core-aarch64-v0.5.1\n");
        let res = verify_sha256_for_candidates(
            &manifest,
            &[
                (
                    "tachyon-core-aarch64-v0.5.1.tar.gz",
                    sha256_hex_bytes(b"tarball"),
                ),
                ("tachyon-core-aarch64-v0.5.1", bin_digest.clone()),
            ],
        );
        assert_eq!(res.unwrap(), bin_digest);
    }

    #[test]
    fn test_tachyon_release_repo_and_self_update_staging() {
        assert_eq!(component_repo("tachyon"), tachyon_release_repo());
        if std::env::var("TACHYON_RELEASE_REPO")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .is_none()
        {
            assert_eq!(tachyon_release_repo(), "Dushnilin/tachyon");
        }

        let assets = vec![
            json!({
                "name": "tachyon_2.0.0_aarch64_generic.ipk",
                "browser_download_url": "https://example/tachyon.ipk"
            }),
            json!({
                "name": "tachyon-aarch64-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-aarch64-v2.0.0.tar.gz"
            }),
        ];
        let picked = select_release_asset(&assets, &["aarch64"]).unwrap();
        assert_eq!(picked.0, "tachyon-aarch64-v2.0.0.tar.gz");

        let mips_assets = vec![
            json!({
                "name": "tachyon-mipsel-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-mipsel.tar.gz"
            }),
            json!({
                "name": "tachyon-mips-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-mips.tar.gz"
            }),
        ];
        assert_eq!(
            select_release_asset(&mips_assets, &["mips"]).unwrap().0,
            "tachyon-mips-v2.0.0.tar.gz"
        );
        assert_eq!(
            select_release_asset(&mips_assets, &["mipsel"]).unwrap().0,
            "tachyon-mipsel-v2.0.0.tar.gz"
        );

        let arm_assets = vec![
            json!({
                "name": "tachyon-aarch64-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-aarch64.tar.gz"
            }),
            json!({
                "name": "tachyon-armv7-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-armv7.tar.gz"
            }),
            json!({
                "name": "tachyon-armv6-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-armv6.tar.gz"
            }),
        ];
        assert_eq!(
            select_release_asset(&arm_assets, &["arm"]).unwrap().0,
            "tachyon-armv6-v2.0.0.tar.gz"
        );

        let base = std::env::temp_dir().join(format!(
            "tachyon_self_upd_{}",
            crate::store::unix_now_secs()
        ));
        let stage = base.join("stage");
        let target_root = base.join("root");
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(stage.join("usr/bin")).unwrap();
        std::fs::create_dir_all(stage.join("usr/share/tachyon")).unwrap();
        std::fs::create_dir_all(stage.join("www/luci-static/resources/view/tachyon")).unwrap();
        std::fs::create_dir_all(stage.join("htdocs/luci-static/resources/view/tachyon")).unwrap();
        std::fs::write(stage.join("tachyon-aarch64-v2.0.0.tar.gz"), b"tar").unwrap();
        std::fs::write(stage.join("usr/bin/tachyon"), b"elf").unwrap();
        std::fs::write(
            stage.join("usr/share/tachyon/tachyon.ru.po"),
            b"msgid \"x\"\nmsgstr \"y\"\n",
        )
        .unwrap();
        std::fs::write(
            stage.join("www/luci-static/resources/view/tachyon/main.js"),
            b"console.log(1);",
        )
        .unwrap();
        std::fs::write(
            stage.join("htdocs/luci-static/resources/view/tachyon/updates.js"),
            b"console.log(2);",
        )
        .unwrap();

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let found = rt
            .block_on(find_extracted_binary(&stage, "tachyon"))
            .unwrap();
        assert_eq!(found, stage.join("usr/bin/tachyon"));

        let first_sync = sync_staged_luci_assets(&stage, &target_root);
        assert_eq!(first_sync, 3);
        assert!(target_root.join("usr/share/tachyon/tachyon.ru.po").exists());
        assert!(
            target_root
                .join("www/luci-static/resources/view/tachyon/main.js")
                .exists()
        );
        assert!(
            target_root
                .join("www/luci-static/resources/view/tachyon/updates.js")
                .exists()
        );

        // Second identical sync must skip all flash writes
        let second_sync = sync_staged_luci_assets(&stage, &target_root);
        assert_eq!(second_sync, 0);

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn test_semver_prerelease_and_v2_release_selection() {
        use std::cmp::Ordering;

        assert!(is_tachyon_v2_or_newer("v2.0.0-beta.1"));
        assert!(is_tachyon_v2_or_newer("2.0.0"));
        assert!(!is_tachyon_v2_or_newer("v1.7.30"));
        assert!(!is_tachyon_v2_or_newer("1.9.99"));
        assert!(!is_tachyon_v2_or_newer(""));

        assert_eq!(
            compare_versions("2.0.0-alpha.1", "2.0.0-beta.2"),
            Ordering::Less
        );
        assert_eq!(
            compare_versions("2.0.0-beta.2", "2.0.0-beta.10"),
            Ordering::Less
        );
        assert_eq!(
            compare_versions("2.0.0-beta.10", "2.0.0-rc.1"),
            Ordering::Less
        );
        assert_eq!(compare_versions("2.0.0-rc.1", "2.0.0"), Ordering::Less);
        assert_eq!(compare_versions("1.7.30", "2.0.0-beta.1"), Ordering::Less);
        assert_eq!(
            compare_versions("v2.0.0-beta.1", "2.0.0-beta.1"),
            Ordering::Equal
        );

        let mixed_releases = vec![
            json!({ "tag_name": "1.7.30", "prerelease": false, "draft": false }),
            json!({ "tag_name": "v2.0.0-beta.2", "prerelease": true, "draft": false }),
            json!({ "tag_name": "v2.0.0-beta.10", "prerelease": true, "draft": false }),
            json!({ "tag_name": "v2.0.0-rc.1", "prerelease": true, "draft": true }),
        ];
        assert!(pick_best_tachyon_v2_release(&mixed_releases, false).is_none());
        let picked_beta = pick_best_tachyon_v2_release(&mixed_releases, true).unwrap();
        assert_eq!(picked_beta["tag_name"], "v2.0.0-beta.10");

        let with_stable = vec![
            json!({ "tag_name": "1.7.30", "prerelease": false, "draft": false }),
            json!({ "tag_name": "v2.0.0-beta.10", "prerelease": true, "draft": false }),
            json!({ "tag_name": "v2.0.0", "prerelease": false, "draft": false }),
            json!({ "tag_name": "v2.0.1-alpha.1", "prerelease": true, "draft": false }),
        ];
        assert_eq!(
            pick_best_tachyon_v2_release(&with_stable, false).unwrap()["tag_name"],
            "v2.0.0"
        );
        assert_eq!(
            pick_best_tachyon_v2_release(&with_stable, true).unwrap()["tag_name"],
            "v2.0.1-alpha.1"
        );
    }

    #[test]
    fn test_select_release_asset_all_openwrt_arches() {
        let mut assets = Vec::new();
        for arch in [
            "x86_64",
            "i386_pentium4",
            "aarch64",
            "armv7",
            "armv6",
            "riscv64",
            "mipsel",
            "mips",
        ] {
            assets.push(json!({
                "name": format!("tachyon-{arch}-v2.0.0-beta.1.tar.gz"),
                "browser_download_url": format!("https://example/tachyon-{arch}.tar.gz"),
            }));
            assets.push(json!({
                "name": format!("tachyon_2.0.0~beta.1-1_{arch}.ipk"),
                "browser_download_url": format!("https://example/tachyon-{arch}.ipk"),
            }));
            assets.push(json!({
                "name": format!("tachyon-2.0.0_beta1-r1_{arch}.apk"),
                "browser_download_url": format!("https://example/tachyon-{arch}.apk"),
            }));
        }

        let cases = [
            (
                "DISTRIB_ARCH='x86_64'",
                "tachyon-x86_64-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='i386_pentium4'",
                "tachyon-i386_pentium4-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='aarch64_cortex-a53'",
                "tachyon-aarch64-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='arm_cortex-a7_neon-vfpv4'",
                "tachyon-armv7-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='arm_mpcore'",
                "tachyon-armv6-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='riscv64_riscv64'",
                "tachyon-riscv64-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='mipsel_24kc'",
                "tachyon-mipsel-v2.0.0-beta.1.tar.gz",
            ),
            (
                "DISTRIB_ARCH='mips_24kc'",
                "tachyon-mips-v2.0.0-beta.1.tar.gz",
            ),
        ];
        for (distrib_arch, expected) in cases {
            let kws = map_arch_str_to_keywords(distrib_arch);
            let picked = select_release_asset(&assets, &kws).unwrap();
            assert_eq!(
                picked.0, expected,
                "failed for {distrib_arch} (kws={kws:?})"
            );
        }
    }
}
