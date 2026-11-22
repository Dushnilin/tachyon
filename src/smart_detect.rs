//! Native Smart Detect 2.0 background detector and target-section resolver.
//!
//! Consumes structured telemetry directly from `tachyon-core` (`/tachyon/anomalies` and
//! `/tachyon/flight?only_failed=true`), probes direct vs selected proxy sections through
//! `POST /tachyon/delay-batch`, enforces strict non-tunnel section exclusions (`block`,
//! `direct`, `bypass`, `dns`, `desync`), and persists confirmed domains to the chosen
//! target section's `user_domains` via transactional config updates + hot-reload.

use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::RwLock;

use crate::config_gen;
use crate::core_mgr::CoreManager;
use crate::crypto_gen;
use crate::store::{AppState, OutboundSource, RouterStoreData, RoutingSection, unix_now_secs};
use crate::transaction;
use crate::ubus_bridge;

const MAX_STREAKS: usize = 256;
const MAX_COOLDOWNS: usize = 512;
const MAX_RECENT_EVENTS: usize = 40;
const COOLDOWN_SECS: i64 = 300;
const DEFAULT_CONFIRM_WINDOW_SECS: i64 = 60;
const DEFAULT_MIN_FAILURES: u32 = 2;
const LOOP_INTERVAL_SECS: u64 = 30;
const MAX_PROBES_PER_TICK: usize = 3;
const TMPFS_COOLDOWN_PATH: &str = "/tmp/tachyon/smart_detect_seen.json";

/// Multi-label public suffixes that must never become the registered root domain.
const MULTI_LABEL_PUBLIC_SUFFIXES: &[&str] = &[
    "co.uk",
    "org.uk",
    "ac.uk",
    "gov.uk",
    "com.ru",
    "org.ru",
    "net.ru",
    "spb.ru",
    "msk.ru",
    "com.ua",
    "org.ua",
    "net.ua",
    "com.au",
    "net.au",
    "org.au",
    "co.jp",
    "ne.jp",
    "or.jp",
    "com.br",
    "net.br",
    "org.br",
    "com.tr",
    "com.cn",
    "net.cn",
    "org.cn",
    "co.in",
    "com.hk",
    "co.kr",
    "co.nz",
    "co.il",
    "co.za",
    "com.mx",
    "com.ar",
    "com.sg",
    "com.tw",
    "github.io",
    "gitlab.io",
    "pages.dev",
    "workers.dev",
    "vercel.app",
    "netlify.app",
    "herokuapp.com",
    "appspot.com",
    "googleapis.com",
    "amazonaws.com",
    "s3.amazonaws.com",
    "cloudfront.net",
    "azurewebsites.net",
    "fastly.net",
    "akamaiedge.net",
    "edgekey.net",
    "firebaseapp.com",
    "web.app",
    "fly.dev",
    "onrender.com",
    "r2.dev",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CandidateStreak {
    first_fail_unix: i64,
    last_seen_unix: i64,
    failures: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmartDetectEvent {
    pub timestamp: i64,
    pub domain: String,
    pub saved_rule: String,
    pub section_id: String,
    pub action: String,
    pub detail: String,
}

#[derive(Debug, Default)]
struct SmartDetectRuntimeState {
    last_tick_unix: i64,
    paused_reason: String,
    streaks: HashMap<String, CandidateStreak>,
    cooldowns: HashMap<String, i64>,
    cooldowns_loaded: bool,
    recent_events: Vec<SmartDetectEvent>,
}

static RUNTIME_STATE: OnceLock<RwLock<SmartDetectRuntimeState>> = OnceLock::new();

fn runtime_state() -> &'static RwLock<SmartDetectRuntimeState> {
    RUNTIME_STATE.get_or_init(|| RwLock::new(SmartDetectRuntimeState::default()))
}

/// Returns `true` strictly for active tunnel/proxy sections eligible as Smart Detect targets.
/// Non-tunnel actions (`block`, `reject`, `direct`, `bypass`, `dns`, `desync`, `hosts`) and
/// modular `Core Desync`-only sections are unconditionally excluded.
pub fn is_section_eligible(sec: &RoutingSection, sources: &[OutboundSource]) -> bool {
    if !sec.enabled {
        return false;
    }
    let act = sec.action.trim().to_ascii_lowercase();
    if matches!(
        act.as_str(),
        "block"
            | "reject"
            | "direct"
            | "bypass"
            | "dns"
            | "desync"
            | "hosts"
            | "zapret"
            | "zapret2"
            | "byedpi"
    ) {
        return false;
    }
    let conn = sec.connection_type.trim().to_ascii_lowercase();
    if matches!(
        conn.as_str(),
        "block" | "reject" | "direct" | "bypass" | "dns" | "desync" | "hosts"
    ) {
        return false;
    }

    // Modular sections with `action = "connection"` can still point exclusively to `desync` sources.
    let has_other_tunnel_refs = !sec.outbound_group_refs.is_empty()
        || !sec.outbound_group_ref.trim().is_empty()
        || !sec.section_refs.is_empty()
        || !sec.balancer_refs.is_empty()
        || !sec.interfaces.is_empty()
        || !sec.output_interface.trim().is_empty();

    if !sec.outbound_source_refs.is_empty() && !has_other_tunnel_refs {
        let mut found_any = false;
        let mut has_tunnel_source = false;
        for sref in &sec.outbound_source_refs {
            if let Some(src) = sources.iter().find(|s| s.id == *sref && s.enabled) {
                found_any = true;
                let st = src.source_type.trim().to_ascii_lowercase();
                if !matches!(
                    st.as_str(),
                    "desync" | "direct" | "block" | "reject" | "zapret" | "zapret2" | "byedpi"
                ) {
                    has_tunnel_source = true;
                    break;
                }
            }
        }
        if found_any && !has_tunnel_source {
            return false;
        }
    }

    true
}

/// Resolve ordered eligible target section IDs for Smart Detect:
/// 1. Explicit single target `settings.smart_detect_section` (if set and eligible);
/// 2. Otherwise ordered `settings.smart_detect_sections` filtered by eligibility;
/// 3. Otherwise the first eligible tunnel section in `data.sections` (never `block`/`direct`/`desync`).
pub fn resolve_target_sections(data: &RouterStoreData) -> Vec<String> {
    let explicit = data.settings.smart_detect_section.trim();
    if !explicit.is_empty()
        && let Some(sec) = data.sections.iter().find(|s| s.id == explicit)
        && is_section_eligible(sec, &data.outbound_sources)
    {
        return vec![sec.id.clone()];
    }

    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for id in &data.settings.smart_detect_sections {
        let trimmed = id.trim();
        if trimmed.is_empty() || !seen.insert(trimmed.to_string()) {
            continue;
        }
        if let Some(sec) = data.sections.iter().find(|s| s.id == trimmed)
            && is_section_eligible(sec, &data.outbound_sources)
        {
            out.push(sec.id.clone());
        }
    }
    if !out.is_empty() {
        return out;
    }

    for sec in &data.sections {
        if is_section_eligible(sec, &data.outbound_sources) {
            out.push(sec.id.clone());
            break;
        }
    }
    out
}

/// List all active tunnel sections eligible as Smart Detect targets.
pub fn list_eligible_sections(data: &RouterStoreData) -> Vec<Value> {
    data.sections
        .iter()
        .filter(|s| is_section_eligible(s, &data.outbound_sources))
        .map(|s| {
            json!({
                "id": s.id,
                "label": if s.label.trim().is_empty() { &s.id } else { &s.label },
                "action": s.action,
                "connection_type": s.connection_type,
            })
        })
        .collect()
}

/// Normalize and validate a candidate hostname (rejects IPs, local domains, invalid syntax).
pub fn normalize_candidate_host(raw: &str) -> Option<String> {
    let trimmed = raw.trim().trim_end_matches('.');
    if trimmed.is_empty() || trimmed.len() > 253 {
        return None;
    }
    let no_scheme = trimmed
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(trimmed);
    let authority = no_scheme.split(['/', '?', '#']).next().unwrap_or(no_scheme);
    let host = if authority.starts_with('[') {
        return None;
    } else {
        authority.split(':').next().unwrap_or(authority)
    }
    .trim()
    .trim_end_matches('.')
    .to_ascii_lowercase();

    if host.is_empty() || !host.contains('.') || host.contains("..") {
        return None;
    }
    if host.parse::<IpAddr>().is_ok() {
        return None;
    }
    if !host
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'.')
    {
        return None;
    }
    if host
        .split('.')
        .any(|lbl| lbl.is_empty() || lbl.len() > 63 || lbl.starts_with('-') || lbl.ends_with('-'))
    {
        return None;
    }
    if matches!(
        host.as_str(),
        "localhost" | "localhost.localdomain" | "router.local" | "openwrt.lan"
    ) || host.ends_with(".local")
        || host.ends_with(".lan")
        || host.ends_with(".home")
        || host.ends_with(".arpa")
        || host.ends_with(".internal")
        || host.ends_with(".localhost")
    {
        return None;
    }
    Some(host)
}

