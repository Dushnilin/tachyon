use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;
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

pub fn resolve_known_component(raw: &str) -> Option<&'static str> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "tachyon" | "luci-app-tachyon" => Some("tachyon"),
        "tachyon-core" | "tachyon_core" | "tachyoncore" | "sing-box" | "sing_box" | "singbox"
        | "core" => Some("sing_box"),
        "lists" | "rulesets" | "tachyon-lists" | "tachyon_lists" => Some("lists"),
        "subscriptions" | "subs" => Some("subscriptions"),
        _ => None,
    }
}

pub fn canonical_component(raw: &str) -> &'static str {
    resolve_known_component(raw).unwrap_or("sing_box")
}

pub fn public_component_name(comp: &str) -> &'static str {
    match canonical_component(comp) {
        "sing_box" => "tachyon-core",
        other => other,
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

pub fn is_update_available_status(status: &str) -> bool {
    matches!(status, "outdated" | "outdated_same_release")
}

pub fn is_valid_commit_sha(raw: &str) -> bool {
    let trimmed = raw.trim();
    (7..=40).contains(&trimmed.len()) && trimmed.bytes().all(|b| b.is_ascii_hexdigit())
}

fn short_sha(sha: &str) -> &str {
    let trimmed = sha.trim();
    let n = trimmed.len().min(8);
    &trimmed[..n]
}

fn attach_build_metadata(
    payload: &mut Value,
    current_sha: &str,
    latest_sha: &str,
    current_build: &str,
    latest_build: &str,
) {
    let Some(map) = payload.as_object_mut() else {
        return;
    };
    if !current_sha.trim().is_empty() {
        map.insert("current_sha".to_string(), json!(current_sha.trim()));
    }
    if !latest_sha.trim().is_empty() {
        map.insert("latest_sha".to_string(), json!(latest_sha.trim()));
    }
    if !current_build.trim().is_empty() {
        map.insert("current_build".to_string(), json!(current_build.trim()));
    }
    if !latest_build.trim().is_empty() {
        map.insert("latest_build".to_string(), json!(latest_build.trim()));
    }
}

fn format_installed_release_msg(
    disp: &str,
    current: &str,
    display_ver: &str,
    local_sha: &str,
    remote_sha: &str,
) -> String {
    if compare_versions(current, display_ver) == std::cmp::Ordering::Equal {
        if !local_sha.is_empty()
            && !remote_sha.is_empty()
            && !short_sha(local_sha).eq_ignore_ascii_case(short_sha(remote_sha))
        {
            format!(
                "{disp} успешно обновлён до новой сборки {display_ver} ({} -> {})",
                short_sha(local_sha),
                short_sha(remote_sha)
            )
        } else {
            format!("{disp} успешно обновлён до новой сборки {display_ver}")
        }
    } else {
        format!("{disp} успешно обновлён: {current} -> {display_ver}")
    }
}

fn clean_sha_token(tok: &str) -> &str {
    tok.trim_matches(|c: char| matches!(c, '`' | '\'' | '"' | ',' | '.' | ';' | ')' | '('))
}

pub fn extract_release_commit_sha(rel: &Value) -> String {
    if let Some(tc) = rel.get("target_commitish").and_then(Value::as_str)
        && is_valid_commit_sha(tc)
    {
        return tc.trim().to_ascii_lowercase();
    }

    let body = rel.get("body").and_then(Value::as_str).unwrap_or("");
    if body.is_empty() {
        return String::new();
    }

    // Pass 1: trailer / standalone metadata line ("Commit: <sha>" or "SHA: <sha>") — pick last match.
    let mut trailer_match: Option<String> = None;
    for raw_line in body.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();
        let after_prefix = if lower.starts_with("commit:") || lower.starts_with("commit ") {
            trimmed.get(7..).map(str::trim)
        } else if lower.starts_with("sha:") || lower.starts_with("sha ") {
            trimmed.get(4..).map(str::trim)
        } else {
            None
        };
        if let Some(rest) = after_prefix
            && let Some(first_tok) = rest.split_whitespace().next()
        {
            let clean = clean_sha_token(first_tok);
            if is_valid_commit_sha(clean) {
                trailer_match = Some(clean.to_ascii_lowercase());
            }
        }
    }
    if let Some(found) = trailer_match {
        return found;
    }

    // Pass 2: "/commit/<hex>" URL fallback — pick last valid match.
    let mut url_match: Option<String> = None;
    let mut cursor = body;
    while let Some(pos) = cursor.find("/commit/") {
        let after = &cursor[pos + "/commit/".len()..];
        let hex: String = after
            .chars()
            .take(40)
            .take_while(|c| c.is_ascii_hexdigit())
            .collect();
        if is_valid_commit_sha(&hex) {
            url_match = Some(hex.to_ascii_lowercase());
        }
        cursor = after;
    }
    url_match.unwrap_or_default()
}

pub fn compute_release_build_fingerprint(
    rel: &Value,
    arch_keywords: &[&str],
    prefer_ext: &str,
    remote_sha: &str,
) -> String {
    if is_valid_commit_sha(remote_sha) {
        return format!("sha:{}", remote_sha.trim().to_ascii_lowercase());
    }

    let published = rel
        .get("published_at")
        .or_else(|| rel.get("created_at"))
        .or_else(|| rel.get("published"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();

    let assets = rel
        .get("assets")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);

    let selected_asset = if crate::platform::is_entware() {
        select_entware_tachyon_asset(assets, arch_keywords)
            .or_else(|| select_entware_core_asset(assets, arch_keywords))
    } else {
        select_openwrt_package_asset(assets, arch_keywords, prefer_ext)
    };
    if let Some((asset_name, _)) = selected_asset
        && let Some(asset) = assets
            .iter()
            .find(|a| a.get("name").and_then(Value::as_str) == Some(asset_name.as_str()))
    {
        if let Some(hex_digest) = asset
            .get("digest")
            .and_then(Value::as_str)
            .and_then(|d| d.trim().strip_prefix("sha256:"))
            .map(str::trim)
            .filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
        {
            return format!("digest:{}", hex_digest.to_ascii_lowercase());
        }

        let mut parts: Vec<String> = Vec::new();
        if !published.is_empty() {
            parts.push(published.to_string());
        }
        let updated = asset
            .get("updated_at")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if !updated.is_empty() {
            parts.push(updated.to_string());
        }
        if let Some(size) = asset.get("size").and_then(Value::as_u64)
            && size > 0
        {
            parts.push(size.to_string());
        }
        if !parts.is_empty() {
            return format!("build:{}", parts.join("|"));
        }
    }

    if !published.is_empty() {
        return format!("build:{published}");
    }
    String::new()
}

pub fn same_release_build_differs(
    local_sha: &str,
    remote_sha: &str,
    local_fp: &str,
    remote_fp: &str,
) -> bool {
    let l_sha = local_sha.trim().to_ascii_lowercase();
    let r_sha = remote_sha.trim().to_ascii_lowercase();
    if is_valid_commit_sha(&l_sha) && is_valid_commit_sha(&r_sha) {
        let prefix_len = l_sha.len().min(r_sha.len());
        return l_sha[..prefix_len] != r_sha[..prefix_len];
    }

    let l_fp = local_fp.trim();
    let r_fp = remote_fp.trim();
    if !l_fp.is_empty() && !r_fp.is_empty() {
        return l_fp != r_fp;
    }

    false
}

fn build_state_path(data_dir: &Path) -> PathBuf {
    data_dir.join("build-state.json")
}

fn read_installed_build_entry(
    data_dir: &Path,
    canon: &str,
    current_version: &str,
) -> (String, String) {
    let cur = current_version.trim();
    if cur.is_empty() {
        return (String::new(), String::new());
    }
    let path = build_state_path(data_dir);
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return (String::new(), String::new());
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return (String::new(), String::new());
    };
    let Some(entry) = val.get(canon).and_then(Value::as_object) else {
        return (String::new(), String::new());
    };
    let rec_ver = entry.get("version").and_then(Value::as_str).unwrap_or("");
    if rec_ver.trim().is_empty() || compare_versions(rec_ver, cur) != std::cmp::Ordering::Equal {
        return (String::new(), String::new());
    }
    let sha = entry
        .get("sha")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| is_valid_commit_sha(s))
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    let fp = entry
        .get("fingerprint")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    (sha, fp)
}

fn write_installed_build_entry(
    data_dir: &Path,
    canon: &str,
    version: &str,
    sha: &str,
    fingerprint: &str,
) {
    let ver = version.trim();
    let clean_sha = sha.trim().to_ascii_lowercase();
    let clean_fp = fingerprint.trim();
    if ver.is_empty() || (clean_sha.is_empty() && clean_fp.is_empty()) {
        return;
    }
    let path = build_state_path(data_dir);
    let mut root_map = std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Map<String, Value>>(&s).ok())
        .unwrap_or_default();
    let mut entry = serde_json::Map::new();
    entry.insert("version".to_string(), json!(ver));
    if is_valid_commit_sha(&clean_sha) {
        entry.insert("sha".to_string(), json!(clean_sha));
    }
    if !clean_fp.is_empty() {
        entry.insert("fingerprint".to_string(), json!(clean_fp));
    }
    root_map.insert(canon.to_string(), Value::Object(entry));
    if let Ok(serialized) = serde_json::to_string_pretty(&Value::Object(root_map)) {
        let _ = crypto_gen::write_file_if_changed(&path, serialized.as_bytes());
    }
}

fn resolve_local_build_identity(
    core: &Arc<CoreManager>,
    canon: &str,
    current_version: &str,
) -> (String, String) {
    if canon == "tachyon" && is_valid_commit_sha(store::TACHYON_COMMIT_SHA) {
        let compiled_sha = store::TACHYON_COMMIT_SHA.trim().to_ascii_lowercase();
        let compiled_fp = format!("sha:{compiled_sha}");
        return (compiled_sha, compiled_fp);
    }
    let data_dir = snapshots::data_dir_for_state(&core.state);
    read_installed_build_entry(&data_dir, canon, current_version)
}

async fn fetch_github_tag_commit_sha(
    core: &Arc<CoreManager>,
    repo: &str,
    tag: &str,
    proxy: Option<&str>,
) -> String {
    let clean_tag = tag.trim();
    if repo.trim().is_empty() || clean_tag.is_empty() {
        return String::new();
    }
    let url = format!("https://api.github.com/repos/{repo}/commits/{clean_tag}");
    if let Ok(bytes) = core
        .curl_fetch_with_doh_fallback(&url, false, 8, proxy)
        .await
        && let Ok(val) = serde_json::from_slice::<Value>(&bytes)
        && let Some(sha) = val.get("sha").and_then(Value::as_str)
        && is_valid_commit_sha(sha)
    {
        return sha.trim().to_ascii_lowercase();
    }
    String::new()
}