fn host_matches_domain_rule(host: &str, raw_rule: &str) -> bool {
    let token = raw_rule
        .split('#')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if token.is_empty() {
        return false;
    }
    let clean = token
        .strip_prefix("domain:")
        .or_else(|| token.strip_prefix("full:"))
        .or_else(|| token.strip_prefix("domain_suffix:"))
        .unwrap_or(&token)
        .trim_start_matches("*.")
        .trim_start_matches('.')
        .trim_end_matches('.');
    if clean.is_empty() {
        return false;
    }
    host == clean || host.ends_with(&format!(".{clean}"))
}

/// Expand a detected subdomain to its registrable root domain when `expand_to_root` is true,
/// preserving multi-label public suffixes and refusing expansion if it would swallow an exclusion.
pub fn expand_to_registrable_domain(
    host: &str,
    expand_to_root: bool,
    excludes: &[String],
) -> String {
    if !expand_to_root {
        return host.to_string();
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() <= 2 {
        return host.to_string();
    }

    let tail2 = format!("{}.{}", labels[labels.len() - 2], labels[labels.len() - 1]);
    let tail3 = if labels.len() >= 3 {
        Some(format!(
            "{}.{}.{}",
            labels[labels.len() - 3],
            labels[labels.len() - 2],
            labels[labels.len() - 1]
        ))
    } else {
        None
    };

    let candidate = if let Some(ref t3) = tail3
        && MULTI_LABEL_PUBLIC_SUFFIXES.contains(&t3.as_str())
    {
        if labels.len() <= 3 {
            return host.to_string();
        }
        format!("{}.{}", labels[labels.len() - 4], t3)
    } else if MULTI_LABEL_PUBLIC_SUFFIXES.contains(&tail2.as_str()) {
        if labels.len() <= 2 {
            return host.to_string();
        }
        format!("{}.{}", labels[labels.len() - 3], tail2)
    } else {
        tail2
    };

    // Never expand to a parent domain if an explicit exclusion sits underneath it.
    let would_swallow_exclude = excludes.iter().any(|ex| {
        let ex_clean = ex
            .split('#')
            .next()
            .unwrap_or("")
            .trim()
            .trim_start_matches("*.")
            .trim_start_matches('.')
            .trim_end_matches('.')
            .to_ascii_lowercase();
        !ex_clean.is_empty()
            && (ex_clean == candidate || ex_clean.ends_with(&format!(".{candidate}")))
    });
    if would_swallow_exclude {
        host.to_string()
    } else {
        candidate
    }
}

/// Extract normalized `.trs` list tokens configured for `smart_detect_exclude_lists`
/// as well as `community_lists` on active `block` / `direct` sections so domains in those
/// lists are never pulled into a proxy section.
fn collect_exclusion_trs_tokens(data: &RouterStoreData) -> Vec<String> {
    let mut out = Vec::new();
    let mut push_tok = |raw: &str| {
        let clean = raw
            .trim()
            .trim_start_matches("trs-")
            .trim_end_matches(".trs")
            .trim_end_matches(".srs")
            .trim()
            .to_string();
        if !clean.is_empty() && !out.contains(&clean) {
            out.push(clean);
        }
    };
    for raw in &data.settings.smart_detect_exclude_lists {
        push_tok(raw);
    }
    for sec in data.sections.iter().filter(|s| s.enabled) {
        let act = sec.action.trim().to_ascii_lowercase();
        let ct = sec.connection_type.trim().to_ascii_lowercase();
        if matches!(act.as_str(), "block" | "reject" | "bypass" | "direct")
            || matches!(ct.as_str(), "block" | "reject" | "bypass" | "direct")
        {
            for l in &sec.community_lists {
                push_tok(l);
            }
            for cref in &sec.condition_refs {
                if let Some(cond) = data.conditions.iter().find(|c| c.id == *cref) {
                    for l in &cond.community_lists {
                        push_tok(l);
                    }
                }
            }
        }
    }
    out
}

fn find_trs_list_paths(data: &RouterStoreData, token: &str) -> Vec<std::path::PathBuf> {
    let mut dirs = Vec::new();
    if !data.settings.rulesets_dir.trim().is_empty() {
        dirs.push(Path::new(data.settings.rulesets_dir.trim()).to_path_buf());
    }
    dirs.push(Path::new("/etc/tachyon/rulesets").to_path_buf());
    dirs.push(Path::new("/tmp/tachyon-rulesets").to_path_buf());

    let mut paths = Vec::new();
    for dir in dirs {
        for name in [format!("trs-{token}.trs"), format!("{token}.trs")] {
            let p = dir.join(name);
            if p.is_file() && !paths.contains(&p) {
                paths.push(p);
            }
        }
    }
    paths
}

async fn domain_matches_exclusion_trs_lists(
    core: &CoreManager,
    host: &str,
    data: &RouterStoreData,
) -> bool {
    let tokens = collect_exclusion_trs_tokens(data);
    if tokens.is_empty() {
        return false;
    }
    let bin_path = core.resolve_bin_path().await;
    if bin_path.trim().is_empty() || !Path::new(&bin_path).exists() {
        return false;
    }
    for token in tokens {
        for path in find_trs_list_paths(data, &token) {
            let mut cmd = tokio::process::Command::new(&bin_path);
            cmd.args(["rule-set", "match", "--domain", host])
                .arg(&path)
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true);
            if let Ok(Ok(out)) = tokio::time::timeout(Duration::from_secs(2), cmd.output()).await
                && out.status.success()
            {
                let text = String::from_utf8_lossy(&out.stdout);
                if text.lines().any(|l| l.trim().starts_with("[0] match")) {
                    return true;
                }
            }
        }
    }
    false
}

/// Check if a domain is excluded by `smart_detect_exclude` or already matched by any active section
/// (including `block`, `direct`, `bypass`, or already-learned `user_domains`).
pub fn is_domain_excluded_or_routed(host: &str, data: &RouterStoreData) -> bool {
    if data
        .settings
        .smart_detect_exclude
        .iter()
        .any(|ex| host_matches_domain_rule(host, ex))
    {
        return true;
    }

    for sec in data.sections.iter().filter(|s| s.enabled) {
        if sec
            .domains
            .iter()
            .chain(sec.user_domains.iter())
            .chain(sec.exclude_domains.iter())
            .any(|d| host_matches_domain_rule(host, d))
        {
            return true;
        }
        for cref in &sec.condition_refs {
            if let Some(cond) = data.conditions.iter().find(|c| c.id == *cref)
                && cond
                    .domains
                    .iter()
                    .chain(cond.user_domains.iter())
                    .chain(cond.exclude_domains.iter())
                    .any(|d| host_matches_domain_rule(host, d))
            {
                return true;
            }
        }
    }

    false
}

fn is_direct_outbound_tag(tag: &str) -> bool {
    matches!(
        tag.trim().to_ascii_lowercase().as_str(),
        "" | "direct" | "direct-out" | "bypass" | "direct-bypass"
    )
}

/// Extract candidate hostnames that failed over the direct/unproxied path from
/// `tachyon-core` `/tachyon/anomalies` and `/tachyon/flight?only_failed=true`.
pub fn extract_direct_failure_candidates(
    anomalies: Option<&Value>,
    flight_failures: Option<&Value>,
    mode: &str,
) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();

    if let Some(entries) = flight_failures
        .and_then(|v| v.get("entries"))
        .and_then(Value::as_array)
    {
        for e in entries {
            let outbound = e.get("outbound").and_then(Value::as_str).unwrap_or("");
            if !is_direct_outbound_tag(outbound) {
                continue;
            }
            let status = e.get("status").and_then(Value::as_str).unwrap_or("");
            let err_kind = e.get("error_kind").and_then(Value::as_str).unwrap_or("");
            let is_explicit_failure = !err_kind.trim().is_empty()
                || matches!(
                    status.trim().to_ascii_lowercase().as_str(),
                    "error" | "failed" | "timeout"
                );
            if !is_explicit_failure {
                continue;
            }
            let raw_host = e
                .get("host")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .or_else(|| e.get("destination").and_then(Value::as_str))
                .unwrap_or("");
            if let Some(host) = normalize_candidate_host(raw_host)
                && seen.insert(host.clone())
            {
                out.push(host);
            }
        }
    }

    let min_anom_fails = if mode.eq_ignore_ascii_case("plus") {
        1
    } else {
        2
    };
    if let Some(hosts) = anomalies
        .and_then(|v| v.get("hosts"))
        .and_then(Value::as_array)
    {
        for h in hosts {
            let fails = h
                .get("failures")
                .or_else(|| h.get("count"))
                .and_then(Value::as_u64)
                .unwrap_or(0);
            if fails < min_anom_fails {
                continue;
            }
            if let Some(ob) = h.get("outbound").and_then(Value::as_str)
                && !is_direct_outbound_tag(ob)
            {
                continue;
            }
            let raw_host = h.get("host").and_then(Value::as_str).unwrap_or("");
            if let Some(host) = normalize_candidate_host(raw_host)
                && seen.insert(host.clone())
            {
                out.push(host);
            }
        }
    }

    out
}