async fn resolve_remote_build_identity(
    core: &Arc<CoreManager>,
    repo: &str,
    tag: &str,
    rel: &Value,
    proxy: Option<&str>,
) -> (String, String) {
    let mut remote_sha = extract_release_commit_sha(rel);
    if remote_sha.is_empty() && !tag.trim().is_empty() {
        remote_sha = fetch_github_tag_commit_sha(core, repo, tag, proxy).await;
    }
    let remote_fp = compute_release_build_fingerprint(
        rel,
        &detect_arch_keywords(),
        preferred_openwrt_pkg_ext(),
        &remote_sha,
    );
    (remote_sha, remote_fp)
}

/// Parse Entware `/opt/bin/opkg print-architecture` output and pick the highest-priority
/// non-generic architecture token (e.g. `mipsel-3.4`, `aarch64-3.10`, `armv7sf-3.2`, `x64-3.2`).
pub fn parse_entware_opkg_arch(raw: &str) -> Option<String> {
    let mut best: Option<(u32, String)> = None;
    for line in raw.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 && parts[0] == "arch" {
            let arch = parts[1].trim();
            if arch.is_empty()
                || arch.eq_ignore_ascii_case("all")
                || arch.eq_ignore_ascii_case("noarch")
            {
                continue;
            }
            let prio = parts
                .get(2)
                .and_then(|p| p.parse::<u32>().ok())
                .unwrap_or(1);
            if best.as_ref().is_none_or(|(bp, _)| prio >= *bp) {
                best = Some((prio, arch.to_string()));
            }
        }
    }
    best.map(|(_, a)| a)
}

pub fn detect_arch_keywords() -> Vec<&'static str> {
    if crate::platform::is_entware() {
        let mut ent_raw = String::new();
        let opkg_path = crate::platform::paths().bin_dir.join("opkg");
        let opkg_candidates = [opkg_path.as_path(), Path::new("/opt/bin/opkg")];
        for opkg_bin in opkg_candidates {
            if opkg_bin.is_file()
                && let Ok(out) = std::process::Command::new(opkg_bin)
                    .arg("print-architecture")
                    .output()
                && out.status.success()
            {
                let text = String::from_utf8_lossy(&out.stdout);
                if let Some(arch) = parse_entware_opkg_arch(&text) {
                    ent_raw.push_str(&arch);
                    ent_raw.push('\n');
                    break;
                }
            }
        }
        let entware_release_path = crate::platform::paths().root.join("etc/entware_release");
        for rel_path in [
            entware_release_path.as_path(),
            Path::new("/opt/etc/entware_release"),
        ] {
            if let Ok(rel) = std::fs::read_to_string(rel_path) {
                ent_raw.push_str(&rel);
                ent_raw.push('\n');
                break;
            }
        }
        if !ent_raw.trim().is_empty() {
            return map_arch_str_to_keywords(&ent_raw);
        }
    }

    let mut raw = String::new();
    if let Ok(rel) = std::fs::read_to_string("/etc/openwrt_release") {
        raw.push_str(&rel);
        raw.push('\n');
    }
    if let Ok(ent_rel) = std::fs::read_to_string("/opt/etc/entware_release") {
        raw.push_str(&ent_rel);
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
    let has_entware_x64 = lower.contains("x64-")
        || lower.contains("x64_")
        || lower == "x64"
        || lower
            .split(|c: char| !c.is_ascii_alphanumeric())
            .any(|tok| tok == "x64");
    if lower.contains("aarch64") || lower.contains("arm64") {
        vec!["aarch64", "arm64"]
    } else if lower.contains("x86_64") || lower.contains("amd64") || has_entware_x64 {
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

fn is_32bit_x86_keywords(arch_keywords: &[&str]) -> bool {
    arch_keywords.iter().any(|k| {
        matches!(
            *k,
            "i386_pentium4" | "386" | "i386" | "i586" | "i686" | "x86"
        )
    }) && !arch_keywords
        .iter()
        .any(|k| matches!(*k, "x86_64" | "amd64" | "linux-amd64"))
}

fn is_excluded_base_asset(lower: &str, is_32bit_x86_target: bool) -> bool {
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
}

fn asset_arch_matches(lower: &str, kw: &str) -> bool {
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
}

fn find_matching_asset<F>(
    assets: &[Value],
    arch_keywords: &[&str],
    ext_pred: F,
) -> Option<(String, String)>
where
    F: Fn(&str) -> bool,
{
    let is_32bit_x86_target = is_32bit_x86_keywords(arch_keywords);
    for kw in arch_keywords {
        for a in assets {
            let name = a.get("name").and_then(Value::as_str).unwrap_or("");
            let url = a
                .get("browser_download_url")
                .and_then(Value::as_str)
                .unwrap_or("");
            let lower = name.to_ascii_lowercase();
            if url.is_empty() || is_excluded_base_asset(&lower, is_32bit_x86_target) {
                continue;
            }
            if asset_arch_matches(&lower, kw) && ext_pred(&lower) {
                return Some((name.to_string(), url.to_string()));
            }
        }
    }
    None
}

pub fn preferred_openwrt_pkg_ext() -> &'static str {
    if Path::new("/lib/apk/db").is_dir() {
        ".apk"
    } else {
        ".ipk"
    }
}

/// Select an Entware bundle archive (`tachyon-entware-<arch>-v<ver>.tar.gz`) matching `arch_keywords`.
pub fn select_entware_tachyon_asset(
    assets: &[Value],
    arch_keywords: &[&str],
) -> Option<(String, String)> {
    find_matching_asset(assets, arch_keywords, |lower| {
        lower.starts_with("tachyon-entware-")
            && (lower.ends_with(".tar.gz") || lower.ends_with(".tgz"))
    })
}

/// Select a `tachyon-core` tarball for Entware, preferring `*-musl.tar.gz` before generic `.tar.gz`.
pub fn select_entware_core_asset(
    assets: &[Value],
    arch_keywords: &[&str],
) -> Option<(String, String)> {
    find_matching_asset(assets, arch_keywords, |lower| {
        lower.ends_with(".tar.gz")
            && lower.contains("musl")
            && !lower.starts_with("tachyon-entware-")
    })
    .or_else(|| {
        find_matching_asset(assets, arch_keywords, |lower| {
            lower.ends_with(".tar.gz")
                && !lower.ends_with(".ipk")
                && !lower.ends_with(".apk")
                && !lower.starts_with("tachyon-entware-")
        })
    })
    .or_else(|| select_release_asset(assets, arch_keywords))
}

pub fn select_openwrt_package_asset(
    assets: &[Value],
    arch_keywords: &[&str],
    prefer_ext: &str,
) -> Option<(String, String)> {
    let fallback_ext = if prefer_ext == ".apk" { ".ipk" } else { ".apk" };
    find_matching_asset(assets, arch_keywords, |lower| lower.ends_with(prefer_ext))
        .or_else(|| {
            find_matching_asset(assets, arch_keywords, |lower| lower.ends_with(fallback_ext))
        })
        .or_else(|| select_release_asset(assets, arch_keywords))
}

pub fn select_release_asset(assets: &[Value], arch_keywords: &[&str]) -> Option<(String, String)> {
    find_matching_asset(assets, arch_keywords, |lower| {
        lower.ends_with(".tar.gz") && !lower.ends_with(".ipk") && !lower.ends_with(".apk")
    })
    .or_else(|| {
        find_matching_asset(assets, arch_keywords, |lower| {
            !lower.ends_with(".ipk")
                && !lower.ends_with(".apk")
                && (lower.ends_with(".tgz") || lower.ends_with(".zip") || !lower.contains('.'))
        })
    })
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
            && let Ok(mut val) = serde_json::from_str::<Value>(&raw)
        {
            if name == "sing_box"
                && let Some(obj) = val.as_object_mut()
            {
                obj.insert("component".to_string(), json!("tachyon-core"));
            }
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

pub fn normalize_update_channel(raw: &str) -> &'static str {
    match raw.trim().to_ascii_lowercase().as_str() {
        "stable" => "stable",
        "beta" | "rc" | "prerelease" => "beta",
        _ => "auto",
    }
}

pub fn resolve_include_prerelease(channel: &str, current_version: &str) -> bool {
    match normalize_update_channel(channel) {
        "beta" => true,
        "stable" => false,
        _ => split_version_parts(current_version).1.is_some(),
    }
}

pub async fn list_releases(
    core: &Arc<CoreManager>,
    raw_comp: &str,
    count: usize,
    page: usize,
) -> Value {
    let Some(canon) = resolve_known_component(raw_comp) else {
        return json!([]);
    };
    ensure_runtime_dirs();
    let per_page = count.clamp(1, 30);
    let page = page.max(1);
    let channel = {
        core.state
            .data
            .read()
            .await
            .settings
            .component_update_channel
            .clone()
    };
    let cur_ver = if canon == "tachyon" {
        store::TACHYON_VERSION.to_string()
    } else {
        current_component_version(core, canon).await
    };
    let include_prerelease = resolve_include_prerelease(&channel, &cur_ver);
    let channel_norm = normalize_update_channel(&channel);
    let cache_path = Path::new(RELEASES_CACHE_DIR).join(format!(
        "{canon}_{channel_norm}_{include_prerelease}_{per_page}_{page}.json"
    ));
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
    let api_per_page = if canon == "tachyon" || !include_prerelease {
        30
    } else {
        per_page
    };
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
                include_prerelease
                    || !item
                        .get("prerelease")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
            })
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
                include_prerelease
                    || !item
                        .get("prerelease")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
            })
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