#[derive(Debug, Clone, Serialize)]
pub struct SmartDetectProbeOutcome {
    pub domain: String,
    pub saved_rule: String,
    pub direct_ok: bool,
    pub direct_ms: Option<u64>,
    pub matched_section: Option<String>,
    pub matched_outbound: Option<String>,
    pub proxy_ms: Option<u64>,
    pub tested_sections: Vec<Value>,
    pub verdict: String,
    pub applied: bool,
}

async fn run_delay_batch_probe(
    core: &Arc<CoreManager>,
    domain: &str,
    outbound_tags: &[String],
    timeout_ms: u64,
) -> anyhow::Result<Value> {
    let url = format!("https://{domain}/");
    let body = json!({
        "names": outbound_tags,
        "url": url,
        "timeout": timeout_ms,
    })
    .to_string();
    core.clash_request("POST", "/tachyon/delay-batch", Some(&body))
        .await
}

fn delay_from_batch(resp: &Value, tag: &str) -> Option<u64> {
    resp.get("results")
        .and_then(|r| r.get(tag))
        .and_then(|entry| entry.get("delay"))
        .and_then(Value::as_u64)
        .filter(|&ms| ms > 0)
}

type DomainInsertOutcome = (Vec<String>, Option<String>, Option<Vec<String>>);

fn insert_domain_into_section_and_linked_condition(
    candidate: &mut RouterStoreData,
    section_id: &str,
    domain_rule: &str,
) -> anyhow::Result<Option<DomainInsertOutcome>> {
    let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == section_id) else {
        anyhow::bail!("Целевая секция '{section_id}' не найдена");
    };
    if !is_section_eligible(sec, &candidate.outbound_sources) {
        anyhow::bail!("Секция '{section_id}' не может использоваться как цель Smart Detect");
    }

    let mut changed = false;
    if !sec
        .domains
        .iter()
        .chain(sec.user_domains.iter())
        .any(|d| d.eq_ignore_ascii_case(domain_rule))
    {
        sec.user_domains.push(domain_rule.to_string());
        changed = true;
    }
    let updated_sec_domains = sec.user_domains.clone();
    let linked_cond_id = sec.condition_refs.first().cloned();
    let mut updated_cond_domains: Option<Vec<String>> = None;
    let mut sync_cond_id: Option<String> = None;

    if let Some(ref cid) = linked_cond_id
        && let Some(cond) = candidate.conditions.iter_mut().find(|c| c.id == *cid)
        && !cond.is_composite()
    {
        if !cond
            .domains
            .iter()
            .chain(cond.user_domains.iter())
            .any(|d| d.eq_ignore_ascii_case(domain_rule))
        {
            cond.user_domains.push(domain_rule.to_string());
            changed = true;
        }
        sync_cond_id = Some(cid.clone());
        updated_cond_domains = Some(cond.user_domains.clone());
    }

    if !changed {
        return Ok(None);
    }

    Ok(Some((
        updated_sec_domains,
        sync_cond_id,
        updated_cond_domains,
    )))
}

async fn apply_detected_domain_to_section(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    section_id: &str,
    domain_rule: &str,
) -> anyhow::Result<bool> {
    let mut candidate = state.data.read().await.clone();
    let Some((updated_sec_domains, sync_cond_id, updated_cond_domains)) =
        insert_domain_into_section_and_linked_condition(&mut candidate, section_id, domain_rule)?
    else {
        return Ok(false);
    };

    transaction::commit_transaction_with_source(state, candidate, "smart_detect").await?;
    ubus_bridge::sync_section_user_domains_to_json(
        section_id,
        &updated_sec_domains,
        sync_cond_id.as_deref(),
        updated_cond_domains.as_deref(),
    );
    let _ = core.apply_or_reload().await;
    Ok(true)
}

async fn load_cooldowns_once(st: &mut SmartDetectRuntimeState) {
    if st.cooldowns_loaded {
        return;
    }
    st.cooldowns_loaded = true;
    if let Ok(raw) = tokio::fs::read_to_string(TMPFS_COOLDOWN_PATH).await
        && let Ok(map) = serde_json::from_str::<HashMap<String, i64>>(&raw)
    {
        let now = unix_now_secs();
        st.cooldowns = map
            .into_iter()
            .filter(|(_, ts)| now.saturating_sub(*ts) < COOLDOWN_SECS)
            .take(MAX_COOLDOWNS)
            .collect();
    }
}

fn persist_cooldowns_tmpfs(cooldowns: &HashMap<String, i64>) {
    if cfg!(windows) {
        return;
    }
    let path = Path::new(TMPFS_COOLDOWN_PATH);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(raw) = serde_json::to_string(cooldowns) {
        let _ = crypto_gen::write_file_if_changed(path, raw.as_bytes());
    }
}

fn record_event(st: &mut SmartDetectRuntimeState, ev: SmartDetectEvent) {
    st.recent_events.push(ev);
    if st.recent_events.len() > MAX_RECENT_EVENTS {
        let drop_n = st.recent_events.len() - MAX_RECENT_EVENTS;
        st.recent_events.drain(0..drop_n);
    }
}

/// Probe a single domain against `direct` and the resolved Smart Detect target sections.
/// When `apply` is `true` and the domain fails directly while succeeding via a target section,
/// adds the normalized rule to that target section and reloads `tachyon-core`.
pub async fn probe_single_domain(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    raw_domain: &str,
    apply: bool,
) -> anyhow::Result<SmartDetectProbeOutcome> {
    let Some(domain) = normalize_candidate_host(raw_domain) else {
        anyhow::bail!("Некорректное или локальное доменное имя: '{raw_domain}'");
    };
    let data = state.data.read().await.clone();
    let targets = resolve_target_sections(&data);
    if targets.is_empty() {
        anyhow::bail!("Нет активных прокси-секций для проверки Smart Detect");
    }

    let tag_map = config_gen::resolve_section_outbound_tags(&data);
    let mut probe_pairs: Vec<(String, String)> = Vec::new();
    let mut names = vec!["direct".to_string()];
    for sec_id in &targets {
        if let Some(tag) = tag_map.get(sec_id)
            && !tag.is_empty()
            && tag != "direct"
            && tag != "block"
        {
            probe_pairs.push((sec_id.clone(), tag.clone()));
            if !names.contains(tag) {
                names.push(tag.clone());
            }
        }
    }
    if probe_pairs.is_empty() {
        anyhow::bail!("Выбранные целевые секции не имеют активного outbound в tachyon-core");
    }

    let batch = run_delay_batch_probe(core, &domain, &names, 5000).await?;
    let mut direct_ms = delay_from_batch(&batch, "direct");

    // Always confirm an apparent direct failure with a second short probe so transient
    // handshake/packet jitter on reachable sites cannot poison routing lists.
    if direct_ms.is_none() {
        tokio::time::sleep(Duration::from_millis(1200)).await;
        if let Ok(recheck) =
            run_delay_batch_probe(core, &domain, &["direct".to_string()], 4000).await
        {
            direct_ms = delay_from_batch(&recheck, "direct");
        }
    }

    let mut tested_sections = Vec::new();
    let mut matched_section: Option<String> = None;
    let mut matched_outbound: Option<String> = None;
    let mut proxy_ms: Option<u64> = None;
    for (sec_id, tag) in &probe_pairs {
        let ms = delay_from_batch(&batch, tag);
        tested_sections.push(json!({
            "section_id": sec_id,
            "outbound_tag": tag,
            "ok": ms.is_some(),
            "delay_ms": ms,
        }));
        if matched_section.is_none()
            && let Some(d_ms) = ms
        {
            matched_section = Some(sec_id.clone());
            matched_outbound = Some(tag.clone());
            proxy_ms = Some(d_ms);
        }
    }

    let mut saved_rule = expand_to_registrable_domain(
        &domain,
        data.settings.smart_detect_expand_to_root,
        &data.settings.smart_detect_exclude,
    );

    if direct_ms.is_none() && matched_section.is_some() && saved_rule != domain {
        // Never expand a failing subdomain (e.g. a dead tracker host) onto a root domain
        // that is either directly reachable itself or covered by an exclusion list.
        let expanded_excluded = is_domain_excluded_or_routed(&saved_rule, &data)
            || domain_matches_exclusion_trs_lists(core, &saved_rule, &data).await;
        if expanded_excluded {
            saved_rule = domain.clone();
        } else if let Ok(root_probe) =
            run_delay_batch_probe(core, &saved_rule, &["direct".to_string()], 4000).await
            && delay_from_batch(&root_probe, "direct").is_some()
        {
            saved_rule = domain.clone();
        }
    }

    let rule_excluded = is_domain_excluded_or_routed(&domain, &data)
        || is_domain_excluded_or_routed(&saved_rule, &data)
        || domain_matches_exclusion_trs_lists(core, &domain, &data).await
        || (saved_rule != domain
            && domain_matches_exclusion_trs_lists(core, &saved_rule, &data).await);

    let (verdict, applied) = if direct_ms.is_some() {
        ("direct_reachable".to_string(), false)
    } else if rule_excluded {
        ("excluded_by_rule".to_string(), false)
    } else if let Some(ref sec_id) = matched_section {
        if apply {
            let added = apply_detected_domain_to_section(state, core, sec_id, &saved_rule).await?;
            let mut rt = runtime_state().write().await;
            record_event(
                &mut rt,
                SmartDetectEvent {
                    timestamp: unix_now_secs(),
                    domain: domain.clone(),
                    saved_rule: saved_rule.clone(),
                    section_id: sec_id.clone(),
                    action: if added {
                        "added".to_string()
                    } else {
                        "already_present".to_string()
                    },
                    detail: format!(
                        "Прямой доступ не прошёл; подтверждено через '{sec_id}' ({} мс)",
                        proxy_ms.unwrap_or(0)
                    ),
                },
            );
            (
                if added {
                    "added".to_string()
                } else {
                    "already_present".to_string()
                },
                added,
            )
        } else {
            ("proxy_confirmed".to_string(), false)
        }
    } else {
        ("unreachable_everywhere".to_string(), false)
    };

    Ok(SmartDetectProbeOutcome {
        domain,
        saved_rule,
        direct_ok: direct_ms.is_some(),
        direct_ms,
        matched_section,
        matched_outbound,
        proxy_ms,
        tested_sections,
        verdict,
        applied,
    })
}