pub fn pick_best_release(
    releases: &[Value],
    include_prerelease: bool,
    require_tachyon_v2: bool,
) -> Option<Value> {
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
        if tag.is_empty() || (require_tachyon_v2 && !is_tachyon_v2_or_newer(tag)) {
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

#[cfg(test)]
pub fn pick_best_tachyon_v2_release(releases: &[Value], include_prerelease: bool) -> Option<Value> {
    pick_best_release(releases, include_prerelease, true)
}

async fn fetch_component_release_json(
    core: &Arc<CoreManager>,
    canon: &str,
    repo: &str,
    tag: Option<&str>,
    proxy: Option<&str>,
) -> anyhow::Result<Value> {
    let is_tachyon_self = canon == "tachyon";
    let channel = {
        core.state
            .data
            .read()
            .await
            .settings
            .component_update_channel
            .clone()
    };
    let cur_ver = if is_tachyon_self {
        store::TACHYON_VERSION.to_string()
    } else {
        current_component_version(core, canon).await
    };
    let include_prerelease = resolve_include_prerelease(&channel, &cur_ver);
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
        let list_url = format!("https://api.github.com/repos/{repo}/releases?per_page=30");
        if let Ok(bytes) = core
            .curl_fetch_with_doh_fallback(&list_url, false, 10, proxy)
            .await
            && let Ok(list) = serde_json::from_slice::<Vec<Value>>(&bytes)
        {
            if let Some(best) = pick_best_release(&list, include_prerelease, is_tachyon_self) {
                return Ok(best);
            }
            if is_tachyon_self {
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
        None if is_tachyon_self || include_prerelease => {
            pick_best_release(&entries, include_prerelease, is_tachyon_self)
        }
        None => entries
            .iter()
            .find(|e| {
                !e.get("prerelease")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            })
            .cloned()
            .or_else(|| entries.first().cloned()),
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
            let (local_sha, local_fp) = resolve_local_build_identity(core, canon, &current);
            let (remote_sha, remote_fp) =
                resolve_remote_build_identity(core, &repo, tag, &rel, proxy.as_deref()).await;
            let mut status = classify_version_status(&current, &latest);
            if status == "latest"
                && same_release_build_differs(&local_sha, &remote_sha, &local_fp, &remote_fp)
            {
                status = "outdated_same_release";
            }
            let msg = match status {
                "outdated" => {
                    format!("{disp}: доступна новая версия {latest} (установлена {current})")
                }
                "outdated_same_release" => {
                    if !local_sha.is_empty() && !remote_sha.is_empty() {
                        format!(
                            "{disp}: доступна обновлённая сборка {latest} ({} -> {})",
                            short_sha(&local_sha),
                            short_sha(&remote_sha)
                        )
                    } else {
                        format!("{disp}: доступна обновлённая сборка текущей версии {latest}")
                    }
                }
                "dev" => format!("{disp}: установлена сборка {current} (новее релиза {latest})"),
                _ => format!("{disp}: установлена актуальная версия {current}"),
            };
            if let Some(jid) = job_id {
                append_job_log(jid, Some("completed"), &format!("[OK] {msg}"));
            }
            let mut payload = json!({
                "success": true,
                "running": false,
                "completed": true,
                "kind": "component",
                "job_id": job_id.unwrap_or(""),
                "component": public_component_name(canon),
                "action": "check_update",
                "message": msg,
                "current_version": current,
                "latest_version": latest,
                "release_url": release_url,
                "release_notes": release_notes,
                "changed": is_update_available_status(status),
                "status": status,
                "exit_code": 0,
                "updated_at": now,
            });
            attach_build_metadata(&mut payload, &local_sha, &remote_sha, &local_fp, &remote_fp);
            write_component_check_cache(canon, &payload);
            payload
        }
        Err(e) => {
            if canon == "tachyon" {
                let (local_sha, local_fp) = resolve_local_build_identity(core, canon, &current);
                let msg = format!(
                    "{disp}: установлена локальная сборка {current} (внешний репозиторий {repo} не опубликован)"
                );
                if let Some(jid) = job_id {
                    append_job_log(jid, Some("completed"), &format!("[OK] {msg}"));
                }
                let mut payload = json!({
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
                attach_build_metadata(&mut payload, &local_sha, "", &local_fp, "");
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
    for direct in [
        dir.join("usr").join("bin").join(expected_name),
        dir.join("bin").join(expected_name),
    ] {
        if direct.is_file() {
            return Some(direct);
        }
    }
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
                let rel_slash = p
                    .strip_prefix(dir)
                    .map(|r| r.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_default();
                if rel_slash.starts_with("etc/init.d/") || rel_slash.starts_with("etc/config/") {
                    continue;
                }
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

async fn run_tar_extract(
    tar_flag: &str,
    archive_path: &Path,
    dest_dir: &Path,
) -> Result<(), String> {
    let mut cmd = Command::new("tar");
    cmd.arg(tar_flag)
        .arg(archive_path)
        .arg("-C")
        .arg(dest_dir)
        .kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(60), cmd.output()).await;
    match out {
        Ok(Ok(o)) if o.status.success() => Ok(()),
        Ok(Ok(o)) => {
            let err = String::from_utf8_lossy(&o.stderr).trim().to_string();
            Err(format!("Ошибка tar {tar_flag}: {err}"))
        }
        Ok(Err(e)) => Err(format!("Не удалось запустить tar: {e}")),
        Err(_) => Err(format!("Таймаут распаковки архива tar {tar_flag} (60s)")),
    }
}

pub async fn extract_package_archive(archive_path: &Path, stage_dir: &Path) -> Result<(), String> {
    let lower = archive_path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if lower.ends_with(".tar.gz") || lower.ends_with(".tgz") {
        return run_tar_extract("-xzf", archive_path, stage_dir).await;
    }
    if lower.ends_with(".ipk") {
        let outer_dir = stage_dir.join("_ipk_outer");
        let _ = std::fs::remove_dir_all(&outer_dir);
        std::fs::create_dir_all(&outer_dir)
            .map_err(|e| format!("Не удалось создать временный каталог ipk: {e}"))?;
        let extract_res = async {
            run_tar_extract("-xzf", archive_path, &outer_dir).await?;
            let (flag, data_archive) = [
                ("-xzf", outer_dir.join("data.tar.gz")),
                ("-xJf", outer_dir.join("data.tar.xz")),
                ("-xf", outer_dir.join("data.tar")),
            ]
            .into_iter()
            .find(|(_, p)| p.is_file())
            .ok_or_else(|| "Внутри .ipk не найден data.tar.gz".to_string())?;
            run_tar_extract(flag, &data_archive, stage_dir).await
        }
        .await;
        let _ = std::fs::remove_dir_all(&outer_dir);
        return extract_res;
    }
    if lower.ends_with(".apk") {
        let mut gzip_cmd = Command::new("gzip");
        gzip_cmd
            .arg("-dc")
            .arg(archive_path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut gzip_child = gzip_cmd
            .spawn()
            .map_err(|e| format!("Не удалось запустить gzip -dc: {e}"))?;

        let mut tar_cmd = Command::new("tar");
        tar_cmd
            .arg("-x")
            .arg("-C")
            .arg(stage_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut tar_child = tar_cmd
            .spawn()
            .map_err(|e| format!("Не удалось запустить tar -x: {e}"))?;

        let mut gzip_out = gzip_child
            .stdout
            .take()
            .ok_or_else(|| "Отсутствует stdout у gzip -dc".to_string())?;
        let mut gzip_err = gzip_child
            .stderr
            .take()
            .ok_or_else(|| "Отсутствует stderr у gzip -dc".to_string())?;
        let mut tar_in = tar_child
            .stdin
            .take()
            .ok_or_else(|| "Отсутствует stdin у tar -x".to_string())?;
        let mut tar_err = tar_child
            .stderr
            .take()
            .ok_or_else(|| "Отсутствует stderr у tar -x".to_string())?;

        let pipe_res = tokio::time::timeout(Duration::from_secs(60), async {
            let copy_fut = async {
                let res = tokio::io::copy(&mut gzip_out, &mut tar_in).await;
                drop(tar_in);
                res
            };
            let mut gz_err_buf = Vec::new();
            let mut tar_err_buf = Vec::new();
            let (copy_res, _, _) = tokio::join!(
                copy_fut,
                gzip_err.read_to_end(&mut gz_err_buf),
                tar_err.read_to_end(&mut tar_err_buf),
            );
            let gz_status = gzip_child.wait().await;
            let tar_status = tar_child.wait().await;
            (copy_res, gz_status, tar_status, gz_err_buf, tar_err_buf)
        })
        .await;

        return match pipe_res {
            Ok((copy_res, Ok(gz_st), Ok(tar_st), gz_err_buf, tar_err_buf)) => {
                if !gz_st.success() {
                    let msg = String::from_utf8_lossy(&gz_err_buf).trim().to_string();
                    return Err(format!("Ошибка gzip -dc для .apk: {msg}"));
                }
                if !tar_st.success() {
                    let msg = String::from_utf8_lossy(&tar_err_buf).trim().to_string();
                    return Err(format!("Ошибка tar -x для .apk: {msg}"));
                }
                if let Err(e) = copy_res {
                    return Err(format!("Ошибка передачи потока .apk в tar: {e}"));
                }
                Ok(())
            }
            Ok((_, Err(e), _, _, _)) => Err(format!("Ошибка ожидания gzip -dc: {e}")),
            Ok((_, _, Err(e), _, _)) => Err(format!("Ошибка ожидания tar -x: {e}")),
            Err(_) => Err("Таймаут распаковки пакета .apk (60s)".to_string()),
        };
    }
    Err(format!("Неподдерживаемый формат архива: {lower}"))
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
                || rel_slash == "etc/init.d/tachyon"
                || rel_slash == "etc/hotplug.d/iface/99-tachyon-wan-monitor"
                || rel_slash == "www/cgi-bin/tachyon-sub"
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

fn clear_luci_tmp_caches() {
    if let Ok(entries) = std::fs::read_dir("/tmp") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            if name.to_string_lossy().starts_with("luci-indexcache") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    if let Ok(entries) = std::fs::read_dir("/tmp/luci-modulecache") {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                let _ = std::fs::remove_dir_all(p);
            } else {
                let _ = std::fs::remove_file(p);
            }
        }
    }
}

fn sync_staged_luci_assets(stage_dir: &Path, target_root: &Path) -> usize {
    let mut updated = 0usize;
    for (src, dst) in collect_staged_luci_sync_pairs(stage_dir, target_root) {
        let dst_slash = dst.to_string_lossy().replace('\\', "/");
        let mode = if dst_slash.ends_with("/etc/init.d/tachyon")
            || dst_slash.ends_with("/etc/hotplug.d/iface/99-tachyon-wan-monitor")
            || dst_slash.ends_with("/www/cgi-bin/tachyon-sub")
        {
            0o755
        } else {
            0o644
        };
        if let Ok(bytes) = std::fs::read(&src)
            && crypto_gen::write_bytes_with_mode_if_changed(&dst, &bytes, mode).unwrap_or(false)
        {
            updated += 1;
        }
    }
    if updated > 0 && target_root == Path::new("/") {
        clear_luci_tmp_caches();
    }
    updated
}

pub fn collect_staged_entware_sync_pairs(
    stage_dir: &Path,
    paths: &crate::platform::PlatformPaths,
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
            let trimmed = rel_slash
                .trim_start_matches("./")
                .strip_prefix("opt/")
                .unwrap_or(rel_slash.trim_start_matches("./"));
            let dst = if let Some(sub) = trimmed.strip_prefix("share/tachyon/www/") {
                let mut out = paths.share_dir.join("www");
                for seg in sub.split('/').filter(|s| !s.is_empty()) {
                    out.push(seg);
                }
                Some(out)
            } else if trimmed == "etc/init.d/S99tachyon" {
                Some(paths.init_script.clone())
            } else if let Some(sub) = trimmed.strip_prefix("etc/ndm/") {
                let mut out = paths.ndm_dir.clone();
                for seg in sub.split('/').filter(|s| !s.is_empty()) {
                    out.push(seg);
                }
                Some(out)
            } else {
                None
            };
            if let Some(target) = dst {
                pairs.push((p, target));
            }
        }
    }
    pairs.sort_by(|a, b| a.1.cmp(&b.1));
    pairs
}

fn set_unix_mode(path: &Path, mode: u32) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
}

pub fn sync_staged_entware_assets(
    stage_dir: &Path,
    paths: &crate::platform::PlatformPaths,
) -> usize {
    let mut updated = 0usize;
    for (src, dst) in collect_staged_entware_sync_pairs(stage_dir, paths) {
        let dst_slash = dst.to_string_lossy().replace('\\', "/");
        let is_exec = dst == paths.init_script
            || dst_slash.ends_with(".sh")
            || dst_slash.contains("/etc/ndm/");
        if let Ok(bytes) = std::fs::read(&src) {
            let changed =
                crate::platform::write_file_if_changed_durable(&dst, &bytes).unwrap_or(false);
            if is_exec {
                set_unix_mode(&dst, 0o755);
            } else if changed {
                set_unix_mode(&dst, 0o644);
            }
            if changed {
                updated += 1;
            }
        }
    }
    updated
}

fn install_binary_durable(extracted_bin: &Path, target_bin: &Path) -> std::io::Result<()> {
    let bytes = std::fs::read(extracted_bin)?;
    let _ = crate::platform::write_file_if_changed_durable(target_bin, &bytes)?;
    set_unix_mode(target_bin, 0o755);
    Ok(())
}

pub fn resolve_tachyon_self_bin_path() -> PathBuf {
    if let Ok(over) = std::env::var("TACHYON_BIN") {
        let trimmed = over.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    let default_bin = crate::platform::paths().bin_dir.join("tachyon");
    if default_bin.exists() || cfg!(target_os = "linux") {
        return default_bin;
    }
    std::env::current_exe().unwrap_or(default_bin)
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
    archive_path: PathBuf,
    extracted_bin: PathBuf,
    target_ver: String,
    release_url: String,
    release_notes: String,
    backup_enabled: bool,
    current: String,
    local_sha: String,
    remote_sha: String,
    remote_fingerprint: String,
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
        "component": public_component_name(canon),
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

    let (local_sha, local_fp) = resolve_local_build_identity(core, canon, &current);
    let (remote_sha, remote_fp) =
        resolve_remote_build_identity(core, repo, &tag, &rel, proxy.as_deref()).await;
    let same_release_update = compare_versions(&current, &target_ver) == std::cmp::Ordering::Equal
        && same_release_build_differs(&local_sha, &remote_sha, &local_fp, &remote_fp);

    if action != "reinstall"
        && action != "install_version"
        && compare_versions(&current, &target_ver) == std::cmp::Ordering::Equal
        && !same_release_update
    {
        let msg = format!("{disp} уже обновлён до версии {target_ver}");
        append_job_log(job_id, Some("completed"), &format!("[OK] {msg}"));
        let mut ok = json!({
            "success": true,
            "running": false,
            "completed": true,
            "kind": "component",
            "job_id": job_id,
            "component": public_component_name(canon),
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
        attach_build_metadata(&mut ok, &local_sha, &remote_sha, "", "");
        write_component_check_cache(canon, &ok);
        return Err(ok);
    }

    if same_release_update {
        append_job_log(
            job_id,
            Some("checking"),
            &format!(
                "[INFO] Обнаружена новая сборка внутри релиза {target_ver}, выполняю обновление..."
            ),
        );
    }

    let assets = rel
        .get("assets")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let arch_kws = detect_arch_keywords();
    let selected = if crate::platform::is_entware() {
        match canon {
            "tachyon" => select_entware_tachyon_asset(assets, &arch_kws),
            "sing_box" => select_entware_core_asset(assets, &arch_kws),
            _ => select_release_asset(assets, &arch_kws),
        }
    } else {
        select_openwrt_package_asset(assets, &arch_kws, preferred_openwrt_pkg_ext())
    };
    let Some((asset_name, asset_url)) = selected else {
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

    let sums_manifest: String = if let Some(sums_url) = find_sha256sums_url(assets) {
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
        String::from_utf8_lossy(&sums_bytes).into_owned()
    } else if let Some(hex_digest) = assets.iter().find_map(|a| {
        if a.get("name").and_then(Value::as_str) == Some(asset_name.as_str()) {
            a.get("digest")
                .and_then(Value::as_str)
                .and_then(|d| d.strip_prefix("sha256:"))
                .map(str::trim)
                .filter(|h| h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()))
        } else {
            None
        }
    }) {
        format!("{hex_digest}  {asset_name}\n")
    } else {
        return Err(component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("В релизе {tag} отсутствует файл контрольных сумм SHA256SUMS"),
        ));
    };

    let stage_dir = if cfg!(target_os = "linux") {
        crate::platform::paths()
            .runtime_tmpfs_dir
            .join(format!("update-{job_id}"))
    } else {
        std::env::temp_dir().join(format!("tachyon-update-{job_id}"))
    };
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
    let is_archive = lower_asset.ends_with(".tar.gz")
        || lower_asset.ends_with(".tgz")
        || lower_asset.ends_with(".ipk")
        || lower_asset.ends_with(".apk");
    let extracted_bin = if is_archive {
        if let Err(err) = extract_package_archive(&archive_path, &stage_dir).await {
            let _ = std::fs::remove_dir_all(&stage_dir);
            return Err(component_error_payload(
                canon, action, job_id, &current, err,
            ));
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

    {
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
        match verify_sha256_for_candidates(&sums_manifest, &candidates) {
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
        archive_path,
        extracted_bin,
        target_ver,
        release_url,
        release_notes,
        backup_enabled,
        current,
        local_sha,
        remote_sha,
        remote_fingerprint: remote_fp,
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
    let (core_bin_cfg, core_cfg_str) = {
        let d = core.state.data.read().await;
        (
            d.settings.core_bin_path.clone(),
            d.settings.core_config_path.clone(),
        )
    };
    let p_layout = crate::platform::paths();
    let core_bin_path = if !core_bin_cfg.trim().is_empty() {
        PathBuf::from(core_bin_cfg.trim())
    } else {
        p_layout.bin_dir.join("tachyon-core")
    };
    let core_config_path = if !core_cfg_str.trim().is_empty() {
        PathBuf::from(core_cfg_str.trim())
    } else {
        p_layout.core_config_dir.join("config.json")
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
    let archive_path = staged.archive_path;
    let extracted_bin = staged.extracted_bin;
    let target_ver = staged.target_ver;
    let current = staged.current;

    if core_config_path.exists() {
        let cfg_str = core_config_path.to_string_lossy();
        if let Err(e) = run_command_checked(&extracted_bin, &["check", "-c", &cfg_str]).await {
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
    let install_res = if crate::platform::is_entware() {
        install_binary_durable(&extracted_bin, &core_bin_path)
    } else {
        atomic_swap_binary(&extracted_bin, &core_bin_path)
    };

    if let Err(e) = install_res {
        let _ = std::fs::remove_dir_all(&stage_dir);
        let _ = core.start().await;
        return component_error_payload(
            canon,
            action,
            job_id,
            &current,
            format!("Ошибка замены бинарного файла ядра: {e}"),
        );
    }

    if !crate::platform::is_entware() && core_bin_path == Path::new("/usr/bin/tachyon-core") {
        sync_apk_pkg_db(job_id, &archive_path, true).await;
    }
    let _ = std::fs::remove_dir_all(&stage_dir);

    let core_ver_path = store::runtime_state_dir().join("tachyon-core-version");
    let _ = crypto_gen::write_file_if_changed(&core_ver_path, format!("{target_ver}\n").as_bytes());
    let _ = std::fs::remove_file(p_layout.data_dir.join("tachyon-core-version"));

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
        let _ =
            crypto_gen::write_file_if_changed(&core_ver_path, format!("{current}\n").as_bytes());
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

    write_installed_build_entry(
        &data_dir,
        canon,
        &target_ver,
        &staged.remote_sha,
        &staged.remote_fingerprint,
    );
    let final_ver = core.refresh_core_version().await;
    let display_ver = if final_ver.is_empty() {
        target_ver.clone()
    } else {
        final_ver
    };
    let msg = format_installed_release_msg(
        disp,
        &current,
        &display_ver,
        &staged.local_sha,
        &staged.remote_sha,
    );
    append_job_log(job_id, Some("completed"), &format!("[OK] {msg}"));
    {
        let d_guard = core.state.data.read().await;
        crate::tg_bot::notify_if_enabled(&d_guard, "auto_update", &format!("[Tachyon] {msg}"));
    }

    let mut ok = json!({
        "success": true,
        "running": false,
        "completed": true,
        "kind": "component",
        "job_id": job_id,
        "component": public_component_name(canon),
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
    attach_build_metadata(
        &mut ok,
        &staged.remote_sha,
        &staged.remote_sha,
        &staged.remote_fingerprint,
        &staged.remote_fingerprint,
    );
    write_component_check_cache(canon, &ok);
    ok
}

async fn sync_apk_pkg_db(job_id: &str, archive_path: &Path, is_core: bool) {
    if !archive_path
        .file_name()
        .and_then(|s| s.to_str())
        .is_some_and(|n| n.to_ascii_lowercase().ends_with(".apk"))
        || !Path::new("/lib/apk/db").is_dir()
    {
        return;
    }
    let mut cmd = Command::new("apk");
    cmd.args([
        "add",
        "--allow-untrusted",
        "--no-network",
        "--repositories-file",
        "/dev/null",
        "--force-overwrite",
        "--force-reinstall",
        "--scripts=no",
    ])
    .arg(archive_path)
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .kill_on_drop(true);
    match tokio::time::timeout(Duration::from_secs(30), cmd.output()).await {
        Ok(Ok(out)) if out.status.success() => {
            if is_core {
                let _ = std::fs::remove_file("/etc/tachyon-core/config.json.apk-new");
                let _ = std::fs::remove_file("/etc/config/tachyon-core.apk-new");
                if let Ok(entries) = std::fs::read_dir("/etc/rc.d") {
                    for entry in entries.flatten() {
                        let name = entry.file_name();
                        let s = name.to_string_lossy();
                        if (s.starts_with('S') || s.starts_with('K')) && s.contains("tachyon-core")
                        {
                            let _ = std::fs::remove_file(entry.path());
                        }
                    }
                }
            }
            append_job_log(
                job_id,
                Some("installing"),
                "[OK] База пакетов apk синхронизирована (--scripts=no)",
            );
        }
        Ok(Ok(out)) => {
            let detail = String::from_utf8_lossy(&out.stderr).trim().to_string();
            append_job_log(
                job_id,
                Some("installing"),
                &format!("[WARN] Не удалось обновить базу apk: {detail}"),
            );
        }
        Ok(Err(e)) => {
            append_job_log(
                job_id,
                Some("installing"),
                &format!("[WARN] Не удалось запустить apk: {e}"),
            );
        }
        Err(_) => {
            append_job_log(
                job_id,
                Some("installing"),
                "[WARN] Таймаут обновления базы apk (30s)",
            );
        }
    }
}

fn schedule_tachyon_service_restart() {
    let init = crate::platform::paths().init_script.clone();
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
    let archive_path = staged.archive_path;
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
    let p_layout = crate::platform::paths();
    let is_entware = crate::platform::is_entware();
    let swap_res = if is_entware {
        install_binary_durable(&extracted_bin, &self_bin_path)
    } else {
        atomic_swap_binary(&extracted_bin, &self_bin_path)
    };
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

    let luci_updated = if is_entware {
        sync_staged_entware_assets(&stage_dir, p_layout)
    } else {
        let updated = sync_staged_luci_assets(&stage_dir, Path::new("/"));
        sync_apk_pkg_db(job_id, &archive_path, false).await;
        updated
    };
    let _ = std::fs::remove_dir_all(&stage_dir);
    if luci_updated > 0 {
        append_job_log(
            job_id,
            Some("installing"),
            &format!("[OK] Обновлено статических файлов веб-интерфейса: {luci_updated}"),
        );
    }

    write_installed_build_entry(
        &data_dir,
        canon,
        &target_ver,
        &staged.remote_sha,
        &staged.remote_fingerprint,
    );

    let msg = format_installed_release_msg(
        disp,
        &current,
        &target_ver,
        &staged.local_sha,
        &staged.remote_sha,
    );
    append_job_log(job_id, Some("completed"), &format!("[OK] {msg}"));
    {
        let d_guard = core.state.data.read().await;
        crate::tg_bot::notify_if_enabled(&d_guard, "auto_update", &format!("[Tachyon] {msg}"));
    }

    let init_script = &p_layout.init_script;
    let restart_scheduled = init_script.exists();
    if restart_scheduled {
        append_job_log(
            job_id,
            Some("restarting"),
            &format!(
                "[INFO] Планирую перезапуск службы {}...",
                init_script.display()
            ),
        );
        schedule_tachyon_service_restart();
    }

    let mut ok = json!({
        "success": true,
        "running": false,
        "completed": true,
        "kind": "component",
        "job_id": job_id,
        "component": public_component_name(canon),
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
    attach_build_metadata(
        &mut ok,
        &staged.remote_sha,
        &staged.remote_sha,
        &staged.remote_fingerprint,
        &staged.remote_fingerprint,
    );
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
                "component": public_component_name(&canon),
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
    let Some(canon) = resolve_known_component(raw_comp) else {
        let comp_trimmed = raw_comp.trim();
        let act_trimmed = raw_action.trim();
        let err_msg = format!("Unsupported component: {comp_trimmed}");
        return json!({
            "success": false,
            "running": false,
            "completed": true,
            "kind": "component",
            "component": comp_trimmed,
            "action": act_trimmed,
            "exit_code": 1,
            "error": err_msg,
            "message": err_msg,
        });
    };
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
        "component": public_component_name(canon),
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

fn list_interval_disabled(spec: &str) -> bool {
    matches!(
        spec.trim().to_ascii_lowercase().as_str(),
        "0" | "off" | "never" | "disabled"
    )
}

fn extract_url_host(url: &str) -> String {
    url.split("://")
        .nth(1)
        .unwrap_or(url)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
}

pub(crate) fn collect_community_sync_targets(
    d: &crate::store::RouterStoreData,
) -> (Vec<String>, Vec<String>) {
    let mut list_names = Vec::new();
    let mut subnet_services = Vec::new();
    let push_list = |names: &mut Vec<String>, raw: &str| {
        let cl = raw.trim().to_string();
        if !cl.is_empty() && !names.contains(&cl) {
            names.push(cl);
        }
    };
    let push_subnet = |subs: &mut Vec<String>, raw: &str| {
        let canonical =
            crate::config_gen::canonical_community_subnet_service(raw).to_ascii_lowercase();
        if !canonical.is_empty()
            && crate::config_gen::community_service_has_subnet_list(&canonical)
            && !subs.contains(&canonical)
        {
            subs.push(canonical);
        }
    };

    for c in &d.conditions {
        for l in &c.community_lists {
            push_list(&mut list_names, l);
            if c.community_subnets {
                push_subnet(&mut subnet_services, l);
            }
        }
        for r in &c.rule_set_with_subnets {
            if crate::config_gen::is_community_list_token(r) {
                push_list(&mut list_names, r);
                push_subnet(&mut subnet_services, r);
            }
        }
    }
    for s in &d.sections {
        for l in &s.community_lists {
            push_list(&mut list_names, l);
            if s.community_subnets {
                push_subnet(&mut subnet_services, l);
            }
        }
        for r in &s.rule_set_with_subnets {
            if crate::config_gen::is_community_list_token(r) {
                push_list(&mut list_names, r);
                push_subnet(&mut subnet_services, r);
            }
        }
    }
    for l in &d.settings.smart_detect_exclude_lists {
        push_list(&mut list_names, l);
    }
    (list_names, subnet_services)
}

pub(crate) async fn sync_community_subnet_lists(
    core: &CoreManager,
    rulesets_dir: &Path,
    github_mirror: &str,
    proxy_opt: Option<&str>,
    subnet_services: &[String],
    dead_hosts: &mut HashSet<String>,
) -> (bool, u64) {
    let mut any_changed = false;
    let mut synced = 0u64;
    if subnet_services.is_empty() {
        return (false, 0);
    }
    let _ = std::fs::create_dir_all(rulesets_dir);
    let tmp_dir = Path::new("/tmp/tachyon-core/rulesets");
    let use_tmp_dir = cfg!(target_os = "linux") && tmp_dir != rulesets_dir;
    if use_tmp_dir {
        let _ = std::fs::create_dir_all(tmp_dir);
    }

    for canonical in subnet_services {
        let Some(base_url) = crate::config_gen::community_subnet_url(canonical) else {
            continue;
        };
        let mirrored = apply_github_mirror(github_mirror, &base_url);
        let base_host = extract_url_host(&base_url);
        let mirror_host = extract_url_host(&mirrored);
        let all_dead = (mirrored == base_url || dead_hosts.contains(&mirror_host))
            && dead_hosts.contains(&base_host);
        if all_dead {
            continue;
        }
        let mut fetched = None;
        if mirrored != base_url && !dead_hosts.contains(&mirror_host) {
            match core
                .curl_fetch_with_doh_fallback(&mirrored, false, 15, proxy_opt)
                .await
            {
                Ok(bytes) if !bytes.is_empty() => fetched = Some(bytes),
                _ => {
                    if !mirror_host.is_empty() {
                        dead_hosts.insert(mirror_host);
                    }
                }
            }
        }
        if fetched.is_none() && !dead_hosts.contains(&base_host) {
            match core
                .curl_fetch_with_doh_fallback(&base_url, false, 15, proxy_opt)
                .await
            {
                Ok(bytes) if !bytes.is_empty() => fetched = Some(bytes),
                _ => {
                    if !base_host.is_empty() {
                        dead_hosts.insert(base_host);
                    }
                }
            }
        }

        let file_name = format!("community-subnets-{canonical}.lst");
        let persist_dst = rulesets_dir.join(&file_name);
        if let Some(bytes) = fetched
            && let Ok(text) = std::str::from_utf8(&bytes)
            && !crate::config_gen::parse_valid_cidr_list(text).is_empty()
        {
            if use_tmp_dir
                && matches!(
                    crypto_gen::write_file_if_changed(tmp_dir.join(&file_name), &bytes),
                    Ok(true)
                )
            {
                any_changed = true;
            }
            if bytes.len() <= 524_288 {
                if matches!(
                    crypto_gen::write_file_if_changed(&persist_dst, &bytes),
                    Ok(true)
                ) {
                    any_changed = true;
                }
            } else {
                let _ = std::fs::remove_file(&persist_dst);
            }
            synced += 1;
        } else if persist_dst.exists() {
            if use_tmp_dir
                && let Ok(existing) = std::fs::read(&persist_dst)
                && !existing.is_empty()
            {
                let _ = crypto_gen::write_file_if_changed(tmp_dir.join(&file_name), &existing);
            }
            synced += 1;
        }
    }
    (any_changed, synced)
}

async fn perform_list_update(core: &Arc<CoreManager>) -> Value {
    let (rulesets_dir, github_mirror, list_names, subnet_services, proxy_opt) = {
        let d = core.state.data.read().await;
        let (names, subnets) = collect_community_sync_targets(&d);
        let px = if d.settings.download_lists_via_proxy {
            d.sections
                .iter()
                .find(|s| {
                    s.enabled
                        && s.id == d.settings.download_lists_via_proxy_section
                        && s.mixed_proxy_enabled
                        && s.mixed_proxy_port > 0
                })
                .map(|s| format!("http://127.0.0.1:{}", s.mixed_proxy_port))
        } else {
            None
        };
        (
            crate::diagnostics::effective_rulesets_dir(&d.settings),
            d.settings.github_mirror.clone(),
            names,
            subnets,
            px,
        )
    };
    let mut any_changed = false;
    let mut synced_files = 0u64;
    let mut dead_hosts: std::collections::HashSet<String> = std::collections::HashSet::new();
    if !list_names.is_empty() {
        let _ = std::fs::create_dir_all(&rulesets_dir);
        for clean in &list_names {
            let base_url = format!(
                "https://github.com/Dushnilin/tachyon-lists/releases/latest/download/{clean}.trs"
            );
            let mirrored = apply_github_mirror(&github_mirror, &base_url);
            let base_host = extract_url_host(&base_url);
            let mirror_host = extract_url_host(&mirrored);
            let all_dead = (mirrored == base_url || dead_hosts.contains(&mirror_host))
                && dead_hosts.contains(&base_host);
            if all_dead {
                continue;
            }
            let mut fetched = None;
            if mirrored != base_url && !dead_hosts.contains(&mirror_host) {
                match core
                    .curl_fetch_with_doh_fallback(&mirrored, false, 15, proxy_opt.as_deref())
                    .await
                {
                    Ok(bytes) if !bytes.is_empty() => fetched = Some(bytes),
                    _ => {
                        if !mirror_host.is_empty() {
                            dead_hosts.insert(mirror_host);
                        }
                    }
                }
            }
            if fetched.is_none() && !dead_hosts.contains(&base_host) {
                match core
                    .curl_fetch_with_doh_fallback(&base_url, false, 15, proxy_opt.as_deref())
                    .await
                {
                    Ok(bytes) if !bytes.is_empty() => fetched = Some(bytes),
                    _ => {
                        if !base_host.is_empty() {
                            dead_hosts.insert(base_host);
                        }
                    }
                }
            }
            let dst = rulesets_dir.join(format!("{clean}.trs"));
            let stale_srs = rulesets_dir.join(format!("{clean}.srs"));
            let _ = std::fs::remove_file(&stale_srs);
            if let Some(bytes) = fetched {
                if crate::core_mgr::CoreManager::bytes_have_valid_trs_magic(&bytes) {
                    if matches!(crypto_gen::write_file_if_changed(&dst, &bytes), Ok(true)) {
                        any_changed = true;
                    }
                    synced_files += 1;
                } else if !crate::core_mgr::CoreManager::file_has_valid_trs_magic(&dst) {
                    let _ = std::fs::remove_file(&dst);
                }
            } else if crate::core_mgr::CoreManager::file_has_valid_trs_magic(&dst) {
                synced_files += 1;
            } else if dst.exists() {
                let _ = std::fs::remove_file(&dst);
            }
        }
    }
    let (sub_changed, _sub_synced) = sync_community_subnet_lists(
        core.as_ref(),
        &rulesets_dir,
        &github_mirror,
        proxy_opt.as_deref(),
        &subnet_services,
        &mut dead_hosts,
    )
    .await;
    if sub_changed {
        any_changed = true;
    }
    if any_changed && !core.is_manually_stopped() {
        let _ = core.apply_or_reload().await;
    }
    let cnt = if synced_files > 0 {
        synced_files
    } else {
        std::fs::read_dir(&rulesets_dir)
            .map(|rd| {
                rd.flatten()
                    .filter(|e| {
                        e.path()
                            .extension()
                            .and_then(|x| x.to_str())
                            .is_some_and(|ext| ext == "trs" || ext == "srs")
                    })
                    .count() as u64
            })
            .unwrap_or(0)
    };
    json!({
        "ok": true,
        "result": {
            "lists_count": cnt,
            "changed": any_changed,
            "rulesets_dir": rulesets_dir.to_string_lossy(),
            "message": format!("Синхронизировано наборов правил (.trs/.srs): {cnt}")
        }
    })
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
        let res = perform_list_update(&core_c).await;
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

pub async fn run_list_updates_if_due(core: &Arc<CoreManager>) -> bool {
    let (enabled, interval_spec) = {
        let d = core.state.data.read().await;
        (
            d.settings.list_update_enabled,
            d.settings.update_interval.clone(),
        )
    };
    if !enabled || list_interval_disabled(&interval_spec) {
        return false;
    }
    let interval_secs = interval_to_secs(if interval_spec.trim().is_empty() {
        "3h"
    } else {
        &interval_spec
    });
    let now = store::unix_now_secs();
    let last_updated = read_list_update_status()
        .get("updated_at")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if last_updated > 0 && now.saturating_sub(last_updated) < interval_secs {
        return false;
    }
    let _ = start_list_update_async(core).await;
    true
}

pub async fn start_list_update_if_due_async(core: &Arc<CoreManager>) -> Value {
    let (enabled, interval_spec) = {
        let d = core.state.data.read().await;
        (
            d.settings.list_update_enabled,
            d.settings.update_interval.clone(),
        )
    };
    if !enabled || list_interval_disabled(&interval_spec) {
        return json!({
            "success": true,
            "running": false,
            "completed": true,
            "due": false,
            "message": "Автообновление списков отключено"
        });
    }
    let interval_secs = interval_to_secs(if interval_spec.trim().is_empty() {
        "3h"
    } else {
        &interval_spec
    });
    let now = store::unix_now_secs();
    let cur = read_list_update_status();
    let last_updated = cur.get("updated_at").and_then(Value::as_i64).unwrap_or(0);
    if last_updated > 0 && now.saturating_sub(last_updated) < interval_secs {
        return json!({
            "success": true,
            "running": false,
            "completed": true,
            "due": false,
            "updated_at": last_updated,
            "message": "Списки актуальны"
        });
    }
    start_list_update_async(core).await
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

pub(crate) fn should_notify_update_available(d: &store::RouterStoreData, comp: &str) -> bool {
    if !d.telegram.enabled || !d.telegram.notify_update_available {
        return false;
    }
    if d.settings.component_auto_update_enabled {
        let canon = canonical_component(comp);
        if d.settings.component_auto_update_targets.is_empty()
            || d.settings
                .component_auto_update_targets
                .iter()
                .any(|t| t == "all" || canonical_component(t) == canon)
        {
            return false;
        }
    }
    true
}

fn is_check_cache_stale(cache_path: &Path, now: i64, ttl: i64) -> bool {
    std::fs::read_to_string(cache_path)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.get("updated_at").and_then(Value::as_i64))
        .map(|ts| now.saturating_sub(ts) >= ttl)
        .unwrap_or(true)
}

fn is_cache_outdated(cache_path: &Path) -> bool {
    std::fs::read_to_string(cache_path)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.get("status").and_then(Value::as_str).map(str::to_string))
        .is_some_and(|s| is_update_available_status(&s))
}

async fn run_component_install_and_wait(core: &Arc<CoreManager>, comp: &str) {
    let job = start_component_action(core, comp, "install", None).await;
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
    let tachyon_cache = Path::new(CHECK_CACHE_DIR).join("tachyon.json");
    let core_stale = is_check_cache_stale(&core_cache, now, check_ttl);
    let tachyon_stale = is_check_cache_stale(&tachyon_cache, now, check_ttl);

    if core_stale || tachyon_stale {
        if core_stale {
            let _ = perform_check_update(core, "sing_box", None).await;
        }
        if tachyon_stale {
            let _ = perform_check_update(core, "tachyon", None).await;
        }

        let d_snap = core.state.data.read().await.clone();
        for comp in ["sing_box", "tachyon"] {
            if !should_notify_update_available(&d_snap, comp) {
                continue;
            }
            let cpath = Path::new(CHECK_CACHE_DIR).join(format!("{comp}.json"));
            if let Ok(raw) = std::fs::read_to_string(&cpath)
                && let Ok(v) = serde_json::from_str::<Value>(&raw)
                && let Some(st) = v.get("status").and_then(Value::as_str)
                && is_update_available_status(st)
            {
                let cur = v
                    .get("current_version")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let latest = v
                    .get("latest_version")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let latest_sha = v
                    .get("latest_sha")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                let latest_label = if st == "outdated_same_release" && !latest_sha.is_empty() {
                    format!("{latest} ({})", short_sha(latest_sha))
                } else if st == "outdated_same_release" {
                    format!("{latest} (новая сборка)")
                } else {
                    latest.to_string()
                };
                crate::tg_bot::submit_update_available_notice(&d_snap, comp, cur, &latest_label);
            }
        }
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

    let wants_all = targets.is_empty() || targets.iter().any(|t| t == "all");
    let wants_core = wants_all || targets.iter().any(|t| canonical_component(t) == "sing_box");
    let wants_tachyon = wants_all || targets.iter().any(|t| canonical_component(t) == "tachyon");

    if wants_core && is_cache_outdated(&core_cache) {
        run_component_install_and_wait(core, "sing_box").await;
    }
    if wants_tachyon && is_cache_outdated(&tachyon_cache) {
        run_component_install_and_wait(core, "tachyon").await;
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
        std::fs::create_dir_all(stage.join("etc/init.d")).unwrap();
        std::fs::create_dir_all(stage.join("usr/share/tachyon")).unwrap();
        std::fs::create_dir_all(stage.join("www/luci-static/resources/view/tachyon")).unwrap();
        std::fs::create_dir_all(stage.join("htdocs/luci-static/resources/view/tachyon")).unwrap();
        std::fs::write(stage.join("tachyon-aarch64-v2.0.0.apk"), b"apk").unwrap();
        std::fs::write(stage.join("etc/init.d/tachyon"), b"#!/bin/sh\n").unwrap();
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

        // Verify fallback search skips etc/init.d/tachyon even if etc/init.d/ is present
        let fallback_stage = base.join("fallback_stage");
        std::fs::create_dir_all(fallback_stage.join("etc/init.d")).unwrap();
        std::fs::create_dir_all(fallback_stage.join("opt/tachyon")).unwrap();
        std::fs::write(fallback_stage.join("etc/init.d/tachyon"), b"#!/bin/sh\n").unwrap();
        std::fs::write(fallback_stage.join("opt/tachyon/tachyon"), b"elf").unwrap();
        let found_fallback = rt
            .block_on(find_extracted_binary(&fallback_stage, "tachyon"))
            .unwrap();
        assert_eq!(found_fallback, fallback_stage.join("opt/tachyon/tachyon"));

        let first_sync = sync_staged_luci_assets(&stage, &target_root);
        assert_eq!(first_sync, 4);
        assert!(target_root.join("etc/init.d/tachyon").exists());
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

        assert!(!resolve_include_prerelease("auto", "2.0.0"));
        assert!(resolve_include_prerelease("auto", "2.0.0-rc.1"));
        assert!(!resolve_include_prerelease("stable", "2.0.0-rc.1"));
        assert!(resolve_include_prerelease("beta", "2.0.0"));
        assert!(resolve_include_prerelease("rc", "0.6.3"));

        let core_releases = vec![
            json!({ "tag_name": "v0.6.3", "prerelease": false, "draft": false }),
            json!({ "tag_name": "v0.6.4-beta.1", "prerelease": true, "draft": false }),
            json!({ "tag_name": "v0.6.4-rc.1", "prerelease": true, "draft": false }),
        ];
        assert_eq!(
            pick_best_release(&core_releases, false, false).unwrap()["tag_name"],
            "v0.6.3"
        );
        assert_eq!(
            pick_best_release(&core_releases, true, false).unwrap()["tag_name"],
            "v0.6.4-rc.1"
        );
    }

    #[test]
    fn test_select_openwrt_package_asset_all_arches_apk_and_ipk() {
        let mut apk_and_ipk_assets = Vec::new();
        let mut ipk_only_assets = Vec::new();
        let mut apk_only_assets = Vec::new();
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
            let ipk = json!({
                "name": format!("tachyon-{arch}-v2.0.0-beta.1.ipk"),
                "browser_download_url": format!("https://example/tachyon-{arch}.ipk"),
            });
            let apk = json!({
                "name": format!("tachyon-{arch}-v2.0.0-beta.1.apk"),
                "browser_download_url": format!("https://example/tachyon-{arch}.apk"),
            });
            apk_and_ipk_assets.push(ipk.clone());
            apk_and_ipk_assets.push(apk.clone());
            ipk_only_assets.push(ipk);
            apk_only_assets.push(apk);
        }

        let cases = [
            ("DISTRIB_ARCH='x86_64'", "x86_64"),
            ("DISTRIB_ARCH='i386_pentium4'", "i386_pentium4"),
            ("DISTRIB_ARCH='aarch64_cortex-a53'", "aarch64"),
            ("DISTRIB_ARCH='arm_cortex-a7_neon-vfpv4'", "armv7"),
            ("DISTRIB_ARCH='arm_mpcore'", "armv6"),
            ("DISTRIB_ARCH='riscv64_riscv64'", "riscv64"),
            ("DISTRIB_ARCH='mipsel_24kc'", "mipsel"),
            ("DISTRIB_ARCH='mips_24kc'", "mips"),
        ];
        for (distrib_arch, arch_name) in cases {
            let kws = map_arch_str_to_keywords(distrib_arch);
            assert_eq!(
                select_openwrt_package_asset(&apk_and_ipk_assets, &kws, ".apk")
                    .unwrap()
                    .0,
                format!("tachyon-{arch_name}-v2.0.0-beta.1.apk"),
                "failed apk selection for {distrib_arch}"
            );
            assert_eq!(
                select_openwrt_package_asset(&apk_and_ipk_assets, &kws, ".ipk")
                    .unwrap()
                    .0,
                format!("tachyon-{arch_name}-v2.0.0-beta.1.ipk"),
                "failed ipk selection for {distrib_arch}"
            );
            // Cross-format fallback when only one format is uploaded (no .tar.gz in release)
            assert_eq!(
                select_openwrt_package_asset(&ipk_only_assets, &kws, ".apk")
                    .unwrap()
                    .0,
                format!("tachyon-{arch_name}-v2.0.0-beta.1.ipk"),
            );
            assert_eq!(
                select_openwrt_package_asset(&apk_only_assets, &kws, ".ipk")
                    .unwrap()
                    .0,
                format!("tachyon-{arch_name}-v2.0.0-beta.1.apk"),
            );
        }
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

    #[test]
    fn test_should_notify_update_available_respects_auto_update_suppression() {
        let mut d = store::RouterStoreData::default();
        d.telegram.enabled = true;
        d.telegram.notify_update_available = true;
        d.settings.component_auto_update_enabled = false;
        assert!(should_notify_update_available(&d, "tachyon"));
        assert!(should_notify_update_available(&d, "sing_box"));

        // Auto-update active with empty/all targets suppresses notifications
        d.settings.component_auto_update_enabled = true;
        assert!(!should_notify_update_available(&d, "tachyon"));
        assert!(!should_notify_update_available(&d, "sing_box"));

        // Specific target suppresses only matching component
        d.settings.component_auto_update_targets = vec!["tachyon".to_string()];
        assert!(!should_notify_update_available(&d, "tachyon"));
        assert!(should_notify_update_available(&d, "sing_box"));

        d.settings.component_auto_update_enabled = false;
        d.telegram.notify_update_available = false;
        assert!(!should_notify_update_available(&d, "sing_box"));
    }

    #[test]
    fn test_sync_staged_luci_assets_includes_init_and_cgi_with_modes() {
        let uniq = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!("tachyon_luci_modes_{uniq}"));
        let stage = base.join("stage");
        let root = base.join("root");
        std::fs::create_dir_all(stage.join("etc/init.d")).unwrap();
        std::fs::create_dir_all(stage.join("etc/hotplug.d/iface")).unwrap();
        std::fs::create_dir_all(stage.join("www/cgi-bin")).unwrap();
        std::fs::create_dir_all(stage.join("www/luci-static/resources/view/tachyon")).unwrap();
        std::fs::write(
            stage.join("etc/init.d/tachyon"),
            b"#!/bin/sh /etc/rc.common\n",
        )
        .unwrap();
        std::fs::write(
            stage.join("etc/hotplug.d/iface/99-tachyon-wan-monitor"),
            b"#!/bin/sh\n",
        )
        .unwrap();
        std::fs::write(stage.join("www/cgi-bin/tachyon-sub"), b"#!/bin/sh\n").unwrap();
        std::fs::write(
            stage.join("www/luci-static/resources/view/tachyon/main.js"),
            b"console.log('ok');",
        )
        .unwrap();

        let changed = sync_staged_luci_assets(&stage, &root);
        assert_eq!(changed, 4);
        assert!(root.join("etc/init.d/tachyon").exists());
        assert!(
            root.join("etc/hotplug.d/iface/99-tachyon-wan-monitor")
                .exists()
        );
        assert!(root.join("www/cgi-bin/tachyon-sub").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let init_mode = std::fs::metadata(root.join("etc/init.d/tachyon"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            let hotplug_mode =
                std::fs::metadata(root.join("etc/hotplug.d/iface/99-tachyon-wan-monitor"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777;
            let cgi_mode = std::fs::metadata(root.join("www/cgi-bin/tachyon-sub"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            let js_mode =
                std::fs::metadata(root.join("www/luci-static/resources/view/tachyon/main.js"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777;
            assert_eq!(init_mode, 0o755);
            assert_eq!(hotplug_mode, 0o755);
            assert_eq!(cgi_mode, 0o755);
            assert_eq!(js_mode, 0o644);
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn test_select_openwrt_package_asset_for_tachyon_core_prefers_apk_ipk_then_targz() {
        let assets = vec![
            json!({
                "name": "libtachyon-arm64-v8a.so",
                "browser_download_url": "https://example/libtachyon-arm64-v8a.so"
            }),
            json!({
                "name": "tachyon-core-aarch64-linux-android-v0.6.0.tar.gz",
                "browser_download_url": "https://example/tachyon-core-aarch64-linux-android-v0.6.0.tar.gz"
            }),
            json!({
                "name": "tachyon-core-windows-amd64-v0.6.0.zip",
                "browser_download_url": "https://example/tachyon-core-windows-amd64-v0.6.0.zip"
            }),
            json!({
                "name": "tachyon-core-aarch64-v0.6.0.tar.gz",
                "browser_download_url": "https://example/tachyon-core-aarch64-v0.6.0.tar.gz"
            }),
            json!({
                "name": "tachyon-core-aarch64-v0.6.0.ipk",
                "browser_download_url": "https://example/tachyon-core-aarch64-v0.6.0.ipk"
            }),
            json!({
                "name": "tachyon-core-aarch64-v0.6.0.apk",
                "browser_download_url": "https://example/tachyon-core-aarch64-v0.6.0.apk"
            }),
            json!({
                "name": "tachyon-core-mipsel-v0.6.0.tar.gz",
                "browser_download_url": "https://example/tachyon-core-mipsel-v0.6.0.tar.gz"
            }),
        ];

        assert_eq!(
            select_openwrt_package_asset(&assets, &["aarch64", "arm64"], ".apk")
                .unwrap()
                .0,
            "tachyon-core-aarch64-v0.6.0.apk"
        );
        assert_eq!(
            select_openwrt_package_asset(&assets, &["aarch64", "arm64"], ".ipk")
                .unwrap()
                .0,
            "tachyon-core-aarch64-v0.6.0.ipk"
        );
        assert_eq!(
            select_openwrt_package_asset(&assets, &["mipsel"], ".apk")
                .unwrap()
                .0,
            "tachyon-core-mipsel-v0.6.0.tar.gz"
        );
    }

    #[test]
    fn test_resolve_known_component_rejects_unknown_and_legacy() {
        assert_eq!(resolve_known_component("tachyon"), Some("tachyon"));
        assert_eq!(resolve_known_component("luci-app-tachyon"), Some("tachyon"));
        assert_eq!(resolve_known_component("tachyon-core"), Some("sing_box"));
        assert_eq!(resolve_known_component("sing_box"), Some("sing_box"));
        assert_eq!(resolve_known_component("lists"), Some("lists"));
        assert_eq!(resolve_known_component("rulesets"), Some("lists"));
        assert_eq!(
            resolve_known_component("subscriptions"),
            Some("subscriptions")
        );

        for bad in [
            "zapret",
            "zapret2",
            "byedpi",
            "direct_bypass",
            "torrserver_direct",
            "",
            "unknown",
        ] {
            assert_eq!(
                resolve_known_component(bad),
                None,
                "expected None for unsupported component '{bad}'"
            );
        }
    }

    #[test]
    fn test_extract_release_commit_sha_and_fingerprint() {
        let with_hex_target = json!({
            "target_commitish": "ABCDEF1234567890",
            "body": "Commit: 1111111"
        });
        assert_eq!(
            extract_release_commit_sha(&with_hex_target),
            "abcdef1234567890"
        );

        let with_branch_target_and_trailer = json!({
            "target_commitish": "2.0",
            "body": "Fixes bug from /commit/aaaaaaa\nCommit: `6c85a10eb4ca6c0e4c38368e0428212b0b3adee2`\n"
        });
        assert_eq!(
            extract_release_commit_sha(&with_branch_target_and_trailer),
            "6c85a10eb4ca6c0e4c38368e0428212b0b3adee2"
        );

        let with_sha_line = json!({
            "target_commitish": "main",
            "body": "Notes\nSHA: FFFF9999AAAA\n"
        });
        assert_eq!(extract_release_commit_sha(&with_sha_line), "ffff9999aaaa");

        let with_url_only = json!({
            "target_commitish": "2.0",
            "body": "See https://github.com/Dushnilin/tachyon/commit/1234abcd5678 for details"
        });
        assert_eq!(extract_release_commit_sha(&with_url_only), "1234abcd5678");

        let digest_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let rel_with_digest = json!({
            "published_at": "2026-11-23T10:00:00Z",
            "assets": [{
                "name": "tachyon-x86_64-v2.0.0-rc.1.ipk",
                "browser_download_url": "https://example/pkg.ipk",
                "digest": format!("sha256:{digest_hex}"),
                "updated_at": "2026-11-23T10:05:00Z",
                "size": 102400
            }]
        });
        assert_eq!(
            compute_release_build_fingerprint(
                &rel_with_digest,
                &["x86_64"],
                ".ipk",
                "6c85a10eb4ca"
            ),
            "sha:6c85a10eb4ca"
        );
        assert_eq!(
            compute_release_build_fingerprint(&rel_with_digest, &["x86_64"], ".ipk", ""),
            format!("digest:{digest_hex}")
        );

        let rel_with_meta = json!({
            "published_at": "2026-11-23T10:00:00Z",
            "assets": [{
                "name": "tachyon-x86_64-v2.0.0-rc.1.ipk",
                "browser_download_url": "https://example/pkg.ipk",
                "updated_at": "2026-11-23T10:05:00Z",
                "size": 102400
            }]
        });
        assert_eq!(
            compute_release_build_fingerprint(&rel_with_meta, &["x86_64"], ".ipk", ""),
            "build:2026-11-23T10:00:00Z|2026-11-23T10:05:00Z|102400"
        );
    }

    #[test]
    fn test_same_release_build_differs_matrix() {
        assert!(!same_release_build_differs(
            "6c85a10",
            "6C85A10EB4CA6C0E4C38368E0428212B0B3ADEE2",
            "build:old",
            "build:new"
        ));
        assert!(same_release_build_differs(
            "cc01ab8",
            "6c85a10eb4ca",
            "build:same",
            "build:same"
        ));
        assert!(!same_release_build_differs(
            "",
            "6c85a10eb4ca",
            "digest:aaaa",
            "digest:aaaa"
        ));
        assert!(same_release_build_differs(
            "",
            "",
            "build:t1|u1|100",
            "build:t1|u2|102"
        ));
        assert!(!same_release_build_differs(
            "",
            "6c85a10eb4ca",
            "",
            "sha:6c85a10eb4ca"
        ));
    }

    #[test]
    fn test_build_state_roundtrip_and_version_invalidation() {
        let uniq = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let data_dir = std::env::temp_dir().join(format!("tachyon_build_state_{uniq}"));
        std::fs::create_dir_all(&data_dir).unwrap();

        write_installed_build_entry(
            &data_dir,
            "tachyon",
            "2.0.0-rc.1",
            "6C85A10EB4CA",
            "sha:6c85a10eb4ca",
        );
        write_installed_build_entry(
            &data_dir,
            "sing_box",
            "0.5.1",
            "",
            "digest:0123456789abcdef",
        );

        assert_eq!(
            read_installed_build_entry(&data_dir, "tachyon", "v2.0.0-rc.1"),
            ("6c85a10eb4ca".to_string(), "sha:6c85a10eb4ca".to_string())
        );
        assert_eq!(
            read_installed_build_entry(&data_dir, "sing_box", "0.5.1"),
            (String::new(), "digest:0123456789abcdef".to_string())
        );
        assert_eq!(
            read_installed_build_entry(&data_dir, "tachyon", "2.0.0"),
            (String::new(), String::new())
        );

        assert!(is_update_available_status("outdated"));
        assert!(is_update_available_status("outdated_same_release"));
        assert!(!is_update_available_status("latest"));
        assert!(!is_update_available_status("dev"));
        assert!(!is_update_available_status(""));

        let _ = std::fs::remove_dir_all(&data_dir);
    }

    #[test]
    fn test_is_cache_outdated_recognizes_same_release() {
        let uniq = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!("tachyon_cache_outdated_{uniq}"));
        std::fs::create_dir_all(&base).unwrap();

        let p_same = base.join("same.json");
        std::fs::write(&p_same, r#"{"status":"outdated_same_release"}"#).unwrap();
        assert!(is_cache_outdated(&p_same));

        let p_outdated = base.join("outdated.json");
        std::fs::write(&p_outdated, r#"{"status":"outdated"}"#).unwrap();
        assert!(is_cache_outdated(&p_outdated));

        let p_latest = base.join("latest.json");
        std::fs::write(&p_latest, r#"{"status":"latest"}"#).unwrap();
        assert!(!is_cache_outdated(&p_latest));

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn test_entware_arch_mapping_and_opkg_parse() {
        assert_eq!(map_arch_str_to_keywords("mipsel-3.4")[0], "mipsel");
        assert_eq!(map_arch_str_to_keywords("mips-3.4")[0], "mips");
        assert_eq!(map_arch_str_to_keywords("aarch64-3.10")[0], "aarch64");
        assert_eq!(map_arch_str_to_keywords("armv7sf-3.2")[0], "armv7");
        assert_eq!(map_arch_str_to_keywords("x64-3.2")[0], "x86_64");
        assert_eq!(map_arch_str_to_keywords("x86-3.2")[0], "i386_pentium4");

        let opkg_out = "\
arch all 1
arch noarch 1
arch mipsel-3.4 10
arch mipsel-3.4_kn 20
";
        assert_eq!(
            parse_entware_opkg_arch(opkg_out).as_deref(),
            Some("mipsel-3.4_kn")
        );
        assert_eq!(
            map_arch_str_to_keywords(&parse_entware_opkg_arch(opkg_out).unwrap())[0],
            "mipsel"
        );
    }

    #[test]
    fn test_select_entware_tachyon_and_core_assets() {
        let tachyon_assets = vec![
            json!({
                "name": "tachyon-2.0.0-aarch64.apk",
                "browser_download_url": "https://example/tachyon-2.0.0-aarch64.apk"
            }),
            json!({
                "name": "tachyon-2.0.0-mipsel.ipk",
                "browser_download_url": "https://example/tachyon-2.0.0-mipsel.ipk"
            }),
            json!({
                "name": "tachyon-entware-mipsel-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-entware-mipsel-v2.0.0.tar.gz"
            }),
            json!({
                "name": "tachyon-entware-mips-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-entware-mips-v2.0.0.tar.gz"
            }),
            json!({
                "name": "tachyon-entware-aarch64-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-entware-aarch64-v2.0.0.tar.gz"
            }),
            json!({
                "name": "tachyon-entware-armv7-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-entware-armv7-v2.0.0.tar.gz"
            }),
            json!({
                "name": "tachyon-entware-x86_64-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-entware-x86_64-v2.0.0.tar.gz"
            }),
            json!({
                "name": "tachyon-entware-i386_pentium4-v2.0.0.tar.gz",
                "browser_download_url": "https://example/tachyon-entware-i386_pentium4-v2.0.0.tar.gz"
            }),
        ];

        for (ent_arch, expected_name) in [
            ("mipsel-3.4", "tachyon-entware-mipsel-v2.0.0.tar.gz"),
            ("mips-3.4", "tachyon-entware-mips-v2.0.0.tar.gz"),
            ("aarch64-3.10", "tachyon-entware-aarch64-v2.0.0.tar.gz"),
            ("armv7sf-3.2", "tachyon-entware-armv7-v2.0.0.tar.gz"),
            ("x64-3.2", "tachyon-entware-x86_64-v2.0.0.tar.gz"),
            ("x86-3.2", "tachyon-entware-i386_pentium4-v2.0.0.tar.gz"),
        ] {
            let kws = map_arch_str_to_keywords(ent_arch);
            let picked = select_entware_tachyon_asset(&tachyon_assets, &kws)
                .unwrap_or_else(|| panic!("no asset picked for {ent_arch} ({kws:?})"));
            assert_eq!(picked.0, expected_name);
        }

        let core_assets = vec![
            json!({
                "name": "tachyon-core-aarch64-v0.6.0.apk",
                "browser_download_url": "https://example/tachyon-core-aarch64-v0.6.0.apk"
            }),
            json!({
                "name": "tachyon-core-aarch64-musl.tar.gz",
                "browser_download_url": "https://example/tachyon-core-aarch64-musl.tar.gz"
            }),
            json!({
                "name": "tachyon-core-mipsel-v0.6.0.tar.gz",
                "browser_download_url": "https://example/tachyon-core-mipsel-v0.6.0.tar.gz"
            }),
        ];
        assert_eq!(
            select_entware_core_asset(&core_assets, &map_arch_str_to_keywords("aarch64-3.10"))
                .unwrap()
                .0,
            "tachyon-core-aarch64-musl.tar.gz"
        );
        assert_eq!(
            select_entware_core_asset(&core_assets, &map_arch_str_to_keywords("mipsel-3.4"))
                .unwrap()
                .0,
            "tachyon-core-mipsel-v0.6.0.tar.gz"
        );
    }

    #[test]
    fn test_sync_staged_entware_assets_durable_and_idempotent() {
        let uniq = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!("tachyon_entware_sync_{uniq}"));
        let stage = base.join("stage");
        let root = base.join("opt");
        std::fs::create_dir_all(stage.join("share/tachyon/www/luci-static/resources/view/tachyon"))
            .unwrap();
        std::fs::create_dir_all(stage.join("share/tachyon/www/luci-static/bootstrap")).unwrap();
        std::fs::create_dir_all(stage.join("etc/init.d")).unwrap();
        std::fs::write(
            stage.join("share/tachyon/www/luci-static/resources/view/tachyon/main.js"),
            b"console.log('tachyon');",
        )
        .unwrap();
        std::fs::write(
            stage.join("share/tachyon/www/luci-static/resources/luci.js"),
            b"window.LuCI = function(){};",
        )
        .unwrap();
        std::fs::write(
            stage.join("share/tachyon/www/luci-static/bootstrap/cascade.css"),
            b"body { color: #111; }",
        )
        .unwrap();
        std::fs::write(stage.join("etc/init.d/S99tachyon"), b"#!/bin/sh\nexit 0\n").unwrap();

        let paths = crate::platform::resolve_paths_for(
            crate::platform::PlatformKind::KeeneticEntware,
            Some(&root.to_string_lossy()),
            None,
            base.join("tmpfs"),
        );

        let first = sync_staged_entware_assets(&stage, &paths);
        assert_eq!(first, 4);
        assert!(
            paths
                .share_dir
                .join("www/luci-static/resources/view/tachyon/main.js")
                .is_file()
        );
        assert!(
            paths
                .share_dir
                .join("www/luci-static/resources/luci.js")
                .is_file()
        );
        assert!(
            paths
                .share_dir
                .join("www/luci-static/bootstrap/cascade.css")
                .is_file()
        );
        assert!(paths.init_script.is_file());

        // Second identical sync must be a zero-write no-op (wear-safe).
        let second = sync_staged_entware_assets(&stage, &paths);
        assert_eq!(second, 0);

        let _ = std::fs::remove_dir_all(&base);
    }
}