/// Remove an auto-detected domain from a section (and optionally add it to `smart_detect_exclude`).
pub async fn remove_detected_domain(
    state: &Arc<AppState>,
    core: &Arc<CoreManager>,
    section_id: &str,
    raw_domain: &str,
    add_to_exclude: bool,
) -> anyhow::Result<Value> {
    let target_dom = raw_domain.trim().to_ascii_lowercase();
    if target_dom.is_empty() {
        anyhow::bail!("Домен не указан");
    }

    let mut candidate = state.data.read().await.clone();
    let mut removed = false;
    let mut updated_sec_domains: Option<Vec<String>> = None;
    let mut linked_cond_id: Option<String> = None;
    let mut updated_cond_domains: Option<Vec<String>> = None;

    if let Some(sec) = candidate.sections.iter_mut().find(|s| s.id == section_id) {
        let before = sec.user_domains.len();
        sec.user_domains
            .retain(|d| !d.trim().eq_ignore_ascii_case(&target_dom));
        if sec.user_domains.len() != before {
            removed = true;
        }
        updated_sec_domains = Some(sec.user_domains.clone());
        linked_cond_id = sec.condition_refs.first().cloned();
    }

    if let Some(ref cid) = linked_cond_id
        && let Some(cond) = candidate.conditions.iter_mut().find(|c| c.id == *cid)
    {
        let before = cond.user_domains.len();
        cond.user_domains
            .retain(|d| !d.trim().eq_ignore_ascii_case(&target_dom));
        if cond.user_domains.len() != before {
            removed = true;
        }
        updated_cond_domains = Some(cond.user_domains.clone());
    }

    let mut excluded_added = false;
    let mut updated_excludes: Option<Vec<String>> = None;
    if add_to_exclude {
        let rule = expand_to_registrable_domain(
            &target_dom,
            candidate.settings.smart_detect_expand_to_root,
            &candidate.settings.smart_detect_exclude,
        );
        if !candidate
            .settings
            .smart_detect_exclude
            .iter()
            .any(|e| e.trim().eq_ignore_ascii_case(&rule))
        {
            candidate.settings.smart_detect_exclude.push(rule);
            excluded_added = true;
        }
        updated_excludes = Some(candidate.settings.smart_detect_exclude.clone());
    }

    if removed || excluded_added {
        transaction::commit_transaction_with_source(state, candidate, "smart_detect").await?;
        if let Some(ref sdoms) = updated_sec_domains {
            ubus_bridge::sync_section_user_domains_to_json(
                section_id,
                sdoms,
                linked_cond_id.as_deref(),
                updated_cond_domains.as_deref(),
            );
        }
        if let Some(ref excl) = updated_excludes {
            ubus_bridge::sync_smart_detect_exclude_to_json(excl);
        }
        let _ = core.apply_or_reload().await;
    }

    Ok(json!({
        "ok": true,
        "section_id": section_id,
        "domain": target_dom,
        "removed": removed,
        "excluded": excluded_added,
    }))
}

/// Snapshot of Smart Detect 2.0 configuration, resolved target sections, learned domains, and runtime status.
pub async fn get_status(state: &Arc<AppState>) -> Value {
    let data = state.data.read().await.clone();
    let rt = runtime_state().read().await;
    let resolved_targets = resolve_target_sections(&data);
    let eligible_sections = list_eligible_sections(&data);

    let mut detected_domains = Vec::new();
    for sec in &data.sections {
        for d in &sec.user_domains {
            let trimmed = d.trim();
            if !trimmed.is_empty() {
                detected_domains.push(json!({
                    "domain": trimmed,
                    "section_id": sec.id,
                    "section_label": if sec.label.trim().is_empty() { &sec.id } else { &sec.label },
                }));
            }
        }
    }

    json!({
        "ok": true,
        "enabled": data.settings.smart_detect,
        "mode": data.settings.smart_detect_mode,
        "target_section": data.settings.smart_detect_section,
        "configured_sections": data.settings.smart_detect_sections,
        "resolved_targets": resolved_targets,
        "eligible_sections": eligible_sections,
        "expand_to_root": data.settings.smart_detect_expand_to_root,
        "exclude": data.settings.smart_detect_exclude,
        "exclude_lists": data.settings.smart_detect_exclude_lists,
        "persistent": data.settings.ai_persistent_smart_detect,
        "last_tick_unix": rt.last_tick_unix,
        "paused_reason": rt.paused_reason,
        "tracked_candidates": rt.streaks.len(),
        "cooldown_entries": rt.cooldowns.len(),
        "recent_events": rt.recent_events,
        "detected_domains": detected_domains,
    })
}

/// Execute one bounded Smart Detect poll cycle (called by the background loop).
pub async fn run_smart_detect_tick(state: &Arc<AppState>, core: &Arc<CoreManager>) {
    let now = unix_now_secs();
    let (settings, live_snap, data_snap) = {
        let d = state.data.read().await.clone();
        let l = state.live.read().await.clone();
        (d.settings.clone(), l, d)
    };

    if !settings.smart_detect {
        let mut rt = runtime_state().write().await;
        rt.paused_reason = "disabled".to_string();
        return;
    }
    if !live_snap.core_running {
        let mut rt = runtime_state().write().await;
        rt.last_tick_unix = now;
        rt.paused_reason = "core_stopped".to_string();
        return;
    }
    if !live_snap.wan_healthy || !live_snap.dns_healthy {
        let mut rt = runtime_state().write().await;
        rt.last_tick_unix = now;
        rt.paused_reason = "wan_or_dns_unhealthy".to_string();
        return;
    }
    if live_snap.config_drift {
        let mut rt = runtime_state().write().await;
        rt.last_tick_unix = now;
        rt.paused_reason = "config_drift".to_string();
        return;
    }

    let targets = resolve_target_sections(&data_snap);
    if targets.is_empty() {
        let mut rt = runtime_state().write().await;
        rt.last_tick_unix = now;
        rt.paused_reason = "no_eligible_target_sections".to_string();
        return;
    }

    let (anomalies_res, flight_res) = tokio::join!(
        core.get_core_anomalies(),
        core.get_core_flight_filtered(true, None, 40),
    );
    let candidates = extract_direct_failure_candidates(
        anomalies_res.ok().as_ref(),
        flight_res.ok().as_ref(),
        &settings.smart_detect_mode,
    );

    let is_plus = settings.smart_detect_mode.eq_ignore_ascii_case("plus");
    let mut ready_to_probe: Vec<String> = Vec::new();
    {
        let mut rt = runtime_state().write().await;
        load_cooldowns_once(&mut rt).await;
        rt.last_tick_unix = now;
        rt.paused_reason.clear();
        rt.cooldowns
            .retain(|_, ts| now.saturating_sub(*ts) < COOLDOWN_SECS);
        rt.streaks
            .retain(|_, s| now.saturating_sub(s.last_seen_unix) < COOLDOWN_SECS);

        for host in candidates {
            if rt.cooldowns.contains_key(&host) {
                continue;
            }
            if is_domain_excluded_or_routed(&host, &data_snap) {
                continue;
            }
            let entry = rt.streaks.entry(host.clone()).or_insert(CandidateStreak {
                first_fail_unix: now,
                last_seen_unix: now,
                failures: 0,
            });
            entry.failures = entry.failures.saturating_add(1);
            entry.last_seen_unix = now;

            let confirmed = if is_plus {
                entry.failures >= 1
            } else {
                entry.failures >= DEFAULT_MIN_FAILURES
                    && now.saturating_sub(entry.first_fail_unix) >= DEFAULT_CONFIRM_WINDOW_SECS
            };
            if confirmed && ready_to_probe.len() < MAX_PROBES_PER_TICK {
                ready_to_probe.push(host);
            }
            if rt.streaks.len() > MAX_STREAKS {
                break;
            }
        }
    }

    for host in ready_to_probe {
        if domain_matches_exclusion_trs_lists(core, &host, &data_snap).await {
            let mut rt = runtime_state().write().await;
            rt.streaks.remove(&host);
            rt.cooldowns.insert(host, unix_now_secs());
            continue;
        }
        let should_apply = settings.ai_persistent_smart_detect;
        match Box::pin(probe_single_domain(state, core, &host, should_apply)).await {
            Ok(outcome) => {
                let mut rt = runtime_state().write().await;
                rt.streaks.remove(&host);
                rt.cooldowns.insert(host.clone(), unix_now_secs());
                if rt.cooldowns.len() > MAX_COOLDOWNS
                    && let Some(oldest) = rt
                        .cooldowns
                        .iter()
                        .min_by_key(|(_, ts)| *ts)
                        .map(|(k, _)| k.clone())
                {
                    rt.cooldowns.remove(&oldest);
                }
                if !should_apply && outcome.verdict == "proxy_confirmed" {
                    record_event(
                        &mut rt,
                        SmartDetectEvent {
                            timestamp: unix_now_secs(),
                            domain: outcome.domain.clone(),
                            saved_rule: outcome.saved_rule.clone(),
                            section_id: outcome.matched_section.clone().unwrap_or_default(),
                            action: "detected_non_persistent".to_string(),
                            detail: "Домен подтверждён, но постоянная запись в конфиг отключена"
                                .to_string(),
                        },
                    );
                }
                persist_cooldowns_tmpfs(&rt.cooldowns);
            }
            Err(_) => {
                let mut rt = runtime_state().write().await;
                rt.cooldowns.insert(host, unix_now_secs());
            }
        }
    }
}

/// Spawn the background Smart Detect 2.0 worker inside the `tachyon` daemon.
pub fn spawn_smart_detect_loop(state: Arc<AppState>, core: Arc<CoreManager>) {
    tokio::spawn(async move {
        // Allow initial daemon startup and first watchdog probe cycle to settle.
        tokio::time::sleep(Duration::from_secs(20)).await;
        let mut interval = tokio::time::interval(Duration::from_secs(LOOP_INTERVAL_SECS));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            Box::pin(run_smart_detect_tick(&state, &core)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_section(id: &str, action: &str, conn_type: &str, source_refs: &[&str]) -> RoutingSection {
        RoutingSection {
            id: id.to_string(),
            enabled: true,
            label: id.to_string(),
            action: action.to_string(),
            connection_type: conn_type.to_string(),
            outbound_source_refs: source_refs.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn target_resolution_never_picks_block_direct_or_desync_and_respects_explicit_target() {
        let mut data = RouterStoreData {
            outbound_sources: vec![
                OutboundSource {
                    id: "desync".to_string(),
                    enabled: true,
                    source_type: "desync".to_string(),
                    ..Default::default()
                },
                OutboundSource {
                    id: "sub_main".to_string(),
                    enabled: true,
                    source_type: "subscription".to_string(),
                    ..Default::default()
                },
                OutboundSource {
                    id: "sub_work".to_string(),
                    enabled: true,
                    source_type: "subscription".to_string(),
                    ..Default::default()
                },
            ],
            sections: vec![
                mk_section("block", "block", "block", &[]),
                mk_section("ByPass", "bypass", "direct", &[]),
                mk_section("Discord", "connection", "desync", &["desync"]),
                mk_section("YouTube", "connection", "connection", &["desync"]),
                mk_section("Main", "connection", "connection", &["sub_main"]),
                mk_section("WorkVPN", "connection", "connection", &["sub_work"]),
            ],
            ..Default::default()
        };

        // Even with block/bypass/desync listed first and no explicit selection, only Main is picked.
        data.settings.smart_detect_section.clear();
        data.settings.smart_detect_sections.clear();
        assert_eq!(resolve_target_sections(&data), vec!["Main".to_string()]);

        // If user explicitly configures Block as smart_detect_section, it is rejected and falls back.
        data.settings.smart_detect_section = "block".to_string();
        assert_eq!(resolve_target_sections(&data), vec!["Main".to_string()]);

        // Explicit valid target overrides the ordered list.
        data.settings.smart_detect_section = "WorkVPN".to_string();
        data.settings.smart_detect_sections = vec!["Main".to_string(), "WorkVPN".to_string()];
        assert_eq!(resolve_target_sections(&data), vec!["WorkVPN".to_string()]);

        // Without explicit target, ordered list is preserved while filtering out ineligible sections.
        data.settings.smart_detect_section.clear();
        data.settings.smart_detect_sections = vec![
            "block".to_string(),
            "Discord".to_string(),
            "WorkVPN".to_string(),
            "Main".to_string(),
        ];
        assert_eq!(
            resolve_target_sections(&data),
            vec!["WorkVPN".to_string(), "Main".to_string()]
        );
    }

    #[test]
    fn domain_normalization_expansion_and_exclusion_guards() {
        assert_eq!(
            normalize_candidate_host("Sub.Example.COM:443"),
            Some("sub.example.com".to_string())
        );
        assert_eq!(normalize_candidate_host("192.168.1.1"), None);
        assert_eq!(normalize_candidate_host("router.lan"), None);
        assert_eq!(normalize_candidate_host("localhost"), None);

        assert_eq!(
            expand_to_registrable_domain("cdn.media.example.com", true, &[]),
            "example.com"
        );
        assert_eq!(
            expand_to_registrable_domain("api.service.co.uk", true, &[]),
            "service.co.uk"
        );
        assert_eq!(
            expand_to_registrable_domain("my-app.github.io", true, &[]),
            "my-app.github.io"
        );
        // Do not expand when an exclusion lives under the parent domain.
        assert_eq!(
            expand_to_registrable_domain(
                "blocked.example.com",
                true,
                &["allowed.example.com".to_string()]
            ),
            "blocked.example.com"
        );
        assert_eq!(
            expand_to_registrable_domain("cdn.example.com", false, &[]),
            "cdn.example.com"
        );
    }

    #[test]
    fn extract_candidates_filters_only_direct_failures() {
        let flight = json!({
            "entries": [
                {"host": "direct-fail.example.org", "outbound": "direct", "status": "error", "error_kind": "timeout", "download": 0},
                {"host": "vk.com", "outbound": "direct", "status": "completed", "error_kind": "", "download": 0},
                {"host": "proxy-fail.example.org", "outbound": "bal-Main", "status": "error", "error_kind": "timeout", "download": 0},
                {"host": "direct-ok.example.org", "outbound": "direct", "status": "completed", "error_kind": "", "download": 1024},
                {"host": "1.2.3.4", "outbound": "direct", "status": "error", "error_kind": "timeout", "download": 0}
            ]
        });
        let anomalies = json!({
            "hosts": [
                {"host": "anom-host.example.net", "failures": 3},
                {"host": "single-hit.example.net", "failures": 1}
            ]
        });
        let default_cands =
            extract_direct_failure_candidates(Some(&anomalies), Some(&flight), "default");
        assert_eq!(
            default_cands,
            vec![
                "direct-fail.example.org".to_string(),
                "anom-host.example.net".to_string()
            ]
        );
        let plus_cands = extract_direct_failure_candidates(Some(&anomalies), Some(&flight), "plus");
        assert!(plus_cands.contains(&"single-hit.example.net".to_string()));
    }

    #[test]
    fn exclusion_trs_tokens_collect_and_normalize() {
        let mut store = RouterStoreData::default();
        store.settings.smart_detect_exclude_lists =
            vec!["trs-russia_outside.trs".to_string(), "geo-ru".to_string()];
        store.sections.push(RoutingSection {
            id: "DirectExclude".to_string(),
            enabled: true,
            action: "direct".to_string(),
            ..Default::default()
        });
        store.conditions.push(crate::store::TrafficCondition {
            id: "cond_direct".to_string(),
            enabled: true,
            community_lists: vec![
                "ru-direct".to_string(),
                "trs-russia_outside.trs".to_string(),
            ],
            ..Default::default()
        });
        store
            .sections
            .last_mut()
            .unwrap()
            .condition_refs
            .push("cond_direct".to_string());

        let tokens = collect_exclusion_trs_tokens(&store);
        assert_eq!(
            tokens,
            vec![
                "russia_outside".to_string(),
                "geo-ru".to_string(),
                "ru-direct".to_string(),
            ]
        );
    }

    #[test]
    fn apply_detected_domain_skips_composite_condition() {
        let mut candidate = RouterStoreData::default();
        candidate.outbound_sources.clear();
        candidate.outbound_sources.push(OutboundSource {
            id: "src_vpn".to_string(),
            enabled: true,
            source_type: "urls".to_string(),
            proxy_links: vec![
                "vless://11111111-1111-1111-1111-111111111111@203.0.113.10:443#NL".to_string(),
            ],
            ..Default::default()
        });

        candidate.conditions.push(crate::store::TrafficCondition {
            id: "c_discord".to_string(),
            enabled: true,
            condition_type: "atomic".to_string(),
            user_domains: vec!["discord.com".to_string()],
            ..Default::default()
        });
        candidate.conditions.push(crate::store::TrafficCondition {
            id: "cond_vpn_policy".to_string(),
            enabled: true,
            condition_type: "all".to_string(),
            children: vec!["c_discord".to_string()],
            ..Default::default()
        });
        candidate.conditions.push(crate::store::TrafficCondition {
            id: "cond_atomic".to_string(),
            enabled: true,
            condition_type: "atomic".to_string(),
            ..Default::default()
        });

        candidate.sections.push(RoutingSection {
            id: "vpn".to_string(),
            enabled: true,
            action: "proxy".to_string(),
            outbound_source_refs: vec!["src_vpn".to_string()],
            condition_refs: vec!["cond_vpn_policy".to_string()],
            ..Default::default()
        });
        candidate.sections.push(RoutingSection {
            id: "sec_atomic".to_string(),
            enabled: true,
            action: "proxy".to_string(),
            outbound_source_refs: vec!["src_vpn".to_string()],
            condition_refs: vec!["cond_atomic".to_string()],
            ..Default::default()
        });

        // Composite condition must NOT receive the detected domain
        let outcome = insert_domain_into_section_and_linked_condition(
            &mut candidate,
            "vpn",
            "detected.example",
        )
        .expect("insert into composite-linked section")
        .expect("changed");
        assert!(outcome.1.is_none());
        assert!(outcome.2.is_none());
        assert_eq!(
            candidate
                .sections
                .iter()
                .find(|s| s.id == "vpn")
                .unwrap()
                .user_domains,
            vec!["detected.example".to_string()]
        );
        assert!(
            candidate
                .conditions
                .iter()
                .find(|c| c.id == "cond_vpn_policy")
                .unwrap()
                .user_domains
                .is_empty(),
            "composite condition must remain untouched"
        );

        // Plain atomic condition still mirrors the domain
        let atomic_outcome = insert_domain_into_section_and_linked_condition(
            &mut candidate,
            "sec_atomic",
            "atomic.example",
        )
        .expect("insert into atomic-linked section")
        .expect("changed");
        assert_eq!(atomic_outcome.1.as_deref(), Some("cond_atomic"));
        assert_eq!(
            candidate
                .conditions
                .iter()
                .find(|c| c.id == "cond_atomic")
                .unwrap()
                .user_domains,
            vec!["atomic.example".to_string()]
        );
    }
}
